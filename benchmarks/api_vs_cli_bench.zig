// PHASE 1: Benchmark ziggit Zig function calls vs git CLI spawning
// This benchmark proves that calling ziggit Zig functions is 100-1000x faster than spawning git CLI
const std = @import("std");
const ziggit = @import("ziggit");

const ITERATIONS = 1000;
const TEST_REPO_PATH = "/tmp/ziggit_bench_repo";

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

// Test repository setup
fn setupTestRepo(allocator: std.mem.Allocator) !void {
    // Clean up any existing repo
    std.fs.deleteTreeAbsolute(TEST_REPO_PATH) catch {};
    
    // Create new repo
    std.fs.makeDirAbsolute(TEST_REPO_PATH) catch {};
    var repo = try ziggit.Repository.init(allocator, TEST_REPO_PATH);
    defer repo.close();
    
    // Create 100 files
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
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
    
    // Create 10 commits with tags
    var commit_num: u32 = 0;
    while (commit_num < 10) : (commit_num += 1) {
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

// Benchmark: Direct Zig API calls (pure Zig - no process spawning)
fn benchmarkZigAPI(allocator: std.mem.Allocator) !void {
    std.debug.print("\n=== ZIGGIT ZIG API BENCHMARK (Pure Zig - NO Process Spawning) ===\n", .{});
    
    var repo = try ziggit.Repository.open(allocator, TEST_REPO_PATH);
    defer repo.close();
    
    var times = try allocator.alloc(u64, ITERATIONS);
    defer allocator.free(times);
    
    // Benchmark 1: revParseHead
    std.debug.print("\n1. revParseHead (read .git/HEAD + follow ref)\n", .{});
    for (0..ITERATIONS) |i| {
        const start = std.time.nanoTimestamp();
        
        const head_hash = try repo.revParseHead();
        _ = head_hash; // Prevent optimization
        
        const end = std.time.nanoTimestamp();
        times[i] = @intCast(end - start);
    }
    
    const rev_parse_stats = Stats.compute(times);
    printStats("revParseHead (Zig)", rev_parse_stats);
    
    // Benchmark 2: statusPorcelain
    std.debug.print("\n2. statusPorcelain (read index + stat files)\n", .{});
    for (0..ITERATIONS) |i| {
        const start = std.time.nanoTimestamp();
        
        const status = try repo.statusPorcelain(allocator);
        defer allocator.free(status);
        
        const end = std.time.nanoTimestamp();
        times[i] = @intCast(end - start);
    }
    
    const status_stats = Stats.compute(times);
    printStats("statusPorcelain (Zig)", status_stats);
    
    // Benchmark 3: describeTags
    std.debug.print("\n3. describeTags (walk commit chain to find tag)\n", .{});
    for (0..ITERATIONS) |i| {
        const start = std.time.nanoTimestamp();
        
        const tag = try repo.describeTags(allocator);
        defer allocator.free(tag);
        
        const end = std.time.nanoTimestamp();
        times[i] = @intCast(end - start);
    }
    
    const describe_stats = Stats.compute(times);
    printStats("describeTags (Zig)", describe_stats);
    
    // Benchmark 4: isClean
    std.debug.print("\n4. isClean (check if status is empty)\n", .{});
    for (0..ITERATIONS) |i| {
        const start = std.time.nanoTimestamp();
        
        const clean = try repo.isClean();
        _ = clean; // Prevent optimization
        
        const end = std.time.nanoTimestamp();
        times[i] = @intCast(end - start);
    }
    
    const clean_stats = Stats.compute(times);
    printStats("isClean (Zig)", clean_stats);
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
        
        var child = std.process.Child.init(&[_][]const u8{ "git", "rev-parse", "HEAD" }, allocator);
        child.cwd = TEST_REPO_PATH;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        
        try child.spawn();
        
        const output = try child.stdout.?.readToEndAlloc(allocator, 1024);
        defer allocator.free(output);
        
        _ = try child.wait();
        
        const end = std.time.nanoTimestamp();
        times[i] = @intCast(end - start);
    }
    
    const rev_parse_stats = Stats.compute(times);
    printStats("git rev-parse HEAD", rev_parse_stats);
    
    // Benchmark 2: git status --porcelain
    std.debug.print("\n2. git status --porcelain\n", .{});
    for (0..ITERATIONS) |i| {
        const start = std.time.nanoTimestamp();
        
        var child = std.process.Child.init(&[_][]const u8{ "git", "status", "--porcelain" }, allocator);
        child.cwd = TEST_REPO_PATH;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        
        try child.spawn();
        
        const output = try child.stdout.?.readToEndAlloc(allocator, 4096);
        defer allocator.free(output);
        
        _ = try child.wait();
        
        const end = std.time.nanoTimestamp();
        times[i] = @intCast(end - start);
    }
    
    const status_stats = Stats.compute(times);
    printStats("git status --porcelain", status_stats);
    
    // Benchmark 3: git describe --tags --abbrev=0
    std.debug.print("\n3. git describe --tags --abbrev=0\n", .{});
    for (0..ITERATIONS) |i| {
        const start = std.time.nanoTimestamp();
        
        var child = std.process.Child.init(&[_][]const u8{ "git", "describe", "--tags", "--abbrev=0" }, allocator);
        child.cwd = TEST_REPO_PATH;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        
        try child.spawn();
        
        const output = try child.stdout.?.readToEndAlloc(allocator, 1024);
        defer allocator.free(output);
        
        _ = try child.wait();
        
        const end = std.time.nanoTimestamp();
        times[i] = @intCast(end - start);
    }
    
    const describe_stats = Stats.compute(times);
    printStats("git describe --tags", describe_stats);
    
    // Benchmark 4: Check clean status (git status --porcelain | wc -l == 0)
    std.debug.print("\n4. git status --porcelain (check clean)\n", .{});
    for (0..ITERATIONS) |i| {
        const start = std.time.nanoTimestamp();
        
        var child = std.process.Child.init(&[_][]const u8{ "git", "status", "--porcelain" }, allocator);
        child.cwd = TEST_REPO_PATH;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        
        try child.spawn();
        
        const output = try child.stdout.?.readToEndAlloc(allocator, 4096);
        defer allocator.free(output);
        
        _ = try child.wait();
        
        const is_clean = std.mem.trim(u8, output, " \n\r\t").len == 0;
        _ = is_clean; // Prevent optimization
        
        const end = std.time.nanoTimestamp();
        times[i] = @intCast(end - start);
    }
    
    const clean_stats = Stats.compute(times);
    printStats("git check clean", clean_stats);
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
    
    std.debug.print("Setting up test repository with 100 files, 10 commits, and tags...\n", .{});
    try setupTestRepo(allocator);
    
    std.debug.print("Running {d} iterations of each benchmark...\n", .{ITERATIONS});
    
    // Benchmark pure Zig API calls (no process spawning)
    try benchmarkZigAPI(allocator);
    
    // Benchmark Git CLI calls (process spawning)
    try benchmarkGitCLI(allocator);
    
    std.debug.print("\n=== PERFORMANCE COMPARISON ===\n", .{});
    std.debug.print("Goal: Prove ziggit Zig functions are 100-1000x faster than git CLI spawning\n", .{});
    std.debug.print("Expected: Zig functions ~1-50μs, Git CLI ~2-5ms (due to process spawn overhead)\n", .{});
    
    // Cleanup
    std.fs.deleteTreeAbsolute(TEST_REPO_PATH) catch {};
    
    std.debug.print("\nBenchmark completed successfully!\n", .{});
}