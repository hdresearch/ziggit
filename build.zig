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
    
    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run ziggit");
    run_step.dependOn(&run_cmd.step);

    // ========== LIBRARY BUILD ==========
    const lib_static = b.addStaticLibrary(.{
        .name = "ziggit",
        .root_source_file = b.path("src/lib/ziggit.zig"),
        .target = target,
        .optimize = optimize,
    });

    const install_lib = b.addInstallArtifact(lib_static, .{});
    
    // Install header if it exists
    const install_header = b.addInstallFile(b.path("src/lib/ziggit.h"), "include/ziggit.h");

    const lib_step = b.step("lib", "Build libziggit.a + ziggit.h");
    lib_step.dependOn(&install_lib.step);
    lib_step.dependOn(&install_header.step);

    // ========== ZIG MODULE ==========
    const ziggit_module = b.addModule("ziggit", .{
        .root_source_file = b.path("src/ziggit.zig"),
    });

    // ========== TESTS ==========
    
    // Platform unit tests
    const platform_tests = b.addTest(.{
        .root_source_file = b.path("src/platform/platform.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_platform_tests = b.addRunArtifact(platform_tests);

    // Git interop integration test (main integration test)
    const git_interop_test = b.addExecutable(.{
        .name = "git_interop_test",
        .root_source_file = b.path("test/git_interop_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    git_interop_test.root_module.addImport("ziggit", ziggit_module);
    const run_git_interop_test = b.addRunArtifact(git_interop_test);

    // Broken pipe test
    const broken_pipe_test = b.addExecutable(.{
        .name = "broken_pipe_test",
        .root_source_file = b.path("test/broken_pipe_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    broken_pipe_test.root_module.addImport("ziggit", ziggit_module);
    const run_broken_pipe_test = b.addRunArtifact(broken_pipe_test);

    // Integration test suite
    const integration_test_suite = b.addExecutable(.{
        .name = "integration_test_suite",
        .root_source_file = b.path("test/integration_test_suite.zig"),
        .target = target,
        .optimize = optimize,
    });
    integration_test_suite.root_module.addImport("ziggit", ziggit_module);
    const run_integration_test_suite = b.addRunArtifact(integration_test_suite);

    // Test step runs all tests
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_platform_tests.step);
    test_step.dependOn(&run_git_interop_test.step);
    test_step.dependOn(&run_broken_pipe_test.step);
    test_step.dependOn(&run_integration_test_suite.step);

    // ========== BENCHMARKS ==========
    const cli_benchmark = b.addExecutable(.{
        .name = "cli_benchmark",
        .root_source_file = b.path("benchmarks/cli_benchmark.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_cli_benchmark = b.addRunArtifact(cli_benchmark);

    const lib_benchmark = b.addExecutable(.{
        .name = "lib_benchmark",
        .root_source_file = b.path("benchmarks/lib_benchmark.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_benchmark.root_module.addImport("ziggit", ziggit_module);
    const run_lib_benchmark = b.addRunArtifact(lib_benchmark);

    const bun_scenario_benchmark = b.addExecutable(.{
        .name = "bun_scenario_benchmark",
        .root_source_file = b.path("benchmarks/bun_scenario_bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    bun_scenario_benchmark.root_module.addImport("ziggit", ziggit_module);
    const run_bun_scenario_benchmark = b.addRunArtifact(bun_scenario_benchmark);

    // API vs CLI benchmark (PHASE 1)
    const api_vs_cli_bench = b.addExecutable(.{
        .name = "api_vs_cli_bench",
        .root_source_file = b.path("benchmarks/api_vs_cli_bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    api_vs_cli_bench.root_module.addImport("ziggit", ziggit_module);
    const run_api_vs_cli_bench = b.addRunArtifact(api_vs_cli_bench);

    const bench_step = b.step("bench", "Run all benchmarks");
    bench_step.dependOn(&run_cli_benchmark.step);
    bench_step.dependOn(&run_lib_benchmark.step);
    bench_step.dependOn(&run_bun_scenario_benchmark.step);
    bench_step.dependOn(&run_api_vs_cli_bench.step);




    const debug_vs_release_bench = b.addExecutable(.{
        .name = "debug_vs_release_bench",
        .root_source_file = b.path("benchmarks/debug_vs_release_bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    debug_vs_release_bench.root_module.addImport("ziggit", ziggit_module);
    const run_debug_vs_release_bench = b.addRunArtifact(debug_vs_release_bench);

    const debug_release_bench_step = b.step("bench-debug", "Run debug vs release performance comparison (PHASE 3)");
    debug_release_bench_step.dependOn(&run_debug_vs_release_bench.step);

    const api_cli_bench_step = b.step("bench-api", "Run API vs CLI performance comparison (PHASE 1)");
    api_cli_bench_step.dependOn(&run_api_vs_cli_bench.step);

    // Optimization benchmark (PHASE 2)
    const optimization_bench = b.addExecutable(.{
        .name = "optimization_bench",
        .root_source_file = b.path("benchmarks/optimization_bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    optimization_bench.root_module.addImport("ziggit", ziggit_module);
    const run_optimization_bench = b.addRunArtifact(optimization_bench);

    const optimization_bench_step = b.step("bench-opt", "Run hot path optimization benchmarks (PHASE 2)");
    optimization_bench_step.dependOn(&run_optimization_bench.step);

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
    
    // WASM target always has git fallback disabled
    const wasm_options = b.addOptions();
    wasm_options.addOption(bool, "enable_git_fallback", false);
    wasm_exe.root_module.addOptions("build_options", wasm_options);
    
    wasm_exe.stack_size = 256 * 1024; // 256KB stack
    wasm_exe.initial_memory = 16 * 1024 * 1024; // 16MB initial memory
    wasm_exe.max_memory = 32 * 1024 * 1024; // 32MB max memory

    const wasm_step = b.step("wasm", "Build for WebAssembly");
    wasm_step.dependOn(&b.addInstallArtifact(wasm_exe, .{}).step);
}