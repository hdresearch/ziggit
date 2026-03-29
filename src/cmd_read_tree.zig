// Auto-generated from main_common.zig - cmd_read_tree
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

pub fn cmdReadTree(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    const git_dir = helpers.findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
        unreachable;
    };
    defer allocator.free(git_dir);

    var tree_hash: ?[]const u8 = null;
    var empty = false;
    var merge = false;
    var update = false;
    var prefix: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--empty")) {
            empty = true;
        } else if (std.mem.eql(u8, arg, "-m")) {
            merge = true;
        } else if (std.mem.eql(u8, arg, "-u")) {
            update = true;
        } else if (std.mem.eql(u8, arg, "-i")) {
            // index-only, ignore
        } else if (std.mem.startsWith(u8, arg, "--prefix=")) {
            prefix = arg["--prefix=".len..];
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            tree_hash = arg;
        }
    }

    if (empty) {
        // helpers.Write an empty index
        var idx = index_mod.Index.init(allocator);
        defer idx.deinit();
        idx.save(git_dir, platform_impl) catch {
            try platform_impl.writeStderr("fatal: unable to write index file\n");
            std.process.exit(128);
        };
        return;
    }

    if (tree_hash == null) {
        try platform_impl.writeStderr("fatal: must specify a tree-ish\n");
        std.process.exit(128);
        unreachable;
    }

    // helpers.Resolve tree-ish to tree hash
    const resolved_tree = helpers.resolveTreeish(git_dir, tree_hash.?, platform_impl, allocator) catch {
        const err_msg = try std.fmt.allocPrint(allocator, "fatal: not a tree object: {s}\n", .{tree_hash.?});
        defer allocator.free(err_msg);
        try platform_impl.writeStderr(err_msg);
        std.process.exit(128);
        unreachable;
    };
    defer allocator.free(resolved_tree);

    // helpers.Build index from tree
    var idx = index_mod.Index.init(allocator);
    defer idx.deinit();

    try readTreeIntoIndex(&idx, git_dir, resolved_tree, prefix orelse "", platform_impl, allocator);

    idx.save(git_dir, platform_impl) catch {
        try platform_impl.writeStderr("fatal: unable to write index file\n");
        std.process.exit(128);
    };
}


pub fn readTreeIntoIndex(idx: *index_mod.Index, git_dir: []const u8, tree_hash: []const u8, prefix: []const u8, platform_impl: *const platform_mod.Platform, allocator: std.mem.Allocator) !void {
    const obj = objects.GitObject.load(tree_hash, git_dir, platform_impl, allocator) catch return;
    defer obj.deinit(allocator);

    if (obj.type != .tree) return;

    // helpers.Parse tree entries from binary data
    var pos: usize = 0;
    const data = obj.data;
    while (pos < data.len) {
        // Format: <mode> <name>\0<20-byte-sha1>
        const space_pos = std.mem.indexOfScalarPos(u8, data, pos, ' ') orelse break;
        const mode_str = data[pos..space_pos];
        const null_pos = std.mem.indexOfScalarPos(u8, data, space_pos + 1, 0) orelse break;
        const name = data[space_pos + 1 .. null_pos];

        if (null_pos + 21 > data.len) break;
        const entry_sha1 = data[null_pos + 1 .. null_pos + 21];

        var hash_hex: [40]u8 = undefined;
        for (entry_sha1, 0..) |byte, j| {
            const hex = std.fmt.bytesToHex([1]u8{byte}, .lower);
            hash_hex[j * 2] = hex[0];
            hash_hex[j * 2 + 1] = hex[1];
        }

        const full_path = if (prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, name })
        else
            try allocator.dupe(u8, name);

        const mode = std.fmt.parseInt(u32, mode_str, 8) catch 0o100644;

        if (mode == 0o40000) {
            // helpers.Directory - recurse
            defer allocator.free(full_path);
            const sub_prefix = try std.fmt.allocPrint(allocator, "{s}/", .{full_path});
            defer allocator.free(sub_prefix);
            try readTreeIntoIndex(idx, git_dir, &hash_hex, sub_prefix, platform_impl, allocator);
        } else {
            // File entry
            var sha1: [20]u8 = undefined;
            @memcpy(&sha1, entry_sha1);

            const entry = index_mod.IndexEntry{
                .ctime_sec = 0,
                .ctime_nsec = 0,
                .mtime_sec = 0,
                .mtime_nsec = 0,
                .dev = 0,
                .ino = 0,
                .mode = mode,
                .uid = 0,
                .gid = 0,
                .size = 0,
                .sha1 = sha1,
                .flags = @as(u16, @intCast(@min(full_path.len, 0xFFF))),
                .extended_flags = null,
                .path = full_path,
            };
            try idx.entries.append(entry);
        }

        pos = null_pos + 21;
    }
}


