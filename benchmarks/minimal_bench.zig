const std = @import("std");

fn runGitCommand(allocator: std.mem.Allocator, args: []const []const u8, cwd: ?[]const u8) !std.process.Child.RunResult {
    return try std.process.Child.run(.{
        .allocator = allocator,
        .argv = args,
        .cwd = cwd,
    });
}

fn cleanupTestDir(path: []const u8) void {
    std.fs.deleteTreeAbsolute(path) catch {};
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.log.info("=== Minimal Git CLI Benchmark ===", .{});
    
    const test_base_dir = "/tmp/minimal_bench";
    cleanupTestDir(test_base_dir);
    
    // Benchmark git init
    {
        const git_path = try std.fmt.allocPrint(allocator, "{s}_git", .{test_base_dir});
        defer allocator.free(git_path);
        defer cleanupTestDir(git_path);
        
        const start = std.time.nanoTimestamp();
        const result = runGitCommand(allocator, &.{ "git", "init", git_path }, null) catch {
            std.log.err("Failed to run git init", .{});
            return;
        };
        const end = std.time.nanoTimestamp();
        
        const success = result.term == .Exited and result.term.Exited == 0;
        const duration = @as(u64, @intCast(end - start));
        const duration_ms = @as(f64, @floatFromInt(duration)) / 1_000_000.0;
        
        std.log.info("git init: {s}, {d:.2}ms", .{ if (success) "SUCCESS" else "FAILED", duration_ms });
    }
    
    // Benchmark git status
    {
        const git_path = try std.fmt.allocPrint(allocator, "{s}_status", .{test_base_dir});
        defer allocator.free(git_path);
        defer cleanupTestDir(git_path);
        
        // First init a repo
        _ = runGitCommand(allocator, &.{ "git", "init", git_path }, null) catch return;
        
        const start = std.time.nanoTimestamp();
        const result = runGitCommand(allocator, &.{ "git", "-C", git_path, "status", "--porcelain" }, null) catch {
            std.log.err("Failed to run git status", .{});
            return;
        };
        const end = std.time.nanoTimestamp();
        
        const success = result.term == .Exited and result.term.Exited == 0;
        const duration = @as(u64, @intCast(end - start));
        const duration_ms = @as(f64, @floatFromInt(duration)) / 1_000_000.0;
        
        std.log.info("git status: {s}, {d:.2}ms", .{ if (success) "SUCCESS" else "FAILED", duration_ms });
    }
    
    // Test ziggit binary
    {
        const ziggit_path = try std.fmt.allocPrint(allocator, "{s}_ziggit", .{test_base_dir});
        defer allocator.free(ziggit_path);
        defer cleanupTestDir(ziggit_path);
        
        const start = std.time.nanoTimestamp();
        const result = runGitCommand(allocator, &.{ "./zig-out/bin/ziggit", "init", ziggit_path }, null) catch {
            std.log.err("Failed to run ziggit init", .{});
            return;
        };
        const end = std.time.nanoTimestamp();
        
        const success = result.term == .Exited and result.term.Exited == 0;
        const duration = @as(u64, @intCast(end - start));
        const duration_ms = @as(f64, @floatFromInt(duration)) / 1_000_000.0;
        
        std.log.info("ziggit init: {s}, {d:.2}ms", .{ if (success) "SUCCESS" else "FAILED", duration_ms });
    }
    
    cleanupTestDir(test_base_dir);
    std.log.info("Minimal benchmark completed!", .{});
}