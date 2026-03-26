// PHASE 1: Simple benchmark to test API vs CLI performance
const std = @import("std");
const ziggit = @import("ziggit");

const ITERATIONS = 100; // Reduced for faster testing
const TEST_REPO_PATH = "/tmp/ziggit_simple_bench";

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

fn setupTestRepo(allocator: std.mem.Allocator) !void {
    std.debug.print("Setting up test repository...\n", .{});
    
    // Clean up
    std.fs.deleteTreeAbsolute(TEST_REPO_PATH) catch {};
    
    // Create repo with git CLI for simplicity
    var child = std.process.Child.init(&[_][]const u8{ "git", "init", TEST_REPO_PATH }, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    _ = try child.wait();
    
    // Create some files
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        const filename = try std.fmt.allocPrint(allocator, "{s}/file{d}.txt", .{TEST_REPO_PATH, i});
        defer allocator.free(filename);
        
        const file = try std.fs.createFileAbsolute(filename, .{ .truncate = true });
        defer file.close();
        
        const content = try std.fmt.allocPrint(allocator, "Content of file {d}\nLine 2\n", .{i});
        defer allocator.free(content);
        
        try file.writeAll(content);
    }
    
    // Configure git
    var config_name_child = std.process.Child.init(&[_][]const u8{ "git", "config", "user.name", "Test User" }, allocator);
    config_name_child.cwd = TEST_REPO_PATH;
    config_name_child.stdout_behavior = .Pipe;
    config_name_child.stderr_behavior = .Pipe;
    try config_name_child.spawn();
    _ = try config_name_child.wait();
    
    var config_email_child = std.process.Child.init(&[_][]const u8{ "git", "config", "user.email", "test@example.com" }, allocator);
    config_email_child.cwd = TEST_REPO_PATH;
    config_email_child.stdout_behavior = .Pipe;
    config_email_child.stderr_behavior = .Pipe;
    try config_email_child.spawn();
    _ = try config_email_child.wait();
    
    // Add and commit files with git CLI
    var add_child = std.process.Child.init(&[_][]const u8{ "git", "add", "." }, allocator);
    add_child.cwd = TEST_REPO_PATH;
    add_child.stdout_behavior = .Pipe;
    add_child.stderr_behavior = .Pipe;
    try add_child.spawn();
    _ = try add_child.wait();
    
    var commit_child = std.process.Child.init(&[_][]const u8{ "git", "commit", "-m", "Initial commit" }, allocator);
    commit_child.cwd = TEST_REPO_PATH;
    commit_child.stdout_behavior = .Pipe;
    commit_child.stderr_behavior = .Pipe;
    try commit_child.spawn();
    _ = try commit_child.wait();
    
    // Create a tag
    var tag_child = std.process.Child.init(&[_][]const u8{ "git", "tag", "v1.0" }, allocator);
    tag_child.cwd = TEST_REPO_PATH;
    tag_child.stdout_behavior = .Pipe;
    tag_child.stderr_behavior = .Pipe;
    try tag_child.spawn();
    _ = try tag_child.wait();
}

fn benchmarkZigAPI(allocator: std.mem.Allocator) !void {
    std.debug.print("\n=== ZIGGIT ZIG API BENCHMARK (Pure Zig) ===\n", .{});
    
    var repo = ziggit.Repository.open(allocator, TEST_REPO_PATH) catch |err| {
        std.debug.print("Failed to open repository with Zig API: {}\n", .{err});
        return;
    };
    defer repo.close();
    
    var times = try allocator.alloc(u64, ITERATIONS);
    defer allocator.free(times);
    
    // Benchmark 1: revParseHead
    std.debug.print("1. revParseHead (Pure Zig - NO subprocess)\n", .{});
    for (0..ITERATIONS) |i| {
        const start = std.time.nanoTimestamp();
        
        const head_hash = repo.revParseHead() catch |err| {
            std.debug.print("revParseHead failed: {}\n", .{err});
            return;
        };
        _ = head_hash; // Prevent optimization
        
        const end = std.time.nanoTimestamp();
        times[i] = @intCast(end - start);
    }
    
    const rev_parse_stats = Stats.compute(times);
    printStats("revParseHead (Zig)", rev_parse_stats);
    
    // Benchmark 2: statusPorcelain
    std.debug.print("2. statusPorcelain (Pure Zig - NO subprocess)\n", .{});
    for (0..ITERATIONS) |i| {
        const start = std.time.nanoTimestamp();
        
        const status = repo.statusPorcelain(allocator) catch |err| {
            std.debug.print("statusPorcelain failed: {}\n", .{err});
            return;
        };
        defer allocator.free(status);
        
        const end = std.time.nanoTimestamp();
        times[i] = @intCast(end - start);
    }
    
    const status_stats = Stats.compute(times);
    printStats("statusPorcelain (Zig)", status_stats);
    
    // Benchmark 3: describeTags
    std.debug.print("3. describeTags (Pure Zig - NO subprocess)\n", .{});
    for (0..ITERATIONS) |i| {
        const start = std.time.nanoTimestamp();
        
        const tag = repo.describeTags(allocator) catch |err| {
            std.debug.print("describeTags failed: {}\n", .{err});
            return;
        };
        defer allocator.free(tag);
        
        const end = std.time.nanoTimestamp();
        times[i] = @intCast(end - start);
    }
    
    const describe_stats = Stats.compute(times);
    printStats("describeTags (Zig)", describe_stats);
    
    // Benchmark 4: isClean
    std.debug.print("4. isClean (Pure Zig - NO subprocess)\n", .{});
    for (0..ITERATIONS) |i| {
        const start = std.time.nanoTimestamp();
        
        const clean = repo.isClean() catch |err| {
            std.debug.print("isClean failed: {}\n", .{err});
            return;
        };
        _ = clean; // Prevent optimization
        
        const end = std.time.nanoTimestamp();
        times[i] = @intCast(end - start);
    }
    
    const clean_stats = Stats.compute(times);
    printStats("isClean (Zig)", clean_stats);
}

fn benchmarkGitCLI(allocator: std.mem.Allocator) !void {
    std.debug.print("\n=== GIT CLI BENCHMARK (Process Spawning) ===\n", .{});
    
    var times = try allocator.alloc(u64, ITERATIONS);
    defer allocator.free(times);
    
    // Benchmark 1: git rev-parse HEAD
    std.debug.print("1. git rev-parse HEAD (subprocess spawn overhead)\n", .{});
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
    std.debug.print("2. git status --porcelain (subprocess spawn overhead)\n", .{});
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
    std.debug.print("3. git describe --tags --abbrev=0 (subprocess spawn overhead)\n", .{});
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
    
    // Benchmark 4: Check clean status
    std.debug.print("4. git status --porcelain check clean (subprocess spawn overhead)\n", .{});
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
    const median_us = @as(f64, @floatFromInt(stats.median)) / 1000.0;
    const mean_us = @as(f64, @floatFromInt(stats.mean)) / 1000.0;
    const p95_us = @as(f64, @floatFromInt(stats.p95)) / 1000.0;
    const p99_us = @as(f64, @floatFromInt(stats.p99)) / 1000.0;
    
    std.debug.print("{s}:\n", .{name});
    std.debug.print("  min:    {d:.2}μs\n", .{min_us});
    std.debug.print("  median: {d:.2}μs\n", .{median_us});
    std.debug.print("  mean:   {d:.2}μs\n", .{mean_us});
    std.debug.print("  p95:    {d:.2}μs\n", .{p95_us});
    std.debug.print("  p99:    {d:.2}μs\n", .{p99_us});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    try setupTestRepo(allocator);
    
    std.debug.print("Running {d} iterations of each benchmark...\n", .{ITERATIONS});
    
    // Benchmark pure Zig API calls (no process spawning)
    try benchmarkZigAPI(allocator);
    
    // Benchmark Git CLI calls (process spawning)
    try benchmarkGitCLI(allocator);
    
    std.debug.print("\n=== PERFORMANCE COMPARISON ===\n", .{});
    std.debug.print("Goal: Prove ziggit Zig functions are 100-1000x faster than git CLI spawning\n", .{});
    std.debug.print("Expected: Zig functions ~1-50μs, Git CLI ~2-5ms (process spawn overhead)\n", .{});
    
    // Cleanup
    std.fs.deleteTreeAbsolute(TEST_REPO_PATH) catch {};
    
    std.debug.print("\nPhase 1 benchmark completed!\n", .{});
}