const std = @import("std");
const GitTestFramework = @import("git_test_framework.zig").GitTestFramework;
const compareGitZiggitOutput = @import("git_test_framework.zig").compareGitZiggitOutput;

// Test: Status on clean repository
fn testStatusClean(framework: *GitTestFramework) !void {
    const test_dir = try framework.createTestRepo("status-clean");
    defer framework.allocator.free(test_dir);

    // Initialize repo
    const init_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{"init"});
    defer init_result.deinit(framework.allocator);
    try framework.expectExitCode(0, init_result);

    // Status on clean repo
    const status_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{"status"});
    defer status_result.deinit(framework.allocator);
    try framework.expectExitCode(0, status_result);

    // Should indicate clean working tree
    if (std.mem.indexOf(u8, status_result.stdout, "clean") == null and 
        std.mem.indexOf(u8, status_result.stdout, "nothing to commit") == null) {
        return error.CleanStatusNotIndicated;
    }
}

// Test: Status with untracked files
fn testStatusUntracked(framework: *GitTestFramework) !void {
    const test_dir = try framework.createTestRepo("status-untracked");
    defer framework.allocator.free(test_dir);

    // Initialize repo
    const init_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{"init"});
    defer init_result.deinit(framework.allocator);
    try framework.expectExitCode(0, init_result);

    // Create untracked files
    try framework.writeFile(test_dir, "untracked1.txt", "Untracked file 1\n");
    try framework.writeFile(test_dir, "untracked2.txt", "Untracked file 2\n");

    // Status should show untracked files
    const status_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{"status"});
    defer status_result.deinit(framework.allocator);
    try framework.expectExitCode(0, status_result);

    // Should show untracked files
    if (std.mem.indexOf(u8, status_result.stdout, "untracked1.txt") == null or
        std.mem.indexOf(u8, status_result.stdout, "untracked2.txt") == null) {
        return error.UntrackedFilesNotShown;
    }

    // Should mention untracked files in some way
    if (std.mem.indexOf(u8, status_result.stdout, "untracked") == null and
        std.mem.indexOf(u8, status_result.stdout, "Untracked") == null) {
        return error.UntrackedLabelMissing;
    }
}

// Test: Status with staged files
fn testStatusStaged(framework: *GitTestFramework) !void {
    const test_dir = try framework.createTestRepo("status-staged");
    defer framework.allocator.free(test_dir);

    // Initialize repo
    const init_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{"init"});
    defer init_result.deinit(framework.allocator);
    try framework.expectExitCode(0, init_result);

    // Create and stage files
    try framework.writeFile(test_dir, "staged1.txt", "Staged file 1\n");
    try framework.writeFile(test_dir, "staged2.txt", "Staged file 2\n");
    
    const add_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{ "add", "staged1.txt", "staged2.txt" });
    defer add_result.deinit(framework.allocator);
    try framework.expectExitCode(0, add_result);

    // Status should show staged files
    const status_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{"status"});
    defer status_result.deinit(framework.allocator);
    try framework.expectExitCode(0, status_result);

    // Should show staged files
    if (std.mem.indexOf(u8, status_result.stdout, "staged1.txt") == null or
        std.mem.indexOf(u8, status_result.stdout, "staged2.txt") == null) {
        return error.StagedFilesNotShown;
    }

    // Should indicate files are staged for commit
    if (std.mem.indexOf(u8, status_result.stdout, "commit") == null) {
        return error.CommitIndicationMissing;
    }
}

// Test: Status with modified files (staged and unstaged)
fn testStatusModified(framework: *GitTestFramework) !void {
    const test_dir = try framework.createTestRepo("status-modified");
    defer framework.allocator.free(test_dir);

    // Initialize repo
    const init_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{"init"});
    defer init_result.deinit(framework.allocator);
    try framework.expectExitCode(0, init_result);

    // Create, stage, and commit a file
    try framework.writeFile(test_dir, "tracked.txt", "Original content\n");
    
    const add_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{ "add", "tracked.txt" });
    defer add_result.deinit(framework.allocator);
    try framework.expectExitCode(0, add_result);

    const commit_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{ "commit", "-m", "Initial commit" });
    defer commit_result.deinit(framework.allocator);
    try framework.expectExitCode(0, commit_result);

    // Modify the file
    try framework.writeFile(test_dir, "tracked.txt", "Modified content\n");

    // Status should show modified file
    const status_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{"status"});
    defer status_result.deinit(framework.allocator);
    try framework.expectExitCode(0, status_result);

    // Should show the modified file
    if (std.mem.indexOf(u8, status_result.stdout, "tracked.txt") == null) {
        return error.ModifiedFileNotShown;
    }

    // Should indicate it's modified
    if (std.mem.indexOf(u8, status_result.stdout, "modified") == null and
        std.mem.indexOf(u8, status_result.stdout, "Modified") == null and
        std.mem.indexOf(u8, status_result.stdout, "changed") == null) {
        return error.ModifiedIndicationMissing;
    }
}

// Test: Status with mixed state (staged, modified, untracked)
fn testStatusMixed(framework: *GitTestFramework) !void {
    const test_dir = try framework.createTestRepo("status-mixed");
    defer framework.allocator.free(test_dir);

    // Initialize repo
    const init_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{"init"});
    defer init_result.deinit(framework.allocator);
    try framework.expectExitCode(0, init_result);

    // Create a tracked file
    try framework.writeFile(test_dir, "existing.txt", "Existing content\n");
    var add1_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{ "add", "existing.txt" });
    defer add1_result.deinit(framework.allocator);
    
    const commit_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{ "commit", "-m", "Initial commit" });
    defer commit_result.deinit(framework.allocator);

    // Create new file and stage it
    try framework.writeFile(test_dir, "new_staged.txt", "New staged content\n");
    var add2_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{ "add", "new_staged.txt" });
    defer add2_result.deinit(framework.allocator);

    // Modify existing file
    try framework.writeFile(test_dir, "existing.txt", "Modified existing content\n");

    // Create untracked file
    try framework.writeFile(test_dir, "untracked.txt", "Untracked content\n");

    // Status should show all different states
    const status_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{"status"});
    defer status_result.deinit(framework.allocator);
    try framework.expectExitCode(0, status_result);

    // Should show staged file
    if (std.mem.indexOf(u8, status_result.stdout, "new_staged.txt") == null) {
        return error.StagedFileNotShown;
    }

    // Should show modified file
    if (std.mem.indexOf(u8, status_result.stdout, "existing.txt") == null) {
        return error.ModifiedFileNotShown;
    }

    // Should show untracked file
    if (std.mem.indexOf(u8, status_result.stdout, "untracked.txt") == null) {
        return error.UntrackedFileNotShown;
    }
}

// Test: Status short format
fn testStatusShort(framework: *GitTestFramework) !void {
    const test_dir = try framework.createTestRepo("status-short");
    defer framework.allocator.free(test_dir);

    // Initialize repo
    const init_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{"init"});
    defer init_result.deinit(framework.allocator);
    try framework.expectExitCode(0, init_result);

    // Create and stage file
    try framework.writeFile(test_dir, "test.txt", "Test content\n");
    
    const add_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{ "add", "test.txt" });
    defer add_result.deinit(framework.allocator);
    try framework.expectExitCode(0, add_result);

    // Status with --short or -s flag
    const status_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{ "status", "--short" });
    defer status_result.deinit(framework.allocator);
    
    // Should succeed (even if not implemented, should not crash)
    try framework.expectExitCode(0, status_result);
}

// Test: Status porcelain format
fn testStatusPorcelain(framework: *GitTestFramework) !void {
    const test_dir = try framework.createTestRepo("status-porcelain");
    defer framework.allocator.free(test_dir);

    // Initialize repo
    const init_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{"init"});
    defer init_result.deinit(framework.allocator);
    try framework.expectExitCode(0, init_result);

    // Create and stage file
    try framework.writeFile(test_dir, "test.txt", "Test content\n");
    
    const add_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{ "add", "test.txt" });
    defer add_result.deinit(framework.allocator);
    try framework.expectExitCode(0, add_result);

    // Status with --porcelain flag
    const status_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{ "status", "--porcelain" });
    defer status_result.deinit(framework.allocator);
    
    // Should succeed (even if not implemented, should not crash)
    try framework.expectExitCode(0, status_result);
}

// Test: Status after commit (should be clean)
fn testStatusAfterCommit(framework: *GitTestFramework) !void {
    const test_dir = try framework.createTestRepo("status-after-commit");
    defer framework.allocator.free(test_dir);

    // Initialize repo
    const init_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{"init"});
    defer init_result.deinit(framework.allocator);
    try framework.expectExitCode(0, init_result);

    // Create, stage and commit file
    try framework.writeFile(test_dir, "test.txt", "Test content\n");
    
    const add_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{ "add", "test.txt" });
    defer add_result.deinit(framework.allocator);
    try framework.expectExitCode(0, add_result);

    const commit_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{ "commit", "-m", "Test commit" });
    defer commit_result.deinit(framework.allocator);
    try framework.expectExitCode(0, commit_result);

    // Status should now be clean
    const status_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{"status"});
    defer status_result.deinit(framework.allocator);
    try framework.expectExitCode(0, status_result);

    // Should indicate clean working tree
    if (std.mem.indexOf(u8, status_result.stdout, "clean") == null and 
        std.mem.indexOf(u8, status_result.stdout, "nothing to commit") == null) {
        return error.NotCleanAfterCommit;
    }
}

// Test: Status with ignored files
fn testStatusIgnored(framework: *GitTestFramework) !void {
    const test_dir = try framework.createTestRepo("status-ignored");
    defer framework.allocator.free(test_dir);

    // Initialize repo
    const init_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{"init"});
    defer init_result.deinit(framework.allocator);
    try framework.expectExitCode(0, init_result);

    // Create .gitignore
    try framework.writeFile(test_dir, ".gitignore", "*.log\n*.tmp\n");
    
    // Create ignored files
    try framework.writeFile(test_dir, "debug.log", "Debug output\n");
    try framework.writeFile(test_dir, "temp.tmp", "Temporary file\n");
    
    // Create normal file
    try framework.writeFile(test_dir, "normal.txt", "Normal file\n");

    // Status should not show ignored files by default
    const status_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{"status"});
    defer status_result.deinit(framework.allocator);
    try framework.expectExitCode(0, status_result);

    // Should show normal file and .gitignore but not ignored files
    if (std.mem.indexOf(u8, status_result.stdout, "normal.txt") == null) {
        return error.NormalFileNotShown;
    }
    
    if (std.mem.indexOf(u8, status_result.stdout, "debug.log") != null) {
        return error.IgnoredFileShown;
    }
}

pub fn runStatusTests() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var framework = try GitTestFramework.init(allocator);
    defer framework.deinit();

    std.debug.print("Running t7000 Status Tests (Comprehensive)...\n", .{});

    try framework.testExpectSuccess("status on clean repository", testStatusClean);
    try framework.testExpectSuccess("status with untracked files", testStatusUntracked);
    try framework.testExpectSuccess("status with staged files", testStatusStaged);
    try framework.testExpectSuccess("status with modified files", testStatusModified);
    try framework.testExpectSuccess("status with mixed state", testStatusMixed);
    try framework.testExpectSuccess("status short format", testStatusShort);
    try framework.testExpectSuccess("status porcelain format", testStatusPorcelain);
    try framework.testExpectSuccess("status after commit", testStatusAfterCommit);
    try framework.testExpectSuccess("status with ignored files", testStatusIgnored);

    framework.summary();
    
    if (framework.failed_counter > 0) {
        std.process.exit(1);
    }
}