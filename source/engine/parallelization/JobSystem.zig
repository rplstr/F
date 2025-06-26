const std = @import("std");
const Job = @import("job/Job.zig");
const Handle = @import("job/Handle.zig");
const Deque = @import("job/Deque.zig");
const Worker = @import("job/Worker.zig");
const Semaphore = std.Thread.Semaphore;

const JobSystem = @This();

/// Maximum number of jobs that can be live at any one time.
pub const max_jobs = 4096;

/// A thread-local variable that stores the ID of the current worker thread.
/// This allows any function to know if it's running on a worker thread and which one.
threadlocal var worked_id: u32 = 0;

allocator: std.mem.Allocator,
workers: []Worker,
semaphore: std.Thread.Semaphore,

// The central pool of all job objects. By pre-allocating this, we avoid any
// dynamic memory allocation during the main execution loop.
job_pool: []Job,

// A lock-free stack used as a free list to recycle job indices.
// When a job is created, an index is popped. When it's finished, it's pushed back.
free_job_indices: [max_jobs]u32,
free_list_top: std.atomic.Value(u32),
should_terminate: std.atomic.Value(bool),

/// Creates worker threads, and prepares the job pool.
pub fn init(allocator: std.mem.Allocator) !*JobSystem {
    const self = try allocator.create(JobSystem);

    const num_threads = @max(1, try std.Thread.getCpuCount() - 1);

    self.* = .{
        .allocator = allocator,
        .workers = try allocator.alloc(Worker, num_threads),
        .semaphore = std.Thread.Semaphore{},
        .job_pool = try allocator.alloc(Job, max_jobs),
        .free_job_indices = undefined,
        .free_list_top = .init(0),
        .should_terminate = .init(false),
    };

    for (0..max_jobs) |i| {
        self.free_job_indices[i] = @intCast(i);
    }
    self.free_list_top.store(max_jobs, .monotonic);

    for (0..num_threads) |i| {
        const worker_id = @as(u32, @intCast(i + 1));
        self.workers[i] = .{
            .id = worker_id,
            .thread = undefined,
            .system = self,
            .deque = .init(),
            .rng = .init(@intCast(i)),
        };

        self.workers[i].thread = try .spawn(
            .{},
            runWorker,
            .{&self.workers[i]},
        );
    }

    return self;
}

/// Shuts down the job system and joins all worker threads.
pub fn deinit(self: *JobSystem) void {
    self.should_terminate.store(true, .release);

    for (self.workers) |_| {
        self.semaphore.post();
    }

    for (self.workers) |*worker| {
        worker.thread.join();
    }

    self.allocator.free(self.workers);
    self.allocator.free(self.job_pool);
    self.allocator.destroy(self);
}

/// Creates a new job with a given task and data.
/// This allocates a job from the pool but does not yet run it.
pub fn createJob(self: *JobSystem, task: Job.Task, parent: Handle, data: []const u8) ?Handle {
    const index = self.allocateJobIndex() orelse return null;
    const job = &self.job_pool[index];

    job.* = .init(task, parent, data);
    job.generation +%= 1;
    job.index = index;

    return Handle{ .index = index, .generation = job.generation };
}

/// Submits a job to be executed by the workers.
pub fn run(self: *JobSystem, handle: Handle) void {
    const worker_id = worked_id;

    if (worker_id == 0 or worker_id >= self.workers.len) {
        self.executeJob(handle);
        return;
    }

    const worker = &self.workers[worker_id];
    worker.deque.pushBottom(handle);
    self.semaphore.post();
}

/// Waits for a job and all of its children to complete.
/// This is an active wait; the calling thread will execute other jobs while waiting.
pub fn wait(self: *JobSystem, handle: Handle) void {
    while (!self.isJobDone(handle)) {
        const worker_id = worked_id;
        if (worker_id == 0 or worker_id >= self.workers.len) {
            std.Thread.yield() catch {};
            continue;
        }

        const worker = &self.workers[worker_id];

        var maybe_job = worker.deque.popBottom();
        if (maybe_job == null) {
            maybe_job = worker.stealWork();
        }

        if (maybe_job) |job_to_do| {
            self.executeJob(job_to_do);
        } else {
            std.Thread.yield() catch {};
        }
    }
}

/// Executes a single job.
pub fn executeJob(self: *JobSystem, handle: Handle) void {
    const job = &self.job_pool[handle.index];

    if (job.generation != handle.generation) return;

    job.task(self, job);

    self.finishJob(handle);
}

fn finishJob(self: *JobSystem, handle: Handle) void {
    const job = &self.job_pool[handle.index];

    const previous = job.unfinished_jobs.fetchSub(1, .acq_rel);

    if (previous == 1) {
        if (!job.parent.isEqual(.invalid)) {
            self.finishJob(job.parent);
        }

        self.freeJobIndex(handle.index);
    }
}

fn isJobDone(self: *JobSystem, handle: Handle) bool {
    const job = &self.job_pool[handle.index];

    if (job.generation != handle.generation) {
        return true;
    }

    return job.unfinished_jobs.load(.acquire) == 0;
}

fn allocateJobIndex(self: *JobSystem) ?u32 {
    var top = self.free_list_top.load(.monotonic);
    while (top > 0) {
        const new_top = top - 1;
        if (self.free_list_top.cmpxchgStrong(top, new_top, .acq_rel, .monotonic) == null) {
            const index = self.free_job_indices[new_top];

            self.job_pool[index].generation +%= 1;
            return index;
        }
        top = self.free_list_top.load(.monotonic);
    }
    return null;
}

fn freeJobIndex(self: *JobSystem, index: u32) void {
    var top = self.free_list_top.load(.monotonic);
    while (true) {
        self.free_job_indices[top] = index;
        const new_top = top + 1;
        if (self.free_list_top.cmpxchgStrong(top, new_top, .acq_rel, .monotonic) == null) {
            return;
        }

        top = self.free_list_top.load(.monotonic);
    }
}

/// Called by a worker when it becomes idle.
/// The worker will wait on the semaphore until woken up.
pub fn onWorkerIdle(self: *JobSystem) void {
    self.semaphore.wait();
}

/// The function that each worker thread executes in a loop.
fn runWorker(worker: *Worker) void {
    worked_id = worker.id;
    worker.run();
}

const testing = std.testing;

test "init and deinit" {
    const allocator = testing.allocator;
    var job_system = try JobSystem.init(allocator);
    defer job_system.deinit();
    try testing.expect(job_system.workers.len > 0);
}

const CounterJobContext = struct {
    counter: *std.atomic.Value(u32),
};

fn counterJobTask(system: *anyopaque, current_job: *const Job) void {
    _ = system;
    const context = std.mem.bytesToValue(CounterJobContext, current_job.data[0..@sizeOf(CounterJobContext)]);
    _ = context.counter.fetchAdd(1, .monotonic);
}

const RootJobContext = struct {
    counter: *std.atomic.Value(u32),
    num_children: u32,
};

fn rootJobTask(system_ptr: *anyopaque, current_job: *Job) void {
    const job_system = @as(*JobSystem, @ptrCast(@alignCast(system_ptr)));
    const context = std.mem.bytesToValue(RootJobContext, current_job.data[0..@sizeOf(RootJobContext)]);

    const self_handle = Handle{
        .index = current_job.index,
        .generation = current_job.generation,
    };

    _ = current_job.unfinished_jobs.fetchAdd(context.num_children, .release);

    for (0..context.num_children) |_| {
        const child_context = CounterJobContext{ .counter = context.counter };
        const child_data = @as([*]const u8, @ptrCast(&child_context))[0..@sizeOf(CounterJobContext)];

        const child_handle = job_system.createJob(counterJobTask, self_handle, child_data) orelse {
            @panic("Failed to create child job in test");
        };
        job_system.run(child_handle);
    }
}

test "single job" {
    const allocator = testing.allocator;
    var job_system = try init(allocator);
    defer job_system.deinit();

    var counter = std.atomic.Value(u32).init(0);
    const context = CounterJobContext{ .counter = &counter };
    const job_data = @as([*]const u8, @ptrCast(&context))[0..@sizeOf(CounterJobContext)];

    const job_handle = job_system.createJob(counterJobTask, Handle.invalid, job_data) orelse @panic("create failed");

    job_system.run(job_handle);
    job_system.wait(job_handle);

    try testing.expectEqual(@as(u32, 1), counter.load(.monotonic));
}

test "multiple children and waiting" {
    const allocator = testing.allocator;
    var job_system = try init(allocator);
    defer job_system.deinit();

    var counter = std.atomic.Value(u32).init(0);
    const num_children = 100;

    const context = RootJobContext{
        .counter = &counter,
        .num_children = num_children,
    };
    const job_data = @as([*]const u8, @ptrCast(&context))[0..@sizeOf(RootJobContext)];

    const root_handle = job_system.createJob(rootJobTask, Handle.invalid, job_data) orelse @panic("create failed");

    job_system.run(root_handle);
    job_system.wait(root_handle);

    try testing.expectEqual(num_children, counter.load(.monotonic));
}
