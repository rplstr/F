const invalid_idx: u32 = @as(u32, @intCast(~@as(u32, 0)));

/// Generic parent/child storage for an ECS world.
/// Manages tree relationships between entities without knowing about components.
pub fn Hierarchy(comptime Cap: usize) type {
    return struct {
        parent: [Cap]u32 = [_]u32{invalid_idx} ** Cap,
        first_child: [Cap]u32 = [_]u32{invalid_idx} ** Cap,
        next_sibling: [Cap]u32 = [_]u32{invalid_idx} ** Cap,

        const Self = @This();

        /// Mark entity `e_idx` as a root (no parent).
        pub fn setRoot(self: *Self, e_idx: u32) void {
            self.parent[e_idx] = invalid_idx;
            self.next_sibling[e_idx] = invalid_idx;
        }

        /// Attach child to new_parent (idx form). Use `invalid_idx` for root.
        pub fn attach(self: *Self, child_idx: u32, new_parent_idx: u32) void {
            const current = self.parent[child_idx];
            if (current != invalid_idx) {
                self.unlink(current, child_idx);
            }
            if (new_parent_idx != invalid_idx) {
                self.next_sibling[child_idx] = self.first_child[new_parent_idx];
                self.first_child[new_parent_idx] = child_idx;
                self.parent[child_idx] = new_parent_idx;
            } else {
                self.setRoot(child_idx);
            }
        }

        /// Iterate direct children of parent and invoke `cb(handle_idx)`.
        pub fn iterChildren(self: *Self, parent_idx: u32, cb: anytype) void {
            var c = self.first_child[parent_idx];
            while (c != invalid_idx) : (c = self.next_sibling[c]) {
                cb(c);
            }
        }

        fn unlink(self: *Self, p_idx: u32, c_idx: u32) void {
            var prev: u32 = invalid_idx;
            var cur = self.first_child[p_idx];
            while (cur != invalid_idx) : (cur = self.next_sibling[cur]) {
                if (cur == c_idx) {
                    if (prev == invalid_idx) {
                        self.first_child[p_idx] = self.next_sibling[cur];
                    } else {
                        self.next_sibling[prev] = self.next_sibling[cur];
                    }
                    break;
                }
                prev = cur;
            }
            self.next_sibling[c_idx] = invalid_idx;
            self.parent[c_idx] = invalid_idx;
        }
    };
}
