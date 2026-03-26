const std = @import("std");
const time = std.time;
const process = std.process;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("=== Simple Git CLI Benchmark ===", .{});
    std.log.info("Testing baseline git performance for bun operations:", .{});
    std.log.info("", .{});
    
    // Create a test repository with real git
    const test_repo_dir = "simple_bench_repo";
    try createTestRepo(allocator, test_repo_dir);
    defer std.fs.cwd().deleteTree(test_repo_dir) catch {};
    
    // Benchmark the critical operations for bun
    std.log.info("Running benchmarks...", .{});
    
    const status_time = try benchmarkGitOperation(allocator, test_repo_dir, &[_][]const u8{ "git", "-C", test_repo_dir, "status", "--porcelain" }, 100);
    const revparse_time = try benchmarkGitOperation(allocator, test_repo_dir, &[_][]const u8{ "git", "-C", test_repo_dir, "rev-parse", "HEAD" }, 100);
    const describe_time = try benchmarkGitOperation(allocator, test_repo_dir, &[_][]const u8{ "git", "-C", test_repo_dir, "describe", "--tags", "--abbrev=0" }, 100);
    
    // Print results
    std.log.info("", .{});
    std.log.info("╭─────────────────────────────────────────╮", .{});
    std.log.info("│          GIT CLI PERFORMANCE           │", .{});
    std.log.info("├─────────────────────────────────────────┤", .{});
    std.log.info("│ Operation           │ Avg Time (ms)     │", .{});
    std.log.info("├─────────────────────────────────────────┤", .{});
    std.log.info("│ status --porcelain  │ {d:>13.2}     │", .{status_time});
    std.log.info("│ rev-parse HEAD      │ {d:>13.2}     │", .{revparse_time});
    std.log.info("│ describe --tags     │ {d:>13.2}     │", .{describe_time});
    std.log.info("╰─────────────────────────────────────────╯", .{});
    
    const total_time = status_time + revparse_time + describe_time;
    std.log.info("", .{});
    std.log.info("Total time per operation set: {d:.2}ms", .{total_time});
    std.log.info("For 100 operations (typical bun install): {d:.0}ms ({d:.1}s)", .{total_time * 100, total_time * 100 / 1000});
    std.log.info("", .{});
    std.log.info("This is the baseline that ziggit needs to beat.", .{});
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
    _ = try runCommand(allocator, &[_][]const u8{ "git", "init", "-q" });
    _ = try runCommand(allocator, &[_][]const u8{ "git", "config", "user.name", "Benchmark User" });
    _ = try runCommand(allocator, &[_][]const u8{ "git", "config", "user.email", "bench@ziggit.com" });
    
    // Create some realistic files
    try std.fs.cwd().writeFile(.{ .sub_path = "package.json", .data = "{\"name\": \"test\", \"version\": \"1.0.0\"}\n" });
    try std.fs.cwd().writeFile(.{ .sub_path = "index.js", .data = "console.log('Hello world');\n" });
    try std.fs.cwd().writeFile(.{ .sub_path = "README.md", .data = "# Test Repository\n" });
    
    // Add and commit
    _ = try runCommand(allocator, &[_][]const u8{ "git", "add", "." });
    _ = try runCommand(allocator, &[_][]const u8{ "git", "commit", "-q", "-m", "Initial commit" });
    
    // Create a tag
    _ = try runCommand(allocator, &[_][]const u8{ "git", "tag", "v1.0.0" });
    
    // Create some changes to test status
    try std.fs.cwd().writeFile(.{ .sub_path = "index.js", .data = "console.log('Modified');\n" });
    try std.fs.cwd().writeFile(.{ .sub_path = "new-file.js", .data = "// New file\n" });
    
    std.log.info("Created test repository", .{});
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
        std.log.err("Command failed: {s}", .{argv[0]});
        if (stderr.len > 0) std.log.err("Stderr: {s}", .{stderr});
        return error.CommandFailed;
    }
    
    return allocator.dupe(u8, stdout);
}

fn benchmarkGitOperation(allocator: std.mem.Allocator, repo_dir: []const u8, argv: []const []const u8, iterations: usize) !f64 {
    _ = repo_dir;
    
    var total_ns: u64 = 0;
    var successful_runs: usize = 0;
    
    for (0..iterations) |_| {
        const start = time.nanoTimestamp();
        
        const result = runCommand(allocator, argv) catch |err| switch (err) {
            error.CommandFailed => {
                // Command failed but we still measure the time
                const elapsed = @as(u64, @intCast(time.nanoTimestamp() - start));
                total_ns += elapsed;
                continue;
            },
            else => return err,
        };
        allocator.free(result);
        
        const elapsed = @as(u64, @intCast(time.nanoTimestamp() - start));
        total_ns += elapsed;
        successful_runs += 1;
    }
    
    if (successful_runs == 0) successful_runs = iterations; // Use all iterations if all failed
    
    const avg_ns = total_ns / iterations;
    const avg_ms = @as(f64, @floatFromInt(avg_ns)) / 1_000_000.0;
    
    return avg_ms;
}