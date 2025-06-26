const std = @import("std");

pub const stack_t = extern struct {
    ss_sp: ?*anyopaque,
    ss_flags: c_int,
    ss_size: usize,
};

pub const mcontext_t = extern struct {
    _opaque: [512]u8,
};

pub const ucontext_t = extern struct {
    uc_flags: c_ulong,
    uc_link: ?*ucontext_t,
    uc_stack: stack_t,
    uc_mcontext: mcontext_t,
    uc_sigmask: [128]u8,
};

extern "c" fn getcontext(ucp: *ucontext_t) c_int;
extern "c" fn setcontext(ucp: *const ucontext_t) c_int;
extern "c" fn makecontext(ucp: *ucontext_t, func: *const fn () callconv(.C) void, argc: c_int, ...) void;
extern "c" fn swapcontext(oucp: *ucontext_t, ucp: *const ucontext_t) c_int;
