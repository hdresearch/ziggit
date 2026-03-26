const std = @import("std");
const ziggit = @import("ziggit");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.debug.print("Testing ziggit import...\n", .{});
    
    // Try to open a repository that doesn't exist to test the API
    const repo_result = ziggit.Repository.open(allocator, "non_existent_repo");
    if (repo_result) |repo| {
        repo.close();
        std.debug.print("Repository opened successfully\n", .{});
    } else |err| {
        std.debug.print("Expected error: {}\n", .{err});
    }
    
    std.debug.print("Test completed\n", .{});
}