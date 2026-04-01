const git_helpers_mod = @import("../git_helpers.zig");
// cherry_pick.zig - Git cherry-pick implementation
// Provides both cherry-pick utilities and the full cherry-pick command.

const std = @import("std");
const main_common = @import("../main_common.zig");
const succinct_mod = @import("../succinct.zig");
const objects = @import("objects.zig");
const refs = @import("refs.zig");
const index_mod = @import("index.zig");
const platform_mod = @import("../platform/platform.zig");
const Platform = platform_mod.Platform;

/// Extract the subject (first line) from a commit message
pub fn extractSubject(message: []const u8) []const u8 {
    const trimmed = std.mem.trimLeft(u8, message, " \t\n\r");
    if (std.mem.indexOfScalar(u8, trimmed, '\n')) |nl| {
        return trimmed[0..nl];
    }
    return trimmed;
}

/// Parse author info from a commit's author line
pub fn parseAuthorLine(author_line: []const u8) ?struct {
    name: []const u8,
    email: []const u8,
    date: []const u8,
} {
    const lt = std.mem.indexOfScalar(u8, author_line, '<') orelse return null;
    const gt = std.mem.indexOfScalar(u8, author_line, '>') orelse return null;
    if (gt <= lt) return null;

    const name = std.mem.trim(u8, author_line[0..lt], " \t");
    const email = author_line[lt + 1 .. gt];
    const date = std.mem.trim(u8, author_line[gt + 1 ..], " \t");

    return .{ .name = name, .email = email, .date = date };
}

const FileEntry = struct {
    sha1: [20]u8,
    mode: u32,
};

pub fn nativeCmdCherryPick(allocator: std.mem.Allocator, args: [][]const u8, command_index: usize, platform_impl: *const Platform) !void {
    const git_path = try git_helpers_mod.findGitDirectory(allocator, platform_impl);
    defer allocator.free(git_path);

    var positionals = std.array_list.Managed([]const u8).init(allocator);
    defer positionals.deinit();
    var no_commit = false;
    var allow_empty = false;
    var mainline_parent: ?u32 = null;

    var i: usize = command_index + 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--abort")) {
            try handleAbort(git_path, allocator, platform_impl);
            return;
        } else if (std.mem.eql(u8, arg, "--continue") or std.mem.eql(u8, arg, "--skip")) {
            cleanupMergeState(git_path, allocator, platform_impl);
            cleanupSequencerState(git_path, allocator, platform_impl);
            return;
        } else if (std.mem.eql(u8, arg, "--no-commit") or std.mem.eql(u8, arg, "-n")) {
            no_commit = true;
        } else if (std.mem.eql(u8, arg, "--no-edit") or std.mem.eql(u8, arg, "-x") or
            std.mem.eql(u8, arg, "--allow-empty") or std.mem.eql(u8, arg, "--allow-empty-message"))
        {
            if (std.mem.eql(u8, arg, "--allow-empty")) {
                allow_empty = true;
            }
            // accept but ignore most
        } else if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--mainline")) {
            i += 1;
            if (i >= args.len) {
                try platform_impl.writeStderr("error: option '-m' requires a value\n");
                std.process.exit(129);
            }
            const val = args[i];
            const num = std.fmt.parseInt(i32, val, 10) catch {
                const msg = try std.fmt.allocPrint(allocator, "error: switch `m' expects a numerical value\n", .{});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(129);
            };
            if (num < 1) {
                try platform_impl.writeStderr("error: switch `m' expects a numerical value\n");
                std.process.exit(129);
            }
            mainline_parent = @intCast(num);
        } else if (std.mem.startsWith(u8, arg, "-m") and arg.len > 2) {
            const val = arg[2..];
            const num = std.fmt.parseInt(i32, val, 10) catch {
                try platform_impl.writeStderr("error: switch `m' expects a numerical value\n");
                std.process.exit(129);
            };
            if (num < 1) {
                try platform_impl.writeStderr("error: switch `m' expects a numerical value\n");
                std.process.exit(129);
            }
            mainline_parent = @intCast(num);
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try positionals.append(arg);
        }
    }

    if (positionals.items.len == 0) {
        try platform_impl.writeStderr("fatal: no commit specified\n");
        std.process.exit(1);
    }

    // Save ORIG_HEAD
    {
        const ohp = try std.fmt.allocPrint(allocator, "{s}/ORIG_HEAD", .{git_path});
        defer allocator.free(ohp);
        if (refs.getCurrentCommit(git_path, platform_impl, allocator) catch null) |cur| {
            defer allocator.free(cur);
            platform_impl.fs.writeFile(ohp, cur) catch {};
        }
    }

    for (positionals.items) |commit_ref| {
        const commit_hash = git_helpers_mod.resolveRevision(git_path, commit_ref, platform_impl, allocator) catch {
            const msg = try std.fmt.allocPrint(allocator, "fatal: bad revision '{s}'\n", .{commit_ref});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
        };
        defer allocator.free(commit_hash);

        const new_hash = cherryPickCommit(git_path, commit_hash, no_commit, allocator, platform_impl, mainline_parent) catch |err| {
            if (err == error.MergeConflict) {
                // Write CHERRY_PICK_HEAD
                const cpp = try std.fmt.allocPrint(allocator, "{s}/CHERRY_PICK_HEAD", .{git_path});
                defer allocator.free(cpp);
                platform_impl.fs.writeFile(cpp, commit_hash) catch {};
                // Write MERGE_MSG
                const mmp = try std.fmt.allocPrint(allocator, "{s}/MERGE_MSG", .{git_path});
                defer allocator.free(mmp);
                if (getCommitMessage(git_path, commit_hash, allocator, platform_impl)) |cm| {
                    defer allocator.free(cm);
                    platform_impl.fs.writeFile(mmp, cm) catch {};
                } else |_| {}
                const sj = getCommitSubject(git_path, commit_hash, allocator, platform_impl) catch "";
                defer if (sj.len > 0) allocator.free(sj);
                const em = try std.fmt.allocPrint(allocator, "error: could not apply {s}... {s}\n", .{ commit_hash[0..@min(7, commit_hash.len)], sj });
                defer allocator.free(em);
                try platform_impl.writeStderr(em);
                std.process.exit(1);
            }
            return err;
        };
        defer allocator.free(new_hash);
        if (!no_commit) {
            try refs.updateHEADCommit(git_path, new_hash, platform_impl, allocator);
        }
        
        // Succinct mode: show success message
        if (succinct_mod.isEnabled()) {
            const subject = getCommitSubject(git_path, commit_hash, allocator, platform_impl) catch "";
            defer if (subject.len > 0) allocator.free(subject);
            const short_hash = if (commit_hash.len >= 7) commit_hash[0..7] else commit_hash;
            const msg = try std.fmt.allocPrint(allocator, "ok cherry-pick {s} \"{s}\"\n", .{ short_hash, subject });
            defer allocator.free(msg);
            try platform_impl.writeStdout(msg);
        }
    }
}

fn handleAbort(git_path: []const u8, allocator: std.mem.Allocator, platform_impl: *const Platform) !void {
    const ohp = try std.fmt.allocPrint(allocator, "{s}/ORIG_HEAD", .{git_path});
    defer allocator.free(ohp);
    if (platform_impl.fs.readFile(allocator, ohp)) |oc| {
        defer allocator.free(oc);
        const oh = std.mem.trim(u8, oc, " \t\n\r");
        if (oh.len == 40) {
            // Check if HEAD points to a branch
            const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_path});
            defer allocator.free(head_path);
            var branch_ref: ?[]const u8 = null;
            if (platform_impl.fs.readFile(allocator, head_path)) |hc| {
                defer allocator.free(hc);
                const ht = std.mem.trim(u8, hc, " \t\n\r");
                if (std.mem.startsWith(u8, ht, "ref: ")) {
                    branch_ref = allocator.dupe(u8, ht["ref: ".len..]) catch null;
                }
            } else |_| {}
            defer if (branch_ref) |br| allocator.free(br);
            if (branch_ref) |br| {
                refs.updateRef(git_path, br, oh, platform_impl, allocator) catch {};
            } else {
                refs.updateHEAD(git_path, oh, platform_impl, allocator) catch {};
            }
            resetToCommit(git_path, oh, allocator, platform_impl) catch {};
        }
    } else |_| {}
    cleanupMergeState(git_path, allocator, platform_impl);
    cleanupSequencerState(git_path, allocator, platform_impl);
}

fn cherryPickCommit(git_path: []const u8, commit_hash: []const u8, no_commit: bool, allocator: std.mem.Allocator, platform_impl: *const Platform, mainline_parent_opt: ?u32) ![]u8 {
    const mainline_parent = mainline_parent_opt;
    _ = no_commit;
    const commit_obj = try objects.GitObject.load(commit_hash, git_path, platform_impl, allocator);
    defer commit_obj.deinit(allocator);
    if (commit_obj.type != .commit) return error.NotACommit;

    var tree_hash: ?[]const u8 = null;
    var parent_hash: ?[]const u8 = null;
    var parent_hashes = std.array_list.Managed([]const u8).init(allocator);
    defer parent_hashes.deinit();
    var author_line: ?[]const u8 = null;
    var lines_iter = std.mem.splitSequence(u8, commit_obj.data, "\n");
    var header_end: usize = 0;
    var pos: usize = 0;

    while (lines_iter.next()) |line| {
        if (line.len == 0) {
            header_end = pos + 1;
            break;
        }
        if (std.mem.startsWith(u8, line, "tree ")) tree_hash = line["tree ".len..];
        if (std.mem.startsWith(u8, line, "parent ")) {
            try parent_hashes.append(line["parent ".len..]);
        }
        if (std.mem.startsWith(u8, line, "author ")) author_line = line["author ".len..];
        pos += line.len + 1;
    }

    // Handle merge commits: if commit has multiple parents, -m is required
    if (parent_hashes.items.len > 1 and mainline_parent == null) {
        const err_msg = try std.fmt.allocPrint(allocator, "error: commit {s} is a merge but no -m option was given.\n", .{commit_hash});
        defer allocator.free(err_msg);
        try platform_impl.writeStderr(err_msg);
        std.process.exit(1);
    }

    // Select parent based on -m option or default to first
    if (mainline_parent) |mp| {
        if (mp > parent_hashes.items.len) {
            const err_msg = try std.fmt.allocPrint(allocator, "error: commit {s} does not have parent {d}\n", .{ commit_hash, mp });
            defer allocator.free(err_msg);
            try platform_impl.writeStderr(err_msg);
            std.process.exit(1);
        }
        parent_hash = parent_hashes.items[mp - 1];
    } else if (parent_hashes.items.len > 0) {
        parent_hash = parent_hashes.items[0];
    }

    const commit_tree = tree_hash orelse return error.InvalidCommit;
    const original_author = author_line orelse return error.InvalidCommit;
    const commit_message = if (header_end < commit_obj.data.len) commit_obj.data[header_end..] else "";

    const current_hash = (try refs.getCurrentCommit(git_path, platform_impl, allocator)) orelse return error.NoHead;
    defer allocator.free(current_hash);

    // Fast-forward optimization: if the commit's parent is current HEAD
    if (parent_hash) |ph| {
        if (std.mem.eql(u8, ph, current_hash)) {
            const repo_root = std.fs.path.dirname(git_path) orelse ".";
            updateIndexFromTree(git_path, commit_tree, allocator, platform_impl) catch {};
            const t_obj = objects.GitObject.load(commit_tree, git_path, platform_impl, allocator) catch return error.InvalidCommit;
            defer t_obj.deinit(allocator);
            if (t_obj.type == .tree) {
                clearTrackedFiles(git_path, repo_root, allocator, platform_impl) catch {};
                checkoutTreeRecursive(git_path, t_obj.data, repo_root, "", allocator, platform_impl) catch {};
            }
            return try allocator.dupe(u8, commit_hash);
        }
    }

    const current_tree = try getCommitTree(git_path, current_hash, allocator, platform_impl);
    defer allocator.free(current_tree);

    const base_tree = if (parent_hash) |ph|
        getCommitTree(git_path, ph, allocator, platform_impl) catch try allocator.dupe(u8, current_tree)
    else
        try allocator.dupe(u8, current_tree);
    defer allocator.free(base_tree);

    var new_tree: []u8 = undefined;
    if (std.mem.eql(u8, base_tree, current_tree)) {
        // base == ours, result is just theirs
        new_tree = try allocator.dupe(u8, commit_tree);
        const repo_root = std.fs.path.dirname(git_path) orelse ".";
        clearTrackedFiles(git_path, repo_root, allocator, platform_impl) catch {};
        const t_obj = objects.GitObject.load(commit_tree, git_path, platform_impl, allocator) catch return error.InvalidCommit;
        defer t_obj.deinit(allocator);
        if (t_obj.type == .tree) {
            checkoutTreeRecursive(git_path, t_obj.data, repo_root, "", allocator, platform_impl) catch {};
        }
        updateIndexFromTree(git_path, commit_tree, allocator, platform_impl) catch {};
    } else if (std.mem.eql(u8, base_tree, commit_tree)) {
        new_tree = try allocator.dupe(u8, current_tree);
    } else if (std.mem.eql(u8, current_tree, commit_tree)) {
        new_tree = try allocator.dupe(u8, current_tree);
    } else {
        // Real 3-way merge
        const merge_result = try threeWayMerge(git_path, base_tree, current_tree, commit_tree, commit_hash, allocator, platform_impl);
        if (merge_result.has_conflicts) {
            return error.MergeConflict;
        }
        new_tree = merge_result.tree_hash;
    }
    defer allocator.free(new_tree);

    const committer_line = getCommitterString(allocator) catch try allocator.dupe(u8, "Unknown <unknown> 0 +0000");
    defer allocator.free(committer_line);

    const parents = [_][]const u8{current_hash};
    const new_commit = try objects.createCommitObject(new_tree, &parents, original_author, committer_line, commit_message, allocator);
    defer new_commit.deinit(allocator);
    return try new_commit.store(git_path, platform_impl, allocator);
}

const MergeResult = struct {
    has_conflicts: bool,
    tree_hash: []u8,
};

fn threeWayMerge(git_path: []const u8, base_tree: []const u8, ours_tree: []const u8, theirs_tree: []const u8, theirs_commit: []const u8, allocator: std.mem.Allocator, platform_impl: *const Platform) !MergeResult {
    var base_entries = std.StringHashMap(FileEntry).init(allocator);
    defer base_entries.deinit();
    var ours_entries = std.StringHashMap(FileEntry).init(allocator);
    defer ours_entries.deinit();
    var theirs_entries = std.StringHashMap(FileEntry).init(allocator);
    defer theirs_entries.deinit();

    try collectTreeEntriesFlat(git_path, base_tree, "", &base_entries, allocator, platform_impl);
    try collectTreeEntriesFlat(git_path, ours_tree, "", &ours_entries, allocator, platform_impl);
    try collectTreeEntriesFlat(git_path, theirs_tree, "", &theirs_entries, allocator, platform_impl);

    var idx = index_mod.Index.init(allocator);
    defer idx.deinit();
    const repo_root = std.fs.path.dirname(git_path) orelse ".";
    var has_conflicts = false;

    // Remove old tracked files first
    clearTrackedFiles(git_path, repo_root, allocator, platform_impl) catch {};

    // Collect all paths
    var all_paths = std.StringHashMap(void).init(allocator);
    defer all_paths.deinit();
    {
        var it = base_entries.iterator();
        while (it.next()) |e| all_paths.put(e.key_ptr.*, {}) catch {};
    }
    {
        var it = ours_entries.iterator();
        while (it.next()) |e| all_paths.put(e.key_ptr.*, {}) catch {};
    }
    {
        var it = theirs_entries.iterator();
        while (it.next()) |e| all_paths.put(e.key_ptr.*, {}) catch {};
    }

    var paths_it = all_paths.iterator();
    while (paths_it.next()) |path_entry| {
        const path = path_entry.key_ptr.*;
        const base = base_entries.get(path);
        const ours = ours_entries.get(path);
        const theirs = theirs_entries.get(path);

        if (ours != null and theirs != null) {
            if (std.mem.eql(u8, &ours.?.sha1, &theirs.?.sha1)) {
                try addIndexEntry(&idx, path, ours.?.sha1, ours.?.mode, repo_root, allocator);
                try writeFileFromBlob(git_path, repo_root, path, &ours.?.sha1, allocator, platform_impl);
            } else if (base != null and std.mem.eql(u8, &base.?.sha1, &theirs.?.sha1)) {
                try addIndexEntry(&idx, path, ours.?.sha1, ours.?.mode, repo_root, allocator);
                try writeFileFromBlob(git_path, repo_root, path, &ours.?.sha1, allocator, platform_impl);
            } else if (base != null and std.mem.eql(u8, &base.?.sha1, &ours.?.sha1)) {
                try addIndexEntry(&idx, path, theirs.?.sha1, theirs.?.mode, repo_root, allocator);
                try writeFileFromBlob(git_path, repo_root, path, &theirs.?.sha1, allocator, platform_impl);
            } else {
                // Conflict
                has_conflicts = true;
                // Write conflict markers
                const ours_content = loadBlobContent(git_path, &ours.?.sha1, allocator, platform_impl);
                defer if (ours_content) |c| allocator.free(c);
                const theirs_content = loadBlobContent(git_path, &theirs.?.sha1, allocator, platform_impl);
                defer if (theirs_content) |c| allocator.free(c);
                const base_content = if (base) |b| loadBlobContent(git_path, &b.sha1, allocator, platform_impl) else null;
                defer if (base_content) |c| allocator.free(c);

                // Try content merge
                if (base_content) |bc| {
                    if (ours_content) |oc| {
                        if (theirs_content) |tc| {
                            if (tryContentMerge(bc, oc, tc, allocator)) |merged| {
                                defer allocator.free(merged);
                                // Clean merge
                                has_conflicts = false;
                                const blob_hash = writeBlob(git_path, merged, allocator, platform_impl) catch continue;
                                try addIndexEntry(&idx, path, blob_hash, ours.?.mode, repo_root, allocator);
                                const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, path });
                                defer allocator.free(full_path);
                                if (std.fs.path.dirname(full_path)) |d| std.fs.cwd().makePath(d) catch {};
                                platform_impl.fs.writeFile(full_path, merged) catch {};
                                continue;
                            }
                        }
                    }
                }

                // Write conflict file
                var conflict = std.array_list.Managed(u8).init(allocator);
                defer conflict.deinit();
                conflict.appendSlice("<<<<<<< HEAD\n") catch {};
                if (ours_content) |c| conflict.appendSlice(c) catch {};
                if (ours_content) |c| {
                    if (c.len > 0 and c[c.len - 1] != '\n') conflict.append('\n') catch {};
                }
                conflict.appendSlice("=======\n") catch {};
                if (theirs_content) |c| conflict.appendSlice(c) catch {};
                if (theirs_content) |c| {
                    if (c.len > 0 and c[c.len - 1] != '\n') conflict.append('\n') catch {};
                }
                // Use short hash and subject for the conflict marker
                const short_hash = theirs_commit[0..@min(7, theirs_commit.len)];
                const subject = getCommitSubject(git_path, theirs_commit, allocator, platform_impl) catch "";
                defer if (subject.len > 0) allocator.free(subject);
                const marker = std.fmt.allocPrint(allocator, ">>>>>>> {s} ({s})\n", .{ short_hash, subject }) catch ">>>>>>> theirs\n";
                defer if (marker.len > ">>>>>>> theirs\n".len) allocator.free(marker);
                conflict.appendSlice(marker) catch {};

                const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, path });
                defer allocator.free(full_path);
                if (std.fs.path.dirname(full_path)) |d| std.fs.cwd().makePath(d) catch {};
                platform_impl.fs.writeFile(full_path, conflict.items) catch {};

                if (base) |b| {
                    addIndexEntryStaged(&idx, path, b.sha1, b.mode, repo_root, allocator, 1) catch {};
                }
                addIndexEntryStaged(&idx, path, ours.?.sha1, ours.?.mode, repo_root, allocator, 2) catch {};
                addIndexEntryStaged(&idx, path, theirs.?.sha1, theirs.?.mode, repo_root, allocator, 3) catch {};
            }
        } else if (ours != null and theirs == null) {
            if (base != null and std.mem.eql(u8, &base.?.sha1, &ours.?.sha1)) {
                // Deleted in theirs, unchanged in ours - delete
            } else if (base == null) {
                try addIndexEntry(&idx, path, ours.?.sha1, ours.?.mode, repo_root, allocator);
                try writeFileFromBlob(git_path, repo_root, path, &ours.?.sha1, allocator, platform_impl);
            } else {
                // Modified in ours, deleted in theirs - keep ours (conflict)
                has_conflicts = true;
                try addIndexEntry(&idx, path, ours.?.sha1, ours.?.mode, repo_root, allocator);
                try writeFileFromBlob(git_path, repo_root, path, &ours.?.sha1, allocator, platform_impl);
            }
        } else if (ours == null and theirs != null) {
            if (base != null and std.mem.eql(u8, &base.?.sha1, &theirs.?.sha1)) {
                // Deleted in ours, unchanged in theirs - delete
            } else if (base == null) {
                try addIndexEntry(&idx, path, theirs.?.sha1, theirs.?.mode, repo_root, allocator);
                try writeFileFromBlob(git_path, repo_root, path, &theirs.?.sha1, allocator, platform_impl);
            } else {
                // Deleted in ours, modified in theirs - add theirs
                try addIndexEntry(&idx, path, theirs.?.sha1, theirs.?.mode, repo_root, allocator);
                try writeFileFromBlob(git_path, repo_root, path, &theirs.?.sha1, allocator, platform_impl);
            }
        }
    }

    idx.save(git_path, platform_impl) catch {};

    // Build the tree directly from our collected entries
    var tree_entries_list = std.array_list.Managed(objects.TreeEntry).init(allocator);
    defer {
        for (tree_entries_list.items) |te| te.deinit(allocator);
        tree_entries_list.deinit();
    }

    for (idx.entries.items) |entry| {
        // Skip staged (conflict) entries
        if ((entry.flags >> 12) & 0x3 != 0) continue;
        var hex: [40]u8 = undefined;
        for (entry.sha1, 0..) |b, bi| {
            const hx = "0123456789abcdef";
            hex[bi * 2] = hx[b >> 4];
            hex[bi * 2 + 1] = hx[b & 0xf];
        }
        const mode_str = if (entry.mode == 0o100755) "100755" else if (entry.mode == 0o120000) "120000" else "100644";
        try tree_entries_list.append(objects.TreeEntry{
            .mode = try allocator.dupe(u8, mode_str),
            .name = try allocator.dupe(u8, entry.path),
            .hash = try allocator.dupe(u8, &hex),
        });
    }

    const tree_obj = try objects.createTreeObject(tree_entries_list.items, allocator);
    defer tree_obj.deinit(allocator);
    const tree_hash = try tree_obj.store(git_path, platform_impl, allocator);

    return MergeResult{ .has_conflicts = has_conflicts, .tree_hash = tree_hash };
}

fn tryContentMerge(base: []const u8, ours: []const u8, theirs: []const u8, allocator: std.mem.Allocator) ?[]u8 {
    if (std.mem.eql(u8, base, ours)) return allocator.dupe(u8, theirs) catch null;
    if (std.mem.eql(u8, base, theirs)) return allocator.dupe(u8, ours) catch null;
    if (std.mem.eql(u8, ours, theirs)) return allocator.dupe(u8, ours) catch null;
    return null;
}

fn loadBlobContent(git_path: []const u8, sha1: *const [20]u8, allocator: std.mem.Allocator, platform_impl: *const Platform) ?[]u8 {
    var hex: [40]u8 = undefined;
    for (sha1.*, 0..) |b, bi| {
        const h = "0123456789abcdef";
        hex[bi * 2] = h[b >> 4];
        hex[bi * 2 + 1] = h[b & 0xf];
    }
    const obj = objects.GitObject.load(&hex, git_path, platform_impl, allocator) catch return null;
    defer obj.deinit(allocator);
    if (obj.type != .blob) return null;
    return allocator.dupe(u8, obj.data) catch null;
}

fn writeBlob(git_path: []const u8, content: []const u8, allocator: std.mem.Allocator, platform_impl: *const Platform) ![20]u8 {
    const blob = try objects.createBlobObject(content, allocator);
    defer blob.deinit(allocator);
    const hash_hex = try blob.store(git_path, platform_impl, allocator);
    defer allocator.free(hash_hex);
    var result: [20]u8 = undefined;
    for (0..20) |bi| {
        result[bi] = std.fmt.parseInt(u8, hash_hex[bi * 2 .. bi * 2 + 2], 16) catch 0;
    }
    return result;
}

fn getCommitTree(git_path: []const u8, commit_hash: []const u8, allocator: std.mem.Allocator, platform_impl: *const Platform) ![]u8 {
    const commit_obj = try objects.GitObject.load(commit_hash, git_path, platform_impl, allocator);
    defer commit_obj.deinit(allocator);
    if (commit_obj.type != .commit) return error.NotACommit;
    var lines = std.mem.splitSequence(u8, commit_obj.data, "\n");
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "tree ")) {
            return try allocator.dupe(u8, line["tree ".len..]);
        }
        if (line.len == 0) break;
    }
    return error.InvalidCommit;
}

fn getCommitMessage(git_path: []const u8, commit_hash: []const u8, allocator: std.mem.Allocator, platform_impl: *const Platform) ![]u8 {
    const commit_obj = try objects.GitObject.load(commit_hash, git_path, platform_impl, allocator);
    defer commit_obj.deinit(allocator);
    if (commit_obj.type != .commit) return error.NotACommit;
    if (std.mem.indexOf(u8, commit_obj.data, "\n\n")) |idx| {
        return try allocator.dupe(u8, commit_obj.data[idx + 2 ..]);
    }
    return error.InvalidCommit;
}

fn getCommitSubject(git_path: []const u8, commit_hash: []const u8, allocator: std.mem.Allocator, platform_impl: *const Platform) ![]u8 {
    const msg = try getCommitMessage(git_path, commit_hash, allocator, platform_impl);
    defer allocator.free(msg);
    const trimmed = std.mem.trimLeft(u8, msg, " \t\n\r");
    if (std.mem.indexOfScalar(u8, trimmed, '\n')) |nl| {
        return try allocator.dupe(u8, trimmed[0..nl]);
    }
    return try allocator.dupe(u8, trimmed);
}

fn collectTreeEntriesFlat(git_path: []const u8, tree_hash: []const u8, prefix: []const u8, map: *std.StringHashMap(FileEntry), allocator: std.mem.Allocator, platform_impl: *const Platform) !void {
    const tree_obj = try objects.GitObject.load(tree_hash, git_path, platform_impl, allocator);
    defer tree_obj.deinit(allocator);

    var pos: usize = 0;
    while (pos < tree_obj.data.len) {
        const space_pos = std.mem.indexOfScalarPos(u8, tree_obj.data, pos, ' ') orelse break;
        const mode_str = tree_obj.data[pos..space_pos];
        const null_pos = std.mem.indexOfScalarPos(u8, tree_obj.data, space_pos, 0) orelse break;
        const name = tree_obj.data[space_pos + 1 .. null_pos];
        if (null_pos + 21 > tree_obj.data.len) break;
        const sha1_bytes = tree_obj.data[null_pos + 1 .. null_pos + 21];

        var hex_hash: [40]u8 = undefined;
        for (sha1_bytes, 0..) |b, bi| {
            const h = "0123456789abcdef";
            hex_hash[bi * 2] = h[b >> 4];
            hex_hash[bi * 2 + 1] = h[b & 0xf];
        }

        const full_name = if (prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, name })
        else
            try allocator.dupe(u8, name);

        if (std.mem.eql(u8, mode_str, "40000")) {
            defer allocator.free(full_name);
            try collectTreeEntriesFlat(git_path, &hex_hash, full_name, map, allocator, platform_impl);
        } else {
            const mode: u32 = if (std.mem.eql(u8, mode_str, "100755")) 0o100755 else if (std.mem.eql(u8, mode_str, "120000")) 0o120000 else 0o100644;
            try map.put(full_name, FileEntry{ .sha1 = sha1_bytes[0..20].*, .mode = mode });
        }
        pos = null_pos + 21;
    }
}

fn writeFileFromBlob(git_path: []const u8, repo_root: []const u8, path: []const u8, sha1: *const [20]u8, allocator: std.mem.Allocator, platform_impl: *const Platform) !void {
    var hex: [40]u8 = undefined;
    for (sha1.*, 0..) |b, bi| {
        const h = "0123456789abcdef";
        hex[bi * 2] = h[b >> 4];
        hex[bi * 2 + 1] = h[b & 0xf];
    }
    const obj = try objects.GitObject.load(&hex, git_path, platform_impl, allocator);
    defer obj.deinit(allocator);
    if (obj.type != .blob) return;
    const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, path });
    defer allocator.free(full_path);
    if (std.fs.path.dirname(full_path)) |d| {
        std.fs.cwd().makePath(d) catch {};
    }
    try platform_impl.fs.writeFile(full_path, obj.data);
}

fn addIndexEntry(idx: *index_mod.Index, path: []const u8, sha1: [20]u8, mode: u32, repo_root: []const u8, allocator: std.mem.Allocator) !void {
    try addIndexEntryStaged(idx, path, sha1, mode, repo_root, allocator, 0);
}

fn addIndexEntryStaged(idx: *index_mod.Index, path: []const u8, sha1: [20]u8, mode: u32, repo_root: []const u8, allocator: std.mem.Allocator, stage: u2) !void {
    const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, path });
    defer allocator.free(full_path);
    const stat = std.fs.cwd().statFile(full_path) catch std.fs.File.Stat{
        .inode = 0,
        .size = 0,
        .mode = @intCast(mode),
        .mtime = 0,
        .ctime = 0,
        .atime = 0,
        .kind = .file,
    };

    const path_copy = try allocator.dupe(u8, path);
    const entry = index_mod.IndexEntry{
        .ctime_sec = @intCast(@divFloor(stat.ctime, 1_000_000_000)),
        .ctime_nsec = @intCast(@mod(stat.ctime, 1_000_000_000)),
        .mtime_sec = @intCast(@divFloor(stat.mtime, 1_000_000_000)),
        .mtime_nsec = @intCast(@mod(stat.mtime, 1_000_000_000)),
        .dev = 0,
        .ino = @truncate(stat.inode),
        .mode = mode,
        .uid = 0,
        .gid = 0,
        .size = @intCast(stat.size),
        .sha1 = sha1,
        .flags = @as(u16, @intCast(@min(path_copy.len, 0xFFF))) | (@as(u16, @intCast(stage)) << 12),
        .extended_flags = null,
        .path = path_copy,
    };
    // Remove existing entries for this path
    var j: usize = 0;
    while (j < idx.entries.items.len) {
        if (std.mem.eql(u8, idx.entries.items[j].path, path)) {
            _ = idx.entries.orderedRemove(j);
        } else {
            j += 1;
        }
    }
    idx.entries.append(entry) catch {};
}

fn updateIndexFromTree(git_path: []const u8, tree_hash: []const u8, allocator: std.mem.Allocator, platform_impl: *const Platform) !void {
    var entries = std.StringHashMap(FileEntry).init(allocator);
    defer {
        var it = entries.iterator();
        while (it.next()) |e| allocator.free(e.key_ptr.*);
        entries.deinit();
    }
    try collectTreeEntriesFlat(git_path, tree_hash, "", &entries, allocator, platform_impl);

    const repo_root = std.fs.path.dirname(git_path) orelse ".";
    var idx = index_mod.Index.init(allocator);
    defer idx.deinit();

    var it = entries.iterator();
    while (it.next()) |e| {
        try addIndexEntry(&idx, e.key_ptr.*, e.value_ptr.sha1, e.value_ptr.mode, repo_root, allocator);
    }
    idx.save(git_path, platform_impl) catch {};
}

fn writeTreeFromIndex(allocator: std.mem.Allocator, idx: *index_mod.Index, git_path: []const u8, platform_impl: *const Platform) ![]u8 {
    // Build tree from index entries (single level for now, supporting subdirectories)
    var dirs = std.StringHashMap(std.array_list.Managed(index_mod.IndexEntry)).init(allocator);
    defer {
        var it = dirs.iterator();
        while (it.next()) |e| {
            if (e.key_ptr.*.len > 0) allocator.free(e.key_ptr.*);
            e.value_ptr.deinit();
        }
        dirs.deinit();
    }

    for (idx.entries.items) |entry| {
        // Skip staged entries (conflict markers)
        if ((entry.flags >> 12) & 0x3 != 0) continue;

        const dir = if (std.mem.lastIndexOfScalar(u8, entry.path, '/')) |slash|
            entry.path[0..slash]
        else
            "";
        const gop = try dirs.getOrPut(if (dir.len > 0) try allocator.dupe(u8, dir) else "");
        if (!gop.found_existing) {
            gop.value_ptr.* = std.array_list.Managed(index_mod.IndexEntry).init(allocator);
        }
        try gop.value_ptr.append(entry);
    }

    return try writeTreeForDir(allocator, &dirs, "", git_path, platform_impl);
}

fn writeTreeForDir(allocator: std.mem.Allocator, dirs: *std.StringHashMap(std.array_list.Managed(index_mod.IndexEntry)), prefix: []const u8, git_path: []const u8, platform_impl: *const Platform) ![]u8 {
    var tree_buf = std.array_list.Managed(u8).init(allocator);
    defer tree_buf.deinit();

    // Collect subdirectory names at this level
    var subdirs = std.StringHashMap(void).init(allocator);
    defer {
        var it = subdirs.iterator();
        while (it.next()) |e| allocator.free(e.key_ptr.*);
        subdirs.deinit();
    }

    var dit = dirs.iterator();
    while (dit.next()) |de| {
        const dir = de.key_ptr.*;
        if (prefix.len == 0) {
            if (dir.len > 0) {
                const slash = std.mem.indexOfScalar(u8, dir, '/') orelse dir.len;
                const sub = dir[0..slash];
                if (!subdirs.contains(sub)) {
                    try subdirs.put(try allocator.dupe(u8, sub), {});
                }
            }
        } else if (std.mem.startsWith(u8, dir, prefix) and dir.len > prefix.len and dir[prefix.len] == '/') {
            const rest = dir[prefix.len + 1 ..];
            const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
            const sub = rest[0..slash];
            if (!subdirs.contains(sub)) {
                try subdirs.put(try allocator.dupe(u8, sub), {});
            }
        }
    }

    // Collect all entries: files at this level + subdirectories
    const TreeEntry = struct { name: []const u8, mode: u32, sha1: [20]u8 };
    var entries = std.array_list.Managed(TreeEntry).init(allocator);
    defer entries.deinit();

    // Add files at this level
    if (dirs.get(prefix)) |file_list| {
        for (file_list.items) |entry| {
            const basename = if (std.mem.lastIndexOfScalar(u8, entry.path, '/')) |slash|
                entry.path[slash + 1 ..]
            else
                entry.path;
            try entries.append(.{ .name = basename, .mode = entry.mode, .sha1 = entry.sha1 });
        }
    }

    // Add subdirectories
    var sit = subdirs.iterator();
    while (sit.next()) |se| {
        const sub_name = se.key_ptr.*;
        const sub_prefix = if (prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, sub_name })
        else
            try allocator.dupe(u8, sub_name);
        defer allocator.free(sub_prefix);
        const sub_tree_hash = try writeTreeForDir(allocator, dirs, sub_prefix, git_path, platform_impl);
        defer allocator.free(sub_tree_hash);
        // Convert hex hash to bytes
        var sha1: [20]u8 = undefined;
        for (0..20) |bi| {
            sha1[bi] = std.fmt.parseInt(u8, sub_tree_hash[bi * 2 .. bi * 2 + 2], 16) catch 0;
        }
        try entries.append(.{ .name = sub_name, .mode = 0o40000, .sha1 = sha1 });
    }

    // Sort entries by name (git tree sorting)
    std.mem.sort(TreeEntry, entries.items, {}, struct {
        fn lessThan(_: void, a: TreeEntry, b: TreeEntry) bool {
            // Git sorts tree entries by name, with directories getting a trailing /
            const a_name = a.name;
            const b_name = b.name;
            const a_is_tree = a.mode == 0o40000;
            const b_is_tree = b.mode == 0o40000;
            if (a_is_tree == b_is_tree) {
                return std.mem.order(u8, a_name, b_name) == .lt;
            }
            // Compare as if trees have trailing /
            const min_len = @min(a_name.len, b_name.len);
            const cmp = std.mem.order(u8, a_name[0..min_len], b_name[0..min_len]);
            if (cmp != .eq) return cmp == .lt;
            if (a_name.len == b_name.len) return false;
            if (a_name.len == min_len) {
                if (a_is_tree) return '/' < b_name[min_len];
                return true;
            }
            if (b_is_tree) return a_name[min_len] < '/';
            return false;
        }
    }.lessThan);

    // Build TreeEntry list for objects.createTreeObject
    var tree_entries = std.array_list.Managed(objects.TreeEntry).init(allocator);
    defer {
        for (tree_entries.items) |te| te.deinit(allocator);
        tree_entries.deinit();
    }

    for (entries.items) |entry| {
        const mode_str_src = if (entry.mode == 0o40000) "40000" else if (entry.mode == 0o100755) "100755" else if (entry.mode == 0o120000) "120000" else "100644";
        var hex_hash: [40]u8 = undefined;
        for (entry.sha1, 0..) |b, bi| {
            const hx = "0123456789abcdef";
            hex_hash[bi * 2] = hx[b >> 4];
            hex_hash[bi * 2 + 1] = hx[b & 0xf];
        }
        try tree_entries.append(objects.TreeEntry{
            .mode = try allocator.dupe(u8, mode_str_src),
            .name = try allocator.dupe(u8, entry.name),
            .hash = try allocator.dupe(u8, &hex_hash),
        });
    }

    // Create tree object
    const tree_obj = try objects.createTreeObject(tree_entries.items, allocator);
    defer tree_obj.deinit(allocator);
    return try tree_obj.store(git_path, platform_impl, allocator);
}

fn clearTrackedFiles(git_path: []const u8, repo_root: []const u8, allocator: std.mem.Allocator, platform_impl: *const Platform) !void {
    var idx = index_mod.Index.load(git_path, platform_impl, allocator) catch return;
    defer idx.deinit();
    for (idx.entries.items) |entry| {
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, entry.path });
        defer allocator.free(full_path);
        std.fs.cwd().deleteFile(full_path) catch {};
    }
}

fn checkoutTreeRecursive(git_path: []const u8, tree_data: []const u8, repo_root: []const u8, current_path: []const u8, allocator: std.mem.Allocator, platform_impl: *const Platform) !void {
    var pos: usize = 0;
    while (pos < tree_data.len) {
        const space_pos = std.mem.indexOfScalarPos(u8, tree_data, pos, ' ') orelse break;
        const mode_str = tree_data[pos..space_pos];
        const null_pos = std.mem.indexOfScalarPos(u8, tree_data, space_pos, 0) orelse break;
        const name = tree_data[space_pos + 1 .. null_pos];
        if (null_pos + 21 > tree_data.len) break;
        const sha1_bytes = tree_data[null_pos + 1 .. null_pos + 21];
        pos = null_pos + 21;

        var hex_hash: [40]u8 = undefined;
        for (sha1_bytes, 0..) |b, bi| {
            const h = "0123456789abcdef";
            hex_hash[bi * 2] = h[b >> 4];
            hex_hash[bi * 2 + 1] = h[b & 0xf];
        }

        const sub_path = if (current_path.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ current_path, name })
        else
            try allocator.dupe(u8, name);
        defer allocator.free(sub_path);

        if (std.mem.eql(u8, mode_str, "40000")) {
            const sub_tree = objects.GitObject.load(&hex_hash, git_path, platform_impl, allocator) catch continue;
            defer sub_tree.deinit(allocator);
            if (sub_tree.type == .tree) {
                try checkoutTreeRecursive(git_path, sub_tree.data, repo_root, sub_path, allocator, platform_impl);
            }
        } else {
            const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, sub_path });
            defer allocator.free(full_path);
            if (std.fs.path.dirname(full_path)) |d| {
                std.fs.cwd().makePath(d) catch {};
            }
            const blob_obj = objects.GitObject.load(&hex_hash, git_path, platform_impl, allocator) catch continue;
            defer blob_obj.deinit(allocator);
            if (blob_obj.type == .blob) {
                platform_impl.fs.writeFile(full_path, blob_obj.data) catch {};
                // Set executable permission if needed
                if (std.mem.eql(u8, mode_str, "100755")) {
                    const file = std.fs.cwd().openFile(full_path, .{ .mode = .read_write }) catch continue;
                    defer file.close();
                    file.chmod(0o755) catch {};
                }
            }
        }
    }
}

fn cleanupMergeState(git_path: []const u8, allocator: std.mem.Allocator, platform_impl: *const Platform) void {
    _ = platform_impl;
    const state_files = [_][]const u8{
        "MERGE_HEAD", "MERGE_MSG", "MERGE_MODE", "SQUASH_MSG",
        "CHERRY_PICK_HEAD", "REVERT_HEAD",
    };
    for (state_files) |name| {
        const path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_path, name }) catch continue;
        defer allocator.free(path);
        std.fs.cwd().deleteFile(path) catch {};
    }
}

fn resetToCommit(git_path: []const u8, commit_hash: []const u8, allocator: std.mem.Allocator, platform_impl: *const Platform) !void {
    // Update index from the commit's tree
    const tree_hash = try getCommitTree(git_path, commit_hash, allocator, platform_impl);
    defer allocator.free(tree_hash);
    try updateIndexFromTree(git_path, tree_hash, allocator, platform_impl);
    // Checkout working tree
    const repo_root = std.fs.path.dirname(git_path) orelse ".";
    clearTrackedFiles(git_path, repo_root, allocator, platform_impl) catch {};
    const t_obj = try objects.GitObject.load(tree_hash, git_path, platform_impl, allocator);
    defer t_obj.deinit(allocator);
    if (t_obj.type == .tree) {
        try checkoutTreeRecursive(git_path, t_obj.data, repo_root, "", allocator, platform_impl);
    }
}

fn getCommitterString(allocator: std.mem.Allocator) ![]u8 {
    const name = std.process.getEnvVarOwned(allocator, "GIT_COMMITTER_NAME") catch
        std.process.getEnvVarOwned(allocator, "GIT_AUTHOR_NAME") catch
        try allocator.dupe(u8, "Unknown");
    defer allocator.free(name);
    const email = std.process.getEnvVarOwned(allocator, "GIT_COMMITTER_EMAIL") catch
        std.process.getEnvVarOwned(allocator, "GIT_AUTHOR_EMAIL") catch
        try allocator.dupe(u8, "unknown@unknown");
    defer allocator.free(email);

    // Get timestamp
    const date_str = std.process.getEnvVarOwned(allocator, "GIT_COMMITTER_DATE") catch null;
    defer if (date_str) |d| allocator.free(d);

    if (date_str) |ds| {
        // Try to parse @ prefix format
        if (ds.len > 0 and ds[0] == '@') {
            return try std.fmt.allocPrint(allocator, "{s} <{s}> {s}", .{ name, email, ds[1..] });
        }
        return try std.fmt.allocPrint(allocator, "{s} <{s}> {s}", .{ name, email, ds });
    }

    // Use current time
    const timestamp = std.time.timestamp();
    return try std.fmt.allocPrint(allocator, "{s} <{s}> {d} +0000", .{ name, email, timestamp });
}

fn cleanupSequencerState(git_path: []const u8, allocator: std.mem.Allocator, platform_impl: *const Platform) void {
    _ = platform_impl;
    const names = [_][]const u8{ "todo", "abort-safety", "head", "opts" };
    for (names) |name| {
        const fp = std.fmt.allocPrint(allocator, "{s}/sequencer/{s}", .{ git_path, name }) catch continue;
        defer allocator.free(fp);
        std.fs.cwd().deleteFile(fp) catch {};
    }
}

test "extractSubject" {
    const testing = std.testing;
    try testing.expectEqualStrings("Hello world", extractSubject("Hello world\n\nBody text"));
    try testing.expectEqualStrings("Single line", extractSubject("Single line"));
    try testing.expectEqualStrings("Trimmed", extractSubject("\n\nTrimmed"));
}

test "parseAuthorLine" {
    const testing = std.testing;
    const result = parseAuthorLine("Test User <test@example.com> 1234567890 +0000").?;
    try testing.expectEqualStrings("Test User", result.name);
    try testing.expectEqualStrings("test@example.com", result.email);
    try testing.expectEqualStrings("1234567890 +0000", result.date);
}
