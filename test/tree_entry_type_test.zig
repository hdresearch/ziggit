// test/tree_entry_type_test.zig
// Tests for tree module: entry types, mode parsing, tree construction.

const std = @import("std");
const tree = @import("tree");
const testing = std.testing;

const TreeEntry = tree.TreeEntry;

// ============================================================================
// EntryType.fromMode
// ============================================================================

test "fromMode: regular file 100644 is blob" {
    try testing.expectEqual(TreeEntry.EntryType.blob, TreeEntry.EntryType.fromMode("100644"));
}

test "fromMode: executable file 100755 is executable" {
    try testing.expectEqual(TreeEntry.EntryType.executable, TreeEntry.EntryType.fromMode("100755"));
}

test "fromMode: directory 040000 is tree" {
    try testing.expectEqual(TreeEntry.EntryType.tree, TreeEntry.EntryType.fromMode("040000"));
}

test "fromMode: symlink 120000 is symlink" {
    try testing.expectEqual(TreeEntry.EntryType.symlink, TreeEntry.EntryType.fromMode("120000"));
}

test "fromMode: unknown mode defaults to blob" {
    try testing.expectEqual(TreeEntry.EntryType.blob, TreeEntry.EntryType.fromMode("999999"));
}

test "fromMode: empty string defaults to blob" {
    try testing.expectEqual(TreeEntry.EntryType.blob, TreeEntry.EntryType.fromMode(""));
}

// ============================================================================
// EntryType.toString
// ============================================================================

test "toString for each type" {
    try testing.expectEqualStrings("blob", TreeEntry.EntryType.blob.toString());
    try testing.expectEqualStrings("tree", TreeEntry.EntryType.tree.toString());
    try testing.expectEqualStrings("symlink", TreeEntry.EntryType.symlink.toString());
    try testing.expectEqualStrings("executable", TreeEntry.EntryType.executable.toString());
}

// ============================================================================
// TreeEntry.init
// ============================================================================

test "TreeEntry.init sets type from mode" {
    const entry = TreeEntry.init("100644", "file.txt", "abc123");
    try testing.expectEqualStrings("100644", entry.mode);
    try testing.expectEqualStrings("file.txt", entry.name);
    try testing.expectEqualStrings("abc123", entry.hash);
    try testing.expectEqual(TreeEntry.EntryType.blob, entry.type);
}

test "TreeEntry.init for directory" {
    const entry = TreeEntry.init("040000", "subdir", "def456");
    try testing.expectEqual(TreeEntry.EntryType.tree, entry.type);
    try testing.expect(entry.isDirectory());
}

test "TreeEntry.init for executable" {
    const entry = TreeEntry.init("100755", "script.sh", "789abc");
    try testing.expectEqual(TreeEntry.EntryType.executable, entry.type);
    try testing.expect(!entry.isDirectory());
}

// ============================================================================
// getObjectType
// ============================================================================

test "getObjectType: blob entry returns .blob" {
    const entry = TreeEntry.init("100644", "file.txt", "aaa");
    const obj_type = entry.getObjectType();
    try testing.expectEqualStrings("blob", obj_type.toString());
}

test "getObjectType: tree entry returns .tree" {
    const entry = TreeEntry.init("040000", "dir", "bbb");
    const obj_type = entry.getObjectType();
    try testing.expectEqualStrings("tree", obj_type.toString());
}

test "getObjectType: executable entry returns .blob" {
    const entry = TreeEntry.init("100755", "run.sh", "ccc");
    const obj_type = entry.getObjectType();
    try testing.expectEqualStrings("blob", obj_type.toString());
}

test "getObjectType: symlink entry returns .blob" {
    const entry = TreeEntry.init("120000", "link", "ddd");
    const obj_type = entry.getObjectType();
    try testing.expectEqualStrings("blob", obj_type.toString());
}

// ============================================================================
// isDirectory
// ============================================================================

test "isDirectory: regular file is not directory" {
    const entry = TreeEntry.init("100644", "file.txt", "aaa");
    try testing.expect(!entry.isDirectory());
}

test "isDirectory: tree entry is directory" {
    const entry = TreeEntry.init("040000", "subdir", "bbb");
    try testing.expect(entry.isDirectory());
}

test "isDirectory: symlink is not directory" {
    const entry = TreeEntry.init("120000", "link", "ccc");
    try testing.expect(!entry.isDirectory());
}
