const std = @import("std");
const print = std.debug.print;
const allocator = std.heap.page_allocator;

// C imports for ziggit library
const ziggit = @cImport({
    @cInclude("ziggit.h");
});

// C imports for libgit2
const libgit2 = @cImport({
    @cInclude("git2.h");
});

const TestError = error{
    CommandFailed,
    OutOfMemory,
    InvalidUtf8,
    LibGit2Error,
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
        std.debug.print("Command failed: {any}\n", .{err});
        return err;
    };
    
    const end = std.time.nanoTimestamp();
    
    if (term != .Exited or term.Exited != 0) {
        std.debug.print("Command failed with term {any}\n", .{term});
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

// Git CLI benchmarks
fn benchGitInit(repo_name: []const u8) !u64 {
    cleanup(repo_name);
    const cmd = [_][]const u8{ "git", "-C", "/tmp", "init", repo_name, "--quiet" };
    return runCommand(&cmd);
}

fn benchGitStatus(repo_name: []const u8) !u64 {
    const cmd = [_][]const u8{ "git", "-C", repo_name, "status", "--porcelain" };
    return runCommand(&cmd);
}

// Ziggit library benchmarks
fn benchZiggitInit(repo_name: []const u8) !u64 {
    cleanup(repo_name);
    
    const start = std.time.nanoTimestamp();
    
    const repo_name_z = try allocator.dupeZ(u8, repo_name);
    defer allocator.free(repo_name_z);
    
    const result = ziggit.ziggit_repo_init(repo_name_z.ptr, 0);
    if (result != ziggit.ZIGGIT_SUCCESS) {
        return TestError.CommandFailed;
    }
    
    const end = std.time.nanoTimestamp();
    return @intCast(end - start);
}

fn benchZiggitStatus(repo_name: []const u8) !u64 {
    const repo_name_z = try allocator.dupeZ(u8, repo_name);
    defer allocator.free(repo_name_z);
    
    const repo = ziggit.ziggit_repo_open(repo_name_z.ptr);
    if (repo == null) {
        return TestError.CommandFailed;
    }
    defer ziggit.ziggit_repo_close(repo);
    
    const start = std.time.nanoTimestamp();
    
    var buffer: [4096]u8 = undefined;
    const result = ziggit.ziggit_status(repo, &buffer, buffer.len);
    if (result != ziggit.ZIGGIT_SUCCESS) {
        return TestError.CommandFailed;
    }
    
    const end = std.time.nanoTimestamp();
    return @intCast(end - start);
}

// libgit2 benchmarks
fn benchLibgit2Init(repo_name: []const u8) !u64 {
    cleanup(repo_name);
    
    const start = std.time.nanoTimestamp();
    
    const repo_name_z = try allocator.dupeZ(u8, repo_name);
    defer allocator.free(repo_name_z);
    
    var repo: ?*libgit2.git_repository = null;
    const result = libgit2.git_repository_init(&repo, repo_name_z.ptr, 0);
    if (result != 0) {
        return TestError.LibGit2Error;
    }
    defer libgit2.git_repository_free(repo);
    
    const end = std.time.nanoTimestamp();
    return @intCast(end - start);
}

fn benchLibgit2Status(repo_name: []const u8) !u64 {
    const repo_name_z = try allocator.dupeZ(u8, repo_name);
    defer allocator.free(repo_name_z);
    
    var repo: ?*libgit2.git_repository = null;
    const open_result = libgit2.git_repository_open(&repo, repo_name_z.ptr);
    if (open_result != 0) {
        return TestError.LibGit2Error;
    }
    defer libgit2.git_repository_free(repo);
    
    const start = std.time.nanoTimestamp();
    
    var status_list: ?*libgit2.git_status_list = null;
    const status_result = libgit2.git_status_list_new(&status_list, repo, null);
    if (status_result != 0) {
        return TestError.LibGit2Error;
    }
    defer libgit2.git_status_list_free(status_list);
    
    _ = libgit2.git_status_list_entrycount(status_list);
    
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
    print("=== Full Git Implementation Benchmark ===\n\n", .{});
    print("Comparing: Git CLI vs Ziggit Library vs libgit2\n", .{});
    print("All times shown as mean ± range.\n\n", .{});
    
    // Initialize libgit2
    _ = libgit2.git_libgit2_init();
    defer _ = libgit2.git_libgit2_shutdown();
    
    const iterations = 100;
    
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
    
    const libgit2_init_result = runBenchmark(
        "libgit2 init",
        benchLibgit2Init,
        .{"/tmp/test-repo-libgit2"},
        iterations
    ) catch |err| {
        print("libgit2 init benchmark failed: {any}\n", .{err});
        return;
    };
    try results.append(libgit2_init_result);
    
    // Test 2: Repository status operations
    print("\n2. Status Operations\n", .{});
    
    // Setup repositories for status testing
    _ = runCommand(&[_][]const u8{ "git", "-C", "/tmp", "init", "status-test-git", "--quiet" }) catch {};
    _ = ziggit.ziggit_repo_init("/tmp/status-test-ziggit", 0);
    var libgit2_repo: ?*libgit2.git_repository = null;
    _ = libgit2.git_repository_init(&libgit2_repo, "/tmp/status-test-libgit2", 0);
    libgit2.git_repository_free(libgit2_repo);
    
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
    
    const libgit2_status_result = runBenchmark(
        "libgit2 status",
        benchLibgit2Status,
        .{"/tmp/status-test-libgit2"},
        iterations
    ) catch |err| {
        print("libgit2 status benchmark failed: {any}\n", .{err});
        return;
    };
    try results.append(libgit2_status_result);
    
    // Print comprehensive results
    print("\n=== BENCHMARK RESULTS ===\n", .{});
    print("  Operation                 | Mean Time (±Range)\n", .{});
    print("  --------------------------|--------------------\n", .{});
    
    for (results.items) |result| {
        result.display();
    }
    
    // Performance comparison
    print("\n=== PERFORMANCE COMPARISON ===\n", .{});
    
    if (results.items.len >= 6) {
        const git_init_time = results.items[0].mean_ns;
        const ziggit_init_time = results.items[1].mean_ns;
        const libgit2_init_time = results.items[2].mean_ns;
        const git_status_time = results.items[3].mean_ns;
        const ziggit_status_time = results.items[4].mean_ns;
        const libgit2_status_time = results.items[5].mean_ns;
        
        print("Init Comparison:\n", .{});
        var fastest_init = git_init_time;
        if (ziggit_init_time < fastest_init) fastest_init = ziggit_init_time;
        if (libgit2_init_time < fastest_init) fastest_init = libgit2_init_time;
        if (fastest_init == ziggit_init_time) {
            print("  ziggit wins! ", .{});
            if (git_init_time > ziggit_init_time) {
                const speedup = @as(f64, @floatFromInt(git_init_time)) / @as(f64, @floatFromInt(ziggit_init_time));
                print("{d:.2}x faster than git, ", .{speedup});
            }
            if (libgit2_init_time > ziggit_init_time) {
                const speedup = @as(f64, @floatFromInt(libgit2_init_time)) / @as(f64, @floatFromInt(ziggit_init_time));
                print("{d:.2}x faster than libgit2", .{speedup});
            }
            print("\n", .{});
        } else if (fastest_init == libgit2_init_time) {
            print("  libgit2 wins! ", .{});
            const git_slowdown = @as(f64, @floatFromInt(git_init_time)) / @as(f64, @floatFromInt(libgit2_init_time));
            const ziggit_slowdown = @as(f64, @floatFromInt(ziggit_init_time)) / @as(f64, @floatFromInt(libgit2_init_time));
            print("{d:.2}x faster than git, {d:.2}x faster than ziggit\n", .{git_slowdown, ziggit_slowdown});
        } else {
            print("  git wins! (unexpected)\n", .{});
        }
        
        print("Status Comparison:\n", .{});
        var fastest_status = git_status_time;
        if (ziggit_status_time < fastest_status) fastest_status = ziggit_status_time;
        if (libgit2_status_time < fastest_status) fastest_status = libgit2_status_time;
        if (fastest_status == ziggit_status_time) {
            print("  ziggit wins! ", .{});
            if (git_status_time > ziggit_status_time) {
                const speedup = @as(f64, @floatFromInt(git_status_time)) / @as(f64, @floatFromInt(ziggit_status_time));
                print("{d:.2}x faster than git, ", .{speedup});
            }
            if (libgit2_status_time > ziggit_status_time) {
                const speedup = @as(f64, @floatFromInt(libgit2_status_time)) / @as(f64, @floatFromInt(ziggit_status_time));
                print("{d:.2}x faster than libgit2", .{speedup});
            }
            print("\n", .{});
        } else if (fastest_status == libgit2_status_time) {
            print("  libgit2 wins! ", .{});
            const git_slowdown = @as(f64, @floatFromInt(git_status_time)) / @as(f64, @floatFromInt(libgit2_status_time));
            const ziggit_slowdown = @as(f64, @floatFromInt(ziggit_status_time)) / @as(f64, @floatFromInt(libgit2_status_time));
            print("{d:.2}x faster than git, {d:.2}x faster than ziggit\n", .{git_slowdown, ziggit_slowdown});
        } else {
            print("  git wins! (unexpected)\n", .{});
        }
    }
    
    // Cleanup
    print("\nCleaning up...\n", .{});
    cleanup("test-repo-git");
    cleanup("test-repo-ziggit");
    cleanup("test-repo-libgit2");
    cleanup("status-test-git");
    cleanup("status-test-ziggit");
    cleanup("status-test-libgit2");
    
    print("Full benchmark complete!\n", .{});
}