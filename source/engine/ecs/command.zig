const std = @import("std");

/// Kinds of commands that can be queued in a `CommandBuffer`.
pub const CmdKind = enum {
    add,
    set,
    rem,
    destroy,
};

/// Packed representation of a queued command in a `CommandBuffer`.
pub const Command = struct {
    kind: CmdKind,
    type_id: u64,
    src_off: u32,
    ent_idx: u32,
};

/// Fixed-capacity append-only buffer that stores commands prior to being flushed to the world.
pub fn CommandBuffer(
    comptime MaxCmd: usize,
    comptime StageBytes: usize,
) type {
    return struct {
        cmds: [MaxCmd]Command = undefined,
        cmd_len: u32 = 0,

        stage: if (StageBytes > 0) [StageBytes]u8 else void = undefined,
        stage_top: u32 = 0,

        const Self = @This();

        /// Reset the buffer, discarding all queued commands and staged payload data.
        pub fn clear(self: *Self) void {
            self.cmd_len = 0;
            self.stage_top = 0;
        }

        /// Push a raw command.
        pub fn push(self: *Self, cmd: Command, payload: ?[]const u8) !void {
            if (self.cmd_len >= MaxCmd) return error.OutOfSpace;
            var c = cmd;
            if (payload) |data| {
                if (StageBytes == 0) return error.OutOfSpace;
                if (self.stage_top + data.len > StageBytes) return error.OutOfSpace;
                std.mem.copy(u8, self.stage[self.stage_top .. self.stage_top + data.len], data);
                c.src_off = self.stage_top;
                self.stage_top += @intCast(data.len);
            }
            self.cmds[self.cmd_len] = c;
            self.cmd_len += 1;
        }
    };
}
