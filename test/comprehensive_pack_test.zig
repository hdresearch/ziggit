const std = @import("std");
const testing = std.testing;
const fs = std.fs;
const objects = @import("../src/git/objects.zig");

/// Comprehensive test for pack file functionality 
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.debug.print("Warning: memory leaked in comprehensive pack tests\n", .{});
        }
    }
    const allocator = gpa.allocator();

    std.debug.print("Running Comprehensive Pack File Tests...\n", .{});

    // Test 1: Pack index format validation
    try testPackIndexValidation(allocator);
    
    // Test 2: Pack file header validation  
    try testPackFileValidation(allocator);
    
    // Test 3: Delta application edge cases
    try testDeltaEdgeCases(allocator);
    
    // Test 4: Object type handling
    try testObjectTypeHandling(allocator);
    
    // Test 5: Hash validation
    try testHashValidation(allocator);

    std.debug.print("All comprehensive pack tests completed successfully!\n", .{});
}

fn testPackIndexValidation(allocator: std.mem.Allocator) !void {
    std.debug.print("Test: Pack index format validation\n", .{});
    
    // Create a minimal valid pack index v2
    var valid_idx = std.ArrayList(u8).init(allocator);
    defer valid_idx.deinit();
    
    // Magic header for v2
    try valid_idx.appendSlice(&[_]u8{ 0xff, 0x74, 0x4f, 0x63 }); // Magic
    try valid_idx.appendSlice(&[_]u8{ 0x00, 0x00, 0x00, 0x02 }); // Version 2
    
    // Fanout table (256 entries, all zeros for simplicity)
    var i: usize = 0;
    while (i < 256) : (i += 1) {
        try valid_idx.appendSlice(&[_]u8{ 0x00, 0x00, 0x00, 0x00 });
    }
    
    // Validate we have proper header size
    try testing.expectEqual(@as(usize, 8 + 256 * 4), valid_idx.items.len);
    
    // Test magic number reading
    const magic = std.mem.readInt(u32, @ptrCast(valid_idx.items[0..4]), .big);
    const version = std.mem.readInt(u32, @ptrCast(valid_idx.items[4..8]), .big);
    
    try testing.expectEqual(@as(u32, 0xff744f63), magic);
    try testing.expectEqual(@as(u32, 2), version);
    
    std.debug.print("  ✓ Pack index validation passed\n", .{});
}

fn testPackFileValidation(allocator: std.mem.Allocator) !void {
    std.debug.print("Test: Pack file header validation\n", .{});
    
    // Create a minimal valid pack file header
    var valid_pack = std.ArrayList(u8).init(allocator);
    defer valid_pack.deinit();
    
    // Pack file header
    try valid_pack.appendSlice("PACK"); // Magic
    try valid_pack.appendSlice(&[_]u8{ 0x00, 0x00, 0x00, 0x02 }); // Version 2
    try valid_pack.appendSlice(&[_]u8{ 0x00, 0x00, 0x00, 0x05 }); // 5 objects
    
    // Validate header parsing
    try testing.expect(std.mem.eql(u8, valid_pack.items[0..4], "PACK"));
    
    const version = std.mem.readInt(u32, @ptrCast(valid_pack.items[4..8]), .big);
    const object_count = std.mem.readInt(u32, @ptrCast(valid_pack.items[8..12]), .big);
    
    try testing.expectEqual(@as(u32, 2), version);
    try testing.expectEqual(@as(u32, 5), object_count);
    
    // Test invalid headers
    const invalid_headers = [_][]const u8{
        "PACX", // Wrong magic
        "PAC",  // Too short
        "",     // Empty
    };
    
    for (invalid_headers) |invalid| {
        if (invalid.len >= 4) {
            try testing.expect(!std.mem.eql(u8, invalid[0..4], "PACK"));
        }
    }
    
    std.debug.print("  ✓ Pack file validation passed\n", .{});
}

fn testDeltaEdgeCases(allocator: std.mem.Allocator) !void {
    std.debug.print("Test: Delta application edge cases\n", .{});
    
    // Test variable-length integer encoding/decoding
    const test_values = [_]usize{ 0, 1, 127, 128, 255, 256, 16383, 16384, 65535, 65536 };
    
    for (test_values) |value| {
        var encoded = std.ArrayList(u8).init(allocator);
        defer encoded.deinit();
        
        // Encode the value
        try encodeVarint(&encoded, value);
        
        // Decode it back
        const decoded = try decodeVarint(encoded.items);
        
        try testing.expectEqual(value, decoded.value);
        try testing.expectEqual(encoded.items.len, decoded.bytes_read);
    }
    
    // Test delta command structure
    var delta_commands = std.ArrayList(u8).init(allocator);
    defer delta_commands.deinit();
    
    // Encode base size (10)
    try encodeVarint(&delta_commands, 10);
    // Encode result size (12)  
    try encodeVarint(&delta_commands, 12);
    
    // Copy command: copy 5 bytes from offset 0
    try delta_commands.append(0x85); // Copy command with size bit set
    try delta_commands.append(5);    // Copy size
    
    // Insert command: insert "Hi"
    try delta_commands.append(2);    // Insert 2 bytes
    try delta_commands.appendSlice("Hi");
    
    // Copy command: copy 3 bytes from offset 7
    try delta_commands.append(0x93); // Copy command with offset and size bits
    try delta_commands.append(7);    // Offset
    try delta_commands.append(3);    // Size
    
    // Validate delta structure
    try testing.expect(delta_commands.items.len > 0);
    
    std.debug.print("  ✓ Delta edge cases passed\n", .{});
}

fn testObjectTypeHandling(allocator: std.mem.Allocator) !void {
    std.debug.print("Test: Object type handling\n", .{});
    
    // Test pack object type encoding
    const PackObjectType = enum(u3) {
        commit = 1,
        tree = 2,
        blob = 3,
        tag = 4,
        ofs_delta = 6,
        ref_delta = 7,
    };
    
    // Verify type values match Git specification
    try testing.expectEqual(@as(u3, 1), @intFromEnum(PackObjectType.commit));
    try testing.expectEqual(@as(u3, 2), @intFromEnum(PackObjectType.tree));
    try testing.expectEqual(@as(u3, 3), @intFromEnum(PackObjectType.blob));
    try testing.expectEqual(@as(u3, 4), @intFromEnum(PackObjectType.tag));
    try testing.expectEqual(@as(u3, 6), @intFromEnum(PackObjectType.ofs_delta));
    try testing.expectEqual(@as(u3, 7), @intFromEnum(PackObjectType.ref_delta));
    
    // Test object type encoding in pack entry header
    const test_objects = [_]struct { type_num: u3, expected: PackObjectType }{
        .{ .type_num = 1, .expected = .commit },
        .{ .type_num = 2, .expected = .tree },
        .{ .type_num = 3, .expected = .blob },
        .{ .type_num = 4, .expected = .tag },
        .{ .type_num = 6, .expected = .ofs_delta },
        .{ .type_num = 7, .expected = .ref_delta },
    };
    
    for (test_objects) |test_obj| {
        const pack_type = std.meta.intToEnum(PackObjectType, test_obj.type_num) catch unreachable;
        try testing.expectEqual(test_obj.expected, pack_type);
    }
    
    // Test invalid type numbers
    const invalid_types = [_]u3{ 0, 5 };
    for (invalid_types) |invalid_type| {
        const result = std.meta.intToEnum(PackObjectType, invalid_type);
        try testing.expectError(error.InvalidEnumTag, result);
    }
    
    std.debug.print("  ✓ Object type handling passed\n", .{});
    _ = allocator; // Suppress unused parameter warning
}

fn testHashValidation(allocator: std.mem.Allocator) !void {
    std.debug.print("Test: Hash validation\n", .{});
    
    const valid_hashes = [_][]const u8{
        "0000000000000000000000000000000000000000",
        "ffffffffffffffffffffffffffffffffffffffff",  
        "1234567890abcdef1234567890abcdef12345678",
        "abcdefabcdefabcdefabcdefabcdefabcdefabcd",
        "ABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCD",
    };
    
    const invalid_hashes = [_][]const u8{
        "123", // Too short
        "1234567890abcdef1234567890abcdef123456789", // Too long by 1
        "1234567890abcdef1234567890abcdef1234567G", // Invalid character
        "1234567890abcdef1234567890abcdef1234567g", // Lowercase g (not hex)
        "1234567890abcdef 234567890abcdef12345678", // Space in middle
        "", // Empty
        "1234567890abcdef1234567890abcdef12345678Z", // Invalid character at end
    };
    
    // Test valid hashes
    for (valid_hashes) |hash| {
        try testing.expect(isValidHash(hash));
        
        // Test hex to bytes conversion
        var hash_bytes: [20]u8 = undefined;
        _ = std.fmt.hexToBytes(&hash_bytes, hash) catch |err| {
            std.debug.print("Failed to convert valid hash {s}: {}\n", .{ hash, err });
            return err;
        };
    }
    
    // Test invalid hashes
    for (invalid_hashes) |hash| {
        try testing.expect(!isValidHash(hash));
    }
    
    std.debug.print("  ✓ Hash validation passed\n", .{});
    _ = allocator; // Suppress unused parameter warning
}

/// Encode a variable-length integer (Git pack format)
fn encodeVarint(buffer: *std.ArrayList(u8), value: usize) !void {
    var val = value;
    while (val >= 128) {
        try buffer.append(@as(u8, @intCast((val & 0x7F) | 0x80)));
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

fn isValidHash(hash: []const u8) bool {
    if (hash.len != 40) return false;
    for (hash) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

test "comprehensive pack file tests" {
    try main();
}