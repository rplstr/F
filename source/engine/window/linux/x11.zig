const builtin = @import("builtin");
const std = @import("std");
const xlib = @import("xlib.zig");

const event = @import("../event.zig");

const OpenConfig = @import("../Window.zig").OpenConfig;
const OpenFlags = @import("../Window.zig").OpenFlags;

const input = @import("../../input/input.zig");

comptime {
    if (builtin.os.tag != .linux) @compileError("x11 backend should only compile on Linux");
}

pub const Error = error{
    OpenDisplayFailed,
    CreateWindowFailed,
    MapWindowFailed,
};

pub const Handle = struct {
    display: *xlib.Display,
    xid: xlib.Window,
    wm_delete: xlib.Atom,
};

/// Opens an X11 window according to `OpenConfig`.
pub fn open(config: OpenConfig) Error!Handle {
    const flags: u8 = config.flags;

    // Display.
    const dsp = xlib.XOpenDisplay(null) orelse return error.OpenDisplayFailed;
    const screen = xlib.XDefaultScreen(dsp);
    const root = xlib.XDefaultRootWindow(dsp);

    // Screen metrics.
    const screen_w = xlib.XDisplayWidth(dsp, screen);
    const screen_h = xlib.XDisplayHeight(dsp, screen);

    // Size and position.
    var width_px: c_uint = @as(c_uint, @intCast(config.width));
    var height_px: c_uint = @as(c_uint, @intCast(config.height));
    var pos_x: c_int = 0;
    var pos_y: c_int = 0;

    if ((flags & @intFromEnum(OpenFlags.fullscreen)) != 0) {
        width_px = @as(c_uint, @intCast(screen_w));
        height_px = @as(c_uint, @intCast(screen_h));
        pos_x = 0;
        pos_y = 0;
    } else if ((flags & @intFromEnum(OpenFlags.centered)) != 0) {
        pos_x = @divTrunc(screen_w - @as(c_int, @intCast(width_px)), 2);
        pos_y = @divTrunc(screen_h - @as(c_int, @intCast(height_px)), 2);
    }

    // Border width.
    const border_width: c_uint = if ((flags & @intFromEnum(OpenFlags.border)) != 0) 1 else 0;

    // Colors.
    const black = xlib.XBlackPixel(dsp, screen);
    const white = xlib.XWhitePixel(dsp, screen);

    // The window itself.
    const xid = xlib.XCreateSimpleWindow(
        dsp,
        root,
        pos_x,
        pos_y,
        width_px,
        height_px,
        border_width,
        black,
        white,
    );
    if (xid == 0) return error.CreateWindowFailed;

    _ = xlib.XSelectInput(dsp, xid, xlib.KeyPressMask | xlib.KeyReleaseMask |
        xlib.ButtonPressMask | xlib.ButtonReleaseMask |
        xlib.PointerMotionMask);

    // Decorations.
    if ((flags & @intFromEnum(OpenFlags.decorated)) == 0) {
        const motif_atom = xlib.XInternAtom(dsp, "_MOTIF_WM_HINTS", 0);
        const MotifHints = extern struct {
            flags: c_ulong,
            functions: c_ulong,
            decorations: c_ulong,
            input_mode: c_long,
            status: c_ulong,
        };
        const MWM_HINTS_DECORATIONS: c_ulong = 1 << 1; // 2
        var hints: MotifHints = .{
            .flags = MWM_HINTS_DECORATIONS,
            .functions = 0,
            .decorations = 0,
            .input_mode = 0,
            .status = 0,
        };
        _ = xlib.XChangeProperty(
            dsp,
            xid,
            motif_atom,
            motif_atom,
            32,
            xlib.PropModeReplace,
            std.mem.asBytes(&hints).ptr,
            5,
        );
    }

    // Resizable.
    if ((flags & @intFromEnum(OpenFlags.resizable)) == 0) {
        var size_hints: xlib.XSizeHints = undefined;
        @memset(std.mem.asBytes(&size_hints), 0);
        size_hints.flags = xlib.PMinSize | xlib.PMaxSize;
        size_hints.min_width = @as(c_int, @intCast(width_px));
        size_hints.min_height = @as(c_int, @intCast(height_px));
        size_hints.max_width = @as(c_int, @intCast(width_px));
        size_hints.max_height = @as(c_int, @intCast(height_px));
        _ = xlib.XSetWMNormalHints(dsp, xid, &size_hints);
    }

    // Fullscreen.
    if ((flags & @intFromEnum(OpenFlags.fullscreen)) != 0) {
        const net_wm_state = xlib.XInternAtom(dsp, "_NET_WM_STATE", 0);
        const net_wm_state_fullscreen = xlib.XInternAtom(dsp, "_NET_WM_STATE_FULLSCREEN", 0);
        var data: [1]c_ulong = .{net_wm_state_fullscreen};
        _ = xlib.XChangeProperty(
            dsp,
            xid,
            net_wm_state,
            xlib.XA_ATOM,
            32,
            xlib.PropModeReplace,
            std.mem.asBytes(&data).ptr,
            1,
        );
    }

    if (isVisible(config.flags)) {
        if (xlib.XMapWindow(dsp, xid) == 0) return error.MapWindowFailed;
    }

    _ = xlib.XFlush(dsp);

    // WM_DELETE_WINDOW protocol so we get ClientMessage when user closes window.
    const wm_delete_atom = xlib.XInternAtom(dsp, "WM_DELETE_WINDOW", 0);
    var proto = wm_delete_atom;
    _ = xlib.XSetWMProtocols(dsp, xid, &proto, 1);

    return Handle{ .display = dsp, .xid = xid, .wm_delete = wm_delete_atom };
}

/// Poll window messages.
pub fn pump(handle: Handle, queue: *event.Queue) void {
    const disp = handle.display;
    while (xlib.XPending(disp) != 0) {
        var ev: xlib.XEvent = undefined;
        _ = xlib.XNextEvent(disp, &ev);
        switch (ev.type) {
            xlib.ClientMessage => {
                if (@as(xlib.Atom, @intCast(ev.xclient.data.l[0])) == handle.wm_delete) {
                    _ = queue.push(.empty(.quit));
                }
            },
            xlib.KeyPress => {
                const kp: *xlib.XKeyEvent = @ptrCast(&ev);
                pushKey(queue, xlib.XLookupKeysym(kp, 0), kp.state, true);
            },
            xlib.KeyRelease => {
                const kp: *xlib.XKeyEvent = @ptrCast(&ev);
                pushKey(queue, xlib.XLookupKeysym(kp, 0), kp.state, false);
            },
            xlib.ButtonPress => {
                const bp: *xlib.XButtonEvent = @ptrCast(&ev);
                pushButton(queue, bp.button, bp.state, bp.x, bp.y, true);
            },
            xlib.ButtonRelease => {
                const bp: *xlib.XButtonEvent = @ptrCast(&ev);
                pushButton(queue, bp.button, bp.state, bp.x, bp.y, false);
            },
            xlib.MotionNotify => {
                const mp: *xlib.XMotionEvent = @ptrCast(&ev);
                pushMove(queue, mp.x, mp.y);
            },
            else => {},
        }
    }
}

/// Closes the X11 window and disconnects.
pub fn close(handle: Handle) Error!void {
    _ = xlib.XDestroyWindow(handle.display, handle.xid);
    _ = xlib.XCloseDisplay(handle.display);
}

fn isVisible(flags: OpenFlags.Mask) bool {
    return flags & @intFromEnum(OpenFlags.visible) != 0;
}

fn pushPayload(queue: *event.Queue, comptime T: type, id: event.Id, payload: T) void {
    _ = queue.push(.init(T, id, payload));
}

fn pushKey(queue: *event.Queue, key_sym: xlib.KeySym, mods_mask: c_uint, is_down: bool) void {
    const payload = input.KeyPayload{
        .key = input.Translate.keySymToKey(@intCast(key_sym)),
        .mods = input.Translate.modsFromMask(mods_mask),
        .state = if (is_down) .down else .up,
    };
    const id: event.Id = if (is_down) .key_down else .key_up;
    pushPayload(queue, input.KeyPayload, id, payload);
}

fn pushButton(queue: *event.Queue, btn_code: c_uint, mods_mask: c_uint, x_pos: c_int, y_pos: c_int, is_down: bool) void {
    const payload = input.ButtonPayload{
        .button = input.Translate.buttonCodeToButton(btn_code),
        .mods = input.Translate.modsFromMask(mods_mask),
        .state = if (is_down) .down else .up,
        .x = @intCast(x_pos),
        .y = @intCast(y_pos),
    };
    const id: event.Id = if (is_down) .button_down else .button_up;
    pushPayload(queue, input.ButtonPayload, id, payload);
}

fn pushMove(queue: *event.Queue, x_pos: c_int, y_pos: c_int) void {
    const payload = input.MovePayload{ .x = @intCast(x_pos), .y = @intCast(y_pos) };
    pushPayload(queue, input.MovePayload, .mouse_move, payload);
}
