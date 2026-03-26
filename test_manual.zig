const std = @import("std");
const ziggit = @import("src/lib/ziggit.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Test in current directory if it's a git repo
    var repo = ziggit.repo_open(allocator, ".") catch {
        std.debug.print("Current directory is not a git repository\n", .{});
        return;
    };
    
    std.debug.print("Testing repository status...\n", .{});
    
    // Test the library status function
    const status = try ziggit.repo_status(&repo, allocator);
    defer allocator.free(status);
    
    std.debug.print("Library status output:\n'{s}'\n", .{status});
    
    // Compare with git command
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "status", "--porcelain" },
    }) catch |err| {
        std.debug.print("Failed to run git command: {}\n", .{err});
        return;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    
    std.debug.print("Git status output:\n'{s}'\n", .{result.stdout});
    
    if (std.mem.eql(u8, status, result.stdout)) {
        std.debug.print("✅ Status outputs match!\n", .{});
    } else {
        std.debug.print("❌ Status outputs differ!\n", .{});
        std.debug.print("Library: {d} bytes\n", .{status.len});
        std.debug.print("Git:     {d} bytes\n", .{result.stdout.len});
    }
}