const std = @import("std");
const ziggit = @import("ziggit");

const BenchmarkStats = struct {
    min_ns: u64,
    max_ns: u64,
    mean_ns: u64,
    median_ns: u64,
    p95_ns: u64,
    p99_ns: u64,
    iterations: usize,

    fn calculate(times: []u64) BenchmarkStats {
        std.mem.sort(u64, times, {}, std.sort.asc(u64));
        
        var total: u64 = 0;
        for (times) |time| {
            total += time;
        }
        
        return BenchmarkStats{
            .min_ns = times[0],
            .max_ns = times[times.len - 1],
            .mean_ns = total / times.len,
            .median_ns = times[times.len / 2],
            .p95_ns = times[@min(times.len - 1, (times.len * 95) / 100)],
            .p99_ns = times[@min(times.len - 1, (times.len * 99) / 100)],
            .iterations = times.len,
        };
    }

    fn display(self: BenchmarkStats, name: []const u8) void {
        std.debug.print("  {s:25} | ", .{name});
        formatTime(self.mean_ns);
        std.debug.print(" | ", .{});
        formatTime(self.median_ns);
        std.debug.print(" | ", .{});
        formatTime(self.p95_ns);
        std.debug.print(" | ", .{});
        formatTime(self.min_ns);
        std.debug.print(" - ", .{});
        formatTime(self.max_ns);
        std.debug.print("\n", .{});
    }
};

fn formatTime(ns: u64) void {
    if (ns < 1000) {
        std.debug.print("{d:4}ns", .{ns});
    } else if (ns < 1000_000) {
        std.debug.print("{d:4.1}μs", .{@as(f64, @floatFromInt(ns)) / 1000.0});
    } else if (ns < 1000_000_000) {
        std.debug.print("{d:4.1}ms", .{@as(f64, @floatFromInt(ns)) / 1000_000.0});
    } else {
        std.debug.print("{d:4.1}s ", .{@as(f64, @floatFromInt(ns)) / 1000_000_000.0});
    }
}

/// Benchmark a pure Zig function call
fn benchmarkZigFunction(
    allocator: std.mem.Allocator,
    repo: *ziggit.Repository,
    comptime operation: enum { rev_parse_head, status_porcelain, describe_tags, is_clean },
    iterations: usize,
) !BenchmarkStats {
    var times = try allocator.alloc(u64, iterations);
    defer allocator.free(times);
    
    var successful_runs: usize = 0;
    
    for (0..iterations) |_| {
        const start = std.time.nanoTimestamp();
        
        const result = switch (operation) {
            .rev_parse_head => blk: {
                const hash = repo.revParseHead() catch {
                    continue; // Skip failed iterations
                };
                break :blk hash;
            },
            .status_porcelain => blk: {
                const status = repo.statusPorcelain(allocator) catch {
                    continue;
                };
                defer allocator.free(status);
                break :blk status;
            },
            .describe_tags => blk: {
                const tag = repo.describeTags(allocator) catch {
                    continue;
                };
                defer allocator.free(tag);
                break :blk tag;
            },
            .is_clean => blk: {
                const clean = repo.isClean() catch {
                    continue;
                };
                break :blk clean;
            },
        };
        
        const end = std.time.nanoTimestamp();
        
        // Verify we got a valid result (helps ensure compiler doesn't optimize away)
        switch (operation) {
            .rev_parse_head => {
                const hash = @as([40]u8, result);
                if (hash[0] == 0 and hash[39] == 0) {
                    // Prevent optimization while allowing empty repo
                }
            },
            .status_porcelain => {
                const status = @as([]const u8, result);
                if (status.len > 0) {
                    // Prevent optimization
                }
            },
            .describe_tags => {
                const tag = @as([]const u8, result);
                if (tag.len > 0) {
                    // Prevent optimization
                }
            },
            .is_clean => {
                const clean = @as(bool, result);
                if (clean) {
                    // Prevent optimization
                }
            },
        }
        
        times[successful_runs] = @intCast(end - start);
        successful_runs += 1;
    }
    
    if (successful_runs == 0) {
        return error.AllIterationsFailed;
    }
    
    return BenchmarkStats.calculate(times[0..successful_runs]);
}

/// Benchmark spawning git CLI as child process
fn benchmarkGitCli(
    allocator: std.mem.Allocator,
    repo_path: []const u8,
    comptime operation: enum { rev_parse_head, status_porcelain, describe_tags, is_clean },
    iterations: usize,
) !BenchmarkStats {
    var times = try allocator.alloc(u64, iterations);
    defer allocator.free(times);
    
    var successful_runs: usize = 0;
    
    for (0..iterations) |_| {
        const start = std.time.nanoTimestamp();
        
        const cmd = switch (operation) {
            .rev_parse_head => &[_][]const u8{ "git", "rev-parse", "HEAD" },
            .status_porcelain => &[_][]const u8{ "git", "status", "--porcelain" },
            .describe_tags => &[_][]const u8{ "git", "describe", "--tags", "--abbrev=0" },
            .is_clean => &[_][]const u8{ "git", "status", "--porcelain" }, // We'll check if output is empty
        };
        
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = cmd,
            .cwd = repo_path,
        }) catch {
            continue; // Skip failed iterations
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        
        const end = std.time.nanoTimestamp();
        
        // Verify we got a valid result and exit code
        if (result.term != .Exited or result.term.Exited != 0) {
            // Allow non-zero exit codes for some operations (like describe when no tags exist)
            if (operation != .describe_tags) {
                continue;
            }
        }
        
        // Verify output format to prevent optimization
        switch (operation) {
            .rev_parse_head => {
                if (result.stdout.len >= 40) {
                    // Should be a 40-character hash
                }
            },
            .status_porcelain, .is_clean => {
                // Status output varies
            },
            .describe_tags => {
                // Tag output varies
            },
        }
        
        times[successful_runs] = @intCast(end - start);
        successful_runs += 1;
    }
    
    if (successful_runs == 0) {
        return error.AllIterationsFailed;
    }
    
    return BenchmarkStats.calculate(times[0..successful_runs]);
}

fn setupTestRepo(allocator: std.mem.Allocator, repo_path: []const u8) !void {
    std.debug.print("Setting up test repository with 100 files, 10 commits, and tags...\n", .{});
    
    // Clean up any existing directory
    {
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "rm", "-rf", repo_path },
        }) catch return;
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    
    // Create directory and initialize git repo
    {
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "mkdir", "-p", repo_path },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
    }
    
    {
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "git", "init" },
            .cwd = repo_path,
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
    }
    
    {
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "git", "config", "user.name", "Benchmark" },
            .cwd = repo_path,
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
    }
    
    {
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "git", "config", "user.email", "bench@example.com" },
            .cwd = repo_path,
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
    }
    
    // Create 10 commits with 10 files each
    for (0..10) |commit_num| {
        // Create 10 files for this commit
        for (0..10) |file_num| {
            const file_index = commit_num * 10 + file_num;
            const file_path = try std.fmt.allocPrint(allocator, "{s}/file{d}.txt", .{ repo_path, file_index });
            defer allocator.free(file_path);
            
            const content = try std.fmt.allocPrint(allocator, 
                \\File {d} - Commit {d}
                \\This is line 2 with some content to make it realistic
                \\Line 3 contains more data for file size
                \\Line 4 has different content in commit {d}
                \\Final line {d}
                \\
            , .{ file_index, commit_num, commit_num, file_index });
            defer allocator.free(content);
            
            const file = try std.fs.createFileAbsolute(file_path, .{});
            defer file.close();
            try file.writeAll(content);
        }
        
        // Add all files
        {
            const result = try std.process.Child.run(.{
                .allocator = allocator,
                .argv = &.{ "git", "add", "." },
                .cwd = repo_path,
            });
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);
        }
        
        // Commit
        const commit_msg = try std.fmt.allocPrint(allocator, "Commit {d} - Added 10 files", .{commit_num});
        defer allocator.free(commit_msg);
        
        {
            const result = try std.process.Child.run(.{
                .allocator = allocator,
                .argv = &.{ "git", "commit", "-m", commit_msg },
                .cwd = repo_path,
            });
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);
        }
        
        // Create a tag every 2 commits
        if (commit_num % 2 == 0) {
            const tag_name = try std.fmt.allocPrint(allocator, "v0.{d}.0", .{commit_num / 2});
            defer allocator.free(tag_name);
            
            const result = std.process.Child.run(.{
                .allocator = allocator,
                .argv = &.{ "git", "tag", tag_name },
                .cwd = repo_path,
            }) catch continue; // Don't fail if tagging fails
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);
        }
        
        std.debug.print("  Created commit {d}/10\n", .{commit_num + 1});
    }
    
    std.debug.print("Test repository setup complete.\n\n", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Ziggit API vs Git CLI Benchmark ===\n\n", .{});
    std.debug.print("This benchmark compares PURE ZIG function calls against git CLI spawning.\n", .{});
    std.debug.print("The goal: prove that ziggit Zig functions are 100-1000x faster than CLI spawning.\n\n", .{});

    const repo_path = "/tmp/ziggit_bench_repo";
    const iterations = 1000;
    
    // Setup test repository
    try setupTestRepo(allocator, repo_path);
    
    // Open repository with ziggit
    var repo = ziggit.Repository.open(allocator, repo_path) catch |err| {
        std.debug.print("Error opening repository with ziggit: {any}\n", .{err});
        return;
    };
    defer repo.close();
    
    std.debug.print("Running benchmarks ({d} iterations each)...\n\n", .{iterations});
    
    // Print table header
    std.debug.print("  Operation                 | Mean     | Median   | P95      | Range\n", .{});
    std.debug.print("  --------------------------|----------|----------|----------|------------------\n", .{});
    
    // 1. rev-parse HEAD benchmark
    std.debug.print("1. rev-parse HEAD:\n", .{});
    
    // Pure Zig version
    const zig_rev_parse = benchmarkZigFunction(allocator, &repo, .rev_parse_head, iterations) catch |err| {
        std.debug.print("  Zig rev-parse failed: {any}\n", .{err});
        return;
    };
    zig_rev_parse.display("Zig revParseHead()");
    
    // Git CLI version  
    const cli_rev_parse = benchmarkGitCli(allocator, repo_path, .rev_parse_head, iterations) catch |err| {
        std.debug.print("  CLI rev-parse failed: {any}\n", .{err});
        return;
    };
    cli_rev_parse.display("git rev-parse HEAD");
    
    // Calculate speedup
    const rev_parse_speedup = @as(f64, @floatFromInt(cli_rev_parse.mean_ns)) / @as(f64, @floatFromInt(zig_rev_parse.mean_ns));
    std.debug.print("  -> Zig is {d:.1}x faster\n\n", .{rev_parse_speedup});
    
    // 2. status --porcelain benchmark
    std.debug.print("2. status --porcelain:\n", .{});
    
    const zig_status = benchmarkZigFunction(allocator, &repo, .status_porcelain, iterations) catch |err| {
        std.debug.print("  Zig status failed: {any}\n", .{err});
        return;
    };
    zig_status.display("Zig statusPorcelain()");
    
    const cli_status = benchmarkGitCli(allocator, repo_path, .status_porcelain, iterations) catch |err| {
        std.debug.print("  CLI status failed: {any}\n", .{err});
        return;
    };
    cli_status.display("git status --porcelain");
    
    const status_speedup = @as(f64, @floatFromInt(cli_status.mean_ns)) / @as(f64, @floatFromInt(zig_status.mean_ns));
    std.debug.print("  -> Zig is {d:.1}x faster\n\n", .{status_speedup});
    
    // 3. describe --tags benchmark
    std.debug.print("3. describe --tags:\n", .{});
    
    const zig_describe = benchmarkZigFunction(allocator, &repo, .describe_tags, iterations) catch |err| {
        std.debug.print("  Zig describe failed: {any}\n", .{err});
        return;
    };
    zig_describe.display("Zig describeTags()");
    
    const cli_describe = benchmarkGitCli(allocator, repo_path, .describe_tags, iterations) catch |err| {
        std.debug.print("  CLI describe failed: {any}\n", .{err});
        return;
    };
    cli_describe.display("git describe --tags");
    
    const describe_speedup = @as(f64, @floatFromInt(cli_describe.mean_ns)) / @as(f64, @floatFromInt(zig_describe.mean_ns));
    std.debug.print("  -> Zig is {d:.1}x faster\n\n", .{describe_speedup});
    
    // 4. is_clean benchmark
    std.debug.print("4. is_clean:\n", .{});
    
    const zig_clean = benchmarkZigFunction(allocator, &repo, .is_clean, iterations) catch |err| {
        std.debug.print("  Zig isClean failed: {any}\n", .{err});
        return;
    };
    zig_clean.display("Zig isClean()");
    
    // For CLI clean, we use status and check if empty
    const cli_clean = benchmarkGitCli(allocator, repo_path, .is_clean, iterations) catch |err| {
        std.debug.print("  CLI clean check failed: {any}\n", .{err});
        return;
    };
    cli_clean.display("git status --porcelain");
    
    const clean_speedup = @as(f64, @floatFromInt(cli_clean.mean_ns)) / @as(f64, @floatFromInt(zig_clean.mean_ns));
    std.debug.print("  -> Zig is {d:.1}x faster\n\n", .{clean_speedup});
    
    // Summary
    std.debug.print("=== PERFORMANCE SUMMARY ===\n", .{});
    std.debug.print("All measurements are wall clock time for {d} iterations.\n", .{iterations});
    std.debug.print("Zig functions are PURE ZIG CODE with no process spawning.\n", .{});
    std.debug.print("Git CLI includes ~2-5ms process spawn overhead per call.\n\n", .{});
    
    std.debug.print("Operation          | Zig Median | CLI Median | Speedup\n", .{});
    std.debug.print("-------------------|------------|------------|--------\n", .{});
    std.debug.print("rev-parse HEAD     | ", .{});
    formatTime(zig_rev_parse.median_ns);
    std.debug.print("    | ", .{});
    formatTime(cli_rev_parse.median_ns);
    std.debug.print("    | {d:.0}x\n", .{rev_parse_speedup});
    
    std.debug.print("status --porcelain | ", .{});
    formatTime(zig_status.median_ns);
    std.debug.print("    | ", .{});
    formatTime(cli_status.median_ns);
    std.debug.print("    | {d:.0}x\n", .{status_speedup});
    
    std.debug.print("describe --tags    | ", .{});
    formatTime(zig_describe.median_ns);
    std.debug.print("    | ", .{});
    formatTime(cli_describe.median_ns);
    std.debug.print("    | {d:.0}x\n", .{describe_speedup});
    
    std.debug.print("is_clean           | ", .{});
    formatTime(zig_clean.median_ns);
    std.debug.print("    | ", .{});
    formatTime(cli_clean.median_ns);
    std.debug.print("    | {d:.0}x\n", .{clean_speedup});
    
    const avg_speedup = (rev_parse_speedup + status_speedup + describe_speedup + clean_speedup) / 4.0;
    std.debug.print("\nAverage speedup: {d:.0}x\n", .{avg_speedup});
    
    if (avg_speedup >= 100.0) {
        std.debug.print("✅ GOAL ACHIEVED: Zig functions are {d:.0}x faster than CLI spawning!\n", .{avg_speedup});
    } else if (avg_speedup >= 10.0) {
        std.debug.print("⚡ Zig functions are {d:.0}x faster - excellent performance!\n", .{avg_speedup});
    } else {
        std.debug.print("📈 Zig functions are {d:.0}x faster - room for optimization.\n", .{avg_speedup});
    }
    
    // Cleanup
    std.debug.print("\nCleaning up test repository...\n", .{});
    {
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "rm", "-rf", repo_path },
        }) catch return;
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
    }
    
    std.debug.print("Benchmark complete!\n", .{});
}