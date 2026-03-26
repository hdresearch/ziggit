const std = @import("std");

const ZiggitRepo = opaque {};

// Import the C API functions as extern
extern fn ziggit_repo_open(path: [*:0]const u8) ?*ZiggitRepo;
extern fn ziggit_repo_close(repo: *ZiggitRepo) void;
extern fn ziggit_status_porcelain(repo: *ZiggitRepo, buffer: [*]u8, buffer_size: usize) c_int;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Test C API ziggit_status_porcelain function
    std.debug.print("Testing C API ziggit_status_porcelain in current directory...\n", .{});
    
    // Open repository using C API
    const repo_handle = ziggit_repo_open(".") orelse {
        std.debug.print("Current directory is not a git repository\n", .{});
        return;
    };
    defer ziggit_repo_close(repo_handle);
    
    // Test C API status function  
    var buffer: [4096]u8 = undefined;
    const result = ziggit_status_porcelain(repo_handle, &buffer, buffer.len);
    
    if (result != 0) {
        std.debug.print("ziggit_status_porcelain failed with error code: {}\n", .{result});
        return;
    }
    
    // Find actual length of the content (up to first null terminator)
    const actual_len = std.mem.indexOf(u8, &buffer, "\x00") orelse buffer.len;
    const c_api_status = buffer[0..actual_len];
    
    std.debug.print("C API status output:\n'{s}'\n", .{c_api_status});
    
    // Compare with git command
    const git_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "status", "--porcelain" },
    }) catch |err| {
        std.debug.print("Failed to run git command: {}\n", .{err});
        return;
    };
    defer allocator.free(git_result.stdout);
    defer allocator.free(git_result.stderr);
    
    std.debug.print("Git status output:\n'{s}'\n", .{git_result.stdout});
    
    if (std.mem.eql(u8, c_api_status, git_result.stdout)) {
        std.debug.print("✅ C API status outputs match!\n", .{});
    } else {
        std.debug.print("❌ C API status outputs differ!\n", .{});
        std.debug.print("C API: {d} bytes\n", .{c_api_status.len});
        std.debug.print("Git:   {d} bytes\n", .{git_result.stdout.len});
        
        // Debug each character
        for (c_api_status, 0..) |c, i| {
            std.debug.print("C[{}]: '{}' ({}) ", .{i, c, c});
        }
        std.debug.print("\n", .{});
        for (git_result.stdout, 0..) |c, i| {
            std.debug.print("G[{}]: '{}' ({}) ", .{i, c, c});
        }
        std.debug.print("\n", .{});
    }
}