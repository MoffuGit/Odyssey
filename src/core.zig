const std = @import("std");
const Allocator = std.mem.Allocator;
const heap = std.heap;
const Io = std.Io;
const testing = std.testing;

const async = @import("async.zig");
const global = @import("global.zig");
const Bench = @import("bench.zig");
const ChunkAllocator = @import("chunk_allocator.zig");
const datastruct = @import("datastruct.zig");
const queue = datastruct.queue;
const slotmap = datastruct.slotmap;
const Slotmap = slotmap.SlotMap;
const Key = slotmap.Key;
const DoublyLinkedList = datastruct.DoublyLinkedList;
const HashTable = datastruct.HashTable;
const SinglyLinkedList = datastruct.SinglyLinkedList;
const scanner = @import("scanner.zig");
const scheduler = @import("scheduler.zig");

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

    frame_arena: heap.ArenaAllocator,
    commands: SinglyLinkedList(Command),
    entities: Slotmap(Entity),
    root: *Entity,
    frame: u64,
    worktree_cache: HashTable(Key, WorktreeCache, WorktreeCache.Context),
};

pub fn init(gpa: Allocator, io: Io) !void {
    core = .{
        .gpa = gpa,
        .chunks = .init(gpa),
        .arena = .init(gpa),
        .worktree_cache = undefined,
        .frame = 0,
        .messages = undefined,
        .io = io,
        .stop = undefined,
        .stop_c = .noop,
        .wakeup = undefined,
        .wakeup_c = .noop,
        .loop = undefined,
        .future = undefined,
        .entities = undefined,
        .root = undefined,
        .commands = .empty,
        .events = undefined,
        .frame_arena = .init(gpa),
    };

    const arena = core.arena.allocator();
    errdefer core.arena.deinit();

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

    try scheduler.init(gpa, io);
    errdefer scheduler.deinit();

    try core.loop.init(io);
    errdefer core.loop.deinit();

    core.wakeup = try core.loop.await(&core.wakeup_c, wakeupCallback);
    errdefer core.wakeup.deinit();

    core.stop = try core.loop.await(&core.stop_c, struct {
        fn stop(_: *async.Completion, _: *async.Loop, res: anyerror!void) bool {
            res catch unreachable;

            core.loop.stop();

            return false;
        }
    }.stop);
    errdefer core.stop.deinit();

    var started: Io.Event = .unset;
    var result: anyerror!void = {};

    var future = try core.io.concurrent(run, .{ &started, &result });
    started.waitUncancelable(core.io);

    result catch |err| {
        future.await(core.io);
        return err;
    };

    core.future = future;
}

pub fn deinit() void {
    core.stop.wake() catch {};
    core.future.await(core.io);

    scanner.stop();
    scheduler.deinit();
    scanner.deinit();

    core.stop.deinit();
    core.wakeup.deinit();
    core.loop.deinit();

    var messages: [128]Message = undefined;
    const messages_len = core.messages.pop(&messages);
    for (messages[0..messages_len]) |msg| msg.free();

    var events: [128]Event = undefined;
    const events_len = core.events.pop(&events);
    for (events[0..events_len]) |*evt| switch (evt.*) {
        .echo => {},
        .worktree => |*data| data.snapshot.deinit(),
    };

    var iter = core.worktree_cache.iterator();
    while (iter.next()) |cached| {
        cached.snapshot.deinit();
    }

    core.frame_arena.deinit();
    core.arena.deinit();
    core.chunks.deinit();
}

fn run(started: *Io.Event, result: *anyerror!void) void {
    scanner.init(core.gpa, core.io) catch |err| {
        result.* = err;
        started.set(core.io);
        return;
    };

    started.set(core.io);

    core.loop.run(.until_done) catch |err| {
        log.err("Loop err={}", .{err});
    };
}

fn wakeupCallback(_: *async.Completion, _: *async.Loop, res: anyerror!void) bool {
    res catch unreachable;

    var buffer: [128]Message = undefined;

    const read = core.messages.pop(&buffer);

    for (buffer[0..read]) |msg| {
        defer msg.free();

        switch (msg) {
            .echo => |id| core.events.push(.{ .echo = id }),
            .open_worktree => |data| scanner.open(data.key, data.abs_path) catch |err| {
                log.err("Open worktree path=\"{s}\" err={}", .{ data.abs_path, err });
            },
            .close_worktree => |key| scanner.close(key),
        }
    }

    return true;
}

pub fn flush() !void {
    var buffer: [128]Event = undefined;
    const len = core.events.pop(&buffer);

    for (buffer[0..len]) |evt| {
        switch (evt) {
            .echo => |id| log.debug("echo: {}", .{id}),
            .worktree => |data| {
                var snapshot = data.snapshot;

                if (core.entities.get(data.key) == null) snapshot.deinit();

                const entry = if (core.worktree_cache.get(data.key)) |entry| blk: {
                    entry.snapshot.deinit();
                    break :blk entry;
                } else blk: {
                    const entry = core.chunks.allocator().create(WorktreeCache) catch |err| {
                        snapshot.deinit();
                        return err;
                    };
                    entry.* = .{
                        .key = data.key,
                        .generation = undefined,
                        .status = undefined,
                        .snapshot = undefined,
                    };
                    core.worktree_cache.insert(data.key, entry);
                    break :blk entry;
                };

                entry.generation = data.generation;
                entry.status = data.status;
                entry.snapshot = snapshot;
            },
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
                const entity = core.entities.get(key) orelse continue;

                if (core.worktree_cache.remove(key)) |cached| {
                    cached.snapshot.deinit();
                    chunks.destroy(cached);
                }

                remove(entity);

                try pushMsg(.{ .close_worktree = key });
            },
        }
    }

    core.frame += 1;
    _ = core.frame_arena.reset(.retain_capacity);

    try core.wakeup.wake();
}

pub fn worktree(key: Key) ?*const WorktreeCache {
    return core.worktree_cache.get(key);
}

pub fn pushMsg(msg: Message) !void {
    core.messages.push(try msg.clone());
}

pub fn pushCmd(params: Params) !void {
    const arena = core.frame_arena.allocator();
    const cmd = try arena.create(Command);
    cmd.* = .{ .params = try params.clone() };
    core.commands.append(cmd);
}

pub fn pushEvt(evt: Event) void {
    return core.events.push(evt);
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

fn remove(entity: *Entity) void {
    if (entity.parent) |p| {
        p.childrens.remove(entity);
    }

    var iter = entity.childrens.iterator();
    while (iter.next()) |child| remove(child);

    core.entities.remove(entity.key);
}

fn prune(entity: *Entity) void {
    var iter = entity.childrens.iterator();
    while (iter.next()) |child| remove(child.key);
}

fn childFromKind(parent: *Entity, kind: EntityKind) ?*Entity {
    var iter = parent.childrens.iterator();
    while (iter.next()) |child| {
        if (child.kind == kind) return child;
    }

    return null;
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
    worktree: struct {
        key: Key,
        generation: u64,
        status: scanner.Status,
        snapshot: scanner.Snapshot,
    },
};

pub const Params = union(enum) {
    open_worktree: []const u8,
    close_worktree: Key,

    fn clone(self: *const Params) !Params {
        const arena = core.frame_arena.allocator();

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

pub const WorktreeCache = struct {
    next: ?*WorktreeCache = null,
    prev: ?*WorktreeCache = null,

    key: Key,

    generation: u64,
    status: scanner.Status,
    snapshot: scanner.Snapshot,
    pub const Context = Key.Context;
};

test "Worktree" {
    const chromium_path = @import("test_options").chromium_path;

    const gpa = testing.allocator;
    const io = testing.io;

    try init(gpa, io);
    defer deinit();

    try pushCmd(.{ .open_worktree = chromium_path });
    try flush();

    const key = childFromKind(core.root, .worktree).?.key;

    const cached = while (true) {
        try flush();
        if (worktree(key)) |cached| break cached;
        try io.sleep(.fromMilliseconds(1), .awake);
    };
    try testing.expectEqualStrings(chromium_path, cached.snapshot.abs_root);

    try pushCmd(.{ .close_worktree = key });
    try flush();

    try testing.expect(worktree(key) == null);
}

test "benchmark: Worktree initial scan" {
    const chromium_path = @import("test_options").chromium_path;

    if (Bench.mode == .smoke) return;

    try global.init();

    const gpa = std.heap.c_allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    try init(gpa, io);
    defer deinit();

    var bench: Bench = .init();
    defer bench.deinit();

    Bench.report("path={s}", .{chromium_path});

    var durations: [8]Io.Duration = undefined;

    for (0..durations.len) |idx| {
        bench.start(io);

        try pushCmd(.{ .open_worktree = chromium_path });
        try flush();

        const key = childFromKind(core.root, .worktree).?.key;

        while (true) {
            try flush();
            const cached = worktree(key);
            if (cached) |w| std.mem.doNotOptimizeAway(w.snapshot.entries.count);

            if (cached) |w| if (w.status == .idle) break;

            try io.sleep(.fromMilliseconds(16), .awake);
        }

        durations[idx] = bench.stop(io);

        try pushCmd(.{ .close_worktree = key });
        try flush();
    }

    const mean = Bench.mean(&durations);
    const min = Bench.min(&durations);
    const max = Bench.max(&durations);
    Bench.report(
        "scan(min={}ms mean={}ms max={}ms)",
        .{
            min.toMilliseconds(),
            mean.toMilliseconds(),
            max.toMilliseconds(),
        },
    );
}
