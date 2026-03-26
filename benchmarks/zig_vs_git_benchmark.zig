const std = @import("std");
const time = std.time;
const process = std.process;
const ziggit = @import("ziggit");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("=== Ziggit vs Git CLI Benchmark ===", .{});
    std.log.info("Testing ziggit Zig API vs git CLI for bun operations:", .{});
    std.log.info("", .{});
    
    // Create a test repository with real git
    const test_repo_dir = "zig_bench_repo";
    try createTestRepo(allocator, test_repo_dir);
    defer std.fs.cwd().deleteTree(test_repo_dir) catch {};
    
    // Benchmark both git CLI and ziggit
    std.log.info("Running benchmarks...", .{});
    
    const git_status_time = try benchmarkGitOperation(allocator, test_repo_dir, &[_][]const u8{ "git", "-C", test_repo_dir, "status", "--porcelain" }, 100);
    const git_revparse_time = try benchmarkGitOperation(allocator, test_repo_dir, &[_][]const u8{ "git", "-C", test_repo_dir, "rev-parse", "HEAD" }, 100);
    const git_describe_time = try benchmarkGitOperation(allocator, test_repo_dir, &[_][]const u8{ "git", "-C", test_repo_dir, "describe", "--tags", "--abbrev=0" }, 100);
    
    const ziggit_status_time = try benchmarkZiggitOperation(allocator, test_repo_dir, "status", 100);
    const ziggit_revparse_time = try benchmarkZiggitOperation(allocator, test_repo_dir, "rev-parse", 100);
    const ziggit_describe_time = try benchmarkZiggitOperation(allocator, test_repo_dir, "describe", 100);
    
    // Print comparison results
    std.log.info("", .{});
    std.log.info("╭────────────────────────────────────────────────────────────╮", .{});
    std.log.info("│               COMPARISON RESULTS                          │", .{});
    std.log.info("├────────────────────────────────────────────────────────────┤", .{});
    std.log.info("│ Operation         │ Git (ms) │ Ziggit (ms) │ Speedup    │", .{});
    std.log.info("├────────────────────────────────────────────────────────────┤", .{});
    std.log.info("│ status --porcelain│ {d:>8.2} │ {d:>11.2} │ {d:>8.1}x   │", .{git_status_time, ziggit_status_time, git_status_time / ziggit_status_time});
    std.log.info("│ rev-parse HEAD    │ {d:>8.2} │ {d:>11.2} │ {d:>8.1}x   │", .{git_revparse_time, ziggit_revparse_time, git_revparse_time / ziggit_revparse_time});
    std.log.info("│ describe --tags   │ {d:>8.2} │ {d:>11.2} │ {d:>8.1}x   │", .{git_describe_time, ziggit_describe_time, git_describe_time / ziggit_describe_time});
    std.log.info("╰────────────────────────────────────────────────────────────╯", .{});
    
    const total_git_time = git_status_time + git_revparse_time + git_describe_time;
    const total_ziggit_time = ziggit_status_time + ziggit_revparse_time + ziggit_describe_time;
    const overall_speedup = total_git_time / total_ziggit_time;
    
    std.log.info("", .{});
    std.log.info("Overall Performance:", .{});
    std.log.info("  • Git CLI total: {d:.2}ms per operation set", .{total_git_time});
    std.log.info("  • Ziggit total: {d:.2}ms per operation set", .{total_ziggit_time});
    std.log.info("  • Overall speedup: {d:.1}x faster", .{overall_speedup});
    std.log.info("", .{});
    std.log.info("For bun's workflow (100 operation sets):", .{});
    std.log.info("  • Git CLI: ~{d:.0}ms ({d:.1}s)", .{total_git_time * 100, total_git_time * 100 / 1000});
    std.log.info("  • Ziggit: ~{d:.0}ms ({d:.1}s)", .{total_ziggit_time * 100, total_ziggit_time * 100 / 1000});
    std.log.info("  • Time saved: ~{d:.0}ms ({d:.1}s)", .{(total_git_time - total_ziggit_time) * 100, (total_git_time - total_ziggit_time) * 100 / 1000});
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
    
    // Create package.json (typical for bun)
    try std.fs.cwd().writeFile(.{ .sub_path = "package.json", .data = 
        \\{
        \\  "name": "benchmark-package",
        \\  "version": "1.0.0",
        \\  "dependencies": {
        \\    "react": "^18.0.0"
        \\  }
        \\}
    });
    
    // Create source files
    try std.fs.cwd().makeDir("src");
    try std.fs.cwd().writeFile(.{ .sub_path = "src/index.js", .data = "console.log('Hello from benchmark');\n" });
    try std.fs.cwd().writeFile(.{ .sub_path = "src/utils.js", .data = "export const utils = {};\n" });
    
    // Create config files
    try std.fs.cwd().writeFile(.{ .sub_path = "tsconfig.json", .data = "{\"compilerOptions\": {}}\n" });
    
    // Add and commit
    _ = try runCommand(allocator, &[_][]const u8{ "git", "add", "." });
    _ = try runCommand(allocator, &[_][]const u8{ "git", "commit", "-q", "-m", "Initial commit" });
    
    // Create tags
    _ = try runCommand(allocator, &[_][]const u8{ "git", "tag", "v1.0.0" });
    
    // Create some changes to make status interesting
    try std.fs.cwd().writeFile(.{ .sub_path = "src/index.js", .data = "console.log('Modified content');\n" });
    try std.fs.cwd().writeFile(.{ .sub_path = "temp.txt", .data = "temporary file\n" });
    
    // Create one more commit
    _ = try runCommand(allocator, &[_][]const u8{ "git", "add", "src/index.js" });
    _ = try runCommand(allocator, &[_][]const u8{ "git", "commit", "-q", "-m", "Update index" });
    _ = try runCommand(allocator, &[_][]const u8{ "git", "tag", "v1.0.1" });
    
    std.log.info("Created test repository with modifications", .{});
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
        return error.CommandFailed;
    }
    
    return allocator.dupe(u8, stdout);
}

fn benchmarkGitOperation(allocator: std.mem.Allocator, repo_dir: []const u8, argv: []const []const u8, iterations: usize) !f64 {
    _ = repo_dir;
    
    var total_ns: u64 = 0;
    
    for (0..iterations) |_| {
        const start = time.nanoTimestamp();
        
        const result = runCommand(allocator, argv) catch |err| switch (err) {
            error.CommandFailed => {
                const elapsed = @as(u64, @intCast(time.nanoTimestamp() - start));
                total_ns += elapsed;
                continue;
            },
            else => return err,
        };
        allocator.free(result);
        
        const elapsed = @as(u64, @intCast(time.nanoTimestamp() - start));
        total_ns += elapsed;
    }
    
    const avg_ns = total_ns / iterations;
    return @as(f64, @floatFromInt(avg_ns)) / 1_000_000.0;
}

fn benchmarkZiggitOperation(allocator: std.mem.Allocator, repo_dir: []const u8, operation: []const u8, iterations: usize) !f64 {
    var total_ns: u64 = 0;
    
    for (0..iterations) |_| {
        const start = time.nanoTimestamp();
        
        if (std.mem.eql(u8, operation, "status")) {
            // Benchmark ziggit status
            var repo = ziggit.repo_open(allocator, repo_dir) catch {
                const elapsed = @as(u64, @intCast(time.nanoTimestamp() - start));
                total_ns += elapsed;
                continue;
            };
            
            const status_result = ziggit.repo_status(&repo, allocator) catch {
                const elapsed = @as(u64, @intCast(time.nanoTimestamp() - start));
                total_ns += elapsed;
                continue;
            };
            allocator.free(status_result);
            
        } else if (std.mem.eql(u8, operation, "rev-parse")) {
            // Benchmark ziggit rev-parse HEAD
            var repo = ziggit.repo_open(allocator, repo_dir) catch {
                const elapsed = @as(u64, @intCast(time.nanoTimestamp() - start));
                total_ns += elapsed;
                continue;
            };
            
            const hash_result = ziggit.repo_rev_parse_head(&repo, allocator) catch {
                const elapsed = @as(u64, @intCast(time.nanoTimestamp() - start));
                total_ns += elapsed;
                continue;
            };
            allocator.free(hash_result);
            
        } else if (std.mem.eql(u8, operation, "describe")) {
            // Benchmark ziggit describe tags
            var repo = ziggit.repo_open(allocator, repo_dir) catch {
                const elapsed = @as(u64, @intCast(time.nanoTimestamp() - start));
                total_ns += elapsed;
                continue;
            };
            
            const tag_result = ziggit.repo_describe_tags(&repo, allocator) catch {
                const elapsed = @as(u64, @intCast(time.nanoTimestamp() - start));
                total_ns += elapsed;
                continue;
            };
            allocator.free(tag_result);
        }
        
        const elapsed = @as(u64, @intCast(time.nanoTimestamp() - start));
        total_ns += elapsed;
    }
    
    const avg_ns = total_ns / iterations;
    return @as(f64, @floatFromInt(avg_ns)) / 1_000_000.0;
}