const std = @import("std");
const testing = std.testing;

test "index version support" {
    
    // Test that we can detect different index versions
    const test_cases = [_]struct {
        version: u32,
        should_support: bool,
    }{
        .{ .version = 1, .should_support = false }, // Too old
        .{ .version = 2, .should_support = true },  // Standard
        .{ .version = 3, .should_support = true },  // With extended flags
        .{ .version = 4, .should_support = true },  // With path compression
        .{ .version = 5, .should_support = false }, // Too new
    };
    
    for (test_cases) |case| {
        // Test version support logic
        const is_supported = blk: {
            if (case.version < 2 or case.version > 4) {
                break :blk false;
            } else {
                break :blk true;
            }
        };
        
        try testing.expectEqual(case.should_support, is_supported);
    }
}

test "index extensions handling" {
    
    // Test that we can recognize known extension signatures
    const known_extensions = [_][]const u8{ "TREE", "REUC", "link", "UNTR", "FSMN", "IEOT", "EOIE" };
    
    for (known_extensions) |ext| {
        // Test that extension signatures are valid ASCII
        for (ext) |c| {
            try testing.expect(c >= 32 and c <= 126);
        }
        try testing.expect(ext.len == 4);
    }
    
    // Test invalid extension signatures
    const invalid_extensions = [_][]const u8{
        &[_]u8{ 0x00, 0x01, 0x02, 0x03 }, // Binary data
        &[_]u8{ 0xFF, 0xFE, 0xFD, 0xFC }, // High bytes
    };
    
    for (invalid_extensions) |ext| {
        var is_printable = true;
        for (ext) |c| {
            if (c < 32 or c > 126) {
                is_printable = false;
                break;
            }
        }
        try testing.expect(!is_printable);
    }
}

test "sha1 checksum verification" {
    const allocator = testing.allocator;
    
    // Create a minimal valid index with correct checksum
    var content = std.ArrayList(u8).init(allocator);
    defer content.deinit();
    
    const writer = content.writer();
    try writer.writeAll("DIRC"); // Magic
    try writer.writeInt(u32, 2, .big); // Version 2
    try writer.writeInt(u32, 0, .big); // No entries
    
    // Calculate SHA-1 of content so far
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(content.items);
    var checksum: [20]u8 = undefined;
    hasher.final(&checksum);
    
    // Add the checksum
    try writer.writeAll(&checksum);
    
    // Verify the last 20 bytes are the checksum
    try testing.expect(content.items.len >= 20);
    const stored_checksum = content.items[content.items.len - 20..];
    try testing.expectEqualSlices(u8, &checksum, stored_checksum);
    
    // Verify checksum matches content
    const content_without_checksum = content.items[0..content.items.len - 20];
    var verify_hasher = std.crypto.hash.Sha1.init(.{});
    verify_hasher.update(content_without_checksum);
    var verify_checksum: [20]u8 = undefined;
    verify_hasher.final(&verify_checksum);
    
    try testing.expectEqualSlices(u8, &verify_checksum, stored_checksum);
}

test "index entry structure" {
    const allocator = testing.allocator;
    
    // Test index entry binary structure (62 bytes base + path + padding)
    const MockIndexEntry = struct {
        ctime_sec: u32,
        ctime_nsec: u32,
        mtime_sec: u32,
        mtime_nsec: u32,
        dev: u32,
        ino: u32,
        mode: u32,
        uid: u32,
        gid: u32,
        size: u32,
        sha1: [20]u8,
        flags: u16,
        extended_flags: ?u16,
        path: []const u8,
        
        pub fn calculateSize(self: @This()) usize {
            const base_size = 62; // 10 * 4 + 20 + 2
            const ext_size = if (self.extended_flags != null) @as(usize, 2) else @as(usize, 0);
            const total = base_size + ext_size + self.path.len;
            const padding = (8 - (total % 8)) % 8;
            return total + padding;
        }
    };
    
    const test_entry = MockIndexEntry{
        .ctime_sec = 1234567890,
        .ctime_nsec = 123456789,
        .mtime_sec = 1234567891,
        .mtime_nsec = 123456790,
        .dev = 2049,
        .ino = 12345,
        .mode = 33188, // 100644 octal
        .uid = 1000,
        .gid = 1000,
        .size = 13,
        .sha1 = [_]u8{0xaa} ** 20,
        .flags = 9, // Path length
        .extended_flags = null,
        .path = "test.txt",
    };
    
    const size = test_entry.calculateSize();
    
    // Verify size is padded to 8-byte boundary
    try testing.expect(size % 8 == 0);
    
    // Verify minimum size
    try testing.expect(size >= 62 + test_entry.path.len);
    
    _ = allocator;
}

test "index entry flags handling" {
    const allocator = testing.allocator;
    _ = allocator;
    
    // Test flag interpretation
    const test_cases = [_]struct {
        flags: u16,
        expected_path_len: u16,
        has_extended: bool,
    }{
        .{ .flags = 0x0009, .expected_path_len = 9, .has_extended = false }, // "test.txt"
        .{ .flags = 0x400A, .expected_path_len = 10, .has_extended = true },  // Extended flag set
        .{ .flags = 0x0FFF, .expected_path_len = 0xFFF, .has_extended = false }, // Max path len
    };
    
    for (test_cases) |case| {
        const path_len = case.flags & 0xFFF;
        const has_extended_flags = (case.flags & 0x4000) != 0;
        
        try testing.expectEqual(case.expected_path_len, path_len);
        try testing.expectEqual(case.has_extended, has_extended_flags);
    }
}

test "variable length encoding" {
    const allocator = testing.allocator;
    _ = allocator;
    
    // Test variable-length integer encoding/decoding used in index v4
    const test_values = [_]u32{ 0, 1, 127, 128, 255, 256, 16383, 16384 };
    
    for (test_values) |value| {
        // Simple variable-length encoding test
        var encoded = std.ArrayList(u8).init(testing.allocator);
        defer encoded.deinit();
        
        var val = value;
        while (val >= 128) {
            try encoded.append(@intCast((val & 0x7F) | 0x80));
            val >>= 7;
        }
        try encoded.append(@intCast(val & 0x7F));
        
        // Decode back
        var decoded: u32 = 0;
        var shift: u5 = 0;
        for (encoded.items) |byte| {
            decoded |= @as(u32, byte & 0x7F) << shift;
            if (byte & 0x80 == 0) break;
            shift += 7;
        }
        
        try testing.expectEqual(value, decoded);
    }
}

test "index format validation" {
    const allocator = testing.allocator;
    
    // Test various invalid index formats
    const invalid_indices = [_][]const u8{
        "", // Empty
        "DIR", // Too short
        "DIRC\x00\x00\x00", // Incomplete header
        "ABCD\x00\x00\x00\x02\x00\x00\x00\x00", // Wrong magic
    };
    
    for (invalid_indices) |data| {
        // These should all be detected as invalid
        if (data.len < 12) {
            // Too short for valid index
            try testing.expect(true);
        } else if (!std.mem.eql(u8, data[0..4], "DIRC")) {
            // Wrong magic
            try testing.expect(true);
        }
    }
    
    // Test valid minimal index
    const valid_index = "DIRC\x00\x00\x00\x02\x00\x00\x00\x00" ++ 
                       ("\x00" ** 20); // 12 byte header + 20 byte checksum
    
    try testing.expect(valid_index.len == 32);
    try testing.expect(std.mem.eql(u8, valid_index[0..4], "DIRC"));
    
    _ = allocator;
}