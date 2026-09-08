const std = @import("std");
const heap = std.heap;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const chunk_pool = @import("chunk_pool.zig");
const ChunkAllocator = chunk_pool.ChunkAllocator;
const Core = @import("core.zig");
const datastruct = @import("datastruct.zig");
const SinglyLinkedList = datastruct.SinglyLinkedList;
const Display = @import("display.zig");
const render = @import("render.zig");
const Renderer = render.Renderer;
const Handle = Renderer.Handle;
const View = @import("view.zig");
const win = @import("window.zig");
const Window = win.Window;

const log = std.log.scoped(.app);

pub const App = @This();

io: Io,
gpa: Allocator,
arena: heap.ArenaAllocator,
chunks: ChunkAllocator,
core: Core,
display: Display,
renderer: Renderer,
states: SinglyLinkedList(WindowState),

pub fn init(self: *App, gpa: Allocator, io: Io) !void {
    self.* = .{
        .arena = .init(gpa),
        .chunks = undefined,
        .io = io,
        .gpa = gpa,
        .states = .empty,
        .renderer = undefined,
        .core = undefined,
        .display = undefined,
    };

    const arena = self.arena.allocator();
    errdefer self.arena.deinit();

    try self.chunks.init(arena, &.{
        .{
            .capacity = 50,
            .chunk_size = @sizeOf(WindowState),
        },
    });

    try win.init("Odyssey", 0);
    errdefer win.deinit();

    try self.core.init(gpa, io, .{});
    errdefer self.core.deinit();

    try self.renderer.init();
    errdefer self.renderer.deinit();

    try self.display.init(&self.core, displayCallback);
    errdefer self.display.deinit();

    win.setEventCallback(.window_resized, resizeCallback);
}

pub fn deinit(self: *App) void {
    self.renderer.deinit();
    self.core.deinit();
    win.deinit();
    self.arena.deinit();
}

pub fn run(self: *App) void {
    self.core.run(.until_done);
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

        try self.view.init(app.gpa);
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

    var curr: ?*WindowState = self.states.head;
    var resized: ?*WindowState = null;

    while (curr) |state| : (curr = state.next) {
        if (state.win.raw == window.raw) {
            resized = state;
        } else {
            self.renderFrame(state, false) catch |err| {
                log.err("Frame render err={}", .{err});
            };
        }
    }

    if (resized) |state| {
        self.renderFrame(state, true) catch |err| {
            log.err("Frame render err={}", .{err});
        };
    }
}

fn displayCallback(display: *Display) bool {
    const self: *App = @fieldParentPtr("display", display);

    self.renderer.start();
    defer self.renderer.end();

    if (self.states.is_empty()) self.core.stop();

    win.pollEvents();

    var states = self.states;
    self.states = .empty;

    const chunks = self.chunks.allocator();

    while (states.pop()) |state| {
        if (state.win.shouldClose()) {
            state.deinit();

            chunks.destroy(state);
        } else {
            self.renderFrame(state, false) catch |err| {
                log.debug("Frame render err={}", .{err});
            };

            self.states.append(state);
        }
    }

    return true;
}

pub fn openWindow(self: *App, opts: win.Options) !void {
    const chunks = self.chunks.allocator();
    const window_state = try chunks.create(WindowState);
    try window_state.init(self, opts);

    self.states.append(window_state);
}

pub fn renderFrame(app: *App, window_state: *WindowState, resize: bool) !void {
    {
        const view = &window_state.view;

        try view.begin(window_state.win, resize);
        defer view.finish();

        view.pushAttrs(&.{ .{ .width = .grow }, .{ .height = .grow } });
        defer view.popAttrs(&.{ .width, .height });

        view.nextAttr(.{ .width = .{ .fixed = 100 } });

        const red = view.block(.{});
        red.color = .{ 1.0, 0.0, 0.0, 1.0 };

        view.shrink(1.0);

        const green = view.blockStr("@@@green", .{ .mouse = true });
        const signal = view.signalForBlock(green);

        if (signal.hovered) {
            green.color = .{ 0.0, 1.0, 0.5, 1.0 };
        } else {
            green.color = .{ 0.0, 1.0, 0.0, 1.0 };
        }

        {
            view.pushAttr(.{ .parent = green });
            defer view.popAttr(.parent);

            view.shrink(1.0);
            _ = view.spacer(.grow);

            view.nextAttr(.{ .axis = .y });

            const col = view.spacer(.{ .fixed = 50 });
            {
                view.pushAttr(.{ .parent = col });
                defer view.popAttr(.parent);

                view.shrink(1.0);
                _ = view.spacer(.grow);

                view.nextAttr(.{ .color = .{ 1.0, 0.0, 0.0, 1.0 } });

                _ = view.spacer(.{ .fixed = 50 });

                view.shrink(1.0);
                _ = view.spacer(.grow);
            }

            view.shrink(1.0);
            _ = view.spacer(.grow);
        }

        view.nextAttr(.{ .width = .{ .fixed = 100 } });

        const blue = view.block(.{});
        blue.color = .{ 0.0, 0.0, 1.0, 1.0 };
    }

    const frame = window_state.handle.nextFrame();
    errdefer window_state.handle.releaseFrame();

    const size = try window_state.win.size();

    try frame.uniform(.{ .viewport_size = .{ size.w, size.h } });

    var box = window_state.view.root;
    while (box) |current| : (box = current.nextPreOrder()) {
        try frame.rect(.{
            .position = current.rect[0] ++ current.rect[1],
            .color_0 = current.color,
            .color_1 = current.color,
            .color_2 = current.color,
            .color_3 = current.color,
        });
    }

    render.renderFrame(&app.renderer, &window_state.handle, frame, resize);
}
