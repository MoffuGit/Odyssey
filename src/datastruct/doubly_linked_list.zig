const std = @import("std");
const testing = std.testing;

pub fn DoublyLinkedList(T: type) type {
    return struct {
        pub const empty: @This() = .{ .first = null, .last = null };

        first: ?*T,
        last: ?*T,

        pub fn insertAfter(self: *@This(), existing_node: *T, new_node: *T) void {
            new_node.prev = existing_node;
            if (existing_node.next) |next_node| {
                new_node.next = next_node;
                next_node.prev = new_node;
            } else {
                self.last = new_node;
            }
            existing_node.next = new_node;
        }

        pub fn insertBefore(self: *@This(), existing_node: *T, new_node: *T) void {
            new_node.next = existing_node;
            if (existing_node.prev) |prev_node| {
                new_node.prev = prev_node;
                prev_node.next = new_node;
            } else {
                self.first = new_node;
            }
            existing_node.prev = new_node;
        }

        pub fn concatByMoving(self: *@This(), other: *@This()) void {
            const first = other.first orelse return;

            if (self.last) |last| {
                last.next = first;
                first.prev = last;
            } else {
                self.first = first;
            }

            self.last = other.last;
            other.first = null;
            other.last = null;
        }

        pub fn append(self: *@This(), value: *T) void {
            if (self.last) |last| {
                self.insertAfter(last, value);
            } else {
                self.first = value;
                self.last = value;
            }
        }

        pub fn prepend(self: *@This(), value: *T) void {
            if (self.first) |first| {
                self.insertBefore(first, value);
            } else {
                self.first = value;
                self.last = value;
            }
        }

        pub fn remove(self: *@This(), value: *T) void {
            const prev = value.prev;
            const next = value.next;

            if (prev) |prev_node| {
                prev_node.next = next;
            } else {
                self.first = next;
            }

            if (next) |next_node| {
                next_node.prev = prev;
            } else {
                self.last = prev;
            }

            value.next = null;
            value.prev = null;
        }

        pub fn pop(self: *@This()) ?*T {
            const last = self.last orelse return null;
            self.remove(last);
            return last;
        }

        pub fn popFirst(self: *@This()) ?*T {
            const first = self.first orelse return null;
            self.remove(first);
            return first;
        }

        pub fn len(self: *const @This()) usize {
            var count: usize = 0;
            var it = self.first;
            while (it) |node| : (it = node.next) count += 1;
            return count;
        }

        pub fn is_empty(self: *const @This()) bool {
            return self.first == null;
        }

        pub const Iterator = struct {
            curr: ?*T,

            pub fn next(self: *@This()) ?*T {
                const curr = self.curr orelse return null;
                self.curr = curr.next;
                return curr;
            }
        };

        pub fn iterator(self: *const @This()) Iterator {
            return .{ .curr = self.first };
        }
    };
}

test "basic operations" {
    const L = struct {
        data: u32,
        next: ?*@This() = null,
        prev: ?*@This() = null,
    };
    var list: DoublyLinkedList(L) = .empty;

    var one: L = .{ .data = 1 };
    var two: L = .{ .data = 2 };
    var three: L = .{ .data = 3 };
    var four: L = .{ .data = 4 };
    var five: L = .{ .data = 5 };

    list.append(&two); // {2}
    list.append(&five); // {2, 5}
    list.prepend(&one); // {1, 2, 5}
    list.insertBefore(&five, &four); // {1, 2, 4, 5}
    list.insertAfter(&two, &three); // {1, 2, 3, 4, 5}

    // Traverse forwards.
    {
        var it = list.first;
        var index: u32 = 1;
        while (it) |node| : (it = node.next) {
            try testing.expect(node.data == index);
            index += 1;
        }
    }

    // Traverse backwards.
    {
        var it = list.last;
        var index: u32 = 1;
        while (it) |node| : (it = node.prev) {
            try testing.expect(node.data == (6 - index));
            index += 1;
        }
    }

    _ = list.popFirst(); // {2, 3, 4, 5}
    _ = list.pop(); // {2, 3, 4}
    list.remove(&three); // {2, 4}

    try testing.expect(list.first.?.data == 2);
    try testing.expect(list.last.?.data == 4);
    try testing.expect(list.len() == 2);
    try testing.expect(one.next == null and one.prev == null);
    try testing.expect(three.next == null and three.prev == null);
    try testing.expect(five.next == null and five.prev == null);
}

test "concatenation" {
    const L = struct {
        data: u32,
        next: ?*@This() = null,
        prev: ?*@This() = null,
    };
    var list1: DoublyLinkedList(L) = .empty;
    var list2: DoublyLinkedList(L) = .empty;

    var one: L = .{ .data = 1 };
    var two: L = .{ .data = 2 };
    var three: L = .{ .data = 3 };
    var four: L = .{ .data = 4 };
    var five: L = .{ .data = 5 };

    list1.append(&one);
    list1.append(&two);
    list2.append(&three);
    list2.append(&four);
    list2.append(&five);

    list1.concatByMoving(&list2);

    try testing.expect(list1.last == &five);
    try testing.expect(list1.len() == 5);
    try testing.expect(list2.first == null);
    try testing.expect(list2.last == null);
    try testing.expect(list2.len() == 0);

    // Traverse forwards.
    {
        var it = list1.first;
        var index: u32 = 1;
        while (it) |node| : (it = node.next) {
            try testing.expect(node.data == index);
            index += 1;
        }
    }

    // Traverse backwards.
    {
        var it = list1.last;
        var index: u32 = 1;
        while (it) |node| : (it = node.prev) {
            try testing.expect(node.data == (6 - index));
            index += 1;
        }
    }

    // Swap them back, this verifies that concatenating to an empty list works.
    list2.concatByMoving(&list1);

    // Traverse forwards.
    {
        var it = list2.first;
        var index: u32 = 1;
        while (it) |node| : (it = node.next) {
            try testing.expect(node.data == index);
            index += 1;
        }
    }

    // Traverse backwards.
    {
        var it = list2.last;
        var index: u32 = 1;
        while (it) |node| : (it = node.prev) {
            try testing.expect(node.data == (6 - index));
            index += 1;
        }
    }
}
