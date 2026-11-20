const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const File = Io.File;
const atomic = std.atomic;
const heap = std.heap;

const chunk_pool = @import("../chunk_pool.zig");
const ChunkAllocator = chunk_pool.ChunkAllocator;
const ChunkedPathStore = @import("../chunked_path.zig");
const ChunkedPath = ChunkedPathStore.ChunkedPath;
const constants = @import("../constants.zig");
const MAX_PATH_LEN = constants.MAX_PATH_LEN;
const datastruct = @import("../datastruct.zig");
const btree = datastruct.btree;

const Entries = btree.BPlusTree(ChunkedPath, Entry, cmpPath);

fn cmpPath(a: ChunkedPath, b: ChunkedPath) std.math.Order {
    return a.cmp(&b);
}

pub const Entry = struct {
    id: u64,
    path: ChunkedPath,
    meta: Meta,
};

pub const Meta = struct {
    mtime: Io.Timestamp,
    size: u64,
    inode: u64,
    kind: File.Kind,
    hidden: bool,
    ignored: bool,
    state: enum {
        loaded,
        pending,
        unloaded,
    },
};

pub const NODE_SIZE = Entries.NODE_SIZE;

const Snapshot = @This();

io: Io,
arena: heap.ArenaAllocator,
chunks: ChunkAllocator,

entries: Entries,

abs_root: []u8,
root_name: []u8,

next_entry_id: atomic.Value(u64),

pub fn init(
    self: *Snapshot,
    abs_path: []const u8,
    gpa: Allocator,
    io: Io,
) !void {
    self.* = .{
        .io = io,
        .arena = .init(gpa),
        .chunks = undefined,
        .abs_root = undefined,
        .root_name = undefined,
        .entries = undefined,
        .next_entry_id = .init(0),
    };

    const arena = self.arena.allocator();
    errdefer self.arena.deinit();

    self.abs_root = try arena.dupe(u8, abs_path);
    self.root_name = try arena.dupe(u8, std.fs.path.basename(self.abs_root));

    try self.chunks.init(arena, &.{
        .{ .capacity = 1024 * 1024, .chunk_size = NODE_SIZE },
    });

    try self.entries.init(self.chunks.allocator());
}

pub fn insert(self: *Snapshot, path: ChunkedPath, meta: Meta) void {
    _ = self.entries.insert(self.chunks.allocator(), path, .{
        .path = path,
        .meta = meta,
        .id = self.next_entry_id.fetchAdd(1, .monotonic),
    }) catch @panic("Snapshot Nodes Overflow");
}

pub fn clone(self: *const Snapshot, gpa: Allocator) !Snapshot {
    var copy: Snapshot = .{
        .io = self.io,
        .arena = .init(gpa),
        .chunks = undefined,
        .entries = undefined,
        .abs_root = undefined,
        .root_name = undefined,
        .next_entry_id = .init(self.next_entry_id.load(.monotonic)),
    };
    errdefer copy.arena.deinit();
    const arena = copy.arena.allocator();

    copy.abs_root = try arena.dupe(u8, self.abs_root);
    copy.root_name = try arena.dupe(u8, self.root_name);

    try copy.chunks.init(arena, &.{
        .{ .capacity = 1024 * 1024, .chunk_size = NODE_SIZE },
    });
    copy.entries = try self.entries.clone(copy.chunks.allocator());

    return copy;
}

pub fn deinit(self: *Snapshot) void {
    self.arena.deinit();
}
