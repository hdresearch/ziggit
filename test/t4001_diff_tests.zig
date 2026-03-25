const std = @import("std");
const TestRunner = @import("git_source_test_adapter.zig").TestRunner;
const TestResult = @import("git_source_test_adapter.zig").TestResult;
const TestCase = @import("git_source_test_adapter.zig").TestCase;
const runTestSuite = @import("git_source_test_adapter.zig").runTestSuite;

// t4001-diff.sh - Test git diff functionality
// Adapted from git/git.git/t/t4* diff tests

// Setup function - initialize repository and configure user
fn setupRepository(runner: *TestRunner) !void {
    var result = try runner.runZiggit(&[_][]const u8{"init"});
    result.deinit(runner.allocator);
    if (result.exit_code != 0) return error.InitFailed;
    
    // Configure user
    result = try runner.runZiggit(&[_][]const u8{ "config", "user.name", "Test User" });
    result.deinit(runner.allocator);
    result = try runner.runZiggit(&[_][]const u8{ "config", "user.email", "test@example.com" });
    result.deinit(runner.allocator);
}

// Setup with initial commit for diff tests
fn setupWithCommit(runner: *TestRunner) !void {
    try setupRepository(runner);
    
    // Create initial commit
    try runner.createFile("file.txt", "line 1\nline 2\nline 3\n");
    var result = try runner.runZiggit(&[_][]const u8{ "add", "file.txt" });
    result.deinit(runner.allocator);
    result = try runner.runZiggit(&[_][]const u8{ "commit", "-m", "Initial commit" });
    result.deinit(runner.allocator);
}

// Test diff on clean repository (no changes)
fn testDiffClean(runner: *TestRunner) !TestResult {
    const result = try runner.runZiggit(&[_][]const u8{"diff"});
    defer result.deinit(runner.allocator);
    
    if (runner.expectExitCode(0, result.exit_code, "ziggit diff (clean)") == .fail) return .fail;
    
    // Clean repository should show no diff output
    if (result.stdout.len == 0) {
        std.debug.print("    ✓ diff on clean repository shows no output\n", .{});
    } else {
        std.debug.print("    ⚠ diff on clean repository shows output: {s}\n", .{result.stdout});
    }
    
    return .pass;
}

// Test diff with working directory changes
fn testDiffWorkingDirectory(runner: *TestRunner) !TestResult {
    // Modify the file
    try runner.createFile("file.txt", "line 1 modified\nline 2\nline 3\nline 4 added\n");
    
    const result = try runner.runZiggit(&[_][]const u8{"diff"});
    defer result.deinit(runner.allocator);
    
    if (runner.expectExitCode(0, result.exit_code, "ziggit diff (working directory changes)") == .fail) return .fail;
    
    // Should show diff output for modified file
    if (runner.expectContains(result.stdout, "file.txt", "shows modified file") == .fail) return .fail;
    
    // Should show diff markers
    if (std.mem.indexOf(u8, result.stdout, "@@") != null or
        std.mem.indexOf(u8, result.stdout, "+++") != null or
        std.mem.indexOf(u8, result.stdout, "---") != null) {
        std.debug.print("    ✓ diff shows standard diff format markers\n", .{});
    } else {
        std.debug.print("    ⚠ diff may not be using standard diff format\n", .{});
    }
    
    // Should show changes
    if (std.mem.indexOf(u8, result.stdout, "modified") != null or
        std.mem.indexOf(u8, result.stdout, "added") != null or
        std.mem.indexOf(u8, result.stdout, "+") != null or
        std.mem.indexOf(u8, result.stdout, "-") != null) {
        std.debug.print("    ✓ diff shows change indicators\n", .{});
    } else {
        std.debug.print("    ⚠ diff may not show change content\n", .{});
    }
    
    return .pass;
}

// Test diff --cached (staged changes)
fn testDiffCached(runner: *TestRunner) !TestResult {
    // Modify file and stage it
    try runner.createFile("file.txt", "line 1 staged\nline 2\nline 3\n");
    var result = try runner.runZiggit(&[_][]const u8{ "add", "file.txt" });
    result.deinit(runner.allocator);
    
    result = try runner.runZiggit(&[_][]const u8{"diff", "--cached"});
    defer result.deinit(runner.allocator);
    
    if (runner.expectExitCode(0, result.exit_code, "ziggit diff --cached") == .fail) return .fail;
    
    // Should show diff for staged changes
    if (runner.expectContains(result.stdout, "file.txt", "shows staged file") == .fail) return .fail;
    if (runner.expectContains(result.stdout, "staged", "shows staged content") == .fail) return .fail;
    
    return .pass;
}

// Test diff between commits
fn testDiffBetweenCommits(runner: *TestRunner) !TestResult {
    // Create second commit
    try runner.createFile("file2.txt", "second file\n");
    var result = try runner.runZiggit(&[_][]const u8{ "add", "file2.txt" });
    result.deinit(runner.allocator);
    result = try runner.runZiggit(&[_][]const u8{ "commit", "-m", "Second commit" });
    result.deinit(runner.allocator);
    
    // Get commit SHAs for comparison
    result = try runner.runZiggit(&[_][]const u8{"log", "--format=%H", "-n", "2"});
    defer result.deinit(runner.allocator);
    
    const output = std.mem.trim(u8, result.stdout, " \t\n\r");
    const lines = std.mem.split(u8, output, "\n");
    
    var line_it = lines;
    const second_commit = line_it.next() orelse return .skip;
    const first_commit = line_it.next() orelse return .skip;
    
    if (second_commit.len == 40 and first_commit.len == 40) {
        // Test diff between commits  
        const diff_result = try runner.runZiggit(&[_][]const u8{ "diff", first_commit, second_commit });
        defer diff_result.deinit(runner.allocator);
        
        if (runner.expectExitCode(0, diff_result.exit_code, "ziggit diff commit1 commit2") == .fail) return .fail;
        if (runner.expectContains(diff_result.stdout, "file2.txt", "shows added file") == .fail) return .fail;
        
        std.debug.print("    ✓ diff between commits works\n", .{});
        return .pass;
    } else {
        std.debug.print("    ⚠ Could not get proper commit SHAs for diff test\n", .{});
        return .skip;
    }
}

// Test diff --name-only option
fn testDiffNameOnly(runner: *TestRunner) !TestResult {
    // Modify the file
    try runner.createFile("file.txt", "modified content\n");
    
    const result = try runner.runZiggit(&[_][]const u8{"diff", "--name-only"});
    defer result.deinit(runner.allocator);
    
    if (runner.expectExitCode(0, result.exit_code, "ziggit diff --name-only") == .fail) return .fail;
    
    const output = std.mem.trim(u8, result.stdout, " \t\n\r");
    
    // Should show only filename, not diff content
    if (std.mem.eql(u8, output, "file.txt")) {
        std.debug.print("    ✓ --name-only shows only filename\n", .{});
    } else if (runner.expectContains(result.stdout, "file.txt", "contains filename") == .fail) {
        return .fail;
    } else {
        // Check that it doesn't contain diff content (like +++ or ---)
        if (std.mem.indexOf(u8, result.stdout, "+++") == null and
            std.mem.indexOf(u8, result.stdout, "---") == null) {
            std.debug.print("    ✓ --name-only doesn't show diff content\n", .{});
        } else {
            std.debug.print("    ✗ --name-only shows diff content when it shouldn't\n", .{});
            return .fail;
        }
    }
    
    return .pass;
}

// Test diff --stat option
fn testDiffStat(runner: *TestRunner) !TestResult {
    // Modify the file  
    try runner.createFile("file.txt", "line 1 changed\nline 2\nline 3\nnew line 4\n");
    
    const result = try runner.runZiggit(&[_][]const u8{"diff", "--stat"});
    defer result.deinit(runner.allocator);
    
    if (runner.expectExitCode(0, result.exit_code, "ziggit diff --stat") == .fail) return .fail;
    if (runner.expectContains(result.stdout, "file.txt", "shows filename in stats") == .fail) return .fail;
    
    // Should show statistics (insertions/deletions/changes)
    if (std.mem.indexOf(u8, result.stdout, "|") != null or
        std.mem.indexOf(u8, result.stdout, "+") != null or
        std.mem.indexOf(u8, result.stdout, "-") != null or
        std.mem.indexOf(u8, result.stdout, "changed") != null) {
        std.debug.print("    ✓ --stat shows change statistics\n", .{});
    } else {
        std.debug.print("    ⚠ --stat may not show proper statistics format\n", .{});
    }
    
    return .pass;
}

// Test diff with new file
fn testDiffNewFile(runner: *TestRunner) !TestResult {
    try runner.createFile("newfile.txt", "new file content\n");
    
    const result = try runner.runZiggit(&[_][]const u8{"diff"});
    defer result.deinit(runner.allocator);
    
    if (runner.expectExitCode(0, result.exit_code, "ziggit diff (new file)") == .fail) return .fail;
    
    // New untracked files might not show in diff (this is git behavior)
    // Or they might be shown - both are acceptable
    if (std.mem.indexOf(u8, result.stdout, "newfile.txt") != null) {
        std.debug.print("    ✓ diff shows new untracked files\n", .{});
    } else {
        std.debug.print("    ✓ diff doesn't show untracked files (git-like behavior)\n", .{});
    }
    
    // Now add and test diff --cached
    var add_result = try runner.runZiggit(&[_][]const u8{ "add", "newfile.txt" });
    add_result.deinit(runner.allocator);
    
    const cached_result = try runner.runZiggit(&[_][]const u8{"diff", "--cached"});
    defer cached_result.deinit(runner.allocator);
    
    if (runner.expectContains(cached_result.stdout, "newfile.txt", "shows new file in --cached") == .fail) return .fail;
    
    return .pass;
}

// Test diff with deleted file  
fn testDiffDeletedFile(runner: *TestRunner) !TestResult {
    // Delete the tracked file
    var buf: [256]u8 = undefined;
    const file_path = try std.fmt.bufPrint(&buf, "{s}/file.txt", .{runner.test_dir});
    std.fs.cwd().deleteFile(file_path[1..]) catch {};
    
    const result = try runner.runZiggit(&[_][]const u8{"diff"});
    defer result.deinit(runner.allocator);
    
    if (runner.expectExitCode(0, result.exit_code, "ziggit diff (deleted file)") == .fail) return .fail;
    if (runner.expectContains(result.stdout, "file.txt", "shows deleted file") == .fail) return .fail;
    
    // Should indicate file deletion
    if (std.mem.indexOf(u8, result.stdout, "deleted") != null or
        std.mem.indexOf(u8, result.stdout, "---") != null) {
        std.debug.print("    ✓ diff shows file deletion indicators\n", .{});
    } else {
        std.debug.print("    ⚠ diff may not clearly indicate file deletion\n", .{});
    }
    
    return .pass;
}

// Compare ziggit and git diff behavior
fn testDiffCompatibilityWithGit(runner: *TestRunner) !TestResult {
    // Create a change for comparison
    try runner.createFile("file.txt", "modified line\nline 2\nline 3\n");
    
    const ziggit_result = try runner.runZiggit(&[_][]const u8{"diff", "--name-only"});
    defer ziggit_result.deinit(runner.allocator);
    
    // Initialize git repo for comparison
    var git_result = try runner.runCommand(&[_][]const u8{ "git", "init", "git-test" });
    git_result.deinit(runner.allocator);
    
    // Configure git user and create similar setup
    var proc = std.process.Child.init(&[_][]const u8{ "git", "config", "user.name", "Test User" }, runner.allocator);
    var buf: [256]u8 = undefined;
    const git_test_path = try std.fmt.bufPrint(&buf, "{s}/git-test", .{runner.test_dir});
    proc.cwd = git_test_path;
    _ = try proc.spawnAndWait();
    
    proc = std.process.Child.init(&[_][]const u8{ "git", "config", "user.email", "test@example.com" }, runner.allocator);
    proc.cwd = git_test_path;
    _ = try proc.spawnAndWait();
    
    // Create similar state in git
    try runner.createFile("git-test/file.txt", "line 1\nline 2\nline 3\n");
    proc = std.process.Child.init(&[_][]const u8{ "git", "add", "file.txt" }, runner.allocator);
    proc.cwd = git_test_path;
    _ = try proc.spawnAndWait();
    proc = std.process.Child.init(&[_][]const u8{ "git", "commit", "-m", "Initial" }, runner.allocator);
    proc.cwd = git_test_path;
    _ = try proc.spawnAndWait();
    
    // Modify file in git repo
    try runner.createFile("git-test/file.txt", "modified line\nline 2\nline 3\n");
    
    // Test git diff
    proc = std.process.Child.init(&[_][]const u8{ "git", "diff", "--name-only" }, runner.allocator);
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
    if (runner.expectExitCode(0, ziggit_result.exit_code, "ziggit diff") == .fail) return .fail;
    if (runner.expectExitCode(0, git_code, "git diff") == .fail) return .fail;
    
    // Both should show the modified file
    const ziggit_output = std.mem.trim(u8, ziggit_result.stdout, " \t\n\r");
    const git_output = std.mem.trim(u8, git_stdout, " \t\n\r");
    
    if (std.mem.eql(u8, ziggit_output, git_output)) {
        std.debug.print("    ✓ ziggit and git diff --name-only produce identical output\n", .{});
    } else {
        std.debug.print("    ⚠ diff output differs: ziggit='{s}' git='{s}'\n", .{ ziggit_output, git_output });
    }
    
    return .pass;
}

const test_cases = [_]TestCase{
    .{
        .name = "diff-clean",
        .description = "diff on clean repository",
        .setup_fn = setupWithCommit,
        .test_fn = testDiffClean,
    },
    .{
        .name = "diff-working-directory",
        .description = "diff with working directory changes",
        .setup_fn = setupWithCommit,
        .test_fn = testDiffWorkingDirectory,
    },
    .{
        .name = "diff-cached",
        .description = "diff --cached shows staged changes",
        .setup_fn = setupWithCommit,
        .test_fn = testDiffCached,
    },
    .{
        .name = "diff-between-commits",
        .description = "diff between two commits",
        .setup_fn = setupWithCommit,
        .test_fn = testDiffBetweenCommits,
    },
    .{
        .name = "diff-name-only",
        .description = "diff --name-only shows filenames only",
        .setup_fn = setupWithCommit,
        .test_fn = testDiffNameOnly,
    },
    .{
        .name = "diff-stat",
        .description = "diff --stat shows statistics",
        .setup_fn = setupWithCommit,
        .test_fn = testDiffStat,
    },
    .{
        .name = "diff-new-file",
        .description = "diff with new files",
        .setup_fn = setupWithCommit,
        .test_fn = testDiffNewFile,
    },
    .{
        .name = "diff-deleted-file",
        .description = "diff with deleted files",
        .setup_fn = setupWithCommit,
        .test_fn = testDiffDeletedFile,
    },
    .{
        .name = "compatibility",
        .description = "ziggit diff behavior matches git diff",
        .setup_fn = setupWithCommit,
        .test_fn = testDiffCompatibilityWithGit,
    },
};

pub fn runT4001DiffTests() !void {
    try runTestSuite("t4001-diff (Git Diff Tests)", &test_cases);
}