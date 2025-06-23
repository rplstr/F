//! A polling-based file watcher that monitors a file for modifications.
//!
//! The watcher operates on a separate thread. To release the
//! watcher thread and associated resources, `stop()` must be called.
const std = @import("std");

const FileWatcher = @This();

handle: std.Thread,
stop_signal: std.atomic.Value(bool),
context: WatchContext,

const WatchContext = struct {
    path_buffer: [std.fs.max_path_bytes]u8,
    path_len: usize,
    callback: fn () void,
    poll_interval_ns: u64,
};

pub const StartOptions = struct {
    poll_interval_ms: u64 = 500,
};

/// Spawns a new thread to watch a file for modifications.
///
/// The `path` is copied into an internal buffer. The `callback` is invoked
/// on the watcher's thread whenever the file's modification time changes.
pub fn start(
    self: *FileWatcher,
    path: []const u8,
    callback: fn () void,
    options: StartOptions,
) !void {
    if (path.len >= self.context.path_buffer.len) {
        return error.PathTooLong;
    }

    self.stop_signal.store(false, .seq_cst);

    @memcpy(self.context.path_buffer[0..path.len], path);

    self.context.path_len = path.len;
    self.context.callback = callback;
    self.context.poll_interval_ns = options.poll_interval_ms * std.time.ns_per_ms;

    self.handle = try .spawn(.{}, watchLoop, .{self});
}

/// Signals the watcher thread to stop and waits for it to terminate.
/// This function blocks until the thread has been fully joined.
pub fn stop(self: *FileWatcher) void {
    self.stop_signal.store(true, .seq_cst);
    self.handle.join();
}

fn watchLoop(watcher: *FileWatcher) void {
    const path = watcher.context.path_buffer[0..watcher.context.path_len];
    const callback = watcher.context.callback;
    const poll_interval_ns = watcher.context.poll_interval_ns;

    var last_mod_time: i64 = -1;

    while (!watcher.stop_signal.load(.seq_cst)) {
        const stat = std.fs.cwd().statFile(path) catch |err| {
            if (err != error.FileNotFound) {
                std.log.err("failed to stat '{s}': {s}", .{ path, @errorName(err) });
            }
            std.Thread.sleep(poll_interval_ns);
            continue;
        };

        if (last_mod_time < 0) {
            last_mod_time = stat.mtime;
        } else if (stat.mtime > last_mod_time) {
            last_mod_time = stat.mtime;
            callback();
        }

        std.Thread.sleep(poll_interval_ns);
    }
}
