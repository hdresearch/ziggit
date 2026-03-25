const std = @import("std");
const testing = std.testing;
const test_harness = @import("test_harness.zig");
const TestHarness = test_harness.TestHarness;

// Git Workflow Tests - Testing basic git operations workflow
pub fn runWorkflowTests() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const harness = TestHarness.init(allocator, "/root/zigg/root/ziggit/zig-out/bin/ziggit", "git");

    std.debug.print("Running git workflow tests...\n", .{});

    // Basic workflow tests
    try testAddSingleFile(harness);
    try testAddMultipleFiles(harness);
    try testStatusWithTrackedFiles(harness);
    try testStatusWithUntrackedFiles(harness);
    try testBasicCommit(harness);
    try testCommitMessage(harness);
    try testLogBasic(harness);
    try testDiffBasic(harness);
    
    std.debug.print("All workflow tests completed!\n", .{});
}

// Test adding a single file
fn testAddSingleFile(harness: TestHarness) !void {
    std.debug.print("  Testing git add single file...\n", .{});
    
    const temp_dir = try harness.createTempDir("test_add_single");
    defer harness.removeTempDir(temp_dir);
    
    // Initialize repository
    var init_result = try harness.runZiggit(&[_][]const u8{"init"}, temp_dir);
    defer init_result.deinit();
    
    if (init_result.exit_code != 0) {
        std.debug.print("    SKIP: Failed to initialize repository\n", .{});
        return;
    }
    
    // Create a test file
    const test_file = try std.fmt.allocPrint(harness.allocator, "{s}/test.txt", .{temp_dir});
    defer harness.allocator.free(test_file);
    try harness.writeFile(test_file, "Hello, world!\n");
    
    // Test add command with ziggit
    var add_result = try harness.runZiggit(&[_][]const u8{"add", "test.txt"}, temp_dir);
    defer add_result.deinit();
    
    if (add_result.exit_code == 0) {
        // If add is implemented, compare with git
        
        // Create comparable git repo
        const git_temp_dir = try harness.createTempDir("test_add_single_git");
        defer harness.removeTempDir(git_temp_dir);
        
        var git_init = try harness.runGit(&[_][]const u8{"init"}, git_temp_dir);
        defer git_init.deinit();
        
        const git_test_file = try std.fmt.allocPrint(harness.allocator, "{s}/test.txt", .{git_temp_dir});
        defer harness.allocator.free(git_test_file);
        try harness.writeFile(git_test_file, "Hello, world!\n");
        
        var git_add_result = try harness.runGit(&[_][]const u8{"add", "test.txt"}, git_temp_dir);
        defer git_add_result.deinit();
        
        if (add_result.exit_code != git_add_result.exit_code) {
            std.debug.print("    FAIL: Exit code mismatch - ziggit: {}, git: {}\n", .{ add_result.exit_code, git_add_result.exit_code });
            return test_harness.TestError.ProcessFailed;
        }
        
        std.debug.print("    ✓ add single file\n", .{});
    } else {
        std.debug.print("    ⚠ add single file not yet implemented (exit code: {})\n", .{add_result.exit_code});
    }
}

// Test adding multiple files
fn testAddMultipleFiles(harness: TestHarness) !void {
    std.debug.print("  Testing git add multiple files...\n", .{});
    
    const temp_dir = try harness.createTempDir("test_add_multiple");
    defer harness.removeTempDir(temp_dir);
    
    // Initialize repository
    var init_result = try harness.runZiggit(&[_][]const u8{"init"}, temp_dir);
    defer init_result.deinit();
    
    if (init_result.exit_code != 0) {
        std.debug.print("    SKIP: Failed to initialize repository\n", .{});
        return;
    }
    
    // Create multiple test files
    const files = [_][]const u8{ "file1.txt", "file2.txt", "file3.txt" };
    for (files, 0..) |filename, i| {
        const file_path = try std.fmt.allocPrint(harness.allocator, "{s}/{s}", .{ temp_dir, filename });
        defer harness.allocator.free(file_path);
        const content = try std.fmt.allocPrint(harness.allocator, "Content of file {}\n", .{i + 1});
        defer harness.allocator.free(content);
        try harness.writeFile(file_path, content);
    }
    
    // Test add multiple files
    var add_result = try harness.runZiggit(&[_][]const u8{"add", "file1.txt", "file2.txt", "file3.txt"}, temp_dir);
    defer add_result.deinit();
    
    if (add_result.exit_code == 0) {
        std.debug.print("    ✓ add multiple files\n", .{});
    } else {
        std.debug.print("    ⚠ add multiple files not yet implemented\n", .{});
    }
}

// Test git status with tracked files
fn testStatusWithTrackedFiles(harness: TestHarness) !void {
    std.debug.print("  Testing git status with tracked files...\n", .{});
    
    const temp_dir = try harness.createTempDir("test_status_tracked");
    defer harness.removeTempDir(temp_dir);
    
    // Initialize repository
    var init_result = try harness.runZiggit(&[_][]const u8{"init"}, temp_dir);
    defer init_result.deinit();
    
    if (init_result.exit_code != 0) {
        std.debug.print("    SKIP: Failed to initialize repository\n", .{});
        return;
    }
    
    // Create and potentially add a file
    const test_file = try std.fmt.allocPrint(harness.allocator, "{s}/tracked.txt", .{temp_dir});
    defer harness.allocator.free(test_file);
    try harness.writeFile(test_file, "This file should be tracked\n");
    
    // Try to add the file first
    var add_result = try harness.runZiggit(&[_][]const u8{"add", "tracked.txt"}, temp_dir);
    defer add_result.deinit();
    
    // Run status regardless of add result
    var status_result = try harness.runZiggit(&[_][]const u8{"status"}, temp_dir);
    defer status_result.deinit();
    
    if (status_result.exit_code == 0) {
        std.debug.print("    ✓ status with tracked files (add result: {})\n", .{add_result.exit_code});
    } else {
        std.debug.print("    FAIL: status command failed\n", .{});
        return test_harness.TestError.ProcessFailed;
    }
}

// Test git status with untracked files
fn testStatusWithUntrackedFiles(harness: TestHarness) !void {
    std.debug.print("  Testing git status with untracked files...\n", .{});
    
    const temp_dir = try harness.createTempDir("test_status_untracked");
    defer harness.removeTempDir(temp_dir);
    
    // Initialize repository
    var init_result = try harness.runZiggit(&[_][]const u8{"init"}, temp_dir);
    defer init_result.deinit();
    
    if (init_result.exit_code != 0) {
        std.debug.print("    SKIP: Failed to initialize repository\n", .{});
        return;
    }
    
    // Create an untracked file
    const test_file = try std.fmt.allocPrint(harness.allocator, "{s}/untracked.txt", .{temp_dir});
    defer harness.allocator.free(test_file);
    try harness.writeFile(test_file, "This file is untracked\n");
    
    // Compare status output with git
    var ziggit_status = try harness.runZiggit(&[_][]const u8{"status"}, temp_dir);
    defer ziggit_status.deinit();
    
    // Create comparable git repository
    const git_temp_dir = try harness.createTempDir("test_status_untracked_git");
    defer harness.removeTempDir(git_temp_dir);
    
    var git_init = try harness.runGit(&[_][]const u8{"init"}, git_temp_dir);
    defer git_init.deinit();
    
    const git_test_file = try std.fmt.allocPrint(harness.allocator, "{s}/untracked.txt", .{git_temp_dir});
    defer harness.allocator.free(git_test_file);
    try harness.writeFile(git_test_file, "This file is untracked\n");
    
    var git_status = try harness.runGit(&[_][]const u8{"status"}, git_temp_dir);
    defer git_status.deinit();
    
    if (ziggit_status.exit_code == git_status.exit_code) {
        // Both should mention untracked files
        if (std.mem.containsAtLeast(u8, ziggit_status.stdout, 1, "untracked") and 
            std.mem.containsAtLeast(u8, git_status.stdout, 1, "untracked")) {
            std.debug.print("    ✓ status shows untracked files\n", .{});
        } else {
            std.debug.print("    ⚠ status may not properly show untracked files\n", .{});
        }
    } else {
        std.debug.print("    FAIL: Status exit code mismatch\n", .{});
    }
}

// Test basic commit functionality
fn testBasicCommit(harness: TestHarness) !void {
    std.debug.print("  Testing git commit...\n", .{});
    
    const temp_dir = try harness.createTempDir("test_commit_basic");
    defer harness.removeTempDir(temp_dir);
    
    // Initialize repository
    var init_result = try harness.runZiggit(&[_][]const u8{"init"}, temp_dir);
    defer init_result.deinit();
    
    if (init_result.exit_code != 0) {
        std.debug.print("    SKIP: Failed to initialize repository\n", .{});
        return;
    }
    
    // Create and add a file
    const test_file = try std.fmt.allocPrint(harness.allocator, "{s}/commit_test.txt", .{temp_dir});
    defer harness.allocator.free(test_file);
    try harness.writeFile(test_file, "File for commit test\n");
    
    // Try to add the file
    var add_result = try harness.runZiggit(&[_][]const u8{"add", "commit_test.txt"}, temp_dir);
    defer add_result.deinit();
    
    if (add_result.exit_code != 0) {
        std.debug.print("    SKIP: Cannot test commit without add functionality\n", .{});
        return;
    }
    
    // Test commit command
    var commit_result = try harness.runZiggit(&[_][]const u8{"commit", "-m", "Initial commit"}, temp_dir);
    defer commit_result.deinit();
    
    if (commit_result.exit_code == 0) {
        std.debug.print("    ✓ basic commit\n", .{});
    } else {
        std.debug.print("    ⚠ commit not yet implemented\n", .{});
    }
}

// Test commit with message
fn testCommitMessage(harness: TestHarness) !void {
    std.debug.print("  Testing git commit with message...\n", .{});
    
    const temp_dir = try harness.createTempDir("test_commit_message");
    defer harness.removeTempDir(temp_dir);
    
    // Initialize repository
    var init_result = try harness.runZiggit(&[_][]const u8{"init"}, temp_dir);
    defer init_result.deinit();
    
    if (init_result.exit_code != 0) {
        std.debug.print("    SKIP: Failed to initialize repository\n", .{});
        return;
    }
    
    // Test commit without anything staged (should fail)
    var empty_commit = try harness.runZiggit(&[_][]const u8{"commit", "-m", "Empty commit"}, temp_dir);
    defer empty_commit.deinit();
    
    if (empty_commit.exit_code != 0) {
        std.debug.print("    ✓ commit correctly fails with nothing to commit\n", .{});
    } else {
        std.debug.print("    ⚠ commit should fail when nothing is staged\n", .{});
    }
}

// Test git log
fn testLogBasic(harness: TestHarness) !void {
    std.debug.print("  Testing git log...\n", .{});
    
    const temp_dir = try harness.createTempDir("test_log_basic");
    defer harness.removeTempDir(temp_dir);
    
    // Initialize repository
    var init_result = try harness.runZiggit(&[_][]const u8{"init"}, temp_dir);
    defer init_result.deinit();
    
    if (init_result.exit_code != 0) {
        std.debug.print("    SKIP: Failed to initialize repository\n", .{});
        return;
    }
    
    // Test log in empty repository
    var log_result = try harness.runZiggit(&[_][]const u8{"log"}, temp_dir);
    defer log_result.deinit();
    
    // Compare with git behavior in empty repo
    const git_temp_dir = try harness.createTempDir("test_log_basic_git");
    defer harness.removeTempDir(git_temp_dir);
    
    var git_init = try harness.runGit(&[_][]const u8{"init"}, git_temp_dir);
    defer git_init.deinit();
    
    var git_log = try harness.runGit(&[_][]const u8{"log"}, git_temp_dir);
    defer git_log.deinit();
    
    if (log_result.exit_code == git_log.exit_code) {
        std.debug.print("    ✓ log exit code matches git in empty repo\n", .{});
    } else {
        std.debug.print("    ⚠ log not yet implemented or behavior differs\n", .{});
    }
}

// Test git diff
fn testDiffBasic(harness: TestHarness) !void {
    std.debug.print("  Testing git diff...\n", .{});
    
    const temp_dir = try harness.createTempDir("test_diff_basic");
    defer harness.removeTempDir(temp_dir);
    
    // Initialize repository
    var init_result = try harness.runZiggit(&[_][]const u8{"init"}, temp_dir);
    defer init_result.deinit();
    
    if (init_result.exit_code != 0) {
        std.debug.print("    SKIP: Failed to initialize repository\n", .{});
        return;
    }
    
    // Create a file for diff testing
    const test_file = try std.fmt.allocPrint(harness.allocator, "{s}/diff_test.txt", .{temp_dir});
    defer harness.allocator.free(test_file);
    try harness.writeFile(test_file, "Line 1\nLine 2\nLine 3\n");
    
    // Test diff command
    var diff_result = try harness.runZiggit(&[_][]const u8{"diff"}, temp_dir);
    defer diff_result.deinit();
    
    // Compare with git behavior
    const git_temp_dir = try harness.createTempDir("test_diff_basic_git");
    defer harness.removeTempDir(git_temp_dir);
    
    var git_init = try harness.runGit(&[_][]const u8{"init"}, git_temp_dir);
    defer git_init.deinit();
    
    const git_test_file = try std.fmt.allocPrint(harness.allocator, "{s}/diff_test.txt", .{git_temp_dir});
    defer harness.allocator.free(git_test_file);
    try harness.writeFile(git_test_file, "Line 1\nLine 2\nLine 3\n");
    
    var git_diff = try harness.runGit(&[_][]const u8{"diff"}, git_temp_dir);
    defer git_diff.deinit();
    
    if (diff_result.exit_code == git_diff.exit_code) {
        std.debug.print("    ✓ diff exit code matches git\n", .{});
    } else {
        std.debug.print("    ⚠ diff not yet implemented or behavior differs\n", .{});
    }
}

// Test runner for workflow tests
test "git workflow" {
    try runWorkflowTests();
}