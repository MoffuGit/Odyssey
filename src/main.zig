const std = @import("std");
const Io = std.Io;

const Bench = @import("bench.zig");
const Buffer = @import("buffer.zig");
const chunk_pool = @import("chunk_pool.zig");
const chunked_path = @import("chunked_path.zig");
const app = @import("app.zig");
const datastruct = @import("datastruct.zig");
const font = @import("font.zig");
const global = @import("global.zig");
const log = @import("log.zig");
const Loop = @import("loop.zig");
const patch = @import("patch.zig");
const renderer = @import("renderer.zig");
const Scheduler = @import("scheduler.zig");
const View = @import("view.zig");
const win = @import("window.zig");

pub const std_options: std.Options = .{
    .logFn = log.logFn,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    try global.init();
    defer global.deinit();

    try renderer.init();
    defer renderer.deinit();

    try font.init(gpa);
    defer font.deinit();

    try win.init("Odyssey", 0);
    defer win.deinit();

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

    try app.run();
}

test {
    _ = font;
    _ = View;
    _ = renderer;
    _ = Scheduler;
    _ = Bench;
    _ = patch;
    _ = Buffer;
    _ = chunk_pool;
    _ = chunked_path;
    _ = datastruct;
    _ = Loop;
}
