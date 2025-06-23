const std = @import("std");
const luajit = @import("luajit");
const log = @import("logger.zig");

const Context = @import("../lua/Context.zig");

const Logger = log.Logger;
const logger_metatable_name = "f.log.Logger";

var context: *Context = undefined;

fn getLogger(L: *luajit.lua_State, index: c_int) *Logger {
    return @as(*Logger, @ptrCast(@alignCast(luajit.lua_touserdata(L, index))));
}

fn logger_info(L: ?*luajit.lua_State) callconv(.c) c_int {
    const logger = getLogger(L.?, 1);
    var len: usize = 0;
    const msg = luajit.luaL_checklstring(L.?, 2, &len);
    logger.info(msg[0..len]);
    return 0;
}

fn logger_warn(L: ?*luajit.lua_State) callconv(.c) c_int {
    const logger = getLogger(L.?, 1);
    var len: usize = 0;
    const msg = luajit.luaL_checklstring(L.?, 2, &len);
    logger.warn(msg[0..len]);
    return 0;
}

fn logger_err(L: ?*luajit.lua_State) callconv(.c) c_int {
    const logger = getLogger(L.?, 1);
    var len: usize = 0;
    const msg = luajit.luaL_checklstring(L.?, 2, &len);
    logger.err(msg[0..len]);
    return 0;
}

fn logger_gc(_: ?*luajit.lua_State) callconv(.c) c_int {
    return 0;
}

fn log_scoped(L: ?*luajit.lua_State) callconv(.c) c_int {
    var len: usize = 0;
    const scope = luajit.luaL_checklstring(L.?, 1, &len);

    const logger_ptr = @as(*Logger, @ptrCast(@alignCast(luajit.lua_newuserdata(L.?, @sizeOf(Logger)))));

    log.createInPlace(logger_ptr, context, scope[0..len]) catch {
        luajit.lua_pushstring(L.?, "failed to create logger");
        return luajit.lua_error(L.?);
    };

    luajit.luaL_setmetatable(L.?, logger_metatable_name);

    return 1;
}

pub fn register(L: *luajit.lua_State, ctx: *Context) void {
    context = ctx;

    if (luajit.luaL_newmetatable(L, logger_metatable_name) != 0) {
        const methods = [_]luajit.luaL_Reg{
            .{ .name = "info", .func = logger_info },
            .{ .name = "warn", .func = logger_warn },
            .{ .name = "err", .func = logger_err },
            .{ .name = "__gc", .func = logger_gc },
            .{ .name = null, .func = null },
        };

        luajit.lua_pushvalue(L, -1);
        luajit.lua_setfield(L, -2, "__index");

        luajit.luaL_setfuncs(L, &methods, 0);
    }
    luajit.lua_pop(L, 1);

    luajit.lua_getglobal(L, "f");
    if (luajit.lua_isnil(L, -1)) {
        luajit.lua_pop(L, 1);
        luajit.lua_newtable(L);
        luajit.lua_setglobal(L, "f");
        luajit.lua_getglobal(L, "f");
    }

    luajit.lua_newtable(L);
    const log_funcs = [_]luajit.luaL_Reg{
        .{ .name = "scoped", .func = log_scoped },
        .{ .name = null, .func = null },
    };
    luajit.luaL_setfuncs(L, &log_funcs, 0);
    luajit.lua_setfield(L, -2, "log");

    luajit.lua_pop(L, 1);
}
