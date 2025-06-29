const std = @import("std");
const builtin = @import("builtin");

const cstr = @import("../main.zig").cstr;
const cstrPtr = @import("../main.zig").cstrPtr;

const vulkan = @import("vulkan");
const Loader = @import("Loader.zig");
const Instance = @import("Instance.zig");

const Device = @This();

const log = std.log.scoped(.device);

/// Chosen physical device handle.
physical: vulkan.PhysicalDevice,

/// Created logical device handle.
logical: vulkan.Device,

/// Queue family indices selected for each capability.
queue_family: QueueFamilyIdx,

/// Acquired queues.
queue: Queues,

/// Parent Vulkan instance handle.
inst: Instance,

/// Pick physical + create logical device using `cfg`.
pub fn create(loader: *const Loader, inst: Instance, cfg: Config) Error!Device {
    log.debug("req: G={} C={} X={} kind={}", .{ cfg.req.graphics, cfg.req.compute, cfg.req.transfer, cfg.req.gpu_kind });
    var phys_buf: [16]vulkan.PhysicalDevice = undefined;
    const phys = phys_buf[0..enumPhysical(loader, inst, &phys_buf)];
    log.debug("found {} devices", .{phys.len});

    for (phys, 0..) |pd, idx| {
        printDeviceInfo(loader, inst, pd, idx);
    }
    if (phys.len == 0) return error.NoPhysicalDevice;

    const chosen = try selectPhysical(loader, phys, inst, cfg);

    {
        const props_fn = loader.loadInstanceFn(
            inst.handle,
            vulkan.PfnGetPhysicalDeviceProperties,
            cstr("vkGetPhysicalDeviceProperties"),
        ) catch null;
        if (props_fn) |fn_ptr| {
            var props: vulkan.PhysicalDeviceProperties = undefined;
            fn_ptr(chosen, &props);
            const name = std.mem.sliceTo(&props.device_name, 0);
            log.info("selected physical device: '{s}' (type={})", .{ name, props.device_type });
        } else {
            log.info("selected physical device (properties unavailable)", .{});
        }
    }

    const qfi = try findQueues(loader, chosen, inst, cfg);
    log.debug("qfam: g={} c={} x={} ", .{ qfi.graphics, qfi.compute, qfi.transfer });

    var queue_ci: [3]vulkan.DeviceQueueCreateInfo = undefined;
    const qci_len = buildQueueInfos(&queue_ci, qfi, cfg.queue_priority, cfg.req);
    log.debug("creating logical device with {} queue create infos", .{qci_len});

    for (queue_ci[0..qci_len], 0..) |ci, i| {
        log.debug("    qci[{d}]: fam={} cnt={} flg={x}", .{ i, ci.queue_family_index, ci.queue_count, ci.flags });
    }

    var dev_handle: vulkan.Device = undefined;

    var dyn_feat = vulkan.PhysicalDeviceDynamicRenderingFeatures{
        .s_type = .physical_device_dynamic_rendering_features,
        .p_next = null,
        .dynamic_rendering = 1,
    };

    dyn_feat.p_next = null;

    const dci = vulkan.DeviceCreateInfo{
        .s_type = .device_create_info,
        .p_next = &dyn_feat,
        .flags = .{},
        .queue_create_info_count = @intCast(qci_len),
        .p_queue_create_infos = @ptrCast(&queue_ci[0]),
        .enabled_layer_count = 0,
        .pp_enabled_layer_names = null,
        .enabled_extension_count = 0,
        .pp_enabled_extension_names = null,
        .p_enabled_features = null,
    };
    const create_fn = try loader.loadInstanceFn(inst.handle, vulkan.PfnCreateDevice, cstr("vkCreateDevice"));
    const res = create_fn(chosen, &dci, null, &dev_handle);
    if (res != .success) return error.CreateFailed;
    log.info("ldev ready", .{});

    const get_queue_fn = try loader.loadInstanceFn(inst.handle, vulkan.PfnGetDeviceQueue, cstr("vkGetDeviceQueue"));
    var q_gr: vulkan.Queue = undefined;
    var q_co: vulkan.Queue = undefined;
    var q_tr: vulkan.Queue = undefined;
    get_queue_fn(dev_handle, qfi.graphics, 0, &q_gr);
    get_queue_fn(dev_handle, qfi.compute, 0, &q_co);
    get_queue_fn(dev_handle, qfi.transfer, 0, &q_tr);

    log.debug("queues ok", .{});

    return .{
        .physical = chosen,
        .logical = dev_handle,
        .queue_family = qfi,
        .queue = .{ .graphics = q_gr, .compute = q_co, .transfer = q_tr },
        .inst = inst,
    };
}

/// Destroy logical device.
pub fn destroy(self: Device, loader: *const Loader, inst: Instance) void {
    log.debug("ldev destroy", .{});
    const destroy_fn = loader.loadInstanceFn(
        inst.handle,
        vulkan.PfnDestroyDevice,
        cstr("vkDestroyDevice"),
    ) catch return;
    destroy_fn(self.logical, null);
    log.info("ldev gone", .{});
}

/// Queue capability requirements toggles.
pub const Requirements = struct {
    graphics: bool = true,
    compute: bool = false,
    transfer: bool = false,

    gpu_kind: GpuKind = .any,
};

/// GPU kind preference.
pub const GpuKind = enum { any, integrated, discrete, virtual, cpu };

/// Device creation configuration.
pub const Config = struct {
    queue_priority: f32 = 1.0,
    req: Requirements = .{},
};

pub const Error = Loader.Error || error{
    NoPhysicalDevice,
    NoSuitableQueue,
    CreateFailed,
};

const Queues = struct {
    graphics: vulkan.Queue,
    compute: vulkan.Queue,
    transfer: vulkan.Queue,
};

const QueueFamilyIdx = struct {
    graphics: u32,
    compute: u32,
    transfer: u32,
};

fn enumPhysical(loader: *const Loader, inst: Instance, buf: []vulkan.PhysicalDevice) usize {
    log.debug("enum devs", .{});
    const enum_fn = loader.loadInstanceFn(
        inst.handle,
        vulkan.PfnEnumeratePhysicalDevices,
        cstr("vkEnumeratePhysicalDevices"),
    ) catch return 0;
    var count: u32 = @intCast(buf.len);
    _ = enum_fn(inst.handle, &count, null);
    if (count == 0) return 0;
    if (count > buf.len) count = @intCast(buf.len);
    _ = enum_fn(inst.handle, &count, buf.ptr);
    log.debug("vkEnumeratePhysicalDevices reported {} device(s)", .{count});
    return @intCast(count);
}

fn selectPhysical(loader: *const Loader, devices: []const vulkan.PhysicalDevice, inst: Instance, cfg: Config) Error!vulkan.PhysicalDevice {
    var fallback: ?vulkan.PhysicalDevice = null;
    for (devices) |pd| {
        if (!supportsRequirements(loader, pd, inst, cfg.req)) continue;

        if (cfg.req.gpu_kind == .any) return pd;

        const props_fn = loader.loadInstanceFn(
            inst.handle,
            vulkan.PfnGetPhysicalDeviceProperties,
            cstr("vkGetPhysicalDeviceProperties"),
        ) catch return pd;
        var props: vulkan.PhysicalDeviceProperties = undefined;
        props_fn(pd, &props);

        const dtype_enum = props.device_type;
        switch (cfg.req.gpu_kind) {
            .integrated => if (dtype_enum == .integrated_gpu) return pd,
            .discrete => if (dtype_enum == .discrete_gpu) return pd,
            .virtual => if (dtype_enum == .virtual_gpu) return pd,
            .cpu => if (dtype_enum == .cpu) return pd,
            else => {},
        }

        if (fallback == null) fallback = pd;
    }

    if (fallback == null) log.err("no physical device matched requirements", .{});
    if (fallback) |d| return d;
    return error.NoPhysicalDevice;
}

fn supportsRequirements(loader: *const Loader, pd: vulkan.PhysicalDevice, inst: Instance, req: Requirements) bool {
    const prop_fn = loader.loadInstanceFn(
        inst.handle,
        vulkan.PfnGetPhysicalDeviceQueueFamilyProperties,
        cstr("vkGetPhysicalDeviceQueueFamilyProperties"),
    ) catch return false;
    var count: u32 = 0;
    prop_fn(pd, &count, null);
    var props_buf: [32]vulkan.QueueFamilyProperties = undefined;
    prop_fn(pd, &count, @ptrCast(&props_buf[0]));

    var has_g = !req.graphics;
    var has_c = !req.compute;
    var has_t = !req.transfer;
    for (props_buf[0..count]) |p| {
        if (!has_g and p.queue_flags.graphics_bit == true) has_g = true;
        if (!has_c and p.queue_flags.compute_bit == true) has_c = true;
        if (!has_t and p.queue_flags.transfer_bit == true) has_t = true;
    }
    return has_g and has_c and has_t;
}

fn findQueues(loader: *const Loader, pd: vulkan.PhysicalDevice, inst: Instance, cfg: Config) Error!QueueFamilyIdx {
    const prop_fn = loader.loadInstanceFn(
        inst.handle,
        vulkan.PfnGetPhysicalDeviceQueueFamilyProperties,
        cstr("vkGetPhysicalDeviceQueueFamilyProperties"),
    ) catch return error.NoSuitableQueue;
    var count: u32 = 0;
    prop_fn(pd, &count, null);
    var props_buf: [32]vulkan.QueueFamilyProperties = undefined;
    prop_fn(pd, &count, @ptrCast(&props_buf[0]));

    var qfi = QueueFamilyIdx{ .graphics = 0, .compute = 0, .transfer = 0 };
    var found_g = false;
    var found_c = !cfg.req.compute;
    var found_t = !cfg.req.transfer;
    for (props_buf[0..count], 0..) |p, idx| {
        if (!found_g and p.queue_flags.graphics_bit == true) {
            qfi.graphics = @intCast(idx);
            found_g = true;
        }
        if (!found_c and p.queue_flags.compute_bit == true) {
            qfi.compute = @intCast(idx);
            found_c = true;
        }
        if (!found_t and p.queue_flags.transfer_bit == true) {
            qfi.transfer = @intCast(idx);
            found_t = true;
        }
    }
    if (!cfg.req.compute) qfi.compute = qfi.graphics;
    if (!cfg.req.transfer) qfi.transfer = qfi.graphics;

    if ((cfg.req.graphics and !found_g) or (cfg.req.compute and !found_c) or (cfg.req.transfer and !found_t)) {
        log.err("required queue family not found (g={}, c={}, t={})", .{ cfg.req.graphics, cfg.req.compute, cfg.req.transfer });
        return error.NoSuitableQueue;
    }
    log.debug("queue families selected", .{});
    return qfi;
}

fn buildQueueInfos(buf: *[3]vulkan.DeviceQueueCreateInfo, qfi: QueueFamilyIdx, prio: f32, req: Requirements) usize {
    const pri = @as([*]const f32, @ptrCast(&prio));
    var idx: usize = 0;

    // Always include graphics.
    buf.*[idx] = .{
        .s_type = .device_queue_create_info,
        .p_next = null,
        .flags = .{},
        .queue_family_index = qfi.graphics,
        .queue_count = 1,
        .p_queue_priorities = pri,
    };
    idx += 1;

    if (req.compute and qfi.compute != qfi.graphics) {
        buf.*[idx] = .{
            .s_type = .device_queue_create_info,
            .p_next = null,
            .flags = .{},
            .queue_family_index = qfi.compute,
            .queue_count = 1,
            .p_queue_priorities = pri,
        };
        idx += 1;
    }

    if (req.transfer and qfi.transfer != qfi.graphics and qfi.transfer != qfi.compute) {
        buf.*[idx] = .{
            .s_type = .device_queue_create_info,
            .p_next = null,
            .flags = .{},
            .queue_family_index = qfi.transfer,
            .queue_count = 1,
            .p_queue_priorities = pri,
        };
        idx += 1;
    }
    return idx;
}

fn printDeviceInfo(loader: *const Loader, inst: Instance, pd: vulkan.PhysicalDevice, idx: usize) void {
    const props_fn = loader.loadInstanceFn(
        inst.handle,
        vulkan.PfnGetPhysicalDeviceProperties,
        cstr("vkGetPhysicalDeviceProperties"),
    ) catch return;

    var props: vulkan.PhysicalDeviceProperties = undefined;
    props_fn(pd, &props);

    const name = std.mem.sliceTo(&props.device_name, 0);
    const dtype = @tagName(props.device_type);

    log.info("device[{d}]: '{s}' type={s} vendor=0x{x} device=0x{x} drv=0x{x} api=0x{x}", .{ idx, name, dtype, props.vendor_id, props.device_id, props.driver_version, props.api_version });

    const qprop_fn = loader.loadInstanceFn(
        inst.handle,
        vulkan.PfnGetPhysicalDeviceQueueFamilyProperties,
        cstr("vkGetPhysicalDeviceQueueFamilyProperties"),
    ) catch return;
    var qcount: u32 = 0;
    qprop_fn(pd, &qcount, null);
    var qprops_buf: [32]vulkan.QueueFamilyProperties = undefined;
    qprop_fn(pd, &qcount, @ptrCast(&qprops_buf));
    for (qprops_buf[0..qcount], 0..) |qp, qidx| {
        log.debug("    queue[{d}]: G={} C={} X={} count={d} ts={}bits", .{
            qidx,
            @intFromBool(qp.queue_flags.graphics_bit),
            @intFromBool(qp.queue_flags.compute_bit),
            @intFromBool(qp.queue_flags.transfer_bit),
            qp.queue_count,
            qp.timestamp_valid_bits,
        });
    }

    const mem_fn = loader.loadInstanceFn(
        inst.handle,
        vulkan.PfnGetPhysicalDeviceMemoryProperties,
        cstr("vkGetPhysicalDeviceMemoryProperties"),
    ) catch return;
    var mem_props: vulkan.PhysicalDeviceMemoryProperties = undefined;
    mem_fn(pd, &mem_props);
    for (mem_props.memory_heaps[0..mem_props.memory_heap_count], 0..) |heap, hidx| {
        const size_mb: usize = heap.size / (1024 * 1024);
        log.debug("    heap[{d}]: {d} MB flags={x}", .{ hidx, size_mb, heap.flags });
    }
}
