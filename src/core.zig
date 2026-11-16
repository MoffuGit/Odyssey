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

pub const Core = @This();

io: Io,
gpa: Allocator,
arena: ArenaAllocator,
chunks: ChunkAllocator,
display: Display,
window_states: SinglyLinkedList(WindowState),
collection: u64,
frame: u64,

// store: SlotMap(Entity),
// root: *Entity,

pub fn init(self: *Core, gpa: Allocator, io: Io) !void {
    self.* = .{
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
    self.collection = try font.addCollection(&.{inter});

    const arena = self.arena.allocator();
    errdefer self.arena.deinit();

    try self.chunks.init(arena, &.{
        .{
            .capacity = 50,
            .chunk_size = @sizeOf(WindowState),
        },
    });

    try self.display.init(displayCallback, io);
    errdefer self.display.deinit();

    win.setEventCallback(.window_resized, resizeCallback);
}

pub fn deinit(self: *Core) void {
    self.display.deinit();
    self.arena.deinit();
}

fn displayCallback(display: *Display) bool {
    const self: *Core = @fieldParentPtr("display", display);

    if (self.window_states.is_empty()) self.display.stop();

    win.poll();

    const chunks = self.chunks.allocator();

    var states = self.window_states;
    self.window_states = .empty;

    while (states.pop()) |state| {
        if (state.win.shouldClose()) {
            state.deinit();

            chunks.destroy(state);
        } else {
            while (state.win.popEvent()) |_| {
                // switch (event.type) {
                //     .mouse_button => state.view.pushEvent(event.type),
                //     else => {},
                // }
            }
            self.render(state, false) catch |err| {
                log.debug("Frame render err={}", .{err});
            };

            self.window_states.append(state);
        }
    }

    return true;
}

fn resizeCallback(event: win.Event) void {
    const window = event.win;
    const self: *Core = @ptrCast(@alignCast(window.userdata()));

    var resized: ?*WindowState = null;
    var iter = self.window_states.iterator();

    while (iter.next()) |state| {
        if (state.win.ptr == window.ptr) {
            resized = state;
        } else {
            self.render(state, false) catch |err| {
                log.err("Frame render err={}", .{err});
            };
        }
    }

    if (resized) |state| {
        self.render(state, true) catch |err| {
            log.err("Frame render err={}", .{err});
        };
    }
}

pub fn openWindow(self: *Core, opts: win.Options) !void {
    const chunks = self.chunks.allocator();
    const window_state = try chunks.create(WindowState);
    try window_state.init(self, opts);

    self.window_states.append(window_state);
}

pub fn render(self: *Core, ws: *WindowState, resize: bool) !void {
    {
        view.setView(&ws.view);

        view.begin(ws.win, resize, self.collection);
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

        renderer.render(&ws.handle, frame, resize);
    }
}
//
// fn create(self: *Core, parent: ?*Entity) Error!*Entity {
//     const key = try self.store.reserve();
//
//     self.store.insert(key, .{
//         .parent = null,
//         .childrens = .empty,
//         .key = key,
//         .next = null,
//         .prev = null,
//     });
//
//     const entity = self.store.get(key) orelse unreachable;
//
//     if (parent) |p| {
//         p.childrens.append(entity);
//         entity.parent = parent;
//     }
//
//     return entity;
// }
//
// pub const Error = Allocator.Error || error{Overflow};
//
// pub const Entity = struct {
//     key: Key,
//     childrens: DoublyLinkedList(Entity),
//     parent: ?*Entity,
//     next: ?*Entity,
//     prev: ?*Entity,
// };
//
// pub fn get(self: *Core, key: Key) ?*Entity {
//     return self.store.get(key);
// }
//
// pub fn destroy(self: *Core, entity: *Entity) void {
//     if (entity.parent) |p| {
//         p.childrens.remove(entity);
//     }
//
//     var iter = entity.childrens.iterator();
//     while (iter.next()) |child| self.destroy(child);
//
//     self.store.remove(entity.key);
// }
//
// pub fn prune(self: *Core, entity: *Entity) void {
//     var iter = entity.childrens.iterator();
//     while (iter.next()) |child| self.destroy(child);
// }
//
pub const WindowState = struct {
    next: ?*WindowState = null,

    win: win.Window,
    handle: renderer.Handle,
    view: view.View,

    pub fn init(self: *WindowState, core: *Core, opts: win.Options) !void {
        self.* = .{
            .view = undefined,
            .win = undefined,
            .handle = undefined,
        };

        try self.view.init(core.gpa);
        errdefer self.view.deinit();

        try self.win.init(opts);
        errdefer self.win.deinit();

        self.win.setUserdata(core);

        try self.handle.init(
            &self.win,
            core.gpa,
            core.io,
        );
    }

    pub fn deinit(self: *WindowState) void {
        self.handle.deinit();
        self.win.deinit();
        self.view.deinit();
    }
};
//
// test "a dropped entity's handle stays dead after its slot is reused" {
//     const Value = struct { value: u32 };
//
//     var core: Core = undefined;
//     try core.init(testing.allocator, testing.io, .{ .capacity = 2 });
//     defer core.deinit();
//
//     const first = try core.create(core.root, Value, .{ .value = 1 });
//     const key = first.key;
//     try testing.expectEqual(1, core.get(key).?.cast(Value).value);
//     core.destroy(first);
//
//     try testing.expectEqual(null, core.get(key));
//
//     const second = try core.create(core.root, Value, .{ .value = 2 });
//     const key_2 = second.key;
//
//     try testing.expectEqual(key.index, key_2.index);
//     try testing.expectEqual(null, core.get(key));
//     try testing.expectEqual(2, core.get(key_2).?.cast(Value).value);
// }
//
// test "dropping an entity destroys its subtree, children first" {
//     const Node = struct {
//         id: u8,
//     };
//
//     var core: Core = undefined;
//     try core.init(testing.allocator, testing.io, .{});
//     defer core.deinit();
//
//     const a = try core.create(core.root, Node, .{ .id = 'a' });
//     _ = try core.create(a, Node, .{ .id = 'b' });
//     const c = try core.create(a, Node, .{ .id = 'c' });
//     const d = try core.create(c, Node, .{ .id = 'd' });
//     const d_key = d.key;
//     const e = try core.create(core.root, Node, .{ .id = 'e' });
//     const e_key = e.key;
//
//     _ = try c.arena.allocator().alloc(u8, 4096);
//
//     core.destroy(a);
//
//     try testing.expectEqual(null, core.get(d_key));
//
//     const childrens = core.root.childrens;
//     try testing.expectEqual(childrens.first, childrens.last);
//     try testing.expectEqual(childrens.first, core.get(e_key));
// }
//
