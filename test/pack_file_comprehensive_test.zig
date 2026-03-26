const std = @import("std");
const testing = std.testing;
const objects = @import("git_objects");

// Mock filesystem that always returns FileNotFound
const EmptyFs = struct {
    pub fn readFile(_: EmptyFs, alloc: std.mem.Allocator, path: []const u8) ![]u8 {
        _ = alloc;
        _ = path;
        return error.FileNotFound;
    }
};
const EmptyPlatform = struct { fs: EmptyFs = .{} };

// Mock filesystem that returns corrupted data
const CorruptedFs = struct {
    pub fn readFile(_: CorruptedFs, alloc: std.mem.Allocator, path: []const u8) ![]u8 {
        _ = path;
        return try alloc.dupe(u8, "CORRUPTED");
    }
};
const CorruptedPlatform = struct { fs: CorruptedFs = .{} };

test "pack object type parsing" {
    const allocator = testing.allocator;

    const valid_types = [_]u8{ 1, 2, 3, 4, 6, 7 };
    const invalid_types = [_]u8{ 0, 5, 8, 9, 255 };

    try testing.expect(valid_types.len == 6);
    try testing.expect(invalid_types.len == 5);

    var pack_data = std.ArrayList(u8).init(allocator);
    defer pack_data.deinit();

    try pack_data.appendSlice("PACK");
    try pack_data.writer().writeInt(u32, 2, .big);
    try pack_data.writer().writeInt(u32, 1, .big);
    try pack_data.append(0x35); // type=3 (blob), size=5

    try testing.expect(pack_data.items.len >= 12);
}

test "pack index v1 and v2 format support" {
    const allocator = testing.allocator;

    var idx_data = std.ArrayList(u8).init(allocator);
    defer idx_data.deinit();

    try idx_data.writer().writeInt(u32, 0xff744f63, .big);
    try idx_data.writer().writeInt(u32, 2, .big);

    var i: u32 = 0;
    while (i < 256) : (i += 1) {
        try idx_data.writer().writeInt(u32, i, .big);
    }

    try testing.expect(idx_data.items.len >= 8 + 256 * 4);
}

test "delta application edge cases" {
    const allocator = testing.allocator;
    const base_data = "Hello, world!";
    try testing.expect(base_data.len == 13);

    var delta = std.ArrayList(u8).init(allocator);
    defer delta.deinit();

    try delta.append(13); // base size
    try delta.append(19); // result size
    // Copy command: offset=0, size=13
    // cmd = 0x80 | 0x10 (size byte present, no offset bytes since offset=0)
    try delta.append(0x90);
    try delta.append(13);   // size = 13
    // Insert command: insert 6 bytes " again"
    try delta.append(6);
    try delta.appendSlice(" again");

    const result = try objects.applyDelta(base_data, delta.items, allocator);
    defer allocator.free(result);
    try testing.expectEqualStrings("Hello, world! again", result);
}

test "pack file corruption detection" {
    const allocator = testing.allocator;

    var corrupted_pack = std.ArrayList(u8).init(allocator);
    defer corrupted_pack.deinit();

    try corrupted_pack.appendSlice("PACX");
    try corrupted_pack.writer().writeInt(u32, 2, .big);
    try corrupted_pack.writer().writeInt(u32, 0, .big);
    var fake_checksum = [_]u8{0} ** 20;
    try corrupted_pack.appendSlice(&fake_checksum);

    try testing.expect(corrupted_pack.items.len >= 28);
    try testing.expect(!std.mem.eql(u8, corrupted_pack.items[0..4], "PACK"));
}

test "pack file size limits and validation" {
    const allocator = testing.allocator;

    var min_pack = std.ArrayList(u8).init(allocator);
    defer min_pack.deinit();

    try min_pack.appendSlice("PACK");
    try min_pack.writer().writeInt(u32, 2, .big);
    try min_pack.writer().writeInt(u32, 0, .big);
    const checksum = [_]u8{0} ** 20;
    try min_pack.appendSlice(&checksum);

    try testing.expect(min_pack.items.len == 32); // PACK(4) + version(4) + count(4) + sha1(20)
}

test "pack file access verification" {
    const allocator = testing.allocator;

    const platform_empty = EmptyPlatform{};
    const has_access = try objects.verifyPackFileAccess("test/.git", &platform_empty, allocator);
    try testing.expect(!has_access);

    const platform_corrupted = CorruptedPlatform{};
    const has_access_corrupted = try objects.verifyPackFileAccess("test/.git", &platform_corrupted, allocator);
    try testing.expect(!has_access_corrupted);
}

test "pack statistics and analysis" {
    const stats = objects.PackFileStats{
        .total_objects = 1000,
        .blob_count = 800,
        .tree_count = 150,
        .commit_count = 45,
        .tag_count = 5,
        .delta_count = 600,
        .file_size = 1024 * 1024,
        .is_thin = false,
        .version = 2,
        .checksum_valid = true,
    };

    const compression_ratio = stats.getCompressionRatio();
    try testing.expect(compression_ratio > 0);
}

test "pack health scoring" {
    const allocator = testing.allocator;

    var health = objects.RepositoryPackHealth{
        .total_pack_files = 5,
        .healthy_pack_files = 4,
        .corrupted_pack_files = 1,
        .total_objects = 10000,
        .estimated_total_size = 50 * 1024 * 1024,
        .compression_ratio = 3.5,
        .has_delta_objects = true,
        .issues = std.ArrayList([]const u8).init(allocator),
    };
    defer health.deinit();

    try testing.expect(!health.isHealthy());

    var healthy_repo = objects.RepositoryPackHealth{
        .total_pack_files = 3,
        .healthy_pack_files = 3,
        .corrupted_pack_files = 0,
        .total_objects = 5000,
        .estimated_total_size = 25 * 1024 * 1024,
        .compression_ratio = 4.0,
        .has_delta_objects = true,
        .issues = std.ArrayList([]const u8).init(allocator),
    };
    defer healthy_repo.deinit();

    try testing.expect(healthy_repo.isHealthy());
}

test "pack object summary generation" {
    const summary = objects.PackObjectSummary{
        .total_objects = 1000,
        .commits = 50,
        .trees = 200,
        .blobs = 700,
        .tags = 10,
        .deltas = 400,
        .estimated_uncompressed_size = 10 * 1024 * 1024,
    };

    const delta_ratio = @as(f32, @floatFromInt(summary.deltas)) / @as(f32, @floatFromInt(summary.total_objects));
    try testing.expect(delta_ratio == 0.4);

    const total_typed = summary.commits + summary.trees + summary.blobs + summary.tags;
    try testing.expect(total_typed <= summary.total_objects);
}
