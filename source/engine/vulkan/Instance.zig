const std = @import("std");
const builtin = @import("builtin");

const cstr = @import("../main.zig").cstr;
const cstrPtr = @import("../main.zig").cstrPtr;

const vulkan = @import("vulkan");

const Loader = @import("Loader.zig");

const Instance = @This();

handle: vulkan.Instance,

/// Create a Vulkan instance.
pub fn create(loader: Loader, cfg: Config) Error!Instance {
    var ext_buf: [32][*:0]const u8 = undefined;
    const ext_count = fillExtPtrs(cfg.extensions, &ext_buf);
    const exts = ext_buf[0..ext_count];

    const app_info = vulkan.ApplicationInfo{
        .s_type = .application_info,
        .p_next = null,
        .p_application_name = null,
        .application_version = 1,
        .p_engine_name = cstr("FEngine"),
        .engine_version = 1,
        .api_version = @bitCast(vulkan.API_VERSION_1_3),
    };

    var ci = vulkan.InstanceCreateInfo{
        .s_type = .instance_create_info,
        .p_next = null,
        .flags = .{},
        .p_application_info = &app_info,
        .enabled_layer_count = 0,
        .pp_enabled_layer_names = null,
        .enabled_extension_count = @intCast(exts.len),
        .pp_enabled_extension_names = if (exts.len == 0) null else exts.ptr,
    };

    const create_fn = try loader.loadInstanceFn(
        .null_handle,
        vulkan.PfnCreateInstance,
        cstr("vkCreateInstance"),
    );

    var inst: vulkan.Instance = undefined;
    const res = create_fn(&ci, null, &inst);
    if (res != .success) return error.CreateFailed;

    return .{ .handle = inst };
}

/// Destroy the instance via the loaded function pointer.
pub fn destroy(self: Instance, loader: Loader) void {
    const destroy_fn = loader.loadInstanceFn(
        self.handle,
        vulkan.PfnDestroyInstance,
        cstr("vkDestroyInstance"),
    ) catch return;
    destroy_fn(self.handle, null);
}

/// Structured list of extension names selected per-OS.
pub const ExtensionsList = struct {
    all: []const []const u8 = &.{},
    windows: []const []const u8 = &.{},
    linux: Linux = .{},

    pub const Linux = struct {
        wayland: []const []const u8 = &.{},
        x11: []const []const u8 = &.{},
    };
};

/// Configuration for `Instance.create`.
pub const Config = struct {
    app: []const u8,
    extensions: ExtensionsList = .{},
};

pub const Error = Loader.Error || error{CreateFailed};

fn fillExtPtrs(set: ExtensionsList, buf: *[32][*:0]const u8) usize {
    var idx: usize = 0;

    for (set.all) |e| {
        buf.*[idx] = cstrPtr(e);
        idx += 1;
    }

    switch (builtin.os.tag) {
        .windows => for (set.windows) |e| {
            buf.*[idx] = cstrPtr(e);
            idx += 1;
        },
        .linux => {
            for (set.linux.wayland) |e| {
                buf.*[idx] = cstrPtr(e);
                idx += 1;
            }
            for (set.linux.x11) |e| {
                buf.*[idx] = cstrPtr(e);
                idx += 1;
            }
        },
        else => {},
    }

    return idx;
}
