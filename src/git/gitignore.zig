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
        const pattern = std.mem.trim(u8, raw_pattern, " \t\r");
        
        return GitignoreEntry{
            .pattern = try allocator.dupe(u8, pattern),
            .pattern_type = .ignore,
            .is_absolute = false,
            .has_wildcard = false,
        };
    }
    
    pub fn deinit(self: GitignoreEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.pattern);
    }
    
    pub fn matches(self: GitignoreEntry, path: []const u8, is_dir: bool) bool {
        _ = is_dir;
        return std.mem.eql(u8, self.pattern, path);
    }
};

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
        _ = path;
        _ = platform_impl;
        return GitIgnore.init(allocator);
    }

    pub fn isIgnored(self: *const GitIgnore, path: []const u8) bool {
        _ = self;
        _ = path;
        return false;
    }
};

// For compatibility
pub const GitignorePattern = GitIgnore;