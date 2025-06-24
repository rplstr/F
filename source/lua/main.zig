const std = @import("std");
const luajit = @import("luajit");
const engine = @import("f");

const lua = engine.lua;
const err = lua.err;
const input = engine.input;

const Context = lua.Context;

const logFn = engine.logger.stdLogFn;

pub const std_options: std.Options = .{
    .logFn = logFn,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var log_context = Context.init(allocator);
    defer log_context.deinit();

    var input_context = input.Context{};

    const L = luajit.luaL_newstate();
    defer luajit.lua_close(L);
    luajit.luaL_openlibs(L);

    var registry = lua.registry.init();

    lua.interfaces.log.register(&registry, L.?, &log_context);
    lua.interfaces.input.register(&registry, L.?, &input_context);
    lua.interfaces.event.register(&registry, L.?);

    try lua.registry.generate(&registry, allocator, "meta");

    const window = try engine.Window.open(.{
        .title = "Hello World",
        .width = 800,
        .height = 600,
        .flags = engine.Window.OpenFlags.mask(.{ .visible, .decorated, .border, .resizable }),
    });
    defer engine.Window.close(window) catch {};

    if (luajit.luaL_loadfile(L, "source/lua/main.lua") != 0) {
        const error_msg_ptr = luajit.lua_tolstring(L, -1, null);
        const error_msg = if (error_msg_ptr) |ptr| std.mem.sliceTo(ptr, 0) else "unknown error";
        std.log.err("failed to load script: {s}", .{error_msg});
        luajit.lua_pop(L, 1);
    } else {
        err.protectedCall(L.?, 0, 0) catch {};
    }

    var queue: engine.event.Queue = .{};

    while (true) update(window, &queue, &input_context, L.?) catch |e| {
        if (e == error.Quit) break;
    };
}

fn update(window: engine.Window.Handle, queue: *engine.event.Queue, input_context: *engine.input.Context, L: *luajit.lua_State) !void {
    engine.Window.pump(window, queue);

    while (queue.pop()) |ev| {
        input_context.handleEvent(ev);

        switch (ev.id) {
            .quit => return error.Quit,
            else => {},
        }
    }

    _ = luajit.lua_getglobal(L, "update");
    if (luajit.lua_isfunction(L, -1) != false) {
        err.protectedCall(L, 0, 0) catch {};
    } else {
        luajit.lua_pop(L, 1);
    }

    std.Thread.sleep(16 * std.time.ns_per_ms);
}
