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
    // Add ziggit module so external projects (like bun) can import it
    const ziggit_module = b.addModule("ziggit", .{
        .root_source_file = b.path("src/ziggit.zig"),
    });
    // Expose it for the library as well
    lib_static.root_module.addImport("ziggit", ziggit_module);

    // ========== TESTS ==========
    // Platform unit tests
    const platform_tests = b.addTest(.{
        .root_source_file = b.path("src/platform/platform.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_platform_tests = b.addRunArtifact(platform_tests);

    // Git interoperability test (integration test)
    const git_interop_test = b.addExecutable(.{
        .name = "git_interop_test",
        .root_source_file = b.path("test/git_interop_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_git_interop_test = b.addRunArtifact(git_interop_test);

    // Enhanced git interoperability test
    const enhanced_git_interop_test = b.addExecutable(.{
        .name = "enhanced_git_interop_test",
        .root_source_file = b.path("test/enhanced_git_interop_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_enhanced_git_interop_test = b.addRunArtifact(enhanced_git_interop_test);

    // Comprehensive git interoperability test
    const comprehensive_git_interop_test = b.addExecutable(.{
        .name = "comprehensive_git_interop_test",
        .root_source_file = b.path("test/comprehensive_git_interop_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_comprehensive_git_interop_test = b.addRunArtifact(comprehensive_git_interop_test);
    
    const comprehensive_interop_step = b.step("comprehensive-interop", "Run comprehensive git interoperability test");
    comprehensive_interop_step.dependOn(&run_comprehensive_git_interop_test.step);

    // Tool compatibility test (critical for bun/npm workflows)
    const tool_compat_test = b.addExecutable(.{
        .name = "tool_compatibility_test", 
        .root_source_file = b.path("test/tool_compatibility_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_tool_compat_test = b.addRunArtifact(tool_compat_test);

    // Other integration tests
    const index_format_test = b.addExecutable(.{
        .name = "index_format_test",
        .root_source_file = b.path("test/index_format_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_index_format_test = b.addRunArtifact(index_format_test);

    const object_format_test = b.addExecutable(.{
        .name = "object_format_test",
        .root_source_file = b.path("test/object_format_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_object_format_test = b.addRunArtifact(object_format_test);

    const command_output_test = b.addExecutable(.{
        .name = "command_output_test",
        .root_source_file = b.path("test/command_output_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_command_output_test = b.addRunArtifact(command_output_test);

    // BrokenPipe handling test
    const broken_pipe_test = b.addExecutable(.{
        .name = "broken_pipe_test",
        .root_source_file = b.path("test/broken_pipe_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_broken_pipe_test = b.addRunArtifact(broken_pipe_test);

    // Library status test (requires ziggit module)
    const lib_status_test = b.addTest(.{
        .root_source_file = b.path("test/lib_status_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    const ziggit_mod = b.addModule("ziggit", .{
        .root_source_file = b.path("src/lib/ziggit.zig"),
    });
    lib_status_test.root_module.addImport("ziggit", ziggit_mod);
    const run_lib_status_test = b.addRunArtifact(lib_status_test);

    // Comprehensive library status test
    const lib_comprehensive_status_test = b.addTest(.{
        .root_source_file = b.path("test/lib_comprehensive_status_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    lib_comprehensive_status_test.root_module.addImport("ziggit", ziggit_mod);
    const run_lib_comprehensive_status_test = b.addRunArtifact(lib_comprehensive_status_test);

    // Bun Zig API test (uses our pure Zig API)
    const bun_zig_api_test = b.addTest(.{
        .root_source_file = b.path("test/bun_zig_api_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    bun_zig_api_test.root_module.addImport("ziggit", ziggit_module);
    const run_bun_zig_api_test = b.addRunArtifact(bun_zig_api_test);

    // Test step runs all tests
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_platform_tests.step);
    test_step.dependOn(&run_git_interop_test.step);
    test_step.dependOn(&run_enhanced_git_interop_test.step);
    test_step.dependOn(&run_comprehensive_git_interop_test.step);
    test_step.dependOn(&run_tool_compat_test.step);
    test_step.dependOn(&run_index_format_test.step);
    test_step.dependOn(&run_object_format_test.step);
    test_step.dependOn(&run_command_output_test.step);
    test_step.dependOn(&run_broken_pipe_test.step);
    test_step.dependOn(&run_lib_status_test.step);
    test_step.dependOn(&run_lib_comprehensive_status_test.step);
    test_step.dependOn(&run_bun_zig_api_test.step);

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

    // Zig API vs Git CLI benchmark (ITEM 7)
    const zig_api_benchmark = b.addExecutable(.{
        .name = "zig_api_benchmark",
        .root_source_file = b.path("benchmarks/zig_api_bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    zig_api_benchmark.root_module.addImport("ziggit", ziggit_module);
    const run_zig_api_benchmark = b.addRunArtifact(zig_api_benchmark);

    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&run_cli_benchmark.step);
    bench_step.dependOn(&run_lib_benchmark.step);
    bench_step.dependOn(&run_bun_scenario_benchmark.step);
    bench_step.dependOn(&run_zig_api_benchmark.step);
    
    const zig_api_bench_step = b.step("zig-api-bench", "Run Zig API vs Git CLI benchmark");
    zig_api_bench_step.dependOn(&run_zig_api_benchmark.step);
    
    // API vs CLI benchmark (minimal essential benchmark)
    const api_vs_cli_benchmark = b.addExecutable(.{
        .name = "api_vs_cli_bench",
        .root_source_file = b.path("benchmarks/api_vs_cli_bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    api_vs_cli_benchmark.root_module.addImport("ziggit", ziggit_module);
    const run_api_vs_cli_benchmark = b.addRunArtifact(api_vs_cli_benchmark);
    
    const perf_step = b.step("perf", "Run performance benchmark");
    perf_step.dependOn(&run_api_vs_cli_benchmark.step);
    
    // Status micro-benchmark to analyze bottlenecks
    const status_micro_benchmark = b.addExecutable(.{
        .name = "status_micro_bench",
        .root_source_file = b.path("benchmarks/status_micro_bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    status_micro_benchmark.root_module.addImport("ziggit", ziggit_module);
    const run_status_micro_benchmark = b.addRunArtifact(status_micro_benchmark);
    
    const micro_step = b.step("micro", "Run status micro-benchmark");
    micro_step.dependOn(&run_status_micro_benchmark.step);
    
    // Simple status analysis
    const simple_status_analysis = b.addExecutable(.{
        .name = "simple_status_analysis",
        .root_source_file = b.path("benchmarks/simple_status_analysis.zig"),
        .target = target,
        .optimize = optimize,
    });
    simple_status_analysis.root_module.addImport("ziggit", ziggit_module);
    const run_simple_status_analysis = b.addRunArtifact(simple_status_analysis);
    
    const analyze_step = b.step("analyze", "Run simple status analysis");
    analyze_step.dependOn(&run_simple_status_analysis.step);
    
    // Debug add operation
    const debug_add_operation = b.addExecutable(.{
        .name = "debug_add_operation",
        .root_source_file = b.path("benchmarks/debug_add_operation.zig"),
        .target = target,
        .optimize = optimize,
    });
    debug_add_operation.root_module.addImport("ziggit", ziggit_module);
    const run_debug_add_operation = b.addRunArtifact(debug_add_operation);
    
    const debug_step = b.step("debug-add", "Debug add operation");
    debug_step.dependOn(&run_debug_add_operation.step);
    
    // Debug benchmark setup
    const debug_benchmark_setup = b.addExecutable(.{
        .name = "debug_benchmark_setup",
        .root_source_file = b.path("benchmarks/debug_benchmark_setup.zig"),
        .target = target,
        .optimize = optimize,
    });
    debug_benchmark_setup.root_module.addImport("ziggit", ziggit_module);
    const run_debug_benchmark_setup = b.addRunArtifact(debug_benchmark_setup);
    
    const debug_bench_step = b.step("debug-bench", "Debug benchmark setup");
    debug_bench_step.dependOn(&run_debug_benchmark_setup.step);
    
    // Debug scale test
    const debug_scale_test = b.addExecutable(.{
        .name = "debug_scale_test",
        .root_source_file = b.path("benchmarks/debug_scale_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    debug_scale_test.root_module.addImport("ziggit", ziggit_module);
    const run_debug_scale_test = b.addRunArtifact(debug_scale_test);
    
    const debug_scale_step = b.step("debug-scale", "Debug scale test (100 files)");
    debug_scale_step.dependOn(&run_debug_scale_test.step);
    
    // Debug index corruption
    const debug_index_corruption = b.addExecutable(.{
        .name = "debug_index_corruption",
        .root_source_file = b.path("benchmarks/debug_index_corruption.zig"),
        .target = target,
        .optimize = optimize,
    });
    debug_index_corruption.root_module.addImport("ziggit", ziggit_module);
    const run_debug_index_corruption = b.addRunArtifact(debug_index_corruption);
    
    const debug_index_step = b.step("debug-index", "Debug index corruption");
    debug_index_step.dependOn(&run_debug_index_corruption.step);


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