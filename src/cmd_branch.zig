// Auto-generated from main_common.zig - cmd_branch
// Agents: this file is yours to edit for the commands it contains.

const std = @import("std");
const platform_mod = @import("platform/platform.zig");
const helpers = @import("git_helpers.zig");
const cmd_reflog = @import("cmd_reflog.zig");

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

pub fn cmdBranch(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    if (@import("builtin").target.os.tag == .freestanding) {
        try platform_impl.writeStderr("branch: not supported in freestanding mode\n");
        return;
    }

    // helpers.Find .git directory
    const git_path = helpers.findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any parent up to mount point /)\nStopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set).\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);

    // Collect all args first for multi-flag handling
    var all_args = std.array_list.Managed([]const u8).init(allocator);
    defer all_args.deinit();
    while (args.next()) |a| try all_args.append(a);

    // Pre-scan for modifier flags and validate mode conflicts
    var verbose = false;
    var mode_count: u32 = 0;
    var has_delete = false;
    var has_move = false;
    var has_copy = false;
    var has_list = false;
    for (all_args.items) |a| {
        if (std.mem.eql(u8, a, "-v") or std.mem.eql(u8, a, "--verbose")) verbose = true;
        if (std.mem.eql(u8, a, "-d") or std.mem.eql(u8, a, "-D")) { has_delete = true; mode_count += 1; }
        if (std.mem.eql(u8, a, "-m") or std.mem.eql(u8, a, "-M")) { has_move = true; mode_count += 1; }
        if (std.mem.eql(u8, a, "-c") or std.mem.eql(u8, a, "-C")) { has_copy = true; mode_count += 1; }
        if (std.mem.eql(u8, a, "-l") or std.mem.eql(u8, a, "--list")) { has_list = true; mode_count += 1; }
    }
    if (mode_count > 1) {
        try platform_impl.writeStderr("fatal: options are incompatible\n");
        std.process.exit(1);
    }

    {
        var i: usize = 0;
        while (i < all_args.items.len) {
            if (std.mem.eql(u8, all_args.items[i], "-v") or std.mem.eql(u8, all_args.items[i], "--verbose")) {
                _ = all_args.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }
    // Reconstruct arg iterator from remaining args
    var arg_idx: usize = 0;
    const ArgIter = struct {
        items: []const []const u8,
        idx: *usize,
        pub fn next(self: *@This()) ?[]const u8 {
            if (self.idx.* >= self.items.len) return null;
            const v = self.items[self.idx.*];
            self.idx.* += 1;
            return v;
        }
    };
    var fake_args = ArgIter{ .items = all_args.items, .idx = &arg_idx };
    const first_arg = fake_args.next();
    if (first_arg == null) {
        // List branches
        const current_branch = refs.getCurrentBranch(git_path, platform_impl, allocator) catch "master";
        defer allocator.free(current_branch);

        var branches = try refs.listBranches(git_path, platform_impl, allocator);
        defer {
            for (branches.items) |branch| {
                allocator.free(branch);
            }
            branches.deinit();
        }

        for (branches.items) |branch| {
            const prefix = if (std.mem.eql(u8, branch, current_branch)) "* " else "  ";
            const msg = try std.fmt.allocPrint(allocator, "{s}{s}\n", .{ prefix, branch });
            defer allocator.free(msg);
            try platform_impl.writeStdout(msg);
        }
    } else if (std.mem.startsWith(u8, first_arg.?, "--set-upstream-to=") or std.mem.eql(u8, first_arg.?, "--set-upstream-to") or std.mem.eql(u8, first_arg.?, "-u")) {
        // Set upstream tracking branch
        const upstream_name = if (std.mem.startsWith(u8, first_arg.?, "--set-upstream-to="))
            first_arg.?["--set-upstream-to=".len..]
        else
            fake_args.next() orelse {
                try platform_impl.writeStderr("fatal: no upstream branch specified\n");
                std.process.exit(128);
                unreachable;
            };
        const branch_name = fake_args.next() orelse blk: {
            break :blk refs.getCurrentBranch(git_path, platform_impl, allocator) catch {
                try platform_impl.writeStderr("fatal: no branch specified and no current branch\n");
                std.process.exit(128);
                unreachable;
            };
        };
        // branch_name may need freeing if allocated
        
        // helpers.Write tracking config: [branch "name"] remote = . merge = refs/heads/upstream
        const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{git_path});
        defer allocator.free(config_path);
        const existing = platform_impl.fs.readFile(allocator, config_path) catch try allocator.dupe(u8, "");
        defer allocator.free(existing);
        
        // helpers.Remove existing [branch "name"] section if present
        var new_config = std.array_list.Managed(u8).init(allocator);
        defer new_config.deinit();
        var skip_section = false;
        const section_header = try std.fmt.allocPrint(allocator, "[branch \"{s}\"]", .{branch_name});
        defer allocator.free(section_header);
        var lines = std.mem.splitScalar(u8, existing, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (std.mem.startsWith(u8, trimmed, section_header)) {
                skip_section = true;
                continue;
            }
            if (skip_section and trimmed.len > 0 and trimmed[0] == '[') {
                skip_section = false;
            }
            if (!skip_section) {
                new_config.appendSlice(line) catch {};
                new_config.append('\n') catch {};
            }
        }
        // helpers.Add new section
        const tracking_section = try std.fmt.allocPrint(allocator, "[branch \"{s}\"]\n\tremote = .\n\tmerge = refs/heads/{s}\n", .{branch_name, upstream_name});
        defer allocator.free(tracking_section);
        new_config.appendSlice(tracking_section) catch {};
        
        std.fs.cwd().writeFile(.{ .sub_path = config_path, .data = new_config.items }) catch {};
        
        const success_msg = try std.fmt.allocPrint(allocator, "branch '{s}' set up to track '{s}'.\n", .{branch_name, upstream_name});
        defer allocator.free(success_msg);
        try platform_impl.writeStdout(success_msg);
    } else if (std.mem.eql(u8, first_arg.?, "--unset-upstream")) {
        // Unset upstream
        const branch_name = fake_args.next() orelse blk: {
            break :blk refs.getCurrentBranch(git_path, platform_impl, allocator) catch {
                try platform_impl.writeStderr("fatal: no branch specified\n");
                std.process.exit(128);
                unreachable;
            };
        };
        const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{git_path});
        defer allocator.free(config_path);
        const existing = platform_impl.fs.readFile(allocator, config_path) catch try allocator.dupe(u8, "");
        defer allocator.free(existing);
        var new_config = std.array_list.Managed(u8).init(allocator);
        defer new_config.deinit();
        var skip_section = false;
        const section_header = try std.fmt.allocPrint(allocator, "[branch \"{s}\"]", .{branch_name});
        defer allocator.free(section_header);
        var line_iter = std.mem.splitScalar(u8, existing, '\n');
        while (line_iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (std.mem.startsWith(u8, trimmed, section_header)) { skip_section = true; continue; }
            if (skip_section and trimmed.len > 0 and trimmed[0] == '[') { skip_section = false; }
            if (!skip_section) { new_config.appendSlice(line) catch {}; new_config.append('\n') catch {}; }
        }
        std.fs.cwd().writeFile(.{ .sub_path = config_path, .data = new_config.items }) catch {};

    } else if (std.mem.eql(u8, first_arg.?, "-d") or std.mem.eql(u8, first_arg.?, "-D")) {
        // helpers.Delete branch - may have -r flag and/or multiple branch names
        var is_remote = false;
        var names_to_delete = std.array_list.Managed([]const u8).init(allocator);
        defer names_to_delete.deinit();
        while (fake_args.next()) |darg| {
            if (std.mem.eql(u8, darg, "-r") or std.mem.eql(u8, darg, "--remotes")) {
                is_remote = true;
            } else if (std.mem.startsWith(u8, darg, "@{-")) {
                // helpers.Resolve @{-N} to previous branch name
                if (std.mem.indexOf(u8, darg, "}")) |close| {
                    const n_str = darg[3..close];
                    const n = std.fmt.parseInt(u32, n_str, 10) catch {
                        try names_to_delete.append(darg);
                        continue;
                    };
                    const prev_branch = helpers.resolvePreviousBranch(git_path, n, allocator, platform_impl) catch {
                        const emsg = try std.fmt.allocPrint(allocator, "error: branch '{s}' not found.\n", .{darg});
                        defer allocator.free(emsg);
                        try platform_impl.writeStderr(emsg);
                        std.process.exit(1);
                    };
                    try names_to_delete.append(prev_branch);
                } else {
                    try names_to_delete.append(darg);
                }
            } else if (std.mem.eql(u8, darg, "-")) {
                // "-" is alias for @{-1}
                const prev_branch = helpers.resolvePreviousBranch(git_path, 1, allocator, platform_impl) catch {
                    const emsg = try std.fmt.allocPrint(allocator, "error: branch '-' not found.\n", .{});
                    defer allocator.free(emsg);
                    try platform_impl.writeStderr(emsg);
                    std.process.exit(1);
                };
                try names_to_delete.append(prev_branch);
            } else {
                try names_to_delete.append(darg);
            }
        }
        if (names_to_delete.items.len == 0) {
            try platform_impl.writeStderr("fatal: branch name required\n");
            std.process.exit(128);
        }

        const current_branch = refs.getCurrentBranch(git_path, platform_impl, allocator) catch "master";
        defer allocator.free(current_branch);

        for (names_to_delete.items) |branch_name| {
            if (!is_remote and std.mem.eql(u8, branch_name, current_branch)) {
                const msg = try std.fmt.allocPrint(allocator, "error: cannot delete branch '{s}' used by worktree at '{s}'\n", .{ branch_name, "." });
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(1);
            }

            if (is_remote) {
                // helpers.Delete remote tracking branch
                const ref_path = try std.fmt.allocPrint(allocator, "{s}/refs/remotes/{s}", .{ git_path, branch_name });
                defer allocator.free(ref_path);
                std.fs.cwd().deleteFile(ref_path) catch |err| switch (err) {
                    error.FileNotFound => {
                        // helpers.Try packed-helpers.refs
                        const msg = try std.fmt.allocPrint(allocator, "error: remote-tracking branch '{s}' not found.\n", .{branch_name});
                        defer allocator.free(msg);
                        try platform_impl.writeStderr(msg);
                        std.process.exit(1);
                    },
                    else => return err,
                };
                const success_msg = try std.fmt.allocPrint(allocator, "Deleted remote-tracking branch {s}.\n", .{branch_name});
                defer allocator.free(success_msg);
                try platform_impl.writeStdout(success_msg);
            } else {
                refs.deleteBranch(git_path, branch_name, platform_impl, allocator) catch |err| switch (err) {
                    error.FileNotFound => {
                        const msg = try std.fmt.allocPrint(allocator, "error: branch '{s}' not found.\n", .{branch_name});
                        defer allocator.free(msg);
                        try platform_impl.writeStderr(msg);
                        std.process.exit(1);
                    },
                    else => return err,
                };
                // Also delete the reflog for the branch
                {
                    const reflog_path = std.fmt.allocPrint(allocator, "{s}/logs/refs/heads/{s}", .{ git_path, branch_name }) catch null;
                    if (reflog_path) |rp| {
                        defer allocator.free(rp);
                        std.fs.cwd().deleteFile(rp) catch {};
                        // Clean up empty parent dirs
                        var parent = std.fs.path.dirname(branch_name);
                        while (parent) |dir| {
                            if (dir.len == 0 or std.mem.eql(u8, dir, ".")) break;
                            const dir_full = std.fmt.allocPrint(allocator, "{s}/logs/refs/heads/{s}", .{ git_path, dir }) catch break;
                            defer allocator.free(dir_full);
                            std.fs.cwd().deleteDir(dir_full) catch break;
                            parent = std.fs.path.dirname(dir);
                        }
                    }
                }
                const success_msg = try std.fmt.allocPrint(allocator, "Deleted branch {s}.\n", .{branch_name});
                defer allocator.free(success_msg);
                try platform_impl.writeStdout(success_msg);
            }
        }
    } else if (std.mem.eql(u8, first_arg.?, "-m") or std.mem.eql(u8, first_arg.?, "-M")) {
        // Rename branch
        const arg1 = fake_args.next() orelse {
            try platform_impl.writeStderr("fatal: branch name required\n");
            std.process.exit(128);
        };
        const arg2 = fake_args.next();

        // helpers.If only one argument: rename current branch to arg1
        // helpers.If two arguments: rename arg1 to arg2
        const old_name = if (arg2 != null) arg1 else blk: {
            break :blk refs.getCurrentBranch(git_path, platform_impl, allocator) catch {
                try platform_impl.writeStderr("fatal: no branch to rename\n");
                std.process.exit(128);
                unreachable;
            };
        };
        defer if (arg2 == null) allocator.free(old_name);
        const new_name = arg2 orelse arg1;

        // helpers.Read old branch hash
        const old_ref_path = try std.fmt.allocPrint(allocator, "{s}/refs/heads/{s}", .{ git_path, old_name });
        defer allocator.free(old_ref_path);
        const old_hash_result = std.fs.cwd().readFileAlloc(allocator, old_ref_path, 4096);
        const is_unborn = if (old_hash_result) |_| false else |_| true;
        const old_hash = if (old_hash_result) |h| h else |_| try allocator.dupe(u8, "");
        defer allocator.free(old_hash);

        if (!is_unborn) {
            // helpers.Write new branch ref
            const new_ref_path = try std.fmt.allocPrint(allocator, "{s}/refs/heads/{s}", .{ git_path, new_name });
            defer allocator.free(new_ref_path);
            // helpers.Create parent directories if needed (for branch names with slashes)
            if (std.fs.path.dirname(new_ref_path)) |parent_dir| {
                std.fs.cwd().makePath(parent_dir) catch {};
            }
            try std.fs.cwd().writeFile(.{ .sub_path = new_ref_path, .data = old_hash });

            // helpers.Delete old branch ref (if different name)
            if (!std.mem.eql(u8, old_name, new_name)) {
                std.fs.cwd().deleteFile(old_ref_path) catch {};
            }
        }

        // Move the reflog from old to new branch
        if (!std.mem.eql(u8, old_name, new_name)) {
            const old_reflog_path = try std.fmt.allocPrint(allocator, "{s}/logs/refs/heads/{s}", .{ git_path, old_name });
            defer allocator.free(old_reflog_path);
            const new_reflog_path = try std.fmt.allocPrint(allocator, "{s}/logs/refs/heads/{s}", .{ git_path, new_name });
            defer allocator.free(new_reflog_path);
            // Create parent directories for new reflog
            if (std.fs.path.dirname(new_reflog_path)) |parent_dir| {
                std.fs.cwd().makePath(parent_dir) catch {};
            }
            std.fs.cwd().rename(old_reflog_path, new_reflog_path) catch {
                // If rename fails, try copy + delete
                if (std.fs.cwd().readFileAlloc(allocator, old_reflog_path, 10 * 1024 * 1024)) |content| {
                    defer allocator.free(content);
                    std.fs.cwd().writeFile(.{ .sub_path = new_reflog_path, .data = content }) catch {};
                    std.fs.cwd().deleteFile(old_reflog_path) catch {};
                } else |_| {}
            };
            // Clean up empty parent dirs for old reflog
            var parent = std.fs.path.dirname(old_name);
            while (parent) |dir| {
                if (dir.len == 0 or std.mem.eql(u8, dir, ".")) break;
                const dir_full = std.fmt.allocPrint(allocator, "{s}/logs/refs/heads/{s}", .{ git_path, dir }) catch break;
                defer allocator.free(dir_full);
                std.fs.cwd().deleteDir(dir_full) catch break;
                parent = std.fs.path.dirname(dir);
            }
        }

        // helpers.Update helpers.HEAD if it pointed to the old branch
        const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_path});
        defer allocator.free(head_path);
        const head_content = std.fs.cwd().readFileAlloc(allocator, head_path, 4096) catch "";
        defer if (head_content.len > 0) allocator.free(head_content);
        const head_trimmed = std.mem.trimRight(u8, head_content, "\r\n");
        const expected_old = try std.fmt.allocPrint(allocator, "ref: refs/heads/{s}", .{old_name});
        defer allocator.free(expected_old);
        if (std.mem.eql(u8, head_trimmed, expected_old)) {
            const new_head = try std.fmt.allocPrint(allocator, "ref: refs/heads/{s}\n", .{new_name});
            defer allocator.free(new_head);
            try std.fs.cwd().writeFile(.{ .sub_path = head_path, .data = new_head });
        }
    } else if (std.mem.eql(u8, first_arg.?, "-c") or std.mem.eql(u8, first_arg.?, "-C")) {
        // helpers.Copy branch
        const arg1 = fake_args.next() orelse {
            try platform_impl.writeStderr("fatal: branch name required\n");
            std.process.exit(128);
        };
        const arg2 = fake_args.next();
        const src_name = if (arg2 != null) arg1 else blk: {
            break :blk refs.getCurrentBranch(git_path, platform_impl, allocator) catch {
                try platform_impl.writeStderr("fatal: no branch to copy\n");
                std.process.exit(128);
                unreachable;
            };
        };
        defer if (arg2 == null) allocator.free(src_name);
        const dst_name = arg2 orelse arg1;

        const src_ref_path = try std.fmt.allocPrint(allocator, "{s}/refs/heads/{s}", .{ git_path, src_name });
        defer allocator.free(src_ref_path);
        const src_hash = std.fs.cwd().readFileAlloc(allocator, src_ref_path, 4096) catch {
            const msg = try std.fmt.allocPrint(allocator, "error: refname refs/heads/{s} not found\n", .{src_name});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
            unreachable;
        };
        defer allocator.free(src_hash);
        const dst_ref_path = try std.fmt.allocPrint(allocator, "{s}/refs/heads/{s}", .{ git_path, dst_name });
        defer allocator.free(dst_ref_path);
        try std.fs.cwd().writeFile(.{ .sub_path = dst_ref_path, .data = src_hash });
    } else if (std.mem.eql(u8, first_arg.?, "--force") or std.mem.eql(u8, first_arg.?, "-f")) {
        // Force create/reset branch
        const branch_name = fake_args.next() orelse {
            try platform_impl.writeStderr("fatal: branch name required\n");
            std.process.exit(128);
        };
        const start_point = fake_args.next();
        // helpers.Resolve start_point using helpers.resolveRevision for complex helpers.refs like HEAD~1
        const resolved_sp_force: ?[]const u8 = if (start_point) |sp|
            helpers.resolveRevision(git_path, sp, platform_impl, allocator) catch null
        else
            null;
        defer if (resolved_sp_force) |rsp| allocator.free(rsp);
        
        if (start_point != null and resolved_sp_force == null) {
            const msg = try std.fmt.allocPrint(allocator, "fatal: not a valid object name: '{s}'\n", .{start_point.?});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
        }
        refs.createBranch(git_path, branch_name, resolved_sp_force, platform_impl, allocator) catch |err| switch (err) {
            error.NoCommitsYet => {
                try platform_impl.writeStderr("fatal: not a valid object name: 'master'\n");
                std.process.exit(128);
            },
            else => return err,
        };
    } else if (std.mem.eql(u8, first_arg.?, "--list") or std.mem.eql(u8, first_arg.?, "-l")) {
        // List branches (with optional pattern)
        const current_branch2 = refs.getCurrentBranch(git_path, platform_impl, allocator) catch "master";
        defer allocator.free(current_branch2);
        var branches2 = try refs.listBranches(git_path, platform_impl, allocator);
        defer {
            for (branches2.items) |branch| allocator.free(branch);
            branches2.deinit();
        }
        const pattern = fake_args.next();
        for (branches2.items) |branch| {
            if (pattern) |p| {
                // helpers.Simple glob matching
                if (!helpers.simpleGlobMatch(p, branch)) continue;
            }
            const prefix2 = if (std.mem.eql(u8, branch, current_branch2)) "* " else "  ";
            const msg2 = try std.fmt.allocPrint(allocator, "{s}{s}\n", .{ prefix2, branch });
            defer allocator.free(msg2);
            try platform_impl.writeStdout(msg2);
        }
    } else if (std.mem.eql(u8, first_arg.?, "--create-reflog")) {
        // helpers.Create branch with reflog
        const branch_name = fake_args.next() orelse {
            try platform_impl.writeStderr("fatal: branch name required\n");
            std.process.exit(128);
        };
        const start_point = fake_args.next();
        // helpers.Resolve start_point using helpers.resolveRevision for complex helpers.refs
        const resolved_sp_reflog: ?[]const u8 = if (start_point) |sp|
            helpers.resolveRevision(git_path, sp, platform_impl, allocator) catch null
        else
            null;
        defer if (resolved_sp_reflog) |rsp| allocator.free(rsp);
        
        if (start_point != null and resolved_sp_reflog == null) {
            const msg = try std.fmt.allocPrint(allocator, "fatal: not a valid object name: '{s}'\n", .{start_point.?});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
        }
        refs.createBranch(git_path, branch_name, resolved_sp_reflog, platform_impl, allocator) catch |err| switch (err) {
            error.NoCommitsYet => {
                try platform_impl.writeStderr("fatal: not a valid object name: 'master'\n");
                std.process.exit(128);
            },
            else => return err,
        };
        // helpers.Create reflog for the new branch
        const new_hash = refs.resolveRef(git_path, std.fmt.allocPrint(allocator, "refs/heads/{s}", .{branch_name}) catch "", platform_impl, allocator) catch null;
        defer if (new_hash) |h| allocator.free(h);
        if (new_hash) |nh| {
            // Determine source name (branch name or start point) for reflog message
            const current_branch = refs.getCurrentBranch(git_path, platform_impl, allocator) catch null;
            defer if (current_branch) |cb| allocator.free(cb);
            const source_name = if (start_point) |sp| sp else if (current_branch) |cb| (if (std.mem.startsWith(u8, cb, "refs/heads/")) cb["refs/heads/".len..] else cb) else "HEAD";
            const reflog_msg_b = std.fmt.allocPrint(allocator, "branch: Created from {s}", .{source_name}) catch "branch: Created from HEAD";
            defer if (reflog_msg_b.len > 0) allocator.free(@constCast(reflog_msg_b));
            const ref_name_b = std.fmt.allocPrint(allocator, "refs/heads/{s}", .{branch_name}) catch "";
            defer if (ref_name_b.len > 0) allocator.free(@constCast(ref_name_b));
            helpers.writeReflogEntry(git_path, ref_name_b, "0000000000000000000000000000000000000000", nh, reflog_msg_b, allocator, platform_impl) catch {};
        }
    } else if (std.mem.eql(u8, first_arg.?, "--copy")) {
        const copy_src = fake_args.next() orelse {
            try platform_impl.writeStderr("fatal: branch name required\n");
            std.process.exit(128);
            unreachable;
        };
        const copy_dst = fake_args.next() orelse copy_src;
        const src_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{copy_src});
        defer allocator.free(src_ref);
        const src_hash2 = refs.resolveRef(git_path, src_ref, platform_impl, allocator) catch {
            const emsg = try std.fmt.allocPrint(allocator, "fatal: no such branch: '{s}'\n", .{copy_src});
            defer allocator.free(emsg);
            try platform_impl.writeStderr(emsg);
            std.process.exit(128);
            unreachable;
        };
        defer if (src_hash2) |h2| allocator.free(h2);
        const dst_ref_path3 = try std.fmt.allocPrint(allocator, "{s}/refs/heads/{s}", .{ git_path, copy_dst });
        defer allocator.free(dst_ref_path3);
        try std.fs.cwd().writeFile(.{ .sub_path = dst_ref_path3, .data = src_hash2 orelse "" });
    } else if (std.mem.eql(u8, first_arg.?, "--no-sort") or std.mem.startsWith(u8, first_arg.?, "--sort=") or
        std.mem.eql(u8, first_arg.?, "--sort") or std.mem.startsWith(u8, first_arg.?, "--track=") or
        std.mem.eql(u8, first_arg.?, "--no-track") or std.mem.eql(u8, first_arg.?, "--no-column") or
        std.mem.startsWith(u8, first_arg.?, "--column") or std.mem.eql(u8, first_arg.?, "--color") or
        std.mem.startsWith(u8, first_arg.?, "--color=") or std.mem.eql(u8, first_arg.?, "--no-color") or
        std.mem.eql(u8, first_arg.?, "-q") or std.mem.eql(u8, first_arg.?, "--quiet") or
        std.mem.eql(u8, first_arg.?, "-a") or std.mem.eql(u8, first_arg.?, "--all") or
        std.mem.eql(u8, first_arg.?, "-r") or std.mem.eql(u8, first_arg.?, "--remotes"))
    {
        const current_branch4 = refs.getCurrentBranch(git_path, platform_impl, allocator) catch "master";
        defer allocator.free(current_branch4);
        var branches4 = try refs.listBranches(git_path, platform_impl, allocator);
        defer {
            for (branches4.items) |br4| allocator.free(br4);
            branches4.deinit();
        }
        while (fake_args.next()) |_| {}
        for (branches4.items) |br4| {
            const p4 = if (std.mem.eql(u8, br4, current_branch4)) "* " else "  ";
            const m4 = try std.fmt.allocPrint(allocator, "{s}{s}\n", .{ p4, br4 });
            defer allocator.free(m4);
            try platform_impl.writeStdout(m4);
        }
    } else {
        // helpers.Create new branch
        const branch_name = first_arg.?;
        const start_point = fake_args.next();
        
        // helpers.Check if branch already exists
        const existing_ref = try std.fmt.allocPrint(allocator, "{s}/refs/heads/{s}", .{ git_path, branch_name });
        defer allocator.free(existing_ref);
        const branch_exists = if (std.fs.cwd().access(existing_ref, .{})) |_| true else |_| false;
        if (branch_exists) {
            const emsg = try std.fmt.allocPrint(allocator, "fatal: a branch named '{s}' already exists\n", .{branch_name});
            defer allocator.free(emsg);
            try platform_impl.writeStderr(emsg);
            std.process.exit(128);
        }
        
        // helpers.Validate branch name
        if (std.mem.eql(u8, branch_name, "HEAD")) {
            try platform_impl.writeStderr("fatal: 'HEAD' is not a valid branch name\n");
            std.process.exit(128);
        }
        
        // helpers.Also check for names starting with -
        if (std.mem.startsWith(u8, branch_name, "-")) {
            const emsg = try std.fmt.allocPrint(allocator, "fatal: '{s}' is not a valid branch name\n", .{branch_name});
            defer allocator.free(emsg);
            try platform_impl.writeStderr(emsg);
            std.process.exit(128);
        }

        // helpers.Resolve start_point using helpers.resolveRevision for complex helpers.refs like A^0
        const resolved_sp: ?[]const u8 = if (start_point) |sp|
            helpers.resolveRevision(git_path, sp, platform_impl, allocator) catch null
        else
            null;
        defer if (resolved_sp) |rsp| allocator.free(rsp);
        
        if (start_point != null and resolved_sp == null) {
            const msg = try std.fmt.allocPrint(allocator, "fatal: not a valid object name: '{s}'\n", .{start_point.?});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
        }
        
        refs.createBranch(git_path, branch_name, resolved_sp, platform_impl, allocator) catch |err| switch (err) {
            error.NoCommitsYet => {
                try platform_impl.writeStderr("fatal: not a valid object name: 'master'\n");
                std.process.exit(128);
            },
            error.InvalidStartPoint => {
                const msg = try std.fmt.allocPrint(allocator, "fatal: not a valid object name: '{s}'\n", .{start_point.?});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(128);
            },
            else => return err,
        };
    }
}

// helpers.Resolve any object hash by prefix (not just commits). helpers.Returns full 40-char hash.