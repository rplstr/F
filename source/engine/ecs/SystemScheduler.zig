/// Ordered scheduler that executes registered systems according to their sort order.
pub fn SystemScheduler(comptime MaxSys: usize, comptime WorldPtr: type) type {
    const SchedulerError = error{OutOfSpace};
    return struct {
        sys_fn: [MaxSys]*const fn (WorldPtr, f32) void = undefined,
        sys_ord: [MaxSys]u8 = [_]u8{0} ** MaxSys,
        sys_len: u8 = 0,

        const Self = @This();

        /// Insert a new system callback keeping the list ordered by `order` (lower first).
        pub fn register(self: *Self, cb: *const fn (WorldPtr, f32) void, order: u8) !void {
            if (self.sys_len >= MaxSys) return SchedulerError.OutOfSpace;
            var i: usize = self.sys_len;
            while (i > 0 and self.sys_ord[i - 1] > order) : (i -= 1) {
                self.sys_fn[i] = self.sys_fn[i - 1];
                self.sys_ord[i] = self.sys_ord[i - 1];
            }
            self.sys_fn[i] = cb;
            self.sys_ord[i] = order;
            self.sys_len += 1;
        }

        /// Execute all registered systems in order, passing `dt` to each.
        pub fn run(self: *Self, world: WorldPtr, dt: f32) void {
            var i: usize = 0;
            while (i < self.sys_len) : (i += 1) {
                self.sys_fn[i](world, dt);
            }
        }
    };
}
