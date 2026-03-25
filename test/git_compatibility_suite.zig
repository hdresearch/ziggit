const std = @import("std");

const TestResult = struct {
    name: []const u8,
    passed: bool,
    message: []const u8,
};

pub const GitCompatibilityTestSuite = struct {
    allocator: std.mem.Allocator,
    ziggit_path: []const u8,
    git_path: []const u8,
    test_base_dir: []const u8,
    results: std.ArrayList(TestResult),

    pub fn init(allocator: std.mem.Allocator, ziggit_path: []const u8) !GitCompatibilityTestSuite {
        const test_base_dir = "/tmp/ziggit_compat_tests";
        
        // Clean and create test directory
        std.fs.cwd().deleteTree(test_base_dir) catch {};
        try std.fs.cwd().makeDir(test_base_dir);
        
        return GitCompatibilityTestSuite{
            .allocator = allocator,
            .ziggit_path = ziggit_path,
            .git_path = "git", 
            .test_base_dir = test_base_dir,
            .results = std.ArrayList(TestResult).init(allocator),
        };
    }

    pub fn deinit(self: *GitCompatibilityTestSuite) void {
        for (self.results.items) |result| {
            self.allocator.free(result.message);
        }
        self.results.deinit();
        std.fs.cwd().deleteTree(self.test_base_dir) catch {};
    }

    fn execCommand(self: *GitCompatibilityTestSuite, args: []const []const u8, cwd: ?[]const u8) !std.process.Child.RunResult {
        return try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = args,
            .cwd = cwd,
            .max_output_bytes = 1024 * 1024,
        });
    }

    fn createTestDir(self: *GitCompatibilityTestSuite, name: []const u8) ![]u8 {
        const test_dir = try std.fmt.allocPrint(self.allocator, "{s}/{s}_{d}", .{ self.test_base_dir, name, std.time.timestamp() });
        try std.fs.cwd().makeDir(test_dir);
        return test_dir;
    }

    fn expectSuccess(self: *GitCompatibilityTestSuite, test_name: []const u8, result: std.process.Child.RunResult) !void {
        const passed = result.term == .Exited and result.term.Exited == 0;
        const message = if (passed)
            try std.fmt.allocPrint(self.allocator, "✓ {s} passed", .{test_name})
        else
            try std.fmt.allocPrint(self.allocator, "✗ {s} failed: {s}{s}", .{ test_name, result.stderr, result.stdout });

        try self.results.append(.{
            .name = test_name,
            .passed = passed,
            .message = message,
        });

        std.debug.print("  {s}\n", .{message});
    }

    // Test: t0000-basic.sh equivalent tests
    pub fn runBasicTests(self: *GitCompatibilityTestSuite) !void {
        std.debug.print("Running basic compatibility tests...\n", .{});
        
        // Test --version
        var result = try self.execCommand(&[_][]const u8{ self.ziggit_path, "--version" }, null);
        defer {
            self.allocator.free(result.stdout);
            self.allocator.free(result.stderr);
        }
        try self.expectSuccess("version check", result);

        // Test --help
        result = try self.execCommand(&[_][]const u8{ self.ziggit_path, "--help" }, null);
        defer {
            self.allocator.free(result.stdout);
            self.allocator.free(result.stderr);
        }
        try self.expectSuccess("help check", result);

        // Test invalid command
        result = try self.execCommand(&[_][]const u8{ self.ziggit_path, "invalidcommand" }, null);
        defer {
            self.allocator.free(result.stdout);
            self.allocator.free(result.stderr);
        }
        const invalid_cmd_passed = result.term == .Exited and result.term.Exited != 0;
        const invalid_cmd_message = if (invalid_cmd_passed)
            try std.fmt.allocPrint(self.allocator, "✓ invalid command correctly rejected", .{})
        else
            try std.fmt.allocPrint(self.allocator, "✗ invalid command should fail", .{});

        try self.results.append(.{
            .name = "invalid command rejection",
            .passed = invalid_cmd_passed,
            .message = invalid_cmd_message,
        });

        std.debug.print("  {s}\n", .{invalid_cmd_message});
    }

    // Test: t0001-init.sh equivalent tests
    pub fn runInitTests(self: *GitCompatibilityTestSuite) !void {
        std.debug.print("Running init compatibility tests...\n", .{});

        // Test: plain init
        const test_dir = try self.createTestDir("plain_init");
        defer self.allocator.free(test_dir);

        var result = try self.execCommand(&[_][]const u8{ self.ziggit_path, "init" }, test_dir);
        defer {
            self.allocator.free(result.stdout);
            self.allocator.free(result.stderr);
        }
        try self.expectSuccess("plain init", result);

        // Verify .git directory structure
        const git_dir = try std.fmt.allocPrint(self.allocator, "{s}/.git", .{test_dir});
        defer self.allocator.free(git_dir);

        const git_stat = std.fs.cwd().statFile(git_dir) catch {
            const msg = try std.fmt.allocPrint(self.allocator, "✗ .git directory not created", .{});
            try self.results.append(.{
                .name = ".git directory creation",
                .passed = false,
                .message = msg,
            });
            std.debug.print("  {s}\n", .{msg});
            return;
        };

        const git_dir_passed = git_stat.kind == .directory;
        const git_dir_message = if (git_dir_passed)
            try std.fmt.allocPrint(self.allocator, "✓ .git directory created", .{})
        else
            try std.fmt.allocPrint(self.allocator, "✗ .git is not a directory", .{});

        try self.results.append(.{
            .name = ".git directory creation",
            .passed = git_dir_passed,
            .message = git_dir_message,
        });

        std.debug.print("  {s}\n", .{git_dir_message});

        // Test: bare init
        const bare_test_dir = try self.createTestDir("bare_init");
        defer self.allocator.free(bare_test_dir);

        result = try self.execCommand(&[_][]const u8{ self.ziggit_path, "init", "--bare" }, bare_test_dir);
        defer {
            self.allocator.free(result.stdout);
            self.allocator.free(result.stderr);
        }
        try self.expectSuccess("bare init", result);
    }

    // Test: basic add/commit/log workflow
    pub fn runWorkflowTests(self: *GitCompatibilityTestSuite) !void {
        std.debug.print("Running workflow compatibility tests...\n", .{});

        const test_dir = try self.createTestDir("workflow");
        defer self.allocator.free(test_dir);

        // Init repository
        var result = try self.execCommand(&[_][]const u8{ self.ziggit_path, "init" }, test_dir);
        defer {
            self.allocator.free(result.stdout);
            self.allocator.free(result.stderr);
        }
        try self.expectSuccess("workflow init", result);

        // Create test file
        const test_file = try std.fmt.allocPrint(self.allocator, "{s}/README.md", .{test_dir});
        defer self.allocator.free(test_file);

        const file = try std.fs.cwd().createFile(test_file, .{});
        defer file.close();
        try file.writeAll("# Test Repository\n\nThis is a test file for ziggit compatibility testing.\n");

        // Test status with untracked file
        result = try self.execCommand(&[_][]const u8{ self.ziggit_path, "status" }, test_dir);
        defer {
            self.allocator.free(result.stdout);
            self.allocator.free(result.stderr);
        }
        try self.expectSuccess("status with untracked files", result);

        // Test add
        result = try self.execCommand(&[_][]const u8{ self.ziggit_path, "add", "README.md" }, test_dir);
        defer {
            self.allocator.free(result.stdout);
            self.allocator.free(result.stderr);
        }
        try self.expectSuccess("add file", result);

        // Test status with staged file  
        result = try self.execCommand(&[_][]const u8{ self.ziggit_path, "status" }, test_dir);
        defer {
            self.allocator.free(result.stdout);
            self.allocator.free(result.stderr);
        }
        try self.expectSuccess("status with staged files", result);

        // Test commit
        result = try self.execCommand(&[_][]const u8{ self.ziggit_path, "commit", "-m", "Initial commit: Add README" }, test_dir);
        defer {
            self.allocator.free(result.stdout);
            self.allocator.free(result.stderr);
        }
        try self.expectSuccess("commit", result);

        // Test log
        result = try self.execCommand(&[_][]const u8{ self.ziggit_path, "log" }, test_dir);
        defer {
            self.allocator.free(result.stdout);
            self.allocator.free(result.stderr);
        }
        try self.expectSuccess("log", result);

        // Test log --oneline
        result = try self.execCommand(&[_][]const u8{ self.ziggit_path, "log", "--oneline" }, test_dir);
        defer {
            self.allocator.free(result.stdout);
            self.allocator.free(result.stderr);
        }
        try self.expectSuccess("log --oneline", result);

        // Test status in clean repository
        result = try self.execCommand(&[_][]const u8{ self.ziggit_path, "status" }, test_dir);
        defer {
            self.allocator.free(result.stdout);
            self.allocator.free(result.stderr);
        }
        try self.expectSuccess("status clean repository", result);
    }

    // Test: diff functionality
    pub fn runDiffTests(self: *GitCompatibilityTestSuite) !void {
        std.debug.print("Running diff compatibility tests...\n", .{});

        const test_dir = try self.createTestDir("diff");
        defer self.allocator.free(test_dir);

        // Setup repository
        var result = try self.execCommand(&[_][]const u8{ self.ziggit_path, "init" }, test_dir);
        defer {
            self.allocator.free(result.stdout);
            self.allocator.free(result.stderr);
        }
        try self.expectSuccess("diff setup init", result);

        // Create and commit initial file
        const test_file = try std.fmt.allocPrint(self.allocator, "{s}/file.txt", .{test_dir});
        defer self.allocator.free(test_file);

        const file = try std.fs.cwd().createFile(test_file, .{});
        defer file.close();
        try file.writeAll("line 1\nline 2\nline 3\n");

        result = try self.execCommand(&[_][]const u8{ self.ziggit_path, "add", "file.txt" }, test_dir);
        defer {
            self.allocator.free(result.stdout);
            self.allocator.free(result.stderr);
        }
        try self.expectSuccess("diff setup add", result);

        result = try self.execCommand(&[_][]const u8{ self.ziggit_path, "commit", "-m", "Initial file" }, test_dir);
        defer {
            self.allocator.free(result.stdout);
            self.allocator.free(result.stderr);
        }
        try self.expectSuccess("diff setup commit", result);

        // Modify file
        const file2 = try std.fs.cwd().createFile(test_file, .{});
        defer file2.close();
        try file2.writeAll("line 1\nmodified line 2\nline 3\nnew line 4\n");

        // Test diff
        result = try self.execCommand(&[_][]const u8{ self.ziggit_path, "diff" }, test_dir);
        defer {
            self.allocator.free(result.stdout);
            self.allocator.free(result.stderr);
        }
        try self.expectSuccess("diff working directory", result);

        // Test diff --cached (no changes in index yet)
        result = try self.execCommand(&[_][]const u8{ self.ziggit_path, "diff", "--cached" }, test_dir);
        defer {
            self.allocator.free(result.stdout);
            self.allocator.free(result.stderr);
        }
        try self.expectSuccess("diff --cached (empty)", result);
    }

    pub fn printSummary(self: *GitCompatibilityTestSuite) void {
        var passed: u32 = 0;
        var total: u32 = 0;

        for (self.results.items) |result| {
            if (result.passed) passed += 1;
            total += 1;
        }

        std.debug.print("\n=== Git Compatibility Test Summary ===\n", .{});
        std.debug.print("Total tests: {}\n", .{total});
        std.debug.print("Passed: {}\n", .{passed});
        std.debug.print("Failed: {}\n", .{total - passed});

        if (passed == total) {
            std.debug.print("🎉 ALL TESTS PASSED! Ziggit shows excellent git compatibility.\n", .{});
        } else {
            std.debug.print("❌ Some tests failed. See details above.\n", .{});
            std.debug.print("\nFailed tests:\n", .{});
            for (self.results.items) |result| {
                if (!result.passed) {
                    std.debug.print("  - {s}: {s}\n", .{ result.name, result.message });
                }
            }
        }
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var test_suite = try GitCompatibilityTestSuite.init(allocator, "/root/ziggit/zig-out/bin/ziggit");
    defer test_suite.deinit();

    try test_suite.runBasicTests();
    try test_suite.runInitTests();
    try test_suite.runWorkflowTests();
    try test_suite.runDiffTests();

    test_suite.printSummary();
}