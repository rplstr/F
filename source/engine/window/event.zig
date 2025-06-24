const std = @import("std");

/// Maximum payload size each event can carry.
pub const max_payload = 24;

/// Identifies the semantic type of an `Event`.
pub const Id = enum(u16) {
    quit = 1,
    key_down,
    key_up,
    button_down,
    button_up,
    mouse_move,
    user_start = 0x100,
};

/// Small trivially copyable representation of an event.
pub const Event = struct {
    id: Id,
    /// Tells how many bytes of `payload` are actually used.
    size: u8,
    payload: [max_payload]u8,

    /// Create a new event from a `T` payload.
    /// Excess payload bytes are zero-initialised.
    pub fn init(comptime T: type, event_id: Id, value: T) Event {
        const bytes = std.mem.asBytes(&value);
        std.debug.assert(bytes.len <= max_payload);
        var self: Event = undefined;
        self.id = event_id;
        self.size = @intCast(bytes.len);
        @memcpy(self.payload[0..bytes.len], bytes);
        if (bytes.len < max_payload) {
            @memset(self.payload[bytes.len..], 0);
        }
        return self;
    }

    /// Create an empty event with no payload.
    pub fn empty(event_id: Id) Event {
        var ev: Event = undefined;
        ev.id = event_id;
        ev.size = 0;
        @memset(ev.payload[0..], 0);
        return ev;
    }
};

/// Fixed-capacity queue suitable for single-producer/
/// single-consumer scenarios.
pub const Queue = struct {
    const capacity = 256;
    buffer: [capacity]Event = undefined,
    head: u16 = 0,
    tail: u16 = 0,

    /// Push an event. Returns `false` when the queue is full.
    pub fn push(self: *Queue, ev: Event) bool {
        const next = @mod(self.head + 1, capacity);
        if (next == self.tail) return false;
        self.buffer[self.head] = ev;
        self.head = next;
        return true;
    }

    /// Attempt to pop an event. Returns `null` when empty.
    pub fn pop(self: *Queue) ?Event {
        if (self.tail == self.head) return null;
        const ev = self.buffer[self.tail];
        self.tail = @mod(self.tail + 1, capacity);
        return ev;
    }

    pub fn isEmpty(self: Queue) bool {
        return self.head == self.tail;
    }

    pub fn isFull(self: Queue) bool {
        return @mod(self.head + 1, capacity) == self.tail;
    }
};
