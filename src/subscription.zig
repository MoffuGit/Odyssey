const std = @import("std");
const Allocator = std.mem.Allocator;
const debug = std.debug;
const assert = debug.assert;
const panic = debug.panic;

const ChunkAllocator = @import("chunk_pool.zig").ChunkAllocator;
const constants = @import("constants.zig");
const MAX_CONTEXT_ALIGN = constants.MAX_CONTEXT_ALIGN;
const MAX_CONTEXT_SIZE = constants.MAX_CONTEXT_SIZE;
const datastruct = @import("datastruct.zig");
const btree = datastruct.btree;

pub fn Subscriptions(
    K: type,
    Args: type,
    comptime comp: *const fn (K, K) std.math.Order,
) type {
    return struct {
        pub const Key = K;

        fn order(a: u32, b: u32) std.math.Order {
            return std.math.order(a, b);
        }

        const Subscribers = btree.BPlusTree(
            Key,
            btree.BPlusTree(u32, *Subscription, order),
            comp,
        );

        const Dropped = btree.BPlusSet(Drops, Drops.order);

        const Callback = *const fn (*Subscription, Args) bool;

        fn noopCallback(_: *Subscription, _: Args) bool {
            return false;
        }

        pub const Subscription = struct {
            pub const noop: @This() = .{
                .callback = noopCallback,
                .active = false,
                .id = 0,
            };

            callback: Callback,
            active: bool,
            id: u32,

            pub fn enable(self: *@This()) void {
                assert(self.id != 0);
                self.active = true;
            }
        };

        pub const NODE_SIZE = @max(
            Subscribers.NODE_SIZE,
            Subscribers.Value.NODE_SIZE,
            Dropped.NODE_SIZE,
        );

        pub const Drops = struct {
            key: Key,
            id: u32,

            pub fn order(a: Drops, b: Drops) std.math.Order {
                return switch (comp(a.key, b.key)) {
                    .eq => std.math.order(a.id, b.id),
                    else => |ord| ord,
                };
            }
        };

        subscribers: Subscribers,
        dropped: Dropped,
        chunk: Allocator,
        next_id: u32,

        pub fn init(self: *@This(), chunk: Allocator) !void {
            self.* = .{
                .next_id = 1,
                .chunk = chunk,
                .subscribers = undefined,
                .dropped = undefined,
            };

            try self.subscribers.init(chunk);
            errdefer self.subscribers.deinit(chunk);

            try self.dropped.init(chunk);
            errdefer self.dropped.deinit(chunk);
        }

        pub fn deinit(self: *@This()) void {
            var outer = self.subscribers.itereator();
            while (outer.next_mut()) |entry| {
                const subscribers = entry.value;
                subscribers.deinit(self.chunk);
            }
            self.subscribers.deinit(self.chunk);
            self.dropped.deinit(self.chunk);
        }

        pub fn insert(
            self: *@This(),
            key: Key,
            callback: anytype,
            subscription: *Subscription,
        ) !void {
            assert(subscription.id == 0);
            assert(!subscription.active);

            const TypeErased = struct {
                fn _callback(sub: *Subscription, args: Args) bool {
                    return @call(.always_inline, callback, .{sub} ++ args);
                }
            };

            const id = self.next_id;
            self.next_id += 1;

            subscription.* = .{
                .active = false,
                .callback = TypeErased._callback,
                .id = id,
            };

            if (self.subscribers.get_mut(key)) |subs| {
                const old = try subs.insert(self.chunk, id, subscription);
                assert(old == null);
            } else {
                var subscribers: Subscribers.Value = undefined;
                try subscribers.init(self.chunk);
                errdefer subscribers.deinit(self.chunk);

                _ = try subscribers.insert(self.chunk, id, subscription);
                _ = try self.subscribers.insert(self.chunk, key, subscribers);
            }
        }

        pub fn notifyAll(self: *@This(), key: Key, args: Args) void {
            const subscribers = self.subscribers.get_mut(key) orelse return;

            var iter = subscribers.itereator();
            while (iter.next()) |entry| {
                if (entry.value.active and !entry.value.callback(entry.value, args)) {
                    _ = self.dropped.insert(self.chunk, .{ .key = key, .id = entry.key }) catch |err| {
                        debug.panic("Drop subscriber err: {}", .{err});
                    };
                }
            }

            self.clearDrops();
        }

        pub fn notify(self: *@This(), key: Key, id: u32, args: Args) bool {
            const subscribers = self.subscribers.get_mut(key) orelse return false;
            const subscriber = subscribers.get(id) orelse return false;

            if (!subscriber.active) return false;

            if (!subscriber.callback(subscriber, args)) {
                _ = self.dropped.insert(self.chunk, .{ .key = key, .id = id }) catch |err| {
                    debug.panic("Drop subscriber err: {}", .{err});
                };
            }

            self.clearDrops();

            return true;
        }

        pub fn clearDrops(self: *@This()) void {
            var dropped = self.dropped.iter();
            while (dropped.next()) |drop| {
                defer _ = self.dropped.remove(self.chunk, drop);

                const subscribers = self.subscribers.get_mut(drop.key) orelse continue;

                _ = subscribers.remove(self.chunk, drop.id);

                if (subscribers.is_empty()) {
                    subscribers.deinit(self.chunk);
                    _ = self.subscribers.remove(self.chunk, drop.key);
                }
            }
        }

        pub fn remove(self: *@This(), key: Key) void {
            var subscribers = self.subscribers.remove(self.chunk, key) orelse return;
            subscribers.deinit(self.chunk);
        }

        pub fn unsubscribe(self: *@This(), key: Key, id: u32) void {
            const subscribers = self.subscribers.get_mut(key) orelse return;
            _ = subscribers.remove(self.chunk, id);

            if (subscribers.is_empty()) {
                subscribers.deinit(self.chunk);
                _ = self.subscribers.remove(self.chunk, key);
            }
        }
    };
}

test "Subscriptions" {
    const Key = u32;
    const Order = struct {
        pub fn order(a: Key, b: Key) std.math.Order {
            return std.math.order(a, b);
        }
    };

    const Subs = Subscriptions(Key, @Tuple(&.{ bool, bool }), Order.order);

    const TestSub = struct {
        const Self = @This();
        run: bool,
        sub: Subs.Subscription = .noop,

        fn notify(sub: *Subs.Subscription, value: bool, keep: bool) bool {
            const self: *Self = @fieldParentPtr("sub", sub);
            self.run = value;
            return keep;
        }
    };

    var chunks: ChunkAllocator = undefined;
    try chunks.init(std.testing.allocator, &.{.{ .capacity = 100, .chunk_size = Subs.NODE_SIZE }});
    defer chunks.deinit(std.testing.allocator);

    var subscriptions: Subs = undefined;
    try subscriptions.init(chunks.allocator());
    defer subscriptions.deinit();

    const key = 42;
    var subscription: TestSub = .{ .run = false };
    try subscriptions.insert(key, TestSub.notify, &subscription.sub);

    try std.testing.expectEqual(1, subscription.sub.id);
    try std.testing.expectEqual(2, subscriptions.next_id);

    const subscribers = subscriptions.subscribers.get_mut(key).?;
    const subscriber = subscribers.get(subscription.sub.id).?;
    try std.testing.expect(!subscriber.active);

    subscriptions.notifyAll(42, .{ true, true });
    try std.testing.expect(!subscription.run);

    subscription.sub.enable();

    subscriptions.notifyAll(42, .{ true, true });
    subscriptions.notifyAll(24, .{ false, false });
    try std.testing.expect(subscription.run);

    subscriptions.notifyAll(42, .{ false, false });
    try std.testing.expect(subscriptions.subscribers.get_mut(42) == null);
}

test "Subscription notifies only its subscriber" {
    const Key = u32;
    const Order = struct {
        pub fn order(a: Key, b: Key) std.math.Order {
            return std.math.order(a, b);
        }
    };

    const Subs = Subscriptions(Key, @Tuple(&.{ u32, bool }), Order.order);

    const TestSubscription = struct {
        const Self = @This();

        result: u32,
        sub: Subs.Subscription = undefined,

        fn notify(sub: *Subs.Subscription, value: u32, keep: bool) bool {
            const self: *Self = @fieldParentPtr("sub", sub);
            self.result = value;
            return keep;
        }
    };

    var chunks: ChunkAllocator = undefined;
    try chunks.init(std.testing.allocator, &.{.{ .capacity = 100, .chunk_size = Subs.NODE_SIZE }});
    defer chunks.deinit(std.testing.allocator);

    var subscriptions: Subs = undefined;
    try subscriptions.init(chunks.allocator());
    defer subscriptions.deinit();

    var test_sub_1: TestSubscription = .{
        .result = 0,
        .sub = .noop,
    };

    var test_sub_2: TestSubscription = .{
        .result = 0,
        .sub = .noop,
    };

    try subscriptions.insert(42, TestSubscription.notify, &test_sub_1.sub);
    try subscriptions.insert(42, TestSubscription.notify, &test_sub_2.sub);

    test_sub_1.sub.enable();
    test_sub_2.sub.enable();

    _ = subscriptions.notify(42, 1, .{ 35, true });

    try std.testing.expectEqual(35, test_sub_1.result);
    try std.testing.expectEqual(0, test_sub_2.result);

    _ = subscriptions.notify(42, 1, .{ 70, false });

    try std.testing.expectEqual(70, test_sub_1.result);
    try std.testing.expect(subscriptions.subscribers.get_mut(42).?.get(1) == null);
    try std.testing.expect(subscriptions.subscribers.get_mut(42).?.get(2) != null);
}
