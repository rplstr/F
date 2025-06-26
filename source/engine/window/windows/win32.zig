const std = @import("std");
const builtin = @import("builtin");
const event = @import("../event.zig");

const OpenConfig = @import("../Window.zig").OpenConfig;
const OpenFlags = @import("../Window.zig").OpenFlags;

const input = @import("../../input/input.zig");

pub const Error = error{
    UnsupportedPlatform,
    TitleTooLong,
    ClassRegisterFailed,
    CreateWindowFailed,
    DestroyWindowFailed,
    InvalidHandle,
    InvalidUtf8,
};

pub const Handle = if (builtin.os.tag == .windows)
    std.os.windows.HWND
else
    void;

comptime {
    if (builtin.os.tag != .windows)
        @compileError("win32.zig is only built when targeting Windows");
}

const user32 = @import("user32.zig");
const dwmapi = @import("dwmapi.zig");

const class_name_w = std.unicode.utf8ToUtf16LeStringLiteral("Game");

/// Opens a Win32 window according to `OpenConfig`.
pub fn open(config: OpenConfig) Error!Handle {
    var title_buf: [128:0]u16 = undefined;
    const len16 = try std.unicode.utf8ToUtf16Le(&title_buf, config.title);
    if (len16 >= title_buf.len) return error.TitleTooLong;
    title_buf[len16] = 0;
    const title_w: [:0]const u16 = title_buf[0..len16 :0];

    const hinstance = user32.GetModuleHandleW(null);

    var wc: user32.WNDCLASSW = .{
        .style = user32.CS_OWNDC,
        .lpfnWndProc = wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = user32.LoadCursorW(null, user32.IDC_ARROW),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = class_name_w.ptr,
    };
    if (user32.RegisterClassW(&wc) == 0) return error.ClassRegisterFailed;

    const flags: u8 = config.flags;
    var style: user32.DWORD = 0;

    // Decoration.
    if ((flags & @intFromEnum(OpenFlags.decorated)) != 0) {
        style |= user32.WS_CAPTION | user32.WS_SYSMENU | user32.WS_MINIMIZEBOX;
    }
    // Outer border.
    if ((flags & @intFromEnum(OpenFlags.border)) != 0) {
        style |= user32.WS_BORDER;
    }
    // Resizable / Maximizable.
    if ((flags & @intFromEnum(OpenFlags.resizable)) != 0) {
        style |= user32.WS_THICKFRAME | user32.WS_MAXIMIZEBOX;
    }
    if (style == 0) {
        style = user32.WS_OVERLAPPEDWINDOW;
    }
    var width_px: user32.INT = @as(user32.INT, @intCast(config.width));
    var height_px: user32.INT = @as(user32.INT, @intCast(config.height));
    var pos_x: user32.INT = user32.CW_USEDEFAULT;
    var pos_y: user32.INT = user32.CW_USEDEFAULT;
    if ((flags & @intFromEnum(OpenFlags.fullscreen)) != 0) {
        style = user32.WS_POPUP;
        width_px = user32.GetSystemMetrics(user32.SM_CXSCREEN);
        height_px = user32.GetSystemMetrics(user32.SM_CYSCREEN);
        pos_x = 0;
        pos_y = 0;
    } else if ((flags & @intFromEnum(OpenFlags.centered)) != 0) {
        const screen_w = user32.GetSystemMetrics(user32.SM_CXSCREEN);
        const screen_h = user32.GetSystemMetrics(user32.SM_CYSCREEN);
        pos_x = @divTrunc(screen_w - width_px, 2);
        pos_y = @divTrunc(screen_h - height_px, 2);
    }
    if ((flags & @intFromEnum(OpenFlags.visible)) != 0) style |= user32.WS_VISIBLE;

    const hwnd = user32.CreateWindowExW(
        0,
        class_name_w.ptr,
        title_w.ptr,
        style,
        pos_x,
        pos_y,
        width_px,
        height_px,
        null,
        null,
        hinstance,
        null,
    );
    if (hwnd == null) return error.CreateWindowFailed;

    setImmersiveDarkMode(hwnd.?);

    return hwnd.?;
}

/// Destroy a previously created window handle.
pub fn close(hwnd: Handle) Error!void {
    if (user32.DestroyWindow(hwnd) == 0) return error.DestroyWindowFailed;
}

/// Poll window messages.
pub fn pump(_: Handle, queue: *event.Queue) void {
    var msg: user32.MSG = undefined;
    while (user32.PeekMessageW(&msg, null, 0, 0, user32.PM_REMOVE) != 0) {
        switch (msg.message) {
            user32.WM_QUIT, user32.WM_CLOSE => {
                _ = queue.push(.empty(.quit));
            },
            // Keyboard
            user32.WM_KEYDOWN => {
                pushKey(queue, @intCast(msg.wParam), true);
            },
            user32.WM_KEYUP => {
                pushKey(queue, @intCast(msg.wParam), false);
            },
            // Mouse buttons
            user32.WM_LBUTTONDOWN, user32.WM_RBUTTONDOWN, user32.WM_MBUTTONDOWN => |msg_id| {
                const btn: input.Button = switch (msg_id) {
                    user32.WM_LBUTTONDOWN => .left,
                    user32.WM_RBUTTONDOWN => .right,
                    else => .middle,
                };
                const x = @as(i16, @intCast(msg.lParam & 0xFFFF));
                const y = @as(i16, @intCast((msg.lParam >> 16) & 0xFFFF));
                pushButton(queue, btn, x, y, true);
            },
            user32.WM_LBUTTONUP, user32.WM_RBUTTONUP, user32.WM_MBUTTONUP => |msg_id| {
                const btn: input.Button = switch (msg_id) {
                    user32.WM_LBUTTONUP => .left,
                    user32.WM_RBUTTONUP => .right,
                    else => .middle,
                };
                const x = @as(i16, @intCast(msg.lParam & 0xFFFF));
                const y = @as(i16, @intCast((msg.lParam >> 16) & 0xFFFF));
                pushButton(queue, btn, x, y, false);
            },
            user32.WM_MOUSEMOVE => {
                const x = @as(i16, @intCast(msg.lParam & 0xFFFF));
                const y = @as(i16, @intCast((msg.lParam >> 16) & 0xFFFF));
                pushMove(queue, x, y);
            },
            else => {
                _ = user32.TranslateMessage(&msg);
                _ = user32.DispatchMessageW(&msg);
            },
        }
    }
}

fn wndProc(
    hwnd: user32.HWND,
    msg: user32.UINT,
    wparam: user32.WPARAM,
    lparam: user32.LPARAM,
) callconv(.winapi) user32.LRESULT {
    return switch (msg) {
        user32.WM_DESTROY => blk: {
            _ = user32.PostQuitMessage(0);
            break :blk 0;
        },
        else => user32.DefWindowProcW(hwnd, msg, wparam, lparam),
    };
}

fn pushPayload(queue: *event.Queue, comptime T: type, id: event.Id, payload: T) void {
    _ = queue.push(.init(T, id, payload));
}

fn pushKey(queue: *event.Queue, vk: u32, is_down: bool) void {
    const payload = input.KeyPayload{
        .key = input.Translate.vkToKey(vk),
        .mods = .{},
        .state = if (is_down) .down else .up,
    };
    const id: event.Id = if (is_down) .key_down else .key_up;
    pushPayload(queue, input.KeyPayload, id, payload);
}

fn pushButton(queue: *event.Queue, btn: input.Button, x: i16, y: i16, is_down: bool) void {
    const payload = input.ButtonPayload{
        .button = btn,
        .mods = .{},
        .state = if (is_down) .down else .up,
        .x = x,
        .y = y,
    };
    const id: event.Id = if (is_down) .button_down else .button_up;
    pushPayload(queue, input.ButtonPayload, id, payload);
}

fn pushMove(queue: *event.Queue, x: i16, y: i16) void {
    const mov = input.MovePayload{ .x = x, .y = y };
    pushPayload(queue, input.MovePayload, .mouse_move, mov);
}

fn setImmersiveDarkMode(hwnd: user32.HWND) void {
    const DWMWA_USE_IMMERSIVE_DARK_MODE_BEFORE_20: dwmapi.DWORD = 19; // 1809
    const DWMWA_USE_IMMERSIVE_DARK_MODE: dwmapi.DWORD = 20; // 1903+

    var enable: dwmapi.BOOL = 1; // TRUE

    const hr_new = dwmapi.DwmSetWindowAttribute(
        hwnd,
        DWMWA_USE_IMMERSIVE_DARK_MODE,
        &enable,
        @sizeOf(dwmapi.BOOL),
    );

    if (hr_new != 0) {
        _ = dwmapi.DwmSetWindowAttribute(
            hwnd,
            DWMWA_USE_IMMERSIVE_DARK_MODE_BEFORE_20,
            &enable,
            @sizeOf(dwmapi.BOOL),
        );
    }
}
