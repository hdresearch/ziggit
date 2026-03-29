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
        var remotes = std.array_list.Managed(RemoteInfo).init(allocator);
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

/// Split a command line string respecting single and double quotes.
/// Returns error.UnclosedQuote if there's an unmatched quote.
/// This mimics git's split_cmdline() function.
pub fn splitCmdline(input: []const u8, allocator: std.mem.Allocator) ![][]const u8 {
    var words = std.array_list.Managed([]const u8).init(allocator);
    errdefer {
        for (words.items) |w| allocator.free(w);
        words.deinit();
    }

    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    var i: usize = 0;
    while (i < input.len) {
        // Skip whitespace
        while (i < input.len and (input[i] == ' ' or input[i] == '\t')) : (i += 1) {}
        if (i >= input.len) break;

        buf.clearRetainingCapacity();
        while (i < input.len and input[i] != ' ' and input[i] != '\t') {
            if (input[i] == '\\' and i + 1 < input.len) {
                i += 1;
                try buf.append(input[i]);
                i += 1;
            } else if (input[i] == '"') {
                i += 1; // skip opening quote
                while (i < input.len and input[i] != '"') {
                    if (input[i] == '\\' and i + 1 < input.len) {
                        i += 1;
                        try buf.append(input[i]);
                        i += 1;
                    } else {
                        try buf.append(input[i]);
                        i += 1;
                    }
                }
                if (i >= input.len) return error.UnclosedQuote;
                i += 1; // skip closing quote
            } else if (input[i] == '\'') {
                i += 1; // skip opening quote
                while (i < input.len and input[i] != '\'') {
                    try buf.append(input[i]);
                    i += 1;
                }
                if (i >= input.len) return error.UnclosedQuote;
                i += 1; // skip closing quote
            } else {
                try buf.append(input[i]);
                i += 1;
            }
        }
        if (buf.items.len > 0) {
            try words.append(try allocator.dupe(u8, buf.items));
        }
    }

    return try words.toOwnedSlice();
}

/// Validate pre-command config: check core.bare is valid boolean if set via -c,
/// and check hasconfig:remote.*.url violations.
/// Called from main before command dispatch.
pub fn validatePreCommandConfig(platform_impl: anytype) void {
const git_helpers_mod = @import("../git_helpers.zig");
    const allocator = std.heap.page_allocator;

    // Check core.bare boolean validity
    if (git_helpers_mod.global_config_overrides) |overrides| {
        for (overrides.items) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.key, "core.bare")) {
                const val = entry.value;
                if (!isValidBool(val)) {
                    platform_impl.writeStderr("fatal: bad boolean config value '") catch {};
                    platform_impl.writeStderr(val) catch {};
                    platform_impl.writeStderr("' for 'core.bare'\n") catch {};
                    std.process.exit(128);
                }
            }
        }
    }

    // Check hasconfig:remote.*.url violations
    // If the repo config uses includeIf hasconfig:remote.*.url and the included file
    // defines remote URLs, that's forbidden.
    const git_path = git_helpers_mod.findGitDirectory(allocator, platform_impl) catch return;
    defer allocator.free(git_path);

    const config_path = std.fmt.allocPrint(allocator, "{s}/config", .{git_path}) catch return;
    defer allocator.free(config_path);

    const content = std.fs.cwd().readFileAlloc(allocator, config_path, 10 * 1024 * 1024) catch return;
    defer allocator.free(content);

    // Scan for includeIf "hasconfig:remote.*.url:..." directives
    var lines = std.mem.splitScalar(u8, content, '\n');
    var in_hasconfig_include = false;
    var include_path: ?[]const u8 = null;

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");

        // Check for [includeIf "hasconfig:remote.*.url:..."]
        if (std.mem.startsWith(u8, trimmed, "[includeIf \"hasconfig:remote.")) {
            in_hasconfig_include = true;
            include_path = null;
            continue;
        }
        if (trimmed.len > 0 and trimmed[0] == '[') {
            in_hasconfig_include = false;
            include_path = null;
            continue;
        }

        if (in_hasconfig_include) {
            // Look for path = ...
            if (std.mem.startsWith(u8, trimmed, "path")) {
                const after_path = std.mem.trimLeft(u8, trimmed[4..], " \t");
                if (after_path.len > 0 and after_path[0] == '=') {
                    var val = std.mem.trim(u8, after_path[1..], " \t");
                    // Remove surrounding quotes
                    if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"') {
                        val = val[1 .. val.len - 1];
                    }
                    include_path = val;
                }
            }
        }

        if (include_path) |ipath| {
            // Read the included file and check for remote URLs
            const inc_content = std.fs.cwd().readFileAlloc(allocator, ipath, 10 * 1024 * 1024) catch {
                include_path = null;
                continue;
            };
            defer allocator.free(inc_content);

            if (configHasRemoteUrl(inc_content)) {
                platform_impl.writeStderr("fatal: remote URLs cannot be configured in file directly or indirectly included by includeIf.hasconfig:remote.*.url\n") catch {};
                std.process.exit(128);
            }
            include_path = null;
        }
    }
}

fn configHasRemoteUrl(content: []const u8) bool {
    var lines = std.mem.splitScalar(u8, content, '\n');
    var in_remote_section = false;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0 and trimmed[0] == '[') {
            // Check for [remote "..."]
            in_remote_section = std.mem.startsWith(u8, trimmed, "[remote ");
            continue;
        }
        if (in_remote_section) {
            const kv = std.mem.trim(u8, trimmed, " \t");
            if (std.mem.startsWith(u8, kv, "url")) {
                const after = std.mem.trimLeft(u8, kv[3..], " \t");
                if (after.len > 0 and after[0] == '=') {
                    return true;
                }
            }
        }
    }
    return false;
}

fn isValidBool(val: []const u8) bool {
    if (val.len == 0) return true; // empty = true in git
    const lower_bufs = [_][]const u8{
        "true", "false", "yes", "no", "on", "off", "1", "0",
    };
    for (lower_bufs) |valid| {
        if (std.ascii.eqlIgnoreCase(val, valid)) return true;
    }
    return false;
}

/// Set GIT_CONFIG_PARAMETERS environment variable from global_config_overrides.
/// This ensures child processes (e.g., shell aliases) inherit -c overrides.
pub fn setConfigParametersEnv(allocator: std.mem.Allocator) void {
const git_helpers_mod = @import("../git_helpers.zig");
    const overrides = git_helpers_mod.global_config_overrides orelse return;
    if (overrides.items.len == 0) return;

    // Build GIT_CONFIG_PARAMETERS format: 'key=value' 'key=value' ...
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    for (overrides.items) |entry| {
        if (buf.items.len > 0) buf.append(' ') catch return;
        buf.append('\'') catch return;
        // Escape single quotes in key and value
        for (entry.key) |c| {
            if (c == '\'') {
                buf.appendSlice("'\\''") catch return;
            } else {
                buf.append(c) catch return;
            }
        }
        buf.append('=') catch return;
        for (entry.value) |c| {
            if (c == '\'') {
                buf.appendSlice("'\\''") catch return;
            } else {
                buf.append(c) catch return;
            }
        }
        buf.append('\'') catch return;
    }

    // Null-terminate for C setenv
    buf.append(0) catch return;
    const c_str: [*:0]const u8 = @ptrCast(buf.items[0 .. buf.items.len - 1 :0]);
    _ = git_helpers_mod.cSetenv("GIT_CONFIG_PARAMETERS", c_str, 1);
}

/// Resolve alias from config, respecting GIT_CONFIG_NOSYSTEM and GIT_CONFIG_SYSTEM.
/// Returns the alias value or null if not found.
pub fn resolveAliasFromConfig(allocator: std.mem.Allocator, name: []const u8, platform_impl: anytype) ?[]u8 {
const git_helpers_mod = @import("../git_helpers.zig");
    const alias_key = std.fmt.allocPrint(allocator, "alias.{s}", .{name}) catch return null;
    defer allocator.free(alias_key);
    const alias_subsection_key = std.fmt.allocPrint(allocator, "alias.{s}.command", .{name}) catch return null;
    defer allocator.free(alias_subsection_key);

    // Check -c overrides first
    if (git_helpers_mod.global_config_overrides) |overrides| {
        for (overrides.items) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.key, alias_key)) {
                return allocator.dupe(u8, entry.value) catch null;
            }
            if (std.ascii.eqlIgnoreCase(entry.key, alias_subsection_key)) {
                return allocator.dupe(u8, entry.value) catch null;
            }
        }
    }

    // Try local config (.git/config)
    if (git_helpers_mod.findGitDirectory(allocator, platform_impl)) |git_path| {
        defer allocator.free(git_path);
        const config_path = std.fmt.allocPrint(allocator, "{s}/config", .{git_path}) catch return null;
        defer allocator.free(config_path);
        if (platform_impl.fs.readFile(allocator, config_path)) |content| {
            defer allocator.free(content);
            if (git_helpers_mod.parseConfigValue(content, alias_key, allocator) catch null) |val| return val;
            if (git_helpers_mod.parseConfigValue(content, alias_subsection_key, allocator) catch null) |val| return val;
        } else |_| {}
    } else |_| {}

    // Try global config (~/.gitconfig)
    if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
        defer allocator.free(home);
        const global_config = std.fmt.allocPrint(allocator, "{s}/.gitconfig", .{home}) catch return null;
        defer allocator.free(global_config);
        if (platform_impl.fs.readFile(allocator, global_config)) |content| {
            defer allocator.free(content);
            if (git_helpers_mod.parseConfigValue(content, alias_key, allocator) catch null) |val| return val;
            if (git_helpers_mod.parseConfigValue(content, alias_subsection_key, allocator) catch null) |val| return val;
        } else |_| {}

        // Try XDG config
        const xdg_config = std.fmt.allocPrint(allocator, "{s}/.config/git/config", .{home}) catch return null;
        defer allocator.free(xdg_config);
        if (platform_impl.fs.readFile(allocator, xdg_config)) |content| {
            defer allocator.free(content);
            if (git_helpers_mod.parseConfigValue(content, alias_key, allocator) catch null) |val| return val;
            if (git_helpers_mod.parseConfigValue(content, alias_subsection_key, allocator) catch null) |val| return val;
        } else |_| {}
    } else |_| {}

    // Try system config - respect GIT_CONFIG_NOSYSTEM and GIT_CONFIG_SYSTEM
    const nosystem = std.process.getEnvVarOwned(allocator, "GIT_CONFIG_NOSYSTEM") catch null;
    const skip_system = blk: {
        if (nosystem) |ns| {
            defer allocator.free(ns);
            // GIT_CONFIG_NOSYSTEM=true/1/yes means skip system config
            if (ns.len > 0 and !std.mem.eql(u8, ns, "0") and !std.ascii.eqlIgnoreCase(ns, "false") and !std.ascii.eqlIgnoreCase(ns, "no")) {
                break :blk true;
            }
        }
        break :blk false;
    };

    if (!skip_system) {
        // Check GIT_CONFIG_SYSTEM for custom system config path
        const system_path = std.process.getEnvVarOwned(allocator, "GIT_CONFIG_SYSTEM") catch null;
        const sys_config_path: []const u8 = system_path orelse "/etc/gitconfig";
        defer if (system_path) |sp| allocator.free(sp);

        if (platform_impl.fs.readFile(allocator, sys_config_path)) |content| {
            defer allocator.free(content);
            if (git_helpers_mod.parseConfigValue(content, alias_key, allocator) catch null) |val| return val;
            if (git_helpers_mod.parseConfigValue(content, alias_subsection_key, allocator) catch null) |val| return val;
        } else |_| {}
    }

    return null;
}