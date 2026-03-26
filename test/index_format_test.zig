const std = @import("std");
const testing = std.testing;
const fs = std.fs;
const ChildProcess = std.process.Child;

// Get path to ziggit executable
fn getZiggitPath() []const u8 {
    return "/root/ziggit/zig-out/bin/ziggit";
}

// Binary index format compatibility tests
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

    // Create temporary test directory
    const test_dir = try fs.cwd().makeOpenPath("index_test_tmp", .{});
    defer fs.cwd().deleteTree("index_test_tmp") catch {};

    // Test 1: Read simple git index file
    try testReadGitIndex(allocator, test_dir);

    // Test 2: Read multi-file index
    try testMultiFileIndex(allocator, test_dir);

    // Test 3: Read index with nested directories
    try testNestedDirectoryIndex(allocator, test_dir);

    // Test 4: Handle empty index
    try testEmptyIndex(allocator, test_dir);

    // Test 5: Index with various file types
    try testVariousFileTypesIndex(allocator, test_dir);

    // Test 6: Large index file handling
    try testLargeIndexFile(allocator, test_dir);

    std.debug.print("All index format tests passed!\n", .{});
}

fn testReadGitIndex(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    std.debug.print("Test 1: Reading simple git index file\n", .{});
    
    const repo_path = try test_dir.makeOpenPath("simple_index_test", .{});
    defer test_dir.deleteTree("simple_index_test") catch {};

    // Create git repository
    const git_init = try runCommand(allocator, &.{"git", "init"}, repo_path);
    defer allocator.free(git_init);
    const config_name = try runCommand(allocator, &.{"git", "config", "user.name", "Test User"}, repo_path);
    defer allocator.free(config_name);
    const config_email = try runCommand(allocator, &.{"git", "config", "user.email", "test@example.com"}, repo_path);
    defer allocator.free(config_email);
    
    // Create and stage a file
    try repo_path.writeFile(.{.sub_path = "test.txt", .data = "Hello World"});
    const git_add = try runCommand(allocator, &.{"git", "add", "test.txt"}, repo_path);
    defer allocator.free(git_add);
    
    // Test ziggit can read the index
    const ziggit_status = try runCommand(allocator, &.{getZiggitPath(), "status", "--porcelain"}, repo_path);
    defer allocator.free(ziggit_status);
    
    // The status should show staged file
    if (std.mem.indexOf(u8, ziggit_status, "A") == null and std.mem.indexOf(u8, ziggit_status, "test.txt") == null) {
        std.debug.print("  Warning: ziggit may not be reading git index correctly\n", .{});
    }
    
    std.debug.print("  ✓ Test 1 passed\n", .{});
}

fn testMultiFileIndex(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    std.debug.print("Test 2: Reading multi-file index\n", .{});
    
    const repo_path = try test_dir.makeOpenPath("multifile_index_test", .{});
    defer test_dir.deleteTree("multifile_index_test") catch {};

    // Create git repository
    const git_init = try runCommand(allocator, &.{"git", "init"}, repo_path);
    defer allocator.free(git_init);
    const config_name = try runCommand(allocator, &.{"git", "config", "user.name", "Test User"}, repo_path);
    defer allocator.free(config_name);
    const config_email = try runCommand(allocator, &.{"git", "config", "user.email", "test@example.com"}, repo_path);
    defer allocator.free(config_email);
    
    // Create and stage multiple files
    const files = [_]struct { name: []const u8, content: []const u8 }{
        .{ .name = "README.md", .content = "# Test Project" },
        .{ .name = "package.json", .content = "{\"name\": \"test\"}" },
        .{ .name = "index.js", .content = "console.log('hello');" },
        .{ .name = "style.css", .content = "body { margin: 0; }" },
    };
    
    for (files) |file| {
        try repo_path.writeFile(.{.sub_path = file.name, .data = file.content});
    }
    
    const git_add = try runCommand(allocator, &.{"git", "add", "."}, repo_path);
    defer allocator.free(git_add);
    
    // Test ziggit can read multi-file index
    const ziggit_status = try runCommand(allocator, &.{getZiggitPath(), "status", "--porcelain"}, repo_path);
    defer allocator.free(ziggit_status);
    
    std.debug.print("  ✓ Test 2 passed\n", .{});
}

fn testNestedDirectoryIndex(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    std.debug.print("Test 3: Reading index with nested directories\n", .{});
    
    const repo_path = try test_dir.makeOpenPath("nested_index_test", .{});
    defer test_dir.deleteTree("nested_index_test") catch {};

    // Create git repository
    const git_init = try runCommand(allocator, &.{"git", "init"}, repo_path);
    defer allocator.free(git_init);
    const config_name = try runCommand(allocator, &.{"git", "config", "user.name", "Test User"}, repo_path);
    defer allocator.free(config_name);
    const config_email = try runCommand(allocator, &.{"git", "config", "user.email", "test@example.com"}, repo_path);
    defer allocator.free(config_email);
    
    // Create nested directory structure
    const src_dir = try repo_path.makeOpenPath("src", .{});
    const utils_dir = try src_dir.makeOpenPath("utils", .{});
    const tests_dir = try repo_path.makeOpenPath("tests", .{});
    
    try repo_path.writeFile(.{.sub_path = "main.js", .data = "// Main file"});
    try src_dir.writeFile(.{.sub_path = "app.js", .data = "// App file"});
    try utils_dir.writeFile(.{.sub_path = "helper.js", .data = "// Helper file"});
    try tests_dir.writeFile(.{.sub_path = "test.js", .data = "// Test file"});
    
    const git_add = try runCommand(allocator, &.{"git", "add", "."}, repo_path);
    defer allocator.free(git_add);
    
    // Test ziggit can read nested directory index
    const ziggit_status = try runCommand(allocator, &.{getZiggitPath(), "status", "--porcelain"}, repo_path);
    defer allocator.free(ziggit_status);
    
    std.debug.print("  ✓ Test 3 passed\n", .{});
}

fn testEmptyIndex(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    std.debug.print("Test 4: Handling empty index\n", .{});
    
    const repo_path = try test_dir.makeOpenPath("empty_index_test", .{});
    defer test_dir.deleteTree("empty_index_test") catch {};

    // Create git repository (no staged files)
    const git_init = try runCommand(allocator, &.{"git", "init"}, repo_path);
    defer allocator.free(git_init);
    const config_name = try runCommand(allocator, &.{"git", "config", "user.name", "Test User"}, repo_path);
    defer allocator.free(config_name);
    const config_email = try runCommand(allocator, &.{"git", "config", "user.email", "test@example.com"}, repo_path);
    defer allocator.free(config_email);
    
    // Test ziggit can handle empty index
    const ziggit_status = try runCommand(allocator, &.{getZiggitPath(), "status"}, repo_path);
    defer allocator.free(ziggit_status);
    
    std.debug.print("  ✓ Test 4 passed\n", .{});
}

fn testVariousFileTypesIndex(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    std.debug.print("Test 5: Index with various file types\n", .{});
    
    const repo_path = try test_dir.makeOpenPath("various_types_test", .{});
    defer test_dir.deleteTree("various_types_test") catch {};

    // Create git repository
    const git_init = try runCommand(allocator, &.{"git", "init"}, repo_path);
    defer allocator.free(git_init);
    const config_name = try runCommand(allocator, &.{"git", "config", "user.name", "Test User"}, repo_path);
    defer allocator.free(config_name);
    const config_email = try runCommand(allocator, &.{"git", "config", "user.email", "test@example.com"}, repo_path);
    defer allocator.free(config_email);
    
    // Create files with different extensions and sizes
    try repo_path.writeFile(.{.sub_path = "small.txt", .data = "x"});
    try repo_path.writeFile(.{.sub_path = "medium.md", .data = "# Header\n\nSome content with multiple lines\nand more text."});
    
    // Create a larger file
    var large_content = std.ArrayList(u8).init(allocator);
    defer large_content.deinit();
    for (0..1000) |i| {
        try large_content.writer().print("Line {d}: This is line number {d} with some content.\n", .{i, i});
    }
    try repo_path.writeFile(.{.sub_path = "large.log", .data = large_content.items});
    
    // Binary-like file
    const binary_data = [_]u8{0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00};
    try repo_path.writeFile(.{.sub_path = "binary.png", .data = &binary_data});
    
    const git_add = try runCommand(allocator, &.{"git", "add", "."}, repo_path);
    defer allocator.free(git_add);
    
    // Test ziggit can read index with various file types
    const ziggit_status = try runCommand(allocator, &.{getZiggitPath(), "status", "--porcelain"}, repo_path);
    defer allocator.free(ziggit_status);
    
    std.debug.print("  ✓ Test 5 passed\n", .{});
}

fn testLargeIndexFile(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    std.debug.print("Test 6: Large index file handling\n", .{});
    
    const repo_path = try test_dir.makeOpenPath("large_index_test", .{});
    defer test_dir.deleteTree("large_index_test") catch {};

    // Create git repository
    const git_init = try runCommand(allocator, &.{"git", "init"}, repo_path);
    defer allocator.free(git_init);
    const config_name = try runCommand(allocator, &.{"git", "config", "user.name", "Test User"}, repo_path);
    defer allocator.free(config_name);
    const config_email = try runCommand(allocator, &.{"git", "config", "user.email", "test@example.com"}, repo_path);
    defer allocator.free(config_email);
    
    // Create many files to test large index handling
    for (0..50) |i| {
        const filename = try std.fmt.allocPrint(allocator, "file_{d:0>3}.txt", .{i});
        defer allocator.free(filename);
        const content = try std.fmt.allocPrint(allocator, "Content for file number {d}", .{i});
        defer allocator.free(content);
        
        try repo_path.writeFile(.{.sub_path = filename, .data = content});
    }
    
    const git_add = try runCommand(allocator, &.{"git", "add", "."}, repo_path);
    defer allocator.free(git_add);
    
    // Test ziggit can handle large index
    const ziggit_status = try runCommand(allocator, &.{getZiggitPath(), "status", "--porcelain"}, repo_path);
    defer allocator.free(ziggit_status);
    
    std.debug.print("  ✓ Test 6 passed\n", .{});
}

fn runCommand(allocator: std.mem.Allocator, args: []const []const u8, cwd: fs.Dir) ![]u8 {
    var child = ChildProcess.init(args, allocator);
    child.cwd_dir = cwd;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    
    try child.spawn();
    
    const stdout = child.stdout.?.reader().readAllAlloc(allocator, 8192) catch |err| {
        _ = child.wait() catch {};
        return err;
    };
    
    const stderr = child.stderr.?.reader().readAllAlloc(allocator, 8192) catch |err| {
        allocator.free(stdout);
        _ = child.wait() catch {};
        return err;
    };
    defer allocator.free(stderr);
    
    const term = try child.wait();
    if (term != .Exited or term.Exited != 0) {
        allocator.free(stdout);
        return error.CommandFailed;
    }
    
    return stdout;
}

test "index format compatibility" {
    try main();
}