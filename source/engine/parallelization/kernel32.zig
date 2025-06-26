const std = @import("std");
const windows = std.os.windows;

const LPVOID = windows.LPVOID;
const SIZE_T = windows.SIZE_T;
const DWORD = windows.DWORD;
const BOOL = windows.BOOL;

pub const PFIBER_START_ROUTINE = *const fn (?*anyopaque) callconv(.winapi) void;

/// https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-convertthreadtofiberex
pub extern "kernel32" fn ConvertThreadToFiberEx(lpParameter: ?*anyopaque, dwFlags: DWORD) callconv(.winapi) ?LPVOID;

/// https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-convertfibertothread
pub extern "kernel32" fn ConvertFiberToThread() callconv(.winapi) BOOL;

/// https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-createfiberex
pub extern "kernel32" fn CreateFiberEx(dwStackCommitSize: SIZE_T, dwStackReserveSize: SIZE_T, dwFlags: DWORD, lpStartAddress: PFIBER_START_ROUTINE, lpParameter: ?*anyopaque) callconv(.winapi) ?LPVOID;

/// https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-switchtofiber
pub extern "kernel32" fn SwitchToFiber(lpFiber: LPVOID) callconv(.winapi) void;

/// https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-deletefiber
pub extern "kernel32" fn DeleteFiber(lpFiber: LPVOID) callconv(.winapi) void;
