const std = @import("std");

const Handle = @This();

index: u32,
generation: u32,

/// Represents an invalid or null handle. This is the default state for a handle
/// that does not point to a valid job, such as the parent of a root job.
pub const invalid = Handle{
    .index = std.math.maxInt(u32),
    .generation = 0,
};

/// Checks for equality between two handles.
/// For two handles to be considered equal, both their index and generation must match.
pub fn isEqual(self: Handle, other: Handle) bool {
    return (self.index == other.index) and (self.generation == other.generation);
}
