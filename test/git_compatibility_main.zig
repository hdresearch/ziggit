const std = @import("std");

// Import all test modules
const t0001_init_tests = @import("t0001_init_tests.zig");
const t2000_add_tests = @import("t2000_add_tests.zig");
const t3000_commit_tests = @import("t3000_commit_tests.zig");
const t7000_status_tests = @import("t7000_status_tests.zig");

pub fn main() !void {
    std.debug.print("=== Ziggit Git Compatibility Test Suite ===\n", .{});
    std.debug.print("Comprehensive testing of ziggit as a drop-in replacement for git\n", .{});
    std.debug.print("Based on git source test suite (git/git.git/t/)\n\n", .{});
    
    var overall_success = true;
    
    // Run init tests
    std.debug.print("Running Git Init Tests...\n", .{});
    t0001_init_tests.runT0001InitTests() catch |err| {
        std.debug.print("Init tests failed: {}\n", .{err});
        overall_success = false;
    };
    std.debug.print("\n==================================================\n\n", .{});
    
    // Run add tests  
    std.debug.print("Running Git Add Tests...\n", .{});
    t2000_add_tests.runT2000AddTests() catch |err| {
        std.debug.print("Add tests failed: {}\n", .{err});
        overall_success = false;
    };
    std.debug.print("\n==================================================\n\n", .{});
    
    // Run commit tests
    std.debug.print("Running Git Commit Tests...\n", .{});
    t3000_commit_tests.runT3000CommitTests() catch |err| {
        std.debug.print("Commit tests failed: {}\n", .{err});
        overall_success = false;
    };
    std.debug.print("\n==================================================\n\n", .{});
    
    // Run status tests
    std.debug.print("Running Git Status Tests...\n", .{});
    t7000_status_tests.runT7000StatusTests() catch |err| {
        std.debug.print("Status tests failed: {}\n", .{err});
        overall_success = false;
    };
    std.debug.print("\n==================================================\n\n", .{});
    
    // Summary
    std.debug.print("=== Ziggit Git Compatibility Test Suite Complete ===\n", .{});
    if (overall_success) {
        std.debug.print("✓ All test suites completed successfully!\n", .{});
        std.debug.print("✓ Ziggit demonstrates strong compatibility with git\n", .{});
        std.debug.print("\nZiggit is ready to be used as a drop-in replacement for git\n", .{});
        std.debug.print("for the tested operations: init, add, commit, status\n", .{});
    } else {
        std.debug.print("⚠ Some test suites encountered issues\n", .{});
        std.debug.print("⚠ Review the output above to identify compatibility gaps\n", .{});
        std.debug.print("\nZiggit may need additional work to achieve full git compatibility\n", .{});
    }
    
    std.debug.print("\nNext steps:\n", .{});
    std.debug.print("- Add more test suites: log, diff, branch, checkout, merge\n", .{});
    std.debug.print("- Run full git test suite adaptation\n", .{});
    std.debug.print("- Performance benchmarking against git\n", .{});
    std.debug.print("- Integration testing with real workflows\n", .{});
}