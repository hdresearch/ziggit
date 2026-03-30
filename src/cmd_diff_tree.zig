// Auto-generated from main_common.zig - cmd_diff_tree
// Agents: this file is yours to edit for the commands it contains.

const std = @import("std");
const platform_mod = @import("platform/platform.zig");
const helpers = @import("git_helpers.zig");
const DiffTreeOpts = helpers.DiffTreeOpts;
const cmd_diff_tree = @import("cmd_diff_tree.zig");

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

pub fn diffTreeForCommit(allocator: std.mem.Allocator, commit_ref: []const u8, opts: *const DiffTreeOpts, pathspecs: []const []const u8, platform_impl: *const platform_mod.Platform) !bool {
    const show_root = opts.show_root;
    const no_commit_id = opts.no_commit_id;
    const quiet = opts.quiet;
    const git_path = helpers.findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);
    
    const commit_hash = try helpers.resolveRevision(git_path, commit_ref, platform_impl, allocator);
    defer allocator.free(commit_hash);
    
    const commit_obj = objects.GitObject.load(commit_hash, git_path, platform_impl, allocator) catch {
        const msg = try std.fmt.allocPrint(allocator, "fatal: bad object {s}\n", .{commit_ref});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        std.process.exit(128);
    };
    defer commit_obj.deinit(allocator);
    
    var tree_hash: ?[]const u8 = null;
    var parent_hash: ?[]const u8 = null;
    var all_parent_hashes = std.array_list.Managed([]const u8).init(allocator);
    defer all_parent_hashes.deinit();
    var line_iter = std.mem.splitScalar(u8, commit_obj.data, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) break;
        if (std.mem.startsWith(u8, line, "tree ")) {
            tree_hash = line["tree ".len..];
        } else if (std.mem.startsWith(u8, line, "parent ")) {
            try all_parent_hashes.append(line["parent ".len..]);
            if (parent_hash == null) parent_hash = line["parent ".len..];
        }
    }
    
    const this_tree = tree_hash orelse return false;
    const is_merge = all_parent_hashes.items.len > 1;
    
    // helpers.For merge commits without -m, -c, or --cc, produce no output
    if (is_merge and !opts.show_m and !opts.show_combined and !opts.show_cc) {
        return false;
    }
    
    // helpers.For merge commits with -m, diff against each parent
    if (is_merge and opts.show_m) {
        var had_any = false;
        for (all_parent_hashes.items) |ph| {
            const parent_obj2 = objects.GitObject.load(ph, git_path, platform_impl, allocator) catch continue;
            defer parent_obj2.deinit(allocator);
            var pt2: ?[]const u8 = null;
            var piter2 = std.mem.splitScalar(u8, parent_obj2.data, '\n');
            while (piter2.next()) |pline| {
                if (pline.len == 0) break;
                if (std.mem.startsWith(u8, pline, "tree ")) {
                    pt2 = pline["tree ".len..];
                    break;
                }
            }
            if (pt2) |parent_tree| {
                var quiet_opts2 = opts.*;
                quiet_opts2.quiet = true;
                const has_diff2 = try diffTwoTreesFiltered(allocator, parent_tree, this_tree, "", &quiet_opts2, pathspecs, platform_impl);
                if (has_diff2) {
                    had_any = true;
                    if (!quiet) {
                        if (!no_commit_id) {
                            if (opts.show_pretty) {
                                try helpers.outputPrettyCommitHeader(allocator, commit_hash, commit_obj.data, opts, platform_impl);
                            } else {
                                const id_line = try std.fmt.allocPrint(allocator, "{s}\n", .{commit_hash});
                                defer allocator.free(id_line);
                                try platform_impl.writeStdout(id_line);
                            }
                        }
                        _ = try diffTwoTreesFiltered(allocator, parent_tree, this_tree, "", opts, pathspecs, platform_impl);
                    }
                }
            }
        }
        return had_any;
    }
    
    // helpers.For merge commits with -c or --cc, show combined diff
    if (is_merge and (opts.show_combined or opts.show_cc)) {
        if (!quiet and !no_commit_id) {
            if (opts.show_pretty) {
                try helpers.outputPrettyCommitHeader(allocator, commit_hash, commit_obj.data, opts, platform_impl);
            } else {
                const id_line = try std.fmt.allocPrint(allocator, "{s}\n", .{commit_hash});
                defer allocator.free(id_line);
                try platform_impl.writeStdout(id_line);
            }
        }
        if (!quiet) {
            // helpers.For -c/--cc, show combined raw by default (when no -p/--stat/etc.)
            const show_combined_raw = opts.show_raw or (!opts.show_patch and !opts.patch_with_stat and !opts.patch_with_raw and !opts.show_stat and !opts.show_shortstat and !opts.show_summary);
            if (show_combined_raw and !opts.show_patch and !opts.patch_with_stat and !opts.patch_with_raw and !opts.show_stat and !opts.show_shortstat) {
                try helpers.outputCombinedRaw(allocator, all_parent_hashes.items, this_tree, git_path, opts, platform_impl);
            }
            if (opts.show_stat or (opts.patch_with_stat and !opts.show_patch)) {
                try helpers.outputCombinedStat(allocator, all_parent_hashes.items, this_tree, git_path, opts.show_cc, platform_impl);
            }
            if (opts.show_summary) {
                try helpers.outputCombinedSummary(allocator, all_parent_hashes.items, this_tree, git_path, opts.show_cc, platform_impl);
            }
            if (opts.show_shortstat) {
                try helpers.outputCombinedShortStat(allocator, all_parent_hashes.items, this_tree, git_path, opts.show_cc, platform_impl);
            }
            if (opts.show_patch or opts.patch_with_stat) {
                if (opts.patch_with_stat) {
                    try helpers.outputCombinedStat(allocator, all_parent_hashes.items, this_tree, git_path, opts.show_cc, platform_impl);
                    try platform_impl.writeStdout("\n");
                }
                try helpers.outputCombinedDiff(allocator, all_parent_hashes.items, this_tree, git_path, opts.show_cc, platform_impl);
            }
            if (opts.patch_with_raw) {
                try helpers.outputCombinedRaw(allocator, all_parent_hashes.items, this_tree, git_path, opts, platform_impl);
                try platform_impl.writeStdout("\n");
                try helpers.outputCombinedDiff(allocator, all_parent_hashes.items, this_tree, git_path, opts.show_cc, platform_impl);
            }
        }
        return true;
    }
    
    if (parent_hash == null) {
        if (show_root) {
            if (!quiet and !no_commit_id) {
                if (opts.show_pretty) {
                    try helpers.outputPrettyCommitHeader(allocator, commit_hash, commit_obj.data, opts, platform_impl);
                } else {
                    const id_line = try std.fmt.allocPrint(allocator, "{s}\n", .{commit_hash});
                    defer allocator.free(id_line);
                    try platform_impl.writeStdout(id_line);
                }
            }
            if (!quiet) {
                if (opts.patch_with_raw) {
                    // helpers.Output raw first, then patch
                    var raw_opts = opts.*;
                    raw_opts.show_patch = false;
                    raw_opts.show_raw = true;
                    try diffTreeWithEmptyOpts(allocator, this_tree, &raw_opts, git_path, platform_impl);
                    try platform_impl.writeStdout("\n");
                    var patch_opts = opts.*;
                    patch_opts.show_patch = true;
                    try diffTreeWithEmptyOpts(allocator, this_tree, &patch_opts, git_path, platform_impl);
                } else if (opts.patch_with_stat) {
                    // helpers.Output stat first, then patch
                    try helpers.outputStatForEmptyTree(allocator, this_tree, git_path, platform_impl);
                    try platform_impl.writeStdout("\n");
                    var patch_opts = opts.*;
                    patch_opts.show_patch = true;
                    try diffTreeWithEmptyOpts(allocator, this_tree, &patch_opts, git_path, platform_impl);
                } else {
                    // helpers.Handle various display modes
                    if (opts.show_stat) {
                        try helpers.outputStatForEmptyTree(allocator, this_tree, git_path, platform_impl);
                    }
                    if (opts.show_raw and !opts.show_stat and !opts.show_summary and !opts.show_patch) {
                        try diffTreeWithEmptyOpts(allocator, this_tree, opts, git_path, platform_impl);
                    }
                    if (opts.show_summary) {
                        try helpers.outputSummaryForEmptyTree(allocator, this_tree, git_path, platform_impl);
                    }
                    if (opts.show_patch and !opts.patch_with_raw and !opts.patch_with_stat) {
                        var patch_opts = opts.*;
                        patch_opts.show_patch = true;
                        try diffTreeWithEmptyOpts(allocator, this_tree, &patch_opts, git_path, platform_impl);
                    }
                }
            }
            return true;
        }
        return false;
    }
    
    // helpers.Get parent tree
    const parent_obj = objects.GitObject.load(parent_hash.?, git_path, platform_impl, allocator) catch return false;
    defer parent_obj.deinit(allocator);
    
    var parent_tree: ?[]const u8 = null;
    var piter = std.mem.splitScalar(u8, parent_obj.data, '\n');
    while (piter.next()) |line| {
        if (line.len == 0) break;
        if (std.mem.startsWith(u8, line, "tree ")) {
            parent_tree = line["tree ".len..];
            break;
        }
    }
    
    if (parent_tree) |pt| {
        // helpers.Check for any changes (content or mode)
        var quiet_opts = opts.*;
        quiet_opts.quiet = true;
        const has_diff = try diffTwoTreesFiltered(allocator, pt, this_tree, "", &quiet_opts, pathspecs, platform_impl);
        // helpers.Also check for mode-only changes for --summary
        const has_mode_change = if (opts.show_summary and !has_diff) try helpers.hasModeChanges(allocator, pt, this_tree, git_path, platform_impl) else false;
        if (has_diff or has_mode_change) {
            if (!quiet) {
                if (!no_commit_id) {
                    if (opts.show_pretty) {
                        try helpers.outputPrettyCommitHeader(allocator, commit_hash, commit_obj.data, opts, platform_impl);
                    } else {
                        const id_line = try std.fmt.allocPrint(allocator, "{s}\n", .{commit_hash});
                        defer allocator.free(id_line);
                        try platform_impl.writeStdout(id_line);
                    }
                }
                if (opts.show_stat or opts.patch_with_stat) {
                    try helpers.outputStatForTwoTrees(allocator, pt, this_tree, git_path, pathspecs, platform_impl);
                    if (opts.patch_with_stat) {
                        try platform_impl.writeStdout("\n");
                    }
                }
                if (opts.show_summary) {
                    try helpers.outputSummaryForTwoTrees(allocator, pt, this_tree, git_path, pathspecs, platform_impl);
                }
                if (opts.patch_with_raw) {
                    // helpers.Output raw before patch
                    var raw_opts = opts.*;
                    raw_opts.show_patch = false;
                    raw_opts.show_raw = true;
                    _ = try diffTwoTreesFiltered(allocator, pt, this_tree, "", &raw_opts, pathspecs, platform_impl);
                    try platform_impl.writeStdout("\n");
                }
                if (opts.show_raw and !opts.show_stat and !opts.show_summary and !opts.patch_with_stat) {
                    _ = try diffTwoTreesFiltered(allocator, pt, this_tree, "", opts, pathspecs, platform_impl);
                }
                if (opts.show_patch and !opts.patch_with_raw) {
                    var patch_opts = opts.*;
                    patch_opts.show_patch = true;
                    _ = try diffTwoTreesFiltered(allocator, pt, this_tree, "", &patch_opts, pathspecs, platform_impl);
                }
            }
            return true;
        }
    }
    return false;
}



pub fn diffTreeWithEmpty(allocator: std.mem.Allocator, tree_hash_str: []const u8, recursive: bool, show_patch: bool, name_only: bool, name_status: bool, git_path: []const u8, platform_impl: *const platform_mod.Platform) !void {
    const default_opts = DiffTreeOpts{ .recursive = recursive, .show_patch = show_patch, .name_only = name_only, .name_status = name_status };
    try diffTreeWithEmptyPrefix(allocator, tree_hash_str, "", &default_opts, git_path, platform_impl);
}

const FileStatEntry = helpers.FileStatEntry;


pub fn diffTreeWithEmptyOpts(allocator: std.mem.Allocator, tree_hash_str: []const u8, opts: *const DiffTreeOpts, git_path: []const u8, platform_impl: *const platform_mod.Platform) !void {
    try diffTreeWithEmptyPrefix(allocator, tree_hash_str, "", opts, git_path, platform_impl);
}


pub fn diffTreeWithEmptyPrefix(allocator: std.mem.Allocator, tree_hash_str: []const u8, prefix: []const u8, opts: *const DiffTreeOpts, git_path: []const u8, platform_impl: *const platform_mod.Platform) !void {
    const recursive = opts.recursive;
    const show_patch = opts.show_patch;
    const name_only = opts.name_only;
    const name_status = opts.name_status;
    const tree_obj = objects.GitObject.load(tree_hash_str, git_path, platform_impl, allocator) catch return;
    defer tree_obj.deinit(allocator);
    
    var entries = tree_mod.parseTree(tree_obj.data, allocator) catch return;
    defer entries.deinit();
    
    const zero_hash = "0000000000000000000000000000000000000000";
    
    for (entries.items) |entry| {
        const full_name = if (prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name })
        else
            try allocator.dupe(u8, entry.name);
        defer allocator.free(full_name);
        
        if (recursive and helpers.isTreeMode(entry.mode)) {
            try diffTreeWithEmptyPrefix(allocator, entry.hash, full_name, opts, git_path, platform_impl);
            continue;
        }
        
        if (show_patch) {
            // helpers.Generate unified diff for new file
            const new_content = helpers.loadBlobContent(allocator, entry.hash, git_path, platform_impl) catch "";
            defer if (new_content.len > 0) allocator.free(new_content);
            var mbuf: [6]u8 = undefined;
            const padded_mode = helpers.padMode6(&mbuf, entry.mode);
            // full_index overrides abbrev for index line
            const idx_zero = if (opts.full_index) zero_hash else if (opts.abbrev_len) |abl| zero_hash[0..@min(if (abl == 0) 7 else abl, zero_hash.len)] else zero_hash[0..7];
            const idx_hash = if (opts.full_index) entry.hash else if (opts.abbrev_len) |abl| entry.hash[0..@min(if (abl == 0) 7 else abl, entry.hash.len)] else entry.hash[0..@min(7, entry.hash.len)];
            const header = try std.fmt.allocPrint(allocator, "diff --git a/{s} b/{s}\nnew file mode {s}\nindex {s}..{s}\n--- /dev/null\n+++ b/{s}\n", .{ full_name, full_name, padded_mode, idx_zero, idx_hash, full_name });
            defer allocator.free(header);
            try platform_impl.writeStdout(header);
            
            // helpers.Output hunk header and content
            if (new_content.len > 0) {
                var line_count: usize = 0;
                var iter = std.mem.splitScalar(u8, new_content, '\n');
                while (iter.next()) |_| line_count += 1;
                // helpers.Remove trailing empty line from count
                if (new_content.len > 0 and new_content[new_content.len - 1] == '\n') line_count -= 1;
                
                const hunk_header = try std.fmt.allocPrint(allocator, "@@ -0,0 +1,{d} @@\n", .{line_count});
                defer allocator.free(hunk_header);
                try platform_impl.writeStdout(hunk_header);
                
                var line_iter = std.mem.splitScalar(u8, new_content, '\n');
                var printed: usize = 0;
                while (line_iter.next()) |line| {
                    if (printed >= line_count) break;
                    const line_out = try std.fmt.allocPrint(allocator, "+{s}\n", .{line});
                    defer allocator.free(line_out);
                    try platform_impl.writeStdout(line_out);
                    printed += 1;
                }
            }
        } else if (name_only) {
            const out = try std.fmt.allocPrint(allocator, "{s}\n", .{full_name});
            defer allocator.free(out);
            try platform_impl.writeStdout(out);
        } else if (name_status) {
            const out = try std.fmt.allocPrint(allocator, "A\t{s}\n", .{full_name});
            defer allocator.free(out);
            try platform_impl.writeStdout(out);
        } else {
            var mbuf: [6]u8 = undefined;
            const ah1 = opts.abbrevHash(zero_hash);
            const ah2 = opts.abbrevHash(entry.hash);
            const suf = opts.hashSuffix();
            const out = try std.fmt.allocPrint(allocator, ":000000 {s} {s}{s} {s}{s} A\t{s}\n", .{ helpers.padMode6(&mbuf, entry.mode), ah1, suf, ah2, suf, full_name });
            defer allocator.free(out);
            try platform_impl.writeStdout(out);
        }
    }
}


pub fn diffTwoTreesFiltered(allocator: std.mem.Allocator, tree1_hash: []const u8, tree2_hash: []const u8, prefix: []const u8, opts: *const DiffTreeOpts, pathspecs: []const []const u8, platform_impl: *const platform_mod.Platform) !bool {
    const recursive = opts.recursive;
    const name_only = opts.name_only;
    const name_status = opts.name_status;
    const quiet = opts.quiet;
    const git_path = helpers.findGitDirectory(allocator, platform_impl) catch return false;
    defer allocator.free(git_path);
    
    const empty_tree_sentinel = "4b825dc642cb6eb9a060e54bf8d69288fbee4904";
    const is_empty_tree1 = std.mem.eql(u8, tree1_hash, empty_tree_sentinel);
    const is_empty_tree2 = std.mem.eql(u8, tree2_hash, empty_tree_sentinel);
    
    const tree1_obj = if (!is_empty_tree1) (objects.GitObject.load(tree1_hash, git_path, platform_impl, allocator) catch return false) else null;
    defer if (tree1_obj) |obj| obj.deinit(allocator);
    const tree2_obj = if (!is_empty_tree2) (objects.GitObject.load(tree2_hash, git_path, platform_impl, allocator) catch return false) else null;
    defer if (tree2_obj) |obj| obj.deinit(allocator);
    
    var entries1 = if (tree1_obj) |obj| (tree_mod.parseTree(obj.data, allocator) catch return false) else std.array_list.Managed(tree_mod.TreeEntry).init(allocator);
    defer entries1.deinit();
    var entries2 = if (tree2_obj) |obj| (tree_mod.parseTree(obj.data, allocator) catch return false) else std.array_list.Managed(tree_mod.TreeEntry).init(allocator);
    defer entries2.deinit();
    
    const zero_hash = "0000000000000000000000000000000000000000";
    
    // helpers.Build lookup maps
    var map1 = std.StringHashMap(tree_mod.TreeEntry).init(allocator);
    defer map1.deinit();
    var map2 = std.StringHashMap(tree_mod.TreeEntry).init(allocator);
    defer map2.deinit();
    for (entries1.items) |e| map1.put(e.name, e) catch {};
    for (entries2.items) |e| map2.put(e.name, e) catch {};
    
    // helpers.Collect and sort all names using git tree sort order
    var all_names = std.StringHashMap(void).init(allocator);
    defer all_names.deinit();
    for (entries1.items) |e| all_names.put(e.name, {}) catch {};
    for (entries2.items) |e| all_names.put(e.name, {}) catch {};
    
    const SortCtx = struct {
        m1: *std.StringHashMap(tree_mod.TreeEntry),
        m2: *std.StringHashMap(tree_mod.TreeEntry),
    };
    var name_list = std.array_list.Managed([]const u8).init(allocator);
    defer name_list.deinit();
    var niter = all_names.keyIterator();
    while (niter.next()) |key| try name_list.append(key.*);
    const ctx = SortCtx{ .m1 = &map1, .m2 = &map2 };
    std.mem.sort([]const u8, name_list.items, ctx, struct {
        fn cmp(c: SortCtx, a: []const u8, b: []const u8) bool {
            // Git sorts tree entries as if they have a trailing '/'
            const a_is_tree = if (c.m2.get(a)) |e| helpers.isTreeMode(e.mode) else if (c.m1.get(a)) |e| helpers.isTreeMode(e.mode) else false;
            const b_is_tree = if (c.m2.get(b)) |e| helpers.isTreeMode(e.mode) else if (c.m1.get(b)) |e| helpers.isTreeMode(e.mode) else false;
            // Compare using virtual trailing '/' for trees
            const min_len = @min(a.len, b.len);
            var i: usize = 0;
            while (i < min_len) : (i += 1) {
                if (a[i] != b[i]) return a[i] < b[i];
            }
            // Same prefix - compare suffixes
            const a_next: u8 = if (i < a.len) a[i] else if (a_is_tree) '/' else 0;
            const b_next: u8 = if (i < b.len) b[i] else if (b_is_tree) '/' else 0;
            return a_next < b_next;
        }
    }.cmp);
    
    var had_diff = false;
    for (name_list.items) |name| {
        const e1 = map1.get(name);
        const e2 = map2.get(name);
        
        const full_name = if (prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, name })
        else
            try allocator.dupe(u8, name);
        defer allocator.free(full_name);
        
        if (e1 != null and e2 != null) {
            if (std.mem.eql(u8, e1.?.hash, e2.?.hash) and std.mem.eql(u8, e1.?.mode, e2.?.mode)) continue;
            
            // Type change: tree <-> blob - treat as D + A
            const e1_is_tree = helpers.isTreeMode(e1.?.mode);
            const e2_is_tree = helpers.isTreeMode(e2.?.mode);
            if (e1_is_tree != e2_is_tree) {
                // This is a type change - emit blob side first (sorts before tree)
                // then tree side, then recurse into the tree
                had_diff = true;
                if (!quiet) {
                    if (name_status) {
                        // Blob entry comes first in git tree sort order
                        if (e1_is_tree) {
                            // e1=tree(D), e2=blob(A) -> emit A first, then D
                            const out_a = try std.fmt.allocPrint(allocator, "A\t{s}\n", .{full_name});
                            defer allocator.free(out_a);
                            try platform_impl.writeStdout(out_a);
                            const out_d = try std.fmt.allocPrint(allocator, "D\t{s}\n", .{full_name});
                            defer allocator.free(out_d);
                            try platform_impl.writeStdout(out_d);
                        } else {
                            // e1=blob(D), e2=tree(A) -> emit D first, then A
                            const out_d = try std.fmt.allocPrint(allocator, "D\t{s}\n", .{full_name});
                            defer allocator.free(out_d);
                            try platform_impl.writeStdout(out_d);
                            const out_a = try std.fmt.allocPrint(allocator, "A\t{s}\n", .{full_name});
                            defer allocator.free(out_a);
                            try platform_impl.writeStdout(out_a);
                        }
                    } else if (name_only) {
                        const out = try std.fmt.allocPrint(allocator, "{s}\n", .{full_name});
                        defer allocator.free(out);
                        try platform_impl.writeStdout(out);
                    } else if (!opts.show_patch) {
                        var mb1: [6]u8 = undefined;
                        var mb2: [6]u8 = undefined;
                        const suf = opts.hashSuffix();
                        if (e1_is_tree) {
                            // e1=tree(D), e2=blob(A) -> emit A first, then D
                            const out_a = try std.fmt.allocPrint(allocator, ":000000 {s} {s}{s} {s}{s} A\t{s}\n", .{ helpers.padMode6(&mb2, e2.?.mode), opts.abbrevHash(zero_hash), suf, opts.abbrevHash(e2.?.hash), suf, full_name });
                            defer allocator.free(out_a);
                            try platform_impl.writeStdout(out_a);
                            const out_d = try std.fmt.allocPrint(allocator, ":{s} 000000 {s}{s} {s}{s} D\t{s}\n", .{ helpers.padMode6(&mb1, e1.?.mode), opts.abbrevHash(e1.?.hash), suf, opts.abbrevHash(zero_hash), suf, full_name });
                            defer allocator.free(out_d);
                            try platform_impl.writeStdout(out_d);
                        } else {
                            // e1=blob(D), e2=tree(A) -> emit D first, then A
                            const out_d = try std.fmt.allocPrint(allocator, ":{s} 000000 {s}{s} {s}{s} D\t{s}\n", .{ helpers.padMode6(&mb1, e1.?.mode), opts.abbrevHash(e1.?.hash), suf, opts.abbrevHash(zero_hash), suf, full_name });
                            defer allocator.free(out_d);
                            try platform_impl.writeStdout(out_d);
                            const out_a = try std.fmt.allocPrint(allocator, ":000000 {s} {s}{s} {s}{s} A\t{s}\n", .{ helpers.padMode6(&mb2, e2.?.mode), opts.abbrevHash(zero_hash), suf, opts.abbrevHash(e2.?.hash), suf, full_name });
                            defer allocator.free(out_a);
                            try platform_impl.writeStdout(out_a);
                        }
                    }
                }
                // Recurse into the old tree (deleted entries) and new tree (added entries)
                if (recursive and e1_is_tree) {
                    const empty_tree_tc = "4b825dc642cb6eb9a060e54bf8d69288fbee4904";
                    const sub = try diffTwoTreesFiltered(allocator, e1.?.hash, empty_tree_tc, full_name, opts, pathspecs, platform_impl);
                    if (sub) had_diff = true;
                }
                if (recursive and e2_is_tree) {
                    const empty_tree_tc2 = "4b825dc642cb6eb9a060e54bf8d69288fbee4904";
                    const sub = try diffTwoTreesFiltered(allocator, empty_tree_tc2, e2.?.hash, full_name, opts, pathspecs, platform_impl);
                    if (sub) had_diff = true;
                }
                continue;
            }
            
            if (recursive and e1_is_tree and e2_is_tree) {
                // Both are trees - if show_tree, emit tree entry first
                if (opts.show_tree and !quiet) {
                    if (name_status) {
                        const out = try std.fmt.allocPrint(allocator, "M\t{s}\n", .{full_name});
                        defer allocator.free(out);
                        try platform_impl.writeStdout(out);
                    } else if (name_only) {
                        const out = try std.fmt.allocPrint(allocator, "{s}\n", .{full_name});
                        defer allocator.free(out);
                        try platform_impl.writeStdout(out);
                    } else if (!opts.show_patch) {
                        var mb1: [6]u8 = undefined;
                        var mb2: [6]u8 = undefined;
                        const suf = opts.hashSuffix();
                        const out = try std.fmt.allocPrint(allocator, ":{s} {s} {s}{s} {s}{s} M\t{s}\n", .{ helpers.padMode6(&mb1, e1.?.mode), helpers.padMode6(&mb2, e2.?.mode), opts.abbrevHash(e1.?.hash), suf, opts.abbrevHash(e2.?.hash), suf, full_name });
                        defer allocator.free(out);
                        try platform_impl.writeStdout(out);
                    }
                    had_diff = true;
                }
                const sub = try diffTwoTreesFiltered(allocator, e1.?.hash, e2.?.hash, full_name, opts, pathspecs, platform_impl);
                if (sub) had_diff = true;
                continue;
            }
            if (!helpers.matchesPathspecs(full_name, pathspecs)) continue;
            had_diff = true;
            if (!quiet) {
                if (name_only) {
                    const out = try std.fmt.allocPrint(allocator, "{s}\n", .{full_name});
                    defer allocator.free(out);
                    try platform_impl.writeStdout(out);
                } else if (name_status) {
                    const out = try std.fmt.allocPrint(allocator, "M\t{s}\n", .{full_name});
                    defer allocator.free(out);
                    try platform_impl.writeStdout(out);
                } else if (opts.show_patch) {
                    // helpers.Generate unified diff for modified file
                    const old_content = helpers.loadBlobContent(allocator, e1.?.hash, git_path, platform_impl) catch "";
                    defer if (old_content.len > 0) allocator.free(old_content);
                    const new_content = helpers.loadBlobContent(allocator, e2.?.hash, git_path, platform_impl) catch "";
                    defer if (new_content.len > 0) allocator.free(new_content);
                    const idx_h1 = if (opts.full_index) e1.?.hash else helpers.uniqueAbbrev(allocator, git_path, e1.?.hash, 7);
                    const idx_h2 = if (opts.full_index) e2.?.hash else helpers.uniqueAbbrev(allocator, git_path, e2.?.hash, 7);
                    const diff_out = diff_mod.generateUnifiedDiffWithHashes(old_content, new_content, full_name, idx_h1, idx_h2, allocator) catch "";
                    defer if (diff_out.len > 0) allocator.free(diff_out);
                    if (diff_out.len > 0) try platform_impl.writeStdout(diff_out);
                } else {
                    var mb1: [6]u8 = undefined;
                    var mb2: [6]u8 = undefined;
                    const suf = opts.hashSuffix();
                    const out = try std.fmt.allocPrint(allocator, ":{s} {s} {s}{s} {s}{s} M\t{s}\n", .{ helpers.padMode6(&mb1, e1.?.mode), helpers.padMode6(&mb2, e2.?.mode), opts.abbrevHash(e1.?.hash), suf, opts.abbrevHash(e2.?.hash), suf, full_name });
                    defer allocator.free(out);
                    try platform_impl.writeStdout(out);
                }
            }
        } else if (e1 != null and e2 == null) {
            const e1_is_tree = helpers.isTreeMode(e1.?.mode);
            // For trees with -t, emit the tree entry then recurse
            if (recursive and e1_is_tree) {
                if (opts.show_tree) {
                    had_diff = true;
                    if (!quiet) {
                        if (name_status) {
                            const out = try std.fmt.allocPrint(allocator, "D\t{s}\n", .{full_name});
                            defer allocator.free(out);
                            try platform_impl.writeStdout(out);
                        } else if (name_only) {
                            const out = try std.fmt.allocPrint(allocator, "{s}\n", .{full_name});
                            defer allocator.free(out);
                            try platform_impl.writeStdout(out);
                        } else if (!opts.show_patch) {
                            var mb1: [6]u8 = undefined;
                            const suf = opts.hashSuffix();
                            const out = try std.fmt.allocPrint(allocator, ":{s} 000000 {s}{s} {s}{s} D\t{s}\n", .{ helpers.padMode6(&mb1, e1.?.mode), opts.abbrevHash(e1.?.hash), suf, opts.abbrevHash(zero_hash), suf, full_name });
                            defer allocator.free(out);
                            try platform_impl.writeStdout(out);
                        }
                    }
                }
                // Recurse into the deleted tree
                const empty_tree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904";
                const sub = try diffTwoTreesFiltered(allocator, e1.?.hash, empty_tree, full_name, opts, pathspecs, platform_impl);
                if (sub) had_diff = true;
                continue;
            }
            if (!helpers.matchesPathspecs(full_name, pathspecs)) continue;
            had_diff = true;
            if (!quiet) {
                if (name_only) {
                    const out = try std.fmt.allocPrint(allocator, "{s}\n", .{full_name});
                    defer allocator.free(out);
                    try platform_impl.writeStdout(out);
                } else if (name_status) {
                    const out = try std.fmt.allocPrint(allocator, "D\t{s}\n", .{full_name});
                    defer allocator.free(out);
                    try platform_impl.writeStdout(out);
                } else if (opts.show_patch) {
                    // helpers.Generate diff for deleted file
                    const old_content = helpers.loadBlobContent(allocator, e1.?.hash, git_path, platform_impl) catch "";
                    defer if (old_content.len > 0) allocator.free(old_content);
                    var mb1: [6]u8 = undefined;
                    const idx_h1 = if (opts.full_index) e1.?.hash else e1.?.hash[0..@min(7, e1.?.hash.len)];
                    const header = try std.fmt.allocPrint(allocator, "diff --git a/{s} b/{s}\ndeleted file mode {s}\nindex {s}..0000000\n--- a/{s}\n+++ /dev/null\n", .{ full_name, full_name, helpers.padMode6(&mb1, e1.?.mode), idx_h1, full_name });
                    defer allocator.free(header);
                    try platform_impl.writeStdout(header);
                    if (old_content.len > 0) {
                        var line_count: usize = 0;
                        var citer = std.mem.splitScalar(u8, old_content, '\n');
                        while (citer.next()) |_| line_count += 1;
                        if (old_content[old_content.len - 1] == '\n') line_count -= 1;
                        const hunk = try std.fmt.allocPrint(allocator, "@@ -1,{d} +0,0 @@\n", .{line_count});
                        defer allocator.free(hunk);
                        try platform_impl.writeStdout(hunk);
                        var liter = std.mem.splitScalar(u8, old_content, '\n');
                        var printed: usize = 0;
                        while (liter.next()) |line| {
                            if (printed >= line_count) break;
                            const lo = try std.fmt.allocPrint(allocator, "-{s}\n", .{line});
                            defer allocator.free(lo);
                            try platform_impl.writeStdout(lo);
                            printed += 1;
                        }
                    }
                } else {
                    var mb1: [6]u8 = undefined;
                    const suf = opts.hashSuffix();
                    const out = try std.fmt.allocPrint(allocator, ":{s} 000000 {s}{s} {s}{s} D\t{s}\n", .{ helpers.padMode6(&mb1, e1.?.mode), opts.abbrevHash(e1.?.hash), suf, opts.abbrevHash(zero_hash), suf, full_name });
                    defer allocator.free(out);
                    try platform_impl.writeStdout(out);
                }
            }
        } else if (e2 != null) {
            const e2_is_tree = helpers.isTreeMode(e2.?.mode);
            // For trees with -t, emit the tree entry then recurse
            if (recursive and e2_is_tree) {
                if (opts.show_tree) {
                    had_diff = true;
                    if (!quiet) {
                        if (name_status) {
                            const out = try std.fmt.allocPrint(allocator, "A\t{s}\n", .{full_name});
                            defer allocator.free(out);
                            try platform_impl.writeStdout(out);
                        } else if (name_only) {
                            const out = try std.fmt.allocPrint(allocator, "{s}\n", .{full_name});
                            defer allocator.free(out);
                            try platform_impl.writeStdout(out);
                        } else if (!opts.show_patch) {
                            var mb2: [6]u8 = undefined;
                            const suf = opts.hashSuffix();
                            const out = try std.fmt.allocPrint(allocator, ":000000 {s} {s}{s} {s}{s} A\t{s}\n", .{ helpers.padMode6(&mb2, e2.?.mode), opts.abbrevHash(zero_hash), suf, opts.abbrevHash(e2.?.hash), suf, full_name });
                            defer allocator.free(out);
                            try platform_impl.writeStdout(out);
                        }
                    }
                }
                // Recurse into the added tree
                const empty_tree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904";
                const sub = try diffTwoTreesFiltered(allocator, empty_tree, e2.?.hash, full_name, opts, pathspecs, platform_impl);
                if (sub) had_diff = true;
                continue;
            }
            if (!helpers.matchesPathspecs(full_name, pathspecs)) continue;
            had_diff = true;
            if (!quiet) {
                if (name_only) {
                    const out = try std.fmt.allocPrint(allocator, "{s}\n", .{full_name});
                    defer allocator.free(out);
                    try platform_impl.writeStdout(out);
                } else if (name_status) {
                    const out = try std.fmt.allocPrint(allocator, "A\t{s}\n", .{full_name});
                    defer allocator.free(out);
                    try platform_impl.writeStdout(out);
                } else if (opts.show_patch) {
                    // helpers.Generate diff for new file
                    const new_content = helpers.loadBlobContent(allocator, e2.?.hash, git_path, platform_impl) catch "";
                    defer if (new_content.len > 0) allocator.free(new_content);
                    var mb2: [6]u8 = undefined;
                    const idx_h2 = if (opts.full_index) e2.?.hash else e2.?.hash[0..@min(7, e2.?.hash.len)];
                    const header = try std.fmt.allocPrint(allocator, "diff --git a/{s} b/{s}\nnew file mode {s}\nindex 0000000..{s}\n--- /dev/null\n+++ b/{s}\n", .{ full_name, full_name, helpers.padMode6(&mb2, e2.?.mode), idx_h2, full_name });
                    defer allocator.free(header);
                    try platform_impl.writeStdout(header);
                    if (new_content.len > 0) {
                        var line_count: usize = 0;
                        var citer = std.mem.splitScalar(u8, new_content, '\n');
                        while (citer.next()) |_| line_count += 1;
                        if (new_content[new_content.len - 1] == '\n') line_count -= 1;
                        const hunk = try std.fmt.allocPrint(allocator, "@@ -0,0 +1,{d} @@\n", .{line_count});
                        defer allocator.free(hunk);
                        try platform_impl.writeStdout(hunk);
                        var liter = std.mem.splitScalar(u8, new_content, '\n');
                        var printed: usize = 0;
                        while (liter.next()) |line| {
                            if (printed >= line_count) break;
                            const lo = try std.fmt.allocPrint(allocator, "+{s}\n", .{line});
                            defer allocator.free(lo);
                            try platform_impl.writeStdout(lo);
                            printed += 1;
                        }
                    }
                } else {
                    var mb2: [6]u8 = undefined;
                    const suf = opts.hashSuffix();
                    const out = try std.fmt.allocPrint(allocator, ":000000 {s} {s}{s} {s}{s} A\t{s}\n", .{ helpers.padMode6(&mb2, e2.?.mode), opts.abbrevHash(zero_hash), suf, opts.abbrevHash(e2.?.hash), suf, full_name });
                    defer allocator.free(out);
                    try platform_impl.writeStdout(out);
                }
            }
        }
    }
    return had_diff;
}


const TreeEntryInfo = helpers.TreeEntryInfo; // = struct { mode: u32, hash: [20]u8 };

// checkRefFormatValid_crf is at end of file


pub fn diffTwoTreesPatch(allocator: std.mem.Allocator, tree1_hash: []const u8, tree2_hash: []const u8, prefix: []const u8, git_path: []const u8, quiet: bool, pathspecs: []const []const u8, platform_impl: *const platform_mod.Platform) !bool {
    const empty_tree_hash = "4b825dc642cb6eb9a060e54bf8d69288fbee4904";
    const is_empty1 = std.mem.eql(u8, tree1_hash, empty_tree_hash);
    const is_empty2 = std.mem.eql(u8, tree2_hash, empty_tree_hash);
    const tree1_obj = if (!is_empty1) (objects.GitObject.load(tree1_hash, git_path, platform_impl, allocator) catch return false) else null;
    defer if (tree1_obj) |obj| obj.deinit(allocator);
    const tree2_obj = if (!is_empty2) (objects.GitObject.load(tree2_hash, git_path, platform_impl, allocator) catch return false) else null;
    defer if (tree2_obj) |obj| obj.deinit(allocator);
    
    var entries1 = if (tree1_obj) |obj| (tree_mod.parseTree(obj.data, allocator) catch return false) else std.array_list.Managed(tree_mod.TreeEntry).init(allocator);
    defer entries1.deinit();
    var entries2 = if (tree2_obj) |obj| (tree_mod.parseTree(obj.data, allocator) catch return false) else std.array_list.Managed(tree_mod.TreeEntry).init(allocator);
    defer entries2.deinit();
    
    var map1 = std.StringHashMap(tree_mod.TreeEntry).init(allocator);
    defer map1.deinit();
    var map2 = std.StringHashMap(tree_mod.TreeEntry).init(allocator);
    defer map2.deinit();
    for (entries1.items) |e| map1.put(e.name, e) catch {};
    for (entries2.items) |e| map2.put(e.name, e) catch {};
    
    var all_names = std.StringHashMap(void).init(allocator);
    defer all_names.deinit();
    for (entries1.items) |e| all_names.put(e.name, {}) catch {};
    for (entries2.items) |e| all_names.put(e.name, {}) catch {};
    
    var name_list = std.array_list.Managed([]const u8).init(allocator);
    defer name_list.deinit();
    var niter = all_names.keyIterator();
    while (niter.next()) |key| try name_list.append(key.*);
    std.mem.sort([]const u8, name_list.items, {}, struct {
        fn cmp(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.cmp);
    
    var had_diff = false;
    for (name_list.items) |name| {
        const e1 = map1.get(name);
        const e2 = map2.get(name);
        
        const full_name = if (prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, name })
        else
            try allocator.dupe(u8, name);
        defer allocator.free(full_name);
        
        if (e1 != null and e2 != null) {
            if (std.mem.eql(u8, e1.?.hash, e2.?.hash) and std.mem.eql(u8, e1.?.mode, e2.?.mode)) continue;
            if (helpers.isTreeMode(e1.?.mode) and helpers.isTreeMode(e2.?.mode)) {
                const sub = try diffTwoTreesPatch(allocator, e1.?.hash, e2.?.hash, full_name, git_path, quiet, pathspecs, platform_impl);
                if (sub) had_diff = true;
                continue;
            }
            if (!helpers.matchesPathspecs(full_name, pathspecs)) continue;
            had_diff = true;
            if (!quiet) {
                // helpers.Load both blob contents and generate unified diff
                const old_content = helpers.loadBlobContent(allocator, e1.?.hash, git_path, platform_impl) catch "";
                defer if (old_content.len > 0) allocator.free(old_content);
                const new_content = helpers.loadBlobContent(allocator, e2.?.hash, git_path, platform_impl) catch "";
                defer if (new_content.len > 0) allocator.free(new_content);
                const short1 = helpers.uniqueAbbrev(allocator, git_path, e1.?.hash, 7);
                const short2 = helpers.uniqueAbbrev(allocator, git_path, e2.?.hash, 7);
                const diff_out = diff_mod.generateUnifiedDiffWithHashes(old_content, new_content, full_name, short1, short2, allocator) catch continue;
                defer allocator.free(diff_out);
                try platform_impl.writeStdout(diff_out);
            }
        } else if (e1 != null and e2 == null) {
            if (!helpers.matchesPathspecs(full_name, pathspecs)) continue;
            had_diff = true;
            if (!quiet) {
                const old_content = helpers.loadBlobContent(allocator, e1.?.hash, git_path, platform_impl) catch "";
                defer if (old_content.len > 0) allocator.free(old_content);
                const short1 = e1.?.hash[0..@min(7, e1.?.hash.len)];
                const diff_out = diff_mod.generateUnifiedDiffWithHashes(old_content, "", full_name, short1, "0000000", allocator) catch continue;
                defer allocator.free(diff_out);
                try platform_impl.writeStdout(diff_out);
            }
        } else if (e2 != null) {
            if (!helpers.matchesPathspecs(full_name, pathspecs)) continue;
            had_diff = true;
            if (!quiet) {
                const new_content = helpers.loadBlobContent(allocator, e2.?.hash, git_path, platform_impl) catch "";
                defer if (new_content.len > 0) allocator.free(new_content);
                const short2 = e2.?.hash[0..@min(7, e2.?.hash.len)];
                const diff_out = diff_mod.generateUnifiedDiffWithHashes("", new_content, full_name, "0000000", short2, allocator) catch continue;
                defer allocator.free(diff_out);
                try platform_impl.writeStdout(diff_out);
            }
        }
    }
    return had_diff;
}
