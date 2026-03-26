const std = @import("std");
const refs = @import("refs.zig");

/// Advanced reference management with enhanced features
pub const AdvancedRefs = struct {
    git_dir: []const u8,
    allocator: std.mem.Allocator,
    ref_cache: std.HashMap([]const u8, CachedRef, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    
    pub fn init(allocator: std.mem.Allocator, git_dir: []const u8) !AdvancedRefs {
        return AdvancedRefs{
            .git_dir = try allocator.dupe(u8, git_dir),
            .allocator = allocator,
            .ref_cache = std.HashMap([]const u8, CachedRef, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
        };
    }
    
    pub fn deinit(self: *AdvancedRefs) void {
        // Clear cache
        var iter = self.ref_cache.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.ref_cache.deinit();
        
        self.allocator.free(self.git_dir);
    }
    
    /// Resolve ref with caching and enhanced error handling
    pub fn resolveRefCached(self: *AdvancedRefs, ref_name: []const u8, platform_impl: anytype) !?[]u8 {
        // Check cache first
        if (self.ref_cache.get(ref_name)) |cached| {
            const current_time = std.time.timestamp();
            if (current_time - cached.timestamp < 60) { // 1 minute cache
                if (cached.hash) |hash| {
                    return try self.allocator.dupe(u8, hash);
                } else {
                    return null;
                }
            }
        }
        
        // Resolve ref and update cache
        const resolved = refs.resolveRef(self.git_dir, ref_name, platform_impl, self.allocator) catch |err| switch (err) {
            error.RefNotFound => null,
            else => return err,
        };
        
        // Update cache
        const cache_key = try self.allocator.dupe(u8, ref_name);
        const cached_ref = CachedRef{
            .hash = if (resolved) |hash| try self.allocator.dupe(u8, hash) else null,
            .timestamp = std.time.timestamp(),
        };
        
        try self.ref_cache.put(cache_key, cached_ref);
        
        return resolved;
    }
    
    /// Get comprehensive ref information
    pub fn getRefInfo(self: *AdvancedRefs, ref_name: []const u8, platform_impl: anytype) !RefInfo {
        var info = RefInfo{
            .name = try self.allocator.dupe(u8, ref_name),
            .hash = null,
            .target = null,
            .is_symbolic = false,
            .is_tag = false,
            .is_branch = false,
            .is_remote = false,
            .object_type = null,
        };
        
        // Determine ref type
        if (std.mem.startsWith(u8, ref_name, "refs/heads/")) {
            info.is_branch = true;
        } else if (std.mem.startsWith(u8, ref_name, "refs/tags/")) {
            info.is_tag = true;
        } else if (std.mem.startsWith(u8, ref_name, "refs/remotes/")) {
            info.is_remote = true;
        }
        
        // Resolve the reference
        const resolved = self.resolveRefCached(ref_name, platform_impl) catch |err| switch (err) {
            error.RefNotFound => return info,
            else => return err,
        };
        
        if (resolved) |hash| {
            info.hash = hash;
            
            // Determine object type by loading the object
            const objects = @import("objects.zig");
            const obj = objects.GitObject.load(hash, self.git_dir, platform_impl, self.allocator) catch |err| switch (err) {
                error.ObjectNotFound => {
                    info.object_type = .unknown;
                    return info;
                },
                else => return err,
            };
            defer obj.deinit(self.allocator);
            
            info.object_type = switch (obj.type) {
                .blob => .blob,
                .tree => .tree,
                .commit => .commit,
                .tag => .tag,
            };
        }
        
        return info;
    }
    
    /// Get all references with their information
    pub fn getAllRefs(self: *AdvancedRefs, platform_impl: anytype) !std.ArrayList(RefInfo) {
        var all_refs = std.ArrayList(RefInfo).init(self.allocator);
        
        const ref_dirs = [_][]const u8{ "refs/heads", "refs/tags", "refs/remotes" };
        
        for (ref_dirs) |ref_dir| {
            const full_ref_dir = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.git_dir, ref_dir });
            defer self.allocator.free(full_ref_dir);
            
            const entries = platform_impl.fs.readDir(self.allocator, full_ref_dir) catch |err| switch (err) {
                error.FileNotFound, error.NotSupported => continue,
                else => return err,
            };
            defer {
                for (entries) |entry| {
                    self.allocator.free(entry);
                }
                self.allocator.free(entries);
            }
            
            for (entries) |entry| {
                const full_ref_name = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ ref_dir, entry });
                defer self.allocator.free(full_ref_name);
                
                const ref_info = self.getRefInfo(full_ref_name, platform_impl) catch |err| {
                    std.debug.print("Warning: Failed to get info for ref {s}: {}\n", .{ full_ref_name, err });
                    continue;
                };
                
                try all_refs.append(ref_info);
            }
        }
        
        // Also check HEAD
        const head_info = self.getRefInfo("HEAD", platform_impl) catch |err| {
            std.debug.print("Warning: Failed to get HEAD info: {}\n", .{err});
            return all_refs;
        };
        try all_refs.append(head_info);
        
        // Check packed-refs for additional refs
        try self.addPackedRefs(&all_refs, platform_impl);
        
        return all_refs;
    }
    
    /// Add refs from packed-refs file
    fn addPackedRefs(self: *AdvancedRefs, all_refs: *std.ArrayList(RefInfo), platform_impl: anytype) !void {
        const packed_refs_path = try std.fmt.allocPrint(self.allocator, "{s}/packed-refs", .{self.git_dir});
        defer self.allocator.free(packed_refs_path);

        const content = platform_impl.fs.readFile(self.allocator, packed_refs_path) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.allocator.free(content);

        var lines = std.mem.split(u8, content, "\n");
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            
            // Skip comments and empty lines
            if (trimmed.len == 0 or trimmed[0] == '#') continue;
            
            // Skip peeled refs
            if (trimmed[0] == '^') continue;
            
            // Format: "<hash> <ref_name>"
            if (std.mem.indexOf(u8, trimmed, " ")) |space_pos| {
                const hash = trimmed[0..space_pos];
                const ref_path = trimmed[space_pos + 1..];
                
                // Check if we already have this ref
                var found = false;
                for (all_refs.items) |existing_ref| {
                    if (std.mem.eql(u8, existing_ref.name, ref_path)) {
                        found = true;
                        break;
                    }
                }
                
                if (!found and refs.isValidHash(hash)) {
                    var info = RefInfo{
                        .name = try self.allocator.dupe(u8, ref_path),
                        .hash = try self.allocator.dupe(u8, hash),
                        .target = null,
                        .is_symbolic = false,
                        .is_tag = std.mem.startsWith(u8, ref_path, "refs/tags/"),
                        .is_branch = std.mem.startsWith(u8, ref_path, "refs/heads/"),
                        .is_remote = std.mem.startsWith(u8, ref_path, "refs/remotes/"),
                        .object_type = .unknown, // We could determine this, but it's expensive
                    };
                    
                    try all_refs.append(info);
                }
            }
        }
    }
    
    /// Find dangling references (refs that point to non-existent objects)
    pub fn findDanglingRefs(self: *AdvancedRefs, platform_impl: anytype) !std.ArrayList(DanglingRef) {
        var dangling = std.ArrayList(DanglingRef).init(self.allocator);
        
        var all_refs = try self.getAllRefs(platform_impl);
        defer {
            for (all_refs.items) |*ref_info| {
                ref_info.deinit(self.allocator);
            }
            all_refs.deinit();
        }
        
        const objects = @import("objects.zig");
        
        for (all_refs.items) |ref_info| {
            if (ref_info.hash) |hash| {
                // Try to load the object
                const obj = objects.GitObject.load(hash, self.git_dir, platform_impl, self.allocator) catch |err| switch (err) {
                    error.ObjectNotFound => {
                        try dangling.append(DanglingRef{
                            .ref_name = try self.allocator.dupe(u8, ref_info.name),
                            .hash = try self.allocator.dupe(u8, hash),
                            .error_type = .object_not_found,
                        });
                        continue;
                    },
                    error.InvalidObject => {
                        try dangling.append(DanglingRef{
                            .ref_name = try self.allocator.dupe(u8, ref_info.name),
                            .hash = try self.allocator.dupe(u8, hash),
                            .error_type = .invalid_object,
                        });
                        continue;
                    },
                    else => return err,
                };
                obj.deinit(self.allocator);
            }
        }
        
        return dangling;
    }
    
    /// Prune dangling references
    pub fn pruneDanglingRefs(self: *AdvancedRefs, platform_impl: anytype, dry_run: bool) !u32 {
        const dangling = try self.findDanglingRefs(platform_impl);
        defer {
            for (dangling.items) |*dang| {
                dang.deinit(self.allocator);
            }
            dangling.deinit();
        }
        
        if (dry_run) {
            std.debug.print("Would prune {} dangling references:\n", .{dangling.items.len});
            for (dangling.items) |dang| {
                std.debug.print("  {s} -> {s} ({})\n", .{ dang.ref_name, dang.hash, dang.error_type });
            }
            return @intCast(dangling.items.len);
        }
        
        var pruned: u32 = 0;
        for (dangling.items) |dang| {
            // Only prune if it's safe to do so
            if (dang.error_type == .object_not_found) {
                const ref_path = if (std.mem.eql(u8, dang.ref_name, "HEAD"))
                    try std.fmt.allocPrint(self.allocator, "{s}/HEAD", .{self.git_dir})
                else
                    try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.git_dir, dang.ref_name });
                defer self.allocator.free(ref_path);
                
                platform_impl.fs.deleteFile(ref_path) catch |err| {
                    std.debug.print("Failed to delete ref {s}: {}\n", .{ dang.ref_name, err });
                    continue;
                };
                
                std.debug.print("Pruned dangling ref: {s}\n", .{dang.ref_name});
                pruned += 1;
            }
        }
        
        // Clear cache since we modified refs
        self.clearCache();
        
        return pruned;
    }
    
    /// Clear the reference cache
    pub fn clearCache(self: *AdvancedRefs) void {
        var iter = self.ref_cache.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.ref_cache.clearAndFree();
    }
    
    /// Get reference statistics
    pub fn getRefStats(self: *AdvancedRefs, platform_impl: anytype) !RefStats {
        var all_refs = try self.getAllRefs(platform_impl);
        defer {
            for (all_refs.items) |*ref_info| {
                ref_info.deinit(self.allocator);
            }
            all_refs.deinit();
        }
        
        var stats = RefStats{
            .total_refs = all_refs.items.len,
            .branches = 0,
            .tags = 0,
            .remotes = 0,
            .symbolic_refs = 0,
            .packed_refs = 0,
        };
        
        for (all_refs.items) |ref_info| {
            if (ref_info.is_branch) stats.branches += 1;
            if (ref_info.is_tag) stats.tags += 1;
            if (ref_info.is_remote) stats.remotes += 1;
            if (ref_info.is_symbolic) stats.symbolic_refs += 1;
        }
        
        // Count packed refs
        const packed_refs_path = try std.fmt.allocPrint(self.allocator, "{s}/packed-refs", .{self.git_dir});
        defer self.allocator.free(packed_refs_path);

        const content = platform_impl.fs.readFile(self.allocator, packed_refs_path) catch |err| switch (err) {
            error.FileNotFound => return stats,
            else => return err,
        };
        defer self.allocator.free(content);

        var lines = std.mem.split(u8, content, "\n");
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len > 0 and trimmed[0] != '#' and trimmed[0] != '^') {
                if (std.mem.indexOf(u8, trimmed, " ")) |_| {
                    stats.packed_refs += 1;
                }
            }
        }
        
        return stats;
    }
};

/// Cached reference entry
const CachedRef = struct {
    hash: ?[]const u8,
    timestamp: i64,
    
    fn deinit(self: CachedRef, allocator: std.mem.Allocator) void {
        if (self.hash) |hash| {
            allocator.free(hash);
        }
    }
};

/// Reference information structure
pub const RefInfo = struct {
    name: []const u8,
    hash: ?[]const u8,
    target: ?[]const u8,
    is_symbolic: bool,
    is_tag: bool,
    is_branch: bool,
    is_remote: bool,
    object_type: ?ObjectType,
    
    pub fn deinit(self: *RefInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.hash) |hash| allocator.free(hash);
        if (self.target) |target| allocator.free(target);
    }
};

/// Object type enum
const ObjectType = enum {
    blob,
    tree,
    commit,
    tag,
    unknown,
};

/// Dangling reference
const DanglingRef = struct {
    ref_name: []const u8,
    hash: []const u8,
    error_type: enum { object_not_found, invalid_object },
    
    fn deinit(self: *DanglingRef, allocator: std.mem.Allocator) void {
        allocator.free(self.ref_name);
        allocator.free(self.hash);
    }
};

/// Reference statistics
pub const RefStats = struct {
    total_refs: usize,
    branches: usize,
    tags: usize,
    remotes: usize,
    symbolic_refs: usize,
    packed_refs: usize,
};

/// Validate all references in a repository
pub fn validateAllRefs(git_dir: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) !RefValidationResult {
    var adv_refs = try AdvancedRefs.init(allocator, git_dir);
    defer adv_refs.deinit();
    
    const stats = try adv_refs.getRefStats(platform_impl);
    const dangling = try adv_refs.findDanglingRefs(platform_impl);
    defer {
        for (dangling.items) |*dang| {
            dang.deinit(allocator);
        }
        dangling.deinit();
    }
    
    return RefValidationResult{
        .stats = stats,
        .dangling_count = dangling.items.len,
        .is_healthy = dangling.items.len == 0,
    };
}

/// Reference validation result
pub const RefValidationResult = struct {
    stats: RefStats,
    dangling_count: usize,
    is_healthy: bool,
};

test "advanced refs basic functionality" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    // Test RefInfo structure
    var ref_info = RefInfo{
        .name = try allocator.dupe(u8, "refs/heads/main"),
        .hash = try allocator.dupe(u8, "1234567890abcdef1234567890abcdef12345678"),
        .target = null,
        .is_symbolic = false,
        .is_tag = false,
        .is_branch = true,
        .is_remote = false,
        .object_type = .commit,
    };
    defer ref_info.deinit(allocator);
    
    try testing.expect(ref_info.is_branch);
    try testing.expect(!ref_info.is_tag);
    try testing.expectEqualStrings("refs/heads/main", ref_info.name);
}