const std = @import("std");
const GitTestFramework = @import("git_test_framework.zig").GitTestFramework;
const compareGitZiggitOutput = @import("git_test_framework.zig").compareGitZiggitOutput;

// Test: Basic commit with -m message
fn testBasicCommit(framework: *GitTestFramework) !void {
    const test_dir = try framework.createTestRepo("basic-commit");
    defer framework.allocator.free(test_dir);

    // Initialize repo
    const init_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{"init"});
    defer init_result.deinit(framework.allocator);
    try framework.expectExitCode(0, init_result);

    // Create and add file
    try framework.writeFile(test_dir, "test.txt", "Hello, World!\n");
    
    const add_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{ "add", "test.txt" });
    defer add_result.deinit(framework.allocator);
    try framework.expectExitCode(0, add_result);

    // Commit with message
    const commit_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{ "commit", "-m", "Initial commit" });
    defer commit_result.deinit(framework.allocator);
    try framework.expectExitCode(0, commit_result);

    // Verify with log
    const log_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{"log"});
    defer log_result.deinit(framework.allocator);
    try framework.expectExitCode(0, log_result);

    // Should show our commit message
    if (std.mem.indexOf(u8, log_result.stdout, "Initial commit") == null) {
        return error.CommitMessageNotFound;
    }
}

// Test: Empty commit (should fail without --allow-empty)
fn testEmptyCommit(framework: *GitTestFramework) !void {
    const test_dir = try framework.createTestRepo("empty-commit");
    defer framework.allocator.free(test_dir);

    // Initialize repo
    const init_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{"init"});
    defer init_result.deinit(framework.allocator);
    try framework.expectExitCode(0, init_result);

    // Try to commit without adding anything
    const commit_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{ "commit", "-m", "Empty commit" });
    defer commit_result.deinit(framework.allocator);
    
    // Should fail
    if (commit_result.exit_code == 0) {
        return error.ExpectedCommitToFail;
    }

    // Compare with git behavior
    const git_test_dir = try framework.createTestRepo("empty-commit-git");
    defer framework.allocator.free(git_test_dir);
    
    var git_init = try framework.runGitCommand(git_test_dir, &[_][]const u8{"init"});
    defer git_init.deinit(framework.allocator);
    
    var git_commit = try framework.runGitCommand(git_test_dir, &[_][]const u8{ "commit", "-m", "Empty commit" });
    defer git_commit.deinit(framework.allocator);
    
    // Git should also fail
    if (git_commit.exit_code == 0) {
        return error.GitShouldAlsoFail;
    }
}

// Test: Commit with --allow-empty
fn testAllowEmptyCommit(framework: *GitTestFramework) !void {
    const test_dir = try framework.createTestRepo("allow-empty");
    defer framework.allocator.free(test_dir);

    // Initialize repo
    const init_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{"init"});
    defer init_result.deinit(framework.allocator);
    try framework.expectExitCode(0, init_result);

    // Commit with --allow-empty
    const commit_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{ "commit", "--allow-empty", "-m", "Empty commit allowed" });
    defer commit_result.deinit(framework.allocator);
    try framework.expectExitCode(0, commit_result);

    // Verify with log
    const log_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{"log"});
    defer log_result.deinit(framework.allocator);
    try framework.expectExitCode(0, log_result);

    // Should show our commit message
    if (std.mem.indexOf(u8, log_result.stdout, "Empty commit allowed") == null) {
        return error.CommitMessageNotFound;
    }
}

// Test: Multiple commits and log history
fn testMultipleCommits(framework: *GitTestFramework) !void {
    const test_dir = try framework.createTestRepo("multiple-commits");
    defer framework.allocator.free(test_dir);

    // Initialize repo
    const init_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{"init"});
    defer init_result.deinit(framework.allocator);
    try framework.expectExitCode(0, init_result);

    // First commit
    try framework.writeFile(test_dir, "file1.txt", "First file\n");
    var add1_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{ "add", "file1.txt" });
    defer add1_result.deinit(framework.allocator);
    try framework.expectExitCode(0, add1_result);

    var commit1_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{ "commit", "-m", "First commit" });
    defer commit1_result.deinit(framework.allocator);
    try framework.expectExitCode(0, commit1_result);

    // Second commit
    try framework.writeFile(test_dir, "file2.txt", "Second file\n");
    var add2_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{ "add", "file2.txt" });
    defer add2_result.deinit(framework.allocator);
    try framework.expectExitCode(0, add2_result);

    var commit2_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{ "commit", "-m", "Second commit" });
    defer commit2_result.deinit(framework.allocator);
    try framework.expectExitCode(0, commit2_result);

    // Third commit
    try framework.writeFile(test_dir, "file3.txt", "Third file\n");
    var add3_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{ "add", "file3.txt" });
    defer add3_result.deinit(framework.allocator);
    try framework.expectExitCode(0, add3_result);

    var commit3_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{ "commit", "-m", "Third commit" });
    defer commit3_result.deinit(framework.allocator);
    try framework.expectExitCode(0, commit3_result);

    // Verify log shows all commits in reverse chronological order
    const log_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{"log"});
    defer log_result.deinit(framework.allocator);
    try framework.expectExitCode(0, log_result);

    // Should show all commit messages
    if (std.mem.indexOf(u8, log_result.stdout, "First commit") == null or
        std.mem.indexOf(u8, log_result.stdout, "Second commit") == null or
        std.mem.indexOf(u8, log_result.stdout, "Third commit") == null) {
        return error.NotAllCommitsInLog;
    }

    // Third commit should appear before first commit in log (newest first)
    const third_pos = std.mem.indexOf(u8, log_result.stdout, "Third commit") orelse return error.ThirdCommitNotFound;
    const first_pos = std.mem.indexOf(u8, log_result.stdout, "First commit") orelse return error.FirstCommitNotFound;
    
    if (third_pos > first_pos) {
        return error.LogNotInReverseChronologicalOrder;
    }
}

// Test: Commit without message (should fail)
fn testCommitWithoutMessage(framework: *GitTestFramework) !void {
    const test_dir = try framework.createTestRepo("no-message");
    defer framework.allocator.free(test_dir);

    // Initialize repo and add file
    const init_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{"init"});
    defer init_result.deinit(framework.allocator);
    try framework.expectExitCode(0, init_result);

    try framework.writeFile(test_dir, "test.txt", "Test content\n");
    
    const add_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{ "add", "test.txt" });
    defer add_result.deinit(framework.allocator);
    try framework.expectExitCode(0, add_result);

    // Try to commit without -m
    const commit_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{"commit"});
    defer commit_result.deinit(framework.allocator);
    
    // Should fail (in our simple implementation; git would open editor)
    if (commit_result.exit_code == 0) {
        return error.ExpectedCommitToFail;
    }
}

// Test: Commit amend (basic)
fn testCommitAmend(framework: *GitTestFramework) !void {
    const test_dir = try framework.createTestRepo("commit-amend");
    defer framework.allocator.free(test_dir);

    // Initialize repo
    const init_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{"init"});
    defer init_result.deinit(framework.allocator);
    try framework.expectExitCode(0, init_result);

    // Create initial commit
    try framework.writeFile(test_dir, "test.txt", "Initial content\n");
    
    const add_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{ "add", "test.txt" });
    defer add_result.deinit(framework.allocator);
    try framework.expectExitCode(0, add_result);

    const commit_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{ "commit", "-m", "Initial commit" });
    defer commit_result.deinit(framework.allocator);
    try framework.expectExitCode(0, commit_result);

    // Make another change and amend the commit
    try framework.writeFile(test_dir, "test.txt", "Modified content\n");
    
    var add2_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{ "add", "test.txt" });
    defer add2_result.deinit(framework.allocator);
    try framework.expectExitCode(0, add2_result);

    const amend_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{ "commit", "--amend", "-m", "Amended commit" });
    defer amend_result.deinit(framework.allocator);
    try framework.expectExitCode(0, amend_result);

    // Log should show only one commit with amended message
    const log_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{"log"});
    defer log_result.deinit(framework.allocator);
    try framework.expectExitCode(0, log_result);

    if (std.mem.indexOf(u8, log_result.stdout, "Amended commit") == null) {
        return error.AmendedCommitNotFound;
    }

    if (std.mem.indexOf(u8, log_result.stdout, "Initial commit") != null) {
        return error.OriginalCommitStillExists;
    }
}

// Test: Commit with author information
fn testCommitWithAuthor(framework: *GitTestFramework) !void {
    const test_dir = try framework.createTestRepo("commit-author");
    defer framework.allocator.free(test_dir);

    // Initialize repo
    const init_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{"init"});
    defer init_result.deinit(framework.allocator);
    try framework.expectExitCode(0, init_result);

    // Set git config for author
    var config1_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{ "config", "user.name", "Test Author" });
    defer config1_result.deinit(framework.allocator);

    var config2_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{ "config", "user.email", "test@example.com" });
    defer config2_result.deinit(framework.allocator);

    // Create and commit file
    try framework.writeFile(test_dir, "test.txt", "Test content\n");
    
    const add_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{ "add", "test.txt" });
    defer add_result.deinit(framework.allocator);
    try framework.expectExitCode(0, add_result);

    const commit_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{ "commit", "-m", "Test commit with author" });
    defer commit_result.deinit(framework.allocator);
    try framework.expectExitCode(0, commit_result);

    // Log should show author information
    const log_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{"log"});
    defer log_result.deinit(framework.allocator);
    try framework.expectExitCode(0, log_result);

    if (std.mem.indexOf(u8, log_result.stdout, "Test Author") == null) {
        return error.AuthorNotFound;
    }
}

// Test: Commit with long message
fn testCommitLongMessage(framework: *GitTestFramework) !void {
    const test_dir = try framework.createTestRepo("long-message");
    defer framework.allocator.free(test_dir);

    // Initialize repo
    const init_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{"init"});
    defer init_result.deinit(framework.allocator);
    try framework.expectExitCode(0, init_result);

    // Create and add file
    try framework.writeFile(test_dir, "test.txt", "Test content\n");
    
    const add_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{ "add", "test.txt" });
    defer add_result.deinit(framework.allocator);
    try framework.expectExitCode(0, add_result);

    // Commit with long message
    const long_message = "This is a very long commit message that spans multiple lines and contains detailed information about the changes being made to the repository. It should be properly stored and retrieved when viewing the log.";
    
    const commit_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{ "commit", "-m", long_message });
    defer commit_result.deinit(framework.allocator);
    try framework.expectExitCode(0, commit_result);

    // Verify with log
    const log_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{"log"});
    defer log_result.deinit(framework.allocator);
    try framework.expectExitCode(0, log_result);

    // Should show the full long message
    if (std.mem.indexOf(u8, log_result.stdout, "very long commit message") == null) {
        return error.LongMessageNotFound;
    }
}

pub fn runCommitTests() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var framework = try GitTestFramework.init(allocator);
    defer framework.deinit();

    std.debug.print("Running t3000 Commit Tests (Comprehensive)...\n", .{});

    try framework.testExpectSuccess("basic commit with message", testBasicCommit);
    try framework.testExpectSuccess("empty commit (should fail)", testEmptyCommit);
    try framework.testExpectSuccess("commit with --allow-empty", testAllowEmptyCommit);
    try framework.testExpectSuccess("multiple commits and log history", testMultipleCommits);
    try framework.testExpectSuccess("commit without message (should fail)", testCommitWithoutMessage);
    try framework.testExpectSuccess("commit amend", testCommitAmend);
    try framework.testExpectSuccess("commit with author info", testCommitWithAuthor);
    try framework.testExpectSuccess("commit with long message", testCommitLongMessage);

    framework.summary();
    
    if (framework.failed_counter > 0) {
        std.process.exit(1);
    }
}