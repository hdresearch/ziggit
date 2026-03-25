const std = @import("std");
const fs = std.fs;
const process = std.process;

// Git error message compatibility tests
// Focused on matching git's exact error message formats and exit codes

const TestFramework = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) TestFramework {
        return TestFramework{ .allocator = allocator };
    }
    
    fn runCommand(self: *TestFramework, args: []const []const u8, cwd: ?[]const u8) !struct { 
        exit_code: u32, 
        stdout: []u8, 
        stderr: []u8 
    } {
        var proc = process.Child.init(args, self.allocator);
        proc.stdout_behavior = .Pipe;
        proc.stderr_behavior = .Pipe;
        
        if (cwd) |dir| {
            proc.cwd = dir;
        }
        
        proc.spawn() catch |err| switch (err) {
            error.FileNotFound => {
                return .{
                    .exit_code = 127,
                    .stdout = try self.allocator.dupe(u8, ""),
                    .stderr = try self.allocator.dupe(u8, "command not found\n"),
                };
            },
            else => return err,
        };
        
        const stdout = try proc.stdout.?.readToEndAlloc(self.allocator, 1024 * 1024);
        const stderr = try proc.stderr.?.readToEndAlloc(self.allocator, 1024 * 1024);
        
        const result = try proc.wait();
        const exit_code = switch (result) {
            .Exited => |code| @as(u32, @intCast(code)),
            else => 1,
        };
        
        return .{
            .exit_code = exit_code,
            .stdout = stdout,
            .stderr = stderr,
        };
    }
    
    fn cleanupTestDir(_: *TestFramework, dir: []const u8) void {
        fs.cwd().deleteTree(dir) catch {};
    }
    
    fn createTestFile(_: *TestFramework, path: []const u8, content: []const u8) !void {
        const file = try fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(content);
    }
    
    const ErrorAnalysis = struct {
        has_fatal_prefix: bool,
        has_error_prefix: bool,
        has_warning_prefix: bool,
        ends_with_newline: bool,
        message_content: []const u8,
    };
    
    fn analyzeErrorMessage(_: *TestFramework, stderr: []const u8) ErrorAnalysis {
        var analysis = ErrorAnalysis{
            .has_fatal_prefix = false,
            .has_error_prefix = false,
            .has_warning_prefix = false,
            .ends_with_newline = false,
            .message_content = "",
        };
        
        if (stderr.len == 0) return analysis;
        
        analysis.has_fatal_prefix = std.mem.startsWith(u8, stderr, "fatal:");
        analysis.has_error_prefix = std.mem.startsWith(u8, stderr, "error:");
        analysis.has_warning_prefix = std.mem.startsWith(u8, stderr, "warning:");
        analysis.ends_with_newline = std.mem.endsWith(u8, stderr, "\n");
        analysis.message_content = std.mem.trim(u8, stderr, " \n\t");
        
        return analysis;
    }
};

pub fn runGitErrorMessageCompatTests() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var tf = TestFramework.init(allocator);
    
    std.debug.print("Running git error message compatibility tests...\n", .{});
    
    // Test "not a git repository" error
    try testNotAGitRepositoryError(&tf);
    
    // Test "file not found" error for add
    try testAddNonexistentFileError(&tf);
    
    // Test invalid command error
    try testInvalidCommandError(&tf);
    
    // Test commit with nothing to commit error
    try testNothingToCommitError(&tf);
    
    // Test checkout nonexistent branch error
    try testCheckoutNonexistentBranchError(&tf);
    
    // Test invalid flag errors
    try testInvalidFlagErrors(&tf);
    
    // Test pathspec errors
    try testPathspecErrors(&tf);
    
    std.debug.print("Git error message compatibility tests completed!\n", .{});
}

fn testNotAGitRepositoryError(tf: *TestFramework) !void {
    std.debug.print("  Testing 'not a git repository' error...\n", .{});
    
    // Create non-git directory
    tf.cleanupTestDir("test-not-repo");
    try fs.cwd().makeDir("test-not-repo");
    defer tf.cleanupTestDir("test-not-repo");
    
    // Test various commands that should fail with "not a git repository"
    const commands = [_][]const []const u8{
        &[_][]const u8{ "../zig-out/bin/ziggit", "status" },
        &[_][]const u8{ "../zig-out/bin/ziggit", "add", "." },
        &[_][]const u8{ "../zig-out/bin/ziggit", "commit", "-m", "test" },
        &[_][]const u8{ "../zig-out/bin/ziggit", "log" },
        &[_][]const u8{ "../zig-out/bin/ziggit", "diff" },
    };
    
    const git_commands = [_][]const []const u8{
        &[_][]const u8{ "git", "status" },
        &[_][]const u8{ "git", "add", "." },
        &[_][]const u8{ "git", "commit", "-m", "test" },
        &[_][]const u8{ "git", "log" },
        &[_][]const u8{ "git", "diff" },
    };
    
    for (commands, git_commands) |ziggit_cmd, git_cmd| {
        const ziggit_result = try tf.runCommand(ziggit_cmd, "test-not-repo");
        defer tf.*.allocator.free(ziggit_result.stdout);
        defer tf.*.allocator.free(ziggit_result.stderr);
        
        const git_result = try tf.runCommand(git_cmd, "test-not-repo");
        defer tf.*.allocator.free(git_result.stdout);
        defer tf.*.allocator.free(git_result.stderr);
        
        const ziggit_analysis = tf.analyzeErrorMessage(ziggit_result.stderr);
        const git_analysis = tf.analyzeErrorMessage(git_result.stderr);
        
        // Check exit code compatibility
        if (ziggit_result.exit_code == git_result.exit_code) {
            std.debug.print("    ✓ {s}: exit codes match ({})\n", .{ ziggit_cmd[1], ziggit_result.exit_code });
        } else {
            std.debug.print("    ✗ {s}: exit codes differ - ziggit={}, git={}\n", .{ ziggit_cmd[1], ziggit_result.exit_code, git_result.exit_code });
        }
        
        // Check error message format
        if (git_analysis.has_fatal_prefix and !ziggit_analysis.has_fatal_prefix) {
            std.debug.print("    ✗ {s}: missing 'fatal:' prefix\n", .{ziggit_cmd[1]});
            std.debug.print("      git: {s}\n", .{git_result.stderr});
            std.debug.print("      ziggit: {s}\n", .{ziggit_result.stderr});
        }
        
        // Check for "not a git repository" message content
        const git_has_not_repo = std.mem.indexOf(u8, git_result.stderr, "not a git repository") != null;
        const ziggit_has_not_repo = std.mem.indexOf(u8, ziggit_result.stderr, "not a git repository") != null;
        
        if (git_has_not_repo and !ziggit_has_not_repo) {
            std.debug.print("    ✗ {s}: missing 'not a git repository' message\n", .{ziggit_cmd[1]});
        }
    }
}

fn testAddNonexistentFileError(tf: *TestFramework) !void {
    std.debug.print("  Testing add nonexistent file error...\n", .{});
    
    tf.cleanupTestDir("test-add-error");
    try fs.cwd().makeDir("test-add-error");
    defer tf.cleanupTestDir("test-add-error");
    
    _ = try tf.runCommand(&[_][]const u8{ "../zig-out/bin/ziggit", "init" }, "test-add-error");
    
    const ziggit_result = try tf.runCommand(&[_][]const u8{ "../zig-out/bin/ziggit", "add", "nonexistent.txt" }, "test-add-error");
    defer tf.*.allocator.free(ziggit_result.stdout);
    defer tf.*.allocator.free(ziggit_result.stderr);
    
    // Git comparison
    tf.cleanupTestDir("test-add-error-git");
    try fs.cwd().makeDir("test-add-error-git");
    defer tf.cleanupTestDir("test-add-error-git");
    _ = try tf.runCommand(&[_][]const u8{ "git", "init" }, "test-add-error-git");
    
    const git_result = try tf.runCommand(&[_][]const u8{ "git", "add", "nonexistent.txt" }, "test-add-error-git");
    defer tf.*.allocator.free(git_result.stdout);
    defer tf.*.allocator.free(git_result.stderr);
    
    const ziggit_analysis = tf.analyzeErrorMessage(ziggit_result.stderr);
    const git_analysis = tf.analyzeErrorMessage(git_result.stderr);
    
    // Both should fail
    if (ziggit_result.exit_code != 0 and git_result.exit_code != 0) {
        std.debug.print("    ✓ both fail for nonexistent file\n", .{});
        
        if (ziggit_result.exit_code == git_result.exit_code) {
            std.debug.print("    ✓ exit codes match ({})\n", .{ziggit_result.exit_code});
        } else {
            std.debug.print("    ✗ exit codes differ: ziggit={}, git={}\n", .{ ziggit_result.exit_code, git_result.exit_code });
        }
        
        // Check error message format
        if (git_analysis.has_fatal_prefix and !ziggit_analysis.has_fatal_prefix) {
            std.debug.print("    ✗ missing 'fatal:' prefix for add error\n", .{});
        }
        
        // Check for pathspec message
        const git_has_pathspec = std.mem.indexOf(u8, git_result.stderr, "pathspec") != null;
        const ziggit_has_pathspec = std.mem.indexOf(u8, ziggit_result.stderr, "pathspec") != null;
        
        if (git_has_pathspec and !ziggit_has_pathspec) {
            std.debug.print("    ⚠ git uses 'pathspec' terminology, ziggit doesn't\n", .{});
        }
        
    } else {
        std.debug.print("    ✗ error handling differs fundamentally\n", .{});
    }
}

fn testInvalidCommandError(tf: *TestFramework) !void {
    std.debug.print("  Testing invalid command error...\n", .{});
    
    const ziggit_result = try tf.runCommand(&[_][]const u8{ "../zig-out/bin/ziggit", "nonexistent-command" }, null);
    defer tf.*.allocator.free(ziggit_result.stdout);
    defer tf.*.allocator.free(ziggit_result.stderr);
    
    const git_result = try tf.runCommand(&[_][]const u8{ "git", "nonexistent-command" }, null);
    defer tf.*.allocator.free(git_result.stdout);
    defer tf.*.allocator.free(git_result.stderr);
    
    // Both should fail
    if (ziggit_result.exit_code != 0 and git_result.exit_code != 0) {
        std.debug.print("    ✓ both fail for invalid command\n", .{});
        
        // Check for similar error message structure
        const git_mentions_command = std.mem.indexOf(u8, git_result.stderr, "not a git command") != null;
        const ziggit_mentions_command = std.mem.indexOf(u8, ziggit_result.stderr, "not a ziggit command") != null;
        
        if (git_mentions_command and ziggit_mentions_command) {
            std.debug.print("    ✓ both mention invalid command appropriately\n", .{});
        } else {
            std.debug.print("    ⚠ error message formats differ\n", .{});
            std.debug.print("      git: {s}\n", .{git_result.stderr});
            std.debug.print("      ziggit: {s}\n", .{ziggit_result.stderr});
        }
        
        // Check exit codes
        if (ziggit_result.exit_code == git_result.exit_code) {
            std.debug.print("    ✓ exit codes match\n", .{});
        } else {
            std.debug.print("    ⚠ exit codes differ: ziggit={}, git={}\n", .{ ziggit_result.exit_code, git_result.exit_code });
        }
    } else {
        std.debug.print("    ✗ invalid command handling fundamentally differs\n", .{});
    }
}

fn testNothingToCommitError(tf: *TestFramework) !void {
    std.debug.print("  Testing nothing to commit error...\n", .{});
    
    tf.cleanupTestDir("test-nothing-commit");
    try fs.cwd().makeDir("test-nothing-commit");
    defer tf.cleanupTestDir("test-nothing-commit");
    
    _ = try tf.runCommand(&[_][]const u8{ "../zig-out/bin/ziggit", "init" }, "test-nothing-commit");
    
    const ziggit_result = try tf.runCommand(&[_][]const u8{ "../zig-out/bin/ziggit", "commit", "-m", "empty commit" }, "test-nothing-commit");
    defer tf.*.allocator.free(ziggit_result.stdout);
    defer tf.*.allocator.free(ziggit_result.stderr);
    
    // Git comparison
    tf.cleanupTestDir("test-nothing-commit-git");
    try fs.cwd().makeDir("test-nothing-commit-git");
    defer tf.cleanupTestDir("test-nothing-commit-git");
    _ = try tf.runCommand(&[_][]const u8{ "git", "init" }, "test-nothing-commit-git");
    
    const git_result = try tf.runCommand(&[_][]const u8{ "git", "commit", "-m", "empty commit" }, "test-nothing-commit-git");
    defer tf.*.allocator.free(git_result.stdout);
    defer tf.*.allocator.free(git_result.stderr);
    
    // Both should fail
    if (ziggit_result.exit_code != 0 and git_result.exit_code != 0) {
        std.debug.print("    ✓ both fail for nothing to commit\n", .{});
        
        if (ziggit_result.exit_code == git_result.exit_code) {
            std.debug.print("    ✓ exit codes match ({})\n", .{ziggit_result.exit_code});
        } else {
            std.debug.print("    ✗ exit codes differ: ziggit={}, git={}\n", .{ ziggit_result.exit_code, git_result.exit_code });
        }
        
        // Check for "nothing to commit" message
        const git_has_nothing = std.mem.indexOf(u8, git_result.stdout, "nothing to commit") != null or
                               std.mem.indexOf(u8, git_result.stderr, "nothing to commit") != null;
        const ziggit_has_nothing = std.mem.indexOf(u8, ziggit_result.stdout, "nothing to commit") != null or
                                  std.mem.indexOf(u8, ziggit_result.stderr, "nothing to commit") != null;
        
        if (git_has_nothing and ziggit_has_nothing) {
            std.debug.print("    ✓ both mention 'nothing to commit'\n", .{});
        } else if (git_has_nothing and !ziggit_has_nothing) {
            std.debug.print("    ✗ ziggit missing 'nothing to commit' message\n", .{});
        }
    } else {
        std.debug.print("    ✗ nothing to commit handling differs\n", .{});
    }
}

fn testCheckoutNonexistentBranchError(tf: *TestFramework) !void {
    std.debug.print("  Testing checkout nonexistent branch error...\n", .{});
    
    tf.cleanupTestDir("test-checkout-error");
    try fs.cwd().makeDir("test-checkout-error");
    defer tf.cleanupTestDir("test-checkout-error");
    
    _ = try tf.runCommand(&[_][]const u8{ "../zig-out/bin/ziggit", "init" }, "test-checkout-error");
    
    const ziggit_result = try tf.runCommand(&[_][]const u8{ "../zig-out/bin/ziggit", "checkout", "nonexistent-branch" }, "test-checkout-error");
    defer tf.*.allocator.free(ziggit_result.stdout);
    defer tf.*.allocator.free(ziggit_result.stderr);
    
    // Git comparison
    tf.cleanupTestDir("test-checkout-error-git");
    try fs.cwd().makeDir("test-checkout-error-git");
    defer tf.cleanupTestDir("test-checkout-error-git");
    _ = try tf.runCommand(&[_][]const u8{ "git", "init" }, "test-checkout-error-git");
    
    const git_result = try tf.runCommand(&[_][]const u8{ "git", "checkout", "nonexistent-branch" }, "test-checkout-error-git");
    defer tf.*.allocator.free(git_result.stdout);
    defer tf.*.allocator.free(git_result.stderr);
    
    // Both should fail
    if (ziggit_result.exit_code != 0 and git_result.exit_code != 0) {
        std.debug.print("    ✓ both fail for nonexistent branch\n", .{});
        
        const ziggit_analysis = tf.analyzeErrorMessage(ziggit_result.stderr);
        const git_analysis = tf.analyzeErrorMessage(git_result.stderr);
        
        if (git_analysis.has_error_prefix and !ziggit_analysis.has_error_prefix) {
            std.debug.print("    ✗ ziggit missing 'error:' prefix\n", .{});
        }
        
        // Check for pathspec or branch-related error message
        const git_has_pathspec = std.mem.indexOf(u8, git_result.stderr, "pathspec") != null;
        const ziggit_has_pathspec = std.mem.indexOf(u8, ziggit_result.stderr, "pathspec") != null;
        
        if (git_has_pathspec and !ziggit_has_pathspec) {
            std.debug.print("    ⚠ git uses pathspec terminology for branch errors\n", .{});
        }
    } else {
        std.debug.print("    ⚠ checkout error handling may differ\n", .{});
    }
}

fn testInvalidFlagErrors(tf: *TestFramework) !void {
    std.debug.print("  Testing invalid flag errors...\n", .{});
    
    const test_cases = [_]struct { 
        cmd: []const []const u8, 
        git_cmd: []const []const u8,
        description: []const u8 
    }{
        .{ .cmd = &[_][]const u8{ "../zig-out/bin/ziggit", "init", "--invalid-flag" }, 
           .git_cmd = &[_][]const u8{ "git", "init", "--invalid-flag" },
           .description = "init --invalid-flag" },
        .{ .cmd = &[_][]const u8{ "../zig-out/bin/ziggit", "status", "--unknown" }, 
           .git_cmd = &[_][]const u8{ "git", "status", "--unknown" },
           .description = "status --unknown" },
        .{ .cmd = &[_][]const u8{ "../zig-out/bin/ziggit", "add", "--badoption" }, 
           .git_cmd = &[_][]const u8{ "git", "add", "--badoption" },
           .description = "add --badoption" },
    };
    
    for (test_cases) |test_case| {
        const ziggit_result = try tf.runCommand(test_case.cmd, null);
        defer tf.*.allocator.free(ziggit_result.stdout);
        defer tf.*.allocator.free(ziggit_result.stderr);
        
        const git_result = try tf.runCommand(test_case.git_cmd, null);
        defer tf.*.allocator.free(git_result.stdout);
        defer tf.*.allocator.free(git_result.stderr);
        
        // Both should fail with non-zero exit code
        if (ziggit_result.exit_code != 0 and git_result.exit_code != 0) {
            std.debug.print("    ✓ {s}: both reject invalid flags\n", .{test_case.description});
            
            // Check for usage message or option error
            const git_has_usage = std.mem.indexOf(u8, git_result.stderr, "usage:") != null or
                                 std.mem.indexOf(u8, git_result.stderr, "unknown option") != null;
            const ziggit_has_usage = std.mem.indexOf(u8, ziggit_result.stderr, "usage:") != null or
                                    std.mem.indexOf(u8, ziggit_result.stderr, "unknown option") != null;
            
            if (git_has_usage and !ziggit_has_usage) {
                std.debug.print("    ⚠ {s}: ziggit error format differs from git\n", .{test_case.description});
            }
        } else {
            std.debug.print("    ⚠ {s}: invalid flag handling differs\n", .{test_case.description});
        }
    }
}

fn testPathspecErrors(tf: *TestFramework) !void {
    std.debug.print("  Testing pathspec-related errors...\n", .{});
    
    tf.cleanupTestDir("test-pathspec");
    try fs.cwd().makeDir("test-pathspec");
    defer tf.cleanupTestDir("test-pathspec");
    
    _ = try tf.runCommand(&[_][]const u8{ "../zig-out/bin/ziggit", "init" }, "test-pathspec");
    
    // Test adding file outside repository (if supported)
    const ziggit_result = try tf.runCommand(&[_][]const u8{ "../zig-out/bin/ziggit", "add", "../nonexistent-file" }, "test-pathspec");
    defer tf.*.allocator.free(ziggit_result.stdout);
    defer tf.*.allocator.free(ziggit_result.stderr);
    
    // Git comparison
    tf.cleanupTestDir("test-pathspec-git");
    try fs.cwd().makeDir("test-pathspec-git");
    defer tf.cleanupTestDir("test-pathspec-git");
    _ = try tf.runCommand(&[_][]const u8{ "git", "init" }, "test-pathspec-git");
    
    const git_result = try tf.runCommand(&[_][]const u8{ "git", "add", "../nonexistent-file" }, "test-pathspec-git");
    defer tf.*.allocator.free(git_result.stdout);
    defer tf.*.allocator.free(git_result.stderr);
    
    // Analyze pathspec error handling
    if (ziggit_result.exit_code != 0 and git_result.exit_code != 0) {
        std.debug.print("    ✓ both handle pathspec errors\n", .{});
        
        const git_has_pathspec = std.mem.indexOf(u8, git_result.stderr, "pathspec") != null;
        const ziggit_has_pathspec = std.mem.indexOf(u8, ziggit_result.stderr, "pathspec") != null;
        
        if (git_has_pathspec and !ziggit_has_pathspec) {
            std.debug.print("    ⚠ ziggit doesn't use 'pathspec' terminology\n", .{});
        } else if (ziggit_has_pathspec) {
            std.debug.print("    ✓ ziggit uses pathspec terminology correctly\n", .{});
        }
    } else {
        std.debug.print("    ⚠ pathspec error handling may differ\n", .{});
    }
}