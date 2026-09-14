// SOURCE: https://github.com/EpicGames/raddebugger
// LICENSE: [RADDEBUGGER]

const std = @import("std");
const math = @import("../math.zig");
const rng = math.rng;
const linked_list = @import("linked_list.zig");
const Allocator = std.mem.Allocator;
const testing = std.testing;

pub const MemMapRng = struct {
    vaddr_range: [2]u64,
    base: [*]u8,
    next: ?*MemMapRng = null,
};

pub const MemMap = struct {
    ranges: linked_list.SinglyLinkedList(MemMapRng) = .empty,

    pub fn push(self: *MemMap, vaddr_range: [2]u64, base: *anyopaque, alloc: Allocator) !void {
        const range = try alloc.create(MemMapRng);
        range.* = .{ .base = @ptrCast(base), .vaddr_range = vaddr_range };

        self.ranges.append(range);
    }

    pub fn read(self: *const MemMap, range: [2]u64, dest: []u8) u64 {
        var dest_vaddr = range[0];
        while (true) {
            var found = false;
            const start_vaddr = dest_vaddr;
            var node = self.ranges.head;
            while (node) |n| : (node = n.next) {
                if (rng.contains(n.vaddr_range, dest_vaddr)) {
                    const src_off = dest_vaddr - n.vaddr_range[0];
                    const possible = n.vaddr_range[1] - dest_vaddr;
                    const needed = range[1] - dest_vaddr;
                    const to_read = @min(needed, possible);

                    const dest_off: usize = @intCast(dest_vaddr - range[0]);
                    const len: usize = @intCast(to_read);
                    const off: usize = @intCast(src_off);
                    @memcpy(dest[dest_off .. dest_off + len], n.base[off .. off + len]);

                    dest_vaddr += to_read;
                    found = true;
                }
            }
            if (!found or dest_vaddr == start_vaddr) break;
        }

        return dest_vaddr - range[0];
    }

    pub fn slice(self: *const MemMap, range: [2]u64, alloc: Allocator) ![]u8 {
        const buffer = try alloc.alloc(u8, rng.dim(range));
        _ = self.read(range, buffer);
        return buffer;
    }
};

test "Memory Map Simple Test" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var map: MemMap = .{};

    var buffer: [16]u8 = .{5} ** 5 ++ .{0} ** 11;
    try map.push(.{ 0, buffer.len }, &buffer, arena.allocator());

    var new_buffer: [16]u8 = undefined;
    const readed = map.read(.{ 0, buffer.len }, &new_buffer);
    try testing.expectEqual(buffer.len, readed);
    try testing.expectEqual(buffer, new_buffer);
}

test "Memory Map Simple Slice Test" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var map: MemMap = .{};

    var buffer: [16]u8 = .{5} ** 5 ++ .{0} ** 11;
    try map.push(.{ 0, buffer.len }, &buffer, arena.allocator());

    const slice = try map.slice(.{ 0, buffer.len }, arena.allocator());

    try testing.expectEqualStrings(&buffer, slice);
}

test "Memory Map: small buffers read all at once" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var map: MemMap = .{};

    // Three 4-byte buffers at contiguous vaddr ranges.
    var buf_a: [4]u8 = .{ 0x10, 0x11, 0x12, 0x13 };
    var buf_b: [4]u8 = .{ 0x20, 0x21, 0x22, 0x23 };
    var buf_c: [4]u8 = .{ 0x30, 0x31, 0x32, 0x33 };
    try map.push(.{ 0, buf_a.len }, &buf_a, arena.allocator());
    try map.push(.{ 4, 4 + buf_b.len }, &buf_b, arena.allocator());
    try map.push(.{ 8, 8 + buf_c.len }, &buf_c, arena.allocator());

    var dest: [12]u8 = undefined;
    const readed = map.read(.{ 0, 12 }, &dest);
    try testing.expectEqual(12, readed);

    const expected: [12]u8 = .{
        0x10, 0x11, 0x12, 0x13,
        0x20, 0x21, 0x22, 0x23,
        0x30, 0x31, 0x32, 0x33,
    };
    try testing.expectEqual(expected, dest);
}

test "Memory Map: two medium buffers read into one chunk" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var map: MemMap = .{};

    // Two 64-byte buffers at contiguous vaddr ranges.
    // Each byte stores its own vaddr so verification is trivial.
    var buf_a: [64]u8 = undefined;
    var buf_b: [64]u8 = undefined;
    for (0..64) |i| buf_a[i] = @intCast(i);
    for (0..64) |i| buf_b[i] = @intCast(i + 64);

    try map.push(.{ 0, buf_a.len }, &buf_a, arena.allocator());
    try map.push(.{ 64, 64 + buf_b.len }, &buf_b, arena.allocator());

    var dest: [128]u8 = undefined;
    const readed = map.read(.{ 0, 128 }, &dest);
    try testing.expectEqual(128, readed);

    for (0..128) |i| try testing.expectEqual(@as(u8, @intCast(i)), dest[i]);
}

test "Memory Map: two medium buffers read in smaller chunks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var map: MemMap = .{};

    var buf_a: [64]u8 = undefined;
    var buf_b: [64]u8 = undefined;
    for (0..64) |i| buf_a[i] = @intCast(i);
    for (0..64) |i| buf_b[i] = @intCast(i + 64);

    try map.push(.{ 0, buf_a.len }, &buf_a, arena.allocator());
    try map.push(.{ 64, 64 + buf_b.len }, &buf_b, arena.allocator());

    // Read in 32-byte chunks — some chunks straddle the two buffers.
    const chunk_size: u64 = 32;
    var offset: u64 = 0;
    while (offset < 128) : (offset += chunk_size) {
        var chunk: [32]u8 = undefined;
        const readed = map.read(.{ offset, offset + chunk_size }, &chunk);
        try testing.expectEqual(chunk_size, readed);

        for (0..chunk_size) |i| {
            try testing.expectEqual(@as(u8, @intCast(offset + i)), chunk[i]);
        }
    }
}

test "Memory Map: overlapping ranges, first inserted takes priority" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var map: MemMap = .{};

    // A covers 0-8 (first inserted, takes priority in the overlap).
    // B covers 0-16 (second inserted, overlaps A in 0-8, extends to 16).
    var buf_a: [8]u8 = .{0xAA} ** 8;
    var buf_b: [16]u8 = .{0xBB} ** 16;
    try map.push(.{ 0, buf_a.len }, &buf_a, arena.allocator());
    try map.push(.{ 0, buf_b.len }, &buf_b, arena.allocator());

    var dest: [16]u8 = undefined;
    const readed = map.read(.{ 0, 16 }, &dest);
    try testing.expectEqual(16, readed);

    // Overlap region 0-8 comes from A (priority), 8-16 comes from B.
    for (0..8) |i| try testing.expectEqual(@as(u8, 0xAA), dest[i]);
    for (8..16) |i| try testing.expectEqual(@as(u8, 0xBB), dest[i]);
}

test "Memory Map: gap stops the read at last valid byte" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var map: MemMap = .{};

    // A covers 0-8, B covers 16-24. Gap from 8-16.
    var buf_a: [8]u8 = .{0xAA} ** 8;
    var buf_b: [8]u8 = .{0xBB} ** 8;
    try map.push(.{ 0, buf_a.len }, &buf_a, arena.allocator());
    try map.push(.{ 16, 16 + buf_b.len }, &buf_b, arena.allocator());

    var dest: [24]u8 = undefined;
    const readed = map.read(.{ 0, 24 }, &dest);
    // Read stops at the gap — only 8 bytes read.
    try testing.expectEqual(8, readed);

    for (0..8) |i| try testing.expectEqual(@as(u8, 0xAA), dest[i]);
}
