// The immediate-mode GUI implementation is based on concepts from Digital Grove (https://www.dgtlgrove.com/).

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const clamp = std.math.clamp;
const heap = std.heap;
const meta = std.meta;
const testing = std.testing;
const Wyhash = std.hash.Wyhash;

const chunk_pool = @import("chunk_pool.zig");
const datastruct = @import("datastruct.zig");
const DoublyLinkedList = datastruct.DoublyLinkedList;
const TaggedLinkedList = datastruct.TaggedLinkedList;
const win = @import("window.zig");
const Window = win.Window;

const log = std.log.scoped(.view);

pub const View = @This();

arena: heap.ArenaAllocator,

root: ?*Block,

block_count: u64,

mouse: [2]f32,

frame: u64,
frame_arenas: [2]heap.ArenaAllocator,
frame_chunks: [2]chunk_pool.ChunkAllocator,

stacks: Stacks,
pop_flags: u64,

cache: []DoublyLinkedList(Cache),

chunks: chunk_pool.ChunkAllocator,

pub fn init(self: *View, gpa: Allocator) !void {
    self.* = .{
        .mouse = @splat(0.0),
        .cache = undefined,
        .arena = .init(gpa),
        .root = null,
        .block_count = 0,
        .frame = 0,
        .frame_arenas = .{ .init(gpa), .init(gpa) },
        .frame_chunks = undefined,
        .stacks = .empty,
        .pop_flags = 0,
        .chunks = undefined,
    };

    const arena = self.arena.allocator();
    errdefer self.arena.deinit();

    for (&self.frame_chunks) |*pool| {
        try pool.init(arena, &.{
            .{ .capacity = 2048, .chunk_size = Stacks.NODE_SIZE },
            .{ .capacity = 2048, .chunk_size = @sizeOf(Block) },
        });
    }

    self.cache = try arena.alloc(DoublyLinkedList(Cache), 2048);
    @memset(self.cache, .empty);

    try self.chunks.init(arena, &.{.{ .capacity = 2048, .chunk_size = @sizeOf(Block) }});
}

pub fn deinit(self: *View) void {
    for (self.frame_arenas) |arena| arena.deinit();
    self.arena.deinit();
}

pub fn begin(self: *View, window: Window, resize: bool) !void {
    self.reset();
    errdefer self.reset();

    const size = try window.size();
    const mouse = try window.mouse();

    if (resize) {
        self.mouse = .{ -1.0, -1.0 };
    } else {
        self.mouse = .{ mouse.x, mouse.y };
    }

    self.nextAttrs(&.{
        .{ .width = .{ .fixed = size.w } },
        .{ .height = .{ .fixed = size.h } },
    });

    self.root = self.buildBlock(.{});

    self.pushAttr(.{ .parent = self.root.? });
}

pub fn finish(self: *View) void {
    const root = self.root orelse unreachable;

    inline for (0..2) |axis| {
        root.layout(axis);
    }

    for (self.cache) |*list| {
        var entry: ?*Cache = list.first;
        while (entry) |cache| {
            entry = cache.next;
            const cached: *Block = @fieldParentPtr("cache", cache);

            if (cached.touched_frame != self.frame) {
                list.remove(cache);
                self.chunks.allocator().destroy(cached);
            }
        }
    }

    self.frame += 1;

    const frame_index = self.frame % self.frame_arenas.len;

    _ = self.frame_arenas[frame_index].reset(.retain_capacity);
    _ = self.frame_chunks[frame_index].reset();
}

pub fn signalForBlock(self: *View, block: *Block) Signal {
    const flags = block.flags;

    var signal: Signal = .none;

    const mouse = self.mouse;
    const rect = block.rect;

    if (rect[0][0] <= mouse[0] and mouse[0] < rect[1][0] and
        rect[0][1] <= mouse[1] and mouse[1] < rect[1][1])
    {
        signal.mouseover = true;
    }

    if (flags.mouse and
        rect[0][0] <= mouse[0] and mouse[0] < rect[1][0] and
        rect[0][1] <= mouse[1] and mouse[1] < rect[1][1])
    {
        signal.hovered = true;
    }

    return signal;
}

pub fn fmt(self: *View, comptime format: []const u8, args: anytype) ![]u8 {
    const required = std.fmt.count(format, args);
    const frame_arena = self.frameArena();
    const buffer = try frame_arena.alloc(u8, required);
    return std.fmt.bufPrint(buffer, format, args) catch unreachable;
}

pub fn buildBlockFromStr(self: *View, string: []const u8, flags: Block.Flags) *Block {
    const chunk = if (std.mem.find(u8, string, "@@@")) |index|
        string[index + "@@@".len ..]
    else
        "";

    const key: ?u64 = if (chunk.len == 0) null else key: {
        var node = self.stacks.get(.parent).head;
        while (node) |current| : (node = current.next) {
            if (current.value.key) |parent_key| break :key Wyhash.hash(parent_key, chunk);
        }

        break :key Wyhash.hash(0, chunk);
    };

    return self.buildBlock(.{ .flags = flags, .key = key });
}

pub fn getBlock(self: *View, key: u64) ?*Block {
    const list = &self.cache[key % self.cache.len];
    var entry = list.first;

    while (entry) |cache| : (entry = cache.next) {
        const block: *Block = @fieldParentPtr("cache", cache);
        if (block.key == key) {
            return block;
        }
    }

    return null;
}

pub fn cacheBlock(self: *View, block: *Block, key: u64) void {
    const list = &self.cache[key % self.cache.len];

    block.key = key;

    list.append(&block.cache);
}

const Options = struct {
    flags: Block.Flags = .{},
    key: ?u64 = null,
};
pub fn buildBlock(self: *View, options: Options) *Block {
    const frame_chunks = self.frameChunks();
    const chunks = self.chunks.allocator();

    const block = bkl: {
        if (options.key) |key| {
            if (self.getBlock(key)) |cached| {
                if (cached.touched_frame == self.frame) {
                    log.warn("Repeated block key", .{});

                    const block = frame_chunks.create(Block) catch @panic("Block Chunk Overflow");
                    block.* = .empty;

                    break :bkl block;
                }

                cached.reset();

                break :bkl cached;
            } else {
                const block = chunks.create(Block) catch @panic("Block Chunk Overflow");
                block.* = .empty;

                self.cacheBlock(block, key);

                break :bkl block;
            }
        } else {
            const block = frame_chunks.create(Block) catch @panic("Block Chunk Overflow");
            block.* = .empty;

            break :bkl block;
        }
    };

    block.build(self, options.flags);

    return block;
}

pub fn pushAttr(self: *View, attr: Attribute) void {
    const chunks = self.frameChunks();

    switch (attr) {
        inline else => |value, flag| {
            assert(self.pop_flags & stackFlag(flag) == 0);

            const node = chunks.create(Node(flag)) catch @panic("Frame chunks overflow");
            node.* = .{ .value = value };
            self.stacks.prepend(flag, node);
        },
    }
}

pub fn popAttr(self: *View, comptime field: StackField) void {
    assert(self.pop_flags & stackFlag(field) == 0);
    if (self.stacks.pop(field) == null) unreachable;
}

pub fn nextAttr(self: *View, attr: Attribute) void {
    self.pushAttr(attr);
    self.flagStack(meta.activeTag(attr));
}

pub fn pushAttrs(self: *View, attrs: []const Attribute) void {
    for (attrs) |attr| self.pushAttr(attr);
}

pub fn popAttrs(self: *View, comptime fields: []const StackField) void {
    inline for (fields) |field| self.popAttr(field);
}

pub fn nextAttrs(self: *View, attrs: []const Attribute) void {
    for (attrs) |attr| self.nextAttr(attr);
}

fn frameArena(self: *View) Allocator {
    return self.frame_arenas[self.frame % self.frame_arenas.len].allocator();
}

fn frameChunks(self: *View) Allocator {
    return self.frame_chunks[self.frame % self.frame_arenas.len].allocator();
}

fn reset(self: *View) void {
    self.root = null;
    self.stacks = .empty;
    self.pop_flags = 0;
    self.block_count = 0;
}

fn flagStack(self: *View, field: StackField) void {
    self.pop_flags |= stackFlag(field);
}

fn popFlagged(self: *View) void {
    inline for (@typeInfo(Stacks.Tag).@"enum".fields) |field| {
        const flag = @as(u64, 1) << field.value;
        if (self.pop_flags & flag != 0) {
            self.pop_flags &= ~flag;
            if (self.stacks.pop(@enumFromInt(field.value)) == null) unreachable;
        }
    }
}

pub fn shrink(self: *View, per: f32) void {
    const parent = self.stacks.get(.parent).head;
    const axis: Axis = if (parent) |p| p.value.axis else .x;

    switch (axis) {
        .x => self.nextAttr(.{ .width_shrink = per }),
        .y => self.nextAttr(.{ .height_shrink = per }),
    }
}

pub fn spacer(self: *View, sizing: Sizing) *Block {
    const parent = self.stacks.get(.parent).head;
    const axis: Axis = if (parent) |p| p.value.axis else .x;

    switch (axis) {
        .x => self.nextAttr(.{ .width = sizing }),
        .y => self.nextAttr(.{ .height = sizing }),
    }

    return self.buildBlock(.{});
}

const Stacks = TaggedLinkedList(union(enum) {
    parent: *Block,
    axis: Axis,
    color: [4]f32,
    width: Sizing,
    width_shrink: f32,
    height: Sizing,
    height_shrink: f32,
    flags: Block.Flags,
});

pub const Attribute = Stacks.Value;
pub const Node = Stacks.Node;
pub const StackField = Stacks.Tag;

fn stackFlag(field: StackField) u64 {
    return @as(u64, 1) << @intFromEnum(field);
}

const Cache = struct {
    pub const _null: Cache = .{
        .next = null,
        .prev = null,
    };
    next: ?*Cache,
    prev: ?*Cache,
};

pub const Axis = enum(u1) { x = 0, y = 1 };

pub const Sizing = union(enum) {
    pub const none: Sizing = .{ .fixed = 0 };
    pub const grow: Sizing = .{ .percent = 1 };

    fit,
    fixed: f32,
    percent: f32,
};

pub const Signal = packed struct {
    const none: @This() = .{
        .hovered = false,
        .mouseover = false,
    };

    hovered: bool,
    mouseover: bool,
};

pub const Block = struct {
    children: DoublyLinkedList(Block),
    child_count: u8,

    next: ?*Block,
    prev: ?*Block,
    parent: ?*Block,

    key: ?u64,
    cache: Cache,
    touched_frame: u64,

    axis: Axis,
    sizing: [2]Sizing,
    shrink: [2]f32,
    color: [4]f32,
    flags: Flags,

    size: [2]f32,
    position: [2]f32,
    rect: [2][2]f32,
    bounds: [2]f32,

    pub const Flags = packed struct {
        pub const allowOverflow: Flags = .{ .overflow = 0b11 };

        overflow: u2 = 0,
        mouse: bool = false,
    };

    pub const empty: Block = .{
        .rect = @splat(@splat(0.0)),
        .cache = ._null,
        .children = .empty,
        .child_count = 0,
        .next = null,
        .prev = null,
        .parent = null,
        .axis = .x,
        .touched_frame = 0,
        .sizing = @splat(.none),
        .shrink = @splat(0.0),
        .color = @splat(0.0),
        .flags = .{},
        .size = @splat(0.0),
        .position = @splat(0.0),
        .bounds = @splat(0.0),
        .key = null,
    };

    fn build(self: *Block, view: *View, flags: Flags) void {
        if (view.stacks.get(.parent).head) |parent| {
            parent.value.child_count += 1;
            parent.value.children.append(self);
            self.parent = parent.value;
        }

        if (view.stacks.get(.axis).head) |node| self.axis = node.value;
        if (view.stacks.get(.color).head) |node| self.color = node.value;
        if (view.stacks.get(.width).head) |node| self.sizing[0] = node.value;
        if (view.stacks.get(.height).head) |node| self.sizing[1] = node.value;
        if (view.stacks.get(.width_shrink).head) |node| self.shrink[0] = clamp(node.value, 0.0, 1.0);
        if (view.stacks.get(.height_shrink).head) |node| self.shrink[1] = clamp(node.value, 0.0, 1.0);

        const stack_flags: u3 = if (view.stacks.get(.flags).head) |node| @bitCast(node.value) else 0;
        self.flags = @bitCast(@as(u3, @bitCast(flags)) | stack_flags);

        self.touched_frame = view.frame;

        view.block_count += 1;
        view.popFlagged();
    }

    pub fn reset(self: *Block) void {
        self.children = .empty;
        self.child_count = 0;
        self.next = null;
        self.prev = null;
        self.parent = null;

        self.axis = .x;
        self.sizing = @splat(.none);
        self.shrink = @splat(0.0);
        self.color = @splat(0.0);
        self.flags = .{};
    }

    pub fn nextPreOrder(self: *Block) ?*Block {
        if (self.children.first) |child| return child;

        var ancestor = self;
        while (true) {
            if (ancestor.next) |sibling| return sibling;
            ancestor = ancestor.parent orelse return null;
        }
    }

    pub fn firstPostOrder(self: *Block) *Block {
        var block = self;
        while (block.children.first) |child| block = child;
        return block;
    }

    pub fn nextPostOrder(self: *Block) ?*Block {
        const parent = self.parent orelse return null;
        return if (self.next) |sibling| sibling.firstPostOrder() else parent;
    }

    pub fn layout(self: *Block, axis: u1) void {
        self.resolveFixedSizing(axis);
        self.resolvePerSizing(axis);
        self.resolveFitSizing(axis);
        self.resolveOverflow(axis);
        self.resolveRect(axis);
    }

    pub fn resolveFixedSizing(self: *Block, axis: u1) void {
        var block: ?*Block = self;
        while (block) |current| : (block = current.nextPreOrder()) {
            switch (current.sizing[axis]) {
                .fixed => |fixed| current.size[axis] = fixed,
                else => {},
            }
        }
    }

    pub fn resolvePerSizing(self: *Block, axis: u1) void {
        var block: ?*Block = self;
        while (block) |current| : (block = current.nextPreOrder()) {
            switch (current.sizing[axis]) {
                .percent => |percent| {
                    const parent_size = parent_size: {
                        var node = current.parent;
                        while (node) |parent| : (node = parent.parent) {
                            switch (parent.sizing[axis]) {
                                .fixed, .percent => break :parent_size parent.size[axis],
                                else => {},
                            }
                        }

                        break :parent_size 0.0;
                    };

                    current.size[axis] = parent_size * percent;
                },
                else => {},
            }
        }
    }

    pub fn resolveFitSizing(self: *Block, axis: u1) void {
        var block: ?*Block = self.firstPostOrder();
        while (block) |current| : (block = current.nextPostOrder()) {
            switch (current.sizing[axis]) {
                .fit => {
                    var total: f32 = 0.0;
                    var children = current.children.first;
                    while (children) |child| : (children = child.next) {
                        if (@intFromEnum(current.axis) == axis) {
                            total += child.size[axis];
                        } else {
                            total = @max(total, child.size[axis]);
                        }
                    }

                    current.size[axis] = total;
                },
                else => {},
            }
        }
    }

    pub fn resolveOverflow(self: *Block, axis: u1) void {
        var block: ?*Block = self;
        while (block) |current| : (block = current.nextPreOrder()) {
            const allowed = current.size[axis];
            const overflow_mask = @as(u2, 1) << axis;

            if (@intFromEnum(current.axis) != axis and
                current.flags.overflow & overflow_mask == 0)
            {
                var children = current.children.first;
                while (children) |child| : (children = child.next) {
                    const size = child.size[axis];
                    const overflow = size - allowed;
                    const fix = clamp(overflow, 0, size);
                    if (fix > 0) child.size[axis] -= fix;
                }
            }

            if (@intFromEnum(current.axis) == axis and
                current.flags.overflow & overflow_mask == 0)
            {
                var used: f32 = 0.0;
                var available: f32 = 0.0;

                var children = current.children.first;
                while (children) |child| : (children = child.next) {
                    used += child.size[axis];
                    available += child.size[axis] * child.shrink[axis];
                }

                const overflow = used - allowed;

                if (overflow > 0 and available > 0) {
                    children = current.children.first;

                    while (children) |child| : (children = child.next) {
                        child.size[axis] -= child.size[axis] *
                            child.shrink[axis] *
                            clamp(overflow / available, 0, 1);
                    }
                }
            }

            if (current.flags.overflow & overflow_mask != 0) {
                var children = current.children.first;
                while (children) |child| : (children = child.next) {
                    switch (child.sizing[axis]) {
                        .percent => |percent| {
                            child.size[axis] = current.size[axis] * percent;
                        },
                        else => {},
                    }
                }
            }
        }
    }

    pub fn resolveRect(self: *Block, axis: u1) void {
        var block: ?*Block = self;
        while (block) |current| : (block = current.nextPreOrder()) {
            var position: f32 = 0.0;
            var bounds: f32 = 0.0;

            var children = current.children.first;
            while (children) |child| : (children = child.next) {
                child.position[axis] = position;

                if (@intFromEnum(current.axis) == axis) {
                    position += child.size[axis];
                    bounds += child.size[axis];
                } else {
                    bounds = @max(bounds, child.size[axis]);
                }

                child.rect[0][axis] = current.rect[0][axis] + child.position[axis];
                child.rect[1][axis] = child.rect[0][axis] + child.size[axis];

                for (0..2) |p| {
                    child.rect[p][axis] = @floor(child.rect[p][axis]);
                }
            }

            current.bounds[axis] = bounds;
        }
    }
};

test "Basic Operations" {
    const window: Window = .{};
    var view: View = undefined;
    try view.init(testing.allocator);
    defer view.deinit();

    const key: u64 = 42;
    const cache = &view.cache[key % view.cache.len];

    try view.begin(window, false);
    view.nextAttr(.{ .width = .{ .fixed = 10 } });
    _ = view.buildBlock(.{});
    view.nextAttr(.{ .width = .{ .fixed = 40 } });
    const first = view.buildBlock(.{ .key = key });
    view.pushAttr(.{ .parent = first });
    _ = view.buildBlock(.{});
    view.popAttr(.parent);
    view.finish();

    try testing.expectEqual(@as(usize, 1), cache.len());
    try testing.expectEqual([2]f32{ 40, 0 }, first.size);
    try testing.expectEqual([2]f32{ 10, 0 }, first.position);
    try testing.expectEqual(@as(u8, 1), first.child_count);

    try view.begin(window, false);
    view.nextAttrs(&.{
        .{ .axis = .y },
        .{ .width = .{ .fixed = 50 } },
    });
    const second = view.buildBlock(.{ .key = key });

    try testing.expectEqual(first, second);
    try testing.expectEqual([2]f32{ 40, 0 }, second.size);
    try testing.expectEqual([2]f32{ 10, 0 }, second.position);
    try testing.expectEqual(Axis.y, second.axis);
    try testing.expectEqual(Sizing{ .fixed = 50 }, second.sizing[0]);
    try testing.expect(second.children.is_empty());
    try testing.expectEqual(@as(u8, 0), second.child_count);
    view.finish();

    try testing.expectEqual(@as(usize, 1), cache.len());

    try view.begin(window, false);
    view.finish();

    try testing.expect(cache.is_empty());
}

test "Hash Block" {
    const window: Window = .{};
    var view: View = undefined;
    try view.init(testing.allocator);
    defer view.deinit();

    try view.begin(window, false);
    _ = view.buildBlockFromStr("First label@@@identity", .{});
    const first = view.root.?.children.last.?;
    try testing.expectEqual(Wyhash.hash(0, "identity"), first.key.?);
    view.finish();

    try view.begin(window, false);
    _ = view.buildBlockFromStr("Different label@@@identity", .{});
    const second = view.root.?.children.last.?;
    try testing.expectEqual(first, second);
    view.finish();

    try view.begin(window, false);
    _ = view.buildBlockFromStr("No identity@@@", .{});
    try testing.expectEqual(null, view.root.?.children.last.?.key);
    view.finish();

    try view.begin(window, false);
    _ = view.buildBlockFromStr("No marker", .{});
    try testing.expectEqual(null, view.root.?.children.last.?.key);
    view.finish();
}

test "Fixed Layout" {
    const window: Window = .{};
    var view: View = undefined;
    try view.init(testing.allocator);
    defer view.deinit();

    try view.begin(window, false);
    view.pushAttr(.{ .flags = .allowOverflow });

    view.nextAttrs(&.{ .{ .width = .grow }, .{ .height = .grow } });
    const wrapper = view.buildBlock(.{});
    view.pushAttr(.{ .parent = wrapper });

    view.nextAttrs(&.{ .{ .width = .{ .fixed = 800 } }, .{ .height = .{ .fixed = 900 } } });
    const first = view.buildBlock(.{});

    view.nextAttrs(&.{ .{ .width = .{ .fixed = 120 } }, .{ .height = .{ .fixed = 120 } } });
    const second = view.buildBlock(.{});

    view.popAttr(.parent);
    view.popAttr(.flags);
    view.finish();

    try testing.expectEqual([2]f32{ 800, 900 }, first.size);
    try testing.expectEqual([2]f32{ 120, 120 }, second.size);
    try testing.expectEqual([2]f32{ 800, 0 }, second.position);
    try testing.expectEqual([2]f32{ 920, 900 }, wrapper.bounds);
}

test "Percent Layout" {
    const window: Window = .{};
    var view: View = undefined;
    try view.init(testing.allocator);
    defer view.deinit();

    try view.begin(window, false);
    view.nextAttrs(&.{ .{ .width = .grow }, .{ .height = .grow } });
    const parent = view.buildBlock(.{});
    view.pushAttr(.{ .parent = parent });

    view.nextAttrs(&.{
        .{ .width = .{ .fixed = 100 } },
        .{ .height = .grow },
    });
    const first = view.buildBlock(.{});

    view.nextAttrs(&.{
        .{ .width = .grow },
        .{ .height = .grow },
        .{ .width_shrink = 1.0 },
    });
    const middle = view.buildBlock(.{});

    view.nextAttrs(&.{
        .{ .width = .{ .fixed = 100 } },
        .{ .height = .grow },
    });
    const last = view.buildBlock(.{});

    view.popAttr(.parent);
    view.finish();

    try testing.expectEqual([2]f32{ 100, 800 }, first.size);
    try testing.expectEqual([2]f32{ 400, 800 }, middle.size);
    try testing.expectEqual([2]f32{ 100, 800 }, last.size);
    try testing.expectEqual([2]f32{ 100, 0 }, middle.position);
    try testing.expectEqual([2]f32{ 500, 0 }, last.position);
}

test "Grow Layout" {
    const window: Window = .{};

    var view: View = undefined;
    try view.init(testing.allocator);
    defer view.deinit();

    try view.begin(window, false);
    view.nextAttrs(&.{ .{ .width = .{ .fixed = 400 } }, .{ .height = .{ .fixed = 300 } } });
    const parent = view.buildBlock(.{});
    view.pushAttr(.{ .parent = parent });

    view.nextAttrs(&.{ .{ .width = .{ .percent = 0.5 } }, .{ .height = .grow } });
    const child = view.buildBlock(.{});
    view.popAttr(.parent);
    view.finish();

    try testing.expectEqual([2]f32{ 200, 300 }, child.size);
}

test "fit sizing resolves from descendants" {
    const window: Window = .{};

    var view: View = undefined;
    try view.init(testing.allocator);
    defer view.deinit();

    try view.begin(window, false);
    view.nextAttrs(&.{ .{ .width = .fit }, .{ .height = .fit }, .{ .axis = .y } });
    const parent = view.buildBlock(.{});
    view.pushAttr(.{ .parent = parent });

    view.nextAttrs(&.{ .{ .width = .fit }, .{ .height = .fit } });
    const first = view.buildBlock(.{});
    view.pushAttr(.{ .parent = first });

    view.nextAttrs(&.{ .{ .width = .{ .fixed = 100 } }, .{ .height = .{ .fixed = 150 } } });
    _ = view.buildBlock(.{});
    view.nextAttrs(&.{ .{ .width = .{ .fixed = 100 } }, .{ .height = .{ .fixed = 150 } } });
    _ = view.buildBlock(.{});
    view.popAttr(.parent);

    view.nextAttrs(&.{ .{ .width = .{ .fixed = 400 } }, .{ .height = .{ .fixed = 450 } } });
    const second = view.buildBlock(.{});
    view.popAttr(.parent);
    view.finish();

    try testing.expectEqual([2]f32{ 200, 150 }, first.size);
    try testing.expectEqual([2]f32{ 400, 600 }, parent.size);
    try testing.expectEqual([2]f32{ 0, 150 }, second.position);
}
