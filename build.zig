const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const enable_git_fallback = b.option(bool, "git-fallback", "Enable git CLI fallback") orelse false;
    const options = b.addOptions();
    options.addOption(bool, "enable_git_fallback", enable_git_fallback);
    const exe_optimize: std.builtin.OptimizeMode = if (optimize == .Debug) .ReleaseFast else optimize;
    const exe = b.addExecutable(.{
        .name = "ziggit",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = exe_optimize,
            .imports = &.{
                .{ .name = "build_options", .module = options.createModule() },
            },
        }),
    });
    exe.linkLibC();

    const install_exe = b.addInstallArtifact(exe, .{});

    // Expose ziggit as a library module for downstream consumers (e.g., bun fork)
    _ = b.addModule("ziggit", .{
        .root_source_file = b.path("src/ziggit.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Install shell helper scripts needed by git test suite
    const shell_scripts = [_][]const u8{
        "git-sh-setup",
        "git-sh-i18n",
    };
    for (shell_scripts) |script| {
        b.getInstallStep().dependOn(&b.addInstallFile(
            b.path(b.fmt("shell-scripts/{s}", .{script})),
            b.fmt("bin/{s}", .{script}),
        ).step);
    }

    // Create git -> ziggit symlink so test suite can find 'git' command
    const symlink = b.addSystemCommand(&.{ "ln", "-sf", "ziggit", b.getInstallPath(.bin, "git") });
    symlink.step.dependOn(&install_exe.step);
    b.getInstallStep().dependOn(&symlink.step);

    // WASM build target (wasm32-freestanding)
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const wasm = b.addExecutable(.{
        .name = "ziggit",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_freestanding.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
            .imports = &.{
                .{ .name = "config", .module = b.createModule(.{ .root_source_file = b.path("src/wasm_config.zig") }) },
            },
        }),
    });
    wasm.entry = .disabled;
    wasm.root_module.export_symbol_names = &.{
        "ziggit_main",
        "ziggit_command",
        "ziggit_command_line",
        "ziggit_set_args",
        "getGlobalArgc",
        "getGlobalArgv",
        // wasm_exports.zig git operations
        "ziggit_alloc",
        "ziggit_free",
        "ziggit_init",
        "ziggit_is_repo",
        "ziggit_rev_parse_head",
        "ziggit_current_branch",
        "ziggit_hash_blob",
        "ziggit_store_blob",
        "ziggit_http_get",
        "ziggit_http_post",
        "ziggit_clone_bare",
        "ziggit_ls_remote",
        "ziggit_version",
        "ziggit_index_pack",
        "ziggit_read_object",
        "ziggit_log",
        "ziggit_ls_tree",
        "ziggit_read_file",
        "ziggit_commit_tree",
        // Low-level WASM utils for browser
        "ziggit_zlib_decompress",
        "ziggit_sha1",
        "ziggit_apply_delta",
        "ziggit_load_pack",
        "ziggit_pack_object_count",
        "ziggit_decompress_and_hash",
        "ziggit_parse_pack_header",
        "ziggit_gitignore_init",
        "ziggit_gitignore_match",
        "ziggit_gitignore_free",
        "ziggit_validate_sha1",
        "ziggit_validate_ref",
        "ziggit_validate_path",
        "ziggit_diff",
        "ziggit_split_lines",
        "ziggit_tree_walk",
        "ziggit_detect_language",
        "ziggit_parse_config",
        "ziggit_verify_pack",
        "ziggit_parse_commit",
        "ziggit_parse_refs",
        "ziggit_build_want_request",
        "ziggit_extract_pack_data",
        "ziggit_extract_all_objects",
        "ziggit_read_object_alloc",
        "ziggit_merge_base",
        "ziggit_count_lines",
        "ziggit_hash_object",
        "ziggit_url_decode",
        "ziggit_walk_commits",
        "ziggit_lcs",
        "ziggit_diff_with_context",
        "ziggit_parse_tree",
        "ziggit_parse_tag",
        "ziggit_crc32",
        "ziggit_zlib_compress",
        "ziggit_pack_stats",
        "ziggit_diff_trees",
        "ziggit_enumerate_objects",
        "ziggit_find_objects",
        "ziggit_read_object_by_index",
        "ziggit_memory_stats",
        "ziggit_unload_pack",
    };

    const wasm_step = b.step("wasm", "Build WASM module for browser");
    wasm_step.dependOn(&b.addInstallArtifact(wasm, .{
        .dest_dir = .{ .override = .{ .custom = "wasm" } },
    }).step);
}
