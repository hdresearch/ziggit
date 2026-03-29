// Auto-generated from main_common.zig - cmd_last_modified
// Agents: this file is yours to edit for the commands it contains.

const std = @import("std");
const platform_mod = @import("platform/platform.zig");
const helpers = @import("git_helpers.zig");
const cmd_check_ref_format = @import("cmd_check_ref_format.zig");
const cmd_tag = @import("cmd_tag.zig");

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

pub fn cmdLastModified(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    var recursive = false;
    var show_trees = false;
    var rev: ?[]const u8 = null;
    var lm_paths = std.array_list.Managed([]const u8).init(allocator);
    defer lm_paths.deinit();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-r")) {
            recursive = true;
        } else if (std.mem.eql(u8, arg, "-t")) {
            show_trees = true;
        } else if (std.mem.eql(u8, arg, "--")) {
            while (args.next()) |p| try lm_paths.append(p);
            break;
        } else if (arg.len > 1 and arg[0] == '-' and arg[1] == '-') {
            const msg = try std.fmt.allocPrint(allocator, "unknown last-modified argument: {s}\n", .{arg});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
        } else {
            // helpers.Could be rev or path - collect for later disambiguation
            try lm_paths.append(arg);
        }
    }

    // Disambiguate: first positional arg might be a rev
    // helpers.Try to resolve it; if it fails, treat as path

    const git_path = helpers.findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);

    // helpers.Try to resolve first positional arg as revision
    if (lm_paths.items.len > 0 and rev == null) {
        const first_arg = lm_paths.items[0];
        const resolved_try = helpers.resolveRevision(git_path, first_arg, platform_impl, allocator) catch null;
        if (resolved_try) |r| {
            allocator.free(r);
            rev = first_arg;
            // helpers.Remove from paths
            _ = lm_paths.orderedRemove(0);
        }
    }

    // helpers.Check for multiple revisions
    if (rev != null and lm_paths.items.len > 0) {
        // helpers.Check if any remaining args look like revisions
        for (lm_paths.items) |p| {
            const r2 = helpers.resolveRevision(git_path, p, platform_impl, allocator) catch null;
            if (r2) |r| {
                allocator.free(r);
                try platform_impl.writeStderr("last-modified can only operate on one commit at a time\n");
                std.process.exit(128);
            }
        }
    }

    const commit_hash: []u8 = blk: {
        if (rev) |r| {
            const resolved = helpers.resolveRevision(git_path, r, platform_impl, allocator) catch {
                const msg2 = try std.fmt.allocPrint(allocator, "fatal: bad revision '{s}'\n", .{r});
                defer allocator.free(msg2);
                try platform_impl.writeStderr(msg2);
                std.process.exit(128);
                unreachable;
            };
            // helpers.Check if it resolves to a tree (not a commit)
            const obj = objects.GitObject.load(resolved, git_path, platform_impl, allocator) catch break :blk resolved;
            defer obj.deinit(allocator);
            if (obj.type == .tree) {
                const msg2 = try std.fmt.allocPrint(allocator, "revision argument '{s}' is a tree, not a commit-ish\n", .{r});
                defer allocator.free(msg2);
                try platform_impl.writeStderr(msg2);
                allocator.free(resolved);
                std.process.exit(128);
            }
            if (obj.type == .tag) {
                const tag_target = helpers.parseTagObject(obj.data, allocator) catch break :blk resolved;
                allocator.free(resolved);
                break :blk tag_target;
            }
            break :blk resolved;
        } else {
            const h = refs.getCurrentCommit(git_path, platform_impl, allocator) catch {
                try platform_impl.writeStderr("fatal: no commits\n");
                std.process.exit(128);
                unreachable;
            };
            break :blk h orelse {
                try platform_impl.writeStderr("fatal: no commits\n");
                std.process.exit(128);
                unreachable;
            };
        }
    };
    defer allocator.free(commit_hash);

    // helpers.Get tree hash from commit
    const commit_obj = objects.GitObject.load(commit_hash, git_path, platform_impl, allocator) catch {
        try platform_impl.writeStderr("fatal: bad commit\n");
        std.process.exit(128);
        unreachable;
    };
    defer commit_obj.deinit(allocator);
    var tree_hash: ?[]const u8 = null;
    var tli = std.mem.splitScalar(u8, commit_obj.data, '\n');
    while (tli.next()) |line| {
        if (std.mem.startsWith(u8, line, "tree ")) { tree_hash = line["tree ".len..]; break; }
        if (line.len == 0) break;
    }
    if (tree_hash == null) { try platform_impl.writeStderr("fatal: bad commit\n"); std.process.exit(128); }

    var entries = std.array_list.Managed(helpers.LastModTreeEntry).init(allocator);
    defer { for (entries.items) |e| allocator.free(e.path); entries.deinit(); }

    if (recursive) {
        try lmCollectRecursive(allocator, git_path, tree_hash.?, "", &entries, show_trees, platform_impl);
    } else {
        try lmCollectTopLevel(allocator, git_path, tree_hash.?, &entries, platform_impl);
    }

    // Filter by paths if specified
    for (entries.items) |entry| {
        if (lm_paths.items.len > 0) {
            var matched = false;
            for (lm_paths.items) |p| {
                if (std.mem.eql(u8, entry.path, p) or std.mem.startsWith(u8, entry.path, p)) { matched = true; break; }
            }
            if (!matched) continue;
        }
        const last_commit = lmFindLastModified(allocator, git_path, commit_hash, entry.path, platform_impl) catch commit_hash;
        const out = try std.fmt.allocPrint(allocator, "{s}\t{s}\n", .{ last_commit, entry.path });
        defer allocator.free(out);
        try platform_impl.writeStdout(out);
    }
}


pub fn lmCollectRecursive(allocator: std.mem.Allocator, git_path: []const u8, tree_hash: []const u8, prefix: []const u8, entries: *std.array_list.Managed(helpers.LastModTreeEntry), show_trees: bool, platform_impl: *const platform_mod.Platform) !void {
    const tree_obj = objects.GitObject.load(tree_hash, git_path, platform_impl, allocator) catch return;
    defer tree_obj.deinit(allocator);
    var pos: usize = 0;
    while (pos < tree_obj.data.len) {
        const sp = std.mem.indexOfScalarPos(u8, tree_obj.data, pos, ' ') orelse break;
        const mode = tree_obj.data[pos..sp];
        pos = sp + 1;
        const np = std.mem.indexOfScalarPos(u8, tree_obj.data, pos, 0) orelse break;
        const name = tree_obj.data[pos..np];
        pos = np + 1;
        if (pos + 20 > tree_obj.data.len) break;
        const hash_bytes = tree_obj.data[pos..pos + 20];
        pos += 20;
        const full_path = if (prefix.len > 0) try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, name }) else try allocator.dupe(u8, name);
        const is_tree = std.mem.eql(u8, mode, "40000");
        if (is_tree) {
            if (show_trees) try entries.append(.{ .path = try allocator.dupe(u8, full_path), .is_tree = true });
            var hash_hex: [40]u8 = undefined;
            for (hash_bytes, 0..) |b, bi| { hash_hex[bi * 2] = "0123456789abcdef"[b >> 4]; hash_hex[bi * 2 + 1] = "0123456789abcdef"[b & 0xf]; }
            try lmCollectRecursive(allocator, git_path, &hash_hex, full_path, entries, show_trees, platform_impl);
            allocator.free(full_path);
        } else {
            try entries.append(.{ .path = full_path, .is_tree = false });
        }
    }
}


pub fn lmCollectTopLevel(allocator: std.mem.Allocator, git_path: []const u8, tree_hash: []const u8, entries: *std.array_list.Managed(helpers.LastModTreeEntry), platform_impl: *const platform_mod.Platform) !void {
    const tree_obj = try objects.GitObject.load(tree_hash, git_path, platform_impl, allocator);
    defer tree_obj.deinit(allocator);
    var pos: usize = 0;
    while (pos < tree_obj.data.len) {
        const sp = std.mem.indexOfScalarPos(u8, tree_obj.data, pos, ' ') orelse break;
        const mode = tree_obj.data[pos..sp];
        pos = sp + 1;
        const np = std.mem.indexOfScalarPos(u8, tree_obj.data, pos, 0) orelse break;
        const name = tree_obj.data[pos..np];
        pos = np + 1;
        if (pos + 20 > tree_obj.data.len) break;
        pos += 20;
        try entries.append(.{ .path = try allocator.dupe(u8, name), .is_tree = std.mem.eql(u8, mode, "40000") });
    }
}


pub fn lmFindLastModified(allocator: std.mem.Allocator, git_path: []const u8, start_hash: []const u8, path: []const u8, platform_impl: *const platform_mod.Platform) ![]const u8 {
    var current = try allocator.dupe(u8, start_hash);
    var iterations: usize = 0;
    while (iterations < 10000) : (iterations += 1) {
        const co = objects.GitObject.load(current, git_path, platform_impl, allocator) catch break;
        defer co.deinit(allocator);
        var parent: ?[]const u8 = null;
        var li = std.mem.splitScalar(u8, co.data, '\n');
        while (li.next()) |line| {
            if (std.mem.startsWith(u8, line, "parent ") and parent == null) parent = line["parent ".len..];
            if (line.len == 0) break;
        }
        if (parent == null) return current;
        const cur_hash = helpers.getTreeEntryHashFromCommit(git_path, current, path, allocator) catch return current;
        defer allocator.free(cur_hash);
        const par_hash = helpers.getTreeEntryHashFromCommit(git_path, parent.?, path, allocator) catch return current;
        defer allocator.free(par_hash);
        if (!std.mem.eql(u8, cur_hash, par_hash)) return current;
        const next = try allocator.dupe(u8, parent.?);
        allocator.free(current);
        current = next;
    }
    return current;
}
