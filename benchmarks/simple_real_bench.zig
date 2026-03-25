const std = @import("std");

// Import the C library
const c = @cImport({
    @cInclude("ziggit.h");
});

const BENCHMARK_ITERATIONS = 100;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    std.debug.print("=== Simple Ziggit vs Git CLI Benchmark ===\n\n", .{});

    // Use current repository (.)
    const repo_path = ".";

    // Benchmark 1: Rev-parse HEAD (the hot path for bun)
    try benchmarkRevParseHead(repo_path, allocator);

    // Benchmark 2: Status porcelain (the other hot path for bun)
    try benchmarkStatusPorcelain(repo_path, allocator);

    std.debug.print("\n=== Benchmark Complete ===\n", .{});
}

fn runCommand(cmd: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var child = std.process.Child.init(&[_][]const u8{ "sh", "-c", cmd }, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    const stdout = try child.stdout.?.readToEndAlloc(allocator, 1024 * 1024);
    const stderr = try child.stderr.?.readToEndAlloc(allocator, 1024 * 1024);
    const term = try child.wait();

    if (term != .Exited or term.Exited != 0) {
        std.debug.print("Command failed: {s}\n", .{cmd});
        std.debug.print("stderr: {s}\n", .{stderr});
        return error.CommandFailed;
    }

    return stdout;
}

fn benchmarkRevParseHead(repo_path: []const u8, allocator: std.mem.Allocator) !void {
    std.debug.print("=== Rev-Parse HEAD Benchmark (Bun Hot Path) ===\n", .{});

    // Benchmark ziggit
    const ziggit_start = std.time.milliTimestamp();
    var ziggit_success_count: usize = 0;
    
    const repo_path_z = try allocator.dupeZ(u8, repo_path);
    defer allocator.free(repo_path_z);
    
    const repo = c.ziggit_repo_open(repo_path_z.ptr);
    if (repo == null) {
        std.debug.print("Failed to open repository with ziggit\n", .{});
        return;
    }
    defer c.ziggit_repo_close(repo);

    var buffer: [64]u8 = undefined;
    
    var i: usize = 0;
    while (i < BENCHMARK_ITERATIONS) : (i += 1) {
        const result = c.ziggit_rev_parse_head(repo, &buffer, buffer.len);
        if (result == 0) {
            ziggit_success_count += 1;
        }
    }
    
    const ziggit_end = std.time.milliTimestamp();
    const ziggit_duration = ziggit_end - ziggit_start;

    // Benchmark git CLI
    const git_start = std.time.milliTimestamp();
    var git_success_count: usize = 0;
    
    i = 0;
    while (i < BENCHMARK_ITERATIONS) : (i += 1) {
        const cmd = try std.fmt.allocPrint(allocator, "cd {s} && git rev-parse HEAD", .{repo_path});
        defer allocator.free(cmd);
        
        const result = runCommand(cmd, allocator) catch "";
        defer allocator.free(result);
        
        if (result.len >= 40) { // Valid commit hash
            git_success_count += 1;
        }
    }
    
    const git_end = std.time.milliTimestamp();
    const git_duration = git_end - git_start;

    // Print results
    std.debug.print("Iterations: {}\n", .{BENCHMARK_ITERATIONS});
    std.debug.print("Ziggit rev-parse HEAD: {} ms ({} successes) - {d:.2} ms per operation\n", .{ ziggit_duration, ziggit_success_count, @as(f64, @floatFromInt(ziggit_duration)) / @as(f64, @floatFromInt(BENCHMARK_ITERATIONS)) });
    std.debug.print("Git CLI rev-parse HEAD: {} ms ({} successes) - {d:.2} ms per operation\n", .{ git_duration, git_success_count, @as(f64, @floatFromInt(git_duration)) / @as(f64, @floatFromInt(BENCHMARK_ITERATIONS)) });
    
    if (git_duration > 0) {
        const speedup = @as(f64, @floatFromInt(git_duration)) / @as(f64, @floatFromInt(ziggit_duration));
        std.debug.print("Ziggit is {d:.1} x faster\n\n", .{speedup});
    }
}

fn benchmarkStatusPorcelain(repo_path: []const u8, allocator: std.mem.Allocator) !void {
    std.debug.print("=== Status Porcelain Benchmark (Bun Hot Path) ===\n", .{});

    // Benchmark ziggit
    const ziggit_start = std.time.milliTimestamp();
    var ziggit_success_count: usize = 0;
    
    const repo_path_z = try allocator.dupeZ(u8, repo_path);
    defer allocator.free(repo_path_z);
    
    const repo = c.ziggit_repo_open(repo_path_z.ptr);
    if (repo == null) {
        std.debug.print("Failed to open repository with ziggit\n", .{});
        return;
    }
    defer c.ziggit_repo_close(repo);

    var buffer: [4096]u8 = undefined;
    
    var i: usize = 0;
    while (i < BENCHMARK_ITERATIONS) : (i += 1) {
        const result = c.ziggit_status_porcelain(repo, &buffer, buffer.len);
        if (result == 0) {
            ziggit_success_count += 1;
        }
    }
    
    const ziggit_end = std.time.milliTimestamp();
    const ziggit_duration = ziggit_end - ziggit_start;

    // Benchmark git CLI
    const git_start = std.time.milliTimestamp();
    var git_success_count: usize = 0;
    
    i = 0;
    while (i < BENCHMARK_ITERATIONS) : (i += 1) {
        const cmd = try std.fmt.allocPrint(allocator, "cd {s} && git status --porcelain", .{repo_path});
        defer allocator.free(cmd);
        
        const result = runCommand(cmd, allocator) catch "";
        defer allocator.free(result);
        
        if (result.len >= 0) { // Command succeeded (even empty output is success)
            git_success_count += 1;
        }
    }
    
    const git_end = std.time.milliTimestamp();
    const git_duration = git_end - git_start;

    // Print results
    std.debug.print("Iterations: {}\n", .{BENCHMARK_ITERATIONS});
    std.debug.print("Ziggit status --porcelain: {} ms ({} successes) - {d:.2} ms per operation\n", .{ ziggit_duration, ziggit_success_count, @as(f64, @floatFromInt(ziggit_duration)) / @as(f64, @floatFromInt(BENCHMARK_ITERATIONS)) });
    std.debug.print("Git CLI status --porcelain: {} ms ({} successes) - {d:.2} ms per operation\n", .{ git_duration, git_success_count, @as(f64, @floatFromInt(git_duration)) / @as(f64, @floatFromInt(BENCHMARK_ITERATIONS)) });
    
    if (git_duration > 0) {
        const speedup = @as(f64, @floatFromInt(git_duration)) / @as(f64, @floatFromInt(ziggit_duration));
        std.debug.print("Ziggit is {d:.1} x faster\n\n", .{speedup});
    }
}