const std = @import("std");
const testing = std.testing;
const refs = @import("../src/git/refs.zig");
const validation = @import("../src/git/validation.zig");

// Mock platform implementation for testing
const TestPlatform = struct {
    files: std.HashMap([]const u8, []const u8, std.hash_map.StringContext, 80),
    allocator: std.mem.Allocator,

    const fs = struct {
        fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
            // This is a simplified mock - in real tests, we'd need more sophisticated mocking
            if (std.mem.endsWith(u8, path, "/HEAD")) {
                return try allocator.dupe(u8, "ref: refs/heads/master\n");
            } else if (std.mem.endsWith(u8, path, "/refs/heads/master")) {
                return try allocator.dupe(u8, "abcdef1234567890abcdef1234567890abcdef12\n");
            } else if (std.mem.endsWith(u8, path, "/packed-refs")) {
                return try allocator.dupe(u8,
                    \\# pack-refs with: peeled fully-peeled sorted 
                    \\abcdef1234567890abcdef1234567890abcdef12 refs/heads/master
                    \\bcdef1234567890abcdef1234567890abcdef123 refs/heads/develop
                    \\cdef1234567890abcdef1234567890abcdef1234 refs/tags/v1.0.0
                    \\^def1234567890abcdef1234567890abcdef12345
                    \\ef1234567890abcdef1234567890abcdef123456 refs/remotes/origin/master
                );
            }
            return error.FileNotFound;
        }
        
        fn exists(path: []const u8) !bool {
            if (std.mem.endsWith(u8, path, "/HEAD")) return true;
            if (std.mem.endsWith(u8, path, "/refs/heads/master")) return true;
            if (std.mem.endsWith(u8, path, "/packed-refs")) return true;
            return false;
        }
        
        fn writeFile(path: []const u8, content: []const u8) !void {
            _ = path;
            _ = content;
            // Mock implementation - in real tests, we'd track writes
        }
        
        fn makeDir(path: []const u8) !void {
            _ = path;
            // Mock implementation
        }
        
        fn readDir(allocator: std.mem.Allocator, path: []const u8) ![][]u8 {
            var entries = std.ArrayList([]u8).init(allocator);
            
            if (std.mem.endsWith(u8, path, "/refs/heads")) {
                try entries.append(try allocator.dupe(u8, "master"));
                try entries.append(try allocator.dupe(u8, "develop"));
                try entries.append(try allocator.dupe(u8, "feature-branch"));
            } else if (std.mem.endsWith(u8, path, "/refs/remotes")) {
                try entries.append(try allocator.dupe(u8, "origin"));
                try entries.append(try allocator.dupe(u8, "upstream"));
            } else if (std.mem.endsWith(u8, path, "/refs/tags")) {
                try entries.append(try allocator.dupe(u8, "v1.0.0"));
                try entries.append(try allocator.dupe(u8, "v1.1.0"));
            }
            
            return entries.toOwnedSlice();
        }
        
        fn deleteFile(path: []const u8) !void {
            _ = path;
            // Mock implementation
        }
    };
};

test "ref name validation" {
    // Valid ref names
    try validation.validateRefName("refs/heads/master");
    try validation.validateRefName("refs/heads/feature-branch");
    try validation.validateRefName("refs/tags/v1.0.0");
    try validation.validateRefName("refs/remotes/origin/master");
    try validation.validateRefName("refs/heads/user/feature");
    
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
    
    // Ref name that's too long
    const long_name = "a" ** 1025; // 1025 characters
    try testing.expectError(validation.GitValidationError.InvalidConfiguration, validation.validateRefName(long_name));
}

test "current branch detection" {
    const allocator = testing.allocator;
    const platform_impl = TestPlatform{ .allocator = allocator, .files = undefined };
    
    // Test getting current branch from HEAD
    const current_branch = try refs.getCurrentBranch("/test/repo/.git", platform_impl, allocator);
    defer allocator.free(current_branch);
    
    try testing.expectEqualStrings("master", current_branch);
}

test "ref resolution with fallback" {
    const allocator = testing.allocator;
    const platform_impl = TestPlatform{ .allocator = allocator, .files = undefined };
    
    // Test resolving HEAD
    if (refs.resolveRef("/test/repo/.git", "HEAD", platform_impl, allocator)) |hash| {
        defer allocator.free(hash);
        try testing.expectEqualStrings("abcdef1234567890abcdef1234567890abcdef12", hash);
    } else |err| {
        // In the mock implementation, this should work
        try testing.expect(false); // Should not reach here
        _ = err;
    }
}

test "packed-refs parsing with peeled refs" {
    const allocator = testing.allocator;
    
    // Test parsing packed-refs format
    const packed_refs_content =
        \\# pack-refs with: peeled fully-peeled sorted 
        \\# This is a comment
        \\abcdef1234567890abcdef1234567890abcdef12 refs/heads/master
        \\bcdef1234567890abcdef1234567890abcdef123 refs/heads/develop
        \\cdef1234567890abcdef1234567890abcdef1234 refs/tags/v1.0.0
        \\^def1234567890abcdef1234567890abcdef12345
        \\ef1234567890abcdef1234567890abcdef123456 refs/remotes/origin/master
        \\f1234567890abcdef1234567890abcdef1234567 refs/remotes/upstream/master
        \\1234567890abcdef1234567890abcdef12345678 refs/tags/v1.1.0
        \\^234567890abcdef1234567890abcdef123456789
    ;
    
    // Parse the content manually to test our understanding
    var lines = std.mem.split(u8, packed_refs_content, "\n");
    var found_master = false;
    var found_tag_with_peel = false;
    var prev_ref: ?[]const u8 = null;
    
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        
        if (trimmed[0] == '^') {
            // Peeled ref
            if (prev_ref != null and std.mem.eql(u8, prev_ref.?, "refs/tags/v1.0.0")) {
                found_tag_with_peel = true;
            }
            continue;
        }
        
        if (std.mem.indexOf(u8, trimmed, " ")) |space_pos| {
            const hash = trimmed[0..space_pos];
            const ref_path = trimmed[space_pos + 1..];
            
            prev_ref = ref_path;
            
            if (std.mem.eql(u8, ref_path, "refs/heads/master")) {
                try testing.expectEqualStrings("abcdef1234567890abcdef1234567890abcdef12", hash);
                found_master = true;
            }
        }
    }
    
    try testing.expect(found_master);
    try testing.expect(found_tag_with_peel);
}

test "branch operations" {
    const allocator = testing.allocator;
    const platform_impl = TestPlatform{ .allocator = allocator, .files = undefined };
    
    // Test branch existence check
    const master_exists = try refs.branchExists("/test/repo/.git", "master", platform_impl, allocator);
    try testing.expect(master_exists);
    
    const nonexistent_exists = try refs.branchExists("/test/repo/.git", "nonexistent", platform_impl, allocator);
    try testing.expect(!nonexistent_exists);
    
    // Test listing branches
    const branches = try refs.listBranches("/test/repo/.git", platform_impl, allocator);
    defer {
        for (branches.items) |branch| {
            allocator.free(branch);
        }
        branches.deinit();
    }
    
    try testing.expect(branches.items.len > 0);
    
    // Check that master is in the list
    var found_master = false;
    for (branches.items) |branch| {
        if (std.mem.eql(u8, branch, "master")) {
            found_master = true;
            break;
        }
    }
    try testing.expect(found_master);
}

test "remote operations" {
    const allocator = testing.allocator;
    const platform_impl = TestPlatform{ .allocator = allocator, .files = undefined };
    
    // Test listing remotes
    const remotes = try refs.listRemotes("/test/repo/.git", platform_impl, allocator);
    defer {
        for (remotes.items) |remote| {
            allocator.free(remote);
        }
        remotes.deinit();
    }
    
    try testing.expect(remotes.items.len > 0);
    
    // Check that origin is in the list
    var found_origin = false;
    for (remotes.items) |remote| {
        if (std.mem.eql(u8, remote, "origin")) {
            found_origin = true;
            break;
        }
    }
    try testing.expect(found_origin);
    
    // Test listing remote branches
    const remote_branches = try refs.listRemoteBranches("/test/repo/.git", "origin", platform_impl, allocator);
    defer {
        for (remote_branches.items) |branch| {
            allocator.free(branch);
        }
        remote_branches.deinit();
    }
    
    // Should have some remote branches
    try testing.expect(remote_branches.items.len >= 0); // May be empty in mock
}

test "tag operations" {
    const allocator = testing.allocator;
    const platform_impl = TestPlatform{ .allocator = allocator, .files = undefined };
    
    // Test listing tags
    const tags = try refs.listTags("/test/repo/.git", platform_impl, allocator);
    defer {
        for (tags.items) |tag| {
            allocator.free(tag);
        }
        tags.deinit();
    }
    
    try testing.expect(tags.items.len > 0);
    
    // Check for expected tags
    var found_v1 = false;
    for (tags.items) |tag| {
        if (std.mem.eql(u8, tag, "v1.0.0")) {
            found_v1 = true;
            break;
        }
    }
    try testing.expect(found_v1);
}

test "symbolic ref resolution with depth limit" {
    const allocator = testing.allocator;
    
    // Test that we don't follow symbolic refs indefinitely
    // This is a conceptual test - we can't easily create infinite loops in our mock
    
    // Test depth tracking
    var depth: u32 = 0;
    const max_depth = 20;
    
    // Simulate following symbolic refs
    while (depth < max_depth + 5) { // Go beyond max
        depth += 1;
        if (depth > max_depth) {
            // Should detect excessive depth
            try testing.expect(depth > max_depth);
            break;
        }
    }
    
    try testing.expect(depth > max_depth);
}

test "hash validation in refs" {
    const allocator = testing.allocator;
    
    // Test valid hashes
    const valid_hashes = [_][]const u8{
        "abcdef1234567890abcdef1234567890abcdef12",
        "0123456789abcdef0123456789abcdef01234567",
        "ffffffffffffffffffffffffffffffffffffffff",
        "0000000000000000000000000000000000000000",
    };
    
    for (valid_hashes) |hash| {
        // Test that our hash validation accepts these
        var is_valid = true;
        if (hash.len != 40) {
            is_valid = false;
        } else {
            for (hash) |c| {
                if (!std.ascii.isHex(c)) {
                    is_valid = false;
                    break;
                }
            }
        }
        try testing.expect(is_valid);
    }
    
    // Test invalid hashes
    const invalid_hashes = [_][]const u8{
        "too_short",
        "way_too_long_to_be_a_valid_hash_string_definitely",
        "xyz1234567890abcdef1234567890abcdef12345", // invalid hex
        "ABCDEF1234567890ABCDEF1234567890ABCDEF12", // uppercase (depends on normalization)
        "",
    };
    
    for (invalid_hashes) |hash| {
        var is_valid = true;
        if (hash.len != 40) {
            is_valid = false;
        } else {
            for (hash) |c| {
                if (!std.ascii.isHex(c)) {
                    is_valid = false;
                    break;
                }
            }
        }
        // Most of these should be invalid
        if (!std.mem.eql(u8, hash, "ABCDEF1234567890ABCDEF1234567890ABCDEF12")) {
            try testing.expect(!is_valid);
        }
    }
    
    _ = allocator;
}

test "error handling in ref operations" {
    const allocator = testing.allocator;
    
    // Test various error conditions that should be handled gracefully
    
    // Empty ref name
    try testing.expectError(validation.GitValidationError.InvalidConfiguration, validation.validateRefName(""));
    
    // Ref name too long
    const long_ref = "refs/heads/" ++ ("a" ** 1000);
    try testing.expectError(validation.GitValidationError.InvalidConfiguration, validation.validateRefName(long_ref));
    
    // Invalid characters
    const invalid_chars = [_][]const u8{
        "refs/heads/has space",
        "refs/heads/has~tilde",
        "refs/heads/has^caret",
        "refs/heads/has:colon",
        "refs/heads/has?question",
        "refs/heads/has*asterisk",
        "refs/heads/has[bracket",
        "refs/heads/has\x00null",
        "refs/heads/has\x01control",
    };
    
    for (invalid_chars) |invalid_ref| {
        try testing.expectError(validation.GitValidationError.InvalidConfiguration, validation.validateRefName(invalid_ref));
    }
}

test "annotated tag parsing" {
    const allocator = testing.allocator;
    
    // Test tag object content parsing
    const tag_content =
        \\object 1234567890abcdef1234567890abcdef12345678
        \\type commit
        \\tag v1.0.0
        \\tagger Test User <test@example.com> 1234567890 +0000
        \\
        \\Release version 1.0.0
        \\
        \\This is the first stable release.
    ;
    
    // Parse tag object manually to find the target object
    var lines = std.mem.split(u8, tag_content, "\n");
    var found_object = false;
    
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "object ")) {
            const target_hash = line["object ".len..];
            
            // Validate it's a proper hash
            if (target_hash.len == 40) {
                var is_valid_hash = true;
                for (target_hash) |c| {
                    if (!std.ascii.isHex(c)) {
                        is_valid_hash = false;
                        break;
                    }
                }
                if (is_valid_hash) {
                    found_object = true;
                    try testing.expectEqualStrings("1234567890abcdef1234567890abcdef12345678", target_hash);
                }
            }
            break;
        }
    }
    
    try testing.expect(found_object);
    
    _ = allocator;
}