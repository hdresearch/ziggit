const std = @import("std");
const pack_writer = @import("pack_writer");
const idx_writer = @import("idx_writer");

// ============================================================================
// pack_writer tests
// ============================================================================

test "pack_writer: savePack rejects invalid magic" {
    var buf: [32]u8 = undefined;
    @memcpy(buf[0..4], "JUNK");
    std.mem.writeInt(u32, buf[4..8], 2, .big);
    std.mem.writeInt(u32, buf[8..12], 0, .big);
    @memset(buf[12..32], 0);

    const result = pack_writer.savePack(std.testing.allocator, "/tmp/test_nonexistent", &buf);
    try std.testing.expectError(error.InvalidPackSignature, result);
}

test "pack_writer: savePack rejects too-small data" {
    var buf: [16]u8 = undefined;
    @memset(&buf, 0);
    const result = pack_writer.savePack(std.testing.allocator, "/tmp/test_nonexistent", &buf);
    try std.testing.expectError(error.PackFileTooSmall, result);
}

test "pack_writer: savePack rejects wrong version" {
    var buf: [32]u8 = undefined;
    @memcpy(buf[0..4], "PACK");
    std.mem.writeInt(u32, buf[4..8], 99, .big); // bad version
    std.mem.writeInt(u32, buf[8..12], 0, .big);
    @memset(buf[12..32], 0);

    const result = pack_writer.savePack(std.testing.allocator, "/tmp/test_nonexistent", &buf);
    try std.testing.expectError(error.UnsupportedPackVersion, result);
}

test "pack_writer: savePack rejects bad checksum" {
    var buf: [32]u8 = undefined;
    @memcpy(buf[0..4], "PACK");
    std.mem.writeInt(u32, buf[4..8], 2, .big);
    std.mem.writeInt(u32, buf[8..12], 0, .big);
    @memset(buf[12..32], 0xFF); // wrong checksum

    const result = pack_writer.savePack(std.testing.allocator, "/tmp/test_nonexistent", &buf);
    try std.testing.expectError(error.PackChecksumMismatch, result);
}

test "pack_writer: savePack writes valid empty pack" {
    // Build a valid empty pack: header(12) + SHA-1(20) = 32 bytes
    var buf: [32]u8 = undefined;
    @memcpy(buf[0..4], "PACK");
    std.mem.writeInt(u32, buf[4..8], 2, .big);
    std.mem.writeInt(u32, buf[8..12], 0, .big);

    // Compute correct SHA-1
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(buf[0..12]);
    hasher.final(buf[12..32]);

    const tmp_dir = "/tmp/pack_writer_test";
    std.fs.cwd().deleteTree(tmp_dir) catch {};
    std.fs.cwd().makePath(tmp_dir) catch {};
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};

    const hex = try pack_writer.savePack(std.testing.allocator, tmp_dir, &buf);
    defer std.testing.allocator.free(hex);

    try std.testing.expectEqual(@as(usize, 40), hex.len);

    // Verify file exists
    const pack_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/objects/pack/pack-{s}.pack", .{ tmp_dir, hex });
    defer std.testing.allocator.free(pack_path);
    const stat = try std.fs.cwd().statFile(pack_path);
    try std.testing.expectEqual(@as(u64, 32), stat.size);
}

// ============================================================================
// idx_writer tests
// ============================================================================

test "idx_writer: generateIdxFromData rejects invalid pack" {
    var buf: [16]u8 = undefined;
    @memset(&buf, 0);
    const result = idx_writer.generateIdxFromData(std.testing.allocator, &buf);
    try std.testing.expectError(error.PackFileTooSmall, result);
}

test "idx_writer: generateIdxFromData produces valid idx for empty pack" {
    // Build a valid empty pack
    var buf: [32]u8 = undefined;
    @memcpy(buf[0..4], "PACK");
    std.mem.writeInt(u32, buf[4..8], 2, .big);
    std.mem.writeInt(u32, buf[8..12], 0, .big);
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(buf[0..12]);
    hasher.final(buf[12..32]);

    const idx_data = try idx_writer.generateIdxFromData(std.testing.allocator, &buf);
    defer std.testing.allocator.free(idx_data);

    // Verify idx v2 header
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xff, 0x74, 0x4f, 0x63 }, idx_data[0..4]);
    const version = std.mem.readInt(u32, idx_data[4..8], .big);
    try std.testing.expectEqual(@as(u32, 2), version);

    // Fanout table: 256 * 4 bytes, all zeros for empty pack
    // Total minimum: 8 (header) + 1024 (fanout) + 20 (pack checksum) + 20 (idx checksum) = 1072
    try std.testing.expectEqual(@as(usize, 1072), idx_data.len);
}

test "idx_writer: generateIdxFromData with single blob" {
    // Build a minimal pack with one blob object
    var pack = std.ArrayList(u8).init(std.testing.allocator);
    defer pack.deinit();

    // Header
    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big); // version
    try pack.writer().writeInt(u32, 1, .big); // 1 object

    // Object: blob type (3), small size
    const content = "hello world\n";
    // type=3(blob), size=12 -> first byte: 0x30 | 12 = 0x3C (no continuation needed since 12 < 16)
    try pack.append(0x30 | @as(u8, @intCast(content.len)));

    // Compress content
    var compressed = std.ArrayList(u8).init(std.testing.allocator);
    defer compressed.deinit();
    var compressor = try std.compress.zlib.compressor(compressed.writer(), .{});
    try compressor.writer().writeAll(content);
    try compressor.finish();
    try pack.appendSlice(compressed.items);

    // Pack checksum
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack.items);
    var checksum: [20]u8 = undefined;
    hasher.final(&checksum);
    try pack.appendSlice(&checksum);

    const idx_data = try idx_writer.generateIdxFromData(std.testing.allocator, pack.items);
    defer std.testing.allocator.free(idx_data);

    // Should have 1 object
    // fanout[255] should be 1
    const fanout_end = 8 + 256 * 4;
    const total_objects = std.mem.readInt(u32, idx_data[fanout_end - 4 ..][0..4], .big);
    try std.testing.expectEqual(@as(u32, 1), total_objects);

    // Verify the SHA-1 matches what git would compute for "blob 12\0hello world\n"
    var expected_sha: [20]u8 = undefined;
    var sha_hasher = std.crypto.hash.Sha1.init(.{});
    sha_hasher.update("blob 12\x00");
    sha_hasher.update(content);
    sha_hasher.final(&expected_sha);

    // SHA-1 table starts at offset fanout_end
    try std.testing.expectEqualSlices(u8, &expected_sha, idx_data[fanout_end .. fanout_end + 20]);
}

// ============================================================================
// Integration: round-trip pack_writer + idx_writer verified by git
// ============================================================================

test "roundtrip: savePack + generateIdx readable by git" {
    // Build a minimal pack with one blob
    var pack = std.ArrayList(u8).init(std.testing.allocator);
    defer pack.deinit();

    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, 1, .big);

    const content = "test content for roundtrip\n";
    try pack.append(0x30 | @as(u8, @intCast(content.len & 0x0F)));
    if (content.len >= 16) {
        // Need continuation byte. Actually 27 > 15 so we do need it.
        // Re-encode: first byte has low 4 bits of size + continuation bit
        pack.items[pack.items.len - 1] = 0x30 | @as(u8, @intCast(content.len & 0x0F)) | 0x80;
        try pack.append(@as(u8, @intCast((content.len >> 4) & 0x7F)));
    }

    var compressed = std.ArrayList(u8).init(std.testing.allocator);
    defer compressed.deinit();
    var compressor = try std.compress.zlib.compressor(compressed.writer(), .{});
    try compressor.writer().writeAll(content);
    try compressor.finish();
    try pack.appendSlice(compressed.items);

    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack.items);
    var checksum: [20]u8 = undefined;
    hasher.final(&checksum);
    try pack.appendSlice(&checksum);

    const tmp_dir = "/tmp/pack_roundtrip_test";
    std.fs.cwd().deleteTree(tmp_dir) catch {};
    std.fs.cwd().makePath(tmp_dir) catch {};
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};

    // Save pack
    const hex = try pack_writer.savePack(std.testing.allocator, tmp_dir, pack.items);
    defer std.testing.allocator.free(hex);

    // Generate idx
    const pp = try pack_writer.packPath(std.testing.allocator, tmp_dir, hex);
    defer std.testing.allocator.free(pp);
    try idx_writer.generateIdx(std.testing.allocator, pp);

    // Verify idx file exists
    const ip = try pack_writer.idxPath(std.testing.allocator, tmp_dir, hex);
    defer std.testing.allocator.free(ip);
    _ = try std.fs.cwd().statFile(ip);

    // Cross-validate with git verify-pack if available
    const result = std.process.Child.run(.{
        .allocator = std.testing.allocator,
        .argv = &.{ "git", "verify-pack", "-v", pp },
    });
    if (result) |res| {
        defer std.testing.allocator.free(res.stdout);
        defer std.testing.allocator.free(res.stderr);
        // git verify-pack should succeed (exit 0)
        try std.testing.expectEqual(@as(u8, 0), res.term.Exited);
    } else |_| {
        // git not available, skip cross-validation
    }
}
