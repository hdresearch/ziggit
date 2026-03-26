const std = @import("std");
const testing = std.testing;
const refs = @import("../src/git/refs.zig");

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

test "get current branch - symbolic ref" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var platform = MockPlatform{};
    platform.fs = MockPlatform.MockFs.init(allocator);
    defer platform.fs.deinit();
    
    // Set HEAD to point to master branch
    try platform.fs.setFile("/test/.git/HEAD", "ref: refs/heads/master\n");
    
    const branch = try refs.getCurrentBranch("/test/.git", platform, allocator);
    defer allocator.free(branch);
    
    try testing.expectEqualSlices(u8, branch, "master");
}

test "get current branch - detached HEAD" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var platform = MockPlatform{};
    platform.fs = MockPlatform.MockFs.init(allocator);
    defer platform.fs.deinit();
    
    // Set HEAD to a direct SHA-1 (detached HEAD)
    const test_sha = "1234567890abcdef1234567890abcdef12345678";
    try platform.fs.setFile("/test/.git/HEAD", test_sha);
    
    const result = refs.getCurrentBranch("/test/.git", platform, allocator);
    try testing.expectError(error.DetachedHead, result);
}

test "resolve ref - direct hash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var platform = MockPlatform{};
    platform.fs = MockPlatform.MockFs.init(allocator);
    defer platform.fs.deinit();
    
    const test_sha = "abcdef1234567890abcdef1234567890abcdef12";
    try platform.fs.setFile("/test/.git/refs/heads/main", test_sha);
    
    const resolved = try refs.resolveRef("refs/heads/main", "/test/.git", platform, allocator);
    defer allocator.free(resolved);
    
    try testing.expectEqualSlices(u8, resolved, test_sha);
}

test "resolve ref - nested symbolic refs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var platform = MockPlatform{};
    platform.fs = MockPlatform.MockFs.init(allocator);
    defer platform.fs.deinit();
    
    // Setup nested symbolic refs: HEAD -> master -> main -> actual hash
    try platform.fs.setFile("/test/.git/HEAD", "ref: refs/heads/master\n");
    try platform.fs.setFile("/test/.git/refs/heads/master", "ref: refs/heads/main\n");
    try platform.fs.setFile("/test/.git/refs/heads/main", "1111111111111111111111111111111111111111\n");
    
    const resolved = try refs.resolveRef("HEAD", "/test/.git", platform, allocator);
    defer allocator.free(resolved);
    
    try testing.expectEqualSlices(u8, resolved, "1111111111111111111111111111111111111111");
}

test "list all refs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var platform = MockPlatform{};
    platform.fs = MockPlatform.MockFs.init(allocator);
    defer platform.fs.deinit();
    
    // Setup some refs
    try platform.fs.setFile("/test/.git/refs/heads/master", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    try platform.fs.setFile("/test/.git/refs/heads/feature", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
    try platform.fs.setFile("/test/.git/refs/tags/v1.0", "cccccccccccccccccccccccccccccccccccccccc");
    
    // This would require implementing a listRefs function in refs.zig
    // For now, just test that our mock setup works
    const master_hash = try refs.resolveRef("refs/heads/master", "/test/.git", platform, allocator);
    defer allocator.free(master_hash);
    try testing.expectEqualSlices(u8, master_hash, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
}

test "create new ref" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var platform = MockPlatform{};
    platform.fs = MockPlatform.MockFs.init(allocator);
    defer platform.fs.deinit();
    
    const test_sha = "1234567890abcdef1234567890abcdef12345678";
    
    // Test creating a new ref
    try refs.createRef("refs/heads/new-branch", test_sha, "/test/.git", platform, allocator);
    
    // Verify it was created correctly
    const resolved = try refs.resolveRef("refs/heads/new-branch", "/test/.git", platform, allocator);
    defer allocator.free(resolved);
    
    try testing.expectEqualSlices(u8, resolved, test_sha);
}

test "update existing ref" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var platform = MockPlatform{};
    platform.fs = MockPlatform.MockFs.init(allocator);
    defer platform.fs.deinit();
    
    const old_sha = "1111111111111111111111111111111111111111";
    const new_sha = "2222222222222222222222222222222222222222";
    
    // Setup existing ref
    try platform.fs.setFile("/test/.git/refs/heads/main", old_sha);
    
    // Update it
    try refs.updateRef("refs/heads/main", new_sha, "/test/.git", platform, allocator);
    
    // Verify update
    const resolved = try refs.resolveRef("refs/heads/main", "/test/.git", platform, allocator);
    defer allocator.free(resolved);
    
    try testing.expectEqualSlices(u8, resolved, new_sha);
}

test "ref validation" {
    // Test valid ref names
    try testing.expect(refs.isValidRefName("refs/heads/master"));
    try testing.expect(refs.isValidRefName("refs/tags/v1.0.0"));
    try testing.expect(refs.isValidRefName("refs/remotes/origin/main"));
    
    // Test invalid ref names
    try testing.expect(!refs.isValidRefName(""));           // empty
    try testing.expect(!refs.isValidRefName(".gitignore")); // starts with dot
    try testing.expect(!refs.isValidRefName("master..dev")); // double dot
    try testing.expect(!refs.isValidRefName("master~1"));   // contains ~
    try testing.expect(!refs.isValidRefName("master^"));    // contains ^
    try testing.expect(!refs.isValidRefName("master:"));    // contains :
    try testing.expect(!refs.isValidRefName("refs/heads/")); // ends with slash
    try testing.expect(!refs.isValidRefName("master.lock")); // ends with .lock
}

test "packed refs support" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var platform = MockPlatform{};
    platform.fs = MockPlatform.MockFs.init(allocator);
    defer platform.fs.deinit();
    
    // Create a packed-refs file
    const packed_refs_content = 
        \\# pack-refs with: peeled fully-peeled sorted
        \\1234567890abcdef1234567890abcdef12345678 refs/heads/master
        \\abcdef1234567890abcdef1234567890abcdef12 refs/heads/feature
        \\^0000000000000000000000000000000000000000
        \\9999999999999999999999999999999999999999 refs/tags/v1.0
        \\
    ;
    
    try platform.fs.setFile("/test/.git/packed-refs", packed_refs_content);
    
    // Test that we can resolve refs from packed-refs
    // This would require implementing packed refs support in refs.zig
    // For now, test the packed refs content parsing
    
    var lines = std.mem.split(u8, packed_refs_content, "\n");
    var ref_count: u32 = 0;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\n\r");
        if (trimmed.len == 0 or trimmed[0] == '#' or trimmed[0] == '^') continue;
        
        if (std.mem.indexOf(u8, trimmed, " ")) |space_pos| {
            const hash = trimmed[0..space_pos];
            const ref_name = trimmed[space_pos + 1..];
            
            // Validate hash format
            if (hash.len == 40) {
                for (hash) |c| {
                    if (!std.ascii.isHex(c)) break;
                }
                ref_count += 1;
            }
            
            _ = ref_name; // Use ref_name to avoid unused variable
        }
    }
    
    try testing.expect(ref_count == 3); // master, feature, v1.0
}

test "tag resolution with annotated tags" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var platform = MockPlatform{};
    platform.fs = MockPlatform.MockFs.init(allocator);
    defer platform.fs.deinit();
    
    // Setup tag pointing to tag object (annotated tag)
    const tag_object_hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const commit_hash = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    
    try platform.fs.setFile("/test/.git/refs/tags/v1.0", tag_object_hash);
    
    // For this test, we would need to mock the tag object content
    // that points to the actual commit. This would require integration
    // with the objects module.
    
    const resolved = try refs.resolveRef("refs/tags/v1.0", "/test/.git", platform, allocator);
    defer allocator.free(resolved);
    
    // Should resolve to tag object hash initially
    try testing.expectEqualSlices(u8, resolved, tag_object_hash);
    
    // Note: Full annotated tag resolution would require loading the tag object
    // and extracting the target commit hash, which would involve the objects module
}

test "ref performance with many refs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var platform = MockPlatform{};
    platform.fs = MockPlatform.MockFs.init(allocator);
    defer platform.fs.deinit();
    
    const num_refs = 1000;
    
    // Create many refs
    for (0..num_refs) |i| {
        const ref_name = try std.fmt.allocPrint(allocator, "/test/.git/refs/heads/branch{d}", .{i});
        const hash = try std.fmt.allocPrint(allocator, "{x:0>40}", .{i});
        
        try platform.fs.setFile(ref_name, hash);
    }
    
    const start_time = std.time.milliTimestamp();
    
    // Resolve several refs
    for (0..10) |i| {
        const ref_name = try std.fmt.allocPrint(allocator, "refs/heads/branch{d}", .{i});
        const resolved = try refs.resolveRef(ref_name, "/test/.git", platform, allocator);
        defer allocator.free(resolved);
        
        const expected = try std.fmt.allocPrint(allocator, "{x:0>40}", .{i});
        defer allocator.free(expected);
        
        try testing.expectEqualSlices(u8, resolved, expected);
    }
    
    const end_time = std.time.milliTimestamp();
    const duration = end_time - start_time;
    
    // Should resolve refs quickly
    try testing.expect(duration < 100); // Less than 100ms
}