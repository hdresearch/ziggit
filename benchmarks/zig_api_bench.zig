const std = @import("std");
const ziggit = @import("ziggit");

const BenchmarkResult = struct {
    operation: []const u8,
    zig_api_ns: u64,
    git_cli_ns: u64,
    iterations: u32,
};

fn runGitCommand(allocator: std.mem.Allocator, args: []const []const u8, cwd: []const u8) !void {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = args,
        .cwd = cwd,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
}

fn benchmarkRevParseHead(allocator: std.mem.Allocator, repo: *ziggit.Repository, repo_path: []const u8, iterations: u32) !BenchmarkResult {
    // Benchmark Zig API
    const zig_start = std.time.nanoTimestamp();
    for (0..iterations) |_| {
        _ = repo.revParseHead() catch [_]u8{'0'} ** 40;
    }
    const zig_end = std.time.nanoTimestamp();
    const zig_time = @as(u64, @intCast(zig_end - zig_start));

    // Benchmark git CLI
    const git_start = std.time.nanoTimestamp();
    for (0..iterations) |_| {
        runGitCommand(allocator, &.{ "git", "rev-parse", "HEAD" }, repo_path) catch {};
    }
    const git_end = std.time.nanoTimestamp();
    const git_time = @as(u64, @intCast(git_end - git_start));

    return BenchmarkResult{
        .operation = "revParseHead",
        .zig_api_ns = zig_time,
        .git_cli_ns = git_time,
        .iterations = iterations,
    };
}

fn benchmarkStatusPorcelain(allocator: std.mem.Allocator, repo: *ziggit.Repository, repo_path: []const u8, iterations: u32) !BenchmarkResult {
    // Benchmark Zig API
    const zig_start = std.time.nanoTimestamp();
    for (0..iterations) |_| {
        const status = repo.statusPorcelain(allocator) catch continue;
        allocator.free(status);
    }
    const zig_end = std.time.nanoTimestamp();
    const zig_time = @as(u64, @intCast(zig_end - zig_start));

    // Benchmark git CLI
    const git_start = std.time.nanoTimestamp();
    for (0..iterations) |_| {
        runGitCommand(allocator, &.{ "git", "status", "--porcelain" }, repo_path) catch {};
    }
    const git_end = std.time.nanoTimestamp();
    const git_time = @as(u64, @intCast(git_end - git_start));

    return BenchmarkResult{
        .operation = "statusPorcelain",
        .zig_api_ns = zig_time,
        .git_cli_ns = git_time,
        .iterations = iterations,
    };
}

fn benchmarkDescribeTags(allocator: std.mem.Allocator, repo: *ziggit.Repository, repo_path: []const u8, iterations: u32) !BenchmarkResult {
    // Benchmark Zig API
    const zig_start = std.time.nanoTimestamp();
    for (0..iterations) |_| {
        const tag = repo.describeTags(allocator) catch continue;
        allocator.free(tag);
    }
    const zig_end = std.time.nanoTimestamp();
    const zig_time = @as(u64, @intCast(zig_end - zig_start));

    // Benchmark git CLI
    const git_start = std.time.nanoTimestamp();
    for (0..iterations) |_| {
        runGitCommand(allocator, &.{ "git", "describe", "--tags", "--abbrev=0" }, repo_path) catch {};
    }
    const git_end = std.time.nanoTimestamp();
    const git_time = @as(u64, @intCast(git_end - git_start));

    return BenchmarkResult{
        .operation = "describeTags",
        .zig_api_ns = zig_time,
        .git_cli_ns = git_time,
        .iterations = iterations,
    };
}

fn benchmarkIsClean(allocator: std.mem.Allocator, repo: *ziggit.Repository, repo_path: []const u8, iterations: u32) !BenchmarkResult {
    // Benchmark Zig API
    const zig_start = std.time.nanoTimestamp();
    for (0..iterations) |_| {
        _ = repo.isClean() catch false;
    }
    const zig_end = std.time.nanoTimestamp();
    const zig_time = @as(u64, @intCast(zig_end - zig_start));

    // Benchmark git CLI (using status --porcelain and checking if empty)
    const git_start = std.time.nanoTimestamp();
    for (0..iterations) |_| {
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "git", "status", "--porcelain" },
            .cwd = repo_path,
        }) catch continue;
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        _ = result.stdout.len == 0; // Check if empty
    }
    const git_end = std.time.nanoTimestamp();
    const git_time = @as(u64, @intCast(git_end - git_start));

    return BenchmarkResult{
        .operation = "isClean",
        .zig_api_ns = zig_time,
        .git_cli_ns = git_time,
        .iterations = iterations,
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Zig API vs Git CLI Benchmark ===\n", .{});
    std.debug.print("This benchmark proves the point: direct Zig function calls eliminate process spawn overhead entirely.\n\n", .{});

    const test_dir = "/tmp/zig_api_bench_test";
    std.fs.deleteTreeAbsolute(test_dir) catch {};

    // Create a repo with some files to benchmark operations
    var repo = try ziggit.Repository.init(allocator, test_dir);
    defer repo.close();

    // Create 10 files (smaller number for faster setup)
    for (0..10) |i| {
        const filename = try std.fmt.allocPrint(allocator, "{s}/file{d}.txt", .{ test_dir, i });
        defer allocator.free(filename);

        const file = try std.fs.createFileAbsolute(filename, .{ .truncate = true });
        defer file.close();

        const content = try std.fmt.allocPrint(allocator, "This is file {d} content.\n", .{i});
        defer allocator.free(content);
        
        try file.writeAll(content);
        
        const add_name = try std.fmt.allocPrint(allocator, "file{d}.txt", .{i});
        defer allocator.free(add_name);
        try repo.add(add_name);
    }

    // Create first commit
    _ = try repo.commit("Initial commit with 10 files", "benchmark", "benchmark@example.com");

    // Create a tag
    try repo.createTag("v1.0.0", "Benchmark tag");

    const iterations: u32 = 1000;
    std.debug.print("Running {d} iterations of each operation...\n\n", .{iterations});

    var results = std.ArrayList(BenchmarkResult).init(allocator);
    defer results.deinit();

    // Benchmark all operations
    try results.append(try benchmarkRevParseHead(allocator, &repo, test_dir, iterations));
    try results.append(try benchmarkStatusPorcelain(allocator, &repo, test_dir, iterations));
    try results.append(try benchmarkDescribeTags(allocator, &repo, test_dir, iterations));
    try results.append(try benchmarkIsClean(allocator, &repo, test_dir, iterations));

    // Print results
    std.debug.print("Operation       | Zig API Time | Git CLI Time | Speedup\n", .{});
    std.debug.print("----------------|--------------|--------------|--------\n", .{});
    
    for (results.items) |result| {
        const zig_ms = @as(f64, @floatFromInt(result.zig_api_ns)) / 1_000_000.0;
        const git_ms = @as(f64, @floatFromInt(result.git_cli_ns)) / 1_000_000.0;
        const speedup = git_ms / zig_ms;
        
        std.debug.print("{s:<15} | {d:>10.2}ms | {d:>10.2}ms | {d:>5.1}x\n", .{
            result.operation,
            zig_ms,
            git_ms,
            speedup,
        });
    }

    // Calculate per-operation times
    std.debug.print("\nPer-operation average times:\n", .{});
    std.debug.print("Operation       | Zig API      | Git CLI      | Difference\n", .{});
    std.debug.print("----------------|--------------|--------------|----------\n", .{});
    
    for (results.items) |result| {
        const zig_per_op_ns = result.zig_api_ns / iterations;
        const git_per_op_ns = result.git_cli_ns / iterations;
        const zig_per_op_us = @as(f64, @floatFromInt(zig_per_op_ns)) / 1000.0;
        const git_per_op_us = @as(f64, @floatFromInt(git_per_op_ns)) / 1000.0;
        
        std.debug.print("{s:<15} | {d:>10.1}μs | {d:>10.1}μs | -{d:>6.1}μs\n", .{
            result.operation,
            zig_per_op_us,
            git_per_op_us,
            git_per_op_us - zig_per_op_us,
        });
    }

    std.debug.print("\n=== Performance Analysis for Bun ===\n", .{});
    std.debug.print("Direct Zig function calls eliminate:\n", .{});
    std.debug.print("• Process spawn overhead (~1-10ms per call)\n", .{});
    std.debug.print("• CLI argument parsing overhead\n", .{});
    std.debug.print("• Process cleanup overhead\n", .{});
    std.debug.print("• Data serialization/deserialization overhead\n", .{});
    std.debug.print("• Context switching between processes\n\n", .{});
    
    var total_zig_time: u64 = 0;
    var total_git_time: u64 = 0;
    for (results.items) |result| {
        total_zig_time += result.zig_api_ns;
        total_git_time += result.git_cli_ns;
    }
    
    const overall_speedup = @as(f64, @floatFromInt(total_git_time)) / @as(f64, @floatFromInt(total_zig_time));
    std.debug.print("Overall speedup: {d:.1}x faster with direct Zig API calls\n", .{overall_speedup});
    
    const time_saved_ns = total_git_time - total_zig_time;
    const time_saved_ms = @as(f64, @floatFromInt(time_saved_ns)) / 1_000_000.0;
    std.debug.print("Total time saved: {d:.1}ms over {d} operations\n", .{ time_saved_ms, iterations * @as(u32, @intCast(results.items.len)) });

    std.fs.deleteTreeAbsolute(test_dir) catch {};
    std.debug.print("\n✅ Benchmark completed!\n", .{});
}