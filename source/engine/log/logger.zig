const std = @import("std");
const tty = std.io.tty;
const Context = @import("../lua/Context.zig").Context;

pub const Logger = struct {
    context: *Context,
    scope: []const u8,

    pub fn info(self: *const Logger, message: []const u8) void {
        logFn(.info, self.scope, message);
    }

    pub fn warn(self: *const Logger, message: []const u8) void {
        logFn(.warn, self.scope, message);
    }

    pub fn err(self: *const Logger, message: []const u8) void {
        logFn(.err, self.scope, message);
    }
};

pub fn createInPlace(
    pointer: *Logger,
    context: *Context,
    scope: []const u8,
) !void {
    pointer.* = .{
        .context = context,
        .scope = try context.internString(scope),
    };
}

pub fn logFn(
    comptime level: std.log.Level,
    scope: []const u8,
    format: []const u8,
) void {
    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();

    const stderr = std.io.getStdErr();
    const tty_config = tty.detectConfig(stderr);
    const writer = stderr.writer();

    writer.print("{s}", .{scope}) catch {};
    tty_config.setColor(writer, .dim) catch {};
    writer.print(" @ {any}", .{std.Thread.getCurrentId()}) catch {};
    tty_config.setColor(writer, .reset) catch {};
    writer.print(": ", .{}) catch {};

    const msg_color: ?tty.Color = switch (level) {
        .err => .magenta,
        .warn => .red,
        else => null,
    };

    if (msg_color) |color| {
        tty_config.setColor(writer, color) catch {};
    }

    writer.print("{s}", .{level.asText()}) catch {};

    if (msg_color != null) {
        tty_config.setColor(writer, .reset) catch {};
    }

    writer.print(": ", .{}) catch {};
    writer.writeAll(format) catch {};
    writer.print("\n", .{}) catch {};
}

/// Used for `std_options`.
pub fn stdLogFn(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, format, args) catch {
        return;
    };
    logFn(level, @tagName(scope), msg);
}
