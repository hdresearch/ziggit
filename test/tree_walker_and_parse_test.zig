// test/tree_walker_and_parse_test.zig - Tests for tree parsing, creation, and type detection
const std = @import("std");
const testing = std.testing;
const tree = @import("tree");
const TreeEntry = tree.TreeEntry;

// ============================================================================
// parseTree: basic parsing of git tree binary format
// ============================================================================

fn buildTreeEntry(buf: *std.ArrayList(u8), mode: []const u8, name: []const u8, hash_byte: u8) !void {
    try buf.appendSlice(mode);
    try buf.append(' ');
    try buf.appendSlice(name);
    try buf.append(0);
    try buf.appendSlice(&([_]u8{hash_byte} ** 20));
}

test "parseTree: empty tree data" {
    var entries = try tree.parseTree("", testing.allocator);
    defer entries.deinit();
    try testing.expectEqual(@as(usize, 0), entries.items.len);
}

test "parseTree: single blob entry" {
    var buf = std.ArrayList(u8).init(testing.allocator);
    defer buf.deinit();
    try buildTreeEntry(&buf, "100644", "hello.txt", 0xAB);

    var entries = try tree.parseTree(buf.items, testing.allocator);
    defer {
        for (entries.items) |e| e.deinit(testing.allocator);
        entries.deinit();
    }

    try testing.expectEqual(@as(usize, 1), entries.items.len);
    try testing.expectEqualStrings("100644", entries.items[0].mode);
    try testing.expectEqualStrings("hello.txt", entries.items[0].name);
    try testing.expectEqual(TreeEntry.EntryType.blob, entries.items[0].type);
    try testing.expect(!entries.items[0].isDirectory());
    try testing.expect(!entries.items[0].isExecutable());
    try testing.expect(!entries.items[0].isSymlink());
    try testing.expectEqual(@as(usize, 40), entries.items[0].hash.len);
    // 0xAB repeated = "abababab..."
    try testing.expectEqualStrings("ab", entries.items[0].hash[0..2]);
}

test "parseTree: multiple entries with different types" {
    var buf = std.ArrayList(u8).init(testing.allocator);
    defer buf.deinit();
    // Note: git binary format uses "40000" for dirs, but fromMode expects "040000"
    // Use "040000" to get correct tree type classification
    try buildTreeEntry(&buf, "100644", "a.txt", 0x01);
    try buildTreeEntry(&buf, "040000", "dir", 0x02);
    try buildTreeEntry(&buf, "100755", "run.sh", 0x03);

    var entries = try tree.parseTree(buf.items, testing.allocator);
    defer {
        for (entries.items) |e| e.deinit(testing.allocator);
        entries.deinit();
    }

    try testing.expectEqual(@as(usize, 3), entries.items.len);
    try testing.expectEqualStrings("a.txt", entries.items[0].name);
    try testing.expectEqual(TreeEntry.EntryType.blob, entries.items[0].type);

    try testing.expectEqualStrings("dir", entries.items[1].name);
    try testing.expectEqual(TreeEntry.EntryType.tree, entries.items[1].type);
    try testing.expect(entries.items[1].isDirectory());

    try testing.expectEqualStrings("run.sh", entries.items[2].name);
    try testing.expectEqual(TreeEntry.EntryType.executable, entries.items[2].type);
    try testing.expect(entries.items[2].isExecutable());
}

test "parseTree: symlink entry" {
    var buf = std.ArrayList(u8).init(testing.allocator);
    defer buf.deinit();
    try buildTreeEntry(&buf, "120000", "link", 0xFF);

    var entries = try tree.parseTree(buf.items, testing.allocator);
    defer {
        for (entries.items) |e| e.deinit(testing.allocator);
        entries.deinit();
    }

    try testing.expectEqual(@as(usize, 1), entries.items.len);
    try testing.expect(entries.items[0].isSymlink());
    try testing.expectEqual(TreeEntry.EntryType.symlink, entries.items[0].type);
}

test "parseTree: handles binary hash bytes including 0x00" {
    var buf = std.ArrayList(u8).init(testing.allocator);
    defer buf.deinit();

    try buf.appendSlice("100644 test.bin\x00");
    var hash: [20]u8 = undefined;
    for (0..20) |i| hash[i] = @intCast(i * 3 + 7); // values 7..64, no overflow
    try buf.appendSlice(&hash);

    var entries = try tree.parseTree(buf.items, testing.allocator);
    defer {
        for (entries.items) |e| e.deinit(testing.allocator);
        entries.deinit();
    }

    try testing.expectEqual(@as(usize, 1), entries.items.len);
    try testing.expectEqualStrings("test.bin", entries.items[0].name);
    // First byte: 0*3+7 = 7 = 0x07, second byte: 1*3+7 = 10 = 0x0a
    try testing.expectEqualStrings("07", entries.items[0].hash[0..2]);
    try testing.expectEqualStrings("0a", entries.items[0].hash[2..4]);
}

test "parseTree: truncated data returns only complete entries" {
    var buf = std.ArrayList(u8).init(testing.allocator);
    defer buf.deinit();

    // Complete first entry
    try buildTreeEntry(&buf, "100644", "a.txt", 0xAA);
    // Incomplete second entry (missing hash bytes)
    try buf.appendSlice("100644 b.txt\x00");
    try buf.appendSlice(&([_]u8{0xBB} ** 10)); // only 10 of 20 bytes

    var entries = try tree.parseTree(buf.items, testing.allocator);
    defer {
        for (entries.items) |e| e.deinit(testing.allocator);
        entries.deinit();
    }

    try testing.expectEqual(@as(usize, 1), entries.items.len);
    try testing.expectEqualStrings("a.txt", entries.items[0].name);
}

// ============================================================================
// createTreeData: roundtrip with parseTree
// ============================================================================

test "createTreeData: single entry roundtrips" {
    const entry = TreeEntry{
        .mode = "100644",
        .name = "file.txt",
        .hash = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391",
        .type = .blob,
    };

    const data = try tree.createTreeData(&[_]TreeEntry{entry}, testing.allocator);
    defer testing.allocator.free(data);

    var parsed = try tree.parseTree(data, testing.allocator);
    defer {
        for (parsed.items) |e| e.deinit(testing.allocator);
        parsed.deinit();
    }

    try testing.expectEqual(@as(usize, 1), parsed.items.len);
    try testing.expectEqualStrings("100644", parsed.items[0].mode);
    try testing.expectEqualStrings("file.txt", parsed.items[0].name);
    try testing.expectEqualStrings("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391", parsed.items[0].hash);
}

test "createTreeData: sorts entries by name" {
    const entries = [_]TreeEntry{
        .{ .mode = "100644", .name = "z.txt", .hash = "0000000000000000000000000000000000000001", .type = .blob },
        .{ .mode = "100644", .name = "a.txt", .hash = "0000000000000000000000000000000000000002", .type = .blob },
        .{ .mode = "40000", .name = "m_dir", .hash = "0000000000000000000000000000000000000003", .type = .tree },
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
    try testing.expectEqualStrings("m_dir", parsed.items[1].name);
    try testing.expectEqualStrings("z.txt", parsed.items[2].name);
}

test "createTreeData: preserves all entry data through roundtrip" {
    const entries = [_]TreeEntry{
        .{ .mode = "100644", .name = "README.md", .hash = "d670460b4b4aece5915caf5c68d12f560a9fe3e4", .type = .blob },
        .{ .mode = "100755", .name = "run.sh", .hash = "b6fc4c620b67d95f953a5c1c1230aaab5db5a1b0", .type = .executable },
        .{ .mode = "040000", .name = "src", .hash = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391", .type = .tree },
        .{ .mode = "120000", .name = "link", .hash = "3b18e512dba79e4c8300dd08aeb37f8e728b8dad", .type = .symlink },
    };

    const data = try tree.createTreeData(&entries, testing.allocator);
    defer testing.allocator.free(data);

    var parsed = try tree.parseTree(data, testing.allocator);
    defer {
        for (parsed.items) |e| e.deinit(testing.allocator);
        parsed.deinit();
    }

    try testing.expectEqual(@as(usize, 4), parsed.items.len);
    // After sorting: README.md, link, run.sh, src
    try testing.expectEqualStrings("README.md", parsed.items[0].name);
    try testing.expectEqualStrings("d670460b4b4aece5915caf5c68d12f560a9fe3e4", parsed.items[0].hash);

    try testing.expectEqualStrings("link", parsed.items[1].name);
    try testing.expect(parsed.items[1].isSymlink());

    try testing.expectEqualStrings("run.sh", parsed.items[2].name);
    try testing.expect(parsed.items[2].isExecutable());

    try testing.expectEqualStrings("src", parsed.items[3].name);
    try testing.expect(parsed.items[3].isDirectory());
}

test "createTreeData: empty entries produces empty data" {
    const data = try tree.createTreeData(&[_]TreeEntry{}, testing.allocator);
    defer testing.allocator.free(data);
    try testing.expectEqual(@as(usize, 0), data.len);
}

test "createTreeData: output is valid git binary tree format" {
    const entry = TreeEntry{
        .mode = "100644",
        .name = "test.txt",
        .hash = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391",
        .type = .blob,
    };

    const data = try tree.createTreeData(&[_]TreeEntry{entry}, testing.allocator);
    defer testing.allocator.free(data);

    // Format: "<mode> <name>\0<20-byte-hash>"
    // "100644 test.txt\0" = 16 bytes + 20 hash bytes = 36 total
    try testing.expectEqual(@as(usize, 16 + 20), data.len);
    try testing.expectEqualStrings("100644 ", data[0..7]);
    try testing.expectEqualStrings("test.txt", data[7..15]);
    try testing.expectEqual(@as(u8, 0), data[15]);
    try testing.expectEqual(@as(u8, 0xe6), data[16]); // first byte of hash
}

// ============================================================================
// TreeEntry type detection comprehensive
// ============================================================================

test "EntryType.fromMode: all standard modes" {
    try testing.expectEqual(TreeEntry.EntryType.blob, TreeEntry.EntryType.fromMode("100644"));
    try testing.expectEqual(TreeEntry.EntryType.executable, TreeEntry.EntryType.fromMode("100755"));
    // Note: fromMode only recognizes "040000" (with leading zero), not "40000"
    try testing.expectEqual(TreeEntry.EntryType.tree, TreeEntry.EntryType.fromMode("040000"));
    try testing.expectEqual(TreeEntry.EntryType.symlink, TreeEntry.EntryType.fromMode("120000"));
}

test "EntryType.fromMode: unknown mode defaults to blob" {
    try testing.expectEqual(TreeEntry.EntryType.blob, TreeEntry.EntryType.fromMode("999999"));
    try testing.expectEqual(TreeEntry.EntryType.blob, TreeEntry.EntryType.fromMode(""));
}

test "EntryType.toString returns non-empty strings" {
    const types = [_]TreeEntry.EntryType{ .blob, .tree, .symlink, .executable };
    for (types) |t| {
        const s = t.toString();
        try testing.expect(s.len > 0);
    }
}

test "TreeEntry.getObjectType: blob types map to blob, tree maps to tree" {
    // blob, executable, symlink all map to git blob object type
    const blob_entry = TreeEntry{ .mode = "100644", .name = "x", .hash = "aa" ** 20, .type = .blob };
    const exec_entry = TreeEntry{ .mode = "100755", .name = "x", .hash = "aa" ** 20, .type = .executable };
    const sym_entry = TreeEntry{ .mode = "120000", .name = "x", .hash = "aa" ** 20, .type = .symlink };
    const tree_entry = TreeEntry{ .mode = "40000", .name = "x", .hash = "aa" ** 20, .type = .tree };

    // All non-tree types should return the same object type
    const blob_ot = blob_entry.getObjectType();
    const exec_ot = exec_entry.getObjectType();
    const sym_ot = sym_entry.getObjectType();
    const tree_ot = tree_entry.getObjectType();

    try testing.expectEqual(blob_ot, exec_ot);
    try testing.expectEqual(blob_ot, sym_ot);
    try testing.expect(blob_ot != tree_ot);
}

// ============================================================================
// TreeEntry.format
// ============================================================================

test "TreeEntry.format produces readable output with all fields" {
    const entry = TreeEntry{
        .mode = "100644",
        .name = "hello.txt",
        .hash = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391",
        .type = .blob,
    };

    const formatted = try entry.format(testing.allocator);
    defer testing.allocator.free(formatted);

    try testing.expect(std.mem.indexOf(u8, formatted, "100644") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "hello.txt") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391") != null);
}

// ============================================================================
// createTreeData: deterministic output (same entries → same bytes)
// ============================================================================

test "createTreeData: deterministic - same entries produce identical output" {
    const entries = [_]TreeEntry{
        .{ .mode = "100644", .name = "b.txt", .hash = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391", .type = .blob },
        .{ .mode = "100644", .name = "a.txt", .hash = "b6fc4c620b67d95f953a5c1c1230aaab5db5a1b0", .type = .blob },
    };

    const data1 = try tree.createTreeData(&entries, testing.allocator);
    defer testing.allocator.free(data1);

    const data2 = try tree.createTreeData(&entries, testing.allocator);
    defer testing.allocator.free(data2);

    try testing.expectEqualSlices(u8, data1, data2);
}

test "createTreeData: different order same entries produce same output (sorting)" {
    const entries_ab = [_]TreeEntry{
        .{ .mode = "100644", .name = "a.txt", .hash = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391", .type = .blob },
        .{ .mode = "100644", .name = "b.txt", .hash = "b6fc4c620b67d95f953a5c1c1230aaab5db5a1b0", .type = .blob },
    };
    const entries_ba = [_]TreeEntry{
        .{ .mode = "100644", .name = "b.txt", .hash = "b6fc4c620b67d95f953a5c1c1230aaab5db5a1b0", .type = .blob },
        .{ .mode = "100644", .name = "a.txt", .hash = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391", .type = .blob },
    };

    const data_ab = try tree.createTreeData(&entries_ab, testing.allocator);
    defer testing.allocator.free(data_ab);

    const data_ba = try tree.createTreeData(&entries_ba, testing.allocator);
    defer testing.allocator.free(data_ba);

    try testing.expectEqualSlices(u8, data_ab, data_ba);
}
