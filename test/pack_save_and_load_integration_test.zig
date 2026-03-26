const std = @import("std");
const testing = std.testing;
const objects = @import("git_objects");

// ============================================================================
// PACK SAVE AND LOAD INTEGRATION TESTS
//
// These tests verify the critical path for HTTPS clone/fetch:
//   1. Receive pack data (simulated)
//   2. saveReceivedPack writes .pack and .idx
//   3. GitObject.load resolves objects from pack files
//   4. All object types (blob, tree, commit, tag) survive round-trip
//   5. OFS_DELTA chains are resolved through GitObject.load
//   6. fixThinPack + saveReceivedPack for thin packs from fetch
//   7. git verify-pack validates our .pack+.idx combination
//
// These tests use real filesystem I/O and the git CLI for cross-validation.
// ============================================================================

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
            std.fs.cwd().makeDir(path) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }
    };
};

fn makeTmpDir(allocator: std.mem.Allocator) ![]u8 {
    const base = "/tmp/ziggit_pack_integration";
    std.fs.makeDirAbsolute(base) catch {};
    var buf: [64]u8 = undefined;
    const ts = std.time.milliTimestamp();
    var rng = std.Random.DefaultPrng.init(@bitCast(ts));
    const rand_val = rng.random().int(u64);
    const name = std.fmt.bufPrint(&buf, "t_{d}_{d}", .{ ts, rand_val }) catch unreachable;
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, name });
    std.fs.makeDirAbsolute(path) catch {};
    return path;
}

fn cleanupTmpDir(path: []const u8) void {
    std.fs.deleteTreeAbsolute(path) catch {};
}

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

/// SHA-1 of a git object: SHA1("{type} {size}\0{data}")
fn gitSha1(obj_type: []const u8, data: []const u8) [20]u8 {
    var hasher = std.crypto.hash.Sha1.init(.{});
    var hdr_buf: [64]u8 = undefined;
    const hdr = std.fmt.bufPrint(&hdr_buf, "{s} {}\x00", .{ obj_type, data.len }) catch unreachable;
    hasher.update(hdr);
    hasher.update(data);
    var out: [20]u8 = undefined;
    hasher.final(&out);
    return out;
}

fn sha1Hex(sha1: [20]u8) [40]u8 {
    var hex: [40]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{}", .{std.fmt.fmtSliceHexLower(&sha1)}) catch unreachable;
    return hex;
}

/// Build a pack object header
fn encodePackHeader(buf: []u8, obj_type: u3, size: usize) usize {
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

/// Zlib-compress data
fn zlibCompress(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var compressed = std.ArrayList(u8).init(allocator);
    defer compressed.deinit();
    var input = std.io.fixedBufferStream(data);
    try std.compress.zlib.compress(input.reader(), compressed.writer(), .{});
    return try allocator.dupe(u8, compressed.items);
}

/// Encode a delta varint
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

/// Build a complete pack file with objects, finalized with SHA-1 checksum
fn buildPack(allocator: std.mem.Allocator, pack_objects: []const PackObject) ![]u8 {
    var pack = std.ArrayList(u8).init(allocator);
    defer pack.deinit();

    // Header
    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, @intCast(pack_objects.len), .big);

    // Objects
    for (pack_objects) |obj| {
        try pack.appendSlice(obj.raw_data);
    }

    // Checksum
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack.items);
    var checksum: [20]u8 = undefined;
    hasher.final(&checksum);
    try pack.appendSlice(&checksum);

    return try allocator.dupe(u8, pack.items);
}

const PackObject = struct {
    raw_data: []const u8,
};

fn buildBaseObject(allocator: std.mem.Allocator, obj_type: u3, data: []const u8) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    var hdr: [10]u8 = undefined;
    const hdr_len = encodePackHeader(&hdr, obj_type, data.len);
    try buf.appendSlice(hdr[0..hdr_len]);

    const compressed = try zlibCompress(allocator, data);
    defer allocator.free(compressed);
    try buf.appendSlice(compressed);

    return try allocator.dupe(u8, buf.items);
}

// ============================================================================
// Test: saveReceivedPack + GitObject.load for blob
// ============================================================================
test "save pack with blob, load via GitObject.load" {
    const allocator = testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    // Create a minimal git repo structure
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp});
    defer allocator.free(git_dir);
    std.fs.makeDirAbsolute(git_dir) catch {};
    const objects_dir = try std.fmt.allocPrint(allocator, "{s}/objects", .{git_dir});
    defer allocator.free(objects_dir);
    std.fs.makeDirAbsolute(objects_dir) catch {};
    const pack_dir = try std.fmt.allocPrint(allocator, "{s}/pack", .{objects_dir});
    defer allocator.free(pack_dir);
    std.fs.makeDirAbsolute(pack_dir) catch {};

    // Build a pack with a single blob
    const blob_content = "Hello from pack integration test!\n";
    const blob_raw = try buildBaseObject(allocator, 3, blob_content);
    defer allocator.free(blob_raw);

    const pack_objs = [_]PackObject{.{ .raw_data = blob_raw }};
    const pack_data = try buildPack(allocator, &pack_objs);
    defer allocator.free(pack_data);

    // Save the pack
    var platform = NativePlatform{};
    const checksum_hex = try objects.saveReceivedPack(pack_data, git_dir, &platform, allocator);
    defer allocator.free(checksum_hex);

    // Verify files exist
    const pack_path = try std.fmt.allocPrint(allocator, "{s}/pack/pack-{s}.pack", .{ objects_dir, checksum_hex });
    defer allocator.free(pack_path);
    const idx_path = try std.fmt.allocPrint(allocator, "{s}/pack/pack-{s}.idx", .{ objects_dir, checksum_hex });
    defer allocator.free(idx_path);

    const pack_stat = try std.fs.cwd().statFile(pack_path);
    try testing.expect(pack_stat.size > 0);
    const idx_stat = try std.fs.cwd().statFile(idx_path);
    try testing.expect(idx_stat.size > 0);

    // Compute the expected SHA-1 of the blob
    const expected_sha1 = gitSha1("blob", blob_content);
    const expected_hex = sha1Hex(expected_sha1);

    // Load via GitObject.load (which should fall back to pack files)
    const obj = try objects.GitObject.load(&expected_hex, git_dir, &platform, allocator);
    defer obj.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.blob, obj.type);
    try testing.expectEqualStrings(blob_content, obj.data);
}

// ============================================================================
// Test: Pack with commit, tree, and blob — all loadable
// ============================================================================
test "save pack with commit+tree+blob, load all via GitObject.load" {
    const allocator = testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp});
    defer allocator.free(git_dir);
    {
        const p = try std.fmt.allocPrint(allocator, "{s}/objects/pack", .{git_dir});
        defer allocator.free(p);
        std.fs.cwd().makePath(p) catch {};
    }

    // Blob
    const blob_data = "file content for tree test\n";
    const blob_sha1 = gitSha1("blob", blob_data);
    const blob_raw = try buildBaseObject(allocator, 3, blob_data);
    defer allocator.free(blob_raw);

    // Tree (single entry: "100644 test.txt\0<20-byte-sha1>")
    var tree_data_buf = std.ArrayList(u8).init(allocator);
    defer tree_data_buf.deinit();
    try tree_data_buf.appendSlice("100644 test.txt\x00");
    try tree_data_buf.appendSlice(&blob_sha1);
    const tree_data = tree_data_buf.items;
    const tree_sha1 = gitSha1("tree", tree_data);
    const tree_raw = try buildBaseObject(allocator, 2, tree_data);
    defer allocator.free(tree_raw);

    // Commit
    const tree_hex = sha1Hex(tree_sha1);
    const commit_data = try std.fmt.allocPrint(allocator, "tree {s}\nauthor Test <test@test.com> 1000000000 +0000\ncommitter Test <test@test.com> 1000000000 +0000\n\ntest commit\n", .{tree_hex});
    defer allocator.free(commit_data);
    const commit_raw = try buildBaseObject(allocator, 1, commit_data);
    defer allocator.free(commit_raw);

    const pack_objs = [_]PackObject{
        .{ .raw_data = blob_raw },
        .{ .raw_data = tree_raw },
        .{ .raw_data = commit_raw },
    };
    const pack_data = try buildPack(allocator, &pack_objs);
    defer allocator.free(pack_data);

    var platform = NativePlatform{};
    const ck = try objects.saveReceivedPack(pack_data, git_dir, &platform, allocator);
    defer allocator.free(ck);

    // Load all three
    const blob_hex = sha1Hex(blob_sha1);
    {
        const obj = try objects.GitObject.load(&blob_hex, git_dir, &platform, allocator);
        defer obj.deinit(allocator);
        try testing.expectEqual(objects.ObjectType.blob, obj.type);
        try testing.expectEqualStrings(blob_data, obj.data);
    }

    {
        const obj = try objects.GitObject.load(&tree_hex, git_dir, &platform, allocator);
        defer obj.deinit(allocator);
        try testing.expectEqual(objects.ObjectType.tree, obj.type);
        try testing.expectEqualSlices(u8, tree_data, obj.data);
    }

    const commit_sha1 = gitSha1("commit", commit_data);
    const commit_hex = sha1Hex(commit_sha1);
    {
        const obj = try objects.GitObject.load(&commit_hex, git_dir, &platform, allocator);
        defer obj.deinit(allocator);
        try testing.expectEqual(objects.ObjectType.commit, obj.type);
        try testing.expectEqualStrings(commit_data, obj.data);
    }
}

// ============================================================================
// Test: Pack with OFS_DELTA, resolve through GitObject.load
// ============================================================================
test "save pack with OFS_DELTA blob, load deltified object via GitObject.load" {
    const allocator = testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp});
    defer allocator.free(git_dir);
    {
        const p = try std.fmt.allocPrint(allocator, "{s}/objects/pack", .{git_dir});
        defer allocator.free(p);
        std.fs.cwd().makePath(p) catch {};
    }

    // Base blob
    const base_content = "Line 1: Hello World\nLine 2: This is base content\nLine 3: More data here\n";
    const base_raw = try buildBaseObject(allocator, 3, base_content);
    defer allocator.free(base_raw);

    // Delta target: same prefix, different suffix
    const target_content = "Line 1: Hello World\nLine 2: This is base content\nLine 3: MODIFIED by delta\n";

    // Build delta instruction: copy prefix from base, insert new suffix
    const shared_prefix = "Line 1: Hello World\nLine 2: This is base content\n";
    const new_suffix = "Line 3: MODIFIED by delta\n";

    var delta = std.ArrayList(u8).init(allocator);
    defer delta.deinit();

    // Delta header: base_size, result_size
    var vbuf: [10]u8 = undefined;
    var vlen = encodeDeltaVarint(&vbuf, base_content.len);
    try delta.appendSlice(vbuf[0..vlen]);
    vlen = encodeDeltaVarint(&vbuf, target_content.len);
    try delta.appendSlice(vbuf[0..vlen]);

    // Copy command: copy shared_prefix.len bytes from offset 0
    // cmd byte: 0x80 | 0x01 (offset byte 0) | 0x10 (size byte 0)
    try delta.append(0x80 | 0x01 | 0x10);
    try delta.append(0x00); // offset low byte = 0
    try delta.append(@intCast(shared_prefix.len)); // size low byte

    // Insert command: insert new_suffix
    try delta.append(@intCast(new_suffix.len));
    try delta.appendSlice(new_suffix);

    // Build OFS_DELTA object
    // The base object starts at offset 12 (after PACK header)
    // The delta object starts after the base object's raw bytes
    const base_offset_in_pack: usize = 12;
    const delta_offset_in_pack: usize = 12 + base_raw.len;
    const negative_offset = delta_offset_in_pack - base_offset_in_pack;

    var delta_obj_buf = std.ArrayList(u8).init(allocator);
    defer delta_obj_buf.deinit();

    // Pack object header: type=6 (OFS_DELTA), uncompressed delta size
    var hdr: [10]u8 = undefined;
    const hdr_len = encodePackHeader(&hdr, 6, delta.items.len);
    try delta_obj_buf.appendSlice(hdr[0..hdr_len]);

    // Encode negative offset (git's encoding)
    {
        var offset_bytes: [10]u8 = undefined;
        var n = negative_offset;
        var idx: usize = 0;
        offset_bytes[idx] = @intCast(n & 0x7F);
        n >>= 7;
        while (n > 0) {
            idx += 1;
            n -= 1;
            offset_bytes[idx] = @intCast(0x80 | (n & 0x7F));
            n >>= 7;
        }
        // Write in reverse (MSB first)
        var j: usize = idx + 1;
        while (j > 0) {
            j -= 1;
            try delta_obj_buf.append(offset_bytes[j]);
        }
    }

    // Compressed delta data
    const compressed_delta = try zlibCompress(allocator, delta.items);
    defer allocator.free(compressed_delta);
    try delta_obj_buf.appendSlice(compressed_delta);

    const delta_raw = try allocator.dupe(u8, delta_obj_buf.items);
    defer allocator.free(delta_raw);

    // Build pack
    const pack_objs = [_]PackObject{
        .{ .raw_data = base_raw },
        .{ .raw_data = delta_raw },
    };
    const pack_data = try buildPack(allocator, &pack_objs);
    defer allocator.free(pack_data);

    // Verify: readPackObjectAtOffset can read the delta
    const delta_obj = try objects.readPackObjectAtOffset(pack_data, delta_offset_in_pack, allocator);
    defer delta_obj.deinit(allocator);
    try testing.expectEqual(objects.ObjectType.blob, delta_obj.type);
    try testing.expectEqualStrings(target_content, delta_obj.data);

    // Save and load through full path
    var platform = NativePlatform{};
    const ck = try objects.saveReceivedPack(pack_data, git_dir, &platform, allocator);
    defer allocator.free(ck);

    // Load the deltified object by its SHA-1
    const target_sha1 = gitSha1("blob", target_content);
    const target_hex = sha1Hex(target_sha1);

    const loaded = try objects.GitObject.load(&target_hex, git_dir, &platform, allocator);
    defer loaded.deinit(allocator);
    try testing.expectEqual(objects.ObjectType.blob, loaded.type);
    try testing.expectEqualStrings(target_content, loaded.data);

    // Also load the base object
    const base_sha1 = gitSha1("blob", base_content);
    const base_hex = sha1Hex(base_sha1);
    const loaded_base = try objects.GitObject.load(&base_hex, git_dir, &platform, allocator);
    defer loaded_base.deinit(allocator);
    try testing.expectEqual(objects.ObjectType.blob, loaded_base.type);
    try testing.expectEqualStrings(base_content, loaded_base.data);
}

// ============================================================================
// Test: git verify-pack validates our .pack+.idx
// ============================================================================
test "git verify-pack accepts ziggit-generated pack+idx" {
    const allocator = testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp});
    defer allocator.free(git_dir);
    {
        const p = try std.fmt.allocPrint(allocator, "{s}/objects/pack", .{git_dir});
        defer allocator.free(p);
        std.fs.cwd().makePath(p) catch {};
    }

    // Build pack with multiple objects
    const blobs = [_][]const u8{
        "First blob content\n",
        "Second blob with different data\n",
        "Third blob: 0123456789\n",
    };

    var raw_objects: [3][]u8 = undefined;
    var raw_count: usize = 0;
    defer for (raw_objects[0..raw_count]) |r| allocator.free(r);

    for (blobs) |content| {
        raw_objects[raw_count] = try buildBaseObject(allocator, 3, content);
        raw_count += 1;
    }

    const pack_objs = [_]PackObject{
        .{ .raw_data = raw_objects[0] },
        .{ .raw_data = raw_objects[1] },
        .{ .raw_data = raw_objects[2] },
    };
    const pack_data = try buildPack(allocator, &pack_objs);
    defer allocator.free(pack_data);

    var platform = NativePlatform{};
    const ck = try objects.saveReceivedPack(pack_data, git_dir, &platform, allocator);
    defer allocator.free(ck);

    // Initialize minimal git repo so git verify-pack works
    try gitExec(allocator, tmp, &.{"init"});

    // git verify-pack should succeed
    const idx_path = try std.fmt.allocPrint(allocator, ".git/objects/pack/pack-{s}.idx", .{ck});
    defer allocator.free(idx_path);

    const verify_out = try git(allocator, tmp, &.{ "verify-pack", "-v", idx_path });
    defer allocator.free(verify_out);

    // Should contain our blob SHA-1s
    for (blobs) |content| {
        const sha1 = gitSha1("blob", content);
        const hex = sha1Hex(sha1);
        try testing.expect(std.mem.indexOf(u8, verify_out, &hex) != null);
    }
}

// ============================================================================
// Test: git-created pack (via gc) readable through GitObject.load
// ============================================================================
test "git gc pack readable through ziggit GitObject.load" {
    const allocator = testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    // Create repo with multiple commits (forces gc to create deltas)
    try gitExec(allocator, tmp, &.{"init"});
    try gitExec(allocator, tmp, &.{ "config", "user.name", "Test" });
    try gitExec(allocator, tmp, &.{ "config", "user.email", "t@t.com" });

    const file_path = try std.fmt.allocPrint(allocator, "{s}/data.txt", .{tmp});
    defer allocator.free(file_path);

    // Create several versions to encourage delta compression
    const versions = [_][]const u8{
        "Version 1: Initial content with some shared text\n",
        "Version 2: Initial content with some shared text\nAdded a new line\n",
        "Version 3: Initial content with some shared text\nAdded a new line\nAnd another line\n",
        "Version 4: Initial content with some shared text\nAdded a new line\nAnd another line\nFinal version\n",
    };

    for (versions) |content| {
        {
            const f = try std.fs.createFileAbsolute(file_path, .{ .truncate = true });
            defer f.close();
            try f.writeAll(content);
        }
        try gitExec(allocator, tmp, &.{ "add", "data.txt" });
        try gitExec(allocator, tmp, &.{ "commit", "-m", "update" });
    }

    // Run gc to create pack files
    try gitExec(allocator, tmp, &.{ "gc", "--aggressive" });

    // Get HEAD commit hash
    const head_out = try git(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(head_out);
    const head_hash = std.mem.trimRight(u8, head_out, "\n\r \t");

    // Load HEAD commit through ziggit
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp});
    defer allocator.free(git_dir);

    var platform = NativePlatform{};

    const commit_obj = try objects.GitObject.load(head_hash, git_dir, &platform, allocator);
    defer commit_obj.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.commit, commit_obj.type);
    try testing.expect(std.mem.indexOf(u8, commit_obj.data, "tree ") != null);

    // Extract tree hash from commit and load tree
    const tree_line_end = std.mem.indexOf(u8, commit_obj.data, "\n") orelse return error.InvalidCommit;
    const tree_hash = commit_obj.data[5..tree_line_end]; // "tree <hash>"
    try testing.expectEqual(@as(usize, 40), tree_hash.len);

    const tree_obj = try objects.GitObject.load(tree_hash, git_dir, &platform, allocator);
    defer tree_obj.deinit(allocator);
    try testing.expectEqual(objects.ObjectType.tree, tree_obj.type);

    // Extract blob hash from tree and load blob
    // Tree format: "100644 data.txt\0<20-byte-hash>"
    const null_pos = std.mem.indexOf(u8, tree_obj.data, "\x00") orelse return error.InvalidTree;
    if (null_pos + 21 > tree_obj.data.len) return error.InvalidTree;
    const blob_sha1_bytes = tree_obj.data[null_pos + 1 .. null_pos + 21];
    var blob_hex: [40]u8 = undefined;
    _ = try std.fmt.bufPrint(&blob_hex, "{}", .{std.fmt.fmtSliceHexLower(blob_sha1_bytes)});

    const blob_obj = try objects.GitObject.load(&blob_hex, git_dir, &platform, allocator);
    defer blob_obj.deinit(allocator);
    try testing.expectEqual(objects.ObjectType.blob, blob_obj.type);

    // The blob should be the latest version
    try testing.expectEqualStrings(versions[versions.len - 1], blob_obj.data);
}

// ============================================================================
// Test: tag object in pack
// ============================================================================
test "save pack with tag object, load via GitObject.load" {
    const allocator = testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp});
    defer allocator.free(git_dir);
    {
        const p = try std.fmt.allocPrint(allocator, "{s}/objects/pack", .{git_dir});
        defer allocator.free(p);
        std.fs.cwd().makePath(p) catch {};
    }

    // Create a blob and tag that points to it
    const blob_data = "tagged content\n";
    const blob_sha1 = gitSha1("blob", blob_data);
    const blob_hex = sha1Hex(blob_sha1);

    const tag_data = try std.fmt.allocPrint(allocator,
        "object {s}\ntype blob\ntag v1.0\ntagger Test <test@test.com> 1000000000 +0000\n\nRelease v1.0\n",
        .{blob_hex},
    );
    defer allocator.free(tag_data);

    const blob_raw = try buildBaseObject(allocator, 3, blob_data);
    defer allocator.free(blob_raw);
    const tag_raw = try buildBaseObject(allocator, 4, tag_data);
    defer allocator.free(tag_raw);

    const pack_objs = [_]PackObject{
        .{ .raw_data = blob_raw },
        .{ .raw_data = tag_raw },
    };
    const pack_data = try buildPack(allocator, &pack_objs);
    defer allocator.free(pack_data);

    var platform = NativePlatform{};
    const ck = try objects.saveReceivedPack(pack_data, git_dir, &platform, allocator);
    defer allocator.free(ck);

    // Load tag
    const tag_sha1 = gitSha1("tag", tag_data);
    const tag_hex = sha1Hex(tag_sha1);
    const loaded_tag = try objects.GitObject.load(&tag_hex, git_dir, &platform, allocator);
    defer loaded_tag.deinit(allocator);
    try testing.expectEqual(objects.ObjectType.tag, loaded_tag.type);
    try testing.expectEqualStrings(tag_data, loaded_tag.data);
}

// ============================================================================
// Test: readPackObjectAtOffset for all base types
// ============================================================================
test "readPackObjectAtOffset returns correct type and data for all base types" {
    const allocator = testing.allocator;

    const TypeInfo = struct { type_num: u3, expected: objects.ObjectType, data: []const u8 };
    const cases = [_]TypeInfo{
        .{ .type_num = 1, .expected = .commit, .data = "tree 0000000000000000000000000000000000000000\nauthor A <a@a.com> 0 +0000\ncommitter A <a@a.com> 0 +0000\n\nmsg\n" },
        .{ .type_num = 2, .expected = .tree, .data = "100644 f\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10\x11\x12\x13" },
        .{ .type_num = 3, .expected = .blob, .data = "hello blob" },
        .{ .type_num = 4, .expected = .tag, .data = "object 0000000000000000000000000000000000000000\ntype blob\ntag t\ntagger A <a@a.com> 0 +0000\n\nmsg\n" },
    };

    for (cases) |case| {
        const raw = try buildBaseObject(allocator, case.type_num, case.data);
        defer allocator.free(raw);

        const pack_objs = [_]PackObject{.{ .raw_data = raw }};
        const pack_data = try buildPack(allocator, &pack_objs);
        defer allocator.free(pack_data);

        const obj = try objects.readPackObjectAtOffset(pack_data, 12, allocator);
        defer obj.deinit(allocator);

        try testing.expectEqual(case.expected, obj.type);
        try testing.expectEqualSlices(u8, case.data, obj.data);
    }
}

// ============================================================================
// Test: generatePackIndex produces correct fanout table
// ============================================================================
test "generatePackIndex fanout table is monotonically increasing" {
    const allocator = testing.allocator;

    // Build pack with several blobs whose SHA-1s span different first bytes
    var raw_list = std.ArrayList([]u8).init(allocator);
    defer {
        for (raw_list.items) |r| allocator.free(r);
        raw_list.deinit();
    }

    for (0..20) |i| {
        var content_buf: [64]u8 = undefined;
        const content = std.fmt.bufPrint(&content_buf, "blob number {d} unique content\n", .{i}) catch unreachable;
        const raw = try buildBaseObject(allocator, 3, content);
        try raw_list.append(raw);
    }

    var pack_objs = std.ArrayList(PackObject).init(allocator);
    defer pack_objs.deinit();
    for (raw_list.items) |raw| {
        try pack_objs.append(.{ .raw_data = raw });
    }

    const pack_data = try buildPack(allocator, pack_objs.items);
    defer allocator.free(pack_data);

    const idx_data = try objects.generatePackIndex(pack_data, allocator);
    defer allocator.free(idx_data);

    // Verify idx header
    const magic = std.mem.readInt(u32, @ptrCast(idx_data[0..4]), .big);
    try testing.expectEqual(@as(u32, 0xff744f63), magic);
    const version = std.mem.readInt(u32, @ptrCast(idx_data[4..8]), .big);
    try testing.expectEqual(@as(u32, 2), version);

    // Fanout table must be monotonically non-decreasing
    var prev: u32 = 0;
    for (0..256) |i| {
        const offset = 8 + i * 4;
        const val = std.mem.readInt(u32, @ptrCast(idx_data[offset .. offset + 4]), .big);
        try testing.expect(val >= prev);
        prev = val;
    }

    // Last fanout entry should equal total object count
    try testing.expectEqual(@as(u32, 20), prev);
}

// ============================================================================
// Test: empty delta (result == base via pure copy)
// ============================================================================
test "applyDelta: identity delta produces exact base content" {
    const allocator = testing.allocator;
    const base = "Exact copy of this content\n";

    var delta = std.ArrayList(u8).init(allocator);
    defer delta.deinit();

    // base_size
    var vbuf: [10]u8 = undefined;
    var vlen = encodeDeltaVarint(&vbuf, base.len);
    try delta.appendSlice(vbuf[0..vlen]);

    // result_size = base_size
    vlen = encodeDeltaVarint(&vbuf, base.len);
    try delta.appendSlice(vbuf[0..vlen]);

    // Single copy command: copy all of base
    try delta.append(0x80 | 0x01 | 0x10); // offset byte + size byte
    try delta.append(0x00); // offset = 0
    try delta.append(@intCast(base.len)); // size = base.len

    const result = try objects.applyDelta(base, delta.items, allocator);
    defer allocator.free(result);

    try testing.expectEqualStrings(base, result);
}

// ============================================================================
// Test: delta with multiple copy+insert operations
// ============================================================================
test "applyDelta: complex multi-operation delta" {
    const allocator = testing.allocator;
    const base = "AAAAABBBBBCCCCC";
    // Target: "BBBBBXXXAAA"
    // - copy 5 bytes from offset 5 (BBBBB)
    // - insert "XXX"
    // - copy 3 bytes from offset 0 (AAA)
    const expected = "BBBBBXXXAAA";

    var delta = std.ArrayList(u8).init(allocator);
    defer delta.deinit();

    var vbuf: [10]u8 = undefined;
    var vlen = encodeDeltaVarint(&vbuf, base.len);
    try delta.appendSlice(vbuf[0..vlen]);
    vlen = encodeDeltaVarint(&vbuf, expected.len);
    try delta.appendSlice(vbuf[0..vlen]);

    // Copy BBBBB: offset=5, size=5
    try delta.append(0x80 | 0x01 | 0x10);
    try delta.append(5); // offset
    try delta.append(5); // size

    // Insert XXX
    try delta.append(3);
    try delta.appendSlice("XXX");

    // Copy AAA: offset=0, size=3
    try delta.append(0x80 | 0x01 | 0x10);
    try delta.append(0); // offset
    try delta.append(3); // size

    const result = try objects.applyDelta(base, delta.items, allocator);
    defer allocator.free(result);

    try testing.expectEqualStrings(expected, result);
}
