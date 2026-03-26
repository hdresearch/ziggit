// micro_optimization_analysis.zig - Ultra-detailed performance analysis
// Identifies remaining micro-optimization opportunities in ziggit
const std = @import("std");
const ziggit = @import("src/ziggit.zig");

const MicroBenchmark = struct {
    name: []const u8,
    iterations: u32,
    total_time: u64,
    min_time: u64,
    max_time: u64,
    
    fn init(name: []const u8) MicroBenchmark {
        return MicroBenchmark{
            .name = name,
            .iterations = 0,
            .total_time = 0,
            .min_time = std.math.maxInt(u64),
            .max_time = 0,
        };
    }
    
    fn add_measurement(self: *MicroBenchmark, time: u64) void {
        self.total_time += time;
        self.iterations += 1;
        self.min_time = @min(self.min_time, time);
        self.max_time = @max(self.max_time, time);
    }
    
    fn average(self: *const MicroBenchmark) u64 {
        return if (self.iterations > 0) self.total_time / self.iterations else 0;
    }
    
    fn print_results(self: *const MicroBenchmark) void {
        const avg = self.average();
        std.debug.print("{s:25}: avg={d:5}ns  min={d:5}ns  max={d:5}ns  ({d} samples)\n", 
            .{ self.name, avg, self.min_time, self.max_time, self.iterations });
    }
};

// Micro-benchmark individual operations to identify bottlenecks
fn microbench_repo_open(allocator: std.mem.Allocator, repo_path: []const u8, iterations: u32) !void {
    var bench = MicroBenchmark.init("Repository.open");
    
    for (0..iterations) |_| {
        const start = std.time.nanoTimestamp();
        var repo = try ziggit.Repository.open(allocator, repo_path);
        const end = std.time.nanoTimestamp();
        repo.close();
        
        bench.add_measurement(@as(u64, @intCast(end - start)));
    }
    
    bench.print_results();
}

fn microbench_head_cached_vs_uncached(allocator: std.mem.Allocator, repo_path: []const u8) !void {
    var repo = try ziggit.Repository.open(allocator, repo_path);
    defer repo.close();
    
    // First call (uncached)
    const start1 = std.time.nanoTimestamp();
    const hash1 = try repo.revParseHead();
    const end1 = std.time.nanoTimestamp();
    
    // Second call (cached)  
    const start2 = std.time.nanoTimestamp();
    const hash2 = try repo.revParseHead();
    const end2 = std.time.nanoTimestamp();
    
    _ = hash1;
    _ = hash2;
    
    const uncached_time = @as(u64, @intCast(end1 - start1));
    const cached_time = @as(u64, @intCast(end2 - start2));
    
    std.debug.print("HEAD resolution cache effectiveness:\n");
    std.debug.print("  Uncached: {d}ns\n", .{uncached_time});
    std.debug.print("  Cached:   {d}ns  ({d:.1}x faster)\n", .{ cached_time, @as(f64, @floatFromInt(uncached_time)) / @as(f64, @floatFromInt(@max(cached_time, 1))) });
}

fn microbench_file_operations(repo_path: []const u8) !void {
    std.debug.print("\nMicro-benchmarking file system operations:\n");
    
    // Benchmark .git/HEAD read
    const head_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/.git/HEAD", .{repo_path});
    defer std.heap.page_allocator.free(head_path);
    
    var head_bench = MicroBenchmark.init("Read .git/HEAD");
    for (0..1000) |_| {
        const start = std.time.nanoTimestamp();
        const file = try std.fs.openFileAbsolute(head_path, .{});
        defer file.close();
        var buf: [64]u8 = undefined;
        _ = try file.readAll(&buf);
        const end = std.time.nanoTimestamp();
        
        head_bench.add_measurement(@as(u64, @intCast(end - start)));
    }
    head_bench.print_results();
    
    // Benchmark .git/index stat
    const index_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/.git/index", .{repo_path});
    defer std.heap.page_allocator.free(index_path);
    
    var index_stat_bench = MicroBenchmark.init("Stat .git/index");
    for (0..1000) |_| {
        const start = std.time.nanoTimestamp();
        _ = std.fs.cwd().statFile(index_path) catch continue;
        const end = std.time.nanoTimestamp();
        
        index_stat_bench.add_measurement(@as(u64, @intCast(end - start)));
    }
    index_stat_bench.print_results();
    
    // Benchmark refs/tags directory scan
    const tags_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/.git/refs/tags", .{repo_path});
    defer std.heap.page_allocator.free(tags_path);
    
    var tags_bench = MicroBenchmark.init("Scan refs/tags dir");
    for (0..1000) |_| {
        const start = std.time.nanoTimestamp();
        if (std.fs.openDirAbsolute(tags_path, .{ .iterate = true })) |mut_dir| {
            var dir = mut_dir;
            defer dir.close();
            var iter = dir.iterate();
            while (try iter.next()) |entry| {
                _ = entry;
            }
        } else |_| {}
        const end = std.time.nanoTimestamp();
        
        tags_bench.add_measurement(@as(u64, @intCast(end - start)));
    }
    tags_bench.print_results();
}

fn analyze_memory_allocation_patterns(allocator: std.mem.Allocator, repo_path: []const u8) !void {
    std.debug.print("\nMemory allocation analysis:\n");
    
    // Track allocations during a typical operation sequence
    const operations = [_][]const u8{ "open", "revParseHead", "status", "describeTags", "isClean", "close" };
    
    std.debug.print("Typical bun workflow memory usage:\n");
    for (operations) |op_name| {
        std.debug.print("  {s}...\n", .{op_name});
    }
    
    var repo = try ziggit.Repository.open(allocator, repo_path);
    defer repo.close();
    
    // Measure string allocations in status operation
    const status = try repo.statusPorcelain(allocator);
    defer allocator.free(status);
    std.debug.print("  Status output length: {d} bytes\n", .{status.len});
    
    const tag = try repo.describeTags(allocator);
    defer allocator.free(tag);
    std.debug.print("  Tag result length: {d} bytes\n", .{tag.len});
}

fn identify_hot_paths(allocator: std.mem.Allocator, repo_path: []const u8) !void {
    std.debug.print("\nHot path analysis (operations that would be called frequently by bun):\n");
    
    const iterations = 10000;
    
    // Simulate bun's likely call pattern: many status checks, fewer commits
    var total_time: u64 = 0;
    var operation_count: u32 = 0;
    
    for (0..iterations) |i| {
        var repo = try ziggit.Repository.open(allocator, repo_path);
        defer repo.close();
        
        const start = std.time.nanoTimestamp();
        
        // Typical bun operations in likely order of frequency:
        if (i % 2 == 0) {
            // Very frequent: quick clean check 
            _ = try repo.isClean();
            operation_count += 1;
        }
        
        if (i % 3 == 0) {
            // Frequent: HEAD resolution
            _ = try repo.revParseHead();
            operation_count += 1;
        }
        
        if (i % 10 == 0) {
            // Less frequent: full status
            const status = try repo.statusPorcelain(allocator);
            allocator.free(status);
            operation_count += 1;
        }
        
        if (i % 50 == 0) {
            // Rare: tag operations
            const tag = try repo.describeTags(allocator);
            allocator.free(tag);
            operation_count += 1;
        }
        
        const end = std.time.nanoTimestamp();
        total_time += @as(u64, @intCast(end - start));
    }
    
    const avg_time = total_time / operation_count;
    std.debug.print("Average time per mixed operation: {d}ns\n", .{avg_time});
    std.debug.print("Total operations performed: {d}\n", .{operation_count});
    std.debug.print("Simulated bun workflow efficiency: {d:.1} ops/ms\n", .{1_000_000.0 / @as(f64, @floatFromInt(avg_time))});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.debug.print("=== ZIGGIT MICRO-OPTIMIZATION ANALYSIS ===\n");
    std.debug.print("Identifying remaining performance optimization opportunities\n\n");
    
    // Use existing test repo if available
    const repo_path = "/tmp/ziggit_bench_test";
    
    // Quick test repo setup
    std.fs.deleteTreeAbsolute(repo_path) catch {};
    const init_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "init", repo_path },
    });
    defer allocator.free(init_result.stdout);
    defer allocator.free(init_result.stderr);
    
    // Create a few files for testing
    for (0..5) |i| {
        const filename = try std.fmt.allocPrint(allocator, "{s}/test_{d}.txt", .{ repo_path, i });
        defer allocator.free(filename);
        
        const file = try std.fs.createFileAbsolute(filename, .{});
        defer file.close();
        try file.writeAll("test");
    }
    
    const add_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "add", "." },
        .cwd = repo_path,
    });
    defer allocator.free(add_result.stdout);
    defer allocator.free(add_result.stderr);
    
    const commit_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "commit", "-m", "Test commit" },
        .cwd = repo_path,
    });
    defer allocator.free(commit_result.stdout);
    defer allocator.free(commit_result.stderr);
    
    const tag_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "tag", "v1.0" },
        .cwd = repo_path,
    });
    defer allocator.free(tag_result.stdout);
    defer allocator.free(tag_result.stderr);
    
    // Run micro-benchmarks
    try microbench_repo_open(allocator, repo_path, 1000);
    try microbench_head_cached_vs_uncached(allocator, repo_path);
    try microbench_file_operations(repo_path);
    try analyze_memory_allocation_patterns(allocator, repo_path);
    try identify_hot_paths(allocator, repo_path);
    
    std.debug.print("\n=== MICRO-OPTIMIZATION RECOMMENDATIONS ===\n");
    std.debug.print("1. Monitor repository opening overhead - consider connection pooling\n");
    std.debug.print("2. Verify caching is maximally effective for repeated calls\n");
    std.debug.print("3. Minimize allocations in hot paths (status, isClean)\n");
    std.debug.print("4. Consider async I/O for batch operations\n");
    std.debug.print("5. Profile mixed workloads to identify real-world bottlenecks\n");
    
    // Cleanup
    std.fs.deleteTreeAbsolute(repo_path) catch {};
}