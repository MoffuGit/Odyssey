const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const panic = std.debug.panic;

const BASE: usize = 6;
const CAPACITY: usize = 2 * BASE;

pub fn NodeType(comptime K: type, comptime V: type, comp: *const fn (a: K, b: K) std.math.Order) type {
    return union(enum) {
        const Node = @This();

        Internal: struct { childs: [CAPACITY]*Node = undefined, keys: [CAPACITY]K = undefined, len: u16 = 0, height: usize = 0 },
        Leaf: struct { items: [CAPACITY]V = undefined, keys: [CAPACITY]K = undefined, len: u16 = 0, next: ?*Node = null },

        pub fn add_item(self: *Node, key: K, value: V) void {
            assert(self.is_leaf());
            assert(self.Leaf.len < CAPACITY);

            const leaf = &self.*.Leaf;

            var idx: u16 = leaf.len;

            while (idx > 0) : (idx -= 1) {
                switch (comp(key, leaf.keys[idx - 1])) {
                    .gt => break,
                    .lt => {
                        leaf.keys[idx] = leaf.keys[idx - 1];
                        leaf.items[idx] = leaf.items[idx - 1];
                    },
                    .eq => return,
                }
            }

            leaf.keys[idx] = key;
            leaf.items[idx] = value;
            leaf.len += 1;
        }

        pub fn add_children(self: *Node, key: K, value: *Node) void {
            assert(!self.is_leaf());
            assert(self.Internal.len < CAPACITY);

            const internal = &self.*.Internal;

            var idx: u16 = internal.len;

            while (idx > 0) : (idx -= 1) {
                switch (comp(key, internal.keys[idx - 1])) {
                    .gt => break,
                    .lt => {
                        internal.keys[idx] = internal.keys[idx - 1];
                        internal.childs[idx] = internal.childs[idx - 1];
                    },
                    .eq => return,
                }
            }

            internal.keys[idx] = key;
            internal.childs[idx] = value;
            internal.len += 1;
        }

        pub fn remove_item(self: *Node, index: u16) struct { key: K, value: V } {
            assert(self.is_leaf());
            assert(self.Leaf.len > index);

            const leaf = &self.*.Leaf;

            const key = leaf.keys[index];
            const value = leaf.items[index];

            var i: u16 = index;
            while (i < leaf.len - 1) : (i += 1) {
                leaf.keys[i] = leaf.keys[i + 1];
                leaf.items[i] = leaf.items[i + 1];
            }

            leaf.len -= 1;

            if (leaf.len < CAPACITY) {
                leaf.keys[leaf.len] = undefined;
                leaf.items[leaf.len] = undefined;
            }

            return .{ .key = key, .value = value };
        }

        pub fn remove_children(self: *Node, index: u16) struct { key: K, child: *Node } {
            assert(!self.is_leaf());
            assert(self.Internal.len > index);

            const internal = &self.*.Internal;

            const key = internal.keys[index];
            const child = internal.childs[index];

            var i: u16 = index;
            while (i < internal.len - 1) : (i += 1) {
                internal.keys[i] = internal.keys[i + 1];
                internal.childs[i] = internal.childs[i + 1];
            }

            internal.len -= 1;

            if (internal.len < CAPACITY) {
                internal.keys[internal.len] = undefined;
                internal.childs[internal.len] = undefined;
            }

            return .{ .key = key, .child = child };
        }

        fn clone(self: *const Node, alloc: Allocator) Allocator.Error!*Node {
            var last_leaf: ?*Node = null;
            return try self.clone_recursive(alloc, &last_leaf);
        }

        fn clone_recursive(self: *const Node, alloc: Allocator, last_leaf: *?*Node) Allocator.Error!*Node {
            const new_node = try alloc.create(Node);

            switch (self.*) {
                .Leaf => |leaf| {
                    new_node.* = .{ .Leaf = .{
                        .keys = leaf.keys,
                        .items = leaf.items,
                        .len = leaf.len,
                        .next = null,
                    } };
                    if (last_leaf.*) |prev| {
                        prev.Leaf.next = new_node;
                    }
                    last_leaf.* = new_node;
                },
                .Internal => |internal| {
                    new_node.* = .{ .Internal = .{
                        .keys = internal.keys,
                        .len = 0,
                        .height = internal.height,
                        .childs = undefined,
                    } };
                    for (0..internal.len) |i| {
                        const child = internal.childs[i].clone_recursive(alloc, last_leaf) catch |err| {
                            new_node.destroy(alloc);
                            return err;
                        };
                        new_node.Internal.childs[i] = child;
                        new_node.Internal.len += 1;
                    }
                },
            }
            return new_node;
        }

        pub fn items(self: *const Node) *const [CAPACITY]V {
            assert(self.is_leaf());
            return &self.Leaf.items;
        }

        pub fn keys(self: *const Node) *const [CAPACITY]K {
            return switch (self.*) {
                .Internal => &self.Internal.keys,
                .Leaf => &self.Leaf.keys,
            };
        }

        pub fn is_empty(self: Node) bool {
            switch (self) {
                .Internal => return false,
                .Leaf => |leaf| {
                    return leaf.len == 0;
                },
            }
        }

        pub fn len(self: Node) u16 {
            switch (self) {
                .Internal => |int| return int.len,
                .Leaf => |leaf| return leaf.len,
            }
        }

        pub fn is_leaf(self: Node) bool {
            switch (self) {
                .Internal => return false,
                .Leaf => return true,
            }
        }

        pub fn height(self: Node) usize {
            switch (self) {
                .Internal => |internal| return internal.height,
                .Leaf => return 0,
            }
        }

        pub fn is_underflowing(self: Node) bool {
            return self.len() < BASE;
        }

        pub fn childs(self: *const Node) *const [CAPACITY]*Node {
            assert(!self.is_leaf());
            return &self.Internal.childs;
        }

        pub fn destroy(self: *Node, alloc: Allocator) void {
            switch (self.*) {
                .Internal => |*internal| {
                    if (internal.len > 0) {
                        for (0..internal.len) |idx| {
                            internal.childs[idx].destroy(alloc);
                        }
                    }
                },
                else => {},
            }
            alloc.destroy(self);
        }

        pub fn append(self: *Node, other: Node, alloc: Allocator) !?V {
            if (self.is_empty()) {
                self.* = other;
            } else if (!other.is_leaf() or other.items().len != 0) {
                if (self.height() < other.height()) {
                    for (other.childs()) |node| {
                        return try self.append(node.*, alloc);
                    }
                } else if (try self.append_recursive(other, alloc)) |res| {
                    switch (res) {
                        .append => |right| {
                            const left = try alloc.create(Node);
                            left.* = self.*;
                            self.* = try Node.from_child_nodes(left, right);
                        },
                        .duplicated => |old| return old,
                    }
                }
            }

            return null;
        }

        pub fn from_child_nodes(left: *Node, right: *Node) !Node {
            var childrens: [CAPACITY]*Node = undefined;
            childrens[0] = left;
            childrens[1] = right;

            var _keys: [CAPACITY]K = undefined;
            _keys[0] = left.keys()[0];
            _keys[1] = right.keys()[0];

            return .{ .Internal = .{ .height = left.height() + 1, .len = 2, .childs = childrens, .keys = _keys } };
        }

        const Result = union(enum) {
            duplicated: V,
            append: *Node,
        };

        pub fn append_recursive(self: *Node, other: Node, alloc: Allocator) !?Result {
            switch (self.*) {
                .Internal => |*internal| {
                    const height_delta = internal.height - other.height();

                    var keys_to_append: [CAPACITY]K = undefined;
                    var childs_to_append: [CAPACITY]*Node = undefined;
                    var len_to_append: u16 = 0;

                    if (height_delta == 0) {
                        @memcpy(&keys_to_append, other.keys());
                        @memcpy(&childs_to_append, other.childs());
                        len_to_append = other.len();
                    } else if (height_delta == 1 and !other.is_underflowing()) {
                        keys_to_append[0] = other.keys()[0];
                        const new_other_node = try alloc.create(Node);
                        new_other_node.* = other;
                        childs_to_append[0] = new_other_node;
                        len_to_append = 1;
                    } else {
                        var idx: u16 = 1;

                        while (idx < internal.len) {
                            switch (comp(other.keys()[0], internal.keys[idx])) {
                                .eq => {
                                    idx += 1;
                                },
                                .gt => {
                                    idx += 1;
                                },
                                .lt => {
                                    break;
                                },
                            }
                        }

                        const node_to_append = bkl: {
                            const res = try internal.childs[idx - 1].append_recursive(other, alloc);
                            if (res == null) break :bkl null;
                            switch (res.?) {
                                .duplicated => |v| return Result{ .duplicated = v },
                                .append => |node| break :bkl node,
                            }
                        };

                        internal.keys[idx - 1] = internal.childs[idx - 1].keys()[0];

                        if (node_to_append) |split| {
                            keys_to_append[0] = split.keys()[0];
                            childs_to_append[0] = split;
                            len_to_append = 1;
                        }
                    }

                    const childs_len = internal.len + len_to_append;
                    if (childs_len > CAPACITY) {
                        var temp_keys: [CAPACITY * 2]K = undefined;
                        var temp_items: [CAPACITY * 2]*Node = undefined;

                        var idx: usize = 0;
                        var other_idx: usize = 0;
                        var temp: usize = 0;

                        while (idx < internal.len and other_idx < len_to_append) {
                            switch (comp(internal.keys[idx], keys_to_append[other_idx])) {
                                .eq => {
                                    @panic("There should not be any internal duplicated keys");
                                },
                                .lt => {
                                    temp_keys[temp] = internal.keys[idx];
                                    temp_items[temp] = internal.childs[idx];
                                    idx += 1;
                                },
                                .gt => {
                                    temp_keys[temp] = keys_to_append[other_idx];
                                    temp_items[temp] = childs_to_append[other_idx];
                                    other_idx += 1;
                                },
                            }
                            temp += 1;
                        }

                        while (idx < internal.len) {
                            temp_keys[temp] = internal.keys[idx];
                            temp_items[temp] = internal.childs[idx];
                            idx += 1;
                            temp += 1;
                        }

                        while (other_idx < len_to_append) {
                            temp_keys[temp] = keys_to_append[other_idx];
                            temp_items[temp] = childs_to_append[other_idx];
                            other_idx += 1;
                            temp += 1;
                        }

                        var left_keys: [CAPACITY]K = undefined;
                        var left_items: [CAPACITY]*Node = undefined;

                        var right_keys: [CAPACITY]K = undefined;
                        var right_items: [CAPACITY]*Node = undefined;

                        const mid = (childs_len + childs_len % 2) / 2;

                        @memcpy(left_keys[0..mid], temp_keys[0..mid]);
                        @memcpy(left_items[0..mid], temp_items[0..mid]);

                        @memcpy(right_keys[0 .. childs_len - mid], temp_keys[mid..childs_len]);
                        @memcpy(right_items[0 .. childs_len - mid], temp_items[mid..childs_len]);

                        internal.childs = left_items;
                        internal.keys = left_keys;
                        internal.len = mid;

                        const right_node = try alloc.create(Node);
                        right_node.* = .{ .Internal = .{ .childs = right_items, .keys = right_keys, .len = childs_len - mid, .height = internal.height } };
                        return Result{ .append = right_node };
                    } else {
                        var target: usize = childs_len;
                        var idx: usize = internal.len;
                        var append_idx: usize = len_to_append;

                        while (target > 0) {
                            target -= 1;

                            if (append_idx > 0 and (idx == 0 or comp(keys_to_append[append_idx - 1], internal.keys[idx - 1]) == .gt)) {
                                append_idx -= 1;
                                internal.keys[target] = keys_to_append[append_idx];
                                internal.childs[target] = childs_to_append[append_idx];
                            } else {
                                idx -= 1;
                                internal.keys[target] = internal.keys[idx];
                                internal.childs[target] = internal.childs[idx];
                            }
                        }

                        internal.len = childs_len;
                    }
                },
                .Leaf => |*leaf| {
                    assert(other.is_leaf());

                    const other_leaf = other.Leaf;
                    const new_len = leaf.len + other_leaf.len;

                    const overflow = new_len > CAPACITY;

                    var temp_keys: [CAPACITY * 2]K = undefined;
                    var temp_items: [CAPACITY * 2]V = undefined;

                    var idx: usize = 0;
                    var other_idx: usize = 0;
                    var temp: usize = 0;

                    while (idx < leaf.len and other_idx < other_leaf.len) {
                        switch (comp(leaf.keys[idx], other_leaf.keys[other_idx])) {
                            .lt => {
                                temp_keys[temp] = leaf.keys[idx];
                                temp_items[temp] = leaf.items[idx];
                                idx += 1;
                            },
                            .gt => {
                                temp_keys[temp] = other_leaf.keys[other_idx];
                                temp_items[temp] = other_leaf.items[other_idx];
                                other_idx += 1;
                            },
                            .eq => {
                                const old = leaf.items[idx];
                                leaf.items[idx] = other_leaf.items[other_idx];
                                return Result{ .duplicated = old };
                            },
                        }
                        temp += 1;
                    }

                    while (idx < leaf.len) {
                        temp_keys[temp] = leaf.keys[idx];
                        temp_items[temp] = leaf.items[idx];
                        idx += 1;
                        temp += 1;
                    }

                    while (other_idx < other_leaf.len) {
                        temp_keys[temp] = other_leaf.keys[other_idx];
                        temp_items[temp] = other_leaf.items[other_idx];
                        other_idx += 1;
                        temp += 1;
                    }

                    if (overflow) {
                        var left_keys: [CAPACITY]K = undefined;
                        var left_items: [CAPACITY]V = undefined;

                        var right_keys: [CAPACITY]K = undefined;
                        var right_items: [CAPACITY]V = undefined;

                        const mid = (new_len + new_len % 2) / 2;

                        @memcpy(left_keys[0..mid], temp_keys[0..mid]);
                        @memcpy(left_items[0..mid], temp_items[0..mid]);

                        @memcpy(right_keys[0 .. new_len - mid], temp_keys[mid..new_len]);
                        @memcpy(right_items[0 .. new_len - mid], temp_items[mid..new_len]);

                        const original_next_leaf = leaf.next;

                        leaf.items = left_items;
                        leaf.keys = left_keys;
                        leaf.len = mid;

                        const right_node = try alloc.create(Node);
                        right_node.* = .{ .Leaf = .{ .items = right_items, .keys = right_keys, .len = new_len - mid, .next = original_next_leaf } };

                        leaf.next = right_node;

                        return Result{ .append = right_node };
                    } else {
                        @memcpy(leaf.keys[0..new_len], temp_keys[0..new_len]);
                        @memcpy(leaf.items[0..new_len], temp_items[0..new_len]);
                        leaf.len = new_len;
                    }
                },
            }

            return null;
        }

        pub fn find(self: *Node, key: K) ?V {
            switch (self.*) {
                .Leaf => |*leaf| {
                    var i: u16 = 0;
                    while (i < leaf.len) {
                        switch (comp(key, leaf.keys[i])) {
                            .eq => return leaf.items[i],
                            .lt => break,
                            .gt => i += 1,
                        }
                    }
                    return null;
                },
                .Internal => |*internal| {
                    var idx: u16 = 1;

                    while (idx < internal.len) {
                        switch (comp(key, internal.keys[idx])) {
                            .eq => {
                                idx += 1;
                                break;
                            },
                            .gt => {
                                idx += 1;
                            },
                            .lt => {
                                break;
                            },
                        }
                    }

                    return internal.childs[idx - 1].find(key);
                },
            }
        }

        pub fn find_mut(self: *Node, key: K) ?*V {
            switch (self.*) {
                .Leaf => |*leaf| {
                    var i: u16 = 0;
                    while (i < leaf.len) {
                        switch (comp(key, leaf.keys[i])) {
                            .eq => return &leaf.items[i],
                            .lt => break,
                            .gt => i += 1,
                        }
                    }
                    return null;
                },
                .Internal => |*internal| {
                    var idx: u16 = 1;

                    while (idx < internal.len) {
                        switch (comp(key, internal.keys[idx])) {
                            .eq => {
                                idx += 1;
                                break;
                            },
                            .gt => {
                                idx += 1;
                            },
                            .lt => {
                                break;
                            },
                        }
                    }

                    return internal.childs[idx - 1].find_mut(key);
                },
            }
        }

        pub fn delete(self: *Node, key: K, alloc: Allocator) ?V {
            switch (self.*) {
                .Leaf => |*leaf| {
                    var i: u16 = 0;
                    while (i < leaf.len) {
                        switch (comp(key, leaf.keys[i])) {
                            .eq => {
                                const removed_value = leaf.items[i];

                                var j: u16 = i;
                                while (j < leaf.len - 1) {
                                    leaf.keys[j] = leaf.keys[j + 1];
                                    leaf.items[j] = leaf.items[j + 1];
                                    j += 1;
                                }
                                leaf.len -= 1;
                                return removed_value;
                            },
                            .lt => return null,
                            .gt => i += 1,
                        }
                    }

                    return null;
                },
                .Internal => |*internal| {
                    var idx: u16 = 1;
                    while (idx < internal.len) {
                        switch (comp(key, internal.keys[idx])) {
                            .eq => {
                                idx += 1;
                                break;
                            },
                            .gt => {
                                idx += 1;
                            },
                            .lt => {
                                break;
                            },
                        }
                    }

                    idx -= 1;

                    const removed = internal.childs[idx].delete(key, alloc);

                    internal.keys[idx] = internal.childs[idx].keys()[0];

                    if (internal.childs[idx].is_underflowing()) {
                        self.rebalance_child(idx, alloc);
                    }

                    return removed;
                },
            }
        }

        fn rebalance_child(self: *Node, idx: u16, alloc: Allocator) void {
            const parent = &self.Internal;
            const child = parent.childs[idx];

            switch (child.*) {
                .Internal => {
                    if (idx > 0) {
                        const sibling = parent.childs[idx - 1];
                        if (sibling.len() > BASE) {
                            const borrow = sibling.remove_children(sibling.len() - 1);
                            child.add_children(borrow.key, borrow.child);

                            parent.keys[idx] = borrow.key;

                            return;
                        }
                    }
                    if (idx < parent.len - 1) {
                        const sibling = parent.childs[idx + 1];
                        if (sibling.len() > BASE) {
                            const borrow = sibling.remove_children(0);
                            child.add_children(borrow.key, borrow.child);

                            parent.keys[idx + 1] = sibling.keys()[0];

                            return;
                        }
                    }
                },
                .Leaf => {
                    if (idx > 0) {
                        const sibling = parent.childs[idx - 1];
                        if (sibling.len() > BASE) {
                            const borrow = sibling.remove_item(sibling.len() - 1);
                            child.add_item(borrow.key, borrow.value);

                            parent.keys[idx] = borrow.key;

                            return;
                        }
                    }
                    if (idx < parent.len - 1) {
                        const sibling = parent.childs[idx + 1];
                        if (sibling.len() > BASE) {
                            const borrow = sibling.remove_item(0);
                            child.add_item(borrow.key, borrow.value);

                            parent.keys[idx + 1] = sibling.keys()[0];

                            return;
                        }
                    }
                },
            }

            if (idx > 0) {
                const sibling = parent.childs[idx - 1];

                _ = self.remove_children(idx);
                _ = sibling.append_recursive(child.*, alloc) catch {};

                alloc.destroy(child);

                parent.keys[idx - 1] = sibling.keys()[0];
            }

            if (idx < parent.len - 1) {
                const sibling = parent.childs[idx + 1];

                _ = self.remove_children(idx + 1);
                _ = child.append_recursive(sibling.*, alloc) catch {};

                alloc.destroy(sibling);

                parent.keys[idx] = child.keys()[0];
            }
        }
    };
}

pub fn BPlusTree(comptime K: type, comptime V: type, comptime comp: *const fn (a: K, b: K) std.math.Order) type {
    return struct {
        pub const Key = K;
        pub const Value = V;
        const Node = NodeType(K, V, comp);

        pub const NODE_SIZE = @sizeOf(Node);
        pub const NODE_ALIGN = @alignOf(Node);

        root: *Node,
        count: usize = 0,

        pub fn init(self: *@This(), alloc: Allocator) !void {
            const root = try alloc.create(Node);
            root.* = .{ .Leaf = .{} };

            self.* = .{ .root = root };
        }

        pub fn deinit(self: *@This(), alloc: Allocator) void {
            self.root.destroy(alloc);
        }

        pub fn clone(self: *const @This(), alloc: Allocator) !@This() {
            const root = try self.root.clone(alloc);
            return .{ .root = root, .count = self.count };
        }

        pub fn insert(self: *@This(), alloc: Allocator, key: K, value: V) !?V {
            var node: Node = Node{ .Leaf = .{} };

            node.add_item(key, value);

            if (try self.root.append(node, alloc)) |old| {
                return old;
            }

            self.count += 1;
            return null;
        }

        pub fn get(self: *@This(), key: K) ?V {
            return self.root.find(key);
        }

        pub fn clear(self: *@This(), alloc: Allocator) void {
            self.root.destroy(alloc);

            const root = alloc.create(Node) catch @panic("Temporal btree clear panic");
            root.* = .{ .Leaf = .{} };
            self.root = root;
            self.count = 0;
        }

        pub fn get_mut(self: *@This(), key: K) ?*V {
            return self.root.find_mut(key);
        }

        pub fn remove(self: *@This(), alloc: Allocator, key: K) ?V {
            const removed = self.root.delete(key, alloc) orelse return null;

            if (!self.root.is_leaf() and self.root.len() == 1) {
                const old_root = self.root;
                self.root = old_root.Internal.childs[0];
                alloc.destroy(old_root);
            }

            self.count -= 1;
            return removed;
        }

        pub fn is_empty(self: *@This()) bool {
            return self.count == 0;
        }

        pub fn first(self: *@This()) ?V {
            var current: ?*Node = self.root;
            while (current) |node| {
                switch (node.*) {
                    .Internal => |*internal| {
                        if (internal.len == 0) {
                            current = null;
                            break;
                        }
                        current = internal.childs[0];
                    },
                    .Leaf => {
                        if (node.Leaf.len == 0) return null;
                        return node.Leaf.items[0];
                    },
                }
            }
            return null;
        }

        pub fn itereator(self: *const @This()) Iterator {
            return Iterator.init(self);
        }

        /// Create a range iterator over [start, end] (both inclusive)
        pub fn range(self: *@This(), start: K, end: K) RangeIterator {
            return RangeIterator.init(self, .{ .inclusive = start }, .{ .inclusive = end });
        }

        /// Create a range iterator from start (inclusive) to end of tree
        pub fn rangeFrom(self: *@This(), start: K) RangeIterator {
            return RangeIterator.init(self, .{ .inclusive = start }, .unbounded);
        }

        /// Create a range iterator from start of tree to end (inclusive)
        pub fn rangeTo(self: *@This(), end: K) RangeIterator {
            return RangeIterator.init(self, .unbounded, .{ .inclusive = end });
        }

        /// Create a range iterator with custom bounds
        pub fn rangeWithBounds(self: *@This(), start_bound: Bound, end_bound: Bound) RangeIterator {
            return RangeIterator.init(self, start_bound, end_bound);
        }

        pub fn print(self: *const @This(), alloc: Allocator) !void {
            var queue = try std.ArrayList(*Node).initCapacity(alloc, 0);
            defer queue.deinit(alloc);

            if (self.root.len() == 0) {
                std.debug.print("Tree is empty.\n", .{});
                return;
            }

            try queue.append(alloc, self.root);

            while (queue.items.len > 0) {
                var next_queue = try std.ArrayList(*Node).initCapacity(alloc, 0);
                defer next_queue.deinit(alloc);

                while (queue.items.len > 0) {
                    const node = queue.orderedRemove(0);
                    if (!node.is_leaf()) {
                        const internal = node.Internal;
                        std.debug.print("{s}", .{"{ "});
                        for (0..internal.len) |i| {
                            std.debug.print("{}", .{internal.keys[i]});
                            if (i < internal.len - 1) {
                                std.debug.print(", ", .{});
                            }
                            try next_queue.append(alloc, internal.childs[i]);
                        }
                        std.debug.print("{s}", .{" } "});
                    } else {
                        const leaf = node.Leaf;
                        std.debug.print("{s}", .{"{ "});
                        for (0..leaf.len) |i| {
                            std.debug.print("{{ {any}, {any} }}", .{ leaf.keys[i], leaf.items[i] });
                            if (i < leaf.len - 1) {
                                std.debug.print(", ", .{});
                            }
                        }
                        std.debug.print("{s}", .{" } "});
                        std.debug.print("\n", .{});
                    }
                }
                std.debug.print("\n", .{});

                queue.clearRetainingCapacity();
                for (next_queue.items) |node| {
                    try queue.append(alloc, node);
                }
            }
        }

        const Self = @This();

        pub const Iterator = struct {
            leaf: ?*Node,
            index: usize,

            pub fn init(tree: *const Self) Iterator {
                var current: ?*Node = tree.root;
                while (current) |node| {
                    switch (node.*) {
                        .Internal => |*internal| {
                            if (internal.len == 0) {
                                current = null;
                                break;
                            }
                            current = internal.childs[0];
                        },
                        .Leaf => {
                            return .{ .leaf = current, .index = 0 };
                        },
                    }
                }
                return .{ .leaf = null, .index = 0 };
            }

            pub fn next(self: *Iterator) ?struct { key: K, value: V } {
                while (self.leaf) |node| {
                    if (node.is_leaf()) {
                        const leaf = node.Leaf;
                        if (self.index < leaf.len) {
                            self.index += 1;
                            return .{ .key = leaf.keys[self.index - 1], .value = leaf.items[self.index - 1] };
                        } else {
                            self.leaf = leaf.next;
                            self.index = 0;
                        }
                    } else {
                        unreachable;
                    }
                }
                return null;
            }

            pub fn next_mut(self: *Iterator) ?struct { key: K, value: *V } {
                while (self.leaf) |node| {
                    if (node.is_leaf()) {
                        const leaf = &node.Leaf;
                        if (self.index < leaf.len) {
                            self.index += 1;
                            return .{ .key = leaf.keys[self.index - 1], .value = &leaf.items[self.index - 1] };
                        } else {
                            self.leaf = leaf.next;
                            self.index = 0;
                        }
                    } else {
                        unreachable;
                    }
                }
                return null;
            }
        };

        /// Bound type for range queries
        pub const Bound = union(enum) {
            /// No bound (unbounded)
            unbounded,
            /// Inclusive bound (includes the key)
            inclusive: K,
            /// Exclusive bound (excludes the key)
            exclusive: K,
        };

        /// Iterator over a range of keys in the B+ tree
        pub const RangeIterator = struct {
            leaf: ?*Node,
            index: usize,
            end_bound: Bound,

            /// Initialize a range iterator starting from a specific bound
            pub fn init(tree: *const Self, start_bound: Bound, end_bound: Bound) RangeIterator {
                const start_leaf = switch (start_bound) {
                    .unbounded => findLeftmostLeaf(tree.root),
                    .inclusive => |key| findLeafForKey(tree.root, key),
                    .exclusive => |key| findLeafForKey(tree.root, key),
                };

                if (start_leaf == null) {
                    return .{ .leaf = null, .index = 0, .end_bound = end_bound };
                }

                const leaf = start_leaf.?;
                const start_index: usize = switch (start_bound) {
                    .unbounded => 0,
                    .inclusive => |key| findIndexInLeaf(leaf, key, true),
                    .exclusive => |key| findIndexInLeaf(leaf, key, false),
                };

                return .{
                    .leaf = leaf,
                    .index = start_index,
                    .end_bound = end_bound,
                };
            }

            fn findLeftmostLeaf(node: *Node) ?*Node {
                var current: ?*Node = node;
                while (current) |n| {
                    switch (n.*) {
                        .Internal => |*internal| {
                            if (internal.len == 0) return null;
                            current = internal.childs[0];
                        },
                        .Leaf => return current,
                    }
                }
                return null;
            }

            fn findLeafForKey(node: *Node, key: K) ?*Node {
                var current: *Node = node;
                while (true) {
                    switch (current.*) {
                        .Internal => |*internal| {
                            if (internal.len == 0) return null;
                            var idx: u16 = 1;
                            while (idx < internal.len) {
                                switch (comp(key, internal.keys[idx])) {
                                    .lt => break,
                                    .eq, .gt => idx += 1,
                                }
                            }
                            current = internal.childs[idx - 1];
                        },
                        .Leaf => return current,
                    }
                }
            }

            fn findIndexInLeaf(node: *Node, key: K, inclusive: bool) usize {
                const leaf = node.Leaf;
                var i: usize = 0;
                while (i < leaf.len) {
                    switch (comp(key, leaf.keys[i])) {
                        .lt => return i,
                        .eq => return if (inclusive) i else i + 1,
                        .gt => i += 1,
                    }
                }
                return i;
            }

            fn isAtOrPastEnd(self: *RangeIterator, key: K) bool {
                return switch (self.end_bound) {
                    .unbounded => false,
                    .inclusive => |end_key| comp(key, end_key) == .gt,
                    .exclusive => |end_key| comp(key, end_key) != .lt,
                };
            }

            pub fn next(self: *RangeIterator) ?struct { key: K, value: V } {
                while (self.leaf) |node| {
                    if (node.is_leaf()) {
                        const leaf = node.Leaf;
                        if (self.index < leaf.len) {
                            const key = leaf.keys[self.index];
                            // Check if we've passed the end bound
                            if (self.isAtOrPastEnd(key)) {
                                self.leaf = null;
                                return null;
                            }
                            self.index += 1;
                            return .{ .key = key, .value = leaf.items[self.index - 1] };
                        } else {
                            self.leaf = leaf.next;
                            self.index = 0;
                        }
                    } else {
                        unreachable;
                    }
                }
                return null;
            }
        };
    };
}

pub fn BPlusSet(comptime K: type, comptime comp: *const fn (a: K, b: K) std.math.Order) type {
    return struct {
        const Self = @This();
        const Tree = BPlusTree(K, void, comp);
        pub const NODE_SIZE = Tree.NODE_SIZE;
        pub const NODE_ALIGN = Tree.NODE_ALIGN;

        tree: Tree,

        pub const Bound = Tree.Bound;

        pub const Iterator = struct {
            inner: Tree.Iterator,

            pub fn next(self: *Iterator) ?K {
                const item = self.inner.next() orelse return null;
                return item.key;
            }
        };

        pub const RangeIterator = struct {
            inner: Tree.RangeIterator,

            pub fn next(self: *RangeIterator) ?K {
                const item = self.inner.next() orelse return null;
                return item.key;
            }
        };

        pub fn init(self: *Self, alloc: Allocator) !void {
            try self.tree.init(alloc);
        }

        pub fn deinit(self: *Self, alloc: Allocator) void {
            self.tree.deinit(alloc);
        }

        pub fn clone(self: *const Self, alloc: Allocator) !Self {
            return .{ .tree = try self.tree.clone(alloc) };
        }

        pub fn insert(self: *Self, alloc: Allocator, key: K) !bool {
            return try self.tree.insert(alloc, key, {}) == null;
        }

        pub fn contains(self: *Self, key: K) bool {
            return self.tree.get(key) != null;
        }

        pub fn remove(self: *Self, alloc: Allocator, key: K) bool {
            return self.tree.remove(alloc, key) != null;
        }

        pub fn clear(self: *Self, alloc: Allocator) void {
            self.tree.clear(alloc);
        }

        pub fn count(self: *const Self) usize {
            return self.tree.count;
        }

        pub fn iter(self: *Self) Iterator {
            return .{ .inner = self.tree.itereator() };
        }

        pub fn range(self: *Self, start: K, end: K) RangeIterator {
            return .{ .inner = self.tree.range(start, end) };
        }

        pub fn rangeFrom(self: *Self, start: K) RangeIterator {
            return .{ .inner = self.tree.rangeFrom(start) };
        }

        pub fn rangeTo(self: *Self, end: K) RangeIterator {
            return .{ .inner = self.tree.rangeTo(end) };
        }

        pub fn rangeWithBounds(self: *Self, start_bound: Bound, end_bound: Bound) RangeIterator {
            return .{ .inner = self.tree.rangeWithBounds(start_bound, end_bound) };
        }

        pub fn print(self: *const Self, alloc: Allocator) !void {
            try self.tree.print(alloc);
        }
    };
}

fn test_comp(a: usize, b: usize) std.math.Order {
    return std.math.order(a, b);
}

test "B+ Tree push operation and splitting" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const T = BPlusTree(usize, usize, test_comp);
    var tree: T = undefined;
    try tree.init(alloc);
    defer tree.deinit(alloc);

    try testing.expectEqual(null, try tree.insert(alloc, 0, 1));

    try testing.expect(!tree.root.is_empty());
    try testing.expect(tree.root.is_leaf());

    for (1..13) |key| {
        try testing.expectEqual(null, try tree.insert(alloc, key, key + 1));
    }

    try testing.expect(!tree.root.is_leaf());

    try testing.expectEqual(12, tree.get(11));

    for (13..20) |key| {
        _ = try tree.insert(alloc, key, key + 1);
    }

    try testing.expectEqual(tree.root.len(), 3);
    try testing.expectEqual(12, tree.get(11));

    for (20..90) |key| {
        _ = try tree.insert(alloc, key, key + 1);
    }

    try testing.expectEqual(tree.root.height(), 2);
}

test "B+ Tree get operation" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const T = BPlusTree(usize, usize, test_comp);
    var tree: T = undefined;
    try tree.init(alloc);
    defer tree.deinit(alloc);

    for (0..90) |key| {
        _ = try tree.insert(alloc, key, key + 1);
    }

    for (0..90) |key| {
        try testing.expectEqual(key + 1, tree.get(key));
    }
}

test "B+ Tree get ref operation" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const T = BPlusTree(usize, usize, test_comp);
    var tree: T = undefined;
    try tree.init(alloc);
    defer tree.deinit(alloc);

    for (0..90) |key| {
        _ = try tree.insert(alloc, key, key + 1);
    }

    for (0..90) |key| {
        const value = tree.get_mut(key).?;
        value.* = key * 4;
        try testing.expectEqual(key * 4, tree.get(key));
    }
}

test "B+ Tree leaf traversal" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const T = BPlusTree(usize, usize, test_comp);
    var tree: T = undefined;
    try tree.init(alloc);
    defer tree.deinit(alloc);

    for (0..20) |key| {
        _ = try tree.insert(alloc, key, key + 100);
    }

    var iter = tree.itereator();
    var expected_key: usize = 0;
    while (iter.next()) |n| {
        try testing.expectEqual(expected_key, n.key);
        try testing.expectEqual(expected_key + 100, n.value);
        expected_key += 1;
    }
    try testing.expectEqual(20, expected_key);
}

test "B+ Tree insert a duplicate key" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const T = BPlusTree(usize, usize, test_comp);
    var tree: T = undefined;
    try tree.init(alloc);
    defer tree.deinit(alloc);

    _ = try tree.insert(alloc, 0, 1);
    try testing.expectEqual(tree.insert(alloc, 0, 2), 1);

    try testing.expectEqual(2, tree.get(0));

    for (1..90) |key| {
        _ = try tree.insert(alloc, key, key + 1);
    }

    for (20..30) |key| {
        const expected = tree.get(key);
        try testing.expectEqual(tree.insert(alloc, key, 2), expected);
        try testing.expectEqual(tree.get(key), 2);
    }
}

test "B+ Tree insert a duplicate key 2" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const T = BPlusTree(usize, usize, test_comp);
    var tree: T = undefined;
    try tree.init(alloc);
    defer tree.deinit(alloc);

    _ = try tree.insert(alloc, 0, 1);
    try testing.expectEqual(tree.insert(alloc, 0, 2), 1);

    try testing.expectEqual(2, tree.get(0));

    for (1..200) |key| {
        _ = try tree.insert(alloc, key, key + 1);
    }

    for (20..180) |key| {
        const expected = tree.get(key);
        try testing.expectEqual(tree.insert(alloc, key, 2), expected);
        try testing.expectEqual(tree.get(key), 2);
    }
}

test "B+ Tree basic deletion" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const T = BPlusTree(usize, usize, test_comp);
    var tree: T = undefined;
    try tree.init(alloc);
    defer tree.deinit(alloc);

    for (0..BASE) |key| {
        _ = try tree.insert(alloc, key, key + 100);
    }
    try testing.expect(tree.root.is_leaf());
    try testing.expectEqual(BASE, tree.root.len());

    const removed_val = tree.remove(alloc, 3);
    try testing.expectEqual(3 + 100, removed_val);
    try testing.expectEqual(null, tree.get(3));
    try testing.expectEqual(BASE - 1, tree.root.len());
    try testing.expectEqual(0 + 100, tree.get(0));
    try testing.expectEqual(5 + 100, tree.get(5));

    _ = tree.remove(alloc, 0);
    try testing.expectEqual(null, tree.get(0));
    try testing.expectEqual(BASE - 2, tree.root.len());
    try testing.expectEqual(1 + 100, tree.get(1));

    _ = tree.remove(alloc, 5);
    try testing.expectEqual(null, tree.get(5));
    try testing.expectEqual(BASE - 3, tree.root.len());
    try testing.expectEqual(4 + 100, tree.get(4));
}

test "B+ Tree delete - non-existent key" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const T = BPlusTree(usize, usize, test_comp);
    var tree: T = undefined;
    try tree.init(alloc);
    defer tree.deinit(alloc);

    for (0..10) |key| {
        _ = try tree.insert(alloc, key, key + 100);
    }

    try testing.expectEqual(null, tree.remove(alloc, 99));
    try testing.expectEqual(null, tree.remove(alloc, 10));

    try testing.expectEqual(10, tree.root.len());
    try testing.expectEqual(5 + 100, tree.get(5));
}

test "B+ Tree delete - underflow and borrow from left sibling (leaf)" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const T = BPlusTree(usize, usize, test_comp);
    var tree: T = undefined;
    try tree.init(alloc);
    defer tree.deinit(alloc);

    for (0..CAPACITY + 1) |key| {
        _ = try tree.insert(alloc, key, key + 100);
    }

    try testing.expect(!tree.root.is_leaf());
    try testing.expectEqual(2, tree.root.len());
    try testing.expectEqual(7, tree.root.Internal.childs[0].len());
    try testing.expectEqual(6, tree.root.Internal.childs[1].len());
    try testing.expectEqual(7, tree.root.Internal.keys[1]);

    const removed_val = tree.remove(alloc, 12);
    try testing.expectEqual(12 + 100, removed_val);
    try testing.expectEqual(null, tree.get(12));

    try testing.expectEqual(6, tree.root.Internal.childs[0].len());
    try testing.expectEqual(6, tree.root.Internal.childs[1].len());
    try testing.expectEqual(6, tree.root.Internal.keys[1]);
    try testing.expectEqual(11 + 100, tree.get(11));
    try testing.expectEqual(10 + 100, tree.get(10));
}

test "B+ Tree delete - underflow and borrow from right sibling (leaf)" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const T = BPlusTree(usize, usize, test_comp);
    var tree: T = undefined;
    try tree.init(alloc);
    defer tree.deinit(alloc);

    for (0..(BASE + CAPACITY)) |key| {
        _ = try tree.insert(alloc, key, key + 100);
    }

    try testing.expect(!tree.root.is_leaf());
    try testing.expectEqual(2, tree.root.len());
    try testing.expectEqual(7, tree.root.Internal.childs[0].len());
    try testing.expectEqual(11, tree.root.Internal.childs[1].len());
    try testing.expectEqual(7, tree.root.Internal.keys[1]);

    const removed_val = tree.remove(alloc, 0);
    const removed_val_1 = tree.remove(alloc, 1);
    try testing.expectEqual(0 + 100, removed_val);
    try testing.expectEqual(1 + 100, removed_val_1);
    try testing.expectEqual(null, tree.get(0));

    try testing.expectEqual(6, tree.root.Internal.childs[0].len());
    try testing.expectEqual(10, tree.root.Internal.childs[1].len());
    try testing.expectEqual(8, tree.root.Internal.keys[1]);
    try testing.expectEqual(null, tree.get(0));
    try testing.expectEqual(null, tree.get(1));
    try testing.expectEqual(6 + 100, tree.get(6));
    try testing.expectEqual(7 + 100, tree.get(7));
}

test "B+ Tree delete - underflow and merge with left sibling (leaf)" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const T = BPlusTree(usize, usize, test_comp);
    var tree: T = undefined;
    try tree.init(alloc);
    defer tree.deinit(alloc);

    for (0..CAPACITY) |key| {
        _ = try tree.insert(alloc, key, key + 100);
    }
    try testing.expect(tree.root.is_leaf());
    try testing.expectEqual(CAPACITY, tree.root.len());

    _ = try tree.insert(alloc, CAPACITY, CAPACITY + 100);

    try testing.expect(!tree.root.is_leaf());
    try testing.expectEqual(2, tree.root.len());
    try testing.expectEqual(7, tree.root.Internal.childs[0].len());
    try testing.expectEqual(6, tree.root.Internal.childs[1].len());
    try testing.expectEqual(0, tree.root.Internal.keys[0]);
    try testing.expectEqual(7, tree.root.Internal.keys[1]);

    const removed_val_12 = tree.remove(alloc, 12);
    try testing.expectEqual(12 + 100, removed_val_12);
    try testing.expectEqual(null, tree.get(12));

    try testing.expectEqual(6, tree.root.Internal.childs[0].len());
    try testing.expectEqual(6, tree.root.Internal.childs[1].len());
    try testing.expectEqual(0, tree.root.Internal.keys[0]);
    try testing.expectEqual(6, tree.root.Internal.keys[1]);

    const removed_val_11 = tree.remove(alloc, 11);
    try testing.expectEqual(11 + 100, removed_val_11);
    try testing.expectEqual(null, tree.get(11));

    try testing.expect(tree.root.is_leaf());
    try testing.expectEqual(11, tree.root.len());
    try testing.expectEqual(0 + 100, tree.get(0));
    try testing.expectEqual(10 + 100, tree.get(10));
    try testing.expectEqual(null, tree.get(11));
    try testing.expectEqual(null, tree.get(12));

    for (0..11) |key| {
        if (key != 11) {
            try testing.expectEqual(key + 100, tree.get(key));
        }
    }
    try testing.expectEqual(null, tree.get(99));
}

test "B+ Tree delete - underflow and merge with right sibling (leaf)" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const T = BPlusTree(usize, usize, test_comp);
    var tree: T = undefined;
    try tree.init(alloc);
    defer tree.deinit(alloc);

    for (0..CAPACITY) |key| {
        _ = try tree.insert(alloc, key, key + 100);
    }
    _ = try tree.insert(alloc, CAPACITY, CAPACITY + 100);
    _ = tree.remove(alloc, 12);

    try testing.expect(!tree.root.is_leaf());
    try testing.expectEqual(2, tree.root.len());
    try testing.expectEqual(6, tree.root.Internal.childs[0].len());
    try testing.expectEqual(6, tree.root.Internal.childs[1].len());
    try testing.expectEqual(0, tree.root.Internal.keys[0]);
    try testing.expectEqual(6, tree.root.Internal.keys[1]);

    const removed_val_0 = tree.remove(alloc, 0);
    try testing.expectEqual(0 + 100, removed_val_0);
    try testing.expectEqual(null, tree.get(0));

    try testing.expectEqual(11, tree.root.len());
    try testing.expect(tree.root.is_leaf());

    try testing.expectEqual(1 + 100, tree.get(1));
    try testing.expectEqual(11 + 100, tree.get(11));
    try testing.expectEqual(null, tree.get(0));
    try testing.expectEqual(null, tree.get(12));

    for (1..12) |key| {
        if (key != 12) {
            try testing.expectEqual(key + 100, tree.get(key));
        }
    }
    try testing.expectEqual(null, tree.get(99));
}

test "B+ Tree delete - underflow and borrow from right sibling (internal)" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const T = BPlusTree(usize, usize, test_comp);
    var tree: T = undefined;
    try tree.init(alloc);
    defer tree.deinit(alloc);

    for (0..90) |key| {
        _ = try tree.insert(alloc, key, key + 100);
    }

    try testing.expectEqual(tree.root.height(), 2);
    try testing.expect(!tree.root.is_leaf());
    try testing.expectEqual(tree.root.len(), 2);

    const I0 = tree.root.Internal.childs[0];
    const I1 = tree.root.Internal.childs[1];

    try testing.expect(!I0.is_leaf());
    try testing.expect(!I1.is_leaf());

    try testing.expectEqual(BASE + 1, I0.len());
    try testing.expectEqual(BASE, I1.len());

    for (0..9) |_| {
        const key_to_remove_from_I0 = I0.keys()[0];
        const removed_val = tree.remove(alloc, key_to_remove_from_I0);
        try testing.expectEqual(key_to_remove_from_I0 + 100, removed_val);
        try testing.expectEqual(null, tree.get(key_to_remove_from_I0));
    }

    try testing.expectEqual(tree.root.height(), 2);
    try testing.expect(!tree.root.is_leaf());
    try testing.expectEqual(tree.root.len(), 2);

    try testing.expectEqual(tree.root.childs()[0].keys()[0], 9);
    try testing.expectEqual(tree.root.keys()[0], 9);

    _ = tree.remove(alloc, 9);

    try testing.expectEqual(tree.root.height(), 1);
    try testing.expect(!tree.root.is_leaf());
    try testing.expectEqual(tree.root.len(), 11);

    _ = try tree.insert(alloc, 9, 109);
    _ = try tree.insert(alloc, 8, 108);

    try testing.expectEqual(tree.root.height(), 1);
    try testing.expect(!tree.root.is_leaf());
    try testing.expectEqual(tree.root.len(), 12);
}

test "B+ Set insert contains iterate and duplicate" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const T = BPlusSet(usize, test_comp);
    var set: T = undefined;
    try set.init(alloc);
    defer set.deinit(alloc);

    for (0..90) |key| {
        try testing.expect(try set.insert(alloc, key));
    }

    try testing.expectEqual(90, set.count());
    try testing.expect(set.contains(0));
    try testing.expect(set.contains(89));
    try testing.expect(!set.contains(90));

    try testing.expect(!try set.insert(alloc, 42));
    try testing.expectEqual(90, set.count());

    var iter = set.iter();
    var expected: usize = 0;
    while (iter.next()) |key| {
        try testing.expectEqual(expected, key);
        expected += 1;
    }
    try testing.expectEqual(90, expected);
}

test "B+ Set remove range clone and clear" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const T = BPlusSet(usize, test_comp);
    var set: T = undefined;
    try set.init(alloc);
    defer set.deinit(alloc);

    for (0..40) |key| {
        _ = try set.insert(alloc, key);
    }

    try testing.expect(set.remove(alloc, 0));
    try testing.expect(set.remove(alloc, 20));
    try testing.expect(!set.remove(alloc, 99));
    try testing.expect(!set.contains(0));
    try testing.expect(!set.contains(20));
    try testing.expectEqual(38, set.count());

    var range = set.rangeWithBounds(.{ .exclusive = 8 }, .{ .inclusive = 13 });
    var expected: usize = 9;
    while (range.next()) |key| {
        try testing.expectEqual(expected, key);
        expected += 1;
    }
    try testing.expectEqual(14, expected);

    var clone = try set.clone(alloc);
    defer clone.deinit(alloc);

    try testing.expect(clone.contains(13));
    try testing.expect(!clone.contains(20));
    try testing.expectEqual(set.count(), clone.count());

    set.clear(alloc);
    try testing.expectEqual(0, set.count());
    try testing.expect(!set.contains(13));
    try testing.expect(clone.contains(13));
}
