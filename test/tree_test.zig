const std = @import("std");
const testing = std.testing;
const tree = @import("../src/git/tree_enhanced.zig");

test "file mode parsing and conversion" {
    // Test string to FileMode conversion
    try testing.expect(try tree.FileMode.fromString("040000") == .directory);
    try testing.expect(try tree.FileMode.fromString("100644") == .regular_file);
    try testing.expect(try tree.FileMode.fromString("100755") == .executable_file);
    try testing.expect(try tree.FileMode.fromString("120000") == .symlink);
    try testing.expect(try tree.FileMode.fromString("160000") == .gitlink);
    
    // Test invalid mode
    try testing.expectError(error.InvalidFileMode, tree.FileMode.fromString("123456"));
    
    // Test FileMode to string conversion
    try testing.expectEqualSlices(u8, tree.FileMode.directory.toString(), "040000");
    try testing.expectEqualSlices(u8, tree.FileMode.regular_file.toString(), "100644");
    try testing.expectEqualSlices(u8, tree.FileMode.executable_file.toString(), "100755");
    try testing.expectEqualSlices(u8, tree.FileMode.symlink.toString(), "120000");
    try testing.expectEqualSlices(u8, tree.FileMode.gitlink.toString(), "160000");
    
    // Test integer conversion
    try testing.expect(tree.FileMode.directory.toInt() == 0o040000);
    try testing.expect(tree.FileMode.regular_file.toInt() == 0o100644);
}

test "tree entry creation and methods" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    const test_hash = [_]u8{0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x12, 0x34, 0x56, 0x78};
    
    // Test regular file entry
    const file_entry = tree.TreeEntry.init(.regular_file, "test.txt", test_hash);
    try testing.expect(file_entry.isFile());
    try testing.expect(!file_entry.isDirectory());
    try testing.expect(!file_entry.isSymlink());
    try testing.expect(!file_entry.isSubmodule());
    
    // Test directory entry
    const dir_entry = tree.TreeEntry.init(.directory, "subdir", test_hash);
    try testing.expect(dir_entry.isDirectory());
    try testing.expect(!dir_entry.isFile());
    
    // Test symlink entry
    const link_entry = tree.TreeEntry.init(.symlink, "link", test_hash);
    try testing.expect(link_entry.isSymlink());
    try testing.expect(!link_entry.isFile()); // symlinks are not regular files
    
    // Test submodule entry
    const submodule_entry = tree.TreeEntry.init(.gitlink, "submodule", test_hash);
    try testing.expect(submodule_entry.isSubmodule());
    
    // Test hash string conversion
    const hash_str = try file_entry.getHashString(allocator);
    try testing.expectEqualSlices(u8, hash_str, "123456789abcdef0123456789abcdef012345678");
}

test "tree parsing from raw data" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    // Create raw tree data (mode name\0hash)
    var data = std.ArrayList(u8).init(allocator);
    defer data.deinit();
    
    // Add a regular file entry
    try data.appendSlice("100644 file.txt\x00");
    const file_hash = [_]u8{0x11} ++ [_]u8{0x22} ** 19;
    try data.appendSlice(&file_hash);
    
    // Add a directory entry  
    try data.appendSlice("040000 subdir\x00");
    const dir_hash = [_]u8{0x33} ++ [_]u8{0x44} ** 19;
    try data.appendSlice(&dir_hash);
    
    var parsed_tree = try tree.GitTree.parseFromData(data.items, allocator);
    defer parsed_tree.deinit();
    
    try testing.expect(parsed_tree.entries.items.len == 2);
    
    // Check file entry
    const file_entry = parsed_tree.entries.items[0];
    try testing.expect(file_entry.mode == .regular_file);
    try testing.expectEqualSlices(u8, file_entry.name, "file.txt");
    try testing.expectEqualSlices(u8, &file_entry.hash, &file_hash);
    
    // Check directory entry (should be sorted second)
    const dir_entry = parsed_tree.entries.items[1];
    try testing.expect(dir_entry.mode == .directory);
    try testing.expectEqualSlices(u8, dir_entry.name, "subdir");
    try testing.expectEqualSlices(u8, &dir_entry.hash, &dir_hash);
}

test "tree serialization" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var test_tree = tree.GitTree.init(allocator);
    defer test_tree.deinit();
    
    const file_hash = [_]u8{0xaa} ++ [_]u8{0xbb} ** 19;
    const dir_hash = [_]u8{0xcc} ++ [_]u8{0xdd} ** 19;
    
    try test_tree.addEntry(.regular_file, "readme.txt", file_hash);
    try test_tree.addEntry(.directory, "docs", dir_hash);
    
    const serialized = try test_tree.serialize(allocator);
    defer allocator.free(serialized);
    
    // Parse it back
    var reparsed = try tree.GitTree.parseFromData(serialized, allocator);
    defer reparsed.deinit();
    
    try testing.expect(reparsed.entries.items.len == 2);
    try testing.expectEqualSlices(u8, reparsed.entries.items[0].name, "docs"); // directories come first in git sort
    try testing.expectEqualSlices(u8, reparsed.entries.items[1].name, "readme.txt");
}

test "tree entry manipulation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var test_tree = tree.GitTree.init(allocator);
    defer test_tree.deinit();
    
    const hash1 = [_]u8{0x11} ++ [_]u8{0x22} ** 19;
    const hash2 = [_]u8{0x33} ++ [_]u8{0x44} ** 19;
    
    // Add entries
    try test_tree.addEntry(.regular_file, "file1.txt", hash1);
    try test_tree.addEntry(.regular_file, "file2.txt", hash2);
    
    try testing.expect(test_tree.entries.items.len == 2);
    
    // Find entry
    const found = test_tree.findEntry("file1.txt");
    try testing.expect(found != null);
    try testing.expectEqualSlices(u8, &found.?.hash, &hash1);
    
    // Try to find non-existent entry
    const not_found = test_tree.findEntry("nonexistent.txt");
    try testing.expect(not_found == null);
    
    // Remove entry
    const removed = test_tree.removeEntry("file1.txt");
    try testing.expect(removed);
    try testing.expect(test_tree.entries.items.len == 1);
    
    // Try to remove non-existent entry
    const not_removed = test_tree.removeEntry("nonexistent.txt");
    try testing.expect(!not_removed);
}

test "tree filtering" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var test_tree = tree.GitTree.init(allocator);
    defer test_tree.deinit();
    
    const hash = [_]u8{0} ** 20;
    
    try test_tree.addEntry(.regular_file, "file.txt", hash);
    try test_tree.addEntry(.directory, "dir", hash);
    try test_tree.addEntry(.symlink, "link", hash);
    try test_tree.addEntry(.gitlink, "submodule", hash);
    
    // Get files
    var files = try test_tree.getFiles(allocator);
    defer files.deinit();
    try testing.expect(files.items.len == 2); // file.txt and link
    
    // Get directories
    var dirs = try test_tree.getDirectories(allocator);
    defer dirs.deinit();
    try testing.expect(dirs.items.len == 1); // dir
}

test "tree formatting" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var test_tree = tree.GitTree.init(allocator);
    defer test_tree.deinit();
    
    const hash = [_]u8{0x12} ++ [_]u8{0x34} ** 19;
    
    try test_tree.addEntry(.regular_file, "readme.txt", hash);
    try test_tree.addEntry(.directory, "src", hash);
    
    const listing = try test_tree.formatListing(allocator);
    defer allocator.free(listing);
    
    // Should contain mode, type, hash, and name
    try testing.expect(std.mem.contains(u8, listing, "040000"));
    try testing.expect(std.mem.contains(u8, listing, "100644"));
    try testing.expect(std.mem.contains(u8, listing, "tree"));
    try testing.expect(std.mem.contains(u8, listing, "blob"));
    try testing.expect(std.mem.contains(u8, listing, "readme.txt"));
    try testing.expect(std.mem.contains(u8, listing, "src"));
}

test "tree diff" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    // Create old tree
    var old_tree = tree.GitTree.init(allocator);
    defer old_tree.deinit();
    
    const old_hash = [_]u8{0xaa} ++ [_]u8{0xbb} ** 19;
    const common_hash = [_]u8{0xcc} ++ [_]u8{0xdd} ** 19;
    const modified_hash_old = [_]u8{0x11} ++ [_]u8{0x22} ** 19;
    
    try old_tree.addEntry(.regular_file, "old_file.txt", old_hash);
    try old_tree.addEntry(.regular_file, "common_file.txt", common_hash);
    try old_tree.addEntry(.regular_file, "modified_file.txt", modified_hash_old);
    
    // Create new tree
    var new_tree = tree.GitTree.init(allocator);
    defer new_tree.deinit();
    
    const new_hash = [_]u8{0xee} ++ [_]u8{0xff} ** 19;
    const modified_hash_new = [_]u8{0x33} ++ [_]u8{0x44} ** 19;
    
    try new_tree.addEntry(.regular_file, "new_file.txt", new_hash);
    try new_tree.addEntry(.regular_file, "common_file.txt", common_hash);
    try new_tree.addEntry(.regular_file, "modified_file.txt", modified_hash_new);
    
    // Compute diff
    var diff = try tree.diffTrees(old_tree, new_tree, allocator);
    defer diff.deinit(allocator);
    
    // Check results
    try testing.expect(diff.added.items.len == 1);
    try testing.expectEqualSlices(u8, diff.added.items[0].name, "new_file.txt");
    
    try testing.expect(diff.deleted.items.len == 1);
    try testing.expectEqualSlices(u8, diff.deleted.items[0].name, "old_file.txt");
    
    try testing.expect(diff.modified.items.len == 1);
    try testing.expectEqualSlices(u8, diff.modified.items[0].old.name, "modified_file.txt");
    try testing.expectEqualSlices(u8, diff.modified.items[0].new.name, "modified_file.txt");
    try testing.expectEqualSlices(u8, &diff.modified.items[0].old.hash, &modified_hash_old);
    try testing.expectEqualSlices(u8, &diff.modified.items[0].new.hash, &modified_hash_new);
}

test "invalid tree data handling" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    // Test truncated data
    const truncated_data = "100644 file.txt\x00"; // Missing hash
    try testing.expectError(error.InvalidTreeFormat, tree.GitTree.parseFromData(truncated_data, allocator));
    
    // Test missing null terminator
    const no_null_data = "100644 file.txt" ++ ([_]u8{0x11} ** 20);
    try testing.expectError(error.InvalidTreeFormat, tree.GitTree.parseFromData(no_null_data, allocator));
    
    // Test invalid mode
    const invalid_mode_data = "999999 file.txt\x00" ++ ([_]u8{0x11} ** 20);
    try testing.expectError(error.InvalidFileMode, tree.GitTree.parseFromData(invalid_mode_data, allocator));
}

test "tree entry sorting" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    
    var test_tree = tree.GitTree.init(allocator);
    defer test_tree.deinit();
    
    const hash = [_]u8{0} ** 20;
    
    // Add entries in non-sorted order
    try test_tree.addEntry(.regular_file, "z_last.txt", hash);
    try test_tree.addEntry(.directory, "a_dir", hash);
    try test_tree.addEntry(.regular_file, "b_middle.txt", hash);
    try test_tree.addEntry(.directory, "z_dir", hash);
    
    // Should be sorted automatically
    try testing.expectEqualSlices(u8, test_tree.entries.items[0].name, "a_dir"); // dirs with / come first
    try testing.expectEqualSlices(u8, test_tree.entries.items[1].name, "b_middle.txt");
    try testing.expectEqualSlices(u8, test_tree.entries.items[2].name, "z_dir");
    try testing.expectEqualSlices(u8, test_tree.entries.items[3].name, "z_last.txt");
}