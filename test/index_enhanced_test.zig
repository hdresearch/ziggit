const std = @import("std");
const testing = std.testing;
const index_mod = @import("../src/git/index.zig");

test "index entry creation and serialization" {
    const allocator = testing.allocator;
    
    // Create a mock file stat
    const file_stat = std.fs.File.Stat{
        .inode = 12345,
        .size = 100,
        .mode = 33188, // 0o100644
        .kind = .file,
        .atime = 1640995200000000000, // 2022-01-01 00:00:00 UTC in nanoseconds
        .mtime = 1640995200000000000,
        .ctime = 1640995200000000000,
    };
    
    const test_hash: [20]u8 = [_]u8{0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0} ++ [_]u8{0x11} ** 12;
    const test_path = "src/main.zig";
    
    // Create index entry
    const entry = index_mod.IndexEntry.init(test_path, file_stat, test_hash);
    
    // Verify fields
    try testing.expectEqual(@as(u32, 1640995200), entry.ctime_sec); // Unix timestamp
    try testing.expectEqual(@as(u32, 0), entry.ctime_nsec);
    try testing.expectEqual(@as(u32, 1640995200), entry.mtime_sec);
    try testing.expectEqual(@as(u32, 0), entry.mtime_nsec);
    try testing.expectEqual(@as(u32, 33188), entry.mode);
    try testing.expectEqual(@as(u32, 100), entry.size);
    try testing.expectEqualSlices(u8, &test_hash, &entry.sha1);
    try testing.expectEqual(@as(u16, test_path.len), entry.flags & 0xFFF);
    try testing.expectEqualStrings(test_path, entry.path);
    try testing.expect(entry.extended_flags == null);
    
    // Test serialization
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    
    try entry.writeToBuffer(buffer.writer());
    
    // Verify buffer has data
    try testing.expect(buffer.items.len > 62); // Minimum entry size
    
    // Test deserialization
    var stream = std.io.fixedBufferStream(buffer.items);
    const reader = stream.reader();
    
    const deserialized_entry = try index_mod.IndexEntry.readFromBuffer(reader, allocator);
    defer deserialized_entry.deinit(allocator);
    
    // Verify deserialized entry matches original
    try testing.expectEqual(entry.ctime_sec, deserialized_entry.ctime_sec);
    try testing.expectEqual(entry.mtime_sec, deserialized_entry.mtime_sec);
    try testing.expectEqual(entry.mode, deserialized_entry.mode);
    try testing.expectEqual(entry.size, deserialized_entry.size);
    try testing.expectEqualSlices(u8, &entry.sha1, &deserialized_entry.sha1);
    try testing.expectEqualStrings(entry.path, deserialized_entry.path);
}

test "index entry with extended flags" {
    const allocator = testing.allocator;
    
    const file_stat = std.fs.File.Stat{
        .inode = 67890,
        .size = 200,
        .mode = 33261, // 0o100755 (executable)
        .kind = .file,
        .atime = 1641081600000000000,
        .mtime = 1641081600000000000,
        .ctime = 1641081600000000000,
    };
    
    const test_hash: [20]u8 = [_]u8{0xaa, 0xbb, 0xcc, 0xdd} ++ [_]u8{0x22} ** 16;
    const test_path = "scripts/build.sh";
    
    var entry = index_mod.IndexEntry.init(test_path, file_stat, test_hash);
    
    // Add extended flags (simulate index v3+ with extended flags)
    entry.extended_flags = 0x1000; // Some extended flag
    entry.flags |= 0x4000; // Set bit 14 to indicate extended flags present
    
    // Test serialization with extended flags
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    
    try entry.writeToBuffer(buffer.writer());
    
    // Should be larger due to extended flags
    try testing.expect(buffer.items.len > 64);
    
    // Test deserialization
    var stream = std.io.fixedBufferStream(buffer.items);
    const reader = stream.reader();
    
    const deserialized_entry = try index_mod.IndexEntry.readFromBuffer(reader, allocator);
    defer deserialized_entry.deinit(allocator);
    
    // Verify extended flags are preserved
    try testing.expectEqual(@as(?u16, 0x1000), deserialized_entry.extended_flags);
    try testing.expect((deserialized_entry.flags & 0x4000) != 0);
    try testing.expectEqualStrings(entry.path, deserialized_entry.path);
}

test "index creation and manipulation" {
    const allocator = testing.allocator;
    
    var git_index = index_mod.Index.init(allocator);
    defer git_index.deinit();
    
    // Create test entries
    const entries_data = [_]struct {
        path: []const u8,
        size: u64,
        hash: [20]u8,
    }{
        .{ .path = "README.md", .size = 50, .hash = [_]u8{0x11} ** 20 },
        .{ .path = "src/main.zig", .size = 1000, .hash = [_]u8{0x22} ** 20 },
        .{ .path = "tests/test.zig", .size = 500, .hash = [_]u8{0x33} ** 20 },
    };
    
    // Add entries to index
    for (entries_data) |entry_data| {
        const file_stat = std.fs.File.Stat{
            .inode = 1000,
            .size = entry_data.size,
            .mode = 33188,
            .kind = .file,
            .atime = 1640995200000000000,
            .mtime = 1640995200000000000,
            .ctime = 1640995200000000000,
        };
        
        const entry = index_mod.IndexEntry.init(entry_data.path, file_stat, entry_data.hash);
        try git_index.entries.append(entry);
    }
    
    try testing.expectEqual(@as(usize, 3), git_index.entries.items.len);
    
    // Test entry lookup
    const main_entry = git_index.getEntry("src/main.zig");
    try testing.expect(main_entry != null);
    try testing.expectEqualStrings("src/main.zig", main_entry.?.path);
    try testing.expectEqual(@as(u32, 1000), main_entry.?.size);
    
    const nonexistent_entry = git_index.getEntry("nonexistent.txt");
    try testing.expect(nonexistent_entry == null);
    
    // Test entry removal
    try git_index.remove("README.md");
    try testing.expectEqual(@as(usize, 2), git_index.entries.items.len);
    try testing.expect(git_index.getEntry("README.md") == null);
    
    // Verify remaining entries
    try testing.expect(git_index.getEntry("src/main.zig") != null);
    try testing.expect(git_index.getEntry("tests/test.zig") != null);
}

test "index serialization and persistence" {
    const allocator = testing.allocator;
    
    // Create index with some entries
    var original_index = index_mod.Index.init(allocator);
    defer original_index.deinit();
    
    const test_entries = [_]struct {
        path: []const u8,
        hash: [20]u8,
    }{
        .{ .path = "file1.txt", .hash = [_]u8{0x01} ** 20 },
        .{ .path = "file2.txt", .hash = [_]u8{0x02} ** 20 },
        .{ .path = "dir/file3.txt", .hash = [_]u8{0x03} ** 20 },
    };
    
    for (test_entries) |entry_data| {
        const file_stat = std.fs.File.Stat{
            .inode = 1,
            .size = 100,
            .mode = 33188,
            .kind = .file,
            .atime = 1640995200000000000,
            .mtime = 1640995200000000000,
            .ctime = 1640995200000000000,
        };
        
        const entry = index_mod.IndexEntry.init(entry_data.path, file_stat, entry_data.hash);
        try original_index.entries.append(entry);
    }
    
    // Serialize to buffer
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    
    const writer = buffer.writer();
    
    // Write index header
    try writer.writeAll("DIRC");
    try writer.writeInt(u32, 2, .big); // Version 2
    try writer.writeInt(u32, @intCast(original_index.entries.items.len), .big);
    
    // Write entries
    for (original_index.entries.items) |entry| {
        try entry.writeToBuffer(writer);
    }
    
    // Calculate and write checksum
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(buffer.items);
    var checksum: [20]u8 = undefined;
    hasher.final(&checksum);
    try writer.writeAll(&checksum);
    
    // Verify buffer structure
    try testing.expect(buffer.items.len >= 12 + 20); // Header + checksum minimum
    try testing.expectEqualStrings("DIRC", buffer.items[0..4]);
    
    const version = std.mem.readInt(u32, @ptrCast(buffer.items[4..8]), .big);
    try testing.expectEqual(@as(u32, 2), version);
    
    const entry_count = std.mem.readInt(u32, @ptrCast(buffer.items[8..12]), .big);
    try testing.expectEqual(@as(u32, 3), entry_count);
    
    // Parse the serialized data
    var parsed_index = index_mod.Index.init(allocator);
    defer parsed_index.deinit();
    
    try parsed_index.parseIndexData(buffer.items);
    
    // Verify parsed index matches original
    try testing.expectEqual(original_index.entries.items.len, parsed_index.entries.items.len);
    
    for (original_index.entries.items, parsed_index.entries.items) |orig, parsed| {
        try testing.expectEqualStrings(orig.path, parsed.path);
        try testing.expectEqualSlices(u8, &orig.sha1, &parsed.sha1);
        try testing.expectEqual(orig.size, parsed.size);
        try testing.expectEqual(orig.mode, parsed.mode);
    }
}

test "index version support and error handling" {
    const allocator = testing.allocator;
    
    // Test invalid signature
    {
        var invalid_index = index_mod.Index.init(allocator);
        defer invalid_index.deinit();
        
        const invalid_data = "INVALID_SIGNATURE";
        try testing.expectError(error.InvalidIndex, invalid_index.parseIndexData(invalid_data));
    }
    
    // Test version 1 (should error)
    {
        var v1_index = index_mod.Index.init(allocator);
        defer v1_index.deinit();
        
        var v1_data = std.ArrayList(u8).init(allocator);
        defer v1_data.deinit();
        
        try v1_data.writer().writeAll("DIRC");
        try v1_data.writer().writeInt(u32, 1, .big); // Version 1
        try v1_data.writer().writeInt(u32, 0, .big); // No entries
        
        try testing.expectError(error.IndexVersionTooOld, v1_index.parseIndexData(v1_data.items));
    }
    
    // Test version 5 (should error)
    {
        var v5_index = index_mod.Index.init(allocator);
        defer v5_index.deinit();
        
        var v5_data = std.ArrayList(u8).init(allocator);
        defer v5_data.deinit();
        
        try v5_data.writer().writeAll("DIRC");
        try v5_data.writer().writeInt(u32, 5, .big); // Version 5 (future)
        try v5_data.writer().writeInt(u32, 0, .big); // No entries
        
        try testing.expectError(error.IndexVersionTooNew, v5_index.parseIndexData(v5_data.items));
    }
    
    // Test truncated data
    {
        var truncated_index = index_mod.Index.init(allocator);
        defer truncated_index.deinit();
        
        const truncated_data = "DIR"; // Too short
        try testing.expectError(error.InvalidIndex, truncated_index.parseIndexData(truncated_data));
    }
}

test "index checksum verification" {
    const allocator = testing.allocator;
    
    // Create valid index data
    var valid_data = std.ArrayList(u8).init(allocator);
    defer valid_data.deinit();
    
    const writer = valid_data.writer();
    try writer.writeAll("DIRC");
    try writer.writeInt(u32, 2, .big); // Version 2
    try writer.writeInt(u32, 0, .big); // No entries
    
    // Calculate correct checksum
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(valid_data.items);
    var correct_checksum: [20]u8 = undefined;
    hasher.final(&correct_checksum);
    try writer.writeAll(&correct_checksum);
    
    // Test with correct checksum
    {
        var good_index = index_mod.Index.init(allocator);
        defer good_index.deinit();
        
        try good_index.parseIndexData(valid_data.items);
        try testing.expectEqual(@as(usize, 0), good_index.entries.items.len);
    }
    
    // Test with incorrect checksum
    {
        var bad_index = index_mod.Index.init(allocator);
        defer bad_index.deinit();
        
        var corrupted_data = try allocator.dupe(u8, valid_data.items);
        defer allocator.free(corrupted_data);
        
        // Corrupt the checksum
        corrupted_data[corrupted_data.len - 1] ^= 0xFF;
        
        try testing.expectError(error.ChecksumMismatch, bad_index.parseIndexData(corrupted_data));
    }
}

test "index extensions handling" {
    const allocator = testing.allocator;
    
    // Create index data with extensions
    var data_with_extensions = std.ArrayList(u8).init(allocator);
    defer data_with_extensions.deinit();
    
    const writer = data_with_extensions.writer();
    
    // Write header
    try writer.writeAll("DIRC");
    try writer.writeInt(u32, 2, .big); // Version 2
    try writer.writeInt(u32, 0, .big); // No entries
    
    // Write TREE extension
    try writer.writeAll("TREE");
    try writer.writeInt(u32, 20, .big); // Extension size
    try writer.writeAll(&([_]u8{0x00} ** 20)); // Dummy extension data
    
    // Write REUC extension  
    try writer.writeAll("REUC");
    try writer.writeInt(u32, 10, .big); // Extension size
    try writer.writeAll(&([_]u8{0xFF} ** 10)); // Dummy extension data
    
    // Calculate checksum over everything so far
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(data_with_extensions.items);
    var checksum: [20]u8 = undefined;
    hasher.final(&checksum);
    try writer.writeAll(&checksum);
    
    // Test parsing - should succeed and skip extensions
    var index_with_extensions = index_mod.Index.init(allocator);
    defer index_with_extensions.deinit();
    
    try index_with_extensions.parseIndexData(data_with_extensions.items);
    try testing.expectEqual(@as(usize, 0), index_with_extensions.entries.items.len);
}

test "index path sorting" {
    const allocator = testing.allocator;
    
    var git_index = index_mod.Index.init(allocator);
    defer git_index.deinit();
    
    // Add entries in non-alphabetical order
    const unsorted_paths = [_][]const u8{
        "zzz.txt",
        "aaa.txt", 
        "mmm.txt",
        "dir/file.txt",
        "dir/aaa.txt",
        "dir/zzz.txt",
    };
    
    const expected_sorted = [_][]const u8{
        "aaa.txt",
        "dir/aaa.txt", 
        "dir/file.txt",
        "dir/zzz.txt",
        "mmm.txt",
        "zzz.txt",
    };
    
    // Add entries
    for (unsorted_paths) |path| {
        const file_stat = std.fs.File.Stat{
            .inode = 1,
            .size = 100,
            .mode = 33188,
            .kind = .file,
            .atime = 1640995200000000000,
            .mtime = 1640995200000000000,
            .ctime = 1640995200000000000,
        };
        
        const hash = [_]u8{0xAA} ** 20;
        const entry = index_mod.IndexEntry.init(path, file_stat, hash);
        try git_index.entries.append(entry);
    }
    
    // Sort entries
    std.sort.block(index_mod.IndexEntry, git_index.entries.items, {}, struct {
        fn lessThan(context: void, lhs: index_mod.IndexEntry, rhs: index_mod.IndexEntry) bool {
            _ = context;
            return std.mem.lessThan(u8, lhs.path, rhs.path);
        }
    }.lessThan);
    
    // Verify sorting
    for (expected_sorted, git_index.entries.items) |expected, actual| {
        try testing.expectEqualStrings(expected, actual.path);
    }
}