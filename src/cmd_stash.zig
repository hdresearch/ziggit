// Auto-generated from main_common.zig - cmd_stash
// Agents: this file is yours to edit for the commands it contains.

const std = @import("std");
const platform_mod = @import("platform/platform.zig");
const helpers = @import("git_helpers.zig");

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

const ZERO_HASH = "0000000000000000000000000000000000000000";

pub fn nativeCmdStash(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    // Collect all remaining args
    var all_args = std.ArrayList([]const u8).init(allocator);
    defer all_args.deinit();
    while (args.next()) |arg| {
        try all_args.append(arg);
    }

    // Handle top-level flags
    if (all_args.items.len > 0) {
        const first = all_args.items[0];
        if (std.mem.eql(u8, first, "-h")) {
            try platform_impl.writeStdout("usage: git stash list [<log-options>]\n");
            try platform_impl.writeStdout("   or: git stash show [-u | --include-untracked | --only-untracked] [<diff-options>] [<stash>]\n");
            try platform_impl.writeStdout("   or: git stash drop [-q | --quiet] [<stash>]\n");
            try platform_impl.writeStdout("   or: git stash pop [--index] [-q | --quiet] [<stash>]\n");
            try platform_impl.writeStdout("   or: git stash apply [--index] [-q | --quiet] [<stash>]\n");
            try platform_impl.writeStdout("   or: git stash branch <branchname> [<stash>]\n");
            try platform_impl.writeStdout("   or: git stash [push [-p | --patch] [-S | --staged] [-k | --[no-]keep-index] [-q | --quiet]\n");
            try platform_impl.writeStdout("                 [-u | --include-untracked] [-a | --all] [(-m | --message) <message>]\n");
            try platform_impl.writeStdout("                 [--pathspec-from-file=<file> [--pathspec-file-nul]]\n");
            try platform_impl.writeStdout("                 [--] [<pathspec>...]]\n");
            try platform_impl.writeStdout("   or: git stash clear\n");
            try platform_impl.writeStdout("   or: git stash create [<message>]\n");
            try platform_impl.writeStdout("   or: git stash store [(-m | --message) <message>] [-q | --quiet] <commit>\n");
            std.process.exit(129);
        }
        if (std.mem.eql(u8, first, "--invalid-option") or
            (std.mem.startsWith(u8, first, "--") and !std.mem.eql(u8, first, "--include-untracked") and
            !std.mem.eql(u8, first, "--keep-index") and !std.mem.eql(u8, first, "--no-keep-index") and
            !std.mem.eql(u8, first, "--quiet") and !std.mem.eql(u8, first, "--patch") and
            !std.mem.eql(u8, first, "--staged") and !std.mem.eql(u8, first, "--all") and
            !std.mem.eql(u8, first, "--message") and !std.mem.eql(u8, first, "--") and
            !std.mem.eql(u8, first, "--index") and !std.mem.eql(u8, first, "--intent-to-add")))
        {
            try platform_impl.writeStderr("error: unknown option: ");
            try platform_impl.writeStderr(first);
            try platform_impl.writeStderr("\nusage: git stash list [<log-options>]\n   or: git stash show [-u | --include-untracked | --only-untracked] [<diff-options>] [<stash>]\n   or: git stash drop [-q | --quiet] [<stash>]\n   or: git stash pop [--index] [-q | --quiet] [<stash>]\n   or: git stash apply [--index] [-q | --quiet] [<stash>]\n   or: git stash branch <branchname> [<stash>]\n   or: git stash [push [-p | --patch] [-S | --staged] [-k | --[no-]keep-index] [-q | --quiet]\n                 [-u | --include-untracked] [-a | --all] [(-m | --message) <message>]\n                 [--pathspec-from-file=<file> [--pathspec-file-nul]]\n                 [--] [<pathspec>...]]\n   or: git stash clear\n   or: git stash create [<message>]\n   or: git stash store [(-m | --message) <message>] [-q | --quiet] <commit>\n");
            std.process.exit(129);
        }
    }

    const subcmd = if (all_args.items.len > 0) all_args.items[0] else "push";

    // Determine if first arg is a subcommand or an option for push
    const is_subcommand = std.mem.eql(u8, subcmd, "push") or std.mem.eql(u8, subcmd, "save") or
        std.mem.eql(u8, subcmd, "list") or std.mem.eql(u8, subcmd, "show") or
        std.mem.eql(u8, subcmd, "pop") or std.mem.eql(u8, subcmd, "apply") or
        std.mem.eql(u8, subcmd, "drop") or std.mem.eql(u8, subcmd, "clear") or
        std.mem.eql(u8, subcmd, "branch") or std.mem.eql(u8, subcmd, "create") or
        std.mem.eql(u8, subcmd, "store");

    const sub_args = if (is_subcommand and all_args.items.len > 1) all_args.items[1..] else if (!is_subcommand) all_args.items[0..] else all_args.items[0..0];
    const effective_subcmd = if (is_subcommand) subcmd else "push";

    const git_path = helpers.findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);

    if (std.mem.eql(u8, effective_subcmd, "list")) {
        try stashList(allocator, git_path, sub_args, platform_impl);
    } else if (std.mem.eql(u8, effective_subcmd, "show")) {
        try stashShow(allocator, git_path, sub_args, platform_impl);
    } else if (std.mem.eql(u8, effective_subcmd, "push") or std.mem.eql(u8, effective_subcmd, "save")) {
        try stashPush(allocator, git_path, sub_args, effective_subcmd, platform_impl);
    } else if (std.mem.eql(u8, effective_subcmd, "pop")) {
        try stashApply(allocator, git_path, sub_args, true, platform_impl);
    } else if (std.mem.eql(u8, effective_subcmd, "apply")) {
        try stashApply(allocator, git_path, sub_args, false, platform_impl);
    } else if (std.mem.eql(u8, effective_subcmd, "drop")) {
        try stashDrop(allocator, git_path, sub_args, platform_impl);
    } else if (std.mem.eql(u8, effective_subcmd, "clear")) {
        try stashClear(allocator, git_path, platform_impl);
    } else if (std.mem.eql(u8, effective_subcmd, "branch")) {
        try stashBranch(allocator, git_path, sub_args, platform_impl);
    } else if (std.mem.eql(u8, effective_subcmd, "create")) {
        try stashCreate(allocator, git_path, sub_args, platform_impl);
    } else if (std.mem.eql(u8, effective_subcmd, "store")) {
        try stashStore(allocator, git_path, sub_args, platform_impl);
    } else {
        const msg = try std.fmt.allocPrint(allocator, "error: unknown subcommand: {s}\n", .{effective_subcmd});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        std.process.exit(1);
    }
}

/// Get the repository root from git_path
fn getRepoRoot(allocator: std.mem.Allocator, git_path: []const u8) ![]u8 {
    // git_path is typically /path/to/repo/.git
    if (std.fs.path.dirname(git_path)) |parent| {
        return try allocator.dupe(u8, parent);
    }
    return try allocator.dupe(u8, ".");
}

/// Get current HEAD hash
fn getHeadHash(allocator: std.mem.Allocator, git_path: []const u8, platform_impl: *const platform_mod.Platform) ![]u8 {
    const result = try refs.resolveRef(git_path, "HEAD", platform_impl, allocator);
    return result orelse return error.NoHead;
}

/// Get the current branch name
fn getCurrentBranch(allocator: std.mem.Allocator, git_path: []const u8, platform_impl: *const platform_mod.Platform) ![]u8 {
    const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_path});
    defer allocator.free(head_path);
    const content = platform_impl.fs.readFile(allocator, head_path) catch return try allocator.dupe(u8, "HEAD");
    defer allocator.free(content);
    const trimmed = std.mem.trimRight(u8, content, "\n\r ");
    if (std.mem.startsWith(u8, trimmed, "ref: refs/heads/")) {
        return try allocator.dupe(u8, trimmed["ref: refs/heads/".len..]);
    }
    return try allocator.dupe(u8, "HEAD");
}

/// Get committer/author identity string
fn getIdentityString(allocator: std.mem.Allocator) ![]u8 {
    return helpers.getCommitterString(allocator) catch {
        const ts = std.time.timestamp();
        return try std.fmt.allocPrint(allocator, "User <user@example.com> {d} +0000", .{ts});
    };
}

/// Write a tree object from the current index
fn writeTreeFromCurrentIndex(allocator: std.mem.Allocator, git_path: []const u8, platform_impl: *const platform_mod.Platform) ![]u8 {
    const repo_root = try getRepoRoot(allocator, git_path);
    defer allocator.free(repo_root);
    var idx = index_mod.Index.load(git_path, platform_impl, allocator) catch
        index_mod.Index.init(allocator);
    defer idx.deinit();
    return try helpers.writeTreeFromIndex(allocator, &idx, git_path, platform_impl);
}

/// Create a stash commit with the proper structure:
/// - Parent 0: HEAD commit
/// - Parent 1: index tree commit
/// - Parent 2 (optional): untracked files tree commit
/// The stash commit itself has the working tree state
fn createStashCommit(
    allocator: std.mem.Allocator,
    git_path: []const u8,
    head_hash: []const u8,
    message: []const u8,
    include_untracked: bool,
    include_all: bool,
    keep_index: bool,
    pathspecs: []const []const u8,
    platform_impl: *const platform_mod.Platform,
) !?[]u8 {
    _ = keep_index;
    const repo_root = try getRepoRoot(allocator, git_path);
    defer allocator.free(repo_root);

    // Read current index
    var idx = index_mod.Index.load(git_path, platform_impl, allocator) catch
        index_mod.Index.init(allocator);
    defer idx.deinit();

    // Step 1: Create index tree (i-tree) from current staged state
    const index_tree_hash = try helpers.writeTreeFromIndex(allocator, &idx, git_path, platform_impl);
    defer allocator.free(index_tree_hash);

    // Check if there are any changes to stash
    const head_tree_hash = helpers.getCommitTree(git_path, head_hash, allocator, platform_impl) catch {
        return null;
    };
    defer allocator.free(head_tree_hash);

    // Step 2: Create a working tree version of the index by updating blobs for modified files
    var wt_idx = index_mod.Index.load(git_path, platform_impl, allocator) catch
        index_mod.Index.init(allocator);
    defer wt_idx.deinit();

    var has_changes = false;
    var has_pathspec_match = false;

    // Update index entries with working tree content
    for (wt_idx.entries.items) |*entry| {
        // If pathspecs given, filter
        if (pathspecs.len > 0) {
            var matches = false;
            for (pathspecs) |ps| {
                if (helpers.matchPathspec(entry.path, ps)) {
                    matches = true;
                    break;
                }
            }
            if (!matches) continue;
            has_pathspec_match = true;
        }

        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, entry.path });
        defer allocator.free(full_path);

        if (std.fs.cwd().openFile(full_path, .{})) |file| {
            defer file.close();
            const content = file.readToEndAlloc(allocator, 100 * 1024 * 1024) catch continue;
            defer allocator.free(content);

            // Create blob from working tree content
            const blob_obj = objects.GitObject.init(.blob, content);
            const new_hash_hex = try blob_obj.store(git_path, platform_impl, allocator);
            defer allocator.free(new_hash_hex);

            // Check if it differs from index
            var old_hex: [40]u8 = undefined;
            _ = std.fmt.bufPrint(&old_hex, "{}", .{std.fmt.fmtSliceHexLower(&entry.sha1)}) catch continue;
            if (!std.mem.eql(u8, &old_hex, new_hash_hex)) {
                has_changes = true;
                // Update entry hash
                var hash_bytes: [20]u8 = undefined;
                for (0..20) |i| {
                    hash_bytes[i] = std.fmt.parseInt(u8, new_hash_hex[i * 2 .. i * 2 + 2], 16) catch 0;
                }
                entry.sha1 = hash_bytes;

                // Update file size
                const stat = file.stat() catch continue;
                entry.size = @truncate(stat.size);
            }
        } else |_| {
            // File deleted in working tree - still a change
            has_changes = true;
        }
    }

    // Also check if index differs from HEAD
    if (!has_changes) {
        if (!std.mem.eql(u8, index_tree_hash, head_tree_hash)) {
            has_changes = true;
        }
    }

    if (pathspecs.len > 0 and !has_pathspec_match) {
        return null;
    }

    if (!has_changes and !include_untracked) {
        return null;
    }

    // Write the working tree as a tree object
    const wt_tree_hash = try helpers.writeTreeFromIndex(allocator, &wt_idx, git_path, platform_impl);
    defer allocator.free(wt_tree_hash);

    // If no changes at all (working tree == index == HEAD)
    if (std.mem.eql(u8, wt_tree_hash, head_tree_hash) and std.mem.eql(u8, index_tree_hash, head_tree_hash) and !include_untracked) {
        return null;
    }

    const identity = try getIdentityString(allocator);
    defer allocator.free(identity);

    // Step 3: Create index commit (parent: HEAD)
    const index_parents = [_][]const u8{head_hash};
    const index_commit_msg = try std.fmt.allocPrint(allocator, "index on {s}", .{message});
    defer allocator.free(index_commit_msg);
    const index_commit_obj = try objects.createCommitObject(index_tree_hash, &index_parents, identity, identity, index_commit_msg, allocator);
    defer index_commit_obj.deinit(allocator);
    const index_commit_hash = try index_commit_obj.store(git_path, platform_impl, allocator);
    defer allocator.free(index_commit_hash);

    // Step 4: Optionally create untracked files commit
    var untracked_commit_hash: ?[]u8 = null;
    defer if (untracked_commit_hash) |h| allocator.free(h);

    if (include_untracked or include_all) {
        if (try createUntrackedTree(allocator, git_path, repo_root, &idx, include_all, platform_impl)) |ut_tree_hash| {
            defer allocator.free(ut_tree_hash);
            const ut_parents = [_][]const u8{};
            const ut_msg = "untracked files on " ++ "";
            const ut_commit_msg = try std.fmt.allocPrint(allocator, "untracked files on {s}", .{message});
            defer allocator.free(ut_commit_msg);
            _ = ut_msg;
            const ut_commit_obj = try objects.createCommitObject(ut_tree_hash, &ut_parents, identity, identity, ut_commit_msg, allocator);
            defer ut_commit_obj.deinit(allocator);
            untracked_commit_hash = try ut_commit_obj.store(git_path, platform_impl, allocator);
        }
    }

    // Step 5: Create stash commit (parents: HEAD, index_commit, [untracked_commit])
    var parents = std.ArrayList([]const u8).init(allocator);
    defer parents.deinit();
    try parents.append(head_hash);
    try parents.append(index_commit_hash);
    if (untracked_commit_hash) |h| {
        try parents.append(h);
    }

    const stash_msg = try std.fmt.allocPrint(allocator, "WIP on {s}", .{message});
    defer allocator.free(stash_msg);

    const stash_commit_obj = try objects.createCommitObject(wt_tree_hash, parents.items, identity, identity, stash_msg, allocator);
    defer stash_commit_obj.deinit(allocator);
    const stash_hash = try stash_commit_obj.store(git_path, platform_impl, allocator);

    return stash_hash;
}

/// Create tree object for untracked files
fn createUntrackedTree(
    allocator: std.mem.Allocator,
    git_path: []const u8,
    repo_root: []const u8,
    idx: *const index_mod.Index,
    include_ignored: bool,
    platform_impl: *const platform_mod.Platform,
) !?[]u8 {
    var gitignore = gitignore_mod.GitIgnore.init(allocator);
    defer gitignore.deinit();
    // Try to load .gitignore from repo root
    const gitignore_path = try std.fmt.allocPrint(allocator, "{s}/.gitignore", .{repo_root});
    defer allocator.free(gitignore_path);
    if (gitignore_mod.GitIgnore.loadFromFile(allocator, gitignore_path, platform_impl)) |loaded| {
        gitignore.deinit();
        gitignore = loaded;
    } else |_| {}

    var untracked = try helpers.findUntrackedFiles(allocator, repo_root, idx, &gitignore, platform_impl);
    defer {
        for (untracked.items) |item| allocator.free(item);
        untracked.deinit();
    }

    if (untracked.items.len == 0) return null;

    // Create a temporary index with just untracked files
    var ut_idx = index_mod.Index.init(allocator);
    defer ut_idx.deinit();

    for (untracked.items) |upath| {
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, upath });
        defer allocator.free(full_path);

        // Check if ignored
        if (!include_ignored and gitignore.isIgnored(upath)) continue;

        if (std.fs.cwd().openFile(full_path, .{})) |file| {
            defer file.close();
            const content = file.readToEndAlloc(allocator, 100 * 1024 * 1024) catch continue;
            defer allocator.free(content);

            const blob_obj = objects.GitObject.init(.blob, content);
            const hash_hex = try blob_obj.store(git_path, platform_impl, allocator);
            defer allocator.free(hash_hex);

            // Parse hex hash to bytes
            var hash_bytes: [20]u8 = undefined;
            for (0..20) |i| {
                hash_bytes[i] = std.fmt.parseInt(u8, hash_hex[i * 2 .. i * 2 + 2], 16) catch 0;
            }

            const stat = file.stat() catch continue;
            const entry = index_mod.IndexEntry{
                .ctime_sec = 0,
                .ctime_nsec = 0,
                .mtime_sec = 0,
                .mtime_nsec = 0,
                .dev = 0,
                .ino = 0,
                .mode = 0o100644,
                .uid = 0,
                .gid = 0,
                .size = @truncate(stat.size),
                .sha1 = hash_bytes,
                .flags = @truncate(upath.len),
                .extended_flags = null,
                .path = try allocator.dupe(u8, upath),
            };
            ut_idx.entries.append(entry) catch {};
        } else |_| {}
    }

    if (ut_idx.entries.items.len == 0) return null;
    return try helpers.writeTreeFromIndex(allocator, &ut_idx, git_path, platform_impl);
}

/// stash push/save implementation
fn stashPush(
    allocator: std.mem.Allocator,
    git_path: []const u8,
    sub_args: []const []const u8,
    subcmd: []const u8,
    platform_impl: *const platform_mod.Platform,
) !void {
    var message: ?[]const u8 = null;
    var include_untracked = false;
    var include_all = false;
    var keep_index = false;
    var quiet = false;
    var pathspecs = std.ArrayList([]const u8).init(allocator);
    defer pathspecs.deinit();
    var after_dashdash = false;
    var is_patch = false;
    var is_staged = false;

    // Parse push-specific args
    var i: usize = 0;
    while (i < sub_args.len) : (i += 1) {
        const arg = sub_args[i];
        if (after_dashdash) {
            try pathspecs.append(arg);
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            after_dashdash = true;
        } else if (std.mem.eql(u8, arg, "-h")) {
            try platform_impl.writeStdout("usage: git stash [push [-p | --patch] [-S | --staged] [-k | --[no-]keep-index] [-q | --quiet]\n");
            try platform_impl.writeStdout("                 [-u | --include-untracked] [-a | --all] [(-m | --message) <message>]\n");
            try platform_impl.writeStdout("                 [--pathspec-from-file=<file> [--pathspec-file-nul]]\n");
            try platform_impl.writeStdout("                 [--] [<pathspec>...]]\n");
            std.process.exit(129);
        } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--message")) {
            i += 1;
            if (i < sub_args.len) {
                message = sub_args[i];
            }
        } else if (std.mem.eql(u8, arg, "-u") or std.mem.eql(u8, arg, "--include-untracked")) {
            include_untracked = true;
        } else if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--all")) {
            include_all = true;
        } else if (std.mem.eql(u8, arg, "-k") or std.mem.eql(u8, arg, "--keep-index")) {
            keep_index = true;
        } else if (std.mem.eql(u8, arg, "--no-keep-index")) {
            keep_index = false;
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            quiet = true;
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--patch")) {
            is_patch = true;
        } else if (std.mem.eql(u8, arg, "-S") or std.mem.eql(u8, arg, "--staged")) {
            is_staged = true;
        } else if (std.mem.eql(u8, arg, "--intent-to-add")) {
            // handled silently
        } else if (std.mem.startsWith(u8, arg, "--invalid-option") or
            (std.mem.startsWith(u8, arg, "-") and arg.len > 1 and !std.mem.startsWith(u8, arg, "--")))
        {
            // Check for unknown short options
            const is_known_short = std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "-u") or
                std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "-k") or
                std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "-S");
            if (!is_known_short) {
                const err_msg = try std.fmt.allocPrint(allocator, "error: unknown option: {s}\nusage: git stash [push [-p | --patch] [-S | --staged] [-k | --[no-]keep-index] [-q | --quiet]\n                 [-u | --include-untracked] [-a | --all] [(-m | --message) <message>]\n                 [--pathspec-from-file=<file> [--pathspec-file-nul]]\n                 [--] [<pathspec>...]]\n", .{arg});
                defer allocator.free(err_msg);
                try platform_impl.writeStderr(err_msg);
                std.process.exit(129);
            }
        } else if (std.mem.startsWith(u8, arg, "--")) {
            const err_msg = try std.fmt.allocPrint(allocator, "error: unknown option: {s}\nusage: git stash [push [-p | --patch] [-S | --staged] [-k | --[no-]keep-index] [-q | --quiet]\n                 [-u | --include-untracked] [-a | --all] [(-m | --message) <message>]\n                 [--pathspec-from-file=<file> [--pathspec-file-nul]]\n                 [--] [<pathspec>...]]\n", .{arg});
            defer allocator.free(err_msg);
            try platform_impl.writeStderr(err_msg);
            std.process.exit(129);
        } else {
            // For "save" subcommand, remaining args are the message
            if (std.mem.eql(u8, subcmd, "save")) {
                // Collect remaining args as message
                var msg_parts = std.ArrayList(u8).init(allocator);
                defer msg_parts.deinit();
                try msg_parts.appendSlice(arg);
                var j = i + 1;
                while (j < sub_args.len) : (j += 1) {
                    try msg_parts.append(' ');
                    try msg_parts.appendSlice(sub_args[j]);
                }
                message = try msg_parts.toOwnedSlice();
                break;
            } else {
                try pathspecs.append(arg);
            }
        }
    }

    if (is_patch) {
        try platform_impl.writeStderr("error: stash --patch is not supported in ziggit\n");
        std.process.exit(1);
    }

    if (is_staged) {
        // TODO: implement --staged
    }

    // Get HEAD
    const head_hash = getHeadHash(allocator, git_path, platform_impl) catch {
        try platform_impl.writeStderr("fatal: bad default revision 'HEAD'\nYou do not have the initial commit yet\n");
        std.process.exit(128);
    };
    defer allocator.free(head_hash);

    // Get branch info for message
    const branch_name = try getCurrentBranch(allocator, git_path, platform_impl);
    defer allocator.free(branch_name);

    // Build default message if not provided
    const default_msg = blk: {
        // Get HEAD commit subject
        const head_data = helpers.readGitObjectContent(git_path, head_hash, allocator) catch break :blk try std.fmt.allocPrint(allocator, "{s}: {s}", .{ branch_name, head_hash[0..7] });
        defer allocator.free(head_data);
        // Find commit message (after double newline)
        if (std.mem.indexOf(u8, head_data, "\n\n")) |pos| {
            const msg_start = head_data[pos + 2 ..];
            // Get first line
            const end = std.mem.indexOfScalar(u8, msg_start, '\n') orelse msg_start.len;
            break :blk try std.fmt.allocPrint(allocator, "{s}: {s}", .{ branch_name, msg_start[0..end] });
        }
        break :blk try std.fmt.allocPrint(allocator, "{s}: {s}", .{ branch_name, head_hash[0..7] });
    };
    defer allocator.free(default_msg);

    const stash_message = message orelse default_msg;

    // Create the stash commit
    const stash_hash = try createStashCommit(
        allocator,
        git_path,
        head_hash,
        stash_message,
        include_untracked,
        include_all,
        keep_index,
        pathspecs.items,
        platform_impl,
    ) orelse {
        try platform_impl.writeStderr("No local changes to save\n");
        std.process.exit(1);
    };
    defer allocator.free(stash_hash);

    // Store the stash
    const old_stash_opt = refs.resolveRef(git_path, "refs/stash", platform_impl, allocator) catch null;
    const old_stash = old_stash_opt orelse try allocator.dupe(u8, ZERO_HASH);
    defer allocator.free(old_stash);

    try refs.updateRef(git_path, "refs/stash", stash_hash, platform_impl, allocator);

    // Write reflog entry
    const reflog_msg = try std.fmt.allocPrint(allocator, "WIP on {s}", .{stash_message});
    defer allocator.free(reflog_msg);
    helpers.writeReflogEntry(git_path, "refs/stash", old_stash, stash_hash, reflog_msg, allocator, platform_impl) catch {};

    // Reset working tree to HEAD (unless pathspec)
    if (pathspecs.items.len == 0) {
        // Reset index to HEAD
        helpers.updateIndexFromTree(git_path, head_hash, allocator, platform_impl) catch {};

        // Checkout HEAD tree to working directory
        const repo_root = try getRepoRoot(allocator, git_path);
        defer allocator.free(repo_root);

        // Reset working tree files
        resetWorkingTreeToHead(allocator, git_path, repo_root, head_hash, platform_impl) catch {};

        // If keep_index, re-apply the index state
        if (keep_index) {
            helpers.updateIndexFromTree(git_path, stash_hash, allocator, platform_impl) catch {};
            // Actually, for keep-index, we need to restore the staged index
            // Re-read the index commit's tree
            const index_tree = blk: {
                // stash^2 is the index commit
                const stash_data = helpers.readGitObjectContent(git_path, stash_hash, allocator) catch break :blk null;
                defer allocator.free(stash_data);
                // Parse to find second parent
                var lines_iter = std.mem.splitScalar(u8, stash_data, '\n');
                _ = lines_iter.next(); // tree line
                _ = lines_iter.next(); // parent 1
                if (lines_iter.next()) |parent2_line| {
                    if (std.mem.startsWith(u8, parent2_line, "parent ")) {
                        const p2_hash = parent2_line[7..];
                        // Get tree from that commit
                        break :blk helpers.getCommitTree(git_path, p2_hash, allocator, platform_impl) catch null;
                    }
                }
                break :blk null;
            };
            if (index_tree) |it| {
                defer allocator.free(it);
                helpers.updateIndexFromTree(git_path, it, allocator, platform_impl) catch {};
            }
        }

        // Remove untracked files if they were stashed
        if (include_untracked or include_all) {
            removeUntrackedFiles(allocator, git_path, repo_root, platform_impl) catch {};
        }
    } else {
        // Pathspec mode: only reset matching files
        resetPathspecFiles(allocator, git_path, head_hash, pathspecs.items, platform_impl) catch {};
    }

    if (!quiet) {
        const saved_msg = try std.fmt.allocPrint(allocator, "Saved working directory and index state WIP on {s}\n", .{stash_message});
        defer allocator.free(saved_msg);
        try platform_impl.writeStderr(saved_msg);
    }
}

/// Reset working tree files to match HEAD
fn resetWorkingTreeToHead(
    allocator: std.mem.Allocator,
    git_path: []const u8,
    repo_root: []const u8,
    head_hash: []const u8,
    platform_impl: *const platform_mod.Platform,
) !void {
    const head_tree = try helpers.getCommitTree(git_path, head_hash, allocator, platform_impl);
    defer allocator.free(head_tree);

    // Load the tree and checkout files
    const tree_obj = try objects.GitObject.load(head_tree, git_path, platform_impl, allocator);
    defer tree_obj.deinit(allocator);

    try helpers.checkoutTreeRecursive(git_path, tree_obj.data, repo_root, "", allocator, platform_impl);
}

/// Reset files matching pathspecs to HEAD state
fn resetPathspecFiles(
    allocator: std.mem.Allocator,
    git_path: []const u8,
    _: []const u8,
    pathspecs: []const []const u8,
    platform_impl: *const platform_mod.Platform,
) !void {
    const repo_root = try getRepoRoot(allocator, git_path);
    defer allocator.free(repo_root);

    // Read HEAD index state and restore matching files
    var idx = index_mod.Index.load(git_path, platform_impl, allocator) catch return;
    defer idx.deinit();

    for (idx.entries.items) |entry| {
        var matches = false;
        for (pathspecs) |ps| {
            if (helpers.matchPathspec(entry.path, ps)) {
                matches = true;
                break;
            }
        }
        if (!matches) continue;

        // Restore file from index
        var hash_hex: [40]u8 = undefined;
        _ = std.fmt.bufPrint(&hash_hex, "{}", .{std.fmt.fmtSliceHexLower(&entry.sha1)}) catch continue;
        const content = helpers.readBlobContent(allocator, git_path, &hash_hex, platform_impl) catch continue;
        defer allocator.free(content);

        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, entry.path });
        defer allocator.free(full_path);
        if (std.fs.path.dirname(full_path)) |parent| {
            std.fs.cwd().makePath(parent) catch {};
        }
        platform_impl.fs.writeFile(full_path, content) catch {};
    }
}

/// Remove untracked files from working tree
fn removeUntrackedFiles(
    allocator: std.mem.Allocator,
    git_path: []const u8,
    repo_root: []const u8,
    platform_impl: *const platform_mod.Platform,
) !void {
    var idx = index_mod.Index.load(git_path, platform_impl, allocator) catch return;
    defer idx.deinit();
    var gitignore = gitignore_mod.GitIgnore.init(allocator);
    defer gitignore.deinit();
    const gi_path = try std.fmt.allocPrint(allocator, "{s}/.gitignore", .{repo_root});
    defer allocator.free(gi_path);
    if (gitignore_mod.GitIgnore.loadFromFile(allocator, gi_path, platform_impl)) |loaded| {
        gitignore.deinit();
        gitignore = loaded;
    } else |_| {}

    var untracked = helpers.findUntrackedFiles(allocator, repo_root, &idx, &gitignore, platform_impl) catch return;
    defer {
        for (untracked.items) |item| allocator.free(item);
        untracked.deinit();
    }

    for (untracked.items) |upath| {
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, upath });
        defer allocator.free(full_path);
        std.fs.cwd().deleteFile(full_path) catch {};
    }
}

/// stash list implementation
fn stashList(
    allocator: std.mem.Allocator,
    git_path: []const u8,
    _: []const []const u8,
    platform_impl: *const platform_mod.Platform,
) !void {
    const reflog_path = try std.fmt.allocPrint(allocator, "{s}/logs/refs/stash", .{git_path});
    defer allocator.free(reflog_path);

    const content = platform_impl.fs.readFile(allocator, reflog_path) catch return;
    defer allocator.free(content);

    // Parse reflog entries - newest first
    var lines = std.ArrayList([]const u8).init(allocator);
    defer lines.deinit();
    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |line| {
        if (line.len > 0) try lines.append(line);
    }

    // Output in reverse order (newest first)
    var idx: usize = lines.items.len;
    while (idx > 0) {
        idx -= 1;
        const line = lines.items[idx];
        const stash_num = lines.items.len - 1 - idx;
        // Parse reflog line: old_hash new_hash identity\tmessage
        if (std.mem.indexOf(u8, line, "\t")) |tab_pos| {
            const msg = line[tab_pos + 1 ..];
            const entry_str = try std.fmt.allocPrint(allocator, "stash@{{{d}}}: {s}\n", .{ stash_num, msg });
            defer allocator.free(entry_str);
            try platform_impl.writeStdout(entry_str);
        }
    }
}

/// stash show implementation
fn stashShow(
    allocator: std.mem.Allocator,
    git_path: []const u8,
    sub_args: []const []const u8,
    platform_impl: *const platform_mod.Platform,
) !void {
    var stash_ref: []const u8 = "stash@{0}";
    var show_patch = false;
    var show_stat = true;
    var show_include_untracked = false;

    for (sub_args) |arg| {
        if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--patch")) {
            show_patch = true;
            show_stat = false;
        } else if (std.mem.eql(u8, arg, "--stat")) {
            show_stat = true;
        } else if (std.mem.eql(u8, arg, "-u") or std.mem.eql(u8, arg, "--include-untracked")) {
            show_include_untracked = true;
        } else if (std.mem.startsWith(u8, arg, "stash@{")) {
            stash_ref = arg;
        } else if (std.mem.eql(u8, arg, "--")) {
            // ignore
        }
    }

    // Resolve stash ref
    const stash_hash = resolveStashRef(allocator, git_path, stash_ref, platform_impl) catch {
        const msg = try std.fmt.allocPrint(allocator, "fatal: bad revision '{s}'\n", .{stash_ref});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        std.process.exit(128);
    };
    defer allocator.free(stash_hash);

    // Get parent (HEAD at time of stash)
    const parent_hash = getStashParent(allocator, git_path, stash_hash, platform_impl) catch {
        try platform_impl.writeStderr("fatal: bad stash reference\n");
        std.process.exit(128);
    };
    defer allocator.free(parent_hash);

    // Generate diff between parent and stash
    if (show_stat) {
        var diff_entries = std.ArrayList(helpers.DiffStatEntry).init(allocator);
        defer {
            for (diff_entries.items) |*e| {
                allocator.free(e.path);
            }
            diff_entries.deinit();
        }

        const parent_tree = helpers.getCommitTree(git_path, parent_hash, allocator, platform_impl) catch {
            return;
        };
        defer allocator.free(parent_tree);
        const stash_tree = helpers.getCommitTree(git_path, stash_hash, allocator, platform_impl) catch {
            return;
        };
        defer allocator.free(stash_tree);

        _ = helpers.collectRefDiffEntries("HEAD", &index_mod.Index.init(allocator), ".", git_path, platform_impl, allocator, &diff_entries, false) catch false;

        // Use the proper diff stat generation between two trees
        try helpers.formatDiffStat(diff_entries.items, platform_impl, allocator);
    }

    if (show_patch) {
        const diff_output = helpers.generateDiffBetweenCommits(git_path, parent_hash, stash_hash, allocator, platform_impl) catch {
            return;
        };
        defer allocator.free(diff_output);
        try platform_impl.writeStdout(diff_output);
    }
}

/// Resolve a stash reference like "stash@{0}" to a commit hash
fn resolveStashRef(
    allocator: std.mem.Allocator,
    git_path: []const u8,
    stash_ref: []const u8,
    platform_impl: *const platform_mod.Platform,
) ![]u8 {
    // Parse stash@{N}
    var n: u32 = 0;
    if (std.mem.startsWith(u8, stash_ref, "stash@{")) {
        const end = std.mem.indexOfScalar(u8, stash_ref, '}') orelse return error.InvalidRef;
        n = std.fmt.parseInt(u32, stash_ref[7..end], 10) catch return error.InvalidRef;
    } else if (std.mem.eql(u8, stash_ref, "stash")) {
        n = 0;
    } else {
        return error.InvalidRef;
    }

    // Read reflog
    const reflog_path = try std.fmt.allocPrint(allocator, "{s}/logs/refs/stash", .{git_path});
    defer allocator.free(reflog_path);
    const content = platform_impl.fs.readFile(allocator, reflog_path) catch return error.NoStash;
    defer allocator.free(content);

    // Count lines
    var line_count: u32 = 0;
    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |line| {
        if (line.len > 0) line_count += 1;
    }

    if (n >= line_count) return error.InvalidRef;

    // Get the (line_count - 1 - n)th entry
    const target_idx = line_count - 1 - n;
    var current_idx: u32 = 0;
    var line_iter2 = std.mem.splitScalar(u8, content, '\n');
    while (line_iter2.next()) |line| {
        if (line.len < 41) continue;
        if (current_idx == target_idx) {
            // new_hash is at position 41..81
            if (line.len >= 81) {
                return try allocator.dupe(u8, line[41..81]);
            }
        }
        current_idx += 1;
    }

    return error.InvalidRef;
}

/// Get the first parent of a stash commit (the HEAD at time of stash)
fn getStashParent(
    allocator: std.mem.Allocator,
    git_path: []const u8,
    stash_hash: []const u8,
    _: *const platform_mod.Platform,
) ![]u8 {
    const data = try helpers.readGitObjectContent(git_path, stash_hash, allocator);
    defer allocator.free(data);

    var lines_iter = std.mem.splitScalar(u8, data, '\n');
    _ = lines_iter.next(); // tree line
    if (lines_iter.next()) |parent_line| {
        if (std.mem.startsWith(u8, parent_line, "parent ")) {
            return try allocator.dupe(u8, parent_line[7..]);
        }
    }
    return error.NoParent;
}

/// stash apply/pop implementation
fn stashApply(
    allocator: std.mem.Allocator,
    git_path: []const u8,
    sub_args: []const []const u8,
    is_pop: bool,
    platform_impl: *const platform_mod.Platform,
) !void {
    var stash_ref: []const u8 = "stash@{0}";
    var restore_index = false;
    var quiet = false;

    for (sub_args) |arg| {
        if (std.mem.eql(u8, arg, "--index")) {
            restore_index = true;
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            quiet = true;
        } else if (std.mem.startsWith(u8, arg, "stash@{") or std.mem.eql(u8, arg, "stash")) {
            stash_ref = arg;
        }
    }

    // Resolve stash ref
    const stash_hash = resolveStashRef(allocator, git_path, stash_ref, platform_impl) catch {
        const msg = try std.fmt.allocPrint(allocator, "error: {s} is not a valid reference\n", .{stash_ref});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        std.process.exit(1);
    };
    defer allocator.free(stash_hash);

    const repo_root = try getRepoRoot(allocator, git_path);
    defer allocator.free(repo_root);

    // Get stash commit info
    const stash_data = helpers.readGitObjectContent(git_path, stash_hash, allocator) catch {
        try platform_impl.writeStderr("error: could not read stash commit\n");
        std.process.exit(1);
    };
    defer allocator.free(stash_data);

    // Parse parents
    var stash_tree: ?[]u8 = null;
    var parent_hash: ?[]u8 = null;
    var index_commit_hash: ?[]u8 = null;
    var untracked_commit_hash: ?[]u8 = null;
    var parent_count: u32 = 0;

    var lines_iter = std.mem.splitScalar(u8, stash_data, '\n');
    while (lines_iter.next()) |line| {
        if (std.mem.startsWith(u8, line, "tree ")) {
            stash_tree = try allocator.dupe(u8, line[5..]);
        } else if (std.mem.startsWith(u8, line, "parent ")) {
            if (parent_count == 0) {
                parent_hash = try allocator.dupe(u8, line[7..]);
            } else if (parent_count == 1) {
                index_commit_hash = try allocator.dupe(u8, line[7..]);
            } else if (parent_count == 2) {
                untracked_commit_hash = try allocator.dupe(u8, line[7..]);
            }
            parent_count += 1;
        } else if (line.len == 0) {
            break;
        }
    }

    defer {
        if (stash_tree) |h| allocator.free(h);
        if (parent_hash) |h| allocator.free(h);
        if (index_commit_hash) |h| allocator.free(h);
        if (untracked_commit_hash) |h| allocator.free(h);
    }

    const st = stash_tree orelse {
        try platform_impl.writeStderr("error: invalid stash commit\n");
        std.process.exit(1);
    };
    const ph = parent_hash orelse {
        try platform_impl.writeStderr("error: invalid stash commit\n");
        std.process.exit(1);
    };

    // Get current HEAD
    const current_head = getHeadHash(allocator, git_path, platform_impl) catch {
        try platform_impl.writeStderr("error: could not read HEAD\n");
        std.process.exit(1);
    };
    defer allocator.free(current_head);

    // Apply untracked files first (if any)
    if (untracked_commit_hash) |ut_hash| {
        applyUntrackedFiles(allocator, git_path, repo_root, ut_hash, platform_impl) catch {};
    }

    // Apply working tree changes using 3-way merge
    // Base: parent (stash^), ours: current HEAD, theirs: stash working tree
    const base_tree = helpers.getCommitTree(git_path, ph, allocator, platform_impl) catch {
        try platform_impl.writeStderr("error: could not resolve stash base tree\n");
        std.process.exit(1);
    };
    defer allocator.free(base_tree);

    const current_tree = helpers.getCommitTree(git_path, current_head, allocator, platform_impl) catch {
        try platform_impl.writeStderr("error: could not resolve current tree\n");
        std.process.exit(1);
    };
    defer allocator.free(current_tree);

    // Perform merge
    const had_conflicts = helpers.mergeTreesWithConflicts(git_path, base_tree, current_tree, st, allocator, platform_impl) catch false;

    // If --index, also apply index changes
    if (restore_index and index_commit_hash != null) {
        const idx_tree = helpers.getCommitTree(git_path, index_commit_hash.?, allocator, platform_impl) catch null;
        if (idx_tree) |it| {
            defer allocator.free(it);
            // Apply index state
            helpers.updateIndexFromTree(git_path, it, allocator, platform_impl) catch {};
        }
    }

    // Checkout the merged files to working directory
    if (!had_conflicts) {
        // Read merged index and checkout files
        var idx = index_mod.Index.load(git_path, platform_impl, allocator) catch index_mod.Index.init(allocator);
        defer idx.deinit();

        for (idx.entries.items) |entry| {
            if ((entry.flags >> 12) & 0x3 != 0) continue; // Skip conflict entries
            var hash_hex: [40]u8 = undefined;
            _ = std.fmt.bufPrint(&hash_hex, "{}", .{std.fmt.fmtSliceHexLower(&entry.sha1)}) catch continue;
            const blob_content = helpers.readBlobContent(allocator, git_path, &hash_hex, platform_impl) catch continue;
            defer allocator.free(blob_content);

            const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, entry.path });
            defer allocator.free(full_path);
            if (std.fs.path.dirname(full_path)) |parent| {
                std.fs.cwd().makePath(parent) catch {};
            }
            platform_impl.fs.writeFile(full_path, blob_content) catch {};
        }
    }

    // If pop, drop the stash entry
    if (is_pop and !had_conflicts) {
        stashDropByIndex(allocator, git_path, 0, platform_impl) catch {};
    }

    if (had_conflicts) {
        if (!quiet) {
            try platform_impl.writeStdout("CONFLICT (content): Merge conflict\n");
        }
        if (is_pop) {
            // Don't drop on conflict
            try platform_impl.writeStderr("The stash entry is kept in case you need it again.\n");
        }
        std.process.exit(1);
    }

    if (!quiet) {
        const head_branch = getCurrentBranch(allocator, git_path, platform_impl) catch try allocator.dupe(u8, "HEAD");
        defer allocator.free(head_branch);
        const msg = try std.fmt.allocPrint(allocator, "On branch {s}\n", .{head_branch});
        defer allocator.free(msg);
        try platform_impl.writeStdout(msg);
    }
}

/// Apply untracked files from stash^3
fn applyUntrackedFiles(
    allocator: std.mem.Allocator,
    git_path: []const u8,
    repo_root: []const u8,
    ut_commit_hash: []const u8,
    platform_impl: *const platform_mod.Platform,
) !void {
    const tree_hash = try helpers.getCommitTree(git_path, ut_commit_hash, allocator, platform_impl);
    defer allocator.free(tree_hash);

    const tree_obj = try objects.GitObject.load(tree_hash, git_path, platform_impl, allocator);
    defer tree_obj.deinit(allocator);

    try checkoutUntrackedTree(allocator, git_path, tree_obj.data, repo_root, "", platform_impl);
}

/// Recursively checkout untracked files from a tree
fn checkoutUntrackedTree(
    allocator: std.mem.Allocator,
    git_path: []const u8,
    tree_data: []const u8,
    repo_root: []const u8,
    prefix: []const u8,
    platform_impl: *const platform_mod.Platform,
) !void {
    var pos: usize = 0;
    while (pos < tree_data.len) {
        // Parse mode
        const space_pos = std.mem.indexOfScalarPos(u8, tree_data, pos, ' ') orelse break;
        const mode_str = tree_data[pos..space_pos];

        // Parse name
        const null_pos = std.mem.indexOfScalarPos(u8, tree_data, space_pos + 1, 0) orelse break;
        const name = tree_data[space_pos + 1 .. null_pos];

        // Parse hash (20 bytes)
        if (null_pos + 21 > tree_data.len) break;
        const hash_bytes = tree_data[null_pos + 1 .. null_pos + 21];
        var hash_hex: [40]u8 = undefined;
        _ = std.fmt.bufPrint(&hash_hex, "{}", .{std.fmt.fmtSliceHexLower(hash_bytes)}) catch break;

        pos = null_pos + 21;

        const full_name = if (prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, name })
        else
            try allocator.dupe(u8, name);
        defer allocator.free(full_name);

        if (std.mem.eql(u8, mode_str, "40000")) {
            // Directory - recurse
            const subtree = objects.GitObject.load(&hash_hex, git_path, platform_impl, allocator) catch continue;
            defer subtree.deinit(allocator);
            try checkoutUntrackedTree(allocator, git_path, subtree.data, repo_root, full_name, platform_impl);
        } else {
            // File - write it
            const content = helpers.readBlobContent(allocator, git_path, &hash_hex, platform_impl) catch continue;
            defer allocator.free(content);
            const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, full_name });
            defer allocator.free(file_path);
            if (std.fs.path.dirname(file_path)) |parent| {
                std.fs.cwd().makePath(parent) catch {};
            }
            platform_impl.fs.writeFile(file_path, content) catch {};
        }
    }
}

/// stash drop implementation
fn stashDrop(
    allocator: std.mem.Allocator,
    git_path: []const u8,
    sub_args: []const []const u8,
    platform_impl: *const platform_mod.Platform,
) !void {
    var quiet = false;
    var stash_ref: []const u8 = "stash@{0}";

    for (sub_args) |arg| {
        if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            quiet = true;
        } else if (std.mem.startsWith(u8, arg, "stash@{")) {
            stash_ref = arg;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            // Extra options cause complaint
            const msg = try std.fmt.allocPrint(allocator, "error: Too many revisions specified: {s}\n", .{arg});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(1);
        }
    }

    // Parse index
    var n: u32 = 0;
    if (std.mem.startsWith(u8, stash_ref, "stash@{")) {
        const end = std.mem.indexOfScalar(u8, stash_ref, '}') orelse {
            try platform_impl.writeStderr("error: invalid stash reference\n");
            std.process.exit(1);
        };
        n = std.fmt.parseInt(u32, stash_ref[7..end], 10) catch {
            try platform_impl.writeStderr("error: invalid stash reference\n");
            std.process.exit(1);
        };
    }

    // Get the hash before dropping for message
    const stash_hash = resolveStashRef(allocator, git_path, stash_ref, platform_impl) catch {
        const msg = try std.fmt.allocPrint(allocator, "error: {s} is not a valid reference\n", .{stash_ref});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        std.process.exit(1);
    };
    defer allocator.free(stash_hash);

    try stashDropByIndex(allocator, git_path, n, platform_impl);

    if (!quiet) {
        const msg = try std.fmt.allocPrint(allocator, "Dropped {s} ({s})\n", .{ stash_ref, stash_hash });
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
    }
}

/// Drop stash entry by index
fn stashDropByIndex(
    allocator: std.mem.Allocator,
    git_path: []const u8,
    n: u32,
    platform_impl: *const platform_mod.Platform,
) !void {
    const reflog_path = try std.fmt.allocPrint(allocator, "{s}/logs/refs/stash", .{git_path});
    defer allocator.free(reflog_path);

    const content = platform_impl.fs.readFile(allocator, reflog_path) catch return error.NoStash;
    defer allocator.free(content);

    // Parse lines
    var lines = std.ArrayList([]const u8).init(allocator);
    defer lines.deinit();
    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |line| {
        if (line.len > 0) try lines.append(line);
    }

    if (lines.items.len == 0) return error.NoStash;

    // n=0 means the most recent (last line)
    const target_line = if (n < lines.items.len) lines.items.len - 1 - n else return error.InvalidRef;

    // Remove the line
    _ = lines.orderedRemove(target_line);

    // Write back
    if (lines.items.len == 0) {
        // No more stash entries - remove files
        std.fs.cwd().deleteFile(reflog_path) catch {};
        const stash_ref_path = try std.fmt.allocPrint(allocator, "{s}/refs/stash", .{git_path});
        defer allocator.free(stash_ref_path);
        std.fs.cwd().deleteFile(stash_ref_path) catch {};
    } else {
        // Rebuild reflog
        var new_content = std.ArrayList(u8).init(allocator);
        defer new_content.deinit();
        for (lines.items) |line| {
            try new_content.appendSlice(line);
            try new_content.append('\n');
        }
        platform_impl.fs.writeFile(reflog_path, new_content.items) catch {};

        // Update refs/stash to point to newest entry
        const last_line = lines.items[lines.items.len - 1];
        if (last_line.len >= 81) {
            const new_hash = last_line[41..81];
            const stash_ref_path = try std.fmt.allocPrint(allocator, "{s}/refs/stash", .{git_path});
            defer allocator.free(stash_ref_path);
            platform_impl.fs.writeFile(stash_ref_path, new_hash) catch {};
        }
    }
}

/// stash clear implementation
fn stashClear(
    allocator: std.mem.Allocator,
    git_path: []const u8,
    platform_impl: *const platform_mod.Platform,
) !void {
    _ = platform_impl;
    const stash_ref = try std.fmt.allocPrint(allocator, "{s}/refs/stash", .{git_path});
    defer allocator.free(stash_ref);
    std.fs.cwd().deleteFile(stash_ref) catch {};
    const stash_log = try std.fmt.allocPrint(allocator, "{s}/logs/refs/stash", .{git_path});
    defer allocator.free(stash_log);
    std.fs.cwd().deleteFile(stash_log) catch {};
}

/// stash branch implementation
fn stashBranch(
    allocator: std.mem.Allocator,
    git_path: []const u8,
    sub_args: []const []const u8,
    platform_impl: *const platform_mod.Platform,
) !void {
    if (sub_args.len < 1) {
        try platform_impl.writeStderr("usage: git stash branch <branchname> [<stash>]\n");
        std.process.exit(129);
    }

    const branch_name = sub_args[0];
    const stash_ref = if (sub_args.len > 1) sub_args[1] else "stash@{0}";

    // Resolve stash
    const stash_hash = resolveStashRef(allocator, git_path, stash_ref, platform_impl) catch {
        const msg = try std.fmt.allocPrint(allocator, "error: {s} is not a valid reference\n", .{stash_ref});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        std.process.exit(1);
    };
    defer allocator.free(stash_hash);

    // Get stash parent (HEAD at stash time)
    const parent_hash = getStashParent(allocator, git_path, stash_hash, platform_impl) catch {
        try platform_impl.writeStderr("error: invalid stash\n");
        std.process.exit(1);
    };
    defer allocator.free(parent_hash);

    // Create branch at the stash parent
    const branch_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{branch_name});
    defer allocator.free(branch_ref);
    refs.updateRef(git_path, branch_ref, parent_hash, platform_impl, allocator) catch {
        try platform_impl.writeStderr("error: could not create branch\n");
        std.process.exit(1);
    };

    // Checkout the branch
    helpers.checkoutCommitTree(git_path, parent_hash, allocator, platform_impl) catch {};
    // Update HEAD to point to branch
    const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_path});
    defer allocator.free(head_path);
    const head_content = try std.fmt.allocPrint(allocator, "ref: {s}\n", .{branch_ref});
    defer allocator.free(head_content);
    platform_impl.fs.writeFile(head_path, head_content) catch {};

    // Apply the stash with --index
    const apply_args = [_][]const u8{ "--index", stash_ref };
    stashApply(allocator, git_path, &apply_args, false, platform_impl) catch {};

    // Drop the stash
    stashDropByIndex(allocator, git_path, 0, platform_impl) catch {};
}

/// stash create implementation (just creates the commit, doesn't update ref)
fn stashCreate(
    allocator: std.mem.Allocator,
    git_path: []const u8,
    sub_args: []const []const u8,
    platform_impl: *const platform_mod.Platform,
) !void {
    const head_hash = getHeadHash(allocator, git_path, platform_impl) catch {
        std.process.exit(1);
    };
    defer allocator.free(head_hash);

    const branch_name = try getCurrentBranch(allocator, git_path, platform_impl);
    defer allocator.free(branch_name);

    const message = if (sub_args.len > 0) sub_args[0] else blk: {
        const head_data = helpers.readGitObjectContent(git_path, head_hash, allocator) catch break :blk try std.fmt.allocPrint(allocator, "{s}: {s}", .{ branch_name, head_hash[0..7] });
        defer allocator.free(head_data);
        if (std.mem.indexOf(u8, head_data, "\n\n")) |pos| {
            const msg_start = head_data[pos + 2 ..];
            const end = std.mem.indexOfScalar(u8, msg_start, '\n') orelse msg_start.len;
            break :blk try std.fmt.allocPrint(allocator, "{s}: {s}", .{ branch_name, msg_start[0..end] });
        }
        break :blk try std.fmt.allocPrint(allocator, "{s}: {s}", .{ branch_name, head_hash[0..7] });
    };
    _ = message;

    // For now just create and output the hash
    const empty_pathspecs = [_][]const u8{};
    const stash_hash = createStashCommit(allocator, git_path, head_hash, if (sub_args.len > 0) sub_args[0] else "created", false, false, false, &empty_pathspecs, platform_impl) catch {
        std.process.exit(1);
    } orelse {
        // No changes
        std.process.exit(1);
    };
    defer allocator.free(stash_hash);

    const output = try std.fmt.allocPrint(allocator, "{s}\n", .{stash_hash});
    defer allocator.free(output);
    try platform_impl.writeStdout(output);
}

/// stash store implementation
fn stashStore(
    allocator: std.mem.Allocator,
    git_path: []const u8,
    sub_args: []const []const u8,
    platform_impl: *const platform_mod.Platform,
) !void {
    var message: ?[]const u8 = null;
    var quiet = false;
    var commit_hash: ?[]const u8 = null;

    var i: usize = 0;
    while (i < sub_args.len) : (i += 1) {
        const arg = sub_args[i];
        if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--message")) {
            i += 1;
            if (i < sub_args.len) message = sub_args[i];
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            quiet = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            commit_hash = arg;
        }
    }
    const hash = commit_hash orelse {
        try platform_impl.writeStderr("error: git stash store requires one <commit> argument\n");
        std.process.exit(1);
    };

    // Validate it's a commit
    _ = helpers.readGitObjectContent(git_path, hash, allocator) catch {
        const msg = try std.fmt.allocPrint(allocator, "error: {s} is not a valid object\n", .{hash});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        std.process.exit(1);
    };

    // Update refs/stash
    const old_stash_opt2 = refs.resolveRef(git_path, "refs/stash", platform_impl, allocator) catch null;
    const old_stash2 = old_stash_opt2 orelse try allocator.dupe(u8, ZERO_HASH);
    defer allocator.free(old_stash2);

    refs.updateRef(git_path, "refs/stash", hash, platform_impl, allocator) catch {
        try platform_impl.writeStderr("error: could not update refs/stash\n");
        std.process.exit(1);
    };

    const reflog_msg = message orelse "store";
    helpers.writeReflogEntry(git_path, "refs/stash", old_stash2, hash, reflog_msg, allocator, platform_impl) catch {};
}
