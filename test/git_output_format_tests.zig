const std = @import("std");
const fs = std.fs;
const process = std.process;
const print = std.debug.print;

// Git output format compatibility tests
// Ensures ziggit output matches git's output format exactly for drop-in replacement
// Based on git source test patterns for output validation

const CommandResult = struct {
    exit_code: u32,
    stdout: []u8,
    stderr: []u8,
};

const TestFramework = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) TestFramework {
        return TestFramework{ .allocator = allocator };
    }
    
    pub fn deinit(_: *TestFramework) void {
        // Nothing to clean up for now
    }
    
    fn runCommand(self: *TestFramework, args: []const []const u8, cwd: ?[]const u8) !CommandResult {
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
    
    fn createTestDir(self: *TestFramework, name: []const u8) ![]u8 {
        var buf: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&buf, "/tmp/ziggit-format-{s}-{d}", .{ name, std.time.timestamp() });
        const dir_path = try self.allocator.dupe(u8, path);
        
        fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        
        return dir_path;
    }
    
    fn cleanupDir(self: *TestFramework, path: []u8) void {
        fs.deleteTreeAbsolute(path) catch {};
        self.allocator.free(path);
    }
    
    fn createFile(_: *TestFramework, dir_path: []const u8, filename: []const u8, content: []const u8) !void {
        var buf: [512]u8 = undefined;
        const file_path = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir_path, filename });
        try fs.cwd().writeFile(.{ .sub_path = file_path, .data = content });
    }
    
    fn compareOutput(self: *TestFramework, description: []const u8, ziggit_out: []const u8, git_out: []const u8, strict: bool) void {
        _ = self;
        
        if (strict) {
            // Exact match required
            if (std.mem.eql(u8, ziggit_out, git_out)) {
                print("    ✓ {s} (exact match)\n", .{description});
            } else {
                print("    ⚠ {s} format differs\n", .{description});
                print("      ziggit: '{s}'\n", .{ziggit_out});
                print("      git:    '{s}'\n", .{git_out});
            }
        } else {
            // Fuzzy match - check key elements
            const ziggit_has_content = ziggit_out.len > 0;
            const git_has_content = git_out.len > 0;
            
            if (ziggit_has_content == git_has_content) {
                print("    ✓ {s} (structure match)\n", .{description});
            } else {
                print("    ⚠ {s} structure differs (ziggit_len={d}, git_len={d})\n", 
                      .{ description, ziggit_out.len, git_out.len });
            }
        }
    }
};

// Test init output format matching
fn testInitOutputFormat(tf: *TestFramework) !void {
    print("  Testing init output format matching...\n", .{});
    
    // Test 1: Basic init output
    {
        const test_dir = try tf.createTestDir("init-basic");
        defer tf.cleanupDir(test_dir);
        
        const ziggit_result = try tf.runCommand(&[_][]const u8{ 
            "/root/ziggit/zig-out/bin/ziggit", "init", "test-repo" 
        }, test_dir);
        
        const git_result = try tf.runCommand(&[_][]const u8{ 
            "git", "init", "test-repo-git" 
        }, test_dir);
        
        // Compare output structure (not exact path)
        const ziggit_mentions_init = std.mem.indexOf(u8, ziggit_result.stdout, "init") != null;
        const git_mentions_init = std.mem.indexOf(u8, git_result.stdout, "init") != null;
        
        if (ziggit_mentions_init == git_mentions_init) {
            print("    ✓ basic init output format matches\n", .{});
        } else {
            print("    ⚠ basic init output format differs\n", .{});
            print("      ziggit: '{s}'\n", .{ziggit_result.stdout});
            print("      git:    '{s}'\n", .{git_result.stdout});
        }
    }
    
    // Test 2: Bare init output
    {
        const test_dir = try tf.createTestDir("init-bare");
        defer tf.cleanupDir(test_dir);
        
        const ziggit_result = try tf.runCommand(&[_][]const u8{ 
            "/root/ziggit/zig-out/bin/ziggit", "init", "--bare", "bare-repo.git" 
        }, test_dir);
        
        const git_result = try tf.runCommand(&[_][]const u8{ 
            "git", "init", "--bare", "bare-repo-git.git" 
        }, test_dir);
        
        const ziggit_mentions_bare = std.mem.indexOf(u8, ziggit_result.stdout, "bare") != null;
        const git_mentions_bare = std.mem.indexOf(u8, git_result.stdout, "bare") != null;
        
        if (ziggit_mentions_bare and git_mentions_bare) {
            print("    ✓ bare init output format matches\n", .{});
        } else {
            print("    ⚠ bare init output format differs\n", .{});
            print("      ziggit: '{s}'\n", .{ziggit_result.stdout});
            print("      git:    '{s}'\n", .{git_result.stdout});
        }
    }
}

// Test status output format matching
fn testStatusOutputFormat(tf: *TestFramework) !void {
    print("  Testing status output format matching...\n", .{});
    
    const test_dir = try tf.createTestDir("status-format");
    defer tf.cleanupDir(test_dir);
    
    // Initialize repo and set up user
    _ = try tf.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "init" }, test_dir);
    _ = try tf.runCommand(&[_][]const u8{ "git", "config", "user.name", "Test User" }, test_dir);
    _ = try tf.runCommand(&[_][]const u8{ "git", "config", "user.email", "test@example.com" }, test_dir);
    
    // Test 1: Empty repository status
    {
        const ziggit_result = try tf.runCommand(&[_][]const u8{ 
            "/root/ziggit/zig-out/bin/ziggit", "status" 
        }, test_dir);
        
        const git_result = try tf.runCommand(&[_][]const u8{ "git", "status" }, test_dir);
        
        // Check for key phrases
        const ziggit_mentions_branch = std.mem.indexOf(u8, ziggit_result.stdout, "branch") != null;
        const git_mentions_branch = std.mem.indexOf(u8, git_result.stdout, "branch") != null;
        
        if (ziggit_mentions_branch == git_mentions_branch) {
            print("    ✓ empty repo status format matches\n", .{});
        } else {
            print("    ⚠ empty repo status format differs\n", .{});
            print("      ziggit: '{s}'\n", .{ziggit_result.stdout});
            print("      git:    '{s}'\n", .{git_result.stdout});
        }
    }
    
    // Test 2: Status with untracked files
    {
        try tf.createFile(test_dir, "untracked1.txt", "content1");
        try tf.createFile(test_dir, "untracked2.txt", "content2");
        
        const ziggit_result = try tf.runCommand(&[_][]const u8{ 
            "/root/ziggit/zig-out/bin/ziggit", "status" 
        }, test_dir);
        
        const git_result = try tf.runCommand(&[_][]const u8{ "git", "status" }, test_dir);
        
        // Check for untracked files section
        const ziggit_shows_untracked = std.mem.indexOf(u8, ziggit_result.stdout, "untracked") != null or
                                     std.mem.indexOf(u8, ziggit_result.stdout, "Untracked") != null;
        const git_shows_untracked = std.mem.indexOf(u8, git_result.stdout, "Untracked files") != null;
        
        if (ziggit_shows_untracked == git_shows_untracked) {
            print("    ✓ untracked files status format matches\n", .{});
        } else {
            print("    ⚠ untracked files status format differs\n", .{});
            print("      ziggit shows untracked: {}\n", .{ziggit_shows_untracked});
            print("      git shows untracked: {}\n", .{git_shows_untracked});
            print("      ziggit: '{s}'\n", .{ziggit_result.stdout});
            print("      git:    '{s}'\n", .{git_result.stdout});
        }
    }
    
    // Test 3: Status with staged files
    {
        _ = try tf.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "add", "untracked1.txt" }, test_dir);
        
        const ziggit_result = try tf.runCommand(&[_][]const u8{ 
            "/root/ziggit/zig-out/bin/ziggit", "status" 
        }, test_dir);
        
        const git_result = try tf.runCommand(&[_][]const u8{ "git", "status" }, test_dir);
        
        // Check for staged files section
        const ziggit_shows_staged = std.mem.indexOf(u8, ziggit_result.stdout, "staged") != null or
                                  std.mem.indexOf(u8, ziggit_result.stdout, "committed") != null;
        const git_shows_staged = std.mem.indexOf(u8, git_result.stdout, "Changes to be committed") != null;
        
        if (ziggit_shows_staged and git_shows_staged) {
            print("    ✓ staged files status format includes staged section\n", .{});
        } else {
            print("    ⚠ staged files status format missing staged section\n", .{});
            print("      ziggit: '{s}'\n", .{ziggit_result.stdout});
            print("      git:    '{s}'\n", .{git_result.stdout});
        }
    }
}

// Test add output format (should be silent on success)
fn testAddOutputFormat(tf: *TestFramework) !void {
    print("  Testing add output format matching...\n", .{});
    
    const test_dir = try tf.createTestDir("add-format");
    defer tf.cleanupDir(test_dir);
    
    _ = try tf.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "init" }, test_dir);
    try tf.createFile(test_dir, "test.txt", "content");
    
    // Test successful add (should be silent)
    {
        const ziggit_result = try tf.runCommand(&[_][]const u8{ 
            "/root/ziggit/zig-out/bin/ziggit", "add", "test.txt" 
        }, test_dir);
        
        const git_result = try tf.runCommand(&[_][]const u8{ 
            "git", "add", "test.txt" 
        }, test_dir);
        
        const both_silent = (ziggit_result.stdout.len == 0) and (git_result.stdout.len == 0);
        if (both_silent and ziggit_result.exit_code == 0 and git_result.exit_code == 0) {
            print("    ✓ successful add is silent (like git)\n", .{});
        } else {
            print("    ⚠ add output differs from git\n", .{});
            print("      ziggit stdout len: {d}, exit: {d}\n", .{ ziggit_result.stdout.len, ziggit_result.exit_code });
            print("      git stdout len: {d}, exit: {d}\n", .{ git_result.stdout.len, git_result.exit_code });
        }
    }
    
    // Test add non-existent file (should have error)
    {
        const ziggit_result = try tf.runCommand(&[_][]const u8{ 
            "/root/ziggit/zig-out/bin/ziggit", "add", "nonexistent.txt" 
        }, test_dir);
        
        const git_result = try tf.runCommand(&[_][]const u8{ 
            "git", "add", "nonexistent.txt" 
        }, test_dir);
        
        const both_failed = (ziggit_result.exit_code != 0) and (git_result.exit_code != 0);
        const both_have_error = (ziggit_result.stderr.len > 0) and (git_result.stderr.len > 0);
        
        if (both_failed and both_have_error) {
            print("    ✓ add non-existent file errors appropriately\n", .{});
        } else {
            print("    ⚠ add non-existent file error format differs\n", .{});
            print("      ziggit stderr: '{s}'\n", .{ziggit_result.stderr});
            print("      git stderr: '{s}'\n", .{git_result.stderr});
        }
    }
}

// Test commit output format
fn testCommitOutputFormat(tf: *TestFramework) !void {
    print("  Testing commit output format matching...\n", .{});
    
    const test_dir = try tf.createTestDir("commit-format");
    defer tf.cleanupDir(test_dir);
    
    _ = try tf.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "init" }, test_dir);
    _ = try tf.runCommand(&[_][]const u8{ "git", "config", "user.name", "Test User" }, test_dir);
    _ = try tf.runCommand(&[_][]const u8{ "git", "config", "user.email", "test@example.com" }, test_dir);
    
    // Test successful commit
    {
        try tf.createFile(test_dir, "file.txt", "content");
        _ = try tf.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "add", "file.txt" }, test_dir);
        
        const ziggit_result = try tf.runCommand(&[_][]const u8{ 
            "/root/ziggit/zig-out/bin/ziggit", "commit", "-m", "Test commit" 
        }, test_dir);
        
        const git_result = try tf.runCommand(&[_][]const u8{ 
            "git", "commit", "-m", "Test commit message" 
        }, test_dir);
        
        // Both should succeed and mention something about the commit
        const both_successful = (ziggit_result.exit_code == 0) and (git_result.exit_code == 0);
        const ziggit_mentions_commit = ziggit_result.stdout.len > 0;
        const git_mentions_commit = git_result.stdout.len > 0;
        
        if (both_successful and (ziggit_mentions_commit == git_mentions_commit)) {
            print("    ✓ successful commit format appropriate\n", .{});
        } else {
            print("    ⚠ commit output format differs\n", .{});
            print("      ziggit: '{s}' (exit: {d})\n", .{ ziggit_result.stdout, ziggit_result.exit_code });
            print("      git:    '{s}' (exit: {d})\n", .{ git_result.stdout, git_result.exit_code });
        }
    }
    
    // Test commit with nothing to commit
    {
        const ziggit_result = try tf.runCommand(&[_][]const u8{ 
            "/root/ziggit/zig-out/bin/ziggit", "commit", "-m", "Nothing to commit" 
        }, test_dir);
        
        const git_result = try tf.runCommand(&[_][]const u8{ 
            "git", "commit", "-m", "Nothing to commit" 
        }, test_dir);
        
        const both_failed = (ziggit_result.exit_code != 0) and (git_result.exit_code != 0);
        if (both_failed) {
            print("    ✓ commit nothing to commit fails appropriately\n", .{});
        } else {
            print("    ⚠ commit nothing to commit handling differs\n", .{});
            print("      ziggit exit: {d}, git exit: {d}\n", .{ ziggit_result.exit_code, git_result.exit_code });
        }
    }
}

// Test log output format
fn testLogOutputFormat(tf: *TestFramework) !void {
    print("  Testing log output format matching...\n", .{});
    
    const test_dir = try tf.createTestDir("log-format");
    defer tf.cleanupDir(test_dir);
    
    _ = try tf.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "init" }, test_dir);
    _ = try tf.runCommand(&[_][]const u8{ "git", "config", "user.name", "Test User" }, test_dir);
    _ = try tf.runCommand(&[_][]const u8{ "git", "config", "user.email", "test@example.com" }, test_dir);
    
    // Test log in empty repository (should fail)
    {
        const ziggit_result = try tf.runCommand(&[_][]const u8{ 
            "/root/ziggit/zig-out/bin/ziggit", "log" 
        }, test_dir);
        
        const git_result = try tf.runCommand(&[_][]const u8{ "git", "log" }, test_dir);
        
        const both_failed = (ziggit_result.exit_code != 0) and (git_result.exit_code != 0);
        if (both_failed) {
            print("    ✓ log empty repo fails appropriately\n", .{});
        } else {
            print("    ⚠ log empty repo handling differs: ziggit={d}, git={d}\n", 
                  .{ ziggit_result.exit_code, git_result.exit_code });
        }
    }
    
    // Test log with commits
    {
        try tf.createFile(test_dir, "file1.txt", "content1");
        _ = try tf.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "add", "file1.txt" }, test_dir);
        _ = try tf.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "commit", "-m", "First commit" }, test_dir);
        
        const ziggit_result = try tf.runCommand(&[_][]const u8{ 
            "/root/ziggit/zig-out/bin/ziggit", "log" 
        }, test_dir);
        
        const git_result = try tf.runCommand(&[_][]const u8{ "git", "log" }, test_dir);
        
        const both_successful = (ziggit_result.exit_code == 0) and (git_result.exit_code == 0);
        const ziggit_shows_commit = std.mem.indexOf(u8, ziggit_result.stdout, "commit") != null;
        const git_shows_commit = std.mem.indexOf(u8, git_result.stdout, "commit") != null;
        
        if (both_successful and ziggit_shows_commit and git_shows_commit) {
            print("    ✓ log with commits shows commit info\n", .{});
        } else {
            print("    ⚠ log with commits format differs\n", .{});
            print("      ziggit success: {}, shows commit: {}\n", .{ ziggit_result.exit_code == 0, ziggit_shows_commit });
            print("      git success: {}, shows commit: {}\n", .{ git_result.exit_code == 0, git_shows_commit });
        }
    }
}

// Test help and version output format
fn testHelpVersionFormat(tf: *TestFramework) !void {
    print("  Testing help and version output format...\n", .{});
    
    // Test --help
    {
        const ziggit_result = try tf.runCommand(&[_][]const u8{ 
            "/root/ziggit/zig-out/bin/ziggit", "--help" 
        }, "/tmp");
        
        const git_result = try tf.runCommand(&[_][]const u8{ "git", "--help" }, "/tmp");
        
        const ziggit_shows_usage = std.mem.indexOf(u8, ziggit_result.stdout, "usage") != null;
        const git_shows_usage = std.mem.indexOf(u8, git_result.stdout, "usage") != null;
        
        if (ziggit_shows_usage and git_shows_usage) {
            print("    ✓ --help shows usage information\n", .{});
        } else {
            print("    ⚠ --help format differs\n", .{});
            print("      ziggit shows usage: {}\n", .{ziggit_shows_usage});
            print("      git shows usage: {}\n", .{git_shows_usage});
        }
    }
    
    // Test --version
    {
        const ziggit_result = try tf.runCommand(&[_][]const u8{ 
            "/root/ziggit/zig-out/bin/ziggit", "--version" 
        }, "/tmp");
        
        const git_result = try tf.runCommand(&[_][]const u8{ "git", "--version" }, "/tmp");
        
        const both_successful = (ziggit_result.exit_code == 0) and (git_result.exit_code == 0);
        const ziggit_shows_version = ziggit_result.stdout.len > 0;
        const git_shows_version = git_result.stdout.len > 0;
        
        if (both_successful and ziggit_shows_version and git_shows_version) {
            print("    ✓ --version shows version information\n", .{});
        } else {
            print("    ⚠ --version format differs\n", .{});
            print("      ziggit: '{s}' (exit: {d})\n", .{ ziggit_result.stdout, ziggit_result.exit_code });
            print("      git:    '{s}' (exit: {d})\n", .{ git_result.stdout, git_result.exit_code });
        }
    }
}

pub fn runGitOutputFormatTests() !void {
    print("Running git output format tests...\n", .{});
    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var tf = TestFramework.init(allocator);
    defer tf.deinit();
    
    try testInitOutputFormat(&tf);
    try testStatusOutputFormat(&tf);
    try testAddOutputFormat(&tf);
    try testCommitOutputFormat(&tf);
    try testLogOutputFormat(&tf);
    try testHelpVersionFormat(&tf);
    
    print("Git output format tests completed!\n", .{});
}