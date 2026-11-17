// add cmds(application cmds), entity kind
// caches(for our important data), evetns(events from the differents systems of the app)
// we requiere as well to store the state of the app(views, animations, windows)

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Io = std.Io;
const assert = std.debug.assert;
const testing = std.testing;

const chunk_pool = @import("chunk_pool.zig");
const ChunkAllocator = chunk_pool.ChunkAllocator;
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
const type_id = @import("type_id.zig");
const TypeId = type_id.TypeId;
const TypeInfo = type_id.TypeInfo;
const view = @import("view.zig");
const win = @import("window.zig");

const log = std.log.scoped(.core);

var core: struct {
    io: Io,
    gpa: Allocator,
    arena: ArenaAllocator,
    chunks: ChunkAllocator,
    display: Display,
    window_states: DoublyLinkedList(WindowState),
    collection: u64,
    frame: u64,
} = undefined;

pub fn init(gpa: Allocator, io: Io) !void {
    core = .{
        .collection = 0,
        .frame = 0,
        .io = io,
        .gpa = gpa,
        .arena = .init(gpa),
        .chunks = undefined,
        .window_states = .empty,
        .display = undefined,
    };

    const inter = try font.fromBytes(embedded.geist_mono, 0);
    core.collection = try font.addCollection(&.{inter});

    const arena = core.arena.allocator();
    errdefer core.arena.deinit();

    try core.chunks.init(arena, &.{
        .{
            .capacity = 50,
            .chunk_size = @sizeOf(WindowState),
        },
    });

    try core.display.init(display, io);
    errdefer core.display.deinit();

    win.setEventCallback(.window_resized, windowResize);
}

pub fn deinit() void {
    core.display.deinit();
    core.arena.deinit();
}

pub fn run() !void {
    try core.display.run();
}

fn display() bool {
    if (core.window_states.is_empty()) core.display.stop();

    const chunks = core.chunks.allocator();

    win.poll();
    while (win.popEvent()) |evt| {
        const state: *WindowState = @ptrCast(@alignCast(evt.win.userdata()));

        switch (evt.type) {
            .window_update => |update| {
                if (update.type == .window_close) {
                    state.deinit();
                    core.window_states.remove(state);
                    chunks.destroy(state);
                }
            },
            .mouse_button => state.view.pushEvent(evt.type),
            else => {},
        }
    }

    render() catch |err| {
        log.err("Frame render err={}", .{err});
    };

    return true;
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

pub fn openWindow(opts: win.Options) !void {
    const chunks = core.chunks.allocator();
    const window_state = try chunks.create(WindowState);
    try window_state.init(opts);

    core.window_states.append(window_state);
}

pub fn render() !void {
    var win_iter = core.window_states.iterator();
    while (win_iter.next()) |ws| {
        {
            view.begin(&ws.view, ws.win, ws.resize, core.collection);
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

            if (frame.atlas_gen != font.cache.atlas_gen) {
                try frame.syncAtlas(&font.cache.atlas);
            }

            var node = ws.view.root;
            while (node) |block| : (node = block.nextPre()) {
                const rect = block.rect[0] ++ block.rect[1];

                if (block.flags.background) {
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

                if (block.flags.border) {
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

                        try frame.rect(.{
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

            renderer.render(&ws.handle, frame, ws.resize);
        }
    }

    core.frame += 1;
}

pub const WindowState = struct {
    next: ?*WindowState = null,
    prev: ?*WindowState = null,

    win: win.Window,
    handle: renderer.Handle,
    view: view.View,
    resize: bool,

    pub fn init(self: *WindowState, opts: win.Options) !void {
        self.* = .{
            .view = undefined,
            .win = undefined,
            .resize = false,
            .handle = undefined,
        };

        try self.view.init(core.gpa);
        errdefer self.view.deinit();

        try self.win.init(opts);
        errdefer self.win.deinit();

        self.win.setUserdata(self);

        try self.handle.init(&self.win, core.gpa, core.io);
    }

    pub fn deinit(self: *WindowState) void {
        self.handle.deinit();
        self.win.deinit();
        self.view.deinit();
    }
};
