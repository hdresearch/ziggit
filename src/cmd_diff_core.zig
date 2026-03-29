// Auto-generated from main_common.zig - cmd_diff_core
// Agents: this file is yours to edit for the commands it contains.

const std = @import("std");
const platform_mod = @import("platform/platform.zig");
const helpers = @import("git_helpers.zig");
const cmd_ls_tree = @import("cmd_ls_tree.zig");
const cmd_diff_tree = @import("cmd_diff_tree.zig");
const cmd_show = @import("cmd_show.zig");

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

pub fn cmdDiff(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    if (@import("builtin").target.os.tag == .freestanding) {
        try platform_impl.writeStderr("diff: not supported in freestanding mode\n");
        return;
    }

    // helpers.Collect all args first to check for --no-index
    var all_diff_args = std.ArrayList([]const u8).init(allocator);
    defer all_diff_args.deinit();
    while (args.next()) |arg| {
        try all_diff_args.append(arg);
    }

    // helpers.Check for --no-index
    var no_index = false;
    for (all_diff_args.items) |arg| {
        if (std.mem.eql(u8, arg, "--no-index")) {
            no_index = true;
            break;
        }
    }

    if (no_index) {
        try cmdDiffNoIndex(allocator, all_diff_args.items, platform_impl);
        return;
    }

    // helpers.Find .git directory first
    const git_path = helpers.findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any parent up to mount point /)\nStopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set).\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);

    // helpers.Check for flags
    var cached = false;
    var quiet = false;
    var exit_code = false;
    var diff_output_mode: enum { patch, stat, shortstat, numstat, name_only, name_status, raw, no_patch, summary, dirstat, patch_with_stat, patch_with_raw } = .patch;
    var check_mode = false;
    var positional = std.ArrayList([]const u8).init(allocator);
    defer positional.deinit();
    var pathspec_args = std.ArrayList([]const u8).init(allocator);
    defer pathspec_args.deinit();
    var seen_dashdash = false;
    // Re-parse args (need an iterator)
    var diff_arg_idx: usize = 0;
    while (diff_arg_idx < all_diff_args.items.len) : (diff_arg_idx += 1) {
        const arg = all_diff_args.items[diff_arg_idx];
        if (seen_dashdash) {
            try pathspec_args.append(arg);
        } else if (std.mem.eql(u8, arg, "--")) {
            seen_dashdash = true;
        } else if (std.mem.eql(u8, arg, "--cached") or std.mem.eql(u8, arg, "--staged")) {
            cached = true;
        } else if (std.mem.eql(u8, arg, "--quiet")) {
            quiet = true;
            exit_code = true;
        } else if (std.mem.eql(u8, arg, "--exit-code")) {
            exit_code = true;
        } else if (std.mem.eql(u8, arg, "--stat") or std.mem.startsWith(u8, arg, "--stat=")) {
            diff_output_mode = .stat;
        } else if (std.mem.eql(u8, arg, "--shortstat")) {
            diff_output_mode = .shortstat;
        } else if (std.mem.eql(u8, arg, "--numstat")) {
            diff_output_mode = .numstat;
        } else if (std.mem.eql(u8, arg, "--name-only")) {
            diff_output_mode = .name_only;
        } else if (std.mem.eql(u8, arg, "--name-status")) {
            diff_output_mode = .name_status;
        } else if (std.mem.eql(u8, arg, "--raw")) {
            diff_output_mode = .raw;
        } else if (std.mem.eql(u8, arg, "--no-patch") or std.mem.eql(u8, arg, "-s")) {
            diff_output_mode = .no_patch;
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--patch") or std.mem.eql(u8, arg, "-u")) {
            // default patch mode (already default)
        } else if (std.mem.eql(u8, arg, "--no-pager")) {
            // ignore
        } else if (std.mem.eql(u8, arg, "-w") or std.mem.eql(u8, arg, "--ignore-all-space") or
            std.mem.eql(u8, arg, "--ignore-space-at-eol") or std.mem.eql(u8, arg, "--ignore-space-change") or
            std.mem.eql(u8, arg, "-b") or std.mem.eql(u8, arg, "--ignore-blank-lines"))
        {
            // whitespace options - accept but don't fully implement
        } else if (std.mem.eql(u8, arg, "--summary") or std.mem.eql(u8, arg, "--compact-summary")) {
            diff_output_mode = .summary;
        } else if (std.mem.eql(u8, arg, "--dirstat") or std.mem.eql(u8, arg, "--cumulative") or std.mem.eql(u8, arg, "--dirstat-by-file")) {
            diff_output_mode = .dirstat;
        } else if (std.mem.eql(u8, arg, "--patch-with-stat")) {
            diff_output_mode = .patch_with_stat;
        } else if (std.mem.eql(u8, arg, "--patch-with-raw")) {
            diff_output_mode = .patch_with_raw;
        } else if (std.mem.eql(u8, arg, "--check")) {
            check_mode = true;
        } else if (std.mem.eql(u8, arg, "--full-index") or std.mem.eql(u8, arg, "--binary") or
            std.mem.eql(u8, arg, "--abbrev") or std.mem.startsWith(u8, arg, "--abbrev=") or
            std.mem.eql(u8, arg, "--no-renames") or std.mem.eql(u8, arg, "-M") or std.mem.startsWith(u8, arg, "-M") or
            std.mem.eql(u8, arg, "-C") or std.mem.startsWith(u8, arg, "-C") or
            std.mem.eql(u8, arg, "--find-copies-harder") or
            std.mem.eql(u8, arg, "--color") or std.mem.startsWith(u8, arg, "--color=") or
            std.mem.eql(u8, arg, "--no-color") or
            std.mem.startsWith(u8, arg, "-U") or std.mem.startsWith(u8, arg, "--unified=") or
            std.mem.startsWith(u8, arg, "--diff-filter=") or
            std.mem.startsWith(u8, arg, "--submodule") or std.mem.startsWith(u8, arg, "--submodule=") or
            std.mem.startsWith(u8, arg, "--dirstat=") or
            std.mem.startsWith(u8, arg, "-G") or std.mem.startsWith(u8, arg, "-S") or
            std.mem.eql(u8, arg, "--pickaxe-regex") or std.mem.eql(u8, arg, "--pickaxe-all") or
            std.mem.eql(u8, arg, "--relative") or std.mem.startsWith(u8, arg, "--relative=") or
            std.mem.startsWith(u8, arg, "--diff-algorithm=") or
            std.mem.eql(u8, arg, "--patience") or std.mem.eql(u8, arg, "--histogram") or std.mem.eql(u8, arg, "--minimal") or
            std.mem.eql(u8, arg, "--indent-heuristic") or std.mem.eql(u8, arg, "--no-indent-heuristic") or
            std.mem.startsWith(u8, arg, "--inter-hunk-context=") or
            std.mem.startsWith(u8, arg, "--stat=") or std.mem.startsWith(u8, arg, "--stat-width=") or
            std.mem.startsWith(u8, arg, "--stat-name-width=") or std.mem.startsWith(u8, arg, "--stat-count=") or
            std.mem.startsWith(u8, arg, "--line-prefix=") or
            std.mem.eql(u8, arg, "--function-context") or std.mem.eql(u8, arg, "--ext-diff") or std.mem.eql(u8, arg, "--no-ext-diff") or
            std.mem.eql(u8, arg, "--textconv") or std.mem.eql(u8, arg, "--no-textconv") or
            std.mem.eql(u8, arg, "--word-diff") or std.mem.startsWith(u8, arg, "--word-diff=") or
            std.mem.startsWith(u8, arg, "--word-diff-regex=") or
            std.mem.eql(u8, arg, "--text") or std.mem.eql(u8, arg, "-a") or
            std.mem.eql(u8, arg, "--no-index") or std.mem.eql(u8, arg, "--ita-invisible-in-index") or
            std.mem.eql(u8, arg, "--ita-visible-in-index") or
            std.mem.eql(u8, arg, "-R") or
            std.mem.startsWith(u8, arg, "--output=") or
            std.mem.startsWith(u8, arg, "-O") or std.mem.startsWith(u8, arg, "--diff-filter=") or
            std.mem.eql(u8, arg, "--follow") or std.mem.eql(u8, arg, "--no-follow") or
            std.mem.eql(u8, arg, "--ignore-submodules") or std.mem.startsWith(u8, arg, "--ignore-submodules=") or
            std.mem.eql(u8, arg, "--src-prefix") or std.mem.startsWith(u8, arg, "--src-prefix=") or
            std.mem.eql(u8, arg, "--dst-prefix") or std.mem.startsWith(u8, arg, "--dst-prefix=") or
            std.mem.eql(u8, arg, "--no-prefix") or
            std.mem.eql(u8, arg, "--default-prefix") or
            std.mem.eql(u8, arg, "--cc") or
            std.mem.eql(u8, arg, "--combined-all-paths") or
            std.mem.eql(u8, arg, "--merge-base") or
            std.mem.eql(u8, arg, "--anchored") or std.mem.startsWith(u8, arg, "--anchored=") or
            std.mem.startsWith(u8, arg, "--break-rewrites") or std.mem.startsWith(u8, arg, "-B") or
            std.mem.eql(u8, arg, "--find-renames") or std.mem.startsWith(u8, arg, "--find-renames=") or
            std.mem.eql(u8, arg, "--find-copies") or std.mem.startsWith(u8, arg, "--find-copies=") or
            std.mem.eql(u8, arg, "--irreversible-delete") or std.mem.eql(u8, arg, "-D") or
            std.mem.eql(u8, arg, "-l") or std.mem.startsWith(u8, arg, "-l") or
            std.mem.eql(u8, arg, "--no-rename-empty") or std.mem.eql(u8, arg, "--rename-empty") or
            std.mem.startsWith(u8, arg, "--rotate-to=") or std.mem.startsWith(u8, arg, "--skip-to=") or
            std.mem.startsWith(u8, arg, "--ws-error-highlight=") or
            std.mem.startsWith(u8, arg, "--max-depth=") or
            std.mem.eql(u8, arg, "-r") or // recursive (default for diff, accepted for compat)
            std.mem.eql(u8, arg, "--no-abbrev") or
            std.mem.eql(u8, arg, "-t") or // show tree entries
            std.mem.eql(u8, arg, "--color-moved") or std.mem.startsWith(u8, arg, "--color-moved=") or
            std.mem.eql(u8, arg, "--color-moved-ws") or std.mem.startsWith(u8, arg, "--color-moved-ws=") or
            std.mem.startsWith(u8, arg, "-I") or // ignore matching lines
            std.mem.eql(u8, arg, "--") // catch-all for -- which is handled above
        )
        {
            // Known flags - accept but may not fully implement
        } else if (std.mem.startsWith(u8, arg, "--")) {
            // helpers.Unknown long option - accept silently for compat
        } else {
            try positional.append(arg);
        }
    }
    
    // helpers.Handle commit-to-commit diff, or treat as pathspecs if unresolvable
    var single_ref: ?[]const u8 = null;
    if (positional.items.len >= 1) {
        var ref1: []const u8 = undefined;
        var ref2: []const u8 = undefined;
        var have_two_refs = false;
        var have_one_ref = false;
        var pos_as_pathspec = false;
        
        if (std.mem.indexOf(u8, positional.items[0], "..")) |dot_pos| {
            ref1 = positional.items[0][0..dot_pos];
            ref2 = positional.items[0][dot_pos + 2 ..];
            if (ref2.len > 0 and ref2[0] == '.') ref2 = ref2[1..];
            have_two_refs = true;
        } else {
            // helpers.Try resolving as ref
            const mt = helpers.resolveToTree(allocator, positional.items[0], git_path, platform_impl) catch null;
            if (mt) |t1| {
                if (positional.items.len >= 2) {
                    const mt2 = helpers.resolveToTree(allocator, positional.items[1], git_path, platform_impl) catch null;
                    if (mt2) |t2| {
                        ref1 = positional.items[0]; ref2 = positional.items[1]; have_two_refs = true;
                        allocator.free(t2);
                        for (positional.items[2..]) |p| try pathspec_args.append(p);
                    } else { allocator.free(t1); pos_as_pathspec = true; }
                } else {
                    // helpers.Single ref: compare that ref to working tree (or index if --cached)
                    have_one_ref = true;
                    single_ref = positional.items[0];
                }
                if (!pos_as_pathspec and !have_two_refs and !have_one_ref) allocator.free(t1);
            } else { pos_as_pathspec = true; }
        }
        if (pos_as_pathspec) { for (positional.items) |p| try pathspec_args.append(p); }
        
        if (have_two_refs) {
            const tree1 = helpers.resolveToTree(allocator, ref1, git_path, platform_impl) catch {
                const msg = try std.fmt.allocPrint(allocator, "fatal: bad revision '{s}'\n", .{ref1});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(128);
            };
            defer allocator.free(tree1);
            const tree2 = helpers.resolveToTree(allocator, ref2, git_path, platform_impl) catch {
                const msg = try std.fmt.allocPrint(allocator, "fatal: bad revision '{s}'\n", .{ref2});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(128);
            };
            defer allocator.free(tree2);
            if (diff_output_mode == .name_only or diff_output_mode == .name_status or diff_output_mode == .numstat or diff_output_mode == .stat or diff_output_mode == .shortstat or diff_output_mode == .raw or diff_output_mode == .no_patch or diff_output_mode == .summary or diff_output_mode == .dirstat) {
                // helpers.Use tree comparison to get file-level changes, then output in requested format
                var diff_entries = std.ArrayList(helpers.DiffStatEntry).init(allocator);
                defer {
                    for (diff_entries.items) |*de| {
                        allocator.free(de.path);
                    }
                    diff_entries.deinit();
                }
                try helpers.collectTreeDiffEntries(allocator, tree1, tree2, "", git_path, pathspec_args.items, platform_impl, &diff_entries);
                if (diff_output_mode != .no_patch) {
                    try helpers.outputDiffEntries(diff_entries.items, diff_output_mode, platform_impl, allocator);
                }
                if ((exit_code or quiet) and diff_entries.items.len > 0) {
                    std.process.exit(1);
                }
            } else {
                const has_diff2 = try cmd_diff_tree.diffTwoTreesPatch(allocator, tree1, tree2, "", git_path, quiet or check_mode, pathspec_args.items, platform_impl);
                if (check_mode) {
                    // TODO: check whitespace in tree diff
                }
                if ((exit_code or (quiet and has_diff2)) and has_diff2) {
                    std.process.exit(1);
                }
            }
            return;
        }
    }
    
    // helpers.Load index 
    var index = index_mod.Index.load(git_path, platform_impl, allocator) catch |err| switch (err) {
        error.FileNotFound => index_mod.Index.init(allocator),
        else => return err,
    };
    defer index.deinit();
    
    const cwd = try platform_impl.fs.getCwd(allocator);
    defer allocator.free(cwd);
    
    var has_diff = false;
    const use_stat = diff_output_mode == .stat or diff_output_mode == .shortstat or diff_output_mode == .numstat or diff_output_mode == .name_only or diff_output_mode == .name_status or diff_output_mode == .raw or diff_output_mode == .no_patch or diff_output_mode == .summary or diff_output_mode == .dirstat;
    if (use_stat) {
        // helpers.Collect diff entries for stat/name output
        var diff_entries = std.ArrayList(helpers.DiffStatEntry).init(allocator);
        defer {
            for (diff_entries.items) |e| {
                allocator.free(e.path);
            }
            diff_entries.deinit();
        }
        if (single_ref) |sref| {
            // helpers.Compare ref tree to working tree (or index if cached)
            has_diff = helpers.collectRefDiffEntries(sref, &index, cwd, git_path, platform_impl, allocator, &diff_entries, cached) catch false;
        } else if (cached) {
            has_diff = helpers.collectStagedDiffEntries(&index, git_path, platform_impl, allocator, &diff_entries) catch false;
        } else {
            has_diff = helpers.collectWorkingTreeDiffEntries(&index, cwd, git_path, platform_impl, allocator, &diff_entries) catch false;
        }
        try helpers.outputDiffEntries(diff_entries.items, diff_output_mode, platform_impl, allocator);
    } else {
        if (single_ref) |sref| {
            // helpers.Compare ref tree to working tree
            const tree_hash = helpers.resolveToTree(allocator, sref, git_path, platform_impl) catch {
                const msg = try std.fmt.allocPrint(allocator, "fatal: bad revision '{s}'\n", .{sref});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(128);
            };
            defer allocator.free(tree_hash);
            // helpers.For now, compare tree to index and show patch
            // helpers.Get helpers.HEAD tree for comparison
            has_diff = cmd_show.showRefToWorkingTreeDiff(sref, &index, cwd, git_path, platform_impl, allocator, quiet or check_mode, cached) catch false;
        } else if (cached) {
            // helpers.Show differences between index and helpers.HEAD (staged changes)
            has_diff = cmd_show.showStagedDiff(&index, git_path, platform_impl, allocator, quiet or check_mode) catch false;
        } else {
            // helpers.Show differences between working tree and index
            has_diff = cmd_show.showWorkingTreeDiff(&index, cwd, platform_impl, allocator, quiet or check_mode) catch false;
        }
    }
    
    var ws_errors = false;
    if (check_mode) {
        // helpers.In check mode, we need to re-run the diff and check for whitespace errors
        // helpers.For now, check working tree for trailing whitespace in modified files
        if (positional.items.len == 0) {
            // helpers.Check for whitespace errors in changed files
            for (index.entries.items) |entry| {
                if (pathspec_args.items.len > 0) {
                    var matches = false;
                    for (pathspec_args.items) |ps| {
                        if (helpers.pathspecMatch(ps, entry.path)) { matches = true; break; }
                    }
                    if (!matches) continue;
                }
                // helpers.Get the content to check
                var check_content: []const u8 = undefined;
                var check_content_owned = false;
                if (cached) {
                    // Cached: check the index (staged) content
                    var idx_hash_buf: [40]u8 = undefined;
                    _ = std.fmt.bufPrint(&idx_hash_buf, "{}", .{std.fmt.fmtSliceHexLower(&entry.sha1)}) catch continue;
                    const idx_obj = objects.GitObject.load(&idx_hash_buf, git_path, platform_impl, allocator) catch continue;
                    defer idx_obj.deinit(allocator);
                    check_content = try allocator.dupe(u8, idx_obj.data);
                    check_content_owned = true;
                } else {
                    // Working tree: check the file content
                    check_content = platform_impl.fs.readFile(allocator, entry.path) catch continue;
                    check_content_owned = true;
                    // helpers.Compare with index to skip unchanged
                    var idx_hash_buf: [40]u8 = undefined;
                    _ = std.fmt.bufPrint(&idx_hash_buf, "{}", .{std.fmt.fmtSliceHexLower(&entry.sha1)}) catch continue;
                    if (objects.GitObject.load(&idx_hash_buf, git_path, platform_impl, allocator)) |idx_obj| {
                        defer idx_obj.deinit(allocator);
                        if (std.mem.eql(u8, check_content, idx_obj.data)) {
                            allocator.free(check_content);
                            continue;
                        }
                    } else |_| {}
                }
                defer if (check_content_owned) allocator.free(check_content);
                // helpers.Check content for whitespace errors
                var lines = std.mem.splitScalar(u8, check_content, '\n');
                var line_num: usize = 0;
                while (lines.next()) |line| {
                    line_num += 1;
                    if (line.len > 0 and (line[line.len - 1] == ' ' or line[line.len - 1] == '\t')) {
                        ws_errors = true;
                        const msg = try std.fmt.allocPrint(allocator, "{s}:{d}: trailing whitespace.\n+{s}\n", .{ entry.path, line_num, line });
                        defer allocator.free(msg);
                        try platform_impl.writeStdout(msg);
                    }
                    // helpers.Check for conflict markers
                    if (std.mem.startsWith(u8, line, "<<<<<<<") or
                        std.mem.startsWith(u8, line, "=======") or
                        std.mem.startsWith(u8, line, ">>>>>>>"))
                    {
                        ws_errors = true;
                        const msg = try std.fmt.allocPrint(allocator, "{s}:{d}: leftover conflict marker.\n+{s}\n", .{ entry.path, line_num, line });
                        defer allocator.free(msg);
                        try platform_impl.writeStdout(msg);
                    }
                }
            }
        }
        if (!quiet) {
            // Suppress normal diff output in check mode - it was already suppressed
        }
    }
    
    if (check_mode and exit_code) {
        var code: u8 = 0;
        if (has_diff) code |= 1;
        if (ws_errors) code |= 2;
        if (code != 0) std.process.exit(code);
    } else if (check_mode) {
        if (ws_errors) std.process.exit(2);
    } else if (exit_code and has_diff) {
        std.process.exit(1);
    }
}


pub fn cmdDiffNoIndex(allocator: std.mem.Allocator, diff_args: []const []const u8, platform_impl: *const platform_mod.Platform) !void {
    var exit_code = false;
    var quiet = false;
    var paths = std.ArrayList([]const u8).init(allocator);
    defer paths.deinit();
    var seen_dashdash = false;

    for (diff_args) |arg| {
        if (seen_dashdash) {
            try paths.append(arg);
        } else if (std.mem.eql(u8, arg, "--")) {
            seen_dashdash = true;
        } else if (std.mem.eql(u8, arg, "--no-index")) {
            // already handled
        } else if (std.mem.eql(u8, arg, "--exit-code")) {
            exit_code = true;
        } else if (std.mem.eql(u8, arg, "--quiet")) {
            quiet = true;
            exit_code = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            // ignore other flags for now
        } else {
            try paths.append(arg);
        }
    }

    if (paths.items.len < 2) {
        try platform_impl.writeStderr("usage: git diff --no-index <path> <path>\n");
        std.process.exit(129);
    }

    const path_a = paths.items[0];
    const path_b = paths.items[1];

    // helpers.Check if paths are directories
    const a_is_dir = if (std.fs.cwd().openDir(path_a, .{})) |d| blk: { var dd = d; dd.close(); break :blk true; } else |_| false;
    const b_is_dir = if (std.fs.cwd().openDir(path_b, .{})) |d| blk: { var dd = d; dd.close(); break :blk true; } else |_| false;

    var has_diff = false;
    if (a_is_dir and b_is_dir) {
        // helpers.Compare directories
        has_diff = try diffNoIndexDirs(allocator, path_a, path_b, quiet, platform_impl);
    } else {
        // helpers.Compare files
        has_diff = try diffNoIndexFiles(allocator, path_a, path_b, quiet, platform_impl);
    }

    if (exit_code and has_diff) {
        std.process.exit(1);
    }
    if (has_diff and !exit_code) {
        std.process.exit(1);
    }
}


pub fn cmdDiffFiles(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    // diff-files: compare index against working tree
    var name_only = false;
    var name_status = false;
    var exit_code = false;
    var df_patch = false;
    var df_suppress = false;
    var df_show_raw = false;
    var df_patch_with_raw = false;
    var df_pathspecs = std.ArrayList([]const u8).init(allocator);
    defer df_pathspecs.deinit();
    var df_seen_dashdash = false;
    while (args.next()) |arg| {
        if (df_seen_dashdash) {
            try df_pathspecs.append(arg);
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            df_seen_dashdash = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--name-only")) {
            name_only = true;
            df_suppress = false;
        } else if (std.mem.eql(u8, arg, "--name-status")) {
            name_status = true;
            df_suppress = false;
        } else if (std.mem.eql(u8, arg, "--exit-code")) {
            exit_code = true;
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            exit_code = true;
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "-u") or std.mem.eql(u8, arg, "--patch")) {
            df_patch = true;
            df_suppress = false;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--no-patch")) {
            df_suppress = true;
            df_patch = false;
            df_patch_with_raw = false;
            df_show_raw = false;
            name_only = false;
            name_status = false;
        } else if (std.mem.eql(u8, arg, "--raw")) {
            df_show_raw = true;
            df_suppress = false;
        } else if (std.mem.eql(u8, arg, "--patch-with-raw")) {
            df_patch = true;
            df_patch_with_raw = true;
            df_suppress = false;
        } else if (std.mem.eql(u8, arg, "--patch-with-stat") or std.mem.eql(u8, arg, "--stat") or
            std.mem.eql(u8, arg, "--numstat") or std.mem.eql(u8, arg, "--shortstat") or
            std.mem.eql(u8, arg, "--compact-summary"))
        {
            df_suppress = false;
        } else if (std.mem.eql(u8, arg, "--summary") or std.mem.eql(u8, arg, "--dirstat") or
            std.mem.eql(u8, arg, "--cumulative") or std.mem.eql(u8, arg, "--dirstat-by-file"))
        {
            df_suppress = true;
            df_patch = false;
            df_show_raw = false;
            name_only = false;
            name_status = false;
        }
    }
    const git_dir = helpers.findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
        unreachable;
    };
    defer allocator.free(git_dir);

    const repo_root = std.fs.path.dirname(git_dir) orelse ".";

    var idx = index_mod.Index.load(git_dir, platform_impl, allocator) catch return;
    defer idx.deinit();

    const zero_oid = "0000000000000000000000000000000000000000";
    var has_diffs = false;
    // helpers.For --patch-with-raw: collect raw lines and patch output separately
    var pwr_raw_buf = std.ArrayList(u8).init(allocator);
    defer pwr_raw_buf.deinit();
    var pwr_patch_buf = std.ArrayList(u8).init(allocator);
    defer pwr_patch_buf.deinit();

    for (idx.entries.items) |entry| {
        // helpers.Skip assume-unchanged entries
        if ((entry.flags & 0x8000) != 0) continue;

        // Filter by pathspecs
        if (df_pathspecs.items.len > 0) {
            var path_matches = false;
            for (df_pathspecs.items) |ps| {
                if (helpers.pathspecMatch(ps, entry.path)) {
                    path_matches = true;
                    break;
                }
            }
            if (!path_matches) continue;
        }

        // helpers.Build full path from repo root
        const full_path = if (repo_root.len > 0 and !std.mem.eql(u8, repo_root, "."))
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, entry.path })
        else
            try allocator.dupe(u8, entry.path);
        defer allocator.free(full_path);

        // helpers.Use lstat (no follow) to properly handle symlinks
        const is_symlink_in_index = (entry.mode & 0o170000) == 0o120000;

        // helpers.Check if path exists - for symlinks, check the link itself
        var link_buf: [4096]u8 = undefined;
        const is_symlink_on_disk = if (std.fs.cwd().readLink(full_path, &link_buf)) |_| true else |_| false;

        // helpers.Try to get file info
        const file_exists = if (is_symlink_on_disk) true else if (std.fs.cwd().access(full_path, .{})) |_| true else |_| false;

        if (!file_exists) {
            // File deleted
            has_diffs = true;
            if (df_suppress) continue;
            var hash_buf: [40]u8 = undefined;
            _ = std.fmt.bufPrint(&hash_buf, "{}", .{std.fmt.fmtSliceHexLower(&entry.sha1)}) catch unreachable;
            if (name_only) {
                const line = try std.fmt.allocPrint(allocator, "{s}\n", .{entry.path});
                defer allocator.free(line);
                try platform_impl.writeStdout(line);
            } else if (name_status) {
                const line = try std.fmt.allocPrint(allocator, "D\t{s}\n", .{entry.path});
                defer allocator.free(line);
                try platform_impl.writeStdout(line);
            } else {
                if (!df_patch or df_patch_with_raw or df_show_raw) {
                    const line = try std.fmt.allocPrint(allocator, ":{o:0>6} 000000 {s} {s} D\t{s}\n", .{ entry.mode, &hash_buf, zero_oid, entry.path });
                    defer allocator.free(line);
                    if (df_patch_with_raw) { try pwr_raw_buf.appendSlice(line); } else { try platform_impl.writeStdout(line); }
                }
                if (df_patch) {
                    const indexed_content = helpers.getIndexedFileContent(entry, allocator) catch "";
                    defer if (indexed_content.len > 0) allocator.free(indexed_content);
                    var out = std.ArrayList(u8).init(allocator);
                    defer out.deinit();
                    try out.appendSlice("diff --git a/");
                    try out.appendSlice(entry.path);
                    try out.appendSlice(" b/");
                    try out.appendSlice(entry.path);
                    try out.appendSlice("\n");
                    const mode_str = try std.fmt.allocPrint(allocator, "deleted file mode {o:0>6}\n", .{entry.mode});
                    defer allocator.free(mode_str);
                    try out.appendSlice(mode_str);
                    const del_idx_line = try std.fmt.allocPrint(allocator, "index {s}..{s}\n", .{ hash_buf[0..7], zero_oid[0..7] });
                    defer allocator.free(del_idx_line);
                    try out.appendSlice(del_idx_line);
                    try out.appendSlice("--- a/");
                    try out.appendSlice(entry.path);
                    try out.appendSlice("\n+++ /dev/null\n");
                    if (indexed_content.len > 0) {
                        var liter = std.mem.splitScalar(u8, indexed_content, '\n');
                        var lines_arr = std.ArrayList([]const u8).init(allocator);
                        defer lines_arr.deinit();
                        while (liter.next()) |ln| try lines_arr.append(ln);
                        if (lines_arr.items.len > 0 and indexed_content[indexed_content.len - 1] == '\n') _ = lines_arr.pop();
                        const hh = try std.fmt.allocPrint(allocator, "@@ -1,{d} +0,0 @@\n", .{lines_arr.items.len});
                        defer allocator.free(hh);
                        try out.appendSlice(hh);
                        for (lines_arr.items) |ln| {
                            try out.append('-');
                            try out.appendSlice(ln);
                            try out.append('\n');
                        }
                        if (indexed_content[indexed_content.len - 1] != '\n') {
                            try out.appendSlice("\\\\ helpers.No newline at end of file\n");
                        }
                    }
                    if (df_patch_with_raw) { try pwr_patch_buf.appendSlice(out.items); } else { try platform_impl.writeStdout(out.items); }
                }
            }
            continue;
        }

        // helpers.Determine working tree mode
        const wt_mode: u32 = wt_blk: {
            if (is_symlink_on_disk) break :wt_blk 0o120000;
            if (std.fs.cwd().statFile(full_path)) |st| {
                if ((st.mode & 0o111) != 0) break :wt_blk 0o100755;
            } else |_| {}
            break :wt_blk 0o100644;
        };

        // helpers.Compare to detect modifications
        var modified = false;

        // helpers.If index entry has zeroed stat cache (e.g., from read-tree), always mark as modified
        if (entry.ctime_sec == 0 and entry.ctime_nsec == 0 and entry.mtime_sec == 0 and entry.mtime_nsec == 0 and entry.ino == 0) {
            modified = true;
        } else if (is_symlink_in_index != is_symlink_on_disk) {
            // Type changed (symlink <-> regular file)
            modified = true;
        } else if (!is_symlink_on_disk) {
            // Regular files - check stat
            if (std.fs.cwd().statFile(full_path)) |stat_result| {
                const file_size: u32 = @intCast(@min(stat_result.size, std.math.maxInt(u32)));
                if (entry.size != file_size and entry.size != 0) {
                    modified = true;
                } else {
                    // helpers.Compare mtime
                    const mtime_s: u32 = @intCast(@max(0, @divTrunc(stat_result.mtime, std.time.ns_per_s)));
                    const mtime_ns: u32 = @intCast(@max(0, @rem(stat_result.mtime, std.time.ns_per_s)));
                    if (entry.mtime_sec != mtime_s or entry.mtime_nsec != mtime_ns or entry.size == 0) {
                        // Stat mismatch or smeared entry (size=0) - compare content hash
                        const content = platform_impl.fs.readFile(allocator, full_path) catch {
                            modified = true;
                            continue;
                        };
                        defer allocator.free(content);
                        const blob_header = std.fmt.allocPrint(allocator, "blob {d}\x00", .{content.len}) catch {
                            modified = true;
                            continue;
                        };
                        defer allocator.free(blob_header);
                        var hasher = std.crypto.hash.Sha1.init(.{});
                        hasher.update(blob_header);
                        hasher.update(content);
                        var file_hash: [20]u8 = undefined;
                        hasher.final(&file_hash);
                        if (!std.mem.eql(u8, &file_hash, &entry.sha1)) {
                            modified = true;
                        }
                    }
                }
            } else |_| {
                modified = true;
            }
        } else {
            // Symlink - check stat (mtime/size)
            // helpers.For symlinks, size in index is the length of the target path
            // Since we can't easily lstat, compare by content if stat check is uncertain
            const link_target = std.fs.cwd().readLink(full_path, &link_buf) catch {
                modified = true;
                continue;
            };
            // Hash the symlink target to compare with index
            const blob_content = try std.fmt.allocPrint(allocator, "blob {d}\x00{s}", .{ link_target.len, link_target });
            defer allocator.free(blob_content);
            var hash: [20]u8 = undefined;
            std.crypto.hash.Sha1.hash(blob_content, &hash, .{});
            if (!std.mem.eql(u8, &hash, &entry.sha1)) {
                modified = true;
            }
        }

        if (modified) {
            has_diffs = true;
            if (df_suppress) continue;
            var hash_buf: [40]u8 = undefined;
            _ = std.fmt.bufPrint(&hash_buf, "{}", .{std.fmt.fmtSliceHexLower(&entry.sha1)}) catch unreachable;
            if (name_only) {
                const line = try std.fmt.allocPrint(allocator, "{s}\n", .{entry.path});
                defer allocator.free(line);
                try platform_impl.writeStdout(line);
            } else if (name_status) {
                const line = try std.fmt.allocPrint(allocator, "M\t{s}\n", .{entry.path});
                defer allocator.free(line);
                try platform_impl.writeStdout(line);
            } else {
                if (!df_patch or df_patch_with_raw or df_show_raw) {
                    const line = try std.fmt.allocPrint(allocator, ":{o:0>6} {o:0>6} {s} {s} M\t{s}\n", .{ entry.mode, wt_mode, &hash_buf, zero_oid, entry.path });
                    defer allocator.free(line);
                    if (df_patch_with_raw) { try pwr_raw_buf.appendSlice(line); } else { try platform_impl.writeStdout(line); }
                }
                if (df_patch) {
                    const indexed_content = helpers.getIndexedFileContent(entry, allocator) catch "";
                    defer if (indexed_content.len > 0) allocator.free(indexed_content);
                    const wt_content = blk: {
                        if (is_symlink_on_disk) {
                            const lt = std.fs.cwd().readLink(full_path, &link_buf) catch break :blk try allocator.dupe(u8, "");
                            break :blk try allocator.dupe(u8, lt);
                        }
                        break :blk platform_impl.fs.readFile(allocator, full_path) catch try allocator.dupe(u8, "");
                    };
                    defer allocator.free(wt_content);
                    var out = std.ArrayList(u8).init(allocator);
                    defer out.deinit();
                    try out.appendSlice("diff --git a/");
                    try out.appendSlice(entry.path);
                    try out.appendSlice(" b/");
                    try out.appendSlice(entry.path);
                    try out.appendSlice("\n");
                    if (entry.mode != wt_mode) {
                        const old_m = try std.fmt.allocPrint(allocator, "old mode {o:0>6}\n", .{entry.mode});
                        defer allocator.free(old_m);
                        try out.appendSlice(old_m);
                        const new_m = try std.fmt.allocPrint(allocator, "new mode {o:0>6}\n", .{wt_mode});
                        defer allocator.free(new_m);
                        try out.appendSlice(new_m);
                    }
                    if (!std.mem.eql(u8, indexed_content, wt_content)) {
                        if (helpers.isBinaryContent(indexed_content) or helpers.isBinaryContent(wt_content)) {
                            // helpers.Add index line for binary
                            if (entry.mode == wt_mode) {
                                const idx_line = try std.fmt.allocPrint(allocator, "index {s}..{s} {o:0>6}\n", .{ hash_buf[0..7], zero_oid[0..7], entry.mode });
                                defer allocator.free(idx_line);
                                try out.appendSlice(idx_line);
                            }
                            try out.appendSlice("Binary files differ\n");
                        } else {
                            // helpers.Add index line
                            if (entry.mode == wt_mode) {
                                const idx_line = try std.fmt.allocPrint(allocator, "index {s}..{s} {o:0>6}\n", .{ hash_buf[0..7], zero_oid[0..7], entry.mode });
                                defer allocator.free(idx_line);
                                try out.appendSlice(idx_line);
                            } else {
                                const idx_line = try std.fmt.allocPrint(allocator, "index {s}..{s}\n", .{ hash_buf[0..7], zero_oid[0..7] });
                                defer allocator.free(idx_line);
                                try out.appendSlice(idx_line);
                            }
                            try out.appendSlice("--- a/");
                            try out.appendSlice(entry.path);
                            try out.appendSlice("\n+++ b/");
                            try out.appendSlice(entry.path);
                            try out.appendSlice("\n");
                            const diff_output = diff_mod.generateUnifiedDiffWithHashes(indexed_content, wt_content, entry.path, hash_buf[0..7], zero_oid[0..7], allocator) catch {
                                if (df_patch_with_raw) { try pwr_patch_buf.appendSlice(out.items); } else { try platform_impl.writeStdout(out.items); }
                                continue;
                            };
                            defer allocator.free(diff_output);
                            if (std.mem.indexOf(u8, diff_output, "\n@@")) |hs| {
                                try out.appendSlice(diff_output[hs + 1 ..]);
                            } else if (std.mem.startsWith(u8, diff_output, "@@")) {
                                try out.appendSlice(diff_output);
                            }
                        }
                    }
                    if (df_patch_with_raw) { try pwr_patch_buf.appendSlice(out.items); } else { try platform_impl.writeStdout(out.items); }
                }
            }
        }
    }

    // helpers.Output collected patch-with-raw buffers
    if (df_patch_with_raw and pwr_raw_buf.items.len > 0) {
        try platform_impl.writeStdout(pwr_raw_buf.items);
        try platform_impl.writeStdout("\n");
        if (pwr_patch_buf.items.len > 0) try platform_impl.writeStdout(pwr_patch_buf.items);
    }
    if (exit_code and has_diffs) {
        std.process.exit(1);
    }
}

// =============================================================================
// helpers.Phase 2: Pure helpers.Zig implementations of previously non-native commands
// =============================================================================


pub fn nativeCmdDiffTree(_: std.mem.Allocator, args: [][]const u8, command_index: usize, platform_impl: *const platform_mod.Platform) !void {
    const allocator = std.heap.page_allocator;
    const rest = args[command_index + 1 ..];
    
    var recursive = false;
    var show_patch = false;
    var show_root = false;
    var name_only = false;
    var name_status = false;
    var no_commit_id = false;
    var quiet = false;
    var abbrev_len: ?usize = null; // null = no abbrev, 0 = default (7)
    var full_index = false;
    var show_stat = false;
    var show_summary = false;
    var show_raw = true; // default for diff-tree
    var patch_with_stat = false;
    var patch_with_raw = false;
    var show_shortstat = false;
    var pretty_fmt: ?[]const u8 = null;
    var show_pretty = false;
    var show_cc = false;
    var show_combined = false;
    var show_m = false;
    var first_parent = false;
    var show_notes = false;
    var format_str: ?[]const u8 = null;
    var compact_summary = false;
    var reverse_diff = false;
    var stdin_mode = false;
    var show_tree = false;
    var line_prefix: []const u8 = "";
    var dt_exit_code = false;
    var tree_refs = std.ArrayList([]const u8).init(allocator);
    defer tree_refs.deinit();
    var pathspecs = std.ArrayList([]const u8).init(allocator);
    defer pathspecs.deinit();
    var seen_dashdash = false;
    
    for (rest) |arg| {
        if (seen_dashdash) {
            try pathspecs.append(arg);
        } else if (std.mem.eql(u8, arg, "--")) {
            seen_dashdash = true;
        } else if (std.mem.eql(u8, arg, "-r")) {
            recursive = true;
        } else if (std.mem.eql(u8, arg, "-t")) {
            recursive = true;
            show_tree = true;
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--patch") or std.mem.eql(u8, arg, "-u")) {
            show_patch = true;
            show_raw = false;
            recursive = true;
        } else if (std.mem.eql(u8, arg, "--root")) {
            show_root = true;
        } else if (std.mem.eql(u8, arg, "--name-only")) {
            name_only = true;
        } else if (std.mem.eql(u8, arg, "--name-status")) {
            name_status = true;
        } else if (std.mem.eql(u8, arg, "--no-commit-id")) {
            no_commit_id = true;
        } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
            quiet = true;
        } else if (std.mem.eql(u8, arg, "--abbrev")) {
            abbrev_len = 0; // default
        } else if (std.mem.startsWith(u8, arg, "--abbrev=")) {
            abbrev_len = std.fmt.parseInt(usize, arg["--abbrev=".len..], 10) catch 7;
        } else if (std.mem.eql(u8, arg, "--full-index")) {
            full_index = true;
        } else if (std.mem.eql(u8, arg, "--stat")) {
            show_stat = true;
            show_raw = false;
        } else if (std.mem.eql(u8, arg, "--summary")) {
            show_summary = true;
            show_raw = false;
        } else if (std.mem.eql(u8, arg, "--shortstat")) {
            show_shortstat = true;
            show_raw = false;
        } else if (std.mem.eql(u8, arg, "--patch-with-stat")) {
            patch_with_stat = true;
            show_patch = true;
            show_stat = true;
            show_raw = false;
            recursive = true;
        } else if (std.mem.eql(u8, arg, "--patch-with-raw")) {
            patch_with_raw = true;
            show_patch = true;
            show_raw = true;
            recursive = true;
        } else if (std.mem.eql(u8, arg, "--pretty") or std.mem.eql(u8, arg, "--pretty=medium")) {
            show_pretty = true;
            pretty_fmt = "medium";
        } else if (std.mem.startsWith(u8, arg, "--pretty=")) {
            show_pretty = true;
            pretty_fmt = arg["--pretty=".len..];
        } else if (std.mem.startsWith(u8, arg, "--format=")) {
            format_str = arg["--format=".len..];
            show_pretty = true;
        } else if (std.mem.eql(u8, arg, "--cc")) {
            show_cc = true;
            show_raw = false;
        } else if (std.mem.eql(u8, arg, "-c")) {
            show_combined = true;
            show_raw = false;
        } else if (std.mem.eql(u8, arg, "-m")) {
            show_m = true;
        } else if (std.mem.eql(u8, arg, "--first-parent")) {
            first_parent = true;
        } else if (std.mem.eql(u8, arg, "--notes")) {
            show_notes = true;
        } else if (std.mem.eql(u8, arg, "--compact-summary")) {
            compact_summary = true;
        } else if (std.mem.eql(u8, arg, "-R")) {
            reverse_diff = true;
        } else if (std.mem.eql(u8, arg, "--exit-code")) {
            dt_exit_code = true;
        } else if (std.mem.eql(u8, arg, "--stdin")) {
            stdin_mode = true;
        } else if (std.mem.startsWith(u8, arg, "--line-prefix=")) {
            line_prefix = arg["--line-prefix=".len..];
        } else if (std.mem.eql(u8, arg, "-h")) {
            try platform_impl.writeStdout("usage: git diff-tree [<options>] <tree-ish> [<tree-ish>] [<path>...]\n");
            std.process.exit(129);
        } else if (std.mem.startsWith(u8, arg, "-")) {
            // skip unknown flags
        } else {
            try tree_refs.append(arg);
        }
    }
    // --cc defaults to patch mode if no other format flags given
    if (show_cc and !show_patch and !show_stat and !show_shortstat and !show_summary and !patch_with_stat and !patch_with_raw) {
        show_patch = true;
        recursive = true;
    }
    // --cc with --stat should show stat only (not patch)
    // --cc with --patch-with-stat should show both
    if (show_cc) {
        recursive = true;
    }

    // helpers.Build options struct
    const dt_opts = helpers.DiffTreeOpts{
        .recursive = recursive,
        .show_patch = show_patch,
        .show_root = show_root,
        .name_only = name_only,
        .name_status = name_status,
        .no_commit_id = no_commit_id,
        .quiet = quiet,
        .abbrev_len = abbrev_len,
        .full_index = full_index,
        .show_stat = show_stat,
        .show_summary = show_summary,
        .show_raw = show_raw,
        .patch_with_stat = patch_with_stat,
        .patch_with_raw = patch_with_raw,
        .show_shortstat = show_shortstat,
        .show_pretty = show_pretty,
        .pretty_fmt = pretty_fmt,
        .show_cc = show_cc,
        .show_combined = show_combined,
        .show_m = show_m,
        .first_parent = first_parent,
        .show_notes = show_notes,
        .format_str = format_str,
        .compact_summary = compact_summary,
        .reverse_diff = reverse_diff,
        .stdin_mode = stdin_mode,
        .line_prefix = line_prefix,
        .show_tree = show_tree,
    };
    
    var had_diff = false;
    
    if (tree_refs.items.len == 0) {
        // helpers.Read commit hashes from stdin
        const stdin_data = helpers.readStdin(allocator, 1024 * 1024) catch return;
        defer allocator.free(stdin_data);
        var line_it = std.mem.splitScalar(u8, stdin_data, '\n');
        while (line_it.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            const d = cmd_diff_tree.diffTreeForCommit(allocator, trimmed, &dt_opts, pathspecs.items, platform_impl) catch false;
            if (d) had_diff = true;
        }
    } else if (tree_refs.items.len == 1) {
        had_diff = try cmd_diff_tree.diffTreeForCommit(allocator, tree_refs.items[0], &dt_opts, pathspecs.items, platform_impl);
    } else {
        // helpers.Resolve both helpers.refs to tree hashes
        const git_path = helpers.findGitDirectory(allocator, platform_impl) catch {
            try platform_impl.writeStderr("fatal: not a git repository\n");
            std.process.exit(128);
        };
        defer allocator.free(git_path);
        const tree1 = helpers.resolveToTree(allocator, tree_refs.items[0], git_path, platform_impl) catch {
            const msg = try std.fmt.allocPrint(allocator, "fatal: bad object {s}\n", .{tree_refs.items[0]});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
        };
        defer allocator.free(tree1);
        const tree2 = helpers.resolveToTree(allocator, tree_refs.items[1], git_path, platform_impl) catch {
            const msg = try std.fmt.allocPrint(allocator, "fatal: bad object {s}\n", .{tree_refs.items[1]});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
        };
        defer allocator.free(tree2);
        if (dt_opts.show_stat or dt_opts.show_shortstat or (dt_opts.show_summary and !dt_opts.show_patch)) {
            var stat_entries = std.ArrayList(helpers.DiffStatEntry).init(allocator);
            defer { for (stat_entries.items) |*de| allocator.free(de.path); stat_entries.deinit(); }
            try helpers.collectTreeDiffEntries(allocator, tree1, tree2, "", git_path, pathspecs.items, platform_impl, &stat_entries);
            if (stat_entries.items.len > 0) had_diff = true;
            if (dt_opts.show_stat) {
                try helpers.formatDiffStat(stat_entries.items, platform_impl, allocator);
            } else if (dt_opts.show_shortstat) {
                try helpers.formatDiffShortStat(stat_entries.items, platform_impl, allocator);
            }
            if (dt_opts.show_summary) {
                try helpers.outputSummaryForTwoTrees(allocator, tree1, tree2, git_path, pathspecs.items, platform_impl);
            }
        } else {
            const d = try cmd_diff_tree.diffTwoTreesFiltered(allocator, tree1, tree2, "", &dt_opts, pathspecs.items, platform_impl);
            if (d) had_diff = true;
        }
    }
    
    // helpers.If --quiet or --exit-code, exit 1 when there were differences
    if ((quiet or dt_exit_code) and had_diff) {
        std.process.exit(1);
    }
}


pub fn nativeCmdDiffIndex(_: std.mem.Allocator, args: [][]const u8, command_index: usize, platform_impl: *const platform_mod.Platform) !void {
    const allocator = std.heap.page_allocator;
    const rest = args[command_index + 1 ..];
    var cached = false;
    var exit_code_flag = false;
    var patch_mode = false;
    var suppress_output = false;
    var name_status = false;
    var name_only = false;
    var di_ignore_submodules = false;
    var tree_ish: ?[]const u8 = null;
    var pathspecs = std.ArrayList([]const u8).init(allocator);
    defer pathspecs.deinit();
    var seen_dashdash = false;

    for (rest) |arg| {
        if (seen_dashdash) {
            try pathspecs.append(arg);
        } else if (std.mem.eql(u8, arg, "-h")) {
            try platform_impl.writeStdout("usage: git diff-index [<options>] <tree-ish> [<path>...]\n");
            std.process.exit(129);
        } else if (std.mem.eql(u8, arg, "--cached") or std.mem.eql(u8, arg, "--staged")) {
            cached = true;
        } else if (std.mem.eql(u8, arg, "--exit-code")) {
            exit_code_flag = true;
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--patch")) {
            patch_mode = true;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--no-patch")) {
            suppress_output = true;
            patch_mode = false;
        } else if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
            suppress_output = true;
            exit_code_flag = true;
        } else if (std.mem.eql(u8, arg, "--name-status")) {
            name_status = true;
        } else if (std.mem.eql(u8, arg, "--name-only")) {
            name_only = true;
        } else if (std.mem.eql(u8, arg, "--ignore-submodules") or std.mem.startsWith(u8, arg, "--ignore-submodules=")) {
            di_ignore_submodules = true;
        } else if (std.mem.eql(u8, arg, "--")) {
            seen_dashdash = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (tree_ish == null) {
                tree_ish = arg;
            } else {
                try pathspecs.append(arg);
            }
        }
    }

    if (tree_ish == null) return;

    const git_dir = helpers.findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository\n");
        std.process.exit(128);
        unreachable;
    };
    defer allocator.free(git_dir);

    var idx = index_mod.Index.load(git_dir, platform_impl, allocator) catch return;
    defer idx.deinit();

    const tree_hash = helpers.resolveToTree(allocator, tree_ish.?, git_dir, platform_impl) catch return;
    defer allocator.free(tree_hash);

    var tree_entries = std.StringHashMap(helpers.TreeEntryInfo).init(allocator);
    defer {
        var kit = tree_entries.keyIterator();
        while (kit.next()) |k| allocator.free(k.*);
        tree_entries.deinit();
    }
    try helpers.walkTreeForDiffIndex(allocator, git_dir, tree_hash, "", &tree_entries, platform_impl);

    const zero_oid = "0000000000000000000000000000000000000000";
    var has_diffs = false;

    for (idx.entries.items) |entry| {
        // Skip submodule entries when --ignore-submodules is set
        if (di_ignore_submodules and entry.mode == 0o160000) continue;
        if (pathspecs.items.len > 0) {
            var matches = false;
            for (pathspecs.items) |ps| {
                if (helpers.pathspecMatch(ps, entry.path)) {
                    matches = true;
                    break;
                }
            }
            if (!matches) continue;
        }

        if (tree_entries.get(entry.path)) |te| {
            if (!std.mem.eql(u8, &te.hash, &entry.sha1) or te.mode != entry.mode) {
                has_diffs = true;
                var old_hash_buf: [40]u8 = undefined;
                _ = std.fmt.bufPrint(&old_hash_buf, "{}", .{std.fmt.fmtSliceHexLower(&te.hash)}) catch unreachable;
                var new_hash_buf: [40]u8 = undefined;
                _ = std.fmt.bufPrint(&new_hash_buf, "{}", .{std.fmt.fmtSliceHexLower(&entry.sha1)}) catch unreachable;
                if (!suppress_output) {
                    const line = if (name_status)
                        try std.fmt.allocPrint(allocator, "M\t{s}\n", .{entry.path})
                    else if (name_only)
                        try std.fmt.allocPrint(allocator, "{s}\n", .{entry.path})
                    else
                        try std.fmt.allocPrint(allocator, ":{o:0>6} {o:0>6} {s} {s} M\t{s}\n", .{ te.mode, entry.mode, &old_hash_buf, &new_hash_buf, entry.path });
                    defer allocator.free(line);
                    try platform_impl.writeStdout(line);
                }
            }
        } else {
            has_diffs = true;
            if (!suppress_output) {
                var new_hash_buf: [40]u8 = undefined;
                _ = std.fmt.bufPrint(&new_hash_buf, "{}", .{std.fmt.fmtSliceHexLower(&entry.sha1)}) catch unreachable;
                const line = if (name_status)
                    try std.fmt.allocPrint(allocator, "A\t{s}\n", .{entry.path})
                else if (name_only)
                    try std.fmt.allocPrint(allocator, "{s}\n", .{entry.path})
                else
                    try std.fmt.allocPrint(allocator, ":000000 {o:0>6} {s} {s} A\t{s}\n", .{ entry.mode, zero_oid, &new_hash_buf, entry.path });
                defer allocator.free(line);
                try platform_impl.writeStdout(line);
            }
        }
    }

    var tree_it = tree_entries.iterator();
    while (tree_it.next()) |kv| {
        // Skip submodule entries when --ignore-submodules is set
        if (di_ignore_submodules and kv.value_ptr.mode == 0o160000) continue;
        var found = false;
        for (idx.entries.items) |entry| {
            if (std.mem.eql(u8, entry.path, kv.key_ptr.*)) {
                found = true;
                break;
            }
        }
        if (!found) {
            if (pathspecs.items.len > 0) {
                var matches = false;
                for (pathspecs.items) |ps| {
                    if (helpers.pathspecMatch(ps, kv.key_ptr.*)) {
                        matches = true;
                        break;
                    }
                }
                if (!matches) continue;
            }
            has_diffs = true;
            if (!suppress_output) {
                var old_hash_buf: [40]u8 = undefined;
                _ = std.fmt.bufPrint(&old_hash_buf, "{}", .{std.fmt.fmtSliceHexLower(&kv.value_ptr.hash)}) catch unreachable;
                const line = if (name_status)
                    try std.fmt.allocPrint(allocator, "D\t{s}\n", .{kv.key_ptr.*})
                else if (name_only)
                    try std.fmt.allocPrint(allocator, "{s}\n", .{kv.key_ptr.*})
                else
                    try std.fmt.allocPrint(allocator, ":{o:0>6} 000000 {s} {s} D\t{s}\n", .{ kv.value_ptr.mode, &old_hash_buf, zero_oid, kv.key_ptr.* });
                defer allocator.free(line);
                try platform_impl.writeStdout(line);
            }
        }
    }

    if (exit_code_flag and has_diffs) {
        std.process.exit(1);
    }
}


pub fn diffNoIndexFiles(allocator: std.mem.Allocator, path_a: []const u8, path_b: []const u8, quiet: bool, platform_impl: *const platform_mod.Platform) !bool {
    const content_a = platform_impl.fs.readFile(allocator, path_a) catch "";
    defer if (content_a.len > 0) allocator.free(content_a);
    const content_b = platform_impl.fs.readFile(allocator, path_b) catch "";
    defer if (content_b.len > 0) allocator.free(content_b);

    if (std.mem.eql(u8, content_a, content_b)) return false;
    if (quiet) return true;

    // helpers.Generate unified diff
    const diff_output = diff_mod.generateUnifiedDiff(content_a, content_b, path_b, allocator) catch return true;
    defer allocator.free(diff_output);

    // helpers.Build proper header
    var out = std.ArrayList(u8).init(allocator);
    defer out.deinit();
    try out.appendSlice("diff --git a/");
    try out.appendSlice(path_a);
    try out.appendSlice(" b/");
    try out.appendSlice(path_b);
    try out.appendSlice("\n--- a/");
    try out.appendSlice(path_a);
    try out.appendSlice("\n+++ b/");
    try out.appendSlice(path_b);
    try out.appendSlice("\n");

    // helpers.Extract hunks from diff output
    if (std.mem.indexOf(u8, diff_output, "\n@@")) |hs| {
        try out.appendSlice(diff_output[hs + 1 ..]);
    } else if (std.mem.startsWith(u8, diff_output, "@@")) {
        try out.appendSlice(diff_output);
    }

    try platform_impl.writeStdout(out.items);
    return true;
}


pub fn diffNoIndexDirs(allocator: std.mem.Allocator, dir_a: []const u8, dir_b: []const u8, quiet: bool, platform_impl: *const platform_mod.Platform) !bool {
    // List files in both directories
    var files_a = std.StringHashMap(void).init(allocator);
    defer {
        var kit = files_a.keyIterator();
        while (kit.next()) |k| allocator.free(k.*);
        files_a.deinit();
    }
    var files_b = std.StringHashMap(void).init(allocator);
    defer {
        var kit = files_b.keyIterator();
        while (kit.next()) |k| allocator.free(k.*);
        files_b.deinit();
    }

    if (std.fs.cwd().openDir(dir_a, .{ .iterate = true })) |d| {
        var dir = d;
        defer dir.close();
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file) {
                try files_a.put(try allocator.dupe(u8, entry.name), {});
            }
        }
    } else |_| {}

    if (std.fs.cwd().openDir(dir_b, .{ .iterate = true })) |d| {
        var dir = d;
        defer dir.close();
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file) {
                try files_b.put(try allocator.dupe(u8, entry.name), {});
            }
        }
    } else |_| {}

    var has_diff = false;

    // helpers.Check files in A
    var it_a = files_a.keyIterator();
    while (it_a.next()) |key| {
        const name = key.*;
        const full_a = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_a, name });
        defer allocator.free(full_a);
        const full_b = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_b, name });
        defer allocator.free(full_b);
        if (files_b.contains(name)) {
            // helpers.Both have the file, diff them
            if (try diffNoIndexFiles(allocator, full_a, full_b, quiet, platform_impl)) {
                has_diff = true;
            }
        } else {
            // helpers.Only in A - deleted from B perspective
            has_diff = true;
            if (!quiet) {
                const content_a = platform_impl.fs.readFile(allocator, full_a) catch "";
                defer if (content_a.len > 0) allocator.free(content_a);
                if (try diffNoIndexFiles(allocator, full_a, "/dev/null", quiet, platform_impl)) {}
            }
        }
    }

    // helpers.Check files only in B
    var it_b = files_b.keyIterator();
    while (it_b.next()) |key| {
        const name = key.*;
        if (!files_a.contains(name)) {
            has_diff = true;
            if (!quiet) {
                const full_b = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_b, name });
                defer allocator.free(full_b);
                if (try diffNoIndexFiles(allocator, "/dev/null", full_b, quiet, platform_impl)) {}
            }
        }
    }

    return has_diff;
}
