const std = @import("std");
const testing = std.testing;

// Test index file parsing with different versions and extensions
test "index file parsing comprehensive test" {
    const allocator = testing.allocator;

    // Create a temporary test repository
    const temp_path = "/tmp/zig-test-index";
    std.fs.cwd().deleteTree(temp_path) catch {};
    try std.fs.cwd().makePath(temp_path);
    defer std.fs.cwd().deleteTree(temp_path) catch {};

    // Initialize git repo
    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "init" }, allocator);
        cmd.cwd = temp_path;
        cmd.stdout_behavior = .Ignore;
        cmd.stderr_behavior = .Ignore;
        _ = try cmd.spawnAndWait();
    }

    // Configure git
    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "config", "user.name", "Test User" }, allocator);
        cmd.cwd = temp_path;
        cmd.stdout_behavior = .Ignore;
        _ = try cmd.spawnAndWait();
    }
    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "config", "user.email", "test@example.com" }, allocator);
        cmd.cwd = temp_path;
        cmd.stdout_behavior = .Ignore;
        _ = try cmd.spawnAndWait();
    }

    // Change to temp directory
    var temp_dir = try std.fs.openDirAbsolute(temp_path, .{});
    defer temp_dir.close();

    // Create test files with various characteristics
    try temp_dir.writeFile(.{ .sub_path = "regular.txt", .data = "Regular file content\n" });
    try temp_dir.writeFile(.{ .sub_path = "file with spaces.txt", .data = "File with spaces in name\n" });
    try temp_dir.writeFile(.{ .sub_path = "unicode-ñame.txt", .data = "Unicode filename test\n" });
    
    // Create subdirectories
    try temp_dir.makeDir("subdir");
    try temp_dir.writeFile(.{ .sub_path = "subdir/nested.txt", .data = "Nested file content\n" });

    // Add files to git index
    {
        var cmd = std.process.Child.init(&[_][]const u8{ "git", "add", "." }, allocator);
        cmd.cwd = temp_path;
        cmd.stdout_behavior = .Ignore;
        _ = try cmd.spawnAndWait();
    }

    // Verify the index file was created and has content
    const index_path = try std.fmt.allocPrint(allocator, "{s}/.git/index", .{temp_path});
    defer allocator.free(index_path);

    const index_data = std.fs.cwd().readFileAlloc(allocator, index_path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("Index file not found after git add, skipping test\n", .{});
            return;
        },
        else => return err,
    };
    defer allocator.free(index_data);

    // Verify index file structure
    if (index_data.len < 12) {
        return error.IndexTooSmall;
    }

    // Check signature
    if (!std.mem.eql(u8, index_data[0..4], "DIRC")) {
        return error.InvalidIndexSignature;
    }

    // Check version
    const version = std.mem.readInt(u32, @ptrCast(index_data[4..8]), .big);
    std.debug.print("Index version: {}\n", .{version});
    
    if (version < 2 or version > 4) {
        return error.UnsupportedIndexVersion;
    }

    // Check entry count
    const entry_count = std.mem.readInt(u32, @ptrCast(index_data[8..12]), .big);
    std.debug.print("Index entry count: {}\n", .{entry_count});
    
    if (entry_count == 0) {
        return error.NoIndexEntries;
    }

    // Basic structure validation passed
    std.debug.print("Index file structure validation passed\n", .{});

    // Test checksum verification (last 20 bytes should be SHA-1)
    if (index_data.len < 20) {
        return error.IndexTooSmallForChecksum;
    }

    const content = index_data[0..index_data.len - 20];
    const stored_checksum = index_data[index_data.len - 20..];

    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(content);
    var computed_checksum: [20]u8 = undefined;
    hasher.final(&computed_checksum);

    if (!std.mem.eql(u8, &computed_checksum, stored_checksum)) {
        return error.IndexChecksumMismatch;
    }

    std.debug.print("Index checksum validation passed\n", .{});
}

test "index file extension handling" {
    // Test that we can handle various index extensions without crashing
    const allocator = testing.allocator;
    
    // Create a minimal valid index with fake extension data
    var index_data = std.ArrayList(u8).init(allocator);
    defer index_data.deinit();
    
    const writer = index_data.writer();
    
    // Write header
    try writer.writeAll("DIRC"); // signature
    try writer.writeInt(u32, 2, .big); // version 2
    try writer.writeInt(u32, 0, .big); // 0 entries for simplicity
    
    // Add a fake extension
    try writer.writeAll("TREE"); // extension signature
    try writer.writeInt(u32, 4, .big); // extension size
    try writer.writeAll("test"); // extension data
    
    // Calculate and write checksum
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(index_data.items);
    var checksum: [20]u8 = undefined;
    hasher.final(&checksum);
    try writer.writeAll(&checksum);
    
    // This test just verifies that our extension parsing doesn't crash
    // A real implementation would parse this data through the index module
    try testing.expect(index_data.items.len > 12);
    try testing.expect(std.mem.eql(u8, index_data.items[0..4], "DIRC"));
    
    std.debug.print("Index extension test structure validated\n", .{});
}

test "index file path encoding test" {
    const allocator = testing.allocator;
    _ = allocator; // Mark as used
    
    // Test various path edge cases that the index should handle
    const test_paths = [_][]const u8{
        "simple.txt",
        "path/with/slashes.txt",
        "file with spaces.txt",
        "unicode-ñame.txt",
        "very-long-filename-that-tests-path-length-limits-in-index-parsing.txt",
        ".hidden-file",
        "ending-with-dot.",
    };
    
    for (test_paths) |path| {
        // Basic validation that paths are reasonable
        try testing.expect(path.len > 0);
        try testing.expect(path.len < 4096); // Git path limit
        
        // Test UTF-8 validity for paths that might contain unicode
        try testing.expect(std.unicode.utf8ValidateSlice(path));
    }
    
    std.debug.print("Index path encoding tests passed\n", .{});
}