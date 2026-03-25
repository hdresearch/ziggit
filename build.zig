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

    // Compatibility test suite
    const compatibility_tests = b.addExecutable(.{
        .name = "compatibility_tests",
        .root_source_file = b.path("test/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_compatibility_tests = b.addRunArtifact(compatibility_tests);
    run_compatibility_tests.step.dependOn(b.getInstallStep()); // Ensure ziggit is built first

    // Git source compatibility test suite (focused on drop-in compatibility)
    const git_compat_tests = b.addExecutable(.{
        .name = "git_compat_tests",
        .root_source_file = b.path("test/git_compat_main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_git_compat_tests = b.addRunArtifact(git_compat_tests);
    run_git_compat_tests.step.dependOn(b.getInstallStep()); // Ensure ziggit is built first

    // Simple git compatibility test
    const simple_git_compat_test = b.addExecutable(.{
        .name = "simple_git_compat_test",
        .root_source_file = b.path("test/simple_git_compat_test.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_simple_git_compat_test = b.addRunArtifact(simple_git_compat_test);
    run_simple_git_compat_test.step.dependOn(b.getInstallStep());

    // Comprehensive git workflow test
    const comprehensive_git_workflow_test = b.addExecutable(.{
        .name = "comprehensive_git_workflow_test",
        .root_source_file = b.path("test/comprehensive_git_workflow_test.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_comprehensive_git_workflow_test = b.addRunArtifact(comprehensive_git_workflow_test);
    run_comprehensive_git_workflow_test.step.dependOn(b.getInstallStep());

    // Test step runs both unit tests and compatibility tests
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_compatibility_tests.step);
    test_step.dependOn(&run_git_compat_tests.step);

    // Separate step for just compatibility tests
    const compat_test_step = b.step("test-compat", "Run compatibility tests");
    compat_test_step.dependOn(&run_compatibility_tests.step);

    // Separate step for git source compatibility tests
    const git_compat_test_step = b.step("test-git-compat", "Run git source compatibility tests");
    git_compat_test_step.dependOn(&run_git_compat_tests.step);

    // Simple git compatibility test step
    const simple_git_compat_test_step = b.step("test-simple-git", "Run simple git compatibility test");
    simple_git_compat_test_step.dependOn(&run_simple_git_compat_test.step);

    // Comprehensive git workflow test step
    const comprehensive_git_workflow_test_step = b.step("test-comprehensive-git", "Run comprehensive git workflow test");
    comprehensive_git_workflow_test_step.dependOn(&run_comprehensive_git_workflow_test.step);

    // Focused commit test
    const focused_commit_test = b.addExecutable(.{
        .name = "focused_commit_test",
        .root_source_file = b.path("test/focused_commit_test.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_focused_commit_test = b.addRunArtifact(focused_commit_test);
    run_focused_commit_test.step.dependOn(b.getInstallStep());

    const focused_commit_test_step = b.step("test-focused-commit", "Run focused commit test");
    focused_commit_test_step.dependOn(&run_focused_commit_test.step);

    // Comprehensive git compatibility test suite (new)
    const git_compatibility_tests = b.addExecutable(.{
        .name = "git_compatibility_tests",
        .root_source_file = b.path("test/git_compatibility_main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_git_compatibility_tests = b.addRunArtifact(git_compatibility_tests);
    run_git_compatibility_tests.step.dependOn(b.getInstallStep()); // Ensure ziggit is built first

    const git_compatibility_test_step = b.step("test-git-compatibility", "Run comprehensive git compatibility tests");
    git_compatibility_test_step.dependOn(&run_git_compatibility_tests.step);

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
    
    // Give enough stack and memory for complex git operations including compression
    wasm_exe.stack_size = 256 * 1024; // 256KB stack (increased for zlib and complex git operations)
    
    // Set initial memory size to give more room for operations
    wasm_exe.initial_memory = 16 * 1024 * 1024; // 16MB initial memory

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
    
    // Export functions for browser environment
    wasm_freestanding_exe.rdynamic = true;
    
    // Additional WASM optimizations for smaller binary size
    wasm_freestanding_exe.stack_size = 16 * 1024; // 16KB stack (smaller than default)
    
    // Add compile-time option for configurable memory size
    const freestanding_memory_size = b.option(u32, "freestanding-memory-size", "Memory size for freestanding WASM build (default: 64KB)") orelse (64 * 1024);
    const options = b.addOptions();
    options.addOption(u32, "freestanding_memory_size", freestanding_memory_size);
    wasm_freestanding_exe.root_module.addOptions("config", options);

    const wasm_browser_step = b.step("wasm-browser", "Build for WebAssembly (freestanding/browser)");
    wasm_browser_step.dependOn(&b.addInstallArtifact(wasm_freestanding_exe, .{}).step);

    // Benchmark executable (original Zig-only benchmarks)
    const benchmark_exe = b.addExecutable(.{
        .name = "ziggit-bench",
        .root_source_file = b.path("benchmarks/bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    const ziggit_module = b.addModule("ziggit", .{
        .root_source_file = b.path("src/lib/ziggit.zig"),
    });
    benchmark_exe.root_module.addImport("ziggit", ziggit_module);

    const run_benchmark = b.addRunArtifact(benchmark_exe);

    const bench_step = b.step("bench", "Run Zig-only benchmarks");
    bench_step.dependOn(&run_benchmark.step);

    // Also install the benchmark executable
    const install_benchmark = b.addInstallArtifact(benchmark_exe, .{});
    bench_step.dependOn(&install_benchmark.step);

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

    // Install libraries
    const install_lib_static = b.addInstallArtifact(lib_static, .{});
    const install_lib_shared = b.addInstallArtifact(lib_shared, .{});

    // Library build steps
    const lib_step = b.step("lib", "Build both static and shared libraries");
    lib_step.dependOn(&install_lib_static.step);
    lib_step.dependOn(&install_lib_shared.step);

    const lib_static_step = b.step("lib-static", "Build static library");
    lib_static_step.dependOn(&install_lib_static.step);

    const lib_shared_step = b.step("lib-shared", "Build shared library");
    lib_shared_step.dependOn(&install_lib_shared.step);
    
    // Also add header installation
    const install_header = b.addInstallFile(b.path("src/lib/ziggit.h"), "include/ziggit.h");
    lib_step.dependOn(&install_header.step);
    lib_static_step.dependOn(&install_header.step);
    lib_shared_step.dependOn(&install_header.step);

    // Comparison benchmark executable (ziggit vs git CLI) - needs to be after lib declarations
    const comparison_benchmark_exe = b.addExecutable(.{
        .name = "ziggit-comparison-bench",
        .root_source_file = b.path("benchmarks/comparison_bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    // Link the static library for C integration testing (avoids TLS issues)
    comparison_benchmark_exe.linkLibrary(lib_static);
    comparison_benchmark_exe.linkLibC();
    comparison_benchmark_exe.addIncludePath(b.path("src/lib"));

    const run_comparison_benchmark = b.addRunArtifact(comparison_benchmark_exe);

    const bench_comparison_step = b.step("bench-comparison", "Run comparison benchmarks (ziggit vs git CLI)");
    bench_comparison_step.dependOn(&run_comparison_benchmark.step);

    // Install the comparison benchmark executable
    const install_comparison_benchmark = b.addInstallArtifact(comparison_benchmark_exe, .{});
    bench_comparison_step.dependOn(&install_comparison_benchmark.step);

    // Simple CLI comparison benchmark (avoids C linking issues)
    const simple_comparison_exe = b.addExecutable(.{
        .name = "ziggit-simple-bench",
        .root_source_file = b.path("benchmarks/simple_comparison.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_simple_comparison = b.addRunArtifact(simple_comparison_exe);

    const bench_simple_step = b.step("bench-simple", "Run simple CLI comparison benchmarks");
    bench_simple_step.dependOn(&run_simple_comparison.step);

    // Install the simple benchmark executable  
    const install_simple_comparison = b.addInstallArtifact(simple_comparison_exe, .{});
    bench_simple_step.dependOn(&install_simple_comparison.step);

    // Full comparison benchmark (ziggit vs git CLI vs libgit2)
    const full_comparison_exe = b.addExecutable(.{
        .name = "ziggit-full-bench",
        .root_source_file = b.path("benchmarks/full_comparison_bench.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Link the static library for C integration testing
    full_comparison_exe.linkLibrary(lib_static);
    full_comparison_exe.linkLibC();
    full_comparison_exe.addIncludePath(b.path("src/lib"));
    
    // Link libgit2
    full_comparison_exe.linkSystemLibrary("git2");

    const run_full_comparison = b.addRunArtifact(full_comparison_exe);

    const bench_full_step = b.step("bench-full", "Run full comparison benchmarks (ziggit vs git CLI vs libgit2)");
    bench_full_step.dependOn(&run_full_comparison.step);

    // Install the full benchmark executable
    const install_full_comparison = b.addInstallArtifact(full_comparison_exe, .{});
    bench_full_step.dependOn(&install_full_comparison.step);

    // Bun integration benchmark (ziggit library vs git CLI) - optimized for bun's use cases
    const bun_integration_exe = b.addExecutable(.{
        .name = "ziggit-bun-bench",
        .root_source_file = b.path("benchmarks/bun_integration_bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    bun_integration_exe.root_module.addImport("ziggit", ziggit_module);

    const run_bun_integration = b.addRunArtifact(bun_integration_exe);

    const bench_bun_step = b.step("bench-bun", "Run Bun integration benchmarks (ziggit vs git CLI for bun use cases)");
    bench_bun_step.dependOn(&run_bun_integration.step);

    // Install the bun integration benchmark executable
    const install_bun_integration = b.addInstallArtifact(bun_integration_exe, .{});
    bench_bun_step.dependOn(&install_bun_integration.step);
}
