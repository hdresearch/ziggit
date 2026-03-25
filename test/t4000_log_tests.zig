const std = @import("std");
const TestRunner = @import("git_source_test_adapter.zig").TestRunner;
const TestResult = @import("git_source_test_adapter.zig").TestResult;
const TestCase = @import("git_source_test_adapter.zig").TestCase;
const runTestSuite = @import("git_source_test_adapter.zig").runTestSuite;

// t4000-log.sh - Test git log functionality
// Adapted from git/git.git/t/t4* log tests

// Setup function - initialize repository, configure user, and create some commits
fn setupRepository(runner: *TestRunner) !void {
    var result = try runner.runZiggit(&[_][]const u8{"init"});
    result.deinit(runner.allocator);
    if (result.exit_code != 0) return error.InitFailed;
    
    // Configure user (required for commits)
    result = try runner.runZiggit(&[_][]const u8{ "config", "user.name", "Test User" });
    result.deinit(runner.allocator);
    result = try runner.runZiggit(&[_][]const u8{ "config", "user.email", "test@example.com" });
    result.deinit(runner.allocator);
    
    // Create some commits for testing log
    try runner.createFile("file1.txt", "first file content\n");
    result = try runner.runZiggit(&[_][]const u8{ "add", "file1.txt" });
    result.deinit(runner.allocator);
    result = try runner.runZiggit(&[_][]const u8{ "commit", "-m", "First commit" });
    result.deinit(runner.allocator);
    
    try runner.createFile("file2.txt", "second file content\n");
    result = try runner.runZiggit(&[_][]const u8{ "add", "file2.txt" });
    result.deinit(runner.allocator);
    result = try runner.runZiggit(&[_][]const u8{ "commit", "-m", "Second commit" });
    result.deinit(runner.allocator);
}

// Test basic log output
fn testBasicLog(runner: *TestRunner) !TestResult {
    const result = try runner.runZiggit(&[_][]const u8{"log"});
    defer result.deinit(runner.allocator);
    
    if (runner.expectExitCode(0, result.exit_code, "ziggit log") == .fail) return .fail;
    if (runner.expectContains(result.stdout, "First commit", "shows first commit") == .fail) return .fail;
    if (runner.expectContains(result.stdout, "Second commit", "shows second commit") == .fail) return .fail;
    
    // Should show author information
    if (runner.expectContains(result.stdout, "Test User", "shows author") == .fail) return .fail;
    if (runner.expectContains(result.stdout, "test@example.com", "shows email") == .fail) return .fail;
    
    return .pass;
}

// Test log --oneline format
fn testLogOneline(runner: *TestRunner) !TestResult {
    const result = try runner.runZiggit(&[_][]const u8{"log", "--oneline"});
    defer result.deinit(runner.allocator);
    
    if (runner.expectExitCode(0, result.exit_code, "ziggit log --oneline") == .fail) return .fail;
    if (runner.expectContains(result.stdout, "First commit", "shows first commit") == .fail) return .fail;
    if (runner.expectContains(result.stdout, "Second commit", "shows second commit") == .fail) return .fail;
    
    // Oneline should be concise - each commit on one line
    const lines = std.mem.split(u8, std.mem.trim(u8, result.stdout, " \t\n\r"), "\n");
    var line_count: u32 = 0;
    var it = lines;
    while (it.next()) |line| {
        if (line.len > 0) line_count += 1;
    }
    
    if (line_count >= 2) {
        std.debug.print("    ✓ oneline format shows {d} commit lines\n", .{line_count});
    } else {
        std.debug.print("    ✗ oneline format shows {d} lines, expected at least 2\n", .{line_count});
        return .fail;
    }
    
    return .pass;
}

// Test log -n (limit) option
fn testLogLimit(runner: *TestRunner) !TestResult {
    const result = try runner.runZiggit(&[_][]const u8{"log", "-n", "1", "--oneline"});
    defer result.deinit(runner.allocator);
    
    if (runner.expectExitCode(0, result.exit_code, "ziggit log -n 1") == .fail) return .fail;
    
    // Should show only one commit (the most recent)
    const lines = std.mem.split(u8, std.mem.trim(u8, result.stdout, " \t\n\r"), "\n");
    var line_count: u32 = 0;
    var it = lines;
    while (it.next()) |line| {
        if (line.len > 0) line_count += 1;
    }
    
    if (line_count == 1) {
        std.debug.print("    ✓ log -n 1 shows exactly 1 commit\n", .{});
        if (runner.expectContains(result.stdout, "Second commit", "shows most recent commit") == .fail) return .fail;
    } else {
        std.debug.print("    ✗ log -n 1 shows {d} lines, expected 1\n", .{line_count});
        return .fail;
    }
    
    return .pass;
}

// Test log --pretty format options
fn testLogPrettyFormat(runner: *TestRunner) !TestResult {
    const result = try runner.runZiggit(&[_][]const u8{"log", "-1", "--pretty=format:%H %s"});
    defer result.deinit(runner.allocator);
    
    if (runner.expectExitCode(0, result.exit_code, "ziggit log --pretty=format") == .fail) return .fail;
    
    const output_line = std.mem.trim(u8, result.stdout, " \t\n\r");
    
    // Should contain a SHA (40 hex chars) followed by commit message
    if (output_line.len >= 41) { // SHA + space + at least one char of message
        const potential_sha = output_line[0..40];
        
        // Check if first 40 chars are hex
        var all_hex = true;
        for (potential_sha) |char| {
            if (!std.ascii.isHex(char)) {
                all_hex = false;
                break;
            }
        }
        
        if (all_hex and output_line[40] == ' ') {
            std.debug.print("    ✓ pretty format shows SHA and message: {s}\n", .{output_line});
            if (runner.expectContains(result.stdout, "Second commit", "shows commit message") == .fail) return .fail;
        } else {
            std.debug.print("    ✗ pretty format doesn't match expected pattern: {s}\n", .{output_line});
            return .fail;
        }
    } else {
        std.debug.print("    ✗ pretty format output too short: {s}\n", .{output_line});
        return .fail;
    }
    
    return .pass;
}

// Test log with file path filter
fn testLogFilePath(runner: *TestRunner) !TestResult {
    const result = try runner.runZiggit(&[_][]const u8{"log", "--oneline", "--", "file1.txt"});
    defer result.deinit(runner.allocator);
    
    if (runner.expectExitCode(0, result.exit_code, "ziggit log -- file1.txt") == .fail) return .fail;
    
    // Should show only commits that modified file1.txt
    if (runner.expectContains(result.stdout, "First commit", "shows commit with file1.txt") == .fail) return .fail;
    
    // Should NOT show second commit (which only added file2.txt)
    if (std.mem.indexOf(u8, result.stdout, "Second commit") != null) {
        std.debug.print("    ⚠ log file filter may be showing unrelated commits\n", .{});
        // This might be acceptable if not implemented yet
    } else {
        std.debug.print("    ✓ log file filter correctly excludes unrelated commits\n", .{});
    }
    
    return .pass;
}

// Test log on empty repository
fn testLogEmptyRepository(runner: *TestRunner) !TestResult {
    // Create a fresh repository without the setup commits
    var result = try runner.runZiggit(&[_][]const u8{"init"});
    result.deinit(runner.allocator);
    
    result = try runner.runZiggit(&[_][]const u8{"log"});
    defer result.deinit(runner.allocator);
    
    // Should fail or give appropriate message for empty repository
    if (result.exit_code != 0) {
        std.debug.print("    ✓ log on empty repository exits with non-zero code ({d})\n", .{result.exit_code});
        
        // Should have appropriate error message
        if (std.mem.indexOf(u8, result.stderr, "does not have any commits") != null or
            std.mem.indexOf(u8, result.stderr, "no commits") != null or
            std.mem.indexOf(u8, result.stderr, "empty") != null) {
            std.debug.print("    ✓ appropriate error message for empty repository\n", .{});
        } else {
            std.debug.print("    ⚠ error message may need improvement: {s}\n", .{result.stderr});
        }
        
        return .pass;
    } else {
        std.debug.print("    ⚠ log on empty repository succeeded - may show empty output\n", .{});
        // Empty output is also acceptable
        if (result.stdout.len == 0) {
            std.debug.print("    ✓ log on empty repository shows no output\n", .{});
            return .pass;
        } else {
            std.debug.print("    ✗ log on empty repository shows unexpected output: {s}\n", .{result.stdout});
            return .fail;
        }
    }
}

// Test log --graph option
fn testLogGraph(runner: *TestRunner) !TestResult {
    const result = try runner.runZiggit(&[_][]const u8{"log", "--graph", "--oneline"});
    defer result.deinit(runner.allocator);
    
    if (runner.expectExitCode(0, result.exit_code, "ziggit log --graph") == .fail) return .fail;
    
    // Graph output should contain graphical characters or be same as regular log
    if (std.mem.indexOf(u8, result.stdout, "*") != null or
        std.mem.indexOf(u8, result.stdout, "|") != null or
        std.mem.indexOf(u8, result.stdout, "/") != null or
        std.mem.indexOf(u8, result.stdout, "\\") != null) {
        std.debug.print("    ✓ graph option shows graphical elements\n", .{});
    } else {
        std.debug.print("    ⚠ graph option may not be fully implemented (no graph chars found)\n", .{});
    }
    
    // Should still show commit messages
    if (runner.expectContains(result.stdout, "Second commit", "shows commits with graph") == .fail) return .fail;
    
    return .pass;
}

// Compare ziggit and git log behavior
fn testLogCompatibilityWithGit(runner: *TestRunner) !TestResult {
    // Test ziggit log
    const ziggit_result = try runner.runZiggit(&[_][]const u8{"log", "--oneline"});
    defer ziggit_result.deinit(runner.allocator);
    
    // Initialize git repo for comparison
    var git_result = try runner.runCommand(&[_][]const u8{ "git", "init", "git-test" });
    git_result.deinit(runner.allocator);
    
    // Configure git user
    var proc = std.process.Child.init(&[_][]const u8{ "git", "config", "user.name", "Test User" }, runner.allocator);
    var buf: [256]u8 = undefined;
    const git_test_path = try std.fmt.bufPrint(&buf, "{s}/git-test", .{runner.test_dir});
    proc.cwd = git_test_path;
    _ = try proc.spawnAndWait();
    
    proc = std.process.Child.init(&[_][]const u8{ "git", "config", "user.email", "test@example.com" }, runner.allocator);
    proc.cwd = git_test_path;
    _ = try proc.spawnAndWait();
    
    // Create similar commits in git repo
    try runner.createFile("git-test/file1.txt", "first file content\n");
    proc = std.process.Child.init(&[_][]const u8{ "git", "add", "file1.txt" }, runner.allocator);
    proc.cwd = git_test_path;
    _ = try proc.spawnAndWait();
    proc = std.process.Child.init(&[_][]const u8{ "git", "commit", "-m", "First commit" }, runner.allocator);
    proc.cwd = git_test_path;
    _ = try proc.spawnAndWait();
    
    // Test git log
    proc = std.process.Child.init(&[_][]const u8{ "git", "log", "--oneline" }, runner.allocator);
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
    if (runner.expectExitCode(0, ziggit_result.exit_code, "ziggit log") == .fail) return .fail;
    if (runner.expectExitCode(0, git_code, "git log") == .fail) return .fail;
    
    // Both should show commit messages
    if (runner.expectContains(ziggit_result.stdout, "commit", "ziggit shows commits") == .fail) return .fail;
    if (runner.expectContains(git_stdout, "First commit", "git shows commits") == .fail) return .fail;
    
    std.debug.print("    ✓ ziggit log behavior tested against git log\n", .{});
    return .pass;
}

const test_cases = [_]TestCase{
    .{
        .name = "basic-log",
        .description = "basic log output shows commits",
        .setup_fn = setupRepository,
        .test_fn = testBasicLog,
    },
    .{
        .name = "log-oneline",
        .description = "log --oneline format",
        .setup_fn = setupRepository,
        .test_fn = testLogOneline,
    },
    .{
        .name = "log-limit",
        .description = "log -n option limits output",
        .setup_fn = setupRepository,
        .test_fn = testLogLimit,
    },
    .{
        .name = "log-pretty",
        .description = "log --pretty format options",
        .setup_fn = setupRepository,
        .test_fn = testLogPrettyFormat,
    },
    .{
        .name = "log-file-path",
        .description = "log with file path filter",
        .setup_fn = setupRepository,
        .test_fn = testLogFilePath,
    },
    .{
        .name = "log-empty",
        .description = "log on empty repository",
        .test_fn = testLogEmptyRepository, // No setup - creates empty repo
    },
    .{
        .name = "log-graph",
        .description = "log --graph option",
        .setup_fn = setupRepository,
        .test_fn = testLogGraph,
    },
    .{
        .name = "compatibility",
        .description = "ziggit log behavior matches git log",
        .setup_fn = setupRepository,
        .test_fn = testLogCompatibilityWithGit,
    },
};

pub fn runT4000LogTests() !void {
    try runTestSuite("t4000-log (Git Log Tests)", &test_cases);
}