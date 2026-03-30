// Auto-generated from main_common.zig - cmd_pack
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

pub fn nativeCmdPackObjects(allocator: std.mem.Allocator, args: [][]const u8, command_index: usize, platform_impl: *const platform_mod.Platform) !void {
    var base_name: ?[]const u8 = null;
    var stdout_mode = false;
    var progress = true;
    var revs_mode = false;
    var use_all = false;
    var stdin_packs = false;
    var write_bitmap = false;
    var name_hash_version: i32 = 1;
    var include_tag = false;

    var i = command_index + 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--stdin")) {
            try platform_impl.writeStderr("fatal: disallowed abbreviated or ambiguous option 'stdin'\n");
            std.process.exit(1);
            unreachable;
        } else if (std.mem.eql(u8, arg, "--stdout")) {
            stdout_mode = true;
        } else if (std.mem.eql(u8, arg, "--all-progress") or std.mem.eql(u8, arg, "--all-progress-implied")) {
            // accepted
        } else if (std.mem.eql(u8, arg, "-q")) {
            progress = false;
        } else if (std.mem.eql(u8, arg, "--progress")) {
            progress = true;
        } else if (std.mem.eql(u8, arg, "--revs")) {
            revs_mode = true;
        } else if (std.mem.eql(u8, arg, "--stdin-packs")) {
            stdin_packs = true;
        } else if (std.mem.eql(u8, arg, "--all")) {
            use_all = true;
        } else if (std.mem.eql(u8, arg, "--no-reuse-delta") or std.mem.eql(u8, arg, "--no-reuse-object")) {
            // accepted
        } else if (std.mem.eql(u8, arg, "--include-tag")) {
            include_tag = true;
        } else if (std.mem.eql(u8, arg, "--thin") or
            std.mem.eql(u8, arg, "--delta-base-offset") or
            std.mem.eql(u8, arg, "--keep-true-parents") or std.mem.eql(u8, arg, "--honor-pack-keep") or
            std.mem.eql(u8, arg, "--non-empty") or std.mem.eql(u8, arg, "--all") or
            std.mem.eql(u8, arg, "--local") or std.mem.eql(u8, arg, "--incremental") or
            std.mem.eql(u8, arg, "--unpacked") or std.mem.eql(u8, arg, "--no-path-walk") or
            std.mem.eql(u8, arg, "--path-walk") or std.mem.eql(u8, arg, "--reflog") or
            std.mem.eql(u8, arg, "--indexed-objects") or std.mem.eql(u8, arg, "--unpack-unreachable"))
        {
            // Accepted flags
        } else if (std.mem.eql(u8, arg, "--write-bitmap-index")) {
            write_bitmap = true;
        } else if (std.mem.startsWith(u8, arg, "--index-version=")) {
            // helpers.Validate --index-version=<ver>[,<offset>]
            const val = arg["--index-version=".len..];
            if (std.mem.indexOfScalar(u8, val, ',')) |comma_pos| {
                const ver_str = val[0..comma_pos];
                const off_str = val[comma_pos + 1 ..];
                const ver = std.fmt.parseInt(u32, ver_str, 10) catch {
                    const msg = try std.fmt.allocPrint(allocator, "bad index version '{s}'\n", .{val});
                    defer allocator.free(msg);
                    try platform_impl.writeStderr(msg);
                    std.process.exit(1);
                    unreachable;
                };
                if (ver < 1 or ver > 2) {
                    const msg = try std.fmt.allocPrint(allocator, "bad index version '{s}'\n", .{val});
                    defer allocator.free(msg);
                    try platform_impl.writeStderr(msg);
                    std.process.exit(1);
                    unreachable;
                }
                if (off_str.len == 0) {
                    const msg = try std.fmt.allocPrint(allocator, "bad index version '{s}'\n", .{val});
                    defer allocator.free(msg);
                    try platform_impl.writeStderr(msg);
                    std.process.exit(1);
                    unreachable;
                }
                // helpers.Parse offset (may be hex with 0x prefix)
                if (std.mem.startsWith(u8, off_str, "0x") or std.mem.startsWith(u8, off_str, "0X")) {
                    _ = std.fmt.parseInt(u64, off_str[2..], 16) catch {
                        const msg = try std.fmt.allocPrint(allocator, "bad index version '{s}'\n", .{val});
                        defer allocator.free(msg);
                        try platform_impl.writeStderr(msg);
                        std.process.exit(1);
                        unreachable;
                    };
                } else {
                    _ = std.fmt.parseInt(u64, off_str, 10) catch {
                        const msg = try std.fmt.allocPrint(allocator, "bad index version '{s}'\n", .{val});
                        defer allocator.free(msg);
                        try platform_impl.writeStderr(msg);
                        std.process.exit(1);
                        unreachable;
                    };
                }
            } else {
                const ver = std.fmt.parseInt(u32, val, 10) catch {
                    const msg = try std.fmt.allocPrint(allocator, "bad index version '{s}'\n", .{val});
                    defer allocator.free(msg);
                    try platform_impl.writeStderr(msg);
                    std.process.exit(1);
                    unreachable;
                };
                if (ver < 1 or ver > 2) {
                    const msg = try std.fmt.allocPrint(allocator, "bad index version '{s}'\n", .{val});
                    defer allocator.free(msg);
                    try platform_impl.writeStderr(msg);
                    std.process.exit(1);
                    unreachable;
                }
            }
        } else if (std.mem.startsWith(u8, arg, "--name-hash-version=")) {
            // helpers.Validate --name-hash-version=<ver>
            const val = arg["--name-hash-version=".len..];
            const ver = std.fmt.parseInt(i32, val, 10) catch {
                const msg = try std.fmt.allocPrint(allocator, "error: invalid --name-hash-version option: '{s}'\n", .{val});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(1);
                unreachable;
            };
            if (ver == 0 or ver > 2) {
                try platform_impl.writeStderr("error: invalid --name-hash-version option\n");
                std.process.exit(1);
                unreachable;
            }
            // Negative values are treated as version 1
            name_hash_version = if (ver < 0) 1 else ver;
        } else if (std.mem.startsWith(u8, arg, "--window=") or
            std.mem.startsWith(u8, arg, "--depth=") or
            std.mem.startsWith(u8, arg, "--threads=") or
            std.mem.startsWith(u8, arg, "--max-pack-size=") or
            std.mem.startsWith(u8, arg, "--compression=") or
            std.mem.startsWith(u8, arg, "--filter=") or
            std.mem.startsWith(u8, arg, "--unpack-unreachable="))
        {
            // Accepted with value
        } else if (std.mem.eql(u8, arg, "-h")) {
            try platform_impl.writeStdout("usage: git pack-helpers.objects [<options>] base-name\n");
            std.process.exit(129);
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (base_name != null) {
                try platform_impl.writeStderr("usage: git pack-helpers.objects [<options>] base-name\n");
                std.process.exit(1);
            }
            base_name = arg;
        }
    }

    // helpers.Check incompatible options
    if (stdin_packs and revs_mode) {
        try platform_impl.writeStderr("error: --stdin-packs is incompatible with --revs\n");
        std.process.exit(1);
        unreachable;
    }

    // Warn about --write-bitmap-index with --name-hash-version=2
    if (write_bitmap and name_hash_version == 2 and !stdout_mode) {
        try platform_impl.writeStderr("warning: currently, --write-bitmap-index requires --name-hash-version=1\n");
    }

    if (base_name == null and !stdout_mode) {
        try platform_impl.writeStderr("usage: git pack-helpers.objects [<options>] base-name\n");
        std.process.exit(1);
    }

    const git_dir = helpers.findGitDir() catch {
        try platform_impl.writeStderr("fatal: not a git repository\n");
        std.process.exit(128);
        unreachable;
    };

    // helpers.Read stdin
    const stdin = std.fs.File{ .handle = std.posix.STDIN_FILENO };
    const stdin_data = stdin.readToEndAlloc(allocator, 100 * 1024 * 1024) catch {
        try platform_impl.writeStderr("fatal: error reading stdin\n");
        std.process.exit(128);
        unreachable;
    };
    defer allocator.free(stdin_data);

    // helpers.Collect object hashes to pack (deduplicated)
    var object_set = std.StringHashMap(void).init(allocator);
    defer object_set.deinit();
    var object_hashes = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (object_hashes.items) |h| allocator.free(h);
        object_hashes.deinit();
    }

    if (stdin_packs) {
        // --stdin-packs mode: each line is a pack name (without path)
        // helpers.Look for matching packs in objects/pack/ directory
        var lines_iter = std.mem.splitScalar(u8, stdin_data, '\n');
        while (lines_iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            // helpers.Check if the pack exists
            const pack_path = std.fmt.allocPrint(allocator, "{s}/objects/pack/pack-{s}.idx", .{ git_dir, trimmed }) catch continue;
            defer allocator.free(pack_path);
            std.fs.cwd().access(pack_path, .{}) catch {
                const msg = try std.fmt.allocPrint(allocator, "fatal: could not find pack '{s}'\n", .{trimmed});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(1);
                unreachable;
            };
            // TODO: actually read helpers.objects from the pack
        }
    } else if (revs_mode) {
        // --revs mode: treat stdin as revision arguments and walk reachable helpers.objects
        // An empty line terminates the revision input (matching git's behavior)
        var lines_iter = std.mem.splitScalar(u8, stdin_data, '\n');
        while (lines_iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) break; // empty line terminates revision input
            if (trimmed[0] == '^') continue; // exclude ref

            var resolved: ?[]const u8 = null;
            if (trimmed.len >= 40) {
                const maybe_hash = trimmed[0..40];
                var is_hex = true;
                for (maybe_hash) |ch| {
                    if (!std.ascii.isHex(ch)) { is_hex = false; break; }
                }
                if (is_hex) resolved = try allocator.dupe(u8, maybe_hash);
            }
            if (resolved == null) {
                resolved = refs.resolveRef(git_dir, trimmed, platform_impl, allocator) catch {
                    const msg = try std.fmt.allocPrint(allocator, "fatal: bad revision '{s}'\n", .{trimmed});
                    defer allocator.free(msg);
                    try platform_impl.writeStderr(msg);
                    std.process.exit(128);
                    unreachable;
                };
            }
            if (resolved) |hash| {
                defer allocator.free(hash);
                try packObjectsWalkReachable(allocator, git_dir, hash, &object_set, &object_hashes, platform_impl);
            }
        }
    } else {
        // Non-revs mode: each line is an object ID, optionally followed by a name hint
        // Lines starting with '-' are exclude markers (object should not be packed)
        var exclude_set = std.StringHashMap(void).init(allocator);
        defer exclude_set.deinit();
        var lines_iter = std.mem.splitScalar(u8, stdin_data, '\n');
        while (lines_iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) {
                if (line.len > 0 or (lines_iter.peek() != null)) {
                    const msg = try std.fmt.allocPrint(allocator, "fatal: expected object ID, got garbage:\n {s}\n\n", .{line});
                    defer allocator.free(msg);
                    try platform_impl.writeStderr(msg);
                    std.process.exit(128);
                    unreachable;
                }
                continue;
            }

            // helpers.Handle exclude lines: -<hash>
            const is_exclude = trimmed[0] == '-';
            const id_start: usize = if (is_exclude) 1 else 0;
            const rest = trimmed[id_start..];

            // helpers.Extract hash (first 40 hex chars), rest may be " name"
            const hash_end = @min(rest.len, 40);
            if (hash_end < 40) {
                const msg = try std.fmt.allocPrint(allocator, "fatal: expected object ID, got garbage:\n {s}\n\n", .{trimmed});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(128);
                unreachable;
            }
            const hash = rest[0..40];
            var valid = true;
            for (hash) |ch| {
                if (!std.ascii.isHex(ch)) { valid = false; break; }
            }
            if (!valid) {
                const msg = try std.fmt.allocPrint(allocator, "fatal: expected object ID, got garbage:\n {s}\n\n", .{trimmed});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(128);
                unreachable;
            }

            if (is_exclude) {
                const duped = try allocator.dupe(u8, hash);
                try exclude_set.put(duped, {});
            } else {
                if (!object_set.contains(hash)) {
                    const duped = try allocator.dupe(u8, hash);
                    try object_set.put(duped, {});
                    try object_hashes.append(duped);
                }
            }
        }

        // helpers.Remove excluded helpers.objects
        if (exclude_set.count() > 0) {
            var excl_idx: usize = 0;
            while (excl_idx < object_hashes.items.len) {
                if (exclude_set.contains(object_hashes.items[excl_idx])) {
                    _ = object_set.remove(object_hashes.items[excl_idx]);
                    allocator.free(object_hashes.items[excl_idx]);
                    _ = object_hashes.orderedRemove(excl_idx);
                } else {
                    excl_idx += 1;
                }
            }
        }
    }

    if (use_all) {
        try packObjectsAddAllObjects(allocator, git_dir, &object_set, &object_hashes);
    }

    // --include-tag: find tags whose target is already in the object set
    if (include_tag) {
        // helpers.Scan refs/tags/ for tag helpers.objects
        const tags_dir_path = std.fmt.allocPrint(allocator, "{s}/refs/tags", .{git_dir}) catch unreachable;
        defer allocator.free(tags_dir_path);
        if (std.fs.cwd().openDir(tags_dir_path, .{ .iterate = true })) |dir_val| {
            var dir = dir_val;
            defer dir.close();
            var iter = dir.iterate();
            while (iter.next() catch null) |entry| {
                if (entry.kind == .directory) continue;
                // helpers.Read the ref file directly to get the raw hash (don't peel)
                const ref_file_path = std.fmt.allocPrint(allocator, "{s}/refs/tags/{s}", .{git_dir, entry.name}) catch continue;
                defer allocator.free(ref_file_path);
                const ref_content = std.fs.cwd().readFileAlloc(allocator, ref_file_path, 4096) catch continue;
                defer allocator.free(ref_content);
                const tag_hash = std.mem.trim(u8, ref_content, " \t\r\n");
                if (tag_hash.len < 40) continue;
                const tag_hash_40 = tag_hash[0..40];

                // helpers.Check if it's a tag object
                if (objects.GitObject.load(tag_hash_40, git_dir, platform_impl, allocator)) |tag_obj| {
                    defer tag_obj.deinit(allocator);
                    if (tag_obj.type == .tag) {
                        // helpers.Parse target from tag object
                        if (std.mem.indexOf(u8, tag_obj.data, "object ")) |obj_start| {
                            const hash_start = obj_start + 7;
                            if (hash_start + 40 <= tag_obj.data.len) {
                                const target_hash = tag_obj.data[hash_start..hash_start + 40];
                                // helpers.If target is in the pack, include the tag too
                                if (object_set.contains(target_hash)) {
                                    if (!object_set.contains(tag_hash_40)) {
                                        const duped = allocator.dupe(u8, tag_hash_40) catch continue;
                                        object_set.put(duped, {}) catch continue;
                                        object_hashes.append(duped) catch continue;
                                    }
                                }
                            }
                        }
                    }
                } else |_| {}
            }
        } else |_| {}

        // helpers.Also check packed-helpers.refs for tags
        const packed_refs_path = std.fmt.allocPrint(allocator, "{s}/packed-refs", .{git_dir}) catch unreachable;
        defer allocator.free(packed_refs_path);
        if (std.fs.cwd().readFileAlloc(allocator, packed_refs_path, 10 * 1024 * 1024)) |packed_data| {
            defer allocator.free(packed_data);
            var plines = std.mem.splitScalar(u8, packed_data, '\n');
            while (plines.next()) |pline| {
                if (pline.len == 0 or pline[0] == '#' or pline[0] == '^') continue;
                if (pline.len < 41) continue;
                const phash = pline[0..40];
                const pref = std.mem.trim(u8, pline[41..], " \t\r");
                if (!std.mem.startsWith(u8, pref, "refs/tags/")) continue;

                // helpers.Check if it's a tag object
                if (objects.GitObject.load(phash, git_dir, platform_impl, allocator)) |tag_obj| {
                    defer tag_obj.deinit(allocator);
                    if (tag_obj.type == .tag) {
                        if (std.mem.indexOf(u8, tag_obj.data, "object ")) |obj_start| {
                            const hash_start = obj_start + 7;
                            if (hash_start + 40 <= tag_obj.data.len) {
                                const target_hash = tag_obj.data[hash_start..hash_start + 40];
                                if (object_set.contains(target_hash)) {
                                    if (!object_set.contains(phash)) {
                                        const duped = allocator.dupe(u8, phash) catch continue;
                                        object_set.put(duped, {}) catch continue;
                                        object_hashes.append(duped) catch continue;
                                    }
                                }
                            }
                        }
                    }
                } else |_| {}
            }
        } else |_| {}
    }

    // helpers.Build the pack
    var pack_data = std.array_list.Managed(u8).init(allocator);
    defer pack_data.deinit();

    try pack_data.appendSlice("PACK");
    const version: u32 = 2;
    try pack_data.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, version)));
    const count_pos = pack_data.items.len;
    try pack_data.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, 0)));

    var actual_count: u32 = 0;
    for (object_hashes.items) |hash| {
        if (objects.GitObject.load(hash, git_dir, platform_impl, allocator)) |obj| {
            defer obj.deinit(allocator);
            const type_num: u8 = switch (obj.type) {
                .commit => 1, .tree => 2, .blob => 3, .tag => 4,
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
            const compressed = if (@import("builtin").target.os.tag == .freestanding or @import("builtin").target.os.tag == .wasi)
                zlib_compat_mod.compressSlice(allocator, obj.data) catch continue
            else
                objects.cCompressSlice(allocator, obj.data) catch continue;
            defer allocator.free(compressed);
            try pack_data.appendSlice(compressed);
            actual_count += 1;
        } else |_| { continue; }
    }

    const count_bytes = std.mem.toBytes(std.mem.nativeToBig(u32, actual_count));
    @memcpy(pack_data.items[count_pos..][0..4], &count_bytes);

    var sha1 = std.crypto.hash.Sha1.init(.{});
    sha1.update(pack_data.items);
    const checksum = sha1.finalResult();
    try pack_data.appendSlice(&checksum);

    if (stdout_mode) {
        const stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
        stdout.writeAll(pack_data.items) catch {};
    } else if (base_name) |name| {
        var hash_hex: [40]u8 = undefined;
        for (checksum, 0..) |b, bi| {
            _ = std.fmt.bufPrint(hash_hex[bi * 2 .. bi * 2 + 2], "{x:0>2}", .{b}) catch continue;
        }
        const pack_filename = std.fmt.allocPrint(allocator, "{s}-{s}.pack", .{ name, hash_hex }) catch unreachable;
        defer allocator.free(pack_filename);
        std.fs.cwd().writeFile(.{ .sub_path = pack_filename, .data = pack_data.items }) catch |err| {
            const msg = std.fmt.allocPrint(allocator, "fatal: unable to write pack file: {s}\n", .{@errorName(err)}) catch unreachable;
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
        };
        const idx_filename = std.fmt.allocPrint(allocator, "{s}-{s}.idx", .{ name, hash_hex }) catch unreachable;
        defer allocator.free(idx_filename);
        generatePackIdxToFile(allocator, pack_data.items, idx_filename) catch {};
        const output = std.fmt.allocPrint(allocator, "{s}\n", .{hash_hex}) catch unreachable;
        defer allocator.free(output);
        try platform_impl.writeStdout(output);
    }

    if (progress) {
        const count_msg = std.fmt.allocPrint(allocator, "Total {d} (delta 0), reused 0 (delta 0), pack-reused 0\n", .{actual_count}) catch unreachable;
        defer allocator.free(count_msg);
        try platform_impl.writeStderr(count_msg);
    }
}


pub fn nativeCmdIndexPack(allocator: std.mem.Allocator, args: [][]const u8, command_index: usize, platform_impl: *const platform_mod.Platform) !void {
    var stdin_mode = false;
    var verify = false;
    var verbose = false;
    var strict = false;
    var pack_file: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;

    var i = command_index + 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--stdin")) {
            stdin_mode = true;
        } else if (std.mem.eql(u8, arg, "--verify")) {
            verify = true;
        } else if (std.mem.eql(u8, arg, "-v")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i < args.len) output_path = args[i];
        } else if (std.mem.eql(u8, arg, "--strict") or std.mem.eql(u8, arg, "--fsck-objects")) {
            strict = true;
        } else if (std.mem.startsWith(u8, arg, "--keep")) {
            // --keep or --keep=<msg>: create .keep file
        } else if (std.mem.startsWith(u8, arg, "--index-version=") or
            std.mem.eql(u8, arg, "--fix-thin") or
            std.mem.eql(u8, arg, "--check-self-contained-and-connected") or
            std.mem.startsWith(u8, arg, "--threads=") or
            std.mem.startsWith(u8, arg, "--max-input-size=") or
            std.mem.startsWith(u8, arg, "--object-format="))
        {
            // Accepted flags
        } else if (std.mem.eql(u8, arg, "-h")) {
            try platform_impl.writeStdout("usage: git index-pack [--verify] [--stdin] [-o <index-file>] <pack-file>\n");
            std.process.exit(129);
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            pack_file = arg;
        }
    }

    if (!stdin_mode and pack_file == null) {
        try platform_impl.writeStderr("usage: git index-pack [--verify] [--stdin] [-o <index-file>] <pack-file>\n");
        std.process.exit(1);
    }

    var pack_data: []const u8 = undefined;
    var should_free_pack = false;

    if (stdin_mode) {
        const git_dir = helpers.findGitDir() catch {
            try platform_impl.writeStderr("fatal: --stdin requires a git repository\n");
            std.process.exit(128);
            unreachable;
        };
        const stdin = std.fs.File{ .handle = std.posix.STDIN_FILENO };
        pack_data = stdin.readToEndAlloc(allocator, 4 * 1024 * 1024 * 1024) catch {
            try platform_impl.writeStderr("fatal: error reading pack from stdin\n");
            std.process.exit(128);
            unreachable;
        };
        should_free_pack = true;

        // helpers.Output progress if verbose
        if (verbose) {
            // helpers.Parse num helpers.objects from pack header for progress
            if (pack_data.len >= 12 and std.mem.eql(u8, pack_data[0..4], "PACK")) {
                const n = std.mem.readInt(u32, pack_data[8..12], .big);
                const msg = std.fmt.allocPrint(allocator, "Receiving objects: 100% ({d}/{d}), done.\n", .{ n, n }) catch unreachable;
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                const msg2 = std.fmt.allocPrint(allocator, "Resolving deltas: 100% ({d}/{d}), done.\n", .{ @as(u32, 0), @as(u32, 0) }) catch unreachable;
                defer allocator.free(msg2);
                try platform_impl.writeStderr(msg2);
            }
        }

        // helpers.Write pack file to objects/pack/
        const pack_dir = std.fmt.allocPrint(allocator, "{s}/objects/pack", .{git_dir}) catch unreachable;
        defer allocator.free(pack_dir);
        std.fs.cwd().makePath(pack_dir) catch {};

        // helpers.Compute checksum for pack name
        if (pack_data.len >= 20) {
            const trailing_sha = pack_data[pack_data.len - 20..];
            var hash_hex: [40]u8 = undefined;
            for (trailing_sha, 0..) |b, bi| {
                _ = std.fmt.bufPrint(hash_hex[bi * 2 .. bi * 2 + 2], "{x:0>2}", .{b}) catch continue;
            }

            // helpers.In strict mode, check for duplicate helpers.objects
            if (strict) {
                if (packHasDuplicates(allocator, pack_data)) {
                    try platform_impl.writeStderr("fatal: pack has duplicate entries\n");
                    std.process.exit(1);
                    unreachable;
                }
            }

            const dest_pack = std.fmt.allocPrint(allocator, "{s}/pack-{s}.pack", .{ pack_dir, hash_hex }) catch unreachable;
            defer allocator.free(dest_pack);
            std.fs.cwd().writeFile(.{ .sub_path = dest_pack, .data = pack_data }) catch {};

            // helpers.Generate idx
            try generatePackIdx(allocator, pack_data, pack_dir, &hash_hex);

            const msg = std.fmt.allocPrint(allocator, "pack\t{s}\n", .{hash_hex}) catch unreachable;
            defer allocator.free(msg);
            try platform_impl.writeStdout(msg);
        }
    } else if (pack_file) |pf| {
        pack_data = std.fs.cwd().readFileAlloc(allocator, pf, 4 * 1024 * 1024 * 1024) catch {
            const msg = std.fmt.allocPrint(allocator, "fatal: cannot open packfile '{s}'\n", .{pf}) catch unreachable;
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
            unreachable;
        };
        should_free_pack = true;

        if (verify) {
            // helpers.Just verify pack header
            if (pack_data.len < 12 or !std.mem.eql(u8, pack_data[0..4], "PACK")) {
                try platform_impl.writeStderr("fatal: not a valid pack file\n");
                std.process.exit(128);
            }
            // Success for verify
            return;
        }

        // helpers.Generate index file
        const idx_path = if (output_path) |op| op else blk: {
            if (std.mem.endsWith(u8, pf, ".pack")) {
                break :blk try std.fmt.allocPrint(allocator, "{s}idx", .{pf[0 .. pf.len - 4]});
            }
            break :blk try std.fmt.allocPrint(allocator, "{s}.idx", .{pf});
        };
        defer if (output_path == null) allocator.free(idx_path);

        try generatePackIdxToFile(allocator, pack_data, idx_path);

        // helpers.Create .keep file if --keep was specified
        {
            var ki = command_index + 1;
            while (ki < args.len) : (ki += 1) {
                if (std.mem.startsWith(u8, args[ki], "--keep")) {
                    const keep_msg = if (std.mem.startsWith(u8, args[ki], "--keep="))
                        args[ki]["--keep=".len..]
                    else
                        "";
                    const keep_path = if (std.mem.endsWith(u8, pf, ".pack"))
                        try std.fmt.allocPrint(allocator, "{s}keep", .{pf[0 .. pf.len - 4]})
                    else
                        try std.fmt.allocPrint(allocator, "{s}.keep", .{pf});
                    defer allocator.free(keep_path);
                    const keep_content = try std.fmt.allocPrint(allocator, "{s}\n", .{keep_msg});
                    defer allocator.free(keep_content);
                    std.fs.cwd().writeFile(.{ .sub_path = keep_path, .data = keep_content }) catch {};
                    break;
                }
            }
        }
    }

    if (should_free_pack) {
        allocator.free(pack_data);
    }
}

const PackIdxEntry = helpers.PackIdxEntry;


pub fn nativeCmdUnpackObjects(allocator: std.mem.Allocator, args: [][]const u8, command_index: usize, platform_impl: *const platform_mod.Platform) !void {
    var dry_run = false;
    var strict = false;
    var quiet = false;

    var i = command_index + 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-n")) {
            dry_run = true;
        } else if (std.mem.eql(u8, arg, "--strict")) {
            strict = true;
        } else if (std.mem.eql(u8, arg, "-q")) {
            quiet = true;
        } else if (std.mem.eql(u8, arg, "-r")) {
            // recover - accepted
        } else if (std.mem.startsWith(u8, arg, "--max-input-size=")) {
            // accepted
        } else if (std.mem.eql(u8, arg, "-h")) {
            try platform_impl.writeStdout("usage: git unpack-helpers.objects [-n] [-q] [-r] [--strict]\n");
            std.process.exit(129);
        }
    }

    const git_dir = helpers.findGitDir() catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
        unreachable;
    };

    // helpers.Read pack data from stdin
    const stdin_file = std.fs.File{ .handle = std.posix.STDIN_FILENO };
    const pack_data = stdin_file.readToEndAlloc(allocator, 4 * 1024 * 1024 * 1024) catch {
        try platform_impl.writeStderr("fatal: error reading pack data from stdin\n");
        std.process.exit(128);
        unreachable;
    };
    defer allocator.free(pack_data);

    // helpers.Validate pack header
    if (pack_data.len < 12) {
        try platform_impl.writeStderr("fatal: pack too short\n");
        std.process.exit(128);
        unreachable;
    }
    if (!std.mem.eql(u8, pack_data[0..4], "PACK")) {
        try platform_impl.writeStderr("fatal: bad pack header\n");
        std.process.exit(128);
        unreachable;
    }

    const version = std.mem.readInt(u32, pack_data[4..8], .big);
    if (version != 2 and version != 3) {
        const msg = std.fmt.allocPrint(allocator, "fatal: unknown pack file version {d}\n", .{version}) catch unreachable;
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        std.process.exit(128);
        unreachable;
    }

    const num_objects = std.mem.readInt(u32, pack_data[8..12], .big);

    if (!quiet) {
        const msg = std.fmt.allocPrint(allocator, "Unpacking {d} objects: ", .{num_objects}) catch unreachable;
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
    }

    const zlib_compat = @import("git/zlib_compat.zig");
    const objects_dir = std.fmt.allocPrint(allocator, "{s}/objects", .{git_dir}) catch unreachable;
    defer allocator.free(objects_dir);

    var pos: usize = 12;
    var unpacked: usize = 0;
    var obj_idx: u32 = 0;
    while (obj_idx < num_objects and pos < pack_data.len -| 20) : (obj_idx += 1) {
        const entry_start = pos;
        _ = entry_start;

        // helpers.Parse variable-length object header
        var c = pack_data[pos];
        pos += 1;
        const obj_type: u8 = (c >> 4) & 0x07;
        var obj_size: u64 = c & 0x0F;
        var shift: u6 = 4;
        while (c & 0x80 != 0 and pos < pack_data.len) {
            c = pack_data[pos];
            pos += 1;
            obj_size |= @as(u64, c & 0x7F) << shift;
            shift +|= 7;
        }

        var base_hash: ?[20]u8 = null;
        var base_offset: ?u64 = null;

        if (obj_type == 6) {
            // OFS_DELTA
            c = pack_data[pos];
            pos += 1;
            var offset: u64 = c & 0x7F;
            while (c & 0x80 != 0 and pos < pack_data.len) {
                c = pack_data[pos];
                pos += 1;
                offset = ((offset + 1) << 7) | (c & 0x7F);
            }
            base_offset = offset;
        } else if (obj_type == 7) {
            // REF_DELTA
            if (pos + 20 > pack_data.len) break;
            base_hash = pack_data[pos..][0..20].*;
            pos += 20;
        }

        // helpers.Decompress using zlib C API for accurate byte tracking
        const decomp_result3 = zlib_compat.decompressSliceWithConsumed(allocator, pack_data[pos..]) catch {
            continue;
        };
        const content_owned = decomp_result3.data;
        defer allocator.free(content_owned);
        pos += decomp_result3.consumed;

        // helpers.Determine actual object type and content (resolve deltas)
        var final_type: u8 = obj_type;
        var final_content: []const u8 = content_owned;
        var resolved_content: ?[]u8 = null;

        if (obj_type == 7 and base_hash != null) {
            // REF_DELTA: resolve using base object hash
            var hex: [40]u8 = undefined;
            for (base_hash.?, 0..) |b, bi| {
                _ = std.fmt.bufPrint(hex[bi * 2 .. bi * 2 + 2], "{x:0>2}", .{b}) catch continue;
            }
            if (objects.GitObject.load(&hex, git_dir, platform_impl, allocator)) |base_obj| {
                defer base_obj.deinit(allocator);
                final_type = switch (base_obj.type) {
                    .commit => 1,
                    .tree => 2,
                    .blob => 3,
                    .tag => 4,
                };
                resolved_content = helpers.applyDelta(allocator, base_obj.data, content_owned) catch null;
                if (resolved_content) |rc| final_content = rc;
            } else |_| {
                if (strict) {
                    try platform_impl.writeStderr("error: could not resolve delta base\n");
                    std.process.exit(1);
                }
                continue;
            }
        } else if (obj_type == 6) {
            // OFS_DELTA: would need to track previous helpers.objects by offset
            // helpers.For now, skip - this is a simplified implementation
        }
        defer if (resolved_content) |rc| allocator.free(rc);

        if (final_type >= 1 and final_type <= 4 and !dry_run) {
            const type_str: []const u8 = switch (final_type) {
                1 => "commit",
                2 => "tree",
                3 => "blob",
                4 => "tag",
                else => continue,
            };

            // helpers.Compute helpers.SHA1 hash
            const header = std.fmt.allocPrint(allocator, "{s} {d}\x00", .{ type_str, final_content.len }) catch continue;
            defer allocator.free(header);
            var hasher = std.crypto.hash.Sha1.init(.{});
            hasher.update(header);
            hasher.update(final_content);
            const sha = hasher.finalResult();

            var hash_hex: [40]u8 = undefined;
            for (sha, 0..) |b, bi| {
                _ = std.fmt.bufPrint(hash_hex[bi * 2 .. bi * 2 + 2], "{x:0>2}", .{b}) catch continue;
            }

            // helpers.Check if object already exists
            const obj_dir = std.fmt.allocPrint(allocator, "{s}/{s}", .{ objects_dir, hash_hex[0..2] }) catch continue;
            defer allocator.free(obj_dir);
            const obj_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ obj_dir, hash_hex[2..] }) catch continue;
            defer allocator.free(obj_path);

            if (std.fs.cwd().statFile(obj_path)) |_| {
                // Already exists
                unpacked += 1;
                continue;
            } else |_| {}

            // helpers.Create directory
            std.fs.cwd().makePath(obj_dir) catch continue;

            // Compress and write object
            const zlib_compat2 = @import("git/zlib_compat.zig");
            var combined = std.array_list.Managed(u8).init(allocator);
            defer combined.deinit();
            try combined.appendSlice(header);
            try combined.appendSlice(final_content);
            const obj_data_buf = zlib_compat2.compressSlice(allocator, combined.items) catch continue;
            defer allocator.free(obj_data_buf);

            std.fs.cwd().writeFile(.{ .sub_path = obj_path, .data = obj_data_buf }) catch continue;
            unpacked += 1;
        } else if (final_type >= 1 and final_type <= 4) {
            unpacked += 1;
        }
    }

    if (!quiet) {
        const msg = std.fmt.allocPrint(allocator, "{d}, done.\n", .{unpacked}) catch unreachable;
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
    }
}


pub fn generatePackIdx(allocator: std.mem.Allocator, pack_data: []const u8, output_dir: []const u8, hash_hex: *const [40]u8) !void {
    // helpers.Parse pack file to extract object SHAs
    if (pack_data.len < 12) return;
    if (!std.mem.eql(u8, pack_data[0..4], "PACK")) return;

    const num_objects = std.mem.readInt(u32, pack_data[8..12], .big);

    // helpers.Collect object hashes by parsing pack entries
    var object_shas = std.array_list.Managed([20]u8).init(allocator);
    defer object_shas.deinit();
    var offsets = std.array_list.Managed(u32).init(allocator);
    defer offsets.deinit();
    var crcs = std.array_list.Managed(u32).init(allocator);
    defer crcs.deinit();

    var pos: usize = 12;
    var obj_count: usize = 0;
    while (obj_count < num_objects and pos < pack_data.len - 20) : (obj_count += 1) {
        const entry_offset = pos;
        try offsets.append(@intCast(entry_offset));

        // helpers.Parse object header
        var c = pack_data[pos];
        pos += 1;
        var obj_size: u64 = c & 0x0F;
        var shift: u6 = 4;
        while (c & 0x80 != 0 and pos < pack_data.len) {
            c = pack_data[pos];
            pos += 1;
            obj_size |= @as(u64, c & 0x7F) << shift;
            shift +|= 7;
        }

        const obj_type = (pack_data[entry_offset] >> 4) & 0x07;

        // helpers.Skip delta base ref if needed
        if (obj_type == 6) {
            // OFS_DELTA: skip base offset encoding
            c = pack_data[pos];
            pos += 1;
            while (c & 0x80 != 0 and pos < pack_data.len) {
                c = pack_data[pos];
                pos += 1;
            }
        } else if (obj_type == 7) {
            // REF_DELTA: skip 20-byte base SHA
            pos += 20;
        }

        // helpers.Decompress using zlib C API for accurate consumed byte count
        const decomp_result = zlib_compat_mod.decompressSliceWithConsumed(allocator, pack_data[pos..]) catch {
            try object_shas.append(std.mem.zeroes([20]u8));
            try crcs.append(0);
            continue;
        };
        defer allocator.free(decomp_result.data);
        pos += decomp_result.consumed;

        // helpers.Compute CRC32 for the entry
        const entry_data = pack_data[entry_offset..pos];
        const crc = std.hash.crc.Crc32.hash(entry_data);
        try crcs.append(crc);

        // helpers.Compute SHA of the object content (only for non-delta objects)
        var sha: [20]u8 = std.mem.zeroes([20]u8);
        if (obj_type >= 1 and obj_type <= 4) {
            const type_str: []const u8 = switch (obj_type) {
                1 => "commit",
                2 => "tree",
                3 => "blob",
                4 => "tag",
                else => "blob",
            };
            const header = std.fmt.allocPrint(allocator, "{s} {d}\x00", .{ type_str, decomp_result.data.len }) catch continue;
            defer allocator.free(header);
            var hasher = std.crypto.hash.Sha1.init(.{});
            hasher.update(header);
            hasher.update(decomp_result.data);
            sha = hasher.finalResult();
        }
        try object_shas.append(sha);
    }

    // helpers.Write v2 idx file
    var idx = std.array_list.Managed(u8).init(allocator);
    defer idx.deinit();

    // Magic + version
    try idx.appendSlice("\xfftOc");
    try idx.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, 2)));

    // Fanout table (256 entries)
    // helpers.Sort helpers.objects by SHA for the fanout
    const SortCtx = struct {
        shas: [][20]u8,
    };
    const indices = try allocator.alloc(usize, object_shas.items.len);
    defer allocator.free(indices);
    for (indices, 0..) |*idx_val, j| idx_val.* = j;

    const ctx = SortCtx{ .shas = object_shas.items };
    std.mem.sort(usize, indices, ctx, struct {
        fn lessThan(c: SortCtx, a: usize, b: usize) bool {
            return std.mem.order(u8, &c.shas[a], &c.shas[b]).compare(.lt);
        }
    }.lessThan);

    // helpers.Build fanout
    var fanout: [256]u32 = std.mem.zeroes([256]u32);
    for (indices) |idx_val| {
        const first_byte = object_shas.items[idx_val][0];
        var fb: usize = first_byte;
        while (fb < 256) : (fb += 1) {
            fanout[fb] += 1;
        }
    }
    for (fanout) |f| {
        try idx.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, f)));
    }

    // SHA-1 table (sorted)
    for (indices) |idx_val| {
        try idx.appendSlice(&object_shas.items[idx_val]);
    }

    // CRC32 table
    for (indices) |idx_val| {
        if (idx_val < crcs.items.len) {
            try idx.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, crcs.items[idx_val])));
        } else {
            try idx.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, 0)));
        }
    }

    // Offset table
    for (indices) |idx_val| {
        if (idx_val < offsets.items.len) {
            try idx.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, offsets.items[idx_val])));
        } else {
            try idx.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, 0)));
        }
    }

    // Pack SHA-1
    if (pack_data.len >= 20) {
        try idx.appendSlice(pack_data[pack_data.len - 20..]);
    }

    // Idx SHA-1
    var idx_sha = std.crypto.hash.Sha1.init(.{});
    idx_sha.update(idx.items);
    const idx_checksum = idx_sha.finalResult();
    try idx.appendSlice(&idx_checksum);

    // helpers.Write idx file
    const idx_filename = std.fmt.allocPrint(allocator, "{s}/pack-{s}.idx", .{ output_dir, hash_hex }) catch return;
    defer allocator.free(idx_filename);
    std.fs.cwd().writeFile(.{ .sub_path = idx_filename, .data = idx.items }) catch {};
}


pub fn generatePackIdxFromEntries(allocator: std.mem.Allocator, entries: []const PackIdxEntry, pack_checksum: *const [20]u8, output_dir: []const u8, hash_hex: *const [40]u8) !void {
    const n = entries.len;

    // helpers.Sort entries by SHA-1
    const indices = try allocator.alloc(usize, n);
    defer allocator.free(indices);
    for (indices, 0..) |*idx_val, j| idx_val.* = j;

    const SortCtx = struct {
        e: []const PackIdxEntry,
    };
    const ctx = SortCtx{ .e = entries };
    std.mem.sort(usize, indices, ctx, struct {
        fn lessThan(c: SortCtx, a: usize, b: usize) bool {
            return std.mem.order(u8, &c.e[a].sha, &c.e[b].sha).compare(.lt);
        }
    }.lessThan);

    var idx = std.array_list.Managed(u8).init(allocator);
    defer idx.deinit();

    // Magic + version
    try idx.appendSlice("\xfftOc");
    try idx.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, 2)));

    // Fanout table (256 entries)
    var fanout: [256]u32 = std.mem.zeroes([256]u32);
    for (indices) |idx_val| {
        const first_byte = entries[idx_val].sha[0];
        var fb: usize = first_byte;
        while (fb < 256) : (fb += 1) {
            fanout[fb] += 1;
        }
    }
    for (fanout) |f| {
        try idx.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, f)));
    }

    // SHA-1 table (sorted)
    for (indices) |idx_val| {
        try idx.appendSlice(&entries[idx_val].sha);
    }

    // CRC32 table
    for (indices) |idx_val| {
        try idx.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, entries[idx_val].crc)));
    }

    // 4-byte offset table
    for (indices) |idx_val| {
        try idx.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, entries[idx_val].offset)));
    }

    // Pack checksum
    try idx.appendSlice(pack_checksum);

    // Idx checksum
    var idx_sha = std.crypto.hash.Sha1.init(.{});
    idx_sha.update(idx.items);
    const idx_checksum = idx_sha.finalResult();
    try idx.appendSlice(&idx_checksum);

    // helpers.Write idx file
    const idx_filename = std.fmt.allocPrint(allocator, "{s}/pack-{s}.idx", .{ output_dir, hash_hex }) catch return;
    defer allocator.free(idx_filename);
    std.fs.cwd().writeFile(.{ .sub_path = idx_filename, .data = idx.items }) catch {};
}


pub fn generatePackIdxToFile(allocator: std.mem.Allocator, pack_data: []const u8, output_path: []const u8) !void {
    // helpers.Parse pack file to extract object SHAs
    if (pack_data.len < 12) return;
    if (!std.mem.eql(u8, pack_data[0..4], "PACK")) return;

    const num_objects = std.mem.readInt(u32, pack_data[8..12], .big);

    // helpers.Collect object hashes by parsing pack entries
    var object_shas = std.array_list.Managed([20]u8).init(allocator);
    defer object_shas.deinit();
    var offsets_list = std.array_list.Managed(u32).init(allocator);
    defer offsets_list.deinit();
    var crcs_list = std.array_list.Managed(u32).init(allocator);
    defer crcs_list.deinit();

    var pos: usize = 12;
    var obj_count: usize = 0;
    while (obj_count < num_objects and pos < pack_data.len -| 20) : (obj_count += 1) {
        const entry_offset = pos;
        try offsets_list.append(@intCast(entry_offset));

        // helpers.Parse object header
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

        // helpers.Skip delta base ref if needed
        if (obj_type == 6) {
            // OFS_DELTA: skip base offset encoding
            c = pack_data[pos];
            pos += 1;
            while (c & 0x80 != 0 and pos < pack_data.len) {
                c = pack_data[pos];
                pos += 1;
            }
        } else if (obj_type == 7) {
            // REF_DELTA: skip 20-byte base SHA
            pos += 20;
        }

        // helpers.Decompress using zlib C API for accurate consumed byte count
        const decomp_result2 = zlib_compat_mod.decompressSliceWithConsumed(allocator, pack_data[pos..]) catch {
            try object_shas.append(std.mem.zeroes([20]u8));
            try crcs_list.append(0);
            continue;
        };
        defer allocator.free(decomp_result2.data);
        pos += decomp_result2.consumed;

        // helpers.Compute CRC32 for the entry
        const entry_data = pack_data[entry_offset..pos];
        const crc = std.hash.crc.Crc32.hash(entry_data);
        try crcs_list.append(crc);

        // helpers.Compute SHA of the object content (only for non-delta objects)
        var sha: [20]u8 = std.mem.zeroes([20]u8);
        if (obj_type >= 1 and obj_type <= 4) {
            const type_str: []const u8 = switch (obj_type) {
                1 => "commit",
                2 => "tree",
                3 => "blob",
                4 => "tag",
                else => "blob",
            };
            const header = std.fmt.allocPrint(allocator, "{s} {d}\x00", .{ type_str, decomp_result2.data.len }) catch continue;
            defer allocator.free(header);
            var hasher = std.crypto.hash.Sha1.init(.{});
            hasher.update(header);
            hasher.update(decomp_result2.data);
            sha = hasher.finalResult();
        }
        try object_shas.append(sha);
    }

    // helpers.Write v2 idx file
    var idx = std.array_list.Managed(u8).init(allocator);
    defer idx.deinit();

    // Magic + version
    try idx.appendSlice("\xfftOc");
    try idx.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, 2)));

    // helpers.Sort helpers.objects by SHA for fanout
    const indices = try allocator.alloc(usize, object_shas.items.len);
    defer allocator.free(indices);
    for (indices, 0..) |*idx_val, j| idx_val.* = j;

    const SortCtx2 = struct {
        shas: [][20]u8,
    };
    const ctx = SortCtx2{ .shas = object_shas.items };
    std.mem.sort(usize, indices, ctx, struct {
        fn lessThan(c2: SortCtx2, a: usize, b: usize) bool {
            return std.mem.order(u8, &c2.shas[a], &c2.shas[b]).compare(.lt);
        }
    }.lessThan);

    // helpers.Build fanout table
    var fanout: [256]u32 = std.mem.zeroes([256]u32);
    for (indices) |idx_val| {
        const first_byte = object_shas.items[idx_val][0];
        var fb: usize = first_byte;
        while (fb < 256) : (fb += 1) {
            fanout[fb] += 1;
        }
    }
    for (fanout) |f| {
        try idx.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, f)));
    }

    // SHA-1 table (sorted)
    for (indices) |idx_val| {
        try idx.appendSlice(&object_shas.items[idx_val]);
    }

    // CRC32 table
    for (indices) |idx_val| {
        if (idx_val < crcs_list.items.len) {
            try idx.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, crcs_list.items[idx_val])));
        } else {
            try idx.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, 0)));
        }
    }

    // Offset table
    for (indices) |idx_val| {
        if (idx_val < offsets_list.items.len) {
            try idx.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, offsets_list.items[idx_val])));
        } else {
            try idx.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, 0)));
        }
    }

    // Pack SHA-1
    if (pack_data.len >= 20) {
        try idx.appendSlice(pack_data[pack_data.len - 20..]);
    }

    // Idx SHA-1
    var idx_sha = std.crypto.hash.Sha1.init(.{});
    idx_sha.update(idx.items);
    const idx_checksum = idx_sha.finalResult();
    try idx.appendSlice(&idx_checksum);

    // helpers.Write idx file
    std.fs.cwd().writeFile(.{ .sub_path = output_path, .data = idx.items }) catch {};
}


pub fn packObjectsAddAllObjects(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    object_set: *std.StringHashMap(void),
    object_hashes: *std.array_list.Managed([]const u8),
) !void {
    const objects_dir_path = try std.fmt.allocPrint(allocator, "{s}/objects", .{git_dir});
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
                var full_hash: [40]u8 = undefined;
                @memcpy(full_hash[0..2], &hex_buf);
                @memcpy(full_hash[2..40], entry.name[0..38]);
                if (!object_set.contains(&full_hash)) {
                    const duped2 = try allocator.dupe(u8, &full_hash);
                    try object_set.put(duped2, {});
                    try object_hashes.append(duped2);
                }
            }
        }
    }
}


pub fn packObjectsWalkReachable(
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    start_hash: []const u8,
    object_set: *std.StringHashMap(void),
    object_hashes: *std.array_list.Managed([]const u8),
    platform_impl: *const platform_mod.Platform,
) !void {
    var worklist = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (worklist.items) |item| allocator.free(item);
        worklist.deinit();
    }
    try worklist.append(try allocator.dupe(u8, start_hash));

    while (worklist.items.len > 0) {
        const hash = worklist.pop() orelse break;
        defer allocator.free(hash);

        if (object_set.contains(hash)) continue;

        const obj = objects.GitObject.load(hash, git_dir, platform_impl, allocator) catch continue;
        defer obj.deinit(allocator);

        const duped = try allocator.dupe(u8, hash);
        try object_set.put(duped, {});
        try object_hashes.append(duped);

        switch (obj.type) {
            .commit => {
                var line_iter = std.mem.splitScalar(u8, obj.data, '\n');
                while (line_iter.next()) |line| {
                    if (line.len == 0) break;
                    if (std.mem.startsWith(u8, line, "tree ") and line.len >= 45) {
                        try worklist.append(try allocator.dupe(u8, line[5..45]));
                    } else if (std.mem.startsWith(u8, line, "parent ") and line.len >= 47) {
                        try worklist.append(try allocator.dupe(u8, line[7..47]));
                    }
                }
            },
            .tree => {
                var tpos: usize = 0;
                while (tpos < obj.data.len) {
                    const null_pos = std.mem.indexOfScalarPos(u8, obj.data, tpos, 0) orelse break;
                    if (null_pos + 21 > obj.data.len) break;
                    const entry_hash_bytes = obj.data[null_pos + 1 .. null_pos + 21];
                    var entry_hex: [40]u8 = undefined;
                    for (entry_hash_bytes, 0..) |b, j| {
                        const hc = "0123456789abcdef";
                        entry_hex[j * 2] = hc[b >> 4];
                        entry_hex[j * 2 + 1] = hc[b & 0xf];
                    }
                    try worklist.append(try allocator.dupe(u8, &entry_hex));
                    tpos = null_pos + 21;
                }
            },
            .tag => {
                var line_iter = std.mem.splitScalar(u8, obj.data, '\n');
                while (line_iter.next()) |line| {
                    if (line.len == 0) break;
                    if (std.mem.startsWith(u8, line, "object ") and line.len >= 47) {
                        try worklist.append(try allocator.dupe(u8, line[7..47]));
                    }
                }
            },
            .blob => {},
        }
    }
}


pub fn packHasDuplicates(allocator: std.mem.Allocator, pack_data: []const u8) bool {
    if (pack_data.len < 12) return false;
    if (!std.mem.eql(u8, pack_data[0..4], "PACK")) return false;
    const num_objects = std.mem.readInt(u32, pack_data[8..12], .big);

    var seen = std.AutoHashMap([20]u8, void).init(allocator);
    defer seen.deinit();

    var pos: usize = 12;
    var obj_count: usize = 0;
    while (obj_count < num_objects and pos < pack_data.len -| 20) : (obj_count += 1) {
        var c = pack_data[pos];
        const obj_type = (c >> 4) & 0x07;
        pos += 1;
        var obj_size: u64 = c & 0x0F;
        var shift: u6 = 4;
        while (c & 0x80 != 0 and pos < pack_data.len) {
            c = pack_data[pos];
            pos += 1;
            obj_size |= @as(u64, c & 0x7F) << shift;
            shift +|= 7;
        }
        if (obj_type == 6) {
            c = pack_data[pos];
            pos += 1;
            while (c & 0x80 != 0 and pos < pack_data.len) {
                c = pack_data[pos];
                pos += 1;
            }
        } else if (obj_type == 7) {
            pos += 20;
        }
        const decomp_result = zlib_compat_mod.decompressSliceWithConsumed(allocator, pack_data[pos..]) catch return false;
        defer allocator.free(decomp_result.data);
        pos += decomp_result.consumed;

        if (obj_type >= 1 and obj_type <= 4) {
            const type_str: []const u8 = switch (obj_type) {
                1 => "commit",
                2 => "tree",
                3 => "blob",
                4 => "tag",
                else => "blob",
            };
            const header = std.fmt.allocPrint(allocator, "{s} {d}\x00", .{ type_str, decomp_result.data.len }) catch continue;
            defer allocator.free(header);
            var hasher = std.crypto.hash.Sha1.init(.{});
            hasher.update(header);
            hasher.update(decomp_result.data);
            const sha = hasher.finalResult();
            if (seen.contains(sha)) return true;
            seen.put(sha, {}) catch {};
        }
    }
    return false;
}
