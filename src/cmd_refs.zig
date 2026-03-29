// Auto-generated from main_common.zig - cmd_refs
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

pub fn cmdRefs(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    const subcmd = args.next() orelse {
        try platform_impl.writeStderr("usage: git helpers.refs <subcommand>\n");
        std.process.exit(129);
        unreachable;
    };
    
    if (std.mem.eql(u8, subcmd, "exists")) {
        const ref_name = args.next() orelse {
            try platform_impl.writeStderr("error: helpers.refs exists requires a ref argument\n");
            std.process.exit(129);
            unreachable;
        };
        
        const git_dir = helpers.findGitDirectory(allocator, platform_impl) catch {
            try platform_impl.writeStderr("fatal: not a git repository\n");
            std.process.exit(128);
            unreachable;
        };
        defer allocator.free(git_dir);
        
        const ref_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_dir, ref_name });
        defer allocator.free(ref_path);
        
        if (std.fs.cwd().access(ref_path, .{})) |_| {
            // helpers.Check not a directory
            const stat = std.fs.cwd().statFile(ref_path) catch return;
            if (stat.kind == .directory) {
                try platform_impl.writeStderr("error: reference does not exist\n");
                std.process.exit(2);
                unreachable;
            }
            return; // exists
        } else |_| {
            // helpers.Check packed-helpers.refs
            const packed_path = try std.fmt.allocPrint(allocator, "{s}/packed-refs", .{git_dir});
            defer allocator.free(packed_path);
            const packed_data = platform_impl.fs.readFile(allocator, packed_path) catch {
                try platform_impl.writeStderr("error: reference does not exist\n");
                std.process.exit(2);
                unreachable;
            };
            defer allocator.free(packed_data);
            var lines = std.mem.splitScalar(u8, packed_data, '\n');
            while (lines.next()) |line| {
                if (line.len == 0 or line[0] == '#') continue;
                if (line.len >= 41 and line[40] == ' ') {
                    const packed_ref = std.mem.trim(u8, line[41..], " \t\r");
                    if (std.mem.eql(u8, packed_ref, ref_name)) return;
                }
            }
            try platform_impl.writeStderr("error: reference does not exist\n");
            std.process.exit(2);
            unreachable;
        }
    } else {
        const msg = try std.fmt.allocPrint(allocator, "error: unknown subcommand '{s}'\n", .{subcmd});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        std.process.exit(1);
        unreachable;
    }
}

// helpers.stripInlineComment moved to config section


















// =============================================================================