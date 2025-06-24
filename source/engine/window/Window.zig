//! Window module.
//! This module does not provide Lua bindings, as it is not a reusable module.
const builtin = @import("builtin");
const event = @import("event.zig");

/// Configuration options for opening a window.
pub const OpenConfig = struct {
    /// Title displayed in the window's title bar.
    title: []const u8,
    /// Window width in pixels.
    width: u32,
    /// Window height in pixels.
    height: u32,
    /// Window flags.
    flags: OpenFlags.Mask = 0,
};

pub const OpenFlags = enum(u8) {
    // NOTE: keep values in distinct bit positions (1<<n).

    /// Window is visible.
    visible = 1 << 1,
    /// Window has a border.
    border = 1 << 2,
    /// Window is resizable.
    resizable = 1 << 3,
    /// Window is fullscreen.
    fullscreen = 1 << 4,
    /// Window is decorated.
    decorated = 1 << 5,
    /// Window is centered.
    centered = 1 << 6,

    pub const Mask = u8;

    /// Build a flag mask from a compile-time list of `OpenFlags`.
    pub fn mask(comptime list: anytype) Mask {
        var m: Mask = 0;
        inline for (list) |f| m |= @intFromEnum(@as(OpenFlags, f));
        return m;
    }
};

const native_os = builtin.os.tag;

const Impl = if (native_os == .windows)
    @import("windows/win32.zig")
else if (native_os == .linux)
    @import("linux/x11.zig")
else
    UnsupportedImpl;

const UnsupportedImpl = struct {
    pub const Error = error{UnsupportedPlatform};
    pub const Handle = void;
    pub fn open(_: OpenConfig) @This().Error!@This().Handle {
        return error.UnsupportedPlatform;
    }
    pub fn close(_: @This().Handle) @This().Error!void {
        return error.UnsupportedPlatform;
    }
    pub fn pump(_: @This().Handle, _: *event.Queue) void {}
};

pub const Error = Impl.Error;
/// Opaque window handle returned by `open`.
pub const Handle = Impl.Handle;

/// Pumps platform messages and writes corresponding events into `queue`.
pub fn pump(handle: Handle, queue: *event.Queue) void {
    Impl.pump(handle, queue);
}

/// Opens a window via the active backend.
pub fn open(config: OpenConfig) Error!Handle {
    return Impl.open(config);
}

/// Closes a previously opened window handle.
pub fn close(handle: Handle) Error!void {
    return Impl.close(handle);
}
