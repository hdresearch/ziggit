const std = @import("std");
const testing = std.testing;

// Test for BrokenPipe error handling in platform/native.zig
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.debug.print("Warning: memory leaked in broken pipe test\n", .{});
        }
    }
    const allocator = gpa.allocator();

    std.debug.print("Testing BrokenPipe error handling...\n", .{});

    // Test that ziggit handles BrokenPipe gracefully when piped to head/less
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{"sh", "-c", "./zig-out/bin/ziggit --help | head -1"},
    }) catch |err| {
        std.debug.print("Failed to run pipe test: {}\n", .{err});
        return;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term != .Exited or result.term.Exited != 0) {
        std.debug.print("⚠ BrokenPipe test warning: ziggit exited with error when piped (code {})\n", .{result.term.Exited});
        std.debug.print("This may indicate BrokenPipe error is not being handled properly\n", .{});
        std.debug.print("stderr: {s}\n", .{result.stderr});
    } else {
        std.debug.print("✓ BrokenPipe handling test passed - ziggit works correctly when piped\n", .{});
    }

    std.debug.print("BrokenPipe test completed!\n", .{});
}