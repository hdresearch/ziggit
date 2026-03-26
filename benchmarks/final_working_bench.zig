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
    success: bool,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("=== Final Working Ziggit vs Git CLI Benchmark ===", .{});
    std.log.info("Real performance comparison for bun's critical operations", .{});
    std.log.info("", .{});
    
    // Create a test repository with real git
    const test_repo_dir = "final_bench_repo";
    const repo_path = try createTestRepo(allocator, test_repo_dir);
    defer allocator.free(repo_path);
    defer std.fs.cwd().deleteTree(test_repo_dir) catch {};
    
    std.log.info("Test repo created at: {s}", .{repo_path});
    std.log.info("", .{});
    
    const iterations: usize = 100;
    
    // Test each critical operation
    var results = std.ArrayList(BenchResult).init(allocator);
    defer results.deinit();
    
    try results.append(try benchmarkStatusPorcelain(allocator, repo_path, iterations));
    try results.append(try benchmarkRevParseHead(allocator, repo_path, iterations));
    try results.append(try benchmarkDescribeTags(allocator, repo_path, iterations));
    
    // Print detailed results
    printResults(results.items);
}

fn createTestRepo(allocator: std.mem.Allocator, repo_dir: []const u8) ![]const u8 {
    // Clean up any existing test repo
    std.fs.cwd().deleteTree(repo_dir) catch {};
    
    // Create directory
    try std.fs.cwd().makeDir(repo_dir);
    
    var cwd_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const original_cwd = try std.process.getCwd(&cwd_buf);
    
    const repo_path = try std.fs.path.resolve(allocator, &[_][]const u8{ original_cwd, repo_dir });
    
    try std.posix.chdir(repo_path);
    defer std.posix.chdir(original_cwd) catch {};
    
    // Initialize git repository
    _ = try runCommand(allocator, &[_][]const u8{ "git", "init", "-q" });
    _ = try runCommand(allocator, &[_][]const u8{ "git", "config", "user.name", "Benchmark" });
    _ = try runCommand(allocator, &[_][]const u8{ "git", "config", "user.email", "bench@test.com" });
    
    // Create typical bun project files
    try std.fs.cwd().writeFile(.{ .sub_path = "package.json", .data = 
        \\{
        \\  "name": "benchmark-project", 
        \\  "version": "1.2.0",
        \\  "dependencies": {
        \\    "react": "^18.2.0",
        \\    "typescript": "^5.0.0"
        \\  }
        \\}
        \\
    });
    
    try std.fs.cwd().writeFile(.{ .sub_path = "bun.lockb", .data = "mock binary lockfile\n" });
    
    try std.fs.cwd().makeDir("src");
    try std.fs.cwd().writeFile(.{ .sub_path = "src/index.ts", .data = "export * from './main';\n" });
    try std.fs.cwd().writeFile(.{ .sub_path = "src/main.ts", .data = "console.log('Hello from bun');\n" });
    
    try std.fs.cwd().makeDir("tests");
    try std.fs.cwd().writeFile(.{ .sub_path = "tests/main.test.ts", .data = "test('basic', () => {});\n" });
    
    // Add and commit
    _ = try runCommand(allocator, &[_][]const u8{ "git", "add", "." });
    _ = try runCommand(allocator, &[_][]const u8{ "git", "commit", "-q", "-m", "Initial commit" });
    
    // Create a tag for describe testing
    _ = try runCommand(allocator, &[_][]const u8{ "git", "tag", "v1.2.0" });
    
    return repo_path;
}

fn benchmarkStatusPorcelain(allocator: std.mem.Allocator, repo_path: []const u8, iterations: usize) !BenchResult {
    std.log.info("Benchmarking status --porcelain ({} iterations)...", .{iterations});
    
    // Benchmark git CLI
    const git_start = time.nanoTimestamp();
    for (0..iterations) |_| {
        _ = runGitCommand(allocator, repo_path, &[_][]const u8{ "git", "status", "--porcelain" }) catch |err| {
            std.log.warn("Git command failed: {}", .{err});
            continue;
        };
    }
    const git_end = time.nanoTimestamp();
    const git_total_ns = @as(f64, @floatFromInt(git_end - git_start));
    const git_avg_ms = git_total_ns / @as(f64, @floatFromInt(iterations)) / 1_000_000.0;
    
    // Benchmark ziggit library
    const repo_path_z = try allocator.dupeZ(u8, repo_path);
    defer allocator.free(repo_path_z);
    
    var buffer: [8192]u8 = undefined;
    var ziggit_success = false;
    var ziggit_total_ns: f64 = 0;
    
    // Test if ziggit works at all first
    if (ziggit_repo_open(repo_path_z.ptr)) |repo| {
        defer ziggit_repo_close(repo);
        const result = ziggit_status_porcelain(repo, &buffer, buffer.len);
        if (result == 0) {
            ziggit_success = true;
            
            // If it works, benchmark it
            const ziggit_start = time.nanoTimestamp();
            for (0..iterations) |_| {
                if (ziggit_repo_open(repo_path_z.ptr)) |r| {
                    defer ziggit_repo_close(r);
                    _ = ziggit_status_porcelain(r, &buffer, buffer.len);
                }
            }
            const ziggit_end = time.nanoTimestamp();
            ziggit_total_ns = @as(f64, @floatFromInt(ziggit_end - ziggit_start));
        }
    }
    
    const ziggit_avg_ms = if (ziggit_success) 
        ziggit_total_ns / @as(f64, @floatFromInt(iterations)) / 1_000_000.0 
    else 
        std.math.inf(f64);
    
    const speedup = if (ziggit_success) git_avg_ms / ziggit_avg_ms else 0.0;
    
    return BenchResult{
        .operation = "status --porcelain",
        .git_avg_ms = git_avg_ms,
        .ziggit_avg_ms = ziggit_avg_ms,
        .speedup = speedup,
        .success = ziggit_success,
    };
}

fn benchmarkRevParseHead(allocator: std.mem.Allocator, repo_path: []const u8, iterations: usize) !BenchResult {
    std.log.info("Benchmarking rev-parse HEAD ({} iterations)...", .{iterations});
    
    // Benchmark git CLI
    const git_start = time.nanoTimestamp();
    for (0..iterations) |_| {
        _ = runGitCommand(allocator, repo_path, &[_][]const u8{ "git", "rev-parse", "HEAD" }) catch continue;
    }
    const git_end = time.nanoTimestamp();
    const git_total_ns = @as(f64, @floatFromInt(git_end - git_start));
    const git_avg_ms = git_total_ns / @as(f64, @floatFromInt(iterations)) / 1_000_000.0;
    
    // Benchmark ziggit library
    const repo_path_z = try allocator.dupeZ(u8, repo_path);
    defer allocator.free(repo_path_z);
    
    var buffer: [64]u8 = undefined;
    var ziggit_success = false;
    var ziggit_total_ns: f64 = 0;
    
    // Test if ziggit works first
    if (ziggit_repo_open(repo_path_z.ptr)) |repo| {
        defer ziggit_repo_close(repo);
        const result = ziggit_rev_parse_head(repo, &buffer, buffer.len);
        if (result == 0) {
            ziggit_success = true;
            
            // If it works, benchmark it
            const ziggit_start = time.nanoTimestamp();
            for (0..iterations) |_| {
                if (ziggit_repo_open(repo_path_z.ptr)) |r| {
                    defer ziggit_repo_close(r);
                    _ = ziggit_rev_parse_head(r, &buffer, buffer.len);
                }
            }
            const ziggit_end = time.nanoTimestamp();
            ziggit_total_ns = @as(f64, @floatFromInt(ziggit_end - ziggit_start));
        }
    }
    
    const ziggit_avg_ms = if (ziggit_success) 
        ziggit_total_ns / @as(f64, @floatFromInt(iterations)) / 1_000_000.0 
    else 
        std.math.inf(f64);
    
    const speedup = if (ziggit_success) git_avg_ms / ziggit_avg_ms else 0.0;
    
    return BenchResult{
        .operation = "rev-parse HEAD",
        .git_avg_ms = git_avg_ms,
        .ziggit_avg_ms = ziggit_avg_ms,
        .speedup = speedup,
        .success = ziggit_success,
    };
}

fn benchmarkDescribeTags(allocator: std.mem.Allocator, repo_path: []const u8, iterations: usize) !BenchResult {
    std.log.info("Benchmarking describe --tags ({} iterations)...", .{iterations});
    
    // Benchmark git CLI
    const git_start = time.nanoTimestamp();
    for (0..iterations) |_| {
        _ = runGitCommand(allocator, repo_path, &[_][]const u8{ "git", "describe", "--tags", "--abbrev=0" }) catch continue;
    }
    const git_end = time.nanoTimestamp();
    const git_total_ns = @as(f64, @floatFromInt(git_end - git_start));
    const git_avg_ms = git_total_ns / @as(f64, @floatFromInt(iterations)) / 1_000_000.0;
    
    // Benchmark ziggit library
    const repo_path_z = try allocator.dupeZ(u8, repo_path);
    defer allocator.free(repo_path_z);
    
    var buffer: [256]u8 = undefined;
    var ziggit_success = false;
    var ziggit_total_ns: f64 = 0;
    
    // Test if ziggit works first
    if (ziggit_repo_open(repo_path_z.ptr)) |repo| {
        defer ziggit_repo_close(repo);
        const result = ziggit_describe_tags(repo, &buffer, buffer.len);
        if (result == 0) {
            ziggit_success = true;
            
            // If it works, benchmark it
            const ziggit_start = time.nanoTimestamp();
            for (0..iterations) |_| {
                if (ziggit_repo_open(repo_path_z.ptr)) |r| {
                    defer ziggit_repo_close(r);
                    _ = ziggit_describe_tags(r, &buffer, buffer.len);
                }
            }
            const ziggit_end = time.nanoTimestamp();
            ziggit_total_ns = @as(f64, @floatFromInt(ziggit_end - ziggit_start));
        }
    }
    
    const ziggit_avg_ms = if (ziggit_success) 
        ziggit_total_ns / @as(f64, @floatFromInt(iterations)) / 1_000_000.0 
    else 
        std.math.inf(f64);
    
    const speedup = if (ziggit_success) git_avg_ms / ziggit_avg_ms else 0.0;
    
    return BenchResult{
        .operation = "describe --tags",
        .git_avg_ms = git_avg_ms,
        .ziggit_avg_ms = ziggit_avg_ms,
        .speedup = speedup,
        .success = ziggit_success,
    };
}

fn printResults(results: []BenchResult) void {
    std.log.info("=== BENCHMARK RESULTS ===", .{});
    std.log.info("", .{});
    std.log.info("╭─────────────────────────────────────────────────────────────────╮", .{});
    std.log.info("│                  Ziggit vs Git CLI Performance                 │", .{});
    std.log.info("├─────────────────────────────────────────────────────────────────┤", .{});
    std.log.info("│ Operation           │ Git CLI  │ Ziggit   │ Speedup │ Status  │", .{});
    std.log.info("├─────────────────────────────────────────────────────────────────┤", .{});
    
    for (results) |result| {
        const ziggit_time = if (result.success) result.ziggit_avg_ms else std.math.inf(f64);
        const speedup_text = if (result.success) 
            if (result.speedup > 999.9) "999.9x+" else std.fmt.allocPrint(std.heap.page_allocator, "{d:.1}x", .{result.speedup}) catch "N/A"
        else 
            "N/A";
        defer if (result.success and result.speedup <= 999.9) std.heap.page_allocator.free(speedup_text);
        
        const status_text = if (result.success) "✓ OK" else "✗ FAIL";
        const ziggit_display = if (result.success) 
            if (ziggit_time > 999.9) "999.9ms+" else std.fmt.allocPrint(std.heap.page_allocator, "{d:.2}ms", .{ziggit_time}) catch "N/A"
        else 
            "N/A";
        defer if (result.success and ziggit_time <= 999.9) std.heap.page_allocator.free(ziggit_display);
        
        std.log.info("│ {s: <19} │ {d: >6.2}ms │ {s: >8} │ {s: >7} │ {s: <6} │", .{
            result.operation,
            result.git_avg_ms,
            ziggit_display,
            speedup_text,
            status_text,
        });
    }
    
    std.log.info("╰─────────────────────────────────────────────────────────────────╯", .{});
    std.log.info("", .{});
    
    // Calculate overall performance
    var total_git_ms: f64 = 0;
    var total_ziggit_ms: f64 = 0;
    var success_count: usize = 0;
    
    for (results) |result| {
        total_git_ms += result.git_avg_ms;
        if (result.success) {
            total_ziggit_ms += result.ziggit_avg_ms;
            success_count += 1;
        }
    }
    
    if (success_count > 0) {
        const overall_speedup = total_git_ms / total_ziggit_ms;
        std.log.info("Overall Performance:", .{});
        std.log.info("• {}/{} operations implemented successfully", .{success_count, results.len});
        std.log.info("• Average speedup: {d:.1}x faster than git CLI", .{overall_speedup});
        std.log.info("• Time saved per bun operation: {d:.2}ms", .{(total_git_ms - total_ziggit_ms) / @as(f64, @floatFromInt(results.len))});
        
        const typical_bun_ops = 50; // Typical package resolution operations
        const git_total = total_git_ms * typical_bun_ops;
        const ziggit_total = total_ziggit_ms * typical_bun_ops;
        std.log.info("• Time savings in typical bun install: {d:.0}ms ({d:.1}s saved)", .{git_total - ziggit_total, (git_total - ziggit_total) / 1000});
    } else {
        std.log.info("No ziggit operations successful - implementation needs work", .{});
    }
}

fn runCommand(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    var child = process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    
    try child.spawn();
    
    const stdout = child.stdout.?.reader().readAllAlloc(allocator, 8192) catch |err| {
        _ = try child.wait();
        return err;
    };
    const stderr = child.stderr.?.reader().readAllAlloc(allocator, 8192) catch |err| {
        allocator.free(stdout);
        _ = try child.wait();
        return err;
    };
    defer allocator.free(stderr);
    
    const result = try child.wait();
    if (result != .Exited or result.Exited != 0) {
        allocator.free(stdout);
        return error.CommandFailed;
    }
    
    return stdout;
}

fn runGitCommand(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) ![]u8 {
    var child = process.Child.init(args, allocator);
    child.cwd = cwd;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    
    try child.spawn();
    
    const stdout = child.stdout.?.reader().readAllAlloc(allocator, 8192) catch |err| {
        _ = try child.wait();
        return err;
    };
    const stderr = child.stderr.?.reader().readAllAlloc(allocator, 8192) catch |err| {
        allocator.free(stdout);
        _ = try child.wait();  
        return err;
    };
    defer allocator.free(stderr);
    
    const result = try child.wait();
    if (result != .Exited or result.Exited != 0) {
        allocator.free(stdout);
        return error.CommandFailed;
    }
    
    return stdout;
}