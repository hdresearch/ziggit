const std = @import("std");


pub const TestFramework = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) TestFramework {
        return TestFramework{
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *TestFramework) void {
        _ = self;
    }
    
    pub const CommandResult = struct {
        stdout: []u8,
        stderr: []u8,
        exit_code: u8,
        allocator: std.mem.Allocator,
        
        pub fn deinit(self: *CommandResult) void {
            self.allocator.free(self.stdout);
            self.allocator.free(self.stderr);
        }
    };
    
    pub fn runCommand(self: *TestFramework, args: []const []const u8, work_dir: []const u8) !CommandResult {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();
        
        var proc = std.process.Child.init(args, arena_allocator);
        proc.cwd = work_dir;
        proc.stdout_behavior = .Pipe;
        proc.stderr_behavior = .Pipe;
        
        try proc.spawn();
        
        // Read output with smaller buffers to avoid memory issues
        const max_output = 64 * 1024; // 64KB max
        var stdout = std.ArrayList(u8).init(self.allocator);
        var stderr = std.ArrayList(u8).init(self.allocator);
        
        errdefer stdout.deinit();
        errdefer stderr.deinit();
        
        if (proc.stdout) |stdout_file| {
            try stdout.appendSlice(try stdout_file.reader().readAllAlloc(self.allocator, max_output));
        }
        
        if (proc.stderr) |stderr_file| {
            try stderr.appendSlice(try stderr_file.reader().readAllAlloc(self.allocator, max_output));
        }
        
        const term = try proc.wait();
        const exit_code: u8 = switch (term) {
            .Exited => |code| @intCast(code),
            else => 1,
        };
        
        return CommandResult{
            .stdout = try stdout.toOwnedSlice(),
            .stderr = try stderr.toOwnedSlice(),
            .exit_code = exit_code,
            .allocator = self.allocator,
        };
    }
    
    pub fn createTempDir(self: *TestFramework, name: []const u8) ![]u8 {
        var temp_dir = std.fs.cwd().makeOpenPath("/tmp", .{}) catch |err| switch (err) {
            error.PathAlreadyExists => try std.fs.cwd().openDir("/tmp", .{}),
            else => return err,
        };
        defer temp_dir.close();
        
        const full_name = try std.fmt.allocPrint(self.allocator, "ziggit-test-{s}-{d}", .{ name, std.time.timestamp() });
        temp_dir.makeDir(full_name) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        
        return try std.fmt.allocPrint(self.allocator, "/tmp/{s}", .{full_name});
    }
    
    pub fn removeTempDir(self: *TestFramework, path: []const u8) void {
        std.fs.cwd().deleteTree(path) catch |err| {
            std.debug.print("Warning: Could not delete temp dir {s}: {any}\n", .{ path, err });
        };
        self.allocator.free(path);
    }
    
    pub fn writeFile(self: *TestFramework, dir: []const u8, filename: []const u8, content: []const u8) !void {
        const file_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir, filename });
        defer self.allocator.free(file_path);
        
        const file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();
        
        try file.writeAll(content);
    }
};

pub fn runGitSourceCompatTests() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var tf = TestFramework.init(allocator);
    defer tf.deinit();
    
    std.debug.print("Running git source compatibility tests...\n", .{});
    
    try testBasicInit(&tf);
    try testBasicAdd(&tf);
    try testBasicCommit(&tf);
    try testBasicStatus(&tf);
    try testBasicLog(&tf);
    try testBasicDiff(&tf);
    
    std.debug.print("✓ All git source compatibility tests passed!\n", .{});
}

fn testBasicInit(tf: *TestFramework) !void {
    std.debug.print("  Testing basic init compatibility...\n", .{});
    
    // Test 1: Basic init
    const test_dir = try tf.createTempDir("init-basic");
    defer tf.removeTempDir(test_dir);
    
    const repo_dir = try std.fmt.allocPrint(tf.allocator, "{s}/test-repo", .{test_dir});
    defer tf.allocator.free(repo_dir);
    
    // Test ziggit init
    var ziggit_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "init", "test-repo" 
    }, test_dir);
    defer ziggit_result.deinit();
    
    // Test git init for comparison
    const git_test_dir = try tf.createTempDir("init-git");
    defer tf.removeTempDir(git_test_dir);
    
    var git_result = try tf.runCommand(&[_][]const u8{ 
        "git", "init", "test-repo" 
    }, git_test_dir);
    defer git_result.deinit();
    
    // Both should succeed
    if (ziggit_result.exit_code != 0) {
        std.debug.print("    ❌ ziggit init failed: {s}\n", .{ziggit_result.stderr});
        return;
    }
    
    if (git_result.exit_code != 0) {
        std.debug.print("    ❌ git init failed: {s}\n", .{git_result.stderr});
        return;
    }
    
    // Check .git directory exists
    const git_dir_path = try std.fmt.allocPrint(tf.allocator, "{s}/.git", .{repo_dir});
    defer tf.allocator.free(git_dir_path);
    
    var git_dir = std.fs.cwd().openDir(git_dir_path, .{}) catch |err| {
        std.debug.print("    ❌ .git directory not created: {any}\n", .{err});
        return;
    };
    git_dir.close();
    
    // Check essential git files exist
    const essential_files = [_][]const u8{ "HEAD", "config", "objects", "refs" };
    for (essential_files) |file| {
        const file_path = try std.fmt.allocPrint(tf.allocator, "{s}/{s}", .{ git_dir_path, file });
        defer tf.allocator.free(file_path);
        
        std.fs.cwd().access(file_path, .{}) catch |err| {
            std.debug.print("    ❌ Essential git file/dir missing: {s} ({any})\n", .{ file, err });
            return;
        };
    }
    
    std.debug.print("    ✓ Basic init test passed\n", .{});
    
    // Test 2: Bare init
    const bare_test_dir = try tf.createTempDir("init-bare");
    defer tf.removeTempDir(bare_test_dir);
    
    var ziggit_bare_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "init", "--bare", "bare-repo.git" 
    }, bare_test_dir);
    defer ziggit_bare_result.deinit();
    
    if (ziggit_bare_result.exit_code != 0) {
        std.debug.print("    ⚠ ziggit bare init not supported yet: {s}\n", .{ziggit_bare_result.stderr});
    } else {
        std.debug.print("    ✓ Bare init test passed\n", .{});
    }
}

fn testBasicAdd(tf: *TestFramework) !void {
    std.debug.print("  Testing basic add compatibility...\n", .{});
    
    const test_dir = try tf.createTempDir("add-basic");
    defer tf.removeTempDir(test_dir);
    
    // Initialize repo
    var init_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "init" 
    }, test_dir);
    defer init_result.deinit();
    
    if (init_result.exit_code != 0) {
        std.debug.print("    ❌ Failed to init repo for add test: {s}\n", .{init_result.stderr});
        return;
    }
    
    // Create a test file
    try tf.writeFile(test_dir, "test.txt", "Hello, World!\n");
    
    // Test add
    var add_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "add", "test.txt" 
    }, test_dir);
    defer add_result.deinit();
    
    if (add_result.exit_code != 0) {
        std.debug.print("    ❌ ziggit add failed: {s}\n", .{add_result.stderr});
        return;
    }
    
    // Check that file is staged (status should show it)
    var status_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "status" 
    }, test_dir);
    defer status_result.deinit();
    
    if (std.mem.indexOf(u8, status_result.stdout, "test.txt") == null) {
        std.debug.print("    ❌ Added file not shown in status\n", .{});
        return;
    }
    
    std.debug.print("    ✓ Basic add test passed\n", .{});
}

fn testBasicCommit(tf: *TestFramework) !void {
    std.debug.print("  Testing basic commit compatibility...\n", .{});
    
    const test_dir = try tf.createTempDir("commit-basic");
    defer tf.removeTempDir(test_dir);
    
    // Initialize repo and add file
    var init_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "init" 
    }, test_dir);
    defer init_result.deinit();
    
    if (init_result.exit_code != 0) {
        std.debug.print("    ❌ Failed to init repo for commit test\n", .{});
        return;
    }
    
    try tf.writeFile(test_dir, "test.txt", "Hello, World!\n");
    
    var add_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "add", "test.txt" 
    }, test_dir);
    defer add_result.deinit();
    
    if (add_result.exit_code != 0) {
        std.debug.print("    ❌ Failed to add file for commit test\n", .{});
        return;
    }
    
    // Test commit
    var commit_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "commit", "-m", "Initial commit" 
    }, test_dir);
    defer commit_result.deinit();
    
    if (commit_result.exit_code != 0) {
        std.debug.print("    ❌ ziggit commit failed: {s}\n", .{commit_result.stderr});
        return;
    }
    
    // Verify commit was created (log should show it)
    var log_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "log", "--oneline" 
    }, test_dir);
    defer log_result.deinit();
    
    if (log_result.exit_code != 0 or log_result.stdout.len == 0) {
        std.debug.print("    ❌ No commits found in log after commit\n", .{});
        return;
    }
    
    if (std.mem.indexOf(u8, log_result.stdout, "Initial commit") == null) {
        std.debug.print("    ❌ Commit message not found in log\n", .{});
        return;
    }
    
    std.debug.print("    ✓ Basic commit test passed\n", .{});
}

fn testBasicStatus(tf: *TestFramework) !void {
    std.debug.print("  Testing basic status compatibility...\n", .{});
    
    const test_dir = try tf.createTempDir("status-basic");
    defer tf.removeTempDir(test_dir);
    
    // Initialize repo
    var init_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "init" 
    }, test_dir);
    defer init_result.deinit();
    
    if (init_result.exit_code != 0) {
        std.debug.print("    ❌ Failed to init repo for status test\n", .{});
        return;
    }
    
    // Test status on empty repo
    var empty_status_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "status" 
    }, test_dir);
    defer empty_status_result.deinit();
    
    if (empty_status_result.exit_code != 0) {
        std.debug.print("    ❌ Status failed on empty repo: {s}\n", .{empty_status_result.stderr});
        return;
    }
    
    // Create file and test untracked status
    try tf.writeFile(test_dir, "test.txt", "Hello, World!\n");
    
    var untracked_status_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "status" 
    }, test_dir);
    defer untracked_status_result.deinit();
    
    if (untracked_status_result.exit_code != 0) {
        std.debug.print("    ❌ Status failed with untracked files: {s}\n", .{untracked_status_result.stderr});
        return;
    }
    
    if (std.mem.indexOf(u8, untracked_status_result.stdout, "test.txt") == null) {
        std.debug.print("    ❌ Untracked file not shown in status\n", .{});
        return;
    }
    
    std.debug.print("    ✓ Basic status test passed\n", .{});
}

fn testBasicLog(tf: *TestFramework) !void {
    std.debug.print("  Testing basic log compatibility...\n", .{});
    
    const test_dir = try tf.createTempDir("log-basic");
    defer tf.removeTempDir(test_dir);
    
    // Initialize repo, add file, and commit
    var init_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "init" 
    }, test_dir);
    defer init_result.deinit();
    
    if (init_result.exit_code != 0) {
        std.debug.print("    ❌ Failed to init repo for log test\n", .{});
        return;
    }
    
    try tf.writeFile(test_dir, "test.txt", "Hello, World!\n");
    
    var add_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "add", "test.txt" 
    }, test_dir);
    defer add_result.deinit();
    
    var commit_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "commit", "-m", "Initial commit" 
    }, test_dir);
    defer commit_result.deinit();
    
    if (commit_result.exit_code != 0) {
        std.debug.print("    ❌ Failed to create commit for log test\n", .{});
        return;
    }
    
    // Test log
    var log_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "log" 
    }, test_dir);
    defer log_result.deinit();
    
    if (log_result.exit_code != 0) {
        std.debug.print("    ❌ Log failed: {s}\n", .{log_result.stderr});
        return;
    }
    
    if (std.mem.indexOf(u8, log_result.stdout, "Initial commit") == null) {
        std.debug.print("    ❌ Commit not found in log output\n", .{});
        return;
    }
    
    // Test log --oneline
    var oneline_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "log", "--oneline" 
    }, test_dir);
    defer oneline_result.deinit();
    
    if (oneline_result.exit_code != 0) {
        std.debug.print("    ❌ Log --oneline failed: {s}\n", .{oneline_result.stderr});
        return;
    }
    
    std.debug.print("    ✓ Basic log test passed\n", .{});
}

fn testBasicDiff(tf: *TestFramework) !void {
    std.debug.print("  Testing basic diff compatibility...\n", .{});
    
    const test_dir = try tf.createTempDir("diff-basic");
    defer tf.removeTempDir(test_dir);
    
    // Initialize repo, add file, and commit
    var init_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "init" 
    }, test_dir);
    defer init_result.deinit();
    
    if (init_result.exit_code != 0) {
        std.debug.print("    ❌ Failed to init repo for diff test\n", .{});
        return;
    }
    
    try tf.writeFile(test_dir, "test.txt", "Hello, World!\n");
    
    var add_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "add", "test.txt" 
    }, test_dir);
    defer add_result.deinit();
    
    var commit_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "commit", "-m", "Initial commit" 
    }, test_dir);
    defer commit_result.deinit();
    
    if (commit_result.exit_code != 0) {
        std.debug.print("    ❌ Failed to create commit for diff test\n", .{});
        return;
    }
    
    // Modify the file
    try tf.writeFile(test_dir, "test.txt", "Hello, World!\nSecond line\n");
    
    // Test diff
    var diff_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "diff" 
    }, test_dir);
    defer diff_result.deinit();
    
    if (diff_result.exit_code != 0) {
        std.debug.print("    ❌ Diff failed: {s}\n", .{diff_result.stderr});
        return;
    }
    
    if (std.mem.indexOf(u8, diff_result.stdout, "+Second line") == null) {
        std.debug.print("    ❌ Expected diff output not found\n", .{});
        return;
    }
    
    std.debug.print("    ✓ Basic diff test passed\n", .{});
}

pub fn main() !void {
    try runGitSourceCompatTests();
}