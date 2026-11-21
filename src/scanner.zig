const std = @import("std");
const Io = std.Io;
const atomic = std.atomic;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const heap = std.heap;
const Timestamp = Io.Timestamp;
const builtin = @import("builtin");

const GitIgnore = @import("zlob").GitIgnore;

const async = @import("async.zig");
const attr = @import("attr.zig");
const BulkAttr = attr.BulkAttr;
const chunk_pool = @import("chunk_pool.zig");
const ChunkAllocator = chunk_pool.ChunkAllocator;
const ChunkedPath = @import("chunked_path.zig");
const RANGE_NODE_SIZE = ChunkedPath.RANGE_NODE_SIZE;
const CHUNK_SIZE = ChunkedPath.CHUNKS_SIZE;
const constants = @import("constants.zig");
const MAX_PATH_LEN = constants.MAX_PATH_LEN;
const core = @import("core.zig");
const datastruct = @import("datastruct.zig");
const HashTable = datastruct.HashTable;
const btree = datastruct.btree;
const SinglyLinkedList = datastruct.SinglyLinkedList;
const Key = datastruct.slotmap.Key;
const scheduler = @import("scheduler.zig");
const Task = scheduler.Task;

const UPDATE_INTERVAL_IN_MS = if (builtin.mode == .debug) 2000 else 100;

const log = std.log.scoped(.scanner);

pub var scanner: Scanner = undefined;

const Scanner = struct {
    io: Io,
    gpa: Allocator,
    arena: heap.ArenaAllocator,
    chunks: ChunkAllocator,

    worktrees: HashTable(Key, Worktree, Key.Context),
    waker: async.Waker,
    waker_c: async.Completion,
};

pub fn init(gpa: Allocator, io: Io) !void {
    scanner = .{
        .io = io,
        .gpa = gpa,
        .arena = .init(gpa),
        .chunks = undefined,
        .worktrees = undefined,
        .waker = undefined,
        .waker_c = .noop,
    };
    errdefer scanner.arena.deinit();

    const arena = scanner.arena.allocator();

    try scanner.chunks.init(arena, &.{
        .{ .capacity = 128, .chunk_size = @sizeOf(Worktree) },
    });

    try scanner.worktrees.init(64, .{}, arena);

    scanner.waker = try core.core.loop.await(&scanner.waker_c, wakeupCallback);
}

pub fn stop() void {
    var iter = scanner.worktrees.iterator();
    while (iter.next()) |worktree| worktree.stop();
}

pub fn deinit() void {
    var iter = scanner.worktrees.iterator();
    while (iter.next()) |worktree| {
        worktree.deinit();
    }

    scanner.waker.deinit();
    scanner.arena.deinit();
}

fn wakeupCallback(_: *async.Completion, _: *async.Loop, res: anyerror!void) bool {
    res catch unreachable;
    const chunks = scanner.chunks.allocator();

    var iter = scanner.worktrees.iterator();
    while (iter.next()) |worktree| {
        if (worktree.stopped.load(.acquire)) {
            if (worktree.task_count.load(.acquire) == 0) {
                iter.remove();
                worktree.deinit();
                chunks.destroy(worktree);
            }
            continue;
        }

        worktree.mutex.lockUncancelable(scanner.io);
        defer worktree.mutex.unlock(scanner.io);

        if (worktree.generation == worktree.last_generation) continue;

        const snapshot = worktree.snapshot.clone(scanner.gpa) catch continue;
        worktree.last_generation = worktree.generation;
        core.pushEvt(.{ .worktree = .{
            .key = worktree.key,
            .generation = worktree.generation,
            .status = worktree.status,
            .snapshot = snapshot,
        } });
    }

    return true;
}

pub fn open(key: Key, abs_path: []const u8) !void {
    const chunks = scanner.chunks.allocator();
    const worktree = try chunks.create(Worktree);
    errdefer chunks.destroy(worktree);

    try worktree.init(key, abs_path);

    scanner.worktrees.insert(key, worktree);
}

pub fn close(key: Key) void {
    const worktree = scanner.worktrees.get(key) orelse return;

    worktree.stop();
    scanner.waker.wake() catch {};
}

pub const Status = enum {
    scanning,
    idle,
};

pub const Snapshot = struct {
    arena: heap.ArenaAllocator,
    chunks: ChunkAllocator,

    entries: Entries,

    abs_root: []u8,
    root_name: []u8,

    next_entry_id: atomic.Value(u64),

    pub fn init(
        self: *Snapshot,
        abs_path: []const u8,
        gpa: Allocator,
    ) !void {
        self.* = .{
            .arena = .init(gpa),
            .chunks = undefined,
            .abs_root = undefined,
            .root_name = undefined,
            .entries = undefined,
            .next_entry_id = .init(0),
        };

        const arena = self.arena.allocator();
        errdefer self.arena.deinit();

        self.abs_root = try arena.dupe(u8, abs_path);
        self.root_name = try arena.dupe(u8, std.fs.path.basename(self.abs_root));

        try self.chunks.init(arena, &.{
            .{ .capacity = 1024 * 1024, .chunk_size = NODE_SIZE },
        });

        try self.entries.init(self.chunks.allocator());
    }

    pub fn insert(self: *Snapshot, path: ChunkedPath, meta: Meta) void {
        _ = self.entries.insert(self.chunks.allocator(), path, .{
            .path = path,
            .meta = meta,
            .id = self.next_entry_id.fetchAdd(1, .monotonic),
        }) catch @panic("Snapshot Nodes Overflow");
    }

    pub fn clone(self: *const Snapshot, gpa: Allocator) !Snapshot {
        var copy: Snapshot = .{
            .arena = .init(gpa),
            .chunks = undefined,
            .entries = undefined,
            .abs_root = undefined,
            .root_name = undefined,
            .next_entry_id = .init(self.next_entry_id.load(.monotonic)),
        };
        errdefer copy.arena.deinit();
        const arena = copy.arena.allocator();

        copy.abs_root = try arena.dupe(u8, self.abs_root);
        copy.root_name = try arena.dupe(u8, self.root_name);

        try copy.chunks.init(arena, &.{
            .{ .capacity = 1024 * 1024, .chunk_size = NODE_SIZE },
        });
        copy.entries = try self.entries.clone(copy.chunks.allocator());

        return copy;
    }

    pub fn deinit(self: *Snapshot) void {
        self.arena.deinit();
    }

    const Entries = btree.BPlusTree(ChunkedPath, Entry, cmpPath);
    pub const NODE_SIZE = Entries.NODE_SIZE;

    fn cmpPath(a: ChunkedPath, b: ChunkedPath) std.math.Order {
        return a.cmp(&b);
    }

    pub const Entry = struct {
        id: u64,
        path: ChunkedPath,
        meta: Meta,
    };

    pub const Meta = struct {
        mtime: Io.Timestamp,
        size: u64,
        inode: u64,
        kind: Io.File.Kind,
        hidden: bool,
        ignored: bool,
        state: enum {
            loaded,
            pending,
            unloaded,
        },
    };
};

const Worktree = struct {
    key: Key,
    next: ?*Worktree = null,
    prev: ?*Worktree = null,

    arena: heap.ArenaAllocator,
    chunks: ChunkAllocator,

    mutex: Io.Mutex,
    snapshot: Snapshot,
    status: Status,
    generation: u64,
    last_generation: u64,

    last_update: atomic.Value(i64),
    task_count: atomic.Value(u64),
    stopped: atomic.Value(bool),

    fn init(self: *Worktree, key: Key, abs_path: []const u8) !void {
        const gpa = scanner.gpa;
        const io = scanner.io;

        self.* = .{
            .last_generation = 0,
            .key = key,
            .arena = .init(gpa),
            .chunks = undefined,
            .mutex = .init,
            .snapshot = undefined,
            .status = .scanning,
            .generation = 0,
            .last_update = .init(Timestamp.now(io, .real).toMilliseconds()),
            .task_count = .init(0),
            .stopped = .init(false),
        };
        errdefer self.arena.deinit();

        try self.snapshot.init(abs_path, gpa);
        errdefer self.snapshot.deinit();

        try self.chunks.initThreadSafe(
            self.arena.allocator(),
            &.{
                .{ .capacity = 1024 * 1024 * 1024, .chunk_size = RANGE_NODE_SIZE },
                .{ .capacity = 1024 * 1024 * 1024, .chunk_size = CHUNK_SIZE },
                .{ .capacity = 1024 * 1024 * 2, .chunk_size = @max(@sizeOf(EntryData), @sizeOf(ScannerTask)) },
                .{ .capacity = 1024 * 1024, .chunk_size = @sizeOf(SharedFd) },
            },
            io,
        );

        const chunks = self.chunks.threadSafeAllocator();

        const task = try chunks.create(ScannerTask);
        errdefer chunks.destroy(task);

        task.* = .{
            .worktree = self,
            .kind = .initial_scan,
            .task = .{ .callback = taskCallback },
        };

        try self.pushTask(task);
    }

    fn deinit(self: *Worktree) void {
        assert(self.task_count.load(.acquire) == 0);

        self.snapshot.deinit();
        self.arena.deinit();
    }

    fn stop(self: *Worktree) void {
        self.stopped.store(true, .release);
    }

    fn publish(self: *Worktree, status: Status) void {
        self.mutex.lockUncancelable(scanner.io);
        defer self.mutex.unlock(scanner.io);

        self.status = status;
        self.generation += 1;

        scanner.waker.wake() catch {};
    }

    fn pushTask(self: *Worktree, task: *ScannerTask) !void {
        if (self.stopped.load(.acquire)) return error.Closed;

        _ = self.task_count.fetchAdd(1, .monotonic);
        errdefer _ = self.task_count.fetchSub(1, .monotonic);

        try scheduler.push(&task.task);
    }

    fn taskDone(self: *Worktree, task: *ScannerTask) void {
        self.chunks.threadSafeAllocator().destroy(task);

        const last_task = self.task_count.load(.acquire) == 1;
        if (last_task) {
            self.publish(.idle);
        } else {
            const now = Timestamp.now(scanner.io, .real).toMilliseconds();
            const last = self.last_update.load(.acquire);

            if (now - last >= UPDATE_INTERVAL_IN_MS) {
                if (self.last_update.cmpxchgStrong(last, now, .acq_rel, .monotonic) == null) {
                    self.publish(.scanning);
                }
            }
        }

        _ = self.task_count.fetchSub(1, .release);
        if (last_task) scanner.waker.wake() catch {};
    }

    fn initialScan(self: *Worktree) !void {
        const io = scanner.io;
        const chunks = self.chunks.threadSafeAllocator();

        const stat = try Io.Dir.statFile(
            .cwd(),
            io,
            self.snapshot.abs_root,
            .{},
        );

        const path: ChunkedPath = .new(self.snapshot.root_name, 0, chunks);

        {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);

            self.snapshot.insert(
                path,
                .{
                    .inode = stat.inode,
                    .size = stat.size,
                    .mtime = stat.mtime,
                    .kind = stat.kind,
                    .hidden = false,
                    .ignored = false,
                    .state = .pending,
                },
            );
        }

        if (stat.kind != .directory) return;

        self.publish(.scanning);

        const task = try chunks.create(ScannerTask);
        errdefer chunks.destroy(task);

        task.* = .{
            .worktree = self,
            .kind = .{
                .scan_dir = .{
                    .path = path,
                    .shared_fd = null,
                    .ignore = null,
                },
            },
            .task = .{ .callback = taskCallback },
        };

        try self.pushTask(task);
    }

    fn scanDir(self: *Worktree, dir_path: ChunkedPath, shared_fd: ?*SharedFd, ignore: ?*const IgnoreNode) !void {
        const io = scanner.io;
        const chunks = self.chunks.threadSafeAllocator();
        const arena = self.arena.allocator();
        var buffer: [64 * 1024]u8 = undefined;
        var tasks: SinglyLinkedList(Task) = .empty;
        var count: u32 = 0;

        defer if (shared_fd) |fd| fd.release(chunks, io);

        const dir = bkl: {
            if (shared_fd) |fd| {
                const len = dir_path.basename(&buffer);
                break :bkl try fd.dir.openDir(
                    io,
                    buffer[0..len],
                    .{ .follow_symlinks = false, .iterate = true },
                );
            }

            break :bkl try Io.Dir.cwd().openDir(
                io,
                self.snapshot.abs_root,
                .{ .follow_symlinks = false, .iterate = true },
            );
        };
        errdefer dir.close(io);

        var effective_ignore: ?*const IgnoreNode = ignore;
        {
            const content = dir.readFile(io, ".gitignore", &buffer) catch null;

            if (content) |src| {
                const gi = try GitIgnore.parse(arena, src);
                const node = try arena.create(IgnoreNode);
                node.* = .{
                    .parent = ignore,
                    .gi = gi,
                    .relative_offset = dir_path.len + 1,
                };
                effective_ignore = node;
            }
        }

        var bulk = BulkAttr.init(dir.handle, &buffer, .{
            .size = true,
            .mtime = true,
            .inode = true,
        });

        var suffix_buf: [MAX_PATH_LEN]u8 = undefined;
        suffix_buf[0] = '/';
        var path_buf: [MAX_PATH_LEN]u8 = undefined;

        var entries: SinglyLinkedList(EntryData) = .empty;

        while (try bulk.next()) |entry| {
            const name = entry.name;
            @memcpy(suffix_buf[1 .. 1 + name.len], name);
            const suffix = suffix_buf[0 .. 1 + name.len];
            const is_dir = entry.kind == .directory;
            const is_hidden = name.len > 0 and name[0] == '.';

            const path: ChunkedPath = .extend(&dir_path, suffix, 1, chunks);
            const len = path.read(&path_buf);
            const ignored = isIgnored(effective_ignore, path_buf[0..len], name, is_dir);

            const data = chunks.create(EntryData) catch unreachable;
            data.* = .{
                .path = path,
                .meta = .{
                    .state = bkl: {
                        if (entry.kind == .directory) {
                            break :bkl if (is_hidden or ignored) .unloaded else .pending;
                        } else break :bkl .loaded;
                    },
                    .inode = entry.meta.inode,
                    .mtime = .fromNanoseconds(@intCast(entry.meta.mtime_ns)),
                    .size = entry.meta.size,
                    .kind = entry.kind,
                    .hidden = is_hidden,
                    .ignored = ignored,
                },
            };
            entries.append(data);

            if (is_dir and !(is_hidden or ignored)) {
                const task = chunks.create(ScannerTask) catch unreachable;
                task.* = .{
                    .worktree = self,
                    .task = .{ .callback = taskCallback },
                    .kind = .{
                        .scan_dir = .{
                            .shared_fd = null,
                            .path = path,
                            .ignore = effective_ignore,
                        },
                    },
                };

                tasks.append(&task.task);
                count += 1;
            }
        }

        {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);

            while (entries.pop()) |data| {
                self.snapshot.insert(
                    data.path,
                    data.meta,
                );
                chunks.destroy(data);
            }

            const entry = self.snapshot.entries.get_mut(dir_path) orelse unreachable;
            entry.meta.state = .loaded;
        }

        if (count > 0) {
            const shared = try chunks.create(SharedFd);
            shared.* = .{
                .dir = dir,
                .refs = .init(count),
            };

            while (tasks.pop()) |t| {
                const task: *ScannerTask = @fieldParentPtr("task", t);
                task.kind.scan_dir.shared_fd = shared;

                self.pushTask(task) catch {
                    shared.release(chunks, io);
                    chunks.destroy(task);
                };
            }
        } else {
            dir.close(io);
        }
    }
};

const ScannerTask = struct {
    worktree: *Worktree,
    kind: union(enum) {
        initial_scan,
        scan_dir: struct {
            path: ChunkedPath,
            shared_fd: ?*SharedFd,
            ignore: ?*const IgnoreNode,
        },
    },
    task: Task,
};

fn taskCallback(task: *Task) void {
    const t: *ScannerTask = @fieldParentPtr("task", task);

    const worktree = t.worktree;
    defer worktree.taskDone(t);

    if (worktree.stopped.load(.acquire)) {
        if (t.kind == .scan_dir) if (t.kind.scan_dir.shared_fd) |fd| {
            fd.release(worktree.chunks.threadSafeAllocator(), scanner.io);
        };
        return;
    }

    const result = switch (t.kind) {
        .initial_scan => worktree.initialScan(),
        .scan_dir => |dir| worktree.scanDir(dir.path, dir.shared_fd, dir.ignore),
    };

    result catch |err| switch (err) {
        error.Closed => {},
        else => log.err("Scanner err={}", .{err}),
    };
}

const IgnoreNode = struct {
    gi: GitIgnore,
    relative_offset: u32,

    parent: ?*const IgnoreNode,
};

fn isIgnored(
    start: ?*const IgnoreNode,
    path: []const u8,
    basename: []const u8,
    is_dir: bool,
) bool {
    var node = start;
    while (node) |n| : (node = n.parent) {
        if (n.gi.is_empty) continue;

        if (n.gi.checkWithBasename(
            path[n.relative_offset..],
            basename,
            is_dir,
        )) |verdict| {
            return verdict;
        }
    }
    return false;
}

const EntryData = struct {
    path: ChunkedPath,
    meta: Snapshot.Meta,
    next: ?*EntryData = null,
};

const SharedFd = struct {
    dir: Io.Dir,
    refs: atomic.Value(u32),

    fn release(self: *SharedFd, alloc: Allocator, io: Io) void {
        const prev = self.refs.fetchSub(1, .acq_rel);

        assert(prev != 0);
        if (prev == 1) {
            self.dir.close(io);
            alloc.destroy(self);
        }
    }
};
