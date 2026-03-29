// Auto-generated from main_common.zig - cmd_commit_tree
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

pub fn cmdCommitTree(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    var tree_hash: ?[]const u8 = null;
    var parents = std.ArrayList([]const u8).init(allocator);
    defer parents.deinit();
    var message: ?[]const u8 = null;
    var read_stdin = true;
    var gpg_sign: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-p")) {
            if (args.next()) |parent| {
                // helpers.Resolve parent to full hash
                const git_dir = helpers.findGitDirectory(allocator, platform_impl) catch {
                    try platform_impl.writeStderr("fatal: not a git repository\n");
                    std.process.exit(128);
                    unreachable;
                };
                defer allocator.free(git_dir);
                const resolved = helpers.resolveCommittish(git_dir, parent, platform_impl, allocator) catch {
                    const msg = try std.fmt.allocPrint(allocator, "fatal: not a valid object name {s}\n", .{parent});
                    defer allocator.free(msg);
                    try platform_impl.writeStderr(msg);
                    std.process.exit(128);
                    unreachable;
                };
                try parents.append(resolved);
            }
        } else if (std.mem.eql(u8, arg, "-m")) {
            message = args.next();
            read_stdin = false;
        } else if (std.mem.eql(u8, arg, "-F")) {
            if (args.next()) |file_path| {
                if (std.mem.eql(u8, file_path, "-")) {
                    // helpers.Read from stdin
                    read_stdin = true;
                } else {
                    message = std.fs.cwd().readFileAlloc(allocator, file_path, 10 * 1024 * 1024) catch null;
                    read_stdin = false;
                }
            }
        } else if (std.mem.startsWith(u8, arg, "-S") or std.mem.startsWith(u8, arg, "--gpg-sign")) {
            gpg_sign = arg;
        } else if (std.mem.eql(u8, arg, "--no-gpg-sign")) {
            gpg_sign = null;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (tree_hash == null) tree_hash = arg;
        }
    }

    if (tree_hash == null) {
        try platform_impl.writeStderr("fatal: must specify a tree object\n");
        std.process.exit(128);
        unreachable;
    }

    // Deduplicate parent hashes (git silently removes duplicates)
    {
        var unique = std.ArrayList([]const u8).init(allocator);
        for (parents.items) |p| {
            var dup = false;
            for (unique.items) |u| {
                if (std.mem.eql(u8, p, u)) {
                    dup = true;
                    break;
                }
            }
            if (!dup) {
                try unique.append(p);
            }
        }
        parents.deinit();
        parents = unique;
    }

    var final_message: []const u8 = undefined;
    var free_message = false;
    if (read_stdin and message == null) {
        final_message = helpers.readStdin(allocator, 10 * 1024 * 1024) catch {
            try platform_impl.writeStderr("fatal: unable to read commit message\n");
            std.process.exit(128);
            unreachable;
        };
        free_message = true;
    } else {
        final_message = message orelse "";
    }
    defer if (free_message) allocator.free(final_message);

    // helpers.Get author/committer from env or config
    const author = helpers.getAuthorString(allocator) catch {
        try platform_impl.writeStderr("fatal: unable to auto-detect author\n");
        std.process.exit(128);
        unreachable;
    };
    defer allocator.free(author);
    const committer = helpers.getCommitterString(allocator) catch {
        try platform_impl.writeStderr("fatal: unable to auto-detect committer\n");
        std.process.exit(128);
        unreachable;
    };
    defer allocator.free(committer);

    const git_dir = helpers.findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository\n");
        std.process.exit(128);
        unreachable;
    };
    defer allocator.free(git_dir);

    // helpers.Resolve tree hash
    const resolved_tree = helpers.resolveCommittish(git_dir, tree_hash.?, platform_impl, allocator) catch {
        const msg = try std.fmt.allocPrint(allocator, "fatal: not a valid object name {s}\n", .{tree_hash.?});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        std.process.exit(128);
        unreachable;
    };
    defer allocator.free(resolved_tree);

    const commit_obj = try objects.createCommitObject(
        resolved_tree,
        parents.items,
        author,
        committer,
        final_message,
        allocator,
    );
    defer commit_obj.deinit(allocator);

    const hash = commit_obj.store(git_dir, platform_impl, allocator) catch {
        try platform_impl.writeStderr("fatal: unable to write commit object\n");
        std.process.exit(128);
        unreachable;
    };
    defer allocator.free(hash);

    const output = try std.fmt.allocPrint(allocator, "{s}\n", .{hash});
    defer allocator.free(output);
    try platform_impl.writeStdout(output);

    // Free parent hashes
    for (parents.items) |p| allocator.free(p);
}

// helpers.Parse a date string into git's internal "epoch timezone" format.