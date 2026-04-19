const std = @import("std");
const delta_encode = @import("../src/git/delta_encode.zig");
const objects = @import("../src/git/objects.zig");

test "createDelta roundtrip" {
    const allocator = std.testing.allocator;
    const base = "hello world this is a test";
    const target = "hello ziggit world this is a test";
    
    const delta = try delta_encode.createDelta(allocator, base, target);
    defer allocator.free(delta);
    
    // Apply the delta back to get the target
    const result = try objects.applyDelta(base, delta, allocator);
    defer allocator.free(result);
    
    try std.testing.expectEqualStrings(target, result);
}

test "createDelta identical data" {
    const allocator = std.testing.allocator;
    const data = "hello world";
    
    const delta = try delta_encode.createDelta(allocator, data, data);
    defer allocator.free(delta);
    
    // Should be small for identical data
    try std.testing.expect(delta.len < 50);
    
    // Apply delta should give back original
    const result = try objects.applyDelta(data, delta, allocator);
    defer allocator.free(result);
    
    try std.testing.expectEqualStrings(data, result);
}

test "deltaSize estimation" {
    const base = "hello world";
    const target = "hello ziggit world";
    
    const estimated = delta_encode.deltaSize(base, target);
    try std.testing.expect(estimated > 0);
    try std.testing.expect(estimated < 100);
}
