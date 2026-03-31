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
    var porcelain_explicit = false; // true when --porcelain was used (paths always repo-relative)
    var nul_terminate = false;
    var show_branch = false;
    var no_branch_explicit = false;
    var short_format = false;
    var no_short_explicit = false;
    var show_stash = false;
    var show_stash_explicit = false;
    var show_ignored = false;
    var verbose_count: u8 = 0;
    var ignore_submodules: enum { none, untracked, dirty, all } = .none;
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
            no_branch_explicit = true;
        } else if (std.mem.eql(u8, arg, "--short") or std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "-sb") or std.mem.eql(u8, arg, "-bs")) {
            short_format = true;
            porcelain = true; // short format uses same output as porcelain
            if (std.mem.eql(u8, arg, "-sb") or std.mem.eql(u8, arg, "-bs")) {
                show_branch = true;
            }
        } else if (std.mem.eql(u8, arg, "--no-short")) {
            short_format = false;
            porcelain = false;
            no_short_explicit = true;
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
            verbose_count += 1;
        } else if (std.mem.eql(u8, arg, "--ignored")) {
            show_ignored = true;
        } else if (std.mem.eql(u8, arg, "--show-stash")) {
            show_stash = true;
            show_stash_explicit = true;
        } else if (std.mem.eql(u8, arg, "--no-show-stash")) {
            show_stash = false;
            show_stash_explicit = true;
        } else if (std.mem.eql(u8, arg, "--renames") or std.mem.eql(u8, arg, "--no-renames") or
            std.mem.eql(u8, arg, "--find-renames"))
        {
            // Rename detection - accept as no-op
        } else if (std.mem.eql(u8, arg, "--ahead-behind") or std.mem.eql(u8, arg, "--no-ahead-behind")) {
            // Ahead/behind display - accept as no-op
        } else if (std.mem.eql(u8, arg, "--ignore-submodules") or std.mem.eql(u8, arg, "--ignore-submodules=all")) {
            ignore_submodules = .all;
        } else if (std.mem.eql(u8, arg, "--ignore-submodules=dirty")) {
            ignore_submodules = .dirty;
        } else if (std.mem.eql(u8, arg, "--ignore-submodules=untracked")) {
            ignore_submodules = .untracked;
        } else if (std.mem.eql(u8, arg, "--ignore-submodules=none")) {
            ignore_submodules = .none;
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
            if (!short_format and !porcelain and !no_short_explicit) {
                // Check status.short config
                const short_val = if (helpers.getConfigOverride("status.short")) |v| v else
                    (helpers.parseConfigValue(cfg, "status.short", allocator) catch null) orelse null;
                if (short_val) |val| {
                    if (std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "yes") or std.mem.eql(u8, val, "1")) {
                        short_format = true;
                        porcelain = true;
                    }
                }
            }
            if (!show_branch and !no_branch_explicit and !porcelain_explicit) {
                // Check status.branch config (suppressed by --no-branch and --porcelain)
                const branch_val = if (helpers.getConfigOverride("status.branch")) |v| v else
                    (helpers.parseConfigValue(cfg, "status.branch", allocator) catch null) orelse null;
                if (branch_val) |val| {
                    if (std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "yes") or std.mem.eql(u8, val, "1")) {
                        show_branch = true;
                    }
                }
            }
            if (!show_stash_explicit) {
                // Check status.showStash config
                const stash_val = if (helpers.getConfigOverride("status.showStash")) |v| v else
                    (helpers.parseConfigValue(cfg, "status.showstash", allocator) catch null) orelse null;
                if (stash_val) |val| {
                    if (std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "yes") or std.mem.eql(u8, val, "1")) {
                        show_stash = true;
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
    
    // Detect detached HEAD
    const is_detached = std.mem.eql(u8, current_branch, "HEAD");

    if (!porcelain) {
        if (is_detached) {
            if (current_commit) |hash| {
                const short_hash = if (hash.len >= 7) hash[0..7] else hash;
                const branch_msg = try std.fmt.allocPrint(allocator, "HEAD detached at {s}\n", .{short_hash});
                defer allocator.free(branch_msg);
                try writeWithCommentPrefix(platform_impl, branch_msg, comment_prefix);
            } else {
                try writeWithCommentPrefix(platform_impl, "HEAD detached at (unknown)\n", comment_prefix);
            }
        } else {
            const branch_msg = try std.fmt.allocPrint(allocator, "On branch {s}\n", .{current_branch});
            defer allocator.free(branch_msg);
            try writeWithCommentPrefix(platform_impl, branch_msg, comment_prefix);
        }

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
                try writeWithCommentPrefix(platform_impl, up_msg, comment_prefix);
            } else {
                const ahead_count = helpers.countUnreachable(git_path, current_commit.?, upstream_hash, allocator, platform_impl);
                const behind_count = helpers.countUnreachable(git_path, upstream_hash, current_commit.?, allocator, platform_impl);
                if (ahead_count > 0 and behind_count > 0) {
                    const up_msg = try std.fmt.allocPrint(allocator, "Your branch and '{s}' have diverged,\nand have {d} and {d} different commits each, respectively.\n", .{upstream_display_name, ahead_count, behind_count});
                    defer allocator.free(up_msg);
                    try writeWithCommentPrefix(platform_impl, up_msg, comment_prefix);
                    if (show_hints) try writeWithCommentPrefix(platform_impl, "  (use \"git pull\" if you want to integrate the remote branch with yours)\n", comment_prefix);
                } else if (ahead_count > 0) {
                    const up_msg = try std.fmt.allocPrint(allocator, "Your branch is ahead of '{s}' by {d} commit{s}.\n", .{upstream_display_name, ahead_count, if (ahead_count > 1) "s" else ""});
                    defer allocator.free(up_msg);
                    try writeWithCommentPrefix(platform_impl, up_msg, comment_prefix);
                    if (show_hints) try writeWithCommentPrefix(platform_impl, "  (use \"git push\" to publish your local commits)\n", comment_prefix);
                } else if (behind_count > 0) {
                    const up_msg = try std.fmt.allocPrint(allocator, "Your branch is behind '{s}' by {d} commit{s}, and can be fast-forwarded.\n", .{upstream_display_name, behind_count, if (behind_count > 1) "s" else ""});
                    defer allocator.free(up_msg);
                    try writeWithCommentPrefix(platform_impl, up_msg, comment_prefix);
                    if (show_hints) try writeWithCommentPrefix(platform_impl, "  (use \"git pull\" to update your local branch)\n", comment_prefix);
                }
            }
        }
        
        if (current_commit == null) {
            try writeWithCommentPrefix(platform_impl, "\nNo commits yet\n", comment_prefix);
        }
    } else if (porcelain and show_branch) {
        // helpers.Check if helpers.HEAD is detached
        const head_content_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_path});
        defer allocator.free(head_content_path);
        const head_raw = platform_impl.fs.readFile(allocator, head_content_path) catch null;
        defer if (head_raw) |h| allocator.free(h);
        
        if (head_raw) |h| {
            if (std.mem.startsWith(u8, h, "ref: ")) {
                // helpers.Read upstream tracking info
                const upstream_info = helpers.getUpstreamTrackingInfo(git_path, current_branch, allocator, platform_impl);
                defer if (upstream_info) |info| allocator.free(info);
                const branch_line_end: []const u8 = if (nul_terminate) "\x00" else "\n";
                if (upstream_info) |info| {
                    const branch_header = try std.fmt.allocPrint(allocator, "## {s}...{s}", .{current_branch, info});
                    defer allocator.free(branch_header);
                    try platform_impl.writeStdout(branch_header);
                    try platform_impl.writeStdout(branch_line_end);
                } else {
                    const branch_header = try std.fmt.allocPrint(allocator, "## {s}", .{current_branch});
                    defer allocator.free(branch_header);
                    try platform_impl.writeStdout(branch_header);
                    try platform_impl.writeStdout(branch_line_end);
                }
            } else {
                try platform_impl.writeStdout("## helpers.HEAD (no branch)");
                try platform_impl.writeStdout(if (nul_terminate) "\x00" else "\n");
            }
        } else {
            const branch_header = try std.fmt.allocPrint(allocator, "## {s}", .{current_branch});
            defer allocator.free(branch_header);
            try platform_impl.writeStdout(branch_header);
            try platform_impl.writeStdout(if (nul_terminate) "\x00" else "\n");
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
        } else if (entry.mode == 0o160000) {
            // Submodule (gitlink) - skip working tree modification check
            // Just check if it's different from HEAD
            if (current_commit == null) {
                try staged_files.append(entry);
            } else {
                const is_different_from_head = blk: {
                    if (head_tree_map.get(entry.path)) |tree_sha1| {
                        break :blk !std.mem.eql(u8, &tree_sha1, &entry.sha1);
                    }
                    // Not in HEAD tree - it's new (staged)
                    break :blk true;
                };
                if (is_different_from_head) {
                    try staged_files.append(entry);
                }
            }
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
                
                if (is_new) {
                    const qp = try quotePath(allocator, entry.path);
                    defer allocator.free(qp);
                    try porcelain_lines.append(try std.fmt.allocPrint(allocator, "A  {s}", .{qp}));
                } else {
                    const qp = try quotePath(allocator, entry.path);
                    defer allocator.free(qp);
                    try porcelain_lines.append(try std.fmt.allocPrint(allocator, "M  {s}", .{qp}));
                }
            }
        } else {
            try writeWithCommentPrefix(platform_impl, "\nChanges to be committed:\n", comment_prefix);
            if (current_commit == null) {
                if (show_hints) try writeWithCommentPrefix(platform_impl, "  (use \"git rm --cached <file>...\" to unstage)\n", comment_prefix);
            } else {
                if (show_hints) try writeWithCommentPrefix(platform_impl, "  (use \"git restore --staged <file>...\" to unstage)\n", comment_prefix);
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
                    try writeWithCommentPrefix(platform_impl, msg, comment_prefix);
                } else {
                    const rel_path = try makeRelativePath(allocator, entry.path, prefix);
                    defer allocator.free(rel_path);
                    const msg = try std.fmt.allocPrint(allocator, "\tmodified:   {s}\n", .{rel_path});
                    defer allocator.free(msg);
                    try writeWithCommentPrefix(platform_impl, msg, comment_prefix);
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
                try porcelain_lines.append(try std.fmt.allocPrint(allocator, " M {s}", .{qp}));
            }
        } else {
            try writeWithCommentPrefix(platform_impl, "\nChanges not staged for commit:\n", comment_prefix);
            if (show_hints) try writeWithCommentPrefix(platform_impl, "  (use \"git add <file>...\" to update what will be committed)\n", comment_prefix);
            if (show_hints) try writeWithCommentPrefix(platform_impl, "  (use \"git restore <file>...\" to discard changes in working directory)\n", comment_prefix);
            
            for (modified_files.items) |entry| {
                const rel_path = try makeRelativePath(allocator, entry.path, prefix);
                defer allocator.free(rel_path);
                const msg = try std.fmt.allocPrint(allocator, "\tmodified:   {s}\n", .{rel_path});
                defer allocator.free(msg);
                try writeWithCommentPrefix(platform_impl, msg, comment_prefix);
            }
        }
    }

    // helpers.Show deleted files
    if (deleted_files.items.len > 0) {
        if (porcelain) {
            for (deleted_files.items) |entry| {
                const qp = try quotePath(allocator, entry.path);
                defer allocator.free(qp);
                try porcelain_lines.append(try std.fmt.allocPrint(allocator, " D {s}", .{qp}));
            }
        } else {
            if (modified_files.items.len == 0) {
                try writeWithCommentPrefix(platform_impl, "\nChanges not staged for commit:\n", comment_prefix);
                if (show_hints) try writeWithCommentPrefix(platform_impl, "  (use \"git add <file>...\" to update what will be committed)\n", comment_prefix);
                if (show_hints) try writeWithCommentPrefix(platform_impl, "  (use \"git restore <file>...\" to discard changes in working directory)\n", comment_prefix);
            }
            
            for (deleted_files.items) |entry| {
                const rel_path = try makeRelativePath(allocator, entry.path, prefix);
                defer allocator.free(rel_path);
                const msg = try std.fmt.allocPrint(allocator, "\tdeleted:    {s}\n", .{rel_path});
                defer allocator.free(msg);
                try writeWithCommentPrefix(platform_impl, msg, comment_prefix);
            }
        }
    }

    // Build a set of submodule paths (gitlink entries with mode 160000)
    var submodule_paths = std.StringHashMap(void).init(allocator);
    defer submodule_paths.deinit();
    for (index.entries.items) |entry| {
        if (entry.mode == 0o160000) {
            submodule_paths.put(entry.path, {}) catch {};
        }
    }

    // helpers.Find untracked files
    var untracked_files = if (show_untracked)
        helpers.findUntrackedFiles(allocator, repo_root, &index, &gitignore, platform_impl) catch std.array_list.Managed([]u8).init(allocator)
    else
        std.array_list.Managed([]u8).init(allocator);

    // Filter out submodule paths from untracked files
    if (submodule_paths.count() > 0 and untracked_files.items.len > 0) {
        var filtered = std.array_list.Managed([]u8).init(allocator);
        for (untracked_files.items) |file| {
            // Check if this is a submodule directory (e.g., "sm/" -> check "sm")
            const check_path = if (file.len > 0 and file[file.len - 1] == '/')
                file[0 .. file.len - 1]
            else
                file;
            if (submodule_paths.contains(check_path)) {
                allocator.free(file);
            } else {
                filtered.append(file) catch {
                    allocator.free(file);
                };
            }
        }
        untracked_files.deinit();
        untracked_files = filtered;
    }

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
                try porcelain_lines.append(try std.fmt.allocPrint(allocator, "?? {s}", .{qp}));
            }
        } else {
            try writeWithCommentPrefix(platform_impl, "\nUntracked files:\n", comment_prefix);
            if (show_hints) try writeWithCommentPrefix(platform_impl, "  (use \"git add <file>...\" to include in what will be committed)\n", comment_prefix);
            
            for (untracked_files.items) |file| {
                const rel_path = try makeRelativePath(allocator, file, prefix);
                defer allocator.free(rel_path);
                const msg = try std.fmt.allocPrint(allocator, "\t{s}\n", .{rel_path});
                defer allocator.free(msg);
                try writeWithCommentPrefix(platform_impl, msg, comment_prefix);
            }
            try writeWithCommentPrefix(platform_impl, "\n", comment_prefix);
        }
    }

    // Collect and output ignored files if --ignored
    if (show_ignored) {
        var ignored_list = findIgnoredFiles(allocator, repo_root, &index, &gitignore) catch std.array_list.Managed([]u8).init(allocator);
        defer {
            for (ignored_list.items) |f| allocator.free(f);
            ignored_list.deinit();
        }

        // Sort ignored files
        if (ignored_list.items.len > 1) {
            std.mem.sort([]u8, ignored_list.items, {}, struct {
                fn lessThan(_: void, a: []u8, b: []u8) bool {
                    return std.mem.order(u8, a, b) == .lt;
                }
            }.lessThan);
        }

        if (ignored_list.items.len > 0) {
            if (porcelain) {
                for (ignored_list.items) |file| {
                    const qp = try quotePath(allocator, file);
                    defer allocator.free(qp);
                    try porcelain_lines.append(try std.fmt.allocPrint(allocator, "!! {s}", .{qp}));
                }
            } else {
                // Don't add leading \n if untracked section already added a trailing blank line
                if (untracked_files.items.len > 0) {
                    try writeWithCommentPrefix(platform_impl, "Ignored files:\n", comment_prefix);
                } else {
                    try writeWithCommentPrefix(platform_impl, "\nIgnored files:\n", comment_prefix);
                }
                if (show_hints) try writeWithCommentPrefix(platform_impl, "  (use \"git add -f <file>...\" to include in what will be committed)\n", comment_prefix);
                for (ignored_list.items) |file| {
                    const rel_path = try makeRelativePath(allocator, file, prefix);
                    defer allocator.free(rel_path);
                    const msg = try std.fmt.allocPrint(allocator, "\t{s}\n", .{rel_path});
                    defer allocator.free(msg);
                    try writeWithCommentPrefix(platform_impl, msg, comment_prefix);
                }
                try writeWithCommentPrefix(platform_impl, "\n", comment_prefix);
            }
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
            fn category(s: []const u8) u2 {
                if (s.len >= 2 and s[0] == '!' and s[1] == '!') return 2; // ignored last
                if (s.len >= 2 and s[0] == '?' and s[1] == '?') return 1; // untracked middle
                return 0; // tracked first
            }
            fn lessThan(_: void, a: []u8, b: []u8) bool {
                const a_cat = category(a);
                const b_cat = category(b);
                if (a_cat != b_cat) return a_cat < b_cat;
                const a_path = stripQuote(if (a.len > 3) a[3..] else a);
                const b_path = stripQuote(if (b.len > 3) b[3..] else b);
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
                try writeWithCommentPrefix(platform_impl, "\nnothing to commit (create/copy files and use \"git add\" to track)\n", comment_prefix);
            } else {
                try writeWithCommentPrefix(platform_impl, "\nnothing to commit, working tree clean\n", comment_prefix);
            }
        } else if (staged_files.items.len == 0 and modified_files.items.len == 0 and deleted_files.items.len == 0 and untracked_files.items.len > 0) {
            try writeWithCommentPrefix(platform_impl, "nothing added to commit but untracked files present (use \"git add\" to track)\n", comment_prefix);
        } else if (staged_files.items.len == 0 and (modified_files.items.len > 0 or deleted_files.items.len > 0)) {
            try writeWithCommentPrefix(platform_impl, "no changes added to commit (use \"git add\" and/or \"git commit -a\")\n", comment_prefix);
        }
        if (!show_untracked) {
            if (show_hints) {
                try writeWithCommentPrefix(platform_impl, "\nUntracked files not listed (use -u option to show untracked files)\n", comment_prefix);
            } else {
                try writeWithCommentPrefix(platform_impl, "\nUntracked files not listed\n", comment_prefix);
            }
        }
    }

    // Show stash info (only in non-porcelain mode, after summary)
    if (!porcelain and show_stash) {
        // Count stash entries by reading refs/stash reflog
        const stash_log_path = try std.fmt.allocPrint(allocator, "{s}/logs/refs/stash", .{git_path});
        defer allocator.free(stash_log_path);
        if (platform_impl.fs.readFile(allocator, stash_log_path)) |stash_log| {
            defer allocator.free(stash_log);
            var stash_count: usize = 0;
            var stash_lines = std.mem.splitScalar(u8, stash_log, '\n');
            while (stash_lines.next()) |line| {
                if (line.len > 0) stash_count += 1;
            }
            if (stash_count > 0) {
                if (stash_count == 1) {
                    try platform_impl.writeStdout("Your stash currently has 1 entry\n");
                } else {
                    const stash_msg = try std.fmt.allocPrint(allocator, "Your stash currently has {d} entries\n", .{stash_count});
                    defer allocator.free(stash_msg);
                    try platform_impl.writeStdout(stash_msg);
                }
            }
        } else |_| {}
    }

    // Verbose mode: show diff of staged changes
    if (verbose_count > 0 and !porcelain and !short_format) {
        const diff_cmd = @import("git/diff_cmd.zig");
        if (verbose_count >= 2) {
            // -v -v: show both staged and unstaged diffs with headers
            try platform_impl.writeStdout("Changes to be committed:\n");
            const cached_args = [_][]const u8{ "--cached", "-c", "diff.mnemonicprefix=true" };
            // Actually, just pass --cached; mnemonic prefix is handled by config
            var cached_args2 = [_][]const u8{"--cached"};
            var cached_iter = platform_mod.ArgIterator{ .args = &cached_args2, .allocator = allocator };
            diff_cmd.cmdDiff(allocator, &cached_iter, platform_impl) catch {};
            try platform_impl.writeStdout("--------------------------------------------------\n");
            try platform_impl.writeStdout("Changes not staged for commit:\n");
            var unstaged_args = [_][]const u8{};
            var unstaged_iter = platform_mod.ArgIterator{ .args = &unstaged_args, .allocator = allocator };
            diff_cmd.cmdDiff(allocator, &unstaged_iter, platform_impl) catch {};
            _ = cached_args;
        } else {
            var diff_args = [_][]const u8{"--cached"};
            var diff_arg_iter = platform_mod.ArgIterator{ .args = &diff_args, .allocator = allocator };
            diff_cmd.cmdDiff(allocator, &diff_arg_iter, platform_impl) catch {};
        }
    }
}

/// Write a string with comment prefix applied to each line.
/// Empty lines become just the comment char (no trailing space).
fn writeWithCommentPrefix(platform_impl: anytype, text: []const u8, prefix: []const u8) !void {
    if (prefix.len == 0) {
        try platform_impl.writeStdout(text);
        return;
    }
    // We need to prefix each line
    var start: usize = 0;
    while (start < text.len) {
        if (std.mem.indexOfScalarPos(u8, text, start, '\n')) |nl| {
            if (nl == start) {
                // Empty line: just comment char + newline
                try platform_impl.writeStdout(prefix[0..1]); // just '#'
                try platform_impl.writeStdout("\n");
            } else if (text[start] == '\t') {
                // Tab-indented line: use just '#' (no space before tab)
                try platform_impl.writeStdout(prefix[0..1]);
                try platform_impl.writeStdout(text[start..nl]);
                try platform_impl.writeStdout("\n");
            } else {
                try platform_impl.writeStdout(prefix);
                try platform_impl.writeStdout(text[start..nl]);
                try platform_impl.writeStdout("\n");
            }
            start = nl + 1;
        } else {
            // Last line without newline
            if (start < text.len) {
                if (text[start] == '\t') {
                    try platform_impl.writeStdout(prefix[0..1]);
                } else {
                    try platform_impl.writeStdout(prefix);
                }
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

fn findIgnoredFiles(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    index: *const index_mod.Index,
    gitignore: *const gitignore_mod.GitIgnore,
) !std.array_list.Managed([]u8) {
    var ignored_files = std.array_list.Managed([]u8).init(allocator);
    errdefer {
        for (ignored_files.items) |f| allocator.free(f);
        ignored_files.deinit();
    }

    var tracked_files = std.StringHashMap(void).init(allocator);
    defer tracked_files.deinit();
    for (index.entries.items) |entry| {
        try tracked_files.put(entry.path, {});
    }

    try scanForIgnored(allocator, repo_root, "", &ignored_files, &tracked_files, gitignore);
    return ignored_files;
}

fn scanForIgnored(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    relative_path: []const u8,
    ignored_files: *std.array_list.Managed([]u8),
    tracked_files: *const std.StringHashMap(void),
    gitignore: *const gitignore_mod.GitIgnore,
) !void {
    const full_path = if (relative_path.len == 0)
        try allocator.dupe(u8, repo_root)
    else
        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, relative_path });
    defer allocator.free(full_path);

    var dir = std.fs.cwd().openDir(full_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iterator = dir.iterate();
    while (iterator.next() catch null) |entry| {
        if (std.mem.eql(u8, entry.name, ".git")) continue;

        const entry_rel = if (relative_path.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ relative_path, entry.name });
        defer allocator.free(entry_rel);

        if (gitignore.isIgnored(entry_rel)) {
            // This is an ignored file/dir - add it
            if (!tracked_files.contains(entry_rel)) {
                try ignored_files.append(try allocator.dupe(u8, entry_rel));
            }
            // Don't recurse into ignored directories
            continue;
        }

        switch (entry.kind) {
            .directory => {
                try scanForIgnored(allocator, repo_root, entry_rel, ignored_files, tracked_files, gitignore);
            },
            else => {},
        }
    }
}

// helpers.Resolve a git alias by looking up alias.<name> in config files.
// helpers.Also supports subsection syntax: alias.<name>.command
// helpers.Returns the alias value (caller must free), or null if not found.