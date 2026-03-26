const std = @import("std");

/// Minimal index entry for status operations - only fields needed for mtime/size comparison
pub const FastIndexEntry = struct {
    mtime_seconds: u32,
    mtime_nanoseconds: u32, 
    size: u32,
    path: []const u8,  // Points into shared buffer, no separate allocation
};

/// Ultra-fast index parser optimized for status operations
pub const FastGitIndex = struct {
    entries: []FastIndexEntry,
    path_buffer: []u8,  // Single buffer for all paths
    allocator: std.mem.Allocator,
    
    pub fn deinit(self: *FastGitIndex) void {
        self.allocator.free(self.entries);
        self.allocator.free(self.path_buffer);
    }
    
    /// Parse index file in ultra-fast mode - only reads mtime, size, path
    pub fn readFromFile(allocator: std.mem.Allocator, index_path: []const u8) !FastGitIndex {
        const file = try std.fs.openFileAbsolute(index_path, .{});
        defer file.close();
        
        const file_size = try file.getEndPos();
        const content = try allocator.alloc(u8, file_size);
        defer allocator.free(content);
        _ = try file.readAll(content);
        
        return parseFast(allocator, content);
    }
    
    fn parseFast(allocator: std.mem.Allocator, data: []const u8) !FastGitIndex {
        if (data.len < 12) return error.InvalidIndex;
        
        // Quick signature check without string comparison
        if (data[0] != 'D' or data[1] != 'I' or data[2] != 'R' or data[3] != 'C') {
            return error.InvalidIndexSignature;
        }
        
        // Skip version check - assume it's valid for speed
        
        // Read number of entries (big endian) 
        const num_entries = std.mem.readInt(u32, data[8..12][0..4], .big);
        
        // Pre-allocate entries array
        const entries = try allocator.alloc(FastIndexEntry, num_entries);
        errdefer allocator.free(entries);
        
        // Estimate total path length (assume average 20 chars per path)
        const estimated_path_size = num_entries * 20;
        var path_buffer = try allocator.alloc(u8, estimated_path_size);
        errdefer allocator.free(path_buffer);
        
        var pos: usize = 12;
        var path_offset: usize = 0;
        
        for (0..num_entries) |i| {
            if (data.len < pos + 62) return error.InvalidIndexEntry;
            
            // OPTIMIZED: Skip fields we don't need for status operations
            // Skip: ctime (8 bytes), dev, ino, mode, uid, gid (5 * 4 = 20 bytes)
            // Only read: mtime (8 bytes), size (4 bytes)
            
            const mtime_seconds = std.mem.readInt(u32, data[pos + 8..pos + 12][0..4], .big);
            const mtime_nanoseconds = std.mem.readInt(u32, data[pos + 12..pos + 16][0..4], .big);
            const size = std.mem.readInt(u32, data[pos + 36..pos + 40][0..4], .big);
            
            // Skip SHA-1 hash (20 bytes) - not needed for mtime/size comparison
            
            // Read path length from flags  
            const flags = std.mem.readInt(u16, data[pos + 60..pos + 62][0..2], .big);
            const path_length = flags & 0x0FFF;
            
            pos += 62;
            
            // Read path into shared buffer
            const path_end = pos + path_length;
            if (data.len < path_end) return error.InvalidIndexEntry;
            if (path_offset + path_length > path_buffer.len) {
                // Resize path buffer if needed
                const new_size = path_buffer.len * 2;
                path_buffer = try allocator.realloc(path_buffer, new_size);
            }
            
            @memcpy(path_buffer[path_offset..path_offset + path_length], data[pos..path_end]);
            
            entries[i] = FastIndexEntry{
                .mtime_seconds = mtime_seconds,
                .mtime_nanoseconds = mtime_nanoseconds,
                .size = size,
                .path = path_buffer[path_offset..path_offset + path_length],
            };
            
            path_offset += path_length;
            pos = path_end;
            
            // Handle null terminator if present
            if (pos < data.len and data[pos] == 0) {
                pos += 1;
            }
            
            // Align to 8-byte boundary (same logic as original parser)
            const padding = (8 - ((62 + path_length + 1) % 8)) % 8;
            pos += padding;
        }
        
        // Shrink path buffer to actual size used
        path_buffer = try allocator.realloc(path_buffer, path_offset);
        
        return FastGitIndex{
            .entries = entries,
            .path_buffer = path_buffer,
            .allocator = allocator,
        };
    }
    
    /// Find entry by path (optimized O(n) search)
    pub fn findEntry(self: *const FastGitIndex, path: []const u8) ?*const FastIndexEntry {
        // Linear search is still fast for typical repo sizes
        for (self.entries) |*entry| {
            if (std.mem.eql(u8, entry.path, path)) {
                return entry;
            }
        }
        return null;
    }
};