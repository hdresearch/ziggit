const std = @import("std");
const ziggit = @import("ziggit");

// Benchmark configuration
const NUM_ITERATIONS = 1000;
const NUM_WARMUP = 100;

// Benchmark results structure  
const BenchmarkResult = struct {
    name: []const u8,
    min_time: u64,
    median_time: u64,
    mean_time: u64,
    p95_time: u64,
    p99_time: u64,
    
    pub fn fromTimes(name: []const u8, times: []u64) BenchmarkResult {
        // Sort times for percentile calculation
        std.sort.insertion(u64, times, {}, std.sort.asc(u64));
        
        const min_time = times[0];
        const median_idx = times.len / 2;
        const median_time = if (times.len % 2 == 0)
            (times[median_idx - 1] + times[median_idx]) / 2
        else 
            times[median_idx];
        
        var sum: u64 = 0;
        for (times) |time| {
            sum += time;
        }
        const mean_time = sum / times.len;
        
        const p95_idx = (times.len * 95) / 100;
        const p95_time = times[@min(p95_idx, times.len - 1)];
        
        const p99_idx = (times.len * 99) / 100;
        const p99_time = times[@min(p99_idx, times.len - 1)];
        
        return BenchmarkResult{
            .name = name,
            .min_time = min_time,
            .median_time = median_time,
            .mean_time = mean_time,
            .p95_time = p95_time,
            .p99_time = p99_time,
        };
    }
    
    pub fn printResult(self: BenchmarkResult) void {
        const min_us = @as(f64, @floatFromInt(self.min_time)) / 1000.0;
        const median_us = @as(f64, @floatFromInt(self.median_time)) / 1000.0;
        const mean_us = @as(f64, @floatFromInt(self.mean_time)) / 1000.0;
        const p95_us = @as(f64, @floatFromInt(self.p95_time)) / 1000.0;
        const p99_us = @as(f64, @floatFromInt(self.p99_time)) / 1000.0;
        
        std.debug.print("| {s:<20} | {d:>8.1} | {d:>8.1} | {d:>8.1} | {d:>8.1} | {d:>8.1} |\n", .{
            self.name, min_us, median_us, mean_us, p95_us, p99_us
        });
    }
};

// Test repository paths
var test_repo_path: []u8 = undefined;
var allocator: std.mem.Allocator = undefined;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    allocator = gpa.allocator();
    
    // Create test repository
    try setupTestRepository();
    defer cleanupTestRepository();
    
    std.debug.print("=== ZIGGIT API vs CLI BENCHMARK ===\n");
    std.debug.print("Iterations: {d}, Warmup: {d}\n", .{NUM_ITERATIONS, NUM_WARMUP});
    std.debug.print("\n");
    
    std.debug.print("| {s:<20} | {s:>8} | {s:>8} | {s:>8} | {s:>8} | {s:>8} |\n", .{
        "Operation", "Min(us)", "Med(us)", "Mean(us)", "P95(us)", "P99(us)"
    });
    std.debug.print("|{s}|{s}|{s}|{s}|{s}|{s}|\n", .{
        "-" ** 22, "-" ** 10, "-" ** 10, "-" ** 10, "-" ** 10, "-" ** 10
    });
    
    // Benchmark rev-parse HEAD
    try benchmarkRevParseHead();
    
    // Benchmark status --porcelain
    try benchmarkStatusPorcelain();
    
    // Benchmark describe --tags
    try benchmarkDescribeTags();
    
    // Benchmark is_clean check
    try benchmarkIsClean();
}

fn setupTestRepository() !void {
    // Create temporary directory for test repository
    const tmp_dir = std.testing.tmpDir(.{});
    test_repo_path = try std.fs.path.resolve(allocator, &[_][]const u8{ tmp_dir.dir.realpathAlloc(allocator, ".") catch "/tmp", "ziggit_bench_repo" });
    
    // Clean up any existing test repo
    std.fs.deleteTreeAbsolute(test_repo_path) catch {};
    
    // Initialize git repository
    const result = std.ChildProcess.exec(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "init", test_repo_path },
    }) catch |err| {
        std.debug.print("Error initializing git repo: {}\n", .{err});
        return err;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    
    if (result.term.Exited != 0) {
        std.debug.print("Git init failed: {s}\n", .{result.stderr});
        return error.GitInitFailed;
    }
    
    // Change to test repository
    const old_cwd = std.process.getCwdAlloc(allocator) catch return error.GetCwdFailed;
    defer allocator.free(old_cwd);
    std.process.changeCurDir(test_repo_path) catch return error.ChangeCwdFailed;
    defer std.process.changeCurDir(old_cwd) catch {};
    
    // Create 100 test files
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        const filename = try std.fmt.allocPrint(allocator, "file{d}.txt", .{i});
        defer allocator.free(filename);
        
        const file = try std.fs.cwd().createFile(filename, .{});
        defer file.close();
        
        const content = try std.fmt.allocPrint(allocator, "This is test file {d}\nLine 2\nLine 3\n", .{i});
        defer allocator.free(content);
        try file.writeAll(content);
    }
    
    // Configure git user
    _ = std.ChildProcess.exec(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "config", "user.email", "test@ziggit.dev" },
    }) catch {};
    
    _ = std.ChildProcess.exec(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "config", "user.name", "Ziggit Benchmark" },
    }) catch {};
    
    // Add and commit files in batches to create 10 commits
    var commit_num: u32 = 0;
    while (commit_num < 10) : (commit_num += 1) {
        // Add 10 files per commit
        const start_file = commit_num * 10;
        const end_file = @min(start_file + 10, 100);
        
        var file_idx = start_file;
        while (file_idx < end_file) : (file_idx += 1) {
            const filename = try std.fmt.allocPrint(allocator, "file{d}.txt", .{file_idx});
            defer allocator.free(filename);
            
            const add_result = std.ChildProcess.exec(.{
                .allocator = allocator,
                .argv = &[_][]const u8{ "git", "add", filename },
            }) catch continue;
            defer allocator.free(add_result.stdout);
            defer allocator.free(add_result.stderr);
        }
        
        // Commit the batch
        const commit_msg = try std.fmt.allocPrint(allocator, "Add files {d}-{d}", .{ start_file, end_file - 1 });
        defer allocator.free(commit_msg);
        
        const commit_result = std.ChildProcess.exec(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "git", "commit", "-m", commit_msg },
        }) catch continue;
        defer allocator.free(commit_result.stdout);
        defer allocator.free(commit_result.stderr);
    }
    
    // Create some tags
    const tag_names = [_][]const u8{ "v1.0.0", "v1.1.0", "v2.0.0" };
    for (tag_names) |tag| {
        const tag_result = std.ChildProcess.exec(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "git", "tag", tag },
        }) catch continue;
        defer allocator.free(tag_result.stdout);
        defer allocator.free(tag_result.stderr);
    }
}

fn cleanupTestRepository() void {
    if (test_repo_path.len > 0) {
        std.fs.deleteTreeAbsolute(test_repo_path) catch {};
        allocator.free(test_repo_path);
    }
}

fn benchmarkRevParseHead() !void {
    // Warmup
    var warmup_idx: u32 = 0;
    while (warmup_idx < NUM_WARMUP) : (warmup_idx += 1) {
        _ = try benchmarkZigRevParseHead();
        _ = try benchmarkCliRevParseHead();
    }
    
    // Benchmark Zig implementation
    var zig_times = try allocator.alloc(u64, NUM_ITERATIONS);
    defer allocator.free(zig_times);
    
    var i: u32 = 0;
    while (i < NUM_ITERATIONS) : (i += 1) {
        zig_times[i] = try benchmarkZigRevParseHead();
    }
    
    // Benchmark CLI implementation
    var cli_times = try allocator.alloc(u64, NUM_ITERATIONS);
    defer allocator.free(cli_times);
    
    i = 0;
    while (i < NUM_ITERATIONS) : (i += 1) {
        cli_times[i] = try benchmarkCliRevParseHead();
    }
    
    // Print results
    const zig_result = BenchmarkResult.fromTimes("rev-parse (Zig)", zig_times);
    const cli_result = BenchmarkResult.fromTimes("rev-parse (CLI)", cli_times);
    
    zig_result.printResult();
    cli_result.printResult();
    
    // Calculate speedup
    const speedup = @as(f64, @floatFromInt(cli_result.median_time)) / @as(f64, @floatFromInt(zig_result.median_time));
    std.debug.print("| {s:<20} | {s:>8} | {s:>8} | {d:>7.1}x | {s:>8} | {s:>8} |\n", .{
        "Speedup", "", "", speedup, "", ""
    });
}

fn benchmarkZigRevParseHead() !u64 {
    const start = std.time.nanoTimestamp();
    
    // PURE ZIG PATH: Open repository and call revParseHead directly
    var repo = try ziggit.Repository.open(allocator, test_repo_path);
    defer repo.close();
    
    const hash = try repo.revParseHead();
    _ = hash; // Use the result to prevent optimization
    
    const end = std.time.nanoTimestamp();
    return @as(u64, @intCast(end - start));
}

fn benchmarkCliRevParseHead() !u64 {
    const start = std.time.nanoTimestamp();
    
    // CLI SPAWNING: Execute git rev-parse HEAD as child process
    const result = try std.ChildProcess.exec(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "rev-parse", "HEAD" },
        .cwd = test_repo_path,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    
    _ = result; // Use the result to prevent optimization
    
    const end = std.time.nanoTimestamp();
    return @as(u64, @intCast(end - start));
}

fn benchmarkStatusPorcelain() !void {
    // Warmup
    var warmup_idx: u32 = 0;
    while (warmup_idx < NUM_WARMUP) : (warmup_idx += 1) {
        _ = try benchmarkZigStatusPorcelain();
        _ = try benchmarkCliStatusPorcelain();
    }
    
    // Benchmark Zig implementation
    var zig_times = try allocator.alloc(u64, NUM_ITERATIONS);
    defer allocator.free(zig_times);
    
    var i: u32 = 0;
    while (i < NUM_ITERATIONS) : (i += 1) {
        zig_times[i] = try benchmarkZigStatusPorcelain();
    }
    
    // Benchmark CLI implementation
    var cli_times = try allocator.alloc(u64, NUM_ITERATIONS);
    defer allocator.free(cli_times);
    
    i = 0;
    while (i < NUM_ITERATIONS) : (i += 1) {
        cli_times[i] = try benchmarkCliStatusPorcelain();
    }
    
    // Print results
    const zig_result = BenchmarkResult.fromTimes("status (Zig)", zig_times);
    const cli_result = BenchmarkResult.fromTimes("status (CLI)", cli_times);
    
    zig_result.printResult();
    cli_result.printResult();
    
    // Calculate speedup
    const speedup = @as(f64, @floatFromInt(cli_result.median_time)) / @as(f64, @floatFromInt(zig_result.median_time));
    std.debug.print("| {s:<20} | {s:>8} | {s:>8} | {d:>7.1}x | {s:>8} | {s:>8} |\n", .{
        "Speedup", "", "", speedup, "", ""
    });
}

fn benchmarkZigStatusPorcelain() !u64 {
    const start = std.time.nanoTimestamp();
    
    // PURE ZIG PATH: Open repository and call statusPorcelain directly
    var repo = try ziggit.Repository.open(allocator, test_repo_path);
    defer repo.close();
    
    const status = try repo.statusPorcelain(allocator);
    defer allocator.free(status);
    _ = status; // Use the result to prevent optimization
    
    const end = std.time.nanoTimestamp();
    return @as(u64, @intCast(end - start));
}

fn benchmarkCliStatusPorcelain() !u64 {
    const start = std.time.nanoTimestamp();
    
    // CLI SPAWNING: Execute git status --porcelain as child process
    const result = try std.ChildProcess.exec(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "status", "--porcelain" },
        .cwd = test_repo_path,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    
    _ = result; // Use the result to prevent optimization
    
    const end = std.time.nanoTimestamp();
    return @as(u64, @intCast(end - start));
}

fn benchmarkDescribeTags() !void {
    // Warmup
    var warmup_idx: u32 = 0;
    while (warmup_idx < NUM_WARMUP) : (warmup_idx += 1) {
        _ = try benchmarkZigDescribeTags();
        _ = try benchmarkCliDescribeTags();
    }
    
    // Benchmark Zig implementation
    var zig_times = try allocator.alloc(u64, NUM_ITERATIONS);
    defer allocator.free(zig_times);
    
    var i: u32 = 0;
    while (i < NUM_ITERATIONS) : (i += 1) {
        zig_times[i] = try benchmarkZigDescribeTags();
    }
    
    // Benchmark CLI implementation
    var cli_times = try allocator.alloc(u64, NUM_ITERATIONS);
    defer allocator.free(cli_times);
    
    i = 0;
    while (i < NUM_ITERATIONS) : (i += 1) {
        cli_times[i] = try benchmarkCliDescribeTags();
    }
    
    // Print results
    const zig_result = BenchmarkResult.fromTimes("describe (Zig)", zig_times);
    const cli_result = BenchmarkResult.fromTimes("describe (CLI)", cli_times);
    
    zig_result.printResult();
    cli_result.printResult();
    
    // Calculate speedup
    const speedup = @as(f64, @floatFromInt(cli_result.median_time)) / @as(f64, @floatFromInt(zig_result.median_time));
    std.debug.print("| {s:<20} | {s:>8} | {s:>8} | {d:>7.1}x | {s:>8} | {s:>8} |\n", .{
        "Speedup", "", "", speedup, "", ""
    });
}

fn benchmarkZigDescribeTags() !u64 {
    const start = std.time.nanoTimestamp();
    
    // PURE ZIG PATH: Open repository and call describeTags directly
    var repo = try ziggit.Repository.open(allocator, test_repo_path);
    defer repo.close();
    
    const tag = try repo.describeTags(allocator);
    defer allocator.free(tag);
    _ = tag; // Use the result to prevent optimization
    
    const end = std.time.nanoTimestamp();
    return @as(u64, @intCast(end - start));
}

fn benchmarkCliDescribeTags() !u64 {
    const start = std.time.nanoTimestamp();
    
    // CLI SPAWNING: Execute git describe --tags --abbrev=0 as child process
    const result = try std.ChildProcess.exec(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "describe", "--tags", "--abbrev=0" },
        .cwd = test_repo_path,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    
    _ = result; // Use the result to prevent optimization
    
    const end = std.time.nanoTimestamp();
    return @as(u64, @intCast(end - start));
}

fn benchmarkIsClean() !void {
    // Warmup
    var warmup_idx: u32 = 0;
    while (warmup_idx < NUM_WARMUP) : (warmup_idx += 1) {
        _ = try benchmarkZigIsClean();
        _ = try benchmarkCliIsClean();
    }
    
    // Benchmark Zig implementation
    var zig_times = try allocator.alloc(u64, NUM_ITERATIONS);
    defer allocator.free(zig_times);
    
    var i: u32 = 0;
    while (i < NUM_ITERATIONS) : (i += 1) {
        zig_times[i] = try benchmarkZigIsClean();
    }
    
    // Benchmark CLI implementation
    var cli_times = try allocator.alloc(u64, NUM_ITERATIONS);
    defer allocator.free(cli_times);
    
    i = 0;
    while (i < NUM_ITERATIONS) : (i += 1) {
        cli_times[i] = try benchmarkCliIsClean();
    }
    
    // Print results
    const zig_result = BenchmarkResult.fromTimes("is_clean (Zig)", zig_times);
    const cli_result = BenchmarkResult.fromTimes("is_clean (CLI)", cli_times);
    
    zig_result.printResult();
    cli_result.printResult();
    
    // Calculate speedup
    const speedup = @as(f64, @floatFromInt(cli_result.median_time)) / @as(f64, @floatFromInt(zig_result.median_time));
    std.debug.print("| {s:<20} | {s:>8} | {s:>8} | {d:>7.1}x | {s:>8} | {s:>8} |\n", .{
        "Speedup", "", "", speedup, "", ""
    });
}

fn benchmarkZigIsClean() !u64 {
    const start = std.time.nanoTimestamp();
    
    // PURE ZIG PATH: Open repository and call isClean directly
    var repo = try ziggit.Repository.open(allocator, test_repo_path);
    defer repo.close();
    
    const clean = try repo.isClean();
    _ = clean; // Use the result to prevent optimization
    
    const end = std.time.nanoTimestamp();
    return @as(u64, @intCast(end - start));
}

fn benchmarkCliIsClean() !u64 {
    const start = std.time.nanoTimestamp();
    
    // CLI SPAWNING: Execute git status --porcelain and check if output is empty
    const result = try std.ChildProcess.exec(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "status", "--porcelain" },
        .cwd = test_repo_path,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    
    const is_clean = std.mem.trim(u8, result.stdout, " \n\t\r").len == 0;
    _ = is_clean; // Use the result to prevent optimization
    
    const end = std.time.nanoTimestamp();
    return @as(u64, @intCast(end - start));
}