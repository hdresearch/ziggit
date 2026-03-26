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

    /// Parse a git config file from string with enhanced validation
    pub fn parseFromString(self: *GitConfig, content: []const u8) !void {
        // Validate input size
        if (content.len > 10 * 1024 * 1024) { // 10MB max config file
            return error.ConfigFileTooLarge;
        }
        
        var lines = std.mem.split(u8, content, "\n");
        var current_section: ?[]const u8 = null;
        var current_subsection: ?[]const u8 = null;
        var line_number: u32 = 0;
        const max_lines = 100_000; // Prevent DoS via extremely long config files
        
        while (lines.next()) |line| {
            line_number += 1;
            
            // Prevent infinite loop attacks
            if (line_number > max_lines) {
                return error.TooManyConfigLines;
            }
            
            // Prevent individual lines from being too long
            if (line.len > 8192) { // 8KB max per line
                continue; // Skip extremely long lines instead of failing
            }
            
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

    /// Set a config value
    pub fn setValue(self: *GitConfig, section: []const u8, subsection: ?[]const u8, name: []const u8, value: []const u8) !void {
        // Check if entry already exists and update it
        for (self.entries.items) |*entry| {
            if (entry.matches(section, subsection, name)) {
                self.allocator.free(entry.value);
                entry.value = try self.allocator.dupe(u8, value);
                return;
            }
        }
        
        // Add new entry
        const entry = ConfigEntry{
            .section = try self.allocator.dupe(u8, section),
            .subsection = if (subsection) |sub| try self.allocator.dupe(u8, sub) else null,
            .name = try self.allocator.dupe(u8, name),
            .value = try self.allocator.dupe(u8, value),
        };
        
        try self.entries.append(entry);
    }

    /// Remove a config value
    pub fn removeValue(self: *GitConfig, section: []const u8, subsection: ?[]const u8, name: []const u8) !bool {
        for (self.entries.items, 0..) |entry, i| {
            if (entry.matches(section, subsection, name)) {
                entry.deinit(self.allocator);
                _ = self.entries.swapRemove(i);
                return true;
            }
        }
        return false;
    }

    /// Get boolean config value with default
    pub fn getBool(self: GitConfig, section: []const u8, subsection: ?[]const u8, name: []const u8, default: bool) bool {
        if (self.get(section, subsection, name)) |value| {
            return parseBooleanValue(value) orelse default;
        }
        return default;
    }

    /// Get integer config value with default
    pub fn getInt(self: GitConfig, section: []const u8, subsection: ?[]const u8, name: []const u8, default: i64) i64 {
        if (self.get(section, subsection, name)) |value| {
            return std.fmt.parseInt(i64, std.mem.trim(u8, value, " \t"), 10) catch default;
        }
        return default;
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

/// Parse boolean values according to git config rules
fn parseBooleanValue(value: []const u8) ?bool {
    const trimmed = std.mem.trim(u8, value, " \t");
    
    if (std.ascii.eqlIgnoreCase(trimmed, "true") or 
        std.ascii.eqlIgnoreCase(trimmed, "yes") or
        std.ascii.eqlIgnoreCase(trimmed, "on") or
        std.ascii.eqlIgnoreCase(trimmed, "1")) {
        return true;
    }
    
    if (std.ascii.eqlIgnoreCase(trimmed, "false") or
        std.ascii.eqlIgnoreCase(trimmed, "no") or
        std.ascii.eqlIgnoreCase(trimmed, "off") or
        std.ascii.eqlIgnoreCase(trimmed, "0")) {
        return false;
    }
    
    return null;
}

/// Write config back to string format
pub fn toString(self: GitConfig, allocator: std.mem.Allocator) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();
    
    var current_section: ?[]const u8 = null;
    var current_subsection: ?[]const u8 = null;
    
    for (self.entries.items) |entry| {
        // Check if we need a new section header
        const section_changed = current_section == null or !std.mem.eql(u8, current_section.?, entry.section);
        const subsection_changed = if (entry.subsection) |sub|
            current_subsection == null or !std.mem.eql(u8, current_subsection.?, sub)
        else
            current_subsection != null;
        
        if (section_changed or subsection_changed) {
            if (current_section != null) {
                try result.append('\n');
            }
            
            if (entry.subsection) |subsection| {
                try result.writer().print("[{s} \"{s}\"]\n", .{ entry.section, subsection });
            } else {
                try result.writer().print("[{s}]\n", .{entry.section});
            }
            
            current_section = entry.section;
            current_subsection = entry.subsection;
        }
        
        // Write the key-value pair
        try result.writer().print("    {s} = {s}\n", .{ entry.name, entry.value });
    }
    
    return try result.toOwnedSlice();
}

/// Write config to file
pub fn writeToFile(self: GitConfig, file_path: []const u8) !void {
    const content = try self.toString(self.allocator);
    defer self.allocator.free(content);
    
    try std.fs.cwd().writeFile(file_path, content);
}

/// Get core.autocrlf setting
pub fn getAutoCrlf(self: GitConfig) ?[]const u8 {
    return self.get("core", null, "autocrlf");
}

/// Get core.filemode setting
pub fn getFileMode(self: GitConfig) bool {
    return self.getBool("core", null, "filemode", true);
}

/// Get core.ignorecase setting  
pub fn getIgnoreCase(self: GitConfig) bool {
    return self.getBool("core", null, "ignorecase", false);
}

/// Get core.bare setting
pub fn getBare(self: GitConfig) bool {
    return self.getBool("core", null, "bare", false);
}

/// Get push.default setting
pub fn getPushDefault(self: GitConfig) ?[]const u8 {
    return self.get("push", null, "default");
}

/// Get pull.rebase setting
pub fn getPullRebase(self: GitConfig) bool {
    return self.getBool("pull", null, "rebase", false);
}

/// Get init.defaultBranch setting (for git init)
pub fn getInitDefaultBranch(self: GitConfig) ?[]const u8 {
    return self.get("init", null, "defaultBranch");
}

/// Get merge.conflictStyle setting
pub fn getMergeConflictStyle(self: GitConfig) ?[]const u8 {
    return self.get("merge", null, "conflictStyle");
}

/// Get diff.tool setting
pub fn getDiffTool(self: GitConfig) ?[]const u8 {
    return self.get("diff", null, "tool");
}

/// Get merge.tool setting
pub fn getMergeTool(self: GitConfig) ?[]const u8 {
    return self.get("merge", null, "tool");
}

/// Get remote.origin.pushurl setting (if different from fetch url)
pub fn getRemotePushUrl(self: GitConfig, remote_name: []const u8) ?[]const u8 {
    return self.get("remote", remote_name, "pushurl");
}

/// Get branch upstream configuration
pub fn getBranchUpstream(self: GitConfig, branch_name: []const u8) ?[]const u8 {
    if (self.getBranchRemote(branch_name)) |remote| {
        if (self.getBranchMerge(branch_name)) |merge_ref| {
            // Extract branch name from refs/heads/branch_name
            if (std.mem.startsWith(u8, merge_ref, "refs/heads/")) {
                const upstream_branch = merge_ref["refs/heads/".len..];
                // Return remote/branch format
                const result = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ remote, upstream_branch }) catch return null;
                return result;
            }
        }
    }
    return null;
}

/// Validate configuration values
pub fn validateConfig(self: GitConfig, allocator: std.mem.Allocator) ![][]const u8 {
    var issues = std.ArrayList([]const u8).init(allocator);
    
    // Check for required user configuration
    if (self.getUserName() == null) {
        try issues.append(try allocator.dupe(u8, "user.name is not configured"));
    }
    
    if (self.getUserEmail() == null) {
        try issues.append(try allocator.dupe(u8, "user.email is not configured"));
    }
    
    // Validate user.email format (basic check)
    if (self.getUserEmail()) |email| {
        if (std.mem.indexOf(u8, email, "@") == null) {
            try issues.append(try allocator.dupe(u8, "user.email does not contain @ symbol"));
        }
    }
    
    // Check for suspicious configurations
    if (self.get("core", null, "autocrlf")) |autocrlf| {
        if (!std.mem.eql(u8, autocrlf, "true") and !std.mem.eql(u8, autocrlf, "false") and !std.mem.eql(u8, autocrlf, "input")) {
            const issue = try std.fmt.allocPrint(allocator, "Invalid core.autocrlf value: {s} (should be true, false, or input)", .{autocrlf});
            try issues.append(issue);
        }
    }
    
    // Validate push.default setting
    if (self.getPushDefault()) |push_default| {
        const valid_values = [_][]const u8{ "nothing", "current", "upstream", "simple", "matching" };
        var is_valid = false;
        for (valid_values) |valid_value| {
            if (std.mem.eql(u8, push_default, valid_value)) {
                is_valid = true;
                break;
            }
        }
        if (!is_valid) {
            const issue = try std.fmt.allocPrint(allocator, "Invalid push.default value: {s}", .{push_default});
            try issues.append(issue);
        }
    }
    
    return issues.toOwnedSlice();
}

/// Get all remotes configured in the repository
pub fn getAllRemotes(self: GitConfig, allocator: std.mem.Allocator) ![][]const u8 {
    var remotes = std.ArrayList([]const u8).init(allocator);
    
    for (self.entries.items) |entry| {
        if (std.mem.eql(u8, entry.section, "remote") and entry.subsection != null) {
            const remote_name = entry.subsection.?;
            
            // Check if we already have this remote
            var already_added = false;
            for (remotes.items) |existing_remote| {
                if (std.mem.eql(u8, existing_remote, remote_name)) {
                    already_added = true;
                    break;
                }
            }
            
            if (!already_added) {
                try remotes.append(try allocator.dupe(u8, remote_name));
            }
        }
    }
    
    return remotes.toOwnedSlice();
}

/// Get all configured branches with their remote tracking information
pub fn getAllBranches(self: GitConfig, allocator: std.mem.Allocator) ![]BranchInfo {
    var branches = std.ArrayList(BranchInfo).init(allocator);
    
    for (self.entries.items) |entry| {
        if (std.mem.eql(u8, entry.section, "branch") and entry.subsection != null) {
            const branch_name = entry.subsection.?;
            
            // Check if we already have this branch
            var branch_info: ?*BranchInfo = null;
            for (branches.items) |*existing_branch| {
                if (std.mem.eql(u8, existing_branch.name, branch_name)) {
                    branch_info = existing_branch;
                    break;
                }
            }
            
            if (branch_info == null) {
                try branches.append(BranchInfo{
                    .name = try allocator.dupe(u8, branch_name),
                    .remote = null,
                    .merge = null,
                    .rebase = false,
                });
                branch_info = &branches.items[branches.items.len - 1];
            }
            
            // Set the specific configuration
            if (std.mem.eql(u8, entry.name, "remote")) {
                if (branch_info.?.remote) |old_remote| allocator.free(old_remote);
                branch_info.?.remote = try allocator.dupe(u8, entry.value);
            } else if (std.mem.eql(u8, entry.name, "merge")) {
                if (branch_info.?.merge) |old_merge| allocator.free(old_merge);
                branch_info.?.merge = try allocator.dupe(u8, entry.value);
            } else if (std.mem.eql(u8, entry.name, "rebase")) {
                branch_info.?.rebase = parseBooleanValue(entry.value) orelse false;
            }
        }
    }
    
    return branches.toOwnedSlice();
}

/// Branch information with tracking details
pub const BranchInfo = struct {
    name: []const u8,
    remote: ?[]const u8,
    merge: ?[]const u8,
    rebase: bool,
    
    pub fn deinit(self: BranchInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.remote) |remote| allocator.free(remote);
        if (self.merge) |merge| allocator.free(merge);
    }
    
    pub fn getUpstreamRef(self: BranchInfo, allocator: std.mem.Allocator) !?[]u8 {
        if (self.remote == null or self.merge == null) return null;
        
        // Convert refs/heads/branch to remote/branch format
        if (std.mem.startsWith(u8, self.merge.?, "refs/heads/")) {
            const branch_name = self.merge.?["refs/heads/".len..];
            return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.remote.?, branch_name });
        }
        
        return null;
    }
};

/// Get all configuration entries (for debugging/export purposes)
pub fn getAllEntries(self: GitConfig) []const ConfigEntry {
    return self.entries.items;
}

/// Count total number of configuration entries
pub fn getEntryCount(self: GitConfig) usize {
    return self.entries.items.len;
}

/// Print configuration summary for debugging
pub fn printSummary(self: GitConfig) void {
    std.debug.print("Git Configuration Summary:\n");
    std.debug.print("  Total entries: {}\n", .{self.entries.items.len});
    
    // Count by section
    var section_counts = std.HashMap([]const u8, u32, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(std.testing.allocator);
    defer section_counts.deinit();
    
    for (self.entries.items) |entry| {
        const count = section_counts.get(entry.section) orelse 0;
        section_counts.put(entry.section, count + 1) catch {};
    }
    
    var iter = section_counts.iterator();
    while (iter.next()) |kv| {
        std.debug.print("  [{s}]: {} entries\n", .{ kv.key_ptr.*, kv.value_ptr.* });
    }
}

test "enhanced config features" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var config = GitConfig.init(allocator);
    defer config.deinit();
    
    // Test setting and getting values
    try config.setValue("user", null, "name", "Test User");
    try config.setValue("core", null, "filemode", "false");
    try config.setValue("remote", "origin", "url", "https://example.com/repo.git");
    
    try testing.expectEqualStrings("Test User", config.get("user", null, "name").?);
    try testing.expectEqual(false, config.getBool("core", null, "filemode", true));
    
    // Test removing values
    try testing.expect(try config.removeValue("user", null, "name"));
    try testing.expect(config.get("user", null, "name") == null);
    
    // Test boolean parsing
    try testing.expectEqual(true, config.getBool("nonexistent", null, "key", true));
}

test "boolean value parsing" {
    try std.testing.expectEqual(@as(?bool, true), parseBooleanValue("true"));
    try std.testing.expectEqual(@as(?bool, true), parseBooleanValue("TRUE"));
    try std.testing.expectEqual(@as(?bool, true), parseBooleanValue("yes"));
    try std.testing.expectEqual(@as(?bool, true), parseBooleanValue("on"));
    try std.testing.expectEqual(@as(?bool, true), parseBooleanValue("1"));
    
    try std.testing.expectEqual(@as(?bool, false), parseBooleanValue("false"));
    try std.testing.expectEqual(@as(?bool, false), parseBooleanValue("FALSE"));
    try std.testing.expectEqual(@as(?bool, false), parseBooleanValue("no"));
    try std.testing.expectEqual(@as(?bool, false), parseBooleanValue("off"));
    try std.testing.expectEqual(@as(?bool, false), parseBooleanValue("0"));
    
    try std.testing.expectEqual(@as(?bool, null), parseBooleanValue("maybe"));
    try std.testing.expectEqual(@as(?bool, null), parseBooleanValue(""));
}