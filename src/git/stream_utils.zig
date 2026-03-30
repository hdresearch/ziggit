const std = @import("std");
const zlib_compat = @import("zlib_compat.zig");

/// Result of streaming decompress+hash operation.
pub const DecompressHashResult = struct {
    sha1: [20]u8,
    decompressed_size: usize,
    /// Number of bytes consumed from the compressed input.
    bytes_consumed: usize,
};

/// Decompress zlib data and compute SHA-1 simultaneously in streaming fashion.
pub fn decompressAndHash(
    compressed_data: []const u8,
    git_type: []const u8,
    object_size: usize,
) !DecompressHashResult {
    var sha_hasher = std.crypto.hash.Sha1.init(.{});

    var hdr_buf: [64]u8 = undefined;
    const header = std.fmt.bufPrint(&hdr_buf, "{s} {}\x00", .{ git_type, object_size }) catch unreachable;
    sha_hasher.update(header);

    const result = zlib_compat.decompressSliceWithConsumed(std.heap.page_allocator, compressed_data) catch return error.ZlibDecompressError;
    defer std.heap.page_allocator.free(result.data);

    sha_hasher.update(result.data);

    var result_sha1: [20]u8 = undefined;
    sha_hasher.final(&result_sha1);

    return .{
        .sha1 = result_sha1,
        .decompressed_size = result.data.len,
        .bytes_consumed = result.consumed,
    };
}

/// Like decompressAndHash but also writes the decompressed data to an output buffer.
pub fn decompressHashAndCapture(
    compressed_data: []const u8,
    git_type: []const u8,
    object_size: usize,
    output: *std.array_list.Managed(u8),
) !DecompressHashResult {
    var sha_hasher = std.crypto.hash.Sha1.init(.{});

    var hdr_buf: [64]u8 = undefined;
    const header = std.fmt.bufPrint(&hdr_buf, "{s} {}\x00", .{ git_type, object_size }) catch unreachable;
    sha_hasher.update(header);

    const res = zlib_compat.decompressSliceWithConsumed(std.heap.page_allocator, compressed_data) catch return error.ZlibDecompressError;
    defer std.heap.page_allocator.free(res.data);

    sha_hasher.update(res.data);
    try output.appendSlice(res.data);

    var result_sha1: [20]u8 = undefined;
    sha_hasher.final(&result_sha1);

    return .{
        .sha1 = result_sha1,
        .decompressed_size = res.data.len,
        .bytes_consumed = res.consumed,
    };
}

/// Compute SHA-1 of already-decompressed data with a git object header.
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
pub fn decompressInto(
    compressed_data: []const u8,
    output: *std.array_list.Managed(u8),
) !struct { decompressed_size: usize, bytes_consumed: usize } {
    const res = zlib_compat.decompressSliceWithConsumed(std.heap.page_allocator, compressed_data) catch return error.ZlibDecompressError;
    defer std.heap.page_allocator.free(res.data);
    try output.appendSlice(res.data);
    return .{ .decompressed_size = res.data.len, .bytes_consumed = res.consumed };
}

/// Decompress zlib data into a pre-sized buffer (no allocation).
pub fn decompressIntoBuf(
    compressed_data: []const u8,
    buf: []u8,
) !struct { decompressed_size: usize, bytes_consumed: usize } {
    const res = zlib_compat.decompressSliceWithConsumed(std.heap.page_allocator, compressed_data) catch return error.ZlibDecompressError;
    defer std.heap.page_allocator.free(res.data);
    const n = @min(res.data.len, buf.len);
    @memcpy(buf[0..n], res.data[0..n]);
    return .{ .decompressed_size = n, .bytes_consumed = res.consumed };
}

/// Decompress zlib data and simultaneously hash it, writing into a caller-provided buffer.
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

    const res = zlib_compat.decompressSliceWithConsumed(std.heap.page_allocator, compressed_data) catch return error.ZlibDecompressError;
    defer std.heap.page_allocator.free(res.data);

    const total = @min(res.data.len, buf.len);
    @memcpy(buf[0..total], res.data[0..total]);
    sha_hasher.update(buf[0..total]);

    var result_sha1: [20]u8 = undefined;
    sha_hasher.final(&result_sha1);

    return .{
        .sha1 = result_sha1,
        .decompressed_size = total,
        .bytes_consumed = res.consumed,
    };
}

// ── Pack object header parsing ─────────────────────────────────────────

/// Result of parsing a pack object header.
pub const PackObjectHeader = struct {
    /// Pack object type (1=commit, 2=tree, 3=blob, 4=tag, 6=ofs_delta, 7=ref_delta)
    type_num: u3,
    /// Uncompressed object size from the header
    size: usize,
    /// Number of bytes consumed for the header (position of data start)
    header_len: usize,
};

/// Parse the type+size varint header of a pack object at `offset`.
pub fn parsePackObjectHeader(pack_data: []const u8, offset: usize) error{InvalidPackData}!PackObjectHeader {
    if (offset >= pack_data.len) return error.InvalidPackData;

    var pos = offset;
    const first_byte = pack_data[pos];
    pos += 1;
    const type_num: u3 = @intCast((first_byte >> 4) & 7);
    var size: usize = @intCast(first_byte & 0x0F);
    const ShiftT = std.math.Log2Int(usize);
    var shift: ShiftT = 4;
    var current_byte = first_byte;
    const max_shift: ShiftT = @bitSizeOf(usize) - 7;

    while (current_byte & 0x80 != 0 and pos < pack_data.len) {
        current_byte = pack_data[pos];
        pos += 1;
        size |= @as(usize, @intCast(current_byte & 0x7F)) << shift;
        if (shift < max_shift) shift += 7 else break;
    }

    return .{
        .type_num = type_num,
        .size = size,
        .header_len = pos - offset,
    };
}

/// Parse the OFS_DELTA negative offset encoding at `pos`.
pub fn parseOfsOffset(data: []const u8, start_pos: usize) error{InvalidPackData}!struct { negative_offset: usize, bytes_consumed: usize } {
    if (start_pos >= data.len) return error.InvalidPackData;

    var pos = start_pos;
    var delta_off: usize = 0;
    var first_byte = true;

    while (pos < data.len) {
        const b = data[pos];
        pos += 1;
        if (first_byte) {
            delta_off = @intCast(b & 0x7F);
            first_byte = false;
        } else {
            delta_off = (delta_off + 1) << 7;
            delta_off += @intCast(b & 0x7F);
        }
        if (b & 0x80 == 0) break;
    }

    return .{
        .negative_offset = delta_off,
        .bytes_consumed = pos - start_pos,
    };
}

/// Map pack type number to git object type string.
pub fn packTypeToString(type_num: u3) ?[]const u8 {
    return switch (type_num) {
        1 => "commit",
        2 => "tree",
        3 => "blob",
        4 => "tag",
        else => null,
    };
}

// ── Tests ──────────────────────────────────────────────────────────────

test "hashGitObject matches manual computation" {
    const data = "test blob data";
    const sha1 = hashGitObject("blob", data);

    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update("blob 14\x00");
    hasher.update(data);
    var expected: [20]u8 = undefined;
    hasher.final(&expected);

    try std.testing.expectEqualSlices(u8, &expected, &sha1);
}

test "parsePackObjectHeader parses commit type" {
    const data = [_]u8{ 0x96, 0x09 };
    const hdr = try parsePackObjectHeader(&data, 0);
    try std.testing.expectEqual(@as(u3, 1), hdr.type_num);
    try std.testing.expectEqual(@as(usize, 150), hdr.size);
    try std.testing.expectEqual(@as(usize, 2), hdr.header_len);
}

test "parsePackObjectHeader parses blob type small" {
    const data = [_]u8{0x35};
    const hdr = try parsePackObjectHeader(&data, 0);
    try std.testing.expectEqual(@as(u3, 3), hdr.type_num);
    try std.testing.expectEqual(@as(usize, 5), hdr.size);
    try std.testing.expectEqual(@as(usize, 1), hdr.header_len);
}

test "parsePackObjectHeader with offset" {
    const data = [_]u8{ 0x00, 0x00, 0x00, 0x25 };
    const hdr = try parsePackObjectHeader(&data, 3);
    try std.testing.expectEqual(@as(u3, 2), hdr.type_num);
    try std.testing.expectEqual(@as(usize, 5), hdr.size);
    try std.testing.expectEqual(@as(usize, 1), hdr.header_len);
}

test "parseOfsOffset single byte" {
    const data = [_]u8{0x05};
    const r = try parseOfsOffset(&data, 0);
    try std.testing.expectEqual(@as(usize, 5), r.negative_offset);
    try std.testing.expectEqual(@as(usize, 1), r.bytes_consumed);
}

test "parseOfsOffset multi byte" {
    const data = [_]u8{ 0x81, 0x00 };
    const r = try parseOfsOffset(&data, 0);
    try std.testing.expectEqual(@as(usize, 256), r.negative_offset);
    try std.testing.expectEqual(@as(usize, 2), r.bytes_consumed);
}

test "packTypeToString" {
    try std.testing.expectEqualSlices(u8, "commit", packTypeToString(1).?);
    try std.testing.expectEqualSlices(u8, "tree", packTypeToString(2).?);
    try std.testing.expectEqualSlices(u8, "blob", packTypeToString(3).?);
    try std.testing.expectEqualSlices(u8, "tag", packTypeToString(4).?);
    try std.testing.expect(packTypeToString(0) == null);
    try std.testing.expect(packTypeToString(5) == null);
    try std.testing.expect(packTypeToString(6) == null);
    try std.testing.expect(packTypeToString(7) == null);
}
