const std = @import("std");
const main_common = @import("main_common.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try main_common.zigzitMain(allocator);
}