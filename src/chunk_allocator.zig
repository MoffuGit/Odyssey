const std = @import("std");
const mem = std.mem;
const heap = std.heap;
const assert = std.debug.assert;
const Allocator = mem.Allocator;
const Io = std.Io;
const testing = std.testing;
const builtin = @import("builtin");

const datastruct = @import("datastruct.zig");
const DoublyLinkedList = datastruct.DoublyLinkedList;
const SinglyLinkedList = datastruct.SinglyLinkedList;

const base_size = 16;
const small_max = 1024;
const max_size = 256 * 1024;
const slot_len = 64 * 1024 * 1024;
const max_align = 64 * 1024;
const pool_count = 96;
const chunk_offset = mem.alignForward(usize, @sizeOf(Slot), @alignOf(Chunk));
const bucket_count = 3;

const bucket_info: [bucket_count]BucketInfo = blk: {
    var info: [bucket_count]BucketInfo = undefined;
    for (&info, [_]usize{ 64 << 10, 1 << 20, 4 << 20 }) |*t, len| {
        const capacity = slot_len / len;
        const meta = chunk_offset + capacity * @sizeOf(Chunk);
        t.* = .{ .len = len, .capacity = capacity, .start = (meta + len - 1) / len };
    }
    break :blk info;
};

const pool_info: [pool_count]PoolInfo = blk: {
    var info: [pool_count]PoolInfo = undefined;
    for (&info, 0..) |*c, i| {
        const size = poolSize(i);

        const bucket = bkl: {
            if (size <= 4 * 1024) break :bkl 0;
            if (size <= 32 * 1024) break :bkl 1;
            break :bkl 2;
        };

        c.* = .{
            .size = size,
            .capacity = bucket_info[bucket].len / size,
            .bucket = bucket,
            .alignment = .fromByteUnits(@min(max_align, @as(usize, 1) << @ctz(size))),
        };
    }
    break :blk info;
};

comptime {
    assert(pool_count <= 1 << @bitSizeOf(u8));
    assert(base_size >= @sizeOf(Free));
    for (bucket_info) |t| assert(t.start < t.capacity);
}

pub const ChunkAllocator = @This();

child: Allocator,
io: Io,
mutex: Io.Mutex,
pools: [pool_count]DoublyLinkedList(Chunk),
buckets: [bucket_count]Bucket,

pub fn init(child: Allocator) ChunkAllocator {
    return .{
        .child = child,
        .io = undefined,
        .mutex = .init,
        .pools = @splat(.empty),
        .buckets = @splat(.empty),
    };
}

pub fn initThreadSafe(child: Allocator, io: Io) ChunkAllocator {
    return .{
        .io = io,
        .child = child,
        .mutex = .init,
        .pools = @splat(.empty),
        .buckets = @splat(.empty),
    };
}

pub fn deinit(self: *ChunkAllocator) void {
    for (&self.buckets) |*bucket| {
        var iter = bucket.slots.iterator();
        while (iter.next()) |slot| {
            const bytes: [*]u8 = @ptrCast(slot);
            self.child.rawFree(bytes[0..slot_len], .fromByteUnits(slot_len), @returnAddress());
        }
    }
}

pub fn allocator(self: *ChunkAllocator) Allocator {
    return .{
        .ptr = self,
        .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        },
    };
}

pub fn threadSafeAllocator(self: *ChunkAllocator) Allocator {
    return .{
        .ptr = self,
        .vtable = &.{
            .alloc = threadSafeAlloc,
            .resize = resize,
            .remap = remap,
            .free = threadSafeFree,
        },
    };
}

fn alloc(ctx: *anyopaque, len: usize, alignment: mem.Alignment, _: usize) ?[*]u8 {
    const self: *ChunkAllocator = @ptrCast(@alignCast(ctx));

    const index = poolIndex(len, alignment);
    const info = pool_info[index];
    const pool = &self.pools[index];
    const chunk = pool.first orelse self.getChunk(index) catch return null;

    chunk.live += 1;
    if (chunk.live == info.capacity) pool.remove(chunk);

    if (chunk.free_list) |f| {
        chunk.free_list = f.next;
        return @ptrCast(f);
    } else {
        const offset = @as(usize, chunk.used) * info.size;
        chunk.used += 1;

        const slot = Slot.fromAddr(@intFromPtr(chunk));
        const chunk_index = (@intFromPtr(chunk) - @intFromPtr(slot.chunks())) / @sizeOf(Chunk);

        const base: [*]u8 = @ptrCast(slot);
        return base + chunk_index * bucket_info[info.bucket].len + offset;
    }
}

fn free(ctx: *anyopaque, memory: []u8, alignment: mem.Alignment, ret_addr: usize) void {
    _ = ret_addr;

    const self: *ChunkAllocator = @ptrCast(@alignCast(ctx));
    const ptr = memory.ptr;
    const index = poolIndex(memory.len, alignment);
    const info = pool_info[index];
    const pool = &self.pools[index];
    const chunk = self.chunkOf(ptr, info.bucket);
    assert(chunk.class == index);

    const node: *Free = @ptrCast(@alignCast(ptr));
    node.* = .{ .next = chunk.free_list };
    chunk.free_list = node;

    if (chunk.live == info.capacity) pool.prepend(chunk);
    chunk.live -= 1;
    if (chunk.live == 0) {
        pool.remove(chunk);
        const bucket = &self.buckets[info.bucket];
        chunk.next = bucket.free;
        bucket.free = chunk;
    }
}

fn threadSafeAlloc(ctx: *anyopaque, len: usize, alignment: mem.Alignment, ret_addr: usize) ?[*]u8 {
    const self: *ChunkAllocator = @ptrCast(@alignCast(ctx));

    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    return alloc(ctx, len, alignment, ret_addr);
}

fn threadSafeFree(ctx: *anyopaque, memory: []u8, alignment: mem.Alignment, ret_addr: usize) void {
    const self: *ChunkAllocator = @ptrCast(@alignCast(ctx));

    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    free(ctx, memory, alignment, ret_addr);
}

fn resize(_: *anyopaque, _: []u8, _: mem.Alignment, _: usize, _: usize) bool {
    unreachable;
}

fn remap(_: *anyopaque, _: []u8, _: mem.Alignment, _: usize, _: usize) ?[*]u8 {
    unreachable;
}

fn getChunk(self: *ChunkAllocator, index: u32) Allocator.Error!*Chunk {
    const t = pool_info[index].bucket;
    const bucket = &self.buckets[t];

    const chunk = if (bucket.free) |c| blk: {
        bucket.free = c.next;
        break :blk c;
    } else bkl: {
        const info = bucket_info[t];

        if (bucket.current == null or bucket.consumed == info.capacity) {
            const next = if (bucket.current) |s| s.next else bucket.slots.head;
            bucket.current = next orelse try self.newSlot(bucket);
            bucket.consumed = info.start;
        }

        const chunk = &bucket.current.?.chunks()[bucket.consumed];
        bucket.consumed += 1;
        break :bkl chunk;
    };

    chunk.* = .{
        .next = null,
        .prev = null,
        .free_list = null,
        .used = 0,
        .live = 0,
        .class = @intCast(index),
    };
    self.pools[index].prepend(chunk);
    return chunk;
}

fn newSlot(self: *ChunkAllocator, bucket: *Bucket) Allocator.Error!*Slot {
    const bytes = self.child.rawAlloc(slot_len, .fromByteUnits(slot_len), @returnAddress()) orelse
        return error.OutOfMemory;
    const slot: *Slot = @ptrCast(@alignCast(bytes));
    slot.* = .{};
    bucket.slots.append(slot);
    return slot;
}

fn chunkOf(self: *ChunkAllocator, ptr: [*]u8, t: u2) *Chunk {
    const info = bucket_info[t];
    const slot = Slot.fromAddr(@intFromPtr(ptr));
    assert(self.ownSlot(slot, t));

    const offset = @intFromPtr(ptr) - @intFromPtr(slot);
    const index = offset / info.len;
    assert(index >= info.start);

    const chunk = &slot.chunks()[index];

    if (builtin.mode.runtimeSafety()) {
        const size = pool_info[chunk.class].size;
        const in_chunk = offset % info.len;
        assert(in_chunk % size == 0 and in_chunk / size < chunk.used);
    }

    return chunk;
}

fn ownSlot(self: *ChunkAllocator, slot: *Slot, t: u2) bool {
    var s = self.buckets[t].slots.head;
    while (s) |cur| : (s = cur.next) if (cur == slot) return true;
    return false;
}

pub fn poolIndex(len: usize, alignment: mem.Alignment) u32 {
    assert(len > 0);
    const align_bytes = alignment.toByteUnits();
    assert(align_bytes <= max_align);
    const size: u32 = @intCast(mem.alignForward(usize, len, @max(align_bytes, base_size)));
    assert(size > 0 and size <= max_size);
    if (size <= small_max) return (size - 1) / base_size;
    const msb: u32 = 31 - @clz(size - 1);
    const quarter = ((size - 1) >> @intCast(msb - 2)) & 3;
    return 64 + (msb - 10) * 4 + quarter;
}

pub fn poolSize(index: u32) u32 {
    assert(index < pool_count);
    if (index < 64) return (index + 1) * base_size;
    const msb: u5 = @intCast(10 + (index - 64) / 4);
    const quarter = (index - 64) % 4;
    return (@as(u32, 1) << msb) + (quarter + 1) * (@as(u32, 1) << (msb - 2));
}

const Bucket = struct {
    pub const empty: Bucket = .{
        .slots = .empty,
        .current = null,
        .consumed = 0,
        .free = null,
    };

    slots: SinglyLinkedList(Slot),
    current: ?*Slot = null,
    consumed: u32 = 0,
    free: ?*Chunk = null,
};

const BucketInfo = struct {
    len: usize,
    capacity: u32,
    start: u32,
};

const PoolInfo = struct {
    size: u32,
    capacity: u32,
    bucket: u2,
    alignment: mem.Alignment,
};

const Free = struct { next: ?*Free };

const Chunk = struct {
    next: ?*Chunk,
    prev: ?*Chunk,
    free_list: ?*Free,
    used: u32,
    live: u32,
    class: u8,
};

const Slot = struct {
    next: ?*Slot = null,

    fn chunks(self: *Slot) [*]Chunk {
        return @ptrCast(@alignCast(@as([*]u8, @ptrCast(self)) + chunk_offset));
    }

    fn fromAddr(addr: usize) *Slot {
        return @ptrFromInt(addr & ~@as(usize, slot_len - 1));
    }
};

fn countSpans(chunks: *const ChunkAllocator, t: u2) usize {
    var n: usize = 0;
    var s = chunks.buckets[t].slots.head;
    while (s) |span| : (s = span.next) n += 1;
    return n;
}

test "pool sizes" {
    const expected = [_]u32{
        16,    32,    48,     64,     80,     96,     112,    128,
        144,   160,   176,    192,    208,    224,    240,    256,
        272,   288,   304,    320,    336,    352,    368,    384,
        400,   416,   432,    448,    464,    480,    496,    512,
        528,   544,   560,    576,    592,    608,    624,    640,
        656,   672,   688,    704,    720,    736,    752,    768,
        784,   800,   816,    832,    848,    864,    880,    896,
        912,   928,   944,    960,    976,    992,    1008,   1024,
        1280,  1536,  1792,   2048,   2560,   3072,   3584,   4096,
        5120,  6144,  7168,   8192,   10240,  12288,  14336,  16384,
        20480, 24576, 28672,  32768,  40960,  49152,  57344,  65536,
        81920, 98304, 114688, 131072, 163840, 196608, 229376, 262144,
    };
    for (expected, 0..) |size, index| {
        try testing.expectEqual(size, poolSize(@intCast(index)));
    }
}

test "pool table: size, alignment, chunk length, slots per chunk" {
    const cases = [_]struct { u32, u32, usize, usize, u32 }{
        .{ 1, 16, 16, 64 << 10, 4096 },
        .{ 17, 32, 32, 64 << 10, 2048 },
        .{ 56, 64, 64, 64 << 10, 1024 },
        .{ 72, 80, 16, 64 << 10, 819 },
        .{ 1024, 1024, 1024, 64 << 10, 64 },
        .{ 4096, 4096, 4096, 64 << 10, 16 },
        .{ 4097, 5120, 1024, 1 << 20, 204 },
        .{ 200 << 10, 224 << 10, 32 << 10, 4 << 20, 18 },
        .{ max_size, max_size, 64 << 10, 4 << 20, 16 },
    };
    for (cases) |c| {
        const info = pool_info[poolIndex(c[0], .@"16")];
        try testing.expectEqual(c[1], info.size);
        try testing.expectEqual(c[2], info.alignment.toByteUnits());
        try testing.expectEqual(c[3], bucket_info[info.bucket].len);
        try testing.expectEqual(c[4], info.capacity);
    }
}

test "picks the pool by size and alignment" {
    var chunks: ChunkAllocator = .init(testing.allocator);
    defer chunks.deinit();

    const a = chunks.allocator();

    const aligned = try a.alignedAlloc(u8, .@"64", 48);
    try testing.expect(@intFromPtr(aligned.ptr) % 64 == 0);
    try testing.expectEqual(@as(u8, comptime poolIndex(64, .@"64")), chunks.chunkOf(aligned.ptr, 0).class);

    const big = try a.alignedAlloc(u8, comptime .fromByteUnits(512), 1100);
    try testing.expect(@intFromPtr(big.ptr) % 512 == 0);
    try testing.expectEqual(@as(u8, comptime poolIndex(1536, .fromByteUnits(512))), chunks.chunkOf(big.ptr, 0).class);

    try testing.expectEqual(@as(usize, 1), countSpans(&chunks, 0));
    for (1..bucket_count) |t| try testing.expectEqual(@as(usize, 0), countSpans(&chunks, @intCast(t)));

    a.free(aligned);
    a.free(big);
}

test "an emptied chunk is reused by another class of its tier" {
    var chunks: ChunkAllocator = .init(testing.allocator);
    defer chunks.deinit();

    const a = chunks.allocator();

    const small = try a.alloc(u8, 16);
    const chunk = chunks.chunkOf(small.ptr, 0);
    a.free(small);

    const other = try a.alloc(u8, 3000);
    try testing.expectEqual(small.ptr, other.ptr);
    try testing.expectEqual(chunk, chunks.chunkOf(other.ptr, 0));
    try testing.expectEqual(@as(u8, comptime poolIndex(3072, .@"16")), chunk.class);
    try testing.expectEqual(@as(usize, 1), countSpans(&chunks, 0));
    a.free(other);
}

test "a chunk that is not empty stays with its pool" {
    var chunks: ChunkAllocator = .init(testing.allocator);
    defer chunks.deinit();

    const a = chunks.allocator();

    const keep = try a.alloc(u8, 16);
    const freed = try a.alloc(u8, 16);
    a.free(freed);

    const other = try a.alloc(u8, 32);
    try testing.expect(chunks.chunkOf(other.ptr, 0) != chunks.chunkOf(keep.ptr, 0));
    try testing.expectEqual(freed.ptr, (try a.alloc(u8, 16)).ptr);
}

test "fills a chunk, then cuts the next one from the same slot" {
    var chunks: ChunkAllocator = .init(testing.allocator);
    defer chunks.deinit();

    const a = chunks.allocator();

    const first = try a.alloc(u8, 1024);
    try testing.expect(@intFromPtr(first.ptr) % (64 << 10) == 0);
    for (1..64) |i| try testing.expectEqual(
        @intFromPtr(first.ptr) + i * 1024,
        @intFromPtr((try a.alloc(u8, 1024)).ptr),
    );

    const next = try a.alloc(u8, 1024);
    try testing.expectEqual(@intFromPtr(first.ptr) + (64 << 10), @intFromPtr(next.ptr));
}

test "a full chunk takes allocations again after a free" {
    var chunks: ChunkAllocator = .init(testing.allocator);
    defer chunks.deinit();

    const a = chunks.allocator();

    var slots: [64][]u8 = undefined;
    for (&slots) |*s| s.* = try a.alloc(u8, 1024);
    _ = try a.alloc(u8, 1024); // second chunk

    a.free(slots[10]);
    try testing.expectEqual(slots[10].ptr, (try a.alloc(u8, 1024)).ptr);
}

test "free list reuses the most recently freed slot" {
    var chunks: ChunkAllocator = .init(testing.allocator);
    defer chunks.deinit();

    const a = chunks.allocator();

    const keep = try a.alloc(u8, 32);
    const x = try a.alloc(u8, 32);
    const y = try a.alloc(u8, 32);
    a.free(x);
    a.free(y);
    try testing.expectEqual(y.ptr, (try a.alloc(u8, 32)).ptr);
    try testing.expectEqual(x.ptr, (try a.alloc(u8, 32)).ptr);
    _ = keep;
}

test "grows into a new slot when one is full" {
    var chunks: ChunkAllocator = .init(testing.allocator);
    defer chunks.deinit();

    const a = chunks.allocator();

    const per_span = (bucket_info[2].capacity - bucket_info[2].start) * pool_info[pool_count - 1].capacity;
    try testing.expectEqual(@as(u32, 240), per_span);
    for (0..per_span) |_| _ = try a.alloc(u8, max_size);
    try testing.expectEqual(@as(usize, 1), countSpans(&chunks, 2));
    _ = try a.alloc(u8, max_size);
    try testing.expectEqual(@as(usize, 2), countSpans(&chunks, 2));
}

test "thread-safe allocator from several threads" {
    var arena: heap.ArenaAllocator = .init(heap.page_allocator);
    defer arena.deinit();

    var chunks: ChunkAllocator = .initThreadSafe(arena.allocator(), testing.io);
    const a = chunks.threadSafeAllocator();

    const Worker = struct {
        fn run(alloc_: Allocator, seed: u8) !void {
            for (0..2000) |i| {
                const n = 1 + (i * 37 + seed) % 3000;
                const buf = try alloc_.alloc(u8, n);
                @memset(buf, seed);
                for (buf) |b| if (b != seed) return error.Corrupted;
                if (i % 3 != 0) alloc_.free(buf);
            }
        }
    };

    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*t, i| t.* = try .spawn(.{}, Worker.run, .{ a, @as(u8, @intCast(i + 1)) });
    for (threads) |t| t.join();
}
