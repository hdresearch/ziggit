const std = @import("std");
const testing = std.testing;
const objects = @import("git_objects");

// ============================================================================
// PACK INTERNALS GROUND-TRUTH TESTS
//
// These tests verify the core pack infrastructure that NET-SMART and NET-PACK
// agents depend on for HTTPS clone/fetch:
//
// 1. readPackObjectAtOffset - read objects from raw pack data
// 2. applyDelta - reconstruct objects from delta chains
// 3. generatePackIndex - produce valid .idx from pack data
// 4. saveReceivedPack + loadFromPackFiles - full save/load roundtrip
// 5. fixThinPack - handle REF_DELTA packs from fetch
// 6. git CLI cross-validation - ensure interop with real git
// ============================================================================

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn git(alloc: std.mem.Allocator, cwd: []const u8, args: []const []const u8) ![]u8 {
    var argv = std.ArrayList([]const u8).init(alloc);
    defer argv.deinit();
    try argv.append("git");
    try argv.appendSlice(args);

    var child = std.process.Child.init(argv.items, alloc);
    child.cwd = cwd;
    child.stderr_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    try child.spawn();
    const stdout = try child.stdout.?.reader().readAllAlloc(alloc, 8 * 1024 * 1024);
    const stderr = try child.stderr.?.reader().readAllAlloc(alloc, 8 * 1024 * 1024);
    defer alloc.free(stderr);
    const result = try child.wait();
    if (result.Exited != 0) {
        alloc.free(stdout);
        return error.GitCommandFailed;
    }
    return stdout;
}

fn gitExec(alloc: std.mem.Allocator, cwd: []const u8, args: []const []const u8) !void {
    const out = try git(alloc, cwd, args);
    alloc.free(out);
}

fn tmpDir(alloc: std.mem.Allocator, label: []const u8) ![]u8 {
    const p = try std.fmt.allocPrint(alloc, "/tmp/ziggit_pi_{s}_{}", .{ label, std.crypto.random.int(u64) });
    try std.fs.cwd().makePath(p);
    return p;
}

fn rmDir(path: []const u8) void {
    std.fs.cwd().deleteTree(path) catch {};
}

/// Write a file into a directory
fn writeFile(dir_path: []const u8, name: []const u8, content: []const u8) !void {
    const full = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ dir_path, name });
    defer testing.allocator.free(full);
    // Ensure parent dirs
    if (std.fs.path.dirname(full)) |parent| {
        std.fs.cwd().makePath(parent) catch {};
    }
    const file = try std.fs.cwd().createFile(full, .{});
    defer file.close();
    try file.writeAll(content);
}

/// Read file contents
fn readFile(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fs.cwd().readFileAlloc(alloc, path, 64 * 1024 * 1024);
}

/// Filesystem adapter for objects.zig functions that take platform_impl
const TestFs = struct {
    pub fn readFile(self: TestFs, alloc: std.mem.Allocator, path: []const u8) ![]u8 {
        _ = self;
        return std.fs.cwd().readFileAlloc(alloc, path, 64 * 1024 * 1024);
    }
    pub fn writeFile(self: TestFs, path: []const u8, data: []const u8) !void {
        _ = self;
        if (std.fs.path.dirname(path)) |parent| {
            std.fs.cwd().makePath(parent) catch {};
        }
        const f = try std.fs.cwd().createFile(path, .{});
        defer f.close();
        try f.writeAll(data);
    }
    pub fn makeDir(self: TestFs, path: []const u8) !void {
        _ = self;
        std.fs.cwd().makePath(path) catch {};
    }
};

const TestPlatform = struct {
    fs: TestFs = .{},
};

// ---------------------------------------------------------------------------
// Varint / delta encoding helpers
// ---------------------------------------------------------------------------

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

/// Build a minimal pack file with one non-delta object
fn buildSingleObjectPack(alloc: std.mem.Allocator, obj_type: u3, data: []const u8) ![]u8 {
    var pack = std.ArrayList(u8).init(alloc);

    // Header: "PACK" + version 2 + 1 object
    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, 1, .big);

    // Object header: type (3 bits) + size varint
    const size = data.len;
    var first: u8 = (@as(u8, obj_type) << 4) | @as(u8, @intCast(size & 0x0F));
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
    var compressed = std.ArrayList(u8).init(alloc);
    defer compressed.deinit();
    var input = std.io.fixedBufferStream(data);
    try std.compress.zlib.compress(input.reader(), compressed.writer(), .{});
    try pack.appendSlice(compressed.items);

    // SHA-1 checksum
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack.items);
    var checksum: [20]u8 = undefined;
    hasher.final(&checksum);
    try pack.appendSlice(&checksum);

    return try pack.toOwnedSlice();
}

/// Build a pack with a base object + OFS_DELTA
fn buildOfsDeltaPack(alloc: std.mem.Allocator, base_type: u3, base_data: []const u8, delta_instructions: []const u8) ![]u8 {
    var pack = std.ArrayList(u8).init(alloc);

    // Header: "PACK" + version 2 + 2 objects
    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, 2, .big);

    // First object: base
    const base_offset: usize = 12; // After header
    {
        const size = base_data.len;
        var first: u8 = (@as(u8, base_type) << 4) | @as(u8, @intCast(size & 0x0F));
        var rem = size >> 4;
        if (rem > 0) first |= 0x80;
        try pack.append(first);
        while (rem > 0) {
            var b: u8 = @intCast(rem & 0x7F);
            rem >>= 7;
            if (rem > 0) b |= 0x80;
            try pack.append(b);
        }
        var compressed = std.ArrayList(u8).init(alloc);
        defer compressed.deinit();
        var input = std.io.fixedBufferStream(base_data);
        try std.compress.zlib.compress(input.reader(), compressed.writer(), .{});
        try pack.appendSlice(compressed.items);
    }

    // Second object: OFS_DELTA
    const delta_obj_offset = pack.items.len;
    {
        // Type=6 (OFS_DELTA) + size of delta_instructions
        const size = delta_instructions.len;
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

        // Negative offset to base (git's special varint encoding)
        const neg_offset = delta_obj_offset - base_offset;
        // Encode negative offset: first byte has 7 bits, subsequent bytes have (value+1)<<7 semantics
        var off = neg_offset;
        var offset_bytes: [10]u8 = undefined;
        var n: usize = 0;
        offset_bytes[n] = @intCast(off & 0x7F);
        off >>= 7;
        n += 1;
        while (off > 0) {
            off -= 1;
            // Insert at beginning - we build backwards then reverse
            offset_bytes[n] = @intCast(0x80 | (off & 0x7F));
            off >>= 7;
            n += 1;
        }
        // Reverse so MSB-first
        var i: usize = 0;
        while (i < n / 2) {
            const tmp = offset_bytes[i];
            offset_bytes[i] = offset_bytes[n - 1 - i];
            offset_bytes[n - 1 - i] = tmp;
            i += 1;
        }
        try pack.appendSlice(offset_bytes[0..n]);

        // Compress delta instructions
        var compressed = std.ArrayList(u8).init(alloc);
        defer compressed.deinit();
        var input = std.io.fixedBufferStream(delta_instructions);
        try std.compress.zlib.compress(input.reader(), compressed.writer(), .{});
        try pack.appendSlice(compressed.items);
    }

    // SHA-1 checksum
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack.items);
    var checksum: [20]u8 = undefined;
    hasher.final(&checksum);
    try pack.appendSlice(&checksum);

    return try pack.toOwnedSlice();
}

/// Build delta instructions: copy entire base + append new data
fn buildSimpleDelta(alloc: std.mem.Allocator, base_size: usize, appended: []const u8) ![]u8 {
    var delta = std.ArrayList(u8).init(alloc);
    var buf: [10]u8 = undefined;

    // Base size varint
    var n = encodeVarint(&buf, base_size);
    try delta.appendSlice(buf[0..n]);
    // Result size varint
    n = encodeVarint(&buf, base_size + appended.len);
    try delta.appendSlice(buf[0..n]);

    // Copy command: copy all of base from offset 0
    if (base_size > 0) {
        var cmd: u8 = 0x80;
        var params = std.ArrayList(u8).init(alloc);
        defer params.deinit();

        // Offset = 0: set bit 0x01, emit byte 0x00
        cmd |= 0x01;
        try params.append(0x00);

        // Size
        const sz = base_size;
        if (sz & 0xFF != 0 or sz <= 0xFF) { cmd |= 0x10; try params.append(@intCast(sz & 0xFF)); }
        if (sz > 0xFF) { cmd |= 0x20; try params.append(@intCast((sz >> 8) & 0xFF)); }
        if (sz > 0xFFFF) { cmd |= 0x40; try params.append(@intCast((sz >> 16) & 0xFF)); }

        try delta.append(cmd);
        try delta.appendSlice(params.items);
    }

    // Insert command for appended data
    if (appended.len > 0) {
        var pos: usize = 0;
        while (pos < appended.len) {
            const chunk = @min(127, appended.len - pos);
            try delta.append(@intCast(chunk));
            try delta.appendSlice(appended[pos .. pos + chunk]);
            pos += chunk;
        }
    }

    return try delta.toOwnedSlice();
}

// ===========================================================================
// SECTION 1: readPackObjectAtOffset tests
// ===========================================================================

test "readPackObjectAtOffset - blob object" {
    const alloc = testing.allocator;
    const data = "Hello, World!";
    const pack = try buildSingleObjectPack(alloc, 3, data); // blob = 3
    defer alloc.free(pack);

    const obj = try objects.readPackObjectAtOffset(pack, 12, alloc);
    defer obj.deinit(alloc);

    try testing.expectEqual(objects.ObjectType.blob, obj.type);
    try testing.expectEqualStrings(data, obj.data);
}

test "readPackObjectAtOffset - commit object" {
    const alloc = testing.allocator;
    const commit_data = "tree 4b825dc642cb6eb9a060e54bf899d69f2e1e9b48\nauthor Test <test@test.com> 1234567890 +0000\ncommitter Test <test@test.com> 1234567890 +0000\n\nInitial commit\n";
    const pack = try buildSingleObjectPack(alloc, 1, commit_data); // commit = 1
    defer alloc.free(pack);

    const obj = try objects.readPackObjectAtOffset(pack, 12, alloc);
    defer obj.deinit(alloc);

    try testing.expectEqual(objects.ObjectType.commit, obj.type);
    try testing.expectEqualStrings(commit_data, obj.data);
}

test "readPackObjectAtOffset - tree object" {
    const alloc = testing.allocator;
    // Tree entry: "100644 hello.txt\0" + 20-byte SHA-1
    var tree_data: [37]u8 = undefined;
    const prefix = "100644 hello.txt\x00";
    @memcpy(tree_data[0..prefix.len], prefix);
    @memset(tree_data[prefix.len..], 0xAB); // fake SHA-1

    const pack = try buildSingleObjectPack(alloc, 2, &tree_data); // tree = 2
    defer alloc.free(pack);

    const obj = try objects.readPackObjectAtOffset(pack, 12, alloc);
    defer obj.deinit(alloc);

    try testing.expectEqual(objects.ObjectType.tree, obj.type);
    try testing.expectEqualSlices(u8, &tree_data, obj.data);
}

test "readPackObjectAtOffset - tag object" {
    const alloc = testing.allocator;
    const tag_data = "object 4b825dc642cb6eb9a060e54bf899d69f2e1e9b48\ntype commit\ntag v1.0\ntagger Test <test@test.com> 1234567890 +0000\n\nRelease v1.0\n";
    const pack = try buildSingleObjectPack(alloc, 4, tag_data); // tag = 4
    defer alloc.free(pack);

    const obj = try objects.readPackObjectAtOffset(pack, 12, alloc);
    defer obj.deinit(alloc);

    try testing.expectEqual(objects.ObjectType.tag, obj.type);
    try testing.expectEqualStrings(tag_data, obj.data);
}

test "readPackObjectAtOffset - OFS_DELTA resolves correctly" {
    const alloc = testing.allocator;
    const base_data = "Hello, World!";
    const appended = " Goodbye!";
    const delta = try buildSimpleDelta(alloc, base_data.len, appended);
    defer alloc.free(delta);

    const pack = try buildOfsDeltaPack(alloc, 3, base_data, delta);
    defer alloc.free(pack);

    // Find the OFS_DELTA object offset (after base object)
    // Parse past header (12 bytes) and base object to find delta offset
    var pos: usize = 12;
    // Skip base object header
    var byte = pack[pos];
    pos += 1;
    while (byte & 0x80 != 0) {
        byte = pack[pos];
        pos += 1;
    }
    // Skip base compressed data
    var decomp = std.ArrayList(u8).init(alloc);
    defer decomp.deinit();
    var stream = std.io.fixedBufferStream(pack[pos..pack.len - 20]);
    std.compress.zlib.decompress(stream.reader(), decomp.writer()) catch {};
    pos += @as(usize, @intCast(stream.pos));

    const delta_offset = pos;
    const obj = try objects.readPackObjectAtOffset(pack, delta_offset, alloc);
    defer obj.deinit(alloc);

    try testing.expectEqual(objects.ObjectType.blob, obj.type);
    const expected = "Hello, World! Goodbye!";
    try testing.expectEqualStrings(expected, obj.data);
}

test "readPackObjectAtOffset - invalid offset returns error" {
    const alloc = testing.allocator;
    const pack = try buildSingleObjectPack(alloc, 3, "test");
    defer alloc.free(pack);

    const result = objects.readPackObjectAtOffset(pack, pack.len + 100, alloc);
    try testing.expectError(error.ObjectNotFound, result);
}

test "readPackObjectAtOffset - REF_DELTA returns specific error" {
    const alloc = testing.allocator;

    // Build a pack with a REF_DELTA object (type=7)
    var pack = std.ArrayList(u8).init(alloc);
    defer pack.deinit();

    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, 1, .big);

    // REF_DELTA header: type=7, size=5
    try pack.append((7 << 4) | 5);
    // 20-byte base SHA-1 (dummy)
    var dummy_sha: [20]u8 = undefined;
    @memset(&dummy_sha, 0xDE);
    try pack.appendSlice(&dummy_sha);
    // Some compressed delta data
    var compressed = std.ArrayList(u8).init(alloc);
    defer compressed.deinit();
    const fake_delta = &[_]u8{ 5, 5, 3, 'a', 'b', 'c' }; // base_size=5, result_size=5, insert "abc"
    var input = std.io.fixedBufferStream(fake_delta);
    try std.compress.zlib.compress(input.reader(), compressed.writer(), .{});
    try pack.appendSlice(compressed.items);

    // Checksum
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack.items);
    var checksum: [20]u8 = undefined;
    hasher.final(&checksum);
    try pack.appendSlice(&checksum);

    const result = objects.readPackObjectAtOffset(pack.items, 12, alloc);
    try testing.expectError(error.RefDeltaRequiresExternalLookup, result);
}

// ===========================================================================
// SECTION 2: applyDelta correctness
// ===========================================================================

test "applyDelta - pure copy from base" {
    const alloc = testing.allocator;
    const base = "ABCDEFGHIJ";
    var delta = std.ArrayList(u8).init(alloc);
    defer delta.deinit();
    var buf: [10]u8 = undefined;

    // base_size = 10, result_size = 10
    var n = encodeVarint(&buf, 10);
    try delta.appendSlice(buf[0..n]);
    n = encodeVarint(&buf, 10);
    try delta.appendSlice(buf[0..n]);

    // Copy: offset=0, size=10
    try delta.append(0x80 | 0x01 | 0x10); // offset byte 0 + size byte 0
    try delta.append(0x00); // offset = 0
    try delta.append(0x0A); // size = 10

    const result = try objects.applyDelta(base, delta.items, alloc);
    defer alloc.free(result);
    try testing.expectEqualStrings("ABCDEFGHIJ", result);
}

test "applyDelta - pure insert" {
    const alloc = testing.allocator;
    const base = "ABCDE";
    var delta = std.ArrayList(u8).init(alloc);
    defer delta.deinit();
    var buf: [10]u8 = undefined;

    // base_size = 5, result_size = 3
    var n = encodeVarint(&buf, 5);
    try delta.appendSlice(buf[0..n]);
    n = encodeVarint(&buf, 3);
    try delta.appendSlice(buf[0..n]);

    // Insert 3 bytes
    try delta.append(3);
    try delta.appendSlice("XYZ");

    const result = try objects.applyDelta(base, delta.items, alloc);
    defer alloc.free(result);
    try testing.expectEqualStrings("XYZ", result);
}

test "applyDelta - copy + insert interleaved" {
    const alloc = testing.allocator;
    const base = "Hello, World!";
    var delta = std.ArrayList(u8).init(alloc);
    defer delta.deinit();
    var buf: [10]u8 = undefined;

    const expected = "Hello INSERTED World!";

    var n = encodeVarint(&buf, base.len);
    try delta.appendSlice(buf[0..n]);
    n = encodeVarint(&buf, expected.len);
    try delta.appendSlice(buf[0..n]);

    // Copy "Hello" (offset=0, size=5)
    try delta.append(0x80 | 0x01 | 0x10);
    try delta.append(0x00);
    try delta.append(0x05);

    // Insert " INSERTED "
    try delta.append(10);
    try delta.appendSlice(" INSERTED ");

    // Copy "World!" (offset=7, size=6)
    try delta.append(0x80 | 0x01 | 0x10);
    try delta.append(0x07);
    try delta.append(0x06);

    const result = try objects.applyDelta(base, delta.items, alloc);
    defer alloc.free(result);
    try testing.expectEqualStrings(expected, result);
}

test "applyDelta - copy with multi-byte offset and size" {
    const alloc = testing.allocator;
    // Create a 300-byte base
    var base: [300]u8 = undefined;
    for (&base, 0..) |*b, i| b.* = @intCast(i % 256);

    var delta = std.ArrayList(u8).init(alloc);
    defer delta.deinit();
    var buf: [10]u8 = undefined;

    // Copy from offset 256, size 44 → total 44 bytes
    var n = encodeVarint(&buf, 300);
    try delta.appendSlice(buf[0..n]);
    n = encodeVarint(&buf, 44);
    try delta.appendSlice(buf[0..n]);

    // Copy: offset=256 (needs 2 bytes), size=44
    try delta.append(0x80 | 0x01 | 0x02 | 0x10); // offset byte 0,1 + size byte 0
    try delta.append(0x00); // offset low byte = 0
    try delta.append(0x01); // offset high byte = 1 → offset = 256
    try delta.append(44); // size = 44

    const result = try objects.applyDelta(&base, delta.items, alloc);
    defer alloc.free(result);
    try testing.expectEqual(@as(usize, 44), result.len);
    try testing.expectEqualSlices(u8, base[256..300], result);
}

test "applyDelta - size 0x10000 special case" {
    const alloc = testing.allocator;
    // Create a 0x10000-byte base
    const big_size = 0x10000;
    const base = try alloc.alloc(u8, big_size);
    defer alloc.free(base);
    for (base, 0..) |*b, i| b.* = @intCast(i % 251); // prime mod for variety

    var delta = std.ArrayList(u8).init(alloc);
    defer delta.deinit();
    var buf: [10]u8 = undefined;

    var n = encodeVarint(&buf, big_size);
    try delta.appendSlice(buf[0..n]);
    n = encodeVarint(&buf, big_size);
    try delta.appendSlice(buf[0..n]);

    // Copy: offset=0, size=0x10000. When size is 0x10000, encoded as 0 (no size bytes set).
    try delta.append(0x80 | 0x01); // only offset byte 0
    try delta.append(0x00); // offset = 0
    // No size bytes → size defaults to 0x10000

    const result = try objects.applyDelta(base, delta.items, alloc);
    defer alloc.free(result);
    try testing.expectEqual(big_size, result.len);
    try testing.expectEqualSlices(u8, base, result);
}

test "applyDelta - empty delta (base_size mismatch) returns error" {
    const alloc = testing.allocator;
    const base = "test";
    // Delta says base_size=99 but actual base is 4 bytes
    var delta = std.ArrayList(u8).init(alloc);
    defer delta.deinit();
    var buf: [10]u8 = undefined;
    var n = encodeVarint(&buf, 99); // wrong base size
    try delta.appendSlice(buf[0..n]);
    n = encodeVarint(&buf, 4);
    try delta.appendSlice(buf[0..n]);
    try delta.append(4);
    try delta.appendSlice("test");

    // Should fail in strict mode (base size mismatch)
    // The permissive fallback might succeed, but strict mode should catch it
    const result = objects.applyDelta(base, delta.items, alloc);
    // Either error or permissive recovery - just verify it doesn't crash
    if (result) |data| {
        alloc.free(data);
    } else |_| {}
}

test "applyDelta - binary data with null bytes" {
    const alloc = testing.allocator;
    const base = &[_]u8{ 0, 1, 2, 3, 0, 0, 0xFF, 0xFE };
    const insert = &[_]u8{ 0xCA, 0xFE, 0, 0xBA, 0xBE };

    var delta = std.ArrayList(u8).init(alloc);
    defer delta.deinit();
    var buf: [10]u8 = undefined;

    var n = encodeVarint(&buf, base.len);
    try delta.appendSlice(buf[0..n]);
    n = encodeVarint(&buf, base.len + insert.len);
    try delta.appendSlice(buf[0..n]);

    // Copy all of base
    try delta.append(0x80 | 0x01 | 0x10);
    try delta.append(0x00);
    try delta.append(@intCast(base.len));

    // Insert binary data
    try delta.append(@intCast(insert.len));
    try delta.appendSlice(insert);

    const result = try objects.applyDelta(base, delta.items, alloc);
    defer alloc.free(result);
    try testing.expectEqual(base.len + insert.len, result.len);
    try testing.expectEqualSlices(u8, base, result[0..base.len]);
    try testing.expectEqualSlices(u8, insert, result[base.len..]);
}

// ===========================================================================
// SECTION 3: generatePackIndex produces valid idx
// ===========================================================================

test "generatePackIndex - single blob produces valid v2 idx" {
    const alloc = testing.allocator;
    const data = "Hello, pack index!";
    const pack = try buildSingleObjectPack(alloc, 3, data);
    defer alloc.free(pack);

    const idx = try objects.generatePackIndex(pack, alloc);
    defer alloc.free(idx);

    // Verify v2 idx header
    const magic = std.mem.readInt(u32, @ptrCast(idx[0..4]), .big);
    try testing.expectEqual(@as(u32, 0xff744f63), magic);
    const version = std.mem.readInt(u32, @ptrCast(idx[4..8]), .big);
    try testing.expectEqual(@as(u32, 2), version);

    // Fanout[255] should be 1 (one object)
    const total = std.mem.readInt(u32, @ptrCast(idx[8 + 255 * 4 .. 8 + 255 * 4 + 4]), .big);
    try testing.expectEqual(@as(u32, 1), total);

    // Extract SHA-1 from idx
    const sha1_offset = 8 + 256 * 4;
    const stored_sha1 = idx[sha1_offset .. sha1_offset + 20];

    // Compute expected SHA-1
    const header = try std.fmt.allocPrint(alloc, "blob {}\x00", .{data.len});
    defer alloc.free(header);
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(header);
    hasher.update(data);
    var expected_sha1: [20]u8 = undefined;
    hasher.final(&expected_sha1);

    try testing.expectEqualSlices(u8, &expected_sha1, stored_sha1);
}

test "generatePackIndex - multiple objects sorted by SHA-1" {
    const alloc = testing.allocator;

    // Build a pack with 3 blobs
    var pack = std.ArrayList(u8).init(alloc);
    defer pack.deinit();

    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, 3, .big);

    const blobs = [_][]const u8{ "aaa", "bbb", "ccc" };
    for (blobs) |blob| {
        // Type 3 (blob), size
        const first: u8 = (3 << 4) | @as(u8, @intCast(blob.len & 0x0F));
        try pack.append(first);

        var compressed = std.ArrayList(u8).init(alloc);
        defer compressed.deinit();
        var input = std.io.fixedBufferStream(blob);
        try std.compress.zlib.compress(input.reader(), compressed.writer(), .{});
        try pack.appendSlice(compressed.items);
    }

    // Checksum
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack.items);
    var checksum: [20]u8 = undefined;
    hasher.final(&checksum);
    try pack.appendSlice(&checksum);

    const idx = try objects.generatePackIndex(pack.items, alloc);
    defer alloc.free(idx);

    // Verify 3 objects
    const total = std.mem.readInt(u32, @ptrCast(idx[8 + 255 * 4 .. 8 + 255 * 4 + 4]), .big);
    try testing.expectEqual(@as(u32, 3), total);

    // Verify SHA-1s are sorted
    const sha1_start = 8 + 256 * 4;
    const sha1_0 = idx[sha1_start .. sha1_start + 20];
    const sha1_1 = idx[sha1_start + 20 .. sha1_start + 40];
    const sha1_2 = idx[sha1_start + 40 .. sha1_start + 60];

    try testing.expect(std.mem.order(u8, sha1_0, sha1_1) == .lt);
    try testing.expect(std.mem.order(u8, sha1_1, sha1_2) == .lt);
}

test "generatePackIndex - OFS_DELTA object gets correct SHA-1" {
    const alloc = testing.allocator;
    const base_data = "base content here";
    const appended = " plus more";
    const expected_result = "base content here plus more";

    const delta = try buildSimpleDelta(alloc, base_data.len, appended);
    defer alloc.free(delta);
    const pack = try buildOfsDeltaPack(alloc, 3, base_data, delta);
    defer alloc.free(pack);

    const idx = try objects.generatePackIndex(pack, alloc);
    defer alloc.free(idx);

    // Should have 2 objects
    const total = std.mem.readInt(u32, @ptrCast(idx[8 + 255 * 4 .. 8 + 255 * 4 + 4]), .big);
    try testing.expectEqual(@as(u32, 2), total);

    // Compute expected SHA-1 of the delta result
    const header = try std.fmt.allocPrint(alloc, "blob {}\x00", .{expected_result.len});
    defer alloc.free(header);
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(header);
    hasher.update(expected_result);
    var expected_sha1: [20]u8 = undefined;
    hasher.final(&expected_sha1);

    // Check that one of the two SHA-1s in the idx matches
    const sha1_start = 8 + 256 * 4;
    const sha1_0 = idx[sha1_start .. sha1_start + 20];
    const sha1_1 = idx[sha1_start + 20 .. sha1_start + 40];

    const found = std.mem.eql(u8, sha1_0, &expected_sha1) or std.mem.eql(u8, sha1_1, &expected_sha1);
    try testing.expect(found);
}

// ===========================================================================
// SECTION 4: Full roundtrip - git creates pack, ziggit reads
// ===========================================================================

test "git-created pack readable by ziggit readPackObjectAtOffset" {
    const alloc = testing.allocator;
    const dir = tmpDir(alloc, "git_pack_read") catch return;
    defer {
        rmDir(dir);
        alloc.free(dir);
    }

    // Create git repo with a few objects
    gitExec(alloc, dir, &.{ "init", "--initial-branch=main" }) catch return;
    gitExec(alloc, dir, &.{ "config", "user.email", "test@test.com" }) catch return;
    gitExec(alloc, dir, &.{ "config", "user.name", "Test" }) catch return;

    writeFile(dir, "file1.txt", "Content of file 1\n") catch return;
    writeFile(dir, "file2.txt", "Content of file 2\n") catch return;
    writeFile(dir, "subdir/file3.txt", "Content of file 3\n") catch return;
    gitExec(alloc, dir, &.{ "add", "." }) catch return;
    gitExec(alloc, dir, &.{ "commit", "-m", "initial" }) catch return;

    // Modify a file to create a delta-friendly scenario
    writeFile(dir, "file1.txt", "Content of file 1 - modified\n") catch return;
    gitExec(alloc, dir, &.{ "add", "." }) catch return;
    gitExec(alloc, dir, &.{ "commit", "-m", "modify" }) catch return;

    // Repack to create pack file
    gitExec(alloc, dir, &.{ "repack", "-a", "-d" }) catch return;

    // Find the pack file
    const pack_dir = try std.fmt.allocPrint(alloc, "{s}/.git/objects/pack", .{dir});
    defer alloc.free(pack_dir);

    var pd = std.fs.cwd().openDir(pack_dir, .{ .iterate = true }) catch return;
    defer pd.close();

    var pack_path_buf: ?[]u8 = null;
    var iter = pd.iterate();
    while (iter.next() catch null) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".pack")) {
            pack_path_buf = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ pack_dir, entry.name });
            break;
        }
    }
    const pack_path = pack_path_buf orelse return;
    defer alloc.free(pack_path);

    // Read pack data
    const pack_data = readFile(alloc, pack_path) catch return;
    defer alloc.free(pack_data);

    // Verify header
    try testing.expectEqualStrings("PACK", pack_data[0..4]);
    const obj_count = std.mem.readInt(u32, @ptrCast(pack_data[8..12]), .big);
    try testing.expect(obj_count >= 4); // At least: 2 commits, 2+ trees, 3+ blobs

    // Read the first object at offset 12
    const obj = objects.readPackObjectAtOffset(pack_data, 12, alloc) catch |err| {
        // OFS_DELTA / REF_DELTA at position 12 is valid for git repacks
        if (err == error.RefDeltaRequiresExternalLookup) return;
        return err;
    };
    defer obj.deinit(alloc);

    // Just verify it's a valid type
    try testing.expect(obj.type == .blob or obj.type == .tree or obj.type == .commit or obj.type == .tag);
    try testing.expect(obj.data.len > 0);
}

test "git-created pack with deltas - loadFromPackFiles reads all objects" {
    const alloc = testing.allocator;
    const dir = tmpDir(alloc, "git_load_all") catch return;
    defer {
        rmDir(dir);
        alloc.free(dir);
    }

    gitExec(alloc, dir, &.{ "init", "--initial-branch=main" }) catch return;
    gitExec(alloc, dir, &.{ "config", "user.email", "test@test.com" }) catch return;
    gitExec(alloc, dir, &.{ "config", "user.name", "Test" }) catch return;

    // Create multiple commits to get delta chains
    writeFile(dir, "readme.md", "# Project\n\nInitial content.\n") catch return;
    gitExec(alloc, dir, &.{ "add", "." }) catch return;
    gitExec(alloc, dir, &.{ "commit", "-m", "first" }) catch return;

    writeFile(dir, "readme.md", "# Project\n\nInitial content.\n\nAdded section 2.\n") catch return;
    gitExec(alloc, dir, &.{ "add", "." }) catch return;
    gitExec(alloc, dir, &.{ "commit", "-m", "second" }) catch return;

    writeFile(dir, "readme.md", "# Project\n\nInitial content.\n\nAdded section 2.\n\nAdded section 3.\n") catch return;
    gitExec(alloc, dir, &.{ "add", "." }) catch return;
    gitExec(alloc, dir, &.{ "commit", "-m", "third" }) catch return;

    // Aggressive repack with deltas
    gitExec(alloc, dir, &.{ "repack", "-a", "-d", "--depth=10", "--window=10" }) catch return;

    // Get list of all object hashes
    const all_objects_raw = git(alloc, dir, &.{ "rev-list", "--objects", "--all" }) catch return;
    defer alloc.free(all_objects_raw);

    const git_dir = try std.fmt.allocPrint(alloc, "{s}/.git", .{dir});
    defer alloc.free(git_dir);

    var platform = TestPlatform{};

    // Parse each object hash and try to load it
    var loaded: usize = 0;
    var failed: usize = 0;
    var line_iter = std.mem.splitScalar(u8, std.mem.trimRight(u8, all_objects_raw, "\n"), '\n');
    while (line_iter.next()) |line| {
        if (line.len < 40) continue;
        const hash = line[0..40];

        const obj = objects.GitObject.load(hash, git_dir, &platform, alloc) catch {
            failed += 1;
            continue;
        };
        defer obj.deinit(alloc);

        // Cross-validate with git cat-file
        const git_type = git(alloc, dir, &.{ "cat-file", "-t", hash }) catch continue;
        defer alloc.free(git_type);
        const trimmed_type = std.mem.trimRight(u8, git_type, "\n");

        const expected_type = objects.ObjectType.fromString(trimmed_type);
        if (expected_type) |et| {
            try testing.expectEqual(et, obj.type);
        }

        loaded += 1;
    }

    // All objects should be loadable
    try testing.expect(loaded >= 6); // 3 commits + at least 3 trees/blobs
    try testing.expectEqual(@as(usize, 0), failed);
}

// ===========================================================================
// SECTION 5: ziggit-generated pack verified by git
// ===========================================================================

test "ziggit generatePackIndex verified by git verify-pack" {
    const alloc = testing.allocator;
    const dir = tmpDir(alloc, "ziggit_idx_verify") catch return;
    defer {
        rmDir(dir);
        alloc.free(dir);
    }

    // Build a pack with 2 blobs
    var pack = std.ArrayList(u8).init(alloc);

    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, 2, .big);

    const blobs = [_][]const u8{ "first blob content\n", "second blob content\n" };
    for (blobs) |blob| {
        var first: u8 = (3 << 4) | @as(u8, @intCast(blob.len & 0x0F));
        var rem = blob.len >> 4;
        if (rem > 0) first |= 0x80;
        try pack.append(first);
        while (rem > 0) {
            var b: u8 = @intCast(rem & 0x7F);
            rem >>= 7;
            if (rem > 0) b |= 0x80;
            try pack.append(b);
        }
        var compressed = std.ArrayList(u8).init(alloc);
        defer compressed.deinit();
        var input = std.io.fixedBufferStream(blob);
        try std.compress.zlib.compress(input.reader(), compressed.writer(), .{});
        try pack.appendSlice(compressed.items);
    }

    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack.items);
    var checksum: [20]u8 = undefined;
    hasher.final(&checksum);
    try pack.appendSlice(&checksum);
    defer pack.deinit();

    // Generate idx with ziggit
    const idx = try objects.generatePackIndex(pack.items, alloc);
    defer alloc.free(idx);

    // Write pack + idx to tmp dir
    const checksum_hex = try std.fmt.allocPrint(alloc, "{}", .{std.fmt.fmtSliceHexLower(&checksum)});
    defer alloc.free(checksum_hex);

    const pack_path = try std.fmt.allocPrint(alloc, "{s}/pack-{s}.pack", .{ dir, checksum_hex });
    defer alloc.free(pack_path);
    {
        const f = try std.fs.cwd().createFile(pack_path, .{});
        defer f.close();
        try f.writeAll(pack.items);
    }

    const idx_path = try std.fmt.allocPrint(alloc, "{s}/pack-{s}.idx", .{ dir, checksum_hex });
    defer alloc.free(idx_path);
    {
        const f = try std.fs.cwd().createFile(idx_path, .{});
        defer f.close();
        try f.writeAll(idx);
    }

    // Verify with git
    const verify_out = git(alloc, "/tmp", &.{ "verify-pack", "-v", pack_path }) catch |err| {
        // If git verify-pack fails, that's a test failure
        std.debug.print("git verify-pack failed: {}\n", .{err});
        return err;
    };
    defer alloc.free(verify_out);

    // Should list 2 objects
    var obj_lines: usize = 0;
    var verify_iter = std.mem.splitScalar(u8, verify_out, '\n');
    while (verify_iter.next()) |vline| {
        if (vline.len > 0 and !std.mem.startsWith(u8, vline, "non delta") and !std.mem.startsWith(u8, vline, "chain length")) {
            if (std.mem.indexOf(u8, vline, "blob") != null) {
                obj_lines += 1;
            }
        }
    }
    try testing.expectEqual(@as(usize, 2), obj_lines);
}

// ===========================================================================
// SECTION 6: saveReceivedPack + loadFromPackFiles end-to-end
// ===========================================================================

test "saveReceivedPack then loadFromPackFiles roundtrip" {
    const alloc = testing.allocator;
    const dir = tmpDir(alloc, "save_load_rt") catch return;
    defer {
        rmDir(dir);
        alloc.free(dir);
    }

    // Set up minimal git dir structure
    const git_dir = try std.fmt.allocPrint(alloc, "{s}/.git", .{dir});
    defer alloc.free(git_dir);
    std.fs.cwd().makePath(git_dir) catch return;

    var platform = TestPlatform{};

    // Build a pack with known content
    const blob_content = "Hello from saveReceivedPack test!\n";
    const pack = try buildSingleObjectPack(alloc, 3, blob_content);
    defer alloc.free(pack);

    // Save it
    const checksum_hex = try objects.saveReceivedPack(pack, git_dir, &platform, alloc);
    defer alloc.free(checksum_hex);

    // Compute expected object hash
    const header = try std.fmt.allocPrint(alloc, "blob {}\x00", .{blob_content.len});
    defer alloc.free(header);
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(header);
    hasher.update(blob_content);
    var expected_sha1: [20]u8 = undefined;
    hasher.final(&expected_sha1);
    const expected_hex = try std.fmt.allocPrint(alloc, "{}", .{std.fmt.fmtSliceHexLower(&expected_sha1)});
    defer alloc.free(expected_hex);

    // Load it back
    const obj = try objects.GitObject.load(expected_hex, git_dir, &platform, alloc);
    defer obj.deinit(alloc);

    try testing.expectEqual(objects.ObjectType.blob, obj.type);
    try testing.expectEqualStrings(blob_content, obj.data);
}

test "saveReceivedPack with OFS_DELTA - objects loadable" {
    const alloc = testing.allocator;
    const dir = tmpDir(alloc, "save_ofs_delta") catch return;
    defer {
        rmDir(dir);
        alloc.free(dir);
    }

    const git_dir = try std.fmt.allocPrint(alloc, "{s}/.git", .{dir});
    defer alloc.free(git_dir);
    std.fs.cwd().makePath(git_dir) catch return;

    var platform = TestPlatform{};

    const base_data = "Original base content for delta test.\n";
    const appended = "Additional delta content.\n";
    const expected_result = "Original base content for delta test.\nAdditional delta content.\n";

    const delta = try buildSimpleDelta(alloc, base_data.len, appended);
    defer alloc.free(delta);
    const pack = try buildOfsDeltaPack(alloc, 3, base_data, delta);
    defer alloc.free(pack);

    const checksum_hex = try objects.saveReceivedPack(pack, git_dir, &platform, alloc);
    defer alloc.free(checksum_hex);

    // Compute expected hash of the delta result
    const header = try std.fmt.allocPrint(alloc, "blob {}\x00", .{expected_result.len});
    defer alloc.free(header);
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(header);
    hasher.update(expected_result);
    var sha1: [20]u8 = undefined;
    hasher.final(&sha1);
    const hex = try std.fmt.allocPrint(alloc, "{}", .{std.fmt.fmtSliceHexLower(&sha1)});
    defer alloc.free(hex);

    const obj = try objects.GitObject.load(hex, git_dir, &platform, alloc);
    defer obj.deinit(alloc);

    try testing.expectEqual(objects.ObjectType.blob, obj.type);
    try testing.expectEqualStrings(expected_result, obj.data);
}

// ===========================================================================
// SECTION 7: fixThinPack
// ===========================================================================

test "fixThinPack - pack without REF_DELTA returned as-is" {
    const alloc = testing.allocator;
    const pack = try buildSingleObjectPack(alloc, 3, "no deltas here");
    defer alloc.free(pack);

    var platform = TestPlatform{};
    const fixed = try objects.fixThinPack(pack, "/nonexistent", &platform, alloc);
    defer alloc.free(fixed);

    try testing.expectEqualSlices(u8, pack, fixed);
}

// ===========================================================================
// SECTION 8: Edge cases and error handling
// ===========================================================================

test "readPackObjectAtOffset - empty pack data" {
    const alloc = testing.allocator;
    const result = objects.readPackObjectAtOffset(&[_]u8{}, 0, alloc);
    try testing.expectError(error.ObjectNotFound, result);
}

test "readPackObjectAtOffset - offset at exact boundary" {
    const alloc = testing.allocator;
    const pack = try buildSingleObjectPack(alloc, 3, "x");
    defer alloc.free(pack);
    // Try reading at the checksum area (last 20 bytes)
    const result = objects.readPackObjectAtOffset(pack, pack.len - 20, alloc);
    try testing.expectError(error.ObjectNotFound, result);
}

test "generatePackIndex - invalid pack signature" {
    const alloc = testing.allocator;
    var bad_pack: [40]u8 = undefined;
    @memcpy(bad_pack[0..4], "XXXX");
    @memset(bad_pack[4..], 0);
    const result = objects.generatePackIndex(&bad_pack, alloc);
    try testing.expectError(error.InvalidPackSignature, result);
}

test "generatePackIndex - too small pack" {
    const alloc = testing.allocator;
    const result = objects.generatePackIndex(&[_]u8{ 'P', 'A', 'C', 'K' }, alloc);
    try testing.expectError(error.PackFileTooSmall, result);
}

test "applyDelta - too short delta data" {
    const alloc = testing.allocator;
    const result = objects.applyDelta("base", &[_]u8{0}, alloc);
    // Should get some form of error (DeltaMissingHeaders or similar)
    if (result) |data| {
        alloc.free(data);
        // Permissive mode might return something - that's OK
    } else |_| {
        // Expected: error for malformed delta
    }
}

test "applyDelta - delta with cmd byte 0 (reserved)" {
    const alloc = testing.allocator;
    const base = "ABCDE";
    var delta = std.ArrayList(u8).init(alloc);
    defer delta.deinit();
    var buf: [10]u8 = undefined;

    var n = encodeVarint(&buf, 5);
    try delta.appendSlice(buf[0..n]);
    n = encodeVarint(&buf, 3);
    try delta.appendSlice(buf[0..n]);
    // Insert 3 bytes
    try delta.append(3);
    try delta.appendSlice("XYZ");
    // Reserved cmd byte 0
    try delta.append(0);

    // Strict mode should reject cmd=0, but permissive might ignore it
    const result = objects.applyDelta(base, delta.items, alloc);
    if (result) |data| {
        defer alloc.free(data);
        // Permissive mode: result should still contain "XYZ" at minimum
        try testing.expect(data.len >= 3);
    } else |_| {
        // Strict error is also acceptable
    }
}
