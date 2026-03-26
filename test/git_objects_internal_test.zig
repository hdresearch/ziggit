// test/git_objects_internal_test.zig - Tests for internal git objects module
const std = @import("std");
const testing = std.testing;
const git = @import("git");

// ============================================================================
// ObjectType enum
// ============================================================================

test "ObjectType.fromString recognizes all types" {
    try testing.expect(git.objects.ObjectType.fromString("blob") == .blob);
    try testing.expect(git.objects.ObjectType.fromString("tree") == .tree);
    try testing.expect(git.objects.ObjectType.fromString("commit") == .commit);
    try testing.expect(git.objects.ObjectType.fromString("tag") == .tag);
}

test "ObjectType.fromString returns null for unknown" {
    try testing.expect(git.objects.ObjectType.fromString("unknown") == null);
    try testing.expect(git.objects.ObjectType.fromString("") == null);
    try testing.expect(git.objects.ObjectType.fromString("Blob") == null);
}

test "ObjectType.toString roundtrips" {
    const types = [_]git.objects.ObjectType{ .blob, .tree, .commit, .tag };
    for (types) |t| {
        const s = t.toString();
        try testing.expect(git.objects.ObjectType.fromString(s) == t);
    }
}

test "ObjectType.toString values" {
    try testing.expectEqualStrings("blob", git.objects.ObjectType.blob.toString());
    try testing.expectEqualStrings("tree", git.objects.ObjectType.tree.toString());
    try testing.expectEqualStrings("commit", git.objects.ObjectType.commit.toString());
    try testing.expectEqualStrings("tag", git.objects.ObjectType.tag.toString());
}

// ============================================================================
// GitObject hash computation
// ============================================================================

test "blob hash: empty content" {
    // git hash-object -t blob --stdin < /dev/null = e69de29bb2d1d6434b8b29ae775ad8c2e48c5391
    const obj = git.objects.GitObject.init(.blob, "");
    const hash = try obj.hash(testing.allocator);
    defer testing.allocator.free(hash);

    try testing.expectEqualStrings("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391", hash);
}

test "blob hash: hello world newline" {
    // echo "hello world" | git hash-object --stdin = 3b18e512dba79e4c8300dd08aeb37f8e728b8dad
    const obj = git.objects.GitObject.init(.blob, "hello world\n");
    const hash = try obj.hash(testing.allocator);
    defer testing.allocator.free(hash);

    try testing.expectEqualStrings("3b18e512dba79e4c8300dd08aeb37f8e728b8dad", hash);
}

test "blob hash: hello (no newline)" {
    // printf 'hello' | git hash-object --stdin = b6fc4c620b67d95f953a5c1c1230aaab5db5a1b0
    const obj = git.objects.GitObject.init(.blob, "hello");
    const hash = try obj.hash(testing.allocator);
    defer testing.allocator.free(hash);

    try testing.expectEqualStrings("b6fc4c620b67d95f953a5c1c1230aaab5db5a1b0", hash);
}

test "blob hash: binary content with null bytes" {
    const data = "ab\x00cd\x00ef";
    const obj = git.objects.GitObject.init(.blob, data);
    const hash = try obj.hash(testing.allocator);
    defer testing.allocator.free(hash);

    try testing.expect(hash.len == 40);
    for (hash) |c| {
        try testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
}

test "blob hash: different content produces different hashes" {
    const obj1 = git.objects.GitObject.init(.blob, "content1");
    const obj2 = git.objects.GitObject.init(.blob, "content2");

    const hash1 = try obj1.hash(testing.allocator);
    defer testing.allocator.free(hash1);
    const hash2 = try obj2.hash(testing.allocator);
    defer testing.allocator.free(hash2);

    try testing.expect(!std.mem.eql(u8, hash1, hash2));
}

test "blob hash: same content produces same hash (deterministic)" {
    const obj1 = git.objects.GitObject.init(.blob, "same content");
    const obj2 = git.objects.GitObject.init(.blob, "same content");

    const hash1 = try obj1.hash(testing.allocator);
    defer testing.allocator.free(hash1);
    const hash2 = try obj2.hash(testing.allocator);
    defer testing.allocator.free(hash2);

    try testing.expectEqualStrings(hash1, hash2);
}

test "blob hash: single byte" {
    const obj = git.objects.GitObject.init(.blob, "x");
    const hash = try obj.hash(testing.allocator);
    defer testing.allocator.free(hash);
    try testing.expect(hash.len == 40);
}

test "blob hash: 1KB content" {
    var buf: [1024]u8 = undefined;
    @memset(&buf, 'A');
    const obj = git.objects.GitObject.init(.blob, &buf);
    const hash = try obj.hash(testing.allocator);
    defer testing.allocator.free(hash);
    try testing.expect(hash.len == 40);
}

test "blob hash matches git hash-object for arbitrary content" {
    // Cross-validate with git CLI
    const content = "ziggit test content for hash validation\n";
    
    const obj = git.objects.GitObject.init(.blob, content);
    const zig_hash = try obj.hash(testing.allocator);
    defer testing.allocator.free(zig_hash);

    // Write content to temp file and hash with git
    const tmp_path = "/tmp/ziggit_hash_test_content";
    {
        const f = try std.fs.createFileAbsolute(tmp_path, .{});
        defer f.close();
        try f.writeAll(content);
    }
    defer std.fs.deleteFileAbsolute(tmp_path) catch {};

    const git_output = try runCmd(&.{ "git", "hash-object", tmp_path });
    defer testing.allocator.free(git_output);
    const git_hash = std.mem.trim(u8, git_output, " \t\n\r");

    try testing.expectEqualStrings(git_hash, zig_hash);
}

// ============================================================================
// createBlobObject
// ============================================================================

test "createBlobObject stores correct data" {
    var obj = try git.objects.createBlobObject("test data", testing.allocator);
    defer obj.deinit(testing.allocator);

    try testing.expect(obj.type == .blob);
    try testing.expectEqualStrings("test data", obj.data);
}

test "createBlobObject empty content" {
    var obj = try git.objects.createBlobObject("", testing.allocator);
    defer obj.deinit(testing.allocator);

    try testing.expect(obj.type == .blob);
    try testing.expect(obj.data.len == 0);
}

// ============================================================================
// createCommitObject
// ============================================================================

test "createCommitObject with no parents" {
    const tree_hash = "4b825dc642cb6eb9a060e54bf899d69f7e6053e0";
    const parents = &[_][]const u8{};

    var obj = try git.objects.createCommitObject(
        tree_hash,
        parents,
        "Author <a@b.com> 1000000000 +0000",
        "Committer <c@d.com> 1000000000 +0000",
        "Initial commit",
        testing.allocator,
    );
    defer obj.deinit(testing.allocator);

    try testing.expect(obj.type == .commit);
    try testing.expect(std.mem.indexOf(u8, obj.data, "tree 4b825dc642cb6eb9a060e54bf899d69f7e6053e0") != null);
    try testing.expect(std.mem.indexOf(u8, obj.data, "parent") == null);
    try testing.expect(std.mem.indexOf(u8, obj.data, "author Author") != null);
    try testing.expect(std.mem.indexOf(u8, obj.data, "committer Committer") != null);
    try testing.expect(std.mem.indexOf(u8, obj.data, "Initial commit") != null);
}

test "createCommitObject with one parent" {
    const tree_hash = "4b825dc642cb6eb9a060e54bf899d69f7e6053e0";
    const parent = "abc1234567890abcdef1234567890abcdef123456";
    const parents = &[_][]const u8{parent};

    var obj = try git.objects.createCommitObject(
        tree_hash,
        parents,
        "Author <a@b.com> 1000000000 +0000",
        "Committer <c@d.com> 1000000000 +0000",
        "Second commit",
        testing.allocator,
    );
    defer obj.deinit(testing.allocator);

    try testing.expect(std.mem.indexOf(u8, obj.data, "parent abc1234567890abcdef1234567890abcdef123456") != null);
}

test "createCommitObject with two parents (merge)" {
    const tree_hash = "4b825dc642cb6eb9a060e54bf899d69f7e6053e0";
    const parent1 = "aaaa234567890abcdef1234567890abcdef123456";
    const parent2 = "bbbb234567890abcdef1234567890abcdef123456";
    const parents = &[_][]const u8{ parent1, parent2 };

    var obj = try git.objects.createCommitObject(
        tree_hash,
        parents,
        "Author <a@b.com> 1000000000 +0000",
        "Committer <c@d.com> 1000000000 +0000",
        "Merge commit",
        testing.allocator,
    );
    defer obj.deinit(testing.allocator);

    // Both parents should appear
    try testing.expect(std.mem.indexOf(u8, obj.data, "parent aaaa") != null);
    try testing.expect(std.mem.indexOf(u8, obj.data, "parent bbbb") != null);
}

test "createCommitObject hash is deterministic" {
    const tree_hash = "4b825dc642cb6eb9a060e54bf899d69f7e6053e0";
    const parents = &[_][]const u8{};

    var obj1 = try git.objects.createCommitObject(tree_hash, parents, "A <a@b.com> 1 +0000", "A <a@b.com> 1 +0000", "msg", testing.allocator);
    defer obj1.deinit(testing.allocator);

    var obj2 = try git.objects.createCommitObject(tree_hash, parents, "A <a@b.com> 1 +0000", "A <a@b.com> 1 +0000", "msg", testing.allocator);
    defer obj2.deinit(testing.allocator);

    const h1 = try obj1.hash(testing.allocator);
    defer testing.allocator.free(h1);
    const h2 = try obj2.hash(testing.allocator);
    defer testing.allocator.free(h2);

    try testing.expectEqualStrings(h1, h2);
}

// ============================================================================
// createTreeObject
// ============================================================================

test "createTreeObject with single entry" {
    const entries = &[_]git.objects.TreeEntry{
        git.objects.TreeEntry.init("100644", "hello.txt", "b6fc4c620b67d95f953a5c1c1230aaab5db5a1b0"),
    };

    var obj = try git.objects.createTreeObject(entries, testing.allocator);
    defer obj.deinit(testing.allocator);

    try testing.expect(obj.type == .tree);
    try testing.expect(obj.data.len > 0);
}

test "createTreeObject with multiple entries" {
    const entries = &[_]git.objects.TreeEntry{
        git.objects.TreeEntry.init("100644", "a.txt", "b6fc4c620b67d95f953a5c1c1230aaab5db5a1b0"),
        git.objects.TreeEntry.init("100644", "b.txt", "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391"),
        git.objects.TreeEntry.init("100755", "script.sh", "b6fc4c620b67d95f953a5c1c1230aaab5db5a1b0"),
    };

    var obj = try git.objects.createTreeObject(entries, testing.allocator);
    defer obj.deinit(testing.allocator);

    try testing.expect(obj.type == .tree);
    // Should contain the filenames
    try testing.expect(std.mem.indexOf(u8, obj.data, "a.txt") != null);
    try testing.expect(std.mem.indexOf(u8, obj.data, "b.txt") != null);
    try testing.expect(std.mem.indexOf(u8, obj.data, "script.sh") != null);
}

test "createTreeObject hash is deterministic" {
    const entries = &[_]git.objects.TreeEntry{
        git.objects.TreeEntry.init("100644", "file.txt", "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391"),
    };

    var obj1 = try git.objects.createTreeObject(entries, testing.allocator);
    defer obj1.deinit(testing.allocator);
    var obj2 = try git.objects.createTreeObject(entries, testing.allocator);
    defer obj2.deinit(testing.allocator);

    const h1 = try obj1.hash(testing.allocator);
    defer testing.allocator.free(h1);
    const h2 = try obj2.hash(testing.allocator);
    defer testing.allocator.free(h2);

    try testing.expectEqualStrings(h1, h2);
}

// ============================================================================
// applyDelta
// ============================================================================

test "applyDelta with simple copy instruction" {
    const base = "Hello World";

    // Build delta: base_size=11, result_size=11, copy(offset=0, size=11)
    var delta_buf: [32]u8 = undefined;
    var pos: usize = 0;

    // base size (varint): 11
    delta_buf[pos] = 11;
    pos += 1;
    // result size (varint): 11
    delta_buf[pos] = 11;
    pos += 1;
    // Copy instruction: 0x80 | flags for offset and size
    // offset = 0 (no offset bytes needed)
    // size = 11 = 0x0B, use size1 flag (0x10)
    delta_buf[pos] = 0x80 | 0x10; // copy, size1 present
    pos += 1;
    delta_buf[pos] = 11; // size byte
    pos += 1;

    const result = try git.objects.applyDelta(base, delta_buf[0..pos], testing.allocator);
    defer testing.allocator.free(result);

    try testing.expectEqualStrings("Hello World", result);
}

test "applyDelta with add instruction" {
    const base = "base";

    var delta_buf: [32]u8 = undefined;
    var pos: usize = 0;

    // base size: 4
    delta_buf[pos] = 4;
    pos += 1;
    // result size: 5
    delta_buf[pos] = 5;
    pos += 1;
    // Add instruction: length byte (< 0x80), followed by literal bytes
    delta_buf[pos] = 5; // add 5 bytes
    pos += 1;
    @memcpy(delta_buf[pos .. pos + 5], "added");
    pos += 5;

    const result = try git.objects.applyDelta(base, delta_buf[0..pos], testing.allocator);
    defer testing.allocator.free(result);

    try testing.expectEqualStrings("added", result);
}

// ============================================================================
// Helpers
// ============================================================================

fn runCmd(args: []const []const u8) ![]u8 {
    var child = std.process.Child.init(args, testing.allocator);
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
