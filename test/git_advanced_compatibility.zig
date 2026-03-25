const std = @import("std");
const testing = std.testing;
const print = std.debug.print;

// Advanced Git Compatibility Test Suite
// Tests more complex git operations for drop-in replacement compatibility

const TestContext = struct {
    allocator: std.mem.Allocator,
    test_counter: u32 = 0,
    passed_tests: u32 = 0,
    failed_tests: u32 = 0,
    temp_dir: []u8,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) !Self {
        const timestamp = std.time.timestamp();
        const temp_dir = try std.fmt.allocPrint(allocator, "/tmp/ziggit-advanced-{d}", .{timestamp});
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
    
    // Read file content
    pub fn readFile(self: *Self, dir: []const u8, filename: []const u8) ![]u8 {
        const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir, filename });
        defer self.allocator.free(path);
        
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        
        return try file.readToEndAlloc(self.allocator, 1024 * 1024);
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

// Advanced test functions

// Test diff command functionality
fn test_git_diff_staged(ctx: *TestContext) !void {
    const test_dir = try ctx.createTestDir("diff-staged");
    defer ctx.allocator.free(test_dir);
    
    // Initialize repository
    var init_result = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "init" }, test_dir);
    defer init_result.deinit(ctx.allocator);
    if (init_result.exit_code != 0) return error.InitFailed;
    
    // Create and commit initial file
    try ctx.writeFile(test_dir, "test.txt", "line 1\nline 2\nline 3\n");
    var add_result = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "add", "test.txt" }, test_dir);
    defer add_result.deinit(ctx.allocator);
    if (add_result.exit_code != 0) return error.AddFailed;
    
    var commit_result = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "commit", "-m", "Initial commit" }, test_dir);
    defer commit_result.deinit(ctx.allocator);
    if (commit_result.exit_code != 0) return error.CommitFailed;
    
    // Modify file and stage it
    try ctx.writeFile(test_dir, "test.txt", "line 1 modified\nline 2\nline 3\nline 4\n");
    var add_result2 = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "add", "test.txt" }, test_dir);
    defer add_result2.deinit(ctx.allocator);
    if (add_result2.exit_code != 0) return error.AddFailed;
    
    // Test diff --staged
    var diff_result = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "diff", "--staged" }, test_dir);
    defer diff_result.deinit(ctx.allocator);
    
    if (diff_result.exit_code != 0) return error.DiffFailed;
    
    // Should contain diff information
    if (std.mem.indexOf(u8, diff_result.stdout, "modified") == null and
        std.mem.indexOf(u8, diff_result.stdout, "+") == null) {
        return error.DiffMissingContent;
    }
}

// Test checkout functionality
fn test_git_checkout_branch(ctx: *TestContext) !void {
    const test_dir = try ctx.createTestDir("checkout-branch");
    defer ctx.allocator.free(test_dir);
    
    // Initialize repository
    var init_result = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "init" }, test_dir);
    defer init_result.deinit(ctx.allocator);
    if (init_result.exit_code != 0) return error.InitFailed;
    
    // Create initial commit
    try ctx.writeFile(test_dir, "readme.txt", "Initial content");
    var add_result = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "add", "readme.txt" }, test_dir);
    defer add_result.deinit(ctx.allocator);
    if (add_result.exit_code != 0) return error.AddFailed;
    
    var commit_result = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "commit", "-m", "Initial commit" }, test_dir);
    defer commit_result.deinit(ctx.allocator);
    if (commit_result.exit_code != 0) return error.CommitFailed;
    
    // Create new branch
    var checkout_result = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "checkout", "-b", "feature" }, test_dir);
    defer checkout_result.deinit(ctx.allocator);
    
    if (checkout_result.exit_code != 0) return error.CheckoutFailed;
    
    // Verify we're on the new branch
    var branch_result = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "branch" }, test_dir);
    defer branch_result.deinit(ctx.allocator);
    
    if (branch_result.exit_code != 0) return error.BranchFailed;
    
    if (std.mem.indexOf(u8, branch_result.stdout, "*") == null or
        std.mem.indexOf(u8, branch_result.stdout, "feature") == null) {
        return error.CheckoutVerificationFailed;
    }
}

// Test multiple commits and log history
fn test_git_log_history(ctx: *TestContext) !void {
    const test_dir = try ctx.createTestDir("log-history");
    defer ctx.allocator.free(test_dir);
    
    // Initialize repository
    var init_result = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "init" }, test_dir);
    defer init_result.deinit(ctx.allocator);
    if (init_result.exit_code != 0) return error.InitFailed;
    
    // Create first commit
    try ctx.writeFile(test_dir, "file1.txt", "First file content");
    var add_result1 = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "add", "file1.txt" }, test_dir);
    defer add_result1.deinit(ctx.allocator);
    if (add_result1.exit_code != 0) return error.AddFailed;
    
    var commit_result1 = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "commit", "-m", "First commit" }, test_dir);
    defer commit_result1.deinit(ctx.allocator);
    if (commit_result1.exit_code != 0) return error.CommitFailed;
    
    // Create second commit
    try ctx.writeFile(test_dir, "file2.txt", "Second file content");
    var add_result2 = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "add", "file2.txt" }, test_dir);
    defer add_result2.deinit(ctx.allocator);
    if (add_result2.exit_code != 0) return error.AddFailed;
    
    var commit_result2 = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "commit", "-m", "Second commit" }, test_dir);
    defer commit_result2.deinit(ctx.allocator);
    if (commit_result2.exit_code != 0) return error.CommitFailed;
    
    // Create third commit
    try ctx.writeFile(test_dir, "file3.txt", "Third file content");
    var add_result3 = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "add", "file3.txt" }, test_dir);
    defer add_result3.deinit(ctx.allocator);
    if (add_result3.exit_code != 0) return error.AddFailed;
    
    var commit_result3 = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "commit", "-m", "Third commit" }, test_dir);
    defer commit_result3.deinit(ctx.allocator);
    if (commit_result3.exit_code != 0) return error.CommitFailed;
    
    // Test log
    var log_result = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "log" }, test_dir);
    defer log_result.deinit(ctx.allocator);
    
    if (log_result.exit_code != 0) return error.LogFailed;
    
    // Should contain all three commits
    if (std.mem.indexOf(u8, log_result.stdout, "First commit") == null or
        std.mem.indexOf(u8, log_result.stdout, "Second commit") == null or
        std.mem.indexOf(u8, log_result.stdout, "Third commit") == null) {
        return error.LogMissingCommits;
    }
}

// Test add with wildcards/patterns
fn test_git_add_patterns(ctx: *TestContext) !void {
    const test_dir = try ctx.createTestDir("add-patterns");
    defer ctx.allocator.free(test_dir);
    
    // Initialize repository
    var init_result = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "init" }, test_dir);
    defer init_result.deinit(ctx.allocator);
    if (init_result.exit_code != 0) return error.InitFailed;
    
    // Create multiple files with different extensions
    try ctx.writeFile(test_dir, "file1.txt", "Text file 1");
    try ctx.writeFile(test_dir, "file2.txt", "Text file 2");
    try ctx.writeFile(test_dir, "script.sh", "#!/bin/bash\necho hello");
    try ctx.writeFile(test_dir, "data.json", "{}");
    
    // Add all files with wildcard
    var add_result = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "add", "." }, test_dir);
    defer add_result.deinit(ctx.allocator);
    
    if (add_result.exit_code != 0) return error.AddFailed;
    
    // Check status to see all files are staged
    var status_result = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "status" }, test_dir);
    defer status_result.deinit(ctx.allocator);
    
    if (status_result.exit_code != 0) return error.StatusFailed;
    
    // Should show staged files
    if (std.mem.indexOf(u8, status_result.stdout, "file1.txt") == null or
        std.mem.indexOf(u8, status_result.stdout, "file2.txt") == null or
        std.mem.indexOf(u8, status_result.stdout, "script.sh") == null or
        std.mem.indexOf(u8, status_result.stdout, "data.json") == null) {
        return error.StatusMissingStagedFiles;
    }
}

// Test status with staged and unstaged changes
fn test_git_status_mixed_changes(ctx: *TestContext) !void {
    const test_dir = try ctx.createTestDir("status-mixed");
    defer ctx.allocator.free(test_dir);
    
    // Initialize repository
    var init_result = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "init" }, test_dir);
    defer init_result.deinit(ctx.allocator);
    if (init_result.exit_code != 0) return error.InitFailed;
    
    // Create initial commit
    try ctx.writeFile(test_dir, "tracked.txt", "Initial content");
    var add_result1 = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "add", "tracked.txt" }, test_dir);
    defer add_result1.deinit(ctx.allocator);
    if (add_result1.exit_code != 0) return error.AddFailed;
    
    var commit_result = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "commit", "-m", "Initial commit" }, test_dir);
    defer commit_result.deinit(ctx.allocator);
    if (commit_result.exit_code != 0) return error.CommitFailed;
    
    // Stage a change
    try ctx.writeFile(test_dir, "staged.txt", "Staged content");
    var add_result2 = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "add", "staged.txt" }, test_dir);
    defer add_result2.deinit(ctx.allocator);
    if (add_result2.exit_code != 0) return error.AddFailed;
    
    // Make unstaged changes to tracked file
    try ctx.writeFile(test_dir, "tracked.txt", "Modified content");
    
    // Create untracked file
    try ctx.writeFile(test_dir, "untracked.txt", "Untracked content");
    
    // Test status
    var status_result = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "status" }, test_dir);
    defer status_result.deinit(ctx.allocator);
    
    if (status_result.exit_code != 0) return error.StatusFailed;
    
    // Should show all different types of changes
    const output = status_result.stdout;
    
    // Check for presence of different file states - the exact format may vary
    var has_staged = false;
    var has_modified = false;
    var has_untracked = false;
    
    if (std.mem.indexOf(u8, output, "staged.txt") != null) has_staged = true;
    if (std.mem.indexOf(u8, output, "tracked.txt") != null) has_modified = true;
    if (std.mem.indexOf(u8, output, "untracked.txt") != null) has_untracked = true;
    
    if (!has_staged or !has_modified or !has_untracked) {
        return error.StatusMissingFileStates;
    }
}

// Test commit with different message formats
fn test_git_commit_messages(ctx: *TestContext) !void {
    const test_dir = try ctx.createTestDir("commit-messages");
    defer ctx.allocator.free(test_dir);
    
    // Initialize repository
    var init_result = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "init" }, test_dir);
    defer init_result.deinit(ctx.allocator);
    if (init_result.exit_code != 0) return error.InitFailed;
    
    // Test commit with multi-word message
    try ctx.writeFile(test_dir, "test1.txt", "Test file 1");
    var add_result1 = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "add", "test1.txt" }, test_dir);
    defer add_result1.deinit(ctx.allocator);
    if (add_result1.exit_code != 0) return error.AddFailed;
    
    var commit_result1 = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "commit", "-m", "Add test file with detailed message" }, test_dir);
    defer commit_result1.deinit(ctx.allocator);
    if (commit_result1.exit_code != 0) return error.CommitFailed;
    
    // Test commit with special characters
    try ctx.writeFile(test_dir, "test2.txt", "Test file 2");
    var add_result2 = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "add", "test2.txt" }, test_dir);
    defer add_result2.deinit(ctx.allocator);
    if (add_result2.exit_code != 0) return error.AddFailed;
    
    var commit_result2 = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "commit", "-m", "Fix: issue #123 (with special chars!)" }, test_dir);
    defer commit_result2.deinit(ctx.allocator);
    if (commit_result2.exit_code != 0) return error.CommitFailed;
    
    // Verify both commits in log
    var log_result = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "log" }, test_dir);
    defer log_result.deinit(ctx.allocator);
    
    if (log_result.exit_code != 0) return error.LogFailed;
    
    if (std.mem.indexOf(u8, log_result.stdout, "detailed message") == null or
        std.mem.indexOf(u8, log_result.stdout, "special chars") == null) {
        return error.LogMissingCommitMessages;
    }
}

// Test error conditions and edge cases
fn test_git_error_handling(ctx: *TestContext) !void {
    const test_dir = try ctx.createTestDir("error-handling");
    defer ctx.allocator.free(test_dir);
    
    // Test command in non-git directory
    var status_result = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "status" }, test_dir);
    defer status_result.deinit(ctx.allocator);
    
    // Should fail gracefully
    if (status_result.exit_code == 0) return error.StatusShouldFailInNonGitDir;
    
    // Initialize repository for further tests
    var init_result = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "init" }, test_dir);
    defer init_result.deinit(ctx.allocator);
    if (init_result.exit_code != 0) return error.InitFailed;
    
    // Test add non-existent file
    var add_result = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "add", "nonexistent.txt" }, test_dir);
    defer add_result.deinit(ctx.allocator);
    
    // Should fail
    if (add_result.exit_code == 0) return error.AddShouldFailForNonExistentFile;
    
    // Test commit with nothing staged
    var commit_result = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "commit", "-m", "Nothing to commit" }, test_dir);
    defer commit_result.deinit(ctx.allocator);
    
    // Should fail or handle gracefully
    if (commit_result.exit_code == 0) return error.CommitShouldFailWithNothingStaged;
}

// Main test runner
pub fn runAdvancedGitCompatibilityTests(allocator: std.mem.Allocator) !void {
    var ctx = try TestContext.init(allocator);
    defer ctx.deinit();
    
    print("🔬 Running Advanced Git Compatibility Tests\n", .{});
    print("===========================================\n\n", .{});
    
    // Diff functionality tests
    print("📋 Diff Command Tests:\n", .{});
    ctx.expectSuccess("diff staged changes", test_git_diff_staged);
    
    // Checkout/branching tests
    print("\n🌿 Checkout/Branch Tests:\n", .{});
    ctx.expectSuccess("checkout new branch", test_git_checkout_branch);
    
    // Log and history tests
    print("\n📚 Log/History Tests:\n", .{});
    ctx.expectSuccess("log multiple commits", test_git_log_history);
    
    // Advanced add functionality
    print("\n📂 Advanced Add Tests:\n", .{});
    ctx.expectSuccess("add with patterns", test_git_add_patterns);
    
    // Complex status scenarios
    print("\n📊 Complex Status Tests:\n", .{});
    ctx.expectSuccess("status with mixed changes", test_git_status_mixed_changes);
    
    // Commit message handling
    print("\n💬 Commit Message Tests:\n", .{});
    ctx.expectSuccess("commit message handling", test_git_commit_messages);
    
    // Error handling tests
    print("\n⚠️  Error Handling Tests:\n", .{});
    ctx.expectSuccess("error condition handling", test_git_error_handling);
    
    print("\n", .{});
    ctx.printSummary();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    try runAdvancedGitCompatibilityTests(allocator);
}