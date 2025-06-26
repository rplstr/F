const std = @import("std");

const luajit = @import("luajit");
const registry = @import("../lua/registry.zig");
const err = @import("../lua/err.zig");

const JobSystem = @import("JobSystem.zig");
const Handle = @import("job/Handle.zig");
const Job = @import("job/Job.zig");

pub const Interface = struct {
    var js_ptr: *JobSystem = undefined;
    var lua_vm: *luajit.lua_State = undefined;

    pub fn register(r: *registry.Registry, L: *luajit.lua_State, js: *JobSystem) void {
        js_ptr = js;
        lua_vm = L;
        r.registerModule(L, &job_module);
    }

    fn packHandle(h: Handle) u64 {
        return (@as(u64, h.generation) << 32) | @as(u64, h.index);
    }

    fn unpackHandle(v: u64) Handle {
        return .{ .index = @intCast(v & 0xFFFF_FFFF), .generation = @intCast(v >> 32) };
    }

    fn pushHandle(L: *luajit.lua_State, h: Handle) void {
        luajit.lua_pushinteger(L, @intCast(packHandle(h)));
    }

    fn checkHandle(L: *luajit.lua_State, n: c_int) Handle {
        const v = @as(u64, @intCast(luajit.luaL_checkinteger(L, n)));
        return unpackHandle(v);
    }

    fn jobRun(L_opt: ?*luajit.lua_State) callconv(.c) c_int {
        const L = L_opt.?;
        luajit.luaL_checktype(L, 1, luajit.LUA_TFUNCTION);

        var high: bool = false;
        if (luajit.lua_gettop(L) >= 2) {
            high = (luajit.lua_toboolean(L, 2) != 0);
        }

        luajit.lua_pushvalue(L, 1);
        const ref_id = luajit.luaL_ref(L, luajit.LUA_REGISTRYINDEX);

        var ctx = LuaJobCtx{ .ref = ref_id };
        const data = @as([*]const u8, @ptrCast(&ctx))[0..@sizeOf(LuaJobCtx)];

        const handle_opt = js_ptr.createJob(luaJobTask, Handle.invalid, data);
        if (handle_opt) |h| {
            if (high) js_ptr.runHigh(h) else js_ptr.run(h);
            pushHandle(L, h);
            return 1;
        }

        luajit.luaL_unref(L, luajit.LUA_REGISTRYINDEX, ref_id);
        luajit.lua_pushnil(L);
        return 1;
    }

    fn jobWait(L_opt: ?*luajit.lua_State) callconv(.c) c_int {
        const L = L_opt.?;
        const h = checkHandle(L, 1);
        js_ptr.wait(h);
        return 0;
    }

    const LuaJobCtx = struct { ref: c_int };

    fn luaJobTask(_: *anyopaque, current_job: *Job) void {
        const ctx = std.mem.bytesToValue(LuaJobCtx, current_job.data[0..@sizeOf(LuaJobCtx)]);
        const L = lua_vm;

        luajit.lua_rawgeti(L, luajit.LUA_REGISTRYINDEX, ctx.ref);
        _ = err.protectedCall(L, 0, 0) catch {};
        luajit.luaL_unref(L, luajit.LUA_REGISTRYINDEX, ctx.ref);
    }

    const job_module = registry.Module{
        .name = "job",
        .functions = &[_]registry.Function{
            .{ .name = "run", .func = jobRun, .doc_string = "Run Lua callback asynchronously using worker pool. Returns job handle.", .params = &[_]registry.Parameter{ .{ .name = "callback", .type_name = "function" }, .{ .name = "high", .type_name = "boolean", .doc_string = "High-priority flag" } }, .returns = &[_]registry.Parameter{.{ .name = "handle", .type_name = "number" }} },
            .{ .name = "wait", .func = jobWait, .doc_string = "Suspend coroutine until the given job completes.", .params = &[_]registry.Parameter{.{ .name = "handle", .type_name = "number" }}, .returns = &[_]registry.Parameter{} },
        },
    };
};

pub fn register(r: *registry.Registry, L: *luajit.lua_State, js: *JobSystem) void {
    Interface.register(r, L, js);
}
