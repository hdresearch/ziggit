// Auto-generated from main_common.zig - cmd_pack_refs
// Agents: this file is yours to edit for the commands it contains.

const std = @import("std");
const platform_mod = @import("platform/platform.zig");
const helpers = @import("git_helpers.zig");
const cmd_gc = @import("cmd_gc.zig");

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

pub fn nativeCmdPackRefs(allocator: std.mem.Allocator, args: [][]const u8, command_index: usize, platform_impl: *const platform_mod.Platform) !void {
    _ = platform_impl;
    var prune_flag = false;
    var all_flag = false;
    var i = command_index + 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--all")) {
            all_flag = true;
        } else if (std.mem.eql(u8, arg, "--prune")) {
            prune_flag = true;
        } else if (std.mem.eql(u8, arg, "--no-prune")) {
            prune_flag = false;
        }
    }
    

    const git_dir = try helpers.findGitDir();
    try packRefsImpl(allocator, git_dir, prune_flag);
}


pub fn packRefs(allocator: std.mem.Allocator, git_dir: []const u8) !void {
    try packRefsImpl(allocator, git_dir, true);
}


pub fn packRefsImpl(allocator: std.mem.Allocator, git_dir: []const u8, prune: bool) !void {
    // helpers.Collect all refs: both from packed-helpers.refs and loose helpers.refs
    var ref_map = std.StringHashMap([]const u8).init(allocator);
    defer {
        var it = ref_map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        ref_map.deinit();
    }

    // helpers.Read existing packed-helpers.refs
    const packed_refs_path = try std.fmt.allocPrint(allocator, "{s}/packed-refs", .{git_dir});
    defer allocator.free(packed_refs_path);
    if (std.fs.cwd().readFileAlloc(allocator, packed_refs_path, 10 * 1024 * 1024)) |packed_content| {
        defer allocator.free(packed_content);
        var lines = std.mem.splitScalar(u8, packed_content, '\n');
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#' or line[0] == '^') continue;
            if (std.mem.indexOfScalar(u8, line, ' ')) |space_idx| {
                const hash = line[0..space_idx];
                const name = line[space_idx + 1..];
                if (hash.len >= 40) {
                    const name_dup = try allocator.dupe(u8, name);
                    const hash_dup = try allocator.dupe(u8, hash[0..40]);
                    const gop = try ref_map.getOrPut(name_dup);
                    if (gop.found_existing) {
                        allocator.free(name_dup);
                        allocator.free(gop.value_ptr.*);
                    }
                    gop.value_ptr.* = hash_dup;
                }
            }
        }
    } else |_| {}

    // helpers.Collect loose helpers.refs from refs/ directory
    var loose_refs = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (loose_refs.items) |r| allocator.free(r);
        loose_refs.deinit();
    }
    try helpers.collectLooseRefsForPack(allocator, git_dir, "refs", &ref_map, &loose_refs);

    // helpers.Write packed-helpers.refs file
    var output = std.array_list.Managed(u8).init(allocator);
    defer output.deinit();
    try output.appendSlice("# pack-helpers.refs with: peeled fully-peeled sorted \n");

    // helpers.Sort ref names
    var names = std.array_list.Managed([]const u8).init(allocator);
    defer names.deinit();
    var it = ref_map.iterator();
    while (it.next()) |entry| {
        try names.append(entry.key_ptr.*);
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    for (names.items) |name| {
        if (ref_map.get(name)) |hash| {
            try output.appendSlice(hash);
            try output.append(' ');
            try output.appendSlice(name);
            try output.append('\n');
        }
    }

    std.fs.cwd().writeFile(.{ .sub_path = packed_refs_path, .data = output.items }) catch {};

    // Prune loose helpers.refs that are now packed
    if (prune) {
        for (loose_refs.items) |ref_path| {
            const full_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_dir, ref_path }) catch continue;
            defer allocator.free(full_path);
            std.fs.cwd().deleteFile(full_path) catch {};
        }
        // helpers.Clean up empty directories
        cmd_gc.cleanEmptyRefDirs2(allocator, git_dir, "refs");
    }
}
