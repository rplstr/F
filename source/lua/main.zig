const std = @import("std");
const luajit = @import("luajit");
const engine = @import("f");

const lua = engine.lua;
const err = lua.err;

const Context = lua.Context;

const logFn = engine.logger.stdLogFn;

pub const std_options: std.Options = .{
    .logFn = logFn,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var context = Context.init(allocator);
    defer context.deinit();

    const L = luajit.luaL_newstate();
    defer luajit.lua_close(L);
    luajit.luaL_openlibs(L);

    var registry = lua.registry.init();

    lua.interfaces.log.register(&registry, L.?, &context);

    try lua.registry.generate(&registry, allocator, "meta");

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
