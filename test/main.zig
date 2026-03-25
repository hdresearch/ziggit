const std = @import("std");
const test_harness = @import("test_harness.zig");
const compatibility_tests = @import("compatibility_tests.zig");
const workflow_tests = @import("workflow_tests.zig");

pub fn main() !void {
    try test_harness.runTests();
    try compatibility_tests.runCompatibilityTests();
    try workflow_tests.runWorkflowTests();
}

// Import test files for `zig build test`
test {
    std.testing.refAllDeclsRecursive(@import("test_harness.zig"));
    std.testing.refAllDeclsRecursive(@import("compatibility_tests.zig"));
    std.testing.refAllDeclsRecursive(@import("workflow_tests.zig"));
}