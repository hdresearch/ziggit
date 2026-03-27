const std = @import("std");
const objects = @import("objects.zig");

/// Pack file diagnostic utilities for troubleshooting and validation
pub const PackDiagnostics = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) PackDiagnostics {
        return PackDiagnostics{ .allocator = allocator };
    }
    
    /// Comprehensive pack file validation
    pub fn validatePackFile(self: PackDiagnostics, pack_path: []const u8, idx_path: []const u8, platform_impl: anytype) !PackValidationResult {
        var result = PackValidationResult.init(self.allocator);
        
        // Read pack file
        const pack_data = platform_impl.fs.readFile(self.allocator, pack_path) catch |err| {
            result.addError(try std.fmt.allocPrint(self.allocator, "Failed to read pack file: {}", .{err}));
            return result;
        };
        defer self.allocator.free(pack_data);
        
        // Read index file  
        const idx_data = platform_impl.fs.readFile(self.allocator, idx_path) catch |err| {
            result.addError(try std.fmt.allocPrint(self.allocator, "Failed to read index file: {}", .{err}));
            return result;
        };
        defer self.allocator.free(idx_data);
        
        // Validate pack header
        try self.validatePackHeader(pack_data, &result);
        
        // Validate index header
        try self.validateIndexHeader(idx_data, &result);
        
        // Validate pack checksum
        try self.validatePackChecksum(pack_data, &result);
        
        // Validate index consistency  
        try self.validateIndexConsistency(pack_data, idx_data, &result);
        
        // Sample object validation
        try self.validateSampleObjects(pack_data, idx_data, platform_impl, &result);
        
        return result;
    }
    
    /// Validate pack file header
    fn validatePackHeader(self: PackDiagnostics, pack_data: []const u8, result: *PackValidationResult) !void {
        if (pack_data.len < 12) {
            try result.addError(try std.fmt.allocPrint(self.allocator, "Pack file too small: {} bytes", .{pack_data.len}));
            return;
        }
        
        if (!std.mem.eql(u8, pack_data[0..4], "PACK")) {
            try result.addError(try std.fmt.allocPrint(self.allocator, "Invalid pack signature: {s}", .{pack_data[0..4]}));
            return;
        }
        
        const version = std.mem.readInt(u32, @ptrCast(pack_data[4..8]), .big);
        if (version < 2 or version > 4) {
            try result.addError(try std.fmt.allocPrint(self.allocator, "Unsupported pack version: {}", .{version}));
            return;
        }
        
        const object_count = std.mem.readInt(u32, @ptrCast(pack_data[8..12]), .big);
        if (object_count == 0) {
            try result.addWarning(try std.fmt.allocPrint(self.allocator, "Pack file claims 0 objects", .{}));
        }
        
        try result.addInfo(try std.fmt.allocPrint(self.allocator, "Pack version: {}, objects: {}", .{ version, object_count }));
    }
    
    /// Validate index file header
    fn validateIndexHeader(self: PackDiagnostics, idx_data: []const u8, result: *PackValidationResult) !void {
        if (idx_data.len < 8) {
            try result.addError(try std.fmt.allocPrint(self.allocator, "Index file too small: {} bytes", .{idx_data.len}));
            return;
        }
        
        const magic = std.mem.readInt(u32, @ptrCast(idx_data[0..4]), .big);
        if (magic == 0xff744f63) {
            const version = std.mem.readInt(u32, @ptrCast(idx_data[4..8]), .big);
            if (version != 2) {
                try result.addWarning(try std.fmt.allocPrint(self.allocator, "Index version: {} (only v2 fully supported)", .{version}));
            } else {
                try result.addInfo(try std.fmt.allocPrint(self.allocator, "Index version: {}", .{version}));
            }
        } else {
            try result.addInfo(try std.fmt.allocPrint(self.allocator, "Index appears to be v1 format (no magic header)", .{}));
        }
    }
    
    /// Validate pack file checksum
    fn validatePackChecksum(self: PackDiagnostics, pack_data: []const u8, result: *PackValidationResult) !void {
        if (pack_data.len < 20) {
            try result.addError(try std.fmt.allocPrint(self.allocator, "Pack file too small for checksum", .{}));
            return;
        }
        
        const content_end = pack_data.len - 20;
        const stored_checksum = pack_data[content_end..];
        
        var hasher = std.crypto.hash.Sha1.init(.{});
        hasher.update(pack_data[0..content_end]);
        var computed_checksum: [20]u8 = undefined;
        hasher.final(&computed_checksum);
        
        if (std.mem.eql(u8, &computed_checksum, stored_checksum)) {
            try result.addInfo(try std.fmt.allocPrint(self.allocator, "Pack checksum valid", .{}));
        } else {
            try result.addError(try std.fmt.allocPrint(self.allocator, "Pack checksum mismatch", .{}));
        }
    }
    
    /// Validate consistency between pack and index
    fn validateIndexConsistency(self: PackDiagnostics, pack_data: []const u8, idx_data: []const u8, result: *PackValidationResult) !void {
        _ = pack_data;
        _ = idx_data;
        // TODO: Implement cross-validation between pack and index
        try result.addInfo(try std.fmt.allocPrint(self.allocator, "Index consistency check: TODO", .{}));
    }
    
    /// Validate a sample of objects to ensure readability
    fn validateSampleObjects(self: PackDiagnostics, pack_data: []const u8, idx_data: []const u8, platform_impl: anytype, result: *PackValidationResult) !void {
        _ = pack_data;
        _ = idx_data;
        _ = platform_impl;
        // TODO: Implement sample object validation
        try result.addInfo(try std.fmt.allocPrint(self.allocator, "Sample object validation: TODO", .{}));
    }
};

/// Pack file validation result
pub const PackValidationResult = struct {
    allocator: std.mem.Allocator,
    errors: std.ArrayList([]const u8),
    warnings: std.ArrayList([]const u8),
    info: std.ArrayList([]const u8),
    
    pub fn init(allocator: std.mem.Allocator) PackValidationResult {
        return PackValidationResult{
            .allocator = allocator,
            .errors = std.ArrayList([]const u8).init(allocator),
            .warnings = std.ArrayList([]const u8).init(allocator),
            .info = std.ArrayList([]const u8).init(allocator),
        };
    }
    
    pub fn deinit(self: *PackValidationResult) void {
        for (self.errors.items) |item| {
            self.allocator.free(item);
        }
        for (self.warnings.items) |item| {
            self.allocator.free(item);
        }
        for (self.info.items) |item| {
            self.allocator.free(item);
        }
        self.errors.deinit();
        self.warnings.deinit();
        self.info.deinit();
    }
    
    pub fn addError(self: *PackValidationResult, msg: []const u8) !void {
        try self.errors.append(msg);
    }
    
    pub fn addWarning(self: *PackValidationResult, msg: []const u8) !void {
        try self.warnings.append(msg);
    }
    
    pub fn addInfo(self: *PackValidationResult, msg: []const u8) !void {
        try self.info.append(msg);
    }
    
    pub fn hasErrors(self: PackValidationResult) bool {
        return self.errors.items.len > 0;
    }
    
    pub fn print(self: PackValidationResult) void {
        if (self.info.items.len > 0) {
            std.debug.print("INFO:\n", .{});
            for (self.info.items) |msg| {
                std.debug.print("  {s}\n", .{msg});
            }
        }
        
        if (self.warnings.items.len > 0) {
            std.debug.print("WARNINGS:\n", .{});
            for (self.warnings.items) |msg| {
                std.debug.print("  {s}\n", .{msg});
            }
        }
        
        if (self.errors.items.len > 0) {
            std.debug.print("ERRORS:\n", .{});
            for (self.errors.items) |msg| {
                std.debug.print("  {s}\n", .{msg});
            }
        }
    }
};

/// Pack file repair utilities
pub const PackRepair = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) PackRepair {
        return PackRepair{ .allocator = allocator };
    }
    
    /// Attempt to repair a corrupted pack index by rebuilding from pack file
    pub fn rebuildIndex(self: PackRepair, pack_path: []const u8, platform_impl: anytype) !void {
        _ = self;
        _ = pack_path;
        _ = platform_impl;
        // TODO: Implement index rebuild
        return error.NotImplemented;
    }
    
    /// Extract all readable objects from a pack file, ignoring corrupted ones
    pub fn extractReadableObjects(self: PackRepair, pack_path: []const u8, output_dir: []const u8, platform_impl: anytype) !void {
        _ = self;
        _ = pack_path;
        _ = output_dir;
        _ = platform_impl;
        // TODO: Implement object extraction
        return error.NotImplemented;
    }
};

/// Pack file optimization utilities
pub const PackOptimizer = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) PackOptimizer {
        return PackOptimizer{ .allocator = allocator };
    }
    
    /// Analyze delta efficiency in a pack file
    pub fn analyzeDeltaEfficiency(self: PackOptimizer, pack_path: []const u8, platform_impl: anytype) !DeltaAnalysis {
        _ = self;
        _ = pack_path;
        _ = platform_impl;
        // TODO: Implement delta analysis
        return error.NotImplemented;
    }
};

pub const DeltaAnalysis = struct {
    total_objects: u32,
    delta_objects: u32,
    compression_ratio: f32,
    average_delta_size: f32,
};

/// Pack file information utility
pub const PackInfo = struct {
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) PackInfo {
        return PackInfo{ .allocator = allocator };
    }
    
    /// Get detailed information about a pack file
    pub fn analyze(self: PackInfo, pack_path: []const u8, platform_impl: anytype) !PackAnalysis {
        const pack_data = try platform_impl.fs.readFile(self.allocator, pack_path);
        defer self.allocator.free(pack_data);
        
        var analysis = PackAnalysis.init(self.allocator);
        
        // Basic pack info
        if (pack_data.len >= 12) {
            analysis.version = std.mem.readInt(u32, @ptrCast(pack_data[4..8]), .big);
            analysis.total_objects = std.mem.readInt(u32, @ptrCast(pack_data[8..12]), .big);
            analysis.file_size = pack_data.len;
        }
        
        // TODO: Scan through objects to get detailed statistics
        // This would require implementing a pack scanner that doesn't depend on index
        
        return analysis;
    }
};

pub const PackAnalysis = struct {
    allocator: std.mem.Allocator,
    version: u32 = 0,
    total_objects: u32 = 0,
    file_size: u64 = 0,
    blob_count: u32 = 0,
    tree_count: u32 = 0,
    commit_count: u32 = 0,
    tag_count: u32 = 0,
    ofs_delta_count: u32 = 0,
    ref_delta_count: u32 = 0,
    
    pub fn init(allocator: std.mem.Allocator) PackAnalysis {
        return PackAnalysis{ .allocator = allocator };
    }
    
    pub fn print(self: PackAnalysis) void {
        std.debug.print("Pack Analysis:\n", .{});
        std.debug.print("  Version: {}\n", .{self.version});
        std.debug.print("  Total Objects: {}\n", .{self.total_objects});
        std.debug.print("  File Size: {} bytes\n", .{self.file_size});
        std.debug.print("  Blobs: {}\n", .{self.blob_count});
        std.debug.print("  Trees: {}\n", .{self.tree_count});
        std.debug.print("  Commits: {}\n", .{self.commit_count});
        std.debug.print("  Tags: {}\n", .{self.tag_count});
        std.debug.print("  OFS Deltas: {}\n", .{self.ofs_delta_count});
        std.debug.print("  REF Deltas: {}\n", .{self.ref_delta_count});
        
        if (self.total_objects > 0) {
            const delta_ratio = (@as(f32, @floatFromInt(self.ofs_delta_count + self.ref_delta_count)) / @as(f32, @floatFromInt(self.total_objects))) * 100.0;
            std.debug.print("  Delta Ratio: {d:.1}%\n", .{delta_ratio});
        }
    }
};