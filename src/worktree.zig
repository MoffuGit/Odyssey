const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const atomic = std.atomic;
const assert = std.debug.assert;

const Core = @import("core.zig");
const chunk_pool = @import("chunk_pool.zig");
const ChunkedPath = @import("chunked_path.zig");
const ent = @import("entity.zig");
const AnyEntity = ent.AnyEntity;
const Loop = @import("loop.zig");
const Waker = Loop.Waker;
const Completion = Loop.Completion;
const bench = @import("worktree/bench.zig");
const Scanner = @import("worktree/scanner.zig");
const Snapshot = @import("worktree/snapshot.zig");
const Entry = Snapshot.Entry;

const log = std.log.scoped(.worktree);

pub const Worktree = @This();

io: Io,
core: *Core,
gpa: Allocator,
any: AnyEntity,
scanning: bool,
snapshot: Snapshot,
scanner: *Scanner,

waker: Waker,
await: Completion,
await_c: Completion,

pub fn init(
    self: *Worktree,
    any: AnyEntity,
    core: *Core,
    io: Io,
    abs_path: []const u8,
) !void {
    const gpa = core.gpa;

    self.* = .{
        .any = any,
        .core = core,
        .io = io,
        .gpa = gpa,
        .scanning = false,
        .snapshot = undefined,
        .scanner = undefined,
        .await = .noop,
        .await_c = .noop,
        .waker = undefined,
    };

    try self.snapshot.init(abs_path, gpa, io);
    errdefer self.snapshot.deinit();

    self.waker = try core.await(&self.await, handleEvents);

    self.scanner = try Scanner.create(core, &self.snapshot, self.waker);
}

pub fn deinit(self: *Worktree) void {
    self.snapshot.deinit();
}

pub fn drop(self: *Worktree) void {
    self.scanner.stop();
    self.any.drop();
    self.core.cancel(
        &self.await_c,
        struct {
            fn noop(_: *Completion, _: *Loop, _: void) bool {
                return false;
            }
        }.noop,
        &self.await,
    );
    self.waker.close();
}

fn handleEvents(c: *Completion, _: *Loop, res: anyerror!void) bool {
    res catch return false;

    const self: *Worktree = @fieldParentPtr("await", c);

    self.core.update();
    defer self.core.endUpdate();

    while (self.scanner.events.pop()) |event| {
        switch (event) {
            .started => {
                log.debug("scanner for path \"{s}\" started", .{self.snapshot.abs_root});
                self.scanning = true;
            },
            .update => |updated| {
                self.snapshot.deinit();
                self.snapshot = updated.snapshot;
                self.scanning = updated.scanning;
            },
        }
    }

    self.core.notify(self);

    return true;
}

test "Worktree" {
    const gpa = testing.allocator;
    const io = testing.io;
    const chromium_path = @import("test_options").chromium_path;

    var core: Core = undefined;
    try core.init(gpa, io, .{});
    defer core.deinit();

    const worktree = try core.new(
        Worktree,
        init,
        .{
            io,
            chromium_path,
        },
    );
    defer worktree.drop();

    try testing.expectEqualStrings(worktree.snapshot.abs_root, chromium_path);
}

test {
    _ = bench;
}
