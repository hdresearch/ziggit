const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "ziggit",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run ziggit");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // WebAssembly target (WASI)
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
    });

    const wasm_exe = b.addExecutable(.{
        .name = "ziggit",
        .root_source_file = b.path("src/main.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });

    const wasm_step = b.step("wasm", "Build for WebAssembly (WASI)");
    wasm_step.dependOn(&b.addInstallArtifact(wasm_exe, .{}).step);

    // WebAssembly target (freestanding for browser) - Temporarily disabled
    // TODO: Resolve Zig stdlib POSIX dependencies in freestanding target
    // const wasm_freestanding_target = b.resolveTargetQuery(.{
    //     .cpu_arch = .wasm32,
    //     .os_tag = .freestanding,
    // });
    //
    // const wasm_freestanding_exe = b.addExecutable(.{
    //     .name = "ziggit-browser",
    //     .root_source_file = b.path("src/main_freestanding.zig"),
    //     .target = wasm_freestanding_target,
    //     .optimize = .ReleaseSmall,
    //     .strip = true,
    // });
    // 
    // // Export functions for browser environment
    // wasm_freestanding_exe.rdynamic = true;
    //
    // const wasm_browser_step = b.step("wasm-browser", "Build for WebAssembly (freestanding/browser)");
    // wasm_browser_step.dependOn(&b.addInstallArtifact(wasm_freestanding_exe, .{}).step);
}
