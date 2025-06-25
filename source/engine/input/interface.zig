const std = @import("std");

const registry = @import("../lua/registry.zig");
const luajit = @import("luajit");
const input = @import("input.zig");

const Key = input.Key;
const Button = input.Button;
const Context = input.Context;

var ctx: *Context = undefined;

pub fn register(r: *registry.Registry, L: *luajit.lua_State, context_handle: *Context) void {
    ctx = context_handle;
    r.registerEnum(&key_enum);
    r.registerEnum(&button_enum);
    r.registerModule(L, &input_module);
    buildConstantTables(L);
}

fn isKeyDown(L: ?*luajit.lua_State) callconv(.c) c_int {
    const key_code = @as(u16, @intCast(luajit.luaL_checkinteger(L.?, 1)));
    const key = @as(Key, @enumFromInt(key_code));
    luajit.lua_pushboolean(L.?, @intFromBool(ctx.isKeyDown(key)));
    return 1;
}

fn isButtonDown(L: ?*luajit.lua_State) callconv(.c) c_int {
    const btn_code = @as(u8, @intCast(luajit.luaL_checkinteger(L.?, 1)));
    const btn = @as(Button, @enumFromInt(btn_code));
    luajit.lua_pushboolean(L.?, @intFromBool(ctx.isButtonDown(btn)));
    return 1;
}

fn mousePosition(L: ?*luajit.lua_State) callconv(.c) c_int {
    luajit.lua_pushinteger(L.?, ctx.mouse_x);
    luajit.lua_pushinteger(L.?, ctx.mouse_y);
    return 2;
}

fn buildConstantTables(L: *luajit.lua_State) void {
    luajit.lua_getglobal(L, "f");
    if (luajit.lua_isnil(L, -1) != false) {
        luajit.lua_pop(L, 1);
        luajit.lua_newtable(L);
        luajit.lua_setglobal(L, "f");
        luajit.lua_getglobal(L, "f");
    }

    luajit.lua_getfield(L, -1, "input");
    if (luajit.lua_isnil(L, -1) != false) {
        luajit.lua_pop(L, 1);
        luajit.lua_newtable(L);
        luajit.lua_setfield(L, -2, "input");
        luajit.lua_getfield(L, -1, "input");
    }

    // Push Key constants.
    luajit.lua_newtable(L);
    inline for (std.meta.fields(Key)) |f| {
        luajit.lua_pushinteger(L, @intCast(f.value));
        luajit.lua_setfield(L, -2, f.name.ptr);
    }
    luajit.lua_setfield(L, -2, "Key");

    // Push Button constants.
    luajit.lua_newtable(L);
    inline for (std.meta.fields(Button)) |f| {
        luajit.lua_pushinteger(L, @intCast(f.value));
        luajit.lua_setfield(L, -2, f.name.ptr);
    }
    luajit.lua_setfield(L, -2, "Button");

    // Pop `f.input` and `f` tables.
    luajit.lua_pop(L, 2);
}

fn buildEnumFieldArray(comptime E: type) [std.meta.fields(E).len]registry.EnumField {
    const field_count = std.meta.fields(E).len;
    var arr: [field_count]registry.EnumField = undefined;
    inline for (std.meta.fields(E), 0..) |f, idx| {
        arr[idx] = .{ .name = f.name, .value = @as(i64, @intCast(f.value)) };
    }
    return arr;
}

const key_fields = buildEnumFieldArray(Key);
const button_fields = buildEnumFieldArray(Button);

const key_enum = registry.Enum{
    .name = "f.input.Key",
    .fields = key_fields[0..],
};

const button_enum = registry.Enum{
    .name = "f.input.Button",
    .fields = button_fields[0..],
};

const input_module = registry.Module{
    .name = "input",
    .functions = &[_]registry.Function{
        .{
            .name = "is_key_down",
            .func = isKeyDown,
            .doc_string = "Return `true` when the specified key is down.",
            .params = &[_]registry.Parameter{
                .{ .name = "key", .type_name = "number", .doc_string = "Keyboard code from f.input.Key." },
            },
            .returns = &[_]registry.Parameter{
                .{ .name = "down", .type_name = "boolean", .doc_string = "True when the key is down." },
            },
        },
        .{
            .name = "is_button_down",
            .func = isButtonDown,
            .doc_string = "Return `true` when the specified mouse button is pressed.",
            .params = &[_]registry.Parameter{
                .{ .name = "button", .type_name = "number", .doc_string = "Mouse button code from f.input.Button." },
            },
            .returns = &[_]registry.Parameter{
                .{ .name = "down", .type_name = "boolean", .doc_string = "True when the button is pressed." },
            },
        },
        .{
            .name = "mouse_position",
            .func = mousePosition,
            .doc_string = "Return the current mouse cursor position as `(x, y)`.",
            .params = &[_]registry.Parameter{},
            .returns = &[_]registry.Parameter{
                .{ .name = "x", .type_name = "number", .doc_string = "Horizontal position." },
                .{ .name = "y", .type_name = "number", .doc_string = "Vertical position." },
            },
        },
    },
};
