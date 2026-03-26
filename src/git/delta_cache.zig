const std = @import("std");

/// Bounded LRU cache for decompressed delta base objects.
/// Tracks total memory usage and evicts least-recently-used entries
/// when the budget is exceeded.
pub const DeltaCache = struct {
    const Self = @This();

    /// A cached entry: type string + owned data slice.
    pub const Entry = struct {
        type_str: []const u8, // static string, not owned
        data: []u8, // owned by the cache
    };

    allocator: std.mem.Allocator,
    entries: std.AutoHashMap(usize, Entry),
    /// Tracks access order (front = oldest, back = newest).
    order: std.ArrayList(usize),
    total_bytes: usize,
    max_bytes: usize,
    hits: u64,
    misses: u64,

    pub fn init(allocator: std.mem.Allocator, max_bytes: usize) Self {
        return .{
            .allocator = allocator,
            .entries = std.AutoHashMap(usize, Entry).init(allocator),
            .order = std.ArrayList(usize).init(allocator),
            .total_bytes = 0,
            .max_bytes = max_bytes,
            .hits = 0,
            .misses = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.entries.valueIterator();
        while (it.next()) |v| {
            self.allocator.free(v.data);
        }
        self.entries.deinit();
        self.order.deinit();
    }

    /// Look up an entry by pack offset. Returns borrowed reference (do NOT free).
    pub fn get(self: *Self, offset: usize) ?Entry {
        if (self.entries.get(offset)) |entry| {
            self.hits += 1;
            // Move to back of LRU order (mark as recently used)
            self.touchOrder(offset);
            return entry;
        }
        self.misses += 1;
        return null;
    }

    /// Insert an entry. The cache takes ownership of `data`.
    /// Evicts oldest entries if over memory budget.
    pub fn put(self: *Self, offset: usize, type_str: []const u8, data: []u8) !void {
        // If already present, replace
        if (self.entries.fetchRemove(offset)) |old| {
            self.total_bytes -= old.value.data.len;
            self.allocator.free(old.value.data);
        }

        // Evict until we have room
        while (self.total_bytes + data.len > self.max_bytes and self.order.items.len > 0) {
            self.evictOldest();
        }

        try self.entries.put(offset, .{ .type_str = type_str, .data = data });
        try self.order.append(offset);
        self.total_bytes += data.len;
    }

    /// Insert by duping the data (caller retains ownership of original).
    pub fn putDupe(self: *Self, offset: usize, type_str: []const u8, data: []const u8) !void {
        const owned = try self.allocator.dupe(u8, data);
        self.put(offset, type_str, owned) catch |err| {
            self.allocator.free(owned);
            return err;
        };
    }

    fn evictOldest(self: *Self) void {
        if (self.order.items.len == 0) return;
        const oldest_offset = self.order.orderedRemove(0);
        if (self.entries.fetchRemove(oldest_offset)) |removed| {
            self.total_bytes -= removed.value.data.len;
            self.allocator.free(removed.value.data);
        }
    }

    fn touchOrder(self: *Self, offset: usize) void {
        // Remove from current position and push to back
        for (self.order.items, 0..) |item, i| {
            if (item == offset) {
                _ = self.order.orderedRemove(i);
                self.order.append(offset) catch {};
                return;
            }
        }
    }

    /// Number of cached entries.
    pub fn count(self: Self) usize {
        return self.entries.count();
    }

    /// Current memory usage in bytes.
    pub fn memoryUsage(self: Self) usize {
        return self.total_bytes;
    }

    pub fn hitRate(self: Self) f64 {
        const total = self.hits + self.misses;
        if (total == 0) return 0.0;
        return @as(f64, @floatFromInt(self.hits)) / @as(f64, @floatFromInt(total));
    }
};

// ── Tests ──────────────────────────────────────────────────────────────

test "DeltaCache basic put and get" {
    const allocator = std.testing.allocator;
    var cache = DeltaCache.init(allocator, 1024);
    defer cache.deinit();

    const data = try allocator.dupe(u8, "hello world");
    try cache.put(100, "blob", data);

    const entry = cache.get(100).?;
    try std.testing.expectEqualSlices(u8, "hello world", entry.data);
    try std.testing.expectEqualSlices(u8, "blob", entry.type_str);
    try std.testing.expectEqual(@as(usize, 1), cache.count());
}

test "DeltaCache evicts when over budget" {
    const allocator = std.testing.allocator;
    // Budget: 20 bytes
    var cache = DeltaCache.init(allocator, 20);
    defer cache.deinit();

    // Insert 3 entries of ~10 bytes each; budget is 20, so oldest should be evicted
    const d1 = try allocator.dupe(u8, "aaaaaaaaaa"); // 10 bytes
    try cache.put(1, "blob", d1);
    try std.testing.expectEqual(@as(usize, 10), cache.memoryUsage());

    const d2 = try allocator.dupe(u8, "bbbbbbbbbb"); // 10 bytes
    try cache.put(2, "blob", d2);
    try std.testing.expectEqual(@as(usize, 20), cache.memoryUsage());

    // This should evict entry 1 to make room
    const d3 = try allocator.dupe(u8, "cccccccccc"); // 10 bytes
    try cache.put(3, "blob", d3);
    try std.testing.expectEqual(@as(usize, 20), cache.memoryUsage());
    try std.testing.expectEqual(@as(usize, 2), cache.count());

    // Entry 1 should be gone
    try std.testing.expect(cache.get(1) == null);
    // Entries 2 and 3 should exist
    try std.testing.expect(cache.get(2) != null);
    try std.testing.expect(cache.get(3) != null);
}

test "DeltaCache LRU order: accessing entry prevents eviction" {
    const allocator = std.testing.allocator;
    var cache = DeltaCache.init(allocator, 20);
    defer cache.deinit();

    const d1 = try allocator.dupe(u8, "aaaaaaaaaa");
    try cache.put(1, "blob", d1);
    const d2 = try allocator.dupe(u8, "bbbbbbbbbb");
    try cache.put(2, "tree", d2);

    // Access entry 1 (moves it to back of LRU)
    _ = cache.get(1);

    // Insert entry 3 — should evict entry 2 (now oldest)
    const d3 = try allocator.dupe(u8, "cccccccccc");
    try cache.put(3, "commit", d3);

    try std.testing.expect(cache.get(1) != null); // kept (was accessed)
    try std.testing.expect(cache.get(2) == null); // evicted
    try std.testing.expect(cache.get(3) != null); // just inserted
}

test "DeltaCache putDupe" {
    const allocator = std.testing.allocator;
    var cache = DeltaCache.init(allocator, 1024);
    defer cache.deinit();

    const data = "some data not owned by cache caller";
    try cache.putDupe(42, "tag", data);

    const entry = cache.get(42).?;
    try std.testing.expectEqualSlices(u8, data, entry.data);
}

test "DeltaCache replace existing entry" {
    const allocator = std.testing.allocator;
    var cache = DeltaCache.init(allocator, 1024);
    defer cache.deinit();

    const d1 = try allocator.dupe(u8, "first");
    try cache.put(10, "blob", d1);

    const d2 = try allocator.dupe(u8, "second");
    try cache.put(10, "blob", d2);

    const entry = cache.get(10).?;
    try std.testing.expectEqualSlices(u8, "second", entry.data);
    try std.testing.expectEqual(@as(usize, 1), cache.count());
    try std.testing.expectEqual(@as(usize, 6), cache.memoryUsage()); // "second" = 6 bytes
}

test "DeltaCache hit rate tracking" {
    const allocator = std.testing.allocator;
    var cache = DeltaCache.init(allocator, 1024);
    defer cache.deinit();

    const d1 = try allocator.dupe(u8, "data");
    try cache.put(1, "blob", d1);

    _ = cache.get(1); // hit
    _ = cache.get(1); // hit
    _ = cache.get(999); // miss

    try std.testing.expectEqual(@as(u64, 2), cache.hits);
    try std.testing.expectEqual(@as(u64, 1), cache.misses);
}
