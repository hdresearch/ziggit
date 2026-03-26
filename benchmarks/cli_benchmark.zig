const std = @import("std");
const print = std.debug.print;

const BenchmarkResult = struct {
    name: []const u8,
    mean_ns: u64,
    min_ns: u64,
    max_ns: u64,
    iterations: usize,
    
    fn display(self: BenchmarkResult) void {
        print("  {s:25} | ", .{self.name});
        formatTime(self.mean_ns);
        print(" (±", .{});
        formatTime(self.max_ns - self.min_ns);
        print(")\n", .{});
    }
};

fn formatTime(ns: u64) void {
    if (ns < 1000) {
        print("{d} ns", .{ns});
    } else if (ns < 1000_000) {
        print("{d:.2} μs", .{@as(f64, @floatFromInt(ns)) / 1000.0});
    } else if (ns < 1000_000_000) {
        print("{d:.2} ms", .{@as(f64, @floatFromInt(ns)) / 1000_000.0});
    } else {
        print("{d:.2} s", .{@as(f64, @floatFromInt(ns)) / 1000_000_000.0});
    }
}

// Helper function to run shell commands and measure time
fn runCommand(allocator: std.mem.Allocator, cmd: []const []const u8, cwd: ?[]const u8) !u64 {
    const start = std.time.nanoTimestamp();
    
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = cmd,
        .cwd = cwd,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    
    const end = std.time.nanoTimestamp();
    
    if (result.term != .Exited or result.term.Exited != 0) {
        return error.CommandFailed;
    }
    
    return @intCast(end - start);
}

// Generic benchmark runner
fn runBenchmark(
    allocator: std.mem.Allocator,
    comptime name: []const u8,
    cmd: []const []const u8,
    cwd: ?[]const u8,
    iterations: usize
) !BenchmarkResult {
    var times = try allocator.alloc(u64, iterations);
    defer allocator.free(times);
    
    print("Running {s} ({d} iterations)...", .{name, iterations});
    
    // Warmup
    for (0..3) |_| {
        _ = runCommand(allocator, cmd, cwd) catch {};
    }
    
    // Actual benchmark
    var successful_runs: usize = 0;
    for (0..iterations) |i| {
        const time = runCommand(allocator, cmd, cwd) catch |err| {
            std.debug.print("Iteration {d} failed: {any}\n", .{i, err});
            continue;
        };
        times[successful_runs] = time;
        successful_runs += 1;
        
        if ((i + 1) % (iterations / 10) == 0) {
            print(".", .{});
        }
    }
    
    if (successful_runs == 0) {
        return error.AllIterationsFailed;
    }
    
    print(" done\n", .{});
    
    // Calculate statistics
    std.mem.sort(u64, times[0..successful_runs], {}, std.sort.asc(u64));
    
    const min_time = times[0];
    const max_time = times[successful_runs - 1];
    var total: u64 = 0;
    for (times[0..successful_runs]) |time| {
        total += time;
    }
    const mean_time = total / successful_runs;
    
    return BenchmarkResult{
        .name = name,
        .mean_ns = mean_time,
        .min_ns = min_time,
        .max_ns = max_time,
        .iterations = successful_runs,
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    print("=== Git CLI vs Ziggit CLI Benchmark ===\n\n", .{});
    print("Measuring performance of common git operations.\n", .{});
    print("All times shown as mean ± range.\n\n", .{});
    
    const iterations = 50;
    
    // Setup: Create a test repository  
    print("Setting up test repository...\n", .{});
    const test_dir = "/tmp/bench_test";
    
    // Clean up any existing directory
    _ = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{"rm", "-rf", test_dir},
    }) catch {};
    
    // Create and initialize repo
    _ = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{"mkdir", "-p", test_dir},
    });
    
    _ = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{"git", "init"},
        .cwd = test_dir,
    });
    
    _ = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{"git", "config", "user.name", "Benchmark"},
        .cwd = test_dir,
    });
    
    _ = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{"git", "config", "user.email", "bench@test.com"},
        .cwd = test_dir,
    });
    
    // Create test files
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const file_path = try std.fmt.allocPrint(allocator, "{s}/file{d}.txt", .{test_dir, i});
        defer allocator.free(file_path);
        
        const content = try std.fmt.allocPrint(allocator, "Content for file {d}\nLine 2\nLine 3\n", .{i});
        defer allocator.free(content);
        
        const file = try std.fs.createFileAbsolute(file_path, .{});
        defer file.close();
        try file.writeAll(content);
    }
    
    // Add and commit files
    _ = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{"git", "add", "."},
        .cwd = test_dir,
    });
    
    _ = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{"git", "commit", "-m", "Initial commit"},
        .cwd = test_dir,
    });
    
    var results = std.ArrayList(BenchmarkResult).init(allocator);
    defer results.deinit();
    
    print("\n=== RUNNING BENCHMARKS ===\n\n", .{});
    
    // Test 1: Status operations
    print("1. Status Operations\n", .{});
    
    const git_status_result = runBenchmark(
        allocator,
        "git status",
        &.{"git", "status", "--porcelain"},
        test_dir,
        iterations
    ) catch |err| {
        print("git status benchmark failed: {any}\n", .{err});
        return;
    };
    try results.append(git_status_result);
    
    if (runBenchmark(
        allocator,
        "ziggit status",
        &.{"/root/ziggit/zig-out/bin/ziggit", "status", "--porcelain"},
        test_dir,
        iterations
    )) |ziggit_status_result| {
        try results.append(ziggit_status_result);
    } else |err| {
        print("ziggit status benchmark failed: {any}\n", .{err});
        // Don't return, continue with other benchmarks
        const dummy_result = BenchmarkResult{
            .name = "ziggit status (failed)",
            .mean_ns = 0,
            .min_ns = 0,
            .max_ns = 0,
            .iterations = 0,
        };
        try results.append(dummy_result);
    }
    
    // Test 2: Log operations
    print("\n2. Log Operations\n", .{});
    
    const git_log_result = runBenchmark(
        allocator,
        "git log",
        &.{"git", "log", "--oneline"},
        test_dir,
        iterations
    ) catch |err| {
        print("git log benchmark failed: {any}\n", .{err});
        return;
    };
    try results.append(git_log_result);
    
    if (runBenchmark(
        allocator,
        "ziggit log", 
        &.{"/root/ziggit/zig-out/bin/ziggit", "log", "--oneline"},
        test_dir,
        iterations
    )) |ziggit_log_result| {
        try results.append(ziggit_log_result);
    } else |err| {
        print("ziggit log benchmark failed: {any}\n", .{err});
        const dummy_result = BenchmarkResult{
            .name = "ziggit log (failed)",
            .mean_ns = 0,
            .min_ns = 0,
            .max_ns = 0,
            .iterations = 0,
        };
        try results.append(dummy_result);
    }
    
    // Print results
    print("\n=== BENCHMARK RESULTS ===\n", .{});
    print("  Operation                 | Mean Time (±Range)\n", .{});
    print("  --------------------------|--------------------\n", .{});
    
    for (results.items) |result| {
        if (result.iterations > 0) {
            result.display();
        } else {
            print("  {s:25} | FAILED\n", .{result.name});
        }
    }
    
    // Performance comparison
    print("\n=== PERFORMANCE COMPARISON ===\n", .{});
    
    if (results.items.len >= 4 and results.items[1].iterations > 0) {
        const git_status_time = results.items[0].mean_ns;
        const ziggit_status_time = results.items[1].mean_ns;
        
        print("Status: ", .{});
        if (ziggit_status_time < git_status_time) {
            const speedup = @as(f64, @floatFromInt(git_status_time)) / @as(f64, @floatFromInt(ziggit_status_time));
            print("ziggit is {d:.2}x faster\n", .{speedup});
        } else {
            const slowdown = @as(f64, @floatFromInt(ziggit_status_time)) / @as(f64, @floatFromInt(git_status_time));
            print("git is {d:.2}x faster\n", .{slowdown});
        }
    }
    
    if (results.items.len >= 4 and results.items[3].iterations > 0) {
        const git_log_time = results.items[2].mean_ns;
        const ziggit_log_time = results.items[3].mean_ns;
        
        print("Log: ", .{});
        if (ziggit_log_time < git_log_time) {
            const speedup = @as(f64, @floatFromInt(git_log_time)) / @as(f64, @floatFromInt(ziggit_log_time));
            print("ziggit is {d:.2}x faster\n", .{speedup});
        } else {
            const slowdown = @as(f64, @floatFromInt(ziggit_log_time)) / @as(f64, @floatFromInt(git_log_time));
            print("git is {d:.2}x faster\n", .{slowdown});
        }
    }
    
    // Cleanup
    print("\nCleaning up...\n", .{});
    _ = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{"rm", "-rf", test_dir},
    }) catch {};
    
    print("CLI benchmark complete!\n", .{});
}