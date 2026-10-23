//SOURCE: https://codeberg.org/Games-by-Mason/mr_slot_map
//License: [licenses/MR_SLOT_MAP]
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const log = std.log.scoped(.slot_map);

pub const Key = packed struct {
    pub const Generation = enum(u32) {
        invalid = 0,
        first = 1,
        _,

        pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            if (self == .invalid) {
                try writer.writeAll(".invalid");
            } else {
                try writer.print("0x{X}", .{@backingInt(self)});
            }
        }
    };
    pub const Index = u32;

    /// Similar to `Key`, but may be set to `.none`.
    pub const Optional = packed struct {
        pub const none: @This() = .{ .index = 0, .generation = .invalid };

        index: Index,
        generation: Generation,

        /// Unwraps the optional key into `Key`, or returns `null` if it is `.none`.
        pub fn unwrap(self: @This()) ?Key {
            if (self == none) return null;
            assert(self.generation != .invalid);
            return .{
                .index = self.index,
                .generation = self.generation,
            };
        }

        pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            if (self.unwrap()) |key| {
                try writer.print("{f}", .{key});
            } else {
                try writer.writeAll(".none");
            }
        }

        pub fn eql(self: @This(), other: @This()) bool {
            return self.index == other.index and self.generation == other.generation;
        }
    };

    /// The key's index. Points to the relevant data.
    index: Index,
    /// The key's generation, used to guarantee key uniqueness.
    generation: Generation,

    /// Returns this key as an optional.
    pub fn toOptional(self: @This()) Optional {
        // Invalid is only allowed on optional keys.
        assert(self.generation != .invalid);
        return .{
            .index = self.index,
            .generation = self.generation,
        };
    }

    pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        assert(self.generation != .invalid);
        try writer.print("0x{X}:{X}", .{ self.index, @backingInt(self.generation) });
    }

    pub fn eql(self: @This(), other: @This()) bool {
        return self.index == other.index and self.generation == other.generation;
    }
};

pub fn SlotMap(Value: type) type {
    return struct {
        /// A persistent `SlotMap` key.
        /// A slot in the slot map.
        pub const Slot = struct {
            generation: Key.Generation,
            value: Value,
        };

        /// The max number of values this slot map can hold simultaneously.
        capacity: usize,

        /// The number of slots with saturated generations. For most use cases, the capacity should
        /// be set high enough that this value remains 0.
        saturated: usize,

        slots: []Slot,
        next_index: usize,
        free: []Key.Index,
        free_count: usize,

        /// Initializes a slot map with the given capacity.
        pub fn init(gpa: Allocator, capacity: usize) Allocator.Error!@This() {
            assert(capacity <= std.math.maxInt(Key.Index));
            comptime assert(std.math.maxInt(Key.Index) < std.math.maxInt(usize)); // For `next_index`

            const slots = try gpa.alloc(Slot, capacity);
            errdefer gpa.free(slots);

            const free = try gpa.alloc(Key.Index, capacity);
            errdefer gpa.free(free);

            return .{
                .capacity = capacity,
                .saturated = 0,
                .slots = slots,
                .next_index = 0,
                .free = free,
                .free_count = 0,
            };
        }

        /// Destroys the slot map.
        pub fn deinit(self: *@This(), gpa: Allocator) void {
            gpa.free(self.slots);
            gpa.free(self.free);
            self.* = undefined;
        }

        /// Clears all values and recycles all keys.
        pub fn recycleAll(self: *@This()) void {
            self.* = .{
                .capacity = self.capacity,
                .saturated = 0,
                .slots = self.slots,
                .next_index = 0,
                .free = self.free,
                .free_count = 0,
            };
        }

        /// Inserts an item into the slot map, returning a persistent unique key.
        pub fn put(self: *@This(), value: Value) error{Overflow}!Key {
            const index: Key.Index = if (self.free_count > 0) b: {
                self.free_count -= 1;
                break :b self.free[self.free_count];
            } else b: {
                if (self.next_index >= self.capacity) return error.Overflow;
                const index = self.next_index;
                self.next_index += 1;
                self.slots[index].generation = .first;
                break :b @intCast(index);
            };

            self.slots[index].value = value;

            const generation = self.slots[index].generation;
            assert(generation != .invalid);
            return .{
                .index = index,
                .generation = generation,
            };
        }

        pub fn reserve(self: *@This()) error{Overflow}!Key {
            const index: Key.Index = if (self.free_count > 0) b: {
                self.free_count -= 1;
                break :b self.free[self.free_count];
            } else b: {
                if (self.next_index >= self.capacity) return error.Overflow;
                const index = self.next_index;
                self.next_index += 1;
                self.slots[index].generation = .first;
                break :b @intCast(index);
            };

            const generation = self.slots[index].generation;
            assert(generation != .invalid);
            return .{
                .index = index,
                .generation = generation,
            };
        }

        pub fn insert(self: *@This(), key: Key, value: Value) void {
            assert(self.contains(key));
            self.slots[key.index].value = value;
        }

        /// Returns true if the value associated with the given key still exists in the map,
        /// false otherwise.
        ///
        /// Asserts that the key was once valid, unless the generation is set to invalid.
        pub fn contains(self: @This(), key: Key) bool {
            // Get the current generation
            const gen = self.slots[key.index].generation;

            // Check that this key was once or is currently valid
            assert(key.generation != .invalid);
            assert(key.index < self.next_index);
            assert(gen == .invalid or @backingInt(key.generation) <= @backingInt(gen));

            // Check if the key is currently valid
            return key.generation == gen;
        }

        /// Retrieves the value associated with the given key, or `null` if it no longer exists.
        pub fn get(self: *const @This(), key: Key) ?*Value {
            if (!self.contains(key)) return null;
            return &self.slots[key.index].value;
        }

        /// Removes the value associated with the given key. The key remains valid.
        pub fn remove(self: *@This(), key: Key) ?Value {
            if (!self.contains(key)) return null;

            self.slots[key.index].generation =
                @fromBackingInt(@intCast(@backingInt(self.slots[key.index].generation) +% 1));
            if (self.slots[key.index].generation == .invalid) {
                self.saturated += 1;
            } else {
                self.free[self.free_count] = key.index;
                self.free_count += 1;
            }

            return self.slots[key.index].value;
        }

        /// Similar to `remove`, but allows the key to be reused in the future.
        pub fn recycle(self: *@This(), key: Key) void {
            if (!self.contains(key)) return;
            self.free[self.free_count] = key.index;
            self.free_count += 1;
        }

        /// Returns the number of values currently stored.
        pub fn count(self: @This()) usize {
            return self.next_index - self.free_count - self.saturated;
        }
    };
}

pub fn SecondaryMap(Value: type) type {
    return struct {
        const Slot = union(enum) {
            vacant,
            occupied: struct {
                generation: Key.Generation,
                value: Value,
            },
        };

        slots: []Slot,
        len: usize,

        pub fn init(gpa: Allocator, slot_capacity: usize) Allocator.Error!@This() {
            const slots = try gpa.alloc(Slot, slot_capacity);
            @memset(slots, .vacant);
            return .{ .slots = slots, .len = 0 };
        }

        pub fn deinit(self: *@This(), gpa: Allocator) void {
            gpa.free(self.slots);
            self.* = undefined;
        }

        pub fn count(self: @This()) usize {
            return self.len;
        }

        pub fn capacity(self: @This()) usize {
            return self.slots.len;
        }

        pub fn contains(self: @This(), key: Key) bool {
            assert(key.index < self.slots.len);
            return switch (self.slots[key.index]) {
                .vacant => false,
                .occupied => |slot| slot.generation == key.generation,
            };
        }

        pub fn put(self: *@This(), key: Key, value: Value) ?Value {
            assert(key.index < self.slots.len);

            const slot = &self.slots[key.index];
            switch (slot.*) {
                .occupied => |*occupied| {
                    if (occupied.generation == key.generation) {
                        const old = occupied.value;
                        occupied.value = value;
                        return old;
                    }
                },
                .vacant => self.len += 1,
            }

            slot.* = .{ .occupied = .{ .generation = key.generation, .value = value } };
            return null;
        }

        pub fn remove(self: *@This(), key: Key) ?Value {
            assert(key.index < self.slots.len);
            const slot = &self.slots[key.index];
            switch (slot.*) {
                .vacant => return null,
                .occupied => |occupied| {
                    if (occupied.generation != key.generation) return null;
                    slot.* = .vacant;
                    self.len -= 1;
                    return occupied.value;
                },
            }
        }

        pub fn get(self: *const @This(), key: Key) ?*const Value {
            assert(key.index < self.slots.len);
            return switch (self.slots[key.index]) {
                .vacant => null,
                .occupied => |*occupied| if (occupied.generation == key.generation) &occupied.value else null,
            };
        }

        pub fn getMut(self: *@This(), key: Key) ?*Value {
            assert(key.index < self.slots.len);
            return switch (self.slots[key.index]) {
                .vacant => null,
                .occupied => |*occupied| if (occupied.generation == key.generation) &occupied.value else null,
            };
        }

        pub fn clear(self: *@This()) void {
            @memset(self.slots, .vacant);
            self.len = 0;
        }
    };
}

test "slot map" {
    var slots: SlotMap(u8) = try .init(std.testing.allocator, 3);
    defer slots.deinit(std.testing.allocator);
    try std.testing.expectEqual(0, slots.count());

    const a = try slots.put('a');
    try std.testing.expectEqual(0, a.index);
    try std.testing.expectEqual(1, @backingInt(a.generation));
    try std.testing.expectEqual(1, slots.count());

    const b = try slots.put('b');
    try std.testing.expectEqual(1, b.index);
    try std.testing.expectEqual(1, @backingInt(b.generation));
    try std.testing.expectEqual(2, slots.count());

    const c = try slots.put('c');
    try std.testing.expectEqual(2, c.index);
    try std.testing.expectEqual(1, @backingInt(c.generation));
    try std.testing.expectEqual(3, slots.count());

    try std.testing.expectEqual('a', slots.get(a).?.*);
    try std.testing.expectEqual('b', slots.get(b).?.*);
    try std.testing.expectEqual('c', slots.get(c).?.*);

    try std.testing.expect(a == a);
    try std.testing.expect(a != b);
    try std.testing.expect(a != c);
    try std.testing.expect(b != c);
    try std.testing.expect(a.toOptional() != Key.Optional.none);
    try std.testing.expect(a.toOptional().unwrap().? == a);

    try std.testing.expectError(error.Overflow, slots.put('d'));

    try std.testing.expect(slots.contains(a));
    _ = slots.remove(a);
    try std.testing.expectEqual(2, slots.count());
    try std.testing.expect(!slots.contains(a));
    _ = slots.remove(a);
    try std.testing.expectEqual(2, slots.count());
    try std.testing.expect(!slots.contains(a));

    _ = slots.remove(c);
    try std.testing.expectEqual(1, slots.count());
    try std.testing.expect(!slots.contains(a));
    try std.testing.expect(slots.contains(b));
    try std.testing.expect(!slots.contains(c));

    try std.testing.expectEqual(null, slots.get(a));
    try std.testing.expectEqual('b', slots.get(b).?.*);
    try std.testing.expectEqual(null, slots.get(c));

    try std.testing.expect(a == a);
    try std.testing.expect(a != b);
    try std.testing.expect(a != c);
    try std.testing.expect(b != c);

    const d = try slots.put('d');
    try std.testing.expectEqual(2, d.index);
    try std.testing.expectEqual(2, @backingInt(d.generation));
    try std.testing.expectEqual(2, slots.count());

    try std.testing.expect(d != a);
    try std.testing.expect(a != b);
    try std.testing.expect(d != c);
    try std.testing.expect(d == d);

    const e = try slots.put('e');
    try std.testing.expectEqual(0, e.index);
    try std.testing.expectEqual(2, @backingInt(e.generation));
    try std.testing.expectEqual(3, slots.count());

    try std.testing.expectError(error.Overflow, slots.put('f'));

    try std.testing.expectEqual(null, slots.get(a));
    try std.testing.expectEqual('b', slots.get(b).?.*);
    try std.testing.expectEqual(null, slots.get(c));
    try std.testing.expectEqual('d', slots.get(d).?.*);
    try std.testing.expectEqual('e', slots.get(e).?.*);

    // Make sure we ignore slots whose generations wrap
    _ = slots.remove(b);
    _ = slots.remove(d);
    _ = slots.remove(e);
    try std.testing.expectEqual(0, slots.count());
    slots.slots[b.index].generation = @fromBackingInt(@intCast(std.math.maxInt(u32) - 1));
    slots.slots[d.index].generation = @fromBackingInt(@intCast(std.math.maxInt(u32) - 1));
    slots.slots[e.index].generation = @fromBackingInt(@intCast(std.math.maxInt(u32) - 1));

    try std.testing.expectEqual(0, slots.saturated);

    for (0..2) |_| {
        const e_new = try slots.put('z');
        try std.testing.expectEqual(1, slots.count());
        try std.testing.expectEqual(e.index, e_new.index);
        _ = slots.remove(e_new);
        try std.testing.expectEqual(0, slots.count());
        try std.testing.expect(!slots.contains(e_new));
    }
    try std.testing.expectEqual(1, slots.saturated);

    for (0..2) |_| {
        const d_new = try slots.put('z');
        try std.testing.expectEqual(1, slots.count());
        try std.testing.expectEqual(d.index, d_new.index);
        _ = slots.remove(d_new);
        try std.testing.expectEqual(0, slots.count());
        try std.testing.expect(!slots.contains(d_new));
    }
    try std.testing.expectEqual(2, slots.saturated);

    for (0..2) |_| {
        const b_new = try slots.put('z');
        try std.testing.expectEqual(1, slots.count());
        try std.testing.expectEqual(b.index, b_new.index);
        _ = slots.remove(b_new);
        try std.testing.expectEqual(0, slots.count());
        try std.testing.expect(!slots.contains(b_new));
    }
    try std.testing.expectEqual(3, slots.saturated);
    try std.testing.expectEqual(0, slots.count());

    try std.testing.expectError(error.Overflow, slots.put('z'));

    slots.recycleAll();
    try std.testing.expectEqual(3, slots.capacity);
    try std.testing.expectEqual(0, slots.saturated);
    try std.testing.expectEqual(0, slots.count());
}

test "recycle key" {
    var slots: SlotMap(u8) = try .init(std.testing.allocator, 3);
    defer slots.deinit(std.testing.allocator);
    try std.testing.expectEqual(0, slots.count());

    const a = try slots.put('a');
    try std.testing.expectEqual(0, a.index);
    try std.testing.expectEqual(1, @backingInt(a.generation));
    try std.testing.expectEqual(1, slots.count());

    slots.recycle(a);

    const b = try slots.put('b');
    try std.testing.expectEqual(0, b.index);
    try std.testing.expectEqual(1, @backingInt(b.generation));
    try std.testing.expectEqual(1, slots.count());

    const c = try slots.put('c');
    try std.testing.expectEqual(1, c.index);
    try std.testing.expectEqual(1, @backingInt(c.generation));
    try std.testing.expectEqual(2, slots.count());
}

test "secondary map" {
    var slots: SlotMap(u8) = try .init(std.testing.allocator, 3);
    defer slots.deinit(std.testing.allocator);

    var secondary: SecondaryMap(u32) = try .init(std.testing.allocator, slots.capacity);
    defer secondary.deinit(std.testing.allocator);

    const a = try slots.put('a');
    const b = try slots.put('b');

    try std.testing.expectEqual(0, secondary.count());
    try std.testing.expectEqual(slots.capacity, secondary.capacity());
    try std.testing.expect(!secondary.contains(a));
    try std.testing.expectEqual(null, secondary.put(a, 10));
    try std.testing.expectEqual(null, secondary.put(b, 20));
    try std.testing.expectEqual(2, secondary.count());
    try std.testing.expect(secondary.contains(a));
    try std.testing.expectEqual(10, secondary.get(a).?.*);
    try std.testing.expectEqual(20, secondary.getMut(b).?.*);

    secondary.getMut(a).?.* += 1;
    try std.testing.expectEqual(11, secondary.get(a).?.*);
    try std.testing.expectEqual(11, secondary.put(a, 12));
    try std.testing.expectEqual(2, secondary.count());

    _ = slots.remove(a);
    const c = try slots.put('c');
    try std.testing.expectEqual(a.index, c.index);
    try std.testing.expect(!secondary.contains(c));
    try std.testing.expectEqual(null, secondary.get(c));
    try std.testing.expectEqual(null, secondary.put(c, 30));
    try std.testing.expect(!secondary.contains(a));
    try std.testing.expectEqual(2, secondary.count());

    try std.testing.expectEqual(20, secondary.remove(b).?);
    try std.testing.expectEqual(null, secondary.remove(b));
    try std.testing.expectEqual(1, secondary.count());

    secondary.clear();
    try std.testing.expectEqual(0, secondary.count());
    try std.testing.expect(!secondary.contains(c));
}

// Basically just making sure it compiles
test "format key" {
    try std.testing.expectFmt("0xA:B", "{f}", .{Key{
        .index = 10,
        .generation = @fromBackingInt(@intCast(11)),
    }});
    try std.testing.expectFmt("0xA:B", "{f}", .{(Key{
        .index = 10,
        .generation = @fromBackingInt(@intCast(11)),
    }).toOptional()});
    try std.testing.expectFmt(".invalid", "{f}", .{Key.Generation.invalid});
    try std.testing.expectFmt("0xF", "{f}", .{@as(Key.Generation, @fromBackingInt(@intCast(0xf)))});
    try std.testing.expectFmt(".none", "{f}", .{Key.Optional.none});
}

test "eql" {
    const a: Key = .{ .index = 1, .generation = @fromBackingInt(@intCast(2)) };
    const b: Key = .{ .index = 2, .generation = @fromBackingInt(@intCast(2)) };
    const c: Key = .{ .index = 1, .generation = @fromBackingInt(@intCast(3)) };

    try std.testing.expect(a.eql(a));
    try std.testing.expect(!a.eql(b));
    try std.testing.expect(!a.eql(c));

    try std.testing.expect(a.toOptional().eql(a.toOptional()));
    try std.testing.expect(!a.toOptional().eql(b.toOptional()));
    try std.testing.expect(!a.toOptional().eql(c.toOptional()));
    try std.testing.expect(!a.toOptional().eql(.none));
    try std.testing.expect(!Key.Optional.none.eql(a.toOptional()));
    try std.testing.expect(Key.Optional.none.eql(.none));
}
