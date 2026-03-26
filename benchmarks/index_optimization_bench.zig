const std = @import("std");
const print = std.debug.print;

const ziggit = @import("ziggit");

// Import both parsers
const index_parser = ziggit.IndexParser;
const index_parser_fast = ziggit.IndexParserFast;

fn formatDuration(ns: u64) void {
    if (ns < 1_000) {
        print("{d} ns", .{ns});
    } else if (ns < 1_000_000) {
        print("{d:.1} μs", .{@as(f64, @floatFromInt(ns)) / 1_000.0});
    } else if (ns < 1_000_000_000) {
        print("{d:.2} ms", .{@as(f64, @floatFromInt(ns)) / 1_000_000.0});
    } else {
        print("{d:.3} s", .{@as(f64, @floatFromInt(ns)) / 1_000_000_000.0});
    }
}

fn benchmark(allocator: std.mem.Allocator, comptime name: []const u8, iterations: usize, func: anytype, args: anytype) !u64 {
    var times = try allocator.alloc(u64, iterations);
    defer allocator.free(times);
    
    for (0..iterations) |i| {
        const start = std.time.nanoTimestamp();
        _ = try @call(.auto, func, args);
        const end = std.time.nanoTimestamp();
        times[i] = @intCast(end - start);
    }
    
    std.sort.heap(u64, times, {}, std.sort.asc(u64));
    
    var total: u64 = 0;
    for (times) |time| {
        total += time;
    }
    
    const mean = total / iterations;
    print("{s:30} | mean: ", .{name});
    formatDuration(mean);
    print(" | median: ", .{});
    formatDuration(times[iterations / 2]);
    print(" | min: ", .{});
    formatDuration(times[0]);
    print("\n", .{});
    
    return mean;
}

fn benchmarkOriginalParser(allocator: std.mem.Allocator, index_path: []const u8) !u64 {
    const OriginalWrapper = struct {
        allocator: std.mem.Allocator,
        index_path: []const u8,
        
        fn parse(self: @This()) !void {
            var git_index = try index_parser.GitIndex.readFromFile(self.allocator, self.index_path);
            defer git_index.deinit();
        }
    };
    
    const wrapper = OriginalWrapper{ .allocator = allocator, .index_path = index_path };
    return try benchmark(allocator, "Original index parser", 100, OriginalWrapper.parse, .{wrapper});
}

fn benchmarkFastParser(allocator: std.mem.Allocator, index_path: []const u8) !u64 {
    const FastWrapper = struct {
        allocator: std.mem.Allocator,
        index_path: []const u8,
        
        fn parse(self: @This()) !void {
            var fast_index = try index_parser_fast.FastGitIndex.readFromFile(self.allocator, self.index_path);
            defer fast_index.deinit();
        }
    };
    
    const wrapper = FastWrapper{ .allocator = allocator, .index_path = index_path };
    return try benchmark(allocator, "Fast index parser", 100, FastWrapper.parse, .{wrapper});
}

fn testCorrectness(allocator: std.mem.Allocator, index_path: []const u8) !void {
    print("=== Correctness Test ===\n", .{});
    
    var original_index = try index_parser.GitIndex.readFromFile(allocator, index_path);
    defer original_index.deinit();
    
    var fast_index = try index_parser_fast.FastGitIndex.readFromFile(allocator, index_path);
    defer fast_index.deinit();
    
    print("Original parser entries: {d}\n", .{original_index.entries.items.len});
    print("Fast parser entries: {d}\n", .{fast_index.entries.len});
    
    if (original_index.entries.items.len != fast_index.entries.len) {
        print("ERROR: Entry count mismatch!\n", .{});
        return;
    }
    
    // Compare first few entries
    const compare_count = @min(5, original_index.entries.items.len);
    for (0..compare_count) |i| {
        const orig = &original_index.entries.items[i];
        const fast = &fast_index.entries[i];
        
        print("Entry {d}: {s}\n", .{ i, orig.path });
        print("  Original: mtime={d}.{d:0>9}, size={d}\n", .{ orig.mtime_seconds, orig.mtime_nanoseconds, orig.size });
        print("  Fast:     mtime={d}.{d:0>9}, size={d}\n", .{ fast.mtime_seconds, fast.mtime_nanoseconds, fast.size });
        
        if (orig.mtime_seconds != fast.mtime_seconds or 
            orig.mtime_nanoseconds != fast.mtime_nanoseconds or
            orig.size != fast.size or
            !std.mem.eql(u8, orig.path, fast.path)) {
            print("ERROR: Entry {d} mismatch!\n", .{i});
            return;
        }
    }
    
    print("Correctness test PASSED\n", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const repo_path = "/tmp/ziggit_bench_repo";
    var index_path_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const index_path = try std.fmt.bufPrint(&index_path_buf, "{s}/.git/index", .{repo_path});
    
    print("=== Index Parser Optimization Benchmark ===\n", .{});
    print("Index file: {s}\n", .{index_path});
    print("\n", .{});
    
    try testCorrectness(allocator, index_path);
    print("\n", .{});
    
    const original_time = try benchmarkOriginalParser(allocator, index_path);
    const fast_time = try benchmarkFastParser(allocator, index_path);
    
    print("\n", .{});
    const speedup = @as(f64, @floatFromInt(original_time)) / @as(f64, @floatFromInt(fast_time));
    print("Speedup: {d:.1}x faster ({d:.1}% reduction)\n", .{ speedup, 100.0 * (1.0 - @as(f64, @floatFromInt(fast_time)) / @as(f64, @floatFromInt(original_time))) });
    
    const time_saved = original_time - fast_time;
    print("Time saved: ", .{});
    formatDuration(time_saved);
    print(" per operation\n", .{});
}