const datastruct = @import("datastruct.zig");
const Atlas = datastruct.Atlas;
const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const TrueType = @import("true_type");
const embedded = @import("embedded.zig");

pub const Manager = @This();

atlas: Atlas,
atlas_gen: usize,

tt: TrueType,

pub fn init(self: *Manager, gpa: Allocator) !void {
    self.* = .{
        .atlas_gen = 0,
        .atlas = undefined,
        .tt = undefined,
    };

    try self.atlas.init(128, 128, gpa);
    errdefer self.atlas.deinit();

    self.tt = try TrueType.load(embedded.inter, 0);
}

pub fn deinit(self: *Manager) void {
    self.atlas.deinit();
}

pub const Glyph = struct {
    /// width of glyph in pixels
    width: u32,

    /// height of glyph in pixels
    height: u32,

    /// coordinates in the atlas of the top-left corner. These have to
    /// be normalized to be between 0 and 1 prior to use in shaders.
    atlas_x: u32,
    atlas_y: u32,
};

test "basic" {
    var manager: Manager = undefined;

    try manager.init(testing.allocator);
    defer manager.deinit();
}
