const std = @import("std");
const platform_mod = @import("platform/platform.zig");

fn printErr(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.allocPrint(allocator, fmt, args) catch return;
    defer allocator.free(msg);
    const f = std.fs.File{ .handle = std.posix.STDERR_FILENO };
    f.writeAll(msg) catch {};
}

const RunError = error{
    SubcommandFailed,
    OutOfMemory,
    SelfExeNotFound,
};

fn runSubcommand(allocator: std.mem.Allocator, args: []const []const u8) RunError!void {
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const self_exe = std.fs.selfExePath(&exe_buf) catch return RunError.SelfExeNotFound;

    // Build argv: [self_exe] ++ args
    const argv_list = allocator.alloc([]const u8, args.len + 1) catch return RunError.OutOfMemory;
    defer allocator.free(argv_list);
    argv_list[0] = self_exe;
    for (args, 0..) |a, i| {
        argv_list[i + 1] = a;
    }

    var child = std.process.Child.init(argv_list, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    const term = child.spawnAndWait() catch return RunError.SubcommandFailed;
    switch (term) {
        .Exited => |code| {
            if (code != 0) return RunError.SubcommandFailed;
        },
        else => return RunError.SubcommandFailed,
    }
}

/// Run a subcommand capturing stdout. Returns true if it produced output.
/// On non-zero exit, returns SubcommandFailed.
fn runSubcommandHasOutput(allocator: std.mem.Allocator, args: []const []const u8) RunError!bool {
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const self_exe = std.fs.selfExePath(&exe_buf) catch return RunError.SelfExeNotFound;

    const argv_list = allocator.alloc([]const u8, args.len + 1) catch return RunError.OutOfMemory;
    defer allocator.free(argv_list);
    argv_list[0] = self_exe;
    for (args, 0..) |a, i| {
        argv_list[i + 1] = a;
    }

    var child = std.process.Child.init(argv_list, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;

    child.spawn() catch return RunError.SubcommandFailed;
    // Read stdout to check if there's output
    var buf: [1024]u8 = undefined;
    var total: usize = 0;
    while (true) {
        const n = child.stdout.?.read(&buf) catch break;
        if (n == 0) break;
        total += n;
    }
    const term = child.wait() catch return RunError.SubcommandFailed;
    switch (term) {
        .Exited => |code| {
            if (code != 0) return RunError.SubcommandFailed;
        },
        else => return RunError.SubcommandFailed,
    }
    return total > 0;
}

/// Detect the currently checked-out branch by reading .git/HEAD.
/// Falls back to "main" if HEAD is detached or unreadable.
fn detectCurrentBranch() []const u8 {
    if (std.fs.cwd().openFile(".git/HEAD", .{})) |file| {
        defer file.close();
        var buf: [256]u8 = undefined;
        const n = file.read(&buf) catch return "main";
        const content = std.mem.trimRight(u8, buf[0..n], "\r\n ");
        const prefix = "ref: refs/heads/";
        if (std.mem.startsWith(u8, content, prefix)) {
            const branch_name = content[prefix.len..];
            // Return static strings to avoid allocation
            if (std.mem.eql(u8, branch_name, "master")) return "master";
            if (std.mem.eql(u8, branch_name, "main")) return "main";
            if (std.mem.eql(u8, branch_name, "develop")) return "develop";
            // Unknown branch — return as-is (static lifetime from stack buf, but
            // this is fine since we only compare/use it immediately)
            return "main"; // fallback for unusual branch names
        }
    } else |_| {}
    return "main";
}

/// Detect the default branch by reading origin/HEAD, then checking for
/// origin/main or origin/master refs. Falls back to "main".
fn detectDefaultBranch() []const u8 {
    // Try reading .git/refs/remotes/origin/HEAD
    if (std.fs.cwd().openFile(".git/refs/remotes/origin/HEAD", .{})) |file| {
        defer file.close();
        var buf: [256]u8 = undefined;
        const n = file.read(&buf) catch return "main";
        const content = std.mem.trimRight(u8, buf[0..n], "\r\n ");
        // Format: "ref: refs/remotes/origin/BRANCH"
        const prefix = "ref: refs/remotes/origin/";
        if (std.mem.startsWith(u8, content, prefix)) {
            const branch_name = content[prefix.len..];
            if (std.mem.eql(u8, branch_name, "master")) return "master";
            if (std.mem.eql(u8, branch_name, "main")) return "main";
            if (std.mem.eql(u8, branch_name, "develop")) return "develop";
        }
    } else |_| {}

    // Fallback: check which ref files exist
    if (std.fs.cwd().access(".git/refs/remotes/origin/master", .{})) |_| {
        return "master";
    } else |_| {}
    if (std.fs.cwd().access(".git/refs/remotes/origin/main", .{})) |_| {
        return "main";
    } else |_| {}

    return "main";
}

/// sync [BRANCH] — fetch origin and merge origin/BRANCH into current branch.
/// Uses merge (not rebase) so parallel agents' commits are never rewritten.
/// This is the building block used by `start` and `progress`.
pub fn cmdRestart(allocator: std.mem.Allocator, args_iter: *platform_mod.ArgIterator) !void {
    const branch = args_iter.next() orelse detectDefaultBranch();

    const origin_branch = std.fmt.allocPrint(allocator, "origin/{s}", .{branch}) catch return error.OutOfMemory;
    defer allocator.free(origin_branch);

    runSubcommand(allocator, &.{ "fetch", "origin" }) catch |e| {
        printErr(allocator, "FAILED: fetch origin\n", .{});
        return e;
    };

    // Merge instead of rebase. This preserves all local commit SHAs so that
    // `reset --hard HEAD~1` always goes to the previous local commit, not
    // some unrelated point in history. For parallel agents this is critical:
    // rebase rewrites their commits and creates orphaned refs.
    runSubcommand(allocator, &.{ "merge", origin_branch, "--no-edit" }) catch |e| {
        // If merge conflicts, abort to leave the tree clean and let the
        // caller (agent) know it needs to retry or resolve.
        printErr(allocator, "FAILED: merge {s} (conflict?) — aborting merge\n", .{origin_branch});
        runSubcommand(allocator, &.{ "merge", "--abort" }) catch {};
        return e;
    };

    printErr(allocator, "ok merged {s}\n", .{origin_branch});
}

/// start [BRANCH] — stash work, sync with origin (merge), restore work
pub fn cmdStart(allocator: std.mem.Allocator, args_iter: *platform_mod.ArgIterator) !void {
    const branch = args_iter.next() orelse detectDefaultBranch();

    // Check if there are local changes using status --porcelain
    const has_changes = runSubcommandHasOutput(allocator, &.{ "status", "--porcelain" }) catch false;

    var had_stash = false;
    if (has_changes) {
        // add -A then stash
        runSubcommand(allocator, &.{ "add", "-A" }) catch {};
        runSubcommand(allocator, &.{"stash"}) catch {};
        had_stash = true;
    }

    // sync (fetch + merge)
    runSubcommand(allocator, &.{ "restart", branch }) catch |e| {
        if (had_stash) {
            runSubcommand(allocator, &.{ "stash", "pop" }) catch {};
        }
        printErr(allocator, "FAILED: sync\n", .{});
        return e;
    };

    // stash pop
    if (had_stash) {
        runSubcommand(allocator, &.{ "stash", "pop" }) catch |e| {
            printErr(allocator, "FAILED: stash pop\n", .{});
            return e;
        };
    }

    printErr(allocator, "ok synced\n", .{});
}

/// progress "DESCRIPTION" — the ONE command agents use for version control.
///
/// 1. fetch + merge origin (pick up other agents' work)
/// 2. add -A + commit
/// 3. push
///
/// Merge-before-commit means the agent's commit is always on top of the
/// latest remote state. Merge (not rebase) means no commit SHAs are ever
/// rewritten, so history is always additive and `reset --hard HEAD~N`
/// behaves predictably.
///
/// If push fails due to a race (another agent pushed between our fetch and
/// push), we pull-merge and retry once.
pub fn cmdProgress(allocator: std.mem.Allocator, args_iter: *platform_mod.ArgIterator) !void {
    const message = args_iter.next() orelse {
        printErr(allocator, "error: progress requires a commit message\n", .{});
        return error.SubcommandFailed;
    };

    // Detect branches
    const default_branch = detectDefaultBranch();
    const current_branch = detectCurrentBranch();

    const origin_branch = std.fmt.allocPrint(allocator, "origin/{s}", .{default_branch}) catch return error.OutOfMemory;
    defer allocator.free(origin_branch);

    // Step 1: Fetch + merge to incorporate other agents' work BEFORE committing.
    // This way our commit sits cleanly on top of the merged state.
    runSubcommand(allocator, &.{ "fetch", "origin" }) catch |e| {
        printErr(allocator, "FAILED: fetch origin\n", .{});
        return e;
    };

    // Merge origin — this is a no-op if already up to date.
    runSubcommand(allocator, &.{ "merge", origin_branch, "--no-edit" }) catch |e| {
        // Merge conflict — abort and let the agent know
        printErr(allocator, "FAILED: merge {s} before commit — aborting\n", .{origin_branch});
        runSubcommand(allocator, &.{ "merge", "--abort" }) catch {};
        return e;
    };

    // Step 2: Stage and commit the agent's work
    runSubcommand(allocator, &.{ "add", "-A" }) catch |e| {
        printErr(allocator, "FAILED: add\n", .{});
        return e;
    };

    // commit (may fail with "nothing to commit" if only the merge happened)
    runSubcommand(allocator, &.{ "commit", "-m", message }) catch {
        // Not fatal — might be nothing new to commit after the merge
        printErr(allocator, "note: nothing to commit (merge-only?)\n", .{});
    };

    // Step 3: Push
    const push_ok = pushBranch(allocator, current_branch, default_branch);
    if (!push_ok) {
        // Push rejected — another agent pushed in between. Pull-merge and retry once.
        printErr(allocator, "note: push rejected, pulling and retrying\n", .{});

        runSubcommand(allocator, &.{ "fetch", "origin" }) catch |e| {
            printErr(allocator, "FAILED: fetch on retry\n", .{});
            return e;
        };

        runSubcommand(allocator, &.{ "merge", origin_branch, "--no-edit" }) catch |e| {
            printErr(allocator, "FAILED: merge on retry — aborting\n", .{});
            runSubcommand(allocator, &.{ "merge", "--abort" }) catch {};
            return e;
        };

        if (!pushBranch(allocator, current_branch, default_branch)) {
            printErr(allocator, "FAILED: push after retry\n", .{});
            return error.SubcommandFailed;
        }
    }

    printErr(allocator, "ok committed+pushed ({s})\n", .{default_branch});
}

/// Push current_branch to origin/default_branch. Returns true on success.
fn pushBranch(allocator: std.mem.Allocator, current_branch: []const u8, default_branch: []const u8) bool {
    if (std.mem.eql(u8, current_branch, default_branch)) {
        runSubcommand(allocator, &.{ "push", "origin", default_branch }) catch return false;
        return true;
    }
    // Cross-branch push: local current → remote default
    const refspec = std.fmt.allocPrint(allocator, "{s}:{s}", .{ current_branch, default_branch }) catch {
        runSubcommand(allocator, &.{ "push", "origin", current_branch }) catch return false;
        return true;
    };
    defer allocator.free(refspec);
    runSubcommand(allocator, &.{ "push", "origin", refspec }) catch {
        // Refspec failed — try pushing current branch as-is
        runSubcommand(allocator, &.{ "push", "origin", current_branch }) catch return false;
    };
    return true;
}
