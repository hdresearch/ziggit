const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const enable_git_fallback = b.option(bool, "git-fallback", "Enable git CLI fallback") orelse false;
    const options = b.addOptions();
    options.addOption(bool, "enable_git_fallback", enable_git_fallback);
    const exe_optimize: std.builtin.OptimizeMode = if (optimize == .Debug) .ReleaseFast else optimize;
    const exe = b.addExecutable(.{
        .name = "ziggit",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = exe_optimize,
            .imports = &.{
                .{ .name = "build_options", .module = options.createModule() },
            },
        }),
    });
    exe.linkLibC();
    exe.linkSystemLibrary("z");

    const install_artifact = b.addInstallArtifact(exe, .{});

    // Fix Zig's wrapper script issue: replace shell wrapper with actual binary
    // This must run AFTER install_artifact completes (which creates the wrapper)
    const fix_wrapper = b.addSystemCommand(&.{
        "sh", "-c",
        \\DEST="$1"
        \\BEST=$(ls -t .zig-cache/o/*/ziggit 2>/dev/null | while read f; do
        \\  if od -A n -t x1 -N 4 "$f" 2>/dev/null | grep -q '7f 45 4c 46'; then
        \\    echo "$f"; break
        \\  fi
        \\done)
        \\if [ -n "$BEST" ]; then
        \\  rm -f "$DEST"
        \\  cp "$BEST" "$DEST"
        \\  chmod +x "$DEST"
        \\fi
        ,
        "--",
        b.getInstallPath(.bin, "ziggit"),
    });
    fix_wrapper.step.dependOn(&install_artifact.step);

    // Install shell helper scripts needed by git test suite
    const shell_scripts = [_][]const u8{
        "git-sh-setup",
        "git-sh-i18n",
    };
    for (shell_scripts) |script| {
        b.getInstallStep().dependOn(&b.addInstallFile(
            b.path(b.fmt("shell-scripts/{s}", .{script})),
            b.fmt("bin/{s}", .{script}),
        ).step);
    }

    // Create git -> ziggit symlink so test suite can find 'git' command
    const symlink = b.addSystemCommand(&.{ "ln", "-sf", "ziggit", b.getInstallPath(.bin, "git") });
    symlink.step.dependOn(&fix_wrapper.step);
    b.getInstallStep().dependOn(&symlink.step);
}
