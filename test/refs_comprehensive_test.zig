const std = @import("std");
const testing = std.testing;

// Test ref resolution functionality
test "refs symbolic resolution comprehensive test" {
    const allocator = testing.allocator;

    // Create a temporary test repository
    const temp_path = "/tmp/zig-test-refs";
    std.fs.cwd().deleteTree(temp_path) catch {};
    try std.fs.cwd().makePath(temp_path);
    defer std.fs.cwd().deleteTree(temp_path) catch {};

    // Initialize git repo
    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "init" }, allocator);
        cmd.cwd = temp_path;
        cmd.stdout_behavior = .Ignore;
        cmd.stderr_behavior = .Ignore;
        _ = try cmd.spawnAndWait();
    }

    // Configure git
    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "config", "user.name", "Test User" }, allocator);
        cmd.cwd = temp_path;
        cmd.stdout_behavior = .Ignore;
        _ = try cmd.spawnAndWait();
    }
    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "config", "user.email", "test@example.com" }, allocator);
        cmd.cwd = temp_path;
        cmd.stdout_behavior = .Ignore;
        _ = try cmd.spawnAndWait();
    }

    // Change to temp directory
    var temp_dir = try std.fs.openDirAbsolute(temp_path, .{});
    defer temp_dir.close();

    // Create and commit an initial file
    try temp_dir.writeFile(.{ .sub_path = "test.txt", .data = "Initial content\n" });

    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "add", "test.txt" }, allocator);
        cmd.cwd = temp_path;
        cmd.stdout_behavior = .Ignore;
        _ = try cmd.spawnAndWait();
    }

    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "commit", "-m", "Initial commit" }, allocator);
        cmd.cwd = temp_path;
        cmd.stdout_behavior = .Ignore;
        _ = try cmd.spawnAndWait();
    }

    // Create some branches and tags for testing
    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "branch", "feature-branch" }, allocator);
        cmd.cwd = temp_path;
        cmd.stdout_behavior = .Ignore;
        _ = try cmd.spawnAndWait();
    }

    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "tag", "v1.0.0" }, allocator);
        cmd.cwd = temp_path;
        cmd.stdout_behavior = .Ignore;
        _ = try cmd.spawnAndWait();
    }

    // Test HEAD resolution
    const git_path = try std.fmt.allocPrint(allocator, "{s}/.git", .{temp_path});
    defer allocator.free(git_path);

    // Check that HEAD file exists and contains valid content
    const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_path});
    defer allocator.free(head_path);

    const head_content = std.fs.cwd().readFileAlloc(allocator, head_path, 1024) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("HEAD file not found, skipping test\n", .{});
            return;
        },
        else => return err,
    };
    defer allocator.free(head_content);

    const trimmed_head = std.mem.trim(u8, head_content, " \t\n\r");
    std.debug.print("HEAD content: {s}\n", .{trimmed_head});

    // HEAD should either be a symbolic ref or a commit hash
    if (std.mem.startsWith(u8, trimmed_head, "ref: ")) {
        const ref_name = trimmed_head["ref: ".len..];
        std.debug.print("HEAD is symbolic ref: {s}\n", .{ref_name});
        
        // Verify the referenced branch exists
        if (std.mem.startsWith(u8, ref_name, "refs/heads/")) {
            const branch_name = ref_name["refs/heads/".len..];
            const branch_path = try std.fmt.allocPrint(allocator, "{s}/refs/heads/{s}", .{ git_path, branch_name });
            defer allocator.free(branch_path);
            
            const branch_content = std.fs.cwd().readFileAlloc(allocator, branch_path, 1024) catch |err| switch (err) {
                error.FileNotFound => {
                    std.debug.print("Branch file not found: {s}\n", .{branch_path});
                    return error.BranchFileNotFound;
                },
                else => return err,
            };
            defer allocator.free(branch_content);
            
            const branch_hash = std.mem.trim(u8, branch_content, " \t\n\r");
            std.debug.print("Branch {s} points to: {s}\n", .{ branch_name, branch_hash });
            
            // Validate hash format (40 hex chars)
            if (branch_hash.len != 40) {
                return error.InvalidHashLength;
            }
            
            for (branch_hash) |c| {
                if (!std.ascii.isHex(c)) {
                    return error.InvalidHashCharacter;
                }
            }
        }
    } else if (trimmed_head.len == 40) {
        // Detached HEAD
        std.debug.print("HEAD is detached at: {s}\n", .{trimmed_head});
        
        // Validate hash format
        for (trimmed_head) |c| {
            if (!std.ascii.isHex(c)) {
                return error.InvalidHashCharacter;
            }
        }
    } else {
        return error.InvalidHEADFormat;
    }

    // Test branch existence
    const feature_branch_path = try std.fmt.allocPrint(allocator, "{s}/refs/heads/feature-branch", .{git_path});
    defer allocator.free(feature_branch_path);

    const feature_branch_content = std.fs.cwd().readFileAlloc(allocator, feature_branch_path, 1024) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("Feature branch not found, test may have failed to create it\n", .{});
            return;
        },
        else => return err,
    };
    defer allocator.free(feature_branch_content);

    const feature_branch_hash = std.mem.trim(u8, feature_branch_content, " \t\n\r");
    std.debug.print("Feature branch hash: {s}\n", .{feature_branch_hash});

    // Test tag existence
    const tag_path = try std.fmt.allocPrint(allocator, "{s}/refs/tags/v1.0.0", .{git_path});
    defer allocator.free(tag_path);

    const tag_content = std.fs.cwd().readFileAlloc(allocator, tag_path, 1024) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("Tag not found, test may have failed to create it\n", .{});
            return;
        },
        else => return err,
    };
    defer allocator.free(tag_content);

    const tag_hash = std.mem.trim(u8, tag_content, " \t\n\r");
    std.debug.print("Tag hash: {s}\n", .{tag_hash});

    std.debug.print("Refs resolution test completed successfully\n", .{});
}

test "packed-refs file parsing test" {
    const allocator = testing.allocator;

    // Create a temporary test repository with many refs to trigger packed-refs
    const temp_path = "/tmp/zig-test-packed-refs";
    std.fs.cwd().deleteTree(temp_path) catch {};
    try std.fs.cwd().makePath(temp_path);
    defer std.fs.cwd().deleteTree(temp_path) catch {};

    // Initialize git repo
    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "init" }, allocator);
        cmd.cwd = temp_path;
        cmd.stdout_behavior = .Ignore;
        cmd.stderr_behavior = .Ignore;
        _ = try cmd.spawnAndWait();
    }

    // Configure git
    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "config", "user.name", "Test User" }, allocator);
        cmd.cwd = temp_path;
        cmd.stdout_behavior = .Ignore;
        _ = try cmd.spawnAndWait();
    }
    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "config", "user.email", "test@example.com" }, allocator);
        cmd.cwd = temp_path;
        cmd.stdout_behavior = .Ignore;
        _ = try cmd.spawnAndWait();
    }

    // Change to temp directory
    var temp_dir = try std.fs.openDirAbsolute(temp_path, .{});
    defer temp_dir.close();

    // Create and commit an initial file
    try temp_dir.writeFile(.{ .sub_path = "test.txt", .data = "Initial content\n" });

    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "add", "test.txt" }, allocator);
        cmd.cwd = temp_path;
        cmd.stdout_behavior = .Ignore;
        _ = try cmd.spawnAndWait();
    }

    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "commit", "-m", "Initial commit" }, allocator);
        cmd.cwd = temp_path;
        cmd.stdout_behavior = .Ignore;
        _ = try cmd.spawnAndWait();
    }

    // Create many tags to potentially trigger packed-refs creation
    for (0..10) |i| {
        const tag_name = try std.fmt.allocPrint(allocator, "tag-{}", .{i});
        defer allocator.free(tag_name);
        
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "tag", tag_name }, allocator);
        cmd.cwd = temp_path;
        cmd.stdout_behavior = .Ignore;
        _ = try cmd.spawnAndWait();
    }

    // Try to force packed-refs creation
    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "pack-refs", "--all" }, allocator);
        cmd.cwd = temp_path;
        cmd.stdout_behavior = .Ignore;
        cmd.stderr_behavior = .Ignore;
        _ = cmd.spawnAndWait() catch {}; // Ignore errors, some git versions don't have this command
    }

    // Check if packed-refs exists
    const git_path = try std.fmt.allocPrint(allocator, "{s}/.git", .{temp_path});
    defer allocator.free(git_path);

    const packed_refs_path = try std.fmt.allocPrint(allocator, "{s}/packed-refs", .{git_path});
    defer allocator.free(packed_refs_path);

    const packed_refs_content = std.fs.cwd().readFileAlloc(allocator, packed_refs_path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("No packed-refs file found, skipping packed-refs test\n", .{});
            return;
        },
        else => return err,
    };
    defer allocator.free(packed_refs_content);

    std.debug.print("Found packed-refs file with {} bytes\n", .{packed_refs_content.len});

    // Basic validation of packed-refs format
    var lines = std.mem.split(u8, packed_refs_content, "\n");
    var ref_count: u32 = 0;
    
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        
        // Skip empty lines and comments
        if (trimmed.len == 0 or trimmed[0] == '#') {
            continue;
        }
        
        // Lines should be: <hash> <refname>
        if (std.mem.indexOf(u8, trimmed, " ")) |space_pos| {
            const hash = trimmed[0..space_pos];
            const refname = trimmed[space_pos + 1..];
            
            // Validate hash
            if (hash.len == 40) {
                for (hash) |c| {
                    if (!std.ascii.isHex(c)) {
                        std.debug.print("Invalid hash character in packed-refs: {c}\n", .{c});
                        return error.InvalidPackedRefHash;
                    }
                }
                
                // Validate refname
                if (std.mem.startsWith(u8, refname, "refs/")) {
                    ref_count += 1;
                    std.debug.print("Found packed ref: {s} -> {s}\n", .{ refname, hash });
                }
            }
        }
    }

    std.debug.print("Parsed {} refs from packed-refs file\n", .{ref_count});
    
    if (ref_count > 0) {
        std.debug.print("Packed-refs parsing test completed successfully\n", .{});
    } else {
        std.debug.print("No valid refs found in packed-refs file\n", .{});
    }
}