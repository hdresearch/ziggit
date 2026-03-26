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
        
        const pattern_type = if (is_negation) 
            PatternType.unignore 
        else if (is_directory) 
            PatternType.directory 
        else 
            PatternType.ignore;
            
        return GitignoreEntry{
            .pattern = try allocator.dupe(u8, pattern),
            .pattern_type = pattern_type,
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
        return std.mem.eql(u8, self.pattern, text);
    }
};