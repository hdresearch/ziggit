const std = @import("std");
const TestFramework = @import("test_framework.zig").TestFramework;
const critical_tests = @import("critical_git_compatibility_tests.zig");

fn print(comptime format: []const u8, args: anytype) void {
    std.io.getStdOut().writer().print(format, args) catch {};
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    print("=== Ziggit Critical Git Compatibility Test Suite ===\n", .{});
    print("Testing essential git operations for drop-in replacement\n\n", .{});

    // Check if ziggit binary exists
    const ziggit_path = "/root/ziggit/zig-out/bin/ziggit";
    std.fs.accessAbsolute(ziggit_path, .{}) catch {
        print("❌ ziggit binary not found at {s}\n", .{ziggit_path});
        print("   Please run 'zig build' first\n", .{});
        std.process.exit(1);
    };
    print("✅ Found ziggit binary at {s}\n", .{ziggit_path});

    // Check git availability
    var git_check = std.process.Child.init(&[_][]const u8{"git", "--version"}, allocator);
    git_check.stdout_behavior = .Ignore;
    git_check.stderr_behavior = .Ignore;
    const git_term = git_check.spawnAndWait() catch {
        print("❌ git command not available\n", .{});
        std.process.exit(1);
    };
    
    if (git_term != .Exited or git_term.Exited != 0) {
        print("❌ git command not working properly\n", .{});
        std.process.exit(1);
    }
    print("✅ Found working git installation\n", .{});

    var tf = TestFramework.init(allocator, ziggit_path);

    print("\n=== Starting Critical Compatibility Tests ===\n", .{});
    
    critical_tests.runCriticalCompatibilityTests(&tf) catch |err| {
        print("\n❌ Test suite encountered an error: {}\n", .{err});
        std.process.exit(1);
    };

    print("\n=== Final Assessment ===\n", .{});
    
    const total_tests = tf.passed_tests + tf.failed_tests;
    const pass_rate = if (total_tests > 0) @as(f32, @floatFromInt(tf.passed_tests)) / @as(f32, @floatFromInt(total_tests)) * 100.0 else 0.0;
    
    print("Total tests run: {d}\n", .{total_tests});
    print("Passed: {d}\n", .{tf.passed_tests});
    print("Failed: {d}\n", .{tf.failed_tests});
    print("Pass rate: {d:.1}%\n", .{pass_rate});
    
    if (tf.failed_tests == 0) {
        print("\n🎉 All critical compatibility tests PASSED!\n", .{});
        print("✅ Ziggit is ready for use as a git drop-in replacement\n", .{});
        std.process.exit(0);
    } else if (pass_rate >= 90.0) {
        print("\n🎯 Excellent compatibility! Minor issues remain.\n", .{});
        print("⚠️  Ziggit is largely compatible but has {d} issues to address\n", .{tf.failed_tests});
        std.process.exit(0);
    } else if (pass_rate >= 75.0) {
        print("\n⚠️  Good compatibility with some gaps.\n", .{});
        print("🔧 Ziggit needs improvement in {d} areas\n", .{tf.failed_tests});
        std.process.exit(1);
    } else {
        print("\n❌ Significant compatibility issues found.\n", .{});
        print("🔧 Ziggit needs major improvements before production use\n", .{});
        std.process.exit(1);
    }
}