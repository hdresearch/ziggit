// Auto-generated from main_common.zig - cmd_count_objects
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

pub fn nativeCmdCountObjects(allocator: std.mem.Allocator, args: [][]const u8, command_index: usize, platform_impl: *const platform_mod.Platform) !void {
    var verbose = false;
    var i = command_index + 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "-H") or std.mem.eql(u8, arg, "--human-readable")) {
            // human_readable = true;
        } else if (std.mem.eql(u8, arg, "-h")) {
            try platform_impl.writeStdout("usage: git count-helpers.objects [-v] [-H | --human-readable]\n");
            std.process.exit(129);
        }
    }

    const git_dir = helpers.findGitDir() catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
        unreachable;
    };

    // helpers.Count loose helpers.objects — git uses on-disk size (st_blocks * 512)
    var count: usize = 0;
    var size_disk: u64 = 0;
    var size_pack: u64 = 0;
    var packs: usize = 0;
    var in_pack: u64 = 0;
    var size_garbage: u64 = 0;
    var garbage_count: usize = 0;

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
            if (entry.kind == .file) {
                count += 1;
                const file = subdir.openFile(entry.name, .{}) catch continue;
                defer file.close();
                const linux_stat = std.posix.fstat(file.handle) catch continue;
                size_disk += @as(u64, @intCast(linux_stat.blocks)) * 512;
            }
        }
    }

    // helpers.Count pack files and helpers.objects in packs
    const pack_dir_path = std.fmt.allocPrint(allocator, "{s}/objects/pack", .{git_dir}) catch unreachable;
    defer allocator.free(pack_dir_path);

    if (std.fs.cwd().openDir(pack_dir_path, .{ .iterate = true })) |pack_dir_handle| {
        var pd = pack_dir_handle;
        defer pd.close();

        var pack_iter = pd.iterate();
        while (pack_iter.next() catch null) |entry| {
            if (entry.kind == .file) {
                if (std.mem.endsWith(u8, entry.name, ".pack")) {
                    packs += 1;
                    const pf_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ pack_dir_path, entry.name }) catch continue;
                    defer allocator.free(pf_path);
                    const stat = std.fs.cwd().statFile(pf_path) catch continue;
                    size_pack += stat.size;
                    // helpers.Count helpers.objects by reading pack header
                    const pf = std.fs.cwd().openFile(pf_path, .{}) catch continue;
                    defer pf.close();
                    var hdr_buf: [12]u8 = undefined;
                    const hdr_read = pf.readAll(&hdr_buf) catch continue;
                    if (hdr_read == 12 and std.mem.eql(u8, hdr_buf[0..4], "PACK")) {
                        in_pack += std.mem.readInt(u32, hdr_buf[8..12], .big);
                    }
                } else if (std.mem.endsWith(u8, entry.name, ".idx")) {
                    // helpers.Git includes .idx size in size-pack
                    const idx_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ pack_dir_path, entry.name }) catch continue;
                    defer allocator.free(idx_path);
                    const stat = std.fs.cwd().statFile(idx_path) catch continue;
                    size_pack += stat.size;
                } else if (!std.mem.endsWith(u8, entry.name, ".keep") and
                    !std.mem.endsWith(u8, entry.name, ".bitmap") and
                    !std.mem.endsWith(u8, entry.name, ".rev") and
                    !std.mem.endsWith(u8, entry.name, ".mtimes") and
                    !std.mem.endsWith(u8, entry.name, ".promisor"))
                {
                    garbage_count += 1;
                    const garb_file = std.fmt.allocPrint(allocator, "{s}/{s}", .{ pack_dir_path, entry.name }) catch continue;
                    defer allocator.free(garb_file);
                    const stat = std.fs.cwd().statFile(garb_file) catch continue;
                    size_garbage += stat.size;
                }
            }
        }
    } else |_| {}

    const size_kb = size_disk / 1024;

    if (verbose) {
        const output = std.fmt.allocPrint(allocator,
            "count: {d}\nsize: {d}\nin-pack: {d}\npacks: {d}\nsize-pack: {d}\nprune-packable: 0\ngarbage: {d}\nsize-garbage: {d}\n",
            .{ count, size_kb, in_pack, packs, size_pack / 1024, garbage_count, size_garbage / 1024 },
        ) catch unreachable;
        defer allocator.free(output);
        try platform_impl.writeStdout(output);

        // helpers.Show alternates from info/alternates (recursively)
        {
            var visited = std.StringHashMap(void).init(allocator);
            defer {
                var vit = visited.iterator();
                while (vit.next()) |entry| allocator.free(entry.key_ptr.*);
                visited.deinit();
            }
            var to_visit = std.ArrayListUnmanaged([]const u8){};
            defer {
                for (to_visit.items) |item| allocator.free(item);
                to_visit.deinit(allocator);
            }

            // helpers.Start with this repo's helpers.objects dir
            const start_obj_dir = std.fmt.allocPrint(allocator, "{s}/objects", .{git_dir}) catch unreachable;
            try to_visit.append(allocator, start_obj_dir);

            while (to_visit.items.len > 0) {
                const obj_dir = to_visit.orderedRemove(0);
                defer allocator.free(obj_dir);

                const info_alt = std.fmt.allocPrint(allocator, "{s}/info/alternates", .{obj_dir}) catch continue;
                defer allocator.free(info_alt);
                const alt_content = std.fs.cwd().readFileAlloc(allocator, info_alt, 1024 * 1024) catch continue;
                defer allocator.free(alt_content);
                var alt_lines = std.mem.splitScalar(u8, alt_content, '\n');
                while (alt_lines.next()) |aline| {
                    const atrimmed = std.mem.trim(u8, aline, " \t\r");
                    if (atrimmed.len == 0) continue;
                    // helpers.Resolve relative paths
                    const abs_alt = if (!std.fs.path.isAbsolute(atrimmed)) blk: {
                        const rel = std.fmt.allocPrint(allocator, "{s}/{s}", .{ obj_dir, atrimmed }) catch continue;
                        defer allocator.free(rel);
                        break :blk std.fs.cwd().realpathAlloc(allocator, rel) catch continue;
                    } else std.fs.cwd().realpathAlloc(allocator, atrimmed) catch try allocator.dupe(u8, atrimmed);
                    defer allocator.free(abs_alt);

                    if (visited.contains(abs_alt)) continue;
                    try visited.put(try allocator.dupe(u8, abs_alt), {});

                    const alt_out = std.fmt.allocPrint(allocator, "alternate: {s}\n", .{abs_alt}) catch continue;
                    defer allocator.free(alt_out);
                    try platform_impl.writeStdout(alt_out);

                    // Queue for recursive visiting
                    try to_visit.append(allocator, try allocator.dupe(u8, abs_alt));
                }
            }
        }
    } else {
        const output = std.fmt.allocPrint(allocator, "{d} helpers.objects, {d} kilobytes\n", .{ count, size_kb }) catch unreachable;
        defer allocator.free(output);
        try platform_impl.writeStdout(output);
    }
}
