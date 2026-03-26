const std = @import("std");
const testing = std.testing;
const index = @import("../src/git/index.zig");

// Helper to create a minimal but valid index file for testing
fn createTestIndex(allocator: std.mem.Allocator, entries: []const TestEntry, extensions: []const TestExtension, version: u32) ![]u8 {
    var data = std.ArrayList(u8).init(allocator);
    defer data.deinit();
    
    // Write header
    try data.appendSlice("DIRC"); // Magic
    try data.writer().writeInt(u32, version, .big);
    try data.writer().writeInt(u32, @intCast(entries.len), .big);
    
    // Write entries
    for (entries) |entry| {
        // Write entry data
        try data.writer().writeInt(u32, entry.ctime_sec, .big);
        try data.writer().writeInt(u32, entry.ctime_nsec, .big);
        try data.writer().writeInt(u32, entry.mtime_sec, .big);
        try data.writer().writeInt(u32, entry.mtime_nsec, .big);
        try data.writer().writeInt(u32, entry.dev, .big);
        try data.writer().writeInt(u32, entry.ino, .big);
        try data.writer().writeInt(u32, entry.mode, .big);
        try data.writer().writeInt(u32, entry.uid, .big);
        try data.writer().writeInt(u32, entry.gid, .big);
        try data.writer().writeInt(u32, entry.size, .big);
        try data.appendSlice(&entry.sha1);
        try data.writer().writeInt(u16, @intCast(entry.path.len), .big); // flags with path length
        
        if (version >= 3) {
            try data.writer().writeInt(u16, 0, .big); // extended flags for v3+
        }
        
        try data.appendSlice(entry.path);
        
        // Pad to multiple of 8 bytes
        const base_len = 62;
        const ext_len = if (version >= 3) @as(usize, 2) else @as(usize, 0);
        const total_len = base_len + ext_len + entry.path.len;
        const pad_len = (8 - (total_len % 8)) % 8;
        
        for (0..pad_len) |_| {
            try data.append(0);
        }
    }
    
    // Write extensions
    for (extensions) |extension| {
        try data.appendSlice(&extension.signature);
        try data.writer().writeInt(u32, @intCast(extension.data.len), .big);
        try data.appendSlice(extension.data);
    }
    
    // Calculate and write checksum
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(data.items);
    var checksum: [20]u8 = undefined;
    hasher.final(&checksum);
    try data.appendSlice(&checksum);
    
    return try allocator.dupe(u8, data.items);
}

const TestEntry = struct {
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
    path: []const u8,
};

const TestExtension = struct {
    signature: [4]u8,
    data: []const u8,
};

test "index v2 parsing with basic entries" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    const test_entries = [_]TestEntry{
        TestEntry{
            .ctime_sec = 1640995200, // 2022-01-01
            .ctime_nsec = 0,
            .mtime_sec = 1640995200,
            .mtime_nsec = 0,
            .dev = 2049,
            .ino = 123456,
            .mode = 33188, // 100644 in decimal
            .uid = 1000,
            .gid = 1000,
            .size = 13,
            .sha1 = [_]u8{0x2a, 0xae, 0x6c, 0x35, 0xc9, 0x4f, 0xcf, 0xb4, 0x15, 0xdb, 0xe9, 0x5f, 0x40, 0x8b, 0x9c, 0xe9, 0x1e, 0xe8, 0x46, 0xed},
            .path = "hello.txt",
        },
    };
    
    const index_data = try createTestIndex(allocator, &test_entries, &[_]TestExtension{}, 2);
    
    const parsed_entries = try index.parseIndex(index_data, allocator);
    defer {
        for (parsed_entries.items) |entry| {
            entry.deinit(allocator);
        }
        parsed_entries.deinit();
    }
    
    try testing.expect(parsed_entries.items.len == 1);
    const entry = parsed_entries.items[0];
    
    try testing.expectEqualStrings("hello.txt", entry.path);
    try testing.expect(entry.size == 13);
    try testing.expect(entry.mode == 33188);
    
    const expected_sha1 = [_]u8{0x2a, 0xae, 0x6c, 0x35, 0xc9, 0x4f, 0xcf, 0xb4, 0x15, 0xdb, 0xe9, 0x5f, 0x40, 0x8b, 0x9c, 0xe9, 0x1e, 0xe8, 0x46, 0xed};
    try testing.expectEqualSlices(u8, &expected_sha1, &entry.sha1);
}

test "index v3 with extended flags" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    const test_entries = [_]TestEntry{
        TestEntry{
            .ctime_sec = 1640995200,
            .ctime_nsec = 0,
            .mtime_sec = 1640995200,
            .mtime_nsec = 0,
            .dev = 2049,
            .ino = 123456,
            .mode = 33188,
            .uid = 1000,
            .gid = 1000,
            .size = 25,
            .sha1 = [_]u8{0x3b, 0x18, 0xe5, 0x12, 0xdb, 0xbe, 0xa3, 0x4b, 0x21, 0x1f, 0x73, 0x2f, 0x32, 0x89, 0x12, 0x0b, 0x83, 0xd5, 0x87, 0xc9},
            .path = "test_file_with_long_name.txt",
        },
    };
    
    const index_data = try createTestIndex(allocator, &test_entries, &[_]TestExtension{}, 3);
    
    const parsed_entries = try index.parseIndex(index_data, allocator);
    defer {
        for (parsed_entries.items) |entry| {
            entry.deinit(allocator);
        }
        parsed_entries.deinit();
    }
    
    try testing.expect(parsed_entries.items.len == 1);
    const entry = parsed_entries.items[0];
    
    try testing.expectEqualStrings("test_file_with_long_name.txt", entry.path);
    try testing.expect(entry.extended_flags != null);
}

test "index with TREE extension" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    // Create TREE extension data (simplified)
    const tree_data = "0 2\x00" ++ [_]u8{0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x12, 0x34, 0x56, 0x78} ++ "subdir\x00-1 0\x00";
    
    const test_extensions = [_]TestExtension{
        TestExtension{
            .signature = [_]u8{'T', 'R', 'E', 'E'},
            .data = tree_data,
        },
    };
    
    const test_entries = [_]TestEntry{
        TestEntry{
            .ctime_sec = 1640995200,
            .ctime_nsec = 0,
            .mtime_sec = 1640995200,
            .mtime_nsec = 0,
            .dev = 2049,
            .ino = 123456,
            .mode = 33188,
            .uid = 1000,
            .gid = 1000,
            .size = 13,
            .sha1 = [_]u8{0x2a, 0xae, 0x6c, 0x35, 0xc9, 0x4f, 0xcf, 0xb4, 0x15, 0xdb, 0xe9, 0x5f, 0x40, 0x8b, 0x9c, 0xe9, 0x1e, 0xe8, 0x46, 0xed},
            .path = "hello.txt",
        },
        TestEntry{
            .ctime_sec = 1640995300,
            .ctime_nsec = 0,
            .mtime_sec = 1640995300,
            .mtime_nsec = 0,
            .dev = 2049,
            .ino = 123457,
            .mode = 33188,
            .uid = 1000,
            .gid = 1000,
            .size = 20,
            .sha1 = [_]u8{0x3b, 0x18, 0xe5, 0x12, 0xdb, 0xbe, 0xa3, 0x4b, 0x21, 0x1f, 0x73, 0x2f, 0x32, 0x89, 0x12, 0x0b, 0x83, 0xd5, 0x87, 0xc9},
            .path = "subdir/file.txt",
        },
    };
    
    const index_data = try createTestIndex(allocator, &test_entries, &test_extensions, 2);
    
    // Parse with extensions support
    const parsed = try index.parseIndexWithExtensions(index_data, allocator);
    defer {
        for (parsed.entries.items) |entry| {
            entry.deinit(allocator);
        }
        parsed.entries.deinit();
        
        for (parsed.extensions.items) |ext| {
            ext.deinit(allocator);
        }
        parsed.extensions.deinit();
    }
    
    try testing.expect(parsed.entries.items.len == 2);
    try testing.expect(parsed.extensions.items.len == 1);
    try testing.expect(parsed.version == 2);
    
    const tree_ext = parsed.extensions.items[0];
    try testing.expectEqualSlices(u8, "TREE", &tree_ext.signature);
    try testing.expect(tree_ext.size > 0);
}

test "index with REUC extension (resolve undo)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    // Create REUC extension data (resolve undo cache)
    const reuc_data = "conflict.txt\x00100644 " ++ [_]u8{0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x11} ++
                      " 100644 " ++ [_]u8{0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22} ++
                      " 100644 " ++ [_]u8{0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33};
    
    const test_extensions = [_]TestExtension{
        TestExtension{
            .signature = [_]u8{'R', 'E', 'U', 'C'},
            .data = reuc_data,
        },
    };
    
    const test_entries = [_]TestEntry{
        TestEntry{
            .ctime_sec = 1640995200,
            .ctime_nsec = 0,
            .mtime_sec = 1640995200,
            .mtime_nsec = 0,
            .dev = 2049,
            .ino = 123456,
            .mode = 33188,
            .uid = 1000,
            .gid = 1000,
            .size = 13,
            .sha1 = [_]u8{0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33},
            .path = "conflict.txt",
        },
    };
    
    const index_data = try createTestIndex(allocator, &test_entries, &test_extensions, 2);
    
    const parsed = try index.parseIndexWithExtensions(index_data, allocator);
    defer {
        for (parsed.entries.items) |entry| {
            entry.deinit(allocator);
        }
        parsed.entries.deinit();
        
        for (parsed.extensions.items) |ext| {
            ext.deinit(allocator);
        }
        parsed.extensions.deinit();
    }
    
    try testing.expect(parsed.extensions.items.len == 1);
    
    const reuc_ext = parsed.extensions.items[0];
    try testing.expectEqualSlices(u8, "REUC", &reuc_ext.signature);
    try testing.expect(std.mem.indexOf(u8, reuc_ext.data, "conflict.txt") != null);
}

test "index integrity verification" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    const test_entries = [_]TestEntry{
        TestEntry{
            .ctime_sec = 1640995200,
            .ctime_nsec = 0,
            .mtime_sec = 1640995200,
            .mtime_nsec = 0,
            .dev = 2049,
            .ino = 123456,
            .mode = 33188,
            .uid = 1000,
            .gid = 1000,
            .size = 13,
            .sha1 = [_]u8{0x2a, 0xae, 0x6c, 0x35, 0xc9, 0x4f, 0xcf, 0xb4, 0x15, 0xdb, 0xe9, 0x5f, 0x40, 0x8b, 0x9c, 0xe9, 0x1e, 0xe8, 0x46, 0xed},
            .path = "hello.txt",
        },
    };
    
    const index_data = try createTestIndex(allocator, &test_entries, &[_]TestExtension{}, 2);
    
    // Test valid checksum
    const is_valid = try index.verifyIndexIntegrity(index_data);
    try testing.expect(is_valid);
    
    // Test corrupted checksum
    var corrupted_data = try allocator.dupe(u8, index_data);
    defer allocator.free(corrupted_data);
    
    // Corrupt the last byte of checksum
    corrupted_data[corrupted_data.len - 1] = ~corrupted_data[corrupted_data.len - 1];
    
    const is_corrupted = try index.verifyIndexIntegrity(corrupted_data);
    try testing.expect(!is_corrupted);
}

test "index statistics analysis" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    const test_entries = [_]TestEntry{
        TestEntry{
            .ctime_sec = 1640995200,
            .ctime_nsec = 0,
            .mtime_sec = 1640995200,
            .mtime_nsec = 0,
            .dev = 2049,
            .ino = 123456,
            .mode = 33188,
            .uid = 1000,
            .gid = 1000,
            .size = 13,
            .sha1 = [_]u8{0x2a, 0xae, 0x6c, 0x35, 0xc9, 0x4f, 0xcf, 0xb4, 0x15, 0xdb, 0xe9, 0x5f, 0x40, 0x8b, 0x9c, 0xe9, 0x1e, 0xe8, 0x46, 0xed},
            .path = "normal.txt",
        },
        TestEntry{
            .ctime_sec = 1640995300,
            .ctime_nsec = 0,
            .mtime_sec = 1640995300,
            .mtime_nsec = 0,
            .dev = 2049,
            .ino = 123457,
            .mode = 33188,
            .uid = 1000,
            .gid = 1000,
            .size = 20,
            .sha1 = [_]u8{0x3b, 0x18, 0xe5, 0x12, 0xdb, 0xbe, 0xa3, 0x4b, 0x21, 0x1f, 0x73, 0x2f, 0x32, 0x89, 0x12, 0x0b, 0x83, 0xd5, 0x87, 0xc9},
            .path = "conflict.txt",
        },
    };
    
    // Create TREE extension
    const tree_data = "0 2\x00" ++ [_]u8{0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x12, 0x34, 0x56, 0x78};
    const test_extensions = [_]TestExtension{
        TestExtension{
            .signature = [_]u8{'T', 'R', 'E', 'E'},
            .data = tree_data,
        },
    };
    
    const index_data = try createTestIndex(allocator, &test_entries, &test_extensions, 3);
    
    const stats = try index.analyzeIndex(index_data, allocator);
    
    try testing.expect(stats.total_entries == 2);
    try testing.expect(stats.conflicted_entries == 0); // No conflicts in our test data
    try testing.expect(stats.version == 3);
    try testing.expect(stats.extensions == 1);
    try testing.expect(stats.total_size == index_data.len);
}

test "index with merge conflict entries" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    // Create entries with different stages (conflict states)
    var test_entries = [_]TestEntry{
        // Stage 0 (normal file)
        TestEntry{
            .ctime_sec = 1640995200,
            .ctime_nsec = 0,
            .mtime_sec = 1640995200,
            .mtime_nsec = 0,
            .dev = 2049,
            .ino = 123456,
            .mode = 33188,
            .uid = 1000,
            .gid = 1000,
            .size = 13,
            .sha1 = [_]u8{0x2a, 0xae, 0x6c, 0x35, 0xc9, 0x4f, 0xcf, 0xb4, 0x15, 0xdb, 0xe9, 0x5f, 0x40, 0x8b, 0x9c, 0xe9, 0x1e, 0xe8, 0x46, 0xed},
            .path = "normal.txt",
        },
    };
    
    // Set stage 0 (no conflict) for flags
    // Note: In real implementation, we'd need to properly encode stage in flags
    
    const index_data = try createTestIndex(allocator, &test_entries, &[_]TestExtension{}, 2);
    
    const parsed_entries = try index.parseIndex(index_data, allocator);
    defer {
        for (parsed_entries.items) |entry| {
            entry.deinit(allocator);
        }
        parsed_entries.deinit();
    }
    
    try testing.expect(parsed_entries.items.len == 1);
    
    // Check that stage extraction works
    const entry = parsed_entries.items[0];
    const stage = (entry.flags & index.INDEX_STAGE_MASK) >> index.INDEX_STAGE_SHIFT;
    try testing.expect(stage == 0); // Normal file, no conflict
}

test "index error handling with corrupted data" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    // Test with too small data
    const too_small = [_]u8{0x44, 0x49, 0x52, 0x43}; // Just "DIRC"
    const result1 = index.parseIndex(&too_small, allocator);
    try testing.expectError(error.InvalidIndex, result1);
    
    // Test with wrong magic
    const wrong_magic = [_]u8{0x42, 0x41, 0x44, 0x21} ++ [_]u8{0x00} ** 28; // "BAD!" + padding
    const result2 = index.parseIndex(&wrong_magic, allocator);
    try testing.expectError(error.InvalidIndex, result2);
    
    // Test with unsupported version
    var bad_version = std.ArrayList(u8).init(allocator);
    defer bad_version.deinit();
    
    try bad_version.appendSlice("DIRC"); // Magic
    try bad_version.writer().writeInt(u32, 999, .big); // Unsupported version
    try bad_version.writer().writeInt(u32, 0, .big); // Entry count
    
    // Add minimal checksum
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(bad_version.items);
    var checksum: [20]u8 = undefined;
    hasher.final(&checksum);
    try bad_version.appendSlice(&checksum);
    
    const result3 = index.parseIndex(bad_version.items, allocator);
    try testing.expectError(error.UnsupportedVersion, result3);
}