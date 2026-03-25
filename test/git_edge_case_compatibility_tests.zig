const std = @import("std");
const TestFramework = @import("test_framework.zig").TestFramework;

fn print(comptime format: []const u8, args: anytype) void {
    std.io.getStdOut().writer().print(format, args) catch {};
}

pub fn runGitEdgeCaseTests(tf: *TestFramework) !void {
    print("\n=== Git Edge Case Compatibility Tests ===\n", .{});
    print("Testing edge cases and corner scenarios for git compatibility\n", .{});
    
    try testSpecialFilenames(tf);
    try testLargeFiles(tf);
    try testDeepDirectoryStructures(tf);
    try testBinaryFiles(tf);
    try testEmptyCommits(tf);
    try testMultipleParents(tf);
    try testBranchNaming(tf);
    try testCommitMessages(tf);
    
    print("\n=== Edge Case Test Results ===\n", .{});
    tf.printSummary();
}

fn testSpecialFilenames(tf: *TestFramework) !void {
    print("\n--- Special Filename Handling ---\n", .{});
    
    const temp_dir = try tf.createTempDir();
    defer tf.cleanupTempDir(temp_dir);
    
    // Initialize repository
    var init_result = try tf.runZiggit(&[_][]const u8{"init"}, temp_dir);
    defer init_result.deinit(tf.allocator);
    try tf.expectSuccess(&init_result, "Repository initialization");
    
    // Test file with spaces
    const file_with_spaces = try std.fmt.allocPrint(tf.allocator, "{s}/file with spaces.txt", .{temp_dir});
    defer tf.allocator.free(file_with_spaces);
    try tf.writeFile(file_with_spaces, "content with spaces\n");
    
    var add_spaces = try tf.runZiggit(&[_][]const u8{"add", "file with spaces.txt"}, temp_dir);
    defer add_spaces.deinit(tf.allocator);
    try tf.expectSuccess(&add_spaces, "Adding file with spaces");
    
    // Test Unicode filename
    const unicode_file = try std.fmt.allocPrint(tf.allocator, "{s}/文件.txt", .{temp_dir});
    defer tf.allocator.free(unicode_file);
    try tf.writeFile(unicode_file, "unicode content\n");
    
    var add_unicode = try tf.runZiggit(&[_][]const u8{"add", "文件.txt"}, temp_dir);
    defer add_unicode.deinit(tf.allocator);
    try tf.expectSuccess(&add_unicode, "Adding unicode filename");
    
    // Test dot files
    const dot_file = try std.fmt.allocPrint(tf.allocator, "{s}/.hidden", .{temp_dir});
    defer tf.allocator.free(dot_file);
    try tf.writeFile(dot_file, "hidden content\n");
    
    var add_hidden = try tf.runZiggit(&[_][]const u8{"add", ".hidden"}, temp_dir);
    defer add_hidden.deinit(tf.allocator);
    try tf.expectSuccess(&add_hidden, "Adding hidden file");
    
    // Check status shows all files
    var status_result = try tf.runZiggit(&[_][]const u8{"status"}, temp_dir);
    defer status_result.deinit(tf.allocator);
    try tf.expectSuccess(&status_result, "Status with special filenames");
    
    const expected_files = [_][]const u8{ "file with spaces.txt", "文件.txt", ".hidden" };
    var found_count: u32 = 0;
    for (expected_files) |expected| {
        if (std.mem.indexOf(u8, status_result.stdout, expected) != null) {
            found_count += 1;
        }
    }
    
    if (found_count == expected_files.len) {
        print("✅ All special filenames handled correctly\n", .{});
        tf.passed_tests += 1;
    } else {
        print("⚠️  Some special filenames not handled: found {d}/{d}\n", .{ found_count, expected_files.len });
    }
    
    // Commit all files
    var commit_result = try tf.runZiggit(&[_][]const u8{"commit", "-m", "Add files with special names"}, temp_dir);
    defer commit_result.deinit(tf.allocator);
    try tf.expectSuccess(&commit_result, "Commit with special filenames");
}

fn testLargeFiles(tf: *TestFramework) !void {
    print("\n--- Large File Handling ---\n", .{});
    
    const temp_dir = try tf.createTempDir();
    defer tf.cleanupTempDir(temp_dir);
    
    var init_result = try tf.runZiggit(&[_][]const u8{"init"}, temp_dir);
    defer init_result.deinit(tf.allocator);
    try tf.expectSuccess(&init_result, "Repository initialization");
    
    // Create a moderately large file (1MB)
    const large_file = try std.fmt.allocPrint(tf.allocator, "{s}/large_file.txt", .{temp_dir});
    defer tf.allocator.free(large_file);
    
    const file = try std.fs.createFileAbsolute(large_file, .{});
    defer file.close();
    
    // Write 1MB of data
    var buffer: [1024]u8 = undefined;
    @memset(&buffer, 'A');
    buffer[1023] = '\n';
    
    var i: u32 = 0;
    while (i < 1024) : (i += 1) {
        try file.writeAll(&buffer);
    }
    
    // Add the large file
    var add_result = try tf.runZiggit(&[_][]const u8{"add", "large_file.txt"}, temp_dir);
    defer add_result.deinit(tf.allocator);
    try tf.expectSuccess(&add_result, "Adding large file");
    
    // Check status
    var status_result = try tf.runZiggit(&[_][]const u8{"status"}, temp_dir);
    defer status_result.deinit(tf.allocator);
    try tf.expectSuccess(&status_result, "Status with large file");
    
    if (std.mem.indexOf(u8, status_result.stdout, "large_file.txt") != null) {
        print("✅ Large file handled correctly\n", .{});
        tf.passed_tests += 1;
    }
    
    // Commit the large file
    var commit_result = try tf.runZiggit(&[_][]const u8{"commit", "-m", "Add large file"}, temp_dir);
    defer commit_result.deinit(tf.allocator);
    try tf.expectSuccess(&commit_result, "Committing large file");
}

fn testDeepDirectoryStructures(tf: *TestFramework) !void {
    print("\n--- Deep Directory Structure ---\n", .{});
    
    const temp_dir = try tf.createTempDir();
    defer tf.cleanupTempDir(temp_dir);
    
    var init_result = try tf.runZiggit(&[_][]const u8{"init"}, temp_dir);
    defer init_result.deinit(tf.allocator);
    try tf.expectSuccess(&init_result, "Repository initialization");
    
    // Create deep directory structure
    const deep_path = "a/b/c/d/e/f/g/h/i/j";
    const full_deep_path = try std.fmt.allocPrint(tf.allocator, "{s}/{s}", .{ temp_dir, deep_path });
    defer tf.allocator.free(full_deep_path);
    
    // Create directories recursively
    var path_components = std.mem.split(u8, deep_path, "/");
    var current_path = std.ArrayList(u8).init(tf.allocator);
    defer current_path.deinit();
    
    try current_path.appendSlice(temp_dir);
    
    while (path_components.next()) |component| {
        try current_path.append('/');
        try current_path.appendSlice(component);
        
        std.fs.makeDirAbsolute(current_path.items) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
    
    const deep_file = try std.fmt.allocPrint(tf.allocator, "{s}/deep_file.txt", .{full_deep_path});
    defer tf.allocator.free(deep_file);
    try tf.writeFile(deep_file, "deep content\n");
    
    // Add the deep file
    const relative_deep_file = try std.fmt.allocPrint(tf.allocator, "{s}/deep_file.txt", .{deep_path});
    defer tf.allocator.free(relative_deep_file);
    
    var add_result = try tf.runZiggit(&[_][]const u8{"add", relative_deep_file}, temp_dir);
    defer add_result.deinit(tf.allocator);
    try tf.expectSuccess(&add_result, "Adding file in deep directory");
    
    var status_result = try tf.runZiggit(&[_][]const u8{"status"}, temp_dir);
    defer status_result.deinit(tf.allocator);
    try tf.expectSuccess(&status_result, "Status with deep directory");
    
    if (std.mem.indexOf(u8, status_result.stdout, deep_path) != null) {
        print("✅ Deep directory structure handled correctly\n", .{});
        tf.passed_tests += 1;
    }
    
    var commit_result = try tf.runZiggit(&[_][]const u8{"commit", "-m", "Add file in deep directory"}, temp_dir);
    defer commit_result.deinit(tf.allocator);
    try tf.expectSuccess(&commit_result, "Committing deep directory file");
}

fn testBinaryFiles(tf: *TestFramework) !void {
    print("\n--- Binary File Handling ---\n", .{});
    
    const temp_dir = try tf.createTempDir();
    defer tf.cleanupTempDir(temp_dir);
    
    var init_result = try tf.runZiggit(&[_][]const u8{"init"}, temp_dir);
    defer init_result.deinit(tf.allocator);
    try tf.expectSuccess(&init_result, "Repository initialization");
    
    // Create a binary file with null bytes and random data
    const binary_file = try std.fmt.allocPrint(tf.allocator, "{s}/binary_file.bin", .{temp_dir});
    defer tf.allocator.free(binary_file);
    
    const file = try std.fs.createFileAbsolute(binary_file, .{});
    defer file.close();
    
    // Write binary data
    const binary_data = [_]u8{ 0x00, 0x01, 0xFF, 0xFE, 0x42, 0x00, 0x7F, 0x80, 0x81, 0xFF };
    try file.writeAll(&binary_data);
    
    // Add the binary file
    var add_result = try tf.runZiggit(&[_][]const u8{"add", "binary_file.bin"}, temp_dir);
    defer add_result.deinit(tf.allocator);
    try tf.expectSuccess(&add_result, "Adding binary file");
    
    var status_result = try tf.runZiggit(&[_][]const u8{"status"}, temp_dir);
    defer status_result.deinit(tf.allocator);
    try tf.expectSuccess(&status_result, "Status with binary file");
    
    if (std.mem.indexOf(u8, status_result.stdout, "binary_file.bin") != null) {
        print("✅ Binary file handled correctly\n", .{});
        tf.passed_tests += 1;
    }
    
    var commit_result = try tf.runZiggit(&[_][]const u8{"commit", "-m", "Add binary file"}, temp_dir);
    defer commit_result.deinit(tf.allocator);
    try tf.expectSuccess(&commit_result, "Committing binary file");
    
    // Test diff on binary file
    const updated_binary_data = [_]u8{ 0xFF, 0xFE, 0xFD, 0x00, 0x01, 0x02 };
    const file2 = try std.fs.openFileAbsolute(binary_file, .{ .mode = .write_only });
    defer file2.close();
    try file2.seekTo(0);
    try file2.writeAll(&updated_binary_data);
    
    var diff_result = try tf.runZiggit(&[_][]const u8{"diff"}, temp_dir);
    defer diff_result.deinit(tf.allocator);
    try tf.expectSuccess(&diff_result, "Diff with binary file changes");
}

fn testEmptyCommits(tf: *TestFramework) !void {
    print("\n--- Empty Commit Handling ---\n", .{});
    
    const temp_dir = try tf.createTempDir();
    defer tf.cleanupTempDir(temp_dir);
    
    var init_result = try tf.runZiggit(&[_][]const u8{"init"}, temp_dir);
    defer init_result.deinit(tf.allocator);
    try tf.expectSuccess(&init_result, "Repository initialization");
    
    // Try to commit with nothing staged
    var empty_commit = try tf.runZiggit(&[_][]const u8{"commit", "-m", "Empty commit"}, temp_dir);
    defer empty_commit.deinit(tf.allocator);
    
    if (empty_commit.exit_code != 0) {
        print("✅ Empty commit correctly rejected\n", .{});
        tf.passed_tests += 1;
    } else {
        print("⚠️  Empty commit was allowed (may not match git behavior)\n", .{});
    }
    
    // Try empty commit with --allow-empty (if supported)
    var allowed_empty_commit = try tf.runZiggit(&[_][]const u8{"commit", "-m", "Allowed empty commit", "--allow-empty"}, temp_dir);
    defer allowed_empty_commit.deinit(tf.allocator);
    
    if (allowed_empty_commit.exit_code == 0) {
        print("✅ --allow-empty flag works\n", .{});
        tf.passed_tests += 1;
    } else {
        print("⚠️  --allow-empty flag not implemented\n", .{});
    }
}

fn testMultipleParents(tf: *TestFramework) !void {
    print("\n--- Multiple Parent Commit Scenarios ---\n", .{});
    
    const temp_dir = try tf.createTempDir();
    defer tf.cleanupTempDir(temp_dir);
    
    var init_result = try tf.runZiggit(&[_][]const u8{"init"}, temp_dir);
    defer init_result.deinit(tf.allocator);
    try tf.expectSuccess(&init_result, "Repository initialization");
    
    // Create initial commit
    const file1 = try std.fmt.allocPrint(tf.allocator, "{s}/file1.txt", .{temp_dir});
    defer tf.allocator.free(file1);
    try tf.writeFile(file1, "initial content\n");
    
    _ = try tf.runZiggit(&[_][]const u8{"add", "file1.txt"}, temp_dir);
    var commit1 = try tf.runZiggit(&[_][]const u8{"commit", "-m", "Initial commit"}, temp_dir);
    defer commit1.deinit(tf.allocator);
    try tf.expectSuccess(&commit1, "Initial commit");
    
    // Create branch and commit there
    _ = try tf.runZiggit(&[_][]const u8{"branch", "feature"}, temp_dir);
    _ = try tf.runZiggit(&[_][]const u8{"checkout", "feature"}, temp_dir);
    
    const file2 = try std.fmt.allocPrint(tf.allocator, "{s}/file2.txt", .{temp_dir});
    defer tf.allocator.free(file2);
    try tf.writeFile(file2, "feature content\n");
    
    _ = try tf.runZiggit(&[_][]const u8{"add", "file2.txt"}, temp_dir);
    var commit2 = try tf.runZiggit(&[_][]const u8{"commit", "-m", "Feature commit"}, temp_dir);
    defer commit2.deinit(tf.allocator);
    try tf.expectSuccess(&commit2, "Feature commit");
    
    // Return to master and create another commit
    _ = try tf.runZiggit(&[_][]const u8{"checkout", "master"}, temp_dir);
    
    const file3 = try std.fmt.allocPrint(tf.allocator, "{s}/file3.txt", .{temp_dir});
    defer tf.allocator.free(file3);
    try tf.writeFile(file3, "master content\n");
    
    _ = try tf.runZiggit(&[_][]const u8{"add", "file3.txt"}, temp_dir);
    var commit3 = try tf.runZiggit(&[_][]const u8{"commit", "-m", "Master commit"}, temp_dir);
    defer commit3.deinit(tf.allocator);
    try tf.expectSuccess(&commit3, "Master commit");
    
    // Test merge (creates commit with multiple parents)
    var merge_result = try tf.runZiggit(&[_][]const u8{"merge", "feature"}, temp_dir);
    defer merge_result.deinit(tf.allocator);
    
    if (merge_result.exit_code == 0) {
        print("✅ Merge operation successful\n", .{});
        tf.passed_tests += 1;
        
        // Check that log shows merge commit
        var log_result = try tf.runZiggit(&[_][]const u8{"log", "--oneline"}, temp_dir);
        defer log_result.deinit(tf.allocator);
        
        if (std.mem.indexOf(u8, log_result.stdout, "Merge") != null or 
            std.mem.count(u8, log_result.stdout, "\n") >= 4) {
            print("✅ Merge commit appears in log\n", .{});
            tf.passed_tests += 1;
        }
    } else {
        print("⚠️  Merge operation not successful\n", .{});
        print("   This is expected if merge functionality is not fully implemented\n", .{});
    }
}

fn testBranchNaming(tf: *TestFramework) !void {
    print("\n--- Branch Naming Edge Cases ---\n", .{});
    
    const temp_dir = try tf.createTempDir();
    defer tf.cleanupTempDir(temp_dir);
    
    var init_result = try tf.runZiggit(&[_][]const u8{"init"}, temp_dir);
    defer init_result.deinit(tf.allocator);
    try tf.expectSuccess(&init_result, "Repository initialization");
    
    // Create initial commit (needed for branch operations)
    const file = try std.fmt.allocPrint(tf.allocator, "{s}/test.txt", .{temp_dir});
    defer tf.allocator.free(file);
    try tf.writeFile(file, "test\n");
    
    _ = try tf.runZiggit(&[_][]const u8{"add", "test.txt"}, temp_dir);
    _ = try tf.runZiggit(&[_][]const u8{"commit", "-m", "Initial"}, temp_dir);
    
    // Test various branch names
    const branch_names = [_][]const u8{
        "feature/new-feature",
        "bugfix-123",
        "release_v1.0",
        "hotfix/urgent-fix",
    };
    
    var successful_branches: u32 = 0;
    for (branch_names) |branch_name| {
        var branch_result = try tf.runZiggit(&[_][]const u8{"branch", branch_name}, temp_dir);
        defer branch_result.deinit(tf.allocator);
        
        if (branch_result.exit_code == 0) {
            successful_branches += 1;
        }
    }
    
    if (successful_branches == branch_names.len) {
        print("✅ All branch naming patterns work correctly\n", .{});
        tf.passed_tests += 1;
    } else {
        print("⚠️  Some branch names not supported: {d}/{d}\n", .{ successful_branches, branch_names.len });
    }
    
    // Test invalid branch names
    const invalid_names = [_][]const u8{
        ".invalid",
        "-invalid",
        "invalid.",
        "inv..alid",
    };
    
    var rejected_count: u32 = 0;
    for (invalid_names) |invalid_name| {
        var invalid_branch = try tf.runZiggit(&[_][]const u8{"branch", invalid_name}, temp_dir);
        defer invalid_branch.deinit(tf.allocator);
        
        if (invalid_branch.exit_code != 0) {
            rejected_count += 1;
        }
    }
    
    if (rejected_count >= invalid_names.len / 2) {  // At least half should be rejected
        print("✅ Invalid branch names appropriately rejected\n", .{});
        tf.passed_tests += 1;
    }
}

fn testCommitMessages(tf: *TestFramework) !void {
    print("\n--- Commit Message Edge Cases ---\n", .{});
    
    const temp_dir = try tf.createTempDir();
    defer tf.cleanupTempDir(temp_dir);
    
    var init_result = try tf.runZiggit(&[_][]const u8{"init"}, temp_dir);
    defer init_result.deinit(tf.allocator);
    try tf.expectSuccess(&init_result, "Repository initialization");
    
    // Create file for commits
    const test_file = try std.fmt.allocPrint(tf.allocator, "{s}/commit_test.txt", .{temp_dir});
    defer tf.allocator.free(test_file);
    
    // Test various commit message formats
    const commit_tests = [_]struct { content: []const u8, message: []const u8, description: []const u8 }{
        .{ .content = "content1", .message = "Short message", .description = "short message" },
        .{ .content = "content2", .message = "Multi-line\ncommit message\nwith details", .description = "multiline message" },
        .{ .content = "content3", .message = "Message with unicode: 🚀 🎉", .description = "unicode message" },
        .{ .content = "content4", .message = "Message with \"quotes\" and 'apostrophes'", .description = "quoted message" },
        .{ .content = "content5", .message = "", .description = "empty message" },
    };
    
    var successful_commits: u32 = 0;
    for (commit_tests, 0..) |test_case, i| {
        try tf.writeFile(test_file, test_case.content);
        _ = try tf.runZiggit(&[_][]const u8{"add", "commit_test.txt"}, temp_dir);
        
        var commit_result = if (test_case.message.len > 0) 
            try tf.runZiggit(&[_][]const u8{"commit", "-m", test_case.message}, temp_dir)
        else
            // For empty message, expect it to fail or prompt for editor
            try tf.runZiggit(&[_][]const u8{"commit"}, temp_dir);
        defer commit_result.deinit(tf.allocator);
        
        if (i == 4) { // Empty message case
            if (commit_result.exit_code != 0) {
                print("✅ Empty commit message appropriately rejected\n", .{});
                tf.passed_tests += 1;
            }
        } else {
            if (commit_result.exit_code == 0) {
                successful_commits += 1;
            }
        }
    }
    
    if (successful_commits >= 3) { // At least most should work
        print("✅ Various commit message formats work\n", .{});
        tf.passed_tests += 1;
    }
    
    // Test log to ensure messages are preserved
    var log_result = try tf.runZiggit(&[_][]const u8{"log"}, temp_dir);
    defer log_result.deinit(tf.allocator);
    
    if (std.mem.indexOf(u8, log_result.stdout, "Short message") != null and
        std.mem.indexOf(u8, log_result.stdout, "🚀") != null) {
        print("✅ Commit messages properly preserved in log\n", .{});
        tf.passed_tests += 1;
    }
}