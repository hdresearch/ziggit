const std = @import("std");
const ziggit = @import("src/ziggit.zig");

fn measureOperation(allocator: std.mem.Allocator, repo_path: []const u8, iterations: u32, operation_name: []const u8, operation_fn: fn (allocator: std.mem.Allocator, repo_path: []const u8) anyerror!void) !u64 {
    var total_time: u64 = 0;
    
    // Warmup
    for (0..10) |_| {
        operation_fn(allocator, repo_path) catch {};
    }
    
    // Measure
    for (0..iterations) |_| {
        const start = std.time.nanoTimestamp();
        operation_fn(allocator, repo_path) catch {};
        const end = std.time.nanoTimestamp();
        total_time += @as(u64, @intCast(end - start));
    }
    
    const avg_time = total_time / iterations;
    std.debug.print("{s}: {d}ns average\n", .{ operation_name, avg_time });
    return avg_time;
}

fn revParseHeadOperation(allocator: std.mem.Allocator, repo_path: []const u8) !void {
    var repo = try ziggit.Repository.open(allocator, repo_path);
    defer repo.close();
    const hash = try repo.revParseHead();
    _ = hash;
}

fn describeTagsOperation(allocator: std.mem.Allocator, repo_path: []const u8) !void {
    var repo = try ziggit.Repository.open(allocator, repo_path);
    defer repo.close();
    const tag = try repo.describeTags(allocator);
    defer allocator.free(tag);
}

fn statusPorcelainOperation(allocator: std.mem.Allocator, repo_path: []const u8) !void {
    var repo = try ziggit.Repository.open(allocator, repo_path);
    defer repo.close();
    const status = try repo.statusPorcelain(allocator);
    defer allocator.free(status);
}

fn isCleanOperation(allocator: std.mem.Allocator, repo_path: []const u8) !void {
    var repo = try ziggit.Repository.open(allocator, repo_path);
    defer repo.close();
    const clean = try repo.isClean();
    _ = clean;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Use the test repo from the main benchmark
    const repo_path = "/tmp/test_optimization_repo";
    
    // Setup test repo (simplified)
    std.fs.deleteTreeAbsolute(repo_path) catch {};
    const init_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "init", repo_path },
    });
    defer allocator.free(init_result.stdout);
    defer allocator.free(init_result.stderr);
    
    // Create some test files and commits
    for (0..10) |i| {
        const filename = try std.fmt.allocPrint(allocator, "{s}/file_{d}.txt", .{ repo_path, i });
        defer allocator.free(filename);
        
        const file = try std.fs.createFileAbsolute(filename, .{});
        defer file.close();
        try file.writeAll("test content");
        
        const add_result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "git", "add", "." },
            .cwd = repo_path,
        });
        defer allocator.free(add_result.stdout);
        defer allocator.free(add_result.stderr);
        
        if (i == 9) {
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
        }
    }
    
    const iterations = 1000;
    std.debug.print("=== Optimization Benchmark (Before Optimizations) ===\n", .{});
    
    _ = try measureOperation(allocator, repo_path, iterations, "revParseHead", revParseHeadOperation);
    _ = try measureOperation(allocator, repo_path, iterations, "describeTags", describeTagsOperation);
    _ = try measureOperation(allocator, repo_path, iterations, "statusPorcelain", statusPorcelainOperation);
    _ = try measureOperation(allocator, repo_path, iterations, "isClean", isCleanOperation);
    
    // Cleanup
    std.fs.deleteTreeAbsolute(repo_path) catch {};
}