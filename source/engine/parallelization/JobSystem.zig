const std = @import("std");

const Semaphore = std.Thread.Semaphore;

pub const Handle = @import("job/Handle.zig");
pub const Deque = @import("job/Deque.zig");
pub const Worker = @import("job/Worker.zig");
pub const Fiber = @import("Fiber.zig");
pub const Job = @import("job/Job.zig");

const JobSystem = @This();

/// Maximum number of jobs that can be live at any one time.
pub const max_jobs = 4096;

/// A thread-local variable that stores the ID of the current worker thread.
/// This allows any function to know if it's running on a worker thread and which one.
threadlocal var worked_id: u32 = 0;

allocator: std.mem.Allocator,
workers: []Worker,
semaphore: std.Thread.Semaphore,

/// The central pool of all job objects.
job_pool: []Job,

// A lock-free stack used as a free list to recycle job indices.
// When a job is created, an index is popped. When it's finished, it's pushed back.
free_job_next: [max_jobs]u32,
free_list_head: std.atomic.Value(u32),
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
        .free_job_next = undefined,
        .free_list_head = .init(max_jobs),
        .should_terminate = .init(false),
    };

    for (0..max_jobs) |i| {
        self.free_job_next[i] = @intCast(i + 1);
    }
    self.free_job_next[max_jobs - 1] = max_jobs;
    self.free_list_head.store(0, .monotonic);

    for (0..num_threads) |i| {
        const worker_id = @as(u32, @intCast(i + 1));
        self.workers[i] = .{
            .id = worker_id,
            .thread = undefined,
            .system = self,
            .deque_high = .init(),
            .deque = .init(),
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

/// Submits a high-priority job to be executed by the workers.
pub fn runHigh(self: *JobSystem, handle: Handle) void {
    const worker_id = worked_id;

    if (worker_id == 0 or worker_id >= self.workers.len) {
        self.executeJob(handle);
        return;
    }

    const worker = &self.workers[worker_id];
    worker.deque_high.pushBottom(handle);
    self.semaphore.post();
}

/// Waits for a job and all of its children to complete.
/// This is an active wait; the calling thread will execute other jobs while waiting.
pub fn wait(self: *JobSystem, handle: Handle) void {
    if (self.isJobDone(handle)) return;

    const current_fiber = Fiber.current();
    const scheduler_fiber = Worker.scheduler;

    // If running on non-job thread (main thread), fallback to busy-wait path.
    if (current_fiber == null or current_fiber == scheduler_fiber) {
        var spin_loops: u32 = 0;
        const spin_threshold: u32 = 100;

        while (!self.isJobDone(handle)) {
            std.Thread.yield() catch {};
            if (spin_loops < spin_threshold) {
                std.atomic.spinLoopHint();
                spin_loops += 1;
            }
        }
        return;
    }

    // Running inside a job fibre – suspend.
    const job = &self.job_pool[handle.index];

    var node = self.allocator.create(WaiterNode) catch @panic("alloc waiter");
    node.* = .{ .fiber = current_fiber, .next = null };

    while (true) {
        const head = job.waiters_head.load(.monotonic);
        node.next = if (head) |h| @ptrCast(@alignCast(h)) else null;
        if (job.waiters_head.cmpxchgStrong(head, node, .acq_rel, .monotonic) == null) break;
    }

    Fiber.switchTo(scheduler_fiber);

    // resumed – job completed.
    self.allocator.destroy(node);
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

    const prev = job.unfinished_jobs.fetchSub(1, .acq_rel);
    if (prev - 1 != 0) {
        return;
    }

    const head_ptr = job.waiters_head.swap(null, .acq_rel);
    var node_ptr: ?*WaiterNode = if (head_ptr) |h| @ptrCast(@alignCast(h)) else null;
    while (node_ptr) |n| {
        if (Worker.current_worker) |w| {
            w.enqueueFiber(n.fiber);
        } else if (self.workers.len > 0) {
            self.workers[0].enqueueFiber(n.fiber);
            self.semaphore.post();
        }
        const next_ptr = n.next;
        self.allocator.destroy(n);
        node_ptr = next_ptr;
    }

    if (!job.parent.isEqual(.invalid)) {
        self.finishJob(job.parent);
    }

    self.freeJobIndex(handle.index);
}

fn isJobDone(self: *JobSystem, handle: Handle) bool {
    const job = &self.job_pool[handle.index];

    if (job.generation != handle.generation) {
        return true;
    }

    return job.unfinished_jobs.load(.acquire) == 0;
}

fn allocateJobIndex(self: *JobSystem) ?u32 {
    var head = self.free_list_head.load(.monotonic);
    while (head != max_jobs) {
        const next = self.free_job_next[head];
        if (self.free_list_head.cmpxchgStrong(head, next, .acq_rel, .monotonic) == null) {
            self.job_pool[head].generation +%= 1;
            return head;
        }
        head = self.free_list_head.load(.monotonic);
    }
    return null;
}

fn freeJobIndex(self: *JobSystem, index: u32) void {
    var head = self.free_list_head.load(.monotonic);
    while (true) {
        if (head != max_jobs) {
            self.free_job_next[index] = head;
        } else {
            self.free_job_next[index] = max_jobs;
        }
        if (self.free_list_head.cmpxchgStrong(head, index, .acq_rel, .monotonic) == null) {
            return;
        }
        head = self.free_list_head.load(.monotonic);
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

const WaiterNode = struct {
    fiber: Fiber.Handle,
    next: ?*WaiterNode,
};
