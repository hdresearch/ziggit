// Auto-generated from main_common.zig - cmd_update_server_info
// Agents: this file is yours to edit for the commands it contains.

const std = @import("std");
const platform_mod = @import("platform/platform.zig");
const helpers = @import("git_helpers.zig");
const cmd_show_ref = @import("cmd_show_ref.zig");

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

pub fn nativeCmdUpdateServerInfo(allocator: std.mem.Allocator, args: [][]const u8, command_index: usize, platform_impl: *const platform_mod.Platform) !void {
    var force = false;

    var i = command_index + 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--force")) {
            force = true;
        } else if (std.mem.eql(u8, arg, "-h")) {
            try platform_impl.writeStdout("usage: git update-server-info [--force]\n");
            std.process.exit(129);
        }
    }

    const git_dir = helpers.findGitDir() catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
        unreachable;
    };

    // helpers.Create info directory
    const info_dir = std.fmt.allocPrint(allocator, "{s}/info", .{git_dir}) catch unreachable;
    defer allocator.free(info_dir);
    std.fs.cwd().makePath(info_dir) catch {};

    // helpers.Update info/helpers.refs
    const info_refs_path = std.fmt.allocPrint(allocator, "{s}/info/refs", .{git_dir}) catch unreachable;
    defer allocator.free(info_refs_path);
    {
        var ref_list = std.ArrayList(helpers.RefEntry).init(allocator);
        defer {
            for (ref_list.items) |entry| {
                allocator.free(entry.name);
                allocator.free(entry.hash);
            }
            ref_list.deinit();
        }

        // helpers.Read packed-helpers.refs
        const packed_refs_path = std.fmt.allocPrint(allocator, "{s}/packed-refs", .{git_dir}) catch unreachable;
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
                        try ref_list.append(.{
                            .name = try allocator.dupe(u8, name),
                            .hash = try allocator.dupe(u8, hash[0..40]),
                        });
                    }
                }
            }
        } else |_| {}
        try helpers.collectLooseRefs(allocator, git_dir, "refs", &ref_list, platform_impl);

        // helpers.Sort
        std.mem.sort(helpers.RefEntry, ref_list.items, {}, struct {
            fn lessThan(_: void, a: helpers.RefEntry, b: helpers.RefEntry) bool {
                return std.mem.order(u8, a.name, b.name).compare(.lt);
            }
        }.lessThan);

        // helpers.Write info/helpers.refs (only if content changed, unless force)
        var content = std.ArrayList(u8).init(allocator);
        defer content.deinit();
        for (ref_list.items) |entry| {
            const line = std.fmt.allocPrint(allocator, "{s}\t{s}\n", .{ entry.hash, entry.name }) catch continue;
            defer allocator.free(line);
            try content.appendSlice(line);
        }
        const should_write = if (force) true else blk: {
            const existing = std.fs.cwd().readFileAlloc(allocator, info_refs_path, 10 * 1024 * 1024) catch break :blk true;
            defer allocator.free(existing);
            break :blk !std.mem.eql(u8, existing, content.items);
        };
        if (should_write) {
            std.fs.cwd().writeFile(.{ .sub_path = info_refs_path, .data = content.items }) catch |err| {
                const msg = std.fmt.allocPrint(allocator, "error: unable to update {s}: {s}\n", .{ info_refs_path, @errorName(err) }) catch return;
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
            };
        }
    }

    // helpers.Update info/packs (objects/info/packs)
    const obj_info_dir = std.fmt.allocPrint(allocator, "{s}/objects/info", .{git_dir}) catch unreachable;
    defer allocator.free(obj_info_dir);
    std.fs.cwd().makePath(obj_info_dir) catch {};

    const packs_file_path = std.fmt.allocPrint(allocator, "{s}/objects/info/packs", .{git_dir}) catch unreachable;
    defer allocator.free(packs_file_path);
    {
        var content = std.ArrayList(u8).init(allocator);
        defer content.deinit();

        const pack_dir = std.fmt.allocPrint(allocator, "{s}/objects/pack", .{git_dir}) catch unreachable;
        defer allocator.free(pack_dir);

        if (std.fs.cwd().openDir(pack_dir, .{ .iterate = true })) |pd| {
            var pack_d = pd;
            defer pack_d.close();
            var pack_names = std.ArrayList([]const u8).init(allocator);
            defer {
                for (pack_names.items) |n| allocator.free(n);
                pack_names.deinit();
            }

            var iter = pack_d.iterate();
            while (iter.next() catch null) |entry| {
                if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".pack")) {
                    try pack_names.append(try allocator.dupe(u8, entry.name));
                }
            }

            // helpers.Sort pack names
            std.mem.sort([]const u8, pack_names.items, {}, struct {
                fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.order(u8, a, b).compare(.lt);
                }
            }.lessThan);

            for (pack_names.items) |name| {
                const line = std.fmt.allocPrint(allocator, "P {s}\n", .{name}) catch continue;
                defer allocator.free(line);
                try content.appendSlice(line);
            }
        } else |_| {}

        // helpers.Always write trailing newline
        try content.append('\n');

        const should_write_packs = if (force) true else blk: {
            const existing = std.fs.cwd().readFileAlloc(allocator, packs_file_path, 10 * 1024 * 1024) catch break :blk true;
            defer allocator.free(existing);
            break :blk !std.mem.eql(u8, existing, content.items);
        };
        if (should_write_packs) {
            std.fs.cwd().writeFile(.{ .sub_path = packs_file_path, .data = content.items }) catch |err| {
                const msg = std.fmt.allocPrint(allocator, "error: unable to update {s}: {s}\n", .{ packs_file_path, @errorName(err) }) catch return;
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
            };
        }
    }
}
