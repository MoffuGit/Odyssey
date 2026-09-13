//LICENSE: [GHOSTTY]
//LICENSE: [RADDEBUGGER]

const std = @import("std");
const Allocator = std.mem.Allocator;
const heap = std.heap;
const assert = std.debug.assert;
const testing = std.testing;
const Io = std.Io;
const builtin = @import("builtin");

const c = @import("c");
const macos = @import("macos");
const objc = @import("objc");

const chunk_pool = @import("chunk_pool.zig");
const ChunkPool = chunk_pool.ChunkPool;
const datastruct = @import("datastruct.zig");
const SinglyLinkedList = datastruct.SinglyLinkedList;
const Metal = @import("renderer/metal.zig");
const win = @import("window.zig");
const Window = win.Window;

const PAGE_SIZE = heap.page_size_min;
const RECT_CAPACITY = PAGE_SIZE / std.math.gcd(PAGE_SIZE, @sizeOf(Rect));

const log = std.log.scoped(.render);

pub const Renderer = renderer: {
    if (!builtin.is_test) break :renderer Metal;

    break :renderer struct {
        pub const Buffer = struct {
            pub fn release(_: *const @This()) void {}
        };

        pub fn init(_: *Renderer) !void {}

        pub fn deinit(_: *Renderer) void {}

        pub fn buffer(_: *Renderer, _: [*]u8, _: usize, _: anytype) Buffer {
            return .{};
        }
    };
};

pub const Handle = renderer: {
    if (!builtin.is_test) break :renderer Metal.Handle;

    break :renderer struct {
        pub fn init(_: *Handle, _: *const Renderer, _: *Window, _: Allocator, _: Io) !void {}

        pub fn deinit(_: *Handle) void {}
    };
};

//The sync path i take it from this issue: https://github.com/ocornut/imgui/issues/9500
pub fn renderFrame(renderer: *Renderer, handle: *Handle, frame_state: *FrameState, sync: bool) void {
    const width, const height = frame_state.uniforms.viewport_size;

    handle.update(width, height, sync);
    var target = handle.target();
    var frame = renderer.frame(handle);
    defer frame.complete(&target, sync);

    var pass = frame.renderPass(&.{
        .{
            .target = target,
            .clear_color = .{ 1.0, 1.0, 1.0, 1.0 },
        },
    });
    defer pass.complete();

    // bytesNoCopy requires both ends of the wrapped region to be page-aligned.
    const uniform = renderer.buffer(
        @ptrCast(&frame_state.uniforms),
        PAGE_SIZE,
        .{ .storage_mode = .shared, .cpu_cache_mode = .write_combined },
    );

    defer uniform.release();

    var node: ?*BufferNode = frame_state.rects.nodes.head;
    while (node) |curr| : (node = curr.next) {
        pass.step(.{
            .pipeline = renderer.shaders.pipelines.rect,
            .buffers = &.{curr.buffer.buffer},
            .uniforms = uniform.buffer,
            .draw = .{
                .vertex_count = 4,
                .type = .triangle_strip,
                .instance_count = curr.pool.reserved,
            },
        });
    }
}

pub const Uniforms = extern struct {
    viewport_size: [2]f32 align(8),
};

pub const Rect = extern struct {
    position: [4]f32 align(16),
    color_0: [4]f32 align(16),
    color_1: [4]f32 align(16),
    color_2: [4]f32 align(16),
    color_3: [4]f32 align(16),
    corner_rads: [4]f32 align(16),
    border: f32 align(4),
};

pub const FrameState = struct {
    arena: heap.ArenaAllocator,

    free_rects: BufferList,
    rects: BufferList,

    uniforms: Uniforms align(PAGE_SIZE),

    pub fn init(self: *FrameState, gpa: Allocator) !void {
        self.* = .{
            .arena = .init(gpa),
            .uniforms = undefined,
            .free_rects = .empty,
            .rects = .empty,
        };
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
    buffer: Renderer.Buffer,
    pool: ChunkPool,

    pub fn init(self: *BufferNode, renderer: *Renderer, opt: chunk_pool.Options, arena: Allocator) !void {
        self.* = .{
            .next = null,
            .buffer = undefined,
            .pool = undefined,
        };

        try self.pool.init(arena, opt);

        self.buffer = renderer.buffer(
            self.pool.ptr,
            self.pool.len,
            .{
                .storage_mode = .shared,
                .cpu_cache_mode = .write_combined,
            },
        );
    }

    pub fn deinit(self: *BufferNode) void {
        self.buffer.release();
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

test {
    _ = FrameState;
}
