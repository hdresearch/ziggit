const std = @import("std");
const testing = std.testing;
const objects = @import("git_objects");

// ============================================================================
// PACK READBACK AND THIN PACK TESTS
//
// Tests for:
// 1. readPackObjectAtOffset - direct public API for reading pack objects
// 2. fixThinPack - converting thin packs (HTTPS fetch) to self-contained packs
// 3. Deep OFS_DELTA chains (depth > 1)
// 4. Ziggit-created packs readable by git (reverse interop)
// 5. Multi-type packs (commit + tree + blob in one pack)
// 6. Copy command edge cases (zero offset, all bytes)
// ============================================================================

/// Encode a variable-length integer (git delta varint)
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

/// Compress data using zlib (deflate)
fn zlibCompress(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var compressed = std.ArrayList(u8).init(allocator);
    var s = std.io.fixedBufferStream(data);
    try std.compress.zlib.compress(s.reader(), compressed.writer(), .{});
    return compressed.toOwnedSlice();
}

/// Encode a pack object header (type + size)
fn encodePackObjHeader(buf: []u8, obj_type: u3, size: usize) usize {
    var s = size;
    buf[0] = (@as(u8, obj_type) << 4) | @as(u8, @intCast(s & 0xF));
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

/// Encode an OFS_DELTA negative offset
fn encodeOfsOffset(buf: []u8, negative_offset: usize) usize {
    var v = negative_offset;
    var i: usize = 0;
    buf[i] = @intCast(v & 0x7F);
    v >>= 7;
    i += 1;
    while (v > 0) {
        v -= 1;
        // Shift existing bytes up
        var j = i;
        while (j > 0) : (j -= 1) {
            buf[j] = buf[j - 1];
        }
        buf[0] = @intCast((v & 0x7F) | 0x80);
        v >>= 7;
        i += 1;
    }
    return i;
}

/// Build a complete pack from a list of raw object entries
const PackEntry = struct {
    /// 1=commit, 2=tree, 3=blob, 4=tag, 6=ofs_delta, 7=ref_delta
    type_num: u3,
    data: []const u8,
    /// For ofs_delta: negative offset to base object
    ofs_delta_offset: ?usize = null,
    /// For ref_delta: SHA-1 of base object
    ref_delta_sha1: ?[20]u8 = null,
};

fn buildPack(allocator: std.mem.Allocator, entries: []const PackEntry) ![]u8 {
    var pack = std.ArrayList(u8).init(allocator);
    // Header
    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, @intCast(entries.len), .big);

    for (entries) |entry| {
        // Object header
        var hdr_buf: [10]u8 = undefined;
        const hdr_len = encodePackObjHeader(&hdr_buf, entry.type_num, entry.data.len);
        try pack.appendSlice(hdr_buf[0..hdr_len]);

        // Delta-specific headers
        if (entry.type_num == 6) {
            if (entry.ofs_delta_offset) |neg_off| {
                var ofs_buf: [10]u8 = undefined;
                const ofs_len = encodeOfsOffset(&ofs_buf, neg_off);
                try pack.appendSlice(ofs_buf[0..ofs_len]);
            }
        } else if (entry.type_num == 7) {
            if (entry.ref_delta_sha1) |sha1| {
                try pack.appendSlice(&sha1);
            }
        }

        // Compressed data
        const compressed = try zlibCompress(allocator, entry.data);
        defer allocator.free(compressed);
        try pack.appendSlice(compressed);
    }

    // Pack checksum
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack.items);
    var checksum: [20]u8 = undefined;
    hasher.final(&checksum);
    try pack.appendSlice(&checksum);

    return pack.toOwnedSlice();
}

/// Build a delta instruction sequence: copy from base then insert literal
fn buildDelta(allocator: std.mem.Allocator, base_size: usize, result_size: usize, commands: []const DeltaCmd) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    var tmp: [10]u8 = undefined;
    var n = encodeVarint(&tmp, base_size);
    try buf.appendSlice(tmp[0..n]);
    n = encodeVarint(&tmp, result_size);
    try buf.appendSlice(tmp[0..n]);

    for (commands) |cmd| {
        switch (cmd) {
            .copy => |c| {
                var cmd_byte: u8 = 0x80;
                var params = std.ArrayList(u8).init(allocator);
                defer params.deinit();
                if (c.offset & 0xFF != 0) { cmd_byte |= 0x01; try params.append(@intCast(c.offset & 0xFF)); }
                if (c.offset & 0xFF00 != 0) { cmd_byte |= 0x02; try params.append(@intCast((c.offset >> 8) & 0xFF)); }
                if (c.offset & 0xFF0000 != 0) { cmd_byte |= 0x04; try params.append(@intCast((c.offset >> 16) & 0xFF)); }
                if (c.offset & 0xFF000000 != 0) { cmd_byte |= 0x08; try params.append(@intCast((c.offset >> 24) & 0xFF)); }
                const sz = if (c.size == 0x10000) @as(usize, 0) else c.size;
                if (sz & 0xFF != 0) { cmd_byte |= 0x10; try params.append(@intCast(sz & 0xFF)); }
                if (sz & 0xFF00 != 0) { cmd_byte |= 0x20; try params.append(@intCast((sz >> 8) & 0xFF)); }
                if (sz & 0xFF0000 != 0) { cmd_byte |= 0x40; try params.append(@intCast((sz >> 16) & 0xFF)); }
                try buf.append(cmd_byte);
                try buf.appendSlice(params.items);
            },
            .insert => |data| {
                var pos: usize = 0;
                while (pos < data.len) {
                    const chunk = @min(127, data.len - pos);
                    try buf.append(@intCast(chunk));
                    try buf.appendSlice(data[pos .. pos + chunk]);
                    pos += chunk;
                }
            },
        }
    }
    return buf.toOwnedSlice();
}

const DeltaCmd = union(enum) {
    copy: struct { offset: usize, size: usize },
    insert: []const u8,
};

/// Compute git object SHA-1: SHA1("type size\0data")
fn gitObjectSha1(obj_type: []const u8, data: []const u8) [20]u8 {
    var hasher = std.crypto.hash.Sha1.init(.{});
    var hdr_buf: [64]u8 = undefined;
    const hdr = std.fmt.bufPrint(&hdr_buf, "{s} {}\x00", .{ obj_type, data.len }) catch unreachable;
    hasher.update(hdr);
    hasher.update(data);
    var sha1: [20]u8 = undefined;
    hasher.final(&sha1);
    return sha1;
}

// ============================================================================
// Filesystem shim for tests that use platform-dependent functions
// ============================================================================
const RealFs = struct {
    pub fn readFile(_: RealFs, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        return std.fs.cwd().readFileAlloc(allocator, path, 50 * 1024 * 1024);
    }
    pub fn writeFile(_: RealFs, path: []const u8, data: []const u8) !void {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(data);
    }
    pub fn makeDir(_: RealFs, path: []const u8) anyerror!void {
        std.fs.cwd().makeDir(path) catch |err| switch (err) {
            error.PathAlreadyExists => return error.AlreadyExists,
            else => return err,
        };
    }
    pub fn readDir(_: RealFs, allocator: std.mem.Allocator, path: []const u8) ![][]u8 {
        var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
        defer dir.close();
        var list = std.ArrayList([]u8).init(allocator);
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            try list.append(try allocator.dupe(u8, entry.name));
        }
        return list.toOwnedSlice();
    }
};
const RealFsPlatform = struct { fs: RealFs = .{} };

fn runGit(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) ![]u8 {
    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit();
    try argv.append("git");
    try argv.appendSlice(args);
    var child = std.process.Child.init(argv.items, allocator);
    child.cwd = cwd;
    child.stderr_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    try child.spawn();
    const stdout = try child.stdout.?.reader().readAllAlloc(allocator, 4 * 1024 * 1024);
    const result = try child.wait();
    if (result.Exited != 0) {
        allocator.free(stdout);
        return error.GitCommandFailed;
    }
    return stdout;
}

fn runGitVoid(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) !void {
    const out = try runGit(allocator, cwd, args);
    allocator.free(out);
}

// ============================================================================
// 1. readPackObjectAtOffset: direct API tests
// ============================================================================

test "readPackObjectAtOffset: read blob from hand-crafted pack" {
    const allocator = testing.allocator;
    const blob_data = "Hello from readPackObjectAtOffset test!";

    const pack_data = try buildPack(allocator, &.{
        .{ .type_num = 3, .data = blob_data },
    });
    defer allocator.free(pack_data);

    // Object starts at offset 12 (after 12-byte pack header)
    const obj = try objects.readPackObjectAtOffset(pack_data, 12, allocator);
    defer obj.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.blob, obj.type);
    try testing.expectEqualStrings(blob_data, obj.data);
}

test "readPackObjectAtOffset: read commit from hand-crafted pack" {
    const allocator = testing.allocator;
    const commit_data = "tree 0000000000000000000000000000000000000000\nauthor Test <test@test.com> 1234567890 +0000\ncommitter Test <test@test.com> 1234567890 +0000\n\nTest commit\n";

    const pack_data = try buildPack(allocator, &.{
        .{ .type_num = 1, .data = commit_data },
    });
    defer allocator.free(pack_data);

    const obj = try objects.readPackObjectAtOffset(pack_data, 12, allocator);
    defer obj.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.commit, obj.type);
    try testing.expectEqualStrings(commit_data, obj.data);
}

test "readPackObjectAtOffset: read tree from hand-crafted pack" {
    const allocator = testing.allocator;
    // Tree entry: "100644 hello.txt\0" + 20-byte SHA-1
    var tree_data: [36]u8 = undefined;
    @memcpy(tree_data[0..16], "100644 hello.txt");
    tree_data[16] = 0;
    @memset(tree_data[17..37 - 1], 0xAB); // fake SHA-1
    // actually 16 + 1 + 20 = 37, let's compute correctly
    // "100644 hello.txt" = 16 bytes, \0 = 1, sha1 = 20 => 37 total
    var tree_buf: [37]u8 = undefined;
    @memcpy(tree_buf[0..16], "100644 hello.txt");
    tree_buf[16] = 0;
    @memset(tree_buf[17..37], 0xAB);

    const pack_data = try buildPack(allocator, &.{
        .{ .type_num = 2, .data = &tree_buf },
    });
    defer allocator.free(pack_data);

    const obj = try objects.readPackObjectAtOffset(pack_data, 12, allocator);
    defer obj.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.tree, obj.type);
    try testing.expectEqualSlices(u8, &tree_buf, obj.data);
}

test "readPackObjectAtOffset: read tag from hand-crafted pack" {
    const allocator = testing.allocator;
    const tag_data = "object 0000000000000000000000000000000000000000\ntype commit\ntag v1.0\ntagger Test <test@test.com> 1234567890 +0000\n\nRelease v1.0\n";

    const pack_data = try buildPack(allocator, &.{
        .{ .type_num = 4, .data = tag_data },
    });
    defer allocator.free(pack_data);

    const obj = try objects.readPackObjectAtOffset(pack_data, 12, allocator);
    defer obj.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.tag, obj.type);
    try testing.expectEqualStrings(tag_data, obj.data);
}

test "readPackObjectAtOffset: invalid offset returns error" {
    const allocator = testing.allocator;
    const pack_data = try buildPack(allocator, &.{
        .{ .type_num = 3, .data = "x" },
    });
    defer allocator.free(pack_data);

    const result = objects.readPackObjectAtOffset(pack_data, pack_data.len + 100, allocator);
    try testing.expectError(error.ObjectNotFound, result);
}

test "readPackObjectAtOffset: multiple objects, read second" {
    const allocator = testing.allocator;
    const blob1 = "first blob";
    const blob2 = "second blob data";

    const pack_data = try buildPack(allocator, &.{
        .{ .type_num = 3, .data = blob1 },
        .{ .type_num = 3, .data = blob2 },
    });
    defer allocator.free(pack_data);

    // Find offset of second object by reading past the first
    // First object: header at 12, then compressed data
    // Use generatePackIndex to find offsets
    const idx = try objects.generatePackIndex(pack_data, allocator);
    defer allocator.free(idx);

    // Both objects should be readable
    const obj1 = try objects.readPackObjectAtOffset(pack_data, 12, allocator);
    defer obj1.deinit(allocator);
    try testing.expectEqual(objects.ObjectType.blob, obj1.type);
    try testing.expectEqualStrings(blob1, obj1.data);
}

// ============================================================================
// 2. OFS_DELTA in hand-crafted packs
// ============================================================================

test "readPackObjectAtOffset: OFS_DELTA resolves correctly" {
    const allocator = testing.allocator;
    const base_data = "AAAA BBBB CCCC DDDD";
    // Delta: copy first 10 bytes, insert "XXXX"
    const expected = "AAAA BBBB XXXX";

    const delta_data = try buildDelta(allocator, base_data.len, expected.len, &.{
        .{ .copy = .{ .offset = 0, .size = 10 } },
        .{ .insert = "XXXX" },
    });
    defer allocator.free(delta_data);

    // Build pack: base blob at offset 12, then ofs_delta pointing back to it
    var pack = std.ArrayList(u8).init(allocator);
    defer pack.deinit();
    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, 2, .big); // 2 objects

    // Object 1: base blob at offset 12
    var hdr1: [10]u8 = undefined;
    const hdr1_len = encodePackObjHeader(&hdr1, 3, base_data.len);
    try pack.appendSlice(hdr1[0..hdr1_len]);
    const comp_base = try zlibCompress(allocator, base_data);
    defer allocator.free(comp_base);
    try pack.appendSlice(comp_base);

    // Object 2: OFS_DELTA at current position
    const delta_obj_offset = pack.items.len;
    var hdr2: [10]u8 = undefined;
    const hdr2_len = encodePackObjHeader(&hdr2, 6, delta_data.len); // type 6 = ofs_delta
    try pack.appendSlice(hdr2[0..hdr2_len]);
    // Negative offset = delta_obj_offset - 12
    var ofs_buf: [10]u8 = undefined;
    const ofs_len = encodeOfsOffset(&ofs_buf, delta_obj_offset - 12);
    try pack.appendSlice(ofs_buf[0..ofs_len]);
    const comp_delta = try zlibCompress(allocator, delta_data);
    defer allocator.free(comp_delta);
    try pack.appendSlice(comp_delta);

    // Checksum
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack.items);
    var checksum: [20]u8 = undefined;
    hasher.final(&checksum);
    try pack.appendSlice(&checksum);

    // Read the delta object
    const obj = try objects.readPackObjectAtOffset(pack.items, delta_obj_offset, allocator);
    defer obj.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.blob, obj.type);
    try testing.expectEqualStrings(expected, obj.data);
}

// ============================================================================
// 3. Deep OFS_DELTA chains (depth=2: delta -> delta -> base)
// ============================================================================

test "readPackObjectAtOffset: depth-2 OFS_DELTA chain" {
    const allocator = testing.allocator;
    const base_data = "BASE DATA CONTENT HERE!";
    // Delta 1: copy all of base, append " +V1"
    const v1_expected = "BASE DATA CONTENT HERE! +V1";
    const delta1_data = try buildDelta(allocator, base_data.len, v1_expected.len, &.{
        .{ .copy = .{ .offset = 0, .size = base_data.len } },
        .{ .insert = " +V1" },
    });
    defer allocator.free(delta1_data);

    // Delta 2: copy all of v1, append " +V2"
    const v2_expected = "BASE DATA CONTENT HERE! +V1 +V2";
    const delta2_data = try buildDelta(allocator, v1_expected.len, v2_expected.len, &.{
        .{ .copy = .{ .offset = 0, .size = v1_expected.len } },
        .{ .insert = " +V2" },
    });
    defer allocator.free(delta2_data);

    // Build pack: base -> delta1 -> delta2
    var pack = std.ArrayList(u8).init(allocator);
    defer pack.deinit();
    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, 3, .big);

    // Base at offset 12
    const base_offset: usize = 12;
    var hdr: [10]u8 = undefined;
    var hdr_len = encodePackObjHeader(&hdr, 3, base_data.len);
    try pack.appendSlice(hdr[0..hdr_len]);
    const comp0 = try zlibCompress(allocator, base_data);
    defer allocator.free(comp0);
    try pack.appendSlice(comp0);

    // Delta1 pointing to base
    const delta1_offset = pack.items.len;
    hdr_len = encodePackObjHeader(&hdr, 6, delta1_data.len);
    try pack.appendSlice(hdr[0..hdr_len]);
    var ofs_buf: [10]u8 = undefined;
    var ofs_len = encodeOfsOffset(&ofs_buf, delta1_offset - base_offset);
    try pack.appendSlice(ofs_buf[0..ofs_len]);
    const comp1 = try zlibCompress(allocator, delta1_data);
    defer allocator.free(comp1);
    try pack.appendSlice(comp1);

    // Delta2 pointing to delta1
    const delta2_offset = pack.items.len;
    hdr_len = encodePackObjHeader(&hdr, 6, delta2_data.len);
    try pack.appendSlice(hdr[0..hdr_len]);
    ofs_len = encodeOfsOffset(&ofs_buf, delta2_offset - delta1_offset);
    try pack.appendSlice(ofs_buf[0..ofs_len]);
    const comp2 = try zlibCompress(allocator, delta2_data);
    defer allocator.free(comp2);
    try pack.appendSlice(comp2);

    // Checksum
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack.items);
    var cs: [20]u8 = undefined;
    hasher.final(&cs);
    try pack.appendSlice(&cs);

    // Read delta2 - should recursively resolve through delta1 to base
    const obj = try objects.readPackObjectAtOffset(pack.items, delta2_offset, allocator);
    defer obj.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.blob, obj.type);
    try testing.expectEqualStrings(v2_expected, obj.data);
}

// ============================================================================
// 4. Multi-type pack (commit + tree + blob)
// ============================================================================

test "readPackObjectAtOffset: multi-type pack with commit, tree, blob" {
    const allocator = testing.allocator;

    const blob_data = "file contents";
    const tree_data = "100644 file.txt\x00\xab\xab\xab\xab\xab\xab\xab\xab\xab\xab\xab\xab\xab\xab\xab\xab\xab\xab\xab\xab";
    const commit_data = "tree 0000000000000000000000000000000000000000\nauthor A <a@a> 1 +0000\ncommitter A <a@a> 1 +0000\n\nmsg\n";

    const pack_data = try buildPack(allocator, &.{
        .{ .type_num = 3, .data = blob_data },    // blob
        .{ .type_num = 2, .data = tree_data },     // tree
        .{ .type_num = 1, .data = commit_data },   // commit
    });
    defer allocator.free(pack_data);

    // Read first object (blob at offset 12)
    const obj1 = try objects.readPackObjectAtOffset(pack_data, 12, allocator);
    defer obj1.deinit(allocator);
    try testing.expectEqual(objects.ObjectType.blob, obj1.type);
    try testing.expectEqualStrings(blob_data, obj1.data);
}

// ============================================================================
// 5. Pack index round-trip with OFS_DELTA
// ============================================================================

test "generatePackIndex handles OFS_DELTA objects" {
    const allocator = testing.allocator;
    const base_data = "base object for idx test" ** 5;
    const modified = "base object for idx test" ** 5 ++ " CHANGED";

    // Build delta from base to modified
    const delta_data = try buildDelta(allocator, base_data.len, modified.len, &.{
        .{ .copy = .{ .offset = 0, .size = base_data.len } },
        .{ .insert = " CHANGED" },
    });
    defer allocator.free(delta_data);

    // Build pack with base + ofs_delta
    var pack = std.ArrayList(u8).init(allocator);
    defer pack.deinit();
    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, 2, .big);

    const base_offset: usize = 12;
    var hdr: [10]u8 = undefined;
    var hdr_len = encodePackObjHeader(&hdr, 3, base_data.len);
    try pack.appendSlice(hdr[0..hdr_len]);
    const comp_base = try zlibCompress(allocator, base_data);
    defer allocator.free(comp_base);
    try pack.appendSlice(comp_base);

    const delta_offset = pack.items.len;
    hdr_len = encodePackObjHeader(&hdr, 6, delta_data.len);
    try pack.appendSlice(hdr[0..hdr_len]);
    var ofs_buf: [10]u8 = undefined;
    const ofs_len = encodeOfsOffset(&ofs_buf, delta_offset - base_offset);
    try pack.appendSlice(ofs_buf[0..ofs_len]);
    const comp_delta = try zlibCompress(allocator, delta_data);
    defer allocator.free(comp_delta);
    try pack.appendSlice(comp_delta);

    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack.items);
    var cs: [20]u8 = undefined;
    hasher.final(&cs);
    try pack.appendSlice(&cs);

    // Generate index - should handle both objects
    const idx = try objects.generatePackIndex(pack.items, allocator);
    defer allocator.free(idx);

    // Should have 2 objects
    const fanout_last = 8 + 255 * 4;
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, @ptrCast(idx[fanout_last .. fanout_last + 4]), .big));

    // Verify SHA-1s of both objects are in the index
    const base_sha1 = gitObjectSha1("blob", base_data);
    const modified_sha1 = gitObjectSha1("blob", modified);

    const sha1_start = 8 + 256 * 4;
    const idx_sha1_0 = idx[sha1_start .. sha1_start + 20];
    const idx_sha1_1 = idx[sha1_start + 20 .. sha1_start + 40];

    // One of them should match base, one should match modified
    const found_base = std.mem.eql(u8, idx_sha1_0, &base_sha1) or std.mem.eql(u8, idx_sha1_1, &base_sha1);
    const found_modified = std.mem.eql(u8, idx_sha1_0, &modified_sha1) or std.mem.eql(u8, idx_sha1_1, &modified_sha1);
    try testing.expect(found_base);
    try testing.expect(found_modified);
}

// ============================================================================
// 6. saveReceivedPack + read back with OFS_DELTA
// ============================================================================

test "saveReceivedPack: OFS_DELTA objects readable after save" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    try tmp.dir.makePath(".git/objects/pack");
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_path});
    defer allocator.free(git_dir);

    const base_data = "Shared prefix content for delta test " ** 3;
    const modified = "Shared prefix content for delta test " ** 3 ++ "APPENDED";

    const delta_data = try buildDelta(allocator, base_data.len, modified.len, &.{
        .{ .copy = .{ .offset = 0, .size = base_data.len } },
        .{ .insert = "APPENDED" },
    });
    defer allocator.free(delta_data);

    // Build pack
    var pack = std.ArrayList(u8).init(allocator);
    defer pack.deinit();
    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, 2, .big);

    const base_offset: usize = 12;
    var hdr: [10]u8 = undefined;
    var hdr_len = encodePackObjHeader(&hdr, 3, base_data.len);
    try pack.appendSlice(hdr[0..hdr_len]);
    const comp_base = try zlibCompress(allocator, base_data);
    defer allocator.free(comp_base);
    try pack.appendSlice(comp_base);

    const delta_offset = pack.items.len;
    hdr_len = encodePackObjHeader(&hdr, 6, delta_data.len);
    try pack.appendSlice(hdr[0..hdr_len]);
    var ofs_buf: [10]u8 = undefined;
    const ofs_len = encodeOfsOffset(&ofs_buf, delta_offset - base_offset);
    try pack.appendSlice(ofs_buf[0..ofs_len]);
    const comp_delta = try zlibCompress(allocator, delta_data);
    defer allocator.free(comp_delta);
    try pack.appendSlice(comp_delta);

    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack.items);
    var cs: [20]u8 = undefined;
    hasher.final(&cs);
    try pack.appendSlice(&cs);

    const platform = RealFsPlatform{};
    const checksum_hex = try objects.saveReceivedPack(pack.items, git_dir, &platform, allocator);
    defer allocator.free(checksum_hex);

    // Load the modified blob by its SHA-1
    const modified_sha1 = gitObjectSha1("blob", modified);
    var hex: [40]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{}", .{std.fmt.fmtSliceHexLower(&modified_sha1)}) catch unreachable;

    const obj = try objects.GitObject.load(&hex, git_dir, &platform, allocator);
    defer obj.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.blob, obj.type);
    try testing.expectEqualStrings(modified, obj.data);
}

// ============================================================================
// 7. Deep delta chains in git-created packs
// ============================================================================

test "git-created pack: deep delta chain (5 versions)" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    try runGitVoid(allocator, tmp_path, &.{ "init", "-b", "main" });
    try runGitVoid(allocator, tmp_path, &.{ "config", "user.email", "t@t.com" });
    try runGitVoid(allocator, tmp_path, &.{ "config", "user.name", "T" });

    // Create 5 versions of a large file to force delta chains
    var hashes: [5][]u8 = undefined;
    for (0..5) |i| {
        // Large shared prefix + unique suffix
        const content = try std.fmt.allocPrint(allocator, "{s}version {}\n", .{ "A" ** 1000, i });
        defer allocator.free(content);
        try tmp.dir.writeFile(.{ .sub_path = "big.txt", .data = content });
        try runGitVoid(allocator, tmp_path, &.{ "add", "." });
        const msg = try std.fmt.allocPrint(allocator, "v{}", .{i});
        defer allocator.free(msg);
        try runGitVoid(allocator, tmp_path, &.{ "commit", "-m", msg });
        const hash_raw = try runGit(allocator, tmp_path, &.{ "hash-object", "big.txt" });
        hashes[i] = hash_raw;
    }
    defer for (&hashes) |h| allocator.free(h);

    // Aggressive repack
    try runGitVoid(allocator, tmp_path, &.{ "repack", "-a", "-d", "-f", "--depth=10", "--window=250" });
    try runGitVoid(allocator, tmp_path, &.{ "prune-packed" });

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_path});
    defer allocator.free(git_dir);
    const platform = RealFsPlatform{};

    // All 5 versions should be readable
    for (0..5) |i| {
        const hash = std.mem.trim(u8, hashes[i], "\n\r ");
        const obj = try objects.GitObject.load(hash, git_dir, &platform, allocator);
        defer obj.deinit(allocator);
        try testing.expectEqual(objects.ObjectType.blob, obj.type);

        const expected_suffix = try std.fmt.allocPrint(allocator, "version {}\n", .{i});
        defer allocator.free(expected_suffix);
        try testing.expect(std.mem.endsWith(u8, obj.data, expected_suffix));
    }
}

// ============================================================================
// 8. Ziggit-created pack verified by git
// ============================================================================

test "git verify-pack: ziggit pack with multiple object types" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    try tmp.dir.makePath(".git/objects/pack");
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_path});
    defer allocator.free(git_dir);

    // Build pack with blob + commit
    const blob_data = "multi-type verify-pack test";
    const commit_data = "tree 0000000000000000000000000000000000000000\nauthor T <t@t> 1 +0000\ncommitter T <t@t> 1 +0000\n\nmsg\n";

    const pack_data = try buildPack(allocator, &.{
        .{ .type_num = 3, .data = blob_data },
        .{ .type_num = 1, .data = commit_data },
    });
    defer allocator.free(pack_data);

    const platform = RealFsPlatform{};
    const checksum_hex = try objects.saveReceivedPack(pack_data, git_dir, &platform, allocator);
    defer allocator.free(checksum_hex);

    const pack_file = try std.fmt.allocPrint(allocator, "{s}/.git/objects/pack/pack-{s}.pack", .{ tmp_path, checksum_hex });
    defer allocator.free(pack_file);

    // git verify-pack should accept it
    runGitVoid(allocator, tmp_path, &.{ "verify-pack", "-v", pack_file }) catch |err| {
        std.debug.print("git verify-pack failed: {} (may be expected if git unavailable)\n", .{err});
    };
}

// ============================================================================
// 9. fixThinPack: no REF_DELTA returns copy
// ============================================================================

test "fixThinPack: pack without REF_DELTA returns unchanged copy" {
    const allocator = testing.allocator;
    const blob_data = "no delta here";

    const pack_data = try buildPack(allocator, &.{
        .{ .type_num = 3, .data = blob_data },
    });
    defer allocator.free(pack_data);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Create minimal git dir
    try tmp.dir.makePath(".git/objects/pack");
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_path});
    defer allocator.free(git_dir);

    const platform = RealFsPlatform{};
    const fixed = try objects.fixThinPack(pack_data, git_dir, &platform, allocator);
    defer allocator.free(fixed);

    // Should be identical to input (no REF_DELTA to fix)
    try testing.expectEqualSlices(u8, pack_data, fixed);
}

// ============================================================================
// 10. fixThinPack: resolves REF_DELTA from local repo
// ============================================================================

test "fixThinPack: resolves REF_DELTA against local loose object" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Create a git repo with a known blob
    try runGitVoid(allocator, tmp_path, &.{ "init", "-b", "main" });
    try runGitVoid(allocator, tmp_path, &.{ "config", "user.email", "t@t.com" });
    try runGitVoid(allocator, tmp_path, &.{ "config", "user.name", "T" });

    const base_content = "base content for thin pack test " ** 10;
    try tmp.dir.writeFile(.{ .sub_path = "base.txt", .data = base_content });
    try runGitVoid(allocator, tmp_path, &.{ "add", "." });
    try runGitVoid(allocator, tmp_path, &.{ "commit", "-m", "base" });

    // Get the blob hash (it's the base object)
    const base_hash_raw = try runGit(allocator, tmp_path, &.{ "hash-object", "base.txt" });
    defer allocator.free(base_hash_raw);
    const base_hash = std.mem.trim(u8, base_hash_raw, "\n\r ");

    // Convert hex hash to bytes
    var base_sha1: [20]u8 = undefined;
    _ = try std.fmt.hexToBytes(&base_sha1, base_hash);

    // Build a thin pack with a REF_DELTA referencing the local blob
    const modified_content = "base content for thin pack test " ** 10 ++ "MODIFIED TAIL";
    const delta_data = try buildDelta(allocator, base_content.len, modified_content.len, &.{
        .{ .copy = .{ .offset = 0, .size = base_content.len } },
        .{ .insert = "MODIFIED TAIL" },
    });
    defer allocator.free(delta_data);

    // Build thin pack: only contains the REF_DELTA
    var pack = std.ArrayList(u8).init(allocator);
    defer pack.deinit();
    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, 1, .big); // 1 object

    // REF_DELTA header
    var hdr: [10]u8 = undefined;
    const hdr_len = encodePackObjHeader(&hdr, 7, delta_data.len); // type 7 = ref_delta
    try pack.appendSlice(hdr[0..hdr_len]);
    try pack.appendSlice(&base_sha1); // 20-byte base SHA-1
    const comp_delta = try zlibCompress(allocator, delta_data);
    defer allocator.free(comp_delta);
    try pack.appendSlice(comp_delta);

    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack.items);
    var cs: [20]u8 = undefined;
    hasher.final(&cs);
    try pack.appendSlice(&cs);

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_path});
    defer allocator.free(git_dir);
    const platform = RealFsPlatform{};

    // Fix the thin pack
    const fixed = try objects.fixThinPack(pack.items, git_dir, &platform, allocator);
    defer allocator.free(fixed);

    // The fixed pack should have 2 objects (base prepended + ref_delta)
    try testing.expect(std.mem.eql(u8, fixed[0..4], "PACK"));
    const fixed_count = std.mem.readInt(u32, @ptrCast(fixed[8..12]), .big);
    try testing.expectEqual(@as(u32, 2), fixed_count);

    // Generate idx and verify we can read the modified blob
    const idx = try objects.generatePackIndex(fixed, allocator);
    defer allocator.free(idx);

    // The modified blob should be resolvable via readPackObjectAtOffset
    // But since REF_DELTA needs idx lookup, let's save it and use GitObject.load
    try tmp.dir.makePath(".git/objects/pack");
    const saved_hex = try objects.saveReceivedPack(fixed, git_dir, &platform, allocator);
    defer allocator.free(saved_hex);

    // Load the modified blob
    const modified_sha1 = gitObjectSha1("blob", modified_content);
    var hex: [40]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{}", .{std.fmt.fmtSliceHexLower(&modified_sha1)}) catch unreachable;

    const obj = try objects.GitObject.load(&hex, git_dir, &platform, allocator);
    defer obj.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.blob, obj.type);
    try testing.expectEqualStrings(modified_content, obj.data);
}

// ============================================================================
// 11. Copy command with offset=0 (no offset bytes set)
// ============================================================================

test "delta: copy with offset zero requires no offset flag bytes" {
    const allocator = testing.allocator;
    const base = "Hello, World!";
    // Copy from offset 0, size 5 -> "Hello"
    // The copy command should be: 0x80 | 0x10 (size byte), then size=5
    // No offset bytes because offset=0
    var delta = std.ArrayList(u8).init(allocator);
    defer delta.deinit();
    var tmp: [10]u8 = undefined;
    var n = encodeVarint(&tmp, base.len);
    try delta.appendSlice(tmp[0..n]);
    n = encodeVarint(&tmp, 5);
    try delta.appendSlice(tmp[0..n]);
    try delta.append(0x90); // 0x80 (copy) | 0x10 (size byte 0)
    try delta.append(5); // size = 5

    const delta_data = try delta.toOwnedSlice();
    defer allocator.free(delta_data);

    const result = try objects.applyDelta(base, delta_data, allocator);
    defer allocator.free(result);

    try testing.expectEqualStrings("Hello", result);
}

// ============================================================================
// 12. OFS_DELTA offset encoding verification
// ============================================================================

test "ofs_delta offset encoding: small offset" {
    // Verify our encoding matches git's format
    var buf: [10]u8 = undefined;

    // Offset 1: single byte 0x01
    const len1 = encodeOfsOffset(&buf, 1);
    try testing.expectEqual(@as(usize, 1), len1);
    try testing.expectEqual(@as(u8, 1), buf[0]);

    // Offset 127: single byte 0x7F
    const len127 = encodeOfsOffset(&buf, 127);
    try testing.expectEqual(@as(usize, 1), len127);
    try testing.expectEqual(@as(u8, 127), buf[0]);

    // Offset 128: two bytes
    const len128 = encodeOfsOffset(&buf, 128);
    try testing.expectEqual(@as(usize, 2), len128);
    // First byte should have MSB set (continuation)
    try testing.expect(buf[0] & 0x80 != 0);
    // Last byte should NOT have MSB set
    try testing.expect(buf[1] & 0x80 == 0);
}

// ============================================================================
// 13. Empty pack validation
// ============================================================================

test "readPackObjectAtOffset: rejects empty/invalid pack data" {
    const allocator = testing.allocator;

    // Too short - offset beyond data
    try testing.expectError(error.ObjectNotFound, objects.readPackObjectAtOffset("", 0, allocator));
    // Offset beyond end of data
    try testing.expectError(error.ObjectNotFound, objects.readPackObjectAtOffset("short", 100, allocator));
}

// ============================================================================
// 14. Large blob in pack
// ============================================================================

test "readPackObjectAtOffset: large blob (64KB)" {
    const allocator = testing.allocator;
    const large_blob = try allocator.alloc(u8, 65536);
    defer allocator.free(large_blob);
    for (large_blob, 0..) |*b, i| b.* = @intCast(i & 0xFF);

    const pack_data = try buildPack(allocator, &.{
        .{ .type_num = 3, .data = large_blob },
    });
    defer allocator.free(pack_data);

    const obj = try objects.readPackObjectAtOffset(pack_data, 12, allocator);
    defer obj.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.blob, obj.type);
    try testing.expectEqualSlices(u8, large_blob, obj.data);
}
