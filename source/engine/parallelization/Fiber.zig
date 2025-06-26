const std = @import("std");
const builtin = @import("builtin");
const c = @cImport({});

const libc = if (builtin.os.tag != .windows) @import("libc.zig") else struct {};

pub const Handle = ?*anyopaque;

pub const StartFn = *const fn (?*anyopaque) callconv(.c) void;

pub fn current() Handle {
    return current_fiber;
}

/// Converts the calling thread to a scheduler fiber. Must be called once per-thread before any
/// call to `switch` or `init`.
pub fn convertThread() !Handle {
    if (current_fiber) |_| return current_fiber;

    if (builtin.os.tag == .windows) {
        const kernel32 = @import("kernel32.zig");
        const handle = kernel32.ConvertThreadToFiberEx(null, 0) orelse return error.FiberConvertFailed;
        current_fiber = handle;
        return handle;
    } else {
        // allocate scheduler context for current thread
        var sched = std.heap.c_allocator.create(PosixFiber) catch return error.FiberConvertFailed;
        sched.* = .{
            .ctx = undefined,
            .stack = &[_]u8{},
            .start = undefined,
            .arg = null,
            .parent = null,
        };
        if (libc.getcontext(&sched.ctx) != 0) return error.FiberConvertFailed;
        current_fiber = @ptrCast(sched);
        return current_fiber;
    }
}

/// Creates a new fiber that will start executing `start(arg)` the first time it is switched to.
/// `stack_bytes` is a hint. Windows commits lazily so we use it for both commit/reserve sizes.
pub fn init(start: StartFn, arg: ?*anyopaque, stack_bytes: usize) !Handle {
    if (builtin.os.tag == .windows) {
        const kernel32 = @import("kernel32.zig");
        const handle = kernel32.CreateFiberEx(stack_bytes, stack_bytes, 0, start, arg) orelse {
            return error.FiberCreateFailed;
        };
        return handle;
    } else {
        var fib = std.heap.c_allocator.create(PosixFiber) catch return error.FiberCreateFailed;
        fib.stack = try std.heap.c_allocator.alloc(u8, stack_bytes);
        fib.start = start;
        fib.arg = arg;
        fib.parent = current_fiber;
        if (libc.getcontext(&fib.ctx) != 0) return error.FiberCreateFailed;
        fib.ctx.uc_stack.ss_sp = fib.stack.ptr;
        fib.ctx.uc_stack.ss_size = stack_bytes;
        fib.ctx.uc_link = null;

        const tramp = @as(*const fn (usize) callconv(.c) void, @ptrCast(&posixTrampoline));
        libc.makecontext(&fib.ctx, tramp, 1, @intFromPtr(fib));
        return @ptrCast(fib);
    }
}

/// Switches execution to the given fiber. The current fiber will resume when another fiber
/// switches back to it.
pub fn switchTo(to: Handle) void {
    if (to == null) return;
    if (builtin.os.tag == .windows) {
        const kernel32 = @import("kernel32.zig");
        const prev = current_fiber;
        current_fiber = to;
        kernel32.SwitchToFiber(to.?);
        current_fiber = prev;
    } else {
        const prev = current_fiber;
        current_fiber = to;
        const prev_f = @as(*PosixFiber, @ptrCast(prev.?));
        const to_f = @as(*PosixFiber, @ptrCast(to.?));
        _ = libc.swapcontext(&prev_f.ctx, &to_f.ctx);
        // when swap returns we are back
        current_fiber = prev;
    }
}

/// Destroys a fiber created with `init`. It must not be the currently running fiber.
pub fn destroy(fiber: Handle) void {
    if (fiber == null) return;
    if (fiber == current_fiber) @panic("Cannot destroy current fiber");
    if (builtin.os.tag == .windows) {
        const kernel32 = @import("kernel32.zig");
        kernel32.DeleteFiber(fiber.?);
    } else {
        const pf = @as(*PosixFiber, @ptrCast(fiber.?));
        std.heap.c_allocator.free(pf.stack);
        std.heap.c_allocator.destroy(pf);
    }
}

threadlocal var current_fiber: Handle = null;

pub const Error = error{
    FiberConvertFailed,
    FiberCreateFailed,
    Unsupported,
};

const PosixFiber = struct {
    ctx: libc.ucontext_t,
    stack: []u8,
    start: StartFn,
    arg: ?*anyopaque,
    parent: Handle,
};

fn posixTrampoline(arg_raw: usize) callconv(.c) void {
    const pf: *PosixFiber = @ptrFromInt(arg_raw);
    pf.start(pf.arg);
    switchTo(pf.parent);
    unreachable;
}
