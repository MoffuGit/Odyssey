const std = @import("std");
const Io = std.Io;
const Terminal = Io.Terminal;
const posix = std.posix;
const builtin = @import("builtin");

const Bench = @import("bench.zig");

pub fn writeCol(stderr: *const Terminal) void {
    stderr.setColor(.white) catch {};
    stderr.writer.writeAll("    ") catch {};
    stderr.writer.writeAll("█") catch {};
    stderr.setColor(.reset) catch {};
}

pub fn log() !void {
    var hostname_buffer: [posix.HOST_NAME_MAX]u8 = undefined;
    const hostname = posix.gethostname(&hostname_buffer) catch "unknown";

    var buffer: [256]u8 = undefined;
    var stderr = std.debug.lockStderr(&buffer).terminal();
    defer std.debug.unlockStderr();

    stderr.mode = .escape_codes;

    stderr.writer.writeAll("\n") catch {};

    for (0..2) |_| {
        writeCol(&stderr);
        stderr.writer.writeAll("\n") catch {};
    }

    writeCol(&stderr);
    stderr.writer.writeAll("    ") catch {};
    stderr.setColor(.bold) catch {};
    stderr.writer.print("ODYSSEY", .{}) catch {};
    stderr.setColor(.reset) catch {};

    if (Bench.mode == .benchmark) {
        stderr.setColor(.dim) catch {};
        stderr.writer.print(" [Benchmark]", .{}) catch {};
        stderr.setColor(.reset) catch {};
    }

    stderr.writer.print("\n", .{}) catch {};

    writeCol(&stderr);
    stderr.writer.writeAll("    ") catch {};
    stderr.writer.print("{s}\n", .{hostname}) catch {};

    writeCol(&stderr);
    stderr.writer.writeAll("    ") catch {};
    stderr.setColor(.dim) catch {};
    stderr.writer.print("@{s} ", .{@tagName(builtin.mode)}) catch {};
    stderr.setColor(.reset) catch {};

    stderr.setColor(.yellow) catch {};
    stderr.writer.print("{f}\n", .{builtin.zig_version}) catch {};
    stderr.setColor(.reset) catch {};

    for (0..2) |_| {
        writeCol(&stderr);
        stderr.writer.writeAll("\n") catch {};
    }

    stderr.writer.writeAll("\n") catch {};
}
