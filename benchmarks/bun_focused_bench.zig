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
    operation: []const u8,
    git_avg_ms: f64,
    ziggit_avg_ms: f64,
    speedup: f64,
    iterations: usize,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("=== Bun-focused Ziggit vs Git CLI Benchmark ===", .{});
    std.log.info("Testing the critical operations bun uses:", .{});
    std.log.info("- git status --porcelain (checking repo cleanliness)", .{});
    std.log.info("- git rev-parse HEAD (getting current commit)", .{});
    std.log.info("- git describe --tags --abbrev=0 (version resolution)", .{});
    std.log.info("", .{});
    
    // Create a test repository with real git
    const test_repo = "bun_bench_repo";
    const repo_path = try setupTestRepo(allocator, test_repo);
    defer allocator.free(repo_path);
    defer std.fs.cwd().deleteTree(test_repo) catch {};
    
    std.log.info("Test repository created with {} files", .{try countFiles(test_repo)});
    std.log.info("", .{});
    
    var results = std.ArrayList(BenchResult).init(allocator);
    defer results.deinit();
    
    const iterations: usize = 100;
    
    // Benchmark critical operations
    try results.append(try benchmarkStatusPorcelain(allocator, repo_path, iterations));
    try results.append(try benchmarkRevParseHead(allocator, repo_path, iterations));
    try results.append(try benchmarkDescribeTags(allocator, repo_path, iterations));
    
    // Print results
    printResults(results.items);
}

fn setupTestRepo(allocator: std.mem.Allocator, repo_dir: []const u8) ![]const u8 {
    // Clean up existing repo
    std.fs.cwd().deleteTree(repo_dir) catch {};
    
    // Get absolute path
    var cwd_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const cwd = try std.process.getCwd(&cwd_buf);
    const repo_path = try std.fs.path.resolve(allocator, &[_][]const u8{ cwd, repo_dir });
    
    // Create directory and initialize git repo
    try std.fs.cwd().makeDir(repo_dir);
    
    const original_cwd = try allocator.dupe(u8, cwd);
    defer allocator.free(original_cwd);
    
    try std.posix.chdir(repo_path);
    defer std.posix.chdir(original_cwd) catch {};
    
    // Initialize git repository
    _ = try runCommand(allocator, &[_][]const u8{ "git", "init", "-q" });
    _ = try runCommand(allocator, &[_][]const u8{ "git", "config", "user.name", "Benchmark" });
    _ = try runCommand(allocator, &[_][]const u8{ "git", "config", "user.email", "bench@test.com" });
    
    // Create files that bun commonly works with
    const files = [_]struct { path: []const u8, content: []const u8 }{
        .{ .path = "package.json", .content = 
            \\{
            \\  "name": "bench-project",
            \\  "version": "1.2.3",
            \\  "dependencies": {
            \\    "react": "^18.0.0",
            \\    "typescript": "^5.0.0",
            \\    "@types/node": "^20.0.0"
            \\  }
            \\}
            \\
        },
        .{ .path = "bun.lockb", .content = "mock lockfile content\n" },
        .{ .path = "tsconfig.json", .content = "{\"compilerOptions\": {\"target\": \"ES2022\", \"moduleResolution\": \"node\"}}\n" },
        .{ .path = "src/index.ts", .content = "export { main } from './main';\n" },
        .{ .path = "src/main.ts", .content = "console.log('Hello from bun bench');\n" },
        .{ .path = "src/utils.ts", .content = "export const VERSION = '1.2.3';\n" },
        .{ .path = "tests/basic.test.ts", .content = "import { expect, test } from 'bun:test';\ntest('works', () => expect(1).toBe(1));\n" },
    };
    
    // Create directories and files
    try std.fs.cwd().makeDir("src");
    try std.fs.cwd().makeDir("tests");
    
    for (files) |file| {
        try std.fs.cwd().writeFile(.{ .sub_path = file.path, .data = file.content });
    }
    
    // Add and commit files
    _ = try runCommand(allocator, &[_][]const u8{ "git", "add", "." });
    _ = try runCommand(allocator, &[_][]const u8{ "git", "commit", "-m", "Initial commit", "-q" });
    
    // Create a tag (important for git describe)
    _ = try runCommand(allocator, &[_][]const u8{ "git", "tag", "v1.2.3" });
    
    // Create another commit
    try std.fs.cwd().writeFile(.{ .sub_path = "README.md", .data = "# Benchmark Project\n" });
    _ = try runCommand(allocator, &[_][]const u8{ "git", "add", "README.md" });
    _ = try runCommand(allocator, &[_][]const u8{ "git", "commit", "-m", "Add README", "-q" });
    
    return repo_path;
}

fn countFiles(repo_dir: []const u8) !usize {
    var count: usize = 0;
    var dir = try std.fs.cwd().openDir(repo_dir, .{ .iterate = true });
    defer dir.close();
    
    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind == .file and !std.mem.startsWith(u8, entry.name, ".git")) {
            count += 1;
        }
    }
    return count;
}

fn benchmarkStatusPorcelain(allocator: std.mem.Allocator, repo_path: []const u8, iterations: usize) !BenchResult {
    std.log.info("Benchmarking git status --porcelain...", .{});
    
    // Benchmark git CLI
    const git_start = time.nanoTimestamp();
    for (0..iterations) |_| {
        _ = try runGitCommand(allocator, repo_path, &[_][]const u8{ "git", "status", "--porcelain" });
    }
    const git_end = time.nanoTimestamp();
    const git_total_ns = @as(f64, @floatFromInt(git_end - git_start));
    const git_avg_ms = git_total_ns / @as(f64, @floatFromInt(iterations)) / 1_000_000.0;
    
    // Benchmark ziggit
    const repo_path_z = try allocator.dupeZ(u8, repo_path);
    defer allocator.free(repo_path_z);
    
    var buffer: [4096]u8 = undefined;
    
    const ziggit_start = time.nanoTimestamp();
    for (0..iterations) |_| {
        if (ziggit_repo_open(repo_path_z.ptr)) |repo| {
            defer ziggit_repo_close(repo);
            _ = ziggit_status_porcelain(repo, &buffer, buffer.len);
        }
    }
    const ziggit_end = time.nanoTimestamp();
    const ziggit_total_ns = @as(f64, @floatFromInt(ziggit_end - ziggit_start));
    const ziggit_avg_ms = ziggit_total_ns / @as(f64, @floatFromInt(iterations)) / 1_000_000.0;
    
    const speedup = git_avg_ms / ziggit_avg_ms;
    
    return BenchResult{
        .operation = "status --porcelain",
        .git_avg_ms = git_avg_ms,
        .ziggit_avg_ms = ziggit_avg_ms,
        .speedup = speedup,
        .iterations = iterations,
    };
}

fn benchmarkRevParseHead(allocator: std.mem.Allocator, repo_path: []const u8, iterations: usize) !BenchResult {
    std.log.info("Benchmarking git rev-parse HEAD...", .{});
    
    // Benchmark git CLI
    const git_start = time.nanoTimestamp();
    for (0..iterations) |_| {
        _ = try runGitCommand(allocator, repo_path, &[_][]const u8{ "git", "rev-parse", "HEAD" });
    }
    const git_end = time.nanoTimestamp();
    const git_total_ns = @as(f64, @floatFromInt(git_end - git_start));
    const git_avg_ms = git_total_ns / @as(f64, @floatFromInt(iterations)) / 1_000_000.0;
    
    // Benchmark ziggit
    const repo_path_z = try allocator.dupeZ(u8, repo_path);
    defer allocator.free(repo_path_z);
    
    var buffer: [64]u8 = undefined;
    
    const ziggit_start = time.nanoTimestamp();
    for (0..iterations) |_| {
        if (ziggit_repo_open(repo_path_z.ptr)) |repo| {
            defer ziggit_repo_close(repo);
            _ = ziggit_rev_parse_head(repo, &buffer, buffer.len);
        }
    }
    const ziggit_end = time.nanoTimestamp();
    const ziggit_total_ns = @as(f64, @floatFromInt(ziggit_end - ziggit_start));
    const ziggit_avg_ms = ziggit_total_ns / @as(f64, @floatFromInt(iterations)) / 1_000_000.0;
    
    const speedup = git_avg_ms / ziggit_avg_ms;
    
    return BenchResult{
        .operation = "rev-parse HEAD",
        .git_avg_ms = git_avg_ms,
        .ziggit_avg_ms = ziggit_avg_ms,
        .speedup = speedup,
        .iterations = iterations,
    };
}

fn benchmarkDescribeTags(allocator: std.mem.Allocator, repo_path: []const u8, iterations: usize) !BenchResult {
    std.log.info("Benchmarking git describe --tags --abbrev=0...", .{});
    
    // Benchmark git CLI
    const git_start = time.nanoTimestamp();
    for (0..iterations) |_| {
        _ = runGitCommand(allocator, repo_path, &[_][]const u8{ "git", "describe", "--tags", "--abbrev=0" }) catch {
            // Ignore errors for repos without tags
        };
    }
    const git_end = time.nanoTimestamp();
    const git_total_ns = @as(f64, @floatFromInt(git_end - git_start));
    const git_avg_ms = git_total_ns / @as(f64, @floatFromInt(iterations)) / 1_000_000.0;
    
    // Benchmark ziggit
    const repo_path_z = try allocator.dupeZ(u8, repo_path);
    defer allocator.free(repo_path_z);
    
    var buffer: [256]u8 = undefined;
    
    const ziggit_start = time.nanoTimestamp();
    for (0..iterations) |_| {
        if (ziggit_repo_open(repo_path_z.ptr)) |repo| {
            defer ziggit_repo_close(repo);
            _ = ziggit_describe_tags(repo, &buffer, buffer.len);
        }
    }
    const ziggit_end = time.nanoTimestamp();
    const ziggit_total_ns = @as(f64, @floatFromInt(ziggit_end - ziggit_start));
    const ziggit_avg_ms = ziggit_total_ns / @as(f64, @floatFromInt(iterations)) / 1_000_000.0;
    
    const speedup = git_avg_ms / ziggit_avg_ms;
    
    return BenchResult{
        .operation = "describe --tags --abbrev=0",
        .git_avg_ms = git_avg_ms,
        .ziggit_avg_ms = ziggit_avg_ms,
        .speedup = speedup,
        .iterations = iterations,
    };
}

fn printResults(results: []BenchResult) void {
    std.log.info("=== BENCHMARK RESULTS ===", .{});
    std.log.info("", .{});
    std.log.info("Operation                    | Git CLI  | Ziggit   | Speedup  | Iterations", .{});
    std.log.info("----------------------------|----------|----------|----------|----------", .{});
    
    for (results) |result| {
        std.log.info("{s: <27} | {d: >6.2}ms | {d: >6.2}ms | {d: >6.1}x  | {d}", .{
            result.operation,
            result.git_avg_ms,
            result.ziggit_avg_ms,
            result.speedup,
            result.iterations,
        });
    }
    
    std.log.info("", .{});
    
    // Calculate overall speedup
    var total_git_ms: f64 = 0;
    var total_ziggit_ms: f64 = 0;
    
    for (results) |result| {
        total_git_ms += result.git_avg_ms;
        total_ziggit_ms += result.ziggit_avg_ms;
    }
    
    const overall_speedup = total_git_ms / total_ziggit_ms;
    std.log.info("Overall speedup: {d:.1}x faster than git CLI", .{overall_speedup});
    std.log.info("Time saved per operation: {d:.2}ms average", .{(total_git_ms - total_ziggit_ms) / @as(f64, @floatFromInt(results.len))});
}

fn runCommand(allocator: std.mem.Allocator, args: []const []const u8) ![]u8 {
    var child = process.Child.init(args, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    
    try child.spawn();
    
    const stdout = try child.stdout.?.reader().readAllAlloc(allocator, 8192);
    const stderr = try child.stderr.?.reader().readAllAlloc(allocator, 8192);
    defer allocator.free(stderr);
    
    const term = try child.wait();
    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                allocator.free(stdout);
                return error.CommandFailed;
            }
        },
        else => {
            allocator.free(stdout);
            return error.CommandFailed;
        },
    }
    
    return stdout;
}

fn runGitCommand(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) ![]u8 {
    var child = process.Child.init(args, allocator);
    child.cwd = cwd;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    
    try child.spawn();
    
    const stdout = try child.stdout.?.reader().readAllAlloc(allocator, 8192);
    const stderr = try child.stderr.?.reader().readAllAlloc(allocator, 8192);
    defer allocator.free(stderr);
    
    const term = try child.wait();
    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                allocator.free(stdout);
                return error.CommandFailed;
            }
        },
        else => {
            allocator.free(stdout);
            return error.CommandFailed;
        },
    }
    
    return stdout;
}