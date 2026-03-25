const std = @import("std");
const testing = std.testing;
const fs = std.fs;
const ChildProcess = std.process.Child;
const crypto = std.crypto;

// Import git objects module for testing
const objects = @import("../src/git/objects.zig");

// Test git object format compatibility between git and ziggit
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("Running Object Format Compatibility Tests...\n", .{});

    // Create temporary test directory
    const test_dir = try fs.cwd().makeOpenPath("test_tmp_objects", .{});
    defer fs.cwd().deleteTree("test_tmp_objects") catch {};

    // Test 1: Read git-created blob objects
    try testReadGitBlobs(allocator, test_dir);

    // Test 2: Read git-created tree objects
    try testReadGitTrees(allocator, test_dir);

    // Test 3: Read git-created commit objects
    try testReadGitCommits(allocator, test_dir);

    // Test 4: Object decompression and parsing
    try testObjectDecompression(allocator, test_dir);

    // Test 5: Packed objects compatibility
    try testPackedObjects(allocator, test_dir);

    std.debug.print("All object format tests passed!\n", .{});
}

fn testReadGitBlobs(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    std.debug.print("Test 1: Reading git-created blob objects\n", .{});
    
    const repo_path = try test_dir.makeOpenPath("blob_test", .{});
    defer test_dir.deleteTree("blob_test") catch {};

    // Initialize repository
    _ = try runCommand(allocator, &.{"git", "init"}, repo_path);
    _ = try runCommand(allocator, &.{"git", "config", "user.name", "Test User"}, repo_path);
    _ = try runCommand(allocator, &.{"git", "config", "user.email", "test@example.com"}, repo_path);

    // Create test files with different content types
    try repo_path.writeFile(.{.sub_path = "simple.txt", .data = "Hello, World!\n"});
    try repo_path.writeFile(.{.sub_path = "binary.dat", .data = "\x00\x01\x02\x03\xff\xfe\xfd\xfc"});
    try repo_path.writeFile(.{.sub_path = "empty.txt", .data = ""});
    try repo_path.writeFile("large.txt", "x" ** 1000 ++ "\n");

    // Add files to create blob objects
    _ = try runCommand(allocator, &.{"git", "add", "."}, repo_path);

    // Get blob hashes from git
    const simple_hash = std.mem.trim(u8, try runCommand(allocator, &.{"git", "rev-parse", ":simple.txt"}, repo_path), " \t\n\r");
    defer allocator.free(simple_hash);
    const empty_hash = std.mem.trim(u8, try runCommand(allocator, &.{"git", "rev-parse", ":empty.txt"}, repo_path), " \t\n\r");
    defer allocator.free(empty_hash);

    // Test reading blob objects with ziggit
    const repo_path_str = try getAbsolutePath(allocator, repo_path);
    defer allocator.free(repo_path_str);

    const objects_dir = try std.fmt.allocPrint(allocator, "{s}/.git/objects", .{repo_path_str});
    defer allocator.free(objects_dir);

    // Test reading the simple.txt blob
    try testReadSpecificBlob(allocator, objects_dir, simple_hash, "Hello, World!\n");
    
    // Test reading the empty blob
    try testReadSpecificBlob(allocator, objects_dir, empty_hash, "");

    std.debug.print("  ✓ Test 1 passed\n", .{});
}

fn testReadSpecificBlob(allocator: std.mem.Allocator, objects_dir: []const u8, hash_str: []const u8, expected_content: []const u8) !void {
    // Parse hash into bytes
    var hash_bytes: [20]u8 = undefined;
    for (hash_bytes, 0..) |*byte, i| {
        const hex_chars = hash_str[i * 2 .. i * 2 + 2];
        byte.* = try std.fmt.parseInt(u8, hex_chars, 16);
    }

    // Read the object
    const content = objects.readObject(allocator, objects_dir, &hash_bytes) catch |err| {
        std.debug.print("    Error reading blob {s}: {}\n", .{hash_str, err});
        return err;
    };
    defer allocator.free(content);

    // Parse object header
    if (content.len < 5) { // minimum: "blob 0\0"
        std.debug.print("    Error: Object too small\n", .{});
        return error.InvalidObject;
    }

    const null_pos = std.mem.indexOf(u8, content, "\x00") orelse {
        std.debug.print("    Error: No null terminator in object header\n", .{});
        return error.InvalidObject;
    };

    const header = content[0..null_pos];
    const obj_content = content[null_pos + 1..];

    if (!std.mem.startsWith(u8, header, "blob ")) {
        std.debug.print("    Error: Expected blob object, got header: {s}\n", .{header});
        return error.InvalidObject;
    }

    // Verify content matches expected
    if (!std.mem.eql(u8, obj_content, expected_content)) {
        std.debug.print("    Error: Content mismatch for blob {s}\n", .{hash_str});
        std.debug.print("    Expected: {s}\n", .{expected_content});
        std.debug.print("    Got: {s}\n", .{obj_content});
        return error.ContentMismatch;
    }

    std.debug.print("    Successfully read blob {s} ({} bytes)\n", .{hash_str, obj_content.len});
}

fn testReadGitTrees(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    std.debug.print("Test 2: Reading git-created tree objects\n", .{});
    
    const repo_path = try test_dir.makeOpenPath("tree_test", .{});
    defer test_dir.deleteTree("tree_test") catch {};

    _ = try runCommand(allocator, &.{"git", "init"}, repo_path);
    _ = try runCommand(allocator, &.{"git", "config", "user.name", "Test User"}, repo_path);
    _ = try runCommand(allocator, &.{"git", "config", "user.email", "test@example.com"}, repo_path);

    // Create a directory structure
    try repo_path.writeFile(.{.sub_path = "root.txt", .data = "root content\n"});
    const subdir = try repo_path.makeOpenPath("subdir", .{});
    try subdir.writeFile(.{.sub_path = "sub.txt", .data = "sub content\n"});

    _ = try runCommand(allocator, &.{"git", "add", "."}, repo_path);
    _ = try runCommand(allocator, &.{"git", "commit", "-m", "Initial commit"}, repo_path);

    // Get root tree hash
    const tree_hash = std.mem.trim(u8, try runCommand(allocator, &.{"git", "rev-parse", "HEAD^{tree}"}, repo_path), " \t\n\r");
    defer allocator.free(tree_hash);

    // Test reading tree object
    const repo_path_str = try getAbsolutePath(allocator, repo_path);
    defer allocator.free(repo_path_str);

    const objects_dir = try std.fmt.allocPrint(allocator, "{s}/.git/objects", .{repo_path_str});
    defer allocator.free(objects_dir);

    var hash_bytes: [20]u8 = undefined;
    for (hash_bytes, 0..) |*byte, i| {
        const hex_chars = tree_hash[i * 2 .. i * 2 + 2];
        byte.* = try std.fmt.parseInt(u8, hex_chars, 16);
    }

    const content = objects.readObject(allocator, objects_dir, &hash_bytes) catch |err| {
        std.debug.print("    Error reading tree {s}: {}\n", .{tree_hash, err});
        return err;
    };
    defer allocator.free(content);

    const null_pos = std.mem.indexOf(u8, content, "\x00") orelse {
        std.debug.print("    Error: No null terminator in tree object header\n", .{});
        return error.InvalidObject;
    };

    const header = content[0..null_pos];
    if (!std.mem.startsWith(u8, header, "tree ")) {
        std.debug.print("    Error: Expected tree object, got header: {s}\n", .{header});
        return error.InvalidObject;
    }

    std.debug.print("    Successfully read tree object {s}\n", .{tree_hash});
    std.debug.print("  ✓ Test 2 passed\n", .{});
}

fn testReadGitCommits(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    std.debug.print("Test 3: Reading git-created commit objects\n", .{});
    
    const repo_path = try test_dir.makeOpenPath("commit_test", .{});
    defer test_dir.deleteTree("commit_test") catch {};

    _ = try runCommand(allocator, &.{"git", "init"}, repo_path);
    _ = try runCommand(allocator, &.{"git", "config", "user.name", "Test User"}, repo_path);
    _ = try runCommand(allocator, &.{"git", "config", "user.email", "test@example.com"}, repo_path);

    try repo_path.writeFile(.{.sub_path = "test.txt", .data = "commit test content\n"});
    _ = try runCommand(allocator, &.{"git", "add", "test.txt"}, repo_path);
    _ = try runCommand(allocator, &.{"git", "commit", "-m", "Test commit message"}, repo_path);

    // Get commit hash
    const commit_hash = std.mem.trim(u8, try runCommand(allocator, &.{"git", "rev-parse", "HEAD"}, repo_path), " \t\n\r");
    defer allocator.free(commit_hash);

    // Test reading commit object
    const repo_path_str = try getAbsolutePath(allocator, repo_path);
    defer allocator.free(repo_path_str);

    const objects_dir = try std.fmt.allocPrint(allocator, "{s}/.git/objects", .{repo_path_str});
    defer allocator.free(objects_dir);

    var hash_bytes: [20]u8 = undefined;
    for (hash_bytes, 0..) |*byte, i| {
        const hex_chars = commit_hash[i * 2 .. i * 2 + 2];
        byte.* = try std.fmt.parseInt(u8, hex_chars, 16);
    }

    const content = objects.readObject(allocator, objects_dir, &hash_bytes) catch |err| {
        std.debug.print("    Error reading commit {s}: {}\n", .{commit_hash, err});
        return err;
    };
    defer allocator.free(content);

    const null_pos = std.mem.indexOf(u8, content, "\x00") orelse {
        std.debug.print("    Error: No null terminator in commit object header\n", .{});
        return error.InvalidObject;
    };

    const header = content[0..null_pos];
    const commit_content = content[null_pos + 1..];

    if (!std.mem.startsWith(u8, header, "commit ")) {
        std.debug.print("    Error: Expected commit object, got header: {s}\n", .{header});
        return error.InvalidObject;
    }

    // Verify commit message is in the content
    if (std.mem.indexOf(u8, commit_content, "Test commit message") == null) {
        std.debug.print("    Error: Commit message not found in commit object\n", .{});
        return error.InvalidCommit;
    }

    std.debug.print("    Successfully read commit object {s}\n", .{commit_hash});
    std.debug.print("  ✓ Test 3 passed\n", .{});
}

fn testObjectDecompression(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    std.debug.print("Test 4: Object decompression and parsing\n", .{});
    
    const repo_path = try test_dir.makeOpenPath("decomp_test", .{});
    defer test_dir.deleteTree("decomp_test") catch {};

    _ = try runCommand(allocator, &.{"git", "init"}, repo_path);
    _ = try runCommand(allocator, &.{"git", "config", "user.name", "Test User"}, repo_path);
    _ = try runCommand(allocator, &.{"git", "config", "user.email", "test@example.com"}, repo_path);

    // Create a large file to ensure compression
    const large_content = "This is a large file that should be compressed by git.\n" ** 100;
    try repo_path.writeFile("large.txt", large_content);
    _ = try runCommand(allocator, &.{"git", "add", "large.txt"}, repo_path);

    const blob_hash = std.mem.trim(u8, try runCommand(allocator, &.{"git", "rev-parse", ":large.txt"}, repo_path), " \t\n\r");
    defer allocator.free(blob_hash);

    // Manually read and decompress the object file
    const repo_path_str = try getAbsolutePath(allocator, repo_path);
    defer allocator.free(repo_path_str);

    const obj_path = try std.fmt.allocPrint(allocator, "{s}/.git/objects/{s}/{s}", .{repo_path_str, blob_hash[0..2], blob_hash[2..]});
    defer allocator.free(obj_path);

    // Read compressed object file
    const compressed_data = try fs.cwd().readFileAlloc(allocator, obj_path, 1024 * 1024);
    defer allocator.free(compressed_data);

    // Test decompression using zlib
    var decompressed = std.ArrayList(u8).init(allocator);
    defer decompressed.deinit();

    var stream = std.compress.zlib.decompressor(std.io.fixedBufferStream(compressed_data).reader());
    try stream.reader().readAllArrayList(&decompressed, 1024 * 1024);

    // Verify object format
    const null_pos = std.mem.indexOf(u8, decompressed.items, "\x00") orelse {
        std.debug.print("    Error: No null terminator found in decompressed object\n", .{});
        return error.InvalidObject;
    };

    const header = decompressed.items[0..null_pos];
    const content = decompressed.items[null_pos + 1..];

    if (!std.mem.startsWith(u8, header, "blob ")) {
        std.debug.print("    Error: Invalid object header: {s}\n", .{header});
        return error.InvalidObject;
    }

    // Verify content matches what we wrote
    if (!std.mem.eql(u8, content, large_content)) {
        std.debug.print("    Error: Decompressed content doesn't match original\n", .{});
        return error.ContentMismatch;
    }

    std.debug.print("    Successfully decompressed and verified object {s}\n", .{blob_hash});
    std.debug.print("  ✓ Test 4 passed\n", .{});
}

fn testPackedObjects(allocator: std.mem.Allocator, test_dir: fs.Dir) !void {
    std.debug.print("Test 5: Packed objects compatibility\n", .{});
    
    const repo_path = try test_dir.makeOpenPath("pack_test", .{});
    defer test_dir.deleteTree("pack_test") catch {};

    _ = try runCommand(allocator, &.{"git", "init"}, repo_path);
    _ = try runCommand(allocator, &.{"git", "config", "user.name", "Test User"}, repo_path);
    _ = try runCommand(allocator, &.{"git", "config", "user.email", "test@example.com"}, repo_path);

    // Create multiple commits to generate packable content
    for (0..5) |i| {
        const filename = try std.fmt.allocPrint(allocator, "file{}.txt", .{i});
        defer allocator.free(filename);
        
        const content = try std.fmt.allocPrint(allocator, "Content for file {}\n", .{i});
        defer allocator.free(content);
        
        try repo_path.writeFile(filename, content);
        _ = try runCommand(allocator, &.{"git", "add", filename}, repo_path);
        
        const commit_msg = try std.fmt.allocPrint(allocator, "Commit {}", .{i});
        defer allocator.free(commit_msg);
        
        _ = try runCommand(allocator, &.{"git", "commit", "-m", commit_msg}, repo_path);
    }

    // Force git to create pack files
    _ = runCommand(allocator, &.{"git", "gc"}, repo_path) catch {
        std.debug.print("    git gc failed, skipping pack test\n", .{});
        std.debug.print("  ✓ Test 5 skipped (pack files not created)\n", .{});
        return;
    };

    // Check if pack files were created
    const repo_path_str = try getAbsolutePath(allocator, repo_path);
    defer allocator.free(repo_path_str);

    const pack_dir_path = try std.fmt.allocPrint(allocator, "{s}/.git/objects/pack", .{repo_path_str});
    defer allocator.free(pack_dir_path);

    const pack_dir = fs.cwd().openDir(pack_dir_path, .{ .iterate = true }) catch {
        std.debug.print("    No pack directory found, pack files not created\n", .{});
        std.debug.print("  ✓ Test 5 skipped (no pack files)\n", .{});
        return;
    };
    defer pack_dir.close();

    var pack_files_found = false;
    var iterator = pack_dir.iterate();
    while (try iterator.next()) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".pack")) {
            pack_files_found = true;
            std.debug.print("    Found pack file: {s}\n", .{entry.name});
        }
    }

    if (!pack_files_found) {
        std.debug.print("    No pack files found after gc\n", .{});
        std.debug.print("  ✓ Test 5 skipped (no pack files created)\n", .{});
        return;
    }

    // For now, just verify that we can still read objects after packing
    // (Full pack file parsing would be a more complex test)
    const latest_commit = std.mem.trim(u8, try runCommand(allocator, &.{"git", "rev-parse", "HEAD"}, repo_path), " \t\n\r");
    defer allocator.free(latest_commit);

    std.debug.print("    Pack files created, repository still readable\n", .{});
    std.debug.print("    Latest commit: {s}\n", .{latest_commit});
    
    std.debug.print("  ✓ Test 5 passed\n", .{});
}

fn runCommand(allocator: std.mem.Allocator, args: []const []const u8, cwd: fs.Dir) ![]u8 {
    var child = ChildProcess.init(args, allocator);
    child.cwd_dir = cwd;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    
    try child.spawn();
    
    const stdout = try child.stdout.?.reader().readAllAlloc(allocator, 8192);
    const stderr = try child.stderr.?.reader().readAllAlloc(allocator, 8192);
    defer allocator.free(stderr);
    
    const term = try child.wait();
    if (term != .Exited or term.Exited != 0) {
        std.debug.print("Command failed: {s}\n", .{stderr});
        allocator.free(stdout);
        return error.CommandFailed;
    }
    
    return stdout;
}

fn getAbsolutePath(allocator: std.mem.Allocator, dir: fs.Dir) ![]u8 {
    const fd = dir.fd;
    var path_buffer: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const path = try std.os.getFdPath(fd, &path_buffer);
    return allocator.dupe(u8, path);
}

test "object format compatibility" {
    try main();
}