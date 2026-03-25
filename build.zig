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

    // Drop-in compatibility test suite - tests that ziggit can replace git
    const drop_in_compat_test = b.addExecutable(.{
        .name = "drop_in_compat_test",
        .root_source_file = b.path("test/git_drop_in_compatibility.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_drop_in_compat_test = b.addRunArtifact(drop_in_compat_test);
    run_drop_in_compat_test.step.dependOn(b.getInstallStep()); // Ensure ziggit is built first

    // Bun compatibility test - proves ziggit works as drop-in replacement with bun
    const bun_compat_test = b.addExecutable(.{
        .name = "bun_compat_test",
        .root_source_file = b.path("test/bun_compatibility_test.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_bun_compat_test = b.addRunArtifact(bun_compat_test);
    run_bun_compat_test.step.dependOn(b.getInstallStep()); // Ensure ziggit is built first

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

    // Drop-in compatibility test step
    const drop_in_compat_test_step = b.step("test-drop-in", "Run drop-in git compatibility tests");
    drop_in_compat_test_step.dependOn(&run_drop_in_compat_test.step);

    const bun_compat_test_step = b.step("test-bun", "Run bun compatibility tests");
    bun_compat_test_step.dependOn(&run_bun_compat_test.step);

    // Git t0001-init adapter test - tests based on git's own t0001-init.sh
    const git_t0001_init_test = b.addExecutable(.{
        .name = "git_t0001_init_test",
        .root_source_file = b.path("test/git_t0001_init_adapter.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_git_t0001_init_test = b.addRunArtifact(git_t0001_init_test);
    run_git_t0001_init_test.step.dependOn(b.getInstallStep()); // Ensure ziggit is built first

    const git_t0001_init_test_step = b.step("test-git-t0001", "Run git t0001-init adapter tests");
    git_t0001_init_test_step.dependOn(&run_git_t0001_init_test.step);

    // Basic workflow test
    const basic_workflow_test = b.addExecutable(.{
        .name = "basic_workflow_test",
        .root_source_file = b.path("test/basic_workflow_test.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_basic_workflow_test = b.addRunArtifact(basic_workflow_test);
    run_basic_workflow_test.step.dependOn(b.getInstallStep()); // Ensure ziggit is built first

    const basic_workflow_test_step = b.step("test-basic-workflow", "Run basic workflow test");
    basic_workflow_test_step.dependOn(&run_basic_workflow_test.step);

    // Git compatibility suite test
    const git_compatibility_suite = b.addExecutable(.{
        .name = "git_compatibility_suite",
        .root_source_file = b.path("test/git_compatibility_suite.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_git_compatibility_suite = b.addRunArtifact(git_compatibility_suite);
    run_git_compatibility_suite.step.dependOn(b.getInstallStep()); // Ensure ziggit is built first

    const git_compatibility_suite_step = b.step("test-git-compatibility-suite", "Run comprehensive git compatibility suite");
    git_compatibility_suite_step.dependOn(&run_git_compatibility_suite.step);

    // Comprehensive compatibility test
    const comprehensive_compatibility_test = b.addExecutable(.{
        .name = "comprehensive_compatibility_test",
        .root_source_file = b.path("test/comprehensive_compatibility_test.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_comprehensive_compatibility_test = b.addRunArtifact(comprehensive_compatibility_test);
    run_comprehensive_compatibility_test.step.dependOn(b.getInstallStep());

    const comprehensive_compatibility_test_step = b.step("test-comprehensive-compatibility", "Run comprehensive compatibility test");
    comprehensive_compatibility_test_step.dependOn(&run_comprehensive_compatibility_test.step);

    // Git output format test
    const git_output_format_test = b.addExecutable(.{
        .name = "git_output_format_test",
        .root_source_file = b.path("test/git_output_format_test.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_git_output_format_test = b.addRunArtifact(git_output_format_test);
    run_git_output_format_test.step.dependOn(b.getInstallStep());

    const git_output_format_test_step = b.step("test-git-format", "Run git output format compatibility test");
    git_output_format_test_step.dependOn(&run_git_output_format_test.step);

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

    // Git source comprehensive compatibility test suite (based on git's own tests)
    const git_source_comprehensive_test = b.addExecutable(.{
        .name = "git_source_comprehensive_test",
        .root_source_file = b.path("test/git_source_comprehensive_compatibility.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_git_source_comprehensive_test = b.addRunArtifact(git_source_comprehensive_test);
    run_git_source_comprehensive_test.step.dependOn(b.getInstallStep()); // Ensure ziggit is built first

    const git_source_comprehensive_test_step = b.step("test-git-source-compat", "Run git source comprehensive compatibility tests");
    git_source_comprehensive_test_step.dependOn(&run_git_source_comprehensive_test.step);

    // Git source test suite - Direct adaptations from git's own test files
    const git_source_test_suite = b.addExecutable(.{
        .name = "git_source_test_suite",
        .root_source_file = b.path("test/git_source_test_suite.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_git_source_test_suite = b.addRunArtifact(git_source_test_suite);
    run_git_source_test_suite.step.dependOn(b.getInstallStep()); // Ensure ziggit is built first

    const git_source_test_suite_step = b.step("test-git-source-suite", "Run git source test suite adapted from git's own tests");
    git_source_test_suite_step.dependOn(&run_git_source_test_suite.step);

    // Advanced git test suite - Testing edge cases and advanced scenarios
    const git_advanced_test_suite = b.addExecutable(.{
        .name = "git_advanced_test_suite",
        .root_source_file = b.path("test/git_advanced_test_suite.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_git_advanced_test_suite = b.addRunArtifact(git_advanced_test_suite);
    run_git_advanced_test_suite.step.dependOn(b.getInstallStep()); // Ensure ziggit is built first

    const git_advanced_test_suite_step = b.step("test-git-advanced-suite", "Run advanced git test suite for edge cases");
    git_advanced_test_suite_step.dependOn(&run_git_advanced_test_suite.step);

    // Critical git compatibility test suite (focused on core functionality)
    const critical_compatibility_tests = b.addExecutable(.{
        .name = "critical_compatibility_tests",
        .root_source_file = b.path("test/critical_compatibility_main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_critical_compatibility_tests = b.addRunArtifact(critical_compatibility_tests);
    run_critical_compatibility_tests.step.dependOn(b.getInstallStep()); // Ensure ziggit is built first

    const critical_compatibility_test_step = b.step("test-critical", "Run critical git compatibility tests");
    critical_compatibility_test_step.dependOn(&run_critical_compatibility_tests.step);

    // Edge case git compatibility test suite
    const edge_case_tests = b.addExecutable(.{
        .name = "edge_case_tests",
        .root_source_file = b.path("test/edge_case_main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_edge_case_tests = b.addRunArtifact(edge_case_tests);
    run_edge_case_tests.step.dependOn(b.getInstallStep()); // Ensure ziggit is built first

    const edge_case_test_step = b.step("test-edge-cases", "Run git edge case compatibility tests");
    edge_case_test_step.dependOn(&run_edge_case_tests.step);

    // Comprehensive git compatibility test suite (new git-source-based tests)
    const comprehensive_git_tests = b.addExecutable(.{
        .name = "comprehensive_git_tests",
        .root_source_file = b.path("test/comprehensive_test_runner.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_comprehensive_git_tests = b.addRunArtifact(comprehensive_git_tests);
    run_comprehensive_git_tests.step.dependOn(b.getInstallStep()); // Ensure ziggit is built first

    const comprehensive_git_test_step = b.step("test-comprehensive", "Run comprehensive git compatibility test suite");
    comprehensive_git_test_step.dependOn(&run_comprehensive_git_tests.step);

    // Core git compatibility test suite (essential functionality tests)
    const core_git_compat_test = b.addExecutable(.{
        .name = "core_git_compat_test",
        .root_source_file = b.path("test/git_compatibility_test_suite_simple.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_core_git_compat_test = b.addRunArtifact(core_git_compat_test);
    run_core_git_compat_test.step.dependOn(b.getInstallStep()); // Ensure ziggit is built first

    const core_git_compat_test_step = b.step("test-core-compat", "Run core git compatibility tests for essential functionality");
    core_git_compat_test_step.dependOn(&run_core_git_compat_test.step);

    // Main test step runs core compatibility tests
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_compatibility_tests.step);
    test_step.dependOn(&run_git_compat_tests.step);
    test_step.dependOn(&run_drop_in_compat_test.step);
    test_step.dependOn(&run_git_t0001_init_test.step);
    test_step.dependOn(&run_git_source_comprehensive_test.step);
    test_step.dependOn(&run_git_source_test_suite.step);
    test_step.dependOn(&run_git_advanced_test_suite.step);
    test_step.dependOn(&run_comprehensive_git_tests.step);
    test_step.dependOn(&run_core_git_compat_test.step);

    // Git source compatibility test suite (newly improved)
    const git_source_compatibility = b.addExecutable(.{
        .name = "git_source_compatibility",
        .root_source_file = b.path("test/git_source_compatibility.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_git_source_compatibility = b.addRunArtifact(git_source_compatibility);
    run_git_source_compatibility.step.dependOn(b.getInstallStep()); // Ensure ziggit is built first

    const git_source_compatibility_step = b.step("test-git-source", "Run improved git source compatibility tests");
    git_source_compatibility_step.dependOn(&run_git_source_compatibility.step);

    // Advanced git compatibility test suite
    const git_advanced_compatibility = b.addExecutable(.{
        .name = "git_advanced_compatibility",
        .root_source_file = b.path("test/git_advanced_compatibility.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_git_advanced_compatibility = b.addRunArtifact(git_advanced_compatibility);
    run_git_advanced_compatibility.step.dependOn(b.getInstallStep()); // Ensure ziggit is built first

    const git_advanced_compatibility_step = b.step("test-git-advanced", "Run advanced git compatibility tests");
    git_advanced_compatibility_step.dependOn(&run_git_advanced_compatibility.step);

    // Git output comparison test suite
    const git_output_comparison = b.addExecutable(.{
        .name = "git_output_comparison",
        .root_source_file = b.path("test/git_output_comparison.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_git_output_comparison = b.addRunArtifact(git_output_comparison);
    run_git_output_comparison.step.dependOn(b.getInstallStep()); // Ensure ziggit is built first

    const git_output_comparison_step = b.step("test-output-comparison", "Run git output format comparison tests");
    git_output_comparison_step.dependOn(&run_git_output_comparison.step);

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
    
    // Set max memory to prevent excessive growth
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
    
    // Export functions for browser environment
    wasm_freestanding_exe.rdynamic = true;
    
    // Additional WASM optimizations for smaller binary size
    wasm_freestanding_exe.stack_size = 16 * 1024; // 16KB stack (smaller than default)
    
    // Set reasonable memory limits for browser environment
    wasm_freestanding_exe.initial_memory = 1024 * 1024; // 1MB initial memory
    wasm_freestanding_exe.max_memory = 4 * 1024 * 1024; // 4MB max memory
    
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

    // Ziggit vs Git CLI vs libgit2 benchmark for bun integration analysis
    const ziggit_bun_integration_exe = b.addExecutable(.{
        .name = "ziggit-bun-integration-bench",
        .root_source_file = b.path("benchmarks/ziggit_bun_integration.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    // Link the static library for C integration testing
    ziggit_bun_integration_exe.linkLibrary(lib_static);
    ziggit_bun_integration_exe.linkLibC();
    ziggit_bun_integration_exe.addIncludePath(b.path("src/lib"));
    
    // Link libgit2
    ziggit_bun_integration_exe.linkSystemLibrary("git2");
    
    // Add ziggit module
    ziggit_bun_integration_exe.root_module.addImport("ziggit", ziggit_module);

    const run_ziggit_bun_integration = b.addRunArtifact(ziggit_bun_integration_exe);

    const bench_bun_integration_step = b.step("bench-bun-integration", "Run comprehensive bun integration benchmarks (ziggit vs git CLI vs libgit2)");
    bench_bun_integration_step.dependOn(&run_ziggit_bun_integration.step);

    // Install the benchmark executable
    const install_ziggit_bun_integration = b.addInstallArtifact(ziggit_bun_integration_exe, .{});
    bench_bun_integration_step.dependOn(&install_ziggit_bun_integration.step);

    // Bun operations benchmark (pure Zig, no C dependencies)
    const bun_operations_bench_exe = b.addExecutable(.{
        .name = "bun-operations-bench",
        .root_source_file = b.path("benchmarks/bun_operations_bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    bun_operations_bench_exe.root_module.addImport("ziggit", ziggit_module);

    const run_bun_operations_bench = b.addRunArtifact(bun_operations_bench_exe);

    const bench_bun_operations_step = b.step("bench-bun-ops", "Run Bun operations benchmark (ziggit vs git CLI for critical operations)");
    bench_bun_operations_step.dependOn(&run_bun_operations_bench.step);

    // Install the benchmark executable
    const install_bun_operations_bench = b.addInstallArtifact(bun_operations_bench_exe, .{});
    bench_bun_operations_step.dependOn(&install_bun_operations_bench.step);

    // Simple bun integration benchmark (ziggit vs git CLI only, no libgit2)
    const simple_bun_bench_exe = b.addExecutable(.{
        .name = "simple-bun-bench",
        .root_source_file = b.path("benchmarks/simple_bun_bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    // Link the static library for C integration testing
    simple_bun_bench_exe.linkLibrary(lib_static);
    simple_bun_bench_exe.linkLibC();
    simple_bun_bench_exe.addIncludePath(b.path("src/lib"));

    const run_simple_bun_bench = b.addRunArtifact(simple_bun_bench_exe);

    const bench_simple_bun_step = b.step("bench-simple-bun", "Run simple bun integration benchmark (ziggit vs git CLI)");
    bench_simple_bun_step.dependOn(&run_simple_bun_bench.step);

    // Install the benchmark executable
    const install_simple_bun_bench = b.addInstallArtifact(simple_bun_bench_exe, .{});
    bench_simple_bun_step.dependOn(&install_simple_bun_bench.step);

    // Minimal benchmark (no C library dependencies)
    const minimal_bench_exe = b.addExecutable(.{
        .name = "minimal-bench",
        .root_source_file = b.path("benchmarks/minimal_bench.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_minimal_bench = b.addRunArtifact(minimal_bench_exe);
    run_minimal_bench.step.dependOn(&b.addInstallArtifact(minimal_bench_exe, .{}).step);

    const bench_minimal_step = b.step("bench-minimal", "Run minimal benchmark (ziggit binary vs git CLI)");
    bench_minimal_step.dependOn(&run_minimal_bench.step);

    // Comprehensive bun benchmark (ziggit vs git CLI vs libgit2)
    const comprehensive_bun_bench_exe = b.addExecutable(.{
        .name = "comprehensive-bun-bench",
        .root_source_file = b.path("benchmarks/comprehensive_bun_bench.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Link the static library and libgit2
    comprehensive_bun_bench_exe.linkLibrary(lib_static);
    comprehensive_bun_bench_exe.linkLibC();
    comprehensive_bun_bench_exe.addIncludePath(b.path("src/lib"));
    comprehensive_bun_bench_exe.linkSystemLibrary("git2");

    const run_comprehensive_bun_bench = b.addRunArtifact(comprehensive_bun_bench_exe);

    const bench_comprehensive_bun_step = b.step("bench-comprehensive-bun", "Run comprehensive bun integration benchmark (ziggit vs git CLI vs libgit2)");
    bench_comprehensive_bun_step.dependOn(&run_comprehensive_bun_bench.step);

    // Install the comprehensive benchmark executable
    const install_comprehensive_bun_bench = b.addInstallArtifact(comprehensive_bun_bench_exe, .{});
    bench_comprehensive_bun_step.dependOn(&install_comprehensive_bun_bench.step);

    // Simple comparison benchmark (ziggit CLI vs git CLI only)
    const simple_comparison_bench_exe = b.addExecutable(.{
        .name = "simple-comparison-bench",
        .root_source_file = b.path("benchmarks/simple_comparison_bench.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_simple_comparison_bench = b.addRunArtifact(simple_comparison_bench_exe);

    const bench_simple_comparison_step = b.step("bench-simple-comparison", "Run simple comparison benchmark (ziggit CLI vs git CLI)");
    bench_simple_comparison_step.dependOn(&run_simple_comparison_bench.step);

    // Install the simple comparison benchmark executable
    const install_simple_comparison_bench = b.addInstallArtifact(simple_comparison_bench_exe, .{});
    bench_simple_comparison_step.dependOn(&install_simple_comparison_bench.step);

    // Real git benchmark (ziggit library vs git CLI with real git repos)
    const real_git_bench_exe = b.addExecutable(.{
        .name = "real-git-bench",
        .root_source_file = b.path("benchmarks/real_git_bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    // Link the static library for C integration testing
    real_git_bench_exe.linkLibrary(lib_static);
    real_git_bench_exe.linkLibC();
    real_git_bench_exe.addIncludePath(b.path("src/lib"));

    const run_real_git_bench = b.addRunArtifact(real_git_bench_exe);

    const bench_real_git_step = b.step("bench-real", "Run real git repository benchmark (ziggit library vs git CLI)");
    bench_real_git_step.dependOn(&run_real_git_bench.step);

    // Install the real git benchmark executable
    const install_real_git_bench = b.addInstallArtifact(real_git_bench_exe, .{});
    bench_real_git_step.dependOn(&install_real_git_bench.step);

    // Pure Zig benchmark (no C dependencies)
    const pure_zig_bench_exe = b.addExecutable(.{
        .name = "pure-zig-bench",
        .root_source_file = b.path("benchmarks/pure_zig_bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    
    pure_zig_bench_exe.root_module.addImport("ziggit", ziggit_module);

    const run_pure_zig_bench = b.addRunArtifact(pure_zig_bench_exe);

    const bench_pure_zig_step = b.step("bench-pure", "Run pure Zig benchmark (ziggit Zig API vs git CLI)");
    bench_pure_zig_step.dependOn(&run_pure_zig_bench.step);

    // Install the pure zig benchmark executable
    const install_pure_zig_bench = b.addInstallArtifact(pure_zig_bench_exe, .{});
    bench_pure_zig_step.dependOn(&install_pure_zig_bench.step);
}
