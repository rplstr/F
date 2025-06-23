const std = @import("std");
const luajit = @import("luajit");
const tty = std.io.tty;

/// A wrapper around lua_pcall.
/// If the call fails, it returns an error containing the formatted message.
pub fn protectedCall(L: *luajit.lua_State, nargs: c_int, nresults: c_int) !void {
    // The message handler is pushed onto the stack before the function to be called.
    const message_handler_index = luajit.lua_gettop(L) - nargs;
    luajit.lua_pushcfunction(L, messageHandler);
    luajit.lua_insert(L, message_handler_index);

    const result = luajit.lua_pcall(L, nargs, nresults, message_handler_index);

    luajit.lua_remove(L, message_handler_index);

    if (result == luajit.LUA_OK) {
        return;
    }

    // On error, the message handler will have left a formatted string on the stack.
    defer luajit.lua_pop(L, 1); // Stack should be clean after we're done.

    const error_msg_ptr = luajit.lua_tolstring(L, -1, null);
    const error_message = if (error_msg_ptr) |ptr| std.mem.sliceTo(ptr, 0) else "unknown lua error";

    const stderr = std.io.getStdErr();
    const tty_config = std.io.tty.detectConfig(stderr);
    const writer = stderr.writer();

    tty_config.setColor(writer, .red) catch {};
    writer.writeAll("looks like an error occured!\nyou can continue the game but it is not recommended as the application could be in an unstable state\n") catch {};
    writer.print("thread {any} lua runtime error:\n", .{std.Thread.getCurrentId()}) catch {};
    tty_config.setColor(writer, .reset) catch {};
    writer.writeAll(error_message) catch {};
    writer.writeAll("\n") catch {};

    return error.LuaScriptError;
}

fn messageHandler(L_opt: ?*luajit.lua_State) callconv(.c) c_int {
    const L = L_opt orelse return 1;

    // We expect the original error object to be on the top of the stack.
    luajit.lua_getglobal(L, "debug");
    luajit.lua_getfield(L, -1, "traceback");
    luajit.lua_pushvalue(L, -3); // Push the original error object.
    luajit.lua_pushinteger(L, 2); // Start traceback at level 2 (skip this C func).
    luajit.lua_call(L, 2, 1); // This call replaces the error object with the formatted traceback string.

    return 1;
}
