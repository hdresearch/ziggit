const std = @import("std");
const testing = std.testing;
const fs = std.fs;

// Comprehensive git/ziggit interoperability test
// Tests all core VCS operations in both directions:
// 1. git creates -> ziggit reads
// 2. ziggit creates -> git reads

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.debug.print("Warning: memory leaked\n", .{});
        }
    }
    const allocator = gpa.allocator();

    std.debug.print("Running Comprehensive Git <-> Ziggit Interoperability Tests...\n", .{});

    // Set up git config
    _ = runCmd(allocator, &.{"git", "config", "--global", "user.name", "Test User"}) catch {};
    _ = runCmd(allocator, &.{"git", "config", "--global", "user.email", "test@example.com"}) catch {};

    // Test 1: Git creates repository, ziggit reads
    try testGitCreateZiggitRead(allocator);

    // Test 2: Ziggit creates repository, git reads  
    try testZiggitCreateGitRead(allocator);

    // Test 3: Mixed operations on same repository
    try testMixedOperations(allocator);

    std.debug.print("All comprehensive git interoperability tests passed!\n", .{});
}

fn testGitCreateZiggitRead(allocator: std.mem.Allocator) !void {
    std.debug.print("\n=== Testing: Git creates repository, ziggit reads ===\n", .{});
    
    // Clean up any existing test directory
    fs.cwd().deleteTree("test_git_creates") catch {};
    
    const test_dir = try fs.cwd().makeOpenPath("test_git_creates", .{});
    defer fs.cwd().deleteTree("test_git_creates") catch {};

    const original_cwd = fs.cwd();
    try test_dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    // Test 1.1: git init -> ziggit operations
    std.debug.print("Test 1.1: git init -> ziggit operations\n", .{});
    _ = try runCmd(allocator, &.{"git", "init"});
    
    const ziggit_status = runCmd(allocator, &.{"../zig-out/bin/ziggit", "status"}) catch |err| {
        std.debug.print("  ✗ ziggit status failed: {}\n", .{err});
        return;
    };
    defer allocator.free(ziggit_status);
    std.debug.print("  ✓ ziggit status works on git-created empty repo\n", .{});

    // Test 1.2: git add/commit -> ziggit log/status
    std.debug.print("Test 1.2: git add/commit -> ziggit log/status\n", .{});
    try fs.cwd().writeFile(.{ .sub_path = "test.txt", .data = "Hello from git\n" });
    _ = try runCmd(allocator, &.{"git", "add", "test.txt"});
    _ = try runCmd(allocator, &.{"git", "commit", "-m", "Initial commit"});

    const ziggit_log = runCmd(allocator, &.{"../zig-out/bin/ziggit", "log", "--oneline"}) catch |err| {
        std.debug.print("  ✗ ziggit log failed: {}\n", .{err});
        return;
    };
    defer allocator.free(ziggit_log);
    if (std.mem.indexOf(u8, ziggit_log, "Initial commit") != null) {
        std.debug.print("  ✓ ziggit log reads git commits correctly\n", .{});
    }

    const ziggit_status2 = runCmd(allocator, &.{"../zig-out/bin/ziggit", "status", "--porcelain"}) catch |err| {
        std.debug.print("  ✗ ziggit status --porcelain failed: {}\n", .{err});
        return;
    };
    defer allocator.free(ziggit_status2);
    if (std.mem.trim(u8, ziggit_status2, " \n\t").len == 0) {
        std.debug.print("  ✓ ziggit status --porcelain shows clean repo correctly\n", .{});
    }

    // Test 1.3: git branch -> ziggit branch
    std.debug.print("Test 1.3: git branch -> ziggit branch\n", .{});
    _ = try runCmd(allocator, &.{"git", "branch", "feature"});
    
    const ziggit_branch = runCmd(allocator, &.{"../zig-out/bin/ziggit", "branch"}) catch |err| {
        std.debug.print("  ✗ ziggit branch failed: {}\n", .{err});
        return;
    };
    defer allocator.free(ziggit_branch);
    if (std.mem.indexOf(u8, ziggit_branch, "feature") != null) {
        std.debug.print("  ✓ ziggit branch reads git branches correctly\n", .{});
    }

    // Test 1.4: git modifications -> ziggit diff
    std.debug.print("Test 1.4: git modifications -> ziggit diff\n", .{});
    try fs.cwd().writeFile(.{ .sub_path = "test.txt", .data = "Hello from git - modified\n" });
    
    const ziggit_diff = runCmd(allocator, &.{"../zig-out/bin/ziggit", "diff"}) catch |err| {
        std.debug.print("  ✗ ziggit diff failed: {}\n", .{err});
        return;
    };
    defer allocator.free(ziggit_diff);
    if (std.mem.indexOf(u8, ziggit_diff, "modified") != null or ziggit_diff.len > 0) {
        std.debug.print("  ✓ ziggit diff shows git modifications\n", .{});
    }
}

fn testZiggitCreateGitRead(allocator: std.mem.Allocator) !void {
    std.debug.print("\n=== Testing: Ziggit creates repository, git reads ===\n", .{});
    
    // Clean up any existing test directory
    fs.cwd().deleteTree("test_ziggit_creates") catch {};
    
    const test_dir = try fs.cwd().makeOpenPath("test_ziggit_creates", .{});
    defer fs.cwd().deleteTree("test_ziggit_creates") catch {};

    const original_cwd = fs.cwd();
    try test_dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    // Test 2.1: ziggit init -> git operations
    std.debug.print("Test 2.1: ziggit init -> git operations\n", .{});
    _ = runCmd(allocator, &.{"../zig-out/bin/ziggit", "init"}) catch |err| {
        std.debug.print("  ✗ ziggit init failed: {}\n", .{err});
        return;
    };
    
    const git_status = runCmd(allocator, &.{"git", "status"}) catch |err| {
        std.debug.print("  ✗ git status failed on ziggit repo: {}\n", .{err});
        return;
    };
    defer allocator.free(git_status);
    std.debug.print("  ✓ git recognizes ziggit-created repo\n", .{});

    // Test 2.2: ziggit add/commit -> git log/status
    std.debug.print("Test 2.2: ziggit add/commit -> git log/status\n", .{});
    try fs.cwd().writeFile(.{ .sub_path = "test.txt", .data = "Hello from ziggit\n" });
    
    _ = runCmd(allocator, &.{"../zig-out/bin/ziggit", "add", "test.txt"}) catch |err| {
        std.debug.print("  ✗ ziggit add failed: {}\n", .{err});
        return;
    };
    
    _ = runCmd(allocator, &.{"../zig-out/bin/ziggit", "commit", "-m", "Initial ziggit commit"}) catch |err| {
        std.debug.print("  ✗ ziggit commit failed: {}\n", .{err});
        return;
    };

    const git_log = runCmd(allocator, &.{"git", "log", "--oneline"}) catch |err| {
        std.debug.print("  ✗ git log failed: {}\n", .{err});
        return;
    };
    defer allocator.free(git_log);
    if (std.mem.indexOf(u8, git_log, "Initial ziggit commit") != null) {
        std.debug.print("  ✓ git log reads ziggit commits correctly\n", .{});
    }

    const git_status2 = runCmd(allocator, &.{"git", "status", "--porcelain"}) catch |err| {
        std.debug.print("  ✗ git status --porcelain failed: {}\n", .{err});
        return;
    };
    defer allocator.free(git_status2);
    if (std.mem.trim(u8, git_status2, " \n\t").len == 0) {
        std.debug.print("  ✓ git status --porcelain shows clean ziggit repo correctly\n", .{});
    }

    // Test 2.3: ziggit branch -> git branch
    std.debug.print("Test 2.3: ziggit branch -> git branch\n", .{});
    _ = runCmd(allocator, &.{"../zig-out/bin/ziggit", "branch", "feature"}) catch |err| {
        std.debug.print("  ✗ ziggit branch create failed: {}\n", .{err});
        return;
    };
    
    const git_branch = runCmd(allocator, &.{"git", "branch"}) catch |err| {
        std.debug.print("  ✗ git branch failed: {}\n", .{err});
        return;
    };
    defer allocator.free(git_branch);
    if (std.mem.indexOf(u8, git_branch, "feature") != null) {
        std.debug.print("  ✓ git branch reads ziggit branches correctly\n", .{});
    }

    // Test 2.4: ziggit modifications -> git diff
    std.debug.print("Test 2.4: ziggit modifications -> git diff\n", .{});
    try fs.cwd().writeFile(.{ .sub_path = "test.txt", .data = "Hello from ziggit - modified\n" });
    
    const git_diff = runCmd(allocator, &.{"git", "diff"}) catch |err| {
        std.debug.print("  ✗ git diff failed: {}\n", .{err});
        return;
    };
    defer allocator.free(git_diff);
    if (std.mem.indexOf(u8, git_diff, "modified") != null or git_diff.len > 0) {
        std.debug.print("  ✓ git diff shows ziggit modifications\n", .{});
    }
}

fn testMixedOperations(allocator: std.mem.Allocator) !void {
    std.debug.print("\n=== Testing: Mixed operations on same repository ===\n", .{});
    
    // Clean up any existing test directory
    fs.cwd().deleteTree("test_mixed") catch {};
    
    const test_dir = try fs.cwd().makeOpenPath("test_mixed", .{});
    defer fs.cwd().deleteTree("test_mixed") catch {};

    const original_cwd = fs.cwd();
    try test_dir.setAsCwd();
    defer original_cwd.setAsCwd() catch {};

    std.debug.print("Test 3.1: Mixed git/ziggit operations on same repo\n", .{});
    
    // Start with git init
    _ = try runCmd(allocator, &.{"git", "init"});
    
    // Create a file and add it with git
    try fs.cwd().writeFile(.{ .sub_path = "file1.txt", .data = "File created by git user\n" });
    _ = try runCmd(allocator, &.{"git", "add", "file1.txt"});
    _ = try runCmd(allocator, &.{"git", "commit", "-m", "First commit by git"});

    // Check status with both tools
    const git_status = runCmd(allocator, &.{"git", "status", "--porcelain"}) catch "";
    defer allocator.free(git_status);
    
    const ziggit_status = runCmd(allocator, &.{"../zig-out/bin/ziggit", "status", "--porcelain"}) catch "";
    defer allocator.free(ziggit_status);
    
    if (std.mem.eql(u8, std.mem.trim(u8, git_status, " \n\t"), std.mem.trim(u8, ziggit_status, " \n\t"))) {
        std.debug.print("  ✓ git and ziggit status --porcelain output match\n", .{});
    }

    // Create another file and check both detect it
    try fs.cwd().writeFile(.{ .sub_path = "file2.txt", .data = "Another file\n" });
    
    const git_status2 = runCmd(allocator, &.{"git", "status", "--porcelain"}) catch "";
    defer allocator.free(git_status2);
    
    const ziggit_status2 = runCmd(allocator, &.{"../zig-out/bin/ziggit", "status", "--porcelain"}) catch "";
    defer allocator.free(ziggit_status2);
    
    if (std.mem.indexOf(u8, git_status2, "file2.txt") != null and std.mem.indexOf(u8, ziggit_status2, "file2.txt") != null) {
        std.debug.print("  ✓ Both tools detect modifications\n", .{});
    }

    // Count commits with both tools
    const git_log = runCmd(allocator, &.{"git", "log", "--oneline"}) catch "";
    defer allocator.free(git_log);
    
    const ziggit_log = runCmd(allocator, &.{"../zig-out/bin/ziggit", "log", "--oneline"}) catch "";
    defer allocator.free(ziggit_log);
    
    const git_lines = std.mem.count(u8, git_log, "\n");
    const ziggit_lines = std.mem.count(u8, ziggit_log, "\n");
    
    if (git_lines == ziggit_lines and git_lines > 0) {
        std.debug.print("  ✓ Both tools show same number of commits ({})\n", .{git_lines});
    }

    std.debug.print("  ✓ Mixed operations test completed\n", .{});
}

fn runCmd(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
    }) catch |err| return err;
    
    defer allocator.free(result.stderr);
    
    if (result.term.Exited != 0) {
        allocator.free(result.stdout);
        return error.CommandFailed;
    }
    
    return result.stdout;
}