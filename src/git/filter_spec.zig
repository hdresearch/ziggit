const std = @import("std");

/// Git partial clone filter specification
pub const FilterSpec = union(enum) {
    /// No filtering - include all objects
    none,
    /// Skip all blob objects (blobless clone)
    blob_none,
    /// Skip trees beyond specified depth (0 = no trees)
    tree_depth: u32,
    /// Skip blobs larger than specified size in bytes
    blob_limit: u64,

    /// Parse a filter specification string
    pub fn parse(allocator: std.mem.Allocator, filter_str: []const u8) !FilterSpec {
        _ = allocator; // May be needed for future complex filters

        if (std.mem.eql(u8, filter_str, "blob:none")) {
            return FilterSpec.blob_none;
        }

        if (std.mem.startsWith(u8, filter_str, "tree:")) {
            const depth_str = filter_str["tree:".len..];
            const depth = std.fmt.parseInt(u32, depth_str, 10) catch return error.InvalidFilter;
            return FilterSpec{ .tree_depth = depth };
        }

        if (std.mem.startsWith(u8, filter_str, "blob:limit=")) {
            const limit_str = filter_str["blob:limit=".len..];
            const limit = std.fmt.parseInt(u64, limit_str, 10) catch return error.InvalidFilter;
            return FilterSpec{ .blob_limit = limit };
        }

        return error.InvalidFilter;
    }

    /// Convert filter to string for protocol transmission
    pub fn toString(self: FilterSpec, allocator: std.mem.Allocator) ![]u8 {
        return switch (self) {
            .none => try allocator.dupe(u8, ""),
            .blob_none => try allocator.dupe(u8, "blob:none"),
            .tree_depth => |depth| try std.fmt.allocPrint(allocator, "tree:{d}", .{depth}),
            .blob_limit => |limit| try std.fmt.allocPrint(allocator, "blob:limit={d}", .{limit}),
        };
    }

    /// Check if an object should be included based on this filter
    pub fn shouldInclude(self: FilterSpec, obj_type: ObjectType, obj_size: u64) bool {
        return switch (self) {
            .none => true,
            .blob_none => obj_type != .blob,
            .tree_depth => |depth| if (obj_type == .tree and depth == 0) false else true,
            .blob_limit => |limit| if (obj_type == .blob and obj_size > limit) false else true,
        };
    }
};

pub const ObjectType = enum {
    commit,
    tree,
    blob,
    tag,
};

test "FilterSpec.parse" {
    const allocator = std.testing.allocator;

    // Test blob:none
    const blob_none = try FilterSpec.parse(allocator, "blob:none");
    try std.testing.expect(blob_none == .blob_none);

    // Test tree:0
    const tree_0 = try FilterSpec.parse(allocator, "tree:0");
    try std.testing.expect(tree_0 == .tree_depth and tree_0.tree_depth == 0);

    // Test blob:limit=1024
    const blob_limit = try FilterSpec.parse(allocator, "blob:limit=1024");
    try std.testing.expect(blob_limit == .blob_limit and blob_limit.blob_limit == 1024);

    // Test invalid filter
    try std.testing.expectError(error.InvalidFilter, FilterSpec.parse(allocator, "invalid:filter"));
}

test "FilterSpec.shouldInclude" {
    const blob_none = FilterSpec.blob_none;
    try std.testing.expect(blob_none.shouldInclude(.commit, 100));
    try std.testing.expect(blob_none.shouldInclude(.tree, 100));
    try std.testing.expect(!blob_none.shouldInclude(.blob, 100));
    try std.testing.expect(blob_none.shouldInclude(.tag, 100));

    const tree_0 = FilterSpec{ .tree_depth = 0 };
    try std.testing.expect(tree_0.shouldInclude(.commit, 100));
    try std.testing.expect(!tree_0.shouldInclude(.tree, 100));
    try std.testing.expect(tree_0.shouldInclude(.blob, 100));

    const blob_limit = FilterSpec{ .blob_limit = 1024 };
    try std.testing.expect(blob_limit.shouldInclude(.blob, 512));
    try std.testing.expect(!blob_limit.shouldInclude(.blob, 2048));
    try std.testing.expect(blob_limit.shouldInclude(.commit, 2048));
}
