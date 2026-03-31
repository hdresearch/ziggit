const std = @import("std");
const helpers = @import("../git_helpers.zig");

pub const HookResult = struct {
    exit_code: u8,
    skipped: bool, // true if hook doesn't exist or isn't executable
};

/// Run a git hook by name.
/// git_dir: path to .git directory
/// hook_name: e.g. "pre-commit", "commit-msg", "post-checkout"
/// args: additional arguments to pass to the hook script
/// stdin_data: optional data to pipe to the hook's stdin
/// platform_impl: platform abstraction (used for config lookup)
pub fn runHook(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    hook_name: []const u8,
    args: []const []const u8,
    stdin_data: ?[]const u8,
    platform_impl: anytype,
) !HookResult {
    _ = platform_impl;
    if (@import("builtin").target.os.tag == .freestanding) {
        return HookResult{ .exit_code = 0, .skipped = true };
    }

    // Determine hooks directory: core.hooksPath or default .git/hooks
    const hooks_dir = blk: {
        if (helpers.getConfigValueByKey(git_dir, "core.hooksPath", allocator)) |hp| {
            break :blk hp;
        }
        break :blk try std.fmt.allocPrint(allocator, "{s}/hooks", .{git_dir});
    };
    defer allocator.free(hooks_dir);

    const hook_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ hooks_dir, hook_name });
    defer allocator.free(hook_path);

    // Check if hook exists
    const stat = std.fs.cwd().statFile(hook_path) catch {
        return HookResult{ .exit_code = 0, .skipped = true };
    };

    // Check if executable (on POSIX)
    if (@import("builtin").target.os.tag != .windows) {
        if (stat.mode & 0o111 == 0) {
            return HookResult{ .exit_code = 0, .skipped = true };
        }
    }

    // Build argv: hook_path + args
    var argv_list = std.array_list.Managed([]const u8).init(allocator);
    defer argv_list.deinit();
    try argv_list.append(hook_path);
    for (args) |a| {
        try argv_list.append(a);
    }

    // Spawn child process
    var child = std.process.Child.init(argv_list.items, allocator);

    // Set working directory to repo root (parent of .git)
    const repo_root = std.fs.path.dirname(git_dir) orelse ".";
    child.cwd = repo_root;

    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    if (stdin_data != null) {
        child.stdin_behavior = .Pipe;
    } else {
        child.stdin_behavior = .Inherit;
    }

    // Inherit the current environment (don't set env_map, which would replace it)
    // GIT_DIR will be available via the normal process environment

    child.spawn() catch {
        return HookResult{ .exit_code = 0, .skipped = true };
    };

    // Write stdin data if provided
    if (stdin_data) |data| {
        if (child.stdin) |*stdin_pipe| {
            stdin_pipe.writeAll(data) catch {};
            stdin_pipe.close();
            child.stdin = null;
        }
    }

    const result = child.wait() catch {
        return HookResult{ .exit_code = 128, .skipped = false };
    };

    return switch (result) {
        .Exited => |code| HookResult{ .exit_code = code, .skipped = false },
        else => HookResult{ .exit_code = 128, .skipped = false },
    };
}

/// Warn about a non-executable hook file (matching git behavior).
pub fn warnIgnoredHook(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    hook_name: []const u8,
    platform_impl: anytype,
) void {
    // Check advice.ignoredHook config
    if (helpers.getConfigValueByKey(git_dir, "advice.ignoredHook", allocator)) |val| {
        defer allocator.free(val);
        if (std.mem.eql(u8, val, "false")) return;
    }

    const hooks_dir = blk: {
        if (helpers.getConfigValueByKey(git_dir, "core.hooksPath", allocator)) |hp| {
            break :blk hp;
        }
        break :blk std.fmt.allocPrint(allocator, "{s}/hooks", .{git_dir}) catch return;
    };
    defer allocator.free(hooks_dir);

    const hook_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ hooks_dir, hook_name }) catch return;
    defer allocator.free(hook_path);

    // Check if file exists but is not executable
    const stat = std.fs.cwd().statFile(hook_path) catch return;
    if (stat.mode & 0o111 == 0) {
        const hint1 = std.fmt.allocPrint(allocator, "hint: The '{s}' hook was ignored because it's not set as executable.\n", .{hook_path}) catch return;
        defer allocator.free(hint1);
        platform_impl.writeStderr(hint1) catch {};
        platform_impl.writeStderr("hint: You can disable this warning with `git config advice.ignoredHook false`.\n") catch {};
    }
}
