const std = @import("std");

const app = @import("app.zig");
const async = @import("async.zig");
const Bench = @import("bench.zig");
const Buffer = @import("buffer.zig");
const chunk_pool = @import("chunk_pool.zig");
const ChunkedPath = @import("chunked_path.zig");
const core = @import("core.zig");
const datastruct = @import("datastruct.zig");
const font = @import("font.zig");
const global = @import("global.zig");
const patch = @import("patch.zig");
const Properties = @import("properties.zig");
const renderer = @import("renderer.zig");
const scheduler = @import("scheduler.zig");
const view = @import("view.zig");
const win = @import("window.zig");

pub const std_options: std.Options = .{
    .logFn = global.logFn,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    try global.init();

    try core.init(gpa, io);
    defer core.deinit();

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
    _ = core;
    _ = font;
    _ = view;
    _ = renderer;
    _ = scheduler;
    _ = Bench;
    _ = patch;
    _ = Buffer;
    _ = chunk_pool;
    _ = ChunkedPath;
    _ = datastruct;
    _ = async;
    _ = Properties;
}
