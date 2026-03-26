const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build options
    const enable_git_fallback = b.option(bool, "git-fallback", "Enable git CLI fallback") orelse true;

    const options = b.addOptions();
    options.addOption(bool, "enable_git_fallback", enable_git_fallback);

    // Create the ziggit module (used by bun via b.dependency)
    const ziggit_mod = b.addModule("ziggit", .{
        .root_source_file = b.path("src/ziggit.zig"),
        .target = target,
        .optimize = optimize,
    });
    ziggit_mod.addOptions("build_options", options);

    // Main executable
    const exe = b.addExecutable(.{
        .name = "ziggit",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "build_options", .module = options.createModule() },
            },
        }),
    });
    exe.linkLibC();
    exe.linkSystemLibrary("z");
    b.installArtifact(exe);
}
