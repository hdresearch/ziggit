const std = @import("std");
const print = std.debug.print;

// Test data structures
const BenchmarkResult = struct {
    operation: []const u8,
    git_cli_ns: ?u64 = null,
    ziggit_cli_ns: ?u64 = null,
    git_success: bool = false,
    ziggit_success: bool = false,
};

// Helper function for timing
fn timeOperation(comptime name: []const u8) struct { start_time: i128, name: []const u8 } {
    const start = std.time.nanoTimestamp();
    return .{ .start_time = start, .name = name };
}

fn finishTiming(timer: anytype) u64 {
    const end = std.time.nanoTimestamp();
    const duration = @as(u64, @intCast(end - timer.start_time));
    std.log.info("{s} took {d}ns ({d:.2}ms)", .{ timer.name, duration, @as(f64, @floatFromInt(duration)) / 1_000_000.0 });
    return duration;
}

fn runCommand(allocator: std.mem.Allocator, args: []const []const u8, cwd: ?[]const u8) !std.process.Child.RunResult {
    return try std.process.Child.run(.{
        .allocator = allocator,
        .argv = args,
        .cwd = cwd,
    });
}

fn cleanupTestDir(path: []const u8) void {
    std.fs.deleteTreeAbsolute(path) catch {};
}

// Benchmark implementations
fn benchmarkRepoInit(allocator: std.mem.Allocator, test_dir: []const u8) !BenchmarkResult {
    var result = BenchmarkResult{ .operation = "repo_init" };
    
    // Test git CLI
    {
        const git_path = try std.fmt.allocPrint(allocator, "{s}_git", .{test_dir});
        defer allocator.free(git_path);
        defer cleanupTestDir(git_path);
        
        const timer = timeOperation("git init");
        const git_result_cmd = runCommand(allocator, &.{ "git", "init", git_path }, null) catch {
            result.git_cli_ns = finishTiming(timer);
            result.git_success = false;
            return result;
        };
        result.git_cli_ns = finishTiming(timer);
        
        result.git_success = git_result_cmd.term == .Exited and git_result_cmd.term.Exited == 0;
        allocator.free(git_result_cmd.stdout);
        allocator.free(git_result_cmd.stderr);
    }
    
    // Test ziggit CLI 
    {
        const ziggit_path = try std.fmt.allocPrint(allocator, "{s}_ziggit", .{test_dir});
        defer allocator.free(ziggit_path);
        defer cleanupTestDir(ziggit_path);
        
        try std.fs.makeDirAbsolute(ziggit_path);
        
        const timer2 = timeOperation("ziggit init");
        const ziggit_result = runCommand(allocator, &.{ "/root/ziggit/zig-out/bin/ziggit", "init" }, ziggit_path) catch {
            result.ziggit_cli_ns = finishTiming(timer2);
            result.ziggit_success = false;
            return result;
        };
        result.ziggit_cli_ns = finishTiming(timer2);
        
        result.ziggit_success = ziggit_result.term == .Exited and ziggit_result.term.Exited == 0;
        allocator.free(ziggit_result.stdout);
        allocator.free(ziggit_result.stderr);
    }
    
    return result;
}

fn benchmarkRepoStatus(allocator: std.mem.Allocator, test_dir: []const u8) !BenchmarkResult {
    var result = BenchmarkResult{ .operation = "repo_status" };
    
    // Setup test repositories
    const git_path = try std.fmt.allocPrint(allocator, "{s}_git_status", .{test_dir});
    defer allocator.free(git_path);
    defer cleanupTestDir(git_path);
    
    const ziggit_path = try std.fmt.allocPrint(allocator, "{s}_ziggit_status", .{test_dir});
    defer allocator.free(ziggit_path);
    defer cleanupTestDir(ziggit_path);
    
    // Initialize repos
    _ = runCommand(allocator, &.{ "git", "init", git_path }, null) catch return result;
    _ = runCommand(allocator, &.{ "git", "config", "user.name", "Test" }, git_path) catch return result;
    _ = runCommand(allocator, &.{ "git", "config", "user.email", "test@example.com" }, git_path) catch return result;
    
    try std.fs.makeDirAbsolute(ziggit_path);
    _ = runCommand(allocator, &.{ "/root/ziggit/zig-out/bin/ziggit", "init" }, ziggit_path) catch return result;
    
    // Add some files
    const git_file_path = try std.fmt.allocPrint(allocator, "{s}/test.txt", .{git_path});
    defer allocator.free(git_file_path);
    const ziggit_file_path = try std.fmt.allocPrint(allocator, "{s}/test.txt", .{ziggit_path});
    defer allocator.free(ziggit_file_path);
    
    const file_content = "test file content\n";
    
    const git_file = try std.fs.createFileAbsolute(git_file_path, .{});
    defer git_file.close();
    try git_file.writeAll(file_content);
    
    const ziggit_file = try std.fs.createFileAbsolute(ziggit_file_path, .{});
    defer ziggit_file.close();
    try ziggit_file.writeAll(file_content);
    
    // Test git CLI status
    {
        const timer = timeOperation("git status");
        const git_status_result = runCommand(allocator, &.{ "git", "status", "--porcelain" }, git_path) catch {
            result.git_cli_ns = finishTiming(timer);
            result.git_success = false;
            return result;
        };
        result.git_cli_ns = finishTiming(timer);
        
        result.git_success = git_status_result.term == .Exited and git_status_result.term.Exited == 0;
        allocator.free(git_status_result.stdout);
        allocator.free(git_status_result.stderr);
    }
    
    // Test ziggit CLI status
    {
        const timer2 = timeOperation("ziggit status");
        const ziggit_status_result = runCommand(allocator, &.{ "/root/ziggit/zig-out/bin/ziggit", "status", "--porcelain" }, ziggit_path) catch {
            result.ziggit_cli_ns = finishTiming(timer2);
            result.ziggit_success = false;
            return result;
        };
        result.ziggit_cli_ns = finishTiming(timer2);
        
        result.ziggit_success = ziggit_status_result.term == .Exited and ziggit_status_result.term.Exited == 0;
        allocator.free(ziggit_status_result.stdout);
        allocator.free(ziggit_status_result.stderr);
    }
    
    return result;
}

// Simulate the operations bun commonly needs
fn benchmarkBunWorkflow(allocator: std.mem.Allocator, test_dir: []const u8) !BenchmarkResult {
    var result = BenchmarkResult{ .operation = "bun_workflow" };
    
    const git_path = try std.fmt.allocPrint(allocator, "{s}_bun_git", .{test_dir});
    defer allocator.free(git_path);
    defer cleanupTestDir(git_path);
    
    const ziggit_path = try std.fmt.allocPrint(allocator, "{s}_bun_ziggit", .{test_dir});
    defer allocator.free(ziggit_path);
    defer cleanupTestDir(ziggit_path);
    
    // Setup git repository
    _ = runCommand(allocator, &.{ "git", "init", git_path }, null) catch return result;
    _ = runCommand(allocator, &.{ "git", "config", "user.name", "Bun Test" }, git_path) catch return result;
    _ = runCommand(allocator, &.{ "git", "config", "user.email", "bun@test.com" }, git_path) catch return result;
    
    // Setup ziggit repository
    try std.fs.makeDirAbsolute(ziggit_path);
    _ = runCommand(allocator, &.{ "/root/ziggit/zig-out/bin/ziggit", "init" }, ziggit_path) catch return result;
    
    // Simulate bun package.json and lockfile creation
    const package_json = "{\n  \"name\": \"test-project\",\n  \"version\": \"1.0.0\"\n}\n";
    const lockfile_content = "# Bun lockfile content\nversion: 1\n";
    
    const git_package_path = try std.fmt.allocPrint(allocator, "{s}/package.json", .{git_path});
    defer allocator.free(git_package_path);
    const git_lock_path = try std.fmt.allocPrint(allocator, "{s}/bun.lockb", .{git_path});
    defer allocator.free(git_lock_path);
    
    const ziggit_package_path = try std.fmt.allocPrint(allocator, "{s}/package.json", .{ziggit_path});
    defer allocator.free(ziggit_package_path);
    const ziggit_lock_path = try std.fmt.allocPrint(allocator, "{s}/bun.lockb", .{ziggit_path});
    defer allocator.free(ziggit_lock_path);
    
    // Create files in git repo
    const git_package_file = try std.fs.createFileAbsolute(git_package_path, .{});
    defer git_package_file.close();
    try git_package_file.writeAll(package_json);
    
    const git_lock_file = try std.fs.createFileAbsolute(git_lock_path, .{});
    defer git_lock_file.close();
    try git_lock_file.writeAll(lockfile_content);
    
    // Create files in ziggit repo
    const ziggit_package_file = try std.fs.createFileAbsolute(ziggit_package_path, .{});
    defer ziggit_package_file.close();
    try ziggit_package_file.writeAll(package_json);
    
    const ziggit_lock_file = try std.fs.createFileAbsolute(ziggit_lock_path, .{});
    defer ziggit_lock_file.close();
    try ziggit_lock_file.writeAll(lockfile_content);
    
    // Benchmark typical bun workflow: status check + version query
    {
        const timer = timeOperation("git bun workflow");
        
        // Status check (what bun does for dependency management)
        const status_result = runCommand(allocator, &.{ "git", "status", "--porcelain", "package.json", "bun.lockb" }, git_path) catch {
            result.git_cli_ns = finishTiming(timer);
            result.git_success = false;
            return result;
        };
        allocator.free(status_result.stdout);
        allocator.free(status_result.stderr);
        
        result.git_cli_ns = finishTiming(timer);
        result.git_success = status_result.term == .Exited and status_result.term.Exited == 0;
    }
    
    {
        const timer2 = timeOperation("ziggit bun workflow");
        
        // Status check (what bun would do with ziggit)
        const status_result = runCommand(allocator, &.{ "/root/ziggit/zig-out/bin/ziggit", "status", "--porcelain" }, ziggit_path) catch {
            result.ziggit_cli_ns = finishTiming(timer2);
            result.ziggit_success = false;
            return result;
        };
        allocator.free(status_result.stdout);
        allocator.free(status_result.stderr);
        
        result.ziggit_cli_ns = finishTiming(timer2);
        result.ziggit_success = status_result.term == .Exited and status_result.term.Exited == 0;
    }
    
    return result;
}

// Main benchmark runner focused on bun's specific use cases
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    print("=== Bun Integration Benchmark: ziggit vs git CLI ===\n", .{});
    print("Testing operations that bun commonly uses...\n\n", .{});
    print("Note: Library APIs unavailable due to compilation issues.\n", .{});
    print("Using CLI comparison instead.\n\n", .{});
    
    const test_base_dir = "/tmp/bun_integration_bench";
    cleanupTestDir(test_base_dir);
    
    var results = std.ArrayList(BenchmarkResult).init(allocator);
    defer results.deinit();
    
    // Repository initialization (used by bun create, install)
    print("Benchmarking repository initialization...\n", .{});
    const init_result = try benchmarkRepoInit(allocator, test_base_dir);
    try results.append(init_result);
    
    // Repository status (used by bun pm hash, dependency checks)
    print("Benchmarking repository status...\n", .{});
    const status_result = try benchmarkRepoStatus(allocator, test_base_dir);
    try results.append(status_result);
    
    // Bun workflow simulation
    print("Benchmarking typical bun workflow...\n", .{});
    const workflow_result = try benchmarkBunWorkflow(allocator, test_base_dir);
    try results.append(workflow_result);
    
    // Print summary
    print("\n=== BENCHMARK SUMMARY ===\n", .{});
    print("Operation       | git CLI  | ziggit CLI | Winner\n", .{});
    print("----------------|----------|------------|-------\n", .{});
    
    for (results.items) |r| {
        const git_ms = if (r.git_cli_ns) |ns| @as(f64, @floatFromInt(ns)) / 1_000_000.0 else 0.0;
        const ziggit_ms = if (r.ziggit_cli_ns) |ns| @as(f64, @floatFromInt(ns)) / 1_000_000.0 else 0.0;
        
        // Determine winner
        var winner: []const u8 = "none";
        if (r.git_success and r.ziggit_success) {
            winner = if (ziggit_ms < git_ms) "ziggit" else "git CLI";
        } else if (r.git_success) {
            winner = "git CLI";
        } else if (r.ziggit_success) {
            winner = "ziggit";
        }
        
        const git_status = if (r.git_success) "✓" else "✗";
        const ziggit_status = if (r.ziggit_success) "✓" else "✗";
        
        print("{s:<15} | {s}{d:>7.2}ms | {s}{d:>8.2}ms | {s}\n", .{
            r.operation, git_status, git_ms, ziggit_status, ziggit_ms, winner
        });
    }
    
    // Calculate performance improvements for bun
    print("\n=== PERFORMANCE ANALYSIS FOR BUN ===\n", .{});
    for (results.items) |r| {
        if (r.ziggit_cli_ns != null and r.git_cli_ns != null and r.ziggit_success and r.git_success) {
            const ziggit_time = @as(f64, @floatFromInt(r.ziggit_cli_ns.?));
            const git_time = @as(f64, @floatFromInt(r.git_cli_ns.?));
            const improvement = ((git_time - ziggit_time) / git_time) * 100.0;
            
            const direction = if (improvement > 0) "faster" else "slower";
            print("{s}: ziggit is {d:.1}% {s} than git CLI\n", .{
                r.operation, 
                @abs(improvement),
                direction
            });
        } else if (!r.ziggit_success and r.git_success) {
            print("{s}: ziggit not functional for this operation\n", .{r.operation});
        } else if (r.ziggit_success and !r.git_success) {
            print("{s}: git failed, ziggit succeeded\n", .{r.operation});
        }
    }
    
    print("\n=== BUN INTEGRATION NOTES ===\n", .{});
    print("The operations benchmarked here are core to bun's functionality:\n", .{});
    print("- repo_init: Used when creating new projects (bun create)\n", .{});
    print("- repo_status: Used for dependency hash verification\n", .{});
    print("- bun_workflow: Combined operations for package management\n", .{});
    print("\nFor bun to benefit from ziggit, these operations must be:\n", .{});
    print("1. Faster than git CLI\n", .{});
    print("2. Functionally equivalent\n", .{});
    print("3. Available via C API for embedding\n", .{});
    
    cleanupTestDir(test_base_dir);
    print("\nBenchmark completed!\n", .{});
}