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
    var argv_list = allocator.alloc([]const u8, args.len + 1) catch return RunError.OutOfMemory;
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
            // Return string literals to avoid dangling stack pointer
            if (std.mem.eql(u8, branch_name, "master")) return "master";
            if (std.mem.eql(u8, branch_name, "main")) return "main";
            if (std.mem.eql(u8, branch_name, "develop")) return "develop";
            // For unknown branch names, fall through to ref file check
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

    // add -A (ignore failure — nothing to add is fine)
    runSubcommand(allocator, &.{ "add", "-A" }) catch {};

    // Try stash
    const had_stash = blk: {
        runSubcommand(allocator, &.{"stash"}) catch {
            break :blk false;
        };
        break :blk true;
    };

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

    // add -A
    runSubcommand(allocator, &.{ "add", "-A" }) catch |e| {
        printErr(allocator, "FAILED: add\n", .{});
        return e;
    };

    // commit -m "DESCRIPTION"
    runSubcommand(allocator, &.{ "commit", "-m", message }) catch |e| {
        printErr(allocator, "FAILED: commit (nothing to commit, or pre-commit hook?)\n", .{});
        return e;
    };

    // push
    runSubcommand(allocator, &.{"push"}) catch |e| {
        printErr(allocator, "FAILED: push\n", .{});
        return e;
    };

    // restart (detect default branch since progress doesn't take a branch arg)
    const branch = detectDefaultBranch();
    runSubcommand(allocator, &.{ "restart", branch }) catch |e| {
        printErr(allocator, "FAILED: restart after push (commit+push succeeded)\n", .{});
        return e;
    };

    printErr(allocator, "ok committed+pushed\n", .{});
}
