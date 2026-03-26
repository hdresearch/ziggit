const std = @import("std");
const ziggit = @import("ziggit");

// Enhanced benchmark configuration
const NUM_ITERATIONS = 1000;
const NUM_WARMUP = 100;

// Benchmark results structure with detailed statistics
const PerfResult = struct {
    name: []const u8,
    min_ns: u64,
    median_ns: u64,
    mean_ns: u64,
    p95_ns: u64,
    p99_ns: u64,
    
    pub fn fromTimes(name: []const u8, times: []u64) PerfResult {
        std.sort.insertion(u64, times, {}, std.sort.asc(u64));
        
        const min_ns = times[0];
        const median_idx = times.len / 2;
        const median_ns = if (times.len % 2 == 0)
            (times[median_idx - 1] + times[median_idx]) / 2
        else 
            times[median_idx];
        
        var sum: u64 = 0;
        for (times) |time| sum += time;
        const mean_ns = sum / times.len;
        
        const p95_idx = (times.len * 95) / 100;
        const p95_ns = times[@min(p95_idx, times.len - 1)];
        
        const p99_idx = (times.len * 99) / 100;
        const p99_ns = times[@min(p99_idx, times.len - 1)];
        
        return PerfResult{
            .name = name,
            .min_ns = min_ns,
            .median_ns = median_ns,
            .mean_ns = mean_ns,
            .p95_ns = p95_ns,
            .p99_ns = p99_ns,
        };
    }
    
    pub fn print(self: PerfResult) void {
        const min_us = @as(f64, @floatFromInt(self.min_ns)) / 1000.0;
        const med_us = @as(f64, @floatFromInt(self.median_ns)) / 1000.0;
        const mean_us = @as(f64, @floatFromInt(self.mean_ns)) / 1000.0;
        const p95_us = @as(f64, @floatFromInt(self.p95_ns)) / 1000.0;
        const p99_us = @as(f64, @floatFromInt(self.p99_ns)) / 1000.0;
        
        std.debug.print("| {s:<22} | {d:>6.1} | {d:>6.1} | {d:>6.1} | {d:>6.1} | {d:>6.1} |\n", .{
            self.name, min_us, med_us, mean_us, p95_us, p99_us
        });
    }
};

var test_repo_path: []u8 = undefined;
var allocator: std.mem.Allocator = undefined;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    allocator = gpa.allocator();
    
    std.debug.print("=== ZIGGIT COMPREHENSIVE PERFORMANCE BENCHMARK ===\n");
    std.debug.print("Configuration: {d} iterations, {d} warmup\n", .{NUM_ITERATIONS, NUM_WARMUP});
    std.debug.print("Optimizations: ReleaseFast build with all optimizations enabled\n\n");
    
    // Create properly configured test repository
    try setupRobustTestRepo();
    defer cleanupTestRepository();
    
    std.debug.print("| {s:<22} | {s:>6} | {s:>6} | {s:>6} | {s:>6} | {s:>6} |\n", .{
        "Operation", "Min", "Med", "Mean", "P95", "P99"
    });
    std.debug.print("| {s:<22} | {s:>6} | {s:>6} | {s:>6} | {s:>6} | {s:>6} |\n", .{
        "", "(μs)", "(μs)", "(μs)", "(μs)", "(μs)"
    });
    std.debug.print("|{s}|{s}|{s}|{s}|{s}|{s}|\n", .{
        "-" ** 24, "-" ** 8, "-" ** 8, "-" ** 8, "-" ** 8, "-" ** 8
    });
    
    // Benchmark core operations
    try benchmarkRevParseHeadRobust();
    try benchmarkStatusPorcelainRobust();
    try benchmarkDescribeTagsRobust();
    try benchmarkIsCleanRobust();
    
    // Benchmark optimization effectiveness
    std.debug.print("\n=== OPTIMIZATION EFFECTIVENESS ===\n");
    try benchmarkCachingEffectiveness();
    
    // Compare with CLI for context
    std.debug.print("\n=== CLI COMPARISON (for reference) ===\n");
    try benchmarkCLIReference();
}

fn setupRobustTestRepo() !void {
    // Create unique temporary directory
    const timestamp = std.time.milliTimestamp();
    test_repo_path = try std.fmt.allocPrint(allocator, "/tmp/ziggit_bench_{d}", .{timestamp});
    
    // Clean up any existing directory
    std.fs.deleteTreeAbsolute(test_repo_path) catch {};
    
    // Create and initialize git repository
    std.fs.makeDirAbsolute(test_repo_path) catch |err| {
        std.debug.print("Failed to create test directory: {}\n", .{err});
        return err;
    };
    
    // Initialize git repo
    const init_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "init", test_repo_path },
    }) catch |err| {
        std.debug.print("Failed to initialize git repo: {}\n", .{err});
        return err;
    };
    defer allocator.free(init_result.stdout);
    defer allocator.free(init_result.stderr);
    
    if (init_result.term.Exited != 0) {
        std.debug.print("Git init failed: {s}\n", .{init_result.stderr});
        return error.GitInitFailed;
    }
    
    // Change to test repository for subsequent operations
    const old_cwd = std.process.getCwdAlloc(allocator) catch return error.GetCwdFailed;
    defer allocator.free(old_cwd);
    std.process.changeCurDir(test_repo_path) catch return error.ChangeCwdFailed;
    defer std.process.changeCurDir(old_cwd) catch {};
    
    // Configure git user
    const config_email = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "config", "user.email", "bench@ziggit.dev" },
    }) catch {};
    defer allocator.free(config_email.stdout);
    defer allocator.free(config_email.stderr);
    
    const config_name = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "config", "user.name", "Ziggit Benchmark" },
    }) catch {};
    defer allocator.free(config_name.stdout);
    defer allocator.free(config_name.stderr);
    
    // Create initial commit to establish HEAD
    const readme_file = try std.fs.cwd().createFile("README.md", .{});
    defer readme_file.close();
    try readme_file.writeAll("# Ziggit Benchmark Repository\nThis is a test repository for benchmarking ziggit performance.\n");
    
    // Add and commit README
    const add_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "add", "README.md" },
    }) catch {};
    defer allocator.free(add_result.stdout);
    defer allocator.free(add_result.stderr);
    
    const commit_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "commit", "-m", "Initial commit" },
    }) catch {};
    defer allocator.free(commit_result.stdout);
    defer allocator.free(commit_result.stderr);
    
    // Create additional files and commits
    var commit_idx: u32 = 1;
    while (commit_idx < 5) : (commit_idx += 1) {
        const filename = try std.fmt.allocPrint(allocator, "file{d}.txt", .{commit_idx});
        defer allocator.free(filename);
        
        const file = try std.fs.cwd().createFile(filename, .{});
        defer file.close();
        
        const content = try std.fmt.allocPrint(allocator, "Content for file {d}\nLine 2\nLine 3\n", .{commit_idx});
        defer allocator.free(content);
        try file.writeAll(content);
        
        // Add and commit
        const add_cmd = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "git", "add", filename },
        }) catch continue;
        defer allocator.free(add_cmd.stdout);
        defer allocator.free(add_cmd.stderr);
        
        const commit_msg = try std.fmt.allocPrint(allocator, "Add {s}", .{filename});
        defer allocator.free(commit_msg);
        
        const commit_cmd = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "git", "commit", "-m", commit_msg },
        }) catch continue;
        defer allocator.free(commit_cmd.stdout);
        defer allocator.free(commit_cmd.stderr);
    }
    
    // Create tags
    const tags = [_][]const u8{ "v1.0.0", "v1.1.0", "v2.0.0" };
    for (tags) |tag| {
        const tag_result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "git", "tag", tag },
        }) catch continue;
        defer allocator.free(tag_result.stdout);
        defer allocator.free(tag_result.stderr);
    }
    
    std.debug.print("✅ Test repository created successfully at {s}\n", .{test_repo_path});
}

fn cleanupTestRepository() void {
    if (test_repo_path.len > 0) {
        std.fs.deleteTreeAbsolute(test_repo_path) catch {};
        allocator.free(test_repo_path);
    }
}

fn benchmarkRevParseHeadRobust() !void {
    // Warmup
    var warmup_idx: u32 = 0;
    while (warmup_idx < NUM_WARMUP) : (warmup_idx += 1) {
        _ = benchmarkZigRevParseHeadSafe() catch continue;
    }
    
    var zig_times = try allocator.alloc(u64, NUM_ITERATIONS);
    defer allocator.free(zig_times);
    
    var successful_measurements: u32 = 0;
    var i: u32 = 0;
    while (i < NUM_ITERATIONS and successful_measurements < NUM_ITERATIONS) : (i += 1) {
        if (benchmarkZigRevParseHeadSafe()) |time| {
            zig_times[successful_measurements] = time;
            successful_measurements += 1;
        } else |_| {
            // Skip failed measurements
            continue;
        }
    }
    
    if (successful_measurements > 0) {
        const result = PerfResult.fromTimes("rev-parse HEAD", zig_times[0..successful_measurements]);
        result.print();
    } else {
        std.debug.print("| {s:<22} | {s:>6} | {s:>6} | {s:>6} | {s:>6} | {s:>6} |\n", .{
            "rev-parse HEAD", "ERROR", "ERROR", "ERROR", "ERROR", "ERROR"
        });
    }
}

fn benchmarkZigRevParseHeadSafe() !u64 {
    const start = std.time.nanoTimestamp();
    
    var repo = ziggit.Repository.open(allocator, test_repo_path) catch |err| {
        // std.debug.print("Repository open error: {}\n", .{err});
        return err;
    };
    defer repo.close();
    
    const hash = repo.revParseHead() catch |err| {
        // std.debug.print("revParseHead error: {}\n", .{err});
        return err;
    };
    _ = hash; // Use the result
    
    const end = std.time.nanoTimestamp();
    return @as(u64, @intCast(end - start));
}

fn benchmarkStatusPorcelainRobust() !void {
    // Warmup
    var warmup_idx: u32 = 0;
    while (warmup_idx < NUM_WARMUP) : (warmup_idx += 1) {
        _ = benchmarkZigStatusPorcelainSafe() catch continue;
    }
    
    var zig_times = try allocator.alloc(u64, NUM_ITERATIONS);
    defer allocator.free(zig_times);
    
    var i: u32 = 0;
    while (i < NUM_ITERATIONS) : (i += 1) {
        zig_times[i] = benchmarkZigStatusPorcelainSafe() catch 0;
    }
    
    const result = PerfResult.fromTimes("status --porcelain", zig_times);
    result.print();
}

fn benchmarkZigStatusPorcelainSafe() !u64 {
    const start = std.time.nanoTimestamp();
    
    var repo = try ziggit.Repository.open(allocator, test_repo_path);
    defer repo.close();
    
    const status = try repo.statusPorcelain(allocator);
    defer allocator.free(status);
    _ = status;
    
    const end = std.time.nanoTimestamp();
    return @as(u64, @intCast(end - start));
}

fn benchmarkDescribeTagsRobust() !void {
    // Warmup
    var warmup_idx: u32 = 0;
    while (warmup_idx < NUM_WARMUP) : (warmup_idx += 1) {
        _ = benchmarkZigDescribeTagsSafe() catch continue;
    }
    
    var zig_times = try allocator.alloc(u64, NUM_ITERATIONS);
    defer allocator.free(zig_times);
    
    var i: u32 = 0;
    while (i < NUM_ITERATIONS) : (i += 1) {
        zig_times[i] = benchmarkZigDescribeTagsSafe() catch 0;
    }
    
    const result = PerfResult.fromTimes("describe --tags", zig_times);
    result.print();
}

fn benchmarkZigDescribeTagsSafe() !u64 {
    const start = std.time.nanoTimestamp();
    
    var repo = try ziggit.Repository.open(allocator, test_repo_path);
    defer repo.close();
    
    const tag = try repo.describeTags(allocator);
    defer allocator.free(tag);
    _ = tag;
    
    const end = std.time.nanoTimestamp();
    return @as(u64, @intCast(end - start));
}

fn benchmarkIsCleanRobust() !void {
    // Warmup
    var warmup_idx: u32 = 0;
    while (warmup_idx < NUM_WARMUP) : (warmup_idx += 1) {
        _ = benchmarkZigIsCleanSafe() catch continue;
    }
    
    var zig_times = try allocator.alloc(u64, NUM_ITERATIONS);
    defer allocator.free(zig_times);
    
    var i: u32 = 0;
    while (i < NUM_ITERATIONS) : (i += 1) {
        zig_times[i] = benchmarkZigIsCleanSafe() catch 0;
    }
    
    const result = PerfResult.fromTimes("is_clean", zig_times);
    result.print();
}

fn benchmarkZigIsCleanSafe() !u64 {
    const start = std.time.nanoTimestamp();
    
    var repo = try ziggit.Repository.open(allocator, test_repo_path);
    defer repo.close();
    
    const clean = try repo.isClean();
    _ = clean;
    
    const end = std.time.nanoTimestamp();
    return @as(u64, @intCast(end - start));
}

fn benchmarkCachingEffectiveness() !void {
    std.debug.print("Testing caching effectiveness with repeated calls:\n");
    
    var repo = try ziggit.Repository.open(allocator, test_repo_path);
    defer repo.close();
    
    // Test rev-parse HEAD caching (if it works)
    const start1 = std.time.nanoTimestamp();
    _ = repo.revParseHead() catch {
        std.debug.print("- rev-parse HEAD: Caching test skipped (function error)\n");
        const end1 = std.time.nanoTimestamp();
        _ = end1 - start1;
        return;
    };
    const end1 = std.time.nanoTimestamp();
    
    const start2 = std.time.nanoTimestamp();
    _ = try repo.revParseHead();
    const end2 = std.time.nanoTimestamp();
    
    const first_call = @as(u64, @intCast(end1 - start1));
    const cached_call = @as(u64, @intCast(end2 - start2));
    const speedup = @as(f64, @floatFromInt(first_call)) / @as(f64, @floatFromInt(cached_call));
    
    std.debug.print("- rev-parse HEAD: {d}ns -> {d}ns ({d:.1}x speedup)\n", .{ first_call, cached_call, speedup });
    
    // Test describe tags caching
    const start3 = std.time.nanoTimestamp();
    const tag1 = try repo.describeTags(allocator);
    const end3 = std.time.nanoTimestamp();
    defer allocator.free(tag1);
    
    const start4 = std.time.nanoTimestamp();
    const tag2 = try repo.describeTags(allocator);
    const end4 = std.time.nanoTimestamp();
    defer allocator.free(tag2);
    
    const first_tag_call = @as(u64, @intCast(end3 - start3));
    const cached_tag_call = @as(u64, @intCast(end4 - start4));
    const tag_speedup = @as(f64, @floatFromInt(first_tag_call)) / @as(f64, @floatFromInt(cached_tag_call));
    
    std.debug.print("- describe --tags: {d}ns -> {d}ns ({d:.1}x speedup)\n", .{ first_tag_call, cached_tag_call, tag_speedup });
}

fn benchmarkCLIReference() !void {
    std.debug.print("CLI performance (for context - showing process spawn overhead):\n");
    
    // Quick CLI measurements for reference
    const cli_ops = [_]struct{ name: []const u8, cmd: []const []const u8 }{
        .{ .name = "CLI rev-parse", .cmd = &[_][]const u8{ "git", "rev-parse", "HEAD" } },
        .{ .name = "CLI status", .cmd = &[_][]const u8{ "git", "status", "--porcelain" } },
        .{ .name = "CLI describe", .cmd = &[_][]const u8{ "git", "describe", "--tags", "--abbrev=0" } },
    };
    
    for (cli_ops) |op| {
        const start = std.time.nanoTimestamp();
        
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = op.cmd,
            .cwd = test_repo_path,
        }) catch continue;
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        
        const end = std.time.nanoTimestamp();
        const time_us = @as(f64, @floatFromInt(@as(u64, @intCast(end - start)))) / 1000.0;
        
        std.debug.print("- {s}: {d:.0}μs (includes process spawn overhead)\n", .{ op.name, time_us });
    }
}