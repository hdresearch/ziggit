const std = @import("std");
const ziggit = @import("src/ziggit.zig");

fn measureOperationWithCaching(allocator: std.mem.Allocator, repo_path: []const u8, iterations: u32, operation_name: []const u8, operation_fn: fn (repo: *ziggit.Repository, allocator: std.mem.Allocator) anyerror!void) !void {
    // Open repository once and reuse it to test caching
    var repo = try ziggit.Repository.open(allocator, repo_path);
    defer repo.close();
    
    var times = std.ArrayList(u64).init(allocator);
    defer times.deinit();
    
    // Measure multiple iterations on same repository instance
    for (0..iterations) |_| {
        const start = std.time.nanoTimestamp();
        operation_fn(&repo, allocator) catch {};
        const end = std.time.nanoTimestamp();
        const duration = @as(u64, @intCast(end - start));
        try times.append(duration);
    }
    
    // Calculate statistics
    var min_time: u64 = std.math.maxInt(u64);
    var max_time: u64 = 0;
    var sum: u64 = 0;
    
    for (times.items) |time| {
        min_time = @min(min_time, time);
        max_time = @max(max_time, time);
        sum += time;
    }
    
    const avg_time = sum / iterations;
    
    // Sort for median calculation
    std.mem.sort(u64, times.items, {}, std.sort.asc(u64));
    const median_time = times.items[times.items.len / 2];
    
    std.debug.print("{s}: min={d}ns, median={d}ns, avg={d}ns, max={d}ns\n", .{ operation_name, min_time, median_time, avg_time, max_time });
    std.debug.print("  -> First call: {d}ns, Last call: {d}ns, Improvement: {d:.1}x\n", .{ times.items[0], times.items[times.items.len - 1], @as(f64, @floatFromInt(times.items[0])) / @as(f64, @floatFromInt(times.items[times.items.len - 1])) });
}

fn revParseHeadOperation(repo: *ziggit.Repository, allocator: std.mem.Allocator) !void {
    _ = allocator;
    const hash = try repo.revParseHead();
    _ = hash;
}

fn describeTagsOperation(repo: *ziggit.Repository, allocator: std.mem.Allocator) !void {
    const tag = try repo.describeTags(allocator);
    defer allocator.free(tag);
}

fn statusPorcelainOperation(repo: *ziggit.Repository, allocator: std.mem.Allocator) !void {
    const status = try repo.statusPorcelain(allocator);
    defer allocator.free(status);
}

fn isCleanOperation(repo: *ziggit.Repository, allocator: std.mem.Allocator) !void {
    _ = allocator;
    const clean = try repo.isClean();
    _ = clean;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Setup test repo
    const repo_path = "/tmp/test_optimization_repo_v2";
    
    std.fs.deleteTreeAbsolute(repo_path) catch {};
    const init_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "init", repo_path },
    });
    defer allocator.free(init_result.stdout);
    defer allocator.free(init_result.stderr);
    
    // Create test files and commit
    for (0..10) |i| {
        const filename = try std.fmt.allocPrint(allocator, "{s}/file_{d}.txt", .{ repo_path, i });
        defer allocator.free(filename);
        
        const file = try std.fs.createFileAbsolute(filename, .{});
        defer file.close();
        try file.writeAll("test content");
    }
    
    const add_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "add", "." },
        .cwd = repo_path,
    });
    defer allocator.free(add_result.stdout);
    defer allocator.free(add_result.stderr);
    
    const commit_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "commit", "-m", "Test commit" },
        .cwd = repo_path,
    });
    defer allocator.free(commit_result.stdout);
    defer allocator.free(commit_result.stderr);
    
    const tag_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "tag", "v1.0" },
        .cwd = repo_path,
    });
    defer allocator.free(tag_result.stdout);
    defer allocator.free(tag_result.stderr);
    
    const iterations = 100;
    std.debug.print("=== Optimization Comparison (Caching Effects) ===\n", .{});
    std.debug.print("Measuring {d} iterations per operation on same repository instance\n\n", .{iterations});
    
    try measureOperationWithCaching(allocator, repo_path, iterations, "revParseHead (ultra-fast)", revParseHeadOperation);
    try measureOperationWithCaching(allocator, repo_path, iterations, "describeTags (ultra-fast)", describeTagsOperation);
    try measureOperationWithCaching(allocator, repo_path, iterations, "statusPorcelain (optimized)", statusPorcelainOperation);
    try measureOperationWithCaching(allocator, repo_path, iterations, "isClean (hyper-fast)", isCleanOperation);
    
    // Cleanup
    std.fs.deleteTreeAbsolute(repo_path) catch {};
}