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

pub fn cmdStatus(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform, _: [][]const u8) !void {
    if (@import("builtin").target.os.tag == .freestanding) {
        try platform_impl.writeStderr("status: not supported in freestanding mode\n");
        return;
    }

    // helpers.Check for flags
    var porcelain = false;
    var show_branch = false;
    var short_format = false;
    var show_untracked = true; // default: show untracked files
    var status_args = std.array_list.Managed([]const u8).init(allocator);
    defer status_args.deinit();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--porcelain") or std.mem.eql(u8, arg, "--porcelain=v1")) {
            porcelain = true;
        } else if (std.mem.startsWith(u8, arg, "--porcelain=")) {
            const version = arg["--porcelain=".len..];
            if (std.mem.eql(u8, version, "v1") or std.mem.eql(u8, version, "1")) {
                porcelain = true;
            } else if (std.mem.eql(u8, version, "v2") or std.mem.eql(u8, version, "2")) {
                porcelain = true;
            } else {
                const msg = try std.fmt.allocPrint(allocator, "fatal: unsupported porcelain version '{s}'\n", .{version});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(128);
            }
        } else if (std.mem.eql(u8, arg, "--branch") or std.mem.eql(u8, arg, "-b")) {
            show_branch = true;
        } else if (std.mem.eql(u8, arg, "--short") or std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "-sb") or std.mem.eql(u8, arg, "-bs")) {
            short_format = true;
            porcelain = true; // short format uses same output as porcelain
            if (std.mem.eql(u8, arg, "-sb") or std.mem.eql(u8, arg, "-bs")) {
                show_branch = true;
            }
        } else if (std.mem.eql(u8, arg, "-uno") or std.mem.eql(u8, arg, "-ufalse") or std.mem.eql(u8, arg, "--untracked-files=no") or std.mem.eql(u8, arg, "--untracked-files=false") or std.mem.eql(u8, arg, "-u") or std.mem.eql(u8, arg, "--no-untracked-files")) {
            show_untracked = false;
        } else if (std.mem.eql(u8, arg, "-unormal") or std.mem.eql(u8, arg, "-utrue") or std.mem.eql(u8, arg, "--untracked-files=normal") or std.mem.eql(u8, arg, "--untracked-files=true") or std.mem.eql(u8, arg, "--untracked-files") or std.mem.eql(u8, arg, "-uall") or std.mem.eql(u8, arg, "--untracked-files=all")) {
            show_untracked = true;
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
            // NUL-terminate output entries - accept but treat as no-op for now
            // (porcelain mode already uses line-based output)
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

    // helpers.Check config for status.showUntrackedFiles (if not overridden by command line)
    if (show_untracked) {
        const config_path_for_ut = try std.fmt.allocPrint(allocator, "{s}/config", .{git_path});
        defer allocator.free(config_path_for_ut);
        if (platform_impl.fs.readFile(allocator, config_path_for_ut)) |cfg| {
            defer allocator.free(cfg);
            if (helpers.parseConfigValue(cfg, "status.showuntrackedfiles", allocator) catch null) |val| {
                defer allocator.free(val);
                if (std.mem.eql(u8, val, "no") or std.mem.eql(u8, val, "false") or std.mem.eql(u8, val, "0")) {
                    show_untracked = false;
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
        try platform_impl.writeStdout(branch_msg);

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
                try platform_impl.writeStdout(up_msg);
            } else {
                const ahead_count = helpers.countUnreachable(git_path, current_commit.?, upstream_hash, allocator, platform_impl);
                const behind_count = helpers.countUnreachable(git_path, upstream_hash, current_commit.?, allocator, platform_impl);
                if (ahead_count > 0 and behind_count > 0) {
                    const up_msg = try std.fmt.allocPrint(allocator, "Your branch and '{s}' have diverged,\nand have {d} and {d} different commits each, respectively.\n  (use \"git pull\" if you want to integrate the remote branch with yours)\n", .{upstream_display_name, ahead_count, behind_count});
                    defer allocator.free(up_msg);
                    try platform_impl.writeStdout(up_msg);
                } else if (ahead_count > 0) {
                    const up_msg = try std.fmt.allocPrint(allocator, "Your branch is ahead of '{s}' by {d} commit{s}.\n  (use \"git push\" to publish your local commits)\n", .{upstream_display_name, ahead_count, if (ahead_count > 1) "s" else ""});
                    defer allocator.free(up_msg);
                    try platform_impl.writeStdout(up_msg);
                } else if (behind_count > 0) {
                    const up_msg = try std.fmt.allocPrint(allocator, "Your branch is behind '{s}' by {d} commit{s}, and can be fast-forwarded.\n  (use \"git pull\" to update your local branch)\n", .{upstream_display_name, behind_count, if (behind_count > 1) "s" else ""});
                    defer allocator.free(up_msg);
                    try platform_impl.writeStdout(up_msg);
                }
            }
        }
        
        if (current_commit == null) {
            try platform_impl.writeStdout("\nNo commits yet\n");
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
                if (upstream_info) |info| {
                    const branch_header = try std.fmt.allocPrint(allocator, "## {s}...{s}\n", .{current_branch, info});
                    defer allocator.free(branch_header);
                    try platform_impl.writeStdout(branch_header);
                } else {
                    const branch_header = try std.fmt.allocPrint(allocator, "## {s}\n", .{current_branch});
                    defer allocator.free(branch_header);
                    try platform_impl.writeStdout(branch_header);
                }
            } else {
                try platform_impl.writeStdout("## helpers.HEAD (no branch)\n");
            }
        } else {
            const branch_header = try std.fmt.allocPrint(allocator, "## {s}\n", .{current_branch});
            defer allocator.free(branch_header);
            try platform_impl.writeStdout(branch_header);
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
                const parent_z = std.posix.toPosixPath(parent_full) catch break;
                const lstat_result = std.posix.fstatat(std.posix.AT.FDCWD, &parent_z, std.posix.AT.SYMLINK_NOFOLLOW) catch break;
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
                
                if (is_new) {
                    try porcelain_lines.append(try std.fmt.allocPrint(allocator, "A  {s}", .{entry.path}));
                } else {
                    try porcelain_lines.append(try std.fmt.allocPrint(allocator, "M  {s}", .{entry.path}));
                }
            }
        } else {
            try platform_impl.writeStdout("\nChanges to be committed:\n");
            if (current_commit == null) {
                try platform_impl.writeStdout("  (use \"git rm --cached <file>...\" to unstage)\n");
            } else {
                try platform_impl.writeStdout("  (use \"git restore --staged <file>...\" to unstage)\n");
            }
            
            for (staged_files.items) |entry| {
                const is_new = if (current_commit == null)
                    true
                else if (head_tree_hash) |hth|
                    (helpers.lookupBlobInTree(hth, entry.path, git_path, platform_impl, allocator) catch null) == null
                else
                    false;
                    
                if (is_new) {
                    const msg = try std.fmt.allocPrint(allocator, "\tnew file:   {s}\n", .{entry.path});
                    defer allocator.free(msg);
                    try platform_impl.writeStdout(msg);
                } else {
                    const msg = try std.fmt.allocPrint(allocator, "\tmodified:   {s}\n", .{entry.path});
                    defer allocator.free(msg);
                    try platform_impl.writeStdout(msg);
                }
            }
        }
    }

    // helpers.Show modified but unstaged files
    if (modified_files.items.len > 0) {
        if (porcelain) {
            for (modified_files.items) |entry| {
                try porcelain_lines.append(try std.fmt.allocPrint(allocator, " M {s}", .{entry.path}));
            }
        } else {
            try platform_impl.writeStdout("\nChanges not staged for commit:\n");
            try platform_impl.writeStdout("  (use \"git add <file>...\" to update what will be committed)\n");
            try platform_impl.writeStdout("  (use \"git restore <file>...\" to discard changes in working directory)\n");
            
            for (modified_files.items) |entry| {
                const msg = try std.fmt.allocPrint(allocator, "\tmodified:   {s}\n", .{entry.path});
                defer allocator.free(msg);
                try platform_impl.writeStdout(msg);
            }
        }
    }

    // helpers.Show deleted files
    if (deleted_files.items.len > 0) {
        if (porcelain) {
            for (deleted_files.items) |entry| {
                try porcelain_lines.append(try std.fmt.allocPrint(allocator, " D {s}", .{entry.path}));
            }
        } else {
            if (modified_files.items.len == 0) {
                try platform_impl.writeStdout("\nChanges not staged for commit:\n");
                try platform_impl.writeStdout("  (use \"git add <file>...\" to update what will be committed)\n");
                try platform_impl.writeStdout("  (use \"git restore <file>...\" to discard changes in working directory)\n");
            }
            
            for (deleted_files.items) |entry| {
                const msg = try std.fmt.allocPrint(allocator, "\tdeleted:    {s}\n", .{entry.path});
                defer allocator.free(msg);
                try platform_impl.writeStdout(msg);
            }
        }
    }

    // helpers.Find untracked files
    var untracked_files = if (show_untracked)
        helpers.findUntrackedFiles(allocator, repo_root, &index, &gitignore, platform_impl) catch std.array_list.Managed([]u8).init(allocator)
    else
        std.array_list.Managed([]u8).init(allocator);

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
                try porcelain_lines.append(try std.fmt.allocPrint(allocator, "?? {s}", .{file}));
            }
        } else {
            try platform_impl.writeStdout("\nUntracked files:\n");
            try platform_impl.writeStdout("  (use \"git add <file>...\" to include in what will be committed)\n");
            
            for (untracked_files.items) |file| {
                const msg = try std.fmt.allocPrint(allocator, "\t{s}\n", .{file});
                defer allocator.free(msg);
                try platform_impl.writeStdout(msg);
            }
            try platform_impl.writeStdout("\n");
        }
    }

    // helpers.Output sorted porcelain lines
    if (porcelain and porcelain_lines.items.len > 0) {
        // Sort: tracked entries in path order first, then untracked in path order
        std.mem.sort([]u8, porcelain_lines.items, {}, struct {
            fn lessThan(_: void, a: []u8, b: []u8) bool {
                const a_untracked = a.len >= 2 and a[0] == '?' and a[1] == '?';
                const b_untracked = b.len >= 2 and b[0] == '?' and b[1] == '?';
                if (a_untracked != b_untracked) return !a_untracked; // tracked before untracked
                const a_path = if (a.len > 3) a[3..] else a;
                const b_path = if (b.len > 3) b[3..] else b;
                return std.mem.order(u8, a_path, b_path) == .lt;
            }
        }.lessThan);
        for (porcelain_lines.items) |line| {
            const msg = try std.fmt.allocPrint(allocator, "{s}\n", .{line});
            defer allocator.free(msg);
            try platform_impl.writeStdout(msg);
        }
    }

    // Final summary message (only in non-porcelain mode)
    if (!porcelain) {
        if (staged_files.items.len == 0 and modified_files.items.len == 0 and deleted_files.items.len == 0 and untracked_files.items.len == 0) {
            if (current_commit == null) {
                try platform_impl.writeStdout("\nnothing to commit (create/copy files and use \"git add\" to track)\n");
            } else {
                try platform_impl.writeStdout("\nnothing to commit, working tree clean\n");
            }
        } else if (staged_files.items.len == 0 and modified_files.items.len == 0 and deleted_files.items.len == 0 and untracked_files.items.len > 0) {
            try platform_impl.writeStdout("nothing added to commit but untracked files present (use \"git add\" to track)\n");
        } else if (staged_files.items.len == 0 and (modified_files.items.len > 0 or deleted_files.items.len > 0)) {
            try platform_impl.writeStdout("no changes added to commit (use \"git add\" and/or \"git commit -a\")\n");
        }
        if (!show_untracked) {
            try platform_impl.writeStdout("Untracked files not listed (use -u option to show untracked files)\n");
        }
    }
}

// helpers.Resolve a git alias by looking up alias.<name> in config files.
// helpers.Also supports subsection syntax: alias.<name>.command
// helpers.Returns the alias value (caller must free), or null if not found.