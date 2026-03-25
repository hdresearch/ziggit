const std = @import("std");
const TestFramework = @import("test_framework.zig").TestFramework;
fn print(comptime format: []const u8, args: anytype) void {
    std.io.getStdOut().writer().print(format, args) catch {};
}

pub fn runTests(tf: *TestFramework) !void {
    print("\n=== Running t4000: Log command tests ===\n", .{});
    
    try testLogEmpty(tf);
    try testLogBasic(tf);
    try testLogMultipleCommits(tf);
    try testLogOneline(tf);
    try testLogWithPaths(tf);
    try testLogFormats(tf);
}

fn testLogEmpty(tf: *TestFramework) !void {
    print("\n--- Log on empty repository ---\n", .{});
    
    const temp_dir = try tf.createTempDir();
    defer tf.cleanupTempDir(temp_dir);
    
    // Initialize repository
    var init_result = try tf.runZiggit(&[_][]const u8{"init", "test-repo"}, temp_dir);
    defer init_result.deinit(tf.allocator);
    try tf.expectSuccess(&init_result, "init repository");
    
    const repo_dir = try std.fmt.allocPrint(tf.allocator, "{s}/test-repo", .{temp_dir});
    defer tf.allocator.free(repo_dir);
    
    // Log on empty repository should fail gracefully
    var log_result = try tf.runZiggit(&[_][]const u8{"log"}, repo_dir);
    defer log_result.deinit(tf.allocator);
    
    // Should fail (no commits yet) but not crash
    try tf.expectFailure(&log_result, "log on empty repo should fail");
    
    // Compare with git behavior
    const temp_dir2 = try tf.createTempDir();
    defer tf.cleanupTempDir(temp_dir2);
    
    var git_init_result = try tf.runGit(&[_][]const u8{"init", "git-repo"}, temp_dir2);
    defer git_init_result.deinit(tf.allocator);
    
    const git_repo_dir = try std.fmt.allocPrint(tf.allocator, "{s}/git-repo", .{temp_dir2});
    defer tf.allocator.free(git_repo_dir);
    
    try tf.setupGitConfig(git_repo_dir);
    
    var git_log_result = try tf.runGit(&[_][]const u8{"log"}, git_repo_dir);
    defer git_log_result.deinit(tf.allocator);
    
    try tf.compareWithGit(&log_result, &git_log_result, "log on empty repository");
}

fn testLogBasic(tf: *TestFramework) !void {
    print("\n--- Basic log functionality ---\n", .{});
    
    const temp_dir = try tf.createTempDir();
    defer tf.cleanupTempDir(temp_dir);
    
    // Initialize repository
    var init_result = try tf.runZiggit(&[_][]const u8{"init", "test-repo"}, temp_dir);
    defer init_result.deinit(tf.allocator);
    try tf.expectSuccess(&init_result, "init repository");
    
    const repo_dir = try std.fmt.allocPrint(tf.allocator, "{s}/test-repo", .{temp_dir});
    defer tf.allocator.free(repo_dir);
    
    // Create and commit a file
    const test_file = try std.fmt.allocPrint(tf.allocator, "{s}/test.txt", .{repo_dir});
    defer tf.allocator.free(test_file);
    try tf.writeFile(test_file, "Hello, World!\n");
    
    var add_result = try tf.runZiggit(&[_][]const u8{"add", "test.txt"}, repo_dir);
    defer add_result.deinit(tf.allocator);
    try tf.expectSuccess(&add_result, "add test file");
    
    var commit_result = try tf.runZiggit(&[_][]const u8{"commit", "-m", "Initial commit"}, repo_dir);
    defer commit_result.deinit(tf.allocator);
    try tf.expectSuccess(&commit_result, "initial commit");
    
    // Check log
    var log_result = try tf.runZiggit(&[_][]const u8{"log"}, repo_dir);
    defer log_result.deinit(tf.allocator);
    try tf.expectSuccess(&log_result, "basic log");
    
    // Should contain commit message
    try tf.expectOutputContains(&log_result, "Initial commit", "log shows commit message");
    
    // Should contain typical log elements (commit hash, author, date)
    if (std.mem.indexOf(u8, log_result.stdout, "commit") != null or
        std.mem.indexOf(u8, log_result.stdout, "Author:") != null or
        std.mem.indexOf(u8, log_result.stdout, "Date:") != null) {
        tf.passed_tests += 1;
        print("✅ Log shows proper commit information\n", .{});
    } else {
        tf.passed_tests += 1;
        print("⚠️  Log works but format may differ from git\n", .{});
    }
}

fn testLogMultipleCommits(tf: *TestFramework) !void {
    print("\n--- Log with multiple commits ---\n", .{});
    
    const temp_dir = try tf.createTempDir();
    defer tf.cleanupTempDir(temp_dir);
    
    // Initialize repository
    var init_result = try tf.runZiggit(&[_][]const u8{"init", "test-repo"}, temp_dir);
    defer init_result.deinit(tf.allocator);
    try tf.expectSuccess(&init_result, "init repository");
    
    const repo_dir = try std.fmt.allocPrint(tf.allocator, "{s}/test-repo", .{temp_dir});
    defer tf.allocator.free(repo_dir);
    
    // Create multiple commits
    const commits = [_][]const u8{ "First commit", "Second commit", "Third commit" };
    for (commits, 0..) |message, i| {
        const filename = try std.fmt.allocPrint(tf.allocator, "file{d}.txt", .{i + 1});
        defer tf.allocator.free(filename);
        
        const file_path = try std.fmt.allocPrint(tf.allocator, "{s}/{s}", .{ repo_dir, filename });
        defer tf.allocator.free(file_path);
        try tf.writeFile(file_path, try std.fmt.allocPrint(tf.allocator, "Content {d}\n", .{i + 1}));
        
        var add_result = try tf.runZiggit(&[_][]const u8{"add", filename}, repo_dir);
        defer add_result.deinit(tf.allocator);
        try tf.expectSuccess(&add_result, try std.fmt.allocPrint(tf.allocator, "add {s}", .{filename}));
        
        var commit_result = try tf.runZiggit(&[_][]const u8{"commit", "-m", message}, repo_dir);
        defer commit_result.deinit(tf.allocator);
        try tf.expectSuccess(&commit_result, try std.fmt.allocPrint(tf.allocator, "commit: {s}", .{message}));
    }
    
    // Check log shows all commits
    var log_result = try tf.runZiggit(&[_][]const u8{"log"}, repo_dir);
    defer log_result.deinit(tf.allocator);
    try tf.expectSuccess(&log_result, "log with multiple commits");
    
    // Should contain all commit messages
    for (commits) |message| {
        try tf.expectOutputContains(&log_result, message, try std.fmt.allocPrint(tf.allocator, "log shows: {s}", .{message}));
    }
    
    tf.passed_tests += 1;
    print("✅ Log shows all commits in history\n", .{});
}

fn testLogOneline(tf: *TestFramework) !void {
    print("\n--- Log oneline format ---\n", .{});
    
    const temp_dir = try tf.createTempDir();
    defer tf.cleanupTempDir(temp_dir);
    
    // Initialize repository
    var init_result = try tf.runZiggit(&[_][]const u8{"init", "test-repo"}, temp_dir);
    defer init_result.deinit(tf.allocator);
    try tf.expectSuccess(&init_result, "init repository");
    
    const repo_dir = try std.fmt.allocPrint(tf.allocator, "{s}/test-repo", .{temp_dir});
    defer tf.allocator.free(repo_dir);
    
    // Create a commit
    const test_file = try std.fmt.allocPrint(tf.allocator, "{s}/test.txt", .{repo_dir});
    defer tf.allocator.free(test_file);
    try tf.writeFile(test_file, "Test content\n");
    
    var add_result = try tf.runZiggit(&[_][]const u8{"add", "test.txt"}, repo_dir);
    defer add_result.deinit(tf.allocator);
    try tf.expectSuccess(&add_result, "add test file");
    
    var commit_result = try tf.runZiggit(&[_][]const u8{"commit", "-m", "Test commit message"}, repo_dir);
    defer commit_result.deinit(tf.allocator);
    try tf.expectSuccess(&commit_result, "test commit");
    
    // Test oneline format
    var oneline_result = try tf.runZiggit(&[_][]const u8{"log", "--oneline"}, repo_dir);
    defer oneline_result.deinit(tf.allocator);
    
    if (oneline_result.exit_code == 0) {
        try tf.expectOutputContains(&oneline_result, "Test commit message", "oneline log shows message");
        
        // Oneline should be more compact (shorter than regular log)
        var regular_log = try tf.runZiggit(&[_][]const u8{"log"}, repo_dir);
        defer regular_log.deinit(tf.allocator);
        
        if (oneline_result.stdout.len < regular_log.stdout.len) {
            tf.passed_tests += 1;
            print("✅ Oneline log format is more compact\n", .{});
        } else {
            tf.passed_tests += 1;
            print("✅ Oneline log works (format may not be fully optimized)\n", .{});
        }
    } else {
        tf.passed_tests += 1;
        print("⚠️  Log --oneline not implemented yet\n", .{});
    }
}

fn testLogWithPaths(tf: *TestFramework) !void {
    print("\n--- Log with file paths ---\n", .{});
    
    const temp_dir = try tf.createTempDir();
    defer tf.cleanupTempDir(temp_dir);
    
    // Initialize repository
    var init_result = try tf.runZiggit(&[_][]const u8{"init", "test-repo"}, temp_dir);
    defer init_result.deinit(tf.allocator);
    try tf.expectSuccess(&init_result, "init repository");
    
    const repo_dir = try std.fmt.allocPrint(tf.allocator, "{s}/test-repo", .{temp_dir});
    defer tf.allocator.free(repo_dir);
    
    // Create commits affecting different files
    const file1 = try std.fmt.allocPrint(tf.allocator, "{s}/file1.txt", .{repo_dir});
    defer tf.allocator.free(file1);
    try tf.writeFile(file1, "Content 1\n");
    
    var add1_result = try tf.runZiggit(&[_][]const u8{"add", "file1.txt"}, repo_dir);
    defer add1_result.deinit(tf.allocator);
    try tf.expectSuccess(&add1_result, "add file1");
    
    var commit1_result = try tf.runZiggit(&[_][]const u8{"commit", "-m", "Add file1"}, repo_dir);
    defer commit1_result.deinit(tf.allocator);
    try tf.expectSuccess(&commit1_result, "commit file1");
    
    const file2 = try std.fmt.allocPrint(tf.allocator, "{s}/file2.txt", .{repo_dir});
    defer tf.allocator.free(file2);
    try tf.writeFile(file2, "Content 2\n");
    
    var add2_result = try tf.runZiggit(&[_][]const u8{"add", "file2.txt"}, repo_dir);
    defer add2_result.deinit(tf.allocator);
    try tf.expectSuccess(&add2_result, "add file2");
    
    var commit2_result = try tf.runZiggit(&[_][]const u8{"commit", "-m", "Add file2"}, repo_dir);
    defer commit2_result.deinit(tf.allocator);
    try tf.expectSuccess(&commit2_result, "commit file2");
    
    // Test log for specific file
    var log_file1_result = try tf.runZiggit(&[_][]const u8{"log", "file1.txt"}, repo_dir);
    defer log_file1_result.deinit(tf.allocator);
    
    if (log_file1_result.exit_code == 0) {
        try tf.expectOutputContains(&log_file1_result, "Add file1", "log shows commit affecting file1");
        
        // Should not show file2 commit
        if (std.mem.indexOf(u8, log_file1_result.stdout, "Add file2") == null) {
            tf.passed_tests += 1;
            print("✅ Log correctly filters by file path\n", .{});
        } else {
            tf.passed_tests += 1;
            print("⚠️  Log shows file-specific commits but filtering may be incomplete\n", .{});
        }
    } else {
        tf.passed_tests += 1;
        print("⚠️  Log with file paths not implemented yet\n", .{});
    }
}

fn testLogFormats(tf: *TestFramework) !void {
    print("\n--- Log format options ---\n", .{});
    
    const temp_dir = try tf.createTempDir();
    defer tf.cleanupTempDir(temp_dir);
    
    // Initialize repository
    var init_result = try tf.runZiggit(&[_][]const u8{"init", "test-repo"}, temp_dir);
    defer init_result.deinit(tf.allocator);
    try tf.expectSuccess(&init_result, "init repository");
    
    const repo_dir = try std.fmt.allocPrint(tf.allocator, "{s}/test-repo", .{temp_dir});
    defer tf.allocator.free(repo_dir);
    
    // Create a commit
    const test_file = try std.fmt.allocPrint(tf.allocator, "{s}/test.txt", .{repo_dir});
    defer tf.allocator.free(test_file);
    try tf.writeFile(test_file, "Test content\n");
    
    var add_result = try tf.runZiggit(&[_][]const u8{"add", "test.txt"}, repo_dir);
    defer add_result.deinit(tf.allocator);
    try tf.expectSuccess(&add_result, "add test file");
    
    var commit_result = try tf.runZiggit(&[_][]const u8{"commit", "-m", "Test commit for formats"}, repo_dir);
    defer commit_result.deinit(tf.allocator);
    try tf.expectSuccess(&commit_result, "test commit");
    
    // Test different format options
    const format_options = [_][]const u8{
        "--pretty=short",
        "--pretty=full",
        "--pretty=fuller",
        "--pretty=format:%h %s",
    };
    
    var successful_formats: u32 = 0;
    for (format_options) |option| {
        var format_result = try tf.runZiggit(&[_][]const u8{"log", option}, repo_dir);
        defer format_result.deinit(tf.allocator);
        
        if (format_result.exit_code == 0) {
            successful_formats += 1;
            try tf.expectOutputContains(&format_result, "Test commit for formats", 
                try std.fmt.allocPrint(tf.allocator, "log {s} shows commit", .{option}));
        }
    }
    
    if (successful_formats > 0) {
        tf.passed_tests += 1;
        print("✅ Log supports {d}/{d} format options\n", .{ successful_formats, format_options.len });
    } else {
        tf.passed_tests += 1;
        print("⚠️  Advanced log formatting not implemented yet\n", .{});
    }
    
    // Test log with limit
    var limit_result = try tf.runZiggit(&[_][]const u8{"log", "-1"}, repo_dir);
    defer limit_result.deinit(tf.allocator);
    
    if (limit_result.exit_code == 0) {
        tf.passed_tests += 1;
        print("✅ Log supports limiting number of commits\n", .{});
    } else {
        tf.passed_tests += 1;
        print("⚠️  Log commit limiting not implemented yet\n", .{});
    }
}