const std = @import("std");

/// Kinds of observer notifications that can occur when components change.
pub const ObsKind = enum {
    add,
    remove,
    set,
};

/// Fixed-capacity list of observers that are notified about component lifecycle events.
pub fn ObserverList(comptime MaxObs: usize, comptime Handle: type) type {
    const ListError = error{OutOfSpace};
    return struct {
        obs_type: [MaxObs]u64 = [_]u64{0} ** MaxObs,
        obs_kind: [MaxObs]ObsKind = [_]ObsKind{.add} ** MaxObs,
        obs_cb: [MaxObs]*const fn (*anyopaque, Handle) void = undefined,
        obs_len: usize = 0,

        const Self = @This();

        /// Register a new observer callback for component type `tid` and event kind `kind`.
        pub fn register(self: *Self, tid: u64, kind: ObsKind, cb: fn (*anyopaque, Handle) void) !void {
            if (self.obs_len >= MaxObs) return ListError.OutOfSpace;
            self.obs_type[self.obs_len] = tid;
            self.obs_kind[self.obs_len] = kind;
            self.obs_cb[self.obs_len] = cb;
            self.obs_len += 1;
        }

        /// Invoke all callbacks matching the given component `tid` and event `kind`.
        pub fn notify(self: *Self, tid: u64, kind: ObsKind, world_ptr: *anyopaque, h: Handle) void {
            var i: usize = 0;
            while (i < self.obs_len) : (i += 1) {
                if (self.obs_type[i] == tid and self.obs_kind[i] == kind) {
                    self.obs_cb[i](world_ptr, h);
                }
            }
        }
    };
}
