const std = @import("std");
const ziggit = @import("ziggit");

const Benchmark = struct {
    name: []const u8,
    setup_fn: ?*const fn() anyerror!void = null,
    bench_fn: *const fn() anyerror!void,
    cleanup_fn: ?*const fn() anyerror!void = null,
};

const BenchmarkResult = struct {
    name: []const u8,
    iterations: u64,
    total_ns: u64,
    avg_ns: u64,
    ops_per_sec: u64,
};

pub fn runBenchmarks(allocator: std.mem.Allocator, benchmarks: []const Benchmark) ![]BenchmarkResult {
    var results = std.ArrayList(BenchmarkResult).init(allocator);
    defer results.deinit();
    
    for (benchmarks) |benchmark| {
        const writer = std.io.getStdOut().writer();
        try writer.print("Running benchmark: {s}...\n", .{benchmark.name});
        
        // Setup
        if (benchmark.setup_fn) |setup| {
            try setup();
        }
        defer {
            if (benchmark.cleanup_fn) |cleanup| {
                cleanup() catch {};
            }
        }
        
        // Warmup
        for (0..10) |_| {
            try benchmark.bench_fn();
        }
        
        // Actual benchmark
        const iterations: u64 = 1000;
        const start_time = std.time.nanoTimestamp();
        
        for (0..iterations) |_| {
            try benchmark.bench_fn();
        }
        
        const end_time = std.time.nanoTimestamp();
        const total_ns: u64 = @intCast(end_time - start_time);
        const avg_ns = total_ns / iterations;
        const ops_per_sec = std.time.ns_per_s / avg_ns;
        
        try results.append(BenchmarkResult{
            .name = benchmark.name,
            .iterations = iterations,
            .total_ns = total_ns,
            .avg_ns = avg_ns,
            .ops_per_sec = ops_per_sec,
        });
    }
    
    return results.toOwnedSlice();
}

var temp_repo_counter: u32 = 0;

var test_allocator = std.heap.GeneralPurposeAllocator(.{}){};

pub fn benchInitRepo() !void {
    temp_repo_counter += 1;
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/bench-repo-{d}", .{temp_repo_counter});
    try ziggit.repo_init(path, false);
}

pub fn benchOpenRepo() !void {
    const path = "/tmp/bench-repo-1";
    const repo = try ziggit.repo_open(test_allocator.allocator(), path);
    _ = repo; // Just test opening, no close needed for this simple struct
}

pub fn benchStatus() !void {
    const path = "/tmp/bench-repo-1"; 
    var repo = try ziggit.repo_open(test_allocator.allocator(), path);
    const status = try ziggit.repo_status(&repo, test_allocator.allocator());
    defer test_allocator.allocator().free(status);
}

pub fn cleanupBenchRepos() !void {
    // Clean up any temporary repositories
    for (1..temp_repo_counter + 1) |i| {
        var path_buf: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "/tmp/bench-repo-{d}", .{i});
        std.fs.deleteTreeAbsolute(path) catch {};
    }
}

pub fn setupBenchRepo() !void {
    try ziggit.repo_init("/tmp/bench-repo-1", false);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const benchmarks = [_]Benchmark{
        .{
            .name = "ziggit_repo_init",
            .bench_fn = benchInitRepo,
            .cleanup_fn = cleanupBenchRepos,
        },
        .{
            .name = "ziggit_repo_open",
            .setup_fn = setupBenchRepo,
            .bench_fn = benchOpenRepo,
            .cleanup_fn = cleanupBenchRepos,
        },
        .{
            .name = "ziggit_status",
            .setup_fn = setupBenchRepo,
            .bench_fn = benchStatus,
            .cleanup_fn = cleanupBenchRepos,
        },
    };
    
    const results = try runBenchmarks(allocator, &benchmarks);
    defer allocator.free(results);
    
    const writer = std.io.getStdOut().writer();
    try writer.print("\n=== Benchmark Results ===\n", .{});
    for (results) |result| {
        try writer.print("{s}:\n", .{result.name});
        try writer.print("  Iterations: {d}\n", .{result.iterations});
        try writer.print("  Avg time: {d} ns\n", .{result.avg_ns});
        try writer.print("  Ops/sec: {d}\n", .{result.ops_per_sec});
        try writer.print("\n", .{});
    }
}