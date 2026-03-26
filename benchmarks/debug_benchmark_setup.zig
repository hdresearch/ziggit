// Debug the exact benchmark setup to see where files get lost
const std = @import("std");
const Repository = @import("ziggit").Repository;

const TEST_REPO_PATH = "/tmp/ziggit_debug_bench_setup";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.debug.print("=== DEBUG BENCHMARK SETUP ===\n", .{});
    
    // Clean up any existing repo
    std.fs.deleteTreeAbsolute(TEST_REPO_PATH) catch {};
    
    // Create new repo
    std.fs.makeDirAbsolute(TEST_REPO_PATH) catch {};
    var repo = try Repository.init(allocator, TEST_REPO_PATH);
    defer repo.close();
    
    std.debug.print("Created repository\n", .{});
    
    // Create just 5 files to debug (smaller than 100)
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        const filename = try std.fmt.allocPrint(allocator, "file{d}.txt", .{i});
        defer allocator.free(filename);
        
        const filepath = try std.fmt.allocPrint(allocator, "{s}/{s}", .{TEST_REPO_PATH, filename});
        defer allocator.free(filepath);
        
        const file = try std.fs.createFileAbsolute(filepath, .{ .truncate = true });
        defer file.close();
        
        const content = try std.fmt.allocPrint(allocator, "Content of file {d}\nLine 2\nLine 3\n", .{i});
        defer allocator.free(content);
        
        try file.writeAll(content);
        
        std.debug.print("Created and adding file: {s}\n", .{filename});
        try repo.add(filename);
    }
    
    std.debug.print("All files added, checking status:\n", .{});
    const status_after_adds = try repo.statusPorcelain(allocator);
    defer allocator.free(status_after_adds);
    std.debug.print("Status after all adds:\n{s}\n", .{status_after_adds});
    
    // Create commits like in the benchmark
    var commit_num: u32 = 0;
    while (commit_num < 3) : (commit_num += 1) {
        const message = try std.fmt.allocPrint(allocator, "Commit {d} message", .{commit_num});
        defer allocator.free(message);
        
        std.debug.print("Creating commit {d}\n", .{commit_num});
        const commit_hash = try repo.commit(message, "Benchmark User", "bench@example.com");
        std.debug.print("Created commit: {s}\n", .{commit_hash});
        
        // Check status after each commit
        const status_after_commit = try repo.statusPorcelain(allocator);
        defer allocator.free(status_after_commit);
        std.debug.print("Status after commit {d}:\n{s}\n", .{commit_num, status_after_commit});
        
        if (commit_num % 2 == 0) {
            const tag_name = try std.fmt.allocPrint(allocator, "v1.{d}", .{commit_num});
            defer allocator.free(tag_name);
            
            const tag_message = try std.fmt.allocPrint(allocator, "Release v1.{d}", .{commit_num});
            defer allocator.free(tag_message);
            
            std.debug.print("Creating tag: {s}\n", .{tag_name});
            try repo.createTag(tag_name, tag_message);
        }
    }
    
    std.debug.print("Final status check:\n", .{});
    const final_status = try repo.statusPorcelain(allocator);
    defer allocator.free(final_status);
    std.debug.print("Final status:\n{s}\n", .{final_status});
    
    if (final_status.len == 0) {
        std.debug.print("Repository is clean - SUCCESS!\n", .{});
    } else {
        std.debug.print("Repository is NOT clean - there's an issue!\n", .{});
    }
    
    // Cleanup
    std.fs.deleteTreeAbsolute(TEST_REPO_PATH) catch {};
    
    std.debug.print("Debug completed successfully!\n", .{});
}