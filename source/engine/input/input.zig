//! Input handling.
const std = @import("std");
const event = @import("../window/event.zig");
const core = @import("../event/core.zig");

/// Normalised keyboard codes, independent of platform.
pub const Key = enum(u16) {
    unknown = 0,
    // Printable
    space,
    a,
    b,
    c,
    d,
    e,
    f,
    g,
    h,
    i,
    j,
    k,
    l,
    m,
    n,
    o,
    p,
    q,
    r,
    s,
    t,
    u,
    v,
    w,
    x,
    y,
    z,
    num0,
    num1,
    num2,
    num3,
    num4,
    num5,
    num6,
    num7,
    num8,
    num9,
    // Control / nav
    escape,
    enter,
    tab,
    backspace,
    left,
    right,
    up,
    down,
    // modifiers (treated as keys as well)
    lshift,
    rshift,
    lctrl,
    rctrl,
    lalt,
    ralt,
    lsuper,
    rsuper,
    count,
};

pub const Button = enum(u8) { left = 1, right, middle, count };

/// Modifier bit-flags.
pub const Mods = packed struct {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    super: bool = false,
    _pad: u4 = 0,
};

pub const State = enum(u8) { up = 0, down = 1 };

pub const KeyPayload = packed struct {
    key: Key,
    mods: Mods,
    state: State,
};

pub const ButtonPayload = packed struct {
    button: Button,
    mods: Mods,
    state: State,
    x: i16,
    y: i16,
};

pub const MovePayload = packed struct {
    x: i16,
    y: i16,
};

/// Callers owns the instance.
pub const Context = struct {
    keys: [@intFromEnum(Key.count)]bool = .{false} ** @intFromEnum(Key.count),
    buttons: [@intFromEnum(Button.count)]bool = .{false} ** @intFromEnum(Button.count),
    mouse_x: i32 = 0,
    mouse_y: i32 = 0,

    /// Apply one window event to the state.
    pub fn handleEvent(self: *Context, ev: event.Event) void {
        switch (ev.id) {
            .key_down, .key_up => {
                const p = std.mem.bytesAsValue(KeyPayload, &ev.payload).*;
                self.keys[@intFromEnum(p.key)] = (ev.id == .key_down);

                core.pushInts(if (ev.id == .key_down) .key_down else .key_up, @intCast(@intFromEnum(p.key)), 0, 0, 0);
            },
            .button_down, .button_up => {
                const p = std.mem.bytesAsValue(ButtonPayload, &ev.payload).*;
                self.buttons[@intFromEnum(p.button)] = (ev.id == .button_down);
                self.mouse_x = p.x;
                self.mouse_y = p.y;

                core.pushInts(if (ev.id == .button_down) .button_down else .button_up, @intCast(@intFromEnum(p.button)), @as(u32, @intCast(p.x)), @as(u32, @intCast(p.y)), 0);
            },
            .mouse_move => {
                const p = std.mem.bytesAsValue(MovePayload, &ev.payload).*;
                self.mouse_x = p.x;
                self.mouse_y = p.y;

                core.pushInts(.mouse_move, @as(u32, @intCast(p.x)), @as(u32, @intCast(p.y)), 0, 0);
            },
            else => {},
        }
    }

    pub fn isKeyDown(self: Context, key: Key) bool {
        return self.keys[@intFromEnum(key)];
    }

    pub fn isButtonDown(self: Context, btn: Button) bool {
        return self.buttons[@intFromEnum(btn)];
    }
};

/// Helpers used by backends to translate platform codes into internal ones.
pub const Translate = struct {
    /// Windows virtual-key -> `Key`.
    pub fn vkToKey(vk: u32) Key {
        return switch (vk) {
            'A'...'Z' => |c| @enumFromInt(@as(u32, @intCast(c - 'A' + @intFromEnum(Key.a)))),
            '0'...'9' => |c| @enumFromInt(@as(u32, @intCast(c - '0' + @intFromEnum(Key.num0)))),
            0x20 => .space,
            0x1B => .escape,
            0x0D => .enter,
            0x25 => .left,
            0x26 => .up,
            0x27 => .right,
            0x28 => .down,
            else => .unknown,
        };
    }

    /// X11 KeySym -> `Key`.
    pub fn keySymToKey(ks: u32) Key {
        return switch (ks) {
            0xFF1B => .escape,
            0xFF0D => .enter,
            0xFF51 => .left,
            0xFF52 => .up,
            0xFF53 => .right,
            0xFF54 => .down,
            else => |sym| blk: {
                if (sym >= 'a' and sym <= 'z') break :blk @enumFromInt(sym - 'a' + @intFromEnum(Key.a));
                if (sym >= 'A' and sym <= 'Z') break :blk @enumFromInt(sym - 'A' + @intFromEnum(Key.a));
                if (sym >= '0' and sym <= '9') break :blk @enumFromInt(sym - '0' + @intFromEnum(Key.num0));
                break :blk .unknown;
            },
        };
    }

    /// X11 modifier mask -> `Mods`.
    pub fn modsFromMask(mask: u32) Mods {
        return .{
            .shift = (mask & 1) != 0,
            .ctrl = (mask & 4) != 0,
            .alt = (mask & 8) != 0,
            .super = (mask & 64) != 0,
        };
    }

    /// X11 mouse button code -> `Button`.
    pub fn buttonCodeToButton(btn: u32) Button {
        return switch (btn) {
            1 => .left,
            3 => .right,
            else => .middle,
        };
    }
};
