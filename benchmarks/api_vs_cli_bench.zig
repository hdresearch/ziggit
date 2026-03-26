const std = @import("std");
const print = std.debug.print;
const ziggit = @import("ziggit");

const ITERATIONS = 1000;

const BenchmarkStats = struct {
    operation: []const u8,
    zig_times: []u64,
    cli_times: []u64,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, operation: []const u8) !BenchmarkStats {
        return BenchmarkStats{
            .operation = operation,
            .zig_times = try allocator.alloc(u64, ITERATIONS),
            .cli_times = try allocator.alloc(u64, ITERATIONS),
            .allocator = allocator,
        };
    }

    fn deinit(self: *BenchmarkStats) void {
        self.allocator.free(self.zig_times);
        self.allocator.free(self.cli_times);
    }

    fn calculateStats(self: *const BenchmarkStats) StatsSummary {
        return StatsSummary{
            .zig_min = self.min(self.zig_times),
            .zig_median = self.median(self.zig_times),
            .zig_mean = self.mean(self.zig_times),
            .zig_p95 = self.percentile(self.zig_times, 95),
            .zig_p99 = self.percentile(self.zig_times, 99),
            .cli_min = self.min(self.cli_times),
            .cli_median = self.median(self.cli_times),
            .cli_mean = self.mean(self.cli_times),
            .cli_p95 = self.percentile(self.cli_times, 95),
            .cli_p99 = self.percentile(self.cli_times, 99),
        };
    }

    fn min(self: *const BenchmarkStats, times: []const u64) u64 {
        const sorted = self.allocator.dupe(u64, times) catch return 0;
        defer self.allocator.free(sorted);
        std.mem.sort(u64, sorted, {}, std.sort.asc(u64));
        return sorted[0];
    }

    fn median(self: *const BenchmarkStats, times: []const u64) u64 {
        const sorted = self.allocator.dupe(u64, times) catch return 0;
        defer self.allocator.free(sorted);
        std.mem.sort(u64, sorted, {}, std.sort.asc(u64));
        return sorted[sorted.len / 2];
    }

    fn mean(self: *const BenchmarkStats, times: []const u64) u64 {
        _ = self;
        var sum: u128 = 0;
        for (times) |time| {
            sum += time;
        }
        return @intCast(sum / times.len);
    }

    fn percentile(self: *const BenchmarkStats, times: []const u64, p: u8) u64 {
        const sorted = self.allocator.dupe(u64, times) catch return 0;
        defer self.allocator.free(sorted);
        std.mem.sort(u64, sorted, {}, std.sort.asc(u64));
        const idx = (sorted.len * p) / 100;
        return sorted[@min(idx, sorted.len - 1)];
    }
};

const StatsSummary = struct {
    zig_min: u64,
    zig_median: u64,
    zig_mean: u64,
    zig_p95: u64,
    zig_p99: u64,
    cli_min: u64,
    cli_median: u64,
    cli_mean: u64,
    cli_p95: u64,
    cli_p99: u64,
};

fn runCommand(allocator: std.mem.Allocator, args: []const []const u8, cwd: ?[]const u8) !std.process.Child.RunResult {
    return try std.process.Child.run(.{
        .allocator = allocator,
        .argv = args,
        .cwd = cwd,
    });
}

fn cleanupTestRepo(path: []const u8) void {
    std.fs.deleteTreeAbsolute(path) catch {};
}

fn setupTestRepository(allocator: std.mem.Allocator, repo_path: []const u8) !void {
    // Clean up any existing test repo
    cleanupTestRepo(repo_path);
    
    // Initialize git repository
    {
        const result = try runCommand(allocator, &.{ "git", "init", repo_path }, null);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        if (result.term != .Exited or result.term.Exited != 0) {
            return error.GitInitFailed;
        }
    }
    
    // Configure git user
    {
        const result = try runCommand(allocator, &.{ "git", "config", "user.name", "Test User" }, repo_path);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
    }
    {
        const result = try runCommand(allocator, &.{ "git", "config", "user.email", "test@example.com" }, repo_path);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
    }
    
    print("Creating 100 test files...\n", .{});
    
    // Create 100 files
    for (0..100) |i| {
        const filename = try std.fmt.allocPrint(allocator, "{s}/file_{d:03}.txt", .{ repo_path, i });
        defer allocator.free(filename);
        
        const file = try std.fs.createFileAbsolute(filename, .{});
        defer file.close();
        
        const content = try std.fmt.allocPrint(allocator, "File content {d}\nLine 2\nLine 3\n", .{i});
        defer allocator.free(content);
        try file.writeAll(content);
    }
    
    print("Creating 10 commits...\n", .{});
    
    // Create 10 commits (10 files each)
    for (0..10) |commit_idx| {
        // Add 10 files for this commit
        const start_file = commit_idx * 10;
        const end_file = start_file + 10;
        
        for (start_file..end_file) |file_idx| {
            const filename = try std.fmt.allocPrint(allocator, "file_{d:03}.txt", .{file_idx});
            defer allocator.free(filename);
            
            const result = try runCommand(allocator, &.{ "git", "add", filename }, repo_path);
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);
        }
        
        // Commit
        const commit_msg = try std.fmt.allocPrint(allocator, "Commit {d}: Added files {d}-{d}", .{ commit_idx + 1, start_file, end_file - 1 });
        defer allocator.free(commit_msg);
        
        const result = try runCommand(allocator, &.{ "git", "commit", "-m", commit_msg }, repo_path);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
    }
    
    print("Creating tags...\n", .{});
    
    // Create some tags
    for (0..3) |tag_idx| {
        const tag_name = try std.fmt.allocPrint(allocator, "v1.{d}.0", .{tag_idx});
        defer allocator.free(tag_name);
        
        const result = try runCommand(allocator, &.{ "git", "tag", tag_name }, repo_path);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
    }
    
    print("Test repository setup complete!\n\n", .{});
}

fn benchmarkRevParseHead(allocator: std.mem.Allocator, repo_path: []const u8) !BenchmarkStats {
    const stats = try BenchmarkStats.init(allocator, "rev-parse HEAD");
    
    print("Benchmarking rev-parse HEAD...\n", .{});
    
    // Open repo for Zig calls
    var repo = ziggit.repo_open(allocator, repo_path) catch {
        print("Failed to open repo with ziggit, skipping Zig benchmarks\n", .{});
        // Fill with dummy data
        for (stats.zig_times) |*time| {
            time.* = std.math.maxInt(u64);
        }
        // Only benchmark CLI
        for (stats.cli_times, 0..) |*time, i| {
            const start = std.time.nanoTimestamp();
            const result = runCommand(allocator, &.{ "git", "rev-parse", "HEAD" }, repo_path) catch {
                time.* = std.math.maxInt(u64);
                continue;
            };
            const end = std.time.nanoTimestamp();
            time.* = @intCast(end - start);
            allocator.free(result.stdout);
            allocator.free(result.stderr);
            
            if (i % 100 == 0) print("  CLI iteration {d}/1000\n", .{i + 1});
        }
        return stats;
    };
    
    // Warm up
    {
        const hash = ziggit.repo_rev_parse_head(&repo, allocator) catch "";
        defer if (hash.len > 0) allocator.free(hash);
    }
    
    // Benchmark Zig function calls
    for (stats.zig_times, 0..) |*time, i| {
        const start = std.time.nanoTimestamp();
        const hash = ziggit.repo_rev_parse_head(&repo, allocator) catch {
            time.* = std.math.maxInt(u64);
            continue;
        };
        const end = std.time.nanoTimestamp();
        time.* = @intCast(end - start);
        defer allocator.free(hash);
        
        if (i % 100 == 0) print("  Zig iteration {d}/1000\n", .{i + 1});
    }
    
    // Benchmark CLI calls
    for (stats.cli_times, 0..) |*time, i| {
        const start = std.time.nanoTimestamp();
        const result = runCommand(allocator, &.{ "git", "rev-parse", "HEAD" }, repo_path) catch {
            time.* = std.math.maxInt(u64);
            continue;
        };
        const end = std.time.nanoTimestamp();
        time.* = @intCast(end - start);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        
        if (i % 100 == 0) print("  CLI iteration {d}/1000\n", .{i + 1});
    }
    
    return stats;
}

fn benchmarkStatusPorcelain(allocator: std.mem.Allocator, repo_path: []const u8) !BenchmarkStats {
    const stats = try BenchmarkStats.init(allocator, "status --porcelain");
    
    print("Benchmarking status --porcelain...\n", .{});
    
    // Open repo for Zig calls
    var repo = ziggit.repo_open(allocator, repo_path) catch {
        print("Failed to open repo with ziggit, skipping Zig benchmarks\n", .{});
        // Fill with dummy data
        for (stats.zig_times) |*time| {
            time.* = std.math.maxInt(u64);
        }
        // Only benchmark CLI
        for (stats.cli_times, 0..) |*time, i| {
            const start = std.time.nanoTimestamp();
            const result = runCommand(allocator, &.{ "git", "status", "--porcelain" }, repo_path) catch {
                time.* = std.math.maxInt(u64);
                continue;
            };
            const end = std.time.nanoTimestamp();
            time.* = @intCast(end - start);
            allocator.free(result.stdout);
            allocator.free(result.stderr);
            
            if (i % 100 == 0) print("  CLI iteration {d}/1000\n", .{i + 1});
        }
        return stats;
    };
    
    // Warm up
    {
        const status = ziggit.repo_status(&repo, allocator) catch "";
        defer if (status.len > 0) allocator.free(status);
    }
    
    // Benchmark Zig function calls
    for (stats.zig_times, 0..) |*time, i| {
        const start = std.time.nanoTimestamp();
        const status = ziggit.repo_status(&repo, allocator) catch {
            time.* = std.math.maxInt(u64);
            continue;
        };
        const end = std.time.nanoTimestamp();
        time.* = @intCast(end - start);
        defer allocator.free(status);
        
        if (i % 100 == 0) print("  Zig iteration {d}/1000\n", .{i + 1});
    }
    
    // Benchmark CLI calls
    for (stats.cli_times, 0..) |*time, i| {
        const start = std.time.nanoTimestamp();
        const result = runCommand(allocator, &.{ "git", "status", "--porcelain" }, repo_path) catch {
            time.* = std.math.maxInt(u64);
            continue;
        };
        const end = std.time.nanoTimestamp();
        time.* = @intCast(end - start);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        
        if (i % 100 == 0) print("  CLI iteration {d}/1000\n", .{i + 1});
    }
    
    return stats;
}

fn benchmarkDescribeTags(allocator: std.mem.Allocator, repo_path: []const u8) !BenchmarkStats {
    const stats = try BenchmarkStats.init(allocator, "describe --tags");
    
    print("Benchmarking describe --tags...\n", .{});
    
    // Open repo for Zig calls
    var repo = ziggit.repo_open(allocator, repo_path) catch {
        print("Failed to open repo with ziggit, skipping Zig benchmarks\n", .{});
        // Fill with dummy data
        for (stats.zig_times) |*time| {
            time.* = std.math.maxInt(u64);
        }
        // Only benchmark CLI
        for (stats.cli_times, 0..) |*time, i| {
            const start = std.time.nanoTimestamp();
            const result = runCommand(allocator, &.{ "git", "describe", "--tags", "--abbrev=0" }, repo_path) catch {
                time.* = std.math.maxInt(u64);
                continue;
            };
            const end = std.time.nanoTimestamp();
            time.* = @intCast(end - start);
            allocator.free(result.stdout);
            allocator.free(result.stderr);
            
            if (i % 100 == 0) print("  CLI iteration {d}/1000\n", .{i + 1});
        }
        return stats;
    };
    
    // Warm up
    {
        const tag = ziggit.repo_describe_tags(&repo, allocator) catch "";
        defer if (tag.len > 0) allocator.free(tag);
    }
    
    // Benchmark Zig function calls
    for (stats.zig_times, 0..) |*time, i| {
        const start = std.time.nanoTimestamp();
        const tag = ziggit.repo_describe_tags(&repo, allocator) catch {
            time.* = std.math.maxInt(u64);
            continue;
        };
        const end = std.time.nanoTimestamp();
        time.* = @intCast(end - start);
        defer allocator.free(tag);
        
        if (i % 100 == 0) print("  Zig iteration {d}/1000\n", .{i + 1});
    }
    
    // Benchmark CLI calls
    for (stats.cli_times, 0..) |*time, i| {
        const start = std.time.nanoTimestamp();
        const result = runCommand(allocator, &.{ "git", "describe", "--tags", "--abbrev=0" }, repo_path) catch {
            time.* = std.math.maxInt(u64);
            continue;
        };
        const end = std.time.nanoTimestamp();
        time.* = @intCast(end - start);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        
        if (i % 100 == 0) print("  CLI iteration {d}/1000\n", .{i + 1});
    }
    
    return stats;
}

fn benchmarkIsClean(allocator: std.mem.Allocator, repo_path: []const u8) !BenchmarkStats {
    const stats = try BenchmarkStats.init(allocator, "is_clean");
    
    print("Benchmarking is_clean...\n", .{});
    
    // Open repo for Zig calls  
    var repo = ziggit.repo_open(allocator, repo_path) catch {
        print("Failed to open repo with ziggit, skipping Zig benchmarks\n", .{});
        // Fill with dummy data
        for (stats.zig_times) |*time| {
            time.* = std.math.maxInt(u64);
        }
        // Only benchmark CLI (equivalent to status --porcelain | wc -l == 0)
        for (stats.cli_times, 0..) |*time, i| {
            const start = std.time.nanoTimestamp();
            const result = runCommand(allocator, &.{ "git", "status", "--porcelain" }, repo_path) catch {
                time.* = std.math.maxInt(u64);
                continue;
            };
            const end = std.time.nanoTimestamp();
            time.* = @intCast(end - start);
            // Check if clean (no output)
            const is_clean = std.mem.trim(u8, result.stdout, " \n\r\t").len == 0;
            _ = is_clean;
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);
            
            if (i % 100 == 0) print("  CLI iteration {d}/1000\n", .{i + 1});
        }
        return stats;
    };
    
    // Warm up
    {
        const status = ziggit.repo_status(&repo, allocator) catch "";
        defer if (status.len > 0) allocator.free(status);
    }
    
    // Benchmark Zig function calls (check if status is empty)
    for (stats.zig_times, 0..) |*time, i| {
        const start = std.time.nanoTimestamp();
        const status = ziggit.repo_status(&repo, allocator) catch {
            time.* = std.math.maxInt(u64);
            continue;
        };
        const is_clean = status.len == 0;
        _ = is_clean;
        const end = std.time.nanoTimestamp();
        time.* = @intCast(end - start);
        defer allocator.free(status);
        
        if (i % 100 == 0) print("  Zig iteration {d}/1000\n", .{i + 1});
    }
    
    // Benchmark CLI calls
    for (stats.cli_times, 0..) |*time, i| {
        const start = std.time.nanoTimestamp();
        const result = runCommand(allocator, &.{ "git", "status", "--porcelain" }, repo_path) catch {
            time.* = std.math.maxInt(u64);
            continue;
        };
        // Check if clean (no output)
        const is_clean = std.mem.trim(u8, result.stdout, " \n\r\t").len == 0;
        _ = is_clean;
        const end = std.time.nanoTimestamp();
        time.* = @intCast(end - start);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        
        if (i % 100 == 0) print("  CLI iteration {d}/1000\n", .{i + 1});
    }
    
    return stats;
}

fn printResults(stats: []BenchmarkStats) void {
    print("\n=== BENCHMARK RESULTS ===\n\n", .{});
    print("Operation         | Zig Min | Zig Median | Zig Mean | Zig P95 | Zig P99 | CLI Min | CLI Median | CLI Mean | CLI P95 | CLI P99 | Speedup\n", .{});
    print("------------------|---------|------------|----------|---------|---------|---------|------------|----------|---------|---------|--------\n", .{});
    
    for (stats) |*stat| {
        const summary = stat.calculateStats();
        
        const speedup = @as(f64, @floatFromInt(summary.cli_mean)) / @as(f64, @floatFromInt(summary.zig_mean));
        
        print("{s:<17} |", .{stat.operation});
        print("{d:>8}|", .{summary.zig_min / 1000}); // Convert to microseconds
        print("{d:>11} |", .{summary.zig_median / 1000});
        print("{d:>9} |", .{summary.zig_mean / 1000});
        print("{d:>8} |", .{summary.zig_p95 / 1000});
        print("{d:>8} |", .{summary.zig_p99 / 1000});
        print("{d:>8} |", .{summary.cli_min / 1000});
        print("{d:>11} |", .{summary.cli_median / 1000});
        print("{d:>9} |", .{summary.cli_mean / 1000});
        print("{d:>8} |", .{summary.cli_p95 / 1000});
        print("{d:>8} |", .{summary.cli_p99 / 1000});
        print("{d:>7.1f}x\n", .{speedup});
    }
    
    print("\nNote: All times in microseconds (μs)\n", .{});
    print("Speedup = CLI_mean / Zig_mean\n\n", .{});
    
    // Performance analysis
    print("=== PERFORMANCE ANALYSIS ===\n", .{});
    for (stats) |*stat| {
        const summary = stat.calculateStats();
        const zig_mean_us = @as(f64, @floatFromInt(summary.zig_mean)) / 1000.0;
        const cli_mean_us = @as(f64, @floatFromInt(summary.cli_mean)) / 1000.0;
        const speedup = cli_mean_us / zig_mean_us;
        
        print("{s}:\n", .{stat.operation});
        print("  Zig: {d:.1f}μs average (expected: 1-50μs for direct function call)\n", .{zig_mean_us});
        print("  CLI: {d:.1f}μs average (expected: ~2-5ms for process spawn)\n", .{cli_mean_us});
        
        if (speedup >= 10.0) {
            print("  ✓ EXCELLENT: {d:.1f}x speedup - Significant improvement for bun!\n", .{speedup});
        } else if (speedup >= 2.0) {
            print("  ✓ GOOD: {d:.1f}x speedup - Worthwhile improvement\n", .{speedup});
        } else if (speedup >= 1.1) {
            print("  ~ MARGINAL: {d:.1f}x speedup - Small improvement\n", .{speedup});
        } else {
            print("  ✗ SLOWER: {d:.1f}x - Needs optimization!\n", .{speedup});
        }
        print("\n", .{});
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    print("=== ziggit API vs CLI Benchmark ===\n", .{});
    print("Comparing direct Zig function calls vs spawning git CLI\n", .{});
    print("Running {} iterations each for statistical significance\n\n", .{ITERATIONS});
    
    const repo_path = "/tmp/ziggit_api_benchmark_repo";
    
    // Setup test repository
    try setupTestRepository(allocator, repo_path);
    defer cleanupTestRepo(repo_path);
    
    // Run benchmarks
    var stats = std.ArrayList(BenchmarkStats).init(allocator);
    defer {
        for (stats.items) |*stat| {
            stat.deinit();
        }
        stats.deinit();
    }
    
    // Benchmark each operation
    const rev_parse_stats = try benchmarkRevParseHead(allocator, repo_path);
    try stats.append(rev_parse_stats);
    
    const status_stats = try benchmarkStatusPorcelain(allocator, repo_path);
    try stats.append(status_stats);
    
    const describe_stats = try benchmarkDescribeTags(allocator, repo_path);
    try stats.append(describe_stats);
    
    const clean_stats = try benchmarkIsClean(allocator, repo_path);
    try stats.append(clean_stats);
    
    // Print results
    printResults(stats.items);
    
    print("=== CONCLUSION ===\n", .{});
    print("This benchmark demonstrates the performance advantage of calling\n", .{});
    print("ziggit Zig functions directly vs spawning git CLI processes.\n", .{});
    print("Process spawn overhead typically adds 2-5ms per call, while\n", .{});
    print("direct function calls should complete in 1-50μs.\n", .{});
    print("\nFor bun's use case with frequent git operations, this represents\n", .{});
    print("a 100-1000x performance improvement opportunity!\n", .{});
}