const std = @import("std");
const config_mod = @import("config.zig");
const GitConfig = config_mod.GitConfig;

/// High-level config helper functions for common git operations
pub const ConfigHelpers = struct {
    config: GitConfig,
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) ConfigHelpers {
        return ConfigHelpers{
            .config = GitConfig.init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *ConfigHelpers) void {
        self.config.deinit();
    }
    
    /// Load git configuration from standard locations in order of precedence
    pub fn loadStandardConfig(self: *ConfigHelpers, git_dir: []const u8) !void {
        // System config (/etc/gitconfig) - lowest priority, often doesn't exist
        self.config.parseFromFile("/etc/gitconfig") catch {};
        
        // Global config (~/.gitconfig or ~/.config/git/config) 
        if (std.os.getenv("HOME")) |home| {
            const global_config = try std.fmt.allocPrint(self.allocator, "{s}/.gitconfig", .{home});
            defer self.allocator.free(global_config);
            self.config.parseFromFile(global_config) catch {};
            
            // Also try XDG config location
            const xdg_config = try std.fmt.allocPrint(self.allocator, "{s}/.config/git/config", .{home});
            defer self.allocator.free(xdg_config);
            self.config.parseFromFile(xdg_config) catch {};
        }
        
        // Repository config (.git/config) - highest priority
        const repo_config = try std.fmt.allocPrint(self.allocator, "{s}/config", .{git_dir});
        defer self.allocator.free(repo_config);
        try self.config.parseFromFile(repo_config);
    }
    
    /// Get remote URL for a given remote name (commonly used for clone/fetch/push)
    pub fn getRemoteUrl(self: ConfigHelpers, remote_name: []const u8) ?[]const u8 {
        return self.config.get("remote", remote_name, "url");
    }
    
    /// Get default branch for a remote
    pub fn getRemoteHead(self: ConfigHelpers, remote_name: []const u8) ?[]const u8 {
        if (self.config.get("remote", remote_name, "HEAD")) |head| {
            // Parse "refs/heads/main" -> "main"
            if (std.mem.startsWith(u8, head, "refs/heads/")) {
                return head["refs/heads/".len..];
            }
            return head;
        }
        return null;
    }
    
    /// Get the upstream branch for a local branch
    pub fn getUpstreamBranch(self: ConfigHelpers, branch_name: []const u8) ?UpstreamInfo {
        const remote = self.config.get("branch", branch_name, "remote") orelse return null;
        const merge = self.config.get("branch", branch_name, "merge") orelse return null;
        
        // Parse refs/heads/branch_name to just branch_name
        const remote_branch = if (std.mem.startsWith(u8, merge, "refs/heads/"))
            merge["refs/heads/".len..]
        else
            merge;
            
        return UpstreamInfo{
            .remote = remote,
            .branch = remote_branch,
        };
    }
    
    /// Get user information for commits
    pub fn getUserInfo(self: ConfigHelpers) UserInfo {
        const name = self.config.get("user", null, "name") orelse "Unknown";
        const email = self.config.get("user", null, "email") orelse "unknown@localhost";
        
        return UserInfo{
            .name = name,
            .email = email,
        };
    }
    
    /// Get core configuration values
    pub fn getCoreConfig(self: ConfigHelpers) CoreConfig {
        const bare = if (self.config.get("core", null, "bare")) |bare_str| 
            std.ascii.eqlIgnoreCase(bare_str, "true") 
        else 
            false;
            
        const worktree = self.config.get("core", null, "worktree");
        
        const filemode = if (self.config.get("core", null, "filemode")) |filemode_str|
            std.ascii.eqlIgnoreCase(filemode_str, "true")
        else
            true; // Default to true
            
        const autocrlf = if (self.config.get("core", null, "autocrlf")) |crlf_str|
            parseAutoCrlf(crlf_str)
        else
            .false;
            
        return CoreConfig{
            .bare = bare,
            .worktree = worktree,
            .filemode = filemode,
            .autocrlf = autocrlf,
        };
    }
    
    /// Check if a feature is enabled (for various git features)
    pub fn isFeatureEnabled(self: ConfigHelpers, section: []const u8, feature: []const u8) bool {
        if (self.config.get(section, null, feature)) |value| {
            return std.ascii.eqlIgnoreCase(value, "true") or std.mem.eql(u8, value, "1");
        }
        return false;
    }
    
    /// Get all remotes configured in the repository
    pub fn getAllRemotes(self: ConfigHelpers, allocator: std.mem.Allocator) ![]RemoteInfo {
        var remotes = std.ArrayList(RemoteInfo).init(allocator);
        var seen_remotes = std.StringHashMap(void).init(allocator);
        defer seen_remotes.deinit();
        
        // Scan through all config entries looking for remote sections
        for (self.config.entries.items) |entry| {
            if (std.mem.eql(u8, entry.section, "remote") and entry.subsection != null) {
                const remote_name = entry.subsection.?;
                
                // Avoid duplicates
                if (seen_remotes.contains(remote_name)) continue;
                try seen_remotes.put(remote_name, {});
                
                const url = self.config.get("remote", remote_name, "url");
                const fetch_refspec = self.config.get("remote", remote_name, "fetch");
                const push_refspec = self.config.get("remote", remote_name, "push");
                
                try remotes.append(RemoteInfo{
                    .name = try allocator.dupe(u8, remote_name),
                    .url = if (url) |u| try allocator.dupe(u8, u) else null,
                    .fetch_refspec = if (fetch_refspec) |f| try allocator.dupe(u8, f) else null,
                    .push_refspec = if (push_refspec) |p| try allocator.dupe(u8, p) else null,
                });
            }
        }
        
        return try remotes.toOwnedSlice();
    }
    
    /// Set a configuration value
    pub fn setValue(self: *ConfigHelpers, section: []const u8, subsection: ?[]const u8, name: []const u8, value: []const u8) !void {
        // Remove existing entry if it exists
        var i: usize = 0;
        while (i < self.config.entries.items.len) {
            if (self.config.entries.items[i].matches(section, subsection, name)) {
                const removed = self.config.entries.orderedRemove(i);
                removed.deinit(self.allocator);
                break;
            }
            i += 1;
        }
        
        // Add new entry
        const entry = config_mod.ConfigEntry{
            .section = try self.allocator.dupe(u8, section),
            .subsection = if (subsection) |sub| try self.allocator.dupe(u8, sub) else null,
            .name = try self.allocator.dupe(u8, name),
            .value = try self.allocator.dupe(u8, value),
        };
        
        try self.config.entries.append(entry);
    }
    
    /// Save configuration to a file
    pub fn saveToFile(self: ConfigHelpers, file_path: []const u8) !void {
        var file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();
        
        const writer = file.writer();
        var current_section: ?[]const u8 = null;
        var current_subsection: ?[]const u8 = null;
        
        for (self.config.entries.items) |entry| {
            // Write section header if needed
            const section_changed = current_section == null or !std.mem.eql(u8, current_section.?, entry.section);
            const subsection_changed = !std.meta.eql(current_subsection, entry.subsection);
            
            if (section_changed or subsection_changed) {
                current_section = entry.section;
                current_subsection = entry.subsection;
                
                if (entry.subsection) |subsection| {
                    try writer.print("[{s} \"{s}\"]\n", .{ entry.section, subsection });
                } else {
                    try writer.print("[{s}]\n", .{entry.section});
                }
            }
            
            // Write key-value pair
            if (needsQuoting(entry.value)) {
                try writer.print("\t{s} = \"{s}\"\n", .{ entry.name, entry.value });
            } else {
                try writer.print("\t{s} = {s}\n", .{ entry.name, entry.value });
            }
        }
    }
};

fn parseAutoCrlf(value: []const u8) AutoCrlf {
    if (std.ascii.eqlIgnoreCase(value, "true")) return .true;
    if (std.ascii.eqlIgnoreCase(value, "false")) return .false;
    if (std.ascii.eqlIgnoreCase(value, "input")) return .input;
    return .false; // Default
}

fn needsQuoting(value: []const u8) bool {
    for (value) |c| {
        if (c == ' ' or c == '\t' or c == '"' or c == '\\') {
            return true;
        }
    }
    return false;
}

pub const UpstreamInfo = struct {
    remote: []const u8,
    branch: []const u8,
};

pub const UserInfo = struct {
    name: []const u8,
    email: []const u8,
    
    pub fn formatForCommit(self: UserInfo, allocator: std.mem.Allocator, timestamp: i64) ![]u8 {
        // Format: "Name <email> timestamp +0000"
        return try std.fmt.allocPrint(allocator, "{s} <{s}> {} +0000", .{ self.name, self.email, timestamp });
    }
};

pub const CoreConfig = struct {
    bare: bool,
    worktree: ?[]const u8,
    filemode: bool,
    autocrlf: AutoCrlf,
};

pub const AutoCrlf = enum {
    true,
    false,
    input,
};

pub const RemoteInfo = struct {
    name: []u8,
    url: ?[]u8,
    fetch_refspec: ?[]u8,
    push_refspec: ?[]u8,
    
    pub fn deinit(self: RemoteInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.url) |url| allocator.free(url);
        if (self.fetch_refspec) |refspec| allocator.free(refspec);
        if (self.push_refspec) |refspec| allocator.free(refspec);
    }
};

/// Convenience function to get remote URL (commonly needed by the library)
pub fn getRemoteUrl(git_dir: []const u8, remote_name: []const u8, allocator: std.mem.Allocator) !?[]u8 {
    var helpers = ConfigHelpers.init(allocator);
    defer helpers.deinit();
    
    try helpers.loadStandardConfig(git_dir);
    
    if (helpers.getRemoteUrl(remote_name)) |url| {
        return try allocator.dupe(u8, url);
    }
    
    return null;
}

/// Convenience function to get user info for commits
pub fn getUserInfo(git_dir: []const u8, allocator: std.mem.Allocator) !UserInfo {
    var helpers = ConfigHelpers.init(allocator);
    defer helpers.deinit();
    
    try helpers.loadStandardConfig(git_dir);
    
    return helpers.getUserInfo();
}