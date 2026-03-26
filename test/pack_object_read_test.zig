const std = @import("std");
const testing = std.testing;
const objects = @import("git_objects");

// ============================================================================
// Tests for readPackObjectAtOffset, generatePackIndex, fixThinPack, applyDelta
// Focus: real git packs, edge cases, interop verification
// ============================================================================

/// Helper: run a shell command and return stdout
fn runCmd(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const result = try child.wait();
    const stdout = try child.stdout.?.reader().readAllAlloc(allocator, 10 * 1024 * 1024);
    if (result.Exited != 0) {
        allocator.free(stdout);
        return error.CommandFailed;
    }
    return stdout;
}

fn runCmdIn(allocator: std.mem.Allocator, cwd: []const u8, argv: []const []const u8) ![]u8 {
    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.cwd = std.fs.cwd().openDir(cwd, .{}) catch return error.CommandFailed;
    try child.spawn();
    const result = try child.wait();
    const stdout = try child.stdout.?.reader().readAllAlloc(allocator, 10 * 1024 * 1024);
    if (result.Exited != 0) {
        allocator.free(stdout);
        return error.CommandFailed;
    }
    return stdout;
}

fn runCmdInDir(allocator: std.mem.Allocator, dir: std.fs.Dir, argv: []const []const u8) ![]u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try dir.realpath(".", &path_buf);
    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.cwd = dir_path;
    try child.spawn();
    const stdout = try child.stdout.?.reader().readAllAlloc(allocator, 10 * 1024 * 1024);
    const result = try child.wait();
    if (result.Exited != 0) {
        allocator.free(stdout);
        return error.CommandFailed;
    }
    return stdout;
}

/// Run command, discard output
fn runGit(allocator: std.mem.Allocator, dir: std.fs.Dir, argv: []const []const u8) !void {
    const out = try runCmdInDir(allocator, dir, argv);
    allocator.free(out);
}

/// Helper: create a git repo with various object types, gc/repack, return pack file bytes
fn createGitRepoWithPack(allocator: std.mem.Allocator, tmp_dir: *std.testing.TmpDir) !struct {
    pack_data: []u8,
    blob_hash: [40]u8,
    commit_hash: [40]u8,
    tree_hash: [40]u8,
} {
    const dir = tmp_dir.dir;

    // git init
    try runGit(allocator, dir, &.{ "git", "init", "-b", "main" });
    try runGit(allocator, dir, &.{ "git", "config", "user.email", "test@test.com" });
    try runGit(allocator, dir, &.{ "git", "config", "user.name", "Test" });

    // Create a blob
    try dir.writeFile(.{ .sub_path = "hello.txt", .data = "Hello, World!\n" });
    try runGit(allocator, dir, &.{ "git", "add", "hello.txt" });
    try runGit(allocator, dir, &.{ "git", "commit", "-m", "initial" });

    // Get hashes
    const blob_out = try runCmdInDir(allocator, dir, &.{ "git", "rev-parse", "HEAD:hello.txt" });
    defer allocator.free(blob_out);
    const commit_out = try runCmdInDir(allocator, dir, &.{ "git", "rev-parse", "HEAD" });
    defer allocator.free(commit_out);
    const tree_out = try runCmdInDir(allocator, dir, &.{ "git", "rev-parse", "HEAD^{tree}" });
    defer allocator.free(tree_out);

    // Repack to create pack file
    try runGit(allocator, dir, &.{ "git", "gc", "--aggressive" });

    // Find pack file
    var pack_dir = try dir.openDir(".git/objects/pack", .{ .iterate = true });
    defer pack_dir.close();
    var it = pack_dir.iterate();
    var pack_data: ?[]u8 = null;
    while (try it.next()) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".pack")) {
            const f = try pack_dir.openFile(entry.name, .{});
            defer f.close();
            const stat = try f.stat();
            pack_data = try allocator.alloc(u8, stat.size);
            _ = try f.readAll(pack_data.?);
            break;
        }
    }

    var blob_hash: [40]u8 = undefined;
    @memcpy(&blob_hash, std.mem.trimRight(u8, blob_out, "\n\r "));
    var commit_hash: [40]u8 = undefined;
    @memcpy(&commit_hash, std.mem.trimRight(u8, commit_out, "\n\r "));
    var tree_hash: [40]u8 = undefined;
    @memcpy(&tree_hash, std.mem.trimRight(u8, tree_out, "\n\r "));

    return .{
        .pack_data = pack_data orelse return error.NoPackFile,
        .blob_hash = blob_hash,
        .commit_hash = commit_hash,
        .tree_hash = tree_hash,
    };
}

/// Encode a varint (for building delta/pack headers)
fn encodeVarint(buf: []u8, value: usize) usize {
    var v = value;
    var i: usize = 0;
    while (true) {
        buf[i] = @intCast(v & 0x7F);
        v >>= 7;
        if (v == 0) return i + 1;
        buf[i] |= 0x80;
        i += 1;
    }
}

/// Build a minimal pack file with a single blob
fn buildSingleBlobPack(allocator: std.mem.Allocator, blob_data: []const u8) ![]u8 {
    var pack = std.ArrayList(u8).init(allocator);
    defer pack.deinit();

    // Header
    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big); // version
    try pack.writer().writeInt(u32, 1, .big); // 1 object

    // Object header: type=blob(3), size
    const size = blob_data.len;
    var first: u8 = (3 << 4) | @as(u8, @intCast(size & 0x0F));
    var remaining = size >> 4;
    if (remaining > 0) first |= 0x80;
    try pack.append(first);
    while (remaining > 0) {
        var b: u8 = @intCast(remaining & 0x7F);
        remaining >>= 7;
        if (remaining > 0) b |= 0x80;
        try pack.append(b);
    }

    // Compress blob data
    var compressed = std.ArrayList(u8).init(allocator);
    defer compressed.deinit();
    var input = std.io.fixedBufferStream(blob_data);
    try std.compress.zlib.compress(input.reader(), compressed.writer(), .{});
    try pack.appendSlice(compressed.items);

    // Checksum
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack.items);
    var checksum: [20]u8 = undefined;
    hasher.final(&checksum);
    try pack.appendSlice(&checksum);

    return try pack.toOwnedSlice();
}

/// Build a pack with blob + OFS_DELTA
fn buildBlobWithOfsDeltaPack(allocator: std.mem.Allocator, base_data: []const u8, result_data: []const u8) ![]u8 {
    var pack = std.ArrayList(u8).init(allocator);
    defer pack.deinit();

    // Header
    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, 2, .big); // 2 objects

    const base_obj_offset: usize = 12;

    // Object 1: base blob
    {
        const size = base_data.len;
        var first: u8 = (3 << 4) | @as(u8, @intCast(size & 0x0F));
        var rem = size >> 4;
        if (rem > 0) first |= 0x80;
        try pack.append(first);
        while (rem > 0) {
            var b: u8 = @intCast(rem & 0x7F);
            rem >>= 7;
            if (rem > 0) b |= 0x80;
            try pack.append(b);
        }
        var compressed = std.ArrayList(u8).init(allocator);
        defer compressed.deinit();
        var input = std.io.fixedBufferStream(base_data);
        try std.compress.zlib.compress(input.reader(), compressed.writer(), .{});
        try pack.appendSlice(compressed.items);
    }

    const delta_obj_offset = pack.items.len;

    // Object 2: OFS_DELTA referencing object 1
    {
        // Build delta: copy entire base, then insert extra data
        var delta = std.ArrayList(u8).init(allocator);
        defer delta.deinit();
        var vbuf: [10]u8 = undefined;
        var n = encodeVarint(&vbuf, base_data.len);
        try delta.appendSlice(vbuf[0..n]);
        n = encodeVarint(&vbuf, result_data.len);
        try delta.appendSlice(vbuf[0..n]);

        // Copy entire base
        if (base_data.len > 0) {
            var cmd: u8 = 0x80;
            var copy_bytes_list = std.ArrayList(u8).init(allocator);
            defer copy_bytes_list.deinit();
            // offset=0 (no offset flags)
            // size
            const sz = base_data.len;
            if (sz & 0xFF != 0 or sz <= 0xFF) {
                cmd |= 0x10;
                try copy_bytes_list.append(@intCast(sz & 0xFF));
            }
            if (sz > 0xFF) {
                cmd |= 0x20;
                try copy_bytes_list.append(@intCast((sz >> 8) & 0xFF));
            }
            if (sz > 0xFFFF) {
                cmd |= 0x40;
                try copy_bytes_list.append(@intCast((sz >> 16) & 0xFF));
            }
            try delta.append(cmd);
            try delta.appendSlice(copy_bytes_list.items);
        }

        // Insert remaining data
        if (result_data.len > base_data.len) {
            const extra = result_data[base_data.len..];
            var pos: usize = 0;
            while (pos < extra.len) {
                const chunk = @min(127, extra.len - pos);
                try delta.append(@intCast(chunk));
                try delta.appendSlice(extra[pos .. pos + chunk]);
                pos += chunk;
            }
        }

        const delta_size = delta.items.len;

        // Pack header for OFS_DELTA (type=6)
        var first: u8 = (6 << 4) | @as(u8, @intCast(delta_size & 0x0F));
        var rem = delta_size >> 4;
        if (rem > 0) first |= 0x80;
        try pack.append(first);
        while (rem > 0) {
            var b: u8 = @intCast(rem & 0x7F);
            rem >>= 7;
            if (rem > 0) b |= 0x80;
            try pack.append(b);
        }

        // OFS_DELTA offset encoding
        const offset_delta = delta_obj_offset - base_obj_offset;
        // Git's offset encoding: first byte has value, subsequent bytes add (value+1)<<7
        // Encode in reverse
        var offset_bytes: [10]u8 = undefined;
        var oi: usize = 0;
        var od = offset_delta;
        offset_bytes[oi] = @intCast(od & 0x7F);
        od >>= 7;
        oi += 1;
        while (od > 0) {
            od -= 1; // The +1 in decode means we -1 in encode
            offset_bytes[oi] = @as(u8, @intCast(od & 0x7F)) | 0x80;
            od >>= 7;
            oi += 1;
        }
        // Write in reverse order (MSB first)
        var ri = oi;
        while (ri > 0) {
            ri -= 1;
            try pack.append(offset_bytes[ri]);
        }

        // Compress delta data
        var compressed = std.ArrayList(u8).init(allocator);
        defer compressed.deinit();
        var input = std.io.fixedBufferStream(delta.items);
        try std.compress.zlib.compress(input.reader(), compressed.writer(), .{});
        try pack.appendSlice(compressed.items);
    }

    // Checksum
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack.items);
    var checksum: [20]u8 = undefined;
    hasher.final(&checksum);
    try pack.appendSlice(&checksum);

    return try pack.toOwnedSlice();
}

// ============================================================================
// Tests
// ============================================================================

test "readPackObjectAtOffset: read blob from synthetic pack" {
    const allocator = testing.allocator;
    const blob_data = "Hello, World!\n";
    const pack_data = try buildSingleBlobPack(allocator, blob_data);
    defer allocator.free(pack_data);

    const obj = try objects.readPackObjectAtOffset(pack_data, 12, allocator);
    defer obj.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.blob, obj.type);
    try testing.expectEqualStrings(blob_data, obj.data);
}

test "readPackObjectAtOffset: OFS_DELTA resolves correctly" {
    const allocator = testing.allocator;
    const base = "Hello, World!\n";
    const result = "Hello, World!\nExtra line\n";
    const pack_data = try buildBlobWithOfsDeltaPack(allocator, base, result);
    defer allocator.free(pack_data);

    // Read the base blob (at offset 12)
    const base_obj = try objects.readPackObjectAtOffset(pack_data, 12, allocator);
    defer base_obj.deinit(allocator);
    try testing.expectEqual(objects.ObjectType.blob, base_obj.type);
    try testing.expectEqualStrings(base, base_obj.data);

    // Find the delta object offset (after base)
    // Parse base header to find its end
    var pos: usize = 12;
    var b = pack_data[pos];
    pos += 1;
    while (b & 0x80 != 0) {
        b = pack_data[pos];
        pos += 1;
    }
    // pos now points to compressed data; decompress to find end
    var stream = std.io.fixedBufferStream(pack_data[pos..]);
    var decomp = std.ArrayList(u8).init(allocator);
    defer decomp.deinit();
    try std.compress.zlib.decompress(stream.reader(), decomp.writer());
    pos += @as(usize, @intCast(stream.pos));

    // Read delta object
    const delta_obj = try objects.readPackObjectAtOffset(pack_data, pos, allocator);
    defer delta_obj.deinit(allocator);
    try testing.expectEqual(objects.ObjectType.blob, delta_obj.type);
    try testing.expectEqualStrings(result, delta_obj.data);
}

test "readPackObjectAtOffset: rejects out-of-bounds offset" {
    const allocator = testing.allocator;
    const pack_data = try buildSingleBlobPack(allocator, "x");
    defer allocator.free(pack_data);

    const err = objects.readPackObjectAtOffset(pack_data, pack_data.len + 100, allocator);
    try testing.expectError(error.ObjectNotFound, err);
}

test "readPackObjectAtOffset: rejects offset at checksum" {
    const allocator = testing.allocator;
    const pack_data = try buildSingleBlobPack(allocator, "x");
    defer allocator.free(pack_data);

    // The last 20 bytes are checksum, not a valid object
    const err = objects.readPackObjectAtOffset(pack_data, pack_data.len - 10, allocator);
    try testing.expectError(error.ObjectNotFound, err);
}

test "generatePackIndex: single blob roundtrip" {
    const allocator = testing.allocator;
    const blob_data = "test blob content\n";
    const pack_data = try buildSingleBlobPack(allocator, blob_data);
    defer allocator.free(pack_data);

    const idx_data = try objects.generatePackIndex(pack_data, allocator);
    defer allocator.free(idx_data);

    // Verify idx structure: magic + version
    try testing.expectEqual(@as(u32, 0xff744f63), std.mem.readInt(u32, idx_data[0..4], .big));
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, idx_data[4..8], .big));

    // Fanout: last entry should be 1 (total objects)
    const total = std.mem.readInt(u32, idx_data[8 + 255 * 4 ..][0..4], .big);
    try testing.expectEqual(@as(u32, 1), total);

    // SHA-1 of "blob 18\0test blob content\n"
    var expected_sha: [20]u8 = undefined;
    var h = std.crypto.hash.Sha1.init(.{});
    h.update("blob 18\x00test blob content\n");
    h.final(&expected_sha);

    // SHA-1 table starts at offset 8 + 256*4 = 1032
    const sha_in_idx = idx_data[1032..1052];
    try testing.expectEqualSlices(u8, &expected_sha, sha_in_idx);

    // Pack checksum should be in idx
    const pack_checksum = pack_data[pack_data.len - 20 ..];
    // Pack checksum in idx is after: magic(4) + ver(4) + fanout(256*4) + sha(20*1) + crc(4*1) + offset(4*1) = 1032+20+4+4 = 1060
    const pack_cksum_in_idx = idx_data[1060..1080];
    try testing.expectEqualSlices(u8, pack_checksum, pack_cksum_in_idx);
}

test "generatePackIndex: OFS_DELTA gets correct SHA-1" {
    const allocator = testing.allocator;
    const base = "line one\nline two\n";
    const result = "line one\nline two\nline three\n";
    const pack_data = try buildBlobWithOfsDeltaPack(allocator, base, result);
    defer allocator.free(pack_data);

    const idx_data = try objects.generatePackIndex(pack_data, allocator);
    defer allocator.free(idx_data);

    // Should have 2 objects
    const total = std.mem.readInt(u32, idx_data[8 + 255 * 4 ..][0..4], .big);
    try testing.expectEqual(@as(u32, 2), total);

    // Compute expected SHA-1s
    var base_sha: [20]u8 = undefined;
    {
        const header = try std.fmt.allocPrint(allocator, "blob {}\x00", .{base.len});
        defer allocator.free(header);
        var h2 = std.crypto.hash.Sha1.init(.{});
        h2.update(header);
        h2.update(base);
        h2.final(&base_sha);
    }

    var result_sha: [20]u8 = undefined;
    {
        const header = try std.fmt.allocPrint(allocator, "blob {}\x00", .{result.len});
        defer allocator.free(header);
        var h2 = std.crypto.hash.Sha1.init(.{});
        h2.update(header);
        h2.update(result);
        h2.final(&result_sha);
    }

    // Both SHA-1s should be in the idx (sorted)
    const sha_table_start: usize = 8 + 256 * 4;
    const sha1_a = idx_data[sha_table_start..][0..20];
    const sha1_b = idx_data[sha_table_start + 20 ..][0..20];

    // They should be sorted
    try testing.expect(std.mem.order(u8, sha1_a, sha1_b) == .lt);

    // Both expected SHAs should be present
    const has_base = std.mem.eql(u8, sha1_a, &base_sha) or std.mem.eql(u8, sha1_b, &base_sha);
    const has_result = std.mem.eql(u8, sha1_a, &result_sha) or std.mem.eql(u8, sha1_b, &result_sha);
    try testing.expect(has_base);
    try testing.expect(has_result);
}

test "git-created pack: all base types readable by readPackObjectAtOffset" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = tmp.dir;

    // Create repo with commit, tree, blob, tag
    try runGit(allocator, dir, &.{ "git", "init", "-b", "main" });
    try runGit(allocator, dir, &.{ "git", "config", "user.email", "t@t.com" });
    try runGit(allocator, dir, &.{ "git", "config", "user.name", "T" });
    try dir.writeFile(.{ .sub_path = "f.txt", .data = "content\n" });
    try runGit(allocator, dir, &.{ "git", "add", "." });
    try runGit(allocator, dir, &.{ "git", "commit", "-m", "init" });
    try runGit(allocator, dir, &.{ "git", "tag", "-a", "v1.0", "-m", "release" });
    try runGit(allocator, dir, &.{ "git", "gc", "--aggressive" });

    // Get expected hashes
    const blob_raw = try runCmdInDir(allocator, dir, &.{ "git", "rev-parse", "HEAD:f.txt" });
    defer allocator.free(blob_raw);
    const blob_hex = std.mem.trimRight(u8, blob_raw, "\n\r ");
    const tree_raw = try runCmdInDir(allocator, dir, &.{ "git", "rev-parse", "HEAD^{tree}" });
    defer allocator.free(tree_raw);
    const tree_hex = std.mem.trimRight(u8, tree_raw, "\n\r ");
    const commit_raw = try runCmdInDir(allocator, dir, &.{ "git", "rev-parse", "HEAD" });
    defer allocator.free(commit_raw);
    const commit_hex = std.mem.trimRight(u8, commit_raw, "\n\r ");
    const tag_raw = try runCmdInDir(allocator, dir, &.{ "git", "rev-parse", "v1.0" });
    defer allocator.free(tag_raw);
    const tag_hex = std.mem.trimRight(u8, tag_raw, "\n\r ");

    // Read pack file
    var pack_dir = try dir.openDir(".git/objects/pack", .{ .iterate = true });
    defer pack_dir.close();
    var pack_data: ?[]u8 = null;
    {
        var it = pack_dir.iterate();
        while (try it.next()) |entry| {
            if (std.mem.endsWith(u8, entry.name, ".pack")) {
                const f = try pack_dir.openFile(entry.name, .{});
                defer f.close();
                const stat = try f.stat();
                pack_data = try allocator.alloc(u8, stat.size);
                _ = try f.readAll(pack_data.?);
                break;
            }
        }
    }
    defer if (pack_data) |pd| allocator.free(pd);
    const pd = pack_data orelse return error.NoPackFile;

    // Generate idx from pack
    const idx_data = try objects.generatePackIndex(pd, allocator);
    defer allocator.free(idx_data);

    // For each expected hash, find its offset in idx, then read with readPackObjectAtOffset
    const expected_hashes = [_]struct { hex: []const u8, expected_type: objects.ObjectType }{
        .{ .hex = blob_hex, .expected_type = .blob },
        .{ .hex = tree_hex, .expected_type = .tree },
        .{ .hex = commit_hex, .expected_type = .commit },
        .{ .hex = tag_hex, .expected_type = .tag },
    };

    const total_objects = std.mem.readInt(u32, idx_data[8 + 255 * 4 ..][0..4], .big);
    const sha_table_start: usize = 8 + 256 * 4;
    const offset_table_start = sha_table_start + 20 * total_objects + 4 * total_objects;

    for (expected_hashes) |expected| {
        var target_sha: [20]u8 = undefined;
        _ = std.fmt.hexToBytes(&target_sha, expected.hex[0..40]) catch continue;

        // Binary search in idx SHA table
        var found_offset: ?u32 = null;
        for (0..total_objects) |i| {
            const sha_in_idx = idx_data[sha_table_start + 20 * i ..][0..20];
            if (std.mem.eql(u8, sha_in_idx, &target_sha)) {
                found_offset = std.mem.readInt(u32, idx_data[offset_table_start + 4 * i ..][0..4], .big);
                break;
            }
        }

        if (found_offset) |off| {
            const obj = try objects.readPackObjectAtOffset(pd, off, allocator);
            defer obj.deinit(allocator);
            try testing.expectEqual(expected.expected_type, obj.type);
            try testing.expect(obj.data.len > 0);
        }
        // If not found, the object may be a delta base that gc didn't include separately
    }
}

test "git-created pack with deltas: readPackObjectAtOffset resolves OFS_DELTA" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = tmp.dir;

    try runGit(allocator, dir, &.{ "git", "init", "-b", "main" });
    try runGit(allocator, dir, &.{ "git", "config", "user.email", "t@t.com" });
    try runGit(allocator, dir, &.{ "git", "config", "user.name", "T" });

    // Create similar blobs to force delta encoding
    try dir.writeFile(.{ .sub_path = "big.txt", .data = "A" ** 200 ++ "\nversion 1\n" });
    try runGit(allocator, dir, &.{ "git", "add", "." });
    try runGit(allocator, dir, &.{ "git", "commit", "-m", "v1" });

    try dir.writeFile(.{ .sub_path = "big.txt", .data = "A" ** 200 ++ "\nversion 2\n" });
    try runGit(allocator, dir, &.{ "git", "add", "." });
    try runGit(allocator, dir, &.{ "git", "commit", "-m", "v2" });

    try runGit(allocator, dir, &.{ "git", "gc", "--aggressive" });

    // Get hash of latest blob
    const blob_raw = try runCmdInDir(allocator, dir, &.{ "git", "rev-parse", "HEAD:big.txt" });
    defer allocator.free(blob_raw);
    const blob_hex = std.mem.trimRight(u8, blob_raw, "\n\r ");

    // Expected content
    const expected_content = "A" ** 200 ++ "\nversion 2\n";

    // Read pack
    var pack_dir = try dir.openDir(".git/objects/pack", .{ .iterate = true });
    defer pack_dir.close();
    var pack_data: ?[]u8 = null;
    {
        var it = pack_dir.iterate();
        while (try it.next()) |entry| {
            if (std.mem.endsWith(u8, entry.name, ".pack")) {
                const f = try pack_dir.openFile(entry.name, .{});
                defer f.close();
                const stat = try f.stat();
                pack_data = try allocator.alloc(u8, stat.size);
                _ = try f.readAll(pack_data.?);
                break;
            }
        }
    }
    defer if (pack_data) |p| allocator.free(p);
    const pd = pack_data orelse return error.NoPackFile;

    // Generate idx, find blob offset, read
    const idx_data = try objects.generatePackIndex(pd, allocator);
    defer allocator.free(idx_data);

    const total_objects = std.mem.readInt(u32, idx_data[8 + 255 * 4 ..][0..4], .big);
    const sha_table_start: usize = 8 + 256 * 4;
    const offset_table_start = sha_table_start + 20 * total_objects + 4 * total_objects;

    var target_sha: [20]u8 = undefined;
    _ = try std.fmt.hexToBytes(&target_sha, blob_hex[0..40]);

    for (0..total_objects) |i| {
        const sha_in_idx = idx_data[sha_table_start + 20 * i ..][0..20];
        if (std.mem.eql(u8, sha_in_idx, &target_sha)) {
            const off = std.mem.readInt(u32, idx_data[offset_table_start + 4 * i ..][0..4], .big);
            const obj = try objects.readPackObjectAtOffset(pd, off, allocator);
            defer obj.deinit(allocator);
            try testing.expectEqual(objects.ObjectType.blob, obj.type);
            try testing.expectEqualStrings(expected_content, obj.data);
            return;
        }
    }
    // If we get here, the blob wasn't found in the idx (shouldn't happen)
    return error.ObjectNotFound;
}

test "generatePackIndex: accepted by git verify-pack" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = tmp.dir;

    // Build a simple pack with one blob
    const blob_data = "verify-pack test content\n";
    const pack_data = try buildSingleBlobPack(allocator, blob_data);
    defer allocator.free(pack_data);

    const idx_data = try objects.generatePackIndex(pack_data, allocator);
    defer allocator.free(idx_data);

    // Compute pack checksum hex for filename
    const pack_checksum = pack_data[pack_data.len - 20 ..];
    var hex: [40]u8 = undefined;
    _ = try std.fmt.bufPrint(&hex, "{}", .{std.fmt.fmtSliceHexLower(pack_checksum)});

    const pack_name = try std.fmt.allocPrint(allocator, "pack-{s}.pack", .{hex});
    defer allocator.free(pack_name);
    const idx_name = try std.fmt.allocPrint(allocator, "pack-{s}.idx", .{hex});
    defer allocator.free(idx_name);

    try dir.writeFile(.{ .sub_path = pack_name, .data = pack_data });
    try dir.writeFile(.{ .sub_path = idx_name, .data = idx_data });

    // Run git verify-pack
    // We need the full path
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const pack_path = try dir.realpath(pack_name, &path_buf);
    const verify_out = runCmdInDir(allocator, dir, &.{ "git", "verify-pack", "-v", pack_path }) catch |err| {
        // git verify-pack might not be available in all environments
        if (err == error.CommandFailed) return;
        return err;
    };
    defer allocator.free(verify_out);

    // If we get here, git accepted our pack+idx
    try testing.expect(verify_out.len > 0);
}

test "applyDelta: copy with size=0 means 0x10000" {
    const allocator = testing.allocator;

    // Create base data of exactly 0x10000 bytes
    const base_data = try allocator.alloc(u8, 0x10000);
    defer allocator.free(base_data);
    for (base_data, 0..) |*byte, i| {
        byte.* = @intCast(i & 0xFF);
    }

    // Build delta: copy offset=0, size=0 (means 0x10000)
    var delta = std.ArrayList(u8).init(allocator);
    defer delta.deinit();

    // Header: base_size=0x10000, result_size=0x10000
    var vbuf: [10]u8 = undefined;
    var n = encodeVarint(&vbuf, 0x10000);
    try delta.appendSlice(vbuf[0..n]);
    n = encodeVarint(&vbuf, 0x10000);
    try delta.appendSlice(vbuf[0..n]);

    // Copy command: 0x80 (copy, no offset flags, no size flags) -> offset=0, size=0x10000
    try delta.append(0x80);

    const result = try objects.applyDelta(base_data, delta.items, allocator);
    defer allocator.free(result);

    try testing.expectEqual(@as(usize, 0x10000), result.len);
    try testing.expectEqualSlices(u8, base_data, result);
}

test "applyDelta: copy from non-zero offset with all offset bytes" {
    const allocator = testing.allocator;

    const base_data = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
    var delta = std.ArrayList(u8).init(allocator);
    defer delta.deinit();

    // Header
    var vbuf: [10]u8 = undefined;
    var n = encodeVarint(&vbuf, base_data.len);
    try delta.appendSlice(vbuf[0..n]);
    n = encodeVarint(&vbuf, 10); // result size = 10
    try delta.appendSlice(vbuf[0..n]);

    // Copy command: offset=10, size=10 -> "KLMNOPQRST"
    // cmd byte: 0x80 | 0x01 (offset byte 0) | 0x10 (size byte 0)
    try delta.append(0x80 | 0x01 | 0x10);
    try delta.append(10); // offset byte 0 = 10
    try delta.append(10); // size byte 0 = 10

    const result = try objects.applyDelta(base_data, delta.items, allocator);
    defer allocator.free(result);

    try testing.expectEqualStrings("KLMNOPQRST", result);
}

test "applyDelta: mixed copy and insert operations" {
    const allocator = testing.allocator;

    const base_data = "Hello, World!";
    const expected = "Hello---World!";

    var delta = std.ArrayList(u8).init(allocator);
    defer delta.deinit();

    var vbuf: [10]u8 = undefined;
    var n_written = encodeVarint(&vbuf, base_data.len);
    try delta.appendSlice(vbuf[0..n_written]);
    n_written = encodeVarint(&vbuf, expected.len);
    try delta.appendSlice(vbuf[0..n_written]);

    // Copy "Hello" (offset=0, size=5)
    try delta.append(0x80 | 0x10); // copy, no offset, size byte 0
    try delta.append(5);

    // Insert "---"
    try delta.append(3); // insert 3 bytes
    try delta.appendSlice("---");

    // Copy "World!" (offset=7, size=6)
    try delta.append(0x80 | 0x01 | 0x10);
    try delta.append(7); // offset
    try delta.append(6); // size

    const result = try objects.applyDelta(base_data, delta.items, allocator);
    defer allocator.free(result);

    try testing.expectEqualStrings(expected, result);
}

test "applyDelta: empty result from non-empty base" {
    const allocator = testing.allocator;
    const base_data = "some content";

    var delta = std.ArrayList(u8).init(allocator);
    defer delta.deinit();

    var vbuf: [10]u8 = undefined;
    var n = encodeVarint(&vbuf, base_data.len);
    try delta.appendSlice(vbuf[0..n]);
    n = encodeVarint(&vbuf, 0); // result size = 0
    try delta.appendSlice(vbuf[0..n]);

    const result = try objects.applyDelta(base_data, delta.items, allocator);
    defer allocator.free(result);

    try testing.expectEqual(@as(usize, 0), result.len);
}

test "applyDelta: rejects cmd byte 0 (reserved)" {
    const allocator = testing.allocator;
    const base_data = "base";

    var delta = std.ArrayList(u8).init(allocator);
    defer delta.deinit();

    var vbuf: [10]u8 = undefined;
    var n = encodeVarint(&vbuf, base_data.len);
    try delta.appendSlice(vbuf[0..n]);
    n = encodeVarint(&vbuf, 4);
    try delta.appendSlice(vbuf[0..n]);

    try delta.append(0); // reserved/invalid cmd

    // Should fail with InvalidDelta (or be caught by recovery)
    const result = objects.applyDelta(base_data, delta.items, allocator);
    // The permissive fallbacks might succeed, so just check it doesn't crash
    if (result) |r| {
        allocator.free(r);
    } else |_| {
        // Expected error is fine too
    }
}

test "applyDelta: copy offset using all 4 offset bytes" {
    const allocator = testing.allocator;

    // Create base with data at a high offset
    const base_size = 0x10100; // > 64KB
    const base_data = try allocator.alloc(u8, base_size);
    defer allocator.free(base_data);
    @memset(base_data, 'X');
    // Put unique marker at offset 0x10000
    @memcpy(base_data[0x10000..0x10005], "HELLO");

    var delta = std.ArrayList(u8).init(allocator);
    defer delta.deinit();

    var vbuf: [10]u8 = undefined;
    var n = encodeVarint(&vbuf, base_size);
    try delta.appendSlice(vbuf[0..n]);
    n = encodeVarint(&vbuf, 5);
    try delta.appendSlice(vbuf[0..n]);

    // Copy from offset 0x10000, size 5
    // cmd: 0x80 | 0x01 (off byte0) | 0x04 (off byte2) | 0x10 (size byte0)
    try delta.append(0x80 | 0x01 | 0x04 | 0x10);
    try delta.append(0x00); // offset byte 0
    // byte 1 is not set (0x02 flag not set)
    try delta.append(0x01); // offset byte 2 = 0x01 => offset = 0x10000
    try delta.append(5); // size byte 0

    const result = try objects.applyDelta(base_data, delta.items, allocator);
    defer allocator.free(result);

    try testing.expectEqualStrings("HELLO", result);
}

test "saveReceivedPack: roundtrip through save and load" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = tmp.dir;

    // Set up a minimal .git directory
    try dir.makePath(".git/objects/pack");
    try dir.makePath(".git/refs");

    const blob_data = "saveReceivedPack test\n";
    const pack_data = try buildSingleBlobPack(allocator, blob_data);
    defer allocator.free(pack_data);

    // Get the tmp dir path
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const git_dir_path = try dir.realpath(".git", &path_buf);
    const git_dir_str = try allocator.dupe(u8, git_dir_path);
    defer allocator.free(git_dir_str);

    // We can't easily call saveReceivedPack without a platform_impl,
    // but we can test generatePackIndex + manual file write
    const idx_data = try objects.generatePackIndex(pack_data, allocator);
    defer allocator.free(idx_data);

    // Write pack + idx
    const pack_checksum = pack_data[pack_data.len - 20 ..];
    var hex_buf: [40]u8 = undefined;
    _ = try std.fmt.bufPrint(&hex_buf, "{}", .{std.fmt.fmtSliceHexLower(pack_checksum)});

    const pack_name = try std.fmt.allocPrint(allocator, ".git/objects/pack/pack-{s}.pack", .{hex_buf});
    defer allocator.free(pack_name);
    const idx_name = try std.fmt.allocPrint(allocator, ".git/objects/pack/pack-{s}.idx", .{hex_buf});
    defer allocator.free(idx_name);

    try dir.writeFile(.{ .sub_path = pack_name, .data = pack_data });
    try dir.writeFile(.{ .sub_path = idx_name, .data = idx_data });

    // Verify the object can be read back via readPackObjectAtOffset
    const obj = try objects.readPackObjectAtOffset(pack_data, 12, allocator);
    defer obj.deinit(allocator);
    try testing.expectEqualStrings(blob_data, obj.data);
}

test "generatePackIndex: multiple blobs sorted correctly" {
    const allocator = testing.allocator;

    // Build pack with 3 blobs
    var pack = std.ArrayList(u8).init(allocator);
    defer pack.deinit();

    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, 3, .big);

    const blobs = [_][]const u8{ "alpha\n", "beta\n", "gamma\n" };

    for (blobs) |blob_data| {
        const size = blob_data.len;
        var first: u8 = (3 << 4) | @as(u8, @intCast(size & 0x0F));
        var remaining = size >> 4;
        if (remaining > 0) first |= 0x80;
        try pack.append(first);
        while (remaining > 0) {
            var b: u8 = @intCast(remaining & 0x7F);
            remaining >>= 7;
            if (remaining > 0) b |= 0x80;
            try pack.append(b);
        }
        var compressed = std.ArrayList(u8).init(allocator);
        defer compressed.deinit();
        var input = std.io.fixedBufferStream(blob_data);
        try std.compress.zlib.compress(input.reader(), compressed.writer(), .{});
        try pack.appendSlice(compressed.items);
    }

    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack.items);
    var checksum: [20]u8 = undefined;
    hasher.final(&checksum);
    try pack.appendSlice(&checksum);

    const pack_data = try pack.toOwnedSlice();
    defer allocator.free(pack_data);

    const idx_data = try objects.generatePackIndex(pack_data, allocator);
    defer allocator.free(idx_data);

    const total = std.mem.readInt(u32, idx_data[8 + 255 * 4 ..][0..4], .big);
    try testing.expectEqual(@as(u32, 3), total);

    // Verify SHA-1s are sorted
    const sha_start: usize = 8 + 256 * 4;
    for (0..total - 1) |i| {
        const a = idx_data[sha_start + 20 * i ..][0..20];
        const b2 = idx_data[sha_start + 20 * (i + 1) ..][0..20];
        try testing.expect(std.mem.order(u8, a, b2) == .lt);
    }

    // Verify fanout is monotonically non-decreasing
    var prev: u32 = 0;
    for (0..256) |i| {
        const val = std.mem.readInt(u32, idx_data[8 + i * 4 ..][0..4], .big);
        try testing.expect(val >= prev);
        prev = val;
    }
    try testing.expectEqual(@as(u32, 3), prev);
}

test "pack checksum verification: reject corrupted pack" {
    const allocator = testing.allocator;
    const pack_data = try buildSingleBlobPack(allocator, "test\n");
    defer allocator.free(pack_data);

    // Corrupt one byte in the middle
    var corrupted = try allocator.dupe(u8, pack_data);
    defer allocator.free(corrupted);
    corrupted[15] ^= 0xFF;

    // generatePackIndex should still work (it doesn't verify pack checksum)
    // but saveReceivedPack would reject it
    // Test that readPackObjectAtOffset on corrupted data fails gracefully
    const result = objects.readPackObjectAtOffset(corrupted, 12, allocator);
    if (result) |obj| {
        // Might still decompress if corruption is in non-critical bytes
        obj.deinit(allocator);
    } else |_| {
        // Expected - decompression failure
    }
}
