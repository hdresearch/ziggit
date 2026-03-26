// test/objects_store_and_hash_test.zig
// Tests git object hash computation, store/load roundtrip, and type handling
// using the internal git module (src/git/objects.zig via git.zig).
const std = @import("std");
const git = @import("git");
const testing = std.testing;

const GitObject = git.objects.GitObject;
const ObjectType = git.objects.ObjectType;
const TreeEntry = git.objects.TreeEntry;

// ============================================================================
// Helper: minimal platform implementation for objects.store/load
// ============================================================================
const TestPlatform = struct {
    pub const fs = struct {
        pub fn makeDir(path: []const u8) anyerror!void {
            std.fs.makeDirAbsolute(path) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }

        pub fn readFile(allocator: std.mem.Allocator, path: []const u8) anyerror![]u8 {
            const f = try std.fs.openFileAbsolute(path, .{});
            defer f.close();
            return try f.readToEndAlloc(allocator, 10 * 1024 * 1024);
        }

        pub fn writeFile(path: []const u8, data: []const u8) anyerror!void {
            const f = try std.fs.createFileAbsolute(path, .{ .truncate = true });
            defer f.close();
            try f.writeAll(data);
        }
    };
};

fn tmp(comptime suffix: []const u8) []const u8 {
    return "/tmp/ziggit_objtest_" ++ suffix;
}

fn cleanup(path: []const u8) void {
    std.fs.deleteTreeAbsolute(path) catch {};
}

inline fn setupGitDir(comptime suffix: []const u8) ![]const u8 {
    const path = comptime tmp(suffix);
    cleanup(path);
    const git_dir = comptime path ++ "/.git";
    std.fs.makeDirAbsolute(path) catch {};
    std.fs.makeDirAbsolute(git_dir) catch {};
    std.fs.makeDirAbsolute(git_dir ++ "/objects") catch {};
    std.fs.makeDirAbsolute(git_dir ++ "/refs") catch {};
    return git_dir;
}

// ============================================================================
// ObjectType tests
// ============================================================================

test "ObjectType.fromString: all valid types" {
    try testing.expectEqual(ObjectType.blob, ObjectType.fromString("blob").?);
    try testing.expectEqual(ObjectType.tree, ObjectType.fromString("tree").?);
    try testing.expectEqual(ObjectType.commit, ObjectType.fromString("commit").?);
    try testing.expectEqual(ObjectType.tag, ObjectType.fromString("tag").?);
}

test "ObjectType.fromString: invalid types return null" {
    try testing.expect(ObjectType.fromString("invalid") == null);
    try testing.expect(ObjectType.fromString("") == null);
    try testing.expect(ObjectType.fromString("BLOB") == null);
    try testing.expect(ObjectType.fromString("Tree") == null);
}

test "ObjectType.toString: roundtrips" {
    try testing.expectEqualStrings("blob", ObjectType.blob.toString());
    try testing.expectEqualStrings("tree", ObjectType.tree.toString());
    try testing.expectEqualStrings("commit", ObjectType.commit.toString());
    try testing.expectEqualStrings("tag", ObjectType.tag.toString());
}

test "ObjectType: fromString(toString(x)) == x for all types" {
    const all = [_]ObjectType{ .blob, .tree, .commit, .tag };
    for (all) |t| {
        try testing.expectEqual(t, ObjectType.fromString(t.toString()).?);
    }
}

// ============================================================================
// GitObject.hash tests
// ============================================================================

test "GitObject.hash: empty blob produces known SHA-1" {
    // "blob 0\0" -> known empty blob hash: e69de29bb2d1d6434b8b29ae775ad8c2e48c5391
    const obj = GitObject.init(.blob, "");
    const hash = try obj.hash(testing.allocator);
    defer testing.allocator.free(hash);
    try testing.expectEqualStrings("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391", hash);
}

test "GitObject.hash: known blob content" {
    // "hello\n" -> blob hash: ce013625030ba8dba906f756967f9e9ca394464a
    const obj = GitObject.init(.blob, "hello\n");
    const hash = try obj.hash(testing.allocator);
    defer testing.allocator.free(hash);
    try testing.expectEqualStrings("ce013625030ba8dba906f756967f9e9ca394464a", hash);
}

test "GitObject.hash: blob hash is 40 hex characters" {
    const obj = GitObject.init(.blob, "test data");
    const hash = try obj.hash(testing.allocator);
    defer testing.allocator.free(hash);
    try testing.expectEqual(@as(usize, 40), hash.len);
    for (hash) |c| {
        try testing.expect(std.ascii.isHex(c));
    }
}

test "GitObject.hash: different content produces different hashes" {
    const obj1 = GitObject.init(.blob, "content A");
    const obj2 = GitObject.init(.blob, "content B");
    const h1 = try obj1.hash(testing.allocator);
    defer testing.allocator.free(h1);
    const h2 = try obj2.hash(testing.allocator);
    defer testing.allocator.free(h2);
    try testing.expect(!std.mem.eql(u8, h1, h2));
}

test "GitObject.hash: same content different types produce different hashes" {
    const data = "same content";
    const blob = GitObject.init(.blob, data);
    const commit = GitObject.init(.commit, data);
    const h_blob = try blob.hash(testing.allocator);
    defer testing.allocator.free(h_blob);
    const h_commit = try commit.hash(testing.allocator);
    defer testing.allocator.free(h_commit);
    try testing.expect(!std.mem.eql(u8, h_blob, h_commit));
}

test "GitObject.hash: same input is deterministic" {
    const obj = GitObject.init(.blob, "deterministic");
    const h1 = try obj.hash(testing.allocator);
    defer testing.allocator.free(h1);
    const h2 = try obj.hash(testing.allocator);
    defer testing.allocator.free(h2);
    try testing.expectEqualStrings(h1, h2);
}

// ============================================================================
// GitObject store/load roundtrip tests
// ============================================================================

test "GitObject store+load roundtrip: blob" {
    const git_dir = try setupGitDir("storeblob");
    defer cleanup(tmp("storeblob"));

    const content = "Hello, roundtrip!\n";
    const obj = GitObject.init(.blob, content);
    const hash = try obj.store(git_dir, TestPlatform, testing.allocator);
    defer testing.allocator.free(hash);

    const loaded = try GitObject.load(hash, git_dir, TestPlatform, testing.allocator);
    defer loaded.deinit(testing.allocator);

    try testing.expectEqual(ObjectType.blob, loaded.type);
    try testing.expectEqualStrings(content, loaded.data);
}

test "GitObject store+load roundtrip: empty blob" {
    const git_dir = try setupGitDir("storeempty");
    defer cleanup(tmp("storeempty"));

    const obj = GitObject.init(.blob, "");
    const hash = try obj.store(git_dir, TestPlatform, testing.allocator);
    defer testing.allocator.free(hash);

    const loaded = try GitObject.load(hash, git_dir, TestPlatform, testing.allocator);
    defer loaded.deinit(testing.allocator);

    try testing.expectEqual(ObjectType.blob, loaded.type);
    try testing.expectEqual(@as(usize, 0), loaded.data.len);
}

test "GitObject store+load roundtrip: large blob" {
    const git_dir = try setupGitDir("storelarge");
    defer cleanup(tmp("storelarge"));

    // 100KB of data
    const data = try testing.allocator.alloc(u8, 100 * 1024);
    defer testing.allocator.free(data);
    for (data, 0..) |*b, i| {
        b.* = @intCast(i % 256);
    }

    const obj = GitObject.init(.blob, data);
    const hash = try obj.store(git_dir, TestPlatform, testing.allocator);
    defer testing.allocator.free(hash);

    const loaded = try GitObject.load(hash, git_dir, TestPlatform, testing.allocator);
    defer loaded.deinit(testing.allocator);

    try testing.expectEqual(ObjectType.blob, loaded.type);
    try testing.expectEqualSlices(u8, data, loaded.data);
}

test "GitObject store+load roundtrip: binary content" {
    const git_dir = try setupGitDir("storebin");
    defer cleanup(tmp("storebin"));

    const content = "\x00\x01\x02\xff\xfe\xfd\x00\x00";
    const obj = GitObject.init(.blob, content);
    const hash = try obj.store(git_dir, TestPlatform, testing.allocator);
    defer testing.allocator.free(hash);

    const loaded = try GitObject.load(hash, git_dir, TestPlatform, testing.allocator);
    defer loaded.deinit(testing.allocator);

    try testing.expectEqual(ObjectType.blob, loaded.type);
    try testing.expectEqualSlices(u8, content, loaded.data);
}

// ============================================================================
// createBlobObject / createCommitObject tests
// ============================================================================

test "createBlobObject: produces correct type and content" {
    const obj = try git.objects.createBlobObject("file data", testing.allocator);
    defer obj.deinit(testing.allocator);
    try testing.expectEqual(ObjectType.blob, obj.type);
    try testing.expectEqualStrings("file data", obj.data);
}

test "createCommitObject: no parents" {
    const tree_hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const obj = try git.objects.createCommitObject(
        tree_hash,
        &[_][]const u8{},
        "Author <a@b.com> 1234567890 +0000",
        "Committer <c@d.com> 1234567890 +0000",
        "Initial commit",
        testing.allocator,
    );
    defer obj.deinit(testing.allocator);

    try testing.expectEqual(ObjectType.commit, obj.type);
    try testing.expect(std.mem.indexOf(u8, obj.data, "tree aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") != null);
    try testing.expect(std.mem.indexOf(u8, obj.data, "parent") == null);
    try testing.expect(std.mem.indexOf(u8, obj.data, "Initial commit") != null);
}

test "createCommitObject: with parent" {
    const tree_hash = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const parent = "cccccccccccccccccccccccccccccccccccccccc";
    const obj = try git.objects.createCommitObject(
        tree_hash,
        &[_][]const u8{parent},
        "Author <a@b.com> 1 +0000",
        "Committer <c@d.com> 1 +0000",
        "second commit",
        testing.allocator,
    );
    defer obj.deinit(testing.allocator);

    try testing.expectEqual(ObjectType.commit, obj.type);
    try testing.expect(std.mem.indexOf(u8, obj.data, "parent cccccccccccccccccccccccccccccccccccccccc") != null);
}

// ============================================================================
// createTreeObject tests
// ============================================================================

test "createTreeObject: single entry" {
    const entries = [_]TreeEntry{
        TreeEntry.init("100644", "hello.txt", "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391"),
    };
    const obj = try git.objects.createTreeObject(&entries, testing.allocator);
    defer obj.deinit(testing.allocator);

    try testing.expectEqual(ObjectType.tree, obj.type);
    try testing.expect(obj.data.len > 0);
    // Tree binary format: "100644 hello.txt\0<20 bytes sha>"
    try testing.expect(std.mem.indexOf(u8, obj.data, "100644 hello.txt") != null);
}

test "createTreeObject: empty tree" {
    const entries = [_]TreeEntry{};
    const obj = try git.objects.createTreeObject(&entries, testing.allocator);
    defer obj.deinit(testing.allocator);

    try testing.expectEqual(ObjectType.tree, obj.type);
    try testing.expectEqual(@as(usize, 0), obj.data.len);
}

// ============================================================================
// Object load error handling
// ============================================================================

test "GitObject.load: nonexistent hash returns error" {
    const git_dir = try setupGitDir("loadfail");
    defer cleanup(tmp("loadfail"));

    const result = GitObject.load(
        "0000000000000000000000000000000000000000",
        git_dir,
        TestPlatform,
        testing.allocator,
    );
    try testing.expectError(error.ObjectNotFound, result);
}
