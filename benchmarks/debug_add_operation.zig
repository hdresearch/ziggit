// Debug the add operation to see why files aren't being tracked properly
const std = @import("std");
const Repository = @import("ziggit").Repository;

const TEST_REPO_PATH = "/tmp/ziggit_debug_add";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.debug.print("=== DEBUG ADD OPERATION ===\n", .{});
    
    // Clean up any existing repo
    std.fs.deleteTreeAbsolute(TEST_REPO_PATH) catch {};
    
    // Create new repo
    std.fs.makeDirAbsolute(TEST_REPO_PATH) catch {};
    var repo = try Repository.init(allocator, TEST_REPO_PATH);
    defer repo.close();
    
    std.debug.print("Created repository at: {s}\n", .{TEST_REPO_PATH});
    
    // Create just one file first
    const filename = "test.txt";
    const filepath = try std.fmt.allocPrint(allocator, "{s}/{s}", .{TEST_REPO_PATH, filename});
    defer allocator.free(filepath);
    
    const file = try std.fs.createFileAbsolute(filepath, .{ .truncate = true });
    defer file.close();
    
    const content = "Hello, World!\nThis is a test file.\n";
    try file.writeAll(content);
    
    std.debug.print("Created file: {s}\n", .{filename});
    
    // Check status before add
    const status_before = try repo.statusPorcelain(allocator);
    defer allocator.free(status_before);
    std.debug.print("Status before add:\n{s}\n", .{status_before});
    
    // Add the file
    std.debug.print("Adding file: {s}\n", .{filename});
    try repo.add(filename);
    std.debug.print("File added successfully\n", .{});
    
    // Check status after add
    const status_after = try repo.statusPorcelain(allocator);
    defer allocator.free(status_after);
    std.debug.print("Status after add:\n{s}\n", .{status_after});
    
    // Check if index file exists and its size
    const index_path = try std.fmt.allocPrint(allocator, "{s}/.git/index", .{TEST_REPO_PATH});
    defer allocator.free(index_path);
    
    if (std.fs.openFileAbsolute(index_path, .{})) |index_file| {
        defer index_file.close();
        const index_stat = try index_file.stat();
        std.debug.print("Index file exists, size: {} bytes\n", .{index_stat.size});
    } else |err| {
        std.debug.print("Index file error: {}\n", .{err});
    }
    
    // Try to commit
    const commit_hash = try repo.commit("Test commit", "Test User", "test@example.com");
    std.debug.print("Commit created: {s}\n", .{commit_hash});
    
    // Check status after commit
    const status_final = try repo.statusPorcelain(allocator);
    defer allocator.free(status_final);
    std.debug.print("Status after commit:\n{s}\n", .{status_final});
    if (status_final.len == 0) {
        std.debug.print("Repository is clean after commit - SUCCESS!\n", .{});
    }
    
    // Cleanup
    std.fs.deleteTreeAbsolute(TEST_REPO_PATH) catch {};
    
    std.debug.print("Debug completed successfully!\n", .{});
}