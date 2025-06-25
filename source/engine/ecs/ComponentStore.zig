const std = @import("std");

/// Possible error values returned by `ComponentStore` operations.
pub const Error = error{ OutOfSpace, ComponentExists, ComponentMissing };

/// Generic component storage manager.
pub fn ComponentStore(
    comptime Cap: usize,
    comptime MaxComp: usize,
    comptime ArenaBytes: usize,
) type {
    const Fnv64 = std.hash.Fnv1a_64;

    const MapSlot = struct {
        id: u64 = 0,
        off: u32 = 0,
        used: bool = false,

        hasFn: *const fn (*const anyopaque, u32) bool = undefined,
        addBytesFn: *const fn (*anyopaque, u32, *const u8) void = undefined,
        setBytesFn: *const fn (*anyopaque, u32, *const u8) void = undefined,
        remFn: *const fn (*anyopaque, u32) void = undefined,
    };

    return struct {
        arena: [ArenaBytes]u8 = undefined,
        arena_top: u32 = 0,

        map: [MaxComp]MapSlot = [_]MapSlot{.{}} ** MaxComp,
        map_len: usize = 0,

        const Self = @This();

        /// Add a new component value `val` for entity `idx`.
        ///
        /// `Error.ComponentExists` if the component of type `T` is already present
        /// `Error.OutOfSpace` if either the per-type map or the arena is full.
        pub fn add(self: *Self, idx: u32, val: anytype) !void {
            const T = @TypeOf(val);
            const stor = try self.ensureStorage(T);
            if (stor.has(idx)) return Error.ComponentExists;
            stor.add(idx, val);
        }

        /// Replace the existing component value for entity `idx`.
        /// `Error.ComponentMissing` if the component is not present.
        pub fn set(self: *Self, idx: u32, val: anytype) !void {
            const T = @TypeOf(val);
            const stor = try self.ensureStorage(T);
            if (!stor.has(idx)) return Error.ComponentMissing;
            stor.data[idx] = val;
        }

        /// Retrieve the component value of type `T` for entity `idx`.
        /// `Error.ComponentMissing` if not present.
        pub fn get(self: *const Self, idx: u32, comptime T: type) !T {
            const stor = self.findStorage(T) orelse return Error.ComponentMissing;
            if (!stor.has(idx)) return Error.ComponentMissing;
            return stor.data[idx];
        }

        /// Return `true` when entity `idx` owns a component of type `T`.
        pub fn has(self: *const Self, idx: u32, comptime T: type) bool {
            if (self.findStorage(T)) |stor| return stor.has(idx) else return false;
        }

        /// Remove the component of type `T` from entity `idx` if it exists.
        pub fn remove(self: *Self, idx: u32, comptime T: type) void {
            if (self.findStorage(T)) |stor_const| {
                var stor: *Storage(T, Cap) = @constCast(@ptrCast(stor_const));
                if (stor.has(idx)) stor.remove(idx);
            }
        }

        /// Install a staged `add` operation from raw bytes; used by `CommandBuffer`.
        /// Returns `true` when a storage matching `tid` was found.
        pub fn applyAddBytes(self: *Self, tid: u64, idx: u32, src: *const u8) bool {
            var i: usize = 0;
            while (i < MaxComp) : (i += 1) {
                const slot = &self.map[i];
                if (!slot.used or slot.id != tid) continue;
                slot.addBytesFn(@ptrCast(&self.arena[slot.off]), idx, src);
                return true;
            }
            return false;
        }

        /// Install a staged `set` operation from raw bytes; used by `CommandBuffer`.
        pub fn applySetBytes(self: *Self, tid: u64, idx: u32, src: *const u8) bool {
            var i: usize = 0;
            while (i < MaxComp) : (i += 1) {
                const slot = &self.map[i];
                if (!slot.used or slot.id != tid) continue;
                slot.setBytesFn(@ptrCast(&self.arena[slot.off]), idx, src);
                return true;
            }
            return false;
        }

        /// Apply a staged `remove` operation; used by `CommandBuffer`.
        pub fn applyRem(self: *Self, tid: u64, idx: u32) bool {
            var i: usize = 0;
            while (i < MaxComp) : (i += 1) {
                const slot = &self.map[i];
                if (!slot.used or slot.id != tid) continue;
                slot.remFn(@ptrCast(&self.arena[slot.off]), idx);
                return true;
            }
            return false;
        }

        fn typeId(comptime T: type) u64 {
            return Fnv64.hash(@typeName(T));
        }

        fn ensureStorage(self: *Self, comptime T: type) !*Storage(T, Cap) {
            if (self.findSlot(T)) |slot| return self.castStoragePtr(T, slot.off);

            if (self.map_len >= MaxComp) return Error.OutOfSpace;
            const need = @sizeOf(Storage(T, Cap));
            if (self.arena_top + need > ArenaBytes) return Error.OutOfSpace;

            const off: u32 = self.arena_top;
            self.arena_top += need;
            const s_ptr: *Storage(T, Cap) = @ptrCast(@alignCast(&self.arena[off]));
            s_ptr.* = .{};

            const FnHas = struct {
                fn call(p: *const anyopaque, idx: u32) bool {
                    const st: *const Storage(T, Cap) = @ptrCast(@alignCast(p));
                    return st.has(idx);
                }
            };
            const FnRem = struct {
                fn call(p: *anyopaque, idx: u32) void {
                    const st: *Storage(T, Cap) = @ptrCast(@alignCast(p));
                    st.remove(idx);
                }
            };
            const FnAddBytes = struct {
                fn call(p: *anyopaque, idx: u32, src: *const u8) void {
                    const st: *Storage(T, Cap) = @ptrCast(@alignCast(p));
                    if (st.has(idx)) return;
                    const v: *const T = @ptrCast(@alignCast(src));
                    st.add(idx, v.*);
                }
            };
            const FnSetBytes = struct {
                fn call(p: *anyopaque, idx: u32, src: *const u8) void {
                    const st: *Storage(T, Cap) = @ptrCast(@alignCast(p));
                    if (!st.has(idx)) return;
                    const v: *const T = @ptrCast(@alignCast(src));
                    st.data[idx] = v.*;
                }
            };

            const slot_idx = self.probeInsert(typeId(T));
            self.map[slot_idx] = .{
                .id = typeId(T),
                .off = off,
                .used = true,
                .hasFn = FnHas.call,
                .addBytesFn = FnAddBytes.call,
                .setBytesFn = FnSetBytes.call,
                .remFn = FnRem.call,
            };
            self.map_len += 1;
            return s_ptr;
        }

        fn findStorage(self: *const Self, comptime T: type) ?*const Storage(T, Cap) {
            if (self.findSlotConst(T)) |slot| return self.castStoragePtrConst(T, slot.off);
            return null;
        }

        fn findSlot(self: *Self, comptime T: type) ?*MapSlot {
            const id = typeId(T);
            var i: usize = id & (MaxComp - 1);
            while (self.map[i].used) : (i = (i + 1) & (MaxComp - 1)) {
                if (self.map[i].id == id) return &self.map[i];
            }
            return null;
        }

        fn findSlotConst(self: *const Self, comptime T: type) ?*const MapSlot {
            return @constCast(self).findSlot(T);
        }

        fn probeInsert(self: *Self, id: u64) usize {
            var i: usize = id & (MaxComp - 1);
            while (self.map[i].used) : (i = (i + 1) & (MaxComp - 1)) {}
            return i;
        }

        fn castStoragePtr(self: *Self, comptime T: type, off: u32) *Storage(T, Cap) {
            return @ptrCast(@alignCast(&self.arena[off]));
        }

        fn castStoragePtrConst(self: *const Self, comptime T: type, off: u32) *const Storage(T, Cap) {
            return @ptrCast(@alignCast(&self.arena[off]));
        }
    };
}

/// Dense SoA storage for component type `T` and capacity `Cap`.
fn Storage(comptime T: type, comptime Cap: usize) type {
    return struct {
        data: [Cap]T = undefined,
        dense: [Cap]u32 = undefined,
        sparse: [Cap]u32 = undefined,
        count: u32 = 0,

        const Self = @This();
        fn has(self: *const Self, idx: u32) bool {
            const d = self.sparse[idx];
            return d < self.count and self.dense[d] == idx;
        }

        fn add(self: *Self, idx: u32, val: T) void {
            self.data[idx] = val;
            self.dense[self.count] = idx;
            self.sparse[idx] = self.count;
            self.count += 1;
        }

        fn remove(self: *Self, idx: u32) void {
            const di = self.sparse[idx];
            const last = self.count - 1;
            const li = self.dense[last];
            self.dense[di] = li;
            self.sparse[li] = di;
            self.count -= 1;
        }
    };
}
