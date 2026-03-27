const std = @import("std");
const objects = @import("objects.zig");
const crypto = std.crypto;

/// Enhanced pack file analysis and diagnostics
pub const PackFileAnalyzer = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) PackFileAnalyzer {
        return PackFileAnalyzer{
            .allocator = allocator,
        };
    }
    
    /// Detailed pack file analysis with enhanced error reporting
    pub const DetailedStats = struct {
        version: u32,
        total_objects: u32,
        blob_count: u32,
        tree_count: u32,
        commit_count: u32,
        tag_count: u32,
        ofs_delta_count: u32,
        ref_delta_count: u32,
        file_size: u64,
        compressed_size: u64,
        uncompressed_size: u64,
        compression_ratio: f32,
        checksum_valid: bool,
        is_thin: bool,
        corrupted_objects: u32,
        
        pub fn print(self: DetailedStats) void {
            std.debug.print("=== Detailed Pack File Analysis ===\n");
            std.debug.print("Pack version: {}\n", .{self.version});
            std.debug.print("Total objects: {}\n", .{self.total_objects});
            std.debug.print("Object breakdown:\n");
            std.debug.print("  - Blobs: {} ({d:.1}%)\n", .{ self.blob_count, @as(f32, @floatFromInt(self.blob_count)) / @as(f32, @floatFromInt(self.total_objects)) * 100.0 });
            std.debug.print("  - Trees: {} ({d:.1}%)\n", .{ self.tree_count, @as(f32, @floatFromInt(self.tree_count)) / @as(f32, @floatFromInt(self.total_objects)) * 100.0 });
            std.debug.print("  - Commits: {} ({d:.1}%)\n", .{ self.commit_count, @as(f32, @floatFromInt(self.commit_count)) / @as(f32, @floatFromInt(self.total_objects)) * 100.0 });
            std.debug.print("  - Tags: {} ({d:.1}%)\n", .{ self.tag_count, @as(f32, @floatFromInt(self.tag_count)) / @as(f32, @floatFromInt(self.total_objects)) * 100.0 });
            std.debug.print("Delta objects:\n");
            std.debug.print("  - Offset deltas: {} ({d:.1}%)\n", .{ self.ofs_delta_count, @as(f32, @floatFromInt(self.ofs_delta_count)) / @as(f32, @floatFromInt(self.total_objects)) * 100.0 });
            std.debug.print("  - Reference deltas: {} ({d:.1}%)\n", .{ self.ref_delta_count, @as(f32, @floatFromInt(self.ref_delta_count)) / @as(f32, @floatFromInt(self.total_objects)) * 100.0 });
            std.debug.print("Size information:\n");
            std.debug.print("  - File size: {} bytes\n", .{self.file_size});
            std.debug.print("  - Compressed: {} bytes\n", .{self.compressed_size});
            std.debug.print("  - Uncompressed: {} bytes (estimated)\n", .{self.uncompressed_size});
            std.debug.print("  - Compression ratio: {d:.2}x\n", .{self.compression_ratio});
            std.debug.print("Health:\n");
            std.debug.print("  - Checksum valid: {}\n", .{self.checksum_valid});
            std.debug.print("  - Is thin pack: {}\n", .{self.is_thin});
            std.debug.print("  - Corrupted objects: {}\n", .{self.corrupted_objects});
        }
    };
    
    /// Analyze a pack file in detail
    pub fn analyzePackFile(self: PackFileAnalyzer, pack_path: []const u8, platform_impl: anytype) !DetailedStats {
        const pack_data = try platform_impl.fs.readFile(self.allocator, pack_path);
        defer self.allocator.free(pack_data);
        
        if (pack_data.len < 28) return error.PackFileTooSmall;
        
        var stats = DetailedStats{
            .version = 0,
            .total_objects = 0,
            .blob_count = 0,
            .tree_count = 0,
            .commit_count = 0,
            .tag_count = 0,
            .ofs_delta_count = 0,
            .ref_delta_count = 0,
            .file_size = pack_data.len,
            .compressed_size = 0,
            .uncompressed_size = 0,
            .compression_ratio = 0.0,
            .checksum_valid = false,
            .is_thin = false,
            .corrupted_objects = 0,
        };
        
        // Check header
        if (!std.mem.eql(u8, pack_data[0..4], "PACK")) {
            return error.InvalidPackSignature;
        }
        
        stats.version = std.mem.readInt(u32, @ptrCast(pack_data[4..8]), .big);
        stats.total_objects = std.mem.readInt(u32, @ptrCast(pack_data[8..12]), .big);
        
        // Verify checksum
        const content_end = pack_data.len - 20;
        const stored_checksum = pack_data[content_end..];
        
        var hasher = crypto.hash.Sha1.init(.{});
        hasher.update(pack_data[0..content_end]);
        var computed_checksum: [20]u8 = undefined;
        hasher.final(&computed_checksum);
        
        stats.checksum_valid = std.mem.eql(u8, &computed_checksum, stored_checksum);
        
        // Analyze objects
        var pos: usize = 12; // Start after header
        var object_count: u32 = 0;
        
        while (pos < content_end and object_count < stats.total_objects) {
            const object_start = pos;
            
            if (pos >= pack_data.len) break;
            
            const first_byte = pack_data[pos];
            pos += 1;
            
            const pack_type_num = (first_byte >> 4) & 7;
            
            // Read variable-length size
            var size: usize = @intCast(first_byte & 15);
            var shift: u6 = 4;
            var current_byte = first_byte;
            
            while (current_byte & 0x80 != 0 and pos < pack_data.len) {
                current_byte = pack_data[pos];
                pos += 1;
                size |= @as(usize, @intCast(current_byte & 0x7F)) << shift;
                shift += 7;
                
                if (shift > 56) break; // Prevent overflow
            }
            
            // Count object types
            switch (pack_type_num) {
                1 => stats.commit_count += 1,  // commit
                2 => stats.tree_count += 1,    // tree
                3 => stats.blob_count += 1,    // blob
                4 => stats.tag_count += 1,     // tag
                6 => {
                    // OFS_DELTA - read offset
                    stats.ofs_delta_count += 1;
                    var base_offset_delta: usize = 0;
                    var first_offset_byte = true;
                    
                    while (pos < pack_data.len) {
                        const offset_byte = pack_data[pos];
                        pos += 1;
                        
                        if (first_offset_byte) {
                            base_offset_delta = @intCast(offset_byte & 0x7F);
                            first_offset_byte = false;
                        } else {
                            base_offset_delta = (base_offset_delta + 1) << 7;
                            base_offset_delta += @intCast(offset_byte & 0x7F);
                        }
                        
                        if (offset_byte & 0x80 == 0) break;
                    }
                },
                7 => {
                    // REF_DELTA - skip 20-byte SHA-1
                    stats.ref_delta_count += 1;
                    pos += 20;
                },
                else => {
                    stats.corrupted_objects += 1;
                }
            }
            
            // Try to find compressed data and skip it
            const compressed_start = pos;
            
            // Skip compressed data by finding next object or end
            // This is a heuristic - we look for the next object header pattern
            var found_next = false;
            while (pos < content_end - 1) {
                const potential_first_byte = pack_data[pos];
                const potential_type = (potential_first_byte >> 4) & 7;
                
                // Valid pack object types are 1-4, 6-7
                if (potential_type >= 1 and potential_type <= 4 or potential_type >= 6 and potential_type <= 7) {
                    // This might be the start of the next object
                    found_next = true;
                    break;
                }
                pos += 1;
            }
            
            if (!found_next) {
                // Reached end, this was the last object
                pos = content_end;
            }
            
            stats.compressed_size += pos - compressed_start;
            stats.uncompressed_size += size;
            object_count += 1;
        }
        
        // Calculate compression ratio
        if (stats.uncompressed_size > 0) {
            stats.compression_ratio = @as(f32, @floatFromInt(stats.uncompressed_size)) / @as(f32, @floatFromInt(stats.compressed_size));
        }
        
        // Check if it's a thin pack (heuristic)
        stats.is_thin = (stats.ref_delta_count > stats.total_objects / 4) and (stats.total_objects < 1000);
        
        return stats;
    }
    
    /// Validate pack file integrity
    pub fn validatePackIntegrity(self: PackFileAnalyzer, pack_path: []const u8, platform_impl: anytype) ![][]const u8 {
        var issues = std.array_list.Managed([]const u8).init(self.allocator);
        
        const pack_data = platform_impl.fs.readFile(self.allocator, pack_path) catch |err| {
            const issue = try std.fmt.allocPrint(self.allocator, "Cannot read pack file: {}", .{err});
            try issues.append(issue);
            return issues.toOwnedSlice();
        };
        defer self.allocator.free(pack_data);
        
        // Basic size check
        if (pack_data.len < 28) {
            try issues.append(try self.allocator.dupe(u8, "Pack file too small (less than 28 bytes)"));
        }
        
        // Check signature
        if (!std.mem.eql(u8, pack_data[0..4], "PACK")) {
            try issues.append(try self.allocator.dupe(u8, "Invalid pack signature (not 'PACK')"));
        }
        
        // Check version
        if (pack_data.len >= 8) {
            const version = std.mem.readInt(u32, @ptrCast(pack_data[4..8]), .big);
            if (version < 2 or version > 4) {
                const issue = try std.fmt.allocPrint(self.allocator, "Unsupported pack version: {}", .{version});
                try issues.append(issue);
            }
        }
        
        // Check object count
        if (pack_data.len >= 12) {
            const object_count = std.mem.readInt(u32, @ptrCast(pack_data[8..12]), .big);
            if (object_count == 0) {
                try issues.append(try self.allocator.dupe(u8, "Pack file claims to have 0 objects"));
            } else if (object_count > 50_000_000) {
                const issue = try std.fmt.allocPrint(self.allocator, "Suspiciously high object count: {}", .{object_count});
                try issues.append(issue);
            }
        }
        
        // Verify checksum
        if (pack_data.len >= 20) {
            const content_end = pack_data.len - 20;
            const stored_checksum = pack_data[content_end..];
            
            var hasher = crypto.hash.Sha1.init(.{});
            hasher.update(pack_data[0..content_end]);
            var computed_checksum: [20]u8 = undefined;
            hasher.final(&computed_checksum);
            
            if (!std.mem.eql(u8, &computed_checksum, stored_checksum)) {
                try issues.append(try self.allocator.dupe(u8, "Pack file checksum mismatch - file may be corrupted"));
            }
        }
        
        return issues.toOwnedSlice();
    }
    
    /// Compare pack index with pack file for consistency
    pub fn validatePackIndex(self: PackFileAnalyzer, pack_path: []const u8, platform_impl: anytype) ![][]const u8 {
        var issues = std.array_list.Managed([]const u8).init(self.allocator);
        
        // Find corresponding .idx file
        if (!std.mem.endsWith(u8, pack_path, ".pack")) {
            try issues.append(try self.allocator.dupe(u8, "Pack file doesn't have .pack extension"));
            return issues.toOwnedSlice();
        }
        
        const idx_path = try std.fmt.allocPrint(self.allocator, "{s}.idx", .{pack_path[0..pack_path.len - 5]});
        defer self.allocator.free(idx_path);
        
        const idx_data = platform_impl.fs.readFile(self.allocator, idx_path) catch |err| {
            const issue = try std.fmt.allocPrint(self.allocator, "Cannot read index file {s}: {}", .{ idx_path, err });
            try issues.append(issue);
            return issues.toOwnedSlice();
        };
        defer self.allocator.free(idx_data);
        
        const pack_data = platform_impl.fs.readFile(self.allocator, pack_path) catch |err| {
            const issue = try std.fmt.allocPrint(self.allocator, "Cannot read pack file: {}", .{err});
            try issues.append(issue);
            return issues.toOwnedSlice();
        };
        defer self.allocator.free(pack_data);
        
        // Basic index validation
        if (idx_data.len < 8) {
            try issues.append(try self.allocator.dupe(u8, "Index file too small"));
            return issues.toOwnedSlice();
        }
        
        // Check index version
        const magic = std.mem.readInt(u32, @ptrCast(idx_data[0..4]), .big);
        if (magic == 0xff744f63) {
            // Version 2 index
            if (idx_data.len < 12) {
                try issues.append(try self.allocator.dupe(u8, "V2 index file too small"));
                return issues.toOwnedSlice();
            }
            
            const idx_version = std.mem.readInt(u32, @ptrCast(idx_data[4..8]), .big);
            if (idx_version != 2) {
                const issue = try std.fmt.allocPrint(self.allocator, "Unsupported index version: {}", .{idx_version});
                try issues.append(issue);
            }
        } else {
            // Version 1 index (no magic header)
            if (idx_data.len < 256 * 4) {
                try issues.append(try self.allocator.dupe(u8, "V1 index file too small"));
            }
        }
        
        // Get object count from pack file
        if (pack_data.len >= 12) {
            const pack_object_count = std.mem.readInt(u32, @ptrCast(pack_data[8..12]), .big);
            
            // Get object count from index
            var idx_object_count: u32 = 0;
            if (magic == 0xff744f63) {
                // V2 index - get from fanout table
                if (idx_data.len >= 8 + 256 * 4) {
                    idx_object_count = std.mem.readInt(u32, @ptrCast(idx_data[8 + 255 * 4..8 + 255 * 4 + 4]), .big);
                }
            } else {
                // V1 index - get from fanout table
                if (idx_data.len >= 256 * 4) {
                    idx_object_count = std.mem.readInt(u32, @ptrCast(idx_data[255 * 4..255 * 4 + 4]), .big);
                }
            }
            
            if (pack_object_count != idx_object_count) {
                const issue = try std.fmt.allocPrint(self.allocator, "Object count mismatch: pack has {}, index has {}", .{ pack_object_count, idx_object_count });
                try issues.append(issue);
            }
        }
        
        return issues.toOwnedSlice();
    }
};

/// Utility function to analyze all pack files in a repository
pub fn analyzeAllPackFiles(git_dir: []const u8, platform_impl: anytype, allocator: std.mem.Allocator) !void {
    const pack_dir_path = try std.fmt.allocPrint(allocator, "{s}/objects/pack", .{git_dir});
    defer allocator.free(pack_dir_path);
    
    var pack_dir = std.fs.cwd().openDir(pack_dir_path, .{ .iterate = true }) catch |err| {
        std.debug.print("Cannot access pack directory: {}\n", .{err});
        return;
    };
    defer pack_dir.close();
    
    var analyzer = PackFileAnalyzer.init(allocator);
    var pack_count: u32 = 0;
    
    std.debug.print("=== Pack File Analysis for {s} ===\n", .{git_dir});
    
    var iterator = pack_dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".pack")) continue;
        
        const pack_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pack_dir_path, entry.name });
        defer allocator.free(pack_path);
        
        std.debug.print("\n--- Analyzing {s} ---\n", .{entry.name});
        
        const stats = analyzer.analyzePackFile(pack_path, platform_impl) catch |err| {
            std.debug.print("Error analyzing pack file: {}\n", .{err});
            continue;
        };
        
        stats.print();
        
        // Validate integrity
        const issues = analyzer.validatePackIntegrity(pack_path, platform_impl) catch |err| {
            std.debug.print("Error validating pack file: {}\n", .{err});
            continue;
        };
        defer {
            for (issues) |issue| {
                allocator.free(issue);
            }
            allocator.free(issues);
        }
        
        if (issues.len > 0) {
            std.debug.print("Issues found:\n");
            for (issues) |issue| {
                std.debug.print("  - {s}\n", .{issue});
            }
        } else {
            std.debug.print("No issues found.\n");
        }
        
        pack_count += 1;
    }
    
    if (pack_count == 0) {
        std.debug.print("No pack files found.\n");
    } else {
        std.debug.print("\nAnalyzed {} pack file(s).\n", .{pack_count});
    }
}

test "pack analyzer basic functionality" {
    // This is a minimal test - would need real pack files for comprehensive testing
    const testing = std.testing;
    const allocator = testing.allocator;
    
    var analyzer = PackFileAnalyzer.init(allocator);
    _ = analyzer;
    
    // Test would require creating actual pack files
    // For now, just test that the analyzer can be created
    try testing.expect(true);
}