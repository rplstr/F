const std = @import("std");

pub const Context = @This();

allocator: std.mem.Allocator,
string_table: std.StringHashMapUnmanaged([]const u8) = .{},

pub fn init(allocator: std.mem.Allocator) Context {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Context) void {
    var it = self.string_table.iterator();
    while (it.next()) |entry| {
        self.allocator.free(entry.key_ptr.*);
    }
    self.string_table.deinit(self.allocator);
}

/// Takes a string slice and returns a stable, interned slice.
/// If the string is new, it's added to the table. If it exists,
/// a pointer to the existing string is returned.
pub fn internString(self: *Context, str: []const u8) ![]const u8 {
    if (self.string_table.get(str)) |interned_str| {
        return interned_str;
    }

    const new_key = try self.allocator.dupe(u8, str);
    errdefer self.allocator.free(new_key);

    try self.string_table.put(self.allocator, new_key, new_key);
    return new_key;
}
