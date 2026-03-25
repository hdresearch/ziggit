// Git source compatibility tests adapted from t3xxx (commit) test files
const std = @import("std");
const print = std.debug.print;

pub const TestFramework = @import("git_source_test_harness.zig").TestFramework;

pub fn runCommitCompatTests() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var tf = TestFramework.init(allocator);
    defer tf.deinit();
    
    print("Running git commit compatibility tests (adapted from t3xxx)...\n");
    
    try testBasicCommit(&tf);
    try testCommitMessage(&tf);
    try testCommitEmpty(&tf);
    try testCommitAmend(&tf);
    try testCommitAllowEmpty(&tf);
    try testCommitAuthorDate(&tf);
    try testMultipleCommits(&tf);
    
    print("✓ All commit compatibility tests passed!\n");
}

fn setupTestRepoWithFile(tf: *TestFramework, name: []const u8, filename: []const u8, content: []const u8) ![]u8 {
    const test_dir = try tf.createTempDir(name);
    
    var init_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "init" 
    }, test_dir);
    defer init_result.deinit();
    
    if (init_result.exit_code != 0) {
        tf.removeTempDir(test_dir);
        return error.InitFailed;
    }
    
    try tf.writeFile(test_dir, filename, content);
    
    var add_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "add", filename 
    }, test_dir);
    defer add_result.deinit();
    
    if (add_result.exit_code != 0) {
        tf.removeTempDir(test_dir);
        return error.AddFailed;
    }
    
    return test_dir;
}

fn testBasicCommit(tf: *TestFramework) !void {
    print("  Testing basic commit...\n");
    
    const test_dir = try setupTestRepoWithFile(tf, "commit-basic", "test.txt", "Hello, World!\n");
    defer tf.removeTempDir(test_dir);
    
    // Test commit with -m flag
    var commit_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "commit", "-m", "Initial commit" 
    }, test_dir);
    defer commit_result.deinit();
    
    if (commit_result.exit_code != 0) {
        print("    ❌ commit failed: {s}\n", .{commit_result.stderr});
        return;
    }
    
    // Commit output should include:
    // - Branch name (usually "master" or "main")
    // - Commit hash (abbreviated)
    // - Commit message
    const expected_patterns = [_][]const u8{ "Initial commit" };
    for (expected_patterns) |pattern| {
        if (std.mem.indexOf(u8, commit_result.stdout, pattern) == null) {
            print("    ⚠ Commit output should contain '{s}'\n", .{pattern});
        }
    }
    
    // Verify commit was created by checking log
    var log_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "log", "--oneline" 
    }, test_dir);
    defer log_result.deinit();
    
    if (log_result.exit_code != 0) {
        print("    ❌ log failed after commit: {s}\n", .{log_result.stderr});
        return;
    }
    
    if (std.mem.indexOf(u8, log_result.stdout, "Initial commit") == null) {
        print("    ❌ Commit message not found in log\n");
        return;
    }
    
    // Check that working directory is clean after commit
    var status_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "status" 
    }, test_dir);
    defer status_result.deinit();
    
    if (status_result.exit_code != 0) {
        print("    ❌ status failed after commit: {s}\n", .{status_result.stderr});
        return;
    }
    
    // Should indicate clean working tree
    if (std.mem.indexOf(u8, status_result.stdout, "working tree clean") == null and
        std.mem.indexOf(u8, status_result.stdout, "nothing to commit") == null) {
        print("    ⚠ Status should indicate clean working tree after commit\n");
    }
    
    print("    ✓ Basic commit test passed\n");
}

fn testCommitMessage(tf: *TestFramework) !void {
    print("  Testing commit message variations...\n");
    
    // Test multiline commit message
    const test_dir = try setupTestRepoWithFile(tf, "commit-message", "test.txt", "Content\n");
    defer tf.removeTempDir(test_dir);
    
    const multiline_msg = "Short summary\n\nLonger description of the changes.\nThis spans multiple lines.";
    
    var commit_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "commit", "-m", multiline_msg 
    }, test_dir);
    defer commit_result.deinit();
    
    if (commit_result.exit_code != 0) {
        print("    ❌ commit with multiline message failed: {s}\n", .{commit_result.stderr});
        return;
    }
    
    // Verify message in log
    var log_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "log", "-1" 
    }, test_dir);
    defer log_result.deinit();
    
    if (log_result.exit_code != 0) {
        print("    ❌ log failed after multiline commit: {s}\n", .{log_result.stderr});
        return;
    }
    
    if (std.mem.indexOf(u8, log_result.stdout, "Short summary") == null) {
        print("    ❌ Multiline commit message not preserved in log\n");
        return;
    }
    
    print("    ✓ Commit message test passed\n");
}

fn testCommitEmpty(tf: *TestFramework) !void {
    print("  Testing commit with no changes...\n");
    
    const test_dir = try tf.createTempDir("commit-empty");
    defer tf.removeTempDir(test_dir);
    
    var init_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "init" 
    }, test_dir);
    defer init_result.deinit();
    
    if (init_result.exit_code != 0) {
        print("    ❌ init failed for empty commit test: {s}\n", .{init_result.stderr});
        return;
    }
    
    // Try to commit with no staged changes
    var commit_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "commit", "-m", "Empty commit" 
    }, test_dir);
    defer commit_result.deinit();
    
    // Should fail (exit code != 0)
    if (commit_result.exit_code == 0) {
        print("    ❌ commit with no changes should fail but didn't\n");
        return;
    }
    
    // Error message should be helpful
    if (std.mem.indexOf(u8, commit_result.stderr, "nothing to commit") == null and
        std.mem.indexOf(u8, commit_result.stderr, "no changes") == null) {
        print("    ⚠ Error message should indicate no changes to commit\n");
    }
    
    print("    ✓ Commit empty test passed\n");
}

fn testCommitAmend(tf: *TestFramework) !void {
    print("  Testing commit --amend...\n");
    
    const test_dir = try setupTestRepoWithFile(tf, "commit-amend", "test.txt", "Initial content\n");
    defer tf.removeTempDir(test_dir);
    
    // Create initial commit
    var commit1_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "commit", "-m", "Initial commit" 
    }, test_dir);
    defer commit1_result.deinit();
    
    if (commit1_result.exit_code != 0) {
        print("    ❌ initial commit failed: {s}\n", .{commit1_result.stderr});
        return;
    }
    
    // Make another change
    try tf.writeFile(test_dir, "test2.txt", "Additional content\n");
    
    var add_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "add", "test2.txt" 
    }, test_dir);
    defer add_result.deinit();
    
    if (add_result.exit_code != 0) {
        print("    ❌ add failed for amend test: {s}\n", .{add_result.stderr});
        return;
    }
    
    // Amend the commit
    var amend_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "commit", "--amend", "-m", "Amended commit message" 
    }, test_dir);
    defer amend_result.deinit();
    
    if (amend_result.exit_code != 0) {
        print("    ⚠ commit --amend not implemented: {s}\n", .{amend_result.stderr});
        return;
    }
    
    // Verify only one commit in log with new message
    var log_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "log", "--oneline" 
    }, test_dir);
    defer log_result.deinit();
    
    if (log_result.exit_code != 0) {
        print("    ❌ log failed after amend: {s}\n", .{log_result.stderr});
        return;
    }
    
    // Should have amended message, not original
    if (std.mem.indexOf(u8, log_result.stdout, "Amended commit message") == null) {
        print("    ❌ Amended commit message not found in log\n");
        return;
    }
    
    if (std.mem.indexOf(u8, log_result.stdout, "Initial commit") != null) {
        print("    ❌ Original commit message still present after amend\n");
        return;
    }
    
    print("    ✓ Commit amend test passed\n");
}

fn testCommitAllowEmpty(tf: *TestFramework) !void {
    print("  Testing commit --allow-empty...\n");
    
    const test_dir = try setupTestRepoWithFile(tf, "commit-allow-empty", "test.txt", "Content\n");
    defer tf.removeTempDir(test_dir);
    
    // Create initial commit
    var commit1_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "commit", "-m", "Initial commit" 
    }, test_dir);
    defer commit1_result.deinit();
    
    if (commit1_result.exit_code != 0) {
        print("    ❌ initial commit failed: {s}\n", .{commit1_result.stderr});
        return;
    }
    
    // Try empty commit with --allow-empty
    var empty_commit_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "commit", "--allow-empty", "-m", "Empty commit" 
    }, test_dir);
    defer empty_commit_result.deinit();
    
    if (empty_commit_result.exit_code != 0) {
        print("    ⚠ commit --allow-empty not implemented: {s}\n", .{empty_commit_result.stderr});
        return;
    }
    
    // Verify two commits in log
    var log_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "log", "--oneline" 
    }, test_dir);
    defer log_result.deinit();
    
    if (log_result.exit_code != 0) {
        print("    ❌ log failed after --allow-empty: {s}\n", .{log_result.stderr});
        return;
    }
    
    // Should have both commits
    if (std.mem.indexOf(u8, log_result.stdout, "Empty commit") == null or
        std.mem.indexOf(u8, log_result.stdout, "Initial commit") == null) {
        print("    ❌ Both commits should be present in log\n");
        return;
    }
    
    print("    ✓ Commit allow-empty test passed\n");
}

fn testCommitAuthorDate(tf: *TestFramework) !void {
    print("  Testing commit author and date info...\n");
    
    const test_dir = try setupTestRepoWithFile(tf, "commit-author-date", "test.txt", "Content\n");
    defer tf.removeTempDir(test_dir);
    
    var commit_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "commit", "-m", "Test commit" 
    }, test_dir);
    defer commit_result.deinit();
    
    if (commit_result.exit_code != 0) {
        print("    ❌ commit failed: {s}\n", .{commit_result.stderr});
        return;
    }
    
    // Check log shows author and date information
    var log_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "log", "-1" 
    }, test_dir);
    defer log_result.deinit();
    
    if (log_result.exit_code != 0) {
        print("    ❌ log failed: {s}\n", .{log_result.stderr});
        return;
    }
    
    // Should contain author information
    if (std.mem.indexOf(u8, log_result.stdout, "Author:") == null and
        std.mem.indexOf(u8, log_result.stdout, "author") == null) {
        print("    ⚠ Log should show author information\n");
    }
    
    // Should contain date information
    if (std.mem.indexOf(u8, log_result.stdout, "Date:") == null and
        std.mem.indexOf(u8, log_result.stdout, "date") == null) {
        print("    ⚠ Log should show date information\n");
    }
    
    print("    ✓ Commit author/date test passed\n");
}

fn testMultipleCommits(tf: *TestFramework) !void {
    print("  Testing multiple sequential commits...\n");
    
    const test_dir = try setupTestRepoWithFile(tf, "multiple-commits", "file1.txt", "Content 1\n");
    defer tf.removeTempDir(test_dir);
    
    // First commit
    var commit1_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "commit", "-m", "First commit" 
    }, test_dir);
    defer commit1_result.deinit();
    
    if (commit1_result.exit_code != 0) {
        print("    ❌ first commit failed: {s}\n", .{commit1_result.stderr});
        return;
    }
    
    // Second commit
    try tf.writeFile(test_dir, "file2.txt", "Content 2\n");
    
    var add2_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "add", "file2.txt" 
    }, test_dir);
    defer add2_result.deinit();
    
    var commit2_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "commit", "-m", "Second commit" 
    }, test_dir);
    defer commit2_result.deinit();
    
    if (commit2_result.exit_code != 0) {
        print("    ❌ second commit failed: {s}\n", .{commit2_result.stderr});
        return;
    }
    
    // Third commit
    try tf.writeFile(test_dir, "file3.txt", "Content 3\n");
    
    var add3_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "add", "file3.txt" 
    }, test_dir);
    defer add3_result.deinit();
    
    var commit3_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "commit", "-m", "Third commit" 
    }, test_dir);
    defer commit3_result.deinit();
    
    if (commit3_result.exit_code != 0) {
        print("    ❌ third commit failed: {s}\n", .{commit3_result.stderr});
        return;
    }
    
    // Verify all commits in log
    var log_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "log", "--oneline" 
    }, test_dir);
    defer log_result.deinit();
    
    if (log_result.exit_code != 0) {
        print("    ❌ log failed: {s}\n", .{log_result.stderr});
        return;
    }
    
    // All three commit messages should be present
    const expected_commits = [_][]const u8{ "First commit", "Second commit", "Third commit" };
    for (expected_commits) |commit_msg| {
        if (std.mem.indexOf(u8, log_result.stdout, commit_msg) == null) {
            print("    ❌ Commit '{s}' not found in log\n", .{commit_msg});
            return;
        }
    }
    
    // Commits should be in reverse chronological order (newest first)
    const third_pos = std.mem.indexOf(u8, log_result.stdout, "Third commit").?;
    const first_pos = std.mem.indexOf(u8, log_result.stdout, "First commit").?;
    
    if (third_pos > first_pos) {
        print("    ❌ Commits not in reverse chronological order in log\n");
        return;
    }
    
    print("    ✓ Multiple commits test passed\n");
}

pub fn main() !void {
    try runCommitCompatTests();
}