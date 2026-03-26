// Status-specific optimization benchmark
// Focus: Measure impact of specific optimizations on statusPorcelain performance
const std = @import("std");
const Repository = @import("ziggit").Repository;

const ITERATIONS = 100;
const TEST_REPO_PATH = "/tmp/ziggit_status_bench";

const Stats = struct {
    min: u64,
    max: u64,
    mean: u64,
    median: u64,
    p95: u64,
    p99: u64,
    
    fn compute(times: []u64) Stats {
        std.mem.sort(u64, times, {}, std.sort.asc(u64));
        
        var sum: u128 = 0;
        for (times) |time| {
            sum += time;
        }
        
        const len = times.len;
        return Stats{
            .min = times[0],
            .max = times[len - 1],
            .mean = @intCast(sum / len),
            .median = times[len / 2],
            .p95 = times[@as(usize, @intFromFloat(@as(f64, @floatFromInt(len)) * 0.95))],
            .p99 = times[@as(usize, @intFromFloat(@as(f64, @floatFromInt(len)) * 0.99))],
        };
    }
};

fn setupLargeTestRepo(allocator: std.mem.Allocator, file_count: u32) !void {
    std.fs.deleteTreeAbsolute(TEST_REPO_PATH) catch {};
    std.fs.makeDirAbsolute(TEST_REPO_PATH) catch {};
    
    var repo = try Repository.init(allocator, TEST_REPO_PATH);
    defer repo.close();
    
    // Create many files to stress-test the status operation
    var i: u32 = 0;
    while (i < file_count) : (i += 1) {
        const filename = try std.fmt.allocPrint(allocator, "file{d}.txt", .{i});
        defer allocator.free(filename);
        
        const filepath = try std.fmt.allocPrint(allocator, "{s}/{s}", .{TEST_REPO_PATH, filename});
        defer allocator.free(filepath);
        
        const file = try std.fs.createFileAbsolute(filepath, .{ .truncate = true });
        defer file.close();
        
        const content = try std.fmt.allocPrint(allocator, "Content of file {d}\n", .{i});
        defer allocator.free(content);
        
        try file.writeAll(content);
        try repo.add(filename);
    }
    
    _ = try repo.commit("Initial commit with many files", "Bench User", "bench@example.com");
}

fn benchmarkStatusByFileCount(allocator: std.mem.Allocator) !void {
    const file_counts = [_]u32{ 10, 50, 100, 500 };
    
    std.debug.print("\n=== STATUS PERFORMANCE BY FILE COUNT ===\n", .{});
    
    for (file_counts) |file_count| {
        std.debug.print("\nBenchmarking with {d} files:\n", .{file_count});
        
        try setupLargeTestRepo(allocator, file_count);
        
        var repo = try Repository.open(allocator, TEST_REPO_PATH);
        defer repo.close();
        
        var times = try allocator.alloc(u64, ITERATIONS);
        defer allocator.free(times);
        
        // Benchmark statusPorcelain
        for (0..ITERATIONS) |i| {
            const start = std.time.nanoTimestamp();
            
            const status = try repo.statusPorcelain(allocator);
            defer allocator.free(status);
            
            const end = std.time.nanoTimestamp();
            times[i] = @intCast(end - start);
        }
        
        const stats = Stats.compute(times);
        const mean_us = @as(f64, @floatFromInt(stats.mean)) / 1000.0;
        const per_file_us = mean_us / @as(f64, @floatFromInt(file_count));
        
        std.debug.print("  Files: {d}, Mean: {d:.2}μs, Per-file: {d:.2}μs\n", .{ file_count, mean_us, per_file_us });
    }
}

fn benchmarkGitStatusByFileCount(allocator: std.mem.Allocator) !void {
    const file_counts = [_]u32{ 10, 50, 100, 500 };
    
    std.debug.print("\n=== GIT CLI STATUS BY FILE COUNT ===\n", .{});
    
    for (file_counts) |file_count| {
        try setupLargeTestRepo(allocator, file_count);
        
        var times = try allocator.alloc(u64, 25); // Fewer iterations for CLI
        defer allocator.free(times);
        
        for (0..25) |i| {
            const start = std.time.nanoTimestamp();
            
            var child = std.process.Child.init(&[_][]const u8{ "git", "status", "--porcelain" }, allocator);
            child.cwd = TEST_REPO_PATH;
            child.stdout_behavior = .Pipe;
            child.stderr_behavior = .Pipe;
            
            try child.spawn();
            
            const output = try child.stdout.?.readToEndAlloc(allocator, 100 * 1024);
            defer allocator.free(output);
            
            _ = try child.wait();
            
            const end = std.time.nanoTimestamp();
            times[i] = @intCast(end - start);
        }
        
        const stats = Stats.compute(times);
        const mean_us = @as(f64, @floatFromInt(stats.mean)) / 1000.0;
        const per_file_us = mean_us / @as(f64, @floatFromInt(file_count));
        
        std.debug.print("  Files: {d}, Mean: {d:.2}μs, Per-file: {d:.2}μs\n", .{ file_count, mean_us, per_file_us });
    }
}

fn benchmarkCleanVsDirtyStatus(allocator: std.mem.Allocator) !void {
    std.debug.print("\n=== CLEAN VS DIRTY STATUS COMPARISON ===\n", .{});
    
    try setupLargeTestRepo(allocator, 100);
    
    var repo = try Repository.open(allocator, TEST_REPO_PATH);
    defer repo.close();
    
    var times = try allocator.alloc(u64, ITERATIONS);
    defer allocator.free(times);
    
    // Benchmark clean status (all files unchanged)
    std.debug.print("\nClean repository (all files unchanged):\n", .{});
    for (0..ITERATIONS) |i| {
        const start = std.time.nanoTimestamp();
        
        const status = try repo.statusPorcelain(allocator);
        defer allocator.free(status);
        
        const end = std.time.nanoTimestamp();
        times[i] = @intCast(end - start);
    }
    
    const clean_stats = Stats.compute(times);
    const clean_mean = @as(f64, @floatFromInt(clean_stats.mean)) / 1000.0;
    std.debug.print("  Clean status mean: {d:.2}μs\n", .{clean_mean});
    
    // Modify some files to make repository dirty
    const dirty_files = [_][]const u8{ "file1.txt", "file5.txt", "file10.txt" };
    for (dirty_files) |filename| {
        const filepath = try std.fmt.allocPrint(allocator, "{s}/{s}", .{TEST_REPO_PATH, filename});
        defer allocator.free(filepath);
        
        const file = try std.fs.createFileAbsolute(filepath, .{ .truncate = true });
        defer file.close();
        
        try file.writeAll("MODIFIED CONTENT - This file has been changed\n");
    }
    
    // Benchmark dirty status (some files changed)
    std.debug.print("\nDirty repository (3 files modified):\n", .{});
    for (0..ITERATIONS) |i| {
        const start = std.time.nanoTimestamp();
        
        const status = try repo.statusPorcelain(allocator);
        defer allocator.free(status);
        
        const end = std.time.nanoTimestamp();
        times[i] = @intCast(end - start);
    }
    
    const dirty_stats = Stats.compute(times);
    const dirty_mean = @as(f64, @floatFromInt(dirty_stats.mean)) / 1000.0;
    std.debug.print("  Dirty status mean: {d:.2}μs\n", .{dirty_mean});
    
    const slowdown = dirty_mean / clean_mean;
    std.debug.print("  Dirty vs Clean ratio: {d:.2}x slower\n", .{slowdown});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.debug.print("=== STATUS OPTIMIZATION BENCHMARK ===\n", .{});
    std.debug.print("Analyzing statusPorcelain performance characteristics\n", .{});
    
    try benchmarkStatusByFileCount(allocator);
    try benchmarkGitStatusByFileCount(allocator);
    try benchmarkCleanVsDirtyStatus(allocator);
    
    std.debug.print("\n=== ANALYSIS ===\n", .{});
    std.debug.print("This benchmark helps identify:\n", .{});
    std.debug.print("1. How status performance scales with repository size\n", .{});
    std.debug.print("2. The efficiency of mtime/size fast path (clean vs dirty)\n", .{});
    std.debug.print("3. Ziggit's per-file overhead compared to git CLI\n", .{});
    
    std.fs.deleteTreeAbsolute(TEST_REPO_PATH) catch {};
    
    std.debug.print("\nStatus optimization benchmark completed!\n", .{});
}