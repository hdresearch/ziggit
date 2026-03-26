const std = @import("std");
const ziggit = @import("ziggit");

// Micro-benchmark for status optimizations - measure each component individually
const Statistics = struct {
    min: u64,
    median: u64,
    mean: u64,
    max: u64,
    
    fn calculate(times: []u64) Statistics {
        if (times.len == 0) return Statistics{ .min = 0, .median = 0, .mean = 0, .max = 0 };
        
        std.mem.sort(u64, times, {}, std.sort.asc(u64));
        
        const min = times[0];
        const max = times[times.len - 1];
        const median = times[times.len / 2];
        
        var total: u64 = 0;
        for (times) |time| total += time;
        const mean = total / times.len;
        
        return Statistics{ .min = min, .median = median, .mean = mean, .max = max };
    }
    
    fn print(self: Statistics, name: []const u8) void {
        std.debug.print("{s}: min={d}μs, median={d}μs, mean={d}μs, max={d}μs\n", .{
            name, self.min / 1000, self.median / 1000, self.mean / 1000, self.max / 1000
        });
    }
};

// Setup test repo quickly
fn setupQuickTestRepo(allocator: std.mem.Allocator, path: []const u8) !ziggit.Repository {
    std.fs.deleteTreeAbsolute(path) catch {};
    
    var repo = try ziggit.Repository.init(allocator, path);
    
    // Create just 10 files and 1 commit for faster benchmark setup
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const filename = try std.fmt.allocPrint(allocator, "file{d}.txt", .{i});
        defer allocator.free(filename);
        
        const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, filename });
        defer allocator.free(file_path);
        
        const content = try std.fmt.allocPrint(allocator, "Content {d}\n", .{i});
        defer allocator.free(content);
        
        const file = try std.fs.createFileAbsolute(file_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(content);
        
        try repo.add(filename);
    }
    
    _ = try repo.commit("Initial commit", "benchmark", "benchmark@example.com");
    return repo;
}

// Benchmark individual components of status operation
fn benchmarkStatusComponents(allocator: std.mem.Allocator, repo: *ziggit.Repository, iterations: usize) !void {
    std.debug.print("=== STATUS MICRO-BENCHMARK (breaking down bottlenecks) ===\n\n", .{});
    
    var times = try allocator.alloc(u64, iterations);
    defer allocator.free(times);
    
    // 1. Benchmark isClean first (should use ultra-fast path internally)
    {
        var success_count: usize = 0;
        for (0..iterations) |_| {
            const start = std.time.nanoTimestamp();
            _ = repo.isClean() catch continue;
            const end = std.time.nanoTimestamp();
            times[success_count] = @as(u64, @intCast(end - start));
            success_count += 1;
        }
        
        if (success_count > 0) {
            const stats = Statistics.calculate(times[0..success_count]);
            stats.print("isClean (should use ultra-fast path)");
        }
    }
    
    // 2. Benchmark rev-parse HEAD (should be ~5µs)
    {
        var success_count: usize = 0;
        for (0..iterations) |_| {
            const start = std.time.nanoTimestamp();
            _ = repo.revParseHead() catch continue;
            const end = std.time.nanoTimestamp();
            times[success_count] = @as(u64, @intCast(end - start));
            success_count += 1;
        }
        
        if (success_count > 0) {
            const stats = Statistics.calculate(times[0..success_count]);
            stats.print("rev-parse HEAD");
        }
    }
    
    // 3. Benchmark full status (current implementation)
    {
        var success_count: usize = 0;
        for (0..iterations) |_| {
            const start = std.time.nanoTimestamp();
            const status = repo.statusPorcelain(allocator) catch continue;
            const end = std.time.nanoTimestamp();
            times[success_count] = @as(u64, @intCast(end - start));
            success_count += 1;
            allocator.free(status);
        }
        
        if (success_count > 0) {
            const stats = Statistics.calculate(times[0..success_count]);
            stats.print("Full statusPorcelain");
        }
    }
    
    // 4. Benchmark describe --tags 
    {
        var success_count: usize = 0;
        for (0..iterations) |_| {
            const start = std.time.nanoTimestamp();
            const result = repo.describeTags(allocator) catch continue;
            const end = std.time.nanoTimestamp();
            times[success_count] = @as(u64, @intCast(end - start));
            success_count += 1;
            allocator.free(result);
        }
        
        if (success_count > 0) {
            const stats = Statistics.calculate(times[0..success_count]);
            stats.print("describeTags");
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const test_repo_path = "/tmp/ziggit_status_micro_bench";
    
    std.debug.print("Setting up test repository...\n", .{});
    var repo = try setupQuickTestRepo(allocator, test_repo_path);
    defer {
        repo.close();
        std.fs.deleteTreeAbsolute(test_repo_path) catch {};
    }
    
    const iterations = 2000;
    std.debug.print("Running {d} iterations of each component...\n\n", .{iterations});
    
    try benchmarkStatusComponents(allocator, &repo, iterations);
    
    std.debug.print("\n=== OPTIMIZATION TARGET ANALYSIS ===\n", .{});
    std.debug.print("• Ultra-fast clean check should be <1μs (just cache lookups)\n", .{});
    std.debug.print("• rev-parse HEAD should be ~5μs (2 file reads + cache)\n", .{});
    std.debug.print("• Full status should be <50μs for clean repos (fast path optimization)\n", .{});
    std.debug.print("• isClean should be <10μs (ultra-fast path + early termination)\n", .{});
    
    std.debug.print("\nBenchmark completed!\n", .{});
}