const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Io = std.Io;
const assert = std.debug.assert;
const testing = std.testing;

const ChunkAllocator = @import("chunk_allocator.zig");
const config = @import("config.zig");
const core = @import("core.zig");
const datastruct = @import("datastruct.zig");
const SinglyLinkedList = datastruct.SinglyLinkedList;
const DoublyLinkedList = datastruct.DoublyLinkedList;
const slotmap = datastruct.slotmap;
const SlotMap = slotmap.SlotMap;
const Key = slotmap.Key;
const Display = @import("display.zig");
const embedded = @import("embedded.zig");
const font = @import("font.zig");
const renderer = @import("renderer.zig");
const view = @import("view.zig");
const win = @import("window.zig");

const log = std.log.scoped(.app);

var app: App = undefined;

const App = struct {
    io: Io,
    gpa: Allocator,
    arena: ArenaAllocator,
    chunks: ChunkAllocator,
    display: Display,
    window_states: DoublyLinkedList(WindowState),
    collection: u64,
    frame: u64,
    frame_arena: ArenaAllocator,
    cmds: SinglyLinkedList(CommandNode),
    quit: bool,
};

pub fn init(gpa: Allocator, io: Io) !void {
    app = .{
        .quit = false,
        .frame_arena = .init(gpa),
        .collection = 0,
        .frame = 0,
        .io = io,
        .gpa = gpa,
        .arena = .init(gpa),
        .chunks = .init(gpa),
        .window_states = .empty,
        .display = undefined,
        .cmds = .empty,
    };

    const inter = try font.fromBytes(embedded.geist_mono, 0);
    app.collection = try font.addCollection(&.{inter});

    try app.display.init(displayCallback, io);
    errdefer app.display.deinit();

    win.setEventCallback(.window_resized, windowResize);
}

pub fn deinit() void {
    app.frame_arena.deinit();
    app.display.deinit();
    app.arena.deinit();
    app.chunks.deinit();
}

pub fn run() !void {
    try app.display.run();
}

pub fn displayCallback() bool {
    display() catch |err| log.err("frame err={}", .{err});

    return true;
}

pub fn display() !void {
    if (app.quit) {
        app.display.stop();
    }

    win.poll();
    while (win.popEvent()) |evt| {
        const window_state: *WindowState = @ptrCast(@alignCast(evt.win.userdata()));

        switch (evt.data) {
            .window_update => |update| {
                if (update.type == .window_close) {
                    window_state.closed = true;
                }
            },
            .mouse_button => |data| window_state.view.pushEvent(.{ .mouse_button = data }),
            else => {},
        }
    }

    var iter = app.cmds.iterator();
    while (iter.next()) |node| {
        const cmd = node.command;

        switch (cmd) {
            .open_window => {
                const chunks = app.chunks.allocator();
                const window_state = try chunks.create(WindowState);
                try window_state.init(.{
                    .name = "Odyssey",
                    .x = 0,
                    .y = 0,
                    .width = 800,
                    .height = 600,
                    .flags = win.WindowCenter | win.WindowFocus,
                });

                app.window_states.append(window_state);
            },
        }
    }

    try render();

    _ = app.frame_arena.reset(.retain_capacity);
    app.cmds = .empty;
}

fn windowResize(event: win.Event) void {
    const window = event.win;
    const state: *WindowState = @ptrCast(@alignCast(window.userdata()));

    state.resize = true;
    defer state.resize = false;

    render() catch |err| {
        log.err("Frame render err={}", .{err});
    };
}

pub fn render() !void {
    const chunks = app.chunks.allocator();

    try core.flush();

    var win_iter = app.window_states.iterator();
    while (win_iter.next()) |window_state| {
        if (window_state.closed) continue;

        {
            view.begin(&window_state.view, window_state.win, window_state.resize, app.collection);
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

                _ = view.blk(.{
                    .str = "zig build run@@@green",
                    .flags = .{ .text = true },
                });
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

                if (view.button("Hello@@@orange").clicked) {
                    log.debug("orange got clicked", .{});
                }
            }

            view.background(.{ 0.0, 0.0, 1.0, 1.0 });
            view.height(.grow);
            view.spacer(.{ .fixed = 100.0 }, 0.0);
        }

        {
            const frame = window_state.handle.nextFrame();
            errdefer window_state.handle.releaseFrame();

            frame.uniforms = .{
                .viewport_size = try window_state.win.size(),
            };

            var node = window_state.view.root;
            while (node) |block| : (node = block.nextPre()) {
                const rect = block.rect[0] ++ block.rect[1];
                const flags = block.flags;

                if (flags.background) {
                    try frame.rect(.{
                        .position = rect,
                        .src_position = undefined,
                        .color_0 = block.color,
                        .color_1 = block.color,
                        .color_2 = block.color,
                        .color_3 = block.color,
                        .corner_rads = block.radius,
                    });
                }

                if (flags.border) {
                    try frame.rect(.{
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
                    const pieces = r.pieces;
                    const font_size = block.font_size * block.scale;
                    var cursor_x, var cursor_y = view.textPosition(block);

                    for (pieces) |piece| {
                        const glyph = font.getGlyph(piece.tag, piece.index, font_size) catch continue;

                        const x: f32 = cursor_x + (piece.offset_x * glyph.scale) + glyph.off_x;
                        const y: f32 = cursor_y + (piece.offset_y * glyph.scale) + glyph.off_y;

                        const width: f32 = @floatFromInt(glyph.width);
                        const height: f32 = @floatFromInt(glyph.height);

                        var position: [4]f32 = .{
                            @floatFromInt(glyph.x),
                            @floatFromInt(glyph.y),
                            @floatFromInt(glyph.x),
                            @floatFromInt(glyph.y),
                        };

                        if (glyph.rotate) {
                            position[2] += @floatFromInt(glyph.height);
                            position[3] += @floatFromInt(glyph.width);
                        } else {
                            position[2] += @floatFromInt(glyph.width);
                            position[3] += @floatFromInt(glyph.height);
                        }

                        try frame.rect(.{
                            .position = .{ x, y, x + width, y + height },
                            .color_0 = block.text_color,
                            .color_1 = block.text_color,
                            .color_2 = block.text_color,
                            .color_3 = block.text_color,
                            .src_position = position,
                            .style = .{
                                .omit_src = 0.0,
                                .rotate_src = if (glyph.rotate) 1.0 else 0.0,
                            },
                        });

                        cursor_x += piece.advance_x * glyph.scale;
                        cursor_y += piece.advance_y * glyph.scale;
                    }
                }
            }

            if (frame.atlas_generation != font.cache.atlas_gen) {
                try frame.syncAtlas(&font.cache.atlas);
            }

            renderer.render(&window_state.handle, frame, window_state.resize);
        }

        window_state.last_frame = app.frame;
    }

    win_iter = app.window_states.iterator();
    while (win_iter.next()) |window_state| {
        if (window_state.last_frame != app.frame) {
            app.window_states.remove(window_state);
            window_state.deinit();
            chunks.destroy(window_state);
        }
    }
    if (app.window_states.len() == 0) app.quit = true;

    app.frame += 1;
}

pub fn pushCmd(cmd: Command) !void {
    const arena = app.frame_arena.allocator();
    const node = try arena.create(CommandNode);
    node.* = .{
        .command = cmd,
    };

    app.cmds.append(node);
}

pub const WindowState = struct {
    next: ?*WindowState = null,
    prev: ?*WindowState = null,

    win: win.Window,
    handle: renderer.Handle,
    view: view.View,
    resize: bool,
    last_frame: u64,
    closed: bool,

    pub fn init(self: *WindowState, opts: win.Options) !void {
        self.* = .{
            .closed = false,
            .last_frame = 0,
            .view = undefined,
            .win = undefined,
            .resize = false,
            .handle = undefined,
        };

        try self.view.init(app.gpa);
        errdefer self.view.deinit();

        try self.win.init(opts);
        errdefer self.win.deinit();

        self.win.setUserdata(self);

        try self.handle.init(&self.win, app.gpa, app.io);
    }

    pub fn deinit(self: *WindowState) void {
        self.handle.deinit();
        self.win.deinit();
        self.view.deinit();
    }
};

const CommandNode = struct {
    next: ?*CommandNode = null,
    command: Command,
};

const Command = union(enum) {
    open_window,
};
