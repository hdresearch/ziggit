// Auto-generated from main_common.zig - cmd_show_branch
// Agents: this file is yours to edit for the commands it contains.

const std = @import("std");
const platform_mod = @import("platform/platform.zig");
const helpers = @import("git_helpers.zig");
const cmd_merge_base = @import("cmd_merge_base.zig");

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

pub fn nativeCmdShowBranch(allocator: std.mem.Allocator, args: [][]const u8, command_index: usize, platform_impl: *const platform_mod.Platform) !void {
    // helpers.Minimal show-branch: supports --merge-base and --independent modes
    var merge_base_mode = false;
    var independent_mode = false;
    var branch_refs = std.ArrayList([]const u8).init(allocator);
    defer branch_refs.deinit();

    var i = command_index + 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--merge-base")) {
            merge_base_mode = true;
        } else if (std.mem.eql(u8, arg, "--independent")) {
            independent_mode = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try branch_refs.append(arg);
        }
    }

    if (merge_base_mode or independent_mode) {
        // Delegate to merge-base with appropriate flags
        var new_args = std.ArrayList([]const u8).init(allocator);
        defer new_args.deinit();
        try new_args.append("git");
        try new_args.append("merge-base");
        if (independent_mode) {
            try new_args.append("--independent");
        } else {
            try new_args.append("--all");
        }
        for (branch_refs.items) |ref| {
            try new_args.append(ref);
        }
        try cmd_merge_base.nativeCmdMergeBase(allocator, new_args.items, 1, platform_impl);
    } else {
        // Basic show-branch: list all local branches with their tip commits
        const git_path = helpers.findGitDirectory(allocator, platform_impl) catch {
            try platform_impl.writeStderr("fatal: not a git repository\n");
            std.process.exit(128);
        };
        defer allocator.free(git_path);

        // helpers.Get list of branches
        const refs_heads_path = try std.fmt.allocPrint(allocator, "{s}/refs/heads", .{git_path});
        defer allocator.free(refs_heads_path);

        var branches = std.ArrayList([]const u8).init(allocator);
        defer {
            for (branches.items) |b| allocator.free(b);
            branches.deinit();
        }

        if (std.fs.cwd().openDir(refs_heads_path, .{ .iterate = true })) |*dir_handle| {
            defer @constCast(dir_handle).close();
            var dir_iter = dir_handle.iterate();
            while (dir_iter.next() catch null) |entry| {
                if (entry.kind == .file) {
                    try branches.append(try allocator.dupe(u8, entry.name));
                }
            }
        } else |_| {}

        // helpers.Get current branch
        const current_branch = refs.getCurrentBranch(git_path, platform_impl, allocator) catch try allocator.dupe(u8, "");
        defer allocator.free(current_branch);
        const short_current = if (std.mem.startsWith(u8, current_branch, "refs/heads/")) current_branch["refs/heads/".len..] else current_branch;

        // Print branch headers
        for (branches.items, 0..) |branch_name, idx| {
            _ = idx;
            const marker: u8 = if (std.mem.eql(u8, branch_name, short_current)) '*' else '!';
            const commit_hash = refs.getBranchCommit(git_path, branch_name, platform_impl, allocator) catch null;
            defer if (commit_hash) |ch| allocator.free(ch);
            var msg: []const u8 = "";
            var msg_owned = false;
            if (commit_hash) |ch| {
                msg = helpers.getCommitMessage(git_path, ch, allocator, platform_impl) catch "";
                msg_owned = msg.len > 0;
            }
            defer if (msg_owned) allocator.free(@constCast(msg));
            const first_line = if (std.mem.indexOf(u8, msg, "\n")) |nl| msg[0..nl] else msg;
            const line = try std.fmt.allocPrint(allocator, " {c} [{s}] {s}\n", .{ marker, branch_name, std.mem.trim(u8, first_line, " \t\r\n") });
            defer allocator.free(line);
            try platform_impl.writeStdout(line);
        }
    }
}
