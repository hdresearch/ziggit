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
    git_avg_ns: u64,
    ziggit_avg_ns: u64,
    speedup: f64,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("=== Real Git Benchmark (ziggit vs git CLI) ===\n", .{});
    
    // Create a test repository with real git
    const test_repo_dir = "bench_test_repo";
    try createTestRepo(allocator, test_repo_dir);
    defer std.fs.cwd().deleteTree(test_repo_dir) catch {};
    
    var results = std.ArrayList(BenchResult).init(allocator);
    defer results.deinit();
    
    // Benchmark git status --porcelain
    try results.append(try benchmarkStatusPorcelain(allocator, test_repo_dir));
    
    // Benchmark git rev-parse HEAD
    try results.append(try benchmarkRevParseHead(allocator, test_repo_dir));
    
    // Benchmark git describe --tags (if tags exist)
    try results.append(try benchmarkDescribeTags(allocator, test_repo_dir));
    
    // Print results
    std.log.info("╭─────────────────────────────────────────────────────────╮", .{});
    std.log.info("│                  BENCHMARK RESULTS                      │", .{});
    std.log.info("├─────────────────────────────────────────────────────────┤", .{});
    std.log.info("│ Operation        │ Git (ms) │ Ziggit (ms) │ Speedup    │", .{});
    std.log.info("├─────────────────────────────────────────────────────────┤", .{});
    
    for (results.items) |result| {
        const git_ms = @as(f64, @floatFromInt(result.git_avg_ns)) / 1_000_000.0;
        const ziggit_ms = @as(f64, @floatFromInt(result.ziggit_avg_ns)) / 1_000_000.0;
        std.log.info("│ {s:<16} │ {d:>8.2}   │ {d:>11.2}   │ {d:>8.2}x   │", .{
            result.name, git_ms, ziggit_ms, result.speedup
        });
    }
    
    std.log.info("╰─────────────────────────────────────────────────────────╯", .{});
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
    
    // Create multiple files for a realistic test
    const files = [_][]const u8{
        "README.md", "src/main.zig", "src/lib.zig", "build.zig", 
        "test/test1.zig", "test/test2.zig", "docs/api.md", "examples/hello.zig"
    };
    
    for (files) |file_path| {
        // Create directory if needed
        if (std.fs.path.dirname(file_path)) |dir| {
            std.fs.cwd().makePath(dir) catch {};
        }
        
        // Write some content to the file
        const content = try std.fmt.allocPrint(allocator, "// File: {s}\nconst std = @import(\"std\");\n\npub fn main() void {{\n    // Test content\n}}\n", .{file_path});
        defer allocator.free(content);
        
        try std.fs.cwd().writeFile(.{ .sub_path = file_path, .data = content });
    }
    
    // Add and commit files
    _ = try runCommand(allocator, &[_][]const u8{ "git", "add", "." });
    _ = try runCommand(allocator, &[_][]const u8{ "git", "commit", "-m", "Initial commit" });
    
    // Create some modifications for status testing
    try std.fs.cwd().writeFile(.{ .sub_path = "README.md", .data = "# Modified README\nThis file has been modified.\n" });
    try std.fs.cwd().writeFile(.{ .sub_path = "new_file.txt", .data = "This is a new file.\n" });
    
    // Add a tag
    _ = try runCommand(allocator, &[_][]const u8{ "git", "tag", "v1.0.0" });
    
    // Make another commit
    _ = try runCommand(allocator, &[_][]const u8{ "git", "add", "README.md" });
    _ = try runCommand(allocator, &[_][]const u8{ "git", "commit", "-m", "Update README" });
    _ = try runCommand(allocator, &[_][]const u8{ "git", "tag", "v1.0.1" });
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
        std.log.err("Stderr: {s}", .{stderr});
        return error.CommandFailed;
    }
    
    return allocator.dupe(u8, stdout);
}

fn benchmarkStatusPorcelain(allocator: std.mem.Allocator, repo_dir: []const u8) !BenchResult {
    const iterations = 100;
    
    // Benchmark git status --porcelain
    var git_total: u64 = 0;
    
    for (0..iterations) |_| {
        const start = time.nanoTimestamp();
        const result = try runCommand(allocator, &[_][]const u8{ "git", "-C", repo_dir, "status", "--porcelain" });
        allocator.free(result);
        const elapsed = @as(u64, @intCast(time.nanoTimestamp() - start));
        git_total += elapsed;
    }
    
    const git_avg = git_total / iterations;
    
    // Benchmark ziggit status
    const repo_path_z = try allocator.dupeZ(u8, repo_dir);
    defer allocator.free(repo_path_z);
    
    const repo = ziggit_repo_open(repo_path_z.ptr) orelse return error.RepoOpenFailed;
    defer ziggit_repo_close(repo);
    
    var buffer: [4096]u8 = undefined;
    
    var ziggit_total: u64 = 0;
    
    for (0..iterations) |_| {
        const start = time.nanoTimestamp();
        _ = ziggit_status_porcelain(repo, &buffer, buffer.len);
        const elapsed = @as(u64, @intCast(time.nanoTimestamp() - start));
        ziggit_total += elapsed;
    }
    
    const ziggit_avg = ziggit_total / iterations;
    const speedup = @as(f64, @floatFromInt(git_avg)) / @as(f64, @floatFromInt(ziggit_avg));
    
    return BenchResult{
        .name = "status --porcelain",
        .git_avg_ns = git_avg,
        .ziggit_avg_ns = ziggit_avg,
        .speedup = speedup,
    };
}

fn benchmarkRevParseHead(allocator: std.mem.Allocator, repo_dir: []const u8) !BenchResult {
    const iterations = 100;
    
    // Benchmark git rev-parse HEAD
    var git_total: u64 = 0;
    
    for (0..iterations) |_| {
        const start = time.nanoTimestamp();
        const result = try runCommand(allocator, &[_][]const u8{ "git", "-C", repo_dir, "rev-parse", "HEAD" });
        allocator.free(result);
        const elapsed = @as(u64, @intCast(time.nanoTimestamp() - start));
        git_total += elapsed;
    }
    
    const git_avg = git_total / iterations;
    
    // Benchmark ziggit rev-parse HEAD
    const repo_path_z = try allocator.dupeZ(u8, repo_dir);
    defer allocator.free(repo_path_z);
    
    const repo = ziggit_repo_open(repo_path_z.ptr) orelse return error.RepoOpenFailed;
    defer ziggit_repo_close(repo);
    
    var buffer: [64]u8 = undefined;
    var ziggit_total: u64 = 0;
    
    for (0..iterations) |_| {
        const start = time.nanoTimestamp();
        _ = ziggit_rev_parse_head(repo, &buffer, buffer.len);
        const elapsed = @as(u64, @intCast(time.nanoTimestamp() - start));
        ziggit_total += elapsed;
    }
    
    const ziggit_avg = ziggit_total / iterations;
    const speedup = @as(f64, @floatFromInt(git_avg)) / @as(f64, @floatFromInt(ziggit_avg));
    
    return BenchResult{
        .name = "rev-parse HEAD",
        .git_avg_ns = git_avg,
        .ziggit_avg_ns = ziggit_avg,
        .speedup = speedup,
    };
}

fn benchmarkDescribeTags(allocator: std.mem.Allocator, repo_dir: []const u8) !BenchResult {
    const iterations = 100;
    
    // Benchmark git describe --tags --abbrev=0
    var git_total: u64 = 0;
    
    for (0..iterations) |_| {
        const start = time.nanoTimestamp();
        const result = runCommand(allocator, &[_][]const u8{ "git", "-C", repo_dir, "describe", "--tags", "--abbrev=0" }) catch |err| switch (err) {
            error.CommandFailed => {
                // No tags, return dummy result
                const dummy_time = 1000; // 1 microsecond
                git_total += dummy_time;
                continue;
            },
            else => return err,
        };
        allocator.free(result);
        const elapsed = @as(u64, @intCast(time.nanoTimestamp() - start));
        git_total += elapsed;
    }
    
    const git_avg = git_total / iterations;
    
    // Benchmark ziggit describe tags
    const repo_path_z = try allocator.dupeZ(u8, repo_dir);
    defer allocator.free(repo_path_z);
    
    const repo = ziggit_repo_open(repo_path_z.ptr) orelse return error.RepoOpenFailed;
    defer ziggit_repo_close(repo);
    
    var buffer: [256]u8 = undefined;
    var ziggit_total: u64 = 0;
    
    for (0..iterations) |_| {
        const start = time.nanoTimestamp();
        _ = ziggit_describe_tags(repo, &buffer, buffer.len);
        const elapsed = @as(u64, @intCast(time.nanoTimestamp() - start));
        ziggit_total += elapsed;
    }
    
    const ziggit_avg = ziggit_total / iterations;
    const speedup = @as(f64, @floatFromInt(git_avg)) / @as(f64, @floatFromInt(ziggit_avg));
    
    return BenchResult{
        .name = "describe --tags",
        .git_avg_ns = git_avg,
        .ziggit_avg_ns = ziggit_avg,
        .speedup = speedup,
    };
}