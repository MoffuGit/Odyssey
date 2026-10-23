//This event loop use as refence libxev and tigerbeetle implementations
//Sources:
// - TigerBeetle: https://github.com/tigerbeetle/tigerbeetle/tree/main [TIGERBEETLE]
// - Libxev: https://github.com/mitchellh/libxev [LIBXEV]

const std = @import("std");
const assert = std.debug.assert;
const posix = std.posix;
const system = posix.system;
const testing = std.testing;
const Io = std.Io;
const meta = std.meta;
const panic = std.debug.panic;
const Kevent = std.c.kevent64_s;
const builtin = @import("builtin");
const atomic = std.atomic;

const datastruct = @import("datastruct.zig");
const Mpsc = datastruct.Mpsc;
const heap = datastruct.heap;
const Scheduler = @import("scheduler.zig");
const Task = Scheduler.Task;
const SinglyLinkedList = datastruct.SinglyLinkedList;

const log = std.log.scoped(.loop);

pub const Loop = @This();

kq: posix.fd_t,

wakeup: Wakeup,
time: Time,
scheduler: *Scheduler,
tasks: Mpsc(Completion),
canceling: SinglyLinkedList(Completion),
submissions: SinglyLinkedList(Completion),
completions: SinglyLinkedList(Completion),
cancellations: SinglyLinkedList(Completion),
timers: heap.Intrusive(Timer, void, Timer.less),
inflight: usize,
stopped: bool,
io: Io,

pub fn init(self: *Loop, scheduler: *Scheduler, io: Io) !void {
    const kq = posix.system.kqueue();

    switch (posix.errno(kq)) {
        .SUCCESS => {},
        else => |err| return posix.unexpectedErrno(err),
    }

    self.* = .{
        .tasks = undefined,
        .wakeup = undefined,
        .scheduler = scheduler,
        .io = io,
        .kq = kq,
        .inflight = 0,
        .stopped = false,
        .timers = .{ .context = {} },
        .canceling = .empty,
        .submissions = .empty,
        .completions = .empty,
        .cancellations = .empty,
        .time = undefined,
    };

    self.wakeup = try .init();
    errdefer self.wakeup.deinit();

    self.tasks.init();

    try self.wakeup.register(self);
}

pub fn deinit(self: *Loop) void {
    assert(self.kq > -1);

    _ = posix.system.close(self.kq);
    self.kq = -1;
}

pub fn done(self: *Loop) bool {
    return self.stopped or (self.submissions.is_empty() and
        self.completions.is_empty() and
        self.inflight == 0);
}

pub fn stop(self: *Loop) void {
    self.stopped = true;
}

pub const RunMode = enum {
    no_wait,
    once,
    until_done,
};

pub fn run(self: *Loop, mode: RunMode) !void {
    switch (mode) {
        .no_wait => try self.tick(false),
        .once => try self.tick(true),
        .until_done => while (!self.done()) try self.tick(true),
    }
}

pub fn tick(self: *Loop, wait: bool) !void {
    var should_wait: bool = wait;

    while (self.cancellations.pop()) |completion| {
        const target: *Completion = completion.operation.cancel;
        switch (target.state) {
            .canceled, .idle => {},
            .completed, .submitted => target.canceled(),
            .active => switch (target.operation) {
                .timer => |*timer_op| {
                    self.timers.remove(timer_op);
                    target.canceled();
                    self.inflight -= 1;
                    self.completions.append(target);
                },
                .read => {
                    target.stopped.store(true, .release);
                },
                else => {
                    target.state = .canceled;
                    self.canceling.append(target);
                },
            },
        }
        completion.result = .cancel;
        _ = completion.callback(self, completion);
    }

    var kevents: [256]Kevent = undefined;

    while (!self.canceling.is_empty() or
        !self.submissions.is_empty())
    {
        var submitted: usize = 0;

        while (submitted < kevents.len) {
            const event = &kevents[submitted];
            const completion = self.canceling.pop() orelse break;
            submitted += 1;

            assert(completion.state == .canceled);
            self.inflight -= 1;

            completion.kevent(event);
            event.flags = std.c.EV.DELETE;
            completion.canceled();
            self.completions.append(completion);
        }

        var active: usize = 0;

        while (submitted < kevents.len) {
            const completion = self.submissions.pop() orelse break;

            if (completion.state == .completed) {
                self.completions.append(completion);
                continue;
            }

            assert(completion.state == .submitted);

            const event = &kevents[active];
            completion.kevent(event);
            completion.state = .active;
            active += 1;
            submitted += 1;
        }

        var timeout = std.mem.zeroes(posix.timespec);

        const completed = try kevent(
            self.kq,
            kevents[0..submitted],
            kevents[0..kevents.len],
            &timeout,
        );

        self.inflight += active;

        for (kevents[0..completed]) |ev| {
            if (ev.udata == 0) continue;

            if (ev.flags & std.c.EV.DELETE != 0) continue;

            self.inflight -= 1;

            const c: *Completion = @ptrFromInt(@as(usize, @intCast(ev.udata)));

            if (ev.flags & std.c.EV.ERROR != 0) {
                @panic("something go wrong with the kqueue submisssion");
            } else {
                c.result = c.resolve();
            }

            assert(c.result != null);
            c.state = .completed;
            self.completions.append(c);
        }
    }

    self.time.update();

    const now_timer: Timer = .{ .next = self.time.now, .ms = 0, .completion = undefined };
    while (self.timers.peek()) |t| {
        should_wait = false;

        if (!Timer.less({}, t, &now_timer)) break;

        assert(self.timers.deleteMin().? == t);

        const completion = t.completion;
        assert(completion.state == .active);

        completion.result = completion.resolve();
        completion.state = .idle;

        self.inflight -= 1;

        if (completion.callback(self, completion)) {
            t.next = self.time.next_tick(t.ms);
            self.timers.insert(t);
            completion.state = .active;
            completion.result = null;
            self.inflight += 1;
        }
    }

    while (self.tasks.pop()) |c| {
        if (c.stopped.raw) c.canceled();
        c.state = .completed;
        self.inflight -= 1;
        self.completions.append(c);
    }

    while (self.completions.pop()) |completion| {
        should_wait = false;

        assert(completion.state == .completed);
        assert(completion.result != null);

        completion.state = .idle;

        if (completion.callback(self, completion)) {
            completion.result = null;
            self.submit(completion);
        }
    }

    const timeout: ?posix.timespec = timeout: {
        if (!should_wait) break :timeout std.mem.zeroes(posix.timespec);
        const t = self.timers.peek() orelse break :timeout null;

        // Determine the time in milliseconds.
        const ms_now = @as(u64, @intCast(self.time.now.sec)) * std.time.ms_per_s +
            @as(u64, @intCast(self.time.now.nsec)) / std.time.ns_per_ms;
        const ms_next = @as(u64, @intCast(t.next.sec)) * std.time.ms_per_s +
            @as(u64, @intCast(t.next.nsec)) / std.time.ns_per_ms;
        const ms = ms_next -| ms_now;

        // Convert to s/ns for the timespec
        const sec = ms / std.time.ms_per_s;
        const nsec = (ms % std.time.ms_per_s) * std.time.ns_per_ms;
        break :timeout .{ .sec = @intCast(sec), .nsec = @intCast(nsec) };
    };

    const completed = try kevent(
        self.kq,
        kevents[0..0],
        kevents[0..kevents.len],
        if (timeout) |*t| t else null,
    );

    for (kevents[0..completed]) |ev| {
        if (ev.udata == 0) continue;

        if (ev.flags & std.c.EV.DELETE != 0) continue;

        self.inflight -= 1;

        const c: *Completion = @ptrFromInt(@as(usize, @intCast(ev.udata)));

        if (ev.flags & std.c.EV.ERROR != 0) {
            @panic("something go wrong with the kqueue submisssion");
        } else {
            c.result = c.resolve();
        }

        assert(c.result != null);
        c.state = .idle;

        if (c.callback(self, c)) {
            c.result = null;
            self.submit(c);
        }
    }
}

pub fn submit(self: *Loop, completion: *Completion) void {
    assert(completion.state == .idle);

    switch (completion.operation) {
        .read => {
            completion.loop = self;
            completion.task = .{
                .callback = Completion.taskCallback,
            };
            completion.state = .active;
            self.inflight += 1;
            //TODO: handle the push error
            self.scheduler.push(&completion.task) catch unreachable;
        },
        .cancel => {
            completion.state = .submitted;
            self.cancellations.append(completion);
        },
        .machport => {
            completion.state = .submitted;
            self.submissions.append(completion);
        },
        .timer => {
            const c_timer = completion.operation.timer;
            completion.operation.timer.next = self.time.next_tick(c_timer.ms);
            completion.state = .active;
            self.inflight += 1;

            self.timers.insert(&completion.operation.timer);
        },
        .noop => unreachable,
    }
}

fn kevent(
    kq: posix.fd_t,
    changelist: []const Kevent,
    eventlist: []Kevent,
    timeout: ?*const posix.timespec,
) !usize {
    while (true) {
        const rc = std.c.kevent64(
            kq,
            changelist.ptr,
            @intCast(changelist.len),
            eventlist.ptr,
            @intCast(eventlist.len),
            .{},
            timeout,
        );

        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .ACCES => return error.AccessDenied,
            .NOENT => return error.EventNotFound,
            .NOMEM => return error.SystemResources,
            else => return error.Unexpected,
        }
    }
}

pub const Time = struct {
    now: posix.timespec,

    pub fn update(self: *Time) void {
        switch (posix.errno(posix.system.clock_gettime(posix.CLOCK.MONOTONIC, &self.now))) {
            .SUCCESS => {},
            else => {},
        }
    }

    pub fn next_tick(self: *Time, next_ms: u64) posix.timespec {
        const max: posix.timespec = .{
            .sec = std.math.maxInt(isize),
            .nsec = std.math.maxInt(isize),
        };

        const next_s = std.math.cast(isize, next_ms / std.time.ms_per_s) orelse
            return max;
        const next_ns = std.math.cast(
            isize,
            (next_ms % std.time.ms_per_s) * std.time.ns_per_ms,
        ) orelse return max;

        self.update();

        return .{
            .sec = std.math.add(isize, self.now.sec, next_s) catch
                return max,
            .nsec = self.now.nsec + next_ns,
        };
    }
};

pub fn clampBuffer(len: usize) usize {
    const limit = switch (builtin.target.os.tag) {
        .linux => 0x7ffff000,
        .macos, .ios, .watchos, .tvos => std.math.maxInt(i32),
        else => std.math.maxInt(isize),
    };
    return @min(limit, len);
}

pub const ReadBuffer = union(enum) {
    slice: []u8,
    array: [32]u8,
};

pub const MachPort = struct {
    port: posix.system.mach_port_name_t,
    buffer: ReadBuffer,
};

pub const Read = struct {
    buffer: ReadBuffer,
    fd: posix.fd_t,
};

pub const ReadError = error{
    Unexpected,
} || Canceled;

pub const Operation = union(OperationType) {
    noop: void,
    machport: MachPort,
    cancel: *Completion,
    timer: Timer,
    read: Read,
};

const OperationType = enum {
    noop,
    machport,
    cancel,
    timer,
    read,
};

const Canceled = error{Canceled};

pub const Result = union(OperationType) {
    noop: void,
    machport: Canceled!void,
    cancel: void,
    timer: Canceled!void,
    read: ReadError!usize,
};

const State = enum(u3) {
    idle,
    submitted,
    canceled,
    active,
    completed,
};

pub const Completion = struct {
    pub const noop: Completion = .{
        .operation = .noop,
        .callback = noopCallback,
        .state = .idle,
    };

    operation: Operation,
    result: ?Result = null,

    callback: *const fn (loop: *Loop, completion: *Completion) bool,

    next: ?*Completion = null,
    task: Task = .noop,
    loop: *Loop = undefined,
    stopped: atomic.Value(bool) = .init(false),

    state: State,

    pub fn noopCallback(_: *Loop, _: *Completion) bool {
        return false;
    }

    pub fn kevent(self: *Completion, event: *Kevent) void {
        switch (self.operation) {
            .cancel, .noop, .timer, .read => panic(
                "{s} operation reached the submissions queueu",
                .{@tagName(self.operation)},
            ),
            .machport => |m| {
                const buffer: []u8 = switch (m.buffer) {
                    .slice => |slice| slice,
                    .array => |array| @constCast(&array),
                };
                event.* = .{
                    .ident = @intCast(m.port),
                    .filter = std.c.EVFILT.MACHPORT,
                    .flags = posix.system.EV.ADD | posix.system.EV.ENABLE | posix.system.EV.ONESHOT,
                    .fflags = @bitCast(std.c.MACH.RCV{ .MSG = true }),
                    .data = 0,
                    .udata = @intFromPtr(self),
                    .ext = .{ @intFromPtr(buffer.ptr), buffer.len },
                };
            },
        }
    }

    pub fn resolve(self: *Completion) Result {
        switch (self.operation) {
            .noop, .cancel => panic(
                "{s} operation try to resolve",
                .{@tagName(self.operation)},
            ),
            .machport => return .{ .machport = {} },
            .timer => return .{ .timer = {} },
            .read => |*data| {
                const buffer = switch (data.buffer) {
                    .slice => |slice| slice,
                    .array => |*array| array[0..array.len],
                };

                while (true) {
                    const rc = system.read(data.fd, buffer.ptr, clampBuffer(buffer.len));
                    return switch (posix.errno(rc)) {
                        .SUCCESS => .{ .read = @intCast(rc) },
                        .INTR => continue,
                        .FAULT => unreachable,
                        else => .{ .read = error.Unexpected },
                    };
                }
            },
        }
    }

    pub fn taskCallback(task: *Task) void {
        const self: *Completion = @fieldParentPtr("task", task);
        if (!self.stopped.load(.acquire)) self.result = self.resolve();
        self.loop.tasks.push(self);
        self.loop.wakeup.wake() catch unreachable;
    }

    pub fn canceled(self: *Completion) void {
        self.state = .completed;
        switch (self.operation) {
            .noop, .cancel => {},
            .machport => self.result = .{ .machport = error.Canceled },
            .timer => self.result = .{ .timer = error.Canceled },
            .read => self.result = .{ .read = error.Canceled },
        }
    }

    pub fn set(
        self: *Completion,
        callback: anytype,
        comptime op_tag: meta.Tag(Operation),
        op_data: @FieldType(Operation, @tagName(op_tag)),
    ) void {
        const TypeErased = struct {
            fn complete(loop: *Loop, _completion: *Completion) bool {
                const res = @field(_completion.result.?, @tagName(op_tag));

                return @call(.always_inline, callback, .{ _completion, loop, res });
            }
        };

        self.* = .{
            .state = .idle,
            .operation = @unionInit(Operation, @tagName(op_tag), op_data),
            .callback = TypeErased.complete,
        };
    }
};

const Timer = struct {
    next: posix.timespec,
    completion: *Completion,

    heap: heap.IntrusiveField(Timer) = .{},
    ms: u64,

    fn less(_: void, a: *const Timer, b: *const Timer) bool {
        return a.ns() < b.ns();
    }

    fn ns(self: *const Timer) u64 {
        return ns_from_timespec(self.next);
    }

    fn ns_from_timespec(ts: posix.timespec) u64 {
        assert(ts.sec >= 0);
        assert(ts.nsec >= 0);

        const max = std.math.maxInt(u64);
        const s_ns = std.math.mul(
            u64,
            @as(u64, @intCast(ts.sec)),
            std.time.ns_per_s,
        ) catch return max;
        return std.math.add(u64, s_ns, @as(u64, @intCast(ts.nsec))) catch
            return max;
    }
};

pub fn mach(
    self: *Loop,
    completion: *Completion,
    function: anytype,
    data: MachPort,
) void {
    completion.set(
        function,
        .machport,
        data,
    );

    self.submit(completion);
}

pub fn cancel(
    self: *Loop,
    completion: *Completion,
    function: anytype,
    target: *Completion,
) void {
    completion.set(
        function,
        .cancel,
        target,
    );

    self.submit(completion);
}

pub fn timer(
    self: *Loop,
    completion: *Completion,
    callback: anytype,
    ms: u64,
) void {
    completion.set(
        callback,
        .timer,
        .{
            .next = undefined,
            .completion = completion,
            .ms = ms,
        },
    );

    self.submit(completion);
}

pub fn read(
    self: *Loop,
    completion: *Completion,
    callback: anytype,
    fd: posix.fd_t,
    buffer: ReadBuffer,
) void {
    completion.set(
        callback,
        .read,
        .{
            .fd = fd,
            .buffer = buffer,
        },
    );

    self.submit(completion);
}

const Mach = struct {
    const mach_port_flavor_t = c_int;

    extern "c" fn mach_port_set_attributes(
        task: system.ipc_space_t,
        name: system.mach_port_name_t,
        flavor: mach_port_flavor_t,
        info: *anyopaque,
        count: system.mach_msg_type_number_t,
    ) posix.system.kern_return_t;

    extern "c" fn mach_port_destroy(
        task: posix.system.ipc_space_t,
        name: posix.system.mach_port_name_t,
    ) posix.system.kern_return_t;

    fn drain(port: posix.system.mach_port_name_t) void {
        var message: struct {
            header: system.mach_msg_header_t,
        } = undefined;

        while (true) {
            switch (system.mach_msg(
                &message.header,
                .{ .RCV = .{ .TIMEOUT = true } },
                0,
                @sizeOf(@TypeOf(message)),
                port,
                system.MACH.MSG.TIMEOUT_NONE,
                system.MACH.PORT.NULL,
            )) {
                .RCV_TIMED_OUT => return,
                .SUCCESS => {},
                .RCV_TOO_LARGE => {},
                .RCV_INVALID_NAME => return,
                else => |err| {
                    log.warn("mach msg drain err, may duplicate async wakeups err={}", .{err});
                    return;
                },
            }
        }
    }
};

pub fn await(
    self: *Loop,
    completion: *Completion,
    function: anytype,
) !Waker {
    const waker: Waker = try .init();

    const TypeErased =
        struct {
            fn complete(c: *Completion, loop: *Loop, res: Canceled!void) bool {
                Mach.drain(c.operation.machport.port);

                return @call(.always_inline, function, .{ c, loop, res });
            }
        };

    completion.set(
        TypeErased.complete,
        .machport,
        .{ .port = waker.port, .buffer = .{ .array = undefined } },
    );

    self.submit(completion);

    return waker;
}

const Wakeup = struct {
    waker: Waker,
    buffer: [32]u8,

    pub fn init() !Wakeup {
        const waker: Waker = try .init();

        return .{ .waker = waker, .buffer = undefined };
    }

    pub fn deinit(self: *Wakeup) void {
        self.waker.close();
    }

    pub fn wake(self: *Wakeup) !void {
        try self.waker.wake();
    }

    pub fn register(self: *Wakeup, loop: *Loop) !void {
        const events = [_]Kevent{.{
            .ident = @as(usize, @intCast(self.waker.port)),
            .filter = std.c.EVFILT.MACHPORT,
            .flags = std.c.EV.ADD | std.c.EV.ENABLE,
            .fflags = @bitCast(std.c.MACH.RCV{ .MSG = true }),
            .data = 0,
            .udata = 0,
            .ext = .{
                @intFromPtr(&self.buffer),
                self.buffer.len,
            },
        }};
        const n = try kevent(
            loop.kq,
            &events,
            events[0..0],
            null,
        );
        assert(n == 0);
    }
};

pub const Waker = struct {
    port: system.mach_port_name_t,

    pub fn init() !Waker {
        const mach_self = system.mach_task_self();
        var mach_port: system.mach_port_name_t = undefined;
        if (system.mach_port_allocate(
            mach_self,
            system.MACH.PORT.RIGHT.RECEIVE,
            &mach_port,
        ) != 0) {
            return error.MachPortAllocFailed;
        }
        errdefer _ = Mach.mach_port_destroy(mach_self, mach_port);

        if (system.mach_port_insert_right(
            mach_self,
            mach_port,
            mach_port,
            system.MACH.MSG.TYPE.MAKE_SEND,
        ) != 0) {
            return error.MachPortAllocFailed;
        }

        const mach_port_limits = extern struct { mpl_qlimit: system.natural_t };
        const MACH_PORT_LIMITS_INFO = 1;

        var limits: mach_port_limits = .{ .mpl_qlimit = 1 };
        if (Mach.mach_port_set_attributes(
            mach_self,
            mach_port,
            MACH_PORT_LIMITS_INFO,
            &limits,
            @sizeOf(@TypeOf(limits)),
        ) != 0) return error.MachPortAllocFailed;

        return .{
            .port = mach_port,
        };
    }

    pub fn wake(self: *const Waker) !void {
        var msg: posix.system.mach_msg_header_t = .{
            .msgh_bits = @backingInt(system.MACH.MSG.TYPE.COPY_SEND),
            .msgh_size = @sizeOf(posix.system.mach_msg_header_t),
            .msgh_remote_port = self.port,
            .msgh_local_port = system.MACH.PORT.NULL,
            .msgh_voucher_port = undefined,
            .msgh_id = undefined,
        };

        switch (system.mach_msg(
            &msg,
            .{ .SEND = .{ .TIMEOUT = true, .MSG = true } },
            msg.msgh_size,
            0,
            system.MACH.PORT.NULL,
            @fromBackingInt(@intCast(0)),
            system.MACH.PORT.NULL,
        )) {
            .SUCCESS => {},
            .SEND_NO_BUFFER => {},
            .SEND_TIMED_OUT => {},
            .SEND_INVALID_DEST => |e| {
                log.debug("mach msg err={}", .{e});
            },
            else => |e| {
                log.warn("mach msg err={}", .{e});
                return error.MachMsgFailed;
            },
        }
    }

    pub fn close(self: *const Waker) void {
        _ = Mach.mach_port_destroy(
            posix.system.mach_task_self(),
            self.port,
        );
    }
};

test "mach port" {
    const io = testing.io;

    var loop: Loop = undefined;
    try loop.init(undefined, io);
    defer loop.deinit();

    const mach_self = posix.system.mach_task_self();
    var mach_port: posix.system.mach_port_name_t = undefined;
    try testing.expectEqual(posix.system.mach_msg_return_t.SUCCESS, @as(
        posix.system.mach_msg_return_t,
        @fromBackingInt(@intCast(
            posix.system.mach_port_allocate(
                mach_self,
                posix.system.MACH.PORT.RIGHT.RECEIVE,
                &mach_port,
            ),
        )),
    ));
    defer _ = posix.system.mach_port_deallocate(mach_self, mach_port);

    const MachTest = struct {
        called: bool = false,
        completion: Completion = .noop,

        fn machport(c: *Completion, _: *Loop, res: Canceled!void) bool {
            const parent: *@This() = @fieldParentPtr("completion", c);
            if (res != error.Canceled) {
                parent.called = true;
            }
            return false;
        }
    };

    var mach_test: MachTest = .{};
    var buffer: [@sizeOf(posix.system.mach_msg_header_t)]u8 = undefined;

    loop.mach(
        &mach_test.completion,
        MachTest.machport,
        .{
            .port = mach_port,
            .buffer = .{ .slice = &buffer },
        },
    );

    try loop.run(.no_wait);
    try testing.expect(!mach_test.called);

    var msg: posix.system.mach_msg_header_t = .{
        .msgh_bits = @backingInt(posix.system.MACH.MSG.TYPE.MAKE_SEND_ONCE),
        .msgh_size = @sizeOf(posix.system.mach_msg_header_t),
        .msgh_remote_port = mach_port,
        .msgh_local_port = posix.system.MACH.PORT.NULL,
        .msgh_voucher_port = undefined,
        .msgh_id = undefined,
    };

    try testing.expectEqual(
        posix.system.mach_msg_return_t.SUCCESS,
        posix.system.mach_msg(
            &msg,
            .{ .SEND = .{} },
            msg.msgh_size,
            0,
            posix.system.MACH.PORT.NULL,
            posix.system.MACH.MSG.TIMEOUT_NONE,
            posix.system.MACH.PORT.NULL,
        ),
    );

    try loop.run(.until_done);
    try testing.expect(mach_test.called);

    mach_test.called = false;
    loop.mach(
        &mach_test.completion,
        MachTest.machport,
        .{
            .port = mach_port,
            .buffer = .{ .slice = &buffer },
        },
    );

    try loop.run(.no_wait);
    try loop.run(.no_wait);
    try testing.expect(!mach_test.called);
}

test "cancel mach port" {
    const io = testing.io;

    var loop: Loop = undefined;
    try loop.init(undefined, io);
    defer loop.deinit();

    const mach_self = posix.system.mach_task_self();
    var mach_port: posix.system.mach_port_name_t = undefined;
    try testing.expectEqual(posix.system.mach_msg_return_t.SUCCESS, @as(
        posix.system.mach_msg_return_t,
        @fromBackingInt(@intCast(
            posix.system.mach_port_allocate(
                mach_self,
                posix.system.MACH.PORT.RIGHT.RECEIVE,
                &mach_port,
            ),
        )),
    ));
    defer _ = posix.system.mach_port_deallocate(mach_self, mach_port);

    const MachTest = struct {
        called: bool = false,
        completion: Completion = .noop,

        fn machport(c: *Completion, _: *Loop, res: Canceled!void) bool {
            const parent: *@This() = @fieldParentPtr("completion", c);
            if (res != error.Canceled) {
                parent.called = true;
            }
            return false;
        }
    };

    var mach_test: MachTest = .{};
    var buffer: [@sizeOf(posix.system.mach_msg_header_t)]u8 = undefined;

    loop.mach(
        &mach_test.completion,
        MachTest.machport,
        .{
            .port = mach_port,
            .buffer = .{ .slice = &buffer },
        },
    );

    for (0..10) |_| try loop.run(.no_wait);
    try testing.expect(!mach_test.called);

    const Cancelation = struct {
        completion: Completion = .noop,
        called: bool = false,

        pub fn callback(c: *Completion, _: *Loop, _: void) bool {
            const parent: *@This() = @fieldParentPtr("completion", c);
            parent.called = true;
            return false;
        }
    };
    var cancellation: Cancelation = .{};

    loop.cancel(&cancellation.completion, Cancelation.callback, &mach_test.completion);

    for (0..10) |_| try loop.run(.no_wait);

    try testing.expect(!mach_test.called);
    try testing.expect(cancellation.called);

    // Send a message to the port
    var msg: posix.system.mach_msg_header_t = .{
        .msgh_bits = @backingInt(posix.system.MACH.MSG.TYPE.MAKE_SEND_ONCE),
        .msgh_size = @sizeOf(posix.system.mach_msg_header_t),
        .msgh_remote_port = mach_port,
        .msgh_local_port = posix.system.MACH.PORT.NULL,
        .msgh_voucher_port = undefined,
        .msgh_id = undefined,
    };

    try testing.expectEqual(
        posix.system.mach_msg_return_t.SUCCESS,
        posix.system.mach_msg(
            &msg,
            .{ .SEND = .{} },
            msg.msgh_size,
            0,
            posix.system.MACH.PORT.NULL,
            posix.system.MACH.MSG.TIMEOUT_NONE,
            posix.system.MACH.PORT.NULL,
        ),
    );
    // We should receive now!
    for (0..10) |_| try loop.run(.no_wait);
    try testing.expect(!mach_test.called);
}

test "timer completes" {
    const io = testing.io;

    var loop: Loop = undefined;
    try loop.init(undefined, io);
    defer loop.deinit();

    const TimerTest = struct {
        called: bool = false,
        completion: Completion = .noop,

        fn timer(c: *Completion, _: *Loop, res: Canceled!void) bool {
            res catch return false;
            const parent: *@This() = @fieldParentPtr("completion", c);
            parent.called = true;
            return false;
        }
    };

    var timer_test: TimerTest = .{};

    loop.timer(
        &timer_test.completion,
        TimerTest.timer,
        0,
    );

    try loop.run(.until_done);

    try testing.expect(timer_test.called);
}

test "timer rearms when callback returns true" {
    const io = testing.io;

    var loop: Loop = undefined;
    try loop.init(undefined, io);
    defer loop.deinit();

    const TimerTest = struct {
        times: u8 = 0,
        completion: Completion = .noop,

        fn timer(c: *Completion, _: *Loop, res: Canceled!void) bool {
            res catch return false;
            const parent: *@This() = @fieldParentPtr("completion", c);
            parent.times += 1;
            return parent.times < 2;
        }
    };

    var timer_test: TimerTest = .{};

    loop.timer(
        &timer_test.completion,
        TimerTest.timer,
        0,
    );

    try loop.run(.until_done);

    try testing.expectEqual(@as(u8, 2), timer_test.times);
}

test "cancel timer" {
    const io = testing.io;

    var loop: Loop = undefined;
    try loop.init(undefined, io);
    defer loop.deinit();

    const TimerTest = struct {
        called: bool = false,
        completion: Completion = .noop,

        fn timer(c: *Completion, _: *Loop, res: Canceled!void) bool {
            res catch return false;
            const parent: *@This() = @fieldParentPtr("completion", c);
            parent.called = true;
            return false;
        }
    };

    var timer_test: TimerTest = .{};

    loop.timer(
        &timer_test.completion,
        TimerTest.timer,
        std.time.ms_per_s,
    );

    try loop.run(.no_wait);

    const Cancelation = struct {
        completion: Completion = .noop,
        called: bool = false,

        pub fn callback(c: *Completion, _: *Loop, _: void) bool {
            const parent: *@This() = @fieldParentPtr("completion", c);
            parent.called = true;
            return false;
        }
    };
    var cancellation: Cancelation = .{};

    loop.cancel(&cancellation.completion, Cancelation.callback, &timer_test.completion);

    try loop.run(.until_done);

    try testing.expect(!timer_test.called);
    try testing.expect(cancellation.called);
}

test "read completion" {
    const ReadTest = struct {
        readed: usize = 0,
        completion: Completion = .noop,

        fn reader(c: *Completion, _: *Loop, res: ReadError!usize) bool {
            const readed = res catch return false;
            const parent: *@This() = @fieldParentPtr("completion", c);
            parent.readed = readed;
            return false;
        }
    };

    const io = testing.io;
    const gpa = testing.allocator;

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var scheduler: Scheduler = undefined;
    try scheduler.init(arena.allocator(), io);
    defer scheduler.deinit();

    var loop: Loop = undefined;
    try loop.init(&scheduler, io);
    defer loop.deinit();

    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    const file = try temp.dir.createFile(io, "temporal_file", .{ .read = true });
    try file.writePositionalAll(io, "expected text", 0);

    var buffer: [1024]u8 = undefined;
    var reader: ReadTest = .{};

    loop.read(&reader.completion, ReadTest.reader, file.handle, .{ .slice = &buffer });

    try loop.run(.until_done);

    try testing.expectEqualStrings("expected text", buffer[0..reader.readed]);
}
