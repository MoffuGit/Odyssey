const std = @import("std");
const macos = @import("macos");
const font = @import("../font.zig");
const builtin = @import("builtin");

const log = std.log.scoped(.core_text);

const Face = struct {
    font: *macos.text.Font,
    size: font.Size,

    pub fn init(source: [:0]const u8, size: font.Size) !Face {
        const data = try macos.foundation.Data.createWithBytesNoCopy(source);
        defer data.release();

        const desc = macos.text.createFontDescriptorFromData(data) orelse
            return error.FontInitFailure;
        defer desc.release();

        const ct_font = try macos.text.Font.createWithFontDescriptor(desc, 12);

        try .fromCTFont(ct_font, size);
    }

    pub fn deinit(self: *Face) void {
        self.font.release();
        self.* = undefined;
    }

    pub fn fromCTFont(ct_font: *macos.text.Font, size: font.Size) !Face {
        const copy = try ct_font.copyWithAttributes(
            size.pixels(),
            null,
            null,
        );
        errdefer ct_font.release();

        return .{ .font = copy, .size = size };
    }

    pub fn name(self: *const Face, buf: []u8) ![]const u8 {
        const family_name = self.font.copyFamilyName();
        if (family_name.cstringPtr(.utf8)) |str| return str;

        // "NULL if the internal storage of theString does not allow
        // this to be returned efficiently." In this case, we need
        // to allocate.
        return family_name.cstring(buf, .utf8) orelse error.OutOfMemory;
    }
    //
    // pub fn copy(self: *Face, size: font.Size) !Face {}
};

test "name" {
    const testing = std.testing;

    const name = try macos.foundation.String.createWithBytes("Menlo", .utf8, false);
    defer name.release();
    const desc = try macos.text.FontDescriptor.createWithNameAndSize(name, 12);
    defer desc.release();
    const ct_font = try macos.text.Font.createWithFontDescriptor(desc, 12);
    defer ct_font.release();

    var face: Face = try .fromCTFont(ct_font, .{ .points = 12 });
    defer face.deinit();

    var buf: [1024]u8 = undefined;
    const font_name = try face.name(&buf);
    try testing.expectEqualStrings(font_name, "Menlo");
}
