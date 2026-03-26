const std = @import("std");
const ziggit = @import("ziggit");
const print = std.debug.print;

// Benchmark for testing optimization improvements
const OptimizationBench = struct {
    repo: ziggit.Repository,
    allocator: std.mem.Allocator,
    path: []const u8,

    fn init(allocator: std.mem.Allocator) !OptimizationBench {
        var tmp_dir_buf: [256]u8 = undefined;
        const tmp_dir = try std.fmt.bufPrint(&tmp_dir_buf, "/tmp/opt_bench_{d}", .{std.time.milliTimestamp()});
        const repo_path = try std.fmt.allocPrint(allocator, "{s}/test_repo", .{tmp_dir});

        // Create test repository
        std.fs.deleteTreeAbsolute(repo_path) catch {};
        
        const init_result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "git", "init", repo_path },
        });
        defer allocator.free(init_result.stdout);
        defer allocator.free(init_result.stderr);

        if (init_result.term != .Exited or init_result.term.Exited != 0) {
            return error.SetupFailed;
        }

        // Set git config
        const config_name_result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "git", "config", "user.name", "Test User" },
            .cwd = repo_path,
        });
        defer allocator.free(config_name_result.stdout);
        defer allocator.free(config_name_result.stderr);

        const config_email_result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "git", "config", "user.email", "test@example.com" },
            .cwd = repo_path,
        });
        defer allocator.free(config_email_result.stdout);
        defer allocator.free(config_email_result.stderr);

        // Create files and commit them to establish a clean baseline
        for (0..50) |i| {
            const filename = try std.fmt.allocPrint(allocator, "{s}/file_{d}.txt", .{ repo_path, i });
            defer allocator.free(filename);

            const file = try std.fs.createFileAbsolute(filename, .{});
            defer file.close();

            const content = try std.fmt.allocPrint(allocator, "Content of file {d}\n", .{i});
            defer allocator.free(content);
            try file.writeAll(content);
        }

        // Add and commit all files
        const add_result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "git", "add", "." },
            .cwd = repo_path,
        });
        defer allocator.free(add_result.stdout);
        defer allocator.free(add_result.stderr);

        const commit_result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "git", "commit", "-m", "Initial commit" },
            .cwd = repo_path,
        });
        defer allocator.free(commit_result.stdout);
        defer allocator.free(commit_result.stderr);

        // Create some tags
        const tag_result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "git", "tag", "v1.0" },
            .cwd = repo_path,
        });
        defer allocator.free(tag_result.stdout);
        defer allocator.free(tag_result.stderr);

        // Open the repository with ziggit
        const repo = try ziggit.Repository.open(allocator, repo_path);
        
        return OptimizationBench{
            .repo = repo,
            .allocator = allocator,
            .path = try allocator.dupe(u8, repo_path),
        };
    }

    fn deinit(self: *OptimizationBench) void {
        self.repo.close();
        std.fs.deleteTreeAbsolute(self.path) catch {};
        self.allocator.free(self.path);
    }

    fn benchmarkStatusOptimization(self: *OptimizationBench) !void {
        print("=== Status Operation Optimization Analysis ===\n", .{});
        
        const iterations = 100;
        var total_time: u64 = 0;

        // Benchmark current implementation
        print("Testing clean repository status (should hit fast path)...\n", .{});
        for (0..iterations) |_| {
            const start = std.time.nanoTimestamp();
            const status = try self.repo.statusPorcelain(self.allocator);
            const end = std.time.nanoTimestamp();
            
            self.allocator.free(status);
            total_time += @as(u64, @intCast(end - start));
        }

        const avg_time = total_time / iterations;
        print("Average status time: {d}ns ({d:.2}μs)\n", .{ avg_time, @as(f64, @floatFromInt(avg_time)) / 1000.0 });

        // Test cached vs uncached performance
        print("\nTesting cached vs uncached performance...\n", .{});
        
        // First call (uncached)
        const start_uncached = std.time.nanoTimestamp();
        const status1 = try self.repo.statusPorcelain(self.allocator);
        const end_uncached = std.time.nanoTimestamp();
        self.allocator.free(status1);
        
        // Second call (potentially cached)
        const start_cached = std.time.nanoTimestamp();
        const status2 = try self.repo.statusPorcelain(self.allocator);
        const end_cached = std.time.nanoTimestamp();
        self.allocator.free(status2);

        const uncached_time = @as(u64, @intCast(end_uncached - start_uncached));
        const cached_time = @as(u64, @intCast(end_cached - start_cached));

        print("Uncached status: {d}ns ({d:.2}μs)\n", .{ uncached_time, @as(f64, @floatFromInt(uncached_time)) / 1000.0 });
        print("Cached status: {d}ns ({d:.2}μs)\n", .{ cached_time, @as(f64, @floatFromInt(cached_time)) / 1000.0 });
        
        if (cached_time < uncached_time) {
            const speedup = @as(f64, @floatFromInt(uncached_time)) / @as(f64, @floatFromInt(cached_time));
            print("Cache speedup: {d:.1}x\n", .{speedup});
        }
    }

    fn benchmarkCleanCheck(self: *OptimizationBench) !void {
        print("\n=== Clean Check Optimization Analysis ===\n", .{});
        
        const iterations = 100;
        var total_time: u64 = 0;

        for (0..iterations) |_| {
            const start = std.time.nanoTimestamp();
            const is_clean = try self.repo.isClean();
            const end = std.time.nanoTimestamp();
            
            _ = is_clean; // Should be true for our clean repo
            total_time += @as(u64, @intCast(end - start));
        }

        const avg_time = total_time / iterations;
        print("Average clean check time: {d}ns ({d:.2}μs)\n", .{ avg_time, @as(f64, @floatFromInt(avg_time)) / 1000.0 });
        
        // Test if the ultra-fast path is being used
        print("Clean repository should always return true with ultra-fast path\n", .{});
    }

    fn benchmarkRevParseOptimization(self: *OptimizationBench) !void {
        print("\n=== Rev-parse HEAD Optimization Analysis ===\n", .{});
        
        const iterations = 100;
        var total_time: u64 = 0;

        for (0..iterations) |_| {
            const start = std.time.nanoTimestamp();
            const hash = try self.repo.revParseHead();
            const end = std.time.nanoTimestamp();
            
            _ = hash;
            total_time += @as(u64, @intCast(end - start));
        }

        const avg_time = total_time / iterations;
        print("Average rev-parse time: {d}ns ({d:.2}μs)\n", .{ avg_time, @as(f64, @floatFromInt(avg_time)) / 1000.0 });
        print("This should be very fast (2 file reads) with caching\n", .{});
    }

    fn measureOptimizationImpact(self: *OptimizationBench) !void {
        print("\n=== Optimization Impact Measurement ===\n", .{});
        
        // Clear any existing caches by creating a new repo instance
        self.repo.close();
        self.repo = try ziggit.Repository.open(self.allocator, self.path);
        
        print("Measuring first vs subsequent calls (cache effectiveness):\n", .{});
        
        // Rev-parse HEAD caching test
        var rev_parse_times: [10]u64 = undefined;
        for (0..10) |i| {
            const start = std.time.nanoTimestamp();
            const hash = try self.repo.revParseHead();
            const end = std.time.nanoTimestamp();
            _ = hash;
            rev_parse_times[i] = @as(u64, @intCast(end - start));
        }
        
        print("Rev-parse times (ns): ", .{});
        for (rev_parse_times) |time| {
            print("{d} ", .{time});
        }
        print("\n", .{});
        
        // Status caching test
        var status_times: [5]u64 = undefined;
        for (0..5) |i| {
            const start = std.time.nanoTimestamp();
            const status = try self.repo.statusPorcelain(self.allocator);
            const end = std.time.nanoTimestamp();
            self.allocator.free(status);
            status_times[i] = @as(u64, @intCast(end - start));
        }
        
        print("Status times (ns): ", .{});
        for (status_times) |time| {
            print("{d} ", .{time});
        }
        print("\n", .{});
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    print("=== Ziggit Optimization Analysis ===\n", .{});
    print("Analyzing current performance to identify optimization opportunities\n\n", .{});

    var bench = try OptimizationBench.init(allocator);
    defer bench.deinit();

    try bench.benchmarkRevParseOptimization();
    try bench.benchmarkStatusOptimization();
    try bench.benchmarkCleanCheck();
    try bench.measureOptimizationImpact();

    print("\n=== Analysis Summary ===\n", .{});
    print("This benchmark helps identify which optimizations are working\n", .{});
    print("and which operations need further optimization.\n", .{});
}