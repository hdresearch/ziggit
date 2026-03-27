const std = @import("std");

/// Pack file cache entry to optimize repeated pack file operations
pub const PackCacheEntry = struct {
    idx_path: []const u8,
    pack_path: []const u8,
    idx_data: []const u8,
    idx_mtime: i64,
    pack_mtime: i64,
    pack_size: u64,
    object_count: u32,
    version: u32,
    
    pub fn init(allocator: std.mem.Allocator, idx_path: []const u8, pack_path: []const u8, idx_data: []const u8, idx_mtime: i64, pack_mtime: i64, pack_size: u64, object_count: u32, version: u32) !PackCacheEntry {
        return PackCacheEntry{
            .idx_path = try allocator.dupe(u8, idx_path),
            .pack_path = try allocator.dupe(u8, pack_path),
            .idx_data = try allocator.dupe(u8, idx_data),
            .idx_mtime = idx_mtime,
            .pack_mtime = pack_mtime,
            .pack_size = pack_size,
            .object_count = object_count,
            .version = version,
        };
    }
    
    pub fn deinit(self: PackCacheEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.idx_path);
        allocator.free(self.pack_path);
        allocator.free(self.idx_data);
    }
    
    /// Check if this cache entry is still valid (files haven't changed)
    pub fn isValid(self: PackCacheEntry) bool {
        // Check if index file has been modified
        if (std.fs.cwd().statFile(self.idx_path)) |idx_stat| {
            const idx_file_mtime = @divTrunc(idx_stat.mtime, std.time.ns_per_s);
            if (idx_file_mtime > self.idx_mtime) {
                return false;
            }
        } else |_| {
            // File no longer exists
            return false;
        }
        
        // Check if pack file has been modified
        if (std.fs.cwd().statFile(self.pack_path)) |pack_stat| {
            const pack_file_mtime = @divTrunc(pack_stat.mtime, std.time.ns_per_s);
            const pack_file_size = pack_stat.size;
            
            if (pack_file_mtime > self.pack_mtime or pack_file_size != self.pack_size) {
                return false;
            }
        } else |_| {
            // File no longer exists
            return false;
        }
        
        return true;
    }
};

/// Global pack file cache to optimize repeated pack operations
pub const PackCache = struct {
    entries: std.HashMap([]const u8, PackCacheEntry, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    allocator: std.mem.Allocator,
    max_entries: usize,
    total_cache_size: usize,
    max_cache_size: usize,
    hit_count: u64,
    miss_count: u64,
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .entries = std.HashMap([]const u8, PackCacheEntry, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
            .allocator = allocator,
            .max_entries = 100, // Cache up to 100 pack files
            .total_cache_size = 0,
            .max_cache_size = 100 * 1024 * 1024, // 100MB cache limit
            .hit_count = 0,
            .miss_count = 0,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.clear();
        self.entries.deinit();
    }
    
    /// Clear all cached entries
    pub fn clear(self: *Self) void {
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.entries.clearRetainingCapacity();
        self.total_cache_size = 0;
    }
    
    /// Get cached pack index data if available and valid
    pub fn get(self: *Self, idx_path: []const u8) ?PackCacheEntry {
        if (self.entries.get(idx_path)) |entry| {
            if (entry.isValid()) {
                self.hit_count += 1;
                return entry;
            } else {
                // Entry is stale, remove it
                self.remove(idx_path);
            }
        }
        
        self.miss_count += 1;
        return null;
    }
    
    /// Add a new pack cache entry
    pub fn put(self: *Self, idx_path: []const u8, entry: PackCacheEntry) !void {
        // Check cache size limits before adding
        const entry_size = entry.idx_data.len + idx_path.len + entry.pack_path.len;
        
        if (entry_size > self.max_cache_size) {
            // Entry is too large to cache
            return;
        }
        
        // Evict old entries if necessary
        try self.evictIfNecessary(entry_size);
        
        // Store the entry
        const key = try self.allocator.dupe(u8, idx_path);
        try self.entries.put(key, entry);
        self.total_cache_size += entry_size;
    }
    
    /// Remove a cached entry
    pub fn remove(self: *Self, idx_path: []const u8) void {
        if (self.entries.fetchRemove(idx_path)) |kv| {
            const entry_size = kv.value.idx_data.len + kv.key.len + kv.value.pack_path.len;
            self.total_cache_size = std.math.sub(usize, self.total_cache_size, entry_size) catch 0;
            
            self.allocator.free(kv.key);
            kv.value.deinit(self.allocator);
        }
    }
    
    /// Evict entries if cache is too full
    fn evictIfNecessary(self: *Self, new_entry_size: usize) !void {
        // Check if we need to evict based on count or size
        while (self.entries.count() >= self.max_entries or 
               self.total_cache_size + new_entry_size > self.max_cache_size) {
            
            if (self.entries.count() == 0) break;
            
            // Simple LRU-like eviction: remove first entry
            // In a production implementation, this could be more sophisticated
            var iter = self.entries.iterator();
            if (iter.next()) |entry| {
                const key_to_remove = try self.allocator.dupe(u8, entry.key_ptr.*);
                defer self.allocator.free(key_to_remove);
                self.remove(key_to_remove);
            } else {
                break;
            }
        }
    }
    
    /// Get cache statistics
    pub fn getStats(self: Self) struct {
        entries: usize,
        total_size: usize,
        hit_count: u64,
        miss_count: u64,
        hit_rate: f64,
    } {
        const total_requests = self.hit_count + self.miss_count;
        const hit_rate = if (total_requests > 0) 
            @as(f64, @floatFromInt(self.hit_count)) / @as(f64, @floatFromInt(total_requests))
        else 0.0;
        
        return .{
            .entries = self.entries.count(),
            .total_size = self.total_cache_size,
            .hit_count = self.hit_count,
            .miss_count = self.miss_count,
            .hit_rate = hit_rate,
        };
    }
    
    /// Set cache limits
    pub fn setLimits(self: *Self, max_entries: usize, max_cache_size: usize) !void {
        self.max_entries = max_entries;
        self.max_cache_size = max_cache_size;
        
        // Evict if we're now over limits
        try self.evictIfNecessary(0);
    }
    
    /// Validate all cached entries and remove stale ones
    pub fn cleanup(self: *Self) void {
        var to_remove = std.ArrayList([]const u8).init(self.allocator);
        defer {
            for (to_remove.items) |key| {
                self.allocator.free(key);
            }
            to_remove.deinit();
        }
        
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            if (!entry.value_ptr.isValid()) {
                to_remove.append(self.allocator.dupe(u8, entry.key_ptr.*) catch continue) catch continue;
            }
        }
        
        for (to_remove.items) |key| {
            self.remove(key);
        }
    }
};

/// Global pack cache instance
var global_pack_cache: ?PackCache = null;
var pack_cache_mutex: std.Thread.Mutex = .{};

/// Initialize the global pack cache
pub fn initGlobalPackCache(allocator: std.mem.Allocator) void {
    pack_cache_mutex.lock();
    defer pack_cache_mutex.unlock();
    
    if (global_pack_cache == null) {
        global_pack_cache = PackCache.init(allocator);
    }
}

/// Deinitialize the global pack cache
pub fn deinitGlobalPackCache() void {
    pack_cache_mutex.lock();
    defer pack_cache_mutex.unlock();
    
    if (global_pack_cache) |*cache| {
        cache.deinit();
        global_pack_cache = null;
    }
}

/// Get the global pack cache (thread-safe)
pub fn getGlobalPackCache() ?*PackCache {
    pack_cache_mutex.lock();
    defer pack_cache_mutex.unlock();
    
    if (global_pack_cache) |*cache| {
        return cache;
    }
    return null;
}

/// Clear the global pack cache
pub fn clearGlobalPackCache() void {
    pack_cache_mutex.lock();
    defer pack_cache_mutex.unlock();
    
    if (global_pack_cache) |*cache| {
        cache.clear();
    }
}

/// Pack file reader with caching support
pub const CachedPackReader = struct {
    git_dir: []const u8,
    allocator: std.mem.Allocator,
    
    const Self = @This();
    
    pub fn init(git_dir: []const u8, allocator: std.mem.Allocator) Self {
        return Self{
            .git_dir = git_dir,
            .allocator = allocator,
        };
    }
    
    /// Find object in pack files using cache when possible
    pub fn findObject(self: Self, hash: []const u8, platform_impl: anytype) !?[]u8 {
        const pack_dir = try std.fmt.allocPrint(self.allocator, "{s}/objects/pack", .{self.git_dir});
        defer self.allocator.free(pack_dir);
        
        // Get list of pack files
        const entries = platform_impl.fs.readDir(self.allocator, pack_dir) catch return null;
        defer {
            for (entries) |entry| {
                self.allocator.free(entry);
            }
            self.allocator.free(entries);
        }
        
        // Check each .idx file
        for (entries) |entry| {
            if (!std.mem.endsWith(u8, entry, ".idx")) continue;
            
            const idx_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ pack_dir, entry });
            defer self.allocator.free(idx_path);
            
            // Try to use cached data
            if (getGlobalPackCache()) |cache| {
                if (cache.get(idx_path)) |cached_entry| {
                    // Use cached index data
                    if (self.searchInIndexData(cached_entry.idx_data, hash)) |offset| {
                        const pack_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}.pack", .{ pack_dir, entry[0..entry.len-4] });
                        defer self.allocator.free(pack_path);
                        
                        return self.readObjectFromPackAtOffset(pack_path, offset, platform_impl);
                    }
                    continue;
                }
            }
            
            // Cache miss, read index file
            const idx_data = platform_impl.fs.readFile(self.allocator, idx_path) catch continue;
            defer self.allocator.free(idx_data);
            
            // Check if object is in this pack
            if (self.searchInIndexData(idx_data, hash)) |offset| {
                // Found the object, cache the index data for future use
                if (getGlobalPackCache()) |cache| {
                    if (std.fs.cwd().statFile(idx_path)) |idx_stat| {
                        const pack_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}.pack", .{ pack_dir, entry[0..entry.len-4] });
                        defer self.allocator.free(pack_path);
                        
                        if (std.fs.cwd().statFile(pack_path)) |pack_stat| {
                            const cache_entry = PackCacheEntry.init(
                                self.allocator,
                                idx_path,
                                pack_path,
                                idx_data,
                                @divTrunc(idx_stat.mtime, std.time.ns_per_s),
                                @divTrunc(pack_stat.mtime, std.time.ns_per_s),
                                pack_stat.size,
                                self.getObjectCountFromIndex(idx_data),
                                self.getVersionFromIndex(idx_data)
                            ) catch continue;
                            
                            cache.put(idx_path, cache_entry) catch {};
                        }
                    }
                }
                
                const pack_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}.pack", .{ pack_dir, entry[0..entry.len-4] });
                defer self.allocator.free(pack_path);
                
                return self.readObjectFromPackAtOffset(pack_path, offset, platform_impl);
            }
        }
        
        return null;
    }
    
    /// Search for object in index data
    fn searchInIndexData(self: Self, idx_data: []const u8, hash: []const u8) ?u64 {
        _ = self;
        
        if (idx_data.len < 8) return null;
        if (hash.len != 40) return null;
        
        // Convert hash to bytes
        var target_hash: [20]u8 = undefined;
        _ = std.fmt.hexToBytes(&target_hash, hash) catch return null;
        
        // Check for v2 format
        const magic = std.mem.readInt(u32, @ptrCast(idx_data[0..4]), .big);
        if (magic != 0xff744f63) return null; // Only handle v2 for now
        
        const version = std.mem.readInt(u32, @ptrCast(idx_data[4..8]), .big);
        if (version != 2) return null;
        
        // Use fanout table for quick lookup
        const fanout_start = 8;
        const first_byte = target_hash[0];
        
        if (idx_data.len < fanout_start + 256 * 4) return null;
        
        const start_index = if (first_byte == 0) 0 else 
            std.mem.readInt(u32, @ptrCast(idx_data[fanout_start + (@as(usize, first_byte) - 1) * 4..fanout_start + (@as(usize, first_byte) - 1) * 4 + 4]), .big);
        const end_index = 
            std.mem.readInt(u32, @ptrCast(idx_data[fanout_start + @as(usize, first_byte) * 4..fanout_start + @as(usize, first_byte) * 4 + 4]), .big);
        
        if (start_index >= end_index) return null;
        
        // Binary search in SHA-1 table
        const total_objects = std.mem.readInt(u32, @ptrCast(idx_data[fanout_start + 255 * 4..fanout_start + 255 * 4 + 4]), .big);
        const sha1_table_start = fanout_start + 256 * 4;
        
        var low = start_index;
        var high = end_index;
        
        while (low < high) {
            const mid = low + (high - low) / 2;
            const sha_offset = sha1_table_start + @as(usize, mid) * 20;
            
            if (sha_offset + 20 > idx_data.len) return null;
            
            const obj_hash = idx_data[sha_offset..sha_offset + 20];
            const cmp = std.mem.order(u8, obj_hash, &target_hash);
            
            switch (cmp) {
                .eq => {
                    // Found it, get offset from offset table
                    const crc_table_start = sha1_table_start + @as(usize, total_objects) * 20;
                    const offset_table_start = crc_table_start + @as(usize, total_objects) * 4;
                    const offset_offset = offset_table_start + @as(usize, mid) * 4;
                    
                    if (offset_offset + 4 > idx_data.len) return null;
                    
                    var offset: u64 = std.mem.readInt(u32, @ptrCast(idx_data[offset_offset..offset_offset + 4]), .big);
                    
                    // Handle 64-bit offsets
                    if (offset & 0x80000000 != 0) {
                        const large_offset_index = offset & 0x7FFFFFFF;
                        const large_offset_table_start = offset_table_start + @as(usize, total_objects) * 4;
                        const large_offset_offset = large_offset_table_start + @as(usize, large_offset_index) * 8;
                        
                        if (large_offset_offset + 8 > idx_data.len) return null;
                        
                        offset = std.mem.readInt(u64, @ptrCast(idx_data[large_offset_offset..large_offset_offset + 8]), .big);
                    }
                    
                    return offset;
                },
                .lt => low = mid + 1,
                .gt => high = mid,
            }
        }
        
        return null;
    }
    
    /// Extract object count from index header
    fn getObjectCountFromIndex(self: Self, idx_data: []const u8) u32 {
        _ = self;
        
        if (idx_data.len < 8) return 0;
        
        const magic = std.mem.readInt(u32, @ptrCast(idx_data[0..4]), .big);
        if (magic != 0xff744f63) return 0;
        
        // For v2, object count is in the last fanout entry
        if (idx_data.len >= 8 + 256 * 4) {
            return std.mem.readInt(u32, @ptrCast(idx_data[8 + 255 * 4..8 + 255 * 4 + 4]), .big);
        }
        
        return 0;
    }
    
    /// Extract version from index header
    fn getVersionFromIndex(self: Self, idx_data: []const u8) u32 {
        _ = self;
        
        if (idx_data.len < 8) return 0;
        
        const magic = std.mem.readInt(u32, @ptrCast(idx_data[0..4]), .big);
        if (magic == 0xff744f63) {
            return std.mem.readInt(u32, @ptrCast(idx_data[4..8]), .big);
        }
        
        return 1; // Assume v1 if no magic
    }
    
    /// Read object from pack file at specific offset
    fn readObjectFromPackAtOffset(self: Self, pack_path: []const u8, offset: u64, platform_impl: anytype) ![]u8 {
        const pack_data = platform_impl.fs.readFile(self.allocator, pack_path) catch return error.PackFileNotFound;
        defer self.allocator.free(pack_data);
        
        // This would integrate with the existing readPackedObject function
        // For now, return a placeholder
        _ = offset;
        return error.NotImplemented;
    }
};

test "pack cache basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var cache = PackCache.init(allocator);
    defer cache.deinit();
    
    // Test empty cache
    try testing.expectEqual(@as(usize, 0), cache.entries.count());
    try testing.expect(cache.get("nonexistent") == null);
    
    // Test cache stats
    const stats = cache.getStats();
    try testing.expectEqual(@as(u64, 0), stats.hit_count);
    try testing.expectEqual(@as(u64, 1), stats.miss_count); // From the get() call above
}

test "pack cache entry validation" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    // Create a temporary file for testing
    const test_file = "/tmp/test_pack.idx";
    try std.fs.cwd().writeFile(test_file, "test content");
    defer std.fs.cwd().deleteFile(test_file) catch {};
    
    const entry = try PackCacheEntry.init(
        allocator,
        test_file,
        "/tmp/test_pack.pack",
        "test data",
        std.time.timestamp(),
        std.time.timestamp(),
        1024,
        10,
        2
    );
    defer entry.deinit(allocator);
    
    // Entry should be valid since we just created it
    try testing.expect(entry.isValid());
}