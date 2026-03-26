// test/object_decompression_test.zig - Tests that ziggit objects are properly zlib compressed
// and can be decompressed by both ziggit and git cat-file
const std = @import("std");
const ziggit = @import("ziggit");
const testing = std.testing;

const Repository = ziggit.Repository;

fn tmpPath(comptime suffix: []const u8) []const u8 {
    return "/tmp/ziggit_decomp_test_" ++ suffix;
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

// ============================================================================
// Blob object verification
// ============================================================================

test "blob: ziggit-created blob decompresses to valid git format" {
    const path = tmpPath("blob_decomp");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    try createFile(path, "test.txt", "hello world\n");
    try repo.add("test.txt");
    _ = try repo.commit("test", "T", "t@t.com");
    repo.close();

    // Use git hash-object to find the expected hash
    const hash_out = try runGit(&.{ "git", "hash-object", "test.txt" }, path);
    defer testing.allocator.free(hash_out);
    const blob_hash = std.mem.trim(u8, hash_out, " \n\r\t");

    // Use git cat-file to read the blob
    const cat_out = try runGit(&.{ "git", "cat-file", "-p", blob_hash }, path);
    defer testing.allocator.free(cat_out);

    // Content should match exactly
    try testing.expectEqualStrings("hello world\n", cat_out);
}

test "blob: git cat-file -t identifies blob type" {
    const path = tmpPath("blob_type");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    try createFile(path, "f.txt", "data");
    try repo.add("f.txt");
    _ = try repo.commit("c", "T", "t@t.com");
    repo.close();

    // Get blob hash
    const hash_out = try runGit(&.{ "git", "hash-object", "f.txt" }, path);
    defer testing.allocator.free(hash_out);
    const blob_hash = std.mem.trim(u8, hash_out, " \n\r\t");

    // Verify type
    const type_out = try runGit(&.{ "git", "cat-file", "-t", blob_hash }, path);
    defer testing.allocator.free(type_out);
    try testing.expectEqualStrings("blob", std.mem.trim(u8, type_out, " \n\r\t"));
}

test "blob: git cat-file -s shows correct size" {
    const path = tmpPath("blob_size");
    cleanup(path);
    defer cleanup(path);

    const content = "exactly twenty bytes";
    var repo = try Repository.init(testing.allocator, path);
    try createFile(path, "sized.txt", content);
    try repo.add("sized.txt");
    _ = try repo.commit("c", "T", "t@t.com");
    repo.close();

    const hash_out = try runGit(&.{ "git", "hash-object", "sized.txt" }, path);
    defer testing.allocator.free(hash_out);
    const blob_hash = std.mem.trim(u8, hash_out, " \n\r\t");

    const size_out = try runGit(&.{ "git", "cat-file", "-s", blob_hash }, path);
    defer testing.allocator.free(size_out);
    const reported_size = try std.fmt.parseInt(usize, std.mem.trim(u8, size_out, " \n\r\t"), 10);

    try testing.expectEqual(content.len, reported_size);
}

// ============================================================================
// Commit object verification
// ============================================================================

test "commit: git cat-file -t identifies commit type" {
    const path = tmpPath("commit_type");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    try createFile(path, "f.txt", "x");
    try repo.add("f.txt");
    const hash = try repo.commit("my message", "Author", "a@b.com");
    repo.close();

    const type_out = try runGit(&.{ "git", "cat-file", "-t", &hash }, path);
    defer testing.allocator.free(type_out);
    try testing.expectEqualStrings("commit", std.mem.trim(u8, type_out, " \n\r\t"));
}

test "commit: git cat-file -p contains tree line" {
    const path = tmpPath("commit_tree");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    try createFile(path, "f.txt", "x");
    try repo.add("f.txt");
    const hash = try repo.commit("msg", "A", "a@b.com");
    repo.close();

    const content = try runGit(&.{ "git", "cat-file", "-p", &hash }, path);
    defer testing.allocator.free(content);

    try testing.expect(std.mem.startsWith(u8, content, "tree "));
}

test "commit: git cat-file -p contains author and committer" {
    const path = tmpPath("commit_author");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    try createFile(path, "f.txt", "x");
    try repo.add("f.txt");
    const hash = try repo.commit("msg", "John Doe", "john@example.com");
    repo.close();

    const content = try runGit(&.{ "git", "cat-file", "-p", &hash }, path);
    defer testing.allocator.free(content);

    try testing.expect(std.mem.indexOf(u8, content, "author John Doe <john@example.com>") != null);
    try testing.expect(std.mem.indexOf(u8, content, "committer John Doe <john@example.com>") != null);
}

test "commit: git cat-file -p contains message" {
    const path = tmpPath("commit_msg");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    try createFile(path, "f.txt", "x");
    try repo.add("f.txt");
    const hash = try repo.commit("this is my special message", "A", "a@b.com");
    repo.close();

    const content = try runGit(&.{ "git", "cat-file", "-p", &hash }, path);
    defer testing.allocator.free(content);

    try testing.expect(std.mem.indexOf(u8, content, "this is my special message") != null);
}

test "commit: second commit has parent line" {
    const path = tmpPath("commit_parent");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    try createFile(path, "f.txt", "v1");
    try repo.add("f.txt");
    const first = try repo.commit("first", "A", "a@b.com");

    try createFile(path, "f.txt", "v2");
    try repo.add("f.txt");
    const second = try repo.commit("second", "A", "a@b.com");
    repo.close();

    const content = try runGit(&.{ "git", "cat-file", "-p", &second }, path);
    defer testing.allocator.free(content);

    // Should contain "parent <first commit hash>"
    const expected_parent = try std.fmt.allocPrint(testing.allocator, "parent {s}", .{first});
    defer testing.allocator.free(expected_parent);
    try testing.expect(std.mem.indexOf(u8, content, expected_parent) != null);
}

// ============================================================================
// Tree object verification
// ============================================================================

test "tree: git ls-tree shows committed files" {
    const path = tmpPath("tree_ls");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    try createFile(path, "alpha.txt", "aaa\n");
    try repo.add("alpha.txt");
    try createFile(path, "beta.txt", "bbb\n");
    try repo.add("beta.txt");
    _ = try repo.commit("multi", "A", "a@b.com");
    repo.close();

    const ls_out = try runGit(&.{ "git", "ls-tree", "HEAD" }, path);
    defer testing.allocator.free(ls_out);

    try testing.expect(std.mem.indexOf(u8, ls_out, "alpha.txt") != null);
    try testing.expect(std.mem.indexOf(u8, ls_out, "beta.txt") != null);
}

test "tree: blob hashes in tree match git hash-object" {
    const path = tmpPath("tree_hashes");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    try createFile(path, "check.txt", "verify me\n");
    try repo.add("check.txt");
    _ = try repo.commit("c", "A", "a@b.com");
    repo.close();

    // Get expected blob hash
    const expected = try runGit(&.{ "git", "hash-object", "check.txt" }, path);
    defer testing.allocator.free(expected);
    const expected_hash = std.mem.trim(u8, expected, " \n\r\t");

    // Get blob hash from tree
    const ls_out = try runGit(&.{ "git", "ls-tree", "HEAD" }, path);
    defer testing.allocator.free(ls_out);

    // Format: "100644 blob <hash>\tcheck.txt"
    try testing.expect(std.mem.indexOf(u8, ls_out, expected_hash) != null);
}

// ============================================================================
// Raw object file format
// ============================================================================

test "object file: starts with zlib header bytes" {
    const path = tmpPath("raw_obj");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    try createFile(path, "z.txt", "zlib test\n");
    try repo.add("z.txt");
    const hash = try repo.commit("c", "A", "a@b.com");
    repo.close();

    // Read raw object file
    const obj_path = try std.fmt.allocPrint(testing.allocator, "{s}/.git/objects/{s}/{s}", .{ path, hash[0..2], hash[2..] });
    defer testing.allocator.free(obj_path);

    const obj_file = try std.fs.openFileAbsolute(obj_path, .{});
    defer obj_file.close();

    var header_buf: [2]u8 = undefined;
    _ = try obj_file.readAll(&header_buf);

    // zlib compressed data starts with 0x78 (CMF byte) followed by check byte
    // 0x78 0x01 = no compression
    // 0x78 0x5E = fast compression
    // 0x78 0x9C = default compression
    // 0x78 0xDA = best compression
    try testing.expectEqual(@as(u8, 0x78), header_buf[0]);
}

test "object file: decompresses to type size null content format" {
    const path = tmpPath("raw_fmt");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    try createFile(path, "fmt.txt", "format check\n");
    try repo.add("fmt.txt");
    _ = try repo.commit("c", "A", "a@b.com");
    repo.close();

    // Get blob hash
    const hash_out = try runGit(&.{ "git", "hash-object", "fmt.txt" }, path);
    defer testing.allocator.free(hash_out);
    const blob_hash = std.mem.trim(u8, hash_out, " \n\r\t");

    // Read and decompress object manually
    const obj_path = try std.fmt.allocPrint(testing.allocator, "{s}/.git/objects/{s}/{s}", .{ path, blob_hash[0..2], blob_hash[2..] });
    defer testing.allocator.free(obj_path);

    const obj_file = try std.fs.openFileAbsolute(obj_path, .{});
    defer obj_file.close();

    const compressed = try obj_file.readToEndAlloc(testing.allocator, 1024 * 1024);
    defer testing.allocator.free(compressed);

    var decompressed = std.ArrayList(u8).init(testing.allocator);
    defer decompressed.deinit();

    var stream = std.io.fixedBufferStream(compressed);
    try std.compress.zlib.decompress(stream.reader(), decompressed.writer());

    // Should start with "blob <size>\0"
    try testing.expect(std.mem.startsWith(u8, decompressed.items, "blob "));

    // Should contain null separator
    const null_pos = std.mem.indexOfScalar(u8, decompressed.items, 0);
    try testing.expect(null_pos != null);

    // Content after null should be the file content
    const content_after_null = decompressed.items[null_pos.? + 1 ..];
    try testing.expectEqualStrings("format check\n", content_after_null);
}

// ============================================================================
// SHA-1 hash verification
// ============================================================================

test "blob hash: computed by ziggit matches git hash-object" {
    const path = tmpPath("hash_verify");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);

    const test_contents = [_][]const u8{
        "",
        "a",
        "hello world\n",
        "line1\nline2\nline3\n",
        "\x00\x01\x02\x03\xff",
    };

    for (test_contents) |content| {
        try createFile(path, "hashtest.txt", content);
        try repo.add("hashtest.txt");
        _ = try repo.commit("test", "A", "a@b.com");

        // Get git's hash
        const git_hash = try runGit(&.{ "git", "hash-object", "hashtest.txt" }, path);
        defer testing.allocator.free(git_hash);
        const expected = std.mem.trim(u8, git_hash, " \n\r\t");

        // Get blob hash from tree
        const ls_out = try runGit(&.{ "git", "ls-tree", "HEAD" }, path);
        defer testing.allocator.free(ls_out);

        // The tree should contain the same hash
        try testing.expect(std.mem.indexOf(u8, ls_out, expected) != null);
    }

    repo.close();
}
