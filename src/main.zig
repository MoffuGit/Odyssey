const std = @import("std");
const Io = std.Io;

const App = @import("app.zig");
const global = @import("global.zig");
const win = @import("window.zig");
const log = @import("log.zig");

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
