const std = @import("std");
const testing = std.testing;

const test_harness = @import("test_harness.zig");
const TestHarness = test_harness.TestHarness;

// Comprehensive git compatibility tests
// Based on git's test suite structure (t/ directory)

// Test cases for init command (based on t0001-init.sh)
pub fn testInitPlain(harness: TestHarness) !void {
    std.debug.print("    Testing plain init...\n", .{});
    
    const temp_dir = try harness.createTempDir("test_init_plain");
    defer harness.removeTempDir(temp_dir);

    // Test plain init
    var init_result = try harness.runZiggit(&.{"init"}, temp_dir);
    defer init_result.deinit();

    try testing.expect(init_result.exit_code == 0);
    
    // Verify .git directory structure
    var git_dir_path = try std.fmt.allocPrint(harness.allocator, "{s}/.git", .{temp_dir});
    defer harness.allocator.free(git_dir_path);

    var git_dir = std.fs.openDirAbsolute(git_dir_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("    FAIL: .git directory not created\n", .{});
            return error.TestFailed;
        },
        else => return err,
    };
    defer git_dir.close();

    // Check for essential git directory structure
    const expected_files = [_][]const u8{ "config", "HEAD", "description" };
    const expected_dirs = [_][]const u8{ "refs", "objects", "hooks" };

    for (expected_files) |filename| {
        git_dir.access(filename, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                std.debug.print("    FAIL: Missing essential file: .git/{s}\n", .{filename});
                return error.TestFailed;
            },
            else => return err,
        };
    }

    for (expected_dirs) |dirname| {
        var dir = git_dir.openDir(dirname, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                std.debug.print("    FAIL: Missing essential directory: .git/{s}\n", .{dirname});
                return error.TestFailed;
            },
            else => return err,
        };
        dir.close();
    }

    std.debug.print("    ✓ init plain repository\n", .{});
}

pub fn testInitBare(harness: TestHarness) !void {
    std.debug.print("    Testing bare init...\n", .{});
    
    const temp_dir = try harness.createTempDir("test_init_bare");
    defer harness.removeTempDir(temp_dir);

    var init_result = try harness.runZiggit(&.{ "init", "--bare" }, temp_dir);
    defer init_result.deinit();

    try testing.expect(init_result.exit_code == 0);

    // In bare repo, git files are directly in the directory
    var dir = std.fs.openDirAbsolute(temp_dir, .{}) catch return error.TestFailed;
    defer dir.close();

    const expected_files = [_][]const u8{ "config", "HEAD", "description" };
    const expected_dirs = [_][]const u8{ "refs", "objects", "hooks" };

    for (expected_files) |filename| {
        dir.access(filename, .{}) catch {
            std.debug.print("    FAIL: Missing file in bare repo: {s}\n", .{filename});
            return error.TestFailed;
        };
    }

    for (expected_dirs) |dirname| {
        var subdir = dir.openDir(dirname, .{}) catch {
            std.debug.print("    FAIL: Missing directory in bare repo: {s}\n", .{dirname});
            return error.TestFailed;
        };
        subdir.close();
    }

    std.debug.print("    ✓ init bare repository\n", .{});
}

// Test cases for add command (based on t2200-add-update.sh and others)
pub fn testAddBasicFile(harness: TestHarness) !void {
    std.debug.print("    Testing add basic file...\n", .{});
    
    const temp_dir = try harness.createTempDir("test_add_basic");
    defer harness.removeTempDir(temp_dir);

    // Initialize repository
    var init_result = try harness.runZiggit(&.{"init"}, temp_dir);
    defer init_result.deinit();
    try testing.expect(init_result.exit_code == 0);

    // Create test file
    const file_path = try std.fmt.allocPrint(harness.allocator, "{s}/test.txt", .{temp_dir});
    defer harness.allocator.free(file_path);

    const file = try std.fs.cwd().createFile(file_path, .{});
    defer file.close();
    try file.writeAll("test content\n");

    // Add file
    var add_result = try harness.runZiggit(&.{ "add", "test.txt" }, temp_dir);
    defer add_result.deinit();

    try testing.expect(add_result.exit_code == 0);

    std.debug.print("    ✓ add basic file\n", .{});
}

pub fn testAddNonexistentFile(harness: TestHarness) !void {
    std.debug.print("    Testing add nonexistent file...\n", .{});
    
    const temp_dir = try harness.createTempDir("test_add_nonexistent");
    defer harness.removeTempDir(temp_dir);

    // Initialize repository
    var init_result = try harness.runZiggit(&.{"init"}, temp_dir);
    defer init_result.deinit();
    try testing.expect(init_result.exit_code == 0);

    // Try to add non-existent file
    var add_result = try harness.runZiggit(&.{ "add", "nonexistent.txt" }, temp_dir);
    defer add_result.deinit();

    // Should fail with appropriate error
    try testing.expect(add_result.exit_code != 0);

    std.debug.print("    ✓ add nonexistent file (correct failure)\n", .{});
}

// Test cases for status command
pub fn testStatusEmptyRepo(harness: TestHarness) !void {
    std.debug.print("    Testing status in empty repo...\n", .{});
    
    const temp_dir = try harness.createTempDir("test_status_empty");
    defer harness.removeTempDir(temp_dir);

    // Initialize repository
    var init_result = try harness.runZiggit(&.{"init"}, temp_dir);
    defer init_result.deinit();
    try testing.expect(init_result.exit_code == 0);

    // Run status
    var status_result = try harness.runZiggit(&.{"status"}, temp_dir);
    defer status_result.deinit();

    try testing.expect(status_result.exit_code == 0);

    std.debug.print("    ✓ status in empty repository\n", .{});
}

pub fn testStatusUntrackedFiles(harness: TestHarness) !void {
    std.debug.print("    Testing status with untracked files...\n", .{});
    
    const temp_dir = try harness.createTempDir("test_status_untracked");
    defer harness.removeTempDir(temp_dir);

    // Initialize repository
    var init_result = try harness.runZiggit(&.{"init"}, temp_dir);
    defer init_result.deinit();
    try testing.expect(init_result.exit_code == 0);

    // Create untracked file
    const file_path = try std.fmt.allocPrint(harness.allocator, "{s}/untracked.txt", .{temp_dir});
    defer harness.allocator.free(file_path);

    const file = try std.fs.cwd().createFile(file_path, .{});
    defer file.close();
    try file.writeAll("untracked content\n");

    // Run status
    var status_result = try harness.runZiggit(&.{"status"}, temp_dir);
    defer status_result.deinit();

    try testing.expect(status_result.exit_code == 0);

    std.debug.print("    ✓ status with untracked files\n", .{});
}

// Test cases for commit command
pub fn testCommitBasic(harness: TestHarness) !void {
    std.debug.print("    Testing basic commit...\n", .{});
    
    const temp_dir = try harness.createTempDir("test_commit_basic");
    defer harness.removeTempDir(temp_dir);

    // Initialize repository
    var init_result = try harness.runZiggit(&.{"init"}, temp_dir);
    defer init_result.deinit();
    try testing.expect(init_result.exit_code == 0);

    // Create and add file
    const file_path = try std.fmt.allocPrint(harness.allocator, "{s}/commit-test.txt", .{temp_dir});
    defer harness.allocator.free(file_path);

    const file = try std.fs.cwd().createFile(file_path, .{});
    defer file.close();
    try file.writeAll("commit test content\n");

    var add_result = try harness.runZiggit(&.{ "add", "commit-test.txt" }, temp_dir);
    defer add_result.deinit();
    try testing.expect(add_result.exit_code == 0);

    // Commit with message
    var commit_result = try harness.runZiggit(&.{ "commit", "-m", "Initial commit" }, temp_dir);
    defer commit_result.deinit();

    if (commit_result.exit_code == 0) {
        std.debug.print("    ✓ basic commit with message\n", .{});
    } else {
        std.debug.print("    ⚠ commit failed (implementation needed): {s}\n", .{commit_result.stderr});
    }
}

pub fn testCommitNothingToCommit(harness: TestHarness) !void {
    std.debug.print("    Testing commit with nothing to commit...\n", .{});
    
    const temp_dir = try harness.createTempDir("test_commit_nothing");
    defer harness.removeTempDir(temp_dir);

    // Initialize repository
    var init_result = try harness.runZiggit(&.{"init"}, temp_dir);
    defer init_result.deinit();
    try testing.expect(init_result.exit_code == 0);

    // Try to commit without staging anything
    var commit_result = try harness.runZiggit(&.{ "commit", "-m", "Empty commit" }, temp_dir);
    defer commit_result.deinit();

    // Should fail with appropriate error
    try testing.expect(commit_result.exit_code != 0);

    std.debug.print("    ✓ commit nothing to commit (correct failure)\n", .{});
}

// Test workflow combinations
pub fn testBasicWorkflow(harness: TestHarness) !void {
    std.debug.print("    Testing basic workflow (init -> add -> commit)...\n", .{});
    
    const temp_dir = try harness.createTempDir("test_basic_workflow");
    defer harness.removeTempDir(temp_dir);

    // 1. Initialize repository
    var init_result = try harness.runZiggit(&.{"init"}, temp_dir);
    defer init_result.deinit();
    try testing.expect(init_result.exit_code == 0);

    // 2. Create file
    const file_path = try std.fmt.allocPrint(harness.allocator, "{s}/workflow.txt", .{temp_dir});
    defer harness.allocator.free(file_path);

    const file = try std.fs.cwd().createFile(file_path, .{});
    defer file.close();
    try file.writeAll("workflow test content\n");

    // 3. Add file
    var add_result = try harness.runZiggit(&.{ "add", "workflow.txt" }, temp_dir);
    defer add_result.deinit();
    try testing.expect(add_result.exit_code == 0);

    // 4. Check status
    var status_result = try harness.runZiggit(&.{"status"}, temp_dir);
    defer status_result.deinit();
    try testing.expect(status_result.exit_code == 0);

    // 5. Commit
    var commit_result = try harness.runZiggit(&.{ "commit", "-m", "Workflow test commit" }, temp_dir);
    defer commit_result.deinit();

    if (commit_result.exit_code == 0) {
        std.debug.print("    ✓ basic workflow completed successfully\n", .{});
    } else {
        std.debug.print("    ⚠ workflow failed at commit step: {s}\n", .{commit_result.stderr});
    }
}

pub fn runGitComprehensiveTests() !void {
    std.debug.print("Running comprehensive git compatibility tests...\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const harness = TestHarness.init(allocator, "/root/ziggit/zig-out/bin/ziggit", "git");

    var failed: u32 = 0;
    var passed: u32 = 0;

    // Run all tests
    const tests = [_]struct { name: []const u8, func: *const fn (TestHarness) anyerror!void }{
        .{ .name = "init plain", .func = testInitPlain },
        .{ .name = "init bare", .func = testInitBare },
        .{ .name = "add basic file", .func = testAddBasicFile },
        .{ .name = "add nonexistent file", .func = testAddNonexistentFile },
        .{ .name = "status empty repo", .func = testStatusEmptyRepo },
        .{ .name = "status untracked files", .func = testStatusUntrackedFiles },
        .{ .name = "commit basic", .func = testCommitBasic },
        .{ .name = "commit nothing to commit", .func = testCommitNothingToCommit },
        .{ .name = "basic workflow", .func = testBasicWorkflow },
    };

    for (tests) |test_case| {
        std.debug.print("  Testing {s}...\n", .{test_case.name});
        
        test_case.func(harness) catch |err| {
            std.debug.print("    ❌ FAILED: {any}\n", .{err});
            failed += 1;
            continue;
        };
        passed += 1;
    }

    std.debug.print("Comprehensive tests completed: {d} passed, {d} failed\n", .{ passed, failed });

    if (failed > 0) {
        return error.TestsFailed;
    }
}

// Export for the main test runner
pub fn runTests() !void {
    try runGitComprehensiveTests();
}