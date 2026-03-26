const std = @import("std");

/// Git configuration entry
pub const ConfigEntry = struct {
    section: []const u8,
    subsection: ?[]const u8,
    name: []const u8,
    value: []const u8,

    pub fn deinit(self: ConfigEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.section);
        if (self.subsection) |subsection| {
            allocator.free(subsection);
        }
        allocator.free(self.name);
        allocator.free(self.value);
    }

    pub fn matches(self: ConfigEntry, section: []const u8, subsection: ?[]const u8, name: []const u8) bool {
        if (!std.ascii.eqlIgnoreCase(self.section, section)) return false;
        if (!std.ascii.eqlIgnoreCase(self.name, name)) return false;
        
        if (subsection) |sub| {
            if (self.subsection) |self_sub| {
                return std.ascii.eqlIgnoreCase(self_sub, sub);
            }
            return false;
        } else {
            return self.subsection == null;
        }
    }
};

/// Git configuration parser
pub const GitConfig = struct {
    entries: std.ArrayList(ConfigEntry),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) GitConfig {
        return GitConfig{
            .entries = std.ArrayList(ConfigEntry).init(allocator),
            .allocator = allocator,
        };
    }

    /// Convenience function to parse config from string (alias for parseFromString)
    pub fn parseConfig(allocator: std.mem.Allocator, content: []const u8) !GitConfig {
        var config = GitConfig.init(allocator);
        try config.parseFromString(content);
        return config;
    }

    pub fn deinit(self: *GitConfig) void {
        for (self.entries.items) |entry| {
            entry.deinit(self.allocator);
        }
        self.entries.deinit();
    }

    /// Parse a git config file from string
    pub fn parseFromString(self: *GitConfig, content: []const u8) !void {
        var lines = std.mem.split(u8, content, "\n");
        var current_section: ?[]const u8 = null;
        var current_subsection: ?[]const u8 = null;
        var line_number: u32 = 0;
        
        while (lines.next()) |line| {
            line_number += 1;
            const trimmed = std.mem.trim(u8, line, " \t\r");
            
            // Skip empty lines and comments
            if (trimmed.len == 0 or trimmed[0] == '#' or trimmed[0] == ';') {
                continue;
            }
            
            // Section header: [section] or [section "subsection"]
            if (trimmed[0] == '[') {
                if (trimmed.len < 3 or trimmed[trimmed.len - 1] != ']') {
                    // Malformed section header, skip it
                    continue;
                }
                
                const section_content = trimmed[1..trimmed.len - 1];
                
                // Check for subsection: section "subsection"
                if (std.mem.indexOf(u8, section_content, "\"")) |quote_start| {
                    const section = std.mem.trim(u8, section_content[0..quote_start], " \t");
                    
                    // Validate section name is not empty
                    if (section.len == 0) continue;
                    
                    // Find closing quote
                    if (std.mem.lastIndexOf(u8, section_content, "\"")) |quote_end| {
                        if (quote_end > quote_start) {
                            const subsection = section_content[quote_start + 1..quote_end];
                            
                            // Free previous section/subsection
                            if (current_section) |sec| self.allocator.free(sec);
                            if (current_subsection) |sub| self.allocator.free(sub);
                            
                            current_section = try self.allocator.dupe(u8, section);
                            current_subsection = try self.allocator.dupe(u8, subsection);
                            continue;
                        }
                    }
                    // Malformed quoted subsection, treat as simple section
                }
                
                // Simple section without subsection
                const section = std.mem.trim(u8, section_content, " \t");
                if (section.len == 0) continue; // Skip empty section names
                
                if (current_section) |sec| self.allocator.free(sec);
                if (current_subsection) |sub| self.allocator.free(sub);
                
                current_section = try self.allocator.dupe(u8, section);
                current_subsection = null;
                continue;
            }
            
            // Key-value pair: name = value
            if (std.mem.indexOf(u8, trimmed, "=")) |equals_pos| {
                if (current_section == null) continue; // No section, skip
                
                const key = std.mem.trim(u8, trimmed[0..equals_pos], " \t");
                const value = std.mem.trim(u8, trimmed[equals_pos + 1..], " \t");
                
                // Remove quotes from value if present
                const clean_value = if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"')
                    value[1..value.len - 1]
                else
                    value;
                
                const entry = ConfigEntry{
                    .section = try self.allocator.dupe(u8, current_section.?),
                    .subsection = if (current_subsection) |sub| try self.allocator.dupe(u8, sub) else null,
                    .name = try self.allocator.dupe(u8, key),
                    .value = try self.allocator.dupe(u8, clean_value),
                };
                
                try self.entries.append(entry);
            }
        }
        
        // Cleanup
        if (current_section) |sec| self.allocator.free(sec);
        if (current_subsection) |sub| self.allocator.free(sub);
    }

    /// Parse a git config file from filesystem
    pub fn parseFromFile(self: *GitConfig, file_path: []const u8) !void {
        const content = std.fs.cwd().readFileAlloc(self.allocator, file_path, 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => return, // Config file doesn't exist, that's OK
            else => return err,
        };
        defer self.allocator.free(content);
        
        try self.parseFromString(content);
    }

    /// Get a config value
    pub fn get(self: GitConfig, section: []const u8, subsection: ?[]const u8, name: []const u8) ?[]const u8 {
        for (self.entries.items) |entry| {
            if (entry.matches(section, subsection, name)) {
                return entry.value;
            }
        }
        return null;
    }

    /// Get all values for a config key (for multi-value configs)
    pub fn getAll(self: GitConfig, section: []const u8, subsection: ?[]const u8, name: []const u8, allocator: std.mem.Allocator) ![][]const u8 {
        var values = std.ArrayList([]const u8).init(allocator);
        
        for (self.entries.items) |entry| {
            if (entry.matches(section, subsection, name)) {
                try values.append(entry.value);
            }
        }
        
        return values.toOwnedSlice();
    }

    /// Get remote URL for a given remote name
    pub fn getRemoteUrl(self: GitConfig, remote_name: []const u8) ?[]const u8 {
        return self.get("remote", remote_name, "url");
    }

    /// Get remote URL with allocator parameter (for API compatibility)
    pub fn getRemoteUrlAlloc(self: GitConfig, allocator: std.mem.Allocator, remote_name: []const u8) ?[]const u8 {
        _ = allocator; // Not used for this operation
        return self.get("remote", remote_name, "url");
    }

    /// Get user name
    pub fn getUserName(self: GitConfig) ?[]const u8 {
        return self.get("user", null, "name");
    }

    /// Get user email
    pub fn getUserEmail(self: GitConfig) ?[]const u8 {
        return self.get("user", null, "email");
    }

    /// Get branch remote for a branch
    pub fn getBranchRemote(self: GitConfig, branch_name: []const u8) ?[]const u8 {
        return self.get("branch", branch_name, "remote");
    }

    /// Get branch remote with allocator parameter (for API compatibility)
    pub fn getBranchRemoteAlloc(self: GitConfig, allocator: std.mem.Allocator, branch_name: []const u8) ?[]const u8 {
        _ = allocator; // Not used for this operation
        return self.get("branch", branch_name, "remote");
    }

    /// Get branch merge target for a branch
    pub fn getBranchMerge(self: GitConfig, branch_name: []const u8) ?[]const u8 {
        return self.get("branch", branch_name, "merge");
    }

    /// Get branch merge with allocator parameter (for API compatibility) 
    pub fn getBranchMergeAlloc(self: GitConfig, allocator: std.mem.Allocator, branch_name: []const u8) ?[]const u8 {
        _ = allocator; // Not used for this operation
        return self.get("branch", branch_name, "merge");
    }

    /// Generic value getter (convenience method for tests)
    pub fn getValue(self: GitConfig, section: []const u8, name: []const u8) ?[]const u8 {
        return self.get(section, null, name);
    }
};

/// Load git config from a git directory
pub fn loadGitConfig(git_dir: []const u8, allocator: std.mem.Allocator) !GitConfig {
    var config = GitConfig.init(allocator);
    
    // Load global config first (if it exists)
    const home_dir = std.posix.getenv("HOME") orelse "/tmp";
    const global_config_path = try std.fmt.allocPrint(allocator, "{s}/.gitconfig", .{home_dir});
    defer allocator.free(global_config_path);
    config.parseFromFile(global_config_path) catch {};
    
    // Load system config (if it exists)
    config.parseFromFile("/etc/gitconfig") catch {};
    
    // Load local config (this takes precedence)
    const local_config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{git_dir});
    defer allocator.free(local_config_path);
    try config.parseFromFile(local_config_path);
    
    return config;
}

/// Get remote URL for a repository (convenience function)
pub fn getRemoteUrl(git_dir: []const u8, remote_name: []const u8, allocator: std.mem.Allocator) !?[]const u8 {
    var config = loadGitConfig(git_dir, allocator) catch return null;
    defer config.deinit();
    
    if (config.getRemoteUrl(remote_name)) |url| {
        return try allocator.dupe(u8, url);
    }
    
    return null;
}

test "parse simple config" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var config = GitConfig.init(allocator);
    defer config.deinit();
    
    const config_content =
        \\[user]
        \\    name = John Doe
        \\    email = john@example.com
        \\
        \\[remote "origin"]
        \\    url = https://github.com/user/repo.git
        \\    fetch = +refs/heads/*:refs/remotes/origin/*
        \\
        \\[branch "master"]
        \\    remote = origin
        \\    merge = refs/heads/master
    ;
    
    try config.parseFromString(config_content);
    
    // Test user config
    try testing.expectEqualStrings("John Doe", config.getUserName().?);
    try testing.expectEqualStrings("john@example.com", config.getUserEmail().?);
    
    // Test remote config
    try testing.expectEqualStrings("https://github.com/user/repo.git", config.getRemoteUrl("origin").?);
    
    // Test branch config
    try testing.expectEqualStrings("origin", config.getBranchRemote("master").?);
    try testing.expectEqualStrings("refs/heads/master", config.getBranchMerge("master").?);
}

test "parse config with comments" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var config = GitConfig.init(allocator);
    defer config.deinit();
    
    const config_content =
        \\# This is a comment
        \\[user]
        \\    # User settings
        \\    name = Jane Doe  # inline comment ignored
        \\    email = "jane@example.com"
        \\
        \\; This is also a comment
        \\[core]
        \\    editor = vim
    ;
    
    try config.parseFromString(config_content);
    
    try testing.expectEqualStrings("Jane Doe  # inline comment ignored", config.getUserName().?);
    try testing.expectEqualStrings("jane@example.com", config.getUserEmail().?);
    try testing.expectEqualStrings("vim", config.get("core", null, "editor").?);
}

test "case insensitive matching" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var config = GitConfig.init(allocator);
    defer config.deinit();
    
    const config_content =
        \\[User]
        \\    Name = Test User
        \\    EMAIL = test@example.com
        \\
        \\[Remote "Origin"]
        \\    URL = https://example.com/repo.git
    ;
    
    try config.parseFromString(config_content);
    
    // Should match case-insensitively
    try testing.expectEqualStrings("Test User", config.get("user", null, "name").?);
    try testing.expectEqualStrings("Test User", config.get("USER", null, "NAME").?);
    try testing.expectEqualStrings("test@example.com", config.get("user", null, "email").?);
    try testing.expectEqualStrings("https://example.com/repo.git", config.get("remote", "origin", "url").?);
    try testing.expectEqualStrings("https://example.com/repo.git", config.get("REMOTE", "ORIGIN", "URL").?);
}