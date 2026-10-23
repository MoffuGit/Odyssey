const std = @import("std");
const testing = std.testing;

const SinglyLinkedList = @import("linked_list.zig").SinglyLinkedList;

pub fn TaggedLinkedList(comptime T: type) type {
    return struct {
        const @"union" = switch (@typeInfo(T)) {
            .@"union" => |u| u,
            else => @compileError("expected union type, found '" ++ @typeName(T) ++ "'"),
        };

        const Types = @"union".field_types;

        pub const Tag = @"union".tag_type orelse
            @compileError("TaggedLinkedList requires a tagged union");

        pub const Lists = bkl: {
            var field_types: [Types.len]type = undefined;
            var field_attrs: [Types.len]std.builtin.Type.Struct.FieldAttributes = undefined;

            for (Types, &field_types, &field_attrs) |@"type", *Type, *attr| {
                Type.* = SinglyLinkedList(struct {
                    next: ?*@This() = null,
                    value: @"type",
                });

                attr.* = .{ .@"align" = @alignOf(Type.*) };
            }

            break :bkl @Struct(.auto, null, @"union".field_names, &field_types, &field_attrs);
        };

        pub fn List(comptime tag: Tag) type {
            return @FieldType(Lists, @tagName(tag));
        }

        pub fn Node(comptime tag: Tag) type {
            return List(tag).Node;
        }

        pub const empty: @This() = bkl: {
            var lists: Lists = undefined;

            for (@"union".field_names) |name| {
                @field(lists, name) = .empty;
            }

            break :bkl .{ .lists = lists };
        };

        lists: Lists,

        pub fn get(self: *@This(), comptime tag: Tag) *List(tag) {
            return &@field(self.lists, @tagName(tag));
        }

        pub fn append(self: *@This(), comptime tag: Tag, node: *Node(tag)) void {
            self.get(tag).append(node);
        }

        pub fn prepend(self: *@This(), comptime tag: Tag, node: *Node(tag)) void {
            self.get(tag).prepend(node);
        }

        pub fn pop(self: *@This(), comptime tag: Tag) ?*Node(tag) {
            return self.get(tag).pop();
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
