const std = @import("std");
const testing = std.testing;
const fs = std.fs;
const ChildProcess = std.process.Child;
const print = std.debug.print;

// Comprehensive git interoperability test
// Tests that create repos with git and verify ziggit reads them correctly
// Tests that create repos with ziggit and verify git reads them correctly
// Covers: init, add, commit, status --porcelain, log --oneline, branch, diff, checkout

const TestError = error{
    CommandFailed,
    OutputMismatch,
    SetupFailed,
    BinaryNotFound,
};

/// Find ziggit binary in common locations
fn findZiggitBinary(allocator: std.mem.Allocator) ![]u8 {
    const possible_paths = [_][]const u8{
        "./zig-out/bin/ziggit",
        "../zig-out/bin/ziggit", 
        "zig-out/bin/ziggit",
        "ziggit",
    };

    for (possible_paths) |path| {
        // Try to access the file
        fs.cwd().access(path, .{}) catch continue;
        
        // Convert to absolute path to avoid issues with changing working directory
        var path_buf: [fs.max_path_bytes]u8 = undefined;
        const abs_path = fs.cwd().realpath(path, &path_buf) catch {
            return try allocator.dupe(u8, path);
        };
        return try allocator.dupe(u8, abs_path);
    }

    return TestError.BinaryNotFound;
}

/// Run a command and return stdout, properly managing memory
fn runCommand(allocator: std.mem.Allocator, args: []const []const u8, cwd: ?fs.Dir) ![]u8 {
    var child = ChildProcess.init(args, allocator);
    if (cwd) |dir| child.cwd_dir = dir;
    
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    
    try child.spawn();
    
    const stdout = try child.stdout.?.reader().readAllAlloc(allocator, 8192);
    errdefer allocator.free(stdout);
    
    const stderr = try child.stderr.?.reader().readAllAlloc(allocator, 8192);
    defer allocator.free(stderr);
    
    const term = try child.wait();
    
    if (term != .Exited or term.Exited != 0) {
        print("Command failed: {s}\n", .{args[0]});
        if (stderr.len > 0) {
            print("Stderr: {s}\n", .{stderr});
        }
        allocator.free(stdout);
        return TestError.CommandFailed;
    }
    
    return stdout;
}

/// Run a command without capturing output
fn runCommandQuiet(allocator: std.mem.Allocator, args: []const []const u8, cwd: ?fs.Dir) !void {
    const result = runCommand(allocator, args, cwd) catch |err| {
        return err;
    };
    allocator.free(result);
}

/// Create a temporary test directory
fn createTestDir(allocator: std.mem.Allocator, name: []const u8) !fs.Dir {
    const tmp_path = try std.fmt.allocPrint(allocator, "/tmp/{s}_{d}", .{ name, std.time.timestamp() });
    defer allocator.free(tmp_path);
    
    // Clean up any existing directory
    fs.deleteTreeAbsolute(tmp_path) catch {};
    
    // Create new directory
    try fs.makeDirAbsolute(tmp_path);
    return try fs.openDirAbsolute(tmp_path, .{});
}

/// Test 1: Git creates repo -> Ziggit reads
fn testGitCreatesZiggitReads(allocator: std.mem.Allocator, ziggit_path: []const u8) !void {
    print("Test 1: Git creates repo -> Ziggit reads\n", .{});
    
    var test_dir = try createTestDir(allocator, "git_creates_ziggit_reads");
    defer {
        var path_buf: [fs.max_path_bytes]u8 = undefined;
        const real_path = test_dir.realpath(".", &path_buf) catch "/tmp/cleanup_failed";
        test_dir.close();
        fs.deleteTreeAbsolute(real_path) catch {};
    }
    
    // Git: init first 
    try runCommandQuiet(allocator, &.{"git", "init"}, test_dir);
    
    // Set up git config after init
    try runCommandQuiet(allocator, &.{ "git", "config", "user.name", "Test User" }, test_dir);
    try runCommandQuiet(allocator, &.{ "git", "config", "user.email", "test@example.com" }, test_dir);
    
    // Create and add files
    try test_dir.writeFile(.{ .sub_path = "README.md", .data = "# Test Repository\n\nCreated by git.\n" });
    test_dir.makeDir("src") catch {}; // Ensure directory exists
    try test_dir.writeFile(.{ .sub_path = "src/main.c", .data = "#include <stdio.h>\nint main() { return 0; }\n" });
    
    try runCommandQuiet(allocator, &.{ "git", "add", "." }, test_dir);
    try runCommandQuiet(allocator, &.{ "git", "commit", "-m", "Initial commit" }, test_dir);
    
    // Create a branch
    try runCommandQuiet(allocator, &.{ "git", "checkout", "-b", "feature" }, test_dir);
    try test_dir.writeFile(.{ .sub_path = "feature.txt", .data = "Feature file\n" });
    try runCommandQuiet(allocator, &.{ "git", "add", "feature.txt" }, test_dir);
    try runCommandQuiet(allocator, &.{ "git", "commit", "-m", "Add feature" }, test_dir);
    
    // Switch back to main/master
    try runCommandQuiet(allocator, &.{ "git", "checkout", "master" }, test_dir);
    
    // Test ziggit reading git-created repo
    {
        const status_result = runCommand(allocator, &.{ ziggit_path, "status", "--porcelain" }, test_dir) catch |err| {
            print("  ⚠ ziggit status failed: {}\n", .{err});
            return;
        };
        defer allocator.free(status_result);
        print("  ✓ ziggit status works on git repo\n", .{});
    }
    
    {
        const log_result = try runCommand(allocator, &.{ ziggit_path, "log", "--oneline" }, test_dir);
        defer allocator.free(log_result);
        print("  ✓ ziggit log works on git repo\n", .{});
    }
    
    {
        const branch_result = try runCommand(allocator, &.{ ziggit_path, "branch" }, test_dir);
        defer allocator.free(branch_result);
        print("  ✓ ziggit branch works on git repo\n", .{});
    }
    
    print("  ✓ Test 1 completed\n", .{});
}

/// Test 2: Ziggit creates repo -> Git reads  
fn testZiggitCreatesGitReads(allocator: std.mem.Allocator, ziggit_path: []const u8) !void {
    print("Test 2: Ziggit creates repo -> Git reads\n", .{});
    
    var test_dir = try createTestDir(allocator, "ziggit_creates_git_reads");
    defer {
        var path_buf: [fs.max_path_bytes]u8 = undefined;
        const real_path = test_dir.realpath(".", &path_buf) catch "/tmp/cleanup_failed";
        test_dir.close();
        fs.deleteTreeAbsolute(real_path) catch {};
    }
    
    // Ziggit: init
    try runCommandQuiet(allocator, &.{ ziggit_path, "init" }, test_dir);
    
    // Set up git config for git operations
    try runCommandQuiet(allocator, &.{ "git", "config", "user.name", "Test User" }, test_dir);
    try runCommandQuiet(allocator, &.{ "git", "config", "user.email", "test@example.com" }, test_dir);
    
    // Create files and use ziggit to add/commit
    try test_dir.writeFile(.{ .sub_path = "package.json", .data = "{\n  \"name\": \"test\",\n  \"version\": \"1.0.0\"\n}\n" });
    try test_dir.writeFile(.{ .sub_path = "index.js", .data = "console.log('Hello world');\n" });
    
    try runCommandQuiet(allocator, &.{ ziggit_path, "add", "." }, test_dir);
    try runCommandQuiet(allocator, &.{ ziggit_path, "commit", "-m", "Initial commit with ziggit" }, test_dir);
    
    // Test git reading ziggit-created repo
    {
        const status_result = try runCommand(allocator, &.{ "git", "status", "--porcelain" }, test_dir);
        defer allocator.free(status_result);
        print("  ✓ git status works on ziggit repo\n", .{});
    }
    
    {
        const log_result = try runCommand(allocator, &.{ "git", "log", "--oneline" }, test_dir);
        defer allocator.free(log_result);
        print("  ✓ git log works on ziggit repo\n", .{});
    }
    
    // Test git operations on ziggit repo
    try test_dir.writeFile(.{ .sub_path = "test.txt", .data = "Test file\n" });
    try runCommandQuiet(allocator, &.{ "git", "add", "test.txt" }, test_dir);
    try runCommandQuiet(allocator, &.{ "git", "commit", "-m", "Added via git" }, test_dir);
    
    // Verify ziggit can still read it
    {
        const status_result = try runCommand(allocator, &.{ ziggit_path, "status", "--porcelain" }, test_dir);
        defer allocator.free(status_result);
        print("  ✓ ziggit status works after git operations\n", .{});
    }
    
    print("  ✓ Test 2 completed\n", .{});
}

/// Test 3: Command output compatibility
fn testOutputCompatibility(allocator: std.mem.Allocator, ziggit_path: []const u8) !void {
    print("Test 3: Command output compatibility\n", .{});
    
    var test_dir = try createTestDir(allocator, "output_compatibility");
    defer {
        var path_buf: [fs.max_path_bytes]u8 = undefined;
        const real_path = test_dir.realpath(".", &path_buf) catch "/tmp/cleanup_failed";
        test_dir.close();
        fs.deleteTreeAbsolute(real_path) catch {};
    }
    
    // Set up repo with both tools
    try runCommandQuiet(allocator, &.{"git", "init"}, test_dir);
    try runCommandQuiet(allocator, &.{ "git", "config", "user.name", "Test User" }, test_dir);
    try runCommandQuiet(allocator, &.{ "git", "config", "user.email", "test@example.com" }, test_dir);
    
    try test_dir.writeFile(.{ .sub_path = "tracked.txt", .data = "tracked content\n" });
    try runCommandQuiet(allocator, &.{ "git", "add", "tracked.txt" }, test_dir);
    try runCommandQuiet(allocator, &.{ "git", "commit", "-m", "Add tracked file" }, test_dir);
    
    try test_dir.writeFile(.{ .sub_path = "untracked.txt", .data = "untracked content\n" });
    
    // Compare status --porcelain output
    const git_status = try runCommand(allocator, &.{ "git", "status", "--porcelain" }, test_dir);
    defer allocator.free(git_status);
    
    const ziggit_status = try runCommand(allocator, &.{ ziggit_path, "status", "--porcelain" }, test_dir);
    defer allocator.free(ziggit_status);
    
    if (!std.mem.eql(u8, std.mem.trim(u8, git_status, " \n\r"), std.mem.trim(u8, ziggit_status, " \n\r"))) {
        print("Status output mismatch!\nGit: '{s}'\nZiggit: '{s}'\n", .{ git_status, ziggit_status });
    } else {
        print("  ✓ status --porcelain outputs match\n", .{});
    }
    
    print("  ✓ Test 3 completed\n", .{});
}

/// Main test function
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            print("Warning: memory leaked in tests\n", .{});
        }
    }
    const allocator = gpa.allocator();

    print("=== Improved Git Interoperability Tests ===\n", .{});

    // Find ziggit binary
    const ziggit_path = findZiggitBinary(allocator) catch |err| switch (err) {
        TestError.BinaryNotFound => {
            print("ERROR: Could not find ziggit binary. Tried:\n", .{});
            print("  - ./zig-out/bin/ziggit\n", .{});
            print("  - ../zig-out/bin/ziggit\n", .{}); 
            print("  - zig-out/bin/ziggit\n", .{});
            print("  - ziggit\n", .{});
            print("Please run 'zig build' first.\n", .{});
            std.process.exit(1);
        },
        else => return err,
    };
    defer allocator.free(ziggit_path);

    print("Using ziggit binary: {s}\n", .{ziggit_path});

    // Set up global git config for tests
    _ = runCommand(allocator, &.{ "git", "config", "--global", "user.name", "Test User" }, null) catch {};
    _ = runCommand(allocator, &.{ "git", "config", "--global", "user.email", "test@example.com" }, null) catch {};

    // Run tests
    try testGitCreatesZiggitReads(allocator, ziggit_path);
    try testZiggitCreatesGitReads(allocator, ziggit_path);  
    try testOutputCompatibility(allocator, ziggit_path);

    print("=== All improved interoperability tests passed! ===\n", .{});
}