const std = @import("std");
const print = std.debug.print;

// Simple benchmark focused on core ziggit functionality
// Optimized for minimal disk usage and maximum insight
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    print("=== Ziggit Core Performance Benchmark ===\n", .{});
    print("Testing fundamental operations with minimal overhead...\n\n", .{});

    // Create minimal test repo
    const test_dir = try createMinimalTestRepo(allocator);
    defer cleanupTestRepo(test_dir);

    // Set current directory to test repo for commands
    const original_cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(original_cwd);
    
    try std.process.changeCurDir(test_dir);
    defer std.process.changeCurDir(original_cwd) catch {};

    print("Test Repository: {s}\n\n", .{test_dir});

    // Benchmark critical operations
    const operations = [_]Operation{
        .{ .name = "Help Command", .ziggit_args = &.{"--help"}, .git_args = &.{"--help"} },
        .{ .name = "Status Check", .ziggit_args = &.{"status"}, .git_args = &.{"status", "--porcelain"} },
        .{ .name = "Version Check", .ziggit_args = &.{"--version"}, .git_args = &.{"--version"} },
    };

    // Results table header
    print("Operation               | Git CLI Time | Ziggit Time | Speedup\n", .{});
    print("------------------------|-------------|-------------|--------\n", .{});

    for (operations) |op| {
        const git_time = benchmarkCommand(allocator, "git", op.git_args);
        const ziggit_time = benchmarkCommand(allocator, "/root/ziggit/zig-out/bin/ziggit", op.ziggit_args);
        
        if (git_time > 0 and ziggit_time > 0) {
            const speedup = @as(f64, @floatFromInt(git_time)) / @as(f64, @floatFromInt(ziggit_time));
            print("{s:23} | ", .{op.name});
            formatTime(git_time);
            print(" | ", .{});
            formatTime(ziggit_time);
            print(" | {d:.2}x\n", .{speedup});
        } else if (ziggit_time > 0) {
            print("{s:23} | N/A         | ", .{op.name});
            formatTime(ziggit_time);
            print(" | N/A\n", .{});
        } else if (git_time > 0) {
            print("{s:23} | ", .{op.name});
            formatTime(git_time);
            print(" | N/A         | N/A\n", .{});
        } else {
            print("{s:23} | Error       | Error       | N/A\n", .{op.name});
        }
    }

    print("\nBenchmark completed!\n", .{});
}

const Operation = struct {
    name: []const u8,
    ziggit_args: []const []const u8,
    git_args: []const []const u8,
};

fn createMinimalTestRepo(allocator: std.mem.Allocator) ![]u8 {
    const test_path = "/root/tmp/simple_bench_repo";
    
    // Clean up any existing repo
    std.fs.cwd().deleteTree(test_path) catch {};
    
    // Create directory
    try std.fs.cwd().makeDir(test_path);
    
    // Initialize git repo
    _ = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{"git", "init"},
        .cwd = test_path,
    }) catch {};
    
    // Configure git
    _ = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{"git", "config", "user.name", "Benchmark Test"},
        .cwd = test_path,
    }) catch {};
    
    _ = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{"git", "config", "user.email", "test@ziggit.dev"},
        .cwd = test_path,
    }) catch {};
    
    // Create a single file and commit
    const test_file = try std.fs.path.join(allocator, &[_][]const u8{test_path, "README.md"});
    defer allocator.free(test_file);
    
    try std.fs.cwd().writeFile(.{.sub_path = test_file, .data = "# Test Repository\nMinimal repo for benchmarking\n"});
    
    _ = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{"git", "add", "README.md"},
        .cwd = test_path,
    }) catch {};
    
    _ = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{"git", "commit", "-m", "Initial commit"},
        .cwd = test_path,
    }) catch {};
    
    return try allocator.dupe(u8, test_path);
}

fn cleanupTestRepo(test_path: []const u8) void {
    std.fs.cwd().deleteTree(test_path) catch {};
}

fn benchmarkCommand(allocator: std.mem.Allocator, program: []const u8, args: []const []const u8) u64 {
    var full_args = std.ArrayList([]const u8).init(allocator);
    defer full_args.deinit();
    
    full_args.append(program) catch return 0;
    for (args) |arg| {
        full_args.append(arg) catch return 0;
    }
    
    const iterations = 5; // Reduced iterations to save time and disk
    var total_time: u64 = 0;
    var successful_runs: u32 = 0;
    
    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        const start = std.time.nanoTimestamp();
        
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = full_args.items,
            .max_output_bytes = 1024, // Limit output to save memory
        }) catch {
            continue; // Skip failed runs
        };
        
        const end = std.time.nanoTimestamp();
        
        // Free the output immediately to save memory
        allocator.free(result.stdout);
        allocator.free(result.stderr);
        
        if (result.term.Exited == 0 or result.term.Exited == 1) { // Accept exit code 0 or 1 (some git commands exit with 1 on empty repos)
            total_time += @as(u64, @intCast(end - start));
            successful_runs += 1;
        }
    }
    
    return if (successful_runs > 0) total_time / successful_runs else 0;
}

fn formatTime(ns: u64) void {
    if (ns < 1_000) {
        print("{d:3}ns", .{ns});
    } else if (ns < 1_000_000) {
        print("{d:3.0}μs", .{@as(f64, @floatFromInt(ns)) / 1_000.0});
    } else if (ns < 1_000_000_000) {
        print("{d:3.1}ms", .{@as(f64, @floatFromInt(ns)) / 1_000_000.0});
    } else {
        print("{d:3.2}s ", .{@as(f64, @floatFromInt(ns)) / 1_000_000_000.0});
    }
}