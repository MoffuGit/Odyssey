const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const chunk_pool = @import("chunk_pool.zig");
const ChunkAllocator = chunk_pool.ChunkAllocator;
const datastruct = @import("datastruct.zig");
const DoublyLinkedList = datastruct.DoublyLinkedList;

const DELIMITER: u8 = '|';

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

pub fn insert(self: *Properties, parent: ?*Property, str: []const u8) !*Property {
    const property = try self.create(str);

    const p = parent orelse self.root;
    p.childrens.append(property);
    property.parent = p;

    return property;
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

fn parseKeys(comptime str: []const u8) [countKeys(str)][]const u8 {
    var result: [countKeys(str)][]const u8 = undefined;
    var iter = std.mem.splitScalar(u8, str, DELIMITER);

    var i: usize = 0;
    while (iter.next()) |key| : (i += 1) {
        result[i] = key;
    }

    return result;
}

fn countKeys(comptime str: []const u8) usize {
    var iter = std.mem.splitScalar(u8, str, DELIMITER);
    var count: usize = 0;

    while (iter.next()) |_| {
        count += 1;
    }

    return count;
}

pub fn find(self: *Properties, comptime str: []const u8) ?*Property {
    const keys = parseKeys(str);
    var current: *Property = self.root;

    inline for (keys) |key| {
        var found: ?*Property = null;

        var iter = current.childrens.iterator();
        while (iter.next()) |child| {
            if (std.mem.eql(u8, child.str, key)) {
                found = child;
                break;
            }
        }

        current = found orelse return null;
    }

    return current;
}

pub const Property = struct {
    next: ?*Property = null,
    prev: ?*Property = null,
    parent: ?*Property = null,
    childrens: DoublyLinkedList(Property) = .empty,

    str: []u8,

    pub fn first(self: *Property) ?*Property {
        return self.childrens.first;
    }

    pub fn get(self: *Property, str: []const u8) ?*Property {
        var iter = self.childrens.iterator();
        while (iter.next()) |p| {
            if (std.mem.eql(u8, p.str, str)) {
                return p;
            }
        }
        return null;
    }

    pub fn into(self: *@This(), comptime T: type) ?T {
        return switch (@typeInfo(T)) {
            .int => std.fmt.parseInt(T, self.str, 10) catch null,
            else => null,
        };
    }
};

test "Property tree" {
    const gpa = testing.allocator;

    var properties: Properties = undefined;
    try properties.init(gpa);
    defer properties.deinit(gpa);

    const first = try properties.insert(null, "first");
    _ = try properties.insert(first, "100");

    const second = try properties.insert(null, "second");
    const third = try properties.insert(second, "third");

    try testing.expectEqual(2, properties.root.childrens.len());

    try testing.expectEqual(first, properties.root.get("first"));
    try testing.expectEqual(second, properties.root.get("second"));
    try testing.expectEqual(third, properties.find("second|third"));

    try testing.expectEqual(100, first.first().?.into(u8));
}
