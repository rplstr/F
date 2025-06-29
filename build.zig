const std = @import("std");
const Shader = @import("Shader.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const luajit_dep = b.dependency("luajit_build", .{
        .target = target,
        .optimize = optimize,
    });
    const luajit_module = luajit_dep.module("luajit-build");
    const vulkan_headers = b.dependency("vulkan_headers", .{});
    const vulkan = b.dependency("vulkan_zig", .{
        .registry = vulkan_headers.path("registry/vk.xml"),
    });
    const vulkan_module = vulkan.module("vulkan-zig");

    const engine = b.addModule("engine", .{
        .root_source_file = b.path("source/engine/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    engine.addImport("luajit", luajit_module);
    engine.addImport("vulkan", vulkan_module);

    const use_wayland = b.option(bool, "wayland", "Use Wayland backend on Linux") orelse false;

    const opts_step = b.addOptions();
    opts_step.addOption(bool, "wayland", use_wayland);
    engine.addOptions("options", opts_step);

    if (target.result.os.tag == .linux) {
        engine.linkSystemLibrary("X11", .{});
        engine.linkSystemLibrary("wayland-client", .{});

        // Generate XDG-Shell client protocol sources at build time so that the
        // required `wl_interface` definitions and helper wrappers are
        // available without relying on distro-specific pre-generated files.
        const proto_dir_path = "meta/wayland";
        std.fs.cwd().makePath(proto_dir_path) catch {};

        var code: u8 = 0;
        const proto_dir_from_pc = b.runAllowFail(&.{ "pkg-config", "--variable=pkgdatadir", "wayland-protocols" }, &code, .Ignore) catch null;

        const proto_dir_final = blk: {
            if (proto_dir_from_pc) |out| break :blk std.mem.trimRight(u8, out, "\n");
            if (b.graph.env_map.get("WAYLAND_PROTOCOLS_DIR")) |envdir| break :blk envdir;
            break :blk "/usr/share/wayland-protocols";
        };

        const xdg_xml_rel = b.pathJoin(&.{ proto_dir_final, "stable/xdg-shell/xdg-shell.xml" });

        // Output paths (relative to the build root).
        const xdg_header_rel = proto_dir_path ++ "/xdg-shell-client-protocol.h";
        const xdg_code_rel = proto_dir_path ++ "/xdg-shell-client-protocol.c";

        // wayland-scanner --generate-header
        const gen_header = b.addSystemCommand(&.{
            "wayland-scanner",
            "client-header",
            xdg_xml_rel,
            xdg_header_rel,
        });

        // wayland-scanner --generate-code
        const gen_code = b.addSystemCommand(&.{
            "wayland-scanner",
            "private-code",
            xdg_xml_rel,
            xdg_code_rel,
        });

        // Compile the generated C source and link it so that the interface
        // symbols (e.g. xdg_wm_base_interface) are provided to the linker.
        engine.addCSourceFile(.{ .file = b.path(xdg_code_rel) });
        engine.addSystemIncludePath(b.path(proto_dir_path));

        const extra_dep = b.addSystemCommand(&.{"true"});
        extra_dep.step.dependOn(&gen_header.step);
        extra_dep.step.dependOn(&gen_code.step);

        // Ensure wayland-client headers are discoverable.
        // We query pkg-config for the include directory and forward it to
        // both the translation unit and the main engine module
        // NOTE: I believe this can be simpler.
        var code_inc: u8 = 0;
        const cflags = b.runAllowFail(&.{ "pkg-config", "--cflags", "wayland-client" }, &code_inc, .Ignore) catch null;
        if (cflags) |flags| {
            var it = std.mem.tokenizeScalar(u8, flags, ' ');
            while (it.next()) |tok| {
                if (tok.len > 2 and tok[0] == '-' and tok[1] == 'I') {
                    const inc_path = std.mem.trimRight(u8, tok[2..], "\n");
                    const lazy_inc = if (std.fs.path.isAbsolute(inc_path))
                        std.Build.LazyPath{ .cwd_relative = inc_path }
                    else
                        b.path(inc_path);

                    engine.addIncludePath(lazy_inc);
                }
            }
        }
    }
    if (target.result.os.tag == .windows) {
        engine.linkSystemLibrary("dwmapi", .{});
    }

    const lua_api = b.addModule("runner", .{
        .root_source_file = b.path("source/lua/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    lua_api.addImport("luajit", luajit_module);
    lua_api.addImport("f", engine);

    const lua_exe = b.addExecutable(.{
        .name = "lua",
        .root_module = lua_api,
    });

    b.installArtifact(lua_exe);

    const run_cmd = b.addRunArtifact(lua_exe);

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run lua");
    run_step.dependOn(&run_cmd.step);

    const clean_step = b.step("clean", "Remove build artifacts");
    const rm_zig_out = b.addRemoveDirTree(b.path("zig-out"));
    const rm_meta = b.addRemoveDirTree(b.path("meta"));
    const rm_cache = b.addRemoveDirTree(b.path(".zig-cache"));

    clean_step.dependOn(&rm_meta.step);
    clean_step.dependOn(&rm_zig_out.step);
    clean_step.dependOn(&rm_cache.step);

    const shader_step = Shader.createStep(b, .{
        .source_dir = "assets/shaders",
        .output_dir = "assets/shaders",
        .opt_flag = "-O",
    });

    lua_exe.step.dependOn(&shader_step.step);
}
