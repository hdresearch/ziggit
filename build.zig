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

    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&run_cli_benchmark.step);
    bench_step.dependOn(&run_lib_benchmark.step);
    bench_step.dependOn(&run_bun_scenario_benchmark.step);
    
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