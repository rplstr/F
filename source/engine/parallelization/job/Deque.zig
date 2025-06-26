//! A lock-free, work-stealing deque.
//! `top` and `bottom` are the indices that manage the queue's state.
//! - `bottom`: This is the index where the next job will be pushed by the owner.
//!   It is incremented after a push. Only the owner thread can write to this.
//! - `top`: This is the index of the first available job for stealing.
//!   It is incremented by thieves after a successful steal.
const std = @import("std");
const Handle = @import("Handle.zig");

/// The capacity of each worker's deque.
pub const deque_capacity = 256;

const Deque = @This();

comptime {
    std.debug.assert(deque_capacity > 0 and (deque_capacity & (deque_capacity - 1)) == 0);
}

// These indices can wrap around. The actual number of items is `bottom - top`.
top: std.atomic.Value(usize),
bottom: std.atomic.Value(usize),

/// The circular buffer storing job handles.
buffer: [deque_capacity]Handle,

/// Initializes an empty deque.
/// Both `top` and `bottom` start at 0.
pub fn init() Deque {
    return Deque{
        .top = .init(0),
        .bottom = .init(0),
        .buffer = undefined,
    };
}

/// Pushes a job handle to the bottom of the deque. ONLY the owner thread may call this.
pub fn pushBottom(self: *Deque, handle: Handle) void {
    const b = self.bottom.load(.monotonic);
    const t = self.top.load(.monotonic);

    std.debug.assert(b >= t); // corruption
    const size = b - t;
    if (size >= deque_capacity) {
        @panic("job deque overflow");
    }

    self.buffer[b & (deque_capacity - 1)] = handle;

    self.bottom.store(b + 1, .release);
}

/// Pops a job handle from the bottom of the deque. ONLY the owner thread may call this.
/// This is the primary way a worker gets its own work (LIFO order).
pub fn popBottom(self: *Deque) ?Handle {
    var b = self.bottom.load(.monotonic);

    const t_now = self.top.load(.acquire);
    if (t_now == b) {
        return null;
    }

    const new_b = b -% 1;
    self.bottom.store(new_b, .monotonic);

    const t = self.top.load(.acquire);
    b = new_b;

    if (t <= b) {
        const handle = self.buffer[b & (deque_capacity - 1)];

        if (t == b) {
            if (self.top.cmpxchgStrong(t, t + 1, .acq_rel, .acquire) == null) {
                return handle;
            }
            self.bottom.store(b + 1, .monotonic);
            return null;
        }

        return handle;
    }

    self.bottom.store(b + 1, .monotonic);
    return null;
}

/// Steals a job handle from the top of the deque. ANY thread may call this.
/// This is how idle workers find new work (FIFO order).
pub fn steal(self: *Deque) ?Handle {
    const t = self.top.load(.acquire);
    const b = self.bottom.load(.acquire);

    if (t < b) {
        const handle = self.buffer[t & (deque_capacity - 1)];

        if (self.top.cmpxchgStrong(t, t + 1, .seq_cst, .seq_cst) == null) {
            return handle;
        }
    }

    return null;
}
