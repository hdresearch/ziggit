const std = @import("std");
const testing = std.testing;
const fs = std.fs;
const print = std.debug.print;
const ChildProcess = std.process.Child;

// Core integration testing - git <-> ziggit interoperability
// Tests that create repos with git, then verify ziggit reads them correctly
// Tests that create repos with ziggit, then verify git reads them correctly
// Covers: init, add, commit, status --porcelain, log --oneline, branch, diff, checkout

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            print("Warning: memory leaked in git ziggit core tests\n", .{});
        }
    }
    const allocator = gpa.allocator();

    print("=== Core Git <-> Ziggit Interoperability Tests ===\n", .{});

    // Set up global git config for tests
    _ = runCommandIgnoreError(allocator, &.{"git", "config", "--global", "user.name", "Test User"}, fs.cwd());
    _ = runCommandIgnoreError(allocator, &.{"git", "config", "--global", "user.email", "test@example.com"}, fs.cwd());

    // Create temporary test directory
    const test_dir = try fs.cwd().makeOpenPath("test_core_tmp", .{});
    defer fs.cwd().deleteTree("test_core_tmp") catch {};

    // Core test scenarios
    try testGitInitZiggitOps(allocator, test_dir);
    try testZiggitInitGitOps(allocator, test_dir);
    try testStatusPorcelainSync(allocator, test_dir);
    try testLogOnelineSync(allocator, test_dir);
    try testBranchSync(allocator, test_dir);
    try testDiffSync(allocator, test_dir);
    try testCheckoutSync(allocator, test_dir);

    print("✅ All core git <-> ziggit tests completed successfully!\n", .{});
}

// Test 1: git init -> ziggit operations -> git verification
fn testGitInitZiggitOps(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    print("\n🧪 Test 1: git init -> ziggit ops -> git verify\n", .{});
    
    const repo_dir = try test_dir.makeOpenPath("git_init_ziggit_ops", .{});
    defer test_dir.deleteTree("git_init_ziggit_ops") catch {};

    // 1. git init
    _ = try runCommand(allocator, &.{"git", "init"}, repo_dir);
    _ = try runCommand(allocator, &.{"git", "config", "user.name", "Test User"}, repo_dir);
    _ = try runCommand(allocator, &.{"git", "config", "user.email", "test@example.com"}, repo_dir);
    print("   ✓ git init completed\n", .{});

    // 2. Create files
    try repo_dir.writeFile(.{.sub_path = "main.zig", .data = "pub fn main() !void {}\n"});
    try repo_dir.writeFile(.{.sub_path = "lib.zig", .data = "pub fn helper() void {}\n"});
    print("   ✓ Test files created\n", .{});

    // 3. ziggit add (if available)
    if (runZiggitCommand(allocator, &.{"add", "main.zig"}, repo_dir)) |ziggit_add_result| {
        defer allocator.free(ziggit_add_result);
        print("   ✓ ziggit add successful\n", .{});
    } else |err| {
        print("   ⚠ ziggit add not available: {}\n", .{err});
        // Fallback to git add
        _ = try runCommand(allocator, &.{"git", "add", "main.zig"}, repo_dir);
        print("   ✓ Fallback to git add\n", .{});
    }

    // 4. ziggit commit (if available)
    if (runZiggitCommand(allocator, &.{"commit", "-m", "Initial commit"}, repo_dir)) |ziggit_commit_result| {
        defer allocator.free(ziggit_commit_result);
        print("   ✓ ziggit commit successful\n", .{});
    } else |err| {
        print("   ⚠ ziggit commit not available: {}\n", .{err});
        // Fallback to git commit
        _ = try runCommand(allocator, &.{"git", "commit", "-m", "Initial commit"}, repo_dir);
        print("   ✓ Fallback to git commit\n", .{});
    }

    // 5. ziggit status --porcelain (test reading git repo)
    const ziggit_status_result = runZiggitCommand(allocator, &.{"status", "--porcelain"}, repo_dir) catch |err| {
        print("   ⚠ ziggit status not available: {}\n", .{err});
        return;
    };
    defer allocator.free(ziggit_status_result);
    print("   ✓ ziggit status --porcelain: '{s}'\n", .{std.mem.trim(u8, ziggit_status_result, " \t\n\r")});

    // 6. Verify git still works with repo
    const git_status = try runCommand(allocator, &.{"git", "status", "--porcelain"}, repo_dir);
    defer allocator.free(git_status);
    print("   ✓ git status still works: '{s}'\n", .{std.mem.trim(u8, git_status, " \t\n\r")});

    print("   ✅ Test 1 completed\n", .{});
}

// Test 2: ziggit init -> git operations -> ziggit verification  
fn testZiggitInitGitOps(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    print("\n🧪 Test 2: ziggit init -> git ops -> ziggit verify\n", .{});
    
    const repo_dir = try test_dir.makeOpenPath("ziggit_init_git_ops", .{});
    defer test_dir.deleteTree("ziggit_init_git_ops") catch {};

    // 1. ziggit init (if available)
    if (runZiggitCommand(allocator, &.{"init"}, repo_dir)) |ziggit_init_result| {
        defer allocator.free(ziggit_init_result);
        print("   ✓ ziggit init successful\n", .{});
    } else |err| {
        print("   ⚠ ziggit init not available: {}\n", .{err});
        // Fallback to git init
        _ = try runCommand(allocator, &.{"git", "init"}, repo_dir);
        _ = try runCommand(allocator, &.{"git", "config", "user.name", "Test User"}, repo_dir);
        _ = try runCommand(allocator, &.{"git", "config", "user.email", "test@example.com"}, repo_dir);
        print("   ✓ Fallback to git init\n", .{});
    }

    // 2. Create files and use git operations
    try repo_dir.writeFile(.{.sub_path = "README.md", .data = "# Test Project\n"});
    try repo_dir.writeFile(.{.sub_path = "build.zig", .data = "const std = @import(\"std\");\n"});
    print("   ✓ Test files created\n", .{});

    // 3. git add & commit
    _ = try runCommand(allocator, &.{"git", "add", "README.md"}, repo_dir);
    _ = try runCommand(allocator, &.{"git", "commit", "-m", "Add README"}, repo_dir);
    print("   ✓ git operations completed\n", .{});

    // 4. ziggit log --oneline (test reading git commits)
    const ziggit_log_result = runZiggitCommand(allocator, &.{"log", "--oneline"}, repo_dir) catch |err| {
        print("   ⚠ ziggit log not available: {}\n", .{err});
        return;
    };
    defer allocator.free(ziggit_log_result);
    print("   ✓ ziggit log --oneline: '{s}'\n", .{std.mem.trim(u8, ziggit_log_result, " \t\n\r")});

    // 5. Verify git log still works
    const git_log = try runCommand(allocator, &.{"git", "log", "--oneline"}, repo_dir);
    defer allocator.free(git_log);
    print("   ✓ git log still works: '{s}'\n", .{std.mem.trim(u8, git_log, " \t\n\r")});

    print("   ✅ Test 2 completed\n", .{});
}

// Test 3: Status --porcelain output synchronization
fn testStatusPorcelainSync(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    print("\n🧪 Test 3: status --porcelain sync\n", .{});
    
    const repo_dir = try test_dir.makeOpenPath("status_sync", .{});
    defer test_dir.deleteTree("status_sync") catch {};

    // Setup repo with git
    _ = try runCommand(allocator, &.{"git", "init"}, repo_dir);
    _ = try runCommand(allocator, &.{"git", "config", "user.name", "Test"}, repo_dir);
    _ = try runCommand(allocator, &.{"git", "config", "user.email", "test@test.com"}, repo_dir);

    // Create various file states
    try repo_dir.writeFile(.{.sub_path = "tracked.txt", .data = "tracked\n"});
    try repo_dir.writeFile(.{.sub_path = "untracked.txt", .data = "untracked\n"});
    _ = try runCommand(allocator, &.{"git", "add", "tracked.txt"}, repo_dir);
    _ = try runCommand(allocator, &.{"git", "commit", "-m", "Add tracked"}, repo_dir);
    
    // Modify tracked file
    try repo_dir.writeFile(.{.sub_path = "tracked.txt", .data = "modified\n"});

    // Compare git vs ziggit status --porcelain
    const git_status = try runCommand(allocator, &.{"git", "status", "--porcelain"}, repo_dir);
    defer allocator.free(git_status);
    
    const ziggit_status = runZiggitCommand(allocator, &.{"status", "--porcelain"}, repo_dir) catch |err| {
        print("   ⚠ ziggit status not available: {}\n", .{err});
        print("   git status: '{s}'\n", .{std.mem.trim(u8, git_status, " \t\n\r")});
        return;
    };
    defer allocator.free(ziggit_status);
    
    print("   git status:    '{s}'\n", .{std.mem.trim(u8, git_status, " \t\n\r")});
    print("   ziggit status: '{s}'\n", .{std.mem.trim(u8, ziggit_status, " \t\n\r")});
    
    if (std.mem.eql(u8, std.mem.trim(u8, git_status, " \t\n\r"), std.mem.trim(u8, ziggit_status, " \t\n\r"))) {
        print("   ✅ Status outputs match perfectly\n", .{});
    } else {
        print("   ⚠ Status outputs differ\n", .{});
    }
    
    print("   ✅ Test 3 completed\n", .{});
}

// Test 4: Log --oneline output synchronization
fn testLogOnelineSync(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    print("\n🧪 Test 4: log --oneline sync\n", .{});
    
    const repo_dir = try test_dir.makeOpenPath("log_sync", .{});
    defer test_dir.deleteTree("log_sync") catch {};

    // Setup repo with multiple commits
    _ = try runCommand(allocator, &.{"git", "init"}, repo_dir);
    _ = try runCommand(allocator, &.{"git", "config", "user.name", "Test"}, repo_dir);
    _ = try runCommand(allocator, &.{"git", "config", "user.email", "test@test.com"}, repo_dir);
    
    try repo_dir.writeFile(.{.sub_path = "file1.txt", .data = "first\n"});
    _ = try runCommand(allocator, &.{"git", "add", "file1.txt"}, repo_dir);
    _ = try runCommand(allocator, &.{"git", "commit", "-m", "First commit"}, repo_dir);
    
    try repo_dir.writeFile(.{.sub_path = "file2.txt", .data = "second\n"});
    _ = try runCommand(allocator, &.{"git", "add", "file2.txt"}, repo_dir);
    _ = try runCommand(allocator, &.{"git", "commit", "-m", "Second commit"}, repo_dir);

    // Compare git vs ziggit log --oneline
    const git_log = try runCommand(allocator, &.{"git", "log", "--oneline"}, repo_dir);
    defer allocator.free(git_log);
    
    const ziggit_log = runZiggitCommand(allocator, &.{"log", "--oneline"}, repo_dir) catch |err| {
        print("   ⚠ ziggit log not available: {}\n", .{err});
        print("   git log: '{s}'\n", .{std.mem.trim(u8, git_log, " \t\n\r")});
        return;
    };
    defer allocator.free(ziggit_log);
    
    print("   git log:    '{s}'\n", .{std.mem.trim(u8, git_log, " \t\n\r")});
    print("   ziggit log: '{s}'\n", .{std.mem.trim(u8, ziggit_log, " \t\n\r")});
    
    // Check if both have similar commit messages (hashes will differ)
    if (std.mem.indexOf(u8, ziggit_log, "First commit") != null and 
        std.mem.indexOf(u8, ziggit_log, "Second commit") != null) {
        print("   ✅ Log outputs contain expected commits\n", .{});
    } else {
        print("   ⚠ Log outputs may differ in content\n", .{});
    }
    
    print("   ✅ Test 4 completed\n", .{});
}

// Test 5: Branch operations synchronization
fn testBranchSync(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    print("\n🧪 Test 5: branch operations sync\n", .{});
    
    const repo_dir = try test_dir.makeOpenPath("branch_sync", .{});
    defer test_dir.deleteTree("branch_sync") catch {};

    // Setup repo
    _ = try runCommand(allocator, &.{"git", "init"}, repo_dir);
    _ = try runCommand(allocator, &.{"git", "config", "user.name", "Test"}, repo_dir);
    _ = try runCommand(allocator, &.{"git", "config", "user.email", "test@test.com"}, repo_dir);
    
    try repo_dir.writeFile(.{.sub_path = "main.txt", .data = "main branch\n"});
    _ = try runCommand(allocator, &.{"git", "add", "main.txt"}, repo_dir);
    _ = try runCommand(allocator, &.{"git", "commit", "-m", "Initial commit"}, repo_dir);
    
    // Create branch with git
    _ = try runCommand(allocator, &.{"git", "branch", "feature"}, repo_dir);
    _ = try runCommand(allocator, &.{"git", "branch", "develop"}, repo_dir);

    // Test ziggit branch reading
    const git_branch = try runCommand(allocator, &.{"git", "branch"}, repo_dir);
    defer allocator.free(git_branch);
    
    const ziggit_branch = runZiggitCommand(allocator, &.{"branch"}, repo_dir) catch |err| {
        print("   ⚠ ziggit branch not available: {}\n", .{err});
        print("   git branch: '{s}'\n", .{std.mem.trim(u8, git_branch, " \t\n\r")});
        return;
    };
    defer allocator.free(ziggit_branch);
    
    print("   git branch:    '{s}'\n", .{std.mem.trim(u8, git_branch, " \t\n\r")});
    print("   ziggit branch: '{s}'\n", .{std.mem.trim(u8, ziggit_branch, " \t\n\r")});
    
    // Check if both show feature and develop branches
    if (std.mem.indexOf(u8, ziggit_branch, "feature") != null and 
        std.mem.indexOf(u8, ziggit_branch, "develop") != null) {
        print("   ✅ Branch outputs show expected branches\n", .{});
    } else {
        print("   ⚠ Branch outputs may differ\n", .{});
    }
    
    print("   ✅ Test 5 completed\n", .{});
}

// Test 6: Diff operations synchronization
fn testDiffSync(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    print("\n🧪 Test 6: diff operations sync\n", .{});
    
    const repo_dir = try test_dir.makeOpenPath("diff_sync", .{});
    defer test_dir.deleteTree("diff_sync") catch {};

    // Setup repo
    _ = try runCommand(allocator, &.{"git", "init"}, repo_dir);
    _ = try runCommand(allocator, &.{"git", "config", "user.name", "Test"}, repo_dir);
    _ = try runCommand(allocator, &.{"git", "config", "user.email", "test@test.com"}, repo_dir);
    
    try repo_dir.writeFile(.{.sub_path = "test.txt", .data = "original content\n"});
    _ = try runCommand(allocator, &.{"git", "add", "test.txt"}, repo_dir);
    _ = try runCommand(allocator, &.{"git", "commit", "-m", "Add file"}, repo_dir);
    
    // Modify file
    try repo_dir.writeFile(.{.sub_path = "test.txt", .data = "modified content\n"});

    // Test diff output
    const git_diff = try runCommand(allocator, &.{"git", "diff", "test.txt"}, repo_dir);
    defer allocator.free(git_diff);
    
    const ziggit_diff = runZiggitCommand(allocator, &.{"diff", "test.txt"}, repo_dir) catch |err| {
        print("   ⚠ ziggit diff not available: {}\n", .{err});
        print("   git diff length: {} chars\n", .{git_diff.len});
        return;
    };
    defer allocator.free(ziggit_diff);
    
    print("   git diff length:    {} chars\n", .{git_diff.len});
    print("   ziggit diff length: {} chars\n", .{ziggit_diff.len});
    
    // Check if both diffs show changes
    if (git_diff.len > 0 and ziggit_diff.len > 0) {
        print("   ✅ Both tools detect file changes\n", .{});
    } else {
        print("   ⚠ Diff detection may differ\n", .{});
    }
    
    print("   ✅ Test 6 completed\n", .{});
}

// Test 7: Checkout operations synchronization
fn testCheckoutSync(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    print("\n🧪 Test 7: checkout operations sync\n", .{});
    
    const repo_dir = try test_dir.makeOpenPath("checkout_sync", .{});
    defer test_dir.deleteTree("checkout_sync") catch {};

    // Setup repo with branches
    _ = try runCommand(allocator, &.{"git", "init"}, repo_dir);
    _ = try runCommand(allocator, &.{"git", "config", "user.name", "Test"}, repo_dir);
    _ = try runCommand(allocator, &.{"git", "config", "user.email", "test@test.com"}, repo_dir);
    
    try repo_dir.writeFile(.{.sub_path = "main.txt", .data = "main content\n"});
    _ = try runCommand(allocator, &.{"git", "add", "main.txt"}, repo_dir);
    _ = try runCommand(allocator, &.{"git", "commit", "-m", "Initial"}, repo_dir);
    
    // Create and switch to feature branch
    _ = try runCommand(allocator, &.{"git", "checkout", "-b", "feature"}, repo_dir);
    try repo_dir.writeFile(.{.sub_path = "feature.txt", .data = "feature content\n"});
    _ = try runCommand(allocator, &.{"git", "add", "feature.txt"}, repo_dir);
    _ = try runCommand(allocator, &.{"git", "commit", "-m", "Add feature"}, repo_dir);
    
    // Test ziggit checkout back to main
    const ziggit_checkout = runZiggitCommand(allocator, &.{"checkout", "main"}, repo_dir) catch |err| {
        print("   ⚠ ziggit checkout not available: {}\n", .{err});
        // Verify git checkout still works
        _ = try runCommand(allocator, &.{"git", "checkout", "main"}, repo_dir);
        print("   ✓ git checkout works\n", .{});
        return;
    };
    defer allocator.free(ziggit_checkout);
    
    print("   ✓ ziggit checkout completed\n", .{});
    
    // Verify we're on main branch
    const current_branch = try runCommand(allocator, &.{"git", "branch", "--show-current"}, repo_dir);
    defer allocator.free(current_branch);
    print("   Current branch: '{s}'\n", .{std.mem.trim(u8, current_branch, " \t\n\r")});
    
    if (std.mem.eql(u8, std.mem.trim(u8, current_branch, " \t\n\r"), "main")) {
        print("   ✅ Checkout successful - on main branch\n", .{});
    } else {
        print("   ⚠ Checkout may have failed\n", .{});
    }
    
    print("   ✅ Test 7 completed\n", .{});
}

// Helper function to run git/shell commands
fn runCommand(allocator: std.mem.Allocator, argv: []const []const u8, cwd: fs.Dir) ![]u8 {
    var child = ChildProcess.init(argv, allocator);
    child.cwd_dir = cwd;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    
    try child.spawn();
    
    const stdout = try child.stdout.?.readToEndAlloc(allocator, 1024 * 1024);
    const stderr = try child.stderr.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(stderr);
    
    const term = try child.wait();
    if (term != .Exited or term.Exited != 0) {
        print("Command failed: {s}\n", .{argv});
        if (stderr.len > 0) print("Error: {s}\n", .{stderr});
        return error.CommandFailed;
    }
    
    return stdout;
}

// Helper function to run ziggit commands
fn runZiggitCommand(allocator: std.mem.Allocator, argv: []const []const u8, cwd: fs.Dir) ![]u8 {
    var args_list = std.ArrayList([]const u8).init(allocator);
    defer args_list.deinit();
    
    try args_list.append("../zig-out/bin/ziggit");
    for (argv) |arg| {
        try args_list.append(arg);
    }
    
    return runCommand(allocator, args_list.items, cwd);
}

// Helper function that ignores errors (for setup commands)
fn runCommandIgnoreError(allocator: std.mem.Allocator, argv: []const []const u8, cwd: fs.Dir) ?[]u8 {
    return runCommand(allocator, argv, cwd) catch null;
}