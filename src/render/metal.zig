// LICENSE: [GHOSTTY]

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const macos = @import("macos");
const objc = @import("objc");

const datastruct = @import("../datastruct.zig");
const render = @import("../render.zig");
const FrameState = render.FrameState;
const win = @import("../window.zig");
const Window = win.Window;
const c = @import("metal/c.zig");

const BufferCount = 3;

const pipeline_descs: []const struct { [:0]const u8, PipelineDescription } =
    &.{
        .{
            "rect",
            .{
                .vertex_fn = "rectVertexShader",
                .fragment_fn = "rectFragmentShader",
                .blending_enabled = true,
                .step_fn = .per_instance,
                .vertex_attributes = render.Rect,
            },
        },
    };

const log = std.log.scoped(.metal);

pub const Metal = @This();

device: objc.Object,
queue: objc.Object,
shaders: Shaders,

autorelease_pool: ?*objc.AutoreleasePool,

pub fn init(self: *Metal) !void {
    self.* = .{
        .shaders = undefined,
        .device = undefined,
        .queue = undefined,
        .autorelease_pool = null,
    };

    var chosen_device: ?objc.Object = null;

    const devices = objc.Object.fromId(c.MTLCopyAllDevices());

    var iter = devices.iterate();
    while (iter.next()) |device| {
        if (device.getProperty(bool, "isHeadless")) continue;
        chosen_device = device;
        if (device.getProperty(bool, "isRemovable") or
            device.getProperty(bool, "isLowPower")) break;
    }

    self.device = chosen_device orelse return error.NoMetalDevice;
    errdefer self.device.release();

    self.queue = self.device.msgSend(objc.Object, objc.sel("newCommandQueue"), .{});
    errdefer self.queue.release();

    try self.shaders.init(self.device, .bgra8unorm);
}

pub fn deinit(self: *Metal) void {
    if (self.autorelease_pool) |pool| pool.deinit();
    self.shaders.deinit();
    self.queue.release();
    self.device.release();
}

pub fn buffer(
    self: *Metal,
    chunk: [*]u8,
    len: usize,
    resource_options: c.MTLResourceOptions,
) Buffer {
    return .init(self.device, chunk, len, resource_options);
}

pub fn start(self: *Metal) void {
    assert(self.autorelease_pool == null);
    self.autorelease_pool = .init();
}

pub fn end(self: *Metal) void {
    assert(self.autorelease_pool != null);
    self.autorelease_pool.?.deinit();
    self.autorelease_pool = null;
}

pub fn frame(self: *Metal, handle: *Handle) Frame {
    return .begin(self, handle);
}

pub const Handle = struct {
    layer: objc.Object,
    swap_chain: SwapChain,

    pub fn init(self: *@This(), api: *const Metal, window: *Window, gpa: Allocator, io: Io) !void {
        self.* = .{ .layer = undefined, .swap_chain = undefined };

        try self.swap_chain.init(gpa, io);

        const CAMetalLayer = objc.getClass("CAMetalLayer").?;

        const layer = CAMetalLayer.msgSend(objc.Object, "layer", .{});
        layer.setProperty("device", api.device);
        layer.setProperty("opaque", true);
        layer.setProperty("pixelFormat", @intFromEnum(c.MTLPixelFormat.bgra8unorm));
        layer.setProperty("contentsGravity", macos.animation.kCAGravityTopLeft);

        const view = objc.Object.fromId(window.osView() orelse unreachable);
        view.msgSend(void, "setLayer:", .{layer});

        self.layer = layer;
    }

    pub fn nextFrame(self: *Handle) *FrameState {
        const next = self.swap_chain.nextFrame();
        next.reset();
        return next;
    }

    pub fn releaseFrame(self: *Handle) void {
        self.swap_chain.releaseFrame();
    }

    pub fn target(self: *const Handle) Target {
        return .init(self.layer);
    }

    pub fn deinit(self: *@This()) void {
        self.layer.release();
        self.swap_chain.deinit();
    }

    pub fn update(self: *@This(), width: f32, height: f32, sync: bool) void {
        const size: macos.graphics.Size = .{
            .width = width,
            .height = height,
        };
        self.layer.msgSend(void, "setDrawableSize:", .{size});

        self.layer.setProperty("presentsWithTransaction", sync);
    }
};

pub const Buffer = struct {
    buffer: objc.Object,

    pub fn init(
        device: objc.Object,
        chunk: [*]u8,
        len: usize,
        resource_options: c.MTLResourceOptions,
    ) Buffer {
        return .{
            .buffer = device.msgSend(
                objc.Object,
                "newBufferWithBytesNoCopy:length:options:deallocator:",
                .{ chunk, @as(c_ulong, @intCast(len)), resource_options, @as(?*anyopaque, null) },
            ),
        };
    }

    pub fn release(self: *const Buffer) void {
        self.buffer.release();
    }
};

pub const Target = struct {
    drawable: objc.Object,
    texture: objc.Object,

    pub fn init(layer: objc.Object) Target {
        const drawable = layer.msgSend(objc.Object, "nextDrawable", .{});
        const texture = drawable.msgSend(objc.Object, "texture", .{});

        return .{ .drawable = drawable, .texture = texture };
    }
};

pub const Frame = struct {
    /// MTLCommandBuffer
    buffer: objc.Object,

    block: CompletionBlock.Context,

    pub fn begin(
        api: *Metal,
        handle: *Handle,
    ) Frame {
        const command_buffer = api.queue.msgSend(
            objc.Object,
            objc.sel("commandBuffer"),
            .{},
        );

        // Create our block to register for completion updates.
        // The block is deallocated by the objC runtime on success.
        const block = CompletionBlock.init(
            .{ .handle = handle },
            &bufferCompleted,
        );

        return .{ .buffer = command_buffer, .block = block };
    }

    /// This is the block type used for the addCompletedHandler callback.
    const CompletionBlock = objc.Block(
        struct {
            handle: *Handle,
        },
        .{},
        void,
    );

    fn bufferCompleted(
        block: *const CompletionBlock.Context,
    ) callconv(.c) void {
        block.handle.releaseFrame();
    }

    /// Add a render pass to this frame with the provided attachments.
    /// Returns a RenderPass which allows render steps to be added.
    pub inline fn renderPass(
        self: *const Frame,
        attachments: []const RenderPass.Attachment,
    ) RenderPass {
        return RenderPass.begin(.{
            .attachments = attachments,
            .command_buffer = self.buffer,
        });
    }

    pub inline fn complete(self: *Frame, target: *Target, sync: bool) void {
        if (!sync) {
            self.buffer.msgSend(
                void,
                objc.sel("addCompletedHandler:"),
                .{&self.block},
            );

            self.buffer.msgSend(void, "presentDrawable:", .{target.drawable});
        }

        self.buffer.msgSend(void, "commit", .{});

        if (sync) {
            self.buffer.msgSend(void, "waitUntilCompleted", .{});
            CompletionBlock.invoke(&self.block, .{});
            target.drawable.msgSend(void, "present", .{});
        }
    }
};

pub const RenderPass = struct {
    pub const Options = struct {
        /// MTLCommandBuffer
        command_buffer: objc.Object,
        /// Color attachments for this render pass.
        attachments: []const Attachment,
    };

    /// Describes a color attachment.
    pub const Attachment = struct {
        target: Target,
        clear_color: ?[4]f64 = null,
    };

    /// Describes a step in a render pass.
    pub const Step = struct {
        pipeline: Pipeline,
        /// MTLBuffer
        uniforms: ?objc.Object = null,
        /// MTLBuffer
        buffers: []const ?objc.Object = &.{},
        draw: Draw,

        /// Describes the draw call for this step.
        pub const Draw = struct {
            type: c.MTLPrimitiveType,
            vertex_count: usize,
            instance_count: usize = 1,
        };
    };

    /// MTLRenderCommandEncoder
    encoder: objc.Object,

    /// Begin a render pass.
    pub fn begin(
        opts: Options,
    ) RenderPass {
        // Create a pass descriptor
        const desc = desc: {
            const MTLRenderPassDescriptor = objc.getClass("MTLRenderPassDescriptor").?;
            const desc = MTLRenderPassDescriptor.msgSend(
                objc.Object,
                objc.sel("renderPassDescriptor"),
                .{},
            );

            // Set our color attachment to be our drawable surface.
            const attachments = objc.Object.fromId(
                desc.getProperty(?*anyopaque, "colorAttachments"),
            );
            for (opts.attachments, 0..) |attch, i| {
                const attachment = attachments.msgSend(
                    objc.Object,
                    objc.sel("objectAtIndexedSubscript:"),
                    .{@as(c_ulong, i)},
                );

                attachment.setProperty(
                    "loadAction",
                    @intFromEnum(@as(
                        c.MTLLoadAction,
                        if (attch.clear_color != null)
                            .clear
                        else
                            .load,
                    )),
                );
                attachment.setProperty(
                    "storeAction",
                    @intFromEnum(c.MTLStoreAction.store),
                );
                attachment.setProperty("texture", attch.target.texture);
                if (attch.clear_color) |color| attachment.setProperty(
                    "clearColor",
                    c.MTLClearColor{
                        .red = color[0],
                        .green = color[1],
                        .blue = color[2],
                        .alpha = color[3],
                    },
                );
            }

            break :desc desc;
        };

        // MTLRenderCommandEncoder
        const encoder = opts.command_buffer.msgSend(
            objc.Object,
            objc.sel("renderCommandEncoderWithDescriptor:"),
            .{desc.value},
        );

        return .{ .encoder = encoder };
    }

    /// Add a step to this render pass.
    pub fn step(self: *const RenderPass, s: Step) void {
        if (s.draw.instance_count == 0) return;

        // Set pipeline state
        self.encoder.msgSend(
            void,
            objc.sel("setRenderPipelineState:"),
            .{s.pipeline.state.value},
        );

        if (s.buffers.len > 0) {
            // We reserve index 0 for the vertex buffer, this isn't very
            // flexible but it lines up with the API we have for OpenGL.
            if (s.buffers[0]) |buf| {
                self.encoder.msgSend(
                    void,
                    objc.sel("setVertexBuffer:offset:atIndex:"),
                    .{ buf.value, @as(c_ulong, 0), @as(c_ulong, 0) },
                );
                self.encoder.msgSend(
                    void,
                    objc.sel("setFragmentBuffer:offset:atIndex:"),
                    .{ buf.value, @as(c_ulong, 0), @as(c_ulong, 0) },
                );
            }

            // Set the rest of the buffers starting at index 2, this is
            // so that we can use index 1 for the uniforms if present.
            //
            // Also, we set buffers (and textures) for both stages.
            //
            // Again, not very flexible, but it's consistent and predictable,
            // and we need to treat the uniforms as special because of OpenGL.
            //
            // TODO: Maybe in the future add info to the pipeline struct which
            //       allows it to define a mapping between provided buffers and
            //       what index they get set at for the vertex / fragment stage.
            for (s.buffers[1..], 2..) |b, i| if (b) |buf| {
                self.encoder.msgSend(
                    void,
                    objc.sel("setVertexBuffer:offset:atIndex:"),
                    .{ buf.value, @as(c_ulong, 0), @as(c_ulong, i) },
                );
                self.encoder.msgSend(
                    void,
                    objc.sel("setFragmentBuffer:offset:atIndex:"),
                    .{ buf.value, @as(c_ulong, 0), @as(c_ulong, i) },
                );
            };
        }

        // Set the uniforms as buffer index 1 if present.
        if (s.uniforms) |buf| {
            self.encoder.msgSend(
                void,
                objc.sel("setVertexBuffer:offset:atIndex:"),
                .{ buf.value, @as(c_ulong, 0), @as(c_ulong, 1) },
            );
            self.encoder.msgSend(
                void,
                objc.sel("setFragmentBuffer:offset:atIndex:"),
                .{ buf.value, @as(c_ulong, 0), @as(c_ulong, 1) },
            );
        }

        self.encoder.msgSend(
            void,
            objc.sel("drawPrimitives:vertexStart:vertexCount:instanceCount:"),
            .{
                @intFromEnum(s.draw.type),
                @as(c_ulong, 0),
                @as(c_ulong, s.draw.vertex_count),
                @as(c_ulong, s.draw.instance_count),
            },
        );
    }

    /// Complete this render pass.
    /// This struct can no longer be used after calling this.
    pub fn complete(self: *const RenderPass) void {
        self.encoder.msgSend(void, objc.sel("endEncoding"), .{});
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

pub const Pipeline = struct {
    /// Options for initializing a render pipeline.
    pub const Options = struct {
        /// MTLDevice
        device: objc.Object,

        /// Name of the vertex function
        vertex_fn: []const u8,
        /// Name of the fragment function
        fragment_fn: []const u8,

        /// MTLLibrary to get the vertex function from
        vertex_library: objc.Object,
        /// MTLLibrary to get the fragment function from
        fragment_library: objc.Object,

        /// Vertex step function
        step_fn: c.MTLVertexStepFunction = .per_vertex,

        /// Info about the color attachments used by this render pipeline.
        attachments: []const Attachment,

        /// Describes a color attachment.
        pub const Attachment = struct {
            pixel_format: c.MTLPixelFormat,
            blending_enabled: bool = true,
        };
    };

    /// MTLRenderPipelineState
    state: objc.Object,

    pub fn init(comptime VertexAttributes: ?type, opts: Options) !Pipeline {
        // Create our descriptor
        const desc = init: {
            const Class = objc.getClass("MTLRenderPipelineDescriptor").?;
            const id_alloc = Class.msgSend(objc.Object, objc.sel("alloc"), .{});
            const id_init = id_alloc.msgSend(objc.Object, objc.sel("init"), .{});
            break :init id_init;
        };
        defer desc.msgSend(void, objc.sel("release"), .{});

        // Get our vertex and fragment functions and add them to the descriptor.
        {
            const str = try macos.foundation.String.createWithBytes(
                opts.vertex_fn,
                .utf8,
                false,
            );
            defer str.release();

            const ptr = opts.vertex_library.msgSend(?*anyopaque, objc.sel("newFunctionWithName:"), .{str});
            const func_vert = objc.Object.fromId(ptr.?);
            defer func_vert.msgSend(void, objc.sel("release"), .{});

            desc.setProperty("vertexFunction", func_vert);
        }
        {
            const str = try macos.foundation.String.createWithBytes(
                opts.fragment_fn,
                .utf8,
                false,
            );
            defer str.release();

            const ptr = opts.fragment_library.msgSend(?*anyopaque, objc.sel("newFunctionWithName:"), .{str});
            const func_frag = objc.Object.fromId(ptr.?);
            defer func_frag.msgSend(void, objc.sel("release"), .{});

            desc.setProperty("fragmentFunction", func_frag);
        }

        // If we have vertex attributes, create and add a vertex descriptor.
        if (VertexAttributes) |V| {
            const vertex_desc = init: {
                const Class = objc.getClass("MTLVertexDescriptor").?;
                const id_alloc = Class.msgSend(objc.Object, objc.sel("alloc"), .{});
                const id_init = id_alloc.msgSend(objc.Object, objc.sel("init"), .{});
                break :init id_init;
            };
            defer vertex_desc.msgSend(void, objc.sel("release"), .{});

            // Our attributes are the fields of the input
            const attrs = objc.Object.fromId(vertex_desc.getProperty(?*anyopaque, "attributes"));
            autoAttribute(V, attrs);

            // The layout describes how and when we fetch the next vertex input.
            const layouts = objc.Object.fromId(vertex_desc.getProperty(?*anyopaque, "layouts"));
            {
                const layout = layouts.msgSend(
                    objc.Object,
                    objc.sel("objectAtIndexedSubscript:"),
                    .{@as(c_ulong, 0)},
                );

                layout.setProperty("stepFunction", @intFromEnum(opts.step_fn));
                layout.setProperty("stride", @as(c_ulong, @sizeOf(V)));
            }

            desc.setProperty("vertexDescriptor", vertex_desc);
        }

        // Set our color attachment
        const attachments = objc.Object.fromId(desc.getProperty(?*anyopaque, "colorAttachments"));
        for (opts.attachments, 0..) |at, i| {
            const attachment = attachments.msgSend(
                objc.Object,
                objc.sel("objectAtIndexedSubscript:"),
                .{@as(c_ulong, i)},
            );

            attachment.setProperty("pixelFormat", @intFromEnum(at.pixel_format));

            attachment.setProperty("blendingEnabled", at.blending_enabled);

            if (at.blending_enabled) {
                attachment.setProperty("rgbBlendOperation", @intFromEnum(c.MTLBlendOperation.add));
                attachment.setProperty("alphaBlendOperation", @intFromEnum(c.MTLBlendOperation.add));
                attachment.setProperty("sourceRGBBlendFactor", @intFromEnum(c.MTLBlendFactor.one));
                attachment.setProperty("sourceAlphaBlendFactor", @intFromEnum(c.MTLBlendFactor.one));
                attachment.setProperty("destinationRGBBlendFactor", @intFromEnum(c.MTLBlendFactor.one_minus_source_alpha));
                attachment.setProperty("destinationAlphaBlendFactor", @intFromEnum(c.MTLBlendFactor.one_minus_source_alpha));
            }
        }

        // Make our state
        var err: ?*anyopaque = null;
        const pipeline_state = opts.device.msgSend(
            objc.Object,
            objc.sel("newRenderPipelineStateWithDescriptor:error:"),
            .{ desc, &err },
        );
        try checkError(err);
        errdefer pipeline_state.release();

        return .{ .state = pipeline_state };
    }

    pub fn deinit(self: *const Pipeline) void {
        self.state.release();
    }

    fn autoAttribute(T: type, attrs: objc.Object) void {
        inline for (@typeInfo(T).@"struct".fields, 0..) |field, i| {
            const offset = @offsetOf(T, field.name);

            const FT = switch (@typeInfo(field.type)) {
                .@"struct" => |e| e.backing_integer.?,
                .@"enum" => |e| e.tag_type,
                else => field.type,
            };

            // Very incomplete list, expand as necessary.
            const format = switch (FT) {
                [4]u8 => c.MTLVertexFormat.uchar4,
                [2]u16 => c.MTLVertexFormat.ushort2,
                [2]i16 => c.MTLVertexFormat.short2,
                f32 => c.MTLVertexFormat.float,
                [2]f32 => c.MTLVertexFormat.float2,
                [3]f32 => c.MTLVertexFormat.float3,
                [4]f32 => c.MTLVertexFormat.float4,
                i32 => c.MTLVertexFormat.int,
                [2]i32 => c.MTLVertexFormat.int2,
                [4]i32 => c.MTLVertexFormat.int2,
                u32 => c.MTLVertexFormat.uint,
                [2]u32 => c.MTLVertexFormat.uint2,
                [4]u32 => c.MTLVertexFormat.uint4,
                u8 => c.MTLVertexFormat.uchar,
                i8 => c.MTLVertexFormat.char,
                else => comptime unreachable,
            };

            const attr = attrs.msgSend(
                objc.Object,
                objc.sel("objectAtIndexedSubscript:"),
                .{@as(c_ulong, i)},
            );

            attr.setProperty("format", @intFromEnum(format));
            attr.setProperty("offset", @as(c_ulong, offset));
            attr.setProperty("bufferIndex", @as(c_ulong, 0));
        }
    }
};

/// All the comptime-known info about a pipeline, so that
/// we can define them ahead-of-time in an ergonomic way.
const PipelineDescription = struct {
    vertex_attributes: ?type = null,
    vertex_fn: []const u8,
    fragment_fn: []const u8,
    step_fn: c.MTLVertexStepFunction = .per_vertex,
    blending_enabled: bool,

    fn initPipeline(
        self: PipelineDescription,
        device: objc.Object,
        library: objc.Object,
        pixel_format: c.MTLPixelFormat,
    ) !Pipeline {
        return try .init(self.vertex_attributes, .{
            .device = device,
            .vertex_fn = self.vertex_fn,
            .fragment_fn = self.fragment_fn,
            .vertex_library = library,
            .fragment_library = library,
            .step_fn = self.step_fn,
            .attachments = &.{.{
                .pixel_format = pixel_format,
                .blending_enabled = self.blending_enabled,
            }},
        });
    }
};

/// We create a type for the pipeline collection based on our desc array.
const PipelineCollection = t: {
    const StructField = std.builtin.Type.StructField;

    var names: [pipeline_descs.len][]const u8 = undefined;
    var types = [_]type{Pipeline} ** pipeline_descs.len;
    var attrs = [_]StructField.Attributes{.{ .@"align" = @alignOf(Pipeline) }} ** pipeline_descs.len;

    for (pipeline_descs, &names) |pipeline, *name| {
        name.* = pipeline[0];
    }
    break :t @Struct(.auto, null, &names, &types, &attrs);
};

/// This contains the state for the shaders used by the Metal renderer.
pub const Shaders = struct {
    library: objc.Object,

    /// Collection of available render pipelines.
    pipelines: PipelineCollection,

    /// Initialize our shader set.
    pub fn init(
        self: *Shaders,
        device: objc.Object,
        pixel_format: c.MTLPixelFormat,
    ) !void {
        const library = try initLibrary(device);
        errdefer library.msgSend(void, objc.sel("release"), .{});

        var pipelines: PipelineCollection = undefined;

        var initialized_pipelines: usize = 0;

        errdefer inline for (pipeline_descs, 0..) |pipeline, i| {
            if (i < initialized_pipelines) {
                @field(pipelines, pipeline[0]).deinit();
            }
        };

        inline for (pipeline_descs) |pipeline| {
            @field(pipelines, pipeline[0]) = try pipeline[1].initPipeline(
                device,
                library,
                pixel_format,
            );
            initialized_pipelines += 1;
        }

        self.* = .{
            .library = library,
            .pipelines = pipelines,
        };
    }

    pub fn deinit(self: *Shaders) void {
        // Release our primary shaders
        inline for (pipeline_descs) |pipeline| {
            @field(self.pipelines, pipeline[0]).deinit();
        }
        self.library.msgSend(void, objc.sel("release"), .{});
    }

    /// Initialize the MTLLibrary. A MTLLibrary is a collection of shaders.
    fn initLibrary(device: objc.Object) !objc.Object {
        const data = try macos.dispatch.Data.create(
            @embedFile("odyssey_metallib"),
            macos.dispatch.queue.getMain(),
            macos.dispatch.Data.DESTRUCTOR_DEFAULT,
        );
        defer data.release();

        var err: ?*anyopaque = null;
        const library = device.msgSend(
            objc.Object,
            objc.sel("newLibraryWithData:error:"),
            .{
                data,
                &err,
            },
        );
        try checkError(err);

        return library;
    }
};

fn checkError(err_: ?*anyopaque) !void {
    const nserr = objc.Object.fromId(err_ orelse return);
    const str = @as(
        *macos.foundation.String,
        @ptrCast(nserr.getProperty(?*anyopaque, "localizedDescription").?),
    );

    log.err("metal error={s}", .{str.cstringPtr(.ascii).?});
    return error.MetalFailed;
}
