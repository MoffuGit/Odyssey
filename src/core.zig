//! Core owns every entity of the application: its state, its place in the
//! interface tree, the memory it allocates, and the subscriptions other
//! entities make to it.
//!
//! - Entities live in a generational slot map and are addressed through
//!   `Handle(T)`. A handle to a dropped entity stops resolving, even after its
//!   slot is reused, so entities can safely hold handles to each other.
//! - Entities form a tree rooted at `Core.root`. A window can own a workspace,
//!   which owns its topbar and sidebar, and so on. Dropping an entity destroys
//!   its whole subtree, children before parents.
//! - Entity state is allocated from size-classed chunk pools. Data whose size
//!   is only known at runtime (strings, lists) goes into the entity's arena,
//!   `arenaOf`, which is freed when the entity is destroyed.
//! - Each entity stores the subscriptions made to it. A subscription refers to
//!   its subscriber by key, so a dropped subscriber is skipped and pruned
//!   instead of leaving a dangling pointer. `emit` reaches every subscriber;
//!   `send` reaches the one subscription whose id it is given.
//! - `emit`, `send`, `notify` and `drop` only queue work. `flush` delivers queued
//!   events, including the ones handlers emit while it runs, and then destroys
//!   dropped entities. Event payloads live in a frame arena that is reset once
//!   a flush drains every queue.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Io = std.Io;
const assert = std.debug.assert;

const chunk_pool = @import("chunk_pool.zig");
const ChunkAllocator = chunk_pool.ChunkAllocator;
const datastruct = @import("datastruct.zig");
const SinglyLinkedList = datastruct.SinglyLinkedList;
const slotmap = datastruct.slotmap;
const SlotMap = slotmap.SlotMap;
pub const Key = slotmap.Key;
const type_id = @import("type_id.zig");
const TypeId = type_id.TypeId;
const TypeInfo = type_id.TypeInfo;

const log = std.log.scoped(.core);

const CHUNK_SIZES = [_]u32{ 64, 128, 256, 512, 2048 };

/// Entity state must fit in the biggest chunk class; anything bigger belongs in
/// the entity's arena.
pub const MAX_ENTITY_SIZE = CHUNK_SIZES[CHUNK_SIZES.len - 1];

pub const Core = @This();

io: Io,
gpa: Allocator,
/// Core-lifetime memory: the entity table and the chunk pools.
arena: ArenaAllocator,
/// Entity state and subscriptions, recycled per size class.
chunks: ChunkAllocator,
/// Queued events and their payloads, reset when a flush drains every queue.
frame: ArenaAllocator,
store: SlotMap(Entity),
root: Handle(Root),
events: SinglyLinkedList(Event),
/// Set by `drop`; the next flush sweeps the tree for entities to destroy.
sweep_pending: bool,
/// Orders subscriptions and events, so a subscription only receives events
/// emitted after it was made.
seq: u64,
flushing: bool,

pub const Options = struct {
    /// The max number of entities alive at once, including `root`.
    capacity: u32 = 256,
};

pub const Error = Allocator.Error || error{ Overflow, EntityNotFound };

/// A typed reference to an entity.
pub fn Handle(comptime T: type) type {
    return struct {
        pub const Type = T;

        key: Key,

        pub fn get(self: @This(), core: *Core) ?*T {
            return core.get(self);
        }
    };
}

/// The entity every other entity descends from.
pub const Root = struct {};

/// Emitted by `notify` when an entity's state changed.
pub const Changed = struct { key: Key };

pub const Entity = struct {
    type_id: TypeId,
    ptr: *anyopaque,
    arena: ArenaAllocator,
    parent: Key.Optional = .none,
    first: Key.Optional = .none,
    last: Key.Optional = .none,
    next: Key.Optional = .none,
    prev: Key.Optional = .none,
    subs: SinglyLinkedList(Subscription) = .empty,
    /// The queued `Changed` event, so repeated notifies coalesce into it.
    changed: ?*Event = null,
    dropping: bool = false,
};

pub const Subscription = struct {
    pub const Id = struct { emitter: Key, id: u64 };

    next: ?*Subscription = null,
    id: u64,
    subscriber: Key,
    event: TypeId,
    callback: *const fn (*anyopaque, *Core, *const anyopaque) bool,
    dead: bool = false,
};

const Event = struct {
    next: ?*Event = null,
    emitter: Key,
    seq: u64,
    type_id: TypeId,
    payload: *anyopaque,
    /// The one subscription id to deliver to, or 0 for every subscriber.
    target: u64 = 0,
};

pub fn init(self: *Core, gpa: Allocator, io: Io, opts: Options) !void {
    self.* = .{
        .io = io,
        .gpa = gpa,
        .arena = .init(gpa),
        .chunks = undefined,
        .frame = .init(gpa),
        .store = undefined,
        .root = undefined,
        .events = .empty,
        .sweep_pending = false,
        .seq = 0,
        .flushing = false,
    };
    errdefer self.arena.deinit();

    const arena = self.arena.allocator();

    var pools: [CHUNK_SIZES.len]chunk_pool.Options = undefined;
    for (&pools, CHUNK_SIZES) |*pool, size| {
        // The smallest class also holds every subscription.
        const capacity = if (size == CHUNK_SIZES[0]) opts.capacity * 4 else opts.capacity;
        pool.* = .{ .capacity = capacity, .chunk_size = size };
    }

    self.store = try .init(arena, opts.capacity);
    try self.chunks.init(arena, &pools);
    self.root = try self.insert(.none, Root, .{});
}

pub fn deinit(self: *Core) void {
    self.flush();
    self.destroy(self.root.key);
    // Deliver or discard whatever the destroyed entities queued on the way out.
    self.flush();
    self.frame.deinit();
    self.arena.deinit();
}

/// Creates an entity of type `T` as the last child of `parent`, which is a
/// handle or a key. On error the caller still owns `value`.
pub fn create(self: *Core, parent: anytype, comptime T: type, value: T) Error!Handle(T) {
    const parent_key = keyOf(parent);
    if (self.store.get(parent_key) == null) return error.EntityNotFound;
    return self.insert(parent_key.toOptional(), T, value);
}

pub fn get(self: *Core, handle: anytype) ?*@TypeOf(handle).Type {
    const T = @TypeOf(handle).Type;
    const entity = self.store.get(handle.key) orelse return null;
    assert(entity.type_id == TypeInfo.init(T));
    return @ptrCast(@alignCast(entity.ptr));
}

/// Returns a typed handle when `key` is alive and holds a `T`.
pub fn cast(self: *Core, key: Key, comptime T: type) ?Handle(T) {
    const entity = self.store.get(key) orelse return null;
    if (entity.type_id != TypeInfo.init(T)) return null;
    return .{ .key = key };
}

/// Memory owned by the entity, freed when it is destroyed.
pub fn arenaOf(self: *Core, handle: anytype) Error!Allocator {
    const entity = self.store.get(keyOf(handle)) orelse return error.EntityNotFound;
    return entity.arena.allocator();
}

/// Queues the entity and its subtree for destruction at the next flush. Until
/// then it stays readable, but its subscriptions stop receiving events.
pub fn drop(self: *Core, handle: anytype) void {
    const key = keyOf(handle);
    assert(key != self.root.key);

    const entity = self.store.get(key) orelse return;
    entity.dropping = true;
    self.sweep_pending = true;
}

pub const Children = struct {
    core: *Core,
    next_key: Key.Optional,

    pub fn next(self: *Children) ?Key {
        const key = self.next_key.unwrap() orelse return null;
        self.next_key = self.core.store.get(key).?.next;
        return key;
    }
};

pub fn children(self: *Core, parent: anytype) Children {
    const entity = self.store.get(keyOf(parent));
    return .{
        .core = self,
        .next_key = if (entity) |e| e.first else .none,
    };
}

/// Calls `handler` with every `E` that `emitter` emits after this call.
/// `handler` is `fn (*S, *Core, *const E) bool` where `S` is the subscriber's
/// type, and may return an error union. Returning false unsubscribes; an error
/// is logged and keeps the subscription.
pub fn subscribe(
    self: *Core,
    emitter: anytype,
    subscriber: anytype,
    comptime E: type,
    comptime handler: anytype,
) Error!Subscription.Id {
    const S = @TypeOf(subscriber).Type;

    const Erased = struct {
        fn callback(ptr: *anyopaque, core: *Core, payload: *const anyopaque) bool {
            const result = handler(
                @as(*S, @ptrCast(@alignCast(ptr))),
                core,
                @as(*const E, @ptrCast(@alignCast(payload))),
            );

            return switch (@typeInfo(@TypeOf(result))) {
                .error_union => result catch |err| {
                    log.err("{s} handler for {s} failed: {}", .{ @typeName(S), @typeName(E), err });
                    return true;
                },
                else => result,
            };
        }
    };

    const emitter_key = keyOf(emitter);
    const entity = self.store.get(emitter_key) orelse return error.EntityNotFound;
    if (self.store.get(subscriber.key) == null) return error.EntityNotFound;

    const sub = try self.chunks.allocator().create(Subscription);
    sub.* = .{
        .id = self.nextSeq(),
        .subscriber = subscriber.key,
        .event = TypeInfo.init(E),
        .callback = Erased.callback,
    };
    entity.subs.append(sub);

    return .{ .emitter = emitter_key, .id = sub.id };
}

pub fn unsubscribe(self: *Core, id: Subscription.Id) void {
    const entity = self.store.get(id.emitter) orelse return;

    var prev: ?*Subscription = null;
    var node = entity.subs.head;
    while (node) |sub| : ({
        prev = sub;
        node = sub.next;
    }) {
        if (sub.id != id.id) continue;

        // A flush may be walking this list; it unlinks dead subscriptions.
        if (self.flushing) {
            sub.dead = true;
        } else {
            self.removeSub(entity, prev, sub);
        }
        return;
    }
}

/// Queues `event` for the subscribers of `emitter`. Once delivered, the
/// payload is deinitialized if `E` has a `deinit`. On error the caller still
/// owns `event`.
pub fn emit(self: *Core, emitter: anytype, comptime E: type, event: E) Allocator.Error!void {
    try self.queue(keyOf(emitter), 0, E, event);
}

/// Queues `event` for the one subscription `id`, which must be subscribed to
/// `E`. Nothing is delivered if that subscription or its subscriber is gone by
/// the next flush. The payload is deinitialized like an emitted one.
pub fn send(self: *Core, id: Subscription.Id, comptime E: type, event: E) Allocator.Error!void {
    try self.queue(id.emitter, id.id, E, event);
}

fn queue(self: *Core, emitter: Key, target: u64, comptime E: type, event: E) Allocator.Error!void {
    const frame = self.frame.allocator();

    const payload = try frame.create(E);
    payload.* = event;

    const node = try frame.create(Event);
    node.* = .{
        .emitter = emitter,
        .seq = self.nextSeq(),
        .type_id = TypeInfo.init(E),
        .payload = payload,
        .target = target,
    };
    self.events.append(node);
}

/// Queues a `Changed` event for `handle`. Notifies before the next flush
/// coalesce into one event.
pub fn notify(self: *Core, handle: anytype) Allocator.Error!void {
    const key = keyOf(handle);
    const entity = self.store.get(key) orelse return;

    if (entity.changed) |pending| {
        pending.seq = self.nextSeq();
        return;
    }

    try self.emit(key, Changed, .{ .key = key });
    entity.changed = self.events.tail;
}

/// Delivers queued events, then destroys dropped entities, until both queues
/// are empty.
pub fn flush(self: *Core) void {
    if (self.flushing) return;

    self.flushing = true;
    defer self.flushing = false;

    while (true) {
        if (self.events.pop()) |event| {
            self.deliver(event);
        } else if (self.sweep_pending) {
            self.sweep_pending = false;
            self.sweep(self.root.key);
        } else break;
    }

    _ = self.frame.reset(.retain_capacity);
}

fn insert(self: *Core, parent: Key.Optional, comptime T: type, value: T) Error!Handle(T) {
    comptime assert(@sizeOf(T) <= MAX_ENTITY_SIZE);

    const chunks = self.chunks.allocator();
    const ptr = try chunks.create(T);
    errdefer chunks.destroy(ptr);
    ptr.* = value;

    const key = try self.store.put(.{
        .type_id = TypeInfo.init(T),
        .ptr = ptr,
        .arena = .init(self.gpa),
    });

    if (parent.unwrap()) |parent_key| self.link(parent_key, key);

    return .{ .key = key };
}

fn link(self: *Core, parent_key: Key, key: Key) void {
    const parent = self.store.get(parent_key).?;
    const entity = self.store.get(key).?;

    entity.parent = parent_key.toOptional();
    entity.prev = parent.last;

    if (parent.last.unwrap()) |last| {
        self.store.get(last).?.next = key.toOptional();
    } else {
        parent.first = key.toOptional();
    }
    parent.last = key.toOptional();
}

fn unlink(self: *Core, key: Key) void {
    const entity = self.store.get(key).?;
    const parent = self.store.get(entity.parent.unwrap() orelse return).?;

    if (entity.prev.unwrap()) |prev| {
        self.store.get(prev).?.next = entity.next;
    } else {
        parent.first = entity.next;
    }

    if (entity.next.unwrap()) |next| {
        self.store.get(next).?.prev = entity.prev;
    } else {
        parent.last = entity.prev;
    }

    entity.parent = .none;
    entity.prev = .none;
    entity.next = .none;
}

fn deliver(self: *Core, event: *Event) void {
    defer event.type_id.deinit(event.payload);

    const emitter = self.store.get(event.emitter) orelse return;
    if (emitter.changed == event) emitter.changed = null;

    var prev: ?*Subscription = null;
    var node = emitter.subs.head;
    while (node) |sub| {
        var keep = !sub.dead;

        if (keep) {
            if (self.store.get(sub.subscriber)) |subscriber| {
                const targeted = event.target == sub.id;
                assert(!targeted or sub.event == event.type_id);

                if ((event.target == 0 or targeted) and
                    sub.event == event.type_id and
                    sub.id < event.seq and
                    !subscriber.dropping)
                {
                    keep = sub.callback(subscriber.ptr, self, event.payload);
                }
            } else {
                keep = false;
            }
        }

        // Read after the callback: it may have appended a subscription.
        node = sub.next;

        if (keep and !sub.dead) {
            prev = sub;
        } else {
            self.removeSub(emitter, prev, sub);
        }
    }
}

fn removeSub(self: *Core, entity: *Entity, prev: ?*Subscription, sub: *Subscription) void {
    if (prev) |p| p.next = sub.next else entity.subs.head = sub.next;
    if (entity.subs.tail == sub) entity.subs.tail = prev;

    self.chunks.allocator().destroy(sub);
}

fn sweep(self: *Core, key: Key) void {
    var child = self.store.get(key).?.first;
    while (child.unwrap()) |child_key| {
        const entity = self.store.get(child_key).?;
        child = entity.next;

        if (entity.dropping) {
            self.destroy(child_key);
        } else {
            self.sweep(child_key);
        }
    }
}

/// Destroys children first, so an entity can still read its parent from its
/// `deinit`.
fn destroy(self: *Core, key: Key) void {
    const entity = self.store.get(key) orelse return;

    while (entity.first.unwrap()) |child| self.destroy(child);

    self.unlink(key);
    entity.type_id.deinit(entity.ptr);

    const chunks = self.chunks.allocator();
    while (entity.subs.pop()) |sub| chunks.destroy(sub);
    entity.arena.deinit();
    entity.type_id.destroy(entity.ptr, chunks);

    _ = self.store.remove(key);
}

fn nextSeq(self: *Core) u64 {
    self.seq += 1;
    return self.seq;
}

fn keyOf(value: anytype) Key {
    return if (@TypeOf(value) == Key) value else value.key;
}

const testing = std.testing;

test "a dropped entity's handle stays dead after its slot is reused" {
    const Value = struct { value: u32 };

    var core: Core = undefined;
    try core.init(testing.allocator, testing.io, .{ .capacity = 2 });
    defer core.deinit();

    const first = try core.create(core.root, Value, .{ .value = 1 });
    core.drop(first);
    try testing.expectEqual(1, core.get(first).?.value);

    core.flush();
    try testing.expectEqual(null, core.get(first));

    const second = try core.create(core.root, Value, .{ .value = 2 });
    try testing.expectEqual(first.key.index, second.key.index);
    try testing.expectEqual(null, core.get(first));
    try testing.expectEqual(2, core.get(second).?.value);
}

test "dropping an entity destroys its subtree, children first" {
    const Node = struct {
        id: u8,
        destroyed: *std.ArrayList(u8),

        pub fn deinit(self: *@This()) void {
            self.destroyed.appendAssumeCapacity(self.id);
        }
    };

    var buffer: [8]u8 = undefined;
    var destroyed: std.ArrayList(u8) = .initBuffer(&buffer);

    {
        var core: Core = undefined;
        try core.init(testing.allocator, testing.io, .{});
        defer core.deinit();

        // root -> a -> { b, c -> d }, root -> e
        const a = try core.create(core.root, Node, .{ .id = 'a', .destroyed = &destroyed });
        _ = try core.create(a, Node, .{ .id = 'b', .destroyed = &destroyed });
        const c = try core.create(a, Node, .{ .id = 'c', .destroyed = &destroyed });
        const d = try core.create(c, Node, .{ .id = 'd', .destroyed = &destroyed });
        _ = try core.create(core.root, Node, .{ .id = 'e', .destroyed = &destroyed });

        // Entity arenas are released with their entity; testing.allocator
        // reports a leak otherwise.
        _ = try (try core.arenaOf(c)).alloc(u8, 4096);

        core.drop(a);
        core.flush();

        try testing.expectEqualStrings("bdca", destroyed.items);
        try testing.expectEqual(null, core.get(d));

        var remaining = core.children(core.root);
        try testing.expectEqual('e', core.get(core.cast(remaining.next().?, Node).?).?.id);
        try testing.expectEqual(null, remaining.next());
    }

    try testing.expectEqualStrings("bdcae", destroyed.items);
}

test "subscriptions receive matching events emitted after they subscribe" {
    const Ping = struct {
        value: u32,
        deinits: *u32,

        pub fn deinit(self: *@This()) void {
            self.deinits.* += 1;
        }
    };
    const Other = struct {};
    const Emitter = struct {};
    const Listener = struct {
        received: *std.ArrayList(u32),

        fn onPing(self: *@This(), _: *Core, ping: *const Ping) bool {
            self.received.appendAssumeCapacity(ping.value);
            return ping.value != 3;
        }

        fn onOther(_: *@This(), _: *Core, _: *const Other) bool {
            unreachable;
        }
    };

    var core: Core = undefined;
    try core.init(testing.allocator, testing.io, .{});
    defer core.deinit();

    var buffer: [8]u32 = undefined;
    var received: std.ArrayList(u32) = .initBuffer(&buffer);
    var dropped_buffer: [8]u32 = undefined;
    var dropped_received: std.ArrayList(u32) = .initBuffer(&dropped_buffer);
    var deinits: u32 = 0;

    const emitter = try core.create(core.root, Emitter, .{});
    const listener = try core.create(core.root, Listener, .{ .received = &received });
    const dropped = try core.create(core.root, Listener, .{ .received = &dropped_received });

    try core.emit(emitter, Ping, .{ .value = 1, .deinits = &deinits });
    _ = try core.subscribe(emitter, listener, Ping, Listener.onPing);
    _ = try core.subscribe(emitter, dropped, Ping, Listener.onPing);
    const other = try core.subscribe(emitter, listener, Other, Listener.onOther);
    core.unsubscribe(other);
    core.drop(dropped);

    try core.emit(emitter, Ping, .{ .value = 2, .deinits = &deinits });
    try core.emit(emitter, Other, .{});
    try core.emit(emitter, Ping, .{ .value = 3, .deinits = &deinits });
    try core.emit(emitter, Ping, .{ .value = 4, .deinits = &deinits });
    core.flush();

    // 1 predates the subscription, and returning false on 3 unsubscribed.
    try testing.expectEqualSlices(u32, &.{ 2, 3 }, received.items);
    try testing.expectEqualSlices(u32, &.{}, dropped_received.items);
    try testing.expectEqual(4, deinits);

    // The dropped listener's subscription is pruned by the emitter's next event.
    try core.emit(emitter, Ping, .{ .value = 5, .deinits = &deinits });
    core.flush();
    try testing.expectEqual(null, core.store.get(emitter.key).?.subs.head);
}

test "a sent event reaches only its target subscription" {
    const Ping = struct {
        value: u32,
        deinits: *u32,

        pub fn deinit(self: *@This()) void {
            self.deinits.* += 1;
        }
    };
    const Emitter = struct {};
    const Listener = struct {
        received: u32 = 0,

        fn onPing(self: *@This(), _: *Core, ping: *const Ping) bool {
            self.received = ping.value;
            return true;
        }
    };

    var core: Core = undefined;
    try core.init(testing.allocator, testing.io, .{});
    defer core.deinit();

    var deinits: u32 = 0;

    const emitter = try core.create(core.root, Emitter, .{});
    const first = try core.create(core.root, Listener, .{});
    const second = try core.create(core.root, Listener, .{});
    const dropped = try core.create(core.root, Listener, .{});

    _ = try core.subscribe(emitter, first, Ping, Listener.onPing);
    const second_sub = try core.subscribe(emitter, second, Ping, Listener.onPing);
    const dropped_sub = try core.subscribe(emitter, dropped, Ping, Listener.onPing);

    try core.send(second_sub, Ping, .{ .value = 7, .deinits = &deinits });
    core.flush();

    try testing.expectEqual(0, core.get(first).?.received);
    try testing.expectEqual(7, core.get(second).?.received);

    core.drop(dropped);
    try core.send(dropped_sub, Ping, .{ .value = 9, .deinits = &deinits });
    core.flush();

    try testing.expectEqual(0, core.get(first).?.received);
    try testing.expectEqual(7, core.get(second).?.received);
    try testing.expectEqual(2, deinits);
}

test "an emitter's last events reach subscribers before it is destroyed" {
    const Closed = struct {};
    const Emitter = struct {};
    const Listener = struct {
        closed: u32 = 0,
        changed: u32 = 0,

        fn onClosed(self: *@This(), _: *Core, _: *const Closed) bool {
            self.closed += 1;
            return true;
        }

        fn onChanged(self: *@This(), _: *Core, _: *const Changed) bool {
            self.changed += 1;
            return true;
        }
    };

    var core: Core = undefined;
    try core.init(testing.allocator, testing.io, .{});
    defer core.deinit();

    const emitter = try core.create(core.root, Emitter, .{});
    const listener = try core.create(core.root, Listener, .{});

    _ = try core.subscribe(emitter, listener, Closed, Listener.onClosed);
    _ = try core.subscribe(emitter, listener, Changed, Listener.onChanged);

    try core.notify(emitter);
    try core.notify(emitter);
    try core.notify(emitter);
    try core.emit(emitter, Closed, .{});
    core.drop(emitter);
    core.flush();

    try testing.expectEqual(null, core.get(emitter));
    try testing.expectEqual(1, core.get(listener).?.closed);
    try testing.expectEqual(1, core.get(listener).?.changed);
}

test "a workspace declares its interface as an entity tree" {
    const Topbar = struct { title: []const u8 = "" };

    const Sidebar = struct {
        const Sidebar = @This();
        const Selected = struct { index: usize };

        items: []const []const u8 = &.{},
        selected: ?usize = null,

        fn select(handle: Handle(Sidebar), core: *Core, index: usize) !void {
            core.get(handle).?.selected = index;
            try core.emit(handle, Selected, .{ .index = index });
        }
    };

    const Workspace = struct {
        const Workspace = @This();

        topbar: Handle(Topbar),
        sidebar: Handle(Sidebar),

        fn create(core: *Core, parent: anytype, items: []const []const u8) !Handle(Workspace) {
            const handle = try core.create(parent, Workspace, undefined);
            errdefer core.drop(handle);

            const self = core.get(handle).?;
            self.topbar = try core.create(handle, Topbar, .{});
            self.sidebar = try core.create(handle, Sidebar, .{});

            const sidebar_arena = try core.arenaOf(self.sidebar);
            const owned = try sidebar_arena.alloc([]const u8, items.len);
            for (owned, items) |*item, src| item.* = try sidebar_arena.dupe(u8, src);
            core.get(self.sidebar).?.items = owned;

            _ = try core.subscribe(self.sidebar, handle, Sidebar.Selected, onSelected);
            return handle;
        }

        fn onSelected(self: *Workspace, core: *Core, event: *const Sidebar.Selected) !bool {
            const item = core.get(self.sidebar).?.items[event.index];
            core.get(self.topbar).?.title = try (try core.arenaOf(self.topbar)).dupe(u8, item);
            try core.notify(self.topbar);
            return true;
        }
    };

    const Window = struct {
        redraws: u32 = 0,

        fn onChanged(self: *@This(), _: *Core, _: *const Changed) bool {
            self.redraws += 1;
            return true;
        }
    };

    var core: Core = undefined;
    try core.init(testing.allocator, testing.io, .{});
    defer core.deinit();

    const window = try core.create(core.root, Window, .{});
    const workspace = try Workspace.create(&core, window, &.{ "src", "build.zig", "README" });
    const ws = core.get(workspace).?;
    _ = try core.subscribe(ws.topbar, window, Changed, Window.onChanged);

    var parts = core.children(workspace);
    try testing.expectEqual(ws.topbar, core.cast(parts.next().?, Topbar).?);
    try testing.expectEqual(ws.sidebar, core.cast(parts.next().?, Sidebar).?);
    try testing.expectEqual(null, parts.next());

    // The sidebar's event and the topbar notify it causes run in one flush.
    try Sidebar.select(ws.sidebar, &core, 1);
    core.flush();

    try testing.expectEqualStrings("build.zig", core.get(ws.topbar).?.title);
    try testing.expectEqual(1, core.get(window).?.redraws);

    const topbar = ws.topbar;
    core.drop(workspace);
    core.flush();

    try testing.expectEqual(null, core.get(topbar));
    try testing.expect(core.get(window) != null);
}
