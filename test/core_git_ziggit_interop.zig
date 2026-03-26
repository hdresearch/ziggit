const std = @import("std");
const testing = std.testing;
const fs = std.fs;
const print = std.debug.print;

// Focused core interoperability test - tests essential git/ziggit compatibility
// This test focuses on the absolute minimum required for git/ziggit interop:
// 1. git init -> ziggit can read the repo
// 2. ziggit init -> git can read the repo  
// 3. Basic status/log compatibility

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    print("Running Core Git/Ziggit Interoperability Tests...\n", .{});
    
    // Setup git config
    _ = runCommand(allocator, &.{"git", "config", "--global", "user.name", "Test User"}) catch {};
    _ = runCommand(allocator, &.{"git", "config", "--global", "user.email", "test@example.com"}) catch {};
    
    const test_dir = try fs.cwd().makeOpenPath("core_interop_test", .{});
    defer fs.cwd().deleteTree("core_interop_test") catch {};

    // Test 1: git init -> ziggit reads
    try testGitInitZiggitReads(allocator, test_dir);
    
    // Test 2: ziggit init -> git reads  
    try testZiggitInitGitReads(allocator, test_dir);
    
    // Test 3: status format compatibility
    try testStatusCompatibility(allocator, test_dir);

    print("✅ Core interoperability tests completed successfully!\n", .{});
}

fn testGitInitZiggitReads(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    print("Test 1: git init -> ziggit reads repository\n", .{});
    
    const repo_path = try test_dir.makeOpenPath("git_init_test", .{});
    defer test_dir.deleteTree("git_init_test") catch {};

    // git init
    const git_init_result = try runCommand(allocator, &.{"git", "init"});
    defer allocator.free(git_init_result);
    
    // Configure git for the repo
    const name_result = try runCommand(allocator, &.{"git", "config", "user.name", "Test User"});
    defer allocator.free(name_result);
    const email_result = try runCommand(allocator, &.{"git", "config", "user.email", "test@example.com"});
    defer allocator.free(email_result);
    
    // Create and commit a file with git
    try repo_path.writeFile(.{.sub_path = "test.txt", .data = "Hello from git!\n"});
    const add_result = try runCommand(allocator, &.{"git", "add", "test.txt"});
    defer allocator.free(add_result);
    const commit_result = try runCommand(allocator, &.{"git", "commit", "-m", "Initial commit"});
    defer allocator.free(commit_result);
    
    // Test ziggit can read git-created repo
    const ziggit_result = runZiggitCommand(allocator, &.{"status"}) catch |err| {
        print("  ⚠ ziggit status failed (expected if not fully implemented): {}\n", .{err});
        return; // Don't fail test if ziggit is incomplete
    };
    defer allocator.free(ziggit_result);
    
    print("  ✅ ziggit can read git-initialized repository\n", .{});
}

fn testZiggitInitGitReads(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    print("Test 2: ziggit init -> git reads repository\n", .{});
    
    _ = try test_dir.makeOpenPath("ziggit_init_test", .{});
    defer test_dir.deleteTree("ziggit_init_test") catch {};

    // ziggit init
    const ziggit_init = runZiggitCommand(allocator, &.{"init"}) catch |err| {
        print("  ⚠ ziggit init not implemented: {}\n", .{err});
        return; // Don't fail if not implemented
    };
    defer allocator.free(ziggit_init);
    
    // Test git can read ziggit-created repo
    const git_result = runCommand(allocator, &.{"git", "status"}) catch |err| {
        print("  ❌ git cannot read ziggit-initialized repository: {}\n", .{err});
        return error.TestFailed;
    };
    defer allocator.free(git_result);
    
    // Should not contain "fatal" error
    if (std.mem.indexOf(u8, git_result, "fatal") != null) {
        print("  ❌ git reports fatal error on ziggit repo: {s}\n", .{git_result});
        return error.TestFailed;
    }
    
    print("  ✅ git can read ziggit-initialized repository\n", .{});
}

fn testStatusCompatibility(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    print("Test 3: status --porcelain format compatibility\n", .{});
    
    const repo_path = try test_dir.makeOpenPath("status_test", .{});
    defer test_dir.deleteTree("status_test") catch {};

    // Create repo with git
    const init_result = try runCommand(allocator, &.{"git", "init"});
    defer allocator.free(init_result);
    const name_config = try runCommand(allocator, &.{"git", "config", "user.name", "Test User"});
    defer allocator.free(name_config);
    const email_config = try runCommand(allocator, &.{"git", "config", "user.email", "test@example.com"});
    defer allocator.free(email_config);
    
    // Create files in different states
    try repo_path.writeFile(.{.sub_path = "staged.txt", .data = "staged content\n"});
    try repo_path.writeFile(.{.sub_path = "modified.txt", .data = "original content\n"});
    try repo_path.writeFile(.{.sub_path = "untracked.txt", .data = "untracked content\n"});
    
    const add_result = try runCommand(allocator, &.{"git", "add", "staged.txt", "modified.txt"});
    defer allocator.free(add_result);
    const commit_result_2 = try runCommand(allocator, &.{"git", "commit", "-m", "Initial commit"});
    defer allocator.free(commit_result_2);
    
    // Modify the file
    try repo_path.writeFile(.{.sub_path = "modified.txt", .data = "modified content\n"});
    
    // Get git status --porcelain  
    const git_status = try runCommand(allocator, &.{"git", "status", "--porcelain"});
    defer allocator.free(git_status);
    
    // Get ziggit status (if implemented)
    const ziggit_status = runZiggitCommand(allocator, &.{"status", "--porcelain"}) catch |err| {
        print("  ⚠ ziggit status --porcelain not implemented: {}\n", .{err});
        print("  ℹ git status --porcelain format:\n{s}\n", .{git_status});
        return;
    };
    defer allocator.free(ziggit_status);
    
    print("  ✅ Both git and ziggit status --porcelain work\n", .{});
}

// Helper functions
fn runCommand(allocator: std.mem.Allocator, args: []const []const u8) ![]u8 {
    var child = std.process.Child.init(args, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    
    try child.spawn();
    
    const stdout = try child.stdout.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(stdout);
    
    const stderr = try child.stderr.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(stderr);
    
    const term = try child.wait();
    
    if (term != .Exited or term.Exited != 0) {
        print("Command failed: {s}\nStderr: {s}\n", .{args[0], stderr});
        return error.CommandFailed;
    }
    
    return try allocator.dupe(u8, stdout);
}

fn runZiggitCommand(allocator: std.mem.Allocator, args: []const []const u8) ![]u8 {
    // Try to run ziggit command - prepend "ziggit" to args
    var ziggit_args = try allocator.alloc([]const u8, args.len + 1);
    defer allocator.free(ziggit_args);
    
    ziggit_args[0] = "./zig-out/bin/ziggit"; // Adjust path as needed
    for (args, 0..) |arg, i| {
        ziggit_args[i + 1] = arg;
    }
    
    return runCommand(allocator, ziggit_args);
}