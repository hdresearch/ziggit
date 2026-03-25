const std = @import("std");

pub const GitIgnore = struct {
    patterns: std.ArrayList([]u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) GitIgnore {
        return GitIgnore{
            .patterns = std.ArrayList([]u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *GitIgnore) void {
        for (self.patterns.items) |pattern| {
            self.allocator.free(pattern);
        }
        self.patterns.deinit();
    }

    pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8, platform_impl: anytype) !GitIgnore {
        var gitignore = GitIgnore.init(allocator);

        const content = platform_impl.fs.readFile(allocator, path) catch |err| switch (err) {
            error.FileNotFound => return gitignore, // No .gitignore file, return empty
            else => return err,
        };
        defer allocator.free(content);

        var lines = std.mem.split(u8, content, "\n");
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') {
                continue; // Skip empty lines and comments
            }
            
            const pattern = try allocator.dupe(u8, trimmed);
            try gitignore.patterns.append(pattern);
        }

        return gitignore;
    }

    pub fn isIgnored(self: GitIgnore, path: []const u8) bool {
        for (self.patterns.items) |pattern| {
            if (matchPattern(pattern, path)) {
                return true;
            }
        }
        return false;
    }

    // Simple pattern matching - just supports exact matches and * wildcards
    fn matchPattern(pattern: []const u8, path: []const u8) bool {
        if (std.mem.eql(u8, pattern, path)) {
            return true;
        }

        // Simple wildcard support: check if pattern contains * and matches
        if (std.mem.indexOf(u8, pattern, "*")) |star_pos| {
            const prefix = pattern[0..star_pos];
            const suffix = pattern[star_pos + 1..];
            
            if (path.len < prefix.len + suffix.len) {
                return false;
            }
            
            return std.mem.startsWith(u8, path, prefix) and 
                   std.mem.endsWith(u8, path, suffix);
        }

        return false;
    }
};