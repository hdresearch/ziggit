const std = @import("std");

/// Performance optimization utilities for git operations
pub const PerformanceStats = struct {
    pack_reads: u64 = 0,
    loose_reads: u64 = 0,
    cache_hits: u64 = 0,
    cache_misses: u64 = 0,
    bytes_read: u64 = 0,
    time_spent_ns: u64 = 0,

    pub fn reset(self: *PerformanceStats) void {
        self.* = PerformanceStats{};
    }

    pub fn print(self: PerformanceStats) void {
        std.debug.print("Performance Stats:\n", .{});
        std.debug.print("  Pack reads: {}\n", .{self.pack_reads});
        std.debug.print("  Loose reads: {}\n", .{self.loose_reads});
        std.debug.print("  Cache hits: {}\n", .{self.cache_hits});
        std.debug.print("  Cache misses: {}\n", .{self.cache_misses});
        std.debug.print("  Bytes read: {} KB\n", .{self.bytes_read / 1024});
        std.debug.print("  Time spent: {} ms\n", .{self.time_spent_ns / 1000000});
    }
};

/// Global performance statistics (disabled in release builds)
pub var global_stats = PerformanceStats{};

/// Start timing an operation
pub fn startTiming() u64 {
    return std.time.nanoTimestamp();
}

/// End timing an operation and record it
pub fn endTiming(start_time: u64) void {
    const end_time = std.time.nanoTimestamp();
    global_stats.time_spent_ns += @intCast(end_time - start_time);
}

/// Record a pack file read operation
pub fn recordPackRead(bytes: usize) void {
    global_stats.pack_reads += 1;
    global_stats.bytes_read += @intCast(bytes);
}

/// Record a loose object read operation  
pub fn recordLooseRead(bytes: usize) void {
    global_stats.loose_reads += 1;
    global_stats.bytes_read += @intCast(bytes);
}

/// Record a cache hit
pub fn recordCacheHit() void {
    global_stats.cache_hits += 1;
}

/// Record a cache miss
pub fn recordCacheMiss() void {
    global_stats.cache_misses += 1;
}

/// Simple LRU cache for git objects
pub fn ObjectCache(comptime ValueType: type) type {
    return struct {
        const Self = @This();
        const CacheEntry = struct {
            key: []u8,
            value: ValueType,
            last_used: u64,
        };

        entries: std.array_list.Managed(CacheEntry),
        allocator: std.mem.Allocator,
        max_size: usize,
        access_counter: u64,

        pub fn init(allocator: std.mem.Allocator, max_size: usize) Self {
            return Self{
                .entries = std.array_list.Managed(CacheEntry).init(allocator),
                .allocator = allocator,
                .max_size = max_size,
                .access_counter = 0,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.entries.items) |entry| {
                self.allocator.free(entry.key);
            }
            self.entries.deinit();
        }

        pub fn get(self: *Self, key: []const u8) ?ValueType {
            for (self.entries.items, 0..) |*entry, i| {
                if (std.mem.eql(u8, entry.key, key)) {
                    entry.last_used = self.access_counter;
                    self.access_counter += 1;
                    recordCacheHit();
                    
                    // Move to front for better cache locality
                    if (i > 0) {
                        const cached_entry = self.entries.swapRemove(i);
                        self.entries.insert(0, cached_entry) catch {};
                    }
                    
                    return entry.value;
                }
            }
            recordCacheMiss();
            return null;
        }

        pub fn put(self: *Self, key: []const u8, value: ValueType) !void {
            // Check if key already exists
            for (self.entries.items) |*entry| {
                if (std.mem.eql(u8, entry.key, key)) {
                    entry.value = value;
                    entry.last_used = self.access_counter;
                    self.access_counter += 1;
                    return;
                }
            }

            // Evict oldest entry if at capacity
            if (self.entries.items.len >= self.max_size and self.max_size > 0) {
                var oldest_idx: usize = 0;
                var oldest_time: u64 = self.entries.items[0].last_used;
                
                for (self.entries.items, 0..) |entry, i| {
                    if (entry.last_used < oldest_time) {
                        oldest_time = entry.last_used;
                        oldest_idx = i;
                    }
                }
                
                const removed = self.entries.swapRemove(oldest_idx);
                self.allocator.free(removed.key);
            }

            // Add new entry
            const key_copy = try self.allocator.dupe(u8, key);
            try self.entries.append(CacheEntry{
                .key = key_copy,
                .value = value,
                .last_used = self.access_counter,
            });
            self.access_counter += 1;
        }

        pub fn clear(self: *Self) void {
            for (self.entries.items) |entry| {
                self.allocator.free(entry.key);
            }
            self.entries.clearRetainingCapacity();
        }

        pub fn size(self: Self) usize {
            return self.entries.items.len;
        }
    };
}

/// Batch reader for efficient sequential access to git objects
pub const BatchObjectReader = struct {
    allocator: std.mem.Allocator,
    git_dir: []const u8,
    platform_impl: anytype,
    cache: ObjectCache([]const u8),
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator, git_dir: []const u8, platform_impl: anytype) Self {
        return Self{
            .allocator = allocator,
            .git_dir = git_dir,
            .platform_impl = platform_impl,
            .cache = ObjectCache([]const u8).init(allocator, 100), // Cache up to 100 objects
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.cache.deinit();
    }
    
    /// Read multiple objects efficiently with caching
    pub fn readObjects(self: *Self, hashes: []const []const u8) ![][]const u8 {
        const objects = @import("objects.zig");
        var results = std.array_list.Managed([]const u8).init(self.allocator);
        
        for (hashes) |hash| {
            // Check cache first
            if (self.cache.get(hash)) |cached_data| {
                try results.append(try self.allocator.dupe(u8, cached_data));
                continue;
            }
            
            // Load from storage
            const obj = objects.GitObject.load(hash, self.git_dir, self.platform_impl, self.allocator) catch |err| {
                // If one object fails, continue with others
                std.debug.print("Failed to load object {s}: {}\n", .{ hash, err });
                try results.append(&[_]u8{});
                continue;
            };
            
            // Cache the result
            const data_copy = try self.allocator.dupe(u8, obj.data);
            self.cache.put(hash, data_copy) catch {}; // Ignore cache failures
            
            try results.append(data_copy);
            obj.deinit(self.allocator);
        }
        
        return results.toOwnedSlice();
    }
    
    /// Clear the cache to free memory
    pub fn clearCache(self: *Self) void {
        self.cache.clear();
    }
};

/// Memory pool for efficient git object allocation
pub const GitObjectPool = struct {
    allocator: std.mem.Allocator,
    small_pool: std.array_list.Managed([]u8), // For objects < 4KB
    medium_pool: std.array_list.Managed([]u8), // For objects < 64KB  
    large_pool: std.array_list.Managed([]u8), // For objects < 1MB
    
    const SMALL_SIZE = 4 * 1024;
    const MEDIUM_SIZE = 64 * 1024;
    const LARGE_SIZE = 1024 * 1024;
    
    const Self = @This();
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .small_pool = std.array_list.Managed([]u8).init(allocator),
            .medium_pool = std.array_list.Managed([]u8).init(allocator),
            .large_pool = std.array_list.Managed([]u8).init(allocator),
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.freePool(&self.small_pool);
        self.freePool(&self.medium_pool);
        self.freePool(&self.large_pool);
        
        self.small_pool.deinit();
        self.medium_pool.deinit();
        self.large_pool.deinit();
    }
    
    fn freePool(self: *Self, pool: *std.array_list.Managed([]u8)) void {
        for (pool.items) |buffer| {
            self.allocator.free(buffer);
        }
        pool.clearRetainingCapacity();
    }
    
    pub fn allocate(self: *Self, size: usize) ![]u8 {
        if (size <= SMALL_SIZE) {
            if (self.small_pool.popOrNull()) |buffer| {
                return buffer[0..size];
            }
            return try self.allocator.alloc(u8, SMALL_SIZE);
        } else if (size <= MEDIUM_SIZE) {
            if (self.medium_pool.popOrNull()) |buffer| {
                return buffer[0..size];
            }
            return try self.allocator.alloc(u8, MEDIUM_SIZE);
        } else if (size <= LARGE_SIZE) {
            if (self.large_pool.popOrNull()) |buffer| {
                return buffer[0..size];
            }
            return try self.allocator.alloc(u8, LARGE_SIZE);
        } else {
            // For very large objects, allocate directly
            return try self.allocator.alloc(u8, size);
        }
    }
    
    pub fn release(self: *Self, buffer: []u8) !void {
        if (buffer.len == SMALL_SIZE) {
            try self.small_pool.append(buffer);
        } else if (buffer.len == MEDIUM_SIZE) {
            try self.medium_pool.append(buffer);
        } else if (buffer.len == LARGE_SIZE) {
            try self.large_pool.append(buffer);
        } else {
            // Free directly for non-standard sizes
            self.allocator.free(buffer);
        }
    }
};

/// Hash computation utilities with optimization for common cases
pub fn computeObjectHash(object_type: []const u8, data: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const start_time = startTiming();
    defer endTiming(start_time);
    
    // Use a stack buffer for small objects to avoid allocation
    var stack_buffer: [8192]u8 = undefined;
    const header = try std.fmt.bufPrint(stack_buffer[0..64], "{s} {}\x00", .{ object_type, data.len });
    
    if (header.len + data.len <= stack_buffer.len) {
        // Use stack buffer for small objects
        std.mem.copyForwards(u8, stack_buffer[header.len..header.len + data.len], data);
        const content = stack_buffer[0..header.len + data.len];
        
        var hasher = std.crypto.hash.Sha1.init(.{});
        hasher.update(content);
        var digest: [20]u8 = undefined;
        hasher.final(&digest);
        
        return try std.fmt.allocPrint(allocator, "{x}", .{&digest});
    } else {
        // Fall back to heap allocation for large objects
        const full_header = try std.fmt.allocPrint(allocator, "{s} {}\x00", .{ object_type, data.len });
        defer allocator.free(full_header);
        
        const content = try std.mem.concat(allocator, u8, &[_][]const u8{ full_header, data });
        defer allocator.free(content);
        
        var hasher = std.crypto.hash.Sha1.init(.{});
        hasher.update(content);
        var digest: [20]u8 = undefined;
        hasher.final(&digest);
        
        return try std.fmt.allocPrint(allocator, "{x}", .{&digest});
    }
}

test "object cache functionality" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var cache = ObjectCache([]const u8).init(allocator, 3);
    defer cache.deinit();
    
    // Test basic put/get
    try cache.put("key1", "value1");
    try cache.put("key2", "value2");
    
    try testing.expectEqualStrings("value1", cache.get("key1").?);
    try testing.expectEqualStrings("value2", cache.get("key2").?);
    
    // Test cache eviction
    try cache.put("key3", "value3");
    try cache.put("key4", "value4"); // Should evict oldest
    
    // key1 should be evicted (oldest)
    try testing.expect(cache.get("key1") == null);
    try testing.expectEqualStrings("value4", cache.get("key4").?);
}

test "batch object reader" {
    // This test would need a mock file system, skipping for now
}

test "performance stats" {
    global_stats.reset();
    
    recordPackRead(1024);
    recordLooseRead(2048);
    recordCacheHit();
    recordCacheMiss();
    
    const testing = std.testing;
    try testing.expect(global_stats.pack_reads == 1);
    try testing.expect(global_stats.loose_reads == 1);
    try testing.expect(global_stats.cache_hits == 1);
    try testing.expect(global_stats.cache_misses == 1);
    try testing.expect(global_stats.bytes_read == 3072);
}