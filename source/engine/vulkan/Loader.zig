const std = @import("std");
const builtin = @import("builtin");

const cstr = @import("../main.zig").cstr;

const vulkan = @import("vulkan");

const Loader = @This();

// Handle to the Vulkan loader shared-library.
lib: std.DynLib,
// Cached pointer to vkGetInstanceProcAddr.
get_instance_proc_addr: vulkan.PfnGetInstanceProcAddr,

pub const Error = std.DynLib.Error || error{SymbolNotFound};

/// Open the operating-system Vulkan loader and fetch core symbols.
pub fn init() !Loader {
    const path = switch (builtin.os.tag) {
        .windows => "vulkan-1.dll",
        .linux => "libvulkan.so.1",
        else => "libvulkan.dylib",
    };

    var lib = try std.DynLib.open(path);
    const gip: vulkan.PfnGetInstanceProcAddr = try loadGlobal(
        vulkan.PfnGetInstanceProcAddr,
        &lib,
        cstr("vkGetInstanceProcAddr"),
    );

    return .{
        .lib = lib,
        .get_instance_proc_addr = gip,
    };
}

/// Release library handle. Loader struct becomes undefined afterwards.
pub fn deinit(self: *Loader) void {
    self.lib.close();
    self.* = undefined;
}

/// Load an instance-level function using the cached dispatcher.
pub fn loadInstanceFn(
    self: *const Loader,
    instance: vulkan.Instance,
    comptime T: type,
    name: [:0]const u8,
) !T {
    const addr = self.get_instance_proc_addr(instance, name.ptr);
    if (addr) |p| return @ptrCast(p);
    return error.SymbolNotFound;
}

/// Load a device-level function via `vkGetDeviceProcAddr`.
pub fn loadDeviceFn(
    device_getter: vulkan.PfnGetDeviceProcAddr,
    device: vulkan.Device,
    comptime T: type,
    name: [:0]const u8,
) !T {
    const addr = device_getter(device, name.ptr);
    if (addr) |p| return @ptrCast(p);
    return error.SymbolNotFound;
}

fn loadGlobal(comptime T: type, lib: *std.DynLib, sym: [:0]const u8) !T {
    const fn_ptr = lib.lookup(T, sym) orelse return error.SymbolNotFound;
    return fn_ptr;
}
