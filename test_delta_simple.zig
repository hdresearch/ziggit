const std = @import("std");
const delta_encode = @import("src/git/delta_encode.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const base = "hello world this is a test";
    const target = "hello ziggit world this is a test";
    
    std.debug.print("Base: {s}\n", .{base});
    std.debug.print("Target: {s}\n", .{target});
    
    const delta = try delta_encode.createDelta(allocator, base, target);
    defer allocator.free(delta);
    
    std.debug.print("Delta size: {} bytes\n", .{delta.len});
    std.debug.print("Original size: {} bytes\n", .{target.len});
    std.debug.print("Compression ratio: {d:.2}\n", .{@as(f64, @floatFromInt(delta.len)) / @as(f64, @floatFromInt(target.len))});
    
    std.debug.print("Delta created successfully!\n", .{});
}
