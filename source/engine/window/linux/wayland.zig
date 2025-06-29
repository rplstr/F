const std = @import("std");
const builtin = @import("builtin");
const event = @import("../event.zig");
const input = @import("../../input/input.zig");
const posix = std.posix;

const toPtr = @import("../../main.zig").toPtr;

const log = std.log.scoped(.wayland);

const OpenConfig = @import("../Window.zig").OpenConfig;
const OpenFlags = @import("../Window.zig").OpenFlags;

const wl = @import("wl.zig");
const linux = std.os.linux;

const RegistryContext = struct {
    compositor: ?*wl.wl_compositor = null,
    xdg_wm_base: ?*wl.xdg_wm_base = null,
    shm: ?*wl.wl_shm = null,
    seat: ?*wl.wl_seat = null,
};

var buffer: ?*wl.wl_buffer = null;
var queue: ?*event.Queue = null;
var keyboard: ?*wl.wl_keyboard = null;

comptime {
    if (builtin.os.tag != .linux) {
        @compileError("wayland backend should only compile on Linux");
    }
}

pub const Error = error{
    ConnectFailed,
    RegistryFailed,
    MissingCompositor,
    MissingXdgWmBase,
    SurfaceCreateFailed,
    TitleTooLong,
};

/// Opaque handle returned by `open`. All fields are implementation details.
pub const Handle = struct {
    display: *wl.wl_display,
    surface: *wl.wl_surface,
    xdg_surface: *wl.xdg_surface,
    toplevel: *wl.xdg_toplevel,
    compositor: *wl.wl_compositor,
    xdg_wm_base: *wl.xdg_wm_base,
    queue: ?*event.Queue,
};

/// Open a Wayland window according to `OpenConfig`.
pub fn open(config: OpenConfig) Error!Handle {
    const display = wl.wl_display_connect(null) orelse return Error.ConnectFailed;

    const registry = wl.wl_display_get_registry(display) orelse return Error.RegistryFailed;
    var ctx = RegistryContext{};

    _ = wl.wl_registry_add_listener(registry, &registry_listener, &ctx);
    _ = wl.wl_display_roundtrip(display); // populate globals and bind objects

    const compositor = ctx.compositor orelse return Error.MissingCompositor;
    const xdg_wm_base = ctx.xdg_wm_base orelse return Error.MissingXdgWmBase;

    if (ctx.shm) |shm_ptr| {
        buffer = createBuffer(shm_ptr);
    }

    _ = wl.xdg_wm_base_add_listener(xdg_wm_base, &xdg_wm_base_listener, null);

    const surface = wl.wl_compositor_create_surface(compositor) orelse return Error.SurfaceCreateFailed;
    const xdg_surface = wl.xdg_wm_base_get_xdg_surface(xdg_wm_base, surface) orelse return Error.SurfaceCreateFailed;

    const toplevel = wl.xdg_surface_get_toplevel(xdg_surface) orelse return Error.SurfaceCreateFailed;

    _ = wl.xdg_surface_add_listener(xdg_surface, &xdg_surface_listener, surface);

    _ = wl.xdg_toplevel_add_listener(toplevel, &toplevel_listener, null);

    // Title.
    var title_buf: [256]u8 = undefined;
    const title_c = toPtr(&title_buf, config.title) catch return Error.TitleTooLong;
    wl.xdg_toplevel_set_title(toplevel, title_c);

    // Handle window flags.
    const flags = config.flags;

    // Fullscreen.
    if ((flags & @intFromEnum(OpenFlags.fullscreen)) != 0) {
        wl.xdg_toplevel_set_fullscreen(toplevel, null);
    }

    // Resizable.
    if ((flags & @intFromEnum(OpenFlags.resizable)) == 0) {
        wl.xdg_toplevel_set_min_size(toplevel, @intCast(config.width), @intCast(config.height));
        wl.xdg_toplevel_set_max_size(toplevel, @intCast(config.width), @intCast(config.height));
    }

    // Decorated.
    if ((flags & @intFromEnum(OpenFlags.decorated)) == 0) {
        wl.xdg_toplevel_set_decorations(toplevel, 0);
    }

    // Centered.
    if ((flags & @intFromEnum(OpenFlags.centered)) != 0) {
        wl.xdg_toplevel_set_min_size(toplevel, @intCast(config.width), @intCast(config.height));
    }

    if ((flags & @intFromEnum(OpenFlags.visible)) != 0) {
        wl.wl_surface_commit(surface);

        _ = wl.wl_display_roundtrip(display);
    }

    _ = wl.wl_display_roundtrip(display);

    flush(display);
    return Handle{
        .display = display,
        .surface = surface,
        .xdg_surface = xdg_surface,
        .toplevel = toplevel,
        .compositor = compositor,
        .xdg_wm_base = xdg_wm_base,
        .queue = null,
    };
}

/// Pump window messages.
pub fn pump(handle: Handle, q: *event.Queue) void {
    var h = handle;
    h.queue = q;
    queue = q;

    _ = wl.wl_display_dispatch_pending(handle.display);

    while (wl.wl_display_prepare_read(handle.display) != 0) {
        _ = wl.wl_display_dispatch_pending(handle.display);
    }

    {
        flush(handle.display);

        const fd: posix.fd_t = @intCast(wl.wl_display_get_fd(handle.display));
        var pfd_arr = [1]posix.pollfd{.{
            .fd = fd,
            .events = std.os.linux.POLL.IN,
            .revents = 0,
        }};

        const poll_rc = posix.poll(pfd_arr[0..], 0) catch 0;
        if (poll_rc > 0 and (pfd_arr[0].revents & std.os.linux.POLL.IN) != 0) {
            _ = wl.wl_display_read_events(handle.display);
        } else {
            _ = wl.wl_display_cancel_read(handle.display);
        }

        _ = wl.wl_display_dispatch_pending(handle.display);
    }
}

/// Close the window releasing all Wayland objects.
pub fn close(handle: Handle) Error!void {
    wl.xdg_toplevel_destroy(handle.toplevel);
    wl.xdg_surface_destroy(handle.xdg_surface);
    wl.wl_surface_destroy(handle.surface);
    wl.wl_display_disconnect(handle.display);
}

fn flush(display: *wl.wl_display) void {
    _ = wl.wl_display_flush(display);
}

fn onXdgWmBasePing(_: ?*anyopaque, wm_base: ?*wl.xdg_wm_base, serial: u32) callconv(.c) void {
    if (wm_base) |base| {
        wl.xdg_wm_base_pong(base, serial);
    }
}

const xdg_wm_base_listener = wl.xdg_wm_base_listener{
    .ping = onXdgWmBasePing,
};

fn onGlobal(
    data: ?*anyopaque,
    registry: ?*wl.wl_registry,
    name: u32,
    interface: [*c]const u8,
    _: u32,
) callconv(.c) void {
    if (data) |ctx_ptr| {
        const iface = std.mem.sliceTo(interface, 0);
        var ctx = @as(*RegistryContext, @ptrCast(@alignCast(ctx_ptr)));
        if (std.mem.eql(u8, iface, "wl_compositor")) {
            ctx.compositor = @as(*wl.wl_compositor, @ptrCast(wl.wl_registry_bind(registry, name, &wl.wl_compositor_interface, 4)));
        } else if (std.mem.eql(u8, iface, "xdg_wm_base")) {
            ctx.xdg_wm_base = @as(*wl.xdg_wm_base, @ptrCast(wl.wl_registry_bind(registry, name, &wl.xdg_wm_base_interface, 1)));
        } else if (std.mem.eql(u8, iface, "wl_shm")) {
            ctx.shm = @as(*wl.wl_shm, @ptrCast(wl.wl_registry_bind(registry, name, &wl.wl_shm_interface, 1)));
        } else if (std.mem.eql(u8, iface, "wl_seat")) {
            ctx.seat = @as(*wl.wl_seat, @ptrCast(wl.wl_registry_bind(registry, name, &wl.wl_seat_interface, 1)));
            if (ctx.seat) |s| {
                _ = wl.wl_seat_add_listener(s, &seat_listener, null);
            }
        }
    }
}

const registry_listener = wl.wl_registry_listener{
    .global = onGlobal,
    .global_remove = onGlobalRemove,
};

fn onGlobalRemove(_: ?*anyopaque, _: ?*wl.wl_registry, _: u32) callconv(.c) void {}

fn onXdgSurfaceConfigure(data: ?*anyopaque, xdg_surface: ?*wl.xdg_surface, serial: u32) callconv(.c) void {
    if (xdg_surface) |surf| {
        wl.xdg_surface_ack_configure(surf, serial);
    }

    if (data) |ptr| {
        const surf = @as(*wl.wl_surface, @alignCast(@ptrCast(ptr)));
        if (buffer) |buf| {
            wl.wl_surface_attach(surf, buf, 0, 0);
        }
        wl.wl_surface_commit(surf);
    }
}

const xdg_surface_listener = wl.xdg_surface_listener{
    .configure = onXdgSurfaceConfigure,
};

fn createBuffer(shm: *wl.wl_shm) ?*wl.wl_buffer {
    const width: u32 = 1;
    const height: u32 = 1;
    const stride: usize = width * 4;
    const size: usize = stride * height;

    const fd = linux.memfd_create("f_buf", 0);
    errdefer linux.close(@intCast(fd));
    _ = linux.ftruncate(@intCast(fd), size);

    const data = linux.mmap(null, size, linux.PROT.READ | linux.PROT.WRITE, .{ .TYPE = .SHARED }, @intCast(fd), 0);
    @memset(@as([*]u8, @ptrFromInt(data))[0..size], 0);

    const pool = wl.wl_shm_create_pool(shm, @intCast(fd), @intCast(size));
    const buf = wl.wl_shm_pool_create_buffer(pool, 0, width, height, @intCast(stride), wl.WL_SHM_FORMAT_ARGB8888);
    wl.wl_shm_pool_destroy(pool);

    _ = linux.close(@intCast(fd));
    return buf;
}

fn pushPayload(q: *event.Queue, comptime T: type, id: event.Id, payload: T) void {
    _ = q.push(event.Event.init(T, id, payload));
}

fn pushKey(q: *event.Queue, key_code: u32, is_down: bool) void {
    const payload = input.KeyPayload{
        .key = input.Translate.evdevToKey(key_code),
        .mods = .{}, // TODO: modifiers handling
        .state = if (is_down) .down else .up,
    };
    const id: event.Id = if (is_down) .key_down else .key_up;
    pushPayload(q, input.KeyPayload, id, payload);
}

fn onSeatCapabilities(_: ?*anyopaque, seat: ?*wl.wl_seat, caps: u32) callconv(.c) void {
    log.info("seat capabilities: {x}", .{caps});
    if (seat) |s| {
        if ((caps & wl.WL_SEAT_CAPABILITY_KEYBOARD) != 0) {
            if (keyboard == null) {
                keyboard = wl.wl_seat_get_keyboard(s);
                if (keyboard) |kb| {
                    _ = wl.wl_keyboard_add_listener(kb, &keyboard_listener, null);
                    log.info("keyboard listener added", .{});
                }
            }
        }
    }
}

fn onSeatName(_: ?*anyopaque, _: ?*wl.wl_seat, _: [*c]const u8) callconv(.c) void {}

const seat_listener = wl.wl_seat_listener{
    .capabilities = onSeatCapabilities,
    .name = onSeatName,
};

fn onKeyboardKey(_: ?*anyopaque, _: ?*wl.wl_keyboard, _: u32, _: u32, key: u32, state: u32) callconv(.c) void {
    const is_down: bool = (state == wl.WL_KEYBOARD_KEY_STATE_PRESSED);
    if (queue) |q| {
        pushKey(q, key, is_down);
    }
}

fn onKeyboardKeyMap(_: ?*anyopaque, _: ?*wl.wl_keyboard, _: u32, _: i32, _: u32) callconv(.c) void {}
fn onKeyboardEnter(_: ?*anyopaque, _: ?*wl.wl_keyboard, _: u32, _: ?*wl.wl_surface, _: ?*wl.wl_array) callconv(.c) void {}
fn onKeyboardLeave(_: ?*anyopaque, _: ?*wl.wl_keyboard, _: u32, _: ?*wl.wl_surface) callconv(.c) void {}
fn onKeyboardModifiers(_: ?*anyopaque, _: ?*wl.wl_keyboard, _: u32, _: u32, _: u32, _: u32, _: u32) callconv(.c) void {}
fn onKeyboardRepeatInfo(_: ?*anyopaque, _: ?*wl.wl_keyboard, _: i32, _: i32) callconv(.c) void {}

const keyboard_listener = wl.wl_keyboard_listener{
    .keymap = onKeyboardKeyMap,
    .enter = onKeyboardEnter,
    .leave = onKeyboardLeave,
    .key = onKeyboardKey,
    .modifiers = onKeyboardModifiers,
    .repeat_info = onKeyboardRepeatInfo,
};

fn onToplevelClose(_: ?*anyopaque, _: ?*wl.xdg_toplevel) callconv(.c) void {
    if (queue) |q| {
        _ = q.push(event.Event.empty(.quit));
    }
}

fn onToplevelConfigure(
    _: ?*anyopaque,
    _: ?*wl.xdg_toplevel,
    _: i32,
    _: i32,
    _: ?*wl.wl_array,
) callconv(.c) void {}

const toplevel_listener = wl.xdg_toplevel_listener{
    .configure = onToplevelConfigure,
    .close = onToplevelClose,
};
