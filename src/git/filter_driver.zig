const std = @import("std");
const helpers = @import("../git_helpers.zig");
const check_attr = @import("../cmd_check_attr.zig");
const platform_mod = @import("../platform/platform.zig");

/// Get the filter name assigned to a file path from .gitattributes.
/// Returns the filter name (e.g., "upper") or null if no filter is set.
pub fn getFilterName(
    allocator: std.mem.Allocator,
    relative_path: []const u8,
    git_path: []const u8,
    platform_impl: *const platform_mod.Platform,
) ?[]u8 {
    const repo_root = std.fs.path.dirname(git_path) orelse ".";

    // Load root .gitattributes
    var attr_rules = std.array_list.Managed(check_attr.AttrRule).init(allocator);
    defer {
        for (attr_rules.items) |*rule| rule.deinit(allocator);
        attr_rules.deinit();
    }

    check_attr.loadAttrFile(allocator, repo_root, "", platform_impl, &attr_rules) catch return null;

    // Also load directory-specific .gitattributes
    var remaining: []const u8 = relative_path;
    while (std.mem.indexOf(u8, remaining, "/")) |slash_pos| {
        const subdir = relative_path[0 .. @intFromPtr(remaining.ptr) - @intFromPtr(relative_path.ptr) + slash_pos];
        if (subdir.len > 0) {
            check_attr.loadAttrFile(allocator, repo_root, subdir, platform_impl, &attr_rules) catch {};
        }
        remaining = remaining[slash_pos + 1 ..];
    }

    // Search for filter attribute (last match wins)
    var filter_value: ?[]const u8 = null;
    for (attr_rules.items) |rule| {
        if (check_attr.attrPatternMatches(rule.pattern, relative_path, false)) {
            for (rule.attrs.items) |attr| {
                if (std.mem.eql(u8, attr.name, "filter")) {
                    if (std.mem.eql(u8, attr.value, "unset") or std.mem.eql(u8, attr.value, "unspecified")) {
                        filter_value = null;
                    } else {
                        filter_value = attr.value;
                    }
                }
            }
        }
    }

    if (filter_value) |v| {
        return allocator.dupe(u8, v) catch null;
    }
    return null;
}

/// Get a filter command from git config.
fn getFilterCommand(
    allocator: std.mem.Allocator,
    git_path: []const u8,
    filter_name: []const u8,
    operation: []const u8,
) ?[]const u8 {
    const key = std.fmt.allocPrint(allocator, "filter.{s}.{s}", .{ filter_name, operation }) catch return null;
    defer allocator.free(key);

    return helpers.getConfigValueByKey(git_path, key, allocator);
}

/// Get the clean filter command for a given filter name.
pub fn getCleanCommand(
    allocator: std.mem.Allocator,
    git_path: []const u8,
    filter_name: []const u8,
) ?[]const u8 {
    return getFilterCommand(allocator, git_path, filter_name, "clean");
}

/// Get the smudge filter command for a given filter name.
pub fn getSmudgeCommand(
    allocator: std.mem.Allocator,
    git_path: []const u8,
    filter_name: []const u8,
) ?[]const u8 {
    return getFilterCommand(allocator, git_path, filter_name, "smudge");
}

/// Get the long-running process command for a given filter name.
pub fn getProcessCommand(
    allocator: std.mem.Allocator,
    git_path: []const u8,
    filter_name: []const u8,
) ?[]const u8 {
    return getFilterCommand(allocator, git_path, filter_name, "process");
}

/// Pipe content through an external filter command.
/// The command is executed via /bin/sh -c, with content piped to stdin.
/// Returns the filtered output, or null on failure.
pub fn runFilter(
    allocator: std.mem.Allocator,
    command: []const u8,
    input: []const u8,
) ?[]u8 {
    if (@import("builtin").target.os.tag == .freestanding) {
        return null;
    }

    const argv = [_][]const u8{ "/bin/sh", "-c", command };
    var child = std.process.Child.init(&argv, allocator);

    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;

    child.spawn() catch return null;

    // Write input to stdin
    if (child.stdin) |*stdin_pipe| {
        stdin_pipe.writeAll(input) catch {};
        stdin_pipe.close();
        child.stdin = null;
    }

    // Read all stdout
    var stdout_list = std.array_list.Managed(u8).init(allocator);
    defer stdout_list.deinit();

    if (child.stdout) |*stdout_pipe| {
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = stdout_pipe.read(&buf) catch break;
            if (n == 0) break;
            stdout_list.appendSlice(buf[0..n]) catch break;
        }
    }

    const result = child.wait() catch return null;

    return switch (result) {
        .Exited => |code| {
            if (code == 0) {
                return stdout_list.toOwnedSlice() catch null;
            }
            return null;
        },
        else => null,
    };
}

/// Apply the clean filter for a file being added to the index.
/// Returns filtered content if a clean filter was applied, null otherwise.
pub fn applyCleanFilter(
    allocator: std.mem.Allocator,
    relative_path: []const u8,
    content: []const u8,
    git_path: []const u8,
    platform_impl: *const platform_mod.Platform,
) ?[]u8 {
    const filter_name = getFilterName(allocator, relative_path, git_path, platform_impl) orelse return null;
    defer allocator.free(filter_name);

    const clean_cmd = getCleanCommand(allocator, git_path, filter_name) orelse return null;
    defer allocator.free(clean_cmd);

    return runFilter(allocator, clean_cmd, content);
}

/// Apply the smudge filter for a file being checked out.
/// Returns filtered content if a smudge filter was applied, null otherwise.
pub fn applySmudgeFilter(
    allocator: std.mem.Allocator,
    relative_path: []const u8,
    content: []const u8,
    git_path: []const u8,
    platform_impl: *const platform_mod.Platform,
) ?[]u8 {
    const filter_name = getFilterName(allocator, relative_path, git_path, platform_impl) orelse return null;
    defer allocator.free(filter_name);

    const smudge_cmd = getSmudgeCommand(allocator, git_path, filter_name) orelse return null;
    defer allocator.free(smudge_cmd);

    return runFilter(allocator, smudge_cmd, content);
}
