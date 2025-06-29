const std = @import("std");

const cstr = @import("../main.zig").cstr;

const vulkan = @import("vulkan");
const Loader = @import("Loader.zig");
const Device = @import("Device.zig");

const log = std.log.scoped(.shader);

const JobSystem = @import("../parallelization/JobSystem.zig");

const Shader = @This();

/// Shader stage enumeration used when creating modules and pipeline stages.
pub const Stage = enum {
    vertex,
    fragment,
    compute,
    geometry,
    tess_control,
    tess_eval,
};

comptime {
    std.debug.assert(@sizeOf(LoadJobData) <= JobSystem.Job.max_job_data_size);
}

/// Compiled shader module together with stage metadata.
module: vulkan.ShaderModule,
stage: Stage,
entry: [*:0]const u8,

pub const Error =
    Loader.Error ||
    std.fs.File.OpenError ||
    std.fs.File.ReadError ||
    std.fs.File.StatError ||
    error{
        BufferTooSmall,
        InvalidSpirvSize,
        InvalidSpirvMagic,
        CreateFailed,
    };

const HeaderInfo = struct {
    version_major: u8,
    version_minor: u8,
    generator: u32,
    bound: u32,
};

const LoadJobData = struct {
    loader: *const Loader,
    device: *const Device,
    path: [*:0]const u8,
    buf: []u32,
    out: *Shader,
    entry: [*:0]const u8,
    stage: Stage,
};

/// Create shader module from SPIR-V words already in memory.
/// The function validates the code, loads `vkCreateShaderModule` and
/// returns a managed `Shader` handle.
pub fn create(
    loader: *const Loader,
    dev: Device,
    code: []const u32,
    stage: Stage,
    entry: [*:0]const u8,
) Error!Shader {
    log.debug("create shader words={d}", .{code.len});

    if (code.len < 5) {
        return error.InvalidSpirvSize;
    }

    if (code[0] != 0x0723_0203) {
        return error.InvalidSpirvMagic;
    }

    dumpHeaderInfo(parseHeader(code));

    const get_dev = loader.loadInstanceFn(
        dev.inst.handle,
        vulkan.PfnGetDeviceProcAddr,
        cstr("vkGetDeviceProcAddr"),
    ) catch return error.CreateFailed;

    const create_fn = Loader.loadDeviceFn(
        get_dev,
        dev.logical,
        vulkan.PfnCreateShaderModule,
        cstr("vkCreateShaderModule"),
    ) catch return error.CreateFailed;

    var ci = vulkan.ShaderModuleCreateInfo{
        .s_type = .shader_module_create_info,
        .p_next = null,
        .flags = .{},
        .code_size = @intCast(code.len * 4),
        .p_code = code.ptr,
    };

    var mod: vulkan.ShaderModule = undefined;
    const res = create_fn(dev.logical, &ci, null, &mod);
    if (res != .success) {
        log.err("vkCreateShaderModule failed ({d})", .{@intFromEnum(res)});
        return error.CreateFailed;
    }

    log.debug("shader module created", .{});
    return .{ .module = mod, .stage = stage, .entry = entry };
}

/// Load SPIR-V from disk into `code_buf`, then call `create`.
/// The buffer must be large enough to hold the entire file.
pub fn fromFile(
    loader: *const Loader,
    dev: Device,
    stage: Stage,
    entry: [*:0]const u8,
    path: [*:0]const u8,
    code_buf: []u32,
) Error!Shader {
    log.debug("load SPV file '{s}'", .{std.mem.sliceTo(path, 0)});

    const file = try std.fs.cwd().openFile(std.mem.sliceTo(path, 0), .{});
    defer file.close();

    const info = try file.stat();
    log.debug("file size={d} bytes", .{info.size});
    if (info.size % 4 != 0) {
        return error.InvalidSpirvSize;
    }
    const words: usize = info.size / 4;
    if (words > code_buf.len) {
        return error.BufferTooSmall;
    }

    const bytes = @as([*]u8, @ptrCast(code_buf.ptr))[0..info.size];
    log.debug("reading {d} words into buffer[{d}]", .{ words, code_buf.len });
    const read_len = try file.readAll(bytes);
    log.debug("read {d} bytes", .{read_len});
    if (read_len != bytes.len) {
        return error.CreateFailed;
    }

    return create(loader, dev, code_buf[0..words], stage, entry);
}

/// Destroy shader module. Safe to call with partially-initialised Shader.
pub fn destroy(self: Shader, loader: *const Loader, dev: Device) void {
    const get_dev = loader.loadInstanceFn(
        dev.inst.handle,
        vulkan.PfnGetDeviceProcAddr,
        cstr("vkGetDeviceProcAddr"),
    ) catch return;

    const destroy_fn = Loader.loadDeviceFn(
        get_dev,
        dev.logical,
        vulkan.PfnDestroyShaderModule,
        cstr("vkDestroyShaderModule"),
    ) catch return;

    destroy_fn(dev.logical, self.module, null);
    log.debug("shader module destroyed", .{});
}

/// Queue a shader load job. Caller supplies scratch buffer and destination.
/// Returns a job handle which can be waited on via `js.wait(handle)`.
pub fn loadAsync(
    js: *JobSystem,
    loader: *const Loader,
    device: *const Device,
    stage: Stage,
    entry: [*:0]const u8,
    path: [*:0]const u8,
    buf: []u32,
    out: *Shader,
) ?JobSystem.Handle {
    var data: LoadJobData = .{
        .loader = loader,
        .device = device,
        .path = path,
        .buf = buf,
        .out = out,
        .entry = entry,
        .stage = stage,
    };

    const bytes = std.mem.asBytes(&data);
    const h = js.createJob(runLoad, .invalid, bytes);
    if (h) |handle| js.run(handle);
    return h;
}

fn dumpHeaderInfo(info: HeaderInfo) void {
    log.info("SPIR-V v{d}.{d} gen=0x{x} bound={d}", .{
        info.version_major,
        info.version_minor,
        info.generator,
        info.bound,
    });
}

fn parseHeader(words: []const u32) HeaderInfo {
    const ver = words[1];
    const major: u8 = @intCast((ver >> 16) & 0xff);
    const minor: u8 = @intCast((ver >> 8) & 0xff);
    return .{
        .version_major = major,
        .version_minor = minor,
        .generator = words[2],
        .bound = words[3],
    };
}

fn runLoad(ctx: *anyopaque, current: *JobSystem.Job) void {
    _ = ctx;

    var ld: LoadJobData = undefined;
    std.mem.copyForwards(u8, std.mem.asBytes(&ld), current.data[0..@sizeOf(LoadJobData)]);

    log.debug("async load '{s}'", .{std.mem.sliceTo(ld.path, 0)});

    const res = fromFile(ld.loader, ld.device.*, ld.stage, ld.entry, ld.path, ld.buf);
    if (res) |sh| ld.out.* = sh else |e| {
        log.err("async shader load failed: {s}", .{@errorName(e)});
    }
}
