// Auto-generated from main_common.zig - cmd_daemon
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

pub fn cmdDaemon(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--init-timeout=")) {
            const val = arg["--init-timeout=".len..];
            const parsed = std.fmt.parseInt(i64, val, 10) catch {
                const msg = try std.fmt.allocPrint(allocator, "fatal: invalid init-timeout '{s}', expecting a non-negative integer\n", .{val});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(1);
            };
            if (parsed < 0) {
                const msg = try std.fmt.allocPrint(allocator, "fatal: invalid init-timeout '{s}', expecting a non-negative integer\n", .{val});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(1);
            }
        } else if (std.mem.startsWith(u8, arg, "--timeout=")) {
            const val = arg["--timeout=".len..];
            const parsed = std.fmt.parseInt(i64, val, 10) catch {
                const msg = try std.fmt.allocPrint(allocator, "fatal: invalid timeout '{s}', expecting a non-negative integer\n", .{val});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(1);
            };
            if (parsed < 0) {
                const msg = try std.fmt.allocPrint(allocator, "fatal: invalid timeout '{s}', expecting a non-negative integer\n", .{val});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(1);
            }
        } else if (std.mem.startsWith(u8, arg, "--max-connections=")) {
            const val = arg["--max-connections=".len..];
            _ = std.fmt.parseInt(i64, val, 10) catch {
                const msg = try std.fmt.allocPrint(allocator, "fatal: invalid max-connections '{s}', expecting an integer\n", .{val});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(1);
            };
        }
    }
    try platform_impl.writeStderr("fatal: daemon not fully implemented\n");
    std.process.exit(1);
}
