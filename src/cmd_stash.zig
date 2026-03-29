// Auto-generated from main_common.zig - cmd_stash
// Agents: this file is yours to edit for the commands it contains.

const std = @import("std");
const platform_mod = @import("platform/platform.zig");
const helpers = @import("git_helpers.zig");

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

pub fn nativeCmdStash(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    const subcmd = args.next() orelse "push";
    
    const git_path = helpers.findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);
    
    if (std.mem.eql(u8, subcmd, "list")) {
        // List stash entries
        const stash_log = try std.fmt.allocPrint(allocator, "{s}/refs/stash", .{git_path});
        defer allocator.free(stash_log);
        _ = platform_impl.fs.readFile(allocator, stash_log) catch {
            // helpers.No stash entries - exit silently
            return;
        };
        // TODO: parse reflog to show stash entries
    } else if (std.mem.eql(u8, subcmd, "push") or std.mem.eql(u8, subcmd, "save")) {
        // Stub: stash push requires saving working tree and index state as commits
        try platform_impl.writeStderr("error: stash push not yet fully implemented natively\n");
        std.process.exit(1);
    } else if (std.mem.eql(u8, subcmd, "pop") or std.mem.eql(u8, subcmd, "apply")) {
        try platform_impl.writeStderr("error: stash pop/apply not yet fully implemented natively\n");
        std.process.exit(1);
    } else if (std.mem.eql(u8, subcmd, "drop")) {
        try platform_impl.writeStderr("error: stash drop not yet fully implemented natively\n");
        std.process.exit(1);
    } else if (std.mem.eql(u8, subcmd, "clear")) {
        // helpers.Delete stash ref
        const stash_ref = try std.fmt.allocPrint(allocator, "{s}/refs/stash", .{git_path});
        defer allocator.free(stash_ref);
        std.fs.cwd().deleteFile(stash_ref) catch {};
        const stash_log = try std.fmt.allocPrint(allocator, "{s}/logs/refs/stash", .{git_path});
        defer allocator.free(stash_log);
        std.fs.cwd().deleteFile(stash_log) catch {};
    } else if (std.mem.eql(u8, subcmd, "show")) {
        try platform_impl.writeStderr("error: stash show not yet fully implemented natively\n");
        std.process.exit(1);
    } else {
        const msg = try std.fmt.allocPrint(allocator, "error: unknown stash subcommand '{s}'\n", .{subcmd});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        std.process.exit(1);
    }
}
