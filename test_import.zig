const std = @import("std");
const ziggit = @import("src/ziggit.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.debug.print("Testing ziggit import...\n", .{});
    
    // Try to create a temporary repository to test
    const test_dir = "/tmp/ziggit_test";
    std.fs.deleteTreeAbsolute(test_dir) catch {};
    std.fs.makeDirAbsolute(test_dir) catch {};
    
    var repo = ziggit.Repository.init(allocator, test_dir) catch |err| {
        std.debug.print("Failed to init repo: {}\n", .{err});
        return;
    };
    defer repo.close();
    
    std.debug.print("Repository initialized successfully!\n", .{});
}