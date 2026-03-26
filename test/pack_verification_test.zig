const std = @import("std");
const testing = std.testing;
const objects = @import("../src/git/objects.zig");

test "pack file verification and optimization" {
    const allocator = testing.allocator;
    
    // Create a mock platform for testing
    const TestPlatform = struct {
        const fs = struct {
            pub fn readFile(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
                _ = alloc;
                
                // Create a minimal valid pack file data for testing
                if (std.mem.endsWith(u8, path, ".pack")) {
                    // Create minimal pack file: header + object + checksum
                    var pack_data = std.ArrayList(u8).init(alloc);
                    defer pack_data.deinit();
                    
                    // Header: PACK + version 2 + 1 object
                    try pack_data.appendSlice("PACK");
                    try pack_data.writer().writeInt(u32, 2, .big);
                    try pack_data.writer().writeInt(u32, 1, .big);
                    
                    // Minimal object: blob with size 5 (0x15 = type 3, size 5)
                    try pack_data.append(0x15); // type=blob(3), size=5
                    // Compressed "hello" using simple compression
                    try pack_data.appendSlice(&[_]u8{0x78, 0x9c, 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0x00, 0x05, 0x8c, 0x01, 0xf5});
                    
                    // Calculate and append SHA-1 checksum
                    var hasher = std.crypto.hash.Sha1.init(.{});
                    hasher.update(pack_data.items);
                    var checksum: [20]u8 = undefined;
                    hasher.final(&checksum);
                    try pack_data.appendSlice(&checksum);
                    
                    return try alloc.dupe(u8, pack_data.items);
                } else {
                    return error.FileNotFound;
                }
            }
        };
    };
    
    // Test pack file verification
    const temp_pack_path = "/tmp/test.pack";
    
    const verification_result = try objects.verifyPackFile(temp_pack_path, TestPlatform, allocator);
    defer verification_result.deinit();
    
    // Verify the verification results
    try testing.expect(verification_result.header_valid);
    try testing.expect(verification_result.checksum_valid);
    try testing.expect(verification_result.total_objects == 1);
    try testing.expect(verification_result.objects_readable == 1);
    try testing.expect(verification_result.corrupted_objects.items.len == 0);
    try testing.expect(verification_result.isHealthy());
    
    verification_result.print();
    
    std.debug.print("Pack file verification test completed successfully\n", .{});
}

test "pack file stats analysis" {
    const allocator = testing.allocator;
    
    const TestPlatform = struct {
        const fs = struct {
            pub fn readFile(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
                _ = alloc;
                
                if (std.mem.endsWith(u8, path, ".pack")) {
                    // Create a pack file with more interesting structure
                    var pack_data = std.ArrayList(u8).init(alloc);
                    defer pack_data.deinit();
                    
                    // Header: PACK + version 2 + 3 objects
                    try pack_data.appendSlice("PACK");
                    try pack_data.writer().writeInt(u32, 2, .big);
                    try pack_data.writer().writeInt(u32, 3, .big);
                    
                    // Object 1: blob
                    try pack_data.append(0x15); // type=blob(3), size=5
                    try pack_data.appendSlice(&[_]u8{0x78, 0x9c, 0xcb, 0x48, 0x01, 0x00, 0x01, 0x00, 0x00, 0xff});
                    
                    // Object 2: tree 
                    try pack_data.append(0x22); // type=tree(2), size=2
                    try pack_data.appendSlice(&[_]u8{0x78, 0x9c, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01});
                    
                    // Object 3: commit
                    try pack_data.append(0x11); // type=commit(1), size=1
                    try pack_data.appendSlice(&[_]u8{0x78, 0x9c, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01});
                    
                    // Pad to have some reasonable size
                    const padding_size = 100;
                    for (0..padding_size) |_| {
                        try pack_data.append(0);
                    }
                    
                    // Calculate and append SHA-1 checksum
                    var hasher = std.crypto.hash.Sha1.init(.{});
                    hasher.update(pack_data.items);
                    var checksum: [20]u8 = undefined;
                    hasher.final(&checksum);
                    try pack_data.appendSlice(&checksum);
                    
                    return try alloc.dupe(u8, pack_data.items);
                } else {
                    return error.FileNotFound;
                }
            }
        };
    };
    
    const stats = try objects.analyzePackFile("/tmp/test.pack", TestPlatform, allocator);
    
    try testing.expect(stats.total_objects == 3);
    try testing.expect(stats.version == 2);
    try testing.expect(stats.checksum_valid);
    try testing.expect(stats.file_size > 100); // Should have some size
    
    stats.print();
    
    const compression_ratio = stats.getCompressionRatio();
    try testing.expect(compression_ratio > 0.0);
    
    std.debug.print("Pack file statistics analysis completed successfully\n", .{});
}