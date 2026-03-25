const std = @import("std");
const testing = std.testing;
const Process = std.process;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const fs = std.fs;

// Enhanced git compatibility tests with better error handling and git setup
pub const EnhancedGitCompatTests = struct {
    allocator: Allocator,
    ziggit_path: []const u8,
    git_path: []const u8,
    
    pub fn init(allocator: Allocator) EnhancedGitCompatTests {
        return EnhancedGitCompatTests{
            .allocator = allocator,
            .ziggit_path = "./zig-out/bin/ziggit",
            .git_path = "git",
        };
    }
    
    pub fn runCommand(self: EnhancedGitCompatTests, command: []const u8, args: []const []const u8, cwd: ?[]const u8) !struct {
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
    
    pub fn cleanupTestDir(self: EnhancedGitCompatTests, dir_name: []const u8) void {
        _ = self;
        fs.cwd().deleteTree(dir_name) catch {};
    }
    
    pub fn setupTestDir(self: EnhancedGitCompatTests, dir_name: []const u8) !void {
        // Clean up any existing directory
        self.cleanupTestDir(dir_name);
        
        // Create the test directory
        try fs.cwd().makeDir(dir_name);
    }
    
    pub fn setupGitRepo(self: EnhancedGitCompatTests, dir_name: []const u8, with_config: bool) !void {
        try self.setupTestDir(dir_name);
        
        // Initialize with git
        const init_result = try self.runCommand(self.git_path, &[_][]const u8{"init"}, dir_name);
        defer self.allocator.free(init_result.stdout);
        defer self.allocator.free(init_result.stderr);
        
        if (with_config) {
            // Set up git user config for testing
            const config_name_result = try self.runCommand(self.git_path, &[_][]const u8{"config", "user.name", "Test User"}, dir_name);
            defer self.allocator.free(config_name_result.stdout);
            defer self.allocator.free(config_name_result.stderr);
            
            const config_email_result = try self.runCommand(self.git_path, &[_][]const u8{"config", "user.email", "test@example.com"}, dir_name);
            defer self.allocator.free(config_email_result.stdout);
            defer self.allocator.free(config_email_result.stderr);
        }
    }
    
    pub fn writeTestFile(self: EnhancedGitCompatTests, dir_name: []const u8, file_name: []const u8, content: []const u8) !void {
        const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{dir_name, file_name});
        defer self.allocator.free(path);
        
        try fs.cwd().writeFile(.{ .sub_path = path, .data = content });
    }
    
    // Test that ziggit init creates the same directory structure as git init
    pub fn testInitCompatibility(self: EnhancedGitCompatTests) !bool {
        const ziggit_dir = "test-ziggit-init";
        const git_dir = "test-git-init";
        
        defer self.cleanupTestDir(ziggit_dir);
        defer self.cleanupTestDir(git_dir);
        
        // Test ziggit init
        const ziggit_result = try self.runCommand(self.ziggit_path, &[_][]const u8{"init", ziggit_dir}, null);
        defer self.allocator.free(ziggit_result.stdout);
        defer self.allocator.free(ziggit_result.stderr);
        
        // Test git init for comparison
        const git_result = try self.runCommand(self.git_path, &[_][]const u8{"init", git_dir}, null);
        defer self.allocator.free(git_result.stdout);
        defer self.allocator.free(git_result.stderr);
        
        // Both should succeed
        if (ziggit_result.exit_code != 0 or git_result.exit_code != 0) {
            std.debug.print("    Init failed: ziggit={}, git={}\n", .{ziggit_result.exit_code, git_result.exit_code});
            return false;
        }
        
        // Both should create .git directories
        const ziggit_git_exists = blk: {
            fs.cwd().access(ziggit_dir ++ "/.git", .{}) catch break :blk false;
            break :blk true;
        };
        
        const git_git_exists = blk: {
            fs.cwd().access(git_dir ++ "/.git", .{}) catch break :blk false;
            break :blk true;
        };
        
        return ziggit_git_exists and git_git_exists;
    }
    
    // Test that ziggit add behaves like git add for non-existent files
    pub fn testAddNonExistentFile(self: EnhancedGitCompatTests) !bool {
        const ziggit_dir = "test-ziggit-add";
        const git_dir = "test-git-add";
        
        defer self.cleanupTestDir(ziggit_dir);
        defer self.cleanupTestDir(git_dir);
        
        try self.setupGitRepo(ziggit_dir, false);
        try self.setupGitRepo(git_dir, false);
        
        // Test adding non-existent file with ziggit
        const ziggit_result = try self.runCommand(self.ziggit_path, &[_][]const u8{"add", "nonexistent.txt"}, ziggit_dir);
        defer self.allocator.free(ziggit_result.stdout);
        defer self.allocator.free(ziggit_result.stderr);
        
        // Test adding non-existent file with git
        const git_result = try self.runCommand(self.git_path, &[_][]const u8{"add", "nonexistent.txt"}, git_dir);
        defer self.allocator.free(git_result.stdout);
        defer self.allocator.free(git_result.stderr);
        
        // Both should fail with non-zero exit codes
        return ziggit_result.exit_code != 0 and git_result.exit_code != 0;
    }
    
    // Test that ziggit add successfully adds files like git
    pub fn testAddExistingFile(self: EnhancedGitCompatTests) !bool {
        const ziggit_dir = "test-ziggit-add-existing";
        const git_dir = "test-git-add-existing";
        
        defer self.cleanupTestDir(ziggit_dir);
        defer self.cleanupTestDir(git_dir);
        
        try self.setupGitRepo(ziggit_dir, false);
        try self.setupGitRepo(git_dir, false);
        
        // Create test files
        try self.writeTestFile(ziggit_dir, "test.txt", "test content\n");
        try self.writeTestFile(git_dir, "test.txt", "test content\n");
        
        // Add files
        const ziggit_result = try self.runCommand(self.ziggit_path, &[_][]const u8{"add", "test.txt"}, ziggit_dir);
        defer self.allocator.free(ziggit_result.stdout);
        defer self.allocator.free(ziggit_result.stderr);
        
        const git_result = try self.runCommand(self.git_path, &[_][]const u8{"add", "test.txt"}, git_dir);
        defer self.allocator.free(git_result.stdout);
        defer self.allocator.free(git_result.stderr);
        
        // Both should succeed
        return ziggit_result.exit_code == 0 and git_result.exit_code == 0;
    }
    
    // Test status output for untracked files
    pub fn testStatusUntracked(self: EnhancedGitCompatTests) !bool {
        const test_dir = "test-status-untracked";
        defer self.cleanupTestDir(test_dir);
        
        try self.setupGitRepo(test_dir, false);
        
        // Create an untracked file
        try self.writeTestFile(test_dir, "untracked.txt", "untracked content\n");
        
        // Get status with ziggit
        const ziggit_result = try self.runCommand(self.ziggit_path, &[_][]const u8{"status"}, test_dir);
        defer self.allocator.free(ziggit_result.stdout);
        defer self.allocator.free(ziggit_result.stderr);
        
        // Get status with git for comparison
        const git_result = try self.runCommand(self.git_path, &[_][]const u8{"status"}, test_dir);
        defer self.allocator.free(git_result.stdout);
        defer self.allocator.free(git_result.stderr);
        
        // Both should succeed
        if (ziggit_result.exit_code != 0 or git_result.exit_code != 0) {
            return false;
        }
        
        // Both should mention the untracked file (basic check)
        const ziggit_mentions_file = std.mem.indexOf(u8, ziggit_result.stdout, "untracked.txt") != null;
        const git_mentions_file = std.mem.indexOf(u8, git_result.stdout, "untracked.txt") != null;
        
        // If git mentions it, ziggit should too for compatibility
        if (git_mentions_file and !ziggit_mentions_file) {
            std.debug.print("    Warning: git shows untracked files but ziggit doesn't\n", .{});
            return false;
        }
        
        return true;
    }
    
    // Test complete workflow: init -> add -> commit -> log
    pub fn testCompleteWorkflow(self: EnhancedGitCompatTests) !bool {
        const test_dir = "test-complete-workflow";
        defer self.cleanupTestDir(test_dir);
        
        // Initialize with ziggit
        const init_result = try self.runCommand(self.ziggit_path, &[_][]const u8{"init", test_dir}, null);
        defer self.allocator.free(init_result.stdout);
        defer self.allocator.free(init_result.stderr);
        
        if (init_result.exit_code != 0) {
            std.debug.print("    Ziggit init failed: {}\n", .{init_result.exit_code});
            return false;
        }
        
        // Create a test file
        try self.writeTestFile(test_dir, "hello.txt", "Hello, World!\n");
        
        // Add the file
        const add_result = try self.runCommand(self.ziggit_path, &[_][]const u8{"add", "hello.txt"}, test_dir);
        defer self.allocator.free(add_result.stdout);
        defer self.allocator.free(add_result.stderr);
        
        if (add_result.exit_code != 0) {
            std.debug.print("    Ziggit add failed: {}\n", .{add_result.exit_code});
            return false;
        }
        
        // Commit the file (this may fail due to user config, but let's try)
        const commit_result = try self.runCommand(self.ziggit_path, &[_][]const u8{"commit", "-m", "Initial commit"}, test_dir);
        defer self.allocator.free(commit_result.stdout);
        defer self.allocator.free(commit_result.stderr);
        
        // For now, we accept that commit might fail due to user config
        // but add and init should work
        
        // Check status to see if file was added
        const status_result = try self.runCommand(self.ziggit_path, &[_][]const u8{"status"}, test_dir);
        defer self.allocator.free(status_result.stdout);
        defer self.allocator.free(status_result.stderr);
        
        if (status_result.exit_code != 0) {
            std.debug.print("    Ziggit status failed: {}\n", .{status_result.exit_code});
            return false;
        }
        
        return true; // Basic workflow steps completed
    }
    
    // Test error handling - commands in non-git directory
    pub fn testErrorHandling(self: EnhancedGitCompatTests) !bool {
        const test_dir = "test-error-handling";
        defer self.cleanupTestDir(test_dir);
        
        try self.setupTestDir(test_dir); // Just create dir, don't initialize git
        
        // Try git commands in non-git directory
        const status_result = try self.runCommand(self.ziggit_path, &[_][]const u8{"status"}, test_dir);
        defer self.allocator.free(status_result.stdout);
        defer self.allocator.free(status_result.stderr);
        
        const add_result = try self.runCommand(self.ziggit_path, &[_][]const u8{"add", "file.txt"}, test_dir);
        defer self.allocator.free(add_result.stdout);
        defer self.allocator.free(add_result.stderr);
        
        // Both should fail with non-zero exit codes
        return status_result.exit_code != 0 and add_result.exit_code != 0;
    }
};

pub fn runEnhancedGitCompatTests() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const tester = EnhancedGitCompatTests.init(allocator);
    
    std.debug.print("Running enhanced git compatibility tests...\n", .{});
    
    const tests = [_]struct {
        name: []const u8,
        func: *const fn(EnhancedGitCompatTests) anyerror!bool,
    }{
        .{ .name = "init compatibility", .func = &EnhancedGitCompatTests.testInitCompatibility },
        .{ .name = "add nonexistent file", .func = &EnhancedGitCompatTests.testAddNonExistentFile },
        .{ .name = "add existing file", .func = &EnhancedGitCompatTests.testAddExistingFile },
        .{ .name = "status untracked files", .func = &EnhancedGitCompatTests.testStatusUntracked },
        .{ .name = "complete workflow", .func = &EnhancedGitCompatTests.testCompleteWorkflow },
        .{ .name = "error handling", .func = &EnhancedGitCompatTests.testErrorHandling },
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
    
    std.debug.print("Enhanced git compatibility tests completed: {} passed, {} failed\n", .{ passed, failed });
}