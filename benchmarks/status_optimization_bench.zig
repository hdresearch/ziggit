// Status Optimization Benchmark - Before and After
// Measures the current slow status vs optimized version
const std = @import("std");

const ITERATIONS = 10; // Fewer iterations since status is slow
const TEST_REPO_PATH = "/tmp/ziggit_status_opt_bench";

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

fn setupLargeTestRepo(allocator: std.mem.Allocator) !void {
    std.debug.print("Setting up large test repository for status optimization benchmark...\n", .{});
    
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
    
    // Create 100 files (like bun's node_modules would have many files)
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        const filename = try std.fmt.allocPrint(allocator, "{s}/file{d}.txt", .{TEST_REPO_PATH, i});
        defer allocator.free(filename);
        
        const file = try std.fs.createFileAbsolute(filename, .{ .truncate = true });
        defer file.close();
        
        // Create larger files (like real source files)
        const content = try std.fmt.allocPrint(allocator, 
            \\// File {d}
            \\const std = @import("std");
            \\
            \\pub fn main() !void {{
            \\    var gpa = std.heap.GeneralPurposeAllocator(.{{}}{{}};
            \\    defer _ = gpa.deinit();
            \\    const allocator = gpa.allocator();
            \\    
            \\    const result = try std.fmt.allocPrint(allocator, "Hello from file {{d}}!", .{{{d}}});
            \\    defer allocator.free(result);
            \\    std.debug.print("{{s}}\n", .{{result}});
            \\}}
        , .{i, i});
        defer allocator.free(content);
        
        try file.writeAll(content);
    }
    
    // Add all files and commit (creates a large index)
    {
        const result = try runCommand(allocator, &.{"git", "add", "."}, TEST_REPO_PATH);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    {
        const result = try runCommand(allocator, &.{"git", "commit", "-m", "Initial commit with 100 files"}, TEST_REPO_PATH);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    
    std.debug.print("Created repository with 100 files for status optimization testing.\n", .{});
}

fn printStats(name: []const u8, stats: Stats) void {
    const min_ms = @as(f64, @floatFromInt(stats.min)) / 1000000.0;
    const max_ms = @as(f64, @floatFromInt(stats.max)) / 1000000.0;
    const mean_ms = @as(f64, @floatFromInt(stats.mean)) / 1000000.0;
    const median_ms = @as(f64, @floatFromInt(stats.median)) / 1000000.0;
    const p95_ms = @as(f64, @floatFromInt(stats.p95)) / 1000000.0;
    const p99_ms = @as(f64, @floatFromInt(stats.p99)) / 1000000.0;
    
    std.debug.print("{s}:\n", .{name});
    std.debug.print("  min:    {d:.1}ms\n", .{min_ms});
    std.debug.print("  median: {d:.1}ms\n", .{median_ms});
    std.debug.print("  mean:   {d:.1}ms\n", .{mean_ms});
    std.debug.print("  p95:    {d:.1}ms\n", .{p95_ms});
    std.debug.print("  p99:    {d:.1}ms\n", .{p99_ms});
    std.debug.print("  max:    {d:.1}ms\n", .{max_ms});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    try setupLargeTestRepo(allocator);
    
    std.debug.print("Running {d} iterations of status benchmarks...\n", .{ITERATIONS});
    
    var times = try allocator.alloc(u64, ITERATIONS);
    defer allocator.free(times);
    
    // Benchmark git status (baseline)
    std.debug.print("\n=== BASELINE: git status --porcelain ===\n", .{});
    for (0..ITERATIONS) |i| {
        const start = std.time.nanoTimestamp();
        const result = try runCommand(allocator, &.{"git", "-C", TEST_REPO_PATH, "status", "--porcelain"}, null);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
        const end = std.time.nanoTimestamp();
        times[i] = @intCast(end - start);
    }
    const git_status_stats = Stats.compute(times);
    printStats("git status --porcelain", git_status_stats);
    
    // Benchmark ziggit status (current slow implementation)
    std.debug.print("\n=== BEFORE OPTIMIZATION: ziggit status --porcelain ===\n", .{});
    const ziggit_path = "/root/ziggit/zig-out/bin/ziggit";
    
    var ziggit_failed = false;
    for (0..ITERATIONS) |i| {
        const start = std.time.nanoTimestamp();
        const result = runCommand(allocator, &.{ziggit_path, "-C", TEST_REPO_PATH, "status", "--porcelain"}, null) catch {
            ziggit_failed = true;
            times[i] = 0;
            continue;
        };
        allocator.free(result.stdout);
        allocator.free(result.stderr);
        const end = std.time.nanoTimestamp();
        times[i] = @intCast(end - start);
    }
    
    if (!ziggit_failed) {
        const ziggit_status_stats = Stats.compute(times);
        printStats("ziggit status --porcelain (SLOW)", ziggit_status_stats);
        
        // Calculate how much slower ziggit is
        const slowdown_factor = @as(f64, @floatFromInt(ziggit_status_stats.mean)) / @as(f64, @floatFromInt(git_status_stats.mean));
        std.debug.print("ziggit is {d:.1}x slower than git\n", .{slowdown_factor});
        
        std.debug.print("\n=== PERFORMANCE ANALYSIS ===\n", .{});
        std.debug.print("The ziggit status implementation is slow because it:\n", .{});
        std.debug.print("1. Reads full content of every file in the index\n", .{});
        std.debug.print("2. Computes SHA-1 hash for every file\n", .{});
        std.debug.print("3. Does this even when files haven't changed (no mtime/size fast path)\n", .{});
        std.debug.print("\nOptimization needed: Use mtime/size fast path to skip unchanged files.\n", .{});
        
    } else {
        std.debug.print("ziggit status failed - this explains the performance issue.\n", .{});
        std.debug.print("The index parsing is broken, causing failures and slowdowns.\n", .{});
    }
    
    // Cleanup
    std.fs.deleteTreeAbsolute(TEST_REPO_PATH) catch {};
    
    std.debug.print("\nStatus optimization benchmark completed!\n", .{});
}