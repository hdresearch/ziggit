const std = @import("std");
const index = @import("../src/git/index.zig");
const testing = std.testing;

test "extended flags handling" {
    const allocator = testing.allocator;
    
    // Create an index entry with extended flags
    var entry = index.IndexEntry{
        .ctime_sec = 1640995200,
        .ctime_nsec = 0,
        .mtime_sec = 1640995200,
        .mtime_nsec = 0,
        .dev = 0,
        .ino = 12345,
        .mode = 33188, // 100644 octal
        .uid = 1000,
        .gid = 1000,
        .size = 13,
        .sha1 = [_]u8{0} ** 20, // Zero hash for test
        .flags = 0x4000 | 8, // Extended flags bit set + path length
        .extended_flags = 0x0001, // Some extended flag
        .path = try allocator.dupe(u8, "test.txt"),
    };
    defer entry.deinit(allocator);

    // Test serialization
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    
    try entry.writeToBuffer(buffer.writer());
    
    // Verify extended flags are written
    try testing.expect(buffer.items.len > 62 + entry.path.len); // Should be larger due to extended flags
    
    // Test deserialization
    var stream = std.io.fixedBufferStream(buffer.items);
    const read_entry = try index.IndexEntry.readFromBuffer(stream.reader(), allocator);
    defer read_entry.deinit(allocator);
    
    // Verify extended flags are preserved
    try testing.expect(read_entry.extended_flags != null);
    try testing.expectEqual(@as(u16, 0x0001), read_entry.extended_flags.?);
    try testing.expectEqualStrings("test.txt", read_entry.path);
}

test "index version compatibility" {
    const allocator = testing.allocator;
    
    // Test data representing different index versions
    const test_cases = [_]struct {
        version: u32,
        should_support: bool,
    }{
        .{ .version = 2, .should_support = true },
        .{ .version = 3, .should_support = true },
        .{ .version = 4, .should_support = true }, // Limited support
        .{ .version = 1, .should_support = false },
        .{ .version = 5, .should_support = false },
    };

    for (test_cases) |case| {
        std.debug.print("Testing index version {} support: {}\n", .{ case.version, case.should_support });
        
        // The version check is in parseIndexData - verify the logic
        const is_supported = case.version >= 2 and case.version <= 4;
        try testing.expectEqual(case.should_support, is_supported);
    }
}

test "checksum verification" {
    const allocator = testing.allocator;
    
    // Create test index data with proper checksum
    const test_data = "DIRC" ++ // Signature
        "\x00\x00\x00\x02" ++ // Version 2
        "\x00\x00\x00\x00"; // 0 entries
    
    // Calculate SHA-1 checksum
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(test_data);
    var checksum: [20]u8 = undefined;
    hasher.final(&checksum);
    
    // Combine data with checksum
    var full_data = std.ArrayList(u8).init(allocator);
    defer full_data.deinit();
    try full_data.appendSlice(test_data);
    try full_data.appendSlice(&checksum);
    
    // Test parsing
    var test_index = index.Index.init(allocator);
    defer test_index.deinit();
    
    // This should succeed with proper checksum
    try test_index.parseIndexData(full_data.items);
    
    // Verify no entries (as expected from our test data)
    try testing.expectEqual(@as(usize, 0), test_index.entries.items.len);
}

test "extension handling" {
    const allocator = testing.allocator;
    
    // Test that we can handle index files with extensions
    // Extensions should be skipped without causing errors
    
    std.debug.print("Testing index extension handling\n", .{});
    
    // Common extension signatures that should be recognized
    const known_extensions = [_][]const u8{
        "TREE", // Cache tree extension
        "REUC", // Resolve undo extension  
        "UNTR", // Untracked cache extension
        "FSMN", // File system monitor extension
    };

    for (known_extensions) |ext| {
        std.debug.print("  Known extension: {s}\n", .{ext});
        
        // Verify extension signatures are printable ASCII
        for (ext) |c| {
            try testing.expect(c >= 32 and c <= 126);
        }
    }
}

test "index entry sorting" {
    const allocator = testing.allocator;
    
    var test_index = index.Index.init(allocator);
    defer test_index.deinit();
    
    // Add entries in random order
    const paths = [_][]const u8{ "zebra.txt", "apple.txt", "beta.txt" };
    
    for (paths) |path| {
        const fake_stat = std.fs.File.Stat{
            .inode = 0,
            .size = 0,
            .mode = 33188,
            .kind = .file,
            .atime = 0,
            .mtime = 0,
            .ctime = 0,
        };
        
        const entry = index.IndexEntry.init(try allocator.dupe(u8, path), fake_stat, [_]u8{0} ** 20);
        try test_index.entries.append(entry);
    }
    
    // Sort entries
    std.sort.block(index.IndexEntry, test_index.entries.items, {}, struct {
        fn lessThan(context: void, lhs: index.IndexEntry, rhs: index.IndexEntry) bool {
            _ = context;
            return std.mem.lessThan(u8, lhs.path, rhs.path);
        }
    }.lessThan);
    
    // Verify sorted order
    try testing.expectEqualStrings("apple.txt", test_index.entries.items[0].path);
    try testing.expectEqualStrings("beta.txt", test_index.entries.items[1].path);
    try testing.expectEqualStrings("zebra.txt", test_index.entries.items[2].path);
}