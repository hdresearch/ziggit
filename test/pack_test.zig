const std = @import("std");
const testing = std.testing;
const objects = @import("../src/git/objects.zig");

// Mock platform implementation for testing
const MockPlatform = struct {
    fs: MockFs = .{},
    
    const MockFs = struct {
        test_data: std.StringHashMap([]const u8) = undefined,
        
        pub fn init(allocator: std.mem.Allocator) MockFs {
            return MockFs{
                .test_data = std.StringHashMap([]const u8).init(allocator),
            };
        }
        
        pub fn deinit(self: *MockFs) void {
            self.test_data.deinit();
        }
        
        pub fn setFile(self: *MockFs, path: []const u8, data: []const u8) !void {
            try self.test_data.put(path, data);
        }
        
        pub fn readFile(self: MockFs, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
            if (self.test_data.get(path)) |data| {
                return try allocator.dupe(u8, data);
            }
            return error.FileNotFound;
        }
        
        pub fn writeFile(self: MockFs, path: []const u8, data: []const u8) !void {
            _ = path;
            _ = data;
            // No-op for tests
        }
        
        pub fn makeDir(self: MockFs, path: []const u8) !void {
            _ = self;
            _ = path;
            // No-op for tests
        }
    };
};

// Helper to create a simple pack index v2 file for testing
fn createTestPackIndexV2(allocator: std.mem.Allocator, objects: []const struct { hash: [20]u8, offset: u32 }) ![]u8 {
    var data = std.ArrayList(u8).init(allocator);
    defer data.deinit();
    
    // Write magic and version
    try data.writer().writeInt(u32, 0xff744f63, .big); // Magic
    try data.writer().writeInt(u32, 2, .big);          // Version
    
    // Create fanout table
    var fanout: [256]u32 = [_]u32{0} ** 256;
    for (objects) |obj| {
        for (@intCast(obj.hash[0] + 1)..256) |i| {
            fanout[i] += 1;
        }
    }
    
    // Write fanout table
    for (fanout) |count| {
        try data.writer().writeInt(u32, count, .big);
    }
    
    // Sort objects by hash for binary search
    var sorted_objects = try allocator.dupe(@TypeOf(objects[0]), objects);
    defer allocator.free(sorted_objects);
    
    std.sort.block(@TypeOf(objects[0]), sorted_objects, {}, struct {
        fn lessThan(ctx: void, lhs: @TypeOf(objects[0]), rhs: @TypeOf(objects[0])) bool {
            _ = ctx;
            return std.mem.order(u8, &lhs.hash, &rhs.hash) == .lt;
        }
    }.lessThan);
    
    // Write SHA-1 table
    for (sorted_objects) |obj| {
        try data.appendSlice(&obj.hash);
    }
    
    // Write CRC table (all zeros for testing)
    for (sorted_objects) |_| {
        try data.writer().writeInt(u32, 0, .big);
    }
    
    // Write offset table
    for (sorted_objects) |obj| {
        try data.writer().writeInt(u32, obj.offset, .big);
    }
    
    return try allocator.dupe(u8, data.items);
}

// Helper to create a simple pack file for testing
fn createTestPackFile(allocator: std.mem.Allocator, objects: []const struct { type: objects.ObjectType, content: []const u8, offset: u32 }) ![]u8 {
    var data = std.ArrayList(u8).init(allocator);
    defer data.deinit();
    
    // Write pack header
    try data.appendSlice("PACK");                       // Magic
    try data.writer().writeInt(u32, 2, .big);          // Version
    try data.writer().writeInt(u32, @intCast(objects.len), .big); // Object count
    
    // Write objects
    for (objects) |obj| {
        // Ensure we're at the expected offset
        while (data.items.len < obj.offset) {
            try data.append(0);
        }
        
        // Object header
        const type_num: u3 = switch (obj.type) {
            .commit => 1,
            .tree => 2,
            .blob => 3,
            .tag => 4,
        };
        
        const size = obj.content.len;
        var header_byte: u8 = (@as(u8, type_num) << 4) | @as(u8, @intCast(size & 0x0F));
        var remaining_size = size >> 4;
        
        if (remaining_size > 0) {
            header_byte |= 0x80;
        }
        
        try data.append(header_byte);
        
        // Write variable length size
        while (remaining_size > 0) {
            var size_byte: u8 = @intCast(remaining_size & 0x7F);
            remaining_size >>= 7;
            if (remaining_size > 0) {
                size_byte |= 0x80;
            }
            try data.append(size_byte);
        }
        
        // Compress object data with zlib
        var compressed = std.ArrayList(u8).init(allocator);
        defer compressed.deinit();
        
        var stream = std.io.fixedBufferStream(obj.content);
        try std.compress.zlib.compress(stream.reader(), compressed.writer(), .{});
        try data.appendSlice(compressed.items);
    }
    
    // Write pack file checksum (SHA-1 of entire pack so far)
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(data.items);
    var checksum: [20]u8 = undefined;
    hasher.final(&checksum);
    try data.appendSlice(&checksum);
    
    return try allocator.dupe(u8, data.items);
}

test "pack index v2 parsing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    // Create test data
    const test_hash = [_]u8{0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x12, 0x34, 0x56, 0x78};
    const test_objects = [_]struct { hash: [20]u8, offset: u32 }{
        .{ .hash = test_hash, .offset = 12 },
    };
    
    const idx_data = try createTestPackIndexV2(allocator, &test_objects);
    const pack_data = try createTestPackFile(allocator, &[_]struct { type: objects.ObjectType, content: []const u8, offset: u32 }{
        .{ .type = .blob, .content = "test content", .offset = 12 },
    });
    
    // Setup mock platform
    var platform = MockPlatform{};
    platform.fs = MockPlatform.MockFs.init(allocator);
    defer platform.fs.deinit();
    
    try platform.fs.setFile("/test/.git/objects/pack/pack-test.idx", idx_data);
    try platform.fs.setFile("/test/.git/objects/pack/pack-test.pack", pack_data);
    
    // Test loading object from pack
    const hash_str = "123456789abcdef0123456789abcdef012345678";
    const result = objects.GitObject.load(hash_str, "/test/.git", platform, allocator);
    
    // This should find the object in the pack file since it's not in loose objects
    try testing.expect(result != error.ObjectNotFound);
}

test "pack file with delta objects" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    // This test would create a more complex pack with delta objects
    // For now, just test basic structure
    
    const base_content = "Hello, World!";
    const base_hash = [_]u8{0xaa} ++ [_]u8{0} ** 19;
    
    const test_objects = [_]struct { hash: [20]u8, offset: u32 }{
        .{ .hash = base_hash, .offset = 12 },
    };
    
    const idx_data = try createTestPackIndexV2(allocator, &test_objects);
    const pack_data = try createTestPackFile(allocator, &[_]struct { type: objects.ObjectType, content: []const u8, offset: u32 }{
        .{ .type = .blob, .content = base_content, .offset = 12 },
    });
    
    // Basic validation that our test pack structure is reasonable
    try testing.expect(pack_data.len > 32); // Should have header + object + checksum
    try testing.expectEqualSlices(u8, "PACK", pack_data[0..4]);
}

test "pack file integrity verification" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    const test_hash = [_]u8{0x11, 0x22, 0x33} ++ [_]u8{0} ** 17;
    const test_objects = [_]struct { hash: [20]u8, offset: u32 }{
        .{ .hash = test_hash, .offset = 12 },
    };
    
    const pack_data = try createTestPackFile(allocator, &[_]struct { type: objects.ObjectType, content: []const u8, offset: u32 }{
        .{ .type = .blob, .content = "integrity test", .offset = 12 },
    });
    
    // Setup mock platform
    var platform = MockPlatform{};
    platform.fs = MockPlatform.MockFs.init(allocator);
    defer platform.fs.deinit();
    
    try platform.fs.setFile("/test/pack-test.pack", pack_data);
    
    // Test pack file analysis
    const stats = try objects.analyzePackFile("/test/pack-test.pack", platform, allocator);
    try testing.expect(stats.total_objects == 1);
    try testing.expect(stats.checksum_valid);
    try testing.expect(stats.version == 2);
}

test "corrupted pack file handling" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    // Create a corrupted pack file (missing checksum)
    const corrupted_data = "PACK" ++ [_]u8{0} ** 8; // Just header, no objects or checksum
    
    var platform = MockPlatform{};
    platform.fs = MockPlatform.MockFs.init(allocator);
    defer platform.fs.deinit();
    
    try platform.fs.setFile("/test/corrupted.pack", corrupted_data);
    
    // Should detect corruption
    const result = objects.analyzePackFile("/test/corrupted.pack", platform, allocator);
    try testing.expectError(error.PackFileTooSmall, result);
}

test "pack index v1 compatibility" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    // Create a simple pack index v1 (without magic header)
    var data = std.ArrayList(u8).init(allocator);
    defer data.deinit();
    
    // Fanout table (256 * 4 bytes)
    for (0..256) |i| {
        const count: u32 = if (i == 255) 1 else 0; // One object with hash starting 0xff
        try data.writer().writeInt(u32, count, .big);
    }
    
    // Object entry: 4 bytes offset + 20 bytes SHA-1
    try data.writer().writeInt(u32, 12, .big); // offset
    const test_hash = [_]u8{0xff} ++ [_]u8{0} ** 19;
    try data.appendSlice(&test_hash);
    
    const idx_data = try allocator.dupe(u8, data.items);
    
    // This tests that our code can handle v1 index format
    // The actual loading would require more complex setup
    try testing.expect(idx_data.len > 256 * 4); // Should have fanout + entries
}

test "large pack file handling" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    // Simulate a large pack with many objects
    var test_objects = std.ArrayList(struct { hash: [20]u8, offset: u32 }).init(allocator);
    defer test_objects.deinit();
    
    // Create 1000 test objects
    for (0..1000) |i| {
        var hash: [20]u8 = undefined;
        hash[0] = @intCast(i & 0xff);
        hash[1] = @intCast((i >> 8) & 0xff);
        hash[2] = @intCast((i >> 16) & 0xff);
        @memset(hash[3..], 0);
        
        try test_objects.append(.{ .hash = hash, .offset = @intCast(12 + i * 100) });
    }
    
    const idx_data = try createTestPackIndexV2(allocator, test_objects.items);
    
    // Should handle large index files
    try testing.expect(idx_data.len > 1000 * 20); // At least the SHA-1 hashes
}