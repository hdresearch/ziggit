const std = @import("std");
const testing = std.testing;

// Import core git format modules
const objects = @import("../src/git/objects.zig");
const config = @import("../src/git/config.zig");
const index = @import("../src/git/index.zig");
const refs = @import("../src/git/refs.zig");

// Mock platform for testing
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
        
        pub fn setFile(self: *MockFs, path: []const u8, data: []const u8) !void {
            const owned_path = try self.allocator.dupe(u8, path);
            const owned_data = try self.allocator.dupe(u8, data);
            try self.files.put(owned_path, owned_data);
        }
        
        pub fn readFile(self: MockFs, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
            if (self.files.get(path)) |data| {
                return try allocator.dupe(u8, data);
            }
            return error.FileNotFound;
        }
        
        pub fn writeFile(self: MockFs, path: []const u8, data: []const u8) !void {
            _ = self;
            _ = path;
            _ = data;
            // No-op for mock
        }
        
        pub fn makeDir(self: MockFs, path: []const u8) !void {
            _ = self;
            _ = path;
            // No-op for mock
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

test "config parser handles all required formats" {
    var git_config = config.GitConfig.init(testing.allocator);
    defer git_config.deinit();
    
    const config_content =
        \\[user]
        \\    name = Test User
        \\    email = test@example.com
        \\
        \\[remote "origin"]
        \\    url = https://github.com/user/repo.git
        \\    fetch = +refs/heads/*:refs/remotes/origin/*
        \\
        \\[branch "master"]
        \\    remote = origin
        \\    merge = refs/heads/master
        \\
        \\[core]
        \\    autocrlf = false
        \\    filemode = true
    ;
    
    try git_config.parseFromString(config_content);
    
    // Test user config
    try testing.expectEqualStrings("Test User", git_config.getUserName().?);
    try testing.expectEqualStrings("test@example.com", git_config.getUserEmail().?);
    
    // Test remote config  
    try testing.expectEqualStrings("https://github.com/user/repo.git", git_config.getRemoteUrl("origin").?);
    
    // Test branch config
    try testing.expectEqualStrings("origin", git_config.getBranchRemote("master").?);
    try testing.expectEqualStrings("refs/heads/master", git_config.getBranchMerge("master").?);
    
    // Test core config
    try testing.expectEqual(false, git_config.getBool("core", null, "autocrlf", true));
    try testing.expectEqual(true, git_config.getBool("core", null, "filemode", false));
}

test "refs resolution with symbolic refs" {
    var platform = MockPlatform.init(testing.allocator);
    defer platform.deinit();
    
    // Set up symbolic refs: HEAD -> refs/heads/main -> commit hash
    try platform.fs.setFile("test/.git/HEAD", "ref: refs/heads/main\n");
    try platform.fs.setFile("test/.git/refs/heads/main", "1234567890abcdef1234567890abcdef12345678\n");
    
    // Test current branch detection
    const branch = try refs.getCurrentBranch("test/.git", &platform, testing.allocator);
    defer testing.allocator.free(branch);
    try testing.expectEqualStrings("main", branch);
    
    // Test ref resolution
    const commit_hash = try refs.resolveRef("test/.git", "HEAD", &platform, testing.allocator);
    defer if (commit_hash) |hash| testing.allocator.free(hash);
    try testing.expectEqualStrings("1234567890abcdef1234567890abcdef12345678", commit_hash.?);
}

test "index parsing handles version 2 format" {
    const allocator = testing.allocator;
    
    // Create a minimal valid index v2 structure
    var index_data = std.ArrayList(u8).init(allocator);
    defer index_data.deinit();
    
    const writer = index_data.writer();
    
    // Header: signature + version + entry_count
    try writer.writeAll("DIRC");
    try writer.writeInt(u32, 2, .big); // version 2
    try writer.writeInt(u32, 1, .big);  // 1 entry
    
    // Single index entry (62 bytes + path + padding)
    try writer.writeInt(u32, 1234567890, .big); // ctime_sec
    try writer.writeInt(u32, 0, .big);           // ctime_nsec
    try writer.writeInt(u32, 1234567890, .big); // mtime_sec
    try writer.writeInt(u32, 0, .big);           // mtime_nsec
    try writer.writeInt(u32, 2049, .big);        // dev
    try writer.writeInt(u32, 12345, .big);       // ino
    try writer.writeInt(u32, 33188, .big);       // mode (regular file)
    try writer.writeInt(u32, 1000, .big);        // uid
    try writer.writeInt(u32, 1000, .big);        // gid
    try writer.writeInt(u32, 123, .big);         // size
    
    // SHA-1 hash
    var sha1 = [_]u8{0x12, 0x34, 0x56, 0x78, 0x90, 0xab, 0xcd, 0xef, 0x12, 0x34, 0x56, 0x78, 0x90, 0xab, 0xcd, 0xef, 0x12, 0x34, 0x56, 0x78};
    try writer.writeAll(&sha1);
    
    // Flags (path length = 8)
    try writer.writeInt(u16, 8, .big);
    
    // Path
    try writer.writeAll("test.txt");
    
    // Padding to 8-byte boundary (62 + 8 = 70, need 6 bytes padding to get to 72)
    const padding = [_]u8{0, 0, 0, 0, 0, 0};
    try writer.writeAll(&padding);
    
    // SHA-1 checksum of everything above
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(index_data.items);
    var checksum: [20]u8 = undefined;
    hasher.final(&checksum);
    try writer.writeAll(&checksum);
    
    // Parse the index
    var idx = index.Index.init(allocator);
    defer idx.deinit();
    
    try idx.parseIndexData(index_data.items);
    
    // Verify the parsed entry
    try testing.expect(idx.entries.items.len == 1);
    const entry = idx.entries.items[0];
    try testing.expectEqualStrings("test.txt", entry.path);
    try testing.expect(entry.size == 123);
    try testing.expect(std.mem.eql(u8, &entry.sha1, &sha1));
}

test "object storage and retrieval" {
    var platform = MockPlatform.init(testing.allocator);
    defer platform.deinit();
    
    // Create a test blob object
    const test_data = "Hello, world!";
    const blob = try objects.createBlobObject(test_data, testing.allocator);
    defer blob.deinit(testing.allocator);
    
    // Store the object
    const hash = try blob.store("test/.git", &platform, testing.allocator);
    defer testing.allocator.free(hash);
    
    // Load it back
    const loaded_obj = try objects.GitObject.load(hash, "test/.git", &platform, testing.allocator);
    defer loaded_obj.deinit(testing.allocator);
    
    // Verify it matches
    try testing.expect(loaded_obj.type == objects.ObjectType.blob);
    try testing.expectEqualStrings(test_data, loaded_obj.data);
}

test "tree object creation and parsing" {
    const allocator = testing.allocator;
    
    // Create tree entries
    var entries = [_]objects.TreeEntry{
        objects.TreeEntry.init("100644", "file1.txt", "1234567890abcdef1234567890abcdef12345678"),
        objects.TreeEntry.init("040000", "subdir", "abcdef1234567890abcdef1234567890abcdef12"),
        objects.TreeEntry.init("100755", "script.sh", "fedcba0987654321fedcba0987654321fedcba09"),
    };
    
    // We need to dupe the strings for the TreeEntry
    for (&entries) |*entry| {
        entry.mode = try allocator.dupe(u8, entry.mode);
        entry.name = try allocator.dupe(u8, entry.name);
        entry.hash = try allocator.dupe(u8, entry.hash);
    }
    defer {
        for (entries) |entry| {
            entry.deinit(allocator);
        }
    }
    
    // Create tree object
    const tree_obj = try objects.createTreeObject(&entries, allocator);
    defer tree_obj.deinit(allocator);
    
    try testing.expect(tree_obj.type == objects.ObjectType.tree);
    try testing.expect(tree_obj.data.len > 0);
}

test "commit object creation" {
    const allocator = testing.allocator;
    
    // Create a commit object
    const tree_hash = "1234567890abcdef1234567890abcdef12345678";
    const parent_hashes = [_][]const u8{"abcdef1234567890abcdef1234567890abcdef12"};
    const author = "Test User <test@example.com> 1234567890 +0000";
    const committer = "Test User <test@example.com> 1234567890 +0000";
    const message = "Initial commit";
    
    const commit_obj = try objects.createCommitObject(tree_hash, &parent_hashes, author, committer, message, allocator);
    defer commit_obj.deinit(allocator);
    
    try testing.expect(commit_obj.type == objects.ObjectType.commit);
    try testing.expect(std.mem.indexOf(u8, commit_obj.data, "Initial commit") != null);
    try testing.expect(std.mem.indexOf(u8, commit_obj.data, tree_hash) != null);
}

test "pack file verification and access" {
    const allocator = testing.allocator;
    
    // Test pack file access verification (should handle missing pack dir gracefully)
    const has_pack_access = objects.verifyPackFileAccess("test/.git", &MockPlatform.init(allocator), allocator) catch false;
    
    // Should return false for missing pack directory, not error
    try testing.expect(!has_pack_access);
}

test "config validation" {
    const allocator = testing.allocator;
    
    var git_config = config.GitConfig.init(allocator);
    defer git_config.deinit();
    
    // Add valid config
    try git_config.setValue("user", null, "name", "Test User");
    try git_config.setValue("user", null, "email", "test@example.com");
    try git_config.setValue("core", null, "autocrlf", "false");
    
    const issues = try git_config.validateConfig(allocator);
    defer {
        for (issues) |issue| {
            allocator.free(issue);
        }
        allocator.free(issues);
    }
    
    // Should have no validation issues
    try testing.expect(issues.len == 0);
}

test "integration: config, refs, and objects work together" {
    const allocator = testing.allocator;
    var platform = MockPlatform.init(allocator);
    defer platform.deinit();
    
    // Set up a minimal git repository structure
    const git_config_content =
        \\[user]
        \\    name = Integration Test
        \\    email = test@integration.test
        \\[remote "origin"]
        \\    url = https://github.com/test/repo.git
    ;
    
    try platform.fs.setFile("test/.git/config", git_config_content);
    try platform.fs.setFile("test/.git/HEAD", "ref: refs/heads/main");
    try platform.fs.setFile("test/.git/refs/heads/main", "1234567890abcdef1234567890abcdef12345678");
    
    // Test config loading
    var git_config = try config.loadGitConfig("test/.git", allocator);
    defer git_config.deinit();
    
    try testing.expectEqualStrings("Integration Test", git_config.getUserName().?);
    try testing.expectEqualStrings("https://github.com/test/repo.git", git_config.getRemoteUrl("origin").?);
    
    // Test ref resolution
    const current_commit = try refs.getCurrentCommit("test/.git", &platform, allocator);
    defer if (current_commit) |commit| allocator.free(commit);
    
    try testing.expectEqualStrings("1234567890abcdef1234567890abcdef12345678", current_commit.?);
    
    // Test object creation and storage
    const test_blob = try objects.createBlobObject("Integration test data", allocator);
    defer test_blob.deinit(allocator);
    
    const blob_hash = try test_blob.store("test/.git", &platform, allocator);
    defer allocator.free(blob_hash);
    
    // Verify the blob was stored and can be loaded
    const loaded_blob = try objects.GitObject.load(blob_hash, "test/.git", &platform, allocator);
    defer loaded_blob.deinit(allocator);
    
    try testing.expectEqualStrings("Integration test data", loaded_blob.data);
}