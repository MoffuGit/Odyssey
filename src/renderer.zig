//LICENSE: [GHOSTTY]
//LICENSE: [RADDEBUGGER]

const std = @import("std");
const Allocator = std.mem.Allocator;
const mem = std.mem;
const heap = std.heap;
const math = std.math;
const assert = std.debug.assert;
const testing = std.testing;
const Io = std.Io;
const PAGE_SIZE = heap.page_size_min;
const builtin = @import("builtin");

const c = @import("c");
const macos = @import("macos");
const objc = @import("objc");

const chunk_pool = @import("chunk_pool.zig");
const ChunkPool = chunk_pool.ChunkPool;
const datastruct = @import("datastruct.zig");
const Atlas = datastruct.Atlas;
const SinglyLinkedList = datastruct.SinglyLinkedList;
const Metal = @import("render/metal.zig");
const win = @import("window.zig");
const Window = win.Window;

pub const Renderer = renderer: {
    if (!builtin.is_test) break :renderer Metal;

    break :renderer struct {};
};

const BufferCount = Renderer.BufferCount;
const RECT_CAPACITY = PAGE_SIZE / std.math.gcd(PAGE_SIZE, @sizeOf(Rect));

var renderer: Renderer = undefined;

const log = std.log.scoped(.render);

pub fn init() !void {
    try renderer.init();
}

pub fn deinit() void {
    renderer.deinit();
}

//The sync path i take it from this issue: https://github.com/ocornut/imgui/issues/9500
pub fn render(handle: *Handle, frame_state: *FrameState, sync: bool) void {
    const width, const height = frame_state.uniforms.viewport_size;

    var target = handle.context.target(width, height, sync);

    var frame = renderer.frame(handle);
    defer frame.complete(&target, sync);

    var pass = frame.renderPass(&.{
        .{
            .target = target,
            .clear_color = .{ 1.0, 1.0, 1.0, 1.0 },
        },
    });
    defer pass.complete();

    var iter = frame_state.rects.nodes.iterator();
    while (iter.next()) |curr| {
        pass.step(.{
            .pipeline = renderer.shaders.pipelines.rect,
            .buffers = &.{curr.buffer},
            .uniforms = frame_state.uniform_buffer,
            .textures = &.{
                frame_state.atlas_texture,
            },
            .draw = .{
                .vertex_count = 4,
                .type = .triangle_strip,
                .instance_count = curr.reserved,
            },
        });
    }
}

pub fn syncTexture(
    texture: *Renderer.Texture,
    width: usize,
    height: usize,
    data: ?[]const u8,
) !void {
    if (width > texture.width or height > texture.height) {
        // Free our old texture
        texture.*.deinit();

        // Reallocate
        texture.* = try renderer.texture(width, height, null);
    }

    if (data) |d| {
        try texture.replaceRegion(0, 0, width, height, d);
    }
}

pub const Handle = struct {
    swap_chain: SwapChain,
    context: Renderer.Context,

    pub fn init(self: *@This(), window: *Window, gpa: Allocator, io: Io) !void {
        self.* = .{ .swap_chain = undefined, .context = undefined };

        try self.swap_chain.init(gpa, io);
        errdefer self.swap_chain.deinit();

        try self.context.init(&renderer, window);
        errdefer self.context.deinit();
    }

    pub fn nextFrame(self: *Handle) *FrameState {
        const next = self.swap_chain.nextFrame();
        next.reset();
        return next;
    }

    pub fn releaseFrame(self: *Handle) void {
        self.swap_chain.releaseFrame();
    }

    pub fn deinit(self: *@This()) void {
        self.context.deinit();
        self.swap_chain.deinit();
    }
};

pub const SwapChain = struct {
    io: Io,
    buffer: [BufferCount]FrameState,
    index: std.math.IntFittingRange(0, BufferCount) = 0,
    semaphore: std.Io.Semaphore = .{ .permits = BufferCount },

    pub fn init(self: *@This(), gpa: Allocator, io: Io) !void {
        self.* = .{
            .io = io,
            .buffer = undefined,
        };

        for (&self.buffer) |*frame_state| {
            try frame_state.init(gpa);
        }
    }

    pub fn deinit(self: *@This()) void {
        for (0..BufferCount) |_| self.semaphore.waitUncancelable(self.io);
        for (&self.buffer) |*frame_state| frame_state.deinit();
    }

    pub fn nextFrame(self: *@This()) *FrameState {
        self.semaphore.waitUncancelable(self.io);
        errdefer self.semaphore.post();
        self.index = (self.index + 1) % BufferCount;
        return &self.buffer[self.index];
    }

    pub fn releaseFrame(self: *@This()) void {
        self.semaphore.post(self.io);
    }
};

pub const FrameState = struct {
    arena: heap.ArenaAllocator,

    free_rects: BufferList,
    rects: BufferList,

    uniforms: Uniforms align(PAGE_SIZE),
    uniform_buffer: Renderer.Buffer,

    atlas_texture: Renderer.Texture,
    atlas_generation: usize,

    pub fn init(self: *FrameState, gpa: Allocator) !void {
        self.* = .{
            .atlas_texture = undefined,
            .atlas_generation = 0,
            .uniform_buffer = undefined,
            .arena = .init(gpa),
            .uniforms = undefined,
            .free_rects = .empty,
            .rects = .empty,
        };

        self.uniform_buffer = renderer.buffer(@ptrCast(&self.uniforms), PAGE_SIZE);

        self.atlas_texture = try renderer.texture(1, 1, null);
        errdefer self.atlas_texture.deinit();
    }

    pub fn deinit(self: *FrameState) void {
        self.atlas_texture.deinit();
        self.uniform_buffer.deinit();
        self.rects.deinit();
        self.free_rects.deinit();
        self.arena.deinit();
    }

    pub fn rect(self: *FrameState, data: Rect) !void {
        const arena = self.arena.allocator();
        const list = &self.rects;

        const buffer = blk: {
            if (list.nodes.tail) |tail| {
                if (tail.alloc()) |buffer| break :blk buffer;
            }

            if (self.free_rects.nodes.pop()) |pool| {
                list.push(pool);
                break :blk pool.alloc() orelse unreachable;
            }

            const pool = try arena.create(Pool);
            try pool.init(.{
                .capacity = RECT_CAPACITY,
                .size = @sizeOf(Rect),
                .alignment = .fromByteUnits(PAGE_SIZE),
            }, arena);
            list.push(pool);

            break :blk pool.alloc() orelse unreachable;
        };

        assert(buffer.len == @sizeOf(Rect));

        const ptr: *Rect = @ptrCast(@alignCast(buffer.ptr));
        ptr.* = data;
    }

    pub fn syncAtlas(self: *FrameState, atlas: *Atlas) !void {
        if (self.atlas_texture.width < atlas.width or self.atlas_texture.height < atlas.height) {
            self.atlas_texture.deinit();
            self.atlas_texture = try renderer.texture(atlas.width, atlas.height, null);
        }

        try self.atlas_texture.replaceRegion(0, 0, atlas.width, atlas.height, atlas.buffer);
    }

    pub fn reset(self: *FrameState) void {
        var iter = self.rects.nodes.iterator();
        while (iter.next()) |curr| curr.reset();

        self.free_rects.nodes.concatByMoving(&self.rects.nodes);
        self.uniforms = undefined;
    }
};

pub const Pool = struct {
    next: ?*Pool,
    buffer: Renderer.Buffer,
    ptr: [*]u8,
    reserved: u32,
    size: u32,
    len: usize,

    pub const Options = struct {
        capacity: u32,
        size: u32,
        alignment: ?mem.Alignment = null,
    };

    pub fn init(self: *Pool, opt: Options, arena: Allocator) !void {
        assert(opt.capacity < math.maxInt(u32));
        assert(opt.capacity > 0);
        assert(opt.size > 0);

        const len = @as(usize, opt.size) * @as(usize, opt.capacity);
        const alignment: mem.Alignment = opt.alignment orelse .fromByteUnits(opt.size);
        const ptr = arena.rawAlloc(len, alignment, @returnAddress()) orelse return error.OutOfMemory;

        self.* = .{
            .next = null,
            .reserved = 0,
            .buffer = undefined,
            .ptr = ptr,
            .size = opt.size,
            .len = len,
        };

        self.buffer = renderer.buffer(self.ptr, self.len);
    }

    pub fn deinit(self: *Pool) void {
        self.buffer.deinit();
    }

    pub fn reset(self: *Pool) void {
        self.reserved = 0;
    }

    pub fn alloc(self: *Pool) ?[]u8 {
        const index = self.reserved;
        const offset = index * self.size;

        if (offset == self.len) return null;
        self.reserved += 1;

        return self.ptr[offset .. offset + self.size];
    }
};

pub const BufferList = struct {
    const empty: BufferList = .{
        .nodes = .empty,
    };
    nodes: SinglyLinkedList(Pool),

    pub fn push(self: *BufferList, node: *Pool) void {
        self.nodes.append(node);
    }

    pub fn deinit(self: *BufferList) void {
        while (self.nodes.pop()) |node| node.deinit();
    }
};

pub const Uniforms = extern struct {
    viewport_size: [2]f32 align(8),
};

pub const Rect = extern struct {
    position: [4]f32 align(16),
    src_position: [4]f32 align(16),
    color_0: [4]f32 align(16),
    color_1: [4]f32 align(16),
    color_2: [4]f32 align(16),
    color_3: [4]f32 align(16),
    corner_rads: [4]f32 align(16) = @splat(0.0),
    style: Style align(16) = .{},
};

pub const Style = packed struct(u128) {
    border_thickness: f32 = 0.0,
    softness: f32 = 1.0,
    omit_src: f32 = 1.0,
    rotate_src: f32 = 0.0,
};

test {
    _ = FrameState;
}
