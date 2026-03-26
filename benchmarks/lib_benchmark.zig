const std = @import("std");
const print = std.debug.print;

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

// Git CLI benchmark functions
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

// Ziggit CLI benchmark functions (fallback to CLI since library is broken)
fn ziggitStatusCLI(allocator: std.mem.Allocator, repo_path: []const u8) !void {
    const result = try runCommand(allocator, &.{"/root/ziggit/zig-out/bin/ziggit", "-C", repo_path, "status", "--porcelain"}, null);
    allocator.free(result.stdout);
    allocator.free(result.stderr);
    if (result.term != .Exited or result.term.Exited != 0) {
        return error.ZiggitFailed;
    }
}

fn ziggitLogCLI(allocator: std.mem.Allocator, repo_path: []const u8) !void {
    const result = try runCommand(allocator, &.{"/root/ziggit/zig-out/bin/ziggit", "-C", repo_path, "log", "--oneline"}, null);
    allocator.free(result.stdout);
    allocator.free(result.stderr);
    if (result.term != .Exited or result.term.Exited != 0) {
        return error.ZiggitFailed;
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    print("{s}\n", .{"=== Library API Performance Benchmark ==="});
    print("{s}\n", .{"Note: Ziggit library API has compilation issues, using CLI fallback"});
    print("{s}\n", .{"Setting up test repository with git CLI..."});
    
    const test_dir = "/tmp/ziggit_lib_bench";
    
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
    while (i < 20) : (i += 1) {
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
    _ = try runCommand(allocator, &.{"git", "commit", "-m", "Initial commit with 20 files"}, test_dir);
    
    // Create a tag
    _ = try runCommand(allocator, &.{"git", "tag", "v1.0.0"}, test_dir);
    
    // Create more commits
    var commit_num: usize = 2;
    while (commit_num <= 3) : (commit_num += 1) {
        // Modify some files
        var file_num: usize = 0;
        while (file_num < 5) : (file_num += 1) {
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
    
    print("{s}\n\n", .{"Test repository created with 20 files and 3 commits"});
    
    const iterations = 25;
    
    print("Benchmarking with {d} iterations:\n", .{iterations});
    print("{s:25} | {s:10} | {s:10} | {s:10}\n", .{"Operation", "Mean", "Min", "Max"});
    print("{s}\n", .{"----------------------------------------------------------------------"});
    
    // Benchmark git CLI operations
    _ = benchmark("git status --porcelain", iterations, gitStatus, .{allocator, test_dir}) catch |err| {
        print("git status benchmark failed: {}\n", .{err});
        return;
    };
    _ = benchmark("git rev-parse HEAD", iterations, gitRevParseHead, .{allocator, test_dir}) catch |err| {
        print("git rev-parse benchmark failed: {}\n", .{err});
        return;
    };
    _ = benchmark("git describe --tags", iterations, gitDescribe, .{allocator, test_dir}) catch |err| {
        print("git describe benchmark failed: {}\n", .{err});
        return;
    };
    
    print("{s}\n", .{"----------------------------------------------------------------------"});
    
    // Benchmark ziggit CLI operations (as library API fallback)
    _ = benchmark("ziggit status (CLI)", iterations, ziggitStatusCLI, .{allocator, test_dir}) catch |err| {
        print("ziggit status benchmark failed: {}\n", .{err});
        print("Note: This is expected if ziggit binary is not built or functional\n", .{});
    };
    _ = benchmark("ziggit log (CLI)", iterations, ziggitLogCLI, .{allocator, test_dir}) catch |err| {
        print("ziggit log benchmark failed: {}\n", .{err});
        print("Note: This is expected if ziggit binary is not built or functional\n", .{});
    };
    
    print("{s}\n", .{""});
    print("{s}\n", .{"Note: ziggit library API could not be tested due to compilation issues"});
    print("{s}\n", .{"in src/lib/ziggit.zig maintained by another agent."});
    print("{s}\n", .{"CLI fallback used instead for performance comparison."});
    
    // Clean up
    std.fs.deleteTreeAbsolute(test_dir) catch {};
    
    print("{s}\n", .{"Library benchmark completed!"});
}