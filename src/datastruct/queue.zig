const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const atomic = std.atomic;
const math = std.math;
const Io = std.Io;

pub fn Spsc(T: type) type {
    return struct {
        const Padding = (atomic.cache_line - 1) / @sizeOf(T) + 1;

        mask: u16,
        len: u16,
        slots: []T,
        producer: atomic.Value(u16) align(atomic.cache_line),
        cache_consumer: u16,

        consumer: atomic.Value(u16) align(atomic.cache_line),
        cache_producer: u16,

        pub fn init(cap: u16, allocator: Allocator) !@This() {
            assert(@sizeOf(T) > 0);

            const _capacity = try math.ceilPowerOfTwo(u16, cap);
            const mask: u16 = @intCast(_capacity - 1);

            const slots = try allocator.alloc(T, _capacity + 2 * Padding);

            return .{
                .len = _capacity,
                .mask = mask,
                .slots = slots,
                .consumer = .init(0),
                .cache_consumer = 0,
                .producer = .init(0),
                .cache_producer = 0,
            };
        }

        pub fn deinit(self: *@This(), allocator: Allocator) void {
            allocator.free(self.slots);
        }

        pub fn capacity(self: *const @This()) u16 {
            return self.len;
        }

        pub fn push(self: *@This(), value: T) void {
            const write = self.producer.load(.monotonic);
            while (write - self.cache_consumer == self.len) {
                self.cache_consumer = self.consumer.load(.acquire);
                atomic.spinLoopHint();
            }
            self.slot(write).* = value;
            self.producer.store(write +% 1, .release);
        }

        pub fn tryPush(self: *@This(), value: T) bool {
            const write = self.producer.load(.monotonic);
            if (write - self.cache_consumer == self.len) {
                self.cache_consumer = self.consumer.load(.acquire);
                if (write - self.cache_consumer == self.len) return false;
            }
            self.slot(write).* = value;
            self.producer.store(write +% 1, .release);
            return true;
        }

        pub fn front(self: *@This()) ?*T {
            const read = self.consumer.load(.monotonic);

            if (read == self.cache_producer) {
                self.cache_producer = self.producer.load(.acquire);
                if (read == self.cache_producer) return null;
            }

            return self.slot(read);
        }

        pub fn popOne(self: *@This()) void {
            const read = self.consumer.load(.monotonic);
            if (self.producer.load(.acquire) == read) unreachable;
            self.consumer.store(read +% 1, .release);
        }

        pub fn pop(self: *@This(), buffer: []T) usize {
            if (buffer.len == 0) return 0;

            const read = self.consumer.load(.monotonic);

            if (read == self.cache_producer) {
                self.cache_producer = self.producer.load(.acquire);
                if (read == self.cache_producer) return 0;
            }

            const available = self.cache_producer -% read;
            const count = @min(buffer.len, available);

            const index = read & self.mask;
            const first = @min(count, self.len - index);

            @memcpy(
                buffer[0..first],
                self.slots[Padding + index ..][0..first],
            );

            if (first < count) {
                @memcpy(
                    buffer[first..count],
                    self.slots[Padding..][0 .. count - first],
                );
            }

            self.consumer.store(read +% @as(u16, @intCast(count)), .release);
            return count;
        }

        fn slot(self: *@This(), index: u16) *T {
            return &self.slots[(index & self.mask) + Padding];
        }
    };
}

pub fn IntrusiveMpsc(comptime T: type) type {
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

test "Intrusive queue" {
    // Types
    const Elem = struct {
        const Self = @This();
        next: ?*Self = null,
    };
    const Queue = IntrusiveMpsc(Elem);
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

test "Ring buffer pads both ends of its slots allocation" {
    const Queue = Spsc(u64);
    var queue = try Queue.init(10, testing.allocator);
    defer queue.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 16), queue.capacity());
    try testing.expectEqual(@as(usize, 16 + 2 * Queue.Padding), queue.slots.len);
    try testing.expectEqual(&queue.slots[Queue.Padding], queue.slot(0));
    try testing.expectEqual(&queue.slots[Queue.Padding + 15], queue.slot(15));

    for (0..queue.len) |b| {
        queue.push(b);
    }

    try testing.expectEqual(false, queue.tryPush(11));

    for (0..queue.len) |b| {
        const expected: u64 = @intCast(b);
        try testing.expectEqual(queue.front().?.*, expected);
        queue.popOne();
    }
}
