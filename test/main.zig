const std = @import("std");
const test_harness = @import("test_harness.zig");
const compatibility_tests = @import("compatibility_tests.zig");
const workflow_tests = @import("workflow_tests.zig");
const integration_tests = @import("integration_tests.zig");
const format_tests = @import("format_tests.zig");
const git_basic_tests = @import("git_basic_tests.zig");

pub fn main() !void {
    try test_harness.runTests();
    try compatibility_tests.runCompatibilityTests();
    try workflow_tests.runWorkflowTests();
    try integration_tests.runIntegrationTests();
    try format_tests.runFormatTests();
    try git_basic_tests.runGitBasicTests();
}

// Import test files for `zig build test`
test {
    std.testing.refAllDeclsRecursive(@import("test_harness.zig"));
    std.testing.refAllDeclsRecursive(@import("compatibility_tests.zig"));
    std.testing.refAllDeclsRecursive(@import("workflow_tests.zig"));
    std.testing.refAllDeclsRecursive(@import("integration_tests.zig"));
    std.testing.refAllDeclsRecursive(@import("format_tests.zig"));
    std.testing.refAllDeclsRecursive(@import("git_basic_tests.zig"));
}