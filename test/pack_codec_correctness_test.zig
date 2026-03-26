const std = @import("std");
const testing = std.testing;
const objects = @import("git_objects");

// ============================================================================
// PACK CODEC CORRECTNESS TESTS
//
// Byte-level correctness tests for:
//   - Delta copy commands with multi-byte offsets and sizes
//   - REF_DELTA resolution within a single pack (generatePackIndex)
//   - Git-created OFS_DELTA packs read by ziggit
//   - saveReceivedPack + loadFromPackFiles filesystem round-trip
//   - Edge cases: large varints, copy offset byte patterns, tag objects
// ============================================================================

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

/// Build a delta from explicit commands
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

                // Offset bytes (little-endian), only emit non-zero bytes
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
                // If offset is 0, we need at least one byte
                if (c.offset == 0 and c.size != 0x10000) {
                    copy_cmd |= 0x01;
                    try copy_bytes.append(0x00);
                }

                // Size bytes (little-endian); size 0 means 0x10000
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
                // If all size bits are 0 and actual size != 0x10000, we need the low byte
                if (effective_size != 0 and effective_size & 0xFF == 0 and effective_size >> 8 & 0xFF == 0 and effective_size >> 16 & 0xFF == 0) {
                    copy_cmd |= 0x10;
                    try copy_bytes.append(0);
                }

                try delta.append(copy_cmd);
                try delta.appendSlice(copy_bytes.items);
            },
            .insert => |data| {
                // Insert commands are limited to 127 bytes each
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

// ============================================================================
// Test: copy with 2-byte offset (offset > 255)
// ============================================================================
test "applyDelta: copy with offset > 255 (2-byte offset)" {
    const allocator = testing.allocator;

    // Base: 300 bytes, we want to copy from offset 260
    var base_data: [300]u8 = undefined;
    for (&base_data, 0..) |*b, i| b.* = @intCast(i % 256);
    // Put a known marker at offset 260
    @memcpy(base_data[260..270], "MARKER_HIT");

    const expected = "MARKER_HIT";

    const delta = try buildDelta(allocator, 300, expected.len, &[_]DeltaCmd{
        .{ .copy = .{ .offset = 260, .size = 10 } },
    });
    defer allocator.free(delta);

    const result = try objects.applyDelta(&base_data, delta, allocator);
    defer allocator.free(result);
    try testing.expectEqualStrings(expected, result);
}

// ============================================================================
// Test: copy with 3-byte offset (offset > 65535)
// ============================================================================
test "applyDelta: copy with offset > 65535 (3-byte offset)" {
    const allocator = testing.allocator;

    const base_size: usize = 70000;
    const base_data = try allocator.alloc(u8, base_size);
    defer allocator.free(base_data);
    for (base_data, 0..) |*b, i| b.* = @intCast(i % 251); // prime modulus avoids patterns
    // Place marker at offset 66000
    @memcpy(base_data[66000..66005], "FOUND");

    const expected = "FOUND";

    const delta = try buildDelta(allocator, base_size, expected.len, &[_]DeltaCmd{
        .{ .copy = .{ .offset = 66000, .size = 5 } },
    });
    defer allocator.free(delta);

    const result = try objects.applyDelta(base_data, delta, allocator);
    defer allocator.free(result);
    try testing.expectEqualStrings(expected, result);
}

// ============================================================================
// Test: copy with 2-byte size (size > 255)
// ============================================================================
test "applyDelta: copy with size > 255 (2-byte size)" {
    const allocator = testing.allocator;

    const copy_size: usize = 500;
    const base_data = try allocator.alloc(u8, copy_size);
    defer allocator.free(base_data);
    for (base_data, 0..) |*b, i| b.* = @intCast(i % 256);

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
// Test: multiple copy commands reassembling base in different order
// ============================================================================
test "applyDelta: reverse order copy commands" {
    const allocator = testing.allocator;

    const base_data = "AABBCCDD";
    const expected = "CCDDAABB";

    const delta = try buildDelta(allocator, base_data.len, expected.len, &[_]DeltaCmd{
        .{ .copy = .{ .offset = 4, .size = 4 } }, // "CCDD"
        .{ .copy = .{ .offset = 0, .size = 4 } }, // "AABB"
    });
    defer allocator.free(delta);

    const result = try objects.applyDelta(base_data, delta, allocator);
    defer allocator.free(result);
    try testing.expectEqualStrings(expected, result);
}

// ============================================================================
// Test: delta producing larger output than input (insert-heavy)
// ============================================================================
test "applyDelta: result much larger than base via inserts" {
    const allocator = testing.allocator;

    const base_data = "X";
    const insert_data = "Y" ** 100; // 100 Y's
    const expected = "X" ++ insert_data;

    const delta = try buildDelta(allocator, base_data.len, expected.len, &[_]DeltaCmd{
        .{ .copy = .{ .offset = 0, .size = 1 } },
        .{ .insert = insert_data },
    });
    defer allocator.free(delta);

    const result = try objects.applyDelta(base_data, delta, allocator);
    defer allocator.free(result);
    try testing.expectEqualStrings(expected, result);
}

// ============================================================================
// Test: delta producing smaller output than input (selective copy)
// ============================================================================
test "applyDelta: result smaller than base" {
    const allocator = testing.allocator;

    const base_data = "A" ** 100;
    const expected = "A" ** 10;

    const delta = try buildDelta(allocator, base_data.len, expected.len, &[_]DeltaCmd{
        .{ .copy = .{ .offset = 0, .size = 10 } },
    });
    defer allocator.free(delta);

    const result = try objects.applyDelta(base_data, delta, allocator);
    defer allocator.free(result);
    try testing.expectEqualStrings(expected, result);
}

// ============================================================================
// Test: identity delta (copy entire base, nothing else)
// ============================================================================
test "applyDelta: identity - copy entire base unchanged" {
    const allocator = testing.allocator;

    const base_data = "The quick brown fox jumps over the lazy dog\n";

    const delta = try buildDelta(allocator, base_data.len, base_data.len, &[_]DeltaCmd{
        .{ .copy = .{ .offset = 0, .size = base_data.len } },
    });
    defer allocator.free(delta);

    const result = try objects.applyDelta(base_data, delta, allocator);
    defer allocator.free(result);
    try testing.expectEqualStrings(base_data, result);
}

// ============================================================================
// Test: REF_DELTA in generatePackIndex - base object is in the same pack
// ============================================================================
test "generatePackIndex: REF_DELTA with base in same pack gets correct SHA-1" {
    const allocator = testing.allocator;

    // Base blob
    const base_data = "base content for ref delta test\n";
    const base_sha1 = try gitObjectSha1("blob", base_data, allocator);

    // Delta result
    const extra = " + appended via ref_delta";
    const expected_result = base_data ++ extra;
    const expected_sha1 = try gitObjectSha1("blob", expected_result, allocator);

    // Build a delta that copies entire base and inserts extra
    const delta = try buildDelta(allocator, base_data.len, expected_result.len, &[_]DeltaCmd{
        .{ .copy = .{ .offset = 0, .size = base_data.len } },
        .{ .insert = extra },
    });
    defer allocator.free(delta);

    // Encode base as regular blob, delta as REF_DELTA referencing base's SHA-1
    const enc_base = try encodePackObject(allocator, 3, base_data);
    defer allocator.free(enc_base);
    const enc_delta = try encodeRefDeltaObject(allocator, base_sha1, delta);
    defer allocator.free(enc_delta);

    const pack_data = try buildPackFile(allocator, &[_][]const u8{ enc_base, enc_delta });
    defer allocator.free(pack_data);

    // generatePackIndex should handle REF_DELTA by finding base in already-indexed entries
    const idx_data = try objects.generatePackIndex(pack_data, allocator);
    defer allocator.free(idx_data);

    // Should have 2 objects
    const total = std.mem.readInt(u32, @ptrCast(idx_data[8 + 255 * 4 .. 8 + 255 * 4 + 4]), .big);
    try testing.expectEqual(@as(u32, 2), total);

    // Verify both SHA-1s present
    const sha1_start = 8 + 256 * 4;
    var found_base = false;
    var found_delta = false;
    for (0..2) |i| {
        const sha = idx_data[sha1_start + i * 20 .. sha1_start + (i + 1) * 20];
        if (std.mem.eql(u8, sha, &base_sha1)) found_base = true;
        if (std.mem.eql(u8, sha, &expected_sha1)) found_delta = true;
    }
    try testing.expect(found_base);
    try testing.expect(found_delta);
}

// ============================================================================
// Test: tag object in pack
// ============================================================================
test "pack tag object: readPackObjectAtOffset" {
    const allocator = testing.allocator;

    const tag_data = "object 0000000000000000000000000000000000000000\ntype commit\ntag v1.0\ntagger Test <t@t> 1000000000 +0000\n\nRelease v1.0\n";
    const enc = try encodePackObject(allocator, 4, tag_data);
    defer allocator.free(enc);
    const pack_data = try buildPackFile(allocator, &[_][]const u8{enc});
    defer allocator.free(pack_data);

    const obj = try objects.readPackObjectAtOffset(pack_data, 12, allocator);
    defer obj.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.tag, obj.type);
    try testing.expectEqualStrings(tag_data, obj.data);
}

// ============================================================================
// Test: git creates repo with delta compression → ziggit reads all objects
// ============================================================================
test "git cross-validation: git gc pack with deltas → ziggit reads all objects" {
    const allocator = testing.allocator;

    // Check if git is available
    const git_check = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "--version" },
    }) catch return;
    defer allocator.free(git_check.stdout);
    defer allocator.free(git_check.stderr);
    if (git_check.term.Exited != 0) return;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Create a repo with multiple similar files (to trigger delta compression)
    const setup_cmds = [_][]const u8{
        "git init",
        "git config user.email test@test.com",
        "git config user.name Test",
    };
    for (setup_cmds) |cmd| {
        const r = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "sh", "-c", cmd },
            .cwd = tmp_path,
        });
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }

    // Create multiple versions of the same file (triggers delta in pack)
    for (0..5) |i| {
        const content = try std.fmt.allocPrint(allocator, "Line 1: shared content\nLine 2: shared content\nLine 3: version {}\n", .{i});
        defer allocator.free(content);
        try tmp_dir.dir.writeFile(.{ .sub_path = "file.txt", .data = content });

        const cmds = [_][]const u8{
            "git add file.txt",
            try std.fmt.allocPrint(allocator, "git commit -m 'version {}'", .{i}),
        };
        defer allocator.free(cmds[1]);
        for (cmds) |cmd| {
            const r = try std.process.Child.run(.{
                .allocator = allocator,
                .argv = &[_][]const u8{ "sh", "-c", cmd },
                .cwd = tmp_path,
            });
            allocator.free(r.stdout);
            allocator.free(r.stderr);
        }
    }

    // Force pack creation with aggressive delta compression
    {
        const r = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "sh", "-c", "git gc --aggressive" },
            .cwd = tmp_path,
        });
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }

    // Create a pack from all objects
    {
        const r = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "sh", "-c", "git rev-list --objects --all | git pack-objects --stdout > /tmp/ziggit_test_gitpack.pack" },
            .cwd = tmp_path,
        });
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }

    const pack_data = std.fs.cwd().readFileAlloc(allocator, "/tmp/ziggit_test_gitpack.pack", 10 * 1024 * 1024) catch return;
    defer allocator.free(pack_data);
    defer std.fs.cwd().deleteFile("/tmp/ziggit_test_gitpack.pack") catch {};

    if (pack_data.len < 32) return;

    // Parse header
    try testing.expectEqualStrings("PACK", pack_data[0..4]);
    const obj_count = std.mem.readInt(u32, @ptrCast(pack_data[8..12]), .big);
    try testing.expect(obj_count >= 10); // 5 commits + 5 trees + 5 blobs minimum

    // Generate index with ziggit
    const idx_data = try objects.generatePackIndex(pack_data, allocator);
    defer allocator.free(idx_data);

    // Verify all objects indexed
    const indexed_count = std.mem.readInt(u32, @ptrCast(idx_data[8 + 255 * 4 .. 8 + 255 * 4 + 4]), .big);
    try testing.expectEqual(obj_count, indexed_count);

    // Read each object by offset from the idx to verify they decompress
    const sha1_table_start: usize = 8 + 256 * 4;
    const crc_table_start = sha1_table_start + @as(usize, indexed_count) * 20;
    const offset_table_start = crc_table_start + @as(usize, indexed_count) * 4;

    var blobs: u32 = 0;
    var trees: u32 = 0;
    var commits: u32 = 0;
    var tags: u32 = 0;

    for (0..indexed_count) |i| {
        const off_pos = offset_table_start + i * 4;
        const offset = std.mem.readInt(u32, @ptrCast(idx_data[off_pos .. off_pos + 4]), .big);

        const obj = objects.readPackObjectAtOffset(pack_data, offset, allocator) catch |err| {
            // OFS_DELTA chains should resolve; REF_DELTA would fail
            // If we hit RefDeltaRequiresExternalLookup, that's expected for thin packs
            if (err == error.RefDeltaRequiresExternalLookup) continue;
            return err;
        };
        defer obj.deinit(allocator);

        switch (obj.type) {
            .blob => blobs += 1,
            .tree => trees += 1,
            .commit => commits += 1,
            .tag => tags += 1,
        }
    }

    // We should have found at least some objects of each type
    try testing.expect(blobs >= 1);
    try testing.expect(trees >= 1);
    try testing.expect(commits >= 1);
}

// ============================================================================
// Test: pack + ziggit idx accepted by git verify-pack (with delta objects)
// ============================================================================
test "git cross-validation: ziggit pack with ofs_delta → git verify-pack" {
    const allocator = testing.allocator;

    const git_check = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "--version" },
    }) catch return;
    defer allocator.free(git_check.stdout);
    defer allocator.free(git_check.stderr);
    if (git_check.term.Exited != 0) return;

    // Build a pack with base + ofs_delta
    const base_data = "shared prefix content\n";
    const extra = "unique suffix\n";
    const result_data = base_data ++ extra;

    const delta = try buildDelta(allocator, base_data.len, result_data.len, &[_]DeltaCmd{
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

    const idx_data = try objects.generatePackIndex(pack_data, allocator);
    defer allocator.free(idx_data);

    // Write to temp dir and verify with git
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
    // Output should mention both blob objects
    try testing.expect(std.mem.indexOf(u8, verify.stdout, "blob") != null);
}

// ============================================================================
// Test: saveReceivedPack + loadFromPackFiles filesystem round-trip
// ============================================================================
test "saveReceivedPack + loadFromPackFiles: full filesystem round-trip" {
    const allocator = testing.allocator;

    // Build a pack with known content
    const blob_data = "round-trip test content\n";
    const blob_sha1 = try gitObjectSha1("blob", blob_data, allocator);
    var blob_hex: [40]u8 = undefined;
    _ = std.fmt.bufPrint(&blob_hex, "{}", .{std.fmt.fmtSliceHexLower(&blob_sha1)}) catch unreachable;

    const enc = try encodePackObject(allocator, 3, blob_data);
    defer allocator.free(enc);
    const pack_data = try buildPackFile(allocator, &[_][]const u8{enc});
    defer allocator.free(pack_data);

    // Create a fake git dir structure
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.makePath("objects/pack");

    const git_dir = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(git_dir);

    // Use native fs as platform_impl
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

    // Save the pack
    const checksum_hex = try objects.saveReceivedPack(pack_data, git_dir, NativeFs, allocator);
    defer allocator.free(checksum_hex);

    // Verify the pack and idx files were created
    const pack_path = try std.fmt.allocPrint(allocator, "{s}/objects/pack/pack-{s}.pack", .{ git_dir, checksum_hex });
    defer allocator.free(pack_path);
    const idx_path = try std.fmt.allocPrint(allocator, "{s}/objects/pack/pack-{s}.idx", .{ git_dir, checksum_hex });
    defer allocator.free(idx_path);

    // Files should exist
    _ = try std.fs.cwd().statFile(pack_path);
    _ = try std.fs.cwd().statFile(idx_path);

    // Now load the object back via loadFromPackFiles
    const loaded = try objects.loadFromPackFiles(&blob_hex, git_dir, NativeFs, allocator);
    defer loaded.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.blob, loaded.type);
    try testing.expectEqualStrings(blob_data, loaded.data);
}

// ============================================================================
// Test: saveReceivedPack rejects invalid pack data
// ============================================================================
test "saveReceivedPack: rejects bad signature" {
    const allocator = testing.allocator;

    var bad_data: [40]u8 = undefined;
    @memcpy(bad_data[0..4], "NOPE");
    @memset(bad_data[4..], 0);

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.makePath("objects/pack");
    const git_dir = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(git_dir);

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

    const result = objects.saveReceivedPack(&bad_data, git_dir, NativeFs, allocator);
    try testing.expectError(error.InvalidPackSignature, result);
}

// ============================================================================
// Test: saveReceivedPack rejects corrupted checksum
// ============================================================================
test "saveReceivedPack: rejects corrupted checksum" {
    const allocator = testing.allocator;

    const blob_data = "test\n";
    const enc = try encodePackObject(allocator, 3, blob_data);
    defer allocator.free(enc);
    const pack_data = try buildPackFile(allocator, &[_][]const u8{enc});
    defer allocator.free(pack_data);

    // Corrupt a byte in the checksum
    var corrupted = try allocator.dupe(u8, pack_data);
    defer allocator.free(corrupted);
    corrupted[corrupted.len - 3] ^= 0xFF;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.makePath("objects/pack");
    const git_dir = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(git_dir);

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

    const result = objects.saveReceivedPack(corrupted, git_dir, NativeFs, allocator);
    try testing.expectError(error.PackChecksumMismatch, result);
}

// ============================================================================
// Test: loadFromPackFiles with multiple objects in pack
// ============================================================================
test "loadFromPackFiles: find each of multiple objects by SHA-1" {
    const allocator = testing.allocator;

    const data1 = "first object data\n";
    const data2 = "second object data\n";
    const data3 = "third object data\n";

    const sha1_1 = try gitObjectSha1("blob", data1, allocator);
    const sha1_2 = try gitObjectSha1("blob", data2, allocator);
    const sha1_3 = try gitObjectSha1("blob", data3, allocator);

    var hex1: [40]u8 = undefined;
    var hex2: [40]u8 = undefined;
    var hex3: [40]u8 = undefined;
    _ = std.fmt.bufPrint(&hex1, "{}", .{std.fmt.fmtSliceHexLower(&sha1_1)}) catch unreachable;
    _ = std.fmt.bufPrint(&hex2, "{}", .{std.fmt.fmtSliceHexLower(&sha1_2)}) catch unreachable;
    _ = std.fmt.bufPrint(&hex3, "{}", .{std.fmt.fmtSliceHexLower(&sha1_3)}) catch unreachable;

    const enc1 = try encodePackObject(allocator, 3, data1);
    defer allocator.free(enc1);
    const enc2 = try encodePackObject(allocator, 3, data2);
    defer allocator.free(enc2);
    const enc3 = try encodePackObject(allocator, 3, data3);
    defer allocator.free(enc3);

    const pack_data = try buildPackFile(allocator, &[_][]const u8{ enc1, enc2, enc3 });
    defer allocator.free(pack_data);

    // Set up fake git dir
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.makePath("objects/pack");
    const git_dir = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(git_dir);

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

    // Save pack
    const cksum = try objects.saveReceivedPack(pack_data, git_dir, NativeFs, allocator);
    defer allocator.free(cksum);

    // Load each object
    {
        const obj = try objects.loadFromPackFiles(&hex1, git_dir, NativeFs, allocator);
        defer obj.deinit(allocator);
        try testing.expectEqualStrings(data1, obj.data);
    }
    {
        const obj = try objects.loadFromPackFiles(&hex2, git_dir, NativeFs, allocator);
        defer obj.deinit(allocator);
        try testing.expectEqualStrings(data2, obj.data);
    }
    {
        const obj = try objects.loadFromPackFiles(&hex3, git_dir, NativeFs, allocator);
        defer obj.deinit(allocator);
        try testing.expectEqualStrings(data3, obj.data);
    }
}

// ============================================================================
// Test: loadFromPackFiles for non-existent object returns error
// ============================================================================
test "loadFromPackFiles: non-existent object returns ObjectNotFound" {
    const allocator = testing.allocator;

    const blob_data = "exists\n";
    const enc = try encodePackObject(allocator, 3, blob_data);
    defer allocator.free(enc);
    const pack_data = try buildPackFile(allocator, &[_][]const u8{enc});
    defer allocator.free(pack_data);

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.makePath("objects/pack");
    const git_dir = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(git_dir);

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

    const cksum = try objects.saveReceivedPack(pack_data, git_dir, NativeFs, allocator);
    defer allocator.free(cksum);

    // Try to load an object that doesn't exist
    const result = objects.loadFromPackFiles("0000000000000000000000000000000000000000", git_dir, NativeFs, allocator);
    try testing.expectError(error.ObjectNotFound, result);
}

// ============================================================================
// Test: OFS_DELTA object loaded via loadFromPackFiles resolves correctly
// ============================================================================
test "loadFromPackFiles: OFS_DELTA resolves through pack index" {
    const allocator = testing.allocator;

    const base_data = "base for ofs_delta load test\n";
    const extra = " + delta addition";
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

    // Compute expected SHA-1 of the delta result
    const result_sha1 = try gitObjectSha1("blob", expected, allocator);
    var result_hex: [40]u8 = undefined;
    _ = std.fmt.bufPrint(&result_hex, "{}", .{std.fmt.fmtSliceHexLower(&result_sha1)}) catch unreachable;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.makePath("objects/pack");
    const git_dir = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(git_dir);

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

    const cksum = try objects.saveReceivedPack(pack_data, git_dir, NativeFs, allocator);
    defer allocator.free(cksum);

    // Load the delta result object by its SHA-1
    const loaded = try objects.loadFromPackFiles(&result_hex, git_dir, NativeFs, allocator);
    defer loaded.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.blob, loaded.type);
    try testing.expectEqualStrings(expected, loaded.data);
}

// ============================================================================
// Test: ziggit-generated pack + idx accepted by git cat-file
// ============================================================================
test "git cross-validation: ziggit pack → git cat-file reads correct content" {
    const allocator = testing.allocator;

    const git_check = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "--version" },
    }) catch return;
    defer allocator.free(git_check.stdout);
    defer allocator.free(git_check.stderr);
    if (git_check.term.Exited != 0) return;

    const blob_data = "Hello from ziggit cat-file test!\n";
    const blob_sha1 = try gitObjectSha1("blob", blob_data, allocator);
    var blob_hex: [40]u8 = undefined;
    _ = std.fmt.bufPrint(&blob_hex, "{}", .{std.fmt.fmtSliceHexLower(&blob_sha1)}) catch unreachable;

    const enc = try encodePackObject(allocator, 3, blob_data);
    defer allocator.free(enc);
    const pack_data = try buildPackFile(allocator, &[_][]const u8{enc});
    defer allocator.free(pack_data);

    const idx_data = try objects.generatePackIndex(pack_data, allocator);
    defer allocator.free(idx_data);

    // Set up a git repo with our pack
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const tmp_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    {
        const r = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "git", "init" },
            .cwd = tmp_path,
        });
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }

    // Write pack and idx
    const checksum = pack_data[pack_data.len - 20 ..];
    var ck_hex: [40]u8 = undefined;
    _ = std.fmt.bufPrint(&ck_hex, "{}", .{std.fmt.fmtSliceHexLower(checksum)}) catch unreachable;

    const pack_name = try std.fmt.allocPrint(allocator, ".git/objects/pack/pack-{s}.pack", .{ck_hex});
    defer allocator.free(pack_name);
    const idx_name = try std.fmt.allocPrint(allocator, ".git/objects/pack/pack-{s}.idx", .{ck_hex});
    defer allocator.free(idx_name);

    try tmp_dir.dir.makePath(".git/objects/pack");
    try tmp_dir.dir.writeFile(.{ .sub_path = pack_name, .data = pack_data });
    try tmp_dir.dir.writeFile(.{ .sub_path = idx_name, .data = idx_data });

    // git cat-file -p <blob_hex>
    const cat_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "cat-file", "-p", &blob_hex },
        .cwd = tmp_path,
    }) catch return;
    defer allocator.free(cat_result.stdout);
    defer allocator.free(cat_result.stderr);

    try testing.expectEqual(@as(u8, 0), cat_result.term.Exited);
    try testing.expectEqualStrings(blob_data, cat_result.stdout);
}

// ============================================================================
// Test: varint encoding/decoding for large sizes (> 16KB)
// ============================================================================
test "pack object with size > 16KB: correct varint round-trip" {
    const allocator = testing.allocator;

    // 20KB blob
    const size: usize = 20 * 1024;
    const blob_data = try allocator.alloc(u8, size);
    defer allocator.free(blob_data);
    for (blob_data, 0..) |*b, i| b.* = @intCast(i % 256);

    const enc = try encodePackObject(allocator, 3, blob_data);
    defer allocator.free(enc);
    const pack_data = try buildPackFile(allocator, &[_][]const u8{enc});
    defer allocator.free(pack_data);

    const obj = try objects.readPackObjectAtOffset(pack_data, 12, allocator);
    defer obj.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.blob, obj.type);
    try testing.expectEqual(size, obj.data.len);
    try testing.expectEqualSlices(u8, blob_data, obj.data);
}

// ============================================================================
// Test: commit object through pack round-trip preserves all fields
// ============================================================================
test "pack commit object: all fields preserved through round-trip" {
    const allocator = testing.allocator;

    const commit_data =
        "tree 4b825dc642cb6eb9a060e54bf899d69f22e5c6f1\n" ++
        "parent 0000000000000000000000000000000000000001\n" ++
        "parent 0000000000000000000000000000000000000002\n" ++
        "author Alice <alice@example.com> 1700000000 +0100\n" ++
        "committer Bob <bob@example.com> 1700000001 -0500\n" ++
        "\n" ++
        "Merge branch 'feature'\n" ++
        "\n" ++
        "This commit has multiple parents and a multi-line message.\n";

    const enc = try encodePackObject(allocator, 1, commit_data);
    defer allocator.free(enc);
    const pack_data = try buildPackFile(allocator, &[_][]const u8{enc});
    defer allocator.free(pack_data);

    const obj = try objects.readPackObjectAtOffset(pack_data, 12, allocator);
    defer obj.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.commit, obj.type);
    try testing.expectEqualStrings(commit_data, obj.data);
}

// ============================================================================
// Test: tree object with multiple entries through pack
// ============================================================================
test "pack tree object: binary format preserved" {
    const allocator = testing.allocator;

    // Build a tree with two entries
    var tree = std.ArrayList(u8).init(allocator);
    defer tree.deinit();

    // Entry 1: 100644 file.txt\0<20 bytes sha1>
    try tree.appendSlice("100644 file.txt\x00");
    try tree.appendSlice(&[_]u8{0xaa} ** 20);

    // Entry 2: 40000 subdir\0<20 bytes sha1>
    try tree.appendSlice("40000 subdir\x00");
    try tree.appendSlice(&[_]u8{0xbb} ** 20);

    const tree_data = try allocator.dupe(u8, tree.items);
    defer allocator.free(tree_data);

    const enc = try encodePackObject(allocator, 2, tree_data);
    defer allocator.free(enc);
    const pack_data = try buildPackFile(allocator, &[_][]const u8{enc});
    defer allocator.free(pack_data);

    const obj = try objects.readPackObjectAtOffset(pack_data, 12, allocator);
    defer obj.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.tree, obj.type);
    try testing.expectEqualSlices(u8, tree_data, obj.data);
}
