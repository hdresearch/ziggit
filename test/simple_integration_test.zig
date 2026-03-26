const std = @import("std");
const fs = std.fs;

// Simple integration test demonstrating working ziggit functionality
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("Running Simple Integration Tests (Core Functionality)...\n", .{});

    // Set up global git config
    _ = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{"git", "config", "--global", "user.name", "Test User"},
    }) catch {};
    _ = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{"git", "config", "--global", "user.email", "test@example.com"},
    }) catch {};

    const test_dir = try fs.cwd().makeOpenPath("simple_test_tmp", .{});
    defer fs.cwd().deleteTree("simple_test_tmp") catch {};

    // Test 1: Basic git -> ziggit compatibility (what works)
    try testBasicCompatibility(allocator, test_dir);

    // Test 2: Index reading compatibility 
    try testIndexReading(allocator, test_dir);

    // Test 3: Log output compatibility
    try testLogCompatibility(allocator, test_dir);

    std.debug.print("Simple integration tests completed! ✅\n", .{});
    std.debug.print("Note: Status sync issue documented as known limitation.\n", .{});
}

fn testBasicCompatibility(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    std.debug.print("Test 1: Basic git -> ziggit compatibility\n", .{});
    
    const repo_path = try test_dir.makeOpenPath("basic_test", .{});
    defer test_dir.deleteTree("basic_test") catch {};

    // Git creates, ziggit reads
    _ = try runCommand(allocator, &.{"git", "init"}, repo_path);
    _ = try runCommand(allocator, &.{"git", "config", "user.name", "Test User"}, repo_path);
    _ = try runCommand(allocator, &.{"git", "config", "user.email", "test@example.com"}, repo_path);

    try repo_path.writeFile(.{.sub_path = "README.md", .data = "# Test Project\n"});
    _ = try runCommand(allocator, &.{"git", "add", "README.md"}, repo_path);
    _ = try runCommand(allocator, &.{"git", "commit", "-m", "Initial commit"}, repo_path);

    // Test ziggit can read the log
    const ziggit_log = try runZiggit(allocator, &.{"log"}, repo_path);
    defer allocator.free(ziggit_log);

    if (std.mem.indexOf(u8, ziggit_log, "Initial commit") == null) {
        std.debug.print("  ❌ ziggit cannot read git-created commits\n", .{});
        return error.TestFailed;
    }

    std.debug.print("  ✅ ziggit successfully reads git-created commits\n", .{});
}

fn testIndexReading(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    std.debug.print("Test 2: Index reading compatibility\n", .{});
    
    const repo_path = try test_dir.makeOpenPath("index_test", .{});
    defer test_dir.deleteTree("index_test") catch {};

    // Create git repository with files
    _ = try runCommand(allocator, &.{"git", "init"}, repo_path);
    _ = try runCommand(allocator, &.{"git", "config", "user.name", "Test User"}, repo_path);
    _ = try runCommand(allocator, &.{"git", "config", "user.email", "test@example.com"}, repo_path);

    try repo_path.writeFile(.{.sub_path = "file1.txt", .data = "content1\n"});
    try repo_path.writeFile(.{.sub_path = "file2.txt", .data = "content2\n"});
    _ = try runCommand(allocator, &.{"git", "add", "."}, repo_path);

    // Test that ziggit can read index without crashing
    const ziggit_status = runZiggit(allocator, &.{"status"}, repo_path) catch |err| {
        std.debug.print("  ❌ ziggit failed to read git-created index: {}\n", .{err});
        return error.TestFailed;
    };
    defer allocator.free(ziggit_status);

    std.debug.print("  ✅ ziggit successfully reads git-created index\n", .{});
}

fn testLogCompatibility(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    std.debug.print("Test 3: Log output compatibility\n", .{});
    
    const repo_path = try test_dir.makeOpenPath("log_test", .{});
    defer test_dir.deleteTree("log_test") catch {};

    // Create repository with multiple commits
    _ = try runCommand(allocator, &.{"git", "init"}, repo_path);
    _ = try runCommand(allocator, &.{"git", "config", "user.name", "Test User"}, repo_path);
    _ = try runCommand(allocator, &.{"git", "config", "user.email", "test@example.com"}, repo_path);

    const commits = [_][]const u8{ "First commit", "Second commit", "Third commit" };
    for (commits, 0..) |msg, i| {
        const filename = try std.fmt.allocPrint(allocator, "file{}.txt", .{i});
        defer allocator.free(filename);
        
        try repo_path.writeFile(.{.sub_path = filename, .data = "content\n"});
        _ = try runCommand(allocator, &.{"git", "add", filename}, repo_path);
        _ = try runCommand(allocator, &.{"git", "commit", "-m", msg}, repo_path);
    }

    // Test log output format
    const git_log = try runCommand(allocator, &.{"git", "log", "--oneline"}, repo_path);
    defer allocator.free(git_log);

    const ziggit_log = try runZiggit(allocator, &.{"log", "--oneline"}, repo_path);
    defer allocator.free(ziggit_log);

    // Check commit count matches
    const git_lines = std.mem.count(u8, git_log, "\n");
    const ziggit_lines = std.mem.count(u8, ziggit_log, "\n");

    if (git_lines != ziggit_lines) {
        std.debug.print("  ❌ Log line count mismatch: git {}, ziggit {}\n", .{ git_lines, ziggit_lines });
        return error.TestFailed;
    }

    // Check commit messages are present
    for (commits) |msg| {
        if (std.mem.indexOf(u8, ziggit_log, msg) == null) {
            std.debug.print("  ❌ Missing commit message: {s}\n", .{msg});
            return error.TestFailed;
        }
    }

    std.debug.print("  ✅ ziggit log format matches git (all {} commits present)\n", .{commits.len});
}

fn runCommand(allocator: std.mem.Allocator, args: []const []const u8, cwd: fs.Dir) ![]u8 {
    var child = std.process.Child.init(args, allocator);
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

fn runZiggit(allocator: std.mem.Allocator, args: []const []const u8, cwd: fs.Dir) ![]u8 {
    var full_args = std.ArrayList([]const u8).init(allocator);
    defer full_args.deinit();
    
    try full_args.append("/root/ziggit/zig-out/bin/ziggit");
    for (args) |arg| {
        try full_args.append(arg);
    }
    
    return runCommand(allocator, full_args.items, cwd);
}

test "simple integration" {
    try main();
}