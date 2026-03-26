const std = @import("std");
const ziggit = @import("ziggit");

// Benchmark configuration
const NUM_ITERATIONS = 10000; // Higher iteration count for micro-optimizations
const NUM_WARMUP = 1000;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Create test repository
    const test_repo_path = try setupOptimizedTestRepo(allocator);
    defer cleanupTestRepository(allocator, test_repo_path);
    
    std.debug.print("=== ZIGGIT OPTIMIZATION BENCHMARK ===\n", .{});
    std.debug.print("Iterations: {d}, Warmup: {d}\n", .{NUM_ITERATIONS, NUM_WARMUP});
    std.debug.print("Testing hot path optimizations...\n\n", .{});
    
    // Benchmark hot paths with repeated calls (simulates real usage)
    try benchmarkHotPaths(allocator, test_repo_path);
}

fn setupOptimizedTestRepo(allocator: std.mem.Allocator) ![]u8 {
    const test_dir = try allocator.dupe(u8, "/tmp/ziggit_opt_bench_repo");
    std.fs.deleteTreeAbsolute(test_dir) catch {};
    
    // Initialize git repository
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "init", test_dir },
    }) catch return error.GitInitFailed;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    
    if (result.term.Exited != 0) return error.GitInitFailed;
    
    // Change to test repository
    const old_cwd = std.process.getCwdAlloc(allocator) catch return error.GetCwdFailed;
    defer allocator.free(old_cwd);
    std.process.changeCurDir(test_dir) catch return error.ChangeCwdFailed;
    defer std.process.changeCurDir(old_cwd) catch {};
    
    // Configure git user
    _ = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "config", "user.email", "opt@ziggit.dev" },
    }) catch {};
    
    _ = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "config", "user.name", "Ziggit Optimizer" },
    }) catch {};
    
    // Create and commit a file (clean repo)
    const file = try std.fs.cwd().createFile("optimized.txt", .{});
    defer file.close();
    try file.writeAll("This is an optimized test file.\n");
    
    _ = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "add", "optimized.txt" },
    }) catch {};
    
    _ = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "commit", "-m", "Optimization test commit" },
    }) catch {};
    
    // Create a tag
    _ = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "tag", "v1.0.0" },
    }) catch {};
    
    return test_dir;
}

fn cleanupTestRepository(allocator: std.mem.Allocator, path: []const u8) void {
    std.fs.deleteTreeAbsolute(path) catch {};
    allocator.free(path);
}

fn benchmarkHotPaths(allocator: std.mem.Allocator, repo_path: []const u8) !void {
    // Test caching effectiveness
    try benchmarkRevParseHeadCaching(allocator, repo_path);
    try benchmarkStatusCaching(allocator, repo_path);
    try benchmarkDescribeTagsCaching(allocator, repo_path);
    try benchmarkIsCleanOptimization(allocator, repo_path);
}

fn benchmarkRevParseHeadCaching(allocator: std.mem.Allocator, repo_path: []const u8) !void {
    std.debug.print("=== Rev-Parse HEAD Caching Test ===\n", .{});
    
    // Open repository
    var repo = try ziggit.Repository.open(allocator, repo_path);
    defer repo.close();
    
    // Warmup
    var i: u32 = 0;
    while (i < NUM_WARMUP) : (i += 1) {
        _ = try repo.revParseHead();
    }
    
    // Benchmark: Repeated calls (should hit cache after first call)
    var total_time: u64 = 0;
    var first_call_time: u64 = 0;
    var cache_hit_time: u64 = 0;
    
    i = 0;
    while (i < NUM_ITERATIONS) : (i += 1) {
        const start = std.time.nanoTimestamp();
        _ = try repo.revParseHead();
        const end = std.time.nanoTimestamp();
        
        const call_time = @as(u64, @intCast(end - start));
        total_time += call_time;
        
        if (i == 0) {
            first_call_time = call_time;
        } else if (i == 1) {
            cache_hit_time = call_time;
        }
    }
    
    const avg_time = total_time / NUM_ITERATIONS;
    const first_call_us = @as(f64, @floatFromInt(first_call_time)) / 1000.0;
    const cache_hit_us = @as(f64, @floatFromInt(cache_hit_time)) / 1000.0;
    const avg_us = @as(f64, @floatFromInt(avg_time)) / 1000.0;
    
    std.debug.print("First call: {d:.1}us (cache miss)\n", .{first_call_us});
    std.debug.print("Second call: {d:.1}us (cache hit)\n", .{cache_hit_us});
    std.debug.print("Average: {d:.1}us\n", .{avg_us});
    
    if (cache_hit_time > 0 and first_call_time > cache_hit_time) {
        const speedup = @as(f64, @floatFromInt(first_call_time)) / @as(f64, @floatFromInt(cache_hit_time));
        std.debug.print("Cache speedup: {d:.1}x\n", .{speedup});
    }
    std.debug.print("\n", .{});
}

fn benchmarkStatusCaching(allocator: std.mem.Allocator, repo_path: []const u8) !void {
    std.debug.print("=== Status Porcelain Ultra-Fast Clean Check ===\n", .{});
    
    // Open repository
    var repo = try ziggit.Repository.open(allocator, repo_path);
    defer repo.close();
    
    // Warmup
    var i: u32 = 0;
    while (i < NUM_WARMUP) : (i += 1) {
        const status = try repo.statusPorcelain(allocator);
        allocator.free(status);
    }
    
    // Benchmark: Repeated status checks on clean repo (should hit ultra-fast path)
    var total_time: u64 = 0;
    var first_call_time: u64 = 0;
    var fast_path_time: u64 = 0;
    
    i = 0;
    while (i < NUM_ITERATIONS) : (i += 1) {
        const start = std.time.nanoTimestamp();
        const status = try repo.statusPorcelain(allocator);
        const end = std.time.nanoTimestamp();
        
        allocator.free(status);
        
        const call_time = @as(u64, @intCast(end - start));
        total_time += call_time;
        
        if (i == 0) {
            first_call_time = call_time;
        } else if (i == 1) {
            fast_path_time = call_time;
        }
    }
    
    const avg_time = total_time / NUM_ITERATIONS;
    const first_call_us = @as(f64, @floatFromInt(first_call_time)) / 1000.0;
    const fast_path_us = @as(f64, @floatFromInt(fast_path_time)) / 1000.0;
    const avg_us = @as(f64, @floatFromInt(avg_time)) / 1000.0;
    
    std.debug.print("First call: {d:.1}us (index parsing)\n", .{first_call_us});
    std.debug.print("Second call: {d:.1}us (ultra-fast clean check)\n", .{fast_path_us});
    std.debug.print("Average: {d:.1}us\n", .{avg_us});
    
    if (fast_path_time > 0 and first_call_time > fast_path_time) {
        const speedup = @as(f64, @floatFromInt(first_call_time)) / @as(f64, @floatFromInt(fast_path_time));
        std.debug.print("Ultra-fast speedup: {d:.1}x\n", .{speedup});
    }
    std.debug.print("\n", .{});
}

fn benchmarkDescribeTagsCaching(allocator: std.mem.Allocator, repo_path: []const u8) !void {
    std.debug.print("=== Describe Tags Caching Test ===\n", .{});
    
    // Open repository
    var repo = try ziggit.Repository.open(allocator, repo_path);
    defer repo.close();
    
    // Warmup
    var i: u32 = 0;
    while (i < NUM_WARMUP) : (i += 1) {
        const tag = try repo.describeTags(allocator);
        allocator.free(tag);
    }
    
    // Benchmark: Repeated describe calls (should hit cache after first call)
    var total_time: u64 = 0;
    var first_call_time: u64 = 0;
    var cache_hit_time: u64 = 0;
    
    i = 0;
    while (i < NUM_ITERATIONS) : (i += 1) {
        const start = std.time.nanoTimestamp();
        const tag = try repo.describeTags(allocator);
        const end = std.time.nanoTimestamp();
        
        allocator.free(tag);
        
        const call_time = @as(u64, @intCast(end - start));
        total_time += call_time;
        
        if (i == 0) {
            first_call_time = call_time;
        } else if (i == 1) {
            cache_hit_time = call_time;
        }
    }
    
    const avg_time = total_time / NUM_ITERATIONS;
    const first_call_us = @as(f64, @floatFromInt(first_call_time)) / 1000.0;
    const cache_hit_us = @as(f64, @floatFromInt(cache_hit_time)) / 1000.0;
    const avg_us = @as(f64, @floatFromInt(avg_time)) / 1000.0;
    
    std.debug.print("First call: {d:.1}us (directory scan)\n", .{first_call_us});
    std.debug.print("Second call: {d:.1}us (cache hit)\n", .{cache_hit_us});
    std.debug.print("Average: {d:.1}us\n", .{avg_us});
    
    if (cache_hit_time > 0 and first_call_time > cache_hit_time) {
        const speedup = @as(f64, @floatFromInt(first_call_time)) / @as(f64, @floatFromInt(cache_hit_time));
        std.debug.print("Cache speedup: {d:.1}x\n", .{speedup});
    }
    std.debug.print("\n", .{});
}

fn benchmarkIsCleanOptimization(allocator: std.mem.Allocator, repo_path: []const u8) !void {
    std.debug.print("=== Is Clean Optimization Test ===\n", .{});
    
    // Open repository
    var repo = try ziggit.Repository.open(allocator, repo_path);
    defer repo.close();
    
    // Warmup
    var i: u32 = 0;
    while (i < NUM_WARMUP) : (i += 1) {
        _ = try repo.isClean();
    }
    
    // Benchmark: Repeated isClean calls on clean repo (should hit ultra-fast path)
    var total_time: u64 = 0;
    var first_call_time: u64 = 0;
    var optimized_time: u64 = 0;
    
    i = 0;
    while (i < NUM_ITERATIONS) : (i += 1) {
        const start = std.time.nanoTimestamp();
        _ = try repo.isClean();
        const end = std.time.nanoTimestamp();
        
        const call_time = @as(u64, @intCast(end - start));
        total_time += call_time;
        
        if (i == 0) {
            first_call_time = call_time;
        } else if (i == 1) {
            optimized_time = call_time;
        }
    }
    
    const avg_time = total_time / NUM_ITERATIONS;
    const first_call_us = @as(f64, @floatFromInt(first_call_time)) / 1000.0;
    const optimized_us = @as(f64, @floatFromInt(optimized_time)) / 1000.0;
    const avg_us = @as(f64, @floatFromInt(avg_time)) / 1000.0;
    
    std.debug.print("First call: {d:.1}us (full check)\n", .{first_call_us});
    std.debug.print("Second call: {d:.1}us (ultra-fast cached check)\n", .{optimized_us});
    std.debug.print("Average: {d:.1}us\n", .{avg_us});
    
    if (optimized_time > 0 and first_call_time > optimized_time) {
        const speedup = @as(f64, @floatFromInt(first_call_time)) / @as(f64, @floatFromInt(optimized_time));
        std.debug.print("Optimization speedup: {d:.1}x\n", .{speedup});
    }
    std.debug.print("\n", .{});
}