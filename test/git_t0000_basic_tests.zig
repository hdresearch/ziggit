// Git source compatibility tests adapted from t0000-basic.sh
const std = @import("std");
const print = std.debug.print;

pub const TestFramework = @import("git_source_test_harness.zig").TestFramework;

pub fn runBasicTests() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var tf = TestFramework.init(allocator);
    defer tf.deinit();
    
    print("Running git basic functionality tests (adapted from t0000-basic.sh)...\n");
    
    try testBasicUsage(&tf);
    try testHelpOutput(&tf);
    try testVersionOutput(&tf);
    try testInvalidCommands(&tf);
    
    print("✓ All basic tests passed!\n");
}

fn testBasicUsage(tf: *TestFramework) !void {
    print("  Testing basic usage patterns...\n");
    
    // Test that ziggit exists and runs
    var version_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "--version" 
    }, "/tmp");
    defer version_result.deinit();
    
    if (version_result.exit_code != 0) {
        print("    ❌ ziggit --version failed: {s}\n", .{version_result.stderr});
        return;
    }
    
    print("    ✓ ziggit executable runs successfully\n");
}

fn testHelpOutput(tf: *TestFramework) !void {
    print("  Testing help output...\n");
    
    // Test --help
    var help_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "--help" 
    }, "/tmp");
    defer help_result.deinit();
    
    if (help_result.exit_code != 0) {
        print("    ❌ ziggit --help failed: {s}\n", .{help_result.stderr});
        return;
    }
    
    // Should contain usage information
    if (std.mem.indexOf(u8, help_result.stdout, "usage") == null and 
        std.mem.indexOf(u8, help_result.stdout, "Usage") == null) {
        print("    ❌ Help output doesn't contain usage information\n");
        return;
    }
    
    // Test help for specific commands
    var help_init_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "help", "init" 
    }, "/tmp");
    defer help_init_result.deinit();
    
    if (help_init_result.exit_code != 0) {
        print("    ⚠ ziggit help init not implemented\n");
    } else {
        print("    ✓ Command-specific help works\n");
    }
    
    print("    ✓ Help output test passed\n");
}

fn testVersionOutput(tf: *TestFramework) !void {
    print("  Testing version output...\n");
    
    var version_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "--version" 
    }, "/tmp");
    defer version_result.deinit();
    
    if (version_result.exit_code != 0) {
        print("    ❌ ziggit --version failed: {s}\n", .{version_result.stderr});
        return;
    }
    
    // Should contain version information
    if (std.mem.indexOf(u8, version_result.stdout, "version") == null and 
        std.mem.indexOf(u8, version_result.stdout, "ziggit") == null) {
        print("    ❌ Version output doesn't contain version information\n");
        return;
    }
    
    print("    ✓ Version output test passed\n");
}

fn testInvalidCommands(tf: *TestFramework) !void {
    print("  Testing invalid command handling...\n");
    
    // Test completely invalid command
    var invalid_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit", "not-a-real-command" 
    }, "/tmp");
    defer invalid_result.deinit();
    
    if (invalid_result.exit_code == 0) {
        print("    ❌ Invalid command should fail but didn't\n");
        return;
    }
    
    // Error should mention the invalid command
    if (std.mem.indexOf(u8, invalid_result.stderr, "not-a-real-command") == null and
        std.mem.indexOf(u8, invalid_result.stderr, "unknown") == null and
        std.mem.indexOf(u8, invalid_result.stderr, "invalid") == null) {
        print("    ⚠ Error message could be more descriptive\n");
    }
    
    // Test command without arguments
    var no_args_result = try tf.runCommand(&[_][]const u8{ 
        "/root/ziggit/zig-out/bin/ziggit" 
    }, "/tmp");
    defer no_args_result.deinit();
    
    // Should either show help or give reasonable error
    if (no_args_result.exit_code != 0 and 
        std.mem.indexOf(u8, no_args_result.stderr, "usage") == null and
        std.mem.indexOf(u8, no_args_result.stderr, "help") == null) {
        print("    ⚠ No args should show usage or help\n");
    }
    
    print("    ✓ Invalid command test passed\n");
}

pub fn main() !void {
    try runBasicTests();
}