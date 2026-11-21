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

    try self.chunks.init(alloc, &.{.{ .capacity = 128, .chunk_size = 8 }});
    errdefer self.chunks.deinit(alloc);

    self.root = self.create(null, "root");
}

pub fn deinit(self: *Properties, alloc: Allocator) void {
    self.chunks.deinit(alloc);
}

pub fn create(self: *Properties, str: []const u8) !*Property {
    const chunks = self.chunks.allocator();
    const property = try chunks.create(Property);

    property.str = try chunks.dupe(u8, str);

    return property;
}

pub fn insert(self: *Properties, parent: ?*Property, str: []const u8) !void {
    const property = try self.create(str);

    parent.childrens.append(property);
    property.parent = parent orelse self.root;
}

pub fn prune(self: *Properties, property: *Property) void {
    var iter = property.childrens.iterator();
    while (iter.next()) |p| {
        self.destroy(p);
    }
}

pub fn destroy(self: *Properties, property: *Property) void {
    const chunks = self.chunks.allocator();

    if (property.parent) |p| {
        p.childrens.remove(property);
    }

    var iter = property.childrens.iterator();
    while (iter.next()) |p| {
        self.destroy(p);
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
    properties.init(gpa);
    defer properties.deinit(gpa);
}
