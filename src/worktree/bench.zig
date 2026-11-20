const std = @import("std");
const Io = std.Io;

const chromium_path = @import("test_options").chromium_path;
const zlob = @import("zlob");

const Bench = @import("../bench.zig");
const constants = @import("../constants.zig");
const MAX_PATH_LEN = constants.MAX_PATH_LEN;
const core = @import("../core.zig");
const global = @import("../global.zig");
const scheduler = @import("../scheduler.zig");
const scanner = @import("scanner.zig");
const Worktree = @import("../worktree.zig");
const log = std.log.scoped(.worktree_bench);

const mode: enum { smoke, benchmark } =
    if (@import("test_options").benchmark) .benchmark else .smoke;

test "benchmark: Worktree initial scan" {
    if (mode == .smoke) return;

    try global.init();
    defer global.deinit();

    const gpa = std.heap.c_allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    try scheduler.init(gpa, io);
    defer scheduler.deinit();

    try scanner.init(gpa, io);
    defer scanner.deinit();

    try core.init(gpa, io);
    defer core.deinit();

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var bench: Bench = .init();
    defer bench.deinit();

    const zlob_res = try zlob.walk.collect(arena, chromium_path, .{
        .include_hidden = false,
        .respect_git = true,
        .report_dirs = true,
    });

    var zlob_set = std.StringHashMap(void).init(arena);

    for (zlob_res.entries) |e| {
        try zlob_set.put(try arena.dupe(u8, e.relativePath()), {});
    }

    Bench.report("path={s}", .{chromium_path});
    var durations: [8]Io.Duration = undefined;

    for (0..durations.len) |idx| {
        bench.start(io);

        const key = try core.openWorktree(chromium_path);

        // Poll the core cache like a frame would: it clones the scanner's
        // state only when the scanner published a new generation.
        const worktree = while (true) {
            core.flush();

            const worktree = (try core.worktree(key)).?;
            if (worktree.status == .idle) break worktree;

            try io.sleep(.fromMilliseconds(1), .awake);
        };

        durations[idx] = bench.stop(io);

        verify(gpa, zlob_set, worktree) catch |err| {
            log.err("Verify err={}", .{err});
        };

        try core.closeWorktree(key);
        core.flush();
    }

    const min = Bench.min(&durations);
    const max = Bench.max(&durations);
    const mean = Bench.mean(&durations);
    Bench.report("iterations={}, min={}ms, max={}ms, mean={}ms", .{
        durations.len,
        min.toMilliseconds(),
        max.toMilliseconds(),
        mean.toMilliseconds(),
    });
}

fn verify(gpa: std.mem.Allocator, zlob_set: std.StringHashMap(void), worktree: *const Worktree) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const snapshot = &worktree.snapshot;

    const root_name = snapshot.root_name;
    const prefix_len = root_name.len + 1;
    var ody_set = std.StringHashMap(void).init(alloc);
    defer ody_set.deinit();

    var it = snapshot.entries.iterator();
    while (it.next()) |kv| {
        const entry = kv.value;
        if (entry.meta.hidden or entry.meta.ignored) continue;

        var buf: [MAX_PATH_LEN]u8 = undefined;
        const len = entry.path.read(&buf);
        const full = buf[0..len];

        if (len == root_name.len and std.mem.eql(u8, full, root_name)) continue;

        if (full.len < prefix_len or full[root_name.len] != '/') {
            std.debug.print("verifyWorktreeScan: unexpected path shape: '{s}'\n", .{full});
            return error.WorktreeSnapshotMismatch;
        }
        const rel = full[prefix_len..];
        try ody_set.put(try alloc.dupe(u8, rel), {});
    }

    const ody_count = ody_set.count();
    const zlob_count = zlob_set.count();

    if (ody_count == zlob_count) return;

    std.debug.print("odyssey visible entries: {d}\n", .{ody_count});
    std.debug.print("zlob    visible entries: {d}\n", .{zlob_count});
    std.debug.print("===================================\n", .{});
}
