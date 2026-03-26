const std = @import("std");
const ziggit = @import("ziggit");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    
    // Test if we can access the Repository struct and its methods
    std.debug.print("ziggit.Repository available: {any}\n", .{@TypeOf(ziggit.Repository)});
    
    // Test creating a temporary repo
    const test_dir = "/tmp/ziggit_api_test";
    std.fs.deleteDirAbsolute(test_dir) catch {};
    
    var repo = ziggit.Repository.init(allocator, test_dir) catch |err| {
        std.debug.print("Failed to init repo: {}\n", .{err});
        return;
    };
    defer repo.close();
    
    std.debug.print("✅ Successfully created repository using Zig API!\n", .{});
    std.debug.print("Path: {s}\n", .{repo.path});
    std.debug.print("Git dir: {s}\n", .{repo.git_dir});
    
    // Test some read operations
    const head = repo.revParseHead() catch |err| {
        std.debug.print("revParseHead() failed (expected for empty repo): {}\n", .{err});
        std.debug.print("✅ API method available and callable\n", .{});
        return;
    };
    
    std.debug.print("HEAD: {s}\n", .{head});
}