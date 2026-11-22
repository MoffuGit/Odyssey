const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const chunk_pool = @import("chunk_pool.zig");
const ChunkAllocator = chunk_pool.ChunkAllocator;
const datastruct = @import("datastruct.zig");
const DoublyLinkedList = datastruct.DoublyLinkedList;

pub const Properties = @This();

chunks: ChunkAllocator,
root: *Property,

pub fn init(self: *Properties, alloc: Allocator) !void {
    self.* = .{
        .chunks = undefined,
        .root = undefined,
    };

    try self.chunks.init(alloc, &.{
        .{ .capacity = 128, .chunk_size = 8 },
        .{ .capacity = 128, .chunk_size = @sizeOf(Property) },
    });
    errdefer self.chunks.deinit(alloc);

    self.root = try self.create("root");
}

pub fn deinit(self: *Properties, alloc: Allocator) void {
    self.chunks.deinit(alloc);
}

pub fn create(self: *Properties, str: []const u8) !*Property {
    const chunks = self.chunks.allocator();
    const property = try chunks.create(Property);

    property.* = .{
        .str = try chunks.dupe(u8, str),
    };

    return property;
}

pub fn insert(self: *Properties, parent: ?*Property, str: []const u8) !void {
    const property = try self.create(str);

    const p = parent orelse self.root;
    p.childrens.append(property);
    property.parent = p;
}

pub fn prune(self: *Properties, property: *Property) void {
    var iter = property.childrens.iterator();
    while (iter.next()) |p| {
        self.remove(p);
    }
}

pub fn replace(self: *Properties, proterty: *Property, str: []const u8) !void {
    const chunks = self.chunks.allocator();
    const dupe = try chunks.dupe(u8, str);
    chunks.free(proterty.str);

    proterty.str = dupe;
}

pub fn remove(self: *Properties, property: *Property) void {
    const chunks = self.chunks.allocator();

    if (property.parent) |p| {
        p.childrens.remove(property);
    }

    var iter = property.childrens.iterator();
    while (iter.next()) |p| {
        self.remove(p);
    }

    chunks.destroy(property.str);
    chunks.destroy(property);
}

pub const Property = struct {
    next: ?*Property = null,
    prev: ?*Property = null,
    parent: ?*Property = null,
    childrens: DoublyLinkedList(Property) = .empty,

    str: []u8,
};

test "Property tree" {
    const gpa = testing.allocator;

    var properties: Properties = undefined;
    try properties.init(gpa);
    defer properties.deinit(gpa);

    try properties.insert(null, "first");
    try properties.insert(null, "second");

    var iter = properties.root.childrens.iterator();

    try testing.expectEqualStrings("first", iter.next().?.str);
    try testing.expectEqualStrings("second", iter.next().?.str);
}
