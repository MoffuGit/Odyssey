const std = @import("std");
const process = std.process;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const posix = std.posix;

const log = std.log.scoped(.global);

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
    const t = std.debug.lockStderr(&buffer).terminal();
    defer std.debug.unlockStderr();

    t.writer.writeAll("\n") catch {};

    for (0..4) |_| {
        writeCol(&t);
        t.writer.writeAll("\n") catch {};
    }

    writeCol(&t);
    t.writer.writeAll("    ") catch {};
    t.setColor(.bold) catch {};
    t.writer.print("ODYSSEY\n", .{}) catch {};
    t.setColor(.reset) catch {};

    writeCol(&t);
    t.writer.writeAll("    ") catch {};
    t.setColor(.dim) catch {};
    t.writer.print("{s}\n", .{hostname}) catch {};
    t.setColor(.reset) catch {};

    writeCol(&t);
    t.writer.writeAll("    ") catch {};
    t.setColor(.dim) catch {};
    t.writer.print("@{s} ", .{@tagName(builtin.mode)}) catch {};
    t.setColor(.reset) catch {};

    t.setColor(.yellow) catch {};
    t.writer.print("{f}\n", .{builtin.zig_version}) catch {};
    t.setColor(.reset) catch {};

    for (0..4) |_| {
        writeCol(&t);
        t.writer.writeAll("\n") catch {};
    }

    t.writer.writeAll("\n") catch {};
}

pub fn deinit() void {}
