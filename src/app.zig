const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Io = std.Io;

const Cache = @import("font.zig");
const chunk_pool = @import("chunk_pool.zig");
const ChunkAllocator = chunk_pool.ChunkAllocator;
const Core = @import("core.zig");
const datastruct = @import("datastruct.zig");
const SinglyLinkedList = datastruct.SinglyLinkedList;
const Display = @import("display.zig");
const embedded = @import("embedded.zig");
const Loop = @import("loop.zig");
const render = @import("render.zig");
const Renderer = render.Renderer;
const Handle = render.Handle;
const Scheduler = @import("scheduler.zig");
const View = @import("view.zig");
const win = @import("window.zig");
const Window = win.Window;

const log = std.log.scoped(.app);

pub const App = @This();

io: Io,
core: Core,
gpa: Allocator,
arena: ArenaAllocator,
chunks: ChunkAllocator,
display: Display,
renderer: Renderer,
states: SinglyLinkedList(WindowState),
font_cache: Cache,
collection: u64,
scheduler: Scheduler,
loop: Loop,

pub fn init(self: *App, gpa: Allocator, io: Io) !void {
    try win.init("Odyssey", 0);
    errdefer win.deinit();

    self.* = .{
        .scheduler = undefined,
        .loop = undefined,
        .collection = 0,
        .arena = .init(gpa),
        .chunks = undefined,
        .io = io,
        .gpa = gpa,
        .states = .empty,
        .renderer = undefined,
        .core = undefined,
        .display = undefined,
        .font_cache = undefined,
    };

    try self.display.init(displayCallback, io);
    errdefer self.display.deinit();

    try self.font_cache.init(gpa);
    errdefer self.font_cache.deinit();

    const inter = try self.font_cache.fromBytes(embedded.geist_mono, 0);
    const collection = try self.font_cache.addCollection(&.{inter});

    self.collection = collection;

    const arena = self.arena.allocator();
    errdefer self.arena.deinit();

    try self.scheduler.init(arena, io);
    errdefer self.scheduler.deinit();

    try self.loop.init(&self.scheduler, io);
    errdefer self.loop.deinit();

    try self.chunks.init(arena, &.{
        .{
            .capacity = 50,
            .chunk_size = @sizeOf(WindowState),
        },
    });

    try self.core.init(gpa, io, .{});
    errdefer self.core.deinit();

    try self.renderer.init();
    errdefer self.renderer.deinit();

    win.setEventCallback(.window_resized, resizeCallback);
}

pub fn deinit(self: *App) void {
    self.loop.run(.until_done) catch |err| {
        log.err("loop err on deinit: {}", .{err});
    };
    self.renderer.deinit();
    self.core.deinit();
    self.loop.deinit();
    self.scheduler.deinit();
    self.arena.deinit();
    self.font_cache.deinit();
    self.display.deinit();

    win.deinit();
}

pub fn run(self: *App) !void {
    try self.display.run();
}

pub const WindowState = struct {
    next: ?*WindowState = null,

    win: Window,
    handle: Handle,
    view: View,

    pub fn init(self: *WindowState, app: *App, opts: win.Options) !void {
        self.* = .{
            .view = undefined,
            .win = undefined,
            .handle = undefined,
        };

        try self.view.init(&app.font_cache, app.gpa);
        errdefer self.view.deinit();

        try self.win.init(opts);
        errdefer self.win.deinit();

        self.win.setUserdata(app);

        try self.handle.init(
            &app.renderer,
            &self.win,
            app.gpa,
            app.io,
        );
    }

    pub fn deinit(self: *WindowState) void {
        self.handle.deinit();
        self.win.deinit();
        self.view.deinit();
    }
};

fn resizeCallback(event: win.Event) void {
    const window = event.win;
    const self: *App = @ptrCast(@alignCast(window.userdata()));

    var iter = self.states.iterator();
    var resized: ?*WindowState = null;

    while (iter.next()) |state| {
        if (state.win.ptr == window.ptr) {
            resized = state;
        } else {
            self.renderWindow(state, false) catch |err| {
                log.err("Frame render err={}", .{err});
            };
        }
    }

    if (resized) |state| {
        self.renderWindow(state, true) catch |err| {
            log.err("Frame render err={}", .{err});
        };
    }
}

fn displayCallback(display: *Display) bool {
    const self: *App = @fieldParentPtr("display", display);

    if (self.states.is_empty()) self.display.stop();

    win.pollEvents();

    var states = self.states;
    self.states = .empty;

    const chunks = self.chunks.allocator();

    while (states.pop()) |state| {
        if (state.win.shouldClose()) {
            state.deinit();

            chunks.destroy(state);
        } else {
            while (state.win.popEvent()) |event| {
                switch (event.type) {
                    .mouse_button => state.view.pushEvent(event.type),
                    else => {},
                }
            }
            self.renderWindow(state, false) catch |err| {
                log.debug("Frame render err={}", .{err});
            };

            self.states.append(state);
        }
    }

    self.loop.run(.no_wait) catch |err| {
        log.err("Loop err={}", .{err});
    };

    return true;
}

pub fn openWindow(self: *App, opts: win.Options) !void {
    const chunks = self.chunks.allocator();
    const window_state = try chunks.create(WindowState);
    try window_state.init(self, opts);

    self.states.append(window_state);
}

pub fn renderWindow(self: *App, ws: *WindowState, resize: bool) !void {
    const view = &ws.view;

    {
        try view.begin(ws.win, resize, self.collection);
        defer view.finish();

        view.background(.{ 1.0, 0.0, 0.0, 1.0 });
        view.height(.grow);
        view.spacer(.{ .fixed = 100 }, 0.0);

        {
            view.shrink(1.0);
            view.background(.{ 0.0118, 0.00784, 0.00784, 1.0 });
            view.padding(.grow, 1.0);
            view.textColor(.{ 1.0, 1.0, 1.0, 1.0 });
            view.textAlign(.right);

            _ = view.blkStr(
                "zig build run@@@green",
                .{ .text = true },
            );
            defer view.blkEnd();

            view.col();
            view.padding(.grow, 1.0);

            _ = view.blk(.{});
            defer view.blkEnd();

            view.size(.{ .text = 100.0 });
            view.rounded(12.0);
            view.background(.{ 1.0, 0.647, 0.0, 1.0 });
            view.border(2, .{ 1.0, 0.0, 0.0, 1.0 });
            view.textColor(.{ 1.0, 0.0, 0.0, 1.0 });
            view.textAlign(.center);

            if (view.button("Hello@@@orange").clicked) log.debug("orange got clicked", .{});
        }

        view.background(.{ 0.0, 0.0, 1.0, 1.0 });
        view.height(.grow);
        view.spacer(.{ .fixed = 100.0 }, 0.0);
    }

    {
        const frame = ws.handle.nextFrame();
        errdefer ws.handle.releaseFrame();

        frame.uniforms = .{
            .viewport_size = try ws.win.size(),
        };

        if (frame.atlas_gen != self.font_cache.atlas_gen) {
            try frame.syncAtlas(&self.renderer, &self.font_cache.atlas);
        }

        var node = ws.view.root;
        while (node) |block| : (node = block.nextPre()) {
            const rect = block.rect[0] ++ block.rect[1];

            if (block.flags.background) {
                try frame.rect(&self.renderer, .{
                    .position = rect,
                    .src_position = undefined,
                    .color_0 = block.color,
                    .color_1 = block.color,
                    .color_2 = block.color,
                    .color_3 = block.color,
                    .corner_rads = block.radius,
                });
            }

            if (block.flags.border) {
                try frame.rect(&self.renderer, .{
                    .position = rect,
                    .src_position = undefined,
                    .color_0 = block.border,
                    .color_1 = block.border,
                    .color_2 = block.border,
                    .color_3 = block.border,
                    .corner_rads = block.radius,
                    .style = .{
                        .border_thickness = block.thickness,
                    },
                });
            }

            if (block.run) |r| {
                var cursor_x, var cursor_y = view.textPosition(block);

                for (r.pieces) |piece| {
                    const x = cursor_x + piece.offset_x + piece.off_x;
                    const y = cursor_y + piece.offset_y + piece.off_y;

                    const width: f32 = @floatFromInt(piece.width);
                    const height: f32 = @floatFromInt(piece.height);

                    const position: [4]f32 = if (piece.rotate) .{
                        @floatFromInt(piece.x),
                        @floatFromInt(piece.y),
                        @floatFromInt(piece.x + piece.height),
                        @floatFromInt(piece.y + piece.width),
                    } else .{
                        @floatFromInt(piece.x),
                        @floatFromInt(piece.y),
                        @floatFromInt(piece.x + piece.width),
                        @floatFromInt(piece.y + piece.height),
                    };

                    try frame.rect(&self.renderer, .{
                        .position = .{ x, y, x + width, y + height },
                        .color_0 = block.text_color,
                        .color_1 = block.text_color,
                        .color_2 = block.text_color,
                        .color_3 = block.text_color,
                        .src_position = position,
                        .style = .{
                            .omit_src = 0.0,
                            .rotate_src = if (piece.rotate) 1.0 else 0.0,
                        },
                    });

                    cursor_x += piece.advance_x;
                    cursor_y += piece.advance_y;
                }
            }
        }

        render.render(&self.renderer, &ws.handle, frame, resize);
    }
}
