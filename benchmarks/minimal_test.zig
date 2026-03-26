const std = @import("std");
const ziggit = @import("ziggit");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.debug.print("Testing basic ziggit import...\n", .{});
    
    // Try to create a simple repo
    const test_path = "/tmp/minimal_test_repo";
    std.fs.deleteTreeAbsolute(test_path) catch {};
    
    var repo = ziggit.Repository.init(allocator, test_path) catch |err| {
        std.debug.print("Failed to create repo: {any}\n", .{err});
        return;
    };
    defer repo.close();
    
    std.debug.print("Successfully created repository\n", .{});
    
    // Test revParseHead
    const head = repo.revParseHead() catch |err| {
        std.debug.print("revParseHead failed: {any}\n", .{err});
        return;
    };
    
    std.debug.print("HEAD: {s}\n", .{head});
    
    // Cleanup
    std.fs.deleteTreeAbsolute(test_path) catch {};
    std.debug.print("Test completed successfully!\n", .{});
}