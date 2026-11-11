const std = @import("std");
const Io = std.Io;

const macos = @import("macos");

const Loop = @import("loop.zig");
const Completion = Loop.Completion;
const Waker = Loop.Waker;

const log = std.log.scoped(.display);

const Display = @This();

display_c: Completion,
display_link: *macos.video.DisplayLink,
waker: Waker,
loop: Loop,

pub fn init(self: *Display, comptime function: *const fn (*Display) bool, io: Io) !void {
    self.* = .{
        .display_link = undefined,
        .display_c = .noop,
        .waker = undefined,
        .loop = undefined,
    };

    try self.loop.init(undefined, io);
    errdefer self.loop.deinit();

    const Callback = struct {
        pub fn callback(completion: *Completion, _: *Loop, res: anyerror!void) bool {
            res catch unreachable;
            const display: *Display = @fieldParentPtr("display_c", completion);

            return @call(.always_inline, function, .{display});
        }
    };

    self.waker = try self.loop.await(&self.display_c, Callback.callback);
    errdefer self.waker.close();

    self.display_link = try macos.video.DisplayLink.createWithActiveCGDisplays();
    errdefer self.display_link.release();

    try self.display_link.setOutputCallback(
        Waker,
        struct {
            fn callback(_: *macos.video.DisplayLink, ud: ?*Waker) void {
                if (ud) |waker| {
                    waker.wake() catch {};
                }
            }
        }.callback,
        &self.waker,
    );

    try self.display_link.start();
}

pub fn run(self: *Display) !void {
    try self.loop.run(.until_done);
}

pub fn stop(self: *Display) void {
    self.loop.stop();
}

pub fn deinit(self: *Display) void {
    self.display_link.release();
    self.waker.close();
}
