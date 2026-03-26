const std = @import("std");
const testing = std.testing;
const repository = @import("../src/git/repository.zig");

// Mock platform implementation for testing
const MockPlatform = struct {
    fs: MockFs = .{},
    
    const MockFs = struct {
        test_data: std.StringHashMap([]const u8) = undefined,
        directories: std.StringHashMap(void) = undefined,
        
        pub fn init(allocator: std.mem.Allocator) MockFs {
            return MockFs{
                .test_data = std.StringHashMap([]const u8).init(allocator),
                .directories = std.StringHashMap(void).init(allocator),
            };
        }
        
        pub fn deinit(self: *MockFs) void {
            self.test_data.deinit();
            self.directories.deinit();
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
        
        pub fn writeFile(self: *MockFs, path: []const u8, data: []const u8) !void {
            try self.setFile(path, data);
        }
        
        pub fn makeDir(self: *MockFs, path: []const u8) !void {
            try self.directories.put(path, {});
        }
        
        pub fn exists(self: MockFs, path: []const u8) !bool {
            return self.test_data.contains(path) or self.directories.contains(path);
        }
        
        pub fn stat(self: MockFs, path: []const u8) !std.fs.File.Stat {
            if (self.test_data.contains(path)) {
                return std.fs.File.Stat{
                    .size = 100,
                    .mode = 0o644,
                    .kind = .file,
                    .ctime = 1640995200000000000,
                    .mtime = 1640995200000000000,
                    .atime = 1640995200000000000,
                    .inode = 12345,
                };
            }
            return error.FileNotFound;
        }
    };
    
    pub fn writeStdout(self: MockPlatform, data: []const u8) !void {
        _ = self;
        _ = data;
        // No-op for tests
    }
};

test "file status enum conversion" {
    try testing.expect(repository.FileStatus.unmodified.toChar() == ' ');
    try testing.expect(repository.FileStatus.modified.toChar() == 'M');
    try testing.expect(repository.FileStatus.added.toChar() == 'A');
    try testing.expect(repository.FileStatus.deleted.toChar() == 'D');
    try testing.expect(repository.FileStatus.renamed.toChar() == 'R');
    try testing.expect(repository.FileStatus.copied.toChar() == 'C');
    try testing.expect(repository.FileStatus.unmerged.toChar() == 'U');
    try testing.expect(repository.FileStatus.untracked.toChar() == '?');
    try testing.expect(repository.FileStatus.ignored.toChar() == '!');
}

test "status entry creation and methods" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    const entry1 = repository.StatusEntry.init("file.txt", .added, .unmodified);
    try testing.expect(entry1.isStaged());
    try testing.expect(!entry1.isUnstaged());
    try testing.expect(!entry1.isUntracked());
    try testing.expect(!entry1.isIgnored());
    
    const entry2 = repository.StatusEntry.init("file2.txt", .unmodified, .modified);
    try testing.expect(!entry2.isStaged());
    try testing.expect(entry2.isUnstaged());
    try testing.expect(!entry2.isUntracked());
    
    const entry3 = repository.StatusEntry.init("file3.txt", .unmodified, .untracked);
    try testing.expect(!entry3.isStaged());
    try testing.expect(!entry3.isUnstaged()); // untracked is not considered unstaged
    try testing.expect(entry3.isUntracked());
    
    const entry4 = repository.StatusEntry.init("file4.txt", .unmodified, .ignored);
    try testing.expect(entry4.isIgnored());
    
    _ = allocator; // Use allocator to avoid unused variable
}

test "repository status management" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var status = repository.RepositoryStatus.init(allocator);
    defer status.deinit(allocator);
    
    // Add test entries
    try status.addEntry(repository.StatusEntry.init("staged.txt", .added, .unmodified));
    try status.addEntry(repository.StatusEntry.init("modified.txt", .unmodified, .modified));
    try status.addEntry(repository.StatusEntry.init("untracked.txt", .unmodified, .untracked));
    
    try testing.expect(status.entries.items.len == 3);
    
    // Test filtering methods
    const staged = status.getStagedFiles();
    defer staged.deinit();
    try testing.expect(staged.items.len == 1);
    
    const unstaged = status.getUnstagedFiles();
    defer unstaged.deinit();
    try testing.expect(unstaged.items.len == 1);
    
    const untracked = status.getUntrackedFiles();
    defer untracked.deinit();
    try testing.expect(untracked.items.len == 1);
}

test "repository initialization" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var platform = MockPlatform{};
    platform.fs = MockPlatform.MockFs.init(allocator);
    defer platform.fs.deinit();
    
    var repo = repository.Repository.init(allocator, "/test/repo", platform);
    
    try repo.initRepository();
    
    // Check that required directories were created
    try testing.expect(try platform.fs.exists("/test/repo/.git"));
    try testing.expect(try platform.fs.exists("/test/repo/.git/objects"));
    try testing.expect(try platform.fs.exists("/test/repo/.git/refs"));
    try testing.expect(try platform.fs.exists("/test/repo/.git/refs/heads"));
    try testing.expect(try platform.fs.exists("/test/repo/.git/refs/tags"));
    
    // Check that required files were created
    try testing.expect(try platform.fs.exists("/test/repo/.git/HEAD"));
    try testing.expect(try platform.fs.exists("/test/repo/.git/config"));
    try testing.expect(try platform.fs.exists("/test/repo/.git/description"));
    
    // Check HEAD content
    const head_content = try platform.fs.readFile(allocator, "/test/repo/.git/HEAD");
    defer allocator.free(head_content);
    try testing.expectEqualSlices(u8, head_content, "ref: refs/heads/master\n");
}

test "repository existence check" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var platform = MockPlatform{};
    platform.fs = MockPlatform.MockFs.init(allocator);
    defer platform.fs.deinit();
    
    var repo = repository.Repository.init(allocator, "/test/repo", platform);
    
    // Should not exist initially
    try testing.expect(!try repo.exists());
    
    // Create .git directory
    try platform.fs.makeDir("/test/repo/.git");
    
    // Should exist now
    try testing.expect(try repo.exists());
}

test "git directory path generation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var platform = MockPlatform{};
    platform.fs = MockPlatform.MockFs.init(allocator);
    defer platform.fs.deinit();
    
    const repo = repository.Repository.init(allocator, "/test/repo", platform);
    
    const git_dir = try repo.getGitDir(allocator);
    defer allocator.free(git_dir);
    
    try testing.expectEqualSlices(u8, git_dir, "/test/repo/.git");
}

test "current branch detection" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var platform = MockPlatform{};
    platform.fs = MockPlatform.MockFs.init(allocator);
    defer platform.fs.deinit();
    
    const repo = repository.Repository.init(allocator, "/test/repo", platform);
    
    // Set up HEAD pointing to master
    try platform.fs.setFile("/test/repo/.git/HEAD", "ref: refs/heads/master\n");
    
    const branch = try repo.getCurrentBranch();
    if (branch) |b| {
        defer allocator.free(b);
        try testing.expectEqualSlices(u8, b, "master");
    } else {
        try testing.expect(false); // Should have found a branch
    }
}

test "repository clean status check" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var platform = MockPlatform{};
    platform.fs = MockPlatform.MockFs.init(allocator);
    defer platform.fs.deinit();
    
    const repo = repository.Repository.init(allocator, "/test/repo", platform);
    
    // Set up minimal repository structure
    try platform.fs.setFile("/test/repo/.git/HEAD", "ref: refs/heads/master\n");
    
    // With no index file, repository should be considered clean
    const is_clean = try repo.isClean();
    try testing.expect(is_clean);
}

test "HEAD commit retrieval" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var platform = MockPlatform{};
    platform.fs = MockPlatform.MockFs.init(allocator);
    defer platform.fs.deinit();
    
    const repo = repository.Repository.init(allocator, "/test/repo", platform);
    
    // Set up HEAD pointing to a commit hash
    const test_commit = "1234567890abcdef1234567890abcdef12345678";
    try platform.fs.setFile("/test/repo/.git/HEAD", test_commit);
    
    const head_commit = try repo.getHeadCommit();
    if (head_commit) |commit| {
        defer allocator.free(commit);
        try testing.expectEqualSlices(u8, commit, test_commit);
    }
}

test "repository status retrieval" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var platform = MockPlatform{};
    platform.fs = MockPlatform.MockFs.init(allocator);
    defer platform.fs.deinit();
    
    const repo = repository.Repository.init(allocator, "/test/repo", platform);
    
    // Set up minimal repository structure
    try platform.fs.setFile("/test/repo/.git/HEAD", "ref: refs/heads/master\n");
    
    var status = try repo.getStatus();
    defer status.deinit(allocator);
    
    // With empty repository, should have no entries
    try testing.expect(status.entries.items.len == 0);
    
    if (status.branch) |branch| {
        try testing.expectEqualSlices(u8, branch, "master");
    }
}

test "repository operations error handling" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var platform = MockPlatform{};
    platform.fs = MockPlatform.MockFs.init(allocator);
    defer platform.fs.deinit();
    
    const repo = repository.Repository.init(allocator, "/test/repo", platform);
    
    // Test operations on non-existent repository
    // Most operations should handle missing files gracefully
    
    const head_commit = try repo.getHeadCommit();
    try testing.expect(head_commit == null);
    
    var status = try repo.getStatus();
    defer status.deinit(allocator);
    try testing.expect(status.entries.items.len == 0);
}