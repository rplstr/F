const std = @import("std");
const luajit = @import("luajit");
const registry = @import("../lua/registry.zig");
const core = @import("core.zig");

/// Registers the `f.event` module and the `EventKind` enum.
/// Must be called once during engine boot after Lua VM is ready.
pub fn register(r: *registry.Registry, L: *luajit.lua_State) void {
    r.registerEnum(&event_kind_enum);
    r.registerModule(L, &event_module);
    buildKindTable(L);
}

/// Copy queued events to Lua table. Returns that table.
fn poll(L_opt: ?*luajit.lua_State) callconv(.c) c_int {
    const L = L_opt.?;
    var buffer: [core.queue_capacity]core.Event = undefined;
    const cnt = core.drainTo(&buffer);

    luajit.lua_createtable(L, @intCast(cnt), 0);
    var i: u16 = 0;
    while (i < cnt) : (i += 1) {
        pushEventTable(L, &buffer[i]);
        luajit.lua_rawseti(L, -2, i + 1);
    }
    return 1;
}

fn pushEventTable(L: *luajit.lua_State, ev: *const core.Event) void {
    luajit.lua_createtable(L, 0, 5);
    luajit.lua_pushinteger(L, @intCast(@intFromEnum(ev.kind)));
    luajit.lua_setfield(L, -2, "kind");

    const bytes = ev.payload.data;
    inline for (0..4) |idx| {
        const start = idx * 4;
        const val = std.mem.readInt(u32, bytes[start .. start + 4], .little);
        luajit.lua_pushinteger(L, val);
        const field_name = switch (idx) {
            0 => "p0",
            1 => "p1",
            2 => "p2",
            else => "p3",
        };
        luajit.lua_setfield(L, -2, field_name);
    }
}

fn buildEnumFieldArray(comptime E: type) [std.meta.fields(E).len]registry.EnumField {
    const n = std.meta.fields(E).len;
    var arr: [n]registry.EnumField = undefined;
    inline for (std.meta.fields(E), 0..) |f, idx| {
        arr[idx] = .{ .name = f.name, .value = @as(i64, @intCast(f.value)) };
    }
    return arr;
}

fn buildKindTable(L: *luajit.lua_State) void {
    luajit.lua_getglobal(L, "f");
    if (luajit.lua_isnil(L, -1) != false) {
        luajit.lua_pop(L, 1);
        luajit.lua_newtable(L);
        luajit.lua_setglobal(L, "f");
        luajit.lua_getglobal(L, "f");
    }
    luajit.lua_getfield(L, -1, "event");
    if (luajit.lua_isnil(L, -1) != false) {
        luajit.lua_pop(L, 1);
        luajit.lua_newtable(L);
        luajit.lua_setfield(L, -2, "event");
        luajit.lua_getfield(L, -1, "event");
    }

    luajit.lua_newtable(L);
    inline for (std.meta.fields(core.EventKind)) |f| {
        luajit.lua_pushinteger(L, @intCast(@as(u8, f.value)));
        luajit.lua_setfield(L, -2, f.name.ptr);
    }
    luajit.lua_setfield(L, -2, "Kind");
    // Pop f.event and f.
    luajit.lua_pop(L, 2);
}

const kind_fields = buildEnumFieldArray(core.EventKind);

const event_kind_enum = registry.Enum{
    .name = "f.event.Kind",
    .fields = kind_fields[0..],
};

const event_module = registry.Module{
    .name = "event",
    .functions = &[_]registry.Function{
        .{
            .name = "poll",
            .func = poll,
            .doc_string = "Return table of queued events (and clears queue)",
            .params = &[_]registry.Parameter{},
            .returns = &[_]registry.Parameter{
                .{ .name = "events", .type_name = "table", .doc_string = "Array of event records." },
            },
        },
    },
};
