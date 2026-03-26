const std = @import("std");
const time = std.time;
const process = std.process;

// C interface to ziggit library
extern fn ziggit_repo_open(path: [*:0]const u8) ?*anyopaque;
extern fn ziggit_repo_close(repo: *anyopaque) void;
extern fn ziggit_status_porcelain(repo: *anyopaque, buffer: [*]u8, buffer_size: usize) c_int;
extern fn ziggit_rev_parse_head(repo: *anyopaque, buffer: [*]u8, buffer_size: usize) c_int;
extern fn ziggit_describe_tags(repo: *anyopaque, buffer: [*]u8, buffer_size: usize) c_int;

const BenchResult = struct {
    name: []const u8,
    git_avg_ms: f64,
    ziggit_avg_ms: f64,
    speedup: f64,
    iterations: usize,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("=== Real Ziggit vs Git CLI Benchmark ===", .{});
    std.log.info("Testing the operations bun uses most frequently:", .{});
    std.log.info("", .{});
    
    // Create a test repository with real git
    const test_repo_dir = "bench_real_repo";
    try createRealisticTestRepo(allocator, test_repo_dir);
    defer std.fs.cwd().deleteTree(test_repo_dir) catch {};
    
    var results = std.ArrayList(BenchResult).init(allocator);
    defer results.deinit();
    
    // Benchmark the critical operations for bun
    std.log.info("Running benchmarks...", .{});
    
    // git status --porcelain (most critical for bun)
    try results.append(try benchmarkStatusPorcelain(allocator, test_repo_dir));
    
    // git rev-parse HEAD (second most critical)  
    try results.append(try benchmarkRevParseHead(allocator, test_repo_dir));
    
    // git describe --tags --abbrev=0 (used for version resolution)
    try results.append(try benchmarkDescribeTags(allocator, test_repo_dir));
    
    // Print results table
    printResultsTable(results.items);
}

fn createRealisticTestRepo(allocator: std.mem.Allocator, repo_dir: []const u8) !void {
    // Clean up any existing test repo
    std.fs.cwd().deleteTree(repo_dir) catch {};
    
    // Create directory
    try std.fs.cwd().makeDir(repo_dir);
    
    var cwd_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const original_cwd = try std.process.getCwd(&cwd_buf);
    
    const repo_path = try std.fs.path.resolve(allocator, &[_][]const u8{ original_cwd, repo_dir });
    defer allocator.free(repo_path);
    
    try std.posix.chdir(repo_path);
    defer std.posix.chdir(original_cwd) catch {};
    
    // Initialize git repository
    _ = try runCommand(allocator, &[_][]const u8{ "git", "init", "-q" });
    _ = try runCommand(allocator, &[_][]const u8{ "git", "config", "user.name", "Benchmark User" });
    _ = try runCommand(allocator, &[_][]const u8{ "git", "config", "user.email", "bench@ziggit.com" });
    
    // Create package.json (typical for bun repos)
    const package_json = 
        \\{
        \\  "name": "benchmark-repo",
        \\  "version": "1.0.0",
        \\  "dependencies": {
        \\    "react": "^18.0.0",
        \\    "typescript": "^5.0.0"
        \\  }
        \\}
        \\
    ;
    try std.fs.cwd().writeFile(.{ .sub_path = "package.json", .data = package_json });
    
    // Create some source files (typical bun project structure)
    try std.fs.cwd().makeDir("src");
    try std.fs.cwd().writeFile(.{ .sub_path = "src/index.ts", .data = "export { default } from './main';\n" });
    try std.fs.cwd().writeFile(.{ .sub_path = "src/main.ts", .data = "console.log('Hello from main');\n" });
    try std.fs.cwd().writeFile(.{ .sub_path = "src/utils.ts", .data = "export const greet = () => 'Hello';\n" });
    
    // Create build configuration files
    try std.fs.cwd().writeFile(.{ .sub_path = "tsconfig.json", .data = "{\"compilerOptions\": {\"target\": \"ES2020\"}}\n" });
    try std.fs.cwd().writeFile(.{ .sub_path = "bun.lockb", .data = "binary lockfile content\n" });
    
    // Create more files to simulate a realistic project
    try std.fs.cwd().makeDir("tests");
    try std.fs.cwd().writeFile(.{ .sub_path = "tests/main.test.ts", .data = "test('basic', () => {});\n" });
    
    // Add and commit initial files
    _ = try runCommand(allocator, &[_][]const u8{ "git", "add", "." });
    _ = try runCommand(allocator, &[_][]const u8{ "git", "commit", "-q", "-m", "Initial commit" });
    
    // Create version tags (bun checks these)
    _ = try runCommand(allocator, &[_][]const u8{ "git", "tag", "v1.0.0" });
    
    // Make some modifications to simulate a typical working state
    // Modify an existing file
    try std.fs.cwd().writeFile(.{ .sub_path = "src/main.ts", .data = "console.log('Modified main file');\n" });
    
    // Create new untracked file
    try std.fs.cwd().writeFile(.{ .sub_path = "temp.log", .data = "temporary log file\n" });
    
    // Add one more commit and tag
    _ = try runCommand(allocator, &[_][]const u8{ "git", "add", "src/main.ts" });
    _ = try runCommand(allocator, &[_][]const u8{ "git", "commit", "-q", "-m", "Update main file" });
    _ = try runCommand(allocator, &[_][]const u8{ "git", "tag", "v1.0.1" });
    
    // Create another modification (not committed)
    try std.fs.cwd().writeFile(.{ .sub_path = "package.json", .data = 
        \\{
        \\  "name": "benchmark-repo",
        \\  "version": "1.0.1",
        \\  "dependencies": {
        \\    "react": "^18.0.0",
        \\    "typescript": "^5.0.0",
        \\    "lodash": "^4.17.21"
        \\  }
        \\}
        \\
    });
    
    std.log.info("Created test repository with realistic project structure", .{});
}

fn runCommand(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    var child = process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    
    try child.spawn();
    
    const stdout = try child.stdout.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(stdout);
    const stderr = try child.stderr.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(stderr);
    
    const result = try child.wait();
    if (result != .Exited or result.Exited != 0) {
        std.log.err("Command failed: {s}", .{std.mem.join(allocator, " ", argv) catch "unknown"});
        if (stderr.len > 0) std.log.err("Stderr: {s}", .{stderr});
        return error.CommandFailed;
    }
    
    return allocator.dupe(u8, stdout);
}

fn benchmarkStatusPorcelain(allocator: std.mem.Allocator, repo_dir: []const u8) !BenchResult {
    const iterations = 200;
    
    // Benchmark git status --porcelain
    var git_total_ns: u64 = 0;
    
    for (0..iterations) |_| {
        const start = time.nanoTimestamp();
        const result = try runCommand(allocator, &[_][]const u8{ "git", "-C", repo_dir, "status", "--porcelain" });
        allocator.free(result);
        const elapsed = @as(u64, @intCast(time.nanoTimestamp() - start));
        git_total_ns += elapsed;
    }
    
    const git_avg_ns = git_total_ns / iterations;
    
    // Benchmark ziggit status_porcelain
    const repo_path_z = try allocator.dupeZ(u8, repo_dir);
    defer allocator.free(repo_path_z);
    
    const repo = ziggit_repo_open(repo_path_z.ptr) orelse return error.RepoOpenFailed;
    defer ziggit_repo_close(repo);
    
    var buffer: [8192]u8 = undefined;
    var ziggit_total_ns: u64 = 0;
    
    for (0..iterations) |_| {
        const start = time.nanoTimestamp();
        _ = ziggit_status_porcelain(repo, &buffer, buffer.len);
        const elapsed = @as(u64, @intCast(time.nanoTimestamp() - start));
        ziggit_total_ns += elapsed;
    }
    
    const ziggit_avg_ns = ziggit_total_ns / iterations;
    const git_avg_ms = @as(f64, @floatFromInt(git_avg_ns)) / 1_000_000.0;
    const ziggit_avg_ms = @as(f64, @floatFromInt(ziggit_avg_ns)) / 1_000_000.0;
    const speedup = git_avg_ms / ziggit_avg_ms;
    
    return BenchResult{
        .name = "status --porcelain",
        .git_avg_ms = git_avg_ms,
        .ziggit_avg_ms = ziggit_avg_ms,
        .speedup = speedup,
        .iterations = iterations,
    };
}

fn benchmarkRevParseHead(allocator: std.mem.Allocator, repo_dir: []const u8) !BenchResult {
    const iterations = 200;
    
    // Benchmark git rev-parse HEAD
    var git_total_ns: u64 = 0;
    
    for (0..iterations) |_| {
        const start = time.nanoTimestamp();
        const result = try runCommand(allocator, &[_][]const u8{ "git", "-C", repo_dir, "rev-parse", "HEAD" });
        allocator.free(result);
        const elapsed = @as(u64, @intCast(time.nanoTimestamp() - start));
        git_total_ns += elapsed;
    }
    
    const git_avg_ns = git_total_ns / iterations;
    
    // Benchmark ziggit rev_parse_head
    const repo_path_z = try allocator.dupeZ(u8, repo_dir);
    defer allocator.free(repo_path_z);
    
    const repo = ziggit_repo_open(repo_path_z.ptr) orelse return error.RepoOpenFailed;
    defer ziggit_repo_close(repo);
    
    var buffer: [64]u8 = undefined;
    var ziggit_total_ns: u64 = 0;
    
    for (0..iterations) |_| {
        const start = time.nanoTimestamp();
        _ = ziggit_rev_parse_head(repo, &buffer, buffer.len);
        const elapsed = @as(u64, @intCast(time.nanoTimestamp() - start));
        ziggit_total_ns += elapsed;
    }
    
    const ziggit_avg_ns = ziggit_total_ns / iterations;
    const git_avg_ms = @as(f64, @floatFromInt(git_avg_ns)) / 1_000_000.0;
    const ziggit_avg_ms = @as(f64, @floatFromInt(ziggit_avg_ns)) / 1_000_000.0;
    const speedup = git_avg_ms / ziggit_avg_ms;
    
    return BenchResult{
        .name = "rev-parse HEAD",
        .git_avg_ms = git_avg_ms,
        .ziggit_avg_ms = ziggit_avg_ms,
        .speedup = speedup,
        .iterations = iterations,
    };
}

fn benchmarkDescribeTags(allocator: std.mem.Allocator, repo_dir: []const u8) !BenchResult {
    const iterations = 200;
    
    // Benchmark git describe --tags --abbrev=0
    var git_total_ns: u64 = 0;
    
    for (0..iterations) |_| {
        const start = time.nanoTimestamp();
        const result = runCommand(allocator, &[_][]const u8{ "git", "-C", repo_dir, "describe", "--tags", "--abbrev=0" }) catch |err| switch (err) {
            error.CommandFailed => {
                // Command failed (maybe no tags), but still measure the time
                const elapsed = @as(u64, @intCast(time.nanoTimestamp() - start));
                git_total_ns += elapsed;
                continue;
            },
            else => return err,
        };
        allocator.free(result);
        const elapsed = @as(u64, @intCast(time.nanoTimestamp() - start));
        git_total_ns += elapsed;
    }
    
    const git_avg_ns = git_total_ns / iterations;
    
    // Benchmark ziggit describe_tags
    const repo_path_z = try allocator.dupeZ(u8, repo_dir);
    defer allocator.free(repo_path_z);
    
    const repo = ziggit_repo_open(repo_path_z.ptr) orelse return error.RepoOpenFailed;
    defer ziggit_repo_close(repo);
    
    var buffer: [256]u8 = undefined;
    var ziggit_total_ns: u64 = 0;
    
    for (0..iterations) |_| {
        const start = time.nanoTimestamp();
        _ = ziggit_describe_tags(repo, &buffer, buffer.len);
        const elapsed = @as(u64, @intCast(time.nanoTimestamp() - start));
        ziggit_total_ns += elapsed;
    }
    
    const ziggit_avg_ns = ziggit_total_ns / iterations;
    const git_avg_ms = @as(f64, @floatFromInt(git_avg_ns)) / 1_000_000.0;
    const ziggit_avg_ms = @as(f64, @floatFromInt(ziggit_avg_ns)) / 1_000_000.0;
    const speedup = git_avg_ms / ziggit_avg_ms;
    
    return BenchResult{
        .name = "describe --tags",
        .git_avg_ms = git_avg_ms,
        .ziggit_avg_ms = ziggit_avg_ms,
        .speedup = speedup,
        .iterations = iterations,
    };
}

fn printResultsTable(results: []const BenchResult) void {
    std.log.info("", .{});
    std.log.info("╭──────────────────────────────────────────────────────────────╮", .{});
    std.log.info("│                     BENCHMARK RESULTS                       │", .{});
    std.log.info("├──────────────────────────────────────────────────────────────┤", .{});
    std.log.info("│ Operation          │ Git (ms) │ Ziggit (ms) │ Speedup │ Iter │", .{});
    std.log.info("├──────────────────────────────────────────────────────────────┤", .{});
    
    for (results) |result| {
        std.log.info("│ {s:<18} │ {d:>8.2} │ {d:>11.2} │ {d:>6.1}x │ {d:>4} │", .{
            result.name, 
            result.git_avg_ms, 
            result.ziggit_avg_ms, 
            result.speedup,
            result.iterations
        });
    }
    
    std.log.info("╰──────────────────────────────────────────────────────────────╯", .{});
    std.log.info("", .{});
    
    // Calculate total time savings for bun scenario
    var total_git_time: f64 = 0;
    var total_ziggit_time: f64 = 0;
    
    for (results) |result| {
        total_git_time += result.git_avg_ms;
        total_ziggit_time += result.ziggit_avg_ms;
    }
    
    const overall_speedup = total_git_time / total_ziggit_time;
    const time_saved_per_operation = total_git_time - total_ziggit_time;
    
    std.log.info("Summary:", .{});
    std.log.info("  • Overall speedup: {d:.1}x faster than git CLI", .{overall_speedup});
    std.log.info("  • Time saved per operation set: {d:.2}ms", .{time_saved_per_operation});
    std.log.info("", .{});
    std.log.info("For bun's typical workflow (100+ operations per install):", .{});
    std.log.info("  • Git CLI total: ~{d:.0}ms", .{total_git_time * 100});
    std.log.info("  • Ziggit total: ~{d:.0}ms", .{total_ziggit_time * 100});
    std.log.info("  • Time saved: ~{d:.0}ms ({d:.1}s)", .{time_saved_per_operation * 100, time_saved_per_operation * 100 / 1000});
}