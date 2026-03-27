const std = @import("std");
const index_mod = @import("index.zig");

/// Git index extension handling and utilities
pub const IndexExtensions = struct {
    allocator: std.mem.Allocator,
    extensions: std.ArrayList(Extension),
    
    pub fn init(allocator: std.mem.Allocator) IndexExtensions {
        return IndexExtensions{
            .allocator = allocator,
            .extensions = std.ArrayList(Extension).init(allocator),
        };
    }
    
    pub fn deinit(self: *IndexExtensions) void {
        for (self.extensions.items) |ext| {
            ext.deinit(self.allocator);
        }
        self.extensions.deinit();
    }
    
    /// Parse extensions from index data starting at the given offset
    pub fn parseExtensions(self: *IndexExtensions, data: []const u8, start_offset: usize) !void {
        if (start_offset >= data.len) return;
        
        var pos = start_offset;
        const end_pos = if (data.len >= 20) data.len - 20 else data.len; // Account for SHA-1 checksum
        
        while (pos + 8 <= end_pos) {
            // Read extension header: 4-byte signature + 4-byte size
            const signature = data[pos..pos + 4];
            const size = std.mem.readInt(u32, @ptrCast(data[pos + 4..pos + 8]), .big);
            pos += 8;
            
            // Validate size
            if (size > end_pos - pos) break;
            
            const ext_data = data[pos..pos + size];
            pos += size;
            
            // Create and store extension
            var extension = Extension{
                .signature = undefined,
                .data = try self.allocator.dupe(u8, ext_data),
            };
            @memcpy(&extension.signature, signature);
            
            try self.extensions.append(extension);
        }
    }
    
    /// Get extension by signature (e.g., "TREE", "REUC", etc.)
    pub fn getExtension(self: IndexExtensions, signature: [4]u8) ?*const Extension {
        for (self.extensions.items) |*ext| {
            if (std.mem.eql(u8, &ext.signature, &signature)) {
                return ext;
            }
        }
        return null;
    }
    
    /// Check if a specific extension exists
    pub fn hasExtension(self: IndexExtensions, signature: [4]u8) bool {
        return self.getExtension(signature) != null;
    }
    
    /// Parse TREE extension (cached tree objects)
    pub fn parseTreeExtension(self: IndexExtensions, allocator: std.mem.Allocator) !?TreeCache {
        const tree_ext = self.getExtension([4]u8{ 'T', 'R', 'E', 'E' }) orelse return null;
        
        var cache = TreeCache.init(allocator);
        var pos: usize = 0;
        
        while (pos < tree_ext.data.len) {
            // Parse tree cache entry
            const null_pos = std.mem.indexOf(u8, tree_ext.data[pos..], "\x00") orelse break;
            const path = tree_ext.data[pos..pos + null_pos];
            pos += null_pos + 1;
            
            // Ensure we have enough data for the rest of the entry
            if (pos + 28 > tree_ext.data.len) break;
            
            // Parse space-separated values after path
            const space1 = std.mem.indexOf(u8, tree_ext.data[pos..pos + 20], " ") orelse continue;
            const space2 = std.mem.indexOf(u8, tree_ext.data[pos + space1 + 1..pos + 20], " ") orelse continue;
            
            const entry_count_str = tree_ext.data[pos..pos + space1];
            const subtree_count_str = tree_ext.data[pos + space1 + 1..pos + space1 + 1 + space2];
            
            const entry_count = std.fmt.parseInt(i32, entry_count_str, 10) catch continue;
            const subtree_count = std.fmt.parseInt(i32, subtree_count_str, 10) catch continue;
            
            pos += 20; // Skip to SHA-1
            
            // Read SHA-1 if entry count is non-negative
            var sha1: ?[20]u8 = null;
            if (entry_count >= 0) {
                if (pos + 20 > tree_ext.data.len) break;
                sha1 = tree_ext.data[pos..pos + 20][0..20].*;
                pos += 20;
            }
            
            try cache.entries.append(TreeCacheEntry{
                .path = try allocator.dupe(u8, path),
                .entry_count = entry_count,
                .subtree_count = subtree_count,
                .sha1 = sha1,
            });
        }
        
        return cache;
    }
    
    /// Parse REUC extension (resolve undo)
    pub fn parseResolveUndoExtension(self: IndexExtensions, allocator: std.mem.Allocator) !?ResolveUndo {
        const reuc_ext = self.getExtension([4]u8{ 'R', 'E', 'U', 'C' }) orelse return null;
        
        var resolve_undo = ResolveUndo.init(allocator);
        var pos: usize = 0;
        
        while (pos < reuc_ext.data.len) {
            // Parse path (null-terminated)
            const null_pos = std.mem.indexOf(u8, reuc_ext.data[pos..], "\x00") orelse break;
            const path = reuc_ext.data[pos..pos + null_pos];
            pos += null_pos + 1;
            
            // Read three stages (mode + SHA-1 for each)
            var stages: [3]?ResolveUndoStage = [3]?ResolveUndoStage{ null, null, null };
            
            for (&stages) |*stage| {
                if (pos + 4 > reuc_ext.data.len) break;
                
                const mode_bytes = reuc_ext.data[pos..pos + 4];
                const mode = std.mem.readInt(u32, @ptrCast(mode_bytes), .big);
                pos += 4;
                
                if (mode == 0) {
                    stage.* = null;
                } else {
                    if (pos + 20 > reuc_ext.data.len) break;
                    const sha1 = reuc_ext.data[pos..pos + 20][0..20].*;
                    pos += 20;
                    
                    stage.* = ResolveUndoStage{
                        .mode = mode,
                        .sha1 = sha1,
                    };
                }
            }
            
            try resolve_undo.entries.append(ResolveUndoEntry{
                .path = try allocator.dupe(u8, path),
                .stages = stages,
            });
        }
        
        return resolve_undo;
    }
    
    /// Get list of all extension signatures present
    pub fn getExtensionSignatures(self: IndexExtensions, allocator: std.mem.Allocator) ![][4]u8 {
        var signatures = try allocator.alloc([4]u8, self.extensions.items.len);
        
        for (self.extensions.items, 0..) |ext, i| {
            signatures[i] = ext.signature;
        }
        
        return signatures;
    }
    
    /// Print information about all extensions
    pub fn printExtensionInfo(self: IndexExtensions) void {
        if (self.extensions.items.len == 0) {
            std.debug.print("No index extensions found.\n", .{});
            return;
        }
        
        std.debug.print("Index extensions ({}):\n", .{self.extensions.items.len});
        for (self.extensions.items) |ext| {
            const sig_str = std.fmt.fmtSliceHexUpper(&ext.signature);
            std.debug.print("  {s} ({}): {} bytes\n", .{ ext.signature, sig_str, ext.data.len });
            
            // Provide known extension info
            if (std.mem.eql(u8, &ext.signature, "TREE")) {
                std.debug.print("    TREE: Cached tree objects\n", .{});
            } else if (std.mem.eql(u8, &ext.signature, "REUC")) {
                std.debug.print("    REUC: Resolve undo information\n", .{});
            } else if (std.mem.eql(u8, &ext.signature, "UNTR")) {
                std.debug.print("    UNTR: Untracked cache\n", .{});
            } else if (std.mem.eql(u8, &ext.signature, "FSMN")) {
                std.debug.print("    FSMN: File system monitor\n", .{});
            } else {
                std.debug.print("    Unknown extension\n", .{});
            }
        }
    }
};

/// Raw extension data
pub const Extension = struct {
    signature: [4]u8,
    data: []u8,
    
    pub fn deinit(self: Extension, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

/// Parsed TREE extension (cached tree objects)
pub const TreeCache = struct {
    entries: std.ArrayList(TreeCacheEntry),
    
    pub fn init(allocator: std.mem.Allocator) TreeCache {
        return TreeCache{
            .entries = std.ArrayList(TreeCacheEntry).init(allocator),
        };
    }
    
    pub fn deinit(self: *TreeCache, allocator: std.mem.Allocator) void {
        for (self.entries.items) |entry| {
            entry.deinit(allocator);
        }
        self.entries.deinit();
    }
    
    /// Find cached tree for a given path
    pub fn findTree(self: TreeCache, path: []const u8) ?TreeCacheEntry {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.path, path)) {
                return entry;
            }
        }
        return null;
    }
};

pub const TreeCacheEntry = struct {
    path: []u8,
    entry_count: i32,     // Number of entries in this tree (-1 if invalid)
    subtree_count: i32,   // Number of subtrees
    sha1: ?[20]u8,        // SHA-1 of tree object (null if invalid)
    
    pub fn deinit(self: TreeCacheEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
    
    pub fn isValid(self: TreeCacheEntry) bool {
        return self.entry_count >= 0 and self.sha1 != null;
    }
};

/// Parsed REUC extension (resolve undo)
pub const ResolveUndo = struct {
    entries: std.ArrayList(ResolveUndoEntry),
    
    pub fn init(allocator: std.mem.Allocator) ResolveUndo {
        return ResolveUndo{
            .entries = std.ArrayList(ResolveUndoEntry).init(allocator),
        };
    }
    
    pub fn deinit(self: *ResolveUndo, allocator: std.mem.Allocator) void {
        for (self.entries.items) |entry| {
            entry.deinit(allocator);
        }
        self.entries.deinit();
    }
    
    /// Check if a path has resolve undo information
    pub fn hasEntry(self: ResolveUndo, path: []const u8) bool {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.path, path)) {
                return true;
            }
        }
        return false;
    }
};

pub const ResolveUndoEntry = struct {
    path: []u8,
    stages: [3]?ResolveUndoStage, // Stage 1, 2, 3 (base, ours, theirs)
    
    pub fn deinit(self: ResolveUndoEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

pub const ResolveUndoStage = struct {
    mode: u32,
    sha1: [20]u8,
};

/// Index validation utilities
pub const IndexValidator = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) IndexValidator {
        return IndexValidator{ .allocator = allocator };
    }
    
    /// Validate index file integrity
    pub fn validateIndex(self: IndexValidator, data: []const u8) ValidationResult {
        var result = ValidationResult.init(self.allocator);
        
        // Basic size check
        if (data.len < 28) { // Minimum: header(12) + 1 entry(62) + checksum(20) - actually varies
            result.addError("Index file too small") catch {};
            return result;
        }
        
        // Validate header
        if (!std.mem.eql(u8, data[0..4], "DIRC")) {
            result.addError("Invalid index signature") catch {};
            return result;
        }
        
        const version = std.mem.readInt(u32, @ptrCast(data[4..8]), .big);
        if (version < 2 or version > 4) {
            result.addError("Unsupported index version") catch {};
        } else {
            result.addInfo("Index version valid") catch {};
        }
        
        const entry_count = std.mem.readInt(u32, @ptrCast(data[8..12]), .big);
        if (entry_count > 1_000_000) {
            result.addWarning("Very large number of entries") catch {};
        }
        
        // Validate checksum
        if (data.len >= 20) {
            const content_end = data.len - 20;
            const stored_checksum = data[content_end..];
            
            var hasher = std.crypto.hash.Sha1.init(.{});
            hasher.update(data[0..content_end]);
            var computed_checksum: [20]u8 = undefined;
            hasher.final(&computed_checksum);
            
            if (std.mem.eql(u8, &computed_checksum, stored_checksum)) {
                result.addInfo("Index checksum valid") catch {};
            } else {
                result.addError("Index checksum mismatch") catch {};
            }
        }
        
        return result;
    }
};

pub const ValidationResult = struct {
    allocator: std.mem.Allocator,
    errors: std.ArrayList([]u8),
    warnings: std.ArrayList([]u8),
    info: std.ArrayList([]u8),
    
    pub fn init(allocator: std.mem.Allocator) ValidationResult {
        return ValidationResult{
            .allocator = allocator,
            .errors = std.ArrayList([]u8).init(allocator),
            .warnings = std.ArrayList([]u8).init(allocator),
            .info = std.ArrayList([]u8).init(allocator),
        };
    }
    
    pub fn deinit(self: *ValidationResult) void {
        for (self.errors.items) |item| self.allocator.free(item);
        for (self.warnings.items) |item| self.allocator.free(item);
        for (self.info.items) |item| self.allocator.free(item);
        self.errors.deinit();
        self.warnings.deinit();
        self.info.deinit();
    }
    
    pub fn addError(self: *ValidationResult, msg: []const u8) !void {
        try self.errors.append(try self.allocator.dupe(u8, msg));
    }
    
    pub fn addWarning(self: *ValidationResult, msg: []const u8) !void {
        try self.warnings.append(try self.allocator.dupe(u8, msg));
    }
    
    pub fn addInfo(self: *ValidationResult, msg: []const u8) !void {
        try self.info.append(try self.allocator.dupe(u8, msg));
    }
    
    pub fn hasErrors(self: ValidationResult) bool {
        return self.errors.items.len > 0;
    }
    
    pub fn print(self: ValidationResult) void {
        for (self.info.items) |msg| {
            std.debug.print("INFO: {s}\n", .{msg});
        }
        for (self.warnings.items) |msg| {
            std.debug.print("WARNING: {s}\n", .{msg});
        }
        for (self.errors.items) |msg| {
            std.debug.print("ERROR: {s}\n", .{msg});
        }
    }
};