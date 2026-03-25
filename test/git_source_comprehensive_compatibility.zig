const std = @import("std");
const testing = std.testing;
const print = std.debug.print;
const Allocator = std.mem.Allocator;

// Comprehensive Git Source Compatibility Test Suite
// Based on git/git repository test patterns (t/t*.sh)
// Focus: Drop-in compatibility verification

const TestRunner = struct {
    allocator: Allocator,
    test_count: u32 = 0,
    pass_count: u32 = 0,
    fail_count: u32 = 0,
    ziggit_path: []const u8,
    git_path: []const u8,
    temp_base: []const u8,

    const Self = @This();

    pub fn init(allocator: Allocator) !Self {
        const timestamp = std.time.timestamp();
        const temp_base = try std.fmt.allocPrint(allocator, "/tmp/ziggit-git-compat-{d}", .{timestamp});
        try std.fs.cwd().makeDir(temp_base);

        // Get current working directory for absolute path to ziggit
        const cwd = std.fs.cwd().realpathAlloc(allocator, ".") catch "/root/ziggit";
        const ziggit_path = std.fmt.allocPrint(allocator, "{s}/zig-out/bin/ziggit", .{cwd}) catch "./zig-out/bin/ziggit";
        
        return Self{
            .allocator = allocator,
            .ziggit_path = ziggit_path,
            .git_path = "git",
            .temp_base = temp_base,
        };
    }

    pub fn deinit(self: *Self) void {
        std.fs.cwd().deleteTree(self.temp_base) catch {};
        self.allocator.free(self.temp_base);
    }

    pub fn createTestDir(self: *Self, name: []const u8) ![]u8 {
        const test_dir = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.temp_base, name });
        try std.fs.cwd().makeDir(test_dir);
        return test_dir;
    }

    pub fn runCmd(self: *Self, args: []const []const u8, cwd: []const u8) !CmdResult {
        var proc = std.process.Child.init(args, self.allocator);
        proc.cwd = cwd;
        proc.stdout_behavior = .Pipe;
        proc.stderr_behavior = .Pipe;

        try proc.spawn();

        const stdout = try proc.stdout.?.readToEndAlloc(self.allocator, 1024 * 1024);
        const stderr = try proc.stderr.?.readToEndAlloc(self.allocator, 1024 * 1024);
        const term = try proc.wait();
        
        const exit_code: u32 = switch (term) {
            .Exited => |code| code,
            else => 1,
        };

        return CmdResult{
            .stdout = stdout,
            .stderr = stderr,
            .exit_code = exit_code,
            .allocator = self.allocator,
        };
    }

    pub fn writeFile(self: *Self, dir: []const u8, filename: []const u8, content: []const u8) !void {
        const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir, filename });
        defer self.allocator.free(path);
        
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(content);
    }

    pub fn expectTest(self: *Self, name: []const u8, test_func: anytype) void {
        self.test_count += 1;
        print("  test {d}: {s}...", .{ self.test_count, name });
        
        test_func(self) catch |err| {
            print(" ❌ FAILED ({any})\n", .{err});
            self.fail_count += 1;
            return;
        };
        
        print(" ✅ ok\n", .{});
        self.pass_count += 1;
    }

    pub fn expectSuccess(self: *Self, description: []const u8, cmd: []const []const u8, cwd: []const u8) !void {
        _ = description;
        const result = try self.runCmd(cmd, cwd);
        defer result.deinit();
        
        if (result.exit_code != 0) {
            print("\n      Expected success, got exit code {d}\n", .{result.exit_code});
            print("      stderr: {s}\n", .{result.stderr});
            return error.TestFailed;
        }
    }

    pub fn expectFailure(self: *Self, description: []const u8, cmd: []const []const u8, cwd: []const u8) !void {
        _ = description;
        const result = try self.runCmd(cmd, cwd);
        defer result.deinit();
        
        if (result.exit_code == 0) {
            print("\n      Expected failure, got success\n", .{});
            print("      stdout: {s}\n", .{result.stdout});
            return error.TestFailed;
        }
    }

    pub fn expectOutputContains(self: *Self, result: *const CmdResult, pattern: []const u8) !void {
        _ = self;
        if (std.mem.indexOf(u8, result.stdout, pattern) == null and 
            std.mem.indexOf(u8, result.stderr, pattern) == null) {
            print("\n      Expected output to contain: '{s}'\n", .{pattern});
            print("      stdout: {s}\n", .{result.stdout});
            print("      stderr: {s}\n", .{result.stderr});
            return error.TestFailed;
        }
    }

    pub fn expectOutputEquals(self: *Self, actual: []const u8, expected: []const u8) !void {
        _ = self;
        if (!std.mem.eql(u8, std.mem.trim(u8, actual, " \t\n\r"), std.mem.trim(u8, expected, " \t\n\r"))) {
            print("\n      Output mismatch:\n", .{});
            print("      Expected: '{s}'\n", .{expected});
            print("      Actual: '{s}'\n", .{actual});
            return error.TestFailed;
        }
    }

    pub fn printSummary(self: *Self) void {
        print("\n=== Git Compatibility Test Results ===\n", .{});
        print("Total tests: {d}\n", .{self.test_count});
        print("Passed: {d}\n", .{self.pass_count});
        print("Failed: {d}\n", .{self.fail_count});
        
        if (self.fail_count == 0) {
            print("🎉 All tests passed! ziggit is git-compatible.\n", .{});
        } else {
            print("❌ Some tests failed. Compatibility issues found.\n", .{});
        }
    }
};

const CmdResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u32,
    allocator: Allocator,

    pub fn deinit(self: *const CmdResult) void {
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
    }
};

// Test Suite Implementation
// Based on git test patterns: t0001-init.sh, t2000-add.sh, t3000-commit.sh, etc.

pub fn runT0001InitTests(runner: *TestRunner) !void {
    print("\n=== t0001-init: Repository initialization tests ===\n", .{});

    // Test 1: Plain init
    runner.expectTest("plain init", struct {
        fn run(r: *TestRunner) !void {
            const test_dir = try r.createTestDir("t0001-plain");
            defer r.allocator.free(test_dir);

            const plain_dir = try std.fmt.allocPrint(r.allocator, "{s}/plain", .{test_dir});
            defer r.allocator.free(plain_dir);

            try r.expectSuccess("init plain repo", &[_][]const u8{ r.ziggit_path, "init", plain_dir }, test_dir);
            
            // Check .git directory structure
            const git_dir = try std.fmt.allocPrint(r.allocator, "{s}/.git", .{plain_dir});
            defer r.allocator.free(git_dir);
            
            // Verify basic structure
            _ = std.fs.cwd().openDir(git_dir, .{}) catch return error.TestFailed;
            _ = std.fs.cwd().openFile(try std.fmt.allocPrint(r.allocator, "{s}/config", .{git_dir}), .{}) catch return error.TestFailed;
            _ = std.fs.cwd().openDir(try std.fmt.allocPrint(r.allocator, "{s}/objects", .{git_dir}), .{}) catch return error.TestFailed;
            _ = std.fs.cwd().openDir(try std.fmt.allocPrint(r.allocator, "{s}/refs", .{git_dir}), .{}) catch return error.TestFailed;
        }
    }.run);

    // Test 2: Bare init
    runner.expectTest("bare init", struct {
        fn run(r: *TestRunner) !void {
            const test_dir = try r.createTestDir("t0001-bare");
            defer r.allocator.free(test_dir);

            const bare_dir = try std.fmt.allocPrint(r.allocator, "{s}/bare.git", .{test_dir});
            defer r.allocator.free(bare_dir);

            try r.expectSuccess("init bare repo", &[_][]const u8{ r.ziggit_path, "init", "--bare", bare_dir }, test_dir);
            
            // Bare repo should not have .git subdir, but should have git files directly
            _ = std.fs.cwd().openFile(try std.fmt.allocPrint(r.allocator, "{s}/config", .{bare_dir}), .{}) catch return error.TestFailed;
            _ = std.fs.cwd().openDir(try std.fmt.allocPrint(r.allocator, "{s}/objects", .{bare_dir}), .{}) catch return error.TestFailed;
            _ = std.fs.cwd().openDir(try std.fmt.allocPrint(r.allocator, "{s}/refs", .{bare_dir}), .{}) catch return error.TestFailed;
        }
    }.run);

    // Test 3: Re-init existing repository  
    runner.expectTest("re-init existing", struct {
        fn run(r: *TestRunner) !void {
            const test_dir = try r.createTestDir("t0001-reinit");
            defer r.allocator.free(test_dir);

            const repo_dir = try std.fmt.allocPrint(r.allocator, "{s}/repo", .{test_dir});
            defer r.allocator.free(repo_dir);

            try r.expectSuccess("initial init", &[_][]const u8{ r.ziggit_path, "init", repo_dir }, test_dir);
            // Re-init should succeed
            try r.expectSuccess("re-init", &[_][]const u8{ r.ziggit_path, "init", repo_dir }, test_dir);
        }
    }.run);
}

pub fn runT2000AddTests(runner: *TestRunner) !void {
    print("\n=== t2000-add: File staging tests ===\n", .{});

    // Test 1: Add new file
    runner.expectTest("add new file", struct {
        fn run(r: *TestRunner) !void {
            const test_dir = try r.createTestDir("t2000-add-new");
            defer r.allocator.free(test_dir);

            try r.expectSuccess("init", &[_][]const u8{ r.ziggit_path, "init" }, test_dir);
            try r.writeFile(test_dir, "test.txt", "Hello, World!");
            try r.expectSuccess("add file", &[_][]const u8{ r.ziggit_path, "add", "test.txt" }, test_dir);

            const result = try r.runCmd(&[_][]const u8{ r.ziggit_path, "status", "--porcelain" }, test_dir);
            defer result.deinit();
            try r.expectOutputContains(&result, "A  test.txt");
        }
    }.run);

    // Test 2: Add multiple files
    runner.expectTest("add multiple files", struct {
        fn run(r: *TestRunner) !void {
            const test_dir = try r.createTestDir("t2000-add-multiple");
            defer r.allocator.free(test_dir);

            try r.expectSuccess("init", &[_][]const u8{ r.ziggit_path, "init" }, test_dir);
            try r.writeFile(test_dir, "file1.txt", "File 1");
            try r.writeFile(test_dir, "file2.txt", "File 2");
            try r.expectSuccess("add files", &[_][]const u8{ r.ziggit_path, "add", "file1.txt", "file2.txt" }, test_dir);

            const result = try r.runCmd(&[_][]const u8{ r.ziggit_path, "status", "--porcelain" }, test_dir);
            defer result.deinit();
            try r.expectOutputContains(&result, "A  file1.txt");
            try r.expectOutputContains(&result, "A  file2.txt");
        }
    }.run);

    // Test 3: Add all files
    runner.expectTest("add all files", struct {
        fn run(r: *TestRunner) !void {
            const test_dir = try r.createTestDir("t2000-add-all");
            defer r.allocator.free(test_dir);

            try r.expectSuccess("init", &[_][]const u8{ r.ziggit_path, "init" }, test_dir);
            try r.writeFile(test_dir, "file1.txt", "File 1");
            try r.writeFile(test_dir, "file2.txt", "File 2");
            try r.expectSuccess("add all", &[_][]const u8{ r.ziggit_path, "add", "." }, test_dir);

            const result = try r.runCmd(&[_][]const u8{ r.ziggit_path, "status", "--porcelain" }, test_dir);
            defer result.deinit();
            try r.expectOutputContains(&result, "A  file1.txt");
            try r.expectOutputContains(&result, "A  file2.txt");
        }
    }.run);

    // Test 4: Add non-existent file should fail
    runner.expectTest("add non-existent file fails", struct {
        fn run(r: *TestRunner) !void {
            const test_dir = try r.createTestDir("t2000-add-missing");
            defer r.allocator.free(test_dir);

            try r.expectSuccess("init", &[_][]const u8{ r.ziggit_path, "init" }, test_dir);
            try r.expectFailure("add missing file", &[_][]const u8{ r.ziggit_path, "add", "missing.txt" }, test_dir);
        }
    }.run);
}

pub fn runT3000CommitTests(runner: *TestRunner) !void {
    print("\n=== t3000-commit: Commit creation tests ===\n", .{});

    // Test 1: Basic commit
    runner.expectTest("basic commit", struct {
        fn run(r: *TestRunner) !void {
            const test_dir = try r.createTestDir("t3000-basic-commit");
            defer r.allocator.free(test_dir);

            try r.expectSuccess("init", &[_][]const u8{ r.ziggit_path, "init" }, test_dir);
            try r.writeFile(test_dir, "test.txt", "Hello, World!");
            try r.expectSuccess("add", &[_][]const u8{ r.ziggit_path, "add", "test.txt" }, test_dir);
            try r.expectSuccess("commit", &[_][]const u8{ r.ziggit_path, "commit", "-m", "Initial commit" }, test_dir);

            const result = try r.runCmd(&[_][]const u8{ r.ziggit_path, "log", "--oneline" }, test_dir);
            defer result.deinit();
            try r.expectOutputContains(&result, "Initial commit");
        }
    }.run);

    // Test 2: Commit without message should fail
    runner.expectTest("commit without message fails", struct {
        fn run(r: *TestRunner) !void {
            const test_dir = try r.createTestDir("t3000-no-message");
            defer r.allocator.free(test_dir);

            try r.expectSuccess("init", &[_][]const u8{ r.ziggit_path, "init" }, test_dir);
            try r.writeFile(test_dir, "test.txt", "Hello, World!");
            try r.expectSuccess("add", &[_][]const u8{ r.ziggit_path, "add", "test.txt" }, test_dir);
            try r.expectFailure("commit no message", &[_][]const u8{ r.ziggit_path, "commit" }, test_dir);
        }
    }.run);

    // Test 3: Empty commit should fail
    runner.expectTest("empty commit fails", struct {
        fn run(r: *TestRunner) !void {
            const test_dir = try r.createTestDir("t3000-empty");
            defer r.allocator.free(test_dir);

            try r.expectSuccess("init", &[_][]const u8{ r.ziggit_path, "init" }, test_dir);
            try r.expectFailure("empty commit", &[_][]const u8{ r.ziggit_path, "commit", "-m", "Empty" }, test_dir);
        }
    }.run);

    // Test 4: Allow empty commit with flag
    runner.expectTest("allow empty commit", struct {
        fn run(r: *TestRunner) !void {
            const test_dir = try r.createTestDir("t3000-allow-empty");
            defer r.allocator.free(test_dir);

            try r.expectSuccess("init", &[_][]const u8{ r.ziggit_path, "init" }, test_dir);
            try r.expectSuccess("empty commit allowed", &[_][]const u8{ r.ziggit_path, "commit", "--allow-empty", "-m", "Empty commit" }, test_dir);

            const result = try r.runCmd(&[_][]const u8{ r.ziggit_path, "log", "--oneline" }, test_dir);
            defer result.deinit();
            try r.expectOutputContains(&result, "Empty commit");
        }
    }.run);
}

pub fn runT7000StatusTests(runner: *TestRunner) !void {
    print("\n=== t7000-status: Repository status tests ===\n", .{});

    // Test 1: Status in empty repository
    runner.expectTest("status empty repo", struct {
        fn run(r: *TestRunner) !void {
            const test_dir = try r.createTestDir("t7000-empty");
            defer r.allocator.free(test_dir);

            try r.expectSuccess("init", &[_][]const u8{ r.ziggit_path, "init" }, test_dir);
            
            const result = try r.runCmd(&[_][]const u8{ r.ziggit_path, "status" }, test_dir);
            defer result.deinit();
            try r.expectOutputContains(&result, "No commits yet");
        }
    }.run);

    // Test 2: Status with untracked files
    runner.expectTest("status untracked files", struct {
        fn run(r: *TestRunner) !void {
            const test_dir = try r.createTestDir("t7000-untracked");
            defer r.allocator.free(test_dir);

            try r.expectSuccess("init", &[_][]const u8{ r.ziggit_path, "init" }, test_dir);
            try r.writeFile(test_dir, "untracked.txt", "Untracked file");
            
            const result = try r.runCmd(&[_][]const u8{ r.ziggit_path, "status" }, test_dir);
            defer result.deinit();
            try r.expectOutputContains(&result, "untracked.txt");
        }
    }.run);

    // Test 3: Status with staged files
    runner.expectTest("status staged files", struct {
        fn run(r: *TestRunner) !void {
            const test_dir = try r.createTestDir("t7000-staged");
            defer r.allocator.free(test_dir);

            try r.expectSuccess("init", &[_][]const u8{ r.ziggit_path, "init" }, test_dir);
            try r.writeFile(test_dir, "staged.txt", "Staged file");
            try r.expectSuccess("add", &[_][]const u8{ r.ziggit_path, "add", "staged.txt" }, test_dir);
            
            const result = try r.runCmd(&[_][]const u8{ r.ziggit_path, "status" }, test_dir);
            defer result.deinit();
            try r.expectOutputContains(&result, "staged.txt");
        }
    }.run);

    // Test 4: Porcelain status format
    runner.expectTest("porcelain status", struct {
        fn run(r: *TestRunner) !void {
            const test_dir = try r.createTestDir("t7000-porcelain");
            defer r.allocator.free(test_dir);

            try r.expectSuccess("init", &[_][]const u8{ r.ziggit_path, "init" }, test_dir);
            try r.writeFile(test_dir, "staged.txt", "Staged");
            try r.writeFile(test_dir, "untracked.txt", "Untracked");
            try r.expectSuccess("add", &[_][]const u8{ r.ziggit_path, "add", "staged.txt" }, test_dir);
            
            const result = try r.runCmd(&[_][]const u8{ r.ziggit_path, "status", "--porcelain" }, test_dir);
            defer result.deinit();
            try r.expectOutputContains(&result, "A  staged.txt");
            try r.expectOutputContains(&result, "?? untracked.txt");
        }
    }.run);
}

pub fn runT4000LogTests(runner: *TestRunner) !void {
    print("\n=== t4000-log: Commit log tests ===\n", .{});

    // Test 1: Log with commits
    runner.expectTest("basic log", struct {
        fn run(r: *TestRunner) !void {
            const test_dir = try r.createTestDir("t4000-basic");
            defer r.allocator.free(test_dir);

            try r.expectSuccess("init", &[_][]const u8{ r.ziggit_path, "init" }, test_dir);
            try r.writeFile(test_dir, "file1.txt", "First");
            try r.expectSuccess("add", &[_][]const u8{ r.ziggit_path, "add", "file1.txt" }, test_dir);
            try r.expectSuccess("commit", &[_][]const u8{ r.ziggit_path, "commit", "-m", "First commit" }, test_dir);
            
            try r.writeFile(test_dir, "file2.txt", "Second");
            try r.expectSuccess("add", &[_][]const u8{ r.ziggit_path, "add", "file2.txt" }, test_dir);
            try r.expectSuccess("commit", &[_][]const u8{ r.ziggit_path, "commit", "-m", "Second commit" }, test_dir);

            const result = try r.runCmd(&[_][]const u8{ r.ziggit_path, "log", "--oneline" }, test_dir);
            defer result.deinit();
            try r.expectOutputContains(&result, "Second commit");
            try r.expectOutputContains(&result, "First commit");
        }
    }.run);

    // Test 2: Log in empty repository should fail
    runner.expectTest("log empty repo fails", struct {
        fn run(r: *TestRunner) !void {
            const test_dir = try r.createTestDir("t4000-empty");
            defer r.allocator.free(test_dir);

            try r.expectSuccess("init", &[_][]const u8{ r.ziggit_path, "init" }, test_dir);
            try r.expectFailure("log empty", &[_][]const u8{ r.ziggit_path, "log" }, test_dir);
        }
    }.run);
}

pub fn runT4001DiffTests(runner: *TestRunner) !void {
    print("\n=== t4001-diff: Diff tests ===\n", .{});

    // Test 1: Diff staged changes
    runner.expectTest("diff staged", struct {
        fn run(r: *TestRunner) !void {
            const test_dir = try r.createTestDir("t4001-staged");
            defer r.allocator.free(test_dir);

            try r.expectSuccess("init", &[_][]const u8{ r.ziggit_path, "init" }, test_dir);
            try r.writeFile(test_dir, "test.txt", "Hello, World!");
            try r.expectSuccess("add", &[_][]const u8{ r.ziggit_path, "add", "test.txt" }, test_dir);

            const result = try r.runCmd(&[_][]const u8{ r.ziggit_path, "diff", "--cached" }, test_dir);
            defer result.deinit();
            try r.expectOutputContains(&result, "+Hello, World!");
        }
    }.run);

    // Test 2: Diff working tree changes
    runner.expectTest("diff working tree", struct {
        fn run(r: *TestRunner) !void {
            const test_dir = try r.createTestDir("t4001-worktree");
            defer r.allocator.free(test_dir);

            try r.expectSuccess("init", &[_][]const u8{ r.ziggit_path, "init" }, test_dir);
            try r.writeFile(test_dir, "test.txt", "Original");
            try r.expectSuccess("add", &[_][]const u8{ r.ziggit_path, "add", "test.txt" }, test_dir);
            try r.expectSuccess("commit", &[_][]const u8{ r.ziggit_path, "commit", "-m", "Initial" }, test_dir);
            
            try r.writeFile(test_dir, "test.txt", "Modified");
            
            const result = try r.runCmd(&[_][]const u8{ r.ziggit_path, "diff" }, test_dir);
            defer result.deinit();
            try r.expectOutputContains(&result, "-Original");
            try r.expectOutputContains(&result, "+Modified");
        }
    }.run);
}

// Main test runner
pub fn runGitSourceCompatibilityTests(allocator: Allocator) !void {
    var runner = try TestRunner.init(allocator);
    defer runner.deinit();

    print("🔬 Git Source Compatibility Test Suite\n", .{});
    print("Testing drop-in compatibility with git commands\n", .{});
    print("ziggit: {s}\n", .{runner.ziggit_path});

    try runT0001InitTests(&runner);
    try runT2000AddTests(&runner);
    try runT3000CommitTests(&runner);
    try runT7000StatusTests(&runner);
    try runT4000LogTests(&runner);
    try runT4001DiffTests(&runner);

    runner.printSummary();
    
    if (runner.fail_count > 0) {
        std.process.exit(1);
    }
}

// Entry point for standalone execution
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try runGitSourceCompatibilityTests(allocator);
}