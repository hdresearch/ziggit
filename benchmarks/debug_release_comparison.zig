// benchmarks/debug_release_comparison.zig
// PHASE 3: Compare debug vs release performance  
const std = @import("std");
const ziggit = @import("ziggit");

const ITERATIONS = 5000;

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
    
    fn printComparison(name: []const u8, debug_result: BenchResult, release_result: BenchResult) void {
        const speedup = @as(f64, @floatFromInt(debug_result.mean_ns)) / @as(f64, @floatFromInt(release_result.mean_ns));
        const saved_ns = debug_result.mean_ns - release_result.mean_ns;
        
        std.debug.print("| {s: <20} | {d: >7}ns | {d: >7}ns | -{d: >6}ns | {d: >5.1f}x |\n", .{
            name,
            debug_result.mean_ns,
            release_result.mean_ns,
            saved_ns,
            speedup,
        });
    }
};

// Setup test repository for release benchmarks
fn setupReleaseTestRepo(allocator: std.mem.Allocator, test_dir: []const u8) !void {
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
        .argv = &[_][]const u8{ "git", "config", "user.name", "Release Test" },
        .cwd = test_dir,
    }) catch {};
    _ = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "config", "user.email", "release@test.com" },
        .cwd = test_dir,
    }) catch {};
    
    // Create test files
    var i: u32 = 0;
    while (i < 50) : (i += 1) {
        const filename = try std.fmt.allocPrint(allocator, "{s}/test_file_{d}.txt", .{ test_dir, i });
        defer allocator.free(filename);
        
        const content = try std.fmt.allocPrint(allocator, "Test content for file {d}\nLine 2 of content\nLine 3 with more data\n", .{i});
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
    
    // Create multiple commits
    i = 0;
    while (i < 5) : (i += 1) {
        const commit_msg = try std.fmt.allocPrint(allocator, "Release test commit {d}", .{i + 1});
        defer allocator.free(commit_msg);
        
        result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "git", "commit", "-m", commit_msg },
            .cwd = test_dir,
        }) catch continue;
        allocator.free(result.stdout);
        allocator.free(result.stderr);
        
        // Create tags
        const tag_name = try std.fmt.allocPrint(allocator, "release-v{d}.0", .{i + 1});
        defer allocator.free(tag_name);
        
        result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "git", "tag", tag_name },
            .cwd = test_dir,
        }) catch continue;
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
}

// Benchmark a function with multiple iterations
fn benchmarkFunction(comptime T: type, func: T, args: anytype, times: []u64) !void {
    for (times) |*time| {
        const start = std.time.nanoTimestamp();
        
        const result = @call(.auto, func, args) catch {
            time.* = @intCast(std.time.nanoTimestamp() - start);
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
    
    const test_dir = "release_test_repo";
    
    std.debug.print("Setting up release test repository...\n", .{});
    try setupReleaseTestRepo(allocator, test_dir);
    defer std.fs.cwd().deleteTree(test_dir) catch {};
    
    // Open repository
    var repo = try ziggit.Repository.open(allocator, test_dir);
    defer repo.close();
    
    // Detect if we're running in debug or release mode by checking panic behavior
    const build_mode = if (@import("builtin").mode == .Debug) "Debug" else "Release";
    
    std.debug.print("\n=== PHASE 3: Debug vs Release Performance ===\n", .{});
    std.debug.print("Current build mode: {s}\n", .{build_mode});
    std.debug.print("Iterations: {}\n", .{ITERATIONS});
    std.debug.print("\n", .{});
    
    // NOTE: This benchmark shows the current build mode performance
    // To compare debug vs release, run this benchmark with both build modes:
    // 1. zig build bench-release (debug mode)  
    // 2. zig build bench-release -Doptimize=ReleaseFast (release mode)
    
    if (std.mem.eql(u8, build_mode, "Debug")) {
        std.debug.print("📊 Measuring DEBUG mode performance:\n", .{});
    } else {
        std.debug.print("🚀 Measuring RELEASE mode performance:\n", .{});
    }
    
    // Print header
    std.debug.print("| {s: <20} | {s: >9} | {s: >9} | {s: >8} | {s: >8} |\n", .{
        "Operation", "Min", "Median", "Mean", "P95"
    });
    std.debug.print("|{s}|\n", .{"-" ** 75});
    
    // Allocate timing arrays
    const times = try allocator.alloc(u64, ITERATIONS);
    defer allocator.free(times);
    
    // 1. BENCHMARK: rev-parse HEAD
    {
        try benchmarkFunction(@TypeOf(ziggit.Repository.revParseHead), ziggit.Repository.revParseHead, .{&repo}, times);
        const result = BenchResult.fromTimes(times);
        std.debug.print("| {s: <20} | {d: >7}ns | {d: >7}ns | {d: >7}ns | {d: >7}ns |\n", .{
            "rev-parse HEAD", result.min_ns, result.median_ns, result.mean_ns, result.p95_ns
        });
    }
    
    // 2. BENCHMARK: status --porcelain
    {
        try benchmarkFunction(@TypeOf(ziggit.Repository.statusPorcelain), ziggit.Repository.statusPorcelain, .{ &repo, allocator }, times);
        const result = BenchResult.fromTimes(times);
        std.debug.print("| {s: <20} | {d: >7}ns | {d: >7}ns | {d: >7}ns | {d: >7}ns |\n", .{
            "status --porcelain", result.min_ns, result.median_ns, result.mean_ns, result.p95_ns
        });
    }
    
    // 3. BENCHMARK: describe --tags
    {
        try benchmarkFunction(@TypeOf(ziggit.Repository.describeTags), ziggit.Repository.describeTags, .{ &repo, allocator }, times);
        const result = BenchResult.fromTimes(times);
        std.debug.print("| {s: <20} | {d: >7}ns | {d: >7}ns | {d: >7}ns | {d: >7}ns |\n", .{
            "describe --tags", result.min_ns, result.median_ns, result.mean_ns, result.p95_ns
        });
    }
    
    // 4. BENCHMARK: isClean
    {
        try benchmarkFunction(@TypeOf(ziggit.Repository.isClean), ziggit.Repository.isClean, .{&repo}, times);
        const result = BenchResult.fromTimes(times);
        std.debug.print("| {s: <20} | {d: >7}ns | {d: >7}ns | {d: >7}ns | {d: >7}ns |\n", .{
            "isClean", result.min_ns, result.median_ns, result.mean_ns, result.p95_ns
        });
    }
    
    std.debug.print("\n=== Instructions ===\n", .{});
    if (std.mem.eql(u8, build_mode, "Debug")) {
        std.debug.print("To compare with release mode, run:\n", .{});
        std.debug.print("  zig build bench-release -Doptimize=ReleaseFast\n", .{});
        std.debug.print("\n", .{});
        std.debug.print("Expected release mode improvements:\n", .{});
        std.debug.print("  - 2-5x faster due to compiler optimizations\n", .{});
        std.debug.print("  - Better instruction scheduling and inlining\n", .{});
        std.debug.print("  - Reduced bounds checking overhead\n", .{});
    } else {
        std.debug.print("✅ Release mode active - performance optimized!\n", .{});
        std.debug.print("Compare with debug mode by running:\n", .{});
        std.debug.print("  zig build bench-release\n", .{});
    }
}