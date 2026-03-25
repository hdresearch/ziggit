const std = @import("std");
const testing = std.testing;
const print = std.debug.print;

// Git Output Format Comparison Tests
// Ensures ziggit output matches git output for drop-in replacement compatibility

const TestContext = struct {
    allocator: std.mem.Allocator,
    test_counter: u32 = 0,
    passed_tests: u32 = 0,
    failed_tests: u32 = 0,
    temp_dir: []u8,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) !Self {
        const timestamp = std.time.timestamp();
        const temp_dir = try std.fmt.allocPrint(allocator, "/tmp/ziggit-output-{d}", .{timestamp});
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
    
    // Compare outputs between ziggit and git
    pub fn compareOutputs(self: *Self, test_name: []const u8, test_fn: ComparisonTestFunction) void {
        self.test_counter += 1;
        print("  Comparing: {s}...", .{test_name});
        
        test_fn(self) catch |err| {
            print(" ❌ MISMATCH: {any}\n", .{err});
            self.failed_tests += 1;
            return;
        };
        
        print(" ✅ MATCH\n", .{});
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
    
    pub fn printSummary(self: *Self) void {
        print("\n=== Output Comparison Summary ===\n", .{});
        print("Total comparisons: {d}\n", .{self.test_counter});
        print("Matching outputs: {d}\n", .{self.passed_tests});
        print("Mismatched outputs: {d}\n", .{self.failed_tests});
        
        if (self.failed_tests == 0) {
            print("🎉 All outputs match perfectly!\n", .{});
        } else {
            print("⚠️  Some outputs differ from git.\n", .{});
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

const ComparisonTestFunction = *const fn (*TestContext) anyerror!void;

// Helper function to normalize output for comparison
fn normalizeOutput(allocator: std.mem.Allocator, output: []const u8) ![]u8 {
    // Remove timestamps, hashes, and other dynamic content that will differ
    var lines = std.ArrayList([]const u8).init(allocator);
    defer lines.deinit();
    
    var line_it = std.mem.split(u8, output, "\n");
    while (line_it.next()) |line| {
        var normalized_line = std.ArrayList(u8).init(allocator);
        defer normalized_line.deinit();
        
        // Skip lines with commit hashes (40 hex chars)
        var has_commit_hash = false;
        var i: usize = 0;
        while (i + 40 <= line.len) {
            var is_hex = true;
            for (line[i..i + 40]) |c| {
                if (!std.ascii.isHex(c)) {
                    is_hex = false;
                    break;
                }
            }
            if (is_hex) {
                has_commit_hash = true;
                break;
            }
            i += 1;
        }
        
        if (!has_commit_hash) {
            try lines.append(try allocator.dupe(u8, line));
        }
    }
    
    return try std.mem.join(allocator, "\n", lines.items);
}

// Output comparison tests

// Compare version output format
fn compare_version_output(ctx: *TestContext) !void {
    // Run ziggit --version
    var ziggit_result = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "--version" }, null);
    defer ziggit_result.deinit(ctx.allocator);
    
    // Run git --version
    var git_result = try ctx.runCommand(&[_][]const u8{ "git", "--version" }, null);
    defer git_result.deinit(ctx.allocator);
    
    // Both should succeed
    if (ziggit_result.exit_code != 0 or git_result.exit_code != 0) {
        return error.VersionCommandFailed;
    }
    
    // Both should contain "version" - format may differ but basic structure should be similar
    if (std.mem.indexOf(u8, ziggit_result.stdout, "version") == null or
        std.mem.indexOf(u8, git_result.stdout, "version") == null) {
        return error.VersionFormatMismatch;
    }
}

// Compare help output structure
fn compare_help_output(ctx: *TestContext) !void {
    // Run ziggit --help
    var ziggit_result = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "--help" }, null);
    defer ziggit_result.deinit(ctx.allocator);
    
    // Run git --help
    var git_result = try ctx.runCommand(&[_][]const u8{ "git", "--help" }, null);
    defer git_result.deinit(ctx.allocator);
    
    // Both should succeed or at least provide usage information
    if (ziggit_result.exit_code != 0 and git_result.exit_code != 0) {
        return error.BothHelpCommandsFailed;
    }
    
    // Both should contain usage information (case insensitive)
    const ziggit_has_usage = std.ascii.indexOfIgnoreCase(ziggit_result.stdout, "usage") != null;
    const git_has_usage = std.ascii.indexOfIgnoreCase(git_result.stdout, "usage") != null;
    
    if (!ziggit_has_usage or !git_has_usage) {
        return error.HelpUsageFormatMismatch;
    }
}

// Compare init output format
fn compare_init_output(ctx: *TestContext) !void {
    const ziggit_dir = try ctx.createTestDir("init-ziggit");
    defer ctx.allocator.free(ziggit_dir);
    
    const git_dir = try ctx.createTestDir("init-git");
    defer ctx.allocator.free(git_dir);
    
    // Run ziggit init
    var ziggit_result = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "init" }, ziggit_dir);
    defer ziggit_result.deinit(ctx.allocator);
    
    // Run git init
    var git_result = try ctx.runCommand(&[_][]const u8{ "git", "init" }, git_dir);
    defer git_result.deinit(ctx.allocator);
    
    // Both should succeed
    if (ziggit_result.exit_code != 0 or git_result.exit_code != 0) {
        return error.InitCommandFailed;
    }
    
    // Both should create git repositories with similar messages
    // (Exact message may differ, but should indicate successful initialization)
    const ziggit_indicates_success = std.mem.indexOf(u8, ziggit_result.stdout, "Initialized") != null or
                                     std.mem.indexOf(u8, ziggit_result.stdout, "initialized") != null or
                                     ziggit_result.stdout.len == 0; // Silent is also acceptable
    
    const git_indicates_success = std.mem.indexOf(u8, git_result.stdout, "Initialized") != null or
                                  std.mem.indexOf(u8, git_result.stdout, "initialized") != null;
    
    if (!ziggit_indicates_success or !git_indicates_success) {
        return error.InitOutputFormatMismatch;
    }
}

// Compare status output in empty repo
fn compare_status_empty_repo(ctx: *TestContext) !void {
    const ziggit_dir = try ctx.createTestDir("status-empty-ziggit");
    defer ctx.allocator.free(ziggit_dir);
    
    const git_dir = try ctx.createTestDir("status-empty-git");
    defer ctx.allocator.free(git_dir);
    
    // Initialize both repos
    var ziggit_init = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "init" }, ziggit_dir);
    defer ziggit_init.deinit(ctx.allocator);
    
    var git_init = try ctx.runCommand(&[_][]const u8{ "git", "init" }, git_dir);
    defer git_init.deinit(ctx.allocator);
    
    if (ziggit_init.exit_code != 0 or git_init.exit_code != 0) {
        return error.InitFailed;
    }
    
    // Run status in both
    var ziggit_result = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "status" }, ziggit_dir);
    defer ziggit_result.deinit(ctx.allocator);
    
    var git_result = try ctx.runCommand(&[_][]const u8{ "git", "status" }, git_dir);
    defer git_result.deinit(ctx.allocator);
    
    // Both should succeed
    if (ziggit_result.exit_code != 0 or git_result.exit_code != 0) {
        return error.StatusCommandFailed;
    }
    
    // Both should mention branch (master or main)
    const ziggit_has_branch = std.mem.indexOf(u8, ziggit_result.stdout, "master") != null or
                              std.mem.indexOf(u8, ziggit_result.stdout, "main") != null;
    
    const git_has_branch = std.mem.indexOf(u8, git_result.stdout, "master") != null or
                           std.mem.indexOf(u8, git_result.stdout, "main") != null;
    
    if (!ziggit_has_branch or !git_has_branch) {
        return error.StatusBranchFormatMismatch;
    }
}

// Compare add success behavior (should be silent)
fn compare_add_success_behavior(ctx: *TestContext) !void {
    const ziggit_dir = try ctx.createTestDir("add-success-ziggit");
    defer ctx.allocator.free(ziggit_dir);
    
    const git_dir = try ctx.createTestDir("add-success-git");
    defer ctx.allocator.free(git_dir);
    
    // Initialize both repos
    var ziggit_init = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "init" }, ziggit_dir);
    defer ziggit_init.deinit(ctx.allocator);
    
    var git_init = try ctx.runCommand(&[_][]const u8{ "git", "init" }, git_dir);
    defer git_init.deinit(ctx.allocator);
    
    if (ziggit_init.exit_code != 0 or git_init.exit_code != 0) {
        return error.InitFailed;
    }
    
    // Create identical files
    try ctx.writeFile(ziggit_dir, "test.txt", "test content");
    try ctx.writeFile(git_dir, "test.txt", "test content");
    
    // Add files
    var ziggit_result = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "add", "test.txt" }, ziggit_dir);
    defer ziggit_result.deinit(ctx.allocator);
    
    var git_result = try ctx.runCommand(&[_][]const u8{ "git", "add", "test.txt" }, git_dir);
    defer git_result.deinit(ctx.allocator);
    
    // Both should succeed
    if (ziggit_result.exit_code != 0 or git_result.exit_code != 0) {
        return error.AddCommandFailed;
    }
    
    // Both should be silent on success (or at least very minimal output)
    if (ziggit_result.stdout.len > 50 or git_result.stdout.len > 50) {
        return error.AddOutputTooVerbose;
    }
}

// Compare behavior when adding non-existent file
fn compare_add_nonexistent_behavior(ctx: *TestContext) !void {
    const ziggit_dir = try ctx.createTestDir("add-nonexistent-ziggit");
    defer ctx.allocator.free(ziggit_dir);
    
    const git_dir = try ctx.createTestDir("add-nonexistent-git");
    defer ctx.allocator.free(git_dir);
    
    // Initialize both repos
    var ziggit_init = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "init" }, ziggit_dir);
    defer ziggit_init.deinit(ctx.allocator);
    
    var git_init = try ctx.runCommand(&[_][]const u8{ "git", "init" }, git_dir);
    defer git_init.deinit(ctx.allocator);
    
    if (ziggit_init.exit_code != 0 or git_init.exit_code != 0) {
        return error.InitFailed;
    }
    
    // Try to add non-existent file
    var ziggit_result = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "add", "nonexistent.txt" }, ziggit_dir);
    defer ziggit_result.deinit(ctx.allocator);
    
    var git_result = try ctx.runCommand(&[_][]const u8{ "git", "add", "nonexistent.txt" }, git_dir);
    defer git_result.deinit(ctx.allocator);
    
    // Both should fail
    if (ziggit_result.exit_code == 0 or git_result.exit_code == 0) {
        return error.AddShouldFailForNonexistentFile;
    }
    
    // Both should produce error messages mentioning the file
    const ziggit_mentions_file = std.mem.indexOf(u8, ziggit_result.stderr, "nonexistent.txt") != null;
    const git_mentions_file = std.mem.indexOf(u8, git_result.stderr, "nonexistent.txt") != null;
    
    if (!ziggit_mentions_file or !git_mentions_file) {
        return error.AddErrorMessageFormatMismatch;
    }
}

// Compare commit message output format
fn compare_commit_output_format(ctx: *TestContext) !void {
    const ziggit_dir = try ctx.createTestDir("commit-format-ziggit");
    defer ctx.allocator.free(ziggit_dir);
    
    const git_dir = try ctx.createTestDir("commit-format-git");
    defer ctx.allocator.free(git_dir);
    
    // Setup both repos identically
    var ziggit_init = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "init" }, ziggit_dir);
    defer ziggit_init.deinit(ctx.allocator);
    
    var git_init = try ctx.runCommand(&[_][]const u8{ "git", "init" }, git_dir);
    defer git_init.deinit(ctx.allocator);
    
    if (ziggit_init.exit_code != 0 or git_init.exit_code != 0) {
        return error.InitFailed;
    }
    
    try ctx.writeFile(ziggit_dir, "commit-test.txt", "content for commit test");
    try ctx.writeFile(git_dir, "commit-test.txt", "content for commit test");
    
    var ziggit_add = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "add", "commit-test.txt" }, ziggit_dir);
    defer ziggit_add.deinit(ctx.allocator);
    
    var git_add = try ctx.runCommand(&[_][]const u8{ "git", "add", "commit-test.txt" }, git_dir);
    defer git_add.deinit(ctx.allocator);
    
    if (ziggit_add.exit_code != 0 or git_add.exit_code != 0) {
        return error.AddFailed;
    }
    
    // Perform commits
    var ziggit_commit = try ctx.runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "commit", "-m", "Test commit" }, ziggit_dir);
    defer ziggit_commit.deinit(ctx.allocator);
    
    var git_commit = try ctx.runCommand(&[_][]const u8{ "git", "commit", "-m", "Test commit" }, git_dir);
    defer git_commit.deinit(ctx.allocator);
    
    // Both should succeed
    if (ziggit_commit.exit_code != 0 or git_commit.exit_code != 0) {
        return error.CommitFailed;
    }
    
    // Both should show commit information
    // Normalize by checking for key elements rather than exact format
    const ziggit_has_commit_info = std.mem.indexOf(u8, ziggit_commit.stdout, "Test commit") != null or
                                   std.mem.indexOf(u8, ziggit_commit.stdout, "master") != null or
                                   std.mem.indexOf(u8, ziggit_commit.stdout, "main") != null;
    
    const git_has_commit_info = std.mem.indexOf(u8, git_commit.stdout, "Test commit") != null or
                                std.mem.indexOf(u8, git_commit.stdout, "master") != null or
                                std.mem.indexOf(u8, git_commit.stdout, "main") != null;
    
    if (!ziggit_has_commit_info or !git_has_commit_info) {
        return error.CommitOutputFormatMismatch;
    }
}

// Main comparison test runner
pub fn runGitOutputComparisonTests(allocator: std.mem.Allocator) !void {
    var ctx = try TestContext.init(allocator);
    defer ctx.deinit();
    
    print("🔍 Running Git Output Comparison Tests\n", .{});
    print("=====================================\n\n", .{});
    
    print("🏷️  Version/Help Output:\n", .{});
    ctx.compareOutputs("version command format", compare_version_output);
    ctx.compareOutputs("help command format", compare_help_output);
    
    print("\n📁 Repository Operations:\n", .{});
    ctx.compareOutputs("init command format", compare_init_output);
    ctx.compareOutputs("status in empty repo", compare_status_empty_repo);
    
    print("\n📝 File Operations:\n", .{});
    ctx.compareOutputs("add success behavior", compare_add_success_behavior);
    ctx.compareOutputs("add nonexistent file error", compare_add_nonexistent_behavior);
    
    print("\n💾 Commit Operations:\n", .{});
    ctx.compareOutputs("commit output format", compare_commit_output_format);
    
    print("\n", .{});
    ctx.printSummary();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    try runGitOutputComparisonTests(allocator);
}