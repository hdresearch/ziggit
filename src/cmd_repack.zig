// Auto-generated from main_common.zig - cmd_repack
// Agents: this file is yours to edit for the commands it contains.

const std = @import("std");
const platform_mod = @import("platform/platform.zig");
const helpers = @import("git_helpers.zig");
const cmd_pack = @import("cmd_pack.zig");
const cmd_apply = @import("cmd_apply.zig");

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

pub fn nativeCmdRepack(allocator: std.mem.Allocator, args: [][]const u8, command_index: usize, platform_impl: *const platform_mod.Platform) !void {
    var ad_flag = false;
    var quiet = false;

    var i = command_index + 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "-A") or std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "-F") or std.mem.eql(u8, arg, "-l")) {
            ad_flag = true;
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            quiet = true;
        } else if (std.mem.eql(u8, arg, "--no-repack-all-into-one") or
            std.mem.eql(u8, arg, "--keep-unreachable") or
            std.mem.eql(u8, arg, "--no-write-bitmap-index") or
            std.mem.eql(u8, arg, "--write-bitmap-index") or
            std.mem.eql(u8, arg, "--write-midx") or
            std.mem.eql(u8, arg, "--geometric=2") or
            std.mem.eql(u8, arg, "--no-cruft") or
            std.mem.eql(u8, arg, "--cruft"))
        {
            // Accepted flags
        } else if (std.mem.startsWith(u8, arg, "--geometric=") or
            std.mem.startsWith(u8, arg, "--window=") or
            std.mem.startsWith(u8, arg, "--depth=") or
            std.mem.startsWith(u8, arg, "--threads=") or
            std.mem.startsWith(u8, arg, "--max-pack-size="))
        {
            // Accepted with value
        } else if (std.mem.eql(u8, arg, "-h")) {
            try platform_impl.writeStdout("usage: git repack [<options>]\n");
            std.process.exit(129);
        }
    }

    const git_dir = helpers.findGitDir() catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
        unreachable;
    };

    try doNativeRepack(allocator, git_dir, platform_impl, quiet);
}


pub fn doNativeRepack(allocator: std.mem.Allocator, git_dir: []const u8, platform_impl: anytype, _quiet: bool) !void {
    _ = _quiet;

    // helpers.Simple repack: collect all loose helpers.objects and write them into a pack file
    // helpers.Also consolidate existing packs
    var all_objects = std.array_list.Managed([20]u8).init(allocator);
    defer all_objects.deinit();

    const objects_dir_path = std.fmt.allocPrint(allocator, "{s}/objects", .{git_dir}) catch return;
    defer allocator.free(objects_dir_path);

    // Enumerate loose helpers.objects
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
                var full_hex: [40]u8 = undefined;
                _ = std.fmt.bufPrint(&full_hex, "{s}{s}", .{ hex_buf, entry.name }) catch continue;
                var sha: [20]u8 = undefined;
                for (&sha, 0..) |*b, bi| {
                    b.* = std.fmt.parseInt(u8, full_hex[bi * 2 .. bi * 2 + 2], 16) catch continue;
                }
                try all_objects.append(sha);
            }
        }
    }

    // helpers.Also collect helpers.objects from existing packs
    var object_hashes = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (object_hashes.items) |h| allocator.free(h);
        object_hashes.deinit();
    }

    // helpers.Convert loose object SHAs to hex strings
    for (all_objects.items) |sha| {
        var hex: [40]u8 = undefined;
        for (sha, 0..) |b, bi| {
            _ = std.fmt.bufPrint(hex[bi * 2 .. bi * 2 + 2], "{x:0>2}", .{b}) catch continue;
        }
        try object_hashes.append(try allocator.dupe(u8, &hex));
    }

    // helpers.Also enumerate helpers.objects in existing pack files
    const pack_dir = std.fmt.allocPrint(allocator, "{s}/objects/pack", .{git_dir}) catch return;
    defer allocator.free(pack_dir);
    std.fs.cwd().makePath(pack_dir) catch {};

    var existing_packs = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (existing_packs.items) |p| allocator.free(p);
        existing_packs.deinit();
    }

    if (std.fs.cwd().openDir(pack_dir, .{ .iterate = true })) |pd| {
        var pack_d = pd;
        defer pack_d.close();
        var pack_iter = pack_d.iterate();
        while (pack_iter.next() catch null) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".idx")) {
                try existing_packs.append(try allocator.dupe(u8, entry.name));
                // helpers.Read idx to get object list
                const idx_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ pack_dir, entry.name }) catch continue;
                defer allocator.free(idx_path);
                const idx_data = std.fs.cwd().readFileAlloc(allocator, idx_path, 100 * 1024 * 1024) catch continue;
                defer allocator.free(idx_data);

                if (idx_data.len > 8 and std.mem.eql(u8, idx_data[0..4], "\xfftOc")) {
                    const num_objects_packed = std.mem.readInt(u32, idx_data[8 + 255 * 4 ..][0..4], .big);
                    const sha_offset: usize = 8 + 256 * 4;
                    var obj_idx: usize = 0;
                    while (obj_idx < num_objects_packed) : (obj_idx += 1) {
                        const sha_start = sha_offset + obj_idx * 20;
                        if (sha_start + 20 > idx_data.len) break;
                        const sha_bytes = idx_data[sha_start .. sha_start + 20];
                        var hex: [40]u8 = undefined;
                        for (sha_bytes, 0..) |b, bi| {
                            _ = std.fmt.bufPrint(hex[bi * 2 .. bi * 2 + 2], "{x:0>2}", .{b}) catch continue;
                        }
                        // Don't duplicate
                        var already_have = false;
                        for (object_hashes.items) |existing| {
                            if (std.mem.eql(u8, existing, &hex)) {
                                already_have = true;
                                break;
                            }
                        }
                        if (!already_have) {
                            try object_hashes.append(try allocator.dupe(u8, &hex));
                        }
                    }
                }
            }
        }
    } else |_| {}

    // helpers.If no helpers.objects at all, nothing to do
    if (object_hashes.items.len == 0) return;

    // helpers.Build pack data, tracking offsets and SHA-1s for idx generation
    var pack_data = std.array_list.Managed(u8).init(allocator);
    defer pack_data.deinit();

    var pack_entries = std.array_list.Managed(helpers.PackIdxEntry).init(allocator);
    defer pack_entries.deinit();

    // Pack header
    try pack_data.appendSlice("PACK");
    const version: u32 = 2;
    try pack_data.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, version)));
    // We'll patch the object count after writing (some helpers.objects may fail to load)
    const count_offset = pack_data.items.len;
    try pack_data.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, 0)));

    // helpers.Write each object
    for (object_hashes.items) |hash| {
        if (objects.GitObject.load(hash, git_dir, platform_impl, allocator)) |obj| {
            defer obj.deinit(allocator);

            // helpers.Parse hex hash to binary SHA
            var sha_bytes: [20]u8 = undefined;
            for (&sha_bytes, 0..) |*b, bi| {
                b.* = std.fmt.parseInt(u8, hash[bi * 2 .. bi * 2 + 2], 16) catch 0;
            }

            const entry_offset: u32 = @intCast(pack_data.items.len);
            const type_num: u8 = switch (obj.type) {
                .commit => 1,
                .tree => 2,
                .blob => 3,
                .tag => 4,
            };
            var obj_size = obj.data.len;
            var first_byte: u8 = (type_num << 4) | @as(u8, @intCast(obj_size & 0x0F));
            obj_size >>= 4;
            if (obj_size > 0) first_byte |= 0x80;
            try pack_data.append(first_byte);
            while (obj_size > 0) {
                var byte: u8 = @intCast(obj_size & 0x7F);
                obj_size >>= 7;
                if (obj_size > 0) byte |= 0x80;
                try pack_data.append(byte);
            }
            // Compress data
            const compressed = zlib_compat_mod.compressSlice(allocator, obj.data) catch continue;
            defer allocator.free(compressed);
            try pack_data.appendSlice(compressed);

            // CRC32 over the entire entry (header + compressed data)
            const entry_data = pack_data.items[entry_offset..];
            const crc = std.hash.crc.Crc32.hash(entry_data);

            try pack_entries.append(.{ .sha = sha_bytes, .offset = entry_offset, .crc = crc });
        } else |_| {
            continue;
        }
    }

    // cmd_apply.Patch actual object count
    const actual_count: u32 = @intCast(pack_entries.items.len);
    @memcpy(pack_data.items[count_offset..][0..4], &std.mem.toBytes(std.mem.nativeToBig(u32, actual_count)));

    // helpers.Compute helpers.SHA1 checksum of pack data
    var sha1 = std.crypto.hash.Sha1.init(.{});
    sha1.update(pack_data.items);
    const checksum = sha1.finalResult();
    try pack_data.appendSlice(&checksum);

    // helpers.Write pack file
    var hash_hex: [40]u8 = undefined;
    for (checksum, 0..) |b, bi| {
        _ = std.fmt.bufPrint(hash_hex[bi * 2 .. bi * 2 + 2], "{x:0>2}", .{b}) catch continue;
    }

    const pack_filename = std.fmt.allocPrint(allocator, "{s}/pack-{s}.pack", .{ pack_dir, hash_hex }) catch return;
    defer allocator.free(pack_filename);
    std.fs.cwd().writeFile(.{ .sub_path = pack_filename, .data = pack_data.items }) catch return;

    // helpers.Generate idx directly from tracked entries (no re-parsing needed)
    try cmd_pack.generatePackIdxFromEntries(allocator, pack_entries.items, &checksum, pack_dir, &hash_hex);

    // helpers.Delete old pack files (but not the newly created one)
    const new_idx_name = std.fmt.allocPrint(allocator, "pack-{s}.idx", .{hash_hex}) catch "";
    defer if (new_idx_name.len > 0) allocator.free(new_idx_name);
    for (existing_packs.items) |old_idx| {
        // helpers.Skip if this is our newly created pack
        if (std.mem.eql(u8, old_idx, new_idx_name)) continue;
        const old_idx_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ pack_dir, old_idx }) catch continue;
        defer allocator.free(old_idx_path);
        std.fs.cwd().deleteFile(old_idx_path) catch {};
        // helpers.Also delete .pack
        if (std.mem.endsWith(u8, old_idx, ".idx")) {
            const base = old_idx[0 .. old_idx.len - 4];
            const old_pack_path = std.fmt.allocPrint(allocator, "{s}/{s}.pack", .{ pack_dir, base }) catch continue;
            defer allocator.free(old_pack_path);
            std.fs.cwd().deleteFile(old_pack_path) catch {};
        }
    }

    // helpers.Delete loose helpers.objects that are now in the pack
    for (all_objects.items) |sha| {
        var hex: [40]u8 = undefined;
        for (sha, 0..) |b, bi| {
            _ = std.fmt.bufPrint(hex[bi * 2 .. bi * 2 + 2], "{x:0>2}", .{b}) catch continue;
        }
        const loose_path = std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ objects_dir_path, hex[0..2], hex[2..] }) catch continue;
        defer allocator.free(loose_path);
        std.fs.cwd().deleteFile(loose_path) catch {};
    }

    // helpers.Update objects/info/packs to list current pack files
    {
        const obj_info_dir = std.fmt.allocPrint(allocator, "{s}/objects/info", .{git_dir}) catch return;
        defer allocator.free(obj_info_dir);
        std.fs.cwd().makePath(obj_info_dir) catch {};

        const packs_file_path = std.fmt.allocPrint(allocator, "{s}/objects/info/packs", .{git_dir}) catch return;
        defer allocator.free(packs_file_path);

        var content = std.array_list.Managed(u8).init(allocator);
        defer content.deinit();

        if (std.fs.cwd().openDir(pack_dir, .{ .iterate = true })) |pd| {
            var pack_d2 = pd;
            defer pack_d2.close();
            var pack_names2 = std.array_list.Managed([]const u8).init(allocator);
            defer {
                for (pack_names2.items) |n| allocator.free(n);
                pack_names2.deinit();
            }
            var iter2 = pack_d2.iterate();
            while (iter2.next() catch null) |entry| {
                if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".pack")) {
                    pack_names2.append(allocator.dupe(u8, entry.name) catch continue) catch {};
                }
            }
            std.mem.sort([]const u8, pack_names2.items, {}, struct {
                fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.order(u8, a, b).compare(.lt);
                }
            }.lessThan);
            for (pack_names2.items) |name| {
                const line = std.fmt.allocPrint(allocator, "P {s}\n", .{name}) catch continue;
                defer allocator.free(line);
                content.appendSlice(line) catch {};
            }
        } else |_| {}
        content.append('\n') catch {};
        std.fs.cwd().writeFile(.{ .sub_path = packs_file_path, .data = content.items }) catch {};
    }
}
