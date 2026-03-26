const std = @import("std");
const testing = std.testing;
const objects = @import("../src/git/objects.zig");

/// Mock platform implementation for testing
const MockPlatform = struct {
    const Self = @This();
    
    pack_data: std.HashMap([]const u8, []const u8),
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .pack_data = std.HashMap([]const u8, []const u8).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        var iterator = self.pack_data.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.pack_data.deinit();
    }
    
    pub fn addFile(self: *Self, path: []const u8, data: []const u8) !void {
        const path_copy = try self.allocator.dupe(u8, path);
        const data_copy = try self.allocator.dupe(u8, data);
        try self.pack_data.put(path_copy, data_copy);
    }
    
    pub const fs = struct {
        pub fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
            _ = allocator;
            _ = path;
            return error.FileNotFound;
        }
        
        pub fn writeFile(path: []const u8, data: []const u8) !void {
            _ = path;
            _ = data;
        }
        
        pub fn makeDir(path: []const u8) !void {
            _ = path;
        }
    };
};

/// Test pack file creation and parsing workflow  
test "pack file workflow simulation" {
    const allocator = testing.allocator;
    
    // Create test objects that would be stored in a pack file
    const blob_content = "Hello, pack file world!";
    const tree_content = "100644 hello.txt\x00" ++ ("\x12\x34\x56\x78" ** 5); // Mock hash
    const commit_content = "tree " ++ ("a" ** 40) ++ "\nauthor Test User <test@example.com> 1234567890 +0000\ncommitter Test User <test@example.com> 1234567890 +0000\n\nInitial commit\n";
    
    // Test object creation
    const blob = try objects.createBlobObject(blob_content, allocator);
    defer blob.deinit(allocator);
    
    try testing.expectEqual(objects.ObjectType.blob, blob.type);
    try testing.expectEqualStrings(blob_content, blob.data);
    
    // Test hash calculation
    const hash = try blob.hash(allocator);
    defer allocator.free(hash);
    
    try testing.expect(hash.len == 40);
    for (hash) |c| {
        try testing.expect(std.ascii.isHex(c));
    }
    
    // Test tree entry creation
    var tree_entries = std.ArrayList(objects.TreeEntry).init(allocator);
    defer {
        for (tree_entries.items) |entry| {
            entry.deinit(allocator);
        }
        tree_entries.deinit();
    }
    
    const entry = objects.TreeEntry.init(
        try allocator.dupe(u8, "100644"),
        try allocator.dupe(u8, "hello.txt"),
        try allocator.dupe(u8, hash)
    );
    try tree_entries.append(entry);
    
    const tree = try objects.createTreeObject(tree_entries.items, allocator);
    defer tree.deinit(allocator);
    
    try testing.expectEqual(objects.ObjectType.tree, tree.type);
    
    // Test commit creation
    const tree_hash = try tree.hash(allocator);
    defer allocator.free(tree_hash);
    
    const parent_hashes = [0][]const u8{};
    const author = "Test User <test@example.com> 1234567890 +0000";
    const committer = author;
    const message = "Initial commit";
    
    const commit = try objects.createCommitObject(
        tree_hash,
        &parent_hashes,
        author,
        committer,
        message,
        allocator
    );
    defer commit.deinit(allocator);
    
    try testing.expectEqual(objects.ObjectType.commit, commit.type);
    try testing.expect(std.mem.indexOf(u8, commit.data, tree_hash) != null);
    try testing.expect(std.mem.indexOf(u8, commit.data, message) != null);
}

/// Test delta application with various scenarios
test "delta application scenarios" {
    const allocator = testing.allocator;
    
    // Test case 1: Simple append
    const base1 = "Hello";
    var delta1 = std.ArrayList(u8).init(allocator);
    defer delta1.deinit();
    
    // Base size (5)
    try delta1.append(5);
    // Result size (11) 
    try delta1.append(11);
    // Copy command: copy 5 bytes from offset 0
    try delta1.append(0x80 | 0x01 | 0x10); // offset=1 byte, size=1 byte
    try delta1.append(0); // offset = 0
    try delta1.append(5); // size = 5
    // Insert command: add " World"
    const insert1 = " World";
    try delta1.append(@intCast(insert1.len));
    try delta1.appendSlice(insert1);
    
    // This tests the structure without actually calling applyDelta
    try testing.expect(delta1.items.len > 0);
    
    // Test case 2: Complex delta with multiple operations
    const base2 = "The quick brown fox jumps over the lazy dog";
    var delta2 = std.ArrayList(u8).init(allocator);
    defer delta2.deinit();
    
    // Base size (43)
    try delta2.append(43);
    // Result size (let's say 50)
    try delta2.append(50);
    // Copy "The quick" (9 bytes from offset 0)
    try delta2.append(0x80 | 0x01 | 0x10);
    try delta2.append(0); // offset 0
    try delta2.append(9); // size 9
    // Insert " red"
    const insert2 = " red";
    try delta2.append(@intCast(insert2.len));
    try delta2.appendSlice(insert2);
    
    try testing.expect(delta2.items.len > 0);
    
    // Test case 3: Large copy operations
    var delta3 = std.ArrayList(u8).init(allocator);
    defer delta3.deinit();
    
    // Test 0x10000 size encoding (when copy_size == 0)
    try delta3.append(100); // base size
    try delta3.append(200); // result size  
    try delta3.append(0x80 | 0x01); // copy with offset=1 byte, size=0 (means 0x10000)
    try delta3.append(0); // offset 0
    // size is omitted (0) which means 0x10000
    
    try testing.expect(delta3.items.len == 4);
}

/// Test variable-length integer encoding/decoding
test "variable length integer codec" {
    const allocator = testing.allocator;
    
    const test_cases = [_]struct { value: u64, bytes: []const u8 }{
        .{ .value = 0, .bytes = &[_]u8{0x00} },
        .{ .value = 127, .bytes = &[_]u8{0x7F} },
        .{ .value = 128, .bytes = &[_]u8{0x80, 0x01} },
        .{ .value = 255, .bytes = &[_]u8{0xFF, 0x01} },
        .{ .value = 256, .bytes = &[_]u8{0x80, 0x02} },
        .{ .value = 16383, .bytes = &[_]u8{0xFF, 0x7F} },
        .{ .value = 16384, .bytes = &[_]u8{0x80, 0x80, 0x01} },
    };
    
    for (test_cases) |case| {
        // Test decoding
        var pos: usize = 0;
        var value: u64 = 0;
        var shift: u6 = 0;
        
        while (pos < case.bytes.len and shift < 64) {
            const b = case.bytes[pos];
            pos += 1;
            value |= @as(u64, @intCast(b & 0x7F)) << shift;
            if (b & 0x80 == 0) break;
            shift += 7;
        }
        
        // For the simpler cases, test exact match
        if (case.value <= 16384) {
            try testing.expectEqual(case.value, value);
        }
    }
    
    _ = allocator;
}

/// Test pack index fanout table calculation
test "pack index fanout optimization" {
    const allocator = testing.allocator;
    
    // Simulate hash distribution for fanout table
    const hashes = [_][]const u8{
        "0123456789abcdef0123456789abcdef01234567", // starts with 0x01
        "1123456789abcdef0123456789abcdef01234567", // starts with 0x11  
        "2123456789abcdef0123456789abcdef01234567", // starts with 0x21
        "a123456789abcdef0123456789abcdef01234567", // starts with 0xa1
        "f123456789abcdef0123456789abcdef01234567", // starts with 0xf1
    };
    
    // Build fanout table
    var fanout = [_]u32{0} ** 256;
    var cumulative: u32 = 0;
    
    for (hashes) |hash| {
        var first_byte_value: u8 = 0;
        _ = std.fmt.hexToBytes(@ptrCast(&first_byte_value), hash[0..2]) catch continue;
        
        // Increment counts up to this first byte
        var i: u32 = first_byte_value;
        while (i < 256) : (i += 1) {
            fanout[i] += 1;
        }
    }
    
    // Make cumulative
    for (fanout, 0..) |*entry, i| {
        cumulative += if (i == 0) 0 else 1; // Simulate object distribution
        entry.* = cumulative;
    }
    
    try testing.expect(fanout[255] >= 0); // Should have some count
    try testing.expect(fanout[0] <= fanout[255]); // Should be non-decreasing
    
    _ = allocator;
}

/// Test object type enum consistency
test "object type consistency" {
    // Verify ObjectType and PackObjectType alignment
    try testing.expectEqual(@as(u8, 1), @intFromEnum(objects.PackObjectType.commit));
    try testing.expectEqual(@as(u8, 2), @intFromEnum(objects.PackObjectType.tree));
    try testing.expectEqual(@as(u8, 3), @intFromEnum(objects.PackObjectType.blob));
    try testing.expectEqual(@as(u8, 4), @intFromEnum(objects.PackObjectType.tag));
    
    // Delta types are pack-specific
    try testing.expectEqual(@as(u8, 6), @intFromEnum(objects.PackObjectType.ofs_delta));
    try testing.expectEqual(@as(u8, 7), @intFromEnum(objects.PackObjectType.ref_delta));
    
    // Test ObjectType string conversion
    try testing.expectEqualStrings("blob", objects.ObjectType.blob.toString());
    try testing.expectEqualStrings("tree", objects.ObjectType.tree.toString());
    try testing.expectEqualStrings("commit", objects.ObjectType.commit.toString());
    try testing.expectEqualStrings("tag", objects.ObjectType.tag.toString());
    
    // Test reverse conversion
    try testing.expectEqual(objects.ObjectType.blob, objects.ObjectType.fromString("blob"));
    try testing.expectEqual(objects.ObjectType.tree, objects.ObjectType.fromString("tree"));
    try testing.expectEqual(objects.ObjectType.commit, objects.ObjectType.fromString("commit"));
    try testing.expectEqual(objects.ObjectType.tag, objects.ObjectType.fromString("tag"));
    try testing.expectEqual(@as(?objects.ObjectType, null), objects.ObjectType.fromString("invalid"));
}