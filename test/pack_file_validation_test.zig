const std = @import("std");
const testing = std.testing;
const objects = @import("../src/git/objects.zig");

// Pack file functionality validation tests
test "git object creation and hash validation" {
    const allocator = testing.allocator;
    
    // Test blob object creation
    const test_data = "Pack file implementation is working correctly!";
    const blob_obj = try objects.createBlobObject(test_data, allocator);
    defer blob_obj.deinit(allocator);
    
    try testing.expect(blob_obj.type == .blob);
    try testing.expectEqualStrings(test_data, blob_obj.data);
    
    // Test hash computation
    const computed_hash = try blob_obj.hash(allocator);
    defer allocator.free(computed_hash);
    
    try testing.expect(computed_hash.len == 40);
    
    // Validate all characters are hex
    for (computed_hash) |c| {
        try testing.expect(std.ascii.isHex(c));
    }
    
    std.debug.print("✅ Git object creation and hash validation passed\n", .{});
}

test "pack file object types validation" {
    // Test ObjectType enum functionality
    try testing.expectEqualStrings("blob", objects.ObjectType.blob.toString());
    try testing.expectEqualStrings("tree", objects.ObjectType.tree.toString());
    try testing.expectEqualStrings("commit", objects.ObjectType.commit.toString());
    try testing.expectEqualStrings("tag", objects.ObjectType.tag.toString());
    
    // Test fromString parsing
    try testing.expect(objects.ObjectType.fromString("blob") == .blob);
    try testing.expect(objects.ObjectType.fromString("tree") == .tree);
    try testing.expect(objects.ObjectType.fromString("commit") == .commit);
    try testing.expect(objects.ObjectType.fromString("tag") == .tag);
    try testing.expect(objects.ObjectType.fromString("invalid") == null);
    
    std.debug.print("✅ Pack file object types validation passed\n", .{});
}

test "tree object creation" {
    const allocator = testing.allocator;
    
    // Create tree entries
    var entries = [_]objects.TreeEntry{
        objects.TreeEntry.init("100644", "file1.txt", "a1b2c3d4e5f6789012345678901234567890abcd"),
        objects.TreeEntry.init("040000", "subdir", "b2c3d4e5f6789012345678901234567890abcdef"),
    };
    
    // Allocate memory for the entries (since init doesn't allocate)
    const entry1_mode = try allocator.dupe(u8, entries[0].mode);
    const entry1_name = try allocator.dupe(u8, entries[0].name);
    const entry1_hash = try allocator.dupe(u8, entries[0].hash);
    const entry2_mode = try allocator.dupe(u8, entries[1].mode);
    const entry2_name = try allocator.dupe(u8, entries[1].name);
    const entry2_hash = try allocator.dupe(u8, entries[1].hash);
    
    entries[0].mode = entry1_mode;
    entries[0].name = entry1_name;
    entries[0].hash = entry1_hash;
    entries[1].mode = entry2_mode;
    entries[1].name = entry2_name;
    entries[1].hash = entry2_hash;
    
    defer {
        for (entries) |entry| {
            entry.deinit(allocator);
        }
    }
    
    // Create tree object
    const tree_obj = try objects.createTreeObject(&entries, allocator);
    defer tree_obj.deinit(allocator);
    
    try testing.expect(tree_obj.type == .tree);
    try testing.expect(tree_obj.data.len > 0);
    
    std.debug.print("✅ Tree object creation validation passed\n", .{});
}

test "commit object creation" {
    const allocator = testing.allocator;
    
    const tree_hash = "a1b2c3d4e5f6789012345678901234567890abcd";
    const parent_hashes = [_][]const u8{"b2c3d4e5f6789012345678901234567890abcdef"};
    const author = "Test Author <test@example.com> 1234567890 +0000";
    const committer = "Test Committer <committer@example.com> 1234567890 +0000";
    const message = "Test commit message";
    
    const commit_obj = try objects.createCommitObject(tree_hash, &parent_hashes, author, committer, message, allocator);
    defer commit_obj.deinit(allocator);
    
    try testing.expect(commit_obj.type == .commit);
    try testing.expect(commit_obj.data.len > 0);
    
    // Verify commit contains expected components
    const commit_content = std.mem.span(commit_obj.data);
    try testing.expect(std.mem.indexOf(u8, commit_content, tree_hash) != null);
    try testing.expect(std.mem.indexOf(u8, commit_content, parent_hashes[0]) != null);
    try testing.expect(std.mem.indexOf(u8, commit_content, message) != null);
    
    std.debug.print("✅ Commit object creation validation passed\n", .{});
}