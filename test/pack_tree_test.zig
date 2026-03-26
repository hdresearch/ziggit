const std = @import("std");
const pack = @import("../src/git/pack.zig");
const tree = @import("../src/git/tree.zig");
const testing = std.testing;

test "pack statistics analysis" {
    var stats = pack.PackStats.init();
    
    // Test initial values
    try testing.expectEqual(@as(u32, 0), stats.total_objects);
    try testing.expectEqual(@as(u32, 0), stats.commit_objects);
    try testing.expectEqual(@as(u32, 1), stats.index_version);
    
    // Test statistics updates
    stats.total_objects = 100;
    stats.commit_objects = 20;
    stats.tree_objects = 15;
    stats.blob_objects = 60;
    stats.tag_objects = 3;
    stats.ofs_delta_objects = 2;
    
    try testing.expectEqual(@as(u32, 100), stats.total_objects);
    try testing.expectEqual(@as(u32, 20), stats.commit_objects);
    
    // Verify totals add up
    const object_sum = stats.commit_objects + stats.tree_objects + stats.blob_objects + 
                      stats.tag_objects + stats.ofs_delta_objects + stats.ref_delta_objects;
    try testing.expectEqual(stats.total_objects, object_sum);
    
    std.debug.print("Pack statistics test completed\n", .{});
    stats.print();
}

test "tree entry parsing and creation" {
    const allocator = testing.allocator;
    
    // Test tree entry creation
    const mode = "100644";
    const name = "README.md";
    const hash = "2fd4e1c67a2d28fced849ee1bb76e7391b93eb12";
    
    const entry = tree.TreeEntry.init(mode, name, hash);
    
    try testing.expectEqualStrings(mode, entry.mode);
    try testing.expectEqualStrings(name, entry.name);
    try testing.expectEqualStrings(hash, entry.hash);
    try testing.expectEqual(tree.TreeEntry.EntryType.blob, entry.type);
    
    // Test entry type detection
    try testing.expect(!entry.isDirectory());
    try testing.expect(!entry.isExecutable());
    try testing.expect(!entry.isSymlink());
    
    // Test executable file
    const exec_entry = tree.TreeEntry.init("100755", "script.sh", hash);
    try testing.expect(exec_entry.isExecutable());
    try testing.expectEqual(tree.TreeEntry.EntryType.executable, exec_entry.type);
    
    // Test directory
    const dir_entry = tree.TreeEntry.init("040000", "subdir", hash);
    try testing.expect(dir_entry.isDirectory());
    try testing.expectEqual(tree.TreeEntry.EntryType.tree, dir_entry.type);
    
    // Test symlink
    const link_entry = tree.TreeEntry.init("120000", "link.txt", hash);
    try testing.expect(link_entry.isSymlink());
    try testing.expectEqual(tree.TreeEntry.EntryType.symlink, link_entry.type);
}

test "tree entry formatting" {
    const allocator = testing.allocator;
    
    const entry = tree.TreeEntry.init("100644", "test.txt", "abc123");
    const formatted = try entry.format(allocator);
    defer allocator.free(formatted);
    
    // Should match git ls-tree output format
    const expected = "100644 blob abc123\ttest.txt";
    try testing.expectEqualStrings(expected, formatted);
}

test "tree data creation and parsing" {
    const allocator = testing.allocator;
    
    // Create some test entries
    var entries = std.ArrayList(tree.TreeEntry).init(allocator);
    defer {
        for (entries.items) |entry| {
            entry.deinit(allocator);
        }
        entries.deinit();
    }
    
    // Add entries (will test sorting)
    try entries.append(tree.TreeEntry{
        .mode = try allocator.dupe(u8, "100644"),
        .name = try allocator.dupe(u8, "zebra.txt"),
        .hash = try allocator.dupe(u8, "1234567890abcdef1234567890abcdef12345678"),
        .type = .blob,
    });
    
    try entries.append(tree.TreeEntry{
        .mode = try allocator.dupe(u8, "040000"),
        .name = try allocator.dupe(u8, "apple"),
        .hash = try allocator.dupe(u8, "abcdef1234567890abcdef1234567890abcdef12"),
        .type = .tree,
    });
    
    try entries.append(tree.TreeEntry{
        .mode = try allocator.dupe(u8, "100755"),
        .name = try allocator.dupe(u8, "beta.sh"),
        .hash = try allocator.dupe(u8, "fedcba0987654321fedcba0987654321fedcba09"),
        .type = .executable,
    });
    
    // Create tree data
    const tree_data = try tree.createTreeData(entries.items, allocator);
    defer allocator.free(tree_data);
    
    // Parse the tree data back
    var parsed_entries = try tree.parseTree(tree_data, allocator);
    defer {
        for (parsed_entries.items) |entry| {
            entry.deinit(allocator);
        }
        parsed_entries.deinit();
    }
    
    // Should have same number of entries
    try testing.expectEqual(entries.items.len, parsed_entries.items.len);
    
    // Should be sorted by name (apple, beta.sh, zebra.txt)
    try testing.expectEqualStrings("apple", parsed_entries.items[0].name);
    try testing.expectEqualStrings("beta.sh", parsed_entries.items[1].name);
    try testing.expectEqualStrings("zebra.txt", parsed_entries.items[2].name);
    
    // Verify modes and types are preserved
    try testing.expectEqualStrings("040000", parsed_entries.items[0].mode);
    try testing.expect(parsed_entries.items[0].isDirectory());
    
    try testing.expectEqualStrings("100755", parsed_entries.items[1].mode);
    try testing.expect(parsed_entries.items[1].isExecutable());
    
    try testing.expectEqualStrings("100644", parsed_entries.items[2].mode);
    try testing.expect(!parsed_entries.items[2].isDirectory() and !parsed_entries.items[2].isExecutable());
}

test "pack cache functionality" {
    const allocator = testing.allocator;
    const objects = @import("../src/git/objects.zig");
    
    var cache = pack.PackCache.init(allocator, 1024); // 1KB cache
    defer cache.deinit();
    
    // Test cache miss
    try testing.expect(cache.get(12345) == null);
    
    // Test cache put and get
    const test_data = "Hello, world!";
    try cache.put(12345, objects.ObjectType.blob, test_data);
    
    const cached = cache.get(12345);
    try testing.expect(cached != null);
    try testing.expectEqual(objects.ObjectType.blob, cached.?.type);
    try testing.expectEqualStrings(test_data, cached.?.data);
    try testing.expectEqual(@as(u32, 2), cached.?.access_count); // Should be 2 after put + get
    
    // Test cache size management
    try testing.expect(cache.current_size > 0);
    try testing.expect(cache.current_size <= cache.max_size);
}

test "entry type conversions" {
    // Test all entry types
    try testing.expectEqual(tree.TreeEntry.EntryType.tree, tree.TreeEntry.EntryType.fromMode("040000"));
    try testing.expectEqual(tree.TreeEntry.EntryType.blob, tree.TreeEntry.EntryType.fromMode("100644"));
    try testing.expectEqual(tree.TreeEntry.EntryType.executable, tree.TreeEntry.EntryType.fromMode("100755"));
    try testing.expectEqual(tree.TreeEntry.EntryType.symlink, tree.TreeEntry.EntryType.fromMode("120000"));
    try testing.expectEqual(tree.TreeEntry.EntryType.blob, tree.TreeEntry.EntryType.fromMode("unknown")); // Default
    
    // Test toString
    try testing.expectEqualStrings("tree", tree.TreeEntry.EntryType.tree.toString());
    try testing.expectEqualStrings("blob", tree.TreeEntry.EntryType.blob.toString());
    try testing.expectEqualStrings("executable", tree.TreeEntry.EntryType.executable.toString());
    try testing.expectEqualStrings("symlink", tree.TreeEntry.EntryType.symlink.toString());
}