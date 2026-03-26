const std = @import("std");
const refs = @import("../src/git/refs.zig");
const objects = @import("../src/git/objects.zig");
const testing = std.testing;

test "symbolic ref resolution comprehensive test" {
    const allocator = testing.allocator;

    // Create a test repository with various ref types
    const temp_path = "/tmp/zig-test-refs-symbolic";
    std.fs.cwd().deleteTree(temp_path) catch {};
    try std.fs.cwd().makePath(temp_path);
    defer std.fs.cwd().deleteTree(temp_path) catch {};

    // Initialize git repository
    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "init" }, allocator);
        cmd.cwd = temp_path;
        cmd.stdout_behavior = .Ignore;
        _ = try cmd.spawnAndWait();
    }

    // Configure git
    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "config", "user.name", "Test User" }, allocator);
        cmd.cwd = temp_path;
        _ = try cmd.spawnAndWait();
    }
    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "config", "user.email", "test@example.com" }, allocator);
        cmd.cwd = temp_path;
        _ = try cmd.spawnAndWait();
    }

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{temp_path});
    defer allocator.free(git_dir);

    // Create initial commit
    const test_file = try std.fmt.allocPrint(allocator, "{s}/initial.txt", .{temp_path});
    defer allocator.free(test_file);
    try std.fs.cwd().writeFile(.{ .sub_path = test_file, .data = "Initial content" });

    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "add", "initial.txt" }, allocator);
        cmd.cwd = temp_path;
        _ = try cmd.spawnAndWait();
    }
    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "commit", "-m", "Initial commit" }, allocator);
        cmd.cwd = temp_path;
        cmd.stdout_behavior = .Ignore;
        _ = try cmd.spawnAndWait();
    }

    // Create some branches
    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "branch", "develop" }, allocator);
        cmd.cwd = temp_path;
        _ = try cmd.spawnAndWait();
    }
    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "branch", "feature-branch" }, allocator);
        cmd.cwd = temp_path;
        _ = try cmd.spawnAndWait();
    }

    // Create a tag
    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "tag", "v1.0.0" }, allocator);
        cmd.cwd = temp_path;
        _ = try cmd.spawnAndWait();
    }

    // Create an annotated tag
    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "tag", "-a", "v1.0.1", "-m", "Annotated tag v1.0.1" }, allocator);
        cmd.cwd = temp_path;
        _ = try cmd.spawnAndWait();
    }

    // Add a remote and remote tracking branch
    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "remote", "add", "origin", "https://github.com/test/repo.git" }, allocator);
        cmd.cwd = temp_path;
        _ = try cmd.spawnAndWait();
    }

    // Test platform implementation
    const TestPlatform = struct {
        pub const fs = struct {
            pub fn readFile(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
                return std.fs.cwd().readFileAlloc(alloc, path, 10 * 1024 * 1024);
            }
            
            pub fn readDir(alloc: std.mem.Allocator, path: []const u8) ![][]u8 {
                var entries = std.ArrayList([]u8).init(alloc);
                errdefer {
                    for (entries.items) |entry| alloc.free(entry);
                    entries.deinit();
                }
                
                var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch return entries.toOwnedSlice();
                defer dir.close();
                
                var iterator = dir.iterate();
                while (try iterator.next()) |entry| {
                    try entries.append(try alloc.dupe(u8, entry.name));
                }
                
                return entries.toOwnedSlice();
            }
        };
    };

    // Test HEAD resolution
    std.debug.print("Testing HEAD resolution...\n", .{});
    const head_commit = refs.resolveRef(git_dir, "HEAD", TestPlatform, allocator) catch |err| {
        std.debug.print("Failed to resolve HEAD: {}\n", .{err});
        return err;
    };
    if (head_commit) |commit| {
        defer allocator.free(commit);
        try testing.expect(commit.len == 40); // SHA-1 hash
        std.debug.print("✓ HEAD resolves to: {s}\n", .{commit[0..8]});
    } else {
        return error.HeadResolutionFailed;
    }

    // Test current branch detection
    const current_branch = refs.getCurrentBranch(git_dir, TestPlatform, allocator) catch |err| {
        std.debug.print("Failed to get current branch: {}\n", .{err});
        return err;
    };
    defer allocator.free(current_branch);

    std.debug.print("✓ Current branch: {s}\n", .{current_branch});
    try testing.expect(std.mem.eql(u8, current_branch, "master") or std.mem.eql(u8, current_branch, "main"));

    // Test branch resolution
    std.debug.print("Testing branch resolution...\n", .{});
    const develop_commit = refs.resolveRef(git_dir, "develop", TestPlatform, allocator) catch |err| {
        std.debug.print("Failed to resolve develop branch: {}\n", .{err});
        return err;
    };
    if (develop_commit) |commit| {
        defer allocator.free(commit);
        try testing.expect(commit.len == 40);
        std.debug.print("✓ develop branch resolves to: {s}\n", .{commit[0..8]});
    }

    const feature_commit = refs.resolveRef(git_dir, "feature-branch", TestPlatform, allocator) catch |err| {
        std.debug.print("Failed to resolve feature-branch: {}\n", .{err});
        return err;
    };
    if (feature_commit) |commit| {
        defer allocator.free(commit);
        try testing.expect(commit.len == 40);
        std.debug.print("✓ feature-branch resolves to: {s}\n", .{commit[0..8]});
    }

    // Test full ref name resolution
    const full_develop_commit = refs.resolveRef(git_dir, "refs/heads/develop", TestPlatform, allocator) catch |err| {
        std.debug.print("Failed to resolve refs/heads/develop: {}\n", .{err});
        return err;
    };
    if (full_develop_commit) |commit| {
        defer allocator.free(commit);
        try testing.expect(commit.len == 40);
        std.debug.print("✓ refs/heads/develop resolves to: {s}\n", .{commit[0..8]});
    }

    // Test tag resolution
    std.debug.print("Testing tag resolution...\n", .{});
    const tag_commit = refs.resolveRef(git_dir, "v1.0.0", TestPlatform, allocator) catch |err| {
        std.debug.print("Failed to resolve v1.0.0 tag: {}\n", .{err});
        return err;
    };
    if (tag_commit) |commit| {
        defer allocator.free(commit);
        try testing.expect(commit.len == 40);
        std.debug.print("✓ v1.0.0 tag resolves to: {s}\n", .{commit[0..8]});
    }

    // Test annotated tag resolution
    const annotated_tag_commit = refs.resolveRef(git_dir, "v1.0.1", TestPlatform, allocator) catch |err| {
        std.debug.print("Failed to resolve v1.0.1 annotated tag: {}\n", .{err});
        return err;
    };
    if (annotated_tag_commit) |commit| {
        defer allocator.free(commit);
        try testing.expect(commit.len == 40);
        std.debug.print("✓ v1.0.1 annotated tag resolves to: {s}\n", .{commit[0..8]});
    }

    // Test listing branches
    std.debug.print("Testing branch listing...\n", .{});
    const branches = refs.listBranches(git_dir, TestPlatform, allocator) catch |err| {
        std.debug.print("Failed to list branches: {}\n", .{err});
        return err;
    };
    defer {
        for (branches.items) |branch| {
            allocator.free(branch);
        }
        branches.deinit();
    }

    std.debug.print("✓ Found {} branches:\n", .{branches.items.len});
    for (branches.items) |branch| {
        std.debug.print("  - {s}\n", .{branch});
    }

    try testing.expect(branches.items.len >= 3); // master/main, develop, feature-branch

    // Test listing tags
    std.debug.print("Testing tag listing...\n", .{});
    const tags = refs.listTags(git_dir, TestPlatform, allocator) catch |err| {
        std.debug.print("Failed to list tags: {}\n", .{err});
        return err;
    };
    defer {
        for (tags.items) |tag| {
            allocator.free(tag);
        }
        tags.deinit();
    }

    std.debug.print("✓ Found {} tags:\n", .{tags.items.len});
    for (tags.items) |tag| {
        std.debug.print("  - {s}\n", .{tag});
    }

    try testing.expect(tags.items.len >= 2); // v1.0.0, v1.0.1

    std.debug.print("✓ All symbolic ref resolution tests passed!\n", .{});
}

test "nested symbolic refs and circular reference detection" {
    const allocator = testing.allocator;

    // Create a test repository
    const temp_path = "/tmp/zig-test-refs-nested";
    std.fs.cwd().deleteTree(temp_path) catch {};
    try std.fs.cwd().makePath(temp_path);
    defer std.fs.cwd().deleteTree(temp_path) catch {};

    // Initialize git repository
    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "init" }, allocator);
        cmd.cwd = temp_path;
        cmd.stdout_behavior = .Ignore;
        _ = try cmd.spawnAndWait();
    }

    // Configure git
    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "config", "user.name", "Test User" }, allocator);
        cmd.cwd = temp_path;
        _ = try cmd.spawnAndWait();
    }
    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "config", "user.email", "test@example.com" }, allocator);
        cmd.cwd = temp_path;
        _ = try cmd.spawnAndWait();
    }

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{temp_path});
    defer allocator.free(git_dir);

    // Create initial commit
    const test_file = try std.fmt.allocPrint(allocator, "{s}/test.txt", .{temp_path});
    defer allocator.free(test_file);
    try std.fs.cwd().writeFile(.{ .sub_path = test_file, .data = "Test content" });

    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "add", "test.txt" }, allocator);
        cmd.cwd = temp_path;
        _ = try cmd.spawnAndWait();
    }
    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "commit", "-m", "Initial commit" }, allocator);
        cmd.cwd = temp_path;
        cmd.stdout_behavior = .Ignore;
        _ = try cmd.spawnAndWait();
    }

    // Create branches
    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "branch", "branch1" }, allocator);
        cmd.cwd = temp_path;
        _ = try cmd.spawnAndWait();
    }

    // Test platform implementation
    const TestPlatform = struct {
        pub const fs = struct {
            pub fn readFile(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
                return std.fs.cwd().readFileAlloc(alloc, path, 10 * 1024 * 1024);
            }
        };
    };

    // Create a nested symbolic reference manually
    std.debug.print("Testing nested symbolic refs...\n", .{});
    
    const sym_ref_path = try std.fmt.allocPrint(allocator, "{s}/refs/heads/symref1", .{git_dir});
    defer allocator.free(sym_ref_path);
    try std.fs.cwd().writeFile(.{ .sub_path = sym_ref_path, .data = "ref: refs/heads/branch1" });

    const nested_sym_ref_path = try std.fmt.allocPrint(allocator, "{s}/refs/heads/symref2", .{git_dir});
    defer allocator.free(nested_sym_ref_path);
    try std.fs.cwd().writeFile(.{ .sub_path = nested_sym_ref_path, .data = "ref: refs/heads/symref1" });

    // Test resolving nested symbolic ref
    const resolved_commit = refs.resolveRef(git_dir, "symref2", TestPlatform, allocator) catch |err| {
        std.debug.print("Failed to resolve nested symbolic ref: {}\n", .{err});
        return err;
    };
    if (resolved_commit) |commit| {
        defer allocator.free(commit);
        try testing.expect(commit.len == 40);
        std.debug.print("✓ Nested symbolic ref resolves to: {s}\n", .{commit[0..8]});
    }

    // Test circular reference detection
    std.debug.print("Testing circular reference detection...\n", .{});
    
    const circular_ref1_path = try std.fmt.allocPrint(allocator, "{s}/refs/heads/circular1", .{git_dir});
    defer allocator.free(circular_ref1_path);
    try std.fs.cwd().writeFile(.{ .sub_path = circular_ref1_path, .data = "ref: refs/heads/circular2" });

    const circular_ref2_path = try std.fmt.allocPrint(allocator, "{s}/refs/heads/circular2", .{git_dir});
    defer allocator.free(circular_ref2_path);
    try std.fs.cwd().writeFile(.{ .sub_path = circular_ref2_path, .data = "ref: refs/heads/circular1" });

    // This should fail with circular reference error
    const circular_result = refs.resolveRef(git_dir, "circular1", TestPlatform, allocator);
    if (circular_result) |commit| {
        allocator.free(commit);
        return error.CircularRefNotDetected;
    } else |err| {
        switch (err) {
            error.CircularRef => {
                std.debug.print("✓ Circular reference correctly detected\n", .{});
            },
            error.TooManySymbolicRefs => {
                std.debug.print("✓ Too many symbolic refs detected (also valid)\n", .{});
            },
            else => {
                std.debug.print("Unexpected error for circular ref: {}\n", .{err});
                return err;
            },
        }
    }

    // Test maximum depth handling
    std.debug.print("Testing maximum symbolic ref depth...\n", .{});
    
    // Create a very long chain of symbolic refs
    for (0..25) |i| {
        const ref_path = try std.fmt.allocPrint(allocator, "{s}/refs/heads/deep{d}", .{ git_dir, i });
        defer allocator.free(ref_path);
        
        const target = if (i == 24) 
            "refs/heads/branch1"  // Final target
        else 
            try std.fmt.allocPrint(allocator, "refs/heads/deep{d}", .{i + 1});
        
        const ref_content = try std.fmt.allocPrint(allocator, "ref: {s}", .{target});
        defer allocator.free(ref_content);
        if (i != 24) defer allocator.free(target);
        
        try std.fs.cwd().writeFile(.{ .sub_path = ref_path, .data = ref_content });
    }

    // This should fail due to depth limit
    const deep_result = refs.resolveRef(git_dir, "deep0", TestPlatform, allocator);
    if (deep_result) |commit| {
        allocator.free(commit);
        return error.DepthLimitNotEnforced;
    } else |err| {
        switch (err) {
            error.TooManySymbolicRefs => {
                std.debug.print("✓ Symbolic ref depth limit correctly enforced\n", .{});
            },
            else => {
                std.debug.print("Unexpected error for deep symbolic ref: {}\n", .{err});
                return err;
            },
        }
    }

    std.debug.print("✓ All nested symbolic ref tests passed!\n", .{});
}

test "refs with packed-refs file" {
    const allocator = testing.allocator;

    // Create a test repository
    const temp_path = "/tmp/zig-test-refs-packed";
    std.fs.cwd().deleteTree(temp_path) catch {};
    try std.fs.cwd().makePath(temp_path);
    defer std.fs.cwd().deleteTree(temp_path) catch {};

    // Initialize git repository
    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "init" }, allocator);
        cmd.cwd = temp_path;
        cmd.stdout_behavior = .Ignore;
        _ = try cmd.spawnAndWait();
    }

    // Configure git
    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "config", "user.name", "Test User" }, allocator);
        cmd.cwd = temp_path;
        _ = try cmd.spawnAndWait();
    }
    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "config", "user.email", "test@example.com" }, allocator);
        cmd.cwd = temp_path;
        _ = try cmd.spawnAndWait();
    }

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{temp_path});
    defer allocator.free(git_dir);

    // Create initial commits and branches
    const test_file = try std.fmt.allocPrint(allocator, "{s}/test.txt", .{temp_path});
    defer allocator.free(test_file);
    try std.fs.cwd().writeFile(.{ .sub_path = test_file, .data = "Test content" });

    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "add", "test.txt" }, allocator);
        cmd.cwd = temp_path;
        _ = try cmd.spawnAndWait();
    }
    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "commit", "-m", "Initial commit" }, allocator);
        cmd.cwd = temp_path;
        cmd.stdout_behavior = .Ignore;
        _ = try cmd.spawnAndWait();
    }

    // Create multiple branches and tags
    for (0..5) |i| {
        const branch_name = try std.fmt.allocPrint(allocator, "branch{d}", .{i});
        defer allocator.free(branch_name);
        
        {
            var cmd = std.process.Child.init(&[_][]const u8{ "git", "branch", branch_name }, allocator);
            cmd.cwd = temp_path;
            _ = try cmd.spawnAndWait();
        }

        const tag_name = try std.fmt.allocPrint(allocator, "v1.0.{d}", .{i});
        defer allocator.free(tag_name);
        
        {
            var cmd = std.process.Child.init(&[_][]const u8{ "git", "tag", tag_name }, allocator);
            cmd.cwd = temp_path;
            _ = try cmd.spawnAndWait();
        }
    }

    // Force pack refs
    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "pack-refs", "--all" }, allocator);
        cmd.cwd = temp_path;
        cmd.stdout_behavior = .Ignore;
        _ = try cmd.spawnAndWait();
    }

    // Test platform implementation
    const TestPlatform = struct {
        pub const fs = struct {
            pub fn readFile(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
                return std.fs.cwd().readFileAlloc(alloc, path, 10 * 1024 * 1024);
            }
        };
    };

    // Test that packed refs are readable
    std.debug.print("Testing packed refs resolution...\n", .{});
    
    for (0..5) |i| {
        const branch_name = try std.fmt.allocPrint(allocator, "branch{d}", .{i});
        defer allocator.free(branch_name);
        
        const commit = refs.resolveRef(git_dir, branch_name, TestPlatform, allocator) catch |err| {
            std.debug.print("Failed to resolve packed ref {s}: {}\n", .{ branch_name, err });
            return err;
        };
        if (commit) |c| {
            defer allocator.free(c);
            try testing.expect(c.len == 40);
            std.debug.print("✓ Packed ref {s} resolves to: {s}\n", .{ branch_name, c[0..8] });
        }

        const tag_name = try std.fmt.allocPrint(allocator, "v1.0.{d}", .{i});
        defer allocator.free(tag_name);
        
        const tag_commit = refs.resolveRef(git_dir, tag_name, TestPlatform, allocator) catch |err| {
            std.debug.print("Failed to resolve packed tag {s}: {}\n", .{ tag_name, err });
            return err;
        };
        if (tag_commit) |c| {
            defer allocator.free(c);
            try testing.expect(c.len == 40);
            std.debug.print("✓ Packed tag {s} resolves to: {s}\n", .{ tag_name, c[0..8] });
        }
    }

    std.debug.print("✓ All packed refs tests passed!\n", .{});
}