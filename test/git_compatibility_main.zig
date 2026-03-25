const std = @import("std");
const TestFramework = @import("test_framework.zig").TestFramework;

fn print(comptime format: []const u8, args: anytype) void {
    std.io.getStdOut().writer().print(format, args) catch {};
}

fn println(comptime format: []const u8) void {
    print(format, .{});
}

// Import test modules
const t0001_init_test = @import("t0001_init_test.zig");
const t2000_add_test = @import("t2000_add_test.zig");
const t3000_commit_test = @import("t3000_commit_test.zig");
const t7000_status_test = @import("t7000_status_test.zig");
const t4000_log_test = @import("t4000_log_test.zig");

pub fn main() !void {
    print("=== Ziggit Git Compatibility Test Suite ===\n", .{});
    print("Based on git's test structure (t/tNNNN-*.sh)\n", .{});
    print("Testing core git operations for drop-in compatibility\n\n", .{});
    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Initialize test framework
    const ziggit_path = "/root/ziggit/zig-out/bin/ziggit";
    var tf = TestFramework.init(allocator, ziggit_path);
    
    // Check that ziggit binary exists
    std.fs.accessAbsolute(ziggit_path, .{}) catch |err| {
        print("❌ Error: ziggit binary not found at {s}\n", .{ziggit_path});
        print("   Please run 'zig build' first\n", .{});
        print("   Error: {}\n", .{err});
        std.process.exit(1);
    };
    
    print("✅ Found ziggit binary at {s}\n", .{ziggit_path});
    
    // Check that git is available for comparison
    var git_check = tf.runCommand(&[_][]const u8{"git", "--version"}, "/tmp") catch |err| {
        print("❌ Error: git command not available for compatibility testing\n", .{});
        print("   Error: {}\n", .{err});
        std.process.exit(1);
    };
    defer git_check.deinit(allocator);
    
    if (git_check.exit_code == 0) {
        print("✅ Found git: {s}\n", .{std.mem.trim(u8, git_check.stdout, " \n\r\t")});
    } else {
        print("❌ Error: git command failed: {s}\n", .{git_check.stderr});
        std.process.exit(1);
    }
    
    print("\n=== Starting Test Execution ===\n", .{});
    
    // Run test suites in logical order
    const test_suites = [_]struct {
        name: []const u8,
        func: *const fn(*TestFramework) anyerror!void,
    }{
        .{ .name = "t0001-init", .func = t0001_init_test.runTests },
        .{ .name = "t2000-add", .func = t2000_add_test.runTests },
        .{ .name = "t3000-commit", .func = t3000_commit_test.runTests },
        .{ .name = "t7000-status", .func = t7000_status_test.runTests },
        .{ .name = "t4000-log", .func = t4000_log_test.runTests },
    };
    
    var suite_results = std.ArrayList(bool).init(allocator);
    defer suite_results.deinit();
    
    for (test_suites) |suite| {
        print("\n" ++ "=" ** 60 ++ "\n", .{});
        print("RUNNING TEST SUITE: {s}\n", .{suite.name});
        print("=" ** 60 ++ "\n", .{});
        
        const initial_passed = tf.passed_tests;
        const initial_failed = tf.failed_tests;
        
        suite.func(&tf) catch |err| {
            print("❌ Test suite {s} encountered an error: {}\n", .{ suite.name, err });
            tf.failed_tests += 1;
        };
        
        const suite_passed = tf.passed_tests - initial_passed;
        const suite_failed = tf.failed_tests - initial_failed;
        const suite_total = suite_passed + suite_failed;
        
        print("\n--- {s} Results ---\n", .{suite.name});
        print("Passed: {d}/{d}\n", .{ suite_passed, suite_total });
        if (suite_failed > 0) {
            print("Failed: {d}\n", .{suite_failed});
        }
        
        try suite_results.append(suite_failed == 0);
    }
    
    // Print final summary
    print("\n" ++ "=" ** 60 ++ "\n", .{});
    print("FINAL TEST RESULTS\n", .{});
    print("=" ** 60 ++ "\n", .{});
    
    var successful_suites: u32 = 0;
    for (test_suites, suite_results.items) |suite, passed| {
        if (passed) {
            successful_suites += 1;
            print("✅ {s}: PASSED\n", .{suite.name});
        } else {
            print("❌ {s}: FAILED\n", .{suite.name});
        }
    }
    
    tf.printSummary();
    
    print("\nTest Suites: {d}/{d} passed\n", .{ successful_suites, test_suites.len });
    
    // Print compatibility assessment
    print("\n=== Git Compatibility Assessment ===\n", .{});
    const pass_rate = if (tf.passed_tests + tf.failed_tests > 0) 
        (tf.passed_tests * 100) / (tf.passed_tests + tf.failed_tests) else 0;
    
    if (pass_rate >= 90) {
        print("🎉 EXCELLENT: {d}% compatibility - Ready for production use\n", .{pass_rate});
    } else if (pass_rate >= 75) {
        print("✅ GOOD: {d}% compatibility - Most features working\n", .{pass_rate});
    } else if (pass_rate >= 50) {
        print("⚠️  FAIR: {d}% compatibility - Core features working, needs improvement\n", .{pass_rate});
    } else {
        print("❌ POOR: {d}% compatibility - Major features missing\n", .{pass_rate});
    }
    
    if (tf.failed_tests > 0) {
        print("\n=== Areas for Improvement ===\n", .{});
        print("• Review failed tests above for specific issues\n", .{});
        print("• Focus on core git compatibility for drop-in replacement\n", .{});
        print("• Ensure output formats match git where possible\n", .{});
        print("• Implement missing command-line options\n", .{});
    }
    
    // Set exit code based on results
    if (tf.hasFailures()) {
        print("\n❌ Some tests failed. Ziggit needs improvements for full git compatibility.\n", .{});
        std.process.exit(1);
    } else {
        print("\n🎉 All tests passed! Ziggit is git-compatible for tested operations.\n", .{});
        std.process.exit(0);
    }
}