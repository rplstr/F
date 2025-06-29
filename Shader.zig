const std = @import("std");

step: std.Build.Step,

source_dir: []const u8,
output_dir: []const u8,
opt_flag: []const u8,
compiler: []const u8,

allocator: std.mem.Allocator,

/// Allocate and return a new shader compilation step.
pub fn createStep(b: *std.Build, cfg: Config) *@This() {
    const self = b.allocator.create(@This()) catch @panic("OOM");
    self.* = .{
        .step = .init(.{
            .id = .custom,
            .name = "compile shaders",
            .owner = b,
            .makeFn = make,
        }),
        .source_dir = cfg.source_dir,
        .output_dir = cfg.output_dir,
        .opt_flag = cfg.opt_flag,
        .compiler = cfg.compiler,
        .allocator = b.allocator,
    };
    return self;
}

/// Configuration record for `addShaderCompileStep`.
pub const Config = struct {
    /// Directory to scan recursively for shader source files.
    /// Path is interpreted relative to the project root.
    source_dir: []const u8,

    /// Directory where compiled `.spv` binaries will be written. The directory
    /// hierarchy mirrors `source_dir`; missing sub-directories are created
    /// automatically.
    output_dir: []const u8,

    /// Optimisation/validation flag forwarded verbatim to the external shader
    /// compiler.  Default `"-O"` means *full optimisation* for `glslc`.
    opt_flag: []const u8 = "-O",

    /// Executable name (or full path) of the shader compiler.  Defaults to
    /// `"glslc"`; `"glslangValidator"` is also compatible.
    compiler: []const u8 = "glslc",
};

const supported_exts = [_][]const u8{
    ".glsl",
    ".vert",
    ".frag",
    ".comp",
    ".geom",
    ".tesc",
    ".tese",
    ".mesh",
    ".task",
};

fn detectStage(path: []const u8) ?[]const u8 {
    const basename = std.fs.path.basename(path);

    inline for (supported_exts[1..]) |ext| { // skip generic .glsl
        if (std.mem.endsWith(u8, basename, ext)) {
            return std.mem.trimLeft(u8, ext, ".");
        }
    }

    if (std.mem.endsWith(u8, basename, ".glsl")) {
        const without_glsl = basename[0 .. basename.len - ".glsl".len];
        const stage_ext = std.fs.path.extension(without_glsl);
        if (stage_ext.len != 0) {
            inline for (supported_exts[1..]) |ext| {
                if (std.mem.eql(u8, stage_ext, ext)) {
                    return std.mem.trimLeft(u8, ext, ".");
                }
            }
        }
    }

    return null;
}

fn make(step_ptr: *std.Build.Step, opts: std.Build.Step.MakeOptions) anyerror!void {
    const self: *@This() = @fieldParentPtr("step", step_ptr);
    const gpa = self.allocator;

    var list = std.ArrayList([]const u8).init(gpa);
    defer list.deinit();

    try walkDir(self.source_dir, "", gpa, &list);

    if (list.items.len == 0) {
        return;
    }

    opts.progress_node.setEstimatedTotalItems(list.items.len);

    std.fs.cwd().makePath(self.output_dir) catch |e| {
        std.log.err("failed to create output dir '{s}': {s}", .{ self.output_dir, @errorName(e) });
        return e;
    };

    const pool = opts.thread_pool;

    var wg = std.Thread.WaitGroup{};
    var failed_any = std.atomic.Value(bool).init(false);

    for (list.items) |path_rel| {
        wg.start();
        try pool.spawn(compileOne, .{
            self.source_dir,
            self.output_dir,
            self.opt_flag,
            self.compiler,
            path_rel,
            &wg,
            &failed_any,
            opts.progress_node,
        });
    }

    wg.wait();

    if (failed_any.load(.seq_cst)) {
        return error.ShaderCompilationFailed;
    }
}

fn walkDir(
    base_dir: []const u8,
    subdir: []const u8,
    alloc: std.mem.Allocator,
    list: *std.ArrayList([]const u8),
) !void {
    // Resolve the directory we are about to inspect.
    const dir_path = if (subdir.len == 0)
        base_dir
    else
        try std.fs.path.join(alloc, &.{ base_dir, subdir });

    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        const rel_path = if (subdir.len == 0)
            try alloc.dupe(u8, entry.name)
        else
            try std.fs.path.join(alloc, &.{ subdir, entry.name });

        if (entry.kind == .file and hasSupportedExt(entry.name)) {
            try list.append(rel_path);
        } else if (entry.kind == .directory) {
            try walkDir(base_dir, rel_path, alloc, list);
        }
    }
}

fn compileOne(
    source_dir: []const u8,
    output_dir: []const u8,
    opt_flag: []const u8,
    compiler: []const u8,
    rel_path: []const u8,
    wg: *std.Thread.WaitGroup,
    failed_any: *std.atomic.Value(bool),
    root: std.Progress.Node,
) void {
    defer wg.finish();

    const node = root.start(rel_path, 0);
    defer node.end();

    var in_buf: [std.fs.max_path_bytes]u8 = undefined;
    const in_path = std.fmt.bufPrint(&in_buf, "{s}{c}{s}", .{ source_dir, std.fs.path.sep, rel_path }) catch unreachable;

    var out_name_buf: [std.fs.max_path_bytes]u8 = undefined;
    const spv_name = replaceExt(&out_name_buf, rel_path, ".spv");

    var out_buf: [std.fs.max_path_bytes]u8 = undefined;
    const out_path = std.fmt.bufPrint(&out_buf, "{s}{c}{s}", .{ output_dir, std.fs.path.sep, spv_name }) catch unreachable;

    if (std.fs.path.dirname(out_path)) |dir_name| {
        std.fs.cwd().makePath(dir_name) catch |e| {
            std.log.err("failed to create shader output dir '{s}': {s}", .{ dir_name, @errorName(e) });
            failed_any.store(true, .seq_cst);
            return;
        };
    }

    var argv = std.ArrayList([]const u8).init(std.heap.page_allocator);
    defer argv.deinit();

    argv.appendSlice(&.{compiler}) catch unreachable;
    argv.append(opt_flag) catch unreachable;

    if (detectStage(rel_path)) |stage| {
        if (std.mem.endsWith(u8, compiler, "glslc") or std.mem.endsWith(u8, compiler, "glslc.exe")) {
            var flag_buf: [32]u8 = undefined;
            const flag = std.fmt.bufPrint(&flag_buf, "-fshader-stage={s}", .{stage}) catch unreachable;
            argv.append(flag) catch unreachable;
        } else {
            argv.append("-S") catch unreachable;
            argv.append(stage) catch unreachable;
        }
    }

    argv.appendSlice(&.{ "-o", out_path, in_path }) catch unreachable;

    const argv_slice = argv.items;

    const cmd_buf = std.mem.join(std.heap.page_allocator, " ", argv_slice) catch unreachable;
    defer std.heap.page_allocator.free(cmd_buf);

    var child = std.process.Child.init(argv_slice, std.heap.page_allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Pipe;

    const run_result = child.spawnAndWait() catch |e| {
        std.log.err("failed to start shader compiler: {s}", .{@errorName(e)});
        failed_any.store(true, .seq_cst);
        return;
    };

    switch (run_result) {
        .Exited => |code| {
            if (code != 0) {
                std.log.err("shader compilation failed ({s} -> {s}) exit={d}", .{ rel_path, spv_name, code });
                failed_any.store(true, .seq_cst);
            }
        },
        else => {
            std.log.err("shader compilation failed ({s}): {any}", .{ rel_path, run_result });
            failed_any.store(true, .seq_cst);
        },
    }
}

fn hasSupportedExt(name: []const u8) bool {
    inline for (supported_exts) |ext| {
        if (std.mem.endsWith(u8, name, ext)) return true;
    }
    return false;
}

fn replaceExt(dst_buf: []u8, path: []const u8, new_ext: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse path.len;
    const res = std.fmt.bufPrint(dst_buf, "{s}{s}", .{ path[0..dot], new_ext }) catch unreachable;
    return res;
}
