// Auto-generated from main_common.zig - cmd_checkout
// Agents: this file is yours to edit for the commands it contains.

const std = @import("std");
const platform_mod = @import("platform/platform.zig");
const helpers = @import("git_helpers.zig");
const cmd_remote = @import("cmd_remote.zig");
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
const crlf_mod = @import("crlf.zig");
const check_attr = @import("cmd_check_attr.zig");

pub fn cmdCheckout(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    if (@import("builtin").target.os.tag == .freestanding) {
        try platform_impl.writeStderr("checkout: not supported in freestanding mode\n");
        return;
    }

    const first_arg = args.next() orelse {
        try platform_impl.writeStderr("error: pathspec '' did not match any file(s) known to git\n");
        std.process.exit(128);
    };

    // helpers.Find .git directory
    const git_path = helpers.findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any parent up to mount point /)\nStopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set).\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);

    // helpers.Handle "checkout -" (switch to previous branch)
    var effective_first_arg = first_arg;
    var resolved_dash: ?[]u8 = null;
    defer if (resolved_dash) |rd| allocator.free(rd);
    if (std.mem.eql(u8, first_arg, "-")) {
        // helpers.Read helpers.HEAD reflog to find previous branch
        const head_reflog_path = try std.fmt.allocPrint(allocator, "{s}/logs/HEAD", .{git_path});
        defer allocator.free(head_reflog_path);
        if (platform_impl.fs.readFile(allocator, head_reflog_path)) |reflog_content| {
            defer allocator.free(reflog_content);
            // helpers.Find the last "checkout: moving from X to Y" entry
            var last_from: ?[]const u8 = null;
            var lines = std.mem.splitScalar(u8, reflog_content, '\n');
            while (lines.next()) |line| {
                if (std.mem.indexOf(u8, line, "checkout: moving from ")) |idx| {
                    const rest = line[idx + "checkout: moving from ".len..];
                    if (std.mem.indexOf(u8, rest, " to ")) |to_idx| {
                        last_from = rest[0..to_idx];
                    }
                }
            }
            if (last_from) |from_branch| {
                resolved_dash = try allocator.dupe(u8, from_branch);
                effective_first_arg = resolved_dash.?;
            } else {
                try platform_impl.writeStderr("error: no previous branch\n");
                std.process.exit(1);
            }
        } else |_| {
            try platform_impl.writeStderr("error: no previous branch\n");
            std.process.exit(1);
        }
    }

    // helpers.Handle -t / --track flag
    var want_track = false;
    if (std.mem.eql(u8, effective_first_arg, "-t") or std.mem.eql(u8, effective_first_arg, "--track")) {
        want_track = true;
        effective_first_arg = args.next() orelse {
            try platform_impl.writeStderr("fatal: '--track' requires a value\n");
            std.process.exit(128);
        };
    }

    // helpers.Check if this is --orphan flag (create orphan branch)
    if (std.mem.eql(u8, effective_first_arg, "--orphan")) {
        const branch_name = args.next() orelse {
            try platform_impl.writeStderr("fatal: option '--orphan' requires a value\n");
            std.process.exit(128);
        };

        // Set helpers.HEAD to point to the new branch (which doesn't exist yet)
        const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_path});
        defer allocator.free(head_path);
        const ref_content = try std.fmt.allocPrint(allocator, "ref: refs/heads/{s}\n", .{branch_name});
        defer allocator.free(ref_content);
        platform_impl.fs.writeFile(head_path, ref_content) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "error: failed to create orphan branch: {}\n", .{err});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(1);
        };


        const success_msg = try std.fmt.allocPrint(allocator, "Switched to a new branch '{s}'\n", .{branch_name});
        defer allocator.free(success_msg);
        try platform_impl.writeStderr(success_msg);
        return;
    }

    // helpers.Check if this is a -b flag (create new branch)
    if (std.mem.eql(u8, effective_first_arg, "-b")) {
        const raw_branch_name = args.next() orelse {
            try platform_impl.writeStderr("fatal: option '-b' requires a value\n");
            std.process.exit(128);
            unreachable;
        };
        // Resolve @{-N} to actual branch name
        var resolved_branch_name: ?[]u8 = null;
        defer if (resolved_branch_name) |rbn| allocator.free(rbn);
        if (std.mem.startsWith(u8, raw_branch_name, "@{-")) {
            if (std.mem.indexOf(u8, raw_branch_name, "}")) |close| {
                const n_str = raw_branch_name[3..close];
                if (std.fmt.parseInt(u32, n_str, 10)) |n| {
                    resolved_branch_name = helpers.resolvePreviousBranch(git_path, n, allocator, platform_impl) catch null;
                } else |_| {}
            }
        }
        const branch_name = if (resolved_branch_name) |rbn| @as([]const u8, rbn) else raw_branch_name;

        // Check for HEAD.lock
        {
            const lock_path = try std.fmt.allocPrint(allocator, "{s}/HEAD.lock", .{git_path});
            defer allocator.free(lock_path);
            if (std.fs.cwd().access(lock_path, .{})) |_| {
                try platform_impl.writeStderr("fatal: Unable to create '/HEAD.lock': File exists.\n");
                std.process.exit(128);
            } else |_| {}
        }

        // helpers.Get optional start point - resolve it to a hash
        const start_point_arg = args.next();
        var resolved_start: ?[]const u8 = null;
        if (start_point_arg) |sp| {
            resolved_start = helpers.resolveRevision(git_path, sp, platform_impl, allocator) catch null;
            // Validate that start point is a commit, not a tree or blob
            if (resolved_start) |hash| {
                const obj = objects.GitObject.load(hash, git_path, platform_impl, allocator) catch null;
                if (obj) |o| {
                    defer o.deinit(allocator);
                    if (o.type != .commit) {
                        const msg = try std.fmt.allocPrint(allocator, "fatal: Cannot update paths and switch to branch '{s}' at the same time.\n", .{branch_name});
                        defer allocator.free(msg);
                        try platform_impl.writeStderr(msg);
                        std.process.exit(128);
                    }
                }
            }
        }
        defer if (resolved_start) |r| allocator.free(@constCast(r));

        // Check if branch already exists (checkout -b fails if branch exists)
        {
            const existing_ref = try std.fmt.allocPrint(allocator, "{s}/refs/heads/{s}", .{ git_path, branch_name });
            defer allocator.free(existing_ref);
            if (std.fs.accessAbsolute(existing_ref, .{})) |_| {
                const emsg = try std.fmt.allocPrint(allocator, "fatal: a branch named '{s}' already exists\n", .{branch_name});
                defer allocator.free(emsg);
                try platform_impl.writeStderr(emsg);
                std.process.exit(128);
            } else |_| {}
        }

        // helpers.Create new branch at start point (or current helpers.HEAD)
        refs.createBranch(git_path, branch_name, resolved_start orelse start_point_arg, platform_impl, allocator) catch |err| switch (err) {
            error.NoCommitsYet, error.RefNotFound, error.FileNotFound => {
                // On empty repo, just set helpers.HEAD to new branch
                const hp = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_path});
                defer allocator.free(hp);
                const rc = try std.fmt.allocPrint(allocator, "ref: refs/heads/{s}\n", .{branch_name});
                defer allocator.free(rc);
                platform_impl.fs.writeFile(hp, rc) catch {};
                const sm = try std.fmt.allocPrint(allocator, "Switched to a new branch '{s}'\n", .{branch_name});
                defer allocator.free(sm);
                try platform_impl.writeStderr(sm);
                return;
            },
            error.InvalidStartPoint => {
                try platform_impl.writeStderr("fatal: not a valid object name\n");
                std.process.exit(128);
            },
            else => return err,
        };

        // helpers.Get old branch name for reflog
        var old_branch_for_b: ?[]u8 = null;
        defer if (old_branch_for_b) |ob| allocator.free(ob);
        var old_hash_for_b: ?[]u8 = null;
        defer if (old_hash_for_b) |oh| allocator.free(oh);
        {
            const hp = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_path});
            defer allocator.free(hp);
            if (platform_impl.fs.readFile(allocator, hp)) |hd| {
                defer allocator.free(hd);
                const tr = std.mem.trim(u8, hd, " \t\r\n");
                if (std.mem.startsWith(u8, tr, "ref: refs/heads/")) {
                    old_branch_for_b = try allocator.dupe(u8, tr["ref: refs/heads/".len..]);
                    const rp = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_path, tr["ref: ".len..] });
                    defer allocator.free(rp);
                    if (platform_impl.fs.readFile(allocator, rp)) |rd| {
                        defer allocator.free(rd);
                        old_hash_for_b = try allocator.dupe(u8, std.mem.trim(u8, rd, " \t\r\n"));
                    } else |_| {}
                }
            } else |_| {}
        }

        // Switch to the new branch
        refs.updateHEAD(git_path, branch_name, platform_impl, allocator) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "error: failed to checkout branch '{s}': {}\n", .{ branch_name, err });
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(1);
        };

        // helpers.If start_point was specified, checkout the tree of that commit
        if (start_point_arg != null) {
            const branch_ref_str = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{branch_name});
            defer allocator.free(branch_ref_str);
            const commit_hash_opt = (refs.resolveRef(git_path, branch_ref_str, platform_impl, allocator) catch null) orelse null;
            if (commit_hash_opt) |ch| {
                defer allocator.free(ch);
                // Check for dirty working tree that conflicts with target
                {
                    var dirty_files_b = std.array_list.Managed([]const u8).init(allocator);
                    defer {
                        for (dirty_files_b.items) |df| allocator.free(df);
                        dirty_files_b.deinit();
                    }
                    checkDirtyWorkingTree(allocator, git_path, ch, platform_impl, &dirty_files_b) catch {};
                    if (dirty_files_b.items.len > 0) {
                        try platform_impl.writeStderr("error: Your local changes to the following files would be overwritten by checkout:\n");
                        for (dirty_files_b.items) |df| {
                            const dmsg = try std.fmt.allocPrint(allocator, "\t{s}\n", .{df});
                            defer allocator.free(dmsg);
                            try platform_impl.writeStderr(dmsg);
                        }
                        try platform_impl.writeStderr("Please commit your changes or stash them before you switch branches.\nAborting\n");
                        // Undo: delete the branch we just created
                        refs.deleteBranch(git_path, branch_name, platform_impl, allocator) catch {};
                        std.process.exit(1);
                    }
                }
                helpers.checkoutCommitTree(git_path, ch, allocator, platform_impl) catch {};
            }
        }

        // helpers.Write reflog entry
        {
            const from_name = if (old_branch_for_b) |ob| ob else "HEAD";
            const old_h = if (old_hash_for_b) |oh| oh else "0000000000000000000000000000000000000000";
            const reflog_msg_b = try std.fmt.allocPrint(allocator, "checkout: moving from {s} to {s}", .{ from_name, branch_name });
            defer allocator.free(reflog_msg_b);
            helpers.writeReflogEntry(git_path, "HEAD", old_h, old_h, reflog_msg_b, allocator, platform_impl) catch {};

            // Write reflog entry for the new branch ref
            const branch_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{branch_name});
            defer allocator.free(branch_ref);
            const created_from = if (start_point_arg) |sp| sp else "HEAD";
            const branch_reflog_msg = try std.fmt.allocPrint(allocator, "branch: Created from {s}", .{created_from});
            defer allocator.free(branch_reflog_msg);
            helpers.writeReflogEntry(git_path, branch_ref, "0000000000000000000000000000000000000000", old_h, branch_reflog_msg, allocator, platform_impl) catch {};
        }

        // Set up tracking if -t was specified
        if (want_track) {
            const tracking_branch = if (old_branch_for_b) |ob| ob else "main";
            cmd_remote.setTrackingConfig(git_path, branch_name, ".", tracking_branch, allocator, platform_impl);
        }

        const success_msg = try std.fmt.allocPrint(allocator, "Switched to a new branch '{s}'\n", .{branch_name});
        defer allocator.free(success_msg);
        try platform_impl.writeStdout(success_msg);
    } else if (std.mem.eql(u8, effective_first_arg, "-B")) {
        // -B: create or reset branch
        const branch_name = args.next() orelse {
            try platform_impl.writeStderr("fatal: option '-B' requires a value\n");
            std.process.exit(128);
        };
        
        // helpers.Get optional start point, resolve it
        const start_point_raw = args.next();
        var resolved_start_B: ?[]u8 = null;
        defer if (resolved_start_B) |r| allocator.free(r);
        const start_point: ?[]const u8 = if (start_point_raw) |sp| blk: {
            resolved_start_B = helpers.resolveRevision(git_path, sp, platform_impl, allocator) catch null;
            break :blk if (resolved_start_B) |r| r else sp;
        } else null;
        
        // helpers.Delete existing branch if it exists (reset)
        const ref_path = try std.fmt.allocPrint(allocator, "{s}/refs/heads/{s}", .{ git_path, branch_name });
        defer allocator.free(ref_path);
        std.fs.cwd().deleteFile(ref_path) catch {};
        
        // helpers.Create the branch
        refs.createBranch(git_path, branch_name, start_point, platform_impl, allocator) catch |err| {
            // helpers.For -B on empty repo (no commits yet), just set helpers.HEAD
            switch (err) {
                error.NoCommitsYet, error.RefNotFound, error.FileNotFound => {
                    const head_path2 = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_path});
                    defer allocator.free(head_path2);
                    const ref_content = try std.fmt.allocPrint(allocator, "ref: refs/heads/{s}\n", .{branch_name});
                    defer allocator.free(ref_content);
                    platform_impl.fs.writeFile(head_path2, ref_content) catch {};
                    const reset_msg2 = try std.fmt.allocPrint(allocator, "Switched to a new branch '{s}'\n", .{branch_name});
                    defer allocator.free(reset_msg2);
                    try platform_impl.writeStderr(reset_msg2);
                    return;
                },
                else => return err,
            }
        };
        
        // Switch to the branch
        refs.updateHEAD(git_path, branch_name, platform_impl, allocator) catch {};

        // helpers.Checkout the tree of the new branch head
        if (start_point != null) {
            const branch_ref_B = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{branch_name});
            defer allocator.free(branch_ref_B);
            const commit_hash_B_opt = (refs.resolveRef(git_path, branch_ref_B, platform_impl, allocator) catch null) orelse null;
            if (commit_hash_B_opt) |ch| {
                defer allocator.free(ch);
                // Check for dirty working tree that conflicts with target
                {
                    var dirty_files_B = std.array_list.Managed([]const u8).init(allocator);
                    defer {
                        for (dirty_files_B.items) |df| allocator.free(df);
                        dirty_files_B.deinit();
                    }
                    checkDirtyWorkingTree(allocator, git_path, ch, platform_impl, &dirty_files_B) catch {};
                    if (dirty_files_B.items.len > 0) {
                        try platform_impl.writeStderr("error: Your local changes to the following files would be overwritten by checkout:\n");
                        for (dirty_files_B.items) |df| {
                            const dmsg = try std.fmt.allocPrint(allocator, "\t{s}\n", .{df});
                            defer allocator.free(dmsg);
                            try platform_impl.writeStderr(dmsg);
                        }
                        try platform_impl.writeStderr("Please commit your changes or stash them before you switch branches.\nAborting\n");
                        std.process.exit(1);
                    }
                }
                helpers.checkoutCommitTree(git_path, ch, allocator, platform_impl) catch {};
            }
        }
        
        const reset_msg = try std.fmt.allocPrint(allocator, "Switched to and reset branch '{s}'\n", .{branch_name});
        defer allocator.free(reset_msg);
        try platform_impl.writeStderr(reset_msg);
    } else if (std.mem.eql(u8, effective_first_arg, "--theirs") or std.mem.eql(u8, effective_first_arg, "--ours")) {
        // checkout --theirs/--ours <paths>: resolve conflicts using stage 2 (ours) or 3 (theirs)
        const want_stage: u16 = if (std.mem.eql(u8, effective_first_arg, "--ours")) 2 else 3;
        var idx = index_mod.Index.load(git_path, platform_impl, allocator) catch return;
        defer idx.deinit();
        const repo_root = std.fs.path.dirname(git_path) orelse ".";

        while (args.next()) |path_arg| {
            const path = if (std.mem.eql(u8, path_arg, "--")) continue else path_arg;
            for (idx.entries.items) |entry| {
                const entry_stage = @as(u16, (entry.flags >> 12) & 0x3);
                if (entry_stage != want_stage) continue;
                if (std.mem.eql(u8, entry.path, path) or helpers.simpleGlobMatch(path, entry.path)) {
                    var hash_hex: [40]u8 = undefined;
                    for (entry.sha1, 0..) |byte, bi| {
                        hash_hex[bi * 2] = "0123456789abcdef"[byte >> 4];
                        hash_hex[bi * 2 + 1] = "0123456789abcdef"[byte & 0xf];
                    }
                    const blob = objects.GitObject.load(&hash_hex, git_path, platform_impl, allocator) catch continue;
                    defer blob.deinit(allocator);
                    const full_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, entry.path }) catch continue;
                    defer allocator.free(full_path);
                    // Ensure parent directory exists
                    if (std.fs.path.dirname(full_path)) |dir| {
                        std.fs.cwd().makePath(dir) catch {};
                    }
                    platform_impl.fs.writeFile(full_path, blob.data) catch {};
                }
            }
        }
    } else if (std.mem.eql(u8, effective_first_arg, "--")) {
        // checkout -- <paths>: restore files from index
        var idx = index_mod.Index.load(git_path, platform_impl, allocator) catch return;
        defer idx.deinit();
        const repo_root = std.fs.path.dirname(git_path) orelse ".";

        // Load CRLF conversion settings
        var attr_rules = crlf_mod.loadAttrRules(allocator, repo_root, git_path, platform_impl) catch std.array_list.Managed(check_attr.AttrRule).init(allocator);
        defer {
            for (attr_rules.items) |*rule| rule.deinit(allocator);
            attr_rules.deinit();
        }
        const autocrlf_val = helpers.getConfigValueByKey(git_path, "core.autocrlf", allocator);
        defer if (autocrlf_val) |v| allocator.free(v);
        const eol_config_val = helpers.getConfigValueByKey(git_path, "core.eol", allocator);
        defer if (eol_config_val) |v| allocator.free(v);
        
        while (args.next()) |path| {
            for (idx.entries.items) |entry| {
                if (std.mem.eql(u8, entry.path, path) or helpers.simpleGlobMatch(path, entry.path)) {
                    // helpers.Load blob and write to working tree
                    var hash_hex: [40]u8 = undefined;
                    for (entry.sha1, 0..) |byte, bi| {
                        hash_hex[bi * 2] = "0123456789abcdef"[byte >> 4];
                        hash_hex[bi * 2 + 1] = "0123456789abcdef"[byte & 0xf];
                    }
                    const blob = objects.GitObject.load(&hash_hex, git_path, platform_impl, allocator) catch continue;
                    defer blob.deinit(allocator);
                    const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, entry.path });
                    defer allocator.free(full_path);
                    // Apply CRLF conversion
                    const converted = crlf_mod.applyCheckoutConversion(allocator, blob.data, entry.path, attr_rules.items, autocrlf_val, eol_config_val) catch blob.data;
                    defer if (converted.ptr != blob.data.ptr) allocator.free(converted);
                    platform_impl.fs.writeFile(full_path, converted) catch {};
                }
            }
        }
    } else {
        // helpers.Parse checkout arguments
        var quiet = std.mem.eql(u8, effective_first_arg, "--quiet") or std.mem.eql(u8, effective_first_arg, "-q");
        var detach = std.mem.eql(u8, effective_first_arg, "--detach");
        var force = std.mem.eql(u8, effective_first_arg, "-f") or std.mem.eql(u8, effective_first_arg, "--force");
        var target: []const u8 = effective_first_arg;
        
        // helpers.If the first arg was a flag, consume flags and find the target
        if (quiet or detach or force) {
            var found_target = false;
            while (args.next()) |arg| {
                if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
                    quiet = true;
                } else if (std.mem.eql(u8, arg, "--detach")) {
                    detach = true;
                } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--force")) {
                    force = true;
                } else if (std.mem.eql(u8, arg, "-b") or std.mem.eql(u8, arg, "-B")) {
                    // -f -b <branch> [<start_point>]: create and switch to new branch
                    const is_reset = std.mem.eql(u8, arg, "-B");
                    const branch_name_fb = args.next() orelse {
                        try platform_impl.writeStderr("fatal: option '-b' requires a value\n");
                        std.process.exit(128);
                    };
                    const start_point_fb = args.next();
                    var resolved_start_fb: ?[]u8 = null;
                    defer if (resolved_start_fb) |r| allocator.free(r);
                    if (start_point_fb) |sp| {
                        resolved_start_fb = helpers.resolveRevision(git_path, sp, platform_impl, allocator) catch null;
                    }
                    // helpers.Delete existing branch if -B
                    if (is_reset) {
                        const ref_path_fb = try std.fmt.allocPrint(allocator, "{s}/refs/heads/{s}", .{ git_path, branch_name_fb });
                        defer allocator.free(ref_path_fb);
                        std.fs.cwd().deleteFile(ref_path_fb) catch {};
                    }
                    refs.createBranch(git_path, branch_name_fb, if (resolved_start_fb) |r| r else start_point_fb, platform_impl, allocator) catch |err| switch (err) {
                        error.NoCommitsYet, error.RefNotFound, error.FileNotFound => {
                            const hp = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_path});
                            defer allocator.free(hp);
                            const rc = try std.fmt.allocPrint(allocator, "ref: refs/heads/{s}\n", .{branch_name_fb});
                            defer allocator.free(rc);
                            platform_impl.fs.writeFile(hp, rc) catch {};
                            const sm = try std.fmt.allocPrint(allocator, "Switched to a new branch '{s}'\n", .{branch_name_fb});
                            defer allocator.free(sm);
                            try platform_impl.writeStderr(sm);
                            return;
                        },
                        error.InvalidStartPoint => {
                            try platform_impl.writeStderr("fatal: not a valid object name\n");
                            std.process.exit(128);
                        },
                        else => return err,
                    };
                    refs.updateHEAD(git_path, branch_name_fb, platform_impl, allocator) catch {};
                    if (start_point_fb != null) {
                        const commit_hash_fb = refs.resolveRef(git_path, try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{branch_name_fb}), platform_impl, allocator) catch null;
                        if (commit_hash_fb) |ch| {
                            defer allocator.free(ch);
                            helpers.checkoutCommitTree(git_path, ch, allocator, platform_impl) catch {};
                        }
                    }
                    const sm = try std.fmt.allocPrint(allocator, "Switched to a new branch '{s}'\n", .{branch_name_fb});
                    defer allocator.free(sm);
                    try platform_impl.writeStderr(sm);
                    return;
                } else {
                    target = arg;
                    found_target = true;
                    break;
                }
            }
            if (!found_target) {
                if (detach) {
                    // --detach with no target means detach at helpers.HEAD
                    target = "HEAD";
                } else if (force) {
                    // -f with no other args: force checkout of current branch (reset working tree)
                    if ((try refs.resolveRef(git_path, "HEAD", platform_impl, allocator))) |head_hash| {
                        defer allocator.free(head_hash);
                        helpers.checkoutCommitTree(git_path, head_hash, allocator, platform_impl) catch {};
                    }
                    return;
                } else {
                    try platform_impl.writeStderr("error: pathspec '' did not match any file(s) known to git\n");
                    std.process.exit(128);
                }
            }
        }

        // helpers.Check for additional flags
        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
                quiet = true;
            } else if (std.mem.eql(u8, arg, "--detach")) {
                detach = true;
            }
        }

        // helpers.Handle --detach: resolve target to commit hash and write directly to helpers.HEAD
        if (detach) {
            // helpers.Resolve the target to a commit hash
            var detach_hash: ?[]const u8 = null;
            
            if (std.mem.eql(u8, target, "HEAD")) {
                // helpers.Resolve helpers.HEAD to its commit hash
                if (refs.resolveRef(git_path, "HEAD", platform_impl, allocator) catch null) |h| {
                    detach_hash = h;
                }
            } else if (target.len == 40 and helpers.isValidHash(target)) {
                detach_hash = try allocator.dupe(u8, target);
            } else {
                // helpers.Try as branch name
                const ref_path = try std.fmt.allocPrint(allocator, "{s}/refs/heads/{s}", .{ git_path, target });
                defer allocator.free(ref_path);
                if (std.fs.cwd().readFileAlloc(allocator, ref_path, 1024)) |content| {
                    defer allocator.free(content);
                    const trimmed = std.mem.trim(u8, content, " \t\n\r");
                    if (trimmed.len >= 40) {
                        detach_hash = try allocator.dupe(u8, trimmed[0..40]);
                    }
                } else |_| {
                    // helpers.Try resolving as revision expression
                    detach_hash = helpers.resolveRevision(git_path, target, platform_impl, allocator) catch null;
                }
            }
            
            if (detach_hash) |hash| {
                defer allocator.free(hash);
                // helpers.Write detached helpers.HEAD
                const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_path});
                defer allocator.free(head_path);
                const head_content = try std.fmt.allocPrint(allocator, "{s}\n", .{hash});
                defer allocator.free(head_content);
                platform_impl.fs.writeFile(head_path, head_content) catch {};
                
                if (!quiet) {
                    const det_msg = try std.fmt.allocPrint(allocator, "HEAD is now at {s}...\n", .{hash[0..7]});
                    defer allocator.free(det_msg);
                    try platform_impl.writeStderr(det_msg);
                }
                return;
            } else {
                const msg = try std.fmt.allocPrint(allocator, "fatal: not a valid object name: '{s}'\n", .{target});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(128);
            }
        }

        // helpers.Try to resolve revision expressions (like A^0, HEAD~3, etc.)
        // helpers.If the target contains special chars, resolve to a hash first
        var resolved_target = if (std.mem.indexOfAny(u8, target, "~^@") != null)
            helpers.resolveRevision(git_path, target, platform_impl, allocator) catch null
        else
            null;
        // Try resolving as remote tracking branch (e.g., origin/main -> refs/remotes/origin/main)
        if (resolved_target == null) {
            const remote_ref = std.fmt.allocPrint(allocator, "refs/remotes/{s}", .{target}) catch null;
            defer if (remote_ref) |r| allocator.free(r);
            if (remote_ref) |rr| {
                if (refs.resolveRef(git_path, rr, platform_impl, allocator) catch null) |hash| {
                    resolved_target = hash;
                }
            }
        }
        defer if (resolved_target) |rt| allocator.free(rt);
        const actual_target = resolved_target orelse target;

        // helpers.For detached helpers.HEAD (resolved hash), just update helpers.HEAD directly
        if (resolved_target != null) {
            // helpers.Get old branch name and hash for reflog before changing helpers.HEAD
            var old_branch_det: ?[]u8 = null;
            defer if (old_branch_det) |obn| allocator.free(obn);
            var old_hash_det: ?[]u8 = null;
            defer if (old_hash_det) |ohh| allocator.free(ohh);
            {
                const head_path_r = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_path});
                defer allocator.free(head_path_r);
                if (platform_impl.fs.readFile(allocator, head_path_r)) |head_data| {
                    defer allocator.free(head_data);
                    const trimmed_h = std.mem.trim(u8, head_data, " \t\r\n");
                    if (std.mem.startsWith(u8, trimmed_h, "ref: refs/heads/")) {
                        old_branch_det = try allocator.dupe(u8, trimmed_h["ref: refs/heads/".len..]);
                        const ref_p = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_path, trimmed_h["ref: ".len..] });
                        defer allocator.free(ref_p);
                        if (platform_impl.fs.readFile(allocator, ref_p)) |hash_data| {
                            defer allocator.free(hash_data);
                            old_hash_det = try allocator.dupe(u8, std.mem.trim(u8, hash_data, " \t\r\n"));
                        } else |_| {}
                    } else if (trimmed_h.len >= 40) {
                        old_hash_det = try allocator.dupe(u8, trimmed_h[0..40]);
                    }
                } else |_| {}
            }

            // helpers.This is a detached helpers.HEAD checkout
            try helpers.checkoutCommitTree(git_path, actual_target, allocator, platform_impl);
            
            // helpers.Write detached helpers.HEAD
            const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_path});
            defer allocator.free(head_path);
            const head_content = try std.fmt.allocPrint(allocator, "{s}\n", .{actual_target});
            defer allocator.free(head_content);
            platform_impl.fs.writeFile(head_path, head_content) catch {};

            // helpers.Write reflog entry
            {
                const from_det = if (old_branch_det) |obn| obn else if (old_hash_det) |ohh| ohh else "HEAD";
                const reflog_msg_det = try std.fmt.allocPrint(allocator, "checkout: moving from {s} to {s}", .{ from_det, target });
                defer allocator.free(reflog_msg_det);
                const oh_det = if (old_hash_det) |ohh| ohh else "0000000000000000000000000000000000000000";
                helpers.writeReflogEntry(git_path, "HEAD", oh_det, actual_target, reflog_msg_det, allocator, platform_impl) catch {};
            }
            
            if (!quiet) {
                const det_msg = try std.fmt.allocPrint(allocator, "Note: switching to '{s}'.\nHEAD is now at {s}\n", .{ target, actual_target[0..7] });
                defer allocator.free(det_msg);
                try platform_impl.writeStderr(det_msg);
            }
            return;
        }

        // helpers.Use native ziggit checkout
        const ziggit = @import("ziggit.zig");
        
        // helpers.Determine repository root from git_path
        const repo_root = if (std.mem.endsWith(u8, git_path, "/.git"))
            git_path[0 .. git_path.len - 5]
        else
            git_path; // bare repo
        
        var repo = ziggit.Repository.open(allocator, repo_root) catch {
            try platform_impl.writeStderr("fatal: not a git repository\n");
            std.process.exit(128);
        };
        defer repo.close();
        
        // helpers.Get current branch name before checkout for reflog
        var old_branch_name: ?[]u8 = null;
        defer if (old_branch_name) |obn| allocator.free(obn);
        var old_head_hash: ?[]u8 = null;
        defer if (old_head_hash) |ohh| allocator.free(ohh);
        {
            const head_path2 = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_path});
            defer allocator.free(head_path2);
            if (platform_impl.fs.readFile(allocator, head_path2)) |head_data| {
                defer allocator.free(head_data);
                const trimmed = std.mem.trim(u8, head_data, " \t\r\n");
                if (std.mem.startsWith(u8, trimmed, "ref: refs/heads/")) {
                    old_branch_name = try allocator.dupe(u8, trimmed["ref: refs/heads/".len..]);
                    // helpers.Resolve to hash
                    const ref_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_path, trimmed["ref: ".len..] });
                    defer allocator.free(ref_path);
                    if (platform_impl.fs.readFile(allocator, ref_path)) |hash_data| {
                        defer allocator.free(hash_data);
                        old_head_hash = try allocator.dupe(u8, std.mem.trim(u8, hash_data, " \t\r\n"));
                    } else |_| {}
                } else if (trimmed.len >= 40) {
                    old_head_hash = try allocator.dupe(u8, trimmed[0..40]);
                }
            } else |_| {}
        }

        // Check for dirty working tree files that would be overwritten
        if (!force) {
            const objects_mod = @import("git/objects.zig");
            var idx = index_mod.Index.load(git_path, platform_impl, allocator) catch index_mod.Index.init(allocator);
            defer idx.deinit();

            // Resolve target commit's tree
            const target_commit_hash = repo.findCommit(actual_target) catch null;
            const target_tree_hash: ?[]u8 = if (target_commit_hash) |ch| blk: {
                const commit_obj = objects_mod.GitObject.load(&ch, git_path, platform_impl, allocator) catch break :blk null;
                defer commit_obj.deinit(allocator);
                break :blk helpers.parseCommitTreeHash(commit_obj.data, allocator) catch null;
            } else null;
            defer if (target_tree_hash) |th| allocator.free(th);

            // Build a set of target tree paths -> hashes
            var target_blobs = std.StringHashMap([]const u8).init(allocator);
            defer {
                var vit = target_blobs.valueIterator();
                while (vit.next()) |v| allocator.free(v.*);
                var kit = target_blobs.keyIterator();
                while (kit.next()) |k| allocator.free(k.*);
                target_blobs.deinit();
            }
            if (target_tree_hash) |th| {
                helpers.collectTreeBlobs(allocator, th, "", git_path, platform_impl, &target_blobs) catch {};
            }

            const repo_root2 = if (std.mem.endsWith(u8, git_path, "/.git")) git_path[0 .. git_path.len - 5] else git_path;
            var dirty_files = std.array_list.Managed([]const u8).init(allocator);
            defer {
                for (dirty_files.items) |df| allocator.free(df);
                dirty_files.deinit();
            }

            for (idx.entries.items) |entry| {
                // Check if this file differs in target tree
                const target_hash = target_blobs.get(entry.path);
                // If file is same in current index and target tree, no conflict possible
                var entry_hash_hex: [40]u8 = undefined;
                _ = std.fmt.bufPrint(&entry_hash_hex, "{x}", .{&entry.sha1}) catch continue;
                if (target_hash) |th| {
                    if (std.mem.eql(u8, &entry_hash_hex, th)) continue;
                } else {
                    // File doesn't exist in target - deletion; check if modified
                }

                // Check if working tree file differs from index
                const full_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root2, entry.path }) catch continue;
                defer allocator.free(full_path);
                const wt_content = platform_impl.fs.readFile(allocator, full_path) catch continue;
                defer allocator.free(wt_content);
                const wt_hash = helpers.hashBlobContent(wt_content, allocator) catch continue;
                defer allocator.free(wt_hash);
                if (!std.mem.eql(u8, wt_hash, &entry_hash_hex)) {
                    dirty_files.append(allocator.dupe(u8, entry.path) catch continue) catch {};
                }
            }

            if (dirty_files.items.len > 0) {
                try platform_impl.writeStderr("error: Your local changes to the following files would be overwritten by checkout:\n");
                for (dirty_files.items) |df| {
                    const msg = try std.fmt.allocPrint(allocator, "\t{s}\n", .{df});
                    defer allocator.free(msg);
                    try platform_impl.writeStderr(msg);
                }
                try platform_impl.writeStderr("Please commit your changes or stash them before you switch branches.\nAborting\n");
                std.process.exit(1);
            }
        }

        // If actual_target is a branch name, try to resolve it via refs (handles symbolic refs)
        var resolved_checkout_target: ?[]u8 = null;
        defer if (resolved_checkout_target) |rct| allocator.free(rct);
        if (!helpers.isValidHexString(actual_target) or actual_target.len != 40) {
            // Try refs/heads/<name> first (handles symbolic refs)
            const branch_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{actual_target});
            defer allocator.free(branch_ref);
            if ((refs.resolveRef(git_path, branch_ref, platform_impl, allocator) catch null) orelse null) |hash| {
                resolved_checkout_target = hash;
            }
            // If that didn't work, try refs/tags/<name>
            if (resolved_checkout_target == null) {
                const tag_ref = try std.fmt.allocPrint(allocator, "refs/tags/{s}", .{actual_target});
                defer allocator.free(tag_ref);
                if ((refs.resolveRef(git_path, tag_ref, platform_impl, allocator) catch null) orelse null) |hash| {
                    resolved_checkout_target = hash;
                }
            }
            // Try resolveRevision as a last resort
            if (resolved_checkout_target == null) {
                resolved_checkout_target = helpers.resolveRevision(git_path, actual_target, platform_impl, allocator) catch null;
            }
        }
        const checkout_target = resolved_checkout_target orelse actual_target;

        repo.checkout(checkout_target) catch |err| {
            switch (err) {
                error.CommitNotFound => {
                    const msg = try std.fmt.allocPrint(allocator, "error: pathspec '{s}' did not match any file(s) known to git\n", .{target});
                    defer allocator.free(msg);
                    try platform_impl.writeStderr(msg);
                    std.process.exit(1);
                },
                error.RefNotFound => {
                    const msg = try std.fmt.allocPrint(allocator, "error: pathspec '{s}' did not match any file(s) known to git\n", .{target});
                    defer allocator.free(msg);
                    try platform_impl.writeStderr(msg);
                    std.process.exit(1);
                },
                error.ObjectNotFound => {
                    const msg = try std.fmt.allocPrint(allocator, "fatal: reference is not a tree: {s}\n", .{target});
                    defer allocator.free(msg);
                    try platform_impl.writeStderr(msg);
                    std.process.exit(128);
                },
                error.InvalidCommitObject, error.InvalidTreeObject => {
                    const msg = try std.fmt.allocPrint(allocator, "fatal: corrupt object for '{s}'\n", .{target});
                    defer allocator.free(msg);
                    try platform_impl.writeStderr(msg);
                    std.process.exit(128);
                },
                else => {
                    const msg = try std.fmt.allocPrint(allocator, "fatal: checkout failed: {}\n", .{err});
                    defer allocator.free(msg);
                    try platform_impl.writeStderr(msg);
                    std.process.exit(128);
                },
            }
        };

        // If we resolved the target to a hash but it was a branch name,
        // ensure HEAD points to the branch as a symbolic ref
        if (resolved_checkout_target != null and !detach) {
            // Check if refs/heads/<target> exists
            const branch_ref_check = try std.fmt.allocPrint(allocator, "{s}/refs/heads/{s}", .{ git_path, actual_target });
            defer allocator.free(branch_ref_check);
            if (std.fs.accessAbsolute(branch_ref_check, .{})) |_| {
                const head_path_fix = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_path});
                defer allocator.free(head_path_fix);
                const symbolic_ref = try std.fmt.allocPrint(allocator, "ref: refs/heads/{s}\n", .{actual_target});
                defer allocator.free(symbolic_ref);
                platform_impl.fs.writeFile(head_path_fix, symbolic_ref) catch {};
            } else |_| {}
        }
        
        // helpers.Write reflog entry for checkout
        {
            var new_head_hash: ?[]u8 = null;
            defer if (new_head_hash) |nhh| allocator.free(nhh);
            {
                const head_path3 = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_path});
                defer allocator.free(head_path3);
                if (platform_impl.fs.readFile(allocator, head_path3)) |hd| {
                    defer allocator.free(hd);
                    const tr = std.mem.trim(u8, hd, " \t\r\n");
                    if (std.mem.startsWith(u8, tr, "ref: ")) {
                        const rp = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_path, tr["ref: ".len..] });
                        defer allocator.free(rp);
                        if (platform_impl.fs.readFile(allocator, rp)) |rd| {
                            defer allocator.free(rd);
                            new_head_hash = try allocator.dupe(u8, std.mem.trim(u8, rd, " \t\r\n"));
                        } else |_| {}
                    } else if (tr.len >= 40) {
                        new_head_hash = try allocator.dupe(u8, tr[0..40]);
                    }
                } else |_| {}
            }
            const from_name = if (old_branch_name) |obn| obn else if (old_head_hash) |ohh| ohh else "HEAD";
            const reflog_msg = try std.fmt.allocPrint(allocator, "checkout: moving from {s} to {s}", .{ from_name, target });
            defer allocator.free(reflog_msg);
            const oh = if (old_head_hash) |ohh| ohh else "0000000000000000000000000000000000000000";
            const nh = if (new_head_hash) |nhh| nhh else "0000000000000000000000000000000000000000";
            helpers.writeReflogEntry(git_path, "HEAD", oh, nh, reflog_msg, allocator, platform_impl) catch {};
        }

        if (!quiet) {
            // helpers.Check if this was a branch or detached helpers.HEAD
            var ref_check_buf: [std.fs.max_path_bytes]u8 = undefined;
            const branch_ref_path = std.fmt.bufPrint(&ref_check_buf, "{s}/refs/heads/{s}", .{ repo.git_dir, target }) catch {
                return;
            };
            
            if (std.fs.accessAbsolute(branch_ref_path, .{})) |_| {
                const msg = try std.fmt.allocPrint(allocator, "Switched to branch '{s}'\n", .{target});
                defer allocator.free(msg);
                try platform_impl.writeStdout(msg);
            } else |_| {
                const msg = try std.fmt.allocPrint(allocator, "HEAD is now at {s}\n", .{target[0..@min(target.len, 7)]});
                defer allocator.free(msg);
                try platform_impl.writeStdout(msg);
            }
        }
    }
}


/// Check if working tree has dirty files that would be overwritten by checking out a target commit.
fn checkDirtyWorkingTree(
    allocator: std.mem.Allocator,
    git_path: []const u8,
    target_commit_hash: []const u8,
    platform_impl: *const platform_mod.Platform,
    dirty_files: *std.array_list.Managed([]const u8),
) !void {
    const objects_mod = @import("git/objects.zig");
    var idx = index_mod.Index.load(git_path, platform_impl, allocator) catch index_mod.Index.init(allocator);
    defer idx.deinit();

    // Get target tree
    const target_tree_hash: ?[]u8 = blk: {
        const commit_obj = objects_mod.GitObject.load(target_commit_hash, git_path, platform_impl, allocator) catch break :blk null;
        defer commit_obj.deinit(allocator);
        break :blk helpers.parseCommitTreeHash(commit_obj.data, allocator) catch null;
    };
    defer if (target_tree_hash) |th| allocator.free(th);

    // Build target tree blobs
    var target_blobs = std.StringHashMap([]const u8).init(allocator);
    defer {
        var vit = target_blobs.valueIterator();
        while (vit.next()) |v| allocator.free(v.*);
        var kit = target_blobs.keyIterator();
        while (kit.next()) |k| allocator.free(k.*);
        target_blobs.deinit();
    }
    if (target_tree_hash) |th| {
        helpers.collectTreeBlobs(allocator, th, "", git_path, platform_impl, &target_blobs) catch {};
    }

    const repo_root = if (std.mem.endsWith(u8, git_path, "/.git")) git_path[0 .. git_path.len - 5] else git_path;

    for (idx.entries.items) |entry| {
        const target_hash = target_blobs.get(entry.path);
        var entry_hash_hex: [40]u8 = undefined;
        _ = std.fmt.bufPrint(&entry_hash_hex, "{x}", .{&entry.sha1}) catch continue;
        if (target_hash) |th| {
            if (std.mem.eql(u8, &entry_hash_hex, th)) continue;
        } else {
            continue; // File will be deleted, no conflict if we just check modifications
        }

        // File differs between index and target — check if working tree also differs from index
        const full_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, entry.path }) catch continue;
        defer allocator.free(full_path);
        const wt_content = platform_impl.fs.readFile(allocator, full_path) catch continue;
        defer allocator.free(wt_content);
        const wt_hash = helpers.hashBlobContent(wt_content, allocator) catch continue;
        defer allocator.free(wt_hash);
        if (!std.mem.eql(u8, wt_hash, &entry_hash_hex)) {
            dirty_files.append(allocator.dupe(u8, entry.path) catch continue) catch {};
        }
    }
}

pub fn cmdSwitch(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    if (@import("builtin").target.os.tag == .freestanding) {
        try platform_impl.writeStderr("switch: not supported in freestanding mode\n");
        return;
    }
    
    var create_branch: ?[]const u8 = null;
    var force_create: ?[]const u8 = null;
    var detach = false;
    var orphan: ?[]const u8 = null;
    var target: ?[]const u8 = null;
    var discard_changes = false;
    
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--create")) {
            create_branch = args.next();
        } else if (std.mem.startsWith(u8, arg, "-c") and arg.len > 2 and arg[1] == 'c') {
            // helpers.This doesn't make sense, skip
        } else if (std.mem.eql(u8, arg, "-C") or std.mem.eql(u8, arg, "--force-create")) {
            force_create = args.next();
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--detach")) {
            detach = true;
        } else if (std.mem.eql(u8, arg, "--orphan")) {
            orphan = args.next();
        } else if (std.mem.eql(u8, arg, "--discard-changes") or std.mem.eql(u8, arg, "--force") or std.mem.eql(u8, arg, "-f")) {
            discard_changes = true;
        } else if (std.mem.eql(u8, arg, "--guess") or std.mem.eql(u8, arg, "--no-guess") or std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            // ignore
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (target == null) target = arg;
        }
    }

    
    const git_path = helpers.findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);
    
    if (orphan) |orphan_name| {
        // helpers.Create orphan branch
        const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_path});
        defer allocator.free(head_path);
        const ref_content = try std.fmt.allocPrint(allocator, "ref: refs/heads/{s}\n", .{orphan_name});
        defer allocator.free(ref_content);
        platform_impl.fs.writeFile(head_path, ref_content) catch {};
        // helpers.Remove index
        const index_path = try std.fmt.allocPrint(allocator, "{s}/index", .{git_path});
        defer allocator.free(index_path);
        std.fs.cwd().deleteFile(index_path) catch {};
        const msg = try std.fmt.allocPrint(allocator, "Switched to a new branch '{s}'\n", .{orphan_name});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        return;
    }
    
    if (create_branch) |branch_name| {
        refs.createBranch(git_path, branch_name, target, platform_impl, allocator) catch |err| {
            switch (err) {
                error.NoCommitsYet, error.RefNotFound, error.FileNotFound => {
                    const head_path2 = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_path});
                    defer allocator.free(head_path2);
                    const ref_content2 = try std.fmt.allocPrint(allocator, "ref: refs/heads/{s}\n", .{branch_name});
                    defer allocator.free(ref_content2);
                    platform_impl.fs.writeFile(head_path2, ref_content2) catch {};
                    const msg2 = try std.fmt.allocPrint(allocator, "Switched to a new branch '{s}'\n", .{branch_name});
                    defer allocator.free(msg2);
                    try platform_impl.writeStderr(msg2);
                    return;
                },
                else => return err,
            }
        };
        refs.updateHEAD(git_path, branch_name, platform_impl, allocator) catch {};
        const msg = try std.fmt.allocPrint(allocator, "Switched to a new branch '{s}'\n", .{branch_name});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        return;
    }
    
    if (force_create) |branch_name| {
        // helpers.Delete existing branch if it exists
        const ref_path = try std.fmt.allocPrint(allocator, "{s}/refs/heads/{s}", .{ git_path, branch_name });
        defer allocator.free(ref_path);
        std.fs.cwd().deleteFile(ref_path) catch {};
        
        refs.createBranch(git_path, branch_name, target, platform_impl, allocator) catch |err| {
            switch (err) {
                error.NoCommitsYet, error.RefNotFound, error.FileNotFound => {
                    const head_path2 = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_path});
                    defer allocator.free(head_path2);
                    const ref_content2 = try std.fmt.allocPrint(allocator, "ref: refs/heads/{s}\n", .{branch_name});
                    defer allocator.free(ref_content2);
                    platform_impl.fs.writeFile(head_path2, ref_content2) catch {};
                    const msg2 = try std.fmt.allocPrint(allocator, "Switched to a new branch '{s}'\n", .{branch_name});
                    defer allocator.free(msg2);
                    try platform_impl.writeStderr(msg2);
                    return;
                },
                else => return err,
            }
        };
        refs.updateHEAD(git_path, branch_name, platform_impl, allocator) catch {};
        const msg = try std.fmt.allocPrint(allocator, "Switched to and reset branch '{s}'\n", .{branch_name});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        return;
    }
    
    if (detach) {
        const t = target orelse {
            try platform_impl.writeStderr("fatal: missing branch or commit argument\n");
            std.process.exit(128);
        };
        const hash = helpers.resolveRevision(git_path, t, platform_impl, allocator) catch {
            const emsg = try std.fmt.allocPrint(allocator, "fatal: invalid reference: {s}\n", .{t});
            defer allocator.free(emsg);
            try platform_impl.writeStderr(emsg);
            std.process.exit(128);
        };
        defer allocator.free(hash);
        try helpers.checkoutCommitTree(git_path, hash, allocator, platform_impl);
        const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_path});
        defer allocator.free(head_path);
        const head_content = try std.fmt.allocPrint(allocator, "{s}\n", .{hash});
        defer allocator.free(head_content);
        platform_impl.fs.writeFile(head_path, head_content) catch {};
        return;
    }
    
    // Default: switch to existing branch
    if (target) |t| {
        refs.updateHEAD(git_path, t, platform_impl, allocator) catch {};
        // helpers.Checkout files
        if (refs.resolveRef(git_path, "HEAD", platform_impl, allocator) catch null) |head_hash| {
            defer allocator.free(head_hash);
            helpers.checkoutCommitTree(git_path, head_hash, allocator, platform_impl) catch {};
        }
        const msg = try std.fmt.allocPrint(allocator, "Switched to branch '{s}'\n", .{t});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
    } else {
        try platform_impl.writeStderr("fatal: missing branch or commit argument\n");
        std.process.exit(128);
    }
}


pub fn cmdRestore(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    // Basic restore command - restore working tree files
    var source: ?[]const u8 = null;
    var staged = false;
    var worktree = true;
    var paths = std.array_list.Managed([]const u8).init(allocator);
    defer paths.deinit();
    var seen_separator = false;
    
    while (args.next()) |arg| {
        if (seen_separator) {
            try paths.append(arg);
        } else if (std.mem.eql(u8, arg, "--")) {
            seen_separator = true;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--source")) {
            source = args.next();
        } else if (std.mem.startsWith(u8, arg, "--source=")) {
            source = arg["--source=".len..];
        } else if (std.mem.eql(u8, arg, "-S") or std.mem.eql(u8, arg, "--staged")) {
            staged = true;
        } else if (std.mem.eql(u8, arg, "-W") or std.mem.eql(u8, arg, "--worktree")) {
            worktree = true;
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            // quiet
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try paths.append(arg);
        }
    }



    
    if (paths.items.len == 0) {
        try platform_impl.writeStderr("fatal: you must specify path(s) to restore\n");
        std.process.exit(128);
    }
    
    const git_path = helpers.findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);
    
    // helpers.Restore files from index to working tree
    var idx = index_mod.Index.load(git_path, platform_impl, allocator) catch return;
    defer idx.deinit();

    const repo_root_r = std.fs.path.dirname(git_path) orelse ".";

    // Load CRLF conversion settings
    var attr_rules_r = crlf_mod.loadAttrRules(allocator, repo_root_r, git_path, platform_impl) catch std.array_list.Managed(check_attr.AttrRule).init(allocator);
    defer {
        for (attr_rules_r.items) |*rule| rule.deinit(allocator);
        attr_rules_r.deinit();
    }
    const autocrlf_r = helpers.getConfigValueByKey(git_path, "core.autocrlf", allocator);
    defer if (autocrlf_r) |v| allocator.free(v);
    const eol_r = helpers.getConfigValueByKey(git_path, "core.eol", allocator);
    defer if (eol_r) |v| allocator.free(v);
    
    for (paths.items) |path| {
        for (idx.entries.items) |entry| {
            if (std.mem.eql(u8, entry.path, path)) {
                // helpers.Load blob and write to working tree
                var hash_hex: [40]u8 = undefined;
                for (entry.sha1, 0..) |byte, bi| {
                    hash_hex[bi * 2] = "0123456789abcdef"[byte >> 4];
                    hash_hex[bi * 2 + 1] = "0123456789abcdef"[byte & 0xf];
                }
                const blob = objects.GitObject.load(&hash_hex, git_path, platform_impl, allocator) catch continue;
                defer blob.deinit(allocator);
                const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root_r, entry.path });
                defer allocator.free(full_path);
                // Apply CRLF conversion
                const converted_r = crlf_mod.applyCheckoutConversion(allocator, blob.data, entry.path, attr_rules_r.items, autocrlf_r, eol_r) catch blob.data;
                defer if (converted_r.ptr != blob.data.ptr) allocator.free(converted_r);
                platform_impl.fs.writeFile(full_path, converted_r) catch {};
                break;
            }
        }
    }
}


pub fn cmdCheckoutIndex(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    var force = false;
    var all = false;
    var update_stat = false;
    var prefix: ?[]const u8 = null;
    var no_create = false;
    var temp_mode = false;
    var stdin_mode = false;
    var stdin_z = false;
    var paths = std.array_list.Managed([]const u8).init(allocator);
    defer paths.deinit();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--force")) {
            force = true;
        } else if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--all")) {
            all = true;
        } else if (std.mem.eql(u8, arg, "-u")) {
            update_stat = true;
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--no-create")) {
            no_create = true;
        } else if (std.mem.eql(u8, arg, "--temp")) {
            temp_mode = true;
        } else if (std.mem.startsWith(u8, arg, "--prefix=")) {
            prefix = arg["--prefix=".len..];
        } else if (std.mem.eql(u8, arg, "--prefix")) {
            prefix = args.next();
        } else if (std.mem.startsWith(u8, arg, "--stage=")) {
            // stage selection - not fully supported yet
        } else if (std.mem.eql(u8, arg, "--stage")) {
            _ = args.next();
        } else if (std.mem.eql(u8, arg, "--stdin")) {
            stdin_mode = true;
        } else if (std.mem.eql(u8, arg, "-z")) {
            stdin_z = true;
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            // quiet mode
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try platform_impl.writeStdout("usage: git checkout-index [<options>] [--] [<file>...]\n\n    -u, --index           update stat information in the index file\n    -q, --quiet           be quiet if files exist or are not in the index\n    -f, --force           force overwrite of existing files\n    -a, --all             check out all files in the index\n    -n, --no-create       don't checkout new files\n    --temp                write the content to temporary files\n    --prefix <string>     when creating files, prepend <string>\n    --stage <number>      copy out the files from named stage\n    --stdin               read list of paths from the standard input\n    -z                    paths are separated with helpers.NUL character\n");
            std.process.exit(129);
            unreachable;
        } else if (std.mem.eql(u8, arg, "--")) {
            while (args.next()) |p| {
                try paths.append(p);
            }
        } else if (arg.len > 0 and arg[0] == '-') {
            const msg = try std.fmt.allocPrint(allocator, "error: unknown option '{s}'\nusage: git checkout-index [<options>] [--] [<file>...]\n", .{arg});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(129);
            unreachable;
        } else {
            try paths.append(arg);
        }
    }

    const git_dir = helpers.findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
        unreachable;
    };
    defer allocator.free(git_dir);

    const repo_root = std.fs.path.dirname(git_dir) orelse ".";

    var idx = index_mod.Index.load(git_dir, platform_impl, allocator) catch {
        try platform_impl.writeStderr("fatal: unable to read index\n");
        std.process.exit(128);
        unreachable;
    };
    defer idx.deinit();

    // helpers.Read core.symlinks config (default true)
    var core_symlinks = true;
    {
        var cfg = config_mod.GitConfig.init(allocator);
        defer cfg.deinit();
        const config_path = std.fmt.allocPrint(allocator, "{s}/config", .{git_dir}) catch "";
        defer if (config_path.len > 0) allocator.free(config_path);
        cfg.parseFromFile(config_path) catch {};
        if (cfg.get("core", null, "symlinks")) |val| {
            if (std.mem.eql(u8, val, "false") or std.mem.eql(u8, val, "0")) {
                core_symlinks = false;
            }
        }
    }

    // helpers.Read paths from stdin if requested
    if (stdin_mode) {
        const stdin_data = helpers.readStdin(allocator, 10 * 1024 * 1024) catch "";
        defer allocator.free(stdin_data);
        if (stdin_z) {
            var it = std.mem.splitScalar(u8, stdin_data, 0);
            while (it.next()) |p| {
                if (p.len > 0) try paths.append(try allocator.dupe(u8, p));
            }
        } else {
            var it = std.mem.splitScalar(u8, stdin_data, '\n');
            while (it.next()) |p| {
                if (p.len > 0) try paths.append(try allocator.dupe(u8, p));
            }
        }
    }

    var did_update_stat = false;
    var has_errors = false;
    var temp_counter: u32 = 0;

    for (idx.entries.items) |*entry| {
        // helpers.Skip higher stages (unmerged) unless specifically requested
        const stage = (entry.flags >> 12) & 0x3;
        if (stage != 0) continue;

        const entry_path = entry.path;

        // helpers.If not --all, check if this path is requested
        if (!all and paths.items.len > 0) {
            var found = false;
            for (paths.items) |p| {
                if (std.mem.eql(u8, p, entry_path)) {
                    found = true;
                    break;
                }
            }
            if (!found) continue;
        } else if (!all) {
            continue;
        }

        // helpers.Build output path
        const out_path = if (prefix) |pfx|
            try std.fmt.allocPrint(allocator, "{s}{s}", .{ pfx, entry_path })
        else if (repo_root.len > 0 and !std.mem.eql(u8, repo_root, "."))
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, entry_path })
        else
            try allocator.dupe(u8, entry_path);
        defer allocator.free(out_path);

        // helpers.Check if file exists and we need -f to overwrite (skip for temp mode)
        if (!force and !temp_mode) {
            if (std.fs.cwd().access(out_path, .{})) |_| {
                // File exists - report error and track failure
                const emsg = std.fmt.allocPrint(allocator, "error: {s} already exists, no checkout\n", .{entry_path}) catch "error: file already exists\n";
                platform_impl.writeStderr(emsg) catch {};
                has_errors = true;
                continue;
            } else |_| {}
        }

        if (no_create and !temp_mode) continue;

        // helpers.Load the blob content
        var hash_buf: [40]u8 = undefined;
        _ = std.fmt.bufPrint(&hash_buf, "{x}", .{&entry.sha1}) catch continue;

        const obj = objects.GitObject.load(&hash_buf, git_dir, platform_impl, allocator) catch {
            const msg = std.fmt.allocPrint(allocator, "error: unable to read sha1 file of {s} ({s})\n", .{ entry_path, &hash_buf }) catch continue;
            defer allocator.free(msg);
            platform_impl.writeStderr(msg) catch {};
            continue;
        };
        defer obj.deinit(allocator);

        const content = obj.data;

        // Temp mode: write to a temporary file and output mapping
        if (temp_mode) {
            const stage_num = (entry.flags >> 12) & 0x3;
            // helpers.Create temp file with unique name
            var temp_name_buf: [256]u8 = undefined;
            const final_name = std.fmt.bufPrint(&temp_name_buf, ".merge_file_{s}_{d}", .{ hash_buf[0..8], temp_counter }) catch continue;
            temp_counter += 1;
            const temp_file = std.fs.cwd().createFile(final_name, .{}) catch continue;
            defer temp_file.close();
            temp_file.writeAll(content) catch continue;
            // Output: tempfile\tpath
            if (stage_num == 0) {
                const tmsg = std.fmt.allocPrint(allocator, "{s}\t{s}\n", .{ final_name, entry_path }) catch continue;
                defer allocator.free(tmsg);
                platform_impl.writeStdout(tmsg) catch {};
            } else {
                // helpers.For unmerged stages, output with stage info
                const tmsg = std.fmt.allocPrint(allocator, "{s}\t{s}\n", .{ final_name, entry_path }) catch continue;
                defer allocator.free(tmsg);
                platform_impl.writeStdout(tmsg) catch {};
            }
            continue;
        }

        // helpers.When force, remove any existing file/dir that conflicts
        if (force) {
            // helpers.Remove the output path if it exists (file or dir)
            std.fs.cwd().deleteFile(out_path) catch {};
            std.fs.cwd().deleteDir(out_path) catch {};
            // helpers.For files under a dir-turned-file, remove the dir tree
            std.fs.cwd().deleteTree(out_path) catch {};
        }

        // helpers.Create parent directories
        if (std.fs.path.dirname(out_path)) |dir| {
            // helpers.If a file/symlink exists where a parent directory should be, remove it when force
            if (force) {
                // helpers.Check if any parent path component is a non-directory
                var check_path = dir;
                while (check_path.len > 0) {
                    var link_buf2: [4096]u8 = undefined;
                    if (std.fs.cwd().readLink(check_path, &link_buf2)) |_| {
                        // It's a symlink - remove it so we can create a dir
                        std.fs.cwd().deleteFile(check_path) catch {};
                        break;
                    } else |_| {
                        if (std.fs.cwd().statFile(check_path)) |st| {
                            if (st.kind != .directory) {
                                std.fs.cwd().deleteFile(check_path) catch {};
                                break;
                            } else break; // It's already a directory, good
                        } else |_| break; // Doesn't exist, makePath will create it
                    }
                    check_path = std.fs.path.dirname(check_path) orelse break;
                }
            }
            std.fs.cwd().makePath(dir) catch {};
        }

        const is_symlink = (entry.mode & 0o170000) == 0o120000;
        const is_executable = (entry.mode & 0o100) != 0;

        if (is_symlink and core_symlinks) {
            // helpers.Remove existing file/symlink first
            std.fs.cwd().deleteFile(out_path) catch {};
            std.fs.cwd().symLink(content, out_path, .{}) catch |err| {
                const msg = std.fmt.allocPrint(allocator, "error: unable to create symlink {s}: {}\n", .{ entry_path, err }) catch continue;
                defer allocator.free(msg);
                platform_impl.writeStderr(msg) catch {};
                continue;
            };
        } else {
            // helpers.Write regular file
            const file = std.fs.cwd().createFile(out_path, .{}) catch |err| {
                const msg = std.fmt.allocPrint(allocator, "error: unable to create file {s}: {}\n", .{ entry_path, err }) catch continue;
                defer allocator.free(msg);
                platform_impl.writeStderr(msg) catch {};
                continue;
            };
            defer file.close();
            file.writeAll(content) catch continue;

            if (is_executable) {
                const st = file.stat() catch continue;
                const new_mode = st.mode | 0o111;
                std.posix.fchmod(file.handle, new_mode) catch {};
            }
        }

        // helpers.Update stat info in index if -u flag
        if (update_stat) {
            if (std.fs.cwd().statFile(out_path)) |stat_result| {
                const mtime_s: u32 = @intCast(@max(0, @divTrunc(stat_result.mtime, std.time.ns_per_s)));
                const mtime_ns: u32 = @intCast(@max(0, @rem(stat_result.mtime, std.time.ns_per_s)));
                const ctime_s: u32 = @intCast(@max(0, @divTrunc(stat_result.ctime, std.time.ns_per_s)));
                const ctime_ns: u32 = @intCast(@max(0, @rem(stat_result.ctime, std.time.ns_per_s)));
                entry.mtime_sec = mtime_s;
                entry.mtime_nsec = mtime_ns;
                entry.ctime_sec = ctime_s;
                entry.ctime_nsec = ctime_ns;
                entry.size = @intCast(@min(stat_result.size, std.math.maxInt(u32)));
                entry.ino = @intCast(stat_result.inode);
                entry.dev = 0;
                did_update_stat = true;
            } else |_| {}
        }
    }

    // helpers.Save index if stat info was updated
    // helpers.Check that all explicitly requested paths were found in the index
    if (!all and paths.items.len > 0) {
        for (paths.items) |p| {
            var found = false;
            for (idx.entries.items) |entry| {
                if (std.mem.eql(u8, entry.path, p)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                const emsg2 = std.fmt.allocPrint(allocator, "git checkout-index: {s} is not in the cache\n", .{p}) catch continue;
                defer allocator.free(emsg2);
                platform_impl.writeStderr(emsg2) catch {};
                has_errors = true;
            }
        }
    }

    if (did_update_stat) {
        idx.save(git_dir, platform_impl) catch {};
    }

    if (has_errors) {
        std.process.exit(1);
    }
}

// === T5 agent functions ===

pub fn cmdWorktree(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    const subcmd = args.next() orelse {
        try platform_impl.writeStderr("usage: git worktree add <path> [<branch>]\n       git worktree list\n       git worktree remove <path>\n");
        std.process.exit(129);
    };
    _ = allocator;
    
    if (std.mem.eql(u8, subcmd, "add") or std.mem.eql(u8, subcmd, "list") or 
        std.mem.eql(u8, subcmd, "remove") or std.mem.eql(u8, subcmd, "prune") or
        std.mem.eql(u8, subcmd, "lock") or std.mem.eql(u8, subcmd, "unlock") or
        std.mem.eql(u8, subcmd, "move") or std.mem.eql(u8, subcmd, "repair")) {
        try platform_impl.writeStderr("fatal: worktree command not yet implemented in ziggit\n");
        std.process.exit(128);
    } else {
        try platform_impl.writeStderr("fatal: unknown worktree subcommand\n");
        std.process.exit(129);
    }
}
