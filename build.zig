const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ========== MAIN CLI EXECUTABLE ==========
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

    // ========== LIBRARY BUILD ==========
    const lib_static = b.addStaticLibrary(.{
        .name = "ziggit",
        .root_source_file = b.path("src/lib/ziggit.zig"),
        .target = target,
        .optimize = optimize,
    });

    const install_lib_static = b.addInstallArtifact(lib_static, .{});
    const install_header = b.addInstallFile(b.path("src/lib/ziggit.h"), "include/ziggit.h");

    const lib_step = b.step("lib", "Build libziggit.a + ziggit.h");
    lib_step.dependOn(&install_lib_static.step);
    lib_step.dependOn(&install_header.step);

    // ========== TESTS ==========
    // Unit tests for main module
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    // Platform-specific unit tests  
    const platform_tests = b.addTest(.{
        .root_source_file = b.path("src/platform/platform.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_platform_tests = b.addRunArtifact(platform_tests);

    // Git interoperability test
    const git_interop_test = b.addExecutable(.{
        .name = "git_interop_test",
        .root_source_file = b.path("test/git_interop_test.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_git_interop_test = b.addRunArtifact(git_interop_test);
    run_git_interop_test.step.dependOn(b.getInstallStep());

    // Index format compatibility test
    const index_format_test = b.addExecutable(.{
        .name = "index_format_test",
        .root_source_file = b.path("test/index_format_test.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_index_format_test = b.addRunArtifact(index_format_test);
    run_index_format_test.step.dependOn(b.getInstallStep());

    // Object format compatibility test
    const object_format_test = b.addExecutable(.{
        .name = "object_format_test",
        .root_source_file = b.path("test/object_format_test.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_object_format_test = b.addRunArtifact(object_format_test);
    run_object_format_test.step.dependOn(b.getInstallStep());

    // Command output compatibility test
    const command_output_test = b.addExecutable(.{
        .name = "command_output_test",
        .root_source_file = b.path("test/command_output_test.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_command_output_test = b.addRunArtifact(command_output_test);
    run_command_output_test.step.dependOn(b.getInstallStep());

    // Pack delta unit tests
    const pack_delta_unit_tests = b.addTest(.{
        .root_source_file = b.path("test/pack_delta_test.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_pack_delta_unit_tests = b.addRunArtifact(pack_delta_unit_tests);

    // Pack files test
    const pack_files_test = b.addExecutable(.{
        .name = "pack_files_test",
        .root_source_file = b.path("test/pack_files_test.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_pack_files_test = b.addRunArtifact(pack_files_test);

    // Library status test
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
    
    const lib_status_test_step = b.step("lib-status-test", "Run library status test");
    lib_status_test_step.dependOn(&run_lib_status_test.step);

    // Pack implementation test
    const pack_implementation_test = b.addExecutable(.{
        .name = "pack_implementation_test",
        .root_source_file = b.path("test/pack_implementation_test.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_pack_implementation_test = b.addRunArtifact(pack_implementation_test);

    // Comprehensive pack test
    const comprehensive_pack_test = b.addExecutable(.{
        .name = "comprehensive_pack_test",
        .root_source_file = b.path("test/comprehensive_pack_test.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_comprehensive_pack_test = b.addRunArtifact(comprehensive_pack_test);

    // Comprehensive refs test
    const comprehensive_refs_test = b.addExecutable(.{
        .name = "comprehensive_refs_test",
        .root_source_file = b.path("test/comprehensive_refs_test.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_comprehensive_refs_test = b.addRunArtifact(comprehensive_refs_test);

    // Main test step runs core tests
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_platform_tests.step);
    test_step.dependOn(&run_git_interop_test.step);
    test_step.dependOn(&run_index_format_test.step);
    test_step.dependOn(&run_object_format_test.step);
    test_step.dependOn(&run_command_output_test.step);
    test_step.dependOn(&run_pack_delta_unit_tests.step);
    test_step.dependOn(&run_pack_files_test.step);
    test_step.dependOn(&run_pack_implementation_test.step);
    test_step.dependOn(&run_comprehensive_pack_test.step);
    test_step.dependOn(&run_comprehensive_refs_test.step);
    test_step.dependOn(&run_lib_status_test.step);

    // Quick test step (just unit tests)
    const quick_test_step = b.step("test-quick", "Run unit tests only");
    quick_test_step.dependOn(&run_unit_tests.step);
    quick_test_step.dependOn(&run_platform_tests.step);

    // Integration test step 
    const integration_test_step = b.step("test-integration", "Run integration tests only");
    integration_test_step.dependOn(&run_git_interop_test.step);
    integration_test_step.dependOn(&run_index_format_test.step);
    integration_test_step.dependOn(&run_object_format_test.step);
    integration_test_step.dependOn(&run_command_output_test.step);

    // ========== BENCHMARKS ==========
    // CLI benchmark (ziggit CLI vs git CLI)
    const cli_benchmark_exe = b.addExecutable(.{
        .name = "cli-benchmark",
        .root_source_file = b.path("benchmarks/cli_benchmark.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_cli_benchmark = b.addRunArtifact(cli_benchmark_exe);

    // Library benchmark
    const lib_benchmark_exe = b.addExecutable(.{
        .name = "lib-benchmark", 
        .root_source_file = b.path("benchmarks/lib_benchmark.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_lib_benchmark = b.addRunArtifact(lib_benchmark_exe);

    // Bun scenario benchmark
    const bun_benchmark_exe = b.addExecutable(.{
        .name = "bun-benchmark",
        .root_source_file = b.path("benchmarks/bun_scenario_bench.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_bun_benchmark = b.addRunArtifact(bun_benchmark_exe);

    // Simple API vs CLI benchmark (demonstrates concept)
    const simple_api_vs_cli_benchmark_exe = b.addExecutable(.{
        .name = "simple-api-vs-cli-benchmark",
        .root_source_file = b.path("benchmarks/simple_api_vs_cli.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_simple_api_vs_cli_benchmark = b.addRunArtifact(simple_api_vs_cli_benchmark_exe);

    const bench_step = b.step("bench", "Run all benchmarks");
    bench_step.dependOn(&run_cli_benchmark.step);
    bench_step.dependOn(&run_lib_benchmark.step);
    bench_step.dependOn(&run_bun_benchmark.step);
    bench_step.dependOn(&run_simple_api_vs_cli_benchmark.step);

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
    
    wasm_exe.stack_size = 256 * 1024; // 256KB stack
    wasm_exe.initial_memory = 16 * 1024 * 1024; // 16MB initial memory
    wasm_exe.max_memory = 32 * 1024 * 1024; // 32MB max memory

    const wasm_step = b.step("wasm", "Build for WebAssembly");
    wasm_step.dependOn(&b.addInstallArtifact(wasm_exe, .{}).step);

    // ========== CLEAN TARGET ==========
    _ = b.step("clean", "Clean build artifacts");
    // Note: Zig handles cache cleaning internally, this is just for documentation
    
    // ========== HELP TARGET ==========
    const help_step = b.step("help", "Show available build targets");
    const help_cmd = b.addSystemCommand(&.{
        "/bin/sh", "-c",
        \\echo "Available build targets:"
        \\echo "  zig build          - Build ziggit CLI (default)"
        \\echo "  zig build lib      - Build libziggit.a + ziggit.h"
        \\echo "  zig build test     - Run all tests"
        \\echo "  zig build test-quick - Run unit tests only"
        \\echo "  zig build test-integration - Run integration tests only"
        \\echo "  zig build bench    - Run all benchmarks"
        \\echo "  zig build wasm     - Build for WebAssembly"
        \\echo "  zig build run      - Build and run ziggit"
        \\echo "  zig build clean    - Clean build artifacts"
        \\echo "  zig build help     - Show this help"
    });
    help_step.dependOn(&help_cmd.step);
}