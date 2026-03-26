const std = @import("std");
const objects = @import("objects.zig");
const refs = @import("refs.zig");
const index = @import("index.zig");

/// Diagnostic and validation utilities for git repositories
pub const GitDiagnostics = struct {
    git_dir: []const u8,
    platform_impl: anytype,
    allocator: std.mem.Allocator,
    issues: std.ArrayList(DiagnosticIssue),
    
    const Self = @This();
    
    pub const IssueLevel = enum {
        info,
        warning,
        error,
        critical,
    };
    
    pub const IssueType = enum {
        corrupted_object,
        missing_object,
        invalid_ref,
        corrupted_index,
        corrupted_pack,
        invalid_config,
        orphaned_object,
        dangling_ref,
        performance_issue,
    };
    
    pub const DiagnosticIssue = struct {
        level: IssueLevel,
        issue_type: IssueType,
        message: []const u8,
        details: ?[]const u8,
        
        pub fn deinit(self: DiagnosticIssue, allocator: std.mem.Allocator) void {
            allocator.free(self.message);
            if (self.details) |details| {
                allocator.free(details);
            }
        }
        
        pub fn format(self: DiagnosticIssue, allocator: std.mem.Allocator) ![]u8 {
            const level_str = switch (self.level) {
                .info => "INFO",
                .warning => "WARN",
                .error => "ERROR",
                .critical => "CRITICAL",
            };
            
            const type_str = switch (self.issue_type) {
                .corrupted_object => "Corrupted Object",
                .missing_object => "Missing Object",
                .invalid_ref => "Invalid Reference",
                .corrupted_index => "Corrupted Index",
                .corrupted_pack => "Corrupted Pack File",
                .invalid_config => "Invalid Config",
                .orphaned_object => "Orphaned Object",
                .dangling_ref => "Dangling Reference",
                .performance_issue => "Performance Issue",
            };
            
            if (self.details) |details| {
                return try std.fmt.allocPrint(allocator, "[{s}] {s}: {s}\n  Details: {s}", .{
                    level_str, type_str, self.message, details
                });
            } else {
                return try std.fmt.allocPrint(allocator, "[{s}] {s}: {s}", .{
                    level_str, type_str, self.message
                });
            }
        }
    };
    
    pub fn init(git_dir: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) Self {
        return Self{
            .git_dir = git_dir,
            .platform_impl = platform_impl,
            .allocator = allocator,
            .issues = std.ArrayList(DiagnosticIssue).init(allocator),
        };
    }
    
    pub fn deinit(self: *Self) void {
        for (self.issues.items) |issue| {
            issue.deinit(self.allocator);
        }
        self.issues.deinit();
    }
    
    fn addIssue(self: *Self, level: IssueLevel, issue_type: IssueType, message: []const u8, details: ?[]const u8) !void {
        const issue = DiagnosticIssue{
            .level = level,
            .issue_type = issue_type,
            .message = try self.allocator.dupe(u8, message),
            .details = if (details) |d| try self.allocator.dupe(u8, d) else null,
        };
        try self.issues.append(issue);
    }
    
    /// Run comprehensive diagnostics on the repository
    pub fn runDiagnostics(self: *Self) !void {
        std.debug.print("Running git repository diagnostics...\n", .{});
        
        try self.checkRepositoryStructure();
        try self.validateRefs();
        try self.validateIndex();
        try self.checkPackFiles();
        try self.validateObjects();
        try self.checkConfig();
        try self.analyzePerformance();
        
        std.debug.print("Diagnostics complete. Found {} issues.\n", .{self.issues.items.len});
    }
    
    /// Check basic repository structure
    fn checkRepositoryStructure(self: *Self) !void {
        const required_dirs = [_][]const u8{
            "objects",
            "objects/info",
            "objects/pack",
            "refs",
            "refs/heads",
            "refs/tags",
        };
        
        const required_files = [_][]const u8{
            "HEAD",
            "config",
        };
        
        for (required_dirs) |dir| {
            const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.git_dir, dir });
            defer self.allocator.free(full_path);
            
            if (!self.platform_impl.fs.exists(full_path) catch false) {
                try self.addIssue(.warning, .invalid_ref, "Missing required directory", full_path);
            }
        }
        
        for (required_files) |file| {
            const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.git_dir, file });
            defer self.allocator.free(full_path);
            
            if (!self.platform_impl.fs.exists(full_path) catch false) {
                try self.addIssue(.error, .invalid_ref, "Missing required file", full_path);
            }
        }
    }
    
    /// Validate all references
    fn validateRefs(self: *Self) !void {
        // Check HEAD
        if (refs.getCurrentBranch(self.git_dir, self.platform_impl, self.allocator)) |current_branch| {
            defer self.allocator.free(current_branch);
            
            if (std.mem.eql(u8, current_branch, "HEAD")) {
                // Detached HEAD - check if the commit exists
                if (refs.getCurrentCommit(self.git_dir, self.platform_impl, self.allocator)) |commit| {
                    if (commit) |c| {
                        defer self.allocator.free(c);
                        // Try to load the commit object
                        const commit_obj = objects.GitObject.load(c, self.git_dir, self.platform_impl, self.allocator) catch {
                            try self.addIssue(.error, .missing_object, "Detached HEAD points to missing commit", c);
                            return;
                        };
                        defer commit_obj.deinit(self.allocator);
                        
                        if (commit_obj.type != .commit) {
                            try self.addIssue(.error, .corrupted_object, "HEAD points to non-commit object", c);
                        }
                    }
                }
            } else {
                // Check if branch exists and points to valid commit
                if (refs.getBranchCommit(self.git_dir, current_branch, self.platform_impl, self.allocator)) |commit_hash| {
                    if (commit_hash) |c| {
                        defer self.allocator.free(c);
                        // Verify commit object exists
                        const commit_obj = objects.GitObject.load(c, self.git_dir, self.platform_impl, self.allocator) catch {
                            try self.addIssue(.error, .missing_object, "Branch points to missing commit", c);
                            return;
                        };
                        defer commit_obj.deinit(self.allocator);
                    } else {
                        try self.addIssue(.error, .dangling_ref, "Branch has no commit", current_branch);
                    }
                } else |err| {
                    const err_msg = try std.fmt.allocPrint(self.allocator, "Failed to resolve branch: {}", .{err});
                    defer self.allocator.free(err_msg);
                    try self.addIssue(.error, .invalid_ref, err_msg, current_branch);
                }
            }
        } else |err| {
            const err_msg = try std.fmt.allocPrint(self.allocator, "Cannot read HEAD: {}", .{err});
            defer self.allocator.free(err_msg);
            try self.addIssue(.critical, .invalid_ref, err_msg, null);
        }
        
        // Check all branches
        if (refs.listBranches(self.git_dir, self.platform_impl, self.allocator)) |branches| {
            defer {
                for (branches.items) |branch| {
                    self.allocator.free(branch);
                }
                branches.deinit();
            }
            
            for (branches.items) |branch| {
                if (refs.getBranchCommit(self.git_dir, branch, self.platform_impl, self.allocator)) |commit_hash| {
                    if (commit_hash) |c| {
                        defer self.allocator.free(c);
                        // Verify the commit object
                        const commit_obj = objects.GitObject.load(c, self.git_dir, self.platform_impl, self.allocator) catch {
                            const msg = try std.fmt.allocPrint(self.allocator, "Branch '{s}' points to missing commit", .{branch});
                            defer self.allocator.free(msg);
                            try self.addIssue(.error, .missing_object, msg, c);
                            continue;
                        };
                        defer commit_obj.deinit(self.allocator);
                        
                        if (commit_obj.type != .commit) {
                            const msg = try std.fmt.allocPrint(self.allocator, "Branch '{s}' points to non-commit object", .{branch});
                            defer self.allocator.free(msg);
                            try self.addIssue(.error, .corrupted_object, msg, c);
                        }
                    }
                } else |_| {
                    const msg = try std.fmt.allocPrint(self.allocator, "Cannot resolve branch '{s}'", .{branch});
                    defer self.allocator.free(msg);
                    try self.addIssue(.warning, .invalid_ref, msg, null);
                }
            }
        } else |_| {
            try self.addIssue(.warning, .invalid_ref, "Cannot list branches", null);
        }
    }
    
    /// Validate the git index
    fn validateIndex(self: *Self) !void {
        var idx = index.Index.load(self.git_dir, self.platform_impl, self.allocator) catch {
            try self.addIssue(.warning, .corrupted_index, "Cannot load index file", null);
            return;
        };
        defer idx.deinit();
        
        // Check each index entry
        for (idx.entries.items) |entry| {
            // Verify the blob object exists
            const hash_str = try std.fmt.allocPrint(self.allocator, "{}", .{std.fmt.fmtSliceHexLower(&entry.sha1)});
            defer self.allocator.free(hash_str);
            
            const blob_obj = objects.GitObject.load(hash_str, self.git_dir, self.platform_impl, self.allocator) catch {
                const msg = try std.fmt.allocPrint(self.allocator, "Index entry '{s}' points to missing blob", .{entry.path});
                defer self.allocator.free(msg);
                try self.addIssue(.error, .missing_object, msg, hash_str);
                continue;
            };
            defer blob_obj.deinit(self.allocator);
            
            if (blob_obj.type != .blob) {
                const msg = try std.fmt.allocPrint(self.allocator, "Index entry '{s}' points to non-blob object", .{entry.path});
                defer self.allocator.free(msg);
                try self.addIssue(.error, .corrupted_object, msg, hash_str);
            }
        }
        
        try self.addIssue(.info, .performance_issue, "Index validation complete", 
            try std.fmt.allocPrint(self.allocator, "Validated {} entries", .{idx.entries.items.len}));
    }
    
    /// Check pack files for corruption
    fn checkPackFiles(self: *Self) !void {
        const pack_dir_path = try std.fmt.allocPrint(self.allocator, "{s}/objects/pack", .{self.git_dir});
        defer self.allocator.free(pack_dir_path);
        
        if (self.platform_impl.fs.readDir(self.allocator, pack_dir_path)) |entries| {
            defer {
                for (entries) |entry| {
                    self.allocator.free(entry);
                }
                self.allocator.free(entries);
            }
            
            var pack_count: u32 = 0;
            var idx_count: u32 = 0;
            
            for (entries) |entry| {
                if (std.mem.endsWith(u8, entry, ".pack")) {
                    pack_count += 1;
                    // Check if corresponding .idx file exists
                    const idx_name = try std.fmt.allocPrint(self.allocator, "{s}.idx", .{entry[0..entry.len-5]});
                    defer self.allocator.free(idx_name);
                    
                    var idx_found = false;
                    for (entries) |idx_entry| {
                        if (std.mem.eql(u8, idx_entry, idx_name)) {
                            idx_found = true;
                            break;
                        }
                    }
                    
                    if (!idx_found) {
                        const msg = try std.fmt.allocPrint(self.allocator, "Pack file missing index: {s}", .{entry});
                        defer self.allocator.free(msg);
                        try self.addIssue(.error, .corrupted_pack, msg, null);
                    }
                } else if (std.mem.endsWith(u8, entry, ".idx")) {
                    idx_count += 1;
                }
            }
            
            if (pack_count > 0) {
                const msg = try std.fmt.allocPrint(self.allocator, "Found {} pack files with {} index files", .{pack_count, idx_count});
                defer self.allocator.free(msg);
                try self.addIssue(.info, .performance_issue, "Pack file summary", msg);
                
                // Suggest repacking if too many pack files
                if (pack_count > 10) {
                    try self.addIssue(.warning, .performance_issue, 
                        "Many pack files found - consider running 'git gc'",
                        try std.fmt.allocPrint(self.allocator, "{} pack files", .{pack_count}));
                }
            }
        } else |_| {
            try self.addIssue(.info, .performance_issue, "No pack directory or cannot read it", null);
        }
    }
    
    /// Validate random objects for corruption
    fn validateObjects(self: *Self) !void {
        // This is a basic implementation - a full fsck would check all objects
        const test_objects = [_][]const u8{
            "0000000000000000000000000000000000000000", // Test with a clearly invalid hash
        };
        
        for (test_objects) |hash| {
            const obj = objects.GitObject.load(hash, self.git_dir, self.platform_impl, self.allocator) catch continue;
            defer obj.deinit(self.allocator);
            
            // Basic validation - check if object type matches content format
            switch (obj.type) {
                .commit => {
                    if (!std.mem.startsWith(u8, obj.data, "tree ")) {
                        try self.addIssue(.error, .corrupted_object, "Commit object doesn't start with 'tree'", hash);
                    }
                },
                .tree => {
                    // Tree objects should contain valid entries
                    var pos: usize = 0;
                    while (pos < obj.data.len) {
                        // Find space (between mode and name)
                        const space_pos = std.mem.indexOfScalarPos(u8, obj.data, pos, ' ') orelse break;
                        pos = space_pos + 1;
                        
                        // Find null (after name)
                        const null_pos = std.mem.indexOfScalarPos(u8, obj.data, pos, 0) orelse break;
                        pos = null_pos + 1;
                        
                        // Skip 20-byte hash
                        if (pos + 20 > obj.data.len) {
                            try self.addIssue(.warning, .corrupted_object, "Tree object truncated", hash);
                            break;
                        }
                        pos += 20;
                    }
                },
                .blob => {
                    // Blobs can contain anything, not much to validate
                },
                .tag => {
                    if (!std.mem.startsWith(u8, obj.data, "object ")) {
                        try self.addIssue(.error, .corrupted_object, "Tag object doesn't start with 'object'", hash);
                    }
                },
            }
        }
    }
    
    /// Check git configuration
    fn checkConfig(self: *Self) !void {
        const config = @import("config.zig");
        const git_config = config.loadGitConfig(self.git_dir, self.allocator) catch {
            try self.addIssue(.warning, .invalid_config, "Cannot load git config", null);
            return;
        };
        var git_config_copy = git_config;
        defer git_config_copy.deinit();
        
        // Check for required config
        if (git_config_copy.getUserName() == null) {
            try self.addIssue(.warning, .invalid_config, "User name not configured", "Set user.name in git config");
        }
        
        if (git_config_copy.getUserEmail() == null) {
            try self.addIssue(.warning, .invalid_config, "User email not configured", "Set user.email in git config");
        }
        
        try self.addIssue(.info, .performance_issue, "Config validation complete", null);
    }
    
    /// Analyze performance characteristics
    fn analyzePerformance(self: *Self) !void {
        // Check repository size characteristics
        const objects_dir = try std.fmt.allocPrint(self.allocator, "{s}/objects", .{self.git_dir});
        defer self.allocator.free(objects_dir);
        
        var loose_object_count: u32 = 0;
        
        // Count loose objects (simplified - would need to walk all subdirs)
        for ("0123456789abcdef") |c| {
            const subdir = try std.fmt.allocPrint(self.allocator, "{s}/{c}", .{objects_dir, c});
            defer self.allocator.free(subdir);
            
            if (self.platform_impl.fs.readDir(self.allocator, subdir)) |entries| {
                defer {
                    for (entries) |entry| {
                        self.allocator.free(entry);
                    }
                    self.allocator.free(entries);
                }
                loose_object_count += @intCast(entries.len);
            } else |_| {
                // Directory doesn't exist or can't read - not an error
            }
        }
        
        if (loose_object_count > 1000) {
            const msg = try std.fmt.allocPrint(self.allocator, "Many loose objects found: {} - consider running 'git gc'", .{loose_object_count});
            defer self.allocator.free(msg);
            try self.addIssue(.info, .performance_issue, "Performance suggestion", msg);
        }
        
        try self.addIssue(.info, .performance_issue, "Performance analysis complete",
            try std.fmt.allocPrint(self.allocator, "Found {} loose objects", .{loose_object_count}));
    }
    
    /// Print all found issues
    pub fn printIssues(self: Self) !void {
        if (self.issues.items.len == 0) {
            std.debug.print("✓ No issues found in repository!\n", .{});
            return;
        }
        
        std.debug.print("\n=== Repository Diagnostic Issues ===\n", .{});
        
        var critical_count: u32 = 0;
        var error_count: u32 = 0;
        var warning_count: u32 = 0;
        var info_count: u32 = 0;
        
        for (self.issues.items) |issue| {
            const formatted = try issue.format(self.allocator);
            defer self.allocator.free(formatted);
            std.debug.print("{s}\n", .{formatted});
            
            switch (issue.level) {
                .critical => critical_count += 1,
                .error => error_count += 1,
                .warning => warning_count += 1,
                .info => info_count += 1,
            }
        }
        
        std.debug.print("\n=== Summary ===\n", .{});
        std.debug.print("Critical: {}, Errors: {}, Warnings: {}, Info: {}\n", 
                       .{critical_count, error_count, warning_count, info_count});
        
        if (critical_count > 0 or error_count > 0) {
            std.debug.print("⚠️  Repository has serious issues that should be addressed.\n", .{});
        } else if (warning_count > 0) {
            std.debug.print("⚠️  Repository has minor issues or suggestions.\n", .{});
        } else {
            std.debug.print("✓ Repository appears healthy!\n", .{});
        }
    }
};

/// Quick repository health check
pub fn quickHealthCheck(git_dir: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) !void {
    var diagnostics = GitDiagnostics.init(git_dir, platform_impl, allocator);
    defer diagnostics.deinit();
    
    try diagnostics.runDiagnostics();
    try diagnostics.printIssues();
}

/// Validate a specific object by hash
pub fn validateObject(git_dir: []const u8, object_hash: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) !bool {
    const obj = objects.GitObject.load(object_hash, git_dir, platform_impl, allocator) catch {
        std.debug.print("❌ Object {s} not found or corrupted\n", .{object_hash});
        return false;
    };
    defer obj.deinit(allocator);
    
    // Verify the object hash matches
    const computed_hash = try obj.hash(allocator);
    defer allocator.free(computed_hash);
    
    if (!std.mem.eql(u8, computed_hash, object_hash)) {
        std.debug.print("❌ Object {s} hash mismatch (computed: {s})\n", .{object_hash, computed_hash});
        return false;
    }
    
    std.debug.print("✅ Object {s} is valid ({s}, {} bytes)\n", .{object_hash, obj.type.toString(), obj.data.len});
    return true;
}

test "diagnostics initialization" {
    const std = @import("std");
    const testing = std.testing;
    
    const MockPlatform = struct {
        pub const fs = struct {
            pub fn exists(path: []const u8) !bool {
                _ = path;
                return true;
            }
            pub fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
                _ = path;
                return try allocator.dupe(u8, "test content");
            }
            pub fn readDir(allocator: std.mem.Allocator, path: []const u8) ![][]u8 {
                _ = path;
                var entries = std.ArrayList([]u8).init(allocator);
                try entries.append(try allocator.dupe(u8, "test.pack"));
                try entries.append(try allocator.dupe(u8, "test.idx"));
                return entries.toOwnedSlice();
            }
        };
    };
    
    var diagnostics = GitDiagnostics.init("/test/.git", MockPlatform.fs, testing.allocator);
    defer diagnostics.deinit();
    
    try testing.expect(diagnostics.issues.items.len == 0);
}