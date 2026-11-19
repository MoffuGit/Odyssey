const std = @import("std");
const Allocator = std.mem.Allocator;
const heap = std.heap;
const Io = std.Io;

const async = @import("async.zig");
const datastruct = @import("datastruct.zig");
const queue = datastruct.queue;
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

    events: queue.Spsc(Event),
    commands: queue.Spsc(Command),

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
        .commands = undefined,
        .events = undefined,
    };

    const arena = core.arena.allocator();
    errdefer core.arena.deinit();

    core.events = try .init(128, arena);
    core.commands = try .init(128, arena);

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

pub fn flush() void {
    var buffer: [128]Event = undefined;

    const len = core.events.pop(&buffer);

    for (buffer[0..len]) |evt| {
        log.debug("evt: {}", .{evt});
    }
}

fn stopCallback(_: *async.Completion, _: *async.Loop, res: anyerror!void) bool {
    res catch unreachable;

    core.loop.stop();

    return false;
}

fn wakeupCallback(_: *async.Completion, _: *async.Loop, res: anyerror!void) bool {
    res catch unreachable;

    var buffer: [128]Command = undefined;

    const read = core.commands.pop(&buffer);

    for (buffer[0..read]) |cmd| {
        log.debug("cmd: {}", .{cmd});

        core.events.push(.{ .id = cmd.id });
    }

    return true;
}

pub const Event = struct {
    id: u64,
};

pub const Command = struct {
    id: u64,
};

pub const EntityKind = enum {
    root,
    worktree,
};

pub const Entity = struct {
    key: Key,
    kind: EntityKind,
    next: ?*Entity = null,
    prev: ?*Entity = null,
    parent: ?*Entity = null,
    childrens: DoublyLinkedList(Entity) = .empty,
};
