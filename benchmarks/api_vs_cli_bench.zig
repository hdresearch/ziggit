const std = @import("std");
const ziggit = @import("ziggit");
const print = std.debug.print;

const Timer = std.time.Timer;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    print("=== Zig API vs Git CLI Benchmark ===\n", .{});
    print("This benchmark proves that direct Zig function calls eliminate process spawn overhead.\n\n", .{});

    // Setup: Create a repo with 100 files for meaningful benchmarks
    const test_dir = "/tmp/api_vs_cli_bench";
    std.fs.deleteDirAbsolute(test_dir) catch {};

    var repo = try ziggit.Repository.init(allocator, test_dir);
    defer repo.close();

    // Create 100 test files
    print("Setting up test repository with 100 files...\n", .{});
    for (0..100) |i| {
        const file_path = try std.fmt.allocPrint(allocator, "{s}/file_{d}.txt", .{ test_dir, i });
        defer allocator.free(file_path);
        
        const file = try std.fs.createFileAbsolute(file_path, .{ .truncate = true });
        defer file.close();
        
        const content = try std.fmt.allocPrint(allocator, "Content of file {d}\nLine 2\nLine 3\n", .{i});
        defer allocator.free(content);
        
        try file.writeAll(content);
        
        const rel_path = try std.fmt.allocPrint(allocator, "file_{d}.txt", .{i});
        defer allocator.free(rel_path);
        try repo.add(rel_path);
    }
    
    // Create initial commit
    _ = try repo.commit("Initial commit with 100 files", "bench", "bench@example.com");
    
    // Create some tags for testing
    try repo.createTag("v0.1.0", "Version 0.1.0");
    try repo.createTag("v0.2.0", "Version 0.2.0");
    
    print("Setup complete. Running benchmarks...\n\n", .{});

    const iterations = 1000;

    // Benchmark 1: revParseHead() vs "git rev-parse HEAD"
    try benchmarkRevParseHead(&repo, allocator, iterations, test_dir);
    
    // Benchmark 2: statusPorcelain() vs "git status --porcelain"
    try benchmarkStatusPorcelain(&repo, allocator, iterations, test_dir);
    
    // Benchmark 3: describeTags() vs "git describe --tags --abbrev=0"
    try benchmarkDescribeTags(&repo, allocator, iterations, test_dir);
    
    // Benchmark 4: isClean() vs "git status --porcelain" (and check empty)
    try benchmarkIsClean(&repo, allocator, iterations, test_dir);

    // Cleanup
    std.fs.deleteDirAbsolute(test_dir) catch {};
    
    print("\n=== Summary ===\n", .{});
    print("Direct Zig function calls eliminate:\n", .{});
    print("• Process spawning overhead\n", .{});
    print("• Argument parsing overhead\n", .{});
    print("• Pipe communication overhead\n", .{});
    print("• String parsing overhead\n", .{});
    print("• Memory allocation for subprocess output\n", .{});
    print("\nThis is why bun should import ziggit as a Zig package!\n", .{});
}

fn benchmarkRevParseHead(repo: *const ziggit.Repository, allocator: std.mem.Allocator, iterations: u32, test_dir: []const u8) !void {
    print("1. Benchmarking revParseHead() vs git rev-parse HEAD\n", .{});
    
    // Benchmark Zig API
    var timer = try Timer.start();
    const start_zig = timer.lap();
    
    for (0..iterations) |_| {
        const hash = try repo.revParseHead();
        std.mem.doNotOptimizeAway(&hash);
    }
    
    const end_zig = timer.lap();
    const zig_time_ns = end_zig - start_zig;
    
    // Benchmark git CLI (sample a smaller number due to process overhead)
    const cli_iterations = @min(iterations / 10, 100); // Much fewer iterations for CLI
    const start_cli = timer.lap();
    
    for (0..cli_iterations) |_| {
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "git", "-C", test_dir, "rev-parse", "HEAD" },
        }) catch continue;
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        std.mem.doNotOptimizeAway(result.stdout.ptr);
    }
    
    const end_cli = timer.lap();
    const cli_time_ns = end_cli - start_cli;
    
    // Calculate per-operation times
    const zig_per_op = zig_time_ns / iterations;
    const cli_per_op = cli_time_ns / cli_iterations;
    
    print("   Zig API ({d} ops): {d}ns per operation\n", .{ iterations, zig_per_op });
    print("   Git CLI ({d} ops): {d}ns per operation\n", .{ cli_iterations, cli_per_op });
    print("   Speedup: {d:.1}x faster\n\n", .{ @as(f64, @floatFromInt(cli_per_op)) / @as(f64, @floatFromInt(zig_per_op)) });
}

fn benchmarkStatusPorcelain(repo: *const ziggit.Repository, allocator: std.mem.Allocator, iterations: u32, test_dir: []const u8) !void {
    print("2. Benchmarking statusPorcelain() vs git status --porcelain\n", .{});
    
    // Benchmark Zig API
    var timer = try Timer.start();
    const start_zig = timer.lap();
    
    for (0..iterations) |_| {
        const status = try repo.statusPorcelain(allocator);
        defer allocator.free(status);
        std.mem.doNotOptimizeAway(status.ptr);
    }
    
    const end_zig = timer.lap();
    const zig_time_ns = end_zig - start_zig;
    
    // Benchmark git CLI
    const cli_iterations = @min(iterations / 10, 100);
    const start_cli = timer.lap();
    
    for (0..cli_iterations) |_| {
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "git", "-C", test_dir, "status", "--porcelain" },
        }) catch continue;
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        std.mem.doNotOptimizeAway(result.stdout.ptr);
    }
    
    const end_cli = timer.lap();
    const cli_time_ns = end_cli - start_cli;
    
    const zig_per_op = zig_time_ns / iterations;
    const cli_per_op = cli_time_ns / cli_iterations;
    
    print("   Zig API ({d} ops): {d}ns per operation\n", .{ iterations, zig_per_op });
    print("   Git CLI ({d} ops): {d}ns per operation\n", .{ cli_iterations, cli_per_op });
    print("   Speedup: {d:.1}x faster\n\n", .{ @as(f64, @floatFromInt(cli_per_op)) / @as(f64, @floatFromInt(zig_per_op)) });
}

fn benchmarkDescribeTags(repo: *const ziggit.Repository, allocator: std.mem.Allocator, iterations: u32, test_dir: []const u8) !void {
    print("3. Benchmarking describeTags() vs git describe --tags --abbrev=0\n", .{});
    
    // Benchmark Zig API
    var timer = try Timer.start();
    const start_zig = timer.lap();
    
    for (0..iterations) |_| {
        const tag = try repo.describeTags(allocator);
        defer allocator.free(tag);
        std.mem.doNotOptimizeAway(tag.ptr);
    }
    
    const end_zig = timer.lap();
    const zig_time_ns = end_zig - start_zig;
    
    // Benchmark git CLI
    const cli_iterations = @min(iterations / 10, 100);
    const start_cli = timer.lap();
    
    for (0..cli_iterations) |_| {
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "git", "-C", test_dir, "describe", "--tags", "--abbrev=0" },
        }) catch continue;
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        std.mem.doNotOptimizeAway(result.stdout.ptr);
    }
    
    const end_cli = timer.lap();
    const cli_time_ns = end_cli - start_cli;
    
    const zig_per_op = zig_time_ns / iterations;
    const cli_per_op = cli_time_ns / cli_iterations;
    
    print("   Zig API ({d} ops): {d}ns per operation\n", .{ iterations, zig_per_op });
    print("   Git CLI ({d} ops): {d}ns per operation\n", .{ cli_iterations, cli_per_op });
    print("   Speedup: {d:.1}x faster\n\n", .{ @as(f64, @floatFromInt(cli_per_op)) / @as(f64, @floatFromInt(zig_per_op)) });
}

fn benchmarkIsClean(repo: *const ziggit.Repository, allocator: std.mem.Allocator, iterations: u32, test_dir: []const u8) !void {
    print("4. Benchmarking isClean() vs git status --porcelain + empty check\n", .{});
    
    // Benchmark Zig API
    var timer = try Timer.start();
    const start_zig = timer.lap();
    
    for (0..iterations) |_| {
        const clean = try repo.isClean();
        std.mem.doNotOptimizeAway(&clean);
    }
    
    const end_zig = timer.lap();
    const zig_time_ns = end_zig - start_zig;
    
    // Benchmark git CLI equivalent
    const cli_iterations = @min(iterations / 10, 100);
    const start_cli = timer.lap();
    
    for (0..cli_iterations) |_| {
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "git", "-C", test_dir, "status", "--porcelain" },
        }) catch continue;
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        
        const is_clean = result.stdout.len == 0;
        std.mem.doNotOptimizeAway(&is_clean);
    }
    
    const end_cli = timer.lap();
    const cli_time_ns = end_cli - start_cli;
    
    const zig_per_op = zig_time_ns / iterations;
    const cli_per_op = cli_time_ns / cli_iterations;
    
    print("   Zig API ({d} ops): {d}ns per operation\n", .{ iterations, zig_per_op });
    print("   Git CLI ({d} ops): {d}ns per operation\n", .{ cli_iterations, cli_per_op });
    print("   Speedup: {d:.1}x faster\n\n", .{ @as(f64, @floatFromInt(cli_per_op)) / @as(f64, @floatFromInt(zig_per_op)) });
}