const std = @import("std");
const testing = std.testing;
const print = std.debug.print;
const test_harness = @import("test_harness.zig");
const TestHarness = test_harness.TestHarness;

// Git output format compatibility tests
// These tests ensure ziggit's output matches git's output as closely as possible

// Test format compatibility for init command
pub fn testInitFormatCompatibility(harness: TestHarness) !void {
    print("    Testing init format compatibility...\n", .{});
    
    const temp_dir = try harness.createTempDir("test_init_format");
    defer harness.removeTempDir(temp_dir);

    // Use the harness compareCommands function to compare outputs
    try harness.compareCommands(&.{"init"}, temp_dir, false);
    
    print("    ✓ init format compatibility\n", .{});
}

pub fn testStatusEmptyFormatCompatibility(harness: TestHarness) !void {
    print("    Testing status empty format compatibility...\n", .{});
    
    const temp_dir = try harness.createTempDir("test_status_empty_format");
    defer harness.removeTempDir(temp_dir);

    // Initialize repository first with ziggit
    var init_result = try harness.runZiggit(&.{"init"}, temp_dir);
    defer init_result.deinit();
    
    if (init_result.exit_code != 0) {
        print("    ⚠ skipping status format test (init failed)\n", .{});
        return;
    }

    try harness.compareCommands(&.{"status"}, temp_dir, false);
    print("    ✓ status empty format compatibility\n", .{});
}

// Test error message format compatibility
pub fn testErrorMessageCompatibility(harness: TestHarness) !void {
    print("    Testing error message format compatibility...\n", .{});
    
    // Test "not a git repository" error
    const temp_dir = try harness.createTempDir("test_error_format");
    defer harness.removeTempDir(temp_dir);

    try harness.compareCommands(&.{"status"}, temp_dir, false);
    print("    ✓ error message format compatibility\n", .{});
}

pub fn runGitFormatCompatibilityTests() !void {
    print("Running git output format compatibility tests...\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const harness = TestHarness.init(allocator, "/root/ziggit/zig-out/bin/ziggit", "git");

    var failed: u32 = 0;
    var passed: u32 = 0;

    const tests = [_]struct { name: []const u8, func: *const fn (TestHarness) anyerror!void }{
        .{ .name = "init format", .func = testInitFormatCompatibility },
        .{ .name = "status empty format", .func = testStatusEmptyFormatCompatibility },
        .{ .name = "error message format", .func = testErrorMessageCompatibility },
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

    print("Format compatibility tests completed: {d} passed, {d} failed\n", .{ passed, failed });

    if (failed > 0) {
        return error.TestsFailed;
    }
}

// Export for the main test runner
pub fn runTests() !void {
    try runGitFormatCompatibilityTests();
}