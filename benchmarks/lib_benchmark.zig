const std = @import("std");
const ziggit = @import("ziggit");

// Benchmark results struct for comparison
const BenchmarkResult = struct {
    operation: []const u8,
    zig_api_ns: ?u64 = null,
    git_cli_ns: ?u64 = null,
    zig_success: bool = false,
    git_success: bool = false,
};

fn formatDuration(ns: u64) void {
    if (ns < 1_000) {
        std.debug.print("{d} ns", .{ns});
    } else if (ns < 1_000_000) {
        std.debug.print("{d:.1} μs", .{@as(f64, @floatFromInt(ns)) / 1_000.0});
    } else if (ns < 1_000_000_000) {
        std.debug.print("{d:.2} ms", .{@as(f64, @floatFromInt(ns)) / 1_000_000.0});
    } else {
        std.debug.print("{d:.3} s", .{@as(f64, @floatFromInt(ns)) / 1_000_000_000.0});
    }
}

fn runGitCommand(allocator: std.mem.Allocator, args: []const []const u8, cwd: ?[]const u8) !std.process.Child.RunResult {
    return try std.process.Child.run(.{
        .allocator = allocator,
        .argv = args,
        .cwd = cwd,
    });
}

// Setup test repository using the Zig API
fn setupTestRepoZigAPI(allocator: std.mem.Allocator, path: []const u8) !ziggit.Repository {
    // Clean up any existing directory
    std.fs.deleteTreeAbsolute(path) catch {};
    
    // Initialize repository using Zig API
    var repo = try ziggit.Repository.init(allocator, path);
    
    // Create 50 files
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const filename = try std.fmt.allocPrint(allocator, "file{d:03}.txt", .{i});
        defer allocator.free(filename);
        
        const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, filename });
        defer allocator.free(file_path);
        
        const content = try std.fmt.allocPrint(allocator, "Content for file {d}\nLine 2\nLine 3\nSome more data to make it realistic.\n", .{i});
        defer allocator.free(content);
        
        const file = try std.fs.createFileAbsolute(file_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(content);
        
        // Add file to git
        try repo.add(filename);
    }
    
    // Create initial commit
    _ = try repo.commit("Initial commit with 50 files", "benchmark", "benchmark@example.com");
    
    // Create a tag
    try repo.createTag("v1.0.0", "Initial version");
    
    return repo;
}

// Setup test repository with git CLI for fallback testing
fn setupTestRepoGitCLI(allocator: std.mem.Allocator, path: []const u8) !void {
    // Clean up any existing directory
    std.fs.deleteTreeAbsolute(path) catch {};
    try std.fs.makeDirAbsolute(path);
    
    // Initialize git repo
    {
        const result = try runGitCommand(allocator, &.{"git", "init"}, path);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    {
        const result = try runGitCommand(allocator, &.{"git", "config", "user.name", "Benchmark"}, path);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    {
        const result = try runGitCommand(allocator, &.{"git", "config", "user.email", "bench@test.com"}, path);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    
    // Create 50 files
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const filename = try std.fmt.allocPrint(allocator, "{s}/file{d:03}.txt", .{path, i});
        defer allocator.free(filename);
        const content = try std.fmt.allocPrint(allocator, "Content for file {d}\nLine 2\nLine 3\nSome more data to make it realistic.\n", .{i});
        defer allocator.free(content);
        const file = try std.fs.createFileAbsolute(filename, .{});
        defer file.close();
        try file.writeAll(content);
    }
    
    // Add files and create commits
    {
        const result = try runGitCommand(allocator, &.{"git", "add", "."}, path);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    {
        const result = try runGitCommand(allocator, &.{"git", "commit", "-m", "Initial commit with 50 files"}, path);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    
    // Create a tag
    {
        const result = try runGitCommand(allocator, &.{"git", "tag", "v1.0.0"}, path);
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
}

// Benchmark revParseHead: Zig API vs git CLI
fn benchmarkRevParseHead(allocator: std.mem.Allocator, repo: ?*const ziggit.Repository, repo_path: []const u8, iterations: usize) !BenchmarkResult {
    var result = BenchmarkResult{ .operation = "revParseHead" };
    
    // Benchmark Zig API if available
    if (repo != null) {
        var total_time: u64 = 0;
        var success_count: usize = 0;
        
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            const start = std.time.nanoTimestamp();
            const head_hash = repo.?.revParseHead() catch {
                continue;
            };
            const end = std.time.nanoTimestamp();
            
            // Verify we got a valid hash
            if (head_hash.len == 40) {
                total_time += @as(u64, @intCast(end - start));
                success_count += 1;
            }
        }
        
        if (success_count > 0) {
            result.zig_api_ns = total_time / success_count;
            result.zig_success = true;
        }
    }
    
    // Benchmark git CLI
    {
        var total_time: u64 = 0;
        var success_count: usize = 0;
        
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            const start = std.time.nanoTimestamp();
            const git_result = runGitCommand(allocator, &.{ "git", "-C", repo_path, "rev-parse", "HEAD" }, null) catch {
                continue;
            };
            const end = std.time.nanoTimestamp();
            
            if (git_result.term == .Exited and git_result.term.Exited == 0) {
                total_time += @as(u64, @intCast(end - start));
                success_count += 1;
            }
            
            allocator.free(git_result.stdout);
            allocator.free(git_result.stderr);
        }
        
        if (success_count > 0) {
            result.git_cli_ns = total_time / success_count;
            result.git_success = true;
        }
    }
    
    return result;
}

// Benchmark statusPorcelain: Zig API vs git CLI
fn benchmarkStatusPorcelain(allocator: std.mem.Allocator, repo: ?*const ziggit.Repository, repo_path: []const u8, iterations: usize) !BenchmarkResult {
    var result = BenchmarkResult{ .operation = "statusPorcelain" };
    
    // Benchmark Zig API if available
    if (repo != null) {
        var total_time: u64 = 0;
        var success_count: usize = 0;
        
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            const start = std.time.nanoTimestamp();
            const status = repo.?.statusPorcelain(allocator) catch {
                continue;
            };
            const end = std.time.nanoTimestamp();
            
            allocator.free(status);
            total_time += @as(u64, @intCast(end - start));
            success_count += 1;
        }
        
        if (success_count > 0) {
            result.zig_api_ns = total_time / success_count;
            result.zig_success = true;
        }
    }
    
    // Benchmark git CLI
    {
        var total_time: u64 = 0;
        var success_count: usize = 0;
        
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            const start = std.time.nanoTimestamp();
            const git_result = runGitCommand(allocator, &.{ "git", "-C", repo_path, "status", "--porcelain" }, null) catch {
                continue;
            };
            const end = std.time.nanoTimestamp();
            
            if (git_result.term == .Exited and git_result.term.Exited == 0) {
                total_time += @as(u64, @intCast(end - start));
                success_count += 1;
            }
            
            allocator.free(git_result.stdout);
            allocator.free(git_result.stderr);
        }
        
        if (success_count > 0) {
            result.git_cli_ns = total_time / success_count;
            result.git_success = true;
        }
    }
    
    return result;
}

// Benchmark describeTags: Zig API vs git CLI
fn benchmarkDescribeTags(allocator: std.mem.Allocator, repo: ?*const ziggit.Repository, repo_path: []const u8, iterations: usize) !BenchmarkResult {
    var result = BenchmarkResult{ .operation = "describeTags" };
    
    // Benchmark Zig API if available
    if (repo != null) {
        var total_time: u64 = 0;
        var success_count: usize = 0;
        
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            const start = std.time.nanoTimestamp();
            const tags = repo.?.describeTags(allocator) catch {
                continue;
            };
            const end = std.time.nanoTimestamp();
            
            allocator.free(tags);
            total_time += @as(u64, @intCast(end - start));
            success_count += 1;
        }
        
        if (success_count > 0) {
            result.zig_api_ns = total_time / success_count;
            result.zig_success = true;
        }
    }
    
    // Benchmark git CLI
    {
        var total_time: u64 = 0;
        var success_count: usize = 0;
        
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            const start = std.time.nanoTimestamp();
            const git_result = runGitCommand(allocator, &.{ "git", "-C", repo_path, "describe", "--tags", "--abbrev=0" }, null) catch {
                continue;
            };
            const end = std.time.nanoTimestamp();
            
            if (git_result.term == .Exited and git_result.term.Exited == 0) {
                total_time += @as(u64, @intCast(end - start));
                success_count += 1;
            }
            
            allocator.free(git_result.stdout);
            allocator.free(git_result.stderr);
        }
        
        if (success_count > 0) {
            result.git_cli_ns = total_time / success_count;
            result.git_success = true;
        }
    }
    
    return result;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.debug.print("=== Ziggit Library API Performance Benchmark ===\n", .{});
    std.debug.print("Comparing Zig API vs Git CLI performance\n\n", .{});
    
    const zig_api_test_dir = "/tmp/ziggit_lib_zig_api";
    const git_cli_test_dir = "/tmp/ziggit_lib_git_cli";
    
    // Try to setup test repository with Zig API
    var zig_repo_opt: ?ziggit.Repository = null;
    var zig_api_available = false;
    
    zig_repo_opt = setupTestRepoZigAPI(allocator, zig_api_test_dir) catch |err| blk: {
        std.debug.print("Note: Zig API setup failed ({}), falling back to Git CLI comparison\n", .{err});
        break :blk null;
    };
    
    if (zig_repo_opt != null) {
        zig_api_available = true;
        std.debug.print("Repository created successfully with Zig API.\n\n", .{});
    }
    
    // Setup test repository with git CLI for baseline
    try setupTestRepoGitCLI(allocator, git_cli_test_dir);
    defer std.fs.deleteTreeAbsolute(git_cli_test_dir) catch {};
    
    const iterations: u32 = if (zig_api_available) 500 else 100;
    std.debug.print("Running {d} iterations of each operation...\n\n", .{iterations});
    
    // Run benchmarks
    const BENCHMARK_COUNT = 3;
    var results: [BENCHMARK_COUNT]BenchmarkResult = undefined;
    
    const repo_ref = if (zig_repo_opt != null) &zig_repo_opt.? else null;
    const test_path = if (zig_api_available) zig_api_test_dir else git_cli_test_dir;
    
    results[0] = try benchmarkRevParseHead(allocator, repo_ref, test_path, iterations);
    results[1] = try benchmarkStatusPorcelain(allocator, repo_ref, test_path, iterations);
    results[2] = try benchmarkDescribeTags(allocator, repo_ref, test_path, iterations);
    
    // Print results table
    std.debug.print("=== RESULTS ===\n", .{});
    if (zig_api_available) {
        std.debug.print("Operation         | Zig API     | Git CLI     | Speedup\n", .{});
        std.debug.print("------------------|-------------|-------------|--------\n", .{});
    } else {
        std.debug.print("Operation         | Git CLI     | Notes\n", .{});
        std.debug.print("------------------|-------------|---------------------------\n", .{});
    }
    
    for (results) |result| {
        std.debug.print("{s:<17} | ", .{result.operation});
        
        if (zig_api_available) {
            if (result.zig_success and result.zig_api_ns != null) {
                formatDuration(result.zig_api_ns.?);
                std.debug.print(" | ", .{});
            } else {
                std.debug.print("    FAILED | ", .{});
            }
            
            if (result.git_success and result.git_cli_ns != null) {
                formatDuration(result.git_cli_ns.?);
                std.debug.print(" | ", .{});
            } else {
                std.debug.print("    FAILED | ", .{});
            }
            
            if (result.zig_success and result.git_success and 
                result.zig_api_ns != null and result.git_cli_ns != null) {
                const speedup = @as(f64, @floatFromInt(result.git_cli_ns.?)) / @as(f64, @floatFromInt(result.zig_api_ns.?));
                std.debug.print("{d:.1}x", .{speedup});
            } else {
                std.debug.print("  N/A", .{});
            }
        } else {
            if (result.git_success and result.git_cli_ns != null) {
                formatDuration(result.git_cli_ns.?);
                std.debug.print(" | Zig API unavailable", .{});
            } else {
                std.debug.print("    FAILED | Git CLI failed", .{});
            }
        }
        
        std.debug.print("\n", .{});
    }
    
    // Analysis
    if (zig_api_available) {
        std.debug.print("\n=== ANALYSIS ===\n", .{});
        std.debug.print("Direct Zig API vs Git CLI performance comparison:\n\n", .{});
        
        var total_zig_time: u64 = 0;
        var total_git_time: u64 = 0;
        var valid_comparisons: usize = 0;
        
        for (results) |result| {
            if (result.zig_success and result.git_success and 
                result.zig_api_ns != null and result.git_cli_ns != null) {
                total_zig_time += result.zig_api_ns.?;
                total_git_time += result.git_cli_ns.?;
                valid_comparisons += 1;
                
                const zig_time = @as(f64, @floatFromInt(result.zig_api_ns.?));
                const git_time = @as(f64, @floatFromInt(result.git_cli_ns.?));
                const improvement = ((git_time - zig_time) / git_time) * 100.0;
                
                std.debug.print("• {s}: {d:.1}% faster (eliminates process spawn overhead)\n", .{
                    result.operation, improvement,
                });
            } else if (result.zig_success and !result.git_success) {
                std.debug.print("• {s}: Zig API succeeded, Git CLI failed\n", .{result.operation});
            } else if (!result.zig_success and result.git_success) {
                std.debug.print("• {s}: Git CLI succeeded, Zig API failed\n", .{result.operation});
            } else {
                std.debug.print("• {s}: Both failed\n", .{result.operation});
            }
        }
        
        if (valid_comparisons > 0) {
            const overall_speedup = @as(f64, @floatFromInt(total_git_time)) / @as(f64, @floatFromInt(total_zig_time));
            std.debug.print("\nOVERALL: Zig API is {d:.1}x faster on average\n", .{overall_speedup});
        }
        
        std.debug.print("\n=== WHY THIS MATTERS FOR BUN ===\n", .{});
        std.debug.print("1. NO PROCESS SPAWNING: Direct function calls eliminate fork/exec overhead\n", .{});
        std.debug.print("2. NO CLI PARSING: Data flows directly between Zig functions\n", .{});
        std.debug.print("3. NO C FFI: Pure Zig-to-Zig calls (vs libgit2's C interface)\n", .{});
        std.debug.print("4. NO GIT DEPENDENCY: Bun doesn't need git binary installed\n", .{});
        std.debug.print("5. UNIFIED OPTIMIZATION: Zig compiler optimizes bun+ziggit as one unit\n", .{});
    } else {
        std.debug.print("\n=== FALLBACK MODE ===\n", .{});
        std.debug.print("Zig API is not available - this demonstrates baseline Git CLI performance.\n", .{});
        std.debug.print("When Zig API is working, expect significant performance improvements due to:\n", .{});
        std.debug.print("• Elimination of process spawn overhead\n", .{});
        std.debug.print("• Direct memory access to git structures\n", .{});
        std.debug.print("• No subprocess communication latency\n", .{});
    }
    
    // Cleanup
    if (zig_repo_opt != null) {
        zig_repo_opt.?.close();
        std.fs.deleteTreeAbsolute(zig_api_test_dir) catch {};
    }
    
    std.debug.print("\nLibrary benchmark completed!\n", .{});
}