const std = @import("std");
const ziggit = @import("src/lib/ziggit.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Test against a simple git repo
    const repo_path = "/tmp/test_repo";
    
    // Create the test repo with git
    _ = try std.process.Child.exec(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "rm", "-rf", repo_path },
    });
    
    _ = try std.process.Child.exec(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "mkdir", "-p", repo_path },
    });
    
    // Change to repo directory and run git commands
    const old_cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(old_cwd);
    try std.process.changeCwd(repo_path);
    
    _ = try std.process.Child.exec(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "init" },
    });
    
    _ = try std.process.Child.exec(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "config", "user.email", "test@example.com" },
    });
    
    _ = try std.process.Child.exec(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "config", "user.name", "Test User" },
    });
    
    // Create a file and commit it
    const test_file = try std.fs.createFileAbsolute("/tmp/test_repo/test.txt", .{});
    try test_file.writeAll("Initial content\n");
    test_file.close();
    
    _ = try std.process.Child.exec(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "add", "test.txt" },
    });
    
    _ = try std.process.Child.exec(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "commit", "-m", "Initial commit" },
    });
    
    // Now modify the file
    const test_file2 = try std.fs.createFileAbsolute("/tmp/test_repo/test.txt", .{ .truncate = true });
    try test_file2.writeAll("Modified content\n");
    test_file2.close();
    
    // Get git status
    const git_result = try std.process.Child.exec(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "status", "--porcelain" },
    });
    defer allocator.free(git_result.stdout);
    defer allocator.free(git_result.stderr);
    
    std.log.info("Git status --porcelain output: '{s}'", .{git_result.stdout});
    
    // Reset back to original directory
    try std.process.changeCwd(old_cwd);
    
    // Test our library function
    var repo = try ziggit.repo_open(allocator, repo_path);
    const lib_status = try ziggit.repo_status(&repo, allocator);
    defer allocator.free(lib_status);
    
    std.log.info("Library status output: '{s}'", .{lib_status});
    
    if (std.mem.eql(u8, std.mem.trim(u8, git_result.stdout, " \n\r\t"), std.mem.trim(u8, lib_status, " \n\r\t"))) {
        std.log.info("✓ Outputs match!");
    } else {
        std.log.err("✗ Outputs differ!");
        std.log.err("Git: '{s}' (len={})", .{ std.mem.trim(u8, git_result.stdout, " \n\r\t"), std.mem.trim(u8, git_result.stdout, " \n\r\t").len });
        std.log.err("Lib: '{s}' (len={})", .{ std.mem.trim(u8, lib_status, " \n\r\t"), std.mem.trim(u8, lib_status, " \n\r\t").len });
    }
}