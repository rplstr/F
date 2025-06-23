const std = @import("std");
const luajit = @import("luajit");
const tty = std.io.tty;

pub const GlobalErrorContext = struct {
    last_zig_stack: ?std.builtin.StackTrace = null,
};

pub var error_context: GlobalErrorContext = .{};
threadlocal var stack_buffer: [128]usize = undefined;

/// A wrapper around lua_pcall that uses `panicHandler`.
pub fn protectedCall(L: *luajit.lua_State) bool {
    var stack_trace = std.builtin.StackTrace{
        .instruction_addresses = &stack_buffer,
        .index = 0,
    };
    std.debug.captureStackTrace(null, &stack_trace);
    error_context.last_zig_stack = stack_trace;

    const original_stack_top = luajit.lua_gettop(L);
    luajit.lua_pushcfunction(L, panicHandler);
    luajit.lua_insert(L, original_stack_top);

    const script_index = original_stack_top + 1;
    const result = luajit.lua_pcall(L, luajit.lua_gettop(L) - script_index, 0, original_stack_top);

    luajit.lua_remove(L, original_stack_top);

    return result == 0;
}

/// This is the function that Lua calls when a panic occurs.
pub fn panicHandler(L_opt: ?*luajit.lua_State) callconv(.c) c_int {
    const L = L_opt orelse return 1;
    const stderr = std.io.getStdErr();
    const tty_config = tty.detectConfig(stderr);
    const writer = stderr.writer();

    tty_config.setColor(writer, .red) catch {};
    writer.print("thread {any} panic:\n", .{std.Thread.getCurrentId()}) catch {};
    tty_config.setColor(writer, .reset) catch {};

    luajit.lua_getglobal(L, "debug");
    luajit.lua_getfield(L, -1, "traceback");
    luajit.lua_pushvalue(L, -3);
    luajit.lua_pushinteger(L, 2);
    luajit.lua_call(L, 2, 1);

    var trace_len: usize = 0;
    const trace_str = luajit.lua_tolstring(L, -1, &trace_len);

    if (trace_str) |s| {
        writer.writeAll(s[0..trace_len]) catch {};
    }
    writer.writeAll("\n") catch {};

    if (error_context.last_zig_stack) |stack| {
        writer.writeAll("\n") catch {};

        std.debug.dumpStackTrace(stack);
    }

    return 1;
}
