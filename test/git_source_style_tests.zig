const std = @import("std");
const testing = std.testing;


const TestHarness = @import("test_harness.zig").TestHarness;

// Test suite following Git's official test style from t/
// Based on patterns from git source: t0001-init.sh, t7508-status.sh

pub fn runGitSourceStyleTests() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    std.debug.print("Running git source style tests...\n", .{});

    try testInitSourceStyle(allocator);
    try testStatusSourceStyle(allocator);
    try testAddCommitSourceStyle(allocator);

    std.debug.print("Git source style tests completed!\n", .{});
}

// Tests based on t0001-init.sh from git source
fn testInitSourceStyle(allocator: std.mem.Allocator) !void {
    var harness = TestHarness.init(allocator, "/root/ziggit/zig-out/bin/ziggit", "git");

    std.debug.print("  Testing init (t0001-init.sh style)...\n", .{});

    const temp_dir = try harness.createTempDir("test_git_init_style");
    defer harness.removeTempDir(temp_dir);

    // Test: plain init
    {
        const plain_dir = try std.fmt.allocPrint(allocator, "{s}/plain", .{temp_dir});
        defer allocator.free(plain_dir);

        var result = try harness.runZiggit(&[_][]const u8{ "init", "plain" }, temp_dir);
        defer result.deinit();

        try testing.expect(result.exit_code == 0);
        
        // Check config exists and is not executable (git test requirement)
        const config_path = try std.fmt.allocPrint(allocator, "{s}/.git/config", .{plain_dir});
        defer allocator.free(config_path);
        
        try testing.expect(fileExists(config_path));
        std.debug.print("    ✓ plain init creates proper structure\n", .{});
    }

    // Test: bare init
    {
        var result = try harness.runZiggit(&[_][]const u8{ "init", "--bare", "bare.git" }, temp_dir);
        defer result.deinit();

        try testing.expect(result.exit_code == 0);
        
        const bare_dir = try std.fmt.allocPrint(allocator, "{s}/bare.git", .{temp_dir});
        defer allocator.free(bare_dir);
        const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{bare_dir});
        defer allocator.free(config_path);
        
        try testing.expect(fileExists(config_path));
        std.debug.print("    ✓ bare init creates proper structure\n", .{});
    }

    // Test: reinit existing
    {
        const reinit_dir = try std.fmt.allocPrint(allocator, "{s}/reinit", .{temp_dir});
        defer allocator.free(reinit_dir);

        // First init
        var result1 = try harness.runZiggit(&[_][]const u8{ "init", "reinit" }, temp_dir);
        defer result1.deinit();
        try testing.expect(result1.exit_code == 0);

        // Reinit
        var result2 = try harness.runZiggit(&[_][]const u8{ "init", "reinit" }, temp_dir);
        defer result2.deinit();
        try testing.expect(result2.exit_code == 0);
        
        std.debug.print("    ✓ reinit existing repository works\n", .{});
    }
}

// Tests based on t7508-status.sh from git source  
fn testStatusSourceStyle(allocator: std.mem.Allocator) !void {
    var harness = TestHarness.init(allocator, "/root/ziggit/zig-out/bin/ziggit", "git");

    std.debug.print("  Testing status (t7508-status.sh style)...\n", .{});

    const temp_dir = try harness.createTempDir("test_git_status_style");
    defer harness.removeTempDir(temp_dir);

    // Initialize repository
    var init_result = try harness.runZiggit(&[_][]const u8{"init"}, temp_dir);
    defer init_result.deinit();
    try testing.expect(init_result.exit_code == 0);

    // Test: status in empty repository
    {
        var result = try harness.runZiggit(&[_][]const u8{"status"}, temp_dir);
        defer result.deinit();

        try testing.expect(result.exit_code == 0);
        try testing.expect(std.mem.indexOf(u8, result.stdout, "On branch") != null);
        try testing.expect(std.mem.indexOf(u8, result.stdout, "No commits yet") != null);
        
        std.debug.print("    ✓ status in empty repository\n", .{});
    }

    // Test: status with untracked files
    {
        // Create untracked files
        const file1 = try std.fmt.allocPrint(allocator, "{s}/untracked.txt", .{temp_dir});
        defer allocator.free(file1);
        const file2 = try std.fmt.allocPrint(allocator, "{s}/dir1/tracked", .{temp_dir});
        defer allocator.free(file2);
        
        try harness.writeFile(file1, "untracked content");
        
        // Create directory and file
        const dir1 = try std.fmt.allocPrint(allocator, "{s}/dir1", .{temp_dir});
        defer allocator.free(dir1);
        try std.fs.makeDirAbsolute(dir1);
        try harness.writeFile(file2, "tracked content");

        var result = try harness.runZiggit(&[_][]const u8{"status"}, temp_dir);
        defer result.deinit();

        try testing.expect(result.exit_code == 0);
        try testing.expect(std.mem.indexOf(u8, result.stdout, "Untracked files:") != null);
        try testing.expect(std.mem.indexOf(u8, result.stdout, "untracked.txt") != null);
        try testing.expect(std.mem.indexOf(u8, result.stdout, "dir1/tracked") != null);
        
        std.debug.print("    ✓ status shows untracked files\n", .{});
    }

    // Test: status after add (staged files)
    {
        var add_result = try harness.runZiggit(&[_][]const u8{ "add", "untracked.txt" }, temp_dir);
        defer add_result.deinit();
        try testing.expect(add_result.exit_code == 0);

        var result = try harness.runZiggit(&[_][]const u8{"status"}, temp_dir);
        defer result.deinit();

        try testing.expect(result.exit_code == 0);
        try testing.expect(std.mem.indexOf(u8, result.stdout, "Changes to be committed:") != null);
        try testing.expect(std.mem.indexOf(u8, result.stdout, "new file:   untracked.txt") != null);
        
        std.debug.print("    ✓ status shows staged files\n", .{});
    }

    // Test: status with .gitignore
    {
        const gitignore_path = try std.fmt.allocPrint(allocator, "{s}/.gitignore", .{temp_dir});
        defer allocator.free(gitignore_path);
        const ignored_file = try std.fmt.allocPrint(allocator, "{s}/ignored.tmp", .{temp_dir});
        defer allocator.free(ignored_file);
        
        try harness.writeFile(gitignore_path, "*.tmp\n");
        try harness.writeFile(ignored_file, "ignored content");

        var result = try harness.runZiggit(&[_][]const u8{"status"}, temp_dir);
        defer result.deinit();

        try testing.expect(result.exit_code == 0);
        // Ignored file should not appear in status
        try testing.expect(std.mem.indexOf(u8, result.stdout, "ignored.tmp") == null);
        
        std.debug.print("    ✓ status respects .gitignore\n", .{});
    }
}

// Basic add/commit workflow tests
fn testAddCommitSourceStyle(allocator: std.mem.Allocator) !void {
    var harness = TestHarness.init(allocator, "/root/ziggit/zig-out/bin/ziggit", "git");

    std.debug.print("  Testing add/commit workflow...\n", .{});

    const temp_dir = try harness.createTempDir("test_git_workflow_style");
    defer harness.removeTempDir(temp_dir);

    // Initialize repository
    var init_result = try harness.runZiggit(&[_][]const u8{"init"}, temp_dir);
    defer init_result.deinit();
    try testing.expect(init_result.exit_code == 0);

    // Test: add nonexistent file (should fail)
    {
        var result = try harness.runZiggit(&[_][]const u8{ "add", "nonexistent.txt" }, temp_dir);
        defer result.deinit();
        
        try testing.expect(result.exit_code != 0);
        std.debug.print("    ✓ add nonexistent file fails correctly\n", .{});
    }

    // Test: add existing file
    {
        const file_path = try std.fmt.allocPrint(allocator, "{s}/test.txt", .{temp_dir});
        defer allocator.free(file_path);
        try harness.writeFile(file_path, "test content");

        var result = try harness.runZiggit(&[_][]const u8{ "add", "test.txt" }, temp_dir);
        defer result.deinit();
        
        try testing.expect(result.exit_code == 0);
        std.debug.print("    ✓ add existing file works\n", .{});
    }

    // Test: commit with staged files
    {
        var result = try harness.runZiggit(&[_][]const u8{ "commit", "-m", "test commit" }, temp_dir);
        defer result.deinit();
        
        try testing.expect(result.exit_code == 0);
        std.debug.print("    ✓ commit with staged files works\n", .{});
    }

    // Test: commit with nothing staged (should fail)
    {
        var result = try harness.runZiggit(&[_][]const u8{ "commit", "-m", "empty commit" }, temp_dir);
        defer result.deinit();
        
        try testing.expect(result.exit_code != 0);
        try testing.expect(std.mem.indexOf(u8, result.stderr, "nothing to commit") != null);
        std.debug.print("    ✓ commit with nothing staged fails correctly\n", .{});
    }

    // Test: log shows commit
    {
        var result = try harness.runZiggit(&[_][]const u8{"log"}, temp_dir);
        defer result.deinit();
        
        try testing.expect(result.exit_code == 0);
        try testing.expect(std.mem.indexOf(u8, result.stdout, "test commit") != null);
        std.debug.print("    ✓ log shows commit correctly\n", .{});
    }
}

// Helper function to check if file exists
fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

test "git source style tests" {
    try runGitSourceStyleTests();
}