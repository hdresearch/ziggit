const std = @import("std");

/// Result of streaming decompress+hash operation.
pub const DecompressHashResult = struct {
    sha1: [20]u8,
    decompressed_size: usize,
    /// Number of bytes consumed from the compressed input.
    bytes_consumed: usize,
};

/// Decompress zlib data and compute SHA-1 simultaneously in streaming fashion.
/// The git object header ("<type> <size>\0") is fed to the hasher first, then
/// decompressed chunks are fed without ever materializing the full object.
///
/// `compressed_data` — raw zlib bytes (e.g., from a pack file)
/// `git_type`        — "blob", "commit", "tree", or "tag"
/// `object_size`     — the uncompressed size (from the pack header)
///
/// Returns the SHA-1 digest, actual decompressed size, and bytes consumed.
pub fn decompressAndHash(
    compressed_data: []const u8,
    git_type: []const u8,
    object_size: usize,
) !DecompressHashResult {
    var sha_hasher = std.crypto.hash.Sha1.init(.{});

    // Write git object header: "<type> <size>\0"
    var hdr_buf: [64]u8 = undefined;
    const header = std.fmt.bufPrint(&hdr_buf, "{s} {}\x00", .{ git_type, object_size }) catch unreachable;
    sha_hasher.update(header);

    // Set up streaming decompression
    var fbs = std.io.fixedBufferStream(compressed_data);
    var decompressor = std.compress.zlib.decompressor(fbs.reader());

    var total_decompressed: usize = 0;
    var chunk_buf: [16384]u8 = undefined; // 16KB chunks

    while (true) {
        const n = decompressor.read(&chunk_buf) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) break;
        sha_hasher.update(chunk_buf[0..n]);
        total_decompressed += n;
    }

    var result_sha1: [20]u8 = undefined;
    sha_hasher.final(&result_sha1);

    return .{
        .sha1 = result_sha1,
        .decompressed_size = total_decompressed,
        .bytes_consumed = @intCast(fbs.pos),
    };
}

/// Like decompressAndHash but also writes the decompressed data to an output buffer.
/// Useful when the caller needs both the hash AND the data (e.g., for delta bases
/// that will be referenced later).
pub fn decompressHashAndCapture(
    compressed_data: []const u8,
    git_type: []const u8,
    object_size: usize,
    output: *std.ArrayList(u8),
) !DecompressHashResult {
    var sha_hasher = std.crypto.hash.Sha1.init(.{});

    var hdr_buf: [64]u8 = undefined;
    const header = std.fmt.bufPrint(&hdr_buf, "{s} {}\x00", .{ git_type, object_size }) catch unreachable;
    sha_hasher.update(header);

    var fbs = std.io.fixedBufferStream(compressed_data);
    var decompressor = std.compress.zlib.decompressor(fbs.reader());

    // Pre-allocate if we know the size
    if (object_size > 0) {
        try output.ensureTotalCapacity(output.items.len + object_size);
    }

    var total_decompressed: usize = 0;
    var chunk_buf: [16384]u8 = undefined;

    while (true) {
        const n = decompressor.read(&chunk_buf) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) break;
        sha_hasher.update(chunk_buf[0..n]);
        try output.appendSlice(chunk_buf[0..n]);
        total_decompressed += n;
    }

    var result_sha1: [20]u8 = undefined;
    sha_hasher.final(&result_sha1);

    return .{
        .sha1 = result_sha1,
        .decompressed_size = total_decompressed,
        .bytes_consumed = @intCast(fbs.pos),
    };
}

/// Compute SHA-1 of already-decompressed data with a git object header.
/// Fast path for delta results that are already in memory.
pub fn hashGitObject(git_type: []const u8, data: []const u8) [20]u8 {
    var sha_hasher = std.crypto.hash.Sha1.init(.{});
    var hdr_buf: [64]u8 = undefined;
    const header = std.fmt.bufPrint(&hdr_buf, "{s} {}\x00", .{ git_type, data.len }) catch unreachable;
    sha_hasher.update(header);
    sha_hasher.update(data);
    var result: [20]u8 = undefined;
    sha_hasher.final(&result);
    return result;
}

/// Decompress zlib data into a pre-cleared ArrayList, returning bytes consumed.
/// Reuses the ArrayList's capacity to avoid repeated allocations.
pub fn decompressInto(
    compressed_data: []const u8,
    output: *std.ArrayList(u8),
) !struct { decompressed_size: usize, bytes_consumed: usize } {
    var fbs = std.io.fixedBufferStream(compressed_data);
    var decompressor = std.compress.zlib.decompressor(fbs.reader());

    var total: usize = 0;
    var chunk_buf: [16384]u8 = undefined;

    while (true) {
        const n = decompressor.read(&chunk_buf) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) break;
        try output.appendSlice(chunk_buf[0..n]);
        total += n;
    }

    return .{
        .decompressed_size = total,
        .bytes_consumed = @intCast(fbs.pos),
    };
}

/// Decompress zlib data into a pre-sized buffer (no allocation).
/// `expected_size` should match the uncompressed size from the pack header.
/// Returns actual decompressed size and bytes consumed from input.
pub fn decompressIntoBuf(
    compressed_data: []const u8,
    buf: []u8,
) !struct { decompressed_size: usize, bytes_consumed: usize } {
    var fbs = std.io.fixedBufferStream(compressed_data);
    var decompressor = std.compress.zlib.decompressor(fbs.reader());

    var total: usize = 0;
    while (total < buf.len) {
        const remaining = buf[total..];
        const n = decompressor.read(remaining) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) break;
        total += n;
    }

    return .{
        .decompressed_size = total,
        .bytes_consumed = @intCast(fbs.pos),
    };
}

/// Decompress zlib data and simultaneously hash it, writing into a caller-provided buffer.
/// Combines decompressIntoBuf + SHA-1 hashing in a single pass.
/// Useful when the caller needs both the data (for caching as delta base) and the hash.
pub fn decompressHashIntoBuf(
    compressed_data: []const u8,
    git_type: []const u8,
    object_size: usize,
    buf: []u8,
) !struct { sha1: [20]u8, decompressed_size: usize, bytes_consumed: usize } {
    var sha_hasher = std.crypto.hash.Sha1.init(.{});

    var hdr_buf: [64]u8 = undefined;
    const header = std.fmt.bufPrint(&hdr_buf, "{s} {}\x00", .{ git_type, object_size }) catch unreachable;
    sha_hasher.update(header);

    var fbs = std.io.fixedBufferStream(compressed_data);
    var decompressor = std.compress.zlib.decompressor(fbs.reader());

    var total: usize = 0;
    while (total < buf.len) {
        const remaining = buf[total..];
        const n = decompressor.read(remaining) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) break;
        sha_hasher.update(buf[total..][0..n]);
        total += n;
    }

    var result_sha1: [20]u8 = undefined;
    sha_hasher.final(&result_sha1);

    return .{
        .sha1 = result_sha1,
        .decompressed_size = total,
        .bytes_consumed = @intCast(fbs.pos),
    };
}

// ── Tests ──────────────────────────────────────────────────────────────

test "decompressAndHash matches decompress-then-hash" {
    const allocator = std.testing.allocator;

    // Create test data and compress it
    const test_data = "Hello, world! This is test content for streaming hash verification.\n";

    var compressed = std.ArrayList(u8).init(allocator);
    defer compressed.deinit();

    var fbs = std.io.fixedBufferStream(test_data);
    try std.compress.zlib.compress(fbs.reader(), compressed.writer(), .{});

    // Method 1: streaming decompress+hash
    const streaming_result = try decompressAndHash(compressed.items, "blob", test_data.len);

    // Method 2: traditional decompress-then-hash
    const traditional_sha1 = hashGitObject("blob", test_data);

    try std.testing.expectEqualSlices(u8, &traditional_sha1, &streaming_result.sha1);
    try std.testing.expectEqual(test_data.len, streaming_result.decompressed_size);
}

test "decompressHashAndCapture returns data and hash" {
    const allocator = std.testing.allocator;

    const test_data = "tree content for capture test";

    var compressed = std.ArrayList(u8).init(allocator);
    defer compressed.deinit();
    var fbs = std.io.fixedBufferStream(test_data);
    try std.compress.zlib.compress(fbs.reader(), compressed.writer(), .{});

    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();

    const result = try decompressHashAndCapture(compressed.items, "tree", test_data.len, &output);

    const expected_sha1 = hashGitObject("tree", test_data);
    try std.testing.expectEqualSlices(u8, &expected_sha1, &result.sha1);
    try std.testing.expectEqualSlices(u8, test_data, output.items);
}

test "hashGitObject matches manual computation" {
    const data = "test blob data";
    const sha1 = hashGitObject("blob", data);

    // Manually compute
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update("blob 14\x00");
    hasher.update(data);
    var expected: [20]u8 = undefined;
    hasher.final(&expected);

    try std.testing.expectEqualSlices(u8, &expected, &sha1);
}

test "decompressInto returns correct size and consumed" {
    const allocator = std.testing.allocator;
    const test_data = "some data to compress and decompress";

    var compressed = std.ArrayList(u8).init(allocator);
    defer compressed.deinit();
    var fbs = std.io.fixedBufferStream(test_data);
    try std.compress.zlib.compress(fbs.reader(), compressed.writer(), .{});

    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();

    const info = try decompressInto(compressed.items, &output);
    try std.testing.expectEqual(test_data.len, info.decompressed_size);
    try std.testing.expectEqual(compressed.items.len, info.bytes_consumed);
    try std.testing.expectEqualSlices(u8, test_data, output.items);
}

test "decompressIntoBuf matches decompressInto" {
    const allocator = std.testing.allocator;
    const test_data = "buffer-based decompression test data here";

    var compressed = std.ArrayList(u8).init(allocator);
    defer compressed.deinit();
    var fbs = std.io.fixedBufferStream(test_data);
    try std.compress.zlib.compress(fbs.reader(), compressed.writer(), .{});

    var buf: [256]u8 = undefined;
    const r = try decompressIntoBuf(compressed.items, &buf);
    try std.testing.expectEqual(test_data.len, r.decompressed_size);
    try std.testing.expectEqualSlices(u8, test_data, buf[0..r.decompressed_size]);
}

test "decompressHashIntoBuf matches decompressAndHash" {
    const allocator = std.testing.allocator;
    const test_data = "testing buf-based hash+decompress";

    var compressed = std.ArrayList(u8).init(allocator);
    defer compressed.deinit();
    var fbs = std.io.fixedBufferStream(test_data);
    try std.compress.zlib.compress(fbs.reader(), compressed.writer(), .{});

    const r1 = try decompressAndHash(compressed.items, "blob", test_data.len);

    var buf: [256]u8 = undefined;
    const r2 = try decompressHashIntoBuf(compressed.items, "blob", test_data.len, &buf);

    try std.testing.expectEqualSlices(u8, &r1.sha1, &r2.sha1);
    try std.testing.expectEqual(r1.decompressed_size, r2.decompressed_size);
    try std.testing.expectEqualSlices(u8, test_data, buf[0..r2.decompressed_size]);
}
