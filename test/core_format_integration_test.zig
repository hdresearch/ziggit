const std = @import("std");
const testing = std.testing;

// Import modules to test
const objects = @import("../src/git/objects.zig");
const config = @import("../src/git/config.zig");
const index = @import("../src/git/index.zig");
const refs = @import("../src/git/refs.zig");
const tree_utils = @import("../src/git/tree_utilities.zig");
const pack_perf = @import("../src/git/pack_performance.zig");

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
            _ = self;
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

test "comprehensive git config parsing and functionality" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    // Test with a comprehensive, realistic git config
    const comprehensive_config =
        \\# This is a comprehensive git configuration for testing
        \\[core]
        \\	repositoryformatversion = 0
        \\	filemode = true
        \\	bare = false
        \\	logallrefupdates = true
        \\	ignorecase = true
        \\	autocrlf = input
        \\	editor = vim
        \\	pager = less -R
        \\
        \\[user]
        \\	name = "Ziggit Developer"
        \\	email = dev@ziggit.example.com
        \\	signingkey = ABC123DEF456
        \\
        \\[remote "origin"]
        \\	url = https://github.com/hdresearch/ziggit.git
        \\	fetch = +refs/heads/*:refs/remotes/origin/*
        \\	pushurl = git@github.com:hdresearch/ziggit.git
        \\
        \\[remote "upstream"]
        \\	url = https://github.com/upstream/ziggit.git
        \\	fetch = +refs/heads/*:refs/remotes/upstream/*
        \\
        \\[branch "master"]
        \\	remote = origin
        \\	merge = refs/heads/master
        \\	rebase = true
        \\
        \\[branch "develop"]
        \\	remote = origin
        \\	merge = refs/heads/develop
        \\	rebase = false
        \\
        \\[push]
        \\	default = simple
        \\	followTags = true
        \\
        \\[pull]
        \\	rebase = true
        \\	ff = only
        \\
        \\[merge]
        \\	tool = vimdiff
        \\	conflictStyle = diff3
        \\
        \\[diff]
        \\	tool = vimdiff
        \\	algorithm = patience
        \\
        \\[alias]
        \\	st = status
        \\	co = checkout
        \\	br = branch
        \\	unstage = "reset HEAD --"
        \\	visual = !gitk
        \\	graph = "log --graph --pretty=format:'%Cred%h%Creset -%C(yellow)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset' --abbrev-commit"
    ;
    
    var git_config = try config.GitConfig.parseConfig(allocator, comprehensive_config);
    defer git_config.deinit();
    
    // Test core configuration
    try testing.expectEqualStrings("0", git_config.get("core", null, "repositoryformatversion").?);
    try testing.expectEqualStrings("true", git_config.get("core", null, "filemode").?);
    try testing.expectEqualStrings("false", git_config.get("core", null, "bare").?);
    try testing.expectEqualStrings("input", git_config.get("core", null, "autocrlf").?);
    try testing.expectEqualStrings("vim", git_config.get("core", null, "editor").?);
    
    // Test user configuration
    try testing.expectEqualStrings("Ziggit Developer", git_config.getUserName().?);
    try testing.expectEqualStrings("dev@ziggit.example.com", git_config.getUserEmail().?);
    try testing.expectEqualStrings("ABC123DEF456", git_config.get("user", null, "signingkey").?);
    
    // Test remote configurations
    try testing.expectEqualStrings("https://github.com/hdresearch/ziggit.git", git_config.getRemoteUrl("origin").?);
    try testing.expectEqualStrings("https://github.com/upstream/ziggit.git", git_config.getRemoteUrl("upstream").?);
    try testing.expectEqualStrings("git@github.com:hdresearch/ziggit.git", git_config.getRemotePushUrl("origin").?);
    
    // Test branch configurations
    try testing.expectEqualStrings("origin", git_config.getBranchRemote("master").?);
    try testing.expectEqualStrings("refs/heads/master", git_config.getBranchMerge("master").?);
    try testing.expectEqual(true, git_config.getBool("branch", "master", "rebase", false));
    try testing.expectEqual(false, git_config.getBool("branch", "develop", "rebase", true));
    
    // Test push/pull configuration
    try testing.expectEqualStrings("simple", git_config.getPushDefault().?);
    try testing.expectEqual(true, git_config.getPullRebase());
    
    // Test tool configuration
    try testing.expectEqualStrings("vimdiff", git_config.getMergeTool().?);
    try testing.expectEqualStrings("vimdiff", git_config.getDiffTool().?);
    try testing.expectEqualStrings("diff3", git_config.getMergeConflictStyle().?);
    
    // Test alias configuration
    try testing.expectEqualStrings("status", git_config.get("alias", null, "st").?);
    try testing.expectEqualStrings("checkout", git_config.get("alias", null, "co").?);
    try testing.expectEqualStrings("reset HEAD --", git_config.get("alias", null, "unstage").?);
    
    // Test configuration validation
    const issues = try git_config.validateConfig(allocator);
    defer {
        for (issues) |issue| {
            allocator.free(issue);
        }
        allocator.free(issues);
    }
    
    // Should have no validation issues with this comprehensive config
    try testing.expectEqual(@as(usize, 0), issues.len);
    
    // Test getting all remotes
    const remotes = try git_config.getAllRemotes(allocator);
    defer {
        for (remotes) |remote| {
            allocator.free(remote);
        }
        allocator.free(remotes);
    }
    
    try testing.expectEqual(@as(usize, 2), remotes.len);
    // Sort to ensure consistent order for testing
    if (std.mem.lessThan(u8, remotes[1], remotes[0])) {
        std.mem.swap([]const u8, &remotes[0], &remotes[1]);
    }
    try testing.expectEqualStrings("origin", remotes[0]);
    try testing.expectEqualStrings("upstream", remotes[1]);
    
    // Test getting all branches
    const branches = try git_config.getAllBranches(allocator);
    defer {
        for (branches) |branch| {
            branch.deinit(allocator);
        }
        allocator.free(branches);
    }
    
    try testing.expectEqual(@as(usize, 2), branches.len);
}

test "git object creation and storage simulation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    // Create different types of objects
    const blob_content = "Hello, World!\nThis is a test blob for ziggit.\n";
    const blob = try objects.createBlobObject(blob_content, allocator);
    defer blob.deinit(allocator);
    
    const tree_entries = [_]objects.TreeEntry{
        objects.TreeEntry.init("100644", try allocator.dupe(u8, "README.md"), try allocator.dupe(u8, "a" ** 40)),
        objects.TreeEntry.init("100755", try allocator.dupe(u8, "build.sh"), try allocator.dupe(u8, "b" ** 40)),
        objects.TreeEntry.init("040000", try allocator.dupe(u8, "src"), try allocator.dupe(u8, "c" ** 40)),
    };
    defer {
        for (tree_entries) |entry| {
            entry.deinit(allocator);
        }
    }
    
    const tree = try objects.createTreeObject(&tree_entries, allocator);
    defer tree.deinit(allocator);
    
    const commit = try objects.createCommitObject(
        "d" ** 40, // tree hash
        &[_][]const u8{"e" ** 40}, // parent hash
        "Test Author <test@example.com> 1234567890 +0000",
        "Test Committer <committer@example.com> 1234567890 +0000",
        "Initial test commit\n\nThis is a test commit message.",
        allocator,
    );
    defer commit.deinit(allocator);
    
    // Test object types
    try testing.expectEqual(objects.ObjectType.blob, blob.type);
    try testing.expectEqual(objects.ObjectType.tree, tree.type);
    try testing.expectEqual(objects.ObjectType.commit, commit.type);
    
    // Test object content
    try testing.expectEqualSlices(u8, blob_content, blob.data);
    try testing.expect(tree.data.len > 0);
    try testing.expect(commit.data.len > 0);
    
    // Test object hashing
    const blob_hash = try blob.hash(allocator);
    defer allocator.free(blob_hash);
    try testing.expectEqual(@as(usize, 40), blob_hash.len);
    
    // Verify hash consistency
    const blob_hash2 = try blob.hash(allocator);
    defer allocator.free(blob_hash2);
    try testing.expectEqualStrings(blob_hash, blob_hash2);
}

test "index file parsing and manipulation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    // Create a mock index with some entries
    var test_index = index.Index.init(allocator);
    defer test_index.deinit();
    
    // Test index operations would go here
    // For now, just test basic initialization
    try testing.expectEqual(@as(usize, 0), test_index.entries.items.len);
    
    // Test index serialization
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    
    const writer = buffer.writer();
    
    // Write minimal valid index header
    try writer.writeAll("DIRC");  // Signature
    try writer.writeInt(u32, 2, .big);  // Version 2
    try writer.writeInt(u32, 0, .big);  // No entries
    
    // Write checksum of header
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(buffer.items);
    var checksum: [20]u8 = undefined;
    hasher.final(&checksum);
    try writer.writeAll(&checksum);
    
    // Test parsing empty index
    var parsed_index = index.Index.init(allocator);
    defer parsed_index.deinit();
    
    try parsed_index.parseIndexData(buffer.items);
    try testing.expectEqual(@as(usize, 0), parsed_index.entries.items.len);
}

test "refs resolution and management" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    // Setup mock filesystem
    var platform = MockPlatform{};
    platform.fs = MockPlatform.MockFs.init(allocator);
    defer platform.fs.deinit();
    
    const test_commit_hash = "1234567890abcdef1234567890abcdef12345678";
    
    // Setup mock git directory structure
    try platform.fs.setFile("/test/.git/HEAD", "ref: refs/heads/master\n");
    try platform.fs.setFile("/test/.git/refs/heads/master", test_commit_hash);
    try platform.fs.setFile("/test/.git/refs/heads/develop", "abcdef1234567890abcdef1234567890abcdef12");
    try platform.fs.setFile("/test/.git/refs/tags/v1.0.0", "fedcba0987654321fedcba0987654321fedcba09");
    
    // Test current branch detection
    const current_branch = try refs.getCurrentBranch("/test/.git", platform, allocator);
    defer allocator.free(current_branch);
    try testing.expectEqualStrings("master", current_branch);
    
    // Test ref resolution
    if (try refs.resolveRef("/test/.git", "HEAD", platform, allocator)) |resolved_head| {
        defer allocator.free(resolved_head);
        try testing.expectEqualStrings(test_commit_hash, resolved_head);
    } else {
        try testing.expect(false); // Should have resolved
    }
    
    if (try refs.resolveRef("/test/.git", "master", platform, allocator)) |resolved_master| {
        defer allocator.free(resolved_master);
        try testing.expectEqualStrings(test_commit_hash, resolved_master);
    } else {
        try testing.expect(false); // Should have resolved
    }
    
    // Test direct hash resolution
    if (try refs.resolveRef("/test/.git", "refs/heads/develop", platform, allocator)) |resolved_develop| {
        defer allocator.free(resolved_develop);
        try testing.expectEqualStrings("abcdef1234567890abcdef1234567890abcdef12", resolved_develop);
    } else {
        try testing.expect(false); // Should have resolved
    }
    
    // Test tag resolution
    if (try refs.resolveRef("/test/.git", "v1.0.0", platform, allocator)) |resolved_tag| {
        defer allocator.free(resolved_tag);
        try testing.expectEqualStrings("fedcba0987654321fedcba0987654321fedcba09", resolved_tag);
    } else {
        try testing.expect(false); // Should have resolved
    }
    
    // Test non-existent ref
    const non_existent = try refs.resolveRef("/test/.git", "nonexistent", platform, allocator);
    try testing.expect(non_existent == null);
}

test "tree utilities and walking" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    // Test file mode parsing
    try testing.expectEqual(tree_utils.TreeEntry.FileMode.regular_file, try tree_utils.TreeEntry.FileMode.fromString("100644"));
    try testing.expectEqual(tree_utils.TreeEntry.FileMode.executable_file, try tree_utils.TreeEntry.FileMode.fromString("100755"));
    try testing.expectEqual(tree_utils.TreeEntry.FileMode.directory, try tree_utils.TreeEntry.FileMode.fromString("40000"));
    try testing.expectEqual(tree_utils.TreeEntry.FileMode.symlink, try tree_utils.TreeEntry.FileMode.fromString("120000"));
    
    // Test mode properties
    try testing.expect(tree_utils.TreeEntry.FileMode.directory.isDirectory());
    try testing.expect(tree_utils.TreeEntry.FileMode.executable_file.isExecutable());
    try testing.expect(tree_utils.TreeEntry.FileMode.symlink.isSymlink());
    try testing.expect(!tree_utils.TreeEntry.FileMode.regular_file.isDirectory());
    
    // Test tree object creation and parsing
    const test_entries = [_]tree_utils.TreeEntry{
        tree_utils.TreeEntry.init(.regular_file, try allocator.dupe(u8, "README.md"), try allocator.dupe(u8, "a" ** 40)),
        tree_utils.TreeEntry.init(.directory, try allocator.dupe(u8, "src"), try allocator.dupe(u8, "b" ** 40)),
        tree_utils.TreeEntry.init(.executable_file, try allocator.dupe(u8, "build.sh"), try allocator.dupe(u8, "c" ** 40)),
    };
    defer {
        for (test_entries) |entry| {
            entry.deinit(allocator);
        }
    }
    
    const tree_obj = try tree_utils.createTreeObject(&test_entries, allocator);
    defer tree_obj.deinit(allocator);
    
    try testing.expectEqual(objects.ObjectType.tree, tree_obj.type);
    try testing.expect(tree_obj.data.len > 0);
    
    // Parse the tree back and verify
    const parsed_entries = try tree_utils.parseTreeObject(tree_obj.data, allocator);
    defer {
        for (parsed_entries) |entry| {
            entry.deinit(allocator);
        }
        allocator.free(parsed_entries);
    }
    
    try testing.expectEqual(@as(usize, 3), parsed_entries.len);
    
    // Test file collector
    var collector = tree_utils.FileCollector.init(allocator);
    defer collector.deinit();
    
    for (test_entries) |entry| {
        _ = try collector.visit(entry, entry.name);
    }
    
    const collected_files = collector.getFiles();
    try testing.expectEqual(@as(usize, 2), collected_files.len); // README.md and build.sh, not src (directory)
}

test "pack performance monitoring and caching" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    // Test pack file cache
    var cache = pack_perf.PackFileCache.init(allocator, 5, 1024);
    defer cache.deinit();
    
    // Test basic cache operations
    try cache.put("/pack1.pack", "test data 1");
    try cache.put("/pack2.pack", "test data 2 is longer");
    
    try testing.expectEqualStrings("test data 1", cache.get("/pack1.pack").?);
    try testing.expectEqualStrings("test data 2 is longer", cache.get("/pack2.pack").?);
    try testing.expect(cache.get("/nonexistent.pack") == null);
    
    // Test cache statistics
    const stats = cache.getStats();
    try testing.expectEqual(@as(usize, 2), stats.entry_count);
    try testing.expect(stats.total_size > 0);
    try testing.expect(stats.utilization() > 0.0);
    
    // Test performance monitor
    var monitor = pack_perf.PackPerformanceMonitor.init();
    
    monitor.recordPackRead(1024);
    monitor.recordPackRead(2048);
    monitor.recordCacheHit();
    monitor.recordCacheMiss();
    monitor.recordCacheMiss();
    
    try testing.expectEqual(@as(u64, 2), monitor.total_pack_reads);
    try testing.expectEqual(@as(u64, 3072), monitor.total_bytes_read);
    try testing.expectEqual(@as(f32, 1536.0), monitor.getAveragePackSize());
    
    const hit_rate = monitor.getCacheHitRate();
    try testing.expect(hit_rate > 0.0 and hit_rate < 1.0);
    
    // Test compression analyzer
    var analyzer = pack_perf.PackCompressionAnalyzer.init();
    
    analyzer.recordObject(1000, 400);  // 60% compression
    analyzer.recordObject(2000, 800);  // 60% compression
    
    try testing.expectEqual(@as(u64, 2), analyzer.object_count);
    try testing.expectEqual(@as(u64, 3000), analyzer.total_uncompressed);
    try testing.expectEqual(@as(u64, 1200), analyzer.total_compressed);
    
    const compression_ratio = analyzer.getCompressionRatio();
    try testing.expectApproxEqAbs(@as(f32, 0.4), compression_ratio, 0.01);
    
    const savings = analyzer.getSpaceSavings();
    try testing.expectEqual(@as(u64, 1800), savings);
}

test "integrated workflow simulation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    // This test simulates a complete git workflow using all the core components
    
    // 1. Setup configuration
    const config_content =
        \\[core]
        \\	repositoryformatversion = 0
        \\	filemode = true
        \\[user]
        \\	name = Integration Test
        \\	email = test@ziggit.com
        \\[remote "origin"]
        \\	url = https://github.com/test/repo.git
    ;
    
    var git_config = try config.GitConfig.parseConfig(allocator, config_content);
    defer git_config.deinit();
    
    try testing.expectEqualStrings("Integration Test", git_config.getUserName().?);
    try testing.expectEqualStrings("https://github.com/test/repo.git", git_config.getRemoteUrl("origin").?);
    
    // 2. Create some git objects
    const file_content = "# Test Repository\n\nThis is a test repository for ziggit integration.\n";
    const blob = try objects.createBlobObject(file_content, allocator);
    defer blob.deinit(allocator);
    
    const blob_hash = try blob.hash(allocator);
    defer allocator.free(blob_hash);
    
    // 3. Test tree utilities
    const tree_entries = [_]tree_utils.TreeEntry{
        tree_utils.TreeEntry.init(.regular_file, try allocator.dupe(u8, "README.md"), try allocator.dupe(u8, blob_hash)),
    };
    defer {
        for (tree_entries) |entry| {
            entry.deinit(allocator);
        }
    }
    
    const tree_obj = try tree_utils.createTreeObject(&tree_entries, allocator);
    defer tree_obj.deinit(allocator);
    
    const tree_hash = try tree_obj.hash(allocator);
    defer allocator.free(tree_hash);
    
    // 4. Create a commit
    const commit = try objects.createCommitObject(
        tree_hash,
        &[_][]const u8{}, // No parents (initial commit)
        "Integration Test <test@ziggit.com> 1234567890 +0000",
        "Integration Test <test@ziggit.com> 1234567890 +0000",
        "Initial commit\n\nAdded README.md file.",
        allocator,
    );
    defer commit.deinit(allocator);
    
    const commit_hash = try commit.hash(allocator);
    defer allocator.free(commit_hash);
    
    // 5. Test pack performance monitoring
    var monitor = pack_perf.PackPerformanceMonitor.init();
    monitor.recordPackRead(blob.data.len);
    monitor.recordPackRead(tree_obj.data.len);
    monitor.recordPackRead(commit.data.len);
    
    try testing.expectEqual(@as(u64, 3), monitor.total_pack_reads);
    try testing.expect(monitor.total_bytes_read > 0);
    
    // 6. Verify all components work together
    try testing.expect(blob_hash.len == 40);
    try testing.expect(tree_hash.len == 40);
    try testing.expect(commit_hash.len == 40);
    
    // All hashes should be different
    try testing.expect(!std.mem.eql(u8, blob_hash, tree_hash));
    try testing.expect(!std.mem.eql(u8, tree_hash, commit_hash));
    try testing.expect(!std.mem.eql(u8, blob_hash, commit_hash));
}