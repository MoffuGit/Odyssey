// const std = @import("std");
// const testing = std.testing;
//
// const core = @import("core.zig");
// const datastruct = @import("datastruct.zig");
// const Key = datastruct.slotmap.Key;
// const global = @import("global.zig");
// const scheduler = @import("scheduler.zig");
// const bench = @import("worktree/bench.zig");
// const scanner = @import("worktree/scanner.zig");
// const Snapshot = @import("worktree/snapshot.zig");
//
// /// Core's cached copy of a worktree the scanner published, resolved by the
// /// key of its entity. Read it with `core.worktree`.
// pub const Worktree = @This();
//
// pub const Context = Key.Context;
//
// key: Key,
// next: ?*Worktree = null,
// prev: ?*Worktree = null,
//
// /// The scanner generation `snapshot` and `status` were cloned at.
// generation: u64,
// status: scanner.Status,
// snapshot: Snapshot,
//
// test "Worktree" {
//     const gpa = testing.allocator;
//     const io = testing.io;
//     const chromium_path = @import("test_options").chromium_path;
//
//     try global.init();
//     defer global.deinit();
//
//     try scheduler.init(gpa, io);
//     defer scheduler.deinit();
//
//     try scanner.init(gpa, io);
//     defer scanner.deinit();
//
//     try core.init(gpa, io);
//     defer core.deinit();
//
//     try core.pushCmd(.{ .open_worktree = chromium_path });
//
//     try core.flush();
//
//     const key = core.core.root.childrens.first.?.key;
//
//     const worktree = while (true) {
//         if (try core.worktree(key)) |worktree| break worktree;
//         try io.sleep(.fromMilliseconds(1), .awake);
//     };
//     try testing.expectEqualStrings(chromium_path, worktree.snapshot.abs_root);
//
//     try core.pushCmd(.{ .close_worktree = key });
//     try core.flush();
//
//     try testing.expect(try core.worktree(key) == null);
// }
//
// test {
//     _ = bench;
// }
