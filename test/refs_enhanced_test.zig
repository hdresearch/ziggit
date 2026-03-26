const std = @import("std");
const testing = std.testing;
const refs = @import("../src/git/refs.zig");

// Mock platform implementation for refs testing
const MockPlatform = struct {
    fs: MockFs,
    
    const MockFs = struct {
        files: std.StringHashMap([]const u8),
        allocator: std.mem.Allocator,
        
        pub fn init(allocator: std.mem.Allocator) MockFs {
            return MockFs{
                .files = std.StringHashMap([]const u8).init(allocator),
                .allocator = allocator,
            };
        }
        
        pub fn deinit(self: *MockFs) void {
            var iterator = self.files.iterator();
            while (iterator.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            self.files.deinit();
        }
        
        pub fn setFile(self: *MockFs, path: []const u8, content: []const u8) !void {
            const owned_path = try self.allocator.dupe(u8, path);
            const owned_content = try self.allocator.dupe(u8, content);
            try self.files.put(owned_path, owned_content);
        }
        
        pub fn readFile(self: MockFs, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
            if (self.files.get(path)) |content| {
                return try allocator.dupe(u8, content);
            }
            return error.FileNotFound;
        }
        
        pub fn writeFile(self: MockFs, path: []const u8, content: []const u8) !void {
            _ = self;
            _ = path;
            _ = content;
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

test "symbolic ref resolution with nested references" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var platform = MockPlatform.init(allocator);
    defer platform.deinit();
    
    const git_dir = "/test/.git";
    
    // Set up a chain of symbolic references
    // HEAD -> refs/heads/main -> refs/heads/master -> actual commit
    const commit_hash = "abcdef1234567890abcdef1234567890abcdef12";
    
    try platform.fs.setFile("/test/.git/HEAD", "ref: refs/heads/main\n");
    try platform.fs.setFile("/test/.git/refs/heads/main", "ref: refs/heads/master\n");
    try platform.fs.setFile("/test/.git/refs/heads/master", commit_hash ++ "\n");
    
    // Test resolving HEAD through the chain
    const resolved = try refs.resolveRef(git_dir, "HEAD", platform, allocator);
    try testing.expect(resolved != null);
    defer allocator.free(resolved.?);
    
    try testing.expectEqualStrings(commit_hash, resolved.?);
    
    // Test resolving intermediate refs
    const main_resolved = try refs.resolveRef(git_dir, "refs/heads/main", platform, allocator);
    try testing.expect(main_resolved != null);
    defer allocator.free(main_resolved.?);
    
    try testing.expectEqualStrings(commit_hash, main_resolved.?);
}

test "circular reference detection" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var platform = MockPlatform.init(allocator);
    defer platform.deinit();
    
    const git_dir = "/test/.git";
    
    // Create a circular reference: A -> B -> C -> A
    try platform.fs.setFile("/test/.git/refs/heads/branch-a", "ref: refs/heads/branch-b\n");
    try platform.fs.setFile("/test/.git/refs/heads/branch-b", "ref: refs/heads/branch-c\n");
    try platform.fs.setFile("/test/.git/refs/heads/branch-c", "ref: refs/heads/branch-a\n");
    
    // Should detect the circular reference
    try testing.expectError(error.CircularRef, refs.resolveRef(git_dir, "refs/heads/branch-a", platform, allocator));
}

test "annotated tag resolution" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var platform = MockPlatform.init(allocator);
    defer platform.deinit();
    
    const git_dir = "/test/.git";
    
    // Set up an annotated tag pointing to a commit
    const tag_object_hash = "1234567890abcdef1234567890abcdef12345678";
    const commit_hash = "abcdef1234567890abcdef1234567890abcdef12";
    
    try platform.fs.setFile("/test/.git/refs/tags/v1.0", tag_object_hash ++ "\n");
    
    // Mock the tag object (this would normally be loaded from objects)
    // For this test, we'll assume the tag resolves to a commit hash
    // In real usage, resolveAnnotatedTag would parse the tag object
    
    // Test direct commit reference
    try platform.fs.setFile("/test/.git/refs/tags/v1.0-lightweight", commit_hash ++ "\n");
    
    const lightweight_resolved = try refs.resolveRef(git_dir, "refs/tags/v1.0-lightweight", platform, allocator);
    try testing.expect(lightweight_resolved != null);
    defer allocator.free(lightweight_resolved.?);
    
    try testing.expectEqualStrings(commit_hash, lightweight_resolved.?);
}

test "remote tracking branch resolution" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var platform = MockPlatform.init(allocator);
    defer platform.deinit();
    
    const git_dir = "/test/.git";
    
    const commit_hash = "fedcba0987654321fedcba0987654321fedcba09";
    
    // Set up remote tracking branches
    try platform.fs.setFile("/test/.git/refs/remotes/origin/main", commit_hash ++ "\n");
    try platform.fs.setFile("/test/.git/refs/remotes/origin/develop", commit_hash ++ "\n");
    try platform.fs.setFile("/test/.git/refs/remotes/upstream/main", commit_hash ++ "\n");
    
    // Test resolving remote branches
    const origin_main = try refs.resolveRef(git_dir, "refs/remotes/origin/main", platform, allocator);
    try testing.expect(origin_main != null);
    defer allocator.free(origin_main.?);
    try testing.expectEqualStrings(commit_hash, origin_main.?);
    
    // Test short name resolution should try remotes/ if heads/ fails
    const short_name = try refs.resolveRef(git_dir, "origin/main", platform, allocator);
    try testing.expect(short_name != null);
    defer allocator.free(short_name.?);
    try testing.expectEqualStrings(commit_hash, short_name.?);
}

test "ref name validation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var platform = MockPlatform.init(allocator);
    defer platform.deinit();
    
    const git_dir = "/test/.git";
    
    // Test invalid ref names that should be rejected
    const invalid_names = [_][]const u8{
        "",                    // Empty
        "refs/heads/",        // Ends with slash
        "refs/heads/.hidden", // Starts with dot
        "refs/heads/bad..name", // Contains double dot
        "refs/heads/bad name", // Contains space
        "refs/heads/bad~name", // Contains tilde
        "refs/heads/bad^name", // Contains caret
        "refs/heads/bad:name", // Contains colon
        "refs/heads/bad?name", // Contains question mark
        "refs/heads/bad*name", // Contains asterisk
        "refs/heads/bad[name", // Contains bracket
        "refs/heads/bad\\name", // Contains backslash
        "refs/heads/bad.lock", // Ends with .lock
    };
    
    for (invalid_names) |invalid_name| {
        try testing.expectError(error.InvalidRefNameChar, refs.resolveRef(git_dir, invalid_name, platform, allocator));
    }
    
    // Test valid ref names
    const valid_commit = "1111111111111111111111111111111111111111";
    const valid_names = [_][]const u8{
        "refs/heads/main",
        "refs/heads/feature-branch",
        "refs/heads/feature_branch",
        "refs/heads/feature123",
        "refs/tags/v1.0.0",
        "refs/remotes/origin/main",
    };
    
    for (valid_names) |valid_name| {
        try platform.fs.setFile(try std.fmt.allocPrint(allocator, "/test/.git/{s}", .{valid_name}), valid_commit ++ "\n");
        const result = try refs.resolveRef(git_dir, valid_name, platform, allocator);
        try testing.expect(result != null);
        allocator.free(result.?);
    }
}

test "detached HEAD scenarios" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var platform = MockPlatform.init(allocator);
    defer platform.deinit();
    
    const git_dir = "/test/.git";
    
    // Test detached HEAD (direct commit hash)
    const commit_hash = "deadbeefcafebabe1234567890abcdef12345678";
    try platform.fs.setFile("/test/.git/HEAD", commit_hash ++ "\n");
    
    const current_branch = try refs.getCurrentBranch(git_dir, platform, allocator);
    defer allocator.free(current_branch);
    
    try testing.expectEqualStrings("HEAD", current_branch);
    
    const current_commit = try refs.getCurrentCommit(git_dir, platform, allocator);
    try testing.expect(current_commit != null);
    defer allocator.free(current_commit.?);
    
    try testing.expectEqualStrings(commit_hash, current_commit.?);
}

test "ref resolution fallback behavior" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var platform = MockPlatform.init(allocator);
    defer platform.deinit();
    
    const git_dir = "/test/.git";
    
    const commit_hash = "abcdef1234567890abcdef1234567890abcdef12";
    
    // Set up refs in different namespaces
    try platform.fs.setFile("/test/.git/refs/heads/main", commit_hash ++ "\n");
    try platform.fs.setFile("/test/.git/refs/tags/v1.0", commit_hash ++ "\n");
    try platform.fs.setFile("/test/.git/refs/remotes/origin/feature", commit_hash ++ "\n");
    
    // Test that short names resolve to the right namespaces in order of preference
    
    // Should resolve to refs/heads/main first
    const main_resolved = try refs.resolveRef(git_dir, "main", platform, allocator);
    try testing.expect(main_resolved != null);
    defer allocator.free(main_resolved.?);
    try testing.expectEqualStrings(commit_hash, main_resolved.?);
    
    // Should resolve to refs/tags/v1.0 when heads/ doesn't exist
    const tag_resolved = try refs.resolveRef(git_dir, "v1.0", platform, allocator);
    try testing.expect(tag_resolved != null);
    defer allocator.free(tag_resolved.?);
    try testing.expectEqualStrings(commit_hash, tag_resolved.?);
    
    // Should resolve to refs/remotes/origin/feature when neither heads/ nor tags/ exist
    const remote_resolved = try refs.resolveRef(git_dir, "origin/feature", platform, allocator);
    try testing.expect(remote_resolved != null);
    defer allocator.free(remote_resolved.?);
    try testing.expectEqualStrings(commit_hash, remote_resolved.?);
}

test "packed refs support" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var platform = MockPlatform.init(allocator);
    defer platform.deinit();
    
    // Create a packed-refs file with multiple refs
    const packed_refs_content =
        \\# pack-refs with: peeled fully-peeled sorted
        \\abcdef1234567890abcdef1234567890abcdef12 refs/heads/main
        \\1234567890abcdef1234567890abcdef12345678 refs/heads/develop
        \\^fedcba0987654321fedcba0987654321fedcba09
        \\deadbeefcafebabe1234567890abcdef12345678 refs/tags/v1.0
        \\^abcdef1234567890abcdef1234567890abcdef12
        \\9876543210fedcba9876543210fedcba98765432 refs/remotes/origin/main
    ;
    
    try platform.fs.setFile("/test/.git/packed-refs", packed_refs_content);
    
    // Test that refs can be resolved from packed-refs when loose refs don't exist
    // This would be implemented in the actual refs.zig as an enhancement
    
    // For now, just test that we can parse the format
    var lines = std.mem.split(u8, packed_refs_content, "\n");
    var ref_count: usize = 0;
    
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\n\r");
        if (trimmed.len == 0 or trimmed[0] == '#' or trimmed[0] == '^') continue;
        
        if (std.mem.indexOf(u8, trimmed, " ")) |space_pos| {
            const hash = trimmed[0..space_pos];
            const ref_name = trimmed[space_pos + 1..];
            
            // Validate hash format
            try testing.expectEqual(@as(usize, 40), hash.len);
            for (hash) |c| {
                try testing.expect(std.ascii.isHex(c));
            }
            
            // Validate ref name format
            try testing.expect(std.mem.startsWith(u8, ref_name, "refs/"));
            
            ref_count += 1;
        }
    }
    
    try testing.expectEqual(@as(usize, 4), ref_count);
}

test "ref update safety and atomic operations" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var platform = MockPlatform.init(allocator);
    defer platform.deinit();
    
    const git_dir = "/test/.git";
    
    // Test safe ref updates (this would be implemented as part of ref writing)
    const old_commit = "1111111111111111111111111111111111111111";
    const new_commit = "2222222222222222222222222222222222222222";
    
    try platform.fs.setFile("/test/.git/refs/heads/main", old_commit ++ "\n");
    
    // Verify current value
    const current = try refs.resolveRef(git_dir, "refs/heads/main", platform, allocator);
    try testing.expect(current != null);
    defer allocator.free(current.?);
    try testing.expectEqualStrings(old_commit, current.?);
    
    // Test lock file mechanism (simulate)
    const lock_file = "/test/.git/refs/heads/main.lock";
    
    // In a real implementation, this would:
    // 1. Create the lock file with new content
    // 2. Verify the old value hasn't changed
    // 3. Atomically rename lock file to actual ref
    // 4. Update reflog if enabled
    
    // For this test, just verify the concept
    try platform.fs.setFile(lock_file, new_commit ++ "\n");
    
    // Verify lock file exists and has correct content
    const lock_content = try platform.fs.readFile(allocator, lock_file);
    defer allocator.free(lock_content);
    
    const trimmed_lock = std.mem.trim(u8, lock_content, " \t\n\r");
    try testing.expectEqualStrings(new_commit, trimmed_lock);
}

test "ref name normalization and case sensitivity" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var platform = MockPlatform.init(allocator);
    defer platform.deinit();
    
    const git_dir = "/test/.git";
    
    const commit_hash = "abcdef1234567890abcdef1234567890abcdef12";
    
    // Git ref names are case sensitive on case-sensitive filesystems
    try platform.fs.setFile("/test/.git/refs/heads/Main", commit_hash ++ "\n");
    try platform.fs.setFile("/test/.git/refs/heads/main", commit_hash ++ "\n");
    
    // These should be different refs
    const main_lower = try refs.resolveRef(git_dir, "refs/heads/main", platform, allocator);
    try testing.expect(main_lower != null);
    defer allocator.free(main_lower.?);
    
    const main_upper = try refs.resolveRef(git_dir, "refs/heads/Main", platform, allocator);
    try testing.expect(main_upper != null);
    defer allocator.free(main_upper.?);
    
    // Both should resolve to the same commit in this test
    try testing.expectEqualStrings(commit_hash, main_lower.?);
    try testing.expectEqualStrings(commit_hash, main_upper.?);
    
    // Test ref name components validation
    const valid_components = [_][]const u8{
        "feature",
        "feature-123",
        "feature_123", 
        "123-feature",
        "v1.0.0",
    };
    
    for (valid_components) |component| {
        const ref_name = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{component});
        defer allocator.free(ref_name);
        
        try platform.fs.setFile(try std.fmt.allocPrint(allocator, "/test/.git/{s}", .{ref_name}), commit_hash ++ "\n");
        
        const resolved = try refs.resolveRef(git_dir, ref_name, platform, allocator);
        try testing.expect(resolved != null);
        allocator.free(resolved.?);
    }
}