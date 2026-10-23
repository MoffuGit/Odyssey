const std = @import("std");

const Bench = @import("bench.zig");
const Buffer = @import("buffer.zig");
const chunk_pool = @import("chunk_pool.zig");
const chunked_path = @import("chunked_path.zig");
const Core = @import("core.zig");
const datastruct = @import("datastruct.zig");
const entity = @import("entity.zig");
const font = @import("font.zig");
const log = @import("log.zig");
const Loop = @import("loop.zig");
const patch = @import("patch.zig");
const render = @import("render.zig");
const Scheduler = @import("scheduler.zig");
const subscription = @import("subscription.zig");
const View = @import("view.zig");
const Worktree = @import("worktree.zig");

pub const std_options: std.Options = .{
    .logFn = log.logFn,
    .log_level = .info,
};

test {
    _ = font;
    _ = View;
    _ = render;
    _ = Scheduler;
    _ = Bench;
    _ = patch;
    _ = Buffer;
    _ = Core;
    _ = chunk_pool;
    _ = chunked_path;
    _ = datastruct;
    _ = entity;
    _ = subscription;
    _ = Loop;
    _ = Worktree;
}
