const std = @import("std");
const Job = @import("Job.zig");
const Deque = @import("Deque.zig");
const Handle = @import("Handle.zig");

const JobSystem = @import("../JobSystem.zig");
const Fiber = @import("../Fiber.zig");

const Worker = @This();

id: u32,
thread: std.Thread,
system: *JobSystem,
deque_high: Deque,
deque: Deque,

/// Fibers that became runnable (e.g., after waiting) and should be resumed.
ready_fibers: std.ArrayListUnmanaged(Fiber.Handle) = .{},

/// The main entry point for a worker thread.
/// This function contains the infinite loop where the worker finds and executes jobs.
pub fn run(self: *Worker) void {
    current_worker = self;

    rand = std.Random.DefaultPrng.init(@intCast(self.id));

    scheduler = Fiber.convertThread() catch {
        @panic("Failed to convert thread to fiber");
    };

    while (!self.system.should_terminate.load(.monotonic)) {
        if (self.ready_fibers.items.len > 0) {
            const fib_opt = self.ready_fibers.pop();
            if (fib_opt) |f| {
                Fiber.switchTo(f);
            }
            continue;
        }

        const maybe_job = self.findWork();

        if (maybe_job) |job_handle| {
            const ctx = self.system.allocator.create(JobFiberCtx) catch @panic("OOM");
            ctx.* = .{ .system = self.system, .handle = job_handle, .scheduler = scheduler };

            const job_fiber = Fiber.init(jobEntry, ctx, 32 * 1024) catch @panic("OOM");

            Fiber.switchTo(job_fiber);

            Fiber.destroy(job_fiber);
            self.system.allocator.destroy(ctx);
        } else {
            self.system.onWorkerIdle();
        }
    }
}

/// Attempts to find a job to execute.
/// It first checks the local deque, and if that's empty, it tries to steal from others.
fn findWork(self: *Worker) ?Handle {
    if (self.deque_high.popBottom()) |handle| {
        return handle;
    }

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
    const victim_index = rand.random().intRangeAtMost(u32, 0, @intCast(self.system.workers.len - 1));

    if (victim_index == self.id) {
        return null;
    }

    const victim = &self.system.workers[victim_index];

    if (victim.deque_high.steal()) |h| {
        return h;
    }
    return victim.deque.steal();
}

const JobFiberCtx = struct {
    system: *JobSystem,
    handle: Handle,
    scheduler: Fiber.Handle,
};

fn jobEntry(arg: ?*anyopaque) callconv(.C) void {
    const ctx: *JobFiberCtx = @ptrCast(@alignCast(arg.?));
    ctx.system.executeJob(ctx.handle);

    Fiber.switchTo(ctx.scheduler);
    unreachable;
}

pub threadlocal var scheduler: Fiber.Handle = null;
pub threadlocal var current_worker: ?*Worker = null;

threadlocal var rand: std.Random.DefaultPrng = undefined;

pub fn enqueueFiber(self: *Worker, fiber: Fiber.Handle) void {
    _ = self.ready_fibers.append(self.system.allocator, fiber) catch {};
}
