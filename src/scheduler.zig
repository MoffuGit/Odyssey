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

const Scheduler = @This();

arena: heap.ArenaAllocator,
queued: atomic.Value(u64),
workers: atomic.Value(?*Worker),
mutex: Io.Mutex,
cond: Io.Condition,
closed: atomic.Value(bool),
group: Io.Group,
io: Io,
queue: Queue,

pub fn init(self: *Scheduler, gpa: Allocator, io: Io) !void {
    self.* = .{
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

    const arena = self.arena.allocator();
    errdefer self.arena.deinit();

    const workers = try arena.alloc(Worker, global.cpu_count);

    for (workers) |*worker| {
        try self.group.concurrent(io, Worker.run, .{ worker, self });
    }
}

pub fn deinit(self: *Scheduler) void {
    self.closed.store(true, .release);
    self.wakeAll();

    self.group.await(self.io) catch |err| {
        log.err("Scanner err={}", .{err});
    };

    self.arena.deinit();
}

pub fn taskAdded(self: *Scheduler) void {
    const queued = self.queued.fetchAdd(1, .release);
    if (queued < global.cpu_count) self.wakeOne();
}

pub fn wakeAll(self: *Scheduler) void {
    self.mutex.lock(self.io) catch unreachable;
    defer self.mutex.unlock(self.io);
    self.cond.broadcast(self.io);
}

pub fn wakeOne(self: *Scheduler) void {
    self.mutex.lock(self.io) catch unreachable;
    defer self.mutex.unlock(self.io);
    self.cond.signal(self.io);
}

pub fn push(self: *Scheduler, task: *Task) !void {
    if (self.closed.load(.acquire)) return error.Closed;

    if (Worker.local) |local| {
        local.push(task, self.io);
    } else {
        self.queue.push(task, self.io);
    }
    self.taskAdded();
}

fn register(self: *Scheduler, worker: *Worker) void {
    var head = self.workers.load(.monotonic);
    while (true) {
        worker.next = head;
        head = self.workers.cmpxchgWeak(
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

    pub fn run(self: *Worker, scheduler: *Scheduler) Io.Cancelable!void {
        self.* = .{
            .queue = .{},
            .next = null,
            .target = null,
        };

        local = self;

        scheduler.register(self);

        while (true) {
            const task = try self.pop(scheduler);
            _ = scheduler.queued.fetchSub(1, .acq_rel);
            task.callback(task);
        }
    }

    pub fn pop(self: *Worker, scheduler: *Scheduler) !*Task {
        while (true) {
            if (self.queue.pop(scheduler.io)) |task| return task;
            if (scheduler.queue.pop(scheduler.io)) |task| return task;

            for (0..global.cpu_count) |_| {
                const target = self.target orelse scheduler.workers.load(.acquire) orelse unreachable;
                self.target = target.next;

                if (target == self) continue;

                if (target.queue.pop(scheduler.io)) |task| return task;
            }

            if (scheduler.closed.load(.acquire)) return error.Canceled;

            scheduler.mutex.lock(scheduler.io) catch unreachable;
            defer scheduler.mutex.unlock(scheduler.io);
            while (scheduler.queued.load(.acquire) == 0 and !scheduler.closed.load(.acquire)) {
                scheduler.cond.wait(scheduler.io, &scheduler.mutex) catch unreachable;
            }
        }
    }

    pub fn push(self: *Worker, task: *Task, io: Io) void {
        self.queue.push(task, io);
    }
};

const Queue = struct {
    mutex: Io.Mutex = .init,
    tasks: SinglyLinkedList(Task) = .empty,

    pub fn pop(self: *@This(), io: Io) ?*Task {
        self.mutex.lock(io) catch unreachable;
        defer self.mutex.unlock(io);

        return self.tasks.pop();
    }

    pub fn push(self: *@This(), task: *Task, io: Io) void {
        asserts(task.next == null);

        self.mutex.lock(io) catch unreachable;
        defer self.mutex.unlock(io);

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

    var scheduler: Scheduler = undefined;
    try scheduler.init(gpa, io);

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

    try scheduler.push(&test_task.task);

    scheduler.deinit();

    try testing.expectEqual(1, test_task.count);
}
