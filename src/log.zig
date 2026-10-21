const std = @import("std");
const debug = std.debug;
const Io = std.Io;
const Terminal = Io.Terminal;
const posix = std.posix;
const builtin = @import("builtin");

const Bench = @import("bench.zig");

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

pub fn RUNINF() !void {
    var buffer: [256]u8 = undefined;
    var stderr = std.debug.lockStderr(&buffer).terminal();
    defer std.debug.unlockStderr();

    stderr.mode = .escape_codes;

    stderr.writer.writeAll("\n") catch {};

    stderr.setColor(.bold) catch {};
    stderr.writer.print("ODYSSEY", .{}) catch {};
    stderr.setColor(.reset) catch {};

    stderr.setColor(.dim) catch {};

    if (Bench.mode == .benchmark) {
        stderr.writer.print(" [Benchmark]", .{}) catch {};
    }

    stderr.writer.print(" -- ", .{}) catch {};

    stderr.writer.print("@{s} ", .{@tagName(builtin.mode)}) catch {};
    stderr.setColor(.reset) catch {};

    stderr.setColor(.yellow) catch {};
    stderr.writer.print("{f} ", .{builtin.zig_version}) catch {};
    stderr.setColor(.reset) catch {};

    stderr.writer.writeAll("\n\n") catch {};
}
