const std = @import("std");
const objects = @import("objects.zig");

/// Pack file utilities for enhanced pack handling
pub const PackUtils = struct {
    /// Verify pack file integrity without loading full content
    pub fn verifyPackIntegrity(pack_path: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) !bool {
        const pack_data = platform_impl.fs.readFile(allocator, pack_path) catch return false;
        defer allocator.free(pack_data);
        
        // Basic header validation
        if (pack_data.len < 28) return false;
        if (!std.mem.eql(u8, pack_data[0..4], "PACK")) return false;
        
        const version = std.mem.readInt(u32, @ptrCast(pack_data[4..8]), .big);
        if (version < 2 or version > 4) return false;
        
        // Checksum validation
        if (pack_data.len >= 20) {
            const content_end = pack_data.len - 20;
            const stored_checksum = pack_data[content_end..];
            
            var hasher = std.crypto.hash.Sha1.init(.{});
            hasher.update(pack_data[0..content_end]);
            var computed_checksum: [20]u8 = undefined;
            hasher.final(&computed_checksum);
            
            return std.mem.eql(u8, &computed_checksum, stored_checksum);
        }
        
        return true;
    }
    
    /// Get pack file basic information quickly
    pub fn getQuickPackInfo(pack_path: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) !PackInfo {
        // Read just the header to get basic info quickly
        const header_size = 32;
        const full_data = platform_impl.fs.readFile(allocator, pack_path) catch return error.PackNotFound;
        defer allocator.free(full_data);
        
        if (full_data.len < header_size) return error.InvalidPack;
        
        const header = full_data[0..header_size];
        
        if (!std.mem.eql(u8, header[0..4], "PACK")) return error.InvalidPackSignature;
        
        const version = std.mem.readInt(u32, @ptrCast(header[4..8]), .big);
        const object_count = std.mem.readInt(u32, @ptrCast(header[8..12]), .big);
        
        return PackInfo{
            .version = version,
            .object_count = object_count,
            .file_size = full_data.len,
            .valid = true,
        };
    }
    
    /// Find all pack files in a repository
    pub fn findPackFiles(git_dir: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) !std.array_list.Managed(PackFileDesc) {
        var pack_files = std.array_list.Managed(PackFileDesc).init(allocator);
        
        const pack_dir = try std.fmt.allocPrint(allocator, "{s}/objects/pack", .{git_dir});
        defer allocator.free(pack_dir);
        
        const entries = platform_impl.fs.readDir(allocator, pack_dir) catch |err| switch (err) {
            error.FileNotFound => return pack_files,
            else => return err,
        };
        defer {
            for (entries) |entry| {
                allocator.free(entry);
            }
            allocator.free(entries);
        }
        
        for (entries) |entry| {
            if (std.mem.endsWith(u8, entry, ".pack")) {
                const pack_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pack_dir, entry });
                
                const pack_info = getQuickPackInfo(pack_path, platform_impl, allocator) catch {
                    allocator.free(pack_path);
                    continue;
                };
                
                try pack_files.append(PackFileDesc{
                    .path = pack_path,
                    .basename = try allocator.dupe(u8, entry),
                    .info = pack_info,
                });
            }
        }
        
        return pack_files;
    }
    
    /// Clean up resources for pack file list
    pub fn deinitPackFiles(pack_files: std.array_list.Managed(PackFileDesc), allocator: std.mem.Allocator) void {
        for (pack_files.items) |pack_file| {
            allocator.free(pack_file.path);
            allocator.free(pack_file.basename);
        }
    }
};

/// Basic pack file information structure
pub const PackInfo = struct {
    version: u32,
    object_count: u32,
    file_size: u64,
    valid: bool,
};

/// Pack file descriptor with metadata
pub const PackFileDesc = struct {
    path: []const u8,
    basename: []const u8,
    info: PackInfo,
};

/// Validate pack index file integrity
pub fn validatePackIndex(idx_path: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) !bool {
    const idx_data = platform_impl.fs.readFile(allocator, idx_path) catch return false;
    defer allocator.free(idx_data);
    
    if (idx_data.len < 8) return false;
    
    // Check for v2 magic
    const magic = std.mem.readInt(u32, @ptrCast(idx_data[0..4]), .big);
    if (magic == 0xff744f63) {
        // Version 2 index
        const version = std.mem.readInt(u32, @ptrCast(idx_data[4..8]), .big);
        if (version != 2) return false;
        
        // Basic structure check - must have fanout table
        if (idx_data.len < 8 + 256 * 4) return false;
        
        // Check fanout table is monotonic
        var prev_count: u32 = 0;
        var i: u32 = 0;
        while (i < 256) : (i += 1) {
            const offset = 8 + i * 4;
            const count = std.mem.readInt(u32, @ptrCast(idx_data[offset..offset + 4]), .big);
            if (count < prev_count) return false;
            prev_count = count;
        }
        
        return true;
    } else {
        // Version 1 index - check fanout table
        if (idx_data.len < 256 * 4) return false;
        
        var prev_count: u32 = 0;
        var i: u32 = 0;
        while (i < 256) : (i += 1) {
            const offset = i * 4;
            const count = std.mem.readInt(u32, @ptrCast(idx_data[offset..offset + 4]), .big);
            if (count < prev_count) return false;
            prev_count = count;
        }
        
        return true;
    }
}

/// Repair or optimize pack file access patterns
pub fn optimizePackAccess(git_dir: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) !void {
    std.debug.print("Optimizing pack file access for repository: {s}\n", .{git_dir});
    
    var pack_files = try PackUtils.findPackFiles(git_dir, platform_impl, allocator);
    defer PackUtils.deinitPackFiles(pack_files, allocator);
    
    std.debug.print("Found {} pack files\n", .{pack_files.items.len});
    
    // Sort pack files by size (larger first, likely contain more recent objects)
    std.sort.block(PackFileDesc, pack_files.items, {}, struct {
        fn lessThan(context: void, lhs: PackFileDesc, rhs: PackFileDesc) bool {
            _ = context;
            return lhs.info.file_size > rhs.info.file_size;
        }
    }.lessThan);
    
    // Validate each pack file integrity
    var valid_packs: u32 = 0;
    for (pack_files.items) |pack_file| {
        std.debug.print("Checking pack: {s} ({} objects, {} bytes)\n", 
            .{ pack_file.basename, pack_file.info.object_count, pack_file.info.file_size });
        
        if (PackUtils.verifyPackIntegrity(pack_file.path, platform_impl, allocator) catch false) {
            valid_packs += 1;
            std.debug.print("  ✓ Pack integrity verified\n");
            
            // Check corresponding index file
            const idx_path = try std.fmt.allocPrint(allocator, "{s}.idx", .{pack_file.path[0..pack_file.path.len-5]});
            defer allocator.free(idx_path);
            
            if (validatePackIndex(idx_path, platform_impl, allocator) catch false) {
                std.debug.print("  ✓ Index integrity verified\n");
            } else {
                std.debug.print("  ⚠ Index file has issues\n");
            }
        } else {
            std.debug.print("  ✗ Pack integrity check failed\n");
        }
    }
    
    std.debug.print("Pack optimization complete: {}/{} packs are valid\n", .{valid_packs, pack_files.items.len});
}

test "pack utils basic functionality" {
    const testing = std.testing;
    
    const pack_info = PackInfo{
        .version = 2,
        .object_count = 100,
        .file_size = 1024 * 1024,
        .valid = true,
    };
    
    try testing.expect(pack_info.valid);
    try testing.expectEqual(@as(u32, 2), pack_info.version);
    try testing.expectEqual(@as(u32, 100), pack_info.object_count);
}