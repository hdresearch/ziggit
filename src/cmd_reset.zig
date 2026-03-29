// Auto-generated from main_common.zig - cmd_reset
// Agents: this file is yours to edit for the commands it contains.

const std = @import("std");
const platform_mod = @import("platform/platform.zig");
const helpers = @import("git_helpers.zig");
const cmd_reflog = @import("cmd_reflog.zig");
const cmd_checkout = @import("cmd_checkout.zig");
const cmd_apply = @import("cmd_apply.zig");

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

pub fn cmdReset(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    if (@import("builtin").target.os.tag == .freestanding) {
        try platform_impl.writeStderr("reset: not supported in freestanding mode\n");
        return;
    }

    // helpers.Find git directory
    const cwd = try platform_impl.fs.getCwd(allocator);
    defer allocator.free(cwd);
    
    const git_path = helpers.findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
        return;
    };
    defer allocator.free(git_path);

    // helpers.Parse arguments
    var reset_mode: enum { soft, mixed, hard, merge_mode } = .mixed; // default is mixed
    var target_ref: ?[]const u8 = null;
    var reset_paths = std.array_list.Managed([]const u8).init(allocator);
    defer reset_paths.deinit();
    var seen_separator = false;
    var quiet = false;
    var intent_to_add = false;

    while (args.next()) |arg| {
        if (seen_separator) {
            try reset_paths.append(arg);
        } else if (std.mem.eql(u8, arg, "--")) {
            seen_separator = true;
        } else if (std.mem.eql(u8, arg, "--end-of-options")) {
            seen_separator = true;
        } else if (std.mem.eql(u8, arg, "--soft")) {
            reset_mode = .soft;
        } else if (std.mem.eql(u8, arg, "--mixed")) {
            reset_mode = .mixed;
        } else if (std.mem.eql(u8, arg, "--hard")) {
            reset_mode = .hard;
        } else if (std.mem.eql(u8, arg, "--merge") or std.mem.eql(u8, arg, "--keep")) {
            reset_mode = .merge_mode;
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            quiet = true;
        } else if (std.mem.eql(u8, arg, "-N") or std.mem.eql(u8, arg, "--no-refresh") or std.mem.eql(u8, arg, "--refresh")) {
            if (std.mem.eql(u8, arg, "-N")) intent_to_add = true;
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--patch")) {
            // cmd_apply.Patch mode not supported
            try platform_impl.writeStderr("fatal: interactive reset not supported\n");
            std.process.exit(1);
            return;
        } else if (std.mem.eql(u8, arg, "--pathspec-from-file") or std.mem.startsWith(u8, arg, "--pathspec-from-file=")) {
            // helpers.Read paths from file
            const file_path = if (std.mem.startsWith(u8, arg, "--pathspec-from-file="))
                arg["--pathspec-from-file=".len..]
            else
                args.next() orelse {
                    try platform_impl.writeStderr("fatal: --pathspec-from-file requires a value\n");
                    std.process.exit(128);
                    return;
                };
            if (std.mem.eql(u8, file_path, "-")) {
                // helpers.Read from stdin
                const stdin_content = helpers.readStdin(allocator, 10 * 1024 * 1024) catch "";
                if (stdin_content.len > 0) {
                    var line_iter = std.mem.splitScalar(u8, stdin_content, '\n');
                    while (line_iter.next()) |line| {
                        const trimmed = std.mem.trimRight(u8, line, "\r");
                        if (trimmed.len > 0) try reset_paths.append(trimmed);
                    }
                }
            } else {
                const content = std.fs.cwd().readFileAlloc(allocator, file_path, 10 * 1024 * 1024) catch {
                    const errmsg = try std.fmt.allocPrint(allocator, "fatal: could not open '{s}' for reading: helpers.No such file or directory\n", .{file_path});
                    defer allocator.free(errmsg);
                    try platform_impl.writeStderr(errmsg);
                    std.process.exit(128);
                    return;
                };
                defer allocator.free(content);
                var line_iter = std.mem.splitScalar(u8, content, '\n');
                while (line_iter.next()) |line| {
                    const trimmed = std.mem.trimRight(u8, line, "\r");
                    if (trimmed.len > 0) try reset_paths.append(trimmed);
                }
            }
        } else if (std.mem.eql(u8, arg, "--pathspec-file-nul") or std.mem.eql(u8, arg, "-z")) {
            // helpers.NUL delimiter mode - handled in conjunction with --pathspec-from-file
            // We'll handle this by re-parsing - for now just accept the flag
        } else if (std.mem.startsWith(u8, arg, "-") and arg.len > 1) {
            // helpers.Strip leading dashes for error message
            var opt_name = arg;
            while (opt_name.len > 0 and opt_name[0] == '-') opt_name = opt_name[1..];
            const msg = try std.fmt.allocPrint(allocator, "error: unknown option `{s}'\n", .{opt_name});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
            return;
        } else if (target_ref == null and reset_paths.items.len == 0) {
            target_ref = arg;
        } else {
            try reset_paths.append(arg);
        }
    }

    // Validate: --soft and --hard/--keep/--merge cannot be used with paths
    if (reset_paths.items.len > 0 or seen_separator) {
        if (reset_mode == .soft) {
            try platform_impl.writeStderr("fatal: Cannot do soft reset with paths.\n");
            std.process.exit(1);
            return;
        }
        if (reset_mode == .hard) {
            try platform_impl.writeStderr("fatal: Cannot do hard reset with paths.\n");
            std.process.exit(1);
            return;
        }
        if (reset_mode == .merge_mode) {
            try platform_impl.writeStderr("fatal: Cannot do merge/keep reset with paths.\n");
            std.process.exit(1);
            return;
        }
    }

    // helpers.Check if helpers.MERGE_HEAD exists - --soft reset should fail with pending merge
    {
        const merge_head_path = try std.fmt.allocPrint(allocator, "{s}/MERGE_HEAD", .{git_path});
        defer allocator.free(merge_head_path);
        const merge_head_exists = if (std.fs.cwd().access(merge_head_path, .{})) |_| true else |_| false;
        if (merge_head_exists and reset_mode == .soft) {
            try platform_impl.writeStderr("fatal: Cannot do a soft reset in the middle of a merge.\n");
            std.process.exit(128);
            return;
        }
    }

    // helpers.Check if we have a worktree (bare repos and inside .git without GIT_WORK_TREE have none)
    const has_worktree = blk: {
        if (std.posix.getenv("GIT_WORK_TREE")) |_| break :blk true;
        // helpers.Check config for bare = true
        const config_path = std.fmt.allocPrint(allocator, "{s}/config", .{git_path}) catch break :blk true;
        defer allocator.free(config_path);
        if (std.fs.cwd().readFileAlloc(allocator, config_path, 1024 * 1024)) |config_content| {
            defer allocator.free(config_content);
            if (std.mem.indexOf(u8, config_content, "bare = true")) |_| break :blk false;
        } else |_| {}
        // helpers.Check if cwd helpers.IS the git dir (we're inside .git dir)
        if (std.mem.eql(u8, cwd, git_path)) break :blk false;
        // helpers.If git_path doesn't end with /.git, we might be inside a bare repo
        if (!std.mem.endsWith(u8, git_path, "/.git") and !std.mem.eql(u8, git_path, ".git")) {
            break :blk false;
        }
        break :blk true;
    };
    
    // helpers.Check config for bare flag
    const is_bare_repo = blk: {
        const bc_path = std.fmt.allocPrint(allocator, "{s}/config", .{git_path}) catch break :blk false;
        defer allocator.free(bc_path);
        if (std.fs.cwd().readFileAlloc(allocator, bc_path, 1024 * 1024)) |bc_content| {
            defer allocator.free(bc_content);
            if (std.mem.indexOf(u8, bc_content, "bare = true")) |_| break :blk true;
        } else |_| {}
        break :blk false;
    };
    
    if (!has_worktree and (reset_mode == .hard or reset_mode == .merge_mode)) {
        try platform_impl.writeStderr("fatal: this operation must be run in a work tree\n");
        std.process.exit(128);
        unreachable;
    }
    if (is_bare_repo and reset_mode == .mixed) {
        try platform_impl.writeStderr("fatal: this operation must be run in a work tree\n");
        std.process.exit(128);
        unreachable;
    }

    // helpers.Track if user explicitly gave a target
    const explicit_target = target_ref != null;
    // helpers.If no target ref specified, default to helpers.HEAD
    if (target_ref == null) {
        target_ref = "HEAD";
    }

    // helpers.Resolve the target commit - use helpers.resolveRevision for full expression support
    const target_hash_or_null: ?[]const u8 = helpers.resolveRevision(git_path, target_ref.?, platform_impl, allocator) catch blk: {
        // helpers.If the target_ref was explicitly provided and doesn't resolve, check if it's a path
        if (explicit_target) {
            // helpers.Check if it's a file/path that exists — treat as path reset
            const repo_root = std.fs.path.dirname(git_path) orelse ".";
            const check_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, target_ref.? }) catch break :blk null;
            defer allocator.free(check_path);
            std.fs.cwd().access(check_path, .{}) catch {
                // helpers.Not a file either — error
                const msg = std.fmt.allocPrint(allocator, "fatal: ambiguous argument '{s}': unknown revision or path not in the working tree.\n", .{target_ref.?}) catch unreachable;
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(128);
                unreachable;
            };
            // It's a path, add to reset_paths and treat as unborn reset
            try reset_paths.append(target_ref.?);
            break :blk null;
        }
        // On an unborn branch, helpers.HEAD doesn't resolve - only OK when user didn't explicitly pass target
        if (!explicit_target and std.mem.eql(u8, target_ref.?, "HEAD")) {
            // helpers.Check if we're on an unborn branch
            const head_path = std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_path}) catch {
                break :blk null;
            };
            defer allocator.free(head_path);
            const head_content = std.fs.cwd().readFileAlloc(allocator, head_path, 4096) catch break :blk null;
            defer allocator.free(head_content);
            const trimmed = std.mem.trimRight(u8, head_content, "\r\n");
            if (std.mem.startsWith(u8, trimmed, "ref: ")) {
                const ref_name = trimmed[5..];
                const ref_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_path, ref_name }) catch break :blk null;
                defer allocator.free(ref_path);
                // helpers.If the ref doesn't exist, we're on an unborn branch
                std.fs.cwd().access(ref_path, .{}) catch {
                    // Unborn branch - reset clears the index
                    break :blk null;
                };
            }
        }
        const msg = try std.fmt.allocPrint(allocator, "fatal: ambiguous argument '{s}': unknown revision or path not in the working tree.\n", .{target_ref.?});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        std.process.exit(128);
        unreachable;
    };
    defer if (target_hash_or_null) |th| allocator.free(th);

    if (target_hash_or_null) |target_hash| {
        // helpers.Get old helpers.HEAD hash for reflog
        const old_head_for_reflog = refs.getCurrentCommit(git_path, platform_impl, allocator) catch null;
        defer if (old_head_for_reflog) |oh| allocator.free(oh);

        // helpers.Update helpers.HEAD to point to the target commit
        try helpers.updateHead(git_path, target_hash, platform_impl, allocator);

        // helpers.Write reflog entries for reset
        {
            const zero_hash = "0000000000000000000000000000000000000000";
            const old_h = old_head_for_reflog orelse zero_hash;
            const subj_for_reflog = helpers.getCommitSubject(target_hash, git_path, platform_impl, allocator) catch try allocator.dupe(u8, "");
            defer allocator.free(subj_for_reflog);
            const reset_reflog_msg = try std.fmt.allocPrint(allocator, "reset: moving to {s}", .{target_ref orelse target_hash});
            defer allocator.free(reset_reflog_msg);
            // helpers.Write helpers.HEAD reflog
            helpers.writeReflogEntry(git_path, "HEAD", old_h, target_hash, reset_reflog_msg, allocator, platform_impl) catch {};
            // helpers.Write branch reflog if on a branch
            const current_branch_for_reflog = refs.getCurrentBranch(git_path, platform_impl, allocator) catch null;
            defer if (current_branch_for_reflog) |cb| allocator.free(cb);
            if (current_branch_for_reflog) |cb| {
                if (!std.mem.eql(u8, cb, "HEAD")) {
                    helpers.writeReflogEntry(git_path, cb, old_h, target_hash, reset_reflog_msg, allocator, platform_impl) catch {};
                }
            }
        }

        // helpers.Handle different reset modes  
        switch (reset_mode) {
            .soft => {
                // helpers.Only update helpers.HEAD, leave index and working tree unchanged
            },
            .mixed => {
                // helpers.Update helpers.HEAD and index, leave working tree unchanged
                resetIndex(git_path, target_hash, platform_impl, allocator) catch {};
            },
            .hard, .merge_mode => {
                // helpers.Clear old tracked files first (using helpers.OLD index), then checkout target tree
                const repo_root_for_clear = std.fs.path.dirname(git_path) orelse ".";
                helpers.clearWorkingDirectory(repo_root_for_clear, allocator, platform_impl) catch {};
                // helpers.Now update index to match target commit
                resetIndex(git_path, target_hash, platform_impl, allocator) catch {};
                // helpers.Checkout the target tree into working directory
                helpers.checkoutCommitTree(git_path, target_hash, allocator, platform_impl) catch {};
            },
        }
        // helpers.Clean up merge/cherry-pick/revert state on hard/merge reset
        if (reset_mode == .hard or reset_mode == .merge_mode) {
            helpers.cleanupMergeState(git_path, allocator);
        }
        // helpers.Output "helpers.HEAD is now at <short-hash> <subject>" for hard reset
        if (reset_mode == .hard or reset_mode == .merge_mode) {
            const short_hash = if (target_hash.len >= 7) target_hash[0..7] else target_hash;
            const subj = helpers.getCommitSubject(target_hash, git_path, platform_impl, allocator) catch "";
            defer if (subj.len > 0) allocator.free(subj);
            const reset_msg = std.fmt.allocPrint(allocator, "helpers.HEAD is now at {s} {s}\n", .{ short_hash, subj }) catch "";
            if (reset_msg.len > 0) {
                defer allocator.free(reset_msg);
                platform_impl.writeStdout(reset_msg) catch {};
            }
        }
    } else {
        // Unborn branch: reset clears the index (and working tree for --hard)
        const index_path = std.fmt.allocPrint(allocator, "{s}/index", .{git_path}) catch return;
        defer allocator.free(index_path);

        if (reset_paths.items.len > 0) {
            // helpers.Reset specific paths: remove them from the index
            helpers.removePathsFromIndex(allocator, index_path, reset_paths.items) catch {};
        } else {
            switch (reset_mode) {
                .soft => {
                    // No-op on unborn branch
                },
                .mixed => {
                    // helpers.Write an empty index (not delete — git writes empty index)
                    helpers.writeEmptyIndex(allocator, index_path) catch {};
                },
                .hard, .merge_mode => {
                    // helpers.Clear the index and remove tracked files
                    const repo_root = std.fs.path.dirname(git_path) orelse ".";
                    helpers.removeTrackedFiles(allocator, index_path, repo_root) catch {};
                    helpers.writeEmptyIndex(allocator, index_path) catch {};
                },
            }
        }
    }
}


pub fn resetIndex(git_path: []const u8, commit_hash: []const u8, platform_impl: *const platform_mod.Platform, allocator: std.mem.Allocator) !void {
    // helpers.Load commit to get tree hash
    const commit_obj = objects.GitObject.load(commit_hash, git_path, platform_impl, allocator) catch return error.InvalidCommitObject;
    defer commit_obj.deinit(allocator);

    var tree_hash: ?[]const u8 = null;
    var lines = std.mem.splitSequence(u8, commit_obj.data, "\n");
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "tree ")) {
            tree_hash = line[5..];
            break;
        }
    }

    if (tree_hash == null) return error.InvalidCommitObject;

    // helpers.Use read-tree to reset the index
    // helpers.Build index entries from the tree
    var entries = std.array_list.Managed(index_mod.IndexEntry).init(allocator);
    defer {
        for (entries.items) |*entry| {
            allocator.free(entry.path);
        }
        entries.deinit();
    }

    try helpers.collectTreeEntries(git_path, tree_hash.?, "", platform_impl, allocator, &entries);

    // helpers.Create and write index
    var idx = index_mod.Index.init(allocator);
    defer idx.deinit();
    for (entries.items) |entry| {
        try idx.entries.append(.{
            .mode = entry.mode,
            .path = try allocator.dupe(u8, entry.path),
            .sha1 = entry.sha1,
            .flags = entry.flags,
            .extended_flags = null,
            .ctime_sec = 0,
            .ctime_nsec = 0,
            .mtime_sec = 0,
            .mtime_nsec = 0,
            .dev = 0,
            .ino = 0,
            .uid = 0,
            .gid = 0,
            .size = 0,
        });
    }
    try idx.save(git_path, platform_impl);
}

// helpers.Recursively collect all blob entries from a tree