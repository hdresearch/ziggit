const std = @import("std");
const fs = std.fs;
const ChildProcess = std.process.Child;
const ziggit = @import("ziggit");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("Debug Status Test\n", .{});

    // Create test directory
    const test_dir = try fs.cwd().makeOpenPath("debug_status_test", .{});
    defer fs.cwd().deleteTree("debug_status_test") catch {};

    // Initialize repository and make a commit
    _ = try runCommand(allocator, &.{"git", "init"}, test_dir);
    _ = try runCommand(allocator, &.{"git", "config", "user.name", "Test User"}, test_dir);
    _ = try runCommand(allocator, &.{"git", "config", "user.email", "test@example.com"}, test_dir);

    try test_dir.writeFile(.{.sub_path = "test.txt", .data = "Hello World\n"});
    _ = try runCommand(allocator, &.{"git", "add", "test.txt"}, test_dir);
    _ = try runCommand(allocator, &.{"git", "commit", "-m", "Initial commit"}, test_dir);

    // Now check status
    const git_status = try runCommand(allocator, &.{"git", "status", "--porcelain"}, test_dir);
    defer allocator.free(git_status);
    
    // Get absolute path
    var path_buffer: [1024]u8 = undefined;
    const repo_path = try test_dir.realpath(".", &path_buffer);
    
    // Open repo with ziggit
    var repo = ziggit.repo_open(allocator, repo_path) catch |err| {
        std.debug.print("Failed to open repo: {}\n", .{err});
        return;
    };
    
    // Get HEAD commit
    const head_result = ziggit.repo_rev_parse_head(&repo, allocator) catch |err| {
        std.debug.print("Failed to get HEAD: {}\n", .{err});
        return;
    };
    defer allocator.free(head_result);
    
    const ziggit_status = ziggit.repo_status(&repo, allocator) catch |err| {
        std.debug.print("Failed to get status: {}\n", .{err});
        return;
    };
    defer allocator.free(ziggit_status);

    std.debug.print("Git status: '{s}'\n", .{std.mem.trim(u8, git_status, " \n\t\r")});
    std.debug.print("HEAD commit: '{s}'\n", .{std.mem.trim(u8, head_result, " \n\t\r")});
    std.debug.print("Ziggit status: '{s}'\n", .{std.mem.trim(u8, ziggit_status, " \n\t\r")});
}

fn runCommand(allocator: std.mem.Allocator, args: []const []const u8, cwd: fs.Dir) ![]u8 {
    var child = ChildProcess.init(args, allocator);
    child.cwd_dir = cwd;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    
    try child.spawn();
    
    const stdout = try child.stdout.?.reader().readAllAlloc(allocator, 8192);
    const stderr = try child.stderr.?.reader().readAllAlloc(allocator, 8192);
    defer allocator.free(stderr);
    
    const term = try child.wait();
    if (term != .Exited or term.Exited != 0) {
        std.debug.print("Command failed: {s}\n", .{stderr});
        allocator.free(stdout);
        return error.CommandFailed;
    }
    
    return stdout;
}