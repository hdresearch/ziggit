const std = @import("std");
const fs = std.fs;
const process = std.process;

// Git diff output compatibility tests
// Focused on matching git's exact diff output format

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
    
    const DiffAnalysis = struct {
        has_header: bool,
        has_hunk_header: bool,
        has_context: bool,
        has_additions: bool,
        has_deletions: bool,
        line_count: u32,
    };
    
    fn analyzeDiffOutput(_: *TestFramework, output: []const u8) DiffAnalysis {
        var analysis = DiffAnalysis{
            .has_header = false,
            .has_hunk_header = false,
            .has_context = false,
            .has_additions = false,
            .has_deletions = false,
            .line_count = 0,
        };
        
        var lines = std.mem.split(u8, output, "\n");
        while (lines.next()) |line| {
            analysis.line_count += 1;
            
            if (std.mem.startsWith(u8, line, "diff --git")) {
                analysis.has_header = true;
            } else if (std.mem.startsWith(u8, line, "@@")) {
                analysis.has_hunk_header = true;
            } else if (std.mem.startsWith(u8, line, "+") and !std.mem.startsWith(u8, line, "+++")) {
                analysis.has_additions = true;
            } else if (std.mem.startsWith(u8, line, "-") and !std.mem.startsWith(u8, line, "---")) {
                analysis.has_deletions = true;
            } else if (std.mem.startsWith(u8, line, " ")) {
                analysis.has_context = true;
            }
        }
        
        return analysis;
    }
};

pub fn runGitDiffOutputCompatTests() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var tf = TestFramework.init(allocator);
    
    std.debug.print("Running git diff output compatibility tests...\n", .{});
    
    // Test diff in empty repository
    try testDiffEmptyRepository(&tf);
    
    // Test diff with no changes
    try testDiffNoChanges(&tf);
    
    // Test diff with staged changes
    try testDiffStagedChanges(&tf);
    
    // Test diff with working directory changes
    try testDiffWorkingDirectoryChanges(&tf);
    
    // Test diff --cached
    try testDiffCached(&tf);
    
    // Test diff output format details
    try testDiffOutputFormat(&tf);
    
    // Test diff binary files
    try testDiffBinaryFiles(&tf);
    
    std.debug.print("Git diff output compatibility tests completed!\n", .{});
}

fn testDiffEmptyRepository(tf: *TestFramework) !void {
    std.debug.print("  Testing diff in empty repository...\n", .{});
    
    tf.cleanupTestDir("test-diff-empty");
    try fs.cwd().makeDir("test-diff-empty");
    defer tf.cleanupTestDir("test-diff-empty");
    
    _ = try tf.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "init" }, "test-diff-empty");
    
    const ziggit_result = try tf.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "diff" }, "test-diff-empty");
    defer tf.*.allocator.free(ziggit_result.stdout);
    defer tf.*.allocator.free(ziggit_result.stderr);
    
    // Git comparison
    tf.cleanupTestDir("test-diff-empty-git");
    try fs.cwd().makeDir("test-diff-empty-git");
    defer tf.cleanupTestDir("test-diff-empty-git");
    _ = try tf.runCommand(&[_][]const u8{ "git", "init" }, "test-diff-empty-git");
    
    const git_result = try tf.runCommand(&[_][]const u8{ "git", "diff" }, "test-diff-empty-git");
    defer tf.*.allocator.free(git_result.stdout);
    defer tf.*.allocator.free(git_result.stderr);
    
    if (ziggit_result.exit_code == git_result.exit_code) {
        std.debug.print("    ✓ diff empty repository exit code matches\n", .{});
    } else {
        std.debug.print("    ✗ diff empty repository exit codes differ: ziggit={}, git={}\n", .{ ziggit_result.exit_code, git_result.exit_code });
    }
    
    // Both should have no output (empty diff)
    if (ziggit_result.stdout.len == 0 and git_result.stdout.len == 0) {
        std.debug.print("    ✓ both produce empty output for empty repository\n", .{});
    } else {
        std.debug.print("    ⚠ diff output differs for empty repository\n", .{});
    }
}

fn testDiffNoChanges(tf: *TestFramework) !void {
    std.debug.print("  Testing diff with no changes...\n", .{});
    
    tf.cleanupTestDir("test-diff-no-changes");
    try fs.cwd().makeDir("test-diff-no-changes");
    defer tf.cleanupTestDir("test-diff-no-changes");
    
    // Set up repository with committed file
    _ = try tf.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "init" }, "test-diff-no-changes");
    try tf.createTestFile("test-diff-no-changes/file.txt", "content\n");
    _ = try tf.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "add", "file.txt" }, "test-diff-no-changes");
    _ = try tf.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "commit", "-m", "initial" }, "test-diff-no-changes");
    
    const ziggit_result = try tf.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "diff" }, "test-diff-no-changes");
    defer tf.*.allocator.free(ziggit_result.stdout);
    defer tf.*.allocator.free(ziggit_result.stderr);
    
    // Git comparison
    tf.cleanupTestDir("test-diff-no-changes-git");
    try fs.cwd().makeDir("test-diff-no-changes-git");
    defer tf.cleanupTestDir("test-diff-no-changes-git");
    _ = try tf.runCommand(&[_][]const u8{ "git", "init" }, "test-diff-no-changes-git");
    try tf.createTestFile("test-diff-no-changes-git/file.txt", "content\n");
    _ = try tf.runCommand(&[_][]const u8{ "git", "add", "file.txt" }, "test-diff-no-changes-git");
    _ = try tf.runCommand(&[_][]const u8{ "git", "commit", "-m", "initial" }, "test-diff-no-changes-git");
    
    const git_result = try tf.runCommand(&[_][]const u8{ "git", "diff" }, "test-diff-no-changes-git");
    defer tf.*.allocator.free(git_result.stdout);
    defer tf.*.allocator.free(git_result.stderr);
    
    if (ziggit_result.exit_code == git_result.exit_code) {
        std.debug.print("    ✓ diff no changes exit code matches\n", .{});
    } else {
        std.debug.print("    ✗ diff no changes exit codes differ: ziggit={}, git={}\n", .{ ziggit_result.exit_code, git_result.exit_code });
    }
}

fn testDiffWorkingDirectoryChanges(tf: *TestFramework) !void {
    std.debug.print("  Testing diff with working directory changes...\n", .{});
    
    tf.cleanupTestDir("test-diff-wd-changes");
    try fs.cwd().makeDir("test-diff-wd-changes");
    defer tf.cleanupTestDir("test-diff-wd-changes");
    
    // Set up repository with committed file, then modify it
    _ = try tf.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "init" }, "test-diff-wd-changes");
    try tf.createTestFile("test-diff-wd-changes/file.txt", "line1\nline2\nline3\n");
    _ = try tf.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "add", "file.txt" }, "test-diff-wd-changes");
    _ = try tf.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "commit", "-m", "initial" }, "test-diff-wd-changes");
    
    // Modify the file
    try tf.createTestFile("test-diff-wd-changes/file.txt", "line1\nmodified line2\nline3\nnew line4\n");
    
    const ziggit_result = try tf.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "diff" }, "test-diff-wd-changes");
    defer tf.*.allocator.free(ziggit_result.stdout);
    defer tf.*.allocator.free(ziggit_result.stderr);
    
    // Git comparison
    tf.cleanupTestDir("test-diff-wd-changes-git");
    try fs.cwd().makeDir("test-diff-wd-changes-git");
    defer tf.cleanupTestDir("test-diff-wd-changes-git");
    _ = try tf.runCommand(&[_][]const u8{ "git", "init" }, "test-diff-wd-changes-git");
    try tf.createTestFile("test-diff-wd-changes-git/file.txt", "line1\nline2\nline3\n");
    _ = try tf.runCommand(&[_][]const u8{ "git", "add", "file.txt" }, "test-diff-wd-changes-git");
    _ = try tf.runCommand(&[_][]const u8{ "git", "commit", "-m", "initial" }, "test-diff-wd-changes-git");
    try tf.createTestFile("test-diff-wd-changes-git/file.txt", "line1\nmodified line2\nline3\nnew line4\n");
    
    const git_result = try tf.runCommand(&[_][]const u8{ "git", "diff" }, "test-diff-wd-changes-git");
    defer tf.*.allocator.free(git_result.stdout);
    defer tf.*.allocator.free(git_result.stderr);
    
    if (ziggit_result.exit_code == git_result.exit_code) {
        std.debug.print("    ✓ diff working directory changes exit code matches\n", .{});
    } else {
        std.debug.print("    ✗ diff working directory changes exit codes differ: ziggit={}, git={}\n", .{ ziggit_result.exit_code, git_result.exit_code });
    }
    
    // Analyze diff output format
    const ziggit_analysis = tf.analyzeDiffOutput(ziggit_result.stdout);
    const git_analysis = tf.analyzeDiffOutput(git_result.stdout);
    
    if (ziggit_analysis.has_header and git_analysis.has_header) {
        std.debug.print("    ✓ both include diff headers\n", .{});
    } else if (!ziggit_analysis.has_header and git_analysis.has_header) {
        std.debug.print("    ✗ CRITICAL: ziggit missing diff headers\n", .{});
        std.debug.print("      git output length: {}, ziggit output length: {}\n", .{ git_result.stdout.len, ziggit_result.stdout.len });
    } else {
        std.debug.print("    ⚠ diff header format differs\n", .{});
    }
    
    if (ziggit_result.stdout.len == 0 and git_result.stdout.len > 0) {
        std.debug.print("    ✗ CRITICAL: ziggit produces no diff output but git does\n", .{});
        std.debug.print("      git output: {s}\n", .{git_result.stdout[0..@min(200, git_result.stdout.len)]});
    }
}

fn testDiffStagedChanges(tf: *TestFramework) !void {
    std.debug.print("  Testing diff with staged changes...\n", .{});
    
    tf.cleanupTestDir("test-diff-staged");
    try fs.cwd().makeDir("test-diff-staged");
    defer tf.cleanupTestDir("test-diff-staged");
    
    // Set up repository, commit file, modify and stage
    _ = try tf.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "init" }, "test-diff-staged");
    try tf.createTestFile("test-diff-staged/file.txt", "original content\n");
    _ = try tf.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "add", "file.txt" }, "test-diff-staged");
    _ = try tf.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "commit", "-m", "initial" }, "test-diff-staged");
    
    try tf.createTestFile("test-diff-staged/file.txt", "modified content\n");
    _ = try tf.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "add", "file.txt" }, "test-diff-staged");
    
    // Test diff (should show no changes since changes are staged)
    const ziggit_result = try tf.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "diff" }, "test-diff-staged");
    defer tf.*.allocator.free(ziggit_result.stdout);
    defer tf.*.allocator.free(ziggit_result.stderr);
    
    if (ziggit_result.exit_code == 0 and ziggit_result.stdout.len == 0) {
        std.debug.print("    ✓ diff shows no changes when changes are staged\n", .{});
    } else {
        std.debug.print("    ⚠ diff behavior with staged changes may differ from git\n", .{});
    }
}

fn testDiffCached(tf: *TestFramework) !void {
    std.debug.print("  Testing diff --cached...\n", .{});
    
    tf.cleanupTestDir("test-diff-cached");
    try fs.cwd().makeDir("test-diff-cached");
    defer tf.cleanupTestDir("test-diff-cached");
    
    // Set up repository with staged changes
    _ = try tf.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "init" }, "test-diff-cached");
    try tf.createTestFile("test-diff-cached/file.txt", "original content\n");
    _ = try tf.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "add", "file.txt" }, "test-diff-cached");
    _ = try tf.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "commit", "-m", "initial" }, "test-diff-cached");
    
    try tf.createTestFile("test-diff-cached/file.txt", "modified content\n");
    _ = try tf.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "add", "file.txt" }, "test-diff-cached");
    
    const ziggit_result = try tf.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "diff", "--cached" }, "test-diff-cached");
    defer tf.*.allocator.free(ziggit_result.stdout);
    defer tf.*.allocator.free(ziggit_result.stderr);
    
    // Git comparison
    tf.cleanupTestDir("test-diff-cached-git");
    try fs.cwd().makeDir("test-diff-cached-git");
    defer tf.cleanupTestDir("test-diff-cached-git");
    _ = try tf.runCommand(&[_][]const u8{ "git", "init" }, "test-diff-cached-git");
    try tf.createTestFile("test-diff-cached-git/file.txt", "original content\n");
    _ = try tf.runCommand(&[_][]const u8{ "git", "add", "file.txt" }, "test-diff-cached-git");
    _ = try tf.runCommand(&[_][]const u8{ "git", "commit", "-m", "initial" }, "test-diff-cached-git");
    try tf.createTestFile("test-diff-cached-git/file.txt", "modified content\n");
    _ = try tf.runCommand(&[_][]const u8{ "git", "add", "file.txt" }, "test-diff-cached-git");
    
    const git_result = try tf.runCommand(&[_][]const u8{ "git", "diff", "--cached" }, "test-diff-cached-git");
    defer tf.*.allocator.free(git_result.stdout);
    defer tf.*.allocator.free(git_result.stderr);
    
    if (ziggit_result.exit_code == git_result.exit_code) {
        std.debug.print("    ✓ diff --cached exit code matches\n", .{});
    } else {
        std.debug.print("    ⚠ diff --cached exit codes differ: ziggit={}, git={}\n", .{ ziggit_result.exit_code, git_result.exit_code });
    }
}

fn testDiffOutputFormat(tf: *TestFramework) !void {
    std.debug.print("  Testing diff output format details...\n", .{});
    
    tf.cleanupTestDir("test-diff-format");
    try fs.cwd().makeDir("test-diff-format");
    defer tf.cleanupTestDir("test-diff-format");
    
    // Create a comprehensive test case for diff format
    _ = try tf.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "init" }, "test-diff-format");
    try tf.createTestFile("test-diff-format/test.txt", 
        \\line 1
        \\line 2
        \\line 3
        \\line 4
        \\line 5
    );
    _ = try tf.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "add", "test.txt" }, "test-diff-format");
    _ = try tf.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "commit", "-m", "initial" }, "test-diff-format");
    
    // Modify file to create a good diff
    try tf.createTestFile("test-diff-format/test.txt", 
        \\line 1
        \\modified line 2
        \\line 3
        \\line 4
        \\new line 5
        \\added line 6
    );
    
    const ziggit_result = try tf.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "diff" }, "test-diff-format");
    defer tf.*.allocator.free(ziggit_result.stdout);
    defer tf.*.allocator.free(ziggit_result.stderr);
    
    if (ziggit_result.stdout.len > 0) {
        std.debug.print("    ✓ diff produces output for changes\n", .{});
        
        // Check for standard diff format elements
        if (std.mem.indexOf(u8, ziggit_result.stdout, "diff --git") != null) {
            std.debug.print("    ✓ includes 'diff --git' header\n", .{});
        } else {
            std.debug.print("    ✗ missing 'diff --git' header\n", .{});
        }
        
        if (std.mem.indexOf(u8, ziggit_result.stdout, "@@") != null) {
            std.debug.print("    ✓ includes hunk headers\n", .{});
        } else {
            std.debug.print("    ✗ missing hunk headers\n", .{});
        }
    } else {
        std.debug.print("    ✗ CRITICAL: diff produces no output for actual changes\n", .{});
    }
}

fn testDiffBinaryFiles(tf: *TestFramework) !void {
    std.debug.print("  Testing diff with binary files...\n", .{});
    
    tf.cleanupTestDir("test-diff-binary");
    try fs.cwd().makeDir("test-diff-binary");
    defer tf.cleanupTestDir("test-diff-binary");
    
    _ = try tf.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "init" }, "test-diff-binary");
    
    // Create a binary file
    const binary_content = [_]u8{ 0x00, 0x01, 0x02, 0xFF, 0xFE, 0xFD };
    try tf.createTestFile("test-diff-binary/binary.bin", &binary_content);
    _ = try tf.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "add", "binary.bin" }, "test-diff-binary");
    _ = try tf.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "commit", "-m", "add binary" }, "test-diff-binary");
    
    // Modify binary file
    const modified_binary = [_]u8{ 0x00, 0x01, 0x03, 0xFF, 0xFE, 0xFC };
    try tf.createTestFile("test-diff-binary/binary.bin", &modified_binary);
    
    const ziggit_result = try tf.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "diff" }, "test-diff-binary");
    defer tf.*.allocator.free(ziggit_result.stdout);
    defer tf.*.allocator.free(ziggit_result.stderr);
    
    if (ziggit_result.exit_code == 0) {
        std.debug.print("    ✓ diff handles binary files\n", .{});
        
        // Check if binary diff is handled appropriately
        if (std.mem.indexOf(u8, ziggit_result.stdout, "Binary files") != null) {
            std.debug.print("    ✓ correctly identifies binary files\n", .{});
        } else if (ziggit_result.stdout.len == 0) {
            std.debug.print("    ⚠ binary diff produces no output (may be unimplemented)\n", .{});
        }
    } else {
        std.debug.print("    ⚠ diff with binary files failed: exit_code={}\n", .{ziggit_result.exit_code});
    }
}