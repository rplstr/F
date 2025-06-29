const std = @import("std");

pub const logger = @import("log/logger.zig");
pub const lua = @import("lua.zig");
pub const event = @import("window/event.zig");
pub const input = @import("input/input.zig");
pub const ecs = @import("ecs/world.zig");
pub const job = @import("parallelization/JobSystem.zig");
pub const vulkan = @import("vulkan.zig");

pub const Window = @import("window/Window.zig");
pub const FileWatcher = @import("FileWatcher.zig");

const max_len: usize = 256;
const slots: usize = 256;

var ring: [slots][max_len]u8 = undefined;
var next_slot: usize = 0;

pub fn cstr(txt: []const u8) [:0]const u8 {
    std.debug.assert(txt.len + 1 <= max_len);

    const slot = next_slot;
    next_slot = (next_slot + 1) % slots;

    var buf = &ring[slot];
    std.mem.copyForwards(u8, buf[0..txt.len], txt);
    buf[txt.len] = 0;

    return buf[0..txt.len :0];
}

/// Pointer version when a C API expects `[*:0]const u8`.
pub fn cstrPtr(txt: []const u8) [*:0]const u8 {
    return cstr(txt).ptr;
}

/// Copy `txt` into `buf`, append a null terminator and return a sentinel slice.
/// The caller must ensure `buf.len > txt.len` so there is space for the `\0`.
pub fn toSlice(buf: []u8, txt: []const u8) ![:0]const u8 {
    if (txt.len >= buf.len) return error.BufferTooSmall;
    std.mem.copyForwards(u8, buf[0..txt.len], txt);
    buf[txt.len] = 0;
    return buf[0..txt.len :0];
}

/// Same as `toSlice` but returns a `[*:0]const u8` pointer instead of a slice.
/// Useful when the C API expects a pointer.
pub fn toPtr(buf: []u8, txt: []const u8) ![*:0]const u8 {
    const slice = try toSlice(buf, txt);
    return slice.ptr;
}
