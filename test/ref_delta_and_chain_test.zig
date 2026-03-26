const std = @import("std");
const testing = std.testing;
const objects = @import("git_objects");

// ============================================================================
// REF_DELTA and thin-pack tests:
//   These test the ref_delta code path which is critical for network fetches.
//   Git servers often send thin packs with ref_delta objects.
// ============================================================================

fn git(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) ![]u8 {
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
    const stderr = try child.stderr.?.reader().readAllAlloc(allocator, 4 * 1024 * 1024);
    defer allocator.free(stderr);
    const result = try child.wait();
    if (result.Exited != 0) {
        allocator.free(stdout);
        return error.GitCommandFailed;
    }
    return stdout;
}

fn gitExec(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) !void {
    const out = try git(allocator, cwd, args);
    allocator.free(out);
}

fn makeTmpDir(allocator: std.mem.Allocator, prefix: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(allocator, "/tmp/ziggit_ref_delta_{s}_{}", .{ prefix, std.crypto.random.int(u64) });
    try std.fs.cwd().makePath(path);
    return path;
}

fn rmTmpDir(path: []const u8) void {
    std.fs.cwd().deleteTree(path) catch {};
}

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

fn appendCopyCmd(delta: *std.ArrayList(u8), offset: usize, size: usize) !void {
    var cmd: u8 = 0x80;
    var params = std.ArrayList(u8).init(delta.allocator);
    defer params.deinit();
    if (offset & 0xFF != 0) { cmd |= 0x01; try params.append(@intCast(offset & 0xFF)); }
    if (offset & 0xFF00 != 0) { cmd |= 0x02; try params.append(@intCast((offset >> 8) & 0xFF)); }
    if (offset & 0xFF0000 != 0) { cmd |= 0x04; try params.append(@intCast((offset >> 16) & 0xFF)); }
    if (offset & 0xFF000000 != 0) { cmd |= 0x08; try params.append(@intCast((offset >> 24) & 0xFF)); }
    const actual_size = if (size == 0x10000) @as(usize, 0) else size;
    if (actual_size != 0) {
        if (actual_size & 0xFF != 0 or actual_size <= 0xFF) { cmd |= 0x10; try params.append(@intCast(actual_size & 0xFF)); }
        if (actual_size & 0xFF00 != 0) { cmd |= 0x20; try params.append(@intCast((actual_size >> 8) & 0xFF)); }
        if (actual_size & 0xFF0000 != 0) { cmd |= 0x40; try params.append(@intCast((actual_size >> 16) & 0xFF)); }
    }
    try delta.append(cmd);
    try delta.appendSlice(params.items);
}

/// Compute SHA-1 of a git object (type + size + data)
fn computeObjectSha1(obj_type: []const u8, data: []const u8) [20]u8 {
    const allocator = testing.allocator;
    const header = std.fmt.allocPrint(allocator, "{s} {}\x00", .{ obj_type, data.len }) catch unreachable;
    defer allocator.free(header);
    var h = std.crypto.hash.Sha1.init(.{});
    h.update(header);
    h.update(data);
    var sha1: [20]u8 = undefined;
    h.final(&sha1);
    return sha1;
}

/// Build a pack file from raw entries (supports type 1-4, 6, 7)
fn buildPack(allocator: std.mem.Allocator, entries: []const RawPackEntry) ![]u8 {
    var pack = std.ArrayList(u8).init(allocator);
    defer pack.deinit();

    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, @intCast(entries.len), .big);

    for (entries) |entry| {
        // Encode object header
        const obj_type: u8 = entry.type_num;
        const size = entry.data.len;
        var first: u8 = (obj_type << 4) | @as(u8, @intCast(size & 0x0F));
        var remaining = size >> 4;
        if (remaining > 0) first |= 0x80;
        try pack.append(first);
        while (remaining > 0) {
            var b: u8 = @intCast(remaining & 0x7F);
            remaining >>= 7;
            if (remaining > 0) b |= 0x80;
            try pack.append(b);
        }

        // OFS_DELTA negative offset encoding
        if (entry.type_num == 6) {
            var off = entry.ofs_delta_offset;
            var off_bytes: [10]u8 = undefined;
            var off_len: usize = 1;
            off_bytes[0] = @intCast(off & 0x7F);
            off >>= 7;
            while (off > 0) {
                off -= 1;
                off_bytes[off_len] = @intCast(0x80 | (off & 0x7F));
                off >>= 7;
                off_len += 1;
            }
            var ri: usize = off_len;
            while (ri > 0) {
                ri -= 1;
                try pack.append(off_bytes[ri]);
            }
        }

        // REF_DELTA base SHA-1
        if (entry.type_num == 7) {
            try pack.appendSlice(&entry.ref_delta_sha1);
        }

        // Compress data
        var compressed = std.ArrayList(u8).init(allocator);
        defer compressed.deinit();
        var stream = std.io.fixedBufferStream(entry.data);
        try std.compress.zlib.compress(stream.reader(), compressed.writer(), .{});
        try pack.appendSlice(compressed.items);
    }

    // Pack checksum
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack.items);
    var checksum: [20]u8 = undefined;
    hasher.final(&checksum);
    try pack.appendSlice(&checksum);

    return try pack.toOwnedSlice();
}

const RawPackEntry = struct {
    type_num: u8,
    data: []const u8,
    ofs_delta_offset: usize = 0,
    ref_delta_sha1: [20]u8 = .{0} ** 20,
};

const NativePlatform = struct {
    fs: Fs = .{},
    const Fs = struct {
        pub fn readFile(_: Fs, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
            return std.fs.cwd().readFileAlloc(allocator, path, 50 * 1024 * 1024);
        }
        pub fn writeFile(_: Fs, path: []const u8, data: []const u8) !void {
            const file = try std.fs.cwd().createFile(path, .{});
            defer file.close();
            try file.writeAll(data);
        }
        pub fn makeDir(_: Fs, path: []const u8) !void {
            try std.fs.cwd().makeDir(path);
        }
    };
};

// ============================================================================
// TEST 1: Pack with REF_DELTA - base and delta in same pack
// ============================================================================
test "pack: REF_DELTA resolves from same pack file" {
    const allocator = testing.allocator;
    const dir = try makeTmpDir(allocator, "refdelta1");
    defer { rmTmpDir(dir); allocator.free(dir); }

    try gitExec(allocator, dir, &.{ "init", "-b", "main" });
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{dir});
    defer allocator.free(git_dir);

    const base_data = "Original file content that will be the base object.\n";
    const expected = "Original file content that will be MODIFIED.\n";

    // Build delta instructions
    var delta = std.ArrayList(u8).init(allocator);
    defer delta.deinit();
    var buf: [10]u8 = undefined;
    var n = encodeVarint(&buf, base_data.len);
    try delta.appendSlice(buf[0..n]);
    n = encodeVarint(&buf, expected.len);
    try delta.appendSlice(buf[0..n]);
    // Copy first 42 bytes "Original file content that will be "
    try appendCopyCmd(&delta, 0, 35);
    // Insert "MODIFIED.\n"
    try delta.append(10);
    try delta.appendSlice("MODIFIED.\n");

    const delta_data = try delta.toOwnedSlice();
    defer allocator.free(delta_data);

    const base_sha1 = computeObjectSha1("blob", base_data);

    const pack_data = try buildPack(allocator, &.{
        RawPackEntry{ .type_num = 3, .data = base_data },
        RawPackEntry{ .type_num = 7, .data = delta_data, .ref_delta_sha1 = base_sha1 },
    });
    defer allocator.free(pack_data);

    const platform = NativePlatform{};
    const checksum = try objects.saveReceivedPack(pack_data, git_dir, platform, allocator);
    defer allocator.free(checksum);

    // Read the delta-result object via ziggit
    const result_sha1 = computeObjectSha1("blob", expected);
    const result_hex = try std.fmt.allocPrint(allocator, "{}", .{std.fmt.fmtSliceHexLower(&result_sha1)});
    defer allocator.free(result_hex);

    const obj = try objects.GitObject.load(result_hex, git_dir, platform, allocator);
    defer obj.deinit(allocator);
    try testing.expectEqual(objects.ObjectType.blob, obj.type);
    try testing.expectEqualStrings(expected, obj.data);
}

// ============================================================================
// TEST 2: Pack with chained OFS_DELTA (A -> B -> C)
// ============================================================================
test "pack: chained OFS_DELTA resolves through multiple levels" {
    const allocator = testing.allocator;
    const dir = try makeTmpDir(allocator, "chain");
    defer { rmTmpDir(dir); allocator.free(dir); }

    try gitExec(allocator, dir, &.{ "init", "-b", "main" });
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{dir});
    defer allocator.free(git_dir);

    // Base -> Delta1 -> Delta2
    const base_data = "Line 1\nLine 2\nLine 3\nLine 4\nLine 5\n";
    const result1 = "Line 1\nLine 2 CHANGED\nLine 3\nLine 4\nLine 5\n";
    const result2 = "Line 1\nLine 2 CHANGED\nLine 3 ALSO CHANGED\nLine 4\nLine 5\n";

    // Delta1: base -> result1
    var d1 = std.ArrayList(u8).init(allocator);
    defer d1.deinit();
    {
        var buf2: [10]u8 = undefined;
        var n2 = encodeVarint(&buf2, base_data.len);
        try d1.appendSlice(buf2[0..n2]);
        n2 = encodeVarint(&buf2, result1.len);
        try d1.appendSlice(buf2[0..n2]);
        try appendCopyCmd(&d1, 0, 7); // "Line 1\n"
        try d1.append(15); // insert "Line 2 CHANGED\n"
        try d1.appendSlice("Line 2 CHANGED\n");
        try appendCopyCmd(&d1, 14, base_data.len - 14); // rest
    }
    const delta1_data = try d1.toOwnedSlice();
    defer allocator.free(delta1_data);

    // Delta2: result1 -> result2
    var d2 = std.ArrayList(u8).init(allocator);
    defer d2.deinit();
    {
        var buf2: [10]u8 = undefined;
        var n2 = encodeVarint(&buf2, result1.len);
        try d2.appendSlice(buf2[0..n2]);
        n2 = encodeVarint(&buf2, result2.len);
        try d2.appendSlice(buf2[0..n2]);
        try appendCopyCmd(&d2, 0, 22); // "Line 1\nLine 2 CHANGED\n"
        try d2.append(20); // insert "Line 3 ALSO CHANGED\n"
        try d2.appendSlice("Line 3 ALSO CHANGED\n");
        try appendCopyCmd(&d2, 29, result1.len - 29); // "Line 4\nLine 5\n"
    }
    const delta2_data = try d2.toOwnedSlice();
    defer allocator.free(delta2_data);

    // We need to know the byte offset of each object in the pack to set ofs_delta_offset.
    // Build manually to track offsets.
    // Pack header: 12 bytes
    // Then: base blob, delta1 (ofs to base), delta2 (ofs to delta1)

    // Compute base entry size
    var base_entry_size: usize = 0;
    {
        // Header bytes
        var size = base_data.len;
        base_entry_size += 1; // first byte
        size >>= 4;
        while (size > 0) { base_entry_size += 1; size >>= 7; }
        // Compressed data
        var compressed = std.ArrayList(u8).init(allocator);
        defer compressed.deinit();
        var stream = std.io.fixedBufferStream(@as([]const u8, base_data));
        try std.compress.zlib.compress(stream.reader(), compressed.writer(), .{});
        base_entry_size += compressed.items.len;
    }

    // Compute delta1 entry size (including OFS_DELTA negative offset header)
    const delta1_offset = 12 + base_entry_size;
    const neg_offset1 = delta1_offset - 12; // offset back to base at pos 12

    var delta1_entry_size: usize = 0;
    {
        var size = delta1_data.len;
        delta1_entry_size += 1;
        size >>= 4;
        while (size > 0) { delta1_entry_size += 1; size >>= 7; }
        // OFS_DELTA negative offset encoding size
        var off = neg_offset1;
        delta1_entry_size += 1; // at least 1 byte
        off >>= 7;
        while (off > 0) { off -= 1; delta1_entry_size += 1; off >>= 7; }
        // Compressed data
        var compressed = std.ArrayList(u8).init(allocator);
        defer compressed.deinit();
        var stream = std.io.fixedBufferStream(delta1_data);
        try std.compress.zlib.compress(stream.reader(), compressed.writer(), .{});
        delta1_entry_size += compressed.items.len;
    }

    const delta2_offset = delta1_offset + delta1_entry_size;
    const neg_offset2 = delta2_offset - delta1_offset; // offset back to delta1

    const pack_data = try buildPack(allocator, &.{
        RawPackEntry{ .type_num = 3, .data = base_data },
        RawPackEntry{ .type_num = 6, .data = delta1_data, .ofs_delta_offset = neg_offset1 },
        RawPackEntry{ .type_num = 6, .data = delta2_data, .ofs_delta_offset = neg_offset2 },
    });
    defer allocator.free(pack_data);

    const platform = NativePlatform{};
    const checksum = try objects.saveReceivedPack(pack_data, git_dir, platform, allocator);
    defer allocator.free(checksum);

    // Read the final object (result2)
    const result2_sha1 = computeObjectSha1("blob", result2);
    const result2_hex = try std.fmt.allocPrint(allocator, "{}", .{std.fmt.fmtSliceHexLower(&result2_sha1)});
    defer allocator.free(result2_hex);

    const obj = try objects.GitObject.load(result2_hex, git_dir, platform, allocator);
    defer obj.deinit(allocator);
    try testing.expectEqual(objects.ObjectType.blob, obj.type);
    try testing.expectEqualStrings(result2, obj.data);

    // Also verify intermediate (result1) is accessible
    const result1_sha1 = computeObjectSha1("blob", result1);
    const result1_hex = try std.fmt.allocPrint(allocator, "{}", .{std.fmt.fmtSliceHexLower(&result1_sha1)});
    defer allocator.free(result1_hex);

    const obj1 = try objects.GitObject.load(result1_hex, git_dir, platform, allocator);
    defer obj1.deinit(allocator);
    try testing.expectEqualStrings(result1, obj1.data);
}

// ============================================================================
// TEST 3: Git fetch-like scenario - similar content across versions
// ============================================================================
test "pack: git repack with multiple versions produces readable pack" {
    const allocator = testing.allocator;
    const dir = try makeTmpDir(allocator, "repack");
    defer { rmTmpDir(dir); allocator.free(dir); }

    try gitExec(allocator, dir, &.{ "init", "-b", "main" });
    try gitExec(allocator, dir, &.{ "config", "user.email", "t@t.com" });
    try gitExec(allocator, dir, &.{ "config", "user.name", "T" });
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{dir});
    defer allocator.free(git_dir);

    // Create a file with shared content across versions
    const file_path = try std.fmt.allocPrint(allocator, "{s}/README.md", .{dir});
    defer allocator.free(file_path);

    const versions = [_][]const u8{
        "# Project\n\nThis is the README.\n\n## Installation\n\nRun `make install`.\n",
        "# Project\n\nThis is the README.\n\n## Installation\n\nRun `zig build install`.\n\n## Usage\n\nRun the binary.\n",
        "# Project v2\n\nThis is the updated README.\n\n## Installation\n\nRun `zig build install`.\n\n## Usage\n\nRun the binary.\n\n## License\n\nMIT\n",
    };

    var blob_hashes: [3][]u8 = undefined;
    for (versions, 0..) |content, i| {
        try std.fs.cwd().writeFile(.{ .sub_path = file_path, .data = content });
        try gitExec(allocator, dir, &.{ "add", "." });
        const msg = try std.fmt.allocPrint(allocator, "v{}", .{i + 1});
        defer allocator.free(msg);
        try gitExec(allocator, dir, &.{ "commit", "-m", msg });

        const hash_raw = try git(allocator, dir, &.{ "rev-parse", "HEAD:README.md" });
        blob_hashes[i] = hash_raw;
    }
    defer for (&blob_hashes) |h| allocator.free(h);

    // Repack with delta compression
    try gitExec(allocator, dir, &.{ "repack", "-a", "-d", "-f" });

    // Read each version through ziggit
    const platform = NativePlatform{};
    for (versions, 0..) |expected_content, i| {
        const hash = std.mem.trim(u8, blob_hashes[i], "\n\r ");
        const obj = try objects.GitObject.load(hash, git_dir, platform, allocator);
        defer obj.deinit(allocator);
        try testing.expectEqual(objects.ObjectType.blob, obj.type);
        try testing.expectEqualStrings(expected_content, obj.data);
    }
}

// ============================================================================
// TEST 4: generatePackIndex correctly handles REF_DELTA
// ============================================================================
test "pack: generatePackIndex resolves REF_DELTA SHA-1 correctly" {
    const allocator = testing.allocator;

    const base_data = "base content original\n";
    const result_data = "base content CHANGED!\n";

    // Build delta
    var delta = std.ArrayList(u8).init(allocator);
    defer delta.deinit();
    var buf: [10]u8 = undefined;
    var n_val = encodeVarint(&buf, base_data.len);
    try delta.appendSlice(buf[0..n_val]);
    n_val = encodeVarint(&buf, result_data.len);
    try delta.appendSlice(buf[0..n_val]);
    // Copy "base content " (13 bytes)
    try appendCopyCmd(&delta, 0, 13);
    // Insert "CHANGED!\n"
    try delta.append(9);
    try delta.appendSlice("CHANGED!\n");

    const delta_data = try delta.toOwnedSlice();
    defer allocator.free(delta_data);

    const base_sha1 = computeObjectSha1("blob", base_data);

    const pack_data = try buildPack(allocator, &.{
        RawPackEntry{ .type_num = 3, .data = base_data },
        RawPackEntry{ .type_num = 7, .data = delta_data, .ref_delta_sha1 = base_sha1 },
    });
    defer allocator.free(pack_data);

    // Generate index
    const idx_data = try objects.generatePackIndex(pack_data, allocator);
    defer allocator.free(idx_data);

    // Should have 2 objects
    const total = std.mem.readInt(u32, @ptrCast(idx_data[8 + 255 * 4 .. 8 + 255 * 4 + 4]), .big);
    try testing.expectEqual(@as(u32, 2), total);

    // Both SHA-1s should be in the index
    const sha_table_start = 8 + 256 * 4;
    const expected_result_sha1 = computeObjectSha1("blob", result_data);

    var found_base = false;
    var found_result = false;
    for (0..total) |i| {
        const sha_offset = sha_table_start + i * 20;
        const sha = idx_data[sha_offset .. sha_offset + 20];
        if (std.mem.eql(u8, sha, &base_sha1)) found_base = true;
        if (std.mem.eql(u8, sha, &expected_result_sha1)) found_result = true;
    }
    try testing.expect(found_base);
    try testing.expect(found_result);
}

// ============================================================================
// TEST 5: Binary content delta (non-text data)
// ============================================================================
test "delta: handles binary content correctly" {
    const allocator = testing.allocator;

    // Base: 256 bytes with all byte values
    var base: [256]u8 = undefined;
    for (&base, 0..) |*b, i| b.* = @intCast(i);

    // Result: swap first 16 bytes with last 16
    var expected: [256]u8 = base;
    @memcpy(expected[0..16], base[240..256]);
    @memcpy(expected[240..256], base[0..16]);

    var delta_buf = std.ArrayList(u8).init(allocator);
    defer delta_buf.deinit();
    var buf: [10]u8 = undefined;
    var n_val = encodeVarint(&buf, 256);
    try delta_buf.appendSlice(buf[0..n_val]);
    n_val = encodeVarint(&buf, 256);
    try delta_buf.appendSlice(buf[0..n_val]);
    // Copy last 16 bytes to start
    try appendCopyCmd(&delta_buf, 240, 16);
    // Copy middle 224 bytes
    try appendCopyCmd(&delta_buf, 16, 224);
    // Copy first 16 bytes to end
    try appendCopyCmd(&delta_buf, 0, 16);

    const delta_data = try delta_buf.toOwnedSlice();
    defer allocator.free(delta_data);

    const result = try objects.applyDelta(&base, delta_data, allocator);
    defer allocator.free(result);

    try testing.expectEqualSlices(u8, &expected, result);
}

// ============================================================================
// TEST 6: Large delta with many small copy+insert operations
// ============================================================================
test "delta: many small interleaved copy and insert ops" {
    const allocator = testing.allocator;

    // Base: "AAAA BBBB CCCC DDDD EEEE FFFF GGGG HHHH " (40 bytes)
    const base = "AAAA BBBB CCCC DDDD EEEE FFFF GGGG HHHH ";

    // Result: interleave copies with inserts
    // Copy "AAAA " + insert "1111 " + copy "CCCC " + insert "2222 " + copy "EEEE " + insert "3333 "
    const expected = "AAAA 1111 CCCC 2222 EEEE 3333 ";

    var delta_buf = std.ArrayList(u8).init(allocator);
    defer delta_buf.deinit();
    var buf: [10]u8 = undefined;
    var n_val = encodeVarint(&buf, base.len);
    try delta_buf.appendSlice(buf[0..n_val]);
    n_val = encodeVarint(&buf, expected.len);
    try delta_buf.appendSlice(buf[0..n_val]);

    try appendCopyCmd(&delta_buf, 0, 5);   // "AAAA "
    try delta_buf.append(5);                // insert "1111 "
    try delta_buf.appendSlice("1111 ");
    try appendCopyCmd(&delta_buf, 10, 5);  // "CCCC "
    try delta_buf.append(5);                // insert "2222 "
    try delta_buf.appendSlice("2222 ");
    try appendCopyCmd(&delta_buf, 20, 5);  // "EEEE "
    try delta_buf.append(5);                // insert "3333 "
    try delta_buf.appendSlice("3333 ");

    const delta_data = try delta_buf.toOwnedSlice();
    defer allocator.free(delta_data);

    const result = try objects.applyDelta(base, delta_data, allocator);
    defer allocator.free(result);

    try testing.expectEqualStrings(expected, result);
}
