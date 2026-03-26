const std = @import("std");
const time = std.time;
const process = std.process;
const ziggit = @import("ziggit");

const BenchResult = struct {
    operation: []const u8,
    git_avg_ms: f64,
    ziggit_avg_ms: f64,
    speedup: f64,
    iterations: usize,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("=== Pure Ziggit vs Git CLI Benchmark ===", .{});
    std.log.info("Using ziggit Zig API (no C library)", .{});
    std.log.info("", .{});
    
    // Create test repository with real git
    const test_repo = "pure_ziggit_bench_repo";
    const repo_path = try setupTestRepo(allocator, test_repo);
    defer allocator.free(repo_path);
    defer std.fs.cwd().deleteTree(test_repo) catch {};
    
    std.log.info("Test repository created at: {s}", .{repo_path});
    std.log.info("", .{});
    
    var results = std.ArrayList(BenchResult).init(allocator);
    defer {
        // Clean up any string allocations in results
        results.deinit();
    }
    
    const iterations: usize = 100;
    
    // Benchmark critical operations using pure Zig API
    try results.append(try benchmarkStatusPorcelain(allocator, repo_path, iterations));
    try results.append(try benchmarkRevParseHead(allocator, repo_path, iterations));
    try results.append(try benchmarkDescribeTags(allocator, repo_path, iterations));
    
    // Print results
    printResults(results.items);
}

fn setupTestRepo(allocator: std.mem.Allocator, repo_dir: []const u8) ![]const u8 {
    // Clean up existing repo
    std.fs.cwd().deleteTree(repo_dir) catch {};
    
    // Get absolute path
    var cwd_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const cwd = try std.process.getCwd(&cwd_buf);
    const repo_path = try std.fs.path.resolve(allocator, &[_][]const u8{ cwd, repo_dir });
    
    // Create directory and initialize git repo
    try std.fs.cwd().makeDir(repo_dir);
    
    const original_cwd = try allocator.dupe(u8, cwd);
    defer allocator.free(original_cwd);
    
    try std.posix.chdir(repo_path);
    defer std.posix.chdir(original_cwd) catch {};
    
    // Initialize git repository
    _ = try runCommand(allocator, &[_][]const u8{ "git", "init", "-q" });
    _ = try runCommand(allocator, &[_][]const u8{ "git", "config", "user.name", "Bench" });
    _ = try runCommand(allocator, &[_][]const u8{ "git", "config", "user.email", "bench@test.com" });
    
    // Create some files
    try std.fs.cwd().writeFile(.{ .sub_path = "package.json", .data = 
        \\{
        \\  "name": "test-project",
        \\  "version": "1.0.0"
        \\}
        \\
    });
    try std.fs.cwd().makeDir("src");
    try std.fs.cwd().writeFile(.{ .sub_path = "src/main.ts", .data = "console.log('hello');\n" });
    
    // Add and commit
    _ = try runCommand(allocator, &[_][]const u8{ "git", "add", "." });
    _ = try runCommand(allocator, &[_][]const u8{ "git", "commit", "-m", "Initial", "-q" });
    
    // Create a tag
    _ = try runCommand(allocator, &[_][]const u8{ "git", "tag", "v1.0.0" });
    
    return repo_path;
}

fn benchmarkStatusPorcelain(allocator: std.mem.Allocator, repo_path: []const u8, iterations: usize) !BenchResult {
    std.log.info("Benchmarking status --porcelain...", .{});
    
    // Benchmark git CLI
    const git_start = time.nanoTimestamp();
    for (0..iterations) |_| {
        _ = try runGitCommand(allocator, repo_path, &[_][]const u8{ "git", "status", "--porcelain" });
    }
    const git_end = time.nanoTimestamp();
    const git_total_ns = @as(f64, @floatFromInt(git_end - git_start));
    const git_avg_ms = git_total_ns / @as(f64, @floatFromInt(iterations)) / 1_000_000.0;
    
    // Benchmark ziggit using Zig API
    const ziggit_start = time.nanoTimestamp();
    for (0..iterations) |_| {
        var repo = ziggit.repo_open(allocator, repo_path) catch continue;
        const status = ziggit.repo_status(&repo, allocator) catch {
            allocator.free(try allocator.alloc(u8, 1024));
            continue;
        };
        allocator.free(status);
    }
    const ziggit_end = time.nanoTimestamp();
    const ziggit_total_ns = @as(f64, @floatFromInt(ziggit_end - ziggit_start));
    const ziggit_avg_ms = ziggit_total_ns / @as(f64, @floatFromInt(iterations)) / 1_000_000.0;
    
    const speedup = git_avg_ms / ziggit_avg_ms;
    
    return BenchResult{
        .operation = "status --porcelain",
        .git_avg_ms = git_avg_ms,
        .ziggit_avg_ms = ziggit_avg_ms,
        .speedup = speedup,
        .iterations = iterations,
    };
}

fn benchmarkRevParseHead(allocator: std.mem.Allocator, repo_path: []const u8, iterations: usize) !BenchResult {
    std.log.info("Benchmarking rev-parse HEAD...", .{});
    
    // Benchmark git CLI
    const git_start = time.nanoTimestamp();
    for (0..iterations) |_| {
        _ = try runGitCommand(allocator, repo_path, &[_][]const u8{ "git", "rev-parse", "HEAD" });
    }
    const git_end = time.nanoTimestamp();
    const git_total_ns = @as(f64, @floatFromInt(git_end - git_start));
    const git_avg_ms = git_total_ns / @as(f64, @floatFromInt(iterations)) / 1_000_000.0;
    
    // Benchmark ziggit using Zig API
    const ziggit_start = time.nanoTimestamp();
    for (0..iterations) |_| {
        var repo = ziggit.repo_open(allocator, repo_path) catch continue;
        const commit_hash = ziggit.repo_rev_parse_head(&repo, allocator) catch {
            allocator.free(try allocator.alloc(u8, 41));
            continue;
        };
        allocator.free(commit_hash);
    }
    const ziggit_end = time.nanoTimestamp();
    const ziggit_total_ns = @as(f64, @floatFromInt(ziggit_end - ziggit_start));
    const ziggit_avg_ms = ziggit_total_ns / @as(f64, @floatFromInt(iterations)) / 1_000_000.0;
    
    const speedup = git_avg_ms / ziggit_avg_ms;
    
    return BenchResult{
        .operation = "rev-parse HEAD",
        .git_avg_ms = git_avg_ms,
        .ziggit_avg_ms = ziggit_avg_ms,
        .speedup = speedup,
        .iterations = iterations,
    };
}

fn benchmarkDescribeTags(allocator: std.mem.Allocator, repo_path: []const u8, iterations: usize) !BenchResult {
    std.log.info("Benchmarking describe --tags...", .{});
    
    // Benchmark git CLI
    const git_start = time.nanoTimestamp();
    for (0..iterations) |_| {
        _ = runGitCommand(allocator, repo_path, &[_][]const u8{ "git", "describe", "--tags", "--abbrev=0" }) catch {
            // Ignore errors
        };
    }
    const git_end = time.nanoTimestamp();
    const git_total_ns = @as(f64, @floatFromInt(git_end - git_start));
    const git_avg_ms = git_total_ns / @as(f64, @floatFromInt(iterations)) / 1_000_000.0;
    
    // Benchmark ziggit using Zig API  
    const ziggit_start = time.nanoTimestamp();
    for (0..iterations) |_| {
        var repo = ziggit.repo_open(allocator, repo_path) catch continue;
        const tag = ziggit.repo_describe_tags(&repo, allocator) catch {
            allocator.free(try allocator.alloc(u8, 256));
            continue;
        };
        allocator.free(tag);
    }
    const ziggit_end = time.nanoTimestamp();
    const ziggit_total_ns = @as(f64, @floatFromInt(ziggit_end - ziggit_start));
    const ziggit_avg_ms = ziggit_total_ns / @as(f64, @floatFromInt(iterations)) / 1_000_000.0;
    
    const speedup = git_avg_ms / ziggit_avg_ms;
    
    return BenchResult{
        .operation = "describe --tags",
        .git_avg_ms = git_avg_ms,
        .ziggit_avg_ms = ziggit_avg_ms,
        .speedup = speedup,
        .iterations = iterations,
    };
}

fn printResults(results: []BenchResult) void {
    std.log.info("=== BENCHMARK RESULTS ===", .{});
    std.log.info("", .{});
    std.log.info("Operation                    | Git CLI  | Ziggit   | Speedup  | Iterations", .{});
    std.log.info("----------------------------|----------|----------|----------|----------", .{});
    
    for (results) |result| {
        std.log.info("{s: <27} | {d: >6.2}ms | {d: >6.2}ms | {d: >6.1}x  | {d}", .{
            result.operation,
            result.git_avg_ms,
            result.ziggit_avg_ms,
            result.speedup,
            result.iterations,
        });
    }
    
    std.log.info("", .{});
    
    // Calculate overall speedup
    var total_git_ms: f64 = 0;
    var total_ziggit_ms: f64 = 0;
    
    for (results) |result| {
        total_git_ms += result.git_avg_ms;
        total_ziggit_ms += result.ziggit_avg_ms;
    }
    
    const overall_speedup = total_git_ms / total_ziggit_ms;
    std.log.info("Overall speedup: {d:.1}x faster than git CLI", .{overall_speedup});
    std.log.info("Time saved per operation: {d:.2}ms", .{(total_git_ms - total_ziggit_ms) / @as(f64, @floatFromInt(results.len))});
}

fn runCommand(allocator: std.mem.Allocator, args: []const []const u8) ![]u8 {
    var child = process.Child.init(args, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    
    try child.spawn();
    
    const stdout = try child.stdout.?.reader().readAllAlloc(allocator, 8192);
    const stderr = try child.stderr.?.reader().readAllAlloc(allocator, 8192);
    defer allocator.free(stderr);
    
    const term = try child.wait();
    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                allocator.free(stdout);
                return error.CommandFailed;
            }
        },
        else => {
            allocator.free(stdout);
            return error.CommandFailed;
        },
    }
    
    return stdout;
}

fn runGitCommand(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) ![]u8 {
    var child = process.Child.init(args, allocator);
    child.cwd = cwd;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    
    try child.spawn();
    
    const stdout = try child.stdout.?.reader().readAllAlloc(allocator, 8192);
    const stderr = try child.stderr.?.reader().readAllAlloc(allocator, 8192);
    defer allocator.free(stderr);
    
    const term = try child.wait();
    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                allocator.free(stdout);
                return error.CommandFailed;
            }
        },
        else => {
            allocator.free(stdout);
            return error.CommandFailed;
        },
    }
    
    return stdout;
}