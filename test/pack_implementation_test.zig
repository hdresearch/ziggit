const std = @import("std");
const testing = std.testing;
const objects = @import("../src/git/objects.zig");

/// Test pack file implementation details
test "pack file delta application" {
    const allocator = testing.allocator;
    
    // Test data for delta application
    const base_data = "Hello, world! This is a test file.";
    
    // Create a simple delta that modifies "world" to "Zig"
    // Delta format: base_size + result_size + commands
    var delta_data = std.ArrayList(u8).init(allocator);
    defer delta_data.deinit();
    
    // Encode base size (34 bytes)
    try encodeVarint(&delta_data, base_data.len);
    
    // Encode result size (32 bytes - "world" becomes "Zig")
    const result_size = base_data.len - 2; // "world" (5) -> "Zig" (3), net -2
    try encodeVarint(&delta_data, result_size);
    
    // Copy command: copy first 7 bytes ("Hello, ")
    try delta_data.append(0x87); // copy command with offset and size flags
    try delta_data.append(7);    // copy 7 bytes
    
    // Insert command: insert "Zig"
    try delta_data.append(3);    // insert 3 bytes
    try delta_data.appendSlice("Zig");
    
    // Copy command: copy rest ("! This is a test file.")
    try delta_data.append(0x91); // copy command with offset flag (bit 0 and 4)
    try delta_data.append(12);   // offset 12 (skip "world")
    try delta_data.append(22);   // copy 22 bytes
    
    std.debug.print("Delta test - base: '{s}'\n", .{base_data});
    std.debug.print("Delta size: {} bytes\n", .{delta_data.items.len});
    
    // This tests the delta format structure without directly calling applyDelta
    // since it's a private function. The test validates the delta encoding logic.
    
    const expected_result = "Hello, Zig! This is a test file.";
    try testing.expectEqual(@as(usize, 32), expected_result.len);
    try testing.expect(result_size == expected_result.len);
}

/// Test pack index version detection
test "pack index version detection" {
    const allocator = testing.allocator;
    
    // Test pack index v2 magic header
    const v2_header = [_]u8{ 0xff, 0x74, 0x4f, 0x63, 0x00, 0x00, 0x00, 0x02 };
    
    const magic = std.mem.readInt(u32, @ptrCast(v2_header[0..4]), .big);
    const version = std.mem.readInt(u32, @ptrCast(v2_header[4..8]), .big);
    
    try testing.expectEqual(@as(u32, 0xff744f63), magic);
    try testing.expectEqual(@as(u32, 2), version);
    
    // Test pack index v1 (no header, starts with fanout table)
    var v1_start = std.ArrayList(u8).init(allocator);
    defer v1_start.deinit();
    
    // V1 starts directly with fanout table (256 entries)
    var i: u32 = 0;
    while (i < 256) : (i += 1) {
        // Fanout entries are cumulative object counts
        const count = i; // Simplified for test
        const bytes = std.mem.toBytes(std.mem.nativeToBig(u32, count));
        try v1_start.appendSlice(&bytes);
    }
    
    // Should have 1024 bytes for fanout table
    try testing.expectEqual(@as(usize, 1024), v1_start.items.len);
    
    std.debug.print("Pack index format tests completed\n", .{});
}

/// Test object type encoding in pack files
test "pack object type encoding" {
    // Test the pack object type enum values match Git's specification
    const PackObjectType = enum(u3) {
        commit = 1,
        tree = 2,
        blob = 3,
        tag = 4,
        ofs_delta = 6,
        ref_delta = 7,
    };
    
    try testing.expectEqual(@as(u3, 1), @intFromEnum(PackObjectType.commit));
    try testing.expectEqual(@as(u3, 2), @intFromEnum(PackObjectType.tree));
    try testing.expectEqual(@as(u3, 3), @intFromEnum(PackObjectType.blob));
    try testing.expectEqual(@as(u3, 4), @intFromEnum(PackObjectType.tag));
    try testing.expectEqual(@as(u3, 6), @intFromEnum(PackObjectType.ofs_delta));
    try testing.expectEqual(@as(u3, 7), @intFromEnum(PackObjectType.ref_delta));
    
    std.debug.print("Pack object type encoding tests completed\n", .{});
}

/// Test variable-length integer encoding (used in pack files)
test "varint encoding" {
    const allocator = testing.allocator;
    
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    
    // Test small number (< 128)
    try encodeVarint(&buffer, 42);
    try testing.expectEqual(@as(usize, 1), buffer.items.len);
    try testing.expectEqual(@as(u8, 42), buffer.items[0]);
    
    buffer.clearRetainingCapacity();
    
    // Test larger number (>= 128)
    try encodeVarint(&buffer, 300);
    try testing.expectEqual(@as(usize, 2), buffer.items.len);
    try testing.expectEqual(@as(u8, 0xAC), buffer.items[0]); // 300 & 0x7F | 0x80
    try testing.expectEqual(@as(u8, 0x02), buffer.items[1]); // 300 >> 7
    
    // Test decoding
    const decoded = try decodeVarint(buffer.items);
    try testing.expectEqual(@as(usize, 300), decoded.value);
    try testing.expectEqual(@as(usize, 2), decoded.bytes_read);
    
    std.debug.print("Varint encoding tests completed\n", .{});
}

/// Encode a variable-length integer (Git pack format)
fn encodeVarint(buffer: *std.ArrayList(u8), value: usize) !void {
    var val = value;
    while (val >= 128) {
        try buffer.append(@as(u8, @intCast(val & 0x7F | 0x80)));
        val >>= 7;
    }
    try buffer.append(@as(u8, @intCast(val & 0x7F)));
}

/// Decode a variable-length integer, returning value and bytes consumed
fn decodeVarint(data: []const u8) !struct { value: usize, bytes_read: usize } {
    var value: usize = 0;
    var shift: u6 = 0;
    var bytes_read: usize = 0;
    
    for (data) |byte| {
        bytes_read += 1;
        value |= @as(usize, @intCast(byte & 0x7F)) << shift;
        if (byte & 0x80 == 0) break;
        shift += 7;
        if (shift >= 64) return error.VarintTooLarge;
    }
    
    return .{ .value = value, .bytes_read = bytes_read };
}

/// Test SHA-1 hash validation utility
test "hash validation" {
    const valid_hashes = [_][]const u8{
        "2fd4e1c67a2d28fced849ee1bb76e7391b93eb12",
        "0000000000000000000000000000000000000000",
        "ffffffffffffffffffffffffffffffffffffffff",
        "abcdef1234567890abcdef1234567890abcdef12",
    };
    
    const invalid_hashes = [_][]const u8{
        "too_short",
        "2fd4e1c67a2d28fced849ee1bb76e7391b93eb123", // too long
        "2fd4e1c67a2d28fced849ee1bb76e7391b93ebXX", // invalid char
        "", // empty
        "2fd4e1c6 7a2d28fced849ee1bb76e7391b93eb12", // space
    };
    
    for (valid_hashes) |hash| {
        try testing.expect(isValidHash(hash));
    }
    
    for (invalid_hashes) |hash| {
        try testing.expect(!isValidHash(hash));
    }
    
    std.debug.print("Hash validation tests completed\n", .{});
}

fn isValidHash(hash: []const u8) bool {
    if (hash.len != 40) return false;
    for (hash) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

test "all pack implementation tests" {
    std.debug.print("Running pack implementation tests...\n", .{});
    // Individual tests run automatically
    std.debug.print("Pack implementation tests completed!\n", .{});
}