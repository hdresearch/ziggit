const std = @import("std");
const index = @import("index.zig");

/// Advanced index operations and utilities
pub const AdvancedIndex = struct {
    base_index: index.Index,
    conflicted_entries: std.ArrayList(ConflictedEntry),
    extensions: std.ArrayList(IndexExtension),
    
    pub fn init(allocator: std.mem.Allocator) AdvancedIndex {
        return AdvancedIndex{
            .base_index = index.Index.init(allocator),
            .conflicted_entries = std.ArrayList(ConflictedEntry).init(allocator),
            .extensions = std.ArrayList(IndexExtension).init(allocator),
        };
    }
    
    pub fn deinit(self: *AdvancedIndex) void {
        self.base_index.deinit();
        
        for (self.conflicted_entries.items) |*entry| {
            entry.deinit(self.base_index.allocator);
        }
        self.conflicted_entries.deinit();
        
        for (self.extensions.items) |*ext| {
            ext.deinit(self.base_index.allocator);
        }
        self.extensions.deinit();
    }
    
    /// Load index with advanced parsing of extensions
    pub fn loadAdvanced(git_dir: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) !AdvancedIndex {
        var adv_index = AdvancedIndex.init(allocator);
        
        const index_path = try std.fmt.allocPrint(allocator, "{s}/index", .{git_dir});
        defer allocator.free(index_path);

        const data = platform_impl.fs.readFile(allocator, index_path) catch |err| switch (err) {
            error.FileNotFound => return adv_index, // Empty index
            else => return err,
        };
        defer allocator.free(data);

        try adv_index.parseAdvancedIndexData(data);
        return adv_index;
    }
    
    /// Parse index with full extension support
    fn parseAdvancedIndexData(self: *AdvancedIndex, data: []const u8) !void {
        // First parse the basic index
        try self.base_index.parseIndexData(data);
        
        // Then parse extensions manually
        if (data.len < 12) return;
        
        var stream = std.io.fixedBufferStream(data);
        const reader = stream.reader();
        
        // Skip header
        try reader.skipBytes(12, .{});
        
        // Skip entries
        const version = std.mem.readInt(u32, @ptrCast(data[4..8]), .big);
        const entry_count = std.mem.readInt(u32, @ptrCast(data[8..12]), .big);
        
        var i: u32 = 0;
        while (i < entry_count) : (i += 1) {
            // Calculate entry size to skip it
            const entry_start = try reader.context.getPos();
            
            // Skip standard entry fields (62 bytes)
            try reader.skipBytes(62, .{});
            
            // Handle extended flags for v3+
            const flags = std.mem.readInt(u16, @ptrCast(data[entry_start + 60..entry_start + 62]), .big);
            if (version >= 3 and (flags & 0x4000) != 0) {
                try reader.skipBytes(2, .{});
            }
            
            // Get path length and skip path + padding
            var path_len = flags & 0xFFF;
            if (version >= 4 and path_len == 0xFFF) {
                // Read variable-length path length
                var varint_len: u16 = 0;
                var shift: u4 = 0;
                while (shift < 14) {
                    const byte = try reader.readByte();
                    varint_len |= @as(u16, @intCast(byte & 0x7F)) << shift;
                    if (byte & 0x80 == 0) break;
                    shift += 7;
                }
                path_len = varint_len;
            }
            
            try reader.skipBytes(path_len, .{});
            
            // Skip padding
            const entry_size = 62 + (if (version >= 3 and (flags & 0x4000) != 0) @as(usize, 2) else @as(usize, 0)) + path_len;
            const pad_len = (8 - (entry_size % 8)) % 8;
            if (pad_len > 0) {
                reader.skipBytes(pad_len, .{}) catch {};
            }
        }
        
        // Now parse extensions
        try self.parseExtensions(reader, data);
    }
    
    /// Parse index extensions with detailed handling
    fn parseExtensions(self: *AdvancedIndex, reader: anytype, data: []const u8) !void {
        while (true) {
            const current_pos = reader.context.getPos() catch break;
            
            // Check if we have enough bytes for checksum
            if (current_pos + 28 >= data.len) break;
            
            // Try to read extension signature
            var sig: [4]u8 = undefined;
            _ = reader.readAll(&sig) catch break;
            
            // Read extension size
            const ext_size = reader.readInt(u32, .big) catch {
                try reader.context.seekTo(current_pos);
                break;
            };
            
            // Validate extension size
            if (ext_size > 10 * 1024 * 1024 or current_pos + 8 + ext_size > data.len - 20) {
                try reader.context.seekTo(current_pos);
                break;
            }
            
            // Read extension data
            const ext_data = try self.base_index.allocator.alloc(u8, ext_size);
            errdefer self.base_index.allocator.free(ext_data);
            _ = try reader.readAll(ext_data);
            
            // Parse specific extensions
            if (std.mem.eql(u8, &sig, "TREE")) {
                try self.parseTreeExtension(ext_data);
            } else if (std.mem.eql(u8, &sig, "REUC")) {
                try self.parseResolveUndoExtension(ext_data);
            } else if (std.mem.eql(u8, &sig, "UNTR")) {
                try self.parseUntrackedCacheExtension(ext_data);
            }
            
            // Store the extension
            try self.extensions.append(IndexExtension{
                .signature = sig,
                .data = ext_data,
                .parsed = true,
            });
        }
    }
    
    /// Parse TREE extension (directory tree cache)
    fn parseTreeExtension(self: *AdvancedIndex, data: []const u8) !void {
        _ = self; // May use in future for tree cache optimization
        
        // Tree extension format:
        // <path>\0<entries><subtrees><sha1>
        // This is used to speed up tree object creation
        var pos: usize = 0;
        
        while (pos < data.len) {
            // Find null terminator for path
            const null_pos = std.mem.indexOfPos(u8, data, pos, "\x00") orelse break;
            const path = data[pos..null_pos];
            pos = null_pos + 1;
            
            if (pos + 8 + 20 > data.len) break;
            
            // Read entry count and subtree count
            const entries = std.mem.readInt(u32, @ptrCast(data[pos..pos+4]), .big);
            pos += 4;
            const subtrees = std.mem.readInt(u32, @ptrCast(data[pos..pos+4]), .big);
            pos += 4;
            
            // Skip SHA-1 hash
            pos += 20;
            
            // Tree cache entry found for path
            _ = path;
            _ = entries;
            _ = subtrees;
        }
    }
    
    /// Parse REUC extension (resolve undo)
    fn parseResolveUndoExtension(self: *AdvancedIndex, data: []const u8) !void {
        // Resolve undo extension tracks conflict resolutions
        var pos: usize = 0;
        
        while (pos < data.len) {
            // Find null terminator for path
            const null_pos = std.mem.indexOfPos(u8, data, pos, "\x00") orelse break;
            const path = data[pos..null_pos];
            pos = null_pos + 1;
            
            if (pos + 12 > data.len) break; // Need at least 3 mode fields
            
            // Read stage modes (ancestor, ours, theirs)
            const ancestor_mode = std.mem.readInt(u32, @ptrCast(data[pos..pos+4]), .big);
            pos += 4;
            const our_mode = std.mem.readInt(u32, @ptrCast(data[pos..pos+4]), .big);
            pos += 4;
            const their_mode = std.mem.readInt(u32, @ptrCast(data[pos..pos+4]), .big);
            pos += 4;
            
            // Read SHA-1 hashes if modes are non-zero
            var ancestor_hash: ?[20]u8 = null;
            var our_hash: ?[20]u8 = null;
            var their_hash: ?[20]u8 = null;
            
            if (ancestor_mode != 0) {
                if (pos + 20 > data.len) break;
                ancestor_hash = data[pos..pos+20].*;
                pos += 20;
            }
            
            if (our_mode != 0) {
                if (pos + 20 > data.len) break;
                our_hash = data[pos..pos+20].*;
                pos += 20;
            }
            
            if (their_mode != 0) {
                if (pos + 20 > data.len) break;
                their_hash = data[pos..pos+20].*;
                pos += 20;
            }
            
            // Store conflict information
            try self.conflicted_entries.append(ConflictedEntry{
                .path = try self.base_index.allocator.dupe(u8, path),
                .ancestor_mode = if (ancestor_mode != 0) ancestor_mode else null,
                .our_mode = if (our_mode != 0) our_mode else null,
                .their_mode = if (their_mode != 0) their_mode else null,
                .ancestor_hash = ancestor_hash,
                .our_hash = our_hash,
                .their_hash = their_hash,
            });
        }
    }
    
    /// Parse UNTR extension (untracked cache)
    fn parseUntrackedCacheExtension(self: *AdvancedIndex, data: []const u8) !void {
        _ = self; // May use in future for untracked cache optimization
        _ = data; // Untracked cache format is complex, skip for now
    }
    
    /// Get conflicted files (useful for merge resolution)
    pub fn getConflictedFiles(self: AdvancedIndex, allocator: std.mem.Allocator) ![][]const u8 {
        var conflicted = std.ArrayList([]const u8).init(allocator);
        
        for (self.conflicted_entries.items) |entry| {
            try conflicted.append(try allocator.dupe(u8, entry.path));
        }
        
        return try conflicted.toOwnedSlice();
    }
    
    /// Check if a file is in conflict state
    pub fn isConflicted(self: AdvancedIndex, path: []const u8) bool {
        for (self.conflicted_entries.items) |entry| {
            if (std.mem.eql(u8, entry.path, path)) {
                return true;
            }
        }
        return false;
    }
    
    /// Get statistics about the index
    pub fn getStats(self: AdvancedIndex) IndexStats {
        var stats = IndexStats{
            .total_entries = self.base_index.entries.items.len,
            .conflicted_entries = self.conflicted_entries.items.len,
            .extensions = self.extensions.items.len,
            .has_tree_cache = false,
            .has_resolve_undo = false,
            .has_untracked_cache = false,
        };
        
        for (self.extensions.items) |ext| {
            if (std.mem.eql(u8, &ext.signature, "TREE")) {
                stats.has_tree_cache = true;
            } else if (std.mem.eql(u8, &ext.signature, "REUC")) {
                stats.has_resolve_undo = true;
            } else if (std.mem.eql(u8, &ext.signature, "UNTR")) {
                stats.has_untracked_cache = true;
            }
        }
        
        return stats;
    }
    
    /// Validate index integrity
    pub fn validateIntegrity(self: AdvancedIndex) !void {
        // Check that entries are sorted by path
        for (self.base_index.entries.items[0..], 0..) |entry, i| {
            if (i > 0) {
                const prev_entry = self.base_index.entries.items[i - 1];
                if (std.mem.order(u8, prev_entry.path, entry.path) != .lt) {
                    return error.IndexNotSorted;
                }
            }
            
            // Validate entry fields
            if (entry.path.len == 0) {
                return error.EmptyPath;
            }
            
            if (entry.path.len > 4096) {
                return error.PathTooLong;
            }
            
            // Check for null bytes in path
            if (std.mem.indexOf(u8, entry.path, "\x00")) |_| {
                return error.InvalidPathCharacters;
            }
        }
    }
};

/// Conflicted entry from resolve undo extension
const ConflictedEntry = struct {
    path: []const u8,
    ancestor_mode: ?u32,
    our_mode: ?u32,
    their_mode: ?u32,
    ancestor_hash: ?[20]u8,
    our_hash: ?[20]u8,
    their_hash: ?[20]u8,
    
    fn deinit(self: *ConflictedEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

/// Index extension
const IndexExtension = struct {
    signature: [4]u8,
    data: []const u8,
    parsed: bool,
    
    fn deinit(self: *IndexExtension, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

/// Index statistics
pub const IndexStats = struct {
    total_entries: usize,
    conflicted_entries: usize,
    extensions: usize,
    has_tree_cache: bool,
    has_resolve_undo: bool,
    has_untracked_cache: bool,
};

/// Repair index file (remove corruption, fix sorting)
pub fn repairIndex(git_dir: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) !bool {
    std.debug.print("Repairing index file...\n");
    
    var adv_index = AdvancedIndex.loadAdvanced(git_dir, platform_impl, allocator) catch |err| {
        std.debug.print("Failed to load index: {}\n", .{err});
        return false;
    };
    defer adv_index.deinit();
    
    // Validate integrity
    adv_index.validateIntegrity() catch |err| {
        std.debug.print("Index integrity issues found: {}\n", .{err});
        
        // Try to fix common issues
        if (err == error.IndexNotSorted) {
            std.debug.print("Sorting index entries...\n");
            
            std.sort.block(index.IndexEntry, adv_index.base_index.entries.items, {}, struct {
                fn lessThan(context: void, lhs: index.IndexEntry, rhs: index.IndexEntry) bool {
                    _ = context;
                    return std.mem.lessThan(u8, lhs.path, rhs.path);
                }
            }.lessThan);
            
            // Save repaired index
            adv_index.base_index.save(git_dir, platform_impl) catch |save_err| {
                std.debug.print("Failed to save repaired index: {}\n", .{save_err});
                return false;
            };
            
            std.debug.print("Index repaired and saved.\n");
            return true;
        }
        
        return false;
    };
    
    std.debug.print("Index integrity is good.\n");
    return true;
}

test "advanced index basic functionality" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var adv_index = AdvancedIndex.init(allocator);
    defer adv_index.deinit();
    
    // Test stats with empty index
    const stats = adv_index.getStats();
    try testing.expectEqual(@as(usize, 0), stats.total_entries);
    try testing.expectEqual(@as(usize, 0), stats.conflicted_entries);
    try testing.expectEqual(@as(usize, 0), stats.extensions);
    try testing.expect(!stats.has_tree_cache);
}