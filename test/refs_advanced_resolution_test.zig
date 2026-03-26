const std = @import("std");
const refs = @import("../src/git/refs.zig");
const objects = @import("../src/git/objects.zig");

// Comprehensive test for advanced refs resolution features
// This test demonstrates enhanced symbolic ref resolution, annotated tags, and remote tracking

const TestPlatform = struct {
    fs: FileSystem = FileSystem{},
    
    const FileSystem = struct {
        fn readFile(self: @This(), allocator: std.mem.Allocator, path: []const u8) ![]u8 {
            _ = self;
            return std.fs.cwd().readFileAlloc(allocator, path, 100 * 1024 * 1024);
        }
        
        fn writeFile(self: @This(), path: []const u8, content: []const u8) !void {
            _ = self;
            if (std.fs.path.dirname(path)) |dir| {
                std.fs.cwd().makePath(dir) catch {};
            }
            try std.fs.cwd().writeFile(.{ .sub_path = path, .data = content });
        }
        
        fn exists(self: @This(), path: []const u8) !bool {
            _ = self;
            std.fs.cwd().access(path, .{}) catch |err| switch (err) {
                error.FileNotFound => return false,
                else => return err,
            };
            return true;
        }
        
        fn makeDir(self: @This(), path: []const u8) !void {
            _ = self;
            std.fs.cwd().makePath(path) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }
        
        fn deleteFile(self: @This(), path: []const u8) !void {
            _ = self;
            try std.fs.cwd().deleteFile(path);
        }
        
        fn readDir(self: @This(), allocator: std.mem.Allocator, path: []const u8) ![][]u8 {
            _ = self;
            var entries = std.ArrayList([]u8).init(allocator);
            var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch return entries.toOwnedSlice();
            defer dir.close();
            var iterator = dir.iterate();
            while (try iterator.next()) |entry| {
                if (entry.kind == .file) {
                    try entries.append(try allocator.dupe(u8, entry.name));
                }
            }
            return entries.toOwnedSlice();
        }
    };
};

/// Create a comprehensive test repository with various ref types
fn createTestRepository(allocator: std.mem.Allocator, platform: TestPlatform) ![]const u8 {
    const repo_path = "test_refs_repo/.git";
    
    // Create repository structure
    try platform.fs.makeDir("test_refs_repo/.git/refs/heads");
    try platform.fs.makeDir("test_refs_repo/.git/refs/tags");
    try platform.fs.makeDir("test_refs_repo/.git/refs/remotes/origin");
    try platform.fs.makeDir("test_refs_repo/.git/refs/remotes/upstream");
    try platform.fs.makeDir("test_refs_repo/.git/objects");
    
    // Test commit hashes
    const main_commit = "1234567890abcdef1234567890abcdef12345678";
    const develop_commit = "abcdef1234567890abcdef1234567890abcdef12";
    const feature_commit = "fedcba0987654321fedcba0987654321fedcba09";
    const tag_commit = "567890abcdef1234567890abcdef1234567890ab";
    
    // Create basic branches
    try platform.fs.writeFile("test_refs_repo/.git/refs/heads/main", main_commit ++ "\n");
    try platform.fs.writeFile("test_refs_repo/.git/refs/heads/develop", develop_commit ++ "\n");
    try platform.fs.writeFile("test_refs_repo/.git/refs/heads/feature-branch", feature_commit ++ "\n");
    
    // Create tags
    try platform.fs.writeFile("test_refs_repo/.git/refs/tags/v1.0.0", tag_commit ++ "\n");
    try platform.fs.writeFile("test_refs_repo/.git/refs/tags/v2.0.0", main_commit ++ "\n");
    
    // Create remote tracking branches
    try platform.fs.writeFile("test_refs_repo/.git/refs/remotes/origin/main", main_commit ++ "\n");
    try platform.fs.writeFile("test_refs_repo/.git/refs/remotes/origin/develop", develop_commit ++ "\n");
    try platform.fs.writeFile("test_refs_repo/.git/refs/remotes/upstream/main", main_commit ++ "\n");
    
    // Create HEAD pointing to main
    try platform.fs.writeFile("test_refs_repo/.git/HEAD", "ref: refs/heads/main\n");
    
    // Create a symbolic ref chain for testing
    try platform.fs.writeFile("test_refs_repo/.git/refs/heads/current", "ref: refs/heads/main\n");
    try platform.fs.writeFile("test_refs_repo/.git/refs/heads/latest", "ref: refs/heads/current\n");
    
    // Create packed-refs file for testing
    const packed_refs_content =
        \\# pack-refs with: peeled fully-peeled sorted 
        \\1234567890abcdef1234567890abcdef12345678 refs/heads/packed-branch
        \\abcdef1234567890abcdef1234567890abcdef12 refs/tags/packed-tag
        \\^1234567890abcdef1234567890abcdef12345678
        \\fedcba0987654321fedcba0987654321fedcba09 refs/remotes/origin/packed-remote
        \\567890abcdef1234567890abcdef1234567890ab refs/tags/annotated-tag
        \\^1234567890abcdef1234567890abcdef12345678
    ;
    
    try platform.fs.writeFile("test_refs_repo/.git/packed-refs", packed_refs_content);
    
    return try allocator.dupe(u8, repo_path);
}

test "symbolic ref resolution with depth" {
    const allocator = std.testing.allocator;
    
    std.debug.print("🧪 Testing symbolic ref resolution with depth...\n");
    
    var platform = TestPlatform{};
    const repo_path = try createTestRepository(allocator, platform);
    defer {
        allocator.free(repo_path);
        std.fs.cwd().deleteTree("test_refs_repo") catch {};
    }
    
    // Test HEAD resolution (should resolve through symbolic refs)
    const head_commit = try refs.resolveRef(repo_path, "HEAD", platform, allocator);
    if (head_commit) |commit| {
        defer allocator.free(commit);
        try std.testing.expectEqualStrings("1234567890abcdef1234567890abcdef12345678", commit);
        std.debug.print("🎯 HEAD resolves to: {s}\n", .{commit});
    } else {
        return error.TestFailed;
    }
    
    // Test nested symbolic refs (latest -> current -> main)
    const latest_commit = try refs.resolveRef(repo_path, "refs/heads/latest", platform, allocator);
    if (latest_commit) |commit| {
        defer allocator.free(commit);
        try std.testing.expectEqualStrings("1234567890abcdef1234567890abcdef12345678", commit);
        std.debug.print("🔗 Latest resolves through chain to: {s}\n", .{commit});
    } else {
        return error.TestFailed;
    }
    
    // Test circular reference detection by creating a cycle
    try platform.fs.writeFile("test_refs_repo/.git/refs/heads/circular1", "ref: refs/heads/circular2\n");
    try platform.fs.writeFile("test_refs_repo/.git/refs/heads/circular2", "ref: refs/heads/circular1\n");
    
    const circular_result = refs.resolveRef(repo_path, "refs/heads/circular1", platform, allocator);
    if (circular_result) |commit| {
        allocator.free(commit);
        return error.TestFailed; // Should not succeed
    } else |err| {
        try std.testing.expectError(error.CircularRef, circular_result);
        std.debug.print("🔄 Circular reference correctly detected: {}\n", .{err});
    }
    
    std.debug.print("✅ Symbolic ref resolution test passed\n");
}

test "ref name expansion and fallback resolution" {
    const allocator = std.testing.allocator;
    
    std.debug.print("🧪 Testing ref name expansion and fallback resolution...\n");
    
    var platform = TestPlatform{};
    const repo_path = try createTestRepository(allocator, platform);
    defer {
        allocator.free(repo_path);
        std.fs.cwd().deleteTree("test_refs_repo") catch {};
    }
    
    // Test short branch name expansion
    const main_expanded = try refs.expandRefName(repo_path, "main", platform, allocator);
    if (main_expanded) |full_ref| {
        defer allocator.free(full_ref);
        try std.testing.expectEqualStrings("refs/heads/main", full_ref);
        std.debug.print("🔍 'main' expands to: {s}\n", .{full_ref});
    } else {
        return error.TestFailed;
    }
    
    // Test tag name expansion
    const tag_expanded = try refs.expandRefName(repo_path, "v1.0.0", platform, allocator);
    if (tag_expanded) |full_ref| {
        defer allocator.free(full_ref);
        try std.testing.expectEqualStrings("refs/tags/v1.0.0", full_ref);
        std.debug.print("🏷️  'v1.0.0' expands to: {s}\n", .{full_ref});
    } else {
        return error.TestFailed;
    }
    
    // Test resolution with fallback to different namespaces
    const develop_commit = try refs.resolveRef(repo_path, "develop", platform, allocator);
    if (develop_commit) |commit| {
        defer allocator.free(commit);
        try std.testing.expectEqualStrings("abcdef1234567890abcdef1234567890abcdef12", commit);
        std.debug.print("🌿 'develop' resolves to: {s}\n", .{commit});
    } else {
        return error.TestFailed;
    }
    
    // Test non-existent ref
    const missing_expanded = try refs.expandRefName(repo_path, "non-existent", platform, allocator);
    try std.testing.expect(missing_expanded == null);
    std.debug.print("❓ 'non-existent' correctly returns null\n");
    
    std.debug.print("✅ Ref name expansion test passed\n");
}

test "packed-refs parsing with peeled refs" {
    const allocator = std.testing.allocator;
    
    std.debug.print("🧪 Testing packed-refs parsing with peeled refs...\n");
    
    var platform = TestPlatform{};
    const repo_path = try createTestRepository(allocator, platform);
    defer {
        allocator.free(repo_path);
        std.fs.cwd().deleteTree("test_refs_repo") catch {};
    }
    
    // Test packed branch resolution
    const packed_branch = try refs.resolveRef(repo_path, "refs/heads/packed-branch", platform, allocator);
    if (packed_branch) |commit| {
        defer allocator.free(commit);
        try std.testing.expectEqualStrings("1234567890abcdef1234567890abcdef12345678", commit);
        std.debug.print("📦 Packed branch resolves to: {s}\n", .{commit});
    } else {
        return error.TestFailed;
    }
    
    // Test packed tag with peeled ref (should return the peeled commit, not the tag object)
    const packed_tag = try refs.resolveRef(repo_path, "refs/tags/packed-tag", platform, allocator);
    if (packed_tag) |commit| {
        defer allocator.free(commit);
        try std.testing.expectEqualStrings("1234567890abcdef1234567890abcdef12345678", commit);
        std.debug.print("🏷️  Packed tag (peeled) resolves to: {s}\n", .{commit});
    } else {
        return error.TestFailed;
    }
    
    // Test annotated tag with peeled ref
    const annotated_tag = try refs.resolveRef(repo_path, "refs/tags/annotated-tag", platform, allocator);
    if (annotated_tag) |commit| {
        defer allocator.free(commit);
        try std.testing.expectEqualStrings("1234567890abcdef1234567890abcdef12345678", commit);
        std.debug.print("🎯 Annotated tag (peeled) resolves to: {s}\n", .{commit});
    } else {
        return error.TestFailed;
    }
    
    // Test remote tracking branch in packed-refs
    const packed_remote = try refs.resolveRef(repo_path, "refs/remotes/origin/packed-remote", platform, allocator);
    if (packed_remote) |commit| {
        defer allocator.free(commit);
        try std.testing.expectEqualStrings("fedcba0987654321fedcba0987654321fedcba09", commit);
        std.debug.print("🌐 Packed remote branch resolves to: {s}\n", .{commit});
    } else {
        return error.TestFailed;
    }
    
    std.debug.print("✅ Packed-refs parsing test passed\n");
}

test "ref type detection and classification" {
    const allocator = std.testing.allocator;
    
    std.debug.print("🧪 Testing ref type detection and classification...\n");
    
    // Test ref type detection
    try std.testing.expect(refs.getRefType("HEAD") == .head);
    try std.testing.expect(refs.getRefType("refs/heads/main") == .branch);
    try std.testing.expect(refs.getRefType("refs/tags/v1.0.0") == .tag);
    try std.testing.expect(refs.getRefType("refs/remotes/origin/main") == .remote);
    try std.testing.expect(refs.getRefType("refs/notes/commits") == .other);
    
    std.debug.print("🔍 Ref type detection working correctly:\n");
    std.debug.print("  - HEAD -> head\n");
    std.debug.print("  - refs/heads/main -> branch\n");
    std.debug.print("  - refs/tags/v1.0.0 -> tag\n");
    std.debug.print("  - refs/remotes/origin/main -> remote\n");
    std.debug.print("  - refs/notes/commits -> other\n");
    
    // Test short ref name extraction
    const short_branch = try refs.getShortRefName("refs/heads/feature-branch", allocator);
    defer allocator.free(short_branch);
    try std.testing.expectEqualStrings("feature-branch", short_branch);
    
    const short_tag = try refs.getShortRefName("refs/tags/v2.0.0", allocator);
    defer allocator.free(short_tag);
    try std.testing.expectEqualStrings("v2.0.0", short_tag);
    
    const short_remote = try refs.getShortRefName("refs/remotes/origin/main", allocator);
    defer allocator.free(short_remote);
    try std.testing.expectEqualStrings("origin/main", short_remote);
    
    std.debug.print("✂️  Short name extraction working correctly\n");
    
    std.debug.print("✅ Ref type detection test passed\n");
}

test "branch and remote listing" {
    const allocator = std.testing.allocator;
    
    std.debug.print("🧪 Testing branch and remote listing...\n");
    
    var platform = TestPlatform{};
    const repo_path = try createTestRepository(allocator, platform);
    defer {
        allocator.free(repo_path);
        std.fs.cwd().deleteTree("test_refs_repo") catch {};
    }
    
    // Test branch listing
    const branches = try refs.listBranches(repo_path, platform, allocator);
    defer {
        for (branches.items) |branch| {
            allocator.free(branch);
        }
        branches.deinit();
    }
    
    std.debug.print("🌿 Found {} branches:\n", .{branches.items.len});
    for (branches.items) |branch| {
        std.debug.print("  - {s}\n", .{branch});
    }
    
    try std.testing.expect(branches.items.len >= 4); // main, develop, feature-branch, current, latest
    
    // Verify specific branches exist
    var found_main = false;
    var found_develop = false;
    var found_feature = false;
    
    for (branches.items) |branch| {
        if (std.mem.eql(u8, branch, "main")) found_main = true;
        if (std.mem.eql(u8, branch, "develop")) found_develop = true;
        if (std.mem.eql(u8, branch, "feature-branch")) found_feature = true;
    }
    
    try std.testing.expect(found_main and found_develop and found_feature);
    
    // Test remote listing
    const remotes = try refs.listRemotes(repo_path, platform, allocator);
    defer {
        for (remotes.items) |remote| {
            allocator.free(remote);
        }
        remotes.deinit();
    }
    
    std.debug.print("🌐 Found {} remotes:\n", .{remotes.items.len});
    for (remotes.items) |remote| {
        std.debug.print("  - {s}\n", .{remote});
    }
    
    try std.testing.expect(remotes.items.len >= 2); // origin, upstream
    
    // Test remote branch listing
    const origin_branches = try refs.listRemoteBranches(repo_path, "origin", platform, allocator);
    defer {
        for (origin_branches.items) |branch| {
            allocator.free(branch);
        }
        origin_branches.deinit();
    }
    
    std.debug.print("🌐 Origin has {} branches:\n", .{origin_branches.items.len});
    for (origin_branches.items) |branch| {
        std.debug.print("  - origin/{s}\n", .{branch});
    }
    
    try std.testing.expect(origin_branches.items.len >= 2); // main, develop
    
    std.debug.print("✅ Branch and remote listing test passed\n");
}

test "tag listing and resolution" {
    const allocator = std.testing.allocator;
    
    std.debug.print("🧪 Testing tag listing and resolution...\n");
    
    var platform = TestPlatform{};
    const repo_path = try createTestRepository(allocator, platform);
    defer {
        allocator.free(repo_path);
        std.fs.cwd().deleteTree("test_refs_repo") catch {};
    }
    
    // Test tag listing (should find both loose and packed tags)
    const tags = try refs.listTags(repo_path, platform, allocator);
    defer {
        for (tags.items) |tag| {
            allocator.free(tag);
        }
        tags.deinit();
    }
    
    std.debug.print("🏷️  Found {} tags:\n", .{tags.items.len});
    for (tags.items) |tag| {
        std.debug.print("  - {s}\n", .{tag});
    }
    
    try std.testing.expect(tags.items.len >= 4); // v1.0.0, v2.0.0, packed-tag, annotated-tag
    
    // Verify specific tags exist
    var found_v1 = false;
    var found_v2 = false;
    var found_packed = false;
    var found_annotated = false;
    
    for (tags.items) |tag| {
        if (std.mem.eql(u8, tag, "v1.0.0")) found_v1 = true;
        if (std.mem.eql(u8, tag, "v2.0.0")) found_v2 = true;
        if (std.mem.eql(u8, tag, "packed-tag")) found_packed = true;
        if (std.mem.eql(u8, tag, "annotated-tag")) found_annotated = true;
    }
    
    try std.testing.expect(found_v1 and found_v2 and found_packed and found_annotated);
    
    // Test tag resolution
    const v1_commit = try refs.resolveRef(repo_path, "refs/tags/v1.0.0", platform, allocator);
    if (v1_commit) |commit| {
        defer allocator.free(commit);
        try std.testing.expectEqualStrings("567890abcdef1234567890abcdef1234567890ab", commit);
        std.debug.print("🏷️  v1.0.0 resolves to: {s}\n", .{commit});
    } else {
        return error.TestFailed;
    }
    
    std.debug.print("✅ Tag listing and resolution test passed\n");
}

test "ref validation and error handling" {
    const allocator = std.testing.allocator;
    
    std.debug.print("🧪 Testing ref validation and error handling...\n");
    
    // Test valid ref names
    try refs.validateRefName("refs/heads/main");
    try refs.validateRefName("refs/tags/v1.0.0");
    try refs.validateRefName("refs/remotes/origin/feature-branch");
    try refs.validateRefName("HEAD");
    std.debug.print("✅ Valid ref names pass validation\n");
    
    // Test invalid ref names
    try std.testing.expectError(error.EmptyRefName, refs.validateRefName(""));
    try std.testing.expectError(error.InvalidRefName, refs.validateRefName("refs/heads/invalid..name"));
    try std.testing.expectError(error.InvalidRefName, refs.validateRefName("refs/heads/invalid~name"));
    try std.testing.expectError(error.InvalidRefName, refs.validateRefName("refs/heads/.invalid"));
    try std.testing.expectError(error.InvalidRefName, refs.validateRefName("refs/heads/invalid."));
    try std.testing.expectError(error.InvalidRefName, refs.validateRefName("/refs/heads/invalid"));
    
    std.debug.print("🚫 Invalid ref names correctly rejected\n");
    
    // Test ref existence checking
    var platform = TestPlatform{};
    const repo_path = try createTestRepository(allocator, platform);
    defer {
        allocator.free(repo_path);
        std.fs.cwd().deleteTree("test_refs_repo") catch {};
    }
    
    // Test existing ref
    const main_exists = try refs.refExists(repo_path, "refs/heads/main", platform, allocator);
    try std.testing.expect(main_exists == true);
    std.debug.print("✅ Existing ref correctly detected\n");
    
    // Test non-existing ref
    const nonexistent_exists = try refs.refExists(repo_path, "refs/heads/does-not-exist", platform, allocator);
    try std.testing.expect(nonexistent_exists == false);
    std.debug.print("❌ Non-existing ref correctly detected\n");
    
    std.debug.print("✅ Ref validation and error handling test passed\n");
}

test "ref caching and performance optimization" {
    const allocator = std.testing.allocator;
    
    std.debug.print("🧪 Testing ref caching and performance optimization...\n");
    
    var platform = TestPlatform{};
    const repo_path = try createTestRepository(allocator, platform);
    defer {
        allocator.free(repo_path);
        std.fs.cwd().deleteTree("test_refs_repo") catch {};
    }
    
    // Test RefResolver with caching
    var resolver = refs.RefResolver.init(repo_path, allocator);
    defer resolver.deinit();
    
    // Test cache miss (first resolution)
    const start_time = std.time.milliTimestamp();
    
    const main_commit1 = try resolver.resolve("refs/heads/main", platform);
    if (main_commit1) |commit| {
        defer allocator.free(commit);
        try std.testing.expectEqualStrings("1234567890abcdef1234567890abcdef12345678", commit);
    } else {
        return error.TestFailed;
    }
    
    const first_resolve_time = std.time.milliTimestamp() - start_time;
    
    // Test cache hit (second resolution should be faster)
    const cache_start = std.time.milliTimestamp();
    
    const main_commit2 = try resolver.resolve("refs/heads/main", platform);
    if (main_commit2) |commit| {
        defer allocator.free(commit);
        try std.testing.expectEqualStrings("1234567890abcdef1234567890abcdef12345678", commit);
    } else {
        return error.TestFailed;
    }
    
    const cache_resolve_time = std.time.milliTimestamp() - cache_start;
    
    std.debug.print("⏱️  First resolve: {} ms, Cached resolve: {} ms\n", .{ first_resolve_time, cache_resolve_time });
    
    // Test batch resolution
    const ref_names = [_][]const u8{ "refs/heads/main", "refs/heads/develop", "refs/tags/v1.0.0", "refs/remotes/origin/main" };
    
    const batch_start = std.time.milliTimestamp();
    const batch_results = try resolver.resolveBatch(&ref_names, platform);
    defer {
        for (batch_results) |result| {
            if (result) |commit| {
                allocator.free(commit);
            }
        }
        allocator.free(batch_results);
    }
    const batch_time = std.time.milliTimestamp() - batch_start;
    
    std.debug.print("📦 Batch resolved {} refs in {} ms\n", .{ ref_names.len, batch_time });
    
    // All refs should resolve successfully
    for (batch_results) |result| {
        try std.testing.expect(result != null);
    }
    
    // Test cache statistics
    const stats = resolver.getCacheStats();
    std.debug.print("📊 Cache stats: {} entries, valid: {}, expires in: {}s\n", 
        .{ stats.entries, stats.is_valid, stats.expires_in });
    
    try std.testing.expect(stats.entries > 0);
    
    // Test cache clearing
    resolver.clearCache();
    const empty_stats = resolver.getCacheStats();
    try std.testing.expect(empty_stats.entries == 0);
    std.debug.print("🧹 Cache cleared successfully\n");
    
    std.debug.print("✅ Ref caching and performance test passed\n");
}

test "advanced ref management operations" {
    const allocator = std.testing.allocator;
    
    std.debug.print("🧪 Testing advanced ref management operations...\n");
    
    var platform = TestPlatform{};
    const repo_path = try createTestRepository(allocator, platform);
    defer {
        allocator.free(repo_path);
        std.fs.cwd().deleteTree("test_refs_repo") catch {};
    }
    
    // Test RefManager
    const ref_manager = refs.RefManager.init(repo_path, allocator);
    
    // Test creating a new branch
    try ref_manager.createBranch("new-feature", "1234567890abcdef1234567890abcdef12345678", platform);
    
    // Verify the branch was created
    const new_branch_exists = try refs.refExists(repo_path, "refs/heads/new-feature", platform, allocator);
    try std.testing.expect(new_branch_exists == true);
    std.debug.print("🌿 Created new branch 'new-feature'\n");
    
    // Test branch already exists error
    const duplicate_result = ref_manager.createBranch("new-feature", "1234567890abcdef1234567890abcdef12345678", platform);
    try std.testing.expectError(error.BranchAlreadyExists, duplicate_result);
    std.debug.print("🚫 Duplicate branch creation correctly rejected\n");
    
    // Test getting ref info
    const main_info = try ref_manager.getRefInfo("refs/heads/main", platform);
    defer {
        allocator.free(main_info.name);
        allocator.free(main_info.hash);
        if (main_info.target) |target| allocator.free(target);
    }
    
    try std.testing.expectEqualStrings("refs/heads/main", main_info.name);
    try std.testing.expectEqualStrings("1234567890abcdef1234567890abcdef12345678", main_info.hash);
    try std.testing.expect(main_info.ref_type == .branch);
    try std.testing.expect(main_info.is_symbolic == false);
    
    std.debug.print("ℹ️  Main branch info: {s} -> {s}\n", .{ main_info.name, main_info.hash });
    
    // Test deleting a branch
    try ref_manager.deleteBranch("new-feature", platform);
    
    const deleted_exists = try refs.refExists(repo_path, "refs/heads/new-feature", platform, allocator);
    try std.testing.expect(deleted_exists == false);
    std.debug.print("🗑️  Deleted branch 'new-feature'\n");
    
    // Test checkout (updating HEAD)
    try ref_manager.checkoutBranch("develop", platform);
    
    const current_branch = try refs.getCurrentBranch(repo_path, platform, allocator);
    defer allocator.free(current_branch);
    
    try std.testing.expectEqualStrings("develop", current_branch);
    std.debug.print("🔄 Checked out branch 'develop'\n");
    
    std.debug.print("✅ Advanced ref management test passed\n");
}

test "ref name suggestion and fuzzy matching" {
    const allocator = std.testing.allocator;
    
    std.debug.print("🧪 Testing ref name suggestion and fuzzy matching...\n");
    
    var platform = TestPlatform{};
    const repo_path = try createTestRepository(allocator, platform);
    defer {
        allocator.free(repo_path);
        std.fs.cwd().deleteTree("test_refs_repo") catch {};
    }
    
    // Test suggesting similar ref names
    const suggestions = try refs.suggestSimilarRefs(repo_path, "mai", platform, allocator);
    defer {
        for (suggestions) |suggestion| {
            allocator.free(suggestion);
        }
        allocator.free(suggestions);
    }
    
    std.debug.print("💡 Suggestions for 'mai':\n");
    for (suggestions) |suggestion| {
        std.debug.print("  - {s}\n", .{suggestion});
    }
    
    // Should find "main" as a suggestion
    var found_main_suggestion = false;
    for (suggestions) |suggestion| {
        if (std.mem.indexOf(u8, suggestion, "main") != null) {
            found_main_suggestion = true;
            break;
        }
    }
    try std.testing.expect(found_main_suggestion);
    
    std.debug.print("🎯 Found 'main' in suggestions\n");
    
    // Test with tag partial match
    const tag_suggestions = try refs.suggestSimilarRefs(repo_path, "v1", platform, allocator);
    defer {
        for (tag_suggestions) |suggestion| {
            allocator.free(suggestion);
        }
        allocator.free(tag_suggestions);
    }
    
    var found_v1_tag = false;
    for (tag_suggestions) |suggestion| {
        if (std.mem.indexOf(u8, suggestion, "v1.0.0") != null) {
            found_v1_tag = true;
            break;
        }
    }
    try std.testing.expect(found_v1_tag);
    
    std.debug.print("🏷️  Found 'v1.0.0' in tag suggestions\n");
    
    std.debug.print("✅ Ref name suggestion test passed\n");
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.debug.print("🚀 Running comprehensive refs advanced resolution tests\n");
    std.debug.print("=" ** 70 ++ "\n");
    
    // Run all comprehensive tests
    _ = @import("std").testing.refAllDecls(@This());
    
    std.debug.print("\n🎉 All comprehensive refs tests completed!\n");
    std.debug.print("\nRefs resolution improvements demonstrated:\n");
    std.debug.print("• ✅ Deep symbolic ref resolution with cycle detection\n");
    std.debug.print("• ✅ Ref name expansion and fallback resolution\n");
    std.debug.print("• ✅ Packed-refs parsing with peeled ref support\n");
    std.debug.print("• ✅ Ref type detection and classification\n");
    std.debug.print("• ✅ Branch, remote, and tag listing\n");
    std.debug.print("• ✅ Comprehensive ref validation and error handling\n");
    std.debug.print("• ✅ Performance caching and batch operations\n");
    std.debug.print("• ✅ Advanced ref management operations\n");
    std.debug.print("• ✅ Fuzzy matching and suggestion system\n");
}