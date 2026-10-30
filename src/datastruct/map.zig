const std = @import("std");
const Allocator = std.mem.Allocator;
const DoublyLinkedList = @import("doubly_linked_list.zig").DoublyLinkedList;

pub fn Map(
    comptime K: type,
    comptime V: type,
    comptime Context: type,
) type {
    return struct {
        table: []DoublyLinkedList(V),
        ctx: Context,

        pub fn init(self: *@This(), n: usize, ctx: Context, alloc: Allocator) !void {
            self.* = .{
                .table = undefined,
                .ctx = ctx,
            };

            self.table = try alloc.alloc(DoublyLinkedList(V), n);
            errdefer alloc.free(self.table);

            @memset(self.table, .empty);
        }

        pub fn get(self: *@This(), key: K) ?*V {
            const list = &self.table[self.ctx.hash(key) % self.table.len];
            var entry = list.first;

            while (entry) |v| : (entry = v.next) {
                if (self.ctx.eql(key, v)) {
                    return v;
                }
            }

            return null;
        }

        pub fn put(self: *@This(), key: K, value: *V) void {
            const list = &self.table[self.ctx.hash(key) % self.table.len];

            list.append(value);
        }

        pub fn deinit(self: *@This(), alloc: Allocator) void {
            alloc.free(self.table);
        }
    };
}
