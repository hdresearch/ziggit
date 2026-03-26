const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ========== BUILD OPTIONS ==========
    const enable_git_fallback = b.option(bool, "git-fallback", "Enable git CLI fallback for unimplemented commands (not available in WASM)") orelse true;

    // ========== MAIN CLI EXECUTABLE (default target) ==========
    const exe = b.addExecutable(.{
        .name = "ziggit",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    const exe_options = b.addOptions();
    exe_options.addOption(bool, "enable_git_fallback", enable_git_fallback);
    exe.root_module.addOptions("build_options", exe_options);
    
    b.installArtifact(exe);
    
    // Run command for CLI
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run ziggit CLI");
    run_step.dependOn(&run_cmd.step);

    // ========== LIBRARY BUILD ==========
    const lib_static = b.addStaticLibrary(.{
        .name = "ziggit",
        .root_source_file = b.path("src/lib/ziggit.zig"),
        .target = target,
        .optimize = optimize,
    });

    const install_lib = b.addInstallArtifact(lib_static, .{});
    
    // Install header file
    const install_header = b.addInstallFile(b.path("src/lib/ziggit.h"), "include/ziggit.h");

    const lib_step = b.step("lib", "Build libziggit.a + ziggit.h");
    lib_step.dependOn(&install_lib.step);
    lib_step.dependOn(&install_header.step);

    // ========== ZIGGIT MODULE ==========
    const ziggit_module = b.addModule("ziggit", .{
        .root_source_file = b.path("src/ziggit.zig"),
    });

    const platform_module = b.addModule("platform", .{
        .root_source_file = b.path("src/platform/platform.zig"),
    });

    // ========== TESTS ==========
    
    // Core integration tests
    const git_interop_test = b.addExecutable(.{
        .name = "git_interop_test", 
        .root_source_file = b.path("test/git_interop_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    git_interop_test.root_module.addImport("ziggit", ziggit_module);
    
    const core_compatibility_test = b.addExecutable(.{
        .name = "core_compatibility_test",
        .root_source_file = b.path("test/core_compatibility_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    core_compatibility_test.root_module.addImport("ziggit", ziggit_module);
    
    const workflow_test = b.addExecutable(.{
        .name = "workflow_integration_test",
        .root_source_file = b.path("test/workflow_integration_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    workflow_test.root_module.addImport("ziggit", ziggit_module);
    
    // Platform tests
    const platform_integration_test = b.addExecutable(.{
        .name = "platform_integration_test",
        .root_source_file = b.path("test/platform_integration_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    platform_integration_test.root_module.addImport("platform", platform_module);
    
    // BrokenPipe specific test
    const broken_pipe_test = b.addExecutable(.{
        .name = "broken_pipe_test",
        .root_source_file = b.path("test/broken_pipe_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    broken_pipe_test.root_module.addImport("platform", platform_module);

    // Bun workflow test
    const bun_zig_api_test = b.addTest(.{
        .root_source_file = b.path("test/bun_zig_api_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    bun_zig_api_test.root_module.addImport("ziggit", ziggit_module);

    // Unit tests for platform layer
    const platform_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/platform/platform.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Test step - runs all integration tests
    const test_step = b.step("test", "Run all unit tests and integration tests");
    test_step.dependOn(&b.addRunArtifact(platform_unit_tests).step);
    test_step.dependOn(&b.addRunArtifact(platform_integration_test).step);
    test_step.dependOn(&b.addRunArtifact(core_compatibility_test).step);
    test_step.dependOn(&b.addRunArtifact(git_interop_test).step);
    test_step.dependOn(&b.addRunArtifact(workflow_test).step);
    test_step.dependOn(&b.addRunArtifact(broken_pipe_test).step);
    test_step.dependOn(&b.addRunArtifact(bun_zig_api_test).step);

    // ========== BENCHMARKS ==========
    
    // Simple benchmark optimized for minimal disk usage
    const simple_benchmark = b.addExecutable(.{
        .name = "simple_benchmark",
        .root_source_file = b.path("benchmarks/simple_benchmark.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    // CLI benchmark (ziggit vs git performance)
    const cli_benchmark = b.addExecutable(.{
        .name = "cli_benchmark",
        .root_source_file = b.path("benchmarks/cli_benchmark.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    // Library API benchmark
    const lib_benchmark = b.addExecutable(.{
        .name = "lib_benchmark",
        .root_source_file = b.path("benchmarks/lib_benchmark.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_benchmark.root_module.addImport("ziggit", ziggit_module);
    
    // API vs CLI spawn benchmark - critical for proving performance advantage
    const api_vs_cli_benchmark = b.addExecutable(.{
        .name = "api_vs_cli_benchmark",
        .root_source_file = b.path("benchmarks/api_vs_cli_bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    api_vs_cli_benchmark.root_module.addImport("ziggit", ziggit_module);
    
    // Bun/npm workflow scenario benchmark
    const bun_scenario_benchmark = b.addExecutable(.{
        .name = "bun_scenario_benchmark",
        .root_source_file = b.path("benchmarks/bun_scenario_bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    bun_scenario_benchmark.root_module.addImport("ziggit", ziggit_module);

    const bench_step = b.step("bench", "Run all benchmarks");
    bench_step.dependOn(&b.addRunArtifact(simple_benchmark).step);
    bench_step.dependOn(&b.addRunArtifact(cli_benchmark).step);
    bench_step.dependOn(&b.addRunArtifact(lib_benchmark).step);
    bench_step.dependOn(&b.addRunArtifact(api_vs_cli_benchmark).step);
    bench_step.dependOn(&b.addRunArtifact(bun_scenario_benchmark).step);
    
    const simple_bench_step = b.step("bench-simple", "Run simple benchmark only");
    simple_bench_step.dependOn(&b.addRunArtifact(simple_benchmark).step);

    // ========== WASM TARGET ==========
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
    
    // WASM has git fallback disabled
    const wasm_options = b.addOptions();
    wasm_options.addOption(bool, "enable_git_fallback", false);
    wasm_exe.root_module.addOptions("build_options", wasm_options);
    
    // WASM memory configuration
    wasm_exe.stack_size = 256 * 1024; // 256KB stack
    wasm_exe.initial_memory = 16 * 1024 * 1024; // 16MB initial memory
    wasm_exe.max_memory = 32 * 1024 * 1024; // 32MB max memory

    const wasm_step = b.step("wasm", "Build for WebAssembly");
    wasm_step.dependOn(&b.addInstallArtifact(wasm_exe, .{}).step);

    // ========== UTILITY COMMANDS ==========
    
    // Clean command (manual: rm -rf zig-cache zig-out)
    const clean_step = b.step("clean", "Clean build artifacts (manual: rm -rf zig-cache zig-out)");
    _ = clean_step;
}