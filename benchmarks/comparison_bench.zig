const std = @import("std");
const print = std.debug.print;
const allocator = std.heap.page_allocator;

// C imports for ziggit library
const c = @cImport({
    @cInclude("ziggit.h");
});

const TestError = error{
    CommandFailed,
    OutOfMemory,
    InvalidUtf8,
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

// Helper function to run shell commands and measure time
fn runCommand(cmd: []const []const u8) !u64 {
    const start = std.time.nanoTimestamp();
    
    var child = std.process.Child.init(cmd, allocator);
    child.cwd = "/tmp";
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    
    const term = child.spawnAndWait() catch |err| {
        std.debug.print("Command failed: {any}\n", .{cmd});
        return err;
    };
    
    const end = std.time.nanoTimestamp();
    
    if (term != .Exited or term.Exited != 0) {
        std.debug.print("Command failed with term {any}: {any}\n", .{term, cmd});
        return TestError.CommandFailed;
    }
    
    return @intCast(end - start);
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
fn benchGitInit(repo_name: []const u8) !u64 {
    cleanup(repo_name);
    
    const cmd = [_][]const u8{ "git", "-C", "/tmp", "init", repo_name, "--quiet" };
    return runCommand(&cmd);
}

fn benchGitStatus(repo_name: []const u8) !u64 {
    // Change to the repo directory and run git status
    const cmd = [_][]const u8{ "git", "-C", repo_name, "status", "--porcelain" };
    return runCommand(&cmd);
}

fn benchGitClone(source_repo: []const u8, target_repo: []const u8) !u64 {
    cleanup(target_repo);
    
    const cmd = [_][]const u8{ "git", "clone", "--quiet", source_repo, target_repo };
    return runCommand(&cmd);
}

// Benchmark functions for ziggit library
fn benchZiggitInit(repo_name: []const u8) !u64 {
    cleanup(repo_name);
    
    const start = std.time.nanoTimestamp();
    
    const repo_name_z = try allocator.dupeZ(u8, repo_name);
    defer allocator.free(repo_name_z);
    
    const result = c.ziggit_repo_init(repo_name_z.ptr, 0);
    if (result != c.ZIGGIT_SUCCESS) {
        return TestError.CommandFailed;
    }
    
    const end = std.time.nanoTimestamp();
    return @intCast(end - start);
}

fn benchZiggitOpen(repo_name: []const u8) !u64 {
    const start = std.time.nanoTimestamp();
    
    const repo_name_z = try allocator.dupeZ(u8, repo_name);
    defer allocator.free(repo_name_z);
    
    const repo = c.ziggit_repo_open(repo_name_z.ptr);
    if (repo == null) {
        return TestError.CommandFailed;
    }
    defer c.ziggit_repo_close(repo);
    
    const end = std.time.nanoTimestamp();
    return @intCast(end - start);
}

fn benchZiggitStatus(repo_name: []const u8) !u64 {
    const repo_name_z = try allocator.dupeZ(u8, repo_name);
    defer allocator.free(repo_name_z);
    
    const repo = c.ziggit_repo_open(repo_name_z.ptr);
    if (repo == null) {
        return TestError.CommandFailed;
    }
    defer c.ziggit_repo_close(repo);
    
    const start = std.time.nanoTimestamp();
    
    var buffer: [4096]u8 = undefined;
    const result = c.ziggit_status(repo, &buffer, buffer.len);
    if (result != c.ZIGGIT_SUCCESS) {
        return TestError.CommandFailed;
    }
    
    const end = std.time.nanoTimestamp();
    return @intCast(end - start);
}

// Generic benchmark runner
fn runBenchmark(
    comptime name: []const u8,
    bench_fn: anytype,
    args: anytype,
    iterations: usize
) !BenchmarkResult {
    var times = try allocator.alloc(u64, iterations);
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
            std.debug.print("Benchmark iteration {d} failed: {any}\n", .{i, err});
            continue;
        };
        times[successful_runs] = time;
        successful_runs += 1;
        
        if ((i + 1) % (iterations / 10) == 0) {
            print(".", .{});
        }
    }
    
    if (successful_runs == 0) {
        return TestError.CommandFailed;
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
    print("=== Git CLI vs Ziggit Library Benchmark ===\n\n", .{});
    print("Measuring performance of common git operations.\n", .{});
    print("All times shown as mean ± range.\n\n", .{});
    
    const iterations = 100;
    
    // Setup: Create a test repository for cloning benchmarks
    print("Setting up test repository...\n", .{});
    cleanup("test-source");
    _ = runCommand(&[_][]const u8{ "git", "-C", "/tmp", "init", "test-source", "--quiet" }) catch {
        print("Failed to setup test repository\n", .{});
        return;
    };
    
    // Create some test content
    const touch_cmd = [_][]const u8{ "touch", "/tmp/test-source/README.md" };
    _ = runCommand(&touch_cmd) catch {};
    _ = runCommand(&[_][]const u8{ "git", "-C", "/tmp/test-source", "add", "." }) catch {};
    _ = runCommand(&[_][]const u8{ "git", "-C", "/tmp/test-source", "commit", "-m", "Initial commit", "--quiet" }) catch {};
    
    var results = std.ArrayList(BenchmarkResult).init(allocator);
    defer results.deinit();
    
    // Test 1: Repository initialization
    print("\n1. Repository Initialization\n", .{});
    
    const git_init_result = runBenchmark(
        "git init",
        benchGitInit,
        .{"test-repo-git"},
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
    
    // Test 2: Repository opening/status (requires pre-existing repo)
    print("\n2. Status Operations\n", .{});
    
    // Setup repositories for status testing
    _ = runCommand(&[_][]const u8{ "git", "-C", "/tmp", "init", "status-test-git", "--quiet" }) catch {};
    _ = c.ziggit_repo_init("/tmp/status-test-ziggit", 0);
    
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
    
    // Test 3: Repository cloning (fewer iterations due to expense)
    print("\n3. Repository Cloning\n", .{});
    
    const clone_iterations = 10;  // Fewer iterations for expensive operations
    
    const git_clone_result = runBenchmark(
        "git clone",
        benchGitClone,
        .{"/tmp/test-source", "/tmp/cloned-git"},
        clone_iterations
    ) catch |err| {
        print("git clone benchmark failed: {any}\n", .{err});
        return;
    };
    try results.append(git_clone_result);
    
    // Print comprehensive results
    print("\n=== BENCHMARK RESULTS ===\n", .{});
    print("  Operation                 | Mean Time (±Range)\n", .{});
    print("  --------------------------|--------------------\n", .{});
    
    for (results.items) |result| {
        result.display();
    }
    
    // Performance comparison
    print("\n=== PERFORMANCE COMPARISON ===\n", .{});
    
    // Find pairs for comparison
    if (results.items.len >= 4) {
        const git_init_time = results.items[0].mean_ns;
        const ziggit_init_time = results.items[1].mean_ns;
        const git_status_time = results.items[2].mean_ns;
        const ziggit_status_time = results.items[3].mean_ns;
        
        print("Init: ", .{});
        if (ziggit_init_time < git_init_time) {
            const speedup = @as(f64, @floatFromInt(git_init_time)) / @as(f64, @floatFromInt(ziggit_init_time));
            print("ziggit is {d:.2}x faster\n", .{speedup});
        } else {
            const slowdown = @as(f64, @floatFromInt(ziggit_init_time)) / @as(f64, @floatFromInt(git_init_time));
            print("git is {d:.2}x faster\n", .{slowdown});
        }
        
        print("Status: ", .{});
        if (ziggit_status_time < git_status_time) {
            const speedup = @as(f64, @floatFromInt(git_status_time)) / @as(f64, @floatFromInt(ziggit_status_time));
            print("ziggit is {d:.2}x faster\n", .{speedup});
        } else {
            const slowdown = @as(f64, @floatFromInt(ziggit_status_time)) / @as(f64, @floatFromInt(git_status_time));
            print("git is {d:.2}x faster\n", .{slowdown});
        }
    }
    
    // Cleanup
    print("\nCleaning up...\n", .{});
    cleanup("test-source");
    cleanup("test-repo-git");
    cleanup("test-repo-ziggit");
    cleanup("status-test-git");
    cleanup("status-test-ziggit");
    cleanup("cloned-git");
    
    print("Benchmark complete!\n", .{});
}