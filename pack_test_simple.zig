const std = @import("std");
const objects = @import("src/git/objects.zig");
const platform = @import("src/platform/native.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("Testing pack file functionality...\n", .{});

    // Create a test repository to work with
    const test_dir = "test_pack_repo";
    std.fs.cwd().deleteTree(test_dir) catch {};
    
    var child = std.process.Child.init(&.{"git", "init", test_dir}, allocator);
    const term = try child.spawnAndWait();
    if (term != .Exited or term.Exited != 0) {
        std.debug.print("Failed to create test repo\n", .{});
        return;
    }
    
    // Change to the test directory
    const original_cwd = try std.process.getCwdAlloc(allocator);
    defer allocator.free(original_cwd);
    
    try std.process.changeCurDir(test_dir);
    defer std.process.changeCurDir(original_cwd) catch {};

    // Create and commit some files
    try std.fs.cwd().writeFile(.{.sub_path = "test.txt", .data = "Hello, world!\n"});
    
    var add_child = std.process.Child.init(&.{"git", "add", "test.txt"}, allocator);
    _ = try add_child.spawnAndWait();
    
    var commit_child = std.process.Child.init(&.{"git", "commit", "-m", "Initial commit"}, allocator);
    commit_child.env_map = &std.process.EnvMap.init(allocator);
    try commit_child.env_map.?.put("GIT_AUTHOR_NAME", "Test");
    try commit_child.env_map.?.put("GIT_AUTHOR_EMAIL", "test@test.com");
    try commit_child.env_map.?.put("GIT_COMMITTER_NAME", "Test");
    try commit_child.env_map.?.put("GIT_COMMITTER_EMAIL", "test@test.com");
    _ = try commit_child.spawnAndWait();
    
    // Create pack files with git gc
    var gc_child = std.process.Child.init(&.{"git", "gc", "--aggressive"}, allocator);
    _ = try gc_child.spawnAndWait();
    
    // Now try to read an object using our pack file implementation
    std.debug.print("Attempting to read objects from pack files...\n", .{});
    
    // Try to load the blob object
    const blob_content = "Hello, world!\n";
    const blob = try objects.createBlobObject(blob_content, allocator);
    defer blob.deinit(allocator);
    
    const expected_hash = try blob.hash(allocator);
    defer allocator.free(expected_hash);
    
    std.debug.print("Expected hash: {s}\n", .{expected_hash});
    
    // Try to load it using our pack file implementation
    const loaded_obj = objects.GitObject.load(expected_hash, ".git", platform, allocator) catch |err| {
        std.debug.print("Failed to load object: {}\n", .{err});
        return;
    };
    defer loaded_obj.deinit(allocator);
    
    std.debug.print("Successfully loaded object from pack files!\n", .{});
    std.debug.print("Type: {}\n", .{loaded_obj.type});
    std.debug.print("Content: {s}\n", .{loaded_obj.data});
    
    if (std.mem.eql(u8, loaded_obj.data, blob_content)) {
        std.debug.print("✓ Content matches!\n", .{});
    } else {
        std.debug.print("✗ Content doesn't match\n", .{});
    }
}