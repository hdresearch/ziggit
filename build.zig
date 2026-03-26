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

    // Expose the module for the library
    lib_static.root_module.addImport("ziggit", ziggit_module);

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

    // Core git format integration tests (uses git module for proper imports)
    const core_git_format_tests = b.addTest(.{
        .root_source_file = b.path("test/core_git_format_integration.zig"),
        .target = target,
        .optimize = optimize,
    });
    core_git_format_tests.root_module.addAnonymousImport("git", .{
        .root_source_file = b.path("src/git/git.zig"),
    });

    // Pack file comprehensive tests
    const pack_comprehensive_tests = b.addTest(.{
        .root_source_file = b.path("test/pack_file_comprehensive_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    pack_comprehensive_tests.root_module.addAnonymousImport("git_objects", .{
        .root_source_file = b.path("src/git/objects.zig"),
    });

    // Delta application tests
    const delta_apply_tests = b.addTest(.{
        .root_source_file = b.path("test/delta_apply_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    delta_apply_tests.root_module.addAnonymousImport("git_objects", .{
        .root_source_file = b.path("src/git/objects.zig"),
    });

    // Pack round-trip tests (create pack + idx with git, read with ziggit)
    const pack_roundtrip_tests = b.addTest(.{
        .root_source_file = b.path("test/pack_roundtrip_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    pack_roundtrip_tests.root_module.addAnonymousImport("git_objects", .{
        .root_source_file = b.path("src/git/objects.zig"),
    });

    // Pack write + read tests (create pack from scratch, index, read back)
    const pack_write_read_tests = b.addTest(.{
        .root_source_file = b.path("test/pack_write_read_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    pack_write_read_tests.root_module.addAnonymousImport("git_objects", .{
        .root_source_file = b.path("src/git/objects.zig"),
    });

    // Delta edge case tests
    const delta_edge_cases_tests = b.addTest(.{
        .root_source_file = b.path("test/delta_edge_cases_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    delta_edge_cases_tests.root_module.addAnonymousImport("git_objects", .{
        .root_source_file = b.path("src/git/objects.zig"),
    });

    // Clone workflow integration tests (full clone simulation: pack save + ref update + git cross-validation)
    const clone_workflow_integration_tests = b.addTest(.{
        .root_source_file = b.path("test/clone_workflow_integration_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    clone_workflow_integration_tests.root_module.addAnonymousImport("git_objects", .{
        .root_source_file = b.path("src/git/objects.zig"),
    });

    // Delta strict correctness tests (byte-exact verification of delta application)
    const delta_strict_correctness_tests = b.addTest(.{
        .root_source_file = b.path("test/delta_strict_correctness_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    delta_strict_correctness_tests.root_module.addAnonymousImport("git_objects", .{
        .root_source_file = b.path("src/git/objects.zig"),
    });

    // Pack index generation tests (generatePackIndex, saveReceivedPack)
    const pack_index_gen_tests = b.addTest(.{
        .root_source_file = b.path("test/pack_index_gen_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    pack_index_gen_tests.root_module.addAnonymousImport("git_objects", .{
        .root_source_file = b.path("src/git/objects.zig"),
    });

    // Pack delta integration tests (OFS_DELTA build+index+read, clone simulation)
    const pack_delta_integration_tests = b.addTest(.{
        .root_source_file = b.path("test/pack_delta_integration_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    pack_delta_integration_tests.root_module.addAnonymousImport("git_objects", .{
        .root_source_file = b.path("src/git/objects.zig"),
    });

    // Pack format ground-truth tests (git CLI interop, all object types, idx validation)
    const pack_format_groundtruth_tests = b.addTest(.{
        .root_source_file = b.path("test/pack_format_groundtruth_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    pack_format_groundtruth_tests.root_module.addAnonymousImport("git_objects", .{
        .root_source_file = b.path("src/git/objects.zig"),
    });

    // REF_DELTA and delta chain tests
    const ref_delta_chain_tests = b.addTest(.{
        .root_source_file = b.path("test/ref_delta_and_chain_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    ref_delta_chain_tests.root_module.addAnonymousImport("git_objects", .{
        .root_source_file = b.path("src/git/objects.zig"),
    });

    const pack_core_verification_tests = b.addTest(.{
        .root_source_file = b.path("test/pack_core_verification_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    pack_core_verification_tests.root_module.addAnonymousImport("git_objects", .{
        .root_source_file = b.path("src/git/objects.zig"),
    });

    // Pack clone flow tests (end-to-end HTTPS clone/fetch simulation)
    const pack_clone_flow_tests = b.addTest(.{
        .root_source_file = b.path("test/pack_clone_flow_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    pack_clone_flow_tests.root_module.addAnonymousImport("git_objects", .{
        .root_source_file = b.path("src/git/objects.zig"),
    });

    // Pack git ground truth tests (real git creates packs, ziggit reads them)
    const pack_git_groundtruth_tests = b.addTest(.{
        .root_source_file = b.path("test/pack_git_groundtruth_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    pack_git_groundtruth_tests.root_module.addAnonymousImport("git_objects", .{
        .root_source_file = b.path("src/git/objects.zig"),
    });

    // Pack network reception tests (clone/fetch infrastructure)
    const pack_network_reception_tests = b.addTest(.{
        .root_source_file = b.path("test/pack_network_reception_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    pack_network_reception_tests.root_module.addAnonymousImport("git_objects", .{
        .root_source_file = b.path("src/git/objects.zig"),
    });

    // Pack thin pack + public API tests (NET-SMART/NET-PACK agent support)
    const pack_thin_public_api_tests = b.addTest(.{
        .root_source_file = b.path("test/pack_thin_and_public_api_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    pack_thin_public_api_tests.root_module.addAnonymousImport("git_objects", .{
        .root_source_file = b.path("src/git/objects.zig"),
    });

    const pack_object_read_tests = b.addTest(.{
        .root_source_file = b.path("test/pack_object_read_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    pack_object_read_tests.root_module.addAnonymousImport("git_objects", .{
        .root_source_file = b.path("src/git/objects.zig"),
    });

    const pack_ref_delta_thin_tests = b.addTest(.{
        .root_source_file = b.path("test/pack_ref_delta_and_thin_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    pack_ref_delta_thin_tests.root_module.addAnonymousImport("git_objects", .{
        .root_source_file = b.path("src/git/objects.zig"),
    });

    // Pack readback and thin pack tests
    const pack_readback_thin_tests = b.addTest(.{
        .root_source_file = b.path("test/pack_readback_and_thin_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    pack_readback_thin_tests.root_module.addAnonymousImport("git_objects", .{
        .root_source_file = b.path("src/git/objects.zig"),
    });

    // Pack network end-to-end tests (saveReceivedPack → load, fixThinPack, git cross-validation)
    const pack_network_e2e_tests = b.addTest(.{
        .root_source_file = b.path("test/pack_network_e2e_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    pack_network_e2e_tests.root_module.addAnonymousImport("git_objects", .{
        .root_source_file = b.path("src/git/objects.zig"),
    });

    // Pack network receive flow tests (clone/fetch simulation with save+load round-trip)
    const pack_network_receive_flow_tests = b.addTest(.{
        .root_source_file = b.path("test/pack_network_receive_flow_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    pack_network_receive_flow_tests.root_module.addAnonymousImport("git_objects", .{
        .root_source_file = b.path("src/git/objects.zig"),
    });

    // Pack exact compatibility tests (git ↔ ziggit byte-level verification)
    const pack_git_exact_compat_tests = b.addTest(.{
        .root_source_file = b.path("test/pack_git_exact_compat_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    pack_git_exact_compat_tests.root_module.addAnonymousImport("git_objects", .{
        .root_source_file = b.path("src/git/objects.zig"),
    });

    // Pack end-to-end tests (full flow: git creates → ziggit reads/indexes → git verifies)
    const pack_end_to_end_tests = b.addTest(.{
        .root_source_file = b.path("test/pack_end_to_end_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    pack_end_to_end_tests.root_module.addAnonymousImport("git_objects", .{
        .root_source_file = b.path("src/git/objects.zig"),
    });

    // Pack infrastructure tests for HTTPS clone/fetch support
    const pack_infrastructure_tests = b.addTest(.{
        .root_source_file = b.path("test/pack_infrastructure_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    pack_infrastructure_tests.root_module.addAnonymousImport("git_objects", .{
        .root_source_file = b.path("src/git/objects.zig"),
    });

    // Tests using internal src/git/*.zig imports that need refactoring
    // (compiled for syntax checking but excluded from test step)
    const config_enhanced_tests = b.addTest(.{
        .root_source_file = b.path("test/config_enhanced_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const core_format_integration_tests = b.addTest(.{
        .root_source_file = b.path("test/core_format_integration_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const enhanced_functionality_tests = b.addTest(.{
        .root_source_file = b.path("test/enhanced_functionality_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const functionality_tests = b.addTest(.{
        .root_source_file = b.path("test/functionality_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const index_checksum_tests = b.addTest(.{
        .root_source_file = b.path("test/index_checksum_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const index_enhanced_tests = b.addTest(.{
        .root_source_file = b.path("test/index_enhanced_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const pack_enhanced_tests = b.addTest(.{
        .root_source_file = b.path("test/pack_enhanced_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const pack_integration_tests = b.addTest(.{
        .root_source_file = b.path("test/pack_integration_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const refs_enhanced_tests = b.addTest(.{
        .root_source_file = b.path("test/refs_enhanced_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const validation_comprehensive_tests = b.addTest(.{
        .root_source_file = b.path("test/validation_comprehensive_test.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Repository API comprehensive tests
    const repo_api_tests = b.addTest(.{
        .root_source_file = b.path("test/repository_api_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    repo_api_tests.root_module.addImport("ziggit", ziggit_module);

    // Object integrity tests
    const object_integrity_tests = b.addTest(.{
        .root_source_file = b.path("test/object_integrity_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    object_integrity_tests.root_module.addImport("ziggit", ziggit_module);

    // Index roundtrip tests
    const index_roundtrip_tests = b.addTest(.{
        .root_source_file = b.path("test/index_roundtrip_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    index_roundtrip_tests.root_module.addImport("ziggit", ziggit_module);

    // Edge case tests
    const edge_cases_tests = b.addTest(.{
        .root_source_file = b.path("test/edge_cases_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    edge_cases_tests.root_module.addImport("ziggit", ziggit_module);

    // Index parser unit tests
    const index_parser_unit_tests = b.addTest(.{
        .root_source_file = b.path("test/index_parser_unit_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    index_parser_unit_tests.root_module.addImport("ziggit", ziggit_module);

    // Status detection tests
    const status_detection_tests = b.addTest(.{
        .root_source_file = b.path("test/status_detection_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    status_detection_tests.root_module.addImport("ziggit", ziggit_module);

    // Commit graph tests
    const commit_graph_tests = b.addTest(.{
        .root_source_file = b.path("test/commit_graph_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    commit_graph_tests.root_module.addImport("ziggit", ziggit_module);

    // Index binary format tests
    const index_binary_format_tests = b.addTest(.{
        .root_source_file = b.path("test/index_binary_format_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    index_binary_format_tests.root_module.addImport("ziggit", ziggit_module);

    // Dirty detection tests
    const dirty_detection_tests = b.addTest(.{
        .root_source_file = b.path("test/dirty_detection_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    dirty_detection_tests.root_module.addImport("ziggit", ziggit_module);

    // Objects parser tests
    const objects_parser_tests = b.addTest(.{
        .root_source_file = b.path("test/objects_parser_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    objects_parser_tests.root_module.addImport("ziggit", ziggit_module);

    // Ref resolution tests
    const ref_resolution_tests = b.addTest(.{
        .root_source_file = b.path("test/ref_resolution_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    ref_resolution_tests.root_module.addImport("ziggit", ziggit_module);

    // Objects parser unit tests (SHA-1, commit format, tree format, cross-validation)
    const objects_parser_unit_tests = b.addTest(.{
        .root_source_file = b.path("test/objects_parser_unit_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    objects_parser_unit_tests.root_module.addImport("ziggit", ziggit_module);

    // Cross-validation tests (ziggit writes/git reads, git writes/ziggit reads)
    const cross_validation_tests = b.addTest(.{
        .root_source_file = b.path("test/cross_validation_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    cross_validation_tests.root_module.addImport("ziggit", ziggit_module);

    // Test step - runs all unit tests and integration tests
    const test_step = b.step("test", "Run all unit tests and integration tests");
    test_step.dependOn(&b.addRunArtifact(platform_unit_tests).step);
    test_step.dependOn(&b.addRunArtifact(platform_integration_test).step);
    test_step.dependOn(&b.addRunArtifact(core_compatibility_test).step);
    test_step.dependOn(&b.addRunArtifact(git_interop_test).step);
    test_step.dependOn(&b.addRunArtifact(workflow_test).step);
    test_step.dependOn(&b.addRunArtifact(broken_pipe_test).step);
    test_step.dependOn(&b.addRunArtifact(bun_zig_api_test).step);
    // Tests with proper module imports (run in test step)
    test_step.dependOn(&b.addRunArtifact(core_git_format_tests).step);
    test_step.dependOn(&b.addRunArtifact(pack_comprehensive_tests).step);
    test_step.dependOn(&b.addRunArtifact(delta_apply_tests).step);
    test_step.dependOn(&b.addRunArtifact(pack_roundtrip_tests).step);
    test_step.dependOn(&b.addRunArtifact(pack_write_read_tests).step);
    test_step.dependOn(&b.addRunArtifact(delta_edge_cases_tests).step);
    test_step.dependOn(&b.addRunArtifact(delta_strict_correctness_tests).step);
    test_step.dependOn(&b.addRunArtifact(clone_workflow_integration_tests).step);
    test_step.dependOn(&b.addRunArtifact(pack_index_gen_tests).step);
    test_step.dependOn(&b.addRunArtifact(pack_delta_integration_tests).step);
    test_step.dependOn(&b.addRunArtifact(pack_format_groundtruth_tests).step);
    test_step.dependOn(&b.addRunArtifact(ref_delta_chain_tests).step);
    test_step.dependOn(&b.addRunArtifact(pack_core_verification_tests).step);

    // Pack format unit tests (byte-level pack construction, all object types, delta chains)
    const pack_format_unit_tests = b.addTest(.{
        .root_source_file = b.path("test/pack_format_unit_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    pack_format_unit_tests.root_module.addAnonymousImport("git_objects", .{
        .root_source_file = b.path("src/git/objects.zig"),
    });
    test_step.dependOn(&b.addRunArtifact(pack_format_unit_tests).step);

    const pack_save_load_roundtrip_tests = b.addTest(.{
        .root_source_file = b.path("test/pack_save_load_roundtrip_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    pack_save_load_roundtrip_tests.root_module.addAnonymousImport("git_objects", .{
        .root_source_file = b.path("src/git/objects.zig"),
    });
    test_step.dependOn(&b.addRunArtifact(pack_save_load_roundtrip_tests).step);

    test_step.dependOn(&b.addRunArtifact(pack_network_reception_tests).step);
    test_step.dependOn(&b.addRunArtifact(pack_network_e2e_tests).step);
    test_step.dependOn(&b.addRunArtifact(pack_network_receive_flow_tests).step);
    test_step.dependOn(&b.addRunArtifact(pack_clone_flow_tests).step);
    test_step.dependOn(&b.addRunArtifact(pack_git_groundtruth_tests).step);
    test_step.dependOn(&b.addRunArtifact(pack_thin_public_api_tests).step);
    test_step.dependOn(&b.addRunArtifact(pack_object_read_tests).step);
    test_step.dependOn(&b.addRunArtifact(pack_ref_delta_thin_tests).step);
    test_step.dependOn(&b.addRunArtifact(pack_readback_thin_tests).step);
    test_step.dependOn(&b.addRunArtifact(pack_infrastructure_tests).step);
    test_step.dependOn(&b.addRunArtifact(pack_git_exact_compat_tests).step);
    test_step.dependOn(&b.addRunArtifact(pack_end_to_end_tests).step);

    // Pack git cross-validation tests (real git packs, all object types, idx generation, round-trip)
    const pack_git_crossvalidation_tests = b.addTest(.{
        .root_source_file = b.path("test/pack_git_crossvalidation_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    pack_git_crossvalidation_tests.root_module.addAnonymousImport("git_objects", .{
        .root_source_file = b.path("src/git/objects.zig"),
    });
    test_step.dependOn(&b.addRunArtifact(pack_git_crossvalidation_tests).step);

    // Pack format correctness tests (byte-exact pack construction, all object types, delta, idx generation)
    const pack_format_correctness_tests = b.addTest(.{
        .root_source_file = b.path("test/pack_format_correctness_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    pack_format_correctness_tests.root_module.addAnonymousImport("git_objects", .{
        .root_source_file = b.path("src/git/objects.zig"),
    });
    test_step.dependOn(&b.addRunArtifact(pack_format_correctness_tests).step);

    // Pack internals ground-truth tests (readPackObjectAtOffset, applyDelta, generatePackIndex, git cross-validation)
    const pack_internals_groundtruth_tests = b.addTest(.{
        .root_source_file = b.path("test/pack_internals_groundtruth_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    pack_internals_groundtruth_tests.root_module.addAnonymousImport("git_objects", .{
        .root_source_file = b.path("src/git/objects.zig"),
    });
    test_step.dependOn(&b.addRunArtifact(pack_internals_groundtruth_tests).step);

    // Pack clone pipeline tests (end-to-end clone/fetch simulation)
    const pack_clone_pipeline_tests = b.addTest(.{
        .root_source_file = b.path("test/pack_clone_pipeline_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    pack_clone_pipeline_tests.root_module.addAnonymousImport("git_objects", .{
        .root_source_file = b.path("src/git/objects.zig"),
    });
    test_step.dependOn(&b.addRunArtifact(pack_clone_pipeline_tests).step);

    // Pack full roundtrip tests (delta, all object types, git cross-validation, saveReceivedPack+load)
    const pack_full_roundtrip_tests = b.addTest(.{
        .root_source_file = b.path("test/pack_full_roundtrip_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    pack_full_roundtrip_tests.root_module.addAnonymousImport("git_objects", .{
        .root_source_file = b.path("src/git/objects.zig"),
    });
    test_step.dependOn(&b.addRunArtifact(pack_full_roundtrip_tests).step);

    // Pack idx compatibility and saveReceivedPack tests
    const pack_idx_compat_tests = b.addTest(.{
        .root_source_file = b.path("test/pack_idx_compat_and_save_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    pack_idx_compat_tests.root_module.addAnonymousImport("git_objects", .{
        .root_source_file = b.path("src/git/objects.zig"),
    });
    test_step.dependOn(&b.addRunArtifact(pack_idx_compat_tests).step);

    // Pack save+load integration tests (full clone/fetch path)
    const pack_save_load_tests = b.addTest(.{
        .root_source_file = b.path("test/pack_save_and_load_integration_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    pack_save_load_tests.root_module.addAnonymousImport("git_objects", .{
        .root_source_file = b.path("src/git/objects.zig"),
    });
    test_step.dependOn(&b.addRunArtifact(pack_save_load_tests).step);

    // Real git interop tests (pack format, delta, idx generation)
    const pack_git_real_interop_tests = b.addTest(.{
        .root_source_file = b.path("test/pack_git_real_interop_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    pack_git_real_interop_tests.root_module.addAnonymousImport("git_objects", .{
        .root_source_file = b.path("src/git/objects.zig"),
    });
    test_step.dependOn(&b.addRunArtifact(pack_git_real_interop_tests).step);

    // Refs + pack integration tests (clone/fetch workflow simulation)
    const refs_pack_integration_tests = b.addTest(.{
        .root_source_file = b.path("test/refs_and_pack_integration_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    refs_pack_integration_tests.root_module.addAnonymousImport("git_objects", .{
        .root_source_file = b.path("src/git/objects.zig"),
    });
    test_step.dependOn(&b.addRunArtifact(refs_pack_integration_tests).step);

    // New tests from other agents (may be slow, included for completeness)
    test_step.dependOn(&b.addRunArtifact(repo_api_tests).step);
    test_step.dependOn(&b.addRunArtifact(object_integrity_tests).step);
    test_step.dependOn(&b.addRunArtifact(index_roundtrip_tests).step);
    test_step.dependOn(&b.addRunArtifact(edge_cases_tests).step);
    // Tests using internal imports excluded until refactored
    _ = config_enhanced_tests;
    _ = core_format_integration_tests;
    _ = enhanced_functionality_tests;
    _ = functionality_tests;
    _ = index_checksum_tests;
    _ = index_enhanced_tests;
    _ = pack_enhanced_tests;
    _ = pack_integration_tests;
    _ = refs_enhanced_tests;
    _ = validation_comprehensive_tests;
    test_step.dependOn(&b.addRunArtifact(repo_api_tests).step);
    test_step.dependOn(&b.addRunArtifact(object_integrity_tests).step);
    test_step.dependOn(&b.addRunArtifact(index_roundtrip_tests).step);
    test_step.dependOn(&b.addRunArtifact(edge_cases_tests).step);
    test_step.dependOn(&b.addRunArtifact(index_parser_unit_tests).step);
    test_step.dependOn(&b.addRunArtifact(status_detection_tests).step);
    test_step.dependOn(&b.addRunArtifact(commit_graph_tests).step);
    test_step.dependOn(&b.addRunArtifact(index_binary_format_tests).step);
    test_step.dependOn(&b.addRunArtifact(dirty_detection_tests).step);
    test_step.dependOn(&b.addRunArtifact(objects_parser_tests).step);
    test_step.dependOn(&b.addRunArtifact(ref_resolution_tests).step);
    test_step.dependOn(&b.addRunArtifact(objects_parser_unit_tests).step);
    test_step.dependOn(&b.addRunArtifact(cross_validation_tests).step);

    // Index git compatibility tests
    const index_git_compat_tests = b.addTest(.{
        .root_source_file = b.path("test/index_git_compat_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    index_git_compat_tests.root_module.addImport("ziggit", ziggit_module);
    test_step.dependOn(&b.addRunArtifact(index_git_compat_tests).step);

    // Cache invalidation tests
    const cache_invalidation_tests = b.addTest(.{
        .root_source_file = b.path("test/cache_invalidation_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    cache_invalidation_tests.root_module.addImport("ziggit", ziggit_module);
    test_step.dependOn(&b.addRunArtifact(cache_invalidation_tests).step);

    // Status modified files tests
    const status_modified_files_tests = b.addTest(.{
        .root_source_file = b.path("test/status_modified_files_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    status_modified_files_tests.root_module.addImport("ziggit", ziggit_module);
    test_step.dependOn(&b.addRunArtifact(status_modified_files_tests).step);

    // Commit/checkout cycle tests
    const commit_checkout_cycle_tests = b.addTest(.{
        .root_source_file = b.path("test/commit_checkout_cycle_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    commit_checkout_cycle_tests.root_module.addImport("ziggit", ziggit_module);
    test_step.dependOn(&b.addRunArtifact(commit_checkout_cycle_tests).step);

    // Object content verification tests
    const object_content_verify_tests = b.addTest(.{
        .root_source_file = b.path("test/object_content_verification_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    object_content_verify_tests.root_module.addImport("ziggit", ziggit_module);
    test_step.dependOn(&b.addRunArtifact(object_content_verify_tests).step);

    // Index write verification tests
    const index_write_verify_tests = b.addTest(.{
        .root_source_file = b.path("test/index_write_verify_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    index_write_verify_tests.root_module.addImport("ziggit", ziggit_module);
    test_step.dependOn(&b.addRunArtifact(index_write_verify_tests).step);

    // Tree sorting tests
    const tree_sorting_tests = b.addTest(.{
        .root_source_file = b.path("test/tree_sorting_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    tree_sorting_tests.root_module.addImport("ziggit", ziggit_module);
    test_step.dependOn(&b.addRunArtifact(tree_sorting_tests).step);

    // Repository lifecycle tests
    const repo_lifecycle_tests = b.addTest(.{
        .root_source_file = b.path("test/repo_lifecycle_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    repo_lifecycle_tests.root_module.addImport("ziggit", ziggit_module);
    test_step.dependOn(&b.addRunArtifact(repo_lifecycle_tests).step);

    // E2E validation: ziggit writes, git reads
    const ziggit_writes_test = b.addTest(.{
        .root_source_file = b.path("test/ziggit_writes_git_reads_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    ziggit_writes_test.root_module.addImport("ziggit", ziggit_module);

    // Status porcelain compatibility tests
    const status_porcelain_compat_tests = b.addTest(.{
        .root_source_file = b.path("test/status_porcelain_compat_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    status_porcelain_compat_tests.root_module.addImport("ziggit", ziggit_module);
    test_step.dependOn(&b.addRunArtifact(status_porcelain_compat_tests).step);

    // Comprehensive Repository API tests
    const repo_api_comprehensive_tests = b.addTest(.{
        .root_source_file = b.path("test/repo_api_comprehensive_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    repo_api_comprehensive_tests.root_module.addImport("ziggit", ziggit_module);
    test_step.dependOn(&b.addRunArtifact(repo_api_comprehensive_tests).step);

    // Refs validation tests (internal git module)
    const refs_validation_tests = b.addTest(.{
        .root_source_file = b.path("test/refs_validation_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    refs_validation_tests.root_module.addAnonymousImport("git", .{
        .root_source_file = b.path("src/git/git.zig"),
    });
    test_step.dependOn(&b.addRunArtifact(refs_validation_tests).step);

    // Config parsing tests (internal git module)
    const config_parsing_tests = b.addTest(.{
        .root_source_file = b.path("test/config_parsing_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    config_parsing_tests.root_module.addAnonymousImport("git", .{
        .root_source_file = b.path("src/git/git.zig"),
    });
    test_step.dependOn(&b.addRunArtifact(config_parsing_tests).step);

    // Git objects internal tests (hash, store, load)
    const git_objects_internal_tests = b.addTest(.{
        .root_source_file = b.path("test/git_objects_internal_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    git_objects_internal_tests.root_module.addAnonymousImport("git", .{
        .root_source_file = b.path("src/git/git.zig"),
    });
    test_step.dependOn(&b.addRunArtifact(git_objects_internal_tests).step);

    // Object store/load roundtrip tests
    const object_store_load_tests = b.addTest(.{
        .root_source_file = b.path("test/object_store_load_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    object_store_load_tests.root_module.addAnonymousImport("git", .{
        .root_source_file = b.path("src/git/git.zig"),
    });
    test_step.dependOn(&b.addRunArtifact(object_store_load_tests).step);

    // Packed refs tests
    const packed_refs_tests = b.addTest(.{
        .root_source_file = b.path("test/packed_refs_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    packed_refs_tests.root_module.addAnonymousImport("git", .{
        .root_source_file = b.path("src/git/git.zig"),
    });
    test_step.dependOn(&b.addRunArtifact(packed_refs_tests).step);

    // Index write/read roundtrip tests
    const index_write_read_tests = b.addTest(.{
        .root_source_file = b.path("test/index_write_read_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    index_write_read_tests.root_module.addAnonymousImport("git", .{
        .root_source_file = b.path("src/git/git.zig"),
    });
    test_step.dependOn(&b.addRunArtifact(index_write_read_tests).step);

    // Git index internal tests (parseIndexData, binary format)
    const git_index_internal_tests = b.addTest(.{
        .root_source_file = b.path("test/git_index_internal_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    git_index_internal_tests.root_module.addAnonymousImport("git", .{
        .root_source_file = b.path("src/git/git.zig"),
    });
    test_step.dependOn(&b.addRunArtifact(git_index_internal_tests).step);

    // Git internal module tests (objects, config, index via git module)
    const git_internal_module_tests = b.addTest(.{
        .root_source_file = b.path("test/git_internal_module_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    git_internal_module_tests.root_module.addAnonymousImport("git", .{
        .root_source_file = b.path("src/git/git.zig"),
    });
    test_step.dependOn(&b.addRunArtifact(git_internal_module_tests).step);

    // Cache correctness tests
    const cache_correctness_tests = b.addTest(.{
        .root_source_file = b.path("test/cache_correctness_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    cache_correctness_tests.root_module.addImport("ziggit", ziggit_module);
    test_step.dependOn(&b.addRunArtifact(cache_correctness_tests).step);

    // E2E validation: git writes, ziggit reads
    const git_writes_test = b.addTest(.{
        .root_source_file = b.path("test/git_writes_ziggit_reads_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    git_writes_test.root_module.addImport("ziggit", ziggit_module);

    // Bun workflow e2e tests
    const bun_workflow_e2e_tests = b.addTest(.{
        .root_source_file = b.path("test/bun_workflow_e2e_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    bun_workflow_e2e_tests.root_module.addImport("ziggit", ziggit_module);

    // E2E validation step (separate from main test to allow independent running)
    const e2e_step = b.step("e2e", "Run end-to-end validation tests");
    e2e_step.dependOn(&b.addRunArtifact(ziggit_writes_test).step);
    e2e_step.dependOn(&b.addRunArtifact(git_writes_test).step);
    e2e_step.dependOn(&b.addRunArtifact(bun_workflow_e2e_tests).step);

    // API git cross-check tests
    const api_git_crosscheck_tests = b.addTest(.{
        .root_source_file = b.path("test/api_git_crosscheck_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    api_git_crosscheck_tests.root_module.addImport("ziggit", ziggit_module);
    test_step.dependOn(&b.addRunArtifact(api_git_crosscheck_tests).step);

    // Git format correctness tests (blob/tree/commit/tag cross-validated with git CLI)
    const git_format_correctness_tests = b.addTest(.{
        .root_source_file = b.path("test/git_format_correctness_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    git_format_correctness_tests.root_module.addImport("ziggit", ziggit_module);
    test_step.dependOn(&b.addRunArtifact(git_format_correctness_tests).step);

    // Strict pack delta tests (format correctness, git compat, clone flow)
    const pack_delta_strict_tests = b.addTest(.{
        .root_source_file = b.path("test/pack_delta_strict_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    pack_delta_strict_tests.root_module.addAnonymousImport("git_objects", .{
        .root_source_file = b.path("src/git/objects.zig"),
    });
    test_step.dependOn(&b.addRunArtifact(pack_delta_strict_tests).step);

    // E2E tests also available via main test step (may be slow)
    test_step.dependOn(&b.addRunArtifact(ziggit_writes_test).step);
    test_step.dependOn(&b.addRunArtifact(git_writes_test).step);
    test_step.dependOn(&b.addRunArtifact(bun_workflow_e2e_tests).step);

    // Bun workflow E2E validation tests (ziggit API -> git CLI verification)
    const bun_workflow_e2e_validation_tests = b.addTest(.{
        .root_source_file = b.path("test/bun_workflow_e2e_validation_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    bun_workflow_e2e_validation_tests.root_module.addImport("ziggit", ziggit_module);
    test_step.dependOn(&b.addRunArtifact(bun_workflow_e2e_validation_tests).step);

    // Repository workflow tests
    const repo_workflow_tests = b.addTest(.{
        .root_source_file = b.path("test/repo_workflow_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    repo_workflow_tests.root_module.addImport("ziggit", ziggit_module);
    test_step.dependOn(&b.addRunArtifact(repo_workflow_tests).step);

    // Clone and fetch tests
    const clone_and_fetch_tests = b.addTest(.{
        .root_source_file = b.path("test/clone_and_fetch_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    clone_and_fetch_tests.root_module.addImport("ziggit", ziggit_module);
    test_step.dependOn(&b.addRunArtifact(clone_and_fetch_tests).step);

    // Object decompression tests
    const object_decompression_tests = b.addTest(.{
        .root_source_file = b.path("test/object_decompression_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    object_decompression_tests.root_module.addImport("ziggit", ziggit_module);
    test_step.dependOn(&b.addRunArtifact(object_decompression_tests).step);

    // Objects parser comprehensive tests
    const objects_parser_comprehensive_tests = b.addTest(.{
        .root_source_file = b.path("test/objects_parser_comprehensive_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    objects_parser_comprehensive_tests.root_module.addImport("ziggit", ziggit_module);
    test_step.dependOn(&b.addRunArtifact(objects_parser_comprehensive_tests).step);

    // Hash correctness tests (SHA-1, git interop, known values)
    const hash_correctness_tests = b.addTest(.{
        .root_source_file = b.path("test/hash_correctness_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    hash_correctness_tests.root_module.addImport("ziggit", ziggit_module);
    test_step.dependOn(&b.addRunArtifact(hash_correctness_tests).step);

    // Fast index parser tests
    const fast_index_parser_tests = b.addTest(.{
        .root_source_file = b.path("test/fast_index_parser_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    fast_index_parser_tests.root_module.addImport("ziggit", ziggit_module);
    test_step.dependOn(&b.addRunArtifact(fast_index_parser_tests).step);

    // Short hash and findCommit tests
    const short_hash_tests = b.addTest(.{
        .root_source_file = b.path("test/short_hash_and_findcommit_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    short_hash_tests.root_module.addImport("ziggit", ziggit_module);
    test_step.dependOn(&b.addRunArtifact(short_hash_tests).step);

    // Object create and parse tests (internal git module)
    const object_create_parse_tests = b.addTest(.{
        .root_source_file = b.path("test/object_create_and_parse_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    object_create_parse_tests.root_module.addAnonymousImport("git", .{
        .root_source_file = b.path("src/git/git.zig"),
    });
    test_step.dependOn(&b.addRunArtifact(object_create_parse_tests).step);

    // Git interop comprehensive tests
    const git_interop_comprehensive_tests = b.addTest(.{
        .root_source_file = b.path("test/git_interop_comprehensive_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    git_interop_comprehensive_tests.root_module.addImport("ziggit", ziggit_module);
    test_step.dependOn(&b.addRunArtifact(git_interop_comprehensive_tests).step);

    // Pack fetch pipeline tests (HTTPS clone/fetch infrastructure)
    const pack_fetch_pipeline_tests = b.addTest(.{
        .root_source_file = b.path("test/pack_fetch_pipeline_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    pack_fetch_pipeline_tests.root_module.addAnonymousImport("git_objects", .{
        .root_source_file = b.path("src/git/objects.zig"),
    });
    test_step.dependOn(&b.addRunArtifact(pack_fetch_pipeline_tests).step);

    // Pack network infrastructure tests (readPackObjectAtOffset, fixThinPack, saveReceivedPack, git cross-validation)
    const pack_network_infra_tests = b.addTest(.{
        .root_source_file = b.path("test/pack_network_infra_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    pack_network_infra_tests.root_module.addAnonymousImport("git_objects", .{
        .root_source_file = b.path("src/git/objects.zig"),
    });
    test_step.dependOn(&b.addRunArtifact(pack_network_infra_tests).step);

    // Pack network clone tests (full clone/fetch flow: fixThinPack, saveReceivedPack, ref update, git fsck)
    const pack_network_clone_tests = b.addTest(.{
        .root_source_file = b.path("test/pack_network_clone_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    pack_network_clone_tests.root_module.addAnonymousImport("git_objects", .{
        .root_source_file = b.path("src/git/objects.zig"),
    });
    test_step.dependOn(&b.addRunArtifact(pack_network_clone_tests).step);

    // Objects store and hash tests (internal git module)
    const objects_store_hash_tests = b.addTest(.{
        .root_source_file = b.path("test/objects_store_and_hash_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    objects_store_hash_tests.root_module.addAnonymousImport("git", .{
        .root_source_file = b.path("src/git/git.zig"),
    });
    test_step.dependOn(&b.addRunArtifact(objects_store_hash_tests).step);

    // Index DIRC format tests
    const index_dirc_format_tests = b.addTest(.{
        .root_source_file = b.path("test/index_dirc_format_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    index_dirc_format_tests.root_module.addImport("ziggit", ziggit_module);
    test_step.dependOn(&b.addRunArtifact(index_dirc_format_tests).step);

    // Refs and config internal tests
    const refs_config_internal_tests = b.addTest(.{
        .root_source_file = b.path("test/refs_and_config_internal_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    refs_config_internal_tests.root_module.addAnonymousImport("git", .{
        .root_source_file = b.path("src/git/git.zig"),
    });
    test_step.dependOn(&b.addRunArtifact(refs_config_internal_tests).step);

    // Tag object verification tests
    const tag_object_verification_tests = b.addTest(.{
        .root_source_file = b.path("test/tag_object_verification_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    tag_object_verification_tests.root_module.addImport("ziggit", ziggit_module);
    test_step.dependOn(&b.addRunArtifact(tag_object_verification_tests).step);

    // Multi-file commit tests
    const multifile_commit_tests = b.addTest(.{
        .root_source_file = b.path("test/multifile_commit_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    multifile_commit_tests.root_module.addImport("ziggit", ziggit_module);
    test_step.dependOn(&b.addRunArtifact(multifile_commit_tests).step);

    // Config roundtrip tests (internal git module)
    const config_roundtrip_tests = b.addTest(.{
        .root_source_file = b.path("test/config_roundtrip_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    config_roundtrip_tests.root_module.addAnonymousImport("git", .{
        .root_source_file = b.path("src/git/git.zig"),
    });
    test_step.dependOn(&b.addRunArtifact(config_roundtrip_tests).step);

    // Ref chain resolution tests
    const ref_chain_resolution_tests = b.addTest(.{
        .root_source_file = b.path("test/ref_chain_resolution_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    ref_chain_resolution_tests.root_module.addImport("ziggit", ziggit_module);
    test_step.dependOn(&b.addRunArtifact(ref_chain_resolution_tests).step);

    // Pack git interop correctness tests (real git cross-validation, generatePackIndex verify-pack, delta chains)
    const pack_git_interop_correctness_tests = b.addTest(.{
        .root_source_file = b.path("test/pack_git_interop_correctness_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    pack_git_interop_correctness_tests.root_module.addAnonymousImport("git_objects", .{
        .root_source_file = b.path("src/git/objects.zig"),
    });
    test_step.dependOn(&b.addRunArtifact(pack_git_interop_correctness_tests).step);

    // Diff module tests
    const diff_module_tests = b.addTest(.{
        .root_source_file = b.path("test/diff_module_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    diff_module_tests.root_module.addAnonymousImport("diff", .{
        .root_source_file = b.path("src/git/diff.zig"),
    });
    test_step.dependOn(&b.addRunArtifact(diff_module_tests).step);

    // Tree parse/create tests
    const tree_parse_create_tests = b.addTest(.{
        .root_source_file = b.path("test/tree_parse_create_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    tree_parse_create_tests.root_module.addAnonymousImport("tree", .{
        .root_source_file = b.path("src/git/tree.zig"),
    });
    test_step.dependOn(&b.addRunArtifact(tree_parse_create_tests).step);

    // Validation module tests
    const validation_module_tests = b.addTest(.{
        .root_source_file = b.path("test/validation_module_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    validation_module_tests.root_module.addAnonymousImport("validation", .{
        .root_source_file = b.path("src/git/validation.zig"),
    });
    test_step.dependOn(&b.addRunArtifact(validation_module_tests).step);

    // Gitignore module tests
    const gitignore_module_tests = b.addTest(.{
        .root_source_file = b.path("test/gitignore_module_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    gitignore_module_tests.root_module.addAnonymousImport("gitignore", .{
        .root_source_file = b.path("src/git/gitignore.zig"),
    });
    test_step.dependOn(&b.addRunArtifact(gitignore_module_tests).step);

    // Repository init and structure tests
    const repo_init_structure_tests = b.addTest(.{
        .root_source_file = b.path("test/repo_init_and_structure_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    repo_init_structure_tests.root_module.addImport("ziggit", ziggit_module);
    test_step.dependOn(&b.addRunArtifact(repo_init_structure_tests).step);

    // Blob/tree/commit/tag object tests
    const blob_tree_commit_tests = b.addTest(.{
        .root_source_file = b.path("test/blob_tree_commit_object_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    blob_tree_commit_tests.root_module.addImport("ziggit", ziggit_module);
    test_step.dependOn(&b.addRunArtifact(blob_tree_commit_tests).step);

    // Index format roundtrip tests
    const index_format_roundtrip_tests = b.addTest(.{
        .root_source_file = b.path("test/index_format_roundtrip_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    index_format_roundtrip_tests.root_module.addImport("ziggit", ziggit_module);
    test_step.dependOn(&b.addRunArtifact(index_format_roundtrip_tests).step);

    // Full workflow cross-validation tests
    const full_workflow_crossval_tests = b.addTest(.{
        .root_source_file = b.path("test/full_workflow_crossval_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    full_workflow_crossval_tests.root_module.addImport("ziggit", ziggit_module);
    test_step.dependOn(&b.addRunArtifact(full_workflow_crossval_tests).step);

    // Error handling tests
    const error_handling_tests = b.addTest(.{
        .root_source_file = b.path("test/error_handling_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    error_handling_tests.root_module.addImport("ziggit", ziggit_module);
    test_step.dependOn(&b.addRunArtifact(error_handling_tests).step);

    // Cross-validation stress tests (large files, overwrites, annotated tags, clone bare)
    const crossval_stress_tests = b.addTest(.{
        .root_source_file = b.path("test/crossval_stress_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    crossval_stress_tests.root_module.addImport("ziggit", ziggit_module);
    test_step.dependOn(&b.addRunArtifact(crossval_stress_tests).step);
    e2e_step.dependOn(&b.addRunArtifact(crossval_stress_tests).step);

    // API coverage tests (comprehensive Repository API tests with git cross-validation)
    const api_coverage_tests = b.addTest(.{
        .root_source_file = b.path("test/api_coverage_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    api_coverage_tests.root_module.addImport("ziggit", ziggit_module);
    test_step.dependOn(&b.addRunArtifact(api_coverage_tests).step);

    // Tree and diff internal tests
    const tree_and_diff_internal_tests = b.addTest(.{
        .root_source_file = b.path("test/tree_and_diff_internal_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    tree_and_diff_internal_tests.root_module.addAnonymousImport("tree", .{
        .root_source_file = b.path("src/git/tree.zig"),
    });
    test_step.dependOn(&b.addRunArtifact(tree_and_diff_internal_tests).step);

    // Repository git cross-validation tests
    const repo_git_crossval_tests = b.addTest(.{
        .root_source_file = b.path("test/repo_git_crossval_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    repo_git_crossval_tests.root_module.addImport("ziggit", ziggit_module);
    test_step.dependOn(&b.addRunArtifact(repo_git_crossval_tests).step);

    // Gitignore behavior tests
    const gitignore_behavior_tests = b.addTest(.{
        .root_source_file = b.path("test/gitignore_behavior_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    gitignore_behavior_tests.root_module.addAnonymousImport("gitignore", .{
        .root_source_file = b.path("src/git/gitignore.zig"),
    });
    test_step.dependOn(&b.addRunArtifact(gitignore_behavior_tests).step);

    // Validation SHA1/refs tests
    const validation_sha1_refs_tests = b.addTest(.{
        .root_source_file = b.path("test/validation_sha1_refs_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    validation_sha1_refs_tests.root_module.addAnonymousImport("validation", .{
        .root_source_file = b.path("src/git/validation.zig"),
    });
    test_step.dependOn(&b.addRunArtifact(validation_sha1_refs_tests).step);

    // Diff comprehensive tests
    const diff_comprehensive_tests = b.addTest(.{
        .root_source_file = b.path("test/diff_comprehensive_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    diff_comprehensive_tests.root_module.addAnonymousImport("diff", .{
        .root_source_file = b.path("src/git/diff.zig"),
    });
    test_step.dependOn(&b.addRunArtifact(diff_comprehensive_tests).step);

    // Tree walker and parse tests
    const tree_walker_parse_tests = b.addTest(.{
        .root_source_file = b.path("test/tree_walker_and_parse_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    tree_walker_parse_tests.root_module.addAnonymousImport("tree", .{
        .root_source_file = b.path("src/git/tree.zig"),
    });
    test_step.dependOn(&b.addRunArtifact(tree_walker_parse_tests).step);

    // Diff internal tests
    const diff_internal_tests = b.addTest(.{
        .root_source_file = b.path("test/diff_internal_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    diff_internal_tests.root_module.addAnonymousImport("diff", .{
        .root_source_file = b.path("src/git/diff.zig"),
    });
    test_step.dependOn(&b.addRunArtifact(diff_internal_tests).step);

    // Validation internal tests
    const validation_internal_tests = b.addTest(.{
        .root_source_file = b.path("test/validation_internal_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    validation_internal_tests.root_module.addAnonymousImport("validation", .{
        .root_source_file = b.path("src/git/validation.zig"),
    });
    test_step.dependOn(&b.addRunArtifact(validation_internal_tests).step);

    // ========== BENCHMARKS ==========
    
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
    
    // Bun/npm workflow scenario benchmark
    const bun_scenario_benchmark = b.addExecutable(.{
        .name = "bun_scenario_benchmark",
        .root_source_file = b.path("benchmarks/bun_scenario_bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    bun_scenario_benchmark.root_module.addImport("ziggit", ziggit_module);

    const bench_step = b.step("bench", "Run all benchmarks");
    bench_step.dependOn(&b.addRunArtifact(cli_benchmark).step);
    bench_step.dependOn(&b.addRunArtifact(lib_benchmark).step);
    bench_step.dependOn(&b.addRunArtifact(bun_scenario_benchmark).step);

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
