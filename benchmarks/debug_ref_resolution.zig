const std = @import("std");
const ziggit = @import("ziggit");

const TEST_REPO_PATH = "/tmp/debug_repo";

fn setupRepo(allocator: std.mem.Allocator) !void {
    std.fs.deleteTreeAbsolute(TEST_REPO_PATH) catch {};
    
    // Create repo with git CLI
    var child = std.process.Child.init(&[_][]const u8{ "git", "init", TEST_REPO_PATH }, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    _ = try child.wait();
    
    // Create a file
    const filename = try std.fmt.allocPrint(allocator, "{s}/test.txt", .{TEST_REPO_PATH});
    defer allocator.free(filename);
    
    const file = try std.fs.createFileAbsolute(filename, .{ .truncate = true });
    defer file.close();
    try file.writeAll("test content\n");
    
    // Configure git
    var config_name_child = std.process.Child.init(&[_][]const u8{ "git", "config", "user.name", "Test User" }, allocator);
    config_name_child.cwd = TEST_REPO_PATH;
    config_name_child.stdout_behavior = .Pipe;
    config_name_child.stderr_behavior = .Pipe;
    try config_name_child.spawn();
    _ = try config_name_child.wait();
    
    var config_email_child = std.process.Child.init(&[_][]const u8{ "git", "config", "user.email", "test@example.com" }, allocator);
    config_email_child.cwd = TEST_REPO_PATH;
    config_email_child.stdout_behavior = .Pipe;
    config_email_child.stderr_behavior = .Pipe;
    try config_email_child.spawn();
    _ = try config_email_child.wait();
    
    // Add and commit
    var add_child = std.process.Child.init(&[_][]const u8{ "git", "add", "test.txt" }, allocator);
    add_child.cwd = TEST_REPO_PATH;
    add_child.stdout_behavior = .Pipe;
    add_child.stderr_behavior = .Pipe;
    try add_child.spawn();
    _ = try add_child.wait();
    
    var commit_child = std.process.Child.init(&[_][]const u8{ "git", "commit", "-m", "Initial commit" }, allocator);
    commit_child.cwd = TEST_REPO_PATH;
    commit_child.stdout_behavior = .Pipe;
    commit_child.stderr_behavior = .Pipe;
    try commit_child.spawn();
    const result = try commit_child.wait();
    std.debug.print("Commit exit code: {}\n", .{result.Exited});
    
    std.debug.print("Repository setup complete\n", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    try setupRepo(allocator);
    
    // Debug: Check .git structure
    std.debug.print("\n=== DEBUG: Repository Structure ===\n", .{});
    
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{TEST_REPO_PATH});
    defer allocator.free(git_dir);
    
    std.debug.print("Git dir: {s}\n", .{git_dir});
    
    // Check HEAD file
    const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_dir});
    defer allocator.free(head_path);
    
    const head_file = std.fs.openFileAbsolute(head_path, .{}) catch |err| {
        std.debug.print("Failed to open HEAD file: {}\n", .{err});
        return;
    };
    defer head_file.close();
    
    var head_content_buf: [256]u8 = undefined;
    const head_bytes = try head_file.readAll(&head_content_buf);
    const head_content = std.mem.trim(u8, head_content_buf[0..head_bytes], " \n\r\t");
    std.debug.print("HEAD content: '{s}'\n", .{head_content});
    
    if (std.mem.startsWith(u8, head_content, "ref: ")) {
        const ref_name = head_content[5..];
        std.debug.print("HEAD points to ref: '{s}'\n", .{ref_name});
        
        // Check if ref exists
        const ref_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{git_dir, ref_name});
        defer allocator.free(ref_path);
        
        std.debug.print("Looking for ref at: {s}\n", .{ref_path});
        
        const ref_file = std.fs.openFileAbsolute(ref_path, .{}) catch |err| {
            std.debug.print("Failed to open ref file: {}\n", .{err});
            return;
        };
        defer ref_file.close();
        
        var ref_content_buf: [256]u8 = undefined;
        const ref_bytes = try ref_file.readAll(&ref_content_buf);
        const ref_content = std.mem.trim(u8, ref_content_buf[0..ref_bytes], " \n\r\t");
        std.debug.print("Ref content: '{s}'\n", .{ref_content});
    }
    
    // Now try to open with ziggit
    std.debug.print("\n=== Opening with ziggit ===\n", .{});
    var repo = ziggit.Repository.open(allocator, TEST_REPO_PATH) catch |err| {
        std.debug.print("Failed to open repo with ziggit: {}\n", .{err});
        return;
    };
    defer repo.close();
    
    std.debug.print("Successfully opened repo with ziggit\n", .{});
    
    // Try revParseHead
    const head_hash = repo.revParseHead() catch |err| {
        std.debug.print("revParseHead failed: {}\n", .{err});
        return;
    };
    
    std.debug.print("revParseHead succeeded: {s}\n", .{head_hash});
    
    // Cleanup
    std.fs.deleteTreeAbsolute(TEST_REPO_PATH) catch {};
}