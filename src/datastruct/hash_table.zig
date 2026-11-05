const std = @import("std");
const Allocator = std.mem.Allocator;
const DoublyLinkedList = @import("doubly_linked_list.zig").DoublyLinkedList;

pub fn HashTable(
    comptime K: type,
    comptime V: type,
    comptime Context: type,
) type {
    return struct {
        slots: []DoublyLinkedList(V),
        ctx: Context,

        const Self = @This();

        pub fn init(self: *@This(), n: usize, ctx: Context, alloc: Allocator) !void {
            self.* = .{
                .slots = undefined,
                .ctx = ctx,
            };

            self.slots = try alloc.alloc(DoublyLinkedList(V), n);
            errdefer alloc.free(self.slots);

            @memset(self.slots, .empty);
        }

        pub fn get(self: *@This(), key: K) ?*V {
            const list = &self.slots[self.ctx.hash(key) % self.slots.len];
            var entry = list.first;

            while (entry) |v| : (entry = v.next) {
                if (self.ctx.eql(key, v)) {
                    return v;
                }
            }

            return null;
        }

        pub fn insert(self: *@This(), key: K, value: *V) void {
            const list = &self.slots[self.ctx.hash(key) % self.slots.len];

            list.append(value);
        }

        pub fn deinit(self: *@This(), alloc: Allocator) void {
            alloc.free(self.slots);
        }

        pub const Iterator = struct {
            table: *Self,
            bucket_index: usize = 0,
            current: ?*V = null,
            last: ?*V = null,

            pub fn next(self: *@This()) ?*V {
                self.last = null;

                while (true) {
                    if (self.current) |entry| {
                        self.current = entry.next;
                        self.last = entry;
                        return entry;
                    }

                    if (self.bucket_index >= self.table.slots.len) return null;

                    self.current = self.table.slots[self.bucket_index].first;
                    self.bucket_index += 1;
                }
            }

            pub fn remove(self: *@This()) void {
                const last = self.last orelse @panic("Double remove on hash iterator");
                self.table.slots[self.bucket_index - 1].remove(last);
                self.last = null;
            }
        };

        pub fn iterator(self: *@This()) Iterator {
            return .{ .table = self };
        }
    };
}
