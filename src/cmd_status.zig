// Auto-generated from main_common.zig - cmd_status
// Agents: this file is yours to edit for the commands it contains.

const std = @import("std");
const platform_mod = @import("platform/platform.zig");
const helpers = @import("git_helpers.zig");
const cmd_gc = @import("cmd_gc.zig");

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

pub fn cmdStatus(passed_allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform, _: [][]const u8) !void {
    if (@import("builtin").target.os.tag == .freestanding) {
        try platform_impl.writeStderr("status: not supported in freestanding mode\n");
        return;
    }
    const allocator = if (comptime @import("builtin").target.os.tag != .freestanding and @import("builtin").target.os.tag != .wasi)
        std.heap.c_allocator
    else
        passed_allocator;

    // helpers.Check for flags
    var porcelain = false;
    var porcelain_v2 = false; // true when --porcelain=v2 was used
    var porcelain_explicit = false; // true when --porcelain was used (paths always repo-relative)
    var nul_terminate = false;
    var show_branch = false;
    var short_format = false;
    var show_untracked = true; // default: show untracked files
    var untracked_explicit = false;
    var untracked_all = false; // false = normal (collapse dirs), true = all (show individual files)
    var status_args = std.array_list.Managed([]const u8).init(allocator);
    defer status_args.deinit();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--porcelain") or std.mem.eql(u8, arg, "--porcelain=v1")) {
            porcelain = true;
            porcelain_explicit = true;
        } else if (std.mem.startsWith(u8, arg, "--porcelain=")) {
            const version = arg["--porcelain=".len..];
            if (std.mem.eql(u8, version, "v1") or std.mem.eql(u8, version, "1")) {
                porcelain = true;
                porcelain_explicit = true;
            } else if (std.mem.eql(u8, version, "v2") or std.mem.eql(u8, version, "2")) {
                porcelain = true;
                porcelain_v2 = true;
                porcelain_explicit = true;
            } else {
                const msg = try std.fmt.allocPrint(allocator, "fatal: unsupported porcelain version '{s}'\n", .{version});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(128);
            }
        } else if (std.mem.eql(u8, arg, "--branch") or std.mem.eql(u8, arg, "-b")) {
            show_branch = true;
        } else if (std.mem.eql(u8, arg, "--no-branch")) {
            show_branch = false;
        } else if (std.mem.eql(u8, arg, "--short") or std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "-sb") or std.mem.eql(u8, arg, "-bs")) {
            short_format = true;
            porcelain = true; // short format uses same output as porcelain
            if (std.mem.eql(u8, arg, "-sb") or std.mem.eql(u8, arg, "-bs")) {
                show_branch = true;
            }
        } else if (std.mem.eql(u8, arg, "--no-short")) {
            short_format = false;
            porcelain = false;
        } else if (std.mem.eql(u8, arg, "-uno") or std.mem.eql(u8, arg, "-ufalse") or std.mem.eql(u8, arg, "--untracked-files=no") or std.mem.eql(u8, arg, "--untracked-files=false") or std.mem.eql(u8, arg, "--no-untracked-files")) {
            show_untracked = false;
            untracked_explicit = true;
        } else if (std.mem.eql(u8, arg, "-uall") or std.mem.eql(u8, arg, "--untracked-files=all")) {
            show_untracked = true;
            untracked_all = true;
            untracked_explicit = true;
        } else if (std.mem.eql(u8, arg, "-unormal") or std.mem.eql(u8, arg, "-utrue") or std.mem.eql(u8, arg, "--untracked-files=normal") or std.mem.eql(u8, arg, "--untracked-files=true") or std.mem.eql(u8, arg, "--untracked-files") or std.mem.eql(u8, arg, "-u")) {
            show_untracked = true;
            untracked_explicit = true;
            untracked_all = false;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try platform_impl.writeStdout("usage: git status [<options>] [--] [<pathspec>...]\n\n");
            try platform_impl.writeStdout("    -s, --short           show status concisely\n");
            try platform_impl.writeStdout("    -b, --branch          show branch information\n");
            try platform_impl.writeStdout("    --porcelain[=<version>]\n                          machine-readable output\n");
            std.process.exit(129);
        } else if (std.mem.eql(u8, arg, "--")) {
            // helpers.End of flags
            while (args.next()) |path_arg| {
                try status_args.append(path_arg);
            }
            break;
        } else if (std.mem.eql(u8, arg, "-z")) {
            nul_terminate = true;
            porcelain = true;
        } else if (std.mem.eql(u8, arg, "--column") or std.mem.startsWith(u8, arg, "--column=")) {
            // Column display - accept as no-op
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            // Verbose mode - accept as no-op (shows diff in commit template)
        } else if (std.mem.eql(u8, arg, "--ignored")) {
            // helpers.Show ignored files - accept as no-op for now
        } else if (std.mem.eql(u8, arg, "--renames") or std.mem.eql(u8, arg, "--no-renames") or
            std.mem.eql(u8, arg, "--find-renames"))
        {
            // Rename detection - accept as no-op
        } else if (std.mem.eql(u8, arg, "--ahead-behind") or std.mem.eql(u8, arg, "--no-ahead-behind")) {
            // Ahead/behind display - accept as no-op
        } else if (std.mem.eql(u8, arg, "--show-stash")) {
            // Show stash info - accept as no-op for now
        } else if (std.mem.eql(u8, arg, "--no-show-stash")) {
            // Don't show stash info - accept as no-op
        } else if (std.mem.eql(u8, arg, "--no-optional-locks")) {
            // Don't update index with stat info - accept as no-op
        } else if (std.mem.startsWith(u8, arg, "--ignore-submodules")) {
            // Ignore submodule changes - accept for now
        } else if (arg.len > 0 and arg[0] != '-') {
            try status_args.append(arg);
        }
        // Silently ignore other unrecognized flags
    }
    
    // helpers.Find .git directory by traversing up
    const git_path = helpers.findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);

    // helpers.Get current working directory (repository root)
    const repo_root = std.fs.path.dirname(git_path) orelse {
        try platform_impl.writeStderr("fatal: unable to determine repository root\n");
        std.process.exit(128);
    };

    // Compute the prefix (subdirectory path relative to repo root)
    // This is used to show paths relative to cwd in long-format output
    const cwd = try platform_impl.fs.getCwd(allocator);
    defer allocator.free(cwd);
    
    // Check status.relativePaths config (default: true)
    var relative_paths = true;
    {
        if (helpers.getConfigOverride("status.relativePaths")) |val| {
            if (std.mem.eql(u8, val, "false") or std.mem.eql(u8, val, "no") or std.mem.eql(u8, val, "0")) {
                relative_paths = false;
            }
        } else {
            const config_path_rp = try std.fmt.allocPrint(allocator, "{s}/config", .{git_path});
            defer allocator.free(config_path_rp);
            if (platform_impl.fs.readFile(allocator, config_path_rp)) |cfg| {
                defer allocator.free(cfg);
                if (helpers.parseConfigValue(cfg, "status.relativepaths", allocator) catch null) |val| {
                    defer allocator.free(val);
                    if (std.mem.eql(u8, val, "false") or std.mem.eql(u8, val, "no") or std.mem.eql(u8, val, "0")) {
                        relative_paths = false;
                    }
                }
            } else |_| {}
        }
    }
    
    const prefix: []const u8 = if (relative_paths and cwd.len > repo_root.len and std.mem.startsWith(u8, cwd, repo_root) and cwd[repo_root.len] == '/')
        cwd[repo_root.len + 1 ..]
    else
        "";

    // Check status.short and status.branch config (only if not overridden by command line)
    {
        const config_path_sb = try std.fmt.allocPrint(allocator, "{s}/config", .{git_path});
        defer allocator.free(config_path_sb);
        if (platform_impl.fs.readFile(allocator, config_path_sb)) |cfg| {
            defer allocator.free(cfg);
            if (!short_format and !porcelain) {
                // Check status.short config
                const short_val = if (helpers.getConfigOverride("status.short")) |v| v else
                    (helpers.parseConfigValue(cfg, "status.short", allocator) catch null) orelse null;
                if (short_val) |val| {
                    if (std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "yes") or std.mem.eql(u8, val, "1")) {
                        short_format = true;
                        porcelain = true;
                    }
                    if (!std.mem.eql(u8, val, "true") and !std.mem.eql(u8, val, "yes") and !std.mem.eql(u8, val, "1"))
                    {} else {}
                }
            }
            if (!show_branch) {
                // Check status.branch config
                const branch_val = if (helpers.getConfigOverride("status.branch")) |v| v else
                    (helpers.parseConfigValue(cfg, "status.branch", allocator) catch null) orelse null;
                if (branch_val) |val| {
                    if (std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "yes") or std.mem.eql(u8, val, "1")) {
                        show_branch = true;
                    }
                }
            }
        } else |_| {}
    }

    // helpers.Check config for status.showUntrackedFiles (if not overridden by command line)
    if (!untracked_explicit) {
        const config_path_for_ut = try std.fmt.allocPrint(allocator, "{s}/config", .{git_path});
        defer allocator.free(config_path_for_ut);
        if (platform_impl.fs.readFile(allocator, config_path_for_ut)) |cfg| {
            defer allocator.free(cfg);
            if (helpers.parseConfigValue(cfg, "status.showuntrackedfiles", allocator) catch null) |val| {
                defer allocator.free(val);
                if (std.mem.eql(u8, val, "no") or std.mem.eql(u8, val, "false") or std.mem.eql(u8, val, "0")) {
                    show_untracked = false;
                } else if (std.mem.eql(u8, val, "all")) {
                    untracked_all = true;
                } else if (std.mem.eql(u8, val, "normal")) {
                    untracked_all = false;
                }
            }
        } else |_| {}
    }

    // Check status.displayCommentPrefix config
    var comment_prefix: []const u8 = "";
    {
        if (helpers.getConfigOverride("status.displayCommentPrefix")) |val| {
            if (std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "yes") or std.mem.eql(u8, val, "1")) {
                comment_prefix = "# ";
            }
        } else {
            const config_path_cp = try std.fmt.allocPrint(allocator, "{s}/config", .{git_path});
            defer allocator.free(config_path_cp);
            if (platform_impl.fs.readFile(allocator, config_path_cp)) |cfg| {
                defer allocator.free(cfg);
                if (helpers.parseConfigValue(cfg, "status.displaycommentprefix", allocator) catch null) |val| {
                    defer allocator.free(val);
                    if (std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "yes") or std.mem.eql(u8, val, "1")) {
                        comment_prefix = "# ";
                    }
                }
            } else |_| {}
        }
    }

    // Check advice.statusHints config
    var show_hints = true;
    {
        const config_path_hints = try std.fmt.allocPrint(allocator, "{s}/config", .{git_path});
        defer allocator.free(config_path_hints);
        if (platform_impl.fs.readFile(allocator, config_path_hints)) |cfg| {
            defer allocator.free(cfg);
            if (helpers.parseConfigValue(cfg, "advice.statushints", allocator) catch null) |val| {
                defer allocator.free(val);
                if (std.mem.eql(u8, val, "false") or std.mem.eql(u8, val, "no") or std.mem.eql(u8, val, "0")) {
                    show_hints = false;
                }
            }
        } else |_| {}
    }

    // helpers.Get current branch
    const current_branch = refs.getCurrentBranch(git_path, platform_impl, allocator) catch try allocator.dupe(u8, "master");
    defer allocator.free(current_branch);

    // helpers.Check if there are any commits
    const current_commit = refs.getCurrentCommit(git_path, platform_impl, allocator) catch null;
    defer if (current_commit) |hash| allocator.free(hash);
    
    if (!porcelain) {
        const branch_msg = try std.fmt.allocPrint(allocator, "On branch {s}\n", .{current_branch});
        defer allocator.free(branch_msg);
        try writePrefixed(platform_impl, branch_msg, comment_prefix);

        // Display upstream tracking info natively
        if (current_commit != null) upstream_display: {
            const config_path_track = try std.fmt.allocPrint(allocator, "{s}/config", .{git_path});
            defer allocator.free(config_path_track);
            const cfg = platform_impl.fs.readFile(allocator, config_path_track) catch break :upstream_display;
            defer allocator.free(cfg);
            const track_key = try std.fmt.allocPrint(allocator, "branch.{s}.remote", .{current_branch});
            defer allocator.free(track_key);
            const remote_val = (helpers.parseConfigValue(cfg, track_key, allocator) catch null) orelse break :upstream_display;
            defer allocator.free(remote_val);

            const merge_key = try std.fmt.allocPrint(allocator, "branch.{s}.merge", .{current_branch});
            defer allocator.free(merge_key);
            const merge_val = (helpers.parseConfigValue(cfg, merge_key, allocator) catch null) orelse break :upstream_display;
            defer allocator.free(merge_val);

            // helpers.Convert refs/heads/foo to remote/origin/foo
            const short_merge = if (std.mem.startsWith(u8, merge_val, "refs/heads/"))
                merge_val["refs/heads/".len..]
            else
                merge_val;

            const is_local = std.mem.eql(u8, remote_val, ".");
            const upstream_ref = if (is_local)
                try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{short_merge})
            else
                try std.fmt.allocPrint(allocator, "refs/remotes/{s}/{s}", .{ remote_val, short_merge });
            defer allocator.free(upstream_ref);
            const upstream_display_name = if (is_local)
                try allocator.dupe(u8, short_merge)
            else
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ remote_val, short_merge });
            defer allocator.free(upstream_display_name);

            // helpers.Resolve upstream ref to commit hash
            const upstream_hash_opt = refs.resolveRef(git_path, upstream_ref, platform_impl, allocator) catch break :upstream_display;
            const upstream_hash = upstream_hash_opt orelse break :upstream_display;
            defer allocator.free(upstream_hash);

            // helpers.Compare commits: count ahead/behind
            if (std.mem.eql(u8, current_commit.?, upstream_hash)) {
                const up_msg = try std.fmt.allocPrint(allocator, "Your branch is up to date with '{s}'.\n", .{upstream_display_name});
                defer allocator.free(up_msg);
                try writePrefixed(platform_impl, up_msg, comment_prefix);
            } else {
                const ahead_count = helpers.countUnreachable(git_path, current_commit.?, upstream_hash, allocator, platform_impl);
                const behind_count = helpers.countUnreachable(git_path, upstream_hash, current_commit.?, allocator, platform_impl);
                if (ahead_count > 0 and behind_count > 0) {
                    const up_msg = try std.fmt.allocPrint(allocator, "Your branch and '{s}' have diverged,\nand have {d} and {d} different commits each, respectively.\n", .{upstream_display_name, ahead_count, behind_count});
                    defer allocator.free(up_msg);
                    try writePrefixed(platform_impl, up_msg, comment_prefix);
                    if (show_hints) try writePrefixed(platform_impl, "  (use \"git pull\" if you want to integrate the remote branch with yours)\n", comment_prefix);
                } else if (ahead_count > 0) {
                    const up_msg = try std.fmt.allocPrint(allocator, "Your branch is ahead of '{s}' by {d} commit{s}.\n", .{upstream_display_name, ahead_count, if (ahead_count > 1) "s" else ""});
                    defer allocator.free(up_msg);
                    try writePrefixed(platform_impl, up_msg, comment_prefix);
                    if (show_hints) try writePrefixed(platform_impl, "  (use \"git push\" to publish your local commits)\n", comment_prefix);
                } else if (behind_count > 0) {
                    const up_msg = try std.fmt.allocPrint(allocator, "Your branch is behind '{s}' by {d} commit{s}, and can be fast-forwarded.\n", .{upstream_display_name, behind_count, if (behind_count > 1) "s" else ""});
                    defer allocator.free(up_msg);
                    try writePrefixed(platform_impl, up_msg, comment_prefix);
                    if (show_hints) try writePrefixed(platform_impl, "  (use \"git pull\" to update your local branch)\n", comment_prefix);
                }
            }
        }
        
        if (current_commit == null) {
            try writePrefixed(platform_impl, "\nNo commits yet\n", comment_prefix);
        }
    } else if (porcelain and (show_branch or porcelain_v2)) {
        // helpers.Check if helpers.HEAD is detached
        const head_content_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_path});
        defer allocator.free(head_content_path);
        const head_raw = platform_impl.fs.readFile(allocator, head_content_path) catch null;
        defer if (head_raw) |h| allocator.free(h);

        const is_detached = if (head_raw) |h| !std.mem.startsWith(u8, h, "ref: ") else true;
        const branch_line_end: []const u8 = if (nul_terminate) "\x00" else "\n";

        // Read upstream tracking config: remote name and merge ref
        var upstream_remote: ?[]const u8 = null;
        var upstream_merge: ?[]const u8 = null;
        read_upstream: {
            const config_path_up = try std.fmt.allocPrint(allocator, "{s}/config", .{git_path});
            defer allocator.free(config_path_up);
            const cfg_up = platform_impl.fs.readFile(allocator, config_path_up) catch break :read_upstream;
            defer allocator.free(cfg_up);
            const rk = try std.fmt.allocPrint(allocator, "branch.{s}.remote", .{current_branch});
            defer allocator.free(rk);
            upstream_remote = (helpers.parseConfigValue(cfg_up, rk, allocator) catch null);
            const mk = try std.fmt.allocPrint(allocator, "branch.{s}.merge", .{current_branch});
            defer allocator.free(mk);
            upstream_merge = (helpers.parseConfigValue(cfg_up, mk, allocator) catch null);
        }
        defer if (upstream_remote) |v| allocator.free(v);
        defer if (upstream_merge) |v| allocator.free(v);

        // Build upstream display name: "remote/branch"
        const upstream_short_merge = if (upstream_merge) |m|
            (if (std.mem.startsWith(u8, m, "refs/heads/")) m["refs/heads/".len..] else m)
        else
            null;
        const upstream_display = if (upstream_remote != null and upstream_short_merge != null)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ upstream_remote.?, upstream_short_merge.? })
        else
            null;
        defer if (upstream_display) |v| allocator.free(v);

        // Compute ahead/behind
        var ahead_count: u32 = 0;
        var behind_count: u32 = 0;
        if (upstream_display != null and current_commit != null) ab_calc: {
            const is_local_remote = std.mem.eql(u8, upstream_remote.?, ".");
            const upstream_ref = if (is_local_remote)
                try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{upstream_short_merge.?})
            else
                try std.fmt.allocPrint(allocator, "refs/remotes/{s}/{s}", .{ upstream_remote.?, upstream_short_merge.? });
            defer allocator.free(upstream_ref);
            const upstream_hash_opt = refs.resolveRef(git_path, upstream_ref, platform_impl, allocator) catch break :ab_calc;
            const upstream_hash = upstream_hash_opt orelse break :ab_calc;
            defer allocator.free(upstream_hash);
            if (!std.mem.eql(u8, current_commit.?, upstream_hash)) {
                ahead_count = helpers.countUnreachable(git_path, current_commit.?, upstream_hash, allocator, platform_impl);
                behind_count = helpers.countUnreachable(git_path, upstream_hash, current_commit.?, allocator, platform_impl);
            }
        }

        if (porcelain_v2) {
            // v2 branch headers
            if (show_branch) {
                const oid_str = current_commit orelse "(initial)";
                const oid_line = try std.fmt.allocPrint(allocator, "# branch.oid {s}", .{oid_str});
                defer allocator.free(oid_line);
                try platform_impl.writeStdout(oid_line);
                try platform_impl.writeStdout(branch_line_end);

                if (is_detached) {
                    try platform_impl.writeStdout("# branch.head (detached)");
                } else {
                    const head_line = try std.fmt.allocPrint(allocator, "# branch.head {s}", .{current_branch});
                    defer allocator.free(head_line);
                    try platform_impl.writeStdout(head_line);
                }
                try platform_impl.writeStdout(branch_line_end);

                if (upstream_display) |ud| {
                    const up_line = try std.fmt.allocPrint(allocator, "# branch.upstream {s}", .{ud});
                    defer allocator.free(up_line);
                    try platform_impl.writeStdout(up_line);
                    try platform_impl.writeStdout(branch_line_end);

                    const ab_line = try std.fmt.allocPrint(allocator, "# branch.ab +{d} -{d}", .{ ahead_count, behind_count });
                    defer allocator.free(ab_line);
                    try platform_impl.writeStdout(ab_line);
                    try platform_impl.writeStdout(branch_line_end);
                }
            }
        } else {
            // v1 / short branch header: ## branch...upstream [ahead N, behind M]
            if (is_detached) {
                try platform_impl.writeStdout("## HEAD (no branch)");
                try platform_impl.writeStdout(branch_line_end);
            } else if (upstream_display) |ud| {
                var ab_suffix: []const u8 = "";
                var ab_suffix_alloc: ?[]u8 = null;
                defer if (ab_suffix_alloc) |a| allocator.free(a);
                if (ahead_count > 0 and behind_count > 0) {
                    ab_suffix_alloc = try std.fmt.allocPrint(allocator, " [ahead {d}, behind {d}]", .{ ahead_count, behind_count });
                    ab_suffix = ab_suffix_alloc.?;
                } else if (ahead_count > 0) {
                    ab_suffix_alloc = try std.fmt.allocPrint(allocator, " [ahead {d}]", .{ahead_count});
                    ab_suffix = ab_suffix_alloc.?;
                } else if (behind_count > 0) {
                    ab_suffix_alloc = try std.fmt.allocPrint(allocator, " [behind {d}]", .{behind_count});
                    ab_suffix = ab_suffix_alloc.?;
                }
                const branch_header = try std.fmt.allocPrint(allocator, "## {s}...{s}{s}", .{ current_branch, ud, ab_suffix });
                defer allocator.free(branch_header);
                try platform_impl.writeStdout(branch_header);
                try platform_impl.writeStdout(branch_line_end);
            } else {
                const branch_header = try std.fmt.allocPrint(allocator, "## {s}", .{current_branch});
                defer allocator.free(branch_header);
                try platform_impl.writeStdout(branch_header);
                try platform_impl.writeStdout(branch_line_end);
            }
        }
    }

    // helpers.Load index to check for staged files
    var index = index_mod.Index.load(git_path, platform_impl, allocator) catch |err| switch (err) {
        error.FileNotFound => index_mod.Index.init(allocator),
        else => return err,
    };
    defer index.deinit();

    // helpers.Load gitignore
    const gitignore_path = try std.fmt.allocPrint(allocator, "{s}/.gitignore", .{repo_root});
    defer allocator.free(gitignore_path);
    
    var gitignore = gitignore_mod.GitIgnore.loadFromFile(allocator, gitignore_path, platform_impl) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => gitignore_mod.GitIgnore.init(allocator),
    };
    defer gitignore.deinit();

    // Pre-compute helpers.HEAD tree hash and build flat index for O(1) blob lookups
    var cached_head_tree: ?[]u8 = null;
    if (current_commit) |cc| {
        const commit_obj = objects.GitObject.load(cc, git_path, platform_impl, allocator) catch null;
        if (commit_obj) |co| {
            defer co.deinit(allocator);
            var clines = std.mem.splitSequence(u8, co.data, "\n");
            if (clines.next()) |tl| {
                if (std.mem.startsWith(u8, tl, "tree ")) {
                    cached_head_tree = allocator.dupe(u8, tl["tree ".len..]) catch null;
                }
            }
        }
    }
    defer if (cached_head_tree) |h| allocator.free(h);

    // helpers.Build flat map: path -> sha1 from helpers.HEAD tree (for fast staged detection)
    var head_tree_map = std.StringHashMap([20]u8).init(allocator);
    defer {
        var kit = head_tree_map.keyIterator();
        while (kit.next()) |key| allocator.free(@constCast(key.*));
        head_tree_map.deinit();
    }
    if (cached_head_tree) |ht| {
        helpers.buildTreeMap(ht, "", git_path, platform_impl, allocator, &head_tree_map) catch {};
    }

    // helpers.Detect staged files vs modified files vs deleted files vs clean files
    var staged_files = std.array_list.Managed(index_mod.IndexEntry).init(allocator);
    var modified_files = std.array_list.Managed(index_mod.IndexEntry).init(allocator);
    var deleted_files = std.array_list.Managed(index_mod.IndexEntry).init(allocator);
    defer staged_files.deinit();
    defer modified_files.deinit();
    defer deleted_files.deinit();

    for (index.entries.items) |entry| {
        // helpers.Check if working directory version is different from index version
        const full_path = if (std.fs.path.isAbsolute(entry.path))
            try allocator.dupe(u8, entry.path)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, entry.path });
        defer allocator.free(full_path);
        
        // helpers.Check if file exists in working directory
        // Also check that no parent directory component is a symlink
        // (e.g. if 'copy' was a dir but is now a symlink, 'copy/file' is deleted)
        const file_exists = file_exists_blk: {
            if (!((platform_impl.fs.exists(full_path)) catch false)) break :file_exists_blk false;
            // Check each parent component for symlinks
            var path_to_check: []const u8 = entry.path;
            while (std.fs.path.dirname(path_to_check)) |parent| {
                if (parent.len == 0) break;
                const parent_full = std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, parent }) catch break;
                defer allocator.free(parent_full);
                const lstat_result = std.posix.fstatat(std.posix.AT.FDCWD, parent_full, std.posix.AT.SYMLINK_NOFOLLOW) catch break;
                if ((lstat_result.mode & std.posix.S.IFMT) == std.posix.S.IFLNK) break :file_exists_blk false;
                path_to_check = parent;
            }
            break :file_exists_blk true;
        };
        
        if (!file_exists) {
            // File is in index but not in working directory - it's deleted
            try deleted_files.append(entry);
        } else {
            const working_modified = blk: {
                // OPTIMIZATION: Fast path using mtime/size before computing SHA-1
                const file_stat = std.fs.cwd().statFile(full_path) catch break :blk false;
                
                // helpers.Compare mtime and size with index entry
                const work_mtime_sec = @as(u32, @intCast(@divTrunc(file_stat.mtime, 1_000_000_000)));
                const work_size = @as(u32, @intCast(file_stat.size));
                
                // Fast path: if mtime and size match index, file is likely unchanged
                if (work_mtime_sec == entry.mtime_sec and work_size == entry.size) {
                    break :blk false; // File appears unchanged - skip expensive SHA-1 computation
                }
                
                // Slow path: mtime or size differs, need to compute SHA-1 to confirm
                const current_content = platform_impl.fs.readFile(allocator, full_path) catch break :blk false;
                defer allocator.free(current_content);
                
                // helpers.Create blob object to get hash
                const blob = objects.createBlobObject(current_content, allocator) catch break :blk false;
                defer blob.deinit(allocator);
                
                const current_hash = blob.hash(allocator) catch break :blk false;
                defer allocator.free(current_hash);
                
                // helpers.Compare with index hash
                const index_hash = std.fmt.allocPrint(allocator, "{x}", .{&entry.sha1}) catch break :blk false;
                defer allocator.free(index_hash);
                
                break :blk !std.mem.eql(u8, current_hash, index_hash);
            };
            
            if (working_modified) {
                try modified_files.append(entry);
            } else if (current_commit == null) {
                // helpers.No commits yet, so anything in index is staged
                try staged_files.append(entry);
            } else {
                // File is in index and matches working directory.
                // helpers.Check if it's different from helpers.HEAD tree using cached map (O(1))
                const is_different_from_head = blk: {
                    if (head_tree_map.get(entry.path)) |tree_sha1| {
                        break :blk !std.mem.eql(u8, &tree_sha1, &entry.sha1);
                    }
                    // File not in helpers.HEAD tree - it's new (staged)
                    break :blk current_commit != null;
                };
                
                if (is_different_from_head) {
                    try staged_files.append(entry);
                }
                // helpers.If same as helpers.HEAD, file is clean (don't show it)
            }
        }
    }

    // helpers.Determine helpers.HEAD tree hash for new-file detection
    var head_tree_hash: ?[]u8 = null;
    if (current_commit) |cc| {
        const cobj = objects.GitObject.load(cc, git_path, platform_impl, allocator) catch null;
        if (cobj) |co| {
            defer co.deinit(allocator);
            if (co.type == .commit) {
                var clines = std.mem.splitSequence(u8, co.data, "\n");
                if (clines.next()) |tl| {
                    if (std.mem.startsWith(u8, tl, "tree ")) {
                        head_tree_hash = allocator.dupe(u8, tl["tree ".len..]) catch null;
                    }
                }
            }
        }
    }
    defer if (head_tree_hash) |h| allocator.free(h);

    // helpers.For porcelain output, collect all lines then sort and output together
    var porcelain_lines = std.array_list.Managed([]u8).init(allocator);
    defer {
        for (porcelain_lines.items) |line| allocator.free(line);
        porcelain_lines.deinit();
    }

    // helpers.Show staged files
    if (staged_files.items.len > 0) {
        if (porcelain) {
            for (staged_files.items) |entry| {
                const is_new = if (current_commit == null)
                    true
                else if (head_tree_hash) |hth|
                    (helpers.lookupBlobInTree(hth, entry.path, git_path, platform_impl, allocator) catch null) == null
                else
                    false;
                
                if (porcelain_v2) {
                    const xy: []const u8 = if (is_new) "A." else "M.";
                    const h_hash = if (is_new) "0000000000000000000000000000000000000000" else blk: {
                        if (head_tree_map.get(entry.path)) |sha1| {
                            const hh = try std.fmt.allocPrint(allocator, "{x}", .{&sha1});
                            break :blk hh;
                        }
                        break :blk try allocator.dupe(u8, "0000000000000000000000000000000000000000");
                    };
                    defer if (!is_new) allocator.free(@constCast(h_hash));
                    const i_hash = try std.fmt.allocPrint(allocator, "{x}", .{&entry.sha1});
                    defer allocator.free(i_hash);
                    const m_h: u32 = if (is_new) 0o000000 else 0o100644;
                    const qp = try quotePath(allocator, entry.path);
                    defer allocator.free(qp);
                    try porcelain_lines.append(try std.fmt.allocPrint(allocator, "1 {s} N... {o:0>6} {o:0>6} {o:0>6} {s} {s} {s}", .{ xy, m_h, @as(u32, 0o100644), @as(u32, 0o100644), h_hash, i_hash, qp }));
                } else {
                    const qp = try quotePath(allocator, entry.path);
                    defer allocator.free(qp);
                    if (is_new) {
                        try porcelain_lines.append(try std.fmt.allocPrint(allocator, "A  {s}", .{qp}));
                    } else {
                        try porcelain_lines.append(try std.fmt.allocPrint(allocator, "M  {s}", .{qp}));
                    }
                }
            }
        } else {
            try writePrefixed(platform_impl, "\nChanges to be committed:\n", comment_prefix);
            if (current_commit == null) {
                if (show_hints) try writePrefixed(platform_impl, "  (use \"git rm --cached <file>...\" to unstage)\n", comment_prefix);
            } else {
                if (show_hints) try writePrefixed(platform_impl, "  (use \"git restore --staged <file>...\" to unstage)\n", comment_prefix);
            }
            
            for (staged_files.items) |entry| {
                const is_new = if (current_commit == null)
                    true
                else if (head_tree_hash) |hth|
                    (helpers.lookupBlobInTree(hth, entry.path, git_path, platform_impl, allocator) catch null) == null
                else
                    false;
                    
                if (is_new) {
                    const rel_path = try makeRelativePath(allocator, entry.path, prefix);
                    defer allocator.free(rel_path);
                    const msg = try std.fmt.allocPrint(allocator, "\tnew file:   {s}\n", .{rel_path});
                    defer allocator.free(msg);
                    try writePrefixed(platform_impl, msg, comment_prefix);
                } else {
                    const rel_path = try makeRelativePath(allocator, entry.path, prefix);
                    defer allocator.free(rel_path);
                    const msg = try std.fmt.allocPrint(allocator, "\tmodified:   {s}\n", .{rel_path});
                    defer allocator.free(msg);
                    try writePrefixed(platform_impl, msg, comment_prefix);
                }
            }
        }
    }

    // helpers.Show modified but unstaged files
    if (modified_files.items.len > 0) {
        if (porcelain) {
            for (modified_files.items) |entry| {
                const qp = try quotePath(allocator, entry.path);
                defer allocator.free(qp);
                if (porcelain_v2) {
                    const i_hash = try std.fmt.allocPrint(allocator, "{x}", .{&entry.sha1});
                    defer allocator.free(i_hash);
                    try porcelain_lines.append(try std.fmt.allocPrint(allocator, "1 .M N... {o:0>6} {o:0>6} {o:0>6} {s} {s} {s}", .{ @as(u32, 0o100644), @as(u32, 0o100644), @as(u32, 0o100644), i_hash, i_hash, qp }));
                } else {
                    try porcelain_lines.append(try std.fmt.allocPrint(allocator, " M {s}", .{qp}));
                }
            }
        } else {
            try writePrefixed(platform_impl, "\nChanges not staged for commit:\n", comment_prefix);
            if (show_hints) try writePrefixed(platform_impl, "  (use \"git add <file>...\" to update what will be committed)\n", comment_prefix);
            if (show_hints) try writePrefixed(platform_impl, "  (use \"git restore <file>...\" to discard changes in working directory)\n", comment_prefix);
            
            for (modified_files.items) |entry| {
                const rel_path = try makeRelativePath(allocator, entry.path, prefix);
                defer allocator.free(rel_path);
                const msg = try std.fmt.allocPrint(allocator, "\tmodified:   {s}\n", .{rel_path});
                defer allocator.free(msg);
                try writePrefixed(platform_impl, msg, comment_prefix);
            }
        }
    }

    // helpers.Show deleted files
    if (deleted_files.items.len > 0) {
        if (porcelain) {
            for (deleted_files.items) |entry| {
                const qp = try quotePath(allocator, entry.path);
                defer allocator.free(qp);
                if (porcelain_v2) {
                    const i_hash = try std.fmt.allocPrint(allocator, "{x}", .{&entry.sha1});
                    defer allocator.free(i_hash);
                    try porcelain_lines.append(try std.fmt.allocPrint(allocator, "1 .D N... {o:0>6} {o:0>6} {o:0>6} {s} {s} {s}", .{ @as(u32, 0o100644), @as(u32, 0o100644), @as(u32, 0), i_hash, i_hash, qp }));
                } else {
                    try porcelain_lines.append(try std.fmt.allocPrint(allocator, " D {s}", .{qp}));
                }
            }
        } else {
            if (modified_files.items.len == 0) {
                try writePrefixed(platform_impl, "\nChanges not staged for commit:\n", comment_prefix);
                if (show_hints) try writePrefixed(platform_impl, "  (use \"git add <file>...\" to update what will be committed)\n", comment_prefix);
                if (show_hints) try writePrefixed(platform_impl, "  (use \"git restore <file>...\" to discard changes in working directory)\n", comment_prefix);
            }
            
            for (deleted_files.items) |entry| {
                const rel_path = try makeRelativePath(allocator, entry.path, prefix);
                defer allocator.free(rel_path);
                const msg = try std.fmt.allocPrint(allocator, "\tdeleted:    {s}\n", .{rel_path});
                defer allocator.free(msg);
                try writePrefixed(platform_impl, msg, comment_prefix);
            }
        }
    }

    // helpers.Find untracked files
    var untracked_files = if (show_untracked)
        helpers.findUntrackedFiles(allocator, repo_root, &index, &gitignore, platform_impl) catch std.array_list.Managed([]u8).init(allocator)
    else
        std.array_list.Managed([]u8).init(allocator);

    // In normal mode (not -uall), collapse untracked directories
    if (!untracked_all and untracked_files.items.len > 0) {
        // Build a set of tracked directories (directories containing tracked files)
        var tracked_dirs = std.StringHashMap(void).init(allocator);
        defer tracked_dirs.deinit();
        {
            const idx = &index;
            for (idx.entries.items) |entry| {
                // Add all parent directories of tracked files
                var path = entry.path;
                while (std.mem.lastIndexOfScalar(u8, path, '/')) |sep| {
                    const dir = path[0..sep];
                    tracked_dirs.put(dir, {}) catch break;
                    path = dir;
                }
            }
        }

        var collapsed = std.array_list.Managed([]u8).init(allocator);
        var seen_dirs = std.StringHashMap(void).init(allocator);
        defer {
            var kit = seen_dirs.keyIterator();
            while (kit.next()) |key| allocator.free(@constCast(key.*));
            seen_dirs.deinit();
        }

        for (untracked_files.items) |file| {
            // Find the top-level directory component
            if (std.mem.indexOfScalar(u8, file, '/')) |sep| {
                const top_dir = file[0..sep];
                // If this top-level dir has no tracked files, collapse
                if (!tracked_dirs.contains(top_dir)) {
                    if (!seen_dirs.contains(top_dir)) {
                        const key_copy = allocator.dupe(u8, top_dir) catch continue;
                        seen_dirs.put(key_copy, {}) catch {
                            allocator.free(key_copy);
                            continue;
                        };
                        const dir_entry = std.fmt.allocPrint(allocator, "{s}/", .{top_dir}) catch continue;
                        collapsed.append(dir_entry) catch {
                            allocator.free(dir_entry);
                            continue;
                        };
                    }
                    allocator.free(file);
                    continue;
                }
            }
            collapsed.append(file) catch {
                allocator.free(file);
            };
        }
        untracked_files.deinit();
        untracked_files = collapsed;
    }

    // Sort untracked files alphabetically
    if (untracked_files.items.len > 1) {
        std.mem.sort([]u8, untracked_files.items, {}, struct {
            fn lessThan(_: void, a: []u8, b: []u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);
    }
    defer {
        for (untracked_files.items) |file| {
            allocator.free(file);
        }
        untracked_files.deinit();
    }

    if (untracked_files.items.len > 0) {
        if (porcelain) {
            for (untracked_files.items) |file| {
                const qp = try quotePath(allocator, file);
                defer allocator.free(qp);
                if (porcelain_v2) {
                    try porcelain_lines.append(try std.fmt.allocPrint(allocator, "? {s}", .{qp}));
                } else {
                    try porcelain_lines.append(try std.fmt.allocPrint(allocator, "?? {s}", .{qp}));
                }
            }
        } else {
            try writePrefixed(platform_impl, "\nUntracked files:\n", comment_prefix);
            if (show_hints) try writePrefixed(platform_impl, "  (use \"git add <file>...\" to include in what will be committed)\n", comment_prefix);
            
            for (untracked_files.items) |file| {
                const rel_path = try makeRelativePath(allocator, file, prefix);
                defer allocator.free(rel_path);
                const msg = try std.fmt.allocPrint(allocator, "\t{s}\n", .{rel_path});
                defer allocator.free(msg);
                try writePrefixed(platform_impl, msg, comment_prefix);
            }
            try writePrefixed(platform_impl, "\n", comment_prefix);
        }
    }

    // helpers.Output sorted porcelain lines
    if (porcelain and porcelain_lines.items.len > 0) {
        // Sort: tracked entries in path order first, then untracked in path order
        std.mem.sort([]u8, porcelain_lines.items, {}, struct {
            fn stripQuote(s: []const u8) []const u8 {
                if (s.len > 0 and s[0] == '"') return s[1..];
                return s;
            }
            fn isUntracked(s: []const u8) bool {
                return (s.len >= 2 and s[0] == '?' and (s[1] == '?' or s[1] == ' '));
            }
            fn extractPath(s: []const u8) []const u8 {
                // v2 changed: "1 XY sub mH mI mW hH hI path" - path is after 8th space
                if (s.len > 2 and s[0] == '1' and s[1] == ' ') {
                    var spaces: usize = 0;
                    for (s, 0..) |c, i| {
                        if (c == ' ') spaces += 1;
                        if (spaces == 8) return stripQuote(s[i + 1 ..]);
                    }
                }
                // v1: "XY path" or v2 untracked: "? path"
                if (s.len >= 2 and s[0] == '?' and s[1] == ' ') return stripQuote(s[2..]);
                return stripQuote(if (s.len > 3) s[3..] else s);
            }
            fn lessThan(_: void, a: []u8, b: []u8) bool {
                const a_untracked = isUntracked(a);
                const b_untracked = isUntracked(b);
                if (a_untracked != b_untracked) return !a_untracked; // tracked before untracked
                const a_path = extractPath(a);
                const b_path = extractPath(b);
                return std.mem.order(u8, a_path, b_path) == .lt;
            }
        }.lessThan);
        const line_end: []const u8 = if (nul_terminate) "\x00" else "\n";
        const use_rel = !porcelain_explicit and prefix.len > 0;
        for (porcelain_lines.items) |line| {
            if (use_rel and line.len > 3) {
                // Convert repo-relative path to cwd-relative for display
                const status_prefix = line[0..3];
                const repo_path = line[3..];
                const display_path = try makeRelativePath(allocator, repo_path, prefix);
                defer allocator.free(display_path);
                try platform_impl.writeStdout(status_prefix);
                try platform_impl.writeStdout(display_path);
            } else {
                try platform_impl.writeStdout(line);
            }
            try platform_impl.writeStdout(line_end);
        }
    }

    // Final summary message (only in non-porcelain mode)
    if (!porcelain) {
        if (staged_files.items.len == 0 and modified_files.items.len == 0 and deleted_files.items.len == 0 and untracked_files.items.len == 0) {
            if (current_commit == null) {
                try writePrefixed(platform_impl, "\nnothing to commit (create/copy files and use \"git add\" to track)\n", comment_prefix);
            } else {
                try writePrefixed(platform_impl, "\nnothing to commit, working tree clean\n", comment_prefix);
            }
        } else if (staged_files.items.len == 0 and modified_files.items.len == 0 and deleted_files.items.len == 0 and untracked_files.items.len > 0) {
            try writePrefixed(platform_impl, "nothing added to commit but untracked files present (use \"git add\" to track)\n", comment_prefix);
        } else if (staged_files.items.len == 0 and (modified_files.items.len > 0 or deleted_files.items.len > 0)) {
            try writePrefixed(platform_impl, "no changes added to commit (use \"git add\" and/or \"git commit -a\")\n", comment_prefix);
        }
        if (!show_untracked) {
            if (show_hints) {
                try writePrefixed(platform_impl, "\nUntracked files not listed (use -u option to show untracked files)\n", comment_prefix);
            } else {
                try writePrefixed(platform_impl, "\nUntracked files not listed\n", comment_prefix);
            }
        }
    }
}

/// Write a string to stdout, prepending comment_prefix to each line.
/// If the string ends with \n, the prefix is added to each line.
/// Empty lines (just \n) get the prefix without trailing space.
fn writePrefixed(platform_impl: anytype, text: []const u8, cp: []const u8) !void {
    if (cp.len == 0) {
        try platform_impl.writeStdout(text);
        return;
    }
    // Process line by line
    var start: usize = 0;
    while (start < text.len) {
        if (std.mem.indexOfScalarPos(u8, text, start, '\n')) |nl| {
            if (nl == start) {
                // Empty line - write prefix trimmed (no trailing space) + newline
                // "# " -> "#"
                const trimmed = std.mem.trimRight(u8, cp, " ");
                try platform_impl.writeStdout(trimmed);
                try platform_impl.writeStdout("\n");
            } else {
                try platform_impl.writeStdout(cp);
                try platform_impl.writeStdout(text[start .. nl + 1]);
            }
            start = nl + 1;
        } else {
            // No newline at end
            if (start < text.len) {
                try platform_impl.writeStdout(cp);
                try platform_impl.writeStdout(text[start..]);
            }
            break;
        }
    }
}

/// Quote a path for porcelain output if it contains special characters
fn quotePath(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    var needs_quote = false;
    for (path) |c| {
        if (c == ' ' or c == '"' or c == '\\' or c == '\t' or c < 0x20 or c >= 0x7f) {
            needs_quote = true;
            break;
        }
    }
    if (!needs_quote) return try alloc.dupe(u8, path);
    
    var result = std.array_list.Managed(u8).init(alloc);
    errdefer result.deinit();
    try result.append('"');
    for (path) |c| {
        if (c == '"' or c == '\\') {
            try result.append('\\');
            try result.append(c);
        } else if (c == '\t') {
            try result.appendSlice("\\t");
        } else if (c == '\n') {
            try result.appendSlice("\\n");
        } else {
            try result.append(c);
        }
    }
    try result.append('"');
    return try result.toOwnedSlice();
}

/// Given a file path relative to repo root and the cwd prefix (also relative to repo root),
/// compute the display path relative to cwd.
/// E.g., prefix="dir1", path="dir1/modified" -> "modified"
///        prefix="dir1", path="dir2/added"    -> "../dir2/added"
///        prefix="",     path="dir1/modified" -> "dir1/modified"
fn makeRelativePath(alloc: std.mem.Allocator, path: []const u8, cwd_prefix: []const u8) ![]u8 {
    if (cwd_prefix.len == 0) return try alloc.dupe(u8, path);
    
    // Split both paths into components
    // If path starts with prefix, strip it
    if (std.mem.startsWith(u8, path, cwd_prefix)) {
        if (path.len == cwd_prefix.len) return try alloc.dupe(u8, ".");
        if (path[cwd_prefix.len] == '/') return try alloc.dupe(u8, path[cwd_prefix.len + 1 ..]);
    }
    
    // Count how many directory levels in cwd_prefix
    var up_count: usize = 1;
    for (cwd_prefix) |c| {
        if (c == '/') up_count += 1;
    }
    
    // Build "../" * up_count + path
    var result = std.array_list.Managed(u8).init(alloc);
    errdefer result.deinit();
    var i: usize = 0;
    while (i < up_count) : (i += 1) {
        try result.appendSlice("../");
    }
    try result.appendSlice(path);
    return try result.toOwnedSlice();
}

// helpers.Resolve a git alias by looking up alias.<name> in config files.
// helpers.Also supports subsection syntax: alias.<name>.command
// helpers.Returns the alias value (caller must free), or null if not found.