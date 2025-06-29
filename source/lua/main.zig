const std = @import("std");
const luajit = @import("luajit");
const engine = @import("f");
const vulkan = engine.vulkan;
const Shader = vulkan.Shader;

const lua = engine.lua;
const err = lua.err;
const input = engine.input;
const ecs = engine.ecs;

const Context = lua.Context;

pub const Position = struct {
    x: f32 = 0,
    y: f32 = 0,
};

const World = engine.ecs.World(.{
    .cap = 1024,
    .max_obs = 64,
    .max_sys = 256,
    .max_cmd = 4096,
    .stage_bytes = 16 * 1024,
    .max_comp = 128,
    .arena_bytes = 128 * 1024,
});

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

    var world: World = .{};
    world.init();

    var input_context = input.Context{};

    var job_system = try engine.job.init(allocator);
    defer job_system.deinit();

    var loader = try vulkan.Loader.init();
    defer loader.deinit();

    const instance = try vulkan.Instance.create(loader, .{ .app = "FEngine" });
    defer instance.destroy(loader);

    const device = try vulkan.Device.create(&loader, instance, .{ .queue_priority = 1.0, .req = .{ .graphics = false } });
    defer device.destroy(&loader, instance);

    const L = luajit.luaL_newstate();
    defer luajit.lua_close(L);
    luajit.luaL_openlibs(L);

    var registry = lua.registry.init();
    const EcsInterface = lua.interfaces.ecs.interface(*World);

    _ = EcsInterface.registerComponent(Position);

    EcsInterface.register(&registry, L.?, &world);
    lua.interfaces.log.register(&registry, L.?, &log_context);
    lua.interfaces.input.register(&registry, L.?, &input_context);
    lua.interfaces.event.register(&registry, L.?);

    lua.interfaces.job.Interface.register(&registry, L.?, job_system);

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

    while (true) update(window, &queue, &input_context, &world, L.?) catch |e| {
        if (e == error.Quit) break;
    };
}

fn update(window: engine.Window.Handle, queue: *engine.event.Queue, input_context: *engine.input.Context, world: *World, L: *luajit.lua_State) !void {
    engine.Window.pump(window, queue);

    while (queue.pop()) |ev| {
        input_context.handleEvent(ev);

        switch (ev.id) {
            .quit => return error.Quit,
            else => {},
        }
    }

    _ = luajit.lua_getglobal(L, "Update");
    if (luajit.lua_isfunction(L, -1) != false) {
        err.protectedCall(L, 0, 0) catch {};
    } else {
        luajit.lua_pop(L, 1);
    }

    world.runFrame(0.016);

    std.Thread.sleep(16 * std.time.ns_per_ms);
}
