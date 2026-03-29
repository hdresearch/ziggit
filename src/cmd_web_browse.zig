// Auto-generated from main_common.zig - cmd_web_browse
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

pub fn cmdWebBrowse(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    var browser: ?[]const u8 = null;
    var url_val: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--browser=")) browser = arg["--browser=".len..]
        else if (!std.mem.startsWith(u8, arg, "-")) url_val = arg;
    }
    if (url_val == null) { try platform_impl.writeStderr("usage: git web--browse\n"); std.process.exit(1); }
    const git_path = helpers.findGitDirectory(allocator, platform_impl) catch null;
    defer if (git_path) |p| allocator.free(p);
    var run_cmd: ?[]const u8 = null;
    if (browser) |b| {
        if (git_path) |gp| {
            const k1 = std.fmt.allocPrint(allocator, "browser.{s}.cmd", .{b}) catch null;
            defer if (k1) |k| allocator.free(k);
            if (k1) |k| run_cmd = helpers.getConfigValueByKey(gp, k, allocator);
            if (run_cmd == null) {
                const k2 = std.fmt.allocPrint(allocator, "browser.{s}.path", .{b}) catch null;
                defer if (k2) |k| allocator.free(k);
                if (k2) |k| {
                    const pv = helpers.getConfigValueByKey(gp, k, allocator);
                    if (pv) |pval| {
                        run_cmd = std.fmt.allocPrint(allocator, "\"{s}\"", .{pval}) catch null;
                        allocator.free(pval);
                    }
                }
            }
        }
    }
    if (run_cmd) |rc| {
        defer allocator.free(rc);
        const sc = std.fmt.allocPrint(allocator, "{s} \"$@\"", .{rc}) catch return;
        defer allocator.free(sc);
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "/bin/sh", "-c", sc, "--", url_val.? },
        }) catch return;
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        if (result.stdout.len > 0) try platform_impl.writeStdout(result.stdout);
    } else {
        try platform_impl.writeStderr("helpers.No suitable browser detected.\n");
        std.process.exit(1);
    }
}
