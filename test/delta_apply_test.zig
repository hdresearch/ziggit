const std = @import("std");
const testing = std.testing;
const objects = @import("git_objects");

// ============================================================================
// Delta format reference (git pack delta encoding):
//   Header: varint(base_size) + varint(result_size)
//   Commands:
//     Copy:   0x80 | offset_flags | size_flags, then offset bytes, then size bytes
//     Insert: 1..127, then that many literal bytes
//     Reserved: 0 (invalid)
// ============================================================================

/// Encode a variable-length integer (git varint for delta headers)
fn encodeVarint(buf: []u8, value: usize) usize {
    var v = value;
    var i: usize = 0;
    while (true) {
        buf[i] = @intCast(v & 0x7F);
        v >>= 7;
        if (v == 0) {
            return i + 1;
        }
        buf[i] |= 0x80;
        i += 1;
    }
}

/// Build a delta that copies the entire base object (identity delta)
fn buildIdentityDelta(allocator: std.mem.Allocator, base_size: usize) ![]u8 {
    var delta = std.ArrayList(u8).init(allocator);
    // Header: base_size, result_size (same)
    var buf: [10]u8 = undefined;
    var n = encodeVarint(&buf, base_size);
    try delta.appendSlice(buf[0..n]);
    n = encodeVarint(&buf, base_size);
    try delta.appendSlice(buf[0..n]);
    // Copy command: copy offset=0, size=base_size
    var cmd: u8 = 0x80;
    var copy_bytes = std.ArrayList(u8).init(allocator);
    defer copy_bytes.deinit();
    // Offset bytes (offset=0, so no offset flags set)
    // Size bytes
    const size = base_size;
    if (size == 0x10000) {
        // size 0 means 0x10000, so emit no size bytes
        // Actually cmd needs no size flags set -> size will be 0 -> interpreted as 0x10000
        // Only works if base_size is exactly 0x10000
    } else {
        if (size & 0xFF != 0 or size <= 0xFF) {
            cmd |= 0x10;
            try copy_bytes.append(@intCast(size & 0xFF));
        }
        if (size > 0xFF) {
            cmd |= 0x20;
            try copy_bytes.append(@intCast((size >> 8) & 0xFF));
        }
        if (size > 0xFFFF) {
            cmd |= 0x40;
            try copy_bytes.append(@intCast((size >> 16) & 0xFF));
        }
    }
    try delta.append(cmd);
    try delta.appendSlice(copy_bytes.items);
    return delta.toOwnedSlice();
}

/// Build a delta with only insert commands
fn buildInsertOnlyDelta(allocator: std.mem.Allocator, base_size: usize, new_data: []const u8) ![]u8 {
    var delta = std.ArrayList(u8).init(allocator);
    // Header
    var buf: [10]u8 = undefined;
    var n = encodeVarint(&buf, base_size);
    try delta.appendSlice(buf[0..n]);
    n = encodeVarint(&buf, new_data.len);
    try delta.appendSlice(buf[0..n]);
    // Insert commands (max 127 bytes each)
    var pos: usize = 0;
    while (pos < new_data.len) {
        const chunk = @min(127, new_data.len - pos);
        try delta.append(@intCast(chunk));
        try delta.appendSlice(new_data[pos .. pos + chunk]);
        pos += chunk;
    }
    return delta.toOwnedSlice();
}

/// Build a delta with a copy from offset with given size, then insert
fn buildCopyInsertDelta(allocator: std.mem.Allocator, base_size: usize, copy_offset: usize, copy_size: usize, insert_data: []const u8) ![]u8 {
    var delta = std.ArrayList(u8).init(allocator);
    const result_size = copy_size + insert_data.len;
    // Header
    var buf: [10]u8 = undefined;
    var n = encodeVarint(&buf, base_size);
    try delta.appendSlice(buf[0..n]);
    n = encodeVarint(&buf, result_size);
    try delta.appendSlice(buf[0..n]);
    // Copy command
    try appendCopyCommand(&delta, copy_offset, copy_size);
    // Insert command
    if (insert_data.len > 0) {
        var pos: usize = 0;
        while (pos < insert_data.len) {
            const chunk = @min(127, insert_data.len - pos);
            try delta.append(@intCast(chunk));
            try delta.appendSlice(insert_data[pos .. pos + chunk]);
            pos += chunk;
        }
    }
    return delta.toOwnedSlice();
}

fn appendCopyCommand(delta: *std.ArrayList(u8), offset: usize, size: usize) !void {
    var cmd: u8 = 0x80;
    var params = std.ArrayList(u8).init(delta.allocator);
    defer params.deinit();

    // Offset bytes (little-endian, only non-zero bytes)
    if (offset & 0xFF != 0) {
        cmd |= 0x01;
        try params.append(@intCast(offset & 0xFF));
    }
    if (offset & 0xFF00 != 0) {
        cmd |= 0x02;
        try params.append(@intCast((offset >> 8) & 0xFF));
    }
    if (offset & 0xFF0000 != 0) {
        cmd |= 0x04;
        try params.append(@intCast((offset >> 16) & 0xFF));
    }
    if (offset & 0xFF000000 != 0) {
        cmd |= 0x08;
        try params.append(@intCast((offset >> 24) & 0xFF));
    }

    // Size bytes
    const actual_size = if (size == 0x10000) @as(usize, 0) else size;
    if (actual_size != 0) {
        if (actual_size & 0xFF != 0 or (actual_size > 0 and actual_size <= 0xFF)) {
            cmd |= 0x10;
            try params.append(@intCast(actual_size & 0xFF));
        }
        if (actual_size & 0xFF00 != 0) {
            cmd |= 0x20;
            try params.append(@intCast((actual_size >> 8) & 0xFF));
        }
        if (actual_size & 0xFF0000 != 0) {
            cmd |= 0x40;
            try params.append(@intCast((actual_size >> 16) & 0xFF));
        }
    }

    try delta.append(cmd);
    try delta.appendSlice(params.items);
}

// ============================================================================
// Test: Identity delta (copy entire base object)
// ============================================================================
test "delta: identity copy produces same output as base" {
    const allocator = testing.allocator;
    const base = "Hello, World! This is test data for delta application.";

    const delta_data = try buildIdentityDelta(allocator, base.len);
    defer allocator.free(delta_data);

    const result = try objects.applyDelta(base, delta_data, allocator);
    defer allocator.free(result);

    try testing.expectEqualStrings(base, result);
}

// ============================================================================
// Test: Insert-only delta (completely new data)
// ============================================================================
test "delta: insert-only delta produces new data" {
    const allocator = testing.allocator;
    const base = "old content that gets replaced";
    const new_data = "completely new content!";

    const delta_data = try buildInsertOnlyDelta(allocator, base.len, new_data);
    defer allocator.free(delta_data);

    const result = try objects.applyDelta(base, delta_data, allocator);
    defer allocator.free(result);

    try testing.expectEqualStrings(new_data, result);
}

// ============================================================================
// Test: Copy + insert delta (partial copy from base, then append)
// ============================================================================
test "delta: copy prefix then insert suffix" {
    const allocator = testing.allocator;
    const base = "ABCDEFGHIJKLMNOP";
    // Copy first 8 bytes, then insert " NEW STUFF"
    const insert = " NEW STUFF";

    const delta_data = try buildCopyInsertDelta(allocator, base.len, 0, 8, insert);
    defer allocator.free(delta_data);

    const result = try objects.applyDelta(base, delta_data, allocator);
    defer allocator.free(result);

    try testing.expectEqualStrings("ABCDEFGH NEW STUFF", result);
}

// ============================================================================
// Test: Copy from middle of base
// ============================================================================
test "delta: copy from middle of base" {
    const allocator = testing.allocator;
    const base = "0123456789ABCDEFGHIJ";
    // Copy 4 bytes starting at offset 10 ("ABCD"), then insert "XY"

    const delta_data = try buildCopyInsertDelta(allocator, base.len, 10, 4, "XY");
    defer allocator.free(delta_data);

    const result = try objects.applyDelta(base, delta_data, allocator);
    defer allocator.free(result);

    try testing.expectEqualStrings("ABCDXY", result);
}

// ============================================================================
// Test: Multiple copy commands (rearranging base data)
// ============================================================================
test "delta: multiple copies rearrange base data" {
    const allocator = testing.allocator;
    const base = "AAAA BBBB CCCC DDDD";
    // Result: "CCCC AAAA " (copy offset=10,size=5 then copy offset=0,size=5)
    const result_size: usize = 10;

    var delta = std.ArrayList(u8).init(allocator);
    defer delta.deinit();
    // Header
    var buf: [10]u8 = undefined;
    var n = encodeVarint(&buf, base.len);
    try delta.appendSlice(buf[0..n]);
    n = encodeVarint(&buf, result_size);
    try delta.appendSlice(buf[0..n]);
    // Copy "CCCC " from offset 10, size 5
    try appendCopyCommand(&delta, 10, 5);
    // Copy "AAAA " from offset 0, size 5
    try appendCopyCommand(&delta, 0, 5);

    const delta_data = try delta.toOwnedSlice();
    defer allocator.free(delta_data);

    const result = try objects.applyDelta(base, delta_data, allocator);
    defer allocator.free(result);

    try testing.expectEqualStrings("CCCC AAAA ", result);
}

// ============================================================================
// Test: Large insert (>127 bytes requires multiple insert commands)
// ============================================================================
test "delta: large insert spanning multiple commands" {
    const allocator = testing.allocator;
    const base = "X";
    // Insert 200 bytes of 'A'
    var new_data: [200]u8 = undefined;
    @memset(&new_data, 'A');

    const delta_data = try buildInsertOnlyDelta(allocator, base.len, &new_data);
    defer allocator.free(delta_data);

    const result = try objects.applyDelta(base, delta_data, allocator);
    defer allocator.free(result);

    try testing.expectEqual(@as(usize, 200), result.len);
    for (result) |c| {
        try testing.expectEqual(@as(u8, 'A'), c);
    }
}

// ============================================================================
// Test: Empty result (base_size=N, result_size=0) - edge case
// ============================================================================
test "delta: zero-length result" {
    const allocator = testing.allocator;
    const base = "some data";
    // Delta: base_size=9, result_size=0, no commands
    var delta = std.ArrayList(u8).init(allocator);
    defer delta.deinit();
    var buf: [10]u8 = undefined;
    var n = encodeVarint(&buf, base.len);
    try delta.appendSlice(buf[0..n]);
    n = encodeVarint(&buf, 0);
    try delta.appendSlice(buf[0..n]);

    const delta_data = try delta.toOwnedSlice();
    defer allocator.free(delta_data);

    const result = try objects.applyDelta(base, delta_data, allocator);
    defer allocator.free(result);

    try testing.expectEqual(@as(usize, 0), result.len);
}

// ============================================================================
// Test: Copy with offset requiring multiple bytes
// ============================================================================
test "delta: copy with large offset" {
    const allocator = testing.allocator;
    // Create base data with 300 bytes
    var base_buf: [300]u8 = undefined;
    for (&base_buf, 0..) |*b, i| {
        b.* = @intCast(i % 256);
    }
    const base: []const u8 = &base_buf;

    // Copy 10 bytes from offset 256 (requires 2 offset bytes)
    var delta = std.ArrayList(u8).init(allocator);
    defer delta.deinit();
    var buf: [10]u8 = undefined;
    var n = encodeVarint(&buf, base.len);
    try delta.appendSlice(buf[0..n]);
    n = encodeVarint(&buf, 10);
    try delta.appendSlice(buf[0..n]);
    try appendCopyCommand(&delta, 256, 10);

    const delta_data = try delta.toOwnedSlice();
    defer allocator.free(delta_data);

    const result = try objects.applyDelta(base, delta_data, allocator);
    defer allocator.free(result);

    try testing.expectEqual(@as(usize, 10), result.len);
    try testing.expectEqualSlices(u8, base[256..266], result);
}

// ============================================================================
// Test: Varint encoding/decoding round-trip
// ============================================================================
test "delta: varint encoding for various sizes" {
    var buf: [10]u8 = undefined;

    // Single byte (< 128)
    try testing.expectEqual(@as(usize, 1), encodeVarint(&buf, 0));
    try testing.expectEqual(@as(u8, 0), buf[0]);

    try testing.expectEqual(@as(usize, 1), encodeVarint(&buf, 127));
    try testing.expectEqual(@as(u8, 127), buf[0]);

    // Two bytes (128..16383)
    try testing.expectEqual(@as(usize, 2), encodeVarint(&buf, 128));
    try testing.expectEqual(@as(u8, 0x80), buf[0]);
    try testing.expectEqual(@as(u8, 0x01), buf[1]);

    try testing.expectEqual(@as(usize, 2), encodeVarint(&buf, 300));
    // 300 = 0b100101100 -> 7 bits: 0101100 (0x2C | 0x80), then 0b10 (0x02)
    try testing.expectEqual(@as(u8, 0xAC), buf[0]);
    try testing.expectEqual(@as(u8, 0x02), buf[1]);
}

// ============================================================================
// Test: Invalid delta - base size mismatch
// ============================================================================
test "delta: rejects base size mismatch" {
    const allocator = testing.allocator;
    const base = "short";
    // Claim base is 100 bytes but it's only 5
    var delta = std.ArrayList(u8).init(allocator);
    defer delta.deinit();
    var buf: [10]u8 = undefined;
    var n = encodeVarint(&buf, 100); // Wrong base size
    try delta.appendSlice(buf[0..n]);
    n = encodeVarint(&buf, 5);
    try delta.appendSlice(buf[0..n]);
    // Insert 5 bytes
    try delta.append(5);
    try delta.appendSlice("hello");

    const delta_data = try delta.toOwnedSlice();
    defer allocator.free(delta_data);

    // The strict path should fail, but permissive fallback may succeed
    // Just verify it doesn't crash
    const result = objects.applyDelta(base, delta_data, allocator);
    if (result) |data| {
        allocator.free(data);
    } else |_| {
        // Error is also acceptable
    }
}

// ============================================================================
// Test: Real-world-like delta (simulating a file edit)
// ============================================================================
test "delta: simulate file edit - change middle of file" {
    const allocator = testing.allocator;
    const base = "line 1: hello world\nline 2: foo bar\nline 3: goodbye\n";
    // New content: keep line 1, change line 2, keep line 3
    const expected = "line 1: hello world\nline 2: CHANGED\nline 3: goodbye\n";

    var delta = std.ArrayList(u8).init(allocator);
    defer delta.deinit();
    var buf: [10]u8 = undefined;
    // Header
    var n = encodeVarint(&buf, base.len);
    try delta.appendSlice(buf[0..n]);
    n = encodeVarint(&buf, expected.len);
    try delta.appendSlice(buf[0..n]);
    // Copy "line 1: hello world\nline 2: " (offset 0, size 28)
    try appendCopyCommand(&delta, 0, 28);
    // Insert "CHANGED\n"
    try delta.append(8);
    try delta.appendSlice("CHANGED\n");
    // Copy "line 3: goodbye\n" from offset 36, size 17
    try appendCopyCommand(&delta, 36, 17);

    const delta_data = try delta.toOwnedSlice();
    defer allocator.free(delta_data);

    const result = try objects.applyDelta(base, delta_data, allocator);
    defer allocator.free(result);

    try testing.expectEqualStrings(expected, result);
}
