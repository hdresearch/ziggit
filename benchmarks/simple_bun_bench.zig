const std = @import("std");

// Include ziggit C API
const ziggit_h = @cImport({
    @cInclude("ziggit.h");
});

// Test data structures
const BenchmarkResult = struct {
    operation: []const u8,
    ziggit_lib_ns: ?u64 = null,
    git_cli_ns: ?u64 = null,
    ziggit_success: bool = false,
    git_success: bool = false,
};

// Helper function for timing
fn timeOperation(comptime name: []const u8) struct { start_time: i128, name: []const u8 } {
    const start = std.time.nanoTimestamp();
    return .{ .start_time = start, .name = name };
}

fn finishTiming(timer: anytype) u64 {
    const end = std.time.nanoTimestamp();
    const duration = @as(u64, @intCast(end - timer.start_time));
    std.log.info("{s} took {d}ns ({d:.2}ms)", .{ timer.name, duration, @as(f64, @floatFromInt(duration)) / 1_000_000.0 });
    return duration;
}

fn runGitCommand(allocator: std.mem.Allocator, args: []const []const u8, cwd: ?[]const u8) !std.process.Child.RunResult {
    return try std.process.Child.run(.{
        .allocator = allocator,
        .argv = args,
        .cwd = cwd,
    });
}

fn cleanupTestDir(path: []const u8) void {
    std.fs.deleteTreeAbsolute(path) catch {};
}

fn benchmarkRepoInit(allocator: std.mem.Allocator, test_dir: []const u8) !BenchmarkResult {
    var result = BenchmarkResult{ .operation = "repo_init" };
    
    // Test ziggit library
    {
        const ziggit_path = try std.fmt.allocPrint(allocator, "{s}_ziggit", .{test_dir});
        defer allocator.free(ziggit_path);
        defer cleanupTestDir(ziggit_path);
        
        const ziggit_path_z = try allocator.dupeZ(u8, ziggit_path);
        defer allocator.free(ziggit_path_z);
        
        const timer = timeOperation("ziggit_repo_init");
        const ziggit_result = ziggit_h.ziggit_repo_init(ziggit_path_z.ptr, 0);
        result.ziggit_lib_ns = finishTiming(timer);
        result.ziggit_success = ziggit_result == 0;
    }
    
    // Test git CLI
    {
        const git_path = try std.fmt.allocPrint(allocator, "{s}_git", .{test_dir});
        defer allocator.free(git_path);
        defer cleanupTestDir(git_path);
        
        const timer2 = timeOperation("git init");
        const git_result_cmd = runGitCommand(allocator, &.{ "git", "init", git_path }, null) catch {
            result.git_cli_ns = finishTiming(timer2);
            result.git_success = false;
            return result;
        };
        result.git_cli_ns = finishTiming(timer2);
        result.git_success = git_result_cmd.term == .Exited and git_result_cmd.term.Exited == 0;
    }
    
    return result;
}

fn benchmarkRepoStatus(allocator: std.mem.Allocator, test_dir: []const u8) !BenchmarkResult {
    var result = BenchmarkResult{ .operation = "repo_status" };
    
    // Setup test repositories
    const ziggit_path = try std.fmt.allocPrint(allocator, "{s}_ziggit_status", .{test_dir});
    defer allocator.free(ziggit_path);
    defer cleanupTestDir(ziggit_path);
    
    const git_path = try std.fmt.allocPrint(allocator, "{s}_git_status", .{test_dir});
    defer allocator.free(git_path);
    defer cleanupTestDir(git_path);
    
    // Initialize repos
    const ziggit_path_z = try allocator.dupeZ(u8, ziggit_path);
    defer allocator.free(ziggit_path_z);
    _ = ziggit_h.ziggit_repo_init(ziggit_path_z.ptr, 0);
    
    _ = runGitCommand(allocator, &.{ "git", "init", git_path }, null) catch return result;
    
    // Test ziggit status
    {
        const repo = ziggit_h.ziggit_repo_open(ziggit_path_z.ptr);
        if (repo) |r| {
            defer ziggit_h.ziggit_repo_close(r);
            
            var buffer: [4096]u8 = undefined;
            const timer4 = timeOperation("ziggit_status");
            const ziggit_status_result = ziggit_h.ziggit_status(r, &buffer, buffer.len);
            result.ziggit_lib_ns = finishTiming(timer4);
            result.ziggit_success = ziggit_status_result == 0;
        }
    }
    
    // Test git CLI status
    {
        const timer5 = timeOperation("git status");
        const git_status_result = runGitCommand(allocator, &.{ "git", "-C", git_path, "status", "--porcelain" }, null) catch {
            result.git_cli_ns = finishTiming(timer5);
            result.git_success = false;
            return result;
        };
        result.git_cli_ns = finishTiming(timer5);
        result.git_success = git_status_result.term == .Exited and git_status_result.term.Exited == 0;
    }
    
    return result;
}

// Main benchmark runner
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.log.info("=== Simple Bun Integration Benchmark: ziggit vs git CLI ===", .{});
    std.log.info("Testing core operations that bun uses...\n", .{});
    
    const test_base_dir = "/tmp/simple_bun_bench";
    cleanupTestDir(test_base_dir);
    
    var results = std.ArrayList(BenchmarkResult).init(allocator);
    defer results.deinit();
    
    // Repository initialization
    std.log.info("Benchmarking repository initialization...", .{});
    const init_result = try benchmarkRepoInit(allocator, test_base_dir);
    try results.append(init_result);
    
    // Repository status
    std.log.info("\nBenchmarking repository status...", .{});
    const status_result = try benchmarkRepoStatus(allocator, test_base_dir);
    try results.append(status_result);
    
    // Print summary
    std.log.info("\n=== BENCHMARK SUMMARY ===", .{});
    std.log.info("Operation       | ziggit-lib | git CLI  | Winner", .{});
    std.log.info("----------------|------------|----------|-------", .{});
    
    for (results.items) |r| {
        const ziggit_ms = if (r.ziggit_lib_ns) |ns| @as(f64, @floatFromInt(ns)) / 1_000_000.0 else 0.0;
        const git_ms = if (r.git_cli_ns) |ns| @as(f64, @floatFromInt(ns)) / 1_000_000.0 else 0.0;
        
        // Determine winner
        var winner: []const u8 = "none";
        if (r.ziggit_success and r.git_success) {
            winner = if (ziggit_ms < git_ms) "ziggit" else "git CLI";
        } else if (r.ziggit_success) {
            winner = "ziggit";
        } else if (r.git_success) {
            winner = "git CLI";
        }
        
        std.log.info("{s:<15} | {d:>8.2}ms | {d:>6.2}ms | {s}", .{
            r.operation, ziggit_ms, git_ms, winner
        });
    }
    
    // Calculate performance improvements
    std.log.info("\n=== PERFORMANCE ANALYSIS FOR BUN ===", .{});
    for (results.items) |r| {
        if (r.ziggit_lib_ns != null and r.git_cli_ns != null and r.ziggit_success and r.git_success) {
            const ziggit_time = @as(f64, @floatFromInt(r.ziggit_lib_ns.?));
            const git_time = @as(f64, @floatFromInt(r.git_cli_ns.?));
            const improvement = ((git_time - ziggit_time) / git_time) * 100.0;
            
            const direction = if (improvement > 0) "faster" else "slower";
            std.log.info("{s}: ziggit is {d:.1}% {s} than git CLI", .{
                r.operation, 
                @abs(improvement),
                direction
            });
        }
    }
    
    cleanupTestDir(test_base_dir);
    std.log.info("\nSimple benchmark completed! Results saved for BENCHMARKS.md", .{});
}