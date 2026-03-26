const std = @import("std");
const testing = std.testing;
const objects = @import("../src/git/objects.zig");

// Enhanced mock platform implementation for testing
const MockPlatform = struct {
    fs: MockFs,
    
    const MockFs = struct {
        test_data: std.StringHashMap([]const u8),
        allocator: std.mem.Allocator,
        
        pub fn init(allocator: std.mem.Allocator) MockFs {
            return MockFs{
                .test_data = std.StringHashMap([]const u8).init(allocator),
                .allocator = allocator,
            };
        }
        
        pub fn deinit(self: *MockFs) void {
            var iterator = self.test_data.iterator();
            while (iterator.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            self.test_data.deinit();
        }
        
        pub fn setFile(self: *MockFs, path: []const u8, data: []const u8) !void {
            const owned_path = try self.allocator.dupe(u8, path);
            const owned_data = try self.allocator.dupe(u8, data);
            try self.test_data.put(owned_path, owned_data);
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
    
    pub fn init(allocator: std.mem.Allocator) MockPlatform {
        return MockPlatform{
            .fs = MockFs.init(allocator),
        };
    }
    
    pub fn deinit(self: *MockPlatform) void {
        self.fs.deinit();
    }
};

// Helper to create a more realistic pack index v2 file
fn createRealisticPackIndexV2(allocator: std.mem.Allocator, objects_list: []const TestObject) ![]u8 {
    var data = std.ArrayList(u8).init(allocator);
    defer data.deinit();
    
    // Write magic and version
    try data.writer().writeInt(u32, 0xff744f63, .big); // Magic
    try data.writer().writeInt(u32, 2, .big);          // Version
    
    // Sort objects by hash for proper indexing
    var sorted_objects = try allocator.dupe(TestObject, objects_list);
    defer allocator.free(sorted_objects);
    
    std.sort.block(TestObject, sorted_objects, {}, struct {
        fn lessThan(ctx: void, lhs: TestObject, rhs: TestObject) bool {
            _ = ctx;
            return std.mem.order(u8, &lhs.hash, &rhs.hash) == .lt;
        }
    }.lessThan);
    
    // Create fanout table - counts how many objects have hash[0] <= i
    var fanout: [256]u32 = [_]u32{0} ** 256;
    for (sorted_objects) |obj| {
        for (@as(usize, obj.hash[0])..256) |i| {
            fanout[i] += 1;
        }
    }
    
    // Write fanout table
    for (fanout) |count| {
        try data.writer().writeInt(u32, count, .big);
    }
    
    // Write SHA-1 table
    for (sorted_objects) |obj| {
        try data.appendSlice(&obj.hash);
    }
    
    // Write CRC table (computed from pack data)
    for (sorted_objects) |obj| {
        // Simple CRC computation for testing
        var hasher = std.crypto.hash.crc.Crc32.init();
        hasher.update(&obj.hash);
        const crc = hasher.final();
        try data.writer().writeInt(u32, crc, .big);
    }
    
    // Write offset table
    for (sorted_objects) |obj| {
        if (obj.offset > 0x7FFFFFFF) {
            // Large offset - set MSB and use index into 64-bit table
            try data.writer().writeInt(u32, 0x80000000 | 0, .big);
        } else {
            try data.writer().writeInt(u32, obj.offset, .big);
        }
    }
    
    // Large offset table (empty for our tests)
    // ... would be added here for offsets > 2GB
    
    return try allocator.dupe(u8, data.items);
}

const TestObject = struct {
    hash: [20]u8,
    offset: u32,
    obj_type: objects.ObjectType,
    content: []const u8,
};

// Helper to create a realistic pack file with proper compression
fn createRealisticPackFile(allocator: std.mem.Allocator, objects_list: []const TestObject) ![]u8 {
    var data = std.ArrayList(u8).init(allocator);
    defer data.deinit();
    
    // Write pack header
    try data.appendSlice("PACK");                       // Magic
    try data.writer().writeInt(u32, 2, .big);          // Version 
    try data.writer().writeInt(u32, @intCast(objects_list.len), .big); // Object count
    
    // Write objects at their specified offsets
    for (objects_list) |obj| {
        // Ensure we're at the expected offset by padding if needed
        while (data.items.len < obj.offset) {
            try data.append(0);
        }
        
        // Object header with variable length encoding
        const type_num: u3 = switch (obj.obj_type) {
            .commit => 1,
            .tree => 2,
            .blob => 3,
            .tag => 4,
        };
        
        const size = obj.content.len;
        var header_bytes = std.ArrayList(u8).init(allocator);
        defer header_bytes.deinit();
        
        // First byte: type and low 4 bits of size
        var first_byte: u8 = (@as(u8, type_num) << 4) | @as(u8, @intCast(size & 0x0F));
        var remaining_size = size >> 4;
        
        if (remaining_size > 0) {
            first_byte |= 0x80;
        }
        try header_bytes.append(first_byte);
        
        // Additional size bytes if needed
        while (remaining_size > 0) {
            var size_byte: u8 = @intCast(remaining_size & 0x7F);
            remaining_size >>= 7;
            if (remaining_size > 0) {
                size_byte |= 0x80;
            }
            try header_bytes.append(size_byte);
        }
        
        try data.appendSlice(header_bytes.items);
        
        // Compress object data with zlib
        var compressed = std.ArrayList(u8).init(allocator);
        defer compressed.deinit();
        
        var content_stream = std.io.fixedBufferStream(obj.content);
        try std.compress.zlib.compress(content_stream.reader(), compressed.writer(), .{});
        try data.appendSlice(compressed.items);
    }
    
    // Write pack file checksum (SHA-1 of entire pack content)
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(data.items);
    var checksum: [20]u8 = undefined;
    hasher.final(&checksum);
    try data.appendSlice(&checksum);
    
    return try allocator.dupe(u8, data.items);
}

test "enhanced pack file loading with realistic data" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    // Create realistic test objects
    var test_objects = [_]TestObject{
        TestObject{
            .hash = [_]u8{0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x12, 0x34, 0x56, 0x78},
            .offset = 12,
            .obj_type = .blob,
            .content = "Hello, World! This is a test file.",
        },
        TestObject{
            .hash = [_]u8{0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x01},
            .offset = 200, // Will be calculated properly in real pack
            .obj_type = .commit,
            .content = "tree 1234567890abcdef\nauthor Test User <test@example.com> 1234567890 +0000\ncommitter Test User <test@example.com> 1234567890 +0000\n\nInitial commit\n",
        },
    };
    
    const idx_data = try createRealisticPackIndexV2(allocator, &test_objects);
    const pack_data = try createRealisticPackFile(allocator, &test_objects);
    
    // Setup mock platform
    var platform = MockPlatform.init(allocator);
    defer platform.deinit();
    
    try platform.fs.setFile("/test/.git/objects/pack/pack-test.idx", idx_data);
    try platform.fs.setFile("/test/.git/objects/pack/pack-test.pack", pack_data);
    
    // Test loading the first object
    const hash_str = "123456789abcdef0123456789abcdef012345678";
    const result = objects.GitObject.load(hash_str, "/test/.git", platform, allocator) catch |err| {
        std.debug.print("Failed to load object: {}\n", .{err});
        return err;
    };
    defer result.deinit(allocator);
    
    try testing.expect(result.type == .blob);
    try testing.expectEqualStrings("Hello, World! This is a test file.", result.data);
}

test "pack file error handling and recovery" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var platform = MockPlatform.init(allocator);
    defer platform.deinit();
    
    // Test missing pack directory
    const result1 = objects.GitObject.load("123456789abcdef0123456789abcdef012345678", "/nonexistent/.git", platform, allocator);
    try testing.expectError(error.ObjectNotFound, result1);
    
    // Test corrupted pack index
    const corrupted_idx = [_]u8{0x00, 0x01, 0x02, 0x03}; // Too short
    try platform.fs.setFile("/test/.git/objects/pack/pack-corrupted.idx", &corrupted_idx);
    
    const result2 = objects.GitObject.load("123456789abcdef0123456789abcdef012345678", "/test/.git", platform, allocator);
    try testing.expectError(error.ObjectNotFound, result2);
    
    // Test pack file without corresponding index
    const simple_pack = "PACK" ++ [_]u8{0x00, 0x00, 0x00, 0x02} ++ [_]u8{0x00, 0x00, 0x00, 0x01};
    try platform.fs.setFile("/test/.git/objects/pack/pack-noindex.pack", &simple_pack);
    
    const result3 = objects.GitObject.load("123456789abcdef0123456789abcdef012345678", "/test/.git", platform, allocator);
    try testing.expectError(error.ObjectNotFound, result3);
}

test "pack file statistics and analysis" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var platform = MockPlatform.init(allocator);
    defer platform.deinit();
    
    // Create a test pack with multiple object types
    const test_objects = [_]TestObject{
        TestObject{
            .hash = [_]u8{0x01} ++ [_]u8{0x00} ** 19,
            .offset = 12,
            .obj_type = .blob,
            .content = "blob content",
        },
        TestObject{
            .hash = [_]u8{0x02} ++ [_]u8{0x00} ** 19,
            .offset = 100,
            .obj_type = .tree,
            .content = "100644 file.txt\x001234567890abcdef1234",
        },
        TestObject{
            .hash = [_]u8{0x03} ++ [_]u8{0x00} ** 19,
            .offset = 200,
            .obj_type = .commit,
            .content = "tree abcdef\nauthor Test <test@test.com> 123456789 +0000\ncommitter Test <test@test.com> 123456789 +0000\n\nTest commit",
        },
    };
    
    const pack_data = try createRealisticPackFile(allocator, &test_objects);
    try platform.fs.setFile("/test/pack-stats.pack", pack_data);
    
    // Test pack file analysis
    const stats = try objects.analyzePackFile("/test/pack-stats.pack", platform, allocator);
    
    try testing.expect(stats.total_objects == 3);
    try testing.expect(stats.version == 2);
    try testing.expect(stats.checksum_valid);
    try testing.expect(stats.file_size == pack_data.len);
}

test "pack index version 1 fallback handling" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    // Create a pack index v1 format (no magic header)
    var data = std.ArrayList(u8).init(allocator);
    defer data.deinit();
    
    // Fanout table (256 * 4 bytes)
    for (0..256) |i| {
        const count: u32 = if (i >= 0x12) 1 else 0; // One object with hash starting 0x12...
        try data.writer().writeInt(u32, count, .big);
    }
    
    // Object entry: 4 bytes offset + 20 bytes SHA-1
    try data.writer().writeInt(u32, 12, .big); // offset
    const test_hash = [_]u8{0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x12, 0x34, 0x56, 0x78};
    try data.appendSlice(&test_hash);
    
    const idx_data = try allocator.dupe(u8, data.items);
    
    // Create corresponding pack file
    const pack_data = try createRealisticPackFile(allocator, &[_]TestObject{
        TestObject{
            .hash = test_hash,
            .offset = 12,
            .obj_type = .blob,
            .content = "v1 index test content",
        },
    });
    
    var platform = MockPlatform.init(allocator);
    defer platform.deinit();
    
    try platform.fs.setFile("/test/.git/objects/pack/pack-v1test.idx", idx_data);
    try platform.fs.setFile("/test/.git/objects/pack/pack-v1test.pack", pack_data);
    
    // This should work with v1 index format
    const hash_str = "123456789abcdef0123456789abcdef012345678";
    const result = objects.GitObject.load(hash_str, "/test/.git", platform, allocator) catch |err| {
        std.debug.print("V1 index test failed: {}\n", .{err});
        return err;
    };
    defer result.deinit(allocator);
    
    try testing.expect(result.type == .blob);
    try testing.expectEqualStrings("v1 index test content", result.data);
}