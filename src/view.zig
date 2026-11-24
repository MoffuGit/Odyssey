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
const HashTable = datastruct.HashTable;
const DoublyLinkedList = datastruct.DoublyLinkedList;
const TaggedLinkedList = datastruct.TaggedLinkedList;
const font = @import("font.zig");
const Run = font.Run;
const rng2 = @import("math.zig").rng2;
const win = @import("window.zig");
const Window = win.Window;

const log = std.log.scoped(.view);

threadlocal var local: *View = undefined;

pub const View = struct {
    arena: heap.ArenaAllocator,
    chunks: chunk_pool.ChunkAllocator,
    mouse: [2]f32,
    block_count: u64,
    root: ?*Block,

    frame: u64,
    frame_t: f32,
    frame_arenas: [2]heap.ArenaAllocator,
    frame_chunks: [2]chunk_pool.ChunkAllocator,

    stacks: Stacks,
    pop_flags: u64,
    hot: ?u64,
    active: ?u64,
    events: DoublyLinkedList(EventNode),
    block_cache: HashTable(u64, Cached, Block.Context),
    animation_cache: HashTable(u64, Cached, Animation.Context),
    active_animations: DoublyLinkedList(Animation),

    pub fn init(self: *View, gpa: Allocator) !void {
        self.* = .{
            .frame_t = 0,
            .active = null,
            .hot = null,
            .events = .empty,
            .mouse = @splat(0.0),
            .block_cache = undefined,
            .animation_cache = undefined,
            .arena = .init(gpa),
            .root = null,
            .block_count = 0,
            .frame = 0,
            .frame_arenas = .{ .init(gpa), .init(gpa) },
            .frame_chunks = undefined,
            .stacks = .empty,
            .pop_flags = 0,
            .chunks = undefined,
            .active_animations = .empty,
        };

        const arena = self.arena.allocator();
        errdefer self.arena.deinit();

        for (&self.frame_chunks) |*chunk| {
            try chunk.init(arena, &.{
                .{ .capacity = 2048, .chunk_size = @sizeOf(Attribute) + @sizeOf(?*Attribute) },
                .{ .capacity = 2048, .chunk_size = @sizeOf(Block) },
            });
        }

        try self.chunks.init(arena, &.{
            .{ .capacity = 2048, .chunk_size = @sizeOf(Block) },
            .{ .capacity = 2048, .chunk_size = @sizeOf(Animation) },
        });
        try self.block_cache.init(2048, .{}, arena);
        try self.animation_cache.init(2048, .{}, arena);
    }

    pub fn deinit(self: *View) void {
        for (self.frame_arenas) |arena| arena.deinit();
        self.arena.deinit();
    }

    pub fn pushEvent(self: *View, evt: Event) void {
        const chunks = self.frameChunks();

        const node = chunks.create(EventNode) catch @panic("Chunk Overflow");

        node.* = .{ .event = evt };

        self.events.append(node);
    }

    fn frameArena(self: *View) Allocator {
        return self.frame_arenas[self.frame % self.frame_arenas.len].allocator();
    }

    fn frameChunks(self: *View) Allocator {
        return self.frame_chunks[self.frame % self.frame_arenas.len].allocator();
    }
};

pub fn begin(view: *View, window: Window, resize: bool, fnt: u64) void {
    local = view;

    const chunks = local.chunks.allocator();

    const monitor = window.monitor();
    const window_size = window.size() catch .{ 0.0, 0.0 };

    local.frame_t = 1.0 / monitor.refreshRate();
    local.root = null;
    local.stacks = .empty;
    local.pop_flags = 0;
    local.block_count = 0;

    if (local.active == null) local.hot = null;

    if (resize) {
        local.mouse = .{ -1.0, -1.0 };
    } else {
        local.mouse = window.mouse() catch .{ -1.0, -1.0 };
    }

    width(.{ .fixed = window_size[0] });
    height(.{ .fixed = window_size[1] });

    local.root = blk(.{});

    pushAttr(.{ .width = .fit });
    pushAttr(.{ .height = .fit });
    pushAttr(.{ .font_family = fnt });
    pushAttr(.{ .font_size = 32.0 });

    var iter = local.active_animations.iterator();
    while (iter.next()) |animation| {
        if (animation.last_frame + 2 >= local.frame) break;

        _ = local.animation_cache.remove(animation.key);
        local.active_animations.remove(animation);
        chunks.destroy(animation);
    }
}

pub fn finish() void {
    const chunks = local.chunks.allocator();
    const root = local.root orelse unreachable;

    inline for (0..2) |axis| {
        root.layout(axis);
    }

    {
        var iter = local.block_cache.iterator();

        while (iter.next()) |cached| {
            const block: *Block = @fieldParentPtr("cached", cached);

            if (block.touched_frame != local.frame) {
                iter.remove();
                chunks.destroy(block);
            }
        }
    }

    {
        var iter = local.animation_cache.iterator();
        while (iter.next()) |cached| {
            const animation: *Animation = @fieldParentPtr("cached", cached);

            switch (animation.kind) {
                .exponential => |expo| {
                    animation.current += (animation.target - animation.current) * expo.rate;
                },
                else => unreachable,
            }
        }
    }

    local.frame += 1;
    local.events = .empty;

    const frame_index = local.frame % local.frame_arenas.len;

    _ = local.frame_arenas[frame_index].reset(.retain_capacity);
    _ = local.frame_chunks[frame_index].reset();
}

pub fn sample(key: u64) ?f32 {
    const cached = local.animation_cache.get(key) orelse return null;
    const animation: *Animation = @fieldParentPtr("cached", cached);
    return animation.current;
}

pub fn getSeed() u64 {
    var seed: u64 = 0;
    var iter = local.stacks.get(.parent).iterator();
    while (iter.next()) |node| {
        if (node.value.key) |key| {
            seed = key;
            break;
        }
    }

    return seed;
}

pub fn keyFromString(seed: u64, str: []const u8) ?u64 {
    var key: ?u64 = null;
    if (std.mem.find(u8, str, "@@@")) |index| {
        const chunk = str[index + "@@@".len ..];

        if (chunk.len != 0) {
            key = Wyhash.hash(seed, chunk);
        }
    }

    return key;
}

pub fn textPosition(block: *Block) ?struct { f32, f32 } {
    const metrics = font.metrics(block.font_family, block.font_size) orelse return null;
    const dim = if (block.run) |run| run.dimensions else return null;

    var position: [2]f32 = @splat(0.0);
    position[1] = @floor((block.rect[0][1] + block.rect[1][1]) / 2.0 + (metrics.ascent / 2.0 + metrics.descent / 2.0));

    switch (block.text_align) {
        .left => position[0] = block.rect[0][0] + block.text_padding,
        .center => {
            position[0] = @trunc((block.rect[0][0] + block.rect[1][0]) / 2.0 - dim[0] / 2.0);
        },
        .right => {
            position[0] = @trunc(block.rect[1][0] - dim[0] - block.text_padding);
            position[0] = std.math.clamp(position[0], block.rect[0][0], block.rect[1][0]);
        },
    }
    return .{ position[0], position[1] };
}

pub fn displayString(str: []const u8) []const u8 {
    const idx = std.mem.find(u8, str, "@@@") orelse str.len;

    return str[0..idx];
}

pub fn setDisplayString(block: *Block, str: []const u8) void {
    const arena = local.frameArena();

    const dupe = arena.dupe(u8, str) catch return;
    const display = displayString(str);

    block.string = dupe;
    if (display.len == 0) return;

    block.run = font.run(
        block.font_family,
        block.font_size,
        display,
    ) catch |err| {
        log.err("Run err={}", .{err});
        return;
    };
}

pub fn signal(block: *Block) Signal {
    const flags = block.flags;

    var sign: Signal = .none;

    const mouse = local.mouse;
    const rect = block.rect;

    const in_bounds = rng2.contains(rect, mouse);

    var iter = local.events.iterator();
    while (iter.next()) |node| {
        var consumed = false;

        switch (node.event) {
            .mouse_button => |data| {
                if (flags.mouse and
                    data.type == .mouse_button_pressed and
                    in_bounds)
                {
                    consumed = true;
                    local.hot = block.key;
                    local.active = block.key;
                    sign.mouse_pressed = true;
                }

                if (flags.mouse and
                    data.type == .mouse_button_released and
                    local.active == block.key)
                {
                    consumed = true;
                    local.active = null;
                    sign.mouse_released = true;
                    if (in_bounds) sign.clicked = true else local.hot = null;
                }
            },
            else => unreachable,
        }

        if (consumed) local.events.remove(node);
    }

    if (flags.mouse and in_bounds and
        (local.hot == null or local.hot == block.key) and
        (local.active == null or local.active == block.key))
    {
        sign.hovered = true;
        local.hot = block.key;
    }

    if (in_bounds) {
        sign.mouse_over = true;
    }

    if (block.key) |key| {
        sign.hot = key == local.hot;
        sign.active = key == local.active;
    }

    return sign;
}

pub fn animate(key: u64, opts: Animation.Options) f32 {
    const chunks = local.chunks.allocator();

    var animation: *Animation = undefined;

    if (local.animation_cache.get(key)) |cached| {
        animation = @fieldParentPtr("cached", cached);
        local.active_animations.remove(animation);
    } else {
        animation = chunks.create(Animation) catch @panic("Chunk Overflow");
        animation.* = .{
            .last_frame = local.frame,
            .first_frame = local.frame,
            .current = opts.initial,
            .initial = opts.initial,
            .target = opts.target,
            .kind = opts.kind,
            .key = key,
        };
        local.animation_cache.insert(key, &animation.cached);
    }

    animation.last_frame = local.frame;
    animation.initial = opts.initial;
    animation.target = opts.target;
    animation.kind = opts.kind;

    local.active_animations.append(animation);

    if (opts.reset) {
        animation.current = opts.initial;
    }

    switch (opts.kind) {
        .exponential => |expo| {
            assert(expo.epsilon != 0);

            if (expo.rate == 1.0 or @abs(animation.current - opts.target) < @abs(expo.epsilon)) {
                animation.current = opts.target;
            }
        },
        else => unreachable,
    }

    return animation.current;
}

pub fn fmt(comptime format: []const u8, args: anytype) ![]u8 {
    const frame_arena = local.frameArena();

    const required = std.fmt.count(format, args);
    const buffer = try frame_arena.alloc(u8, required);

    return std.fmt.bufPrint(buffer, format, args) catch unreachable;
}

pub fn blk(options: Block.Options) *Block {
    const frame_chunks = local.frameChunks();
    const chunks = local.chunks.allocator();

    const cached = bkl: {
        const str = options.str orelse break :bkl null;
        const key = keyFromString(getSeed(), str) orelse break :bkl null;

        if (local.block_cache.get(key)) |c| {
            const block: *Block = @fieldParentPtr("cached", c);

            if (block.touched_frame == local.frame) {
                log.warn("Repeated block key", .{});
                break :bkl null;
            }

            block.reset();
            break :bkl block;
        } else {
            const block = chunks.create(Block) catch @panic("Block Chunk Overflow");
            block.* = .empty;
            block.key = key;

            local.block_cache.insert(key, &block.cached);
            break :bkl block;
        }
    };

    const block = if (cached) |c| c else bkl: {
        const block = frame_chunks.create(Block) catch @panic("Block Chunk Overflow");
        block.* = .empty;

        break :bkl block;
    };

    block.build(local, options.flags);

    inline for (@typeInfo(Stacks.Field).@"enum".field_values) |value| {
        const flag = @as(u64, 1) << value;
        if (local.pop_flags & flag != 0) {
            local.pop_flags &= ~flag;
            if (local.stacks.pop(@fromBackingInt(value)) == null) unreachable;
        }
    }

    pushAttr(.{ .parent = block });

    if (block.flags.padding) {
        const value = local.stacks.get(.padding).head.?.value;
        spacer(value.@"0", value.@"1");
    }

    local.block_count += 1;

    if (block.flags.text) {
        if (options.str) |str| setDisplayString(block, str);
    }

    if (block.flags.animate) assert(block.key != null);

    return block;
}

pub fn blkEnd() void {
    const block = local.stacks.get(.parent).head.?.value;
    if (block.flags.padding) {
        const value = local.stacks.get(.padding).head.?.value;
        spacer(value.@"0", value.@"1");

        popAttr(.padding);
    }

    popAttr(.parent);
}

pub fn pushAttr(attr: Attribute) void {
    const chunks = local.frameChunks();

    switch (attr) {
        inline else => |value, flag| {
            assert(local.pop_flags & stackFlag(flag) == 0);

            const node = chunks.create(Node(flag)) catch @panic("Frame chunks overflow");
            node.* = .{ .value = value };
            local.stacks.prepend(flag, node);
        },
    }
}

pub fn popAttr(comptime field: StackField) void {
    assert(local.pop_flags & stackFlag(field) == 0);

    const chunks = local.frameChunks();
    const node = local.stacks.pop(field) orelse unreachable;
    chunks.destroy(node);
}

pub fn popAttrs(comptime fields: []const StackField) void {
    inline for (fields) |field| local.popAttr(field);
}

pub fn nextAttr(attr: Attribute) void {
    assert(attr != .padding);

    pushAttr(attr);
    flagStack(meta.activeTag(attr));
}

fn flagStack(field: StackField) void {
    local.pop_flags |= stackFlag(field);
}

pub fn padding(sizing: Sizing, factor: f32) void {
    pushAttr(.{ .padding = .{ sizing, factor } });
    nextFlag().padding = true;
}

pub fn shrink(factor: f32) void {
    const parent = local.stacks.get(.parent).head;
    const axis: Axis = if (parent) |p| p.value.axis else .x;

    switch (axis) {
        .x => nextAttr(.{ .width_shrink = factor }),
        .y => nextAttr(.{ .height_shrink = factor }),
    }
}

pub fn rounded(radius: f32) void {
    nextAttr(.{ .radius = @splat(radius) });
}

pub fn fontFamily(value: u64) void {
    nextAttr(.{ .font_family = value });
}

pub fn fontSize(value: f32) void {
    nextAttr(.{ .font_size = value });
}

pub fn textColor(value: [4]f32) void {
    nextAttr(.{ .text_color = value });
}

pub fn textAlign(value: TextAlign) void {
    nextAttr(.{ .text_align = value });
}

pub fn textPadding(value: f32) void {
    nextAttr(.{ .text_padding = value });
}

pub fn scale(value: f32) void {
    nextAttr(.{ .scale = value });
}

pub fn size(sizing: Sizing) void {
    width(sizing);
    height(sizing);
}

pub fn width(sizing: Sizing) void {
    nextAttr(.{ .width = sizing });
}

pub fn height(sizing: Sizing) void {
    nextAttr(.{ .height = sizing });
}

pub fn nextFlag() *Block.Flags {
    if (local.pop_flags & stackFlag(.flags) == 0) {
        nextAttr(.{ .flags = .{} });
    }

    const h = local.stacks.get(.flags).head orelse unreachable;
    return &h.value;
}

pub fn background(color: [4]f32) void {
    nextAttr(.{ .background = color });
    nextFlag().background = true;
}

pub fn border(thickness: f32, color: [4]f32) void {
    nextAttr(.{ .border = color });
    nextAttr(.{ .thickness = thickness });
    nextFlag().border = true;
}

pub fn col() void {
    nextAttr(.{ .axis = .y });
}

pub fn row() void {
    local.nextAttr(.{ .axis = .x });
}

pub fn spacer(sizing: Sizing, factor: f32) void {
    const parent = local.stacks.get(.parent).head;
    const axis: Axis = if (parent) |p| p.value.axis else .x;

    switch (axis) {
        .x => width(sizing),
        .y => height(sizing),
    }

    shrink(factor);

    _ = blk(.{});
    blkEnd();
}

pub fn button(str: []const u8) Signal {
    const block = blk(.{
        .str = str,
        .flags = .{
            .mouse = true,
            .text = true,
            .animate = true,
        },
    });
    blkEnd();

    return signal(block);
}

const EventNode = struct {
    next: ?*EventNode = null,
    prev: ?*EventNode = null,
    event: Event,
};

const Event = union(enum) {
    none,
    key: win.Key,
    key_char: u32,
    mouse_motion: win.MouseMotion,
    mouse_button: win.MouseButton,
    mouse_scroll: win.MouseScroll,
    data_drop,
    data_drag,
};

pub const Attribute = union(enum) {
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
    font_size: f32,
    font_family: u64,
    text_color: [4]f32,
    text_align: TextAlign,
    text_padding: f32,
    scale: f32,
};

const Stacks = TaggedLinkedList(Attribute);
pub const Node = Stacks.Node;
pub const StackField = Stacks.Field;

fn stackFlag(field: StackField) u64 {
    return @as(u64, 1) << @backingInt(field);
}

const Animation = struct {
    next: ?*Animation = null,
    prev: ?*Animation = null,
    cached: Cached = .{},
    initial: f32,
    target: f32,
    kind: AnimationKind,
    current: f32,
    first_frame: u64,
    last_frame: u64,
    key: u64,

    pub const Options = struct {
        initial: f32,
        target: f32,
        kind: AnimationKind,
        reset: bool = false,
    };

    pub const Context = struct {
        pub fn hash(_: @This(), k: u64) u64 {
            return k;
        }
        pub fn eql(_: @This(), k: u64, cached: *Cached) bool {
            const animation: *Animation = @fieldParentPtr("cached", cached);
            return k == animation.key;
        }
    };
};

pub const AnimationKind = union(enum) {
    exponential: struct {
        rate: f32,
        epsilon: f32 = 0.005,
    },
    easing: struct {
        duration: f32,
        cubic_bezier: [4]f32,
    },
};

const Cached = struct {
    next: ?*Cached = null,
    prev: ?*Cached = null,
};

pub const TextAlign = enum { left, center, right };

pub const Axis = enum(u1) { x = 0, y = 1 };

pub const Sizing = union(enum) {
    pub const none: Sizing = .{ .fixed = 0 };
    pub const grow: Sizing = .{ .percent = 1 };

    fit,
    text: f32,
    fixed: f32,
    percent: f32,
};

pub const Signal = packed struct {
    const none: @This() = .{
        .hot = false,
        .hovered = false,
        .mouse_over = false,
        .mouse_pressed = false,
        .mouse_released = false,
        .clicked = false,
        .active = false,
    };

    hot: bool,
    active: bool,
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
    cached: Cached,
    touched_frame: u64,

    axis: Axis,
    scale: f32,
    sizing: [2]Sizing,
    shrink: [2]f32,
    color: [4]f32,
    border: [4]f32,
    thickness: f32,
    flags: Flags,
    radius: [4]f32,
    font_size: f32,
    font_family: u64,
    text_color: [4]f32,
    text_align: TextAlign,
    text_padding: f32,
    string: ?[]const u8,
    run: ?Run,

    size: [2]f32,
    position: [2]f32,
    rect: [2][2]f32,
    bounds: [2]f32,

    pub const Options = struct {
        flags: Flags = .{},
        str: ?[]const u8 = null,
    };

    pub const Flags = packed struct {
        overflow: u2 = 0,
        mouse: bool = false,
        background: bool = false,
        border: bool = false,
        padding: bool = false,
        text: bool = false,
        animate: bool = false,
    };

    const FlagBits = @typeInfo(Flags).@"struct".backing_integer.?;

    pub const Context = struct {
        pub fn hash(_: @This(), k: u64) u64 {
            return k;
        }
        pub fn eql(_: @This(), k: u64, cached: *Cached) bool {
            const block: *Block = @fieldParentPtr("cached", cached);
            return k == block.key;
        }
    };

    pub const empty: Block = .{
        .scale = 1.0,
        .text_padding = 0.0,
        .text_align = .left,
        .run = null,
        .string = null,
        .font_family = 0,
        .font_size = 0.0,
        .rect = @splat(@splat(0.0)),
        .cached = .{},
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
        .text_color = @splat(0.0),
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
        if (view.stacks.get(.font_size).head) |node| self.font_size = node.value;
        if (view.stacks.get(.font_family).head) |node| self.font_family = node.value;
        if (view.stacks.get(.text_color).head) |node| self.text_color = node.value;
        if (view.stacks.get(.scale).head) |node| self.scale = node.value;
        if (view.stacks.get(.text_align).head) |node| self.text_align = node.value;
        if (view.stacks.get(.text_padding).head) |node| self.text_padding = node.value;
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
        self.border = @splat(0.0);
        self.radius = @splat(0.0);
        self.scale = 1.0;
        self.flags = .{};
        self.string = null;
        self.run = null;
    }

    pub fn nextPre(self: *Block) ?*Block {
        if (self.children.first) |child| return child;

        var ancestor = self;
        while (true) {
            if (ancestor.next) |sibling| return sibling;
            ancestor = ancestor.parent orelse return null;
        }
    }

    pub fn firstPost(self: *Block) *Block {
        var block = self;
        while (block.children.first) |child| block = child;
        return block;
    }

    pub fn nextPost(self: *Block) ?*Block {
        const parent = self.parent orelse return null;
        return if (self.next) |sibling| sibling.firstPost() else parent;
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
        while (block) |current| : (block = current.nextPre()) {
            switch (current.sizing[axis]) {
                .fixed => |fixed| current.size[axis] = fixed,
                .text => |base| {
                    const dim = if (current.run) |run| run.dimensions else .{ 0.0, 0.0 };
                    current.size[axis] = base + dim[axis] + current.text_padding * 2;
                },
                else => {},
            }
        }
    }

    pub fn resolvePerSizing(self: *Block, axis: u1) void {
        var block: ?*Block = self;
        while (block) |current| : (block = current.nextPre()) {
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
        var block: ?*Block = self.firstPost();
        while (block) |current| : (block = current.nextPost()) {
            switch (current.sizing[axis]) {
                .fit => {
                    var total: f32 = 0.0;
                    var children = current.children.first;
                    while (children) |child| : (children = child.next) {
                        if (@backingInt(current.axis) == axis) {
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
        while (block) |current| : (block = current.nextPre()) {
            const allowed = current.size[axis];
            const overflow_mask = @as(u2, 1) << axis;

            if (@backingInt(current.axis) != axis and
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

            if (@backingInt(current.axis) == axis and
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
        while (block) |current| : (block = current.nextPre()) {
            var position: f32 = 0.0;
            var bounds: f32 = 0.0;

            var children = current.children.first;
            while (children) |child| : (children = child.next) {
                child.position[axis] = position;

                if (@backingInt(current.axis) == axis) {
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

            const center = (current.rect[0][axis] + current.rect[1][axis]) * 0.5;
            const half_size = (current.rect[1][axis] - current.rect[0][axis]) * 0.5 * current.scale;

            current.rect[0][axis] = @floor(center - half_size);
            current.rect[1][axis] = @floor(center + half_size);
        }
    }
};
