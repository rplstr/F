const std = @import("std");
const err = @import("../lua/err.zig");
const luajit = @import("luajit");
const registry = @import("../lua/registry.zig");
const entity = @import("entity.zig");
const ev = @import("../event/core.zig");

const Handle = entity.Handle;

fn packHandle(h: Handle) u32 {
    return (@as(u32, h.gen) << 24) | @as(u32, h.idx);
}

fn unpackHandle(v: u32) Handle {
    return .{ .idx = @intCast(v & 0x00FF_FFFF), .gen = @intCast(v >> 24) };
}

pub fn interface(comptime WorldPtr: type) type {
    return struct {
        var world: WorldPtr = undefined;

        const CompMap = std.StringHashMapUnmanaged(u32);
        var comp_map: CompMap = .{};

        const max_components: usize = 1024;
        var comp_enum_fields: [max_components]registry.EnumField = undefined;
        var comp_enum_len: usize = 0;
        var comp_enum: registry.Enum = .{
            .name = "f.ecs.Component",
            .fields = comp_enum_fields[0..0],
        };

        pub fn register(r: *registry.Registry, L: *luajit.lua_State, w: WorldPtr) void {
            world = w;
            r.registerEnum(&comp_enum);
            lua_vm = L;
            r.registerModule(L, &ecs_module);

            // ensure `f.ecs.comp` exists and has a lazy __index metamethod that
            // hashes the component name on first access and caches the numeric ID.
            luajit.lua_getglobal(L, "f"); // stack: f
            luajit.lua_getfield(L, -1, "ecs"); // stack: f, ecs
            if (luajit.lua_isnil(L, -1) == false) {
                luajit.lua_getfield(L, -1, "comp"); // stack: f, ecs, comp|nil
                const has_comp = luajit.lua_isnil(L, -1) == false;
                if (has_comp) {
                    // pop comp table
                    luajit.lua_pop(L, 1);
                } else {
                    luajit.lua_pop(L, 1); // pop nil
                    luajit.lua_newtable(L); // comp table
                    // create metatable
                    luajit.lua_newtable(L); // mt
                    luajit.lua_pushcfunction(L, compIndex);
                    luajit.lua_setfield(L, -2, "__index");
                    // setmetatable(comp, mt)
                    _ = luajit.lua_setmetatable(L, -2);
                    // ecs.comp = comp
                    luajit.lua_setfield(L, -2, "comp");
                }
            }
            // Pop ecs and f
            luajit.lua_pop(L, 2);

            var it = comp_map.iterator();
            while (it.next()) |kv| {
                _ = ensureCompId(L, kv.key_ptr.*);
            }
        }

        /// Generic compile-time helper. `Ecs.register(Position)`.
        /// May be called before `register()` sets `lua_vm`, so we only touch
        /// in-memory maps and tooling files here.  The Lua side is synchronised
        /// later inside `register()`.
        pub fn registerComponent(comptime Comp: type) u32 {
            const name = compLowerName(Comp);
            if (comp_map.get(name)) |existing| return existing;
            const id: u32 = std.hash.Fnv1a_32.hash(name);
            const duped = comp_allocator.dupe(u8, name) catch unreachable;
            comp_map.put(comp_allocator, duped, id) catch unreachable;

            std.debug.assert(comp_enum_len < max_components);
            comp_enum_fields[comp_enum_len] = .{ .name = name, .value = @as(i64, id) };
            comp_enum_len += 1;
            comp_enum.fields = comp_enum_fields[0..comp_enum_len];

            return id;
        }

        fn checkEntity(L: *luajit.lua_State, n: c_int) Handle {
            const v = @as(u32, @intCast(luajit.luaL_checkinteger(L, n)));
            return unpackHandle(v);
        }

        fn pushEntity(L: *luajit.lua_State, h: Handle) void {
            luajit.lua_pushinteger(L, @intCast(packHandle(h)));
        }

        fn create(L_opt: ?*luajit.lua_State) callconv(.c) c_int {
            const L = L_opt.?;
            const h = world.create() catch {
                luajit.lua_pushnil(L);
                return 1;
            };
            pushEntity(L, h);
            return 1;
        }

        fn destroy(L_opt: ?*luajit.lua_State) callconv(.c) c_int {
            const L = L_opt.?;
            const h = checkEntity(L, 1);
            _ = world.destroy(h) catch {};
            return 0;
        }

        fn isValid(L_opt: ?*luajit.lua_State) callconv(.c) c_int {
            const L = L_opt.?;
            const h = checkEntity(L, 1);
            luajit.lua_pushboolean(L, @intFromBool(world.isValid(h)));
            return 1;
        }

        fn setParent(L_opt: ?*luajit.lua_State) callconv(.c) c_int {
            const L = L_opt.?;
            const child = checkEntity(L, 1);
            var parent: ?Handle = null;
            if (luajit.lua_isnil(L, 2) == false) {
                parent = checkEntity(L, 2);
            }
            world.setParent(child, parent);
            return 0;
        }

        fn children(L_opt: ?*luajit.lua_State) callconv(.c) c_int {
            const L = L_opt.?;
            const parent = checkEntity(L, 1);

            luajit.lua_newtable(L);
            var next_idx: c_int = 1;

            lua_vm = L;
            table_index = &next_idx;

            world.iterChildren(parent, pushChildCb);

            return 1;
        }

        /// Main Lua state pointer captured at register. Required for system callbacks.
        var lua_vm: *luajit.lua_State = undefined;
        // Scratch variables used only by the `children` iterator callback.
        var table_index: *c_int = undefined;

        fn pushChildCb(child_idx: u32) void {
            const L = lua_vm; // children always sets this before iterating
            const idx_ptr = table_index;
            const h = world.entities.handleFromIdx(child_idx);
            pushEntity(L, h);
            luajit.lua_rawseti(L, -2, idx_ptr.*);
            idx_ptr.* += 1;
        }

        fn entities(L_opt: ?*luajit.lua_State) callconv(.c) c_int {
            const L = L_opt.?;
            luajit.lua_newtable(L);
            var idx: c_int = 1;
            var i: u32 = 0;
            while (i < world.entities.gens.len) : (i += 1) {
                const h = world.entities.handleFromIdx(i);
                if (world.isValid(h)) {
                    pushEntity(L, h);
                    luajit.lua_rawseti(L, -2, idx);
                    idx += 1;
                }
            }
            return 1;
        }

        const comp_allocator = std.heap.c_allocator;

        fn compLowerName(comptime T: type) []const u8 {
            const full = @typeName(T);
            const dot = comptime std.mem.lastIndexOfScalar(u8, full, '.') orelse full.len;
            const simple = full[dot + 1 ..];
            const lower = comptime blk: {
                var buf: [simple.len]u8 = undefined;
                for (simple, 0..) |c, i| {
                    buf[i] = std.ascii.toLower(c);
                }
                break :blk buf;
            };
            return lower[0..];
        }

        fn ensureCompId(L: *luajit.lua_State, name: []const u8) u32 {
            if (comp_map.get(name)) |existing| return existing;
            const id: u32 = std.hash.Fnv1a_32.hash(name);
            const duped = comp_allocator.dupe(u8, name) catch unreachable;
            comp_map.put(comp_allocator, duped, id) catch unreachable;

            luajit.lua_getglobal(L, "f");
            luajit.lua_getfield(L, -1, "ecs");
            luajit.lua_getfield(L, -1, "comp");
            if (luajit.lua_isnil(L, -1) != false) {
                luajit.lua_pop(L, 1);
                luajit.lua_newtable(L);
                luajit.lua_pushvalue(L, -1);
                luajit.lua_setfield(L, -3, "comp");
            }
            luajit.lua_pushinteger(L, id);
            luajit.lua_setfield(L, -2, name.ptr);
            luajit.lua_pop(L, 3); // comp, ecs, f

            return id;
        }

        fn compIndex(L_opt: ?*luajit.lua_State) callconv(.c) c_int {
            const L = L_opt.?;
            luajit.luaL_checktype(L, 2, luajit.LUA_TSTRING);
            const cid = compIdArg(L, 2);
            luajit.lua_pushinteger(L, cid);
            return 1;
        }

        fn compIdArg(L: *luajit.lua_State, idx: c_int) u32 {
            const t = luajit.lua_type(L, idx);
            if (t == luajit.LUA_TNUMBER) return @intCast(luajit.lua_tointeger(L, idx));
            if (t == luajit.LUA_TSTRING) {
                var len: usize = 0;
                const cstr = luajit.lua_tolstring(L, idx, &len);
                const slice = @as([*]const u8, cstr)[0..len];
                if (comp_map.get(slice)) |cid| {
                    return cid;
                }
                _ = luajit.luaL_error(L, "unknown component '%s' (not registered)", cstr);
                unreachable;
            }
            _ = luajit.luaL_error(L, "component must be string or number");
            unreachable;
        }

        fn pushCompStore(L: *luajit.lua_State) void {
            luajit.lua_getfield(L, luajit.LUA_REGISTRYINDEX, "__ecs_comp_store");
            if (luajit.lua_isnil(L, -1) != false) {
                luajit.lua_pop(L, 1);
                luajit.lua_newtable(L);
                luajit.lua_pushvalue(L, -1);
                luajit.lua_setfield(L, luajit.LUA_REGISTRYINDEX, "__ecs_comp_store");
            }
        }

        fn addComp(L_opt: ?*luajit.lua_State) callconv(.c) c_int {
            const L = L_opt.?;
            const ent = checkEntity(L, 1);
            const cid = compIdArg(L, 2);
            luajit.luaL_checktype(L, 3, luajit.LUA_TTABLE);

            pushCompStore(L); // store
            pushEntity(L, ent); // key
            luajit.lua_gettable(L, -2); // ent_tbl or nil
            if (luajit.lua_isnil(L, -1) != false) {
                luajit.lua_pop(L, 1);
                luajit.lua_newtable(L); // ent_tbl
                pushEntity(L, ent);
                luajit.lua_pushvalue(L, -2);
                luajit.lua_settable(L, -4); // store[ent] = ent_tbl
            }
            // ent_tbl now on stack top

            luajit.lua_pushinteger(L, cid);
            luajit.lua_gettable(L, -2); // get old value
            const is_add = luajit.lua_isnil(L, -1) != false;
            luajit.lua_pop(L, 1); // pop old value

            luajit.lua_pushinteger(L, cid);
            luajit.lua_pushvalue(L, 3);
            luajit.lua_settable(L, -3); // ent_tbl[cid] = comp_table

            const kind = if (is_add) ev.EventKind.component_add else ev.EventKind.component_set;
            ev.pushInts(kind, @intCast(ent.idx), @intCast(ent.gen), @intCast(cid), 0);
            ev.pushInts(ev.EventKind.entity_modified, @intCast(ent.idx), @intCast(ent.gen), 0, 0);

            luajit.lua_pop(L, 2); // ent_tbl, store
            return 0;
        }

        fn getComp(L_opt: ?*luajit.lua_State) callconv(.c) c_int {
            const L = L_opt.?;
            const ent = checkEntity(L, 1);
            const cid = compIdArg(L, 2);
            pushCompStore(L);
            pushEntity(L, ent);
            luajit.lua_gettable(L, -2); // ent_tbl or nil
            if (luajit.lua_isnil(L, -1) != false) {
                luajit.lua_pop(L, 2); // nil, store
                luajit.lua_pushnil(L);
                return 1;
            }
            luajit.lua_pushinteger(L, cid);
            luajit.lua_gettable(L, -2); // comp or nil
            luajit.lua_remove(L, -2); // ent_tbl
            luajit.lua_remove(L, -2); // store
            return 1;
        }

        fn removeComp(L_opt: ?*luajit.lua_State) callconv(.c) c_int {
            const L = L_opt.?;
            const ent = checkEntity(L, 1);
            const cid = compIdArg(L, 2);
            pushCompStore(L);
            pushEntity(L, ent);
            luajit.lua_gettable(L, -2); // ent_tbl or nil
            if (luajit.lua_isnil(L, -1) == false) {
                // Check if component exists before removing
                luajit.lua_pushinteger(L, cid);
                luajit.lua_gettable(L, -2);
                const existed = luajit.lua_isnil(L, -1) == false;
                luajit.lua_pop(L, 1);

                if (existed) {
                    luajit.lua_pushinteger(L, cid);
                    luajit.lua_pushnil(L);
                    luajit.lua_settable(L, -3);

                    ev.pushInts(ev.EventKind.component_remove, @intCast(ent.idx), @intCast(ent.gen), @intCast(cid), 0);
                    ev.pushInts(ev.EventKind.entity_modified, @intCast(ent.idx), @intCast(ent.gen), 0, 0);
                }
            }
            luajit.lua_pop(L, 2); // ent_tbl/store or store
            return 0;
        }

        const max_systems = 1024;
        var lua_sys_refs: [max_systems]c_int = [_]c_int{0} ** max_systems;
        var lua_sys_len: usize = 0;

        fn luaWrapper(comptime idx: usize) fn (WorldPtr, f32) void {
            return struct {
                fn cb(_: WorldPtr, dt: f32) void {
                    const L = lua_vm;
                    luajit.lua_rawgeti(L, luajit.LUA_REGISTRYINDEX, lua_sys_refs[idx]);
                    luajit.lua_pushnumber(L, dt);

                    _ = err.protectedCall(L, 1, 0) catch {};
                }
            }.cb;
        }

        const lua_wrappers = blk: {
            var arr: [max_systems]*const fn (WorldPtr, f32) void = undefined;
            for (0..max_systems) |i| {
                @setEvalBranchQuota(10_000);
                arr[i] = luaWrapper(i);
            }
            break :blk arr;
        };

        fn registerSystemLua(L_opt: ?*luajit.lua_State) callconv(.c) c_int {
            const L = L_opt.?;
            luajit.luaL_checktype(L, 1, luajit.LUA_TFUNCTION);

            var order: u8 = 0;
            if (luajit.lua_gettop(L) >= 2) {
                order = @intCast(luajit.luaL_checkinteger(L, 2));
            }

            if (lua_sys_len >= max_systems) {
                luajit.lua_pushstring(L, "Too many Lua ECS systems registered");
                _ = luajit.lua_error(L);
            }

            luajit.lua_pushvalue(L, 1);
            const ref_id = luajit.luaL_ref(L, luajit.LUA_REGISTRYINDEX);
            lua_sys_refs[lua_sys_len] = ref_id;

            lua_vm = L;

            const wrapper = lua_wrappers[lua_sys_len];
            world.systems.register(wrapper, order) catch {
                luajit.lua_pushstring(L, "scheduler out of space");
                _ = luajit.lua_error(L);
            };

            lua_sys_len += 1;
            return 0;
        }

        const ecs_module = registry.Module{
            .name = "ecs",
            .functions = &[_]registry.Function{ .{
                .name = "create",
                .func = create,
                .doc_string = "Create a new entity and return its handle (packed integer).",
                .params = &[_]registry.Parameter{},
                .returns = &[_]registry.Parameter{
                    .{ .name = "handle", .type_name = "number", .doc_string = "Packed entity handle." },
                },
            }, .{
                .name = "destroy",
                .func = destroy,
                .doc_string = "Destroy an entity by handle. Ignores invalid handles.",
                .params = &[_]registry.Parameter{
                    .{ .name = "handle", .type_name = "number" },
                },
                .returns = &[_]registry.Parameter{},
            }, .{
                .name = "is_valid",
                .func = isValid,
                .doc_string = "Return true if the handle refers to an alive entity.",
                .params = &[_]registry.Parameter{
                    .{ .name = "handle", .type_name = "number" },
                },
                .returns = &[_]registry.Parameter{
                    .{ .name = "valid", .type_name = "boolean" },
                },
            }, .{
                .name = "set_parent",
                .func = setParent,
                .doc_string = "Set the parent of a child entity. Pass nil as parent for root level.",
                .params = &[_]registry.Parameter{
                    .{ .name = "child", .type_name = "number" },
                    .{ .name = "parent", .type_name = "number" },
                },
                .returns = &[_]registry.Parameter{},
            }, .{
                .name = "children",
                .func = children,
                .doc_string = "Return array of direct children handles for the given parent entity.",
                .params = &[_]registry.Parameter{
                    .{ .name = "parent", .type_name = "number" },
                },
                .returns = &[_]registry.Parameter{
                    .{ .name = "handles", .type_name = "table" },
                },
            }, .{
                .name = "entities",
                .func = entities,
                .doc_string = "Return table of all alive entity handles.",
                .params = &[_]registry.Parameter{},
                .returns = &[_]registry.Parameter{
                    .{ .name = "handles", .type_name = "table" },
                },
            }, .{
                .name = "register_system",
                .func = registerSystemLua,
                .doc_string = "Register a callback as an ECS system.",
                .params = &[_]registry.Parameter{
                    .{ .name = "callback", .type_name = "function" },
                    .{ .name = "order", .type_name = "number" },
                },
                .returns = &[_]registry.Parameter{},
            }, .{
                .name = "set_comp",
                .func = addComp,
                .doc_string = "Add or replace a component on an entity.",
                .params = &[_]registry.Parameter{
                    .{ .name = "entity", .type_name = "number" },
                    .{ .name = "component", .type_name = "string" },
                    .{ .name = "data", .type_name = "table" },
                },
                .returns = &[_]registry.Parameter{},
            }, .{
                .name = "get_comp",
                .func = getComp,
                .doc_string = "Retrieve a component table from an entity or nil if not present.",
                .params = &[_]registry.Parameter{
                    .{ .name = "entity", .type_name = "number" },
                    .{ .name = "component", .type_name = "string" },
                },
                .returns = &[_]registry.Parameter{
                    .{ .name = "data", .type_name = "table" },
                },
            }, .{
                .name = "remove_comp",
                .func = removeComp,
                .doc_string = "Remove a component from an entity.",
                .params = &[_]registry.Parameter{
                    .{ .name = "entity", .type_name = "number" },
                    .{ .name = "component", .type_name = "string" },
                },
                .returns = &[_]registry.Parameter{},
            } },
        };
    };
}
