// Auto-generated from main_common.zig - cmd_fast_import
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

pub fn cmdFastImport(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    const fast_import = @import("git/fast_import.zig");
    var expect_done = false;
    var options = fast_import.Options{
        .expect_done = &expect_done,
    };

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--done")) {
            expect_done = true;
        } else if (std.mem.eql(u8, arg, "--force")) {
            options.force = true;
        } else if (std.mem.eql(u8, arg, "--quiet")) {
            options.quiet = true;
        } else if (std.mem.eql(u8, arg, "--stats")) {
            options.stats = true;
        } else if (std.mem.startsWith(u8, arg, "--import-marks=")) {
            options.import_marks = arg["--import-marks=".len..];
        } else if (std.mem.startsWith(u8, arg, "--import-marks-if-exists=")) {
            options.import_marks_if_exists = arg["--import-marks-if-exists=".len..];
        } else if (std.mem.startsWith(u8, arg, "--export-marks=")) {
            options.export_marks = arg["--export-marks=".len..];
        } else if (std.mem.eql(u8, arg, "--date-format=raw-permissive")) {
            options.date_format_raw_permissive = true;
        } else if (std.mem.startsWith(u8, arg, "--date-format=")) {
            // raw is default, others accepted
        }
    }

    const git_dir = helpers.global_git_dir_override orelse ".git";
    fast_import.run(allocator, platform_impl, options, git_dir) catch |e| {
        const msg = std.fmt.allocPrint(allocator, "fatal: fast-import error: {}\n", .{e}) catch "fatal: fast-import error\n";
        platform_impl.writeStderr(msg) catch {};
        std.process.exit(1);
    };
}
