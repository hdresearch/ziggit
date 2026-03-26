const std = @import("std");

pub fn main() !void {
    std.debug.print("Hello world\n", .{});
    std.debug.print("Test with format: {d}\n", .{42});
}