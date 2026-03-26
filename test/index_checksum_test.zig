const std = @import("std");
const testing = std.testing;
const index_mod = @import("../src/git/index.zig");

test "index checksum verification with corrupted data" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    // Create a valid index structure
    var valid_index = std.ArrayList(u8).init(allocator);
    defer valid_index.deinit();
    
    // Header: "DIRC" + version + entry count
    try valid_index.appendSlice("DIRC");
    try valid_index.writer().writeInt(u32, 2, .big); // Version 2
    try valid_index.writer().writeInt(u32, 1, .big); // 1 entry
    
    // Single index entry (minimal valid entry)
    const entry_start = valid_index.items.len;
    
    // Entry data (62 bytes minimum)
    try valid_index.writer().writeInt(u32, 1234567890, .big); // ctime_sec
    try valid_index.writer().writeInt(u32, 0, .big);          // ctime_nsec
    try valid_index.writer().writeInt(u32, 1234567890, .big); // mtime_sec
    try valid_index.writer().writeInt(u32, 0, .big);          // mtime_nsec
    try valid_index.writer().writeInt(u32, 1, .big);          // dev
    try valid_index.writer().writeInt(u32, 12345, .big);      // ino
    try valid_index.writer().writeInt(u32, 0o100644, .big);   // mode
    try valid_index.writer().writeInt(u32, 1000, .big);       // uid
    try valid_index.writer().writeInt(u32, 1000, .big);       // gid
    try valid_index.writer().writeInt(u32, 13, .big);         // size
    
    // SHA-1 hash
    const test_hash = [_]u8{0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0} ++ [_]u8{0} ** 12;
    try valid_index.appendSlice(&test_hash);
    
    try valid_index.writer().writeInt(u16, 9, .big); // flags (path length = 9)
    
    // Path
    try valid_index.appendSlice("test.txt");
    try valid_index.append(0); // Null terminator part of path
    
    // Padding to 8-byte boundary
    const entry_len = valid_index.items.len - entry_start;
    const pad_len = (8 - (entry_len % 8)) % 8;
    for (0..pad_len) |_| {
        try valid_index.append(0);
    }
    
    // Calculate correct checksum for the content so far
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(valid_index.items);
    var correct_checksum: [20]u8 = undefined;
    hasher.final(&correct_checksum);
    try valid_index.appendSlice(&correct_checksum);
    
    // Test 1: Valid index should parse without error
    var valid_idx = index_mod.Index.init(allocator);
    defer valid_idx.deinit();
    
    try valid_idx.parseIndexData(valid_index.items);
    try testing.expectEqual(@as(usize, 1), valid_idx.entries.items.len);
    try testing.expectEqualStrings("test.txt", valid_idx.entries.items[0].path);
    
    // Test 2: Corrupted checksum should fail
    var corrupted_checksum = try allocator.dupe(u8, valid_index.items);
    defer allocator.free(corrupted_checksum);
    
    // Corrupt the last byte of the checksum
    corrupted_checksum[corrupted_checksum.len - 1] ^= 0xFF;
    
    var corrupted_idx = index_mod.Index.init(allocator);
    defer corrupted_idx.deinit();
    
    try testing.expectError(error.ChecksumMismatch, corrupted_idx.parseIndexData(corrupted_checksum));
    
    // Test 3: Truncated index should fail
    const truncated = valid_index.items[0..valid_index.items.len - 10];
    var truncated_idx = index_mod.Index.init(allocator);
    defer truncated_idx.deinit();
    
    try testing.expectError(error.InvalidIndex, truncated_idx.parseIndexData(truncated));
    
    // Test 4: Invalid signature should fail
    var invalid_sig = try allocator.dupe(u8, valid_index.items);
    defer allocator.free(invalid_sig);
    invalid_sig[0] = 'X'; // Change "DIRC" to "XIRC"
    
    var invalid_sig_idx = index_mod.Index.init(allocator);
    defer invalid_sig_idx.deinit();
    
    try testing.expectError(error.InvalidIndex, invalid_sig_idx.parseIndexData(invalid_sig));
}

test "index version 3 and 4 support" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    // Test version 3 index with extended flags
    var v3_index = std.ArrayList(u8).init(allocator);
    defer v3_index.deinit();
    
    // Header for version 3
    try v3_index.appendSlice("DIRC");
    try v3_index.writer().writeInt(u32, 3, .big); // Version 3
    try v3_index.writer().writeInt(u32, 1, .big); // 1 entry
    
    // Entry with extended flags
    try v3_index.writer().writeInt(u32, 1234567890, .big); // ctime_sec
    try v3_index.writer().writeInt(u32, 0, .big);          // ctime_nsec
    try v3_index.writer().writeInt(u32, 1234567890, .big); // mtime_sec
    try v3_index.writer().writeInt(u32, 0, .big);          // mtime_nsec
    try v3_index.writer().writeInt(u32, 1, .big);          // dev
    try v3_index.writer().writeInt(u32, 12345, .big);      // ino
    try v3_index.writer().writeInt(u32, 0o100644, .big);   // mode
    try v3_index.writer().writeInt(u32, 1000, .big);       // uid
    try v3_index.writer().writeInt(u32, 1000, .big);       // gid
    try v3_index.writer().writeInt(u32, 15, .big);         // size
    
    const test_hash = [_]u8{0xab, 0xcd, 0xef} ++ [_]u8{0} ** 17;
    try v3_index.appendSlice(&test_hash);
    
    // Flags with extended flag bit set
    const flags_with_ext: u16 = 0x4000 | 11; // Extended flags present + path length
    try v3_index.writer().writeInt(u16, flags_with_ext, .big);
    
    // Extended flags
    try v3_index.writer().writeInt(u16, 0x0001, .big); // Some extended flag
    
    // Path
    try v3_index.appendSlice("test_v3.txt");
    
    // Padding (calculate based on full entry size including extended flags)
    const entry_base = 62 + 2 + 11; // base + extended flags + path
    const pad_len = (8 - (entry_base % 8)) % 8;
    for (0..pad_len) |_| {
        try v3_index.append(0);
    }
    
    // Checksum
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(v3_index.items);
    var checksum: [20]u8 = undefined;
    hasher.final(&checksum);
    try v3_index.appendSlice(&checksum);
    
    // Test parsing version 3
    var idx_v3 = index_mod.Index.init(allocator);
    defer idx_v3.deinit();
    
    try idx_v3.parseIndexData(v3_index.items);
    try testing.expectEqual(@as(usize, 1), idx_v3.entries.items.len);
    try testing.expectEqualStrings("test_v3.txt", idx_v3.entries.items[0].path);
    try testing.expect(idx_v3.entries.items[0].extended_flags != null);
    try testing.expectEqual(@as(u16, 0x0001), idx_v3.entries.items[0].extended_flags.?);
}

test "index extension handling" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    // Create an index with extensions
    var index_with_ext = std.ArrayList(u8).init(allocator);
    defer index_with_ext.deinit();
    
    // Header
    try index_with_ext.appendSlice("DIRC");
    try index_with_ext.writer().writeInt(u32, 2, .big); // Version 2
    try index_with_ext.writer().writeInt(u32, 1, .big); // 1 entry
    
    // Single simple entry
    try index_with_ext.writer().writeInt(u32, 1234567890, .big); // ctime_sec
    try index_with_ext.writer().writeInt(u32, 0, .big);          // ctime_nsec
    try index_with_ext.writer().writeInt(u32, 1234567890, .big); // mtime_sec
    try index_with_ext.writer().writeInt(u32, 0, .big);          // mtime_nsec
    try index_with_ext.writer().writeInt(u32, 1, .big);          // dev
    try index_with_ext.writer().writeInt(u32, 12345, .big);      // ino
    try index_with_ext.writer().writeInt(u32, 0o100644, .big);   // mode
    try index_with_ext.writer().writeInt(u32, 1000, .big);       // uid
    try index_with_ext.writer().writeInt(u32, 1000, .big);       // gid
    try index_with_ext.writer().writeInt(u32, 4, .big);          // size
    
    const test_hash = [_]u8{0x11, 0x22, 0x33} ++ [_]u8{0} ** 17;
    try index_with_ext.appendSlice(&test_hash);
    
    try index_with_ext.writer().writeInt(u16, 8, .big); // flags (path length = 8)
    
    // Path with padding
    try index_with_ext.appendSlice("test.txt");
    
    // Calculate padding for entry
    const entry_size = 62 + 8;
    const pad_len = (8 - (entry_size % 8)) % 8;
    for (0..pad_len) |_| {
        try index_with_ext.append(0);
    }
    
    // Add TREE extension (tree cache)
    try index_with_ext.appendSlice("TREE");
    try index_with_ext.writer().writeInt(u32, 20, .big); // Extension size
    
    // Dummy tree cache data
    try index_with_ext.appendSlice("dummy_tree_cache_dat");
    
    // Add REUC extension (resolve undo)
    try index_with_ext.appendSlice("REUC");
    try index_with_ext.writer().writeInt(u32, 16, .big); // Extension size
    
    // Dummy resolve undo data
    try index_with_ext.appendSlice("dummy_reuc_data!");
    
    // Calculate checksum for everything including extensions
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(index_with_ext.items);
    var checksum: [20]u8 = undefined;
    hasher.final(&checksum);
    try index_with_ext.appendSlice(&checksum);
    
    // Test that extensions are properly skipped
    var idx_with_ext = index_mod.Index.init(allocator);
    defer idx_with_ext.deinit();
    
    try idx_with_ext.parseIndexData(index_with_ext.items);
    try testing.expectEqual(@as(usize, 1), idx_with_ext.entries.items.len);
    try testing.expectEqualStrings("test.txt", idx_with_ext.entries.items[0].path);
}

test "index handling of very long paths" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    // Create a path that's near the limit (but valid)
    const long_path = "very/long/path/structure/with/many/nested/directories/and/a/very/long/filename_that_tests_path_length_limits.txt";
    
    var long_path_index = std.ArrayList(u8).init(allocator);
    defer long_path_index.deinit();
    
    // Header
    try long_path_index.appendSlice("DIRC");
    try long_path_index.writer().writeInt(u32, 2, .big); // Version 2
    try long_path_index.writer().writeInt(u32, 1, .big); // 1 entry
    
    // Entry data
    try long_path_index.writer().writeInt(u32, 1234567890, .big); // ctime_sec
    try long_path_index.writer().writeInt(u32, 0, .big);          // ctime_nsec
    try long_path_index.writer().writeInt(u32, 1234567890, .big); // mtime_sec
    try long_path_index.writer().writeInt(u32, 0, .big);          // mtime_nsec
    try long_path_index.writer().writeInt(u32, 1, .big);          // dev
    try long_path_index.writer().writeInt(u32, 12345, .big);      // ino
    try long_path_index.writer().writeInt(u32, 0o100644, .big);   // mode
    try long_path_index.writer().writeInt(u32, 1000, .big);       // uid
    try long_path_index.writer().writeInt(u32, 1000, .big);       // gid
    try long_path_index.writer().writeInt(u32, 100, .big);        // size
    
    const test_hash = [_]u8{0x99, 0x88, 0x77} ++ [_]u8{0} ** 17;
    try long_path_index.appendSlice(&test_hash);
    
    // Path length in flags - limited to 0xFFF in versions < 4
    const path_len = @min(long_path.len, 0xFFF);
    try long_path_index.writer().writeInt(u16, @intCast(path_len), .big);
    
    // Path
    try long_path_index.appendSlice(long_path[0..path_len]);
    
    // Padding
    const entry_size = 62 + path_len;
    const pad_len = (8 - (entry_size % 8)) % 8;
    for (0..pad_len) |_| {
        try long_path_index.append(0);
    }
    
    // Checksum
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(long_path_index.items);
    var checksum: [20]u8 = undefined;
    hasher.final(&checksum);
    try long_path_index.appendSlice(&checksum);
    
    // Test parsing
    var idx_long_path = index_mod.Index.init(allocator);
    defer idx_long_path.deinit();
    
    try idx_long_path.parseIndexData(long_path_index.items);
    try testing.expectEqual(@as(usize, 1), idx_long_path.entries.items.len);
    try testing.expectEqualStrings(long_path[0..path_len], idx_long_path.entries.items[0].path);
}

test "index file size limits and malformed data" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    // Test 1: Empty data
    var empty_idx = index_mod.Index.init(allocator);
    defer empty_idx.deinit();
    
    try testing.expectError(error.InvalidIndex, empty_idx.parseIndexData(&[_]u8{}));
    
    // Test 2: Too small data
    var small_idx = index_mod.Index.init(allocator);
    defer small_idx.deinit();
    
    const small_data = [_]u8{ 'D', 'I', 'R', 'C', 0, 0, 0, 2 }; // Only 8 bytes
    try testing.expectError(error.InvalidIndex, small_idx.parseIndexData(&small_data));
    
    // Test 3: Claimed entry count that would exceed reasonable limits
    var malformed_count_idx = index_mod.Index.init(allocator);
    defer malformed_count_idx.deinit();
    
    var malformed_data = std.ArrayList(u8).init(allocator);
    defer malformed_data.deinit();
    
    try malformed_data.appendSlice("DIRC");
    try malformed_data.writer().writeInt(u32, 2, .big);        // Version 2
    try malformed_data.writer().writeInt(u32, 0xFFFFFFFF, .big); // Impossibly large entry count
    
    // Add a few dummy bytes and checksum
    for (0..50) |_| {
        try malformed_data.append(0);
    }
    
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(malformed_data.items);
    var checksum: [20]u8 = undefined;
    hasher.final(&checksum);
    try malformed_data.appendSlice(&checksum);
    
    try testing.expectError(error.TooManyIndexEntries, malformed_count_idx.parseIndexData(malformed_data.items));
    
    // Test 4: Version too old or too new
    var old_version_idx = index_mod.Index.init(allocator);
    defer old_version_idx.deinit();
    
    var old_version_data = std.ArrayList(u8).init(allocator);
    defer old_version_data.deinit();
    
    try old_version_data.appendSlice("DIRC");
    try old_version_data.writer().writeInt(u32, 1, .big); // Version 1 (too old)
    try old_version_data.writer().writeInt(u32, 0, .big);
    
    // Add checksum
    var hasher2 = std.crypto.hash.Sha1.init(.{});
    hasher2.update(old_version_data.items);
    var checksum2: [20]u8 = undefined;
    hasher2.final(&checksum2);
    try old_version_data.appendSlice(&checksum2);
    
    try testing.expectError(error.IndexVersionTooOld, old_version_idx.parseIndexData(old_version_data.items));
}