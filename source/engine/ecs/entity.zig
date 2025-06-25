/// Packed entity handle identifying an entity by slot index and generation.
pub const Handle = packed struct {
    idx: u24,
    gen: u8,
};

/// Pool allocator managing up to `Cap` entity handles, providing creation and validation utilities.
pub fn Pool(comptime Cap: usize) type {
    return struct {
        gens: [Cap]u8 = [_]u8{0} ** Cap,
        alive: [Cap]bool = [_]bool{false} ** Cap,
        free: [Cap]u32 = undefined,
        free_top: u32 = 0,
        alive_cnt: u32 = 0,

        const Self = @This();

        /// Initialise the pool.
        pub fn init(self: *Self) void {
            @setEvalBranchQuota(10_000);
            inline for (0..Cap) |i| self.free[i] = @intCast(Cap - 1 - i);
            self.free_top = Cap;
        }

        /// Create a new entity handle. Amortised O(1).
        pub fn create(self: *Self) !Handle {
            if (self.free_top == 0) return error.OutOfSpace;
            self.free_top -= 1;
            const idx = self.free[self.free_top];
            self.alive[idx] = true;
            self.alive_cnt += 1;
            return .{ .idx = @intCast(idx), .gen = self.gens[idx] };
        }

        /// Retire an entity handle. Marks the slot free. Does not touch any
        /// external component storage. O(1).
        pub fn destroy(self: *Self, h: Handle) !void {
            if (!self.isValid(h)) return error.InvalidHandle;
            self.gens[h.idx] +%= 1;
            self.alive[h.idx] = false;
            self.free[self.free_top] = h.idx;
            self.free_top += 1;
            self.alive_cnt -= 1;
        }

        /// Validate handle against current generation.
        pub fn isValid(self: *const Self, h: Handle) bool {
            return self.alive[h.idx] and self.gens[h.idx] == h.gen;
        }

        /// Quickly create a handle from index (without validation).
        pub inline fn handleFromIdx(self: *const Self, idx: u32) Handle {
            return .{ .idx = @intCast(idx), .gen = self.gens[idx] };
        }
    };
}
