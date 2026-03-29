// Auto-generated from main_common.zig - cmd_verify_pack
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

pub fn nativeCmdVerifyPack(allocator: std.mem.Allocator, args: [][]const u8, command_index: usize, platform_impl: *const platform_mod.Platform) !void {
    var verbose = false;
    var stat_only = false;
    var pack_files = std.ArrayList([]const u8).init(allocator);
    defer pack_files.deinit();

    var i = command_index + 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--stat-only")) {
            stat_only = true;
        } else if (std.mem.eql(u8, arg, "-h")) {
            try platform_impl.writeStdout("usage: git verify-pack [-v | --verbose] [-s | --stat-only] [--] <pack>.idx...\n");
            std.process.exit(129);
        } else if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            while (i < args.len) : (i += 1) {
                try pack_files.append(args[i]);
            }
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try pack_files.append(arg);
        }
    }

    if (pack_files.items.len == 0) {
        try platform_impl.writeStderr("usage: git verify-pack [-v | --verbose] [-s | --stat-only] [--] <pack>.idx...\n");
        std.process.exit(1);
    }

    var any_error = false;
    for (pack_files.items) |pack_file| {
        // helpers.Determine pack and idx file paths
        var pack_path_alloc: ?[]const u8 = null;
        var idx_path_alloc: ?[]const u8 = null;
        defer if (pack_path_alloc) |p| allocator.free(p);
        defer if (idx_path_alloc) |p| allocator.free(p);

        var pack_path: []const u8 = undefined;
        var idx_path: []const u8 = undefined;

        if (std.mem.endsWith(u8, pack_file, ".idx")) {
            idx_path = pack_file;
            const base = pack_file[0 .. pack_file.len - 4];
            pack_path_alloc = std.fmt.allocPrint(allocator, "{s}.pack", .{base}) catch continue;
            pack_path = pack_path_alloc.?;
        } else if (std.mem.endsWith(u8, pack_file, ".pack")) {
            pack_path = pack_file;
            const base = pack_file[0 .. pack_file.len - 5];
            idx_path_alloc = std.fmt.allocPrint(allocator, "{s}.idx", .{base}) catch continue;
            idx_path = idx_path_alloc.?;
        } else {
            pack_path = pack_file;
            idx_path = pack_file;
        }

        // helpers.Read pack file
        const pack_data = std.fs.cwd().readFileAlloc(allocator, pack_path, 4 * 1024 * 1024 * 1024) catch {
            const msg = std.fmt.allocPrint(allocator, "error: packfile {s} not found.\n", .{pack_path}) catch continue;
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            any_error = true;
            continue;
        };
        defer allocator.free(pack_data);

        // helpers.Verify pack header
        if (pack_data.len < 12 or !std.mem.eql(u8, pack_data[0..4], "PACK")) {
            const msg = std.fmt.allocPrint(allocator, "error: {s}: packfile signature mismatch\n", .{pack_path}) catch continue;
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            any_error = true;
            continue;
        }

        const pack_version = std.mem.readInt(u32, pack_data[4..8], .big);
        if (pack_version != 2 and pack_version != 3) {
            const msg = std.fmt.allocPrint(allocator, "error: {s}: unsupported pack version {d}\n", .{ pack_path, pack_version }) catch continue;
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            any_error = true;
            continue;
        }

        // helpers.Verify pack checksum
        if (pack_data.len >= 20) {
            var sha1 = std.crypto.hash.Sha1.init(.{});
            sha1.update(pack_data[0 .. pack_data.len - 20]);
            const computed = sha1.finalResult();
            const stored = pack_data[pack_data.len - 20 ..][0..20];
            if (!std.mem.eql(u8, &computed, stored)) {
                const msg = std.fmt.allocPrint(allocator, "error: {s}: pack checksum mismatch\n", .{pack_path}) catch continue;
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                any_error = true;
                continue;
            }
        }

        // helpers.Read idx file to verify pack checksum in idx matches
        const idx_data = std.fs.cwd().readFileAlloc(allocator, idx_path, 100 * 1024 * 1024) catch {
            const msg = std.fmt.allocPrint(allocator, "error: packfile {s} index not found.\n", .{idx_path}) catch continue;
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            any_error = true;
            continue;
        };
        defer allocator.free(idx_data);

        // helpers.Verify idx checksum
        if (idx_data.len >= 40) {
            // helpers.The last 20 bytes of idx is the idx helpers.SHA1
            // helpers.The 20 bytes before that is the pack helpers.SHA1
            const idx_pack_checksum = idx_data[idx_data.len - 40 .. idx_data.len - 20];
            const pack_trailing = pack_data[pack_data.len - 20 ..];
            if (!std.mem.eql(u8, idx_pack_checksum, pack_trailing)) {
                const msg = std.fmt.allocPrint(allocator, "error: packfile {s} does not match index\n", .{pack_path}) catch continue;
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                any_error = true;
                continue;
            }

            // helpers.Verify idx's own checksum
            var idx_sha = std.crypto.hash.Sha1.init(.{});
            idx_sha.update(idx_data[0 .. idx_data.len - 20]);
            const idx_computed = idx_sha.finalResult();
            const idx_stored = idx_data[idx_data.len - 20 ..][0..20];
            if (!std.mem.eql(u8, &idx_computed, idx_stored)) {
                const msg = std.fmt.allocPrint(allocator, "error: index file {s} checksum mismatch\n", .{idx_path}) catch continue;
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                any_error = true;
                continue;
            }
        }

        const num_objects = std.mem.readInt(u32, pack_data[8..12], .big);

        if (verbose and !stat_only) {
            // helpers.In verbose mode, list each object in the pack
            var pos: usize = 12;
            var obj_idx: u32 = 0;
            while (obj_idx < num_objects and pos < pack_data.len -| 20) : (obj_idx += 1) {
                const entry_offset = pos;
                var c = pack_data[pos];
                pos += 1;
                const obj_type = (pack_data[entry_offset] >> 4) & 0x07;
                var obj_size: u64 = c & 0x0F;
                var shift: u6 = 4;
                while (c & 0x80 != 0 and pos < pack_data.len) {
                    c = pack_data[pos];
                    pos += 1;
                    obj_size |= @as(u64, c & 0x7F) << shift;
                    shift +|= 7;
                }

                // helpers.Handle delta base helpers.refs
                var delta_base_offset: ?u64 = null;
                var delta_base_ref: ?[20]u8 = null;
                if (obj_type == 6) {
                    c = pack_data[pos];
                    pos += 1;
                    var ofs: u64 = c & 0x7F;
                    while (c & 0x80 != 0 and pos < pack_data.len) {
                        c = pack_data[pos];
                        pos += 1;
                        ofs = ((ofs + 1) << 7) | (c & 0x7F);
                    }
                    delta_base_offset = ofs;
                } else if (obj_type == 7) {
                    if (pos + 20 <= pack_data.len) {
                        delta_base_ref = pack_data[pos..][0..20].*;
                        pos += 20;
                    }
                }

                // helpers.Decompress
                const decomp = zlib_compat_mod.decompressSliceWithConsumed(allocator, pack_data[pos..]) catch {
                    pos = pack_data.len -| 20;
                    continue;
                };
                defer allocator.free(decomp.data);
                pos += decomp.consumed;

                // helpers.Compute object hash
                const type_str: []const u8 = switch (obj_type) {
                    1 => "commit",
                    2 => "tree",
                    3 => "blob",
                    4 => "tag",
                    6 => "ofs_delta",
                    7 => "ref_delta",
                    else => "unknown",
                };

                if (obj_type >= 1 and obj_type <= 4) {
                    const hdr = std.fmt.allocPrint(allocator, "{s} {d}\x00", .{ type_str, decomp.data.len }) catch continue;
                    defer allocator.free(hdr);
                    var hasher = std.crypto.hash.Sha1.init(.{});
                    hasher.update(hdr);
                    hasher.update(decomp.data);
                    const sha = hasher.finalResult();
                    var hash_hex: [40]u8 = undefined;
                    for (sha, 0..) |b, bi| {
                        const hc = "0123456789abcdef";
                        hash_hex[bi * 2] = hc[b >> 4];
                        hash_hex[bi * 2 + 1] = hc[b & 0xf];
                    }
                    const out = std.fmt.allocPrint(allocator, "{s} {s: <6} {d} {d} {d}\n", .{ hash_hex, type_str, decomp.data.len, pos - entry_offset, entry_offset }) catch continue;
                    defer allocator.free(out);
                    try platform_impl.writeStdout(out);
                } else if (obj_type == 6 and delta_base_offset != null) {
                    const out = std.fmt.allocPrint(allocator, "non delta: {s} {d} {d} {d} {d}\n", .{ type_str, obj_size, decomp.data.len, pos - entry_offset, entry_offset }) catch continue;
                    defer allocator.free(out);
                    try platform_impl.writeStdout(out);
                } else if (obj_type == 7 and delta_base_ref != null) {
                    const out = std.fmt.allocPrint(allocator, "non delta: {s} {d} {d} {d} {d}\n", .{ type_str, obj_size, decomp.data.len, pos - entry_offset, entry_offset }) catch continue;
                    defer allocator.free(out);
                    try platform_impl.writeStdout(out);
                }
            }
        }

        // helpers.Output summary
        if (verbose and !stat_only) {
            const summary = std.fmt.allocPrint(allocator, "non delta: {d} object{s}\n{s}: ok\n", .{
                num_objects,
                if (num_objects == 1) "" else "s",
                pack_path,
            }) catch "";
            if (summary.len > 0) {
                defer allocator.free(summary);
                try platform_impl.writeStdout(summary);
            }
        }
    }

    if (any_error) {
        std.process.exit(1);
    }
}
