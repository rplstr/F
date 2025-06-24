//! Thin Win32 API layer.
const std = @import("std");
const builtin = @import("builtin");

pub const windows = std.os.windows;

pub const BOOL = windows.BOOL;
pub const UINT = windows.UINT;
pub const DWORD = windows.DWORD;
pub const INT = windows.INT;
pub const LRESULT = windows.LRESULT;
pub const ATOM = windows.ATOM;
pub const WPARAM = windows.WPARAM;
pub const LPARAM = windows.LPARAM;

pub const HWND = windows.HWND;
pub const HINSTANCE = windows.HINSTANCE;
pub const HCURSOR = windows.HCURSOR;
pub const HICON = windows.HICON;
pub const HBRUSH = windows.HBRUSH;
pub const HMENU = windows.HMENU;

pub const CS_OWNDC: UINT = 0x0020;
pub const WS_OVERLAPPEDWINDOW: DWORD = 0x00cf0000;
/// Style bits.
pub const WS_OVERLAPPED: DWORD = 0x00000000;
pub const WS_POPUP: DWORD = 0x80000000;
pub const WS_CAPTION: DWORD = 0x00C00000;
pub const WS_SYSMENU: DWORD = 0x00080000;
/// Also called `WS_SIZEBOX`.
pub const WS_THICKFRAME: DWORD = 0x00040000;
pub const WS_SIZEBOX: DWORD = WS_THICKFRAME;
pub const WS_MINIMIZEBOX: DWORD = 0x00020000;
pub const WS_MAXIMIZEBOX: DWORD = 0x00010000;
pub const WS_BORDER: DWORD = 0x00800000;
pub const WS_VISIBLE: DWORD = 0x10000000;
pub const CW_USEDEFAULT: INT = @bitCast(@as(u32, 0x80000000));

// Message queue removal flag.
pub const PM_REMOVE: UINT = 0x0001;
/// `MAKEINTRESOURCEW(32512)`.
pub const IDC_ARROW = @as([*:0]const u16, @ptrFromInt(32512));

/// Called `DestroyWindow(hwnd)`.
pub const WM_DESTROY: UINT = 0x0002;
/// Called `PostQuitMessage(exit)`.
pub const WM_QUIT: UINT = 0x0012;
/// Pressed Close Button (X) / Alt+F4 / "Close" in context menu.
pub const WM_CLOSE: UINT = 0x0010;

pub const WM_KEYDOWN: UINT = 0x0100;
pub const WM_KEYUP: UINT = 0x0101;

pub const WM_MOUSEMOVE: UINT = 0x0200;
pub const WM_LBUTTONDOWN: UINT = 0x0201;
pub const WM_LBUTTONUP: UINT = 0x0202;
pub const WM_RBUTTONDOWN: UINT = 0x0204;
pub const WM_RBUTTONUP: UINT = 0x0205;
pub const WM_MBUTTONDOWN: UINT = 0x0207;
pub const WM_MBUTTONUP: UINT = 0x0208;

pub const MSG = extern struct {
    hwnd: ?HWND,
    message: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
    time: DWORD,
    pt: extern struct {
        x: windows.LONG,
        y: windows.LONG,
    },
};

/// Indices for GetSystemMetrics.
pub const SM_CXSCREEN: c_int = 0;
pub const SM_CYSCREEN: c_int = 1;

pub const WNDPROC = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;

pub const WNDCLASSW = extern struct {
    style: UINT,
    lpfnWndProc: WNDPROC,
    cbClsExtra: INT,
    cbWndExtra: INT,
    hInstance: ?HINSTANCE,
    hIcon: ?HICON,
    hCursor: ?HCURSOR,
    hbrBackground: ?HBRUSH,
    lpszMenuName: ?[*:0]const u16,
    lpszClassName: [*:0]const u16,
};

pub extern "kernel32" fn GetModuleHandleW(lpModuleName: ?[*:0]const u16) ?HINSTANCE;
pub extern "user32" fn RegisterClassW(lpWndClass: *const WNDCLASSW) ATOM;
pub extern "user32" fn CreateWindowExW(
    dwExStyle: DWORD,
    lpClassName: [*:0]const u16,
    lpWindowName: [*:0]const u16,
    dwStyle: DWORD,
    X: INT,
    Y: INT,
    nWidth: INT,
    nHeight: INT,
    hWndParent: ?HWND,
    hMenu: ?HMENU,
    hInstance: ?HINSTANCE,
    lpParam: ?*anyopaque,
) ?HWND;
pub extern "user32" fn DestroyWindow(hWnd: HWND) BOOL;
pub extern "user32" fn DefWindowProcW(hWnd: HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) LRESULT;
pub extern "user32" fn LoadCursorW(hInstance: ?HINSTANCE, lpCursorName: [*:0]const u16) ?HCURSOR;
pub extern "user32" fn PostQuitMessage(nExitCode: INT) void;
pub extern "user32" fn GetSystemMetrics(nIndex: c_int) INT;
pub extern "user32" fn PeekMessageW(lpMsg: *MSG, hWnd: ?HWND, wMsgFilterMin: UINT, wMsgFilterMax: UINT, wRemoveMsg: UINT) BOOL;
pub extern "user32" fn TranslateMessage(lpMsg: *const MSG) BOOL;
pub extern "user32" fn DispatchMessageW(lpMsg: *const MSG) LRESULT;
