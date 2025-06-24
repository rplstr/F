const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const luajit_dep = b.dependency("luajit_build", .{
        .target = target,
        .optimize = optimize,
    });
    const luajit_module = luajit_dep.module("luajit-build");

    const engine = b.addModule("engine", .{
        .root_source_file = b.path("source/engine/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    engine.addImport("luajit", luajit_module);

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
}
