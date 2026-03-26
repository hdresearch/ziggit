const std = @import("std");
const ziggit = @import("ziggit");

// Benchmark specific optimization for status operations
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== STATUS OPTIMIZATION BENCHMARK ===\n\n", .{});

    const test_repo_path = "/tmp/ziggit_status_optimize_bench";
    std.fs.deleteTreeAbsolute(test_repo_path) catch {};
    
    // Create test repository 
    var repo = try ziggit.Repository.init(allocator, test_repo_path);
    defer {
        repo.close();
        std.fs.deleteTreeAbsolute(test_repo_path) catch {};
    }

    // Add files to create realistic repo
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const filename = try std.fmt.allocPrint(allocator, "file{d:03}.txt", .{i});
        defer allocator.free(filename);
        
        const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ test_repo_path, filename });
        defer allocator.free(file_path);
        
        const content = try std.fmt.allocPrint(allocator, "Content for file {d}\n", .{i});
        defer allocator.free(content);
        
        const file = try std.fs.createFileAbsolute(file_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(content);
        
        try repo.add(filename);
    }
    
    // Create commit so we have a clean working tree
    _ = try repo.commit("Initial commit", "benchmark", "benchmark@example.com");

    // Benchmark current status implementation
    const iterations = 2000;
    std.debug.print("Benchmarking statusPorcelain BEFORE optimization ({d} iterations)...\n", .{iterations});
    
    var times = try allocator.alloc(u64, iterations);
    defer allocator.free(times);
    
    var success_count: usize = 0;
    var j: usize = 0;
    while (j < iterations) : (j += 1) {
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

        std.debug.print("BEFORE optimization results:\n", .{});
        std.debug.print("  Min:    {d} μs\n", .{min / 1000});
        std.debug.print("  Median: {d} μs\n", .{median / 1000});
        std.debug.print("  Mean:   {d} μs\n", .{mean / 1000});
        std.debug.print("  Success rate: {d:.1}%\n", .{@as(f64, @floatFromInt(success_count)) / @as(f64, @floatFromInt(iterations)) * 100.0});
    }

    std.debug.print("\n=== OPTIMIZATION OPPORTUNITIES ===\n", .{});
    std.debug.print("1. Index caching: Avoid re-reading index on every call\n", .{});
    std.debug.print("2. Ultra-fast path: Skip file stats for provably clean repos\n", .{});
    std.debug.print("3. Memory optimization: Reduce heap allocations\n", .{});
    std.debug.print("4. Early termination: Return empty immediately if ultra-fast check succeeds\n", .{});
    
    std.debug.print("\nBenchmark completed!\n", .{});
}