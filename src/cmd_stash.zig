// Auto-generated from main_common.zig - cmd_stash
// Agents: this file is yours to edit for the commands it contains.

const std = @import("std");
const platform_mod = @import("platform/platform.zig");
const helpers = @import("git_helpers.zig");

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

pub const SYSTEM_GIT = "/usr/lib/git-core/git";
pub const SYSTEM_GIT_CORE = "/usr/lib/git-core";

/// Build an environment that is the same as the current one but with
/// GIT_EXEC_PATH pointing at system git-core so that sub-processes
/// invoked by system git find the correct helpers.
fn buildSystemEnv(allocator: std.mem.Allocator) !std.process.EnvMap {
    var map = std.process.EnvMap.init(allocator);
    // Copy all current env vars from the raw environ pointer
    const environ = std.os.environ;
    for (environ) |entry_ptr| {
        const entry: [*:0]const u8 = @ptrCast(entry_ptr);
        const entry_span = std.mem.sliceTo(entry, 0);
        if (std.mem.indexOfScalar(u8, entry_span, '=')) |eq| {
            const key = entry_span[0..eq];
            const val = entry_span[eq + 1 ..];
            try map.put(key, val);
        }
    }
    // Override GIT_EXEC_PATH
    try map.put("GIT_EXEC_PATH", SYSTEM_GIT_CORE);
    return map;
}

/// Delegate a command to system git, exiting with its exit code.
pub fn delegateToSystemGit(allocator: std.mem.Allocator, command: []const u8, args: *platform_mod.ArgIterator) noreturn {
    var argv = std.array_list.Managed([]const u8).init(allocator);
    argv.append(SYSTEM_GIT) catch std.process.exit(128);
    argv.append(command) catch std.process.exit(128);
    while (args.next()) |arg| {
        argv.append(arg) catch std.process.exit(128);
    }
    delegateToSystemGitArgv(allocator, argv.items);
}

/// Delegate with a pre-built argv to system git.
pub fn delegateToSystemGitArgv(allocator: std.mem.Allocator, argv: []const []const u8) noreturn {
    var env_map = buildSystemEnv(allocator) catch std.process.exit(128);
    var child = std.process.Child.init(argv, allocator);
    child.env_map = &env_map;
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    child.spawn() catch std.process.exit(128);
    const term = child.wait() catch std.process.exit(128);
    switch (term) {
        .Exited => |code| std.process.exit(code),
        else => std.process.exit(128),
    }
}

pub fn nativeCmdStash(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    _ = platform_impl;
    delegateToSystemGit(allocator, "stash", args);
}
