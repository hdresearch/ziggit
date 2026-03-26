const std = @import("std");
const testing = std.testing;
const fs = std.fs;
const refs = @import("../src/git/refs.zig");

/// Mock platform implementation for testing
const MockPlatform = struct {
    files: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .files = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Self) void {
        var iterator = self.files.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.files.deinit();
    }
    
    pub fn addFile(self: *Self, path: []const u8, content: []const u8) !void {
        const path_copy = try self.allocator.dupe(u8, path);
        const content_copy = try self.allocator.dupe(u8, content);
        try self.files.put(path_copy, content_copy);
    }
    
    pub const FS = struct {
        platform: *MockPlatform,
        
        pub fn readFile(self: @This(), allocator: std.mem.Allocator, path: []const u8) ![]u8 {
            if (self.platform.files.get(path)) |content| {
                return try allocator.dupe(u8, content);
            }
            return error.FileNotFound;
        }
        
        pub fn writeFile(self: @This(), path: []const u8, content: []const u8) !void {
            try self.platform.addFile(path, content);
        }
        
        pub fn deleteFile(self: @This(), path: []const u8) !void {
            if (self.platform.files.getPtr(path)) |entry| {
                self.platform.allocator.free(entry.key_ptr.*);
                self.platform.allocator.free(entry.value_ptr.*);
                _ = self.platform.files.remove(path);
            } else {
                return error.FileNotFound;
            }
        }
        
        pub fn makeDir(self: @This(), path: []const u8) !void {
            _ = self;
            _ = path;
            // No-op for mock
        }
        
        pub fn exists(self: @This(), path: []const u8) !bool {
            return self.platform.files.contains(path);
        }
        
        pub fn readDir(self: @This(), allocator: std.mem.Allocator, path: []const u8) ![][]u8 {
            _ = self;
            _ = allocator;
            _ = path;
            return error.NotSupported; // Simplified for testing
        }
    };
    
    pub fn getFS(self: *Self) FS {
        return FS{ .platform = self };
    }
};

/// Comprehensive test for refs functionality
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.debug.print("Warning: memory leaked in comprehensive refs tests\n", .{});
        }
    }
    const allocator = gpa.allocator();

    std.debug.print("Running Comprehensive Refs Tests...\n", .{});

    // Test 1: Basic ref resolution
    try testBasicRefResolution(allocator);
    
    // Test 2: Symbolic ref chains
    try testSymbolicRefChains(allocator);
    
    // Test 3: Circular ref detection
    try testCircularRefDetection(allocator);
    
    // Test 4: Packed-refs handling
    try testPackedRefsHandling(allocator);
    
    // Test 5: Ref name validation
    try testRefNameValidation(allocator);

    std.debug.print("All comprehensive refs tests completed successfully!\n", .{});
}

fn testBasicRefResolution(allocator: std.mem.Allocator) !void {
    std.debug.print("Test: Basic ref resolution\n", .{});
    
    var platform = MockPlatform.init(allocator);
    defer platform.deinit();
    
    const fs_impl = platform.getFS();
    
    // Set up a basic repository structure
    const commit_hash = "1234567890abcdef1234567890abcdef12345678";
    
    try platform.addFile("/tmp/test/.git/HEAD", "ref: refs/heads/main\n");
    try platform.addFile("/tmp/test/.git/refs/heads/main", "1234567890abcdef1234567890abcdef12345678\n");
    
    // Test HEAD resolution
    const resolved_head = try refs.resolveRef("/tmp/test/.git", "HEAD", fs_impl, allocator);
    if (resolved_head) |hash| {
        defer allocator.free(hash);
        try testing.expectEqualStrings(commit_hash, hash);
    } else {
        return error.TestFailed;
    }
    
    // Test direct branch resolution
    const resolved_main = try refs.resolveRef("/tmp/test/.git", "main", fs_impl, allocator);
    if (resolved_main) |hash| {
        defer allocator.free(hash);
        try testing.expectEqualStrings(commit_hash, hash);
    } else {
        return error.TestFailed;
    }
    
    std.debug.print("  ✓ Basic ref resolution passed\n", .{});
}

fn testSymbolicRefChains(allocator: std.mem.Allocator) !void {
    std.debug.print("Test: Symbolic ref chains\n", .{});
    
    var platform = MockPlatform.init(allocator);
    defer platform.deinit();
    
    const fs_impl = platform.getFS();
    
    // Set up a chain of symbolic refs: HEAD -> main -> master -> commit_hash
    const commit_hash = "abcdef1234567890abcdef1234567890abcdef12";
    
    try platform.addFile("/tmp/test/.git/HEAD", "ref: refs/heads/main\n");
    try platform.addFile("/tmp/test/.git/refs/heads/main", "ref: refs/heads/master\n");
    try platform.addFile("/tmp/test/.git/refs/heads/master", "abcdef1234567890abcdef1234567890abcdef12\n");
    
    // Test chain resolution
    const resolved = try refs.resolveRef("/tmp/test/.git", "HEAD", fs_impl, allocator);
    if (resolved) |hash| {
        defer allocator.free(hash);
        try testing.expectEqualStrings(commit_hash, hash);
    } else {
        return error.TestFailed;
    }
    
    std.debug.print("  ✓ Symbolic ref chains passed\n", .{});
}

fn testCircularRefDetection(allocator: std.mem.Allocator) !void {
    std.debug.print("Test: Circular ref detection\n", .{});
    
    var platform = MockPlatform.init(allocator);
    defer platform.deinit();
    
    const fs_impl = platform.getFS();
    
    // Set up circular refs: HEAD -> main -> master -> main
    try platform.addFile("/tmp/test/.git/HEAD", "ref: refs/heads/main\n");
    try platform.addFile("/tmp/test/.git/refs/heads/main", "ref: refs/heads/master\n");
    try platform.addFile("/tmp/test/.git/refs/heads/master", "ref: refs/heads/main\n");
    
    // Test that circular reference is detected
    const result = refs.resolveRef("/tmp/test/.git", "HEAD", fs_impl, allocator);
    try testing.expectError(error.CircularRef, result);
    
    std.debug.print("  ✓ Circular ref detection passed\n", .{});
}

fn testPackedRefsHandling(allocator: std.mem.Allocator) !void {
    std.debug.print("Test: Packed-refs handling\n", .{});
    
    var platform = MockPlatform.init(allocator);
    defer platform.deinit();
    
    const fs_impl = platform.getFS();
    
    // Set up packed-refs file
    const packed_refs_content =
        \\# pack-refs with: peeled fully-peeled sorted
        \\1234567890abcdef1234567890abcdef12345678 refs/heads/main
        \\abcdef1234567890abcdef1234567890abcdef12 refs/heads/feature
        \\fedcba0987654321fedcba0987654321fedcba09 refs/tags/v1.0
        \\^1111111111111111111111111111111111111111
        \\5555555555555555555555555555555555555555 refs/remotes/origin/main
    ;
    
    try platform.addFile("/tmp/test/.git/packed-refs", packed_refs_content);
    
    // Test resolving refs from packed-refs
    const main_hash = try refs.resolveRef("/tmp/test/.git", "main", fs_impl, allocator);
    if (main_hash) |hash| {
        defer allocator.free(hash);
        try testing.expectEqualStrings("1234567890abcdef1234567890abcdef12345678", hash);
    } else {
        return error.TestFailed;
    }
    
    const feature_hash = try refs.resolveRef("/tmp/test/.git", "feature", fs_impl, allocator);
    if (feature_hash) |hash| {
        defer allocator.free(hash);
        try testing.expectEqualStrings("abcdef1234567890abcdef1234567890abcdef12", hash);
    } else {
        return error.TestFailed;
    }
    
    // Test tag resolution (should resolve to peeled ref)
    const tag_hash = try refs.resolveRef("/tmp/test/.git", "v1.0", fs_impl, allocator);
    if (tag_hash) |hash| {
        defer allocator.free(hash);
        // Should get the peeled ref, not the tag object
        try testing.expectEqualStrings("1111111111111111111111111111111111111111", hash);
    } else {
        return error.TestFailed;
    }
    
    std.debug.print("  ✓ Packed-refs handling passed\n", .{});
}

fn testRefNameValidation(allocator: std.mem.Allocator) !void {
    std.debug.print("Test: Ref name validation\n", .{});
    
    var platform = MockPlatform.init(allocator);
    defer platform.deinit();
    
    const fs_impl = platform.getFS();
    
    // Test empty ref name
    const empty_result = refs.resolveRef("/tmp/test/.git", "", fs_impl, allocator);
    try testing.expectError(error.EmptyRefName, empty_result);
    
    // Test very long ref name
    var long_name = std.ArrayList(u8).init(allocator);
    defer long_name.deinit();
    
    var i: usize = 0;
    while (i < 2000) : (i += 1) { // Create a 2000-character name
        try long_name.append('a');
    }
    
    const long_result = refs.resolveRef("/tmp/test/.git", long_name.items, fs_impl, allocator);
    try testing.expectError(error.RefNameTooLong, long_result);
    
    // Test valid ref name patterns
    const valid_names = [_][]const u8{
        "main",
        "feature/new-feature",
        "v1.0.0",
        "refs/heads/main",
        "refs/tags/v1.0",
        "refs/remotes/origin/main",
    };
    
    for (valid_names) |name| {
        // These should at least not fail with validation errors
        // (they may fail with FileNotFound, which is expected)
        const result = refs.resolveRef("/tmp/test/.git", name, fs_impl, allocator);
        if (result) |hash| {
            allocator.free(hash);
        } else |err| {
            // FileNotFound and RefNotFound are acceptable for this test
            try testing.expect(err == error.FileNotFound or err == error.RefNotFound);
        }
    }
    
    std.debug.print("  ✓ Ref name validation passed\n", .{});
}

test "comprehensive refs tests" {
    try main();
}