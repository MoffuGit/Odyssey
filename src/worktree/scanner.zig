const std = @import("std");
const Io = std.Io;
const c = std.c;
const atomic = std.atomic;
const posix = std.posix;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const heap = std.heap;
const Timestamp = Io.Timestamp;
const builtin = @import("builtin");

const GitIgnore = @import("zlob").GitIgnore;

const chunk_pool = @import("../chunk_pool.zig");
const ChunkAllocator = chunk_pool.ChunkAllocator;
const ChunkedPath = @import("../chunked_path.zig");
const RANGE_NODE_SIZE = ChunkedPath.RANGE_NODE_SIZE;
const CHUNK_SIZE = ChunkedPath.CHUNKS_SIZE;
const constants = @import("../constants.zig");
const MAX_PATH_LEN = constants.MAX_PATH_LEN;
const Core = @import("../core.zig");
const datastruct = @import("../datastruct.zig");
const MpscBounded = datastruct.MpscBounded;
const SinglyLinkedList = datastruct.SinglyLinkedList;
const global = @import("../global.zig");
const Loop = @import("../loop.zig");
const Completion = Loop.Completion;
const Waker = Loop.Waker;
const Scheduler = @import("../scheduler.zig");
const Task = Scheduler.Task;
const attr = @import("attr.zig");
const BulkAttr = attr.BulkAttr;
const Snapshot = @import("snapshot.zig");

const UPDATE_INTERVAL_IN_MS = if (builtin.mode == .Debug) 2000 else 100;
const log = std.log.scoped(.scanner);

const Scanner = @This();

io: Io,
gpa: Allocator,
core: *Core,
arena: heap.ArenaAllocator,
snapshot: Snapshot,
mutex: Io.Mutex,
chunks: ChunkAllocator,
last_update: atomic.Value(i64),
task_count: atomic.Value(u64),
stopped: atomic.Value(bool),

/// One reference for the owner, released by `stop`, plus one per queued task.
/// The last release hands the scanner back to core, which destroys it.
refs: atomic.Value(u64),
background: Core.Background,

/// Updates for the owner; the owner pops them after `waker` fires.
events: MpscBounded(Event),
waker: Waker,

scan_id: atomic.Value(u64),
completed_scan: u64,

pub const Event = union(enum) {
    update: struct {
        snapshot: Snapshot,
        scanning: bool,
    },
    started,

    pub fn deinit(self: *Event) void {
        switch (self.*) {
            .update => |*updated| {
                updated.snapshot.deinit();
            },
            else => {},
        }
    }
};

/// Creates a scanner owned by `core` that scans a copy of `snapshot` and wakes
/// `waker` whenever it pushes an event. Call `stop` to release it.
pub fn create(core: *Core, snapshot: *const Snapshot, waker: Waker) !*Scanner {
    const self = try core.gpa.create(Scanner);
    errdefer core.gpa.destroy(self);

    try self.init(core, snapshot, waker);

    return self;
}

fn init(
    self: *Scanner,
    core: *Core,
    snapshot: *const Snapshot,
    waker: Waker,
) !void {
    const io = core.io;

    self.* = .{
        .core = core,
        .gpa = core.gpa,
        .arena = .init(core.gpa),
        .io = io,
        .snapshot = undefined,
        .mutex = .init,
        .chunks = undefined,
        .last_update = .init(Timestamp.now(io, .real).toMilliseconds()),
        .scan_id = .init(0),
        .completed_scan = 0,
        .task_count = .init(0),
        .stopped = .init(false),
        .refs = .init(1),
        .background = .{ .destroy = destroy },
        .events = undefined,
        .waker = waker,
    };
    errdefer self.arena.deinit();

    const arena = self.arena.allocator();

    self.events = try .init(global.cpu_count, 64, arena);

    self.snapshot = try snapshot.clone(self.gpa);
    errdefer self.snapshot.deinit();

    try self.chunks.initThreadSafe(
        arena,
        &.{
            .{ .capacity = 1024 * 1024 * 1024, .chunk_size = RANGE_NODE_SIZE },
            .{ .capacity = 1024 * 1024 * 1024, .chunk_size = CHUNK_SIZE },
            .{ .capacity = 1024 * 1024 * 2, .chunk_size = @max(@sizeOf(EntryData), @sizeOf(ScannerTask)) },
            .{ .capacity = 1024 * 1024, .chunk_size = @sizeOf(SharedFd) },
        },
        self.io,
    );

    const chunks = self.chunks.threadSafeAllocator();

    const task = try chunks.create(ScannerTask);
    errdefer chunks.destroy(task);

    task.* = .{
        .scanner = self,
        .kind = .initial_scan,
        .task = .{
            .callback = taskCallback,
        },
    };

    try self.pushTask(task);
}

fn destroy(background: *Core.Background) void {
    const self: *Scanner = @fieldParentPtr("background", background);
    const gpa = self.gpa;

    while (self.events.pop()) |event| {
        var e = event;
        e.deinit();
    }

    self.snapshot.deinit();
    self.arena.deinit();
    gpa.destroy(self);
}

/// Tells the scanner its owner is gone and releases the owner's reference.
/// Queued tasks finish without scanning, and the owner must not touch the
/// scanner again, including its events.
pub fn stop(self: *Scanner) void {
    self.stopped.store(true, .release);
    self.release();
}

fn release(self: *Scanner) void {
    if (self.refs.fetchSub(1, .acq_rel) != 1) return;
    self.core.release(&self.background);
}

const ScannerTask = struct {
    scanner: *Scanner,
    kind: union(enum) {
        initial_scan,
        scan_dir: struct {
            path: ChunkedPath,
            shared_fd: ?*SharedFd,
            ignore: ?*const IgnoreNode,
        },
        scan_request: struct {
            subscription: u6,
            path: ChunkedPath,
        },
    },
    task: Task,
};

fn pushUpdate(self: *Scanner, scanning: bool) !void {
    if (self.stopped.load(.acquire)) return;

    defer self.waker.wake() catch unreachable;

    var producer = self.events.register() orelse unreachable;
    defer producer.unregister();

    const snapshot = snapshot: {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        break :snapshot try self.snapshot.clone(self.gpa);
    };
    producer.push(.{
        .update = .{
            .scanning = scanning,
            .snapshot = snapshot,
        },
    });
}

fn pushTask(self: *Scanner, task: *ScannerTask) !void {
    if (self.stopped.load(.acquire)) return error.Closed;

    _ = self.refs.fetchAdd(1, .monotonic);
    _ = self.task_count.fetchAdd(1, .release);
    self.core.scheduler.push(&task.task) catch |err| {
        _ = self.task_count.fetchSub(1, .release);
        _ = self.refs.fetchSub(1, .monotonic);
        return err;
    };
}

fn taskDone(self: *Scanner, task: *ScannerTask) void {
    defer self.release();

    self.chunks.threadSafeAllocator().destroy(task);

    const prev = self.task_count.fetchSub(1, .release);
    if (prev != 1) return;

    self.completed_scan = self.scan_id.load(.acquire);

    self.pushUpdate(false) catch unreachable;
}

fn taskCallback(task: *Task) void {
    const t: *ScannerTask = @fieldParentPtr("task", task);

    const self = t.scanner;
    defer self.taskDone(t);

    self._taskCallback(t) catch |err| {
        switch (err) {
            error.Closed => {},
            else => log.err("Scanner err={}", .{err}),
        }
    };
}

fn _taskCallback(self: *Scanner, task: *ScannerTask) !void {
    if (self.stopped.load(.acquire)) return;

    switch (task.kind) {
        .initial_scan => try self.initialScan(),
        .scan_dir => |dir| try self.scanDir(dir.path, dir.shared_fd, dir.ignore),
        .scan_request => |request| try self.scanRequest(request.subscription, request.path),
    }
}

fn initialScan(
    self: *Scanner,
) !void {
    const chunks = self.chunks.threadSafeAllocator();

    const stat = try Io.Dir.statFile(
        .cwd(),
        self.io,
        self.snapshot.abs_root,
        .{},
    );

    const path: ChunkedPath = .new(self.snapshot.root_name, 0, chunks);

    {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

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

    {
        var producer = self.events.register() orelse unreachable;
        defer producer.unregister();

        producer.push(.started);
        try self.waker.wake();
    }

    const task = chunks.create(ScannerTask) catch unreachable;
    errdefer chunks.destroy(task);

    _ = self.scan_id.fetchAdd(1, .release);

    task.* = .{
        .scanner = self,
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

//we need to handle the git ignore stack,
//we are going to make an structure that let us make a git ignore
//stack for every given path, once we have that we can make the scan request
//path, the reasong why we need the ignore strucutr efirst is because at this point
//we would need to read/load the ignore files again, even if we do that on a prev
//scan, maybe we could use a hashmap and add an entry for every path that we know has a
//git ignore file
fn scanRequest(self: *Scanner, subscription: u64, path: ChunkedPath) !void {
    //load any pending directory
    //this would take every ancestor of the path,
    //see if we aready have an entry for the ancestor
    //and see if the entry kind is unloaded, if it is unloaded we would
    //load the directory into the snapshot,
    _ = subscription;
    _ = path;
    //push the scan id up
    _ = self.scan_id.fetchAdd(1, .release);
    //reload the paths
    //this would load the new metadata for the path,
    //if there is no metadata we would need to remove the entry
    //and in the case of directories, remove every child of it(remove path)
    //on the othe rhand, with the new metadata we would need to update
    //the existing entry, one detail, this part should not trigger a re scan
    //of the directories, the reason is because we are not currently handling events,
    //any request is for a change made by the user, we know what happening with those
    //changes

    //send status update
    try self.pushUpdate(self.task_count.load(.acquire) > 0);
}

fn scanDir(self: *Scanner, dir_path: ChunkedPath, shared_fd: ?*SharedFd, ignore: ?*const IgnoreNode) !void {
    const chunks = self.chunks.threadSafeAllocator();
    const arena = self.arena.allocator();
    var buffer: [64 * 1024]u8 = undefined;
    var tasks: SinglyLinkedList(Task) = .empty;
    var count: u32 = 0;

    defer if (shared_fd) |fd| fd.release(chunks, self.io);

    const dir = bkl: {
        if (shared_fd) |fd| {
            const len = dir_path.basename(&buffer);
            break :bkl try fd.dir.openDir(
                self.io,
                buffer[0..len],
                .{ .follow_symlinks = false, .iterate = true },
            );
        }

        break :bkl try Io.Dir.openDirAbsolute(
            self.io,
            self.snapshot.abs_root,
            .{ .follow_symlinks = false, .iterate = true },
        );
    };
    errdefer dir.close(self.io);

    var effective_ignore: ?*const IgnoreNode = ignore;
    {
        const content = dir.readFile(self.io, ".gitignore", &buffer) catch null;

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

        const path: ChunkedPath = .extend(dir_path, suffix, 1, chunks);
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
                .scanner = self,
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
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

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
        //     errdefer {
        //         while (jobs.pop()) |j| {
        //             j.finish(chunks, self.io);
        //         }
        //     }

        while (tasks.pop()) |t| {
            const task: *ScannerTask = @fieldParentPtr("task", t);
            task.kind.scan_dir.shared_fd = shared;

            try self.pushTask(task);
        }
    } else {
        dir.close(self.io);
    }

    const now = Timestamp.now(self.io, .real).toMilliseconds();
    const last = self.last_update.load(.acquire);

    if (now - last >= UPDATE_INTERVAL_IN_MS) {
        if (self.last_update.cmpxchgWeak(last, now, .acq_rel, .monotonic) == null) {
            try self.pushUpdate(true);
        }
    }
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

    pub fn init(self: *SharedFd, dir: Io.Dir, refs: u32) void {
        self.* = .{
            .dir = dir,
            .refs = .init(refs),
        };
    }

    fn release(self: *SharedFd, alloc: Allocator, io: Io) void {
        const prev = self.refs.fetchSub(1, .acq_rel);

        assert(prev != 0);
        if (prev == 1) {
            self.close(io);
            alloc.destroy(self);
        }
    }

    fn close(self: *SharedFd, io: Io) void {
        self.dir.close(io);
    }
};
