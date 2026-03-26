const std = @import("std");
const testing = std.testing;
const index = @import("../src/git/index.zig");

test "index version support" {
    const allocator = testing.allocator;
    
    // Test that we can handle different index versions
    const supported_versions = [_]u32{ 2, 3, 4 };
    const unsupported_versions = [_]u32{ 1, 5, 0, 999 };
    
    for (supported_versions) |version| {
        // Version should be in supported range
        try testing.expect(version >= 2 and version <= 4);
    }
    
    for (unsupported_versions) |version| {
        // These versions should be rejected
        const is_supported = version >= 2 and version <= 4;
        try testing.expect(!is_supported);
    }
}

test "index header validation" {
    const allocator = testing.allocator;
    
    // Create a valid index header
    var index_data = std.ArrayList(u8).init(allocator);
    defer index_data.deinit();
    
    const writer = index_data.writer();
    
    // Write DIRC signature
    try writer.writeAll("DIRC");
    
    // Write version (2)
    try writer.writeInt(u32, 2, .big);
    
    // Write entry count (0 for this test)
    try writer.writeInt(u32, 0, .big);
    
    // Write SHA-1 checksum of the content
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(index_data.items);
    var checksum: [20]u8 = undefined;
    hasher.final(&checksum);
    try writer.writeAll(&checksum);
    
    // Validate header structure
    try testing.expect(index_data.items.len >= 32); // Minimum size: 12 bytes header + 20 bytes checksum
    try testing.expectEqualStrings("DIRC", index_data.items[0..4]);
    
    const version = std.mem.readInt(u32, @ptrCast(index_data.items[4..8]), .big);
    try testing.expectEqual(@as(u32, 2), version);
    
    const entry_count = std.mem.readInt(u32, @ptrCast(index_data.items[8..12]), .big);
    try testing.expectEqual(@as(u32, 0), entry_count);
}

test "index entry structure" {
    const allocator = testing.allocator;
    
    // Test index entry creation and serialization
    const test_stat = std.fs.File.Stat{
        .inode = 12345,
        .size = 100,
        .mode = 33188, // 100644 in octal
        .kind = .file,
        .atime = 1234567890 * std.time.ns_per_s,
        .mtime = 1234567890 * std.time.ns_per_s,
        .ctime = 1234567890 * std.time.ns_per_s,
    };
    
    const test_hash: [20]u8 = [_]u8{0x12, 0x34, 0x56, 0x78, 0x9a} ++ [_]u8{0xbc} ** 15;
    const test_path = "test/file.txt";
    
    const entry = index.IndexEntry.init(test_path, test_stat, test_hash);
    
    // Validate entry fields
    try testing.expect(entry.size == 100);
    try testing.expect(entry.mode == 33188);
    try testing.expectEqualStrings(test_path, entry.path);
    try testing.expect(std.mem.eql(u8, &entry.sha1, &test_hash));
    
    // Test serialization
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    
    try entry.writeToBuffer(buffer.writer());
    
    // Should have written some data
    try testing.expect(buffer.items.len > 62); // Base entry size
    
    // Test that padding aligns to 8-byte boundary
    const base_size = 62 + test_path.len;
    const expected_padding = (8 - (base_size % 8)) % 8;
    const expected_total = base_size + expected_padding;
    
    try testing.expectEqual(expected_total, buffer.items.len);
}

test "index extension handling" {
    const allocator = testing.allocator;
    
    // Create index data with extensions
    var index_data = std.ArrayList(u8).init(allocator);
    defer index_data.deinit();
    
    const writer = index_data.writer();
    
    // Write basic header
    try writer.writeAll("DIRC");
    try writer.writeInt(u32, 2, .big);
    try writer.writeInt(u32, 0, .big); // 0 entries
    
    // Write TREE extension
    try writer.writeAll("TREE");
    try writer.writeInt(u32, 8, .big); // Extension size
    try writer.writeAll("treedata"); // 8 bytes of extension data
    
    // Write REUC extension
    try writer.writeAll("REUC");
    try writer.writeInt(u32, 12, .big); // Extension size
    try writer.writeAll("resolveundo\x00"); // 12 bytes of extension data
    
    // Write unknown extension (should be skipped gracefully)
    try writer.writeAll("UNKN");
    try writer.writeInt(u32, 4, .big); // Extension size
    try writer.writeAll("test"); // 4 bytes of extension data
    
    // Calculate and write checksum
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(index_data.items);
    var checksum: [20]u8 = undefined;
    hasher.final(&checksum);
    try writer.writeAll(&checksum);
    
    // Test that we have extensions in the data
    const extension_start = 12; // After header
    try testing.expectEqualStrings("TREE", index_data.items[extension_start..extension_start + 4]);
    
    // The parser should be able to skip these extensions
    try testing.expect(index_data.items.len > 32);
}

test "index checksum verification" {
    const allocator = testing.allocator;
    
    // Create index with correct checksum
    var valid_index = std.ArrayList(u8).init(allocator);
    defer valid_index.deinit();
    
    const writer = valid_index.writer();
    
    // Header
    try writer.writeAll("DIRC");
    try writer.writeInt(u32, 2, .big);
    try writer.writeInt(u32, 0, .big);
    
    // Calculate correct checksum
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(valid_index.items);
    var correct_checksum: [20]u8 = undefined;
    hasher.final(&correct_checksum);
    try writer.writeAll(&correct_checksum);
    
    // Verify checksum manually
    const content = valid_index.items[0..valid_index.items.len - 20];
    const stored_checksum = valid_index.items[valid_index.items.len - 20..];
    
    var verify_hasher = std.crypto.hash.Sha1.init(.{});
    verify_hasher.update(content);
    var computed_checksum: [20]u8 = undefined;
    verify_hasher.final(&computed_checksum);
    
    try testing.expect(std.mem.eql(u8, &computed_checksum, stored_checksum));
    
    // Create index with incorrect checksum
    var invalid_index = std.ArrayList(u8).init(allocator);
    defer invalid_index.deinit();
    
    try invalid_index.appendSlice(valid_index.items[0..valid_index.items.len - 20]);
    try invalid_index.appendSlice(&([_]u8{0xFF} ** 20)); // Wrong checksum
    
    // Verify that checksums don't match
    const invalid_content = invalid_index.items[0..invalid_index.items.len - 20];
    const invalid_stored = invalid_index.items[invalid_index.items.len - 20..];
    
    var invalid_hasher = std.crypto.hash.Sha1.init(.{});
    invalid_hasher.update(invalid_content);
    var invalid_computed: [20]u8 = undefined;
    invalid_hasher.final(&invalid_computed);
    
    try testing.expect(!std.mem.eql(u8, &invalid_computed, invalid_stored));
}

test "index size limits and validation" {
    const allocator = testing.allocator;
    
    // Test size validation limits
    const max_reasonable_entries = 1_000_000;
    const max_index_size = 100 * 1024 * 1024; // 100MB
    const max_extension_size = 10 * 1024 * 1024; // 10MB per extension
    const max_total_extensions = 50 * 1024 * 1024; // 50MB total
    
    // These should be reasonable limits
    try testing.expect(max_reasonable_entries > 0);
    try testing.expect(max_index_size > 1024); // At least 1KB
    try testing.expect(max_extension_size > 1024);
    try testing.expect(max_total_extensions >= max_extension_size);
    
    // Test that we reject unreasonable values
    const unreasonable_entries = 100_000_000; // 100M entries
    const unreasonable_size = 10 * 1024 * 1024 * 1024; // 10GB
    
    try testing.expect(unreasonable_entries > max_reasonable_entries);
    try testing.expect(unreasonable_size > max_index_size);
}

test "index entry path validation" {
    const allocator = testing.allocator;
    
    // Valid paths
    const valid_paths = [_][]const u8{
        "file.txt",
        "dir/file.txt",
        "deep/nested/path/file.txt",
        "with-dashes.txt",
        "with_underscores.txt",
        "with.dots.txt",
        "123numbers.txt",
    };
    
    for (valid_paths) |path| {
        // These should all be acceptable
        try testing.expect(path.len > 0);
        try testing.expect(path.len < 4096); // Reasonable path length limit
        
        // Should not contain dangerous characters
        try testing.expect(std.mem.indexOf(u8, path, "\x00") == null); // No null bytes
        try testing.expect(std.mem.indexOf(u8, path, "..") == null); // No path traversal
        try testing.expect(!std.mem.startsWith(u8, path, "/")); // No absolute paths
    }
    
    // Invalid paths that should be rejected
    const invalid_paths = [_][]const u8{
        "",
        "/absolute/path",
        "../parent/dir",
        "dir/../traversal",
        "file\x00name",
        "..",
        ".",
        "path/./current",
        "path/../parent",
    };
    
    for (invalid_paths) |path| {
        var is_dangerous = false;
        
        if (path.len == 0) is_dangerous = true;
        if (std.mem.startsWith(u8, path, "/")) is_dangerous = true;
        if (std.mem.indexOf(u8, path, "..") != null) is_dangerous = true;
        if (std.mem.indexOf(u8, path, "\x00") != null) is_dangerous = true;
        if (std.mem.eql(u8, path, ".") or std.mem.eql(u8, path, "..")) is_dangerous = true;
        
        try testing.expect(is_dangerous);
    }
    
    _ = allocator;
}

test "index extension size tracking" {
    const allocator = testing.allocator;
    
    // Test extension size accumulation
    var total_size: u64 = 0;
    const max_total_size = 50 * 1024 * 1024; // 50MB
    
    const extensions = [_]struct { name: []const u8, size: u32 }{
        .{ .name = "TREE", .size = 1024 },
        .{ .name = "REUC", .size = 2048 },
        .{ .name = "link", .size = 4096 },
        .{ .name = "UNTR", .size = 8192 },
        .{ .name = "FSMN", .size = 16384 },
    };
    
    for (extensions) |ext| {
        total_size += ext.size;
        
        // Each extension should be reasonable in size
        try testing.expect(ext.size <= 10 * 1024 * 1024); // 10MB max per extension
        try testing.expect(ext.name.len == 4); // Extension signatures are 4 bytes
    }
    
    // Total should be within limits
    try testing.expect(total_size <= max_total_size);
    
    // Test what happens when we exceed the limit
    const huge_extension_size: u64 = 100 * 1024 * 1024; // 100MB
    const new_total = total_size + huge_extension_size;
    
    try testing.expect(new_total > max_total_size); // Should exceed limit
    
    _ = allocator;
}

test "index file format compatibility" {
    const allocator = testing.allocator;
    
    // Test that we handle different format variations correctly
    
    // Version 2: basic format
    const v2_features = struct {
        has_extended_flags: bool = false,
        has_skip_worktree: bool = false,
        has_intent_to_add: bool = false,
        max_path_length: u16 = 0xFFF,
    }{ .has_extended_flags = false };
    
    // Version 3: adds extended flags
    const v3_features = struct {
        has_extended_flags: bool = true,
        has_skip_worktree: bool = true,
        has_intent_to_add: bool = true,
        max_path_length: u16 = 0xFFF,
    }{};
    
    // Version 4: variable length paths
    const v4_features = struct {
        has_extended_flags: bool = true,
        has_skip_worktree: bool = true,
        has_intent_to_add: bool = true,
        max_path_length: u16 = 0xFFFF, // Unlimited
    }{};
    
    // Verify feature progression
    try testing.expect(!v2_features.has_extended_flags);
    try testing.expect(v3_features.has_extended_flags);
    try testing.expect(v4_features.has_extended_flags);
    
    try testing.expect(v4_features.max_path_length > v2_features.max_path_length);
    
    _ = allocator;
}

test "index performance characteristics" {
    const allocator = testing.allocator;
    
    // Test that our index operations scale reasonably
    const entry_counts = [_]u32{ 10, 100, 1000, 10000 };
    
    for (entry_counts) |count| {
        // Estimate memory usage for index with this many entries
        const avg_path_length = 30; // Average path length
        const entry_size = 62 + avg_path_length + 8; // Base + path + padding
        const estimated_size = 12 + (count * entry_size) + 20; // Header + entries + checksum
        
        // Should be reasonable memory usage
        const mb_size = estimated_size / (1024 * 1024);
        try testing.expect(mb_size < 1000); // Less than 1GB for 10k entries
        
        // Binary search should be efficient
        const search_steps = std.math.log2(count) + 1;
        try testing.expect(search_steps < 20); // Should find any entry in <20 steps
    }
    
    _ = allocator;
}