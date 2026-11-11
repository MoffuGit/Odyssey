const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const assert = std.debug.assert;
const atomic = std.atomic;
const ArrayList = std.ArrayList;
const ArenaAllocator = std.heap.ArenaAllocator;

const @"type" = @import("type_id.zig");
const TypeId = @"type".TypeId;
const TypeInfo = @"type".TypeInfo;
const chunk_pool = @import("chunk_pool.zig");
const ChunkAllocator = chunk_pool.ChunkAllocator;
const constants = @import("constants.zig");
const MAX_CONTEXT_SIZE = constants.MAX_CONTEXT_SIZE;
const MAX_CONTEXT_ALIGN = constants.MAX_CONTEXT_ALIGN;
const datastruct = @import("datastruct.zig");
const btree = datastruct.btree;
const SinglyLinkedList = datastruct.SinglyLinkedList;
const slotmap = datastruct.slotmap;
const SlotMap = slotmap.SlotMap;
const subs = @import("subscription.zig");
const Subscriptions = subs.Subscriptions;
const typeId = @import("type_id.zig");

const CHUNK_SIZES: []const chunk_pool.Options = &.{
    .{ .capacity = 100, .chunk_size = 64 },
    .{ .capacity = 50, .chunk_size = 128 },
    .{ .capacity = 50, .chunk_size = 256 },
    .{ .capacity = 50, .chunk_size = 512 },
    .{ .capacity = 50, .chunk_size = 2048 },
};

const log = std.log.scoped(.core);

pub const Core = @This();

io: Io,
gpa: Allocator,
arena: ArenaAllocator,
evented: SinglyLinkedList(Evented),
dispatched: SinglyLinkedList(Dispatched),
deferred: SinglyLinkedList(Deferred),
dropped: SinglyLinkedList(Dropped),
store: SlotMap(*anyopaque),
listeners: Listeners,
receivers: Receivers,
observers: Observers,
chunks: ChunkAllocator,
flushing: bool,
pending_updates: u8,
notifications: btree.BPlusSet(Tag, Tag.order),

const Options = struct {};

pub fn init(self: *Core, gpa: Allocator, io: Io, _: Options) !void {
    self.* = .{
        .flushing = false,
        .pending_updates = 0,
        .io = io,
        .notifications = undefined,
        .observers = undefined,
        .listeners = undefined,
        .receivers = undefined,
        .chunks = undefined,
        .store = undefined,
        .gpa = gpa,
        .arena = .init(gpa),
        .evented = .empty,
        .deferred = .empty,
        .dropped = .empty,
        .dispatched = .empty,
    };

    const arena = self.arena.allocator();
    errdefer self.arena.deinit();

    self.store = try .init(arena, 100);
    try self.chunks.init(arena, CHUNK_SIZES);

    const chunks = self.chunks.allocator();

    try self.observers.init(chunks);
    try self.listeners.init(chunks);
    try self.receivers.init(chunks);
    try self.notifications.init(chunks);
}

pub fn deinit(self: *Core) void {
    self.flush();
    self.receivers.deinit();
    self.arena.deinit();
}

pub fn insert(self: *Core, ptr: anytype) Tag {
    const Type = @typeInfo(@TypeOf(ptr)).pointer.child;

    const id = self.store.put(ptr) catch @panic("Entities Overflow");
    return .init(id, TypeInfo.init(Type));
}

pub fn get(self: *Core, tag: Tag, T: type) ?*T {
    assert(TypeInfo.init(T) == tag.type_id);

    const ptr = self.store.get(tag.key) orelse return null;
    return @ptrCast(@alignCast(ptr.*));
}

pub fn recycle(self: *Core, tag: Tag) void {
    self.store.recycle(tag.key);
}

pub fn create(self: *Core, comptime T: type) struct { *T, Tag } {
    const chunks = self.chunks.allocator();
    const ptr = chunks.create(T) catch @panic("Chunk Overflow");
    const tag = self.insert(ptr);

    return .{ ptr, tag };
}

pub fn drop(self: *Core, tag: Tag) void {
    const chunks = self.chunks.allocator();
    const dropped = chunks.create(Dropped) catch @panic("Chunk Overflow");

    dropped.* = .{ .tag = tag };

    self.dropped.append(dropped);
}

pub fn flush(self: *Core) void {
    if (self.flushing) return;

    self.flushing = true;
    defer self.flushing = false;

    const chunks = self.chunks.allocator();

    while (self.deferred.pop()) |deferred| {
        deferred.callback(deferred.context);
        chunks.destroy(deferred);
    }

    while (self.dropped.pop()) |dropped| {
        const tag = dropped.tag;
        const ptr = if (self.store.get(tag.key)) |ptr| ptr.* else {
            log.warn("Tag drop does not exist: {}", .{tag});
            continue;
        };

        self.listeners.remove(tag);
        self.receivers.remove(tag);
        self.observers.remove(tag);

        tag.type_id.deinit(ptr);
        tag.type_id.destroy(ptr, chunks);

        self.recycle(tag);
        chunks.destroy(dropped);
    }

    var notifications = self.notifications.iter();
    while (notifications.next()) |id| {
        self.observers.notifyAll(id, .{ self, id });
    }

    self.notifications.clear(self.chunks.allocator());

    while (!self.evented.is_empty() or !self.dispatched.is_empty()) {
        while (self.evented.pop()) |event| {
            self.listeners.notifyAll(
                event.tag,
                .{ self, event.ptr, event.type },
            );

            event.destroy(chunks);
            chunks.destroy(event);
        }

        while (self.dispatched.pop()) |event| {
            const reach = self.receivers.notify(
                event.key,
                event.id,
                .{ self, event.ptr, event.type },
            );

            if (!reach) event.deinit();

            event.destroy(chunks);
            chunks.destroy(event);
        }
    }
}

pub fn observe(
    self: *Core,
    entity: anytype,
    function: anytype,
    observer: *Observer,
) !void {
    const T = @typeInfo(@TypeOf(entity)).pointer.child;

    const TypeErased = struct {
        fn _callback(sub: *Observer, core: *Core, tag: Tag) bool {
            const ptr = core.get(tag, T) orelse return false;

            return @call(
                .always_inline,
                function,
                .{ sub, core, ptr },
            );
        }
    };

    try self.observers.insert(
        entity.tag,
        TypeErased._callback,
        observer,
    );

    self.@"defer"(Observer, Observer.enable, observer);
}

pub fn notify(self: *Core, entity: anytype) void {
    _ = self.notifications.insert(self.chunks.allocator(), entity.tag) catch |err| {
        log.err("We cannot notify, err: {}", .{err});
    };
}

pub fn @"defer"(
    self: *Core,
    comptime T: type,
    comptime function: *const fn (*T) void,
    data: *T,
) void {
    const chunks = self.chunks.allocator();
    const deferred = chunks.create(Deferred) catch @panic("Deferred Overflow");

    const TypeErased = struct {
        fn callback(ptr: *anyopaque) void {
            const d: *T = @ptrCast(@alignCast(ptr));

            @call(.always_inline, function, .{d});
        }
    };

    deferred.* = .{
        .callback = TypeErased.callback,
        .context = data,
    };

    self.deferred.append(deferred);
}

pub fn receive(
    self: *Core,
    entity: anytype,
    comptime E: type,
    function: anytype,
    receiver: *Receiver,
) !void {
    const TypeErased = struct {
        fn _callback(sub: *Receiver, core: *Core, ptr: *anyopaque, _type: TypeId) bool {
            if (TypeInfo.init(E) != _type) @panic("Receiver subscription event type mismatch");
            const event: *E = @ptrCast(@alignCast(ptr));
            return @call(.always_inline, function, .{ sub, core, event });
        }
    };

    try self.receivers.insert(
        entity.tag,
        TypeErased._callback,
        receiver,
    );

    self.@"defer"(Receiver, Receiver.enable, receiver);
}

pub fn listen(
    self: *Core,
    entity: anytype,
    comptime E: type,
    function: anytype,
    listener: *Listener,
) !void {
    const TypeErased = struct {
        fn _callback(sub: *Listener, core: *Core, ptr: *anyopaque, _type: TypeId) bool {
            if (TypeInfo.init(E) != _type) return true;
            const event: *E = @ptrCast(@alignCast(ptr));
            return @call(.always_inline, function, .{ sub, core, event });
        }

        fn enable(core: *Core, sub: Listener) void {
            core.listeners.enable(sub);
        }
    };

    try self.listeners.insert(
        entity.tag,
        TypeErased._callback,
        listener,
    );

    self.@"defer"(Listener, Listener.enable, listener);
}

pub fn nevent(self: *Core, entity: anytype, comptime E: type) !*E {
    const chunk = self.chunks.allocator();
    const ptr = try chunk.create(E);
    errdefer chunk.destroy(ptr);

    const node = try chunk.create(Evented);
    node.* = .{
        .tag = entity.tag,
        .ptr = ptr,
        .type = TypeInfo.init(E),
    };

    self.evented.append(node);

    return ptr;
}

pub fn dispatch(self: *Core, entity: anytype, id: u32, comptime E: type) !*E {
    const chunk = self.chunks.allocator();
    const ptr = try chunk.create(E);
    errdefer chunk.destroy(ptr);

    const node = try chunk.create(Dispatched);

    node.* = .{
        .key = entity.tag,
        .id = id,
        .ptr = ptr,
        .type = TypeInfo.init(E),
    };

    self.dispatched.append(node);

    return ptr;
}

pub const Observers = Subscriptions(Tag, @Tuple(&.{ *Core, Tag }), Tag.order);

pub const Observer = Observers.Subscription;

pub const Listeners = Subscriptions(Tag, @Tuple(&.{ *Core, *anyopaque, TypeId }), Tag.order);

pub const Listener = Listeners.Subscription;

pub const Receivers = Subscriptions(Tag, @Tuple(&.{ *Core, *anyopaque, TypeId }), Tag.order);

pub const Receiver = Receivers.Subscription;

pub const Deferred = struct {
    callback: *const fn (*anyopaque) void,
    context: *anyopaque,
    next: ?*Deferred = null,
};

pub const Evented = struct {
    tag: Tag,
    type: TypeId,
    ptr: *anyopaque,
    next: ?*Evented = null,

    pub fn destroy(self: *const Evented, chunk: Allocator) void {
        self.type.deinit(self.ptr);
        self.type.destroy(self.ptr, chunk);
    }
};

pub const Dispatched = struct {
    key: Receivers.Key,
    id: u32,
    type: TypeId,
    ptr: *anyopaque,

    next: ?*Dispatched = null,

    pub fn deinit(self: *const Dispatched) void {
        self.type.deinit(self.ptr);
    }

    pub fn destroy(self: *const Dispatched, chunk: Allocator) void {
        self.type.destroy(self.ptr, chunk);
    }
};

pub const Dropped = struct {
    tag: Tag,
    next: ?*Dropped = null,
};

pub const Tag = struct {
    const Key = slotmap.Key;

    type_id: TypeId,
    key: slotmap.Key,

    pub fn init(key: Key, type_id: TypeId) @This() {
        return .{ .key = key, .type_id = type_id };
    }

    pub fn order(a: Tag, b: Tag) std.math.Order {
        const index_order = std.math.order(a.key.index, b.key.index);
        if (index_order != .eq) return index_order;

        return std.math.order(@backingInt(a.key.generation), @backingInt(b.key.generation));
    }
};

const TestStruct = struct {
    index: usize,
    tag: Tag,
};

test "creates/drops entities" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;

    var core: Core = undefined;
    try core.init(allocator, io, .{});
    defer core.deinit();

    var tags: [32]Tag = undefined;
    for (&tags, 0..) |*tag, index| {
        const ptr, tag.* = core.create(TestStruct);

        ptr.* = .{
            .index = 0,
            .tag = tag.*,
        };
        ptr.index = index;
        ptr.index += 1;
    }

    core.flush();

    for (tags, 0..) |tag, index| {
        try testing.expectEqual(index + 1, core.get(tag, TestStruct).?.index);
        core.drop(tag);
    }

    core.flush();
}

test "Observe entities" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;

    var core: Core = undefined;
    try core.init(allocator, io, .{});
    defer core.deinit();

    const observed, const tag = core.create(TestStruct);
    defer core.drop(tag);

    observed.* = .{ .index = 0, .tag = tag };

    const TestObserver = struct {
        run: bool = false,
        observer: Observer = .noop,

        pub fn callback(observer: *Observer, _: *Core, _: *TestStruct) bool {
            const parent: *@This() = @fieldParentPtr("observer", observer);
            parent.run = true;
            return false;
        }
    };

    var observer: TestObserver = .{};

    core.notify(observed);
    core.flush();

    try testing.expect(!observer.run);

    _ = try core.observe(observed, TestObserver.callback, &observer.observer);

    core.notify(observed);
    core.flush();

    try testing.expect(observer.run);

    core.flush();
}

test "Listen entities events" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;

    const TestEvent = struct {
        id: usize,
    };

    var core: Core = undefined;
    try core.init(allocator, io, .{});
    defer core.deinit();

    const listened, const tag = core.create(TestStruct);
    defer core.drop(tag);

    const TestListener = struct {
        id: usize = 0,
        listener: Listener = .noop,

        pub fn callback(listener: *Listener, _: *Core, evt: *TestEvent) bool {
            const parent: *@This() = @fieldParentPtr("listener", listener);
            parent.id = evt.id;
            return false;
        }
    };

    var listener: TestListener = .{};

    _ = try core.listen(listened, TestEvent, TestListener.callback, &listener.listener);

    const evt = try core.nevent(listened, TestEvent);
    evt.* = .{
        .id = 35,
    };

    core.flush();

    try testing.expectEqual(listener.id, 35);

    core.flush();
}

test "Queued receiver event targets a typed subscription" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;

    const TestEvent = struct {
        value: usize,
    };

    const TestReceiver = struct {
        received: usize = 0,
        receiver: Receiver = .noop,

        pub fn callback(receiver: *Receiver, _: *Core, evt: *TestEvent) bool {
            const parent: *@This() = @fieldParentPtr("receiver", receiver);
            parent.received = evt.value;
            return false;
        }
    };

    var core: Core = undefined;
    try core.init(allocator, io, .{});
    defer core.deinit();

    const dispatcher, const tag = core.create(TestStruct);
    defer core.drop(tag);

    dispatcher.* = .{ .index = 0, .tag = tag };

    var receiver: TestReceiver = .{};

    try core.receive(dispatcher, TestEvent, TestReceiver.callback, &receiver.receiver);
    core.flush();

    const event = try core.dispatch(dispatcher, receiver.receiver.id, TestEvent);
    event.* = .{ .value = 35 };
    core.flush();

    try testing.expectEqual(@as(usize, 35), receiver.received);
    try testing.expectEqual(null, core.receivers.subscribers.get_mut(dispatcher.tag));

    core.flush();
}

test "Dropping a receiver removes subscriptions before queued delivery" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;

    const TestEvent = struct {
        deinit_called: *bool,

        pub fn deinit(self: *@This()) void {
            self.deinit_called.* = true;
        }
    };

    const TestReceiver = struct {
        received: bool = false,
        receiver: Receiver = .noop,

        pub fn callback(receiver: *Receiver, _: *Core, evt: *TestEvent) bool {
            const parent: *@This() = @fieldParentPtr("receiver", receiver);
            parent.received = evt.deinit_called.*;
            return false;
        }
    };

    var core: Core = undefined;
    try core.init(allocator, io, .{});
    defer core.deinit();

    const dispatcher, const tag = core.create(TestStruct);
    var deinit_called = false;

    dispatcher.* = .{ .index = 0, .tag = tag };

    var receiver: TestReceiver = .{};

    try core.receive(dispatcher, TestEvent, TestReceiver.callback, &receiver.receiver);
    core.flush();

    const event = try core.dispatch(dispatcher, receiver.receiver.id, TestEvent);
    event.* = .{ .deinit_called = &deinit_called };

    core.drop(tag);
    core.flush();

    try testing.expect(!receiver.received);
    try testing.expect(deinit_called);
    try testing.expectEqual(null, core.receivers.subscribers.get_mut(tag));
}

test "Observe entities drop before enable" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const io = testing.io;

    const TestObserver = struct {
        run: bool = false,
        observer: Observer = .noop,

        pub fn callback(observer: *Observer, _: *Core, _: *TestStruct) bool {
            const parent: *@This() = @fieldParentPtr("observer", observer);
            parent.run = true;
            return false;
        }
    };

    var core: Core = undefined;
    try core.init(allocator, io, .{});
    defer core.deinit();

    const observed, const tag = core.create(TestStruct);

    observed.* = .{ .index = 0, .tag = tag };

    var observer: TestObserver = .{};

    observed.index = 1;

    core.notify(observed);

    try testing.expect(!observer.run);

    try core.observe(observed, TestObserver.callback, &observer.observer);
    core.observers.unsubscribe(observed.tag, observer.observer.id);

    observed.index = 2;

    core.notify(observed);

    core.flush();

    try testing.expect(!observer.run);

    core.drop(tag);

    core.flush();
}
