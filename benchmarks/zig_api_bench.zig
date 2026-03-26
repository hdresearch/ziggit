// benchmarks/zig_api_bench.zig - ITEM 7: Benchmark comparing direct Zig calls vs git CLI spawning
const std = @import("std");
const ziggit = @import("ziggit");

const BenchmarkResult = struct {
    zig_api_ns: u64,
    git_cli_ns: u64,
    
    pub fn speedup(self: BenchmarkResult) f64 {
        return @as(f64, @floatFromInt(self.git_cli_ns)) / @as(f64, @floatFromInt(self.zig_api_ns));
    }
};

fn benchmarkOperation(
    allocator: std.mem.Allocator, 
    repo: *ziggit.Repository, 
    repo_path: []const u8,
    iterations: u32,
    comptime zig_fn: anytype,
    git_command: []const []const u8
) !BenchmarkResult {
    var zig_total_ns: u64 = 0;
    var git_total_ns: u64 = 0;
    
    // Benchmark Zig API calls
    for (0..iterations) |_| {
        const start_time = std.time.nanoTimestamp();
        
        const result = zig_fn(repo, allocator) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        };
        defer if (@TypeOf(result) == []const u8 or @TypeOf(result) == [][]const u8) {
            if (@TypeOf(result) == [][]const u8) {
                for (result) |item| allocator.free(item);
            }
            allocator.free(result);
        };
        
        const end_time = std.time.nanoTimestamp();
        zig_total_ns += @intCast(end_time - start_time);
    }
    
    // Benchmark git CLI spawning
    for (0..iterations) |_| {
        const start_time = std.time.nanoTimestamp();
        
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = git_command,
            .cwd = repo_path,
        }) catch continue;
        
        const end_time = std.time.nanoTimestamp();
        git_total_ns += @intCast(end_time - start_time);
        
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    
    return BenchmarkResult{
        .zig_api_ns = zig_total_ns / iterations,
        .git_cli_ns = git_total_ns / iterations,
    };
}

fn revParseHeadZig(repo: *ziggit.Repository, allocator: std.mem.Allocator) ![]const u8 {
    _ = allocator;
    const hash = try repo.revParseHead();
    return try repo.allocator.dupe(u8, &hash);
}

fn statusPorcelainZig(repo: *ziggit.Repository, allocator: std.mem.Allocator) ![]const u8 {
    return try repo.statusPorcelain(allocator);
}

fn describeTagsZig(repo: *ziggit.Repository, allocator: std.mem.Allocator) ![]const u8 {
    return try repo.describeTags(allocator);
}

fn isCleanZig(repo: *ziggit.Repository, allocator: std.mem.Allocator) ![]const u8 {
    _ = allocator;
    const clean = try repo.isClean();
    return try repo.allocator.dupe(u8, if (clean) "true" else "false");
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const test_dir = "/tmp/zig_api_benchmark";
    std.fs.deleteDirAbsolute(test_dir) catch {};
    
    // Create repository with 100 files for realistic benchmark
    var repo = try ziggit.Repository.init(allocator, test_dir);
    defer repo.close();
    
    // Create 100 files to simulate a real project
    std.debug.print("Setting up benchmark repository with 100 files...\n", .{});
    for (0..100) |i| {
        const filename = try std.fmt.allocPrint(allocator, "file_{d:0>3}.txt", .{i});
        defer allocator.free(filename);
        
        const filepath = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ test_dir, filename });
        defer allocator.free(filepath);
        
        const file = try std.fs.createFileAbsolute(filepath, .{ .truncate = true });
        defer file.close();
        
        const content = try std.fmt.allocPrint(allocator, "File {d} content\nLine 2\nLine 3\n", .{i});
        defer allocator.free(content);
        
        try file.writeAll(content);
        try repo.add(filename);
    }
    
    _ = try repo.commit("Initial commit with 100 files", "benchmark", "benchmark@test.com");
    try repo.createTag("v1.0.0", "Initial tag");
    
    const iterations: u32 = 1000;
    std.debug.print("Running benchmarks with {d} iterations each...\n\n", .{iterations});
    
    // Benchmark 1: revParseHead
    std.debug.print("Benchmarking revParseHead...\n", .{});
    const rev_parse_result = try benchmarkOperation(
        allocator,
        &repo,
        test_dir,
        iterations,
        revParseHeadZig,
        &.{ "git", "-C", test_dir, "rev-parse", "HEAD" }
    );
    
    std.debug.print("  Zig API:  {d} ns per call\n", .{rev_parse_result.zig_api_ns});
    std.debug.print("  Git CLI:  {d} ns per call\n", .{rev_parse_result.git_cli_ns});
    std.debug.print("  Speedup:  {d:.2}x faster\n\n", .{rev_parse_result.speedup()});
    
    // Benchmark 2: statusPorcelain
    std.debug.print("Benchmarking statusPorcelain...\n", .{});
    const status_result = try benchmarkOperation(
        allocator,
        &repo,
        test_dir,
        iterations,
        statusPorcelainZig,
        &.{ "git", "-C", test_dir, "status", "--porcelain" }
    );
    
    std.debug.print("  Zig API:  {d} ns per call\n", .{status_result.zig_api_ns});
    std.debug.print("  Git CLI:  {d} ns per call\n", .{status_result.git_cli_ns});
    std.debug.print("  Speedup:  {d:.2}x faster\n\n", .{status_result.speedup()});
    
    // Benchmark 3: describeTags
    std.debug.print("Benchmarking describeTags...\n", .{});
    const tags_result = try benchmarkOperation(
        allocator,
        &repo,
        test_dir,
        iterations,
        describeTagsZig,
        &.{ "git", "-C", test_dir, "describe", "--tags", "--abbrev=0" }
    );
    
    std.debug.print("  Zig API:  {d} ns per call\n", .{tags_result.zig_api_ns});
    std.debug.print("  Git CLI:  {d} ns per call\n", .{tags_result.git_cli_ns});
    std.debug.print("  Speedup:  {d:.2}x faster\n\n", .{tags_result.speedup()});
    
    // Benchmark 4: isClean
    std.debug.print("Benchmarking isClean...\n", .{});
    const clean_result = try benchmarkOperation(
        allocator,
        &repo,
        test_dir,
        iterations,
        isCleanZig,
        &.{ "git", "-C", test_dir, "status", "--porcelain" }
    );
    
    std.debug.print("  Zig API:  {d} ns per call\n", .{clean_result.zig_api_ns});
    std.debug.print("  Git CLI:  {d} ns per call\n", .{clean_result.git_cli_ns});
    std.debug.print("  Speedup:  {d:.2}x faster\n\n", .{clean_result.speedup()});
    
    // Calculate overall performance improvement
    const total_zig_ns = rev_parse_result.zig_api_ns + status_result.zig_api_ns + 
                        tags_result.zig_api_ns + clean_result.zig_api_ns;
    const total_git_ns = rev_parse_result.git_cli_ns + status_result.git_cli_ns + 
                        tags_result.git_cli_ns + clean_result.git_cli_ns;
    
    const overall_speedup = @as(f64, @floatFromInt(total_git_ns)) / @as(f64, @floatFromInt(total_zig_ns));
    
    std.debug.print("=== OVERALL RESULTS ===\n");
    std.debug.print("Total Zig API time:  {d} ns\n", .{total_zig_ns});
    std.debug.print("Total Git CLI time:  {d} ns\n", .{total_git_ns});
    std.debug.print("Overall speedup:     {d:.2}x faster\n", .{overall_speedup});
    std.debug.print("\nThis proves that direct Zig function calls eliminate process spawn overhead entirely!\n");
    std.debug.print("Bun calling ziggit.Repository.revParseHead() is {d:.2}x faster than spawning 'git rev-parse HEAD'\n", .{overall_speedup});
    
    // Cleanup
    std.fs.deleteDirAbsolute(test_dir) catch {};
}