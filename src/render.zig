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

const PAGE_SIZE = heap.pageSize();

const log = std.log.scoped(.render);

pub const Renderer = renderer: {
    if (!builtin.is_test) break :renderer Metal;

    break :renderer struct {
        pub fn init(_: *Renderer) !void {}

        pub fn deinit(_: *Renderer) void {}
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

    const uniform = renderer.buffer(
        @ptrCast(frame_state.uniforms),
        @sizeOf(Uniforms),
        .{ .storage_mode = .shared, .cpu_cache_mode = .write_combined },
    );

    defer uniform.release();

    var node: ?*BufferNode = frame_state.rects.nodes.head;
    while (node) |curr| : (node = curr.next) {
        const ptr = curr.pool.ptr;
        const instances = curr.pool.reserved;

        const rect = renderer.buffer(
            @ptrCast(ptr),
            @sizeOf(Rect) * instances,
            .{ .storage_mode = .shared, .cpu_cache_mode = .write_combined },
        );
        defer rect.release();

        pass.step(.{
            .pipeline = renderer.shaders.pipelines.rect,
            .buffers = &.{rect.buffer},
            .uniforms = uniform.buffer,
            .draw = .{
                .vertex_count = 4,
                .type = .triangle_strip,
                .instance_count = instances,
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
};

pub const FrameState = struct {
    arena: heap.ArenaAllocator,
    rects: BufferList,
    uniforms: *Uniforms,

    pub fn init(self: *FrameState, gpa: Allocator) !void {
        self.* = .{
            .arena = .init(gpa),
            .uniforms = undefined,
            .rects = .empty,
        };
    }

    pub fn uniform(self: *FrameState, data: Uniforms) !void {
        const arena = self.arena.allocator();

        const buffer = arena.rawAlloc(
            @sizeOf(Uniforms),
            .fromByteUnits(PAGE_SIZE),
            @returnAddress(),
        ) orelse return error.OutOfMemory;
        const ptr: *Uniforms = @ptrCast(@alignCast(buffer));
        ptr.* = data;

        self.uniforms = ptr;
    }

    pub fn rect(self: *FrameState, data: Rect) !void {
        const arena = self.arena.allocator();
        const list = &self.rects;

        if (list.nodes.is_empty()) {
            const node = try arena.create(BufferNode);
            try node.init(.{
                .capacity = 256,
                .chunk_size = @sizeOf(Rect),
                .alignment = .fromByteUnits(PAGE_SIZE),
            }, arena);
            list.push(node);
        }

        const buffer = ptr: {
            if (list.nodes.head.?.pool.alloc()) |ptr| break :ptr ptr;

            const node = try arena.create(BufferNode);
            try node.init(.{
                .capacity = 256,
                .chunk_size = @sizeOf(Rect),
                .alignment = .fromByteUnits(PAGE_SIZE),
            }, arena);
            list.push(node);

            break :ptr node.pool.alloc() orelse unreachable;
        };

        assert(buffer.len == @sizeOf(Rect));

        const ptr: *Rect = @ptrCast(@alignCast(buffer.ptr));
        ptr.* = data;
    }

    pub fn deinit(self: *FrameState) void {
        self.arena.deinit();
    }

    pub fn reset(self: *FrameState) void {
        self.rects = .empty;
        self.uniforms = undefined;
        _ = self.arena.reset(.retain_capacity);
    }
};

pub const BufferNode = struct {
    next: ?*BufferNode,
    pool: ChunkPool,

    pub fn init(self: *BufferNode, opt: chunk_pool.Options, arena: Allocator) !void {
        self.* = .{
            .next = null,
            .pool = undefined,
        };

        try self.pool.init(arena, opt);
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
};

test {
    _ = FrameState;
}
