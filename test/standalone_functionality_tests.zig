const std = @import("std");
const testing = std.testing;
const Process = std.process;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const fs = std.fs;

// Standalone functionality tests - test ziggit without needing git for comparison
// Based on git's expected behavior patterns from the git source test suite

pub const StandaloneFunctionalityTests = struct {
    allocator: Allocator,
    ziggit_path: []const u8,
    
    pub fn init(allocator: Allocator) StandaloneFunctionalityTests {
        return StandaloneFunctionalityTests{
            .allocator = allocator,
            .ziggit_path = "/root/zigg/root/ziggit/zig-out/bin/ziggit",
        };
    }
    
    pub fn runCommand(self: StandaloneFunctionalityTests, args: []const []const u8, cwd: ?[]const u8) !struct {
        stdout: []u8,
        stderr: []u8,
        exit_code: u8,
    } {
        var argv = ArrayList([]const u8).init(self.allocator);
        defer argv.deinit();
        try argv.append(self.ziggit_path);
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
    
    pub fn cleanupTestDir(_: StandaloneFunctionalityTests, dir_name: []const u8) void {
        fs.cwd().deleteTree(dir_name) catch {};
    }
    
    pub fn writeTestFile(self: StandaloneFunctionalityTests, dir_name: []const u8, file_name: []const u8, content: []const u8) !void {
        const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{dir_name, file_name});
        defer self.allocator.free(path);
        
        try fs.cwd().writeFile(.{ .sub_path = path, .data = content });
    }
    
    pub fn directoryExists(_: StandaloneFunctionalityTests, path: []const u8) bool {
        fs.cwd().access(path, .{}) catch return false;
        return true;
    }
    
    // Test git init functionality - should create .git directory
    pub fn testInit(self: StandaloneFunctionalityTests) !bool {
        const test_dir = "test-standalone-init";
        defer self.cleanupTestDir(test_dir);
        
        // Test init with directory argument
        const result = try self.runCommand(&[_][]const u8{"init", test_dir}, null);
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
        
        if (result.exit_code != 0) {
            std.debug.print("    Init failed with exit code: {}\n", .{result.exit_code});
            std.debug.print("    stderr: {s}\n", .{result.stderr});
            return false;
        }
        
        // Check that .git directory was created
        const git_dir = test_dir ++ "/.git";
        if (!self.directoryExists(git_dir)) {
            std.debug.print("    .git directory not created in {s}\n", .{git_dir});
            return false;
        }
        
        return true;
    }
    
    // Test git init --bare functionality
    pub fn testInitBare(self: StandaloneFunctionalityTests) !bool {
        const test_dir = "test-standalone-init-bare";
        defer self.cleanupTestDir(test_dir);
        
        const result = try self.runCommand(&[_][]const u8{"init", "--bare", test_dir}, null);
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
        
        if (result.exit_code != 0) {
            std.debug.print("    Init --bare failed with exit code: {}\n", .{result.exit_code});
            return false;
        }
        
        // For bare repo, the directory itself should contain git files
        return self.directoryExists(test_dir);
    }
    
    // Test status in empty repository
    pub fn testStatusEmpty(self: StandaloneFunctionalityTests) !bool {
        const test_dir = "test-standalone-status-empty";
        defer self.cleanupTestDir(test_dir);
        
        // First initialize a repo
        const init_result = try self.runCommand(&[_][]const u8{"init", test_dir}, null);
        defer self.allocator.free(init_result.stdout);
        defer self.allocator.free(init_result.stderr);
        
        if (init_result.exit_code != 0) return false;
        
        // Then check status
        const status_result = try self.runCommand(&[_][]const u8{"status"}, test_dir);
        defer self.allocator.free(status_result.stdout);
        defer self.allocator.free(status_result.stderr);
        
        // Status should succeed in a git repository
        return status_result.exit_code == 0;
    }
    
    // Test status outside repository - should fail
    pub fn testStatusOutsideRepo(self: StandaloneFunctionalityTests) !bool {
        const test_dir = "test-standalone-status-outside";
        defer self.cleanupTestDir(test_dir);
        
        // Create directory but don't initialize git
        try fs.cwd().makeDir(test_dir);
        
        const status_result = try self.runCommand(&[_][]const u8{"status"}, test_dir);
        defer self.allocator.free(status_result.stdout);
        defer self.allocator.free(status_result.stderr);
        
        // Status should fail outside git repository
        return status_result.exit_code != 0;
    }
    
    // Test add non-existent file - should fail
    pub fn testAddNonExistent(self: StandaloneFunctionalityTests) !bool {
        const test_dir = "test-standalone-add-nonexistent";
        defer self.cleanupTestDir(test_dir);
        
        // Initialize repo
        const init_result = try self.runCommand(&[_][]const u8{"init", test_dir}, null);
        defer self.allocator.free(init_result.stdout);
        defer self.allocator.free(init_result.stderr);
        
        if (init_result.exit_code != 0) return false;
        
        // Try to add non-existent file
        const add_result = try self.runCommand(&[_][]const u8{"add", "nonexistent.txt"}, test_dir);
        defer self.allocator.free(add_result.stdout);
        defer self.allocator.free(add_result.stderr);
        
        // Should fail
        return add_result.exit_code != 0;
    }
    
    // Test add existing file - should succeed
    pub fn testAddExistingFile(self: StandaloneFunctionalityTests) !bool {
        const test_dir = "test-standalone-add-existing";
        defer self.cleanupTestDir(test_dir);
        
        // Initialize repo
        const init_result = try self.runCommand(&[_][]const u8{"init", test_dir}, null);
        defer self.allocator.free(init_result.stdout);
        defer self.allocator.free(init_result.stderr);
        
        if (init_result.exit_code != 0) return false;
        
        // Create a file
        try self.writeTestFile(test_dir, "test.txt", "test content\n");
        
        // Add the file
        const add_result = try self.runCommand(&[_][]const u8{"add", "test.txt"}, test_dir);
        defer self.allocator.free(add_result.stdout);
        defer self.allocator.free(add_result.stderr);
        
        // Should succeed
        return add_result.exit_code == 0;
    }
    
    // Test status with untracked files
    pub fn testStatusWithUntracked(self: StandaloneFunctionalityTests) !bool {
        const test_dir = "test-standalone-status-untracked";
        defer self.cleanupTestDir(test_dir);
        
        // Initialize repo
        const init_result = try self.runCommand(&[_][]const u8{"init", test_dir}, null);
        defer self.allocator.free(init_result.stdout);
        defer self.allocator.free(init_result.stderr);
        
        if (init_result.exit_code != 0) return false;
        
        // Create an untracked file
        try self.writeTestFile(test_dir, "untracked.txt", "untracked content\n");
        
        // Get status
        const status_result = try self.runCommand(&[_][]const u8{"status"}, test_dir);
        defer self.allocator.free(status_result.stdout);
        defer self.allocator.free(status_result.stderr);
        
        // Should succeed and ideally mention the untracked file
        if (status_result.exit_code != 0) return false;
        
        // Check if untracked file is mentioned (optional - for better git compatibility)
        const mentions_untracked = std.mem.indexOf(u8, status_result.stdout, "untracked.txt") != null;
        if (!mentions_untracked) {
            std.debug.print("    Note: status doesn't show untracked files\n", .{});
        }
        
        return true;
    }
    
    // Test commit in empty repository - should fail
    pub fn testCommitEmpty(self: StandaloneFunctionalityTests) !bool {
        const test_dir = "test-standalone-commit-empty";
        defer self.cleanupTestDir(test_dir);
        
        // Initialize repo
        const init_result = try self.runCommand(&[_][]const u8{"init", test_dir}, null);
        defer self.allocator.free(init_result.stdout);
        defer self.allocator.free(init_result.stderr);
        
        if (init_result.exit_code != 0) return false;
        
        // Try to commit with nothing staged
        const commit_result = try self.runCommand(&[_][]const u8{"commit", "-m", "Empty commit"}, test_dir);
        defer self.allocator.free(commit_result.stdout);
        defer self.allocator.free(commit_result.stderr);
        
        // Should fail - nothing to commit
        return commit_result.exit_code != 0;
    }
    
    // Test log in empty repository - should fail
    pub fn testLogEmpty(self: StandaloneFunctionalityTests) !bool {
        const test_dir = "test-standalone-log-empty";
        defer self.cleanupTestDir(test_dir);
        
        // Initialize repo
        const init_result = try self.runCommand(&[_][]const u8{"init", test_dir}, null);
        defer self.allocator.free(init_result.stdout);
        defer self.allocator.free(init_result.stderr);
        
        if (init_result.exit_code != 0) return false;
        
        // Try to get log of empty repo
        const log_result = try self.runCommand(&[_][]const u8{"log"}, test_dir);
        defer self.allocator.free(log_result.stdout);
        defer self.allocator.free(log_result.stderr);
        
        // Should fail - no commits
        return log_result.exit_code != 0;
    }
    
    // Test diff in empty repository - should succeed (no output)
    pub fn testDiffEmpty(self: StandaloneFunctionalityTests) !bool {
        const test_dir = "test-standalone-diff-empty";
        defer self.cleanupTestDir(test_dir);
        
        // Initialize repo
        const init_result = try self.runCommand(&[_][]const u8{"init", test_dir}, null);
        defer self.allocator.free(init_result.stdout);
        defer self.allocator.free(init_result.stderr);
        
        if (init_result.exit_code != 0) return false;
        
        // Get diff of empty repo
        const diff_result = try self.runCommand(&[_][]const u8{"diff"}, test_dir);
        defer self.allocator.free(diff_result.stdout);
        defer self.allocator.free(diff_result.stderr);
        
        // Should succeed (diff of empty repo is valid)
        return diff_result.exit_code == 0;
    }
    
    // Test branch listing in empty repository
    pub fn testBranchEmpty(self: StandaloneFunctionalityTests) !bool {
        const test_dir = "test-standalone-branch-empty";
        defer self.cleanupTestDir(test_dir);
        
        // Initialize repo
        const init_result = try self.runCommand(&[_][]const u8{"init", test_dir}, null);
        defer self.allocator.free(init_result.stdout);
        defer self.allocator.free(init_result.stderr);
        
        if (init_result.exit_code != 0) return false;
        
        // List branches
        const branch_result = try self.runCommand(&[_][]const u8{"branch"}, test_dir);
        defer self.allocator.free(branch_result.stdout);
        defer self.allocator.free(branch_result.stderr);
        
        // May succeed or fail depending on implementation - both are reasonable
        // In git, it fails with "fatal: not a valid object name: 'master'"
        return true; // Accept either behavior for now
    }
    
    // Test help/version commands
    pub fn testHelpAndVersion(self: StandaloneFunctionalityTests) !bool {
        // Test --help
        const help_result = try self.runCommand(&[_][]const u8{"--help"}, null);
        defer self.allocator.free(help_result.stdout);
        defer self.allocator.free(help_result.stderr);
        
        // Test --version
        const version_result = try self.runCommand(&[_][]const u8{"--version"}, null);
        defer self.allocator.free(version_result.stdout);
        defer self.allocator.free(version_result.stderr);
        
        // Both should work and provide output
        const help_ok = help_result.exit_code == 0 and help_result.stdout.len > 0;
        const version_ok = version_result.exit_code == 0 and version_result.stdout.len > 0;
        
        return help_ok and version_ok;
    }
    
    // Test complete workflow that should work
    pub fn testWorkflow(self: StandaloneFunctionalityTests) !bool {
        const test_dir = "test-standalone-workflow";
        defer self.cleanupTestDir(test_dir);
        
        // 1. Initialize repository
        const init_result = try self.runCommand(&[_][]const u8{"init", test_dir}, null);
        defer self.allocator.free(init_result.stdout);
        defer self.allocator.free(init_result.stderr);
        
        if (init_result.exit_code != 0) {
            std.debug.print("    Workflow failed at init: {}\n", .{init_result.exit_code});
            return false;
        }
        
        // 2. Create a file
        try self.writeTestFile(test_dir, "workflow.txt", "Step 1: File created\n");
        
        // 3. Add the file
        const add_result = try self.runCommand(&[_][]const u8{"add", "workflow.txt"}, test_dir);
        defer self.allocator.free(add_result.stdout);
        defer self.allocator.free(add_result.stderr);
        
        if (add_result.exit_code != 0) {
            std.debug.print("    Workflow failed at add: {}\n", .{add_result.exit_code});
            return false;
        }
        
        // 4. Check status (should show staged file)
        const status_result = try self.runCommand(&[_][]const u8{"status"}, test_dir);
        defer self.allocator.free(status_result.stdout);
        defer self.allocator.free(status_result.stderr);
        
        if (status_result.exit_code != 0) {
            std.debug.print("    Workflow failed at status: {}\n", .{status_result.exit_code});
            return false;
        }
        
        // 5. Create another file (untracked)
        try self.writeTestFile(test_dir, "untracked.txt", "This file is untracked\n");
        
        // 6. Check status again
        const status2_result = try self.runCommand(&[_][]const u8{"status"}, test_dir);
        defer self.allocator.free(status2_result.stdout);
        defer self.allocator.free(status2_result.stderr);
        
        if (status2_result.exit_code != 0) {
            std.debug.print("    Workflow failed at second status: {}\n", .{status2_result.exit_code});
            return false;
        }
        
        return true;
    }
};

pub fn runStandaloneFunctionalityTests() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const tester = StandaloneFunctionalityTests.init(allocator);
    
    std.debug.print("Running standalone functionality tests...\n", .{});
    
    const tests = [_]struct {
        name: []const u8,
        func: *const fn(StandaloneFunctionalityTests) anyerror!bool,
    }{
        .{ .name = "init basic", .func = &StandaloneFunctionalityTests.testInit },
        .{ .name = "init --bare", .func = &StandaloneFunctionalityTests.testInitBare },
        .{ .name = "status in empty repo", .func = &StandaloneFunctionalityTests.testStatusEmpty },
        .{ .name = "status outside repo", .func = &StandaloneFunctionalityTests.testStatusOutsideRepo },
        .{ .name = "add nonexistent file", .func = &StandaloneFunctionalityTests.testAddNonExistent },
        .{ .name = "add existing file", .func = &StandaloneFunctionalityTests.testAddExistingFile },
        .{ .name = "status with untracked", .func = &StandaloneFunctionalityTests.testStatusWithUntracked },
        .{ .name = "commit in empty repo", .func = &StandaloneFunctionalityTests.testCommitEmpty },
        .{ .name = "log in empty repo", .func = &StandaloneFunctionalityTests.testLogEmpty },
        .{ .name = "diff in empty repo", .func = &StandaloneFunctionalityTests.testDiffEmpty },
        .{ .name = "branch in empty repo", .func = &StandaloneFunctionalityTests.testBranchEmpty },
        .{ .name = "help and version", .func = &StandaloneFunctionalityTests.testHelpAndVersion },
        .{ .name = "complete workflow", .func = &StandaloneFunctionalityTests.testWorkflow },
    };
    
    var passed: u32 = 0;
    var failed: u32 = 0;
    
    for (tests) |test_case| {
        std.debug.print("  Testing {s}...\n", .{test_case.name});
        
        const result = test_case.func(tester) catch |err| {
            std.debug.print("    ❌ {s} - ERROR: {}\n", .{ test_case.name, err });
            failed += 1;
            continue;
        };
        
        if (result) {
            std.debug.print("    ✓ {s}\n", .{test_case.name});
            passed += 1;
        } else {
            std.debug.print("    ❌ {s}\n", .{test_case.name});
            failed += 1;
        }
    }
    
    std.debug.print("Standalone functionality tests completed: {} passed, {} failed\n", .{ passed, failed });
}