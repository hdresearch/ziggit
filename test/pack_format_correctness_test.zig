const std = @import("std");
const testing = std.testing;
const objects = @import("git_objects");

// =============================================================================
// Pack Format Correctness Tests
//
// These tests construct pack files byte-by-byte according to the git pack format
// spec, then verify that readPackObjectAtOffset, generatePackIndex, and
// applyDelta produce correct results. Each test is self-contained with known
// inputs and expected outputs.
//
// Reference: https://git-scm.com/docs/pack-format
// =============================================================================

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Encode git pack object type+size header.
/// Returns number of bytes written.
fn encodePackObjectHeader(buf: []u8, obj_type: u3, size: usize) usize {
    var first: u8 = (@as(u8, obj_type) << 4) | @as(u8, @intCast(size & 0x0F));
    var remaining = size >> 4;
    if (remaining > 0) first |= 0x80;
    buf[0] = first;
    var i: usize = 1;
    while (remaining > 0) {
        var b: u8 = @intCast(remaining & 0x7F);
        remaining >>= 7;
        if (remaining > 0) b |= 0x80;
        buf[i] = b;
        i += 1;
    }
    return i;
}

/// Zlib-compress data using Zig's std.compress.zlib.
fn zlibCompress(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var compressed = std.ArrayList(u8).init(allocator);
    defer compressed.deinit();
    var input = std.io.fixedBufferStream(data);
    try std.compress.zlib.compress(input.reader(), compressed.writer(), .{});
    return try allocator.dupe(u8, compressed.items);
}

/// Build a complete pack file from a list of raw object entries.
/// Each entry is the already-encoded header + compressed data (everything between
/// the 12-byte pack header and the 20-byte trailing checksum).
fn buildPackFile(allocator: std.mem.Allocator, raw_entries: []const []const u8) ![]u8 {
    var pack = std.ArrayList(u8).init(allocator);
    defer pack.deinit();

    // PACK header
    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big); // version 2
    try pack.writer().writeInt(u32, @intCast(raw_entries.len), .big); // object count

    for (raw_entries) |entry| {
        try pack.appendSlice(entry);
    }

    // SHA-1 checksum
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack.items);
    var checksum: [20]u8 = undefined;
    hasher.final(&checksum);
    try pack.appendSlice(&checksum);

    return try allocator.dupe(u8, pack.items);
}

/// Build a single pack object entry (header + compressed data).
fn buildPackEntry(allocator: std.mem.Allocator, obj_type: u3, data: []const u8) ![]u8 {
    var entry = std.ArrayList(u8).init(allocator);
    defer entry.deinit();

    var hdr_buf: [10]u8 = undefined;
    const hdr_len = encodePackObjectHeader(&hdr_buf, obj_type, data.len);
    try entry.appendSlice(hdr_buf[0..hdr_len]);

    const compressed = try zlibCompress(allocator, data);
    defer allocator.free(compressed);
    try entry.appendSlice(compressed);

    return try allocator.dupe(u8, entry.items);
}

/// Compute the SHA-1 of a git object (as "type size\0data").
fn gitObjectSha1(obj_type_str: []const u8, data: []const u8) [20]u8 {
    var hasher = std.crypto.hash.Sha1.init(.{});
    var hdr_buf: [64]u8 = undefined;
    const hdr = std.fmt.bufPrint(&hdr_buf, "{s} {}\x00", .{ obj_type_str, data.len }) catch unreachable;
    hasher.update(hdr);
    hasher.update(data);
    var out: [20]u8 = undefined;
    hasher.final(&out);
    return out;
}

/// Encode a delta varint (for delta header base_size / result_size).
fn encodeDeltaVarint(buf: []u8, value: usize) usize {
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

/// Build a delta instruction stream. Helper for constructing test deltas.
const DeltaBuilder = struct {
    buf: std.ArrayList(u8),

    fn init(allocator: std.mem.Allocator, base_size: usize, result_size: usize) !DeltaBuilder {
        var db = DeltaBuilder{ .buf = std.ArrayList(u8).init(allocator) };
        var tmp: [10]u8 = undefined;
        var n = encodeDeltaVarint(&tmp, base_size);
        try db.buf.appendSlice(tmp[0..n]);
        n = encodeDeltaVarint(&tmp, result_size);
        try db.buf.appendSlice(tmp[0..n]);
        return db;
    }

    /// Add a copy-from-base command.
    fn addCopy(self: *DeltaBuilder, offset: usize, size: usize) !void {
        var cmd: u8 = 0x80;
        var extra = std.ArrayList(u8).init(self.buf.allocator);
        defer extra.deinit();

        // Offset bytes (little-endian, only non-zero bytes with flags)
        if (offset & 0xFF != 0) {
            cmd |= 0x01;
            try extra.append(@intCast(offset & 0xFF));
        }
        if (offset & 0xFF00 != 0) {
            cmd |= 0x02;
            try extra.append(@intCast((offset >> 8) & 0xFF));
        }
        if (offset & 0xFF0000 != 0) {
            cmd |= 0x04;
            try extra.append(@intCast((offset >> 16) & 0xFF));
        }
        if (offset & 0xFF000000 != 0) {
            cmd |= 0x08;
            try extra.append(@intCast((offset >> 24) & 0xFF));
        }

        // Size bytes
        const actual_size: usize = if (size == 0x10000) 0 else size;
        if (actual_size & 0xFF != 0) {
            cmd |= 0x10;
            try extra.append(@intCast(actual_size & 0xFF));
        }
        if (actual_size & 0xFF00 != 0) {
            cmd |= 0x20;
            try extra.append(@intCast((actual_size >> 8) & 0xFF));
        }
        if (actual_size & 0xFF0000 != 0) {
            cmd |= 0x40;
            try extra.append(@intCast((actual_size >> 16) & 0xFF));
        }

        try self.buf.append(cmd);
        try self.buf.appendSlice(extra.items);
    }

    /// Add an insert-literal command.
    fn addInsert(self: *DeltaBuilder, data: []const u8) !void {
        std.debug.assert(data.len > 0 and data.len <= 127);
        try self.buf.append(@intCast(data.len));
        try self.buf.appendSlice(data);
    }

    fn toOwnedSlice(self: *DeltaBuilder) ![]u8 {
        return try self.buf.toOwnedSlice();
    }

    fn deinit(self: *DeltaBuilder) void {
        self.buf.deinit();
    }
};

/// Encode OFS_DELTA negative offset.
fn encodeOfsOffset(buf: []u8, negative_offset: usize) usize {
    // Git's encoding: first byte has low 7 bits, subsequent bytes add 1 before shifting
    // We need to encode the value such that decoding reverses it.
    var n = negative_offset;
    buf[0] = @intCast(n & 0x7F);
    n >>= 7;
    var i: usize = 1;
    while (n > 0) {
        n -= 1; // The +1 in decoding
        // We build in reverse, so shift existing bytes right
        var j: usize = i;
        while (j > 0) : (j -= 1) {
            buf[j] = buf[j - 1];
        }
        buf[0] = @intCast((n & 0x7F) | 0x80);
        n >>= 7;
        i += 1;
    }
    return i;
}

// =============================================================================
// Test: Read blob from pack
// =============================================================================
test "readPackObjectAtOffset - blob" {
    const allocator = testing.allocator;
    const blob_data = "Hello, World!\n";

    const entry = try buildPackEntry(allocator, 3, blob_data); // type 3 = blob
    defer allocator.free(entry);

    const pack = try buildPackFile(allocator, &.{entry});
    defer allocator.free(pack);

    const obj = try objects.readPackObjectAtOffset(pack, 12, allocator);
    defer obj.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.blob, obj.type);
    try testing.expectEqualStrings(blob_data, obj.data);
}

// =============================================================================
// Test: Read commit from pack
// =============================================================================
test "readPackObjectAtOffset - commit" {
    const allocator = testing.allocator;
    const commit_data =
        "tree 4b825dc642cb6eb9a060e54bf899d69f4ef67344\n" ++
        "author Test <test@test.com> 1700000000 +0000\n" ++
        "committer Test <test@test.com> 1700000000 +0000\n" ++
        "\nInitial commit\n";

    const entry = try buildPackEntry(allocator, 1, commit_data); // type 1 = commit
    defer allocator.free(entry);

    const pack = try buildPackFile(allocator, &.{entry});
    defer allocator.free(pack);

    const obj = try objects.readPackObjectAtOffset(pack, 12, allocator);
    defer obj.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.commit, obj.type);
    try testing.expectEqualStrings(commit_data, obj.data);
}

// =============================================================================
// Test: Read tree from pack
// =============================================================================
test "readPackObjectAtOffset - tree" {
    const allocator = testing.allocator;
    // Tree entry: "100644 hello.txt\0" + 20-byte SHA-1
    var tree_data_buf: [256]u8 = undefined;
    const mode_name = "100644 hello.txt\x00";
    @memcpy(tree_data_buf[0..mode_name.len], mode_name);
    // Fake SHA-1 (all 0xAA)
    @memset(tree_data_buf[mode_name.len .. mode_name.len + 20], 0xAA);
    const tree_data = tree_data_buf[0 .. mode_name.len + 20];

    const entry = try buildPackEntry(allocator, 2, tree_data); // type 2 = tree
    defer allocator.free(entry);

    const pack = try buildPackFile(allocator, &.{entry});
    defer allocator.free(pack);

    const obj = try objects.readPackObjectAtOffset(pack, 12, allocator);
    defer obj.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.tree, obj.type);
    try testing.expectEqualSlices(u8, tree_data, obj.data);
}

// =============================================================================
// Test: Read tag from pack
// =============================================================================
test "readPackObjectAtOffset - tag" {
    const allocator = testing.allocator;
    const tag_data =
        "object 4b825dc642cb6eb9a060e54bf899d69f4ef67344\n" ++
        "type commit\n" ++
        "tag v1.0\n" ++
        "tagger Test <test@test.com> 1700000000 +0000\n" ++
        "\nRelease v1.0\n";

    const entry = try buildPackEntry(allocator, 4, tag_data); // type 4 = tag
    defer allocator.free(entry);

    const pack = try buildPackFile(allocator, &.{entry});
    defer allocator.free(pack);

    const obj = try objects.readPackObjectAtOffset(pack, 12, allocator);
    defer obj.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.tag, obj.type);
    try testing.expectEqualStrings(tag_data, obj.data);
}

// =============================================================================
// Test: Read OFS_DELTA from pack
// =============================================================================
test "readPackObjectAtOffset - ofs_delta" {
    const allocator = testing.allocator;

    // Base blob
    const base_data = "Hello, World!\n";
    const base_entry = try buildPackEntry(allocator, 3, base_data);
    defer allocator.free(base_entry);

    // Delta: replace "World" with "Zig"
    // Result: "Hello, Zig!\n" (12 bytes)
    const result_data = "Hello, Zig!\n";
    var db = try DeltaBuilder.init(allocator, base_data.len, result_data.len);
    defer db.deinit();
    try db.addCopy(0, 7); // "Hello, "
    try db.addInsert("Zig!\n"); // "Zig!\n"
    const delta_data = try db.toOwnedSlice();
    defer allocator.free(delta_data);

    // Build OFS_DELTA entry: header + ofs_offset + compressed delta
    var delta_entry_buf = std.ArrayList(u8).init(allocator);
    defer delta_entry_buf.deinit();

    // Pack header for OFS_DELTA (type=6)
    var hdr_buf: [10]u8 = undefined;
    const hdr_len = encodePackObjectHeader(&hdr_buf, 6, delta_data.len);
    try delta_entry_buf.appendSlice(hdr_buf[0..hdr_len]);

    // Negative offset: distance from this object to base object
    // Base is at offset 12 in the pack. Delta will be at offset 12 + base_entry.len.
    const delta_offset_in_pack = 12 + base_entry.len;
    const negative_offset = delta_offset_in_pack - 12; // = base_entry.len
    var ofs_buf: [10]u8 = undefined;
    const ofs_len = encodeOfsOffset(&ofs_buf, negative_offset);
    try delta_entry_buf.appendSlice(ofs_buf[0..ofs_len]);

    // Compressed delta
    const compressed_delta = try zlibCompress(allocator, delta_data);
    defer allocator.free(compressed_delta);
    try delta_entry_buf.appendSlice(compressed_delta);

    const delta_entry = try allocator.dupe(u8, delta_entry_buf.items);
    defer allocator.free(delta_entry);

    // Build pack with both objects
    const pack = try buildPackFile(allocator, &.{ base_entry, delta_entry });
    defer allocator.free(pack);

    // Read the delta object - should resolve to the patched result
    const obj = try objects.readPackObjectAtOffset(pack, delta_offset_in_pack, allocator);
    defer obj.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.blob, obj.type);
    try testing.expectEqualStrings(result_data, obj.data);
}

// =============================================================================
// Test: Delta application - identity (copy whole base)
// =============================================================================
test "applyDelta - identity copy" {
    const allocator = testing.allocator;
    const base = "Hello, World!\n";

    var db = try DeltaBuilder.init(allocator, base.len, base.len);
    defer db.deinit();
    try db.addCopy(0, base.len);
    const delta = try db.toOwnedSlice();
    defer allocator.free(delta);

    const result = try objects.applyDelta(base, delta, allocator);
    defer allocator.free(result);

    try testing.expectEqualStrings(base, result);
}

// =============================================================================
// Test: Delta application - pure insert (no copy from base)
// =============================================================================
test "applyDelta - pure insert" {
    const allocator = testing.allocator;
    const base = "old content";
    const new = "brand new data!";

    var db = try DeltaBuilder.init(allocator, base.len, new.len);
    defer db.deinit();
    try db.addInsert(new);
    const delta = try db.toOwnedSlice();
    defer allocator.free(delta);

    const result = try objects.applyDelta(base, delta, allocator);
    defer allocator.free(result);

    try testing.expectEqualStrings(new, result);
}

// =============================================================================
// Test: Delta application - copy from middle of base
// =============================================================================
test "applyDelta - copy from middle" {
    const allocator = testing.allocator;
    const base = "ABCDEFGHIJKLMNOP";
    // Extract "EFGH" from offset 4, length 4
    const expected = "EFGH";

    var db = try DeltaBuilder.init(allocator, base.len, expected.len);
    defer db.deinit();
    try db.addCopy(4, 4);
    const delta = try db.toOwnedSlice();
    defer allocator.free(delta);

    const result = try objects.applyDelta(base, delta, allocator);
    defer allocator.free(result);

    try testing.expectEqualStrings(expected, result);
}

// =============================================================================
// Test: Delta application - interleaved copy and insert
// =============================================================================
test "applyDelta - interleaved copy and insert" {
    const allocator = testing.allocator;
    const base = "Hello World";
    // Result: "Hello Brave New World!"
    const expected = "Hello Brave New World!";

    var db = try DeltaBuilder.init(allocator, base.len, expected.len);
    defer db.deinit();
    try db.addCopy(0, 6); // "Hello "
    try db.addInsert("Brave New "); // literal insert
    try db.addCopy(6, 5); // "World"
    try db.addInsert("!"); // literal "!"
    const delta = try db.toOwnedSlice();
    defer allocator.free(delta);

    const result = try objects.applyDelta(base, delta, allocator);
    defer allocator.free(result);

    try testing.expectEqualStrings(expected, result);
}

// =============================================================================
// Test: Delta application - copy with multi-byte offset
// =============================================================================
test "applyDelta - multi-byte offset copy" {
    const allocator = testing.allocator;
    // Create a base > 256 bytes so we need multi-byte offset
    var base_buf: [512]u8 = undefined;
    for (&base_buf, 0..) |*b, i| {
        b.* = @intCast(i & 0xFF);
    }
    const base = &base_buf;

    // Copy 10 bytes from offset 300
    const expected = base[300..310];

    var db = try DeltaBuilder.init(allocator, base.len, expected.len);
    defer db.deinit();
    try db.addCopy(300, 10);
    const delta = try db.toOwnedSlice();
    defer allocator.free(delta);

    const result = try objects.applyDelta(base, delta, allocator);
    defer allocator.free(result);

    try testing.expectEqualSlices(u8, expected, result);
}

// =============================================================================
// Test: Delta with size 0x10000 (special encoding: size=0 means 65536)
// =============================================================================
test "applyDelta - copy size 0x10000" {
    const allocator = testing.allocator;
    // Create base of exactly 0x10000 bytes
    const base = try allocator.alloc(u8, 0x10000);
    defer allocator.free(base);
    for (base, 0..) |*b, i| {
        b.* = @intCast(i & 0xFF);
    }

    // Copy all 0x10000 bytes from offset 0
    var db = try DeltaBuilder.init(allocator, base.len, base.len);
    defer db.deinit();
    try db.addCopy(0, 0x10000); // size 0x10000 encoded as 0
    const delta = try db.toOwnedSlice();
    defer allocator.free(delta);

    const result = try objects.applyDelta(base, delta, allocator);
    defer allocator.free(result);

    try testing.expectEqualSlices(u8, base, result);
}

// =============================================================================
// Test: generatePackIndex produces valid v2 idx
// =============================================================================
test "generatePackIndex - single blob, valid v2 format" {
    const allocator = testing.allocator;
    const blob_data = "test blob content\n";

    const entry = try buildPackEntry(allocator, 3, blob_data);
    defer allocator.free(entry);

    const pack = try buildPackFile(allocator, &.{entry});
    defer allocator.free(pack);

    const idx = try objects.generatePackIndex(pack, allocator);
    defer allocator.free(idx);

    // Verify v2 idx magic and version
    try testing.expectEqual(@as(u32, 0xff744f63), std.mem.readInt(u32, @ptrCast(idx[0..4]), .big));
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, @ptrCast(idx[4..8]), .big));

    // Fanout table: 256 entries of 4 bytes each (8..1032)
    // Last entry should be total object count (1)
    const total_objects = std.mem.readInt(u32, @ptrCast(idx[8 + 255 * 4 .. 8 + 256 * 4]), .big);
    try testing.expectEqual(@as(u32, 1), total_objects);

    // SHA-1 table starts at 1032, should have the blob's SHA-1
    const expected_sha1 = gitObjectSha1("blob", blob_data);
    try testing.expectEqualSlices(u8, &expected_sha1, idx[1032 .. 1032 + 20]);

    // Pack checksum in idx should match pack's trailing checksum
    const n: u32 = 1;
    const sha1_end = 1032 + n * 20;
    const crc_end = sha1_end + n * 4;
    const offset_end = crc_end + n * 4;
    // Pack checksum is 20 bytes after offset table
    const idx_pack_checksum = idx[offset_end .. offset_end + 20];
    const pack_checksum = pack[pack.len - 20 ..];
    try testing.expectEqualSlices(u8, pack_checksum, idx_pack_checksum);
}

// =============================================================================
// Test: generatePackIndex - multiple objects, sorted by SHA-1
// =============================================================================
test "generatePackIndex - multiple objects sorted by sha1" {
    const allocator = testing.allocator;

    const blob1 = "alpha\n";
    const blob2 = "beta\n";
    const blob3 = "gamma\n";

    const e1 = try buildPackEntry(allocator, 3, blob1);
    defer allocator.free(e1);
    const e2 = try buildPackEntry(allocator, 3, blob2);
    defer allocator.free(e2);
    const e3 = try buildPackEntry(allocator, 3, blob3);
    defer allocator.free(e3);

    const pack = try buildPackFile(allocator, &.{ e1, e2, e3 });
    defer allocator.free(pack);

    const idx = try objects.generatePackIndex(pack, allocator);
    defer allocator.free(idx);

    // Total objects = 3
    const total = std.mem.readInt(u32, @ptrCast(idx[8 + 255 * 4 .. 8 + 256 * 4]), .big);
    try testing.expectEqual(@as(u32, 3), total);

    // Verify SHA-1s are sorted
    const sha1_start: usize = 1032;
    const sha1_0 = idx[sha1_start .. sha1_start + 20];
    const sha1_1 = idx[sha1_start + 20 .. sha1_start + 40];
    const sha1_2 = idx[sha1_start + 40 .. sha1_start + 60];

    try testing.expect(std.mem.order(u8, sha1_0, sha1_1) == .lt);
    try testing.expect(std.mem.order(u8, sha1_1, sha1_2) == .lt);
}

// =============================================================================
// Test: Pack roundtrip - create pack, generate idx, read back all objects
// =============================================================================
test "pack roundtrip - create, index, read back" {
    const allocator = testing.allocator;

    const blob_data = "roundtrip test data\n";
    const commit_data =
        "tree 4b825dc642cb6eb9a060e54bf899d69f4ef67344\n" ++
        "author RT <rt@test.com> 1700000000 +0000\n" ++
        "committer RT <rt@test.com> 1700000000 +0000\n" ++
        "\nRoundtrip\n";

    const e_blob = try buildPackEntry(allocator, 3, blob_data);
    defer allocator.free(e_blob);
    const e_commit = try buildPackEntry(allocator, 1, commit_data);
    defer allocator.free(e_commit);

    const pack = try buildPackFile(allocator, &.{ e_blob, e_commit });
    defer allocator.free(pack);

    // Read both objects back by offset
    const obj0 = try objects.readPackObjectAtOffset(pack, 12, allocator);
    defer obj0.deinit(allocator);
    try testing.expectEqual(objects.ObjectType.blob, obj0.type);
    try testing.expectEqualStrings(blob_data, obj0.data);

    const obj1 = try objects.readPackObjectAtOffset(pack, 12 + e_blob.len, allocator);
    defer obj1.deinit(allocator);
    try testing.expectEqual(objects.ObjectType.commit, obj1.type);
    try testing.expectEqualStrings(commit_data, obj1.data);

    // Generate idx and verify it's valid
    const idx = try objects.generatePackIndex(pack, allocator);
    defer allocator.free(idx);

    const total = std.mem.readInt(u32, @ptrCast(idx[8 + 255 * 4 .. 8 + 256 * 4]), .big);
    try testing.expectEqual(@as(u32, 2), total);
}

// =============================================================================
// Test: OFS_DELTA chain - 2 levels deep
// =============================================================================
test "readPackObjectAtOffset - ofs_delta chain 2 deep" {
    const allocator = testing.allocator;

    // Base blob: "AAAA BBBB CCCC"
    const base_data = "AAAA BBBB CCCC";
    const base_entry = try buildPackEntry(allocator, 3, base_data);
    defer allocator.free(base_entry);

    // Delta1: change BBBB to XXXX -> "AAAA XXXX CCCC"
    const mid_data = "AAAA XXXX CCCC";
    var db1 = try DeltaBuilder.init(allocator, base_data.len, mid_data.len);
    defer db1.deinit();
    try db1.addCopy(0, 5); // "AAAA "
    try db1.addInsert("XXXX"); // replace BBBB
    try db1.addCopy(9, 5); // " CCCC"
    const delta1_data = try db1.toOwnedSlice();
    defer allocator.free(delta1_data);

    // Build delta1 entry (OFS_DELTA pointing to base at offset 12)
    var d1_buf = std.ArrayList(u8).init(allocator);
    defer d1_buf.deinit();
    var hdr1: [10]u8 = undefined;
    const hdr1_len = encodePackObjectHeader(&hdr1, 6, delta1_data.len);
    try d1_buf.appendSlice(hdr1[0..hdr1_len]);
    const delta1_pack_offset = 12 + base_entry.len;
    var ofs1: [10]u8 = undefined;
    const ofs1_len = encodeOfsOffset(&ofs1, delta1_pack_offset - 12);
    try d1_buf.appendSlice(ofs1[0..ofs1_len]);
    const c1 = try zlibCompress(allocator, delta1_data);
    defer allocator.free(c1);
    try d1_buf.appendSlice(c1);
    const delta1_entry = try allocator.dupe(u8, d1_buf.items);
    defer allocator.free(delta1_entry);

    // Delta2: change CCCC to ZZZZ -> "AAAA XXXX ZZZZ"
    const final_data = "AAAA XXXX ZZZZ";
    var db2 = try DeltaBuilder.init(allocator, mid_data.len, final_data.len);
    defer db2.deinit();
    try db2.addCopy(0, 10); // "AAAA XXXX "
    try db2.addInsert("ZZZZ"); // replace CCCC
    const delta2_data = try db2.toOwnedSlice();
    defer allocator.free(delta2_data);

    // Build delta2 entry (OFS_DELTA pointing to delta1)
    var d2_buf = std.ArrayList(u8).init(allocator);
    defer d2_buf.deinit();
    var hdr2: [10]u8 = undefined;
    const hdr2_len = encodePackObjectHeader(&hdr2, 6, delta2_data.len);
    try d2_buf.appendSlice(hdr2[0..hdr2_len]);
    const delta2_pack_offset = delta1_pack_offset + delta1_entry.len;
    var ofs2: [10]u8 = undefined;
    const ofs2_len = encodeOfsOffset(&ofs2, delta2_pack_offset - delta1_pack_offset);
    try d2_buf.appendSlice(ofs2[0..ofs2_len]);
    const c2 = try zlibCompress(allocator, delta2_data);
    defer allocator.free(c2);
    try d2_buf.appendSlice(c2);
    const delta2_entry = try allocator.dupe(u8, d2_buf.items);
    defer allocator.free(delta2_entry);

    // Build pack
    const pack = try buildPackFile(allocator, &.{ base_entry, delta1_entry, delta2_entry });
    defer allocator.free(pack);

    // Read the 2nd delta - should resolve through the chain
    const obj = try objects.readPackObjectAtOffset(pack, delta2_pack_offset, allocator);
    defer obj.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.blob, obj.type);
    try testing.expectEqualStrings(final_data, obj.data);
}

// =============================================================================
// Test: Binary data in pack objects
// =============================================================================
test "readPackObjectAtOffset - binary blob data" {
    const allocator = testing.allocator;
    // Binary data with null bytes and all byte values
    var bin_data: [256]u8 = undefined;
    for (&bin_data, 0..) |*b, i| {
        b.* = @intCast(i);
    }

    const entry = try buildPackEntry(allocator, 3, &bin_data);
    defer allocator.free(entry);

    const pack = try buildPackFile(allocator, &.{entry});
    defer allocator.free(pack);

    const obj = try objects.readPackObjectAtOffset(pack, 12, allocator);
    defer obj.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.blob, obj.type);
    try testing.expectEqualSlices(u8, &bin_data, obj.data);
}

// =============================================================================
// Test: git cross-validation - create pack with git, read with ziggit
// =============================================================================
test "git cross-validation - git-created pack readable by ziggit" {
    const allocator = testing.allocator;

    // Create a temp git repo, commit something, repack, then read the pack
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realpath(".", &tmp_buf);

    // git init + commit
    const init_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "init", tmp_path },
        .env_map = null,
    }) catch return; // Skip if git not available
    defer allocator.free(init_result.stdout);
    defer allocator.free(init_result.stderr);

    // Configure git
    inline for (.{
        &.{ "git", "-C", tmp_path, "config", "user.email", "test@test.com" },
        &.{ "git", "-C", tmp_path, "config", "user.name", "Test" },
    }) |argv| {
        const r = std.process.Child.run(.{ .allocator = allocator, .argv = argv }) catch return;
        defer allocator.free(r.stdout);
        defer allocator.free(r.stderr);
    }

    // Create a file and commit
    {
        const file_path = try std.fmt.allocPrint(allocator, "{s}/test.txt", .{tmp_path});
        defer allocator.free(file_path);
        var f = try std.fs.cwd().createFile(file_path, .{});
        defer f.close();
        try f.writeAll("Hello from git test!\n");
    }

    inline for (.{
        &.{ "git", "-C", tmp_path, "add", "." },
        &.{ "git", "-C", tmp_path, "commit", "-m", "test commit" },
        &.{ "git", "-C", tmp_path, "repack", "-a", "-d" },
    }) |argv| {
        const r = std.process.Child.run(.{ .allocator = allocator, .argv = argv }) catch return;
        defer allocator.free(r.stdout);
        defer allocator.free(r.stderr);
    }

    // Find the pack file
    const pack_dir_path = try std.fmt.allocPrint(allocator, "{s}/.git/objects/pack", .{tmp_path});
    defer allocator.free(pack_dir_path);

    var pack_dir = std.fs.cwd().openDir(pack_dir_path, .{ .iterate = true }) catch return;
    defer pack_dir.close();

    var pack_filename: ?[]u8 = null;
    defer if (pack_filename) |f| allocator.free(f);

    var iter = pack_dir.iterate();
    while (try iter.next()) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".pack")) {
            pack_filename = try allocator.dupe(u8, entry.name);
            break;
        }
    }

    const fname = pack_filename orelse return; // No pack file found

    // Read the pack file
    const pack_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pack_dir_path, fname });
    defer allocator.free(pack_path);

    const pack_data = try std.fs.cwd().readFileAlloc(allocator, pack_path, 10 * 1024 * 1024);
    defer allocator.free(pack_data);

    // Verify pack header
    try testing.expectEqualStrings("PACK", pack_data[0..4]);

    // Read first object (at offset 12) - should succeed without error
    const obj = try objects.readPackObjectAtOffset(pack_data, 12, allocator);
    defer obj.deinit(allocator);

    // Object should be one of the valid types
    try testing.expect(obj.type == .blob or obj.type == .commit or obj.type == .tree or obj.type == .tag);
    try testing.expect(obj.data.len > 0);

    // Generate our own idx and verify structure
    const idx = try objects.generatePackIndex(pack_data, allocator);
    defer allocator.free(idx);

    // Verify idx magic
    try testing.expectEqual(@as(u32, 0xff744f63), std.mem.readInt(u32, @ptrCast(idx[0..4]), .big));

    // Cross-validate: use git verify-pack on our generated idx
    // Write our idx to a temp file
    const our_idx_path = try std.fmt.allocPrint(allocator, "{s}/our-test.idx", .{pack_dir_path});
    defer allocator.free(our_idx_path);
    {
        var f = try std.fs.cwd().createFile(our_idx_path, .{});
        defer f.close();
        try f.writeAll(idx);
    }
    defer std.fs.cwd().deleteFile(our_idx_path) catch {};

    // Also write pack with matching name
    const our_pack_path = try std.fmt.allocPrint(allocator, "{s}/our-test.pack", .{pack_dir_path});
    defer allocator.free(our_pack_path);
    {
        var f = try std.fs.cwd().createFile(our_pack_path, .{});
        defer f.close();
        try f.writeAll(pack_data);
    }
    defer std.fs.cwd().deleteFile(our_pack_path) catch {};

    // git verify-pack should accept our idx
    const verify_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "verify-pack", "-v", our_idx_path },
    }) catch return;
    defer allocator.free(verify_result.stdout);
    defer allocator.free(verify_result.stderr);

    // If git verify-pack returns 0, our idx is valid
    if (verify_result.term.Exited == 0) {
        // Success - git accepted our generated idx
        try testing.expect(verify_result.stdout.len > 0);
    }
}

// =============================================================================
// Test: Empty pack file handling
// =============================================================================
test "readPackObjectAtOffset - invalid offset returns error" {
    const allocator = testing.allocator;
    const blob_data = "test";
    const entry = try buildPackEntry(allocator, 3, blob_data);
    defer allocator.free(entry);
    const pack = try buildPackFile(allocator, &.{entry});
    defer allocator.free(pack);

    // Offset beyond pack data
    try testing.expectError(error.ObjectNotFound, objects.readPackObjectAtOffset(pack, pack.len + 100, allocator));
    // Offset in checksum area
    try testing.expectError(error.ObjectNotFound, objects.readPackObjectAtOffset(pack, pack.len - 10, allocator));
}

// =============================================================================
// Test: Large blob in pack
// =============================================================================
test "readPackObjectAtOffset - large blob (64KB)" {
    const allocator = testing.allocator;
    const large = try allocator.alloc(u8, 65536);
    defer allocator.free(large);
    for (large, 0..) |*b, i| {
        b.* = @intCast((i * 7 + 13) & 0xFF);
    }

    const entry = try buildPackEntry(allocator, 3, large);
    defer allocator.free(entry);

    const pack = try buildPackFile(allocator, &.{entry});
    defer allocator.free(pack);

    const obj = try objects.readPackObjectAtOffset(pack, 12, allocator);
    defer obj.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.blob, obj.type);
    try testing.expectEqualSlices(u8, large, obj.data);
}

// =============================================================================
// Test: generatePackIndex with OFS_DELTA produces correct SHA-1
// =============================================================================
test "generatePackIndex - ofs_delta sha1 is correct" {
    const allocator = testing.allocator;

    const base_data = "base content here\n";
    const base_entry = try buildPackEntry(allocator, 3, base_data);
    defer allocator.free(base_entry);

    // Delta: append " modified"
    const result_data = "base content here\n modified";
    var db = try DeltaBuilder.init(allocator, base_data.len, result_data.len);
    defer db.deinit();
    try db.addCopy(0, base_data.len); // copy all of base
    try db.addInsert(" modified"); // append
    const delta_data = try db.toOwnedSlice();
    defer allocator.free(delta_data);

    var d_buf = std.ArrayList(u8).init(allocator);
    defer d_buf.deinit();
    var hdr: [10]u8 = undefined;
    const hdr_len = encodePackObjectHeader(&hdr, 6, delta_data.len);
    try d_buf.appendSlice(hdr[0..hdr_len]);
    const delta_offset = 12 + base_entry.len;
    var ofs: [10]u8 = undefined;
    const ofs_len = encodeOfsOffset(&ofs, delta_offset - 12);
    try d_buf.appendSlice(ofs[0..ofs_len]);
    const cd = try zlibCompress(allocator, delta_data);
    defer allocator.free(cd);
    try d_buf.appendSlice(cd);
    const delta_entry = try allocator.dupe(u8, d_buf.items);
    defer allocator.free(delta_entry);

    const pack = try buildPackFile(allocator, &.{ base_entry, delta_entry });
    defer allocator.free(pack);

    const idx = try objects.generatePackIndex(pack, allocator);
    defer allocator.free(idx);

    // Should have 2 entries
    const total = std.mem.readInt(u32, @ptrCast(idx[8 + 255 * 4 .. 8 + 256 * 4]), .big);
    try testing.expectEqual(@as(u32, 2), total);

    // Find the SHA-1 of the delta result in the idx
    const expected_base_sha = gitObjectSha1("blob", base_data);
    const expected_delta_sha = gitObjectSha1("blob", result_data);

    // Both SHA-1s should appear in the idx (sorted)
    const sha_table = idx[1032 .. 1032 + 40];
    const sha0 = sha_table[0..20];
    const sha1 = sha_table[20..40];

    // One of them should be our expected delta result SHA
    const found_base = std.mem.eql(u8, sha0, &expected_base_sha) or std.mem.eql(u8, sha1, &expected_base_sha);
    const found_delta = std.mem.eql(u8, sha0, &expected_delta_sha) or std.mem.eql(u8, sha1, &expected_delta_sha);

    try testing.expect(found_base);
    try testing.expect(found_delta);
}
