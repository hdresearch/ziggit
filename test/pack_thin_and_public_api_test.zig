const std = @import("std");
const testing = std.testing;
const objects = @import("git_objects");

// =============================================================================
// Tests for pack infrastructure needed by NET-SMART and NET-PACK agents:
//   1. readPackObjectAtOffset (public API for reading objects by offset from raw pack data)
//   2. Thin pack fixup (REF_DELTA to objects outside the pack)
//   3. Multi-pack object resolution
//   4. generatePackIndex correctness with OFS_DELTA chains
//   5. Pack data concatenation / incremental reception
// =============================================================================

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
};

const Platform = struct { fs: RealFs = .{} };

/// Encode a git pack varint (type+size header byte pattern)
fn encodePackObjHeader(buf: []u8, obj_type: u3, size: usize) usize {
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

/// Compress data with zlib
fn zlibCompress(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var compressed = std.ArrayList(u8).init(allocator);
    defer compressed.deinit();
    var input = std.io.fixedBufferStream(data);
    try std.compress.zlib.compress(input.reader(), compressed.writer(), .{});
    return try allocator.dupe(u8, compressed.items);
}

/// Compute git object SHA-1
fn gitSha1(obj_type: []const u8, data: []const u8) [20]u8 {
    var hasher = std.crypto.hash.Sha1.init(.{});
    var buf: [64]u8 = undefined;
    const header = std.fmt.bufPrint(&buf, "{s} {}\x00", .{ obj_type, data.len }) catch unreachable;
    hasher.update(header);
    hasher.update(data);
    var digest: [20]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

fn sha1Hex(hash: [20]u8) [40]u8 {
    var hex: [40]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{}", .{std.fmt.fmtSliceHexLower(&hash)}) catch unreachable;
    return hex;
}

/// Build pack file checksum and append it
fn finalizePack(pack: *std.ArrayList(u8)) !void {
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack.items);
    var checksum: [20]u8 = undefined;
    hasher.final(&checksum);
    try pack.appendSlice(&checksum);
}

/// Encode OFS_DELTA negative offset
fn encodeOfsOffset(buf: []u8, offset: usize) usize {
    var off = offset;
    buf[0] = @intCast(off & 0x7F);
    var len: usize = 1;
    off >>= 7;
    while (off > 0) {
        off -= 1;
        buf[len] = @intCast((off & 0x7F) | 0x80);
        len += 1;
        off >>= 7;
    }
    // Reverse (MSB-first encoding)
    std.mem.reverse(u8, buf[0..len]);
    return len;
}

/// Build a simple delta: copy first `copy_len` bytes from base, then insert `insert_data`
fn buildDelta(allocator: std.mem.Allocator, base_size: usize, copy_len: usize, insert_data: []const u8) ![]u8 {
    var delta = std.ArrayList(u8).init(allocator);
    // base_size varint
    var v = base_size;
    while (true) {
        var b: u8 = @intCast(v & 0x7F);
        v >>= 7;
        if (v > 0) b |= 0x80;
        try delta.append(b);
        if (v == 0) break;
    }
    // result_size varint
    v = copy_len + insert_data.len;
    while (true) {
        var b: u8 = @intCast(v & 0x7F);
        v >>= 7;
        if (v > 0) b |= 0x80;
        try delta.append(b);
        if (v == 0) break;
    }
    // Copy command: offset=0, size=copy_len
    if (copy_len > 0) {
        var cmd: u8 = 0x80 | 0x10; // size byte 0
        var params = std.ArrayList(u8).init(allocator);
        defer params.deinit();
        try params.append(@intCast(copy_len & 0xFF));
        if (copy_len > 0xFF) {
            cmd |= 0x20;
            try params.append(@intCast((copy_len >> 8) & 0xFF));
        }
        if (copy_len > 0xFFFF) {
            cmd |= 0x40;
            try params.append(@intCast((copy_len >> 16) & 0xFF));
        }
        try delta.append(cmd);
        try delta.appendSlice(params.items);
    }
    // Insert command(s)
    var pos: usize = 0;
    while (pos < insert_data.len) {
        const chunk = @min(127, insert_data.len - pos);
        try delta.append(@intCast(chunk));
        try delta.appendSlice(insert_data[pos .. pos + chunk]);
        pos += chunk;
    }
    return try delta.toOwnedSlice();
}

// =============================================================================
// Test: readPackObjectAtOffset reads a base blob correctly
// =============================================================================
test "public API: readPackObjectAtOffset reads base blob" {
    const allocator = testing.allocator;
    const blob_data = "hello from pack!\n";

    // Build a one-object pack
    var pack = std.ArrayList(u8).init(allocator);
    defer pack.deinit();
    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, 1, .big);

    const obj_offset = pack.items.len;
    var hdr_buf: [10]u8 = undefined;
    const hdr_len = encodePackObjHeader(&hdr_buf, 3, blob_data.len); // blob=3
    try pack.appendSlice(hdr_buf[0..hdr_len]);
    const compressed = try zlibCompress(allocator, blob_data);
    defer allocator.free(compressed);
    try pack.appendSlice(compressed);
    try finalizePack(&pack);

    const result = try objects.readPackObjectAtOffset(pack.items, obj_offset, allocator);
    defer result.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.blob, result.type);
    try testing.expectEqualStrings(blob_data, result.data);
}

// =============================================================================
// Test: readPackObjectAtOffset reads commit, tree, tag
// =============================================================================
test "public API: readPackObjectAtOffset reads all base types" {
    const allocator = testing.allocator;

    const blob = "blob data";
    const tree = "100644 f\x00" ++ [_]u8{0xaa} ** 20; // minimal tree entry
    const commit = "tree 0000000000000000000000000000000000000000\nauthor A <a> 0 +0000\ncommitter C <c> 0 +0000\n\nmsg\n";
    const tag = "object 0000000000000000000000000000000000000000\ntype commit\ntag v1\ntagger T <t> 0 +0000\n\ntag msg\n";

    const items = [_]struct { t: u3, data: []const u8, expected: objects.ObjectType }{
        .{ .t = 3, .data = blob, .expected = .blob },
        .{ .t = 2, .data = tree, .expected = .tree },
        .{ .t = 1, .data = commit, .expected = .commit },
        .{ .t = 4, .data = tag, .expected = .tag },
    };

    for (items) |item| {
        var pack = std.ArrayList(u8).init(allocator);
        defer pack.deinit();
        try pack.appendSlice("PACK");
        try pack.writer().writeInt(u32, 2, .big);
        try pack.writer().writeInt(u32, 1, .big);

        const obj_offset = pack.items.len;
        var hdr_buf: [10]u8 = undefined;
        const hdr_len = encodePackObjHeader(&hdr_buf, item.t, item.data.len);
        try pack.appendSlice(hdr_buf[0..hdr_len]);
        const comp = try zlibCompress(allocator, item.data);
        defer allocator.free(comp);
        try pack.appendSlice(comp);
        try finalizePack(&pack);

        const result = try objects.readPackObjectAtOffset(pack.items, obj_offset, allocator);
        defer result.deinit(allocator);

        try testing.expectEqual(item.expected, result.type);
        try testing.expectEqualSlices(u8, item.data, result.data);
    }
}

// =============================================================================
// Test: readPackObjectAtOffset resolves OFS_DELTA
// =============================================================================
test "public API: readPackObjectAtOffset resolves OFS_DELTA" {
    const allocator = testing.allocator;
    const base_data = "AAAAAAAAAA"; // 10 bytes
    const expected_result = "AAAAABBBBB"; // copy 5 from base, insert BBBBB

    const delta_data = try buildDelta(allocator, base_data.len, 5, "BBBBB");
    defer allocator.free(delta_data);

    var pack = std.ArrayList(u8).init(allocator);
    defer pack.deinit();
    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, 2, .big); // 2 objects

    // Object 1: base blob
    const base_offset = pack.items.len;
    var hdr_buf: [10]u8 = undefined;
    var hdr_len = encodePackObjHeader(&hdr_buf, 3, base_data.len);
    try pack.appendSlice(hdr_buf[0..hdr_len]);
    const base_comp = try zlibCompress(allocator, base_data);
    defer allocator.free(base_comp);
    try pack.appendSlice(base_comp);

    // Object 2: OFS_DELTA
    const delta_obj_offset = pack.items.len;
    hdr_len = encodePackObjHeader(&hdr_buf, 6, delta_data.len); // ofs_delta=6
    try pack.appendSlice(hdr_buf[0..hdr_len]);

    // Negative offset
    const neg_offset = delta_obj_offset - base_offset;
    var ofs_buf: [10]u8 = undefined;
    const ofs_len = encodeOfsOffset(&ofs_buf, neg_offset);
    try pack.appendSlice(ofs_buf[0..ofs_len]);

    const delta_comp = try zlibCompress(allocator, delta_data);
    defer allocator.free(delta_comp);
    try pack.appendSlice(delta_comp);

    try finalizePack(&pack);

    // Read the delta object - should resolve to the applied result
    const result = try objects.readPackObjectAtOffset(pack.items, delta_obj_offset, allocator);
    defer result.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.blob, result.type);
    try testing.expectEqualStrings(expected_result, result.data);
}

// =============================================================================
// Test: readPackObjectAtOffset with chained OFS_DELTA (delta of delta)
// =============================================================================
test "public API: readPackObjectAtOffset resolves chained OFS_DELTA" {
    const allocator = testing.allocator;
    const base_data = "XXXXXXXXXX"; // 10 bytes
    // delta1: copy 8, insert "YY" → "XXXXXXXXYY"
    const delta1_data = try buildDelta(allocator, 10, 8, "YY");
    defer allocator.free(delta1_data);
    // delta2 applied to result of delta1: copy 5, insert "ZZZZZ" → "XXXXXZZZZZ"
    const delta2_data = try buildDelta(allocator, 10, 5, "ZZZZZ");
    defer allocator.free(delta2_data);

    var pack = std.ArrayList(u8).init(allocator);
    defer pack.deinit();
    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, 3, .big);

    // Object 1: base blob
    const off0 = pack.items.len;
    var hdr_buf: [10]u8 = undefined;
    var hdr_len = encodePackObjHeader(&hdr_buf, 3, base_data.len);
    try pack.appendSlice(hdr_buf[0..hdr_len]);
    var comp = try zlibCompress(allocator, base_data);
    try pack.appendSlice(comp);
    allocator.free(comp);

    // Object 2: OFS_DELTA referencing object 1
    const off1 = pack.items.len;
    hdr_len = encodePackObjHeader(&hdr_buf, 6, delta1_data.len);
    try pack.appendSlice(hdr_buf[0..hdr_len]);
    var ofs_buf: [10]u8 = undefined;
    var ofs_len = encodeOfsOffset(&ofs_buf, off1 - off0);
    try pack.appendSlice(ofs_buf[0..ofs_len]);
    comp = try zlibCompress(allocator, delta1_data);
    try pack.appendSlice(comp);
    allocator.free(comp);

    // Object 3: OFS_DELTA referencing object 2 (chain!)
    const off2 = pack.items.len;
    hdr_len = encodePackObjHeader(&hdr_buf, 6, delta2_data.len);
    try pack.appendSlice(hdr_buf[0..hdr_len]);
    ofs_len = encodeOfsOffset(&ofs_buf, off2 - off1);
    try pack.appendSlice(ofs_buf[0..ofs_len]);
    comp = try zlibCompress(allocator, delta2_data);
    try pack.appendSlice(comp);
    allocator.free(comp);

    try finalizePack(&pack);

    // Read the chained delta - should fully resolve
    const result = try objects.readPackObjectAtOffset(pack.items, off2, allocator);
    defer result.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.blob, result.type);
    try testing.expectEqualStrings("XXXXXZZZZZ", result.data);
}

// =============================================================================
// Test: readPackObjectAtOffset rejects invalid offset
// =============================================================================
test "public API: readPackObjectAtOffset rejects out-of-bounds offset" {
    const allocator = testing.allocator;

    // Minimal valid pack with 1 blob
    const blob = "hi";
    var pack = std.ArrayList(u8).init(allocator);
    defer pack.deinit();
    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, 1, .big);
    var hdr_buf: [10]u8 = undefined;
    const hdr_len = encodePackObjHeader(&hdr_buf, 3, blob.len);
    try pack.appendSlice(hdr_buf[0..hdr_len]);
    const comp = try zlibCompress(allocator, blob);
    defer allocator.free(comp);
    try pack.appendSlice(comp);
    try finalizePack(&pack);

    // Offset way past the end
    const result = objects.readPackObjectAtOffset(pack.items, pack.items.len + 100, allocator);
    try testing.expectError(error.ObjectNotFound, result);
}

// =============================================================================
// Test: thin pack fixup - REF_DELTA referencing loose object already in repo
// =============================================================================
test "thin pack: REF_DELTA resolved against existing loose object" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create a git repo with one loose object (the base blob)
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    const repo_path = try std.fmt.allocPrint(allocator, "{s}/repo", .{tmp_path});
    defer allocator.free(repo_path);

    // Initialize git repo
    {
        var argv = [_][]const u8{ "git", "init", repo_path };
        var child = std.process.Child.init(&argv, allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        try child.spawn();
        const stdout = try child.stdout.?.reader().readAllAlloc(allocator, 1024 * 1024);
        defer allocator.free(stdout);
        const stderr = try child.stderr.?.reader().readAllAlloc(allocator, 1024 * 1024);
        defer allocator.free(stderr);
        _ = try child.wait();
    }

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{repo_path});
    defer allocator.free(git_dir);
    const platform = Platform{};

    // Store a base blob as a loose object
    const base_content = "base content for thin pack test\n";
    const base_obj = objects.GitObject.init(.blob, base_content);
    const base_hash = try base_obj.store(git_dir, &platform, allocator);
    defer allocator.free(base_hash);

    // Now build a thin pack with a REF_DELTA pointing to that base blob
    const base_sha1 = gitSha1("blob", base_content);

    // Delta: copy first 10 bytes, insert " MODIFIED"
    const delta_data = try buildDelta(allocator, base_content.len, 10, " MODIFIED\n");
    defer allocator.free(delta_data);

    const expected_result = "base conte MODIFIED\n";

    var pack = std.ArrayList(u8).init(allocator);
    defer pack.deinit();
    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, 1, .big); // 1 object (REF_DELTA only)

    // REF_DELTA object (type 7)
    var hdr_buf: [10]u8 = undefined;
    const hdr_len = encodePackObjHeader(&hdr_buf, 7, delta_data.len);
    try pack.appendSlice(hdr_buf[0..hdr_len]);

    // 20-byte SHA-1 of base object
    try pack.appendSlice(&base_sha1);

    // Compressed delta
    const delta_comp = try zlibCompress(allocator, delta_data);
    defer allocator.free(delta_comp);
    try pack.appendSlice(delta_comp);

    try finalizePack(&pack);

    // Save the thin pack - our fixThinPack should resolve the REF_DELTA
    // using the loose object already in the repo
    const fixed_pack = try objects.fixThinPack(pack.items, git_dir, &platform, allocator);
    defer allocator.free(fixed_pack);

    // The fixed pack should be a valid non-thin pack
    try testing.expect(std.mem.eql(u8, fixed_pack[0..4], "PACK"));

    // Save the fixed pack and verify we can read the delta-resolved object
    const ck = try objects.saveReceivedPack(fixed_pack, git_dir, &platform, allocator);
    defer allocator.free(ck);

    const result_sha1 = gitSha1("blob", expected_result);
    const result_hex = sha1Hex(result_sha1);
    const loaded = try objects.GitObject.load(&result_hex, git_dir, &platform, allocator);
    defer loaded.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.blob, loaded.type);
    try testing.expectEqualStrings(expected_result, loaded.data);
}

// =============================================================================
// Test: multi-pack object resolution (object in pack A, delta base in pack B)
// =============================================================================
test "multi-pack: object found across pack files" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("repo/.git/objects/pack");
    const git_dir = try tmp.dir.realpathAlloc(allocator, "repo/.git");
    defer allocator.free(git_dir);
    const platform = Platform{};

    // Pack 1: contains blob "alpha"
    const blob1 = "alpha content\n";
    {
        var pack = std.ArrayList(u8).init(allocator);
        defer pack.deinit();
        try pack.appendSlice("PACK");
        try pack.writer().writeInt(u32, 2, .big);
        try pack.writer().writeInt(u32, 1, .big);
        var hdr_buf: [10]u8 = undefined;
        const hdr_len = encodePackObjHeader(&hdr_buf, 3, blob1.len);
        try pack.appendSlice(hdr_buf[0..hdr_len]);
        const comp = try zlibCompress(allocator, blob1);
        defer allocator.free(comp);
        try pack.appendSlice(comp);
        try finalizePack(&pack);

        const ck = try objects.saveReceivedPack(pack.items, git_dir, &platform, allocator);
        allocator.free(ck);
    }

    // Pack 2: contains blob "beta"
    const blob2 = "beta content\n";
    {
        var pack = std.ArrayList(u8).init(allocator);
        defer pack.deinit();
        try pack.appendSlice("PACK");
        try pack.writer().writeInt(u32, 2, .big);
        try pack.writer().writeInt(u32, 1, .big);
        var hdr_buf: [10]u8 = undefined;
        const hdr_len = encodePackObjHeader(&hdr_buf, 3, blob2.len);
        try pack.appendSlice(hdr_buf[0..hdr_len]);
        const comp = try zlibCompress(allocator, blob2);
        defer allocator.free(comp);
        try pack.appendSlice(comp);
        try finalizePack(&pack);

        const ck = try objects.saveReceivedPack(pack.items, git_dir, &platform, allocator);
        allocator.free(ck);
    }

    // Both objects should be loadable
    const sha1_1 = gitSha1("blob", blob1);
    const hex1 = sha1Hex(sha1_1);
    const obj1 = try objects.GitObject.load(&hex1, git_dir, &platform, allocator);
    defer obj1.deinit(allocator);
    try testing.expectEqualStrings(blob1, obj1.data);

    const sha1_2 = gitSha1("blob", blob2);
    const hex2 = sha1Hex(sha1_2);
    const obj2 = try objects.GitObject.load(&hex2, git_dir, &platform, allocator);
    defer obj2.deinit(allocator);
    try testing.expectEqualStrings(blob2, obj2.data);
}

// =============================================================================
// Test: generatePackIndex with OFS_DELTA produces correct SHA-1
// =============================================================================
test "idx gen: OFS_DELTA object gets correct SHA-1 in idx" {
    const allocator = testing.allocator;
    const base_data = "base object data\n";
    const delta_data = try buildDelta(allocator, base_data.len, 5, " new tail\n");
    defer allocator.free(delta_data);

    const result_content = "base  new tail\n";
    const expected_sha1 = gitSha1("blob", result_content);

    var pack = std.ArrayList(u8).init(allocator);
    defer pack.deinit();
    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, 2, .big);

    const off0 = pack.items.len;
    var hdr_buf: [10]u8 = undefined;
    var hdr_len = encodePackObjHeader(&hdr_buf, 3, base_data.len);
    try pack.appendSlice(hdr_buf[0..hdr_len]);
    var comp = try zlibCompress(allocator, base_data);
    try pack.appendSlice(comp);
    allocator.free(comp);

    const off1 = pack.items.len;
    hdr_len = encodePackObjHeader(&hdr_buf, 6, delta_data.len);
    try pack.appendSlice(hdr_buf[0..hdr_len]);
    var ofs_buf: [10]u8 = undefined;
    const ofs_len = encodeOfsOffset(&ofs_buf, off1 - off0);
    try pack.appendSlice(ofs_buf[0..ofs_len]);
    comp = try zlibCompress(allocator, delta_data);
    try pack.appendSlice(comp);
    allocator.free(comp);

    try finalizePack(&pack);

    const idx = try objects.generatePackIndex(pack.items, allocator);
    defer allocator.free(idx);

    // There should be 2 objects in the idx
    const total = std.mem.readInt(u32, @ptrCast(idx[8 + 255 * 4 .. 8 + 255 * 4 + 4]), .big);
    try testing.expectEqual(@as(u32, 2), total);

    // Find the delta object's SHA-1 in the idx table
    const sha1_table_start: usize = 8 + 256 * 4;
    var found = false;
    for (0..total) |i| {
        const off = sha1_table_start + i * 20;
        if (std.mem.eql(u8, idx[off .. off + 20], &expected_sha1)) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

// =============================================================================
// Test: saveReceivedPack + git verify-pack end-to-end with delta
// =============================================================================
test "end-to-end: pack with OFS_DELTA accepted by git verify-pack" {
    const allocator = testing.allocator;
    const base_data = "original file content\nwith multiple lines\n";
    const delta_data = try buildDelta(allocator, base_data.len, 22, "modified second part\n");
    defer allocator.free(delta_data);

    var pack = std.ArrayList(u8).init(allocator);
    defer pack.deinit();
    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, 2, .big);

    const off0 = pack.items.len;
    var hdr_buf: [10]u8 = undefined;
    var hdr_len = encodePackObjHeader(&hdr_buf, 3, base_data.len);
    try pack.appendSlice(hdr_buf[0..hdr_len]);
    var comp = try zlibCompress(allocator, base_data);
    try pack.appendSlice(comp);
    allocator.free(comp);

    const off1 = pack.items.len;
    hdr_len = encodePackObjHeader(&hdr_buf, 6, delta_data.len);
    try pack.appendSlice(hdr_buf[0..hdr_len]);
    var ofs_buf: [10]u8 = undefined;
    const ofs_len = encodeOfsOffset(&ofs_buf, off1 - off0);
    try pack.appendSlice(ofs_buf[0..ofs_len]);
    comp = try zlibCompress(allocator, delta_data);
    try pack.appendSlice(comp);
    allocator.free(comp);

    try finalizePack(&pack);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("repo/.git/objects/pack");
    const git_dir = try tmp.dir.realpathAlloc(allocator, "repo/.git");
    defer allocator.free(git_dir);
    const platform = Platform{};

    const ck = try objects.saveReceivedPack(pack.items, git_dir, &platform, allocator);
    defer allocator.free(ck);

    // Run git verify-pack
    const idx_path = try std.fmt.allocPrint(allocator, "{s}/objects/pack/pack-{s}.idx", .{ git_dir, ck });
    defer allocator.free(idx_path);

    var verify_argv = [_][]const u8{ "git", "verify-pack", "-v", idx_path };
    var child = std.process.Child.init(&verify_argv, allocator);
    child.stderr_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    try child.spawn();
    const stdout = try child.stdout.?.reader().readAllAlloc(allocator, 1024 * 1024);
    defer allocator.free(stdout);
    _ = try child.stderr.?.reader().readAllAlloc(allocator, 1024 * 1024);
    const term = try child.wait();

    try testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, term);
}

// =============================================================================
// Test: generatePackIndex pack checksum embedded correctly
// =============================================================================
test "idx gen: pack checksum in idx matches pack file" {
    const allocator = testing.allocator;

    var pack = std.ArrayList(u8).init(allocator);
    defer pack.deinit();
    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, 1, .big);
    var hdr_buf: [10]u8 = undefined;
    const hdr_len = encodePackObjHeader(&hdr_buf, 3, 5);
    try pack.appendSlice(hdr_buf[0..hdr_len]);
    const comp = try zlibCompress(allocator, "hello");
    defer allocator.free(comp);
    try pack.appendSlice(comp);
    try finalizePack(&pack);

    const pack_checksum = pack.items[pack.items.len - 20 ..];

    const idx = try objects.generatePackIndex(pack.items, allocator);
    defer allocator.free(idx);

    // Pack checksum is at idx.len - 40 (before the idx's own checksum)
    const idx_pack_ck = idx[idx.len - 40 .. idx.len - 20];
    try testing.expectEqualSlices(u8, pack_checksum, idx_pack_ck);
}
