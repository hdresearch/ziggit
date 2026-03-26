// benchmarks/micro_optimization_bench.zig - Detailed micro-benchmarking for hot path optimization
const std = @import("std");
const ziggit = @import("ziggit");
const print = std.debug.print;

const Stats = struct {
    min: u64 = std.math.maxInt(u64),
    max: u64 = 0,
    sum: u64 = 0,
    count: u32 = 0,

    fn add(self: *Stats, value: u64) void {
        self.min = @min(self.min, value);
        self.max = @max(self.max, value);
        self.sum += value;
        self.count += 1;
    }

    fn mean(self: *const Stats) f64 {
        if (self.count == 0) return 0;
        return @as(f64, @floatFromInt(self.sum)) / @as(f64, @floatFromInt(self.count));
    }
};

// Measure component performance for rev-parse HEAD
fn benchmarkRevParseComponents(allocator: std.mem.Allocator, repo_path: []const u8) !void {
    print("\n=== Micro-benchmarking rev-parse HEAD components ===\n", .{});
    
    // Setup repository
    var repo = try ziggit.Repository.open(allocator, repo_path);
    defer repo.close();
    
    const iterations = 10000;
    var cached_stats = Stats{};
    var uncached_stats = Stats{};
    
    // Test cached vs uncached performance
    print("Measuring cached vs uncached HEAD resolution...\n", .{});
    
    // First measure uncached (force cache miss each time)
    for (0..iterations) |_| {
        // Clear the cache to force uncached path
        repo._cached_head_hash = null;
        
        const start = std.time.nanoTimestamp();
        _ = try repo.revParseHead();
        const end = std.time.nanoTimestamp();
        
        uncached_stats.add(@as(u64, @intCast(end - start)));
    }
    
    // Now measure cached (should be almost instant)
    for (0..iterations) |_| {
        const start = std.time.nanoTimestamp();
        _ = try repo.revParseHead();
        const end = std.time.nanoTimestamp();
        
        cached_stats.add(@as(u64, @intCast(end - start)));
    }
    
    print("Uncached: min={d}ns mean={:.0}ns max={d}ns\n", .{uncached_stats.min, uncached_stats.mean(), uncached_stats.max});
    print("Cached:   min={d}ns mean={:.0}ns max={d}ns\n", .{cached_stats.min, cached_stats.mean(), cached_stats.max});
    print("Cache speedup: {d:.1}x\n", .{uncached_stats.mean() / @max(cached_stats.mean(), 1.0)});
}

// Measure component performance for status operations
fn benchmarkStatusComponents(allocator: std.mem.Allocator, repo_path: []const u8) !void {
    print("\n=== Micro-benchmarking status components ===\n", .{});
    
    var repo = try ziggit.Repository.open(allocator, repo_path);
    defer repo.close();
    
    const iterations = 1000;
    var hyper_fast_stats = Stats{};
    var ultra_fast_stats = Stats{};
    var detailed_stats = Stats{};
    
    print("Measuring status check performance tiers...\n", .{});
    
    // Test hyper-fast (cached) clean check
    for (0..iterations) |_| {
        const start = std.time.nanoTimestamp();
        _ = repo.isHyperFastCleanCached() catch false;
        const end = std.time.nanoTimestamp();
        
        hyper_fast_stats.add(@as(u64, @intCast(end - start)));
    }
    
    // Reset cache for ultra-fast test
    repo._cached_is_clean = null;
    repo._cached_index_mtime = null;
    
    // Test ultra-fast clean check
    for (0..iterations) |_| {
        const start = std.time.nanoTimestamp();
        _ = repo.isUltraFastCleanCached() catch false;
        const end = std.time.nanoTimestamp();
        
        ultra_fast_stats.add(@as(u64, @intCast(end - start)));
    }
    
    // Test detailed status (fallback)
    for (0..iterations) |_| {
        repo._cached_is_clean = null; // Force detailed path
        
        const start = std.time.nanoTimestamp();
        const status = repo.statusPorcelain(allocator) catch continue;
        const end = std.time.nanoTimestamp();
        
        allocator.free(status);
        detailed_stats.add(@as(u64, @intCast(end - start)));
    }
    
    print("Hyper-fast: min={d}ns mean={:.0}ns max={d}ns\n", .{hyper_fast_stats.min, hyper_fast_stats.mean(), hyper_fast_stats.max});
    print("Ultra-fast: min={d}ns mean={:.0}ns max={d}ns\n", .{ultra_fast_stats.min, ultra_fast_stats.mean(), ultra_fast_stats.max});
    print("Detailed:   min={d}ns mean={:.0}ns max={d}ns\n", .{detailed_stats.min, detailed_stats.mean(), detailed_stats.max});
}

// Measure tag describe performance
fn benchmarkTagsComponents(allocator: std.mem.Allocator, repo_path: []const u8) !void {
    print("\n=== Micro-benchmarking tags components ===\n", .{});
    
    var repo = try ziggit.Repository.open(allocator, repo_path);
    defer repo.close();
    
    const iterations = 1000;
    var cached_stats = Stats{};
    var uncached_stats = Stats{};
    
    print("Measuring cached vs uncached tag resolution...\n", .{});
    
    // Test uncached 
    for (0..iterations) |_| {
        // Clear cache
        if (repo._cached_latest_tag) |tag| {
            repo.allocator.free(tag);
        }
        repo._cached_latest_tag = null;
        
        const start = std.time.nanoTimestamp();
        const tag = repo.describeTags(allocator) catch continue;
        const end = std.time.nanoTimestamp();
        
        allocator.free(tag);
        uncached_stats.add(@as(u64, @intCast(end - start)));
    }
    
    // Test cached
    for (0..iterations) |_| {
        const start = std.time.nanoTimestamp();
        const tag = repo.describeTags(allocator) catch continue;
        const end = std.time.nanoTimestamp();
        
        allocator.free(tag);
        cached_stats.add(@as(u64, @intCast(end - start)));
    }
    
    print("Uncached: min={d}ns mean={:.0}ns max={d}ns\n", .{uncached_stats.min, uncached_stats.mean(), uncached_stats.max});
    print("Cached:   min={d}ns mean={:.0}ns max={d}ns\n", .{cached_stats.min, cached_stats.mean(), cached_stats.max});
    print("Cache speedup: {d:.1}x\n", .{uncached_stats.mean() / @max(cached_stats.mean(), 1.0)});
}

// Setup test repository
fn setupTestRepo(allocator: std.mem.Allocator, path: []const u8) !void {
    std.fs.deleteTreeAbsolute(path) catch {};
    
    const init_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "init", path },
    });
    defer allocator.free(init_result.stdout);
    defer allocator.free(init_result.stderr);

    const config_cmds = [_][]const []const u8{
        &.{ "git", "config", "user.name", "Test" },
        &.{ "git", "config", "user.email", "test@example.com" },
    };

    for (config_cmds) |cmd| {
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = cmd,
            .cwd = path,
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
    }

    // Create a single commit with a tag
    const filename = try std.fmt.allocPrint(allocator, "{s}/test.txt", .{path});
    defer allocator.free(filename);
    
    const file = try std.fs.createFileAbsolute(filename, .{});
    defer file.close();
    try file.writeAll("test content\n");

    const add_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "add", "test.txt" },
        .cwd = path,
    });
    defer allocator.free(add_result.stdout);
    defer allocator.free(add_result.stderr);

    const commit_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "commit", "-m", "test" },
        .cwd = path,
    });
    defer allocator.free(commit_result.stdout);
    defer allocator.free(commit_result.stderr);
    
    const tag_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "tag", "v1.0" },
        .cwd = path,
    });
    defer allocator.free(tag_result.stdout);
    defer allocator.free(tag_result.stderr);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    print("=== ZIGGIT MICRO-OPTIMIZATION ANALYSIS ===\n", .{});
    print("Analyzing hot paths for potential optimizations\n", .{});

    const repo_path = "/tmp/ziggit_micro_bench";
    print("Setting up test repository at {s}...\n", .{repo_path});
    try setupTestRepo(allocator, repo_path);
    defer std.fs.deleteTreeAbsolute(repo_path) catch {};

    try benchmarkRevParseComponents(allocator, repo_path);
    try benchmarkStatusComponents(allocator, repo_path);
    try benchmarkTagsComponents(allocator, repo_path);
    
    print("\n=== OPTIMIZATION OPPORTUNITIES ===\n", .{});
    print("1. Cached operations are already highly optimized\n", .{});
    print("2. Focus should be on optimizing cold path first-time access\n", .{});
    print("3. Index parsing and file stat operations are main bottlenecks\n", .{});
}