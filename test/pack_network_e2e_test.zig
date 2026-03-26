const std = @import("std");
const testing = std.testing;
const objects = @import("git_objects");

// ============================================================================
// PACK NETWORK END-TO-END TESTS
//
// These tests simulate what NET-SMART and NET-PACK agents encounter:
//   1. Receiving a pack file (from HTTPS fetch/clone)
//   2. Saving it with saveReceivedPack (writes .pack + generates .idx)
//   3. Reading objects back by SHA-1 through the normal load path
//   4. Handling thin packs (REF_DELTA with external bases)
//   5. Multi-object packs with mixed types
//   6. Cross-validation with git CLI
//
// All packs are constructed byte-by-byte (no git CLI dependency for core tests).
// Git CLI is used only in cross-validation tests (skipped if git unavailable).
// ============================================================================

const NativePlatform = struct {
    fs: Fs = .{},

    const Fs = struct {
        pub fn readFile(_: Fs, alloc: std.mem.Allocator, path: []const u8) ![]u8 {
            return std.fs.cwd().readFileAlloc(alloc, path, 100 * 1024 * 1024);
        }

        pub fn writeFile(_: Fs, path: []const u8, data: []const u8) !void {
            const file = try std.fs.cwd().createFile(path, .{});
            defer file.close();
            try file.writeAll(data);
        }

        pub fn makeDir(_: Fs, path: []const u8) (std.fs.Dir.MakeError || error{AlreadyExists})!void {
            std.fs.cwd().makeDir(path) catch |err| switch (err) {
                error.PathAlreadyExists => return error.AlreadyExists,
                else => return err,
            };
        }
    };
};

fn gitObjectSha1(obj_type: []const u8, data: []const u8) [20]u8 {
    var hasher = std.crypto.hash.Sha1.init(.{});
    var header_buf: [64]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "{s} {}\x00", .{ obj_type, data.len }) catch unreachable;
    hasher.update(header);
    hasher.update(data);
    var out: [20]u8 = undefined;
    hasher.final(&out);
    return out;
}

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

fn zlibCompress(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var compressed = std.ArrayList(u8).init(allocator);
    defer compressed.deinit();
    var input = std.io.fixedBufferStream(data);
    try std.compress.zlib.compress(input.reader(), compressed.writer(), .{});
    return try allocator.dupe(u8, compressed.items);
}

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

fn sha1Hex(sha1: [20]u8) [40]u8 {
    var hex: [40]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{}", .{std.fmt.fmtSliceHexLower(&sha1)}) catch unreachable;
    return hex;
}

/// Build a pack with given objects. Each object is (type_num, data).
/// Returns pack data with valid header and checksum.
fn buildPack(allocator: std.mem.Allocator, raw_objects: []const PackObject) ![]u8 {
    var pack = std.ArrayList(u8).init(allocator);
    defer pack.deinit();

    // Header
    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, @intCast(raw_objects.len), .big);

    // Objects
    for (raw_objects) |obj| {
        var hdr_buf: [10]u8 = undefined;
        const hdr_len = encodePackObjectHeader(&hdr_buf, obj.type_num, obj.data.len);
        try pack.appendSlice(hdr_buf[0..hdr_len]);

        // For REF_DELTA, write the base SHA-1 before compressed data
        if (obj.type_num == 7) {
            try pack.appendSlice(&obj.ref_delta_base_sha1.?);
        }

        const compressed = try zlibCompress(allocator, obj.data);
        defer allocator.free(compressed);
        try pack.appendSlice(compressed);
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
    type_num: u3,
    data: []const u8,
    ref_delta_base_sha1: ?[20]u8 = null,
};

fn gitAvailable(allocator: std.mem.Allocator) bool {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "--version" },
    }) catch return false;
    allocator.free(result.stdout);
    allocator.free(result.stderr);
    return true;
}

fn setupTestRepo(allocator: std.mem.Allocator) !struct { dir: []const u8, git_dir: []const u8, platform: NativePlatform } {
    const dir = try allocator.dupe(u8, "/tmp/ziggit_net_e2e_test_XXXXXX");
    // Use mkdtemp equivalent
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "mktemp", "-d", "/tmp/ziggit_net_e2e_test_XXXXXX" },
    }) catch return error.TestSetupFailed;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    allocator.free(dir);
    const trimmed = std.mem.trimRight(u8, result.stdout, "\n");
    const dir2 = try allocator.dupe(u8, trimmed);
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{dir2});

    // Init repo
    const init_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "init", dir2 },
    }) catch return error.TestSetupFailed;
    allocator.free(init_result.stdout);
    allocator.free(init_result.stderr);

    return .{ .dir = dir2, .git_dir = git_dir, .platform = NativePlatform{} };
}

fn cleanupTestRepo(allocator: std.mem.Allocator, dir: []const u8, git_dir: []const u8) void {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "rm", "-rf", dir },
    }) catch return;
    allocator.free(result.stdout);
    allocator.free(result.stderr);
    allocator.free(git_dir);
    allocator.free(dir);
}

// ============================================================================
// Test 1: saveReceivedPack with single blob, then load by hash
// ============================================================================
test "e2e: saveReceivedPack single blob then load" {
    const allocator = testing.allocator;
    const setup = try setupTestRepo(allocator);
    defer cleanupTestRepo(allocator, setup.dir, setup.git_dir);
    var platform = setup.platform;

    const blob_data = "Hello from network clone!\n";
    const expected_sha1 = gitObjectSha1("blob", blob_data);
    const expected_hex = sha1Hex(expected_sha1);

    const pack_data = try buildPack(allocator, &.{
        .{ .type_num = 3, .data = blob_data },
    });
    defer allocator.free(pack_data);

    const checksum_hex = try objects.saveReceivedPack(pack_data, setup.git_dir, &platform, allocator);
    defer allocator.free(checksum_hex);

    // Load the object by hash through the normal path (which searches pack files)
    const obj = try objects.GitObject.load(&expected_hex, setup.git_dir, &platform, allocator);
    defer obj.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.blob, obj.type);
    try testing.expectEqualStrings(blob_data, obj.data);
}

// ============================================================================
// Test 2: saveReceivedPack with commit + tree + blob, load all three
// ============================================================================
test "e2e: saveReceivedPack mixed types then load all" {
    const allocator = testing.allocator;
    const setup = try setupTestRepo(allocator);
    defer cleanupTestRepo(allocator, setup.dir, setup.git_dir);
    var platform = setup.platform;

    const blob_data = "file content\n";
    const blob_sha1 = gitObjectSha1("blob", blob_data);

    // Tree entry: "100644 file.txt\0<sha1>"
    var tree_data_buf: [256]u8 = undefined;
    var tree_stream = std.io.fixedBufferStream(&tree_data_buf);
    tree_stream.writer().print("100644 file.txt\x00", .{}) catch unreachable;
    tree_stream.writer().writeAll(&blob_sha1) catch unreachable;
    const tree_data = tree_data_buf[0..tree_stream.pos];
    const tree_sha1 = gitObjectSha1("tree", tree_data);
    const tree_hex = sha1Hex(tree_sha1);

    var commit_buf: [512]u8 = undefined;
    var commit_stream = std.io.fixedBufferStream(&commit_buf);
    const commit_writer = commit_stream.writer();
    commit_writer.print("tree {s}\nauthor Test <test@test.com> 1000000000 +0000\ncommitter Test <test@test.com> 1000000000 +0000\n\nInitial commit\n", .{sha1Hex(tree_sha1)}) catch unreachable;
    const commit_data = commit_buf[0..commit_stream.pos];
    const commit_sha1 = gitObjectSha1("commit", commit_data);
    const commit_hex = sha1Hex(commit_sha1);

    const pack_data = try buildPack(allocator, &.{
        .{ .type_num = 3, .data = blob_data },
        .{ .type_num = 2, .data = tree_data },
        .{ .type_num = 1, .data = commit_data },
    });
    defer allocator.free(pack_data);

    const checksum_hex = try objects.saveReceivedPack(pack_data, setup.git_dir, &platform, allocator);
    defer allocator.free(checksum_hex);

    // Load all three objects
    {
        const blob_hex = sha1Hex(blob_sha1);
        const obj = try objects.GitObject.load(&blob_hex, setup.git_dir, &platform, allocator);
        defer obj.deinit(allocator);
        try testing.expectEqual(objects.ObjectType.blob, obj.type);
        try testing.expectEqualStrings(blob_data, obj.data);
    }
    {
        const obj = try objects.GitObject.load(&tree_hex, setup.git_dir, &platform, allocator);
        defer obj.deinit(allocator);
        try testing.expectEqual(objects.ObjectType.tree, obj.type);
        try testing.expectEqualSlices(u8, tree_data, obj.data);
    }
    {
        const obj = try objects.GitObject.load(&commit_hex, setup.git_dir, &platform, allocator);
        defer obj.deinit(allocator);
        try testing.expectEqual(objects.ObjectType.commit, obj.type);
        try testing.expectEqualStrings(commit_data, obj.data);
    }
}

// ============================================================================
// Test 3: saveReceivedPack with OFS_DELTA, load resolved object
// ============================================================================
test "e2e: saveReceivedPack with OFS_DELTA resolves correctly" {
    const allocator = testing.allocator;
    const setup = try setupTestRepo(allocator);
    defer cleanupTestRepo(allocator, setup.dir, setup.git_dir);
    var platform = setup.platform;

    // Base blob and delta that modifies it
    const base_data = "Hello, World!\n";
    const result_data = "Hello, Zig!\n";

    // Build delta: copy "Hello, " (7 bytes), insert "Zig!\n" (5 bytes)
    var delta = std.ArrayList(u8).init(allocator);
    defer delta.deinit();

    // Delta header: base_size, result_size
    var vbuf: [10]u8 = undefined;
    var n = encodeDeltaVarint(&vbuf, base_data.len);
    try delta.appendSlice(vbuf[0..n]);
    n = encodeDeltaVarint(&vbuf, result_data.len);
    try delta.appendSlice(vbuf[0..n]);

    // Copy command: offset=0, size=7
    try delta.append(0x80 | 0x10); // copy, size byte 0
    try delta.append(7); // size = 7

    // Insert command: "Zig!\n"
    try delta.append(5);
    try delta.appendSlice("Zig!\n");

    // Build pack manually with OFS_DELTA
    var pack = std.ArrayList(u8).init(allocator);
    defer pack.deinit();

    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, 2, .big); // 2 objects

    // Object 1: base blob
    const base_offset = pack.items.len;
    var hdr_buf: [10]u8 = undefined;
    var hdr_len = encodePackObjectHeader(&hdr_buf, 3, base_data.len); // blob
    try pack.appendSlice(hdr_buf[0..hdr_len]);
    const base_compressed = try zlibCompress(allocator, base_data);
    defer allocator.free(base_compressed);
    try pack.appendSlice(base_compressed);

    // Object 2: OFS_DELTA referencing object 1
    const delta_obj_offset = pack.items.len;
    hdr_len = encodePackObjectHeader(&hdr_buf, 6, delta.items.len); // ofs_delta
    try pack.appendSlice(hdr_buf[0..hdr_len]);

    // OFS_DELTA negative offset encoding
    const neg_offset = delta_obj_offset - base_offset;
    // Encode negative offset (git's encoding: MSB continuation, value builds up)
    var off_buf: [10]u8 = undefined;
    var off_val = neg_offset;
    off_buf[0] = @intCast(off_val & 0x7F);
    off_val >>= 7;
    var off_len: usize = 1;
    while (off_val > 0) {
        off_val -= 1;
        // Shift existing bytes right and prepend
        var j: usize = off_len;
        while (j > 0) : (j -= 1) {
            off_buf[j] = off_buf[j - 1];
        }
        off_buf[0] = @intCast((off_val & 0x7F) | 0x80);
        off_val >>= 7;
        off_len += 1;
    }
    try pack.appendSlice(off_buf[0..off_len]);

    const delta_compressed = try zlibCompress(allocator, delta.items);
    defer allocator.free(delta_compressed);
    try pack.appendSlice(delta_compressed);

    // Pack checksum
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack.items);
    var checksum: [20]u8 = undefined;
    hasher.final(&checksum);
    try pack.appendSlice(&checksum);

    // Save and load
    const checksum_hex = try objects.saveReceivedPack(pack.items, setup.git_dir, &platform, allocator);
    defer allocator.free(checksum_hex);

    // The delta-resolved object should be a blob with result_data
    const expected_sha1 = gitObjectSha1("blob", result_data);
    const expected_hex = sha1Hex(expected_sha1);

    const obj = try objects.GitObject.load(&expected_hex, setup.git_dir, &platform, allocator);
    defer obj.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.blob, obj.type);
    try testing.expectEqualStrings(result_data, obj.data);
}

// ============================================================================
// Test 4: fixThinPack resolves REF_DELTA against local loose object
// ============================================================================
test "e2e: fixThinPack resolves REF_DELTA from local loose object" {
    const allocator = testing.allocator;
    const setup = try setupTestRepo(allocator);
    defer cleanupTestRepo(allocator, setup.dir, setup.git_dir);
    var platform = setup.platform;

    // Store base blob as loose object
    const base_data = "base content for thin pack test\n";
    const base_obj = try objects.createBlobObject(base_data, allocator);
    defer base_obj.deinit(allocator);
    const base_hash = try base_obj.store(setup.git_dir, &platform, allocator);
    defer allocator.free(base_hash);

    var base_sha1: [20]u8 = undefined;
    _ = try std.fmt.hexToBytes(&base_sha1, base_hash);

    // Build delta: "base content" → "modified content for thin pack test\n"
    const result_data = "modified content for thin pack test\n";
    var delta = std.ArrayList(u8).init(allocator);
    defer delta.deinit();

    var vbuf: [10]u8 = undefined;
    var vn = encodeDeltaVarint(&vbuf, base_data.len);
    try delta.appendSlice(vbuf[0..vn]);
    vn = encodeDeltaVarint(&vbuf, result_data.len);
    try delta.appendSlice(vbuf[0..vn]);

    // Insert the entire result (simplest delta)
    var pos: usize = 0;
    while (pos < result_data.len) {
        const chunk = @min(127, result_data.len - pos);
        try delta.append(@intCast(chunk));
        try delta.appendSlice(result_data[pos .. pos + chunk]);
        pos += chunk;
    }

    // Build thin pack with REF_DELTA
    const pack_data = try buildPack(allocator, &.{
        .{ .type_num = 7, .data = delta.items, .ref_delta_base_sha1 = base_sha1 },
    });
    defer allocator.free(pack_data);

    // Fix thin pack
    const fixed = try objects.fixThinPack(pack_data, setup.git_dir, &platform, allocator);
    defer allocator.free(fixed);

    // Fixed pack should have 2 objects (base + delta)
    try testing.expect(fixed.len > pack_data.len);
    try testing.expect(std.mem.eql(u8, fixed[0..4], "PACK"));
    const fixed_count = std.mem.readInt(u32, @ptrCast(fixed[8..12]), .big);
    try testing.expectEqual(@as(u32, 2), fixed_count);

    // Save fixed pack and load the resolved object
    const checksum_hex = try objects.saveReceivedPack(fixed, setup.git_dir, &platform, allocator);
    defer allocator.free(checksum_hex);

    const expected_sha1 = gitObjectSha1("blob", result_data);
    const expected_hex = sha1Hex(expected_sha1);
    const obj = try objects.GitObject.load(&expected_hex, setup.git_dir, &platform, allocator);
    defer obj.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.blob, obj.type);
    try testing.expectEqualStrings(result_data, obj.data);
}

// ============================================================================
// Test 5: Pack with tag object
// ============================================================================
test "e2e: saveReceivedPack with tag object" {
    const allocator = testing.allocator;
    const setup = try setupTestRepo(allocator);
    defer cleanupTestRepo(allocator, setup.dir, setup.git_dir);
    var platform = setup.platform;

    // Create a minimal tag object
    const fake_commit_sha = "0000000000000000000000000000000000000000";
    const tag_data_str = "object " ++ fake_commit_sha ++ "\ntype commit\ntag v1.0\ntagger Test <test@test.com> 1000000000 +0000\n\nRelease v1.0\n";
    const tag_sha1 = gitObjectSha1("tag", tag_data_str);
    const tag_hex = sha1Hex(tag_sha1);

    const pack_data = try buildPack(allocator, &.{
        .{ .type_num = 4, .data = tag_data_str },
    });
    defer allocator.free(pack_data);

    const checksum_hex = try objects.saveReceivedPack(pack_data, setup.git_dir, &platform, allocator);
    defer allocator.free(checksum_hex);

    const obj = try objects.GitObject.load(&tag_hex, setup.git_dir, &platform, allocator);
    defer obj.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.tag, obj.type);
    try testing.expectEqualStrings(tag_data_str, obj.data);
}

// ============================================================================
// Test 6: generatePackIndex produces idx accepted by git verify-pack
// ============================================================================
test "cross: generated idx passes git verify-pack" {
    const allocator = testing.allocator;

    if (!gitAvailable(allocator)) return;

    const setup = try setupTestRepo(allocator);
    defer cleanupTestRepo(allocator, setup.dir, setup.git_dir);
    var platform = setup.platform;

    const blob_data = "verify-pack test content\n";
    const pack_data = try buildPack(allocator, &.{
        .{ .type_num = 3, .data = blob_data },
    });
    defer allocator.free(pack_data);

    const checksum_hex = try objects.saveReceivedPack(pack_data, setup.git_dir, &platform, allocator);
    defer allocator.free(checksum_hex);

    const pack_path = try std.fmt.allocPrint(allocator, "{s}/objects/pack/pack-{s}.pack", .{ setup.git_dir, checksum_hex });
    defer allocator.free(pack_path);

    // Run git verify-pack
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "verify-pack", "-v", pack_path },
    }) catch return;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try testing.expectEqual(@as(u8, 0), result.term.Exited);
}

// ============================================================================
// Test 7: git-created pack readable by ziggit (full roundtrip)
// ============================================================================
test "cross: git-created pack objects readable by ziggit" {
    const allocator = testing.allocator;

    if (!gitAvailable(allocator)) return;

    const setup = try setupTestRepo(allocator);
    defer cleanupTestRepo(allocator, setup.dir, setup.git_dir);
    var platform = setup.platform;

    // Create several commits with git to produce interesting pack
    const cmds = [_][]const []const u8{
        &.{ "git", "-C", setup.dir, "config", "user.email", "test@test.com" },
        &.{ "git", "-C", setup.dir, "config", "user.name", "Test" },
    };
    for (cmds) |argv| {
        const r = std.process.Child.run(.{ .allocator = allocator, .argv = argv }) catch return;
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }

    // Create files and commits
    var commit_hashes = std.ArrayList([]const u8).init(allocator);
    defer {
        for (commit_hashes.items) |h| allocator.free(h);
        commit_hashes.deinit();
    }

    for (0..5) |i| {
        const fname = try std.fmt.allocPrint(allocator, "{s}/file{}.txt", .{ setup.dir, i });
        defer allocator.free(fname);
        const content = try std.fmt.allocPrint(allocator, "Content of file {} - revision 1\n", .{i});
        defer allocator.free(content);

        try std.fs.cwd().writeFile(.{ .sub_path = fname, .data = content });

        const add_r = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "git", "-C", setup.dir, "add", "." },
        }) catch return;
        allocator.free(add_r.stdout);
        allocator.free(add_r.stderr);

        const msg = try std.fmt.allocPrint(allocator, "Commit {}", .{i});
        defer allocator.free(msg);
        const commit_r = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "git", "-C", setup.dir, "commit", "-m", msg },
        }) catch return;
        allocator.free(commit_r.stdout);
        allocator.free(commit_r.stderr);
    }

    // Run git gc to create pack file
    {
        const gc_r = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "git", "-C", setup.dir, "gc", "--aggressive" },
        }) catch return;
        allocator.free(gc_r.stdout);
        allocator.free(gc_r.stderr);
    }

    // Get HEAD hash
    const head_r = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "-C", setup.dir, "rev-parse", "HEAD" },
    }) catch return;
    defer allocator.free(head_r.stdout);
    defer allocator.free(head_r.stderr);
    const head_hash = std.mem.trimRight(u8, head_r.stdout, "\n");
    if (head_hash.len != 40) return;

    // Try to load HEAD commit through ziggit's pack path
    const obj = objects.GitObject.load(head_hash, setup.git_dir, &platform, allocator) catch |err| {
        std.debug.print("Failed to load HEAD commit from git-created pack: {}\n", .{err});
        return err;
    };
    defer obj.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.commit, obj.type);
    // Commit data should contain "tree" header
    try testing.expect(std.mem.startsWith(u8, obj.data, "tree "));
}

// ============================================================================
// Test 8: Multiple saves don't corrupt - second pack doesn't break first
// ============================================================================
test "e2e: multiple saveReceivedPack calls coexist" {
    const allocator = testing.allocator;
    const setup = try setupTestRepo(allocator);
    defer cleanupTestRepo(allocator, setup.dir, setup.git_dir);
    var platform = setup.platform;

    const blob1 = "First pack blob\n";
    const blob2 = "Second pack blob\n";
    const sha1_1 = gitObjectSha1("blob", blob1);
    const sha1_2 = gitObjectSha1("blob", blob2);
    const hex1 = sha1Hex(sha1_1);
    const hex2 = sha1Hex(sha1_2);

    const pack1 = try buildPack(allocator, &.{.{ .type_num = 3, .data = blob1 }});
    defer allocator.free(pack1);
    const pack2 = try buildPack(allocator, &.{.{ .type_num = 3, .data = blob2 }});
    defer allocator.free(pack2);

    const ck1 = try objects.saveReceivedPack(pack1, setup.git_dir, &platform, allocator);
    defer allocator.free(ck1);
    const ck2 = try objects.saveReceivedPack(pack2, setup.git_dir, &platform, allocator);
    defer allocator.free(ck2);

    // Both objects should be loadable
    {
        const obj = try objects.GitObject.load(&hex1, setup.git_dir, &platform, allocator);
        defer obj.deinit(allocator);
        try testing.expectEqualStrings(blob1, obj.data);
    }
    {
        const obj = try objects.GitObject.load(&hex2, setup.git_dir, &platform, allocator);
        defer obj.deinit(allocator);
        try testing.expectEqualStrings(blob2, obj.data);
    }
}

// ============================================================================
// Test 9: saveReceivedPack rejects bad checksum
// ============================================================================
test "e2e: saveReceivedPack rejects corrupted pack" {
    const allocator = testing.allocator;
    const setup = try setupTestRepo(allocator);
    defer cleanupTestRepo(allocator, setup.dir, setup.git_dir);
    var platform = setup.platform;

    const pack_data = try buildPack(allocator, &.{
        .{ .type_num = 3, .data = "test\n" },
    });
    defer allocator.free(pack_data);

    // Corrupt the checksum
    var corrupted = try allocator.dupe(u8, pack_data);
    defer allocator.free(corrupted);
    corrupted[corrupted.len - 1] ^= 0xFF;

    const result = objects.saveReceivedPack(corrupted, setup.git_dir, &platform, allocator);
    try testing.expectError(error.PackChecksumMismatch, result);
}

// ============================================================================
// Test 10: Binary data preservation through pack roundtrip
// ============================================================================
test "e2e: binary data preserved through pack save and load" {
    const allocator = testing.allocator;
    const setup = try setupTestRepo(allocator);
    defer cleanupTestRepo(allocator, setup.dir, setup.git_dir);
    var platform = setup.platform;

    // Binary data with all byte values
    var binary_data: [256]u8 = undefined;
    for (0..256) |i| binary_data[i] = @intCast(i);

    const sha1 = gitObjectSha1("blob", &binary_data);
    const hex = sha1Hex(sha1);

    const pack_data = try buildPack(allocator, &.{
        .{ .type_num = 3, .data = &binary_data },
    });
    defer allocator.free(pack_data);

    const ck = try objects.saveReceivedPack(pack_data, setup.git_dir, &platform, allocator);
    defer allocator.free(ck);

    const obj = try objects.GitObject.load(&hex, setup.git_dir, &platform, allocator);
    defer obj.deinit(allocator);

    try testing.expectEqualSlices(u8, &binary_data, obj.data);
}

// ============================================================================
// Test 11: Empty blob in pack
// ============================================================================
test "e2e: empty blob through pack roundtrip" {
    const allocator = testing.allocator;
    const setup = try setupTestRepo(allocator);
    defer cleanupTestRepo(allocator, setup.dir, setup.git_dir);
    var platform = setup.platform;

    const sha1 = gitObjectSha1("blob", "");
    const hex = sha1Hex(sha1);

    const pack_data = try buildPack(allocator, &.{
        .{ .type_num = 3, .data = "" },
    });
    defer allocator.free(pack_data);

    const ck = try objects.saveReceivedPack(pack_data, setup.git_dir, &platform, allocator);
    defer allocator.free(ck);

    const obj = try objects.GitObject.load(&hex, setup.git_dir, &platform, allocator);
    defer obj.deinit(allocator);

    try testing.expectEqual(@as(usize, 0), obj.data.len);
}

// ============================================================================
// Test 12: Large blob (128KB) in pack
// ============================================================================
test "e2e: large blob (128KB) through pack roundtrip" {
    const allocator = testing.allocator;
    const setup = try setupTestRepo(allocator);
    defer cleanupTestRepo(allocator, setup.dir, setup.git_dir);
    var platform = setup.platform;

    // 128KB blob
    const large = try allocator.alloc(u8, 128 * 1024);
    defer allocator.free(large);
    for (large, 0..) |*b, i| b.* = @intCast(i % 251); // prime modulus for variety

    const sha1 = gitObjectSha1("blob", large);
    const hex = sha1Hex(sha1);

    const pack_data = try buildPack(allocator, &.{
        .{ .type_num = 3, .data = large },
    });
    defer allocator.free(pack_data);

    const ck = try objects.saveReceivedPack(pack_data, setup.git_dir, &platform, allocator);
    defer allocator.free(ck);

    const obj = try objects.GitObject.load(&hex, setup.git_dir, &platform, allocator);
    defer obj.deinit(allocator);

    try testing.expectEqual(large.len, obj.data.len);
    try testing.expectEqualSlices(u8, large, obj.data);
}
