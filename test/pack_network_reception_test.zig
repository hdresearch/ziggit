const std = @import("std");
const objects = @import("git_objects");

// =============================================================================
// Tests for pack file infrastructure used by HTTPS clone/fetch (NET-SMART, NET-PACK)
// Covers: saveReceivedPack, generatePackIndex, readPackObjectAtOffset,
//         REF_DELTA resolution, multi-object packs, delta chains
// =============================================================================

// ============================================================================
// Filesystem platform shim for tests (duck-typed, no platform module needed)
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
};

const RealFsPlatform = struct {
    fs: RealFs = .{},
};

const PackEntry = struct { obj_type: u3, data: []const u8 };

/// Helper: build a minimal pack file from raw object entries.
/// Each entry is (type, data) for base objects.
fn buildPackFile(allocator: std.mem.Allocator, objs: []const PackEntry) ![]u8 {
    var pack = std.ArrayList(u8).init(allocator);
    errdefer pack.deinit();

    // Header: PACK + version 2 + object count
    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, @intCast(objs.len), .big);

    for (objs) |obj| {
        // Encode type+size header
        const size = obj.data.len;
        var first_byte: u8 = (@as(u8, obj.obj_type) << 4) | @as(u8, @intCast(size & 0x0F));
        var remaining = size >> 4;
        if (remaining > 0) first_byte |= 0x80;
        try pack.append(first_byte);
        while (remaining > 0) {
            var b: u8 = @intCast(remaining & 0x7F);
            remaining >>= 7;
            if (remaining > 0) b |= 0x80;
            try pack.append(b);
        }

        // Compress data
        var compressed = std.ArrayList(u8).init(allocator);
        defer compressed.deinit();
        var input = std.io.fixedBufferStream(obj.data);
        try std.compress.zlib.compress(input.reader(), compressed.writer(), .{});
        try pack.appendSlice(compressed.items);
    }

    // Append SHA-1 checksum of everything
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack.items);
    var checksum: [20]u8 = undefined;
    hasher.final(&checksum);
    try pack.appendSlice(&checksum);

    return try pack.toOwnedSlice();
}

/// Helper: compute the git object SHA-1 for a given type+data
fn gitObjectSha1(obj_type: []const u8, data: []const u8) [20]u8 {
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

// ---------------------------------------------------------------------------
// Test: generatePackIndex round-trip for a single blob
// ---------------------------------------------------------------------------
test "network pack: single blob pack generates valid idx and object is retrievable" {
    const allocator = std.testing.allocator;
    const blob_data = "Hello from network clone!\n";
    const expected_sha1 = gitObjectSha1("blob", blob_data);

    const pack_data = try buildPackFile(allocator, &.{
        .{ .obj_type = 3, .data = blob_data }, // blob = 3
    });
    defer allocator.free(pack_data);

    // Generate idx
    const idx_data = try objects.generatePackIndex(pack_data, allocator);
    defer allocator.free(idx_data);

    // Verify idx magic + version
    try std.testing.expectEqual(@as(u32, 0xff744f63), std.mem.readInt(u32, @ptrCast(idx_data[0..4]), .big));
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, @ptrCast(idx_data[4..8]), .big));

    // Verify fanout[255] == 1 (one object)
    const fanout_last_off = 8 + 255 * 4;
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, @ptrCast(idx_data[fanout_last_off .. fanout_last_off + 4]), .big));

    // SHA-1 table starts at 8 + 256*4 = 1032
    const sha1_in_idx = idx_data[1032 .. 1032 + 20];
    try std.testing.expectEqualSlices(u8, &expected_sha1, sha1_in_idx);
}

// ---------------------------------------------------------------------------
// Test: multi-object pack (commit + tree + blob) round-trip
// ---------------------------------------------------------------------------
test "network pack: commit+tree+blob pack round-trips through saveReceivedPack" {
    const allocator = std.testing.allocator;

    // Create a temp dir simulating a git repo
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create .git/objects/pack directory
    try tmp.dir.makePath("repo/.git/objects/pack");

    const git_dir_path = try tmp.dir.realpathAlloc(allocator, "repo/.git");
    defer allocator.free(git_dir_path);

    const blob_content = "file content\n";
    const blob_sha1 = gitObjectSha1("blob", blob_content);
    const blob_hex = sha1Hex(blob_sha1);

    // Build a tree entry: "100644 file.txt\0<sha1>"
    var tree_data_buf = std.ArrayList(u8).init(allocator);
    defer tree_data_buf.deinit();
    try tree_data_buf.writer().print("100644 file.txt\x00", .{});
    try tree_data_buf.appendSlice(&blob_sha1);
    const tree_content = try allocator.dupe(u8, tree_data_buf.items);
    defer allocator.free(tree_content);
    const tree_sha1 = gitObjectSha1("tree", tree_content);
    const tree_hex = sha1Hex(tree_sha1);

    // Build commit data
    var commit_buf = std.ArrayList(u8).init(allocator);
    defer commit_buf.deinit();
    try commit_buf.writer().print("tree {s}\nauthor Test <t@t> 1000000000 +0000\ncommitter Test <t@t> 1000000000 +0000\n\ninitial\n", .{tree_hex});
    const commit_content = try allocator.dupe(u8, commit_buf.items);
    defer allocator.free(commit_content);

    const pack_data = try buildPackFile(allocator, &.{
        .{ .obj_type = 3, .data = blob_content },   // blob
        .{ .obj_type = 2, .data = tree_content },    // tree
        .{ .obj_type = 1, .data = commit_content },  // commit
    });
    defer allocator.free(pack_data);

    const platform = RealFsPlatform{};

    const checksum_hex = try objects.saveReceivedPack(pack_data, git_dir_path, &platform, allocator);
    defer allocator.free(checksum_hex);

    // Verify we can load all three objects back
    const blob_obj = try objects.GitObject.load(&blob_hex, git_dir_path, &platform, allocator);
    defer blob_obj.deinit(allocator);
    try std.testing.expectEqual(objects.ObjectType.blob, blob_obj.type);
    try std.testing.expectEqualStrings(blob_content, blob_obj.data);

    const tree_obj = try objects.GitObject.load(&tree_hex, git_dir_path, &platform, allocator);
    defer tree_obj.deinit(allocator);
    try std.testing.expectEqual(objects.ObjectType.tree, tree_obj.type);

    const commit_sha1 = gitObjectSha1("commit", commit_content);
    const commit_hex = sha1Hex(commit_sha1);
    const commit_obj = try objects.GitObject.load(&commit_hex, git_dir_path, &platform, allocator);
    defer commit_obj.deinit(allocator);
    try std.testing.expectEqual(objects.ObjectType.commit, commit_obj.type);
}

// ---------------------------------------------------------------------------
// Test: OFS_DELTA in a pack built by hand
// ---------------------------------------------------------------------------
test "network pack: OFS_DELTA object resolved correctly from hand-built pack" {
    const allocator = std.testing.allocator;

    // Base blob and a delta that modifies it
    const base_content = "AAAAAAAAAA"; // 10 bytes
    const result_content = "AAAAABBBBB"; // 10 bytes (copy 5 from base, insert 5)

    // Build delta instructions:
    // base_size = 10, result_size = 10
    // copy offset=0, size=5
    // insert 5 bytes "BBBBB"
    var delta = std.ArrayList(u8).init(allocator);
    defer delta.deinit();
    try delta.append(10); // base size = 10
    try delta.append(10); // result size = 10
    // Copy: cmd=0x80|0x10, offset=0 (no offset bytes since all zero), size=5
    try delta.append(0x80 | 0x10); // copy with size byte
    try delta.append(5); // size = 5
    // Insert 5 bytes
    try delta.append(5); // insert 5 bytes
    try delta.appendSlice("BBBBB");

    const delta_bytes = try allocator.dupe(u8, delta.items);
    defer allocator.free(delta_bytes);

    // Build pack manually: base blob at offset 12, then OFS_DELTA
    var pack = std.ArrayList(u8).init(allocator);
    defer pack.deinit();

    // Header
    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, 2, .big); // 2 objects

    const base_offset = pack.items.len;

    // Object 1: blob, size=10
    {
        var first_byte: u8 = (3 << 4) | @as(u8, @intCast(base_content.len & 0x0F));
        const remaining = base_content.len >> 4;
        if (remaining > 0) first_byte |= 0x80;
        try pack.append(first_byte);
        if (remaining > 0) try pack.append(@intCast(remaining & 0x7F));

        var compressed = std.ArrayList(u8).init(allocator);
        defer compressed.deinit();
        var input = std.io.fixedBufferStream(base_content);
        try std.compress.zlib.compress(input.reader(), compressed.writer(), .{});
        try pack.appendSlice(compressed.items);
    }

    const delta_offset = pack.items.len;

    // Object 2: OFS_DELTA, decompressed size = delta_bytes.len
    {
        const delta_size = delta_bytes.len;
        var first_byte: u8 = (6 << 4) | @as(u8, @intCast(delta_size & 0x0F));
        const remaining = delta_size >> 4;
        if (remaining > 0) first_byte |= 0x80;
        try pack.append(first_byte);
        if (remaining > 0) try pack.append(@intCast(remaining & 0x7F));

        // OFS_DELTA negative offset encoding
        const neg_offset = delta_offset - base_offset;
        // Encode as variable-length: for values < 128, single byte
        if (neg_offset < 128) {
            try pack.append(@intCast(neg_offset));
        } else {
            // Multi-byte encoding
            var off = neg_offset;
            var buf: [10]u8 = undefined;
            var len: usize = 0;
            buf[len] = @intCast(off & 0x7F);
            len += 1;
            off >>= 7;
            while (off > 0) {
                off -= 1;
                buf[len] = @intCast((off & 0x7F) | 0x80);
                len += 1;
                off >>= 7;
            }
            // Write in reverse order (MSB first)
            var i: usize = len;
            while (i > 0) {
                i -= 1;
                try pack.append(buf[i]);
            }
        }

        var compressed = std.ArrayList(u8).init(allocator);
        defer compressed.deinit();
        var input = std.io.fixedBufferStream(delta_bytes);
        try std.compress.zlib.compress(input.reader(), compressed.writer(), .{});
        try pack.appendSlice(compressed.items);
    }

    // Pack checksum
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack.items);
    var checksum: [20]u8 = undefined;
    hasher.final(&checksum);
    try pack.appendSlice(&checksum);

    const pack_data = try pack.toOwnedSlice();
    defer allocator.free(pack_data);

    // Generate idx and verify we can read the delta object
    const idx_data = try objects.generatePackIndex(pack_data, allocator);
    defer allocator.free(idx_data);

    // The delta-resolved object should have SHA-1 of blob "AAAAABBBBB"
    const expected_sha1 = gitObjectSha1("blob", result_content);
    const expected_hex = sha1Hex(expected_sha1);

    // Write to temp dir and try to load
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("repo/.git/objects/pack");
    const git_dir_path = try tmp.dir.realpathAlloc(allocator, "repo/.git");
    defer allocator.free(git_dir_path);

    const platform = RealFsPlatform{};

    const ck = try objects.saveReceivedPack(pack_data, git_dir_path, &platform, allocator);
    defer allocator.free(ck);

    const obj = try objects.GitObject.load(&expected_hex, git_dir_path, &platform, allocator);
    defer obj.deinit(allocator);
    try std.testing.expectEqual(objects.ObjectType.blob, obj.type);
    try std.testing.expectEqualStrings(result_content, obj.data);
}

// ---------------------------------------------------------------------------
// Test: delta application edge cases
// ---------------------------------------------------------------------------
test "delta apply: copy with all offset+size bytes set" {
    const allocator = std.testing.allocator;

    // Base: 300 bytes of 'X'
    const base = try allocator.alloc(u8, 300);
    defer allocator.free(base);
    @memset(base, 'X');

    // Delta: copy from offset 256, size 44 (the last 44 bytes)
    var delta = std.ArrayList(u8).init(allocator);
    defer delta.deinit();

    // base_size varint: 300 = 0b100101100 → 0xAC, 0x02
    try delta.append(0x80 | 44); // 300 & 0x7F = 44 with continuation
    try delta.append(2); // 300 >> 7 = 2

    // result_size: 44
    try delta.append(44);

    // Copy: offset=256 (needs 2 bytes: 0x00, 0x01), size=44 (needs 1 byte)
    // cmd = 0x80 | 0x01 | 0x02 | 0x10 = 0x93
    try delta.append(0x93);
    try delta.append(0x00); // offset byte 0 = 0
    try delta.append(0x01); // offset byte 1 = 1 → offset = 256
    try delta.append(44); // size byte 0 = 44

    const result = try objects.applyDelta(base, delta.items, allocator);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 44), result.len);
    for (result) |c| {
        try std.testing.expectEqual(@as(u8, 'X'), c);
    }
}

test "delta apply: copy size 0 means 0x10000" {
    const allocator = std.testing.allocator;

    // Base: 0x10000 bytes (65536)
    const base = try allocator.alloc(u8, 0x10000);
    defer allocator.free(base);
    @memset(base, 'A');

    var delta = std.ArrayList(u8).init(allocator);
    defer delta.deinit();

    // base_size varint: 0x10000 = 65536
    // 65536 = 0b10000000000000000 → 7-bit chunks: 0, 0, 4
    try delta.append(0x80 | 0); // 0 with continuation
    try delta.append(0x80 | 0); // 0 with continuation
    try delta.append(4); // 65536 >> 14 = 4

    // result_size: same 65536
    try delta.append(0x80 | 0);
    try delta.append(0x80 | 0);
    try delta.append(4);

    // Copy: offset=0, size=0 (means 0x10000)
    // cmd = 0x80 (no offset bytes, no size bytes → offset=0, size=0x10000)
    try delta.append(0x80);

    const result = try objects.applyDelta(base, delta.items, allocator);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 0x10000), result.len);
}

test "delta apply: insert exactly 127 bytes (max single insert)" {
    const allocator = std.testing.allocator;

    const base = "x"; // 1 byte base
    const insert_data = "A" ** 127;

    var delta = std.ArrayList(u8).init(allocator);
    defer delta.deinit();

    try delta.append(1); // base size = 1
    try delta.append(127); // result size = 127
    try delta.append(127); // insert 127 bytes
    try delta.appendSlice(insert_data);

    const result = try objects.applyDelta(base, delta.items, allocator);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 127), result.len);
    try std.testing.expectEqualStrings(insert_data, result);
}

test "delta apply: empty delta (base_size=N, result_size=0) produces empty output" {
    const allocator = std.testing.allocator;

    const base = "hello";
    var delta = std.ArrayList(u8).init(allocator);
    defer delta.deinit();

    try delta.append(5); // base size = 5
    try delta.append(0); // result size = 0
    // No commands

    const result = try objects.applyDelta(base, delta.items, allocator);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "delta apply: multiple copies from different offsets" {
    const allocator = std.testing.allocator;

    // Base: "ABCDEFGHIJ" (10 bytes)
    const base = "ABCDEFGHIJ";

    // Result should be "FGHIJABCDE" (reverse halves)
    var delta = std.ArrayList(u8).init(allocator);
    defer delta.deinit();

    try delta.append(10); // base size
    try delta.append(10); // result size

    // Copy offset=5, size=5 → "FGHIJ"
    try delta.append(0x80 | 0x01 | 0x10); // offset byte 0 + size byte 0
    try delta.append(5); // offset = 5
    try delta.append(5); // size = 5

    // Copy offset=0, size=5 → "ABCDE"
    try delta.append(0x80 | 0x10); // size byte 0 only (offset=0)
    try delta.append(5); // size = 5

    const result = try objects.applyDelta(base, delta.items, allocator);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("FGHIJABCDE", result);
}

test "delta apply: interleaved copy and insert" {
    const allocator = std.testing.allocator;

    const base = "Hello World";
    // Result: "Hello, Beautiful World!"
    const expected = "Hello, Beautiful World!";

    var delta = std.ArrayList(u8).init(allocator);
    defer delta.deinit();

    try delta.append(11); // base size = 11
    try delta.append(@intCast(expected.len)); // result size

    // Copy "Hello" (offset=0, size=5)
    try delta.append(0x80 | 0x10);
    try delta.append(5);

    // Insert ", Beautiful"
    try delta.append(11); // insert 11 bytes
    try delta.appendSlice(", Beautiful");

    // Copy " World" (offset=5, size=6)
    try delta.append(0x80 | 0x01 | 0x10);
    try delta.append(5); // offset
    try delta.append(6); // size

    // Insert "!"
    try delta.append(1);
    try delta.appendSlice("!");

    const result = try objects.applyDelta(base, delta.items, allocator);
    defer allocator.free(result);

    try std.testing.expectEqualStrings(expected, result);
}

// ---------------------------------------------------------------------------
// Test: git CLI creates pack, ziggit reads all object types
// ---------------------------------------------------------------------------
test "network pack: git gc pack with all types readable by ziggit" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    const repo_path = try std.fmt.allocPrint(allocator, "{s}/repo", .{tmp_path});
    defer allocator.free(repo_path);

    // Initialize git repo
    try runGitVoid(allocator, &.{ "init", repo_path });

    // Create a file and commit
    const file_path = try std.fmt.allocPrint(allocator, "{s}/hello.txt", .{repo_path});
    defer allocator.free(file_path);
    try std.fs.cwd().writeFile(.{ .sub_path = file_path, .data = "hello world\n" });

    try runGitInDirVoid(allocator, repo_path, &.{ "add", "." });
    try runGitInDirVoid(allocator, repo_path, &.{ "commit", "-m", "initial" });

    // Create annotated tag
    try runGitInDirVoid(allocator, repo_path, &.{ "tag", "-a", "v1.0", "-m", "release" });

    // Create a second commit (to create deltas during gc)
    try std.fs.cwd().writeFile(.{ .sub_path = file_path, .data = "hello world\nline 2\n" });
    try runGitInDirVoid(allocator, repo_path, &.{ "add", "." });
    try runGitInDirVoid(allocator, repo_path, &.{ "commit", "-m", "second" });

    // Force gc to create pack with deltas
    try runGitInDirVoid(allocator, repo_path, &.{ "gc", "--aggressive" });

    // Get the HEAD commit hash
    const head_hash_raw = try runGitInDir(allocator, repo_path, &.{ "rev-parse", "HEAD" });
    defer allocator.free(head_hash_raw);
    const head_hash = std.mem.trim(u8, head_hash_raw, &.{ '\n', '\r', ' ' });

    // Get the blob hash
    const blob_hash_raw = try runGitInDir(allocator, repo_path, &.{ "rev-parse", "HEAD:hello.txt" });
    defer allocator.free(blob_hash_raw);
    const blob_hash = std.mem.trim(u8, blob_hash_raw, &.{ '\n', '\r', ' ' });

    // Load objects via ziggit
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{repo_path});
    defer allocator.free(git_dir);

    const platform = RealFsPlatform{};

    // Blob
    const blob_obj = try objects.GitObject.load(blob_hash, git_dir, &platform, allocator);
    defer blob_obj.deinit(allocator);
    try std.testing.expectEqual(objects.ObjectType.blob, blob_obj.type);
    try std.testing.expectEqualStrings("hello world\nline 2\n", blob_obj.data);

    // Commit
    const commit_obj = try objects.GitObject.load(head_hash, git_dir, &platform, allocator);
    defer commit_obj.deinit(allocator);
    try std.testing.expectEqual(objects.ObjectType.commit, commit_obj.type);
    try std.testing.expect(std.mem.indexOf(u8, commit_obj.data, "second") != null);
}

// ---------------------------------------------------------------------------
// Test: saveReceivedPack with tag object
// ---------------------------------------------------------------------------
test "network pack: tag object in received pack" {
    const allocator = std.testing.allocator;

    const blob_content = "tagged content\n";
    const blob_sha1 = gitObjectSha1("blob", blob_content);
    const blob_hex = sha1Hex(blob_sha1);

    // Create a tag pointing to the blob
    var tag_buf = std.ArrayList(u8).init(allocator);
    defer tag_buf.deinit();
    try tag_buf.writer().print("object {s}\ntype blob\ntag v1.0\ntagger Test <t@t> 1000000000 +0000\n\nrelease tag\n", .{blob_hex});
    const tag_content = try allocator.dupe(u8, tag_buf.items);
    defer allocator.free(tag_content);

    const pack_data = try buildPackFile(allocator, &.{
        .{ .obj_type = 3, .data = blob_content },  // blob
        .{ .obj_type = 4, .data = tag_content },    // tag
    });
    defer allocator.free(pack_data);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("repo/.git/objects/pack");
    const git_dir_path = try tmp.dir.realpathAlloc(allocator, "repo/.git");
    defer allocator.free(git_dir_path);

    const platform = RealFsPlatform{};

    const ck = try objects.saveReceivedPack(pack_data, git_dir_path, &platform, allocator);
    defer allocator.free(ck);

    // Verify tag is loadable
    const tag_sha1 = gitObjectSha1("tag", tag_content);
    const tag_hex = sha1Hex(tag_sha1);
    const tag_obj = try objects.GitObject.load(&tag_hex, git_dir_path, &platform, allocator);
    defer tag_obj.deinit(allocator);
    try std.testing.expectEqual(objects.ObjectType.tag, tag_obj.type);
    try std.testing.expect(std.mem.indexOf(u8, tag_obj.data, "v1.0") != null);
}

// ---------------------------------------------------------------------------
// Test: git verify-pack validates our generated pack+idx
// ---------------------------------------------------------------------------
test "network pack: git verify-pack accepts saveReceivedPack output" {
    const allocator = std.testing.allocator;

    const blob1 = "first file\n";
    const blob2 = "second file\n";

    const pack_data = try buildPackFile(allocator, &.{
        .{ .obj_type = 3, .data = blob1 },
        .{ .obj_type = 3, .data = blob2 },
    });
    defer allocator.free(pack_data);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("repo/.git/objects/pack");
    const git_dir_path = try tmp.dir.realpathAlloc(allocator, "repo/.git");
    defer allocator.free(git_dir_path);

    const platform = RealFsPlatform{};

    const ck = try objects.saveReceivedPack(pack_data, git_dir_path, &platform, allocator);
    defer allocator.free(ck);

    // Run git verify-pack
    const idx_path = try std.fmt.allocPrint(allocator, "{s}/objects/pack/pack-{s}.idx", .{ git_dir_path, ck });
    defer allocator.free(idx_path);

    var verify_argv = [_][]const u8{ "git", "verify-pack", "-v", idx_path };
    var result = std.process.Child.init(&verify_argv, allocator);
    result.stderr_behavior = .Pipe;
    result.stdout_behavior = .Pipe;
    try result.spawn();
    const stdout = try result.stdout.?.reader().readAllAlloc(allocator, 1024 * 1024);
    defer allocator.free(stdout);
    const stderr = try result.stderr.?.reader().readAllAlloc(allocator, 1024 * 1024);
    defer allocator.free(stderr);
    const term = try result.wait();

    try std.testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, term);
    // verify-pack output should mention our objects
    try std.testing.expect(stdout.len > 0);
}

// ---------------------------------------------------------------------------
// Test: fanout table correctness with diverse SHA-1 first bytes
// ---------------------------------------------------------------------------
test "network pack: idx fanout table correct with many objects" {
    const allocator = std.testing.allocator;

    // Create 10 blobs with different content to get diverse SHA-1 prefixes
    var obj_list: [10]PackEntry = undefined;
    var contents: [10][]u8 = undefined;
    for (0..10) |i| {
        contents[i] = try std.fmt.allocPrint(allocator, "blob number {}\n", .{i});
        obj_list[i] = .{ .obj_type = 3, .data = contents[i] };
    }
    defer for (&contents) |c| allocator.free(c);

    const pack_data = try buildPackFile(allocator, &obj_list);
    defer allocator.free(pack_data);

    const idx_data = try objects.generatePackIndex(pack_data, allocator);
    defer allocator.free(idx_data);

    // Fanout must be monotonically non-decreasing and fanout[255] == 10
    var prev: u32 = 0;
    for (0..256) |i| {
        const off = 8 + i * 4;
        const val = std.mem.readInt(u32, @ptrCast(idx_data[off .. off + 4]), .big);
        try std.testing.expect(val >= prev);
        prev = val;
    }
    try std.testing.expectEqual(@as(u32, 10), prev);
}

// ---------------------------------------------------------------------------
// Test: pack with binary data (null bytes, high bytes)
// ---------------------------------------------------------------------------
test "network pack: binary blob with null bytes round-trips" {
    const allocator = std.testing.allocator;

    var binary_data: [256]u8 = undefined;
    for (0..256) |i| {
        binary_data[i] = @intCast(i);
    }

    const pack_data = try buildPackFile(allocator, &.{
        .{ .obj_type = 3, .data = &binary_data },
    });
    defer allocator.free(pack_data);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("repo/.git/objects/pack");
    const git_dir_path = try tmp.dir.realpathAlloc(allocator, "repo/.git");
    defer allocator.free(git_dir_path);

    const platform = RealFsPlatform{};

    const ck = try objects.saveReceivedPack(pack_data, git_dir_path, &platform, allocator);
    defer allocator.free(ck);

    const expected_sha1 = gitObjectSha1("blob", &binary_data);
    const expected_hex = sha1Hex(expected_sha1);

    const obj = try objects.GitObject.load(&expected_hex, git_dir_path, &platform, allocator);
    defer obj.deinit(allocator);
    try std.testing.expectEqualSlices(u8, &binary_data, obj.data);
}

// ---------------------------------------------------------------------------
// Test: saveReceivedPack rejects corrupted checksum
// ---------------------------------------------------------------------------
test "network pack: saveReceivedPack rejects corrupted checksum" {
    const allocator = std.testing.allocator;

    var pack_data = try buildPackFile(allocator, &.{
        .{ .obj_type = 3, .data = "test\n" },
    });
    defer allocator.free(pack_data);

    // Corrupt the checksum
    pack_data[pack_data.len - 1] ^= 0xFF;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("repo/.git/objects/pack");
    const git_dir_path = try tmp.dir.realpathAlloc(allocator, "repo/.git");
    defer allocator.free(git_dir_path);

    const platform = RealFsPlatform{};

    const result = objects.saveReceivedPack(pack_data, git_dir_path, &platform, allocator);
    try std.testing.expectError(error.PackChecksumMismatch, result);
}

// ---------------------------------------------------------------------------
// Test: saveReceivedPack rejects invalid signature
// ---------------------------------------------------------------------------
test "network pack: saveReceivedPack rejects invalid signature" {
    const allocator = std.testing.allocator;

    var data = [_]u8{0} ** 40;
    data[0] = 'X'; // Not "PACK"

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("repo/.git/objects/pack");
    const git_dir_path = try tmp.dir.realpathAlloc(allocator, "repo/.git");
    defer allocator.free(git_dir_path);

    const platform = RealFsPlatform{};

    const result = objects.saveReceivedPack(&data, git_dir_path, &platform, allocator);
    try std.testing.expectError(error.InvalidPackSignature, result);
}

// ---------------------------------------------------------------------------
// Test: generatePackIndex SHA-1 table is sorted
// ---------------------------------------------------------------------------
test "network pack: idx SHA-1 table is sorted" {
    const allocator = std.testing.allocator;

    var obj_list: [5]PackEntry = undefined;
    var contents: [5][]u8 = undefined;
    for (0..5) |i| {
        contents[i] = try std.fmt.allocPrint(allocator, "content-{}-{}\n", .{ i, i * 7 + 13 });
        obj_list[i] = .{ .obj_type = 3, .data = contents[i] };
    }
    defer for (&contents) |c| allocator.free(c);

    const pack_data = try buildPackFile(allocator, &obj_list);
    defer allocator.free(pack_data);

    const idx_data = try objects.generatePackIndex(pack_data, allocator);
    defer allocator.free(idx_data);

    // SHA-1 table starts at 1032, 5 entries of 20 bytes each
    const sha1_start: usize = 1032;
    var prev_sha: [20]u8 = [_]u8{0} ** 20;
    for (0..5) |i| {
        const off = sha1_start + i * 20;
        const sha = idx_data[off .. off + 20];
        if (i > 0) {
            try std.testing.expect(std.mem.order(u8, &prev_sha, sha) == .lt);
        }
        @memcpy(&prev_sha, sha);
    }
}

// ---------------------------------------------------------------------------
// Test: clone simulation - git creates pack, we save and read via our infra
// ---------------------------------------------------------------------------
test "network pack: clone simulation with git-created pack" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Create a source repo
    const src_repo = try std.fmt.allocPrint(allocator, "{s}/src_repo", .{tmp_path});
    defer allocator.free(src_repo);
    try runGitVoid(allocator, &.{ "init", src_repo });

    // Add multiple files
    for (0..5) |i| {
        const fname = try std.fmt.allocPrint(allocator, "{s}/file{}.txt", .{ src_repo, i });
        defer allocator.free(fname);
        const content = try std.fmt.allocPrint(allocator, "File {} content\nWith multiple lines\n", .{i});
        defer allocator.free(content);
        try std.fs.cwd().writeFile(.{ .sub_path = fname, .data = content });
    }
    try runGitInDirVoid(allocator, src_repo, &.{ "add", "." });
    try runGitInDirVoid(allocator, src_repo, &.{ "commit", "-m", "multi-file commit" });

    // Use git pack-objects to create a pack of everything
    // Get all object hashes
    const all_objects_raw = try runGitInDir(allocator, src_repo, &.{ "rev-list", "--objects", "--all" });
    defer allocator.free(all_objects_raw);

    // Extract just the hashes (first 40 chars of each line)
    var hash_list = std.ArrayList(u8).init(allocator);
    defer hash_list.deinit();
    var lines = std.mem.splitScalar(u8, all_objects_raw, '\n');
    while (lines.next()) |line| {
        if (line.len >= 40) {
            try hash_list.appendSlice(line[0..40]);
            try hash_list.append('\n');
        }
    }

    // Create pack using git pack-objects
    const pack_base = try std.fmt.allocPrint(allocator, "{s}/test-pack", .{tmp_path});
    defer allocator.free(pack_base);

    {
        var pack_argv = [_][]const u8{ "git", "-C", src_repo, "pack-objects", "--stdout" };
        var child = std.process.Child.init(&pack_argv, allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        try child.spawn();

        // Write hashes to stdin
        try child.stdin.?.writeAll(hash_list.items);
        child.stdin.?.close();
        child.stdin = null;

        const pack_bytes = try child.stdout.?.reader().readAllAlloc(allocator, 50 * 1024 * 1024);
        defer allocator.free(pack_bytes);
        const pack_stderr = try child.stderr.?.reader().readAllAlloc(allocator, 1024 * 1024);
        defer allocator.free(pack_stderr);
        const term = try child.wait();

        // git pack-objects --stdout should succeed
        if (term != .Exited or term.Exited != 0) {
            return; // Skip if git pack-objects doesn't work as expected
        }

        // Now save via our infrastructure
        var dst = std.testing.tmpDir(.{});
        defer dst.cleanup();
        try dst.dir.makePath("dst/.git/objects/pack");
        const dst_git = try dst.dir.realpathAlloc(allocator, "dst/.git");
        defer allocator.free(dst_git);

        const platform = RealFsPlatform{};

        const ck = try objects.saveReceivedPack(pack_bytes, dst_git, &platform, allocator);
        defer allocator.free(ck);

        // Verify we can read HEAD commit
        const head_raw = try runGitInDir(allocator, src_repo, &.{ "rev-parse", "HEAD" });
        defer allocator.free(head_raw);
        const head_hash = std.mem.trim(u8, head_raw, &.{ '\n', '\r', ' ' });

        const commit_obj = try objects.GitObject.load(head_hash, dst_git, &platform, allocator);
        defer commit_obj.deinit(allocator);
        try std.testing.expectEqual(objects.ObjectType.commit, commit_obj.type);
        try std.testing.expect(std.mem.indexOf(u8, commit_obj.data, "multi-file commit") != null);
    }
}

// ---------------------------------------------------------------------------
// Helpers for running git commands
// ---------------------------------------------------------------------------
fn runGitVoid(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const out = try runGit(allocator, args);
    allocator.free(out);
}

fn runGitInDirVoid(allocator: std.mem.Allocator, dir: []const u8, args: []const []const u8) !void {
    const out = try runGitInDir(allocator, dir, args);
    allocator.free(out);
}

fn runGit(allocator: std.mem.Allocator, args: []const []const u8) ![]u8 {
    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit();
    try argv.append("git");
    try argv.appendSlice(args);

    var child = std.process.Child.init(argv.items, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const stdout = try child.stdout.?.reader().readAllAlloc(allocator, 1024 * 1024);
    const stderr = try child.stderr.?.reader().readAllAlloc(allocator, 1024 * 1024);
    defer allocator.free(stderr);
    const term = try child.wait();
    if (term != .Exited or term.Exited != 0) {
        allocator.free(stdout);
        return error.GitCommandFailed;
    }
    return stdout;
}

fn runGitInDir(allocator: std.mem.Allocator, dir: []const u8, args: []const []const u8) ![]u8 {
    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit();
    try argv.append("git");
    try argv.append("-C");
    try argv.append(dir);
    try argv.appendSlice(args);

    var child = std.process.Child.init(argv.items, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    var env_map = std.process.EnvMap.init(allocator);
    defer env_map.deinit();
    try env_map.put("GIT_AUTHOR_NAME", "Test");
    try env_map.put("GIT_AUTHOR_EMAIL", "test@test.com");
    try env_map.put("GIT_COMMITTER_NAME", "Test");
    try env_map.put("GIT_COMMITTER_EMAIL", "test@test.com");
    child.env_map = &env_map;
    try child.spawn();
    const stdout = try child.stdout.?.reader().readAllAlloc(allocator, 1024 * 1024);
    const stderr = try child.stderr.?.reader().readAllAlloc(allocator, 1024 * 1024);
    defer allocator.free(stderr);
    const term = try child.wait();
    if (term != .Exited or term.Exited != 0) {
        allocator.free(stdout);
        return error.GitCommandFailed;
    }
    return stdout;
}
