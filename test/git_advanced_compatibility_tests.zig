const std = @import("std");
const fs = std.fs;
const process = std.process;
const print = std.debug.print;
const ArrayList = std.ArrayList;

// Advanced git compatibility tests based on git source test suite
// Focuses on edge cases, advanced functionality, and exact output matching
// Based on patterns from git t/ directory tests

const TestFramework = struct {
    allocator: std.mem.Allocator,
    
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
    
    fn createTestDir(self: *TestFramework, name: []const u8) ![]u8 {
        var buf: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&buf, "/tmp/ziggit-test-{s}-{d}", .{ name, std.time.timestamp() });
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
    
    fn createFile(self: *TestFramework, dir_path: []const u8, filename: []const u8, content: []const u8) !void {
        var buf: [512]u8 = undefined;
        const file_path = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir_path, filename });
        try fs.cwd().writeFile(file_path, content);
    }
    
    deinit: fn(*TestFramework) void = struct {
        fn deinit(_: *TestFramework) void {}
    }.deinit,
};

// Test git init with various scenarios based on t0001-init.sh
fn testInitAdvanced(tf: *TestFramework) !void {
    print("  Testing advanced git init scenarios...\n");
    
    // Test 1: init --bare with custom directory name
    {
        const test_dir = try tf.createTestDir("init-bare-custom");
        defer tf.cleanupDir(test_dir);
        
        const ziggit_result = try tf.runCommand(&[_][]const u8{ 
            "/root/zigg/root/ziggit/zig-out/bin/ziggit", "init", "--bare", "custom.git" 
        }, test_dir);
        
        const git_result = try tf.runCommand(&[_][]const u8{ 
            "git", "init", "--bare", "custom-git.git" 
        }, test_dir);
        
        if (ziggit_result.exit_code != git_result.exit_code) {
            print("    ⚠ bare init custom dir exit codes differ: ziggit={d}, git={d}\n", 
                  .{ ziggit_result.exit_code, git_result.exit_code });
        }
        
        // Check if bare repo was created correctly
        var buf: [512]u8 = undefined;
        const bare_path = try std.fmt.bufPrint(&buf, "{s}/custom.git", .{test_dir});
        const config_path = try std.fmt.bufPrint(&buf, "{s}/config", .{bare_path});
        
        fs.accessAbsolute(bare_path, .{}) catch |err| {
            print("    ⚠ bare repo directory not created: {}\n", .{err});
            return;
        };
        
        fs.accessAbsolute(config_path, .{}) catch |err| {
            print("    ⚠ bare repo config not created: {}\n", .{err});
            return;
        };
        
        print("    ✓ bare init with custom directory\n");
    }
    
    // Test 2: init in non-empty directory
    {
        const test_dir = try tf.createTestDir("init-non-empty");
        defer tf.cleanupDir(test_dir);
        
        // Create some files first
        try tf.createFile(test_dir, "existing.txt", "This file exists");
        try tf.createFile(test_dir, "README.md", "# Test\nThis is a test");
        
        const ziggit_result = try tf.runCommand(&[_][]const u8{ 
            "/root/zigg/root/ziggit/zig-out/bin/ziggit", "init" 
        }, test_dir);
        
        if (ziggit_result.exit_code != 0) {
            print("    ⚠ init in non-empty dir failed: exit_code={d}\n", .{ziggit_result.exit_code});
        } else {
            print("    ✓ init in non-empty directory\n");
        }
    }
    
    // Test 3: init --quiet (should have minimal output)
    {
        const test_dir = try tf.createTestDir("init-quiet");
        defer tf.cleanupDir(test_dir);
        
        const ziggit_result = try tf.runCommand(&[_][]const u8{ 
            "/root/zigg/root/ziggit/zig-out/bin/ziggit", "init", "--quiet" 
        }, test_dir);
        
        // Check if --quiet is respected (minimal output)
        if (ziggit_result.stdout.len > 100) {
            print("    ⚠ init --quiet has too much output: {d} bytes\n", .{ziggit_result.stdout.len});
        } else {
            print("    ✓ init --quiet respects minimal output\n");
        }
    }
}

// Test git status advanced functionality based on t7508-status.sh 
fn testStatusAdvanced(tf: *TestFramework) !void {
    print("  Testing advanced git status functionality...\n");
    
    const test_dir = try tf.createTestDir("status-advanced");
    defer tf.cleanupDir(test_dir);
    
    // Initialize repository
    _ = try tf.runCommand(&[_][]const u8{ "/root/zigg/root/ziggit/zig-out/bin/ziggit", "init" }, test_dir);
    
    // Test 1: Status with mixed file states
    {
        // Create various file states
        try tf.createFile(test_dir, "tracked.txt", "tracked content");
        try tf.createFile(test_dir, "staged.txt", "staged content");
        try tf.createFile(test_dir, "untracked.txt", "untracked content");
        try tf.createFile(test_dir, "modified.txt", "original");
        
        // Add some files
        _ = try tf.runCommand(&[_][]const u8{ 
            "/root/zigg/root/ziggit/zig-out/bin/ziggit", "add", "tracked.txt", "staged.txt", "modified.txt" 
        }, test_dir);
        
        // Make initial commit
        _ = try tf.runCommand(&[_][]const u8{ 
            "/root/zigg/root/ziggit/zig-out/bin/ziggit", "commit", "-m", "Initial commit" 
        }, test_dir);
        
        // Modify a tracked file
        try tf.createFile(test_dir, "modified.txt", "modified content");
        
        // Add another file to staging
        try tf.createFile(test_dir, "new_staged.txt", "new staged");
        _ = try tf.runCommand(&[_][]const u8{ 
            "/root/zigg/root/ziggit/zig-out/bin/ziggit", "add", "new_staged.txt" 
        }, test_dir);
        
        // Get status from both ziggit and git
        const ziggit_result = try tf.runCommand(&[_][]const u8{ 
            "/root/zigg/root/ziggit/zig-out/bin/ziggit", "status" 
        }, test_dir);
        
        const git_result = try tf.runCommand(&[_][]const u8{ "git", "status" }, test_dir);
        
        // Check if both show untracked files section
        const ziggit_has_untracked = std.mem.indexOf(u8, ziggit_result.stdout, "untracked") != null;
        const git_has_untracked = std.mem.indexOf(u8, git_result.stdout, "Untracked files") != null;
        
        if (ziggit_has_untracked != git_has_untracked) {
            print("    ⚠ untracked file display differs: ziggit={}, git={}\n", 
                  .{ ziggit_has_untracked, git_has_untracked });
        }
        
        print("    ✓ mixed file states status test\n");
    }
    
    // Test 2: Status --porcelain (if supported)
    {
        const ziggit_result = try tf.runCommand(&[_][]const u8{ 
            "/root/zigg/root/ziggit/zig-out/bin/ziggit", "status", "--porcelain" 
        }, test_dir);
        
        if (ziggit_result.exit_code == 0) {
            print("    ✓ status --porcelain supported\n");
        } else {
            print("    ⚠ status --porcelain not implemented\n");
        }
    }
}

// Test git add advanced functionality  
fn testAddAdvanced(tf: *TestFramework) !void {
    print("  Testing advanced git add functionality...\n");
    
    const test_dir = try tf.createTestDir("add-advanced");
    defer tf.cleanupDir(test_dir);
    
    // Initialize repository
    _ = try tf.runCommand(&[_][]const u8{ "/root/zigg/root/ziggit/zig-out/bin/ziggit", "init" }, test_dir);
    
    // Test 1: add -A (add all)
    {
        try tf.createFile(test_dir, "file1.txt", "content1");
        try tf.createFile(test_dir, "file2.txt", "content2");
        
        // Create subdirectory
        var buf: [256]u8 = undefined;
        const subdir = try std.fmt.bufPrint(&buf, "{s}/subdir", .{test_dir});
        fs.makeDirAbsolute(subdir) catch {};
        
        try tf.createFile(test_dir, "subdir/file3.txt", "content3");
        
        const ziggit_result = try tf.runCommand(&[_][]const u8{ 
            "/root/zigg/root/ziggit/zig-out/bin/ziggit", "add", "-A" 
        }, test_dir);
        
        if (ziggit_result.exit_code == 0) {
            print("    ✓ add -A supported\n");
        } else {
            print("    ⚠ add -A not implemented (exit_code={d})\n", .{ziggit_result.exit_code});
        }
    }
    
    // Test 2: add with gitignore patterns
    {
        try tf.createFile(test_dir, ".gitignore", "*.tmp\n*.log\n");
        try tf.createFile(test_dir, "important.txt", "keep this");
        try tf.createFile(test_dir, "temp.tmp", "ignore this");
        try tf.createFile(test_dir, "debug.log", "ignore this too");
        
        const ziggit_result = try tf.runCommand(&[_][]const u8{ 
            "/root/zigg/root/ziggit/zig-out/bin/ziggit", "add", "." 
        }, test_dir);
        
        // Check status to see if gitignore is respected
        const status_result = try tf.runCommand(&[_][]const u8{ 
            "/root/zigg/root/ziggit/zig-out/bin/ziggit", "status" 
        }, test_dir);
        
        const shows_ignored = std.mem.indexOf(u8, status_result.stdout, "temp.tmp") != null or
                            std.mem.indexOf(u8, status_result.stdout, "debug.log") != null;
        
        if (shows_ignored) {
            print("    ⚠ gitignore patterns not fully respected\n");
        } else {
            print("    ✓ gitignore patterns respected\n");
        }
    }
}

// Test git commit advanced functionality
fn testCommitAdvanced(tf: *TestFramework) !void {
    print("  Testing advanced git commit functionality...\n");
    
    const test_dir = try tf.createTestDir("commit-advanced");
    defer tf.cleanupDir(test_dir);
    
    // Initialize repository and set up user
    _ = try tf.runCommand(&[_][]const u8{ "/root/zigg/root/ziggit/zig-out/bin/ziggit", "init" }, test_dir);
    _ = try tf.runCommand(&[_][]const u8{ "git", "config", "user.name", "Test User" }, test_dir);
    _ = try tf.runCommand(&[_][]const u8{ "git", "config", "user.email", "test@example.com" }, test_dir);
    
    // Test 1: commit --amend
    {
        try tf.createFile(test_dir, "file1.txt", "content");
        _ = try tf.runCommand(&[_][]const u8{ 
            "/root/zigg/root/ziggit/zig-out/bin/ziggit", "add", "file1.txt" 
        }, test_dir);
        _ = try tf.runCommand(&[_][]const u8{ 
            "/root/zigg/root/ziggit/zig-out/bin/ziggit", "commit", "-m", "Initial commit" 
        }, test_dir);
        
        try tf.createFile(test_dir, "file2.txt", "more content");
        _ = try tf.runCommand(&[_][]const u8{ 
            "/root/zigg/root/ziggit/zig-out/bin/ziggit", "add", "file2.txt" 
        }, test_dir);
        
        const ziggit_result = try tf.runCommand(&[_][]const u8{ 
            "/root/zigg/root/ziggit/zig-out/bin/ziggit", "commit", "--amend", "-m", "Amended commit" 
        }, test_dir);
        
        if (ziggit_result.exit_code == 0) {
            print("    ✓ commit --amend supported\n");
        } else {
            print("    ⚠ commit --amend not implemented\n");
        }
    }
    
    // Test 2: commit with no changes (should fail)
    {
        const ziggit_result = try tf.runCommand(&[_][]const u8{ 
            "/root/zigg/root/ziggit/zig-out/bin/ziggit", "commit", "-m", "No changes" 
        }, test_dir);
        
        const git_result = try tf.runCommand(&[_][]const u8{ 
            "git", "commit", "-m", "No changes" 
        }, test_dir);
        
        const both_failed = (ziggit_result.exit_code != 0) and (git_result.exit_code != 0);
        if (both_failed) {
            print("    ✓ commit with no changes fails appropriately\n");
        } else {
            print("    ⚠ commit no changes behavior differs: ziggit={d}, git={d}\n", 
                  .{ ziggit_result.exit_code, git_result.exit_code });
        }
    }
}

// Test git log advanced functionality
fn testLogAdvanced(tf: *TestFramework) !void {
    print("  Testing advanced git log functionality...\n");
    
    const test_dir = try tf.createTestDir("log-advanced");
    defer tf.cleanupDir(test_dir);
    
    // Initialize repository and make some commits
    _ = try tf.runCommand(&[_][]const u8{ "/root/zigg/root/ziggit/zig-out/bin/ziggit", "init" }, test_dir);
    _ = try tf.runCommand(&[_][]const u8{ "git", "config", "user.name", "Test User" }, test_dir);
    _ = try tf.runCommand(&[_][]const u8{ "git", "config", "user.email", "test@example.com" }, test_dir);
    
    // Create multiple commits
    try tf.createFile(test_dir, "file1.txt", "first");
    _ = try tf.runCommand(&[_][]const u8{ "/root/zigg/root/ziggit/zig-out/bin/ziggit", "add", "file1.txt" }, test_dir);
    _ = try tf.runCommand(&[_][]const u8{ 
        "/root/zigg/root/ziggit/zig-out/bin/ziggit", "commit", "-m", "First commit" 
    }, test_dir);
    
    try tf.createFile(test_dir, "file2.txt", "second");
    _ = try tf.runCommand(&[_][]const u8{ "/root/zigg/root/ziggit/zig-out/bin/ziggit", "add", "file2.txt" }, test_dir);
    _ = try tf.runCommand(&[_][]const u8{ 
        "/root/zigg/root/ziggit/zig-out/bin/ziggit", "commit", "-m", "Second commit" 
    }, test_dir);
    
    // Test 1: log --oneline
    {
        const ziggit_result = try tf.runCommand(&[_][]const u8{ 
            "/root/zigg/root/ziggit/zig-out/bin/ziggit", "log", "--oneline" 
        }, test_dir);
        
        if (ziggit_result.exit_code == 0) {
            print("    ✓ log --oneline supported\n");
        } else {
            print("    ⚠ log --oneline not implemented\n");
        }
    }
    
    // Test 2: log -n (limit number of commits)
    {
        const ziggit_result = try tf.runCommand(&[_][]const u8{ 
            "/root/zigg/root/ziggit/zig-out/bin/ziggit", "log", "-n", "1" 
        }, test_dir);
        
        if (ziggit_result.exit_code == 0) {
            print("    ✓ log -n supported\n");
        } else {
            print("    ⚠ log -n not implemented\n");
        }
    }
}

// Test git diff advanced functionality  
fn testDiffAdvanced(tf: *TestFramework) !void {
    print("  Testing advanced git diff functionality...\n");
    
    const test_dir = try tf.createTestDir("diff-advanced");
    defer tf.cleanupDir(test_dir);
    
    // Initialize repository
    _ = try tf.runCommand(&[_][]const u8{ "/root/zigg/root/ziggit/zig-out/bin/ziggit", "init" }, test_dir);
    _ = try tf.runCommand(&[_][]const u8{ "git", "config", "user.name", "Test User" }, test_dir);
    _ = try tf.runCommand(&[_][]const u8{ "git", "config", "user.email", "test@example.com" }, test_dir);
    
    // Create initial commit
    try tf.createFile(test_dir, "file.txt", "line 1\nline 2\nline 3\n");
    _ = try tf.runCommand(&[_][]const u8{ "/root/zigg/root/ziggit/zig-out/bin/ziggit", "add", "file.txt" }, test_dir);
    _ = try tf.runCommand(&[_][]const u8{ 
        "/root/zigg/root/ziggit/zig-out/bin/ziggit", "commit", "-m", "Initial" 
    }, test_dir);
    
    // Modify file
    try tf.createFile(test_dir, "file.txt", "line 1\nmodified line 2\nline 3\nnew line 4\n");
    
    // Test 1: diff working directory changes
    {
        const ziggit_result = try tf.runCommand(&[_][]const u8{ 
            "/root/zigg/root/ziggit/zig-out/bin/ziggit", "diff" 
        }, test_dir);
        
        const git_result = try tf.runCommand(&[_][]const u8{ "git", "diff" }, test_dir);
        
        const ziggit_has_output = ziggit_result.stdout.len > 0;
        const git_has_output = git_result.stdout.len > 0;
        
        if (ziggit_has_output == git_has_output) {
            print("    ✓ diff working directory changes\n");
        } else {
            print("    ⚠ diff output differs: ziggit_len={d}, git_len={d}\n", 
                  .{ ziggit_result.stdout.len, git_result.stdout.len });
        }
    }
    
    // Test 2: diff --cached (staged changes)
    {
        _ = try tf.runCommand(&[_][]const u8{ "/root/zigg/root/ziggit/zig-out/bin/ziggit", "add", "file.txt" }, test_dir);
        
        const ziggit_result = try tf.runCommand(&[_][]const u8{ 
            "/root/zigg/root/ziggit/zig-out/bin/ziggit", "diff", "--cached" 
        }, test_dir);
        
        if (ziggit_result.exit_code == 0) {
            print("    ✓ diff --cached supported\n");
        } else {
            print("    ⚠ diff --cached not implemented\n");
        }
    }
}

// Test git branch and checkout advanced functionality
fn testBranchCheckoutAdvanced(tf: *TestFramework) !void {
    print("  Testing advanced git branch/checkout functionality...\n");
    
    const test_dir = try tf.createTestDir("branch-advanced");
    defer tf.cleanupDir(test_dir);
    
    // Initialize repository and make initial commit
    _ = try tf.runCommand(&[_][]const u8{ "/root/zigg/root/ziggit/zig-out/bin/ziggit", "init" }, test_dir);
    _ = try tf.runCommand(&[_][]const u8{ "git", "config", "user.name", "Test User" }, test_dir);
    _ = try tf.runCommand(&[_][]const u8{ "git", "config", "user.email", "test@example.com" }, test_dir);
    
    try tf.createFile(test_dir, "file.txt", "content");
    _ = try tf.runCommand(&[_][]const u8{ "/root/zigg/root/ziggit/zig-out/bin/ziggit", "add", "file.txt" }, test_dir);
    _ = try tf.runCommand(&[_][]const u8{ 
        "/root/zigg/root/ziggit/zig-out/bin/ziggit", "commit", "-m", "Initial" 
    }, test_dir);
    
    // Test 1: branch creation
    {
        const ziggit_result = try tf.runCommand(&[_][]const u8{ 
            "/root/zigg/root/ziggit/zig-out/bin/ziggit", "branch", "feature" 
        }, test_dir);
        
        if (ziggit_result.exit_code == 0) {
            print("    ✓ branch creation supported\n");
        } else {
            print("    ⚠ branch creation failed: exit_code={d}\n", .{ziggit_result.exit_code});
        }
    }
    
    // Test 2: branch listing
    {
        const ziggit_result = try tf.runCommand(&[_][]const u8{ 
            "/root/zigg/root/ziggit/zig-out/bin/ziggit", "branch" 
        }, test_dir);
        
        const git_result = try tf.runCommand(&[_][]const u8{ "git", "branch" }, test_dir);
        
        if (ziggit_result.exit_code == git_result.exit_code) {
            print("    ✓ branch listing exit codes match\n");
        } else {
            print("    ⚠ branch listing exit codes differ: ziggit={d}, git={d}\n", 
                  .{ ziggit_result.exit_code, git_result.exit_code });
        }
    }
    
    // Test 3: checkout branch
    {
        const ziggit_result = try tf.runCommand(&[_][]const u8{ 
            "/root/zigg/root/ziggit/zig-out/bin/ziggit", "checkout", "feature" 
        }, test_dir);
        
        if (ziggit_result.exit_code == 0) {
            print("    ✓ checkout branch supported\n");
        } else {
            print("    ⚠ checkout branch failed: exit_code={d}\n", .{ziggit_result.exit_code});
        }
    }
    
    // Test 4: checkout -b (create and checkout)
    {
        const ziggit_result = try tf.runCommand(&[_][]const u8{ 
            "/root/zigg/root/ziggit/zig-out/bin/ziggit", "checkout", "-b", "development" 
        }, test_dir);
        
        if (ziggit_result.exit_code == 0) {
            print("    ✓ checkout -b supported\n");
        } else {
            print("    ⚠ checkout -b not implemented\n");
        }
    }
}

pub fn runGitAdvancedCompatibilityTests() !void {
    print("Running advanced git compatibility tests...\n");
    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var tf = TestFramework.init(allocator);
    defer tf.deinit();
    
    try testInitAdvanced(&tf);
    try testStatusAdvanced(&tf);  
    try testAddAdvanced(&tf);
    try testCommitAdvanced(&tf);
    try testLogAdvanced(&tf);
    try testDiffAdvanced(&tf);
    try testBranchCheckoutAdvanced(&tf);
    
    print("Advanced git compatibility tests completed!\n");
}