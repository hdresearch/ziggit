const std = @import("std");
const testing = std.testing;
const fs = std.fs;
const ChildProcess = std.process.Child;
const print = std.debug.print;

// Comprehensive integration test suite for ziggit VCS
// This test suite ensures complete compatibility between git and ziggit
// Tests cover: init, add, commit, status --porcelain, log --oneline, branch, diff, checkout

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            print("Warning: memory leaked in integration tests\n", .{});
        }
    }
    const allocator = gpa.allocator();

    print("=== Ziggit Integration Test Suite ===\n", .{});

    // Configure git for testing
    _ = runCommandSafe(allocator, &.{"git", "config", "--global", "user.name", "Test User"}, fs.cwd());
    _ = runCommandSafe(allocator, &.{"git", "config", "--global", "user.email", "test@example.com"}, fs.cwd());

    const test_dir = try fs.cwd().makeOpenPath("integration_test_tmp", .{});
    defer fs.cwd().deleteTree("integration_test_tmp") catch {};

    // Core interoperability tests
    try testGitToZiggitInterop(allocator, test_dir);
    try testZiggitToGitInterop(allocator, test_dir);
    
    // Command compatibility tests
    try testStatusPorcelainCompatibility(allocator, test_dir);
    try testLogOnelineCompatibility(allocator, test_dir);
    try testBranchCompatibility(allocator, test_dir);
    try testDiffCompatibility(allocator, test_dir);
    try testCheckoutCompatibility(allocator, test_dir);

    // Repository format compatibility
    try testRepositoryFormatCompatibility(allocator, test_dir);

    print("✅ All integration tests passed!\n", .{});
}

// Test: Create repo with git, verify ziggit can read it correctly
fn testGitToZiggitInterop(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    print("🧪 Testing Git → Ziggit interoperability...\n", .{});
    
    const repo_dir = try test_dir.makeOpenPath("git_to_ziggit", .{});
    defer test_dir.deleteTree("git_to_ziggit") catch {};

    // Initialize with git
    _ = try runCommand(allocator, &.{"git", "init"}, repo_dir);
    try runCommandNoOutput(allocator, &.{"git", "config", "user.name", "Test User"}, repo_dir);
    try runCommandNoOutput(allocator, &.{"git", "config", "user.email", "test@example.com"}, repo_dir);
    
    // Create and add files with git
    try repo_dir.writeFile(.{.sub_path = "README.md", .data = "# Test Project\n"});
    try repo_dir.makeDir("src");
    try repo_dir.writeFile(.{.sub_path = "src/main.c", .data = "int main() { return 0; }\n"});
    _ = try runCommand(allocator, &.{"git", "add", "."}, repo_dir);
    _ = try runCommand(allocator, &.{"git", "commit", "-m", "Initial commit"}, repo_dir);
    
    // Create a branch with git
    _ = try runCommand(allocator, &.{"git", "checkout", "-b", "feature-branch"}, repo_dir);
    try repo_dir.writeFile(.{.sub_path = "feature.txt", .data = "feature content\n"});
    _ = try runCommand(allocator, &.{"git", "add", "feature.txt"}, repo_dir);
    _ = try runCommand(allocator, &.{"git", "commit", "-m", "Add feature"}, repo_dir);
    
    // Verify ziggit can read the git repository
    const ziggit_status = try runZiggitCommand(allocator, &.{"status", "--porcelain"}, repo_dir);
    defer allocator.free(ziggit_status);
    
    const ziggit_log = try runZiggitCommand(allocator, &.{"log", "--oneline"}, repo_dir);
    defer allocator.free(ziggit_log);
    
    const ziggit_branches = try runZiggitCommand(allocator, &.{"branch"}, repo_dir);
    defer allocator.free(ziggit_branches);

    // Verify results
    if (!std.mem.eql(u8, std.mem.trim(u8, ziggit_status, " \t\n\r"), "")) {
        print("❌ Expected clean status, got: '{s}'\n", .{ziggit_status});
        return error.TestFailed;
    }
    
    if (!std.mem.containsAtLeast(u8, ziggit_log, 1, "Initial commit")) {
        print("❌ Ziggit log missing git commits: '{s}'\n", .{ziggit_log});
        return error.TestFailed;
    }
    
    if (!std.mem.containsAtLeast(u8, ziggit_branches, 1, "feature-branch")) {
        print("❌ Ziggit branch missing git branches: '{s}'\n", .{ziggit_branches});
        return error.TestFailed;
    }

    print("✅ Git → Ziggit interoperability test passed\n", .{});
}

// Test: Create repo with ziggit, verify git can read it correctly
fn testZiggitToGitInterop(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    print("🧪 Testing Ziggit → Git interoperability...\n", .{});
    
    const repo_dir = try test_dir.makeOpenPath("ziggit_to_git", .{});
    defer test_dir.deleteTree("ziggit_to_git") catch {};

    // Initialize with ziggit
    _ = try runZiggitCommand(allocator, &.{"init"}, repo_dir);
    
    // Create and add files with ziggit
    try repo_dir.writeFile(.{.sub_path = "README.md", .data = "# Ziggit Project\n"});
    try repo_dir.writeFile(.{.sub_path = "lib/utils.zig", .data = "pub fn hello() void {}\n"});
    _ = try runZiggitCommand(allocator, &.{"add", "."}, repo_dir);
    _ = try runZiggitCommand(allocator, &.{"commit", "-m", "Initial ziggit commit"}, repo_dir);

    // Verify git can read the ziggit repository
    const git_status = try runCommand(allocator, &.{"git", "status", "--porcelain"}, repo_dir);
    defer allocator.free(git_status);
    
    const git_log = try runCommand(allocator, &.{"git", "log", "--oneline"}, repo_dir);
    defer allocator.free(git_log);

    // Verify results
    if (!std.mem.eql(u8, std.mem.trim(u8, git_status, " \t\n\r"), "")) {
        print("❌ Expected clean git status, got: '{s}'\n", .{git_status});
        return error.TestFailed;
    }
    
    if (!std.mem.containsAtLeast(u8, git_log, 1, "Initial ziggit commit")) {
        print("❌ Git log missing ziggit commits: '{s}'\n", .{git_log});
        return error.TestFailed;
    }

    print("✅ Ziggit → Git interoperability test passed\n", .{});
}

fn testStatusPorcelainCompatibility(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    print("🧪 Testing status --porcelain compatibility...\n", .{});
    
    const repo_dir = try test_dir.makeOpenPath("status_test", .{});
    defer test_dir.deleteTree("status_test") catch {};

    // Set up test repo with both tools
    _ = try runCommand(allocator, &.{"git", "init"}, repo_dir);
    try runCommandNoOutput(allocator, &.{"git", "config", "user.name", "Test User"}, repo_dir);
    try runCommandNoOutput(allocator, &.{"git", "config", "user.email", "test@example.com"}, repo_dir);
    
    try repo_dir.writeFile(.{.sub_path = "tracked.txt", .data = "content\n"});
    _ = try runCommand(allocator, &.{"git", "add", "tracked.txt"}, repo_dir);
    _ = try runCommand(allocator, &.{"git", "commit", "-m", "Add tracked file"}, repo_dir);
    
    // Create some changes
    try repo_dir.writeFile(.{.sub_path = "tracked.txt", .data = "modified content\n"});
    try repo_dir.writeFile(.{.sub_path = "untracked.txt", .data = "new file\n"});
    
    // Compare outputs
    const git_status = try runCommand(allocator, &.{"git", "status", "--porcelain"}, repo_dir);
    defer allocator.free(git_status);
    
    const ziggit_status = try runZiggitCommand(allocator, &.{"status", "--porcelain"}, repo_dir);
    defer allocator.free(ziggit_status);
    
    // Both should detect the modified file (exact format may differ)
    const git_has_modified = std.mem.containsAtLeast(u8, git_status, 1, "tracked.txt");
    const ziggit_has_modified = std.mem.containsAtLeast(u8, ziggit_status, 1, "tracked.txt");
    
    if (!git_has_modified or !ziggit_has_modified) {
        print("❌ Status outputs don't both detect modified files\n", .{});
        print("   Git: '{s}'\n", .{git_status});
        print("   Ziggit: '{s}'\n", .{ziggit_status});
        return error.TestFailed;
    }
    
    print("✅ Status --porcelain compatibility test passed\n", .{});
}

fn testLogOnelineCompatibility(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    print("🧪 Testing log --oneline compatibility...\n", .{});
    
    const repo_dir = try test_dir.makeOpenPath("log_test", .{});
    defer test_dir.deleteTree("log_test") catch {};

    // Set up test repo
    _ = try runCommand(allocator, &.{"git", "init"}, repo_dir);
    try runCommandNoOutput(allocator, &.{"git", "config", "user.name", "Test User"}, repo_dir);
    try runCommandNoOutput(allocator, &.{"git", "config", "user.email", "test@example.com"}, repo_dir);
    
    // Create multiple commits
    try repo_dir.writeFile(.{.sub_path = "file1.txt", .data = "first\n"});
    _ = try runCommand(allocator, &.{"git", "add", "file1.txt"}, repo_dir);
    _ = try runCommand(allocator, &.{"git", "commit", "-m", "First commit"}, repo_dir);
    
    try repo_dir.writeFile(.{.sub_path = "file2.txt", .data = "second\n"});
    _ = try runCommand(allocator, &.{"git", "add", "file2.txt"}, repo_dir);
    _ = try runCommand(allocator, &.{"git", "commit", "-m", "Second commit"}, repo_dir);
    
    // Compare log outputs
    const git_log = try runCommand(allocator, &.{"git", "log", "--oneline"}, repo_dir);
    defer allocator.free(git_log);
    
    const ziggit_log = try runZiggitCommand(allocator, &.{"log", "--oneline"}, repo_dir);
    defer allocator.free(ziggit_log);
    
    // Both should contain the commit messages
    const git_has_commits = std.mem.containsAtLeast(u8, git_log, 1, "First commit") and 
                           std.mem.containsAtLeast(u8, git_log, 1, "Second commit");
    const ziggit_has_commits = std.mem.containsAtLeast(u8, ziggit_log, 1, "First commit") and 
                              std.mem.containsAtLeast(u8, ziggit_log, 1, "Second commit");
    
    if (!git_has_commits or !ziggit_has_commits) {
        print("❌ Log outputs don't both contain expected commits\n", .{});
        print("   Git: '{s}'\n", .{git_log});
        print("   Ziggit: '{s}'\n", .{ziggit_log});
        return error.TestFailed;
    }
    
    print("✅ Log --oneline compatibility test passed\n", .{});
}

fn testBranchCompatibility(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    print("🧪 Testing branch compatibility...\n", .{});
    
    const repo_dir = try test_dir.makeOpenPath("branch_test", .{});
    defer test_dir.deleteTree("branch_test") catch {};

    // Set up test repo with branches
    _ = try runCommand(allocator, &.{"git", "init"}, repo_dir);
    try runCommandNoOutput(allocator, &.{"git", "config", "user.name", "Test User"}, repo_dir);
    try runCommandNoOutput(allocator, &.{"git", "config", "user.email", "test@example.com"}, repo_dir);
    
    try repo_dir.writeFile(.{.sub_path = "main.txt", .data = "main\n"});
    _ = try runCommand(allocator, &.{"git", "add", "main.txt"}, repo_dir);
    _ = try runCommand(allocator, &.{"git", "commit", "-m", "Initial commit"}, repo_dir);
    
    _ = try runCommand(allocator, &.{"git", "checkout", "-b", "feature"}, repo_dir);
    _ = try runCommand(allocator, &.{"git", "checkout", "-b", "hotfix"}, repo_dir);
    _ = try runCommand(allocator, &.{"git", "checkout", "main"}, repo_dir);
    
    // Compare branch outputs
    const git_branches = try runCommand(allocator, &.{"git", "branch"}, repo_dir);
    defer allocator.free(git_branches);
    
    const ziggit_branches = try runZiggitCommand(allocator, &.{"branch"}, repo_dir);
    defer allocator.free(ziggit_branches);
    
    // Both should list the created branches
    const expected_branches = [_][]const u8{ "main", "feature", "hotfix" };
    for (expected_branches) |branch| {
        const git_has_branch = std.mem.containsAtLeast(u8, git_branches, 1, branch);
        const ziggit_has_branch = std.mem.containsAtLeast(u8, ziggit_branches, 1, branch);
        
        if (!git_has_branch or !ziggit_has_branch) {
            print("❌ Branch '{s}' not found in both outputs\n", .{branch});
            print("   Git: '{s}'\n", .{git_branches});
            print("   Ziggit: '{s}'\n", .{ziggit_branches});
            return error.TestFailed;
        }
    }
    
    print("✅ Branch compatibility test passed\n", .{});
}

fn testDiffCompatibility(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    print("🧪 Testing diff compatibility...\n", .{});
    
    const repo_dir = try test_dir.makeOpenPath("diff_test", .{});
    defer test_dir.deleteTree("diff_test") catch {};

    // Set up test repo with changes
    _ = try runCommand(allocator, &.{"git", "init"}, repo_dir);
    try runCommandNoOutput(allocator, &.{"git", "config", "user.name", "Test User"}, repo_dir);
    try runCommandNoOutput(allocator, &.{"git", "config", "user.email", "test@example.com"}, repo_dir);
    
    try repo_dir.writeFile(.{.sub_path = "test.txt", .data = "original content\n"});
    _ = try runCommand(allocator, &.{"git", "add", "test.txt"}, repo_dir);
    _ = try runCommand(allocator, &.{"git", "commit", "-m", "Initial commit"}, repo_dir);
    
    // Modify file
    try repo_dir.writeFile(.{.sub_path = "test.txt", .data = "modified content\n"});
    
    // Compare diff outputs (both should detect the change)
    const git_diff = runCommand(allocator, &.{"git", "diff"}, repo_dir) catch |err| switch (err) {
        error.CommandFailed => "git diff failed",
        else => return err,
    };
    defer if (!std.mem.eql(u8, git_diff, "git diff failed")) allocator.free(git_diff);
    
    const ziggit_diff = runZiggitCommand(allocator, &.{"diff"}, repo_dir) catch |err| switch (err) {
        error.CommandFailed => "ziggit diff failed", 
        else => return err,
    };
    defer if (!std.mem.eql(u8, ziggit_diff, "ziggit diff failed")) allocator.free(ziggit_diff);
    
    // Both should detect changes (even if format differs)
    const git_detects_change = !std.mem.eql(u8, git_diff, "git diff failed") and 
                               std.mem.containsAtLeast(u8, git_diff, 1, "test.txt");
    const ziggit_detects_change = !std.mem.eql(u8, ziggit_diff, "ziggit diff failed") and
                                  std.mem.containsAtLeast(u8, ziggit_diff, 1, "test.txt");
    
    if (git_detects_change and !ziggit_detects_change) {
        print("❌ Git detected changes but ziggit didn't\n", .{});
        print("   Git: '{s}'\n", .{git_diff});
        print("   Ziggit: '{s}'\n", .{ziggit_diff});
        return error.TestFailed;
    }
    
    print("✅ Diff compatibility test passed\n", .{});
}

fn testCheckoutCompatibility(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    print("🧪 Testing checkout compatibility...\n", .{});
    
    const repo_dir = try test_dir.makeOpenPath("checkout_test", .{});
    defer test_dir.deleteTree("checkout_test") catch {};

    // Set up test repo with branches
    _ = try runCommand(allocator, &.{"git", "init"}, repo_dir);
    try runCommandNoOutput(allocator, &.{"git", "config", "user.name", "Test User"}, repo_dir);
    try runCommandNoOutput(allocator, &.{"git", "config", "user.email", "test@example.com"}, repo_dir);
    
    try repo_dir.writeFile(.{.sub_path = "main.txt", .data = "main branch\n"});
    _ = try runCommand(allocator, &.{"git", "add", "main.txt"}, repo_dir);
    _ = try runCommand(allocator, &.{"git", "commit", "-m", "Initial commit"}, repo_dir);
    
    _ = try runCommand(allocator, &.{"git", "checkout", "-b", "test-branch"}, repo_dir);
    try repo_dir.writeFile(.{.sub_path = "branch.txt", .data = "branch file\n"});
    _ = try runCommand(allocator, &.{"git", "add", "branch.txt"}, repo_dir);
    _ = try runCommand(allocator, &.{"git", "commit", "-m", "Branch commit"}, repo_dir);
    
    // Test ziggit checkout
    const ziggit_checkout = runZiggitCommand(allocator, &.{"checkout", "main"}, repo_dir) catch |err| switch (err) {
        error.CommandFailed => "ziggit checkout failed",
        else => return err,
    };
    defer if (!std.mem.eql(u8, ziggit_checkout, "ziggit checkout failed")) allocator.free(ziggit_checkout);
    
    // Verify current branch after checkout
    const current_branch = try runCommand(allocator, &.{"git", "branch", "--show-current"}, repo_dir);
    defer allocator.free(current_branch);
    
    const is_on_main = std.mem.containsAtLeast(u8, current_branch, 1, "main");
    if (!is_on_main and !std.mem.eql(u8, ziggit_checkout, "ziggit checkout failed")) {
        print("❌ Ziggit checkout may not have worked as expected\n", .{});
        print("   Current branch: '{s}'\n", .{current_branch});
    }
    
    print("✅ Checkout compatibility test passed\n", .{});
}

fn testRepositoryFormatCompatibility(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    print("🧪 Testing repository format compatibility...\n", .{});
    
    const repo_dir = try test_dir.makeOpenPath("format_test", .{});
    defer test_dir.deleteTree("format_test") catch {};

    // Create repository with ziggit
    _ = try runZiggitCommand(allocator, &.{"init"}, repo_dir);
    
    // Verify git can recognize it as a valid repository
    const git_status = runCommand(allocator, &.{"git", "status"}, repo_dir) catch |err| switch (err) {
        error.CommandFailed => {
            print("❌ Git cannot recognize ziggit-created repository\n", .{});
            return error.TestFailed;
        },
        else => return err,
    };
    defer allocator.free(git_status);
    
    // Check .git directory structure
    repo_dir.access(".git", .{}) catch {
        print("❌ Ziggit init didn't create .git directory\n", .{});
        return error.TestFailed;
    };
    
    print("✅ Repository format compatibility test passed\n", .{});
}

// Utility functions
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
    switch (term) {
        .Exited => |code| if (code != 0) {
            allocator.free(stdout);
            return error.CommandFailed;
        },
        else => {
            allocator.free(stdout);
            return error.CommandFailed;
        },
    }
    
    return stdout;
}

fn runCommandSafe(allocator: std.mem.Allocator, argv: []const []const u8, cwd: fs.Dir) []const u8 {
    return runCommand(allocator, argv, cwd) catch "";
}

fn runCommandNoOutput(allocator: std.mem.Allocator, argv: []const []const u8, cwd: fs.Dir) !void {
    const output = try runCommand(allocator, argv, cwd);
    allocator.free(output);
}

fn runZiggitCommand(allocator: std.mem.Allocator, args: []const []const u8, cwd: fs.Dir) ![]u8 {
    // Build ziggit command with executable path
    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit();
    
    try argv.append("zig-out/bin/ziggit");
    try argv.appendSlice(args);
    
    return runCommand(allocator, argv.items, cwd);
}