// Auto-generated from main_common.zig - cmd_gc
// Agents: this file is yours to edit for the commands it contains.

const std = @import("std");
const platform_mod = @import("platform/platform.zig");
const helpers = @import("git_helpers.zig");
const cmd_pack_refs = @import("cmd_pack_refs.zig");
const cmd_repack = @import("cmd_repack.zig");

// Re-export commonly used types from helpers
const objects = helpers.objects;
const index_mod = helpers.index_mod;
const refs = helpers.refs;
const tree_mod = helpers.tree_mod;
const gitignore_mod = helpers.gitignore_mod;
const config_mod = helpers.config_mod;
const config_helpers_mod = helpers.config_helpers_mod;
const diff_mod = helpers.diff_mod;
const diff_stats_mod = helpers.diff_stats_mod;
const network = helpers.network;
const zlib_compat_mod = helpers.zlib_compat_mod;
const build_options = @import("build_options");
const version_mod = @import("version.zig");
const wildmatch_mod = @import("wildmatch.zig");

pub fn nativeCmdGc(allocator: std.mem.Allocator, args: [][]const u8, command_index: usize, platform_impl: *const platform_mod.Platform) !void {
    var aggressive = false;
    var auto_mode = false;
    var prune_option: []const u8 = "2.weeks.ago";
    var quiet = false;
    var no_cruft = false;

    var i = command_index + 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--aggressive")) {
            aggressive = true;
        } else if (std.mem.eql(u8, arg, "--auto")) {
            auto_mode = true;
        } else if (std.mem.startsWith(u8, arg, "--prune=")) {
            prune_option = arg["--prune=".len..];
        } else if (std.mem.eql(u8, arg, "--prune")) {
            i += 1;
            if (i < args.len) prune_option = args[i];
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            quiet = true;
        } else if (std.mem.eql(u8, arg, "--no-prune")) {
            prune_option = "never";
        } else if (std.mem.eql(u8, arg, "--no-cruft")) {
            no_cruft = true;
        } else if (std.mem.eql(u8, arg, "--no-quiet")) {
            quiet = false;
        } else if (std.mem.eql(u8, arg, "--cruft")) {
            // accepted
        } else if (std.mem.eql(u8, arg, "--force")) {
            // accepted
        } else if (std.mem.eql(u8, arg, "--detach") or std.mem.eql(u8, arg, "--no-detach")) {
            // accepted
        } else if (std.mem.eql(u8, arg, "--keep-largest-pack")) {
            // accepted
        } else if (std.mem.startsWith(u8, arg, "--max-cruft-size=") or
            std.mem.startsWith(u8, arg, "--expire-to="))
        {
            // accepted
        } else if (std.mem.eql(u8, arg, "-h")) {
            try platform_impl.writeStderr("usage: git gc [--aggressive] [--auto] [--quiet] [--prune=<date>]\n");
            std.process.exit(129);
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try platform_impl.writeStderr("usage: git gc [--aggressive] [--auto] [--quiet] [--prune=<date>]\n");
            std.process.exit(129);
        }
    }

    const git_dir = helpers.findGitDir() catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
        unreachable;
    };

    // Run native repack
    if (!quiet) {
        try platform_impl.writeStderr("Enumerating objects: done.\n");
        try platform_impl.writeStderr("Counting objects: done.\n");
    }

    // Repack helpers.objects into a single pack
    try cmd_repack.doNativeRepack(allocator, git_dir, platform_impl, quiet);

    // Prune loose helpers.objects
    if (!std.mem.eql(u8, prune_option, "never")) {
        try helpers.doNativePrune(allocator, git_dir, platform_impl, prune_option);
    }

    // Pack helpers.refs
    try cmd_pack_refs.packRefs(allocator, git_dir);

    // helpers.Remove empty directories
    try cleanEmptyObjectDirs(allocator, git_dir);
}


pub fn cleanEmptyObjectDirs(allocator: std.mem.Allocator, git_dir: []const u8) !void {
    const objects_dir_path = std.fmt.allocPrint(allocator, "{s}/objects", .{git_dir}) catch return;
    defer allocator.free(objects_dir_path);

    var hex_dirs: usize = 0;
    while (hex_dirs < 256) : (hex_dirs += 1) {
        var hex_buf: [2]u8 = undefined;
        _ = std.fmt.bufPrint(&hex_buf, "{x:0>2}", .{hex_dirs}) catch continue;
        const subdir_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ objects_dir_path, hex_buf }) catch continue;
        defer allocator.free(subdir_path);

        // helpers.Try to remove - will fail if not empty (which is fine)
        std.fs.cwd().deleteDir(subdir_path) catch {};
    }
}


pub fn cleanEmptyRefDirs(git_dir: []const u8, ref_name: []const u8, allocator: std.mem.Allocator) void {
    // helpers.After deleting a ref like refs/heads/foo/bar, clean up empty parent dirs
    var path = ref_name;
    while (std.fs.path.dirname(path)) |parent| {
        if (std.mem.eql(u8, parent, "refs") or parent.len == 0) break;
        const full = std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_dir, parent }) catch break;
        defer allocator.free(full);
        std.fs.cwd().deleteDir(full) catch break;
        path = parent;
    }
}


pub fn cleanEmptyRefDirs2(allocator: std.mem.Allocator, git_dir: []const u8, prefix: []const u8) void {
    const dir_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_dir, prefix }) catch return;
    defer allocator.free(dir_path);

    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    // helpers.Collect subdirectory names first
    var subdirs = std.ArrayList([]const u8).init(allocator);
    defer {
        for (subdirs.items) |s| allocator.free(s);
        subdirs.deinit();
    }
    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind == .directory) {
            subdirs.append(allocator.dupe(u8, entry.name) catch continue) catch {};
        }
    }

    for (subdirs.items) |subdir| {
        const child_prefix = std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, subdir }) catch continue;
        defer allocator.free(child_prefix);
        cleanEmptyRefDirs2(allocator, git_dir, child_prefix);
    }

    // helpers.Try to remove this dir if empty (and not the "refs" root itself)
    if (!std.mem.eql(u8, prefix, "refs")) {
        std.fs.cwd().deleteDir(dir_path) catch {};
    }
}


