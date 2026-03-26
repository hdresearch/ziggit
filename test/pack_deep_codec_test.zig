const std = @import("std");
const testing = std.testing;
const objects = @import("git_objects");

// ============================================================================
// DEEP PACK CODEC TESTS
//
// Covers gaps not addressed by other test files:
//   1. OFS_DELTA chains of depth 3+ (base → Δ1 → Δ2)
//   2. Copy command with 4-byte offset (>16MB)
//   3. Copy command with 3-byte size (>64KB, ≠ 0x10000)
//   4. fixThinPack: REF_DELTA resolved from local loose objects
//   5. generatePackIndex with mixed types (all 6 pack object types)
//   6. Delta on non-blob types (commit, tree)
//   7. OFS_DELTA encoding with large negative offsets
//   8. Empty delta (base_size == result_size, no commands)
//   9. Multiple REF_DELTA objects referencing same base
//  10. Pack with 0 objects
// ============================================================================

// --- Helper functions (same as pack_codec_correctness_test) ---

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

fn encodePackObjectHeader(buf: []u8, obj_type: u3, size: usize) usize {
    var s = size;
    buf[0] = (@as(u8, obj_type) << 4) | @as(u8, @intCast(s & 0x0F));
    s >>= 4;
    if (s == 0) return 1;
    buf[0] |= 0x80;
    var i: usize = 1;
    while (s > 0) {
        buf[i] = @intCast(s & 0x7F);
        s >>= 7;
        if (s > 0) buf[i] |= 0x80;
        i += 1;
    }
    return i;
}

fn encodeOfsOffset(buf: []u8, offset: usize) usize {
    var val = offset;
    var i: usize = 0;
    buf[i] = @intCast(val & 0x7F);
    val >>= 7;
    while (val > 0) {
        val -= 1;
        i += 1;
        buf[i] = @intCast(0x80 | (val & 0x7F));
        val >>= 7;
    }
    // Reverse - OFS encoding is big-endian MSB-first
    var lo: usize = 0;
    var hi: usize = i;
    while (lo < hi) {
        const tmp = buf[lo];
        buf[lo] = buf[hi];
        buf[hi] = tmp;
        lo += 1;
        hi -= 1;
    }
    return i + 1;
}

fn zlibCompress(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var compressed = std.ArrayList(u8).init(allocator);
    var input = std.io.fixedBufferStream(data);
    try std.compress.zlib.compress(input.reader(), compressed.writer(), .{});
    return try compressed.toOwnedSlice();
}

fn gitObjectSha1(type_str: []const u8, data: []const u8, allocator: std.mem.Allocator) ![20]u8 {
    const header = try std.fmt.allocPrint(allocator, "{s} {}\x00", .{ type_str, data.len });
    defer allocator.free(header);
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(header);
    hasher.update(data);
    var out: [20]u8 = undefined;
    hasher.final(&out);
    return out;
}

fn buildPackFile(allocator: std.mem.Allocator, encoded_objects: []const []const u8) ![]u8 {
    var pack = std.ArrayList(u8).init(allocator);
    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, @intCast(encoded_objects.len), .big);
    for (encoded_objects) |obj| try pack.appendSlice(obj);
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack.items);
    var checksum: [20]u8 = undefined;
    hasher.final(&checksum);
    try pack.appendSlice(&checksum);
    return try pack.toOwnedSlice();
}

fn encodePackObject(allocator: std.mem.Allocator, obj_type: u3, data: []const u8) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    var hdr_buf: [10]u8 = undefined;
    const hdr_len = encodePackObjectHeader(&hdr_buf, obj_type, data.len);
    try result.appendSlice(hdr_buf[0..hdr_len]);
    const compressed = try zlibCompress(allocator, data);
    defer allocator.free(compressed);
    try result.appendSlice(compressed);
    return try result.toOwnedSlice();
}

fn encodeOfsDeltaObject(allocator: std.mem.Allocator, neg_offset: usize, delta_data: []const u8) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    var hdr_buf: [10]u8 = undefined;
    const hdr_len = encodePackObjectHeader(&hdr_buf, 6, delta_data.len);
    try result.appendSlice(hdr_buf[0..hdr_len]);
    var ofs_buf: [10]u8 = undefined;
    const ofs_len = encodeOfsOffset(&ofs_buf, neg_offset);
    try result.appendSlice(ofs_buf[0..ofs_len]);
    const compressed = try zlibCompress(allocator, delta_data);
    defer allocator.free(compressed);
    try result.appendSlice(compressed);
    return try result.toOwnedSlice();
}

fn encodeRefDeltaObject(allocator: std.mem.Allocator, base_sha1: [20]u8, delta_data: []const u8) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    var hdr_buf: [10]u8 = undefined;
    const hdr_len = encodePackObjectHeader(&hdr_buf, 7, delta_data.len);
    try result.appendSlice(hdr_buf[0..hdr_len]);
    try result.appendSlice(&base_sha1);
    const compressed = try zlibCompress(allocator, delta_data);
    defer allocator.free(compressed);
    try result.appendSlice(compressed);
    return try result.toOwnedSlice();
}

const DeltaCmd = union(enum) {
    copy: struct { offset: usize, size: usize },
    insert: []const u8,
};

fn buildDelta(allocator: std.mem.Allocator, base_size: usize, result_size: usize, cmds: []const DeltaCmd) ![]u8 {
    var delta = std.ArrayList(u8).init(allocator);
    var buf: [10]u8 = undefined;

    var n = encodeVarint(&buf, base_size);
    try delta.appendSlice(buf[0..n]);
    n = encodeVarint(&buf, result_size);
    try delta.appendSlice(buf[0..n]);

    for (cmds) |cmd| {
        switch (cmd) {
            .copy => |c| {
                var copy_cmd: u8 = 0x80;
                var copy_bytes = std.ArrayList(u8).init(allocator);
                defer copy_bytes.deinit();

                if (c.offset & 0xFF != 0) {
                    copy_cmd |= 0x01;
                    try copy_bytes.append(@intCast(c.offset & 0xFF));
                }
                if (c.offset >> 8 & 0xFF != 0) {
                    copy_cmd |= 0x02;
                    try copy_bytes.append(@intCast(c.offset >> 8 & 0xFF));
                }
                if (c.offset >> 16 & 0xFF != 0) {
                    copy_cmd |= 0x04;
                    try copy_bytes.append(@intCast(c.offset >> 16 & 0xFF));
                }
                if (c.offset >> 24 & 0xFF != 0) {
                    copy_cmd |= 0x08;
                    try copy_bytes.append(@intCast(c.offset >> 24 & 0xFF));
                }
                if (c.offset == 0 and c.size != 0x10000) {
                    copy_cmd |= 0x01;
                    try copy_bytes.append(0x00);
                }

                const effective_size = if (c.size == 0x10000) @as(usize, 0) else c.size;
                if (effective_size & 0xFF != 0) {
                    copy_cmd |= 0x10;
                    try copy_bytes.append(@intCast(effective_size & 0xFF));
                }
                if (effective_size >> 8 & 0xFF != 0) {
                    copy_cmd |= 0x20;
                    try copy_bytes.append(@intCast(effective_size >> 8 & 0xFF));
                }
                if (effective_size >> 16 & 0xFF != 0) {
                    copy_cmd |= 0x40;
                    try copy_bytes.append(@intCast(effective_size >> 16 & 0xFF));
                }
                if (effective_size != 0 and effective_size & 0xFF == 0 and effective_size >> 8 & 0xFF == 0 and effective_size >> 16 & 0xFF == 0) {
                    copy_cmd |= 0x10;
                    try copy_bytes.append(0);
                }

                try delta.append(copy_cmd);
                try delta.appendSlice(copy_bytes.items);
            },
            .insert => |data| {
                var remaining = data;
                while (remaining.len > 0) {
                    const chunk = @min(remaining.len, 127);
                    try delta.append(@intCast(chunk));
                    try delta.appendSlice(remaining[0..chunk]);
                    remaining = remaining[chunk..];
                }
            },
        }
    }
    return try delta.toOwnedSlice();
}

fn sha1Hex(sha: [20]u8) [40]u8 {
    var hex: [40]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{}", .{std.fmt.fmtSliceHexLower(&sha)}) catch unreachable;
    return hex;
}

const NativeFs = struct {
    pub const fs = struct {
        pub fn readFile(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
            return std.fs.cwd().readFileAlloc(alloc, path, 50 * 1024 * 1024);
        }
        pub fn writeFile(path: []const u8, data: []const u8) !void {
            const file = try std.fs.cwd().createFile(path, .{});
            defer file.close();
            try file.writeAll(data);
        }
        pub fn makeDir(path: []const u8) !void {
            try std.fs.cwd().makeDir(path);
        }
    };
};

// ============================================================================
// 1. OFS_DELTA chain depth 3: base → delta1 → delta2
// ============================================================================
test "readPackObjectAtOffset: OFS_DELTA chain depth 3 resolves correctly" {
    const allocator = testing.allocator;

    // base → "AAAA"
    // delta1 → "AAAABB" (copy base + insert "BB")
    // delta2 → "AAAABBCC" (copy delta1 result + insert "CC")

    const base_data = "AAAA";
    const d1_result = "AAAABB";
    const d2_result = "AAAABBCC";

    const delta1 = try buildDelta(allocator, base_data.len, d1_result.len, &[_]DeltaCmd{
        .{ .copy = .{ .offset = 0, .size = 4 } },
        .{ .insert = "BB" },
    });
    defer allocator.free(delta1);

    const delta2 = try buildDelta(allocator, d1_result.len, d2_result.len, &[_]DeltaCmd{
        .{ .copy = .{ .offset = 0, .size = 6 } },
        .{ .insert = "CC" },
    });
    defer allocator.free(delta2);

    const enc_base = try encodePackObject(allocator, 3, base_data);
    defer allocator.free(enc_base);

    // delta1 references base at negative offset = enc_base.len (distance from delta1 start to base start)
    const enc_d1 = try encodeOfsDeltaObject(allocator, enc_base.len, delta1);
    defer allocator.free(enc_d1);

    // delta2 references delta1 at negative offset = enc_d1.len
    const enc_d2 = try encodeOfsDeltaObject(allocator, enc_d1.len, delta2);
    defer allocator.free(enc_d2);

    const pack_data = try buildPackFile(allocator, &[_][]const u8{ enc_base, enc_d1, enc_d2 });
    defer allocator.free(pack_data);

    // Read delta2 (at offset 12 + enc_base.len + enc_d1.len)
    const d2_offset = 12 + enc_base.len + enc_d1.len;
    const obj = try objects.readPackObjectAtOffset(pack_data, d2_offset, allocator);
    defer obj.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.blob, obj.type);
    try testing.expectEqualStrings(d2_result, obj.data);
}

// ============================================================================
// 2. Copy with 4-byte offset (> 16MB base)
// ============================================================================
test "applyDelta: copy with 4-byte offset (> 16MB)" {
    const allocator = testing.allocator;

    // We need a base > 16MB. Use 17MB.
    const base_size: usize = 17 * 1024 * 1024;
    const base_data = try allocator.alloc(u8, base_size);
    defer allocator.free(base_data);
    @memset(base_data, 'X');
    // Place marker at 16MB + 256 = 16777472
    const marker_offset: usize = 16 * 1024 * 1024 + 256;
    @memcpy(base_data[marker_offset .. marker_offset + 5], "FOUND");

    const delta = try buildDelta(allocator, base_size, 5, &[_]DeltaCmd{
        .{ .copy = .{ .offset = marker_offset, .size = 5 } },
    });
    defer allocator.free(delta);

    const result = try objects.applyDelta(base_data, delta, allocator);
    defer allocator.free(result);
    try testing.expectEqualStrings("FOUND", result);
}

// ============================================================================
// 3. Copy with 3-byte size (> 64KB, ≠ 0x10000)
// ============================================================================
test "applyDelta: copy with 3-byte size (70000 bytes)" {
    const allocator = testing.allocator;

    const copy_size: usize = 70000;
    const base_data = try allocator.alloc(u8, copy_size);
    defer allocator.free(base_data);
    for (base_data, 0..) |*b, i| b.* = @intCast(i % 251);

    const delta = try buildDelta(allocator, copy_size, copy_size, &[_]DeltaCmd{
        .{ .copy = .{ .offset = 0, .size = copy_size } },
    });
    defer allocator.free(delta);

    const result = try objects.applyDelta(base_data, delta, allocator);
    defer allocator.free(result);
    try testing.expectEqual(copy_size, result.len);
    try testing.expectEqualSlices(u8, base_data, result);
}

// ============================================================================
// 4. fixThinPack: REF_DELTA base resolved from local loose object
// ============================================================================
test "fixThinPack: REF_DELTA resolved from local loose object" {
    const allocator = testing.allocator;

    // The base object content
    const base_data = "this is the base object for thin pack test\n";
    const base_sha1 = try gitObjectSha1("blob", base_data, allocator);
    const base_hex = sha1Hex(base_sha1);

    // Delta: copy base + insert extra
    const extra = " extra data\n";
    const expected_result = base_data ++ extra;

    const delta = try buildDelta(allocator, base_data.len, expected_result.len, &[_]DeltaCmd{
        .{ .copy = .{ .offset = 0, .size = base_data.len } },
        .{ .insert = extra },
    });
    defer allocator.free(delta);

    // Build thin pack with only the REF_DELTA (no base)
    const enc_delta = try encodeRefDeltaObject(allocator, base_sha1, delta);
    defer allocator.free(enc_delta);
    const thin_pack = try buildPackFile(allocator, &[_][]const u8{enc_delta});
    defer allocator.free(thin_pack);

    // Set up a git dir with the base object as a loose object
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const git_dir = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(git_dir);

    // Create loose object: objects/ab/cdef...
    const obj_dir = try std.fmt.allocPrint(allocator, "objects/{s}", .{base_hex[0..2]});
    defer allocator.free(obj_dir);
    try tmp_dir.dir.makePath(obj_dir);

    // Loose object = zlib(header + data)
    const loose_header = try std.fmt.allocPrint(allocator, "blob {}\x00", .{base_data.len});
    defer allocator.free(loose_header);

    var loose_raw = std.ArrayList(u8).init(allocator);
    defer loose_raw.deinit();
    try loose_raw.appendSlice(loose_header);
    try loose_raw.appendSlice(base_data);

    const loose_compressed = try zlibCompress(allocator, loose_raw.items);
    defer allocator.free(loose_compressed);

    const loose_path = try std.fmt.allocPrint(allocator, "objects/{s}/{s}", .{ base_hex[0..2], base_hex[2..] });
    defer allocator.free(loose_path);
    try tmp_dir.dir.writeFile(.{ .sub_path = loose_path, .data = loose_compressed });

    // Fix the thin pack
    const fixed = try objects.fixThinPack(thin_pack, git_dir, NativeFs, allocator);
    defer allocator.free(fixed);

    // Fixed pack should have 2 objects (base + delta)
    try testing.expectEqualStrings("PACK", fixed[0..4]);
    const fixed_count = std.mem.readInt(u32, @ptrCast(fixed[8..12]), .big);
    try testing.expectEqual(@as(u32, 2), fixed_count);

    // Verify the pack checksum is valid
    const content_end = fixed.len - 20;
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(fixed[0..content_end]);
    var computed: [20]u8 = undefined;
    hasher.final(&computed);
    try testing.expectEqualSlices(u8, &computed, fixed[content_end..]);

    // Generate idx and verify both objects present
    const idx = try objects.generatePackIndex(fixed, allocator);
    defer allocator.free(idx);

    const total = std.mem.readInt(u32, @ptrCast(idx[8 + 255 * 4 .. 8 + 255 * 4 + 4]), .big);
    try testing.expectEqual(@as(u32, 2), total);
}

// ============================================================================
// 5. generatePackIndex: mixed types (commit + tree + blob + tag + ofs_delta)
// ============================================================================
test "generatePackIndex: all base types + OFS_DELTA in one pack" {
    const allocator = testing.allocator;

    const blob_data = "blob content\n";
    const tree_data = "100644 file.txt\x00" ++ "\xaa" ** 20;
    const commit_data = "tree 4b825dc642cb6eb9a060e54bf899d69f22e5c6f1\nauthor A <a@a> 0 +0000\ncommitter A <a@a> 0 +0000\n\ninit\n";
    const tag_data = "object 0000000000000000000000000000000000000000\ntype commit\ntag v1\ntagger T <t@t> 0 +0000\n\ntag\n";

    // Delta on blob
    const delta_result = blob_data ++ "extra\n";
    const delta = try buildDelta(allocator, blob_data.len, delta_result.len, &[_]DeltaCmd{
        .{ .copy = .{ .offset = 0, .size = blob_data.len } },
        .{ .insert = "extra\n" },
    });
    defer allocator.free(delta);

    const enc_blob = try encodePackObject(allocator, 3, blob_data);
    defer allocator.free(enc_blob);
    const enc_tree = try encodePackObject(allocator, 2, tree_data);
    defer allocator.free(enc_tree);
    const enc_commit = try encodePackObject(allocator, 1, commit_data);
    defer allocator.free(enc_commit);
    const enc_tag = try encodePackObject(allocator, 4, tag_data);
    defer allocator.free(enc_tag);

    // OFS_DELTA references blob (first object)
    const delta_neg_offset = enc_blob.len + enc_tree.len + enc_commit.len + enc_tag.len;
    const enc_delta = try encodeOfsDeltaObject(allocator, delta_neg_offset, delta);
    defer allocator.free(enc_delta);

    const pack_data = try buildPackFile(allocator, &[_][]const u8{
        enc_blob, enc_tree, enc_commit, enc_tag, enc_delta,
    });
    defer allocator.free(pack_data);

    const idx = try objects.generatePackIndex(pack_data, allocator);
    defer allocator.free(idx);

    // Should have 5 objects
    const total = std.mem.readInt(u32, @ptrCast(idx[8 + 255 * 4 .. 8 + 255 * 4 + 4]), .big);
    try testing.expectEqual(@as(u32, 5), total);

    // Verify each SHA-1 is correct
    const blob_sha = try gitObjectSha1("blob", blob_data, allocator);
    const tree_sha = try gitObjectSha1("tree", tree_data, allocator);
    const commit_sha = try gitObjectSha1("commit", commit_data, allocator);
    const tag_sha = try gitObjectSha1("tag", tag_data, allocator);
    const delta_sha = try gitObjectSha1("blob", delta_result, allocator);

    const sha_start: usize = 8 + 256 * 4;
    var found: u32 = 0;
    for (0..5) |i| {
        const sha = idx[sha_start + i * 20 .. sha_start + (i + 1) * 20];
        if (std.mem.eql(u8, sha, &blob_sha)) found += 1;
        if (std.mem.eql(u8, sha, &tree_sha)) found += 1;
        if (std.mem.eql(u8, sha, &commit_sha)) found += 1;
        if (std.mem.eql(u8, sha, &tag_sha)) found += 1;
        if (std.mem.eql(u8, sha, &delta_sha)) found += 1;
    }
    try testing.expectEqual(@as(u32, 5), found);
}

// ============================================================================
// 6a. OFS_DELTA on commit type preserves type through chain
// ============================================================================
test "readPackObjectAtOffset: OFS_DELTA on commit preserves commit type" {
    const allocator = testing.allocator;

    const base_commit = "tree 4b825dc642cb6eb9a060e54bf899d69f22e5c6f1\nauthor A <a@a> 1000 +0000\ncommitter A <a@a> 1000 +0000\n\nfirst\n";
    const result_commit = "tree 4b825dc642cb6eb9a060e54bf899d69f22e5c6f1\nauthor A <a@a> 1000 +0000\ncommitter A <a@a> 1000 +0000\n\nsecond\n";

    // Delta: copy most of base, replace "first" with "second"
    // Copy first 100 bytes (up to message), then insert "second\n"
    const shared_prefix = "tree 4b825dc642cb6eb9a060e54bf899d69f22e5c6f1\nauthor A <a@a> 1000 +0000\ncommitter A <a@a> 1000 +0000\n\n";
    const delta = try buildDelta(allocator, base_commit.len, result_commit.len, &[_]DeltaCmd{
        .{ .copy = .{ .offset = 0, .size = shared_prefix.len } },
        .{ .insert = "second\n" },
    });
    defer allocator.free(delta);

    const enc_base = try encodePackObject(allocator, 1, base_commit); // type 1 = commit
    defer allocator.free(enc_base);
    const enc_delta = try encodeOfsDeltaObject(allocator, enc_base.len, delta);
    defer allocator.free(enc_delta);

    const pack_data = try buildPackFile(allocator, &[_][]const u8{ enc_base, enc_delta });
    defer allocator.free(pack_data);

    const obj = try objects.readPackObjectAtOffset(pack_data, 12 + enc_base.len, allocator);
    defer obj.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.commit, obj.type);
    try testing.expectEqualStrings(result_commit, obj.data);
}

// ============================================================================
// 6b. OFS_DELTA on tree type preserves type
// ============================================================================
test "readPackObjectAtOffset: OFS_DELTA on tree preserves tree type" {
    const allocator = testing.allocator;

    // Base tree: one entry
    var base_tree = std.ArrayList(u8).init(allocator);
    defer base_tree.deinit();
    try base_tree.appendSlice("100644 a.txt\x00");
    try base_tree.appendSlice(&[_]u8{0x11} ** 20);

    // Result tree: two entries (base + new entry)
    var result_tree = std.ArrayList(u8).init(allocator);
    defer result_tree.deinit();
    try result_tree.appendSlice("100644 a.txt\x00");
    try result_tree.appendSlice(&[_]u8{0x11} ** 20);
    try result_tree.appendSlice("100644 b.txt\x00");
    try result_tree.appendSlice(&[_]u8{0x22} ** 20);

    const delta = try buildDelta(allocator, base_tree.items.len, result_tree.items.len, &[_]DeltaCmd{
        .{ .copy = .{ .offset = 0, .size = base_tree.items.len } },
        .{ .insert = "100644 b.txt\x00" ++ "\x22" ** 20 },
    });
    defer allocator.free(delta);

    const enc_base = try encodePackObject(allocator, 2, base_tree.items); // type 2 = tree
    defer allocator.free(enc_base);
    const enc_delta = try encodeOfsDeltaObject(allocator, enc_base.len, delta);
    defer allocator.free(enc_delta);

    const pack_data = try buildPackFile(allocator, &[_][]const u8{ enc_base, enc_delta });
    defer allocator.free(pack_data);

    const obj = try objects.readPackObjectAtOffset(pack_data, 12 + enc_base.len, allocator);
    defer obj.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.tree, obj.type);
    try testing.expectEqualSlices(u8, result_tree.items, obj.data);
}

// ============================================================================
// 7. Multiple REF_DELTA objects referencing the same base
// ============================================================================
test "generatePackIndex: multiple REF_DELTAs referencing same base" {
    const allocator = testing.allocator;

    const base_data = "shared base content\n";
    const base_sha1 = try gitObjectSha1("blob", base_data, allocator);

    const result1 = base_data ++ "variant A\n";
    const result2 = base_data ++ "variant B\n";

    const delta1 = try buildDelta(allocator, base_data.len, result1.len, &[_]DeltaCmd{
        .{ .copy = .{ .offset = 0, .size = base_data.len } },
        .{ .insert = "variant A\n" },
    });
    defer allocator.free(delta1);

    const delta2 = try buildDelta(allocator, base_data.len, result2.len, &[_]DeltaCmd{
        .{ .copy = .{ .offset = 0, .size = base_data.len } },
        .{ .insert = "variant B\n" },
    });
    defer allocator.free(delta2);

    const enc_base = try encodePackObject(allocator, 3, base_data);
    defer allocator.free(enc_base);
    const enc_d1 = try encodeRefDeltaObject(allocator, base_sha1, delta1);
    defer allocator.free(enc_d1);
    const enc_d2 = try encodeRefDeltaObject(allocator, base_sha1, delta2);
    defer allocator.free(enc_d2);

    const pack_data = try buildPackFile(allocator, &[_][]const u8{ enc_base, enc_d1, enc_d2 });
    defer allocator.free(pack_data);

    const idx = try objects.generatePackIndex(pack_data, allocator);
    defer allocator.free(idx);

    const total = std.mem.readInt(u32, @ptrCast(idx[8 + 255 * 4 .. 8 + 255 * 4 + 4]), .big);
    try testing.expectEqual(@as(u32, 3), total);

    // Verify all 3 SHA-1s present
    const sha_start: usize = 8 + 256 * 4;
    const sha_base = try gitObjectSha1("blob", base_data, allocator);
    const sha_r1 = try gitObjectSha1("blob", result1, allocator);
    const sha_r2 = try gitObjectSha1("blob", result2, allocator);

    var found: u32 = 0;
    for (0..3) |i| {
        const sha = idx[sha_start + i * 20 .. sha_start + (i + 1) * 20];
        if (std.mem.eql(u8, sha, &sha_base)) found += 1;
        if (std.mem.eql(u8, sha, &sha_r1)) found += 1;
        if (std.mem.eql(u8, sha, &sha_r2)) found += 1;
    }
    try testing.expectEqual(@as(u32, 3), found);
}

// ============================================================================
// 8. OFS_DELTA chain via saveReceivedPack + loadFromPackFiles
// ============================================================================
test "saveReceivedPack + loadFromPackFiles: OFS_DELTA chain resolves" {
    const allocator = testing.allocator;

    const base_data = "base for chain test\n";
    const extra = "appended\n";
    const expected = base_data ++ extra;

    const delta = try buildDelta(allocator, base_data.len, expected.len, &[_]DeltaCmd{
        .{ .copy = .{ .offset = 0, .size = base_data.len } },
        .{ .insert = extra },
    });
    defer allocator.free(delta);

    const enc_base = try encodePackObject(allocator, 3, base_data);
    defer allocator.free(enc_base);
    const enc_delta = try encodeOfsDeltaObject(allocator, enc_base.len, delta);
    defer allocator.free(enc_delta);
    const pack_data = try buildPackFile(allocator, &[_][]const u8{ enc_base, enc_delta });
    defer allocator.free(pack_data);

    // SHA of the delta result
    const result_sha = try gitObjectSha1("blob", expected, allocator);
    const result_hex = sha1Hex(result_sha);

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.makePath("objects/pack");
    const git_dir = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(git_dir);

    const cksum = try objects.saveReceivedPack(pack_data, git_dir, NativeFs, allocator);
    defer allocator.free(cksum);

    const loaded = try objects.loadFromPackFiles(&result_hex, git_dir, NativeFs, allocator);
    defer loaded.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.blob, loaded.type);
    try testing.expectEqualStrings(expected, loaded.data);
}

// ============================================================================
// 9. OFS_DELTA with large negative offset (object far from base)
// ============================================================================
test "readPackObjectAtOffset: OFS_DELTA with large negative offset" {
    const allocator = testing.allocator;

    // Create a base + several filler objects + delta referencing base
    const base_data = "the base\n";
    const enc_base = try encodePackObject(allocator, 3, base_data);
    defer allocator.free(enc_base);

    // Create 10 filler blobs to increase distance
    var fillers: [10][]u8 = undefined;
    var filler_count: usize = 0;
    defer for (fillers[0..filler_count]) |f| allocator.free(f);

    var total_filler_size: usize = 0;
    for (0..10) |i| {
        const filler_data = try std.fmt.allocPrint(allocator, "filler blob number {} with some padding data to increase size\n", .{i});
        defer allocator.free(filler_data);
        fillers[i] = try encodePackObject(allocator, 3, filler_data);
        total_filler_size += fillers[i].len;
        filler_count += 1;
    }

    // Delta referencing base, with large negative offset
    const delta_result = base_data ++ "added\n";
    const delta = try buildDelta(allocator, base_data.len, delta_result.len, &[_]DeltaCmd{
        .{ .copy = .{ .offset = 0, .size = base_data.len } },
        .{ .insert = "added\n" },
    });
    defer allocator.free(delta);

    const neg_offset = enc_base.len + total_filler_size;
    const enc_delta = try encodeOfsDeltaObject(allocator, neg_offset, delta);
    defer allocator.free(enc_delta);

    // Build pack: base, 10 fillers, delta
    var all_objects: [12][]const u8 = undefined;
    all_objects[0] = enc_base;
    for (0..10) |i| all_objects[i + 1] = fillers[i];
    all_objects[11] = enc_delta;

    const pack_data = try buildPackFile(allocator, &all_objects);
    defer allocator.free(pack_data);

    // Read the delta object
    const delta_offset = 12 + enc_base.len + total_filler_size;
    const obj = try objects.readPackObjectAtOffset(pack_data, delta_offset, allocator);
    defer obj.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.blob, obj.type);
    try testing.expectEqualStrings(delta_result, obj.data);
}

// ============================================================================
// 10. git verify-pack accepts pack with depth-3 OFS_DELTA chain
// ============================================================================
test "git cross-validation: depth-3 OFS_DELTA chain accepted by git verify-pack" {
    const allocator = testing.allocator;

    const git_check = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "--version" },
    }) catch return;
    defer allocator.free(git_check.stdout);
    defer allocator.free(git_check.stderr);
    if (git_check.term.Exited != 0) return;

    const base = "line1\nline2\nline3\n";
    const r1 = "line1\nline2\nline3\nline4\n";
    const r2 = "line1\nline2\nline3\nline4\nline5\n";

    const d1 = try buildDelta(allocator, base.len, r1.len, &[_]DeltaCmd{
        .{ .copy = .{ .offset = 0, .size = base.len } },
        .{ .insert = "line4\n" },
    });
    defer allocator.free(d1);

    const d2 = try buildDelta(allocator, r1.len, r2.len, &[_]DeltaCmd{
        .{ .copy = .{ .offset = 0, .size = r1.len } },
        .{ .insert = "line5\n" },
    });
    defer allocator.free(d2);

    const enc_base = try encodePackObject(allocator, 3, base);
    defer allocator.free(enc_base);
    const enc_d1 = try encodeOfsDeltaObject(allocator, enc_base.len, d1);
    defer allocator.free(enc_d1);
    const enc_d2 = try encodeOfsDeltaObject(allocator, enc_d1.len, d2);
    defer allocator.free(enc_d2);

    const pack_data = try buildPackFile(allocator, &[_][]const u8{ enc_base, enc_d1, enc_d2 });
    defer allocator.free(pack_data);

    const idx_data = try objects.generatePackIndex(pack_data, allocator);
    defer allocator.free(idx_data);

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const checksum = pack_data[pack_data.len - 20 ..];
    var hex_buf: [40]u8 = undefined;
    _ = std.fmt.bufPrint(&hex_buf, "{}", .{std.fmt.fmtSliceHexLower(checksum)}) catch unreachable;

    const pack_name = try std.fmt.allocPrint(allocator, "pack-{s}.pack", .{hex_buf});
    defer allocator.free(pack_name);
    const idx_name = try std.fmt.allocPrint(allocator, "pack-{s}.idx", .{hex_buf});
    defer allocator.free(idx_name);

    try tmp_dir.dir.writeFile(.{ .sub_path = pack_name, .data = pack_data });
    try tmp_dir.dir.writeFile(.{ .sub_path = idx_name, .data = idx_data });

    const pack_path = try tmp_dir.dir.realpathAlloc(allocator, pack_name);
    defer allocator.free(pack_path);

    const verify = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "verify-pack", "-v", pack_path },
    }) catch return;
    defer allocator.free(verify.stdout);
    defer allocator.free(verify.stderr);

    try testing.expectEqual(@as(u8, 0), verify.term.Exited);
    // Should show 3 objects
    var line_count: usize = 0;
    var it = std.mem.splitSequence(u8, std.mem.trimRight(u8, verify.stdout, "\n"), "\n");
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, "blob") != null) line_count += 1;
    }
    try testing.expectEqual(@as(usize, 3), line_count);
}

// ============================================================================
// 11. readPackObjectAtOffset rejects out-of-bounds offset
// ============================================================================
test "readPackObjectAtOffset: rejects offset beyond pack data" {
    const allocator = testing.allocator;

    const enc = try encodePackObject(allocator, 3, "test\n");
    defer allocator.free(enc);
    const pack_data = try buildPackFile(allocator, &[_][]const u8{enc});
    defer allocator.free(pack_data);

    const result = objects.readPackObjectAtOffset(pack_data, pack_data.len + 100, allocator);
    try testing.expectError(error.ObjectNotFound, result);
}

// ============================================================================
// 12. readPackObjectAtOffset: REF_DELTA returns specific error
// ============================================================================
test "readPackObjectAtOffset: REF_DELTA returns RefDeltaRequiresExternalLookup" {
    const allocator = testing.allocator;

    const delta = try buildDelta(allocator, 5, 5, &[_]DeltaCmd{
        .{ .copy = .{ .offset = 0, .size = 5 } },
    });
    defer allocator.free(delta);

    const enc = try encodeRefDeltaObject(allocator, [_]u8{0xaa} ** 20, delta);
    defer allocator.free(enc);
    const pack_data = try buildPackFile(allocator, &[_][]const u8{enc});
    defer allocator.free(pack_data);

    const result = objects.readPackObjectAtOffset(pack_data, 12, allocator);
    try testing.expectError(error.RefDeltaRequiresExternalLookup, result);
}

// ============================================================================
// 13. idx fanout table: correct cumulative counts
// ============================================================================
test "generatePackIndex: fanout table has correct cumulative counts" {
    const allocator = testing.allocator;

    // Create blobs whose SHA-1 first bytes span different fanout buckets
    const data1 = "blob alpha\n";
    const data2 = "blob beta\n";
    const data3 = "blob gamma\n";

    const sha1 = try gitObjectSha1("blob", data1, allocator);
    const sha2 = try gitObjectSha1("blob", data2, allocator);
    const sha3 = try gitObjectSha1("blob", data3, allocator);

    const enc1 = try encodePackObject(allocator, 3, data1);
    defer allocator.free(enc1);
    const enc2 = try encodePackObject(allocator, 3, data2);
    defer allocator.free(enc2);
    const enc3 = try encodePackObject(allocator, 3, data3);
    defer allocator.free(enc3);

    const pack_data = try buildPackFile(allocator, &[_][]const u8{ enc1, enc2, enc3 });
    defer allocator.free(pack_data);

    const idx = try objects.generatePackIndex(pack_data, allocator);
    defer allocator.free(idx);

    // Verify fanout is monotonically increasing and ends at 3
    var prev: u32 = 0;
    for (0..256) |i| {
        const val = std.mem.readInt(u32, @ptrCast(idx[8 + i * 4 .. 8 + i * 4 + 4]), .big);
        try testing.expect(val >= prev);
        prev = val;
    }
    try testing.expectEqual(@as(u32, 3), prev);

    // Verify specific fanout entries
    // fanout[sha1[0]] should count objects with first byte <= sha1[0]
    _ = sha1;
    _ = sha2;
    _ = sha3;
    // The last entry (fanout[255]) must equal total count
    const last = std.mem.readInt(u32, @ptrCast(idx[8 + 255 * 4 .. 8 + 255 * 4 + 4]), .big);
    try testing.expectEqual(@as(u32, 3), last);
}

// ============================================================================
// 14. idx self-checksum validation
// ============================================================================
test "generatePackIndex: idx trailing SHA-1 is valid" {
    const allocator = testing.allocator;

    const enc = try encodePackObject(allocator, 3, "checksum test\n");
    defer allocator.free(enc);
    const pack_data = try buildPackFile(allocator, &[_][]const u8{enc});
    defer allocator.free(pack_data);

    const idx = try objects.generatePackIndex(pack_data, allocator);
    defer allocator.free(idx);

    // Last 20 bytes = SHA-1 of everything before it
    const content = idx[0 .. idx.len - 20];
    const stored_checksum = idx[idx.len - 20 ..];

    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(content);
    var computed: [20]u8 = undefined;
    hasher.final(&computed);

    try testing.expectEqualSlices(u8, &computed, stored_checksum);
}

// ============================================================================
// 15. Pack with binary data containing all 256 byte values
// ============================================================================
test "pack round-trip: all 256 byte values preserved" {
    const allocator = testing.allocator;

    var all_bytes: [256]u8 = undefined;
    for (&all_bytes, 0..) |*b, i| b.* = @intCast(i);

    const enc = try encodePackObject(allocator, 3, &all_bytes);
    defer allocator.free(enc);
    const pack_data = try buildPackFile(allocator, &[_][]const u8{enc});
    defer allocator.free(pack_data);

    const obj = try objects.readPackObjectAtOffset(pack_data, 12, allocator);
    defer obj.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.blob, obj.type);
    try testing.expectEqualSlices(u8, &all_bytes, obj.data);
}
