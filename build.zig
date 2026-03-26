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
    // Core git-ziggit interoperability test
    const core_test = b.addExecutable(.{
        .name = "git_ziggit_core_test",
        .root_source_file = b.path("test/git_ziggit_core_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_core_test = b.addRunArtifact(core_test);
    
    // Comprehensive integration test suite
    const integration_test = b.addExecutable(.{
        .name = "integration_test_suite",
        .root_source_file = b.path("test/integration_test_suite.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_integration_test = b.addRunArtifact(integration_test);
    
    // Existing git interop test
    const git_interop_test = b.addExecutable(.{
        .name = "git_interop_test",
        .root_source_file = b.path("test/git_interop_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_git_interop_test = b.addRunArtifact(git_interop_test);

    // Platform unit tests
    const platform_tests = b.addTest(.{
        .root_source_file = b.path("src/platform/platform.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_platform_tests = b.addRunArtifact(platform_tests);

    // BrokenPipe test
    const broken_pipe_test = b.addExecutable(.{
        .name = "broken_pipe_test",
        .root_source_file = b.path("test/broken_pipe_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_broken_pipe_test = b.addRunArtifact(broken_pipe_test);

    // Core git-ziggit interop test
    const core_interop_test = b.addExecutable(.{
        .name = "core_git_ziggit_interop",
        .root_source_file = b.path("test/core_git_ziggit_interop.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_core_interop_test = b.addRunArtifact(core_interop_test);

    // Pack file comprehensive test  
    const pack_comprehensive_test = b.addTest(.{
        .root_source_file = b.path("test/pack_file_comprehensive_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_pack_comprehensive_test = b.addRunArtifact(pack_comprehensive_test);

    // Comprehensive pack file delta tests
    const pack_delta_test = b.addTest(.{
        .root_source_file = b.path("test/pack_delta_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_pack_delta_test = b.addRunArtifact(pack_delta_test);

    // Git config comprehensive tests
    const config_test = b.addTest(.{
        .root_source_file = b.path("test/config_comprehensive_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_config_test = b.addRunArtifact(config_test);

    // Index extensions and versions tests
    const index_test = b.addTest(.{
        .root_source_file = b.path("test/index_extensions_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_index_test = b.addRunArtifact(index_test);

    // Symbolic refs and resolution tests
    const refs_test = b.addTest(.{
        .root_source_file = b.path("test/refs_symbolic_resolution_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_refs_test = b.addRunArtifact(refs_test);

    // Individual test steps
    const test_pack_step = b.step("test-pack", "Run pack file tests");
    test_pack_step.dependOn(&run_pack_delta_test.step);

    const test_config_step = b.step("test-config", "Run config parsing tests");
    test_config_step.dependOn(&run_config_test.step);

    const test_index_step = b.step("test-index", "Run index tests");
    test_index_step.dependOn(&run_index_test.step);

    const test_refs_step = b.step("test-refs", "Run refs resolution tests");
    test_refs_step.dependOn(&run_refs_test.step);

    // Test step runs all tests
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_platform_tests.step);
    test_step.dependOn(&run_core_test.step);
    test_step.dependOn(&run_integration_test.step);
    test_step.dependOn(&run_git_interop_test.step);
    test_step.dependOn(&run_broken_pipe_test.step);
    test_step.dependOn(&run_core_interop_test.step);
    test_step.dependOn(&run_pack_comprehensive_test.step);
    test_step.dependOn(&run_pack_delta_test.step);
    test_step.dependOn(&run_config_test.step);
    test_step.dependOn(&run_index_test.step);
    test_step.dependOn(&run_refs_test.step);

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

    const api_vs_cli_benchmark = b.addExecutable(.{
        .name = "api_vs_cli_benchmark",
        .root_source_file = b.path("benchmarks/api_vs_cli_bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    api_vs_cli_benchmark.root_module.addImport("ziggit", ziggit_module);
    const run_api_vs_cli_benchmark = b.addRunArtifact(api_vs_cli_benchmark);

    const status_optimization_benchmark = b.addExecutable(.{
        .name = "status_optimization_benchmark",
        .root_source_file = b.path("benchmarks/status_optimization_bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    status_optimization_benchmark.root_module.addImport("ziggit", ziggit_module);
    const run_status_optimization_benchmark = b.addRunArtifact(status_optimization_benchmark);

    const bench_step = b.step("bench", "Run all benchmarks");
    bench_step.dependOn(&run_cli_benchmark.step);
    bench_step.dependOn(&run_lib_benchmark.step);
    bench_step.dependOn(&run_bun_scenario_benchmark.step);
    bench_step.dependOn(&run_api_vs_cli_benchmark.step);

    const status_bench_step = b.step("bench-status", "Run status optimization benchmark");
    status_bench_step.dependOn(&run_status_optimization_benchmark.step);

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