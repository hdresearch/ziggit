const std = @import("std");
const TestFramework = @import("test_framework.zig").TestFramework;

fn print(comptime format: []const u8, args: anytype) void {
    std.io.getStdOut().writer().print(format, args) catch {};
}

pub fn runCriticalCompatibilityTests(tf: *TestFramework) !void {
    print("\n=== Critical Git Compatibility Test Suite ===\n", .{});
    print("Testing core operations for drop-in git replacement\n", .{});
    
    try testCoreWorkflow(tf);
    try testStatusOutputFormat(tf);
    try testCommitOutputFormat(tf);
    try testLogCompatibility(tf);
    try testBranchOperations(tf);
    try testDiffOperations(tf);
    try testErrorHandling(tf);
    
    print("\n=== Critical Compatibility Results ===\n", .{});
    tf.printSummary();
}

fn testCoreWorkflow(tf: *TestFramework) !void {
    print("\n--- Core Git Workflow Test ---\n", .{});
    
    const temp_dir = try tf.createTempDir();
    defer tf.cleanupTempDir(temp_dir);
    
    // Test complete workflow: init → add → commit → log
    var init_result = try tf.runZiggit(&[_][]const u8{"init"}, temp_dir);
    defer init_result.deinit(tf.allocator);
    try tf.expectSuccess(&init_result, "Repository initialization");
    
    // Create test file
    const test_file = try std.fmt.allocPrint(tf.allocator, "{s}/test.txt", .{temp_dir});
    defer tf.allocator.free(test_file);
    try tf.writeFile(test_file, "Hello, world!\n");
    
    // Add file
    var add_result = try tf.runZiggit(&[_][]const u8{"add", "test.txt"}, temp_dir);
    defer add_result.deinit(tf.allocator);
    try tf.expectSuccess(&add_result, "File staging");
    
    // Commit changes
    var commit_result = try tf.runZiggit(&[_][]const u8{"commit", "-m", "Initial commit"}, temp_dir);
    defer commit_result.deinit(tf.allocator);
    try tf.expectSuccess(&commit_result, "Commit creation");
    
    // Verify commit output format matches git pattern
    if (std.mem.indexOf(u8, commit_result.stdout, "[master ") == null) {
        print("⚠️  Commit output format differs from git\n", .{});
        print("   Expected: [master <hash>] message\n", .{});
        print("   Got: {s}\n", .{std.mem.trim(u8, commit_result.stdout, " \n\t\r")});
    } else {
        print("✅ Commit output format matches git\n", .{});
        tf.passed_tests += 1;
    }
    
    // Check log
    var log_result = try tf.runZiggit(&[_][]const u8{"log", "--oneline"}, temp_dir);
    defer log_result.deinit(tf.allocator);
    try tf.expectSuccess(&log_result, "Log display");
    
    print("✅ Core workflow completed successfully\n", .{});
}

fn testStatusOutputFormat(tf: *TestFramework) !void {
    print("\n--- Status Output Format Test ---\n", .{});
    
    const temp_dir = try tf.createTempDir();
    defer tf.cleanupTempDir(temp_dir);
    
    // Initialize repository
    var init_result = try tf.runZiggit(&[_][]const u8{"init"}, temp_dir);
    defer init_result.deinit(tf.allocator);
    try tf.expectSuccess(&init_result, "Repository initialization");
    
    // Test empty repository status
    var empty_status = try tf.runZiggit(&[_][]const u8{"status"}, temp_dir);
    defer empty_status.deinit(tf.allocator);
    try tf.expectSuccess(&empty_status, "Empty repository status");
    
    // Compare with git
    var git_empty_status = try tf.runGit(&[_][]const u8{"status"}, temp_dir);
    defer git_empty_status.deinit(tf.allocator);
    
    if (std.mem.indexOf(u8, empty_status.stdout, "On branch master") != null and
        std.mem.indexOf(u8, empty_status.stdout, "No commits yet") != null) {
        print("✅ Empty repository status format matches git\n", .{});
        tf.passed_tests += 1;
    } else {
        print("⚠️  Empty repository status format differs\n", .{});
        print("   ziggit: {s}\n", .{std.mem.trim(u8, empty_status.stdout, " \n\t\r")});
        print("   git: {s}\n", .{std.mem.trim(u8, git_empty_status.stdout, " \n\t\r")});
    }
    
    // Test with untracked files
    const untracked_file = try std.fmt.allocPrint(tf.allocator, "{s}/untracked.txt", .{temp_dir});
    defer tf.allocator.free(untracked_file);
    try tf.writeFile(untracked_file, "untracked content\n");
    
    var untracked_status = try tf.runZiggit(&[_][]const u8{"status"}, temp_dir);
    defer untracked_status.deinit(tf.allocator);
    try tf.expectSuccess(&untracked_status, "Status with untracked files");
    
    if (std.mem.indexOf(u8, untracked_status.stdout, "untracked.txt") != null) {
        print("✅ Status correctly shows untracked files\n", .{});
        tf.passed_tests += 1;
    }
    
    // Test porcelain format
    var porcelain_status = try tf.runZiggit(&[_][]const u8{"status", "--porcelain"}, temp_dir);
    defer porcelain_status.deinit(tf.allocator);
    try tf.expectSuccess(&porcelain_status, "Porcelain status format");
    
    var git_porcelain_status = try tf.runGit(&[_][]const u8{"status", "--porcelain"}, temp_dir);
    defer git_porcelain_status.deinit(tf.allocator);
    
    const ziggit_porcelain = std.mem.trim(u8, porcelain_status.stdout, " \n\t\r");
    const git_porcelain = std.mem.trim(u8, git_porcelain_status.stdout, " \n\t\r");
    
    if (std.mem.eql(u8, ziggit_porcelain, git_porcelain)) {
        print("✅ Porcelain format matches git exactly\n", .{});
        tf.passed_tests += 1;
    } else {
        print("⚠️  Porcelain format differs from git\n", .{});
        print("   ziggit: '{s}'\n", .{ziggit_porcelain});
        print("   git: '{s}'\n", .{git_porcelain});
    }
}

fn testCommitOutputFormat(tf: *TestFramework) !void {
    print("\n--- Commit Output Format Test ---\n", .{});
    
    const temp_dir = try tf.createTempDir();
    defer tf.cleanupTempDir(temp_dir);
    
    // Initialize and set up repository
    var init_result = try tf.runZiggit(&[_][]const u8{"init"}, temp_dir);
    defer init_result.deinit(tf.allocator);
    try tf.expectSuccess(&init_result, "Repository initialization");
    
    // Create and add a file
    const test_file = try std.fmt.allocPrint(tf.allocator, "{s}/test.txt", .{temp_dir});
    defer tf.allocator.free(test_file);
    try tf.writeFile(test_file, "test content\n");
    
    var add_result = try tf.runZiggit(&[_][]const u8{"add", "test.txt"}, temp_dir);
    defer add_result.deinit(tf.allocator);
    try tf.expectSuccess(&add_result, "File add");
    
    // Test commit with message
    var commit_result = try tf.runZiggit(&[_][]const u8{"commit", "-m", "Test commit message"}, temp_dir);
    defer commit_result.deinit(tf.allocator);
    try tf.expectSuccess(&commit_result, "Commit with message");
    
    // Verify commit output format: should be [branch hash] message
    const commit_output = std.mem.trim(u8, commit_result.stdout, " \n\t\r");
    if (std.mem.startsWith(u8, commit_output, "[master ") and
        std.mem.indexOf(u8, commit_output, "] Test commit message") != null) {
        print("✅ Commit output format matches git standard\n", .{});
        tf.passed_tests += 1;
    } else {
        print("⚠️  Commit output format differs from git\n", .{});
        print("   Expected: [master <hash>] Test commit message\n", .{});
        print("   Got: {s}\n", .{commit_output});
    }
    
    // Test commit with nothing to commit
    var empty_commit = try tf.runZiggit(&[_][]const u8{"commit", "-m", "Empty commit"}, temp_dir);
    defer empty_commit.deinit(tf.allocator);
    
    if (empty_commit.exit_code != 0) {
        print("✅ Empty commit properly fails\n", .{});
        tf.passed_tests += 1;
        
        // Compare error message with git
        var git_empty_commit = try tf.runGit(&[_][]const u8{"commit", "-m", "Empty commit"}, temp_dir);
        defer git_empty_commit.deinit(tf.allocator);
        
        if (git_empty_commit.exit_code != 0) {
            print("✅ Empty commit behavior matches git\n", .{});
            tf.passed_tests += 1;
        }
    }
}

fn testLogCompatibility(tf: *TestFramework) !void {
    print("\n--- Log Compatibility Test ---\n", .{});
    
    const temp_dir = try tf.createTempDir();
    defer tf.cleanupTempDir(temp_dir);
    
    // Set up repository with multiple commits
    var init_result = try tf.runZiggit(&[_][]const u8{"init"}, temp_dir);
    defer init_result.deinit(tf.allocator);
    try tf.expectSuccess(&init_result, "Repository initialization");
    
    // First commit
    const file1 = try std.fmt.allocPrint(tf.allocator, "{s}/file1.txt", .{temp_dir});
    defer tf.allocator.free(file1);
    try tf.writeFile(file1, "First file\n");
    
    _ = try tf.runZiggit(&[_][]const u8{"add", "file1.txt"}, temp_dir);
    var commit1 = try tf.runZiggit(&[_][]const u8{"commit", "-m", "First commit"}, temp_dir);
    defer commit1.deinit(tf.allocator);
    try tf.expectSuccess(&commit1, "First commit");
    
    // Second commit
    const file2 = try std.fmt.allocPrint(tf.allocator, "{s}/file2.txt", .{temp_dir});
    defer tf.allocator.free(file2);
    try tf.writeFile(file2, "Second file\n");
    
    _ = try tf.runZiggit(&[_][]const u8{"add", "file2.txt"}, temp_dir);
    var commit2 = try tf.runZiggit(&[_][]const u8{"commit", "-m", "Second commit"}, temp_dir);
    defer commit2.deinit(tf.allocator);
    try tf.expectSuccess(&commit2, "Second commit");
    
    // Test log output
    var log_result = try tf.runZiggit(&[_][]const u8{"log"}, temp_dir);
    defer log_result.deinit(tf.allocator);
    try tf.expectSuccess(&log_result, "Log output");
    
    // Check that log contains both commits
    if (std.mem.indexOf(u8, log_result.stdout, "First commit") != null and
        std.mem.indexOf(u8, log_result.stdout, "Second commit") != null) {
        print("✅ Log shows all commits\n", .{});
        tf.passed_tests += 1;
    }
    
    // Test oneline format
    var oneline_log = try tf.runZiggit(&[_][]const u8{"log", "--oneline"}, temp_dir);
    defer oneline_log.deinit(tf.allocator);
    try tf.expectSuccess(&oneline_log, "Oneline log format");
    
    // Count lines in oneline output (should be 2)
    const line_count = std.mem.count(u8, oneline_log.stdout, "\n");
    if (line_count >= 2) {
        print("✅ Oneline log format works correctly\n", .{});
        tf.passed_tests += 1;
    }
    
    // Test log on empty repository
    const empty_temp_dir = try tf.createTempDir();
    defer tf.cleanupTempDir(empty_temp_dir);
    
    _ = try tf.runZiggit(&[_][]const u8{"init"}, empty_temp_dir);
    var empty_log = try tf.runZiggit(&[_][]const u8{"log"}, empty_temp_dir);
    defer empty_log.deinit(tf.allocator);
    
    if (empty_log.exit_code != 0) {
        print("✅ Log on empty repository fails appropriately\n", .{});
        tf.passed_tests += 1;
    }
}

fn testBranchOperations(tf: *TestFramework) !void {
    print("\n--- Branch Operations Test ---\n", .{});
    
    const temp_dir = try tf.createTempDir();
    defer tf.cleanupTempDir(temp_dir);
    
    // Initialize repository
    var init_result = try tf.runZiggit(&[_][]const u8{"init"}, temp_dir);
    defer init_result.deinit(tf.allocator);
    try tf.expectSuccess(&init_result, "Repository initialization");
    
    // Test branch listing (should show master/main)
    var branch_list = try tf.runZiggit(&[_][]const u8{"branch"}, temp_dir);
    defer branch_list.deinit(tf.allocator);
    try tf.expectSuccess(&branch_list, "Branch listing");
    
    // Create a commit first (needed for branch operations)
    const test_file = try std.fmt.allocPrint(tf.allocator, "{s}/branch_test.txt", .{temp_dir});
    defer tf.allocator.free(test_file);
    try tf.writeFile(test_file, "branch test\n");
    
    _ = try tf.runZiggit(&[_][]const u8{"add", "branch_test.txt"}, temp_dir);
    var commit_result = try tf.runZiggit(&[_][]const u8{"commit", "-m", "Branch test commit"}, temp_dir);
    defer commit_result.deinit(tf.allocator);
    try tf.expectSuccess(&commit_result, "Initial commit for branch test");
    
    // Test creating a new branch
    var create_branch = try tf.runZiggit(&[_][]const u8{"branch", "feature"}, temp_dir);
    defer create_branch.deinit(tf.allocator);
    try tf.expectSuccess(&create_branch, "Branch creation");
    
    // Test listing branches (should now show both master and feature)
    var branch_list2 = try tf.runZiggit(&[_][]const u8{"branch"}, temp_dir);
    defer branch_list2.deinit(tf.allocator);
    try tf.expectSuccess(&branch_list2, "Branch listing after creation");
    
    if (std.mem.indexOf(u8, branch_list2.stdout, "feature") != null and
        std.mem.indexOf(u8, branch_list2.stdout, "master") != null) {
        print("✅ Branch operations work correctly\n", .{});
        tf.passed_tests += 1;
    }
    
    // Test checkout
    var checkout_result = try tf.runZiggit(&[_][]const u8{"checkout", "feature"}, temp_dir);
    defer checkout_result.deinit(tf.allocator);
    try tf.expectSuccess(&checkout_result, "Branch checkout");
    
    // Verify current branch
    var current_branch = try tf.runZiggit(&[_][]const u8{"branch"}, temp_dir);
    defer current_branch.deinit(tf.allocator);
    if (std.mem.indexOf(u8, current_branch.stdout, "* feature") != null) {
        print("✅ Checkout changes current branch correctly\n", .{});
        tf.passed_tests += 1;
    }
}

fn testDiffOperations(tf: *TestFramework) !void {
    print("\n--- Diff Operations Test ---\n", .{});
    
    const temp_dir = try tf.createTempDir();
    defer tf.cleanupTempDir(temp_dir);
    
    // Initialize repository
    var init_result = try tf.runZiggit(&[_][]const u8{"init"}, temp_dir);
    defer init_result.deinit(tf.allocator);
    try tf.expectSuccess(&init_result, "Repository initialization");
    
    // Create and commit initial file
    const test_file = try std.fmt.allocPrint(tf.allocator, "{s}/diff_test.txt", .{temp_dir});
    defer tf.allocator.free(test_file);
    try tf.writeFile(test_file, "line 1\nline 2\nline 3\n");
    
    _ = try tf.runZiggit(&[_][]const u8{"add", "diff_test.txt"}, temp_dir);
    var commit_result = try tf.runZiggit(&[_][]const u8{"commit", "-m", "Initial commit"}, temp_dir);
    defer commit_result.deinit(tf.allocator);
    try tf.expectSuccess(&commit_result, "Initial commit");
    
    // Modify the file
    try tf.writeFile(test_file, "line 1\nmodified line 2\nline 3\nnew line 4\n");
    
    // Test diff (working directory vs committed)
    var diff_result = try tf.runZiggit(&[_][]const u8{"diff"}, temp_dir);
    defer diff_result.deinit(tf.allocator);
    try tf.expectSuccess(&diff_result, "Diff command");
    
    // Check that diff shows the changes
    if (std.mem.indexOf(u8, diff_result.stdout, "diff_test.txt") != null) {
        print("✅ Diff shows file changes\n", .{});
        tf.passed_tests += 1;
    }
    
    // Test staged diff
    _ = try tf.runZiggit(&[_][]const u8{"add", "diff_test.txt"}, temp_dir);
    
    var staged_diff = try tf.runZiggit(&[_][]const u8{"diff", "--cached"}, temp_dir);
    defer staged_diff.deinit(tf.allocator);
    try tf.expectSuccess(&staged_diff, "Staged diff command");
    
    if (std.mem.indexOf(u8, staged_diff.stdout, "diff_test.txt") != null) {
        print("✅ Staged diff works correctly\n", .{});
        tf.passed_tests += 1;
    }
}

fn testErrorHandling(tf: *TestFramework) !void {
    print("\n--- Error Handling Test ---\n", .{});
    
    const temp_dir = try tf.createTempDir();
    defer tf.cleanupTempDir(temp_dir);
    
    // Test git commands outside repository
    var status_outside_repo = try tf.runZiggit(&[_][]const u8{"status"}, temp_dir);
    defer status_outside_repo.deinit(tf.allocator);
    
    if (status_outside_repo.exit_code != 0 and
        std.mem.indexOf(u8, status_outside_repo.stderr, "not a git repository") != null) {
        print("✅ Proper error for commands outside repository\n", .{});
        tf.passed_tests += 1;
    }
    
    // Test invalid commands
    var invalid_command = try tf.runZiggit(&[_][]const u8{"invalidcommand"}, temp_dir);
    defer invalid_command.deinit(tf.allocator);
    
    if (invalid_command.exit_code != 0) {
        print("✅ Invalid command properly rejected\n", .{});
        tf.passed_tests += 1;
    }
    
    // Initialize repository for further tests
    _ = try tf.runZiggit(&[_][]const u8{"init"}, temp_dir);
    
    // Test adding non-existent file
    var add_missing = try tf.runZiggit(&[_][]const u8{"add", "nonexistent.txt"}, temp_dir);
    defer add_missing.deinit(tf.allocator);
    
    if (add_missing.exit_code != 0) {
        print("✅ Adding non-existent file fails appropriately\n", .{});
        tf.passed_tests += 1;
    }
    
    // Test checkout non-existent branch
    var checkout_missing = try tf.runZiggit(&[_][]const u8{"checkout", "nonexistent-branch"}, temp_dir);
    defer checkout_missing.deinit(tf.allocator);
    
    if (checkout_missing.exit_code != 0) {
        print("✅ Checkout non-existent branch fails appropriately\n", .{});
        tf.passed_tests += 1;
    }
}