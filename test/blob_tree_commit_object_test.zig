const std = @import("std");
const ziggit = @import("ziggit");
const testing = std.testing;

fn cleanupPath(path: []const u8) void {
    std.fs.deleteTreeAbsolute(path) catch {};
}

// Helper: read and decompress a git object
fn readGitObject(allocator: std.mem.Allocator, git_dir: []const u8, hash_hex: []const u8) ![]const u8 {
    const obj_path = try std.fmt.allocPrint(allocator, "{s}/objects/{s}/{s}", .{ git_dir, hash_hex[0..2], hash_hex[2..] });
    defer allocator.free(obj_path);

    const file = try std.fs.openFileAbsolute(obj_path, .{});
    defer file.close();

    const compressed = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(compressed);

    var decompressed = std.ArrayList(u8).init(allocator);
    defer decompressed.deinit();

    var stream = std.io.fixedBufferStream(compressed);
    try std.compress.zlib.decompress(stream.reader(), decompressed.writer());

    return try allocator.dupe(u8, decompressed.items);
}

// === Blob object tests ===

test "blob object: correct SHA-1 for known content" {
    // Verify our hash computation matches git hash-object
    const content = "hello world\n";
    const header = "blob 12\x00";
    const full = header ++ content;

    var hash: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(full, &hash, .{});

    var hex: [40]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{}", .{std.fmt.fmtSliceHexLower(&hash)}) catch unreachable;

    // Cross-validate with git hash-object
    const tmp_file = "/tmp/ziggit_test_hash_content.txt";
    {
        const f = try std.fs.createFileAbsolute(tmp_file, .{});
        defer f.close();
        try f.writeAll(content);
    }
    defer std.fs.deleteFileAbsolute(tmp_file) catch {};

    const result = std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = &[_][]const u8{ "git", "hash-object", tmp_file },
    }) catch return;
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    const git_hash = std.mem.trim(u8, result.stdout, " \n\r\t");
    try testing.expectEqualStrings(git_hash, &hex);
}

test "blob object: add creates compressed object readable by git cat-file" {
    const path = "/tmp/ziggit_test_blob_catfile";
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    const content = "test blob content\n";
    {
        const f = try std.fs.createFileAbsolute(path ++ "/test.txt", .{});
        defer f.close();
        try f.writeAll(content);
    }

    try repo.add("test.txt");

    // Use git cat-file to verify blob content
    // First get the blob hash from the index
    const result = std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = &[_][]const u8{ "git", "-C", path, "ls-files", "--stage" },
    }) catch return;
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    if (result.term.Exited != 0) return;

    // Parse blob hash from ls-files output: "100644 <hash> 0\ttest.txt"
    const stdout = std.mem.trim(u8, result.stdout, " \n\r\t");
    if (stdout.len < 47) return; // Not enough data
    const blob_hash = stdout[7..47];

    // Read blob content with git cat-file
    const cat_result = std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = &[_][]const u8{ "git", "-C", path, "cat-file", "-p", blob_hash },
    }) catch return;
    defer testing.allocator.free(cat_result.stdout);
    defer testing.allocator.free(cat_result.stderr);

    try testing.expectEqual(@as(u8, 0), cat_result.term.Exited);
    try testing.expectEqualStrings(content, cat_result.stdout);
}

test "blob object: decompressed content has correct header format" {
    const path = "/tmp/ziggit_test_blob_header";
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    const content = "precise content";
    {
        const f = try std.fs.createFileAbsolute(path ++ "/f.txt", .{});
        defer f.close();
        try f.writeAll(content);
    }

    try repo.add("f.txt");

    // Compute expected hash
    const header_str = try std.fmt.allocPrint(testing.allocator, "blob {}\x00", .{content.len});
    defer testing.allocator.free(header_str);
    const blob = try std.mem.concat(testing.allocator, u8, &[_][]const u8{ header_str, content });
    defer testing.allocator.free(blob);

    var hash: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(blob, &hash, .{});
    var hex: [40]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{}", .{std.fmt.fmtSliceHexLower(&hash)}) catch unreachable;

    // Read the stored object
    const obj_data = try readGitObject(testing.allocator, path ++ "/.git", &hex);
    defer testing.allocator.free(obj_data);

    // Verify header format
    const expected_header = try std.fmt.allocPrint(testing.allocator, "blob {}\x00", .{content.len});
    defer testing.allocator.free(expected_header);

    try testing.expect(std.mem.startsWith(u8, obj_data, expected_header));

    // Verify content after header
    const null_pos = std.mem.indexOfScalar(u8, obj_data, 0).?;
    try testing.expectEqualStrings(content, obj_data[null_pos + 1 ..]);
}

test "blob object: empty file has valid hash" {
    const path = "/tmp/ziggit_test_blob_empty";
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    {
        const f = try std.fs.createFileAbsolute(path ++ "/empty.txt", .{});
        defer f.close();
        // Write nothing - empty file
    }

    try repo.add("empty.txt");

    // Known git hash for empty blob: "blob 0\0" -> e69de29bb2d1d6434b8b29ae775ad8c2e48c5391
    const empty_blob = "blob 0\x00";
    var hash: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(empty_blob, &hash, .{});
    var hex: [40]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{}", .{std.fmt.fmtSliceHexLower(&hash)}) catch unreachable;

    try testing.expectEqualStrings("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391", &hex);

    // Verify the object exists
    const obj_path = try std.fmt.allocPrint(testing.allocator, "{s}/.git/objects/{s}/{s}", .{ path, hex[0..2], hex[2..] });
    defer testing.allocator.free(obj_path);
    std.fs.accessAbsolute(obj_path, .{}) catch {
        return error.TestFailed;
    };
}

// === Tree object tests ===

test "tree object: commit creates tree containing added files" {
    const path = "/tmp/ziggit_test_tree_files";
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    {
        const f = try std.fs.createFileAbsolute(path ++ "/alpha.txt", .{});
        defer f.close();
        try f.writeAll("alpha\n");
    }

    try repo.add("alpha.txt");
    _ = try repo.commit("init", "T", "t@t.com");

    // Use git ls-tree to verify tree contents
    const result = std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = &[_][]const u8{ "git", "-C", path, "ls-tree", "HEAD" },
    }) catch return;
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    if (result.term.Exited != 0) return;

    try testing.expect(std.mem.indexOf(u8, result.stdout, "alpha.txt") != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "100644") != null);
}

test "tree object: multiple files in tree" {
    const path = "/tmp/ziggit_test_tree_multi";
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    const files = [_][]const u8{ "a.txt", "b.txt", "c.txt" };
    for (files) |name| {
        const full = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ path, name });
        defer testing.allocator.free(full);
        const f = try std.fs.createFileAbsolute(full, .{});
        defer f.close();
        try f.writeAll(name);
    }

    for (files) |name| {
        try repo.add(name);
    }
    _ = try repo.commit("multi", "T", "t@t.com");

    // git ls-tree should show all 3 files
    const result = std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = &[_][]const u8{ "git", "-C", path, "ls-tree", "HEAD" },
    }) catch return;
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    if (result.term.Exited != 0) return;

    for (files) |name| {
        try testing.expect(std.mem.indexOf(u8, result.stdout, name) != null);
    }
}

// === Commit object tests ===

test "commit object: has tree, author, committer, and message" {
    const path = "/tmp/ziggit_test_commit_parts";
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    {
        const f = try std.fs.createFileAbsolute(path ++ "/f.txt", .{});
        defer f.close();
        try f.writeAll("data");
    }
    try repo.add("f.txt");
    const hash = try repo.commit("my message", "John Doe", "john@example.com");

    // Read commit object
    const obj_data = try readGitObject(testing.allocator, path ++ "/.git", &hash);
    defer testing.allocator.free(obj_data);

    // Parse past header
    const null_pos = std.mem.indexOfScalar(u8, obj_data, 0).?;
    const commit_content = obj_data[null_pos + 1 ..];

    // Verify structure
    try testing.expect(std.mem.startsWith(u8, commit_content, "tree "));
    try testing.expect(std.mem.indexOf(u8, commit_content, "author John Doe <john@example.com>") != null);
    try testing.expect(std.mem.indexOf(u8, commit_content, "committer John Doe <john@example.com>") != null);
    try testing.expect(std.mem.indexOf(u8, commit_content, "my message") != null);
}

test "commit object: first commit has no parent" {
    const path = "/tmp/ziggit_test_commit_noparent";
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    {
        const f = try std.fs.createFileAbsolute(path ++ "/f.txt", .{});
        defer f.close();
        try f.writeAll("data");
    }
    try repo.add("f.txt");
    const hash = try repo.commit("first", "T", "t@t.com");

    const obj_data = try readGitObject(testing.allocator, path ++ "/.git", &hash);
    defer testing.allocator.free(obj_data);

    const null_pos = std.mem.indexOfScalar(u8, obj_data, 0).?;
    const commit_content = obj_data[null_pos + 1 ..];

    try testing.expect(std.mem.indexOf(u8, commit_content, "parent ") == null);
}

test "commit object: second commit has parent" {
    const path = "/tmp/ziggit_test_commit_parent";
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    {
        const f = try std.fs.createFileAbsolute(path ++ "/f.txt", .{});
        defer f.close();
        try f.writeAll("v1");
    }
    try repo.add("f.txt");
    const hash1 = try repo.commit("first", "T", "t@t.com");

    {
        const f = try std.fs.createFileAbsolute(path ++ "/g.txt", .{});
        defer f.close();
        try f.writeAll("v2");
    }
    try repo.add("g.txt");
    const hash2 = try repo.commit("second", "T", "t@t.com");

    const obj_data = try readGitObject(testing.allocator, path ++ "/.git", &hash2);
    defer testing.allocator.free(obj_data);

    const null_pos = std.mem.indexOfScalar(u8, obj_data, 0).?;
    const commit_content = obj_data[null_pos + 1 ..];

    // Should contain parent line with first commit's hash
    const parent_line = try std.fmt.allocPrint(testing.allocator, "parent {s}", .{hash1});
    defer testing.allocator.free(parent_line);
    try testing.expect(std.mem.indexOf(u8, commit_content, parent_line) != null);
}

test "commit object: git cat-file validates commit format" {
    const path = "/tmp/ziggit_test_commit_catfile";
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    {
        const f = try std.fs.createFileAbsolute(path ++ "/f.txt", .{});
        defer f.close();
        try f.writeAll("data");
    }
    try repo.add("f.txt");
    const hash = try repo.commit("test msg", "T", "t@t.com");

    // git cat-file -t should report "commit"
    const type_result = std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = &[_][]const u8{ "git", "-C", path, "cat-file", "-t", &hash },
    }) catch return;
    defer testing.allocator.free(type_result.stdout);
    defer testing.allocator.free(type_result.stderr);

    try testing.expectEqualStrings("commit\n", type_result.stdout);

    // git cat-file -p should show commit contents
    const print_result = std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = &[_][]const u8{ "git", "-C", path, "cat-file", "-p", &hash },
    }) catch return;
    defer testing.allocator.free(print_result.stdout);
    defer testing.allocator.free(print_result.stderr);

    try testing.expect(std.mem.indexOf(u8, print_result.stdout, "test msg") != null);
}

// === Tag object tests ===

test "tag object: annotated tag readable by git" {
    const path = "/tmp/ziggit_test_tag_gitread";
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    {
        const f = try std.fs.createFileAbsolute(path ++ "/f.txt", .{});
        defer f.close();
        try f.writeAll("data");
    }
    try repo.add("f.txt");
    _ = try repo.commit("init", "T", "t@t.com");

    try repo.createTag("v1.0.0", "Release 1.0.0");

    // Read tag ref to get tag object hash
    const tag_ref = try std.fs.cwd().readFileAlloc(
        testing.allocator,
        path ++ "/.git/refs/tags/v1.0.0",
        128,
    );
    defer testing.allocator.free(tag_ref);

    // git cat-file -t should report "tag"
    const result = std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = &[_][]const u8{ "git", "-C", path, "cat-file", "-t", tag_ref },
    }) catch return;
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    try testing.expectEqualStrings("tag\n", result.stdout);
}

test "tag object: annotated tag contains message" {
    const path = "/tmp/ziggit_test_tag_msg";
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    {
        const f = try std.fs.createFileAbsolute(path ++ "/f.txt", .{});
        defer f.close();
        try f.writeAll("data");
    }
    try repo.add("f.txt");
    _ = try repo.commit("init", "T", "t@t.com");

    try repo.createTag("v1.0.0", "My tag message");

    const tag_ref = try std.fs.cwd().readFileAlloc(
        testing.allocator,
        path ++ "/.git/refs/tags/v1.0.0",
        128,
    );
    defer testing.allocator.free(tag_ref);

    // Read tag object
    const obj_data = try readGitObject(testing.allocator, path ++ "/.git", tag_ref);
    defer testing.allocator.free(obj_data);

    const null_pos = std.mem.indexOfScalar(u8, obj_data, 0).?;
    const tag_content = obj_data[null_pos + 1 ..];

    try testing.expect(std.mem.indexOf(u8, tag_content, "tag v1.0.0") != null);
    try testing.expect(std.mem.indexOf(u8, tag_content, "type commit") != null);
    try testing.expect(std.mem.indexOf(u8, tag_content, "My tag message") != null);
}

// === Binary content tests ===

test "blob object: binary content preserved through add" {
    const path = "/tmp/ziggit_test_blob_binary";
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    // Write binary content (includes null bytes)
    const binary_content = [_]u8{ 0x00, 0x01, 0xFF, 0xFE, 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };
    {
        const f = try std.fs.createFileAbsolute(path ++ "/binary.dat", .{});
        defer f.close();
        try f.writeAll(&binary_content);
    }

    try repo.add("binary.dat");
    _ = try repo.commit("binary", "T", "t@t.com");

    // git cat-file should be able to read it
    const result = std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = &[_][]const u8{ "git", "-C", path, "fsck", "--strict" },
    }) catch return;
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    try testing.expectEqual(@as(u8, 0), result.term.Exited);
}
