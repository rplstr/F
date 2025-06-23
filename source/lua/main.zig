const std = @import("std");
const luajit = @import("luajit");
const engine = @import("f");
const lua = engine.lua;
const Context = lua.Context;

const err = lua.err;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var context = Context.init(allocator);
    defer context.deinit();

    const L = luajit.luaL_newstate();
    defer luajit.lua_close(L);
    luajit.luaL_openlibs(L);

    lua.interfaces.log.register(L.?, &context);

    if (luajit.luaL_loadfile(L, "source/lua/main.lua") != 0) {
        const error_msg_ptr = luajit.lua_tolstring(L, -1, null);
        const error_msg = if (error_msg_ptr) |ptr| std.mem.sliceTo(ptr, 0) else "unknown error";
        std.log.err("failed to load script: {s}", .{error_msg});
        luajit.lua_pop(L, 1);
    } else {
        err.protectedCall(L.?, 0, 0) catch {};
    }

    std.log.info("done", .{});
}
