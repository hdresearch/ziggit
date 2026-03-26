const std = @import("std");
const print = std.debug.print;
const ziggit = @import("ziggit");

fn formatDuration(ns: u64) void {
    if (ns < 1_000) {
        print("{d} ns", .{ns});
    } else if (ns < 1_000_000) {
        print("{d:.1} μs", .{@as(f64, @floatFromInt(ns)) / 1_000.0});
    } else if (ns < 1_000_000_000) {
        print("{d:.2} ms", .{@as(f64, @floatFromInt(ns)) / 1_000_000.0});
    } else {
        print("{d:.3} s", .{@as(f64, @floatFromInt(ns)) / 1_000_000_000.0});
    }
}

fn runCommand(allocator: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8) !std.process.Child.RunResult {
    return try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .cwd = cwd,
    });
}

const BenchmarkStats = struct {
    min: u64,
    median: u64,
    mean: u64,
    p95: u64,
    p99: u64,
    
    fn calculate(times: []u64) BenchmarkStats {
        std.sort.heap(u64, times, {}, std.sort.asc(u64));
        
        var total: u64 = 0;
        for (times) |time| {
            total += time;
        }
        
        const len = times.len;
        return BenchmarkStats{
            .min = times[0],
            .median = times[len / 2],
            .mean = total / len,
            .p95 = times[(len * 95) / 100],
            .p99 = times[(len * 99) / 100],
        };
    }
    
    fn print_stats(self: BenchmarkStats, name: []const u8) void {
        print("{s:30} | min: ", .{name});
        formatDuration(self.min);
        print(" | median: ", .{});
        formatDuration(self.median);
        print(" | mean: ", .{});
        formatDuration(self.mean);
        print(" | p95: ", .{});
        formatDuration(self.p95);
        print(" | p99: ", .{});
        formatDuration(self.p99);
        print("\n", .{});
    }
};

fn setupTestRepo(allocator: std.mem.Allocator, repo_path: []const u8) !void {
    // Remove existing repo if present
    std.fs.deleteTreeAbsolute(repo_path) catch {};
    
    // Create directory
    try std.fs.makeDirAbsolute(repo_path);
    
    // Initialize git repo
    _ = try runCommand(allocator, &[_][]const u8{ "git", "init" }, repo_path);
    _ = try runCommand(allocator, &[_][]const u8{ "git", "config", "user.name", "Test User" }, repo_path);
    _ = try runCommand(allocator, &[_][]const u8{ "git", "config", "user.email", "test@example.com" }, repo_path);
    
    // Create 100 files and 10 commits with tags
    var commit_num: u32 = 1;
    while (commit_num <= 10) : (commit_num += 1) {
        // Add 10 files per commit
        var file_num: u32 = 1;
        while (file_num <= 10) : (file_num += 1) {
            const file_index = (commit_num - 1) * 10 + file_num;
            const file_name = try std.fmt.allocPrint(allocator, "file_{d:0>3}.txt", .{file_index});
            defer allocator.free(file_name);
            
            const file_path = try std.fs.path.join(allocator, &[_][]const u8{ repo_path, file_name });
            defer allocator.free(file_path);
            
            const content = try std.fmt.allocPrint(allocator, "Content of file {d} in commit {d}\n", .{ file_index, commit_num });
            defer allocator.free(content);
            
            const file = try std.fs.createFileAbsolute(file_path, .{});
            defer file.close();
            try file.writeAll(content);
            
            _ = try runCommand(allocator, &[_][]const u8{ "git", "add", file_name }, repo_path);
        }
        
        const commit_msg = try std.fmt.allocPrint(allocator, "Commit {d}", .{commit_num});
        defer allocator.free(commit_msg);
        
        _ = try runCommand(allocator, &[_][]const u8{ "git", "commit", "-m", commit_msg }, repo_path);
        
        // Create tag every 3 commits
        if (commit_num % 3 == 0) {
            const tag_name = try std.fmt.allocPrint(allocator, "v{d}.0", .{commit_num / 3});
            defer allocator.free(tag_name);
            
            _ = try runCommand(allocator, &[_][]const u8{ "git", "tag", tag_name }, repo_path);
        }
    }
    
    print("Test repo setup complete: {s}\n", .{repo_path});
}

fn benchmarkRevParseHead(allocator: std.mem.Allocator, repo_path: []const u8, iterations: usize) !void {
    var repo = try ziggit.Repository.open(allocator, repo_path);
    defer repo.close();
    
    // Benchmark Zig API
    var zig_times = try allocator.alloc(u64, iterations);
    defer allocator.free(zig_times);
    
    for (0..iterations) |i| {
        const start = std.time.nanoTimestamp();
        _ = try repo.revParseHead();
        const end = std.time.nanoTimestamp();
        zig_times[i] = @intCast(end - start);
    }
    
    // Benchmark CLI spawn
    var cli_times = try allocator.alloc(u64, iterations);
    defer allocator.free(cli_times);
    
    for (0..iterations) |i| {
        const start = std.time.nanoTimestamp();
        const result = try runCommand(allocator, &[_][]const u8{ "git", "rev-parse", "HEAD" }, repo_path);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
        const end = std.time.nanoTimestamp();
        cli_times[i] = @intCast(end - start);
    }
    
    const zig_stats = BenchmarkStats.calculate(zig_times);
    const cli_stats = BenchmarkStats.calculate(cli_times);
    
    print("\n=== rev-parse HEAD ({d} iterations) ===\n", .{iterations});
    zig_stats.print_stats("Zig API");
    cli_stats.print_stats("Git CLI");
    
    const speedup = @as(f64, @floatFromInt(cli_stats.mean)) / @as(f64, @floatFromInt(zig_stats.mean));
    print("Speedup: {d:.1}x faster\n", .{speedup});
}

fn benchmarkStatusPorcelain(allocator: std.mem.Allocator, repo_path: []const u8, iterations: usize) !void {
    var repo = try ziggit.Repository.open(allocator, repo_path);
    defer repo.close();
    
    // Benchmark Zig API
    var zig_times = try allocator.alloc(u64, iterations);
    defer allocator.free(zig_times);
    
    for (0..iterations) |i| {
        const start = std.time.nanoTimestamp();
        const status = try repo.statusPorcelain(allocator);
        allocator.free(status);
        const end = std.time.nanoTimestamp();
        zig_times[i] = @intCast(end - start);
    }
    
    // Benchmark CLI spawn
    var cli_times = try allocator.alloc(u64, iterations);
    defer allocator.free(cli_times);
    
    for (0..iterations) |i| {
        const start = std.time.nanoTimestamp();
        const result = try runCommand(allocator, &[_][]const u8{ "git", "status", "--porcelain" }, repo_path);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
        const end = std.time.nanoTimestamp();
        cli_times[i] = @intCast(end - start);
    }
    
    const zig_stats = BenchmarkStats.calculate(zig_times);
    const cli_stats = BenchmarkStats.calculate(cli_times);
    
    print("\n=== status --porcelain ({d} iterations) ===\n", .{iterations});
    zig_stats.print_stats("Zig API");
    cli_stats.print_stats("Git CLI");
    
    const speedup = @as(f64, @floatFromInt(cli_stats.mean)) / @as(f64, @floatFromInt(zig_stats.mean));
    print("Speedup: {d:.1}x faster\n", .{speedup});
}

fn benchmarkDescribeTags(allocator: std.mem.Allocator, repo_path: []const u8, iterations: usize) !void {
    var repo = try ziggit.Repository.open(allocator, repo_path);
    defer repo.close();
    
    // Benchmark Zig API
    var zig_times = try allocator.alloc(u64, iterations);
    defer allocator.free(zig_times);
    
    for (0..iterations) |i| {
        const start = std.time.nanoTimestamp();
        const tag = try repo.describeTags(allocator);
        defer allocator.free(tag);
        const end = std.time.nanoTimestamp();
        zig_times[i] = @intCast(end - start);
    }
    
    // Benchmark CLI spawn
    var cli_times = try allocator.alloc(u64, iterations);
    defer allocator.free(cli_times);
    
    for (0..iterations) |i| {
        const start = std.time.nanoTimestamp();
        const result = runCommand(allocator, &[_][]const u8{ "git", "describe", "--tags", "--abbrev=0" }, repo_path) catch |err| switch (err) {
            else => {
                // Even if command fails, we still measure the process spawn overhead
                const end = std.time.nanoTimestamp();
                cli_times[i] = @intCast(end - start);
                continue;
            },
        };
        allocator.free(result.stdout);
        allocator.free(result.stderr);
        const end = std.time.nanoTimestamp();
        cli_times[i] = @intCast(end - start);
    }
    
    const zig_stats = BenchmarkStats.calculate(zig_times);
    const cli_stats = BenchmarkStats.calculate(cli_times);
    
    print("\n=== describe --tags ({d} iterations) ===\n", .{iterations});
    zig_stats.print_stats("Zig API");
    cli_stats.print_stats("Git CLI");
    
    const speedup = @as(f64, @floatFromInt(cli_stats.mean)) / @as(f64, @floatFromInt(zig_stats.mean));
    print("Speedup: {d:.1}x faster\n", .{speedup});
}

fn benchmarkIsClean(allocator: std.mem.Allocator, repo_path: []const u8, iterations: usize) !void {
    var repo = try ziggit.Repository.open(allocator, repo_path);
    defer repo.close();
    
    // Benchmark Zig API
    var zig_times = try allocator.alloc(u64, iterations);
    defer allocator.free(zig_times);
    
    for (0..iterations) |i| {
        const start = std.time.nanoTimestamp();
        _ = try repo.isClean();
        const end = std.time.nanoTimestamp();
        zig_times[i] = @intCast(end - start);
    }
    
    // Benchmark CLI spawn (using status --porcelain and checking if empty)
    var cli_times = try allocator.alloc(u64, iterations);
    defer allocator.free(cli_times);
    
    for (0..iterations) |i| {
        const start = std.time.nanoTimestamp();
        const result = try runCommand(allocator, &[_][]const u8{ "git", "status", "--porcelain" }, repo_path);
        _ = result.stdout.len == 0; // Check if clean
        allocator.free(result.stdout);
        allocator.free(result.stderr);
        const end = std.time.nanoTimestamp();
        cli_times[i] = @intCast(end - start);
    }
    
    const zig_stats = BenchmarkStats.calculate(zig_times);
    const cli_stats = BenchmarkStats.calculate(cli_times);
    
    print("\n=== is_clean ({d} iterations) ===\n", .{iterations});
    zig_stats.print_stats("Zig API");
    cli_stats.print_stats("Git CLI");
    
    const speedup = @as(f64, @floatFromInt(cli_stats.mean)) / @as(f64, @floatFromInt(zig_stats.mean));
    print("Speedup: {d:.1}x faster\n", .{speedup});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const repo_path = "/tmp/ziggit_bench_repo";
    const iterations = 1000;
    
    print("Setting up test repository...\n", .{});
    try setupTestRepo(allocator, repo_path);
    
    print("\n=== API vs CLI Benchmark ===\n", .{});
    print("Repository: {s}\n", .{repo_path});
    print("Iterations: {d}\n", .{iterations});
    
    try benchmarkRevParseHead(allocator, repo_path, iterations);
    try benchmarkStatusPorcelain(allocator, repo_path, iterations);
    try benchmarkDescribeTags(allocator, repo_path, iterations);
    try benchmarkIsClean(allocator, repo_path, iterations);
    
    print("\n=== Summary ===\n", .{});
    print("All benchmarks measure PURE ZIG code paths vs git CLI spawning.\n", .{});
    print("The measured Zig functions do NOT spawn external processes.\n", .{});
}