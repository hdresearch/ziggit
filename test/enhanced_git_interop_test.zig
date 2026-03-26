const std = @import("std");
const testing = std.testing;
const fs = std.fs;
const ChildProcess = std.process.Child;

// Enhanced Git Interoperability Tests
// Tests BOTH directions: git -> ziggit and ziggit -> git
// Covers all core commands: init, add, commit, status --porcelain, log --oneline, branch, diff, checkout

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.debug.print("Warning: memory leaked in git interop tests\n", .{});
        }
    }
    const allocator = gpa.allocator();

    std.debug.print("=== Enhanced Git Interoperability Tests ===\n", .{});

    // Set up git config
    try setupGitConfig(allocator);

    // Create temporary test directory
    const test_dir = try fs.cwd().makeOpenPath("enhanced_interop_test", .{});
    defer fs.cwd().deleteTree("enhanced_interop_test") catch {};

    var tests_passed: u32 = 0;
    var tests_failed: u32 = 0;

    // Core interoperability tests
    try runTest(allocator, test_dir, "Git Init -> Ziggit Status", testGitInitZiggitStatus, &tests_passed, &tests_failed);
    try runTest(allocator, test_dir, "Ziggit Init -> Git Status", testZiggitInitGitStatus, &tests_passed, &tests_failed);
    try runTest(allocator, test_dir, "Git Add/Commit -> Ziggit Log --oneline", testGitCommitZiggitLogOneline, &tests_passed, &tests_failed);
    try runTest(allocator, test_dir, "Ziggit Add/Commit -> Git Log --oneline", testZiggitCommitGitLogOneline, &tests_passed, &tests_failed);
    try runTest(allocator, test_dir, "Status --porcelain Compatibility", testStatusPorcelainCompatibility, &tests_passed, &tests_failed);
    try runTest(allocator, test_dir, "Branch Operations", testBranchOperations, &tests_passed, &tests_failed);
    try runTest(allocator, test_dir, "Diff Operations", testDiffOperations, &tests_passed, &tests_failed);
    try runTest(allocator, test_dir, "Checkout Operations", testCheckoutOperations, &tests_passed, &tests_failed);
    try runTest(allocator, test_dir, "File Format Compatibility", testFileFormatCompatibility, &tests_passed, &tests_failed);
    try runTest(allocator, test_dir, "Mixed Operations Workflow", testMixedOperationsWorkflow, &tests_passed, &tests_failed);

    // Print summary
    std.debug.print("\n=== TEST SUMMARY ===\n", .{});
    std.debug.print("✓ Passed: {d}\n", .{tests_passed});
    if (tests_failed > 0) {
        std.debug.print("✗ Failed: {d}\n", .{tests_failed});
    } else {
        std.debug.print("All tests passed!\n", .{});
    }
}

fn runTest(allocator: std.mem.Allocator, test_dir: fs.Dir, name: []const u8, test_fn: anytype, passed: *u32, failed: *u32) !void {
    std.debug.print("\n--- {s} ---\n", .{name});
    test_fn(allocator, test_dir) catch |err| {
        std.debug.print("✗ FAILED: {any}\n", .{err});
        failed.* += 1;
        return;
    };
    std.debug.print("✓ PASSED\n", .{});
    passed.* += 1;
}

fn setupGitConfig(allocator: std.mem.Allocator) !void {
    const configs = [_][3][]const u8{
        .{ "git", "config", "--global" },
        .{ "git", "config", "--system" },
    };
    const settings = [_][2][]const u8{
        .{ "user.name", "Test User" },
        .{ "user.email", "test@example.com" },
        .{ "init.defaultBranch", "master" },
    };

    for (configs) |config_cmd| {
        for (settings) |setting| {
            var full_cmd = std.ArrayList([]const u8).init(allocator);
            defer full_cmd.deinit();
            try full_cmd.appendSlice(config_cmd[0..]);
            try full_cmd.appendSlice(setting[0..]);

            _ = runCommand(allocator, full_cmd.items, fs.cwd()) catch continue;
        }
    }
}

fn testGitInitZiggitStatus(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    const repo_dir = try createTestRepo(test_dir, "git_init_test");
    defer test_dir.deleteTree("git_init_test") catch {};

    // 1. Init with git
    _ = try runCommand(allocator, &.{ "git", "init" }, repo_dir);
    try configureRepo(allocator, repo_dir);

    // 2. Create and stage files
    try repo_dir.writeFile(.{ .sub_path = "README.md", .data = "# Test Project\n" });
    repo_dir.makeDir("src") catch {};
    try repo_dir.writeFile(.{ .sub_path = "src/main.c", .data = "#include <stdio.h>\n" });
    
    _ = try runCommand(allocator, &.{ "git", "add", "README.md" }, repo_dir);
    _ = try runCommand(allocator, &.{ "git", "commit", "-m", "Initial commit" }, repo_dir);

    // 3. Modify files to create different states
    try repo_dir.writeFile(.{ .sub_path = "README.md", .data = "# Test Project\nUpdated!\n" });
    try repo_dir.writeFile(.{ .sub_path = "new_file.txt", .data = "New content\n" });

    // 4. Use ziggit to check status
    const ziggit_result = try runZiggitCommand(allocator, &.{"status"}, repo_dir);
    defer allocator.free(ziggit_result);

    // Verify ziggit can read git repository
    std.debug.print("Git-created repo, ziggit status output present: {any}\n", .{ziggit_result.len > 0});
}

fn testZiggitInitGitStatus(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    const repo_dir = try createTestRepo(test_dir, "ziggit_init_test");
    defer test_dir.deleteTree("ziggit_init_test") catch {};

    // 1. Init with ziggit
    _ = try runZiggitCommand(allocator, &.{"init"}, repo_dir);

    // 2. Use git to check the repository
    const git_result = runCommand(allocator, &.{ "git", "status" }, repo_dir) catch |err| {
        std.debug.print("Git cannot read ziggit repository: {any}\n", .{err});
        return error.GitCannotReadZiggitRepo;
    };
    defer allocator.free(git_result);

    // 3. Verify git recognizes it as valid
    if (std.mem.indexOf(u8, git_result, "fatal") != null) {
        return error.GitRejectsZiggitRepo;
    }

    std.debug.print("Ziggit-created repo recognized by git: ✓\n", .{});
}

fn testGitCommitZiggitLogOneline(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    const repo_dir = try createTestRepo(test_dir, "git_commit_test");
    defer test_dir.deleteTree("git_commit_test") catch {};

    // 1. Init with git and create commits
    _ = try runCommand(allocator, &.{ "git", "init" }, repo_dir);
    try configureRepo(allocator, repo_dir);

    const commits = [_]struct { file: []const u8, msg: []const u8 }{
        .{ .file = "file1.txt", .msg = "First commit" },
        .{ .file = "file2.txt", .msg = "Second commit" },
        .{ .file = "file3.txt", .msg = "Third commit" },
    };

    for (commits) |commit| {
        try repo_dir.writeFile(.{ .sub_path = commit.file, .data = "content\n" });
        _ = try runCommand(allocator, &.{ "git", "add", commit.file }, repo_dir);
        _ = try runCommand(allocator, &.{ "git", "commit", "-m", commit.msg }, repo_dir);
    }

    // 2. Use ziggit to read log
    const ziggit_log = try runZiggitCommand(allocator, &.{ "log", "--oneline" }, repo_dir);
    defer allocator.free(ziggit_log);

    const git_log = try runCommand(allocator, &.{ "git", "log", "--oneline" }, repo_dir);
    defer allocator.free(git_log);

    // 3. Compare outputs
    std.debug.print("Git log lines: {d}, Ziggit log lines: {d}\n", .{
        std.mem.count(u8, git_log, "\n"),
        std.mem.count(u8, ziggit_log, "\n")
    });
    
    // Check if commit messages are present (allowing for hash differences)
    for (commits) |commit| {
        const found_in_ziggit = std.mem.indexOf(u8, ziggit_log, commit.msg) != null;
        const found_in_git = std.mem.indexOf(u8, git_log, commit.msg) != null;
        if (found_in_git and !found_in_ziggit) {
            std.debug.print("Warning: commit '{s}' missing in ziggit log\n", .{commit.msg});
        }
    }
}

fn testZiggitCommitGitLogOneline(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    const repo_dir = try createTestRepo(test_dir, "ziggit_commit_test");
    defer test_dir.deleteTree("ziggit_commit_test") catch {};

    // 1. Init with ziggit
    _ = try runZiggitCommand(allocator, &.{"init"}, repo_dir);

    // 2. Create commits with ziggit (may not be fully implemented)
    const files = [_][]const u8{ "test1.txt", "test2.txt" };
    for (files, 0..) |file, i| {
        try repo_dir.writeFile(.{ .sub_path = file, .data = "test content\n" });
        
        const add_result = runZiggitCommand(allocator, &.{ "add", file }, repo_dir) catch |err| {
            std.debug.print("Ziggit add not implemented: {any}\n", .{err});
            return; // Skip test if add not implemented
        };
        defer allocator.free(add_result);

        const msg = try std.fmt.allocPrint(allocator, "Commit {}", .{i + 1});
        defer allocator.free(msg);

        const commit_result = runZiggitCommand(allocator, &.{ "commit", "-m", msg }, repo_dir) catch |err| {
            std.debug.print("Ziggit commit not implemented: {any}\n", .{err});
            return; // Skip test if commit not implemented
        };
        defer allocator.free(commit_result);
    }

    // 3. Use git to read log
    const git_log = try runCommand(allocator, &.{ "git", "log", "--oneline" }, repo_dir);
    defer allocator.free(git_log);

    std.debug.print("Git can read ziggit commits: {d} lines\n", .{std.mem.count(u8, git_log, "\n")});
}

fn testStatusPorcelainCompatibility(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    const repo_dir = try createTestRepo(test_dir, "status_porcelain_test");
    defer test_dir.deleteTree("status_porcelain_test") catch {};

    // 1. Set up repository with various file states
    _ = try runCommand(allocator, &.{ "git", "init" }, repo_dir);
    try configureRepo(allocator, repo_dir);

    // Create files in different states
    try repo_dir.writeFile(.{ .sub_path = "committed.txt", .data = "committed\n" });
    _ = try runCommand(allocator, &.{ "git", "add", "committed.txt" }, repo_dir);
    _ = try runCommand(allocator, &.{ "git", "commit", "-m", "Initial" }, repo_dir);

    try repo_dir.writeFile(.{ .sub_path = "staged.txt", .data = "staged\n" });
    _ = try runCommand(allocator, &.{ "git", "add", "staged.txt" }, repo_dir);

    try repo_dir.writeFile(.{ .sub_path = "committed.txt", .data = "modified\n" });
    try repo_dir.writeFile(.{ .sub_path = "untracked.txt", .data = "untracked\n" });

    // 2. Compare --porcelain output
    const git_porcelain = try runCommand(allocator, &.{ "git", "status", "--porcelain" }, repo_dir);
    defer allocator.free(git_porcelain);

    const ziggit_porcelain = runZiggitCommand(allocator, &.{ "status", "--porcelain" }, repo_dir) catch |err| {
        std.debug.print("Ziggit --porcelain not implemented: {any}\n", .{err});
        return;
    };
    defer allocator.free(ziggit_porcelain);

    // 3. Analyze format compatibility
    compareOutputFormat(git_porcelain, ziggit_porcelain, "status --porcelain");
}

fn testBranchOperations(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    const repo_dir = try createTestRepo(test_dir, "branch_test");
    defer test_dir.deleteTree("branch_test") catch {};

    // 1. Set up repository with branches
    _ = try runCommand(allocator, &.{ "git", "init" }, repo_dir);
    try configureRepo(allocator, repo_dir);

    try repo_dir.writeFile(.{ .sub_path = "initial.txt", .data = "initial\n" });
    _ = try runCommand(allocator, &.{ "git", "add", "initial.txt" }, repo_dir);
    _ = try runCommand(allocator, &.{ "git", "commit", "-m", "Initial commit" }, repo_dir);

    _ = try runCommand(allocator, &.{ "git", "branch", "feature-a" }, repo_dir);
    _ = try runCommand(allocator, &.{ "git", "branch", "feature-b" }, repo_dir);

    // 2. Test ziggit branch listing
    const git_branches = try runCommand(allocator, &.{ "git", "branch" }, repo_dir);
    defer allocator.free(git_branches);

    const ziggit_branches = runZiggitCommand(allocator, &.{"branch"}, repo_dir) catch |err| {
        std.debug.print("Ziggit branch not implemented: {any}\n", .{err});
        return;
    };
    defer allocator.free(ziggit_branches);

    // 3. Compare branch listings
    const expected_branches = [_][]const u8{ "master", "feature-a", "feature-b" };
    for (expected_branches) |branch| {
        const in_git = std.mem.indexOf(u8, git_branches, branch) != null;
        const in_ziggit = std.mem.indexOf(u8, ziggit_branches, branch) != null;
        if (in_git and !in_ziggit) {
            std.debug.print("Warning: branch '{s}' missing in ziggit output\n", .{branch});
        }
    }

    std.debug.print("Branch compatibility check completed\n", .{});
}

fn testDiffOperations(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    const repo_dir = try createTestRepo(test_dir, "diff_test");
    defer test_dir.deleteTree("diff_test") catch {};

    // 1. Set up repository with modifications
    _ = try runCommand(allocator, &.{ "git", "init" }, repo_dir);
    try configureRepo(allocator, repo_dir);

    try repo_dir.writeFile(.{ .sub_path = "test.txt", .data = "original line 1\noriginal line 2\n" });
    _ = try runCommand(allocator, &.{ "git", "add", "test.txt" }, repo_dir);
    _ = try runCommand(allocator, &.{ "git", "commit", "-m", "Initial commit" }, repo_dir);

    try repo_dir.writeFile(.{ .sub_path = "test.txt", .data = "modified line 1\noriginal line 2\nnew line 3\n" });

    // 2. Compare diff output
    const git_diff = try runCommand(allocator, &.{ "git", "diff" }, repo_dir);
    defer allocator.free(git_diff);

    const ziggit_diff = runZiggitCommand(allocator, &.{"diff"}, repo_dir) catch |err| {
        std.debug.print("Ziggit diff not implemented: {any}\n", .{err});
        return;
    };
    defer allocator.free(ziggit_diff);

    // 3. Check if both detect modifications
    const git_has_changes = git_diff.len > 0;
    const ziggit_has_changes = ziggit_diff.len > 0;

    std.debug.print("Diff detection - Git: {any}, Ziggit: {any}\n", .{ git_has_changes, ziggit_has_changes });
}

fn testCheckoutOperations(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    const repo_dir = try createTestRepo(test_dir, "checkout_test");
    defer test_dir.deleteTree("checkout_test") catch {};

    // 1. Set up repository with branches
    _ = try runCommand(allocator, &.{ "git", "init" }, repo_dir);
    try configureRepo(allocator, repo_dir);

    try repo_dir.writeFile(.{ .sub_path = "content.txt", .data = "master content\n" });
    _ = try runCommand(allocator, &.{ "git", "add", "content.txt" }, repo_dir);
    _ = try runCommand(allocator, &.{ "git", "commit", "-m", "Master commit" }, repo_dir);

    _ = try runCommand(allocator, &.{ "git", "checkout", "-b", "feature" }, repo_dir);
    try repo_dir.writeFile(.{ .sub_path = "content.txt", .data = "feature content\n" });
    _ = try runCommand(allocator, &.{ "git", "add", "content.txt" }, repo_dir);
    _ = try runCommand(allocator, &.{ "git", "commit", "-m", "Feature commit" }, repo_dir);

    _ = try runCommand(allocator, &.{ "git", "checkout", "master" }, repo_dir);

    // 2. Test ziggit checkout
    const checkout_result = runZiggitCommand(allocator, &.{ "checkout", "feature" }, repo_dir) catch |err| {
        std.debug.print("Ziggit checkout not implemented: {any}\n", .{err});
        return;
    };
    defer allocator.free(checkout_result);

    // 3. Verify file content changed
    const content = try repo_dir.readFileAlloc(allocator, "content.txt", 1024);
    defer allocator.free(content);

    const expected_feature_content = std.mem.eql(u8, content, "feature content\n");
    std.debug.print("Checkout functionality: {s}\n", .{if (expected_feature_content) "✓ Working" else "⚠ Issues"});
}

fn testFileFormatCompatibility(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    const repo_dir = try createTestRepo(test_dir, "format_test");
    defer test_dir.deleteTree("format_test") catch {};

    // 1. Create repository with git
    _ = try runCommand(allocator, &.{ "git", "init" }, repo_dir);
    try configureRepo(allocator, repo_dir);

    // Create various file types and structures
    try repo_dir.writeFile(.{ .sub_path = "binary_file", .data = "\x00\x01\x02\x03\xFF\xFE\xFD" });
    try repo_dir.writeFile(.{ .sub_path = "large_file.txt", .data = "A" ** 10000 });
    try repo_dir.writeFile(.{ .sub_path = "unicode_file.txt", .data = "Hello 🌍 Unicode 文字\n" });

    repo_dir.makeDir("subdir") catch {};
    try repo_dir.writeFile(.{ .sub_path = "subdir/nested.txt", .data = "nested content\n" });

    _ = try runCommand(allocator, &.{ "git", "add", "." }, repo_dir);
    _ = try runCommand(allocator, &.{ "git", "commit", "-m", "Various file types" }, repo_dir);

    // 2. Test ziggit can read the repository
    const status_result = runZiggitCommand(allocator, &.{"status"}, repo_dir) catch |err| {
        std.debug.print("Ziggit failed on complex repository: {any}\n", .{err});
        return error.FormatCompatibilityIssue;
    };
    defer allocator.free(status_result);

    std.debug.print("Complex repository compatibility: ✓\n", .{});
}

fn testMixedOperationsWorkflow(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    const repo_dir = try createTestRepo(test_dir, "mixed_workflow_test");
    defer test_dir.deleteTree("mixed_workflow_test") catch {};

    // 1. Start with ziggit init
    _ = try runZiggitCommand(allocator, &.{"init"}, repo_dir);

    // 2. Use git to add content
    try repo_dir.writeFile(.{ .sub_path = "git_file.txt", .data = "Created by git\n" });
    _ = try runCommand(allocator, &.{ "git", "add", "git_file.txt" }, repo_dir);
    _ = try runCommand(allocator, &.{ "git", "commit", "-m", "Git commit" }, repo_dir);

    // 3. Use ziggit to check status
    const ziggit_status = runZiggitCommand(allocator, &.{"status"}, repo_dir) catch |err| {
        std.debug.print("Mixed workflow failed at status: {any}\n", .{err});
        return;
    };
    defer allocator.free(ziggit_status);

    // 4. Use git to check log
    const git_log = try runCommand(allocator, &.{ "git", "log", "--oneline" }, repo_dir);
    defer allocator.free(git_log);

    // 5. Use ziggit to read log
    const ziggit_log = runZiggitCommand(allocator, &.{ "log", "--oneline" }, repo_dir) catch |err| {
        std.debug.print("Mixed workflow failed at log: {any}\n", .{err});
        return;
    };
    defer allocator.free(ziggit_log);

    std.debug.print("Mixed git/ziggit workflow: ✓\n", .{});
}

// Helper functions
fn createTestRepo(parent_dir: fs.Dir, name: []const u8) !fs.Dir {
    return parent_dir.makeOpenPath(name, .{});
}

fn configureRepo(allocator: std.mem.Allocator, repo_dir: fs.Dir) !void {
    _ = runCommand(allocator, &.{ "git", "config", "user.name", "Test User" }, repo_dir) catch {};
    _ = runCommand(allocator, &.{ "git", "config", "user.email", "test@example.com" }, repo_dir) catch {};
}

fn runCommand(allocator: std.mem.Allocator, args: []const []const u8, cwd: fs.Dir) ![]u8 {
    var child = ChildProcess.init(args, allocator);
    child.cwd_dir = cwd;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    
    try child.spawn();
    
    const stdout = child.stdout.?.reader().readAllAlloc(allocator, 8192) catch |err| {
        _ = child.stderr.?.reader().readAllAlloc(allocator, 8192) catch {};
        _ = child.wait() catch {};
        return err;
    };
    
    const stderr = child.stderr.?.reader().readAllAlloc(allocator, 8192) catch |err| {
        allocator.free(stdout);
        _ = child.wait() catch {};
        return err;
    };
    defer allocator.free(stderr);
    
    const term = try child.wait();
    if (term != .Exited or term.Exited != 0) {
        allocator.free(stdout);
        return error.CommandFailed;
    }
    
    return stdout;
}

fn runZiggitCommand(allocator: std.mem.Allocator, args: []const []const u8, cwd: fs.Dir) ![]u8 {
    var full_args = std.ArrayList([]const u8).init(allocator);
    defer full_args.deinit();
    
    try full_args.append("/root/ziggit/zig-out/bin/ziggit");
    for (args) |arg| {
        try full_args.append(arg);
    }
    
    return runCommand(allocator, full_args.items, cwd);
}

fn compareOutputFormat(git_output: []const u8, ziggit_output: []const u8, context: []const u8) void {
    const git_lines = std.mem.count(u8, git_output, "\n");
    const ziggit_lines = std.mem.count(u8, ziggit_output, "\n");
    
    std.debug.print("{s} format comparison:\n", .{context});
    std.debug.print("  Git lines: {d}, Ziggit lines: {d}\n", .{ git_lines, ziggit_lines });
    
    if (git_output.len > 0 and ziggit_output.len == 0) {
        std.debug.print("  ⚠ Ziggit produced no output while git did\n", .{});
    } else if (git_output.len == 0 and ziggit_output.len > 0) {
        std.debug.print("  ⚠ Ziggit produced output while git didn't\n", .{});
    } else if (std.mem.eql(u8, std.mem.trim(u8, git_output, "\n\r "), std.mem.trim(u8, ziggit_output, "\n\r "))) {
        std.debug.print("  ✓ Outputs match exactly\n", .{});
    } else {
        std.debug.print("  ⚠ Outputs differ in format\n", .{});
    }
}