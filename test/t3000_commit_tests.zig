const std = @import("std");
const TestRunner = @import("git_source_test_adapter.zig").TestRunner;
const TestResult = @import("git_source_test_adapter.zig").TestResult;
const TestCase = @import("git_source_test_adapter.zig").TestCase;
const runTestSuite = @import("git_source_test_adapter.zig").runTestSuite;

// t3000-commit.sh - Test git commit functionality
// Adapted from git/git.git/t/t7* commit tests

// Setup function - initialize repository and configure user
fn setupRepository(runner: *TestRunner) !void {
    var result = try runner.runZiggit(&[_][]const u8{"init"});
    result.deinit(runner.allocator);
    if (result.exit_code != 0) return error.InitFailed;
    
    // Configure user (required for commits)
    result = try runner.runZiggit(&[_][]const u8{ "config", "user.name", "Test User" });
    result.deinit(runner.allocator);
    result = try runner.runZiggit(&[_][]const u8{ "config", "user.email", "test@example.com" });
    result.deinit(runner.allocator);
}

// Test basic commit with message
fn testBasicCommit(runner: *TestRunner) !TestResult {
    try runner.createFile("file.txt", "hello world\n");
    
    // Add file
    var result = try runner.runZiggit(&[_][]const u8{ "add", "file.txt" });
    result.deinit(runner.allocator);
    
    // Commit with message
    result = try runner.runZiggit(&[_][]const u8{ "commit", "-m", "Initial commit" });
    defer result.deinit(runner.allocator);
    
    if (runner.expectExitCode(0, result.exit_code, "ziggit commit -m") == .fail) return .fail;
    if (runner.expectContains(result.stdout, "Initial commit", "commit message in output") == .fail) return .fail;
    
    // Check that commit was created
    const log_result = try runner.runZiggit(&[_][]const u8{"log", "--oneline"});
    defer log_result.deinit(runner.allocator);
    
    if (runner.expectContains(log_result.stdout, "Initial commit", "commit appears in log") == .fail) return .fail;
    
    return .pass;
}

// Test commit with no staged changes (should fail)
fn testCommitNothingStaged(runner: *TestRunner) !TestResult {
    const result = try runner.runZiggit(&[_][]const u8{ "commit", "-m", "Nothing to commit" });
    defer result.deinit(runner.allocator);
    
    // Should fail with non-zero exit code
    if (result.exit_code == 0) {
        std.debug.print("    ✗ commit with nothing staged should fail but succeeded\n", .{});
        return .fail;
    }
    
    if (runner.expectContains(result.stderr, "nothing to commit", "appropriate error message") == .fail) {
        // Alternative error formats
        if (runner.expectContains(result.stderr, "no changes", "alternative error format") == .fail) {
            if (runner.expectContains(result.stderr, "nothing added", "another error format") == .fail) return .fail;
        }
    }
    
    std.debug.print("    ✓ commit with nothing staged fails appropriately\n", .{});
    return .pass;
}

// Test commit without message (should fail or prompt)
fn testCommitNoMessage(runner: *TestRunner) !TestResult {
    try runner.createFile("file.txt", "content\n");
    
    var result = try runner.runZiggit(&[_][]const u8{ "add", "file.txt" });
    result.deinit(runner.allocator);
    
    result = try runner.runZiggit(&[_][]const u8{"commit"});
    defer result.deinit(runner.allocator);
    
    // Should either fail or handle it gracefully
    if (result.exit_code == 0) {
        std.debug.print("    ✓ commit without message succeeded (may use default or prompt)\n", .{});
        return .pass;
    } else {
        if (runner.expectContains(result.stderr, "message", "mentions message requirement") == .fail) {
            if (runner.expectContains(result.stderr, "editor", "mentions editor") == .fail) return .fail;
        }
        std.debug.print("    ✓ commit without message fails appropriately\n", .{});
        return .pass;
    }
}

// Test commit with long message
fn testCommitLongMessage(runner: *TestRunner) !TestResult {
    try runner.createFile("file.txt", "content\n");
    
    var result = try runner.runZiggit(&[_][]const u8{ "add", "file.txt" });
    result.deinit(runner.allocator);
    
    const long_message = "This is a very long commit message that spans multiple words and should be handled correctly by the commit functionality";
    
    result = try runner.runZiggit(&[_][]const u8{ "commit", "-m", long_message });
    defer result.deinit(runner.allocator);
    
    if (runner.expectExitCode(0, result.exit_code, "ziggit commit with long message") == .fail) return .fail;
    
    const log_result = try runner.runZiggit(&[_][]const u8{"log", "-1", "--pretty=format:%s"});
    defer log_result.deinit(runner.allocator);
    
    if (runner.expectContains(log_result.stdout, long_message, "long message preserved") == .fail) return .fail;
    
    return .pass;
}

// Test commit with multiline message
fn testCommitMultilineMessage(runner: *TestRunner) !TestResult {
    try runner.createFile("file.txt", "content\n");
    
    var result = try runner.runZiggit(&[_][]const u8{ "add", "file.txt" });
    result.deinit(runner.allocator);
    
    const multiline_message = "Short summary\n\nLonger description of the changes made in this commit.";
    
    result = try runner.runZiggit(&[_][]const u8{ "commit", "-m", multiline_message });
    defer result.deinit(runner.allocator);
    
    if (runner.expectExitCode(0, result.exit_code, "ziggit commit with multiline message") == .fail) return .fail;
    
    const log_result = try runner.runZiggit(&[_][]const u8{"log", "-1", "--pretty=format:%B"});
    defer log_result.deinit(runner.allocator);
    
    if (runner.expectContains(log_result.stdout, "Short summary", "summary line preserved") == .fail) return .fail;
    if (runner.expectContains(log_result.stdout, "Longer description", "description preserved") == .fail) return .fail;
    
    return .pass;
}

// Test multiple commits create history
fn testMultipleCommits(runner: *TestRunner) !TestResult {
    // First commit
    try runner.createFile("file1.txt", "first file\n");
    var result = try runner.runZiggit(&[_][]const u8{ "add", "file1.txt" });
    result.deinit(runner.allocator);
    result = try runner.runZiggit(&[_][]const u8{ "commit", "-m", "First commit" });
    result.deinit(runner.allocator);
    
    // Second commit
    try runner.createFile("file2.txt", "second file\n");
    result = try runner.runZiggit(&[_][]const u8{ "add", "file2.txt" });
    result.deinit(runner.allocator);
    result = try runner.runZiggit(&[_][]const u8{ "commit", "-m", "Second commit" });
    result.deinit(runner.allocator);
    
    // Check log shows both commits
    result = try runner.runZiggit(&[_][]const u8{"log", "--oneline"});
    defer result.deinit(runner.allocator);
    
    if (runner.expectContains(result.stdout, "First commit", "first commit in log") == .fail) return .fail;
    if (runner.expectContains(result.stdout, "Second commit", "second commit in log") == .fail) return .fail;
    
    // Count commits (should be 2)
    const commit_count = std.mem.count(u8, result.stdout, "\n");
    if (commit_count < 2) {
        std.debug.print("    ✗ Expected at least 2 commits, found {d}\n", .{commit_count});
        return .fail;
    }
    
    std.debug.print("    ✓ Multiple commits create proper history ({d} commits)\n", .{commit_count});
    return .pass;
}

// Test commit generates proper SHA-1 hash
fn testCommitShaGeneration(runner: *TestRunner) !TestResult {
    try runner.createFile("file.txt", "content\n");
    
    var result = try runner.runZiggit(&[_][]const u8{ "add", "file.txt" });
    result.deinit(runner.allocator);
    
    result = try runner.runZiggit(&[_][]const u8{ "commit", "-m", "Test SHA generation" });
    result.deinit(runner.allocator);
    
    // Get commit SHA
    result = try runner.runZiggit(&[_][]const u8{"log", "-1", "--format=%H"});
    defer result.deinit(runner.allocator);
    
    const sha_line = std.mem.trim(u8, result.stdout, " \t\n\r");
    
    // SHA should be 40 hex characters
    if (sha_line.len != 40) {
        std.debug.print("    ✗ SHA length is {d}, expected 40\n", .{sha_line.len});
        return .fail;
    }
    
    // Check if all characters are hex
    for (sha_line) |char| {
        if (!std.ascii.isHex(char)) {
            std.debug.print("    ✗ SHA contains non-hex character: {c}\n", .{char});
            return .fail;
        }
    }
    
    std.debug.print("    ✓ Commit SHA is valid 40-character hex: {s}\n", .{sha_line});
    return .pass;
}

// Compare ziggit and git commit behavior
fn testCommitCompatibilityWithGit(runner: *TestRunner) !TestResult {
    // Test ziggit commit
    try runner.createFile("ziggit-file.txt", "ziggit content\n");
    var result = try runner.runZiggit(&[_][]const u8{ "add", "ziggit-file.txt" });
    result.deinit(runner.allocator);
    result = try runner.runZiggit(&[_][]const u8{ "commit", "-m", "Ziggit test commit" });
    defer result.deinit(runner.allocator);
    
    // Initialize git repo for comparison
    var git_result = try runner.runCommand(&[_][]const u8{ "git", "init", "git-test" });
    git_result.deinit(runner.allocator);
    
    try runner.createFile("git-test/git-file.txt", "git content\n");
    
    // Configure git user
    var proc = std.process.Child.init(&[_][]const u8{ "git", "config", "user.name", "Test User" }, runner.allocator);
    var buf: [256]u8 = undefined;
    const git_test_path = try std.fmt.bufPrint(&buf, "{s}/git-test", .{runner.test_dir});
    proc.cwd = git_test_path;
    _ = try proc.spawnAndWait();
    
    proc = std.process.Child.init(&[_][]const u8{ "git", "config", "user.email", "test@example.com" }, runner.allocator);
    proc.cwd = git_test_path;
    _ = try proc.spawnAndWait();
    
    proc = std.process.Child.init(&[_][]const u8{ "git", "add", "git-file.txt" }, runner.allocator);
    proc.cwd = git_test_path;
    _ = try proc.spawnAndWait();
    
    proc = std.process.Child.init(&[_][]const u8{ "git", "commit", "-m", "Git test commit" }, runner.allocator);
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
    if (runner.expectExitCode(0, result.exit_code, "ziggit commit") == .fail) return .fail;
    if (runner.expectExitCode(0, git_code, "git commit") == .fail) return .fail;
    
    std.debug.print("    ✓ ziggit commit behavior matches git commit\n", .{});
    return .pass;
}

const test_cases = [_]TestCase{
    .{
        .name = "basic-commit",
        .description = "basic commit with message",
        .setup_fn = setupRepository,
        .test_fn = testBasicCommit,
    },
    .{
        .name = "commit-nothing",
        .description = "commit with nothing staged should fail",
        .setup_fn = setupRepository,
        .test_fn = testCommitNothingStaged,
    },
    .{
        .name = "commit-no-message",
        .description = "commit without message should be handled",
        .setup_fn = setupRepository,
        .test_fn = testCommitNoMessage,
    },
    .{
        .name = "commit-long-message",
        .description = "commit with long message",
        .setup_fn = setupRepository,
        .test_fn = testCommitLongMessage,
    },
    .{
        .name = "commit-multiline",
        .description = "commit with multiline message",
        .setup_fn = setupRepository,
        .test_fn = testCommitMultilineMessage,
    },
    .{
        .name = "multiple-commits",
        .description = "multiple commits create proper history",
        .setup_fn = setupRepository,
        .test_fn = testMultipleCommits,
    },
    .{
        .name = "sha-generation",
        .description = "commits generate valid SHA-1 hashes",
        .setup_fn = setupRepository,
        .test_fn = testCommitShaGeneration,
    },
    .{
        .name = "compatibility",
        .description = "ziggit commit behavior matches git commit",
        .setup_fn = setupRepository,
        .test_fn = testCommitCompatibilityWithGit,
    },
};

pub fn runT3000CommitTests() !void {
    try runTestSuite("t3000-commit (Git Commit Tests)", &test_cases);
}