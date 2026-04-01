// Auto-generated from main_common.zig - cmd_stash
// Agents: this file is yours to edit for the commands it contains.

const std = @import("std");
const platform_mod = @import("platform/platform.zig");
const helpers = @import("git_helpers.zig");
const hooks = @import("git/hooks.zig");
const succinct_mod = @import("succinct.zig");

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

const stash_usage = "usage: git stash list [<log-options>]\n   or: git stash show [-u | --include-untracked | --only-untracked] [<diff-options>] [<stash>]\n   or: git stash drop [-q | --quiet] [<stash>]\n   or: git stash pop [--index] [-q | --quiet] [<stash>]\n   or: git stash apply [--index] [-q | --quiet] [<stash>]\n   or: git stash branch <branchname> [<stash>]\n   or: git stash [push [-p | --patch] [-S | --staged] [-k | --[no-]keep-index] [-q | --quiet]\n                 [-u | --include-untracked] [-a | --all] [(-m | --message) <message>]\n                 [--pathspec-from-file=<file> [--pathspec-file-nul]]\n                 [--] [<pathspec>...]]\n   or: git stash clear\n   or: git stash create [<message>]\n   or: git stash store [(-m | --message) <message>] [-q | --quiet] <commit>\n";

const push_usage = "usage: git stash [push [-p | --patch] [-S | --staged] [-k | --[no-]keep-index] [-q | --quiet]\n                 [-u | --include-untracked] [-a | --all] [(-m | --message) <message>]\n                 [--pathspec-from-file=<file> [--pathspec-file-nul]]\n                 [--] [<pathspec>...]]\n";

pub fn nativeCmdStash(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    var all_args = std.array_list.Managed([]const u8).init(allocator);
    defer all_args.deinit();
    while (args.next()) |arg| {
        try all_args.append(arg);
    }

    // Handle top-level -h
    if (all_args.items.len > 0 and std.mem.eql(u8, all_args.items[0], "-h")) {
        try platform_impl.writeStdout(stash_usage);
        std.process.exit(129);
    }

    // Handle top-level unknown options (before subcommand dispatch)
    if (all_args.items.len > 0) {
        const first = all_args.items[0];
        if (std.mem.startsWith(u8, first, "--") and !isKnownPushOption(first) and
            !std.mem.eql(u8, first, "--"))
        {
            try platform_impl.writeStderr("error: unknown option: ");
            try platform_impl.writeStderr(first);
            try platform_impl.writeStderr("\n");
            try platform_impl.writeStderr(stash_usage);
            std.process.exit(129);
        }
    }

    const subcmd = if (all_args.items.len > 0) all_args.items[0] else "push";

    const is_subcommand = isStashSubcommand(subcmd);

    const sub_args = if (is_subcommand and all_args.items.len > 1)
        all_args.items[1..]
    else if (!is_subcommand)
        all_args.items[0..]
    else
        all_args.items[0..0];
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
        try stashPush(allocator, git_path, sub_args, effective_subcmd, is_subcommand, platform_impl);
    } else if (std.mem.eql(u8, effective_subcmd, "pop")) {
        try stashApply(allocator, git_path, sub_args, true, platform_impl);
    } else if (std.mem.eql(u8, effective_subcmd, "apply")) {
        try stashApply(allocator, git_path, sub_args, false, platform_impl);
    } else if (std.mem.eql(u8, effective_subcmd, "drop")) {
        try stashDrop(allocator, git_path, sub_args, platform_impl);
    } else if (std.mem.eql(u8, effective_subcmd, "clear")) {
        try stashClear(allocator, git_path);
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

fn isIntentToAdd(entry: *const index_mod.IndexEntry) bool {
    if (entry.extended_flags) |ef| {
        return (ef & 0x2000) != 0;
    }
    return false;
}

fn isStashSubcommand(s: []const u8) bool {
    const cmds = [_][]const u8{
        "push", "save", "list", "show", "pop", "apply",
        "drop", "clear", "branch", "create", "store",
    };
    for (cmds) |c| {
        if (std.mem.eql(u8, s, c)) return true;
    }
    return false;
}

fn isKnownPushOption(s: []const u8) bool {
    const opts = [_][]const u8{
        "--include-untracked", "--keep-index", "--no-keep-index",
        "--quiet", "--patch", "--staged", "--all", "--message",
        "--index", "--intent-to-add",
    };
    for (opts) |o| {
        if (std.mem.eql(u8, s, o)) return true;
    }
    // --message=...
    if (std.mem.startsWith(u8, s, "--message=")) return true;
    return false;
}

// ============= Helpers =============

fn getRepoRoot(allocator: std.mem.Allocator, git_path: []const u8) ![]u8 {
    if (std.fs.path.dirname(git_path)) |parent| {
        return try allocator.dupe(u8, parent);
    }
    return try allocator.dupe(u8, ".");
}

fn getHeadHash(allocator: std.mem.Allocator, git_path: []const u8, platform_impl: *const platform_mod.Platform) ![]u8 {
    const result = try refs.resolveRef(git_path, "HEAD", platform_impl, allocator);
    return result orelse return error.NoHead;
}

fn getCurrentBranch(allocator: std.mem.Allocator, git_path: []const u8, platform_impl: *const platform_mod.Platform) ![]u8 {
    const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_path});
    defer allocator.free(head_path);
    const content = platform_impl.fs.readFile(allocator, head_path) catch return try allocator.dupe(u8, "(no branch)");
    defer allocator.free(content);
    const trimmed = std.mem.trimRight(u8, content, "\n\r ");
    if (std.mem.startsWith(u8, trimmed, "ref: refs/heads/")) {
        return try allocator.dupe(u8, trimmed["ref: refs/heads/".len..]);
    }
    // Detached HEAD
    return try allocator.dupe(u8, "(no branch)");
}

fn getStashIdentityFallback(allocator: std.mem.Allocator) ![]u8 {
    const ts = std.time.timestamp();
    return try std.fmt.allocPrint(allocator, "git stash <git@stash> {d} +0000", .{ts});
}

fn hasRealIdentity() bool {
    // Check if any identity source is configured
    if (std.posix.getenv("GIT_COMMITTER_NAME") != null) return true;
    if (std.posix.getenv("GIT_COMMITTER_EMAIL") != null) return true;
    if (std.posix.getenv("GIT_AUTHOR_NAME") != null) return true;
    if (std.posix.getenv("GIT_AUTHOR_EMAIL") != null) return true;
    // Check git config
    const git_dir = helpers.findGitDir() catch return false;
    if (helpers.getConfigValueByKey(git_dir, "user.name", std.heap.page_allocator)) |v| {
        std.heap.page_allocator.free(v);
        return true;
    }
    if (helpers.getConfigValueByKey(git_dir, "user.email", std.heap.page_allocator)) |v| {
        std.heap.page_allocator.free(v);
        return true;
    }
    return false;
}

fn getIdentityString(allocator: std.mem.Allocator) ![]u8 {
    if (!hasRealIdentity()) return getStashIdentityFallback(allocator);
    return helpers.getCommitterString(allocator) catch getStashIdentityFallback(allocator);
}

fn getAuthorString(allocator: std.mem.Allocator) ![]u8 {
    if (!hasRealIdentity()) return getStashIdentityFallback(allocator);
    return helpers.getAuthorString(allocator) catch getStashIdentityFallback(allocator);
}

/// Get HEAD commit's subject line
fn getHeadSubject(allocator: std.mem.Allocator, git_path: []const u8, head_hash: []const u8) ![]u8 {
    const head_data = helpers.readGitObjectContent(git_path, head_hash, allocator) catch
        return try std.fmt.allocPrint(allocator, "{s}", .{head_hash[0..7]});
    defer allocator.free(head_data);
    if (std.mem.indexOf(u8, head_data, "\n\n")) |pos| {
        const msg_start = head_data[pos + 2 ..];
        const end = std.mem.indexOfScalar(u8, msg_start, '\n') orelse msg_start.len;
        return try allocator.dupe(u8, msg_start[0..end]);
    }
    return try std.fmt.allocPrint(allocator, "{s}", .{head_hash[0..7]});
}

/// Parse a -m option that might have value attached like -mfoo
fn parseShortOptionValue(arg: []const u8, prefix: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, arg, prefix) and arg.len > prefix.len) {
        return arg[prefix.len..];
    }
    return null;
}

/// Resolve a stash reference to a commit hash.
/// Accepts: stash@{N}, stash, or a raw commit hash (40 hex chars)
fn resolveStashRef(
    allocator: std.mem.Allocator,
    git_path: []const u8,
    stash_ref: []const u8,
    platform_impl: *const platform_mod.Platform,
) ![]u8 {
    // Try stash@{N}
    if (std.mem.startsWith(u8, stash_ref, "stash@{")) {
        const end = std.mem.indexOfScalar(u8, stash_ref, '}') orelse return error.InvalidRef;
        const inner = stash_ref[7..end];
        // Try as number
        if (std.fmt.parseInt(u32, inner, 10)) |n| {
            return resolveStashByIndex(allocator, git_path, n, platform_impl);
        } else |_| {
            // Could be a date - not supported yet
            return error.InvalidRef;
        }
    }
    if (std.mem.eql(u8, stash_ref, "stash")) {
        return resolveStashByIndex(allocator, git_path, 0, platform_impl);
    }

    // Try as a plain number
    if (std.fmt.parseInt(u32, stash_ref, 10)) |n| {
        return resolveStashByIndex(allocator, git_path, n, platform_impl);
    } else |_| {}

    // Try as commit hash
    if (stash_ref.len == 40) {
        for (stash_ref) |c| {
            if (!std.ascii.isHex(c)) return error.InvalidRef;
        }
        // Verify it exists
        _ = helpers.readGitObjectContent(git_path, stash_ref, allocator) catch return error.InvalidRef;
        return try allocator.dupe(u8, stash_ref);
    }

    return error.InvalidRef;
}

fn resolveStashByIndex(
    allocator: std.mem.Allocator,
    git_path: []const u8,
    n: u32,
    platform_impl: *const platform_mod.Platform,
) ![]u8 {
    _ = platform_impl;
    const reflog_path = try std.fmt.allocPrint(allocator, "{s}/logs/refs/stash", .{git_path});
    defer allocator.free(reflog_path);
    const content = std.fs.cwd().readFileAlloc(allocator, reflog_path, 10 * 1024 * 1024) catch return error.NoStash;
    defer allocator.free(content);

    var line_count: u32 = 0;
    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |line| {
        if (line.len > 0) line_count += 1;
    }

    if (n >= line_count) return error.InvalidRef;

    const target_idx = line_count - 1 - n;
    var current_idx: u32 = 0;
    var line_iter2 = std.mem.splitScalar(u8, content, '\n');
    while (line_iter2.next()) |line| {
        if (line.len < 41) continue;
        if (current_idx == target_idx) {
            if (line.len >= 81) {
                return try allocator.dupe(u8, line[41..81]);
            }
        }
        current_idx += 1;
    }

    return error.InvalidRef;
}

fn getStashParent(allocator: std.mem.Allocator, git_path: []const u8, stash_hash: []const u8) ![]u8 {
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

/// Parse stash commit to get tree, parents
const StashInfo = struct {
    stash_tree: []u8,
    parent_hash: []u8,
    index_commit: ?[]u8,
    untracked_commit: ?[]u8,

    fn deinit(self: *StashInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.stash_tree);
        allocator.free(self.parent_hash);
        if (self.index_commit) |h| allocator.free(h);
        if (self.untracked_commit) |h| allocator.free(h);
    }
};

fn parseStashCommit(allocator: std.mem.Allocator, git_path: []const u8, stash_hash: []const u8) !StashInfo {
    const data = try helpers.readGitObjectContent(git_path, stash_hash, allocator);
    defer allocator.free(data);

    var stash_tree: ?[]u8 = null;
    var parents = std.array_list.Managed([]u8).init(allocator);
    defer parents.deinit();

    var lines_iter = std.mem.splitScalar(u8, data, '\n');
    while (lines_iter.next()) |line| {
        if (std.mem.startsWith(u8, line, "tree ")) {
            stash_tree = try allocator.dupe(u8, line[5..]);
        } else if (std.mem.startsWith(u8, line, "parent ")) {
            try parents.append(try allocator.dupe(u8, line[7..]));
        } else if (line.len == 0) {
            break;
        }
    }

    return StashInfo{
        .stash_tree = stash_tree orelse return error.InvalidStash,
        .parent_hash = if (parents.items.len > 0) parents.items[0] else return error.InvalidStash,
        .index_commit = if (parents.items.len > 1) parents.items[1] else null,
        .untracked_commit = if (parents.items.len > 2) parents.items[2] else null,
    };
}

// ============= Create Stash Commit =============

fn createStashCommit(
    allocator: std.mem.Allocator,
    git_path: []const u8,
    head_hash: []const u8,
    branch_name: []const u8,
    user_message: ?[]const u8,
    include_untracked: bool,
    include_all: bool,
    pathspecs: []const []const u8,
    platform_impl: *const platform_mod.Platform,
    staged_only_flag: bool,
) !?[]u8 {
    const repo_root = try getRepoRoot(allocator, git_path);
    defer allocator.free(repo_root);

    // Read current index
    var idx = index_mod.Index.load(git_path, platform_impl, allocator) catch
        index_mod.Index.init(allocator);
    defer idx.deinit();

    // Remove intent-to-add entries before computing tree hash (they don't represent real staged content)
    {
        var i: usize = 0;
        while (i < idx.entries.items.len) {
            if (isIntentToAdd(&idx.entries.items[i])) {
                idx.entries.items[i].deinit(allocator);
                _ = idx.entries.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    // Create index tree from current staged state
    const index_tree_hash = try helpers.writeTreeFromIndex(allocator, &idx, git_path, platform_impl);
    defer allocator.free(index_tree_hash);

    // Get HEAD tree for comparison
    const head_tree_hash = helpers.getCommitTree(git_path, head_hash, allocator, platform_impl) catch
        return null;
    defer allocator.free(head_tree_hash);

    // Build working tree index (copy of current index + working tree modifications)
    var wt_idx = index_mod.Index.load(git_path, platform_impl, allocator) catch
        index_mod.Index.init(allocator);
    defer wt_idx.deinit();

    var has_wt_changes = false;
    const has_index_changes = !std.mem.eql(u8, index_tree_hash, head_tree_hash);

    // Remove intent-to-add entries from working tree index too
    {
        var i: usize = 0;
        while (i < wt_idx.entries.items.len) {
            if (isIntentToAdd(&wt_idx.entries.items[i])) {
                wt_idx.entries.items[i].deinit(allocator);
                _ = wt_idx.entries.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    // Update wt_idx entries with working tree content
    for (wt_idx.entries.items) |*entry| {
        if (pathspecs.len > 0) {
            var matches = false;
            for (pathspecs) |ps| {
                if (helpers.matchPathspec(entry.path, ps)) {
                    matches = true;
                    break;
                }
            }
            if (!matches) continue;
        }

        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, entry.path });
        defer allocator.free(full_path);

        if (std.fs.cwd().openFile(full_path, .{})) |file| {
            defer file.close();
            const content = file.readToEndAlloc(allocator, 100 * 1024 * 1024) catch continue;
            defer allocator.free(content);

            const blob_obj = objects.GitObject.init(.blob, content);
            const new_hash_hex = try blob_obj.store(git_path, platform_impl, allocator);
            defer allocator.free(new_hash_hex);

            var old_hex: [40]u8 = undefined;
            _ = std.fmt.bufPrint(&old_hex, "{x}", .{&entry.sha1}) catch continue;
            if (!std.mem.eql(u8, &old_hex, new_hash_hex)) {
                has_wt_changes = true;
                var hash_bytes: [20]u8 = undefined;
                for (0..20) |i| {
                    hash_bytes[i] = std.fmt.parseInt(u8, new_hash_hex[i * 2 .. i * 2 + 2], 16) catch 0;
                }
                entry.sha1 = hash_bytes;
                const stat = file.stat() catch continue;
                entry.size = @truncate(stat.size);
            }
        } else |_| {
            has_wt_changes = true;
        }
    }

    // Also check for files that are in HEAD tree but not in index (e.g., git rm'd) and still exist on disk
    // These need to be included in the working tree tree to capture the full working tree state
    {
        var head_tree_files = std.StringHashMap([]const u8).init(allocator);
        defer freeStringMap(&head_tree_files, allocator);
        const ht_hash = helpers.getCommitTree(git_path, head_hash, allocator, platform_impl) catch null;
        if (ht_hash) |hth| {
            defer allocator.free(hth);
            collectTreeFilesRecursive(allocator, git_path, hth, "", &head_tree_files, platform_impl) catch {};
        }

        var ht_iter = head_tree_files.iterator();
        while (ht_iter.next()) |ht_entry| {
            const ht_path = ht_entry.key_ptr.*;
            // Check if this file is already in wt_idx
            var in_wt_idx = false;
            for (wt_idx.entries.items) |e| {
                if (std.mem.eql(u8, e.path, ht_path)) {
                    in_wt_idx = true;
                    break;
                }
            }
            if (in_wt_idx) continue;

            // File is in HEAD but not in index - check if it exists on disk
            const disk_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, ht_path }) catch continue;
            defer allocator.free(disk_path);

            if (std.fs.cwd().openFile(disk_path, .{})) |file| {
                defer file.close();
                const content = file.readToEndAlloc(allocator, 100 * 1024 * 1024) catch continue;
                defer allocator.free(content);

                const blob_obj = objects.GitObject.init(.blob, content);
                const new_hash_hex = blob_obj.store(git_path, platform_impl, allocator) catch continue;
                defer allocator.free(new_hash_hex);

                var hash_bytes: [20]u8 = undefined;
                for (0..20) |bi| {
                    hash_bytes[bi] = std.fmt.parseInt(u8, new_hash_hex[bi * 2 .. bi * 2 + 2], 16) catch 0;
                }

                const stat = file.stat() catch continue;
                const path_copy = allocator.dupe(u8, ht_path) catch continue;
                const path_len: u16 = if (ht_path.len >= 0xFFF) 0xFFF else @intCast(ht_path.len);
                const new_entry = index_mod.IndexEntry{
                    .ctime_sec = @intCast(@divFloor(stat.ctime, 1_000_000_000)),
                    .ctime_nsec = @intCast(@mod(stat.ctime, 1_000_000_000)),
                    .mtime_sec = @intCast(@divFloor(stat.mtime, 1_000_000_000)),
                    .mtime_nsec = @intCast(@mod(stat.mtime, 1_000_000_000)),
                    .dev = 0,
                    .ino = 0,
                    .mode = 0o100644,
                    .uid = 0,
                    .gid = 0,
                    .size = @truncate(stat.size),
                    .sha1 = hash_bytes,
                    .flags = path_len,
                    .extended_flags = null,
                    .path = path_copy,
                };
                wt_idx.entries.append(new_entry) catch continue;
                has_wt_changes = true;
            } else |_| {
                // File doesn't exist on disk - it was truly deleted, which is a working tree change
                // The wt_idx not having it is correct (file deleted)
                has_wt_changes = true;
            }
        }

        // Re-sort after adding entries
        std.sort.block(index_mod.IndexEntry, wt_idx.entries.items, {}, struct {
            fn lessThan(context: void, lhs: index_mod.IndexEntry, rhs: index_mod.IndexEntry) bool {
                _ = context;
                return std.mem.lessThan(u8, lhs.path, rhs.path);
            }
        }.lessThan);
    }

    if (!has_wt_changes and !has_index_changes and !include_untracked) {
        return null;
    }

    const wt_tree_hash = if (staged_only_flag)
        try allocator.dupe(u8, index_tree_hash)
    else
        try helpers.writeTreeFromIndex(allocator, &wt_idx, git_path, platform_impl);
    defer allocator.free(wt_tree_hash);

    if (std.mem.eql(u8, wt_tree_hash, head_tree_hash) and std.mem.eql(u8, index_tree_hash, head_tree_hash) and !include_untracked) {
        return null;
    }

    const author = try getAuthorString(allocator);
    defer allocator.free(author);
    const committer = try getIdentityString(allocator);
    defer allocator.free(committer);

    // Build the base message "branch: subject"
    const head_subject = try getHeadSubject(allocator, git_path, head_hash);
    defer allocator.free(head_subject);
    const base_msg = try std.fmt.allocPrint(allocator, "{s}: {s} {s}", .{ branch_name, head_hash[0..@min(head_hash.len, 7)], head_subject });
    defer allocator.free(base_msg);

    // Create index commit
    const index_parents = [_][]const u8{head_hash};
    const index_msg = try std.fmt.allocPrint(allocator, "index on {s}", .{base_msg});
    defer allocator.free(index_msg);
    const index_commit_obj = try objects.createCommitObject(index_tree_hash, &index_parents, author, committer, index_msg, allocator);
    defer index_commit_obj.deinit(allocator);
    const index_commit_hash = try index_commit_obj.store(git_path, platform_impl, allocator);
    defer allocator.free(index_commit_hash);

    // Create untracked files commit if requested
    var untracked_commit_hash: ?[]u8 = null;
    defer if (untracked_commit_hash) |h| allocator.free(h);

    if (include_untracked or include_all) {
        if (try createUntrackedTree(allocator, git_path, repo_root, &idx, include_all, platform_impl)) |ut_tree_hash| {
            defer allocator.free(ut_tree_hash);
            const ut_parents = [_][]const u8{};
            const ut_msg = try std.fmt.allocPrint(allocator, "untracked files on {s}", .{base_msg});
            defer allocator.free(ut_msg);
            const ut_commit_obj = try objects.createCommitObject(ut_tree_hash, &ut_parents, author, committer, ut_msg, allocator);
            defer ut_commit_obj.deinit(allocator);
            untracked_commit_hash = try ut_commit_obj.store(git_path, platform_impl, allocator);
        }
    }

    // Create stash commit
    var parents = std.array_list.Managed([]const u8).init(allocator);
    defer parents.deinit();
    try parents.append(head_hash);
    try parents.append(index_commit_hash);
    if (untracked_commit_hash) |h| try parents.append(h);

    // Stash commit message
    const stash_msg = if (user_message) |um|
        try std.fmt.allocPrint(allocator, "On {s}: {s}", .{ branch_name, um })
    else
        try std.fmt.allocPrint(allocator, "WIP on {s}", .{base_msg});
    defer allocator.free(stash_msg);

    const stash_commit_obj = try objects.createCommitObject(wt_tree_hash, parents.items, author, committer, stash_msg, allocator);
    defer stash_commit_obj.deinit(allocator);
    return try stash_commit_obj.store(git_path, platform_impl, allocator);
}

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
    const gi_path = try std.fmt.allocPrint(allocator, "{s}/.gitignore", .{repo_root});
    defer allocator.free(gi_path);
    if (gitignore_mod.GitIgnore.loadFromFile(allocator, gi_path, platform_impl)) |loaded| {
        gitignore.deinit();
        gitignore = loaded;
    } else |_| {}

    var untracked = try helpers.findUntrackedFiles(allocator, repo_root, idx, &gitignore, platform_impl);
    defer {
        for (untracked.items) |item| allocator.free(item);
        untracked.deinit();
    }

    if (untracked.items.len == 0) return null;

    var ut_idx = index_mod.Index.init(allocator);
    defer ut_idx.deinit();

    for (untracked.items) |upath| {
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, upath });
        defer allocator.free(full_path);

        if (!include_ignored and gitignore.isIgnored(upath)) continue;

        if (std.fs.cwd().openFile(full_path, .{})) |file| {
            defer file.close();
            const content = file.readToEndAlloc(allocator, 100 * 1024 * 1024) catch continue;
            defer allocator.free(content);

            const blob_obj = objects.GitObject.init(.blob, content);
            const hash_hex = try blob_obj.store(git_path, platform_impl, allocator);
            defer allocator.free(hash_hex);

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
                .flags = if (upath.len >= 0xFFF) 0xFFF else @truncate(upath.len),
                .extended_flags = null,
                .path = try allocator.dupe(u8, upath),
            };
            ut_idx.entries.append(entry) catch {};
        } else |_| {}
    }

    if (ut_idx.entries.items.len == 0) return null;
    return try helpers.writeTreeFromIndex(allocator, &ut_idx, git_path, platform_impl);
}

// ============= stash push/save =============

fn stashPush(
    allocator: std.mem.Allocator,
    git_path: []const u8,
    sub_args: []const []const u8,
    subcmd: []const u8,
    explicit_push: bool,
    platform_impl: *const platform_mod.Platform,
) !void {
    var message: ?[]const u8 = null;
    var message_needs_free = false;
    var include_untracked = false;
    var include_all = false;
    var keep_index = false;
    var quiet = false;
    var staged_only = false;
    var pathspecs = std.array_list.Managed([]const u8).init(allocator);
    defer pathspecs.deinit();
    var after_dashdash = false;

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
            try platform_impl.writeStdout(push_usage);
            std.process.exit(129);
        } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--message")) {
            i += 1;
            if (i < sub_args.len) message = sub_args[i];
        } else if (std.mem.startsWith(u8, arg, "--message=")) {
            message = arg["--message=".len..];
        } else if (std.mem.startsWith(u8, arg, "-m") and arg.len > 2) {
            // -mfoo
            message = arg[2..];
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
            try platform_impl.writeStderr("error: stash --patch is not supported in ziggit\n");
            std.process.exit(1);
        } else if (std.mem.eql(u8, arg, "-S") or std.mem.eql(u8, arg, "--staged")) {
            staged_only = true;
        } else if (std.mem.eql(u8, arg, "--intent-to-add")) {
            // handled silently
        } else if (std.mem.startsWith(u8, arg, "-") and arg.len > 1) {
            const err_msg = try std.fmt.allocPrint(allocator, "error: unknown option: {s}\n{s}", .{ arg, push_usage });
            defer allocator.free(err_msg);
            try platform_impl.writeStderr(err_msg);
            std.process.exit(129);
        } else {
            // Check if this looks like a misplaced subcommand
            // (implicit push mode + subcommand name as arg)
            if (isStashSubcommand(arg) and !explicit_push) {
                const err_msg2 = try std.fmt.allocPrint(allocator, "error: subcommand wasn't specified; 'push' can't be assumed due to unexpected token '{s}'\n", .{arg});
                defer allocator.free(err_msg2);
                try platform_impl.writeStderr(err_msg2);
                std.process.exit(1);
            }
            // For "save" subcommand, remaining args are the message
            if (std.mem.eql(u8, subcmd, "save")) {
                var msg_parts = std.array_list.Managed(u8).init(allocator);
                try msg_parts.appendSlice(arg);
                var j = i + 1;
                while (j < sub_args.len) : (j += 1) {
                    try msg_parts.append(' ');
                    try msg_parts.appendSlice(sub_args[j]);
                }
                message = try msg_parts.toOwnedSlice();
                message_needs_free = true;
                break;
            } else {
                try pathspecs.append(arg);
            }
        }
    }
    defer if (message_needs_free) allocator.free(message.?);

    // Get HEAD
    const head_hash = getHeadHash(allocator, git_path, platform_impl) catch {
        if (!quiet) {
            try platform_impl.writeStderr("fatal: bad default revision 'HEAD'\nYou do not have the initial commit yet\n");
        }
        std.process.exit(128);
    };
    defer allocator.free(head_hash);

    const branch_name = try getCurrentBranch(allocator, git_path, platform_impl);
    defer allocator.free(branch_name);

    const stash_hash = try createStashCommit(
        allocator, git_path, head_hash, branch_name, message,
        include_untracked, include_all, pathspecs.items, platform_impl,
        staged_only,
    ) orelse {
        if (!quiet) {
            try platform_impl.writeStdout("No local changes to save\n");
        }
        if (quiet) return;
        std.process.exit(1);
    };
    defer allocator.free(stash_hash);

    // Store the stash ref
    const old_stash_opt = refs.resolveRef(git_path, "refs/stash", platform_impl, allocator) catch null;
    const old_stash = (old_stash_opt orelse null) orelse try allocator.dupe(u8, ZERO_HASH);
    defer allocator.free(old_stash);

    try refs.updateRef(git_path, "refs/stash", stash_hash, platform_impl, allocator);

    // Get stash message for reflog
    const stash_data = helpers.readGitObjectContent(git_path, stash_hash, allocator) catch null;
    defer if (stash_data) |d| allocator.free(d);
    const reflog_msg = if (stash_data) |d| blk: {
        if (std.mem.indexOf(u8, d, "\n\n")) |pos| {
            const msg_start = d[pos + 2 ..];
            const end = std.mem.indexOfScalar(u8, msg_start, '\n') orelse msg_start.len;
            break :blk msg_start[0..end];
        }
        break :blk "WIP";
    } else "WIP";

    helpers.writeReflogEntry(git_path, "refs/stash", old_stash, stash_hash, reflog_msg, allocator, platform_impl) catch {};

    // Reset working tree
    if (staged_only) {
        // For --staged: reset the index to HEAD and restore staged files in working tree
        const repo_root_s = try getRepoRoot(allocator, git_path);
        defer allocator.free(repo_root_s);
        const head_tree = helpers.getCommitTree(git_path, head_hash, allocator, platform_impl) catch null;
        if (head_tree) |ht| {
            defer allocator.free(ht);
            // Load current index (has staged changes) to know which files were staged
            var staged_idx = index_mod.Index.load(git_path, platform_impl, allocator) catch index_mod.Index.init(allocator);
            defer staged_idx.deinit();
            // Build HEAD tree blob map
            var head_blobs = std.StringHashMap([]const u8).init(allocator);
            defer {
                var vit = head_blobs.valueIterator();
                while (vit.next()) |v| allocator.free(v.*);
                var kit = head_blobs.keyIterator();
                while (kit.next()) |k| allocator.free(k.*);
                head_blobs.deinit();
            }
            helpers.collectTreeBlobs(allocator, ht, "", git_path, platform_impl, &head_blobs) catch {};
            // For each file that differs between index and HEAD, restore working tree to HEAD version
            for (staged_idx.entries.items) |entry| {
                var entry_hex: [40]u8 = undefined;
                for (entry.sha1, 0..) |byte, bi| {
                    entry_hex[bi * 2] = "0123456789abcdef"[byte >> 4];
                    entry_hex[bi * 2 + 1] = "0123456789abcdef"[byte & 0xf];
                }
                const head_hash_for_file = head_blobs.get(entry.path);
                if (head_hash_for_file) |hh| {
                    if (!std.mem.eql(u8, &entry_hex, hh)) {
                        // File was staged (index differs from HEAD) - restore to HEAD
                        const blob = objects.GitObject.load(hh, git_path, platform_impl, allocator) catch continue;
                        defer blob.deinit(allocator);
                        const full_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root_s, entry.path }) catch continue;
                        defer allocator.free(full_path);
                        platform_impl.fs.writeFile(full_path, blob.data) catch {};
                    }
                } else {
                    // File exists in index but not in HEAD - it was a new staged file, delete it
                    const full_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root_s, entry.path }) catch continue;
                    defer allocator.free(full_path);
                    std.fs.cwd().deleteFile(full_path) catch {};
                }
            }
            helpers.updateIndexFromTree(git_path, ht, allocator, platform_impl) catch {};
        }
    } else if (pathspecs.items.len == 0) {
        // Full reset to HEAD
        const repo_root = try getRepoRoot(allocator, git_path);
        defer allocator.free(repo_root);

        // Checkout HEAD tree
        const head_tree = helpers.getCommitTree(git_path, head_hash, allocator, platform_impl) catch null;
        if (head_tree) |ht| {
            defer allocator.free(ht);

            // Collect HEAD tree files to know what should exist
            var head_files = std.StringHashMap([]const u8).init(allocator);
            defer freeStringMap(&head_files, allocator);
            collectTreeFilesRecursive(allocator, git_path, ht, "", &head_files, platform_impl) catch {};

            // Remove files from working tree that are in old index but not in HEAD
            var old_idx = index_mod.Index.load(git_path, platform_impl, allocator) catch index_mod.Index.init(allocator);
            defer old_idx.deinit();
            for (old_idx.entries.items) |entry| {
                if (!head_files.contains(entry.path)) {
                    const rm_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, entry.path }) catch continue;
                    defer allocator.free(rm_path);
                    std.fs.cwd().deleteFile(rm_path) catch {};
                }
            }

            // First checkout files to working tree
            const tree_obj = objects.GitObject.load(ht, git_path, platform_impl, allocator) catch null;
            if (tree_obj) |to| {
                defer to.deinit(allocator);
                helpers.checkoutTreeRecursive(git_path, to.data, repo_root, "", allocator, platform_impl) catch {};
            }
            // Then reset index to HEAD tree (so stat info matches freshly written files)
            helpers.updateIndexFromTree(git_path, ht, allocator, platform_impl) catch {};
        }

        // Keep index if requested
        if (keep_index) {
            var info = parseStashCommit(allocator, git_path, stash_hash) catch null;
            if (info) |*si| {
                defer si.deinit(allocator);
                if (si.index_commit) |ic| {
                    const idx_tree = helpers.getCommitTree(git_path, ic, allocator, platform_impl) catch null;
                    if (idx_tree) |it| {
                        defer allocator.free(it);
                        helpers.updateIndexFromTree(git_path, it, allocator, platform_impl) catch {};
                        // Also checkout the index tree files
                        const it_obj = objects.GitObject.load(it, git_path, platform_impl, allocator) catch null;
                        if (it_obj) |ito| {
                            defer ito.deinit(allocator);
                            helpers.checkoutTreeRecursive(git_path, ito.data, repo_root, "", allocator, platform_impl) catch {};
                        }
                    }
                }
            }
        }

        // Remove untracked files if stashed
        if (include_untracked or include_all) {
            removeUntrackedFiles(allocator, git_path, repo_root, platform_impl) catch {};
        }
    } else {
        // Pathspec mode: only reset matching files to their HEAD state
        resetPathspecFiles(allocator, git_path, head_hash, pathspecs.items, platform_impl) catch {};
    }

    if (!quiet) {
        if (succinct_mod.isEnabled()) {
            try platform_impl.writeStderr("ok stash push\n");
        } else {
            const saved_msg = try std.fmt.allocPrint(allocator, "Saved working directory and index state {s}\n", .{reflog_msg});
            defer allocator.free(saved_msg);
            try platform_impl.writeStderr(saved_msg);
        }
    }
}

fn resetPathspecFiles(
    allocator: std.mem.Allocator,
    git_path: []const u8,
    head_hash: []const u8,
    pathspecs: []const []const u8,
    platform_impl: *const platform_mod.Platform,
) !void {
    const repo_root = try getRepoRoot(allocator, git_path);
    defer allocator.free(repo_root);

    // First, update the index for matching paths to HEAD state
    // Load HEAD tree entries
    const head_tree = try helpers.getCommitTree(git_path, head_hash, allocator, platform_impl);
    defer allocator.free(head_tree);

    // Load current index
    var idx = index_mod.Index.load(git_path, platform_impl, allocator) catch return;
    defer idx.deinit();

    // For each entry matching pathspec, restore from HEAD
    for (idx.entries.items) |*entry| {
        var matches = false;
        for (pathspecs) |ps| {
            if (helpers.matchPathspec(entry.path, ps)) {
                matches = true;
                break;
            }
        }
        if (!matches) continue;

        // Get the blob from HEAD tree
        const blob_hash = helpers.getTreeEntryHashByPath(git_path, head_tree, entry.path, allocator) catch {
            // File doesn't exist in HEAD - remove it from index and working tree
            const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, entry.path });
            defer allocator.free(full_path);
            std.fs.cwd().deleteFile(full_path) catch {};
            continue;
        };
        defer allocator.free(blob_hash);

        // Update index entry hash
        var hash_bytes: [20]u8 = undefined;
        for (0..20) |j| {
            hash_bytes[j] = std.fmt.parseInt(u8, blob_hash[j * 2 .. j * 2 + 2], 16) catch 0;
        }
        entry.sha1 = hash_bytes;

        // Restore file content
        const content = helpers.readBlobContent(allocator, git_path, blob_hash, platform_impl) catch continue;
        defer allocator.free(content);

        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, entry.path });
        defer allocator.free(full_path);
        if (std.fs.path.dirname(full_path)) |parent| {
            std.fs.cwd().makePath(parent) catch {};
        }
        platform_impl.fs.writeFile(full_path, content) catch {};
    }

    idx.save(git_path, platform_impl) catch {};
}

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

// ============= stash list =============

fn stashList(
    allocator: std.mem.Allocator,
    git_path: []const u8,
    sub_args: []const []const u8,
    platform_impl: *const platform_mod.Platform,
) !void {
    // Parse limit from args like -1, -2, etc.
    var limit: ?usize = null;
    for (sub_args) |arg| {
        if (arg.len >= 2 and arg[0] == '-' and std.ascii.isDigit(arg[1])) {
            limit = std.fmt.parseInt(usize, arg[1..], 10) catch null;
        }
    }

    const reflog_path = try std.fmt.allocPrint(allocator, "{s}/logs/refs/stash", .{git_path});
    defer allocator.free(reflog_path);

    const content = std.fs.cwd().readFileAlloc(allocator, reflog_path, 10 * 1024 * 1024) catch return;
    defer allocator.free(content);

    var lines = std.array_list.Managed([]const u8).init(allocator);
    defer lines.deinit();
    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |line| {
        if (line.len > 0) try lines.append(line);
    }

    // Output in reverse order (newest first)
    var count: usize = 0;
    var idx: usize = lines.items.len;
    while (idx > 0) {
        idx -= 1;
        if (limit) |l| {
            if (count >= l) break;
        }
        const line = lines.items[idx];
        const stash_num = lines.items.len - 1 - idx;
        if (std.mem.indexOf(u8, line, "\t")) |tab_pos| {
            const msg = line[tab_pos + 1 ..];
            if (succinct_mod.isEnabled()) {
                // Strip "WIP on branch:" prefix for compact output
                const compact_msg = if (std.mem.startsWith(u8, msg, "WIP on "))
                    if (std.mem.indexOf(u8, msg, ": ")) |colon_pos| msg[colon_pos + 2 ..] else msg
                else
                    msg;
                const entry_str = try std.fmt.allocPrint(allocator, "stash@{{{d}}}: {s}\n", .{ stash_num, compact_msg });
                defer allocator.free(entry_str);
                try platform_impl.writeStdout(entry_str);
            } else {
                const entry_str = try std.fmt.allocPrint(allocator, "stash@{{{d}}}: {s}\n", .{ stash_num, msg });
                defer allocator.free(entry_str);
                try platform_impl.writeStdout(entry_str);
            }
        }
        count += 1;
    }
}

// ============= stash show =============

fn stashShow(
    allocator: std.mem.Allocator,
    git_path: []const u8,
    sub_args: []const []const u8,
    platform_impl: *const platform_mod.Platform,
) !void {
    var stash_ref: ?[]const u8 = null;
    var show_patch = false;
    var show_stat = true;

    for (sub_args) |arg| {
        if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--patch")) {
            show_patch = true;
            show_stat = false;
        } else if (std.mem.eql(u8, arg, "--stat")) {
            show_stat = true;
        } else if (std.mem.eql(u8, arg, "--numstat")) {
            show_stat = false;
            show_patch = false;
            // numstat mode
        } else if (std.mem.eql(u8, arg, "-u") or std.mem.eql(u8, arg, "--include-untracked")) {
            // TODO
        } else if (std.mem.eql(u8, arg, "--patience") or std.mem.eql(u8, arg, "--histogram") or
            std.mem.eql(u8, arg, "--minimal") or std.mem.eql(u8, arg, "--diff-algorithm=patience"))
        {
            // diff algorithm flags - accept but ignore
            show_patch = true;
            show_stat = false;
        } else if (std.mem.eql(u8, arg, "--")) {
            // ignore
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (stash_ref != null) {
                try platform_impl.writeStderr("error: Too many revisions specified: stash\n");
                std.process.exit(1);
            }
            stash_ref = arg;
        }
    }

    // Read stash.showPatch and stash.showStat from config if no explicit flags
    var has_explicit_format = false;
    for (sub_args) |arg| {
        if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--patch") or
            std.mem.eql(u8, arg, "--stat") or std.mem.eql(u8, arg, "--numstat") or
            std.mem.eql(u8, arg, "--patience") or std.mem.eql(u8, arg, "--histogram") or
            std.mem.eql(u8, arg, "--minimal") or std.mem.eql(u8, arg, "--diff-algorithm=patience") or
            std.mem.eql(u8, arg, "--no-patch") or std.mem.eql(u8, arg, "--shortstat"))
        {
            has_explicit_format = true;
            break;
        }
    }
    if (!has_explicit_format) {
        const config_path_stash = std.fmt.allocPrint(allocator, "{s}/config", .{git_path}) catch "";
        defer if (config_path_stash.len > 0) allocator.free(config_path_stash);
        if (config_path_stash.len > 0) {
            if (platform_impl.fs.readFile(allocator, config_path_stash)) |cfg| {
                defer allocator.free(cfg);
                if (helpers.parseConfigValue(cfg, "stash.showpatch", allocator) catch null) |val| {
                    defer allocator.free(val);
                    if (std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "yes") or std.mem.eql(u8, val, "1")) {
                        show_patch = true;
                    } else if (std.mem.eql(u8, val, "false") or std.mem.eql(u8, val, "no") or std.mem.eql(u8, val, "0")) {
                        show_patch = false;
                    }
                }
                if (helpers.parseConfigValue(cfg, "stash.showstat", allocator) catch null) |val| {
                    defer allocator.free(val);
                    if (std.mem.eql(u8, val, "false") or std.mem.eql(u8, val, "no") or std.mem.eql(u8, val, "0")) {
                        show_stat = false;
                    } else if (std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "yes") or std.mem.eql(u8, val, "1")) {
                        show_stat = true;
                    }
                }
            } else |_| {}
        }
    }

    // Check for --numstat
    var numstat = false;
    for (sub_args) |arg| {
        if (std.mem.eql(u8, arg, "--numstat")) {
            numstat = true;
        }
    }

    const effective_ref = stash_ref orelse "stash@{0}";

    // Resolve stash ref
    const stash_hash = resolveStashRef(allocator, git_path, effective_ref, platform_impl) catch {
        const msg = try std.fmt.allocPrint(allocator, "fatal: bad revision '{s}'\n", .{effective_ref});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        std.process.exit(128);
    };
    defer allocator.free(stash_hash);

    const parent_hash = getStashParent(allocator, git_path, stash_hash) catch {
        try platform_impl.writeStderr("fatal: bad stash reference\n");
        std.process.exit(128);
    };
    defer allocator.free(parent_hash);

    // Get trees from both commits
    const parent_tree = helpers.getCommitTree(git_path, parent_hash, allocator, platform_impl) catch return;
    defer allocator.free(parent_tree);
    const stash_tree_hash = helpers.getCommitTree(git_path, stash_hash, allocator, platform_impl) catch return;
    defer allocator.free(stash_tree_hash);

    // Collect files from both trees
    var parent_map = std.StringHashMap([]const u8).init(allocator);
    defer freeStringMap(&parent_map, allocator);
    var stash_map_show = std.StringHashMap([]const u8).init(allocator);
    defer freeStringMap(&stash_map_show, allocator);

    collectTreeFilesRecursive(allocator, git_path, parent_tree, "", &parent_map, platform_impl) catch {};
    collectTreeFilesRecursive(allocator, git_path, stash_tree_hash, "", &stash_map_show, platform_impl) catch {};

    // Collect changed files
    var changed_files = std.array_list.Managed(ChangedFile).init(allocator);
    defer {
        for (changed_files.items) |cf| {
            allocator.free(cf.path);
            if (cf.old_hash) |h| allocator.free(h);
            if (cf.new_hash) |h| allocator.free(h);
        }
        changed_files.deinit();
    }

    // Files in stash that differ from parent
    var all_paths = std.StringHashMap(void).init(allocator);
    defer {
        var it2 = all_paths.iterator();
        while (it2.next()) |e| allocator.free(e.key_ptr.*);
        all_paths.deinit();
    }
    {
        var it2 = parent_map.iterator();
        while (it2.next()) |e| {
            if (!all_paths.contains(e.key_ptr.*)) try all_paths.put(try allocator.dupe(u8, e.key_ptr.*), {});
        }
    }
    {
        var it2 = stash_map_show.iterator();
        while (it2.next()) |e| {
            if (!all_paths.contains(e.key_ptr.*)) try all_paths.put(try allocator.dupe(u8, e.key_ptr.*), {});
        }
    }

    var pit = all_paths.iterator();
    while (pit.next()) |pe| {
        const path = pe.key_ptr.*;
        const old_h = parent_map.get(path);
        const new_h = stash_map_show.get(path);
        if (old_h != null and new_h != null and std.mem.eql(u8, old_h.?, new_h.?)) continue;
        try changed_files.append(.{
            .path = try allocator.dupe(u8, path),
            .old_hash = if (old_h) |h| try allocator.dupe(u8, h) else null,
            .new_hash = if (new_h) |h| try allocator.dupe(u8, h) else null,
        });
    }

    // Sort changed files by path
    std.mem.sort(ChangedFile, changed_files.items, {}, struct {
        fn lessThan(_: void, a: ChangedFile, b: ChangedFile) bool {
            return std.mem.order(u8, a.path, b.path) == .lt;
        }
    }.lessThan);

    if (show_stat or numstat) {
        for (changed_files.items) |cf| {
            const old_content = if (cf.old_hash) |h| (helpers.readBlobContent(allocator, git_path, h, platform_impl) catch null) else null;
            defer if (old_content) |c| allocator.free(c);
            const new_content = if (cf.new_hash) |h| (helpers.readBlobContent(allocator, git_path, h, platform_impl) catch null) else null;
            defer if (new_content) |c| allocator.free(c);

            var ins: usize = 0;
            var del: usize = 0;
            countDiffStats(old_content orelse "", new_content orelse "", &ins, &del);

            if (numstat) {
                const out = try std.fmt.allocPrint(allocator, "{d}\t{d}\t{s}\n", .{ ins, del, cf.path });
                defer allocator.free(out);
                try platform_impl.writeStdout(out);
            } else {
                // Collect for stat summary
                _ = .{}; // handled below
            }
        }
        if (show_stat and !numstat) {
            try outputDiffstatFromFiles(allocator, git_path, changed_files.items, platform_impl);
        }
    }

    if (show_patch) {
        for (changed_files.items) |cf| {
            try outputPatchForFile(allocator, git_path, cf, platform_impl);
        }
    }
}

const ChangedFile = struct {
    path: []u8,
    old_hash: ?[]u8,
    new_hash: ?[]u8,
};

fn countDiffStats(old: []const u8, new: []const u8, ins: *usize, del: *usize) void {
    // Simple line-based diff counting
    var old_lines = std.array_list.Managed([]const u8).init(std.heap.page_allocator);
    defer old_lines.deinit();
    var new_lines = std.array_list.Managed([]const u8).init(std.heap.page_allocator);
    defer new_lines.deinit();

    var oit = std.mem.splitScalar(u8, old, '\n');
    while (oit.next()) |line| old_lines.append(line) catch {};
    var nit = std.mem.splitScalar(u8, new, '\n');
    while (nit.next()) |line| new_lines.append(line) catch {};

    // Remove trailing empty line from split
    if (old_lines.items.len > 0 and old_lines.items[old_lines.items.len - 1].len == 0) _ = old_lines.pop();
    if (new_lines.items.len > 0 and new_lines.items[new_lines.items.len - 1].len == 0) _ = new_lines.pop();

    // Simple: count lines added and removed
    // For a proper diff we'd need LCS, but for stats, approximate with simple comparison
    const old_count = old_lines.items.len;
    const new_count = new_lines.items.len;

    // Count matching lines from start
    var common: usize = 0;
    const min_count = @min(old_count, new_count);
    while (common < min_count and std.mem.eql(u8, old_lines.items[common], new_lines.items[common])) {
        common += 1;
    }
    // Count matching lines from end
    var end_common: usize = 0;
    while (end_common < min_count - common and
        std.mem.eql(u8, old_lines.items[old_count - 1 - end_common], new_lines.items[new_count - 1 - end_common]))
    {
        end_common += 1;
    }

    const old_changed = old_count - common - end_common;
    const new_changed = new_count - common - end_common;
    del.* = old_changed;
    ins.* = new_changed;
}

fn outputDiffstatFromFiles(
    allocator: std.mem.Allocator,
    git_path: []const u8,
    files: []const ChangedFile,
    platform_impl: *const platform_mod.Platform,
) !void {
    if (files.len == 0) return;

    var max_name_len: usize = 0;
    var total_ins: usize = 0;
    var total_del: usize = 0;
    var file_stats = std.array_list.Managed(FileStat).init(allocator);
    defer file_stats.deinit();

    for (files) |cf| {
        const old_content = if (cf.old_hash) |h| (helpers.readBlobContent(allocator, git_path, h, platform_impl) catch null) else null;
        defer if (old_content) |c| allocator.free(c);
        const new_content = if (cf.new_hash) |h| (helpers.readBlobContent(allocator, git_path, h, platform_impl) catch null) else null;
        defer if (new_content) |c| allocator.free(c);

        var ins: usize = 0;
        var del: usize = 0;
        countDiffStats(old_content orelse "", new_content orelse "", &ins, &del);

        if (cf.path.len > max_name_len) max_name_len = cf.path.len;
        total_ins += ins;
        total_del += del;
        try file_stats.append(.{ .name = cf.path, .ins = ins, .del = del });
    }

    for (file_stats.items) |f| {
        const changes = f.ins + f.del;
        const line = try std.fmt.allocPrint(allocator, " {s}", .{f.name});
        defer allocator.free(line);
        try platform_impl.writeStdout(line);

        var pad_count = max_name_len - f.name.len + 1;
        while (pad_count > 0) : (pad_count -= 1) try platform_impl.writeStdout(" ");

        const bar = try std.fmt.allocPrint(allocator, "| {d} ", .{changes});
        defer allocator.free(bar);
        try platform_impl.writeStdout(bar);

        var plus_count = f.ins;
        var minus_count = f.del;
        const max_bar: usize = 40;
        if (plus_count + minus_count > max_bar) {
            const total = plus_count + minus_count;
            plus_count = (plus_count * max_bar + total - 1) / total;
            minus_count = max_bar - plus_count;
        }
        var j: usize = 0;
        while (j < plus_count) : (j += 1) try platform_impl.writeStdout("+");
        j = 0;
        while (j < minus_count) : (j += 1) try platform_impl.writeStdout("-");
        try platform_impl.writeStdout("\n");
    }

    try helpers.formatDiffStatSummary(file_stats.items.len, total_ins, total_del, platform_impl, allocator);
}

fn outputPatchForFile(
    allocator: std.mem.Allocator,
    git_path: []const u8,
    cf: ChangedFile,
    platform_impl: *const platform_mod.Platform,
) !void {
    const old_content = if (cf.old_hash) |h| (helpers.readBlobContent(allocator, git_path, h, platform_impl) catch null) else null;
    defer if (old_content) |c| allocator.free(c);
    const new_content = if (cf.new_hash) |h| (helpers.readBlobContent(allocator, git_path, h, platform_impl) catch null) else null;
    defer if (new_content) |c| allocator.free(c);

    const old_short = if (cf.old_hash) |h| h[0..@min(h.len, 7)] else "0000000";
    const new_short = if (cf.new_hash) |h| h[0..@min(h.len, 7)] else "0000000";

    // Header
    const header = try std.fmt.allocPrint(allocator, "diff --git a/{s} b/{s}\n", .{ cf.path, cf.path });
    defer allocator.free(header);
    try platform_impl.writeStdout(header);

    if (cf.old_hash == null) {
        try platform_impl.writeStdout("new file mode 100644\n");
        const idx = try std.fmt.allocPrint(allocator, "index {s}..{s}\n", .{ old_short, new_short });
        defer allocator.free(idx);
        try platform_impl.writeStdout(idx);
    } else if (cf.new_hash == null) {
        try platform_impl.writeStdout("deleted file mode 100644\n");
        const idx = try std.fmt.allocPrint(allocator, "index {s}..{s}\n", .{ old_short, new_short });
        defer allocator.free(idx);
        try platform_impl.writeStdout(idx);
    } else {
        const idx = try std.fmt.allocPrint(allocator, "index {s}..{s} 100644\n", .{ old_short, new_short });
        defer allocator.free(idx);
        try platform_impl.writeStdout(idx);
    }

    const a_name = try std.fmt.allocPrint(allocator, "--- {s}\n", .{if (cf.old_hash != null) try std.fmt.allocPrint(allocator, "a/{s}", .{cf.path}) else "/dev/null"});
    defer allocator.free(a_name);
    try platform_impl.writeStdout(a_name);

    const b_name = try std.fmt.allocPrint(allocator, "+++ {s}\n", .{if (cf.new_hash != null) try std.fmt.allocPrint(allocator, "b/{s}", .{cf.path}) else "/dev/null"});
    defer allocator.free(b_name);
    try platform_impl.writeStdout(b_name);

    // Generate unified diff hunks only (we already output the header)
    const diff_result = diff_mod.generateUnifiedDiffWithHashes(old_content orelse "", new_content orelse "", cf.path, old_short, new_short, allocator) catch return;
    defer allocator.free(diff_result);
    // Skip the header lines we already output, find the first @@ line
    if (std.mem.indexOf(u8, diff_result, "@@ ")) |hunk_start| {
        try platform_impl.writeStdout(diff_result[hunk_start..]);
    }
}

fn outputDiffstat(allocator: std.mem.Allocator, diff_output: []const u8, platform_impl: *const platform_mod.Platform) !void {
    // Parse diff output to extract file stats
    var files = std.array_list.Managed(FileStat).init(allocator);
    defer files.deinit();

    var lines_iter = std.mem.splitScalar(u8, diff_output, '\n');
    var current_file: ?[]const u8 = null;
    var insertions: usize = 0;
    var deletions: usize = 0;

    while (lines_iter.next()) |line| {
        if (std.mem.startsWith(u8, line, "diff --git ")) {
            // Save previous file
            if (current_file) |f| {
                try files.append(.{ .name = f, .ins = insertions, .del = deletions });
            }
            // Parse filename
            if (std.mem.indexOf(u8, line, " b/")) |b_pos| {
                current_file = line[b_pos + 3 ..];
            } else {
                current_file = null;
            }
            insertions = 0;
            deletions = 0;
        } else if (line.len > 0 and line[0] == '+' and !std.mem.startsWith(u8, line, "+++")) {
            insertions += 1;
        } else if (line.len > 0 and line[0] == '-' and !std.mem.startsWith(u8, line, "---")) {
            deletions += 1;
        }
    }
    if (current_file) |f| {
        try files.append(.{ .name = f, .ins = insertions, .del = deletions });
    }

    if (files.items.len == 0) return;

    // Find max name width and max change count
    var max_name_len: usize = 0;
    var max_changes: usize = 0;
    var total_ins: usize = 0;
    var total_del: usize = 0;
    for (files.items) |f| {
        if (f.name.len > max_name_len) max_name_len = f.name.len;
        const changes = f.ins + f.del;
        if (changes > max_changes) max_changes = changes;
        total_ins += f.ins;
        total_del += f.del;
    }

    // Output stat lines
    for (files.items) |f| {
        const changes = f.ins + f.del;
        const line = try std.fmt.allocPrint(allocator, " {s}", .{f.name});
        defer allocator.free(line);
        try platform_impl.writeStdout(line);

        // Pad
        var pad_count = max_name_len - f.name.len + 1;
        while (pad_count > 0) : (pad_count -= 1) {
            try platform_impl.writeStdout(" ");
        }

        const bar = try std.fmt.allocPrint(allocator, "| {d} ", .{changes});
        defer allocator.free(bar);
        try platform_impl.writeStdout(bar);

        // +/- indicators
        var plus_count = f.ins;
        var minus_count = f.del;
        // Scale if too wide
        const max_bar = 40;
        if (plus_count + minus_count > max_bar) {
            const total = plus_count + minus_count;
            plus_count = (plus_count * max_bar + total - 1) / total;
            minus_count = max_bar - plus_count;
        }
        var j: usize = 0;
        while (j < plus_count) : (j += 1) try platform_impl.writeStdout("+");
        j = 0;
        while (j < minus_count) : (j += 1) try platform_impl.writeStdout("-");
        try platform_impl.writeStdout("\n");
    }

    // Summary line
    try helpers.formatDiffStatSummary(files.items.len, total_ins, total_del, platform_impl, allocator);
}

const FileStat = struct {
    name: []const u8,
    ins: usize,
    del: usize,
};

fn outputNumstat(allocator: std.mem.Allocator, diff_output: []const u8, platform_impl: *const platform_mod.Platform) !void {
    var lines_iter = std.mem.splitScalar(u8, diff_output, '\n');
    var current_file: ?[]const u8 = null;
    var insertions: usize = 0;
    var deletions_count: usize = 0;

    while (lines_iter.next()) |line| {
        if (std.mem.startsWith(u8, line, "diff --git ")) {
            if (current_file) |f| {
                const out = try std.fmt.allocPrint(allocator, "{d}\t{d}\t{s}\n", .{ insertions, deletions_count, f });
                defer allocator.free(out);
                try platform_impl.writeStdout(out);
            }
            if (std.mem.indexOf(u8, line, " b/")) |b_pos| {
                current_file = line[b_pos + 3 ..];
            } else {
                current_file = null;
            }
            insertions = 0;
            deletions_count = 0;
        } else if (line.len > 0 and line[0] == '+' and !std.mem.startsWith(u8, line, "+++")) {
            insertions += 1;
        } else if (line.len > 0 and line[0] == '-' and !std.mem.startsWith(u8, line, "---")) {
            deletions_count += 1;
        }
    }
    if (current_file) |f| {
        const out = try std.fmt.allocPrint(allocator, "{d}\t{d}\t{s}\n", .{ insertions, deletions_count, f });
        defer allocator.free(out);
        try platform_impl.writeStdout(out);
    }
}

// ============= stash apply/pop =============

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

    var ref_count: usize = 0;
    for (sub_args) |arg| {
        if (std.mem.eql(u8, arg, "--index")) {
            restore_index = true;
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            quiet = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            ref_count += 1;
            if (ref_count > 1) {
                try platform_impl.writeStderr("error: Too many revisions specified: stash\n");
                std.process.exit(1);
            }
            stash_ref = arg;
        }
    }

    // Validate stash ref format for pop/drop: must be a stash reference, not a raw hash
    if (is_pop) {
        const is_stash_style_ref = std.mem.startsWith(u8, stash_ref, "stash") or isDigitString(stash_ref);
        if (!is_stash_style_ref) {
            const msg = try std.fmt.allocPrint(allocator, "error: '{s}' is not a stash reference\n", .{stash_ref});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(1);
        }
    } else {
        const is_valid_stash_ref = std.mem.startsWith(u8, stash_ref, "stash") or isDigitString(stash_ref) or (stash_ref.len == 40 and isHexString(stash_ref));
        if (!is_valid_stash_ref) {
            const msg = try std.fmt.allocPrint(allocator, "error: '{s}' is not a stash-like commit\n", .{stash_ref});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(1);
        }
    }

    const stash_hash = resolveStashRef(allocator, git_path, stash_ref, platform_impl) catch {
        const msg = try std.fmt.allocPrint(allocator, "error: {s} is not a valid reference\n", .{stash_ref});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        std.process.exit(1);
    };
    defer allocator.free(stash_hash);

    const repo_root = try getRepoRoot(allocator, git_path);
    defer allocator.free(repo_root);

    var info = parseStashCommit(allocator, git_path, stash_hash) catch {
        try platform_impl.writeStderr("error: could not read stash commit\n");
        std.process.exit(1);
    };
    defer info.deinit(allocator);

    // Get current HEAD
    const current_head = getHeadHash(allocator, git_path, platform_impl) catch {
        try platform_impl.writeStderr("error: could not read HEAD\n");
        std.process.exit(1);
    };
    defer allocator.free(current_head);

    // Apply untracked files first
    if (info.untracked_commit) |ut_hash| {
        applyUntrackedFiles(allocator, git_path, repo_root, ut_hash, platform_impl) catch {};
    }

    // Get base tree (stash parent), current tree, and stash tree
    const base_tree = helpers.getCommitTree(git_path, info.parent_hash, allocator, platform_impl) catch {
        try platform_impl.writeStderr("error: could not resolve stash base tree\n");
        std.process.exit(1);
    };
    defer allocator.free(base_tree);

    const current_tree = helpers.getCommitTree(git_path, current_head, allocator, platform_impl) catch {
        try platform_impl.writeStderr("error: could not resolve current tree\n");
        std.process.exit(1);
    };
    defer allocator.free(current_tree);

    // Collect file hashes from all three trees
    var base_map = std.StringHashMap([]const u8).init(allocator);
    defer freeStringMap(&base_map, allocator);
    var current_map = std.StringHashMap([]const u8).init(allocator);
    defer freeStringMap(&current_map, allocator);
    var stash_map = std.StringHashMap([]const u8).init(allocator);
    defer freeStringMap(&stash_map, allocator);

    collectTreeFilesRecursive(allocator, git_path, base_tree, "", &base_map, platform_impl) catch {};
    collectTreeFilesRecursive(allocator, git_path, current_tree, "", &current_map, platform_impl) catch {};
    collectTreeFilesRecursive(allocator, git_path, info.stash_tree, "", &stash_map, platform_impl) catch {};

    // For stash apply: apply the diff (base -> stash) on top of current
    var had_conflicts = false;

    // Load current index
    var idx = index_mod.Index.load(git_path, platform_impl, allocator) catch index_mod.Index.init(allocator);
    defer idx.deinit();

    // Collect all unique paths
    var all_paths = std.StringHashMap(void).init(allocator);
    defer {
        var it = all_paths.iterator();
        while (it.next()) |e| allocator.free(e.key_ptr.*);
        all_paths.deinit();
    }
    {
        var it = base_map.iterator();
        while (it.next()) |e| {
            if (!all_paths.contains(e.key_ptr.*)) try all_paths.put(try allocator.dupe(u8, e.key_ptr.*), {});
        }
    }
    {
        var it = stash_map.iterator();
        while (it.next()) |e| {
            if (!all_paths.contains(e.key_ptr.*)) try all_paths.put(try allocator.dupe(u8, e.key_ptr.*), {});
        }
    }

    // Pre-check: detect if working tree has local changes that conflict with stash
    {
        var check_iter = all_paths.iterator();
        while (check_iter.next()) |check_entry| {
            const check_path = check_entry.key_ptr.*;
            const bh = base_map.get(check_path);
            const sh = stash_map.get(check_path);
            const ch = current_map.get(check_path);

            // Only care about files that stash modifies
            if (bh != null and sh != null and std.mem.eql(u8, bh.?, sh.?)) continue;
            if (bh == null and sh == null) continue;

            // If stash modifies this file and it exists in current, check working tree
            if (sh != null and ch != null) {
                const check_file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, check_path });
                defer allocator.free(check_file_path);
                const wt_content = readWorkingFile(allocator, check_file_path) catch continue;
                defer allocator.free(wt_content);
                const head_content = helpers.readBlobContent(allocator, git_path, ch.?, platform_impl) catch continue;
                defer allocator.free(head_content);
                if (!std.mem.eql(u8, wt_content, head_content)) {
                    // Working tree has local changes that would be overwritten
                    try platform_impl.writeStderr("error: Your local changes to the following files would be overwritten by merge:\n");
                    const err_msg = try std.fmt.allocPrint(allocator, "\t{s}\n", .{check_path});
                    defer allocator.free(err_msg);
                    try platform_impl.writeStderr(err_msg);
                    try platform_impl.writeStderr("Please commit your changes or stash them before you merge.\n");
                    try platform_impl.writeStderr("Aborting\n");
                    std.process.exit(1);
                }
            }
        }
    }

    var path_iter = all_paths.iterator();
    while (path_iter.next()) |path_entry| {
        const path = path_entry.key_ptr.*;
        const base_hash = base_map.get(path);
        const stash_hash_for_file = stash_map.get(path);
        const current_hash_for_file = current_map.get(path);

        // If file didn't change between base and stash, skip
        if (base_hash != null and stash_hash_for_file != null and std.mem.eql(u8, base_hash.?, stash_hash_for_file.?)) continue;
        if (base_hash == null and stash_hash_for_file == null) continue;

        const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, path });
        defer allocator.free(file_path);

        if (stash_hash_for_file == null) {
            // File was deleted in stash
            if (current_hash_for_file != null and base_hash != null and std.mem.eql(u8, current_hash_for_file.?, base_hash.?)) {
                // Current matches base, safe to delete
                std.fs.cwd().deleteFile(file_path) catch {};
                removeIndexEntry(&idx, path);
            } else if (current_hash_for_file != null) {
                // Current was modified, conflict
                had_conflicts = true;
            } else {
                // Already deleted in current, no action
            }
        } else if (base_hash == null) {
            // File was added in stash
            if (current_hash_for_file == null) {
                // Not in current either, just add it
                if (std.fs.path.dirname(file_path)) |parent| std.fs.cwd().makePath(parent) catch {};
                const content = helpers.readBlobContent(allocator, git_path, stash_hash_for_file.?, platform_impl) catch continue;
                defer allocator.free(content);
                platform_impl.fs.writeFile(file_path, content) catch {};
                if (restore_index) updateIndexEntryFromHash(&idx, path, stash_hash_for_file.?, allocator) catch {};
            } else if (std.mem.eql(u8, current_hash_for_file.?, stash_hash_for_file.?)) {
                // Same content, no action needed
            } else {
                // Both added different content - conflict
                had_conflicts = true;
            }
        } else {
            // File was modified in stash
            if (current_hash_for_file == null) {
                // Deleted in current but modified in stash
                had_conflicts = true;
            } else if (std.mem.eql(u8, current_hash_for_file.?, base_hash.?)) {
                // Current matches base, safe to take stash version
                if (std.fs.path.dirname(file_path)) |parent| std.fs.cwd().makePath(parent) catch {};
                const content = helpers.readBlobContent(allocator, git_path, stash_hash_for_file.?, platform_impl) catch continue;
                defer allocator.free(content);
                platform_impl.fs.writeFile(file_path, content) catch {};
            } else if (std.mem.eql(u8, current_hash_for_file.?, stash_hash_for_file.?)) {
                // Current already has stash content, no action
            } else {
                // Both modified differently - try content merge
                const base_content = helpers.readBlobContent(allocator, git_path, base_hash.?, platform_impl) catch continue;
                defer allocator.free(base_content);
                const current_content = readWorkingFile(allocator, file_path) catch continue;
                defer allocator.free(current_content);
                const stash_content = helpers.readBlobContent(allocator, git_path, stash_hash_for_file.?, platform_impl) catch continue;
                defer allocator.free(stash_content);

                if (helpers.threeWayContentMerge(base_content, current_content, stash_content, allocator) catch null) |merged| {
                    defer allocator.free(merged);
                    platform_impl.fs.writeFile(file_path, merged) catch {};
                } else {
                    // Write conflict markers
                    const conflict_content = try std.fmt.allocPrint(allocator, "<<<<<<< Updated upstream\n{s}=======\n{s}>>>>>>> Stashed changes\n", .{ current_content, stash_content });
                    defer allocator.free(conflict_content);
                    platform_impl.fs.writeFile(file_path, conflict_content) catch {};
                    had_conflicts = true;
                }
            }
        }
    }

    // If --index, restore index state from stash^2
    if (restore_index) {
        if (info.index_commit) |ic| {
            const idx_tree = helpers.getCommitTree(git_path, ic, allocator, platform_impl) catch null;
            if (idx_tree) |it| {
                defer allocator.free(it);
                // Collect index tree files
                var idx_map = std.StringHashMap([]const u8).init(allocator);
                defer freeStringMap(&idx_map, allocator);
                collectTreeFilesRecursive(allocator, git_path, it, "", &idx_map, platform_impl) catch {};

                // Update index entries for files that differ between base and index commit
                var idx_iter = idx_map.iterator();
                while (idx_iter.next()) |e| {
                    const ipath = e.key_ptr.*;
                    const ihash = e.value_ptr.*;
                    const bh = base_map.get(ipath);
                    if (bh == null or !std.mem.eql(u8, bh.?, ihash)) {
                        updateIndexEntryFromHash(&idx, ipath, ihash, allocator) catch {};
                    }
                }
            }
        }
    }

    // Save updated index
    idx.save(git_path, platform_impl) catch {};

    // If pop, drop the stash entry (only if no conflicts)
    if (is_pop and !had_conflicts) {
        // Find which index this stash_ref corresponds to
        const drop_idx = getStashDropIndex(stash_ref);
        stashDropByIndex(allocator, git_path, drop_idx, platform_impl) catch {};
    }

    if (had_conflicts) {
        if (!quiet) {
            try platform_impl.writeStdout("CONFLICT (content): Merge conflict\n");
        }
        if (is_pop) {
            try platform_impl.writeStderr("The stash entry is kept in case you need it again.\n");
        }
        std.process.exit(1);
    }

    if (!quiet) {
        if (succinct_mod.isEnabled()) {
            if (is_pop) {
                try platform_impl.writeStdout("ok stash pop\n");
            } else {
                try platform_impl.writeStdout("ok stash apply\n");
            }
        } else {
            const head_branch = getCurrentBranch(allocator, git_path, platform_impl) catch try allocator.dupe(u8, "HEAD");
            defer allocator.free(head_branch);
            const msg = try std.fmt.allocPrint(allocator, "On branch {s}\n", .{head_branch});
            defer allocator.free(msg);
            try platform_impl.writeStdout(msg);
        }
    }

    // Run post-checkout hook after stash apply/pop restores working tree
    {
        const prev_head = refs.getCurrentCommit(git_path, platform_impl, allocator) catch null;
        defer if (prev_head) |h| allocator.free(h);
        const head_hash = prev_head orelse ZERO_HASH;
        const hook_args = [_][]const u8{ head_hash, head_hash, "1" };
        _ = hooks.runHook(allocator, git_path, "post-checkout", &hook_args, null, platform_impl) catch {};
    }
}

fn isHexString(s: []const u8) bool {
    for (s) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return s.len > 0;
}

fn isDigitString(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

fn getStashDropIndex(stash_ref: []const u8) u32 {
    if (std.mem.startsWith(u8, stash_ref, "stash@{")) {
        const end = std.mem.indexOfScalar(u8, stash_ref, '}') orelse return 0;
        return std.fmt.parseInt(u32, stash_ref[7..end], 10) catch 0;
    }
    if (isDigitString(stash_ref)) {
        return std.fmt.parseInt(u32, stash_ref, 10) catch 0;
    }
    return 0;
}

fn freeStringMap(map: *std.StringHashMap([]const u8), allocator: std.mem.Allocator) void {
    var it = map.iterator();
    while (it.next()) |e| {
        allocator.free(e.key_ptr.*);
        allocator.free(e.value_ptr.*);
    }
    map.deinit();
}

fn collectTreeFilesRecursive(
    allocator: std.mem.Allocator,
    git_path: []const u8,
    tree_hash: []const u8,
    prefix: []const u8,
    map: *std.StringHashMap([]const u8),
    platform_impl: *const platform_mod.Platform,
) !void {
    const tree_obj = try objects.GitObject.load(tree_hash, git_path, platform_impl, allocator);
    defer tree_obj.deinit(allocator);
    if (tree_obj.type != .tree) return;

    var pos: usize = 0;
    while (pos < tree_obj.data.len) {
        const space_pos = std.mem.indexOfScalarPos(u8, tree_obj.data, pos, ' ') orelse break;
        const mode_str = tree_obj.data[pos..space_pos];
        const null_pos = std.mem.indexOfScalarPos(u8, tree_obj.data, space_pos + 1, 0) orelse break;
        const name = tree_obj.data[space_pos + 1 .. null_pos];
        if (null_pos + 21 > tree_obj.data.len) break;
        const hash_bytes = tree_obj.data[null_pos + 1 .. null_pos + 21];
        var hash_hex: [40]u8 = undefined;
        _ = std.fmt.bufPrint(&hash_hex, "{x}", .{hash_bytes}) catch break;
        pos = null_pos + 21;

        const full_name = if (prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, name })
        else
            try allocator.dupe(u8, name);

        if (std.mem.eql(u8, mode_str, "40000")) {
            // Recurse into subdirectory
            try collectTreeFilesRecursive(allocator, git_path, &hash_hex, full_name, map, platform_impl);
            allocator.free(full_name);
        } else {
            const hash_copy = try allocator.dupe(u8, &hash_hex);
            map.put(full_name, hash_copy) catch {
                allocator.free(full_name);
                allocator.free(hash_copy);
            };
        }
    }
}

fn removeIndexEntry(idx: *index_mod.Index, path: []const u8) void {
    var i: usize = 0;
    while (i < idx.entries.items.len) {
        if (std.mem.eql(u8, idx.entries.items[i].path, path)) {
            _ = idx.entries.orderedRemove(i);
        } else {
            i += 1;
        }
    }
}

fn updateIndexEntryFromHash(idx: *index_mod.Index, path: []const u8, hash_hex: []const u8, allocator: std.mem.Allocator) !void {
    var hash_bytes: [20]u8 = undefined;
    for (0..20) |i| {
        hash_bytes[i] = std.fmt.parseInt(u8, hash_hex[i * 2 .. i * 2 + 2], 16) catch 0;
    }
    // Find existing entry and update
    for (idx.entries.items) |*entry| {
        if (std.mem.eql(u8, entry.path, path)) {
            entry.sha1 = hash_bytes;
            return;
        }
    }
    // Add new entry
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
        .size = 0,
        .sha1 = hash_bytes,
        .flags = if (path.len >= 0xFFF) 0xFFF else @truncate(path.len),
        .extended_flags = null,
        .path = try allocator.dupe(u8, path),
    };
    try idx.entries.append(entry);
}

fn readWorkingFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return try file.readToEndAlloc(allocator, 100 * 1024 * 1024);
}

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
        const space_pos = std.mem.indexOfScalarPos(u8, tree_data, pos, ' ') orelse break;
        const mode_str = tree_data[pos..space_pos];
        const null_pos = std.mem.indexOfScalarPos(u8, tree_data, space_pos + 1, 0) orelse break;
        const name = tree_data[space_pos + 1 .. null_pos];
        if (null_pos + 21 > tree_data.len) break;
        const hash_bytes = tree_data[null_pos + 1 .. null_pos + 21];
        var hash_hex: [40]u8 = undefined;
        _ = std.fmt.bufPrint(&hash_hex, "{x}", .{hash_bytes}) catch break;
        pos = null_pos + 21;

        const full_name = if (prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, name })
        else
            try allocator.dupe(u8, name);
        defer allocator.free(full_name);

        if (std.mem.eql(u8, mode_str, "40000")) {
            const subtree = objects.GitObject.load(&hash_hex, git_path, platform_impl, allocator) catch continue;
            defer subtree.deinit(allocator);
            try checkoutUntrackedTree(allocator, git_path, subtree.data, repo_root, full_name, platform_impl);
        } else {
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

// ============= stash drop =============

fn stashDrop(
    allocator: std.mem.Allocator,
    git_path: []const u8,
    sub_args: []const []const u8,
    platform_impl: *const platform_mod.Platform,
) !void {
    var quiet = false;
    var stash_ref: []const u8 = "stash@{0}";

    var ref_count: usize = 0;
    for (sub_args) |arg| {
        if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            quiet = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            const err_msg = try std.fmt.allocPrint(allocator, "error: unknown option: {s}\n", .{arg});
            defer allocator.free(err_msg);
            try platform_impl.writeStderr(err_msg);
            std.process.exit(1);
        } else if (std.mem.startsWith(u8, arg, "stash@{")) {
            ref_count += 1;
            if (ref_count > 1) {
                try platform_impl.writeStderr("error: Too many revisions specified: stash\n");
                std.process.exit(1);
            }
            stash_ref = arg;
        } else {
            ref_count += 1;
            if (ref_count > 1) {
                try platform_impl.writeStderr("error: Too many revisions specified: stash\n");
                std.process.exit(1);
            }
            // Accept plain numbers, reject other strings
            if (isDigitString(arg)) {
                stash_ref = arg;
            } else {
                const msg = try std.fmt.allocPrint(allocator, "error: '{s}' is not a stash-like commit\n", .{arg});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(1);
            }
        }
    }

    // Parse index
    const n = getStashDropIndex(stash_ref);

    // Get hash before dropping
    const stash_hash = resolveStashRef(allocator, git_path, stash_ref, platform_impl) catch {
        const msg = try std.fmt.allocPrint(allocator, "error: {s} is not a valid reference\n", .{stash_ref});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        std.process.exit(1);
    };
    defer allocator.free(stash_hash);

    stashDropByIndex(allocator, git_path, n, platform_impl) catch {
        try platform_impl.writeStderr("error: could not drop stash entry\n");
        std.process.exit(1);
    };

    if (!quiet) {
        if (succinct_mod.isEnabled()) {
            try platform_impl.writeStderr("ok stash drop\n");
        } else {
            const msg = try std.fmt.allocPrint(allocator, "Dropped {s} ({s})\n", .{ stash_ref, stash_hash });
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
        }
    }
}

fn stashDropByIndex(
    allocator: std.mem.Allocator,
    git_path: []const u8,
    n: u32,
    _: *const platform_mod.Platform,
) !void {
    const reflog_path = try std.fmt.allocPrint(allocator, "{s}/logs/refs/stash", .{git_path});
    defer allocator.free(reflog_path);

    const content = std.fs.cwd().readFileAlloc(allocator, reflog_path, 10 * 1024 * 1024) catch return error.NoStash;
    defer allocator.free(content);

    var lines = std.array_list.Managed([]const u8).init(allocator);
    defer lines.deinit();
    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |line| {
        if (line.len > 0) try lines.append(line);
    }

    if (lines.items.len == 0) return error.NoStash;
    if (n >= lines.items.len) return error.InvalidRef;

    const target_line = lines.items.len - 1 - n;
    // Get the "old" hash from the dropped line for reflog rewriting
    const dropped_line = lines.items[target_line];
    const dropped_old_hash = if (dropped_line.len >= 40) dropped_line[0..40] else null;
    _ = lines.orderedRemove(target_line);

    // Rewrite: update the "old" field of the line that follows the dropped one
    // (which is now at target_line position after removal)
    if (dropped_old_hash) |old_hash| {
        if (target_line < lines.items.len) {
            const next_line = lines.items[target_line];
            if (next_line.len >= 40) {
                // Replace the first 40 chars (old hash) with the dropped entry's old hash
                const new_line = try std.fmt.allocPrint(allocator, "{s}{s}", .{ old_hash, next_line[40..] });
                // We can't free the old line since it's a slice of content
                lines.items[target_line] = new_line;
            }
        }
    }

    if (lines.items.len == 0) {
        std.fs.cwd().deleteFile(reflog_path) catch {};
        const stash_ref_path = try std.fmt.allocPrint(allocator, "{s}/refs/stash", .{git_path});
        defer allocator.free(stash_ref_path);
        std.fs.cwd().deleteFile(stash_ref_path) catch {};
    } else {
        var new_content = std.array_list.Managed(u8).init(allocator);
        defer new_content.deinit();
        for (lines.items) |line| {
            try new_content.appendSlice(line);
            try new_content.append('\n');
        }

        const file = try std.fs.cwd().createFile(reflog_path, .{});
        defer file.close();
        try file.writeAll(new_content.items);

        // Update refs/stash to newest entry
        const last_line = lines.items[lines.items.len - 1];
        if (last_line.len >= 81) {
            const new_hash = last_line[41..81];
            const stash_ref_path = try std.fmt.allocPrint(allocator, "{s}/refs/stash", .{git_path});
            defer allocator.free(stash_ref_path);
            const ref_file = try std.fs.cwd().createFile(stash_ref_path, .{});
            defer ref_file.close();
            try ref_file.writeAll(new_hash);
            try ref_file.writeAll("\n");
        }
    }
}

// ============= stash clear =============

fn stashClear(allocator: std.mem.Allocator, git_path: []const u8) !void {
    const stash_ref = try std.fmt.allocPrint(allocator, "{s}/refs/stash", .{git_path});
    defer allocator.free(stash_ref);
    std.fs.cwd().deleteFile(stash_ref) catch {};
    const stash_log = try std.fmt.allocPrint(allocator, "{s}/logs/refs/stash", .{git_path});
    defer allocator.free(stash_log);
    std.fs.cwd().deleteFile(stash_log) catch {};
}

// ============= stash branch =============

fn stashBranch(
    allocator: std.mem.Allocator,
    git_path: []const u8,
    sub_args: []const []const u8,
    platform_impl: *const platform_mod.Platform,
) !void {
    if (sub_args.len < 1) {
        try platform_impl.writeStderr("error: No branch name specified\n");
        std.process.exit(1);
    }

    const branch_name = sub_args[0];
    if (sub_args.len > 2) {
        try platform_impl.writeStderr("error: Too many revisions specified: stash\n");
        std.process.exit(1);
    }
    const stash_ref = if (sub_args.len > 1) sub_args[1] else "stash@{0}";

    // Check if branch already exists
    const branch_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{branch_name});
    defer allocator.free(branch_ref);

    if (refs.resolveRef(git_path, branch_ref, platform_impl, allocator) catch null) |ex| {
        allocator.free(ex);
        const msg = try std.fmt.allocPrint(allocator, "fatal: a branch named '{s}' already exists\n", .{branch_name});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        std.process.exit(128);
    }

    const stash_hash = resolveStashRef(allocator, git_path, stash_ref, platform_impl) catch {
        const msg = try std.fmt.allocPrint(allocator, "error: {s} is not a valid reference\n", .{stash_ref});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        std.process.exit(1);
    };
    defer allocator.free(stash_hash);

    const parent_hash = getStashParent(allocator, git_path, stash_hash) catch {
        try platform_impl.writeStderr("error: invalid stash\n");
        std.process.exit(1);
    };
    defer allocator.free(parent_hash);

    // Create branch at stash parent
    refs.updateRef(git_path, branch_ref, parent_hash, platform_impl, allocator) catch {
        try platform_impl.writeStderr("error: could not create branch\n");
        std.process.exit(1);
    };

    // Checkout the branch
    helpers.checkoutCommitTree(git_path, parent_hash, allocator, platform_impl) catch {};

    // Update HEAD
    const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_path});
    defer allocator.free(head_path);
    const head_content = try std.fmt.allocPrint(allocator, "ref: {s}\n", .{branch_ref});
    defer allocator.free(head_content);
    const hf = std.fs.cwd().createFile(head_path, .{}) catch {
        try platform_impl.writeStderr("error: could not update HEAD\n");
        std.process.exit(1);
    };
    defer hf.close();
    hf.writeAll(head_content) catch {};

    // Apply stash with --index
    const apply_args = [_][]const u8{ "--index", stash_ref };
    stashApply(allocator, git_path, &apply_args, false, platform_impl) catch |err| {
        // If apply fails, don't drop the stash
        if (err == error.SystemResources) return err;
        std.process.exit(1);
    };

    // Drop the stash
    const drop_idx = getStashDropIndex(stash_ref);
    stashDropByIndex(allocator, git_path, drop_idx, platform_impl) catch {};
}

// ============= stash create =============

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

    // Collect all args as message
    var user_message: ?[]u8 = null;
    defer if (user_message) |m| allocator.free(m);

    if (sub_args.len > 0) {
        var msg_buf = std.array_list.Managed(u8).init(allocator);
        for (sub_args, 0..) |arg, idx| {
            if (idx > 0) try msg_buf.append(' ');
            try msg_buf.appendSlice(arg);
        }
        user_message = try msg_buf.toOwnedSlice();
    }

    const stash_hash = createStashCommit(
        allocator, git_path, head_hash, branch_name, user_message,
        false, false, &.{}, platform_impl,
        false,
    ) catch {
        std.process.exit(1);
    } orelse {
        // No changes - exit 0 with no output for 'create'
        return;
    };
    defer allocator.free(stash_hash);

    const output = try std.fmt.allocPrint(allocator, "{s}\n", .{stash_hash});
    defer allocator.free(output);
    try platform_impl.writeStdout(output);
}

// ============= stash store =============

fn stashStore(
    allocator: std.mem.Allocator,
    git_path: []const u8,
    sub_args: []const []const u8,
    platform_impl: *const platform_mod.Platform,
) !void {
    var message: ?[]const u8 = null;
    var commit_hash: ?[]const u8 = null;

    var i: usize = 0;
    while (i < sub_args.len) : (i += 1) {
        const arg = sub_args[i];
        if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--message")) {
            i += 1;
            if (i < sub_args.len) message = sub_args[i];
        } else if (std.mem.startsWith(u8, arg, "--message=")) {
            message = arg["--message=".len..];
        } else if (std.mem.startsWith(u8, arg, "-m") and arg.len > 2) {
            message = arg[2..];
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            // quiet
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            commit_hash = arg;
        }
    }

    const hash = commit_hash orelse {
        try platform_impl.writeStderr("error: git stash store requires one <commit> argument\n");
        std.process.exit(1);
    };

    // Validate it's a valid object
    _ = helpers.readGitObjectContent(git_path, hash, allocator) catch {
        const msg = try std.fmt.allocPrint(allocator, "error: {s} is not a valid object\n", .{hash});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        std.process.exit(1);
    };

    // Update refs/stash
    const old_stash_opt = refs.resolveRef(git_path, "refs/stash", platform_impl, allocator) catch null;
    const old_stash = (if (old_stash_opt) |o| o else null) orelse try allocator.dupe(u8, ZERO_HASH);
    defer allocator.free(old_stash);

    refs.updateRef(git_path, "refs/stash", hash, platform_impl, allocator) catch {
        try platform_impl.writeStderr("error: could not update refs/stash\n");
        std.process.exit(1);
    };

    const reflog_msg = message orelse "store";
    helpers.writeReflogEntry(git_path, "refs/stash", old_stash, hash, reflog_msg, allocator, platform_impl) catch {};
}
