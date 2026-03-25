const std = @import("std");
const test_harness = @import("test_harness.zig");

pub fn main() !void {
    try test_harness.runTests();
}

// Import test files for `zig build test`
test {
    std.testing.refAllDeclsRecursive(@import("test_harness.zig"));
}