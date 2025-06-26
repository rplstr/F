const std = @import("std");

const windows = std.os.windows;

pub const BOOL = windows.BOOL;
pub const HWND = windows.HWND;
pub const HRESULT = windows.HRESULT;
pub const DWORD = windows.DWORD;

pub extern "dwmapi" fn DwmSetWindowAttribute(
    hwnd: ?HWND,
    dwAttribute: DWORD,
    pvAttribute: ?*const anyopaque,
    cbAttribute: DWORD,
) HRESULT;
