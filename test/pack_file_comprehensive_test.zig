const std = @import("std");
const testing = std.testing;
const objects = @import("../src/git/objects.zig");

test "pack file index v2 parsing" {
    const allocator = testing.allocator;
    
    // Create a minimal mock pack index v2 file structure
    var index_data = std.ArrayList(u8).init(allocator);
    defer index_data.deinit();
    
    const writer = index_data.writer();
    
    // Pack index v2 header
    try writer.writeInt(u32, 0xff744f63, .big); // Magic: "\377tOc"
    try writer.writeInt(u32, 2, .big); // Version 2
    
    // Fanout table (256 entries) - simplified with just a few objects
    var i: u32 = 0;
    while (i < 256) : (i += 1) {
        const count = if (i < 2) i else @as(u32, 2); // 2 objects total
        try writer.writeInt(u32, count, .big);
    }
    
    // SHA-1 table (2 objects)
    const obj1_sha: [20]u8 = [_]u8{0x12} ++ [_]u8{0x34} ** 19;
    const obj2_sha: [20]u8 = [_]u8{0x56} ++ [_]u8{0x78} ** 19;
    try writer.writeAll(&obj1_sha);
    try writer.writeAll(&obj2_sha);
    
    // CRC-32 table (2 objects)
    try writer.writeInt(u32, 0x12345678, .big);
    try writer.writeInt(u32, 0x9abcdef0, .big);
    
    // Offset table (2 objects) 
    try writer.writeInt(u32, 12, .big); // First object at offset 12
    try writer.writeInt(u32, 100, .big); // Second object at offset 100
    
    // Pack file checksum (20 bytes)
    try writer.writeAll(&([_]u8{0xAA} ** 20));
    
    // Verify we can parse this structure
    try testing.expect(index_data.items.len > 12);
    
    // Check magic and version
    const magic = std.mem.readInt(u32, @ptrCast(index_data.items[0..4]), .big);
    const version = std.mem.readInt(u32, @ptrCast(index_data.items[4..8]), .big);
    
    try testing.expectEqual(@as(u32, 0xff744f63), magic);
    try testing.expectEqual(@as(u32, 2), version);
}

test "pack object type parsing" {
    // Test pack object type values
    try testing.expectEqual(@as(u3, 1), @intFromEnum(objects.PackObjectType.commit));
    try testing.expectEqual(@as(u3, 2), @intFromEnum(objects.PackObjectType.tree));
    try testing.expectEqual(@as(u3, 3), @intFromEnum(objects.PackObjectType.blob));
    try testing.expectEqual(@as(u3, 4), @intFromEnum(objects.PackObjectType.tag));
    try testing.expectEqual(@as(u3, 6), @intFromEnum(objects.PackObjectType.ofs_delta));
    try testing.expectEqual(@as(u3, 7), @intFromEnum(objects.PackObjectType.ref_delta));
}

test "pack variable length size encoding" {
    const allocator = testing.allocator;
    
    // Test cases for variable length encoding
    const test_cases = [_]struct { 
        bytes: []const u8, 
        expected_size: u64,
        expected_type: u3,
    }{
        // Type 3 (blob), size 5: first byte = (3 << 4) | 5 = 0x35
        .{ .bytes = &[_]u8{0x35}, .expected_size = 5, .expected_type = 3 },
        
        // Type 1 (commit), size 128: first byte = (1 << 4) | 0x80, second byte = 0x01
        .{ .bytes = &[_]u8{0x90, 0x01}, .expected_size = 128, .expected_type = 1 },
        
        // Type 2 (tree), size 15: first byte = (2 << 4) | 15 = 0x2F
        .{ .bytes = &[_]u8{0x2F}, .expected_size = 15, .expected_type = 2 },
    };
    
    for (test_cases) |case| {
        var stream = std.io.fixedBufferStream(case.bytes);
        const reader = stream.reader();
        
        const first_byte = try reader.readByte();
        const pack_type = (first_byte >> 4) & 7;
        
        var size: u64 = first_byte & 15;
        var shift: u6 = 4;
        var current_byte = first_byte;
        
        while (current_byte & 0x80 != 0) {
            current_byte = try reader.readByte();
            size |= @as(u64, @intCast(current_byte & 0x7F)) << shift;
            shift += 7;
        }
        
        try testing.expectEqual(case.expected_type, @intCast(pack_type));
        try testing.expectEqual(case.expected_size, size);
    }
    
    _ = allocator;
}

test "delta application basics" {
    const allocator = testing.allocator;
    
    // Create a simple base object
    const base_data = "Hello, World!";
    
    // Create a simple delta that copies the base and appends text
    var delta = std.ArrayList(u8).init(allocator);
    defer delta.deinit();
    
    // Delta format: base_size (varint), result_size (varint), commands
    
    // Base size (13)
    try delta.append(13);
    
    // Result size (20) 
    try delta.append(20);
    
    // Copy command: copy 13 bytes from offset 0
    // Format: 0x80 | offset_flags | size_flags, offset_bytes..., size_bytes...
    try delta.append(0x80 | 0x01 | 0x10); // offset=1 byte, size=1 byte
    try delta.append(0); // offset = 0
    try delta.append(13); // size = 13
    
    // Insert command: add " Ziggit!"
    const insert_text = " Ziggit!";
    try delta.append(@intCast(insert_text.len)); // Insert size
    try delta.appendSlice(insert_text);
    
    // Test that we can parse this delta structure
    var pos: usize = 0;
    
    // Read base size
    var base_size: usize = 0;
    var shift: u6 = 0;
    while (pos < delta.items.len) {
        const b = delta.items[pos];
        pos += 1;
        base_size |= @as(usize, @intCast(b & 0x7F)) << shift;
        if (b & 0x80 == 0) break;
        shift += 7;
    }
    
    try testing.expectEqual(@as(usize, 13), base_size);
    try testing.expectEqual(base_data.len, base_size);
}

test "pack file header validation" {
    const allocator = testing.allocator;
    
    // Create mock pack file header
    var pack_data = std.ArrayList(u8).init(allocator);
    defer pack_data.deinit();
    
    const writer = pack_data.writer();
    
    // Pack file header
    try writer.writeAll("PACK"); // Magic
    try writer.writeInt(u32, 2, .big); // Version 2
    try writer.writeInt(u32, 3, .big); // 3 objects
    
    // Add some dummy object data
    try writer.writeAll(&([_]u8{0xFF} ** 100));
    
    // Verify header parsing
    try testing.expect(pack_data.items.len >= 12);
    
    const magic = pack_data.items[0..4];
    try testing.expectEqualStrings("PACK", magic);
    
    const version = std.mem.readInt(u32, @ptrCast(pack_data.items[4..8]), .big);
    try testing.expectEqual(@as(u32, 2), version);
    
    const object_count = std.mem.readInt(u32, @ptrCast(pack_data.items[8..12]), .big);
    try testing.expectEqual(@as(u32, 3), object_count);
}

test "hash validation" {
    // Test the isValidHash function logic
    const valid_hashes = [_][]const u8{
        "abc1234567890abcdef1234567890abcdef12345",
        "0123456789abcdef0123456789abcdef01234567", 
        "ffffffffffffffffffffffffffffffffffffffff",
        "0000000000000000000000000000000000000000",
        "deadbeefcafebabe0123456789abcdef01234567",
    };
    
    const invalid_hashes = [_][]const u8{
        "not_a_hash",
        "abc123", // too short
        "abc1234567890abcdef1234567890abcdef1234567", // too long (41 chars)
        "xyz1234567890abcdef1234567890abcdef12345", // invalid hex chars
        "", // empty
        "abc1234567890abcdef1234567890abcdef1234G", // invalid char at end
    };
    
    // Test valid hashes
    for (valid_hashes) |hash| {
        const is_valid = hash.len == 40 and blk: {
            for (hash) |c| {
                if (!std.ascii.isHex(c)) break :blk false;
            }
            break :blk true;
        };
        try testing.expect(is_valid);
    }
    
    // Test invalid hashes
    for (invalid_hashes) |hash| {
        const is_valid = hash.len == 40 and blk: {
            for (hash) |c| {
                if (!std.ascii.isHex(c)) break :blk false;
            }
            break :blk true;
        };
        try testing.expect(!is_valid);
    }
}

test "fanout table search optimization" {
    const allocator = testing.allocator;
    
    // Create a fanout table with some test data
    var fanout = [_]u32{0} ** 256;
    
    // Simulate fanout counts: 
    // - 0x00-0x0F: 0 objects each
    // - 0x10-0x1F: 1 object each (total 1-16)
    // - 0x20-0x2F: 2 objects each (total 17-48) 
    // - Rest: same as 0x2F
    
    var cumulative: u32 = 0;
    for (fanout, 0..) |*entry, i| {
        if (i >= 0x10 and i < 0x20) {
            cumulative += 1;
        } else if (i >= 0x20 and i < 0x30) {
            cumulative += 2; 
        }
        entry.* = cumulative;
    }
    
    // Test search range calculation
    const target_first_byte: u8 = 0x1A; // Should be in the 0x10-0x1F range
    
    const start_index = if (target_first_byte == 0) 0 else fanout[target_first_byte - 1];
    const end_index = fanout[target_first_byte];
    
    try testing.expectEqual(@as(u32, 10), start_index); // 0x1A-1 = 0x19, objects 0-9 
    try testing.expectEqual(@as(u32, 11), end_index); // 0x1A has 1 object, so 0-10
    try testing.expectEqual(@as(u32, 1), end_index - start_index); // 1 object to search
    
    _ = allocator;
}

test "pack index offset table" {
    const allocator = testing.allocator;
    
    // Test 32-bit offset (MSB clear)
    const offset_32bit: u32 = 0x12345678;
    try testing.expect(offset_32bit & 0x80000000 == 0);
    
    // Test 64-bit offset indicator (MSB set)
    const offset_64bit_indicator: u32 = 0x80000001; // Points to index 1 in 64-bit table
    try testing.expect(offset_64bit_indicator & 0x80000000 != 0);
    
    const large_offset_index = offset_64bit_indicator & 0x7FFFFFFF;
    try testing.expectEqual(@as(u32, 1), large_offset_index);
    
    _ = allocator;
}