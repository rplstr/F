//! Polling file watcher.
const std = @import("std");

const log = std.log.scoped(.@"file watcher");

pub const Callback = fn (watcher: *FileWatcher, path: []const u8) void;

pub const StartConfig = struct {
    allocator: ?std.mem.Allocator = null,
    /// Poll interval in milliseconds.
    poll_interval_ms: u64 = 500,
    /// Minimum delay between two callback invocations (milliseconds).
    debounce_ms: u64 = 0,
    /// Stack size for the watcher thread.
    stack_size: usize = 64 * 1024,
};

const FileWatcher = @This();

allocator: std.mem.Allocator,
path: []u8,
handle: ?std.Thread = null,
stop_flag: std.atomic.Value(bool) = .init(false),
callback: Callback,
poll_interval_ns: u64,
debounce_ns: u64,

/// Starts the watcher. The struct must outlive the spawned thread.
pub fn start(
    self: *FileWatcher,
    path: []const u8,
    callback: Callback,
    options: StartConfig,
) !void {
    if (self.handle != null) return error.AlreadyStarted;

    const gpa = options.allocator orelse std.heap.page_allocator;
    const path_copy = try gpa.alloc(u8, path.len);
    @memcpy(path_copy, path);

    self.allocator = gpa;
    self.path = path_copy;
    self.callback = callback;
    self.poll_interval_ns = options.poll_interval_ms * std.time.ns_per_ms;
    self.debounce_ns = options.debounce_ms * std.time.ns_per_ms;
    self.stop_flag.store(false, .seq_cst);

    self.handle = try .spawn(
        .{ .stack_size = options.stack_size },
        watchLoop,
        .{self},
    );
    log.info("watching on {s} with interval {d}ms", .{ path, options.poll_interval_ms });
}

/// Stops the watcher and frees associated resources. Blocks until the thread
/// terminates.
pub fn stop(self: *FileWatcher) void {
    if (self.handle) |t| {
        log.info("stopping watcher for '{s}'", .{self.path});
        self.stop_flag.store(true, .seq_cst);
        t.join();
        self.allocator.free(self.path);
        self.path = &[_]u8{};
        self.handle = null;
    }
}

/// Returns `true` if the watcher thread is currently running.
pub fn isRunning(self: *const FileWatcher) bool {
    return self.handle != null;
}

fn watchLoop(self: *FileWatcher) void {
    var file = std.fs.cwd().openFile(self.path, .{ .mode = .read_only }) catch |err| {
        log.err("failed to open '{s}': {s}", .{ self.path, @errorName(err) });
        return;
    };
    defer file.close();

    var last_stat = file.stat() catch std.fs.File.Stat{ .mtime = 0, .size = 0, .atime = 0, .ctime = 0, .mode = 0 };
    var last_cb_ts: u64 = 0;
    var timer = std.time.Timer.start() catch unreachable;

    while (!self.stop_flag.load(.seq_cst)) {
        const stat = file.stat() catch |err| {
            log.err("stat failed for '{s}': {s}", .{ self.path, @errorName(err) });
            break;
        };

        if (stat.mtime > last_stat.mtime) {
            const now = std.time.nanoTimestamp();
            if (self.debounce_ns == 0 or now - last_cb_ts >= self.debounce_ns) {
                last_cb_ts = now;
                self.callback(self, self.path);
            }
            last_stat = stat;
        }

        const elapsed = timer.lap();
        if (elapsed < self.poll_interval_ns) {
            std.Thread.sleep(self.poll_interval_ns - elapsed);
        }
    }
}
