// Auto-generated from main_common.zig - cmd_mktag
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

pub fn nativeCmdMktag(allocator: std.mem.Allocator, args: [][]const u8, command_index: usize, platform_impl: *const platform_mod.Platform) !void {
    var i = command_index + 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h")) {
            try platform_impl.writeStdout("usage: git mktag\n");
            std.process.exit(129);
        }
    }

    const git_dir = helpers.findGitDir() catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
        unreachable;
    };

    // helpers.Read tag content from stdin
    const stdin = std.fs.File{ .handle = std.posix.STDIN_FILENO };
    const stdin_data = stdin.readToEndAlloc(allocator, 10 * 1024 * 1024) catch {
        try platform_impl.writeStderr("fatal: error reading from stdin\n");
        std.process.exit(128);
        unreachable;
    };
    defer allocator.free(stdin_data);

    // helpers.Validate tag format
    if (std.mem.indexOf(u8, stdin_data, "object ") == null or
        std.mem.indexOf(u8, stdin_data, "type ") == null or
        std.mem.indexOf(u8, stdin_data, "tag ") == null or
        std.mem.indexOf(u8, stdin_data, "tagger ") == null)
    {
        try platform_impl.writeStderr("error: invalid tag format\n");
        std.process.exit(128);
    }

    // helpers.Create and store tag object
    const tag_obj = objects.GitObject.init(.tag, stdin_data);
    const hash = tag_obj.store(git_dir, platform_impl, allocator) catch {
        try platform_impl.writeStderr("fatal: error storing tag object\n");
        std.process.exit(128);
        unreachable;
    };
    defer allocator.free(hash);

    const output = std.fmt.allocPrint(allocator, "{s}\n", .{hash}) catch unreachable;
    defer allocator.free(output);
    try platform_impl.writeStdout(output);
}
