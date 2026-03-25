const std = @import("std");
const time = std.time;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("=== Real Git Benchmark (Git CLI Only) ===\n", .{});
    
    // Create a test repository with real git
    const test_repo_dir = "simple_bench_test_repo";
    try createTestRepo(allocator, test_repo_dir);
    defer std.fs.cwd().deleteTree(test_repo_dir) catch {};
    
    // Benchmark git operations
    try benchmarkGitOperations(allocator, test_repo_dir);
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
    
    // Create 100 files for a more realistic test
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const filename = try std.fmt.allocPrint(allocator, "file_{d:0>3}.txt", .{i});
        defer allocator.free(filename);
        
        const content = try std.fmt.allocPrint(allocator, "File number {d}\nThis is test content for file {d}\n", .{ i, i });
        defer allocator.free(content);
        
        try std.fs.cwd().writeFile(.{ .sub_path = filename, .data = content });
    }
    
    // Add and commit files
    _ = try runCommand(allocator, &[_][]const u8{ "git", "add", "." });
    _ = try runCommand(allocator, &[_][]const u8{ "git", "commit", "-m", "Initial commit with 100 files" });
    
    // Create some modifications for status testing
    try std.fs.cwd().writeFile(.{ .sub_path = "file_001.txt", .data = "Modified content in file 001\n" });
    try std.fs.cwd().writeFile(.{ .sub_path = "new_untracked.txt", .data = "This is a new untracked file.\n" });
    
    // Add a tag
    _ = try runCommand(allocator, &[_][]const u8{ "git", "tag", "v1.0.0" });
    
    // Make some more commits
    _ = try runCommand(allocator, &[_][]const u8{ "git", "add", "file_001.txt" });
    _ = try runCommand(allocator, &[_][]const u8{ "git", "commit", "-m", "Modify file_001" });
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

fn benchmarkGitOperations(allocator: std.mem.Allocator, repo_dir: []const u8) !void {
    const iterations = 50;
    
    std.log.info("Benchmarking git operations ({} iterations each):\n", .{iterations});
    
    // Benchmark git status --porcelain
    const status_result = try benchmarkSingleOperation(
        allocator,
        repo_dir,
        &[_][]const u8{ "git", "-C", repo_dir, "status", "--porcelain" },
        iterations,
        "status --porcelain"
    );
    std.log.info("  {s}: {d:.3}ms avg", .{ "git status --porcelain", status_result });
    
    // Benchmark git rev-parse HEAD
    const rev_parse_result = try benchmarkSingleOperation(
        allocator,
        repo_dir,
        &[_][]const u8{ "git", "-C", repo_dir, "rev-parse", "HEAD" },
        iterations,
        "rev-parse HEAD"
    );
    std.log.info("  {s}: {d:.3}ms avg", .{ "git rev-parse HEAD", rev_parse_result });
    
    // Benchmark git describe --tags --abbrev=0
    const describe_result = try benchmarkSingleOperation(
        allocator,
        repo_dir,
        &[_][]const u8{ "git", "-C", repo_dir, "describe", "--tags", "--abbrev=0" },
        iterations,
        "describe --tags"
    );
    std.log.info("  {s}: {d:.3}ms avg", .{ "git describe --tags", describe_result });
    
    std.log.info("\nThis shows the baseline performance that ziggit needs to beat.", .{});
    std.log.info("Bun calls these operations hundreds of times during package resolution.", .{});
}

fn benchmarkSingleOperation(
    allocator: std.mem.Allocator,
    repo_dir: []const u8,
    argv: []const []const u8,
    iterations: usize,
    operation_name: []const u8
) !f64 {
    _ = repo_dir;
    _ = operation_name;
    
    var total_time: u64 = 0;
    
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const start = time.nanoTimestamp();
        
        const result = runCommand(allocator, argv) catch |err| switch (err) {
            error.CommandFailed => {
                // Some operations might fail (e.g., no tags), but we still measure the time
                const elapsed = @as(u64, @intCast(time.nanoTimestamp() - start));
                total_time += elapsed;
                continue;
            },
            else => return err,
        };
        allocator.free(result);
        
        const elapsed = @as(u64, @intCast(time.nanoTimestamp() - start));
        total_time += elapsed;
    }
    
    const avg_ns = total_time / iterations;
    const avg_ms = @as(f64, @floatFromInt(avg_ns)) / 1_000_000.0;
    
    return avg_ms;
}