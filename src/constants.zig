const std = @import("std");
const mem = std.mem;

pub const BUNDLE_ID = "Hss.Odyssey";

pub const MAX_CONTEXT_ALIGN: mem.Alignment = .@"16";
pub const MAX_CONTEXT_SIZE = 128;

pub const MAX_PATH_LEN = 4096;

pub const SIMD_CHUNK_BYTES = 16;
