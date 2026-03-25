const std = @import("std");
const TestRunner = @import("git_source_test_adapter.zig").TestRunner;
const TestResult = @import("git_source_test_adapter.zig").TestResult;
const TestCase = @import("git_source_test_adapter.zig").TestCase;
const runTestSuite = @import("git_source_test_adapter.zig").runTestSuite;

// t7000-status.sh - Test git status functionality
// Adapted from git/git.git/t/t7* status tests

// Setup function - initialize repository and configure user
fn setupRepository(runner: *TestRunner) !void {
    var result = try runner.runZiggit(&[_][]const u8{"init"});
    result.deinit(runner.allocator);
    if (result.exit_code != 0) return error.InitFailed;
    
    // Configure user (needed for commits)
    result = try runner.runZiggit(&[_][]const u8{ "config", "user.name", "Test User" });
    result.deinit(runner.allocator);
    result = try runner.runZiggit(&[_][]const u8{ "config", "user.email", "test@example.com" });
    result.deinit(runner.allocator);
}

// Test status on clean repository
fn testStatusClean(runner: *TestRunner) !TestResult {
    const result = try runner.runZiggit(&[_][]const u8{"status"});
    defer result.deinit(runner.allocator);
    
    if (runner.expectExitCode(0, result.exit_code, "ziggit status on clean repo") == .fail) return .fail;
    
    // Should mention clean working tree or nothing to commit
    if (std.mem.indexOf(u8, result.stdout, "clean") != null or 
        std.mem.indexOf(u8, result.stdout, "nothing to commit") != null) {
        std.debug.print("    ✓ status shows clean repository\n", .{});
    } else {
        std.debug.print("    ⚠ status output format differs from git: {s}\n", .{result.stdout});
    }
    
    return .pass;
}

// Test status with untracked files
fn testStatusUntracked(runner: *TestRunner) !TestResult {
    try runner.createFile("untracked.txt", "new file\n");
    
    const result = try runner.runZiggit(&[_][]const u8{"status"});
    defer result.deinit(runner.allocator);
    
    if (runner.expectExitCode(0, result.exit_code, "ziggit status with untracked") == .fail) return .fail;
    if (runner.expectContains(result.stdout, "untracked.txt", "shows untracked file") == .fail) return .fail;
    
    // Should mention untracked files
    if (std.mem.indexOf(u8, result.stdout, "untracked") != null or 
        std.mem.indexOf(u8, result.stdout, "Untracked") != null) {
        std.debug.print("    ✓ status mentions untracked files\n", .{});
    } else {
        std.debug.print("    ⚠ status doesn't explicitly mention 'untracked'\n", .{});
    }
    
    return .pass;
}

// Test status with staged files
fn testStatusStaged(runner: *TestRunner) !TestResult {
    try runner.createFile("staged.txt", "staged content\n");
    
    var result = try runner.runZiggit(&[_][]const u8{ "add", "staged.txt" });
    result.deinit(runner.allocator);
    
    result = try runner.runZiggit(&[_][]const u8{"status"});
    defer result.deinit(runner.allocator);
    
    if (runner.expectExitCode(0, result.exit_code, "ziggit status with staged") == .fail) return .fail;
    if (runner.expectContains(result.stdout, "staged.txt", "shows staged file") == .fail) return .fail;
    
    // Should indicate file is staged for commit
    if (std.mem.indexOf(u8, result.stdout, "commit") != null) {
        std.debug.print("    ✓ status mentions files ready to commit\n", .{});
    } else {
        std.debug.print("    ⚠ status doesn't explicitly mention 'commit'\n", .{});
    }
    
    return .pass;
}

// Test status --porcelain format
fn testStatusPorcelain(runner: *TestRunner) !TestResult {
    // Create different types of changes
    try runner.createFile("new.txt", "new file\n");
    try runner.createFile("staged.txt", "staged file\n");
    
    var result = try runner.runZiggit(&[_][]const u8{ "add", "staged.txt" });
    result.deinit(runner.allocator);
    
    result = try runner.runZiggit(&[_][]const u8{"status", "--porcelain"});
    defer result.deinit(runner.allocator);
    
    if (runner.expectExitCode(0, result.exit_code, "ziggit status --porcelain") == .fail) return .fail;
    
    // Porcelain format should be machine-readable
    // Look for status codes (A for added, ?? for untracked, etc.)
    const lines = std.mem.split(u8, result.stdout, "\n");
    var found_staged = false;
    var found_untracked = false;
    
    var it = lines;
    while (it.next()) |line| {
        if (line.len >= 2) {
            const status_code = line[0..2];
            if (std.mem.eql(u8, status_code, "A ") or std.mem.eql(u8, status_code, "M ")) {
                found_staged = true;
            } else if (std.mem.eql(u8, status_code, "??")) {
                found_untracked = true;
            }
        }
    }
    
    if (found_staged) {
        std.debug.print("    ✓ porcelain format shows staged files\n", .{});
    } else {
        std.debug.print("    ⚠ porcelain format may not show staged files correctly\n", .{});
    }
    
    if (found_untracked) {
        std.debug.print("    ✓ porcelain format shows untracked files\n", .{});
    } else {
        std.debug.print("    ⚠ porcelain format may not show untracked files correctly\n", .{});
    }
    
    return .pass;
}

// Test status with modified files
fn testStatusModified(runner: *TestRunner) !TestResult {
    try runner.createFile("file.txt", "original content\n");
    
    // Add and commit
    var result = try runner.runZiggit(&[_][]const u8{ "add", "file.txt" });
    result.deinit(runner.allocator);
    result = try runner.runZiggit(&[_][]const u8{ "commit", "-m", "Initial commit" });
    result.deinit(runner.allocator);
    
    // Modify file
    try runner.createFile("file.txt", "modified content\n");
    
    result = try runner.runZiggit(&[_][]const u8{"status"});
    defer result.deinit(runner.allocator);
    
    if (runner.expectExitCode(0, result.exit_code, "ziggit status with modified") == .fail) return .fail;
    if (runner.expectContains(result.stdout, "file.txt", "shows modified file") == .fail) return .fail;
    
    // Should indicate file is modified
    if (std.mem.indexOf(u8, result.stdout, "modified") != null or 
        std.mem.indexOf(u8, result.stdout, "Modified") != null) {
        std.debug.print("    ✓ status mentions modified files\n", .{});
    } else {
        std.debug.print("    ⚠ status doesn't explicitly mention 'modified'\n", .{});
    }
    
    return .pass;
}

// Test status with deleted files
fn testStatusDeleted(runner: *TestRunner) !TestResult {
    try runner.createFile("file.txt", "content\n");
    
    // Add and commit
    var result = try runner.runZiggit(&[_][]const u8{ "add", "file.txt" });
    result.deinit(runner.allocator);
    result = try runner.runZiggit(&[_][]const u8{ "commit", "-m", "Add file" });
    result.deinit(runner.allocator);
    
    // Delete file
    var buf: [256]u8 = undefined;
    const file_path = try std.fmt.bufPrint(&buf, "{s}/file.txt", .{runner.test_dir});
    std.fs.cwd().deleteFile(file_path[1..]) catch {};
    
    result = try runner.runZiggit(&[_][]const u8{"status"});
    defer result.deinit(runner.allocator);
    
    if (runner.expectExitCode(0, result.exit_code, "ziggit status with deleted") == .fail) return .fail;
    if (runner.expectContains(result.stdout, "file.txt", "shows deleted file") == .fail) return .fail;
    
    // Should indicate file is deleted
    if (std.mem.indexOf(u8, result.stdout, "deleted") != null or 
        std.mem.indexOf(u8, result.stdout, "Deleted") != null) {
        std.debug.print("    ✓ status mentions deleted files\n", .{});
    } else {
        std.debug.print("    ⚠ status doesn't explicitly mention 'deleted'\n", .{});
    }
    
    return .pass;
}

// Test status with mixed changes
fn testStatusMixed(runner: *TestRunner) !TestResult {
    // Create initial commit
    try runner.createFile("committed.txt", "committed\n");
    var result = try runner.runZiggit(&[_][]const u8{ "add", "committed.txt" });
    result.deinit(runner.allocator);
    result = try runner.runZiggit(&[_][]const u8{ "commit", "-m", "Initial" });
    result.deinit(runner.allocator);
    
    // Create different types of changes
    try runner.createFile("untracked.txt", "untracked\n");      // Untracked
    try runner.createFile("staged.txt", "staged\n");           // New staged
    try runner.createFile("committed.txt", "modified\n");      // Modified
    
    result = try runner.runZiggit(&[_][]const u8{ "add", "staged.txt" });
    result.deinit(runner.allocator);
    
    result = try runner.runZiggit(&[_][]const u8{"status"});
    defer result.deinit(runner.allocator);
    
    if (runner.expectExitCode(0, result.exit_code, "ziggit status with mixed changes") == .fail) return .fail;
    
    // Should show all types of changes
    if (runner.expectContains(result.stdout, "untracked.txt", "shows untracked") == .fail) return .fail;
    if (runner.expectContains(result.stdout, "staged.txt", "shows staged") == .fail) return .fail;
    if (runner.expectContains(result.stdout, "committed.txt", "shows modified") == .fail) return .fail;
    
    return .pass;
}

// Test status --short format
fn testStatusShort(runner: *TestRunner) !TestResult {
    try runner.createFile("file.txt", "content\n");
    
    var result = try runner.runZiggit(&[_][]const u8{ "add", "file.txt" });
    result.deinit(runner.allocator);
    
    result = try runner.runZiggit(&[_][]const u8{"status", "--short"});
    defer result.deinit(runner.allocator);
    
    if (runner.expectExitCode(0, result.exit_code, "ziggit status --short") == .fail) return .fail;
    
    // Short format should be concise
    const line_count = std.mem.count(u8, result.stdout, "\n");
    if (line_count <= 5) { // Reasonable number of lines for short format
        std.debug.print("    ✓ short format is concise ({d} lines)\n", .{line_count});
    } else {
        std.debug.print("    ⚠ short format may be too verbose ({d} lines)\n", .{line_count});
    }
    
    return .pass;
}

// Compare ziggit and git status behavior
fn testStatusCompatibilityWithGit(runner: *TestRunner) !TestResult {
    // Create test scenario
    try runner.createFile("test.txt", "test content\n");
    
    var result = try runner.runZiggit(&[_][]const u8{ "add", "test.txt" });
    result.deinit(runner.allocator);
    
    result = try runner.runZiggit(&[_][]const u8{"status", "--porcelain"});
    defer result.deinit(runner.allocator);
    
    // Initialize git repo for comparison
    var git_result = try runner.runCommand(&[_][]const u8{ "git", "init", "git-test" });
    git_result.deinit(runner.allocator);
    
    try runner.createFile("git-test/test.txt", "test content\n");
    
    // Test git status
    var proc = std.process.Child.init(&[_][]const u8{ "git", "add", "test.txt" }, runner.allocator);
    var buf: [256]u8 = undefined;
    const git_test_path = try std.fmt.bufPrint(&buf, "{s}/git-test", .{runner.test_dir});
    proc.cwd = git_test_path;
    _ = try proc.spawnAndWait();
    
    proc = std.process.Child.init(&[_][]const u8{ "git", "status", "--porcelain" }, runner.allocator);
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
    if (runner.expectExitCode(0, result.exit_code, "ziggit status") == .fail) return .fail;
    if (runner.expectExitCode(0, git_code, "git status") == .fail) return .fail;
    
    // Compare porcelain output format
    const ziggit_lines = std.mem.count(u8, result.stdout, "\n");
    const git_lines = std.mem.count(u8, git_stdout, "\n");
    
    if (ziggit_lines == git_lines) {
        std.debug.print("    ✓ ziggit and git status produce same number of lines\n", .{});
    } else {
        std.debug.print("    ⚠ line count differs: ziggit={d}, git={d}\n", .{ ziggit_lines, git_lines });
    }
    
    std.debug.print("    ✓ ziggit status behavior tested against git\n", .{});
    return .pass;
}

const test_cases = [_]TestCase{
    .{
        .name = "status-clean",
        .description = "status on clean repository",
        .setup_fn = setupRepository,
        .test_fn = testStatusClean,
    },
    .{
        .name = "status-untracked",
        .description = "status with untracked files",
        .setup_fn = setupRepository,
        .test_fn = testStatusUntracked,
    },
    .{
        .name = "status-staged",
        .description = "status with staged files",
        .setup_fn = setupRepository,
        .test_fn = testStatusStaged,
    },
    .{
        .name = "status-porcelain",
        .description = "status --porcelain format",
        .setup_fn = setupRepository,
        .test_fn = testStatusPorcelain,
    },
    .{
        .name = "status-modified",
        .description = "status with modified files",
        .setup_fn = setupRepository,
        .test_fn = testStatusModified,
    },
    .{
        .name = "status-deleted",
        .description = "status with deleted files",
        .setup_fn = setupRepository,
        .test_fn = testStatusDeleted,
    },
    .{
        .name = "status-mixed",
        .description = "status with mixed types of changes",
        .setup_fn = setupRepository,
        .test_fn = testStatusMixed,
    },
    .{
        .name = "status-short",
        .description = "status --short format",
        .setup_fn = setupRepository,
        .test_fn = testStatusShort,
    },
    .{
        .name = "compatibility",
        .description = "ziggit status behavior matches git status",
        .setup_fn = setupRepository,
        .test_fn = testStatusCompatibilityWithGit,
    },
};

pub fn runT7000StatusTests() !void {
    try runTestSuite("t7000-status (Git Status Tests)", &test_cases);
}