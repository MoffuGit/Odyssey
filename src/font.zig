const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const ArenaAllocator = std.heap.ArenaAllocator;
const Io = std.Io;
const autoHash = std.hash.autoHash;
const builtin = @import("builtin");

const kb = @import("kb_text");
const TrueType = @import("true_type");

const datastruct = @import("datastruct.zig");
const SinglyLinkedList = datastruct.SinglyLinkedList;
const Atlas = datastruct.Atlas;
const HashTable = datastruct.HashTable;
const embedded = @import("embedded.zig");

const log = std.log.scoped(.font_cache);

const DEFAULT_DPI = if (builtin.os.tag == .macos) 72 else 96;
const ContextFlag = kb.KBTS_SHAPE_CONTEXT_FLAG_FONT_PRIORITY_BOTTOM_TO_TOP;

pub const Cache = @This();

arena: ArenaAllocator,
gpa: Allocator,
data: HashTable(u64, Data, Data.Context),
fonts: HashTable(u64, Font, Font.Context),
collections: HashTable(u64, Collection, Collection.Context),
glyphs: HashTable(Glyph.Key, Glyph, Glyph.Context),
atlas: Atlas,
buffer: std.ArrayList(u8),
glyph_buffer: std.ArrayList(Glyph),

pub fn init(self: *Cache, gpa: Allocator) !void {
    self.* = .{
        .glyph_buffer = .empty,
        .gpa = gpa,
        .arena = .init(gpa),
        .data = undefined,
        .fonts = undefined,
        .atlas = undefined,
        .glyphs = undefined,
        .collections = undefined,
        .buffer = .empty,
    };

    const arena = self.arena.allocator();
    errdefer self.arena.deinit();

    try self.atlas.init(1024, 1024, gpa);
    errdefer self.atlas.deinit();

    try self.data.init(1028, .{}, arena);
    try self.fonts.init(1028, .{}, arena);
    try self.glyphs.init(1028, .{}, arena);
    try self.collections.init(1028, .{}, arena);
}

pub fn deinit(self: *Cache) void {
    var iter = self.collections.iterator();
    while (iter.next()) |collection| collection.deinit();
    self.atlas.deinit();
    self.arena.deinit();
    self.buffer.deinit(self.gpa);
    self.glyph_buffer.deinit(self.gpa);
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

        try self.addFont(data, index, tag);
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

        try self.addFont(data, index, tag);
    }

    return tag;
}

pub fn addFont(self: *Cache, data: *Data, index: u32, tag: Tag) !void {
    const arena = self.arena.allocator();

    const font = try arena.create(Font);

    font.init(data, index, tag);
    self.fonts.insert(tag.font_hash, font);
}

pub fn addCollection(self: *Cache, tags: []const Tag) !u64 {
    var hasher = std.hash.Wyhash.init(0);
    for (tags) |tag| autoHash(&hasher, tag);
    const key = hasher.final();
    if (self.collections.get(key) != null) return key;

    const arena = self.arena.allocator();

    const collection = try arena.create(Collection);
    try collection.init(key, arena);

    for (tags) |tag| {
        const font = self.fonts.get(tag.font_hash) orelse continue;
        try collection.add(font, arena);
    }

    self.collections.insert(key, collection);
    return key;
}

pub fn run(
    self: *Cache,
    key: u64,
    size: f32,
    str: []const u8,
) !Run {
    const collection = self.collections.get(key) orelse return error.MissingCollection;

    if (collection.runs.get(.{ .str = str, .size = size })) |cached| return cached.*;

    self.glyph_buffer.clearRetainingCapacity();

    const context = collection.context;
    context.ShapeBegin(kb.KBTS_DIRECTION_DONT_KNOW, kb.KBTS_LANGUAGE_ENGLISH);
    context.ShapeUtf8(str.ptr, @intCast(str.len), kb.KBTS_USER_ID_GENERATION_MODE_CODEPOINT_INDEX);
    context.ShapeEnd();

    const arena = self.arena.allocator();

    var kb_run: kb.kbts_run = undefined;
    while (context.ShapeRun(&kb_run) != 0) {
        const font: *Font = @ptrCast(@alignCast(kb_run.Font.*.UserData));

        var kb_glyph: [*c]kb.kbts_glyph = undefined;
        while (kb_run.Glyphs.GlyphIteratorNext(&kb_glyph) != 0) {
            const glyph = try self.getGlyph(font.tag, kb_glyph.*.Id, size);
            try self.glyph_buffer.append(self.gpa, glyph);
        }
    }

    const new = try arena.create(Run);
    new.* = .{
        .str = try arena.dupe(u8, str),
        .glyphs = try arena.dupe(Glyph, self.glyph_buffer.items),
        .size = size,
    };
    collection.runs.insert(.{ .str = new.str, .size = size }, new);

    return new.*;
}

pub fn getGlyph(self: *Cache, tag: Tag, index: u16, size: f32) !Glyph {
    const font = self.fonts.get(tag.font_hash) orelse return error.MissingFont;

    if (font.status == .invalid) return error.InvalidFont;

    if (self.glyphs.get(.{ .index = index, .tag = tag, .size = size })) |glyph| return glyph.*;

    const arena = self.arena.allocator();

    const scale = font.ttf.scaleForPixelHeight(size);
    defer self.buffer.clearRetainingCapacity();
    const bitmap = try font.ttf.glyphBitmap(self.gpa, &self.buffer, @fromBackingInt(index), scale, scale);

    var region: Atlas.Region = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    var rotate = false;

    if (bitmap.width != 0 and bitmap.height != 0) {
        region = try self.atlas.reserve(bitmap.width, bitmap.height);
        rotate = bitmap.width != region.width;

        const len = @as(usize, bitmap.width) * bitmap.height;
        var pixels = self.buffer.items[0..len];

        if (rotate) {
            try self.buffer.ensureUnusedCapacity(self.gpa, len);
            const src = self.buffer.items[0..len];
            pixels = self.buffer.addManyAsSliceAssumeCapacity(len);

            for (0..bitmap.height) |y| {
                for (0..bitmap.width) |x| {
                    pixels[x * region.width + y] = src[y * bitmap.width + x];
                }
            }
        }

        self.atlas.set(region, pixels);
    }

    const glyph = try arena.create(Glyph);

    glyph.* = .{
        .size = size,
        .tag = tag,
        .index = index,
        .width = bitmap.width,
        .height = bitmap.height,
        .rotate = rotate,
        .off_x = bitmap.off_x,
        .off_y = bitmap.off_y,
        .x = region.x,
        .y = region.y,
    };

    self.glyphs.insert(glyph.key(), glyph);

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

    tag: Tag,
    index: u32,
    ttf: TrueType,
    kbf: kb.kbts_font,
    status: Status,

    pub fn init(self: *Font, data: *Data, index: u32, tag: Tag) void {
        self.* = .{
            .index = index,
            .tag = tag,
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

        self.kbf.UserData = self;
        self.status = .loaded;
    }

    pub const Context = struct {
        pub fn hash(_: @This(), k: u64) u64 {
            return k;
        }

        pub fn eql(_: @This(), k: u64, v: *Font) bool {
            return k == v.tag.font_hash;
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

    tag: Tag,
    index: u16,
    size: f32,
    rotate: bool,
    width: u32,
    height: u32,
    off_x: i16,
    off_y: i16,
    x: u32,
    y: u32,

    pub fn key(self: *const Glyph) Key {
        return .{
            .tag = self.tag,
            .index = self.index,
            .size = self.size,
        };
    }

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
            return std.meta.eql(k, v.key());
        }
    };
};

const Run = struct {
    pub const Key = struct {
        str: []const u8,
        size: f32,
    };
    next: ?*Run = null,
    prev: ?*Run = null,

    str: []const u8,
    glyphs: []const Glyph,
    size: f32,

    pub const Context = struct {
        pub fn hash(_: @This(), k: Key) u64 {
            var hasher = std.hash.Wyhash.init(0);
            hasher.update(k.str);
            autoHash(&hasher, @as(u32, @bitCast(k.size)));
            return hasher.final();
        }

        pub fn eql(_: @This(), k: Key, v: *Run) bool {
            return k.size == v.size and std.mem.eql(u8, k.str, v.str);
        }
    };
};

const Collection = struct {
    const Item = struct { next: ?*Item = null, tag: Tag };

    next: ?*Collection = null,
    prev: ?*Collection = null,

    key: u64,
    tags: SinglyLinkedList(Item),
    runs: HashTable(Run.Key, Run, Run.Context),
    context: *kb.kbts_shape_context,

    pub fn init(self: *Collection, key: u64, arena: Allocator) !void {
        self.* = .{
            .tags = .empty,
            .key = key,
            .runs = undefined,
            .context = undefined,
        };

        self.context = kb.kbts_CreateShapeContext2(null, null, ContextFlag) orelse return error.KBCTXERROR;
        try self.runs.init(1028, .{}, arena);
    }

    pub fn deinit(self: *Collection) void {
        self.context.DestroyShapeContext();
    }

    pub fn primary(self: *Collection) Tag {
        return self.tags.head orelse unreachable;
    }

    pub fn add(self: *Collection, font: *Font, arena: Allocator) !void {
        const item = try arena.create(Item);
        item.* = .{ .tag = font.tag };

        self.tags.append(item);
        if (self.context.ShapePushFont(&font.kbf) == 0) return error.OutOfSpace;
    }

    pub const Context = struct {
        pub fn hash(_: @This(), k: u64) u64 {
            return k;
        }

        pub fn eql(_: @This(), k: u64, v: *Collection) bool {
            return k == v.key;
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
    const tag2 = try cache.fromBytes(embedded.inter, 0);

    const collection = try cache.addCollection(&.{ tag1, tag2 });

    const res = try cache.run(collection, 12, "Hello");

    try testing.expectEqual(5, res.glyphs.len);
    try testing.expectEqual(res.glyphs[2], res.glyphs[3]);
    try testing.expect(!std.meta.eql(res.glyphs[0], res.glyphs[1]));

    const cached = try cache.run(collection, 12, "Hello");
    try testing.expectEqual(res.glyphs.ptr, cached.glyphs.ptr);

    const bigger = try cache.run(collection, 24, "Hello");

    try testing.expect(bigger.glyphs[0].height > res.glyphs[0].height);

    try testing.expectEqual(tag1, res.glyphs[0].tag);
    const other = try cache.addCollection(&.{tag2});
    try testing.expectEqual(tag2, (try cache.run(other, 12, "Hi")).glyphs[0].tag);
    try testing.expectEqual(tag1, (try cache.run(collection, 12, "Hi")).glyphs[0].tag);

    var before: std.ArrayList(Atlas.Region) = .empty;
    defer before.deinit(gpa);
    var node = cache.atlas.regions.first;
    while (node) |n| : (node = n.next) try before.append(gpa, n.region);

    const space = try cache.run(collection, 24, " ");
    try testing.expectEqual(0, space.glyphs[0].width);
    try testing.expectEqual(0, space.glyphs[0].height);

    node = cache.atlas.regions.first;
    for (before.items) |region| {
        try testing.expectEqual(region, node.?.region);
        node = node.?.next;
    }
    try testing.expectEqual(null, node);
}

test "atlas holds each glyph bitmap, transposed when rotated" {
    const gpa = testing.allocator;

    var cache: Cache = undefined;
    try cache.init(gpa);
    defer cache.deinit();

    const tag = try cache.fromBytes(embedded.inter, 0);
    const collection = try cache.addCollection(&.{tag});
    const font = cache.fonts.get(tag.font_hash).?;

    var rotated: usize = 0;
    for ([_]f32{ 13, 29, 47 }) |size| {
        const res = try cache.run(collection, size, "The quick brown fox jumps over the lazy dog! WMQ@#gjpy");

        for (res.glyphs) |glyph| {
            var pixels: std.ArrayList(u8) = .empty;
            defer pixels.deinit(gpa);

            const scale = font.ttf.scaleForPixelHeight(size);
            const bitmap = try font.ttf.glyphBitmap(gpa, &pixels, @fromBackingInt(glyph.index), scale, scale);
            if (glyph.rotate) rotated += 1;

            for (0..bitmap.height) |y| {
                for (0..bitmap.width) |x| {
                    const ax, const ay = if (glyph.rotate) .{ y, x } else .{ x, y };
                    try testing.expectEqual(
                        pixels.items[y * bitmap.width + x],
                        cache.atlas.buffer[(glyph.y + ay) * cache.atlas.width + glyph.x + ax],
                    );
                }
            }
        }
    }

    try testing.expect(rotated > 0);
}
