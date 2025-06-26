//! Not finished.
//! Client<->Server transport.
const std = @import("std");

/// Maximum packet payload, bytes.
pub const pkt_cap_bytes: usize = 256;

/// Maximum queued packets each direction.
pub const q_cap_pkts: usize = 32;

comptime {
    std.debug.assert(@popCount(q_cap_pkts) == 1);
}

/// Logical peer endpoint.
pub const Peer = enum(u8) {
    client,
    server,
};

/// Handle returned by `recv`; value is number of bytes copied.
pub const RecvSize = u16;

const Packet = struct {
    len: u16 = 0,
    data: [pkt_cap_bytes]u8 = undefined,
};

const Ring = struct {
    head: std.atomic.Value(u32) = .init(0),
    tail: std.atomic.Value(u32) = .init(0),
    buf: [q_cap_pkts]Packet = undefined,

    /// Push `src` into queue. Returns `true` if enqueued.
    inline fn push(self: *Ring, src: []const u8) bool {
        const h = self.head.load(.acquire);
        const t = self.tail.load(.acquire);
        if (h - t >= q_cap_pkts) return false; // queue full

        const idx: usize = @intCast(h & (q_cap_pkts - 1));
        const pkt = &self.buf[idx];
        const sz: u16 = @intCast(@min(src.len, pkt_cap_bytes));
        pkt.len = sz;
        std.mem.copyForwards(u8, pkt.data[0..sz], src[0..sz]);
        self.head.store(h + 1, .release);
        return true;
    }

    /// Pop packet into `dst`. Returns number of bytes written or `null`.
    inline fn pop(self: *Ring, dst: []u8) ?RecvSize {
        const t = self.tail.load(.acquire);
        const h = self.head.load(.acquire);
        if (t == h) return null;

        const idx: usize = @intCast(t & (q_cap_pkts - 1));
        const pkt = &self.buf[idx];
        const sz: usize = @min(dst.len, pkt.len);
        std.mem.copyForwards(u8, dst[0..sz], pkt.data[0..sz]);
        self.tail.store(t + 1, .release);
        return @intCast(sz);
    }
};

/// Directional queues: client->server and server->client.
var c2s: Ring = .{};
var s2c: Ring = .{};

/// Send `data` from `from` peer to the opposite peer.
pub fn send(from: Peer, data: []const u8) bool {
    return switch (from) {
        .client => c2s.push(data),
        .server => s2c.push(data),
    };
}

/// Receive into `dst` for `to` peer. Returns bytes copied or `null`.
pub fn recv(to: Peer, dst: []u8) ?RecvSize {
    return switch (to) {
        .client => s2c.pop(dst),
        .server => c2s.pop(dst),
    };
}

const testing = std.testing;

test "send/recv" {
    var buf: [pkt_cap_bytes]u8 = undefined;
    const msg = "hello";

    try testing.expect(send(.client, msg));
    const sz_opt = recv(.server, buf[0..]);
    try testing.expect(sz_opt != null);
    const sz = sz_opt.?;
    try testing.expectEqual(@as(u16, msg.len), sz);
    try testing.expect(std.mem.eql(u8, buf[0..msg.len], msg));
}
