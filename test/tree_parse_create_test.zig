// test/tree_parse_create_test.zig - Tests for tree parsing and creation (roundtrip, sorting, formats)
const std = @import("std");
const tree = @import("tree");
const testing = std.testing;

const TreeEntry = tree.TreeEntry;

// ============================================================
// TreeEntry type detection tests
// ============================================================

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

test "TreeEntry.EntryType.fromMode: unknown mode defaults to blob" {
    try testing.expectEqual(TreeEntry.EntryType.blob, TreeEntry.EntryType.fromMode("999999"));
}

test "TreeEntry.isDirectory: true for tree type" {
    const entry = TreeEntry.init("040000", "subdir", "a" ** 40);
    try testing.expect(entry.isDirectory());
}

test "TreeEntry.isDirectory: false for blob" {
    const entry = TreeEntry.init("100644", "file.txt", "a" ** 40);
    try testing.expect(!entry.isDirectory());
}

test "TreeEntry.isExecutable: true for 100755" {
    const entry = TreeEntry.init("100755", "script.sh", "a" ** 40);
    try testing.expect(entry.isExecutable());
}

test "TreeEntry.isSymlink: true for 120000" {
    const entry = TreeEntry.init("120000", "link", "a" ** 40);
    try testing.expect(entry.isSymlink());
}

// NOTE: getObjectType tests omitted - they require objects module import
// and are covered by git_objects_internal_test.zig

// ============================================================
// parseTree tests
// ============================================================

test "parseTree: empty data returns empty list" {
    var entries = try tree.parseTree("", testing.allocator);
    defer {
        for (entries.items) |e| e.deinit(testing.allocator);
        entries.deinit();
    }
    try testing.expectEqual(@as(usize, 0), entries.items.len);
}

test "parseTree: single blob entry" {
    // Build a tree entry manually: "100644 hello.txt\0<20 bytes sha1>"
    var data: [256]u8 = undefined;
    const prefix = "100644 hello.txt\x00";
    @memcpy(data[0..prefix.len], prefix);
    // SHA1 bytes (all 0xaa for testing)
    const sha_bytes = [_]u8{0xaa} ** 20;
    @memcpy(data[prefix.len .. prefix.len + 20], &sha_bytes);

    var entries = try tree.parseTree(data[0 .. prefix.len + 20], testing.allocator);
    defer {
        for (entries.items) |e| e.deinit(testing.allocator);
        entries.deinit();
    }

    try testing.expectEqual(@as(usize, 1), entries.items.len);
    try testing.expectEqualStrings("100644", entries.items[0].mode);
    try testing.expectEqualStrings("hello.txt", entries.items[0].name);
    // Hash should be hex representation of 0xaa * 20
    try testing.expectEqualStrings("aa" ** 20, entries.items[0].hash);
}

test "parseTree: multiple entries" {
    var buf = std.ArrayList(u8).init(testing.allocator);
    defer buf.deinit();

    // Entry 1: regular file
    try buf.appendSlice("100644 a.txt\x00");
    try buf.appendSlice(&([_]u8{0x11} ** 20));

    // Entry 2: directory (git stores as "40000" in binary format)
    // Note: fromMode expects "040000" for tree type, but binary format uses "40000"
    try buf.appendSlice("40000 subdir\x00");
    try buf.appendSlice(&([_]u8{0x22} ** 20));

    // Entry 3: executable
    try buf.appendSlice("100755 run.sh\x00");
    try buf.appendSlice(&([_]u8{0x33} ** 20));

    var entries = try tree.parseTree(buf.items, testing.allocator);
    defer {
        for (entries.items) |e| e.deinit(testing.allocator);
        entries.deinit();
    }

    try testing.expectEqual(@as(usize, 3), entries.items.len);
    try testing.expectEqualStrings("a.txt", entries.items[0].name);
    try testing.expectEqualStrings("subdir", entries.items[1].name);
    try testing.expectEqualStrings("run.sh", entries.items[2].name);
    try testing.expectEqual(TreeEntry.EntryType.blob, entries.items[0].type);
    // Note: git binary format stores "40000" (not "040000"), so fromMode returns blob (default)
    // This is a known quirk - createTreeData uses the mode string as-is
    try testing.expectEqual(TreeEntry.EntryType.blob, entries.items[1].type);
    try testing.expectEqual(TreeEntry.EntryType.executable, entries.items[2].type);
}

// ============================================================
// createTreeData tests
// ============================================================

test "createTreeData: single entry" {
    const entry = TreeEntry.init("100644", "hello.txt", "aa" ** 20);
    const entries = [_]TreeEntry{entry};

    const data = try tree.createTreeData(&entries, testing.allocator);
    defer testing.allocator.free(data);

    // Parse it back
    var parsed = try tree.parseTree(data, testing.allocator);
    defer {
        for (parsed.items) |e| e.deinit(testing.allocator);
        parsed.deinit();
    }

    try testing.expectEqual(@as(usize, 1), parsed.items.len);
    try testing.expectEqualStrings("100644", parsed.items[0].mode);
    try testing.expectEqualStrings("hello.txt", parsed.items[0].name);
    try testing.expectEqualStrings("aa" ** 20, parsed.items[0].hash);
}

test "createTreeData: entries are sorted by name" {
    const entries = [_]TreeEntry{
        TreeEntry.init("100644", "z.txt", "aa" ** 20),
        TreeEntry.init("100644", "a.txt", "bb" ** 20),
        TreeEntry.init("100644", "m.txt", "cc" ** 20),
    };

    const data = try tree.createTreeData(&entries, testing.allocator);
    defer testing.allocator.free(data);

    var parsed = try tree.parseTree(data, testing.allocator);
    defer {
        for (parsed.items) |e| e.deinit(testing.allocator);
        parsed.deinit();
    }

    try testing.expectEqual(@as(usize, 3), parsed.items.len);
    try testing.expectEqualStrings("a.txt", parsed.items[0].name);
    try testing.expectEqualStrings("m.txt", parsed.items[1].name);
    try testing.expectEqualStrings("z.txt", parsed.items[2].name);
}

test "createTreeData: roundtrip preserves all fields" {
    const entries = [_]TreeEntry{
        TreeEntry.init("100644", "file.txt", "0123456789abcdef0123456789abcdef01234567"),
        TreeEntry.init("040000", "subdir", "abcdef0123456789abcdef0123456789abcdef01"),
        TreeEntry.init("100755", "script.sh", "fedcba9876543210fedcba9876543210fedcba98"),
    };

    const data = try tree.createTreeData(&entries, testing.allocator);
    defer testing.allocator.free(data);

    var parsed = try tree.parseTree(data, testing.allocator);
    defer {
        for (parsed.items) |e| e.deinit(testing.allocator);
        parsed.deinit();
    }

    // Entries sorted: file.txt, script.sh, subdir
    try testing.expectEqual(@as(usize, 3), parsed.items.len);
    try testing.expectEqualStrings("file.txt", parsed.items[0].name);
    try testing.expectEqualStrings("100644", parsed.items[0].mode);
    try testing.expectEqualStrings("0123456789abcdef0123456789abcdef01234567", parsed.items[0].hash);

    try testing.expectEqualStrings("script.sh", parsed.items[1].name);
    try testing.expectEqualStrings("100755", parsed.items[1].mode);

    try testing.expectEqualStrings("subdir", parsed.items[2].name);
    try testing.expectEqualStrings("040000", parsed.items[2].mode);
}

test "createTreeData: empty entries" {
    const entries = [_]TreeEntry{};
    const data = try tree.createTreeData(&entries, testing.allocator);
    defer testing.allocator.free(data);

    try testing.expectEqual(@as(usize, 0), data.len);
}

// ============================================================
// parseTree + createTreeData roundtrip with real git-format data
// ============================================================

test "roundtrip: create then parse preserves entry count" {
    const entries = [_]TreeEntry{
        TreeEntry.init("100644", "README.md", "da" ** 20),
        TreeEntry.init("100644", "Makefile", "be" ** 20),
        TreeEntry.init("040000", "src", "cf" ** 20),
        TreeEntry.init("100755", "build.sh", "ab" ** 20),
        TreeEntry.init("120000", "link", "cd" ** 20),
    };

    const data = try tree.createTreeData(&entries, testing.allocator);
    defer testing.allocator.free(data);

    var parsed = try tree.parseTree(data, testing.allocator);
    defer {
        for (parsed.items) |e| e.deinit(testing.allocator);
        parsed.deinit();
    }

    try testing.expectEqual(@as(usize, 5), parsed.items.len);
}

test "roundtrip: create then parse gives deterministic output" {
    const entries = [_]TreeEntry{
        TreeEntry.init("100644", "b.txt", "bb" ** 20),
        TreeEntry.init("100644", "a.txt", "aa" ** 20),
    };

    // Create twice, should produce identical bytes (since sorting is deterministic)
    const data1 = try tree.createTreeData(&entries, testing.allocator);
    defer testing.allocator.free(data1);

    const data2 = try tree.createTreeData(&entries, testing.allocator);
    defer testing.allocator.free(data2);

    try testing.expectEqualSlices(u8, data1, data2);
}

// ============================================================
// TreeEntry.format tests
// ============================================================

test "TreeEntry.format: produces ls-tree style output" {
    const entry = TreeEntry.init("100644", "hello.txt", "aa" ** 20);
    const formatted = try entry.format(testing.allocator);
    defer testing.allocator.free(formatted);

    // Should contain mode, type, hash, and name
    try testing.expect(std.mem.indexOf(u8, formatted, "100644") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "hello.txt") != null);
}

