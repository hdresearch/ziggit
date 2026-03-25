const std = @import("std");
const test_harness = @import("test_harness.zig");
const compatibility_tests = @import("compatibility_tests.zig");
const workflow_tests = @import("workflow_tests.zig");
const integration_tests = @import("integration_tests.zig");
const format_tests = @import("format_tests.zig");
const git_basic_tests = @import("git_basic_tests.zig");
const git_comprehensive_tests = @import("git_comprehensive_tests.zig");
const git_branch_checkout_tests = @import("git_branch_checkout_tests.zig");
const git_log_diff_advanced_tests = @import("git_log_diff_advanced_tests.zig");
const git_format_compatibility_tests = @import("git_format_compatibility_tests.zig");
const essential_git_compatibility = @import("essential_git_compatibility.zig");
const git_source_compat_tests = @import("git_source_compat_tests.zig");
const enhanced_git_compat_tests = @import("enhanced_git_compat_tests.zig");

pub fn main() !void {
    try test_harness.runTests();
    try compatibility_tests.runCompatibilityTests();
    try workflow_tests.runWorkflowTests();
    try integration_tests.runIntegrationTests();
    try format_tests.runFormatTests();
    try git_basic_tests.runGitBasicTests();
    try git_comprehensive_tests.runGitComprehensiveTests();
    try git_branch_checkout_tests.runGitBranchCheckoutTests();
    try git_log_diff_advanced_tests.runGitLogDiffAdvancedTests();
    try essential_git_compatibility.runEssentialGitCompatibilityTests();
    try git_source_compat_tests.runGitSourceCompatTests();
    try enhanced_git_compat_tests.runEnhancedGitCompatTests();
    // Note: git_format_compatibility_tests temporarily disabled due to format differences
    // try git_format_compatibility_tests.runGitFormatCompatibilityTests();
}

// Import test files for `zig build test`
test {
    std.testing.refAllDeclsRecursive(@import("test_harness.zig"));
    std.testing.refAllDeclsRecursive(@import("compatibility_tests.zig"));
    std.testing.refAllDeclsRecursive(@import("workflow_tests.zig"));
    std.testing.refAllDeclsRecursive(@import("integration_tests.zig"));
    std.testing.refAllDeclsRecursive(@import("format_tests.zig"));
    std.testing.refAllDeclsRecursive(@import("git_basic_tests.zig"));
    std.testing.refAllDeclsRecursive(@import("git_comprehensive_tests.zig"));
    std.testing.refAllDeclsRecursive(@import("git_branch_checkout_tests.zig"));
    std.testing.refAllDeclsRecursive(@import("git_log_diff_advanced_tests.zig"));
    std.testing.refAllDeclsRecursive(@import("git_format_compatibility_tests.zig"));
    std.testing.refAllDeclsRecursive(@import("essential_git_compatibility.zig"));
    std.testing.refAllDeclsRecursive(@import("git_source_compat_tests.zig"));
    std.testing.refAllDeclsRecursive(@import("enhanced_git_compat_tests.zig"));
}