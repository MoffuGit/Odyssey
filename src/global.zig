const std = @import("std");

pub var cpu_count: usize = 2;

pub fn init() !void {
    cpu_count = try std.Thread.getCpuCount();
}

pub fn deinit() void {}
