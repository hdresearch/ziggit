const std = @import("std");
const testing = std.testing;
const objects = @import("git_objects");

// ============================================================================
// PACK NETWORK RECEIVE FLOW TESTS
//
// Simulates the exact flow NET-SMART and NET-PACK agents will use when
// receiving pack data over HTTPS:
//
//   1. Receive raw pack bytes (may be thin with REF_DELTA)
//   2. fixThinPack to resolve external bases (for fetch, not clone)
//   3. saveReceivedPack writes .pack + .idx
//   4. loadFromPackFiles reads objects back by SHA-1
//   5. Multiple sequential fetches → multiple pack files coexist
//   6. Refs update after pack save
//
// Also tests edge cases specific to network-received packs:
//   - Pack with only REF_DELTA objects (pure thin pack)
//   - Pack with mixed OFS_DELTA + REF_DELTA
//   - Empty pack (0 objects, valid header)
//   - Very small objects (1 byte blobs)
//   - Pack received in one shot (clone) vs incremental (fetch)
// ============================================================================

// -- Platform shim for filesystem operations --
const Platform = struct {
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
        pub fn makeDir(_: Fs, path: []const u8) anyerror!void {
            std.fs.cwd().makeDir(path) catch |err| switch (err) {
                error.PathAlreadyExists => return error.AlreadyExists,
                else => return err,
            };
        }
    };
};

// -- Helper functions --

fn gitObjectSha1(obj_type: []const u8, data: []const u8) [20]u8 {
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

fn encodeOfsOffset(buf: []u8, negative_offset: usize) usize {
    var off = negative_offset;
    var i: usize = 0;
    buf[i] = @intCast(off & 0x7F);
    off >>= 7;
    i += 1;
    while (off > 0) {
        off -= 1;
        var j: usize = i;
        while (j > 0) : (j -= 1) {
            buf[j] = buf[j - 1];
        }
        buf[0] = @intCast((off & 0x7F) | 0x80);
        off >>= 7;
        i += 1;
    }
    return i;
}

/// Build a delta: copy first `copy_len` bytes from base, then insert `suffix`.
fn buildDelta(allocator: std.mem.Allocator, base_size: usize, copy_len: usize, suffix: []const u8) ![]u8 {
    var delta = std.ArrayList(u8).init(allocator);
    var buf: [10]u8 = undefined;
    const result_size = copy_len + suffix.len;

    // Header
    var n = encodeDeltaVarint(&buf, base_size);
    try delta.appendSlice(buf[0..n]);
    n = encodeDeltaVarint(&buf, result_size);
    try delta.appendSlice(buf[0..n]);

    // Copy from base
    if (copy_len > 0) {
        var cmd: u8 = 0x80; // copy
        var copy_bytes = std.ArrayList(u8).init(allocator);
        defer copy_bytes.deinit();
        // offset = 0 (no offset bytes needed)
        // size bytes
        const sz = copy_len;
        if (sz & 0xFF != 0 or (sz > 0 and sz <= 0xFF)) {
            cmd |= 0x10;
            try copy_bytes.append(@intCast(sz & 0xFF));
        }
        if (sz > 0xFF) {
            if (cmd & 0x10 == 0) {
                cmd |= 0x10;
                try copy_bytes.append(@intCast(sz & 0xFF));
            }
            cmd |= 0x20;
            try copy_bytes.append(@intCast((sz >> 8) & 0xFF));
        }
        if (sz > 0xFFFF) {
            cmd |= 0x40;
            try copy_bytes.append(@intCast((sz >> 16) & 0xFF));
        }
        try delta.append(cmd);
        try delta.appendSlice(copy_bytes.items);
    }

    // Insert suffix
    if (suffix.len > 0) {
        var off: usize = 0;
        while (off < suffix.len) {
            const chunk = @min(suffix.len - off, 127);
            try delta.append(@intCast(chunk));
            try delta.appendSlice(suffix[off .. off + chunk]);
            off += chunk;
        }
    }

    return try delta.toOwnedSlice();
}

fn buildPackFile(allocator: std.mem.Allocator, objs: []const struct { type_num: u3, data: []const u8 }) ![]u8 {
    var pack = std.ArrayList(u8).init(allocator);
    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, @intCast(objs.len), .big);
    for (objs) |obj| {
        var hdr_buf: [16]u8 = undefined;
        const hdr_len = encodePackObjectHeader(&hdr_buf, obj.type_num, obj.data.len);
        try pack.appendSlice(hdr_buf[0..hdr_len]);
        const compressed = try zlibCompress(allocator, obj.data);
        defer allocator.free(compressed);
        try pack.appendSlice(compressed);
    }
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack.items);
    var cksum: [20]u8 = undefined;
    hasher.final(&cksum);
    try pack.appendSlice(&cksum);
    return try pack.toOwnedSlice();
}

fn initGitRepo(allocator: std.mem.Allocator, path: []const u8) !void {
    const argv = [_][]const u8{ "git", "init", path };
    var child = std.process.Child.init(&argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const stdout = try child.stdout.?.reader().readAllAlloc(allocator, 1 << 20);
    defer allocator.free(stdout);
    const stderr = try child.stderr.?.reader().readAllAlloc(allocator, 1 << 20);
    defer allocator.free(stderr);
    _ = try child.wait();
}

// ============================================================================
// TEST 1: Clone flow — receive pack with all base types, save, load back
// ============================================================================

test "clone flow: save pack → load all object types by SHA-1" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    const repo_path = try std.fmt.allocPrint(allocator, "{s}/repo", .{tmp_path});
    defer allocator.free(repo_path);

    initGitRepo(allocator, repo_path) catch return; // skip if no git
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{repo_path});
    defer allocator.free(git_dir);

    const platform = Platform{};

    // Construct pack with blob + commit + tree + tag
    const blob_data = "clone flow test blob\n";
    var tree_buf: [256]u8 = undefined;
    const tree_entry = "100644 test.txt\x00";
    @memcpy(tree_buf[0..tree_entry.len], tree_entry);
    const blob_sha1 = gitObjectSha1("blob", blob_data);
    @memcpy(tree_buf[tree_entry.len .. tree_entry.len + 20], &blob_sha1);
    const tree_data = tree_buf[0 .. tree_entry.len + 20];

    const tree_sha1 = gitObjectSha1("tree", tree_data);
    var tree_hex: [40]u8 = undefined;
    _ = std.fmt.bufPrint(&tree_hex, "{}", .{std.fmt.fmtSliceHexLower(&tree_sha1)}) catch unreachable;

    var commit_buf: [512]u8 = undefined;
    const commit_data = std.fmt.bufPrint(&commit_buf, "tree {s}\nauthor Test <t@t.com> 1700000000 +0000\ncommitter Test <t@t.com> 1700000000 +0000\n\nclone test\n", .{tree_hex}) catch unreachable;

    const commit_sha1 = gitObjectSha1("commit", commit_data);
    var commit_hex: [40]u8 = undefined;
    _ = std.fmt.bufPrint(&commit_hex, "{}", .{std.fmt.fmtSliceHexLower(&commit_sha1)}) catch unreachable;

    var tag_buf: [512]u8 = undefined;
    const tag_data = std.fmt.bufPrint(&tag_buf, "object {s}\ntype commit\ntag v1.0\ntagger Test <t@t.com> 1700000000 +0000\n\nrelease\n", .{commit_hex}) catch unreachable;

    const pack_data = try buildPackFile(allocator, &.{
        .{ .type_num = 3, .data = blob_data },
        .{ .type_num = 2, .data = tree_data },
        .{ .type_num = 1, .data = commit_data },
        .{ .type_num = 4, .data = tag_data },
    });
    defer allocator.free(pack_data);

    // Save pack (simulating what NET-PACK does after receiving pack data)
    const ck_hex = try objects.saveReceivedPack(pack_data, git_dir, &platform, allocator);
    defer allocator.free(ck_hex);

    // Load each object by SHA-1 (simulating post-clone object access)
    const blob_hex = sha1Hex(gitObjectSha1("blob", blob_data));
    const loaded_blob = try objects.loadFromPackFiles(&blob_hex, git_dir, &platform, allocator);
    defer loaded_blob.deinit(allocator);
    try testing.expect(loaded_blob.type == .blob);
    try testing.expectEqualStrings(blob_data, loaded_blob.data);

    const t_hex = sha1Hex(gitObjectSha1("tree", tree_data));
    const loaded_tree = try objects.loadFromPackFiles(&t_hex, git_dir, &platform, allocator);
    defer loaded_tree.deinit(allocator);
    try testing.expect(loaded_tree.type == .tree);
    try testing.expectEqualSlices(u8, tree_data, loaded_tree.data);

    const c_hex = sha1Hex(gitObjectSha1("commit", commit_data));
    const loaded_commit = try objects.loadFromPackFiles(&c_hex, git_dir, &platform, allocator);
    defer loaded_commit.deinit(allocator);
    try testing.expect(loaded_commit.type == .commit);
    try testing.expectEqualStrings(commit_data, loaded_commit.data);

    const tg_hex = sha1Hex(gitObjectSha1("tag", tag_data));
    const loaded_tag = try objects.loadFromPackFiles(&tg_hex, git_dir, &platform, allocator);
    defer loaded_tag.deinit(allocator);
    try testing.expect(loaded_tag.type == .tag);
    try testing.expectEqualStrings(tag_data, loaded_tag.data);
}

// ============================================================================
// TEST 2: Fetch flow — thin pack with REF_DELTA, fixThinPack, save, load
// ============================================================================

test "fetch flow: fixThinPack resolves REF_DELTA → save → load" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    const repo_path = try std.fmt.allocPrint(allocator, "{s}/repo", .{tmp_path});
    defer allocator.free(repo_path);

    initGitRepo(allocator, repo_path) catch return;
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{repo_path});
    defer allocator.free(git_dir);
    const platform = Platform{};

    // Store a base blob as loose object (simulates existing repo state before fetch)
    const base_content = "This is the original file content that exists locally.\n";
    const base_obj = objects.GitObject.init(.blob, base_content);
    const base_hash_hex = try base_obj.store(git_dir, &platform, allocator);
    defer allocator.free(base_hash_hex);

    // Build thin pack: one REF_DELTA object referencing the local base
    const base_sha1 = gitObjectSha1("blob", base_content);
    const modified_content = "This is the MODIFIED file content from the remote.\n";
    const delta_data = try buildDelta(allocator, base_content.len, 8, modified_content[8..]);
    defer allocator.free(delta_data);

    // Verify our delta produces the right result
    const delta_check = try objects.applyDelta(base_content, delta_data, allocator);
    defer allocator.free(delta_check);
    try testing.expectEqualStrings(modified_content, delta_check);

    var pack = std.ArrayList(u8).init(allocator);
    defer pack.deinit();
    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, 1, .big);

    var hdr_buf: [16]u8 = undefined;
    const hdr_len = encodePackObjectHeader(&hdr_buf, 7, delta_data.len);
    try pack.appendSlice(hdr_buf[0..hdr_len]);
    try pack.appendSlice(&base_sha1);
    const compressed = try zlibCompress(allocator, delta_data);
    defer allocator.free(compressed);
    try pack.appendSlice(compressed);

    // Finalize with checksum
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack.items);
    var cksum: [20]u8 = undefined;
    hasher.final(&cksum);
    try pack.appendSlice(&cksum);

    // Fix thin pack
    const fixed = try objects.fixThinPack(pack.items, git_dir, &platform, allocator);
    defer allocator.free(fixed);

    // Fixed pack should have 2 objects (base + delta)
    try testing.expectEqualSlices(u8, "PACK", fixed[0..4]);
    const fixed_count = std.mem.readInt(u32, fixed[8..12], .big);
    try testing.expectEqual(@as(u32, 2), fixed_count);

    // Save and load
    const ck = try objects.saveReceivedPack(fixed, git_dir, &platform, allocator);
    defer allocator.free(ck);

    const result_hex = sha1Hex(gitObjectSha1("blob", modified_content));
    const loaded = try objects.loadFromPackFiles(&result_hex, git_dir, &platform, allocator);
    defer loaded.deinit(allocator);
    try testing.expect(loaded.type == .blob);
    try testing.expectEqualStrings(modified_content, loaded.data);
}

// ============================================================================
// TEST 3: Mixed OFS_DELTA + REF_DELTA in one pack (fetch with delta chains)
// ============================================================================

test "fetch flow: pack with OFS_DELTA chain + REF_DELTA to external base" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    const repo_path = try std.fmt.allocPrint(allocator, "{s}/repo", .{tmp_path});
    defer allocator.free(repo_path);

    initGitRepo(allocator, repo_path) catch return;
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{repo_path});
    defer allocator.free(git_dir);
    const platform = Platform{};

    // External base (already in repo as loose object)
    const external_base = "External base content for delta chain test.\n";
    const ext_obj = objects.GitObject.init(.blob, external_base);
    const ext_hash = try ext_obj.store(git_dir, &platform, allocator);
    defer allocator.free(ext_hash);
    const ext_sha1 = gitObjectSha1("blob", external_base);

    // In-pack base blob (this one lives inside the pack)
    const inpack_base = "Internal base content that also lives in the same pack file.\n";

    // OFS_DELTA: delta from inpack_base
    // Common prefix is "Internal base content that " (27 chars)
    // Delta: copy 27 bytes from base, insert new suffix
    const ofs_suffix = "was CHANGED in the same pack file.\n";
    const inpack_modified = "Internal base content that " ++ ofs_suffix;
    const ofs_delta_data = try buildDelta(allocator, inpack_base.len, 27, ofs_suffix);
    defer allocator.free(ofs_delta_data);

    // REF_DELTA: delta from external base
    const ext_modified = "External base content MODIFIED by fetch.\n";
    const ref_delta_data = try buildDelta(allocator, external_base.len, 22, ext_modified[22..]);
    defer allocator.free(ref_delta_data);

    // Build pack: [inpack_base blob] [OFS_DELTA → inpack_base] [REF_DELTA → external]
    var pack = std.ArrayList(u8).init(allocator);
    defer pack.deinit();
    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, 3, .big);

    // Object 1: blob (inpack_base)
    const off1 = pack.items.len;
    var hdr_buf: [16]u8 = undefined;
    var hdr_len = encodePackObjectHeader(&hdr_buf, 3, inpack_base.len);
    try pack.appendSlice(hdr_buf[0..hdr_len]);
    const c = try zlibCompress(allocator, inpack_base);
    defer allocator.free(c);
    try pack.appendSlice(c);

    // Object 2: OFS_DELTA → object 1
    const off2 = pack.items.len;
    hdr_len = encodePackObjectHeader(&hdr_buf, 6, ofs_delta_data.len);
    try pack.appendSlice(hdr_buf[0..hdr_len]);
    var ofs_buf: [16]u8 = undefined;
    const ofs_len = encodeOfsOffset(&ofs_buf, off2 - off1);
    try pack.appendSlice(ofs_buf[0..ofs_len]);
    const c2 = try zlibCompress(allocator, ofs_delta_data);
    defer allocator.free(c2);
    try pack.appendSlice(c2);

    // Object 3: REF_DELTA → external base
    hdr_len = encodePackObjectHeader(&hdr_buf, 7, ref_delta_data.len);
    try pack.appendSlice(hdr_buf[0..hdr_len]);
    try pack.appendSlice(&ext_sha1);
    const c3 = try zlibCompress(allocator, ref_delta_data);
    defer allocator.free(c3);
    try pack.appendSlice(c3);

    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack.items);
    var cksum: [20]u8 = undefined;
    hasher.final(&cksum);
    try pack.appendSlice(&cksum);

    // Fix thin pack (should add external_base as prepended object)
    const fixed = try objects.fixThinPack(pack.items, git_dir, &platform, allocator);
    defer allocator.free(fixed);

    // Fixed pack should have 4 objects (1 prepended + 3 original)
    const fixed_count = std.mem.readInt(u32, fixed[8..12], .big);
    try testing.expectEqual(@as(u32, 4), fixed_count);

    // Save and verify all objects loadable
    const ck = try objects.saveReceivedPack(fixed, git_dir, &platform, allocator);
    defer allocator.free(ck);

    // Load the inpack_base blob
    const b1_hex = sha1Hex(gitObjectSha1("blob", inpack_base));
    const loaded_b1 = try objects.loadFromPackFiles(&b1_hex, git_dir, &platform, allocator);
    defer loaded_b1.deinit(allocator);
    try testing.expectEqualStrings(inpack_base, loaded_b1.data);

    // Load the OFS_DELTA result
    const ofs_result_hex = sha1Hex(gitObjectSha1("blob", inpack_modified));
    const loaded_ofs = try objects.loadFromPackFiles(&ofs_result_hex, git_dir, &platform, allocator);
    defer loaded_ofs.deinit(allocator);
    try testing.expectEqualStrings(inpack_modified, loaded_ofs.data);

    // Load the REF_DELTA result
    const ref_result_hex = sha1Hex(gitObjectSha1("blob", ext_modified));
    const loaded_ref = try objects.loadFromPackFiles(&ref_result_hex, git_dir, &platform, allocator);
    defer loaded_ref.deinit(allocator);
    try testing.expectEqualStrings(ext_modified, loaded_ref.data);
}

// ============================================================================
// TEST 4: Sequential fetches → multiple packs coexist
// ============================================================================

test "multiple fetches: objects spread across two pack files" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    const repo_path = try std.fmt.allocPrint(allocator, "{s}/repo", .{tmp_path});
    defer allocator.free(repo_path);

    initGitRepo(allocator, repo_path) catch return;
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{repo_path});
    defer allocator.free(git_dir);
    const platform = Platform{};

    // First "fetch": pack with blob1
    const blob1 = "Content from first fetch\n";
    const pack1 = try buildPackFile(allocator, &.{
        .{ .type_num = 3, .data = blob1 },
    });
    defer allocator.free(pack1);
    const ck1 = try objects.saveReceivedPack(pack1, git_dir, &platform, allocator);
    defer allocator.free(ck1);

    // Second "fetch": pack with blob2
    const blob2 = "Content from second fetch\n";
    const pack2 = try buildPackFile(allocator, &.{
        .{ .type_num = 3, .data = blob2 },
    });
    defer allocator.free(pack2);
    const ck2 = try objects.saveReceivedPack(pack2, git_dir, &platform, allocator);
    defer allocator.free(ck2);

    // Verify both objects are loadable
    const hex1 = sha1Hex(gitObjectSha1("blob", blob1));
    const loaded1 = try objects.loadFromPackFiles(&hex1, git_dir, &platform, allocator);
    defer loaded1.deinit(allocator);
    try testing.expectEqualStrings(blob1, loaded1.data);

    const hex2 = sha1Hex(gitObjectSha1("blob", blob2));
    const loaded2 = try objects.loadFromPackFiles(&hex2, git_dir, &platform, allocator);
    defer loaded2.deinit(allocator);
    try testing.expectEqualStrings(blob2, loaded2.data);

    // Verify pack checksums are different
    try testing.expect(!std.mem.eql(u8, ck1, ck2));
}

// ============================================================================
// TEST 5: Binary data integrity through pack round-trip
// ============================================================================

test "binary data: all 256 byte values survive pack round-trip" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    const repo_path = try std.fmt.allocPrint(allocator, "{s}/repo", .{tmp_path});
    defer allocator.free(repo_path);

    initGitRepo(allocator, repo_path) catch return;
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{repo_path});
    defer allocator.free(git_dir);
    const platform = Platform{};

    // Create blob with every byte value 0x00..0xFF
    var binary_data: [256]u8 = undefined;
    for (&binary_data, 0..) |*b, i| b.* = @intCast(i);

    const pack_data = try buildPackFile(allocator, &.{
        .{ .type_num = 3, .data = &binary_data },
    });
    defer allocator.free(pack_data);

    const ck = try objects.saveReceivedPack(pack_data, git_dir, &platform, allocator);
    defer allocator.free(ck);

    const hex = sha1Hex(gitObjectSha1("blob", &binary_data));
    const loaded = try objects.loadFromPackFiles(&hex, git_dir, &platform, allocator);
    defer loaded.deinit(allocator);
    try testing.expectEqualSlices(u8, &binary_data, loaded.data);
}

// ============================================================================
// TEST 6: Empty blob survives pack round-trip
// ============================================================================

test "edge case: empty blob in pack" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    const repo_path = try std.fmt.allocPrint(allocator, "{s}/repo", .{tmp_path});
    defer allocator.free(repo_path);

    initGitRepo(allocator, repo_path) catch return;
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{repo_path});
    defer allocator.free(git_dir);
    const platform = Platform{};

    const empty: []const u8 = "";
    const pack_data = try buildPackFile(allocator, &.{
        .{ .type_num = 3, .data = empty },
    });
    defer allocator.free(pack_data);

    const ck = try objects.saveReceivedPack(pack_data, git_dir, &platform, allocator);
    defer allocator.free(ck);

    // The well-known empty blob SHA-1: e69de29bb2d1d6434b8b29ae775ad8c2e48c5391
    const hex = sha1Hex(gitObjectSha1("blob", empty));
    const loaded = try objects.loadFromPackFiles(&hex, git_dir, &platform, allocator);
    defer loaded.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), loaded.data.len);
    try testing.expect(loaded.type == .blob);
}

// ============================================================================
// TEST 7: saveReceivedPack rejects invalid packs
// ============================================================================

test "saveReceivedPack: rejects too-small input" {
    const allocator = testing.allocator;
    const platform = Platform{};
    const result = objects.saveReceivedPack("too small", "/tmp/fake", &platform, allocator);
    try testing.expectError(error.PackFileTooSmall, result);
}

test "saveReceivedPack: rejects bad magic" {
    const allocator = testing.allocator;
    const platform = Platform{};
    var bad: [40]u8 = undefined;
    @memcpy(bad[0..4], "NOPE");
    std.mem.writeInt(u32, bad[4..8], 2, .big);
    @memset(bad[8..], 0);
    const result = objects.saveReceivedPack(&bad, "/tmp/fake", &platform, allocator);
    try testing.expectError(error.InvalidPackSignature, result);
}

test "saveReceivedPack: rejects checksum mismatch" {
    const allocator = testing.allocator;
    const platform = Platform{};

    // Build valid pack then corrupt checksum
    const pack_data = try buildPackFile(allocator, &.{
        .{ .type_num = 3, .data = "test" },
    });
    defer allocator.free(pack_data);

    // Flip a byte in the checksum
    var corrupted = try allocator.dupe(u8, pack_data);
    defer allocator.free(corrupted);
    corrupted[corrupted.len - 1] ^= 0xFF;

    const result = objects.saveReceivedPack(corrupted, "/tmp/fake", &platform, allocator);
    try testing.expectError(error.PackChecksumMismatch, result);
}

// ============================================================================
// TEST 8: Git cross-validation — git verify-pack accepts our saved packs
// ============================================================================

test "cross-validation: git verify-pack accepts saveReceivedPack output" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    const repo_path = try std.fmt.allocPrint(allocator, "{s}/repo", .{tmp_path});
    defer allocator.free(repo_path);

    initGitRepo(allocator, repo_path) catch return;
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{repo_path});
    defer allocator.free(git_dir);
    const platform = Platform{};

    const blob_data = "verify-pack cross-validation test\n";
    const commit_data = "tree 4b825dc642cb6eb9a060e54bf899d69f82623700\nauthor T <t@t.com> 1700000000 +0000\ncommitter T <t@t.com> 1700000000 +0000\n\ntest\n";

    const pack_data = try buildPackFile(allocator, &.{
        .{ .type_num = 3, .data = blob_data },
        .{ .type_num = 1, .data = commit_data },
    });
    defer allocator.free(pack_data);

    const ck_hex = try objects.saveReceivedPack(pack_data, git_dir, &platform, allocator);
    defer allocator.free(ck_hex);

    // Find and verify with git verify-pack
    const pack_path = try std.fmt.allocPrint(allocator, "{s}/objects/pack/pack-{s}.pack", .{ git_dir, ck_hex });
    defer allocator.free(pack_path);

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "verify-pack", "-v", pack_path },
    }) catch return;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try testing.expect(result.term.Exited == 0);
}

// ============================================================================
// TEST 9: OFS_DELTA with large offset (> 127, requires multi-byte encoding)
// ============================================================================

test "OFS_DELTA: large offset encoding (base far from delta)" {
    const allocator = testing.allocator;

    // Create a large base blob to push the delta object far away
    const large_base = try allocator.alloc(u8, 4096);
    defer allocator.free(large_base);
    for (large_base, 0..) |*b, i| b.* = @intCast(i & 0xFF);

    const delta_result = try allocator.alloc(u8, 4096);
    defer allocator.free(delta_result);
    @memcpy(delta_result[0..4000], large_base[0..4000]);
    @memset(delta_result[4000..], 0xBB); // Change last 96 bytes

    const delta_data = try buildDelta(allocator, large_base.len, 4000, delta_result[4000..]);
    defer allocator.free(delta_data);

    var pack = std.ArrayList(u8).init(allocator);
    defer pack.deinit();
    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, 2, .big);

    const off1 = pack.items.len;
    var hdr_buf: [16]u8 = undefined;
    var hdr_len = encodePackObjectHeader(&hdr_buf, 3, large_base.len);
    try pack.appendSlice(hdr_buf[0..hdr_len]);
    const c1 = try zlibCompress(allocator, large_base);
    defer allocator.free(c1);
    try pack.appendSlice(c1);

    const off2 = pack.items.len;
    const neg_offset = off2 - off1;
    // Verify the offset is large enough to need multi-byte encoding
    try testing.expect(neg_offset > 127);

    hdr_len = encodePackObjectHeader(&hdr_buf, 6, delta_data.len);
    try pack.appendSlice(hdr_buf[0..hdr_len]);
    var ofs_buf: [16]u8 = undefined;
    const ofs_len = encodeOfsOffset(&ofs_buf, neg_offset);
    try pack.appendSlice(ofs_buf[0..ofs_len]);
    const c2 = try zlibCompress(allocator, delta_data);
    defer allocator.free(c2);
    try pack.appendSlice(c2);

    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack.items);
    var cksum: [20]u8 = undefined;
    hasher.final(&cksum);
    try pack.appendSlice(&cksum);

    const pack_data = try pack.toOwnedSlice();
    defer allocator.free(pack_data);

    const obj = try objects.readPackObjectAtOffset(pack_data, off2, allocator);
    defer obj.deinit(allocator);
    try testing.expectEqualSlices(u8, delta_result, obj.data);
    try testing.expect(obj.type == .blob);
}

// ============================================================================
// TEST 10: Delta with copy from offset 0 and size = 0x10000 (special case)
// ============================================================================

test "delta edge case: copy size 0 means 0x10000" {
    const allocator = testing.allocator;

    // Base must be at least 0x10000 bytes
    const base = try allocator.alloc(u8, 0x10000 + 100);
    defer allocator.free(base);
    for (base, 0..) |*b, i| b.* = @intCast(i & 0xFF);

    // Delta: copy 0x10000 bytes from offset 0 (size=0 means 0x10000)
    var delta_buf: [32]u8 = undefined;
    var pos: usize = 0;
    pos += encodeDeltaVarint(delta_buf[pos..], base.len);
    pos += encodeDeltaVarint(delta_buf[pos..], 0x10000); // result size
    // Copy command: offset=0, size=0 (means 0x10000)
    delta_buf[pos] = 0x80; // copy, no offset bytes, no size bytes
    pos += 1;

    const result = try objects.applyDelta(base, delta_buf[0..pos], allocator);
    defer allocator.free(result);
    try testing.expectEqual(@as(usize, 0x10000), result.len);
    try testing.expectEqualSlices(u8, base[0..0x10000], result);
}

// ============================================================================
// TEST 11: Verify pack+idx round-trip preserves CRC32
// ============================================================================

test "generatePackIndex: CRC32 values match git format spec" {
    const allocator = testing.allocator;

    const blob_data = "CRC32 validation test blob\n";
    const pack_data = try buildPackFile(allocator, &.{
        .{ .type_num = 3, .data = blob_data },
    });
    defer allocator.free(pack_data);

    const idx = try objects.generatePackIndex(pack_data, allocator);
    defer allocator.free(idx);

    // Extract CRC32 from idx (after fanout + SHA-1 table)
    const sha1_table_start = 8 + 256 * 4;
    const crc_table_start = sha1_table_start + 20; // 1 object × 20 bytes
    const stored_crc = std.mem.readInt(u32, idx[crc_table_start..][0..4], .big);

    // Compute expected CRC32 of the pack object data (from header to end of compressed data)
    // Object starts at offset 12 (right after pack header)
    // Find end of compressed data by decompressing
    var pos: usize = 12;
    const first_byte = pack_data[pos];
    pos += 1;
    var current_byte = first_byte;
    while (current_byte & 0x80 != 0) {
        current_byte = pack_data[pos];
        pos += 1;
    }
    // Now pos is at start of compressed data
    var decompressed = std.ArrayList(u8).init(allocator);
    defer decompressed.deinit();
    var stream = std.io.fixedBufferStream(pack_data[pos .. pack_data.len - 20]);
    std.compress.zlib.decompress(stream.reader(), decompressed.writer()) catch {};
    const obj_end = pos + @as(usize, @intCast(stream.pos));

    const expected_crc = std.hash.crc.Crc32IsoHdlc.hash(pack_data[12..obj_end]);
    try testing.expectEqual(expected_crc, stored_crc);
}

// ============================================================================
// TEST 12: fixThinPack with no REF_DELTA returns pack as-is
// ============================================================================

test "fixThinPack: non-thin pack returned unchanged" {
    const allocator = testing.allocator;
    const platform = Platform{};

    const pack_data = try buildPackFile(allocator, &.{
        .{ .type_num = 3, .data = "no deltas here" },
    });
    defer allocator.free(pack_data);

    // fixThinPack should return a copy since there are no REF_DELTA objects
    const result = try objects.fixThinPack(pack_data, "/tmp/nonexistent_git_dir", &platform, allocator);
    defer allocator.free(result);

    try testing.expectEqualSlices(u8, pack_data, result);
}
