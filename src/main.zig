const std = @import("std");
const Io = std.Io;

const App = @import("app.zig");
const Bench = @import("bench.zig");
const Buffer = @import("buffer.zig");
const chunk_pool = @import("chunk_pool.zig");
const chunked_path = @import("chunked_path.zig");
const Core = @import("core.zig");
const datastruct = @import("datastruct.zig");
const entity = @import("entity.zig");
const font = @import("font.zig");
const global = @import("global.zig");
const log = @import("log.zig");
const Loop = @import("loop.zig");
const patch = @import("patch.zig");
const render = @import("render.zig");
const Scheduler = @import("scheduler.zig");
const subscription = @import("subscription.zig");
const View = @import("view.zig");
const win = @import("window.zig");

pub const std_options: std.Options = .{
    .logFn = log.logFn,
};

pub fn main(init: std.process.Init) !void {
    try global.init();
    defer global.deinit();

    const gpa = init.gpa;
    const io = init.io;

    var app: App = undefined;
    try app.init(gpa, io);
    defer app.deinit();

    try app.openWindow(.{
        .name = "Odyssey",
        .x = 0,
        .y = 0,
        .width = 800,
        .height = 600,
        .flags = win.WindowCenter | win.WindowFocus,
    });

    app.run();
}

test {
    _ = font;
    _ = View;
    _ = render;
    _ = Scheduler;
    _ = Bench;
    _ = patch;
    _ = Buffer;
    _ = Core;
    _ = chunk_pool;
    _ = chunked_path;
    _ = datastruct;
    _ = entity;
    _ = subscription;
    _ = Loop;
}
