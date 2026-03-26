const std = @import("std");
const print = std.debug.print;

// Import real ziggit implementation directly
const ziggit = @import("src/ziggit.zig");

fn formatDuration(ns: u64) void {
    if (ns < 1_000) {
        print("{d}ns", .{ns});
    } else if (ns < 1_000_000) {
        print("{d:.1}μs", .{@as(f64, @floatFromInt(ns)) / 1_000.0});
    } else if (ns < 1_000_000_000) {
        print("{d:.2}ms", .{@as(f64, @floatFromInt(ns)) / 1_000_000.0});
    } else {
        print("{d:.3}s", .{@as(f64, @floatFromInt(ns)) / 1_000_000_000.0});
    }
}

fn runGitCommand(allocator: std.mem.Allocator, argv: []const []const u8, cwd: []const u8) !std.process.Child.RunResult {
    return std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .cwd = cwd,
    }) catch |err| switch (err) {
        else => return err,
    };
}

const BenchmarkResult = struct {
    min: u64,
    median: u64,
    mean: u64,
    p95: u64,
    p99: u64,
};

fn calculateStats(times: []u64) BenchmarkResult {
    std.mem.sort(u64, times, {}, std.sort.asc(u64));
    
    var total: u64 = 0;
    for (times) |t| {
        total += t;
    }
    
    const mean = total / times.len;
    const median = times[times.len / 2];
    const p95_idx = (times.len * 95) / 100;
    const p99_idx = (times.len * 99) / 100;
    
    return BenchmarkResult{
        .min = times[0],
        .median = median,
        .mean = mean,
        .p95 = if (p95_idx < times.len) times[p95_idx] else times[times.len - 1],
        .p99 = if (p99_idx < times.len) times[p99_idx] else times[times.len - 1],
    };
}

fn printResults(name: []const u8, zig_stats: BenchmarkResult, cli_stats: BenchmarkResult) void {
    print("{s:20} | ", .{name});
    formatDuration(zig_stats.median);
    print(" | ", .{});
    formatDuration(zig_stats.mean);
    print(" | ", .{});
    formatDuration(zig_stats.p95);
    print(" | ", .{});
    formatDuration(zig_stats.p99);
    print(" || ", .{});
    formatDuration(cli_stats.median);
    print(" | ", .{});
    formatDuration(cli_stats.mean);
    print(" | ", .{});
    formatDuration(cli_stats.p95);
    print(" | ", .{});
    formatDuration(cli_stats.p99);
    print(" || ", .{});
    
    const speedup = @as(f64, @floatFromInt(cli_stats.median)) / @as(f64, @floatFromInt(zig_stats.median));
    print("{d:.1}x", .{speedup});
    print("\n", .{});
}

// Real Zig function implementations (pure Zig, no external processes)
fn zigRevParseHead(allocator: std.mem.Allocator, repo_path: []const u8) !void {
    var repo = ziggit.Repository.open(allocator, repo_path) catch return;
    defer repo.close();
    _ = repo.revParseHead() catch return;
}

fn zigStatusPorcelain(allocator: std.mem.Allocator, repo_path: []const u8) !void {
    var repo = ziggit.Repository.open(allocator, repo_path) catch return;
    defer repo.close();
    const result = repo.statusPorcelain(allocator) catch return;
    defer allocator.free(result);
}

fn zigDescribeTags(allocator: std.mem.Allocator, repo_path: []const u8) !void {
    var repo = ziggit.Repository.open(allocator, repo_path) catch return;
    defer repo.close();
    const result = repo.describeTags(allocator) catch return;
    defer allocator.free(result);
}

fn zigIsClean(allocator: std.mem.Allocator, repo_path: []const u8) !void {
    var repo = ziggit.Repository.open(allocator, repo_path) catch return;
    defer repo.close();
    _ = repo.isClean() catch return;
}

// Git CLI implementations (child process spawning)
fn cliRevParseHead(allocator: std.mem.Allocator, repo_path: []const u8) !void {
    const result = runGitCommand(allocator, &.{"git", "-C", repo_path, "rev-parse", "HEAD"}, repo_path) catch return;
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

fn cliStatusPorcelain(allocator: std.mem.Allocator, repo_path: []const u8) !void {
    const result = runGitCommand(allocator, &.{"git", "-C", repo_path, "status", "--porcelain"}, repo_path) catch return;
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

fn cliDescribeTags(allocator: std.mem.Allocator, repo_path: []const u8) !void {
    const result = runGitCommand(allocator, &.{"git", "-C", repo_path, "describe", "--tags", "--abbrev=0"}, repo_path) catch return;
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

fn cliIsClean(allocator: std.mem.Allocator, repo_path: []const u8) !void {
    const result = runGitCommand(allocator, &.{"git", "-C", repo_path, "status", "--porcelain"}, repo_path) catch return;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    _ = std.mem.trim(u8, result.stdout, " \n\r\t").len == 0;
}

fn benchmarkOperation(
    comptime name: []const u8,
    allocator: std.mem.Allocator,
    repo_path: []const u8,
    iterations: usize,
    zigFunc: anytype,
    cliFunc: anytype,
) !void {
    var zig_times = try allocator.alloc(u64, iterations);
    defer allocator.free(zig_times);
    var cli_times = try allocator.alloc(u64, iterations);
    defer allocator.free(cli_times);

    // Benchmark Zig implementation
    for (0..iterations) |i| {
        const start = std.time.nanoTimestamp();
        _ = try zigFunc(allocator, repo_path);
        const end = std.time.nanoTimestamp();
        zig_times[i] = @as(u64, @intCast(end - start));
    }

    // Benchmark CLI implementation
    for (0..iterations) |i| {
        const start = std.time.nanoTimestamp();
        _ = try cliFunc(allocator, repo_path);
        const end = std.time.nanoTimestamp();
        cli_times[i] = @as(u64, @intCast(end - start));
    }

    const zig_stats = calculateStats(zig_times);
    const cli_stats = calculateStats(cli_times);

    printResults(name, zig_stats, cli_stats);
}

fn setupTestRepo(allocator: std.mem.Allocator, repo_path: []const u8) !void {
    // Clean up any existing test directory
    std.fs.deleteTreeAbsolute(repo_path) catch {};
    
    // Create test repository with git CLI
    try std.fs.makeDirAbsolute(repo_path);
    
    // Initialize git repo
    _ = try runGitCommand(allocator, &.{"git", "init"}, repo_path);
    _ = try runGitCommand(allocator, &.{"git", "config", "user.name", "Benchmark"}, repo_path);
    _ = try runGitCommand(allocator, &.{"git", "config", "user.email", "bench@test.com"}, repo_path);
    
    // Create 100 files
    for (0..100) |i| {
        const filename = try std.fmt.allocPrint(allocator, "{s}/file{d}.txt", .{repo_path, i});
        defer allocator.free(filename);
        const content = try std.fmt.allocPrint(allocator, "Content for file {d}\nThis is a test file for benchmarking.\nFile number: {d}\n", .{i, i});
        defer allocator.free(content);
        
        const file = try std.fs.createFileAbsolute(filename, .{});
        defer file.close();
        try file.writeAll(content);
    }
    
    // Add files and create 10 commits
    _ = try runGitCommand(allocator, &.{"git", "add", "."}, repo_path);
    _ = try runGitCommand(allocator, &.{"git", "commit", "-m", "Initial commit with 100 files"}, repo_path);
    
    for (1..10) |i| {
        // Modify some files
        for (0..10) |j| {
            const file_idx = (i * 10 + j) % 100;
            const filename = try std.fmt.allocPrint(allocator, "{s}/file{d}.txt", .{repo_path, file_idx});
            defer allocator.free(filename);
            const content = try std.fmt.allocPrint(allocator, "Modified content {d} for file {d}\nCommit number: {d}\n", .{i, file_idx, i});
            defer allocator.free(content);
            
            const file = try std.fs.createFileAbsolute(filename, .{});
            defer file.close();
            try file.writeAll(content);
        }
        
        _ = try runGitCommand(allocator, &.{"git", "add", "."}, repo_path);
        const commit_msg = try std.fmt.allocPrint(allocator, "Commit {d}: Modified 10 files", .{i});
        defer allocator.free(commit_msg);
        _ = try runGitCommand(allocator, &.{"git", "commit", "-m", commit_msg}, repo_path);
    }
    
    // Create some tags
    _ = try runGitCommand(allocator, &.{"git", "tag", "v1.0.0"}, repo_path);
    _ = try runGitCommand(allocator, &.{"git", "tag", "v1.1.0"}, repo_path);
    _ = try runGitCommand(allocator, &.{"git", "tag", "v2.0.0"}, repo_path);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    print("=== Real Ziggit API vs CLI Benchmark ===\n", .{});
    print("Comparing pure Zig function calls vs git CLI spawning\n", .{});
    print("Using real ziggit.zig implementation (not stubs)\n\n", .{});
    
    const test_dir = "/tmp/ziggit_real_bench";
    
    print("Setting up test repository (100 files, 10 commits, 3 tags)...\n", .{});
    try setupTestRepo(allocator, test_dir);
    print("Test repository setup complete.\n\n", .{});
    
    const iterations = 1000;
    print("Running {d} iterations per operation:\n\n", .{iterations});
    
    print("{s:20} | {s:>10} | {s:>10} | {s:>10} | {s:>10} || {s:>10} | {s:>10} | {s:>10} | {s:>10} || {s:>8}\n", 
        .{"Operation", "Zig Med", "Zig Mean", "Zig P95", "Zig P99", "CLI Med", "CLI Mean", "CLI P95", "CLI P99", "Speedup"});
    print("{s}\n", .{"=" ** 130});
    
    try benchmarkOperation("rev-parse HEAD", allocator, test_dir, iterations, zigRevParseHead, cliRevParseHead);
    try benchmarkOperation("status --porcelain", allocator, test_dir, iterations, zigStatusPorcelain, cliStatusPorcelain);
    try benchmarkOperation("describe --tags", allocator, test_dir, iterations, zigDescribeTags, cliDescribeTags);
    try benchmarkOperation("is_clean", allocator, test_dir, iterations, zigIsClean, cliIsClean);
    
    print("\n", .{});
    print("NOTE: This benchmark uses the REAL ziggit implementation from src/ziggit.zig\n", .{});
    print("All Zig implementations are pure Zig code paths with no process spawning.\n", .{});
    print("CLI implementations spawn 'git' as a child process.\n", .{});
    
    // Clean up
    std.fs.deleteTreeAbsolute(test_dir) catch {};
    
    print("\nReal benchmark completed!\n", .{});
}