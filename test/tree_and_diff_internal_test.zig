// test/tree_and_diff_internal_test.zig - Tests for tree parsing/creation and diff generation
const std = @import("std");
const tree_mod = @import("tree");
const testing = std.testing;

const TreeEntry = tree_mod.TreeEntry;

// ============================================================================
// TreeEntry type detection
// ============================================================================

test "TreeEntry.EntryType.fromMode: regular file" {
    try testing.expectEqual(TreeEntry.EntryType.blob, TreeEntry.EntryType.fromMode("100644"));
}

test "TreeEntry.EntryType.fromMode: executable" {
    try testing.expectEqual(TreeEntry.EntryType.executable, TreeEntry.EntryType.fromMode("100755"));
}

test "TreeEntry.EntryType.fromMode: directory" {
    try testing.expectEqual(TreeEntry.EntryType.tree, TreeEntry.EntryType.fromMode("040000"));
}

test "TreeEntry.EntryType.fromMode: symlink" {
    try testing.expectEqual(TreeEntry.EntryType.symlink, TreeEntry.EntryType.fromMode("120000"));
}

test "TreeEntry.EntryType.fromMode: unknown defaults to blob" {
    try testing.expectEqual(TreeEntry.EntryType.blob, TreeEntry.EntryType.fromMode("999999"));
}

test "TreeEntry.EntryType.toString roundtrip" {
    const types = [_]TreeEntry.EntryType{ .blob, .tree, .symlink, .executable };
    const names = [_][]const u8{ "blob", "tree", "symlink", "executable" };
    for (types, names) |t, name| {
        try testing.expectEqualStrings(name, t.toString());
    }
}

// ============================================================================
// TreeEntry properties
// ============================================================================

test "TreeEntry.isDirectory" {
    const dir_entry = TreeEntry.init("040000", "subdir", "a" ** 40);
    try testing.expect(dir_entry.isDirectory());

    const file_entry = TreeEntry.init("100644", "file.txt", "b" ** 40);
    try testing.expect(!file_entry.isDirectory());
}

test "TreeEntry.isExecutable" {
    const exec_entry = TreeEntry.init("100755", "script.sh", "c" ** 40);
    try testing.expect(exec_entry.isExecutable());

    const reg_entry = TreeEntry.init("100644", "data.txt", "d" ** 40);
    try testing.expect(!reg_entry.isExecutable());
}

test "TreeEntry.isSymlink" {
    const sym_entry = TreeEntry.init("120000", "link", "e" ** 40);
    try testing.expect(sym_entry.isSymlink());

    const reg_entry = TreeEntry.init("100644", "data.txt", "f" ** 40);
    try testing.expect(!reg_entry.isSymlink());
}

// ============================================================================
// Tree creation and parsing roundtrip
// ============================================================================

test "createTreeData then parseTree roundtrip: single entry" {
    const hash_hex = "a" ** 40;
    const entry = TreeEntry.init("100644", "hello.txt", hash_hex);
    const entries = [_]TreeEntry{entry};

    const tree_data = try tree_mod.createTreeData(&entries, testing.allocator);
    defer testing.allocator.free(tree_data);

    var parsed = try tree_mod.parseTree(tree_data, testing.allocator);
    defer {
        for (parsed.items) |*e| e.deinit(testing.allocator);
        parsed.deinit();
    }

    try testing.expectEqual(@as(usize, 1), parsed.items.len);
    try testing.expectEqualStrings("100644", parsed.items[0].mode);
    try testing.expectEqualStrings("hello.txt", parsed.items[0].name);
    try testing.expectEqualStrings(hash_hex, parsed.items[0].hash);
}

test "createTreeData then parseTree roundtrip: multiple entries" {
    const e1 = TreeEntry.init("100644", "a.txt", "a" ** 40);
    const e2 = TreeEntry.init("100755", "b.sh", "b" ** 40);
    const e3 = TreeEntry.init("040000", "subdir", "c" ** 40);
    const entries = [_]TreeEntry{ e1, e2, e3 };

    const tree_data = try tree_mod.createTreeData(&entries, testing.allocator);
    defer testing.allocator.free(tree_data);

    var parsed = try tree_mod.parseTree(tree_data, testing.allocator);
    defer {
        for (parsed.items) |*e| e.deinit(testing.allocator);
        parsed.deinit();
    }

    try testing.expectEqual(@as(usize, 3), parsed.items.len);
    try testing.expectEqualStrings("a.txt", parsed.items[0].name);
    try testing.expectEqualStrings("b.sh", parsed.items[1].name);
    try testing.expectEqualStrings("subdir", parsed.items[2].name);
}

test "createTreeData produces consistent output" {
    const entry = TreeEntry.init("100644", "file.txt", "abcdef0123456789abcdef0123456789abcdef01");
    const entries = [_]TreeEntry{entry};

    const data1 = try tree_mod.createTreeData(&entries, testing.allocator);
    defer testing.allocator.free(data1);
    const data2 = try tree_mod.createTreeData(&entries, testing.allocator);
    defer testing.allocator.free(data2);

    try testing.expectEqualSlices(u8, data1, data2);
}

test "parseTree with empty data returns empty list" {
    var parsed = try tree_mod.parseTree("", testing.allocator);
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 0), parsed.items.len);
}

test "TreeEntry.format produces readable output" {
    const entry = TreeEntry.init("100644", "hello.txt", "a" ** 40);
    const formatted = try entry.format(testing.allocator);
    defer testing.allocator.free(formatted);

    // Should contain mode, name, and hash
    try testing.expect(std.mem.indexOf(u8, formatted, "100644") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "hello.txt") != null);
}
