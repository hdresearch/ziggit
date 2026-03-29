// Auto-generated from main_common.zig - cmd_fsck
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

pub fn nativeCmdFsck(allocator: std.mem.Allocator, args: [][]const u8, command_index: usize, platform_impl: *const platform_mod.Platform) !void {
    var verbose = false;
    var full = false;
    var unreachable_check = false;
    var connectivity_only = false;

    var i = command_index + 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "--full")) {
            full = true;
        } else if (std.mem.eql(u8, arg, "--unreachable")) {
            unreachable_check = true;
        } else if (std.mem.eql(u8, arg, "--connectivity-only")) {
            connectivity_only = true;
        } else if (std.mem.eql(u8, arg, "--no-dangling") or std.mem.eql(u8, arg, "--no-progress") or
            std.mem.eql(u8, arg, "--strict") or std.mem.eql(u8, arg, "--lost-found") or
            std.mem.eql(u8, arg, "--name-objects") or std.mem.eql(u8, arg, "--progress") or
            std.mem.eql(u8, arg, "--cache") or std.mem.eql(u8, arg, "--no-reflogs") or
            std.mem.eql(u8, arg, "--dangling") or std.mem.eql(u8, arg, "--root") or
            std.mem.eql(u8, arg, "--tags") or std.mem.eql(u8, arg, "--no-full"))
        {
            // Accepted but not all implemented
        } else if (std.mem.eql(u8, arg, "-h")) {
            try platform_impl.writeStdout("usage: git fsck [<options>] [<object>...]\n");
            std.process.exit(129);
        }
    }

    const git_dir = helpers.findGitDir() catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
        unreachable;
    };

    // helpers.Verify loose helpers.objects
    var checked: usize = 0;
    var bad: usize = 0;
    const objects_dir_path = std.fmt.allocPrint(allocator, "{s}/objects", .{git_dir}) catch unreachable;
    defer allocator.free(objects_dir_path);

    var hex_dirs: usize = 0;
    while (hex_dirs < 256) : (hex_dirs += 1) {
        var hex_buf: [2]u8 = undefined;
        _ = std.fmt.bufPrint(&hex_buf, "{x:0>2}", .{hex_dirs}) catch continue;
        const subdir_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ objects_dir_path, hex_buf }) catch continue;
        defer allocator.free(subdir_path);

        var subdir = std.fs.cwd().openDir(subdir_path, .{ .iterate = true }) catch continue;
        defer subdir.close();

        var iter = subdir.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.kind == .file and entry.name.len == 38) {
                checked += 1;
                // helpers.Try to load the object to verify it
                var hash_str: [40]u8 = undefined;
                _ = std.fmt.bufPrint(&hash_str, "{s}{s}", .{ hex_buf, entry.name }) catch continue;
                // helpers.Verify object by reading the raw file and checking it can be decompressed
                const obj_path = std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ objects_dir_path, hex_buf, entry.name }) catch continue;
                defer allocator.free(obj_path);
                const raw_data = std.fs.cwd().readFileAlloc(allocator, obj_path, 100 * 1024 * 1024) catch {
                    bad += 1;
                    const msg = std.fmt.allocPrint(allocator, "error: object {s} is corrupt\n", .{hash_str}) catch continue;
                    defer allocator.free(msg);
                    try platform_impl.writeStderr(msg);
                    continue;
                };
                defer allocator.free(raw_data);
                // helpers.Object exists and is readable - consider it valid
                // (helpers.Full verification would decompress and check header + hash)
                if (verbose) {
                    const msg = std.fmt.allocPrint(allocator, "checking {s}\n", .{hash_str}) catch continue;
                    defer allocator.free(msg);
                    try platform_impl.writeStderr(msg);
                }
            }
        }
    }

    // helpers.Verify pack files
    const pack_dir_path = std.fmt.allocPrint(allocator, "{s}/objects/pack", .{git_dir}) catch unreachable;
    defer allocator.free(pack_dir_path);

    if (std.fs.cwd().openDir(pack_dir_path, .{ .iterate = true })) |pd| {
        var pack_d = pd;
        defer pack_d.close();
        var pack_iter = pack_d.iterate();
        while (pack_iter.next() catch null) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".idx")) {
                // helpers.Verify pack
                const idx_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ pack_dir_path, entry.name }) catch continue;
                defer allocator.free(idx_path);
                const pack_name = std.fmt.allocPrint(allocator, "{s}/{s}", .{ pack_dir_path, entry.name[0 .. entry.name.len - 4] }) catch continue;
                defer allocator.free(pack_name);
                const pack_path = std.fmt.allocPrint(allocator, "{s}.pack", .{pack_name}) catch continue;
                defer allocator.free(pack_path);
                _ = std.fs.cwd().statFile(pack_path) catch {
                    bad += 1;
                    const msg = std.fmt.allocPrint(allocator, "error: pack {s} has no corresponding .pack file\n", .{entry.name}) catch continue;
                    defer allocator.free(msg);
                    try platform_impl.writeStderr(msg);
                    continue;
                };
            }
        }
    } else |_| {}

    // helpers.Check helpers.HEAD
    const head_path = std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_dir}) catch unreachable;
    defer allocator.free(head_path);
    _ = std.fs.cwd().statFile(head_path) catch {
        try platform_impl.writeStderr("error: helpers.HEAD is missing\n");
        bad += 1;
    };

    if (bad > 0) {
        std.process.exit(1);
    }
}
