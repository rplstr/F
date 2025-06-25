const std = @import("std");
const entity = @import("entity.zig");

const Fnv64 = std.hash.Fnv1a_64;

const Pool = entity.Pool;
const Handle = entity.Handle;

const Hierarchy = @import("Hierarchy.zig").Hierarchy;
const ObserverList = @import("observer.zig").ObserverList;
const ObsKind = @import("observer.zig").ObsKind;
const CommandBuffer = @import("command.zig").CommandBuffer;
const SystemScheduler = @import("SystemScheduler.zig").SystemScheduler;
const ComponentStore = @import("ComponentStore.zig").ComponentStore;
const ev = @import("../event/core.zig");

pub const Error = error{ OutOfSpace, InvalidHandle };

/// Build-time configuration for a `World` instance.
pub const WorldConfig = struct {
    cap: usize, // maximum simultaneous entities
    max_obs: usize = 0, // observer slots
    max_sys: usize = 0, // systems per world
    max_cmd: usize = 0, // command buffer length
    stage_bytes: usize = 0, // scratch space for deferred copies
    max_comp: usize = 0, // component types capacity
    arena_bytes: usize = 0, // bytes for component arena
};

/// Thin facade that glues specialised managers together.
pub fn World(comptime Cfg: WorldConfig) type {
    const EP = Pool(Cfg.cap);

    return struct {
        entities: EP = .{},
        hierarchy: Hierarchy(Cfg.cap) = .{},
        observers: ObserverList(Cfg.max_obs, Handle) = .{},
        comps: ComponentStore(Cfg.cap, Cfg.max_comp, Cfg.arena_bytes) = .{},
        cmd_buf: CommandBuffer(Cfg.max_cmd, Cfg.stage_bytes) = .{},
        systems: SystemScheduler(Cfg.max_sys, *Self) = .{},

        const Self = @This();

        /// Initialise internal managers. Must be called once before use.
        pub fn init(self: *Self) void {
            self.entities.init();
        }

        /// Create a new entity and return its handle.
        pub fn create(self: *Self) !Handle {
            return self.entities.create();
        }
        /// Destroy the entity referred to by handle `h`.
        pub fn destroy(self: *Self, h: Handle) !void {
            try self.entities.destroy(h);
        }

        /// Check whether handle `h` is still valid (entity alive).
        pub fn isValid(self: *const Self, h: Handle) bool {
            return self.entities.isValid(h);
        }

        /// Change the parent of `child` to `new_parent`. Pass `null` for root.
        pub fn setParent(self: *Self, child: Handle, new_parent: ?Handle) void {
            const p_idx: u32 = if (new_parent) |p| p.idx else std.math.maxInt(u32);
            self.hierarchy.attach(child.idx, p_idx);
        }

        /// Iterate direct children of `parent`, invoking callback `cb(handle_idx)`.
        pub fn iterChildren(self: *Self, parent: Handle, cb: anytype) void {
            self.hierarchy.iterChildren(parent.idx, cb);
        }

        /// Register a system function that will be executed each frame in order `order`.
        pub fn registerSystem(self: *Self, fn_ptr: fn (*Self, f32) void, order: u8) !void {
            try self.systems.register(fn_ptr, order);
        }

        /// Run one simulation frame: execute all systems and flush deferred commands.
        pub fn runFrame(self: *Self, dt: f32) void {
            self.systems.run(self, dt);

            self.flushCommands();
        }

        /// Add a new component `val` of its inferred type to entity `e`.
        pub fn add(self: *Self, e: Handle, val: anytype) !void {
            if (!self.isValid(e)) return Error.InvalidHandle;
            const T = @TypeOf(val);
            const tid = typeId(T);
            try self.comps.add(e.idx, val);
            self.observers.notify(tid, .add, @ptrCast(self), e);
            ev.pushInts(
                ev.EventKind.component_add,
                @intCast(e.idx),
                @intCast(e.gen),
                @intCast(tid & 0xFFFF_FFFF),
                @intCast(tid >> 32),
            );
        }

        /// Set (overwrite) an existing component on entity `e`.
        pub fn set(self: *Self, e: Handle, val: anytype) !void {
            if (!self.isValid(e)) return Error.InvalidHandle;
            const T = @TypeOf(val);
            const tid = typeId(T);
            try self.comps.set(e.idx, val);
            self.observers.notify(tid, .set, @ptrCast(self), e);
            ev.pushInts(
                ev.EventKind.component_set,
                @intCast(e.idx),
                @intCast(e.gen),
                @intCast(tid & 0xFFFF_FFFF),
                @intCast(tid >> 32),
            );
        }

        /// Get component of type `T` from entity `e`.
        pub fn get(self: *const Self, e: Handle, comptime T: type) !T {
            if (!self.isValid(e)) return Error.InvalidHandle;
            return self.comps.get(e.idx, T);
        }

        /// Return `true` if entity `e` has a component of type `T`.
        pub fn has(self: *const Self, e: Handle, comptime T: type) bool {
            if (!self.isValid(e)) return false;
            return self.comps.has(e.idx, T);
        }

        /// Remove component of type `T` from entity `e` (if any).
        pub fn remove(self: *Self, e: Handle, comptime T: type) void {
            if (!self.isValid(e)) return;
            self.comps.remove(e.idx, T);
            const tid = typeId(T);
            self.observers.notify(tid, .remove, @ptrCast(self), e);
            ev.pushInts(
                ev.EventKind.component_remove,
                @intCast(e.idx),
                @intCast(e.gen),
                @intCast(tid & 0xFFFF_FFFF),
                @intCast(tid >> 32),
            );
        }

        fn flushCommands(self: *Self) void {
            var i: usize = 0;
            while (i < self.cmd_buf.cmd_len) : (i += 1) {
                const c = self.cmd_buf.cmds[i];
                const h = self.entities.handleFromIdx(c.ent_idx);

                switch (c.kind) {
                    .add => {
                        if (Cfg.stage_bytes == 0) unreachable;
                        const src = &self.cmd_buf.stage[c.src_off];
                        _ = self.comps.applyAddBytes(c.type_id, h.idx, src);
                        self.observers.notify(c.type_id, .add, @ptrCast(self), h);
                        ev.pushInts(
                            ev.EventKind.component_add,
                            @intCast(h.idx),
                            @intCast(h.gen),
                            @intCast(c.type_id & 0xFFFF_FFFF),
                            @intCast(c.type_id >> 32),
                        );
                    },
                    .set => {
                        if (Cfg.stage_bytes == 0) unreachable;
                        const src = &self.cmd_buf.stage[c.src_off];
                        _ = self.comps.applySetBytes(c.type_id, h.idx, src);
                        self.observers.notify(c.type_id, .set, @ptrCast(self), h);
                        ev.pushInts(
                            ev.EventKind.component_set,
                            @intCast(h.idx),
                            @intCast(h.gen),
                            @intCast(c.type_id & 0xFFFF_FFFF),
                            @intCast(c.type_id >> 32),
                        );
                    },
                    .rem => {
                        _ = self.comps.applyRem(c.type_id, h.idx);
                        self.observers.notify(c.type_id, .remove, @ptrCast(self), h);
                        ev.pushInts(
                            ev.EventKind.component_remove,
                            @intCast(h.idx),
                            @intCast(h.gen),
                            @intCast(c.type_id & 0xFFFF_FFFF),
                            @intCast(c.type_id >> 32),
                        );
                    },
                    .destroy => {
                        _ = self.destroy(h) catch {};
                    },
                }
            }
            self.cmd_buf.clear();
        }

        fn typeId(comptime T: type) u64 {
            return Fnv64.hash(@typeName(T));
        }
    };
}

const TestCfg = WorldConfig{
    .cap = 8,
    .max_obs = 8,
    .max_sys = 8,
    .max_cmd = 16,
    .stage_bytes = 1024,
    .max_comp = 8,
    .arena_bytes = 2048,
};

const TestWorld = World(TestCfg);

const Position = struct { x: i32, y: i32 };
const Velocity = struct { dx: i32, dy: i32 };

var child_counter: u8 = 0;
var sys_exec_order: [2]u8 = undefined;
var sys_exec_idx: u8 = 0;

test "entity create and destroy" {
    var w: TestWorld = .{};
    w.init();

    const e1 = try w.create();
    const e2 = try w.create();

    try std.testing.expect(w.isValid(e1));
    try std.testing.expect(w.isValid(e2));

    try w.destroy(e1);
    try std.testing.expect(!w.isValid(e1));
    try std.testing.expect(w.isValid(e2));
}

test "component add / set / get / has / remove" {
    var w: TestWorld = .{};
    w.init();

    const e = try w.create();

    try w.add(e, Position{ .x = 1, .y = 2 });
    try std.testing.expect(w.has(e, Position));
    try std.testing.expectEqual(Position{ .x = 1, .y = 2 }, try w.get(e, Position));

    const new_pos = Position{ .x = 3, .y = 4 };
    try w.set(e, new_pos);
    try std.testing.expectEqual(new_pos, try w.get(e, Position));

    w.remove(e, Position);
    try std.testing.expect(!w.has(e, Position));
}

test "parent / child relationships" {
    var w: TestWorld = .{};
    w.init();

    const parent = try w.create();
    const c1 = try w.create();
    const c2 = try w.create();

    w.setParent(c1, parent);
    w.setParent(c2, parent);

    child_counter = 0;

    const Visitor = struct {
        fn cb(idx: u32) void {
            _ = idx;
            child_counter += 1;
        }
    };

    w.iterChildren(parent, Visitor.cb);

    try std.testing.expectEqual(@as(u8, 2), child_counter);
}

fn sysA(world: *TestWorld, dt: f32) void {
    sys_exec_order[sys_exec_idx] = 1;
    sys_exec_idx += 1;
    _ = world;
    _ = dt;
}

fn sysB(world: *TestWorld, dt: f32) void {
    sys_exec_order[sys_exec_idx] = 2;
    sys_exec_idx += 1;
    _ = world;
    _ = dt;
}

test "system execution order" {
    sys_exec_idx = 0;

    var w: TestWorld = .{};
    w.init();

    try w.registerSystem(sysB, 2);
    try w.registerSystem(sysA, 1);

    w.runFrame(0.016);

    try std.testing.expectEqual(@as(u8, 1), sys_exec_order[0]);
    try std.testing.expectEqual(@as(u8, 2), sys_exec_order[1]);
    try std.testing.expectEqual(@as(u8, 2), sys_exec_idx);
}
