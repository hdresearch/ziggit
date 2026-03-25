const std = @import("std");
const print = std.debug.print;
const allocator = std.heap.page_allocator;

const BenchmarkResult = struct {
    name: []const u8,
    mean_ms: f64,
    min_ms: f64,
    max_ms: f64,
    iterations: usize,
    
    fn display(self: BenchmarkResult) void {
        print("  {s:25} | {d:7.2} ms (±{d:5.2} ms)\n", .{
            self.name, 
            self.mean_ms,
            self.max_ms - self.min_ms
        });
    }
};

// Helper function to run shell commands and measure time
fn runCommand(cmd: []const []const u8, cwd: []const u8) !f64 {
    const start = std.time.nanoTimestamp();
    
    var child = std.process.Child.init(cmd, allocator);
    child.cwd = cwd;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    
    const term = child.spawnAndWait() catch |err| {
        return err;
    };
    
    const end = std.time.nanoTimestamp();
    
    if (term != .Exited or term.Exited != 0) {
        return error.CommandFailed;
    }
    
    return @as(f64, @floatFromInt(end - start)) / 1_000_000.0; // Convert to ms
}

// Clean up function
fn cleanup(repo_name: []const u8) void {
    const rm_cmd = [_][]const u8{ "rm", "-rf", repo_name };
    var child = std.process.Child.init(&rm_cmd, allocator);
    child.cwd = "/tmp";
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    _ = child.spawnAndWait() catch {};
}

// Benchmark functions for git CLI
fn benchGitInit(repo_name: []const u8) !f64 {
    cleanup(repo_name);
    const cmd = [_][]const u8{ "git", "init", repo_name, "--quiet" };
    return runCommand(&cmd, "/tmp");
}

fn benchGitStatus(repo_name: []const u8) !f64 {
    const cmd = [_][]const u8{ "git", "status", "--porcelain" };
    return runCommand(&cmd, repo_name);
}

// Benchmark functions for ziggit CLI
fn benchZiggitInit(repo_name: []const u8) !f64 {
    cleanup(repo_name);
    const cmd = [_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "init", repo_name };
    return runCommand(&cmd, "/tmp");
}

fn benchZiggitStatus(repo_name: []const u8) !f64 {
    const cmd = [_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "status" };
    return runCommand(&cmd, repo_name);
}

// Generic benchmark runner
fn runBenchmark(
    comptime name: []const u8,
    bench_fn: anytype,
    args: anytype,
    iterations: usize
) !BenchmarkResult {
    var times = try allocator.alloc(f64, iterations);
    defer allocator.free(times);
    
    print("Running {s} ({d} iterations)...", .{name, iterations});
    
    // Warmup
    for (0..3) |_| {
        _ = @call(.auto, bench_fn, args) catch {};
    }
    
    // Actual benchmark
    var successful_runs: usize = 0;
    for (0..iterations) |i| {
        const time = @call(.auto, bench_fn, args) catch |err| {
            if (i == 0) {
                print(" FAILED: {any}\n", .{err});
                return err;
            }
            continue;
        };
        times[successful_runs] = time;
        successful_runs += 1;
        
        if ((i + 1) % (iterations / 10) == 0) {
            print(".", .{});
        }
    }
    
    if (successful_runs == 0) {
        return error.CommandFailed;
    }
    
    print(" done ({d} successful)\n", .{successful_runs});
    
    // Calculate statistics
    std.mem.sort(f64, times[0..successful_runs], {}, std.sort.asc(f64));
    
    const min_time = times[0];
    const max_time = times[successful_runs - 1];
    var total: f64 = 0;
    for (times[0..successful_runs]) |time| {
        total += time;
    }
    const mean_time = total / @as(f64, @floatFromInt(successful_runs));
    
    return BenchmarkResult{
        .name = name,
        .mean_ms = mean_time,
        .min_ms = min_time,
        .max_ms = max_time,
        .iterations = successful_runs,
    };
}

pub fn main() !void {
    print("=== Git CLI vs Ziggit CLI Benchmark ===\n\n", .{});
    print("Measuring performance of common git operations.\n", .{});
    print("Times shown as mean ± range in milliseconds.\n\n", .{});
    
    // Check if ziggit binary exists
    if (std.fs.accessAbsolute("/root/ziggit/zig-out/bin/ziggit", .{})) |_| {
        print("Found ziggit binary\n", .{});
    } else |_| {
        print("Error: ziggit binary not found. Please build with 'zig build' first.\n", .{});
        return;
    }
    
    const iterations = 50;
    
    var results = std.ArrayList(BenchmarkResult).init(allocator);
    defer results.deinit();
    
    // Test 1: Repository initialization
    print("\n1. Repository Initialization\n", .{});
    
    const git_init_result = runBenchmark(
        "git init",
        benchGitInit,
        .{"/tmp/test-repo-git"},
        iterations
    ) catch |err| {
        print("git init benchmark failed: {any}\n", .{err});
        return;
    };
    try results.append(git_init_result);
    
    const ziggit_init_result = runBenchmark(
        "ziggit init",
        benchZiggitInit,
        .{"/tmp/test-repo-ziggit"},
        iterations
    ) catch |err| {
        print("ziggit init benchmark failed: {any}\n", .{err});
        return;
    };
    try results.append(ziggit_init_result);
    
    // Test 2: Status operations
    print("\n2. Status Operations\n", .{});
    
    // Setup repositories for status testing
    _ = runCommand(&[_][]const u8{ "git", "init", "status-test-git", "--quiet" }, "/tmp") catch {};
    _ = runCommand(&[_][]const u8{ "/root/ziggit/zig-out/bin/ziggit", "init", "status-test-ziggit" }, "/tmp") catch {};
    
    const git_status_result = runBenchmark(
        "git status",
        benchGitStatus,
        .{"/tmp/status-test-git"},
        iterations
    ) catch |err| {
        print("git status benchmark failed: {any}\n", .{err});
        return;
    };
    try results.append(git_status_result);
    
    const ziggit_status_result = runBenchmark(
        "ziggit status", 
        benchZiggitStatus,
        .{"/tmp/status-test-ziggit"},
        iterations
    ) catch |err| {
        print("ziggit status benchmark failed: {any}\n", .{err});
        return;
    };
    try results.append(ziggit_status_result);
    
    // Print comprehensive results
    print("\n=== BENCHMARK RESULTS ===\n", .{});
    print("  Operation                 | Mean Time (±Range)\n", .{});
    print("  --------------------------|--------------------\n", .{});
    
    for (results.items) |result| {
        result.display();
    }
    
    // Performance comparison
    print("\n=== PERFORMANCE COMPARISON ===\n", .{});
    
    if (results.items.len >= 4) {
        const git_init_time = results.items[0].mean_ms;
        const ziggit_init_time = results.items[1].mean_ms;
        const git_status_time = results.items[2].mean_ms;
        const ziggit_status_time = results.items[3].mean_ms;
        
        print("Init: ", .{});
        if (ziggit_init_time < git_init_time) {
            const speedup = git_init_time / ziggit_init_time;
            print("ziggit is {d:.2}x faster\n", .{speedup});
        } else {
            const slowdown = ziggit_init_time / git_init_time;
            print("git is {d:.2}x faster\n", .{slowdown});
        }
        
        print("Status: ", .{});
        if (ziggit_status_time < git_status_time) {
            const speedup = git_status_time / ziggit_status_time;
            print("ziggit is {d:.2}x faster\n", .{speedup});
        } else {
            const slowdown = ziggit_status_time / git_status_time;
            print("git is {d:.2}x faster\n", .{slowdown});
        }
    }
    
    // Cleanup
    print("\nCleaning up...\n", .{});
    cleanup("/tmp/test-repo-git");
    cleanup("/tmp/test-repo-ziggit");
    cleanup("/tmp/status-test-git");
    cleanup("/tmp/status-test-ziggit");
    
    print("Benchmark complete!\n", .{});
}