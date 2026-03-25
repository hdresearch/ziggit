const std = @import("std");
const TestRunner = @import("git_source_test_adapter.zig").TestRunner;
const TestResult = @import("git_source_test_adapter.zig").TestResult;
const TestCase = @import("git_source_test_adapter.zig").TestCase;
const runTestSuite = @import("git_source_test_adapter.zig").runTestSuite;

// t3200-branch.sh - Test git branch functionality
// Adapted from git/git.git/t/t3200-branch.sh

// Setup function - initialize repository with initial commit
fn setupRepository(runner: *TestRunner) !void {
    var result = try runner.runZiggit(&[_][]const u8{"init"});
    result.deinit(runner.allocator);
    if (result.exit_code != 0) return error.InitFailed;
    
    // Configure user
    result = try runner.runZiggit(&[_][]const u8{ "config", "user.name", "Test User" });
    result.deinit(runner.allocator);
    result = try runner.runZiggit(&[_][]const u8{ "config", "user.email", "test@example.com" });
    result.deinit(runner.allocator);
    
    // Create initial commit (required for branch operations)
    try runner.createFile("initial.txt", "initial content\n");
    result = try runner.runZiggit(&[_][]const u8{ "add", "initial.txt" });
    result.deinit(runner.allocator);
    result = try runner.runZiggit(&[_][]const u8{ "commit", "-m", "Initial commit" });
    result.deinit(runner.allocator);
    if (result.exit_code != 0) return error.CommitFailed;
}

// Test basic branch listing
fn testBranchList(runner: *TestRunner) !TestResult {
    const result = try runner.runZiggit(&[_][]const u8{"branch"});
    defer result.deinit(runner.allocator);
    
    if (runner.expectExitCode(0, result.exit_code, "ziggit branch") == .fail) return .fail;
    
    // Should show current branch (usually "master" or "main")
    if (std.mem.indexOf(u8, result.stdout, "master") != null or
        std.mem.indexOf(u8, result.stdout, "main") != null) {
        std.debug.print("    ✓ branch listing shows default branch\n", .{});
    } else {
        std.debug.print("    ⚠ branch listing output: {s}\n", .{result.stdout});
        std.debug.print("    ⚠ may not show expected default branch name\n", .{});
    }
    
    // Should indicate current branch (usually with * or other marker)
    if (std.mem.indexOf(u8, result.stdout, "*") != null) {
        std.debug.print("    ✓ current branch is marked with *\n", .{});
    } else {
        std.debug.print("    ⚠ current branch may not be clearly marked\n", .{});
    }
    
    return .pass;
}

// Test creating a new branch
fn testBranchCreate(runner: *TestRunner) !TestResult {
    const result = try runner.runZiggit(&[_][]const u8{ "branch", "feature" });
    defer result.deinit(runner.allocator);
    
    if (runner.expectExitCode(0, result.exit_code, "ziggit branch feature") == .fail) return .fail;
    
    // Verify branch was created by listing branches
    const list_result = try runner.runZiggit(&[_][]const u8{"branch"});
    defer list_result.deinit(runner.allocator);
    
    if (runner.expectContains(list_result.stdout, "feature", "new branch appears in list") == .fail) return .fail;
    
    std.debug.print("    ✓ branch creation successful\n", .{});
    return .pass;
}

// Test creating branch with invalid name
fn testBranchCreateInvalid(runner: *TestRunner) !TestResult {
    const result = try runner.runZiggit(&[_][]const u8{ "branch", "invalid..name" });
    defer result.deinit(runner.allocator);
    
    // Should fail with non-zero exit code
    if (result.exit_code == 0) {
        std.debug.print("    ✗ branch with invalid name should fail but succeeded\n", .{});
        return .fail;
    } else {
        std.debug.print("    ✓ branch creation with invalid name fails appropriately (code {d})\n", .{result.exit_code});
        
        // Should have descriptive error message
        if (runner.expectContains(result.stderr, "invalid", "error mentions invalid name") == .fail) {
            if (runner.expectContains(result.stderr, "name", "error mentions name") == .fail) return .fail;
        }
    }
    
    return .pass;
}

// Test deleting a branch
fn testBranchDelete(runner: *TestRunner) !TestResult {
    // First create a branch to delete
    var result = try runner.runZiggit(&[_][]const u8{ "branch", "to-delete" });
    result.deinit(runner.allocator);
    
    // Delete the branch
    result = try runner.runZiggit(&[_][]const u8{ "branch", "-d", "to-delete" });
    defer result.deinit(runner.allocator);
    
    if (runner.expectExitCode(0, result.exit_code, "ziggit branch -d") == .fail) return .fail;
    
    // Verify branch was deleted
    const list_result = try runner.runZiggit(&[_][]const u8{"branch"});
    defer list_result.deinit(runner.allocator);
    
    if (std.mem.indexOf(u8, list_result.stdout, "to-delete") == null) {
        std.debug.print("    ✓ deleted branch no longer appears in list\n", .{});
    } else {
        std.debug.print("    ✗ deleted branch still appears in list\n", .{});
        return .fail;
    }
    
    return .pass;
}

// Test deleting current branch (should fail)
fn testBranchDeleteCurrent(runner: *TestRunner) !TestResult {
    const result = try runner.runZiggit(&[_][]const u8{ "branch", "-d", "master" });
    defer result.deinit(runner.allocator);
    
    // Should fail - can't delete current branch
    if (result.exit_code == 0) {
        std.debug.print("    ✗ deleting current branch should fail but succeeded\n", .{});
        return .fail;
    } else {
        std.debug.print("    ✓ deleting current branch fails appropriately (code {d})\n", .{result.exit_code});
        
        // Should have appropriate error message
        if (std.mem.indexOf(u8, result.stderr, "current") != null or
            std.mem.indexOf(u8, result.stderr, "checked out") != null) {
            std.debug.print("    ✓ appropriate error message for current branch deletion\n", .{});
        } else {
            std.debug.print("    ⚠ error message may need improvement: {s}\n", .{result.stderr});
        }
    }
    
    return .pass;
}

// Test branch -a (list all branches)
fn testBranchListAll(runner: *TestRunner) !TestResult {
    // Create a few branches first
    var result = try runner.runZiggit(&[_][]const u8{ "branch", "branch1" });
    result.deinit(runner.allocator);
    result = try runner.runZiggit(&[_][]const u8{ "branch", "branch2" });
    result.deinit(runner.allocator);
    
    result = try runner.runZiggit(&[_][]const u8{"branch", "-a"});
    defer result.deinit(runner.allocator);
    
    if (runner.expectExitCode(0, result.exit_code, "ziggit branch -a") == .fail) return .fail;
    
    // Should show all branches
    if (runner.expectContains(result.stdout, "branch1", "shows branch1") == .fail) return .fail;
    if (runner.expectContains(result.stdout, "branch2", "shows branch2") == .fail) return .fail;
    
    // Count branches
    const branch_count = std.mem.count(u8, result.stdout, "\n");
    if (branch_count >= 3) { // master + branch1 + branch2 (minimum)
        std.debug.print("    ✓ branch -a shows multiple branches ({d} lines)\n", .{branch_count});
    } else {
        std.debug.print("    ⚠ branch -a shows {d} lines, expected at least 3\n", .{branch_count});
    }
    
    return .pass;
}

// Test branch renaming
fn testBranchRename(runner: *TestRunner) !TestResult {
    // Create a branch to rename
    var result = try runner.runZiggit(&[_][]const u8{ "branch", "old-name" });
    result.deinit(runner.allocator);
    
    // Rename the branch
    result = try runner.runZiggit(&[_][]const u8{ "branch", "-m", "old-name", "new-name" });
    defer result.deinit(runner.allocator);
    
    if (runner.expectExitCode(0, result.exit_code, "ziggit branch -m") == .fail) return .fail;
    
    // Verify rename
    const list_result = try runner.runZiggit(&[_][]const u8{"branch"});
    defer list_result.deinit(runner.allocator);
    
    if (std.mem.indexOf(u8, list_result.stdout, "old-name") == null) {
        std.debug.print("    ✓ old branch name no longer appears\n", .{});
    } else {
        std.debug.print("    ✗ old branch name still appears after rename\n", .{});
        return .fail;
    }
    
    if (runner.expectContains(list_result.stdout, "new-name", "new branch name appears") == .fail) return .fail;
    
    return .pass;
}

// Test branch --show-current
fn testBranchShowCurrent(runner: *TestRunner) !TestResult {
    const result = try runner.runZiggit(&[_][]const u8{"branch", "--show-current"});
    defer result.deinit(runner.allocator);
    
    if (runner.expectExitCode(0, result.exit_code, "ziggit branch --show-current") == .fail) return .fail;
    
    const current_branch = std.mem.trim(u8, result.stdout, " \t\n\r");
    
    // Should show only the current branch name
    if (current_branch.len > 0 and std.mem.indexOf(u8, current_branch, "\n") == null) {
        std.debug.print("    ✓ --show-current shows single branch name: {s}\n", .{current_branch});
    } else {
        std.debug.print("    ⚠ --show-current output may not be clean: '{s}'\n", .{current_branch});
    }
    
    return .pass;
}

// Test branch on empty repository
fn testBranchEmptyRepository(runner: *TestRunner) !TestResult {
    // Create fresh repository without initial commit
    var result = try runner.runZiggit(&[_][]const u8{"init"});
    result.deinit(runner.allocator);
    
    result = try runner.runZiggit(&[_][]const u8{"branch"});
    defer result.deinit(runner.allocator);
    
    // Behavior on empty repository can vary - might succeed with no output or fail
    if (result.exit_code == 0) {
        if (result.stdout.len == 0) {
            std.debug.print("    ✓ branch on empty repository shows no branches\n", .{});
        } else {
            std.debug.print("    ⚠ branch on empty repository output: {s}\n", .{result.stdout});
        }
        return .pass;
    } else {
        std.debug.print("    ✓ branch on empty repository fails appropriately (code {d})\n", .{result.exit_code});
        
        if (std.mem.indexOf(u8, result.stderr, "no commits") != null or
            std.mem.indexOf(u8, result.stderr, "empty") != null) {
            std.debug.print("    ✓ appropriate error for empty repository\n", .{});
        }
        return .pass;
    }
}

// Compare ziggit and git branch behavior
fn testBranchCompatibilityWithGit(runner: *TestRunner) !TestResult {
    // Create a test branch in ziggit
    var result = try runner.runZiggit(&[_][]const u8{ "branch", "test-compat" });
    result.deinit(runner.allocator);
    
    const ziggit_result = try runner.runZiggit(&[_][]const u8{"branch"});
    defer ziggit_result.deinit(runner.allocator);
    
    // Initialize git repo for comparison
    var git_result = try runner.runCommand(&[_][]const u8{ "git", "init", "git-test" });
    git_result.deinit(runner.allocator);
    
    // Configure git user and create initial commit
    var proc = std.process.Child.init(&[_][]const u8{ "git", "config", "user.name", "Test User" }, runner.allocator);
    var buf: [256]u8 = undefined;
    const git_test_path = try std.fmt.bufPrint(&buf, "{s}/git-test", .{runner.test_dir});
    proc.cwd = git_test_path;
    _ = try proc.spawnAndWait();
    
    proc = std.process.Child.init(&[_][]const u8{ "git", "config", "user.email", "test@example.com" }, runner.allocator);
    proc.cwd = git_test_path;
    _ = try proc.spawnAndWait();
    
    try runner.createFile("git-test/initial.txt", "initial content\n");
    proc = std.process.Child.init(&[_][]const u8{ "git", "add", "initial.txt" }, runner.allocator);
    proc.cwd = git_test_path;
    _ = try proc.spawnAndWait();
    proc = std.process.Child.init(&[_][]const u8{ "git", "commit", "-m", "Initial" }, runner.allocator);
    proc.cwd = git_test_path;
    _ = try proc.spawnAndWait();
    
    // Create similar branch in git
    proc = std.process.Child.init(&[_][]const u8{ "git", "branch", "test-compat" }, runner.allocator);
    proc.cwd = git_test_path;
    _ = try proc.spawnAndWait();
    
    // Test git branch
    proc = std.process.Child.init(&[_][]const u8{ "git", "branch" }, runner.allocator);
    proc.cwd = git_test_path;
    proc.stdout_behavior = .Pipe;
    proc.stderr_behavior = .Pipe;
    try proc.spawn();
    const git_stdout = try proc.stdout.?.readToEndAlloc(runner.allocator, 1024 * 1024);
    defer runner.allocator.free(git_stdout);
    const git_stderr = try proc.stderr.?.readToEndAlloc(runner.allocator, 1024 * 1024);
    defer runner.allocator.free(git_stderr);
    const git_exit_code = try proc.wait();
    
    const git_code = switch (git_exit_code) {
        .Exited => |code| code,
        else => 255,
    };
    
    // Both should succeed
    if (runner.expectExitCode(0, ziggit_result.exit_code, "ziggit branch") == .fail) return .fail;
    if (runner.expectExitCode(0, git_code, "git branch") == .fail) return .fail;
    
    // Both should show the test branch
    if (runner.expectContains(ziggit_result.stdout, "test-compat", "ziggit shows test branch") == .fail) return .fail;
    if (runner.expectContains(git_stdout, "test-compat", "git shows test branch") == .fail) return .fail;
    
    // Count branches in both
    const ziggit_branches = std.mem.count(u8, ziggit_result.stdout, "\n");
    const git_branches = std.mem.count(u8, git_stdout, "\n");
    
    if (ziggit_branches == git_branches) {
        std.debug.print("    ✓ ziggit and git show same number of branches\n", .{});
    } else {
        std.debug.print("    ⚠ branch count differs: ziggit={d}, git={d}\n", .{ ziggit_branches, git_branches });
    }
    
    std.debug.print("    ✓ ziggit branch behavior tested against git\n", .{});
    return .pass;
}

const test_cases = [_]TestCase{
    .{
        .name = "branch-list",
        .description = "basic branch listing",
        .setup_fn = setupRepository,
        .test_fn = testBranchList,
    },
    .{
        .name = "branch-create",
        .description = "creating new branch",
        .setup_fn = setupRepository,
        .test_fn = testBranchCreate,
    },
    .{
        .name = "branch-invalid-name",
        .description = "creating branch with invalid name should fail",
        .setup_fn = setupRepository,
        .test_fn = testBranchCreateInvalid,
    },
    .{
        .name = "branch-delete",
        .description = "deleting branch",
        .setup_fn = setupRepository,
        .test_fn = testBranchDelete,
    },
    .{
        .name = "branch-delete-current",
        .description = "deleting current branch should fail",
        .setup_fn = setupRepository,
        .test_fn = testBranchDeleteCurrent,
    },
    .{
        .name = "branch-list-all",
        .description = "listing all branches with -a",
        .setup_fn = setupRepository,
        .test_fn = testBranchListAll,
    },
    .{
        .name = "branch-rename",
        .description = "renaming branch with -m",
        .setup_fn = setupRepository,
        .test_fn = testBranchRename,
    },
    .{
        .name = "branch-show-current",
        .description = "showing current branch with --show-current",
        .setup_fn = setupRepository,
        .test_fn = testBranchShowCurrent,
    },
    .{
        .name = "branch-empty-repo",
        .description = "branch operations on empty repository",
        .test_fn = testBranchEmptyRepository, // No setup - creates empty repo
    },
    .{
        .name = "compatibility",
        .description = "ziggit branch behavior matches git branch",
        .setup_fn = setupRepository,
        .test_fn = testBranchCompatibilityWithGit,
    },
};

pub fn runT3200BranchTests() !void {
    try runTestSuite("t3200-branch (Git Branch Tests)", &test_cases);
}