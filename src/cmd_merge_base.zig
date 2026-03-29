// Auto-generated from main_common.zig - cmd_merge_base
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

pub fn nativeCmdMergeBase(allocator: std.mem.Allocator, args: [][]const u8, command_index: usize, platform_impl: *const platform_mod.Platform) !void {
    var all_mode = false;
    var is_ancestor = false;
    var independent = false;
    var fork_point = false;
    var octopus = false;
    var commits = std.ArrayList([]const u8).init(allocator);
    defer commits.deinit();

    var i = command_index + 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--all") or std.mem.eql(u8, arg, "-a")) {
            all_mode = true;
        } else if (std.mem.eql(u8, arg, "--is-ancestor")) {
            is_ancestor = true;
        } else if (std.mem.eql(u8, arg, "--independent")) {
            independent = true;
        } else if (std.mem.eql(u8, arg, "--fork-point")) {
            fork_point = true;
        } else if (std.mem.eql(u8, arg, "--octopus")) {
            octopus = true;
        } else if (std.mem.eql(u8, arg, "-h")) {
            try platform_impl.writeStdout("usage: git merge-base [-a | --all] <commit> <commit>...\n   or: git merge-base [-a | --all] --octopus <commit>...\n   or: git merge-base --independent <commit>...\n   or: git merge-base --is-ancestor <commit> <commit>\n   or: git merge-base --fork-point <ref> [<commit>]\n");
            std.process.exit(129);
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try commits.append(arg);
        }
    }

    const git_dir = helpers.findGitDir() catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
        unreachable;
    };

    // helpers.Resolve all commit arguments to hashes
    var resolved = std.ArrayList([]const u8).init(allocator);
    defer {
        for (resolved.items) |h| allocator.free(h);
        resolved.deinit();
    }
    for (commits.items) |c| {
        // helpers.Check if it's already a full hex SHA
        const hash = if (c.len == 40 and helpers.isAllHex(c))
            try allocator.dupe(u8, c)
        else if (refs.resolveRef(git_dir, c, platform_impl, allocator) catch null) |h|
            h
        else blk: {
            // helpers.Try abbreviated hash - check helpers.objects dir
            if (c.len >= 4 and helpers.isAllHex(c)) {
                if (helpers.expandAbbrevHash(allocator, git_dir, c)) |expanded| {
                    break :blk expanded;
                } else |_| {}
            }
            const msg = std.fmt.allocPrint(allocator, "fatal: helpers.Not a valid object name {s}\n", .{c}) catch unreachable;
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
            unreachable;
        };
        try resolved.append(hash);
    }

    if (is_ancestor) {
        if (resolved.items.len != 2) {
            try platform_impl.writeStderr("usage: git merge-base --is-ancestor <commit> <commit>\n");
            std.process.exit(129);
        }
        // helpers.Check if first is ancestor of second
        var ancestors = std.StringHashMap(void).init(allocator);
        defer {
            var it = ancestors.iterator();
            while (it.next()) |entry| allocator.free(entry.key_ptr.*);
            ancestors.deinit();
        }
        try helpers.collectAncestors(git_dir, resolved.items[1], &ancestors, allocator, platform_impl);
        if (ancestors.contains(resolved.items[0])) {
            // Is ancestor - exit 0
            return;
        } else {
            std.process.exit(1);
        }
    }

    if (independent) {
        // helpers.Find commits that are not ancestors of any other commit in the list
        // helpers.For each commit, check if it's an ancestor of any other
        var indep = std.ArrayList([]const u8).init(allocator);
        defer indep.deinit();

        for (resolved.items, 0..) |commit_hash, ci| {
            var is_reachable = false;
            for (resolved.items, 0..) |other_hash, oi| {
                if (ci == oi) continue;
                // helpers.Check if commit_hash is ancestor of other_hash
                var ancestors = std.StringHashMap(void).init(allocator);
                defer {
                    var it = ancestors.iterator();
                    while (it.next()) |entry| allocator.free(entry.key_ptr.*);
                    ancestors.deinit();
                }
                try helpers.collectAncestors(git_dir, other_hash, &ancestors, allocator, platform_impl);
                if (ancestors.contains(commit_hash)) {
                    is_reachable = true;
                    break;
                }
            }
            if (!is_reachable) {
                try indep.append(commit_hash);
            }
        }

        for (indep.items, 0..) |h, hi| {
            if (hi > 0) try platform_impl.writeStdout(" ");
            const out = std.fmt.allocPrint(allocator, "{s}", .{h}) catch continue;
            defer allocator.free(out);
            try platform_impl.writeStdout(out);
        }
        if (indep.items.len > 0) try platform_impl.writeStdout("\n");
        return;
    }

    if (fork_point) {
        // helpers.Simplified fork-point: find merge-base between commit and ref tip
        if (resolved.items.len < 1) {
            try platform_impl.writeStderr("usage: git merge-base --fork-point <ref> [<commit>]\n");
            std.process.exit(129);
        }
        // helpers.Use helpers.HEAD as second commit if not specified
        const second = if (resolved.items.len >= 2) resolved.items[1] else blk: {
            const head = refs.resolveRef(git_dir, "HEAD", platform_impl, allocator) catch {
                std.process.exit(1);
                unreachable;
            };
            break :blk head orelse {
                std.process.exit(1);
                unreachable;
            };
        };
        const mb = helpers.findMergeBase(git_dir, resolved.items[0], second, allocator, platform_impl) catch {
            std.process.exit(1);
            unreachable;
        };
        defer allocator.free(mb);
        const out = std.fmt.allocPrint(allocator, "{s}\n", .{mb}) catch unreachable;
        defer allocator.free(out);
        try platform_impl.writeStdout(out);
        return;
    }

    if (octopus) {
        // Octopus merge base: find merge base of all commits iteratively
        if (resolved.items.len < 2) {
            try platform_impl.writeStderr("fatal: helpers.Not enough arguments\n");
            std.process.exit(128);
            unreachable;
        }
        var current = try allocator.dupe(u8, resolved.items[0]);
        var j: usize = 1;
        while (j < resolved.items.len) : (j += 1) {
            const mb = helpers.findMergeBase(git_dir, current, resolved.items[j], allocator, platform_impl) catch {
                std.process.exit(1);
                unreachable;
            };
            allocator.free(current);
            current = mb;
        }
        defer allocator.free(current);
        const out = std.fmt.allocPrint(allocator, "{s}\n", .{current}) catch unreachable;
        defer allocator.free(out);
        try platform_impl.writeStdout(out);
        return;
    }

    // Default: find merge base between two commits
    if (resolved.items.len < 2) {
        try platform_impl.writeStderr("usage: git merge-base [-a | --all] <commit> <commit>...\n");
        std.process.exit(128);
        unreachable;
    }

    if (all_mode) {
        // helpers.Find all merge bases
        const bases = try findAllMergeBases(git_dir, resolved.items[0], resolved.items[1], allocator, platform_impl);
        defer {
            for (bases) |b| allocator.free(b);
            allocator.free(bases);
        }
        for (bases) |b| {
            const out = std.fmt.allocPrint(allocator, "{s}\n", .{b}) catch continue;
            defer allocator.free(out);
            try platform_impl.writeStdout(out);
        }
        if (bases.len == 0) std.process.exit(1);
    } else {
        // helpers.For multiple commits, find merge-base iteratively (pairwise)
        var current = try allocator.dupe(u8, resolved.items[0]);
        var j: usize = 1;
        while (j < resolved.items.len) : (j += 1) {
            const mb = helpers.findMergeBase(git_dir, current, resolved.items[j], allocator, platform_impl) catch {
                std.process.exit(1);
                unreachable;
            };
            allocator.free(current);
            current = mb;
        }
        defer allocator.free(current);
        const out = std.fmt.allocPrint(allocator, "{s}\n", .{current}) catch unreachable;
        defer allocator.free(out);
        try platform_impl.writeStdout(out);
    }
}


pub fn findAllMergeBases(git_dir: []const u8, hash1: []const u8, hash2: []const u8, allocator: std.mem.Allocator, platform_impl: *const platform_mod.Platform) ![][]const u8 {
    // helpers.Collect ancestors of both commits
    var ancestors1 = std.StringHashMap(void).init(allocator);
    defer {
        var it = ancestors1.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        ancestors1.deinit();
    }
    var ancestors2 = std.StringHashMap(void).init(allocator);
    defer {
        var it = ancestors2.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        ancestors2.deinit();
    }

    try helpers.collectAncestors(git_dir, hash1, &ancestors1, allocator, platform_impl);
    try helpers.collectAncestors(git_dir, hash2, &ancestors2, allocator, platform_impl);

    // Common ancestors are the intersection
    var common = std.ArrayList([]const u8).init(allocator);
    defer common.deinit();

    var it = ancestors1.iterator();
    while (it.next()) |entry| {
        if (ancestors2.contains(entry.key_ptr.*)) {
            try common.append(try allocator.dupe(u8, entry.key_ptr.*));
        }
    }

    // Filter out non-maximal: remove any common ancestor that is itself
    // an ancestor of another common ancestor
    var result = std.ArrayList([]const u8).init(allocator);
    defer result.deinit();

    for (common.items) |candidate| {
        var is_ancestor_of_other = false;
        for (common.items) |other| {
            if (std.mem.eql(u8, candidate, other)) continue;
            // helpers.Check if candidate is ancestor of other
            var other_ancestors = std.StringHashMap(void).init(allocator);
            defer {
                var oit = other_ancestors.iterator();
                while (oit.next()) |oe| allocator.free(oe.key_ptr.*);
                other_ancestors.deinit();
            }
            try helpers.collectAncestors(git_dir, other, &other_ancestors, allocator, platform_impl);
            if (other_ancestors.contains(candidate)) {
                is_ancestor_of_other = true;
                break;
            }
        }
        if (!is_ancestor_of_other) {
            try result.append(try allocator.dupe(u8, candidate));
        }
    }

    // Free common list entries not in result
    for (common.items) |c| allocator.free(c);

    return try result.toOwnedSlice();
}


