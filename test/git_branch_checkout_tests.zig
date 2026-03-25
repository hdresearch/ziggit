const std = @import("std");
const testing = std.testing;

const test_harness = @import("test_harness.zig");
const TestHarness = test_harness.TestHarness;

// Git branch and checkout compatibility tests
// Based on git's test suite structure

// Test branch creation and listing
pub fn testBranchList(harness: TestHarness) !void {
    std.debug.print("    Testing branch list...\n", .{});
    
    const temp_dir = try harness.createTempDir("test_branch_list");
    defer harness.removeTempDir(temp_dir);

    // Initialize repository
    var init_result = try harness.runZiggit(&.{"init"}, temp_dir);
    defer init_result.deinit();
    try testing.expect(init_result.exit_code == 0);

    // List branches in empty repository
    var branch_result = try harness.runZiggit(&.{"branch"}, temp_dir);
    defer branch_result.deinit();

    try testing.expect(branch_result.exit_code == 0);

    std.debug.print("    ✓ branch list in empty repository\n", .{});
}

pub fn testCheckoutBranch(harness: TestHarness) !void {
    std.debug.print("    Testing checkout in empty repository...\n", .{});
    
    const temp_dir = try harness.createTempDir("test_checkout");
    defer harness.removeTempDir(temp_dir);

    // Initialize repository
    var init_result = try harness.runZiggit(&.{"init"}, temp_dir);
    defer init_result.deinit();
    try testing.expect(init_result.exit_code == 0);

    // Test checkout in empty repository (should fail appropriately)
    var checkout_result = try harness.runZiggit(&.{ "checkout", "nonexistent" }, temp_dir);
    defer checkout_result.deinit();

    // Should fail in empty repository
    try testing.expect(checkout_result.exit_code != 0);

    std.debug.print("    ✓ checkout in empty repository (correct failure)\n", .{});
}

pub fn runGitBranchCheckoutTests() !void {
    std.debug.print("Running git branch and checkout compatibility tests...\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const harness = TestHarness.init(allocator, "/root/ziggit/zig-out/bin/ziggit", "git");

    var failed: u32 = 0;
    var passed: u32 = 0;

    const tests = [_]struct { name: []const u8, func: *const fn (TestHarness) anyerror!void }{
        .{ .name = "branch list", .func = testBranchList },
        .{ .name = "checkout in empty repository", .func = testCheckoutBranch },
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

    std.debug.print("Branch/checkout tests completed: {d} passed, {d} failed\n", .{ passed, failed });

    if (failed > 0) {
        return error.TestsFailed;
    }
}

// Export for the main test runner
pub fn runTests() !void {
    try runGitBranchCheckoutTests();
}