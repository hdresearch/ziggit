const std = @import("std");
const pack_writer = @import("pack_writer");
const idx_writer = @import("idx_writer");

// ============================================================================
// Helper: build a minimal valid pack file with given objects
// ============================================================================

const PackObject = struct {
    type_str: []const u8,
    data: []const u8,
};

fn buildPackFile(allocator: std.mem.Allocator, objects: []const PackObject) ![]u8 {
    var pack = std.ArrayList(u8).init(allocator);
    errdefer pack.deinit();

    // Header: PACK + version 2 + object count
    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, @intCast(objects.len), .big);

    for (objects) |obj| {
        const obj_type: u3 = if (std.mem.eql(u8, obj.type_str, "commit"))
            1
        else if (std.mem.eql(u8, obj.type_str, "tree"))
            2
        else if (std.mem.eql(u8, obj.type_str, "blob"))
            3
        else if (std.mem.eql(u8, obj.type_str, "tag"))
            4
        else
            unreachable;

        // Encode type+size varint header
        var size = obj.data.len;
        var first_byte: u8 = (@as(u8, obj_type) << 4) | @as(u8, @intCast(size & 0x0F));
        size >>= 4;
        if (size > 0) first_byte |= 0x80;
        try pack.append(first_byte);

        while (size > 0) {
            var b: u8 = @intCast(size & 0x7F);
            size >>= 7;
            if (size > 0) b |= 0x80;
            try pack.append(b);
        }

        // Compress data with zlib
        var compressed = std.ArrayList(u8).init(allocator);
        defer compressed.deinit();
        var compressor = try std.compress.zlib.compressor(compressed.writer(), .{});
        try compressor.writer().writeAll(obj.data);
        try compressor.finish();
        try pack.appendSlice(compressed.items);
    }

    // Compute and append SHA-1 checksum
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack.items);
    var checksum: [20]u8 = undefined;
    hasher.final(&checksum);
    try pack.appendSlice(&checksum);

    return pack.toOwnedSlice();
}

fn setupTmpDir() ![]const u8 {
    const allocator = std.testing.allocator;
    const tmp = try std.fmt.allocPrint(allocator, "/tmp/ziggit_pack_test_{}", .{std.crypto.random.int(u64)});
    try std.fs.cwd().makePath(tmp);
    return tmp;
}

fn cleanupTmpDir(path: []const u8) void {
    std.fs.cwd().deleteTree(path) catch {};
    std.testing.allocator.free(path);
}

// ============================================================================
// pack_writer.savePack validation tests
// ============================================================================

test "savePack - valid pack with single blob" {
    const allocator = std.testing.allocator;
    const tmp_dir = try setupTmpDir();
    defer cleanupTmpDir(tmp_dir);

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/git", .{tmp_dir});
    defer allocator.free(git_dir);
    try std.fs.cwd().makePath(git_dir);

    const objects = [_]PackObject{
        .{ .type_str = "blob", .data = "hello world\n" },
    };
    const pack_data = try buildPackFile(allocator, &objects);
    defer allocator.free(pack_data);

    const hex = try pack_writer.savePack(allocator, git_dir, pack_data);
    defer allocator.free(hex);

    // Hex should be 40 characters
    try std.testing.expectEqual(@as(usize, 40), hex.len);

    // Verify the file was written
    const pack_path = try pack_writer.packPath(allocator, git_dir, hex);
    defer allocator.free(pack_path);
    const stat = try std.fs.cwd().statFile(pack_path);
    try std.testing.expectEqual(pack_data.len, stat.size);
}

test "savePack - rejects too small data" {
    const result = pack_writer.savePack(std.testing.allocator, "/tmp/x", &[_]u8{ 0, 1, 2, 3, 4 });
    try std.testing.expectError(error.PackFileTooSmall, result);
}

test "savePack - rejects bad magic" {
    var buf: [32]u8 = undefined;
    @memcpy(buf[0..4], "JUNK");
    std.mem.writeInt(u32, buf[4..8], 2, .big);
    std.mem.writeInt(u32, buf[8..12], 0, .big);
    @memset(buf[12..32], 0);

    const result = pack_writer.savePack(std.testing.allocator, "/tmp/x", &buf);
    try std.testing.expectError(error.InvalidPackSignature, result);
}

test "savePack - rejects wrong version" {
    var buf: [32]u8 = undefined;
    @memcpy(buf[0..4], "PACK");
    std.mem.writeInt(u32, buf[4..8], 3, .big); // version 3 not supported
    std.mem.writeInt(u32, buf[8..12], 0, .big);
    @memset(buf[12..32], 0);

    const result = pack_writer.savePack(std.testing.allocator, "/tmp/x", &buf);
    try std.testing.expectError(error.UnsupportedPackVersion, result);
}

test "savePack - rejects corrupted checksum" {
    const allocator = std.testing.allocator;
    const objects = [_]PackObject{
        .{ .type_str = "blob", .data = "test" },
    };
    var pack_data = try buildPackFile(allocator, &objects);
    defer allocator.free(pack_data);

    // Corrupt the last byte of checksum
    pack_data[pack_data.len - 1] ^= 0xFF;

    const result = pack_writer.savePack(allocator, "/tmp/x", pack_data);
    try std.testing.expectError(error.PackChecksumMismatch, result);
}

test "savePack - packPath and idxPath are consistent" {
    const allocator = std.testing.allocator;
    const hex = "abcdef0123456789abcdef0123456789abcdef01";
    const git_dir = "/tmp/test_git";

    const pp = try pack_writer.packPath(allocator, git_dir, hex);
    defer allocator.free(pp);
    const ip = try pack_writer.idxPath(allocator, git_dir, hex);
    defer allocator.free(ip);

    try std.testing.expectEqualStrings("/tmp/test_git/objects/pack/pack-abcdef0123456789abcdef0123456789abcdef01.pack", pp);
    try std.testing.expectEqualStrings("/tmp/test_git/objects/pack/pack-abcdef0123456789abcdef0123456789abcdef01.idx", ip);
}

// ============================================================================
// idx_writer tests
// ============================================================================

test "generateIdxFromData - valid pack with single blob" {
    const allocator = std.testing.allocator;
    const objects = [_]PackObject{
        .{ .type_str = "blob", .data = "hello world\n" },
    };
    const pack_data = try buildPackFile(allocator, &objects);
    defer allocator.free(pack_data);

    const idx_data = try idx_writer.generateIdxFromData(allocator, pack_data);
    defer allocator.free(idx_data);

    // Verify idx v2 magic: 0xff744f63
    try std.testing.expectEqual(@as(u32, 0xff744f63), std.mem.readInt(u32, idx_data[0..4], .big));
    // Version 2
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, idx_data[4..8], .big));

    // Fanout table: 256 entries of 4 bytes = 1024 bytes starting at offset 8
    // Last entry should equal total object count
    const fanout_end = 8 + 256 * 4;
    const total_objects = std.mem.readInt(u32, idx_data[fanout_end - 4 ..][0..4], .big);
    try std.testing.expectEqual(@as(u32, 1), total_objects);
}

test "generateIdxFromData - rejects too small" {
    const result = idx_writer.generateIdxFromData(std.testing.allocator, &[_]u8{ 0, 1, 2 });
    try std.testing.expectError(error.PackFileTooSmall, result);
}

test "generateIdxFromData - rejects bad magic" {
    var buf: [32]u8 = undefined;
    @memcpy(buf[0..4], "JUNK");
    std.mem.writeInt(u32, buf[4..8], 2, .big);
    std.mem.writeInt(u32, buf[8..12], 0, .big);
    @memset(buf[12..32], 0);

    const result = idx_writer.generateIdxFromData(std.testing.allocator, &buf);
    try std.testing.expectError(error.InvalidPackSignature, result);
}

test "generateIdxFromData - multiple objects" {
    const allocator = std.testing.allocator;
    const objects = [_]PackObject{
        .{ .type_str = "blob", .data = "file1 content\n" },
        .{ .type_str = "blob", .data = "file2 content\n" },
        .{ .type_str = "blob", .data = "file3 content\n" },
    };
    const pack_data = try buildPackFile(allocator, &objects);
    defer allocator.free(pack_data);

    const idx_data = try idx_writer.generateIdxFromData(allocator, pack_data);
    defer allocator.free(idx_data);

    // Verify structure
    try std.testing.expectEqual(@as(u32, 0xff744f63), std.mem.readInt(u32, idx_data[0..4], .big));
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, idx_data[4..8], .big));

    const fanout_end = 8 + 256 * 4;
    const total_objects = std.mem.readInt(u32, idx_data[fanout_end - 4 ..][0..4], .big);
    try std.testing.expectEqual(@as(u32, 3), total_objects);

    // Verify fanout is monotonically non-decreasing
    var prev: u32 = 0;
    for (0..256) |i| {
        const offset = 8 + i * 4;
        const val = std.mem.readInt(u32, idx_data[offset..][0..4], .big);
        try std.testing.expect(val >= prev);
        prev = val;
    }
}

test "generateIdxFromData - commit object" {
    const allocator = std.testing.allocator;
    // Minimal valid commit object data
    const tree_line = "tree 4b825dc642cb6eb9a060e54bf899d69f82063700\n";
    const author_line = "author Test User <test@example.com> 1700000000 +0000\n";
    const committer_line = "committer Test User <test@example.com> 1700000000 +0000\n";
    const commit_data = tree_line ++ author_line ++ committer_line ++ "\nInitial commit\n";

    const objects = [_]PackObject{
        .{ .type_str = "commit", .data = commit_data },
    };
    const pack_data = try buildPackFile(allocator, &objects);
    defer allocator.free(pack_data);

    const idx_data = try idx_writer.generateIdxFromData(allocator, pack_data);
    defer allocator.free(idx_data);

    const fanout_end = 8 + 256 * 4;
    const total_objects = std.mem.readInt(u32, idx_data[fanout_end - 4 ..][0..4], .big);
    try std.testing.expectEqual(@as(u32, 1), total_objects);
}

test "generateIdxFromData - mixed object types" {
    const allocator = std.testing.allocator;

    const blob_data = "some file content\n";
    const tree_data = "100644 file.txt\x00" ++ "\x00" ** 20; // minimal tree entry (20-byte hash)
    const commit_data =
        "tree 4b825dc642cb6eb9a060e54bf899d69f82063700\n" ++
        "author A <a@b.c> 1700000000 +0000\n" ++
        "committer A <a@b.c> 1700000000 +0000\n" ++
        "\ncommit msg\n";

    const objects = [_]PackObject{
        .{ .type_str = "blob", .data = blob_data },
        .{ .type_str = "tree", .data = tree_data },
        .{ .type_str = "commit", .data = commit_data },
    };
    const pack_data = try buildPackFile(allocator, &objects);
    defer allocator.free(pack_data);

    const idx_data = try idx_writer.generateIdxFromData(allocator, pack_data);
    defer allocator.free(idx_data);

    const fanout_end = 8 + 256 * 4;
    const total_objects = std.mem.readInt(u32, idx_data[fanout_end - 4 ..][0..4], .big);
    try std.testing.expectEqual(@as(u32, 3), total_objects);
}

// ============================================================================
// Git interop: verify pack/idx with `git verify-pack`
// ============================================================================

test "git verify-pack accepts pack written by savePack" {
    const allocator = std.testing.allocator;
    const tmp_dir = try setupTmpDir();
    defer cleanupTmpDir(tmp_dir);

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_dir});
    defer allocator.free(git_dir);

    // Initialize a bare git repo structure
    {
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "git", "init", "--bare", git_dir },
        });
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    const objects = [_]PackObject{
        .{ .type_str = "blob", .data = "hello from ziggit\n" },
    };
    const pack_data = try buildPackFile(allocator, &objects);
    defer allocator.free(pack_data);

    const hex = try pack_writer.savePack(allocator, git_dir, pack_data);
    defer allocator.free(hex);

    const pp = try pack_writer.packPath(allocator, git_dir, hex);
    defer allocator.free(pp);

    // Generate idx (required by git verify-pack)
    try idx_writer.generateIdx(allocator, pp);

    // git verify-pack should succeed
    const verify_result = try std.process.Child.run(.{
        .allocator = allocator,
        .max_output_bytes = 10 * 1024 * 1024,
        .argv = &.{ "git", "verify-pack", pp },
    });
    defer allocator.free(verify_result.stdout);
    defer allocator.free(verify_result.stderr);
    try std.testing.expectEqual(@as(u8, 0), verify_result.term.Exited);
}

test "git verify-pack -v accepts idx generated by generateIdx" {
    const allocator = std.testing.allocator;
    const tmp_dir = try setupTmpDir();
    defer cleanupTmpDir(tmp_dir);

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_dir});
    defer allocator.free(git_dir);

    {
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "git", "init", "--bare", git_dir },
        });
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    const objects = [_]PackObject{
        .{ .type_str = "blob", .data = "test blob for idx\n" },
        .{ .type_str = "blob", .data = "another blob\n" },
    };
    const pack_data = try buildPackFile(allocator, &objects);
    defer allocator.free(pack_data);

    const hex = try pack_writer.savePack(allocator, git_dir, pack_data);
    defer allocator.free(hex);

    const pp = try pack_writer.packPath(allocator, git_dir, hex);
    defer allocator.free(pp);

    // Generate idx
    try idx_writer.generateIdx(allocator, pp);

    // Verify with -v (verbose, also checks idx)
    const verify_result = try std.process.Child.run(.{
        .allocator = allocator,
        .max_output_bytes = 10 * 1024 * 1024,
        .argv = &.{ "git", "verify-pack", "-v", pp },
    });
    defer allocator.free(verify_result.stdout);
    defer allocator.free(verify_result.stderr);
    try std.testing.expectEqual(@as(u8, 0), verify_result.term.Exited);

    // Verbose output should list the objects
    try std.testing.expect(std.mem.indexOf(u8, verify_result.stdout, "blob") != null);
}

test "git verify-pack - pack with commit, tree, and blob" {
    const allocator = std.testing.allocator;
    const tmp_dir = try setupTmpDir();
    defer cleanupTmpDir(tmp_dir);

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_dir});
    defer allocator.free(git_dir);

    {
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "git", "init", "--bare", git_dir },
        });
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    const blob_data = "file content here\n";
    const tree_data = "100644 file.txt\x00" ++ "\x00" ** 20;
    const commit_data =
        "tree 4b825dc642cb6eb9a060e54bf899d69f82063700\n" ++
        "author Tester <t@t.com> 1700000000 +0000\n" ++
        "committer Tester <t@t.com> 1700000000 +0000\n" ++
        "\ntest\n";

    const objects = [_]PackObject{
        .{ .type_str = "blob", .data = blob_data },
        .{ .type_str = "tree", .data = tree_data },
        .{ .type_str = "commit", .data = commit_data },
    };
    const pack_data = try buildPackFile(allocator, &objects);
    defer allocator.free(pack_data);

    const hex = try pack_writer.savePack(allocator, git_dir, pack_data);
    defer allocator.free(hex);

    const pp = try pack_writer.packPath(allocator, git_dir, hex);
    defer allocator.free(pp);

    try idx_writer.generateIdx(allocator, pp);

    const verify_result = try std.process.Child.run(.{
        .allocator = allocator,
        .max_output_bytes = 10 * 1024 * 1024,
        .argv = &.{ "git", "verify-pack", "-v", pp },
    });
    defer allocator.free(verify_result.stdout);
    defer allocator.free(verify_result.stderr);
    try std.testing.expectEqual(@as(u8, 0), verify_result.term.Exited);

    // Should list all 3 types
    try std.testing.expect(std.mem.indexOf(u8, verify_result.stdout, "blob") != null);
    try std.testing.expect(std.mem.indexOf(u8, verify_result.stdout, "tree") != null);
    try std.testing.expect(std.mem.indexOf(u8, verify_result.stdout, "commit") != null);
}

test "git verify-pack - pack with tag object" {
    const allocator = std.testing.allocator;
    const tmp_dir = try setupTmpDir();
    defer cleanupTmpDir(tmp_dir);

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_dir});
    defer allocator.free(git_dir);

    {
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "git", "init", "--bare", git_dir },
        });
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    const tag_data =
        "object 4b825dc642cb6eb9a060e54bf899d69f82063700\n" ++
        "type commit\n" ++
        "tag v1.0.0\n" ++
        "tagger Tester <t@t.com> 1700000000 +0000\n" ++
        "\nRelease v1.0.0\n";

    const objects = [_]PackObject{
        .{ .type_str = "tag", .data = tag_data },
    };
    const pack_data = try buildPackFile(allocator, &objects);
    defer allocator.free(pack_data);

    const hex = try pack_writer.savePack(allocator, git_dir, pack_data);
    defer allocator.free(hex);

    const pp = try pack_writer.packPath(allocator, git_dir, hex);
    defer allocator.free(pp);

    try idx_writer.generateIdx(allocator, pp);

    const verify_result = try std.process.Child.run(.{
        .allocator = allocator,
        .max_output_bytes = 10 * 1024 * 1024,
        .argv = &.{ "git", "verify-pack", "-v", pp },
    });
    defer allocator.free(verify_result.stdout);
    defer allocator.free(verify_result.stderr);
    try std.testing.expectEqual(@as(u8, 0), verify_result.term.Exited);
    try std.testing.expect(std.mem.indexOf(u8, verify_result.stdout, "tag") != null);
}

// ============================================================================
// Idx structure integrity tests
// ============================================================================

test "idx SHA-1 table entries are sorted" {
    const allocator = std.testing.allocator;
    const objects = [_]PackObject{
        .{ .type_str = "blob", .data = "aaa\n" },
        .{ .type_str = "blob", .data = "bbb\n" },
        .{ .type_str = "blob", .data = "ccc\n" },
        .{ .type_str = "blob", .data = "ddd\n" },
        .{ .type_str = "blob", .data = "eee\n" },
    };
    const pack_data = try buildPackFile(allocator, &objects);
    defer allocator.free(pack_data);

    const idx_data = try idx_writer.generateIdxFromData(allocator, pack_data);
    defer allocator.free(idx_data);

    const fanout_end = 8 + 256 * 4;
    const total_objects = std.mem.readInt(u32, idx_data[fanout_end - 4 ..][0..4], .big);

    // SHA-1 table starts right after fanout
    const sha_table_start = fanout_end;
    var prev_sha: [20]u8 = [_]u8{0} ** 20;

    for (0..total_objects) |i| {
        const offset = sha_table_start + i * 20;
        const sha = idx_data[offset..][0..20];
        try std.testing.expect(std.mem.order(u8, &prev_sha, sha) != .gt);
        @memcpy(&prev_sha, sha);
    }
}

test "idx fanout last entry equals object count" {
    const allocator = std.testing.allocator;
    const objects = [_]PackObject{
        .{ .type_str = "blob", .data = "x\n" },
        .{ .type_str = "blob", .data = "y\n" },
    };
    const pack_data = try buildPackFile(allocator, &objects);
    defer allocator.free(pack_data);

    const idx_data = try idx_writer.generateIdxFromData(allocator, pack_data);
    defer allocator.free(idx_data);

    // Object count from pack header
    const pack_count = std.mem.readInt(u32, pack_data[8..12], .big);

    // Last fanout entry
    const fanout_last = std.mem.readInt(u32, idx_data[8 + 255 * 4 ..][0..4], .big);
    try std.testing.expectEqual(pack_count, fanout_last);
}

test "idx ends with valid SHA-1 checksum" {
    const allocator = std.testing.allocator;
    const objects = [_]PackObject{
        .{ .type_str = "blob", .data = "checksum test\n" },
    };
    const pack_data = try buildPackFile(allocator, &objects);
    defer allocator.free(pack_data);

    const idx_data = try idx_writer.generateIdxFromData(allocator, pack_data);
    defer allocator.free(idx_data);

    // Last 20 bytes = idx checksum over everything before
    const content = idx_data[0 .. idx_data.len - 20];
    const stored_checksum = idx_data[idx_data.len - 20 ..][0..20];

    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(content);
    var computed: [20]u8 = undefined;
    hasher.final(&computed);

    try std.testing.expectEqualSlices(u8, &computed, stored_checksum);
}

test "idx contains pack checksum" {
    const allocator = std.testing.allocator;
    const objects = [_]PackObject{
        .{ .type_str = "blob", .data = "pack checksum test\n" },
    };
    const pack_data = try buildPackFile(allocator, &objects);
    defer allocator.free(pack_data);

    const idx_data = try idx_writer.generateIdxFromData(allocator, pack_data);
    defer allocator.free(idx_data);

    // Pack checksum is the last 20 bytes of the pack data
    const pack_checksum = pack_data[pack_data.len - 20 ..];

    // In idx, pack checksum is at [len-40..len-20] (before idx checksum)
    const idx_pack_checksum = idx_data[idx_data.len - 40 .. idx_data.len - 20];
    try std.testing.expectEqualSlices(u8, pack_checksum, idx_pack_checksum);
}
