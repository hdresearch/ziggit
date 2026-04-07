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

/// restart [BRANCH] — fetch origin && rebase onto origin/BRANCH
pub fn cmdRestart(allocator: std.mem.Allocator, args_iter: *platform_mod.ArgIterator) !void {
    const branch = args_iter.next() orelse detectDefaultBranch();

    const origin_branch = std.fmt.allocPrint(allocator, "origin/{s}", .{branch}) catch return error.OutOfMemory;
    defer allocator.free(origin_branch);

    runSubcommand(allocator, &.{ "fetch", "origin" }) catch |e| {
        printErr(allocator, "FAILED: fetch origin\n", .{});
        return e;
    };

    runSubcommand(allocator, &.{ "rebase", origin_branch }) catch |e| {
        printErr(allocator, "FAILED: rebase onto {s}\n", .{origin_branch});
        return e;
    };

    printErr(allocator, "ok rebased on {s}\n", .{origin_branch});
}

/// start [BRANCH] — stash work, restart, restore work
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

    // restart
    runSubcommand(allocator, &.{ "restart", branch }) catch |e| {
        if (had_stash) {
            runSubcommand(allocator, &.{ "stash", "pop" }) catch {};
        }
        printErr(allocator, "FAILED: restart\n", .{});
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

/// progress "DESCRIPTION" — add, commit, push, restart
pub fn cmdProgress(allocator: std.mem.Allocator, args_iter: *platform_mod.ArgIterator) !void {
    const message = args_iter.next() orelse {
        printErr(allocator, "error: progress requires a commit message\n", .{});
        return error.SubcommandFailed;
    };

    // Detect branches
    const default_branch = detectDefaultBranch();
    const current_branch = detectCurrentBranch();

    // add -A
    runSubcommand(allocator, &.{ "add", "-A" }) catch |e| {
        printErr(allocator, "FAILED: add\n", .{});
        return e;
    };

    // commit -m "DESCRIPTION"
    runSubcommand(allocator, &.{ "commit", "-m", message }) catch |e| {
        printErr(allocator, "FAILED: commit (nothing to commit?)\n", .{});
        return e;
    };

    // Push: if current branch differs from default, use refspec current:default
    // (e.g. push master's commits to origin/main)
    if (std.mem.eql(u8, current_branch, default_branch)) {
        // Simple case: current matches default
        runSubcommand(allocator, &.{ "push", "origin", default_branch }) catch |e| {
            printErr(allocator, "FAILED: push\n", .{});
            return e;
        };
    } else {
        // Cross-branch push: local current → remote default
        const refspec = std.fmt.allocPrint(allocator, "{s}:{s}", .{ current_branch, default_branch }) catch {
            // Allocation failed — try plain push as fallback
            runSubcommand(allocator, &.{ "push", "origin", current_branch }) catch |e| {
                printErr(allocator, "FAILED: push\n", .{});
                return e;
            };
            printErr(allocator, "ok committed+pushed ({s}, wanted {s})\n", .{ current_branch, default_branch });
            return;
        };
        defer allocator.free(refspec);
        runSubcommand(allocator, &.{ "push", "origin", refspec }) catch |e| {
            // Refspec push failed — try pushing current branch as-is
            printErr(allocator, "note: cross-branch push {s}:{s} failed, trying {s}\n", .{ current_branch, default_branch, current_branch });
            runSubcommand(allocator, &.{ "push", "origin", current_branch }) catch {
                printErr(allocator, "FAILED: push\n", .{});
                return e;
            };
        };
    }

    // restart (fetch + rebase onto origin/BRANCH)
    runSubcommand(allocator, &.{ "restart", default_branch }) catch |e| {
        printErr(allocator, "note: commit+push succeeded, but post-push restart failed\n", .{});
        printErr(allocator, "FAILED: restart after push\n", .{});
        return e;
    };

    printErr(allocator, "ok committed+pushed ({s})\n", .{default_branch});
}
