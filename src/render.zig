//LICENSE: [GHOSTTY]
//LICENSE: [RADDEBUGGER]

const std = @import("std");
const Allocator = std.mem.Allocator;
const heap = std.heap;
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
const SinglyLinkedList = datastruct.SinglyLinkedList;
const Metal = @import("render/metal.zig");
const win = @import("window.zig");
const Window = win.Window;

const RECT_CAPACITY = PAGE_SIZE / std.math.gcd(PAGE_SIZE, @sizeOf(Rect));

const log = std.log.scoped(.render);

const BufferCount = Renderer.BufferCount;
const Buffer = Renderer.Buffer;
const Texture = Renderer.Texture;
const Context = Renderer.Context;

pub const Renderer = renderer: {
    if (!builtin.is_test) break :renderer Metal;

    break :renderer struct {
        const BufferCount = 1;

        pub fn init(_: *Renderer) !void {}

        pub fn deinit(_: *Renderer) void {}
    };
};

//The sync path i take it from this issue: https://github.com/ocornut/imgui/issues/9500
pub fn render(renderer: *Renderer, handle: *Handle, frame_state: *FrameState, sync: bool) void {
    renderer.start();
    defer renderer.end();

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

    var node: ?*BufferNode = frame_state.rects.nodes.head;
    while (node) |curr| : (node = curr.next) {
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
                .instance_count = curr.pool.reserved,
            },
        });
    }
}

pub fn syncTexture(
    renderer: *Renderer,
    texture: *const Texture,
    width: usize,
    height: usize,
    data: ?[]const u8,
) !void {
    if (width > texture.width or height > texture.height) {
        // Free our old texture
        texture.*.deinit();

        // Reallocate
        texture.* = try renderer.texture(width, height, data);
    }

    if (data) |d| {
        try texture.replaceRegion(0, 0, width, height, d);
    }
}

pub const Handle = struct {
    swap_chain: SwapChain,
    context: Context,

    pub fn init(self: *@This(), renderer: *Renderer, window: *Window, gpa: Allocator, io: Io) !void {
        self.* = .{ .swap_chain = undefined, .context = undefined };

        try self.swap_chain.init(renderer, gpa, io);
        errdefer self.swap_chain.deinit();

        try self.context.init(renderer, window);
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

    pub fn init(self: *@This(), renderer: *Renderer, gpa: Allocator, io: Io) !void {
        self.* = .{
            .io = io,
            .buffer = undefined,
        };

        for (&self.buffer) |*frame_state| {
            try frame_state.init(renderer, gpa);
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
    uniform_buffer: Buffer,

    atlas_texture: Texture,
    atlas_gen: usize,

    pub fn init(self: *FrameState, renderer: *Renderer, gpa: Allocator) !void {
        self.* = .{
            .atlas_texture = undefined,
            .atlas_gen = 0,
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

    pub fn rect(self: *FrameState, renderer: *Renderer, data: Rect) !void {
        const arena = self.arena.allocator();
        const list = &self.rects;

        const buffer = blk: {
            if (list.nodes.tail) |tail| {
                if (tail.pool.alloc()) |buffer| break :blk buffer;
            }

            if (self.free_rects.nodes.pop()) |node| {
                list.push(node);
                break :blk node.pool.alloc() orelse unreachable;
            }

            const node = try arena.create(BufferNode);
            try node.init(renderer, .{
                .capacity = RECT_CAPACITY,
                .chunk_size = @sizeOf(Rect),
                .alignment = .fromByteUnits(PAGE_SIZE),
            }, arena);
            list.push(node);

            break :blk node.pool.alloc() orelse unreachable;
        };

        assert(buffer.len == @sizeOf(Rect));

        const ptr: *Rect = @ptrCast(@alignCast(buffer.ptr));
        ptr.* = data;
    }

    pub fn deinit(self: *FrameState) void {
        self.atlas_texture.deinit();
        self.uniform_buffer.deinit();
        self.rects.deinit();
        self.free_rects.deinit();
        self.arena.deinit();
    }

    pub fn reset(self: *FrameState) void {
        var node = self.rects.nodes.head;
        while (node) |curr| : (node = curr.next) curr.pool.reset();

        self.free_rects.nodes.concatByMoving(&self.rects.nodes);
        self.uniforms = undefined;
    }
};

pub const BufferNode = struct {
    next: ?*BufferNode,
    buffer: Buffer,
    pool: ChunkPool,

    pub fn init(self: *BufferNode, renderer: *Renderer, opt: chunk_pool.Options, arena: Allocator) !void {
        self.* = .{
            .next = null,
            .buffer = undefined,
            .pool = undefined,
        };

        try self.pool.init(arena, opt);

        self.buffer = renderer.buffer(self.pool.ptr, self.pool.len);
    }

    pub fn deinit(self: *BufferNode) void {
        self.buffer.deinit();
    }
};

pub const BufferList = struct {
    const empty: BufferList = .{
        .nodes = .empty,
    };
    nodes: SinglyLinkedList(BufferNode),

    pub fn push(self: *BufferList, node: *BufferNode) void {
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
    corner_rads: [4]f32 align(16),
    style: Style align(16),
};

pub const Style = packed struct(u128) {
    border_thickness: f32 = 0.0,
    softness: f32 = 1.0,
    omit_src: f32 = 1.0,
    _padding: f32 = 0.0,
};

test {
    _ = FrameState;
}
