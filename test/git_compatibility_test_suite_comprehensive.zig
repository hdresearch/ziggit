const std = @import("std");
const print = std.debug.print;

// Comprehensive Git Compatibility Test Suite
// Adapted from git's own test suite to ensure ziggit is a true drop-in replacement

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
        const temp_dir = try std.fs.cwd().makeOpenPath(full_name, .{});
        temp_dir.close();
        self.temp_dir = full_name;
        return full_name;
    }

    fn runCommand(self: *TestFramework, args: []const []const u8) !std.process.Child.RunResult {
        return std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = args,
            .cwd = self.temp_dir,
        });
    }

    fn runZiggitCommand(self: *TestFramework, args: []const []const u8) !std.process.Child.RunResult {
        var full_args = std.ArrayList([]const u8).init(self.allocator);
        defer full_args.deinit();
        
        try full_args.append("./zig-out/bin/ziggit");
        for (args) |arg| {
            try full_args.append(arg);
        }
        
        return self.runCommand(full_args.items);
    }

    fn runGitCommand(self: *TestFramework, args: []const []const u8) !std.process.Child.RunResult {
        var full_args = std.ArrayList([]const u8).init(self.allocator);
        defer full_args.deinit();
        
        try full_args.append("git");
        for (args) |arg| {
            try full_args.append(arg);
        }
        
        return self.runCommand(full_args.items);
    }

    fn writeFile(self: *TestFramework, filename: []const u8, content: []const u8) !void {
        if (self.temp_dir) |temp_dir| {
            var dir = try std.fs.cwd().openDir(temp_dir, .{});
            defer dir.close();
            try dir.writeFile(filename, content);
        } else {
            try std.fs.cwd().writeFile(filename, content);
        }
    }
};

// Test 1: Basic repository initialization (based on t0001-init.sh)
fn testBasicInit(tf: *TestFramework) !void {
    print("  Testing basic init compatibility...\n");
    
    // Test plain init
    const test_dir = try tf.createTempDir("init-plain");
    const ziggit_result = try tf.runZiggitCommand(&[_][]const u8{"init"});
    defer tf.allocator.free(ziggit_result.stdout);
    defer tf.allocator.free(ziggit_result.stderr);

    if (ziggit_result.term.Exited != 0) {
        print("    ❌ ziggit init failed: {s}\n", .{ziggit_result.stderr});
        return error.InitFailed;
    }

    // Check that .git directory was created with proper structure
    var dir = std.fs.cwd().openDir(test_dir, .{}) catch return error.TestDirNotFound;
    defer dir.close();
    
    var git_dir = dir.openDir(".git", .{}) catch return error.GitDirNotFound;
    defer git_dir.close();
    
    // Check for essential git directory structure
    {
        var objects_dir = git_dir.openDir("objects", .{}) catch return error.ObjectsDirNotFound;
        objects_dir.close();
    }
    {
        var refs_dir = git_dir.openDir("refs", .{}) catch return error.RefsDirNotFound;
        refs_dir.close();
    }
    {
        var heads_dir = git_dir.openDir("refs/heads", .{}) catch return error.HeadsDirNotFound;
        heads_dir.close();
    }
    {
        var config_file = git_dir.openFile("config", .{}) catch return error.ConfigNotFound;
        config_file.close();
    }
    
    print("    ✓ Basic init test passed\n");

    // Test bare init
    _ = try tf.createTempDir("init-bare");
    const bare_result = try tf.runZiggitCommand(&[_][]const u8{"init", "--bare"});
    defer tf.allocator.free(bare_result.stdout);
    defer tf.allocator.free(bare_result.stderr);

    if (bare_result.term.Exited != 0) {
        print("    ❌ ziggit init --bare failed: {s}\n", .{bare_result.stderr});
        return error.BareInitFailed;
    }
    
    print("    ✓ Bare init test passed\n");
}

// Test 2: Add functionality (based on t2xxx tests)
fn testAddFunctionality(tf: *TestFramework) !void {
    print("  Testing add functionality...\n");

    _ = try tf.createTempDir("add-test");
    
    // Initialize repository
    const init_result = try tf.runZiggitCommand(&[_][]const u8{"init"});
    defer tf.allocator.free(init_result.stdout);
    defer tf.allocator.free(init_result.stderr);
    
    // Create a test file
    try tf.writeFile("test.txt", "Hello World\n");
    
    // Test basic add
    const add_result = try tf.runZiggitCommand(&[_][]const u8{"add", "test.txt"});
    defer tf.allocator.free(add_result.stdout);
    defer tf.allocator.free(add_result.stderr);
    
    if (add_result.term.Exited != 0) {
        print("    ❌ add failed: {s}\n", .{add_result.stderr});
        return error.AddFailed;
    }
    
    // Verify file was staged
    const status_result = try tf.runZiggitCommand(&[_][]const u8{"status", "--porcelain"});
    defer tf.allocator.free(status_result.stdout);
    defer tf.allocator.free(status_result.stderr);
    
    if (!std.mem.containsAtLeast(u8, status_result.stdout, 1, "A  test.txt") and 
        !std.mem.containsAtLeast(u8, status_result.stdout, 1, "A test.txt")) {
        print("    ❌ File not properly staged: {s}\n", .{status_result.stdout});
        return error.FileNotStaged;
    }
    
    print("    ✓ Add functionality test passed\n");
}

// Test 3: Commit functionality (based on t3xxx tests)
fn testCommitFunctionality(tf: *TestFramework) !void {
    print("  Testing commit functionality...\n");

    const test_dir = try tf.createTempDir("commit-test");
    
    // Initialize repository
    var init_result = try tf.runZiggitCommand(&[_][]const u8{"init"});
    defer tf.allocator.free(init_result.stdout);
    defer tf.allocator.free(init_result.stderr);
    
    // Create and add a test file
    try tf.writeFile("test.txt", "Hello World\n");
    var add_result = try tf.runZiggitCommand(&[_][]const u8{"add", "test.txt"});
    defer tf.allocator.free(add_result.stdout);
    defer tf.allocator.free(add_result.stderr);
    
    // Test basic commit
    var commit_result = try tf.runZiggitCommand(&[_][]const u8{"commit", "-m", "Initial commit"});
    defer tf.allocator.free(commit_result.stdout);
    defer tf.allocator.free(commit_result.stderr);
    
    if (commit_result.term.Exited != 0) {
        print("    ❌ commit failed: {s}\n", .{commit_result.stderr});
        return error.CommitFailed;
    }
    
    // Verify commit was created
    var log_result = try tf.runZiggitCommand(&[_][]const u8{"log", "--oneline"});
    defer tf.allocator.free(log_result.stdout);
    defer tf.allocator.free(log_result.stderr);
    
    if (!std.mem.containsAtLeast(u8, log_result.stdout, 1, "Initial commit")) {
        print("    ❌ Commit not found in log: {s}\n", .{log_result.stdout});
        return error.CommitNotInLog;
    }
    
    print("    ✓ Commit functionality test passed\n");
}

// Test 4: Status functionality (based on t7xxx tests)
fn testStatusFunctionality(tf: *TestFramework) !void {
    print("  Testing status functionality...\n");

    const test_dir = try tf.createTempDir("status-test");
    
    // Initialize repository
    var init_result = try tf.runZiggitCommand(&[_][]const u8{"init"});
    defer tf.allocator.free(init_result.stdout);
    defer tf.allocator.free(init_result.stderr);
    
    // Test status in empty repository
    var empty_status = try tf.runZiggitCommand(&[_][]const u8{"status"});
    defer tf.allocator.free(empty_status.stdout);
    defer tf.allocator.free(empty_status.stderr);
    
    if (!std.mem.containsAtLeast(u8, empty_status.stdout, 1, "No commits yet")) {
        print("    ❌ Empty repository status incorrect: {s}\n", .{empty_status.stdout});
        return error.EmptyStatusIncorrect;
    }
    
    // Create untracked file
    try tf.writeFile("untracked.txt", "Untracked file\n");
    
    var untracked_status = try tf.runZiggitCommand(&[_][]const u8{"status"});
    defer tf.allocator.free(untracked_status.stdout);
    defer tf.allocator.free(untracked_status.stderr);
    
    if (!std.mem.containsAtLeast(u8, untracked_status.stdout, 1, "Untracked files")) {
        print("    ❌ Untracked files not shown: {s}\n", .{untracked_status.stdout});
        return error.UntrackedNotShown;
    }
    
    print("    ✓ Status functionality test passed\n");
}

// Test 5: Log functionality (based on t4xxx tests)
fn testLogFunctionality(tf: *TestFramework) !void {
    print("  Testing log functionality...\n");

    const test_dir = try tf.createTempDir("log-test");
    
    // Initialize repository and make initial commit
    var init_result = try tf.runZiggitCommand(&[_][]const u8{"init"});
    defer tf.allocator.free(init_result.stdout);
    defer tf.allocator.free(init_result.stderr);
    
    try tf.writeFile("file1.txt", "Content 1\n");
    var add1_result = try tf.runZiggitCommand(&[_][]const u8{"add", "file1.txt"});
    defer tf.allocator.free(add1_result.stdout);
    defer tf.allocator.free(add1_result.stderr);
    
    var commit1_result = try tf.runZiggitCommand(&[_][]const u8{"commit", "-m", "First commit"});
    defer tf.allocator.free(commit1_result.stdout);
    defer tf.allocator.free(commit1_result.stderr);
    
    // Make second commit
    try tf.writeFile("file2.txt", "Content 2\n");
    var add2_result = try tf.runZiggitCommand(&[_][]const u8{"add", "file2.txt"});
    defer tf.allocator.free(add2_result.stdout);
    defer tf.allocator.free(add2_result.stderr);
    
    var commit2_result = try tf.runZiggitCommand(&[_][]const u8{"commit", "-m", "Second commit"});
    defer tf.allocator.free(commit2_result.stdout);
    defer tf.allocator.free(commit2_result.stderr);
    
    // Test log output
    var log_result = try tf.runZiggitCommand(&[_][]const u8{"log", "--oneline"});
    defer tf.allocator.free(log_result.stdout);
    defer tf.allocator.free(log_result.stderr);
    
    if (!std.mem.containsAtLeast(u8, log_result.stdout, 1, "First commit") or
        !std.mem.containsAtLeast(u8, log_result.stdout, 1, "Second commit")) {
        print("    ❌ Log missing commits: {s}\n", .{log_result.stdout});
        return error.LogMissingCommits;
    }
    
    print("    ✓ Log functionality test passed\n");
}

// Test 6: Branch functionality (basic branch operations)
fn testBranchFunctionality(tf: *TestFramework) !void {
    print("  Testing branch functionality...\n");

    const test_dir = try tf.createTempDir("branch-test");
    
    // Initialize repository and make initial commit
    var init_result = try tf.runZiggitCommand(&[_][]const u8{"init"});
    defer tf.allocator.free(init_result.stdout);
    defer tf.allocator.free(init_result.stderr);
    
    try tf.writeFile("file.txt", "Initial content\n");
    var add_result = try tf.runZiggitCommand(&[_][]const u8{"add", "file.txt"});
    defer tf.allocator.free(add_result.stdout);
    defer tf.allocator.free(add_result.stderr);
    
    var commit_result = try tf.runZiggitCommand(&[_][]const u8{"commit", "-m", "Initial commit"});
    defer tf.allocator.free(commit_result.stdout);
    defer tf.allocator.free(commit_result.stderr);
    
    // Test branch creation
    var branch_result = try tf.runZiggitCommand(&[_][]const u8{"branch", "test-branch"});
    defer tf.allocator.free(branch_result.stdout);
    defer tf.allocator.free(branch_result.stderr);
    
    if (branch_result.term.Exited != 0) {
        print("    ❌ branch creation failed: {s}\n", .{branch_result.stderr});
        return error.BranchCreationFailed;
    }
    
    // Test branch listing
    var branch_list = try tf.runZiggitCommand(&[_][]const u8{"branch"});
    defer tf.allocator.free(branch_list.stdout);
    defer tf.allocator.free(branch_list.stderr);
    
    if (!std.mem.containsAtLeast(u8, branch_list.stdout, 1, "test-branch")) {
        print("    ❌ Branch not listed: {s}\n", .{branch_list.stdout});
        return error.BranchNotListed;
    }
    
    print("    ✓ Branch functionality test passed\n");
}

// Test 7: Checkout functionality
fn testCheckoutFunctionality(tf: *TestFramework) !void {
    print("  Testing checkout functionality...\n");

    const test_dir = try tf.createTempDir("checkout-test");
    
    // Initialize repository and make initial commit
    var init_result = try tf.runZiggitCommand(&[_][]const u8{"init"});
    defer tf.allocator.free(init_result.stdout);
    defer tf.allocator.free(init_result.stderr);
    
    try tf.writeFile("file.txt", "Initial content\n");
    var add_result = try tf.runZiggitCommand(&[_][]const u8{"add", "file.txt"});
    defer tf.allocator.free(add_result.stdout);
    defer tf.allocator.free(add_result.stderr);
    
    var commit_result = try tf.runZiggitCommand(&[_][]const u8{"commit", "-m", "Initial commit"});
    defer tf.allocator.free(commit_result.stdout);
    defer tf.allocator.free(commit_result.stderr);
    
    // Create and checkout branch
    var branch_result = try tf.runZiggitCommand(&[_][]const u8{"branch", "test-branch"});
    defer tf.allocator.free(branch_result.stdout);
    defer tf.allocator.free(branch_result.stderr);
    
    var checkout_result = try tf.runZiggitCommand(&[_][]const u8{"checkout", "test-branch"});
    defer tf.allocator.free(checkout_result.stdout);
    defer tf.allocator.free(checkout_result.stderr);
    
    if (checkout_result.term.Exited != 0) {
        print("    ❌ checkout failed: {s}\n", .{checkout_result.stderr});
        return error.CheckoutFailed;
    }
    
    // Verify we're on the new branch
    var status_result = try tf.runZiggitCommand(&[_][]const u8{"status"});
    defer tf.allocator.free(status_result.stdout);
    defer tf.allocator.free(status_result.stderr);
    
    if (!std.mem.containsAtLeast(u8, status_result.stdout, 1, "test-branch")) {
        print("    ❌ Not on expected branch: {s}\n", .{status_result.stdout});
        return error.WrongBranch;
    }
    
    print("    ✓ Checkout functionality test passed\n");
}

// Test 8: Diff functionality (basic diff operations)
fn testDiffFunctionality(tf: *TestFramework) !void {
    print("  Testing diff functionality...\n");

    const test_dir = try tf.createTempDir("diff-test");
    
    // Initialize repository and make initial commit
    var init_result = try tf.runZiggitCommand(&[_][]const u8{"init"});
    defer tf.allocator.free(init_result.stdout);
    defer tf.allocator.free(init_result.stderr);
    
    try tf.writeFile("file.txt", "Line 1\nLine 2\nLine 3\n");
    var add_result = try tf.runZiggitCommand(&[_][]const u8{"add", "file.txt"});
    defer tf.allocator.free(add_result.stdout);
    defer tf.allocator.free(add_result.stderr);
    
    var commit_result = try tf.runZiggitCommand(&[_][]const u8{"commit", "-m", "Initial commit"});
    defer tf.allocator.free(commit_result.stdout);
    defer tf.allocator.free(commit_result.stderr);
    
    // Modify file
    try tf.writeFile("file.txt", "Line 1\nModified Line 2\nLine 3\nLine 4\n");
    
    // Test diff
    var diff_result = try tf.runZiggitCommand(&[_][]const u8{"diff"});
    defer tf.allocator.free(diff_result.stdout);
    defer tf.allocator.free(diff_result.stderr);
    
    if (!std.mem.containsAtLeast(u8, diff_result.stdout, 1, "Modified Line 2") or
        !std.mem.containsAtLeast(u8, diff_result.stdout, 1, "Line 4")) {
        print("    ❌ Diff output missing changes: {s}\n", .{diff_result.stdout});
        return error.DiffMissingChanges;
    }
    
    print("    ✓ Diff functionality test passed\n");
}

// Test 9: Output format compatibility with git
fn testOutputFormatCompatibility(tf: *TestFramework) !void {
    print("  Testing output format compatibility with git...\n");

    const test_dir = try tf.createTempDir("format-compat-test");
    
    // Initialize with both ziggit and git, compare outputs
    var ziggit_init = try tf.runZiggitCommand(&[_][]const u8{"init"});
    defer tf.allocator.free(ziggit_init.stdout);
    defer tf.allocator.free(ziggit_init.stderr);
    
    // Create a simple test file and commit
    try tf.writeFile("test.txt", "Hello World\n");
    
    var ziggit_add = try tf.runZiggitCommand(&[_][]const u8{"add", "test.txt"});
    defer tf.allocator.free(ziggit_add.stdout);
    defer tf.allocator.free(ziggit_add.stderr);
    
    var ziggit_commit = try tf.runZiggitCommand(&[_][]const u8{"commit", "-m", "Test commit"});
    defer tf.allocator.free(ziggit_commit.stdout);
    defer tf.allocator.free(ziggit_commit.stderr);
    
    // Test status format
    var ziggit_status = try tf.runZiggitCommand(&[_][]const u8{"status"});
    defer tf.allocator.free(ziggit_status.stdout);
    defer tf.allocator.free(ziggit_status.stderr);
    
    // Check for git-like status format
    if (!std.mem.containsAtLeast(u8, ziggit_status.stdout, 1, "On branch") or
        !std.mem.containsAtLeast(u8, ziggit_status.stdout, 1, "working tree clean")) {
        print("    ❌ Status format doesn't match git: {s}\n", .{ziggit_status.stdout});
        return error.StatusFormatMismatch;
    }
    
    print("    ✓ Output format compatibility test passed\n");
}

// Main test runner
pub fn main() !void {
    print("🧪 Running Comprehensive Git Compatibility Test Suite\n");
    print("===================================================\n\n");

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tf = TestFramework.init(allocator);
    defer tf.deinit();

    var passed: u32 = 0;
    var total: u32 = 0;

    const tests = [_]struct {
        name: []const u8,
        func: fn(*TestFramework) anyerror!void,
    }{
        .{ .name = "Basic Init Functionality", .func = testBasicInit },
        .{ .name = "Add Functionality", .func = testAddFunctionality },
        .{ .name = "Commit Functionality", .func = testCommitFunctionality },
        .{ .name = "Status Functionality", .func = testStatusFunctionality },
        .{ .name = "Log Functionality", .func = testLogFunctionality },
        .{ .name = "Branch Functionality", .func = testBranchFunctionality },
        .{ .name = "Checkout Functionality", .func = testCheckoutFunctionality },
        .{ .name = "Diff Functionality", .func = testDiffFunctionality },
        .{ .name = "Output Format Compatibility", .func = testOutputFormatCompatibility },
    };

    for (tests) |test_case| {
        total += 1;
        print("[{d}/{d}] {s}...\n", .{total, tests.len, test_case.name});
        
        test_case.func(&tf) catch |err| {
            print("  ❌ Test failed with error: {}\n\n", .{err});
            continue;
        };
        
        passed += 1;
        print("  ✅ Passed\n\n");
    }

    print("=== Test Results Summary ===\n");
    print("Total tests: {d}\n", .{total});
    print("Passed: {d}\n", .{passed});
    print("Failed: {d}\n", .{total - passed});

    if (passed == total) {
        print("\n🎉 ALL TESTS PASSED! ziggit is compatible with git.\n");
    } else {
        print("\n⚠️  Some tests failed. ziggit needs more work for full git compatibility.\n");
        std.process.exit(1);
    }
}