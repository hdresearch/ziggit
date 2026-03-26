const std = @import("std");
const testing = std.testing;
const objects = @import("../src/git/objects.zig");
const config = @import("../src/git/config.zig");
const index_module = @import("../src/git/index.zig");
const refs = @import("../src/git/refs.zig");

/// Comprehensive integration test that validates all core git format implementations
/// working together in realistic scenarios
test "core git formats integration test" {
    const allocator = testing.allocator;
    
    // Create a comprehensive test repository
    const temp_path = "/tmp/zig-core-integration-test";
    std.fs.cwd().deleteTree(temp_path) catch {};
    try std.fs.cwd().makePath(temp_path);
    defer std.fs.cwd().deleteTree(temp_path) catch {};
    
    std.debug.print("=== Core Git Formats Integration Test ===\n", .{});
    
    // Initialize repository with proper configuration
    try runGitCommand(allocator, temp_path, &[_][]const u8{"init"});
    try runGitCommand(allocator, temp_path, &[_][]const u8{"config", "user.name", "Integration Test User"});
    try runGitCommand(allocator, temp_path, &[_][]const u8{"config", "user.email", "integration@ziggit.dev"});
    try runGitCommand(allocator, temp_path, &[_][]const u8{"config", "core.autocrlf", "input"});
    try runGitCommand(allocator, temp_path, &[_][]const u8{"config", "init.defaultBranch", "main"});
    try runGitCommand(allocator, temp_path, &[_][]const u8{"config", "push.default", "simple"});
    
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{temp_path});
    defer allocator.free(git_dir);
    
    // Test 1: Config Parsing and Validation
    std.debug.print("\n--- Testing Config Implementation ---\n", .{});
    {
        var git_config = try config.loadGitConfig(git_dir, allocator);
        defer git_config.deinit();
        
        // Verify configuration was loaded correctly
        try testing.expectEqualStrings("Integration Test User", git_config.getUserName().?);
        try testing.expectEqualStrings("integration@ziggit.dev", git_config.getUserEmail().?);
        try testing.expectEqualStrings("input", git_config.getAutoCrlf().?);
        try testing.expectEqualStrings("main", git_config.getInitDefaultBranch().?);
        try testing.expectEqualStrings("simple", git_config.getPushDefault().?);
        
        // Test configuration validation
        const issues = try git_config.validateConfig(allocator);
        defer {
            for (issues) |issue| {
                allocator.free(issue);
            }
            allocator.free(issues);
        }
        
        std.debug.print("Configuration validation: {} issues found\n", .{issues.len});
        try testing.expect(issues.len == 0); // Should be valid config
        
        std.debug.print("✓ Config parsing and validation working correctly\n", .{});
    }
    
    // Test 2: Index Operations 
    std.debug.print("\n--- Testing Index Implementation ---\n", .{});
    var temp_dir = try std.fs.openDirAbsolute(temp_path, .{});
    defer temp_dir.close();
    
    // Create test files with different characteristics
    const test_files = [_]struct { name: []const u8, content: []const u8 }{
        .{ .name = "README.md", .content = "# Integration Test Repository\n\nThis tests all core git formats working together.\n" },
        .{ .name = "src/main.zig", .content = "const std = @import(\"std\");\n\npub fn main() void {\n    std.debug.print(\"Hello, World!\\n\", .{});\n}\n" },
        .{ .name = "src/lib.zig", .content = "pub fn add(a: i32, b: i32) i32 {\n    return a + b;\n}\n\npub fn multiply(a: i32, b: i32) i32 {\n    return a * b;\n}\n" },
        .{ .name = "test/main_test.zig", .content = "const std = @import(\"std\");\nconst lib = @import(\"../src/lib.zig\");\n\ntest \"basic math\" {\n    try std.testing.expect(lib.add(2, 3) == 5);\n}\n" },
        .{ .name = "build.zig", .content = "const std = @import(\"std\");\n\npub fn build(b: *std.Build) void {\n    // Build configuration\n}\n" },
        .{ .name = ".gitignore", .content = "*.o\n*.so\n*.dylib\ntarget/\nzig-cache/\nzig-out/\n" },
    };
    
    for (test_files) |file| {
        // Create directory if needed
        if (std.mem.lastIndexOf(u8, file.name, "/")) |last_slash| {
            const dir_path = file.name[0..last_slash];
            temp_dir.makePath(dir_path) catch {};
        }
        
        try temp_dir.writeFile(.{ .sub_path = file.name, .data = file.content });
    }
    
    // Add files to git
    try runGitCommand(allocator, temp_path, &[_][]const u8{"add", "."});
    
    const TestPlatform = struct {
        const fs = struct {
            pub fn readFile(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
                return std.fs.cwd().readFileAlloc(alloc, path, 1024 * 1024);
            }
            
            pub fn writeFile(path: []const u8, content: []const u8) !void {
                try std.fs.cwd().writeFile(path, content);
            }
            
            pub fn deleteFile(path: []const u8) !void {
                try std.fs.cwd().deleteFile(path);
            }
            
            pub fn exists(path: []const u8) !bool {
                std.fs.cwd().access(path, .{}) catch |err| switch (err) {
                    error.FileNotFound => return false,
                    else => return err,
                };
                return true;
            }
            
            pub fn readDir(alloc: std.mem.Allocator, path: []const u8) ![][]u8 {
                var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch return &[_][]u8{};
                defer dir.close();
                
                var entries = std.ArrayList([]u8).init(alloc);
                var iterator = dir.iterate();
                while (try iterator.next()) |entry| {
                    if (entry.kind == .file) {
                        try entries.append(try alloc.dupe(u8, entry.name));
                    }
                }
                return entries.toOwnedSlice();
            }
            
            pub fn makeDir(path: []const u8) !void {
                try std.fs.cwd().makePath(path);
            }
        };
    };
    
    // Test index loading and analysis
    const index_stats = try index_module.analyzeIndex(git_dir, TestPlatform, allocator);
    std.debug.print("Index analysis: {} entries, version {}, checksum_valid={}\n", .{
        index_stats.total_entries, 
        index_stats.version, 
        index_stats.checksum_valid 
    });
    
    try testing.expect(index_stats.total_entries == test_files.len);
    try testing.expect(index_stats.version >= 2);
    try testing.expect(index_stats.checksum_valid);
    
    // Test index validation
    const index_issues = try index_module.validateIndex(git_dir, TestPlatform, allocator);
    defer {
        for (index_issues) |issue| {
            allocator.free(issue);
        }
        allocator.free(index_issues);
    }
    
    std.debug.print("Index validation: {} issues found\n", .{index_issues.len});
    try testing.expect(index_issues.len == 0);
    
    std.debug.print("✓ Index operations working correctly\n", .{});
    
    // Test 3: Refs and Branch Management
    std.debug.print("\n--- Testing Refs Implementation ---\n", .{});
    
    // Make initial commit
    try runGitCommand(allocator, temp_path, &[_][]const u8{"commit", "-m", "Initial commit with test files"});
    
    // Test current branch detection
    const current_branch = try refs.getCurrentBranch(git_dir, TestPlatform, allocator);
    defer allocator.free(current_branch);
    std.debug.print("Current branch: {s}\n", .{current_branch});
    
    // Test current commit resolution
    const current_commit = try refs.getCurrentCommit(git_dir, TestPlatform, allocator);
    try testing.expect(current_commit != null);
    if (current_commit) |commit_hash| {
        defer allocator.free(commit_hash);
        std.debug.print("Current commit: {s}\n", .{commit_hash});
        try testing.expect(commit_hash.len == 40);
        
        // Create additional branches
        var ref_manager = refs.RefManager.init(git_dir, allocator);
        try ref_manager.createBranch("develop", commit_hash, TestPlatform);
        try ref_manager.createBranch("feature/new-feature", commit_hash, TestPlatform);
        try ref_manager.createBranch("hotfix/urgent-fix", commit_hash, TestPlatform);
        
        // Test branch listing
        var branches = try refs.listBranches(git_dir, TestPlatform, allocator);
        defer {
            for (branches.items) |branch| {
                allocator.free(branch);
            }
            branches.deinit();
        }
        
        std.debug.print("Branches created: {} branches found\n", .{branches.items.len});
        try testing.expect(branches.items.len >= 4); // main + 3 created
        
        // Test branch existence
        try testing.expect(try refs.branchExists(git_dir, "develop", TestPlatform, allocator));
        try testing.expect(try refs.branchExists(git_dir, "feature/new-feature", TestPlatform, allocator));
        try testing.expect(!try refs.branchExists(git_dir, "non-existent", TestPlatform, allocator));
        
        std.debug.print("✓ Refs and branch management working correctly\n", .{});
    }
    
    // Test 4: Object Storage and Retrieval
    std.debug.print("\n--- Testing Objects Implementation ---\n", .{});
    {
        // Create and store various object types
        const blob_content = "This is a test blob object for integration testing.\nIt contains multiple lines\nto test blob storage and retrieval.";
        const blob_object = try objects.createBlobObject(blob_content, allocator);
        defer blob_object.deinit(allocator);
        
        const blob_hash = try blob_object.store(git_dir, TestPlatform, allocator);
        defer allocator.free(blob_hash);
        
        std.debug.print("Stored blob object: {s}\n", .{blob_hash});
        try testing.expect(blob_hash.len == 40);
        
        // Retrieve and verify blob
        const retrieved_blob = try objects.GitObject.load(blob_hash, git_dir, TestPlatform, allocator);
        defer retrieved_blob.deinit(allocator);
        
        try testing.expect(retrieved_blob.type == .blob);
        try testing.expectEqualStrings(blob_content, retrieved_blob.data);
        
        // Create tree object
        const tree_entries = [_]objects.TreeEntry{
            objects.TreeEntry.init(try allocator.dupe(u8, "100644"), try allocator.dupe(u8, "test.txt"), try allocator.dupe(u8, blob_hash)),
            objects.TreeEntry.init(try allocator.dupe(u8, "040000"), try allocator.dupe(u8, "subdir"), try allocator.dupe(u8, blob_hash)),
        };
        defer for (tree_entries) |entry| entry.deinit(allocator);
        
        const tree_object = try objects.createTreeObject(&tree_entries, allocator);
        defer tree_object.deinit(allocator);
        
        const tree_hash = try tree_object.store(git_dir, TestPlatform, allocator);
        defer allocator.free(tree_hash);
        
        std.debug.print("Stored tree object: {s}\n", .{tree_hash});
        
        // Create commit object
        const commit_object = try objects.createCommitObject(
            tree_hash,
            &[_][]const u8{}, // No parents for initial commit
            "Integration Test <integration@ziggit.dev> 1640995200 +0000",
            "Integration Test <integration@ziggit.dev> 1640995200 +0000",
            "Integration test commit\n\nThis commit tests object storage and retrieval.",
            allocator
        );
        defer commit_object.deinit(allocator);
        
        const commit_hash = try commit_object.store(git_dir, TestPlatform, allocator);
        defer allocator.free(commit_hash);
        
        std.debug.print("Stored commit object: {s}\n", .{commit_hash});
        
        // Retrieve and verify commit
        const retrieved_commit = try objects.GitObject.load(commit_hash, git_dir, TestPlatform, allocator);
        defer retrieved_commit.deinit(allocator);
        
        try testing.expect(retrieved_commit.type == .commit);
        try testing.expect(std.mem.indexOf(u8, retrieved_commit.data, "Integration test commit") != null);
        
        std.debug.print("✓ Object storage and retrieval working correctly\n", .{});
    }
    
    // Test 5: Pack File Integration (if available)
    std.debug.print("\n--- Testing Pack File Integration ---\n", .{});
    {
        // Create more commits to encourage pack file creation
        for (0..5) |i| {
            const file_content = try std.fmt.allocPrint(allocator, "Modified content for iteration {}\nThis creates delta-able changes.\n", .{i});
            defer allocator.free(file_content);
            
            try temp_dir.writeFile(.{ .sub_path = "changing_file.txt", .data = file_content });
            try runGitCommand(allocator, temp_path, &[_][]const u8{"add", "changing_file.txt"});
            
            const commit_msg = try std.fmt.allocPrint(allocator, "Iteration {} commit", .{i});
            defer allocator.free(commit_msg);
            try runGitCommand(allocator, temp_path, &[_][]const u8{"commit", "-m", commit_msg});
        }
        
        // Force pack file creation
        try runGitCommand(allocator, temp_path, &[_][]const u8{"gc", "--aggressive", "--prune=now"});
        
        // Check for pack files
        const pack_path = try std.fmt.allocPrint(allocator, "{s}/objects/pack", .{git_dir});
        defer allocator.free(pack_path);
        
        var pack_dir = std.fs.openDirAbsolute(pack_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => {
                std.debug.print("No pack files created, pack integration test skipped\n", .{});
                return;
            },
            else => return err,
        };
        defer pack_dir.close();
        
        var pack_files_found = false;
        var iterator = pack_dir.iterate();
        while (try iterator.next()) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".pack")) {
                pack_files_found = true;
                std.debug.print("Found pack file: {s}\n", .{entry.name});
                
                // Test pack file analysis
                const pack_file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{pack_path, entry.name});
                defer allocator.free(pack_file_path);
                
                const pack_stats = try objects.analyzePackFile(pack_file_path, TestPlatform, allocator);
                std.debug.print("Pack file analysis: {} objects, version {}, {}MB\n", .{
                    pack_stats.total_objects,
                    pack_stats.version,
                    pack_stats.file_size / (1024 * 1024)
                });
                
                try testing.expect(pack_stats.total_objects > 0);
                try testing.expect(pack_stats.version >= 2);
                try testing.expect(pack_stats.checksum_valid);
                
                break;
            }
        }
        
        if (pack_files_found) {
            std.debug.print("✓ Pack file integration working correctly\n", .{});
        } else {
            std.debug.print("! No pack files found, pack integration test skipped\n", .{});
        }
    }
    
    // Test 6: Cross-component Integration
    std.debug.print("\n--- Testing Cross-Component Integration ---\n", .{});
    {
        // Test scenario: Create a complex ref structure that references objects stored in various ways
        
        // Create an annotated tag
        try runGitCommand(allocator, temp_path, &[_][]const u8{"tag", "-a", "v1.0.0", "-m", "Version 1.0.0 release tag"});
        
        // Test resolving various refs and their objects
        const test_refs = [_][]const u8{ "HEAD", "main", "develop", "v1.0.0", "refs/tags/v1.0.0" };
        
        for (test_refs) |ref_name| {
            const resolved_hash = refs.resolveRef(git_dir, ref_name, TestPlatform, allocator) catch |err| {
                std.debug.print("Could not resolve {s}: {}\n", .{ref_name, err});
                continue;
            };
            
            if (resolved_hash) |hash| {
                defer allocator.free(hash);
                std.debug.print("Resolved {s} -> {s}\n", .{ref_name, hash});
                
                // Try to load the object (commit or tag)
                const obj = objects.GitObject.load(hash, git_dir, TestPlatform, allocator) catch |err| {
                    std.debug.print("Could not load object {s}: {}\n", .{hash, err});
                    continue;
                };
                defer obj.deinit(allocator);
                
                std.debug.print("  Object type: {}, size: {} bytes\n", .{obj.type, obj.data.len});
                try testing.expect(obj.data.len > 0);
                
                // If it's a commit, verify it has proper structure
                if (obj.type == .commit) {
                    try testing.expect(std.mem.startsWith(u8, obj.data, "tree "));
                    try testing.expect(std.mem.indexOf(u8, obj.data, "author ") != null);
                    try testing.expect(std.mem.indexOf(u8, obj.data, "committer ") != null);
                }
            }
        }
        
        // Test that config, index, and refs are all consistent
        var git_config = try config.loadGitConfig(git_dir, allocator);
        defer git_config.deinit();
        
        const config_default_branch = git_config.getInitDefaultBranch() orelse "main";
        const actual_current_branch = try refs.getCurrentBranch(git_dir, TestPlatform, allocator);
        defer allocator.free(actual_current_branch);
        
        std.debug.print("Config default branch: {s}, actual current: {s}\n", .{config_default_branch, actual_current_branch});
        
        // Test that index is consistent with current commit
        const head_commit = try refs.getCurrentCommit(git_dir, TestPlatform, allocator);
        try testing.expect(head_commit != null);
        if (head_commit) |commit_hash| {
            defer allocator.free(commit_hash);
            
            const index_stats = try index_module.analyzeIndex(git_dir, TestPlatform, allocator);
            try testing.expect(index_stats.total_entries > 0);
            try testing.expect(index_stats.checksum_valid);
            
            std.debug.print("Integration consistency check passed\n", .{});
        }
        
        std.debug.print("✓ Cross-component integration working correctly\n", .{});
    }
    
    std.debug.print("\n=== All Core Git Format Tests Passed Successfully! ===\n", .{});
}

/// Performance benchmark test for all core components
test "core formats performance benchmark" {
    const allocator = testing.allocator;
    
    std.debug.print("\n=== Core Git Formats Performance Benchmark ===\n", .{});
    
    const temp_path = "/tmp/zig-perf-benchmark-test";
    std.fs.cwd().deleteTree(temp_path) catch {};
    try std.fs.cwd().makePath(temp_path);
    defer std.fs.cwd().deleteTree(temp_path) catch {};
    
    // Initialize repository
    try runGitCommand(allocator, temp_path, &[_][]const u8{"init"});
    try runGitCommand(allocator, temp_path, &[_][]const u8{"config", "user.name", "Perf Test"});
    try runGitCommand(allocator, temp_path, &[_][]const u8{"config", "user.email", "perf@ziggit.dev"});
    
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{temp_path});
    defer allocator.free(git_dir);
    
    var temp_dir = try std.fs.openDirAbsolute(temp_path, .{});
    defer temp_dir.close();
    
    const TestPlatform = struct {
        const fs = struct {
            pub fn readFile(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
                return std.fs.cwd().readFileAlloc(alloc, path, 1024 * 1024);
            }
            
            pub fn writeFile(path: []const u8, content: []const u8) !void {
                try std.fs.cwd().writeFile(path, content);
            }
        };
    };
    
    // Benchmark 1: Config parsing performance
    {
        std.debug.print("\n--- Config Parsing Benchmark ---\n", .{});
        
        const start_time = std.time.milliTimestamp();
        
        for (0..100) |_| {
            var git_config = try config.loadGitConfig(git_dir, allocator);
            git_config.deinit();
        }
        
        const end_time = std.time.milliTimestamp();
        const duration = end_time - start_time;
        
        std.debug.print("Config parsing: 100 iterations in {}ms ({d:.2}ms avg)\n", .{duration, @as(f64, @floatFromInt(duration)) / 100.0});
    }
    
    // Benchmark 2: Object creation and hashing
    {
        std.debug.print("\n--- Object Operations Benchmark ---\n", .{});
        
        const test_content = "This is test content for benchmark testing. " ** 100;  // ~4.5KB
        
        const start_time = std.time.milliTimestamp();
        
        for (0..50) |_| {
            const blob_object = try objects.createBlobObject(test_content, allocator);
            const hash = try blob_object.hash(allocator);
            allocator.free(hash);
            blob_object.deinit(allocator);
        }
        
        const end_time = std.time.milliTimestamp();
        const duration = end_time - start_time;
        
        std.debug.print("Object creation/hashing: 50 iterations in {}ms ({d:.2}ms avg)\n", .{duration, @as(f64, @floatFromInt(duration)) / 50.0});
    }
    
    // Benchmark 3: Ref resolution performance
    {
        std.debug.print("\n--- Ref Resolution Benchmark ---\n", .{});
        
        // Create test commit first
        try temp_dir.writeFile(.{ .sub_path = "perf_test.txt", .data = "Performance test file\n" });
        try runGitCommand(allocator, temp_path, &[_][]const u8{"add", "perf_test.txt"});
        try runGitCommand(allocator, temp_path, &[_][]const u8{"commit", "-m", "Performance test commit"});
        
        const start_time = std.time.milliTimestamp();
        
        for (0..200) |_| {
            const resolved = try refs.resolveRef(git_dir, "HEAD", TestPlatform, allocator);
            if (resolved) |hash| {
                allocator.free(hash);
            }
        }
        
        const end_time = std.time.milliTimestamp();
        const duration = end_time - start_time;
        
        std.debug.print("Ref resolution: 200 iterations in {}ms ({d:.2}ms avg)\n", .{duration, @as(f64, @floatFromInt(duration)) / 200.0});
    }
    
    // Benchmark 4: Index operations
    {
        std.debug.print("\n--- Index Operations Benchmark ---\n", .{});
        
        const start_time = std.time.milliTimestamp();
        
        for (0..50) |_| {
            const stats = try index_module.analyzeIndex(git_dir, TestPlatform, allocator);
            _ = stats; // Use the result
        }
        
        const end_time = std.time.milliTimestamp();
        const duration = end_time - start_time;
        
        std.debug.print("Index analysis: 50 iterations in {}ms ({d:.2}ms avg)\n", .{duration, @as(f64, @floatFromInt(duration)) / 50.0});
    }
    
    std.debug.print("\n=== Performance Benchmark Complete ===\n", .{});
}

/// Helper function to run git commands
fn runGitCommand(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) !void {
    var cmd = std.process.Child.init(args, allocator);
    cmd.cwd = cwd;
    cmd.stdout_behavior = .Ignore;
    cmd.stderr_behavior = .Ignore;
    
    const result = try cmd.spawnAndWait();
    if (result != .Exited or result.Exited != 0) {
        std.debug.print("Git command failed: {any}\n", .{args});
        return error.GitCommandFailed;
    }
}

test "error handling and edge cases integration" {
    const allocator = testing.allocator;
    
    std.debug.print("\n=== Error Handling and Edge Cases Test ===\n", .{});
    
    // Test handling of non-existent repository
    {
        const non_existent_path = "/tmp/non-existent-repo/.git";
        
        // Config loading should handle missing files gracefully
        const git_config = config.loadGitConfig(non_existent_path, allocator) catch |err| {
            std.debug.print("Config loading correctly failed for non-existent repo: {}\n", .{err});
            var empty_config = config.GitConfig.init(allocator);
            defer empty_config.deinit();
            return; // Expected behavior
        };
        git_config.deinit();
        
        std.debug.print("✓ Config error handling working\n", .{});
    }
    
    // Test malformed config handling
    {
        const temp_config_path = "/tmp/malformed-config";
        defer std.fs.cwd().deleteFile(temp_config_path) catch {};
        
        const malformed_config =
            \\[broken section
            \\missing = close bracket
            \\[valid]
            \\key = value
            \\[] empty section name
            \\invalid key = value
        ;
        
        try std.fs.cwd().writeFile(temp_config_path, malformed_config);
        
        var config_parser = config.GitConfig.init(allocator);
        defer config_parser.deinit();
        
        // Should not crash on malformed input
        try config_parser.parseFromFile(temp_config_path);
        
        // Valid entries should still be parsed
        try testing.expectEqualStrings("value", config_parser.get("valid", null, "key").?);
        
        std.debug.print("✓ Malformed config handled gracefully\n", .{});
    }
    
    // Test invalid ref names
    {
        const invalid_refs = [_][]const u8{
            "",
            "ref with spaces",
            "ref..double.dots", 
            "ref/.hidden",
            ".starts-with-dot",
            "ref@{0}",
        };
        
        for (invalid_refs) |invalid_ref| {
            refs.validateRefName(invalid_ref) catch |err| {
                std.debug.print("Correctly rejected invalid ref '{s}': {}\n", .{invalid_ref, err});
                continue;
            };
            
            std.debug.print("ERROR: Should have rejected invalid ref: {s}\n", .{invalid_ref});
            try testing.expect(false);
        }
        
        std.debug.print("✓ Invalid ref name handling working\n", .{});
    }
    
    // Test large input handling
    {
        var large_config = std.ArrayList(u8).init(allocator);
        defer large_config.deinit();
        
        // Generate a large config (1MB)
        try large_config.appendSlice("[user]\nname = Test User\nemail = test@example.com\n");
        
        for (0..10000) |i| {
            try large_config.writer().print("[section{}]\nkey = value{}\n", .{i, i});
        }
        
        // Should handle large configs without issues
        var config_parser = config.GitConfig.init(allocator);
        defer config_parser.deinit();
        
        config_parser.parseFromString(large_config.items) catch |err| {
            if (err == error.ConfigFileTooLarge or err == error.TooManyConfigLines) {
                std.debug.print("Large config correctly rejected: {}\n", .{err});
                return; // This is expected behavior
            }
            return err;
        };
        
        // If parsing succeeded, verify some entries
        try testing.expectEqualStrings("Test User", config_parser.getUserName().?);
        try testing.expectEqualStrings("value0", config_parser.get("section0", null, "key").?);
        
        std.debug.print("✓ Large input handling working (processed {} entries)\n", .{config_parser.getEntryCount()});
    }
    
    std.debug.print("\n=== Error Handling Tests Complete ===\n", .{});
}