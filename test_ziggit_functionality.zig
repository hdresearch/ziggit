const std = @import("std");
const testing = std.testing;
const print = std.debug.print;

test "ziggit core functionality integration test" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Create a temporary test directory
    const test_dir = "test_ziggit_integration";
    std.fs.cwd().makeDir(test_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {
            // Clean up existing directory
            std.fs.cwd().deleteTree(test_dir) catch {};
            try std.fs.cwd().makeDir(test_dir);
        },
        else => return err,
    };
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    // Change to test directory for operations
    var dir = try std.fs.cwd().openDir(test_dir, .{});
    defer dir.close();

    print("🧪 Running ziggit integration test...\n");

    // Test 1: Repository initialization (should use .git directory)
    {
        const result = std.ChildProcess.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "zig", "run", "../src/main.zig", "--", "init" },
            .cwd = test_dir,
        }) catch return error.TestFailed;

        try testing.expect(result.term == .Exited and result.term.Exited == 0);
        try testing.expect(std.fs.cwd().access(test_dir ++ "/.git", .{}) catch false);
        print("✅ Test 1: Repository initialization with .git directory\n");
    }

    // Test 2: Add file and verify index format
    {
        // Create test file
        try std.fs.cwd().writeFile(test_dir ++ "/test_file.txt", "Hello, world!\nThis is a test.\n");

        const result = std.ChildProcess.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "zig", "run", "../src/main.zig", "--", "add", "test_file.txt" },
            .cwd = test_dir,
        }) catch return error.TestFailed;

        try testing.expect(result.term == .Exited and result.term.Exited == 0);
        
        // Verify index file exists and has correct format
        const index_data = std.fs.cwd().readFileAlloc(allocator, test_dir ++ "/.git/index", 1024) catch return error.TestFailed;
        defer allocator.free(index_data);
        
        // Check DIRC signature
        try testing.expect(std.mem.eql(u8, index_data[0..4], "DIRC"));
        
        // Check version (should be 2, big-endian)
        const version = std.mem.readInt(u32, @ptrCast(index_data[4..8]), .big);
        try testing.expect(version == 2);
        
        print("✅ Test 2: Index file with proper git binary format\n");
    }

    // Test 3: Commit and verify object creation
    {
        const result = std.ChildProcess.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "zig", "run", "../src/main.zig", "--", "commit", "-m", "Test commit" },
            .cwd = test_dir,
        }) catch return error.TestFailed;

        try testing.expect(result.term == .Exited and result.term.Exited == 0);
        
        // Verify objects directory has content
        var objects_dir = std.fs.cwd().openDir(test_dir ++ "/.git/objects", .{ .iterate = true }) catch return error.TestFailed;
        defer objects_dir.close();
        
        var iterator = objects_dir.iterate();
        var found_object = false;
        while (try iterator.next()) |entry| {
            if (entry.kind == .directory and entry.name.len == 2) {
                found_object = true;
                break;
            }
        }
        try testing.expect(found_object);
        
        print("✅ Test 3: Commit creates proper git objects\n");
    }

    // Test 4: Status command with blob content reading
    {
        // Modify the file
        try std.fs.cwd().writeFile(test_dir ++ "/test_file.txt", "Hello, world!\nThis is modified.\n");

        const result = std.ChildProcess.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "zig", "run", "../src/main.zig", "--", "status" },
            .cwd = test_dir,
        }) catch return error.TestFailed;

        try testing.expect(result.term == .Exited and result.term.Exited == 0);
        try testing.expect(result.stdout.len > 0); // Should show modified file
        
        print("✅ Test 4: Status command detects file changes\n");
    }

    // Test 5: Diff command with blob content retrieval
    {
        const result = std.ChildProcess.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "zig", "run", "../src/main.zig", "--", "diff" },
            .cwd = test_dir,
        }) catch return error.TestFailed;

        try testing.expect(result.term == .Exited and result.term.Exited == 0);
        try testing.expect(std.mem.indexOf(u8, result.stdout, "diff --git") != null);
        
        print("✅ Test 5: Diff command retrieves blob content\n");
    }

    print("🎉 All integration tests passed!\n");
}

test "ziggit git compatibility verification" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    print("🔍 Verifying git compatibility...\n");

    // Create test repository with git
    const test_dir = "test_git_compat";
    std.fs.cwd().makeDir(test_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {
            std.fs.cwd().deleteTree(test_dir) catch {};
            try std.fs.cwd().makeDir(test_dir);
        },
        else => return err,
    };
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    // Initialize with git
    {
        const result = std.ChildProcess.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "git", "init" },
            .cwd = test_dir,
        }) catch return error.TestSkipped; // Skip if git not available

        if (result.term != .Exited or result.term.Exited != 0) {
            return error.TestSkipped;
        }
    }

    // Create and commit file with git
    {
        try std.fs.cwd().writeFile(test_dir ++ "/compat_test.txt", "Git-created content\n");
        
        _ = std.ChildProcess.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "git", "add", "compat_test.txt" },
            .cwd = test_dir,
        }) catch return error.TestSkipped;
        
        _ = std.ChildProcess.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "git", "commit", "-m", "Git commit" },
            .cwd = test_dir,
        }) catch return error.TestSkipped;
    }

    // Test ziggit can read git-created repository
    {
        const result = std.ChildProcess.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "zig", "run", "../src/main.zig", "--", "status" },
            .cwd = test_dir,
        }) catch return error.TestFailed;

        try testing.expect(result.term == .Exited and result.term.Exited == 0);
        print("✅ ziggit can read git-created repository\n");
    }

    // Test ziggit can read git-created index
    {
        const result = std.ChildProcess.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "zig", "run", "../src/main.zig", "--", "log" },
            .cwd = test_dir,
        }) catch return error.TestFailed;

        try testing.expect(result.term == .Exited and result.term.Exited == 0);
        try testing.expect(std.mem.indexOf(u8, result.stdout, "Git commit") != null);
        print("✅ ziggit can read git-created commits\n");
    }

    print("🎉 Git compatibility verified!\n");
}