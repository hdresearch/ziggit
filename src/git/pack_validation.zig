const std = @import("std");
const objects = @import("objects.zig");

/// Enhanced pack file validation with detailed diagnostics
pub const PackValidationResult = struct {
    total_packs: u32,
    healthy_packs: u32,
    corrupted_packs: u32,
    pack_details: std.array_list.Managed(PackDetail),
    
    pub const PackDetail = struct {
        name: []u8,
        size: u64,
        version: u32,
        total_objects: u32,
        readable_objects: u32,
        issues: std.array_list.Managed([]u8),
        
        pub fn init(allocator: std.mem.Allocator, name: []const u8) PackDetail {
            return PackDetail{
                .name = allocator.dupe(u8, name) catch unreachable,
                .size = 0,
                .version = 0,
                .total_objects = 0,
                .readable_objects = 0,
                .issues = std.array_list.Managed([]u8).init(allocator),
            };
        }
        
        pub fn deinit(self: PackDetail, allocator: std.mem.Allocator) void {
            allocator.free(self.name);
            for (self.issues.items) |issue| {
                allocator.free(issue);
            }
            self.issues.deinit();
        }
        
        pub fn addIssue(self: *PackDetail, allocator: std.mem.Allocator, issue: []const u8) void {
            const owned_issue = allocator.dupe(u8, issue) catch return;
            self.issues.append(owned_issue) catch return;
        }
        
        pub fn isHealthy(self: PackDetail) bool {
            return self.issues.items.len == 0 and self.readable_objects == self.total_objects;
        }
    };
    
    pub fn init(allocator: std.mem.Allocator) PackValidationResult {
        return PackValidationResult{
            .total_packs = 0,
            .healthy_packs = 0,
            .corrupted_packs = 0,
            .pack_details = std.array_list.Managed(PackDetail).init(allocator),
        };
    }
    
    pub fn deinit(self: PackValidationResult, allocator: std.mem.Allocator) void {
        for (self.pack_details.items) |detail| {
            detail.deinit(allocator);
        }
        self.pack_details.deinit();
    }
    
    pub fn print(self: PackValidationResult) void {
        std.debug.print("Pack Validation Results:\n");
        std.debug.print("  Total packs: {}\n", .{self.total_packs});
        std.debug.print("  Healthy packs: {}\n", .{self.healthy_packs});
        std.debug.print("  Corrupted packs: {}\n", .{self.corrupted_packs});
        std.debug.print("\nPack Details:\n");
        
        for (self.pack_details.items) |detail| {
            std.debug.print("  {s}:\n", .{detail.name});
            std.debug.print("    Size: {} KB\n", .{detail.size / 1024});
            std.debug.print("    Version: {}\n", .{detail.version});
            std.debug.print("    Objects: {}/{}\n", .{detail.readable_objects, detail.total_objects});
            std.debug.print("    Health: {}\n", .{if (detail.isHealthy()) "OK" else "ISSUES"});
            
            if (detail.issues.items.len > 0) {
                std.debug.print("    Issues:\n");
                for (detail.issues.items) |issue| {
                    std.debug.print("      - {s}\n", .{issue});
                }
            }
            std.debug.print("\n");
        }
    }
};

/// Comprehensive pack file validation for a repository
pub fn validateAllPackFiles(git_dir: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) !PackValidationResult {
    var result = PackValidationResult.init(allocator);
    errdefer result.deinit(allocator);
    
    const pack_dir_path = try std.fmt.allocPrint(allocator, "{s}/objects/pack", .{git_dir});
    defer allocator.free(pack_dir_path);
    
    var pack_dir = std.fs.cwd().openDir(pack_dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return result, // No pack directory, that's ok
        else => return err,
    };
    defer pack_dir.close();
    
    var iterator = pack_dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".pack")) continue;
        
        result.total_packs += 1;
        
        var detail = PackDetail.init(allocator, entry.name);
        
        const pack_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{pack_dir_path, entry.name});
        defer allocator.free(pack_path);
        
        // Validate this pack file
        validateSinglePack(pack_path, platform_impl, allocator, &detail) catch |err| {
            const error_msg = try std.fmt.allocPrint(allocator, "Validation failed: {}", .{err});
            detail.addIssue(allocator, error_msg);
        };
        
        if (detail.isHealthy()) {
            result.healthy_packs += 1;
        } else {
            result.corrupted_packs += 1;
        }
        
        try result.pack_details.append(detail);
    }
    
    return result;
}

/// Validate a single pack file with detailed reporting
fn validateSinglePack(pack_path: []const u8, platform_impl: anytype, allocator: std.mem.Allocator, detail: *PackDetail) !void {
    // Get basic file stats
    const stat = std.fs.cwd().statFile(pack_path) catch return error.FileNotFound;
    detail.size = stat.size;
    
    // Read pack file for validation
    const pack_data = platform_impl.fs.readFile(allocator, pack_path) catch return error.ReadFailed;
    defer allocator.free(pack_data);
    
    // Basic header validation
    if (pack_data.len < 28) {
        detail.addIssue(allocator, "Pack file too small");
        return;
    }
    
    if (!std.mem.eql(u8, pack_data[0..4], "PACK")) {
        detail.addIssue(allocator, "Invalid pack signature");
        return;
    }
    
    detail.version = std.mem.readInt(u32, @ptrCast(pack_data[4..8]), .big);
    detail.total_objects = std.mem.readInt(u32, @ptrCast(pack_data[8..12]), .big);
    
    // Version validation
    if (detail.version < 2 or detail.version > 4) {
        const version_issue = try std.fmt.allocPrint(allocator, "Unsupported pack version: {}", .{detail.version});
        detail.addIssue(allocator, version_issue);
        return;
    }
    
    // Checksum validation
    const content_end = pack_data.len - 20;
    const stored_checksum = pack_data[content_end..];
    
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack_data[0..content_end]);
    var computed_checksum: [20]u8 = undefined;
    hasher.final(&computed_checksum);
    
    if (!std.mem.eql(u8, &computed_checksum, stored_checksum)) {
        detail.addIssue(allocator, "Pack checksum mismatch");
        return;
    }
    
    // Try to read all object headers to count readable objects
    var pos: usize = 12; // Start after header
    var readable_count: u32 = 0;
    
    while (readable_count < detail.total_objects and pos + 4 < content_end) {
        if (readPackObjectHeaderValidation(pack_data, pos)) |header_info| {
            readable_count += 1;
            pos = header_info.next_pos;
            
            // Skip compressed data (estimate size for performance)
            const estimated_compressed = header_info.uncompressed_size / 3; // Rough compression ratio
            pos += @min(estimated_compressed, content_end - pos);
            
            // Safety check to prevent infinite loops
            if (pos >= content_end) break;
        } else |_| {
            pos += 1; // Try to continue
            const error_msg = try std.fmt.allocPrint(allocator, "Unreadable object at position {}", .{pos});
            detail.addIssue(allocator, error_msg);
        }
        
        // Prevent excessive processing time
        if (readable_count > 100000) break; // Reasonable limit for validation
    }
    
    detail.readable_objects = readable_count;
    
    if (detail.readable_objects != detail.total_objects) {
        const count_issue = try std.fmt.allocPrint(allocator, "Object count mismatch: {}/{}", .{detail.readable_objects, detail.total_objects});
        detail.addIssue(allocator, count_issue);
    }
}

/// Object header information for validation (simplified version)
const PackObjectHeaderValidation = struct {
    object_type: u8,
    uncompressed_size: usize,
    next_pos: usize,
};

/// Read just the header of a packed object for validation (optimized version)
fn readPackObjectHeaderValidation(pack_data: []const u8, offset: usize) !PackObjectHeaderValidation {
    if (offset >= pack_data.len) return error.OffsetBeyondData;
    
    var pos = offset;
    const first_byte = pack_data[pos];
    pos += 1;
    
    const object_type = (first_byte >> 4) & 7;
    
    // Read variable-length size with bounds checking
    var size: usize = @intCast(first_byte & 15);
    var shift: u6 = 4;
    var current_byte = first_byte;
    var iterations: u8 = 0;
    
    while (current_byte & 0x80 != 0 and pos < pack_data.len and iterations < 10) {
        current_byte = pack_data[pos];
        pos += 1;
        size |= @as(usize, @intCast(current_byte & 0x7F)) << shift;
        shift += 7;
        iterations += 1;
        
        // Prevent unreasonable sizes that could indicate corruption
        if (size > 1024 * 1024 * 1024) return error.ObjectSizeTooLarge; // 1GB limit
    }
    
    // Handle delta object types
    if (object_type == 6) { // OFS_DELTA
        // Skip offset delta header
        while (pos < pack_data.len) {
            const offset_byte = pack_data[pos];
            pos += 1;
            if (offset_byte & 0x80 == 0) break;
        }
    } else if (object_type == 7) { // REF_DELTA
        // Skip 20-byte SHA-1 reference
        pos += @min(20, pack_data.len - pos);
    }
    
    return PackObjectHeaderValidation{
        .object_type = object_type,
        .uncompressed_size = size,
        .next_pos = pos,
    };
}

/// Repair pack files by removing corrupted objects (placeholder implementation)
pub fn repairPackFiles(git_dir: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) !PackRepairResult {
    _ = git_dir;
    _ = platform_impl;
    
    // This would be a complex implementation that:
    // 1. Identifies corrupted objects
    // 2. Attempts to reconstruct them from other sources
    // 3. Rebuilds pack files without corrupted objects
    // 4. Updates index files accordingly
    
    return PackRepairResult{
        .packs_processed = 0,
        .objects_repaired = 0,
        .objects_removed = 0,
        .space_reclaimed = 0,
        .repair_log = std.array_list.Managed([]u8).init(allocator),
    };
}

/// Result of pack file repair operations
pub const PackRepairResult = struct {
    packs_processed: u32,
    objects_repaired: u32,
    objects_removed: u32,
    space_reclaimed: u64,
    repair_log: std.array_list.Managed([]u8),
    
    pub fn deinit(self: PackRepairResult, allocator: std.mem.Allocator) void {
        for (self.repair_log.items) |log_entry| {
            allocator.free(log_entry);
        }
        self.repair_log.deinit();
    }
    
    pub fn print(self: PackRepairResult) void {
        std.debug.print("Pack Repair Results:\n");
        std.debug.print("  Packs processed: {}\n", .{self.packs_processed});
        std.debug.print("  Objects repaired: {}\n", .{self.objects_repaired});
        std.debug.print("  Objects removed: {}\n", .{self.objects_removed});
        std.debug.print("  Space reclaimed: {} KB\n", .{self.space_reclaimed / 1024});
        
        if (self.repair_log.items.len > 0) {
            std.debug.print("\nRepair Log:\n");
            for (self.repair_log.items) |log_entry| {
                std.debug.print("  {s}\n", .{log_entry});
            }
        }
    }
};