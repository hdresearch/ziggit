const std = @import("std");
const time = std.time;
const process = std.process;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("=== Final Git CLI Benchmark ===", .{});
    std.log.info("Real measurements of git operations that bun uses most:", .{});
    std.log.info("", .{});
    
    // Create a realistic test repository
    const test_repo_dir = "final_bench_repo";
    const abs_repo_path = try createRealisticRepo(allocator, test_repo_dir);
    defer allocator.free(abs_repo_path);
    defer std.fs.cwd().deleteTree(test_repo_dir) catch {};
    
    std.log.info("Running git CLI benchmarks (200 iterations each)...", .{});
    
    // Benchmark the critical operations for bun
    const status_avg = try benchmarkOperation(
        allocator, 
        &[_][]const u8{ "git", "-C", test_repo_dir, "status", "--porcelain" },
        200,
        "git status --porcelain"
    );
    
    const revparse_avg = try benchmarkOperation(
        allocator,
        &[_][]const u8{ "git", "-C", test_repo_dir, "rev-parse", "HEAD" },
        200, 
        "git rev-parse HEAD"
    );
    
    const describe_avg = try benchmarkOperation(
        allocator,
        &[_][]const u8{ "git", "-C", test_repo_dir, "describe", "--tags", "--abbrev=0" },
        200,
        "git describe --tags"
    );
    
    const ls_remote_avg = try benchmarkOperation(
        allocator,
        &[_][]const u8{ "git", "-C", test_repo_dir, "ls-remote", "--heads", "origin" },
        50, // Fewer iterations for network operation
        "git ls-remote --heads"
    );
    
    // Print results table
    std.log.info("", .{});
    std.log.info("╭─────────────────────────────────────────────────╮", .{});
    std.log.info("│        GIT CLI PERFORMANCE (Baseline)          │", .{});
    std.log.info("├─────────────────────────────────────────────────┤", .{});
    std.log.info("│ Operation           │ Avg (ms) │ Iter │ Note     │", .{});
    std.log.info("├─────────────────────────────────────────────────┤", .{});
    std.log.info("│ status --porcelain  │ {d:>8.2} │ {d:>4} │ Critical │", .{status_avg, 200});
    std.log.info("│ rev-parse HEAD      │ {d:>8.2} │ {d:>4} │ Critical │", .{revparse_avg, 200});
    std.log.info("│ describe --tags     │ {d:>8.2} │ {d:>4} │ Frequent │", .{describe_avg, 200});
    std.log.info("│ ls-remote --heads   │ {d:>8.2} │ {d:>4} │ Network  │", .{ls_remote_avg, 50});
    std.log.info("╰─────────────────────────────────────────────────╯", .{});
    
    const critical_total = status_avg + revparse_avg;
    const all_total = status_avg + revparse_avg + describe_avg;
    
    std.log.info("", .{});
    std.log.info("Performance Analysis:", .{});
    std.log.info("  • Critical operations (status + rev-parse): {d:.2}ms", .{critical_total});
    std.log.info("  • All local operations: {d:.2}ms", .{all_total});
    std.log.info("", .{});
    std.log.info("Bun Usage Patterns:", .{});
    std.log.info("  • During package resolution: ~100-500 operations", .{});
    std.log.info("  • Mostly status checks and HEAD resolution", .{});
    std.log.info("", .{});
    std.log.info("Time estimates for typical bun install:", .{});
    std.log.info("  • 100 critical operations: {d:.0}ms ({d:.1}s)", .{critical_total * 100, critical_total * 100 / 1000});
    std.log.info("  • 200 all operations: {d:.0}ms ({d:.1}s)", .{all_total * 200, all_total * 200 / 1000});
    std.log.info("", .{});
    std.log.info("Target for ziggit library:", .{});
    std.log.info("  • Should be 3-10x faster (eliminate subprocess overhead)", .{});
    std.log.info("  • Target: <0.3ms per operation for clean repos", .{});
    std.log.info("  • Potential savings: {d:.0}-{d:.0}ms per 100 operations", .{critical_total * 70, critical_total * 90});
}

fn createRealisticRepo(allocator: std.mem.Allocator, repo_dir: []const u8) ![]u8 {
    // Clean up any existing test repo
    std.fs.cwd().deleteTree(repo_dir) catch {};
    
    // Create directory
    try std.fs.cwd().makeDir(repo_dir);
    
    // Get absolute path
    var cwd_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const original_cwd = try std.process.getCwd(&cwd_buf);
    const abs_repo_path = try std.fs.path.resolve(allocator, &[_][]const u8{ original_cwd, repo_dir });
    
    // Change to repo directory for git operations
    try std.posix.chdir(abs_repo_path);
    defer std.posix.chdir(original_cwd) catch {};
    
    // Initialize git repository
    _ = try runCommand(allocator, &[_][]const u8{ "git", "init", "-q" });
    _ = try runCommand(allocator, &[_][]const u8{ "git", "config", "user.name", "Benchmark User" });
    _ = try runCommand(allocator, &[_][]const u8{ "git", "config", "user.email", "bench@ziggit.dev" });
    
    // Create realistic project structure (like a typical bun project)
    try createProjectStructure();
    
    // Add and commit all files
    _ = try runCommand(allocator, &[_][]const u8{ "git", "add", "." });
    _ = try runCommand(allocator, &[_][]const u8{ "git", "commit", "-q", "-m", "feat: initial project setup" });
    
    // Create version tags (bun checks these frequently)
    _ = try runCommand(allocator, &[_][]const u8{ "git", "tag", "v0.1.0" });
    
    // Make some realistic changes
    try simulateProjectChanges();
    
    // Create more commits and tags
    _ = try runCommand(allocator, &[_][]const u8{ "git", "add", "-u" }); // Only modified files  
    _ = try runCommand(allocator, &[_][]const u8{ "git", "commit", "-q", "-m", "fix: update dependencies" });
    _ = try runCommand(allocator, &[_][]const u8{ "git", "tag", "v0.1.1" });
    
    // Create some more untracked and modified files (realistic working state)
    try std.fs.cwd().writeFile(.{ .sub_path = "temp-debug.log", .data = "Debug information\n" });
    try std.fs.cwd().writeFile(.{ .sub_path = ".env.local", .data = "API_KEY=test123\n" });
    
    // Modify an existing file
    try std.fs.cwd().writeFile(.{ .sub_path = "package.json", .data = 
        \\{
        \\  "name": "benchmark-project",
        \\  "version": "0.1.1",
        \\  "type": "module",
        \\  "dependencies": {
        \\    "react": "^18.2.0",
        \\    "typescript": "^5.0.0",
        \\    "zod": "^3.22.0"
        \\  },
        \\  "devDependencies": {
        \\    "@types/node": "^20.0.0",
        \\    "bun-types": "latest"
        \\  }
        \\}
        \\
    });
    
    std.log.info("Created realistic test repository at: {s}", .{abs_repo_path});
    return abs_repo_path;
}

fn createProjectStructure() !void {
    // Create package.json
    try std.fs.cwd().writeFile(.{ .sub_path = "package.json", .data = 
        \\{
        \\  "name": "benchmark-project",
        \\  "version": "0.1.0",
        \\  "type": "module",
        \\  "main": "src/index.ts",
        \\  "scripts": {
        \\    "dev": "bun run src/index.ts",
        \\    "build": "bun build src/index.ts --outdir dist",
        \\    "test": "bun test"
        \\  },
        \\  "dependencies": {
        \\    "react": "^18.2.0",
        \\    "typescript": "^5.0.0"
        \\  }
        \\}
        \\
    });
    
    // Create src directory and files
    try std.fs.cwd().makeDir("src");
    try std.fs.cwd().writeFile(.{ .sub_path = "src/index.ts", .data = 
        \\import { createServer } from './server';
        \\import { logger } from './utils/logger';
        \\
        \\logger.info('Starting application...');
        \\const server = createServer();
        \\server.listen(3000);
        \\
    });
    
    try std.fs.cwd().writeFile(.{ .sub_path = "src/server.ts", .data = 
        \\export function createServer() {
        \\  return {
        \\    listen(port: number) {
        \\      console.log(`Server listening on port ${port}`);
        \\    }
        \\  };
        \\}
        \\
    });
    
    // Create utils directory
    try std.fs.cwd().makeDir("src/utils");
    try std.fs.cwd().writeFile(.{ .sub_path = "src/utils/logger.ts", .data = 
        \\export const logger = {
        \\  info: (msg: string) => console.log(`[INFO] ${msg}`),
        \\  error: (msg: string) => console.error(`[ERROR] ${msg}`)
        \\};
        \\
    });
    
    // Create config files
    try std.fs.cwd().writeFile(.{ .sub_path = "tsconfig.json", .data = 
        \\{
        \\  "compilerOptions": {
        \\    "target": "ES2022",
        \\    "module": "ESNext",
        \\    "moduleResolution": "node",
        \\    "strict": true,
        \\    "esModuleInterop": true,
        \\    "skipLibCheck": true,
        \\    "forceConsistentCasingInFileNames": true
        \\  }
        \\}
        \\
    });
    
    try std.fs.cwd().writeFile(.{ .sub_path = "README.md", .data = 
        \\# Benchmark Project
        \\
        \\A test project for benchmarking git operations.
        \\
        \\## Setup
        \\
        \\```bash
        \\bun install
        \\bun run dev
        \\```
        \\
    });
    
    // Create .gitignore
    try std.fs.cwd().writeFile(.{ .sub_path = ".gitignore", .data = 
        \\node_modules/
        \\dist/
        \\*.log
        \\.env.local
        \\.DS_Store
        \\
    });
}

fn simulateProjectChanges() !void {
    // Update version in package.json
    try std.fs.cwd().writeFile(.{ .sub_path = "package.json", .data = 
        \\{
        \\  "name": "benchmark-project",
        \\  "version": "0.1.1",
        \\  "type": "module",
        \\  "main": "src/index.ts",
        \\  "scripts": {
        \\    "dev": "bun run src/index.ts",
        \\    "build": "bun build src/index.ts --outdir dist",
        \\    "test": "bun test"
        \\  },
        \\  "dependencies": {
        \\    "react": "^18.2.0",
        \\    "typescript": "^5.0.0"
        \\  }
        \\}
        \\
    });
    
    // Update server.ts
    try std.fs.cwd().writeFile(.{ .sub_path = "src/server.ts", .data = 
        \\export function createServer() {
        \\  return {
        \\    listen(port: number) {
        \\      console.log(`🚀 Server ready on port ${port}`);
        \\    }
        \\  };
        \\}
        \\
    });
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
        std.log.warn("Command failed: {s}", .{argv[0]});
        if (stderr.len > 0) std.log.warn("Stderr: {s}", .{stderr});
        // Don't return error, just return empty result for failed commands
    }
    
    return allocator.dupe(u8, stdout);
}

fn benchmarkOperation(allocator: std.mem.Allocator, argv: []const []const u8, iterations: usize, name: []const u8) !f64 {
    std.log.info("  Benchmarking {s}...", .{name});
    
    var total_ns: u64 = 0;
    var successful: usize = 0;
    
    for (0..iterations) |_| {
        const start = time.nanoTimestamp();
        
        const result = runCommand(allocator, argv) catch {
            const elapsed = @as(u64, @intCast(time.nanoTimestamp() - start));
            total_ns += elapsed;
            continue;
        };
        allocator.free(result);
        
        const elapsed = @as(u64, @intCast(time.nanoTimestamp() - start));
        total_ns += elapsed;
        successful += 1;
    }
    
    const avg_ns = total_ns / iterations;
    const avg_ms = @as(f64, @floatFromInt(avg_ns)) / 1_000_000.0;
    
    if (successful < iterations) {
        std.log.info("    ({d}/{d} operations successful)", .{successful, iterations});
    }
    
    return avg_ms;
}