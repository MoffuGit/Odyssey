const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const ArenaAllocator = std.heap.ArenaAllocator;
const Io = std.Io;
const builtin = @import("builtin");

const kb = @import("kb_text");
const TrueType = @import("true_type");

const datastruct = @import("datastruct.zig");
const SinglyLinkedList = datastruct.SinglyLinkedList;
const embedded = @import("embedded.zig");

pub const DEFAULT_DPI = if (builtin.os.tag == .macos) 72 else 96;

pub const State = struct {
    buffers: SinglyLinkedList(Buffer),

    pub fn init(self: *State, _: Allocator) !void {
        self.* = .{
            .buffers = .empty,
        };
    }

    pub fn deinit(self: *State) void {
        _ = self;
    }
};

const Face = struct {
    buffer: *Buffer,
    ttf: TrueType,
    kbf: kb.kbts_font,
    size: Size,

    pub fn init(buffer: *Buffer, index: u32, size: Size) !Face {
        const offset = TrueType.fontOffsetForIndex(buffer.bytes, index) orelse unreachable;
        const ttf: TrueType = try .load(buffer.bytes, offset);
        var kbt = kb.kbts_FontFromMemory(
            @constCast(buffer.bytes.ptr),
            @intCast(buffer.bytes.len),
            @intCast(index),
            null,
            null,
        );

        if (kb.kbts_FontIsValid(&kbt) != 1) return error.LoadError;

        return .{
            .buffer = buffer,
            .ttf = ttf,
            .kbf = kbt,
            .size = size,
        };
    }
};

pub const Size = struct {
    points: f32,

    xdpi: u16 = DEFAULT_DPI,
    ydpi: u16 = DEFAULT_DPI,

    pub fn pixels(self: Size) f32 {
        return (self.points * @as(f32, @floatFromInt(self.ydpi))) / 72;
    }
};

const Buffer = struct {
    next: ?*Buffer = null,
    gpa: ?Allocator = null,
    references: usize = 0,

    bytes: []const u8,
    fonts: u32,

    pub fn load(abs_path: []const u8, gpa: Allocator, io: Io) !Buffer {
        const file = try Io.Dir.openFileAbsolute(io, abs_path, .{});
        defer file.close(io);

        const length = try file.length(io);

        const buffer = try gpa.alloc(u8, length);
        errdefer gpa.free(buffer);

        var reader = file.reader(io, buffer);
        try reader.interface.fill(length);

        const fonts = TrueType.numberOfFonts(buffer);
        if (fonts == 0) return error.InvalidData;

        return .{
            .bytes = buffer,
            .gpa = gpa,
            .fonts = fonts,
        };
    }

    pub fn fromBytes(bytes: []const u8) !Buffer {
        const fonts = TrueType.numberOfFonts(bytes);
        if (fonts == 0) return error.InvalidData;

        return .{ .bytes = bytes, .fonts = fonts };
    }

    pub fn deinit(self: *Buffer) void {
        if (self.gpa) |gpa| {
            gpa.free(self.bytes);
        }
    }
};

test "basic" {
    const gpa = testing.allocator;
    const io = testing.io;

    const abs_path = try Io.Dir.cwd().realPathFileAlloc(io, "src/embedded/Inter.ttc", gpa);
    defer gpa.free(abs_path);

    var buffer: Buffer = try .fromBytes(embedded.inter);
    defer buffer.deinit();

    var loaded_buffer: Buffer = try .load(abs_path, gpa, io);
    defer loaded_buffer.deinit();

    try testing.expectEqual(1, buffer.fonts);
    try testing.expectEqual(36, loaded_buffer.fonts);

    const face: Face = try .init(&buffer, 0, .{ .points = 12 });
    _ = face;
}
