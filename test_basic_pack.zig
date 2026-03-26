const std = @import("std");
const objects = @import("src/git/objects.zig");

test "basic pack test" {
    const allocator = std.testing.allocator;
    
    // Test creating a simple blob object
    const blob = try objects.createBlobObject("hello world", allocator);
    defer blob.deinit(allocator);
    
    try std.testing.expectEqual(objects.ObjectType.blob, blob.type);
    try std.testing.expectEqualSlices(u8, "hello world", blob.data);
}