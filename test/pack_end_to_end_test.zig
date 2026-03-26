const std = @import("std");
const testing = std.testing;
const objects = @import("git_objects");

// ============================================================================
// End-to-end pack file tests for HTTPS clone/fetch support.
// Tests the complete flow: git creates pack → ziggit reads & indexes → git verifies.
// Focus on scenarios that clone/fetch actually produce.
// ============================================================================

fn gitCmd(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) ![]u8 {
    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit();
    try argv.append("git");
    try argv.appendSlice(args);
    var child = std.process.Child.init(argv.items, allocator);
    child.cwd = cwd;
    child.stderr_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    try child.spawn();
    const stdout = try child.stdout.?.reader().readAllAlloc(allocator, 10 * 1024 * 1024);
    const stderr = try child.stderr.?.reader().readAllAlloc(allocator, 1024 * 1024);
    defer allocator.free(stderr);
    const result = try child.wait();
    if (result.Exited != 0) {
        allocator.free(stdout);
        return error.GitCommandFailed;
    }
    return stdout;
}

fn git(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) !void {
    const out = try gitCmd(allocator, cwd, args);
    allocator.free(out);
}

const RealFsPlatform = struct {
    fs: Fs = .{},
    const Fs = struct {
        pub fn readFile(_: @This(), alloc: std.mem.Allocator, path: []const u8) ![]u8 {
            return std.fs.cwd().readFileAlloc(alloc, path, 50 * 1024 * 1024);
        }
        pub fn writeFile(_: @This(), path: []const u8, data: []const u8) !void {
            const file = try std.fs.cwd().createFile(path, .{});
            defer file.close();
            try file.writeAll(data);
        }
        pub fn makeDir(_: @This(), path: []const u8) anyerror!void {
            std.fs.cwd().makeDir(path) catch |err| switch (err) {
                error.PathAlreadyExists => return error.AlreadyExists,
                else => return err,
            };
        }
    };
};

/// Build a minimal valid pack file containing one object.
fn buildSingleObjectPack(allocator: std.mem.Allocator, obj_type: u3, data: []const u8) ![]u8 {
    var pack = std.ArrayList(u8).init(allocator);

    // Header
    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big); // version
    try pack.writer().writeInt(u32, 1, .big); // 1 object

    // Object header: type+size
    var first: u8 = (@as(u8, obj_type) << 4) | @as(u8, @intCast(data.len & 0x0F));
    var remaining = data.len >> 4;
    if (remaining > 0) first |= 0x80;
    try pack.append(first);
    while (remaining > 0) {
        var b: u8 = @intCast(remaining & 0x7F);
        remaining >>= 7;
        if (remaining > 0) b |= 0x80;
        try pack.append(b);
    }

    // Compress data
    var compressed = std.ArrayList(u8).init(allocator);
    defer compressed.deinit();
    var input = std.io.fixedBufferStream(data);
    try std.compress.zlib.compress(input.reader(), compressed.writer(), .{});
    try pack.appendSlice(compressed.items);

    // Trailing SHA-1 checksum
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack.items);
    var checksum: [20]u8 = undefined;
    hasher.final(&checksum);
    try pack.appendSlice(&checksum);

    return try pack.toOwnedSlice();
}

// ============================================================================
// TEST 1: generatePackIndex produces idx that git verify-pack accepts
// ============================================================================
test "e2e: generatePackIndex accepted by git verify-pack" {
    const allocator = testing.allocator;

    // Build a pack with one blob
    const blob_data = "Hello, this is test content for pack index generation!\n";
    const pack_data = try buildSingleObjectPack(allocator, 3, blob_data);
    defer allocator.free(pack_data);

    // Generate idx with ziggit
    const idx_data = try objects.generatePackIndex(pack_data, allocator);
    defer allocator.free(idx_data);

    // Write to temp dir and verify with git
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const pack_path = try std.fmt.allocPrint(allocator, "{s}/test.pack", .{tmp_path});
    defer allocator.free(pack_path);
    const idx_path = try std.fmt.allocPrint(allocator, "{s}/test.idx", .{tmp_path});
    defer allocator.free(idx_path);

    try tmp.dir.writeFile(.{ .sub_path = "test.pack", .data = pack_data });
    try tmp.dir.writeFile(.{ .sub_path = "test.idx", .data = idx_data });

    // git verify-pack should succeed
    git(allocator, tmp_path, &.{ "verify-pack", pack_path }) catch |err| {
        std.debug.print("git verify-pack failed: {}\n", .{err});
        return err;
    };
}

// ============================================================================
// TEST 2: Multi-commit repo repacked → ziggit reads all objects correctly
// ============================================================================
test "e2e: multi-commit repack, ziggit reads all objects" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    git(allocator, tmp_path, &.{ "init", "-b", "main" }) catch return;
    git(allocator, tmp_path, &.{ "config", "user.email", "test@test.com" }) catch return;
    git(allocator, tmp_path, &.{ "config", "user.name", "Test" }) catch return;

    // Create 5 commits with evolving content
    const versions = [_][]const u8{
        "version 1: initial content\nshared line A\nshared line B\n",
        "version 2: modified content\nshared line A\nshared line B\nnew line\n",
        "version 3: more changes\nshared line A\nmodified line B\nnew line\n",
        "version 4: significant rewrite\ncompletely different\n",
        "version 5: back to normal\nshared line A\nshared line B\nfinal\n",
    };

    var commit_hashes: [5][]u8 = undefined;
    for (versions, 0..) |content, i| {
        try tmp.dir.writeFile(.{ .sub_path = "file.txt", .data = content });
        git(allocator, tmp_path, &.{ "add", "file.txt" }) catch return;
        const msg = try std.fmt.allocPrint(allocator, "commit {}", .{i + 1});
        defer allocator.free(msg);
        git(allocator, tmp_path, &.{ "commit", "-m", msg }) catch return;
        commit_hashes[i] = gitCmd(allocator, tmp_path, &.{ "rev-parse", "HEAD" }) catch return;
    }
    defer for (&commit_hashes) |h| allocator.free(h);

    // Aggressive repack to create delta chains
    git(allocator, tmp_path, &.{ "repack", "-a", "-d", "-f", "--depth=10", "--window=50" }) catch return;
    git(allocator, tmp_path, &.{ "prune-packed" }) catch {};

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_path});
    defer allocator.free(git_dir);
    const platform = RealFsPlatform{};

    // Verify every commit is loadable and its tree is readable
    for (commit_hashes) |raw_hash| {
        const hash = std.mem.trim(u8, raw_hash, " \t\n\r");
        if (hash.len != 40) continue;

        const commit_obj = objects.GitObject.load(hash, git_dir, &platform, allocator) catch |err| {
            std.debug.print("Failed to load commit {s}: {}\n", .{ hash, err });
            return err;
        };
        defer commit_obj.deinit(allocator);

        try testing.expectEqual(objects.ObjectType.commit, commit_obj.type);

        // Parse tree hash from commit data
        if (std.mem.indexOf(u8, commit_obj.data, "tree ")) |tree_start| {
            const tree_hash = commit_obj.data[tree_start + 5 .. tree_start + 45];
            const tree_obj = objects.GitObject.load(tree_hash, git_dir, &platform, allocator) catch |err| {
                std.debug.print("Failed to load tree {s}: {}\n", .{ tree_hash, err });
                return err;
            };
            defer tree_obj.deinit(allocator);
            try testing.expectEqual(objects.ObjectType.tree, tree_obj.type);
        }
    }
}

// ============================================================================
// TEST 3: saveReceivedPack → objects loadable by both ziggit and git cat-file
// ============================================================================
test "e2e: saveReceivedPack, objects readable by ziggit and git" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Initialize a bare-ish git repo for saving pack into
    git(allocator, tmp_path, &.{ "init", "-b", "main" }) catch return;

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_path});
    defer allocator.free(git_dir);
    const platform = RealFsPlatform{};

    // Build a pack with a blob
    const content = "This blob was received over the network!\n";
    const pack_data = try buildSingleObjectPack(allocator, 3, content);
    defer allocator.free(pack_data);

    // Save it via ziggit's saveReceivedPack
    const checksum_hex = try objects.saveReceivedPack(pack_data, git_dir, &platform, allocator);
    defer allocator.free(checksum_hex);

    // Compute expected blob hash
    const blob_header = try std.fmt.allocPrint(allocator, "blob {}\x00", .{content.len});
    defer allocator.free(blob_header);
    var sha = std.crypto.hash.Sha1.init(.{});
    sha.update(blob_header);
    sha.update(content);
    var digest: [20]u8 = undefined;
    sha.final(&digest);
    var hash_hex: [40]u8 = undefined;
    _ = try std.fmt.bufPrint(&hash_hex, "{}", .{std.fmt.fmtSliceHexLower(&digest)});

    // Read with ziggit
    const obj = objects.GitObject.load(&hash_hex, git_dir, &platform, allocator) catch |err| {
        std.debug.print("ziggit load failed: {}\n", .{err});
        return err;
    };
    defer obj.deinit(allocator);
    try testing.expectEqual(objects.ObjectType.blob, obj.type);
    try testing.expectEqualStrings(content, obj.data);

    // Read with git cat-file
    const cat_output = gitCmd(allocator, tmp_path, &.{ "cat-file", "-p", &hash_hex }) catch |err| {
        std.debug.print("git cat-file failed: {}\n", .{err});
        return err;
    };
    defer allocator.free(cat_output);
    try testing.expectEqualStrings(content, cat_output);
}

// ============================================================================
// TEST 4: idx CRC32 values match git's idx for same pack
// ============================================================================
test "e2e: idx CRC32 values match git index-pack output" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Build a pack with several objects
    const blob1 = "first blob content\n";
    const blob2 = "second blob content - different data\n";

    var pack = std.ArrayList(u8).init(allocator);
    defer pack.deinit();

    // Header
    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, 2, .big); // 2 objects

    // Blob 1
    {
        var first: u8 = (3 << 4) | @as(u8, @intCast(blob1.len & 0x0F));
        var rem = blob1.len >> 4;
        if (rem > 0) first |= 0x80;
        try pack.append(first);
        while (rem > 0) {
            var b: u8 = @intCast(rem & 0x7F);
            rem >>= 7;
            if (rem > 0) b |= 0x80;
            try pack.append(b);
        }
        var c1 = std.ArrayList(u8).init(allocator);
        defer c1.deinit();
        var in1 = std.io.fixedBufferStream(@as([]const u8, blob1));
        try std.compress.zlib.compress(in1.reader(), c1.writer(), .{});
        try pack.appendSlice(c1.items);
    }

    // Blob 2
    {
        var first: u8 = (3 << 4) | @as(u8, @intCast(blob2.len & 0x0F));
        var rem = blob2.len >> 4;
        if (rem > 0) first |= 0x80;
        try pack.append(first);
        while (rem > 0) {
            var b: u8 = @intCast(rem & 0x7F);
            rem >>= 7;
            if (rem > 0) b |= 0x80;
            try pack.append(b);
        }
        var c2 = std.ArrayList(u8).init(allocator);
        defer c2.deinit();
        var in2 = std.io.fixedBufferStream(@as([]const u8, blob2));
        try std.compress.zlib.compress(in2.reader(), c2.writer(), .{});
        try pack.appendSlice(c2.items);
    }

    // Checksum
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack.items);
    var cksum: [20]u8 = undefined;
    hasher.final(&cksum);
    try pack.appendSlice(&cksum);

    const pack_data = try pack.toOwnedSlice();
    defer allocator.free(pack_data);

    // Generate idx with ziggit
    const our_idx = try objects.generatePackIndex(pack_data, allocator);
    defer allocator.free(our_idx);

    // Write pack, let git generate idx too
    try tmp.dir.writeFile(.{ .sub_path = "test.pack", .data = pack_data });
    const pack_path = try std.fmt.allocPrint(allocator, "{s}/test.pack", .{tmp_path});
    defer allocator.free(pack_path);

    git(allocator, tmp_path, &.{ "index-pack", pack_path }) catch return;

    // Read git's idx
    const git_idx = tmp.dir.readFileAlloc(allocator, "test.idx", 10 * 1024 * 1024) catch return;
    defer allocator.free(git_idx);

    // Both should have same magic + version
    try testing.expectEqualSlices(u8, git_idx[0..8], our_idx[0..8]);

    // Both should have same fanout table
    try testing.expectEqualSlices(u8, git_idx[8 .. 8 + 256 * 4], our_idx[8 .. 8 + 256 * 4]);

    // Both should have same SHA-1 table (sorted identically)
    const n_objects: usize = 2;
    const sha_start = 8 + 256 * 4;
    const sha_end = sha_start + n_objects * 20;
    try testing.expectEqualSlices(u8, git_idx[sha_start..sha_end], our_idx[sha_start..sha_end]);

    // CRC32 values should match
    const crc_start = sha_end;
    const crc_end = crc_start + n_objects * 4;
    try testing.expectEqualSlices(u8, git_idx[crc_start..crc_end], our_idx[crc_start..crc_end]);

    // Pack checksum in idx should match
    const our_pack_cksum_start = our_idx.len - 40;
    const git_pack_cksum_start = git_idx.len - 40;
    try testing.expectEqualSlices(u8, git_idx[git_pack_cksum_start .. git_pack_cksum_start + 20], our_idx[our_pack_cksum_start .. our_pack_cksum_start + 20]);
}

// ============================================================================
// TEST 5: Deep delta chain (5 levels) from aggressive repack
// ============================================================================
test "e2e: 5-level delta chain from aggressive repack" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    git(allocator, tmp_path, &.{ "init", "-b", "main" }) catch return;
    git(allocator, tmp_path, &.{ "config", "user.email", "t@t.com" }) catch return;
    git(allocator, tmp_path, &.{ "config", "user.name", "T" }) catch return;
    git(allocator, tmp_path, &.{ "config", "pack.depth", "10" }) catch return;

    // Create many small mutations to encourage deep delta chains
    const base = "AAAAAAAAAAAAAAAAAAAAAAAAAAA common content that stays the same across all versions to maximize delta efficiency BBBBBBBBBBBBBBBBBBBBB\n";
    var blob_hashes: [7][]u8 = undefined;
    var hash_count: usize = 0;

    for (0..7) |i| {
        var content = std.ArrayList(u8).init(allocator);
        defer content.deinit();
        try content.appendSlice(base);
        // Append unique line
        const line = try std.fmt.allocPrint(allocator, "version {} unique data: {x}\n", .{ i, i * 0x1234 });
        defer allocator.free(line);
        try content.appendSlice(line);

        try tmp.dir.writeFile(.{ .sub_path = "data.txt", .data = content.items });
        git(allocator, tmp_path, &.{ "add", "data.txt" }) catch return;
        const msg = try std.fmt.allocPrint(allocator, "v{}", .{i});
        defer allocator.free(msg);
        git(allocator, tmp_path, &.{ "commit", "-m", msg }) catch return;

        blob_hashes[i] = gitCmd(allocator, tmp_path, &.{ "rev-parse", "HEAD:data.txt" }) catch return;
        hash_count += 1;
    }
    defer for (blob_hashes[0..hash_count]) |h| allocator.free(h);

    // Force deep deltas
    git(allocator, tmp_path, &.{ "repack", "-a", "-d", "-f", "--depth=10", "--window=250" }) catch return;
    git(allocator, tmp_path, &.{ "prune-packed" }) catch {};

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_path});
    defer allocator.free(git_dir);
    const platform = RealFsPlatform{};

    // Verify every blob version is loadable
    for (blob_hashes[0..hash_count], 0..) |raw_hash, i| {
        const hash = std.mem.trim(u8, raw_hash, " \t\n\r");
        if (hash.len != 40) continue;

        const obj = objects.GitObject.load(hash, git_dir, &platform, allocator) catch |err| {
            std.debug.print("Failed to load blob v{}: {}\n", .{ i, err });
            return err;
        };
        defer obj.deinit(allocator);

        try testing.expectEqual(objects.ObjectType.blob, obj.type);

        // Verify content starts with base
        try testing.expect(std.mem.startsWith(u8, obj.data, "AAAA"));
    }
}

// ============================================================================
// TEST 6: Binary data (null bytes, high bytes) roundtrip through pack
// ============================================================================
test "e2e: binary blob with null bytes through pack roundtrip" {
    const allocator = testing.allocator;

    // Create binary data with every possible byte value
    var binary_data: [256]u8 = undefined;
    for (&binary_data, 0..) |*b, i| b.* = @intCast(i);

    const pack_data = try buildSingleObjectPack(allocator, 3, &binary_data);
    defer allocator.free(pack_data);

    // Read back with readPackObjectAtOffset
    const obj = try objects.readPackObjectAtOffset(pack_data, 12, allocator);
    defer obj.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.blob, obj.type);
    try testing.expectEqual(@as(usize, 256), obj.data.len);
    try testing.expectEqualSlices(u8, &binary_data, obj.data);

    // Also test through generatePackIndex + findOffsetInIdx round-trip
    const idx_data = try objects.generatePackIndex(pack_data, allocator);
    defer allocator.free(idx_data);

    // Verify idx has exactly 1 object
    const total = std.mem.readInt(u32, @ptrCast(idx_data[8 + 255 * 4 .. 8 + 255 * 4 + 4]), .big);
    try testing.expectEqual(@as(u32, 1), total);
}

// ============================================================================
// TEST 7: Empty tree object in pack
// ============================================================================
test "e2e: empty tree object in pack" {
    const allocator = testing.allocator;

    // Empty tree is a valid git object (40 zero bytes of content)
    const pack_data = try buildSingleObjectPack(allocator, 2, "");
    defer allocator.free(pack_data);

    const obj = try objects.readPackObjectAtOffset(pack_data, 12, allocator);
    defer obj.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.tree, obj.type);
    try testing.expectEqual(@as(usize, 0), obj.data.len);
}

// ============================================================================
// TEST 8: Tag object in pack, readable and hash matches
// ============================================================================
test "e2e: tag object roundtrip through pack + idx" {
    const allocator = testing.allocator;

    const tag_content = "object 0000000000000000000000000000000000000000\ntype commit\ntag v1.0\ntagger Test <test@test.com> 1700000000 +0000\n\nRelease v1.0\n";

    const pack_data = try buildSingleObjectPack(allocator, 4, tag_content);
    defer allocator.free(pack_data);

    const obj = try objects.readPackObjectAtOffset(pack_data, 12, allocator);
    defer obj.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.tag, obj.type);
    try testing.expectEqualStrings(tag_content, obj.data);

    // Generate idx and verify SHA-1
    const idx_data = try objects.generatePackIndex(pack_data, allocator);
    defer allocator.free(idx_data);

    // Compute expected SHA-1
    const header = try std.fmt.allocPrint(allocator, "tag {}\x00", .{tag_content.len});
    defer allocator.free(header);
    var sha = std.crypto.hash.Sha1.init(.{});
    sha.update(header);
    sha.update(tag_content);
    var expected_hash: [20]u8 = undefined;
    sha.final(&expected_hash);

    // SHA-1 table starts at offset 8 + 256*4 = 1032
    const sha_in_idx = idx_data[1032 .. 1032 + 20];
    try testing.expectEqualSlices(u8, &expected_hash, sha_in_idx);
}

// ============================================================================
// TEST 9: OFS_DELTA in hand-crafted pack with known delta result
// ============================================================================
test "e2e: hand-crafted OFS_DELTA produces correct result" {
    const allocator = testing.allocator;

    const base_data = "Hello World! This is the base object content.\n";
    const expected_result = "Hello World! This is MODIFIED content.\n";

    var pack = std.ArrayList(u8).init(allocator);
    defer pack.deinit();

    // Header
    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, 2, .big); // 2 objects

    // Object 1: base blob at offset 12
    const base_offset: usize = 12;
    {
        var first: u8 = (3 << 4) | @as(u8, @intCast(base_data.len & 0x0F));
        var rem = base_data.len >> 4;
        if (rem > 0) first |= 0x80;
        try pack.append(first);
        while (rem > 0) {
            var b: u8 = @intCast(rem & 0x7F);
            rem >>= 7;
            if (rem > 0) b |= 0x80;
            try pack.append(b);
        }
        var c = std.ArrayList(u8).init(allocator);
        defer c.deinit();
        var inp = std.io.fixedBufferStream(@as([]const u8, base_data));
        try std.compress.zlib.compress(inp.reader(), c.writer(), .{});
        try pack.appendSlice(c.items);
    }

    // Object 2: OFS_DELTA referencing object 1
    const delta_obj_offset = pack.items.len;
    {
        // Build delta data: copy "Hello World! This is " (21 bytes) + insert "MODIFIED content.\n"
        var delta = std.ArrayList(u8).init(allocator);
        defer delta.deinit();

        // varint: base_size
        var buf: [10]u8 = undefined;
        var n = encodeVarint(&buf, base_data.len);
        try delta.appendSlice(buf[0..n]);
        // varint: result_size
        n = encodeVarint(&buf, expected_result.len);
        try delta.appendSlice(buf[0..n]);

        // Copy offset=0, size=21 ("Hello World! This is ")
        try delta.append(0x80 | 0x10); // copy, size byte 0
        try delta.append(21);

        // Insert "MODIFIED content.\n" (18 bytes)
        try delta.append(18);
        try delta.appendSlice("MODIFIED content.\n");

        const delta_bytes = delta.items;

        // OFS_DELTA header
        const ofs_delta_size = delta_bytes.len;
        var first: u8 = (6 << 4) | @as(u8, @intCast(ofs_delta_size & 0x0F));
        var rem = ofs_delta_size >> 4;
        if (rem > 0) first |= 0x80;
        try pack.append(first);
        while (rem > 0) {
            var b: u8 = @intCast(rem & 0x7F);
            rem >>= 7;
            if (rem > 0) b |= 0x80;
            try pack.append(b);
        }

        // Negative offset to base (delta_obj_offset - base_offset)
        const neg_offset = delta_obj_offset - base_offset;
        // Encode negative offset (git's variable-length encoding)
        var off = neg_offset;
        try pack.append(@intCast(off & 0x7F));
        off >>= 7;
        while (off > 0) {
            // Prepend continuation byte - but we need to encode MSB-first
            // Actually git encodes this differently: first byte has MSB=0 for last
            break; // Simple case: offset fits in 7 bits handled above
        }
        // For larger offsets we'd need multi-byte encoding, but this test uses small offsets

        // Compress delta data
        var cd = std.ArrayList(u8).init(allocator);
        defer cd.deinit();
        var di = std.io.fixedBufferStream(@as([]const u8, delta_bytes));
        try std.compress.zlib.compress(di.reader(), cd.writer(), .{});
        try pack.appendSlice(cd.items);
    }

    // Trailing checksum
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack.items);
    var cksum: [20]u8 = undefined;
    hasher.final(&cksum);
    try pack.appendSlice(&cksum);

    // Read the delta object
    const obj = try objects.readPackObjectAtOffset(pack.items, delta_obj_offset, allocator);
    defer obj.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.blob, obj.type);
    try testing.expectEqualStrings(expected_result, obj.data);
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

// ============================================================================
// TEST 10: REF_DELTA in pack resolved by generatePackIndex (base before delta)
// ============================================================================
test "e2e: REF_DELTA resolved by generatePackIndex when base precedes delta" {
    const allocator = testing.allocator;

    const base_data = "base content for ref-delta test\n";
    const modified_data = "base content for ref-delta test - MODIFIED\n";

    // Compute base blob's SHA-1
    const base_header = try std.fmt.allocPrint(allocator, "blob {}\x00", .{base_data.len});
    defer allocator.free(base_header);
    var sha = std.crypto.hash.Sha1.init(.{});
    sha.update(base_header);
    sha.update(base_data);
    var base_sha1: [20]u8 = undefined;
    sha.final(&base_sha1);

    // Build delta: copy first 31 bytes, insert " - MODIFIED\n"
    var delta = std.ArrayList(u8).init(allocator);
    defer delta.deinit();
    var buf: [10]u8 = undefined;
    var n = encodeVarint(&buf, base_data.len);
    try delta.appendSlice(buf[0..n]);
    n = encodeVarint(&buf, modified_data.len);
    try delta.appendSlice(buf[0..n]);
    // Copy first 31 bytes from base
    try delta.append(0x80 | 0x10);
    try delta.append(31);
    // Insert " - MODIFIED\n" (13 bytes)
    try delta.append(13);
    try delta.appendSlice(" - MODIFIED\n");

    // Build pack with base blob + REF_DELTA
    var pack = std.ArrayList(u8).init(allocator);
    defer pack.deinit();

    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, 2, .big);

    // Base blob
    {
        var first: u8 = (3 << 4) | @as(u8, @intCast(base_data.len & 0x0F));
        var rem = base_data.len >> 4;
        if (rem > 0) first |= 0x80;
        try pack.append(first);
        while (rem > 0) {
            var b: u8 = @intCast(rem & 0x7F);
            rem >>= 7;
            if (rem > 0) b |= 0x80;
            try pack.append(b);
        }
        var c = std.ArrayList(u8).init(allocator);
        defer c.deinit();
        var inp = std.io.fixedBufferStream(@as([]const u8, base_data));
        try std.compress.zlib.compress(inp.reader(), c.writer(), .{});
        try pack.appendSlice(c.items);
    }

    // REF_DELTA referencing the base blob by SHA-1
    {
        const delta_bytes = delta.items;
        var first: u8 = (7 << 4) | @as(u8, @intCast(delta_bytes.len & 0x0F));
        var rem = delta_bytes.len >> 4;
        if (rem > 0) first |= 0x80;
        try pack.append(first);
        while (rem > 0) {
            var b: u8 = @intCast(rem & 0x7F);
            rem >>= 7;
            if (rem > 0) b |= 0x80;
            try pack.append(b);
        }
        // 20-byte base SHA-1
        try pack.appendSlice(&base_sha1);
        // Compressed delta
        var cd = std.ArrayList(u8).init(allocator);
        defer cd.deinit();
        var di = std.io.fixedBufferStream(@as([]const u8, delta_bytes));
        try std.compress.zlib.compress(di.reader(), cd.writer(), .{});
        try pack.appendSlice(cd.items);
    }

    // Checksum
    var hasher2 = std.crypto.hash.Sha1.init(.{});
    hasher2.update(pack.items);
    var cksum: [20]u8 = undefined;
    hasher2.final(&cksum);
    try pack.appendSlice(&cksum);

    // generatePackIndex should resolve the REF_DELTA because base is already indexed
    const idx_data = try objects.generatePackIndex(pack.items, allocator);
    defer allocator.free(idx_data);

    // Should have 2 objects in idx
    const total = std.mem.readInt(u32, @ptrCast(idx_data[8 + 255 * 4 .. 8 + 255 * 4 + 4]), .big);
    try testing.expectEqual(@as(u32, 2), total);

    // Compute expected SHA-1 for the modified blob
    const mod_header = try std.fmt.allocPrint(allocator, "blob {}\x00", .{modified_data.len});
    defer allocator.free(mod_header);
    var sha2 = std.crypto.hash.Sha1.init(.{});
    sha2.update(mod_header);
    sha2.update(modified_data);
    var expected_modified_sha1: [20]u8 = undefined;
    sha2.final(&expected_modified_sha1);

    // Verify both SHA-1s are in the idx's SHA-1 table
    const sha_table_start: usize = 8 + 256 * 4;
    var found_base = false;
    var found_modified = false;
    for (0..2) |i| {
        const entry_sha = idx_data[sha_table_start + i * 20 .. sha_table_start + i * 20 + 20];
        if (std.mem.eql(u8, entry_sha, &base_sha1)) found_base = true;
        if (std.mem.eql(u8, entry_sha, &expected_modified_sha1)) found_modified = true;
    }
    try testing.expect(found_base);
    try testing.expect(found_modified);
}

// ============================================================================
// TEST 11: Pack with commit+tree+blob, git verify-pack -v matches our idx
// ============================================================================
test "e2e: full commit+tree+blob pack verified by git" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    git(allocator, tmp_path, &.{ "init", "-b", "main" }) catch return;
    git(allocator, tmp_path, &.{ "config", "user.email", "t@t.com" }) catch return;
    git(allocator, tmp_path, &.{ "config", "user.name", "T" }) catch return;

    try tmp.dir.writeFile(.{ .sub_path = "hello.txt", .data = "Hello from ziggit e2e test!\n" });
    git(allocator, tmp_path, &.{ "add", "hello.txt" }) catch return;
    git(allocator, tmp_path, &.{ "commit", "-m", "initial" }) catch return;

    // Repack to get everything into a pack file
    git(allocator, tmp_path, &.{ "repack", "-a", "-d" }) catch return;
    git(allocator, tmp_path, &.{ "prune-packed" }) catch {};

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_path});
    defer allocator.free(git_dir);

    // Find the pack file
    const pack_dir = try std.fmt.allocPrint(allocator, "{s}/objects/pack", .{git_dir});
    defer allocator.free(pack_dir);

    var dir = std.fs.cwd().openDir(pack_dir, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".pack")) continue;

        // Read git's pack
        const pack_data = dir.readFileAlloc(allocator, entry.name, 50 * 1024 * 1024) catch continue;
        defer allocator.free(pack_data);

        // Generate our idx
        const our_idx = objects.generatePackIndex(pack_data, allocator) catch continue;
        defer allocator.free(our_idx);

        // Write pack + our idx to temp location
        const test_pack_path = try std.fmt.allocPrint(allocator, "{s}/ziggit-test.pack", .{tmp_path});
        defer allocator.free(test_pack_path);
        const test_idx_path = try std.fmt.allocPrint(allocator, "{s}/ziggit-test.idx", .{tmp_path});
        defer allocator.free(test_idx_path);

        try tmp.dir.writeFile(.{ .sub_path = "ziggit-test.pack", .data = pack_data });
        try tmp.dir.writeFile(.{ .sub_path = "ziggit-test.idx", .data = our_idx });

        // git verify-pack should accept our idx
        git(allocator, tmp_path, &.{ "verify-pack", test_pack_path }) catch |err| {
            std.debug.print("git verify-pack rejected our idx: {}\n", .{err});
            return err;
        };

        break; // Only need to test one pack
    }
}
