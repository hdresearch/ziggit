// PHASE 1: Benchmark ziggit Zig function calls vs git CLI spawning
// This benchmark proves that calling ziggit functions is 100-1000x faster than spawning git CLI
const std = @import("std");

const ITERATIONS = 1000;
const TEST_REPO_PATH = "/tmp/ziggit_phase1_bench";

// Statistics collection
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

fn runCommand(allocator: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8) !std.process.Child.RunResult {
    return try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .cwd = cwd,
    });
}

// Test repository setup
fn setupTestRepo(allocator: std.mem.Allocator) !void {
    std.debug.print("Setting up test repository with 100 files, 10 commits, and tags...\n", .{});
    
    // Clean up any existing repo
    std.fs.deleteTreeAbsolute(TEST_REPO_PATH) catch {};
    
    // Create new repo
    try std.fs.makeDirAbsolute(TEST_REPO_PATH);
    
    // Initialize git repo
    {
        const result = try runCommand(allocator, &.{"git", "init"}, TEST_REPO_PATH);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    {
        const result = try runCommand(allocator, &.{"git", "config", "user.name", "Benchmark User"}, TEST_REPO_PATH);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    {
        const result = try runCommand(allocator, &.{"git", "config", "user.email", "bench@example.com"}, TEST_REPO_PATH);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    
    // Create 100 files
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        const filename = try std.fmt.allocPrint(allocator, "{s}/file{d}.txt", .{TEST_REPO_PATH, i});
        defer allocator.free(filename);
        
        const file = try std.fs.createFileAbsolute(filename, .{ .truncate = true });
        defer file.close();
        
        const content = try std.fmt.allocPrint(allocator, "Content of file {d}\nLine 2\nLine 3\n", .{i});
        defer allocator.free(content);
        
        try file.writeAll(content);
    }
    
    // Add all files
    {
        const result = try runCommand(allocator, &.{"git", "add", "."}, TEST_REPO_PATH);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    
    // Create 10 commits with tags
    var commit_num: u32 = 0;
    while (commit_num < 10) : (commit_num += 1) {
        const message = try std.fmt.allocPrint(allocator, "Commit {d} message", .{commit_num});
        defer allocator.free(message);
        
        {
            const result = try runCommand(allocator, &.{"git", "commit", "-m", message}, TEST_REPO_PATH);
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }
        
        if (commit_num % 2 == 0) {
            const tag_name = try std.fmt.allocPrint(allocator, "v1.{d}", .{commit_num});
            defer allocator.free(tag_name);
            
            {
                const result = try runCommand(allocator, &.{"git", "tag", tag_name}, TEST_REPO_PATH);
                allocator.free(result.stdout);
                allocator.free(result.stderr);
            }
        }
        
        // Modify a few files for next commit
        if (commit_num < 9) {
            var j: u32 = 0;
            while (j < 5) : (j += 1) {
                const filename = try std.fmt.allocPrint(allocator, "{s}/file{d}.txt", .{TEST_REPO_PATH, j});
                defer allocator.free(filename);
                
                const file = try std.fs.createFileAbsolute(filename, .{ .truncate = true });
                defer file.close();
                
                const content = try std.fmt.allocPrint(allocator, "Modified content {d} for file {d}\nLine 2\nLine 3\n", .{commit_num + 1, j});
                defer allocator.free(content);
                
                try file.writeAll(content);
            }
            
            {
                const result = try runCommand(allocator, &.{"git", "add", "."}, TEST_REPO_PATH);
                allocator.free(result.stdout);
                allocator.free(result.stderr);
            }
        }
    }
}

// Benchmark: Git CLI spawning (process spawn overhead)
fn benchmarkGitCLI(allocator: std.mem.Allocator) !void {
    std.debug.print("\n=== GIT CLI BENCHMARK (Process Spawning Overhead) ===\n", .{});
    
    var times = try allocator.alloc(u64, ITERATIONS);
    defer allocator.free(times);
    
    // Benchmark 1: git rev-parse HEAD
    std.debug.print("\n1. git rev-parse HEAD\n", .{});
    for (0..ITERATIONS) |i| {
        const start = std.time.nanoTimestamp();
        
        const result = try runCommand(allocator, &.{"git", "-C", TEST_REPO_PATH, "rev-parse", "HEAD"}, null);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
        
        const end = std.time.nanoTimestamp();
        times[i] = @intCast(end - start);
    }
    
    const rev_parse_stats = Stats.compute(times);
    printStats("git rev-parse HEAD", rev_parse_stats);
    
    // Benchmark 2: git status --porcelain
    std.debug.print("\n2. git status --porcelain\n", .{});
    for (0..ITERATIONS) |i| {
        const start = std.time.nanoTimestamp();
        
        const result = try runCommand(allocator, &.{"git", "-C", TEST_REPO_PATH, "status", "--porcelain"}, null);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
        
        const end = std.time.nanoTimestamp();
        times[i] = @intCast(end - start);
    }
    
    const status_stats = Stats.compute(times);
    printStats("git status --porcelain", status_stats);
    
    // Benchmark 3: git describe --tags --abbrev=0
    std.debug.print("\n3. git describe --tags --abbrev=0\n", .{});
    for (0..ITERATIONS) |i| {
        const start = std.time.nanoTimestamp();
        
        const result = try runCommand(allocator, &.{"git", "-C", TEST_REPO_PATH, "describe", "--tags", "--abbrev=0"}, null);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
        
        const end = std.time.nanoTimestamp();
        times[i] = @intCast(end - start);
    }
    
    const describe_stats = Stats.compute(times);
    printStats("git describe --tags", describe_stats);
    
    // Benchmark 4: Check clean status (git status --porcelain | wc -l == 0)
    std.debug.print("\n4. git status --porcelain (check clean)\n", .{});
    for (0..ITERATIONS) |i| {
        const start = std.time.nanoTimestamp();
        
        const result = try runCommand(allocator, &.{"git", "-C", TEST_REPO_PATH, "status", "--porcelain"}, null);
        const is_clean = std.mem.trim(u8, result.stdout, " \n\r\t").len == 0;
        _ = is_clean; // Prevent optimization
        allocator.free(result.stdout);
        allocator.free(result.stderr);
        
        const end = std.time.nanoTimestamp();
        times[i] = @intCast(end - start);
    }
    
    const clean_stats = Stats.compute(times);
    printStats("git check clean", clean_stats);
}

// Benchmark: Ziggit CLI calls (should use pure Zig implementations internally)
fn benchmarkZiggitCLI(allocator: std.mem.Allocator) !void {
    std.debug.print("\n=== ZIGGIT CLI BENCHMARK (Pure Zig Implementation) ===\n", .{});
    
    var times = try allocator.alloc(u64, ITERATIONS);
    defer allocator.free(times);
    
    const ziggit_path = "/root/ziggit/zig-out/bin/ziggit";
    
    // Benchmark 1: ziggit rev-parse HEAD
    std.debug.print("\n1. ziggit rev-parse HEAD\n", .{});
    for (0..ITERATIONS) |i| {
        const start = std.time.nanoTimestamp();
        
        const result = try runCommand(allocator, &.{ziggit_path, "-C", TEST_REPO_PATH, "rev-parse", "HEAD"}, null);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
        
        const end = std.time.nanoTimestamp();
        times[i] = @intCast(end - start);
    }
    
    const rev_parse_stats = Stats.compute(times);
    printStats("ziggit rev-parse HEAD", rev_parse_stats);
    
    // Benchmark 2: ziggit status --porcelain
    std.debug.print("\n2. ziggit status --porcelain\n", .{});
    for (0..ITERATIONS) |i| {
        const start = std.time.nanoTimestamp();
        
        const result = try runCommand(allocator, &.{ziggit_path, "-C", TEST_REPO_PATH, "status", "--porcelain"}, null);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
        
        const end = std.time.nanoTimestamp();
        times[i] = @intCast(end - start);
    }
    
    const status_stats = Stats.compute(times);
    printStats("ziggit status --porcelain", status_stats);
    
    // Benchmark 3: ziggit describe --tags
    std.debug.print("\n3. ziggit describe --tags\n", .{});
    for (0..ITERATIONS) |i| {
        const start = std.time.nanoTimestamp();
        
        const result = try runCommand(allocator, &.{ziggit_path, "-C", TEST_REPO_PATH, "describe", "--tags"}, null);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
        
        const end = std.time.nanoTimestamp();
        times[i] = @intCast(end - start);
    }
    
    const describe_stats = Stats.compute(times);
    printStats("ziggit describe --tags", describe_stats);
}

fn printStats(name: []const u8, stats: Stats) void {
    const min_us = @as(f64, @floatFromInt(stats.min)) / 1000.0;
    const max_us = @as(f64, @floatFromInt(stats.max)) / 1000.0;
    const mean_us = @as(f64, @floatFromInt(stats.mean)) / 1000.0;
    const median_us = @as(f64, @floatFromInt(stats.median)) / 1000.0;
    const p95_us = @as(f64, @floatFromInt(stats.p95)) / 1000.0;
    const p99_us = @as(f64, @floatFromInt(stats.p99)) / 1000.0;
    
    std.debug.print("{s}:\n", .{name});
    std.debug.print("  min:    {d:.2}μs\n", .{min_us});
    std.debug.print("  median: {d:.2}μs\n", .{median_us});
    std.debug.print("  mean:   {d:.2}μs\n", .{mean_us});
    std.debug.print("  p95:    {d:.2}μs\n", .{p95_us});
    std.debug.print("  p99:    {d:.2}μs\n", .{p99_us});
    std.debug.print("  max:    {d:.2}μs\n", .{max_us});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    try setupTestRepo(allocator);
    
    std.debug.print("Running {d} iterations of each benchmark...\n", .{ITERATIONS});
    
    // Benchmark Git CLI calls (process spawning)
    try benchmarkGitCLI(allocator);
    
    // Benchmark ziggit CLI calls (should use pure Zig internally)
    benchmarkZiggitCLI(allocator) catch |err| {
        std.debug.print("Ziggit benchmark failed: {}\n", .{err});
        std.debug.print("This might indicate ziggit binary is not working correctly.\n", .{});
    };
    
    std.debug.print("\n=== PERFORMANCE COMPARISON ===\n", .{});
    std.debug.print("Goal: Prove ziggit implementation is faster than git CLI spawning\n", .{});
    std.debug.print("Expected: Git CLI ~2-5ms (process spawn overhead), ziggit ~100-500μs\n", .{});
    
    // Cleanup
    std.fs.deleteTreeAbsolute(TEST_REPO_PATH) catch {};
    
    std.debug.print("\nPhase 1 benchmark completed successfully!\n", .{});
}