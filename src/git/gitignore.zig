const std = @import("std");

/// Type of gitignore pattern
pub const PatternType = enum {
    ignore, // Normal ignore pattern
    unignore, // Negation pattern (starts with !)
};

/// Result of a gitignore match
pub const MatchResult = struct {
    matched: bool,
    source: []const u8, // source file (e.g., ".gitignore")
    line_number: usize, // 1-based line number
    pattern: []const u8, // the original pattern text
    is_negated: bool,
};

/// A parsed gitignore pattern
pub const GitignoreEntry = struct {
    pattern: []const u8,
    original_pattern: []const u8, // original pattern as written in file
    pattern_type: PatternType,
    is_absolute: bool, // Pattern starts with /
    dir_only: bool, // Pattern ends with /
    line_number: usize, // 1-based line number in source file
    source_file: []const u8, // source file path
    allocator: std.mem.Allocator,

    pub fn init(raw_pattern: []const u8, allocator: std.mem.Allocator) !GitignoreEntry {
        return initWithSource(raw_pattern, "", 0, allocator);
    }

    pub fn initWithSource(raw_pattern: []const u8, source: []const u8, line_num: usize, allocator: std.mem.Allocator) !GitignoreEntry {
        var pat = std.mem.trim(u8, raw_pattern, " \t\r");
        const orig = try allocator.dupe(u8, pat);

        var ptype: PatternType = .ignore;
        if (pat.len > 0 and pat[0] == '!') {
            ptype = .unignore;
            pat = pat[1..];
        }

        var is_abs = false;
        if (pat.len > 0 and pat[0] == '/') {
            is_abs = true;
            pat = pat[1..];
        }

        var dir_only = false;
        if (pat.len > 0 and pat[pat.len - 1] == '/') {
            dir_only = true;
            pat = pat[0 .. pat.len - 1];
        }

        // Pattern with a slash in the middle is anchored (absolute)
        if (!is_abs and std.mem.indexOf(u8, pat, "/") != null) {
            is_abs = true;
        }

        return GitignoreEntry{
            .pattern = try allocator.dupe(u8, pat),
            .original_pattern = orig,
            .pattern_type = ptype,
            .is_absolute = is_abs,
            .dir_only = dir_only,
            .line_number = line_num,
            .source_file = try allocator.dupe(u8, source),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: GitignoreEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.pattern);
        allocator.free(self.original_pattern);
        allocator.free(self.source_file);
    }

    pub fn matches(self: GitignoreEntry, path: []const u8, is_dir: bool) bool {
        if (self.dir_only and !is_dir) return false;

        if (self.is_absolute) {
            // Absolute patterns match from root
            return globMatch(self.pattern, path);
        } else {
            // Relative patterns match against any path component suffix
            // e.g., "*.o" matches "src/foo.o"
            if (globMatch(self.pattern, path)) return true;
            // Try matching against basename
            const basename = std.fs.path.basename(path);
            return globMatch(self.pattern, basename);
        }
    }
};

/// Simple glob matching supporting * and ?
fn globMatch(pattern: []const u8, text: []const u8) bool {
    return globMatchImpl(pattern, text);
}

fn globMatchImpl(pattern: []const u8, text: []const u8) bool {
    var pi: usize = 0;
    var ti: usize = 0;
    var star_pi: ?usize = null;
    var star_ti: usize = 0;

    while (ti < text.len or pi < pattern.len) {
        if (pi < pattern.len) {
            const pc = pattern[pi];
            if (pc == '*') {
                if (pi + 1 < pattern.len and pattern[pi + 1] == '*') {
                    // ** matches everything including /
                    // Skip all consecutive *
                    var p2 = pi;
                    while (p2 < pattern.len and pattern[p2] == '*') p2 += 1;
                    // If followed by /, skip that too
                    if (p2 < pattern.len and pattern[p2] == '/') p2 += 1;
                    // Try matching rest of pattern at every position
                    var t2 = ti;
                    while (t2 <= text.len) : (t2 += 1) {
                        if (globMatchImpl(pattern[p2..], text[t2..])) return true;
                    }
                    return false;
                }
                // Single * doesn't match /
                star_pi = pi;
                star_ti = ti;
                pi += 1;
                continue;
            } else if (pc == '?' and ti < text.len and text[ti] != '/') {
                pi += 1;
                ti += 1;
                continue;
            } else if (pc == '[' and ti < text.len) {
                // Character class
                if (matchCharClass(pattern[pi..], text[ti])) |advance| {
                    pi += advance;
                    ti += 1;
                    continue;
                }
            } else if (ti < text.len and pc == text[ti]) {
                pi += 1;
                ti += 1;
                continue;
            }
        }

        // Mismatch - try advancing star match
        if (star_pi) |sp| {
            star_ti += 1;
            if (star_ti <= text.len and (star_ti == text.len or text[star_ti - 1] != '/')) {
                pi = sp + 1;
                ti = star_ti;
                continue;
            }
        }

        return false;
    }

    return true;
}

fn matchCharClass(pattern: []const u8, ch: u8) ?usize {
    if (pattern.len < 2 or pattern[0] != '[') return null;
    var i: usize = 1;
    var negate = false;
    if (i < pattern.len and (pattern[i] == '!' or pattern[i] == '^')) {
        negate = true;
        i += 1;
    }
    var found = false;
    while (i < pattern.len and pattern[i] != ']') : (i += 1) {
        if (i + 2 < pattern.len and pattern[i + 1] == '-') {
            if (ch >= pattern[i] and ch <= pattern[i + 2]) found = true;
            i += 2;
        } else {
            if (ch == pattern[i]) found = true;
        }
    }
    if (i < pattern.len and pattern[i] == ']') {
        const matched = if (negate) !found else found;
        return if (matched) i + 1 else null;
    }
    return null;
}

pub const GitIgnore = struct {
    entries: std.array_list.Managed(GitignoreEntry),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) GitIgnore {
        return GitIgnore{
            .entries = std.array_list.Managed(GitignoreEntry).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *GitIgnore) void {
        for (self.entries.items) |entry| {
            entry.deinit(self.allocator);
        }
        self.entries.deinit();
    }

    pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8, platform_impl: anytype) !GitIgnore {
        var gi = GitIgnore.init(allocator);
        const content = platform_impl.fs.readFile(allocator, path) catch |err| {
            return switch (err) {
                error.FileNotFound => gi,
                error.OutOfMemory => err,
                else => gi,
            };
        };
        defer allocator.free(content);
        gi.addPatternsFromSource(content, path);
        return gi;
    }

    /// Add patterns from a string (one pattern per line)
    pub fn addPatterns(self: *GitIgnore, content: []const u8) void {
        self.addPatternsFromSource(content, "");
    }

    /// Add patterns from a string with source file tracking
    pub fn addPatternsFromSource(self: *GitIgnore, content: []const u8, source: []const u8) void {
        var lines = std.mem.splitScalar(u8, content, '\n');
        var line_num: usize = 0;
        while (lines.next()) |line| {
            line_num += 1;
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            if (trimmed[0] == '#') continue;
            const entry = GitignoreEntry.initWithSource(trimmed, source, line_num, self.allocator) catch continue;
            self.entries.append(entry) catch continue;
        }
    }

    /// Check if a path is ignored. Last matching pattern wins.
    pub fn isIgnored(self: *const GitIgnore, path: []const u8) bool {
        var ignored = false;
        for (self.entries.items) |entry| {
            if (entry.matches(path, false)) {
                ignored = entry.pattern_type == .ignore;
            }
        }
        return ignored;
    }

    /// Check if a path is ignored, considering if it's a directory
    pub fn isIgnoredPath(self: *const GitIgnore, path: []const u8, is_dir: bool) bool {
        var ignored = false;
        for (self.entries.items) |entry| {
            if (entry.matches(path, is_dir)) {
                ignored = entry.pattern_type == .ignore;
            }
        }
        return ignored;
    }

    /// Get detailed match information for a path
    pub fn getMatchInfo(self: *const GitIgnore, path: []const u8, is_dir: bool) MatchResult {
        var result = MatchResult{
            .matched = false,
            .source = "",
            .line_number = 0,
            .pattern = "",
            .is_negated = false,
        };
        for (self.entries.items) |entry| {
            if (entry.matches(path, is_dir)) {
                result.matched = entry.pattern_type == .ignore;
                result.source = entry.source_file;
                result.line_number = entry.line_number;
                result.pattern = entry.original_pattern;
                result.is_negated = entry.pattern_type == .unignore;
            }
        }
        return result;
    }
};

// For compatibility
pub const GitignorePattern = GitIgnore;
