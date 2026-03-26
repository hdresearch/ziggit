const std = @import("std");

// Imported via build.zig anonymous imports
const stream_utils = @import("stream_utils");
const delta_cache_mod = @import("delta_cache");
const objects = @import("git_objects");
const DeltaCache = delta_cache_mod.DeltaCache;

// ── 1. decompressAndHash produces same SHA-1 as decompress-then-hash ──

test "decompressAndHash matches traditional approach for blob" {
    const allocator = std.testing.allocator;
    const data = "Hello, world! This is a test blob.\n";

    var compressed = std.ArrayList(u8).init(allocator);
    defer compressed.deinit();
    var fbs = std.io.fixedBufferStream(data);
    try std.compress.zlib.compress(fbs.reader(), compressed.writer(), .{});

    // Streaming
    const result = try stream_utils.decompressAndHash(compressed.items, "blob", data.len);

    // Traditional
    const expected = stream_utils.hashGitObject("blob", data);

    try std.testing.expectEqualSlices(u8, &expected, &result.sha1);
    try std.testing.expectEqual(data.len, result.decompressed_size);
    try std.testing.expectEqual(compressed.items.len, result.bytes_consumed);
}

test "decompressAndHash matches for commit type" {
    const allocator = std.testing.allocator;
    const data = "tree abc123\nparent def456\nauthor Test <test@test.com> 1234567890 +0000\n\ncommit message\n";

    var compressed = std.ArrayList(u8).init(allocator);
    defer compressed.deinit();
    var fbs = std.io.fixedBufferStream(data);
    try std.compress.zlib.compress(fbs.reader(), compressed.writer(), .{});

    const result = try stream_utils.decompressAndHash(compressed.items, "commit", data.len);
    const expected = stream_utils.hashGitObject("commit", data);

    try std.testing.expectEqualSlices(u8, &expected, &result.sha1);
}

test "decompressAndHash matches for empty blob" {
    const allocator = std.testing.allocator;
    const data = "";

    var compressed = std.ArrayList(u8).init(allocator);
    defer compressed.deinit();
    var fbs = std.io.fixedBufferStream(data);
    try std.compress.zlib.compress(fbs.reader(), compressed.writer(), .{});

    const result = try stream_utils.decompressAndHash(compressed.items, "blob", 0);
    const expected = stream_utils.hashGitObject("blob", data);

    try std.testing.expectEqualSlices(u8, &expected, &result.sha1);
    try std.testing.expectEqual(@as(usize, 0), result.decompressed_size);
}

test "decompressAndHash matches for large data" {
    const allocator = std.testing.allocator;

    // Generate ~64KB of data
    const big = try allocator.alloc(u8, 65536);
    defer allocator.free(big);
    for (big, 0..) |*b, i| {
        b.* = @intCast(i % 256);
    }

    var compressed = std.ArrayList(u8).init(allocator);
    defer compressed.deinit();
    var fbs = std.io.fixedBufferStream(big);
    try std.compress.zlib.compress(fbs.reader(), compressed.writer(), .{});

    const result = try stream_utils.decompressAndHash(compressed.items, "blob", big.len);
    const expected = stream_utils.hashGitObject("blob", big);

    try std.testing.expectEqualSlices(u8, &expected, &result.sha1);
    try std.testing.expectEqual(big.len, result.decompressed_size);
}

// ── 2. DeltaCache evicts correctly when over budget ──

test "DeltaCache eviction maintains budget" {
    const allocator = std.testing.allocator;
    var cache = DeltaCache.init(allocator, 50);
    defer cache.deinit();

    // Insert 5 entries of 20 bytes each (total 100 > budget 50)
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const data = try allocator.alloc(u8, 20);
        @memset(data, @intCast(i + 'A'));
        try cache.put(i * 100, "blob", data);
    }

    // Should have evicted enough to stay within budget
    try std.testing.expect(cache.memoryUsage() <= 50);
    // Most recent entries should be present
    try std.testing.expect(cache.get(400) != null);
    // Oldest entries should have been evicted
    try std.testing.expect(cache.get(0) == null);
}

test "DeltaCache LRU keeps accessed entries" {
    const allocator = std.testing.allocator;
    var cache = DeltaCache.init(allocator, 30);
    defer cache.deinit();

    const d1 = try allocator.dupe(u8, "1111111111"); // 10
    try cache.put(1, "blob", d1);
    const d2 = try allocator.dupe(u8, "2222222222"); // 10
    try cache.put(2, "tree", d2);
    const d3 = try allocator.dupe(u8, "3333333333"); // 10
    try cache.put(3, "commit", d3);
    // All fit within 30 bytes

    // Access entry 1 (makes it most recent)
    _ = cache.get(1);

    // Insert entry 4 — should evict entry 2 (oldest non-accessed)
    const d4 = try allocator.dupe(u8, "4444444444");
    try cache.put(4, "tag", d4);

    try std.testing.expect(cache.get(1) != null);
    try std.testing.expect(cache.get(2) == null); // evicted
    try std.testing.expect(cache.get(3) != null);
    try std.testing.expect(cache.get(4) != null);
}

test "DeltaCache hit rate" {
    const allocator = std.testing.allocator;
    var cache = DeltaCache.init(allocator, 1024);
    defer cache.deinit();

    try cache.putDupe(10, "blob", "hello");
    _ = cache.get(10); // hit
    _ = cache.get(10); // hit
    _ = cache.get(20); // miss
    _ = cache.get(30); // miss

    try std.testing.expectEqual(@as(u64, 2), cache.hits);
    try std.testing.expectEqual(@as(u64, 2), cache.misses);
    try std.testing.expect(cache.hitRate() > 0.49 and cache.hitRate() < 0.51);
}

// ── 3. applyDelta produces correct results for known delta pairs ──

test "applyDelta with copy command" {
    const allocator = std.testing.allocator;

    // Build a delta that copies the entire base
    const base = "Hello, World!";
    // Delta format:
    //   base_size varint: 13
    //   result_size varint: 13
    //   copy cmd: 0x80 | 0x01 (offset byte) | 0x10 (size byte)
    //   offset: 0x00
    //   size: 0x0D (13)
    var delta: [5]u8 = undefined;
    delta[0] = 13; // base_size = 13 (fits in 1 byte)
    delta[1] = 13; // result_size = 13
    delta[2] = 0x80 | 0x01 | 0x10; // copy cmd with offset byte0 + size byte0
    delta[3] = 0x00; // offset = 0
    delta[4] = 0x0D; // size = 13

    const result = try objects.applyDelta(base, &delta, allocator);
    defer allocator.free(result);

    try std.testing.expectEqualSlices(u8, base, result);
}

test "applyDelta with insert command" {
    const allocator = std.testing.allocator;

    const base = "base";
    // Delta: base_size=4, result_size=5, insert 5 bytes "hello"
    const delta = [_]u8{
        4, // base_size
        5, // result_size
        5, // insert 5 bytes
        'h', 'e', 'l', 'l', 'o',
    };

    const result = try objects.applyDelta(base, &delta, allocator);
    defer allocator.free(result);

    try std.testing.expectEqualSlices(u8, "hello", result);
}

test "applyDelta with mixed copy and insert" {
    const allocator = std.testing.allocator;

    const base = "Hello, World!";
    // Delta: copy "Hello" (5 bytes from offset 0), then insert " Zig!"
    const delta = [_]u8{
        13, // base_size = 13
        10, // result_size = 10
        0x80 | 0x01 | 0x10, // copy with offset + size
        0x00, // offset = 0
        0x05, // size = 5 (copy "Hello")
        5, // insert 5 bytes
        ' ', 'Z', 'i', 'g', '!',
    };

    const result = try objects.applyDelta(base, &delta, allocator);
    defer allocator.free(result);

    try std.testing.expectEqualSlices(u8, "Hello Zig!", result);
}

test "decompressHashAndCapture roundtrip" {
    const allocator = std.testing.allocator;
    const data = "tree entry content\x00hash_bytes_here";

    var compressed = std.ArrayList(u8).init(allocator);
    defer compressed.deinit();
    var fbs = std.io.fixedBufferStream(data);
    try std.compress.zlib.compress(fbs.reader(), compressed.writer(), .{});

    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();
    const result = try stream_utils.decompressHashAndCapture(compressed.items, "tree", data.len, &output);

    // Data should be captured
    try std.testing.expectEqualSlices(u8, data, output.items);
    // Hash should match
    const expected = stream_utils.hashGitObject("tree", data);
    try std.testing.expectEqualSlices(u8, &expected, &result.sha1);
}
