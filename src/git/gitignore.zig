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

    /// Enhanced pattern matching with gitignore semantics
    fn matchPattern(pattern: []const u8, path: []const u8) bool {
        // Handle negation patterns (starting with !)
        const is_negation = pattern.len > 0 and pattern[0] == '!';
        const actual_pattern = if (is_negation) pattern[1..] else pattern;
        
        // Exact match
        if (std.mem.eql(u8, actual_pattern, path)) {
            return !is_negation;
        }
        
        // Directory pattern (ending with /)
        if (actual_pattern.len > 0 and actual_pattern[actual_pattern.len - 1] == '/') {
            const dir_pattern = actual_pattern[0..actual_pattern.len - 1];
            if (std.mem.startsWith(u8, path, dir_pattern)) {
                const match_result = path.len == dir_pattern.len or path[dir_pattern.len] == '/';
                return if (is_negation) !match_result else match_result;
            }
        }
        
        // Path starts with pattern/ (directory matching)
        if (std.mem.endsWith(u8, path, actual_pattern) or 
            std.mem.indexOf(u8, path, actual_pattern)) |_| {
            return !is_negation;
        }
        
        // Wildcard support
        if (std.mem.indexOf(u8, actual_pattern, "*")) |_| {
            const match_result = matchWildcard(actual_pattern, path);
            return if (is_negation) !match_result else match_result;
        }

        return false;
    }
    
    /// Match wildcard patterns (* and **)
    fn matchWildcard(pattern: []const u8, path: []const u8) bool {
        // Handle ** (matches zero or more directories)
        if (std.mem.indexOf(u8, pattern, "**")) |double_star_pos| {
            const prefix = pattern[0..double_star_pos];
            const suffix_start = if (double_star_pos + 2 < pattern.len and pattern[double_star_pos + 2] == '/') 
                double_star_pos + 3 else double_star_pos + 2;
            const suffix = pattern[suffix_start..];
            
            if (prefix.len > 0 and !std.mem.startsWith(u8, path, prefix)) {
                return false;
            }
            if (suffix.len > 0 and !std.mem.endsWith(u8, path, suffix)) {
                return false;
            }
            return true;
        }
        
        // Simple * wildcard matching
        return matchSimpleWildcard(pattern, path);
    }
    
    /// Match simple * wildcard patterns
    fn matchSimpleWildcard(pattern: []const u8, text: []const u8) bool {
        var p_idx: usize = 0;
        var t_idx: usize = 0;
        var star_idx: ?usize = null;
        var match: usize = 0;
        
        while (t_idx < text.len) {
            if (p_idx < pattern.len and (pattern[p_idx] == '?' or pattern[p_idx] == text[t_idx])) {
                p_idx += 1;
                t_idx += 1;
            } else if (p_idx < pattern.len and pattern[p_idx] == '*') {
                star_idx = p_idx;
                match = t_idx;
                p_idx += 1;
            } else if (star_idx) |star| {
                p_idx = star + 1;
                match += 1;
                t_idx = match;
            } else {
                return false;
            }
        }
        
        // Skip remaining * in pattern
        while (p_idx < pattern.len and pattern[p_idx] == '*') {
            p_idx += 1;
        }
        
        return p_idx == pattern.len;
    }
};

/// Load gitignore patterns from multiple sources (global, repo-level, etc.)
pub fn loadGitIgnore(git_dir: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) !GitIgnore {
    var gitignore = GitIgnore.init(allocator);
    
    // Load global gitignore (if it exists)
    const home_dir = std.posix.getenv("HOME") orelse "/tmp";
    const global_ignore_path = try std.fmt.allocPrint(allocator, "{s}/.gitignore_global", .{home_dir});
    defer allocator.free(global_ignore_path);
    
    const global_ignore = GitIgnore.loadFromFile(allocator, global_ignore_path, platform_impl) catch GitIgnore.init(allocator);
    defer global_ignore.deinit();
    
    // Copy global patterns to main gitignore
    for (global_ignore.patterns.items) |pattern| {
        try gitignore.patterns.append(try allocator.dupe(u8, pattern));
    }
    
    // Load repository .gitignore
    const repo_dir = std.fs.path.dirname(git_dir) orelse ".";
    const local_ignore_path = try std.fmt.allocPrint(allocator, "{s}/.gitignore", .{repo_dir});
    defer allocator.free(local_ignore_path);
    
    const local_ignore = GitIgnore.loadFromFile(allocator, local_ignore_path, platform_impl) catch GitIgnore.init(allocator);
    defer local_ignore.deinit();
    
    // Copy local patterns to main gitignore  
    for (local_ignore.patterns.items) |pattern| {
        try gitignore.patterns.append(try allocator.dupe(u8, pattern));
    }
    
    return gitignore;
}

test "gitignore pattern matching" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var gitignore = GitIgnore.init(allocator);
    defer gitignore.deinit();
    
    // Add test patterns
    try gitignore.patterns.append(try allocator.dupe(u8, "*.log"));
    try gitignore.patterns.append(try allocator.dupe(u8, "node_modules/"));
    try gitignore.patterns.append(try allocator.dupe(u8, "temp*"));
    try gitignore.patterns.append(try allocator.dupe(u8, "**/*.tmp"));
    
    // Test wildcard matching
    try testing.expect(gitignore.isIgnored("error.log"));
    try testing.expect(gitignore.isIgnored("debug.log"));
    try testing.expect(!gitignore.isIgnored("error.txt"));
    
    // Test directory matching
    try testing.expect(gitignore.isIgnored("node_modules/package.json"));
    try testing.expect(!gitignore.isIgnored("my_modules/file.js"));
    
    // Test prefix matching
    try testing.expect(gitignore.isIgnored("temp123"));
    try testing.expect(gitignore.isIgnored("temporary"));
    try testing.expect(!gitignore.isIgnored("atemporary"));
    
    // Test recursive directory matching  
    try testing.expect(gitignore.isIgnored("src/test.tmp"));
    try testing.expect(gitignore.isIgnored("deep/nested/dir/file.tmp"));
}

test "gitignore negation patterns" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var gitignore = GitIgnore.init(allocator);
    defer gitignore.deinit();
    
    // Add patterns with negation
    try gitignore.patterns.append(try allocator.dupe(u8, "*.log"));
    try gitignore.patterns.append(try allocator.dupe(u8, "!important.log"));
    
    // Normal log files should be ignored
    try testing.expect(gitignore.isIgnored("error.log"));
    try testing.expect(gitignore.isIgnored("debug.log"));
    
    // But important.log should NOT be ignored due to negation
    try testing.expect(!gitignore.isIgnored("important.log"));
}