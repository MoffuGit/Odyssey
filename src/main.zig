const std = @import("std");
const debug = std.debug;
const Io = std.Io;

const Bench = @import("bench.zig");
const Buffer = @import("buffer.zig");
const chunk_pool = @import("chunk_pool.zig");
const ChunkedPath = @import("chunked_path.zig");
const app = @import("app.zig");
const datastruct = @import("datastruct.zig");
const font = @import("font.zig");
const global = @import("global.zig");
const log = @import("log.zig");
const Loop = @import("loop.zig");
const patch = @import("patch.zig");
const renderer = @import("renderer.zig");
const scheduler = @import("scheduler.zig");
const view = @import("view.zig");
const win = @import("window.zig");

pub const std_options: std.Options = .{
    .logFn = logFn,
};

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    var buffer: [64]u8 = undefined;
    const stderr = debug.lockStderr(&buffer);
    defer debug.unlockStderr();

    var terminal = stderr.terminal();
    terminal.mode = .escape_codes;

    return logFileTerminal(level, scope, format, args, terminal) catch {};
}

pub fn logFileTerminal(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
    t: std.Io.Terminal,
) std.Io.Writer.Error!void {
    t.setColor(.dim) catch {};
    if (scope != .default) try t.writer.print("@{t} ", .{scope});
    t.setColor(.reset) catch {};

    t.setColor(switch (level) {
        .err => .red,
        .warn => .yellow,
        .info => .green,
        .debug => .magenta,
    }) catch {};

    try t.writer.writeAll("◍ ");

    t.setColor(.reset) catch {};

    try t.writer.writeAll(".──. ");

    try t.writer.print(format ++ "\n", args);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    try global.init();
    defer global.deinit();

    try scheduler.init(gpa, io);
    defer scheduler.deinit();

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
    _ = view;
    _ = renderer;
    _ = scheduler;
    _ = Bench;
    _ = patch;
    _ = Buffer;
    _ = chunk_pool;
    _ = ChunkedPath;
    _ = datastruct;
    _ = Loop;
}
