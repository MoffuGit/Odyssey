const std = @import("std");
const testing = std.testing;

const SinglyLinkedList = @import("linked_list.zig").SinglyLinkedList;

pub fn TaggedLinkedList(comptime T: type) type {
    return struct {
        const @"union" = switch (@typeInfo(T)) {
            .@"union" => |u| u,
            else => @compileError("expected union type, found '" ++ @typeName(T) ++ "'"),
        };

        pub const Field = std.meta.FieldEnum(T);

        pub const Lists = bkl: {
            var field_types: [@"union".field_types.len]type = undefined;
            var field_attrs: [@"union".field_types.len]std.builtin.Type.Struct.FieldAttributes = undefined;

            for (0..@"union".field_names.len) |i| {
                const field: Field = @fromBackingInt(@intCast(i));

                field_types[i] = SinglyLinkedList(Node(field));
                field_attrs[i] = .{ .@"align" = @alignOf(field_types[i]) };
            }

            break :bkl @Struct(.auto, null, @"union".field_names, &field_types, &field_attrs);
        };

        pub fn List(comptime field: Field) type {
            return @FieldType(Lists, @tagName(field));
        }

        pub fn Node(comptime field: Field) type {
            return struct {
                next: ?*@This() = null,
                value: @FieldType(T, @tagName(field)),
            };
        }

        pub const empty: @This() = bkl: {
            var lists: Lists = undefined;

            for (@"union".field_names) |name| {
                @field(lists, name) = .empty;
            }

            break :bkl .{ .lists = lists };
        };

        lists: Lists,

        pub fn get(self: *@This(), comptime field: Field) *List(field) {
            return &@field(self.lists, @tagName(field));
        }

        pub fn append(self: *@This(), comptime field: Field, node: *Node(field)) void {
            self.get(field).append(node);
        }

        pub fn prepend(self: *@This(), comptime field: Field, node: *Node(field)) void {
            self.get(field).prepend(node);
        }

        pub fn pop(self: *@This(), comptime field: Field) ?*Node(field) {
            return self.get(field).pop();
        }
    };
}

test "generates linked nodes from a tagged value union" {
    const Value = union(enum) {
        number: u8,
        text: []const u8,
    };
    const Collection = TaggedLinkedList(Value);

    var collection: Collection = .empty;
    var number: Collection.Node(.number) = .{ .value = 42 };
    var text: Collection.Node(.text) = .{ .value = "hello" };

    collection.prepend(.number, &number);
    collection.prepend(.text, &text);

    const number_list = collection.get(.number);
    try testing.expect(number_list.head == &number);
    try testing.expectEqual(@as(u8, 42), collection.pop(.number).?.value);
    try testing.expectEqualStrings("hello", collection.pop(.text).?.value);
}
