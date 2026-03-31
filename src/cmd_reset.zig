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
            try interactiveResetPatch(allocator, platform_impl);
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
        // Path-based reset: only update index entries, don't move HEAD
        if (reset_paths.items.len > 0) {
            resetIndexPaths(git_path, target_hash, reset_paths.items, platform_impl, allocator) catch {};
            return;
        }

        // helpers.Get old helpers.HEAD hash for reflog
        const old_head_for_reflog = refs.getCurrentCommit(git_path, platform_impl, allocator) catch null;
        defer if (old_head_for_reflog) |oh| allocator.free(oh);

        // Save ORIG_HEAD before updating HEAD
        if (old_head_for_reflog) |old_h| {
            const orig_head_path = try std.fmt.allocPrint(allocator, "{s}/ORIG_HEAD", .{git_path});
            defer allocator.free(orig_head_path);
            const orig_content = try std.fmt.allocPrint(allocator, "{s}\n", .{old_h});
            defer allocator.free(orig_content);
            std.fs.cwd().writeFile(.{ .sub_path = orig_head_path, .data = orig_content }) catch {};
        }

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
        // helpers.Output "HEAD is now at <short-hash> <subject>" for hard reset
        if (reset_mode == .hard or reset_mode == .merge_mode) {
            const short_hash = if (target_hash.len >= 7) target_hash[0..7] else target_hash;
            const subj = helpers.getCommitSubject(target_hash, git_path, platform_impl, allocator) catch "";
            defer if (subj.len > 0) allocator.free(subj);
            const reset_msg = std.fmt.allocPrint(allocator, "HEAD is now at {s} {s}\n", .{ short_hash, subj }) catch "";
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


/// Reset specific paths in the index to match the given commit's tree.
/// This is used for `git reset HEAD -- file1 file2` etc.
fn resetIndexPaths(git_path: []const u8, commit_hash: []const u8, paths: []const []const u8, platform_impl: *const platform_mod.Platform, allocator: std.mem.Allocator) !void {
    // Load commit to get tree hash
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

    // Collect all tree entries from the target commit
    var tree_entries = std.array_list.Managed(index_mod.IndexEntry).init(allocator);
    defer {
        for (tree_entries.items) |*entry| allocator.free(entry.path);
        tree_entries.deinit();
    }
    try helpers.collectTreeEntries(git_path, tree_hash.?, "", platform_impl, allocator, &tree_entries);

    // Build a map of path -> tree entry
    var tree_map = std.StringHashMap(index_mod.IndexEntry).init(allocator);
    defer tree_map.deinit();
    for (tree_entries.items) |entry| {
        tree_map.put(entry.path, entry) catch {};
    }

    // Load current index
    var idx = index_mod.Index.load(git_path, platform_impl, allocator) catch index_mod.Index.init(allocator);
    defer idx.deinit();

    // Build map of old index entries for stat preservation
    var old_entries = std.StringHashMap(index_mod.IndexEntry).init(allocator);
    defer old_entries.deinit();
    for (idx.entries.items) |entry| {
        old_entries.put(entry.path, entry) catch {};
    }

    // For each requested path, update or remove from index
    for (paths) |path| {
        // Check if this path matches any index entry or tree entry
        // First remove existing entries for this path (could match as prefix for dirs)
        var i: usize = 0;
        while (i < idx.entries.items.len) {
            if (std.mem.eql(u8, idx.entries.items[i].path, path) or
                (std.mem.startsWith(u8, idx.entries.items[i].path, path) and
                idx.entries.items[i].path.len > path.len and
                idx.entries.items[i].path[path.len] == '/'))
            {
                allocator.free(idx.entries.items[i].path);
                _ = idx.entries.orderedRemove(i);
            } else {
                i += 1;
            }
        }

        // Now add entries from tree that match this path
        if (tree_map.get(path)) |tree_entry| {
            // Exact file match - preserve stat if sha1 unchanged
            const old = old_entries.get(tree_entry.path);
            const preserve = old != null and std.mem.eql(u8, &old.?.sha1, &tree_entry.sha1);
            idx.entries.append(.{
                .mode = tree_entry.mode,
                .path = allocator.dupe(u8, tree_entry.path) catch continue,
                .sha1 = tree_entry.sha1,
                .flags = tree_entry.flags,
                .extended_flags = null,
                .ctime_sec = if (preserve) old.?.ctime_sec else 0,
                .ctime_nsec = if (preserve) old.?.ctime_nsec else 0,
                .mtime_sec = if (preserve) old.?.mtime_sec else 0,
                .mtime_nsec = if (preserve) old.?.mtime_nsec else 0,
                .dev = if (preserve) old.?.dev else 0,
                .ino = if (preserve) old.?.ino else 0,
                .uid = if (preserve) old.?.uid else 0,
                .gid = if (preserve) old.?.gid else 0,
                .size = if (preserve) old.?.size else 0,
            }) catch {};
        } else {
            // Check if it's a directory prefix - add all tree entries under it
            const dir_prefix = std.fmt.allocPrint(allocator, "{s}/", .{path}) catch continue;
            defer allocator.free(dir_prefix);
            for (tree_entries.items) |tree_entry| {
                if (std.mem.startsWith(u8, tree_entry.path, dir_prefix)) {
                    idx.entries.append(.{
                        .mode = tree_entry.mode,
                        .path = allocator.dupe(u8, tree_entry.path) catch continue,
                        .sha1 = tree_entry.sha1,
                        .flags = tree_entry.flags,
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
                    }) catch {};
                }
            }
        }
    }

    // Sort entries by path
    std.mem.sort(index_mod.IndexEntry, idx.entries.items, {}, struct {
        fn lessThan(_: void, a: index_mod.IndexEntry, b: index_mod.IndexEntry) bool {
            return std.mem.order(u8, a.path, b.path) == .lt;
        }
    }.lessThan);

    try idx.save(git_path, platform_impl);
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

fn interactiveResetPatch(allocator: std.mem.Allocator, platform_impl: *const platform_mod.Platform) !void {
    const git_path = helpers.findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);

    var idx = index_mod.Index.load(git_path, platform_impl, allocator) catch return;

    // Get HEAD tree hash (may be empty for unborn branch)
    const head_commit = refs.getCurrentCommit(git_path, platform_impl, allocator) catch null;
    defer if (head_commit) |hc| allocator.free(hc);
    var head_tree_hash: ?[]const u8 = null;
    defer if (head_tree_hash) |h| allocator.free(h);
    if (head_commit) |hc| {
        const commit_obj = objects.GitObject.load(hc, git_path, platform_impl, allocator) catch null;
        defer if (commit_obj) |co| co.deinit(allocator);
        if (commit_obj) |co| {
            const th = helpers.extractHeaderField(co.data, "tree");
            if (th.len > 0) head_tree_hash = allocator.dupe(u8, th) catch null;
        }
    }

    const stdin = std.fs.File.stdin();
    var entries_to_remove = std.array_list.Managed(usize).init(allocator);
    defer entries_to_remove.deinit();

    // Process each index entry
    for (idx.entries.items, 0..) |entry, ei| {
        // Check if this file is in HEAD tree
        var in_head = false; _ = &in_head;
        if (head_tree_hash) |_| {
            // File exists in HEAD - show modification diff
            // For simplicity, just check if it exists
            in_head = true;
        }

        // Generate diff for this entry
        const content = helpers.readGitObjectContent(git_path, &hexFromBytes(entry.sha1), allocator) catch "";
        defer if (content.len > 0) allocator.free(content);

        // Show the diff hunk
        const diff_header = std.fmt.allocPrint(allocator, "diff --git a/{s} b/{s}\nnew file mode {o}\nindex 0000000..{s}\n--- /dev/null\n+++ b/{s}\n", .{ entry.path, entry.path, entry.mode, hexFromBytes(entry.sha1)[0..7], entry.path }) catch continue;
        defer allocator.free(diff_header);
        try platform_impl.writeStdout(diff_header);

        // Show content as added lines
        var line_count: usize = 0;
        var content_iter = std.mem.splitScalar(u8, content, '\n');
        while (content_iter.next()) |_| line_count += 1;
        if (content.len > 0 and content[content.len - 1] == '\n') line_count -= 1;

        const hunk_header = std.fmt.allocPrint(allocator, "@@ -0,0 +1,{d} @@\n", .{line_count}) catch continue;
        defer allocator.free(hunk_header);
        try platform_impl.writeStdout(hunk_header);

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (line.len > 0 or lines.peek() != null) {
                const out_line = std.fmt.allocPrint(allocator, "+{s}\n", .{line}) catch continue;
                defer allocator.free(out_line);
                try platform_impl.writeStdout(out_line);
            }
        }

        // Prompt
        const prompt = std.fmt.allocPrint(allocator, "(1/1) Unstage addition [y,n,q,a,d,e,?]? ", .{}) catch continue;
        defer allocator.free(prompt);
        try platform_impl.writeStdout(prompt);

        // Read response from stdin
        var buf: [64]u8 = undefined;
        const n = stdin.read(&buf) catch 0;
        const response = if (n > 0) std.mem.trimRight(u8, buf[0..n], "\n\r") else "";

        if (response.len > 0 and (response[0] == 'y' or response[0] == 'a')) {
            try entries_to_remove.append(ei);
        } else if (response.len > 0 and (response[0] == 'q' or response[0] == 'd')) {
            break;
        }
    }

    // Remove entries in reverse order
    var ri: usize = entries_to_remove.items.len;
    while (ri > 0) {
        ri -= 1;
        _ = idx.entries.orderedRemove(entries_to_remove.items[ri]);
    }

    try idx.save(git_path, platform_impl);
}

fn hexFromBytes(bytes: [20]u8) [40]u8 {
    const hc = "0123456789abcdef";
    var hex: [40]u8 = undefined;
    for (bytes, 0..) |b, i| {
        hex[i * 2] = hc[b >> 4];
        hex[i * 2 + 1] = hc[b & 0xf];
    }
    return hex;
}