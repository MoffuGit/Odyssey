const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const heap = std.heap;

const chromium_path = @import("test_options").chromium_path;
const zlob = @import("zlob");

const Core = @import("../core.zig");
const Bench = @import("../bench.zig");
const constants = @import("../constants.zig");
const MAX_PATH_LEN = constants.MAX_PATH_LEN;
const ent = @import("../entity.zig");
const global = @import("../global.zig");
const Worktree = @import("../worktree.zig");
const Snapshot = @import("../worktree/snapshot.zig");
const log = std.log.scoped(.worktree_bench);

const mode: enum { smoke, benchmark } =
    if (@import("test_options").benchmark) .benchmark else .smoke;

const WorktreeObserver = struct {
    scanning: bool = true,
    observer: Core.Observer = .noop,

    pub fn callback(observer: *Core.Observer, _: *Core, worktree: *Worktree) bool {
        const parent: *@This() = @fieldParentPtr("observer", observer);
        parent.scanning = worktree.scanning;
        return parent.scanning;
    }
};

test "benchmark: Worktree initial scan" {
    if (mode == .smoke) return;

    try global.init();
    defer global.deinit();

    const gpa = std.heap.c_allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    const io = threaded.io();

    var core: Core = undefined;
    try core.init(gpa, io, .{});
    defer core.deinit();

    const arena = core.arena.allocator();

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

    Bench.report("Worktree Scanned Path={s}", .{chromium_path});
    var durations: [8]Io.Duration = undefined;

    for (0..durations.len) |idx| {
        bench.start(io);

        const worktree = try core.new(
            Worktree,
            Worktree.init,
            .{
                io,
                chromium_path,
            },
        );
        defer worktree.drop();

        var observer: WorktreeObserver = .{};

        try core.observe(worktree, WorktreeObserver.callback, &observer.observer);

        while (observer.scanning) {
            core.run(.once);
            core.flush();
        }

        durations[idx] = bench.stop(io);

        verify(&core, zlob_set, worktree) catch |err| {
            log.err("Verify err={}", .{err});
        };
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

fn verify(core: *Core, zlob_set: std.StringHashMap(void), worktree: *Worktree) !void {
    var arena = std.heap.ArenaAllocator.init(core.gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const snapshot = &worktree.snapshot;

    const root_name = snapshot.root_name;
    const prefix_len = root_name.len + 1;
    var ody_set = std.StringHashMap(void).init(alloc);
    defer ody_set.deinit();

    var it = snapshot.entries.iter();
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
