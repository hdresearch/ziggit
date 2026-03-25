const std = @import("std");
const core_git_compatibility_tests = @import("core_git_compatibility_tests.zig");
const git_source_adapted_tests = @import("git_source_adapted_tests.zig");

pub fn main() !void {
    std.debug.print("=== Ziggit Compatibility Test Suite ===\n", .{});
    std.debug.print("Testing drop-in replacement compatibility with git\n", .{});
    std.debug.print("Adapted from git source test suite (git/git.git/t/)\n\n", .{});
    
    // Run core compatibility tests
    try core_git_compatibility_tests.runCoreGitCompatibilityTests();
    std.debug.print("\n", .{});
    
    // Run git source adapted tests
    try git_source_adapted_tests.runGitSourceAdaptedTests();
    std.debug.print("\n", .{});
    
    std.debug.print("=== Test Suite Complete ===\n", .{});
    std.debug.print("See output above for detailed test results\n", .{});
}

// Import test files for `zig build test`
test {
    std.testing.refAllDeclsRecursive(@import("core_git_compatibility_tests.zig"));
    std.testing.refAllDeclsRecursive(@import("git_source_adapted_tests.zig"));
}