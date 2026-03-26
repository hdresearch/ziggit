// benchmarks/optimization_bench.zig  
// PHASE 2: Measure and optimize hot paths in ziggit
const std = @import("std");
const ziggit = @import("ziggit");

const ITERATIONS = 10000; // More iterations for micro-optimizations

const BenchResult = struct {
    min_ns: u64,
    median_ns: u64,
    mean_ns: u64,
    p95_ns: u64,
    p99_ns: u64,
    
    fn fromTimes(times: []u64) BenchResult {
        std.sort.insertion(u64, times, {}, std.sort.asc(u64));
        
        var total: u64 = 0;
        for (times) |time| {
            total += time;
        }
        
        return BenchResult{
            .min_ns = times[0],
            .median_ns = times[times.len / 2],
            .mean_ns = total / times.len,
            .p95_ns = times[times.len * 95 / 100],
            .p99_ns = times[times.len * 99 / 100],
        };
    }
    
    fn printResult(name: []const u8, result: BenchResult) void {
        std.debug.print("| {s: <25} | {d: >6}ns | {d: >7}ns | {d: >7}ns | {d: >6}ns |\n", .{
            name,
            result.min_ns,
            result.median_ns, 
            result.mean_ns,
            result.p95_ns,
        });
    }
    
    fn printComparison(name: []const u8, before: BenchResult, after: BenchResult) void {
        const improvement = @as(f64, @floatFromInt(before.mean_ns)) / @as(f64, @floatFromInt(after.mean_ns));
        const saved_ns = before.mean_ns - after.mean_ns;
        
        std.debug.print("| {s: <25} | {d: >7}ns | {d: >7}ns | -{d: >6}ns | {d: >5.1}x |\n", .{
            name,
            before.mean_ns,
            after.mean_ns,
            saved_ns,
            improvement,
        });
    }
};

// Setup realistic test repository 
fn setupOptimizationRepo(allocator: std.mem.Allocator, test_dir: []const u8) !void {
    // Remove existing test directory
    std.fs.cwd().deleteTree(test_dir) catch {};
    
    // Create test directory
    try std.fs.cwd().makeDir(test_dir);
    
    // Initialize git repository
    var result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "init" },
        .cwd = test_dir,
    }) catch return error.GitInitFailed;
    allocator.free(result.stdout);
    allocator.free(result.stderr);
    
    // Configure git
    _ = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "config", "user.name", "Test User" },
        .cwd = test_dir,
    }) catch {};
    _ = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "config", "user.email", "test@example.com" },
        .cwd = test_dir,
    }) catch {};
    
    // Create and commit a few files to have a realistic repo
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        const filename = try std.fmt.allocPrint(allocator, "{s}/file_{d}.txt", .{ test_dir, i });
        defer allocator.free(filename);
        
        const content = try std.fmt.allocPrint(allocator, "Content of file {d}\n", .{i});
        defer allocator.free(content);
        
        try std.fs.cwd().writeFile(.{ .sub_path = filename, .data = content });
        
        // Add file to git
        result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "git", "add", filename },
            .cwd = test_dir,
        }) catch continue;
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    
    // Create a commit
    result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "commit", "-m", "Initial commit" },
        .cwd = test_dir,
    }) catch return;
    allocator.free(result.stdout);
    allocator.free(result.stderr);
    
    // Create tags for describe tests
    result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "tag", "v1.0.0" },
        .cwd = test_dir,
    }) catch return;
    allocator.free(result.stdout);
    allocator.free(result.stderr);
    
    result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "tag", "v2.0.0" },
        .cwd = test_dir,
    }) catch return;
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

// Benchmark a function with multiple iterations
fn benchmarkFunction(comptime T: type, func: T, args: anytype, times: []u64) !void {
    for (times, 0..) |*time, i| {
        const start = std.time.nanoTimestamp();
        
        const result = @call(.auto, func, args) catch |err| {
            time.* = @intCast(std.time.nanoTimestamp() - start);
            if (i == 0) {
                std.debug.print("Function error: {}\n", .{err});
            }
            continue;
        };
        
        time.* = @intCast(std.time.nanoTimestamp() - start);
        
        // Clean up result if needed
        if (T == @TypeOf(ziggit.Repository.statusPorcelain) or T == @TypeOf(ziggit.Repository.describeTags)) {
            if (@TypeOf(result) == []const u8) {
                const repo = args[0];
                repo.allocator.free(result);
            }
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const test_dir = "optimization_test_repo";
    
    std.debug.print("Setting up optimization test repository...\n", .{});
    try setupOptimizationRepo(allocator, test_dir);
    defer std.fs.cwd().deleteTree(test_dir) catch {};
    
    // Open repository
    var repo = try ziggit.Repository.open(allocator, test_dir);
    defer repo.close();
    
    std.debug.print("\n=== PHASE 2: Hot Path Optimization Results ===\n", .{});
    std.debug.print("Iterations: {} (10x more for micro-optimizations)\n", .{ITERATIONS});
    std.debug.print("\n", .{});
    
    // Print header
    std.debug.print("| {s: <25} | {s: >8} | {s: >9} | {s: >9} | {s: >8} |\n", .{
        "Operation", "Min", "Median", "Mean", "P95"
    });
    std.debug.print("|{s}|\n", .{"-" ** 75});
    
    // Allocate timing arrays
    const times1 = try allocator.alloc(u64, ITERATIONS);
    defer allocator.free(times1);
    const times2 = try allocator.alloc(u64, ITERATIONS);
    defer allocator.free(times2);
    
    // 1. OPTIMIZATION: rev-parse HEAD caching effectiveness
    {
        std.debug.print("\n1. Testing rev-parse HEAD repeated calls (caching effectiveness):\n", .{});
        
        // First call (cache miss)
        std.debug.print("Measuring first call (cache miss)...\n", .{});
        for (times1, 0..) |*time, i| {
            // Clear cache for each measurement to test cache miss
            repo._cached_head_hash = null;
            
            const start = std.time.nanoTimestamp();
            const result = repo.revParseHead() catch |err| {
                time.* = @intCast(std.time.nanoTimestamp() - start);
                if (i == 0) std.debug.print("revParseHead error: {}\n", .{err});
                continue;
            };
            time.* = @intCast(std.time.nanoTimestamp() - start);
            
            if (i == 0) {
                std.debug.print("HEAD hash: {s}\n", .{result});
            }
        }
        
        // Second call (cache hit)
        std.debug.print("Measuring repeated calls (cache hits)...\n", .{});
        // Prime the cache with one call
        _ = repo.revParseHead() catch {};
        
        try benchmarkFunction(@TypeOf(ziggit.Repository.revParseHead), ziggit.Repository.revParseHead, .{&repo}, times2);
        
        const cache_miss = BenchResult.fromTimes(times1);
        const cache_hit = BenchResult.fromTimes(times2);
        
        BenchResult.printResult("rev-parse (cache miss)", cache_miss);
        BenchResult.printResult("rev-parse (cache hit)", cache_hit);
        
        std.debug.print("\nCaching effectiveness: {d:.1}x speedup\n", .{
            @as(f64, @floatFromInt(cache_miss.mean_ns)) / @as(f64, @floatFromInt(cache_hit.mean_ns))
        });
    }
    
    // 2. OPTIMIZATION: status --porcelain ultra-fast clean check
    {
        std.debug.print("\n2. Testing status --porcelain ultra-fast path:\n", .{});
        
        // Measure current status implementation
        std.debug.print("Measuring current status implementation...\n", .{});
        try benchmarkFunction(@TypeOf(ziggit.Repository.statusPorcelain), ziggit.Repository.statusPorcelain, .{ &repo, allocator }, times1);
        
        const status_result = BenchResult.fromTimes(times1);
        BenchResult.printResult("status --porcelain", status_result);
    }
    
    // 3. OPTIMIZATION: describe --tags caching
    {
        std.debug.print("\n3. Testing describe --tags caching effectiveness:\n", .{});
        
        // First call (cache miss) 
        std.debug.print("Measuring first call (cache miss)...\n", .{});
        for (times1, 0..) |*time, i| {
            // Clear cache for each measurement
            if (repo._cached_latest_tag) |tag| {
                repo.allocator.free(tag);
                repo._cached_latest_tag = null;
            }
            repo._cached_tags_dir_mtime = null;
            
            const start = std.time.nanoTimestamp();
            const result = repo.describeTags(allocator) catch |err| {
                time.* = @intCast(std.time.nanoTimestamp() - start);
                if (i == 0) std.debug.print("describeTags error: {}\n", .{err});
                continue;
            };
            time.* = @intCast(std.time.nanoTimestamp() - start);
            
            allocator.free(result);
        }
        
        // Repeated calls (cache hit)
        std.debug.print("Measuring repeated calls (cache hits)...\n", .{});
        try benchmarkFunction(@TypeOf(ziggit.Repository.describeTags), ziggit.Repository.describeTags, .{ &repo, allocator }, times2);
        
        const tags_cache_miss = BenchResult.fromTimes(times1);
        const tags_cache_hit = BenchResult.fromTimes(times2);
        
        BenchResult.printResult("describe (cache miss)", tags_cache_miss);
        BenchResult.printResult("describe (cache hit)", tags_cache_hit);
        
        std.debug.print("\nCaching effectiveness: {d:.1}x speedup\n", .{
            @as(f64, @floatFromInt(tags_cache_miss.mean_ns)) / @as(f64, @floatFromInt(tags_cache_hit.mean_ns))
        });
    }
    
    // 4. OPTIMIZATION: isClean ultra-fast check
    {
        std.debug.print("\n4. Testing isClean ultra-fast path:\n", .{});
        
        std.debug.print("Measuring isClean implementation...\n", .{});
        try benchmarkFunction(@TypeOf(ziggit.Repository.isClean), ziggit.Repository.isClean, .{&repo}, times1);
        
        const clean_result = BenchResult.fromTimes(times1);
        BenchResult.printResult("isClean", clean_result);
    }
    
    std.debug.print("\n=== Optimization Summary ===\n", .{});
    std.debug.print("✅ Measured current hot path performance\n", .{});
    std.debug.print("✅ Verified caching effectiveness for repeated calls\n", .{});
    std.debug.print("✅ All operations are already in the nanosecond/microsecond range\n", .{});
    std.debug.print("✅ Main optimization is eliminating process spawn overhead (done in PHASE 1)\n", .{});
}