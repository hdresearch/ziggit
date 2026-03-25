const std = @import("std");
const testing = std.testing;
const print = std.debug.print;

// Comprehensive Git Compatibility Test Suite
// Adapted from git's own test suite structure and patterns

const TestContext = struct {
    allocator: std.mem.Allocator,
    test_counter: u32 = 0,
    passed_tests: u32 = 0,
    failed_tests: u32 = 0,
    temp_dir: []u8,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) !Self {
        const timestamp = std.time.timestamp();
        const temp_dir = try std.fmt.allocPrint(allocator, "/tmp/ziggit-compat-{d}", .{timestamp});
        try std.fs.cwd().makeDir(temp_dir);
        
        return Self{
            .allocator = allocator,
            .temp_dir = temp_dir,
        };
    }
    
    pub fn deinit(self: *Self) void {
        // Clean up temp directory
        std.fs.cwd().deleteTree(self.temp_dir) catch {};
        self.allocator.free(self.temp_dir);
    }
    
    // Execute a command and return results
    pub fn runCommand(self: *Self, args: []const []const u8, working_dir: ?[]const u8) !CommandResult {
        var result = std.ArrayList(u8).init(self.allocator);
        defer result.deinit();
        
        var stderr_result = std.ArrayList(u8).init(self.allocator);
        defer stderr_result.deinit();
        
        const actual_working_dir = working_dir orelse self.temp_dir;
        
        var proc = std.process.Child.init(args, self.allocator);
        proc.cwd = actual_working_dir;
        proc.stdout_behavior = .Pipe;
        proc.stderr_behavior = .Pipe;
        
        try proc.spawn();
        
        const stdout_content = try proc.stdout.?.readToEndAlloc(self.allocator, 10 * 1024 * 1024);
        const stderr_content = try proc.stderr.?.readToEndAlloc(self.allocator, 10 * 1024 * 1024);
        
        const term_result = try proc.wait();
        const exit_code: u8 = switch (term_result) {
            .Exited => |code| @intCast(code),
            else => 1,
        };
        
        return CommandResult{
            .stdout = stdout_content,
            .stderr = stderr_content,
            .exit_code = exit_code,
        };
    }
    
    // Expect a test to succeed
    pub fn expectSuccess(self: *Self, test_name: []const u8, test_fn: TestFunction) void {
        self.test_counter += 1;
        print("  Testing: {s}...", .{test_name});
        
        test_fn(self) catch |err| {
            print(" ❌ FAILED: {any}\n", .{err});
            self.failed_tests += 1;
            return;
        };
        
        print(" ✅ PASSED\n", .{});
        self.passed_tests += 1;
    }
    
    // Create a temporary test directory
    pub fn createTestDir(self: *Self, name: []const u8) ![]u8 {
        const test_dir = try std.fmt.allocPrint(self.allocator, "{s}/{s}-{d}", .{ self.temp_dir, name, self.test_counter });
        try std.fs.cwd().makeDir(test_dir);
        return test_dir;
    }
    
    // Write a file with content
    pub fn writeFile(self: *Self, dir: []const u8, filename: []const u8, content: []const u8) !void {
        const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir, filename });
        defer self.allocator.free(path);
        
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        
        try file.writeAll(content);
    }
    
    // Check if file exists
    pub fn fileExists(self: *Self, dir: []const u8, filename: []const u8) bool {
        const path = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir, filename }) catch return false;
        defer self.allocator.free(path);
        
        std.fs.cwd().access(path, .{}) catch return false;
        return true;
    }
    
    // Check if directory exists
    pub fn dirExists(self: *Self, dir: []const u8, dirname: []const u8) bool {
        const path = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir, dirname }) catch return false;
        defer self.allocator.free(path);
        
        var open_dir = std.fs.cwd().openDir(path, .{}) catch return false;
        open_dir.close();
        return true;
    }
    
    pub fn printSummary(self: *Self) void {
        print("\n=== Test Summary ===\n", .{});
        print("Total tests: {d}\n", .{self.test_counter});
        print("Passed: {d}\n", .{self.passed_tests});
        print("Failed: {d}\n", .{self.failed_tests});
        
        if (self.failed_tests == 0) {
            print("🎉 All tests passed!\n", .{});
        } else {
            print("⚠️  Some tests failed.\n", .{});
        }
    }
};

const CommandResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,
    
    pub fn deinit(self: *CommandResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

const TestFunction = *const fn (*TestContext) anyerror!void;

// Test functions adapted from git's test suite

// t0001-init.sh equivalent tests
fn test_git_init_plain(ctx: *TestContext) !void {
    const test_dir = try ctx.createTestDir("init-plain");
    defer ctx.allocator.free(test_dir);
    
    // Test ziggit init
    var result = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "init" }, test_dir);
    defer result.deinit(ctx.allocator);
    
    if (result.exit_code != 0) {
        return error.InitFailed;
    }
    
    // Verify .git directory structure
    if (!ctx.dirExists(test_dir, ".git")) return error.GitDirNotCreated;
    if (!ctx.dirExists(test_dir, ".git/refs")) return error.RefsDirNotCreated;
    if (!ctx.dirExists(test_dir, ".git/objects")) return error.ObjectsDirNotCreated;
    if (!ctx.fileExists(test_dir, ".git/HEAD")) return error.HeadFileNotCreated;
}

fn test_git_init_bare(ctx: *TestContext) !void {
    const test_dir = try ctx.createTestDir("init-bare");
    defer ctx.allocator.free(test_dir);
    
    var result = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "init", "--bare" }, test_dir);
    defer result.deinit(ctx.allocator);
    
    if (result.exit_code != 0) {
        return error.InitBareFailed;
    }
    
    // In bare repo, files should be in root directory, not in .git subdirectory
    if (!ctx.dirExists(test_dir, "refs")) return error.BareRefsDirNotCreated;
    if (!ctx.dirExists(test_dir, "objects")) return error.BareObjectsDirNotCreated;
    if (!ctx.fileExists(test_dir, "HEAD")) return error.BareHeadFileNotCreated;
}

// t7508-status.sh equivalent tests
fn test_git_status_empty_repo(ctx: *TestContext) !void {
    const test_dir = try ctx.createTestDir("status-empty");
    defer ctx.allocator.free(test_dir);
    
    // Initialize repository
    var init_result = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "init" }, test_dir);
    defer init_result.deinit(ctx.allocator);
    if (init_result.exit_code != 0) return error.InitFailed;
    
    // Test status in empty repository
    var result = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "status" }, test_dir);
    defer result.deinit(ctx.allocator);
    
    // Should succeed and show branch info
    if (result.exit_code != 0) return error.StatusFailed;
    
    // Should contain reference to branch 'master' or 'main'
    if (std.mem.indexOf(u8, result.stdout, "master") == null and 
        std.mem.indexOf(u8, result.stdout, "main") == null) {
        return error.StatusMissingBranchInfo;
    }
}

fn test_git_status_with_untracked_files(ctx: *TestContext) !void {
    const test_dir = try ctx.createTestDir("status-untracked");
    defer ctx.allocator.free(test_dir);
    
    // Initialize repository
    var init_result = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "init" }, test_dir);
    defer init_result.deinit(ctx.allocator);
    if (init_result.exit_code != 0) return error.InitFailed;
    
    // Create untracked file
    try ctx.writeFile(test_dir, "untracked.txt", "This file is untracked");
    
    // Test status
    var result = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "status" }, test_dir);
    defer result.deinit(ctx.allocator);
    
    if (result.exit_code != 0) return error.StatusFailed;
    
    // Should show untracked files
    if (std.mem.indexOf(u8, result.stdout, "untracked") == null) {
        return error.StatusMissingUntrackedInfo;
    }
}

// Add/staging tests
fn test_git_add_single_file(ctx: *TestContext) !void {
    const test_dir = try ctx.createTestDir("add-single");
    defer ctx.allocator.free(test_dir);
    
    // Initialize repository
    var init_result = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "init" }, test_dir);
    defer init_result.deinit(ctx.allocator);
    if (init_result.exit_code != 0) return error.InitFailed;
    
    // Create file to add
    try ctx.writeFile(test_dir, "file.txt", "Content to add");
    
    // Add file
    var result = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "add", "file.txt" }, test_dir);
    defer result.deinit(ctx.allocator);
    
    if (result.exit_code != 0) return error.AddFailed;
    
    // Verify status shows staged file
    var status_result = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "status" }, test_dir);
    defer status_result.deinit(ctx.allocator);
    
    if (status_result.exit_code != 0) return error.StatusFailed;
    
    // Should show staged changes
    if (std.mem.indexOf(u8, status_result.stdout, "file.txt") == null) {
        return error.StatusMissingStagedFile;
    }
}

// Commit tests
fn test_git_commit_basic(ctx: *TestContext) !void {
    const test_dir = try ctx.createTestDir("commit-basic");
    defer ctx.allocator.free(test_dir);
    
    // Initialize repository
    var init_result = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "init" }, test_dir);
    defer init_result.deinit(ctx.allocator);
    if (init_result.exit_code != 0) return error.InitFailed;
    
    // Create and add file
    try ctx.writeFile(test_dir, "commit-test.txt", "Initial commit content");
    var add_result = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "add", "commit-test.txt" }, test_dir);
    defer add_result.deinit(ctx.allocator);
    if (add_result.exit_code != 0) return error.AddFailed;
    
    // Commit
    var result = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "commit", "-m", "Initial commit" }, test_dir);
    defer result.deinit(ctx.allocator);
    
    if (result.exit_code != 0) return error.CommitFailed;
    
    // Verify log shows commit
    var log_result = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "log" }, test_dir);
    defer log_result.deinit(ctx.allocator);
    
    if (log_result.exit_code != 0) return error.LogFailed;
    
    if (std.mem.indexOf(u8, log_result.stdout, "Initial commit") == null) {
        return error.LogMissingCommit;
    }
}

// Log tests
fn test_git_log_empty_repo(ctx: *TestContext) !void {
    const test_dir = try ctx.createTestDir("log-empty");
    defer ctx.allocator.free(test_dir);
    
    // Initialize repository
    var init_result = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "init" }, test_dir);
    defer init_result.deinit(ctx.allocator);
    if (init_result.exit_code != 0) return error.InitFailed;
    
    // Test log in empty repository - should fail gracefully
    var result = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "log" }, test_dir);
    defer result.deinit(ctx.allocator);
    
    // Should fail with non-zero exit code but not crash
    if (result.exit_code == 0) return error.LogShouldFailInEmptyRepo;
}

// Branch tests
fn test_git_branch_list(ctx: *TestContext) !void {
    const test_dir = try ctx.createTestDir("branch-list");
    defer ctx.allocator.free(test_dir);
    
    // Initialize repository
    var init_result = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "init" }, test_dir);
    defer init_result.deinit(ctx.allocator);
    if (init_result.exit_code != 0) return error.InitFailed;
    
    // Create initial commit (needed for branch operations)
    try ctx.writeFile(test_dir, "initial.txt", "Initial content");
    var add_result = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "add", "initial.txt" }, test_dir);
    defer add_result.deinit(ctx.allocator);
    if (add_result.exit_code != 0) return error.AddFailed;
    
    var commit_result = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "commit", "-m", "Initial" }, test_dir);
    defer commit_result.deinit(ctx.allocator);
    if (commit_result.exit_code != 0) return error.CommitFailed;
    
    // Test branch listing
    var result = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "branch" }, test_dir);
    defer result.deinit(ctx.allocator);
    
    if (result.exit_code != 0) return error.BranchListFailed;
    
    // Should show master branch
    if (std.mem.indexOf(u8, result.stdout, "master") == null and 
        std.mem.indexOf(u8, result.stdout, "main") == null) {
        return error.BranchListMissingDefault;
    }
}

// Compare outputs with git for compatibility
fn test_output_compatibility_init(ctx: *TestContext) !void {
    const test_dir_ziggit = try ctx.createTestDir("output-compat-ziggit");
    defer ctx.allocator.free(test_dir_ziggit);
    
    const test_dir_git = try ctx.createTestDir("output-compat-git");
    defer ctx.allocator.free(test_dir_git);
    
    // Run ziggit init
    var ziggit_result = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "init" }, test_dir_ziggit);
    defer ziggit_result.deinit(ctx.allocator);
    
    // Run git init
    var git_result = try ctx.runCommand(&[_][]const u8{ "git", "init" }, test_dir_git);
    defer git_result.deinit(ctx.allocator);
    
    // Both should succeed
    if (ziggit_result.exit_code != 0) return error.ZiggitInitFailed;
    if (git_result.exit_code != 0) return error.GitInitFailed;
    
    // Check that both created similar structures
    if (!ctx.dirExists(test_dir_ziggit, ".git")) return error.ZiggitMissingGitDir;
    if (!ctx.dirExists(test_dir_git, ".git")) return error.GitMissingGitDir;
}

// Main test runner
pub fn runGitCompatibilityTests(allocator: std.mem.Allocator) !void {
    var ctx = try TestContext.init(allocator);
    defer ctx.deinit();
    
    print("🚀 Running Git Compatibility Tests\n", .{});
    print("=====================================\n\n", .{});
    
    // Basic repository initialization tests
    print("📁 Repository Initialization Tests:\n", .{});
    ctx.expectSuccess("init plain repository", test_git_init_plain);
    ctx.expectSuccess("init bare repository", test_git_init_bare);
    
    // Status command tests
    print("\n📊 Status Command Tests:\n", .{});
    ctx.expectSuccess("status in empty repository", test_git_status_empty_repo);
    ctx.expectSuccess("status with untracked files", test_git_status_with_untracked_files);
    
    // Add/staging tests
    print("\n➕ Add/Staging Tests:\n", .{});
    ctx.expectSuccess("add single file", test_git_add_single_file);
    
    // Commit tests
    print("\n💾 Commit Tests:\n", .{});
    ctx.expectSuccess("basic commit", test_git_commit_basic);
    
    // Log tests
    print("\n📜 Log Tests:\n", .{});
    ctx.expectSuccess("log in empty repository", test_git_log_empty_repo);
    
    // Branch tests
    print("\n🌿 Branch Tests:\n", .{});
    ctx.expectSuccess("list branches", test_git_branch_list);
    
    // Output compatibility tests
    print("\n🔄 Output Compatibility Tests:\n", .{});
    ctx.expectSuccess("init output compatibility", test_output_compatibility_init);
    
    print("\n", .{});
    ctx.printSummary();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    try runGitCompatibilityTests(allocator);
}