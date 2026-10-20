const std = @import("std");

const banner = @import("banner.zig");

pub var cpu_count: usize = 2;

pub fn init() !void {
    cpu_count = try std.Thread.getCpuCount();

    try banner.log();
}

pub fn deinit() void {}
