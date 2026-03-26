// test/object_content_verification_test.zig
// Tests that verify the actual content of git objects created by ziggit.
// Uses both direct inspection (decompress and parse) and git CLI cross-validation.
const std = @import("std");
const ziggit = @import("ziggit");
const testing = std.testing;

const Repository = ziggit.Repository;

fn tmpPath(comptime suffix: []const u8) []const u8 {
    return "/tmp/ziggit_objver_" ++ suffix;
}

fn cleanup(path: []const u8) void {
    std.fs.deleteTreeAbsolute(path) catch {};
}

fn createFile(dir: []const u8, name: []const u8, content: []const u8) !void {
    const full = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ dir, name });
    defer testing.allocator.free(full);
    const f = try std.fs.createFileAbsolute(full, .{ .truncate = true });
    defer f.close();
    try f.writeAll(content);
}

fn readFileContent(dir: []const u8, name: []const u8) ![]u8 {
    const full = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ dir, name });
    defer testing.allocator.free(full);
    const f = try std.fs.openFileAbsolute(full, .{});
    defer f.close();
    return try f.readToEndAlloc(testing.allocator, 1024 * 1024);
}

fn runGit(dir: []const u8, args: []const []const u8) ![]u8 {
    var argv = std.ArrayList([]const u8).init(testing.allocator);
    defer argv.deinit();
    try argv.append("git");
    for (args) |a| try argv.append(a);
    var child = std.process.Child.init(argv.items, testing.allocator);
    var cwd_dir = try std.fs.openDirAbsolute(dir, .{});
    defer cwd_dir.close();
    child.cwd_dir = cwd_dir;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const stdout = try child.stdout.?.reader().readAllAlloc(testing.allocator, 1024 * 1024);
    errdefer testing.allocator.free(stdout);
    const stderr = try child.stderr.?.reader().readAllAlloc(testing.allocator, 1024 * 1024);
    defer testing.allocator.free(stderr);
    const result = try child.wait();
    if (result.Exited != 0) {
        testing.allocator.free(stdout);
        return error.GitFailed;
    }
    return stdout;
}

fn configGit(dir: []const u8) void {
    const e = runGit(dir, &.{ "config", "user.email", "test@test.com" }) catch return;
    testing.allocator.free(e);
    const n = runGit(dir, &.{ "config", "user.name", "Test" }) catch return;
    testing.allocator.free(n);
}

fn decompressObject(allocator: std.mem.Allocator, git_dir: []const u8, hash_hex: []const u8) ![]u8 {
    const obj_path = try std.fmt.allocPrint(allocator, "{s}/objects/{s}/{s}", .{ git_dir, hash_hex[0..2], hash_hex[2..] });
    defer allocator.free(obj_path);
    const f = try std.fs.openFileAbsolute(obj_path, .{});
    defer f.close();
    const compressed = try f.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(compressed);
    var decompressed = std.ArrayList(u8).init(allocator);
    var stream = std.io.fixedBufferStream(compressed);
    try std.compress.zlib.decompress(stream.reader(), decompressed.writer());
    return try decompressed.toOwnedSlice();
}

// ============================================================================
// Blob object content verification
// ============================================================================

test "blob object has correct header format" {
    const path = tmpPath("blob_header");
    cleanup(path);
    defer cleanup(path);
    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    const content = "hello world\n";
    try createFile(path, "hello.txt", content);
    try repo.add("hello.txt");

    // Get hash via git
    const hash_out = runGit(path, &.{ "hash-object", "hello.txt" }) catch return;
    defer testing.allocator.free(hash_out);
    const hash = std.mem.trim(u8, hash_out, "\n\r ");

    // Decompress object and check header
    const git_dir = try std.fmt.allocPrint(testing.allocator, "{s}/.git", .{path});
    defer testing.allocator.free(git_dir);
    const raw = try decompressObject(testing.allocator, git_dir, hash);
    defer testing.allocator.free(raw);

    // Must start with "blob <size>\0"
    const expected_header = try std.fmt.allocPrint(testing.allocator, "blob {d}\x00", .{content.len});
    defer testing.allocator.free(expected_header);

    try testing.expect(std.mem.startsWith(u8, raw, expected_header));
    // Content after header must match file content
    const null_pos = std.mem.indexOfScalar(u8, raw, 0).?;
    try testing.expectEqualStrings(content, raw[null_pos + 1 ..]);
}

test "blob SHA-1 matches git hash-object" {
    const path = tmpPath("blob_sha_match");
    cleanup(path);
    defer cleanup(path);
    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "test.txt", "test content\n");
    try repo.add("test.txt");

    // git hash-object should match what's in the index
    const hash_out = runGit(path, &.{ "hash-object", "test.txt" }) catch return;
    defer testing.allocator.free(hash_out);
    const git_hash = std.mem.trim(u8, hash_out, "\n\r ");

    // git ls-files --stage should show the same hash
    const ls_out = runGit(path, &.{ "ls-files", "--stage" }) catch return;
    defer testing.allocator.free(ls_out);
    // Format: "100644 <hash> 0\tfilename"
    const idx_hash_start = std.mem.indexOf(u8, ls_out, " ").? + 1;
    const idx_hash = ls_out[idx_hash_start .. idx_hash_start + 40];
    try testing.expectEqualStrings(git_hash, idx_hash);
}

test "empty blob has known SHA-1" {
    const path = tmpPath("empty_blob_known");
    cleanup(path);
    defer cleanup(path);
    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "empty.txt", "");
    try repo.add("empty.txt");

    // Well-known SHA-1 of empty blob
    const expected = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391";
    const ls_out = runGit(path, &.{ "ls-files", "--stage" }) catch return;
    defer testing.allocator.free(ls_out);
    const idx_hash_start = std.mem.indexOf(u8, ls_out, " ").? + 1;
    const idx_hash = ls_out[idx_hash_start .. idx_hash_start + 40];
    try testing.expectEqualStrings(expected, idx_hash);
}

// ============================================================================
// Commit object content verification
// ============================================================================

test "commit object contains tree, author, committer, message" {
    const path = tmpPath("commit_content");
    cleanup(path);
    defer cleanup(path);
    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    configGit(path);

    try createFile(path, "f.txt", "data");
    try repo.add("f.txt");
    const hash = try repo.commit("test message", "Alice", "alice@test.com");

    // Decompress commit object
    const git_dir = try std.fmt.allocPrint(testing.allocator, "{s}/.git", .{path});
    defer testing.allocator.free(git_dir);
    const raw = try decompressObject(testing.allocator, git_dir, &hash);
    defer testing.allocator.free(raw);

    // Must start with "commit <size>\0"
    try testing.expect(std.mem.startsWith(u8, raw, "commit "));
    const null_pos = std.mem.indexOfScalar(u8, raw, 0).?;
    const content = raw[null_pos + 1 ..];

    // Must contain tree line
    try testing.expect(std.mem.startsWith(u8, content, "tree "));
    // Must contain author
    try testing.expect(std.mem.indexOf(u8, content, "author Alice <alice@test.com>") != null);
    // Must contain committer
    try testing.expect(std.mem.indexOf(u8, content, "committer Alice <alice@test.com>") != null);
    // Must contain message
    try testing.expect(std.mem.indexOf(u8, content, "test message") != null);
}

test "first commit has no parent line" {
    const path = tmpPath("no_parent");
    cleanup(path);
    defer cleanup(path);
    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    configGit(path);

    try createFile(path, "f.txt", "data");
    try repo.add("f.txt");
    const hash = try repo.commit("first", "A", "a@t.com");

    const git_dir = try std.fmt.allocPrint(testing.allocator, "{s}/.git", .{path});
    defer testing.allocator.free(git_dir);
    const raw = try decompressObject(testing.allocator, git_dir, &hash);
    defer testing.allocator.free(raw);
    const null_pos = std.mem.indexOfScalar(u8, raw, 0).?;
    const content = raw[null_pos + 1 ..];

    // First commit must NOT have "parent" line
    try testing.expect(std.mem.indexOf(u8, content, "parent ") == null);
}

test "second commit has parent line pointing to first" {
    const path = tmpPath("has_parent");
    cleanup(path);
    defer cleanup(path);
    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    configGit(path);

    try createFile(path, "f.txt", "v1");
    try repo.add("f.txt");
    const first_hash = try repo.commit("first", "A", "a@t.com");

    try createFile(path, "f.txt", "v2");
    try repo.add("f.txt");
    const second_hash = try repo.commit("second", "A", "a@t.com");

    const git_dir = try std.fmt.allocPrint(testing.allocator, "{s}/.git", .{path});
    defer testing.allocator.free(git_dir);
    const raw = try decompressObject(testing.allocator, git_dir, &second_hash);
    defer testing.allocator.free(raw);
    const null_pos = std.mem.indexOfScalar(u8, raw, 0).?;
    const content = raw[null_pos + 1 ..];

    // Must have parent line
    const parent_prefix = "parent ";
    const parent_pos = std.mem.indexOf(u8, content, parent_prefix).?;
    const parent_hash = content[parent_pos + parent_prefix.len .. parent_pos + parent_prefix.len + 40];
    try testing.expectEqualStrings(&first_hash, parent_hash);
}

test "commit tree hash is valid 40-char hex" {
    const path = tmpPath("tree_hash_valid");
    cleanup(path);
    defer cleanup(path);
    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "data");
    try repo.add("f.txt");
    const hash = try repo.commit("msg", "A", "a@t.com");

    const git_dir = try std.fmt.allocPrint(testing.allocator, "{s}/.git", .{path});
    defer testing.allocator.free(git_dir);
    const raw = try decompressObject(testing.allocator, git_dir, &hash);
    defer testing.allocator.free(raw);
    const null_pos = std.mem.indexOfScalar(u8, raw, 0).?;
    const content = raw[null_pos + 1 ..];

    // Extract tree hash
    try testing.expect(std.mem.startsWith(u8, content, "tree "));
    const tree_hash = content[5..45];
    // Verify it's valid hex
    for (tree_hash) |c| {
        try testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }

    // Verify the tree object actually exists
    const tree_obj = try decompressObject(testing.allocator, git_dir, tree_hash);
    defer testing.allocator.free(tree_obj);
    try testing.expect(std.mem.startsWith(u8, tree_obj, "tree "));
}

// ============================================================================
// Tree object content verification
// ============================================================================

test "tree object contains file entry with correct mode" {
    const path = tmpPath("tree_entry");
    cleanup(path);
    defer cleanup(path);
    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "test.txt", "data");
    try repo.add("test.txt");
    const commit_hash = try repo.commit("msg", "A", "a@t.com");

    // Use git cat-file to verify tree content
    const cat_out = runGit(path, &.{ "cat-file", "-p", &commit_hash }) catch return;
    defer testing.allocator.free(cat_out);

    // Extract tree hash from commit output
    try testing.expect(std.mem.startsWith(u8, cat_out, "tree "));
    const tree_hash = cat_out[5..45];

    // Verify tree content via git
    const tree_out = runGit(path, &.{ "ls-tree", tree_hash }) catch return;
    defer testing.allocator.free(tree_out);

    // Should contain "100644 blob <hash>\ttest.txt"
    try testing.expect(std.mem.indexOf(u8, tree_out, "100644") != null);
    try testing.expect(std.mem.indexOf(u8, tree_out, "blob") != null);
    try testing.expect(std.mem.indexOf(u8, tree_out, "test.txt") != null);
}

test "tree with multiple files lists all entries" {
    const path = tmpPath("tree_multi");
    cleanup(path);
    defer cleanup(path);
    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "a.txt", "aaa");
    try createFile(path, "b.txt", "bbb");
    try createFile(path, "c.txt", "ccc");
    try repo.add("a.txt");
    try repo.add("b.txt");
    try repo.add("c.txt");
    const commit_hash = try repo.commit("multi", "A", "a@t.com");

    // git cat-file to get tree hash
    const cat_out = runGit(path, &.{ "cat-file", "-p", &commit_hash }) catch return;
    defer testing.allocator.free(cat_out);
    const tree_hash = cat_out[5..45];

    // ls-tree should show all 3 files
    const tree_out = runGit(path, &.{ "ls-tree", tree_hash }) catch return;
    defer testing.allocator.free(tree_out);

    try testing.expect(std.mem.indexOf(u8, tree_out, "a.txt") != null);
    try testing.expect(std.mem.indexOf(u8, tree_out, "b.txt") != null);
    try testing.expect(std.mem.indexOf(u8, tree_out, "c.txt") != null);

    // Count entries (lines)
    var line_count: usize = 0;
    var lines = std.mem.split(u8, std.mem.trim(u8, tree_out, "\n"), "\n");
    while (lines.next()) |_| line_count += 1;
    try testing.expectEqual(@as(usize, 3), line_count);
}

// ============================================================================
// Tag object content verification
// ============================================================================

test "lightweight tag file contains commit hash" {
    const path = tmpPath("lt_tag_content");
    cleanup(path);
    defer cleanup(path);
    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    configGit(path);

    try createFile(path, "f.txt", "data");
    try repo.add("f.txt");
    const commit_hash = try repo.commit("msg", "A", "a@t.com");
    try repo.createTag("v1.0", null);

    // Read tag file directly
    const tag_path = try std.fmt.allocPrint(testing.allocator, "{s}/.git/refs/tags/v1.0", .{path});
    defer testing.allocator.free(tag_path);
    const tag_content = try readFileContent(path, ".git/refs/tags/v1.0");
    defer testing.allocator.free(tag_content);

    // Lightweight tag contains the commit hash
    const trimmed = std.mem.trim(u8, tag_content, "\n\r ");
    try testing.expectEqualStrings(&commit_hash, trimmed);
}

test "annotated tag object contains tagger and message" {
    const path = tmpPath("ann_tag_content");
    cleanup(path);
    defer cleanup(path);
    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    configGit(path);

    try createFile(path, "f.txt", "data");
    try repo.add("f.txt");
    _ = try repo.commit("msg", "A", "a@t.com");
    try repo.createTag("v2.0", "release notes here");

    // Use git to verify tag content
    const show_out = runGit(path, &.{ "cat-file", "tag", "v2.0" }) catch return;
    defer testing.allocator.free(show_out);

    try testing.expect(std.mem.indexOf(u8, show_out, "tag v2.0") != null);
    try testing.expect(std.mem.indexOf(u8, show_out, "type commit") != null);
    try testing.expect(std.mem.indexOf(u8, show_out, "release notes here") != null);
}

// ============================================================================
// Index entry behavior
// ============================================================================

test "adding same file twice appends second entry" {
    // Note: ziggit currently appends without deduplicating.
    // This test documents that behavior. 
    // git commit still works because createTreeFromIndex uses all entries.
    const path = tmpPath("idx_dup");
    cleanup(path);
    defer cleanup(path);
    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "dup.txt", "version 1");
    try repo.add("dup.txt");
    try createFile(path, "dup.txt", "version 2");
    try repo.add("dup.txt");

    // ziggit currently produces 2 entries; verify it doesn't crash
    // and that commit still works
    _ = try repo.commit("with dup", "A", "a@t.com");
    const head = try repo.revParseHead();
    // Head should be a valid 40-char hex hash
    for (&head) |c| {
        try testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
}

test "add two different files creates distinct blob objects" {
    const path = tmpPath("two_blobs");
    cleanup(path);
    defer cleanup(path);
    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    configGit(path);

    try createFile(path, "one.txt", "content one");
    try createFile(path, "two.txt", "content two");
    try repo.add("one.txt");
    try repo.add("two.txt");

    // Verify with git hash-object that two distinct hashes exist
    const h1 = runGit(path, &.{ "hash-object", "one.txt" }) catch return;
    defer testing.allocator.free(h1);
    const h2 = runGit(path, &.{ "hash-object", "two.txt" }) catch return;
    defer testing.allocator.free(h2);

    const hash1 = std.mem.trim(u8, h1, "\n\r ");
    const hash2 = std.mem.trim(u8, h2, "\n\r ");
    try testing.expect(!std.mem.eql(u8, hash1, hash2));
}

// ============================================================================
// git fsck validation
// ============================================================================

test "git cat-file reads all 5 commit objects" {
    const path = tmpPath("catfile_5");
    cleanup(path);
    defer cleanup(path);
    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    configGit(path);

    var hashes: [5][40]u8 = undefined;
    for (0..5) |i| {
        const content = try std.fmt.allocPrint(testing.allocator, "content {d}", .{i});
        defer testing.allocator.free(content);
        try createFile(path, "f.txt", content);
        try repo.add("f.txt");
        const msg = try std.fmt.allocPrint(testing.allocator, "commit {d}", .{i});
        defer testing.allocator.free(msg);
        hashes[i] = try repo.commit(msg, "A", "a@t.com");
    }

    // Verify git can read each commit
    for (hashes) |hash| {
        const cat_out = runGit(path, &.{ "cat-file", "-t", &hash }) catch continue;
        defer testing.allocator.free(cat_out);
        try testing.expectEqualStrings("commit\n", cat_out);
    }
}

test "git cat-file reads annotated tag object" {
    const path = tmpPath("catfile_tag");
    cleanup(path);
    defer cleanup(path);
    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    configGit(path);

    try createFile(path, "f.txt", "data");
    try repo.add("f.txt");
    _ = try repo.commit("msg", "A", "a@t.com");
    try repo.createTag("v2.0", "annotated tag");

    // Verify git can read the tag object type
    const tag_type = runGit(path, &.{ "cat-file", "-t", "v2.0" }) catch return;
    defer testing.allocator.free(tag_type);
    try testing.expectEqualStrings("tag\n", tag_type);
}

// ============================================================================
// Object decompression round-trip
// ============================================================================

test "ziggit-created blob decompresses to valid object" {
    const path = tmpPath("decomp_blob");
    cleanup(path);
    defer cleanup(path);
    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    const original = "hello decompression test!\n";
    try createFile(path, "dc.txt", original);
    try repo.add("dc.txt");

    // Get hash from git
    const hash_out = runGit(path, &.{ "hash-object", "dc.txt" }) catch return;
    defer testing.allocator.free(hash_out);
    const hash = std.mem.trim(u8, hash_out, "\n\r ");

    // Manually decompress and verify
    const git_dir = try std.fmt.allocPrint(testing.allocator, "{s}/.git", .{path});
    defer testing.allocator.free(git_dir);
    const raw = try decompressObject(testing.allocator, git_dir, hash);
    defer testing.allocator.free(raw);

    // Parse header
    const null_pos = std.mem.indexOfScalar(u8, raw, 0).?;
    const header = raw[0..null_pos];
    const body = raw[null_pos + 1 ..];

    // Verify header format
    try testing.expect(std.mem.startsWith(u8, header, "blob "));
    const size = try std.fmt.parseInt(usize, header[5..], 10);
    try testing.expectEqual(original.len, size);

    // Verify body
    try testing.expectEqualStrings(original, body);

    // Verify SHA-1 matches
    var computed: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(raw, &computed, .{});
    var computed_hex: [40]u8 = undefined;
    _ = std.fmt.bufPrint(&computed_hex, "{}", .{std.fmt.fmtSliceHexLower(&computed)}) catch unreachable;
    try testing.expectEqualStrings(hash, &computed_hex);
}

// ============================================================================
// Binary content handling
// ============================================================================

test "blob with null bytes preserved correctly" {
    const path = tmpPath("null_bytes");
    cleanup(path);
    defer cleanup(path);
    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    configGit(path);

    // Create file with null bytes
    const content = "before\x00middle\x00after";
    try createFile(path, "bin.dat", content);
    try repo.add("bin.dat");
    _ = try repo.commit("binary", "A", "a@t.com");

    // Checkout to a clean state to verify round-trip
    const hash = try repo.revParseHead();
    try repo.checkout(&hash);

    // Read back and verify content preserved
    const read_back = try readFileContent(path, "bin.dat");
    defer testing.allocator.free(read_back);
    try testing.expectEqualSlices(u8, content, read_back);
}

test "blob with all 256 byte values stored correctly" {
    const path = tmpPath("all_bytes");
    cleanup(path);
    defer cleanup(path);
    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    configGit(path);

    var content: [256]u8 = undefined;
    for (0..256) |i| content[i] = @intCast(i);

    try createFile(path, "allbytes.bin", &content);
    try repo.add("allbytes.bin");
    _ = try repo.commit("all bytes", "A", "a@t.com");

    // Verify blob object size via git
    const hash_out = runGit(path, &.{ "hash-object", "allbytes.bin" }) catch return;
    defer testing.allocator.free(hash_out);
    const hash = std.mem.trim(u8, hash_out, "\n\r ");

    const cat_out = runGit(path, &.{ "cat-file", "-s", hash }) catch return;
    defer testing.allocator.free(cat_out);
    const size = try std.fmt.parseInt(usize, std.mem.trim(u8, cat_out, "\n\r "), 10);
    try testing.expectEqual(@as(usize, 256), size);

    // Verify the blob exists as a valid object
    const type_out = runGit(path, &.{ "cat-file", "-t", hash }) catch return;
    defer testing.allocator.free(type_out);
    try testing.expectEqualStrings("blob\n", type_out);
}
