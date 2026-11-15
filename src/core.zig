const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Io = std.Io;
const assert = std.debug.assert;
const testing = std.testing;

const chunk_pool = @import("chunk_pool.zig");
const ChunkAllocator = chunk_pool.ChunkAllocator;
const datastruct = @import("datastruct.zig");
const DoublyLinkedList = datastruct.DoublyLinkedList;
const slotmap = datastruct.slotmap;
const SlotMap = slotmap.SlotMap;
pub const Key = slotmap.Key;
const type_id = @import("type_id.zig");
const TypeId = type_id.TypeId;
const TypeInfo = type_id.TypeInfo;

const log = std.log.scoped(.core);

const CHUNK_SIZES = [_]u32{ 64, 128, 256, 512, 2048 };

pub const Options = struct {
    capacity: u32 = 256,
};

pub const Root = struct {};

pub const Core = @This();

io: Io,
gpa: Allocator,
arena: ArenaAllocator,
chunks: ChunkAllocator,
frame: u64,
store: SlotMap(Entity),
root: *Entity,

pub fn init(self: *Core, gpa: Allocator, io: Io, opts: Options) !void {
    self.* = .{
        .io = io,
        .gpa = gpa,
        .arena = .init(gpa),
        .chunks = undefined,
        .frame = 0,
        .store = undefined,
        .root = undefined,
    };
    errdefer self.arena.deinit();

    const arena = self.arena.allocator();

    var pools: [CHUNK_SIZES.len]chunk_pool.Options = undefined;
    for (&pools, CHUNK_SIZES) |*pool, size| {
        pool.* = .{ .capacity = opts.capacity, .chunk_size = size };
    }

    self.store = try .init(arena, opts.capacity);
    try self.chunks.init(arena, &pools);
    self.root = try self.create(null, Root, .{});
}

pub fn deinit(self: *Core) void {
    self.destroy(self.root);
    self.arena.deinit();
}

fn create(self: *Core, parent: ?*Entity, comptime T: type, value: T) Error!*Entity {
    const chunks = self.chunks.allocator();
    const ptr = try chunks.create(T);
    errdefer chunks.destroy(ptr);
    ptr.* = value;

    const key = try self.store.reserve();

    self.store.insert(key, .{
        .parent = null,
        .type_id = TypeInfo.init(T),
        .arena = .init(self.gpa),
        .childrens = .empty,
        .key = key,
        .ptr = ptr,
        .next = null,
        .prev = null,
    });

    const entity = self.store.get(key) orelse unreachable;

    if (parent) |p| {
        p.childrens.append(entity);
        entity.parent = parent;
    }

    return entity;
}

pub const Error = Allocator.Error || error{Overflow};

pub const Entity = struct {
    key: Key,
    type_id: TypeId,
    ptr: *anyopaque,
    arena: ArenaAllocator,
    childrens: DoublyLinkedList(Entity),
    parent: ?*Entity,
    next: ?*Entity,
    prev: ?*Entity,

    pub fn cast(self: *Entity, comptime T: type) *T {
        assert(self.type_id == TypeInfo.init(T));
        return @ptrCast(@alignCast(self.ptr));
    }
};

pub fn get(self: *Core, key: Key) ?*Entity {
    return self.store.get(key);
}

pub fn destroy(self: *Core, entity: *Entity) void {
    const chunks = self.chunks.allocator();

    if (entity.parent) |p| {
        p.childrens.remove(entity);
    }

    var iter = entity.childrens.iterator();
    while (iter.next()) |child| self.destroy(child);

    entity.arena.deinit();
    entity.type_id.destroy(entity.ptr, chunks);

    self.store.remove(entity.key);
}

pub fn prune(self: *Core, entity: *Entity) void {
    var iter = entity.childrens.iterator();
    while (iter.next()) |child| self.destroy(child);
}

test "a dropped entity's handle stays dead after its slot is reused" {
    const Value = struct { value: u32 };

    var core: Core = undefined;
    try core.init(testing.allocator, testing.io, .{ .capacity = 2 });
    defer core.deinit();

    const first = try core.create(core.root, Value, .{ .value = 1 });
    const key = first.key;
    try testing.expectEqual(1, core.get(key).?.cast(Value).value);
    core.destroy(first);

    try testing.expectEqual(null, core.get(key));

    const second = try core.create(core.root, Value, .{ .value = 2 });
    const key_2 = second.key;

    try testing.expectEqual(key.index, key_2.index);
    try testing.expectEqual(null, core.get(key));
    try testing.expectEqual(2, core.get(key_2).?.cast(Value).value);
}

test "dropping an entity destroys its subtree, children first" {
    const Node = struct {
        id: u8,
    };

    var core: Core = undefined;
    try core.init(testing.allocator, testing.io, .{});
    defer core.deinit();

    const a = try core.create(core.root, Node, .{ .id = 'a' });
    _ = try core.create(a, Node, .{ .id = 'b' });
    const c = try core.create(a, Node, .{ .id = 'c' });
    const d = try core.create(c, Node, .{ .id = 'd' });
    const d_key = d.key;
    const e = try core.create(core.root, Node, .{ .id = 'e' });
    const e_key = e.key;

    _ = try c.arena.allocator().alloc(u8, 4096);

    core.destroy(a);

    try testing.expectEqual(null, core.get(d_key));

    const childrens = core.root.childrens;
    try testing.expectEqual(childrens.first, childrens.last);
    try testing.expectEqual(childrens.first, core.get(e_key));
}
