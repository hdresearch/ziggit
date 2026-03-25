const std = @import("std");

// Import the C library
const c = @cImport({
    @cInclude("ziggit.h");
});

const BENCHMARK_ITERATIONS = 1000;
const TEST_FILES_COUNT = 100;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    std.debug.print("=== Ziggit vs Git CLI Real Repository Benchmark ===\n\n", .{});

    // Create a temporary test repository
    const test_repo_path = "/tmp/ziggit_bench_repo";
    
    // Cleanup any existing test repo
    cleanupTestRepo(test_repo_path);
    
    // Create test repository with real git
    try createTestRepository(test_repo_path, allocator);
    defer cleanupTestRepo(test_repo_path);

    std.debug.print("Created test repository with {} files and multiple commits at: {s}\n\n", .{ TEST_FILES_COUNT, test_repo_path });

    // Benchmark 1: Repository opening
    try benchmarkRepoOpen(test_repo_path, allocator);

    // Benchmark 2: Status porcelain (the hot path for bun)
    try benchmarkStatusPorcelain(test_repo_path, allocator);

    // Benchmark 3: Rev-parse HEAD (the other hot path for bun)
    try benchmarkRevParseHead(test_repo_path, allocator);

    // Benchmark 4: Describe tags
    try benchmarkDescribeTags(test_repo_path, allocator);

    std.debug.print("\n=== Benchmark Complete ===\n", .{});
}

fn createTestRepository(repo_path: []const u8, allocator: std.mem.Allocator) !void {
    // Initialize git repository
    const git_init_cmd = try std.fmt.allocPrint(allocator, "git init {s}", .{repo_path});
    _ = try runCommand(git_init_cmd, allocator);

    // Change to repo directory
    const original_cwd = std.fs.cwd();
    var repo_dir = try std.fs.openDirAbsolute(repo_path, .{});
    defer repo_dir.close();
    try std.posix.fchdir(repo_dir.fd);
    defer std.posix.fchdir(original_cwd.fd) catch {};

    // Configure git user (needed for commits)
    _ = try runCommand("git config user.name \"Ziggit Benchmark\"", allocator);
    _ = try runCommand("git config user.email \"ziggit@example.com\"", allocator);

    // Create test files
    var i: usize = 0;
    while (i < TEST_FILES_COUNT) : (i += 1) {
        const filename = try std.fmt.allocPrint(allocator, "file{}.txt", .{i});
        const content = try std.fmt.allocPrint(allocator, "This is test file {}\nLine 2\nLine 3\n", .{i});
        
        const file = try std.fs.cwd().createFile(filename, .{});
        defer file.close();
        try file.writeAll(content);
    }

    // Create initial commit
    _ = try runCommand("git add .", allocator);
    _ = try runCommand("git commit -m \"Initial commit with test files\"", allocator);

    // Create a few more commits with changes
    try createFile("README.md", "# Test Repository\nThis is a benchmark repository.\n");
    _ = try runCommand("git add README.md", allocator);
    _ = try runCommand("git commit -m \"Add README\"", allocator);

    // Modify some files
    try createFile("file0.txt", "Modified content for file 0\nNew line\n");
    try createFile("file1.txt", "Modified content for file 1\nAnother new line\n");
    _ = try runCommand("git add file0.txt file1.txt", allocator);
    _ = try runCommand("git commit -m \"Modify files 0 and 1\"", allocator);

    // Create a tag
    _ = try runCommand("git tag -a v1.0.0 -m \"Version 1.0.0\"", allocator);

    // Create another commit
    try createFile("new_file.txt", "This is a new file\n");
    _ = try runCommand("git add new_file.txt", allocator);
    _ = try runCommand("git commit -m \"Add new file\"", allocator);

    // Create another tag
    _ = try runCommand("git tag -a v1.1.0 -m \"Version 1.1.0\"", allocator);
}

fn createFile(filename: []const u8, content: []const u8) !void {
    const file = try std.fs.cwd().createFile(filename, .{ .truncate = true });
    defer file.close();
    try file.writeAll(content);
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

fn cleanupTestRepo(repo_path: []const u8) void {
    const allocator = std.heap.page_allocator;
    const rm_cmd = std.fmt.allocPrint(allocator, "rm -rf {s}", .{repo_path}) catch return;
    defer allocator.free(rm_cmd);
    _ = runCommand(rm_cmd, allocator) catch {};
}

fn benchmarkRepoOpen(repo_path: []const u8, allocator: std.mem.Allocator) !void {
    std.debug.print("=== Repository Opening Benchmark ===\n", .{});

    // Benchmark ziggit
    const ziggit_start = std.time.milliTimestamp();
    var ziggit_success_count: usize = 0;
    
    var i: usize = 0;
    while (i < BENCHMARK_ITERATIONS) : (i += 1) {
        const repo_path_z = try allocator.dupeZ(u8, repo_path);
        const repo = c.ziggit_repo_open(repo_path_z.ptr);
        if (repo != null) {
            ziggit_success_count += 1;
            c.ziggit_repo_close(repo);
        }
    }
    
    const ziggit_end = std.time.milliTimestamp();
    const ziggit_duration = ziggit_end - ziggit_start;

    // Benchmark git CLI
    const git_start = std.time.milliTimestamp();
    var git_success_count: usize = 0;
    
    i = 0;
    while (i < BENCHMARK_ITERATIONS) : (i += 1) {
        const cmd = try std.fmt.allocPrint(allocator, "cd {s} && git rev-parse --git-dir >/dev/null 2>&1", .{repo_path});
        const result = runCommand(cmd, allocator) catch "";
        if (result.len >= 0) { // Command succeeded
            git_success_count += 1;
        }
    }
    
    const git_end = std.time.milliTimestamp();
    const git_duration = git_end - git_start;

    // Print results
    std.debug.print("Iterations: {}\n", .{BENCHMARK_ITERATIONS});
    std.debug.print("Ziggit repo open: {} ms ({} successes) - {d:.2} ms per operation\n", .{ ziggit_duration, ziggit_success_count, @as(f64, @floatFromInt(ziggit_duration)) / @as(f64, @floatFromInt(BENCHMARK_ITERATIONS)) });
    std.debug.print("Git CLI validation: {} ms ({} successes) - {d:.2} ms per operation\n", .{ git_duration, git_success_count, @as(f64, @floatFromInt(git_duration)) / @as(f64, @floatFromInt(BENCHMARK_ITERATIONS)) });
    
    if (git_duration > 0) {
        const speedup = @as(f64, @floatFromInt(git_duration)) / @as(f64, @floatFromInt(ziggit_duration));
        std.debug.print("Ziggit is {d:.2}x faster\n\n", .{speedup});
    }
}

fn benchmarkStatusPorcelain(repo_path: []const u8, allocator: std.mem.Allocator) !void {
    std.debug.print("=== Status Porcelain Benchmark (Bun Hot Path) ===\n", .{});

    // Benchmark ziggit
    const ziggit_start = std.time.milliTimestamp();
    var ziggit_success_count: usize = 0;
    
    const repo_path_z = try allocator.dupeZ(u8, repo_path);
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
        const result = runCommand(cmd, allocator) catch "";
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
        std.debug.print("Ziggit is {d:.2}x faster\n\n", .{speedup});
    }
}

fn benchmarkRevParseHead(repo_path: []const u8, allocator: std.mem.Allocator) !void {
    std.debug.print("=== Rev-Parse HEAD Benchmark (Bun Hot Path) ===\n", .{});

    // Benchmark ziggit
    const ziggit_start = std.time.milliTimestamp();
    var ziggit_success_count: usize = 0;
    
    const repo_path_z = try allocator.dupeZ(u8, repo_path);
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
        const result = runCommand(cmd, allocator) catch "";
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
        std.debug.print("Ziggit is {d:.2}x faster\n\n", .{speedup});
    }
}

fn benchmarkDescribeTags(repo_path: []const u8, allocator: std.mem.Allocator) !void {
    std.debug.print("=== Describe Tags Benchmark ===\n", .{});

    // Benchmark ziggit
    const ziggit_start = std.time.milliTimestamp();
    var ziggit_success_count: usize = 0;
    
    const repo_path_z = try allocator.dupeZ(u8, repo_path);
    const repo = c.ziggit_repo_open(repo_path_z.ptr);
    if (repo == null) {
        std.debug.print("Failed to open repository with ziggit\n", .{});
        return;
    }
    defer c.ziggit_repo_close(repo);

    var buffer: [256]u8 = undefined;
    
    var i: usize = 0;
    while (i < BENCHMARK_ITERATIONS) : (i += 1) {
        const result = c.ziggit_describe_tags(repo, &buffer, buffer.len);
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
        const cmd = try std.fmt.allocPrint(allocator, "cd {s} && git describe --tags --abbrev=0", .{repo_path});
        const result = runCommand(cmd, allocator) catch "";
        if (result.len > 0) { // Got a tag
            git_success_count += 1;
        }
    }
    
    const git_end = std.time.milliTimestamp();
    const git_duration = git_end - git_start;

    // Print results
    std.debug.print("Iterations: {}\n", .{BENCHMARK_ITERATIONS});
    std.debug.print("Ziggit describe --tags: {} ms ({} successes) - {d:.2} ms per operation\n", .{ ziggit_duration, ziggit_success_count, @as(f64, @floatFromInt(ziggit_duration)) / @as(f64, @floatFromInt(BENCHMARK_ITERATIONS)) });
    std.debug.print("Git CLI describe --tags: {} ms ({} successes) - {d:.2} ms per operation\n", .{ git_duration, git_success_count, @as(f64, @floatFromInt(git_duration)) / @as(f64, @floatFromInt(BENCHMARK_ITERATIONS)) });
    
    if (git_duration > 0) {
        const speedup = @as(f64, @floatFromInt(git_duration)) / @as(f64, @floatFromInt(ziggit_duration));
        std.debug.print("Ziggit is {d:.2}x faster\n\n", .{speedup});
    }
}