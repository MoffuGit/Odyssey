const std = @import("std");
const debug = std.debug;

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
