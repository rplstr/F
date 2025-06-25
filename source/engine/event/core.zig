const std = @import("std");

pub const queue_capacity: u16 = 1024;
pub const queue_mask: u16 = queue_capacity - 1;

comptime {
    if (queue_capacity & queue_mask != 0) {
        @compileError("queue_capacity must be a power-of-two");
    }
}

pub const max_listeners: u16 = 128;

pub const EventKind = enum(u8) {
    key_down,
    key_up,
    button_down,
    button_up,
    mouse_move,
    component_add,
    component_set,
    component_remove,
    entity_modified,
};

pub const Payload = struct {
    data: [16]u8 = undefined,
};

pub const Event = struct {
    kind: EventKind,
    payload: Payload,
};

pub const ListenerHandle = packed struct { slot: u16 };

pub const ListenerFn = fn (user_ctx: ?*anyopaque, ev: *const Event) callconv(.c) void;

const ListenerSlot = struct {
    fn_ptr: ListenerFn = undefined,
    ctx: ?*anyopaque = null,
    kind: EventKind = EventKind.key_down,
    active: bool = false,
};

var queue: [queue_capacity]Event = undefined;
var head: u16 = 0;
var tail: u16 = 0;

var listeners: [max_listeners]ListenerSlot = undefined;

/// Helper to push event given integer payload values.
/// Each param is stored little-endian into payload.
pub fn pushInts(kind: EventKind, p0: u32, p1: u32, p2: u32, p3: u32) void {
    var e: Event = undefined;
    e.kind = kind;
    std.mem.writeInt(u32, e.payload.data[0..4], p0, .little);
    std.mem.writeInt(u32, e.payload.data[4..8], p1, .little);
    std.mem.writeInt(u32, e.payload.data[8..12], p2, .little);
    std.mem.writeInt(u32, e.payload.data[12..16], p3, .little);
    push(&e);
}

/// Pushes an event. Overwrites the oldest when full.
/// Caller guarantees *ev lives on the stack; copy is taken.
pub fn push(ev: *const Event) void {
    const nt = nextIndex(tail);
    if (nt == head) {
        head = nextIndex(head);
    }
    queue[tail] = ev.*;
    tail = nt;
}

/// Registers a native listener for one EventKind. Returns opaque handle.
pub fn register(kind: EventKind, fn_ptr: ListenerFn, ctx: ?*anyopaque) ListenerHandle {
    var i: u16 = 0;
    while (i < max_listeners) : (i += 1) {
        const slot = &listeners[i];
        if (!slot.active) {
            slot.* = .{ .fn_ptr = fn_ptr, .ctx = ctx, .kind = kind, .active = true };
            return .{ .slot = i };
        }
    }
    @panic("listener pool exhausted");
}

pub fn unregister(handle: ListenerHandle) void {
    if (handle.slot >= max_listeners) return;
    listeners[handle.slot].active = false;
}

/// Invoked once per frame.
pub fn dispatchNative() void {
    var qi = head;
    while (qi != tail) : (qi = nextIndex(qi)) {
        const ev = queue[qi];
        var li: u16 = 0;
        while (li < max_listeners) : (li += 1) {
            const slot = listeners[li];
            if (!slot.active or slot.kind != ev.kind) continue;
            slot.fn_ptr(slot.ctx, &ev);
        }
    }
    head = tail;
}

/// Copies queued events into caller-provided slice, returns count copied.
/// Used to fetch events in bulk.
/// Copies queued events into dest. Does not clear the queue (peek).
/// For destructive read, see `drainTo`.
pub fn copyTo(dest: []Event) u16 {
    var count: u16 = 0;
    var qi = head;
    while (qi != tail and count < dest.len) : (qi = nextIndex(qi)) {
        dest[count] = queue[qi];
        count += 1;
    }
    return count;
}

/// Copy events into dest and clear them afterwards. Destructive read.
pub fn drainTo(dest: []Event) u16 {
    const copied = copyTo(dest);
    head = tail;
    return copied;
}

/// Optional reset.
pub fn reset() void {
    head = 0;
    tail = 0;
    for (&listeners) |*s| s.active = false;
}

pub fn isEmpty() bool {
    return head == tail;
}

pub fn isFull() bool {
    return nextIndex(tail) == head;
}

fn nextIndex(idx: u16) u16 {
    return (idx + 1) & queue_mask;
}
