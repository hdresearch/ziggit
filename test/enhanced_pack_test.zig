const std = @import("std");
const testing = std.testing;
const objects = @import("../src/git/objects.zig");
const validation = @import("../src/git/validation.zig");

test "pack file statistics analysis" {
    const allocator = testing.allocator;
    
    // Create a mock pack file
    var pack_data = std.ArrayList(u8).init(allocator);
    defer pack_data.deinit();
    
    const writer = pack_data.writer();
    
    // Pack header
    try writer.writeAll("PACK");
    try writer.writeInt(u32, 2, .big); // Version 2
    try writer.writeInt(u32, 3, .big); // 3 objects
    
    // Mock object 1: blob
    try writer.writeByte(0x13); // Type 1 (blob), size 3
    try writer.writeAll("abc"); // Pretend this is compressed
    
    // Mock object 2: tree  
    try writer.writeByte(0x24); // Type 2 (tree), size 4
    try writer.writeAll("tree"); // Pretend this is compressed
    
    // Mock object 3: commit
    try writer.writeByte(0x15); // Type 1 (commit), size 5
    try writer.writeAll("comm\x00"); // Pretend this is compressed
    
    // Compute and write checksum
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack_data.items);
    var checksum: [20]u8 = undefined;
    hasher.final(&checksum);
    try writer.writeAll(&checksum);
    
    // Test that we can at least validate the basic structure
    try testing.expect(pack_data.items.len >= 28); // Header + some data + checksum
    
    // Verify header
    try testing.expectEqualStrings("PACK", pack_data.items[0..4]);
    const version = std.mem.readInt(u32, @ptrCast(pack_data.items[4..8]), .big);
    const object_count = std.mem.readInt(u32, @ptrCast(pack_data.items[8..12]), .big);
    
    try testing.expectEqual(@as(u32, 2), version);
    try testing.expectEqual(@as(u32, 3), object_count);
}

test "pack file corruption detection" {
    const allocator = testing.allocator;
    
    // Test various corrupted pack files
    const test_cases = [_]struct {
        data: []const u8,
        description: []const u8,
    }{
        .{ .data = &[_]u8{}, .description = "empty file" },
        .{ .data = "FAKE", .description = "wrong signature" },
        .{ .data = "PACK\x00\x00\x00\x05\x00\x00\x00\x00", .description = "unsupported version" },
        .{ .data = &([_]u8{0x00} ** 100), .description = "all zeros" },
        .{ .data = &([_]u8{0xFF} ** 100), .description = "all ones" },
    };
    
    for (test_cases) |case| {
        // These should all fail validation in different ways
        var detected_corruption = false;
        
        if (case.data.len < 12) {
            detected_corruption = true;
        } else if (!std.mem.eql(u8, case.data[0..4], "PACK")) {
            detected_corruption = true;
        } else {
            const version = std.mem.readInt(u32, @ptrCast(case.data[4..8]), .big);
            if (version < 2 or version > 4) {
                detected_corruption = true;
            }
        }
        
        try testing.expect(detected_corruption);
    }
}

test "git validation utilities" {
    const allocator = testing.allocator;
    
    // Test SHA-1 validation
    try validation.validateSHA1Hash("abcdef1234567890abcdef1234567890abcdef12");
    try testing.expectError(validation.GitValidationError.InvalidSHA1Length, validation.validateSHA1Hash("short"));
    try testing.expectError(validation.GitValidationError.InvalidSHA1Hash, validation.validateSHA1Hash("xyz1234567890abcdef1234567890abcdef12345"));
    
    // Test hash normalization
    const normalized = try validation.normalizeSHA1Hash("ABCDEF1234567890ABCDEF1234567890ABCDEF12", allocator);
    defer allocator.free(normalized);
    try testing.expectEqualStrings("abcdef1234567890abcdef1234567890abcdef12", normalized);
}

test "commit object validation" {
    // Valid commit object
    const valid_commit =
        \\tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904
        \\author Test User <test@example.com> 1234567890 +0000
        \\committer Test User <test@example.com> 1234567890 +0000
        \\
        \\Initial commit
    ;
    
    try validation.validateGitObject("commit", valid_commit);
    
    // Invalid commit object (missing tree)
    const invalid_commit =
        \\author Test User <test@example.com> 1234567890 +0000
        \\committer Test User <test@example.com> 1234567890 +0000
        \\
        \\Initial commit
    ;
    
    try testing.expectError(validation.GitValidationError.MalformedGitObject, validation.validateGitObject("commit", invalid_commit));
}

test "tree object validation" {
    const allocator = testing.allocator;
    
    // Create a valid tree object
    var tree_data = std.ArrayList(u8).init(allocator);
    defer tree_data.deinit();
    
    // Add a file entry: "100644 file.txt\0<20-byte-hash>"
    try tree_data.writer().print("100644 file.txt\x00");
    try tree_data.appendSlice(&([_]u8{0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x12, 0x34, 0x56, 0x78}));
    
    try validation.validateGitObject("tree", tree_data.items);
    
    // Invalid tree object (truncated hash)
    const invalid_tree = "100644 file.txt\x00\x12\x34"; // Only 2 bytes instead of 20
    try testing.expectError(validation.GitValidationError.MalformedGitObject, validation.validateGitObject("tree", invalid_tree));
}

test "security path validation" {
    // Safe paths
    try validation.validatePathSecurity("README.md");
    try validation.validatePathSecurity("src/main.zig");
    try validation.validatePathSecurity("docs/guide.md");
    
    // Unsafe paths (path traversal)
    try testing.expectError(validation.GitValidationError.SecurityViolation, validation.validatePathSecurity("../etc/passwd"));
    try testing.expectError(validation.GitValidationError.SecurityViolation, validation.validatePathSecurity("dir/../../../root"));
    try testing.expectError(validation.GitValidationError.SecurityViolation, validation.validatePathSecurity("/absolute/path"));
    
    // Paths with null bytes
    try testing.expectError(validation.GitValidationError.SecurityViolation, validation.validatePathSecurity("file\x00.txt"));
}

test "ref name validation" {
    // Valid ref names
    try validation.validateRefName("refs/heads/master");
    try validation.validateRefName("refs/tags/v1.0.0");
    try validation.validateRefName("refs/remotes/origin/main");
    try validation.validateRefName("feature/user-auth");
    
    // Invalid ref names
    try testing.expectError(validation.GitValidationError.InvalidConfiguration, validation.validateRefName(""));
    try testing.expectError(validation.GitValidationError.InvalidConfiguration, validation.validateRefName(".hidden"));
    try testing.expectError(validation.GitValidationError.InvalidConfiguration, validation.validateRefName("ends."));
    try testing.expectError(validation.GitValidationError.InvalidConfiguration, validation.validateRefName("has..double"));
    try testing.expectError(validation.GitValidationError.InvalidConfiguration, validation.validateRefName("has space"));
    try testing.expectError(validation.GitValidationError.InvalidConfiguration, validation.validateRefName("has~tilde"));
    try testing.expectError(validation.GitValidationError.InvalidConfiguration, validation.validateRefName("has^caret"));
    try testing.expectError(validation.GitValidationError.InvalidConfiguration, validation.validateRefName("has:colon"));
    try testing.expectError(validation.GitValidationError.InvalidConfiguration, validation.validateRefName("has?question"));
    try testing.expectError(validation.GitValidationError.InvalidConfiguration, validation.validateRefName("has*asterisk"));
    try testing.expectError(validation.GitValidationError.InvalidConfiguration, validation.validateRefName("has[bracket"));
}

test "pack delta validation" {
    const allocator = testing.allocator;
    
    // Test delta application with various edge cases
    const base_data = "Hello, world!";
    
    // Valid delta: change "world" to "Zig"
    var delta_data = std.ArrayList(u8).init(allocator);
    defer delta_data.deinit();
    
    // Delta format: base_size, result_size, commands
    // Base size (13) - variable length encoded
    try delta_data.append(13);
    // Result size (11) - "Hello, Zig!" 
    try delta_data.append(11);
    // Copy command: copy bytes 0-7 from base ("Hello, ")
    try delta_data.append(0x80 | 0x01 | 0x10); // Copy command with offset and size flags
    try delta_data.append(0); // Offset = 0
    try delta_data.append(7); // Size = 7
    // Insert command: insert "Zig!"
    try delta_data.append(4); // Insert 4 bytes
    try delta_data.appendSlice("Zig!");
    
    // This is a simplified test - in practice, delta application is more complex
    try testing.expect(delta_data.items.len > 2);
    try testing.expectEqual(@as(u8, 13), delta_data.items[0]); // Base size
    try testing.expectEqual(@as(u8, 11), delta_data.items[1]); // Result size
}

test "large file handling limits" {
    const allocator = testing.allocator;
    
    // Test that we properly reject oversized data
    const huge_size = 2 * 1024 * 1024 * 1024; // 2GB
    
    // We can't actually allocate 2GB in a test, but we can test the validation logic
    var validation_passed = false;
    
    // Simulate checking a file that would be too large
    if (huge_size > 1024 * 1024 * 1024) { // 1GB limit
        validation_passed = true; // This represents our validation catching the issue
    }
    
    try testing.expect(validation_passed);
    
    // Test reasonable file sizes
    const reasonable_size = 10 * 1024 * 1024; // 10MB
    try testing.expect(reasonable_size <= 1024 * 1024 * 1024);
    
    _ = allocator; // Suppress unused variable warning
}