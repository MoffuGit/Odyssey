const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const ArenaAllocator = std.heap.ArenaAllocator;
const Io = std.Io;
const autoHash = std.hash.autoHash;
const builtin = @import("builtin");

const kb = @import("kb_text");
const TrueType = @import("true_type");

const datastruct = @import("../datastruct.zig");
const SinglyLinkedList = datastruct.SinglyLinkedList;
const Atlas = datastruct.Atlas;
const HashTable = datastruct.HashTable;
const embedded = @import("../embedded.zig");

const log = std.log.scoped(.font_cache);

const DEFAULT_DPI = if (builtin.os.tag == .macos) 72 else 96;

pub const Cache = @This();

arena: ArenaAllocator,
gpa: Allocator,
data: HashTable(u64, Data, Data.Context),
fonts: HashTable(u64, Font, Font.Context),
glyphs: HashTable(Glyph.Key, Glyph, Glyph.Context),
atlas: Atlas,
buffer: std.ArrayList(u8),

pub fn init(self: *Cache, gpa: Allocator) !void {
    self.* = .{
        .gpa = gpa,
        .arena = .init(gpa),
        .data = undefined,
        .fonts = undefined,
        .atlas = undefined,
        .glyphs = undefined,
        .buffer = .empty,
    };

    const arena = self.arena.allocator();
    errdefer self.arena.deinit();

    try self.atlas.init(1024, 1024, gpa);
    errdefer self.atlas.deinit();

    try self.data.init(1028, .{}, arena);
    try self.fonts.init(1028, .{}, arena);
    try self.glyphs.init(1028, .{}, arena);
}

pub fn deinit(self: *Cache) void {
    self.atlas.deinit();
    self.arena.deinit();
    self.buffer.deinit(self.gpa);
}

pub fn fromPath(self: *Cache, abs_path: []const u8, index: u32, io: Io) !Tag {
    const arena = self.arena.allocator();

    var hash = std.hash.Wyhash.hash(0, abs_path);
    hash |= 1 << 63;

    const tag: Tag = .new(hash, index);

    if (self.fonts.get(tag.font_hash) == null) {
        const data = self.data.get(tag.data_hash) orelse data: {
            const new = try arena.create(Data);

            try new.fromPath(tag.data_hash, abs_path, arena, io);

            self.data.insert(new.key, new);

            break :data new;
        };

        const new = try arena.create(Font);

        new.init(data, index, tag.font_hash);

        self.fonts.insert(new.key, new);
    }

    return tag;
}

pub fn fromBytes(self: *Cache, bytes: []const u8, index: u32) !Tag {
    const arena = self.arena.allocator();

    var hash = std.hash.Wyhash.hash(0, bytes);
    hash &= ~@as(u64, 1 << 63);

    const tag: Tag = .new(hash, index);

    if (self.fonts.get(tag.font_hash) == null) {
        const data = self.data.get(tag.data_hash) orelse data: {
            const new = try arena.create(Data);

            new.fromBytes(bytes, tag.data_hash);

            self.data.insert(new.key, new);

            break :data new;
        };

        const new = try arena.create(Font);

        new.init(data, index, tag.font_hash);

        self.fonts.insert(new.key, new);
    }

    return tag;
}

pub fn fontStatus(self: *Cache, tag: Tag) ?Status {
    if (self.fonts.get(tag.font_hash)) |font|
        return font.status;
    return null;
}

pub fn dataStatus(self: *Cache, tag: Tag) ?Status {
    if (self.data.get(tag.data_hash)) |data|
        return data.status;
    return null;
}

pub fn dataFonts(self: *Cache, tag: Tag) ?u32 {
    if (self.data.get(tag.data_hash)) |data|
        return data.fonts;
    return null;
}

pub fn getGlyph(self: *Cache, tag: Tag, codepoint: u21, size: f32) !Glyph {
    const font = self.fonts.get(tag.font_hash) orelse return error.MissingFont;

    if (font.status == .invalid) return error.InvalidFont;

    const index = font.ttf.codepointGlyphIndex(codepoint);

    const key: Glyph.Key = .{ .index = @backingInt(index), .tag = tag, .size = size };

    if (self.glyphs.get(key)) |glyph| return glyph.*;

    const arena = self.arena.allocator();

    const scale = font.ttf.scaleForPixelHeight(size);
    const bitmap = try font.ttf.glyphBitmap(self.gpa, &self.buffer, index, scale, scale);

    const region = try self.atlas.reserve(bitmap.width, bitmap.height);
    self.atlas.set(region, self.buffer.items);

    const glyph = try arena.create(Glyph);

    const rotate = bitmap.width != region.width;

    glyph.* = .{
        .size = size,
        .key = key,
        .width = region.width,
        .height = region.height,
        .rotate = rotate,
        .off_x = bitmap.off_x,
        .off_y = bitmap.off_y,
        .x = region.x,
        .y = region.y,
    };

    self.glyphs.insert(glyph.key, glyph);
    self.buffer.clearRetainingCapacity();

    return glyph.*;
}

const Tag = struct {
    font_hash: u64,
    data_hash: u64,

    pub fn new(data_key: u64, index: u32) Tag {
        var hasher = std.hash.Wyhash.init(0);
        autoHash(&hasher, data_key);
        autoHash(&hasher, index);

        return .{
            .data_hash = data_key,
            .font_hash = hasher.final(),
        };
    }
};

const Font = struct {
    next: ?*Font = null,
    prev: ?*Font = null,

    key: u64,
    index: u32,
    ttf: TrueType,
    kbf: kb.kbts_font,
    status: Status,

    pub fn init(self: *Font, data: *Data, index: u32, key: u64) void {
        self.* = .{
            .index = index,
            .key = key,
            .ttf = undefined,
            .kbf = undefined,
            .status = .invalid,
        };

        if (data.status != .loaded) return;

        const offset = TrueType.fontOffsetForIndex(data.bytes, index) orelse return;
        self.ttf = TrueType.load(data.bytes, offset) catch return;
        self.kbf = kb.kbts_FontFromMemory(
            @constCast(data.bytes.ptr),
            @intCast(data.bytes.len),
            @intCast(index),
            null,
            null,
        );

        if (kb.kbts_FontIsValid(&self.kbf) != 1) return;

        self.kbf.UserData;
        self.status = .loaded;
    }

    pub const Context = struct {
        pub fn hash(_: @This(), k: u64) u64 {
            return k;
        }

        pub fn eql(_: @This(), k: u64, v: *Font) bool {
            return k == v.key;
        }
    };
};

pub fn readFile(abs_path: []const u8, arena: Allocator, io: Io) ![]u8 {
    const file = try Io.Dir.openFileAbsolute(io, abs_path, .{});
    defer file.close(io);

    const length = try file.length(io);

    const buffer = try arena.alloc(u8, length);
    errdefer arena.free(buffer);

    var reader = file.reader(io, buffer);
    try reader.interface.fill(length);

    return buffer;
}

pub const Status = union(enum) {
    loaded,
    invalid,
};

const Data = struct {
    next: ?*Data = null,
    prev: ?*Data = null,

    key: u64,
    fonts: u32,
    path: []const u8,
    bytes: []const u8,
    status: Status,

    pub fn fromPath(self: *Data, key: u64, abs_path: []const u8, arena: Allocator, io: Io) !void {
        self.loadFromPath(key, abs_path, arena, io) catch |err| {
            switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => self.* = .{
                    .fonts = 0,
                    .key = key,
                    .bytes = undefined,
                    .path = undefined,
                    .status = .invalid,
                },
            }
        };
    }

    pub fn loadFromPath(self: *Data, key: u64, abs_path: []const u8, arena: Allocator, io: Io) !void {
        const buffer = try readFile(abs_path, arena, io);
        const path = try arena.dupe(u8, abs_path);

        const fonts = TrueType.numberOfFonts(buffer);
        const status: Status = if (fonts == 0) .invalid else .loaded;

        self.* = .{
            .key = key,
            .bytes = buffer,
            .fonts = fonts,
            .path = path,
            .status = status,
        };
    }

    pub fn fromBytes(self: *Data, bytes: []const u8, key: u64) void {
        const fonts = TrueType.numberOfFonts(bytes);
        const status: Status = if (fonts == 0) .invalid else .loaded;

        self.* = .{
            .status = status,
            .bytes = bytes,
            .fonts = fonts,
            .path = "",
            .key = key,
        };
    }

    pub const Context = struct {
        pub fn hash(_: @This(), k: u64) u64 {
            return k;
        }

        pub fn eql(_: @This(), k: u64, v: *Data) bool {
            return k == v.key;
        }
    };
};

const Glyph = struct {
    next: ?*Glyph = null,
    prev: ?*Glyph = null,

    key: Key,

    rotate: bool,
    width: u32,
    height: u32,
    off_x: i16,
    off_y: i16,
    x: u32,
    y: u32,
    size: f32,

    const Key = struct {
        tag: Tag,
        index: u16,
        size: f32,
    };

    pub const Context = struct {
        pub fn hash(_: @This(), k: Key) u64 {
            var hasher = std.hash.Wyhash.init(0);
            autoHash(&hasher, k.index);
            autoHash(&hasher, k.tag);
            autoHash(&hasher, @as(u32, @bitCast(k.size)));
            return hasher.final();
        }

        pub fn eql(_: @This(), k: Key, v: *Glyph) bool {
            return std.meta.eql(k, v.key);
        }
    };
};

test "basic" {
    const gpa = testing.allocator;
    const io = testing.io;

    var cache: Cache = undefined;
    try cache.init(gpa);
    defer cache.deinit();

    const abs_path = try Io.Dir.cwd().realPathFileAlloc(io, "src/embedded/Inter.ttc", gpa);
    defer gpa.free(abs_path);

    const tag1 = try cache.fromPath(abs_path, 0, io);
    const tag1_2 = try cache.fromPath(abs_path, 0, io);

    const tag2 = try cache.fromBytes(embedded.inter, 0);
    const tag2_2 = try cache.fromBytes(embedded.inter, 0);

    try testing.expectEqual(cache.fontStatus(tag1).?, .loaded);
    try testing.expectEqual(cache.fontStatus(tag2).?, .loaded);

    try testing.expectEqual(cache.dataStatus(tag1).?, .loaded);
    try testing.expectEqual(cache.dataStatus(tag2).?, .loaded);

    try testing.expectEqual(tag1, tag1_2);
    try testing.expectEqual(tag2, tag2_2);
    try testing.expectEqual(1, cache.dataFonts(tag2).?);

    var font_iter = cache.fonts.iterator();
    var font_count: u8 = 0;
    while (font_iter.next()) |_| {
        font_count += 1;
    }

    var data_iter = cache.data.iterator();
    var data_count: u8 = 0;
    while (data_iter.next()) |_| {
        data_count += 1;
    }

    try testing.expectEqual(2, font_count);
    try testing.expectEqual(2, data_count);

    var it = std.unicode.Utf8View.initComptime("abcdefghijkl").iterator();

    while (it.nextCodepoint()) |codepoint| {
        const glyph_1 = try cache.getGlyph(tag2, codepoint, 21);
        const glyph_2 = try cache.getGlyph(tag2_2, codepoint, 21);
        const glyph_3 = try cache.getGlyph(tag2_2, codepoint, 16);

        try testing.expectEqual(glyph_1, glyph_2);
        try testing.expectEqual(glyph_1, glyph_2);
        try testing.expect(!std.meta.eql(glyph_3.key, glyph_2.key));
    }
}
