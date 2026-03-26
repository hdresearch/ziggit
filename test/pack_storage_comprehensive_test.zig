const std = @import("std");
const pack_writer = @import("pack_writer");
const idx_writer = @import("idx_writer");

// ============================================================================
// Helpers
// ============================================================================

const PackObject = struct {
    type_str: []const u8,
    data: []const u8,
};

fn buildPackFile(allocator: std.mem.Allocator, objects: []const PackObject) ![]u8 {
    var pack = std.ArrayList(u8).init(allocator);
    errdefer pack.deinit();

    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, @intCast(objects.len), .big);

    for (objects) |obj| {
        const obj_type: u3 = if (std.mem.eql(u8, obj.type_str, "commit"))
            1
        else if (std.mem.eql(u8, obj.type_str, "tree"))
            2
        else if (std.mem.eql(u8, obj.type_str, "blob"))
            3
        else if (std.mem.eql(u8, obj.type_str, "tag"))
            4
        else
            unreachable;

        var size = obj.data.len;
        var first_byte: u8 = (@as(u8, obj_type) << 4) | @as(u8, @intCast(size & 0x0F));
        size >>= 4;
        if (size > 0) first_byte |= 0x80;
        try pack.append(first_byte);
        while (size > 0) {
            var b: u8 = @intCast(size & 0x7F);
            size >>= 7;
            if (size > 0) b |= 0x80;
            try pack.append(b);
        }

        var compressed = std.ArrayList(u8).init(allocator);
        defer compressed.deinit();
        var compressor = try std.compress.zlib.compressor(compressed.writer(), .{});
        try compressor.writer().writeAll(obj.data);
        try compressor.finish();
        try pack.appendSlice(compressed.items);
    }

    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack.items);
    var checksum: [20]u8 = undefined;
    hasher.final(&checksum);
    try pack.appendSlice(&checksum);
    return pack.toOwnedSlice();
}

fn encodePackHeader(buf: *std.ArrayList(u8), obj_type: u3, size: usize) !void {
    var s = size;
    var first_byte: u8 = (@as(u8, obj_type) << 4) | @as(u8, @intCast(s & 0x0F));
    s >>= 4;
    if (s > 0) first_byte |= 0x80;
    try buf.append(first_byte);
    while (s > 0) {
        var b: u8 = @intCast(s & 0x7F);
        s >>= 7;
        if (s > 0) b |= 0x80;
        try buf.append(b);
    }
}

fn compressData(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var compressed = std.ArrayList(u8).init(allocator);
    errdefer compressed.deinit();
    var compressor = try std.compress.zlib.compressor(compressed.writer(), .{});
    try compressor.writer().writeAll(data);
    try compressor.finish();
    return compressed.toOwnedSlice();
}

fn encodeDeltaVarint(buf: *std.ArrayList(u8), value: usize) !void {
    var v = value;
    while (true) {
        var b: u8 = @intCast(v & 0x7F);
        v >>= 7;
        if (v > 0) b |= 0x80;
        try buf.append(b);
        if (v == 0) break;
    }
}

fn encodeOfsOffset(buf: *std.ArrayList(u8), negative_offset: usize) !void {
    var offset = negative_offset;
    var bytes: [10]u8 = undefined;
    var n: usize = 0;
    bytes[n] = @intCast(offset & 0x7F);
    n += 1;
    offset >>= 7;
    while (offset > 0) {
        offset -= 1;
        bytes[n] = @intCast(0x80 | (offset & 0x7F));
        n += 1;
        offset >>= 7;
    }
    while (n > 0) {
        n -= 1;
        try buf.append(bytes[n]);
    }
}

/// Build delta: copy base_size bytes from base, then insert extra data
fn buildCopyInsertDelta(allocator: std.mem.Allocator, base_size: usize, result_data: []const u8) ![]u8 {
    var delta = std.ArrayList(u8).init(allocator);
    errdefer delta.deinit();

    try encodeDeltaVarint(&delta, base_size);
    try encodeDeltaVarint(&delta, result_data.len);

    // Copy command: copy base_size bytes from offset 0
    if (base_size > 0) {
        var cmd: u8 = 0x80;
        if (base_size & 0xFF != 0) cmd |= 0x10;
        if ((base_size >> 8) & 0xFF != 0) cmd |= 0x20;
        try delta.append(cmd);
        if (base_size & 0xFF != 0) try delta.append(@intCast(base_size & 0xFF));
        if ((base_size >> 8) & 0xFF != 0) try delta.append(@intCast((base_size >> 8) & 0xFF));
    }

    // Insert the extra data
    const extra = result_data[base_size..];
    if (extra.len > 0 and extra.len < 128) {
        try delta.append(@intCast(extra.len));
        try delta.appendSlice(extra);
    }

    return delta.toOwnedSlice();
}

fn setupTmpDir() ![]const u8 {
    const allocator = std.testing.allocator;
    const tmp = try std.fmt.allocPrint(allocator, "/tmp/ziggit_storage_test_{}", .{std.crypto.random.int(u64)});
    try std.fs.cwd().makePath(tmp);
    return tmp;
}

fn cleanupTmpDir(path: []const u8) void {
    std.fs.cwd().deleteTree(path) catch {};
    std.testing.allocator.free(path);
}

fn gitHashObject(allocator: std.mem.Allocator, type_str: []const u8, data: []const u8) [20]u8 {
    var h = std.crypto.hash.Sha1.init(.{});
    var hdr_buf: [64]u8 = undefined;
    const hdr = std.fmt.bufPrint(&hdr_buf, "{s} {}\x00", .{ type_str, data.len }) catch unreachable;
    h.update(hdr);
    h.update(data);
    var sha: [20]u8 = undefined;
    h.final(&sha);
    _ = allocator;
    return sha;
}

// ============================================================================
// REF_DELTA idx generation tests
// ============================================================================

test "generateIdxFromData with REF_DELTA object" {
    const allocator = std.testing.allocator;

    // Build pack: base blob + REF_DELTA referencing it by SHA-1
    const base_data = "Hello REF_DELTA base\n";
    const delta_target = "Hello REF_DELTA base\nAppended line\n";

    // Compute base SHA-1 (what git hash-object would produce)
    const base_sha = gitHashObject(allocator, "blob", base_data);

    var pack = std.ArrayList(u8).init(allocator);
    defer pack.deinit();

    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, 2, .big); // 2 objects

    // Object 1: base blob
    try encodePackHeader(&pack, 3, base_data.len);
    const base_comp = try compressData(allocator, base_data);
    defer allocator.free(base_comp);
    try pack.appendSlice(base_comp);

    // Object 2: REF_DELTA (type=7) referencing base by SHA-1
    const delta_instr = try buildCopyInsertDelta(allocator, base_data.len, delta_target);
    defer allocator.free(delta_instr);
    try encodePackHeader(&pack, 7, delta_instr.len);
    try pack.appendSlice(&base_sha); // 20-byte base SHA-1
    const delta_comp = try compressData(allocator, delta_instr);
    defer allocator.free(delta_comp);
    try pack.appendSlice(delta_comp);

    // Pack checksum
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack.items);
    var cksum: [20]u8 = undefined;
    hasher.final(&cksum);
    try pack.appendSlice(&cksum);

    // Generate idx
    const idx_data = try idx_writer.generateIdxFromData(allocator, pack.items);
    defer allocator.free(idx_data);

    // Should have 2 objects
    const fanout_end = 8 + 256 * 4;
    const total = std.mem.readInt(u32, idx_data[fanout_end - 4 ..][0..4], .big);
    try std.testing.expectEqual(@as(u32, 2), total);

    // SHA-1 entries should be sorted
    const sha_start = fanout_end;
    const sha1 = idx_data[sha_start..][0..20];
    const sha2 = idx_data[sha_start + 20 ..][0..20];
    try std.testing.expect(std.mem.order(u8, sha1, sha2) == .lt);
}

test "git verify-pack accepts REF_DELTA pack" {
    const allocator = std.testing.allocator;
    const tmp_dir = try setupTmpDir();
    defer cleanupTmpDir(tmp_dir);

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_dir});
    defer allocator.free(git_dir);
    {
        const r = try std.process.Child.run(.{ .allocator = allocator, .argv = &.{ "git", "init", "--bare", git_dir } });
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }

    const base_data = "REF_DELTA verify base content\n";
    const delta_target = "REF_DELTA verify base content\nExtra!\n";
    const base_sha = gitHashObject(allocator, "blob", base_data);

    var pack = std.ArrayList(u8).init(allocator);
    defer pack.deinit();

    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, 2, .big);

    try encodePackHeader(&pack, 3, base_data.len);
    const base_comp = try compressData(allocator, base_data);
    defer allocator.free(base_comp);
    try pack.appendSlice(base_comp);

    const delta_instr = try buildCopyInsertDelta(allocator, base_data.len, delta_target);
    defer allocator.free(delta_instr);
    try encodePackHeader(&pack, 7, delta_instr.len);
    try pack.appendSlice(&base_sha);
    const delta_comp = try compressData(allocator, delta_instr);
    defer allocator.free(delta_comp);
    try pack.appendSlice(delta_comp);

    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack.items);
    var cksum: [20]u8 = undefined;
    hasher.final(&cksum);
    try pack.appendSlice(&cksum);

    // Save and generate idx
    const hex = try std.fmt.allocPrint(allocator, "{s}", .{std.fmt.fmtSliceHexLower(&cksum)});
    defer allocator.free(hex);
    const pack_dir = try std.fmt.allocPrint(allocator, "{s}/objects/pack", .{git_dir});
    defer allocator.free(pack_dir);
    std.fs.cwd().makePath(pack_dir) catch {};
    const pack_path = try std.fmt.allocPrint(allocator, "{s}/pack-{s}.pack", .{ pack_dir, hex });
    defer allocator.free(pack_path);
    {
        const f = try std.fs.cwd().createFile(pack_path, .{});
        defer f.close();
        try f.writeAll(pack.items);
    }
    try idx_writer.generateIdx(allocator, pack_path);

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .max_output_bytes = 10 * 1024 * 1024,
        .argv = &.{ "git", "verify-pack", "-v", pack_path },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(@as(u8, 0), result.term.Exited);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "blob") != null);
}

// ============================================================================
// Multi-level OFS_DELTA chain tests
// ============================================================================

test "generateIdxFromData with chained OFS_DELTAs (base -> delta1 -> delta2)" {
    const allocator = std.testing.allocator;

    const base_data = "Line 1\n";
    const target1 = "Line 1\nLine 2\n";
    const target2 = "Line 1\nLine 2\nLine 3\n";

    var pack = std.ArrayList(u8).init(allocator);
    defer pack.deinit();

    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, 3, .big); // 3 objects

    // Object 1: base blob
    const base_offset = pack.items.len;
    try encodePackHeader(&pack, 3, base_data.len);
    const base_comp = try compressData(allocator, base_data);
    defer allocator.free(base_comp);
    try pack.appendSlice(base_comp);

    // Object 2: OFS_DELTA based on object 1
    const delta1_offset = pack.items.len;
    const delta1_instr = try buildCopyInsertDelta(allocator, base_data.len, target1);
    defer allocator.free(delta1_instr);
    try encodePackHeader(&pack, 6, delta1_instr.len);
    try encodeOfsOffset(&pack, delta1_offset - base_offset);
    const delta1_comp = try compressData(allocator, delta1_instr);
    defer allocator.free(delta1_comp);
    try pack.appendSlice(delta1_comp);

    // Object 3: OFS_DELTA based on object 2 (delta of delta!)
    const delta2_offset = pack.items.len;
    const delta2_instr = try buildCopyInsertDelta(allocator, target1.len, target2);
    defer allocator.free(delta2_instr);
    try encodePackHeader(&pack, 6, delta2_instr.len);
    try encodeOfsOffset(&pack, delta2_offset - delta1_offset);
    const delta2_comp = try compressData(allocator, delta2_instr);
    defer allocator.free(delta2_comp);
    try pack.appendSlice(delta2_comp);

    // Pack checksum
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack.items);
    var cksum: [20]u8 = undefined;
    hasher.final(&cksum);
    try pack.appendSlice(&cksum);

    const idx_data = try idx_writer.generateIdxFromData(allocator, pack.items);
    defer allocator.free(idx_data);

    // Should have 3 objects
    const fanout_end = 8 + 256 * 4;
    const total = std.mem.readInt(u32, idx_data[fanout_end - 4 ..][0..4], .big);
    try std.testing.expectEqual(@as(u32, 3), total);

    // Verify SHA-1 correctness: the resolved delta2 should match git hash-object of target2
    const expected_base_sha = gitHashObject(allocator, "blob", base_data);
    const expected_t1_sha = gitHashObject(allocator, "blob", target1);
    const expected_t2_sha = gitHashObject(allocator, "blob", target2);

    // Collect all 3 SHA-1s from idx
    const sha_start = fanout_end;
    var found = [3]bool{ false, false, false };
    for (0..3) |i| {
        const sha = idx_data[sha_start + i * 20 ..][0..20];
        if (std.mem.eql(u8, sha, &expected_base_sha)) found[0] = true;
        if (std.mem.eql(u8, sha, &expected_t1_sha)) found[1] = true;
        if (std.mem.eql(u8, sha, &expected_t2_sha)) found[2] = true;
    }
    try std.testing.expect(found[0]); // base blob found
    try std.testing.expect(found[1]); // delta1 resolved correctly
    try std.testing.expect(found[2]); // delta2 (chained) resolved correctly
}

test "git verify-pack accepts chained OFS_DELTAs" {
    const allocator = std.testing.allocator;
    const tmp_dir = try setupTmpDir();
    defer cleanupTmpDir(tmp_dir);

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_dir});
    defer allocator.free(git_dir);
    {
        const r = try std.process.Child.run(.{ .allocator = allocator, .argv = &.{ "git", "init", "--bare", git_dir } });
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }

    const base_data = "Chain base\n";
    const target1 = "Chain base\nChain delta 1\n";
    const target2 = "Chain base\nChain delta 1\nChain delta 2\n";

    var pack = std.ArrayList(u8).init(allocator);
    defer pack.deinit();

    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, 3, .big);

    const base_offset = pack.items.len;
    try encodePackHeader(&pack, 3, base_data.len);
    const bc = try compressData(allocator, base_data);
    defer allocator.free(bc);
    try pack.appendSlice(bc);

    const d1_offset = pack.items.len;
    const d1 = try buildCopyInsertDelta(allocator, base_data.len, target1);
    defer allocator.free(d1);
    try encodePackHeader(&pack, 6, d1.len);
    try encodeOfsOffset(&pack, d1_offset - base_offset);
    const d1c = try compressData(allocator, d1);
    defer allocator.free(d1c);
    try pack.appendSlice(d1c);

    const d2_offset = pack.items.len;
    const d2 = try buildCopyInsertDelta(allocator, target1.len, target2);
    defer allocator.free(d2);
    try encodePackHeader(&pack, 6, d2.len);
    try encodeOfsOffset(&pack, d2_offset - d1_offset);
    const d2c = try compressData(allocator, d2);
    defer allocator.free(d2c);
    try pack.appendSlice(d2c);

    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack.items);
    var cksum: [20]u8 = undefined;
    hasher.final(&cksum);
    try pack.appendSlice(&cksum);

    const hex = try std.fmt.allocPrint(allocator, "{s}", .{std.fmt.fmtSliceHexLower(&cksum)});
    defer allocator.free(hex);
    const pack_dir = try std.fmt.allocPrint(allocator, "{s}/objects/pack", .{git_dir});
    defer allocator.free(pack_dir);
    std.fs.cwd().makePath(pack_dir) catch {};
    const pack_path = try std.fmt.allocPrint(allocator, "{s}/pack-{s}.pack", .{ pack_dir, hex });
    defer allocator.free(pack_path);
    {
        const f = try std.fs.cwd().createFile(pack_path, .{});
        defer f.close();
        try f.writeAll(pack.items);
    }
    try idx_writer.generateIdx(allocator, pack_path);

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .max_output_bytes = 10 * 1024 * 1024,
        .argv = &.{ "git", "verify-pack", "-v", pack_path },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(@as(u8, 0), result.term.Exited);
}

// ============================================================================
// Git-created pack interop (git gc, then our idx generation)
// ============================================================================

test "idx from git-created pack matches git verify-pack" {
    const allocator = std.testing.allocator;
    const tmp_dir = try setupTmpDir();
    defer cleanupTmpDir(tmp_dir);

    // Create a real git repo with multiple commits to trigger delta compression
    const repo_dir = try std.fmt.allocPrint(allocator, "{s}/real_repo", .{tmp_dir});
    defer allocator.free(repo_dir);

    inline for ([_][]const u8{
        "git init {s}",
        "git -C {s} config user.email test@test.com",
        "git -C {s} config user.name Test",
    }) |cmd_fmt| {
        const cmd = try std.fmt.allocPrint(allocator, cmd_fmt, .{repo_dir});
        defer allocator.free(cmd);
        const r = try std.process.Child.run(.{ .allocator = allocator, .argv = &.{ "bash", "-c", cmd } });
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }

    // Create multiple files and commits (to create delta objects on gc)
    for (0..5) |i| {
        var content_buf: [128]u8 = undefined;
        const content = std.fmt.bufPrint(&content_buf, "Version {}\nSome shared content that will delta well.\nLine3\nLine4\n", .{i}) catch unreachable;
        const file_path = try std.fmt.allocPrint(allocator, "{s}/file.txt", .{repo_dir});
        defer allocator.free(file_path);
        {
            const f = try std.fs.cwd().createFile(file_path, .{});
            defer f.close();
            try f.writeAll(content);
        }

        const add_cmd = try std.fmt.allocPrint(allocator, "git -C {s} add file.txt", .{repo_dir});
        defer allocator.free(add_cmd);
        const add_r = try std.process.Child.run(.{ .allocator = allocator, .argv = &.{ "bash", "-c", add_cmd } });
        allocator.free(add_r.stdout);
        allocator.free(add_r.stderr);

        var msg_buf: [32]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "commit {}", .{i}) catch unreachable;
        const commit_cmd = try std.fmt.allocPrint(allocator, "git -C {s} commit -m '{s}'", .{ repo_dir, msg });
        defer allocator.free(commit_cmd);
        const commit_r = try std.process.Child.run(.{ .allocator = allocator, .argv = &.{ "bash", "-c", commit_cmd } });
        allocator.free(commit_r.stdout);
        allocator.free(commit_r.stderr);
    }

    // Run git gc to create pack with deltas
    {
        const gc_cmd = try std.fmt.allocPrint(allocator, "git -C {s} gc --aggressive", .{repo_dir});
        defer allocator.free(gc_cmd);
        const gc_r = try std.process.Child.run(.{ .allocator = allocator, .argv = &.{ "bash", "-c", gc_cmd } });
        allocator.free(gc_r.stdout);
        allocator.free(gc_r.stderr);
    }

    // Find the pack file created by git
    const pack_dir = try std.fmt.allocPrint(allocator, "{s}/.git/objects/pack", .{repo_dir});
    defer allocator.free(pack_dir);

    var dir = try std.fs.cwd().openDir(pack_dir, .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();

    var found_pack: ?[]u8 = null;
    defer if (found_pack) |fp| allocator.free(fp);

    while (try it.next()) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".pack")) {
            found_pack = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pack_dir, entry.name });
            break;
        }
    }

    const git_pack_path = found_pack orelse return error.NoPackFileFound;

    // Read the git-created pack
    const pack_data = try std.fs.cwd().readFileAlloc(allocator, git_pack_path, 512 * 1024 * 1024);
    defer allocator.free(pack_data);

    // Copy to new location and generate our idx
    const test_dir = try std.fmt.allocPrint(allocator, "{s}/test_idx", .{tmp_dir});
    defer allocator.free(test_dir);
    {
        const r = try std.process.Child.run(.{ .allocator = allocator, .argv = &.{ "git", "init", "--bare", test_dir } });
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }

    const checksum = try pack_writer.savePack(allocator, test_dir, pack_data);
    defer allocator.free(checksum);

    const our_pack_path = try pack_writer.packPath(allocator, test_dir, checksum);
    defer allocator.free(our_pack_path);
    try idx_writer.generateIdx(allocator, our_pack_path);

    // git verify-pack should accept our idx
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .max_output_bytes = 10 * 1024 * 1024,
        .argv = &.{ "git", "verify-pack", "-v", our_pack_path },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(@as(u8, 0), result.term.Exited);

    // Count objects in verify-pack output (should be >= 5 commits + trees + blobs)
    var obj_count: usize = 0;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len > 40 and (std.mem.indexOf(u8, line, "blob") != null or
            std.mem.indexOf(u8, line, "tree") != null or
            std.mem.indexOf(u8, line, "commit") != null))
        {
            obj_count += 1;
        }
    }
    try std.testing.expect(obj_count >= 10); // At least commits + trees + blobs
}

// ============================================================================
// Multiple pack files in same repo
// ============================================================================

test "multiple pack files coexist in objects/pack" {
    const allocator = std.testing.allocator;
    const tmp_dir = try setupTmpDir();
    defer cleanupTmpDir(tmp_dir);

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_dir});
    defer allocator.free(git_dir);
    {
        const r = try std.process.Child.run(.{ .allocator = allocator, .argv = &.{ "git", "init", "--bare", git_dir } });
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }

    // Save first pack
    const objs1 = [_]PackObject{
        .{ .type_str = "blob", .data = "pack one blob\n" },
    };
    const pack1 = try buildPackFile(allocator, &objs1);
    defer allocator.free(pack1);
    const hex1 = try pack_writer.savePack(allocator, git_dir, pack1);
    defer allocator.free(hex1);
    const pp1 = try pack_writer.packPath(allocator, git_dir, hex1);
    defer allocator.free(pp1);
    try idx_writer.generateIdx(allocator, pp1);

    // Save second pack (different content → different checksum)
    const objs2 = [_]PackObject{
        .{ .type_str = "blob", .data = "pack two blob\n" },
    };
    const pack2 = try buildPackFile(allocator, &objs2);
    defer allocator.free(pack2);
    const hex2 = try pack_writer.savePack(allocator, git_dir, pack2);
    defer allocator.free(hex2);
    const pp2 = try pack_writer.packPath(allocator, git_dir, hex2);
    defer allocator.free(pp2);
    try idx_writer.generateIdx(allocator, pp2);

    // Both should have different checksums
    try std.testing.expect(!std.mem.eql(u8, hex1, hex2));

    // Both packs should verify
    {
        const r = try std.process.Child.run(.{
            .allocator = allocator,
            .max_output_bytes = 10 * 1024 * 1024,
            .argv = &.{ "git", "verify-pack", "-v", pp1 },
        });
        defer allocator.free(r.stdout);
        defer allocator.free(r.stderr);
        try std.testing.expectEqual(@as(u8, 0), r.term.Exited);
    }
    {
        const r = try std.process.Child.run(.{
            .allocator = allocator,
            .max_output_bytes = 10 * 1024 * 1024,
            .argv = &.{ "git", "verify-pack", "-v", pp2 },
        });
        defer allocator.free(r.stdout);
        defer allocator.free(r.stderr);
        try std.testing.expectEqual(@as(u8, 0), r.term.Exited);
    }
}

// ============================================================================
// HEAD preference: main > master > first branch
// ============================================================================

test "updateRefsAfterClone prefers main over master for HEAD" {
    const allocator = std.testing.allocator;
    const tmp_dir = try setupTmpDir();
    defer cleanupTmpDir(tmp_dir);

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_dir});
    defer allocator.free(git_dir);
    try std.fs.cwd().makePath(git_dir);
    {
        const d = try std.fmt.allocPrint(allocator, "{s}/refs/heads", .{git_dir});
        defer allocator.free(d);
        try std.fs.cwd().makePath(d);
    }

    const refs = [_]pack_writer.RefUpdate{
        .{ .name = "refs/heads/develop", .hash = "1111111111111111111111111111111111111111" },
        .{ .name = "refs/heads/master", .hash = "2222222222222222222222222222222222222222" },
        .{ .name = "refs/heads/main", .hash = "3333333333333333333333333333333333333333" },
    };
    try pack_writer.updateRefsAfterClone(allocator, git_dir, &refs, true);

    const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_dir});
    defer allocator.free(head_path);
    const content = try std.fs.cwd().readFileAlloc(allocator, head_path, 256);
    defer allocator.free(content);
    const trimmed = std.mem.trimRight(u8, content, "\n");
    // "main" should win since it's processed after "master"
    try std.testing.expectEqualStrings("ref: refs/heads/main", trimmed);
}

test "updateRefsAfterClone uses master when no main exists" {
    const allocator = std.testing.allocator;
    const tmp_dir = try setupTmpDir();
    defer cleanupTmpDir(tmp_dir);

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_dir});
    defer allocator.free(git_dir);
    try std.fs.cwd().makePath(git_dir);
    {
        const d = try std.fmt.allocPrint(allocator, "{s}/refs/heads", .{git_dir});
        defer allocator.free(d);
        try std.fs.cwd().makePath(d);
    }

    const refs = [_]pack_writer.RefUpdate{
        .{ .name = "refs/heads/feature", .hash = "1111111111111111111111111111111111111111" },
        .{ .name = "refs/heads/master", .hash = "2222222222222222222222222222222222222222" },
    };
    try pack_writer.updateRefsAfterClone(allocator, git_dir, &refs, true);

    const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_dir});
    defer allocator.free(head_path);
    const content = try std.fs.cwd().readFileAlloc(allocator, head_path, 256);
    defer allocator.free(content);
    const trimmed = std.mem.trimRight(u8, content, "\n");
    try std.testing.expectEqualStrings("ref: refs/heads/master", trimmed);
}

test "updateRefsAfterClone uses first branch when no main/master" {
    const allocator = std.testing.allocator;
    const tmp_dir = try setupTmpDir();
    defer cleanupTmpDir(tmp_dir);

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_dir});
    defer allocator.free(git_dir);
    try std.fs.cwd().makePath(git_dir);
    {
        const d = try std.fmt.allocPrint(allocator, "{s}/refs/heads", .{git_dir});
        defer allocator.free(d);
        try std.fs.cwd().makePath(d);
    }

    const refs = [_]pack_writer.RefUpdate{
        .{ .name = "refs/heads/develop", .hash = "1111111111111111111111111111111111111111" },
    };
    try pack_writer.updateRefsAfterClone(allocator, git_dir, &refs, true);

    const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_dir});
    defer allocator.free(head_path);
    const content = try std.fs.cwd().readFileAlloc(allocator, head_path, 256);
    defer allocator.free(content);
    const trimmed = std.mem.trimRight(u8, content, "\n");
    try std.testing.expectEqualStrings("ref: refs/heads/develop", trimmed);
}

// ============================================================================
// SHA-1 correctness for resolved delta objects
// ============================================================================

test "OFS_DELTA resolved SHA-1 matches manual git hash-object computation" {
    const allocator = std.testing.allocator;

    const base_data = "base content here\n";
    const target_data = "base content here\nappended\n";

    var pack = std.ArrayList(u8).init(allocator);
    defer pack.deinit();

    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, 2, .big);

    const base_offset = pack.items.len;
    try encodePackHeader(&pack, 3, base_data.len);
    const bc = try compressData(allocator, base_data);
    defer allocator.free(bc);
    try pack.appendSlice(bc);

    const delta_offset = pack.items.len;
    const di = try buildCopyInsertDelta(allocator, base_data.len, target_data);
    defer allocator.free(di);
    try encodePackHeader(&pack, 6, di.len);
    try encodeOfsOffset(&pack, delta_offset - base_offset);
    const dc = try compressData(allocator, di);
    defer allocator.free(dc);
    try pack.appendSlice(dc);

    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack.items);
    var cksum: [20]u8 = undefined;
    hasher.final(&cksum);
    try pack.appendSlice(&cksum);

    const idx_data = try idx_writer.generateIdxFromData(allocator, pack.items);
    defer allocator.free(idx_data);

    // Compute expected SHA-1s
    const expected_base = gitHashObject(allocator, "blob", base_data);
    const expected_target = gitHashObject(allocator, "blob", target_data);

    // Both should be in the idx
    const sha_start = 8 + 256 * 4;
    var found_base = false;
    var found_target = false;
    for (0..2) |i| {
        const sha = idx_data[sha_start + i * 20 ..][0..20];
        if (std.mem.eql(u8, sha, &expected_base)) found_base = true;
        if (std.mem.eql(u8, sha, &expected_target)) found_target = true;
    }
    try std.testing.expect(found_base);
    try std.testing.expect(found_target);
}

// ============================================================================
// savePack idempotency
// ============================================================================

test "savePack is idempotent (same data -> same checksum)" {
    const allocator = std.testing.allocator;
    const tmp_dir = try setupTmpDir();
    defer cleanupTmpDir(tmp_dir);

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_dir});
    defer allocator.free(git_dir);
    try std.fs.cwd().makePath(git_dir);

    const objects = [_]PackObject{
        .{ .type_str = "blob", .data = "idempotent\n" },
    };
    const pack_data = try buildPackFile(allocator, &objects);
    defer allocator.free(pack_data);

    const hex1 = try pack_writer.savePack(allocator, git_dir, pack_data);
    defer allocator.free(hex1);
    const hex2 = try pack_writer.savePack(allocator, git_dir, pack_data);
    defer allocator.free(hex2);

    try std.testing.expectEqualStrings(hex1, hex2);
}

// ============================================================================
// Idx CRC-32 field is populated
// ============================================================================

test "idx CRC-32 entries are non-zero for real objects" {
    const allocator = std.testing.allocator;
    const objects = [_]PackObject{
        .{ .type_str = "blob", .data = "crc test 1\n" },
        .{ .type_str = "blob", .data = "crc test 2\n" },
    };
    const pack_data = try buildPackFile(allocator, &objects);
    defer allocator.free(pack_data);

    const idx_data = try idx_writer.generateIdxFromData(allocator, pack_data);
    defer allocator.free(idx_data);

    const n: u32 = 2;
    const crc_start = 8 + 256 * 4 + n * 20;
    for (0..n) |i| {
        const crc = std.mem.readInt(u32, idx_data[crc_start + i * 4 ..][0..4], .big);
        try std.testing.expect(crc != 0); // CRC of real compressed data should not be zero
    }
}

// ============================================================================
// Idx offset field correctness
// ============================================================================

test "idx offset entries are valid pack offsets" {
    const allocator = std.testing.allocator;
    const objects = [_]PackObject{
        .{ .type_str = "blob", .data = "offset test A\n" },
        .{ .type_str = "blob", .data = "offset test B\n" },
    };
    const pack_data = try buildPackFile(allocator, &objects);
    defer allocator.free(pack_data);

    const idx_data = try idx_writer.generateIdxFromData(allocator, pack_data);
    defer allocator.free(idx_data);

    const n: u32 = 2;
    const offset_start = 8 + 256 * 4 + n * 20 + n * 4;
    for (0..n) |i| {
        const offset = std.mem.readInt(u32, idx_data[offset_start + i * 4 ..][0..4], .big);
        // Offsets must be >= 12 (after pack header) and < pack content end
        try std.testing.expect(offset >= 12);
        try std.testing.expect(offset < pack_data.len - 20);
    }
}

// ============================================================================
// Full round-trip: git creates repo -> we re-index -> git verifies
// ============================================================================

test "round-trip: git gc pack -> our idx -> git cat-file reads all objects" {
    const allocator = std.testing.allocator;
    const tmp_dir = try setupTmpDir();
    defer cleanupTmpDir(tmp_dir);

    // Create a git repo with several commits for delta creation
    const src_dir = try std.fmt.allocPrint(allocator, "{s}/src_repo", .{tmp_dir});
    defer allocator.free(src_dir);

    try std.fs.cwd().makePath(src_dir);

    const init_cmds = [_][]const u8{
        "git init",
        "git config user.email test@test.com",
        "git config user.name Test",
    };
    for (init_cmds) |cmd| {
        const full_cmd = try std.fmt.allocPrint(allocator, "cd {s} && {s}", .{ src_dir, cmd });
        defer allocator.free(full_cmd);
        const r = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "bash", "-c", full_cmd },
            .max_output_bytes = 1024 * 1024,
        });
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }

    // Multiple commits with similar content (triggers deltas on gc)
    for (0..8) |i| {
        var buf: [256]u8 = undefined;
        const content = std.fmt.bufPrint(&buf, "Version {}\nShared content across versions\nMore shared text\nLine 4\nLine 5\n", .{i}) catch unreachable;
        const fp = try std.fmt.allocPrint(allocator, "{s}/data.txt", .{src_dir});
        defer allocator.free(fp);
        {
            const f = try std.fs.cwd().createFile(fp, .{});
            defer f.close();
            try f.writeAll(content);
        }
        var msg_buf: [32]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "v{}", .{i}) catch unreachable;
        const cmd = try std.fmt.allocPrint(allocator, "cd {s} && git add -A && git commit -m '{s}'", .{ src_dir, msg });
        defer allocator.free(cmd);
        const r = try std.process.Child.run(.{ .allocator = allocator, .argv = &.{ "bash", "-c", cmd }, .max_output_bytes = 1024 * 1024 });
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }

    // gc to create pack with deltas
    {
        const cmd = try std.fmt.allocPrint(allocator, "cd {s} && git gc --aggressive", .{src_dir});
        defer allocator.free(cmd);
        const r = try std.process.Child.run(.{ .allocator = allocator, .argv = &.{ "bash", "-c", cmd }, .max_output_bytes = 1024 * 1024 });
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }

    // Find git's pack file
    const pack_dir = try std.fmt.allocPrint(allocator, "{s}/.git/objects/pack", .{src_dir});
    defer allocator.free(pack_dir);

    var dir = try std.fs.cwd().openDir(pack_dir, .{ .iterate = true });
    defer dir.close();
    var iter = dir.iterate();
    var pack_name: ?[]u8 = null;
    defer if (pack_name) |pn| allocator.free(pn);

    while (try iter.next()) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".pack")) {
            pack_name = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pack_dir, entry.name });
            break;
        }
    }
    const git_pack = pack_name orelse return error.NoPackFileFound;

    // Read git's pack
    const pack_data = try std.fs.cwd().readFileAlloc(allocator, git_pack, 512 * 1024 * 1024);
    defer allocator.free(pack_data);

    // Create a new bare repo and save+index with our code
    const dst_dir = try std.fmt.allocPrint(allocator, "{s}/dst_repo.git", .{tmp_dir});
    defer allocator.free(dst_dir);
    {
        const r = try std.process.Child.run(.{ .allocator = allocator, .argv = &.{ "git", "init", "--bare", dst_dir } });
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }

    const checksum = try pack_writer.savePack(allocator, dst_dir, pack_data);
    defer allocator.free(checksum);
    const pp = try pack_writer.packPath(allocator, dst_dir, checksum);
    defer allocator.free(pp);

    // Delete git's idx so we generate our own
    try idx_writer.generateIdx(allocator, pp);

    // Get the HEAD hash from source repo
    const head_cmd = try std.fmt.allocPrint(allocator, "cd {s} && git rev-parse HEAD", .{src_dir});
    defer allocator.free(head_cmd);
    const head_r = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "bash", "-c", head_cmd },
    });
    defer allocator.free(head_r.stdout);
    defer allocator.free(head_r.stderr);
    const head_hash = std.mem.trimRight(u8, head_r.stdout, "\n\r ");

    // Write refs in dst
    const refs = [_]pack_writer.RefUpdate{
        .{ .name = "refs/heads/master", .hash = head_hash },
    };
    try pack_writer.updateRefsAfterClone(allocator, dst_dir, &refs, true);

    // git verify-pack with our idx
    {
        const r = try std.process.Child.run(.{
            .allocator = allocator,
            .max_output_bytes = 10 * 1024 * 1024,
            .argv = &.{ "git", "verify-pack", "-v", pp },
        });
        defer allocator.free(r.stdout);
        defer allocator.free(r.stderr);
        try std.testing.expectEqual(@as(u8, 0), r.term.Exited);
    }

    // git log should work in dst
    {
        const r = try std.process.Child.run(.{
            .allocator = allocator,
            .max_output_bytes = 10 * 1024 * 1024,
            .argv = &.{ "git", "--git-dir", dst_dir, "log", "--oneline" },
        });
        defer allocator.free(r.stdout);
        defer allocator.free(r.stderr);
        try std.testing.expectEqual(@as(u8, 0), r.term.Exited);
        // Should see all 8 commits
        var line_count: usize = 0;
        var lines = std.mem.splitScalar(u8, std.mem.trimRight(u8, r.stdout, "\n"), '\n');
        while (lines.next()) |_| line_count += 1;
        try std.testing.expect(line_count >= 8);
    }

    // git cat-file --batch-all-objects should work (verifies every object is readable)
    {
        const r = try std.process.Child.run(.{
            .allocator = allocator,
            .max_output_bytes = 10 * 1024 * 1024,
            .argv = &.{ "git", "--git-dir", dst_dir, "cat-file", "--batch-check", "--batch-all-objects" },
        });
        defer allocator.free(r.stdout);
        defer allocator.free(r.stderr);
        try std.testing.expectEqual(@as(u8, 0), r.term.Exited);
        // Should list all objects (at least commits + trees + blobs)
        var obj_lines: usize = 0;
        var lines = std.mem.splitScalar(u8, std.mem.trimRight(u8, r.stdout, "\n"), '\n');
        while (lines.next()) |line| {
            if (line.len > 0) obj_lines += 1;
        }
        try std.testing.expect(obj_lines >= 16); // 8 commits + 8 trees + at least 1 blob
    }
}

// ============================================================================
// Large blob test (> 16KB to stress streaming decompression)
// ============================================================================

test "idx generation works with large blobs (>64KB)" {
    const allocator = std.testing.allocator;
    const tmp_dir = try setupTmpDir();
    defer cleanupTmpDir(tmp_dir);

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_dir});
    defer allocator.free(git_dir);
    {
        const r = try std.process.Child.run(.{ .allocator = allocator, .argv = &.{ "git", "init", "--bare", git_dir } });
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }

    // Create a 100KB blob
    const large_data = try allocator.alloc(u8, 100 * 1024);
    defer allocator.free(large_data);
    for (large_data, 0..) |*b, i| {
        b.* = @intCast(i % 256);
    }

    const objects = [_]PackObject{
        .{ .type_str = "blob", .data = large_data },
    };
    const pack_data = try buildPackFile(allocator, &objects);
    defer allocator.free(pack_data);

    const hex = try pack_writer.savePack(allocator, git_dir, pack_data);
    defer allocator.free(hex);
    const pp = try pack_writer.packPath(allocator, git_dir, hex);
    defer allocator.free(pp);
    try idx_writer.generateIdx(allocator, pp);

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .max_output_bytes = 10 * 1024 * 1024,
        .argv = &.{ "git", "verify-pack", "-v", pp },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(@as(u8, 0), result.term.Exited);

    // Check SHA-1 matches our expectation
    const expected_sha = gitHashObject(allocator, "blob", large_data);
    const hex_expected = std.fmt.bytesToHex(expected_sha, .lower);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, &hex_expected) != null);
}
