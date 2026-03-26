const std = @import("std");
const objects = @import("objects.zig");

/// Pack file statistics for debugging and optimization
pub const PackStats = struct {
    total_objects: u32,
    commit_objects: u32,
    tree_objects: u32,
    blob_objects: u32,
    tag_objects: u32,
    ofs_delta_objects: u32,
    ref_delta_objects: u32,
    total_size: u64,
    index_version: u32,

    pub fn init() PackStats {
        return PackStats{
            .total_objects = 0,
            .commit_objects = 0,
            .tree_objects = 0,
            .blob_objects = 0,
            .tag_objects = 0,
            .ofs_delta_objects = 0,
            .ref_delta_objects = 0,
            .total_size = 0,
            .index_version = 1,
        };
    }

    pub fn print(self: PackStats) void {
        std.debug.print("Pack Statistics:\n", .{});
        std.debug.print("  Total objects: {}\n", .{self.total_objects});
        std.debug.print("  Commits: {}\n", .{self.commit_objects});
        std.debug.print("  Trees: {}\n", .{self.tree_objects});
        std.debug.print("  Blobs: {}\n", .{self.blob_objects});
        std.debug.print("  Tags: {}\n", .{self.tag_objects});
        std.debug.print("  OFS deltas: {}\n", .{self.ofs_delta_objects});
        std.debug.print("  REF deltas: {}\n", .{self.ref_delta_objects});
        std.debug.print("  Total size: {} bytes\n", .{self.total_size});
        std.debug.print("  Index version: {}\n", .{self.index_version});
    }
};

/// Analyze a pack file and return statistics
pub fn analyzePackFile(pack_dir_path: []const u8, idx_filename: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) !PackStats {
    var stats = PackStats.init();

    // Read the .idx file
    const idx_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{pack_dir_path, idx_filename});
    defer allocator.free(idx_path);
    
    const idx_data = platform_impl.fs.readFile(allocator, idx_path) catch return error.PackNotFound;
    defer allocator.free(idx_data);
    
    stats.total_size = idx_data.len;
    
    if (idx_data.len < 8) return error.InvalidPackIndex;
    
    // Check for pack index magic and version
    const magic = std.mem.readInt(u32, @ptrCast(idx_data[0..4]), .big);
    if (magic == 0xff744f63) { // '\377tOc'
        // Version 2 index
        const version = std.mem.readInt(u32, @ptrCast(idx_data[4..8]), .big);
        if (version != 2) return error.UnsupportedIndexVersion;
        stats.index_version = version;
        
        // Read total objects from fanout table
        const fanout_start = 8;
        const fanout_end = fanout_start + 256 * 4;
        if (idx_data.len < fanout_end) return error.InvalidPackIndex;
        
        // The last entry in the fanout table gives us the total object count
        const total_objects = std.mem.readInt(u32, @ptrCast(idx_data[fanout_end - 4..fanout_end]), .big);
        stats.total_objects = total_objects;
    } else {
        // Version 1 index (no magic header)
        stats.index_version = 1;
        
        if (idx_data.len < 256 * 4) return error.InvalidPackIndex;
        
        // Read total objects from fanout table
        const total_objects = std.mem.readInt(u32, @ptrCast(idx_data[256 * 4 - 4..256 * 4]), .big);
        stats.total_objects = total_objects;
    }

    return stats;
}

/// Verify the integrity of a pack file
pub fn verifyPackFile(pack_dir_path: []const u8, idx_filename: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) !void {
    const idx_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{pack_dir_path, idx_filename});
    defer allocator.free(idx_path);
    
    const idx_data = platform_impl.fs.readFile(allocator, idx_path) catch return error.PackNotFound;
    defer allocator.free(idx_data);

    // Verify index file format
    if (idx_data.len < 8) return error.InvalidPackIndex;
    
    const magic = std.mem.readInt(u32, @ptrCast(idx_data[0..4]), .big);
    if (magic == 0xff744f63) { // Version 2
        const version = std.mem.readInt(u32, @ptrCast(idx_data[4..8]), .big);
        if (version != 2) return error.UnsupportedIndexVersion;
        
        // Verify fanout table consistency
        const fanout_start = 8;
        const fanout_end = fanout_start + 256 * 4;
        if (idx_data.len < fanout_end) return error.InvalidPackIndex;
        
        var prev_count: u32 = 0;
        var i: usize = 0;
        while (i < 256) : (i += 1) {
            const current_count = std.mem.readInt(u32, @ptrCast(idx_data[fanout_start + i * 4..fanout_start + i * 4 + 4]), .big);
            if (current_count < prev_count) {
                return error.InvalidFanoutTable;
            }
            prev_count = current_count;
        }
    } else {
        // Version 1 - verify fanout table
        if (idx_data.len < 256 * 4) return error.InvalidPackIndex;
        
        var prev_count: u32 = 0;
        var i: usize = 0;
        while (i < 256) : (i += 1) {
            const current_count = std.mem.readInt(u32, @ptrCast(idx_data[i * 4..i * 4 + 4]), .big);
            if (current_count < prev_count) {
                return error.InvalidFanoutTable;
            }
            prev_count = current_count;
        }
    }

    // Verify corresponding pack file exists
    const pack_filename = try std.fmt.allocPrint(allocator, "{s}.pack", .{idx_filename[0..idx_filename.len-4]});
    defer allocator.free(pack_filename);
    
    const pack_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{pack_dir_path, pack_filename});
    defer allocator.free(pack_path);
    
    const pack_data = platform_impl.fs.readFile(allocator, pack_path) catch return error.PackFileNotFound;
    defer allocator.free(pack_data);

    // Verify pack file header
    if (pack_data.len < 12) return error.InvalidPackFile;
    
    const pack_signature = pack_data[0..4];
    if (!std.mem.eql(u8, pack_signature, "PACK")) return error.InvalidPackFile;
    
    const pack_version = std.mem.readInt(u32, @ptrCast(pack_data[4..8]), .big);
    if (pack_version != 2) return error.UnsupportedPackVersion;
    
    const object_count = std.mem.readInt(u32, @ptrCast(pack_data[8..12]), .big);
    
    // Verify object count matches between index and pack
    const stats = try analyzePackFile(pack_dir_path, idx_filename, platform_impl, allocator);
    if (object_count != stats.total_objects) return error.ObjectCountMismatch;
}

/// List all available pack files in a repository
pub fn listPackFiles(git_dir: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) !std.array_list.Managed([]u8) {
    var pack_files = std.array_list.Managed([]u8).init(allocator);
    
    const pack_dir_path = try std.fmt.allocPrint(allocator, "{s}/objects/pack", .{git_dir});
    defer allocator.free(pack_dir_path);
    
    const entries = platform_impl.fs.readDir(allocator, pack_dir_path) catch |err| switch (err) {
        error.FileNotFound, error.NotSupported => return pack_files,
        else => return err,
    };
    defer {
        for (entries) |entry| {
            allocator.free(entry);
        }
        allocator.free(entries);
    }
    
    // Find .idx files and derive pack file names
    for (entries) |entry| {
        if (std.mem.endsWith(u8, entry, ".idx")) {
            const pack_name = try std.fmt.allocPrint(allocator, "{s}.pack", .{entry[0..entry.len-4]});
            try pack_files.append(pack_name);
        }
    }
    
    return pack_files;
}

/// Optimize pack file access by pre-loading frequently accessed objects
pub const PackCache = struct {
    cache: std.HashMap(u32, CachedObject, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    allocator: std.mem.Allocator,
    max_size: usize,
    current_size: usize,

    const CachedObject = struct {
        type: objects.ObjectType,
        data: []const u8,
        access_count: u32,
        last_access: i64,
    };

    pub fn init(allocator: std.mem.Allocator, max_size: usize) PackCache {
        return PackCache{
            .cache = std.HashMap(u32, CachedObject, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
            .allocator = allocator,
            .max_size = max_size,
            .current_size = 0,
        };
    }

    pub fn deinit(self: *PackCache) void {
        var iterator = self.cache.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.value_ptr.data);
        }
        self.cache.deinit();
    }

    pub fn get(self: *PackCache, hash: u32) ?*const CachedObject {
        if (self.cache.getPtr(hash)) |obj| {
            obj.access_count += 1;
            obj.last_access = std.time.timestamp();
            return obj;
        }
        return null;
    }

    pub fn put(self: *PackCache, hash: u32, obj_type: objects.ObjectType, data: []const u8) !void {
        // Simple eviction: remove oldest accessed item if cache is full
        while (self.current_size + data.len > self.max_size and self.cache.count() > 0) {
            try self.evictOldest();
        }

        const data_copy = try self.allocator.dupe(u8, data);
        const cached_obj = CachedObject{
            .type = obj_type,
            .data = data_copy,
            .access_count = 1,
            .last_access = std.time.timestamp(),
        };

        try self.cache.put(hash, cached_obj);
        self.current_size += data.len;
    }

    fn evictOldest(self: *PackCache) !void {
        var oldest_hash: u32 = undefined;
        var oldest_time: i64 = std.math.maxInt(i64);
        var found = false;

        var iterator = self.cache.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.last_access < oldest_time) {
                oldest_time = entry.value_ptr.last_access;
                oldest_hash = entry.key_ptr.*;
                found = true;
            }
        }

        if (found) {
            if (self.cache.get(oldest_hash)) |obj| {
                self.current_size -= obj.data.len;
                self.allocator.free(obj.data);
                _ = self.cache.remove(oldest_hash);
            }
        }
    }
};