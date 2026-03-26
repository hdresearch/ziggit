const std = @import("std");
const pack_writer = @import("pack_writer");
const idx_writer = @import("idx_writer");

// ============================================================================
// Helper: build a minimal valid pack file
// ============================================================================
const PackObject = struct {
    type_str: []const u8,
    data: []const u8,
};

fn buildPackFile(allocator: std.mem.Allocator, objects: []const PackObject) ![]u8 {
    var pack = std.ArrayList(u8).init(allocator);
    errdefer pack.deinit();

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

        var compressed = std.ArrayList(u8).init(allocator);
        defer compressed.deinit();
        var compressor = try std.compress.zlib.compressor(compressed.writer(), .{});
        try compressor.writer().writeAll(obj.data);
        try compressor.finish();
        try pack.appendSlice(compressed.items);
    }

    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack.items);
    var checksum: [20]u8 = undefined;
    hasher.final(&checksum);
    try pack.appendSlice(&checksum);

    return pack.toOwnedSlice();
}

fn setupTmpDir() ![]const u8 {
    const allocator = std.testing.allocator;
    const tmp = try std.fmt.allocPrint(allocator, "/tmp/ziggit_pw_test_{}", .{std.crypto.random.int(u64)});
    try std.fs.cwd().makePath(tmp);
    return tmp;
}

fn cleanupTmpDir(path: []const u8) void {
    std.fs.cwd().deleteTree(path) catch {};
    std.testing.allocator.free(path);
}

// ============================================================================
// savePack tests
// ============================================================================

test "savePack writes pack file to correct path" {
    const allocator = std.testing.allocator;
    const tmp_dir = try setupTmpDir();
    defer cleanupTmpDir(tmp_dir);

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_dir});
    defer allocator.free(git_dir);
    try std.fs.cwd().makePath(git_dir);

    const objects = [_]PackObject{
        .{ .type_str = "blob", .data = "hello pack writer\n" },
    };
    const pack_data = try buildPackFile(allocator, &objects);
    defer allocator.free(pack_data);

    const hex = try pack_writer.savePack(allocator, git_dir, pack_data);
    defer allocator.free(hex);

    try std.testing.expectEqual(@as(usize, 40), hex.len);

    // File must exist and have correct size
    const pp = try pack_writer.packPath(allocator, git_dir, hex);
    defer allocator.free(pp);
    const stat = try std.fs.cwd().statFile(pp);
    try std.testing.expectEqual(pack_data.len, stat.size);
}

test "savePack rejects invalid magic" {
    var buf: [32]u8 = [_]u8{0} ** 32;
    @memcpy(buf[0..4], "NOPE");
    std.mem.writeInt(u32, buf[4..8], 2, .big);
    const result = pack_writer.savePack(std.testing.allocator, "/tmp/x", &buf);
    try std.testing.expectError(error.InvalidPackSignature, result);
}

test "savePack rejects version 3" {
    var buf: [32]u8 = [_]u8{0} ** 32;
    @memcpy(buf[0..4], "PACK");
    std.mem.writeInt(u32, buf[4..8], 3, .big);
    const result = pack_writer.savePack(std.testing.allocator, "/tmp/x", &buf);
    try std.testing.expectError(error.UnsupportedPackVersion, result);
}

test "savePack rejects too small data" {
    const result = pack_writer.savePack(std.testing.allocator, "/tmp/x", &[_]u8{1} ** 10);
    try std.testing.expectError(error.PackFileTooSmall, result);
}

test "savePack rejects corrupted checksum" {
    const allocator = std.testing.allocator;
    const objects = [_]PackObject{
        .{ .type_str = "blob", .data = "checksum test" },
    };
    var pack_data = try buildPackFile(allocator, &objects);
    defer allocator.free(pack_data);
    pack_data[pack_data.len - 1] ^= 0xFF;
    const result = pack_writer.savePack(allocator, "/tmp/x", pack_data);
    try std.testing.expectError(error.PackChecksumMismatch, result);
}

test "savePackFast skips checksum verification" {
    const allocator = std.testing.allocator;
    const tmp_dir = try setupTmpDir();
    defer cleanupTmpDir(tmp_dir);

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_dir});
    defer allocator.free(git_dir);
    try std.fs.cwd().makePath(git_dir);

    const objects = [_]PackObject{
        .{ .type_str = "blob", .data = "fast save test\n" },
    };
    const pack_data = try buildPackFile(allocator, &objects);
    defer allocator.free(pack_data);

    const hex = try pack_writer.savePackFast(allocator, git_dir, pack_data);
    defer allocator.free(hex);
    try std.testing.expectEqual(@as(usize, 40), hex.len);
}

// ============================================================================
// generateIdx tests
// ============================================================================

test "generateIdx creates idx file next to pack" {
    const allocator = std.testing.allocator;
    const tmp_dir = try setupTmpDir();
    defer cleanupTmpDir(tmp_dir);

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_dir});
    defer allocator.free(git_dir);
    try std.fs.cwd().makePath(git_dir);

    const objects = [_]PackObject{
        .{ .type_str = "blob", .data = "idx gen test\n" },
    };
    const pack_data = try buildPackFile(allocator, &objects);
    defer allocator.free(pack_data);

    const hex = try pack_writer.savePack(allocator, git_dir, pack_data);
    defer allocator.free(hex);

    const pp = try pack_writer.packPath(allocator, git_dir, hex);
    defer allocator.free(pp);

    try idx_writer.generateIdx(allocator, pp);

    // idx file should exist
    const ip = try pack_writer.idxPath(allocator, git_dir, hex);
    defer allocator.free(ip);
    const stat = try std.fs.cwd().statFile(ip);
    try std.testing.expect(stat.size > 0);
}

test "generateIdxFromData produces valid v2 header" {
    const allocator = std.testing.allocator;
    const objects = [_]PackObject{
        .{ .type_str = "blob", .data = "v2 header\n" },
    };
    const pack_data = try buildPackFile(allocator, &objects);
    defer allocator.free(pack_data);

    const idx_data = try idx_writer.generateIdxFromData(allocator, pack_data);
    defer allocator.free(idx_data);

    try std.testing.expectEqual(@as(u32, 0xff744f63), std.mem.readInt(u32, idx_data[0..4], .big));
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, idx_data[4..8], .big));
}

test "generateIdxFromData fanout monotonically increasing" {
    const allocator = std.testing.allocator;
    const objects = [_]PackObject{
        .{ .type_str = "blob", .data = "a\n" },
        .{ .type_str = "blob", .data = "b\n" },
        .{ .type_str = "blob", .data = "c\n" },
        .{ .type_str = "blob", .data = "d\n" },
    };
    const pack_data = try buildPackFile(allocator, &objects);
    defer allocator.free(pack_data);

    const idx_data = try idx_writer.generateIdxFromData(allocator, pack_data);
    defer allocator.free(idx_data);

    var prev: u32 = 0;
    for (0..256) |i| {
        const val = std.mem.readInt(u32, idx_data[8 + i * 4 ..][0..4], .big);
        try std.testing.expect(val >= prev);
        prev = val;
    }
    try std.testing.expectEqual(@as(u32, 4), prev);
}

test "generateIdxFromData SHA-1 entries are sorted" {
    const allocator = std.testing.allocator;
    const objects = [_]PackObject{
        .{ .type_str = "blob", .data = "zzz\n" },
        .{ .type_str = "blob", .data = "aaa\n" },
        .{ .type_str = "blob", .data = "mmm\n" },
    };
    const pack_data = try buildPackFile(allocator, &objects);
    defer allocator.free(pack_data);

    const idx_data = try idx_writer.generateIdxFromData(allocator, pack_data);
    defer allocator.free(idx_data);

    const n: u32 = 3;
    const sha_start = 8 + 256 * 4;
    var prev_sha: [20]u8 = [_]u8{0} ** 20;
    for (0..n) |i| {
        const sha = idx_data[sha_start + i * 20 ..][0..20];
        try std.testing.expect(std.mem.order(u8, &prev_sha, sha) != .gt);
        @memcpy(&prev_sha, sha);
    }
}

test "generateIdxFromData idx self-checksum is valid" {
    const allocator = std.testing.allocator;
    const objects = [_]PackObject{
        .{ .type_str = "blob", .data = "self checksum\n" },
    };
    const pack_data = try buildPackFile(allocator, &objects);
    defer allocator.free(pack_data);

    const idx_data = try idx_writer.generateIdxFromData(allocator, pack_data);
    defer allocator.free(idx_data);

    const content = idx_data[0 .. idx_data.len - 20];
    const stored = idx_data[idx_data.len - 20 ..][0..20];
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(content);
    var computed: [20]u8 = undefined;
    hasher.final(&computed);
    try std.testing.expectEqualSlices(u8, &computed, stored);
}

test "generateIdxFromData pack checksum is embedded" {
    const allocator = std.testing.allocator;
    const objects = [_]PackObject{
        .{ .type_str = "blob", .data = "pack checksum embed\n" },
    };
    const pack_data = try buildPackFile(allocator, &objects);
    defer allocator.free(pack_data);

    const idx_data = try idx_writer.generateIdxFromData(allocator, pack_data);
    defer allocator.free(idx_data);

    const pack_checksum = pack_data[pack_data.len - 20 ..];
    const idx_pack_checksum = idx_data[idx_data.len - 40 .. idx_data.len - 20];
    try std.testing.expectEqualSlices(u8, pack_checksum, idx_pack_checksum);
}

// ============================================================================
// git verify-pack interop tests
// ============================================================================

test "git verify-pack accepts savePack + generateIdx output" {
    const allocator = std.testing.allocator;
    const tmp_dir = try setupTmpDir();
    defer cleanupTmpDir(tmp_dir);

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_dir});
    defer allocator.free(git_dir);
    {
        const r = try std.process.Child.run(.{ .allocator = allocator, .argv = &.{ "git", "init", "--bare", git_dir } });
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }

    const objects = [_]PackObject{
        .{ .type_str = "blob", .data = "verify test blob\n" },
        .{ .type_str = "blob", .data = "second blob\n" },
    };
    const pack_data = try buildPackFile(allocator, &objects);
    defer allocator.free(pack_data);

    const hex = try pack_writer.savePack(allocator, git_dir, pack_data);
    defer allocator.free(hex);

    const pp = try pack_writer.packPath(allocator, git_dir, hex);
    defer allocator.free(pp);
    try idx_writer.generateIdx(allocator, pp);

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .max_output_bytes = 10 * 1024 * 1024,
        .argv = &.{ "git", "verify-pack", "-v", pp },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(@as(u8, 0), result.term.Exited);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "blob") != null);
}

test "git verify-pack with mixed types (blob, tree, commit)" {
    const allocator = std.testing.allocator;
    const tmp_dir = try setupTmpDir();
    defer cleanupTmpDir(tmp_dir);

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_dir});
    defer allocator.free(git_dir);
    {
        const r = try std.process.Child.run(.{ .allocator = allocator, .argv = &.{ "git", "init", "--bare", git_dir } });
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }

    const objects = [_]PackObject{
        .{ .type_str = "blob", .data = "content\n" },
        .{ .type_str = "tree", .data = "100644 file.txt\x00" ++ "\x00" ** 20 },
        .{
            .type_str = "commit",
            .data = "tree 4b825dc642cb6eb9a060e54bf899d69f82063700\n" ++
                "author A <a@b.c> 1700000000 +0000\n" ++
                "committer A <a@b.c> 1700000000 +0000\n" ++
                "\ntest\n",
        },
    };
    const pack_data = try buildPackFile(allocator, &objects);
    defer allocator.free(pack_data);

    const hex = try pack_writer.savePack(allocator, git_dir, pack_data);
    defer allocator.free(hex);
    const pp = try pack_writer.packPath(allocator, git_dir, hex);
    defer allocator.free(pp);
    try idx_writer.generateIdx(allocator, pp);

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .max_output_bytes = 10 * 1024 * 1024,
        .argv = &.{ "git", "verify-pack", "-v", pp },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(@as(u8, 0), result.term.Exited);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "blob") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "tree") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "commit") != null);
}

// ============================================================================
// updateRefs tests (clone workflow)
// ============================================================================

test "updateRefsAfterClone writes refs for bare repo" {
    const allocator = std.testing.allocator;
    const tmp_dir = try setupTmpDir();
    defer cleanupTmpDir(tmp_dir);

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_dir});
    defer allocator.free(git_dir);

    // Create minimal git dir structure
    try std.fs.cwd().makePath(git_dir);
    {
        const refs_dir = try std.fmt.allocPrint(allocator, "{s}/refs/heads", .{git_dir});
        defer allocator.free(refs_dir);
        try std.fs.cwd().makePath(refs_dir);
    }
    {
        const refs_dir = try std.fmt.allocPrint(allocator, "{s}/refs/tags", .{git_dir});
        defer allocator.free(refs_dir);
        try std.fs.cwd().makePath(refs_dir);
    }

    const hash = "abcdef0123456789abcdef0123456789abcdef01";
    const refs = [_]pack_writer.RefUpdate{
        .{ .name = "refs/heads/main", .hash = hash },
        .{ .name = "refs/heads/develop", .hash = "1111111111111111111111111111111111111111" },
    };

    try pack_writer.updateRefsAfterClone(allocator, git_dir, &refs, true);

    // Check refs/heads/main
    {
        const path = try std.fmt.allocPrint(allocator, "{s}/refs/heads/main", .{git_dir});
        defer allocator.free(path);
        const content = try std.fs.cwd().readFileAlloc(allocator, path, 1024);
        defer allocator.free(content);
        const trimmed = std.mem.trimRight(u8, content, "\n");
        try std.testing.expectEqualStrings(hash, trimmed);
    }

    // Check refs/heads/develop
    {
        const path = try std.fmt.allocPrint(allocator, "{s}/refs/heads/develop", .{git_dir});
        defer allocator.free(path);
        const content = try std.fs.cwd().readFileAlloc(allocator, path, 1024);
        defer allocator.free(content);
        const trimmed = std.mem.trimRight(u8, content, "\n");
        try std.testing.expectEqualStrings("1111111111111111111111111111111111111111", trimmed);
    }
}

test "updateRefsAfterClone writes HEAD for bare clone" {
    const allocator = std.testing.allocator;
    const tmp_dir = try setupTmpDir();
    defer cleanupTmpDir(tmp_dir);

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_dir});
    defer allocator.free(git_dir);
    try std.fs.cwd().makePath(git_dir);
    {
        const refs_dir = try std.fmt.allocPrint(allocator, "{s}/refs/heads", .{git_dir});
        defer allocator.free(refs_dir);
        try std.fs.cwd().makePath(refs_dir);
    }

    const refs = [_]pack_writer.RefUpdate{
        .{ .name = "refs/heads/main", .hash = "abcdef0123456789abcdef0123456789abcdef01" },
    };

    try pack_writer.updateRefsAfterClone(allocator, git_dir, &refs, true);

    // HEAD should point to refs/heads/main
    const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_dir});
    defer allocator.free(head_path);
    const content = try std.fs.cwd().readFileAlloc(allocator, head_path, 1024);
    defer allocator.free(content);
    const trimmed = std.mem.trimRight(u8, content, "\n");
    try std.testing.expectEqualStrings("ref: refs/heads/main", trimmed);
}

test "updateRefsAfterClone non-bare writes to remotes/origin" {
    const allocator = std.testing.allocator;
    const tmp_dir = try setupTmpDir();
    defer cleanupTmpDir(tmp_dir);

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_dir});
    defer allocator.free(git_dir);
    try std.fs.cwd().makePath(git_dir);
    {
        const refs_dir = try std.fmt.allocPrint(allocator, "{s}/refs/remotes/origin", .{git_dir});
        defer allocator.free(refs_dir);
        try std.fs.cwd().makePath(refs_dir);
    }
    {
        const refs_dir = try std.fmt.allocPrint(allocator, "{s}/refs/heads", .{git_dir});
        defer allocator.free(refs_dir);
        try std.fs.cwd().makePath(refs_dir);
    }

    const refs = [_]pack_writer.RefUpdate{
        .{ .name = "refs/heads/main", .hash = "abcdef0123456789abcdef0123456789abcdef01" },
    };

    try pack_writer.updateRefsAfterClone(allocator, git_dir, &refs, false);

    // Should have refs/remotes/origin/main
    {
        const path = try std.fmt.allocPrint(allocator, "{s}/refs/remotes/origin/main", .{git_dir});
        defer allocator.free(path);
        const content = try std.fs.cwd().readFileAlloc(allocator, path, 1024);
        defer allocator.free(content);
        const trimmed = std.mem.trimRight(u8, content, "\n");
        try std.testing.expectEqualStrings("abcdef0123456789abcdef0123456789abcdef01", trimmed);
    }
}

test "updateRefsAfterClone writes tags directly" {
    const allocator = std.testing.allocator;
    const tmp_dir = try setupTmpDir();
    defer cleanupTmpDir(tmp_dir);

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_dir});
    defer allocator.free(git_dir);
    try std.fs.cwd().makePath(git_dir);
    {
        const refs_dir = try std.fmt.allocPrint(allocator, "{s}/refs/tags", .{git_dir});
        defer allocator.free(refs_dir);
        try std.fs.cwd().makePath(refs_dir);
    }

    const refs = [_]pack_writer.RefUpdate{
        .{ .name = "refs/tags/v1.0", .hash = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" },
    };

    try pack_writer.updateRefsAfterClone(allocator, git_dir, &refs, true);

    const path = try std.fmt.allocPrint(allocator, "{s}/refs/tags/v1.0", .{git_dir});
    defer allocator.free(path);
    const content = try std.fs.cwd().readFileAlloc(allocator, path, 1024);
    defer allocator.free(content);
    const trimmed = std.mem.trimRight(u8, content, "\n");
    try std.testing.expectEqualStrings("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", trimmed);
}

// ============================================================================
// updateRefsAfterFetch tests
// ============================================================================

test "updateRefsAfterFetch updates remotes/origin refs" {
    const allocator = std.testing.allocator;
    const tmp_dir = try setupTmpDir();
    defer cleanupTmpDir(tmp_dir);

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_dir});
    defer allocator.free(git_dir);
    try std.fs.cwd().makePath(git_dir);
    {
        const refs_dir = try std.fmt.allocPrint(allocator, "{s}/refs/remotes/origin", .{git_dir});
        defer allocator.free(refs_dir);
        try std.fs.cwd().makePath(refs_dir);
    }

    const refs = [_]pack_writer.RefUpdate{
        .{ .name = "refs/heads/main", .hash = "cccccccccccccccccccccccccccccccccccccccc" },
        .{ .name = "refs/heads/feature", .hash = "dddddddddddddddddddddddddddddddddddddd" },
    };

    try pack_writer.updateRefsAfterFetch(allocator, git_dir, &refs);

    // Check refs/remotes/origin/main
    {
        const path = try std.fmt.allocPrint(allocator, "{s}/refs/remotes/origin/main", .{git_dir});
        defer allocator.free(path);
        const content = try std.fs.cwd().readFileAlloc(allocator, path, 1024);
        defer allocator.free(content);
        const trimmed = std.mem.trimRight(u8, content, "\n");
        try std.testing.expectEqualStrings("cccccccccccccccccccccccccccccccccccccccc", trimmed);
    }

    // Check refs/remotes/origin/feature
    {
        const path = try std.fmt.allocPrint(allocator, "{s}/refs/remotes/origin/feature", .{git_dir});
        defer allocator.free(path);
        const content = try std.fs.cwd().readFileAlloc(allocator, path, 1024);
        defer allocator.free(content);
        const trimmed = std.mem.trimRight(u8, content, "\n");
        try std.testing.expectEqualStrings("dddddddddddddddddddddddddddddddddddddd", trimmed);
    }
}

test "updateRefsAfterFetch writes FETCH_HEAD" {
    const allocator = std.testing.allocator;
    const tmp_dir = try setupTmpDir();
    defer cleanupTmpDir(tmp_dir);

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_dir});
    defer allocator.free(git_dir);
    try std.fs.cwd().makePath(git_dir);
    {
        const refs_dir = try std.fmt.allocPrint(allocator, "{s}/refs/remotes/origin", .{git_dir});
        defer allocator.free(refs_dir);
        try std.fs.cwd().makePath(refs_dir);
    }

    const refs = [_]pack_writer.RefUpdate{
        .{ .name = "refs/heads/main", .hash = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" },
    };

    try pack_writer.updateRefsAfterFetch(allocator, git_dir, &refs);

    const path = try std.fmt.allocPrint(allocator, "{s}/FETCH_HEAD", .{git_dir});
    defer allocator.free(path);
    const content = try std.fs.cwd().readFileAlloc(allocator, path, 4096);
    defer allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee") != null);
}

test "updateRefsAfterFetch writes tags directly" {
    const allocator = std.testing.allocator;
    const tmp_dir = try setupTmpDir();
    defer cleanupTmpDir(tmp_dir);

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_dir});
    defer allocator.free(git_dir);
    try std.fs.cwd().makePath(git_dir);
    {
        const refs_dir = try std.fmt.allocPrint(allocator, "{s}/refs/tags", .{git_dir});
        defer allocator.free(refs_dir);
        try std.fs.cwd().makePath(refs_dir);
    }
    {
        const refs_dir = try std.fmt.allocPrint(allocator, "{s}/refs/remotes/origin", .{git_dir});
        defer allocator.free(refs_dir);
        try std.fs.cwd().makePath(refs_dir);
    }

    const refs = [_]pack_writer.RefUpdate{
        .{ .name = "refs/tags/v2.0", .hash = "ffffffffffffffffffffffffffffffffffffffff" },
    };

    try pack_writer.updateRefsAfterFetch(allocator, git_dir, &refs);

    const path = try std.fmt.allocPrint(allocator, "{s}/refs/tags/v2.0", .{git_dir});
    defer allocator.free(path);
    const content = try std.fs.cwd().readFileAlloc(allocator, path, 1024);
    defer allocator.free(content);
    const trimmed = std.mem.trimRight(u8, content, "\n");
    try std.testing.expectEqualStrings("ffffffffffffffffffffffffffffffffffffffff", trimmed);
}

// ============================================================================
// Full clone pipeline test (git-created pack -> save -> idx -> verify)
// ============================================================================

test "full pipeline: savePack + generateIdx + git verify-pack with many objects" {
    const allocator = std.testing.allocator;
    const tmp_dir = try setupTmpDir();
    defer cleanupTmpDir(tmp_dir);

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_dir});
    defer allocator.free(git_dir);
    {
        const r = try std.process.Child.run(.{ .allocator = allocator, .argv = &.{ "git", "init", "--bare", git_dir } });
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }

    // Build pack with many blobs
    const objects = [_]PackObject{
        .{ .type_str = "blob", .data = "file1\n" },
        .{ .type_str = "blob", .data = "file2\n" },
        .{ .type_str = "blob", .data = "file3\n" },
        .{ .type_str = "blob", .data = "file4\n" },
        .{ .type_str = "blob", .data = "file5\n" },
        .{ .type_str = "blob", .data = "a longer file with more content to test compression\n" },
        .{ .type_str = "blob", .data = "another blob for good measure\n" },
    };
    const pack_data = try buildPackFile(allocator, &objects);
    defer allocator.free(pack_data);

    const hex = try pack_writer.savePack(allocator, git_dir, pack_data);
    defer allocator.free(hex);

    const pp = try pack_writer.packPath(allocator, git_dir, hex);
    defer allocator.free(pp);
    try idx_writer.generateIdx(allocator, pp);

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .max_output_bytes = 10 * 1024 * 1024,
        .argv = &.{ "git", "verify-pack", "-v", pp },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(@as(u8, 0), result.term.Exited);

    // Count blob lines - should be 7
    var blob_count: usize = 0;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "blob") != null and line.len > 40) {
            blob_count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 7), blob_count);
}

// ============================================================================
// Edge cases
// ============================================================================

test "generateIdxFromData handles empty pack (0 objects)" {
    const allocator = std.testing.allocator;

    // Build pack with 0 objects
    var pack = std.ArrayList(u8).init(allocator);
    defer pack.deinit();
    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, 0, .big);
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack.items);
    var checksum: [20]u8 = undefined;
    hasher.final(&checksum);
    try pack.appendSlice(&checksum);

    const idx_data = try idx_writer.generateIdxFromData(allocator, pack.items);
    defer allocator.free(idx_data);

    // Should have valid header, all-zero fanout, and checksums
    try std.testing.expectEqual(@as(u32, 0xff744f63), std.mem.readInt(u32, idx_data[0..4], .big));
    // Last fanout entry should be 0
    const fanout_last = std.mem.readInt(u32, idx_data[8 + 255 * 4 ..][0..4], .big);
    try std.testing.expectEqual(@as(u32, 0), fanout_last);
}

test "packPath and idxPath produce consistent names" {
    const allocator = std.testing.allocator;
    const hex = "0123456789abcdef0123456789abcdef01234567";
    const pp = try pack_writer.packPath(allocator, "/repo/.git", hex);
    defer allocator.free(pp);
    const ip = try pack_writer.idxPath(allocator, "/repo/.git", hex);
    defer allocator.free(ip);

    // Both should share the same base path
    try std.testing.expectEqualStrings("/repo/.git/objects/pack/pack-0123456789abcdef0123456789abcdef01234567.pack", pp);
    try std.testing.expectEqualStrings("/repo/.git/objects/pack/pack-0123456789abcdef0123456789abcdef01234567.idx", ip);
}
