// Worktree command implementation
// Agents: this file is yours to edit for worktree commands.

const std = @import("std");
const platform_mod = @import("platform/platform.zig");
const helpers = @import("git_helpers.zig");
const objects = helpers.objects;
const index_mod = helpers.index_mod;
const refs = helpers.refs;

const worktree_usage = "usage: git worktree add [-f] [--detach] [--checkout] [--lock [--reason <string>]]\n                       [--orphan] [-b <new-branch>] <path> [<commit-ish>]\n   or: git worktree list [-v | --porcelain [-z]]\n   or: git worktree lock [--reason <string>] <worktree>\n   or: git worktree move <worktree> <new-path>\n   or: git worktree prune [-n] [-v] [--expire <expire>]\n   or: git worktree remove [-f] <worktree>\n   or: git worktree repair [<path>...]\n   or: git worktree unlock <worktree>\n";

pub fn cmdWorktree(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    const subcmd = args.next() orelse {
        try platform_impl.writeStderr(worktree_usage);
        std.process.exit(129);
    };

    if (std.mem.eql(u8, subcmd, "-h")) {
        try platform_impl.writeStdout(worktree_usage);
        std.process.exit(129);
    }

    const git_path = helpers.findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);

    // Resolve to the common git dir (for linked worktrees)
    const common_dir = getCommonDir(allocator, git_path) catch try allocator.dupe(u8, git_path);
    defer allocator.free(common_dir);

    if (std.mem.eql(u8, subcmd, "add")) {
        try worktreeAdd(allocator, args, common_dir, platform_impl);
    } else if (std.mem.eql(u8, subcmd, "list")) {
        try worktreeList(allocator, args, common_dir, platform_impl);
    } else if (std.mem.eql(u8, subcmd, "remove")) {
        try worktreeRemove(allocator, args, common_dir, platform_impl);
    } else if (std.mem.eql(u8, subcmd, "prune")) {
        try worktreePrune(allocator, args, common_dir, platform_impl);
    } else if (std.mem.eql(u8, subcmd, "lock")) {
        try worktreeLock(allocator, args, common_dir, platform_impl);
    } else if (std.mem.eql(u8, subcmd, "unlock")) {
        try worktreeUnlock(allocator, args, common_dir, platform_impl);
    } else if (std.mem.eql(u8, subcmd, "move")) {
        try platform_impl.writeStderr("fatal: 'move' is not implemented yet\n");
        std.process.exit(128);
    } else if (std.mem.eql(u8, subcmd, "repair")) {
        // repair is a no-op for now
    } else {
        const msg = try std.fmt.allocPrint(allocator, "fatal: '{s}' is not a valid worktree subcommand\n", .{subcmd});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        std.process.exit(129);
    }
}

fn getCommonDir(allocator: std.mem.Allocator, git_path: []const u8) ![]u8 {
    const commondir_path = try std.fmt.allocPrint(allocator, "{s}/commondir", .{git_path});
    defer allocator.free(commondir_path);
    const content = std.fs.cwd().readFileAlloc(allocator, commondir_path, 4096) catch return try allocator.dupe(u8, git_path);
    defer allocator.free(content);
    const trimmed = std.mem.trimRight(u8, content, "\n\r \t");
    if (std.fs.path.isAbsolute(trimmed)) {
        return try allocator.dupe(u8, trimmed);
    }
    // Relative to git_path
    const result = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_path, trimmed });
    return result;
}

fn getRepoRoot(allocator: std.mem.Allocator, git_path: []const u8) ![]u8 {
    if (std.fs.path.dirname(git_path)) |parent| {
        return try allocator.dupe(u8, parent);
    }
    return try allocator.dupe(u8, ".");
}

// ============= worktree add =============

fn worktreeAdd(
    allocator: std.mem.Allocator,
    args: *platform_mod.ArgIterator,
    common_dir: []const u8,
    platform_impl: *const platform_mod.Platform,
) !void {
    var wt_path: ?[]const u8 = null;
    var branch: ?[]const u8 = null;
    var new_branch: ?[]const u8 = null;
    var detach = false;
    var force = false;
    var no_checkout = false;
    var do_lock = false;
    var lock_reason: ?[]const u8 = null;
    var orphan_branch: ?[]const u8 = null;
    var after_dashdash = false;

    while (args.next()) |arg| {
        if (after_dashdash) {
            if (wt_path == null) {
                wt_path = arg;
            } else if (branch == null) {
                branch = arg;
            }
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            after_dashdash = true;
        } else if (std.mem.eql(u8, arg, "-b") or std.mem.eql(u8, arg, "-B")) {
            new_branch = args.next();
        } else if (std.mem.eql(u8, arg, "--detach")) {
            detach = true;
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--force")) {
            force = true;
        } else if (std.mem.eql(u8, arg, "--no-checkout")) {
            no_checkout = true;
        } else if (std.mem.eql(u8, arg, "--checkout")) {
            no_checkout = false;
        } else if (std.mem.eql(u8, arg, "--orphan")) {
            orphan_branch = args.next();
        } else if (std.mem.eql(u8, arg, "--lock")) {
            do_lock = true;
        } else if (std.mem.eql(u8, arg, "--reason")) {
            lock_reason = args.next();
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            // quiet
        } else if (std.mem.eql(u8, arg, "--track") or std.mem.eql(u8, arg, "--no-track")) {
            // tracking options
        } else if (std.mem.eql(u8, arg, "--guess-remote") or std.mem.eql(u8, arg, "--no-guess-remote")) {
            // guess remote options
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (wt_path == null) {
                wt_path = arg;
            } else if (branch == null) {
                branch = arg;
            }
        }
    }

    const path = wt_path orelse {
        try platform_impl.writeStderr("fatal: must specify path for 'worktree add'\n");
        std.process.exit(128);
    };

    // Resolve the absolute path
    const abs_path = std.fs.cwd().realpathAlloc(allocator, ".") catch try allocator.dupe(u8, ".");
    defer allocator.free(abs_path);
    const full_wt_path = if (std.fs.path.isAbsolute(path))
        try allocator.dupe(u8, path)
    else
        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ abs_path, path });
    defer allocator.free(full_wt_path);

    // Determine the worktree name (basename of path)
    const wt_name = std.fs.path.basename(full_wt_path);

    // Determine branch to checkout
    var target_branch: ?[]const u8 = null;
    var create_branch = false;

    if (orphan_branch) |ob| {
        target_branch = ob;
        create_branch = false; // will be handled specially
    } else if (new_branch) |nb| {
        target_branch = nb;
        create_branch = true;
    } else if (branch) |b| {
        target_branch = b;
    } else if (!detach) {
        // Default: create a new branch with the same name as the worktree dir
        target_branch = wt_name;
        // Check if branch already exists
        const ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{wt_name});
        defer allocator.free(ref);
        if (refs.resolveRef(common_dir, ref, platform_impl, allocator) catch null) |h| {
            allocator.free(h);
            // Branch exists, use it
            create_branch = false;
        } else {
            create_branch = true;
        }
    }

    // Get the commit hash to checkout
    var commit_hash: []u8 = undefined;
    if (target_branch) |tb| {
        if (create_branch or orphan_branch != null) {
            // Create branch at HEAD
            commit_hash = refs.resolveRef(common_dir, "HEAD", platform_impl, allocator) catch {
                try platform_impl.writeStderr("fatal: not a valid object name: 'HEAD'\n");
                std.process.exit(128);
            } orelse {
                try platform_impl.writeStderr("fatal: not a valid object name: 'HEAD'\n");
                std.process.exit(128);
            };
            if (orphan_branch == null) {
                // Create the branch
                const branch_ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{tb});
                defer allocator.free(branch_ref);
                refs.updateRef(common_dir, branch_ref, commit_hash, platform_impl, allocator) catch {
                    try platform_impl.writeStderr("fatal: could not create branch\n");
                    std.process.exit(128);
                };
            }
        } else {
            // Resolve existing branch/committish
            const resolved = helpers.resolveCommittish(common_dir, tb, platform_impl, allocator) catch {
                const msg = try std.fmt.allocPrint(allocator, "fatal: invalid reference: {s}\n", .{tb});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(128);
            };
            commit_hash = resolved;
        }
    } else {
        // Detached HEAD at current HEAD
        commit_hash = refs.resolveRef(common_dir, "HEAD", platform_impl, allocator) catch {
            try platform_impl.writeStderr("fatal: not a valid object name: 'HEAD'\n");
            std.process.exit(128);
        } orelse {
            try platform_impl.writeStderr("fatal: not a valid object name: 'HEAD'\n");
            std.process.exit(128);
        };
    }
    defer allocator.free(commit_hash);

    // Check if the branch is already checked out in another worktree
    if (target_branch != null and !detach and !force) {
        const tb = target_branch.?;
        // Check main worktree HEAD
        const main_branch = getCurrentBranch(allocator, common_dir, platform_impl) catch null;
        defer if (main_branch) |b| allocator.free(b);
        if (main_branch) |mb| {
            if (std.mem.eql(u8, mb, tb)) {
                const msg = try std.fmt.allocPrint(allocator, "fatal: '{s}' is already checked out at '{s}'\n", .{ tb, std.fs.path.dirname(common_dir) orelse "." });
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(128);
            }
        }
        // Check linked worktrees
        const wt_dir_path = try std.fmt.allocPrint(allocator, "{s}/worktrees", .{common_dir});
        defer allocator.free(wt_dir_path);
        if (std.fs.cwd().openDir(wt_dir_path, .{ .iterate = true })) |*dp| {
            var ddir = dp.*;
            defer ddir.close();
            var wit = ddir.iterate();
            while (try wit.next()) |we| {
                if (we.kind != .directory) continue;
                const wt_head_path = try std.fmt.allocPrint(allocator, "{s}/{s}/HEAD", .{ wt_dir_path, we.name });
                defer allocator.free(wt_head_path);
                const wt_head = std.fs.cwd().readFileAlloc(allocator, wt_head_path, 4096) catch continue;
                defer allocator.free(wt_head);
                const wt_head_trim = std.mem.trimRight(u8, wt_head, "\n\r \t");
                if (std.mem.startsWith(u8, wt_head_trim, "ref: refs/heads/")) {
                    if (std.mem.eql(u8, wt_head_trim["ref: refs/heads/".len..], tb)) {
                        // Read gitdir to get the worktree path
                        const gd_path = try std.fmt.allocPrint(allocator, "{s}/{s}/gitdir", .{ wt_dir_path, we.name });
                        defer allocator.free(gd_path);
                        const gd_content = std.fs.cwd().readFileAlloc(allocator, gd_path, 4096) catch continue;
                        defer allocator.free(gd_content);
                        const gd = std.mem.trimRight(u8, gd_content, "\n\r \t");
                        const wt_root = if (std.mem.endsWith(u8, gd, "/.git")) gd[0 .. gd.len - 5] else gd;
                        const msg = try std.fmt.allocPrint(allocator, "fatal: '{s}' is already checked out at '{s}'\n", .{ tb, wt_root });
                        defer allocator.free(msg);
                        try platform_impl.writeStderr(msg);
                        std.process.exit(128);
                    }
                }
            }
        } else |_| {}
    }

    // Check if path already exists
    if (!force) {
        if (std.fs.cwd().access(full_wt_path, .{})) {
            // Check if it's an empty directory (OK to use)
            var is_empty_dir = false;
            if (std.fs.cwd().openDir(full_wt_path, .{ .iterate = true })) |*d| {
                var dir = d.*;
                defer dir.close();
                var iter = dir.iterate();
                is_empty_dir = true;
                while (iter.next() catch null) |_| {
                    is_empty_dir = false;
                    break;
                }
            } else |_| {}
            if (!is_empty_dir) {
                const msg = try std.fmt.allocPrint(allocator, "fatal: '{s}' already exists\n", .{path});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(128);
            }
        } else |_| {}
    }

    // Create the worktree directory
    std.fs.cwd().makePath(full_wt_path) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "fatal: could not create directory '{s}': {}\n", .{ path, err });
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        std.process.exit(128);
    };

    // Create .git/worktrees/<name>/ directory
    const wt_admin_dir = try std.fmt.allocPrint(allocator, "{s}/worktrees/{s}", .{ common_dir, wt_name });
    defer allocator.free(wt_admin_dir);
    std.fs.cwd().makePath(wt_admin_dir) catch {};

    // Write .git/worktrees/<name>/gitdir
    const gitdir_file_path = try std.fmt.allocPrint(allocator, "{s}/gitdir", .{wt_admin_dir});
    defer allocator.free(gitdir_file_path);
    const wt_git_path = try std.fmt.allocPrint(allocator, "{s}/.git\n", .{full_wt_path});
    defer allocator.free(wt_git_path);
    try writeFileContent(gitdir_file_path, wt_git_path);

    // Write .git/worktrees/<name>/commondir
    const commondir_file = try std.fmt.allocPrint(allocator, "{s}/commondir", .{wt_admin_dir});
    defer allocator.free(commondir_file);
    try writeFileContent(commondir_file, "../..\n");

    // Create symlinks for shared directories so object loading works
    const shared_dirs = [_][]const u8{ "objects", "refs", "packed-refs", "info" };
    for (shared_dirs) |shared| {
        const dst = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ wt_admin_dir, shared });
        defer allocator.free(dst);
        const rel_src = try std.fmt.allocPrint(allocator, "../../{s}", .{shared});
        defer allocator.free(rel_src);
        std.posix.symlinkat(rel_src, std.fs.cwd().fd, dst) catch {};
    }

    // Write .git/worktrees/<name>/HEAD
    const head_file = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{wt_admin_dir});
    defer allocator.free(head_file);
    if (detach or orphan_branch != null) {
        const head_content = try std.fmt.allocPrint(allocator, "{s}\n", .{commit_hash});
        defer allocator.free(head_content);
        try writeFileContent(head_file, head_content);
    } else if (target_branch) |tb| {
        const head_content = try std.fmt.allocPrint(allocator, "ref: refs/heads/{s}\n", .{tb});
        defer allocator.free(head_content);
        try writeFileContent(head_file, head_content);
    }

    // Write <worktree>/.git file (not directory)
    const wt_dot_git = try std.fmt.allocPrint(allocator, "{s}/.git", .{full_wt_path});
    defer allocator.free(wt_dot_git);
    const gitdir_content = try std.fmt.allocPrint(allocator, "gitdir: {s}\n", .{wt_admin_dir});
    defer allocator.free(gitdir_content);
    try writeFileContent(wt_dot_git, gitdir_content);

    // Checkout the tree if not --no-checkout and not orphan
    if (!no_checkout and orphan_branch == null) {
        // Load objects from common_dir, checkout to full_wt_path
        const tree_hash = helpers.getCommitTree(common_dir, commit_hash, allocator, platform_impl) catch null;
        if (tree_hash) |th| {
            defer allocator.free(th);
            const tree_obj = objects.GitObject.load(th, common_dir, platform_impl, allocator) catch null;
            if (tree_obj) |to| {
                defer to.deinit(allocator);
                // Checkout files to worktree path
                helpers.checkoutTreeRecursive(common_dir, to.data, full_wt_path, "", allocator, platform_impl) catch {};
                // Build and save index for the worktree
                var wt_index = index_mod.Index.init(allocator);
                defer wt_index.deinit();
                helpers.populateIndexFromTree(common_dir, to.data, full_wt_path, "", &wt_index, allocator, platform_impl) catch {};
                wt_index.save(wt_admin_dir, platform_impl) catch {};
            }
        }
    }

    // Create lock file if --lock was specified
    if (do_lock) {
        const lock_path = try std.fmt.allocPrint(allocator, "{s}/locked", .{wt_admin_dir});
        defer allocator.free(lock_path);
        try writeFileContent(lock_path, lock_reason orelse "");
    }

    // Print output
    // Get subject line from commit
    const subject = getCommitSubject(allocator, common_dir, commit_hash) catch try allocator.dupe(u8, "");
    defer allocator.free(subject);

    if (detach) {
        const msg = try std.fmt.allocPrint(allocator, "Preparing worktree (detached HEAD {s})\nHEAD is now at {s} {s}\n", .{
            commit_hash[0..7], commit_hash[0..7], subject,
        });
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
    } else if (create_branch) {
        const msg = try std.fmt.allocPrint(allocator, "Preparing worktree (new branch '{s}')\nHEAD is now at {s} {s}\n", .{
            target_branch orelse wt_name, commit_hash[0..7], subject,
        });
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
    } else if (orphan_branch != null) {
        const msg = try std.fmt.allocPrint(allocator, "Preparing worktree (new branch '{s}')\n", .{
            orphan_branch.?,
        });
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
    } else {
        const msg = try std.fmt.allocPrint(allocator, "Preparing worktree (checking out '{s}')\nHEAD is now at {s} {s}\n", .{
            target_branch orelse commit_hash[0..7], commit_hash[0..7], subject,
        });
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
    }
}

fn getCommitSubject(allocator: std.mem.Allocator, git_path: []const u8, commit_hash: []const u8) ![]u8 {
    const data = try helpers.readGitObjectContent(git_path, commit_hash, allocator);
    defer allocator.free(data);
    if (std.mem.indexOf(u8, data, "\n\n")) |pos| {
        const msg_start = data[pos + 2 ..];
        const end = std.mem.indexOfScalar(u8, msg_start, '\n') orelse msg_start.len;
        return try allocator.dupe(u8, msg_start[0..end]);
    }
    return try allocator.dupe(u8, "");
}

fn writeFileContent(path: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        std.fs.cwd().makePath(parent) catch {};
    }
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(content);
}

// ============= worktree list =============

fn worktreeList(
    allocator: std.mem.Allocator,
    args: *platform_mod.ArgIterator,
    common_dir: []const u8,
    platform_impl: *const platform_mod.Platform,
) !void {
    var porcelain = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--porcelain")) {
            porcelain = true;
        }
    }

    // Main worktree
    const main_root = std.fs.path.dirname(common_dir) orelse ".";
    const main_abs = std.fs.cwd().realpathAlloc(allocator, main_root) catch try allocator.dupe(u8, main_root);
    defer allocator.free(main_abs);

    const main_head = refs.resolveRef(common_dir, "HEAD", platform_impl, allocator) catch null;
    defer if (main_head) |h| allocator.free(h) else {};
    const main_branch = getCurrentBranch(allocator, common_dir, platform_impl) catch null;
    defer if (main_branch) |b| allocator.free(b);

    if (porcelain) {
        try platform_impl.writeStdout("worktree ");
        try platform_impl.writeStdout(main_abs);
        try platform_impl.writeStdout("\n");
        if (main_head) |h| {
            try platform_impl.writeStdout("HEAD ");
            try platform_impl.writeStdout(h);
            try platform_impl.writeStdout("\n");
        }
        if (main_branch) |b| {
            const ref = try std.fmt.allocPrint(allocator, "branch refs/heads/{s}\n", .{b});
            defer allocator.free(ref);
            try platform_impl.writeStdout(ref);
        } else {
            try platform_impl.writeStdout("detached\n");
        }
        try platform_impl.writeStdout("\n");
    } else {
        const head_short = if (main_head) |h| h[0..@min(h.len, 7)] else "0000000";
        const branch_info = if (main_branch) |b|
            try std.fmt.allocPrint(allocator, "[{s}]", .{b})
        else
            try allocator.dupe(u8, "(detached HEAD)");
        defer allocator.free(branch_info);
        const line = try std.fmt.allocPrint(allocator, "{s}  {s} {s}\n", .{ main_abs, head_short, branch_info });
        defer allocator.free(line);
        try platform_impl.writeStdout(line);
    }

    // Linked worktrees
    const worktrees_dir = try std.fmt.allocPrint(allocator, "{s}/worktrees", .{common_dir});
    defer allocator.free(worktrees_dir);
    var dir = std.fs.cwd().openDir(worktrees_dir, .{ .iterate = true }) catch return;
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;
        const wt_admin = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ worktrees_dir, entry.name });
        defer allocator.free(wt_admin);

        // Read gitdir to get worktree path
        const gitdir_path = try std.fmt.allocPrint(allocator, "{s}/gitdir", .{wt_admin});
        defer allocator.free(gitdir_path);
        const gitdir_content = std.fs.cwd().readFileAlloc(allocator, gitdir_path, 4096) catch continue;
        defer allocator.free(gitdir_content);
        const wt_git = std.mem.trimRight(u8, gitdir_content, "\n\r \t");
        // wt_git is like /path/to/worktree/.git, strip /.git
        const wt_root = if (std.mem.endsWith(u8, wt_git, "/.git"))
            wt_git[0 .. wt_git.len - 5]
        else
            wt_git;

        const wt_abs = std.fs.cwd().realpathAlloc(allocator, wt_root) catch try allocator.dupe(u8, wt_root);
        defer allocator.free(wt_abs);

        // Read HEAD
        const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{wt_admin});
        defer allocator.free(head_path);
        const head_content = std.fs.cwd().readFileAlloc(allocator, head_path, 4096) catch null;
        defer if (head_content) |hc| allocator.free(hc);
        const head_trimmed = if (head_content) |hc| std.mem.trimRight(u8, hc, "\n\r \t") else null;

        var wt_branch: ?[]const u8 = null;
        var wt_head_hash: ?[]const u8 = null;
        if (head_trimmed) |ht| {
            if (std.mem.startsWith(u8, ht, "ref: refs/heads/")) {
                wt_branch = ht["ref: refs/heads/".len..];
                // Resolve the ref
                const ref_name = ht["ref: ".len..];
                wt_head_hash = refs.resolveRef(common_dir, ref_name, platform_impl, allocator) catch null;
            } else if (ht.len == 40) {
                wt_head_hash = ht;
            }
        }
        defer if (wt_head_hash != null and wt_branch == null) {} else if (wt_head_hash) |h| {
            // Only free if we allocated it (from resolveRef)
            if (wt_branch != null) allocator.free(h);
        };

        // Check if locked
        const lock_path = try std.fmt.allocPrint(allocator, "{s}/locked", .{wt_admin});
        defer allocator.free(lock_path);
        const is_locked = if (std.fs.cwd().access(lock_path, .{})) true else |_| false;

        // Check if prunable (gitdir target doesn't exist)
        _ = std.fs.cwd().access(wt_git, .{}) catch {};

        if (porcelain) {
            try platform_impl.writeStdout("worktree ");
            try platform_impl.writeStdout(wt_abs);
            try platform_impl.writeStdout("\n");
            if (wt_head_hash) |h| {
                try platform_impl.writeStdout("HEAD ");
                try platform_impl.writeStdout(h);
                try platform_impl.writeStdout("\n");
            }
            if (wt_branch) |b| {
                const ref = try std.fmt.allocPrint(allocator, "branch refs/heads/{s}\n", .{b});
                defer allocator.free(ref);
                try platform_impl.writeStdout(ref);
            } else {
                try platform_impl.writeStdout("detached\n");
            }
            if (is_locked) try platform_impl.writeStdout("locked\n");
            try platform_impl.writeStdout("\n");
        } else {
            const head_short = if (wt_head_hash) |h| h[0..@min(h.len, 7)] else "0000000";
            const branch_info = if (wt_branch) |b|
                try std.fmt.allocPrint(allocator, "[{s}]", .{b})
            else
                try allocator.dupe(u8, "(detached HEAD)");
            defer allocator.free(branch_info);
            const line = try std.fmt.allocPrint(allocator, "{s}  {s} {s}", .{ wt_abs, head_short, branch_info });
            defer allocator.free(line);
            try platform_impl.writeStdout(line);
            if (is_locked) try platform_impl.writeStdout(" locked");
            try platform_impl.writeStdout("\n");
        }
    }
}

fn getCurrentBranch(allocator: std.mem.Allocator, git_path: []const u8, platform_impl: *const platform_mod.Platform) ![]u8 {
    _ = platform_impl;
    const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_path});
    defer allocator.free(head_path);
    const content = std.fs.cwd().readFileAlloc(allocator, head_path, 4096) catch return error.NoHead;
    defer allocator.free(content);
    const trimmed = std.mem.trimRight(u8, content, "\n\r ");
    if (std.mem.startsWith(u8, trimmed, "ref: refs/heads/")) {
        return try allocator.dupe(u8, trimmed["ref: refs/heads/".len..]);
    }
    return error.DetachedHead;
}

// ============= worktree remove =============

fn worktreeRemove(
    allocator: std.mem.Allocator,
    args: *platform_mod.ArgIterator,
    common_dir: []const u8,
    platform_impl: *const platform_mod.Platform,
) !void {
    var force = false;
    var wt_name: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--force")) {
            force = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            wt_name = arg;
        }
    }
    const name = wt_name orelse {
        try platform_impl.writeStderr("fatal: must specify worktree to remove\n");
        std.process.exit(128);
    };

    // Find the worktree admin dir
    const basename = std.fs.path.basename(name);
    const wt_admin = try std.fmt.allocPrint(allocator, "{s}/worktrees/{s}", .{ common_dir, basename });
    defer allocator.free(wt_admin);

    // Read gitdir to get worktree path
    const gitdir_path = try std.fmt.allocPrint(allocator, "{s}/gitdir", .{wt_admin});
    defer allocator.free(gitdir_path);
    const gitdir_content = std.fs.cwd().readFileAlloc(allocator, gitdir_path, 4096) catch {
        const msg = try std.fmt.allocPrint(allocator, "fatal: '{s}' is not a working tree\n", .{name});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        std.process.exit(128);
    };
    defer allocator.free(gitdir_content);
    const wt_git = std.mem.trimRight(u8, gitdir_content, "\n\r \t");
    const wt_root = if (std.mem.endsWith(u8, wt_git, "/.git"))
        wt_git[0 .. wt_git.len - 5]
    else
        wt_git;

    // Remove the worktree directory
    std.fs.cwd().deleteTree(wt_root) catch {};

    // Remove the admin directory
    std.fs.cwd().deleteTree(wt_admin) catch {};
}

// ============= worktree prune =============

fn worktreePrune(
    allocator: std.mem.Allocator,
    args: *platform_mod.ArgIterator,
    common_dir: []const u8,
    platform_impl: *const platform_mod.Platform,
) !void {
    var verbose = false;
    var dry_run = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        }
    }

    const worktrees_dir = try std.fmt.allocPrint(allocator, "{s}/worktrees", .{common_dir});
    defer allocator.free(worktrees_dir);
    var dir = std.fs.cwd().openDir(worktrees_dir, .{ .iterate = true }) catch return;
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;
        const wt_admin = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ worktrees_dir, entry.name });
        defer allocator.free(wt_admin);

        // Check if gitdir target exists
        const gitdir_path = try std.fmt.allocPrint(allocator, "{s}/gitdir", .{wt_admin});
        defer allocator.free(gitdir_path);
        const gitdir_content = std.fs.cwd().readFileAlloc(allocator, gitdir_path, 4096) catch {
            // No gitdir file - prune it
            if (!dry_run) std.fs.cwd().deleteTree(wt_admin) catch {};
            if (verbose) {
                const msg = try std.fmt.allocPrint(allocator, "Removing worktrees/{s}: gitdir file points to non-existent location\n", .{entry.name});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
            }
            continue;
        };
        defer allocator.free(gitdir_content);

        const wt_git = std.mem.trimRight(u8, gitdir_content, "\n\r \t");
        if (std.fs.cwd().access(wt_git, .{})) {} else |_| {
            // Target doesn't exist - prune
            if (!dry_run) std.fs.cwd().deleteTree(wt_admin) catch {};
            if (verbose) {
                const msg = try std.fmt.allocPrint(allocator, "Removing worktrees/{s}: gitdir file points to non-existent location\n", .{entry.name});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
            }
        }
    }
}

// ============= worktree lock/unlock =============

fn worktreeLock(
    allocator: std.mem.Allocator,
    args: *platform_mod.ArgIterator,
    common_dir: []const u8,
    platform_impl: *const platform_mod.Platform,
) !void {
    var reason: ?[]const u8 = null;
    var wt_name: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--reason")) {
            reason = args.next();
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            wt_name = arg;
        }
    }

    const name = wt_name orelse {
        try platform_impl.writeStderr("fatal: must specify worktree to lock\n");
        std.process.exit(128);
    };

    const basename = std.fs.path.basename(name);
    const lock_path = try std.fmt.allocPrint(allocator, "{s}/worktrees/{s}/locked", .{ common_dir, basename });
    defer allocator.free(lock_path);

    if (std.fs.cwd().access(lock_path, .{})) {
        const msg = try std.fmt.allocPrint(allocator, "fatal: '{s}' is already locked\n", .{name});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        std.process.exit(128);
    } else |_| {}

    try writeFileContent(lock_path, reason orelse "");
}

fn worktreeUnlock(
    allocator: std.mem.Allocator,
    args: *platform_mod.ArgIterator,
    common_dir: []const u8,
    platform_impl: *const platform_mod.Platform,
) !void {
    var wt_name: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (!std.mem.startsWith(u8, arg, "-")) {
            wt_name = arg;
        }
    }

    const name = wt_name orelse {
        try platform_impl.writeStderr("fatal: must specify worktree to unlock\n");
        std.process.exit(128);
    };

    const basename = std.fs.path.basename(name);
    const lock_path = try std.fmt.allocPrint(allocator, "{s}/worktrees/{s}/locked", .{ common_dir, basename });
    defer allocator.free(lock_path);

    std.fs.cwd().deleteFile(lock_path) catch {
        const msg = try std.fmt.allocPrint(allocator, "fatal: '{s}' is not locked\n", .{name});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        std.process.exit(128);
    };
}
