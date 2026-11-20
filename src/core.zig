const std = @import("std");
const Allocator = std.mem.Allocator;
const heap = std.heap;
const Io = std.Io;

const async = @import("async.zig");
const chunk_pool = @import("chunk_pool.zig");
const ChunkAllocator = chunk_pool.ChunkAllocator;
const datastruct = @import("datastruct.zig");
const queue = datastruct.queue;
const slotmap = datastruct.slotmap;
const Slotmap = slotmap.SlotMap;
const Key = slotmap.Key;
const DoublyLinkedList = datastruct.DoublyLinkedList;
const HashTable = datastruct.HashTable;
const SinglyLinkedList = datastruct.SinglyLinkedList;
const Worktree = @import("worktree.zig");
const scanner = @import("worktree/scanner.zig");

const log = std.log.scoped(.core);

pub var core: Core = undefined;

pub const Core = struct {
    gpa: Allocator,
    chunks: ChunkAllocator,
    arena: heap.ArenaAllocator,

    io: Io,
    future: Io.Future(void),
    loop: async.Loop,

    wakeup: async.Waker,
    wakeup_c: async.Completion,

    stop: async.Waker,
    stop_c: async.Completion,

    events: queue.Spsc(Event),
    messages: queue.Spsc(Message),

    commands_arena: heap.ArenaAllocator,
    commands: SinglyLinkedList(Command),
    entities: Slotmap(Entity),
    root: *Entity,
    frame: u64,
    worktree_cache: HashTable(Key, Worktree, Worktree.Context),
};

pub fn init(gpa: Allocator, io: Io) !void {
    core = .{
        .gpa = gpa,
        .chunks = undefined,
        .worktree_cache = undefined,
        .frame = 0,
        .messages = undefined,
        .io = io,
        .stop = undefined,
        .stop_c = .noop,
        .wakeup = undefined,
        .wakeup_c = .noop,
        .arena = .init(gpa),
        .loop = undefined,
        .future = undefined,
        .entities = undefined,
        .root = undefined,
        .commands = .empty,
        .events = undefined,
        .commands_arena = .init(gpa),
    };

    try core.loop.init(io);
    errdefer core.loop.deinit();

    const arena = core.arena.allocator();
    errdefer core.arena.deinit();

    try core.chunks.init(
        arena,
        &.{.{ .capacity = 128, .chunk_size = @sizeOf(Worktree) }},
    );

    core.events = try .init(128, arena);
    core.messages = try .init(128, arena);

    core.entities = try .init(arena, 128);

    try core.worktree_cache.init(64, .{}, arena);

    const key = try core.entities.reserve();
    core.entities.insert(key, .{
        .key = key,
        .kind = .root,
    });

    core.root = core.entities.get(key) orelse unreachable;

    core.wakeup = try core.loop.await(&core.wakeup_c, wakeupCallback);
    errdefer core.wakeup.deinit();

    core.stop = try core.loop.await(&core.stop_c, stopCallback);
    errdefer core.stop.deinit();

    core.future = try io.concurrent(run, .{});
}

pub fn deinit() void {
    core.stop.wake() catch {};
    core.future.await(core.io);

    var it = core.worktree_cache.iterator();
    while (it.next()) |cached| {
        cached.snapshot.deinit();
    }

    core.stop.deinit();
    core.wakeup.deinit();
    core.commands_arena.deinit();
    core.arena.deinit();
    core.loop.deinit();
}

pub fn run() void {
    core.loop.run(.until_done) catch {};
}

pub fn flush() !void {
    var buffer: [128]Event = undefined;
    const len = core.events.pop(&buffer);

    for (buffer[0..len]) |evt| {
        switch (evt) {
            .echo => |id| log.debug("echo: {}", .{id}),
        }
    }

    while (core.commands.pop()) |cmd| {
        switch (cmd.params) {
            .open_worktree => |path| {
                const key = insert(core.root, .worktree);
                try pushMsg(.{ .open_worktree = .{ .key = key, .abs_path = path } });
            },
            .close_worktree => |key| {
                const chunks = core.chunks.allocator();

                if (core.worktree_cache.remove(key)) |cached| {
                    cached.snapshot.deinit();
                    chunks.destroy(cached);
                }

                remove(key);

                try pushMsg(.{ .close_worktree = key });
            },
        }
    }

    core.frame += 1;
    _ = core.commands_arena.reset(.retain_capacity);

    try core.wakeup.wake();
}

pub fn pushMsg(msg: Message) !void {
    core.messages.push(try msg.clone());
}

pub fn pushCmd(params: Params) !void {
    const arena = core.commands_arena.allocator();
    const cmd = try arena.create(Command);
    cmd.* = .{ .params = try params.clone() };
    core.commands.append(cmd);
}

fn insert(parent: ?*Entity, kind: EntityKind) Key {
    const key = core.entities.reserve() catch unreachable;

    core.entities.insert(key, .{
        .key = key,
        .kind = kind,
        .parent = parent,
    });

    if (parent) |p| {
        p.childrens.append(core.entities.get(key) orelse unreachable);
    }

    return key;
}

fn remove(key: Key) void {
    const entity = core.entities.get(key) orelse return;

    if (entity.parent) |p| {
        p.childrens.remove(entity);
    }

    var iter = entity.childrens.iterator();
    while (iter.next()) |child| remove(child.key);

    core.entities.remove(key);
}

pub fn worktree(key: Key) !?*const Worktree {
    if (core.entities.get(key) == null) return null;

    if (core.worktree_cache.get(key)) |cached| {
        if (scanner.generation(key) != cached.generation) {
            const published = try scanner.clone(key, core.gpa) orelse return null;

            cached.snapshot.deinit();
            cached.generation = published.generation;
            cached.status = published.status;
            cached.snapshot = published.snapshot;
        }

        return cached;
    }

    const chunks = core.chunks.allocator();

    var published = try scanner.clone(key, core.gpa) orelse return null;
    errdefer published.snapshot.deinit();

    const cached = try chunks.create(Worktree);
    cached.* = .{
        .key = key,
        .generation = published.generation,
        .status = published.status,
        .snapshot = published.snapshot,
    };
    core.worktree_cache.insert(key, cached);

    return cached;
}

fn stopCallback(_: *async.Completion, _: *async.Loop, res: anyerror!void) bool {
    res catch unreachable;

    core.loop.stop();

    return false;
}

fn wakeupCallback(_: *async.Completion, _: *async.Loop, res: anyerror!void) bool {
    res catch unreachable;

    var buffer: [128]Message = undefined;

    const read = core.messages.pop(&buffer);

    for (buffer[0..read]) |msg| {
        defer msg.free();

        switch (msg) {
            .echo => |id| core.events.push(.{ .echo = id }),
            .open_worktree => |data| {
                scanner.open(data.key, data.abs_path) catch |err| {
                    log.err("Open worktree path=\"{s}\" err={}", .{ data.abs_path, err });
                };
            },
            .close_worktree => |key| scanner.close(key),
        }
    }

    return true;
}

pub const Message = union(enum) {
    echo: u64,
    open_worktree: struct {
        key: Key,
        abs_path: []const u8,
    },
    close_worktree: Key,

    fn clone(self: *const Message) !Message {
        return switch (self.*) {
            .echo, .close_worktree => self.*,
            .open_worktree => |data| .{
                .open_worktree = .{
                    .abs_path = try core.gpa.dupe(u8, data.abs_path),
                    .key = data.key,
                },
            },
        };
    }

    fn free(self: *const Message) void {
        switch (self.*) {
            .echo, .close_worktree => {},
            .open_worktree => |data| core.gpa.free(data.abs_path),
        }
    }
};

pub const Event = union(enum) {
    echo: u64,
};

pub const Params = union(enum) {
    open_worktree: []const u8,
    close_worktree: Key,

    fn clone(self: *const Params) !Params {
        const arena = core.commands_arena.allocator();

        return switch (self.*) {
            .close_worktree => self.*,
            .open_worktree => |path| .{ .open_worktree = try arena.dupe(u8, path) },
        };
    }
};

pub const Command = struct {
    next: ?*Command = null,
    params: Params,
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
