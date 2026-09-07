const std = @import("std");
const mem = std.mem;
const debug = std.debug;
const assert = debug.assert;
const Allocator = mem.Allocator;
const testing = std.testing;
const panic = debug.panic;
const atomic = std.atomic;
const builtin = @import("builtin");
const math = std.math;
const Io = std.Io;

const log = std.log.scoped(.chunk_pool);

const Index = enum(u32) {
    none = math.maxInt(u32),
    _,
};
const Chunk = opaque {
    const Header = struct {
        next: Index,
    };

    fn header(self: *Chunk) *Header {
        return @ptrCast(@alignCast(self));
    }
};

pub const Options = struct {
    capacity: u32,
    chunk_size: u32,
    alignment: ?mem.Alignment = null,
};

pub const ChunkPool = struct {
    ptr: [*]u8,
    len: usize,
    alignment: mem.Alignment,
    chunk_size: u32,
    reserved: u32,
    free_list: Index,
    mutex: Io.Mutex,

    pub fn init(self: *ChunkPool, allocator: Allocator, opt: Options) !void {
        assert(opt.capacity < math.maxInt(u32));
        assert(opt.capacity > 0);
        assert(opt.chunk_size > 0);

        const len = @as(usize, opt.chunk_size) * @as(usize, opt.capacity);
        const alignment: mem.Alignment = opt.alignment orelse .fromByteUnits(opt.chunk_size);
        const ptr = allocator.rawAlloc(len, alignment, @returnAddress()) orelse return error.OutOfMemory;

        self.* = .{
            .reserved = 0,
            .free_list = .none,
            .len = len,
            .ptr = ptr,
            .alignment = alignment,
            .chunk_size = opt.chunk_size,
            .mutex = .init,
        };
    }

    pub fn alloc(self: *ChunkPool) ?[]u8 {
        if (self.free_list == .none) {
            const index = self.reserved;
            const offset = index * self.chunk_size;

            if (offset == self.len) return null;
            self.reserved += 1;

            return self.ptr[offset .. offset + self.chunk_size];
        } else {
            const index = self.free_list;

            const offset = @intFromEnum(index) * self.chunk_size;
            const chunk: *Chunk = @ptrCast(@alignCast(&self.ptr[offset]));
            const next = chunk.header().next;
            self.free_list = next;

            return self.ptr[offset .. offset + self.chunk_size];
        }
    }

    pub fn threadSafeAlloc(self: *ChunkPool, io: Io) ?[]u8 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        return self.alloc();
    }

    pub fn free(self: *ChunkPool, buffer: []u8) void {
        assert(buffer.len == self.chunk_size);
        assert(@intFromPtr(buffer.ptr) >= @intFromPtr(self.ptr));
        assert(@intFromPtr(buffer.ptr) + buffer.len <= @intFromPtr(self.ptr) + self.len);

        const offset = @intFromPtr(buffer.ptr) - @intFromPtr(self.ptr);
        assert(offset % self.chunk_size == 0);
        const index: Index = @enumFromInt(offset / self.chunk_size);
        const chunk: *Chunk = @ptrCast(@alignCast(buffer.ptr));

        const head = self.free_list;
        chunk.header().next = head;

        self.free_list = index;
    }

    pub fn threadSafeFree(self: *ChunkPool, buffer: []u8, io: Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        self.free(buffer);
    }

    pub fn deinit(self: *ChunkPool, gpa: Allocator) void {
        gpa.rawFree(self.ptr[0..self.len], self.alignment, @returnAddress());
    }

    pub fn reset(self: *ChunkPool) void {
        self.reserved = 0;
        self.free_list = .none;
    }

    pub fn threadSafeReset(self: *ChunkPool, io: Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        self.reset();
    }
};

fn lessThan(_: void, lhs: Options, rhs: Options) bool {
    return lhs.chunk_size < rhs.chunk_size;
}

pub const ChunkAllocator = struct {
    pools: []ChunkPool,
    io: Io,

    pub fn init(self: *ChunkAllocator, child_alloc: Allocator, opts: []const Options) !void {
        self.* = .{
            .pools = undefined,
            .io = undefined,
        };

        self.pools = try child_alloc.alloc(ChunkPool, opts.len);
        errdefer child_alloc.free(self.pools);

        var initialized: usize = 0;
        errdefer {
            for (self.pools[0..initialized]) |*pool| pool.deinit(child_alloc);
        }

        var buffer: [100]Options = undefined;
        for (opts, 0..) |config, index| {
            buffer[index] = .{
                .capacity = config.capacity,
                .chunk_size = math.ceilPowerOfTwoAssert(u32, config.chunk_size),
                .alignment = config.alignment,
            };
        }

        const ordered_pools = buffer[0..opts.len];
        mem.sort(Options, buffer[0..opts.len], {}, lessThan);

        var last: u32 = 0;
        for (ordered_pools, 0..) |opt, index| {
            assert(last != opt.chunk_size);

            try self.pools[index].init(child_alloc, opt);

            last = opt.chunk_size;
            initialized += 1;
        }
    }

    pub fn initThreadSafe(self: *ChunkAllocator, child_alloc: Allocator, pool_configs: []const Options, io: Io) !void {
        try self.init(child_alloc, pool_configs);
        self.io = io;
    }

    pub fn deinit(self: *ChunkAllocator, child_alloc: Allocator) void {
        for (self.pools) |*pool| pool.deinit(child_alloc);
        child_alloc.free(self.pools);
    }

    pub fn allocator(self: *ChunkAllocator) Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = Allocator.noResize,
                .remap = Allocator.noRemap,
                .free = free,
            },
        };
    }

    pub fn threadSafeAllocator(self: *ChunkAllocator) Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = threadSafeAlloc,
                .resize = Allocator.noResize,
                .remap = Allocator.noRemap,
                .free = threadSafeFree,
            },
        };
    }

    fn findPool(self: *ChunkAllocator, len: usize, alignment: mem.Alignment) ?*ChunkPool {
        assert(self.pools[self.pools.len - 1].chunk_size >= len);

        for (self.pools) |*pool| {
            if (len > pool.chunk_size) continue;
            if (alignment.toByteUnits() > pool.alignment.toByteUnits()) continue;
            return pool;
        }

        return null;
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: mem.Alignment, _: usize) ?[*]u8 {
        const self: *ChunkAllocator = @ptrCast(@alignCast(ctx));
        const pool = self.findPool(len, alignment) orelse return null;
        const buffer = pool.alloc() orelse return null;

        if (builtin.mode == .Debug and !builtin.is_test and len < buffer.len >> 1) {
            log.warn("Unused chunk size={} used={}", .{ buffer.len, len });
        }

        return buffer.ptr;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: mem.Alignment, _: usize) void {
        const self: *ChunkAllocator = @ptrCast(@alignCast(ctx));
        const pool = self.findPool(memory.len, alignment) orelse unreachable;
        pool.free(memory.ptr[0..pool.chunk_size]);
    }

    fn threadSafeAlloc(ctx: *anyopaque, len: usize, alignment: mem.Alignment, _: usize) ?[*]u8 {
        const self: *ChunkAllocator = @ptrCast(@alignCast(ctx));
        const pool = self.findPool(len, alignment) orelse return null;
        const buffer = pool.threadSafeAlloc(self.io) orelse return null;

        if (builtin.mode == .Debug and !builtin.is_test and len < buffer.len >> 1) {
            log.warn("Unused chunk size={} used={}", .{ buffer.len, len });
        }

        return buffer.ptr;
    }

    fn threadSafeFree(ctx: *anyopaque, memory: []u8, alignment: mem.Alignment, _: usize) void {
        const self: *ChunkAllocator = @ptrCast(@alignCast(ctx));
        const pool = self.findPool(memory.len, alignment) orelse unreachable;
        pool.threadSafeFree(memory.ptr[0..pool.chunk_size], self.io);
    }

    fn reset(self: *ChunkAllocator) void {
        for (self.pools) |pool| pool.reset();
    }
};

test "Simple Chunk Pool" {
    const gpa = testing.allocator;

    var pool: ChunkPool = undefined;
    try pool.init(gpa, .{ .capacity = 2, .chunk_size = 128 });
    defer pool.deinit(gpa);

    const first = pool.alloc() orelse return error.TestUnexpectedResult;
    const second = pool.alloc() orelse return error.TestUnexpectedResult;
    try testing.expect(first.ptr != second.ptr);

    pool.free(first);

    const allocated = pool.alloc() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(first.ptr, allocated.ptr);
    try testing.expectEqual(@as(usize, 128), allocated.len);
    try testing.expect(pool.alloc() == null);
}

test "Chunk Pool reuses chunk after capacity is exhausted" {
    const gpa = testing.allocator;

    var pool: ChunkPool = undefined;
    try pool.init(gpa, .{ .capacity = 3, .chunk_size = 128 });
    defer pool.deinit(gpa);

    const first = pool.alloc() orelse return error.TestUnexpectedResult;
    _ = pool.alloc() orelse return error.TestUnexpectedResult;
    _ = pool.alloc() orelse return error.TestUnexpectedResult;

    try testing.expect(pool.alloc() == null);

    pool.free(first);

    const reused = pool.alloc() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(first.ptr, reused.ptr);
}

test "Chunk Allocator" {
    const gpa = testing.allocator;

    const Small = struct {
        a: u32,
        b: u32,
    };
    const Medium = struct {
        bytes: [80]u8,
    };

    var chunk_allocator: ChunkAllocator = undefined;
    try chunk_allocator.init(gpa, &.{ .{ .capacity = 1, .chunk_size = 64 }, .{ .capacity = 1, .chunk_size = 128 } });
    defer chunk_allocator.deinit(gpa);

    const alloc = chunk_allocator.allocator();
    const small = try alloc.create(Small);
    small.* = .{ .a = 1, .b = 2 };
    try testing.expectEqual(@as(u32, 1), small.a);
    try testing.expectError(error.OutOfMemory, alloc.create(Small));

    const medium = try alloc.create(Medium);
    try testing.expectError(error.OutOfMemory, alloc.create(Medium));

    alloc.destroy(small);

    const reused = try alloc.create(Small);
    try testing.expectEqual(small, reused);
    alloc.destroy(reused);
    alloc.destroy(medium);
}

test "Chunk Allocator orders chunk sizes from smallest to biggest" {
    const gpa = testing.allocator;

    var chunk_allocator: ChunkAllocator = undefined;
    try chunk_allocator.init(gpa, &.{ .{ .capacity = 1, .chunk_size = 128 }, .{ .capacity = 1, .chunk_size = 64 }, .{ .capacity = 1, .chunk_size = 256 } });
    defer chunk_allocator.deinit(gpa);

    try testing.expectEqual(@as(u32, 64), chunk_allocator.pools[0].chunk_size);
    try testing.expectEqual(@as(u32, 128), chunk_allocator.pools[1].chunk_size);
    try testing.expectEqual(@as(u32, 256), chunk_allocator.pools[2].chunk_size);
}
