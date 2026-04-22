const std = @import("std");
const platform_mod = @import("platform/platform.zig");
const helpers = @import("git_helpers.zig");
const objects = helpers.objects;
const refs = helpers.refs;

/// Minimal git receive-pack implementation (protocol v0/v1).
/// Advertises refs with capabilities, then receives ref updates and pack data.
pub fn cmdReceivePack(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    var repo_path: ?[]const u8 = null;
    var advertise_refs_only = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--stateless-rpc")) {
            // ignored for now
        } else if (std.mem.eql(u8, arg, "--advertise-refs")) {
            advertise_refs_only = true;
        } else if (std.mem.eql(u8, arg, "--http-backend-info-refs")) {
            advertise_refs_only = true;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            repo_path = arg;
        }
    }

    if (repo_path == null) {
        try platform_impl.writeStderr("fatal: receive-pack requires a repository argument\n");
        std.process.exit(128);
    }

    const path = repo_path.?;
    var git_dir: []const u8 = undefined;

    // Try path/.git first, then path itself (bare repo)
    const dot_git = try std.fmt.allocPrint(allocator, "{s}/.git", .{path});
    defer allocator.free(dot_git);
    const is_dot_git = blk: {
        std.fs.cwd().access(dot_git, .{}) catch break :blk false;
        break :blk true;
    };

    if (is_dot_git) {
        git_dir = dot_git;
    } else {
        const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{path});
        defer allocator.free(head_path);
        std.fs.cwd().access(head_path, .{}) catch {
            try platform_impl.writeStderr("fatal: not a git repository\n");
            std.process.exit(128);
        };
        git_dir = path;
    }

    // Collect all refs
    var ref_list = std.array_list.Managed(RefEntry).init(allocator);
    defer {
        for (ref_list.items) |entry| {
            allocator.free(entry.name);
            allocator.free(entry.hash);
        }
        ref_list.deinit();
    }

    // Read HEAD
    const head_file = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_dir});
    defer allocator.free(head_file);
    if (std.fs.cwd().readFileAlloc(allocator, head_file, 1024)) |head_content| {
        defer allocator.free(head_content);
        const trimmed = std.mem.trim(u8, head_content, " \t\r\n");
        if (std.mem.startsWith(u8, trimmed, "ref: ")) {
            const ref_name = trimmed[5..];
            const ref_path2 = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_dir, ref_name });
            defer allocator.free(ref_path2);
            if (std.fs.cwd().readFileAlloc(allocator, ref_path2, 1024)) |ref_content| {
                defer allocator.free(ref_content);
                const hash = std.mem.trim(u8, ref_content, " \t\r\n");
                if (hash.len >= 40) {
                    try ref_list.append(.{
                        .name = try allocator.dupe(u8, "HEAD"),
                        .hash = try allocator.dupe(u8, hash[0..40]),
                    });
                }
            } else |_| {
                if (resolvePackedRef(allocator, git_dir, ref_name)) |hash| {
                    try ref_list.append(.{
                        .name = try allocator.dupe(u8, "HEAD"),
                        .hash = hash,
                    });
                } else |_| {}
            }
        } else if (trimmed.len >= 40) {
            try ref_list.append(.{
                .name = try allocator.dupe(u8, "HEAD"),
                .hash = try allocator.dupe(u8, trimmed[0..40]),
            });
        }
    } else |_| {}

    // Read refs
    try collectRefs(allocator, git_dir, "refs", &ref_list);
    try collectPackedRefs(allocator, git_dir, &ref_list);

    // Sort refs
    var si: usize = 0;
    while (si < ref_list.items.len) : (si += 1) {
        var sj: usize = si + 1;
        while (sj < ref_list.items.len) : (sj += 1) {
            const a_name = ref_list.items[si].name;
            const b_name = ref_list.items[sj].name;
            const swap = blk: {
                if (std.mem.eql(u8, b_name, "HEAD")) break :blk true;
                if (std.mem.eql(u8, a_name, "HEAD")) break :blk false;
                break :blk std.mem.order(u8, a_name, b_name) == .gt;
            };
            if (swap) {
                const tmp = ref_list.items[si];
                ref_list.items[si] = ref_list.items[sj];
                ref_list.items[sj] = tmp;
            }
        }
    }

    const capabilities = "report-status report-status-v2 delete-refs side-band-64k quiet atomic ofs-delta object-format=sha1 agent=ziggit/1.0";

    // Write refs advertisement
    if (ref_list.items.len == 0) {
        const line = try std.fmt.allocPrint(allocator, "0000000000000000000000000000000000000000 capabilities^{{}}\x00{s}\n", .{capabilities});
        defer allocator.free(line);
        try writePktLine(platform_impl, line);
    } else {
        for (ref_list.items, 0..) |entry, i| {
            if (i == 0) {
                const line = try std.fmt.allocPrint(allocator, "{s} {s}\x00{s}\n", .{ entry.hash, entry.name, capabilities });
                defer allocator.free(line);
                try writePktLine(platform_impl, line);
            } else {
                const line = try std.fmt.allocPrint(allocator, "{s} {s}\n", .{ entry.hash, entry.name });
                defer allocator.free(line);
                try writePktLine(platform_impl, line);
            }
        }
    }

    // Flush
    try platform_impl.writeStdout("0000");

    if (advertise_refs_only) return;

    // Read ref update commands from client
    const stdin = std.fs.File.stdin();
    var updates = std.array_list.Managed(RefUpdate).init(allocator);
    defer {
        for (updates.items) |u| allocator.free(u.ref_name);
        updates.deinit();
    }

    while (true) {
        // Read pkt-line
        var len_buf: [4]u8 = undefined;
        const bytes_read = stdin.read(&len_buf) catch break;
        if (bytes_read < 4) break;
        if (std.mem.eql(u8, &len_buf, "0000")) break;

        const pkt_len = std.fmt.parseInt(u16, &len_buf, 16) catch break;
        if (pkt_len < 4) break;
        const data_len = pkt_len - 4;
        if (data_len == 0) continue;

        var buf: [65536]u8 = undefined;
        if (data_len > buf.len) break;

        const data_read = stdin.read(buf[0..data_len]) catch break;
        if (data_read < data_len) break;

        const line_data = buf[0..data_read];
        const trimmed = std.mem.trimRight(u8, line_data, "\n\r");

        // Format: "<old-hash> <new-hash> <ref-name>[\0capabilities]"
        if (trimmed.len < 83) continue;

        var update: RefUpdate = undefined;
        @memcpy(&update.old_hash, trimmed[0..40]);
        @memcpy(&update.new_hash, trimmed[41..81]);

        const ref_and_caps = trimmed[82..];
        if (std.mem.indexOfScalar(u8, ref_and_caps, 0)) |null_pos| {
            update.ref_name = try allocator.dupe(u8, ref_and_caps[0..null_pos]);
        } else {
            update.ref_name = try allocator.dupe(u8, ref_and_caps);
        }
        try updates.append(update);
    }

    if (updates.items.len == 0) return;

    // Read pack data if there are non-delete updates
    const zero_hash = "0000000000000000000000000000000000000000";
    var has_non_delete = false;
    for (updates.items) |u| {
        if (!std.mem.eql(u8, &u.new_hash, zero_hash)) {
            has_non_delete = true;
            break;
        }
    }

    if (has_non_delete) {
        // Read pack from stdin
        var pack_buf = std.array_list.Managed(u8).init(allocator);
        defer pack_buf.deinit();

        var read_buf: [8192]u8 = undefined;
        while (true) {
            const n = stdin.read(&read_buf) catch break;
            if (n == 0) break;
            try pack_buf.appendSlice(read_buf[0..n]);
        }

        if (pack_buf.items.len >= 12 and std.mem.eql(u8, pack_buf.items[0..4], "PACK")) {
            // Save pack to repository
            savePackData(allocator, git_dir, pack_buf.items) catch |err| {
                const err_msg = try std.fmt.allocPrint(allocator, "unpack error: {}\n", .{err});
                defer allocator.free(err_msg);
                try writePktLine(platform_impl, err_msg);
                try platform_impl.writeStdout("0000");
                return;
            };
        }
    }

    // Apply ref updates
    for (updates.items) |update| {
        applyRefUpdate(allocator, git_dir, &update.old_hash, &update.new_hash, update.ref_name) catch {};
    }

    // Send status
    try writePktLine(platform_impl, "unpack ok\n");
    for (updates.items) |update| {
        const status = try std.fmt.allocPrint(allocator, "ok {s}\n", .{update.ref_name});
        defer allocator.free(status);
        try writePktLine(platform_impl, status);
    }
    try platform_impl.writeStdout("0000");
}

const RefEntry = struct {
    name: []const u8,
    hash: []const u8,
};

const RefUpdate = struct {
    old_hash: [40]u8,
    new_hash: [40]u8,
    ref_name: []const u8,
};

fn writePktLine(platform_impl: *const platform_mod.Platform, data: []const u8) !void {
    const total_len = data.len + 4;
    var len_hex: [4]u8 = undefined;
    _ = std.fmt.bufPrint(&len_hex, "{x:0>4}", .{total_len}) catch return;
    try platform_impl.writeStdout(&len_hex);
    try platform_impl.writeStdout(data);
}

fn resolvePackedRef(allocator: std.mem.Allocator, git_dir: []const u8, ref_name: []const u8) ![]const u8 {
    const packed_path = try std.fmt.allocPrint(allocator, "{s}/packed-refs", .{git_dir});
    defer allocator.free(packed_path);
    const content = try std.fs.cwd().readFileAlloc(allocator, packed_path, 10 * 1024 * 1024);
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#' or line[0] == '^') continue;
        if (std.mem.indexOfScalar(u8, line, ' ')) |sp| {
            const hash = line[0..sp];
            const name = line[sp + 1 ..];
            if (std.mem.eql(u8, name, ref_name) and hash.len >= 40) {
                return try allocator.dupe(u8, hash[0..40]);
            }
        }
    }
    return error.NotFound;
}

fn collectRefs(allocator: std.mem.Allocator, git_dir: []const u8, prefix: []const u8, ref_list: *std.array_list.Managed(RefEntry)) !void {
    const dir_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_dir, prefix });
    defer allocator.free(dir_path);

    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const full_name = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name });
        if (entry.kind == .directory) {
            defer allocator.free(full_name);
            try collectRefs(allocator, git_dir, full_name, ref_list);
        } else {
            const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_dir, full_name });
            defer allocator.free(file_path);
            if (std.fs.cwd().readFileAlloc(allocator, file_path, 1024)) |content| {
                defer allocator.free(content);
                const hash = std.mem.trim(u8, content, " \t\r\n");
                if (hash.len >= 40) {
                    try ref_list.append(.{
                        .name = full_name,
                        .hash = try allocator.dupe(u8, hash[0..40]),
                    });
                } else {
                    allocator.free(full_name);
                }
            } else |_| {
                allocator.free(full_name);
            }
        }
    }
}

fn collectPackedRefs(allocator: std.mem.Allocator, git_dir: []const u8, ref_list: *std.array_list.Managed(RefEntry)) !void {
    const packed_path = try std.fmt.allocPrint(allocator, "{s}/packed-refs", .{git_dir});
    defer allocator.free(packed_path);
    const content = std.fs.cwd().readFileAlloc(allocator, packed_path, 10 * 1024 * 1024) catch return;
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#' or line[0] == '^') continue;
        if (std.mem.indexOfScalar(u8, line, ' ')) |sp| {
            const hash = line[0..sp];
            const name = line[sp + 1 ..];
            if (hash.len >= 40 and std.mem.startsWith(u8, name, "refs/")) {
                var found = false;
                for (ref_list.items) |existing| {
                    if (std.mem.eql(u8, existing.name, name)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    try ref_list.append(.{
                        .name = try allocator.dupe(u8, name),
                        .hash = try allocator.dupe(u8, hash[0..40]),
                    });
                }
            }
        }
    }
}

fn savePackData(allocator: std.mem.Allocator, git_dir: []const u8, pack_data: []const u8) !void {
    if (pack_data.len < 32) return error.Overflow;

    const pack_content = pack_data[0 .. pack_data.len - 20];
    var sha1 = std.crypto.hash.Sha1.init(.{});
    sha1.update(pack_content);
    const checksum = sha1.finalResult();
    var checksum_hex: [40]u8 = undefined;
    for (checksum, 0..) |b, i| {
        const hc = "0123456789abcdef";
        checksum_hex[i * 2] = hc[b >> 4];
        checksum_hex[i * 2 + 1] = hc[b & 0xf];
    }

    const pack_dir = try std.fmt.allocPrint(allocator, "{s}/objects/pack", .{git_dir});
    defer allocator.free(pack_dir);
    std.fs.cwd().makePath(pack_dir) catch {};

    const pack_path = try std.fmt.allocPrint(allocator, "{s}/pack-{s}.pack", .{ pack_dir, checksum_hex });
    defer allocator.free(pack_path);

    const pack_file = try std.fs.cwd().createFile(pack_path, .{});
    defer pack_file.close();
    try pack_file.writeAll(pack_data);

    // Generate index using proper delta-resolving idx_writer
    {
        const idx_writer_mod = @import("git/idx_writer.zig");
        const idx_data = try idx_writer_mod.generateIdxFromDataWithRepo(allocator, pack_data, git_dir);
        defer allocator.free(idx_data);
        const idx_path2 = try std.fmt.allocPrint(allocator, "{s}/pack-{s}.idx", .{ pack_dir, checksum_hex });
        defer allocator.free(idx_path2);
        const idx_file2 = try std.fs.cwd().createFile(idx_path2, .{});
        defer idx_file2.close();
        try idx_file2.writeAll(idx_data);
    }
}

fn applyRefUpdate(allocator: std.mem.Allocator, git_dir: []const u8, old_hash: *const [40]u8, new_hash: *const [40]u8, ref_name: []const u8) !void {
    const zero_hash = "0000000000000000000000000000000000000000";

    if (std.mem.eql(u8, new_hash, zero_hash)) {
        const ref_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_dir, ref_name });
        defer allocator.free(ref_path);
        std.fs.cwd().deleteFile(ref_path) catch {};
        return;
    }

    // Verify old hash if not creating
    if (!std.mem.eql(u8, old_hash, zero_hash)) {
        const ref_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_dir, ref_name });
        defer allocator.free(ref_path);
        if (std.fs.cwd().readFileAlloc(allocator, ref_path, 1024)) |current| {
            defer allocator.free(current);
            const current_hash = std.mem.trim(u8, current, " \t\r\n");
            if (current_hash.len >= 40 and !std.mem.eql(u8, current_hash[0..40], old_hash)) {
                return error.InvalidCharacter; // ref mismatch
            }
        } else |_| {
            return error.InvalidCharacter; // ref doesn't exist
        }
    }

    const ref_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_dir, ref_name });
    defer allocator.free(ref_path);

    if (std.mem.lastIndexOfScalar(u8, ref_path, '/')) |last_slash| {
        std.fs.cwd().makePath(ref_path[0..last_slash]) catch {};
    }

    const ref_file = try std.fs.cwd().createFile(ref_path, .{});
    defer ref_file.close();
    try ref_file.writeAll(new_hash);
    try ref_file.writeAll("\n");
}

fn generatePackIdx(allocator: std.mem.Allocator, pack_data: []const u8, pack_dir: []const u8, hash_hex: *const [40]u8) !void {
    if (pack_data.len < 12) return;
    if (!std.mem.eql(u8, pack_data[0..4], "PACK")) return;

    const num_objects = std.mem.readInt(u32, pack_data[8..12], .big);

    var object_shas = std.array_list.Managed([20]u8).init(allocator);
    defer object_shas.deinit();
    var offsets_list = std.array_list.Managed(u32).init(allocator);
    defer offsets_list.deinit();
    var crcs = std.array_list.Managed(u32).init(allocator);
    defer crcs.deinit();

    var pos: usize = 12;
    var obj_count: usize = 0;
    while (obj_count < num_objects and pos < pack_data.len -| 20) : (obj_count += 1) {
        const entry_offset = pos;
        try offsets_list.append(@intCast(entry_offset));

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

        const compressed = pack_data[pos..@min(pos + obj_size + 1024, pack_data.len)];
        const decomp = objects.cDecompressWithConsumed(allocator, compressed, @intCast(@min(obj_size, 1 << 24))) orelse {
            try object_shas.append(std.mem.zeroes([20]u8));
            try crcs.append(0);
            continue;
        };
        defer allocator.free(decomp.data);
        pos += decomp.consumed;

        const crc = std.hash.crc.Crc32IsoHdlc.hash(pack_data[entry_offset..pos]);
        try crcs.append(crc);

        var sha: [20]u8 = std.mem.zeroes([20]u8);
        if (obj_type >= 1 and obj_type <= 4) {
            const type_str: []const u8 = switch (obj_type) {
                1 => "commit",
                2 => "tree",
                3 => "blob",
                4 => "tag",
                else => "blob",
            };
            const header = try std.fmt.allocPrint(allocator, "{s} {d}\x00", .{ type_str, decomp.data.len });
            defer allocator.free(header);
            var hasher = std.crypto.hash.Sha1.init(.{});
            hasher.update(header);
            hasher.update(decomp.data);
            sha = hasher.finalResult();
        }
        try object_shas.append(sha);
    }

    var idx = std.array_list.Managed(u8).init(allocator);
    defer idx.deinit();

    try idx.appendSlice("\xfftOc");
    try idx.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, 2)));

    const indices = try allocator.alloc(usize, object_shas.items.len);
    defer allocator.free(indices);
    for (indices, 0..) |*iv, j| iv.* = j;

    const SortCtx = struct {
        shas: [][20]u8,
        fn lessThan(ctx: @This(), a: usize, b: usize) bool {
            return std.mem.order(u8, &ctx.shas[a], &ctx.shas[b]).compare(.lt);
        }
    };
    std.mem.sort(usize, indices, SortCtx{ .shas = object_shas.items }, SortCtx.lessThan);

    var fanout: [256]u32 = std.mem.zeroes([256]u32);
    for (indices) |iv| {
        const first_byte = object_shas.items[iv][0];
        var fb: usize = first_byte;
        while (fb < 256) : (fb += 1) {
            fanout[fb] += 1;
        }
    }
    for (fanout) |f| {
        try idx.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, f)));
    }

    for (indices) |iv| try idx.appendSlice(&object_shas.items[iv]);
    for (indices) |iv| {
        if (iv < crcs.items.len) {
            try idx.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, crcs.items[iv])));
        } else {
            try idx.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, 0)));
        }
    }
    for (indices) |iv| {
        if (iv < offsets_list.items.len) {
            try idx.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, offsets_list.items[iv])));
        } else {
            try idx.appendSlice(&std.mem.toBytes(std.mem.nativeToBig(u32, 0)));
        }
    }

    if (pack_data.len >= 20) try idx.appendSlice(pack_data[pack_data.len - 20 ..]);

    var idx_sha = std.crypto.hash.Sha1.init(.{});
    idx_sha.update(idx.items);
    const idx_checksum = idx_sha.finalResult();
    try idx.appendSlice(&idx_checksum);

    const idx_path = try std.fmt.allocPrint(allocator, "{s}/pack-{s}.idx", .{ pack_dir, hash_hex });
    defer allocator.free(idx_path);
    const idx_file = try std.fs.cwd().createFile(idx_path, .{});
    defer idx_file.close();
    try idx_file.writeAll(idx.items);
}
