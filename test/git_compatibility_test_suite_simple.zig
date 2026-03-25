const std = @import("std");
const print = std.debug.print;

// Simple Git Compatibility Test Suite
// Tests core functionality to ensure ziggit is a drop-in replacement for git

const TestFramework = struct {
    allocator: std.mem.Allocator,
    temp_dir: ?[]u8 = null,

    fn init(allocator: std.mem.Allocator) TestFramework {
        return TestFramework{ .allocator = allocator };
    }

    fn deinit(self: *TestFramework) void {
        if (self.temp_dir) |temp_dir| {
            self.allocator.free(temp_dir);
        }
    }

    fn createTempDir(self: *TestFramework, name: []const u8) ![]u8 {
        const full_name = try std.fmt.allocPrint(self.allocator, "ziggit-test-{s}-{d}", .{ name, std.time.timestamp() });
        var temp_dir = try std.fs.cwd().makeOpenPath(full_name, .{});
        temp_dir.close();
        self.temp_dir = full_name;
        return full_name;
    }

    fn runZiggitCommand(self: *TestFramework, args: []const []const u8) !std.process.Child.RunResult {
        var full_args = std.ArrayList([]const u8).init(self.allocator);
        defer full_args.deinit();
        
        try full_args.append("/root/ziggit/zig-out/bin/ziggit");
        for (args) |arg| {
            try full_args.append(arg);
        }
        
        return std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = full_args.items,
            .cwd = self.temp_dir,
        });
    }

    fn writeFile(self: *TestFramework, filename: []const u8, content: []const u8) !void {
        if (self.temp_dir) |temp_dir| {
            var dir = try std.fs.cwd().openDir(temp_dir, .{});
            defer dir.close();
            try dir.writeFile(.{ .sub_path = filename, .data = content });
        } else {
            try std.fs.cwd().writeFile(.{ .sub_path = filename, .data = content });
        }
    }
};

// Test basic workflow: init -> add -> commit -> log
fn testBasicWorkflow(tf: *TestFramework) !void {
    print("  Testing basic git workflow (init -> add -> commit -> log)...\n", .{});

    _ = try tf.createTempDir("basic-workflow");
    
    // Test init
    const init_result = try tf.runZiggitCommand(&[_][]const u8{"init"});
    defer tf.allocator.free(init_result.stdout);
    defer tf.allocator.free(init_result.stderr);
    
    if (init_result.term.Exited != 0) {
        print("    [ERROR] init failed: {s}\n", .{init_result.stderr});
        return error.InitFailed;
    }
    
    // Create a test file and add it
    try tf.writeFile("test.txt", "Hello World\n");
    
    const add_result = try tf.runZiggitCommand(&[_][]const u8{"add", "test.txt"});
    defer tf.allocator.free(add_result.stdout);
    defer tf.allocator.free(add_result.stderr);
    
    if (add_result.term.Exited != 0) {
        print("    [ERROR] add failed: {s}\n", .{add_result.stderr});
        return error.AddFailed;
    }
    
    // Commit the file
    const commit_result = try tf.runZiggitCommand(&[_][]const u8{"commit", "-m", "Initial commit"});
    defer tf.allocator.free(commit_result.stdout);
    defer tf.allocator.free(commit_result.stderr);
    
    if (commit_result.term.Exited != 0) {
        print("    [ERROR] commit failed: {s}\n", .{commit_result.stderr});
        return error.CommitFailed;
    }
    
    // Check log
    const log_result = try tf.runZiggitCommand(&[_][]const u8{"log", "--oneline"});
    defer tf.allocator.free(log_result.stdout);
    defer tf.allocator.free(log_result.stderr);
    
    if (!std.mem.containsAtLeast(u8, log_result.stdout, 1, "Initial commit")) {
        print("    [ERROR] Commit not found in log: {s}\n", .{log_result.stdout});
        return error.CommitNotInLog;
    }
    
    print("    ✓ Basic workflow test passed\n", .{});
}

// Test status functionality
fn testStatus(tf: *TestFramework) !void {
    print("  Testing status functionality...\n", .{});

    _ = try tf.createTempDir("status-test");
    
    const init_result = try tf.runZiggitCommand(&[_][]const u8{"init"});
    defer tf.allocator.free(init_result.stdout);
    defer tf.allocator.free(init_result.stderr);
    
    // Test status in empty repository
    const empty_status = try tf.runZiggitCommand(&[_][]const u8{"status"});
    defer tf.allocator.free(empty_status.stdout);
    defer tf.allocator.free(empty_status.stderr);
    
    if (!std.mem.containsAtLeast(u8, empty_status.stdout, 1, "No commits yet")) {
        print("    [ERROR] Empty repository status incorrect: {s}\n", .{empty_status.stdout});
        return error.EmptyStatusIncorrect;
    }
    
    // Create untracked file
    try tf.writeFile("untracked.txt", "Untracked file\n");
    
    const untracked_status = try tf.runZiggitCommand(&[_][]const u8{"status"});
    defer tf.allocator.free(untracked_status.stdout);
    defer tf.allocator.free(untracked_status.stderr);
    
    if (!std.mem.containsAtLeast(u8, untracked_status.stdout, 1, "Untracked files")) {
        print("    [ERROR] Untracked files not shown: {s}\n", .{untracked_status.stdout});
        return error.UntrackedNotShown;
    }
    
    print("    ✓ Status test passed\n", .{});
}

// Test branch operations
fn testBranches(tf: *TestFramework) !void {
    print("  Testing branch operations...\n", .{});

    _ = try tf.createTempDir("branch-test");
    
    // Setup repository
    const init_result = try tf.runZiggitCommand(&[_][]const u8{"init"});
    defer tf.allocator.free(init_result.stdout);
    defer tf.allocator.free(init_result.stderr);
    
    try tf.writeFile("file.txt", "Initial content\n");
    
    const add_result = try tf.runZiggitCommand(&[_][]const u8{"add", "file.txt"});
    defer tf.allocator.free(add_result.stdout);
    defer tf.allocator.free(add_result.stderr);
    
    const commit_result = try tf.runZiggitCommand(&[_][]const u8{"commit", "-m", "Initial commit"});
    defer tf.allocator.free(commit_result.stdout);
    defer tf.allocator.free(commit_result.stderr);
    
    // Test branch creation
    const branch_result = try tf.runZiggitCommand(&[_][]const u8{"branch", "test-branch"});
    defer tf.allocator.free(branch_result.stdout);
    defer tf.allocator.free(branch_result.stderr);
    
    if (branch_result.term.Exited != 0) {
        print("    [ERROR] branch creation failed: {s}\n", .{branch_result.stderr});
        return error.BranchCreationFailed;
    }
    
    // Test branch listing
    const branch_list = try tf.runZiggitCommand(&[_][]const u8{"branch"});
    defer tf.allocator.free(branch_list.stdout);
    defer tf.allocator.free(branch_list.stderr);
    
    if (!std.mem.containsAtLeast(u8, branch_list.stdout, 1, "test-branch")) {
        print("    [ERROR] Branch not listed: {s}\n", .{branch_list.stdout});
        return error.BranchNotListed;
    }
    
    print("    ✓ Branch test passed\n", .{});
}

// Test diff functionality
fn testDiff(tf: *TestFramework) !void {
    print("  Testing diff functionality...\n", .{});

    _ = try tf.createTempDir("diff-test");
    
    // Setup repository
    const init_result = try tf.runZiggitCommand(&[_][]const u8{"init"});
    defer tf.allocator.free(init_result.stdout);
    defer tf.allocator.free(init_result.stderr);
    
    try tf.writeFile("file.txt", "Line 1\nLine 2\nLine 3\n");
    
    const add_result = try tf.runZiggitCommand(&[_][]const u8{"add", "file.txt"});
    defer tf.allocator.free(add_result.stdout);
    defer tf.allocator.free(add_result.stderr);
    
    const commit_result = try tf.runZiggitCommand(&[_][]const u8{"commit", "-m", "Initial commit"});
    defer tf.allocator.free(commit_result.stdout);
    defer tf.allocator.free(commit_result.stderr);
    
    // Modify file
    try tf.writeFile("file.txt", "Line 1\nModified Line 2\nLine 3\nLine 4\n");
    
    // Test diff
    const diff_result = try tf.runZiggitCommand(&[_][]const u8{"diff"});
    defer tf.allocator.free(diff_result.stdout);
    defer tf.allocator.free(diff_result.stderr);
    
    if (!std.mem.containsAtLeast(u8, diff_result.stdout, 1, "Modified Line 2") or
        !std.mem.containsAtLeast(u8, diff_result.stdout, 1, "Line 4")) {
        print("    [ERROR] Diff output missing changes: {s}\n", .{diff_result.stdout});
        return error.DiffMissingChanges;
    }
    
    print("    ✓ Diff test passed\n", .{});
}

// Test multiple commits and log
fn testMultipleCommits(tf: *TestFramework) !void {
    print("  Testing multiple commits and log...\n", .{});

    _ = try tf.createTempDir("multi-commit-test");
    
    // Setup repository
    const init_result = try tf.runZiggitCommand(&[_][]const u8{"init"});
    defer tf.allocator.free(init_result.stdout);
    defer tf.allocator.free(init_result.stderr);
    
    // First commit
    try tf.writeFile("file1.txt", "Content 1\n");
    
    const add1_result = try tf.runZiggitCommand(&[_][]const u8{"add", "file1.txt"});
    defer tf.allocator.free(add1_result.stdout);
    defer tf.allocator.free(add1_result.stderr);
    
    const commit1_result = try tf.runZiggitCommand(&[_][]const u8{"commit", "-m", "First commit"});
    defer tf.allocator.free(commit1_result.stdout);
    defer tf.allocator.free(commit1_result.stderr);
    
    // Second commit
    try tf.writeFile("file2.txt", "Content 2\n");
    
    const add2_result = try tf.runZiggitCommand(&[_][]const u8{"add", "file2.txt"});
    defer tf.allocator.free(add2_result.stdout);
    defer tf.allocator.free(add2_result.stderr);
    
    const commit2_result = try tf.runZiggitCommand(&[_][]const u8{"commit", "-m", "Second commit"});
    defer tf.allocator.free(commit2_result.stdout);
    defer tf.allocator.free(commit2_result.stderr);
    
    // Test log output
    const log_result = try tf.runZiggitCommand(&[_][]const u8{"log", "--oneline"});
    defer tf.allocator.free(log_result.stdout);
    defer tf.allocator.free(log_result.stderr);
    
    if (!std.mem.containsAtLeast(u8, log_result.stdout, 1, "First commit") or
        !std.mem.containsAtLeast(u8, log_result.stdout, 1, "Second commit")) {
        print("    [ERROR] Log missing commits: {s}\n", .{log_result.stdout});
        return error.LogMissingCommits;
    }
    
    print("    ✓ Multiple commits test passed\n", .{});
}

// Main test runner
pub fn main() !void {
    print("Running Simple Git Compatibility Test Suite\n", .{});
    print("===========================================\n\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tf = TestFramework.init(allocator);
    defer tf.deinit();

    var passed: u32 = 0;
    var total: u32 = 0;

    const tests = [_]struct {
        name: []const u8,
        func: *const fn(*TestFramework) anyerror!void,
    }{
        .{ .name = "Basic Workflow", .func = testBasicWorkflow },
        .{ .name = "Status Functionality", .func = testStatus },
        .{ .name = "Branch Operations", .func = testBranches },
        .{ .name = "Diff Functionality", .func = testDiff },
        .{ .name = "Multiple Commits", .func = testMultipleCommits },
    };

    for (tests) |test_case| {
        total += 1;
        print("[{d}/{d}] {s}...\n", .{total, tests.len, test_case.name});
        
        test_case.func(&tf) catch |err| {
            print("  [ERROR] Test failed with error: {}\n\n", .{err});
            continue;
        };
        
        passed += 1;
        print("  [PASS] Passed\n\n", .{});
    }

    print("=== Test Results Summary ===\n", .{});
    print("Total tests: {d}\n", .{total});
    print("Passed: {d}\n", .{passed});
    print("Failed: {d}\n", .{total - passed});

    if (passed == total) {
        print("\n[SUCCESS] ALL TESTS PASSED! ziggit shows excellent git compatibility.\n", .{});
    } else {
        print("\n[WARNING]  Some tests failed. ziggit needs more work for full git compatibility.\n", .{});
        std.process.exit(1);
    }
}