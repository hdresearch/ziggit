// test/object_integrity_test.zig - Tests that ziggit creates correct git objects
// Verifies object hashing, compression, format, and cross-compatibility with git CLI
const std = @import("std");
const ziggit = @import("ziggit");
const testing = std.testing;

const Repository = ziggit.Repository;

// ============================================================================
// Helpers
// ============================================================================

fn tmpPath(comptime suffix: []const u8) []const u8 {
    return "/tmp/ziggit_obj_test_" ++ suffix;
}

fn cleanup(path: []const u8) void {
    std.fs.deleteTreeAbsolute(path) catch {};
}

fn createFile(repo_path: []const u8, name: []const u8, content: []const u8) !void {
    const full = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ repo_path, name });
    defer testing.allocator.free(full);
    const f = try std.fs.createFileAbsolute(full, .{ .truncate = true });
    defer f.close();
    try f.writeAll(content);
}

fn createDirs(repo_path: []const u8, dirs: []const []const u8) !void {
    for (dirs) |d| {
        const full = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ repo_path, d });
        defer testing.allocator.free(full);
        std.fs.makeDirAbsolute(full) catch {};
    }
}

fn runGit(args: []const []const u8, cwd: []const u8) ![]u8 {
    var child = std.process.Child.init(args, testing.allocator);
    var cwd_dir = try std.fs.openDirAbsolute(cwd, .{});
    defer cwd_dir.close();
    child.cwd_dir = cwd_dir;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const stdout = try child.stdout.?.reader().readAllAlloc(testing.allocator, 64 * 1024);
    errdefer testing.allocator.free(stdout);
    const stderr = try child.stderr.?.reader().readAllAlloc(testing.allocator, 64 * 1024);
    defer testing.allocator.free(stderr);
    const term = try child.wait();
    switch (term) {
        .Exited => |code| if (code != 0) {
            testing.allocator.free(stdout);
            return error.CommandFailed;
        },
        else => {
            testing.allocator.free(stdout);
            return error.CommandFailed;
        },
    }
    return stdout;
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \n\r\t");
}

fn readObject(git_dir: []const u8, hash_hex: []const u8) ![]u8 {
    const obj_path = try std.fmt.allocPrint(testing.allocator, "{s}/objects/{s}/{s}", .{ git_dir, hash_hex[0..2], hash_hex[2..40] });
    defer testing.allocator.free(obj_path);

    const file = try std.fs.openFileAbsolute(obj_path, .{});
    defer file.close();

    const compressed = try file.readToEndAlloc(testing.allocator, 10 * 1024 * 1024);
    defer testing.allocator.free(compressed);

    var decompressed = std.ArrayList(u8).init(testing.allocator);
    errdefer decompressed.deinit();

    var stream = std.io.fixedBufferStream(compressed);
    try std.compress.zlib.decompress(stream.reader(), decompressed.writer());

    return try decompressed.toOwnedSlice();
}

// ============================================================================
// Blob object integrity tests
// ============================================================================

test "blob object has correct format: 'blob <size>\\0<content>'" {
    const path = tmpPath("blob_format");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    const content = "Hello, World!\n";
    try createFile(path, "hello.txt", content);
    try repo.add("hello.txt");

    // Compute expected hash
    const header = try std.fmt.allocPrint(testing.allocator, "blob {}\x00", .{content.len});
    defer testing.allocator.free(header);
    const full_blob = try std.mem.concat(testing.allocator, u8, &.{ header, content });
    defer testing.allocator.free(full_blob);

    var expected_hash: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(full_blob, &expected_hash, .{});
    var hash_hex: [40]u8 = undefined;
    _ = std.fmt.bufPrint(&hash_hex, "{}", .{std.fmt.fmtSliceHexLower(&expected_hash)}) catch unreachable;

    // Read back the stored object
    const git_dir = try std.fmt.allocPrint(testing.allocator, "{s}/.git", .{path});
    defer testing.allocator.free(git_dir);
    const obj_data = try readObject(git_dir, &hash_hex);
    defer testing.allocator.free(obj_data);

    // Verify format
    try testing.expectEqualStrings(full_blob, obj_data);
}

test "blob SHA-1 matches git hash-object" {
    const path = tmpPath("blob_sha1");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    const content = "test content for hashing\n";
    try createFile(path, "test.txt", content);
    try repo.add("test.txt");

    // Get hash from git
    const git_hash_raw = try runGit(&.{ "git", "hash-object", "test.txt" }, path);
    defer testing.allocator.free(git_hash_raw);
    const git_hash = trim(git_hash_raw);

    // Compute ziggit's hash
    const header = try std.fmt.allocPrint(testing.allocator, "blob {}\x00", .{content.len});
    defer testing.allocator.free(header);
    const full_blob = try std.mem.concat(testing.allocator, u8, &.{ header, content });
    defer testing.allocator.free(full_blob);
    var computed_hash: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(full_blob, &computed_hash, .{});
    var hash_hex: [40]u8 = undefined;
    _ = std.fmt.bufPrint(&hash_hex, "{}", .{std.fmt.fmtSliceHexLower(&computed_hash)}) catch unreachable;

    try testing.expectEqualStrings(git_hash, &hash_hex);
}

test "empty blob has known SHA-1" {
    const path = tmpPath("blob_empty");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "empty.txt", "");
    try repo.add("empty.txt");

    // The empty blob has a well-known hash: e69de29bb2d1d6434b8b29ae775ad8c2e48c5391
    const git_hash_raw = try runGit(&.{ "git", "hash-object", "empty.txt" }, path);
    defer testing.allocator.free(git_hash_raw);
    const git_hash = trim(git_hash_raw);
    try testing.expectEqualStrings("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391", git_hash);
}

test "blob with null bytes preserved correctly" {
    const path = tmpPath("blob_nulls");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    const content = "before\x00middle\x00after";
    try createFile(path, "nulls.bin", content);
    try repo.add("nulls.bin");
    _ = try repo.commit("binary", "A", "a@a.com");

    // Verify via git cat-file
    const cat_out = try runGit(&.{ "git", "cat-file", "blob", "HEAD:nulls.bin" }, path);
    defer testing.allocator.free(cat_out);
    try testing.expectEqual(content.len, cat_out.len);
    try testing.expectEqualSlices(u8, content, cat_out);
}

// ============================================================================
// Commit object integrity tests
// ============================================================================

test "commit object has tree, author, committer, and message" {
    const path = tmpPath("commit_fields");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    const hash = try repo.commit("Test message", "Alice", "alice@example.com");

    // Use git cat-file to inspect the commit
    const out = try runGit(&.{ "git", "cat-file", "-p", &hash }, path);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "tree ") != null);
    try testing.expect(std.mem.indexOf(u8, out, "author Alice <alice@example.com>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "committer Alice <alice@example.com>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Test message") != null);
}

test "commit object type is 'commit'" {
    const path = tmpPath("commit_type");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    const hash = try repo.commit("msg", "A", "a@a.com");

    const type_out = try runGit(&.{ "git", "cat-file", "-t", &hash }, path);
    defer testing.allocator.free(type_out);
    try testing.expectEqualStrings("commit", trim(type_out));
}

test "second commit has parent field" {
    const path = tmpPath("commit_parent");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "v1\n");
    try repo.add("f.txt");
    const hash1 = try repo.commit("first", "A", "a@a.com");

    try createFile(path, "f.txt", "v2\n");
    try repo.add("f.txt");
    const hash2 = try repo.commit("second", "A", "a@a.com");

    // Inspect second commit
    const out = try runGit(&.{ "git", "cat-file", "-p", &hash2 }, path);
    defer testing.allocator.free(out);

    // Should have parent pointing to first commit
    const parent_line = try std.fmt.allocPrint(testing.allocator, "parent {s}", .{hash1});
    defer testing.allocator.free(parent_line);
    try testing.expect(std.mem.indexOf(u8, out, parent_line) != null);
}

test "first commit has no parent field" {
    const path = tmpPath("commit_noparent");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    const hash = try repo.commit("initial", "A", "a@a.com");

    const out = try runGit(&.{ "git", "cat-file", "-p", &hash }, path);
    defer testing.allocator.free(out);

    // First commit should NOT have a parent line
    try testing.expect(std.mem.indexOf(u8, out, "parent ") == null);
}

test "commit chain: git rev-list shows correct ancestry" {
    const path = tmpPath("commit_chain");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    var hashes: [5][40]u8 = undefined;
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        var buf: [32]u8 = undefined;
        const content = std.fmt.bufPrint(&buf, "version {d}\n", .{i}) catch unreachable;
        try createFile(path, "f.txt", content);
        try repo.add("f.txt");
        var msg_buf: [32]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "commit {d}", .{i}) catch unreachable;
        hashes[i] = try repo.commit(msg, "A", "a@a.com");
    }

    // git rev-list should return all 5 hashes
    const rev_list = try runGit(&.{ "git", "rev-list", "HEAD" }, path);
    defer testing.allocator.free(rev_list);

    for (hashes) |h| {
        try testing.expect(std.mem.indexOf(u8, rev_list, &h) != null);
    }
}

// ============================================================================
// Tree object integrity tests
// ============================================================================

test "tree object contains correct file entry" {
    const path = tmpPath("tree_entry");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "hello.txt", "hello\n");
    try repo.add("hello.txt");
    _ = try repo.commit("init", "A", "a@a.com");

    // git ls-tree should show the file
    const ls = try runGit(&.{ "git", "ls-tree", "HEAD" }, path);
    defer testing.allocator.free(ls);

    try testing.expect(std.mem.indexOf(u8, ls, "100644") != null);
    try testing.expect(std.mem.indexOf(u8, ls, "blob") != null);
    try testing.expect(std.mem.indexOf(u8, ls, "hello.txt") != null);
}

test "tree with multiple files lists all of them" {
    const path = tmpPath("tree_multi");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    const files = [_][]const u8{ "alpha.txt", "beta.txt", "gamma.txt" };
    for (files) |name| {
        try createFile(path, name, name);
        try repo.add(name);
    }
    _ = try repo.commit("multi", "A", "a@a.com");

    const ls = try runGit(&.{ "git", "ls-tree", "HEAD" }, path);
    defer testing.allocator.free(ls);

    for (files) |name| {
        try testing.expect(std.mem.indexOf(u8, ls, name) != null);
    }
}

test "tree object blob hash matches standalone hash-object" {
    const path = tmpPath("tree_blob_hash");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    const content = "verify this hash\n";
    try createFile(path, "verify.txt", content);
    try repo.add("verify.txt");
    _ = try repo.commit("verify", "A", "a@a.com");

    // Get blob hash from tree
    const ls = try runGit(&.{ "git", "ls-tree", "HEAD" }, path);
    defer testing.allocator.free(ls);

    // Get standalone hash
    const standalone = try runGit(&.{ "git", "hash-object", "verify.txt" }, path);
    defer testing.allocator.free(standalone);

    // The hash in ls-tree should match hash-object
    try testing.expect(std.mem.indexOf(u8, ls, trim(standalone)) != null);
}

// ============================================================================
// Tag object integrity tests
// ============================================================================

test "lightweight tag points to correct commit" {
    const path = tmpPath("tag_lw");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    const hash = try repo.commit("init", "A", "a@a.com");
    try repo.createTag("v1.0.0", null);

    // Read tag file directly
    const tag_content_raw = try runGit(&.{ "git", "rev-parse", "v1.0.0" }, path);
    defer testing.allocator.free(tag_content_raw);
    try testing.expectEqualStrings(&hash, trim(tag_content_raw));
}

test "annotated tag object type is 'tag'" {
    const path = tmpPath("tag_annotated_type");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "A", "a@a.com");
    try repo.createTag("v1.0.0", "Release v1.0.0");

    // The tag ref should point to a tag object
    const rev = try runGit(&.{ "git", "rev-parse", "v1.0.0" }, path);
    defer testing.allocator.free(rev);

    const type_out = try runGit(&.{ "git", "cat-file", "-t", trim(rev) }, path);
    defer testing.allocator.free(type_out);
    try testing.expectEqualStrings("tag", trim(type_out));
}

test "annotated tag object contains tag name and message" {
    const path = tmpPath("tag_annotated_content");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "A", "a@a.com");
    try repo.createTag("v2.0.0", "Second release");

    const rev = try runGit(&.{ "git", "rev-parse", "v2.0.0" }, path);
    defer testing.allocator.free(rev);

    const content = try runGit(&.{ "git", "cat-file", "-p", trim(rev) }, path);
    defer testing.allocator.free(content);

    try testing.expect(std.mem.indexOf(u8, content, "tag v2.0.0") != null);
    try testing.expect(std.mem.indexOf(u8, content, "Second release") != null);
    try testing.expect(std.mem.indexOf(u8, content, "type commit") != null);
}

test "annotated tag dereferences to correct commit" {
    const path = tmpPath("tag_deref");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    const commit_hash = try repo.commit("init", "A", "a@a.com");
    try repo.createTag("v1.0.0", "Release");

    // git rev-parse v1.0.0^{commit} should give the commit hash
    const deref = try runGit(&.{ "git", "rev-parse", "v1.0.0^{commit}" }, path);
    defer testing.allocator.free(deref);
    try testing.expectEqualStrings(&commit_hash, trim(deref));
}

// ============================================================================
// Object decompression integrity tests
// ============================================================================

test "stored objects are valid zlib compressed" {
    const path = tmpPath("zlib_valid");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "test data for compression\n");
    try repo.add("f.txt");
    const hash = try repo.commit("test", "A", "a@a.com");

    // Read commit object file
    const obj_path = try std.fmt.allocPrint(testing.allocator, "{s}/.git/objects/{s}/{s}", .{ path, hash[0..2], hash[2..] });
    defer testing.allocator.free(obj_path);

    const file = try std.fs.openFileAbsolute(obj_path, .{});
    defer file.close();
    const compressed = try file.readToEndAlloc(testing.allocator, 10 * 1024 * 1024);
    defer testing.allocator.free(compressed);

    // Should decompress without error
    var decompressed = std.ArrayList(u8).init(testing.allocator);
    defer decompressed.deinit();
    var stream = std.io.fixedBufferStream(compressed);
    try std.compress.zlib.decompress(stream.reader(), decompressed.writer());

    // Decompressed data should start with "commit "
    try testing.expect(std.mem.startsWith(u8, decompressed.items, "commit "));
}

test "decompressed commit SHA-1 matches stored path" {
    const path = tmpPath("sha1_integrity");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "integrity check\n");
    try repo.add("f.txt");
    const hash = try repo.commit("integrity", "A", "a@a.com");

    // Read and decompress
    const git_dir = try std.fmt.allocPrint(testing.allocator, "{s}/.git", .{path});
    defer testing.allocator.free(git_dir);
    const obj_data = try readObject(git_dir, &hash);
    defer testing.allocator.free(obj_data);

    // Recompute SHA-1 of decompressed data
    var recomputed_hash: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(obj_data, &recomputed_hash, .{});
    var recomputed_hex: [40]u8 = undefined;
    _ = std.fmt.bufPrint(&recomputed_hex, "{}", .{std.fmt.fmtSliceHexLower(&recomputed_hash)}) catch unreachable;

    try testing.expectEqualStrings(&hash, &recomputed_hex);
}

// ============================================================================
// git fsck validation
// ============================================================================

test "git fsck passes on ziggit-created repo" {
    const path = tmpPath("fsck");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "a.txt", "aaa\n");
    try repo.add("a.txt");
    _ = try repo.commit("first", "A", "a@a.com");

    try createFile(path, "b.txt", "bbb\n");
    try repo.add("b.txt");
    _ = try repo.commit("second", "A", "a@a.com");

    try repo.createTag("v1.0.0", null);
    try repo.createTag("v2.0.0", "annotated release");

    // git fsck should pass with no errors
    const fsck = try runGit(&.{ "git", "fsck", "--full" }, path);
    defer testing.allocator.free(fsck);
    // fsck returns 0 exit code (ensured by runGit) and shouldn't report errors
    // (warnings about missing objects are OK, actual errors would cause non-zero exit)
}

test "git fsck passes on repo with distinct files per commit" {
    const path = tmpPath("fsck_many");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    // Use distinct filenames to avoid duplicate tree entry issue
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "file_{d}.txt", .{i}) catch unreachable;
        var content_buf: [32]u8 = undefined;
        const content = std.fmt.bufPrint(&content_buf, "data {d}\n", .{i}) catch unreachable;
        try createFile(path, name, content);
        try repo.add(name);
        var msg_buf: [32]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "commit {d}", .{i}) catch unreachable;
        _ = try repo.commit(msg, "A", "a@a.com");
    }

    const fsck = try runGit(&.{ "git", "fsck", "--full" }, path);
    defer testing.allocator.free(fsck);
}
