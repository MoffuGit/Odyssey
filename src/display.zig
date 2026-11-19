const std = @import("std");
const Io = std.Io;

const macos = @import("macos");

const async = @import("async.zig");

const log = std.log.scoped(.display);

const Display = @This();

display_c: async.Completion,
display_link: *macos.video.DisplayLink,
waker: async.Waker,
loop: async.Loop,

pub fn init(self: *Display, comptime function: *const fn () bool, io: Io) !void {
    self.* = .{
        .display_link = undefined,
        .display_c = .noop,
        .waker = undefined,
        .loop = undefined,
    };

    try self.loop.init(io);
    errdefer self.loop.deinit();

    const Callback = struct {
        pub fn callback(_: *async.Completion, _: *async.Loop, res: anyerror!void) bool {
            res catch unreachable;

            return @call(.always_inline, function, .{});
        }
    };

    self.waker = try self.loop.await(&self.display_c, Callback.callback);
    errdefer self.waker.deinit();

    self.display_link = try macos.video.DisplayLink.createWithActiveCGDisplays();
    errdefer self.display_link.release();

    try self.display_link.setOutputCallback(
        async.Waker,
        struct {
            fn callback(_: *macos.video.DisplayLink, ud: ?*async.Waker) void {
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
    self.waker.deinit();
}
