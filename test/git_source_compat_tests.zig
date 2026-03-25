const std = @import("std");
const testing = std.testing;
const Process = std.process;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const fs = std.fs;

// Test structure inspired by git's own test suite (t/ directory)
// Focuses on exact compatibility with git behavior

pub const TestResult = struct {
    name: []const u8,
    passed: bool,
    details: ?[]const u8,
    allocator: Allocator,
    
    pub fn deinit(self: *TestResult) void {
        if (self.details) |details| {
            self.allocator.free(details);
        }
    }
};

pub const GitSourceCompatTests = struct {
    allocator: Allocator,
    ziggit_path: []const u8,
    git_path: []const u8,
    
    pub fn init(allocator: Allocator) GitSourceCompatTests {
        return GitSourceCompatTests{
            .allocator = allocator,
            .ziggit_path = "./zig-out/bin/ziggit",
            .git_path = "git",
        };
    }
    
    pub fn runCommand(self: GitSourceCompatTests, command: []const u8, args: []const []const u8, cwd: ?[]const u8) !struct {
        stdout: []u8,
        stderr: []u8,
        exit_code: u8,
    } {
        var argv = ArrayList([]const u8).init(self.allocator);
        defer argv.deinit();
        try argv.append(command);
        for (args) |arg| {
            try argv.append(arg);
        }
        
        var proc = Process.Child.init(argv.items, self.allocator);
        proc.stdout_behavior = .Pipe;
        proc.stderr_behavior = .Pipe;
        
        if (cwd) |dir| {
            proc.cwd = dir;
        }
        
        try proc.spawn();
        
        const stdout = try proc.stdout.?.reader().readAllAlloc(self.allocator, 1024 * 1024);
        const stderr = try proc.stderr.?.reader().readAllAlloc(self.allocator, 1024 * 1024);
        
        const result = try proc.wait();
        const exit_code: u8 = switch (result) {
            .Exited => |code| @intCast(code),
            .Signal => 128,
            .Stopped => 128,
            .Unknown => 128,
        };
        
        return .{
            .stdout = stdout,
            .stderr = stderr,
            .exit_code = exit_code,
        };
    }
    
    pub fn setupTestRepo(self: GitSourceCompatTests, dir_name: []const u8) !void {
        // Create test directory
        fs.cwd().makeDir(dir_name) catch {};
        
        // Initialize with git first for comparison baseline
        const git_result = try self.runCommand(self.git_path, &[_][]const u8{"init"}, dir_name);
        defer self.allocator.free(git_result.stdout);
        defer self.allocator.free(git_result.stderr);
    }
    
    pub fn cleanupTestRepo(_: GitSourceCompatTests, dir_name: []const u8) void {
        fs.cwd().deleteTree(dir_name) catch {};
    }
    
    // Test inspired by t0001-init.sh: plain init
    pub fn testInitPlain(self: GitSourceCompatTests) !TestResult {
        const test_dir = "test-init-plain";
        defer self.cleanupTestRepo(test_dir);
        
        // Clean start
        self.cleanupTestRepo(test_dir);
        
        // Test ziggit init
        const ziggit_result = try self.runCommand(self.ziggit_path, &[_][]const u8{"init", test_dir}, null);
        defer self.allocator.free(ziggit_result.stdout);
        defer self.allocator.free(ziggit_result.stderr);
        
        // Test git init for comparison
        const test_dir_git = "test-init-plain-git";
        defer self.cleanupTestRepo(test_dir_git);
        self.cleanupTestRepo(test_dir_git);
        
        const git_result = try self.runCommand(self.git_path, &[_][]const u8{"init", test_dir_git}, null);
        defer self.allocator.free(git_result.stdout);
        defer self.allocator.free(git_result.stderr);
        
        // Check exit codes match
        if (ziggit_result.exit_code != git_result.exit_code) {
            const details = try std.fmt.allocPrint(self.allocator, 
                "Exit codes differ: ziggit={}, git={}", 
                .{ziggit_result.exit_code, git_result.exit_code});
            return TestResult{
                .name = "init plain",
                .passed = false,
                .details = details,
                .allocator = self.allocator,
            };
        }
        
        // Check that .git directory structure is created correctly
        const git_dir_exists = blk: {
            fs.cwd().access(test_dir ++ "/.git", .{}) catch break :blk false;
            break :blk true;
        };
        if (!git_dir_exists) {
            const details = try self.allocator.dupe(u8, ".git directory not created");
            return TestResult{
                .name = "init plain",
                .passed = false,
                .details = details,
                .allocator = self.allocator,
            };
        }
        
        return TestResult{
            .name = "init plain",
            .passed = true,
            .details = null,
            .allocator = self.allocator,
        };
    }
    
    // Test inspired by git add behavior - adding non-existent files
    pub fn testAddNonExistent(self: GitSourceCompatTests) !TestResult {
        const test_dir = "test-add-nonexistent";
        defer self.cleanupTestRepo(test_dir);
        
        try self.setupTestRepo(test_dir);
        
        // Test adding non-existent file with ziggit
        const ziggit_result = try self.runCommand(self.ziggit_path, &[_][]const u8{"add", "nonexistent.txt"}, test_dir);
        defer self.allocator.free(ziggit_result.stdout);
        defer self.allocator.free(ziggit_result.stderr);
        
        // Test adding non-existent file with git  
        const test_dir_git = "test-add-nonexistent-git";
        defer self.cleanupTestRepo(test_dir_git);
        try self.setupTestRepo(test_dir_git);
        
        const git_result = try self.runCommand(self.git_path, &[_][]const u8{"add", "nonexistent.txt"}, test_dir_git);
        defer self.allocator.free(git_result.stdout);
        defer self.allocator.free(git_result.stderr);
        
        // Both should fail with same exit code
        if (ziggit_result.exit_code != git_result.exit_code) {
            const details = try std.fmt.allocPrint(self.allocator,
                "Exit codes differ for nonexistent file: ziggit={}, git={}",
                .{ziggit_result.exit_code, git_result.exit_code});
            return TestResult{
                .name = "add nonexistent file",
                .passed = false,
                .details = details,
                .allocator = self.allocator,
            };
        }
        
        // Both should fail (non-zero exit code)
        if (ziggit_result.exit_code == 0 or git_result.exit_code == 0) {
            const details = try self.allocator.dupe(u8, "Adding nonexistent file should fail");
            return TestResult{
                .name = "add nonexistent file",
                .passed = false,
                .details = details,
                .allocator = self.allocator,
            };
        }
        
        return TestResult{
            .name = "add nonexistent file",
            .passed = true,
            .details = null,
            .allocator = self.allocator,
        };
    }
    
    // Test commit behavior with nothing to commit
    pub fn testCommitNothing(self: GitSourceCompatTests) !TestResult {
        const test_dir = "test-commit-nothing";
        defer self.cleanupTestRepo(test_dir);
        
        try self.setupTestRepo(test_dir);
        
        // Test commit with nothing staged (ziggit)
        const ziggit_result = try self.runCommand(self.ziggit_path, &[_][]const u8{"commit", "-m", "test commit"}, test_dir);
        defer self.allocator.free(ziggit_result.stdout);
        defer self.allocator.free(ziggit_result.stderr);
        
        // Test commit with nothing staged (git)
        const test_dir_git = "test-commit-nothing-git";
        defer self.cleanupTestRepo(test_dir_git);
        try self.setupTestRepo(test_dir_git);
        
        const git_result = try self.runCommand(self.git_path, &[_][]const u8{"commit", "-m", "test commit"}, test_dir_git);
        defer self.allocator.free(git_result.stdout);
        defer self.allocator.free(git_result.stderr);
        
        // Both should fail with similar exit codes
        if (ziggit_result.exit_code == 0 or git_result.exit_code == 0) {
            const details = try std.fmt.allocPrint(self.allocator,
                "Commit with nothing staged should fail: ziggit={}, git={}",
                .{ziggit_result.exit_code, git_result.exit_code});
            return TestResult{
                .name = "commit nothing to commit",
                .passed = false,
                .details = details,
                .allocator = self.allocator,
            };
        }
        
        return TestResult{
            .name = "commit nothing to commit",
            .passed = true,
            .details = null,
            .allocator = self.allocator,
        };
    }
    
    // Test status output format matching
    pub fn testStatusFormat(self: GitSourceCompatTests) !TestResult {
        const test_dir = "test-status-format";
        defer self.cleanupTestRepo(test_dir);
        
        try self.setupTestRepo(test_dir);
        
        // Create a test file
        const file_content = "test content\n";
        try fs.cwd().writeFile(.{ .sub_path = test_dir ++ "/test.txt", .data = file_content });
        
        // Get ziggit status
        const ziggit_result = try self.runCommand(self.ziggit_path, &[_][]const u8{"status"}, test_dir);
        defer self.allocator.free(ziggit_result.stdout);
        defer self.allocator.free(ziggit_result.stderr);
        
        // Get git status for comparison  
        const test_dir_git = "test-status-format-git";
        defer self.cleanupTestRepo(test_dir_git);
        try self.setupTestRepo(test_dir_git);
        try fs.cwd().writeFile(.{ .sub_path = test_dir_git ++ "/test.txt", .data = file_content });
        
        const git_result = try self.runCommand(self.git_path, &[_][]const u8{"status"}, test_dir_git);
        defer self.allocator.free(git_result.stdout);
        defer self.allocator.free(git_result.stderr);
        
        // Exit codes should match
        if (ziggit_result.exit_code != git_result.exit_code) {
            const details = try std.fmt.allocPrint(self.allocator,
                "Status exit codes differ: ziggit={}, git={}",
                .{ziggit_result.exit_code, git_result.exit_code});
            return TestResult{
                .name = "status format",
                .passed = false,
                .details = details,
                .allocator = self.allocator,
            };
        }
        
        // Both should mention the untracked file
        const has_untracked_ziggit = std.mem.indexOf(u8, ziggit_result.stdout, "test.txt") != null;
        const has_untracked_git = std.mem.indexOf(u8, git_result.stdout, "test.txt") != null;
        
        if (has_untracked_git and !has_untracked_ziggit) {
            const details = try self.allocator.dupe(u8, "ziggit status doesn't show untracked files like git");
            return TestResult{
                .name = "status format", 
                .passed = false,
                .details = details,
                .allocator = self.allocator,
            };
        }
        
        return TestResult{
            .name = "status format",
            .passed = true,
            .details = null,
            .allocator = self.allocator,
        };
    }
    
    // Test basic add-commit workflow
    pub fn testBasicWorkflow(self: GitSourceCompatTests) !TestResult {
        const test_dir = "test-basic-workflow";
        defer self.cleanupTestRepo(test_dir);
        
        try self.setupTestRepo(test_dir);
        
        // Create and add file with ziggit
        const file_content = "Hello, ziggit!\n";
        try fs.cwd().writeFile(.{ .sub_path = test_dir ++ "/hello.txt", .data = file_content });
        
        const add_result = try self.runCommand(self.ziggit_path, &[_][]const u8{"add", "hello.txt"}, test_dir);
        defer self.allocator.free(add_result.stdout);
        defer self.allocator.free(add_result.stderr);
        
        if (add_result.exit_code != 0) {
            const details = try std.fmt.allocPrint(self.allocator,
                "Add command failed: exit_code={}, stderr: {s}",
                .{add_result.exit_code, add_result.stderr});
            return TestResult{
                .name = "basic workflow",
                .passed = false,
                .details = details,
                .allocator = self.allocator,
            };
        }
        
        // Commit with ziggit
        const commit_result = try self.runCommand(self.ziggit_path, &[_][]const u8{"commit", "-m", "Initial commit"}, test_dir);
        defer self.allocator.free(commit_result.stdout);
        defer self.allocator.free(commit_result.stderr);
        
        if (commit_result.exit_code != 0) {
            const details = try std.fmt.allocPrint(self.allocator,
                "Commit command failed: exit_code={}, stderr: {s}",
                .{commit_result.exit_code, commit_result.stderr});
            return TestResult{
                .name = "basic workflow",
                .passed = false,
                .details = details,
                .allocator = self.allocator,
            };
        }
        
        // Check that we can get log
        const log_result = try self.runCommand(self.ziggit_path, &[_][]const u8{"log"}, test_dir);
        defer self.allocator.free(log_result.stdout);
        defer self.allocator.free(log_result.stderr);
        
        if (log_result.exit_code != 0) {
            const details = try std.fmt.allocPrint(self.allocator,
                "Log command failed after commit: exit_code={}, stderr: {s}",
                .{log_result.exit_code, log_result.stderr});
            return TestResult{
                .name = "basic workflow",
                .passed = false,
                .details = details,
                .allocator = self.allocator,
            };
        }
        
        // Log should contain our commit message
        if (std.mem.indexOf(u8, log_result.stdout, "Initial commit") == null) {
            const details = try std.fmt.allocPrint(self.allocator,
                "Log doesn't contain commit message. Log output: {s}",
                .{log_result.stdout});
            return TestResult{
                .name = "basic workflow",
                .passed = false,
                .details = details,
                .allocator = self.allocator,
            };
        }
        
        return TestResult{
            .name = "basic workflow",
            .passed = true,
            .details = null,
            .allocator = self.allocator,
        };
    }
};

pub fn runGitSourceCompatTests() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const tester = GitSourceCompatTests.init(allocator);
    
    std.debug.print("Running git source compatibility tests...\n", .{});
    
    const tests = [_]struct{name: []const u8, func: *const fn(GitSourceCompatTests) anyerror!TestResult} {
        .{ .name = "init plain", .func = &GitSourceCompatTests.testInitPlain },
        .{ .name = "add nonexistent", .func = &GitSourceCompatTests.testAddNonExistent },
        .{ .name = "commit nothing", .func = &GitSourceCompatTests.testCommitNothing },
        .{ .name = "status format", .func = &GitSourceCompatTests.testStatusFormat },
        .{ .name = "basic workflow", .func = &GitSourceCompatTests.testBasicWorkflow },
    };
    
    var passed: u32 = 0;
    var failed: u32 = 0;
    
    for (tests) |test_case| {
        std.debug.print("  Testing {s}...\n", .{test_case.name});
        
        var result = test_case.func(tester) catch |err| {
            std.debug.print("    ❌ {s} - ERROR: {}\n", .{test_case.name, err});
            failed += 1;
            continue;
        };
        defer result.deinit();
        
        if (result.passed) {
            std.debug.print("    ✓ {s}\n", .{result.name});
            passed += 1;
        } else {
            if (result.details) |details| {
                std.debug.print("    ❌ {s} - {s}\n", .{result.name, details});
            } else {
                std.debug.print("    ❌ {s}\n", .{result.name});
            }
            failed += 1;
        }
    }
    
    std.debug.print("Git source compatibility tests completed: {} passed, {} failed\n", .{ passed, failed });
}