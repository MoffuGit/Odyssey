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
const DoublyLinkedList = @import("doubly_linked_list.zig").DoublyLinkedList;

const Atlas = @This();

arena: heap.ArenaAllocator,
buffer: []u8,
width: u64,
height: u64,
regions: DoublyLinkedList(RegionNode),
free: DoublyLinkedList(RegionNode),

pub fn init(self: *Atlas, w: u64, h: u64, alloc: Allocator) !void {
    self.* = .{
        .width = w,
        .height = h,
        .arena = .init(alloc),
        .buffer = undefined,
        .regions = .empty,
        .free = .empty,
    };

    const arena = self.arena.allocator();
    errdefer self.arena.deinit();

    self.buffer = try arena.alloc(u8, w * h);
    const free = try arena.create(RegionNode);
    free.* = .{
        .region = .{
            .width = w,
            .height = h,
            .x = 0,
            .y = 0,
        },
        .next = null,
        .prev = null,
    };

    self.regions.append(free);
}

pub fn reserve(self: *Atlas, width: u64, height: u64) !Region {
    var region: Region = undefined;

    const best = bkl: {
        var best: ?*RegionNode = null;
        var score: u64 = std.math.maxInt(u64);

        var free = self.regions.first;

        while (free) |f| : (free = f.next) {
            if (width <= f.region.width and height <= f.region.height) {
                const left_width = f.region.width - width;
                const left_height = f.region.height - height;
                const left = @min(left_width, left_height);

                if (left < score) {
                    best = f;
                    score = left;

                    region = .{
                        .x = f.region.x,
                        .y = f.region.y,
                        .width = width,
                        .height = height,
                    };
                }
            }

            if (width <= f.region.height and height <= f.region.width) {
                const left_width = f.region.width - height;
                const left_height = f.region.height - width;
                const left = @min(left_width, left_height);

                if (left < score) {
                    best = f;
                    score = left;

                    region = .{
                        .x = f.region.x,
                        .y = f.region.y,
                        .width = height,
                        .height = width,
                    };
                }
            }
        }

        break :bkl best orelse return error.Full;
    };

    self.regions.remove(best);
    self.free.append(best);

    const free_region = best.region;

    var bottom: Region = undefined;
    var right: Region = undefined;

    if (free_region.width <= free_region.height) {
        bottom = .{
            .x = free_region.x,
            .y = free_region.y + region.height,
            .width = free_region.width,
            .height = free_region.height - region.height,
        };
        right = .{
            .x = free_region.x + region.width,
            .y = free_region.y,
            .width = free_region.width - region.width,
            .height = region.height,
        };
    } else {
        bottom = .{
            .x = free_region.x + region.width,
            .y = free_region.y + region.height,
            .width = free_region.width - region.width,
            .height = free_region.height - region.height,
        };
        right = .{
            .x = free_region.x + region.width,
            .y = free_region.y,
            .width = free_region.width - region.width,
            .height = free_region.height,
        };
    }

    if (bottom.width > 0 and bottom.height > 0) {
        const node = self.free.pop() orelse try self.arena.allocator().create(RegionNode);
        node.* = .{ .region = bottom };
        self.regions.append(node);
    }

    if (right.width > 0 and right.height > 0) {
        const node = self.free.pop() orelse try self.arena.allocator().create(RegionNode);
        node.* = .{ .region = right };
        self.regions.append(node);
    }

    return region;
}

pub fn deinit(self: *Atlas) void {
    self.arena.deinit();
}

const Region = struct {
    x: u64,
    y: u64,
    width: u64,
    height: u64,
};

const RegionNode = struct {
    next: ?*RegionNode = null,
    prev: ?*RegionNode = null,

    region: Region,
};

test "Basic Operations" {
    const gpa = testing.allocator;
    var atlas: Atlas = undefined;
    try atlas.init(100, 100, gpa);
    defer atlas.deinit();

    const a = try atlas.reserve(60, 40);
    try expectRegion(a, 0, 0, 60, 40);

    try testing.expect(atlas.regions.len() == 2);
    try expectRegion(atlas.regions.first.?.region, 0, 40, 100, 60);
    try expectRegion(atlas.regions.first.?.next.?.region, 60, 0, 40, 40);
    try testing.expect(atlas.free.is_empty());

    const b = try atlas.reserve(40, 40);
    try expectRegion(b, 60, 0, 40, 40);
    try testing.expect(atlas.regions.len() == 1);
    try testing.expect(atlas.free.len() == 1);

    const c = try atlas.reserve(30, 20);
    try expectRegion(c, 0, 40, 20, 30);
    try testing.expect(atlas.regions.len() == 2);
    try expectRegion(atlas.regions.first.?.region, 20, 70, 80, 30);
    try expectRegion(atlas.regions.first.?.next.?.region, 20, 40, 80, 60);
    try testing.expect(atlas.free.is_empty());

    try testing.expectError(error.Full, atlas.reserve(100, 100));
}

fn expectRegion(region: Region, x: u64, y: u64, width: u64, height: u64) !void {
    try testing.expectEqual(x, region.x);
    try testing.expectEqual(y, region.y);
    try testing.expectEqual(width, region.width);
    try testing.expectEqual(height, region.height);
}
