const std = @import("std");

const luajit = @import("luajit");

const log = std.log.scoped(.gen);

/// Describes a single parameter or return value of a Lua-exposed function.
pub const Parameter = struct {
    name: []const u8,
    /// Lua-equivalent type, e.g. "string", "number", "f.log.Logger"
    type_name: []const u8,
    doc_string: []const u8 = "",
};

/// Representation of a single Zig function exposed to Lua.
pub const Function = struct {
    name: []const u8,
    func: luajit.lua_CFunction,
    doc_string: []const u8 = "",

    params: []const Parameter = &.{},
    returns: []const Parameter = &.{},
};

/// A collection of related functions, represented as a table in the global `f`
/// namespace in Lua.
pub const Module = struct {
    name: []const u8,
    functions: []const Function,
};

/// A collection of methods that define a Lua "class", implemented as a metatable
/// for userdata.
pub const Class = struct {
    /// Fully-qualified name, e.g. "f.log.Logger"
    name: []const u8,
    methods: []const Function,
};

/// Describes a single compile-time constant inside an enum.
pub const EnumField = struct {
    name: []const u8,
    value: i64,
};

/// Representation of a Zig enum exported to Lua. Generated as
/// `---@alias name integer` followed by an `---@enum` block so EmmyLua / LLS recognize it.
pub const Enum = struct {
    /// Fully-qualified Lua name, e.g. "f.input.Key"
    name: []const u8,
    fields: []const EnumField,
};

const max_modules = 32;
const max_classes = 32;
const max_functions_per_item = 64;
const max_enums = 64;

pub const Registry = @This();

api_modules: [max_modules]*const Module = undefined,
registered_modules: u32 = 0,

api_classes: [max_classes]*const Class = undefined,
registered_classes: u32 = 0,

api_enums: [max_enums]*const Enum = undefined,
registered_enums: u32 = 0,

pub fn init() Registry {
    return .{
        .api_modules = [_]*const Module{undefined} ** max_modules,
        .registered_modules = 0,
        .api_classes = [_]*const Class{undefined} ** max_classes,
        .registered_classes = 0,
        .api_enums = [_]*const Enum{undefined} ** max_enums,
        .registered_enums = 0,
    };
}

/// Creates a new table at `f[module.name]` and populates it with
/// the functions defined in `module.functions`.
pub fn registerModule(self: *Registry, L: *luajit.lua_State, module: *const Module) void {
    std.debug.assert(self.registered_modules < max_modules);

    self.api_modules[self.registered_modules] = module;
    self.registered_modules += 1;

    luajit.lua_getglobal(L, "f");
    if (luajit.lua_isnil(L, -1)) {
        luajit.lua_pop(L, 1);
        luajit.lua_newtable(L);
        luajit.lua_setglobal(L, "f");
        luajit.lua_getglobal(L, "f");
    }

    luajit.lua_newtable(L);

    var funcs: [max_functions_per_item]luajit.luaL_Reg = undefined;
    for (module.functions, 0..) |f, i| {
        funcs[i] = .{ .name = f.name.ptr, .func = f.func };
    }
    funcs[module.functions.len] = .{ .name = null, .func = null };

    luajit.luaL_setfuncs(L, &funcs, 0);
    luajit.lua_setfield(L, -2, module.name.ptr);

    luajit.lua_pop(L, 1);
}

/// Creates a new metatable in the Lua registry with the name `class.name`. This
/// metatable is populated with the methods from `class.methods` and is configured
/// with `__index` pointing to itself.
pub fn registerClass(self: *Registry, L: *luajit.lua_State, class: *const Class) void {
    std.debug.assert(self.registered_classes < max_classes);

    self.api_classes[self.registered_classes] = class;
    self.registered_classes += 1;

    if (luajit.luaL_newmetatable(L, class.name.ptr) != 0) {
        var methods: [max_functions_per_item]luajit.luaL_Reg = undefined;
        for (class.methods, 0..) |m, i| {
            methods[i] = .{ .name = m.name.ptr, .func = m.func };
        }
        methods[class.methods.len] = .{ .name = null, .func = null };

        luajit.lua_pushvalue(L, -1);
        luajit.lua_setfield(L, -2, "__index");

        luajit.luaL_setfuncs(L, &methods, 0);
    }

    luajit.lua_pop(L, 1);
}

/// Adds an enum description for documentation generation.
/// Does not touch the Lua state at runtime.
pub fn registerEnum(self: *Registry, en: *const Enum) void {
    std.debug.assert(self.registered_enums < max_enums);
    self.api_enums[self.registered_enums] = en;
    self.registered_enums += 1;
}

/// Iterates through all modules, classes, and enums added via the registry
/// `registerClass`, and `registerEnum` and writes their definitions to `.lua` files in the
/// target directory.
pub fn generate(self: *const Registry, allocator: std.mem.Allocator, dir_path: []const u8) !void {
    log.debug("┌─", .{});
    var dir = try std.fs.cwd().makeOpenPath(dir_path, .{});
    defer dir.close();

    try dir.makePath(".");

    var i: u32 = 0;
    while (i < self.registered_modules) : (i += 1) {
        const module = self.api_modules[i];
        const file_name = try std.fmt.allocPrint(allocator, "{s}.lua", .{module.name});
        defer allocator.free(file_name);

        const full_path = try std.fs.path.resolve(allocator, &.{ dir_path, file_name });
        defer allocator.free(full_path);
        log.debug("├─► {s}", .{full_path});

        const file = try dir.createFile(file_name, .{ .read = true });
        defer file.close();

        const writer = file.writer();

        try writer.writeAll("---@meta\n");
        try writer.writeAll("-- This file is automatically generated.\n\n");

        const module_prefix = try std.fmt.allocPrint(allocator, "f.{s}.", .{module.name});
        defer allocator.free(module_prefix);

        var j: u32 = 0;
        while (j < self.registered_classes) : (j += 1) {
            const class = self.api_classes[j];
            if (std.mem.startsWith(u8, class.name, module_prefix)) {
                try writeClass(allocator, writer, class);
            }
        }

        // Enums
        var k: u32 = 0;
        while (k < self.registered_enums) : (k += 1) {
            const en = self.api_enums[k];
            if (std.mem.startsWith(u8, en.name, module_prefix)) {
                try writeEnum(writer, en);
            }
        }

        try writer.print("f = f or {{}}\nf.{s} = {{}}\n\n", .{module.name});

        for (module.functions) |f| {
            try writeFunction(allocator, writer, module.name, &f);
        }
    }
    log.debug("└─", .{});
}

pub fn generateEmmy(allocator: std.mem.Allocator, writer: anytype, modules: []const *const Module) !void {
    try writer.writeAll(
        \\---@meta
        \\
        \\
        \\
    );

    for (modules) |module| {
        if (module.name.len == 0) continue;

        for (module.functions) |f| {
            try writeFunction(allocator, writer, module.name, f);
        }
    }
}

fn writeClass(allocator: std.mem.Allocator, writer: anytype, class: *const Class) !void {
    log.debug("│  ├─ class {s}", .{class.name});
    try writer.print("---@class {s}\n", .{class.name});
    try writer.print("{s} = {{}}\n\n", .{class.name});

    for (class.methods) |m| {
        if (std.mem.startsWith(u8, m.name, "__")) continue;

        log.debug("│  │  └─ method {s}", .{m.name});
        const method_fqn = std.fmt.allocPrint(allocator, "{s}:{s}", .{ class.name, m.name }) catch unreachable;
        defer allocator.free(method_fqn);
        try writeFunctionDocumentation(writer, &m, method_fqn);
    }
}

fn writeFunction(allocator: std.mem.Allocator, writer: anytype, module_name: []const u8, func: *const Function) !void {
    const func_fqn = std.fmt.allocPrint(allocator, "f.{s}.{s}", .{ module_name, func.name }) catch unreachable;
    defer allocator.free(func_fqn);
    log.debug("│  └─ function {s}", .{func_fqn});
    try writeFunctionDocumentation(writer, func, func_fqn);
}

fn writeFunctionDocumentation(writer: anytype, func: *const Function, fqn: []const u8) !void {
    if (func.doc_string.len > 0) {
        try writer.print("--- {s}\n", .{func.doc_string});
    }

    for (func.params) |p| {
        try writer.print("---@param {s} {s}", .{ p.name, p.type_name });
        if (p.doc_string.len > 0) {
            try writer.print(" {s}\n", .{p.doc_string});
        } else {
            try writer.writeAll("\n");
        }
    }

    for (func.returns) |r| {
        try writer.print("---@return {s} {s}", .{ r.type_name, r.name });
        if (r.doc_string.len > 0) {
            try writer.print(" {s}\n", .{r.doc_string});
        } else {
            try writer.writeAll("\n");
        }
    }

    var param_names: [max_functions_per_item]u8 = undefined;
    var param_list: []u8 = "";
    if (func.params.len > 0) {
        var fbs = std.io.fixedBufferStream(&param_names);
        const list_writer = fbs.writer();
        for (func.params, 0..) |p, i| {
            if (i > 0) {
                try list_writer.writeAll(", ");
            }
            try list_writer.writeAll(p.name);
        }
        param_list = fbs.getWritten();
    }

    try writer.print("function {s}({s}) end\n\n", .{ fqn, param_list });
}

fn writeEnum(writer: anytype, e: *const Enum) !void {
    log.debug("│  └─ enum {s}", .{e.name});
    try writer.print("---@alias {s} integer\n", .{e.name});
    try writer.print("---@enum {s}\n{s} = {{\n", .{ e.name, e.name });
    for (e.fields) |f| {
        log.debug("│  │  └─ {s}", .{f.name});
        try writer.print("    {s} = {d},\n", .{ f.name, f.value });
    }
    try writer.writeAll("}\n\n");
}
