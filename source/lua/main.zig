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

    const lua_script =
        \\local logger = f.log.scoped("test")
        \\logger:info("this will work")
        \\
        \\local a = 1
        \\local b = nil
        \\
        \\local c = a + b
    ;

    if (luajit.luaL_loadstring(L.?, lua_script) != 0) {
        return;
    }

    if (!err.protectedCall(L.?)) {
        return;
    }
}
