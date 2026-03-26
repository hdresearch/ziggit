// Test with 100 files to see if it's a scale issue
const std = @import("std");
const Repository = @import("ziggit").Repository;

const TEST_REPO_PATH = "/tmp/ziggit_debug_scale";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.debug.print("=== DEBUG SCALE TEST (100 files) ===\n", .{});
    
    // Clean up any existing repo
    std.fs.deleteTreeAbsolute(TEST_REPO_PATH) catch {};
    
    // Create new repo
    std.fs.makeDirAbsolute(TEST_REPO_PATH) catch {};
    var repo = try Repository.init(allocator, TEST_REPO_PATH);
    defer repo.close();
    
    std.debug.print("Created repository, adding 100 files...\n", .{});
    
    // Create 100 files - exactly like the main benchmark
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        const filename = try std.fmt.allocPrint(allocator, "file{d}.txt", .{i});
        defer allocator.free(filename);
        
        const filepath = try std.fmt.allocPrint(allocator, "{s}/{s}", .{TEST_REPO_PATH, filename});
        defer allocator.free(filepath);
        
        const file = try std.fs.createFileAbsolute(filepath, .{ .truncate = true });
        defer file.close();
        
        const content = try std.fmt.allocPrint(allocator, "Content of file {d}\nLine 2\nLine 3\n", .{i});
        defer allocator.free(content);
        
        try file.writeAll(content);
        try repo.add(filename);
        
        if (i % 20 == 0) {
            std.debug.print("Added {} files so far...\n", .{i + 1});
        }
    }
    
    std.debug.print("All 100 files added, checking status:\n", .{});
    const status_after_adds = try repo.statusPorcelain(allocator);
    defer allocator.free(status_after_adds);
    std.debug.print("Status length after all adds: {} bytes\n", .{status_after_adds.len});
    if (status_after_adds.len > 0) {
        std.debug.print("First 200 chars of status:\n{s}...\n", .{status_after_adds[0..@min(200, status_after_adds.len)]});
    } else {
        std.debug.print("Status is empty (all files staged) - GOOD!\n", .{});
    }
    
    // Create just one commit initially
    std.debug.print("Creating initial commit...\n", .{});
    const commit_hash = try repo.commit("Initial commit with 100 files", "Benchmark User", "bench@example.com");
    std.debug.print("Created commit: {s}\n", .{commit_hash});
    
    // Check status after initial commit
    const status_after_commit = try repo.statusPorcelain(allocator);
    defer allocator.free(status_after_commit);
    std.debug.print("Status after initial commit - length: {} bytes\n", .{status_after_commit.len});
    
    if (status_after_commit.len == 0) {
        std.debug.print("Repository is clean after initial commit - SUCCESS!\n", .{});
    } else {
        std.debug.print("Repository is NOT clean after initial commit!\n", .{});
        std.debug.print("First 200 chars of status:\n{s}...\n", .{status_after_commit[0..@min(200, status_after_commit.len)]});
    }
    
    // Cleanup
    std.fs.deleteTreeAbsolute(TEST_REPO_PATH) catch {};
    
    std.debug.print("Debug completed!\n", .{});
}