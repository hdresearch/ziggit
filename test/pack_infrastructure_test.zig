const std = @import("std");
const testing = std.testing;
const objects = @import("git_objects");

// Platform shim for tests (matches what objects.zig expects)
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
// Pack infrastructure tests for HTTPS clone/fetch support
// Ensures pack file reading, idx generation, delta application, and
// git interop all work correctly for the networking agents.
// ============================================================================

// ---------- Helpers ----------

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

fn appendCopyCommand(delta: *std.ArrayList(u8), offset: usize, size: usize) !void {
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

/// Build a complete pack file from raw object data entries.
/// Each entry: (type_num: u3, data: []const u8)
fn buildPackFile(allocator: std.mem.Allocator, entries: []const struct { type_num: u3, data: []const u8 }) ![]u8 {
    var pack = std.ArrayList(u8).init(allocator);
    defer pack.deinit();

    // Header
    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big); // version 2
    try pack.writer().writeInt(u32, @intCast(entries.len), .big);

    for (entries) |entry| {
        // Encode type+size header
        const size = entry.data.len;
        var first: u8 = (@as(u8, entry.type_num) << 4) | @as(u8, @intCast(size & 0x0F));
        var remaining = size >> 4;
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
        var input = std.io.fixedBufferStream(entry.data);
        try std.compress.zlib.compress(input.reader(), compressed.writer(), .{});
        try pack.appendSlice(compressed.items);
    }

    // Trailing SHA-1 checksum
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack.items);
    var checksum: [20]u8 = undefined;
    hasher.final(&checksum);
    try pack.appendSlice(&checksum);

    return try pack.toOwnedSlice();
}

/// Compute the git SHA-1 hash for an object (type + data)
fn gitObjectSha1(type_str: []const u8, data: []const u8, allocator: std.mem.Allocator) ![20]u8 {
    const header = try std.fmt.allocPrint(allocator, "{s} {}\x00", .{ type_str, data.len });
    defer allocator.free(header);
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(header);
    hasher.update(data);
    var sha1: [20]u8 = undefined;
    hasher.final(&sha1);
    return sha1;
}

// ============================================================================
// 1. readPackObjectAtOffset: all base object types
// ============================================================================

test "readPackObjectAtOffset: blob" {
    const allocator = testing.allocator;
    const data = "Hello from a blob!\n";
    const pack = try buildPackFile(allocator, &.{.{ .type_num = 3, .data = data }});
    defer allocator.free(pack);

    const obj = try objects.readPackObjectAtOffset(pack, 12, allocator);
    defer obj.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.blob, obj.type);
    try testing.expectEqualStrings(data, obj.data);
}

test "readPackObjectAtOffset: commit" {
    const allocator = testing.allocator;
    const data = "tree 0000000000000000000000000000000000000000\nauthor A <a@b> 1 +0000\ncommitter A <a@b> 1 +0000\n\nfirst\n";
    const pack = try buildPackFile(allocator, &.{.{ .type_num = 1, .data = data }});
    defer allocator.free(pack);

    const obj = try objects.readPackObjectAtOffset(pack, 12, allocator);
    defer obj.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.commit, obj.type);
    try testing.expectEqualStrings(data, obj.data);
}

test "readPackObjectAtOffset: tree" {
    const allocator = testing.allocator;
    // tree entry: "100644 file\0" + 20 null bytes for SHA-1
    var tree_data: [32]u8 = undefined;
    const prefix = "100644 f\x00";
    @memcpy(tree_data[0..prefix.len], prefix);
    @memset(tree_data[prefix.len..], 0xAB);
    const data: []const u8 = tree_data[0 .. prefix.len + 20];

    const pack = try buildPackFile(allocator, &.{.{ .type_num = 2, .data = data }});
    defer allocator.free(pack);

    const obj = try objects.readPackObjectAtOffset(pack, 12, allocator);
    defer obj.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.tree, obj.type);
    try testing.expectEqualSlices(u8, data, obj.data);
}

test "readPackObjectAtOffset: tag" {
    const allocator = testing.allocator;
    const data = "object 0000000000000000000000000000000000000000\ntype commit\ntag v1.0\ntagger A <a@b> 1 +0000\n\nrelease\n";
    const pack = try buildPackFile(allocator, &.{.{ .type_num = 4, .data = data }});
    defer allocator.free(pack);

    const obj = try objects.readPackObjectAtOffset(pack, 12, allocator);
    defer obj.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.tag, obj.type);
    try testing.expectEqualStrings(data, obj.data);
}

// ============================================================================
// 2. readPackObjectAtOffset: OFS_DELTA resolution
// ============================================================================

test "readPackObjectAtOffset: OFS_DELTA resolves against base in same pack" {
    const allocator = testing.allocator;

    // Base blob
    const base_data = "AAAAAAAAAA"; // 10 bytes
    // Delta that copies first 5 bytes and inserts "BBBBB"
    const result_expected = "AAAAABBBBB";

    // Build delta payload
    var delta_payload = std.ArrayList(u8).init(allocator);
    defer delta_payload.deinit();
    var buf: [10]u8 = undefined;
    var n = encodeVarint(&buf, base_data.len);
    try delta_payload.appendSlice(buf[0..n]);
    n = encodeVarint(&buf, result_expected.len);
    try delta_payload.appendSlice(buf[0..n]);
    try appendCopyCommand(&delta_payload, 0, 5);
    try delta_payload.append(5); // insert 5 bytes
    try delta_payload.appendSlice("BBBBB");

    // Build pack manually: base blob at offset 12, then OFS_DELTA
    var pack = std.ArrayList(u8).init(allocator);
    defer pack.deinit();

    // Header
    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, 2, .big); // 2 objects

    // Object 1: blob (type=3)
    const base_obj_offset = pack.items.len;
    {
        const size = base_data.len;
        var first: u8 = (3 << 4) | @as(u8, @intCast(size & 0x0F));
        var rem = size >> 4;
        if (rem > 0) first |= 0x80;
        try pack.append(first);
        while (rem > 0) {
            var b: u8 = @intCast(rem & 0x7F);
            rem >>= 7;
            if (rem > 0) b |= 0x80;
            try pack.append(b);
        }
        var compressed = std.ArrayList(u8).init(allocator);
        defer compressed.deinit();
        var input = std.io.fixedBufferStream(base_data);
        try std.compress.zlib.compress(input.reader(), compressed.writer(), .{});
        try pack.appendSlice(compressed.items);
    }

    // Object 2: OFS_DELTA (type=6)
    const delta_obj_offset = pack.items.len;
    {
        const size = delta_payload.items.len;
        var first: u8 = (6 << 4) | @as(u8, @intCast(size & 0x0F));
        var rem = size >> 4;
        if (rem > 0) first |= 0x80;
        try pack.append(first);
        while (rem > 0) {
            var b: u8 = @intCast(rem & 0x7F);
            rem >>= 7;
            if (rem > 0) b |= 0x80;
            try pack.append(b);
        }

        // OFS_DELTA negative offset encoding
        const neg_offset = delta_obj_offset - base_obj_offset;
        // Git encoding: first byte = offset & 0x7F, subsequent = ((offset >> 7) - 1) ...
        // But since we need to encode forward: MSB first
        var offset_bytes: [10]u8 = undefined;
        var offset_len: usize = 0;
        var off = neg_offset;
        offset_bytes[0] = @intCast(off & 0x7F);
        off >>= 7;
        offset_len = 1;
        while (off > 0) {
            // Shift existing bytes right
            var j: usize = offset_len;
            while (j > 0) : (j -= 1) {
                offset_bytes[j] = offset_bytes[j - 1];
            }
            offset_bytes[0] = @intCast(((off - 1) & 0x7F) | 0x80);
            off = (off - 1) >> 7;
            offset_len += 1;
        }
        // Set continuation bits on all but last
        for (offset_bytes[0 .. offset_len - 1]) |*ob| {
            ob.* |= 0x80;
        }
        offset_bytes[offset_len - 1] &= 0x7F;
        try pack.appendSlice(offset_bytes[0..offset_len]);

        // Compressed delta data
        var compressed = std.ArrayList(u8).init(allocator);
        defer compressed.deinit();
        var input = std.io.fixedBufferStream(delta_payload.items);
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

    // Read base object
    const base_obj = try objects.readPackObjectAtOffset(pack_data, base_obj_offset, allocator);
    defer base_obj.deinit(allocator);
    try testing.expectEqual(objects.ObjectType.blob, base_obj.type);
    try testing.expectEqualStrings(base_data, base_obj.data);

    // Read delta object - should resolve to the expected result
    const delta_obj = try objects.readPackObjectAtOffset(pack_data, delta_obj_offset, allocator);
    defer delta_obj.deinit(allocator);
    try testing.expectEqual(objects.ObjectType.blob, delta_obj.type);
    try testing.expectEqualStrings(result_expected, delta_obj.data);
}

// ============================================================================
// 3. readPackObjectAtOffset: REF_DELTA returns proper error
// ============================================================================

test "readPackObjectAtOffset: REF_DELTA returns RefDeltaRequiresExternalLookup" {
    const allocator = testing.allocator;

    // Build a minimal pack with one REF_DELTA object
    var pack = std.ArrayList(u8).init(allocator);
    defer pack.deinit();

    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, 1, .big);

    // REF_DELTA object (type=7), size=5
    const delta_offset = pack.items.len;
    try pack.append((7 << 4) | 5); // type 7, size 5 (fits in 4 bits)

    // 20-byte base SHA-1 (arbitrary)
    var fake_sha1: [20]u8 = undefined;
    @memset(&fake_sha1, 0xDE);
    try pack.appendSlice(&fake_sha1);

    // Compressed delta data (just some bytes)
    var compressed = std.ArrayList(u8).init(allocator);
    defer compressed.deinit();
    var input = std.io.fixedBufferStream("XXXXX");
    try std.compress.zlib.compress(input.reader(), compressed.writer(), .{});
    try pack.appendSlice(compressed.items);

    // Checksum
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack.items);
    var cksum: [20]u8 = undefined;
    hasher.final(&cksum);
    try pack.appendSlice(&cksum);

    const pack_data = try pack.toOwnedSlice();
    defer allocator.free(pack_data);

    const result = objects.readPackObjectAtOffset(pack_data, delta_offset, allocator);
    try testing.expectError(error.RefDeltaRequiresExternalLookup, result);
}

// ============================================================================
// 4. generatePackIndex + readback: full round-trip
// ============================================================================

test "generatePackIndex: blob round-trip through pack+idx" {
    const allocator = testing.allocator;
    const blob_data = "test blob content for idx generation\n";

    const pack_data = try buildPackFile(allocator, &.{.{ .type_num = 3, .data = blob_data }});
    defer allocator.free(pack_data);

    const idx_data = try objects.generatePackIndex(pack_data, allocator);
    defer allocator.free(idx_data);

    // Verify idx structure
    // Magic
    try testing.expectEqual(@as(u32, 0xff744f63), std.mem.readInt(u32, @ptrCast(idx_data[0..4]), .big));
    // Version
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, @ptrCast(idx_data[4..8]), .big));

    // Fanout[255] should be 1 (one object total)
    const fanout_255_offset = 8 + 255 * 4;
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, @ptrCast(idx_data[fanout_255_offset .. fanout_255_offset + 4]), .big));

    // SHA-1 in idx should match the expected blob hash
    const expected_sha1 = try gitObjectSha1("blob", blob_data, allocator);
    const sha1_table_start = 8 + 256 * 4;
    try testing.expectEqualSlices(u8, &expected_sha1, idx_data[sha1_table_start .. sha1_table_start + 20]);
}

// ============================================================================
// 5. generatePackIndex: multiple objects, verify sorted SHA-1 table
// ============================================================================

test "generatePackIndex: multi-object pack has sorted SHA-1 table" {
    const allocator = testing.allocator;

    const pack_data = try buildPackFile(allocator, &.{
        .{ .type_num = 3, .data = "blob one\n" },
        .{ .type_num = 3, .data = "blob two\n" },
        .{ .type_num = 3, .data = "blob three\n" },
        .{ .type_num = 3, .data = "blob four\n" },
    });
    defer allocator.free(pack_data);

    const idx_data = try objects.generatePackIndex(pack_data, allocator);
    defer allocator.free(idx_data);

    // Total objects from fanout[255]
    const total = std.mem.readInt(u32, @ptrCast(idx_data[8 + 255 * 4 .. 8 + 255 * 4 + 4]), .big);
    try testing.expectEqual(@as(u32, 4), total);

    // Verify SHA-1 table is sorted
    const sha1_start = 8 + 256 * 4;
    var prev: [20]u8 = undefined;
    @memset(&prev, 0);
    for (0..4) |i| {
        const off = sha1_start + i * 20;
        const sha = idx_data[off .. off + 20];
        if (i > 0) {
            try testing.expect(std.mem.order(u8, &prev, sha[0..20]) == .lt);
        }
        @memcpy(&prev, sha);
    }
}

// ============================================================================
// 6. git interop: buildPackFile → git index-pack → git verify-pack
// ============================================================================

test "git interop: ziggit-built pack accepted by git index-pack and git verify-pack" {
    const allocator = testing.allocator;
    const blob_data = "interop test blob\n";

    const pack_data = try buildPackFile(allocator, &.{
        .{ .type_num = 3, .data = blob_data },
        .{ .type_num = 1, .data = "tree 0000000000000000000000000000000000000000\nauthor T <t@t> 1 +0000\ncommitter T <t@t> 1 +0000\n\nmsg\n" },
    });
    defer allocator.free(pack_data);

    // Write to temp file
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const pack_path = "test.pack";
    try tmp_dir.dir.writeFile(.{ .sub_path = pack_path, .data = pack_data });

    // Get real path for git commands
    var real_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp_dir.dir.realpath(".", &real_path_buf);
    const full_pack_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, pack_path });
    defer allocator.free(full_pack_path);

    // git index-pack should succeed
    const idx_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "index-pack", full_pack_path },
    });
    if (idx_result) |result| {
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        try testing.expectEqual(@as(u8, 0), result.term.Exited);
    } else |_| {
        // git not available, skip
        return;
    }

    // git verify-pack should succeed
    const verify_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "verify-pack", "-v", full_pack_path },
    });
    defer allocator.free(verify_result.stdout);
    defer allocator.free(verify_result.stderr);
    try testing.expectEqual(@as(u8, 0), verify_result.term.Exited);
}

// ============================================================================
// 7. git interop: git creates pack → ziggit generates identical idx
// ============================================================================

test "git interop: ziggit generatePackIndex matches git index-pack on git-created pack" {
    const allocator = testing.allocator;

    // Create a git repo, add objects, repack to get a pack file
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var real_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp_dir.dir.realpath(".", &real_path_buf);

    // git init
    const init_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "init", dir_path },
    });
    if (init_result) |r| {
        defer allocator.free(r.stdout);
        defer allocator.free(r.stderr);
        if (r.term.Exited != 0) return; // git not available
    } else |_| return;

    // Create a file and commit
    try tmp_dir.dir.writeFile(.{ .sub_path = "hello.txt", .data = "hello world\n" });

    inline for (.{
        &[_][]const u8{ "git", "-C", dir_path, "add", "hello.txt" },
        &[_][]const u8{ "git", "-C", dir_path, "-c", "user.name=Test", "-c", "user.email=t@t", "commit", "-m", "initial" },
        &[_][]const u8{ "git", "-C", dir_path, "repack", "-ad" },
    }) |argv| {
        const r = try std.process.Child.run(.{ .allocator = allocator, .argv = argv });
        defer allocator.free(r.stdout);
        defer allocator.free(r.stderr);
        if (r.term.Exited != 0) return;
    }

    // Find the .pack file
    const pack_dir_path = try std.fmt.allocPrint(allocator, "{s}/.git/objects/pack", .{dir_path});
    defer allocator.free(pack_dir_path);

    var pack_dir = std.fs.cwd().openDir(pack_dir_path, .{ .iterate = true }) catch return;
    defer pack_dir.close();

    var pack_filename: ?[]u8 = null;
    defer if (pack_filename) |f| allocator.free(f);

    var iter = pack_dir.iterate();
    while (try iter.next()) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".pack")) {
            pack_filename = try allocator.dupe(u8, entry.name);
            break;
        }
    }

    const pf = pack_filename orelse return;

    // Read pack data
    const pack_data = try pack_dir.readFileAlloc(allocator, pf, 10 * 1024 * 1024);
    defer allocator.free(pack_data);

    // Generate idx with ziggit
    const ziggit_idx = try objects.generatePackIndex(pack_data, allocator);
    defer allocator.free(ziggit_idx);

    // Read git's idx
    const idx_name = try std.fmt.allocPrint(allocator, "{s}.idx", .{pf[0 .. pf.len - 5]});
    defer allocator.free(idx_name);
    const git_idx = try pack_dir.readFileAlloc(allocator, idx_name, 10 * 1024 * 1024);
    defer allocator.free(git_idx);

    // Both should have same magic, version, fanout, and SHA-1 table
    // (CRC32 values might differ if zlib produced different compressed output,
    //  but for a pack git created, if we re-read, our CRCs should match too.)
    try testing.expectEqual(ziggit_idx.len, git_idx.len);

    // Compare magic + version (8 bytes)
    try testing.expectEqualSlices(u8, git_idx[0..8], ziggit_idx[0..8]);

    // Compare fanout table (256 * 4 bytes)
    try testing.expectEqualSlices(u8, git_idx[8 .. 8 + 1024], ziggit_idx[8 .. 8 + 1024]);

    // Compare SHA-1 table
    const total = std.mem.readInt(u32, @ptrCast(git_idx[8 + 255 * 4 .. 8 + 255 * 4 + 4]), .big);
    const sha1_end = 8 + 1024 + @as(usize, total) * 20;
    try testing.expectEqualSlices(u8, git_idx[8 + 1024 .. sha1_end], ziggit_idx[8 + 1024 .. sha1_end]);
}

// ============================================================================
// 8. Delta edge case: copy with only byte 1 of offset (offset 0x0100)
// ============================================================================

test "delta: copy with offset byte 1 only (0x0100)" {
    const allocator = testing.allocator;
    // Base of 512 bytes
    var base_buf: [512]u8 = undefined;
    for (&base_buf, 0..) |*b, i| b.* = @intCast(i & 0xFF);
    const base: []const u8 = &base_buf;

    var delta = std.ArrayList(u8).init(allocator);
    defer delta.deinit();
    var buf: [10]u8 = undefined;
    var n = encodeVarint(&buf, base.len);
    try delta.appendSlice(buf[0..n]);
    n = encodeVarint(&buf, 8);
    try delta.appendSlice(buf[0..n]);

    // Copy offset=0x100, size=8 — only byte 1 of offset is set
    // cmd = 0x80 | 0x02 (offset byte 1) | 0x10 (size byte 0)
    try delta.append(0x80 | 0x02 | 0x10);
    try delta.append(0x01); // offset byte 1 → offset = 0x0100
    try delta.append(8); // size byte 0

    const delta_data = try delta.toOwnedSlice();
    defer allocator.free(delta_data);

    const result = try objects.applyDelta(base, delta_data, allocator);
    defer allocator.free(result);

    try testing.expectEqual(@as(usize, 8), result.len);
    try testing.expectEqualSlices(u8, base[0x100 .. 0x108], result);
}

// ============================================================================
// 9. Delta edge case: copy with only size byte 1 (size 0x0100)
// ============================================================================

test "delta: copy with size byte 1 only (0x0100)" {
    const allocator = testing.allocator;
    var base_buf: [512]u8 = undefined;
    for (&base_buf, 0..) |*b, i| b.* = @intCast(i & 0xFF);
    const base: []const u8 = &base_buf;

    var delta = std.ArrayList(u8).init(allocator);
    defer delta.deinit();
    var buf: [10]u8 = undefined;
    var n = encodeVarint(&buf, base.len);
    try delta.appendSlice(buf[0..n]);
    n = encodeVarint(&buf, 0x100);
    try delta.appendSlice(buf[0..n]);

    // Copy offset=0, size=0x100 — only size byte 1 is set
    // cmd = 0x80 | 0x20 (size byte 1)
    try delta.append(0x80 | 0x20);
    try delta.append(0x01); // size byte 1 → size = 0x0100

    const delta_data = try delta.toOwnedSlice();
    defer allocator.free(delta_data);

    const result = try objects.applyDelta(base, delta_data, allocator);
    defer allocator.free(result);

    try testing.expectEqual(@as(usize, 0x100), result.len);
    try testing.expectEqualSlices(u8, base[0..0x100], result);
}

// ============================================================================
// 10. Pack with binary content (null bytes, high bytes)
// ============================================================================

test "readPackObjectAtOffset: binary blob with null bytes" {
    const allocator = testing.allocator;
    // Binary data with nulls, high bytes
    var binary_data: [64]u8 = undefined;
    for (&binary_data, 0..) |*b, i| b.* = @intCast(i * 4 & 0xFF);
    binary_data[0] = 0;
    binary_data[10] = 0;
    binary_data[20] = 0xFF;
    binary_data[30] = 0;

    const pack = try buildPackFile(allocator, &.{.{ .type_num = 3, .data = &binary_data }});
    defer allocator.free(pack);

    const obj = try objects.readPackObjectAtOffset(pack, 12, allocator);
    defer obj.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.blob, obj.type);
    try testing.expectEqualSlices(u8, &binary_data, obj.data);
}

// ============================================================================
// 11. saveReceivedPack end-to-end: simulate HTTPS clone reception
// ============================================================================

test "saveReceivedPack: simulated clone reception round-trip" {
    const allocator = testing.allocator;

    // Build a pack with a blob
    const blob_data = "file content from remote\n";
    const pack_data = try buildPackFile(allocator, &.{.{ .type_num = 3, .data = blob_data }});
    defer allocator.free(pack_data);

    // Create temp git dir structure
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var real_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp_dir.dir.realpath(".", &real_path_buf);
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{dir_path});
    defer allocator.free(git_dir);

    // Create directory structure
    const pack_dir_str = try std.fmt.allocPrint(allocator, "{s}/objects/pack", .{git_dir});
    defer allocator.free(pack_dir_str);
    std.fs.cwd().makePath(pack_dir_str) catch {};

    // Use native platform
    const platform_impl = NativePlatform{};

    // Save the pack
    const checksum_hex = try objects.saveReceivedPack(pack_data, git_dir, platform_impl, allocator);
    defer allocator.free(checksum_hex);

    // Verify checksum hex is 40 chars
    try testing.expectEqual(@as(usize, 40), checksum_hex.len);

    // Verify the pack file exists
    const pack_path = try std.fmt.allocPrint(allocator, "{s}/objects/pack/pack-{s}.pack", .{ git_dir, checksum_hex });
    defer allocator.free(pack_path);
    const stat = try std.fs.cwd().statFile(pack_path);
    try testing.expect(stat.size > 0);

    // Verify the idx file exists
    const idx_path = try std.fmt.allocPrint(allocator, "{s}/objects/pack/pack-{s}.idx", .{ git_dir, checksum_hex });
    defer allocator.free(idx_path);
    const idx_stat = try std.fs.cwd().statFile(idx_path);
    try testing.expect(idx_stat.size > 0);

    // Load the object back via SHA-1
    const expected_sha1 = try gitObjectSha1("blob", blob_data, allocator);
    var hex: [40]u8 = undefined;
    _ = try std.fmt.bufPrint(&hex, "{}", .{std.fmt.fmtSliceHexLower(&expected_sha1)});

    const loaded = try objects.GitObject.load(&hex, git_dir, platform_impl, allocator);
    defer loaded.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.blob, loaded.type);
    try testing.expectEqualStrings(blob_data, loaded.data);
}

// ============================================================================
// 12. generatePackIndex: CRC32 values are correct
// ============================================================================

test "generatePackIndex: CRC32 matches manual computation" {
    const allocator = testing.allocator;
    const blob_data = "crc32 test data\n";

    const pack_data = try buildPackFile(allocator, &.{.{ .type_num = 3, .data = blob_data }});
    defer allocator.free(pack_data);

    const idx_data = try objects.generatePackIndex(pack_data, allocator);
    defer allocator.free(idx_data);

    // One object: find its CRC32 in idx
    const total = std.mem.readInt(u32, @ptrCast(idx_data[8 + 255 * 4 .. 8 + 255 * 4 + 4]), .big);
    try testing.expectEqual(@as(u32, 1), total);

    const sha1_end = 8 + 256 * 4 + 20; // After one SHA-1
    const crc_in_idx = std.mem.readInt(u32, @ptrCast(idx_data[sha1_end .. sha1_end + 4]), .big);

    // Manually compute CRC32 of the raw object bytes (from offset 12 to end of compressed data)
    // The object starts at offset 12 (after PACK header)
    const content_end = pack_data.len - 20;
    const raw_object_bytes = pack_data[12..content_end];
    const expected_crc = std.hash.crc.Crc32IsoHdlc.hash(raw_object_bytes);

    try testing.expectEqual(expected_crc, crc_in_idx);
}

// ============================================================================
// 13. generatePackIndex: pack checksum embedded in idx
// ============================================================================

test "generatePackIndex: idx contains correct pack checksum" {
    const allocator = testing.allocator;
    const pack_data = try buildPackFile(allocator, &.{.{ .type_num = 3, .data = "cksum test\n" }});
    defer allocator.free(pack_data);

    const idx_data = try objects.generatePackIndex(pack_data, allocator);
    defer allocator.free(idx_data);

    // Pack checksum is the last 20 bytes of pack
    const pack_cksum = pack_data[pack_data.len - 20 ..];
    // In idx: pack checksum is at (idx_len - 40) .. (idx_len - 20)
    const idx_pack_cksum = idx_data[idx_data.len - 40 .. idx_data.len - 20];

    try testing.expectEqualSlices(u8, pack_cksum, idx_pack_cksum);
}

// ============================================================================
// 14. generatePackIndex: idx trailing checksum is valid
// ============================================================================

test "generatePackIndex: idx self-checksum is valid" {
    const allocator = testing.allocator;
    const pack_data = try buildPackFile(allocator, &.{.{ .type_num = 3, .data = "self cksum\n" }});
    defer allocator.free(pack_data);

    const idx_data = try objects.generatePackIndex(pack_data, allocator);
    defer allocator.free(idx_data);

    // Last 20 bytes = SHA-1 of everything before
    const content = idx_data[0 .. idx_data.len - 20];
    const stored_cksum = idx_data[idx_data.len - 20 ..];

    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(content);
    var computed: [20]u8 = undefined;
    hasher.final(&computed);

    try testing.expectEqualSlices(u8, &computed, stored_cksum);
}

// ============================================================================
// 15. Delta: copy_size == 0 means 0x10000
// ============================================================================

test "delta: copy size 0 means 0x10000 (65536)" {
    const allocator = testing.allocator;
    // Need a base at least 65536 bytes
    const base = try allocator.alloc(u8, 0x10000);
    defer allocator.free(base);
    for (base, 0..) |*b, i| b.* = @intCast(i & 0xFF);

    var delta = std.ArrayList(u8).init(allocator);
    defer delta.deinit();
    var buf: [10]u8 = undefined;
    var n = encodeVarint(&buf, base.len);
    try delta.appendSlice(buf[0..n]);
    n = encodeVarint(&buf, 0x10000);
    try delta.appendSlice(buf[0..n]);

    // Copy command: offset=0, size=0 (meaning 0x10000)
    // No offset bits, no size bits → cmd = 0x80 only
    try delta.append(0x80);

    const delta_data = try delta.toOwnedSlice();
    defer allocator.free(delta_data);

    const result = try objects.applyDelta(base, delta_data, allocator);
    defer allocator.free(result);

    try testing.expectEqual(@as(usize, 0x10000), result.len);
    try testing.expectEqualSlices(u8, base, result);
}

// ============================================================================
// 16. Pack rejection: corrupted checksum
// ============================================================================

test "readPackObjectAtOffset: rejects pack with invalid checksum" {
    const allocator = testing.allocator;

    const pack_data = try buildPackFile(allocator, &.{.{ .type_num = 3, .data = "valid data\n" }});
    defer allocator.free(pack_data);

    // Corrupt the checksum
    var corrupted = try allocator.dupe(u8, pack_data);
    defer allocator.free(corrupted);
    corrupted[corrupted.len - 1] ^= 0xFF;

    // readPackObjectAtOffset doesn't check checksum (it's raw pack reading),
    // but saveReceivedPack should reject it
    const platform_impl = NativePlatform{};
    const result = objects.saveReceivedPack(corrupted, "/tmp/nonexistent", platform_impl, allocator);
    try testing.expectError(error.PackChecksumMismatch, result);
}

// ============================================================================
// 17. Multiple object types in one pack
// ============================================================================

test "readPackObjectAtOffset: blob + commit + tree in one pack, all readable" {
    const allocator = testing.allocator;

    const blob_data = "multi-type test\n";
    const commit_data = "tree 0000000000000000000000000000000000000000\nauthor A <a@b> 1 +0000\ncommitter A <a@b> 1 +0000\n\ntest\n";
    var tree_data_buf: [29]u8 = undefined;
    const tree_prefix = "100644 x\x00";
    @memcpy(tree_data_buf[0..tree_prefix.len], tree_prefix);
    @memset(tree_data_buf[tree_prefix.len..], 0xAA);
    const tree_data: []const u8 = &tree_data_buf;

    // Build pack with all three
    var pack = std.ArrayList(u8).init(allocator);
    defer pack.deinit();
    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, 3, .big);

    var offsets: [3]usize = undefined;
    const items = [_]struct { type_num: u3, data: []const u8 }{
        .{ .type_num = 3, .data = blob_data },
        .{ .type_num = 1, .data = commit_data },
        .{ .type_num = 2, .data = tree_data },
    };

    for (items, 0..) |entry, idx| {
        offsets[idx] = pack.items.len;
        const size = entry.data.len;
        var first: u8 = (@as(u8, entry.type_num) << 4) | @as(u8, @intCast(size & 0x0F));
        var remaining = size >> 4;
        if (remaining > 0) first |= 0x80;
        try pack.append(first);
        while (remaining > 0) {
            var b: u8 = @intCast(remaining & 0x7F);
            remaining >>= 7;
            if (remaining > 0) b |= 0x80;
            try pack.append(b);
        }
        var compressed = std.ArrayList(u8).init(allocator);
        defer compressed.deinit();
        var input = std.io.fixedBufferStream(entry.data);
        try std.compress.zlib.compress(input.reader(), compressed.writer(), .{});
        try pack.appendSlice(compressed.items);
    }

    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack.items);
    var cksum: [20]u8 = undefined;
    hasher.final(&cksum);
    try pack.appendSlice(&cksum);

    const pack_data = try pack.toOwnedSlice();
    defer allocator.free(pack_data);

    // Read each
    const blob = try objects.readPackObjectAtOffset(pack_data, offsets[0], allocator);
    defer blob.deinit(allocator);
    try testing.expectEqual(objects.ObjectType.blob, blob.type);
    try testing.expectEqualStrings(blob_data, blob.data);

    const commit = try objects.readPackObjectAtOffset(pack_data, offsets[1], allocator);
    defer commit.deinit(allocator);
    try testing.expectEqual(objects.ObjectType.commit, commit.type);
    try testing.expectEqualStrings(commit_data, commit.data);

    const tree = try objects.readPackObjectAtOffset(pack_data, offsets[2], allocator);
    defer tree.deinit(allocator);
    try testing.expectEqual(objects.ObjectType.tree, tree.type);
    try testing.expectEqualSlices(u8, tree_data, tree.data);
}

// ============================================================================
// 18. git creates pack with deltas → ziggit reads all objects correctly
// ============================================================================

test "git interop: read all objects from git gc pack match git cat-file" {
    const allocator = testing.allocator;

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var real_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp_dir.dir.realpath(".", &real_path_buf);

    // Create repo with multiple similar files (forces delta compression)
    const init_r = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "init", dir_path },
    }) catch return;
    defer allocator.free(init_r.stdout);
    defer allocator.free(init_r.stderr);
    if (init_r.term.Exited != 0) return;

    // Create similar files to encourage delta encoding
    for (0..5) |i| {
        const fname = try std.fmt.allocPrint(allocator, "file{}.txt", .{i});
        defer allocator.free(fname);
        const content = try std.fmt.allocPrint(allocator, "This is the common header for all files.\nLine specific to file number {}\nMore common content that is shared across files.\n", .{i});
        defer allocator.free(content);
        try tmp_dir.dir.writeFile(.{ .sub_path = fname, .data = content });
    }

    // Add, commit, gc (aggressive to force deltas)
    const cmds = [_][]const []const u8{
        &.{ "git", "-C", dir_path, "add", "." },
        &.{ "git", "-C", dir_path, "-c", "user.name=T", "-c", "user.email=t@t", "commit", "-m", "files" },
        &.{ "git", "-C", dir_path, "gc", "--aggressive" },
    };
    for (cmds) |argv| {
        const r = std.process.Child.run(.{ .allocator = allocator, .argv = argv }) catch return;
        defer allocator.free(r.stdout);
        defer allocator.free(r.stderr);
        if (r.term.Exited != 0) return;
    }

    // List all object hashes with git rev-list --objects --all
    const list_r = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "-C", dir_path, "rev-list", "--objects", "--all" },
    }) catch return;
    defer allocator.free(list_r.stdout);
    defer allocator.free(list_r.stderr);
    if (list_r.term.Exited != 0) return;

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{dir_path});
    defer allocator.free(git_dir);
    const platform_impl = NativePlatform{};

    // For each object, compare git cat-file output with ziggit
    var lines = std.mem.splitScalar(u8, list_r.stdout, '\n');
    var checked: usize = 0;
    while (lines.next()) |line| {
        if (line.len < 40) continue;
        const hash = line[0..40];

        // git cat-file -p <hash>
        const cat_r = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "git", "-C", dir_path, "cat-file", "-p", hash },
        }) catch continue;
        defer allocator.free(cat_r.stdout);
        defer allocator.free(cat_r.stderr);
        if (cat_r.term.Exited != 0) continue;

        // ziggit load
        const obj = objects.GitObject.load(hash, git_dir, platform_impl, allocator) catch continue;
        defer obj.deinit(allocator);

        // For blobs and commits, content should match exactly
        if (obj.type == .blob or obj.type == .commit or obj.type == .tag) {
            try testing.expectEqualStrings(cat_r.stdout, obj.data);
        }
        checked += 1;
    }

    // We should have checked at least the 5 blobs + 1 tree + 1 commit
    try testing.expect(checked >= 7);
}
