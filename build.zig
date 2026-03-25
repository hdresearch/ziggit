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

    // Unit tests for the main library
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    // Consolidated integration tests
    
    // Git interoperability test (git creates, ziggit reads and vice versa)
    const git_interop_test = b.addExecutable(.{
        .name = "git_interop_test",
        .root_source_file = b.path("test/git_interop_test.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_git_interop_test = b.addRunArtifact(git_interop_test);
    run_git_interop_test.step.dependOn(b.getInstallStep()); // Ensure ziggit is built first

    // Index format compatibility test (binary index compatibility)
    const index_format_test = b.addExecutable(.{
        .name = "index_format_test",
        .root_source_file = b.path("test/index_format_test.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_index_format_test = b.addRunArtifact(index_format_test);
    run_index_format_test.step.dependOn(b.getInstallStep());

    // Object format compatibility test (object store compatibility)
    const object_format_test = b.addExecutable(.{
        .name = "object_format_test",
        .root_source_file = b.path("test/object_format_test.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_object_format_test = b.addRunArtifact(object_format_test);
    run_object_format_test.step.dependOn(b.getInstallStep());

    // Command output compatibility test (CLI output format matching)
    const command_output_test = b.addExecutable(.{
        .name = "command_output_test",
        .root_source_file = b.path("test/command_output_test.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_command_output_test = b.addRunArtifact(command_output_test);
    run_command_output_test.step.dependOn(b.getInstallStep());

    // Individual test steps
    const git_interop_test_step = b.step("test-git-interop", "Run git interoperability tests");
    git_interop_test_step.dependOn(&run_git_interop_test.step);

    const index_format_test_step = b.step("test-index-format", "Run index format compatibility tests");
    index_format_test_step.dependOn(&run_index_format_test.step);

    const object_format_test_step = b.step("test-object-format", "Run object format compatibility tests");
    object_format_test_step.dependOn(&run_object_format_test.step);

    const command_output_test_step = b.step("test-command-output", "Run command output compatibility tests");
    command_output_test_step.dependOn(&run_command_output_test.step);

    // Main test step runs all tests
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_git_interop_test.step);
    test_step.dependOn(&run_index_format_test.step);
    test_step.dependOn(&run_object_format_test.step);
    test_step.dependOn(&run_command_output_test.step);

    // WebAssembly target (WASI)
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
    });

    const wasm_exe = b.addExecutable(.{
        .name = "ziggit",
        .root_source_file = b.path("src/main_wasi.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
        .strip = true,
    });
    
    wasm_exe.stack_size = 256 * 1024; // 256KB stack
    wasm_exe.initial_memory = 16 * 1024 * 1024; // 16MB initial memory
    wasm_exe.max_memory = 32 * 1024 * 1024; // 32MB max memory

    const wasm_step = b.step("wasm", "Build for WebAssembly (WASI)");
    wasm_step.dependOn(&b.addInstallArtifact(wasm_exe, .{}).step);

    // WebAssembly target (freestanding for browser)
    const wasm_freestanding_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    const wasm_freestanding_exe = b.addExecutable(.{
        .name = "ziggit-browser",
        .root_source_file = b.path("src/main_freestanding.zig"),
        .target = wasm_freestanding_target,
        .optimize = .ReleaseSmall,
        .strip = true,
    });
    
    wasm_freestanding_exe.rdynamic = true;
    wasm_freestanding_exe.stack_size = 16 * 1024; // 16KB stack
    wasm_freestanding_exe.initial_memory = 1024 * 1024; // 1MB initial memory
    wasm_freestanding_exe.max_memory = 4 * 1024 * 1024; // 4MB max memory
    
    const freestanding_memory_size = b.option(u32, "freestanding-memory-size", "Memory size for freestanding WASM build (default: 64KB)") orelse (64 * 1024);
    const options = b.addOptions();
    options.addOption(u32, "freestanding_memory_size", freestanding_memory_size);
    wasm_freestanding_exe.root_module.addOptions("config", options);

    const wasm_browser_step = b.step("wasm-browser", "Build for WebAssembly (freestanding/browser)");
    wasm_browser_step.dependOn(&b.addInstallArtifact(wasm_freestanding_exe, .{}).step);

    // Library builds for C integration
    const lib_static = b.addStaticLibrary(.{
        .name = "ziggit",
        .root_source_file = b.path("src/lib/ziggit.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    const lib_shared = b.addSharedLibrary(.{
        .name = "ziggit",
        .root_source_file = b.path("src/lib/ziggit.zig"),
        .target = target,
        .optimize = optimize,
    });

    const install_lib_static = b.addInstallArtifact(lib_static, .{});
    const install_lib_shared = b.addInstallArtifact(lib_shared, .{});
    const install_header = b.addInstallFile(b.path("src/lib/ziggit.h"), "include/ziggit.h");

    const lib_step = b.step("lib", "Build both static and shared libraries");
    lib_step.dependOn(&install_lib_static.step);
    lib_step.dependOn(&install_lib_shared.step);
    lib_step.dependOn(&install_header.step);

    const lib_static_step = b.step("lib-static", "Build static library");
    lib_static_step.dependOn(&install_lib_static.step);
    lib_static_step.dependOn(&install_header.step);

    const lib_shared_step = b.step("lib-shared", "Build shared library");
    lib_shared_step.dependOn(&install_lib_shared.step);
    lib_shared_step.dependOn(&install_header.step);
}