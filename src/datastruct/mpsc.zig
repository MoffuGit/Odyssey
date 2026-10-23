const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const testing = std.testing;

const spsc = @import("spsc.zig");

pub fn MpscBounded(comptime T: type) type {
    return struct {
        const Self = @This();

        const Slot = struct {
            spsc: spsc.SpscBounded(T),
            claimed: std.atomic.Value(bool),
        };

        pub const Producer = struct {
            slot: ?*Slot,

            pub fn push(self: *const Producer, value: T) void {
                const slot = self.slot orelse @panic("Producer Unregistered");
                return slot.spsc.push(value);
            }

            pub fn tryPush(self: *const Producer, value: T) bool {
                const slot = self.slot orelse @panic("Producer Unregistered");
                return slot.spsc.tryPush(value);
            }

            pub fn unregister(self: *Producer) void {
                const slot = self.slot orelse @panic("Producer Unregistered");
                self.slot = null;
                if (!slot.claimed.swap(false, .release)) unreachable;
            }
        };

        slots: []Slot,
        next_channel: usize = 0,

        pub fn init(
            producers: usize,
            buffer_size: u16,
            allocator: Allocator,
        ) !Self {
            const slots = try allocator.alloc(Slot, producers);
            errdefer allocator.free(slots);

            var initialized: usize = 0;
            errdefer for (slots[0..initialized]) |*slot| {
                slot.spsc.deinit(allocator);
            };

            for (slots) |*slot| {
                slot.* = .{
                    .spsc = try .init(buffer_size, allocator),
                    .claimed = .init(false),
                };
                initialized += 1;
            }

            return .{ .slots = slots };
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            for (self.slots) |*slot| {
                if (slot.claimed.load(.monotonic)) unreachable;
                slot.spsc.deinit(allocator);
            }
            allocator.free(self.slots);
            self.* = undefined;
        }

        pub fn register(self: *Self) ?Producer {
            for (self.slots) |*slot| {
                if (slot.claimed.cmpxchgStrong(
                    false,
                    true,
                    .acquire,
                    .monotonic,
                ) == null) return .{ .slot = slot };
            }
            return null;
        }

        pub fn pop(self: *Self) ?T {
            if (self.slots.len == 0) return null;

            for (0..self.slots.len) |offset| {
                const index = (self.next_channel + offset) % self.slots.len;
                const slot = &self.slots[index];
                if (slot.spsc.front()) |value| {
                    defer slot.spsc.pop();
                    self.next_channel = (index + 1) % self.slots.len;
                    return value.*;
                }
            }
            return null;
        }
    };
}

//Libxev: https://github.com/mitchellh/libxev [LIBXEV]
/// An intrusive MPSC (multi-provider, single consumer) queue implementation.
/// The type T must have a field "next" of type `?*T`.
///
/// This is an implementatin of a Vyukov Queue[1].
/// TODO(mitchellh): I haven't audited yet if I got all the atomic operations
/// correct. I was short term more focused on getting something that seemed
/// to work; I need to make sure it actually works.
///
/// For those unaware, an intrusive variant of a data structure is one in which
/// the data type in the list has the pointer to the next element, rather
/// than a higher level "node" or "container" type. The primary benefit
/// of this (and the reason we implement this) is that it defers all memory
/// management to the caller: the data structure implementation doesn't need
/// to allocate "nodes" to contain each element. Instead, the caller provides
/// the element and how its allocated is up to them.
///
/// [1]: https://www.1024cores.net/home/lock-free-algorithms/queues/intrusive-mpsc-node-based-queue
pub fn Mpsc(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Head is the front of the queue and tail is the back of the queue.
        head: *T,
        tail: *T,
        stub: T,

        /// Initialize the queue. This requires a stable pointer to itself.
        /// This must be called before the queue is used concurrently.
        pub fn init(self: *Self) void {
            self.head = &self.stub;
            self.tail = &self.stub;
            self.stub.next = null;
        }

        /// Push an item onto the queue. This can be called by any number
        /// of producers.
        pub fn push(self: *Self, v: *T) void {
            @atomicStore(?*T, &v.next, null, .unordered);
            const prev = @atomicRmw(*T, &self.head, .Xchg, v, .acq_rel);
            @atomicStore(?*T, &prev.next, v, .release);
        }

        /// Returns true if the queue is empty.
        pub fn empty(self: *Self) bool {
            const tail = @atomicLoad(*T, &self.tail, .acquire);
            const head = @atomicLoad(*T, &self.head, .acquire);
            const next = @atomicLoad(?*T, &tail.next, .acquire);
            return tail == &self.stub and head == &self.stub and next == null;
        }

        /// Pop the first in element from the queue. This must be called
        /// by only a single consumer at any given time.
        pub fn pop(self: *Self) ?*T {
            var tail = @atomicLoad(*T, &self.tail, .unordered);
            var next_ = @atomicLoad(?*T, &tail.next, .acquire);
            if (tail == &self.stub) {
                const next = next_ orelse return null;
                @atomicStore(*T, &self.tail, next, .unordered);
                tail = next;
                next_ = @atomicLoad(?*T, &tail.next, .acquire);
            }

            if (next_) |next| {
                @atomicStore(*T, &self.tail, next, .release);
                tail.next = null;
                return tail;
            }

            const head = @atomicLoad(*T, &self.head, .unordered);
            if (tail != head) return null;
            self.push(&self.stub);

            next_ = @atomicLoad(?*T, &tail.next, .acquire);
            if (next_) |next| {
                @atomicStore(*T, &self.tail, next, .unordered);
                tail.next = null;
                return tail;
            }

            return null;
        }
    };
}

test Mpsc {
    // Types
    const Elem = struct {
        const Self = @This();
        next: ?*Self = null,
    };
    const Queue = Mpsc(Elem);
    var q: Queue = undefined;
    q.init();

    // Elems
    var elems: [10]Elem = @splat(Elem{});

    // One
    try testing.expect(q.pop() == null);
    q.push(&elems[0]);
    try testing.expect(q.pop().? == &elems[0]);
    try testing.expect(q.pop() == null);

    // Two
    try testing.expect(q.pop() == null);
    q.push(&elems[0]);
    q.push(&elems[1]);
    try testing.expect(q.pop().? == &elems[0]);
    try testing.expect(q.pop().? == &elems[1]);
    try testing.expect(q.pop() == null);

    // // Interleaved
    try testing.expect(q.pop() == null);
    q.push(&elems[0]);
    try testing.expect(q.pop().? == &elems[0]);
    q.push(&elems[1]);
    try testing.expect(q.pop().? == &elems[1]);
    try testing.expect(q.pop() == null);
}

test "bounded MPSC registers producers and drains their SPSC channels" {
    const Channel = MpscBounded(u32);
    var channel = try Channel.init(2, 2, std.testing.allocator);
    defer channel.deinit(std.testing.allocator);

    var first = channel.register().?;
    defer first.unregister();
    var second = channel.register().?;
    defer second.unregister();

    try testing.expect(channel.register() == null);
    try testing.expect(first.tryPush(1));
    try testing.expect(first.tryPush(2));
    try testing.expect(!first.tryPush(3));
    try testing.expect(second.tryPush(10));

    try testing.expectEqual(@as(?u32, 1), channel.pop());
    try testing.expectEqual(@as(?u32, 10), channel.pop());
    try testing.expectEqual(@as(?u32, 2), channel.pop());
    try testing.expectEqual(@as(?u32, null), channel.pop());
}

test "bounded MPSC reuses unregistered producers without dropping values" {
    const Channel = MpscBounded(u32);
    var channel = try Channel.init(1, 2, std.testing.allocator);
    defer channel.deinit(std.testing.allocator);

    var first = channel.register().?;
    try testing.expect(first.tryPush(1));
    first.unregister();

    var second = channel.register().?;
    defer second.unregister();
    try testing.expect(second.tryPush(2));

    try testing.expectEqual(@as(?u32, 1), channel.pop());
    try testing.expectEqual(@as(?u32, 2), channel.pop());
    try testing.expectEqual(@as(?u32, null), channel.pop());
}

test "bounded MPSC supports concurrent producers" {
    const Channel = MpscBounded(u32);
    const values_per_producer = 100;
    const producer_count = 2;
    const total_values = values_per_producer * producer_count;

    const ProducerContext = struct {
        channel: *Channel,
        first_value: u32,

        fn run(context: *@This()) void {
            var producer = context.channel.register().?;
            defer producer.unregister();

            for (0..values_per_producer) |offset| {
                const value = context.first_value + @as(u32, @intCast(offset));
                while (!producer.tryPush(value)) std.Thread.yield() catch {};
            }
        }
    };

    var channel = try Channel.init(producer_count, 7, testing.allocator);
    defer channel.deinit(testing.allocator);

    var contexts: [producer_count]ProducerContext = .{
        .{ .channel = &channel, .first_value = 0 },
        .{ .channel = &channel, .first_value = values_per_producer },
    };
    var threads: [producer_count]std.Thread = undefined;
    for (&threads, &contexts) |*thread, *context| {
        thread.* = try std.Thread.spawn(.{}, ProducerContext.run, .{context});
    }

    var seen: [total_values]bool = @splat(false);
    var received: usize = 0;
    while (received < total_values) {
        if (channel.pop()) |value| {
            try testing.expect(!seen[value]);
            seen[value] = true;
            received += 1;
        } else {
            std.Thread.yield() catch {};
        }
    }

    for (threads) |thread| thread.join();
    for (seen) |was_seen| try testing.expect(was_seen);
}
