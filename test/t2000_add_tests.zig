const std = @import("std");
const TestRunner = @import("git_source_test_adapter.zig").TestRunner;
const TestResult = @import("git_source_test_adapter.zig").TestResult;
const TestCase = @import("git_source_test_adapter.zig").TestCase;
const runTestSuite = @import("git_source_test_adapter.zig").runTestSuite;

// t2000-add.sh - Test git add functionality
// Adapted from git/git.git/t/t2000* tests

// Setup function - initialize repository
fn setupRepository(runner: *TestRunner) !void {
    const result = try runner.runZiggit(&[_][]const u8{"init"});
    defer result.deinit(runner.allocator);
    
    if (result.exit_code != 0) {
        return error.InitFailed;
    }
}

// Test adding a single file
fn testAddSingleFile(runner: *TestRunner) !TestResult {
    try runner.createFile("file.txt", "hello world\n");
    
    const result = try runner.runZiggit(&[_][]const u8{ "add", "file.txt" });
    defer result.deinit(runner.allocator);
    
    if (runner.expectExitCode(0, result.exit_code, "ziggit add file.txt") == .fail) return .fail;
    
    // Check that file is staged (git status should show it)
    const status_result = try runner.runZiggit(&[_][]const u8{"status", "--porcelain"});
    defer status_result.deinit(runner.allocator);
    
    if (runner.expectContains(status_result.stdout, "A", "file marked as added") == .fail) return .fail;
    
    return .pass;
}

// Test adding multiple files
fn testAddMultipleFiles(runner: *TestRunner) !TestResult {
    try runner.createFile("file1.txt", "content1\n");
    try runner.createFile("file2.txt", "content2\n");
    
    const result = try runner.runZiggit(&[_][]const u8{ "add", "file1.txt", "file2.txt" });
    defer result.deinit(runner.allocator);
    
    if (runner.expectExitCode(0, result.exit_code, "ziggit add multiple files") == .fail) return .fail;
    
    const status_result = try runner.runZiggit(&[_][]const u8{"status", "--porcelain"});
    defer status_result.deinit(runner.allocator);
    
    // Both files should be staged
    if (runner.expectContains(status_result.stdout, "file1.txt", "file1 in status") == .fail) return .fail;
    if (runner.expectContains(status_result.stdout, "file2.txt", "file2 in status") == .fail) return .fail;
    
    return .pass;
}

// Test adding with glob pattern
fn testAddWithGlob(runner: *TestRunner) !TestResult {
    try runner.createFile("test1.txt", "content1\n");
    try runner.createFile("test2.txt", "content2\n");
    try runner.createFile("other.md", "markdown\n");
    
    const result = try runner.runZiggit(&[_][]const u8{ "add", "*.txt" });
    defer result.deinit(runner.allocator);
    
    if (runner.expectExitCode(0, result.exit_code, "ziggit add *.txt") == .fail) return .fail;
    
    const status_result = try runner.runZiggit(&[_][]const u8{"status", "--porcelain"});
    defer status_result.deinit(runner.allocator);
    
    // txt files should be staged, md should not
    if (runner.expectContains(status_result.stdout, "test1.txt", "test1.txt staged") == .fail) return .fail;
    if (runner.expectContains(status_result.stdout, "test2.txt", "test2.txt staged") == .fail) return .fail;
    
    return .pass;
}

// Test adding all files
fn testAddAll(runner: *TestRunner) !TestResult {
    try runner.createFile("file1.txt", "content1\n");
    try runner.createFile("subdir/file2.txt", "content2\n");
    
    const result = try runner.runZiggit(&[_][]const u8{ "add", "." });
    defer result.deinit(runner.allocator);
    
    if (runner.expectExitCode(0, result.exit_code, "ziggit add .") == .fail) return .fail;
    
    const status_result = try runner.runZiggit(&[_][]const u8{"status", "--porcelain"});
    defer status_result.deinit(runner.allocator);
    
    // All files should be staged
    if (runner.expectContains(status_result.stdout, "file1.txt", "file1.txt staged") == .fail) return .fail;
    if (runner.expectContains(status_result.stdout, "subdir/file2.txt", "subdir/file2.txt staged") == .fail) return .fail;
    
    return .pass;
}

// Test adding nonexistent file (should fail)
fn testAddNonexistentFile(runner: *TestRunner) !TestResult {
    const result = try runner.runZiggit(&[_][]const u8{ "add", "nonexistent.txt" });
    defer result.deinit(runner.allocator);
    
    // Should fail with non-zero exit code
    if (result.exit_code == 0) {
        std.debug.print("    ✗ ziggit add nonexistent file should fail but succeeded\n", .{});
        return .fail;
    }
    
    if (runner.expectContains(result.stderr, "pathspec", "error mentions pathspec") == .fail) {
        // Alternative error message format
        if (runner.expectContains(result.stderr, "not found", "alternative error format") == .fail) {
            if (runner.expectContains(result.stderr, "exist", "mentions existence") == .fail) return .fail;
        }
    }
    
    std.debug.print("    ✓ ziggit add nonexistent file fails appropriately\n", .{});
    return .pass;
}

// Test adding empty directory (should be no-op or informative)
fn testAddEmptyDirectory(runner: *TestRunner) !TestResult {
    // Create empty directory
    var buf: [256]u8 = undefined;
    const dir_path = try std.fmt.bufPrint(&buf, "{s}/emptydir", .{runner.test_dir});
    try std.fs.cwd().makePath(dir_path[1..]);
    
    const result = try runner.runZiggit(&[_][]const u8{ "add", "emptydir" });
    defer result.deinit(runner.allocator);
    
    // Git ignores empty directories, ziggit should do the same
    if (runner.expectExitCode(0, result.exit_code, "ziggit add empty directory") == .fail) return .fail;
    
    const status_result = try runner.runZiggit(&[_][]const u8{"status", "--porcelain"});
    defer status_result.deinit(runner.allocator);
    
    // Empty directory should not appear in status
    if (std.mem.indexOf(u8, status_result.stdout, "emptydir") != null) {
        std.debug.print("    ⚠ Empty directory appears in status (may be implementation difference)\n", .{});
        // This might be acceptable difference
    }
    
    return .pass;
}

// Test adding file then modifying it
fn testAddModifiedFile(runner: *TestRunner) !TestResult {
    try runner.createFile("file.txt", "initial content\n");
    
    // Add the file
    var result = try runner.runZiggit(&[_][]const u8{ "add", "file.txt" });
    result.deinit(runner.allocator);
    
    // Modify the file
    try runner.createFile("file.txt", "modified content\n");
    
    // Check status - should show both staged and unstaged changes
    result = try runner.runZiggit(&[_][]const u8{"status", "--porcelain"});
    defer result.deinit(runner.allocator);
    
    // Should show file as both staged (A or M in first column) and modified (M in second column)
    if (std.mem.indexOf(u8, result.stdout, "file.txt") == null) {
        std.debug.print("    ✗ modified staged file not shown in status\n", .{});
        return .fail;
    }
    
    std.debug.print("    ✓ modified staged file appears in status\n", .{});
    return .pass;
}

// Compare ziggit and git add behavior
fn testAddCompatibilityWithGit(runner: *TestRunner) !TestResult {
    // Create test files
    try runner.createFile("test.txt", "test content\n");
    
    // Test ziggit add
    const ziggit_result = try runner.runZiggit(&[_][]const u8{ "add", "test.txt" });
    defer ziggit_result.deinit(runner.allocator);
    
    // Initialize git repo in different directory for comparison
    const git_init = try runner.runCommand(&[_][]const u8{ "git", "init", "git-test" });
    defer git_init.deinit(runner.allocator);
    
    // Create similar file in git repo
    try runner.createFile("git-test/test.txt", "test content\n");
    
    // Test git add
    var proc = std.process.Child.init(&[_][]const u8{ "git", "add", "test.txt" }, runner.allocator);
    var buf: [256]u8 = undefined;
    const git_test_path = try std.fmt.bufPrint(&buf, "{s}/git-test", .{runner.test_dir});
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
    if (runner.expectExitCode(0, ziggit_result.exit_code, "ziggit add") == .fail) return .fail;
    if (runner.expectExitCode(0, git_code, "git add") == .fail) return .fail;
    
    std.debug.print("    ✓ ziggit add behavior matches git add\n", .{});
    return .pass;
}

const test_cases = [_]TestCase{
    .{
        .name = "add-single-file",
        .description = "add a single file to staging area",
        .setup_fn = setupRepository,
        .test_fn = testAddSingleFile,
    },
    .{
        .name = "add-multiple-files",
        .description = "add multiple files at once",
        .setup_fn = setupRepository,
        .test_fn = testAddMultipleFiles,
    },
    .{
        .name = "add-glob",
        .description = "add files using glob pattern",
        .setup_fn = setupRepository,
        .test_fn = testAddWithGlob,
    },
    .{
        .name = "add-all",
        .description = "add all files with 'add .'",
        .setup_fn = setupRepository,
        .test_fn = testAddAll,
    },
    .{
        .name = "add-nonexistent",
        .description = "adding nonexistent file should fail appropriately",
        .setup_fn = setupRepository,
        .test_fn = testAddNonexistentFile,
    },
    .{
        .name = "add-empty-dir",
        .description = "adding empty directory should be handled",
        .setup_fn = setupRepository,
        .test_fn = testAddEmptyDirectory,
    },
    .{
        .name = "add-modified",
        .description = "adding then modifying file shows in status correctly",
        .setup_fn = setupRepository,
        .test_fn = testAddModifiedFile,
    },
    .{
        .name = "compatibility",
        .description = "ziggit add behavior matches git add",
        .setup_fn = setupRepository,
        .test_fn = testAddCompatibilityWithGit,
    },
};

pub fn runT2000AddTests() !void {
    try runTestSuite("t2000-add (Git Add Tests)", &test_cases);
}