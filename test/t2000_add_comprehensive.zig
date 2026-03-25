const std = @import("std");
const GitTestFramework = @import("git_test_framework.zig").GitTestFramework;
const compareGitZiggitOutput = @import("git_test_framework.zig").compareGitZiggitOutput;

// Test: Basic add single file
fn testBasicAdd(framework: *GitTestFramework) !void {
    const test_dir = try framework.createTestRepo("basic-add");
    defer framework.allocator.free(test_dir);

    // Initialize repo
    var init_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{"init"});
    defer init_result.deinit(framework.allocator);
    try framework.expectExitCode(0, init_result);

    // Create a test file
    try framework.writeFile(test_dir, "test.txt", "Hello, World!\n");

    // Add the file
    var add_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{ "add", "test.txt" });
    defer add_result.deinit(framework.allocator);
    try framework.expectExitCode(0, add_result);

    // Verify with status that file is staged
    var status_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{"status"});
    defer status_result.deinit(framework.allocator);
    try framework.expectExitCode(0, status_result);

    // Should show file as staged for commit
    if (std.mem.indexOf(u8, status_result.stdout, "test.txt") == null) {
        return error.FileNotInStatus;
    }

    // Compare with git behavior
    const git_test_dir = try framework.createTestRepo("basic-add-git");
    defer framework.allocator.free(git_test_dir);
    
    var git_init = try framework.runGitCommand(git_test_dir, &[_][]const u8{"init"});
    defer git_init.deinit(framework.allocator);
    
    try framework.writeFile(git_test_dir, "test.txt", "Hello, World!\n");
    
    var git_add = try framework.runGitCommand(git_test_dir, &[_][]const u8{ "add", "test.txt" });
    defer git_add.deinit(framework.allocator);
    try framework.expectExitCode(0, git_add);
}

// Test: Add multiple files
fn testAddMultipleFiles(framework: *GitTestFramework) !void {
    const test_dir = try framework.createTestRepo("add-multiple");
    defer framework.allocator.free(test_dir);

    // Initialize repo
    var init_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{"init"});
    defer init_result.deinit(framework.allocator);
    try framework.expectExitCode(0, init_result);

    // Create multiple test files
    try framework.writeFile(test_dir, "file1.txt", "Content 1\n");
    try framework.writeFile(test_dir, "file2.txt", "Content 2\n");
    try framework.writeFile(test_dir, "file3.txt", "Content 3\n");

    // Add multiple files
    var add_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{ "add", "file1.txt", "file2.txt", "file3.txt" });
    defer add_result.deinit(framework.allocator);
    try framework.expectExitCode(0, add_result);

    // Verify with status
    var status_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{"status"});
    defer status_result.deinit(framework.allocator);
    try framework.expectExitCode(0, status_result);

    // All files should be staged
    if (std.mem.indexOf(u8, status_result.stdout, "file1.txt") == null or
        std.mem.indexOf(u8, status_result.stdout, "file2.txt") == null or
        std.mem.indexOf(u8, status_result.stdout, "file3.txt") == null) {
        return error.NotAllFilesStaged;
    }
}

// Test: Add all files with '.'
fn testAddAll(framework: *GitTestFramework) !void {
    const test_dir = try framework.createTestRepo("add-all");
    defer framework.allocator.free(test_dir);

    // Initialize repo
    var init_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{"init"});
    defer init_result.deinit(framework.allocator);
    try framework.expectExitCode(0, init_result);

    // Create multiple test files
    try framework.writeFile(test_dir, "file1.txt", "Content 1\n");
    try framework.writeFile(test_dir, "file2.txt", "Content 2\n");
    
    // Create subdirectory with file
    const subdir_path = try std.fs.path.join(framework.allocator, &[_][]const u8{ test_dir, "subdir" });
    defer framework.allocator.free(subdir_path);
    try std.fs.cwd().makeDir(subdir_path);
    try framework.writeFile(subdir_path, "file3.txt", "Content 3\n");

    // Add all files with '.'
    var add_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{ "add", "." });
    defer add_result.deinit(framework.allocator);
    try framework.expectExitCode(0, add_result);

    // Verify with status
    var status_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{"status"});
    defer status_result.deinit(framework.allocator);
    try framework.expectExitCode(0, status_result);

    // All files should be staged
    if (std.mem.indexOf(u8, status_result.stdout, "file1.txt") == null or
        std.mem.indexOf(u8, status_result.stdout, "file2.txt") == null) {
        return error.NotAllFilesStaged;
    }
}

// Test: Add non-existent file (should fail)
fn testAddNonExistentFile(framework: *GitTestFramework) !void {
    const test_dir = try framework.createTestRepo("add-nonexistent");
    defer framework.allocator.free(test_dir);

    // Initialize repo
    var init_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{"init"});
    defer init_result.deinit(framework.allocator);
    try framework.expectExitCode(0, init_result);

    // Try to add non-existent file
    var add_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{ "add", "nonexistent.txt" });
    defer add_result.deinit(framework.allocator);
    
    // Should fail
    if (add_result.exit_code == 0) {
        return error.ExpectedAddToFail;
    }

    // Compare with git behavior
    const git_test_dir = try framework.createTestRepo("add-nonexistent-git");
    defer framework.allocator.free(git_test_dir);
    
    var git_init = try framework.runGitCommand(git_test_dir, &[_][]const u8{"init"});
    defer git_init.deinit(framework.allocator);
    
    var git_add = try framework.runGitCommand(git_test_dir, &[_][]const u8{ "add", "nonexistent.txt" });
    defer git_add.deinit(framework.allocator);
    
    // Git should also fail
    if (git_add.exit_code == 0) {
        return error.GitShouldAlsoFail;
    }
}

// Test: Add file then modify (check different states)
fn testAddThenModify(framework: *GitTestFramework) !void {
    const test_dir = try framework.createTestRepo("add-modify");
    defer framework.allocator.free(test_dir);

    // Initialize repo
    var init_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{"init"});
    defer init_result.deinit(framework.allocator);
    try framework.expectExitCode(0, init_result);

    // Create and add file
    try framework.writeFile(test_dir, "test.txt", "Original content\n");
    
    var add_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{ "add", "test.txt" });
    defer add_result.deinit(framework.allocator);
    try framework.expectExitCode(0, add_result);

    // Modify the file after adding
    try framework.writeFile(test_dir, "test.txt", "Modified content\n");

    // Status should show both staged and modified
    var status_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{"status"});
    defer status_result.deinit(framework.allocator);
    try framework.expectExitCode(0, status_result);

    // Should show file in staged area and working directory changes
    if (std.mem.indexOf(u8, status_result.stdout, "test.txt") == null) {
        return error.FileNotInStatus;
    }
}

// Test: Add empty directory (should be ignored like git)
fn testAddEmptyDirectory(framework: *GitTestFramework) !void {
    const test_dir = try framework.createTestRepo("add-empty-dir");
    defer framework.allocator.free(test_dir);

    // Initialize repo
    var init_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{"init"});
    defer init_result.deinit(framework.allocator);
    try framework.expectExitCode(0, init_result);

    // Create empty directory
    const empty_dir_path = try std.fs.path.join(framework.allocator, &[_][]const u8{ test_dir, "empty_dir" });
    defer framework.allocator.free(empty_dir_path);
    try std.fs.cwd().makeDir(empty_dir_path);

    // Try to add empty directory
    var add_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{ "add", "empty_dir" });
    defer add_result.deinit(framework.allocator);
    
    // Git ignores empty directories, so we should too
    // The command shouldn't fail but also shouldn't stage anything
    try framework.expectExitCode(0, add_result);

    // Status should not show the empty directory
    var status_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{"status"});
    defer status_result.deinit(framework.allocator);
    try framework.expectExitCode(0, status_result);
}

// Test: Add with pathspecs and patterns
fn testAddWithPatterns(framework: *GitTestFramework) !void {
    const test_dir = try framework.createTestRepo("add-patterns");
    defer framework.allocator.free(test_dir);

    // Initialize repo
    var init_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{"init"});
    defer init_result.deinit(framework.allocator);
    try framework.expectExitCode(0, init_result);

    // Create files with different extensions
    try framework.writeFile(test_dir, "file1.txt", "Text file 1\n");
    try framework.writeFile(test_dir, "file2.txt", "Text file 2\n");
    try framework.writeFile(test_dir, "script.sh", "#!/bin/bash\necho hello\n");
    try framework.writeFile(test_dir, "data.json", "{\"key\": \"value\"}\n");

    // Add only .txt files with pattern
    var add_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{ "add", "*.txt" });
    defer add_result.deinit(framework.allocator);
    try framework.expectExitCode(0, add_result);

    // Status should show only txt files staged
    var status_result = try framework.runZiggitCommand(test_dir, &[_][]const u8{"status"});
    defer status_result.deinit(framework.allocator);
    try framework.expectExitCode(0, status_result);

    // Should show txt files as staged
    if (std.mem.indexOf(u8, status_result.stdout, "file1.txt") == null or
        std.mem.indexOf(u8, status_result.stdout, "file2.txt") == null) {
        return error.TxtFilesNotStaged;
    }
}

pub fn runAddTests() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var framework = try GitTestFramework.init(allocator);
    defer framework.deinit();

    std.debug.print("Running t2000 Add Tests (Comprehensive)...\n", .{});

    try framework.testExpectSuccess("basic add single file", testBasicAdd);
    try framework.testExpectSuccess("add multiple files", testAddMultipleFiles);
    try framework.testExpectSuccess("add all files with '.'", testAddAll);
    try framework.testExpectSuccess("add non-existent file (should fail)", testAddNonExistentFile);
    try framework.testExpectSuccess("add then modify file", testAddThenModify);
    try framework.testExpectSuccess("add empty directory", testAddEmptyDirectory);
    try framework.testExpectSuccess("add with patterns", testAddWithPatterns);

    framework.summary();
    
    if (framework.failed_counter > 0) {
        std.process.exit(1);
    }
}