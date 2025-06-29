const std = @import("std");

const cstr = @import("../main.zig").cstr;

const vulkan = @import("vulkan");
const Loader = @import("Loader.zig");
const Device = @import("Device.zig");
const Shader = @import("Shader.zig");

const log = std.log.scoped(.pipeline);

const Pipeline = @This();

handle: vulkan.Pipeline,
layout: vulkan.PipelineLayout,

pub const Error =
    Loader.Error || Shader.Error || error{
        InvalidStageCount,
        DuplicateStage,
        IncompatibleShaders,
        BufferTooSmall,
        CreateFailed,
    };

/// Top-level user description of a pipeline. All slices reference memory
/// owned by the caller and must outlive `create`.
pub const Desc = struct {
    stages: []const Shader,
    vertex: VertexState = .{},
    assembly: InputAssemblyState = .{},
    raster: RasterState = .{},
    depth: DepthStencilState = .{},
    blend: BlendState = .{},
    dyn: DynamicState = .{},

    descriptor_set_layouts: []const vulkan.DescriptorSetLayout = &.{},
    push_constant_ranges: []const vulkan.PushConstantRange = &.{},
};

/// Scratch buffer group that holds intermediate Vulkan structs.
/// The slices must have enough capacity; otherwise `Error.BufferTooSmall` is returned.
pub const Scratch = struct {
    shader_stage_infos: []vulkan.PipelineShaderStageCreateInfo,
    vertex_bindings: []vulkan.VertexInputBindingDescription,
    vertex_attrs: []vulkan.VertexInputAttributeDescription,
    dynamic_states: []vulkan.DynamicState,
};

/// Vertex input configuration. Omitted arrays mean no bindings/attributes.
pub const VertexState = struct {
    bindings: []const Binding = &.{},
    attributes: []const Attribute = &.{},

    pub const Binding = struct {
        binding: u32,
        stride: u32,
        rate: Rate = .vertex,
    };

    pub const Attribute = struct {
        location: u32,
        binding: u32,
        format: vulkan.Format,
        offset: u32,
    };

    pub const Rate = enum { vertex, instance };
};

/// Input-assembly (primitive construction) state.
pub const InputAssemblyState = struct {
    topology: vulkan.PrimitiveTopology = .triangle_list,
    restart_enable: bool = false,
};

/// Rasterizer fixed-function options.
pub const RasterState = struct {
    polygon_mode: vulkan.PolygonMode = .fill,
    cull: vulkan.CullModeFlags = .{ .back_bit = true },
    front_face: vulkan.FrontFace = .counter_clockwise,
    line_width: f32 = 1.0,
    sample_count: vulkan.SampleCountFlags = .{ .@"1_bit" = true },
};

/// Depth / stencil testing state.
pub const DepthStencilState = struct {
    depth_test_enable: bool = false,
    depth_write_enable: bool = false,
    depth_compare_op: vulkan.CompareOp = .less_or_equal,
};

/// Colour-blend state for each render-target.
pub const BlendState = struct {
    attachments: []const Attachment = &.{},

    pub const Attachment = struct {
        blend_enable: bool = false,
        src_color: vulkan.BlendFactor = .one,
        dst_color: vulkan.BlendFactor = .zero,
        color_op: vulkan.BlendOp = .add,
        src_alpha: vulkan.BlendFactor = .one,
        dst_alpha: vulkan.BlendFactor = .zero,
        alpha_op: vulkan.BlendOp = .add,
        color_mask: vulkan.ColorComponentFlags = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
    };
};

/// Set of dynamic states toggled for this pipeline.
pub const DynamicState = struct {
    viewports: bool = true,
    scissors: bool = true,
    line_width: bool = false,
};

/// Create graphics pipeline.  Returns fully-initialised `Pipeline` on success.
/// Never allocates.
pub fn create(
    loader: *const Loader,
    dev: Device,
    desc: Desc,
    scratch: Scratch,
) Error!Pipeline {
    validateStages(desc) catch |e| return e;

    const stage_infos = try marshalStages(desc, scratch.shader_stage_infos);

    const vi = try marshalVertex(desc.vertex, desc.assembly, desc.raster, desc.depth, scratch);

    const dyn_states = marshalDynamic(desc.dyn, scratch.dynamic_states);

    const layout = try createLayout(loader, dev, desc);

    const pip = try createGraphics(loader, dev, stage_infos, vi, dyn_states, layout);

    return .{ .handle = pip, .layout = layout };
}

/// Destroy pipeline and associated layout.  Safe to call on partially-initialised values.
pub fn destroy(self: Pipeline, loader: *const Loader, dev: Device) void {
    const get_dev = loader.loadInstanceFn(
        dev.inst.handle,
        vulkan.PfnGetDeviceProcAddr,
        cstr("vkGetDeviceProcAddr"),
    ) catch return;

    const destroy_pipe = Loader.loadDeviceFn(
        get_dev,
        dev.logical,
        vulkan.PfnDestroyPipeline,
        cstr("vkDestroyPipeline"),
    ) catch return;

    const destroy_layout = Loader.loadDeviceFn(
        get_dev,
        dev.logical,
        vulkan.PfnDestroyPipelineLayout,
        cstr("vkDestroyPipelineLayout"),
    ) catch return;

    destroy_pipe(dev.logical, self.handle, null);
    destroy_layout(dev.logical, self.layout, null);

    log.debug("pipeline + layout destroyed", .{});
}

fn validateStages(desc: Desc) Error!void {
    if (desc.stages.len == 0) return Error.InvalidStageCount;

    var seen: u8 = 0;
    for (desc.stages) |st| {
        // Vulkan shader stage indices fit within 3 bits, cast accordingly for the shift amount.
        const stage_idx: u3 = @intCast(@intFromEnum(st.stage));
        const bit: u8 = @as(u8, 1) << stage_idx;
        if ((seen & bit) != 0) return Error.DuplicateStage;
        seen |= bit;
    }
}

fn marshalStages(
    desc: Desc,
    out_buf: []vulkan.PipelineShaderStageCreateInfo,
) Error![]vulkan.PipelineShaderStageCreateInfo {
    if (desc.stages.len > out_buf.len) return Error.BufferTooSmall;

    var idx: usize = 0;
    for (desc.stages) |sh| {
        out_buf[idx] = .{
            .s_type = .pipeline_shader_stage_create_info,
            .p_next = null,
            .flags = .{},
            .stage = shaderStageFlags(sh.stage),
            .module = sh.module,
            .p_name = sh.entry,
            .p_specialization_info = null,
        };
        idx += 1;
    }
    return out_buf[0..desc.stages.len];
}

fn shaderStageFlags(st: Shader.Stage) vulkan.ShaderStageFlags {
    return switch (st) {
        .vertex => .{ .vertex_bit = true },
        .fragment => .{ .fragment_bit = true },
        .compute => .{ .compute_bit = true },
        .geometry => .{ .geometry_bit = true },
        .tess_control => .{ .tessellation_control_bit = true },
        .tess_eval => .{ .tessellation_evaluation_bit = true },
    };
}

const VertexInfo = struct {
    vi: vulkan.PipelineVertexInputStateCreateInfo,
    ia: vulkan.PipelineInputAssemblyStateCreateInfo,
    rs: vulkan.PipelineRasterizationStateCreateInfo,
    ms: vulkan.PipelineMultisampleStateCreateInfo,
    ds: vulkan.PipelineDepthStencilStateCreateInfo,
    cb: vulkan.PipelineColorBlendStateCreateInfo,
};

fn marshalVertex(
    v: VertexState,
    ia_desc: InputAssemblyState,
    r: RasterState,
    d: DepthStencilState,
    scratch: Scratch,
) Error!VertexInfo {
    if (v.bindings.len > scratch.vertex_bindings.len or
        v.attributes.len > scratch.vertex_attrs.len) return Error.BufferTooSmall;

    for (v.bindings, 0..) |b, i| {
        scratch.vertex_bindings[i] = .{
            .binding = b.binding,
            .stride = b.stride,
            .input_rate = if (b.rate == .vertex) .vertex else .instance,
        };
    }

    for (v.attributes, 0..) |a, i| {
        scratch.vertex_attrs[i] = .{
            .location = a.location,
            .binding = a.binding,
            .format = a.format,
            .offset = a.offset,
        };
    }

    const vi = vulkan.PipelineVertexInputStateCreateInfo{
        .s_type = .pipeline_vertex_input_state_create_info,
        .p_next = null,
        .flags = .{},
        .vertex_binding_description_count = @intCast(v.bindings.len),
        .p_vertex_binding_descriptions = if (v.bindings.len == 0) null else scratch.vertex_bindings.ptr,
        .vertex_attribute_description_count = @intCast(v.attributes.len),
        .p_vertex_attribute_descriptions = if (v.attributes.len == 0) null else scratch.vertex_attrs.ptr,
    };

    const ia = vulkan.PipelineInputAssemblyStateCreateInfo{
        .s_type = .pipeline_input_assembly_state_create_info,
        .p_next = null,
        .flags = .{},
        .topology = ia_desc.topology,
        .primitive_restart_enable = if (ia_desc.restart_enable) 1 else 0,
    };

    const rs = vulkan.PipelineRasterizationStateCreateInfo{
        .s_type = .pipeline_rasterization_state_create_info,
        .p_next = null,
        .flags = .{},
        .depth_clamp_enable = 0,
        .rasterizer_discard_enable = 0,
        .polygon_mode = r.polygon_mode,
        .cull_mode = r.cull,
        .front_face = r.front_face,
        .depth_bias_enable = 0,
        .depth_bias_constant_factor = 0,
        .depth_bias_clamp = 0,
        .depth_bias_slope_factor = 0,
        .line_width = r.line_width,
    };

    const ms = vulkan.PipelineMultisampleStateCreateInfo{
        .s_type = .pipeline_multisample_state_create_info,
        .p_next = null,
        .flags = .{},
        .rasterization_samples = r.sample_count,
        .sample_shading_enable = 0,
        .min_sample_shading = 0,
        .p_sample_mask = null,
        .alpha_to_coverage_enable = 0,
        .alpha_to_one_enable = 0,
    };

    const ds = vulkan.PipelineDepthStencilStateCreateInfo{
        .s_type = .pipeline_depth_stencil_state_create_info,
        .p_next = null,
        .flags = .{},
        .depth_test_enable = if (d.depth_test_enable) 1 else 0,
        .depth_write_enable = if (d.depth_write_enable) 1 else 0,
        .depth_compare_op = d.depth_compare_op,
        .depth_bounds_test_enable = 0,
        .stencil_test_enable = 0,
        .front = undefined,
        .back = undefined,
        .min_depth_bounds = 0,
        .max_depth_bounds = 1,
    };

    const cb = vulkan.PipelineColorBlendStateCreateInfo{
        .s_type = .pipeline_color_blend_state_create_info,
        .p_next = null,
        .flags = .{},
        .logic_op_enable = 0,
        .logic_op = .copy,
        .attachment_count = 0,
        .p_attachments = null,
        .blend_constants = [_]f32{ 0, 0, 0, 0 },
    };

    return VertexInfo{ .vi = vi, .ia = ia, .rs = rs, .ms = ms, .ds = ds, .cb = cb };
}

fn marshalDynamic(desc: DynamicState, out: []vulkan.DynamicState) []vulkan.DynamicState {
    var idx: usize = 0;
    if (desc.viewports) {
        out[idx] = .viewport;
        idx += 1;
    }
    if (desc.scissors) {
        out[idx] = .scissor;
        idx += 1;
    }
    if (desc.line_width) {
        out[idx] = .line_width;
        idx += 1;
    }
    return out[0..idx];
}

fn createLayout(loader: *const Loader, dev: Device, desc: Desc) Error!vulkan.PipelineLayout {
    const get_dev = try loader.loadInstanceFn(dev.inst.handle, vulkan.PfnGetDeviceProcAddr, cstr("vkGetDeviceProcAddr"));

    const create_fn = try Loader.loadDeviceFn(get_dev, dev.logical, vulkan.PfnCreatePipelineLayout, cstr("vkCreatePipelineLayout"));

    const pci = vulkan.PipelineLayoutCreateInfo{
        .s_type = .pipeline_layout_create_info,
        .p_next = null,
        .flags = .{},
        .set_layout_count = @intCast(desc.descriptor_set_layouts.len),
        .p_set_layouts = if (desc.descriptor_set_layouts.len == 0) null else desc.descriptor_set_layouts.ptr,
        .push_constant_range_count = @intCast(desc.push_constant_ranges.len),
        .p_push_constant_ranges = if (desc.push_constant_ranges.len == 0) null else desc.push_constant_ranges.ptr,
    };

    var layout: vulkan.PipelineLayout = undefined;
    const res = create_fn(dev.logical, &pci, null, &layout);
    if (res != .success) return Error.CreateFailed;
    return layout;
}

fn createGraphics(
    loader: *const Loader,
    dev: Device,
    stages: []const vulkan.PipelineShaderStageCreateInfo,
    vi: VertexInfo,
    dyn_states: []const vulkan.DynamicState,
    layout: vulkan.PipelineLayout,
) Error!vulkan.Pipeline {
    const vp_state = vulkan.PipelineViewportStateCreateInfo{
        .s_type = .pipeline_viewport_state_create_info,
        .p_next = null,
        .flags = .{},
        .viewport_count = 1,
        .p_viewports = null,
        .scissor_count = 1,
        .p_scissors = null,
    };

    const dyn_info = vulkan.PipelineDynamicStateCreateInfo{
        .s_type = .pipeline_dynamic_state_create_info,
        .p_next = null,
        .flags = .{},
        .dynamic_state_count = @intCast(dyn_states.len),
        .p_dynamic_states = if (dyn_states.len == 0) null else dyn_states.ptr,
    };

    var prci = vulkan.PipelineRenderingCreateInfo{
        .s_type = .pipeline_rendering_create_info,
        .p_next = null,
        .view_mask = 0,
        .color_attachment_count = 0,
        .p_color_attachment_formats = null,
        .depth_attachment_format = .undefined,
        .stencil_attachment_format = .undefined,
    };

    const gci = vulkan.GraphicsPipelineCreateInfo{
        .s_type = .graphics_pipeline_create_info,
        .p_next = &prci,
        .flags = .{},
        .stage_count = @intCast(stages.len),
        .p_stages = stages.ptr,
        .p_vertex_input_state = &vi.vi,
        .p_input_assembly_state = &vi.ia,
        .p_tessellation_state = null,
        .p_viewport_state = &vp_state,
        .p_rasterization_state = &vi.rs,
        .p_multisample_state = &vi.ms,
        .p_depth_stencil_state = &vi.ds,
        .p_color_blend_state = &vi.cb,
        .p_dynamic_state = &dyn_info,
        .layout = layout,
        .render_pass = .null_handle,
        .subpass = 0,
        .base_pipeline_handle = .null_handle,
        .base_pipeline_index = -1,
    };

    const get_dev = try loader.loadInstanceFn(dev.inst.handle, vulkan.PfnGetDeviceProcAddr, cstr("vkGetDeviceProcAddr"));

    const create_fn = try Loader.loadDeviceFn(get_dev, dev.logical, vulkan.PfnCreateGraphicsPipelines, cstr("vkCreateGraphicsPipelines"));

    var pipeline: vulkan.Pipeline = undefined;
    const res = create_fn(
        dev.logical,
        .null_handle,
        1,
        @ptrCast(&gci),
        null,
        @as([*]vulkan.Pipeline, @ptrCast(&pipeline)),
    );
    if (res != .success) return Error.CreateFailed;
    return pipeline;
}
