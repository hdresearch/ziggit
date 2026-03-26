// Simple analysis of statusPorcelain to identify bottlenecks
const std = @import("std");
const Repository = @import("ziggit").Repository;

const TEST_REPO_PATH = "/tmp/ziggit_bench_repo";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Set up test repo - exactly like the main benchmark
    try setupTestRepo(allocator);
    
    var repo = try Repository.open(allocator, TEST_REPO_PATH);
    defer repo.close();
    
    std.debug.print("=== SIMPLE STATUS ANALYSIS ===\n", .{});
    
    // Test 1: Single statusPorcelain call with timing
    const start = std.time.nanoTimestamp();
    const status = try repo.statusPorcelain(allocator);
    defer allocator.free(status);
    const end = std.time.nanoTimestamp();
    
    const duration_us = @as(f64, @floatFromInt(end - start)) / 1000.0;
    std.debug.print("Single statusPorcelain call: {d:.2}μs\n", .{duration_us});
    std.debug.print("Status output length: {} bytes\n", .{status.len});
    std.debug.print("Status output:\n{s}\n", .{status});
    
    // Test 2: Test if the repository is clean
    const clean = try repo.isClean();
    std.debug.print("Repository is clean: {}\n", .{clean});
    
    // Cleanup
    std.fs.deleteTreeAbsolute(TEST_REPO_PATH) catch {};
    
    std.debug.print("Analysis completed successfully!\n", .{});
}

// Same setup as the main benchmark
fn setupTestRepo(allocator: std.mem.Allocator) !void {
    // Clean up any existing repo
    std.fs.deleteTreeAbsolute(TEST_REPO_PATH) catch {};
    
    // Create new repo
    std.fs.makeDirAbsolute(TEST_REPO_PATH) catch {};
    var repo = try Repository.init(allocator, TEST_REPO_PATH);
    defer repo.close();
    
    // Create 100 files
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
    }
    
    // Create 10 commits with tags
    var commit_num: u32 = 0;
    while (commit_num < 10) : (commit_num += 1) {
        const message = try std.fmt.allocPrint(allocator, "Commit {d} message", .{commit_num});
        defer allocator.free(message);
        
        _ = try repo.commit(message, "Benchmark User", "bench@example.com");
        
        if (commit_num % 2 == 0) {
            const tag_name = try std.fmt.allocPrint(allocator, "v1.{d}", .{commit_num});
            defer allocator.free(tag_name);
            
            const tag_message = try std.fmt.allocPrint(allocator, "Release v1.{d}", .{commit_num});
            defer allocator.free(tag_message);
            
            try repo.createTag(tag_name, tag_message);
        }
    }
}