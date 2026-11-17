const std = @import("std");
const Allocator = std.mem.Allocator;
const heap = std.heap;
const Io = std.Io;

const async = @import("async.zig");
const datastruct = @import("datastruct.zig");
const slotmap = datastruct.slotmap;
const Slotmap = slotmap.SlotMap;
const Key = slotmap.Key;
const DoublyLinkedList = datastruct.DoublyLinkedList;

const log = std.log.scoped(.core);

pub var core: Core = undefined;

pub const Core = struct {
    io: Io,
    arena: heap.ArenaAllocator,

    wakeup: async.Waker,
    wakeup_c: async.Completion,

    stop: async.Waker,
    stop_c: async.Completion,

    loop: async.Loop,
    store: Slotmap(Entity),
    future: Io.Future(void),
    root: *Entity,
};

pub fn init(gpa: Allocator, io: Io) !void {
    core = .{
        .io = io,
        .stop = undefined,
        .stop_c = .noop,
        .wakeup = undefined,
        .wakeup_c = .noop,
        .arena = .init(gpa),
        .loop = undefined,
        .future = undefined,
        .store = undefined,
        .root = undefined,
    };

    const arena = core.arena.allocator();
    errdefer core.arena.deinit();

    core.store = try .init(arena, 128);

    const key = try core.store.reserve();
    core.store.insert(key, .{
        .key = key,
        .kind = .root,
    });

    core.root = core.store.get(key) orelse unreachable;

    try core.loop.init(io);
    errdefer core.loop.deinit();

    core.wakeup = try core.loop.await(&core.wakeup_c, wakeupCallback);
    errdefer core.wakeup.deinit();

    core.stop = try core.loop.await(&core.stop_c, stopCallback);
    errdefer core.stop.deinit();

    core.future = try io.concurrent(run, .{});
}

pub fn run() void {
    core.loop.run(.until_done) catch {};
}

pub fn deinit() void {
    core.stop.wake() catch {};
    core.future.await(core.io);
    core.stop.deinit();
    core.wakeup.deinit();
    core.arena.deinit();
    core.loop.deinit();
}

fn stopCallback(_: *async.Completion, _: *async.Loop, res: anyerror!void) bool {
    res catch unreachable;

    core.loop.stop();

    return false;
}

fn wakeupCallback(_: *async.Completion, _: *async.Loop, res: anyerror!void) bool {
    res catch unreachable;

    return true;
}

pub const EntityKind = enum {
    root,
};

pub const Entity = struct {
    kind: EntityKind,
    next: ?*Entity = null,
    prev: ?*Entity = null,
    childrens: DoublyLinkedList(Entity) = .empty,
    parent: ?*Entity = null,
    key: Key,
};
