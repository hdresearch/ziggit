const std = @import("std");
const print = std.debug.print;

fn runCommand(allocator: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8) !std.process.Child.RunResult {
    return try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .cwd = cwd,
    });
}

fn testGitIntegration() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    print("{s}\n", .{"=== Simple Git Integration Test ==="});
    
    const test_dir = "/tmp/ziggit_simple_test";
    
    // Clean up any existing test directory
    std.fs.deleteTreeAbsolute(test_dir) catch {};
    
    // Create test repository with real git
    try std.fs.makeDirAbsolute(test_dir);
    
    // Initialize git repo
    _ = try runCommand(allocator, &.{"git", "init"}, test_dir);
    _ = try runCommand(allocator, &.{"git", "config", "user.name", "Test"}, test_dir);
    _ = try runCommand(allocator, &.{"git", "config", "user.email", "test@test.com"}, test_dir);
    
    // Create and commit a file
    const test_file = try std.fmt.allocPrint(allocator, "{s}/test.txt", .{test_dir});
    defer allocator.free(test_file);
    
    const file = try std.fs.createFileAbsolute(test_file, .{});
    defer file.close();
    try file.writeAll("Hello, World!\n");
    
    _ = try runCommand(allocator, &.{"git", "add", "test.txt"}, test_dir);
    _ = try runCommand(allocator, &.{"git", "commit", "-m", "Initial commit"}, test_dir);
    
    // Create a tag
    _ = try runCommand(allocator, &.{"git", "tag", "v1.0.0"}, test_dir);
    
    print("{s}\n", .{"Git repository created successfully!"});
    
    // Test git commands
    const git_status_result = try runCommand(allocator, &.{"git", "-C", test_dir, "status", "--porcelain"}, null);
    defer allocator.free(git_status_result.stdout);
    defer allocator.free(git_status_result.stderr);
    
    const git_rev_result = try runCommand(allocator, &.{"git", "-C", test_dir, "rev-parse", "HEAD"}, null);
    defer allocator.free(git_rev_result.stdout);
    defer allocator.free(git_rev_result.stderr);
    
    const git_tag_result = try runCommand(allocator, &.{"git", "-C", test_dir, "describe", "--tags", "--abbrev=0"}, null);
    defer allocator.free(git_tag_result.stdout);
    defer allocator.free(git_tag_result.stderr);
    
    print("{s}: '{s}'\n", .{"Git status output", std.mem.trim(u8, git_status_result.stdout, " \n\r\t")});
    print("{s}: '{s}'\n", .{"Git rev-parse HEAD", std.mem.trim(u8, git_rev_result.stdout, " \n\r\t")});
    print("{s}: '{s}'\n", .{"Git describe tags", std.mem.trim(u8, git_tag_result.stdout, " \n\r\t")});
    
    // Test our Zig functions  
    // Import the ziggit functions
    const ziggit = @import("src/lib/ziggit.zig");
    const path_cstr = try std.fmt.allocPrintZ(allocator, "{s}", .{test_dir});
    defer allocator.free(path_cstr);
    
    const repo = ziggit.ziggit_repo_open(path_cstr.ptr);
    defer if (repo) |r| ziggit.ziggit_repo_close(r);
    
    if (repo) |r| {
        print("{s}\n", .{"Ziggit repo opened successfully!"});
        
        // Test status
        var status_buffer: [1024]u8 = undefined;
        const status_result = ziggit.ziggit_status_porcelain(r, &status_buffer, status_buffer.len);
        if (status_result == 0) {
            const status_str = std.mem.span(@as([*:0]u8, @ptrCast(&status_buffer)));
            print("{s}: '{s}'\n", .{"Ziggit status output", status_str});
        } else {
            print("{s}: {d}\n", .{"Ziggit status failed with error", status_result});
        }
        
        // Test rev-parse
        var rev_buffer: [64]u8 = undefined;
        const rev_result = ziggit.ziggit_rev_parse_head(r, &rev_buffer, rev_buffer.len);
        if (rev_result == 0) {
            const rev_str = std.mem.span(@as([*:0]u8, @ptrCast(&rev_buffer)));
            print("{s}: '{s}'\n", .{"Ziggit rev-parse HEAD", rev_str});
        } else {
            print("{s}: {d}\n", .{"Ziggit rev-parse failed with error", rev_result});
        }
        
        // Test describe tags
        var tag_buffer: [256]u8 = undefined;
        const tag_result = ziggit.ziggit_describe_tags(r, &tag_buffer, tag_buffer.len);
        if (tag_result == 0) {
            const tag_str = std.mem.span(@as([*:0]u8, @ptrCast(&tag_buffer)));
            print("{s}: '{s}'\n", .{"Ziggit describe tags", tag_str});
        } else {
            print("{s}: {d}\n", .{"Ziggit describe failed with error", tag_result});
        }
    } else {
        print("{s}\n", .{"Failed to open repository with ziggit!"});
    }
    
    // Clean up
    std.fs.deleteTreeAbsolute(test_dir) catch {};
    
    print("{s}\n", .{"Test completed!"});
}

pub fn main() !void {
    try testGitIntegration();
}