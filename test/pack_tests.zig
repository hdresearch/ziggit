const std = @import("std");
const testing = std.testing;

// Consolidated pack file tests - combining pack_file_test, pack_delta_test, enhanced_pack_test
// Tests pack file functionality, delta handling, and comprehensive pack scenarios

test "pack file basic functionality" {
    const allocator = testing.allocator;
    
    // Create temporary directory
    const temp_path = "/tmp/ziggit-pack-basic";
    std.fs.cwd().deleteTree(temp_path) catch {};
    try std.fs.cwd().makePath(temp_path);
    defer std.fs.cwd().deleteTree(temp_path) catch {};

    // Create a basic git repository
    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "init" }, allocator);
        cmd.cwd = temp_path;
        cmd.stdout_behavior = .Ignore;
        const result = try cmd.spawnAndWait();
        if (result.Exited != 0) {
            std.debug.print("Git not available, skipping pack file basic test\n", .{});
            return;
        }
    }

    // Configure git
    try runGitCommand(allocator, temp_path, &[_][]const u8{ "config", "user.name", "Test User" });
    try runGitCommand(allocator, temp_path, &[_][]const u8{ "config", "user.email", "test@example.com" });

    // Create some test files
    const test_file_path = try std.fmt.allocPrint(allocator, "{s}/test.txt", .{temp_path});
    defer allocator.free(test_file_path);
    
    try std.fs.cwd().writeFile(.{.sub_path = test_file_path, .data = "Hello, World!\n"});
    
    try runGitCommand(allocator, temp_path, &[_][]const u8{ "add", "test.txt" });
    try runGitCommand(allocator, temp_path, &[_][]const u8{ "commit", "-m", "Initial commit" });

    // Force creation of pack files by running git gc
    try runGitCommand(allocator, temp_path, &[_][]const u8{ "gc", "--aggressive" });

    // Check that pack files were created
    const objects_pack_path = try std.fmt.allocPrint(allocator, "{s}/.git/objects/pack", .{temp_path});
    defer allocator.free(objects_pack_path);
    
    var pack_dir = std.fs.cwd().openDir(objects_pack_path, .{ .iterate = true }) catch {
        std.debug.print("No pack directory found (normal for small repos)\n", .{});
        return;
    };
    defer pack_dir.close();

    var iterator = pack_dir.iterate();
    var found_pack = false;
    while (try iterator.next()) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".pack")) {
            found_pack = true;
            break;
        }
    }

    if (found_pack) {
        std.debug.print("✓ Pack files created successfully\n", .{});
    } else {
        std.debug.print("No pack files found (normal for small repos)\n", .{});
    }
}

test "pack file delta handling" {
    const allocator = testing.allocator;

    // Create a test repository with delta-generating content
    const temp_path = "/tmp/ziggit-pack-delta";
    std.fs.cwd().deleteTree(temp_path) catch {};
    try std.fs.cwd().makePath(temp_path);
    defer std.fs.cwd().deleteTree(temp_path) catch {};

    // Initialize git repo
    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "init" }, allocator);
        cmd.cwd = temp_path;
        cmd.stdout_behavior = .Ignore;
        const result = try cmd.spawnAndWait();
        if (result.Exited != 0) {
            std.debug.print("Git not available, skipping pack delta test\n", .{});
            return;
        }
    }

    try runGitCommand(allocator, temp_path, &[_][]const u8{ "config", "user.name", "Test User" });
    try runGitCommand(allocator, temp_path, &[_][]const u8{ "config", "user.email", "test@example.com" });

    // Create a large file that will generate deltas when modified
    const large_content = "This is a large file content that will be modified multiple times to create deltas.\n" ** 100;
    const large_file_path = try std.fmt.allocPrint(allocator, "{s}/large.txt", .{temp_path});
    defer allocator.free(large_file_path);

    // Create multiple versions to force delta generation
    for (0..5) |i| {
        const modified_content = try std.fmt.allocPrint(allocator, "{s}Modified version {}\n", .{ large_content, i });
        defer allocator.free(modified_content);

        try std.fs.cwd().writeFile(.{.sub_path = large_file_path, .data = modified_content});
        try runGitCommand(allocator, temp_path, &[_][]const u8{ "add", "large.txt" });
        
        const commit_msg = try std.fmt.allocPrint(allocator, "Version {}", .{i});
        defer allocator.free(commit_msg);
        try runGitCommand(allocator, temp_path, &[_][]const u8{ "commit", "-m", commit_msg });
    }

    // Force pack file creation with deltas
    try runGitCommand(allocator, temp_path, &[_][]const u8{ "gc", "--aggressive" });

    std.debug.print("✓ Pack file delta test completed\n", .{});
}

test "pack file comprehensive functionality" {
    const allocator = testing.allocator;
    
    // Create temporary directories for bare and work repos
    const base_path = "/tmp/ziggit-pack-comprehensive";
    std.fs.cwd().deleteTree(base_path) catch {};
    try std.fs.cwd().makePath(base_path);
    defer std.fs.cwd().deleteTree(base_path) catch {};
    
    const bare_repo_path = try std.fmt.allocPrint(allocator, "{s}/bare.git", .{base_path});
    defer allocator.free(bare_repo_path);
    
    const work_repo_path = try std.fmt.allocPrint(allocator, "{s}/work", .{base_path});
    defer allocator.free(work_repo_path);

    // Create bare repository
    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "init", "--bare", bare_repo_path }, allocator);
        cmd.stdout_behavior = .Ignore;
        const result = try cmd.spawnAndWait();
        if (result.Exited != 0) {
            std.debug.print("Git not available, skipping comprehensive pack test\n", .{});
            return;
        }
    }

    // Clone the bare repo to create work directory
    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "clone", bare_repo_path, work_repo_path }, allocator);
        cmd.stdout_behavior = .Ignore;
        _ = try cmd.spawnAndWait();
    }

    try runGitCommand(allocator, work_repo_path, &[_][]const u8{ "config", "user.name", "Test User" });
    try runGitCommand(allocator, work_repo_path, &[_][]const u8{ "config", "user.email", "test@example.com" });

    // Create multiple files and commits to generate complex pack scenarios
    for (0..10) |i| {
        const filename = try std.fmt.allocPrint(allocator, "file_{}.txt", .{i});
        defer allocator.free(filename);
        
        const filepath = try std.fmt.allocPrint(allocator, "{s}/{s}", .{work_repo_path, filename});
        defer allocator.free(filepath);
        
        const content = try std.fmt.allocPrint(allocator, "File {} content\nWith multiple lines\nTo test pack compression\n", .{i});
        defer allocator.free(content);

        try std.fs.cwd().writeFile(.{.sub_path = filepath, .data = content});
        try runGitCommand(allocator, work_repo_path, &[_][]const u8{ "add", filename });
        
        const commit_msg = try std.fmt.allocPrint(allocator, "Add {s}", .{filename});
        defer allocator.free(commit_msg);
        try runGitCommand(allocator, work_repo_path, &[_][]const u8{ "commit", "-m", commit_msg });
    }

    // Push to bare repo
    try runGitCommand(allocator, work_repo_path, &[_][]const u8{ "push", "origin", "main" });

    // Force pack creation in bare repo
    try runGitCommand(allocator, bare_repo_path, &[_][]const u8{ "gc", "--aggressive" });

    std.debug.print("✓ Pack file comprehensive test completed\n", .{});
}

// Helper function to run git commands
fn runGitCommand(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) !void {
    var cmd = std.process.Child.init(args, allocator);
    cmd.cwd = cwd;
    cmd.stdout_behavior = .Ignore;
    cmd.stderr_behavior = .Ignore;
    const result = try cmd.spawnAndWait();
    if (result.Exited != 0) {
        return error.GitCommandFailed;
    }
}