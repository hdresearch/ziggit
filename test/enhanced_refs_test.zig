const std = @import("std");
const testing = std.testing;
const refs = @import("../src/git/refs.zig");

test "advanced symbolic ref resolution with nested refs" {
    const allocator = testing.allocator;
    
    // Create a temporary test repository with complex ref structure
    const temp_path = "/tmp/zig-refs-nested-test";
    std.fs.cwd().deleteTree(temp_path) catch {};
    try std.fs.cwd().makePath(temp_path);
    defer std.fs.cwd().deleteTree(temp_path) catch {};
    
    // Initialize git repo
    try runGitCommand(allocator, temp_path, &[_][]const u8{"init"});
    try runGitCommand(allocator, temp_path, &[_][]const u8{"config", "user.name", "Refs Test User"});
    try runGitCommand(allocator, temp_path, &[_][]const u8{"config", "user.email", "refstest@ziggit.dev"});
    
    // Create test files and commits
    var temp_dir = try std.fs.openDirAbsolute(temp_path, .{});
    defer temp_dir.close();
    
    try temp_dir.writeFile(.{ .sub_path = "test.txt", .data = "Initial content\n" });
    try runGitCommand(allocator, temp_path, &[_][]const u8{"add", "test.txt"});
    try runGitCommand(allocator, temp_path, &[_][]const u8{"commit", "-m", "Initial commit"});
    
    // Create additional branches and tags
    try runGitCommand(allocator, temp_path, &[_][]const u8{"branch", "feature"});
    try runGitCommand(allocator, temp_path, &[_][]const u8{"branch", "develop"});
    try runGitCommand(allocator, temp_path, &[_][]const u8{"tag", "v1.0"});
    try runGitCommand(allocator, temp_path, &[_][]const u8{"tag", "-a", "v1.0-annotated", "-m", "Version 1.0 release"});
    
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{temp_path});
    defer allocator.free(git_dir);
    
    // Create complex symbolic ref structure manually
    const refs_dir = try std.fmt.allocPrint(allocator, "{s}/refs", .{git_dir});
    defer allocator.free(refs_dir);
    
    const heads_dir = try std.fmt.allocPrint(allocator, "{s}/heads", .{refs_dir});
    defer allocator.free(heads_dir);
    
    // Create a chain of symbolic refs: alias -> feature -> master
    try temp_dir.writeFile(.{
        .sub_path = ".git/refs/heads/alias",
        .data = "ref: refs/heads/feature\n"
    });
    
    // Update feature to point to master/main
    const main_exists = std.fs.cwd().access(try std.fmt.allocPrint(allocator, "{s}/refs/heads/main", .{git_dir}), .{}) catch false;
    const master_exists = std.fs.cwd().access(try std.fmt.allocPrint(allocator, "{s}/refs/heads/master", .{git_dir}), .{}) catch false;
    
    const default_branch = if (main_exists) "main" else if (master_exists) "master" else "main";
    
    const feature_ref_content = try std.fmt.allocPrint(allocator, "ref: refs/heads/{s}\n", .{default_branch});
    defer allocator.free(feature_ref_content);
    
    try temp_dir.writeFile(.{
        .sub_path = ".git/refs/heads/feature",
        .data = feature_ref_content
    });
    
    const TestPlatform = struct {
        const fs = struct {
            pub fn readFile(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
                return std.fs.cwd().readFileAlloc(alloc, path, 1024 * 1024);
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
        };
    };
    
    // Test resolving the chain of symbolic refs
    const resolved_alias = try refs.resolveRef(git_dir, "refs/heads/alias", TestPlatform, allocator);
    try testing.expect(resolved_alias != null);
    
    if (resolved_alias) |hash| {
        defer allocator.free(hash);
        try testing.expect(hash.len == 40);
        std.debug.print("Resolved alias -> feature -> {s} to: {s}\n", .{ default_branch, hash });
    }
    
    // Test resolving various ref formats
    const test_refs = [_][]const u8{
        "HEAD",
        "alias",
        "refs/heads/alias", 
        "feature",
        "refs/heads/feature",
        default_branch,
        "v1.0",
        "refs/tags/v1.0",
        "v1.0-annotated",
        "refs/tags/v1.0-annotated",
    };
    
    for (test_refs) |ref_name| {
        const resolved = refs.resolveRef(git_dir, ref_name, TestPlatform, allocator) catch |err| {
            std.debug.print("Failed to resolve {s}: {}\n", .{ ref_name, err });
            continue;
        };
        
        if (resolved) |hash| {
            defer allocator.free(hash);
            std.debug.print("Resolved {s} to: {s}\n", .{ ref_name, hash });
            try testing.expect(hash.len == 40);
        } else {
            std.debug.print("Could not resolve ref: {s}\n", .{ref_name});
        }
    }
    
    std.debug.print("Advanced symbolic ref resolution test completed successfully\n", .{});
}

test "ref manager operations and branch management" {
    const allocator = testing.allocator;
    
    // Create a temporary repository
    const temp_path = "/tmp/zig-ref-manager-test";
    std.fs.cwd().deleteTree(temp_path) catch {};
    try std.fs.cwd().makePath(temp_path);
    defer std.fs.cwd().deleteTree(temp_path) catch {};
    
    try runGitCommand(allocator, temp_path, &[_][]const u8{"init"});
    try runGitCommand(allocator, temp_path, &[_][]const u8{"config", "user.name", "Ref Manager Test"});
    try runGitCommand(allocator, temp_path, &[_][]const u8{"config", "user.email", "refmgr@ziggit.dev"});
    
    var temp_dir = try std.fs.openDirAbsolute(temp_path, .{});
    defer temp_dir.close();
    
    // Create initial commit
    try temp_dir.writeFile(.{ .sub_path = "README.md", .data = "# Ref Manager Test\n" });
    try runGitCommand(allocator, temp_path, &[_][]const u8{"add", "README.md"});
    try runGitCommand(allocator, temp_path, &[_][]const u8{"commit", "-m", "Initial commit"});
    
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{temp_path});
    defer allocator.free(git_dir);
    
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
        };
    };
    
    var ref_manager = refs.RefManager.init(git_dir, allocator);
    
    // Get current commit hash for branch creation
    const current_commit = try refs.getCurrentCommit(git_dir, TestPlatform, allocator);
    try testing.expect(current_commit != null);
    
    if (current_commit) |commit_hash| {
        defer allocator.free(commit_hash);
        
        // Test creating new branches
        try ref_manager.createBranch("feature-1", commit_hash, TestPlatform);
        try ref_manager.createBranch("feature-2", commit_hash, TestPlatform);
        try ref_manager.createBranch("hotfix", commit_hash, TestPlatform);
        
        // Verify branches were created
        try testing.expect(try refs.branchExists(git_dir, "feature-1", TestPlatform, allocator));
        try testing.expect(try refs.branchExists(git_dir, "feature-2", TestPlatform, allocator));
        try testing.expect(try refs.branchExists(git_dir, "hotfix", TestPlatform, allocator));
        
        // Test branch existence check for non-existent branch
        try testing.expect(!try refs.branchExists(git_dir, "non-existent", TestPlatform, allocator));
        
        // Test getting ref info
        const feature1_info = try ref_manager.getRefInfo("refs/heads/feature-1", TestPlatform);
        defer feature1_info.deinit(allocator);
        
        try testing.expectEqualStrings("refs/heads/feature-1", feature1_info.name);
        try testing.expectEqualStrings(commit_hash, feature1_info.hash);
        try testing.expect(feature1_info.ref_type == .branch);
        try testing.expect(!feature1_info.is_symbolic);
        
        // Test checkout (change HEAD)
        try ref_manager.checkoutBranch("feature-1", TestPlatform);
        
        const current_branch = try refs.getCurrentBranch(git_dir, TestPlatform, allocator);
        defer allocator.free(current_branch);
        try testing.expectEqualStrings("feature-1", current_branch);
        
        // Test deleting a branch (switch back to main first)
        const default_branch = refs.getCurrentBranch(git_dir, TestPlatform, allocator) catch "main";
        defer allocator.free(default_branch);
        
        // Try to determine the original branch name
        const original_branch = if (try refs.branchExists(git_dir, "main", TestPlatform, allocator)) 
            "main" 
        else if (try refs.branchExists(git_dir, "master", TestPlatform, allocator))
            "master"
        else
            "main"; // fallback
        
        try ref_manager.checkoutBranch(original_branch, TestPlatform);
        try ref_manager.deleteBranch("hotfix", TestPlatform);
        
        // Verify branch was deleted
        try testing.expect(!try refs.branchExists(git_dir, "hotfix", TestPlatform, allocator));
        
        std.debug.print("Ref manager operations test completed successfully\n", .{});
    }
}

test "packed refs handling and performance" {
    const allocator = testing.allocator;
    
    // Create a repository with many refs to trigger packed-refs
    const temp_path = "/tmp/zig-packed-refs-test";
    std.fs.cwd().deleteTree(temp_path) catch {};
    try std.fs.cwd().makePath(temp_path);
    defer std.fs.cwd().deleteTree(temp_path) catch {};
    
    try runGitCommand(allocator, temp_path, &[_][]const u8{"init"});
    try runGitCommand(allocator, temp_path, &[_][]const u8{"config", "user.name", "Packed Refs Test"});
    try runGitCommand(allocator, temp_path, &[_][]const u8{"config", "user.email", "packed@ziggit.dev"});
    
    var temp_dir = try std.fs.openDirAbsolute(temp_path, .{});
    defer temp_dir.close();
    
    // Create initial commit
    try temp_dir.writeFile(.{ .sub_path = "file.txt", .data = "content\n" });
    try runGitCommand(allocator, temp_path, &[_][]const u8{"add", "file.txt"});
    try runGitCommand(allocator, temp_path, &[_][]const u8{"commit", "-m", "Initial commit"});
    
    // Create many branches and tags to fill the refs
    const num_refs = 20;
    for (0..num_refs) |i| {
        const branch_name = try std.fmt.allocPrint(allocator, "branch-{:03}", .{i});
        defer allocator.free(branch_name);
        
        const tag_name = try std.fmt.allocPrint(allocator, "tag-{:03}", .{i});
        defer allocator.free(tag_name);
        
        try runGitCommand(allocator, temp_path, &[_][]const u8{ "branch", branch_name });
        try runGitCommand(allocator, temp_path, &[_][]const u8{ "tag", tag_name });
    }
    
    // Pack the refs
    try runGitCommand(allocator, temp_path, &[_][]const u8{"pack-refs", "--all"});
    
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{temp_path});
    defer allocator.free(git_dir);
    
    // Check if packed-refs file was created
    const packed_refs_path = try std.fmt.allocPrint(allocator, "{s}/packed-refs", .{git_dir});
    defer allocator.free(packed_refs_path);
    
    const packed_refs_exists = (std.fs.cwd().access(packed_refs_path, .{}) catch false);
    if (!packed_refs_exists) {
        std.debug.print("Packed-refs file not created, skipping packed refs test\n", .{});
        return;
    }
    
    const TestPlatform = struct {
        const fs = struct {
            pub fn readFile(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
                return std.fs.cwd().readFileAlloc(alloc, path, 1024 * 1024);
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
        };
    };
    
    // Test performance of packed refs lookups
    const start_time = std.time.milliTimestamp();
    
    // Look up all the created refs
    for (0..num_refs) |i| {
        const branch_name = try std.fmt.allocPrint(allocator, "branch-{:03}", .{i});
        defer allocator.free(branch_name);
        
        const tag_name = try std.fmt.allocPrint(allocator, "tag-{:03}", .{i});
        defer allocator.free(tag_name);
        
        const branch_hash = try refs.resolveRef(git_dir, branch_name, TestPlatform, allocator);
        const tag_hash = try refs.resolveRef(git_dir, tag_name, TestPlatform, allocator);
        
        try testing.expect(branch_hash != null);
        try testing.expect(tag_hash != null);
        
        if (branch_hash) |hash| allocator.free(hash);
        if (tag_hash) |hash| allocator.free(hash);
    }
    
    const lookup_time = std.time.milliTimestamp() - start_time;
    
    // Test batch resolution performance
    var ref_names = std.ArrayList([]const u8).init(allocator);
    defer ref_names.deinit();
    
    for (0..num_refs) |i| {
        const branch_name = try std.fmt.allocPrint(allocator, "branch-{:03}", .{i});
        try ref_names.append(branch_name);
    }
    defer {
        for (ref_names.items) |name| {
            allocator.free(@constCast(name));
        }
    }
    
    const batch_start_time = std.time.milliTimestamp();
    const batch_results = try refs.resolveRefs(git_dir, ref_names.items, TestPlatform, allocator);
    const batch_time = std.time.milliTimestamp() - batch_start_time;
    
    defer {
        for (batch_results) |result| {
            if (result) |hash| allocator.free(hash);
        }
        allocator.free(batch_results);
    }
    
    // Verify all batch results
    for (batch_results) |result| {
        try testing.expect(result != null);
        if (result) |hash| {
            try testing.expect(hash.len == 40);
        }
    }
    
    std.debug.print("Packed refs performance test results:\n", .{});
    std.debug.print("  Refs tested: {}\n", .{num_refs * 2});
    std.debug.print("  Individual lookup time: {}ms\n", .{lookup_time});
    std.debug.print("  Batch lookup time: {}ms\n", .{batch_time});
    std.debug.print("  Speedup: {d:.2}x\n", .{@as(f64, @floatFromInt(lookup_time)) / @as(f64, @floatFromInt(batch_time))});
    
    // Test clearing cache
    refs.clearPackedRefsCache();
    
    std.debug.print("Packed refs handling test completed successfully\n", .{});
}

test "ref resolution caching and optimization" {
    const allocator = testing.allocator;
    
    const temp_path = "/tmp/zig-ref-caching-test";
    std.fs.cwd().deleteTree(temp_path) catch {};
    try std.fs.cwd().makePath(temp_path);
    defer std.fs.cwd().deleteTree(temp_path) catch {};
    
    try runGitCommand(allocator, temp_path, &[_][]const u8{"init"});
    try runGitCommand(allocator, temp_path, &[_][]const u8{"config", "user.name", "Caching Test"});
    try runGitCommand(allocator, temp_path, &[_][]const u8{"config", "user.email", "cache@ziggit.dev"});
    
    var temp_dir = try std.fs.openDirAbsolute(temp_path, .{});
    defer temp_dir.close();
    
    try temp_dir.writeFile(.{ .sub_path = "test.txt", .data = "test content\n" });
    try runGitCommand(allocator, temp_path, &[_][]const u8{"add", "test.txt"});
    try runGitCommand(allocator, temp_path, &[_][]const u8{"commit", "-m", "Test commit"});
    
    // Create some branches
    try runGitCommand(allocator, temp_path, &[_][]const u8{"branch", "feature-cache"});
    try runGitCommand(allocator, temp_path, &[_][]const u8{"branch", "develop-cache"});
    
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{temp_path});
    defer allocator.free(git_dir);
    
    const TestPlatform = struct {
        const fs = struct {
            pub fn readFile(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
                return std.fs.cwd().readFileAlloc(alloc, path, 1024 * 1024);
            }
        };
    };
    
    // Test RefResolver caching
    var resolver = refs.RefResolver.init(git_dir, allocator);
    defer resolver.deinit();
    
    // First resolution (cache miss)
    const start_time = std.time.milliTimestamp();
    const hash1 = try resolver.resolve("feature-cache", TestPlatform);
    const first_time = std.time.milliTimestamp() - start_time;
    
    // Second resolution (cache hit)
    const cached_start_time = std.time.milliTimestamp();
    const hash2 = try resolver.resolve("feature-cache", TestPlatform);
    const cached_time = std.time.milliTimestamp() - cached_start_time;
    
    try testing.expect(hash1 != null);
    try testing.expect(hash2 != null);
    
    if (hash1) |h1| {
        defer allocator.free(h1);
        if (hash2) |h2| {
            defer allocator.free(h2);
            try testing.expectEqualStrings(h1, h2);
        }
    }
    
    std.debug.print("Caching performance:\n", .{});
    std.debug.print("  First lookup: {}ms\n", .{first_time});
    std.debug.print("  Cached lookup: {}ms\n", .{cached_time});
    if (cached_time > 0) {
        std.debug.print("  Speedup: {d:.2}x\n", .{@as(f64, @floatFromInt(first_time)) / @as(f64, @floatFromInt(cached_time))});
    }
    
    // Test batch resolution
    const batch_refs = [_][]const u8{ "HEAD", "feature-cache", "develop-cache" };
    const batch_results = try resolver.resolveBatch(&batch_refs, TestPlatform);
    defer {
        for (batch_results) |result| {
            if (result) |hash| allocator.free(hash);
        }
        allocator.free(batch_results);
    }
    
    try testing.expect(batch_results.len == 3);
    for (batch_results) |result| {
        try testing.expect(result != null);
    }
    
    // Test cache statistics
    const cache_stats = resolver.getCacheStats();
    cache_stats.print();
    
    try testing.expect(cache_stats.entries > 0);
    try testing.expect(cache_stats.is_valid);
    
    std.debug.print("Ref resolution caching test completed successfully\n", .{});
}

test "advanced ref name expansion and suggestions" {
    const allocator = testing.allocator;
    
    const temp_path = "/tmp/zig-ref-expansion-test";
    std.fs.cwd().deleteTree(temp_path) catch {};
    try std.fs.cwd().makePath(temp_path);
    defer std.fs.cwd().deleteTree(temp_path) catch {};
    
    try runGitCommand(allocator, temp_path, &[_][]const u8{"init"});
    try runGitCommand(allocator, temp_path, &[_][]const u8{"config", "user.name", "Expansion Test"});
    try runGitCommand(allocator, temp_path, &[_][]const u8{"config", "user.email", "expansion@ziggit.dev"});
    
    var temp_dir = try std.fs.openDirAbsolute(temp_path, .{});
    defer temp_dir.close();
    
    try temp_dir.writeFile(.{ .sub_path = "expansion.txt", .data = "expansion test\n" });
    try runGitCommand(allocator, temp_path, &[_][]const u8{"add", "expansion.txt"});
    try runGitCommand(allocator, temp_path, &[_][]const u8{"commit", "-m", "Expansion test commit"});
    
    // Create branches and tags with similar names
    const ref_data = [_][]const u8{
        "feature-abc",
        "feature-abcd",
        "feature-xyz", 
        "develop-abc",
        "develop-xyz",
        "release-v1",
        "release-v2",
        "hotfix-123",
    };
    
    for (ref_data) |ref_name| {
        try runGitCommand(allocator, temp_path, &[_][]const u8{ "branch", ref_name });
        
        // Also create some tags
        const tag_name = try std.fmt.allocPrint(allocator, "tag-{s}", .{ref_name});
        defer allocator.free(tag_name);
        try runGitCommand(allocator, temp_path, &[_][]const u8{ "tag", tag_name });
    }
    
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{temp_path});
    defer allocator.free(git_dir);
    
    const TestPlatform = struct {
        const fs = struct {
            pub fn readFile(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
                return std.fs.cwd().readFileAlloc(alloc, path, 1024 * 1024);
            }
        };
    };
    
    // Test ref name expansion
    const expansion_tests = [_]struct {
        input: []const u8,
        should_find: bool,
    }{
        .{ .input = "feature-abc", .should_find = true },
        .{ .input = "develop-xyz", .should_find = true },
        .{ .input = "tag-feature-abc", .should_find = true },
        .{ .input = "non-existent", .should_find = false },
    };
    
    for (expansion_tests) |test_case| {
        const expanded = refs.expandRefName(git_dir, test_case.input, TestPlatform, allocator) catch null;
        
        if (test_case.should_find) {
            try testing.expect(expanded != null);
            if (expanded) |exp| {
                defer allocator.free(exp);
                std.debug.print("Expanded '{s}' to '{s}'\n", .{ test_case.input, exp });
                try testing.expect(exp.len > test_case.input.len);
            }
        } else {
            try testing.expect(expanded == null);
        }
    }
    
    // Test ref type detection
    const type_tests = [_]struct {
        ref_name: []const u8,
        expected_type: refs.RefType,
    }{
        .{ .ref_name = "HEAD", .expected_type = .head },
        .{ .ref_name = "refs/heads/feature-abc", .expected_type = .branch },
        .{ .ref_name = "refs/tags/v1.0", .expected_type = .tag },
        .{ .ref_name = "refs/remotes/origin/main", .expected_type = .remote },
        .{ .ref_name = "refs/notes/commits", .expected_type = .other },
    };
    
    for (type_tests) |test_case| {
        const detected_type = refs.getRefType(test_case.ref_name);
        try testing.expect(detected_type == test_case.expected_type);
        std.debug.print("'{s}' detected as type: {}\n", .{ test_case.ref_name, detected_type });
    }
    
    // Test short name extraction
    const short_name_tests = [_]struct {
        input: []const u8,
        expected: []const u8,
    }{
        .{ .input = "refs/heads/feature", .expected = "feature" },
        .{ .input = "refs/tags/v1.0", .expected = "v1.0" },
        .{ .input = "refs/remotes/origin/main", .expected = "origin/main" },
        .{ .input = "HEAD", .expected = "HEAD" },
    };
    
    for (short_name_tests) |test_case| {
        const short_name = try refs.getShortRefName(test_case.input, allocator);
        defer allocator.free(short_name);
        
        try testing.expectEqualStrings(test_case.expected, short_name);
        std.debug.print("'{s}' short name: '{s}'\n", .{ test_case.input, short_name });
    }
    
    // Test suggestions for partial matches
    const suggestions = try refs.suggestSimilarRefs(git_dir, "feature", TestPlatform, allocator);
    defer {
        for (suggestions) |suggestion| {
            allocator.free(suggestion);
        }
        allocator.free(suggestions);
    }
    
    std.debug.print("Suggestions for 'feature': {} found\n", .{suggestions.len});
    for (suggestions) |suggestion| {
        std.debug.print("  - {s}\n", .{suggestion});
    }
    
    try testing.expect(suggestions.len > 0);
    
    std.debug.print("Advanced ref name expansion test completed successfully\n", .{});
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

test "ref validation and error handling" {
    const allocator = testing.allocator;
    
    // Test ref name validation
    const valid_names = [_][]const u8{
        "refs/heads/main",
        "refs/tags/v1.0.0",
        "refs/remotes/origin/develop",
        "feature/awesome-feature",
        "HEAD",
    };
    
    const invalid_names = [_][]const u8{
        "",           // Empty
        "ref with spaces",  // Spaces
        "ref\nwith\nnewlines",  // Control characters
        "ref..double.dots",     // Double dots
        "ref/.hidden",          // Starts with dot after slash
        "ref@{0}",             // At-brace pattern
        ".starts-with-dot",     // Starts with dot
        "ends-with-dot.",       // Ends with dot
        "/starts-with-slash",   // Starts with slash
        "ends-with-slash/",     // Ends with slash
    };
    
    // Test valid names
    for (valid_names) |name| {
        refs.validateRefName(name) catch |err| {
            std.debug.print("Unexpectedly invalid ref name: {s} ({any})\n", .{ name, err });
            try testing.expect(false);
        };
        std.debug.print("Valid ref name: {s}\n", .{name});
    }
    
    // Test invalid names
    for (invalid_names) |name| {
        refs.validateRefName(name) catch |err| {
            std.debug.print("Correctly rejected invalid ref name: {s} ({any})\n", .{ name, err });
            continue;
        };
        
        std.debug.print("Unexpectedly accepted invalid ref name: {s}\n", .{name});
        try testing.expect(false);
    }
    
    std.debug.print("Ref validation test completed successfully\n", .{});
}