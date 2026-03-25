const std = @import("std");
const print = std.debug.print;
const allocator = std.heap.page_allocator;
const ziggit = @import("ziggit");

const TestError = error{
    CommandFailed,
    OutOfMemory,
    InvalidUtf8,
    GitNotFound,
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
    successful_runs: usize,
    
    fn display(self: BenchmarkResult) void {
        print("  {s:25} | ", .{self.name});
        formatTime(self.mean_ns);
        print(" (±", .{});
        const range = self.max_ns - self.min_ns;
        formatTime(range);
        print(") [{d}/{d} runs]", .{self.successful_runs, self.iterations});
        print("\n", .{});
    }

    fn speedup_vs(self: BenchmarkResult, other: BenchmarkResult) f64 {
        return @as(f64, @floatFromInt(other.mean_ns)) / @as(f64, @floatFromInt(self.mean_ns));
    }
};

// Helper function to run shell commands and measure time
fn runCommand(cmd: []const []const u8, cwd: ?[]const u8) !u64 {
    const start = std.time.nanoTimestamp();
    
    var child = std.process.Child.init(cmd, allocator);
    if (cwd) |work_dir| {
        child.cwd = work_dir;
    }
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    
    const term = try child.spawnAndWait();
    if (term != .Exited or term.Exited != 0) {
        return TestError.CommandFailed;
    }
    
    const end = std.time.nanoTimestamp();
    return @intCast(end - start);
}

// Test if git is available
fn isGitAvailable() bool {
    var child = std.process.Child.init(&[_][]const u8{ "git", "--version" }, allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    
    const term = child.spawnAndWait() catch return false;
    return term == .Exited and term.Exited == 0;
}

// Git benchmark functions
fn benchGitInit(repo_path: []const u8) !u64 {
    // Clean up any existing repo
    var dir = std.fs.openDirAbsolute("/tmp", .{}) catch return TestError.CommandFailed;
    defer dir.close();
    dir.deleteTree(std.fs.path.basename(repo_path)) catch {};
    
    return runCommand(&[_][]const u8{ "git", "init", repo_path, "--quiet" }, null);
}

fn benchGitStatus(repo_path: []const u8) !u64 {
    return runCommand(&[_][]const u8{ "git", "status", "--porcelain" }, repo_path);
}

fn benchGitClone(url: []const u8, target: []const u8) !u64 {
    // Clean up any existing target
    var dir = std.fs.openDirAbsolute("/tmp", .{}) catch return TestError.CommandFailed;
    defer dir.close();
    dir.deleteTree(std.fs.path.basename(target)) catch {};
    
    return runCommand(&[_][]const u8{ "git", "clone", "--quiet", "--depth", "1", url, target }, null);
}

fn benchGitAdd(repo_path: []const u8) !u64 {
    // Create a test file first
    const test_file_path = try std.fmt.allocPrint(allocator, "{s}/test.txt", .{repo_path});
    defer allocator.free(test_file_path);
    
    var file = std.fs.createFileAbsolute(test_file_path, .{}) catch return TestError.CommandFailed;
    defer file.close();
    try file.writeAll("test content");
    
    return runCommand(&[_][]const u8{ "git", "add", "test.txt" }, repo_path);
}

// Ziggit benchmark functions
fn benchZiggitInit(repo_path: []const u8) !u64 {
    // Clean up any existing repo
    var dir = std.fs.openDirAbsolute("/tmp", .{}) catch return TestError.CommandFailed;
    defer dir.close();
    dir.deleteTree(std.fs.path.basename(repo_path)) catch {};
    
    const start = std.time.nanoTimestamp();
    
    ziggit.repo_init(repo_path, false) catch {
        return TestError.CommandFailed;
    };
    
    const end = std.time.nanoTimestamp();
    return @intCast(end - start);
}

fn benchZiggitStatus(repo_path: []const u8) !u64 {
    const start = std.time.nanoTimestamp();
    
    var repo = ziggit.repo_open(allocator, repo_path) catch {
        return TestError.CommandFailed;
    };
    
    const status_buffer = ziggit.repo_status(&repo, allocator) catch {
        return TestError.CommandFailed;
    };
    defer allocator.free(status_buffer);
    
    const end = std.time.nanoTimestamp();
    return @intCast(end - start);
}

fn benchZiggitOpen(repo_path: []const u8) !u64 {
    const start = std.time.nanoTimestamp();
    
    const repo = ziggit.repo_open(allocator, repo_path) catch {
        return TestError.CommandFailed;
    };
    _ = repo; // Use the repo to ensure it's not optimized away
    
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
    print("Running {s} ({d} iterations)", .{ name, iterations });
    
    var times = std.ArrayList(u64).init(allocator);
    defer times.deinit();
    
    var successful_runs: usize = 0;
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        if (i % 10 == 0) print(".", .{});
        
        const time_ns = @call(.auto, bench_fn, args) catch |err| {
            // Skip failed runs but don't fail the entire benchmark
            if (err == TestError.CommandFailed) {
                continue;
            }
            return err;
        };
        
        try times.append(time_ns);
        successful_runs += 1;
    }
    
    print(" done ({d} successful)\n", .{successful_runs});
    
    if (successful_runs == 0) {
        return TestError.CommandFailed;
    }
    
    // Calculate statistics
    var total_ns: u64 = 0;
    var min_ns: u64 = std.math.maxInt(u64);
    var max_ns: u64 = 0;
    
    for (times.items) |time_ns| {
        total_ns += time_ns;
        min_ns = @min(min_ns, time_ns);
        max_ns = @max(max_ns, time_ns);
    }
    
    const mean_ns = total_ns / successful_runs;
    
    return BenchmarkResult{
        .name = name,
        .mean_ns = mean_ns,
        .min_ns = min_ns,
        .max_ns = max_ns,
        .iterations = iterations,
        .successful_runs = successful_runs,
    };
}

pub fn main() !void {
    print("=== Ziggit vs Git CLI Bun Integration Benchmark ===\n\n", .{});
    print("Measuring performance of operations commonly used by Bun.\n", .{});
    print("Times shown as mean ± range.\n\n", .{});

    if (!isGitAvailable()) {
        print("ERROR: git command not found. Please install git to run this benchmark.\n", .{});
        return TestError.GitNotFound;
    }

    var results = std.ArrayList(BenchmarkResult).init(allocator);
    defer results.deinit();
    
    const iterations = 50;
    
    // Test 1: Repository initialization (core operation for bun create)
    print("1. Repository Initialization (bun create)\n", .{});
    
    const git_init_result = try runBenchmark(
        "git init",
        benchGitInit,
        .{"/tmp/bench-git-init"},
        iterations
    );
    try results.append(git_init_result);
    
    const ziggit_init_result = try runBenchmark(
        "ziggit init",
        benchZiggitInit,
        .{"/tmp/bench-ziggit-init"},
        iterations
    );
    try results.append(ziggit_init_result);
    
    // Test 2: Repository status (used by bun to check git state)
    print("\n2. Status Operations (bun git state checking)\n", .{});
    
    // Setup repositories for status testing
    _ = benchGitInit("/tmp/status-test-git") catch {};
    _ = benchZiggitInit("/tmp/status-test-ziggit") catch {};
    
    const git_status_result = try runBenchmark(
        "git status",
        benchGitStatus,
        .{"/tmp/status-test-git"},
        iterations
    );
    try results.append(git_status_result);
    
    const ziggit_status_result = try runBenchmark(
        "ziggit status",
        benchZiggitStatus,
        .{"/tmp/status-test-ziggit"},
        iterations
    );
    try results.append(ziggit_status_result);
    
    // Test 3: Repository opening (used internally by other operations)
    print("\n3. Repository Opening (internal operations)\n", .{});
    
    const ziggit_open_result = try runBenchmark(
        "ziggit open",
        benchZiggitOpen,
        .{"/tmp/status-test-ziggit"},
        iterations
    );
    try results.append(ziggit_open_result);
    
    // Test 4: Add operations (used by bun create for initial commit)
    print("\n4. Add Operations (bun create initial commit)\n", .{});
    
    const git_add_result = try runBenchmark(
        "git add",
        benchGitAdd,
        .{"/tmp/status-test-git"},
        iterations
    );
    try results.append(git_add_result);
    
    // Display results
    print("\n=== BENCHMARK RESULTS ===\n", .{});
    print("  Operation                 | Mean Time (±Range) [Success Rate]\n", .{});
    print("  --------------------------|--------------------------------------------\n", .{});
    
    for (results.items) |result| {
        result.display();
    }
    
    // Performance comparison
    print("\n=== PERFORMANCE COMPARISON ===\n", .{});
    
    // Find corresponding results for comparison
    var git_init_idx: ?usize = null;
    var ziggit_init_idx: ?usize = null;
    var git_status_idx: ?usize = null;
    var ziggit_status_idx: ?usize = null;
    
    for (results.items, 0..) |result, idx| {
        if (std.mem.eql(u8, result.name, "git init")) git_init_idx = idx;
        if (std.mem.eql(u8, result.name, "ziggit init")) ziggit_init_idx = idx;
        if (std.mem.eql(u8, result.name, "git status")) git_status_idx = idx;
        if (std.mem.eql(u8, result.name, "ziggit status")) ziggit_status_idx = idx;
    }
    
    if (git_init_idx != null and ziggit_init_idx != null) {
        const speedup = results.items[ziggit_init_idx.?].speedup_vs(results.items[git_init_idx.?]);
        print("Init: ziggit is {d:.2}x faster\n", .{speedup});
    }
    
    if (git_status_idx != null and ziggit_status_idx != null) {
        const speedup = results.items[ziggit_status_idx.?].speedup_vs(results.items[git_status_idx.?]);
        print("Status: ziggit is {d:.2}x faster\n", .{speedup});
    }
    
    // Cleanup
    print("\nCleaning up...\n", .{});
    var tmp_dir = std.fs.openDirAbsolute("/tmp", .{}) catch return;
    defer tmp_dir.close();
    
    tmp_dir.deleteTree("bench-git-init") catch {};
    tmp_dir.deleteTree("bench-ziggit-init") catch {};
    tmp_dir.deleteTree("status-test-git") catch {};
    tmp_dir.deleteTree("status-test-ziggit") catch {};
    
    print("Benchmark complete!\n", .{});
}