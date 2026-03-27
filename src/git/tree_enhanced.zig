const std = @import("std");
const objects = @import("objects.zig");
const platform_mod = @import("../platform/platform.zig");

/// Git tree entry representing a file or directory
pub const TreeEntry = struct {
    mode: FileMode,
    name: []const u8,
    hash: [20]u8,
    
    pub fn init(mode: FileMode, name: []const u8, hash: [20]u8) TreeEntry {
        return TreeEntry{
            .mode = mode,
            .name = name,
            .hash = hash,
        };
    }
    
    pub fn deinit(self: TreeEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
    
    /// Get the hash as a hex string
    pub fn getHashString(self: TreeEntry, allocator: std.mem.Allocator) ![]u8 {
        return try std.fmt.allocPrint(allocator, "{s}", .{std.fmt.fmtSliceHexLower(&self.hash)});
    }
    
    /// Check if this entry represents a directory
    pub fn isDirectory(self: TreeEntry) bool {
        return self.mode == .directory;
    }
    
    /// Check if this entry represents a regular file
    pub fn isFile(self: TreeEntry) bool {
        return self.mode == .regular_file or self.mode == .executable_file;
    }
    
    /// Check if this entry represents a symlink
    pub fn isSymlink(self: TreeEntry) bool {
        return self.mode == .symlink;
    }
    
    /// Check if this entry represents a submodule
    pub fn isSubmodule(self: TreeEntry) bool {
        return self.mode == .gitlink;
    }
};

/// Git file modes
pub const FileMode = enum(u32) {
    directory = 0o040000,
    regular_file = 0o100644,
    executable_file = 0o100755,
    symlink = 0o120000,
    gitlink = 0o160000, // submodule
    
    pub fn fromString(mode_str: []const u8) !FileMode {
        const mode_int = try std.fmt.parseInt(u32, mode_str, 8);
        return switch (mode_int) {
            0o040000 => .directory,
            0o100644 => .regular_file,
            0o100755 => .executable_file,
            0o120000 => .symlink,
            0o160000 => .gitlink,
            else => return error.InvalidFileMode,
        };
    }
    
    pub fn toString(self: FileMode) []const u8 {
        return switch (self) {
            .directory => "040000",
            .regular_file => "100644",
            .executable_file => "100755",
            .symlink => "120000",
            .gitlink => "160000",
        };
    }
    
    pub fn toInt(self: FileMode) u32 {
        return @intFromEnum(self);
    }
};

/// Git tree object
pub const GitTree = struct {
    entries: std.ArrayList(TreeEntry),
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) GitTree {
        return GitTree{
            .entries = std.ArrayList(TreeEntry).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *GitTree) void {
        for (self.entries.items) |entry| {
            entry.deinit(self.allocator);
        }
        self.entries.deinit();
    }
    
    /// Parse tree object from raw data
    pub fn parseFromData(data: []const u8, allocator: std.mem.Allocator) !GitTree {
        var tree = GitTree.init(allocator);
        errdefer tree.deinit();
        
        var pos: usize = 0;
        
        while (pos < data.len) {
            // Find space after mode
            const space_pos = std.mem.indexOfScalarPos(u8, data, pos, ' ') orelse 
                return error.InvalidTreeFormat;
            
            // Parse mode
            const mode_str = data[pos..space_pos];
            const mode = FileMode.fromString(mode_str) catch return error.InvalidFileMode;
            pos = space_pos + 1;
            
            // Find null terminator after filename
            const null_pos = std.mem.indexOfScalarPos(u8, data, pos, 0) orelse 
                return error.InvalidTreeFormat;
            
            // Parse filename
            const name = try allocator.dupe(u8, data[pos..null_pos]);
            pos = null_pos + 1;
            
            // Parse SHA-1 hash (20 bytes)
            if (pos + 20 > data.len) return error.InvalidTreeFormat;
            var hash: [20]u8 = undefined;
            @memcpy(&hash, data[pos..pos + 20]);
            pos += 20;
            
            try tree.entries.append(TreeEntry.init(mode, name, hash));
        }
        
        // Sort entries for consistent output (git sorts them)
        std.sort.block(TreeEntry, tree.entries.items, {}, compareEntries);
        
        return tree;
    }
    
    /// Serialize tree to git object data format
    pub fn serialize(self: GitTree, allocator: std.mem.Allocator) ![]u8 {
        var result = std.ArrayList(u8).init(allocator);
        defer result.deinit();
        
        for (self.entries.items) |entry| {
            // Write mode
            try result.appendSlice(entry.mode.toString());
            try result.append(' ');
            
            // Write name
            try result.appendSlice(entry.name);
            try result.append(0);
            
            // Write hash
            try result.appendSlice(&entry.hash);
        }
        
        return try allocator.dupe(u8, result.items);
    }
    
    /// Add an entry to the tree
    pub fn addEntry(self: *GitTree, mode: FileMode, name: []const u8, hash: [20]u8) !void {
        const name_copy = try self.allocator.dupe(u8, name);
        try self.entries.append(TreeEntry.init(mode, name_copy, hash));
        
        // Keep entries sorted
        std.sort.block(TreeEntry, self.entries.items, {}, compareEntries);
    }
    
    /// Find entry by name
    pub fn findEntry(self: GitTree, name: []const u8) ?TreeEntry {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.name, name)) {
                return entry;
            }
        }
        return null;
    }
    
    /// Remove entry by name
    pub fn removeEntry(self: *GitTree, name: []const u8) bool {
        for (self.entries.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.name, name)) {
                entry.deinit(self.allocator);
                _ = self.entries.swapRemove(i);
                return true;
            }
        }
        return false;
    }
    
    /// Get all file entries (non-directories)
    pub fn getFiles(self: GitTree, allocator: std.mem.Allocator) !std.ArrayList(TreeEntry) {
        var files = std.ArrayList(TreeEntry).init(allocator);
        
        for (self.entries.items) |entry| {
            if (entry.isFile() or entry.isSymlink()) {
                try files.append(entry);
            }
        }
        
        return files;
    }
    
    /// Get all directory entries
    pub fn getDirectories(self: GitTree, allocator: std.mem.Allocator) !std.ArrayList(TreeEntry) {
        var dirs = std.ArrayList(TreeEntry).init(allocator);
        
        for (self.entries.items) |entry| {
            if (entry.isDirectory()) {
                try dirs.append(entry);
            }
        }
        
        return dirs;
    }
    
    /// Generate a formatted tree listing
    pub fn formatListing(self: GitTree, allocator: std.mem.Allocator) ![]u8 {
        var result = std.ArrayList(u8).init(allocator);
        defer result.deinit();
        
        for (self.entries.items) |entry| {
            const hash_str = try entry.getHashString(allocator);
            defer allocator.free(hash_str);
            
            const type_str = if (entry.isDirectory()) 
                "tree" 
            else if (entry.isFile()) 
                "blob" 
            else if (entry.isSymlink()) 
                "blob" 
            else if (entry.isSubmodule()) 
                "commit" 
            else 
                "unknown";
            
            try result.writer().print("{s} {} {s}\t{s}\n", .{
                entry.mode.toString(),
                type_str,
                hash_str,
                entry.name,
            });
        }
        
        return try result.toOwnedSlice();
    }
};

/// Compare function for sorting tree entries (git order)
fn compareEntries(context: void, a: TreeEntry, b: TreeEntry) bool {
    _ = context;
    
    // Git sorts entries by name, but directories get a trailing /
    const a_name = if (a.isDirectory()) 
        a.name ++ "/" 
    else 
        a.name;
    const b_name = if (b.isDirectory()) 
        b.name ++ "/" 
    else 
        b.name;
    
    return std.mem.order(u8, a_name, b_name) == .lt;
}

/// Tree walker for recursive traversal
pub const TreeWalker = struct {
    git_dir: []const u8,
    platform_impl: *const platform_mod.Platform,
    allocator: std.mem.Allocator,
    
    pub fn init(git_dir: []const u8, platform_impl: *const platform_mod.Platform, allocator: std.mem.Allocator) TreeWalker {
        return TreeWalker{
            .git_dir = git_dir,
            .platform_impl = platform_impl,
            .allocator = allocator,
        };
    }
    
    /// Walk tree recursively and call visitor for each entry
    pub fn walk(self: TreeWalker, tree_hash: []const u8, visitor: anytype, context: anytype) !void {
        try self.walkRecursive(tree_hash, "", visitor, context, 0);
    }
    
    fn walkRecursive(self: TreeWalker, tree_hash: []const u8, path_prefix: []const u8, visitor: anytype, context: anytype, depth: u32) !void {
        // Prevent infinite recursion
        if (depth > 1000) return error.MaxDepthExceeded;
        
        // Load tree object
        const tree_obj = try objects.GitObject.load(tree_hash, self.git_dir, self.platform_impl, self.allocator);
        defer tree_obj.deinit(self.allocator);
        
        if (tree_obj.type != .tree) return error.NotATree;
        
        var tree = try GitTree.parseFromData(tree_obj.data, self.allocator);
        defer tree.deinit();
        
        for (tree.entries.items) |entry| {
            const full_path = if (path_prefix.len > 0) 
                try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{path_prefix, entry.name})
            else 
                try self.allocator.dupe(u8, entry.name);
            defer self.allocator.free(full_path);
            
            // Call visitor
            try visitor(context, full_path, entry);
            
            // Recurse into subdirectories
            if (entry.isDirectory()) {
                const entry_hash_str = try entry.getHashString(self.allocator);
                defer self.allocator.free(entry_hash_str);
                
                try self.walkRecursive(entry_hash_str, full_path, visitor, context, depth + 1);
            }
        }
    }
};

/// Tree difference result
pub const TreeDiff = struct {
    added: std.ArrayList(TreeEntry),
    modified: std.ArrayList(struct { old: TreeEntry, new: TreeEntry }),
    deleted: std.ArrayList(TreeEntry),
    
    pub fn init(allocator: std.mem.Allocator) TreeDiff {
        return TreeDiff{
            .added = std.ArrayList(TreeEntry).init(allocator),
            .modified = std.ArrayList(struct { old: TreeEntry, new: TreeEntry }).init(allocator),
            .deleted = std.ArrayList(TreeEntry).init(allocator),
        };
    }
    
    pub fn deinit(self: *TreeDiff, allocator: std.mem.Allocator) void {
        for (self.added.items) |entry| {
            entry.deinit(allocator);
        }
        self.added.deinit();
        
        for (self.modified.items) |mod| {
            mod.old.deinit(allocator);
            mod.new.deinit(allocator);
        }
        self.modified.deinit();
        
        for (self.deleted.items) |entry| {
            entry.deinit(allocator);
        }
        self.deleted.deinit();
    }
};

/// Compare two trees and return differences
pub fn diffTrees(old_tree: GitTree, new_tree: GitTree, allocator: std.mem.Allocator) !TreeDiff {
    var diff = TreeDiff.init(allocator);
    errdefer diff.deinit(allocator);
    
    // Create maps for efficient lookup
    var old_map = std.StringHashMap(TreeEntry).init(allocator);
    defer old_map.deinit();
    var new_map = std.StringHashMap(TreeEntry).init(allocator);
    defer new_map.deinit();
    
    for (old_tree.entries.items) |entry| {
        try old_map.put(entry.name, entry);
    }
    
    for (new_tree.entries.items) |entry| {
        try new_map.put(entry.name, entry);
    }
    
    // Find added and modified entries
    for (new_tree.entries.items) |new_entry| {
        if (old_map.get(new_entry.name)) |old_entry| {
            // Entry exists in both trees
            if (!std.mem.eql(u8, &old_entry.hash, &new_entry.hash)) {
                // Hash changed - modified
                try diff.modified.append(.{
                    .old = TreeEntry.init(old_entry.mode, try allocator.dupe(u8, old_entry.name), old_entry.hash),
                    .new = TreeEntry.init(new_entry.mode, try allocator.dupe(u8, new_entry.name), new_entry.hash),
                });
            }
        } else {
            // Entry only in new tree - added
            try diff.added.append(TreeEntry.init(new_entry.mode, try allocator.dupe(u8, new_entry.name), new_entry.hash));
        }
    }
    
    // Find deleted entries
    for (old_tree.entries.items) |old_entry| {
        if (!new_map.contains(old_entry.name)) {
            // Entry only in old tree - deleted
            try diff.deleted.append(TreeEntry.init(old_entry.mode, try allocator.dupe(u8, old_entry.name), old_entry.hash));
        }
    }
    
    return diff;
}

/// Build a tree from a directory structure
pub fn buildTreeFromDirectory(dir_path: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) !GitTree {
    var tree = GitTree.init(allocator);
    errdefer tree.deinit();
    
    // This would require implementing directory traversal
    // For now, return empty tree as placeholder
    _ = dir_path;
    _ = platform_impl;
    
    return tree;
}

/// Create a tree object and return its hash
pub fn createTreeObject(tree: GitTree, git_dir: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) ![]u8 {
    const data = try tree.serialize(allocator);
    defer allocator.free(data);
    
    const tree_obj = objects.GitObject.init(.tree, data);
    const hash = try tree_obj.store(git_dir, platform_impl, allocator);
    
    return hash;
}

/// Load tree from git object
pub fn loadTree(tree_hash: []const u8, git_dir: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) !GitTree {
    const tree_obj = try objects.GitObject.load(tree_hash, git_dir, platform_impl, allocator);
    defer tree_obj.deinit(allocator);
    
    if (tree_obj.type != .tree) return error.NotATree;
    
    return try GitTree.parseFromData(tree_obj.data, allocator);
}

/// Tree statistics for analysis
pub const TreeStats = struct {
    total_entries: u32,
    files: u32,
    directories: u32,
    symlinks: u32,
    submodules: u32,
    total_size: u64,
    max_depth: u32,
    
    pub fn print(self: TreeStats) void {
        std.debug.print("Tree Statistics:\n");
        std.debug.print("  Total entries: {}\n", .{self.total_entries});
        std.debug.print("  Files: {}\n", .{self.files});
        std.debug.print("  Directories: {}\n", .{self.directories});
        std.debug.print("  Symlinks: {}\n", .{self.symlinks});
        std.debug.print("  Submodules: {}\n", .{self.submodules});
        std.debug.print("  Total size: {} bytes\n", .{self.total_size});
        std.debug.print("  Max depth: {}\n", .{self.max_depth});
    }
};

/// Analyze tree recursively and return statistics
pub fn analyzeTree(tree_hash: []const u8, git_dir: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) !TreeStats {
    var stats = TreeStats{
        .total_entries = 0,
        .files = 0,
        .directories = 0,
        .symlinks = 0,
        .submodules = 0,
        .total_size = 0,
        .max_depth = 0,
    };
    
    const walker = TreeWalker.init(git_dir, platform_impl, allocator);
    try walker.walk(tree_hash, analyzeTreeVisitor, &stats);
    
    return stats;
}

fn analyzeTreeVisitor(stats: *TreeStats, path: []const u8, entry: TreeEntry) !void {
    _ = path; // Path not used in basic stats
    
    stats.total_entries += 1;
    
    if (entry.isFile()) {
        stats.files += 1;
    } else if (entry.isDirectory()) {
        stats.directories += 1;
    } else if (entry.isSymlink()) {
        stats.symlinks += 1;
    } else if (entry.isSubmodule()) {
        stats.submodules += 1;
    }
}