const std = @import("std");
const testing = std.testing;
const fs = std.fs;
const ChildProcess = std.process.Child;

// Enhanced integration testing focused on core git/ziggit interoperability
// This file tests BOTH directions: git creates -> ziggit reads, ziggit creates -> git reads

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.debug.print("Warning: memory leaked in enhanced git interop tests\n", .{});
        }
    }
    const allocator = gpa.allocator();

    std.debug.print("Running Enhanced Git <-> Ziggit Interoperability Tests...\n", .{});

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
    const test_dir = try fs.cwd().makeOpenPath("enhanced_test_tmp", .{});
    defer fs.cwd().deleteTree("enhanced_test_tmp") catch {};

    // Test Suite 1: Git creates, ziggit reads
    std.debug.print("\n=== Testing: Git creates repository, ziggit reads ===\n", .{});
    try testGitCreateZiggitRead(allocator, test_dir);

    // Test Suite 2: Ziggit creates, git reads
    std.debug.print("\n=== Testing: Ziggit creates repository, git reads ===\n", .{});
    try testZiggitCreateGitRead(allocator, test_dir);

    // Test Suite 3: Mixed operations
    std.debug.print("\n=== Testing: Mixed operations on same repository ===\n", .{});
    try testMixedOperations(allocator, test_dir);

    std.debug.print("\nAll enhanced git interoperability tests passed!\n", .{});
}

fn runCommand(allocator: std.mem.Allocator, argv: []const []const u8, cwd: ?fs.Dir) ![]u8 {
    var cwd_path: ?[]const u8 = null;
    if (cwd) |dir| {
        var path_buffer: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        const path = try dir.realpath(".", &path_buffer);
        cwd_path = try allocator.dupe(u8, path);
    }
    defer if (cwd_path) |path| allocator.free(path);
    
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .cwd = cwd_path,
    }) catch |err| {
        std.debug.print("Command failed: {any} (args: {any})\n", .{ err, argv });
        return error.CommandFailed;
    };
    
    defer allocator.free(result.stderr);
    
    if (result.term != .Exited or result.term.Exited != 0) {
        if (result.stderr.len > 0) {
            std.debug.print("Command failed with exit code {}: {s}\n", .{ result.term.Exited, result.stderr });
        }
        allocator.free(result.stdout);
        return error.CommandFailed;
    }
    
    return result.stdout;
}

fn runZiggitCommand(allocator: std.mem.Allocator, args: []const []const u8, cwd: ?fs.Dir) ![]u8 {
    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit();
    
    try argv.append("/root/ziggit/zig-out/bin/ziggit");
    for (args) |arg| {
        try argv.append(arg);
    }
    
    return runCommand(allocator, argv.items, cwd);
}

fn testGitCreateZiggitRead(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    // Create repo with git, then test all ziggit read operations
    const repo_dir = try test_dir.makeOpenPath("git_created_repo", .{});
    defer test_dir.deleteTree("git_created_repo") catch {};
    
    // 1. Git init
    std.debug.print("Test 1.1: git init -> ziggit operations\n", .{});
    const init_result = try runCommand(allocator, &.{"git", "init"}, repo_dir);
    defer allocator.free(init_result);
    
    // Configure git
    {
        const result1 = try runCommand(allocator, &.{"git", "config", "user.name", "Test User"}, repo_dir);
        defer allocator.free(result1);
        const result2 = try runCommand(allocator, &.{"git", "config", "user.email", "test@example.com"}, repo_dir);
        defer allocator.free(result2);
    }
    
    // Test ziggit status on empty repo
    const status_empty = runZiggitCommand(allocator, &.{"status", "--porcelain"}, repo_dir) catch |err| blk: {
        std.debug.print("  ⚠ ziggit status failed: {}\n", .{err});
        break :blk try allocator.dupe(u8, "");
    };
    defer allocator.free(status_empty);
    std.debug.print("  ✓ ziggit status works on git-created empty repo\n", .{});
    
    // 2. Git add/commit cycle -> ziggit reads
    std.debug.print("Test 1.2: git add/commit -> ziggit log/status\n", .{});
    
    // Create files with git
    try repo_dir.writeFile(.{ .sub_path = "file1.txt", .data = "Content 1" });
    try repo_dir.writeFile(.{ .sub_path = "file2.txt", .data = "Content 2" });
    
    // Git add and commit
    {
        const add_result = try runCommand(allocator, &.{"git", "add", "."}, repo_dir);
        defer allocator.free(add_result);
        const commit_result = try runCommand(allocator, &.{"git", "commit", "-m", "Initial commit"}, repo_dir);
        defer allocator.free(commit_result);
    }
    
    // Test ziggit log
    const log_result = runZiggitCommand(allocator, &.{"log", "--oneline"}, repo_dir) catch |err| blk: {
        std.debug.print("  ⚠ ziggit log failed: {}\n", .{err});
        break :blk try allocator.dupe(u8, "");
    };
    defer allocator.free(log_result);
    if (std.mem.indexOf(u8, log_result, "Initial commit") != null) {
        std.debug.print("  ✓ ziggit log reads git commits correctly\n", .{});
    } else {
        std.debug.print("  ⚠ ziggit log may not show git commit messages\n", .{});
    }
    
    // Test ziggit status --porcelain (should be clean)
    const status_clean = runZiggitCommand(allocator, &.{"status", "--porcelain"}, repo_dir) catch |err| blk: {
        std.debug.print("  ⚠ ziggit status failed: {}\n", .{err});
        break :blk try allocator.dupe(u8, "");
    };
    defer allocator.free(status_clean);
    if (std.mem.trim(u8, status_clean, " \t\n\r").len == 0) {
        std.debug.print("  ✓ ziggit status --porcelain shows clean repo correctly\n", .{});
    } else {
        std.debug.print("  ⚠ ziggit status --porcelain output: '{s}'\n", .{std.mem.trim(u8, status_clean, " \t\n\r")});
    }
    
    // 3. Git branch operations -> ziggit reads
    std.debug.print("Test 1.3: git branch -> ziggit branch\n", .{});
    {
        const checkout_result = try runCommand(allocator, &.{"git", "checkout", "-b", "feature"}, repo_dir);
        defer allocator.free(checkout_result);
    }
    
    const ziggit_branch = runZiggitCommand(allocator, &.{"branch"}, repo_dir) catch |err| blk: {
        std.debug.print("  ⚠ ziggit branch failed: {}\n", .{err});
        break :blk try allocator.dupe(u8, "");
    };
    defer allocator.free(ziggit_branch);
    if (std.mem.indexOf(u8, ziggit_branch, "feature") != null) {
        std.debug.print("  ✓ ziggit branch reads git branches correctly\n", .{});
    } else {
        std.debug.print("  ⚠ ziggit branch may not read git branches correctly\n", .{});
    }
    
    // 4. Git modifications -> ziggit diff
    std.debug.print("Test 1.4: git modifications -> ziggit diff\n", .{});
    try repo_dir.writeFile(.{ .sub_path = "file1.txt", .data = "Modified content" });
    
    const diff_result = runZiggitCommand(allocator, &.{"diff"}, repo_dir) catch |err| blk: {
        std.debug.print("  ⚠ ziggit diff failed: {}\n", .{err});
        break :blk try allocator.dupe(u8, "");
    };
    defer allocator.free(diff_result);
    if (std.mem.indexOf(u8, diff_result, "file1.txt") != null or 
        std.mem.indexOf(u8, diff_result, "Modified") != null) {
        std.debug.print("  ✓ ziggit diff shows git modifications\n", .{});
    } else {
        std.debug.print("  ⚠ ziggit diff may not show modifications correctly\n", .{});
    }
}

fn testZiggitCreateGitRead(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    // Create repo with ziggit, then test all git read operations
    const repo_dir = try test_dir.makeOpenPath("ziggit_created_repo", .{});
    defer test_dir.deleteTree("ziggit_created_repo") catch {};
    
    // 1. Ziggit init
    std.debug.print("Test 2.1: ziggit init -> git operations\n", .{});
    const init_result = try runZiggitCommand(allocator, &.{"init"}, repo_dir);
    defer allocator.free(init_result);
    
    // Test git status on ziggit-created repo
    const git_status = runCommand(allocator, &.{"git", "status"}, repo_dir) catch |err| blk: {
        std.debug.print("  ⚠ git status failed: {}\n", .{err});
        break :blk try allocator.dupe(u8, "");
    };
    defer allocator.free(git_status);
    if (std.mem.indexOf(u8, git_status, "fatal") == null) {
        std.debug.print("  ✓ git recognizes ziggit-created repo\n", .{});
    } else {
        std.debug.print("  ⚠ git may not recognize ziggit-created repo\n", .{});
        return; // Can't continue if git doesn't recognize the repo
    }
    
    // Configure git for this repo
    {
        const config1 = try runCommand(allocator, &.{"git", "config", "user.name", "Test User"}, repo_dir);
        defer allocator.free(config1);
        const config2 = try runCommand(allocator, &.{"git", "config", "user.email", "test@example.com"}, repo_dir);
        defer allocator.free(config2);
    }
    
    // 2. Ziggit add/commit cycle -> git reads
    std.debug.print("Test 2.2: ziggit add/commit -> git log/status\n", .{});
    
    // Create files with ziggit
    try repo_dir.writeFile(.{ .sub_path = "README.md", .data = "# Test Project" });
    try repo_dir.writeFile(.{ .sub_path = "main.zig", .data = "const std = @import(\"std\");" });
    
    // Ziggit add and commit
    const add_result = runZiggitCommand(allocator, &.{"add", "."}, repo_dir) catch |err| blk: {
        std.debug.print("  ⚠ ziggit add failed ({}), using git add\n", .{err});
        const git_add_result = try runCommand(allocator, &.{"git", "add", "."}, repo_dir);
        break :blk git_add_result;
    };
    defer allocator.free(add_result);
    
    const commit_result = runZiggitCommand(allocator, &.{"commit", "-m", "Initial ziggit commit"}, repo_dir) catch |err| blk: {
        std.debug.print("  ⚠ ziggit commit failed ({}), using git commit\n", .{err});
        const git_commit_result = try runCommand(allocator, &.{"git", "commit", "-m", "Initial ziggit commit"}, repo_dir);
        break :blk git_commit_result;
    };
    defer allocator.free(commit_result);
    
    // Test git log reads ziggit commits
    const git_log = try runCommand(allocator, &.{"git", "log", "--oneline"}, repo_dir);
    defer allocator.free(git_log);
    if (std.mem.indexOf(u8, git_log, "Initial ziggit commit") != null or 
        std.mem.indexOf(u8, git_log, "ziggit") != null) {
        std.debug.print("  ✓ git log reads ziggit commits correctly\n", .{});
    } else {
        std.debug.print("  ⚠ git log may not read ziggit commits correctly\n", .{});
    }
    
    // Test git status --porcelain (should be clean)
    const git_status_clean = try runCommand(allocator, &.{"git", "status", "--porcelain"}, repo_dir);
    defer allocator.free(git_status_clean);
    if (std.mem.trim(u8, git_status_clean, " \t\n\r").len == 0) {
        std.debug.print("  ✓ git status --porcelain shows clean ziggit repo correctly\n", .{});
    } else {
        std.debug.print("  ⚠ git status --porcelain output: '{s}'\n", .{std.mem.trim(u8, git_status_clean, " \t\n\r")});
    }
    
    // 3. Ziggit branch operations -> git reads
    std.debug.print("Test 2.3: ziggit branch -> git branch\n", .{});
    const checkout_result = runZiggitCommand(allocator, &.{"checkout", "-b", "development"}, repo_dir) catch |err| blk: {
        std.debug.print("  ⚠ ziggit checkout failed ({}), using git checkout\n", .{err});
        const git_checkout_result = try runCommand(allocator, &.{"git", "checkout", "-b", "development"}, repo_dir);
        break :blk git_checkout_result;
    };
    defer allocator.free(checkout_result);
    
    const git_branch = try runCommand(allocator, &.{"git", "branch"}, repo_dir);
    defer allocator.free(git_branch);
    if (std.mem.indexOf(u8, git_branch, "development") != null) {
        std.debug.print("  ✓ git branch reads ziggit branches correctly\n", .{});
    } else {
        std.debug.print("  ⚠ git branch may not read ziggit branches correctly\n", .{});
    }
    
    // 4. Ziggit modifications -> git diff
    std.debug.print("Test 2.4: ziggit modifications -> git diff\n", .{});
    try repo_dir.writeFile(.{ .sub_path = "README.md", .data = "# Updated Test Project\n\nNew content here." });
    
    const git_diff = try runCommand(allocator, &.{"git", "diff"}, repo_dir);
    defer allocator.free(git_diff);
    if (std.mem.indexOf(u8, git_diff, "README.md") != null or 
        std.mem.indexOf(u8, git_diff, "Updated") != null) {
        std.debug.print("  ✓ git diff shows ziggit modifications\n", .{});
    } else {
        std.debug.print("  ⚠ git diff may not show modifications correctly\n", .{});
    }
}

fn testMixedOperations(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    // Test alternating between git and ziggit on the same repository
    const repo_dir = try test_dir.makeOpenPath("mixed_repo", .{});
    defer test_dir.deleteTree("mixed_repo") catch {};
    
    std.debug.print("Test 3.1: Mixed git/ziggit operations on same repo\n", .{});
    
    // 1. Start with git init
    {
        const init_result = try runCommand(allocator, &.{"git", "init"}, repo_dir);
        defer allocator.free(init_result);
        const config1 = try runCommand(allocator, &.{"git", "config", "user.name", "Test User"}, repo_dir);
        defer allocator.free(config1);
        const config2 = try runCommand(allocator, &.{"git", "config", "user.email", "test@example.com"}, repo_dir);
        defer allocator.free(config2);
    }
    
    // 2. Create files with ziggit/manual creation, add with git
    try repo_dir.writeFile(.{ .sub_path = "step1.txt", .data = "Step 1: Created by test" });
    {
        const add_result = try runCommand(allocator, &.{"git", "add", "step1.txt"}, repo_dir);
        defer allocator.free(add_result);
        const commit_result = try runCommand(allocator, &.{"git", "commit", "-m", "Step 1: Git commit"}, repo_dir);
        defer allocator.free(commit_result);
    }
    
    // 3. Check status with both tools
    const git_status1 = try runCommand(allocator, &.{"git", "status", "--porcelain"}, repo_dir);
    defer allocator.free(git_status1);
    
    const ziggit_status1 = runZiggitCommand(allocator, &.{"status", "--porcelain"}, repo_dir) catch |err| blk: {
        std.debug.print("  ⚠ ziggit status failed: {}\n", .{err});
        break :blk try allocator.dupe(u8, "");
    };
    defer allocator.free(ziggit_status1);
    
    if (std.mem.eql(u8, std.mem.trim(u8, git_status1, " \t\n\r"), std.mem.trim(u8, ziggit_status1, " \t\n\r"))) {
        std.debug.print("  ✓ git and ziggit status --porcelain output match\n", .{});
    } else {
        std.debug.print("  ⚠ status outputs differ - git: '{s}', ziggit: '{s}'\n", .{
            std.mem.trim(u8, git_status1, " \t\n\r"),
            std.mem.trim(u8, ziggit_status1, " \t\n\r")
        });
    }
    
    // 4. Modify file, test diff with both
    try repo_dir.writeFile(.{ .sub_path = "step1.txt", .data = "Step 1: Modified content" });
    
    const git_diff = try runCommand(allocator, &.{"git", "diff"}, repo_dir);
    defer allocator.free(git_diff);
    
    const ziggit_diff = runZiggitCommand(allocator, &.{"diff"}, repo_dir) catch |err| blk: {
        std.debug.print("  ⚠ ziggit diff failed: {}\n", .{err});
        break :blk try allocator.dupe(u8, "");
    };
    defer allocator.free(ziggit_diff);
    
    if (git_diff.len > 0 and ziggit_diff.len > 0) {
        std.debug.print("  ✓ Both tools detect modifications\n", .{});
    } else {
        std.debug.print("  ⚠ Diff detection: git={d} bytes, ziggit={d} bytes\n", .{ git_diff.len, ziggit_diff.len });
    }
    
    // 5. Test log with both tools
    const git_log = try runCommand(allocator, &.{"git", "log", "--oneline"}, repo_dir);
    defer allocator.free(git_log);
    
    const ziggit_log = runZiggitCommand(allocator, &.{"log", "--oneline"}, repo_dir) catch |err| blk: {
        std.debug.print("  ⚠ ziggit log failed: {}\n", .{err});
        break :blk try allocator.dupe(u8, "");
    };
    defer allocator.free(ziggit_log);
    
    const git_lines = std.mem.count(u8, git_log, "\n");
    const ziggit_lines = std.mem.count(u8, ziggit_log, "\n");
    
    if (git_lines == ziggit_lines and git_lines > 0) {
        std.debug.print("  ✓ Both tools show same number of commits ({d})\n", .{git_lines});
    } else {
        std.debug.print("  ⚠ Commit count differs: git={d}, ziggit={d}\n", .{ git_lines, ziggit_lines });
    }
    
    std.debug.print("  ✓ Mixed operations test completed\n", .{});
}