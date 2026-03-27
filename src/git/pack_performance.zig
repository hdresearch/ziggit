const std = @import("std");

/// Simple LRU cache for pack file data to avoid repeated reads
pub const PackFileCache = struct {
    const CacheEntry = struct {
        path: []const u8,
        data: []const u8,
        last_access: i64,
        
        pub fn deinit(self: CacheEntry, allocator: std.mem.Allocator) void {
            allocator.free(self.path);
            allocator.free(self.data);
        }
    };
    
    entries: std.array_list.Managed(CacheEntry),
    allocator: std.mem.Allocator,
    max_entries: usize,
    max_total_size: usize,
    current_total_size: usize,
    
    pub fn init(allocator: std.mem.Allocator, max_entries: usize, max_total_size: usize) PackFileCache {
        return PackFileCache{
            .entries = std.array_list.Managed(CacheEntry).init(allocator),
            .allocator = allocator,
            .max_entries = max_entries,
            .max_total_size = max_total_size,
            .current_total_size = 0,
        };
    }
    
    pub fn deinit(self: *PackFileCache) void {
        for (self.entries.items) |entry| {
            entry.deinit(self.allocator);
        }
        self.entries.deinit();
    }
    
    /// Get cached pack file data or null if not cached
    pub fn get(self: *PackFileCache, path: []const u8) ?[]const u8 {
        const now = std.time.timestamp();
        
        for (self.entries.items, 0..) |*entry, i| {
            if (std.mem.eql(u8, entry.path, path)) {
                entry.last_access = now;
                
                // Move to front (LRU)
                if (i > 0) {
                    const moved_entry = self.entries.swapRemove(i);
                    self.entries.insert(0, moved_entry) catch {
                        // If insert fails, just put it back
                        self.entries.insert(i, moved_entry) catch unreachable;
                    };
                    return self.entries.items[0].data;
                }
                
                return entry.data;
            }
        }
        
        return null;
    }
    
    /// Store pack file data in cache
    pub fn put(self: *PackFileCache, path: []const u8, data: []const u8) !void {
        // Don't cache very large files
        if (data.len > self.max_total_size / 2) {
            return;
        }
        
        const now = std.time.timestamp();
        
        // Check if already exists and update
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.path, path)) {
                entry.last_access = now;
                // Don't update data, assume it hasn't changed
                return;
            }
        }
        
        // Make room if needed
        while (self.current_total_size + data.len > self.max_total_size or 
               self.entries.items.len >= self.max_entries) {
            if (self.entries.items.len == 0) break;
            
            // Remove least recently used (last in list after LRU moves to front)
            const removed = self.entries.pop();
            self.current_total_size -= removed.data.len;
            removed.deinit(self.allocator);
        }
        
        // Add new entry
        const new_entry = CacheEntry{
            .path = try self.allocator.dupe(u8, path),
            .data = try self.allocator.dupe(u8, data),
            .last_access = now,
        };
        
        try self.entries.insert(0, new_entry); // Insert at front
        self.current_total_size += data.len;
    }
    
    /// Clear all cached entries
    pub fn clear(self: *PackFileCache) void {
        for (self.entries.items) |entry| {
            entry.deinit(self.allocator);
        }
        self.entries.clearRetainingCapacity();
        self.current_total_size = 0;
    }
    
    /// Get cache statistics
    pub fn getStats(self: PackFileCache) CacheStats {
        return CacheStats{
            .entry_count = self.entries.items.len,
            .total_size = self.current_total_size,
            .max_entries = self.max_entries,
            .max_total_size = self.max_total_size,
        };
    }
};

pub const CacheStats = struct {
    entry_count: usize,
    total_size: usize,
    max_entries: usize,
    max_total_size: usize,
    
    pub fn utilization(self: CacheStats) f32 {
        return @as(f32, @floatFromInt(self.total_size)) / @as(f32, @floatFromInt(self.max_total_size));
    }
    
    pub fn print(self: CacheStats) void {
        std.debug.print("Pack Cache Stats:\n");
        std.debug.print("  Entries: {}/{}\n", .{self.entry_count, self.max_entries});
        std.debug.print("  Size: {}/{} bytes ({d:.1}%)\n", .{self.total_size, self.max_total_size, self.utilization() * 100});
    }
};

/// Performance monitoring for pack operations
pub const PackPerformanceMonitor = struct {
    total_pack_reads: u64,
    total_bytes_read: u64,
    cache_hits: u64,
    cache_misses: u64,
    start_time: i64,
    
    pub fn init() PackPerformanceMonitor {
        return PackPerformanceMonitor{
            .total_pack_reads = 0,
            .total_bytes_read = 0,
            .cache_hits = 0,
            .cache_misses = 0,
            .start_time = std.time.timestamp(),
        };
    }
    
    pub fn recordPackRead(self: *PackPerformanceMonitor, bytes_read: usize) void {
        self.total_pack_reads += 1;
        self.total_bytes_read += bytes_read;
    }
    
    pub fn recordCacheHit(self: *PackPerformanceMonitor) void {
        self.cache_hits += 1;
    }
    
    pub fn recordCacheMiss(self: *PackPerformanceMonitor) void {
        self.cache_misses += 1;
    }
    
    pub fn getCacheHitRate(self: PackPerformanceMonitor) f32 {
        const total_requests = self.cache_hits + self.cache_misses;
        if (total_requests == 0) return 0.0;
        return @as(f32, @floatFromInt(self.cache_hits)) / @as(f32, @floatFromInt(total_requests));
    }
    
    pub fn getAveragePackSize(self: PackPerformanceMonitor) f32 {
        if (self.total_pack_reads == 0) return 0.0;
        return @as(f32, @floatFromInt(self.total_bytes_read)) / @as(f32, @floatFromInt(self.total_pack_reads));
    }
    
    pub fn getElapsedTime(self: PackPerformanceMonitor) i64 {
        return std.time.timestamp() - self.start_time;
    }
    
    pub fn print(self: PackPerformanceMonitor) void {
        const elapsed = self.getElapsedTime();
        std.debug.print("Pack Performance Stats:\n");
        std.debug.print("  Total pack reads: {}\n", .{self.total_pack_reads});
        std.debug.print("  Total bytes read: {} ({d:.1} KB)\n", .{self.total_bytes_read, @as(f32, @floatFromInt(self.total_bytes_read)) / 1024.0});
        std.debug.print("  Cache hit rate: {d:.1}% ({}/{} requests)\n", .{self.getCacheHitRate() * 100, self.cache_hits, self.cache_hits + self.cache_misses});
        std.debug.print("  Average pack size: {d:.1} KB\n", .{self.getAveragePackSize() / 1024.0});
        std.debug.print("  Elapsed time: {}s\n", .{elapsed});
    }
};

/// Enhanced pack file reader with caching and performance monitoring
pub const CachedPackReader = struct {
    cache: PackFileCache,
    monitor: PackPerformanceMonitor,
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator, cache_size_mb: usize, max_entries: usize) CachedPackReader {
        return CachedPackReader{
            .cache = PackFileCache.init(allocator, max_entries, cache_size_mb * 1024 * 1024),
            .monitor = PackPerformanceMonitor.init(),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *CachedPackReader) void {
        self.cache.deinit();
    }
    
    /// Read pack file data with caching
    pub fn readPackFile(self: *CachedPackReader, path: []const u8, platform_impl: anytype) ![]u8 {
        // Check cache first
        if (self.cache.get(path)) |cached_data| {
            self.monitor.recordCacheHit();
            return try self.allocator.dupe(u8, cached_data);
        }
        
        // Cache miss - read from filesystem
        self.monitor.recordCacheMiss();
        const data = try platform_impl.fs.readFile(self.allocator, path);
        self.monitor.recordPackRead(data.len);
        
        // Try to cache the data
        self.cache.put(path, data) catch {
            // Cache failure is not critical, continue without caching
        };
        
        return data;
    }
    
    /// Get performance statistics
    pub fn getStats(self: CachedPackReader) struct { cache: CacheStats, performance: PackPerformanceMonitor } {
        return .{
            .cache = self.cache.getStats(),
            .performance = self.monitor,
        };
    }
    
    /// Print comprehensive statistics
    pub fn printStats(self: CachedPackReader) void {
        self.cache.getStats().print();
        std.debug.print("\n");
        self.monitor.print();
    }
};

/// Pack file compression analyzer
pub const PackCompressionAnalyzer = struct {
    total_uncompressed: u64,
    total_compressed: u64,
    object_count: u64,
    
    pub fn init() PackCompressionAnalyzer {
        return PackCompressionAnalyzer{
            .total_uncompressed = 0,
            .total_compressed = 0,
            .object_count = 0,
        };
    }
    
    pub fn recordObject(self: *PackCompressionAnalyzer, uncompressed_size: u64, compressed_size: u64) void {
        self.total_uncompressed += uncompressed_size;
        self.total_compressed += compressed_size;
        self.object_count += 1;
    }
    
    pub fn getCompressionRatio(self: PackCompressionAnalyzer) f32 {
        if (self.total_uncompressed == 0) return 0.0;
        return @as(f32, @floatFromInt(self.total_compressed)) / @as(f32, @floatFromInt(self.total_uncompressed));
    }
    
    pub fn getSpaceSavings(self: PackCompressionAnalyzer) u64 {
        if (self.total_uncompressed > self.total_compressed) {
            return self.total_uncompressed - self.total_compressed;
        }
        return 0;
    }
    
    pub fn print(self: PackCompressionAnalyzer) void {
        const ratio = self.getCompressionRatio();
        const savings = self.getSpaceSavings();
        
        std.debug.print("Pack Compression Analysis:\n");
        std.debug.print("  Objects analyzed: {}\n", .{self.object_count});
        std.debug.print("  Uncompressed total: {} KB\n", .{self.total_uncompressed / 1024});
        std.debug.print("  Compressed total: {} KB\n", .{self.total_compressed / 1024});
        std.debug.print("  Compression ratio: {d:.2}:1\n", .{1.0 / ratio});
        std.debug.print("  Space savings: {} KB ({d:.1}%)\n", .{savings / 1024, (1.0 - ratio) * 100});
    }
};

test "pack file cache basic operations" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var cache = PackFileCache.init(allocator, 3, 1024);
    defer cache.deinit();
    
    // Test put and get
    try cache.put("/path/to/pack1.pack", "data1");
    try cache.put("/path/to/pack2.pack", "data22");
    
    try testing.expectEqualStrings("data1", cache.get("/path/to/pack1.pack").?);
    try testing.expectEqualStrings("data22", cache.get("/path/to/pack2.pack").?);
    
    // Test miss
    try testing.expect(cache.get("/nonexistent.pack") == null);
    
    // Test LRU eviction
    try cache.put("/path/to/pack3.pack", "data333");
    try cache.put("/path/to/pack4.pack", "data4444");
    
    // pack1 should be evicted (max 3 entries)
    try testing.expect(cache.get("/path/to/pack1.pack") == null);
    try testing.expectEqualStrings("data22", cache.get("/path/to/pack2.pack").?);
}

test "pack file cache size limits" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var cache = PackFileCache.init(allocator, 10, 50); // Bigger size limit for test
    defer cache.deinit();
    
    // Add small data that fits
    try cache.put("/small.pack", "small");
    try testing.expectEqualStrings("small", cache.get("/small.pack").?);
    
    // Add medium data 
    try cache.put("/medium.pack", "medium_data_here");
    
    // Both should be there initially
    try testing.expect(cache.get("/small.pack") != null);
    try testing.expect(cache.get("/medium.pack") != null);
    
    // Very large data should be rejected (larger than max_total_size/2)
    const large_data = "a" ** 30; // Larger than max_total_size/2 (25)
    try cache.put("/large.pack", large_data);
    try testing.expect(cache.get("/large.pack") == null); // Should not be cached
}

test "performance monitor" {
    const testing = std.testing;
    
    var monitor = PackPerformanceMonitor.init();
    
    // Test basic recording
    monitor.recordPackRead(1024);
    monitor.recordPackRead(2048);
    monitor.recordCacheHit();
    monitor.recordCacheMiss();
    monitor.recordCacheMiss();
    
    try testing.expectEqual(@as(u64, 2), monitor.total_pack_reads);
    try testing.expectEqual(@as(u64, 3072), monitor.total_bytes_read);
    try testing.expectEqual(@as(u64, 1), monitor.cache_hits);
    try testing.expectEqual(@as(u64, 2), monitor.cache_misses);
    
    // Test calculations
    try testing.expectApproxEqAbs(@as(f32, 1536.0), monitor.getAveragePackSize(), 0.1);
    try testing.expectApproxEqAbs(@as(f32, 0.333), monitor.getCacheHitRate(), 0.01);
}

test "compression analyzer" {
    const testing = std.testing;
    
    var analyzer = PackCompressionAnalyzer.init();
    
    analyzer.recordObject(1000, 400);  // 40% compression
    analyzer.recordObject(2000, 600);  // 30% compression
    analyzer.recordObject(3000, 900);  // 30% compression
    
    try testing.expectEqual(@as(u64, 3), analyzer.object_count);
    try testing.expectEqual(@as(u64, 6000), analyzer.total_uncompressed);
    try testing.expectEqual(@as(u64, 1900), analyzer.total_compressed);
    
    const ratio = analyzer.getCompressionRatio();
    try testing.expectApproxEqAbs(@as(f32, 0.317), ratio, 0.01);
    
    const savings = analyzer.getSpaceSavings();
    try testing.expectEqual(@as(u64, 4100), savings);
}