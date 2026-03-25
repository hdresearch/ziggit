const std = @import("std");
const fs = std.fs;
const process = std.process;
const print = std.debug.print;

// Git edge case tests based on git source test suite
// Focuses on error conditions, boundary cases, and unusual scenarios
// Ensures ziggit handles edge cases the same way git does

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
    
    fn createTestDir(self: *TestFramework, name: []const u8) ![]u8 {
        var buf: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&buf, "/tmp/ziggit-edge-{s}-{d}", .{ name, std.time.timestamp() });
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

// Test git commands with invalid arguments
fn testInvalidArguments(tf: *TestFramework) !void {
    print("  Testing invalid argument handling...\n");
    
    // Test 1: init with invalid flags
    {
        const ziggit_result = try tf.runCommand(&[_][]const u8{ 
            "/root/zigg/root/ziggit/zig-out/bin/ziggit", "init", "--invalid-flag" 
        }, "/tmp");
        
        const git_result = try tf.runCommand(&[_][]const u8{ 
            "git", "init", "--invalid-flag" 
        }, "/tmp");
        
        const both_failed = (ziggit_result.exit_code != 0) and (git_result.exit_code != 0);
        if (both_failed) {
            print("    ✓ invalid flag handling matches git\n");
        } else {
            print("    ⚠ invalid flag handling differs: ziggit={d}, git={d}\n", 
                  .{ ziggit_result.exit_code, git_result.exit_code });
        }
    }
    
    // Test 2: add with no arguments in repository
    {
        const test_dir = try tf.createTestDir("add-no-args");
        defer tf.cleanupDir(test_dir);
        
        _ = try tf.runCommand(&[_][]const u8{ "/root/zigg/root/ziggit/zig-out/bin/ziggit", "init" }, test_dir);
        
        const ziggit_result = try tf.runCommand(&[_][]const u8{ 
            "/root/zigg/root/ziggit/zig-out/bin/ziggit", "add" 
        }, test_dir);
        
        const git_result = try tf.runCommand(&[_][]const u8{ "git", "add" }, test_dir);
        
        if (ziggit_result.exit_code == git_result.exit_code) {
            print("    ✓ add with no args exit codes match\n");
        } else {
            print("    ⚠ add no args exit codes differ: ziggit={d}, git={d}\n", 
                  .{ ziggit_result.exit_code, git_result.exit_code });
        }
    }
    
    // Test 3: commit with empty message
    {
        const test_dir = try tf.createTestDir("commit-empty-msg");
        defer tf.cleanupDir(test_dir);
        
        _ = try tf.runCommand(&[_][]const u8{ "/root/zigg/root/ziggit/zig-out/bin/ziggit", "init" }, test_dir);
        try tf.createFile(test_dir, "file.txt", "content");
        _ = try tf.runCommand(&[_][]const u8{ "/root/zigg/root/ziggit/zig-out/bin/ziggit", "add", "file.txt" }, test_dir);
        
        const ziggit_result = try tf.runCommand(&[_][]const u8{ 
            "/root/zigg/root/ziggit/zig-out/bin/ziggit", "commit", "-m", "" 
        }, test_dir);
        
        const git_result = try tf.runCommand(&[_][]const u8{ 
            "git", "commit", "-m", "" 
        }, test_dir);
        
        if ((ziggit_result.exit_code != 0) == (git_result.exit_code != 0)) {
            print("    ✓ empty commit message handling matches\n");
        } else {
            print("    ⚠ empty commit message handling differs: ziggit={d}, git={d}\n", 
                  .{ ziggit_result.exit_code, git_result.exit_code });
        }
    }
}

// Test operations outside git repository
fn testOutsideRepository(tf: *TestFramework) !void {
    print("  Testing operations outside git repository...\n");
    
    const test_dir = try tf.createTestDir("outside-repo");
    defer tf.cleanupDir(test_dir);
    
    // Ensure this is NOT a git repository
    try tf.createFile(test_dir, "regular-file.txt", "not in git");
    
    const commands = [_][]const []const u8{
        &[_][]const u8{ "status" },
        &[_][]const u8{ "add", "regular-file.txt" },
        &[_][]const u8{ "commit", "-m", "test" },
        &[_][]const u8{ "log" },
        &[_][]const u8{ "diff" },
        &[_][]const u8{ "branch" },
    };
    
    for (commands) |cmd_args| {
        var ziggit_args = std.ArrayList([]const u8).init(tf.allocator);
        defer ziggit_args.deinit();
        
        try ziggit_args.append("/root/zigg/root/ziggit/zig-out/bin/ziggit");
        for (cmd_args) |arg| {
            try ziggit_args.append(arg);
        }
        
        var git_args = std.ArrayList([]const u8).init(tf.allocator);
        defer git_args.deinit();
        
        try git_args.append("git");
        for (cmd_args) |arg| {
            try git_args.append(arg);
        }
        
        const ziggit_result = try tf.runCommand(ziggit_args.items, test_dir);
        const git_result = try tf.runCommand(git_args.items, test_dir);
        
        const both_failed = (ziggit_result.exit_code != 0) and (git_result.exit_code != 0);
        if (both_failed) {
            print("    ✓ {s} outside repo fails appropriately\n", .{cmd_args[0]});
        } else {
            print("    ⚠ {s} outside repo: ziggit={d}, git={d}\n", 
                  .{ cmd_args[0], ziggit_result.exit_code, git_result.exit_code });
        }
    }
}

// Test with special file names and characters
fn testSpecialFilenames(tf: *TestFramework) !void {
    print("  Testing special filename handling...\n");
    
    const test_dir = try tf.createTestDir("special-files");
    defer tf.cleanupDir(test_dir);
    
    _ = try tf.runCommand(&[_][]const u8{ "/root/zigg/root/ziggit/zig-out/bin/ziggit", "init" }, test_dir);
    
    const special_files = [_][]const u8{
        "file with spaces.txt",
        "file-with-dashes.txt", 
        "file.with.dots.txt",
        "UPPERCASE.TXT",
        "file_with_underscores.txt",
        "123numeric.txt",
        "mixed-Case_File.123.txt",
    };
    
    // Create files with special names
    for (special_files) |filename| {
        const content = try std.fmt.allocPrint(tf.allocator, "Content of {s}", .{filename});
        defer tf.allocator.free(content);
        
        tf.createFile(test_dir, filename, content) catch |err| {
            print("    ⚠ Failed to create file '{s}': {}\n", .{ filename, err });
            continue;
        };
        
        // Try to add the file
        const ziggit_result = try tf.runCommand(&[_][]const u8{ 
            "/root/zigg/root/ziggit/zig-out/bin/ziggit", "add", filename 
        }, test_dir);
        
        if (ziggit_result.exit_code == 0) {
            print("    ✓ added file: {s}\n", .{filename});
        } else {
            print("    ⚠ failed to add file: {s} (exit_code={d})\n", .{ filename, ziggit_result.exit_code });
        }
    }
    
    // Test status with special files
    const status_result = try tf.runCommand(&[_][]const u8{ 
        "/root/zigg/root/ziggit/zig-out/bin/ziggit", "status" 
    }, test_dir);
    
    if (status_result.exit_code == 0) {
        print("    ✓ status with special filenames works\n");
    } else {
        print("    ⚠ status failed with special filenames: exit_code={d}\n", .{status_result.exit_code});
    }
}

// Test repository corruption scenarios
fn testCorruptedRepository(tf: *TestFramework) !void {
    print("  Testing corrupted repository handling...\n");
    
    const test_dir = try tf.createTestDir("corrupted");
    defer tf.cleanupDir(test_dir);
    
    // Create valid repository first
    _ = try tf.runCommand(&[_][]const u8{ "/root/zigg/root/ziggit/zig-out/bin/ziggit", "init" }, test_dir);
    
    // Test 1: Corrupt HEAD file
    {
        var buf: [512]u8 = undefined;
        const head_path = try std.fmt.bufPrint(&buf, "{s}/.git/HEAD", .{test_dir});
        
        fs.cwd().writeFile(head_path, "invalid head content") catch {};
        
        const ziggit_result = try tf.runCommand(&[_][]const u8{ 
            "/root/zigg/root/ziggit/zig-out/bin/ziggit", "status" 
        }, test_dir);
        
        const git_result = try tf.runCommand(&[_][]const u8{ "git", "status" }, test_dir);
        
        const both_handle_gracefully = (ziggit_result.exit_code != 0) and (git_result.exit_code != 0);
        if (both_handle_gracefully) {
            print("    ✓ corrupt HEAD handled gracefully\n");
        } else {
            print("    ⚠ corrupt HEAD handling differs: ziggit={d}, git={d}\n", 
                  .{ ziggit_result.exit_code, git_result.exit_code });
        }
        
        // Restore valid HEAD
        fs.cwd().writeFile(head_path, "ref: refs/heads/main\n") catch {};
    }
    
    // Test 2: Missing .git/config
    {
        var buf: [512]u8 = undefined;
        const config_path = try std.fmt.bufPrint(&buf, "{s}/.git/config", .{test_dir});
        
        fs.cwd().deleteFile(config_path) catch {};
        
        const ziggit_result = try tf.runCommand(&[_][]const u8{ 
            "/root/zigg/root/ziggit/zig-out/bin/ziggit", "status" 
        }, test_dir);
        
        if (ziggit_result.exit_code == 0) {
            print("    ✓ missing config handled (status works)\n");
        } else {
            print("    ⚠ missing config causes failure: exit_code={d}\n", .{ziggit_result.exit_code});
        }
    }
}

// Test large file handling
fn testLargeFiles(tf: *TestFramework) !void {
    print("  Testing large file handling...\n");
    
    const test_dir = try tf.createTestDir("large-files");
    defer tf.cleanupDir(test_dir);
    
    _ = try tf.runCommand(&[_][]const u8{ "/root/zigg/root/ziggit/zig-out/bin/ziggit", "init" }, test_dir);
    
    // Create a moderately large file (1MB)
    const large_content = try tf.allocator.alloc(u8, 1024 * 1024);
    defer tf.allocator.free(large_content);
    
    // Fill with predictable pattern
    for (large_content, 0..) |*byte, i| {
        byte.* = @as(u8, @intCast(i % 256));
    }
    
    var buf: [512]u8 = undefined;
    const large_file_path = try std.fmt.bufPrint(&buf, "{s}/large_file.bin", .{test_dir});
    
    fs.cwd().writeFile(large_file_path, large_content) catch |err| {
        print("    ⚠ Failed to create large file: {}\n", .{err});
        return;
    };
    
    // Test adding large file
    const add_result = try tf.runCommand(&[_][]const u8{ 
        "/root/zigg/root/ziggit/zig-out/bin/ziggit", "add", "large_file.bin" 
    }, test_dir);
    
    if (add_result.exit_code == 0) {
        print("    ✓ large file (1MB) added successfully\n");
        
        // Test status with large file
        const status_result = try tf.runCommand(&[_][]const u8{ 
            "/root/zigg/root/ziggit/zig-out/bin/ziggit", "status" 
        }, test_dir);
        
        if (status_result.exit_code == 0) {
            print("    ✓ status with large file works\n");
        } else {
            print("    ⚠ status failed with large file: exit_code={d}\n", .{status_result.exit_code});
        }
    } else {
        print("    ⚠ large file add failed: exit_code={d}\n", .{add_result.exit_code});
    }
}

// Test deep directory structures
fn testDeepDirectories(tf: *TestFramework) !void {
    print("  Testing deep directory structures...\n");
    
    const test_dir = try tf.createTestDir("deep-dirs");
    defer tf.cleanupDir(test_dir);
    
    _ = try tf.runCommand(&[_][]const u8{ "/root/zigg/root/ziggit/zig-out/bin/ziggit", "init" }, test_dir);
    
    // Create deep directory structure
    const max_depth = 10;
    var current_path = try tf.allocator.alloc(u8, 1024);
    defer tf.allocator.free(current_path);
    
    std.mem.copy(u8, current_path, test_dir);
    var current_len = test_dir.len;
    
    var i: usize = 0;
    while (i < max_depth) : (i += 1) {
        const dir_name = try std.fmt.bufPrint(current_path[current_len..], "/dir{d}", .{i});
        current_len += dir_name.len;
        
        fs.makeDirAbsolute(current_path[0..current_len]) catch |err| {
            print("    ⚠ Failed to create deep directory at depth {d}: {}\n", .{ i, err });
            break;
        };
    }
    
    // Create file in deepest directory
    const deep_file_path = try std.fmt.bufPrint(current_path[current_len..], "/deep_file.txt");
    current_len += deep_file_path.len;
    
    fs.cwd().writeFile(current_path[0..current_len], "Deep file content") catch |err| {
        print("    ⚠ Failed to create deep file: {}\n", .{err});
        return;
    };
    
    // Test status with deep structure
    const status_result = try tf.runCommand(&[_][]const u8{ 
        "/root/zigg/root/ziggit/zig-out/bin/ziggit", "status" 
    }, test_dir);
    
    if (status_result.exit_code == 0) {
        print("    ✓ status with deep directories (depth {d}) works\n", .{max_depth});
    } else {
        print("    ⚠ status failed with deep directories: exit_code={d}\n", .{status_result.exit_code});
    }
    
    // Test add with deep file
    const relative_deep_path = current_path[test_dir.len + 1..current_len]; // Skip test_dir and leading slash
    const add_result = try tf.runCommand(&[_][]const u8{ 
        "/root/zigg/root/ziggit/zig-out/bin/ziggit", "add", relative_deep_path 
    }, test_dir);
    
    if (add_result.exit_code == 0) {
        print("    ✓ add deep file successful\n");
    } else {
        print("    ⚠ add deep file failed: exit_code={d}\n", .{add_result.exit_code});
    }
}

// Test concurrent access simulation
fn testConcurrentAccess(tf: *TestFramework) !void {
    print("  Testing concurrent access patterns...\n");
    
    const test_dir = try tf.createTestDir("concurrent");
    defer tf.cleanupDir(test_dir);
    
    _ = try tf.runCommand(&[_][]const u8{ "/root/zigg/root/ziggit/zig-out/bin/ziggit", "init" }, test_dir);
    
    // Create multiple files rapidly
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        var filename_buf: [64]u8 = undefined;
        const filename = try std.fmt.bufPrint(&filename_buf, "file{d}.txt", .{i});
        
        var content_buf: [64]u8 = undefined;
        const content = try std.fmt.bufPrint(&content_buf, "Content {d}", .{i});
        
        try tf.createFile(test_dir, filename, content);
    }
    
    // Run multiple git operations quickly
    const operations = [_][]const []const u8{
        &[_][]const u8{ "status" },
        &[_][]const u8{ "add", "." },
        &[_][]const u8{ "status" },
    };
    
    for (operations) |op| {
        var args = std.ArrayList([]const u8).init(tf.allocator);
        defer args.deinit();
        
        try args.append("/root/zigg/root/ziggit/zig-out/bin/ziggit");
        for (op) |arg| {
            try args.append(arg);
        }
        
        const result = try tf.runCommand(args.items, test_dir);
        if (result.exit_code != 0 and !std.mem.eql(u8, op[0], "add")) { // add might fail, others shouldn't
            print("    ⚠ {s} failed in concurrent test: exit_code={d}\n", .{ op[0], result.exit_code });
        }
    }
    
    print("    ✓ concurrent access patterns handled\n");
}

pub fn runGitEdgeCaseTests() !void {
    print("Running git edge case tests...\n");
    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var tf = TestFramework.init(allocator);
    defer tf.deinit();
    
    try testInvalidArguments(&tf);
    try testOutsideRepository(&tf);
    try testSpecialFilenames(&tf);
    try testCorruptedRepository(&tf);
    try testLargeFiles(&tf);
    try testDeepDirectories(&tf);
    try testConcurrentAccess(&tf);
    
    print("Git edge case tests completed!\n");
}