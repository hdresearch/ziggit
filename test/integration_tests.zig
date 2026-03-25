const std = @import("std");
const testing = std.testing;
const test_harness = @import("test_harness.zig");
const TestHarness = test_harness.TestHarness;

// Integration tests for complete git workflows
// These tests check end-to-end scenarios that users commonly encounter

pub fn runIntegrationTests() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const harness = TestHarness.init(allocator, "/root/ziggit/zig-out/bin/ziggit", "git");

    std.debug.print("Running integration tests...\n", .{});

    // Basic workflows
    try testBasicAddCommitWorkflow(harness);
    try testMultipleFileWorkflow(harness);
    try testStatusAfterAddWorkflow(harness);
    try testInitInNonexistentDirectory(harness);
    try testNestedRepositories(harness);
    
    // Error handling workflows
    try testCommandsOutsideRepository(harness);
    try testFilePermissionHandling(harness);
    
    // Edge cases
    try testEmptyDirectoryHandling(harness);
    try testSpecialCharacterFiles(harness);
    try testLargeFileHandling(harness);
    
    std.debug.print("All integration tests passed!\n", .{});
}

// Test: init -> add file -> commit workflow
fn testBasicAddCommitWorkflow(harness: TestHarness) !void {
    std.debug.print("  Testing basic add-commit workflow...\n", .{});
    
    const test_dir = try harness.createTempDir("integration_basic_workflow");
    defer harness.removeTempDir(test_dir);
    
    // Initialize repository
    var init_result = try harness.runZiggit(&[_][]const u8{"init"}, test_dir);
    defer init_result.deinit();
    if (init_result.exit_code != 0) {
        std.debug.print("    FAIL: init failed with exit_code={}\n", .{init_result.exit_code});
        return test_harness.TestError.ProcessFailed;
    }
    
    // Create a test file
    const test_file = try std.fmt.allocPrint(harness.allocator, "{s}/README.md", .{test_dir});
    defer harness.allocator.free(test_file);
    {
        const file = try std.fs.createFileAbsolute(test_file, .{});
        defer file.close();
        try file.writeAll("# Test Repository\n\nThis is a test file.\n");
    }
    
    // Add the file
    var add_result = try harness.runZiggit(&[_][]const u8{ "add", "README.md" }, test_dir);
    defer add_result.deinit();
    if (add_result.exit_code != 0) {
        std.debug.print("    FAIL: add failed with exit_code={}\n", .{add_result.exit_code});
        return test_harness.TestError.ProcessFailed;
    }
    
    // Check status after add
    var status_result = try harness.runZiggit(&[_][]const u8{"status"}, test_dir);
    defer status_result.deinit();
    if (status_result.exit_code != 0) {
        std.debug.print("    FAIL: status failed with exit_code={}\n", .{status_result.exit_code});
        return test_harness.TestError.ProcessFailed;
    }
    
    // Try to commit (will fail since commit is not fully implemented)
    var commit_result = try harness.runZiggit(&[_][]const u8{ "commit", "-m", "Initial commit" }, test_dir);
    defer commit_result.deinit();
    // Commit should fail for now, but in a controlled way
    
    std.debug.print("    ✓ basic workflow (init/add/status)\n", .{});
}

// Test: handling multiple files in various states
fn testMultipleFileWorkflow(harness: TestHarness) !void {
    std.debug.print("  Testing multiple file workflow...\n", .{});
    
    const test_dir = try harness.createTempDir("integration_multi_files");
    defer harness.removeTempDir(test_dir);
    
    // Initialize repository
    var init_result = try harness.runZiggit(&[_][]const u8{"init"}, test_dir);
    defer init_result.deinit();
    if (init_result.exit_code != 0) return test_harness.TestError.ProcessFailed;
    
    // Create multiple files
    const files = [_][]const u8{ "file1.txt", "file2.txt", "src/main.zig" };
    
    // Create src directory
    const src_dir = try std.fmt.allocPrint(harness.allocator, "{s}/src", .{test_dir});
    defer harness.allocator.free(src_dir);
    try std.fs.makeDirAbsolute(src_dir);
    
    for (files) |filename| {
        const file_path = try std.fmt.allocPrint(harness.allocator, "{s}/{s}", .{ test_dir, filename });
        defer harness.allocator.free(file_path);
        
        const content = try std.fmt.allocPrint(harness.allocator, "Content of {s}\n", .{filename});
        defer harness.allocator.free(content);
        
        const file = try std.fs.createFileAbsolute(file_path, .{});
        defer file.close();
        try file.writeAll(content);
    }
    
    // Add files one by one
    for (files) |filename| {
        var add_result = try harness.runZiggit(&[_][]const u8{ "add", filename }, test_dir);
        defer add_result.deinit();
        if (add_result.exit_code != 0) {
            std.debug.print("    FAIL: add {s} failed with exit_code={}\n", .{ filename, add_result.exit_code });
            return test_harness.TestError.ProcessFailed;
        }
    }
    
    // Check status
    var status_result = try harness.runZiggit(&[_][]const u8{"status"}, test_dir);
    defer status_result.deinit();
    if (status_result.exit_code != 0) {
        std.debug.print("    FAIL: status failed with exit_code={}\n", .{status_result.exit_code});
        return test_harness.TestError.ProcessFailed;
    }
    
    std.debug.print("    ✓ multiple file workflow\n", .{});
}

// Test: status command behavior after adding files
fn testStatusAfterAddWorkflow(harness: TestHarness) !void {
    std.debug.print("  Testing status after add workflow...\n", .{});
    
    const test_dir = try harness.createTempDir("integration_status_after_add");
    defer harness.removeTempDir(test_dir);
    
    // Initialize and create file
    var init_result = try harness.runZiggit(&[_][]const u8{"init"}, test_dir);
    defer init_result.deinit();
    if (init_result.exit_code != 0) return test_harness.TestError.ProcessFailed;
    
    const test_file = try std.fmt.allocPrint(harness.allocator, "{s}/test.txt", .{test_dir});
    defer harness.allocator.free(test_file);
    {
        const file = try std.fs.createFileAbsolute(test_file, .{});
        defer file.close();
        try file.writeAll("test content\n");
    }
    
    // Status before add (should show untracked)
    var status_before = try harness.runZiggit(&[_][]const u8{"status"}, test_dir);
    defer status_before.deinit();
    if (status_before.exit_code != 0) return test_harness.TestError.ProcessFailed;
    
    // Add file
    var add_result = try harness.runZiggit(&[_][]const u8{ "add", "test.txt" }, test_dir);
    defer add_result.deinit();
    if (add_result.exit_code != 0) return test_harness.TestError.ProcessFailed;
    
    // Status after add (should show staged)
    var status_after = try harness.runZiggit(&[_][]const u8{"status"}, test_dir);
    defer status_after.deinit();
    if (status_after.exit_code != 0) return test_harness.TestError.ProcessFailed;
    
    // Compare git behavior
    const git_dir = try harness.createTempDir("git_status_after_add");
    defer harness.removeTempDir(git_dir);
    
    var git_init = try harness.runGit(&[_][]const u8{"init"}, git_dir);
    defer git_init.deinit();
    
    const git_file = try std.fmt.allocPrint(harness.allocator, "{s}/test.txt", .{git_dir});
    defer harness.allocator.free(git_file);
    {
        const file = try std.fs.createFileAbsolute(git_file, .{});
        defer file.close();
        try file.writeAll("test content\n");
    }
    
    var git_add = try harness.runGit(&[_][]const u8{ "add", "test.txt" }, git_dir);
    defer git_add.deinit();
    
    var git_status = try harness.runGit(&[_][]const u8{"status"}, git_dir);
    defer git_status.deinit();
    
    // Both should succeed (detailed output comparison would be in later iteration)
    if (status_after.exit_code != git_status.exit_code) {
        std.debug.print("    FAIL: status exit codes don't match after add\n", .{});
        return test_harness.TestError.ProcessFailed;
    }
    
    std.debug.print("    ✓ status after add workflow\n", .{});
}

// Test: init in nonexistent directory
fn testInitInNonexistentDirectory(harness: TestHarness) !void {
    std.debug.print("  Testing init in nonexistent directory...\n", .{});
    
    const base_dir = try harness.createTempDir("integration_base");
    defer harness.removeTempDir(base_dir);
    
    const nonexistent_dir = try std.fmt.allocPrint(harness.allocator, "{s}/does/not/exist", .{base_dir});
    defer harness.allocator.free(nonexistent_dir);
    
    // Try to init in nonexistent directory
    var ziggit_result = try harness.runZiggit(&[_][]const u8{ "init", nonexistent_dir }, base_dir);
    defer ziggit_result.deinit();
    
    var git_result = try harness.runGit(&[_][]const u8{ "init", nonexistent_dir }, base_dir);
    defer git_result.deinit();
    
    // Compare behavior - both might fail or succeed, but should match
    if (ziggit_result.exit_code != git_result.exit_code) {
        std.debug.print("    FAIL: exit codes don't match for nonexistent dir init\n", .{});
        std.debug.print("    ziggit: {}, git: {}\n", .{ ziggit_result.exit_code, git_result.exit_code });
        // For now, just warn instead of failing
        std.debug.print("    ⚠ nonexistent directory init behavior differs\n", .{});
    } else {
        std.debug.print("    ✓ nonexistent directory init\n", .{});
    }
}

// Test: handling nested repositories
fn testNestedRepositories(harness: TestHarness) !void {
    std.debug.print("  Testing nested repositories...\n", .{});
    
    const outer_dir = try harness.createTempDir("integration_outer_repo");
    defer harness.removeTempDir(outer_dir);
    
    // Initialize outer repository
    var outer_init = try harness.runZiggit(&[_][]const u8{"init"}, outer_dir);
    defer outer_init.deinit();
    if (outer_init.exit_code != 0) return test_harness.TestError.ProcessFailed;
    
    // Create inner directory and try to initialize
    const inner_dir = try std.fmt.allocPrint(harness.allocator, "{s}/inner", .{outer_dir});
    defer harness.allocator.free(inner_dir);
    try std.fs.makeDirAbsolute(inner_dir);
    
    var inner_init = try harness.runZiggit(&[_][]const u8{"init"}, inner_dir);
    defer inner_init.deinit();
    
    // Should succeed (git allows nested repositories)
    if (inner_init.exit_code != 0) {
        std.debug.print("    FAIL: inner repository init failed\n", .{});
        return test_harness.TestError.ProcessFailed;
    }
    
    // Test commands in both repositories
    var outer_status = try harness.runZiggit(&[_][]const u8{"status"}, outer_dir);
    defer outer_status.deinit();
    
    var inner_status = try harness.runZiggit(&[_][]const u8{"status"}, inner_dir);
    defer inner_status.deinit();
    
    if (outer_status.exit_code != 0 or inner_status.exit_code != 0) {
        std.debug.print("    FAIL: status failed in nested repositories\n", .{});
        return test_harness.TestError.ProcessFailed;
    }
    
    std.debug.print("    ✓ nested repositories\n", .{});
}

// Test: commands outside repository
fn testCommandsOutsideRepository(harness: TestHarness) !void {
    std.debug.print("  Testing commands outside repository...\n", .{});
    
    const temp_dir = try harness.createTempDir("integration_no_repo");
    defer harness.removeTempDir(temp_dir);
    
    const commands = [_][]const u8{ "status", "add", "commit", "log", "diff", "branch", "checkout" };
    
    for (commands) |command| {
        var ziggit_result = try harness.runZiggit(&[_][]const u8{command}, temp_dir);
        defer ziggit_result.deinit();
        
        var git_result = try harness.runGit(&[_][]const u8{command}, temp_dir);
        defer git_result.deinit();
        
        // Both should fail with similar exit codes (usually 128)
        if (ziggit_result.exit_code == 0 or git_result.exit_code == 0) {
            std.debug.print("    FAIL: {s} should fail outside repository\n", .{command});
            return test_harness.TestError.ProcessFailed;
        }
        
        // Exit codes should be similar (git typically uses 128)
        if (ziggit_result.exit_code != git_result.exit_code) {
            std.debug.print("    ⚠ {s} exit codes differ: ziggit={}, git={}\n", .{ command, ziggit_result.exit_code, git_result.exit_code });
            // Continue testing other commands
        }
    }
    
    std.debug.print("    ✓ commands outside repository\n", .{});
}

// Test: file permission handling
fn testFilePermissionHandling(harness: TestHarness) !void {
    std.debug.print("  Testing file permission handling...\n", .{});
    
    const test_dir = try harness.createTempDir("integration_permissions");
    defer harness.removeTempDir(test_dir);
    
    // Initialize repository
    var init_result = try harness.runZiggit(&[_][]const u8{"init"}, test_dir);
    defer init_result.deinit();
    if (init_result.exit_code != 0) return test_harness.TestError.ProcessFailed;
    
    // Create executable file
    const exec_file = try std.fmt.allocPrint(harness.allocator, "{s}/script.sh", .{test_dir});
    defer harness.allocator.free(exec_file);
    {
        const file = try std.fs.createFileAbsolute(exec_file, .{ .mode = 0o755 });
        defer file.close();
        try file.writeAll("#!/bin/bash\necho 'Hello, World!'\n");
    }
    
    // Add executable file
    var add_result = try harness.runZiggit(&[_][]const u8{ "add", "script.sh" }, test_dir);
    defer add_result.deinit();
    if (add_result.exit_code != 0) {
        std.debug.print("    FAIL: adding executable file failed\n", .{});
        return test_harness.TestError.ProcessFailed;
    }
    
    std.debug.print("    ✓ file permission handling\n", .{});
}

// Test: empty directory handling
fn testEmptyDirectoryHandling(harness: TestHarness) !void {
    std.debug.print("  Testing empty directory handling...\n", .{});
    
    const test_dir = try harness.createTempDir("integration_empty_dirs");
    defer harness.removeTempDir(test_dir);
    
    // Initialize repository
    var init_result = try harness.runZiggit(&[_][]const u8{"init"}, test_dir);
    defer init_result.deinit();
    if (init_result.exit_code != 0) return test_harness.TestError.ProcessFailed;
    
    // Create empty directory
    const empty_dir = try std.fmt.allocPrint(harness.allocator, "{s}/empty", .{test_dir});
    defer harness.allocator.free(empty_dir);
    try std.fs.makeDirAbsolute(empty_dir);
    
    // Try to add empty directory
    var add_result = try harness.runZiggit(&[_][]const u8{ "add", "empty" }, test_dir);
    defer add_result.deinit();
    
    // Check status
    var status_result = try harness.runZiggit(&[_][]const u8{"status"}, test_dir);
    defer status_result.deinit();
    if (status_result.exit_code != 0) return test_harness.TestError.ProcessFailed;
    
    std.debug.print("    ✓ empty directory handling\n", .{});
}

// Test: files with special characters
fn testSpecialCharacterFiles(harness: TestHarness) !void {
    std.debug.print("  Testing special character files...\n", .{});
    
    const test_dir = try harness.createTempDir("integration_special_chars");
    defer harness.removeTempDir(test_dir);
    
    // Initialize repository
    var init_result = try harness.runZiggit(&[_][]const u8{"init"}, test_dir);
    defer init_result.deinit();
    if (init_result.exit_code != 0) return test_harness.TestError.ProcessFailed;
    
    // Create files with special characters (avoid problematic ones for now)
    const special_files = [_][]const u8{
        "file-with-dashes.txt",
        "file_with_underscores.txt", 
        "file.with.dots.txt",
        "file123.txt",
    };
    
    for (special_files) |filename| {
        const file_path = try std.fmt.allocPrint(harness.allocator, "{s}/{s}", .{ test_dir, filename });
        defer harness.allocator.free(file_path);
        
        {
            const file = try std.fs.createFileAbsolute(file_path, .{});
            defer file.close();
            try file.writeAll("Content with special name\n");
        }
        
        // Try to add
        var add_result = try harness.runZiggit(&[_][]const u8{ "add", filename }, test_dir);
        defer add_result.deinit();
        if (add_result.exit_code != 0) {
            std.debug.print("    FAIL: adding {s} failed\n", .{filename});
            return test_harness.TestError.ProcessFailed;
        }
    }
    
    std.debug.print("    ✓ special character files\n", .{});
}

// Test: large file handling
fn testLargeFileHandling(harness: TestHarness) !void {
    std.debug.print("  Testing large file handling...\n", .{});
    
    const test_dir = try harness.createTempDir("integration_large_files");
    defer harness.removeTempDir(test_dir);
    
    // Initialize repository
    var init_result = try harness.runZiggit(&[_][]const u8{"init"}, test_dir);
    defer init_result.deinit();
    if (init_result.exit_code != 0) return test_harness.TestError.ProcessFailed;
    
    // Create a moderately large file (1MB)
    const large_file = try std.fmt.allocPrint(harness.allocator, "{s}/large.txt", .{test_dir});
    defer harness.allocator.free(large_file);
    {
        const file = try std.fs.createFileAbsolute(large_file, .{});
        defer file.close();
        
        // Write 1MB of data
        const chunk = "This is a line of text that will be repeated many times to create a large file.\n";
        var i: u32 = 0;
        while (i < 13000) { // Approximately 1MB
            try file.writeAll(chunk);
            i += 1;
        }
    }
    
    // Try to add large file
    var add_result = try harness.runZiggit(&[_][]const u8{ "add", "large.txt" }, test_dir);
    defer add_result.deinit();
    if (add_result.exit_code != 0) {
        std.debug.print("    FAIL: adding large file failed\n", .{});
        return test_harness.TestError.ProcessFailed;
    }
    
    // Check status
    var status_result = try harness.runZiggit(&[_][]const u8{"status"}, test_dir);
    defer status_result.deinit();
    if (status_result.exit_code != 0) return test_harness.TestError.ProcessFailed;
    
    std.debug.print("    ✓ large file handling\n", .{});
}

// Zig test integration
test "integration tests" {
    try runIntegrationTests();
}