const std = @import("std");
const idx_writer = @import("idx_writer");

// ============================================================================
// Helper: build pack files with OFS_DELTA objects
// ============================================================================

fn compressData(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var compressed = std.ArrayList(u8).init(allocator);
    errdefer compressed.deinit();
    var compressor = try std.compress.zlib.compressor(compressed.writer(), .{});
    try compressor.writer().writeAll(data);
    try compressor.finish();
    return compressed.toOwnedSlice();
}

fn encodePackHeader(buf: *std.ArrayList(u8), obj_type: u3, size: usize) !void {
    var s = size;
    var first_byte: u8 = (@as(u8, obj_type) << 4) | @as(u8, @intCast(s & 0x0F));
    s >>= 4;
    if (s > 0) first_byte |= 0x80;
    try buf.append(first_byte);
    while (s > 0) {
        var b: u8 = @intCast(s & 0x7F);
        s >>= 7;
        if (s > 0) b |= 0x80;
        try buf.append(b);
    }
}

fn encodeDeltaVarint(buf: *std.ArrayList(u8), value: usize) !void {
    var v = value;
    while (true) {
        var b: u8 = @intCast(v & 0x7F);
        v >>= 7;
        if (v > 0) b |= 0x80;
        try buf.append(b);
        if (v == 0) break;
    }
}

fn encodeOfsOffset(buf: *std.ArrayList(u8), negative_offset: usize) !void {
    // Encode the negative offset as git does
    var offset = negative_offset;
    var bytes: [10]u8 = undefined;
    var n: usize = 0;
    bytes[n] = @intCast(offset & 0x7F);
    n += 1;
    offset >>= 7;
    while (offset > 0) {
        offset -= 1;
        bytes[n] = @intCast(0x80 | (offset & 0x7F));
        n += 1;
        offset >>= 7;
    }
    // Write in reverse order
    while (n > 0) {
        n -= 1;
        try buf.append(bytes[n]);
    }
}

/// Build a delta instruction stream: copy the whole base then insert extra data
fn buildCopyDelta(allocator: std.mem.Allocator, base_size: usize, result_data: []const u8) ![]u8 {
    var delta = std.ArrayList(u8).init(allocator);
    errdefer delta.deinit();

    // Base size varint
    try encodeDeltaVarint(&delta, base_size);
    // Result size varint
    try encodeDeltaVarint(&delta, result_data.len);

    // Copy command: copy base_size bytes from offset 0
    // cmd byte: 0x80 | flags
    // For offset=0 and size=base_size (assuming base_size < 256):
    if (base_size > 0 and base_size < 0x10000) {
        var cmd: u8 = 0x80;
        // offset=0: no offset bytes needed (zero means no flags set for offset)
        // size: need to encode it
        if (base_size & 0xFF != 0) cmd |= 0x10;
        if (base_size >> 8 != 0) cmd |= 0x20;
        try delta.append(cmd);
        if (base_size & 0xFF != 0) try delta.append(@intCast(base_size & 0xFF));
        if (base_size >> 8 != 0) try delta.append(@intCast((base_size >> 8) & 0xFF));
    }

    // Insert command for the extra data after the base content
    const extra = result_data[base_size..];
    if (extra.len > 0 and extra.len < 128) {
        try delta.append(@intCast(extra.len));
        try delta.appendSlice(extra);
    }

    return delta.toOwnedSlice();
}

fn setupTmpDir() ![]const u8 {
    const allocator = std.testing.allocator;
    const tmp = try std.fmt.allocPrint(allocator, "/tmp/ziggit_delta_test_{}", .{std.crypto.random.int(u64)});
    try std.fs.cwd().makePath(tmp);
    return tmp;
}

fn cleanupTmpDir(path: []const u8) void {
    std.fs.cwd().deleteTree(path) catch {};
    std.testing.allocator.free(path);
}

// ============================================================================
// OFS_DELTA idx generation tests
// ============================================================================

test "generateIdxFromData with OFS_DELTA object" {
    const allocator = std.testing.allocator;

    // Build a pack with: base blob + OFS_DELTA referencing it
    var pack = std.ArrayList(u8).init(allocator);
    defer pack.deinit();

    // Pack header
    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, 2, .big); // 2 objects

    // Object 1: base blob "Hello World\n"
    const base_data = "Hello World\n";
    const base_offset = pack.items.len;
    try encodePackHeader(&pack, 3, base_data.len); // type=3 (blob)
    const base_compressed = try compressData(allocator, base_data);
    defer allocator.free(base_compressed);
    try pack.appendSlice(base_compressed);

    // Object 2: OFS_DELTA extending the blob to "Hello World\nExtra line\n"
    const delta_target = "Hello World\nExtra line\n";
    const delta_offset = pack.items.len;
    const delta_instr = try buildCopyDelta(allocator, base_data.len, delta_target);
    defer allocator.free(delta_instr);

    try encodePackHeader(&pack, 6, delta_instr.len); // type=6 (ofs_delta)
    // Encode negative offset (distance from current object to base)
    try encodeOfsOffset(&pack, delta_offset - base_offset);
    // Compress delta instructions
    const delta_compressed = try compressData(allocator, delta_instr);
    defer allocator.free(delta_compressed);
    try pack.appendSlice(delta_compressed);

    // Pack checksum
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack.items);
    var checksum: [20]u8 = undefined;
    hasher.final(&checksum);
    try pack.appendSlice(&checksum);

    // Generate idx
    const idx_data = try idx_writer.generateIdxFromData(allocator, pack.items);
    defer allocator.free(idx_data);

    // Verify: should have 2 objects
    const fanout_end = 8 + 256 * 4;
    const total = std.mem.readInt(u32, idx_data[fanout_end - 4 ..][0..4], .big);
    try std.testing.expectEqual(@as(u32, 2), total);

    // Verify: SHA-1 entries are sorted
    const sha_start = fanout_end;
    const sha1 = idx_data[sha_start..][0..20];
    const sha2 = idx_data[sha_start + 20 ..][0..20];
    try std.testing.expect(std.mem.order(u8, sha1, sha2) == .lt);
}

test "git verify-pack accepts pack with OFS_DELTA" {
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

    // Build pack with base + OFS_DELTA
    var pack = std.ArrayList(u8).init(allocator);
    defer pack.deinit();

    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, 2, .big);

    const base_data = "Hello World\n";
    const base_offset = pack.items.len;
    try encodePackHeader(&pack, 3, base_data.len);
    const base_compressed = try compressData(allocator, base_data);
    defer allocator.free(base_compressed);
    try pack.appendSlice(base_compressed);

    const delta_target = "Hello World\nExtra line\n";
    const delta_offset = pack.items.len;
    const delta_instr = try buildCopyDelta(allocator, base_data.len, delta_target);
    defer allocator.free(delta_instr);

    try encodePackHeader(&pack, 6, delta_instr.len);
    try encodeOfsOffset(&pack, delta_offset - base_offset);
    const delta_compressed = try compressData(allocator, delta_instr);
    defer allocator.free(delta_compressed);
    try pack.appendSlice(delta_compressed);

    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack.items);
    var cksum: [20]u8 = undefined;
    hasher.final(&cksum);
    try pack.appendSlice(&cksum);

    // Save and generate idx
    const pack_dir = try std.fmt.allocPrint(allocator, "{s}/objects/pack", .{git_dir});
    defer allocator.free(pack_dir);
    std.fs.cwd().makePath(pack_dir) catch {};

    // Get checksum hex for naming
    const hex = try std.fmt.allocPrint(allocator, "{s}", .{std.fmt.fmtSliceHexLower(&cksum)});
    defer allocator.free(hex);
    const pack_path = try std.fmt.allocPrint(allocator, "{s}/pack-{s}.pack", .{ pack_dir, hex });
    defer allocator.free(pack_path);

    {
        const f = try std.fs.cwd().createFile(pack_path, .{});
        defer f.close();
        try f.writeAll(pack.items);
    }

    try idx_writer.generateIdx(allocator, pack_path);

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .max_output_bytes = 10 * 1024 * 1024,
        .argv = &.{ "git", "verify-pack", "-v", pack_path },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(@as(u8, 0), result.term.Exited);
    // Should show delta object
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "blob") != null);
}

// ============================================================================
// Edge case tests
// ============================================================================

test "generateIdxFromData with large object count still produces valid idx" {
    const allocator = std.testing.allocator;

    // Build a pack with 20 blobs
    const N = 20;
    var pack = std.ArrayList(u8).init(allocator);
    defer pack.deinit();

    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, N, .big);

    for (0..N) |i| {
        var buf: [64]u8 = undefined;
        const data = std.fmt.bufPrint(&buf, "blob content number {}\n", .{i}) catch unreachable;
        try encodePackHeader(&pack, 3, data.len);
        const compressed = try compressData(allocator, data);
        defer allocator.free(compressed);
        try pack.appendSlice(compressed);
    }

    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack.items);
    var cksum: [20]u8 = undefined;
    hasher.final(&cksum);
    try pack.appendSlice(&cksum);

    const idx_data = try idx_writer.generateIdxFromData(allocator, pack.items);
    defer allocator.free(idx_data);

    const fanout_end = 8 + 256 * 4;
    const total = std.mem.readInt(u32, idx_data[fanout_end - 4 ..][0..4], .big);
    try std.testing.expectEqual(@as(u32, N), total);

    // Verify sorted SHA-1 table
    const sha_start = fanout_end;
    var prev: [20]u8 = [_]u8{0} ** 20;
    for (0..N) |i| {
        const sha = idx_data[sha_start + i * 20 ..][0..20];
        try std.testing.expect(std.mem.order(u8, &prev, sha) != .gt);
        @memcpy(&prev, sha);
    }
}

test "generateIdxFromData SHA-1 matches git hash-object" {
    const allocator = std.testing.allocator;
    const tmp_dir = try setupTmpDir();
    defer cleanupTmpDir(tmp_dir);

    const blob_content = "known content for hash validation\n";

    // Compute expected SHA-1 manually (same as git hash-object)
    const expected_sha = blk: {
        var h = std.crypto.hash.Sha1.init(.{});
        var hdr_buf: [64]u8 = undefined;
        const hdr = std.fmt.bufPrint(&hdr_buf, "blob {}\x00", .{blob_content.len}) catch unreachable;
        h.update(hdr);
        h.update(blob_content);
        var sha: [20]u8 = undefined;
        h.final(&sha);
        break :blk sha;
    };

    // Build single-blob pack
    var pack = std.ArrayList(u8).init(allocator);
    defer pack.deinit();
    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, 1, .big);
    try encodePackHeader(&pack, 3, blob_content.len);
    const compressed = try compressData(allocator, blob_content);
    defer allocator.free(compressed);
    try pack.appendSlice(compressed);
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack.items);
    var cksum: [20]u8 = undefined;
    hasher.final(&cksum);
    try pack.appendSlice(&cksum);

    const idx_data = try idx_writer.generateIdxFromData(allocator, pack.items);
    defer allocator.free(idx_data);

    // Extract SHA-1 from idx
    const sha_start = 8 + 256 * 4;
    const idx_sha = idx_data[sha_start..][0..20];
    try std.testing.expectEqualSlices(u8, &expected_sha, idx_sha);
}
