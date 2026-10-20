const std = @import("std");
const process = std.process;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const posix = std.posix;
const Bench = @import("bench.zig");

const banner_color: Io.Terminal.Color = .cyan;

pub var cpu_count: usize = 2;

pub fn writeCol(t: *const std.Io.Terminal) void {
    t.setColor(.white) catch {};
    t.writer.writeAll("    ") catch {};
    t.writer.writeAll("█") catch {};
    t.setColor(.reset) catch {};
}

pub fn init() !void {
    cpu_count = try std.Thread.getCpuCount();

    var hostname_buffer: [posix.HOST_NAME_MAX]u8 = undefined;
    const hostname = posix.gethostname(&hostname_buffer) catch "unknown";

    var buffer: [256]u8 = undefined;
    var stderr = std.debug.lockStderr(&buffer).terminal();
    stderr.mode = .escape_codes;

    defer std.debug.unlockStderr();

    stderr.writer.writeAll("\n") catch {};

    for (0..4) |_| {
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

    for (0..4) |_| {
        writeCol(&stderr);
        stderr.writer.writeAll("\n") catch {};
    }

    stderr.writer.writeAll("\n") catch {};
}

pub fn deinit() void {}
