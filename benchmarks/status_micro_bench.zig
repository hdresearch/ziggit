// Status operation micro-benchmark to identify bottlenecks
const std = @import("std");
const Repository = @import("ziggit").Repository;
const index_parser = @import("../src/lib/index_parser.zig");

const ITERATIONS = 1000;
const TEST_REPO_PATH = "/tmp/ziggit_status_micro_bench";

// Statistics collection
const Stats = struct {
    min: u64,
    max: u64,
    mean: u64,
    median: u64,
    
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
        };
    }
};

fn printStats(name: []const u8, stats: Stats) void {
    const min_us = @as(f64, @floatFromInt(stats.min)) / 1000.0;
    const mean_us = @as(f64, @floatFromInt(stats.mean)) / 1000.0;
    const median_us = @as(f64, @floatFromInt(stats.median)) / 1000.0;
    const max_us = @as(f64, @floatFromInt(stats.max)) / 1000.0;
    
    std.debug.print("{s}: min {d:.2}μs, median {d:.2}μs, mean {d:.2}μs, max {d:.2}μs\n", 
                    .{name, min_us, median_us, mean_us, max_us});
}

// Setup test repository - use same approach as the main benchmark
fn setupTestRepo(allocator: std.mem.Allocator) !void {
    std.fs.deleteTreeAbsolute(TEST_REPO_PATH) catch {};
    
    // Create new repo
    std.fs.makeDirAbsolute(TEST_REPO_PATH) catch {};
    var repo = try Repository.init(allocator, TEST_REPO_PATH);
    defer repo.close();
    
    // Create 20 files (smaller set for micro-testing)
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
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
    
    // Create commits with tags
    var commit_num: u32 = 0;
    while (commit_num < 3) : (commit_num += 1) {
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

// Benchmark individual components
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    try setupTestRepo(allocator);
    var repo = try Repository.open(allocator, TEST_REPO_PATH);
    defer repo.close();
    
    var times = try allocator.alloc(u64, ITERATIONS);
    defer allocator.free(times);
    
    std.debug.print("=== STATUS MICRO-BENCHMARK BREAKDOWN ===\n", .{});
    
    // 1. Benchmark reading index file
    const index_path = try std.fmt.allocPrint(allocator, "{s}/.git/index", .{TEST_REPO_PATH});
    defer allocator.free(index_path);
    
    for (0..ITERATIONS) |i| {
        const start = std.time.nanoTimestamp();
        
        var git_index = try index_parser.GitIndex.readFromFile(allocator, index_path);
        defer git_index.deinit();
        
        const end = std.time.nanoTimestamp();
        times[i] = @intCast(end - start);
    }
    
    const index_stats = Stats.compute(times);
    printStats("1. Read index file", index_stats);
    
    // 2. Benchmark building HashMap
    var git_index = try index_parser.GitIndex.readFromFile(allocator, index_path);
    defer git_index.deinit();
    
    for (0..ITERATIONS) |i| {
        const start = std.time.nanoTimestamp();
        
        var tracked_files = std.HashMap([]const u8, void, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator);
        defer tracked_files.deinit();
        
        for (git_index.entries.items) |entry| {
            try tracked_files.put(entry.path, {});
        }
        
        const end = std.time.nanoTimestamp();
        times[i] = @intCast(end - start);
    }
    
    const hashmap_stats = Stats.compute(times);
    printStats("2. Build HashMap (20 entries)", hashmap_stats);
    
    // 3. Benchmark file stat operations only
    for (0..ITERATIONS) |i| {
        const start = std.time.nanoTimestamp();
        
        for (git_index.entries.items) |entry| {
            var file_path_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
            const file_path = std.fmt.bufPrint(&file_path_buf, "{s}/{s}", .{ repo.path, entry.path }) catch continue;
            
            _ = std.fs.cwd().statFile(file_path) catch continue;
        }
        
        const end = std.time.nanoTimestamp();
        times[i] = @intCast(end - start);
    }
    
    const stat_stats = Stats.compute(times);
    printStats("3. Stat all files (20 files)", stat_stats);
    
    // 4. Benchmark full status (for comparison)
    for (0..ITERATIONS) |i| {
        const start = std.time.nanoTimestamp();
        
        const status = try repo.statusPorcelain(allocator);
        defer allocator.free(status);
        
        const end = std.time.nanoTimestamp();
        times[i] = @intCast(end - start);
    }
    
    const full_stats = Stats.compute(times);
    printStats("4. Full statusPorcelain", full_stats);
    
    // 5. Benchmark directory scanning for untracked files
    for (0..ITERATIONS) |i| {
        const start = std.time.nanoTimestamp();
        
        var dir = std.fs.cwd().openDir(repo.path, .{ .iterate = true }) catch continue;
        defer dir.close();
        
        var iterator = dir.iterate();
        while (try iterator.next()) |entry| {
            if (entry.kind != .file) continue;
            if (std.mem.startsWith(u8, entry.name, ".git")) continue;
        }
        
        const end = std.time.nanoTimestamp();
        times[i] = @intCast(end - start);
    }
    
    const scan_stats = Stats.compute(times);
    printStats("5. Directory scan (20 files)", scan_stats);
    
    std.debug.print("\n=== ANALYSIS ===\n", .{});
    std.debug.print("If Full status > sum of components, there's overhead to optimize\n", .{});
    
    const total_components = index_stats.median + hashmap_stats.median + stat_stats.median + scan_stats.median;
    const full_median = full_stats.median;
    
    const component_total_us = @as(f64, @floatFromInt(total_components)) / 1000.0;
    const full_us = @as(f64, @floatFromInt(full_median)) / 1000.0;
    
    std.debug.print("Sum of components: {d:.2}μs\n", .{component_total_us});
    std.debug.print("Full statusPorcelain: {d:.2}μs\n", .{full_us});
    
    if (full_median > total_components) {
        const overhead_us = @as(f64, @floatFromInt(full_median - total_components)) / 1000.0;
        std.debug.print("Overhead: {d:.2}μs - investigate memory allocations, string operations\n", .{overhead_us});
    }
    
    // Cleanup
    std.fs.deleteTreeAbsolute(TEST_REPO_PATH) catch {};
}