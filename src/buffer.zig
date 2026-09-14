const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const patch = @import("patch.zig");
const PatchList = patch.PatchList;

const math = @import("math.zig");
const rng = math.rng;

pub const Buffer = @This();

data: []u8,
info: Info,
patchs: PatchList,

pub fn init(self: *Buffer, data: []u8, alloc: Allocator) !void {
    self.* = .{
        .data = data,
        .info = undefined,
        .patchs = .{},
    };

    try self.info.init(data, alloc);
}

pub const Info = struct {
    line_count: u64,
    line_ranges: [][2]u64,
    line_max_size: u64,

    pub fn init(self: *Info, buffer: []u8, alloc: Allocator) !void {
        var count: u64 = 0;

        for (buffer, 1..) |char, cnt| {
            if (char == '\n' or cnt == buffer.len) count += 1;
        }

        var ranges = try alloc.alloc([2]u64, count);

        var line_idx: usize = 0;
        var max_size: u64 = 0;
        var start: u64 = 0;
        for (buffer, 1..) |c, idx| {
            if (c == '\n' or idx == buffer.len) {
                const range: [2]u64 = .{ start, idx - 1 };
                ranges[line_idx] = range;

                max_size = @max(max_size, rng.dim(range));
                line_idx += 1;
                start = idx;
            }
        }

        self.* = .{
            .line_count = count,
            .line_max_size = max_size,
            .line_ranges = ranges,
        };
    }
};

test "Buffer init test" {
    const gpa = testing.allocator;

    const line1 = "This line is about x chars long\n";
    const line2 = "This other line is aboyt y chars long\n";
    const line3 = "This line is kinda like z chars long\n";
    const line4 = "This last line is aboyt z chars long\n";
    const line5 = "\n";

    const text = line1 ++ line2 ++ line3 ++ line4 ++ line5;

    var a: std.heap.ArenaAllocator = .init(gpa);
    defer a.deinit();

    const arena = a.allocator();

    const buffer = try arena.dupe(u8, text);

    const expected: [5][2]u64 = .{
        .{ 0, 31 },
        .{ 32, 69 },
        .{ 70, 106 },
        .{ 107, 143 },
        .{ 144, 144 },
    };

    var info: Info = undefined;
    try info.init(buffer, arena);

    try testing.expectEqualSlices([2]u64, &expected, info.line_ranges);
    try testing.expectEqual(info.line_max_size, 70 - 33);
}
