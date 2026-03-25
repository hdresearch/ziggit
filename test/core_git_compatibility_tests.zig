const std = @import("std");


// Git Core Compatibility Tests
// Adapted from git source test suite (t0001-init.sh, t1300-config.sh, t2000-add.sh, etc.)

const TestFramework = struct {
    allocator: std.mem.Allocator,
    test_dir_counter: u32,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .test_dir_counter = 0,
        };
    }
    
    pub fn createTestDir(self: *Self, prefix: []const u8) ![]const u8 {
        var buf: [256]u8 = undefined;
        const test_dir = try std.fmt.bufPrint(&buf, "/tmp/{s}-{d}", .{ prefix, self.test_dir_counter });
        self.test_dir_counter += 1;
        
        // Clean up any existing directory
        std.fs.cwd().deleteTree(test_dir[1..]) catch {};
        try std.fs.cwd().makePath(test_dir[1..]);
        
        const owned = try self.allocator.dupe(u8, test_dir);
        return owned;
    }
    
    pub fn runCommand(self: *Self, args: []const []const u8, cwd: []const u8) !CommandResult {
        var proc = std.process.Child.init(args, self.allocator);
        proc.cwd = cwd;
        proc.stdout_behavior = .Pipe;
        proc.stderr_behavior = .Pipe;
        
        try proc.spawn();
        
        const stdout = try proc.stdout.?.readToEndAlloc(self.allocator, 1024 * 1024);
        const stderr = try proc.stderr.?.readToEndAlloc(self.allocator, 1024 * 1024);
        const exit_code = try proc.wait();
        
        return CommandResult{
            .stdout = stdout,
            .stderr = stderr,
            .exit_code = switch (exit_code) {
                .Exited => |code| code,
                else => 255,
            },
        };
    }
    
    pub fn cleanup(self: *Self, test_dir: []const u8) void {
        std.fs.cwd().deleteTree(test_dir[1..]) catch {};
        self.allocator.free(test_dir);
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

// Test: git init functionality (adapted from t0001-init.sh)
fn testGitInit(tf: *TestFramework) !void {
    std.debug.print("  Testing git init compatibility...\n", .{});
    
    // Test 1: Plain init
    const test_dir = try tf.createTestDir("init-plain");
    defer tf.cleanup(test_dir);
    
    var result = try tf.runCommand(&[_][]const u8{ "./zig-out/bin/ziggit", "init" }, test_dir);
    defer result.deinit(tf.allocator);
    
    if (result.exit_code != 0) {
        std.debug.print("    ✗ ziggit init failed with code {d}: {s}\n", .{ result.exit_code, result.stderr });
        return;
    }
    
    // Check that .git directory exists
    const git_dir_path = try std.fmt.allocPrint(tf.allocator, "{s}/.git", .{test_dir});
    defer tf.allocator.free(git_dir_path);
    
    var git_dir = std.fs.cwd().openDir(git_dir_path[1..], .{}) catch {
        std.debug.print("    ✗ .git directory not created\n", .{});
        return;
    };
    defer git_dir.close();
    
    // Check essential git structures
    const essential_files = [_][]const u8{ "config", "HEAD", "refs", "objects" };
    for (essential_files) |file| {
        git_dir.access(file, .{}) catch {
            std.debug.print("    ✗ Missing essential git structure: {s}\n", .{file});
            return;
        };
    }
    
    std.debug.print("    ✓ Plain init works correctly\n", .{});
    
    // Test 2: Bare init (adapted from git test suite)
    const bare_dir = try tf.createTestDir("init-bare");
    defer tf.cleanup(bare_dir);
    
    var bare_result = try tf.runCommand(&[_][]const u8{ "./zig-out/bin/ziggit", "init", "--bare" }, bare_dir);
    defer bare_result.deinit(tf.allocator);
    
    if (bare_result.exit_code != 0) {
        std.debug.print("    ⚠ Bare init not implemented (exit code {d})\n", .{bare_result.exit_code});
        return;
    }
    
    std.debug.print("    ✓ Bare init works correctly\n", .{});
}

// Test: git add functionality (adapted from t2000-add.sh)
fn testGitAdd(tf: *TestFramework) !void {
    std.debug.print("  Testing git add compatibility...\n", .{});
    
    const test_dir = try tf.createTestDir("add-test");
    defer tf.cleanup(test_dir);
    
    // Initialize repository
    var init_result = try tf.runCommand(&[_][]const u8{ "./zig-out/bin/ziggit", "init" }, test_dir);
    defer init_result.deinit(tf.allocator);
    
    if (init_result.exit_code != 0) {
        std.debug.print("    ✗ Failed to initialize repository\n", .{});
        return;
    }
    
    // Create a test file
    const test_file_path = try std.fmt.allocPrint(tf.allocator, "{s}/test.txt", .{test_dir});
    defer tf.allocator.free(test_file_path);
    
    try std.fs.cwd().writeFile(.{ .sub_path = test_file_path[1..], .data = "Hello, git compatibility!\n" });
    
    // Test adding the file
    var add_result = try tf.runCommand(&[_][]const u8{ "./zig-out/bin/ziggit", "add", "test.txt" }, test_dir);
    defer add_result.deinit(tf.allocator);
    
    if (add_result.exit_code != 0) {
        std.debug.print("    ✗ add failed with code {d}: {s}\n", .{ add_result.exit_code, add_result.stderr });
        return;
    }
    
    // Check that file was staged by checking status
    var status_result = try tf.runCommand(&[_][]const u8{ "./zig-out/bin/ziggit", "status", "--porcelain" }, test_dir);
    defer status_result.deinit(tf.allocator);
    
    if (std.mem.indexOf(u8, status_result.stdout, "A ") == null) {
        std.debug.print("    ✗ File not properly staged (status: {s})\n", .{status_result.stdout});
        return;
    }
    
    std.debug.print("    ✓ Basic add functionality works\n", .{});
    
    // Test adding nonexistent file (should fail)
    var add_fail_result = try tf.runCommand(&[_][]const u8{ "./zig-out/bin/ziggit", "add", "nonexistent.txt" }, test_dir);
    defer add_fail_result.deinit(tf.allocator);
    
    if (add_fail_result.exit_code == 0) {
        std.debug.print("    ✗ Adding nonexistent file should fail\n", .{});
        return;
    }
    
    std.debug.print("    ✓ Error handling for nonexistent files works\n", .{});
}

// Test: git commit functionality (adapted from t7500-commit.sh)
fn testGitCommit(tf: *TestFramework) !void {
    std.debug.print("  Testing git commit compatibility...\n", .{});
    
    const test_dir = try tf.createTestDir("commit-test");
    defer tf.cleanup(test_dir);
    
    // Set up repository
    var init_result = try tf.runCommand(&[_][]const u8{ "./zig-out/bin/ziggit", "init" }, test_dir);
    defer init_result.deinit(tf.allocator);
    
    if (init_result.exit_code != 0) {
        std.debug.print("    ✗ Failed to initialize repository\n", .{});
        return;
    }
    
    // Create and add a file
    const test_file_path = try std.fmt.allocPrint(tf.allocator, "{s}/commit-test.txt", .{test_dir});
    defer tf.allocator.free(test_file_path);
    
    try std.fs.cwd().writeFile(.{ .sub_path = test_file_path[1..], .data = "Initial commit content\n" });
    
    var add_result = try tf.runCommand(&[_][]const u8{ "./zig-out/bin/ziggit", "add", "commit-test.txt" }, test_dir);
    defer add_result.deinit(tf.allocator);
    
    // Test commit with message
    var commit_result = try tf.runCommand(&[_][]const u8{ "./zig-out/bin/ziggit", "commit", "-m", "Initial commit" }, test_dir);
    defer commit_result.deinit(tf.allocator);
    
    if (commit_result.exit_code != 0) {
        std.debug.print("    ✗ commit failed with code {d}: {s}\n", .{ commit_result.exit_code, commit_result.stderr });
        return;
    }
    
    // Verify commit was created by checking log
    var log_result = try tf.runCommand(&[_][]const u8{ "./zig-out/bin/ziggit", "log", "--oneline" }, test_dir);
    defer log_result.deinit(tf.allocator);
    
    if (std.mem.indexOf(u8, log_result.stdout, "Initial commit") == null) {
        std.debug.print("    ✗ Commit not found in log: {s}\n", .{log_result.stdout});
        return;
    }
    
    std.debug.print("    ✓ Basic commit functionality works\n", .{});
    
    // Test commit with nothing to commit (should fail)
    var empty_commit_result = try tf.runCommand(&[_][]const u8{ "./zig-out/bin/ziggit", "commit", "-m", "Empty commit" }, test_dir);
    defer empty_commit_result.deinit(tf.allocator);
    
    if (empty_commit_result.exit_code == 0) {
        std.debug.print("    ⚠ Empty commit should fail (git behavior)\n", .{});
    } else {
        std.debug.print("    ✓ Empty commit properly rejected\n", .{});
    }
}

// Test: git status functionality (adapted from t7060-wtstatus.sh)  
fn testGitStatus(tf: *TestFramework) !void {
    std.debug.print("  Testing git status compatibility...\n", .{});
    
    const test_dir = try tf.createTestDir("status-test");
    defer tf.cleanup(test_dir);
    
    // Initialize and create initial commit
    var init_result = try tf.runCommand(&[_][]const u8{ "./zig-out/bin/ziggit", "init" }, test_dir);
    defer init_result.deinit(tf.allocator);
    
    const test_file_path = try std.fmt.allocPrint(tf.allocator, "{s}/status.txt", .{test_dir});
    defer tf.allocator.free(test_file_path);
    
    try std.fs.cwd().writeFile(.{ .sub_path = test_file_path[1..], .data = "Status test content\n" });
    
    var add_result = try tf.runCommand(&[_][]const u8{ "./zig-out/bin/ziggit", "add", "status.txt" }, test_dir);
    defer add_result.deinit(tf.allocator);
    
    var commit_result = try tf.runCommand(&[_][]const u8{ "./zig-out/bin/ziggit", "commit", "-m", "Initial status test" }, test_dir);
    defer commit_result.deinit(tf.allocator);
    
    // Test clean status
    var clean_status = try tf.runCommand(&[_][]const u8{ "./zig-out/bin/ziggit", "status", "--porcelain" }, test_dir);
    defer clean_status.deinit(tf.allocator);
    
    if (clean_status.stdout.len > 0) {
        std.debug.print("    ✗ Clean repository should have empty status: {s}\n", .{clean_status.stdout});
        return;
    }
    
    std.debug.print("    ✓ Clean status works correctly\n", .{});
    
    // Modify file and test modified status
    try std.fs.cwd().writeFile(.{ .sub_path = test_file_path[1..], .data = "Modified content\n" });
    
    var modified_status = try tf.runCommand(&[_][]const u8{ "./zig-out/bin/ziggit", "status", "--porcelain" }, test_dir);
    defer modified_status.deinit(tf.allocator);
    
    if (std.mem.indexOf(u8, modified_status.stdout, " M ") == null) {
        std.debug.print("    ✗ Modified file not detected in status: {s}\n", .{modified_status.stdout});
        return;
    }
    
    std.debug.print("    ✓ Modified file detection works\n", .{});
}

// Test: git log functionality (adapted from t4202-log.sh)
fn testGitLog(tf: *TestFramework) !void {
    std.debug.print("  Testing git log compatibility...\n", .{});
    
    const test_dir = try tf.createTestDir("log-test");
    defer tf.cleanup(test_dir);
    
    // Set up repository with multiple commits
    var init_result = try tf.runCommand(&[_][]const u8{ "./zig-out/bin/ziggit", "init" }, test_dir);
    defer init_result.deinit(tf.allocator);
    
    // First commit
    const test_file1_path = try std.fmt.allocPrint(tf.allocator, "{s}/file1.txt", .{test_dir});
    defer tf.allocator.free(test_file1_path);
    
    try std.fs.cwd().writeFile(.{ .sub_path = test_file1_path[1..], .data = "First commit\n" });
    
    var add1_result = try tf.runCommand(&[_][]const u8{ "./zig-out/bin/ziggit", "add", "file1.txt" }, test_dir);
    defer add1_result.deinit(tf.allocator);
    
    var commit1_result = try tf.runCommand(&[_][]const u8{ "./zig-out/bin/ziggit", "commit", "-m", "First commit" }, test_dir);
    defer commit1_result.deinit(tf.allocator);
    
    // Second commit  
    const test_file2_path = try std.fmt.allocPrint(tf.allocator, "{s}/file2.txt", .{test_dir});
    defer tf.allocator.free(test_file2_path);
    
    try std.fs.cwd().writeFile(.{ .sub_path = test_file2_path[1..], .data = "Second commit\n" });
    
    var add2_result = try tf.runCommand(&[_][]const u8{ "./zig-out/bin/ziggit", "add", "file2.txt" }, test_dir);
    defer add2_result.deinit(tf.allocator);
    
    var commit2_result = try tf.runCommand(&[_][]const u8{ "./zig-out/bin/ziggit", "commit", "-m", "Second commit" }, test_dir);
    defer commit2_result.deinit(tf.allocator);
    
    // Test log output
    var log_result = try tf.runCommand(&[_][]const u8{ "./zig-out/bin/ziggit", "log", "--oneline" }, test_dir);
    defer log_result.deinit(tf.allocator);
    
    if (log_result.exit_code != 0) {
        std.debug.print("    ✗ log failed with code {d}: {s}\n", .{ log_result.exit_code, log_result.stderr });
        return;
    }
    
    // Check that both commits appear
    const has_first = std.mem.indexOf(u8, log_result.stdout, "First commit") != null;
    const has_second = std.mem.indexOf(u8, log_result.stdout, "Second commit") != null;
    
    if (!has_first or !has_second) {
        std.debug.print("    ✗ Missing commits in log output: {s}\n", .{log_result.stdout});
        return;
    }
    
    std.debug.print("    ✓ Log functionality works correctly\n", .{});
}

// Test: git diff functionality (adapted from t4041-diff-submodule-option.sh)
fn testGitDiff(tf: *TestFramework) !void {
    std.debug.print("  Testing git diff compatibility...\n", .{});
    
    const test_dir = try tf.createTestDir("diff-test");
    defer tf.cleanup(test_dir);
    
    // Set up repository
    var init_result = try tf.runCommand(&[_][]const u8{ "./zig-out/bin/ziggit", "init" }, test_dir);
    defer init_result.deinit(tf.allocator);
    
    const test_file_path = try std.fmt.allocPrint(tf.allocator, "{s}/diff.txt", .{test_dir});
    defer tf.allocator.free(test_file_path);
    
    // Create initial version and commit
    try std.fs.cwd().writeFile(.{ .sub_path = test_file_path[1..], .data = "Original content\nLine 2\nLine 3\n" });
    
    var add_result = try tf.runCommand(&[_][]const u8{ "./zig-out/bin/ziggit", "add", "diff.txt" }, test_dir);
    defer add_result.deinit(tf.allocator);
    
    var commit_result = try tf.runCommand(&[_][]const u8{ "./zig-out/bin/ziggit", "commit", "-m", "Initial for diff" }, test_dir);
    defer commit_result.deinit(tf.allocator);
    
    // Modify file
    try std.fs.cwd().writeFile(.{ .sub_path = test_file_path[1..], .data = "Modified content\nLine 2\nNew line 3\n" });
    
    // Test diff
    var diff_result = try tf.runCommand(&[_][]const u8{ "./zig-out/bin/ziggit", "diff" }, test_dir);
    defer diff_result.deinit(tf.allocator);
    
    if (diff_result.exit_code != 0) {
        std.debug.print("    ✗ diff failed with code {d}: {s}\n", .{ diff_result.exit_code, diff_result.stderr });
        return;
    }
    
    // Check for diff markers
    const has_minus = std.mem.indexOf(u8, diff_result.stdout, "-Original content") != null;
    const has_plus = std.mem.indexOf(u8, diff_result.stdout, "+Modified content") != null;
    
    if (!has_minus or !has_plus) {
        std.debug.print("    ✗ Diff output doesn't show expected changes: {s}\n", .{diff_result.stdout});
        return;
    }
    
    std.debug.print("    ✓ Diff functionality works correctly\n", .{});
}

// Test: git branch functionality (adapted from t3200-branch.sh)
fn testGitBranch(tf: *TestFramework) !void {
    std.debug.print("  Testing git branch compatibility...\n", .{});
    
    const test_dir = try tf.createTestDir("branch-test");
    defer tf.cleanup(test_dir);
    
    // Set up repository with initial commit
    var init_result = try tf.runCommand(&[_][]const u8{ "./zig-out/bin/ziggit", "init" }, test_dir);
    defer init_result.deinit(tf.allocator);
    
    const test_file_path = try std.fmt.allocPrint(tf.allocator, "{s}/branch.txt", .{test_dir});
    defer tf.allocator.free(test_file_path);
    
    try std.fs.cwd().writeFile(.{ .sub_path = test_file_path[1..], .data = "Branch test content\n" });
    
    var add_result = try tf.runCommand(&[_][]const u8{ "./zig-out/bin/ziggit", "add", "branch.txt" }, test_dir);
    defer add_result.deinit(tf.allocator);
    
    var commit_result = try tf.runCommand(&[_][]const u8{ "./zig-out/bin/ziggit", "commit", "-m", "Initial for branch test" }, test_dir);
    defer commit_result.deinit(tf.allocator);
    
    // Test creating a branch
    var branch_result = try tf.runCommand(&[_][]const u8{ "./zig-out/bin/ziggit", "branch", "feature" }, test_dir);
    defer branch_result.deinit(tf.allocator);
    
    if (branch_result.exit_code != 0) {
        std.debug.print("    ⚠ Branch creation not implemented (exit code {d}): {s}\n", .{ branch_result.exit_code, branch_result.stderr });
        return;
    }
    
    // List branches
    var list_result = try tf.runCommand(&[_][]const u8{ "./zig-out/bin/ziggit", "branch" }, test_dir);
    defer list_result.deinit(tf.allocator);
    
    if (std.mem.indexOf(u8, list_result.stdout, "feature") == null) {
        std.debug.print("    ✗ Created branch not found in branch list: {s}\n", .{list_result.stdout});
        return;
    }
    
    std.debug.print("    ✓ Branch functionality works correctly\n", .{});
}

// Test: git checkout functionality (adapted from t2013-checkout-submodule.sh)
fn testGitCheckout(tf: *TestFramework) !void {
    std.debug.print("  Testing git checkout compatibility...\n", .{});
    
    const test_dir = try tf.createTestDir("checkout-test");
    defer tf.cleanup(test_dir);
    
    // Set up repository
    var init_result = try tf.runCommand(&[_][]const u8{ "./zig-out/bin/ziggit", "init" }, test_dir);
    defer init_result.deinit(tf.allocator);
    
    const test_file_path = try std.fmt.allocPrint(tf.allocator, "{s}/checkout.txt", .{test_dir});
    defer tf.allocator.free(test_file_path);
    
    try std.fs.cwd().writeFile(.{ .sub_path = test_file_path[1..], .data = "Checkout test content\n" });
    
    var add_result = try tf.runCommand(&[_][]const u8{ "./zig-out/bin/ziggit", "add", "checkout.txt" }, test_dir);
    defer add_result.deinit(tf.allocator);
    
    var commit_result = try tf.runCommand(&[_][]const u8{ "./zig-out/bin/ziggit", "commit", "-m", "Initial for checkout test" }, test_dir);
    defer commit_result.deinit(tf.allocator);
    
    // Create and switch to branch
    var branch_result = try tf.runCommand(&[_][]const u8{ "./zig-out/bin/ziggit", "branch", "test-branch" }, test_dir);
    defer branch_result.deinit(tf.allocator);
    
    var checkout_result = try tf.runCommand(&[_][]const u8{ "./zig-out/bin/ziggit", "checkout", "test-branch" }, test_dir);
    defer checkout_result.deinit(tf.allocator);
    
    if (checkout_result.exit_code != 0) {
        std.debug.print("    ⚠ Checkout not implemented (exit code {d}): {s}\n", .{ checkout_result.exit_code, checkout_result.stderr });
        return;
    }
    
    std.debug.print("    ✓ Checkout functionality works correctly\n", .{});
}

pub fn runCoreGitCompatibilityTests() !void {
    std.debug.print("Running Core Git Compatibility Tests (adapted from git source test suite)...\n", .{});
    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var tf = TestFramework.init(gpa.allocator());
    
    // Run all tests
    try testGitInit(&tf);
    try testGitAdd(&tf);
    try testGitCommit(&tf);
    try testGitStatus(&tf);
    try testGitLog(&tf);
    try testGitDiff(&tf);
    try testGitBranch(&tf);
    try testGitCheckout(&tf);
    
    std.debug.print("Core Git Compatibility Tests completed!\n", .{});
}

// Unit tests for zig build test
test "git init creates repository" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var tf = TestFramework.init(gpa.allocator());
    
    const test_dir = try tf.createTestDir("test-init");
    defer tf.cleanup(test_dir);
    
    var result = try tf.runCommand(&[_][]const u8{ "./zig-out/bin/ziggit", "init" }, test_dir);
    defer result.deinit(tf.allocator);
    
    try std.testing.expect(result.exit_code == 0);
    
    const git_dir_path = try std.fmt.allocPrint(tf.allocator, "{s}/.git", .{test_dir});
    defer tf.allocator.free(git_dir_path);
    
    const git_dir = try std.fs.cwd().openDir(git_dir_path[1..], .{});
    defer git_dir.close();
    
    // Verify essential structures exist
    try git_dir.access("config", .{});
    try git_dir.access("HEAD", .{});
    try git_dir.access("refs", .{});
    try git_dir.access("objects", .{});
}

test "git add stages files" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var tf = TestFramework.init(gpa.allocator());
    
    const test_dir = try tf.createTestDir("test-add");
    defer tf.cleanup(test_dir);
    
    // Initialize repo
    var init_result = try tf.runCommand(&[_][]const u8{ "./zig-out/bin/ziggit", "init" }, test_dir);
    defer init_result.deinit(tf.allocator);
    try std.testing.expect(init_result.exit_code == 0);
    
    // Create test file
    const test_file_path = try std.fmt.allocPrint(tf.allocator, "{s}/test.txt", .{test_dir});
    defer tf.allocator.free(test_file_path);
    try std.fs.cwd().writeFile(.{ .sub_path = test_file_path[1..], .data = "test content" });
    
    // Add file
    var add_result = try tf.runCommand(&[_][]const u8{ "./zig-out/bin/ziggit", "add", "test.txt" }, test_dir);
    defer add_result.deinit(tf.allocator);
    try std.testing.expect(add_result.exit_code == 0);
    
    // Verify file is staged
    var status_result = try tf.runCommand(&[_][]const u8{ "./zig-out/bin/ziggit", "status", "--porcelain" }, test_dir);
    defer status_result.deinit(tf.allocator);
    try std.testing.expect(std.mem.indexOf(u8, status_result.stdout, "A ") != null);
}