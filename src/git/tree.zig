const std = @import("std");
const objects = @import("objects.zig");

/// Git tree entry with enhanced functionality
pub const TreeEntry = struct {
    mode: []const u8, // e.g., "100644", "040000", "100755", "120000"
    name: []const u8,
    hash: []const u8, // 40-character hex string
    type: EntryType,

    pub const EntryType = enum {
        blob,
        tree,
        symlink,
        executable,

        pub fn fromMode(mode: []const u8) EntryType {
            if (std.mem.eql(u8, mode, "040000")) return .tree;
            if (std.mem.eql(u8, mode, "120000")) return .symlink;
            if (std.mem.eql(u8, mode, "100755")) return .executable;
            return .blob; // Default to blob for regular files
        }

        pub fn toString(self: EntryType) []const u8 {
            return switch (self) {
                .blob => "blob",
                .tree => "tree",
                .symlink => "symlink",
                .executable => "executable",
            };
        }
    };

    pub fn init(mode: []const u8, name: []const u8, hash: []const u8) TreeEntry {
        return TreeEntry{
            .mode = mode,
            .name = name,
            .hash = hash,
            .type = EntryType.fromMode(mode),
        };
    }

    pub fn deinit(self: TreeEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.mode);
        allocator.free(self.name);
        allocator.free(self.hash);
    }

    /// Get the object type for this tree entry
    pub fn getObjectType(self: TreeEntry) objects.ObjectType {
        return switch (self.type) {
            .blob, .symlink, .executable => .blob,
            .tree => .tree,
        };
    }

    /// Check if this entry represents a directory
    pub fn isDirectory(self: TreeEntry) bool {
        return self.type == .tree;
    }

    /// Check if this entry represents an executable file
    pub fn isExecutable(self: TreeEntry) bool {
        return self.type == .executable;
    }

    /// Check if this entry represents a symbolic link
    pub fn isSymlink(self: TreeEntry) bool {
        return self.type == .symlink;
    }

    /// Format entry for display (similar to `git ls-tree` output)
    pub fn format(self: TreeEntry, allocator: std.mem.Allocator) ![]u8 {
        const obj_type = self.getObjectType();
        return try std.fmt.allocPrint(allocator, "{s} {s} {s}\t{s}", .{
            self.mode,
            obj_type.toString(),
            self.hash,
            self.name,
        });
    }
};

/// Parse a tree object from git object data
pub fn parseTree(tree_data: []const u8, allocator: std.mem.Allocator) !std.ArrayList(TreeEntry) {
    var entries = std.ArrayList(TreeEntry).init(allocator);
    var pos: usize = 0;

    while (pos < tree_data.len) {
        // Find space separator between mode and filename
        const space_pos = std.mem.indexOfScalarPos(u8, tree_data, pos, ' ') orelse break;
        
        // Extract mode
        const mode = tree_data[pos..space_pos];
        pos = space_pos + 1;

        // Find null terminator after filename
        const null_pos = std.mem.indexOfScalarPos(u8, tree_data, pos, 0) orelse break;
        
        // Extract filename
        const name = tree_data[pos..null_pos];
        pos = null_pos + 1;

        // Extract 20-byte SHA-1 hash
        if (pos + 20 > tree_data.len) break;
        const hash_bytes = tree_data[pos..pos + 20];
        pos += 20;

        // Convert hash to hex string
        const hash_str = try std.fmt.allocPrint(allocator, "{}", .{std.fmt.fmtSliceHexLower(hash_bytes)});

        const entry = TreeEntry{
            .mode = try allocator.dupe(u8, mode),
            .name = try allocator.dupe(u8, name),
            .hash = hash_str,
            .type = TreeEntry.EntryType.fromMode(mode),
        };

        try entries.append(entry);
    }

    return entries;
}

/// Create tree object data from entries
pub fn createTreeData(entries: []const TreeEntry, allocator: std.mem.Allocator) ![]u8 {
    var content = std.ArrayList(u8).init(allocator);
    defer content.deinit();

    // Sort entries by name for consistent tree hashes
    var sorted_entries = std.ArrayList(TreeEntry).init(allocator);
    defer sorted_entries.deinit();
    
    for (entries) |entry| {
        try sorted_entries.append(entry);
    }

    std.sort.block(TreeEntry, sorted_entries.items, {}, struct {
        fn lessThan(context: void, lhs: TreeEntry, rhs: TreeEntry) bool {
            _ = context;
            return std.mem.lessThan(u8, lhs.name, rhs.name);
        }
    }.lessThan);

    for (sorted_entries.items) |entry| {
        try content.writer().print("{s} {s}\x00", .{ entry.mode, entry.name });
        // Write hash bytes directly
        var hash_bytes: [20]u8 = undefined;
        _ = try std.fmt.hexToBytes(&hash_bytes, entry.hash);
        try content.appendSlice(&hash_bytes);
    }

    return content.toOwnedSlice();
}

/// Tree walker for recursively traversing tree objects
pub const TreeWalker = struct {
    git_dir: []const u8,
    platform_impl: @TypeOf(@import("../platform/native.zig")),
    allocator: std.mem.Allocator,

    pub fn init(git_dir: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) TreeWalker {
        return TreeWalker{
            .git_dir = git_dir,
            .platform_impl = platform_impl,
            .allocator = allocator,
        };
    }

    /// Walk a tree recursively and call callback for each entry
    pub fn walk(self: TreeWalker, tree_hash: []const u8, callback: anytype, context: anytype, path_prefix: []const u8) !void {
        // Load the tree object
        const tree_obj = objects.GitObject.load(tree_hash, self.git_dir, self.platform_impl, self.allocator) catch return;
        defer tree_obj.deinit(self.allocator);

        if (tree_obj.type != .tree) return error.NotATree;

        // Parse tree entries
        var entries = parseTree(tree_obj.data, self.allocator) catch return;
        defer {
            for (entries.items) |entry| {
                entry.deinit(self.allocator);
            }
            entries.deinit();
        }

        for (entries.items) |entry| {
            // Build full path
            const full_path = if (path_prefix.len > 0)
                try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ path_prefix, entry.name })
            else
                try self.allocator.dupe(u8, entry.name);
            defer self.allocator.free(full_path);

            // Call callback for this entry
            try callback(context, &entry, full_path);

            // Recursively walk subdirectories
            if (entry.isDirectory()) {
                try self.walk(entry.hash, callback, context, full_path);
            }
        }
    }

    /// List all files in a tree (non-recursive)
    pub fn listFiles(self: TreeWalker, tree_hash: []const u8) !std.ArrayList(TreeEntry) {
        const tree_obj = objects.GitObject.load(tree_hash, self.git_dir, self.platform_impl, self.allocator) catch return error.TreeNotFound;
        defer tree_obj.deinit(self.allocator);

        if (tree_obj.type != .tree) return error.NotATree;

        return parseTree(tree_obj.data, self.allocator);
    }

    /// Find a specific file in a tree by path
    pub fn findFile(self: TreeWalker, tree_hash: []const u8, target_path: []const u8) !?TreeEntry {
        // Split path into components
        var path_iter = std.mem.split(u8, target_path, "/");
        var current_tree_hash = tree_hash;
        var remaining_path = path_iter.rest();

        while (path_iter.next()) |component| {
            // Load current tree
            const tree_obj = objects.GitObject.load(current_tree_hash, self.git_dir, self.platform_impl, self.allocator) catch return null;
            defer tree_obj.deinit(self.allocator);

            if (tree_obj.type != .tree) return null;

            // Parse tree entries
            var entries = parseTree(tree_obj.data, self.allocator) catch return null;
            defer {
                for (entries.items) |entry| {
                    entry.deinit(self.allocator);
                }
                entries.deinit();
            }

            // Look for the component
            var found_entry: ?TreeEntry = null;
            for (entries.items) |entry| {
                if (std.mem.eql(u8, entry.name, component)) {
                    found_entry = TreeEntry{
                        .mode = try self.allocator.dupe(u8, entry.mode),
                        .name = try self.allocator.dupe(u8, entry.name),
                        .hash = try self.allocator.dupe(u8, entry.hash),
                        .type = entry.type,
                    };
                    break;
                }
            }

            if (found_entry) |entry| {
                // Check if this is the final component
                const next_component = path_iter.peek();
                if (next_component == null) {
                    // This is the target file/directory
                    return entry;
                } else {
                    // Continue searching in this subdirectory
                    if (entry.isDirectory()) {
                        // Free old hash and continue with new one
                        self.allocator.free(current_tree_hash);
                        current_tree_hash = entry.hash;
                        remaining_path = path_iter.rest();
                    } else {
                        // Not a directory but path continues - file not found
                        entry.deinit(self.allocator);
                        return null;
                    }
                }
            } else {
                // Component not found
                return null;
            }
        }

        return null;
    }

    /// Get the blob hash for a file path in a tree
    pub fn getBlobHash(self: TreeWalker, tree_hash: []const u8, file_path: []const u8) !?[]u8 {
        const entry = try self.findFile(tree_hash, file_path);
        if (entry) |e| {
            defer e.deinit(self.allocator);
            if (!e.isDirectory()) {
                return try self.allocator.dupe(u8, e.hash);
            }
        }
        return null;
    }
};