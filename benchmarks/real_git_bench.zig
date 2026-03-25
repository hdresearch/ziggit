const std = @import("std");
const print = std.debug.print;

// Import ziggit C API
const c = @cImport({
    @cInclude("ziggit.h");
});

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

fn runCommand(allocator: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8) !std.process.Child.RunResult {
    return try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .cwd = cwd,
    });
}

fn benchmark(comptime name: []const u8, iterations: usize, func: anytype, args: anytype) !u64 {
    var total_time: u64 = 0;
    var min_time: u64 = std.math.maxInt(u64);
    var max_time: u64 = 0;

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const start = std.time.nanoTimestamp();
        _ = try @call(.auto, func, args);
        const end = std.time.nanoTimestamp();
        
        const duration = @as(u64, @intCast(end - start));
        total_time += duration;
        min_time = @min(min_time, duration);
        max_time = @max(max_time, duration);
    }

    const mean_time = total_time / iterations;
    
    print("{s:25} | ", .{name});
    formatDuration(mean_time);
    print("{s}", .{" | min: "});
    formatDuration(min_time);
    print("{s}", .{" | max: "});
    formatDuration(max_time);
    print("{s}", .{"\n"});
    
    return mean_time;
}

fn gitStatus(allocator: std.mem.Allocator, repo_path: []const u8) !void {
    const result = try runCommand(allocator, &.{"git", "-C", repo_path, "status", "--porcelain"}, null);
    allocator.free(result.stdout);
    allocator.free(result.stderr);
    if (result.term != .Exited or result.term.Exited != 0) {
        return error.GitFailed;
    }
}

fn gitRevParseHead(allocator: std.mem.Allocator, repo_path: []const u8) !void {
    const result = try runCommand(allocator, &.{"git", "-C", repo_path, "rev-parse", "HEAD"}, null);
    allocator.free(result.stdout);
    allocator.free(result.stderr);
    // It's ok if this fails for empty repos
}

fn gitDescribe(allocator: std.mem.Allocator, repo_path: []const u8) !void {
    const result = try runCommand(allocator, &.{"git", "-C", repo_path, "describe", "--tags", "--abbrev=0"}, null);
    allocator.free(result.stdout);
    allocator.free(result.stderr);
    // It's ok if this fails for repos with no tags
}

fn ziggitStatusPorcelain(repo_path: []const u8) !void {
    const path_cstr = try std.heap.c_allocator.dupeZ(u8, repo_path);
    defer std.heap.c_allocator.free(path_cstr);
    
    const repo = c.ziggit_repo_open(path_cstr.ptr);
    defer if (repo) |r| c.ziggit_repo_close(r);
    
    if (repo) |r| {
        var buffer: [4096]u8 = undefined;
        const result = c.ziggit_status_porcelain(r, &buffer, buffer.len);
        if (result != 0) {
            return error.ZiggitFailed;
        }
    } else {
        return error.ZiggitOpenFailed;
    }
}

fn ziggitRevParseHead(repo_path: []const u8) !void {
    const path_cstr = try std.heap.c_allocator.dupeZ(u8, repo_path);
    defer std.heap.c_allocator.free(path_cstr);
    
    const repo = c.ziggit_repo_open(path_cstr.ptr);
    defer if (repo) |r| c.ziggit_repo_close(r);
    
    if (repo) |r| {
        var buffer: [64]u8 = undefined;
        const result = c.ziggit_rev_parse_head(r, &buffer, buffer.len);
        if (result != 0) {
            return error.ZiggitFailed;
        }
    } else {
        return error.ZiggitOpenFailed;
    }
}

fn ziggitDescribeTags(repo_path: []const u8) !void {
    const path_cstr = try std.heap.c_allocator.dupeZ(u8, repo_path);
    defer std.heap.c_allocator.free(path_cstr);
    
    const repo = c.ziggit_repo_open(path_cstr.ptr);
    defer if (repo) |r| c.ziggit_repo_close(r);
    
    if (repo) |r| {
        var buffer: [256]u8 = undefined;
        const result = c.ziggit_describe_tags(r, &buffer, buffer.len);
        if (result != 0) {
            return error.ZiggitFailed;
        }
    } else {
        return error.ZiggitOpenFailed;
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    print("{s}\n", .{"=== Real Git Repository Benchmark ==="});
    print("{s}\n", .{"Setting up test repository with git CLI..."});
    
    const test_dir = "/tmp/ziggit_real_bench";
    
    // Clean up any existing test directory
    std.fs.deleteTreeAbsolute(test_dir) catch {};
    
    // Create test repository with real git
    try std.fs.makeDirAbsolute(test_dir);
    
    // Initialize git repo
    _ = try runCommand(allocator, &.{"git", "init"}, test_dir);
    _ = try runCommand(allocator, &.{"git", "config", "user.name", "Benchmark"}, test_dir);
    _ = try runCommand(allocator, &.{"git", "config", "user.email", "bench@test.com"}, test_dir);
    
    // Create some files
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const filename = try std.fmt.allocPrint(allocator, "{s}/file{d}.txt", .{test_dir, i});
        defer allocator.free(filename);
        const content = try std.fmt.allocPrint(allocator, "Content for file {d}\nLine 2\nLine 3\n", .{i});
        defer allocator.free(content);
        const file = try std.fs.createFileAbsolute(filename, .{});
        defer file.close();
        try file.writeAll(content);
    }
    
    // Add files and create commits
    _ = try runCommand(allocator, &.{"git", "add", "."}, test_dir);
    _ = try runCommand(allocator, &.{"git", "commit", "-m", "Initial commit with 100 files"}, test_dir);
    
    // Create a tag
    _ = try runCommand(allocator, &.{"git", "tag", "v1.0.0"}, test_dir);
    
    // Create more commits
    var commit_num: usize = 2;
    while (commit_num <= 5) : (commit_num += 1) {
        // Modify some files
        var file_num: usize = 0;
        while (file_num < 20) : (file_num += 1) {
            const filename = try std.fmt.allocPrint(allocator, "{s}/file{d}.txt", .{test_dir, file_num});
            defer allocator.free(filename);
            const content = try std.fmt.allocPrint(allocator, "Modified content {d} for file {d}\n", .{commit_num, file_num});
            defer allocator.free(content);
            const file = try std.fs.createFileAbsolute(filename, .{});
            defer file.close();
            try file.writeAll(content);
        }
        
        _ = try runCommand(allocator, &.{"git", "add", "."}, test_dir);
        const commit_msg = try std.fmt.allocPrint(allocator, "Commit number {d}", .{commit_num});
        defer allocator.free(commit_msg);
        _ = try runCommand(allocator, &.{"git", "commit", "-m", commit_msg}, test_dir);
    }
    
    print("{s}\n\n", .{"Test repository created with 100 files and 5 commits"});
    
    const iterations = 100;
    
    print("Benchmarking with {d} iterations:\n", .{iterations});
    print("{s:25} | {s:10} | {s:10} | {s:10}\n", .{"Operation", "Mean", "Min", "Max"});
    print("{s}\n", .{"----------------------------------------------------------------------"});
    
    // Benchmark git CLI operations
    _ = try benchmark("git status --porcelain", iterations, gitStatus, .{allocator, test_dir});
    _ = try benchmark("git rev-parse HEAD", iterations, gitRevParseHead, .{allocator, test_dir});
    _ = try benchmark("git describe --tags", iterations, gitDescribe, .{allocator, test_dir});
    
    print("{s}\n", .{"----------------------------------------------------------------------"});
    
    // Benchmark ziggit operations
    _ = try benchmark("ziggit_status_porcelain", iterations, ziggitStatusPorcelain, .{test_dir});
    _ = try benchmark("ziggit_rev_parse_head", iterations, ziggitRevParseHead, .{test_dir});
    _ = try benchmark("ziggit_describe_tags", iterations, ziggitDescribeTags, .{test_dir});
    
    print("{s}\n", .{""});
    
    // Clean up
    std.fs.deleteTreeAbsolute(test_dir) catch {};
    
    print("{s}\n", .{"Benchmark completed!"});
}