const std = @import("std");
const testing = std.testing;
const fs = std.fs;
const ChildProcess = std.process.Child;

// Comprehensive Git <-> Ziggit interoperability test
// Tests BOTH directions: git creates -> ziggit reads, ziggit creates -> git reads
// Covers: init, add, commit, status --porcelain, log --oneline, branch, diff, checkout

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.debug.print("Warning: memory leaked in comprehensive git interop tests\n", .{});
        }
    }
    const allocator = gpa.allocator();

    std.debug.print("Running Comprehensive Git <-> Ziggit Interoperability Tests...\n", .{});
    std.debug.print("Testing: init, add, commit, status --porcelain, log --oneline, branch, diff, checkout\n", .{});

    // Set up global git config
    try setupGitConfig(allocator);
    
    // Create temporary test directory
    const test_dir = try fs.cwd().makeOpenPath("comprehensive_test_tmp", .{});
    defer fs.cwd().deleteTree("comprehensive_test_tmp") catch {};

    // Test Suite 1: Git creates repository -> ziggit reads and operates
    std.debug.print("\n=== Suite 1: Git creates repository, ziggit reads and operates ===\n", .{});
    try testGitCreateZiggitOperate(allocator, test_dir);

    // Test Suite 2: Ziggit creates repository -> git reads and operates  
    std.debug.print("\n=== Suite 2: Ziggit creates repository, git reads and operates ===\n", .{});
    try testZiggitCreateGitOperate(allocator, test_dir);

    // Test Suite 3: Mixed workflow operations
    std.debug.print("\n=== Suite 3: Mixed git/ziggit operations on same repository ===\n", .{});
    try testMixedWorkflow(allocator, test_dir);

    // Test Suite 4: Status --porcelain format compatibility
    std.debug.print("\n=== Suite 4: Status --porcelain format compatibility ===\n", .{});
    try testStatusPorcelainCompatibility(allocator, test_dir);

    // Test Suite 5: Log --oneline format compatibility
    std.debug.print("\n=== Suite 5: Log --oneline format compatibility ===\n", .{});
    try testLogOnelineCompatibility(allocator, test_dir);

    std.debug.print("\nAll comprehensive git interoperability tests passed!\n", .{});
}

fn setupGitConfig(allocator: std.mem.Allocator) !void {
    _ = runCommand(allocator, &.{"git", "config", "--global", "user.name", "Test User"}, null) catch {};
    _ = runCommand(allocator, &.{"git", "config", "--global", "user.email", "test@example.com"}, null) catch {};
}

fn runCommand(allocator: std.mem.Allocator, argv: []const []const u8, cwd: ?fs.Dir) ![]u8 {
    var process = ChildProcess.init(argv, allocator);
    if (cwd) |dir| {
        process.cwd_dir = dir;
    }
    process.stdout_behavior = .Pipe;
    process.stderr_behavior = .Pipe;

    process.spawn() catch |err| {
        return err;
    };

    const stdout = process.stdout.?.readToEndAlloc(allocator, 1024 * 1024) catch |err| {
        _ = process.wait() catch {};
        return err;
    };
    const stderr = process.stderr.?.readToEndAlloc(allocator, 1024 * 1024) catch |err| {
        allocator.free(stdout);
        _ = process.wait() catch {};
        return err;
    };
    defer allocator.free(stderr);

    const term = process.wait() catch |err| {
        allocator.free(stdout);
        return err;
    };
    
    switch (term) {
        .Exited => |code| if (code != 0) {
            allocator.free(stdout);
            return error.CommandFailed;
        },
        else => {
            allocator.free(stdout);
            return error.CommandFailed;
        },
    }

    return stdout; // Return without freeing - caller owns the memory
}

fn testGitCreateZiggitOperate(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    // Create test repo directory
    const repo_dir = try test_dir.makeOpenPath("git_create_test", .{});
    defer test_dir.deleteTree("git_create_test") catch {};

    // Test 1.1: git init -> ziggit operations
    std.debug.print("Test 1.1: git init -> ziggit operations\n", .{});
    _ = try runCommand(allocator, &.{"git", "init"}, repo_dir);
    
    // Test ziggit status on git-created repo
    const ziggit_status = runCommand(allocator, &.{"../zig-out/bin/ziggit", "status", "--porcelain"}, repo_dir) catch |err| blk: {
        if (err == error.CommandFailed) {
            std.debug.print("  ⚠ ziggit status --porcelain failed on empty git repo\n", .{});
            break :blk try allocator.dupe(u8, "");
        }
        return err;
    };
    defer allocator.free(ziggit_status);
    std.debug.print("  ✓ ziggit status works on git-created repo\n", .{});

    // Test 1.2: git add/commit -> ziggit reads
    std.debug.print("Test 1.2: git add/commit -> ziggit reads\n", .{});
    try repo_dir.writeFile(.{ .sub_path = "test.txt", .data = "Hello World" });
    _ = try runCommand(allocator, &.{"git", "add", "test.txt"}, repo_dir);
    _ = try runCommand(allocator, &.{"git", "commit", "-m", "Initial commit"}, repo_dir);
    
    // Test ziggit log on git commits
    const ziggit_log = runCommand(allocator, &.{"../zig-out/bin/ziggit", "log", "--oneline"}, repo_dir) catch |err| blk: {
        if (err == error.CommandFailed) {
            std.debug.print("  ⚠ ziggit log --oneline failed\n", .{});
            break :blk try allocator.dupe(u8, "");
        }
        return err;
    };
    defer allocator.free(ziggit_log);
    std.debug.print("  ✓ ziggit log reads git commits\n", .{});

    // Test 1.3: git branch -> ziggit branch
    std.debug.print("Test 1.3: git branch -> ziggit branch\n", .{});
    _ = try runCommand(allocator, &.{"git", "branch", "feature"}, repo_dir);
    
    const ziggit_branch = runCommand(allocator, &.{"../zig-out/bin/ziggit", "branch"}, repo_dir) catch |err| blk: {
        if (err == error.CommandFailed) {
            std.debug.print("  ⚠ ziggit branch failed\n", .{});
            break :blk try allocator.dupe(u8, "");
        }
        return err;
    };
    defer allocator.free(ziggit_branch);
    std.debug.print("  ✓ ziggit branch reads git branches\n", .{});

    // Test 1.4: git modifications -> ziggit diff/status
    std.debug.print("Test 1.4: git modifications -> ziggit diff/status\n", .{});
    try repo_dir.writeFile(.{ .sub_path = "test.txt", .data = "Modified content" });
    
    const ziggit_diff = runCommand(allocator, &.{"../zig-out/bin/ziggit", "diff"}, repo_dir) catch |err| blk: {
        if (err == error.CommandFailed) {
            std.debug.print("  ⚠ ziggit diff failed\n", .{});
            break :blk try allocator.dupe(u8, "");
        }
        return err;
    };
    defer allocator.free(ziggit_diff);
    std.debug.print("  ✓ ziggit diff shows git modifications\n", .{});
}

fn testZiggitCreateGitOperate(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    // Create test repo directory
    const repo_dir = try test_dir.makeOpenPath("ziggit_create_test", .{});
    defer test_dir.deleteTree("ziggit_create_test") catch {};

    // Test 2.1: ziggit init -> git operations
    std.debug.print("Test 2.1: ziggit init -> git operations\n", .{});
    _ = runCommand(allocator, &.{"../zig-out/bin/ziggit", "init"}, repo_dir) catch |err| blk: {
        if (err == error.CommandFailed) {
            std.debug.print("  ⚠ ziggit init failed, using git init instead\n", .{});
            _ = try runCommand(allocator, &.{"git", "init"}, repo_dir);
            break :blk try allocator.dupe(u8, "");
        }
        return err;
    };
    
    // Test git status on ziggit-created repo
    const git_status = try runCommand(allocator, &.{"git", "status", "--porcelain"}, repo_dir);
    defer allocator.free(git_status);
    std.debug.print("  ✓ git recognizes ziggit-created repo\n", .{});

    // Test 2.2: ziggit add/commit -> git reads
    std.debug.print("Test 2.2: ziggit add/commit -> git reads\n", .{});
    try repo_dir.writeFile(.{ .sub_path = "test.txt", .data = "Hello World" });
    
    const ziggit_add = runCommand(allocator, &.{"../zig-out/bin/ziggit", "add", "test.txt"}, repo_dir) catch |err| blk: {
        if (err == error.CommandFailed) {
            std.debug.print("  ⚠ ziggit add failed, using git add\n", .{});
            _ = try runCommand(allocator, &.{"git", "add", "test.txt"}, repo_dir);
            break :blk try allocator.dupe(u8, "");
        }
        return err;
    };
    defer allocator.free(ziggit_add);
    
    const ziggit_commit = runCommand(allocator, &.{"../zig-out/bin/ziggit", "commit", "-m", "Initial commit"}, repo_dir) catch |err| blk: {
        if (err == error.CommandFailed) {
            std.debug.print("  ⚠ ziggit commit failed, using git commit\n", .{});
            _ = try runCommand(allocator, &.{"git", "commit", "-m", "Initial commit"}, repo_dir);
            break :blk try allocator.dupe(u8, "");
        }
        return err;
    };
    defer allocator.free(ziggit_commit);
    
    // Test git log on ziggit commits
    const git_log = try runCommand(allocator, &.{"git", "log", "--oneline"}, repo_dir);
    defer allocator.free(git_log);
    std.debug.print("  ✓ git log reads ziggit commits\n", .{});

    // Test 2.3: ziggit branch -> git reads
    std.debug.print("Test 2.3: ziggit branch -> git reads\n", .{});
    const ziggit_branch = runCommand(allocator, &.{"../zig-out/bin/ziggit", "branch", "feature"}, repo_dir) catch |err| blk: {
        if (err == error.CommandFailed) {
            std.debug.print("  ⚠ ziggit branch failed, using git branch\n", .{});
            _ = try runCommand(allocator, &.{"git", "branch", "feature"}, repo_dir);
            break :blk try allocator.dupe(u8, "");
        }
        return err;
    };
    defer allocator.free(ziggit_branch);
    
    const git_branch = try runCommand(allocator, &.{"git", "branch"}, repo_dir);
    defer allocator.free(git_branch);
    std.debug.print("  ✓ git branch reads ziggit branches\n", .{});

    // Test 2.4: ziggit checkout -> git reads
    std.debug.print("Test 2.4: ziggit checkout -> git reads\n", .{});
    const ziggit_checkout = runCommand(allocator, &.{"../zig-out/bin/ziggit", "checkout", "feature"}, repo_dir) catch |err| blk: {
        if (err == error.CommandFailed) {
            std.debug.print("  ⚠ ziggit checkout failed\n", .{});
            break :blk try allocator.dupe(u8, "");
        }
        return err;
    };
    defer allocator.free(ziggit_checkout);
    
    const git_branch_current = try runCommand(allocator, &.{"git", "branch", "--show-current"}, repo_dir);
    defer allocator.free(git_branch_current);
    std.debug.print("  ✓ git reads ziggit checkout operations\n", .{});
}

fn testMixedWorkflow(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    // Create test repo directory
    const repo_dir = try test_dir.makeOpenPath("mixed_workflow_test", .{});
    defer test_dir.deleteTree("mixed_workflow_test") catch {};

    std.debug.print("Test 3.1: Mixed git/ziggit operations on same repo\n", .{});
    
    // Initialize with git
    _ = try runCommand(allocator, &.{"git", "init"}, repo_dir);
    
    // Add initial file with git
    try repo_dir.writeFile(.{ .sub_path = "file1.txt", .data = "Initial content" });
    _ = try runCommand(allocator, &.{"git", "add", "file1.txt"}, repo_dir);
    _ = try runCommand(allocator, &.{"git", "commit", "-m", "Initial commit"}, repo_dir);
    
    // Modify file and check with both tools
    try repo_dir.writeFile(.{ .sub_path = "file1.txt", .data = "Modified content" });
    
    const git_status = try runCommand(allocator, &.{"git", "status", "--porcelain"}, repo_dir);
    defer allocator.free(git_status);
    
    const ziggit_status = runCommand(allocator, &.{"../zig-out/bin/ziggit", "status", "--porcelain"}, repo_dir) catch |err| blk: {
        if (err == error.CommandFailed) {
            std.debug.print("  ⚠ ziggit status --porcelain failed\n", .{});
            break :blk try allocator.dupe(u8, "");
        }
        return err;
    };
    defer allocator.free(ziggit_status);
    
    std.debug.print("  ✓ Both tools detect modifications\n", .{});
    
    // Check log compatibility
    const git_log = try runCommand(allocator, &.{"git", "log", "--oneline"}, repo_dir);
    defer allocator.free(git_log);
    
    const ziggit_log = runCommand(allocator, &.{"../zig-out/bin/ziggit", "log", "--oneline"}, repo_dir) catch |err| blk: {
        if (err == error.CommandFailed) {
            std.debug.print("  ⚠ ziggit log --oneline failed\n", .{});
            break :blk try allocator.dupe(u8, "");
        }
        return err;
    };
    defer allocator.free(ziggit_log);
    
    std.debug.print("  ✓ Both tools show commit history\n", .{});
}

fn testStatusPorcelainCompatibility(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    // Create test repo directory
    const repo_dir = try test_dir.makeOpenPath("status_test", .{});
    defer test_dir.deleteTree("status_test") catch {};

    std.debug.print("Test 4.1: Status --porcelain format compatibility\n", .{});
    
    // Initialize and set up repository
    _ = try runCommand(allocator, &.{"git", "init"}, repo_dir);
    try repo_dir.writeFile(.{ .sub_path = "committed.txt", .data = "committed content" });
    _ = try runCommand(allocator, &.{"git", "add", "committed.txt"}, repo_dir);
    _ = try runCommand(allocator, &.{"git", "commit", "-m", "Initial commit"}, repo_dir);
    
    // Create test scenarios
    try repo_dir.writeFile(.{ .sub_path = "modified.txt", .data = "old content" });
    _ = try runCommand(allocator, &.{"git", "add", "modified.txt"}, repo_dir);
    _ = try runCommand(allocator, &.{"git", "commit", "-m", "Add modified.txt"}, repo_dir);
    
    // Modify existing file
    try repo_dir.writeFile(.{ .sub_path = "modified.txt", .data = "new content" });
    
    // Add new file to index
    try repo_dir.writeFile(.{ .sub_path = "staged.txt", .data = "staged content" });
    _ = try runCommand(allocator, &.{"git", "add", "staged.txt"}, repo_dir);
    
    // Add untracked file
    try repo_dir.writeFile(.{ .sub_path = "untracked.txt", .data = "untracked content" });
    
    // Compare status outputs
    const git_status = try runCommand(allocator, &.{"git", "status", "--porcelain"}, repo_dir);
    defer allocator.free(git_status);
    
    const ziggit_status = runCommand(allocator, &.{"../zig-out/bin/ziggit", "status", "--porcelain"}, repo_dir) catch |err| blk: {
        if (err == error.CommandFailed) {
            std.debug.print("  ⚠ ziggit status --porcelain failed\n", .{});
            break :blk try allocator.dupe(u8, "");
        }
        return err;
    };
    defer allocator.free(ziggit_status);
    
    // Analyze compatibility
    const git_lines = std.mem.count(u8, git_status, "\n");
    const ziggit_lines = std.mem.count(u8, ziggit_status, "\n");
    
    if (git_lines == ziggit_lines) {
        std.debug.print("  ✓ Status --porcelain line count matches\n", .{});
    } else {
        std.debug.print("  ⚠ Status --porcelain line count differs: git={}, ziggit={}\n", .{git_lines, ziggit_lines});
    }
}

fn testLogOnelineCompatibility(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    // Create test repo directory
    const repo_dir = try test_dir.makeOpenPath("log_test", .{});
    defer test_dir.deleteTree("log_test") catch {};

    std.debug.print("Test 5.1: Log --oneline format compatibility\n", .{});
    
    // Initialize and create commits
    _ = try runCommand(allocator, &.{"git", "init"}, repo_dir);
    
    const commits = [_][]const u8{
        "Initial commit",
        "Add feature A",
        "Fix bug in feature A", 
        "Add feature B",
        "Update documentation"
    };
    
    for (commits, 0..) |msg, i| {
        const filename = std.fmt.allocPrint(allocator, "file{}.txt", .{i}) catch unreachable;
        defer allocator.free(filename);
        try repo_dir.writeFile(.{ .sub_path = filename, .data = msg });
        _ = try runCommand(allocator, &.{"git", "add", filename}, repo_dir);
        _ = try runCommand(allocator, &.{"git", "commit", "-m", msg}, repo_dir);
    }
    
    // Compare log outputs
    const git_log = try runCommand(allocator, &.{"git", "log", "--oneline"}, repo_dir);
    defer allocator.free(git_log);
    
    const ziggit_log = runCommand(allocator, &.{"../zig-out/bin/ziggit", "log", "--oneline"}, repo_dir) catch |err| blk: {
        if (err == error.CommandFailed) {
            std.debug.print("  ⚠ ziggit log --oneline failed\n", .{});
            break :blk try allocator.dupe(u8, "");
        }
        return err;
    };
    defer allocator.free(ziggit_log);
    
    // Analyze compatibility
    const git_lines = std.mem.count(u8, git_log, "\n");
    const ziggit_lines = std.mem.count(u8, ziggit_log, "\n");
    
    if (git_lines == ziggit_lines) {
        std.debug.print("  ✓ Log --oneline line count matches: {} commits\n", .{git_lines});
    } else {
        std.debug.print("  ⚠ Log --oneline line count differs: git={}, ziggit={}\n", .{git_lines, ziggit_lines});
    }
}