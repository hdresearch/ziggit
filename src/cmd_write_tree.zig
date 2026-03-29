// Auto-generated from main_common.zig - cmd_write_tree
// Agents: this file is yours to edit for the commands it contains.

const std = @import("std");
const platform_mod = @import("platform/platform.zig");
const helpers = @import("git_helpers.zig");

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

pub fn cmdWriteTree(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    var prefix: ?[]const u8 = null;
    var missing_ok = false;
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--prefix=")) {
            prefix = arg["--prefix=".len..];
        } else if (std.mem.eql(u8, arg, "--prefix")) {
            prefix = args.next();
        } else if (std.mem.eql(u8, arg, "--missing-ok")) {
            missing_ok = true;
        }
    }
    const git_dir = helpers.findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
        unreachable;
    };
    defer allocator.free(git_dir);

    // helpers.Load the index
    var idx = index_mod.Index.load(git_dir, platform_impl, allocator) catch {
        try platform_impl.writeStderr("fatal: unable to read index\n");
        std.process.exit(128);
        unreachable;
    };
    defer idx.deinit();

    // Unless --missing-ok, validate that all helpers.objects referenced in the index exist
    if (!missing_ok) {
        for (idx.entries.items) |entry| {
            // helpers.Skip entries not under prefix
            if (prefix) |pfx| {
                if (!std.mem.startsWith(u8, entry.path, pfx)) continue;
            }
            var hash_hex: [40]u8 = undefined;
            for (entry.sha1, 0..) |byte, j| {
                const hex = std.fmt.bytesToHex([1]u8{byte}, .lower);
                hash_hex[j * 2] = hex[0];
                hash_hex[j * 2 + 1] = hex[1];
            }
            // helpers.Check if object exists (loose or packed)
            const obj_exists = helpers.objectExistsCheck(git_dir, &hash_hex, platform_impl, allocator);
            if (!obj_exists) {
                const msg = try std.fmt.allocPrint(allocator, "error: invalid object {o:0>6} {s} for '{s}'\nfatal: git-write-tree: error building trees\n", .{ entry.mode, &hash_hex, entry.path });
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(128);
                unreachable;
            }
        }
    }

    // helpers.Build tree from index entries, optionally scoped to prefix
    // Ensure prefix has trailing slash
    const write_prefix = if (prefix) |pfx|
        (if (pfx.len > 0 and pfx[pfx.len - 1] != '/')
            try std.fmt.allocPrint(allocator, "{s}/", .{pfx})
        else
            try allocator.dupe(u8, pfx))
    else
        try allocator.dupe(u8, "");
    defer allocator.free(write_prefix);
    const tree_hash = helpers.writeTreeRecursive(allocator, &idx, write_prefix, git_dir, platform_impl) catch {
        try platform_impl.writeStderr("fatal: unable to write tree\n");
        std.process.exit(128);
        unreachable;
    };
    defer allocator.free(tree_hash);

    const output = try std.fmt.allocPrint(allocator, "{s}\n", .{tree_hash});
    defer allocator.free(output);
    try platform_impl.writeStdout(output);
}


