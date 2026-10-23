const builtin = @import("builtin");
const CoreText = @import("font/core_text.zig");

pub const DEFAULT_DPI = if (builtin.os.tag == .macos) 72 else 96;

pub const Size = struct {
    points: f32,

    dpi: [2]u16 = @splat(DEFAULT_DPI),

    pub fn pixels(self: Size) f32 {
        return (self.points * @as(f32, @floatFromInt(self.dpi[1]))) / 72;
    }
};

test {
    _ = CoreText;
}
