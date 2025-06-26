const std = @import("std");
const Job = @import("Job.zig");
const Deque = @import("Deque.zig");
const Handle = @import("Handle.zig");

const JobSystem = @import("../JobSystem.zig");

const Worker = @This();

id: u32,
thread: std.Thread,
system: *JobSystem,
deque: Deque,

/// Each worker has its own random number generator.
rng: std.Random.DefaultPrng,

/// The main entry point for a worker thread.
/// This function contains the infinite loop where the worker finds and executes jobs.
pub fn run(self: *Worker) void {
    while (!self.system.should_terminate.load(.monotonic)) {
        const maybe_job = self.findWork();

        if (maybe_job) |job_handle| {
            self.system.executeJob(job_handle);
        } else {
            self.system.onWorkerIdle();
        }
    }
}

/// Attempts to find a job to execute.
/// It first checks the local deque, and if that's empty, it tries to steal from others.
fn findWork(self: *Worker) ?Handle {
    if (self.deque.popBottom()) |handle| {
        return handle;
    }

    const steal_attempts = 8;
    var i: u32 = 0;
    while (i < steal_attempts) : (i += 1) {
        if (self.stealWork()) |handle| {
            return handle;
        }
    }

    return null;
}

/// Attempts to steal a job from a randomly selected victim worker.
pub fn stealWork(self: *Worker) ?Handle {
    const victim_index = self.rng.random().intRangeAtMost(u32, 0, @intCast(self.system.workers.len - 1));

    if (victim_index == self.id) {
        return null;
    }

    const victim = &self.system.workers[victim_index];

    return victim.deque.steal();
}
