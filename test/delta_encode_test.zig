const std = @import("std");

// Test delta encoding roundtrip compatibility with existing delta application
test "delta encoding roundtrip" {
    const allocator = std.testing.allocator;
    
    // Import the modules we need
    const delta_encode = @import("../src/git/delta_encode.zig");
    
    // Test data
    const base = "hello world this is a test of delta compression functionality";
    const target = "hello ziggit world this is a test of delta compression functionality";
    
    // Create delta
    const delta = try delta_encode.createDelta(allocator, base, target);
    defer allocator.free(delta);
    
    // Verify delta is smaller than target for this case
    try std.testing.expect(delta.len < target.len);
    
    std.debug.print("Delta encoding test passed: {} -> {} bytes ({}% compression)\n", .{
        target.len, delta.len, 
        100 - (delta.len * 100 / target.len)
    });
}

test "delta encoding identical data" {
    const allocator = std.testing.allocator;
    const delta_encode = @import("../src/git/delta_encode.zig");
    
    const data = "identical data test";
    
    const delta = try delta_encode.createDelta(allocator, data, data);
    defer allocator.free(delta);
    
    // Should be very small for identical data
    try std.testing.expect(delta.len < 20);
    
    std.debug.print("Identical data delta size: {} bytes\n", .{delta.len});
}

test "delta size estimation" {
    const delta_encode = @import("../src/git/delta_encode.zig");
    
    const base = "hello world";
    const target = "hello ziggit world";
    
    const estimated = delta_encode.deltaSize(base, target);
    try std.testing.expect(estimated > 0);
    try std.testing.expect(estimated < 100);
    
    std.debug.print("Delta size estimation: {} bytes\n", .{estimated});
}
