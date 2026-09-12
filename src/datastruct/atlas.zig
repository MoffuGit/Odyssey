//! The implementation is based on "A Thousand Ways to Pack the Bin - A
//! Practical Approach to Two-Dimensional Rectangle Bin Packing" by Jukka
//! Jylänki.
//! My main reference was Jukka Jylänki Guillotine
//! implementation: (https://github.com/juj/RectangleBinPack/tree/master).
//!
//! I used Best Short Side Fit (BSSF)
//! and Shorter Axis Split Rule (SAS)
//!
//! Other references:
//! Ghostty (https://github.com/ghostty-org/ghostty/tree/main)
//! Exploring rectangle packing algorithms (https://www.david-colson.com/2020/03/10/exploring-rect-packing.html)

const std = @import("std");
const Allocator = std.mem.Allocator;
const heap = std.heap;
const testing = std.testing;

const Atlas = @This();

arena: heap.ArenaAllocator,
buffer: []u8,
width: u64,
height: u64,

pub fn init(self: *Atlas, w: u64, h: u64, alloc: Allocator) !void {
    self.* = .{ .width = w, .height = h, .arena = .init(alloc), .buffer = undefined };

    const arena = self.arena.allocator();
    errdefer self.arena.deinit();

    self.buffer = try arena.alloc(u8, w * h);
}

pub fn deinit(self: *Atlas) void {
    self.arena.deinit();
}

test "Basic Operations" {
    const gpa = testing.allocator;
    var atlas: Atlas = undefined;
    try atlas.init(50, 50, gpa);
    defer atlas.deinit();
}
