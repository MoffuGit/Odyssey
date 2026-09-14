const std = @import("std");

pub const rng = struct {
    pub inline fn contains(r: anytype, value: @typeInfo(@TypeOf(r)).array.child) bool {
        return value >= r[0] and value < r[1];
    }

    pub inline fn dim(r: anytype) @typeInfo(@TypeOf(r)).array.child {
        return if (r[1] > r[0]) r[1] - r[0] else 0;
    }

    pub inline fn empty(r: anytype) bool {
        return r[0] >= r[1];
    }

    pub inline fn intersect(a: anytype, b: anytype) @TypeOf(a) {
        return .{ @max(a[0], b[0]), @min(a[1], b[1]) };
    }
};

pub const rng2 = struct {
    pub inline fn contains(r: anytype, value: @typeInfo(@TypeOf(r)).array.child) bool {
        return r[0][0] <= value[0] and
            value[0] < r[1][0] and
            r[0][1] <= value[1] and
            value[1] < r[1][1];
    }
};
