const std = @import("std");

/// Type of gitignore pattern
pub const PatternType = enum {
    ignore,      // Normal ignore pattern
    unignore,    // Negation pattern (starts with !)
    directory,   // Directory-only pattern (ends with /)
};

/// A parsed gitignore pattern
pub const GitignoreEntry = struct {
    pattern: []const u8,
    pattern_type: PatternType,
    is_absolute: bool,  // Pattern starts with /
    has_wildcard: bool, // Pattern contains * or ?
    
    pub fn init(raw_pattern: []const u8, allocator: std.mem.Allocator) !GitignoreEntry {
        var pattern = std.mem.trim(u8, raw_pattern, " \t\r");
        
        // Handle negation patterns
        const is_negation = pattern.len > 0 and pattern[0] == '!';
        if (is_negation) {
            pattern = pattern[1..];
        }
        
        // Handle absolute patterns
        const is_absolute = pattern.len > 0 and pattern[0] == '/';
        if (is_absolute) {
            pattern = pattern[1..];
        }
        
        // Handle directory patterns
        const is_directory = pattern.len > 0 and pattern[pattern.len - 1] == '/';
        if (is_directory) {
            pattern = pattern[0..pattern.len - 1];
        }
        
        // Check for wildcards
        const has_wildcard = std.mem.indexOf(u8, pattern, "*") != null or 
                           std.mem.indexOf(u8, pattern, "?") != null;
        
        return GitignoreEntry{
            .pattern = try allocator.dupe(u8, pattern),
            .pattern_type = if (is_negation) 
                .unignore 
            else if (is_directory) 
                .directory 
            else 
                .ignore,
            .is_absolute = is_absolute,
            .has_wildcard = has_wildcard,
        };
    }
    
    pub fn deinit(self: GitignoreEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.pattern);
    }
    
    /// Check if this pattern matches the given path
    pub fn matches(self: GitignoreEntry, path: []const u8, is_dir: bool) bool {
        // Directory-only patterns only match directories
        if (self.pattern_type == .directory and !is_dir) {
            return false;
        }
        
        if (self.is_absolute) {
            // Absolute pattern - match from root
            return self.matchesPattern(path);
        } else {
            // Relative pattern - match any component
            if (self.matchesPattern(path)) {
                return true;
            }
            
            // Try matching against each path component
            var parts = std.mem.split(u8, path, "/");
            while (parts.next()) |part| {
                if (self.matchesPattern(part)) {
                    return true;
                }
            }
            
            return false;
        }
    }
    
    fn matchesPattern(self: GitignoreEntry, text: []const u8) bool {
        if (self.has_wildcard) {
            return matchGlob(self.pattern, text);
        } else {
            return std.mem.eql(u8, self.pattern, text);
        }
    }
};

pub const GitignorePattern = struct {
    entries: std.ArrayList(GitignoreEntry),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) GitignorePattern {
        return GitignorePattern{
            .entries = std.ArrayList(GitignoreEntry).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *GitignorePattern) void {
        for (self.entries.items) |entry| {
            entry.deinit(self.allocator);
        }
        self.entries.deinit();
    }

    pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8, platform_impl: anytype) !GitignorePattern {
        var patterns = GitignorePattern.init(allocator);
        errdefer patterns.deinit();

        const content = platform_impl.fs.readFile(allocator, path) catch |err| switch (err) {
            error.FileNotFound => return patterns, // No .gitignore file, return empty
            else => return err,
        };
        defer allocator.free(content);

        try patterns.parseContent(content);
        return patterns;
    }
    
    pub fn parseContent(self: *GitignorePattern, content: []const u8) !void {
        var lines = std.mem.split(u8, content, "\n");
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            
            // Skip empty lines and comments
            if (trimmed.len == 0 or trimmed[0] == '#') {
                continue;
            }
            
            // Skip lines that are just whitespace after removing escapes
            if (std.mem.allEqual(u8, trimmed, ' ') or std.mem.allEqual(u8, trimmed, '\t')) {
                continue;
            }
            
            const entry = try GitignoreEntry.init(trimmed, self.allocator);
            try self.entries.append(entry);
        }
    }

    /// Check if a path should be ignored
    pub fn isIgnored(self: GitignorePattern, path: []const u8, is_dir: bool) bool {
        var result = false;
        
        // Process patterns in order - later patterns can override earlier ones
        for (self.entries.items) |entry| {
            if (entry.matches(path, is_dir)) {
                result = entry.pattern_type != .unignore;
            }
        }
        
        return result;
    }
    
    /// Add a pattern programmatically
    pub fn addPattern(self: *GitignorePattern, pattern: []const u8) !void {
        const entry = try GitignoreEntry.init(pattern, self.allocator);
        try self.entries.append(entry);
    }
    
    /// Get all patterns as strings (for debugging)
    pub fn getPatternStrings(self: GitignorePattern, allocator: std.mem.Allocator) ![][]const u8 {
        var patterns = try allocator.alloc([]const u8, self.entries.items.len);
        for (self.entries.items, 0..) |entry, i| {
            patterns[i] = entry.pattern;
        }
        return patterns;
    }
};

// Legacy alias for compatibility
pub const GitIgnore = GitignorePattern;

/// Load gitignore patterns from a repository
pub fn loadGitignore(repo_path: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) !GitignorePattern {
    var patterns = GitignorePattern.init(allocator);
    errdefer patterns.deinit();
    
    // Load global gitignore patterns (from .gitignore_global, etc.)
    // For now, just load the main .gitignore file
    
    const gitignore_path = try std.fmt.allocPrint(allocator, "{s}/.gitignore", .{repo_path});
    defer allocator.free(gitignore_path);
    
    const file_patterns = GitignorePattern.loadFromFile(allocator, gitignore_path, platform_impl) catch |err| switch (err) {
        error.FileNotFound => return patterns, // No .gitignore, return empty
        else => return err,
    };
    defer file_patterns.deinit();
    
    // Merge patterns
    for (file_patterns.entries.items) |entry| {
        const new_entry = try GitignoreEntry.init(entry.pattern, allocator);
        try patterns.entries.append(new_entry);
    }
    
    return patterns;
}

/// Match a glob pattern against text
fn matchGlob(pattern: []const u8, text: []const u8) bool {
    // Handle ** (matches zero or more directories)
    if (std.mem.indexOf(u8, pattern, "**")) |double_star_pos| {
        const prefix = pattern[0..double_star_pos];
        const suffix_start = if (double_star_pos + 2 < pattern.len and pattern[double_star_pos + 2] == '/') 
            double_star_pos + 3 else double_star_pos + 2;
        const suffix = if (suffix_start < pattern.len) pattern[suffix_start..] else "";
        
        // Check prefix
        if (prefix.len > 0 and !std.mem.startsWith(u8, text, prefix)) {
            return false;
        }
        
        // Check suffix
        if (suffix.len > 0 and !std.mem.endsWith(u8, text, suffix)) {
            return false;
        }
        
        // If we have both prefix and suffix, make sure they don't overlap
        if (prefix.len > 0 and suffix.len > 0 and prefix.len + suffix.len > text.len) {
            return false;
        }
        
        return true;
    }
    
    // Simple * and ? wildcard matching
    return matchSimpleGlob(pattern, text);
}

/// Match simple glob patterns with * and ?
fn matchSimpleGlob(pattern: []const u8, text: []const u8) bool {
    var p_idx: usize = 0;
    var t_idx: usize = 0;
    var star_idx: ?usize = null;
    var match_idx: usize = 0;
    
    while (t_idx < text.len) {
        if (p_idx < pattern.len and (pattern[p_idx] == '?' or pattern[p_idx] == text[t_idx])) {
            // Characters match or pattern has ?
            p_idx += 1;
            t_idx += 1;
        } else if (p_idx < pattern.len and pattern[p_idx] == '*') {
            // Found *, record position
            star_idx = p_idx;
            match_idx = t_idx;
            p_idx += 1;
        } else if (star_idx != null) {
            // No match, but we have a previous *, backtrack
            p_idx = star_idx.? + 1;
            match_idx += 1;
            t_idx = match_idx;
        } else {
            // No match and no * to backtrack
            return false;
        }
    }
    
    // Skip remaining * in pattern
    while (p_idx < pattern.len and pattern[p_idx] == '*') {
        p_idx += 1;
    }
    
    return p_idx == pattern.len;
}

/// Check if a file extension matches any pattern
pub fn matchesExtension(patterns: *GitignorePattern, path: []const u8, extension: []const u8) bool {
    if (std.mem.endsWith(u8, path, extension)) {
        return patterns.isIgnored(path, false);
    }
    
    // Also check for pattern like *.ext
    const ext_pattern = std.fmt.allocPrint(patterns.allocator, "*.{s}", .{extension}) catch return false;
    defer patterns.allocator.free(ext_pattern);
    
    for (patterns.entries.items) |entry| {
        if (std.mem.eql(u8, entry.pattern, ext_pattern)) {
            return entry.pattern_type != .unignore;
        }
    }
    
    return false;
}

/// Create default gitignore patterns for common project types
pub fn createDefaultPatterns(allocator: std.mem.Allocator, project_type: []const u8) !GitignorePattern {
    var patterns = GitignorePattern.init(allocator);
    errdefer patterns.deinit();
    
    // Common patterns for all projects
    try patterns.addPattern("*.tmp");
    try patterns.addPattern("*.log");
    try patterns.addPattern("*.swp");
    try patterns.addPattern("*.swo");
    try patterns.addPattern("*~");
    try patterns.addPattern(".DS_Store");
    try patterns.addPattern("Thumbs.db");
    
    if (std.mem.eql(u8, project_type, "zig")) {
        try patterns.addPattern("zig-cache/");
        try patterns.addPattern("zig-out/");
        try patterns.addPattern("*.o");
        try patterns.addPattern("*.so");
        try patterns.addPattern("*.dylib");
        try patterns.addPattern("*.dll");
    } else if (std.mem.eql(u8, project_type, "node")) {
        try patterns.addPattern("node_modules/");
        try patterns.addPattern("npm-debug.log*");
        try patterns.addPattern(".npm");
        try patterns.addPattern("dist/");
        try patterns.addPattern("build/");
    } else if (std.mem.eql(u8, project_type, "python")) {
        try patterns.addPattern("__pycache__/");
        try patterns.addPattern("*.pyc");
        try patterns.addPattern("*.pyo");
        try patterns.addPattern("*.pyd");
        try patterns.addPattern(".Python");
        try patterns.addPattern("venv/");
        try patterns.addPattern("env/");
        try patterns.addPattern("*.egg-info/");
    } else if (std.mem.eql(u8, project_type, "rust")) {
        try patterns.addPattern("target/");
        try patterns.addPattern("Cargo.lock");
        try patterns.addPattern("*.rs.bk");
    }
    
    return patterns;
}
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
            std.mem.indexOf(u8, path, actual_pattern) != null) {
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