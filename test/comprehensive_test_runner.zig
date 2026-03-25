const std = @import("std");

// Import all our comprehensive test modules
const t0001_init = @import("t0001_init_comprehensive.zig");
const t2000_add = @import("t2000_add_comprehensive.zig");
const t3000_commit = @import("t3000_commit_comprehensive.zig");
const t7000_status = @import("t7000_status_comprehensive.zig");

pub fn main() !void {
    std.debug.print("🚀 Starting Comprehensive Git Compatibility Test Suite\n", .{});
    std.debug.print("============================================================\n\n", .{});

    var overall_failed = false;

    // Run t0001 init tests
    std.debug.print("📁 Running Repository Initialization Tests (t0001)...\n", .{});
    std.debug.print("------------------------------------------------------\n", .{});
    t0001_init.runInitTests() catch {
        overall_failed = true;
        std.debug.print("❌ Init tests FAILED\n\n", .{});
    };
    if (!overall_failed) {
        std.debug.print("✅ Init tests PASSED\n\n", .{});
    }

    // Run t2000 add tests  
    std.debug.print("📝 Running File Staging Tests (t2000)...\n", .{});
    std.debug.print("----------------------------------------\n", .{});
    t2000_add.runAddTests() catch {
        overall_failed = true;
        std.debug.print("❌ Add tests FAILED\n\n", .{});
    };
    if (!overall_failed) {
        std.debug.print("✅ Add tests PASSED\n\n", .{});
    }

    // Run t3000 commit tests
    std.debug.print("💾 Running Commit Tests (t3000)...\n", .{});
    std.debug.print("-----------------------------------\n", .{});
    t3000_commit.runCommitTests() catch {
        overall_failed = true;
        std.debug.print("❌ Commit tests FAILED\n\n", .{});
    };
    if (!overall_failed) {
        std.debug.print("✅ Commit tests PASSED\n\n", .{});
    }

    // Run t7000 status tests
    std.debug.print("📊 Running Status Tests (t7000)...\n", .{});
    std.debug.print("----------------------------------\n", .{});
    t7000_status.runStatusTests() catch {
        overall_failed = true;
        std.debug.print("❌ Status tests FAILED\n\n", .{});
    };
    if (!overall_failed) {
        std.debug.print("✅ Status tests PASSED\n\n", .{});
    }

    // Final summary
    std.debug.print("============================================================\n", .{});
    std.debug.print("🎯 COMPREHENSIVE TEST SUITE SUMMARY\n", .{});
    std.debug.print("============================================================\n", .{});

    if (overall_failed) {
        std.debug.print("❌ Some tests FAILED - ziggit needs more work for full git compatibility\n", .{});
        std.debug.print("   Check the output above for specific failure details.\n", .{});
        std.debug.print("   Priority: Fix failing tests to achieve drop-in git replacement.\n\n", .{});
        std.process.exit(1);
    } else {
        std.debug.print("🎉 ALL TESTS PASSED - ziggit shows excellent git compatibility!\n", .{});
        std.debug.print("   ✅ Repository initialization works correctly\n", .{});
        std.debug.print("   ✅ File staging (add) works correctly\n", .{});
        std.debug.print("   ✅ Committing works correctly\n", .{});
        std.debug.print("   ✅ Status reporting works correctly\n", .{});
        std.debug.print("\n🚀 ziggit is ready as a drop-in replacement for basic git operations!\n\n", .{});
    }

    // Performance note
    std.debug.print("📊 NEXT STEPS:\n", .{});
    std.debug.print("   1. Run performance benchmarks against git\n", .{});
    std.debug.print("   2. Test advanced git features (branch, merge, remote)\n", .{});
    std.debug.print("   3. Test with large repositories\n", .{});
    std.debug.print("   4. Validate WebAssembly builds\n", .{});
    std.debug.print("   5. Consider integration with bun.js\n\n", .{});
}