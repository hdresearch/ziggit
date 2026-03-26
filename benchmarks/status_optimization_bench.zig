const std = @import("std");
const ziggit = @import("ziggit");

fn setupCleanRepo(allocator: std.mem.Allocator, path: []const u8) !ziggit.Repository {
    // Clean up any existing directory
    std.fs.deleteTreeAbsolute(path) catch {};
    
    // Initialize repository
    var repo = try ziggit.Repository.init(allocator, path);
    
    // Create 50 files and commit them (clean repo)
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const filename = try std.fmt.allocPrint(allocator, "file{d:03}.txt", .{i});
        defer allocator.free(filename);
        
        const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, filename });
        defer allocator.free(file_path);
        
        const content = try std.fmt.allocPrint(allocator, "Content for file {d}\n", .{i});
        defer allocator.free(content);
        
        const file = try std.fs.createFileAbsolute(file_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(content);
        
        try repo.add(filename);
    }
    
    _ = try repo.commit("Initial commit", "bench", "bench@example.com");
    
    return repo;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.debug.print("=== STATUS OPTIMIZATION BENCHMARK ===\n\n", .{});
    
    const test_repo_path = "/tmp/ziggit_status_optimization";
    var repo = try setupCleanRepo(allocator, test_repo_path);
    defer {
        repo.close();
        std.fs.deleteTreeAbsolute(test_repo_path) catch {};
    }
    
    const iterations = 1000;
    
    // Benchmark current statusPorcelain implementation
    std.debug.print("Benchmarking current statusPorcelain ({d} iterations)...\n", .{iterations});
    
    var times = try allocator.alloc(u64, iterations);
    defer allocator.free(times);
    
    var success_count: usize = 0;
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const start = std.time.nanoTimestamp();
        const status = repo.statusPorcelain(allocator) catch continue;
        const end = std.time.nanoTimestamp();
        
        // Should be empty for clean repo
        if (status.len == 0) {
            times[success_count] = @as(u64, @intCast(end - start));
            success_count += 1;
        }
        allocator.free(status);
    }
    
    if (success_count > 0) {
        std.mem.sort(u64, times[0..success_count], {}, std.sort.asc(u64));
        
        const min = times[0];
        const median = times[success_count / 2];
        var total: u64 = 0;
        for (times[0..success_count]) |time| {
            total += time;
        }
        const mean = total / success_count;
        
        std.debug.print("Results:\n", .{});
        std.debug.print("  Min:    {d} μs\n", .{min / 1000});
        std.debug.print("  Median: {d} μs\n", .{median / 1000});
        std.debug.print("  Mean:   {d} μs\n", .{mean / 1000});
        std.debug.print("  Success rate: {d:.1}%\n", .{(@as(f64, @floatFromInt(success_count)) / @as(f64, @floatFromInt(iterations))) * 100.0});
    } else {
        std.debug.print("All iterations failed!\n", .{});
    }
    
    // Benchmark isClean (which uses status internally)
    std.debug.print("\nBenchmarking current isClean ({d} iterations)...\n", .{iterations});
    
    success_count = 0;
    i = 0;
    while (i < iterations) : (i += 1) {
        const start = std.time.nanoTimestamp();
        const is_clean = repo.isClean() catch continue;
        const end = std.time.nanoTimestamp();
        
        if (is_clean) {
            times[success_count] = @as(u64, @intCast(end - start));
            success_count += 1;
        }
    }
    
    if (success_count > 0) {
        std.mem.sort(u64, times[0..success_count], {}, std.sort.asc(u64));
        
        const min = times[0];
        const median = times[success_count / 2];
        var total: u64 = 0;
        for (times[0..success_count]) |time| {
            total += time;
        }
        const mean = total / success_count;
        
        std.debug.print("Results:\n", .{});
        std.debug.print("  Min:    {d} μs\n", .{min / 1000});
        std.debug.print("  Median: {d} μs\n", .{median / 1000});
        std.debug.print("  Mean:   {d} μs\n", .{mean / 1000});
        std.debug.print("  Success rate: {d:.1}%\n", .{(@as(f64, @floatFromInt(success_count)) / @as(f64, @floatFromInt(iterations))) * 100.0});
    } else {
        std.debug.print("All iterations failed!\n", .{});
    }
    
    std.debug.print("\n=== OPTIMIZATION OPPORTUNITIES ===\n", .{});
    std.debug.print("1. Use FastGitIndex instead of regular GitIndex for index parsing\n", .{});
    std.debug.print("2. Cache index and file stats between calls\n", .{});
    std.debug.print("3. Improve ultra-fast clean check hit rate\n", .{});
    std.debug.print("4. Optimize directory iteration for untracked file detection\n", .{});
    
    std.debug.print("\nBenchmark completed!\n", .{});
}