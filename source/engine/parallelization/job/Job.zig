const std = @import("std");
const Handle = @import("Handle.zig");

/// Amount of data (in bytes) a single job can hold.
pub const max_job_data_size = 64;

const Job = @This();

/// The signature for any function that can be executed as a job.
/// Receives an opaque context pointer (which will be a `*JobSystem`)
/// and a pointer to its own `Job` struct to access its data payload.
pub const Task = *const fn (system_context: *anyopaque, current_job: *Job) void;

task: Task,
parent: Handle,

/// This must be an atomic integer to allow multiple children to decrement it concurrently
/// without race conditions. Tracks how many of this job's children have not yet completed.
unfinished_jobs: std.atomic.Value(u32),

/// The generation is incremented each time this job slot is reused.
generation: u32,

/// The job's own index in the pool. Allows a job's task to get a handle to itself.
index: u32,

/// The data payload for the job.
data: [max_job_data_size]u8,

_padding: [36]u8,

/// Initializes a job with its task, parent, and data.
/// The `unfinished_jobs` counter is initialized to 1, representing the job itself.
/// When child jobs are spawned, this counter will be incremented.
pub fn init(task_fn: Task, parent_handle: Handle, job_data: []const u8) Job {
    std.debug.assert(job_data.len <= max_job_data_size);

    var new_job: Job = .{
        .task = task_fn,
        .parent = parent_handle,
        .unfinished_jobs = .init(1),
        .generation = 0,
        .index = 0,
        .data = undefined,
        ._padding = undefined,
    };

    @memcpy(new_job.data[0..job_data.len], job_data);

    return new_job;
}

comptime {
    std.debug.assert(@sizeOf(Job) == 128);
}
