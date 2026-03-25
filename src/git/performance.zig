const std = @import("std");

// Performance optimizations for ziggit operations

pub const GitCache = struct {
    git_dir: ?[]const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) GitCache {
        return GitCache{
            .git_dir = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *GitCache) void {
        if (self.git_dir) |path| {
            self.allocator.free(path);
        }
    }

    pub fn getGitDir(self: *GitCache, platform_impl: anytype) ![]const u8 {
        if (self.git_dir) |path| {
            return path;
        }

        // This would implement a cached git directory lookup
        // For now, just return null to fall back to normal lookup
        return error.CacheEmpty;
    }

    pub fn setGitDir(self: *GitCache, path: []const u8) !void {
        if (self.git_dir) |old_path| {
            self.allocator.free(old_path);
        }
        self.git_dir = try self.allocator.dupe(u8, path);
    }
};

// Performance metrics and benchmarking support
pub const PerfMetrics = struct {
    command_start_time: i64,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) PerfMetrics {
        return PerfMetrics{
            .command_start_time = std.time.microTimestamp(),
            .allocator = allocator,
        };
    }

    pub fn recordCommandTime(self: PerfMetrics, command_name: []const u8) void {
        const end_time = std.time.microTimestamp();
        const duration_us = end_time - self.command_start_time;
        
        // In debug builds, print timing information
        if (@import("builtin").mode == .Debug) {
            std.debug.print("ziggit {s}: {d}μs\n", .{ command_name, duration_us });
        }
    }
};