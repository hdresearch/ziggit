// Auto-generated from main_common.zig - cmd_rm
// Agents: this file is yours to edit for the commands it contains.

const std = @import("std");
const platform_mod = @import("platform/platform.zig");
const helpers = @import("git_helpers.zig");
const succinct_mod = @import("succinct.zig");

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

pub fn cmdRm(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    if (@import("builtin").target.os.tag == .freestanding) {
        try platform_impl.writeStderr("rm: not supported in freestanding mode\n");
        return;
    }

    // helpers.Find git directory
    const git_path = helpers.findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
        return;
    };
    defer allocator.free(git_path);

    // helpers.Parse arguments
    var force = false;
    var cached = false;
    var recursive = false;
    var quiet = false;
    var ignore_unmatch = false;
    var saw_dashdash = false;
    var files = std.array_list.Managed([]const u8).init(allocator);
    defer files.deinit();

    while (args.next()) |arg| {
        if (saw_dashdash) {
            try files.append(arg);
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            saw_dashdash = true;
        } else if (std.mem.eql(u8, arg, "--force")) {
            force = true;
        } else if (std.mem.eql(u8, arg, "--cached")) {
            cached = true;
        } else if (std.mem.eql(u8, arg, "--recursive")) {
            recursive = true;
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            quiet = true;
        } else if (std.mem.eql(u8, arg, "--ignore-unmatch")) {
            ignore_unmatch = true;
        } else if (std.mem.startsWith(u8, arg, "-") and !std.mem.eql(u8, arg, "--") and arg.len > 1 and arg[1] != '-') {
            // helpers.Handle combined short flags like -rf, -fr, etc.
            for (arg[1..]) |ch| {
                switch (ch) {
                    'f' => force = true,
                    'r' => recursive = true,
                    'q' => quiet = true,
                    else => {
                        const msg = try std.fmt.allocPrint(allocator, "fatal: unknown option '{s}'\n", .{arg});
                        defer allocator.free(msg);
                        try platform_impl.writeStderr(msg);
                        std.process.exit(128);
                    },
                }
            }
        } else {
            try files.append(arg);
        }
    }

    if (files.items.len == 0) {
        try platform_impl.writeStderr("usage: git rm [-f | --force] [-n] [-r] [--cached] [--ignore-unmatch] [--quiet] [--pathspec-from-file=<file> [--pathspec-file-nul]] [--] [<pathspec>...]\n");
        std.process.exit(128);
        return;
    }

    // helpers.Load the index
    var index = index_mod.Index.load(git_path, platform_impl, allocator) catch |err| switch (err) {
        error.IndexNotFound => {
            try platform_impl.writeStderr("fatal: index file not found\n");
            std.process.exit(128);
            return;
        },
        else => return err,
    };
    defer index.deinit();

    // helpers.Collect indices to remove (reverse order to preserve indices)
    var to_remove = std.array_list.Managed(usize).init(allocator);
    defer to_remove.deinit();
    var removed_paths = std.array_list.Managed([]const u8).init(allocator);
    defer removed_paths.deinit();

    for (files.items) |file_path| {
        var found = false;
        for (index.entries.items, 0..) |entry, i| {
            if (helpers.pathspecMatch(file_path, entry.path)) {
                // helpers.Check if non-recursive and path is in subdirectory
                if (!recursive and !std.mem.eql(u8, file_path, entry.path) and std.mem.indexOf(u8, entry.path, "/") != null) {
                    // helpers.Only skip if the pathspec is a directory prefix match and -r not set
                    if (std.mem.startsWith(u8, entry.path, file_path)) {
                        if (!force) {
                            const msg = try std.fmt.allocPrint(allocator, "fatal: not removing '{s}' recursively without -r\n", .{file_path});
                            defer allocator.free(msg);
                            try platform_impl.writeStderr(msg);
                            std.process.exit(128);
                        }
                        continue;
                    }
                }
                found = true;
                try to_remove.append(i);
                try removed_paths.append(entry.path);
            }
        }

        if (!found) {
            if (ignore_unmatch) continue;
            const msg = try std.fmt.allocPrint(allocator, "fatal: pathspec '{s}' did not match any files\n", .{file_path});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
            return;
        }
    }

    // helpers.Sort removal indices in reverse order to preserve earlier indices
    std.mem.sort(usize, to_remove.items, {}, struct {
        fn cmp(_: void, a: usize, b: usize) bool {
            return a > b; // reverse order
        }
    }.cmp);

    // helpers.Remove duplicates and perform removal
    var last_removed: ?usize = null;
    for (to_remove.items) |idx| {
        if (last_removed != null and last_removed.? == idx) continue;
        last_removed = idx;
        _ = index.entries.orderedRemove(idx);
    }

    // helpers.Output removed files and remove from working tree
    for (removed_paths.items) |path| {
        if (!quiet and !succinct_mod.isEnabled()) {
            const msg = try std.fmt.allocPrint(allocator, "rm '{s}'\n", .{path});
            defer allocator.free(msg);
            try platform_impl.writeStdout(msg);
        }

        if (!cached) {
            const full_path = try std.fmt.allocPrint(allocator, "{s}/../{s}", .{git_path, path});
            defer allocator.free(full_path);

            platform_impl.fs.deleteFile(full_path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => {
                    if (!force) {
                        const msg = try std.fmt.allocPrint(allocator, "fatal: could not remove '{s}': {}\n", .{path, err});
                        defer allocator.free(msg);
                        try platform_impl.writeStderr(msg);
                        std.process.exit(128);
                    }
                },
            };
            // Clean up empty parent directories (like real git)
            const repo_root = std.fs.path.dirname(git_path) orelse ".";
            var parent = std.fs.path.dirname(path);
            while (parent) |dir| {
                if (dir.len == 0 or std.mem.eql(u8, dir, ".")) break;
                const dir_full = std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, dir }) catch break;
                defer allocator.free(dir_full);
                // Try to remove - will fail if not empty
                std.fs.cwd().deleteDir(dir_full) catch break;
                parent = std.fs.path.dirname(dir);
            }
        }
    }

    // helpers.Write the updated index back
    try index.save(git_path, platform_impl);
}
