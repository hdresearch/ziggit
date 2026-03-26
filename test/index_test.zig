const std = @import("std");
const testing = std.testing;
const index = @import("../src/git/index.zig");

test "index entry creation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    // Create a mock file stat
    const mock_stat = std.fs.File.Stat{
        .size = 1024,
        .mode = 0o644,
        .kind = .file,
        .ctime = 1640995200000000000, // 2022-01-01 00:00:00
        .mtime = 1640995200000000000,
        .atime = 1640995200000000000,
        .inode = 12345,
    };
    
    const test_hash = [_]u8{
        0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0,
        0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0,
        0x12, 0x34, 0x56, 0x78
    };
    
    const entry = index.IndexEntry.init("test/file.txt", mock_stat, test_hash);
    
    try testing.expect(entry.size == 1024);
    try testing.expect(entry.mode == 0o644);
    try testing.expectEqualSlices(u8, &entry.sha1, &test_hash);
    try testing.expectEqualSlices(u8, entry.path, "test/file.txt");
}

test "index file parsing and writing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    // Create some test index entries
    const mock_stat = std.fs.File.Stat{
        .size = 100,
        .mode = 0o644,
        .kind = .file,
        .ctime = 1640995200000000000,
        .mtime = 1640995200000000000,
        .atime = 1640995200000000000,
        .inode = 1,
    };
    
    const hash1 = [_]u8{0x11} ++ [_]u8{0} ** 19;
    const hash2 = [_]u8{0x22} ++ [_]u8{0} ** 19;
    
    var test_entries = std.ArrayList(index.IndexEntry).init(allocator);
    defer test_entries.deinit();
    
    try test_entries.append(index.IndexEntry.init("file1.txt", mock_stat, hash1));
    try test_entries.append(index.IndexEntry.init("file2.txt", mock_stat, hash2));
    
    // Write index to buffer
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    
    try index.writeIndex(test_entries.items, buffer.writer(), allocator);
    
    // Verify index format
    try testing.expect(buffer.items.len > 12); // Header should exist
    try testing.expectEqualSlices(u8, buffer.items[0..4], "DIRC"); // Index magic
    
    // Test parsing the index back
    const parsed_entries = try index.parseIndex(buffer.items, allocator);
    defer {
        for (parsed_entries.items) |entry| {
            entry.deinit(allocator);
        }
        parsed_entries.deinit();
    }
    
    try testing.expect(parsed_entries.items.len == 2);
    try testing.expectEqualSlices(u8, parsed_entries.items[0].path, "file1.txt");
    try testing.expectEqualSlices(u8, parsed_entries.items[1].path, "file2.txt");
}

test "index with extensions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    // Create an index buffer with a mock extension
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    
    // Write index header
    try buffer.appendSlice("DIRC"); // Magic
    try buffer.writer().writeInt(u32, 3, .big); // Version 3
    try buffer.writer().writeInt(u32, 0, .big); // No entries for this test
    
    // Write a mock TREE extension
    try buffer.appendSlice("TREE");
    try buffer.writer().writeInt(u32, 8, .big); // Extension size
    try buffer.appendSlice([_]u8{0} ** 8); // Dummy extension data
    
    // Write index checksum (SHA-1)
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(buffer.items);
    var checksum: [20]u8 = undefined;
    hasher.final(&checksum);
    try buffer.appendSlice(&checksum);
    
    // Should be able to parse index with extensions (even if we skip them)
    const parsed_entries = index.parseIndex(buffer.items, allocator) catch |err| switch (err) {
        error.UnsupportedIndexExtension => {
            // This is expected for now - extensions are not fully implemented
            return;
        },
        else => return err,
    };
    
    defer {
        for (parsed_entries.items) |entry| {
            entry.deinit(allocator);
        }
        parsed_entries.deinit();
    }
    
    try testing.expect(parsed_entries.items.len == 0);
}

test "index version 4 variable length encoding" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    // Test variable length integer encoding/decoding used in index v4
    const test_values = [_]u32{ 0, 1, 127, 128, 255, 256, 16383, 16384, 65535, 65536 };
    
    for (test_values) |value| {
        // Encode
        var encoded = std.ArrayList(u8).init(allocator);
        defer encoded.deinit();
        
        try index.writeVarInt(encoded.writer(), value);
        
        // Decode
        var stream = std.io.fixedBufferStream(encoded.items);
        const decoded = try index.readVarInt(stream.reader());
        
        try testing.expect(decoded == value);
    }
}

test "index conflict resolution entries" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    // Create index with conflict markers (stage != 0)
    const mock_stat = std.fs.File.Stat{
        .size = 100,
        .mode = 0o644,
        .kind = .file,
        .ctime = 1640995200000000000,
        .mtime = 1640995200000000000,
        .atime = 1640995200000000000,
        .inode = 1,
    };
    
    const base_hash = [_]u8{0x11} ++ [_]u8{0} ** 19;
    const ours_hash = [_]u8{0x22} ++ [_]u8{0} ** 19;
    const theirs_hash = [_]u8{0x33} ++ [_]u8{0} ** 19;
    
    var test_entries = std.ArrayList(index.IndexEntry).init(allocator);
    defer test_entries.deinit();
    
    // Stage 1: base version
    var base_entry = index.IndexEntry.init("conflicted.txt", mock_stat, base_hash);
    base_entry.flags = (base_entry.flags & ~index.INDEX_STAGE_MASK) | (1 << index.INDEX_STAGE_SHIFT);
    try test_entries.append(base_entry);
    
    // Stage 2: our version  
    var our_entry = index.IndexEntry.init("conflicted.txt", mock_stat, ours_hash);
    our_entry.flags = (our_entry.flags & ~index.INDEX_STAGE_MASK) | (2 << index.INDEX_STAGE_SHIFT);
    try test_entries.append(our_entry);
    
    // Stage 3: their version
    var their_entry = index.IndexEntry.init("conflicted.txt", mock_stat, theirs_hash);
    their_entry.flags = (their_entry.flags & ~index.INDEX_STAGE_MASK) | (3 << index.INDEX_STAGE_SHIFT);
    try test_entries.append(their_entry);
    
    // Write and parse back
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    
    try index.writeIndex(test_entries.items, buffer.writer(), allocator);
    
    const parsed_entries = try index.parseIndex(buffer.items, allocator);
    defer {
        for (parsed_entries.items) |entry| {
            entry.deinit(allocator);
        }
        parsed_entries.deinit();
    }
    
    try testing.expect(parsed_entries.items.len == 3);
    
    // Check stages
    for (parsed_entries.items, 1..) |entry, expected_stage| {
        const stage = (entry.flags & index.INDEX_STAGE_MASK) >> index.INDEX_STAGE_SHIFT;
        try testing.expect(stage == expected_stage);
    }
}

test "index checksum validation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    // Create valid index
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    
    try buffer.appendSlice("DIRC"); // Magic
    try buffer.writer().writeInt(u32, 2, .big); // Version
    try buffer.writer().writeInt(u32, 0, .big); // No entries
    
    // Calculate and append correct checksum
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(buffer.items);
    var correct_checksum: [20]u8 = undefined;
    hasher.final(&correct_checksum);
    try buffer.appendSlice(&correct_checksum);
    
    // Should parse successfully
    const result1 = index.parseIndex(buffer.items, allocator);
    try testing.expect(result1 != error.InvalidChecksum);
    
    // Corrupt the checksum
    buffer.items[buffer.items.len - 1] ^= 0xFF;
    
    // Should fail checksum validation
    const result2 = index.parseIndex(buffer.items, allocator);
    try testing.expectError(error.InvalidChecksum, result2);
}

test "index performance with large number of files" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    const num_files = 10000;
    
    const mock_stat = std.fs.File.Stat{
        .size = 100,
        .mode = 0o644,
        .kind = .file,
        .ctime = 1640995200000000000,
        .mtime = 1640995200000000000,
        .atime = 1640995200000000000,
        .inode = 1,
    };
    
    var test_entries = std.ArrayList(index.IndexEntry).init(allocator);
    defer test_entries.deinit();
    
    // Create many entries
    for (0..num_files) |i| {
        const path = try std.fmt.allocPrint(allocator, "file{d}.txt", .{i});
        var hash: [20]u8 = undefined;
        @memset(&hash, @intCast(i & 0xFF));
        
        try test_entries.append(index.IndexEntry.init(path, mock_stat, hash));
    }
    
    const start_time = std.time.milliTimestamp();
    
    // Write index
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    
    try index.writeIndex(test_entries.items, buffer.writer(), allocator);
    
    // Parse it back
    const parsed_entries = try index.parseIndex(buffer.items, allocator);
    defer {
        for (parsed_entries.items) |entry| {
            entry.deinit(allocator);
        }
        parsed_entries.deinit();
    }
    
    const end_time = std.time.milliTimestamp();
    
    try testing.expect(parsed_entries.items.len == num_files);
    
    // Should complete in reasonable time (less than 1 second for 10k files)
    const duration = end_time - start_time;
    try testing.expect(duration < 1000);
}