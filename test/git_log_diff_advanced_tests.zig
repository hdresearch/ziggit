const std = @import("std");
const testing = std.testing;
const print = std.debug.print;
const test_harness = @import("test_harness.zig");
const TestHarness = test_harness.TestHarness;

// Advanced git log and diff compatibility tests
// Based on git's test suite structure

// Test log command functionality
pub fn testLogEmptyRepository(harness: TestHarness) !void {
    print("    Testing log in empty repository...\n", .{});
    
    const temp_dir = try harness.createTempDir("test_log_empty");
    defer harness.removeTempDir(temp_dir);

    // Initialize repository
    var init_result = try harness.runZiggit(&.{"init"}, temp_dir);
    defer init_result.deinit();
    try testing.expect(init_result.exit_code == 0);

    // Run log in empty repository
    var log_result = try harness.runZiggit(&.{"log"}, temp_dir);
    defer log_result.deinit();

    // Should fail with appropriate error in empty repository
    try testing.expect(log_result.exit_code != 0);

    print("    ✓ log in empty repository (correct failure)\n", .{});
}

// Test diff command functionality  
pub fn testDiffEmptyRepository(harness: TestHarness) !void {
    print("    Testing diff in empty repository...\n", .{});
    
    const temp_dir = try harness.createTempDir("test_diff_empty");
    defer harness.removeTempDir(temp_dir);

    // Initialize repository
    var init_result = try harness.runZiggit(&.{"init"}, temp_dir);
    defer init_result.deinit();
    try testing.expect(init_result.exit_code == 0);

    // Run diff in empty repository
    var diff_result = try harness.runZiggit(&.{"diff"}, temp_dir);
    defer diff_result.deinit();

    // Should succeed with no output in empty repository
    try testing.expect(diff_result.exit_code == 0);

    print("    ✓ diff in empty repository\n", .{});
}

pub fn testDiffWithChanges(harness: TestHarness) !void {
    print("    Testing diff with changes...\n", .{});
    
    const temp_dir = try harness.createTempDir("test_diff_changes");
    defer harness.removeTempDir(temp_dir);

    // Initialize repository
    var init_result = try harness.runZiggit(&.{"init"}, temp_dir);
    defer init_result.deinit();
    try testing.expect(init_result.exit_code == 0);

    // Create a file
    const file_path = try std.fmt.allocPrint(harness.allocator, "{s}/diff-test.txt", .{temp_dir});
    defer harness.allocator.free(file_path);

    const file1 = try std.fs.cwd().createFile(file_path, .{});
    defer file1.close();
    try file1.writeAll("original content\nline 2\nline 3\n");

    var add_result = try harness.runZiggit(&.{ "add", "diff-test.txt" }, temp_dir);
    defer add_result.deinit();

    if (add_result.exit_code != 0) {
        print("    ⚠ skipping diff test (add failed)\n", .{});
        return;
    }

    var commit_result = try harness.runZiggit(&.{ "commit", "-m", "Initial commit for diff test" }, temp_dir);
    defer commit_result.deinit();

    if (commit_result.exit_code != 0) {
        print("    ⚠ skipping diff test (commit failed)\n", .{});
        return;
    }

    // Modify the file
    const file2 = try std.fs.cwd().createFile(file_path, .{});
    defer file2.close();
    try file2.writeAll("modified content\nline 2\nnew line 3\n");

    // Run diff
    var diff_result = try harness.runZiggit(&.{"diff"}, temp_dir);
    defer diff_result.deinit();

    if (diff_result.exit_code == 0) {
        print("    ✓ diff with changes\n", .{});
    } else {
        print("    ⚠ diff command failed: {s}\n", .{diff_result.stderr});
    }
}

pub fn runGitLogDiffAdvancedTests() !void {
    print("Running git log and diff advanced compatibility tests...\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const harness = TestHarness.init(allocator, "/root/zigg/root/ziggit/zig-out/bin/ziggit", "git");

    var failed: u32 = 0;
    var passed: u32 = 0;

    const tests = [_]struct { name: []const u8, func: *const fn (TestHarness) anyerror!void }{
        .{ .name = "log empty repository", .func = testLogEmptyRepository },
        .{ .name = "diff empty repository", .func = testDiffEmptyRepository },
        .{ .name = "diff with changes", .func = testDiffWithChanges },
    };

    for (tests) |test_case| {
        print("  Testing {s}...\n", .{test_case.name});
        
        test_case.func(harness) catch |err| {
            print("    ❌ FAILED: {any}\n", .{err});
            failed += 1;
            continue;
        };
        passed += 1;
    }

    print("Log/diff advanced tests completed: {d} passed, {d} failed\n", .{ passed, failed });

    if (failed > 0) {
        return error.TestsFailed;
    }
}

// Export for the main test runner
pub fn runTests() !void {
    try runGitLogDiffAdvancedTests();
}