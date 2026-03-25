const std = @import("std");
const time = std.time;
const ziggit = @import("ziggit");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("=== Ziggit vs Git CLI Benchmark ===\n", .{});
    
    // Create a test repository with real git
    const test_repo_dir = "ziggit_bench_repo";
    try createTestRepo(allocator, test_repo_dir);
    defer std.fs.cwd().deleteTree(test_repo_dir) catch {};
    
    // Benchmark both git and ziggit
    try runBenchmarks(allocator, test_repo_dir);
}

fn createTestRepo(allocator: std.mem.Allocator, repo_dir: []const u8) !void {
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
    _ = try runCommand(allocator, &[_][]const u8{ "git", "init" });
    _ = try runCommand(allocator, &[_][]const u8{ "git", "config", "user.name", "Test User" });
    _ = try runCommand(allocator, &[_][]const u8{ "git", "config", "user.email", "test@example.com" });
    
    // Create multiple files for a more realistic test
    const files = [_][]const u8{
        "README.md", "src/main.zig", "src/lib.zig", "build.zig", 
        "test/test1.zig", "test/test2.zig", "docs/api.md", "examples/hello.zig",
        "package.json", "tsconfig.json", "src/index.ts", "src/utils.ts"
    };
    
    for (files) |file_path| {
        // Create directory if needed
        if (std.fs.path.dirname(file_path)) |dir| {
            std.fs.cwd().makePath(dir) catch {};
        }
        
        // Write some content to the file
        const content = try std.fmt.allocPrint(allocator, "// File: {s}\nconst std = @import(\"std\");\n\npub fn main() void {{\n    // Test content for benchmarking\n    // Line count: 10 lines\n}}\n", .{file_path});
        defer allocator.free(content);
        
        try std.fs.cwd().writeFile(.{ .sub_path = file_path, .data = content });
    }
    
    // Add and commit files
    _ = try runCommand(allocator, &[_][]const u8{ "git", "add", "." });
    _ = try runCommand(allocator, &[_][]const u8{ "git", "commit", "-m", "Initial commit" });
    
    // Create some modifications for status testing
    try std.fs.cwd().writeFile(.{ .sub_path = "README.md", .data = "# Modified README\nThis file has been modified for testing.\n" });
    try std.fs.cwd().writeFile(.{ .sub_path = "untracked.txt", .data = "This is an untracked file.\n" });
    
    // Add a tag
    _ = try runCommand(allocator, &[_][]const u8{ "git", "tag", "v1.0.0" });
    
    // Make another commit
    _ = try runCommand(allocator, &[_][]const u8{ "git", "add", "README.md" });
    _ = try runCommand(allocator, &[_][]const u8{ "git", "commit", "-m", "Update README" });
    _ = try runCommand(allocator, &[_][]const u8{ "git", "tag", "v1.0.1" });
}

fn runCommand(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    
    try child.spawn();
    
    const stdout = try child.stdout.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(stdout);
    const stderr = try child.stderr.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(stderr);
    
    const result = try child.wait();
    if (result != .Exited or result.Exited != 0) {
        std.log.err("Command failed: {s}", .{argv[0]});
        std.log.err("Stderr: {s}", .{stderr});
        return error.CommandFailed;
    }
    
    return allocator.dupe(u8, stdout);
}

const BenchResult = struct {
    operation: []const u8,
    git_avg_ms: f64,
    ziggit_avg_ms: f64,
    speedup: f64,
};

fn runBenchmarks(allocator: std.mem.Allocator, repo_dir: []const u8) !void {
    const iterations = 50;
    
    std.log.info("Running benchmarks with {} iterations each:\n", .{iterations});
    
    var results = std.ArrayList(BenchResult).init(allocator);
    defer results.deinit();
    
    // Test status --porcelain
    std.log.info("Benchmarking status --porcelain...", .{});
    const status_result = try benchmarkStatus(allocator, repo_dir, iterations);
    try results.append(status_result);
    
    // Test rev-parse HEAD
    std.log.info("Benchmarking rev-parse HEAD...", .{});
    const rev_parse_result = try benchmarkRevParse(allocator, repo_dir, iterations);
    try results.append(rev_parse_result);
    
    // Test describe --tags
    std.log.info("Benchmarking describe --tags...", .{});
    const describe_result = try benchmarkDescribe(allocator, repo_dir, iterations);
    try results.append(describe_result);
    
    // Print results
    std.log.info("\n╭─────────────────────────────────────────────────────────────╮", .{});
    std.log.info("│                   BENCHMARK RESULTS                         │", .{});
    std.log.info("├─────────────────────────────────────────────────────────────┤", .{});
    std.log.info("│ Operation           │ Git (ms) │ Ziggit (ms) │ Speedup     │", .{});
    std.log.info("├─────────────────────────────────────────────────────────────┤", .{});
    
    for (results.items) |result| {
        std.log.info("│ {s:<19} │ {d:>8.3} │ {d:>11.3} │ {d:>8.2}x   │", .{
            result.operation, result.git_avg_ms, result.ziggit_avg_ms, result.speedup
        });
    }
    
    std.log.info("╰─────────────────────────────────────────────────────────────╯", .{});
    
    // Calculate overall improvement
    var total_git_time: f64 = 0;
    var total_ziggit_time: f64 = 0;
    for (results.items) |result| {
        total_git_time += result.git_avg_ms;
        total_ziggit_time += result.ziggit_avg_ms;
    }
    
    const overall_speedup = total_git_time / total_ziggit_time;
    std.log.info("\nOverall speedup: {d:.2}x faster than git CLI", .{overall_speedup});
    std.log.info("Time saved per bun operation cycle: {d:.3}ms", .{total_git_time - total_ziggit_time});
}

fn benchmarkStatus(allocator: std.mem.Allocator, repo_dir: []const u8, iterations: usize) !BenchResult {
    // Benchmark git status --porcelain
    var git_total_ns: u64 = 0;
    
    for (0..iterations) |_| {
        const start = time.nanoTimestamp();
        const result = runCommand(allocator, &[_][]const u8{ "git", "-C", repo_dir, "status", "--porcelain" }) catch |err| switch (err) {
            error.CommandFailed => {
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
    
    const git_avg_ms = @as(f64, @floatFromInt(git_total_ns / iterations)) / 1_000_000.0;
    
    // Benchmark ziggit status
    var cwd_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const cwd = try std.process.getCwd(&cwd_buf);
    const abs_repo_path = try std.fs.path.resolve(allocator, &[_][]const u8{ cwd, repo_dir });
    defer allocator.free(abs_repo_path);
    
    const repo = try ziggit.repo_open(allocator, abs_repo_path);
    
    var ziggit_total_ns: u64 = 0;
    
    for (0..iterations) |_| {
        const start = time.nanoTimestamp();
        const result = try ziggit.repo_status(@constCast(&repo), allocator);
        allocator.free(result);
        const elapsed = @as(u64, @intCast(time.nanoTimestamp() - start));
        ziggit_total_ns += elapsed;
    }
    
    const ziggit_avg_ms = @as(f64, @floatFromInt(ziggit_total_ns / iterations)) / 1_000_000.0;
    const speedup = git_avg_ms / ziggit_avg_ms;
    
    return BenchResult{
        .operation = "status --porcelain",
        .git_avg_ms = git_avg_ms,
        .ziggit_avg_ms = ziggit_avg_ms,
        .speedup = speedup,
    };
}

fn benchmarkRevParse(allocator: std.mem.Allocator, repo_dir: []const u8, iterations: usize) !BenchResult {
    // Benchmark git rev-parse HEAD
    var git_total_ns: u64 = 0;
    
    for (0..iterations) |_| {
        const start = time.nanoTimestamp();
        const result = runCommand(allocator, &[_][]const u8{ "git", "-C", repo_dir, "rev-parse", "HEAD" }) catch |err| switch (err) {
            error.CommandFailed => {
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
    
    const git_avg_ms = @as(f64, @floatFromInt(git_total_ns / iterations)) / 1_000_000.0;
    
    // Benchmark ziggit rev-parse HEAD
    var cwd_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const cwd = try std.process.getCwd(&cwd_buf);
    const abs_repo_path = try std.fs.path.resolve(allocator, &[_][]const u8{ cwd, repo_dir });
    defer allocator.free(abs_repo_path);
    
    const repo = try ziggit.repo_open(allocator, abs_repo_path);
    
    var ziggit_total_ns: u64 = 0;
    
    for (0..iterations) |_| {
        const start = time.nanoTimestamp();
        const result = try ziggit.repo_rev_parse_head(@constCast(&repo), allocator);
        allocator.free(result);
        const elapsed = @as(u64, @intCast(time.nanoTimestamp() - start));
        ziggit_total_ns += elapsed;
    }
    
    const ziggit_avg_ms = @as(f64, @floatFromInt(ziggit_total_ns / iterations)) / 1_000_000.0;
    const speedup = git_avg_ms / ziggit_avg_ms;
    
    return BenchResult{
        .operation = "rev-parse HEAD",
        .git_avg_ms = git_avg_ms,
        .ziggit_avg_ms = ziggit_avg_ms,
        .speedup = speedup,
    };
}

fn benchmarkDescribe(allocator: std.mem.Allocator, repo_dir: []const u8, iterations: usize) !BenchResult {
    // Benchmark git describe --tags --abbrev=0
    var git_total_ns: u64 = 0;
    
    for (0..iterations) |_| {
        const start = time.nanoTimestamp();
        const result = runCommand(allocator, &[_][]const u8{ "git", "-C", repo_dir, "describe", "--tags", "--abbrev=0" }) catch |err| switch (err) {
            error.CommandFailed => {
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
    
    const git_avg_ms = @as(f64, @floatFromInt(git_total_ns / iterations)) / 1_000_000.0;
    
    // Benchmark ziggit describe --tags
    var cwd_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const cwd = try std.process.getCwd(&cwd_buf);
    const abs_repo_path = try std.fs.path.resolve(allocator, &[_][]const u8{ cwd, repo_dir });
    defer allocator.free(abs_repo_path);
    
    const repo = try ziggit.repo_open(allocator, abs_repo_path);
    
    var ziggit_total_ns: u64 = 0;
    
    for (0..iterations) |_| {
        const start = time.nanoTimestamp();
        const result = try ziggit.repo_describe_tags(@constCast(&repo), allocator);
        allocator.free(result);
        const elapsed = @as(u64, @intCast(time.nanoTimestamp() - start));
        ziggit_total_ns += elapsed;
    }
    
    const ziggit_avg_ms = @as(f64, @floatFromInt(ziggit_total_ns / iterations)) / 1_000_000.0;
    const speedup = git_avg_ms / ziggit_avg_ms;
    
    return BenchResult{
        .operation = "describe --tags",
        .git_avg_ms = git_avg_ms,
        .ziggit_avg_ms = ziggit_avg_ms,
        .speedup = speedup,
    };
}