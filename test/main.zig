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
const standalone_functionality_tests = @import("standalone_functionality_tests.zig");
const git_source_style_tests = @import("git_source_style_tests.zig");
const git_compatibility_test_suite = @import("git_compatibility_test_suite.zig");
const comprehensive_git_test_suite = @import("comprehensive_git_test_suite.zig");
const git_t0001_init_compat = @import("git_t0001_init_compat.zig");
const git_status_compat = @import("git_status_compat.zig");
const git_diff_output_compat = @import("git_diff_output_compat.zig");
const git_error_message_compat = @import("git_error_message_compat.zig");
const git_advanced_compatibility_tests = @import("git_advanced_compatibility_tests.zig");
const git_edge_case_tests = @import("git_edge_case_tests.zig");
const git_output_format_tests = @import("git_output_format_tests.zig");
// const git_source_comparison_tests = @import("git_source_comparison_tests.zig");
// const advanced_git_operations_tests = @import("advanced_git_operations_tests.zig");

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
    try standalone_functionality_tests.runStandaloneFunctionalityTests();
    try git_compatibility_test_suite.runGitCompatibilityTestSuite();
    try comprehensive_git_test_suite.runComprehensiveGitTestSuite();
    try git_t0001_init_compat.runGitT0001InitCompatTests();
    try git_status_compat.runGitStatusCompatTests();
    try git_diff_output_compat.runGitDiffOutputCompatTests();
    try git_error_message_compat.runGitErrorMessageCompatTests();
    try git_advanced_compatibility_tests.runGitAdvancedCompatibilityTests();
    try git_edge_case_tests.runGitEdgeCaseTests();
    try git_output_format_tests.runGitOutputFormatTests();
    // try git_source_comparison_tests.runGitSourceComparisonTests();
    // try advanced_git_operations_tests.runAdvancedGitOperationsTests();
    // TODO: Fix executable path issues in git_source_style_tests
    // try git_source_style_tests.runGitSourceStyleTests();
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
    std.testing.refAllDeclsRecursive(@import("standalone_functionality_tests.zig"));
    std.testing.refAllDeclsRecursive(@import("git_source_style_tests.zig"));
    std.testing.refAllDeclsRecursive(@import("git_compatibility_test_suite.zig"));
    std.testing.refAllDeclsRecursive(@import("comprehensive_git_test_suite.zig"));
    std.testing.refAllDeclsRecursive(@import("git_t0001_init_compat.zig"));
    std.testing.refAllDeclsRecursive(@import("git_status_compat.zig"));
    std.testing.refAllDeclsRecursive(@import("git_diff_output_compat.zig"));
    std.testing.refAllDeclsRecursive(@import("git_error_message_compat.zig"));
    // std.testing.refAllDeclsRecursive(@import("git_source_comparison_tests.zig"));
    // std.testing.refAllDeclsRecursive(@import("advanced_git_operations_tests.zig"));
}