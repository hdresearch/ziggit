const std = @import("std");
const testing = std.testing;
const fs = std.fs;
const ChildProcess = std.process.Child;

// Test binary index format compatibility between git and ziggit
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.debug.print("Warning: memory leaked in index format tests\n", .{});
        }
    }
    const allocator = gpa.allocator();

    std.debug.print("Running Index Format Compatibility Tests...\n", .{});

    // Set up global git config for tests
    _ = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{"git", "config", "--global", "user.name", "Test User"},
    }) catch {};
    _ = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{"git", "config", "--global", "user.email", "test@example.com"},
    }) catch {};

    // Create temporary test directory
    const test_dir = try fs.cwd().makeOpenPath("test_tmp_index", .{});
    defer fs.cwd().deleteTree("test_tmp_index") catch {};

    // Test 1: Read git-created index file
    try testReadGitIndex(allocator, test_dir);

    // Test 2: Index with multiple files
    try testMultiFileIndex(allocator, test_dir);

    // Test 3: Index with nested directories
    try testNestedDirectoryIndex(allocator, test_dir);

    // Test 4: Empty index compatibility
    try testEmptyIndex(allocator, test_dir);

    std.debug.print("All index format tests passed!\n", .{});
}

fn testReadGitIndex(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    std.debug.print("Test 1: Reading git-created index file\n", .{});
    
    const repo_path = try test_dir.makeOpenPath("git_index_read", .{});
    defer test_dir.deleteTree("git_index_read") catch {};

    // Initialize repository with git
    _ = try runCommand(allocator, &.{"git", "init"}, repo_path);

    // Create and add a simple file
    try repo_path.writeFile(.{.sub_path = "simple.txt", .data = "Hello, World!\n"});
    _ = try runCommand(allocator, &.{"git", "add", "simple.txt"}, repo_path);

    // Now test that ziggit can read the git-created index
    const ziggit_status = try runZiggitCommand(allocator, &.{"status"}, repo_path);
    defer allocator.free(ziggit_status);

    std.debug.print("  ziggit successfully read git index\n", .{});
    std.debug.print("  ✓ Test 1 passed\n", .{});
}

fn testMultiFileIndex(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    std.debug.print("Test 2: Index with multiple files\n", .{});
    
    const repo_path = try test_dir.makeOpenPath("multi_file_index", .{});
    defer test_dir.deleteTree("multi_file_index") catch {};

    // Initialize repository
    _ = try runCommand(allocator, &.{"git", "init"}, repo_path);

    // Create multiple files
    try repo_path.writeFile(.{.sub_path = "file1.txt", .data = "Content 1\n"});
    try repo_path.writeFile(.{.sub_path = "file2.txt", .data = "Content 2\n"});
    try repo_path.writeFile(.{.sub_path = "file3.txt", .data = "Content 3\n"});

    // Add all files
    _ = try runCommand(allocator, &.{"git", "add", "."}, repo_path);

    // Test ziggit can read the multi-file index
    const ziggit_status = try runZiggitCommand(allocator, &.{"status"}, repo_path);
    defer allocator.free(ziggit_status);

    std.debug.print("  ziggit successfully read multi-file index\n", .{});
    std.debug.print("  ✓ Test 2 passed\n", .{});
}

fn testNestedDirectoryIndex(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    std.debug.print("Test 3: Index with nested directories\n", .{});
    
    const repo_path = try test_dir.makeOpenPath("nested_index", .{});
    defer test_dir.deleteTree("nested_index") catch {};

    // Initialize repository
    _ = try runCommand(allocator, &.{"git", "init"}, repo_path);

    // Create nested directory structure
    const subdir = try repo_path.makeOpenPath("subdir", .{});
    try subdir.writeFile(.{.sub_path = "nested.txt", .data = "Nested content\n"});
    const deep_dir = try subdir.makeOpenPath("deep", .{});
    try deep_dir.writeFile(.{.sub_path = "deep.txt", .data = "Deep content\n"});

    // Add all files
    _ = try runCommand(allocator, &.{"git", "add", "."}, repo_path);

    // Test ziggit can read the nested index
    const ziggit_status = try runZiggitCommand(allocator, &.{"status"}, repo_path);
    defer allocator.free(ziggit_status);

    std.debug.print("  ziggit successfully read nested directory index\n", .{});
    std.debug.print("  ✓ Test 3 passed\n", .{});
}

fn testEmptyIndex(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    std.debug.print("Test 4: Empty index compatibility\n", .{});
    
    const repo_path = try test_dir.makeOpenPath("empty_index", .{});
    defer test_dir.deleteTree("empty_index") catch {};

    // Initialize repository but don't add any files
    _ = try runCommand(allocator, &.{"git", "init"}, repo_path);

    // Test ziggit can read the empty index
    const ziggit_status = try runZiggitCommand(allocator, &.{"status"}, repo_path);
    defer allocator.free(ziggit_status);

    std.debug.print("  ziggit successfully read empty index\n", .{});
    std.debug.print("  ✓ Test 4 passed\n", .{});
}

fn runCommand(allocator: std.mem.Allocator, args: []const []const u8, cwd: fs.Dir) ![]u8 {
    var child = ChildProcess.init(args, allocator);
    child.cwd_dir = cwd;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    
    try child.spawn();
    
    const stdout = try child.stdout.?.reader().readAllAlloc(allocator, 8192);
    const stderr = try child.stderr.?.reader().readAllAlloc(allocator, 8192);
    defer allocator.free(stderr);
    
    const term = try child.wait();
    if (term != .Exited or term.Exited != 0) {
        std.debug.print("Command failed: {s}\n", .{stderr});
        allocator.free(stdout);
        return error.CommandFailed;
    }
    
    return stdout;
}

fn runZiggitCommand(allocator: std.mem.Allocator, args: []const []const u8, cwd: fs.Dir) ![]u8 {
    var full_args = std.ArrayList([]const u8).init(allocator);
    defer full_args.deinit();
    
    try full_args.append("/root/ziggit/zig-out/bin/ziggit");
    for (args) |arg| {
        try full_args.append(arg);
    }
    
    return runCommand(allocator, full_args.items, cwd);
}

test "index format compatibility" {
    try main();
}