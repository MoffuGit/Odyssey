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
const rng2 = @import("math.zig").rng2;
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

hot: ?u64,
active: ?u64,

events: DoublyLinkedList(Event),

cache: []DoublyLinkedList(Cache),

chunks: chunk_pool.ChunkAllocator,

pub fn init(self: *View, gpa: Allocator) !void {
    self.* = .{
        .active = null,
        .hot = null,
        .events = .empty,
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
            .{ .capacity = 128, .chunk_size = @sizeOf(Event) },
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
    const window_size = try window.size();
    const mouse = try window.mouse();

    self.root = null;
    self.stacks = .empty;
    self.pop_flags = 0;
    self.block_count = 0;

    if (self.active == null) self.hot = null;

    if (resize) {
        self.mouse = .{ -1.0, -1.0 };
    } else {
        self.mouse = .{ mouse.x, mouse.y };
    }

    self.width(.{ .fixed = window_size.w });
    self.height(.{ .fixed = window_size.h });

    self.root = self.blk(.{});

    self.pushAttr(.{ .width = .fit });
    self.pushAttr(.{ .height = .fit });
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
    self.events = .empty;

    const frame_index = self.frame % self.frame_arenas.len;

    _ = self.frame_arenas[frame_index].reset(.retain_capacity);
    _ = self.frame_chunks[frame_index].reset();
}

pub fn pushEvent(self: *View, @"type": win.EventType) void {
    const chunks = self.frameChunks();

    const event = chunks.create(Event) catch @panic("Chunk Overflow");

    event.* = .{ .type = @"type" };

    self.events.append(event);
}

pub fn signal(self: *View, block: *Block) Signal {
    const flags = block.flags;

    var _signal: Signal = .none;

    const mouse = self.mouse;
    const rect = block.rect;

    const in_bounds = rng2.contains(rect, mouse);

    var node = self.events.first;

    while (node) |event| {
        node = event.next;

        var consumed = false;

        switch (event.type) {
            .mouse_button => |data| {
                if (flags.mouse and
                    data.type == .mouse_button_pressed and
                    in_bounds)
                {
                    consumed = true;
                    self.hot = block.key;
                    self.active = block.key;
                    _signal.mouse_pressed = true;
                }

                if (flags.mouse and
                    data.type == .mouse_button_released and
                    self.active == block.key)
                {
                    consumed = true;
                    self.active = null;
                    _signal.mouse_released = true;
                    if (in_bounds) _signal.clicked = true else self.hot = null;
                }
            },
            else => unreachable,
        }

        if (consumed) self.events.remove(event);
    }

    if (flags.mouse and in_bounds and
        (self.hot == null or self.hot == block.key) and
        (self.active == null or self.active == block.key))
    {
        _signal.hovered = true;
        self.hot = block.key;
    }

    if (in_bounds) {
        _signal.mouse_over = true;
    }

    return _signal;
}

pub fn fmt(self: *View, comptime format: []const u8, args: anytype) ![]u8 {
    const frame_arena = self.frameArena();

    const required = std.fmt.count(format, args);
    const buffer = try frame_arena.alloc(u8, required);

    return std.fmt.bufPrint(buffer, format, args) catch unreachable;
}

pub fn blkStr(self: *View, str: []const u8, flags: Block.Flags) *Block {
    const key = key: {
        if (std.mem.find(u8, str, "@@@")) |index| {
            const chunk = str[index + "@@@".len ..];

            if (chunk.len == 0) break :key null else {
                var node = self.stacks.get(.parent).head;
                while (node) |current| : (node = current.next) {
                    if (current.value.key) |parent_key| {
                        break :key Wyhash.hash(parent_key, chunk);
                    }
                }

                break :key Wyhash.hash(0, chunk);
            }
        } else break :key null;
    };

    return self.blk(.{ .flags = flags, .key = key });
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

pub fn blk(self: *View, options: Options) *Block {
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

    self.blkComplete(block);

    return block;
}

pub fn blkEnd(self: *View) void {
    const block = self.stacks.get(.parent).head.?.value;
    if (block.flags.padding) {
        const value = self.stacks.get(.padding).head.?.value;
        self.spacer(value.@"0", value.@"1");

        self.popAttr(.padding);
    }

    self.popAttr(.parent);
}

fn blkComplete(self: *View, block: *Block) void {
    inline for (@typeInfo(Stacks.Tag).@"enum".fields) |field| {
        const flag = @as(u64, 1) << field.value;
        if (self.pop_flags & flag != 0) {
            self.pop_flags &= ~flag;
            if (self.stacks.pop(@enumFromInt(field.value)) == null) unreachable;
        }
    }

    self.pushAttr(.{ .parent = block });

    if (block.flags.padding) {
        const value = self.stacks.get(.padding).head.?.value;
        self.spacer(value.@"0", value.@"1");
    }

    self.block_count += 1;
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

    const chunks = self.frameChunks();
    const node = self.stacks.pop(field) orelse unreachable;
    chunks.destroy(node);
}

pub fn popAttrs(self: *View, comptime fields: []const StackField) void {
    inline for (fields) |field| self.popAttr(field);
}

pub fn nextAttr(self: *View, attr: Attribute) void {
    assert(attr != .padding);

    self.pushAttr(attr);
    self.flagStack(meta.activeTag(attr));
}

fn frameArena(self: *View) Allocator {
    return self.frame_arenas[self.frame % self.frame_arenas.len].allocator();
}

fn frameChunks(self: *View) Allocator {
    return self.frame_chunks[self.frame % self.frame_arenas.len].allocator();
}

fn flagStack(self: *View, field: StackField) void {
    self.pop_flags |= stackFlag(field);
}

pub fn padding(self: *View, sizing: Sizing, per: f32) void {
    self.pushAttr(.{ .padding = .{ sizing, per } });
    self.nextFlag().padding = true;
}

pub fn shrink(self: *View, per: f32) void {
    const parent = self.stacks.get(.parent).head;
    const axis: Axis = if (parent) |p| p.value.axis else .x;

    switch (axis) {
        .x => self.nextAttr(.{ .width_shrink = per }),
        .y => self.nextAttr(.{ .height_shrink = per }),
    }
}

pub fn rounded(self: *View, radius: f32) void {
    self.nextAttr(.{ .radius = @splat(radius) });
}

pub fn size(self: *View, sizing: Sizing) void {
    self.width(sizing);
    self.height(sizing);
}

pub fn width(self: *View, sizing: Sizing) void {
    self.nextAttr(.{ .width = sizing });
}

pub fn height(self: *View, sizing: Sizing) void {
    self.nextAttr(.{ .height = sizing });
}

pub fn nextFlag(self: *View) *Block.Flags {
    if (self.pop_flags & stackFlag(.flags) == 0) {
        self.nextAttr(.{ .flags = .{} });
    }

    const h = self.stacks.get(.flags).head orelse unreachable;
    return &h.value;
}

pub fn background(self: *View, color: [4]f32) void {
    self.nextAttr(.{ .background = color });
    self.nextFlag().background = true;
}

pub fn border(self: *View, thickness: f32, color: [4]f32) void {
    self.nextAttr(.{ .border = color });
    self.nextAttr(.{ .thickness = thickness });
    self.nextFlag().border = true;
}

pub fn col(self: *View) void {
    self.nextAttr(.{ .axis = .y });
}

pub fn row(self: *View) void {
    self.nextAttr(.{ .axis = .x });
}

pub fn spacer(self: *View, sizing: Sizing, per: f32) void {
    const parent = self.stacks.get(.parent).head;
    const axis: Axis = if (parent) |p| p.value.axis else .x;

    switch (axis) {
        .x => self.width(sizing),
        .y => self.height(sizing),
    }

    self.shrink(per);

    _ = self.blk(.{});
    self.blkEnd();
}

pub fn button(self: *View, str: []const u8) Signal {
    const block = self.blkStr(str, .{ .mouse = true });
    self.blkEnd();

    return self.signal(block);
}

const Event = struct {
    next: ?*Event = null,
    prev: ?*Event = null,
    type: win.EventType,
};

const Stacks = TaggedLinkedList(union(enum) {
    parent: *Block,
    axis: Axis,
    background: [4]f32,
    width: Sizing,
    width_shrink: f32,
    height: Sizing,
    height_shrink: f32,
    flags: Block.Flags,
    radius: [4]f32,
    border: [4]f32,
    thickness: f32,
    padding: struct { Sizing, f32 },
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
        .mouse_over = false,
        .mouse_pressed = false,
        .mouse_released = false,
        .clicked = false,
    };

    hovered: bool,
    mouse_over: bool,
    mouse_pressed: bool,
    mouse_released: bool,
    clicked: bool,
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
    border: [4]f32,
    thickness: f32,
    flags: Flags,
    radius: [4]f32,

    size: [2]f32,
    position: [2]f32,
    rect: [2][2]f32,
    bounds: [2]f32,

    pub const Flags = packed struct {
        overflow: u2 = 0,
        mouse: bool = false,
        background: bool = false,
        border: bool = false,
        padding: bool = false,
    };

    const FlagBits = u6;

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
        .radius = @splat(0.0),
        .border = @splat(0.0),
        .thickness = 0.0,
    };

    fn build(self: *Block, view: *View, flags: Flags) void {
        if (view.stacks.get(.parent).head) |parent| {
            parent.value.child_count += 1;
            parent.value.children.append(self);
            self.parent = parent.value;
        }

        if (view.stacks.get(.axis).head) |node| self.axis = node.value;
        if (view.stacks.get(.width).head) |node| self.sizing[0] = node.value;
        if (view.stacks.get(.height).head) |node| self.sizing[1] = node.value;
        if (view.stacks.get(.radius).head) |node| self.radius = node.value;
        if (view.stacks.get(.width_shrink).head) |node| self.shrink[0] = clamp(node.value, 0.0, 1.0);
        if (view.stacks.get(.height_shrink).head) |node| self.shrink[1] = clamp(node.value, 0.0, 1.0);

        const stack_flags: FlagBits = if (view.stacks.get(.flags).head) |node| @bitCast(node.value) else 0;
        self.flags = @bitCast(@as(FlagBits, @bitCast(flags)) | stack_flags);

        if (self.flags.background) {
            self.color = view.stacks.get(.background).head.?.value;
        }

        if (self.flags.border) {
            self.border = view.stacks.get(.border).head.?.value;
            self.thickness = view.stacks.get(.thickness).head.?.value;
        }

        self.touched_frame = view.frame;
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
                    const child_size = child.size[axis];

                    const overflow = child_size - allowed;
                    const fix = clamp(overflow, 0, child_size);
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

                inline for (0..2) |p| {
                    child.rect[p][axis] = @floor(child.rect[p][axis]);
                }
            }

            current.bounds[axis] = bounds;
        }
    }
};
