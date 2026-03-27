const std = @import("std");
const config = @import("config.zig");

/// Advanced git configuration management with enhanced features
pub const AdvancedGitConfig = struct {
    base_config: config.GitConfig,
    file_paths: std.array_list.Managed([]const u8),
    last_loaded: i64,
    
    pub fn init(allocator: std.mem.Allocator) AdvancedGitConfig {
        return AdvancedGitConfig{
            .base_config = config.GitConfig.init(allocator),
            .file_paths = std.array_list.Managed([]const u8).init(allocator),
            .last_loaded = 0,
        };
    }
    
    pub fn deinit(self: *AdvancedGitConfig) void {
        self.base_config.deinit();
        for (self.file_paths.items) |path| {
            self.base_config.allocator.free(path);
        }
        self.file_paths.deinit();
    }
    
    /// Load configuration with caching and change detection
    pub fn loadWithCaching(self: *AdvancedGitConfig, git_dir: []const u8) !void {
        const current_time = std.time.timestamp();
        
        // Check if any config files have been modified since last load
        var needs_reload = self.last_loaded == 0;
        
        const config_paths = [_][]const u8{
            "/etc/gitconfig",
            try std.fmt.allocPrint(self.base_config.allocator, "{s}/.gitconfig", .{std.posix.getenv("HOME") orelse "/tmp"}),
            try std.fmt.allocPrint(self.base_config.allocator, "{s}/config", .{git_dir}),
        };
        defer {
            self.base_config.allocator.free(config_paths[1]);
            self.base_config.allocator.free(config_paths[2]);
        }
        
        if (!needs_reload) {
            for (config_paths) |path| {
                if (std.fs.cwd().statFile(path)) |stat| {
                    const mtime = @divTrunc(stat.mtime, std.time.ns_per_s);
                    if (mtime > self.last_loaded) {
                        needs_reload = true;
                        break;
                    }
                } else |_| {}
            }
        }
        
        if (needs_reload) {
            // Clear existing configuration
            self.base_config.deinit();
            self.base_config = config.GitConfig.init(self.base_config.allocator);
            
            // Load all configuration files in order
            for (config_paths) |path| {
                self.base_config.parseFromFile(path) catch {};
            }
            
            self.last_loaded = current_time;
        }
    }
    
    /// Get configuration value with environment variable override support
    pub fn getWithEnvOverride(self: AdvancedGitConfig, section: []const u8, subsection: ?[]const u8, name: []const u8) ?[]const u8 {
        // Check for environment variable override first
        // Git uses GIT_<SECTION>_<NAME> pattern for some configs
        const allocator = self.base_config.allocator;
        
        const env_var_name = if (subsection) |sub|
            std.fmt.allocPrint(allocator, "GIT_{s}_{s}_{s}", .{ 
                std.ascii.upperString(allocator, section) catch return self.base_config.get(section, subsection, name),
                std.ascii.upperString(allocator, sub) catch return self.base_config.get(section, subsection, name),
                std.ascii.upperString(allocator, name) catch return self.base_config.get(section, subsection, name),
            }) catch return self.base_config.get(section, subsection, name)
        else
            std.fmt.allocPrint(allocator, "GIT_{s}_{s}", .{ 
                std.ascii.upperString(allocator, section) catch return self.base_config.get(section, subsection, name),
                std.ascii.upperString(allocator, name) catch return self.base_config.get(section, subsection, name),
            }) catch return self.base_config.get(section, subsection, name);
        defer allocator.free(env_var_name);
        
        if (std.posix.getenv(env_var_name)) |env_value| {
            return env_value;
        }
        
        // Common environment variable overrides
        if (std.mem.eql(u8, section, "user") and std.mem.eql(u8, name, "name")) {
            if (std.posix.getenv("GIT_AUTHOR_NAME")) |env_name| return env_name;
            if (std.posix.getenv("GIT_COMMITTER_NAME")) |env_name| return env_name;
        }
        
        if (std.mem.eql(u8, section, "user") and std.mem.eql(u8, name, "email")) {
            if (std.posix.getenv("GIT_AUTHOR_EMAIL")) |env_email| return env_email;
            if (std.posix.getenv("GIT_COMMITTER_EMAIL")) |env_email| return env_email;
        }
        
        // Fallback to normal config lookup
        return self.base_config.get(section, subsection, name);
    }
    
    /// Get all remote configurations
    pub fn getAllRemotes(self: AdvancedGitConfig, allocator: std.mem.Allocator) !std.array_list.Managed(RemoteConfig) {
        var remotes = std.array_list.Managed(RemoteConfig).init(allocator);
        
        // Collect all remote sections
        var remote_names = std.array_list.Managed([]const u8).init(allocator);
        defer {
            for (remote_names.items) |name| {
                allocator.free(name);
            }
            remote_names.deinit();
        }
        
        for (self.base_config.entries.items) |entry| {
            if (std.mem.eql(u8, entry.section, "remote") and entry.subsection != null) {
                const remote_name = entry.subsection.?;
                
                // Check if we already have this remote
                var found = false;
                for (remote_names.items) |existing_name| {
                    if (std.mem.eql(u8, existing_name, remote_name)) {
                        found = true;
                        break;
                    }
                }
                
                if (!found) {
                    try remote_names.append(try allocator.dupe(u8, remote_name));
                }
            }
        }
        
        // Create RemoteConfig for each remote
        for (remote_names.items) |remote_name| {
            const url = self.base_config.get("remote", remote_name, "url");
            const fetch = self.base_config.get("remote", remote_name, "fetch");
            const push = self.base_config.get("remote", remote_name, "push");
            
            try remotes.append(RemoteConfig{
                .name = try allocator.dupe(u8, remote_name),
                .url = if (url) |u| try allocator.dupe(u8, u) else null,
                .fetch = if (fetch) |f| try allocator.dupe(u8, f) else null,
                .push = if (push) |p| try allocator.dupe(u8, p) else null,
            });
        }
        
        return remotes;
    }
    
    /// Get all branch configurations
    pub fn getAllBranches(self: AdvancedGitConfig, allocator: std.mem.Allocator) !std.array_list.Managed(BranchConfig) {
        var branches = std.array_list.Managed(BranchConfig).init(allocator);
        
        // Collect all branch sections
        var branch_names = std.array_list.Managed([]const u8).init(allocator);
        defer {
            for (branch_names.items) |name| {
                allocator.free(name);
            }
            branch_names.deinit();
        }
        
        for (self.base_config.entries.items) |entry| {
            if (std.mem.eql(u8, entry.section, "branch") and entry.subsection != null) {
                const branch_name = entry.subsection.?;
                
                // Check if we already have this branch
                var found = false;
                for (branch_names.items) |existing_name| {
                    if (std.mem.eql(u8, existing_name, branch_name)) {
                        found = true;
                        break;
                    }
                }
                
                if (!found) {
                    try branch_names.append(try allocator.dupe(u8, branch_name));
                }
            }
        }
        
        // Create BranchConfig for each branch
        for (branch_names.items) |branch_name| {
            const remote = self.base_config.get("branch", branch_name, "remote");
            const merge = self.base_config.get("branch", branch_name, "merge");
            const rebase = self.base_config.get("branch", branch_name, "rebase");
            
            try branches.append(BranchConfig{
                .name = try allocator.dupe(u8, branch_name),
                .remote = if (remote) |r| try allocator.dupe(u8, r) else null,
                .merge = if (merge) |m| try allocator.dupe(u8, m) else null,
                .rebase = if (rebase) |rb| std.mem.eql(u8, rb, "true") else false,
            });
        }
        
        return branches;
    }
    
    /// Validate configuration for common issues
    pub fn validate(self: AdvancedGitConfig, allocator: std.mem.Allocator) !std.array_list.Managed(ConfigIssue) {
        var issues = std.array_list.Managed(ConfigIssue).init(allocator);
        
        // Check required user configuration
        if (self.base_config.getUserName() == null) {
            try issues.append(ConfigIssue{
                .severity = .warning,
                .message = try allocator.dupe(u8, "user.name is not set"),
                .suggestion = try allocator.dupe(u8, "Run: git config --global user.name \"Your Name\""),
            });
        }
        
        if (self.base_config.getUserEmail() == null) {
            try issues.append(ConfigIssue{
                .severity = .warning,
                .message = try allocator.dupe(u8, "user.email is not set"),
                .suggestion = try allocator.dupe(u8, "Run: git config --global user.email \"your.email@example.com\""),
            });
        }
        
        // Check for potentially problematic configurations
        if (self.base_config.get("core", null, "autocrlf")) |autocrlf| {
            if (std.mem.eql(u8, autocrlf, "true") and @import("builtin").os.tag != .windows) {
                try issues.append(ConfigIssue{
                    .severity = .info,
                    .message = try allocator.dupe(u8, "core.autocrlf is set to true on non-Windows system"),
                    .suggestion = try allocator.dupe(u8, "Consider setting it to 'input' for cross-platform compatibility"),
                });
            }
        }
        
        // Check remote configurations
        const remotes = try self.getAllRemotes(allocator);
        defer {
            for (remotes.items) |remote| {
                remote.deinit(allocator);
            }
            remotes.deinit();
        }
        
        for (remotes.items) |remote| {
            if (remote.url == null) {
                const message = try std.fmt.allocPrint(allocator, "Remote '{s}' has no URL configured", .{remote.name});
                try issues.append(ConfigIssue{
                    .severity = .error,
                    .message = message,
                    .suggestion = try std.fmt.allocPrint(allocator, "Run: git remote set-url {s} <url>", .{remote.name}),
                });
            }
        }
        
        return issues;
    }
};

/// Remote configuration structure
pub const RemoteConfig = struct {
    name: []const u8,
    url: ?[]const u8,
    fetch: ?[]const u8,
    push: ?[]const u8,
    
    pub fn deinit(self: RemoteConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.url) |url| allocator.free(url);
        if (self.fetch) |fetch| allocator.free(fetch);
        if (self.push) |push| allocator.free(push);
    }
};

/// Branch configuration structure
pub const BranchConfig = struct {
    name: []const u8,
    remote: ?[]const u8,
    merge: ?[]const u8,
    rebase: bool,
    
    pub fn deinit(self: BranchConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.remote) |remote| allocator.free(remote);
        if (self.merge) |merge| allocator.free(merge);
    }
};

/// Configuration validation issue
pub const ConfigIssue = struct {
    severity: enum { error, warning, info },
    message: []const u8,
    suggestion: []const u8,
    
    pub fn deinit(self: ConfigIssue, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        allocator.free(self.suggestion);
    }
};

test "advanced config basic functionality" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var config_adv = AdvancedGitConfig.init(allocator);
    defer config_adv.deinit();
    
    const config_content =
        \\[user]
        \\    name = Advanced User
        \\    email = advanced@example.com
        \\
        \\[remote "origin"]
        \\    url = https://github.com/advanced/repo.git
        \\    fetch = +refs/heads/*:refs/remotes/origin/*
        \\
        \\[branch "main"]
        \\    remote = origin
        \\    merge = refs/heads/main
        \\    rebase = true
    ;
    
    try config_adv.base_config.parseFromString(config_content);
    
    // Test remote collection
    var remotes = try config_adv.getAllRemotes(allocator);
    defer {
        for (remotes.items) |remote| {
            remote.deinit(allocator);
        }
        remotes.deinit();
    }
    
    try testing.expectEqual(@as(usize, 1), remotes.items.len);
    try testing.expectEqualStrings("origin", remotes.items[0].name);
    try testing.expectEqualStrings("https://github.com/advanced/repo.git", remotes.items[0].url.?);
    
    // Test branch collection
    var branches = try config_adv.getAllBranches(allocator);
    defer {
        for (branches.items) |branch| {
            branch.deinit(allocator);
        }
        branches.deinit();
    }
    
    try testing.expectEqual(@as(usize, 1), branches.items.len);
    try testing.expectEqualStrings("main", branches.items[0].name);
    try testing.expectEqualStrings("origin", branches.items[0].remote.?);
    try testing.expect(branches.items[0].rebase);
}