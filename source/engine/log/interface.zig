const registry = @import("../lua/registry.zig");

const luajit = @import("luajit");
const log = @import("logger.zig");

const Context = @import("../lua/Context.zig").Context;

var context: *Context = undefined;

const logger_class_name = "f.log.Logger";

/// Registers the log module and Logger class with the Lua registry.
pub fn register(r: *registry.Registry, L: *luajit.lua_State, ctx: *Context) void {
    context = ctx;
    r.registerModule(L, &log_module);
    r.registerClass(L, &logger_class);
}

fn checkString(L: *luajit.lua_State, n: c_int) []const u8 {
    var len: usize = 0;
    const ptr = luajit.luaL_checklstring(L, n, &len);
    return ptr[0..len];
}

fn getLogger(L: *luajit.lua_State) *log.Logger {
    const ptr = luajit.luaL_checkudata(L, 1, logger_class_name);
    return @as(*log.Logger, @alignCast(@ptrCast(ptr)));
}

/// Log an info message. This log level is intended to be used for
/// general messages about the state.
fn loggerInfo(L: ?*luajit.lua_State) callconv(.c) c_int {
    const logger = getLogger(L.?);
    const message = checkString(L.?, 2);
    logger.info(message);
    return 0;
}

/// Log a warning message. This log level is intended to be used if
/// it is uncertain whether something has gone wrong or not, but the
/// circumstances would be worth investigating.
fn loggerWarn(L: ?*luajit.lua_State) callconv(.c) c_int {
    const logger = getLogger(L.?);
    const message = checkString(L.?, 2);
    logger.warn(message);
    return 0;
}

/// Log an error message. This log level is intended to be used
/// when something has gone wrong. This might be recoverable or not.
fn loggerErr(L: ?*luajit.lua_State) callconv(.c) c_int {
    const logger = getLogger(L.?);
    const message = checkString(L.?, 2);
    logger.err(message);
    return 0;
}

const logger_class = registry.Class{
    .name = logger_class_name,
    .methods = &[_]registry.Function{
        .{
            .name = "info",
            .func = loggerInfo,
            .doc_string = "Log an info message. This log level is intended to be used for general messages about the state.",
            .params = &[_]registry.Parameter{
                .{ .name = "self", .type_name = logger_class_name },
                .{ .name = "message", .type_name = "string", .doc_string = "The message to log." },
            },
        },
        .{
            .name = "warn",
            .func = loggerWarn,
            .doc_string = "Log a warning message. This log level is intended to be used if it is uncertain whether something has gone wrong or not, but the circumstances would be worth investigating.",
            .params = &[_]registry.Parameter{
                .{ .name = "self", .type_name = logger_class_name },
                .{ .name = "message", .type_name = "string", .doc_string = "The message to log." },
            },
        },
        .{
            .name = "err",
            .func = loggerErr,
            .doc_string = "Log an error message. This log level is intended to be used when something has gone wrong. This might be recoverable or not.",
            .params = &[_]registry.Parameter{
                .{ .name = "self", .type_name = logger_class_name },
                .{ .name = "message", .type_name = "string", .doc_string = "The message to log." },
            },
        },
    },
};

/// Creates a new logger instance with the given scope. It is idiomatic
/// to create one logger per logical module or feature and reuse it.
fn logNew(L: ?*luajit.lua_State) callconv(.c) c_int {
    const scope = checkString(L.?, 1);
    const ptr = luajit.lua_newuserdata(L.?, @sizeOf(log.Logger));
    const logger_ptr = @as(*log.Logger, @alignCast(@ptrCast(ptr)));
    luajit.luaL_getmetatable(L.?, logger_class_name);
    _ = luajit.lua_setmetatable(L.?, -2);

    log.createInPlace(logger_ptr, context, scope) catch return 0;

    return 1;
}

const log_module = registry.Module{
    .name = "log",
    .functions = &[_]registry.Function{
        .{
            .name = "new",
            .func = logNew,
            .doc_string = "Creates a new logger instance with the given scope. It is idiomatic to create one logger per logical module or feature and reuse it.",
            .params = &[_]registry.Parameter{
                .{ .name = "scope", .type_name = "string", .doc_string = "The scope to associate with the logger." },
            },
            .returns = &[_]registry.Parameter{
                .{ .name = "logger", .type_name = logger_class_name, .doc_string = "A new logger instance." },
            },
        },
    },
};
