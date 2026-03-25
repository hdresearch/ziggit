const std = @import("std");
const TestFramework = @import("test_framework.zig").TestFramework;
const edge_case_tests = @import("git_edge_case_compatibility_tests.zig");

fn print(comptime format: []const u8, args: anytype) void {
    std.io.getStdOut().writer().print(format, args) catch {};
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    print("=== Ziggit Git Edge Case Compatibility Test Suite ===\n", .{});
    print("Testing edge cases and corner scenarios for robust git compatibility\n\n", .{});

    // Check if ziggit binary exists
    const ziggit_path = "/root/ziggit/zig-out/bin/ziggit";
    std.fs.accessAbsolute(ziggit_path, .{}) catch {
        print("❌ ziggit binary not found at {s}\n", .{ziggit_path});
        print("   Please run 'zig build' first\n", .{});
        std.process.exit(1);
    };
    print("✅ Found ziggit binary at {s}\n", .{ziggit_path});

    var tf = TestFramework.init(allocator, ziggit_path);

    print("\n=== Starting Edge Case Tests ===\n", .{});
    
    edge_case_tests.runGitEdgeCaseTests(&tf) catch |err| {
        print("\n❌ Test suite encountered an error: {}\n", .{err});
        std.process.exit(1);
    };

    print("\n=== Final Edge Case Assessment ===\n", .{});
    
    const total_tests = tf.passed_tests + tf.failed_tests;
    const pass_rate = if (total_tests > 0) @as(f32, @floatFromInt(tf.passed_tests)) / @as(f32, @floatFromInt(total_tests)) * 100.0 else 0.0;
    
    print("Total edge case tests run: {d}\n", .{total_tests});
    print("Passed: {d}\n", .{tf.passed_tests});
    print("Failed: {d}\n", .{tf.failed_tests});
    print("Pass rate: {d:.1}%\n", .{pass_rate});
    
    if (tf.failed_tests == 0) {
        print("\n🎉 All edge case tests PASSED!\n", .{});
        print("✅ Ziggit handles edge cases robustly\n", .{});
        std.process.exit(0);
    } else if (pass_rate >= 80.0) {
        print("\n🎯 Good edge case handling! Some advanced features may be missing.\n", .{});
        print("⚠️  Ziggit handles most edge cases but has {d} areas for improvement\n", .{tf.failed_tests});
        std.process.exit(0);
    } else {
        print("\n⚠️  Edge case handling needs improvement.\n", .{});
        print("🔧 Ziggit needs work on {d} edge cases for robust production use\n", .{tf.failed_tests});
        std.process.exit(1);
    }
}