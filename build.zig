const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const enable_git_fallback = b.option(bool, "git-fallback", "Enable git CLI fallback") orelse false;
    const options = b.addOptions();
    options.addOption(bool, "enable_git_fallback", enable_git_fallback);
    const exe_optimize: std.builtin.OptimizeMode = if (optimize == .Debug) .ReleaseFast else optimize;
    const exe = b.addExecutable(.{ .name = "ziggit", .root_source_file = b.path("src/main.zig"), .target = target, .optimize = exe_optimize });
    exe.root_module.addOptions("build_options", options);
    exe.linkLibC();
    exe.linkSystemLibrary("z");
    b.installArtifact(exe);
}
