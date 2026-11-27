const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const ChunkAllocator = @import("chunk_allocator.zig");
const datastruct = @import("datastruct.zig");
const DoublyLinkedList = datastruct.DoublyLinkedList;

const DELIMITER: u8 = '.';

var config: Configuration = undefined;

pub const Configuration = struct {
    chunks: ChunkAllocator,
    root: *Property,
    generation: u64,
};

pub fn init(gpa: Allocator) !void {
    config = .{
        .generation = 0,
        .chunks = .init(gpa),
        .root = undefined,
    };

    errdefer config.chunks.deinit();

    config.root = try create("root");
}

pub fn deinit() void {
    config.chunks.deinit();
}

pub fn create(str: []const u8) !*Property {
    const chunks = config.chunks.allocator();
    const property = try chunks.create(Property);

    property.* = .{
        .str = try chunks.dupe(u8, str),
        .id = config.generation,
    };

    config.generation += 1;

    return property;
}

pub fn insert(parent: ?*Property, str: []const u8) !*Property {
    const property = try create(str);

    const p = parent orelse config.root;
    p.childrens.append(property);
    property.parent = p;

    return property;
}

pub fn prune(property: *Property) void {
    var iter = property.childrens.iterator();
    while (iter.next()) |p| {
        config.remove(p);
    }
}

pub fn replace(proterty: *Property, str: []const u8) !void {
    const chunks = config.chunks.allocator();
    const dupe = try chunks.dupe(u8, str);
    chunks.free(proterty.str);

    proterty.str = dupe;
}

pub fn remove(property: *Property) void {
    const chunks = config.chunks.allocator();

    if (property.parent) |p| {
        p.childrens.remove(property);
    }

    var iter = property.childrens.iterator();
    while (iter.next()) |p| {
        config.remove(p);
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

pub fn find(comptime str: []const u8) ?*Property {
    const keys = parseKeys(str);
    var current: *Property = config.root;

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
    id: u64,

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

test "Config tree" {
    const gpa = testing.allocator;

    try init(gpa);
    defer deinit();

    const first = try insert(null, "first");
    _ = try insert(first, "100");

    const second = try insert(null, "second");
    const third = try insert(second, "third");

    try testing.expectEqual(2, config.root.childrens.len());

    try testing.expectEqual(first, config.root.get("first"));
    try testing.expectEqual(second, config.root.get("second"));
    try testing.expectEqual(third, find("second|third"));

    try testing.expectEqual(100, first.first().?.into(u8));
}
