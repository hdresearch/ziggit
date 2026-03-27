const std = @import("std");
const objects = @import("objects.zig");

/// Git tree entry with parsed mode and type information
pub const TreeEntry = struct {
    mode: FileMode,
    name: []const u8,
    hash: []const u8,
    type: objects.ObjectType,
    
    pub const FileMode = enum(u32) {
        // Common git file modes
        regular_file = 0o100644,
        executable_file = 0o100755,
        symlink = 0o120000,
        directory = 0o040000,
        submodule = 0o160000,
        
        pub fn fromString(mode_str: []const u8) !FileMode {
            const mode_int = std.fmt.parseInt(u32, mode_str, 8) catch return error.InvalidMode;
            return switch (mode_int) {
                0o100644 => .regular_file,
                0o100755 => .executable_file,
                0o120000 => .symlink,
                0o040000 => .directory,
                0o160000 => .submodule,
                else => return error.UnsupportedMode,
            };
        }
        
        pub fn toString(self: FileMode) []const u8 {
            return switch (self) {
                .regular_file => "100644",
                .executable_file => "100755",
                .symlink => "120000",
                .directory => "040000",
                .submodule => "160000",
            };
        }
        
        pub fn isDirectory(self: FileMode) bool {
            return self == .directory;
        }
        
        pub fn isExecutable(self: FileMode) bool {
            return self == .executable_file;
        }
        
        pub fn isSymlink(self: FileMode) bool {
            return self == .symlink;
        }
        
        pub fn isSubmodule(self: FileMode) bool {
            return self == .submodule;
        }
    };
    
    pub fn init(mode: FileMode, name: []const u8, hash: []const u8) TreeEntry {
        const obj_type: objects.ObjectType = if (mode.isDirectory()) .tree else .blob;
        return TreeEntry{
            .mode = mode,
            .name = name,
            .hash = hash,
            .type = obj_type,
        };
    }
    
    pub fn deinit(self: TreeEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.hash);
    }
};

/// Parse a git tree object into structured entries
pub fn parseTreeObject(tree_data: []const u8, allocator: std.mem.Allocator) ![]TreeEntry {
    var entries = std.array_list.Managed(TreeEntry).init(allocator);
    defer entries.deinit();
    
    var pos: usize = 0;
    
    while (pos < tree_data.len) {
        // Find space separator between mode and name
        const space_pos = std.mem.indexOfScalarPos(u8, tree_data, pos, ' ') orelse return error.InvalidTreeFormat;
        
        // Parse mode
        const mode_str = tree_data[pos..space_pos];
        const mode = TreeEntry.FileMode.fromString(mode_str) catch |err| switch (err) {
            error.InvalidMode, error.UnsupportedMode => {
                // Skip unsupported entries rather than failing completely
                pos = space_pos + 1;
                continue;
            },
            else => return err,
        };
        
        pos = space_pos + 1;
        
        // Find null terminator after filename
        const null_pos = std.mem.indexOfScalarPos(u8, tree_data, pos, 0) orelse return error.InvalidTreeFormat;
        
        const name = try allocator.dupe(u8, tree_data[pos..null_pos]);
        errdefer allocator.free(name);
        
        pos = null_pos + 1;
        
        // Read 20-byte SHA-1 hash
        if (pos + 20 > tree_data.len) return error.InvalidTreeFormat;
        
        const hash_bytes = tree_data[pos..pos + 20];
        const hash = try allocator.alloc(u8, 40);
        errdefer allocator.free(hash);
        _ = try std.fmt.bufPrint(hash, "{x}", .{hash_bytes});
        
        pos += 20;
        
        const entry = TreeEntry.init(mode, name, hash);
        try entries.append(entry);
    }
    
    return entries.toOwnedSlice();
}

/// Tree walker for recursive directory traversal
pub fn TreeWalker(comptime PlatformImpl: type) type {
    return struct {
        git_dir: []const u8,
        platform_impl: PlatformImpl,
        allocator: std.mem.Allocator,
        visited_trees: std.StringHashMap(void), // Cycle detection
        
        const Self = @This();
        
        pub fn init(git_dir: []const u8, platform_impl: PlatformImpl, allocator: std.mem.Allocator) Self {
            return Self{
                .git_dir = git_dir,
                .platform_impl = platform_impl,
                .allocator = allocator,
                .visited_trees = std.StringHashMap(void).init(allocator),
            };
        }
        
        pub fn deinit(self: *Self) void {
            self.visited_trees.deinit();
        }
        
        /// Walk a tree recursively, calling the visitor function for each entry
        pub fn walk(self: *Self, tree_hash: []const u8, path: []const u8, visitor: anytype) !void {
            // Cycle detection
            if (self.visited_trees.contains(tree_hash)) {
                return error.TreeCycle;
            }
            try self.visited_trees.put(tree_hash, {});
            defer _ = self.visited_trees.remove(tree_hash);
            
            // Load the tree object
            const tree_obj = objects.GitObject.load(tree_hash, self.git_dir, self.platform_impl, self.allocator) catch |err| switch (err) {
                error.ObjectNotFound => return error.TreeNotFound,
                else => return err,
            };
            defer tree_obj.deinit(self.allocator);
            
            if (tree_obj.type != .tree) return error.NotATree;
            
            // Parse tree entries
            const entries = try parseTreeObject(tree_obj.data, self.allocator);
            defer {
                for (entries) |entry| {
                    entry.deinit(self.allocator);
                }
                self.allocator.free(entries);
            }
            
            // Visit each entry
            for (entries) |entry| {
                const entry_path = if (path.len == 0) 
                    try self.allocator.dupe(u8, entry.name)
                else 
                    try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ path, entry.name });
                defer self.allocator.free(entry_path);
                
                // Call visitor function
                const should_recurse = try visitor.visit(entry, entry_path);
                
                // Recursively walk subdirectories if requested
                if (should_recurse and entry.mode.isDirectory()) {
                    try self.walk(entry.hash, entry_path, visitor);
                }
            }
        }
        
        /// Get all files in a tree (non-recursive)
        pub fn getTreeFiles(self: *Self, tree_hash: []const u8) ![]TreeEntry {
            const tree_obj = try objects.GitObject.load(tree_hash, self.git_dir, self.platform_impl, self.allocator);
            defer tree_obj.deinit(self.allocator);
            
            if (tree_obj.type != .tree) return error.NotATree;
            
            return parseTreeObject(tree_obj.data, self.allocator);
        }
        
        /// Find a specific file in a tree by path
        pub fn findFile(self: *Self, tree_hash: []const u8, target_path: []const u8) !?TreeEntry {
            var path_parts = std.mem.splitSequence(u8, target_path, "/");
            var current_tree = try self.allocator.dupe(u8, tree_hash);
            defer self.allocator.free(current_tree);
            
            while (path_parts.next()) |part| {
                const entries = try self.getTreeFiles(current_tree);
                defer {
                    for (entries) |entry| {
                        entry.deinit(self.allocator);
                    }
                    self.allocator.free(entries);
                }
                
                // Look for the path component
                var found_entry: ?TreeEntry = null;
                for (entries) |entry| {
                    if (std.mem.eql(u8, entry.name, part)) {
                        found_entry = TreeEntry{
                            .mode = entry.mode,
                            .name = try self.allocator.dupe(u8, entry.name),
                            .hash = try self.allocator.dupe(u8, entry.hash),
                            .type = entry.type,
                        };
                        break;
                    }
                }
                
                if (found_entry == null) return null;
                
                // Check if this is the final component
                if (path_parts.rest().len == 0) {
                    return found_entry;
                }
                
                // Move to next level (must be a directory)
                if (!found_entry.?.mode.isDirectory()) {
                    found_entry.?.deinit(self.allocator);
                    return null;
                }
                
                self.allocator.free(current_tree);
                current_tree = try self.allocator.dupe(u8, found_entry.?.hash);
                found_entry.?.deinit(self.allocator);
            }
            
            return null;
        }
    };
}

/// Simple visitor that collects all file paths
pub const FileCollector = struct {
    files: std.array_list.Managed([]const u8),
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) FileCollector {
        return FileCollector{
            .files = std.array_list.Managed([]const u8).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *FileCollector) void {
        for (self.files.items) |file| {
            self.allocator.free(file);
        }
        self.files.deinit();
    }
    
    pub fn visit(self: *FileCollector, entry: TreeEntry, path: []const u8) !bool {
        if (!entry.mode.isDirectory()) {
            try self.files.append(try self.allocator.dupe(u8, path));
        }
        return true; // Always recurse
    }
    
    pub fn getFiles(self: FileCollector) []const []const u8 {
        return self.files.items;
    }
};

/// Create a new tree object from entries
pub fn createTreeObject(entries: []const TreeEntry, allocator: std.mem.Allocator) !objects.GitObject {
    // Sort entries by name (git requirement)
    const sorted_entries = try allocator.dupe(TreeEntry, entries);
    defer allocator.free(sorted_entries);
    
    std.sort.block(TreeEntry, sorted_entries, {}, struct {
        fn lessThan(context: void, lhs: TreeEntry, rhs: TreeEntry) bool {
            _ = context;
            return std.mem.lessThan(u8, lhs.name, rhs.name);
        }
    }.lessThan);
    
    var content = std.array_list.Managed(u8).init(allocator);
    defer content.deinit();
    
    for (sorted_entries) |entry| {
        try content.writer().print("{s} {s}\x00", .{ entry.mode.toString(), entry.name });
        
        // Convert hex hash to bytes
        var hash_bytes: [20]u8 = undefined;
        _ = try std.fmt.hexToBytes(&hash_bytes, entry.hash);
        try content.appendSlice(&hash_bytes);
    }
    
    const data = try content.toOwnedSlice();
    return objects.GitObject.init(.tree, data);
}

test "tree entry parsing" {
    const testing = std.testing;
    
    // Test file mode parsing
    try testing.expectEqual(TreeEntry.FileMode.regular_file, try TreeEntry.FileMode.fromString("100644"));
    try testing.expectEqual(TreeEntry.FileMode.executable_file, try TreeEntry.FileMode.fromString("100755"));
    try testing.expectEqual(TreeEntry.FileMode.directory, try TreeEntry.FileMode.fromString("40000"));
    
    // Test mode properties
    try testing.expect(TreeEntry.FileMode.directory.isDirectory());
    try testing.expect(TreeEntry.FileMode.executable_file.isExecutable());
    try testing.expect(!TreeEntry.FileMode.regular_file.isDirectory());
}

test "tree object creation" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    const entries = [_]TreeEntry{
        TreeEntry.init(.regular_file, try allocator.dupe(u8, "file1.txt"), try allocator.dupe(u8, "a" ** 40)),
        TreeEntry.init(.directory, try allocator.dupe(u8, "subdir"), try allocator.dupe(u8, "b" ** 40)),
    };
    
    defer {
        for (entries) |entry| {
            entry.deinit(allocator);
        }
    }
    
    const tree_obj = try createTreeObject(&entries, allocator);
    defer tree_obj.deinit(allocator);
    
    try testing.expectEqual(objects.ObjectType.tree, tree_obj.type);
    try testing.expect(tree_obj.data.len > 0);
    
    // Parse it back to verify
    const parsed_entries = try parseTreeObject(tree_obj.data, allocator);
    defer {
        for (parsed_entries) |entry| {
            entry.deinit(allocator);
        }
        allocator.free(parsed_entries);
    }
    
    try testing.expectEqual(@as(usize, 2), parsed_entries.len);
}

test "file collector visitor" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var collector = FileCollector.init(allocator);
    defer collector.deinit();
    
    // Simulate visiting some entries
    const file_entry = TreeEntry.init(.regular_file, try allocator.dupe(u8, "test.txt"), try allocator.dupe(u8, "a" ** 40));
    defer file_entry.deinit(allocator);
    
    const dir_entry = TreeEntry.init(.directory, try allocator.dupe(u8, "subdir"), try allocator.dupe(u8, "b" ** 40));
    defer dir_entry.deinit(allocator);
    
    _ = try collector.visit(file_entry, "test.txt");
    _ = try collector.visit(dir_entry, "subdir");
    
    const files = collector.getFiles();
    try testing.expectEqual(@as(usize, 1), files.len); // Only the file, not the directory
    try testing.expectEqualStrings("test.txt", files[0]);
}