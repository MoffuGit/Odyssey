const std = @import("std");
const testing = std.testing;

pub fn SinglyLinkedList(T: type) type {
    return struct {
        pub const Node = T;

        pub const empty: @This() = .{
            .head = null,
            .tail = null,
        };

        head: ?*Node,
        tail: ?*Node,

        pub fn append(self: *@This(), value: *Node) void {
            if (self.tail) |tail| {
                tail.next = value;
                self.tail = value;
            } else {
                self.head = value;
                self.tail = value;
            }
        }

        pub fn prepend(self: *@This(), value: *Node) void {
            if (self.head) |head| {
                value.next = head;
                self.head = value;
            } else {
                self.head = value;
                self.tail = value;
            }
        }

        pub fn concatByMoving(self: *@This(), other: *@This()) void {
            const head = other.head orelse return;

            if (self.tail) |tail| {
                tail.next = head;
            } else {
                self.head = head;
            }

            self.tail = other.tail;
            other.head = null;
            other.tail = null;
        }

        pub fn pop(self: *@This()) ?*Node {
            const head = self.head orelse return null;

            if (self.head == self.tail) self.tail = null;
            self.head = head.next;
            head.next = null;
            return head;
        }

        pub fn is_empty(self: *const @This()) bool {
            return self.head == null;
        }
    };
}

test "append and prepend" {
    const Elem = struct {
        value: u8,
        next: ?*@This() = null,
    };

    var one: Elem = .{ .value = 1 };
    var two: Elem = .{ .value = 2 };
    var list: SinglyLinkedList(Elem) = .empty;

    list.append(&two);
    list.prepend(&one);

    try testing.expectEqual(@as(u8, 1), list.pop().?.value);
    try testing.expectEqual(@as(u8, 2), list.pop().?.value);
    try testing.expect(list.is_empty());
}

test "concatenation" {
    const Elem = struct {
        value: u8,
        next: ?*@This() = null,
    };
    const List = SinglyLinkedList(Elem);

    var one: Elem = .{ .value = 1 };
    var two: Elem = .{ .value = 2 };
    var first: List = .empty;
    var second: List = .empty;

    first.prepend(&one);
    second.prepend(&two);
    first.concatByMoving(&second);

    try testing.expect(second.is_empty());
    try testing.expectEqual(@as(u8, 1), first.pop().?.value);
    try testing.expectEqual(@as(u8, 2), first.pop().?.value);
}
