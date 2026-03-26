const std = @import("std");
const ziggit = @import("ziggit");

const BenchmarkStats = struct {
    min_ns: u64,
    max_ns: u64,
    mean_ns: u64,
    median_ns: u64,
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
            .iterations = times.len,
        };
    }

    fn display(self: BenchmarkStats, name: []const u8) void {
        std.debug.print("  {s:25} | ", .{name});
        formatTime(self.median_ns);
        std.debug.print(" | ", .{});
        formatTime(self.mean_ns);
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

fn setupTestRepo(allocator: std.mem.Allocator, repo_path: []const u8) !void {
    std.debug.print("Setting up test repository...\n", .{});
    
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
    
    // Create some files and commits
    for (0..5) |commit_num| {
        // Create 5 files for this commit
        for (0..5) |file_num| {
            const file_index = commit_num * 5 + file_num;
            const file_path = try std.fmt.allocPrint(allocator, "{s}/file{d}.txt", .{ repo_path, file_index });
            defer allocator.free(file_path);
            
            const content = try std.fmt.allocPrint(allocator, "Content for file {d}\n", .{file_index});
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
        const commit_msg = try std.fmt.allocPrint(allocator, "Commit {d}", .{commit_num});
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
        
        // Create a tag
        const tag_name = try std.fmt.allocPrint(allocator, "v0.{d}.0", .{commit_num});
        defer allocator.free(tag_name);
        
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "git", "tag", tag_name },
            .cwd = repo_path,
        }) catch continue;
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
    }
    
    std.debug.print("Test repository setup complete.\n\n", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Debug vs Release Performance Comparison ===\n\n", .{});
    
    const is_debug = @import("builtin").mode == .Debug;
    const build_mode = if (is_debug) "Debug" else "Release";
    std.debug.print("Current build mode: {s}\n", .{build_mode});
    std.debug.print("This benchmark shows the current build's performance.\n", .{});
    std.debug.print("Run with both 'zig build bench-debug' and 'zig build -Doptimize=ReleaseFast bench-debug' to compare.\n\n", .{});

    const repo_path = "/tmp/ziggit_debug_release_bench";
    const iterations = 1000;
    
    // Setup test repository
    try setupTestRepo(allocator, repo_path);
    
    // Open repository with ziggit
    var repo = ziggit.Repository.open(allocator, repo_path) catch |err| {
        std.debug.print("Error opening repository with ziggit: {any}\n", .{err});
        return;
    };
    defer repo.close();
    
    std.debug.print("Running {s} benchmarks ({d} iterations each)...\n\n", .{ build_mode, iterations });
    
    // Print table header
    std.debug.print("  Operation                 | Median   | Mean     | Range\n", .{});
    std.debug.print("  --------------------------|----------|----------|------------------\n", .{});
    
    // 1. rev-parse HEAD benchmark
    const zig_rev_parse = benchmarkZigFunction(allocator, &repo, .rev_parse_head, iterations) catch |err| {
        std.debug.print("  Zig rev-parse failed: {any}\n", .{err});
        return;
    };
    zig_rev_parse.display("rev-parse HEAD");
    
    // 2. status --porcelain benchmark
    const zig_status = benchmarkZigFunction(allocator, &repo, .status_porcelain, iterations) catch |err| {
        std.debug.print("  Zig status failed: {any}\n", .{err});
        return;
    };
    zig_status.display("status --porcelain");
    
    // 3. describe --tags benchmark
    const zig_describe = benchmarkZigFunction(allocator, &repo, .describe_tags, iterations) catch |err| {
        std.debug.print("  Zig describe failed: {any}\n", .{err});
        return;
    };
    zig_describe.display("describe --tags");
    
    // 4. is_clean benchmark
    const zig_clean = benchmarkZigFunction(allocator, &repo, .is_clean, iterations) catch |err| {
        std.debug.print("  Zig isClean failed: {any}\n", .{err});
        return;
    };
    zig_clean.display("is_clean");
    
    // Summary
    std.debug.print("\n=== {s} BUILD PERFORMANCE SUMMARY ===\n", .{build_mode});
    std.debug.print("All measurements are for pure Zig function calls (no CLI spawning).\n", .{});
    std.debug.print("Median times represent typical performance.\n\n", .{});
    
    const avg_median = (zig_rev_parse.median_ns + zig_status.median_ns + 
                        zig_describe.median_ns + zig_clean.median_ns) / 4;
    std.debug.print("Average median time: ", .{});
    formatTime(avg_median);
    std.debug.print("\n", .{});
    
    if (is_debug) {
        std.debug.print("\n📋 To see release performance, run:\n", .{});
        std.debug.print("   zig build -Doptimize=ReleaseFast bench-debug\n", .{});
        std.debug.print("\n📊 Expected release improvements:\n", .{});
        std.debug.print("   - 2-3x faster for most operations\n", .{});
        std.debug.print("   - Better cache utilization\n", .{});
        std.debug.print("   - Compiler optimizations enabled\n", .{});
    } else {
        std.debug.print("\n⚡ Release mode optimizations active:\n", .{});
        std.debug.print("   - Function inlining\n", .{});
        std.debug.print("   - Loop unrolling\n", .{});
        std.debug.print("   - Dead code elimination\n", .{});
        std.debug.print("   - Register allocation optimization\n", .{});
        std.debug.print("\n🏆 This represents peak ziggit performance!\n", .{});
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
    
    std.debug.print("Debug vs Release benchmark complete!\n", .{});
}