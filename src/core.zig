const std = @import("std");
const Allocator = std.mem.Allocator;
const heap = std.heap;
const Io = std.Io;
const Loop = @import("loop.zig");
const datastruct = @import("datastruct.zig");
const slotmap = datastruct.slotmap;
const Slotmap = slotmap.SlotMap;
const Key = slotmap.Key;
const DoublyLinkedList = datastruct.DoublyLinkedList;

const log = std.log.scoped(.core);

pub var core: Core = undefined;

pub const Core = struct {
    arena: heap.ArenaAllocator,
    loop: Loop,
    store: Slotmap(Entity),
    future: Io.Future(void),
};

pub fn init(gpa: Allocator, io: Io) !void {
    core = .{
        .arena = .init(gpa),
        .loop = undefined,
        .future = undefined,
        .store = undefined,
    };

    const arena = core.arena.allocator();
    errdefer core.arena.deinit();

    core.store = try .init(arena, 128);

    try core.loop.init(io);
    errdefer core.loop.deinit();
}

pub fn deinit() void {
    core.arena.deinit();
    core.loop.deinit();
}

pub const Entity = struct {
    next: ?*Entity,
    prev: ?*Entity,
    childrens: DoublyLinkedList(Entity),
    parent: ?*Entity,
    key: Key,
};
