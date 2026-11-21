//The stealing queue came from zlob
// SOURCE: https://github.com/dmtrKovalenko/zlob/tree/main
// LICENSE: [ZLOB]

const std = @import("std");
const atomic = std.atomic;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const heap = std.heap;
const asserts = std.debug.assert;

const constants = @import("constants.zig");
const MAX_CONTEXT_SIZE = constants.MAX_CONTEXT_SIZE;
const datastruct = @import("datastruct.zig");
const SinglyLinkedList = datastruct.SinglyLinkedList;
const global = @import("global.zig");

const log = std.log.scoped(.scheduler);

pub var scheduler: Scheduler = undefined;

const Scheduler = struct {
    arena: heap.ArenaAllocator,
    queued: atomic.Value(u64),
    workers: atomic.Value(?*Worker),
    mutex: Io.Mutex,
    cond: Io.Condition,
    closed: atomic.Value(bool),
    group: Io.Group,
    io: Io,
    queue: Queue,
};

pub fn init(gpa: Allocator, io: Io) !void {
    scheduler = .{
        .queued = .init(0),
        .queue = .{},
        .workers = .init(null),
        .closed = .init(false),
        .arena = .init(gpa),
        .mutex = .init,
        .group = .init,
        .cond = .init,
        .io = io,
    };

    const arena = scheduler.arena.allocator();
    errdefer scheduler.arena.deinit();

    const workers = try arena.alloc(Worker, global.cpu_count);

    for (workers) |*worker| {
        try scheduler.group.concurrent(io, Worker.run, .{worker});
    }
}

pub fn deinit() void {
    scheduler.closed.store(true, .release);
    wakeAll();

    scheduler.group.await(scheduler.io) catch |err| {
        log.err("Scheduler err={}", .{err});
    };

    scheduler.arena.deinit();
}

pub fn taskAdded() void {
    const queued = scheduler.queued.fetchAdd(1, .release);
    if (queued < global.cpu_count) wakeOne();
}

pub fn wakeAll() void {
    scheduler.mutex.lock(scheduler.io) catch unreachable;
    defer scheduler.mutex.unlock(scheduler.io);
    scheduler.cond.broadcast(scheduler.io);
}

pub fn wakeOne() void {
    scheduler.mutex.lock(scheduler.io) catch unreachable;
    defer scheduler.mutex.unlock(scheduler.io);
    scheduler.cond.signal(scheduler.io);
}

pub fn push(task: *Task) !void {
    if (scheduler.closed.load(.acquire)) return error.Closed;

    if (Worker.local) |local| {
        local.push(task);
    } else {
        scheduler.queue.push(task);
    }
    taskAdded();
}

fn register(worker: *Worker) void {
    var head = scheduler.workers.load(.monotonic);
    while (true) {
        worker.next = head;
        head = scheduler.workers.cmpxchgWeak(
            head,
            worker,
            .release,
            .monotonic,
        ) orelse break;
    }
}

const Worker = struct {
    queue: Queue,
    next: ?*Worker,
    target: ?*Worker,

    threadlocal var local: ?*Worker = null;

    pub fn run(self: *Worker) Io.Cancelable!void {
        self.* = .{
            .queue = .{},
            .next = null,
            .target = null,
        };

        local = self;

        register(self);

        while (true) {
            const task = try self.pop();
            _ = scheduler.queued.fetchSub(1, .acq_rel);
            task.callback(task);
        }
    }

    pub fn pop(self: *Worker) !*Task {
        while (true) {
            if (self.queue.pop()) |task| return task;
            if (scheduler.queue.pop()) |task| return task;

            for (0..global.cpu_count) |_| {
                const target = self.target orelse scheduler.workers.load(.acquire) orelse unreachable;
                self.target = target.next;

                if (target == self) continue;

                if (target.queue.pop()) |task| return task;
            }

            if (scheduler.closed.load(.acquire)) return error.Canceled;

            scheduler.mutex.lock(scheduler.io) catch unreachable;
            defer scheduler.mutex.unlock(scheduler.io);
            while (scheduler.queued.load(.acquire) == 0 and !scheduler.closed.load(.acquire)) {
                scheduler.cond.wait(scheduler.io, &scheduler.mutex) catch unreachable;
            }
        }
    }

    pub fn push(self: *Worker, task: *Task) void {
        self.queue.push(task);
    }
};

const Queue = struct {
    mutex: Io.Mutex = .init,
    tasks: SinglyLinkedList(Task) = .empty,

    pub fn pop(self: *@This()) ?*Task {
        self.mutex.lock(scheduler.io) catch unreachable;
        defer self.mutex.unlock(scheduler.io);

        return self.tasks.pop();
    }

    pub fn push(self: *@This(), task: *Task) void {
        asserts(task.next == null);

        self.mutex.lock(scheduler.io) catch unreachable;
        defer self.mutex.unlock(scheduler.io);

        return self.tasks.append(task);
    }
};

pub const Task = struct {
    fn noopCallback(_: *Task) void {}

    pub const noop: Task = .{
        .next = null,
        .callback = noopCallback,
    };

    callback: *const fn (*Task) void,
    next: ?*Task = null,
};

test "Scheduler" {
    const io = testing.io;
    const gpa = testing.allocator;

    try init(gpa, io);

    const TestTask = struct {
        const Self = @This();

        count: u64,
        task: Task,

        pub fn callback(task: *Task) void {
            const self: *Self = @fieldParentPtr("task", task);
            self.count += 1;
        }
    };

    var test_task = TestTask{
        .count = 0,
        .task = .{ .callback = TestTask.callback },
    };

    try push(&test_task.task);

    deinit();

    try testing.expectEqual(1, test_task.count);
}
