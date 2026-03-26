const std = @import("std");
const print = std.debug.print;
const ziggit = @import("ziggit");

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

fn benchmarkIndexParsing(allocator: std.mem.Allocator, repo_path: []const u8) !void {
    var repo = try ziggit.Repository.open(allocator, repo_path);
    defer repo.close();
    
    // Import the index parser directly
    const index_parser = @import("../src/lib/index_parser.zig");
    
    var index_path_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const index_path = try std.fmt.bufPrint(&index_path_buf, "{s}/index", .{repo.git_dir});
    
    const IndexWrapper = struct {
        allocator: std.mem.Allocator,
        index_path: []const u8,
        
        fn parse(self: @This()) !void {
            var git_index = try index_parser.GitIndex.readFromFile(self.allocator, self.index_path);
            defer git_index.deinit();
        }
    };
    
    const wrapper = IndexWrapper{ .allocator = allocator, .index_path = index_path };
    _ = try benchmark(allocator, "Index parsing", 100, IndexWrapper.parse, .{wrapper});
}

fn benchmarkFileStat(allocator: std.mem.Allocator, repo_path: []const u8) !void {
    var repo = try ziggit.Repository.open(allocator, repo_path);
    defer repo.close();
    
    const index_parser = @import("../src/lib/index_parser.zig");
    
    var index_path_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const index_path = try std.fmt.bufPrint(&index_path_buf, "{s}/index", .{repo.git_dir});
    
    var git_index = try index_parser.GitIndex.readFromFile(allocator, index_path);
    defer git_index.deinit();
    
    if (git_index.entries.items.len == 0) return;
    
    const first_entry = git_index.entries.items[0];
    var file_path_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const file_path = try std.fmt.bufPrint(&file_path_buf, "{s}/{s}", .{ repo_path, first_entry.path });
    
    const StatWrapper = struct {
        file_path: []const u8,
        
        fn stat(self: @This()) !void {
            _ = try std.fs.cwd().statFile(self.file_path);
        }
    };
    
    const wrapper = StatWrapper{ .file_path = file_path };
    _ = try benchmark(allocator, "Single file stat", 1000, StatWrapper.stat, .{wrapper});
}

fn benchmarkAllFileStat(allocator: std.mem.Allocator, repo_path: []const u8) !void {
    var repo = try ziggit.Repository.open(allocator, repo_path);
    defer repo.close();
    
    const index_parser = @import("../src/lib/index_parser.zig");
    
    var index_path_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const index_path = try std.fmt.bufPrint(&index_path_buf, "{s}/index", .{repo.git_dir});
    
    var git_index = try index_parser.GitIndex.readFromFile(allocator, index_path);
    defer git_index.deinit();
    
    const StatAllWrapper = struct {
        allocator: std.mem.Allocator,
        repo_path: []const u8,
        entries: []const @TypeOf(git_index.entries.items[0]),
        
        fn statAll(self: @This()) !void {
            for (self.entries) |entry| {
                var file_path_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
                const file_path = try std.fmt.bufPrint(&file_path_buf, "{s}/{s}", .{ self.repo_path, entry.path });
                _ = std.fs.cwd().statFile(file_path) catch continue;
            }
        }
    };
    
    const wrapper = StatAllWrapper{ 
        .allocator = allocator, 
        .repo_path = repo_path, 
        .entries = git_index.entries.items 
    };
    _ = try benchmark(allocator, "All files stat", 100, StatAllWrapper.statAll, .{wrapper});
}

fn benchmarkDirIteration(allocator: std.mem.Allocator, repo_path: []const u8) !void {
    const DirWrapper = struct {
        repo_path: []const u8,
        
        fn iterate(self: @This()) !void {
            var dir = try std.fs.cwd().openDir(self.repo_path, .{ .iterate = true });
            defer dir.close();
            
            var iterator = dir.iterate();
            while (try iterator.next()) |entry| {
                if (entry.kind != .file) continue;
                if (std.mem.startsWith(u8, entry.name, ".git")) continue;
                // Just iterate, don't do anything
            }
        }
    };
    
    const wrapper = DirWrapper{ .repo_path = repo_path };
    _ = try benchmark(allocator, "Directory iteration", 100, DirWrapper.iterate, .{wrapper});
}

fn benchmarkFullStatus(allocator: std.mem.Allocator, repo_path: []const u8) !void {
    var repo = try ziggit.Repository.open(allocator, repo_path);
    defer repo.close();
    
    const StatusWrapper = struct {
        repo: *const ziggit.Repository,
        allocator: std.mem.Allocator,
        
        fn status(self: @This()) !void {
            const result = try self.repo.statusPorcelain(self.allocator);
            defer self.allocator.free(result);
        }
    };
    
    const wrapper = StatusWrapper{ .repo = &repo, .allocator = allocator };
    _ = try benchmark(allocator, "Full status", 100, StatusWrapper.status, .{wrapper});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const repo_path = "/tmp/ziggit_bench_repo";
    
    print("=== Status Operation Bottleneck Analysis ===\n", .{});
    print("Repository: {s}\n", .{repo_path});
    print("\n", .{});
    
    try benchmarkIndexParsing(allocator, repo_path);
    try benchmarkFileStat(allocator, repo_path);
    try benchmarkAllFileStat(allocator, repo_path);
    try benchmarkDirIteration(allocator, repo_path);
    try benchmarkFullStatus(allocator, repo_path);
    
    print("\n=== Analysis ===\n", .{});
    print("This breakdown shows where time is spent in status operations.\n", .{});
    print("Use this data to identify optimization targets.\n", .{});
}