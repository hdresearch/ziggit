const std = @import("std");
const fs = std.fs;
const process = std.process;

// Git status compatibility tests
// Focused on matching git's exact exit codes and output formats

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
};

pub fn runGitStatusCompatTests() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var tf = TestFramework.init(allocator);
    
    std.debug.print("Running git status compatibility tests...\n", .{});
    
    // Test status outside repository (critical for exit code compatibility)
    try testStatusOutsideRepository(&tf);
    
    // Test status in empty repository
    try testStatusEmptyRepository(&tf);
    
    // Test status with untracked files
    try testStatusUntrackedFiles(&tf);
    
    // Test status with staged files
    try testStatusStagedFiles(&tf);
    
    // Test status with modified files
    try testStatusModifiedFiles(&tf);
    
    // Test status --porcelain
    try testStatusPorcelain(&tf);
    
    // Test status error messages
    try testStatusErrorMessages(&tf);
    
    std.debug.print("Git status compatibility tests completed!\n", .{});
}

fn testStatusOutsideRepository(tf: *TestFramework) !void {
    std.debug.print("  Testing status outside repository...\n", .{});
    
    // Create a temporary directory that's NOT a git repository
    tf.cleanupTestDir("test-no-repo");
    try fs.cwd().makeDir("test-no-repo");
    defer tf.cleanupTestDir("test-no-repo");
    
    // Test ziggit status
    const ziggit_result = try tf.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "status" }, "test-no-repo");
    defer tf.*.allocator.free(ziggit_result.stdout);
    defer tf.*.allocator.free(ziggit_result.stderr);
    
    // Test git status for comparison
    const git_result = try tf.runCommand(&[_][]const u8{ "git", "status" }, "test-no-repo");
    defer tf.*.allocator.free(git_result.stdout);
    defer tf.*.allocator.free(git_result.stderr);
    
    // git status outside repo typically returns 128
    // This is a critical compatibility issue identified in tests
    if (ziggit_result.exit_code == git_result.exit_code) {
        std.debug.print("    ✓ status outside repository exit code matches\n", .{});
    } else {
        std.debug.print("    ✗ CRITICAL: status outside repository exit codes differ: ziggit={}, git={}\n", .{ ziggit_result.exit_code, git_result.exit_code });
        std.debug.print("      ziggit stderr: {s}\n", .{ziggit_result.stderr});
        std.debug.print("      git stderr: {s}\n", .{git_result.stderr});
    }
    
    // Check error message format
    const git_error_contains_fatal = std.mem.indexOf(u8, git_result.stderr, "fatal:") != null;
    const ziggit_error_contains_fatal = std.mem.indexOf(u8, ziggit_result.stderr, "fatal:") != null;
    
    if (git_error_contains_fatal and !ziggit_error_contains_fatal) {
        std.debug.print("    ⚠ error message format differs (git uses 'fatal:', ziggit doesn't)\n", .{});
    }
}

fn testStatusEmptyRepository(tf: *TestFramework) !void {
    std.debug.print("  Testing status in empty repository...\n", .{});
    
    tf.cleanupTestDir("test-empty-repo");
    try fs.cwd().makeDir("test-empty-repo");
    defer tf.cleanupTestDir("test-empty-repo");
    
    // Initialize repositories
    _ = try tf.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "init" }, "test-empty-repo");
    
    tf.cleanupTestDir("test-empty-repo-git");
    try fs.cwd().makeDir("test-empty-repo-git");
    defer tf.cleanupTestDir("test-empty-repo-git");
    _ = try tf.runCommand(&[_][]const u8{ "git", "init" }, "test-empty-repo-git");
    
    // Test status in empty repositories
    const ziggit_result = try tf.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "status" }, "test-empty-repo");
    defer tf.*.allocator.free(ziggit_result.stdout);
    defer tf.*.allocator.free(ziggit_result.stderr);
    
    const git_result = try tf.runCommand(&[_][]const u8{ "git", "status" }, "test-empty-repo-git");
    defer tf.*.allocator.free(git_result.stdout);
    defer tf.*.allocator.free(git_result.stderr);
    
    if (ziggit_result.exit_code == git_result.exit_code) {
        std.debug.print("    ✓ status empty repository exit code matches\n", .{});
    } else {
        std.debug.print("    ✗ status empty repository exit codes differ: ziggit={}, git={}\n", .{ ziggit_result.exit_code, git_result.exit_code });
    }
    
    // Both should mention initial commit and branch
    const git_mentions_initial = std.mem.indexOf(u8, git_result.stdout, "Initial commit") != null or 
                                 std.mem.indexOf(u8, git_result.stdout, "No commits yet") != null;
    const ziggit_mentions_initial = std.mem.indexOf(u8, ziggit_result.stdout, "Initial commit") != null or 
                                    std.mem.indexOf(u8, ziggit_result.stdout, "No commits yet") != null;
    
    if (git_mentions_initial and ziggit_mentions_initial) {
        std.debug.print("    ✓ both mention initial commit status\n", .{});
    } else if (git_mentions_initial and !ziggit_mentions_initial) {
        std.debug.print("    ⚠ ziggit doesn't mention initial commit status like git\n", .{});
    }
}

fn testStatusUntrackedFiles(tf: *TestFramework) !void {
    std.debug.print("  Testing status with untracked files...\n", .{});
    
    tf.cleanupTestDir("test-untracked");
    try fs.cwd().makeDir("test-untracked");
    defer tf.cleanupTestDir("test-untracked");
    
    // Initialize and add untracked file
    _ = try tf.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "init" }, "test-untracked");
    try tf.createTestFile("test-untracked/untracked.txt", "untracked content\n");
    
    // Git comparison
    tf.cleanupTestDir("test-untracked-git");
    try fs.cwd().makeDir("test-untracked-git");
    defer tf.cleanupTestDir("test-untracked-git");
    _ = try tf.runCommand(&[_][]const u8{ "git", "init" }, "test-untracked-git");
    try tf.createTestFile("test-untracked-git/untracked.txt", "untracked content\n");
    
    const ziggit_result = try tf.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "status" }, "test-untracked");
    defer tf.*.allocator.free(ziggit_result.stdout);
    defer tf.*.allocator.free(ziggit_result.stderr);
    
    const git_result = try tf.runCommand(&[_][]const u8{ "git", "status" }, "test-untracked-git");
    defer tf.*.allocator.free(git_result.stdout);
    defer tf.*.allocator.free(git_result.stderr);
    
    // Exit codes should match
    if (ziggit_result.exit_code == git_result.exit_code) {
        std.debug.print("    ✓ status untracked files exit code matches\n", .{});
    } else {
        std.debug.print("    ✗ status untracked files exit codes differ: ziggit={}, git={}\n", .{ ziggit_result.exit_code, git_result.exit_code });
    }
    
    // Both should mention untracked files
    const git_mentions_untracked = std.mem.indexOf(u8, git_result.stdout, "untracked") != null;
    const ziggit_mentions_untracked = std.mem.indexOf(u8, ziggit_result.stdout, "untracked") != null;
    
    if (git_mentions_untracked and ziggit_mentions_untracked) {
        std.debug.print("    ✓ both mention untracked files\n", .{});
    } else {
        std.debug.print("    ⚠ untracked file detection differs\n", .{});
    }
}

fn testStatusStagedFiles(tf: *TestFramework) !void {
    std.debug.print("  Testing status with staged files...\n", .{});
    
    tf.cleanupTestDir("test-staged");
    try fs.cwd().makeDir("test-staged");
    defer tf.cleanupTestDir("test-staged");
    
    // Initialize, add file, and stage it
    _ = try tf.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "init" }, "test-staged");
    try tf.createTestFile("test-staged/staged.txt", "staged content\n");
    _ = try tf.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "add", "staged.txt" }, "test-staged");
    
    // Git comparison
    tf.cleanupTestDir("test-staged-git");
    try fs.cwd().makeDir("test-staged-git");
    defer tf.cleanupTestDir("test-staged-git");
    _ = try tf.runCommand(&[_][]const u8{ "git", "init" }, "test-staged-git");
    try tf.createTestFile("test-staged-git/staged.txt", "staged content\n");
    _ = try tf.runCommand(&[_][]const u8{ "git", "add", "staged.txt" }, "test-staged-git");
    
    const ziggit_result = try tf.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "status" }, "test-staged");
    defer tf.*.allocator.free(ziggit_result.stdout);
    defer tf.*.allocator.free(ziggit_result.stderr);
    
    const git_result = try tf.runCommand(&[_][]const u8{ "git", "status" }, "test-staged-git");
    defer tf.*.allocator.free(git_result.stdout);
    defer tf.*.allocator.free(git_result.stderr);
    
    if (ziggit_result.exit_code == git_result.exit_code) {
        std.debug.print("    ✓ status staged files exit code matches\n", .{});
    } else {
        std.debug.print("    ✗ status staged files exit codes differ: ziggit={}, git={}\n", .{ ziggit_result.exit_code, git_result.exit_code });
    }
}

fn testStatusModifiedFiles(tf: *TestFramework) !void {
    std.debug.print("  Testing status with modified files...\n", .{});
    
    tf.cleanupTestDir("test-modified");
    try fs.cwd().makeDir("test-modified");
    defer tf.cleanupTestDir("test-modified");
    
    // Initialize, add, commit, then modify
    _ = try tf.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "init" }, "test-modified");
    try tf.createTestFile("test-modified/modified.txt", "original content\n");
    _ = try tf.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "add", "modified.txt" }, "test-modified");
    _ = try tf.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "commit", "-m", "initial" }, "test-modified");
    
    // Modify the file
    try tf.createTestFile("test-modified/modified.txt", "modified content\n");
    
    const ziggit_result = try tf.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "status" }, "test-modified");
    defer tf.*.allocator.free(ziggit_result.stdout);
    defer tf.*.allocator.free(ziggit_result.stderr);
    
    if (ziggit_result.exit_code == 0) {
        std.debug.print("    ✓ status with modified files\n", .{});
    } else {
        std.debug.print("    ✗ status with modified files failed: exit_code={}\n", .{ziggit_result.exit_code});
    }
}

fn testStatusPorcelain(tf: *TestFramework) !void {
    std.debug.print("  Testing status --porcelain...\n", .{});
    
    tf.cleanupTestDir("test-porcelain");
    try fs.cwd().makeDir("test-porcelain");
    defer tf.cleanupTestDir("test-porcelain");
    
    // Test --porcelain flag
    _ = try tf.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "init" }, "test-porcelain");
    
    const ziggit_result = try tf.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "status", "--porcelain" }, "test-porcelain");
    defer tf.*.allocator.free(ziggit_result.stdout);
    defer tf.*.allocator.free(ziggit_result.stderr);
    
    // Git comparison
    tf.cleanupTestDir("test-porcelain-git");
    try fs.cwd().makeDir("test-porcelain-git");
    defer tf.cleanupTestDir("test-porcelain-git");
    _ = try tf.runCommand(&[_][]const u8{ "git", "init" }, "test-porcelain-git");
    
    const git_result = try tf.runCommand(&[_][]const u8{ "git", "status", "--porcelain" }, "test-porcelain-git");
    defer tf.*.allocator.free(git_result.stdout);
    defer tf.*.allocator.free(git_result.stderr);
    
    if (ziggit_result.exit_code == git_result.exit_code) {
        std.debug.print("    ✓ status --porcelain\n", .{});
    } else {
        std.debug.print("    ⚠ status --porcelain exit codes differ: ziggit={}, git={}\n", .{ ziggit_result.exit_code, git_result.exit_code });
    }
}

fn testStatusErrorMessages(tf: *TestFramework) !void {
    std.debug.print("  Testing status error message formats...\n", .{});
    
    // Test invalid flags
    const ziggit_invalid = try tf.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "status", "--invalid-flag" }, null);
    defer tf.*.allocator.free(ziggit_invalid.stdout);
    defer tf.*.allocator.free(ziggit_invalid.stderr);
    
    const git_invalid = try tf.runCommand(&[_][]const u8{ "git", "status", "--invalid-flag" }, null);
    defer tf.*.allocator.free(git_invalid.stdout);
    defer tf.*.allocator.free(git_invalid.stderr);
    
    // Both should fail with similar exit codes
    if (ziggit_invalid.exit_code != 0 and git_invalid.exit_code != 0) {
        std.debug.print("    ✓ both fail on invalid flags\n", .{});
    } else {
        std.debug.print("    ⚠ invalid flag handling differs\n", .{});
    }
}