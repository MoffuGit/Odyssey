const std = @import("std");
const atomic = std.atomic;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const datastruct = @import("datastruct.zig");
const slotmap = datastruct.slotmap;
pub const EntityId = slotmap.Key;
const typeId = @import("type_id.zig");
const TypeId = typeId.TypeId;
const TypeInfo = typeId.TypeInfo;

pub fn entityOrder(a: EntityId, b: EntityId) std.math.Order {
    const index_order = std.math.order(a.index, b.index);
    if (index_order != .eq) return index_order;

    return std.math.order(@backingInt(a.generation), @backingInt(b.generation));
}

pub const AnyEntity = struct {
    store: *EntityStore,
    type_id: TypeId,
    id: EntityId,

    pub fn init(store: *EntityStore, id: EntityId, type_id: TypeId) @This() {
        return .{ .store = store, .id = id, .type_id = type_id };
    }

    pub fn get(self: *const @This()) ?*anyopaque {
        return self.store.get(self.id);
    }

    pub fn into(self: *const @This(), comptime T: type) ?*T {
        assert(TypeInfo.init(T) == self.type_id);

        const ptr = self.get() orelse return null;
        return @ptrCast(@alignCast(ptr));
    }

    pub fn drop(self: @This()) void {
        const store = self.store;
        store.dropped.appendAssumeCapacity(self);
    }
};

pub const EntityStore = struct {
    const Entities = slotmap.SlotMap(*anyopaque);

    entities: Entities,
    dropped: std.ArrayList(AnyEntity),

    pub fn init(self: *@This(), arena: Allocator, capacity: usize) !void {
        var entities = try Entities.init(arena, capacity);
        errdefer entities.deinit(arena);

        self.* = .{
            .entities = entities,
            .dropped = try .initCapacity(arena, capacity),
        };
    }

    pub fn insert(self: *@This(), ptr: *anyopaque) EntityId {
        return self.entities.put(ptr) catch @panic("Entities Overflow");
    }

    pub fn get(self: *@This(), id: EntityId) ?*anyopaque {
        const ptr = self.entities.get(id) orelse return null;
        return ptr.*;
    }

    pub fn popDrop(self: *@This()) ?struct { *anyopaque, EntityId, TypeId } {
        const entity = self.dropped.pop() orelse return null;

        const ptr = self.entities.remove(entity.id) orelse @panic("Dropping non existing entity");

        return .{ ptr, entity.id, entity.type_id };
    }

    pub fn recycle(self: *@This(), id: EntityId) void {
        self.entities.recycle(id);
    }

    pub fn collect(self: *@This(), gpa: Allocator) !std.ArrayList(struct { *anyopaque, EntityId, TypeId }) {
        var entities: std.ArrayList(struct { *anyopaque, EntityId, TypeId }) = .empty;
        errdefer entities.deinit(gpa);

        while (self.dropped.pop()) |entity| {
            const ptr = self.entities.remove(entity.id) orelse continue;
            try entities.append(gpa, .{ ptr, entity.id, entity.type_id });
        }

        return entities;
    }
};

test "entity store returns inserted data and rejects wrong type" {
    const allocator = std.testing.allocator;
    var alloc = std.heap.ArenaAllocator.init(allocator);
    defer alloc.deinit();

    const arena = alloc.allocator();

    const A = struct { value: u32 };

    var store: EntityStore = undefined;
    try store.init(arena, 10);

    const ptr = try allocator.create(A);
    defer allocator.destroy(ptr);
    ptr.* = .{ .value = 42 };

    const id = store.insert(ptr);
    const any = AnyEntity.init(&store, id, TypeInfo.init(A));

    try std.testing.expectEqualDeep(@intFromPtr(ptr), @intFromPtr(store.get(any.id)));
    try std.testing.expectEqual(@as(u32, 42), any.into(A).?.value);
}

test "dropping arena-backed entity calls optional deinit" {
    const allocator = std.testing.allocator;

    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    const A = struct {
        deinit_called: *bool,

        pub fn deinit(self: *@This()) void {
            self.deinit_called.* = true;
        }
    };

    var store: EntityStore = undefined;
    try store.init(arena.allocator(), 10);

    var deinit_called = false;
    const ptr = try arena.allocator().create(A);
    ptr.* = .{ .deinit_called = &deinit_called };

    const id = store.insert(ptr);
    const any = AnyEntity.init(&store, id, TypeInfo.init(A));

    any.drop();

    const drop = store.popDrop().?;
    try std.testing.expectEqual(ptr, @as(*A, @ptrCast(@alignCast(drop.@"0"))));
    try std.testing.expect(drop.@"1".eql(id));
    try std.testing.expectEqual(TypeInfo.init(A), drop.@"2");

    drop.@"2".deinit(drop.@"0");
    try std.testing.expect(deinit_called);
}

test "destroyed entities recycle ids" {
    const allocator = std.testing.allocator;
    var alloc = std.heap.ArenaAllocator.init(allocator);
    defer alloc.deinit();

    const arena = alloc.allocator();

    const A = struct { value: u32 };

    var store: EntityStore = undefined;
    try store.init(arena, 10);

    const ptr = try allocator.create(A);
    defer allocator.destroy(ptr);
    ptr.* = .{ .value = 1 };

    const id = store.insert(ptr);
    const any = AnyEntity.init(&store, id, TypeInfo.init(A));

    any.drop();
    const drop = store.popDrop().?;
    try std.testing.expect(drop.@"1".eql(id));
    store.recycle(drop.@"1");

    const recycled = store.insert(ptr);
    try std.testing.expectEqual(id.index, recycled.index);
}
