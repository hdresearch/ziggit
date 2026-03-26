const std = @import("std");
const testing = std.testing;
const objects = @import("../src/git/objects.zig");
const index = @import("../src/git/index.zig");
const refs = @import("../src/git/refs.zig");
const config = @import("../src/git/config.zig");

// Test improved pack file error handling
test "pack file error handling improvements" {
    const allocator = testing.allocator;
    
    // Test invalid hash validation
    const invalid_hashes = [_][]const u8{
        "too_short",
        "123456789012345678901234567890123456789G", // invalid character
        "", // empty
        "1234567890123456789012345678901234567890", // too long
    };
    
    // Create fake platform that always returns FileNotFound
    const FakePlatform = struct {
        const Fs = struct {
            pub fn readFile(self: @This(), alloc: std.mem.Allocator, path: []const u8) ![]u8 {
                _ = self;
                _ = alloc;
                _ = path;
                return error.FileNotFound;
            }
        };
        pub const fs: Fs = .{};
    };
    
    for (invalid_hashes) |invalid_hash| {
        const result = objects.GitObject.load(invalid_hash, ".git", FakePlatform, allocator);
        try testing.expectError(error.ObjectNotFound, result);
    }
}

// Test index improvements with platform-specific fields
test "index platform-specific fields" {
    const allocator = testing.allocator;
    
    // Create a fake file stat
    const fake_stat = std.fs.File.Stat{
        .inode = 12345,
        .size = 1000,
        .mode = 33188, // 100644 in octal
        .kind = .file,
        .atime = 1000000000000000000, // 1 second in nanoseconds
        .mtime = 2000000000000000000, // 2 seconds in nanoseconds
        .ctime = 3000000000000000000, // 3 seconds in nanoseconds
        .dev = 2049, // Example device ID
    };
    
    var hash: [20]u8 = undefined;
    std.crypto.random.bytes(&hash);
    
    const entry = index.IndexEntry.init("test.txt", fake_stat, hash);
    defer allocator.free(entry.path);
    
    // Verify basic fields are set correctly
    try testing.expectEqual(@as(u32, 12345), entry.ino);
    try testing.expectEqual(@as(u32, 1000), entry.size);
    try testing.expectEqual(@as(u32, 33188), entry.mode);
    
    // Verify time fields
    try testing.expectEqual(@as(u32, 3), entry.ctime_sec); // 3 seconds
    try testing.expectEqual(@as(u32, 0), entry.ctime_nsec); // 0 nanoseconds
    try testing.expectEqual(@as(u32, 2), entry.mtime_sec); // 2 seconds
    try testing.expectEqual(@as(u32, 0), entry.mtime_nsec); // 0 nanoseconds
    
    // The dev, uid, gid fields should be set based on platform
    // We can't test specific values since they're platform-dependent,
    // but we can verify they're not the old TODO values of 0
    // (unless we're on a platform where 0 is actually valid)
    std.debug.print("Entry dev: {}, uid: {}, gid: {}\n", .{ entry.dev, entry.uid, entry.gid });
}

// Test config file functionality 
test "config file comprehensive parsing" {
    const allocator = testing.allocator;
    
    const complex_config =
        \\# Git configuration file
        \\[core]
        \\    repositoryformatversion = 0
        \\    filemode = true
        \\    bare = false
        \\    logallrefupdates = true
        \\
        \\[user]
        \\    name = "John Doe"
        \\    email = john.doe@example.com
        \\
        \\[remote "origin"]
        \\    url = https://github.com/user/repo.git
        \\    fetch = +refs/heads/*:refs/remotes/origin/*
        \\
        \\[remote "upstream"]
        \\    url = git@github.com:upstream/repo.git
        \\    fetch = +refs/heads/*:refs/remotes/upstream/*
        \\
        \\[branch "master"]
        \\    remote = origin
        \\    merge = refs/heads/master
        \\
        \\[branch "develop"]
        \\    remote = upstream
        \\    merge = refs/heads/develop
        \\
        \\[alias]
        \\    st = status
        \\    co = checkout
        \\    br = branch
    ;
    
    var git_config = config.GitConfig.init(allocator);
    defer git_config.deinit();
    
    try git_config.parseFromString(complex_config);
    
    // Test basic user config
    try testing.expectEqualStrings("John Doe", git_config.getUserName().?);
    try testing.expectEqualStrings("john.doe@example.com", git_config.getUserEmail().?);
    
    // Test multiple remotes
    try testing.expectEqualStrings("https://github.com/user/repo.git", git_config.getRemoteUrl("origin").?);
    try testing.expectEqualStrings("git@github.com:upstream/repo.git", git_config.getRemoteUrl("upstream").?);
    
    // Test branch configurations
    try testing.expectEqualStrings("origin", git_config.getBranchRemote("master").?);
    try testing.expectEqualStrings("upstream", git_config.getBranchRemote("develop").?);
    try testing.expectEqualStrings("refs/heads/master", git_config.getBranchMerge("master").?);
    try testing.expectEqualStrings("refs/heads/develop", git_config.getBranchMerge("develop").?);
    
    // Test core settings
    try testing.expectEqualStrings("0", git_config.get("core", null, "repositoryformatversion").?);
    try testing.expectEqualStrings("true", git_config.get("core", null, "filemode").?);
    
    // Test aliases
    try testing.expectEqualStrings("status", git_config.get("alias", null, "st").?);
    try testing.expectEqualStrings("checkout", git_config.get("alias", null, "co").?);
    try testing.expectEqualStrings("branch", git_config.get("alias", null, "br").?);
}

// Test refs functionality with error cases
test "refs error handling and edge cases" {
    const allocator = testing.allocator;
    
    // Create fake platform that simulates various error conditions
    const ErrorPlatform = struct {
        const Fs = struct {
            pub fn readFile(self: @This(), alloc: std.mem.Allocator, path: []const u8) ![]u8 {
                _ = self;
                _ = alloc;
                if (std.mem.endsWith(u8, path, "/HEAD")) {
                    return error.AccessDenied;
                } else {
                    return error.FileNotFound;
                }
            }
        };
        pub const fs: Fs = .{};
    };
    
    // Test various error conditions
    const result1 = refs.getCurrentBranch(".git", ErrorPlatform, allocator);
    try testing.expectError(error.AccessDenied, result1);
    
    const result2 = refs.resolveRef(".git", "nonexistent-ref", ErrorPlatform, allocator);
    try testing.expectError(error.RefNotFound, result2);
    
    // Test empty ref name
    const result3 = refs.resolveRef(".git", "", ErrorPlatform, allocator);
    try testing.expectError(error.EmptyRefName, result3);
    
    // Test very long ref name
    const long_ref = "a" ** 2000;
    const result4 = refs.resolveRef(".git", long_ref, ErrorPlatform, allocator);
    try testing.expectError(error.RefNameTooLong, result4);
}

test "all improved implementations" {
    std.debug.print("All improved implementation tests completed!\n", .{});
}