// test/object_create_and_parse_test.zig
// Tests for creating git objects (blob, tree, commit) and parsing them back
// Uses the internal git module directly
const std = @import("std");
const git = @import("git");
const testing = std.testing;

const objects = git.objects;
const GitObject = objects.GitObject;
const ObjectType = objects.ObjectType;
const TreeEntry = objects.TreeEntry;

// Platform impl matching the anytype interface used by git.objects
const platform = struct {
    pub const fs = struct {
        pub fn makeDir(path: []const u8) !void {
            std.fs.cwd().makeDir(path) catch |err| switch (err) {
                error.PathAlreadyExists => return error.AlreadyExists,
                else => return err,
            };
        }
        pub fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
            return try std.fs.cwd().readFileAlloc(allocator, path, std.math.maxInt(usize));
        }
        pub fn writeFile(path: []const u8, data: []const u8) !void {
            try std.fs.cwd().writeFile(.{ .sub_path = path, .data = data });
        }
        pub fn exists(path: []const u8) !bool {
            std.fs.cwd().access(path, .{}) catch |err| switch (err) {
                error.FileNotFound => return false,
                else => return err,
            };
            return true;
        }
        pub fn readDir(allocator: std.mem.Allocator, path: []const u8) ![][]u8 {
            var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch return error.FileNotFound;
            defer dir.close();
            var list = std.ArrayList([]u8).init(allocator);
            var iter = dir.iterate();
            while (try iter.next()) |entry| {
                try list.append(try allocator.dupe(u8, entry.name));
            }
            return try list.toOwnedSlice();
        }
    };
};

fn setupGitDir(path: []const u8) !void {
    std.fs.deleteTreeAbsolute(path) catch {};
    try std.fs.makeDirAbsolute(path);

    const subdirs = [_][]const u8{
        "objects", "objects/info", "objects/pack",
        "refs", "refs/heads", "refs/tags",
    };
    for (subdirs) |sub| {
        const full = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ path, sub });
        defer testing.allocator.free(full);
        std.fs.makeDirAbsolute(full) catch {};
    }
    // Write HEAD
    const head_path = try std.fmt.allocPrint(testing.allocator, "{s}/HEAD", .{path});
    defer testing.allocator.free(head_path);
    const f = try std.fs.createFileAbsolute(head_path, .{ .truncate = true });
    defer f.close();
    try f.writeAll("ref: refs/heads/master\n");
}

fn cleanup(path: []const u8) void {
    std.fs.deleteTreeAbsolute(path) catch {};
}

// ============================================================================
// ObjectType tests
// ============================================================================

test "ObjectType.fromString: all valid types" {
    try testing.expectEqual(ObjectType.commit, ObjectType.fromString("commit").?);
    try testing.expectEqual(ObjectType.tree, ObjectType.fromString("tree").?);
    try testing.expectEqual(ObjectType.blob, ObjectType.fromString("blob").?);
    try testing.expectEqual(ObjectType.tag, ObjectType.fromString("tag").?);
}

test "ObjectType.fromString: invalid returns null" {
    try testing.expect(ObjectType.fromString("invalid") == null);
    try testing.expect(ObjectType.fromString("") == null);
    try testing.expect(ObjectType.fromString("COMMIT") == null);
    try testing.expect(ObjectType.fromString("Blob") == null);
}

test "ObjectType.toString roundtrip" {
    inline for (.{ ObjectType.commit, ObjectType.tree, ObjectType.blob, ObjectType.tag }) |t| {
        const s = t.toString();
        try testing.expectEqual(t, ObjectType.fromString(s).?);
    }
}

// ============================================================================
// Blob creation tests
// ============================================================================

test "createBlobObject: stores content correctly" {
    var obj = try objects.createBlobObject("hello world\n", testing.allocator);
    defer obj.deinit(testing.allocator);

    try testing.expectEqual(ObjectType.blob, obj.type);
    try testing.expectEqualSlices(u8, "hello world\n", obj.data);
}

test "createBlobObject: empty content" {
    var obj = try objects.createBlobObject("", testing.allocator);
    defer obj.deinit(testing.allocator);

    try testing.expectEqual(ObjectType.blob, obj.type);
    try testing.expectEqual(@as(usize, 0), obj.data.len);
}

test "blob hash: known value for hello world newline" {
    // git hash-object -t blob --stdin <<< "hello world"
    // gives: 3b18e512dba79e4c8300dd08aeb37f8e728b8dad
    var obj = try objects.createBlobObject("hello world\n", testing.allocator);
    defer obj.deinit(testing.allocator);

    const hash = try obj.hash(testing.allocator);
    defer testing.allocator.free(hash);

    try testing.expectEqualSlices(u8, "3b18e512dba79e4c8300dd08aeb37f8e728b8dad", hash);
}

test "blob hash: empty blob has known hash" {
    // git hash-object -t blob /dev/null → e69de29bb2d1d6434b8b29ae775ad8c2e48c5391
    var obj = try objects.createBlobObject("", testing.allocator);
    defer obj.deinit(testing.allocator);

    const hash = try obj.hash(testing.allocator);
    defer testing.allocator.free(hash);

    try testing.expectEqualSlices(u8, "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391", hash);
}

test "blob hash: deterministic same content same hash" {
    var obj1 = try objects.createBlobObject("test content", testing.allocator);
    defer obj1.deinit(testing.allocator);
    var obj2 = try objects.createBlobObject("test content", testing.allocator);
    defer obj2.deinit(testing.allocator);

    const h1 = try obj1.hash(testing.allocator);
    defer testing.allocator.free(h1);
    const h2 = try obj2.hash(testing.allocator);
    defer testing.allocator.free(h2);

    try testing.expectEqualSlices(u8, h1, h2);
}

test "blob hash: different content different hash" {
    var obj1 = try objects.createBlobObject("aaa", testing.allocator);
    defer obj1.deinit(testing.allocator);
    var obj2 = try objects.createBlobObject("bbb", testing.allocator);
    defer obj2.deinit(testing.allocator);

    const h1 = try obj1.hash(testing.allocator);
    defer testing.allocator.free(h1);
    const h2 = try obj2.hash(testing.allocator);
    defer testing.allocator.free(h2);

    try testing.expect(!std.mem.eql(u8, h1, h2));
}

// ============================================================================
// Blob store and load roundtrip
// ============================================================================

test "blob store then load: content preserved" {
    const git_dir = "/tmp/ziggit_ocp_blob_rt";
    try setupGitDir(git_dir);
    defer cleanup(git_dir);

    var obj = try objects.createBlobObject("roundtrip test\n", testing.allocator);
    defer obj.deinit(testing.allocator);

    const hash = try obj.store(git_dir, platform, testing.allocator);
    defer testing.allocator.free(hash);

    var loaded = try GitObject.load(hash, git_dir, platform, testing.allocator);
    defer loaded.deinit(testing.allocator);

    try testing.expectEqual(ObjectType.blob, loaded.type);
    try testing.expectEqualSlices(u8, "roundtrip test\n", loaded.data);
}

test "blob store then load: hash is valid 40-char hex" {
    const git_dir = "/tmp/ziggit_ocp_blob_hex";
    try setupGitDir(git_dir);
    defer cleanup(git_dir);

    var obj = try objects.createBlobObject("hex check", testing.allocator);
    defer obj.deinit(testing.allocator);

    const hash = try obj.store(git_dir, platform, testing.allocator);
    defer testing.allocator.free(hash);

    try testing.expectEqual(@as(usize, 40), hash.len);
    for (hash) |c| {
        try testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
}

// ============================================================================
// Tree creation tests
// ============================================================================

test "createTreeObject: single entry" {
    const entries = [_]TreeEntry{
        TreeEntry.init("100644", "file.txt", "3b18e512dba79e4c8300dd08aeb37f8e728b8dad"),
    };

    var obj = try objects.createTreeObject(&entries, testing.allocator);
    defer obj.deinit(testing.allocator);

    try testing.expectEqual(ObjectType.tree, obj.type);
    try testing.expect(obj.data.len > 0);
}

test "createTreeObject: multiple entries" {
    const entries = [_]TreeEntry{
        TreeEntry.init("100644", "a.txt", "3b18e512dba79e4c8300dd08aeb37f8e728b8dad"),
        TreeEntry.init("100644", "b.txt", "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391"),
    };

    var obj = try objects.createTreeObject(&entries, testing.allocator);
    defer obj.deinit(testing.allocator);

    try testing.expectEqual(ObjectType.tree, obj.type);
}

test "createTreeObject: hash is deterministic" {
    const entries = [_]TreeEntry{
        TreeEntry.init("100644", "test.txt", "3b18e512dba79e4c8300dd08aeb37f8e728b8dad"),
    };

    var obj1 = try objects.createTreeObject(&entries, testing.allocator);
    defer obj1.deinit(testing.allocator);
    var obj2 = try objects.createTreeObject(&entries, testing.allocator);
    defer obj2.deinit(testing.allocator);

    const h1 = try obj1.hash(testing.allocator);
    defer testing.allocator.free(h1);
    const h2 = try obj2.hash(testing.allocator);
    defer testing.allocator.free(h2);

    try testing.expectEqualSlices(u8, h1, h2);
}

test "tree store then load: roundtrip" {
    const git_dir = "/tmp/ziggit_ocp_tree_rt";
    try setupGitDir(git_dir);
    defer cleanup(git_dir);

    const entries = [_]TreeEntry{
        TreeEntry.init("100644", "hello.txt", "3b18e512dba79e4c8300dd08aeb37f8e728b8dad"),
    };

    var obj = try objects.createTreeObject(&entries, testing.allocator);
    defer obj.deinit(testing.allocator);

    const hash = try obj.store(git_dir, platform, testing.allocator);
    defer testing.allocator.free(hash);

    var loaded = try GitObject.load(hash, git_dir, platform, testing.allocator);
    defer loaded.deinit(testing.allocator);

    try testing.expectEqual(ObjectType.tree, loaded.type);
}

// ============================================================================
// Commit creation tests
// ============================================================================

test "createCommitObject: no parents" {
    var obj = try objects.createCommitObject(
        "4b825dc642cb6eb9a060e54bf899d69f82023000",
        &.{},
        "Test Author <test@test.com> 1000000000 +0000",
        "Test Author <test@test.com> 1000000000 +0000",
        "Initial commit",
        testing.allocator,
    );
    defer obj.deinit(testing.allocator);

    try testing.expectEqual(ObjectType.commit, obj.type);
    try testing.expect(std.mem.indexOf(u8, obj.data, "tree 4b825dc642cb6eb9a060e54bf899d69f82023000") != null);
    try testing.expect(std.mem.indexOf(u8, obj.data, "Initial commit") != null);
    // No parent line
    try testing.expect(std.mem.indexOf(u8, obj.data, "parent ") == null);
}

test "createCommitObject: one parent" {
    var obj = try objects.createCommitObject(
        "4b825dc642cb6eb9a060e54bf899d69f82023000",
        &.{"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
        "Test <test@test.com> 1000000000 +0000",
        "Test <test@test.com> 1000000000 +0000",
        "Second commit",
        testing.allocator,
    );
    defer obj.deinit(testing.allocator);

    try testing.expect(std.mem.indexOf(u8, obj.data, "parent aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") != null);
}

test "createCommitObject: two parents merge" {
    var obj = try objects.createCommitObject(
        "4b825dc642cb6eb9a060e54bf899d69f82023000",
        &.{
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        },
        "Test <test@test.com> 1000000000 +0000",
        "Test <test@test.com> 1000000000 +0000",
        "Merge commit",
        testing.allocator,
    );
    defer obj.deinit(testing.allocator);

    try testing.expect(std.mem.indexOf(u8, obj.data, "parent aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") != null);
    try testing.expect(std.mem.indexOf(u8, obj.data, "parent bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb") != null);
}

test "createCommitObject: hash is deterministic with fixed timestamp" {
    const make = struct {
        fn f() !GitObject {
            return objects.createCommitObject(
                "4b825dc642cb6eb9a060e54bf899d69f82023000",
                &.{},
                "A <a@a.com> 1000000000 +0000",
                "A <a@a.com> 1000000000 +0000",
                "Deterministic",
                testing.allocator,
            );
        }
    };

    var obj1 = try make.f();
    defer obj1.deinit(testing.allocator);
    var obj2 = try make.f();
    defer obj2.deinit(testing.allocator);

    const h1 = try obj1.hash(testing.allocator);
    defer testing.allocator.free(h1);
    const h2 = try obj2.hash(testing.allocator);
    defer testing.allocator.free(h2);

    try testing.expectEqualSlices(u8, h1, h2);
}

test "commit store then load: roundtrip preserves message" {
    const git_dir = "/tmp/ziggit_ocp_commit_rt";
    try setupGitDir(git_dir);
    defer cleanup(git_dir);

    var obj = try objects.createCommitObject(
        "4b825dc642cb6eb9a060e54bf899d69f82023000",
        &.{},
        "Test <t@t.com> 1000000000 +0000",
        "Test <t@t.com> 1000000000 +0000",
        "roundtrip msg",
        testing.allocator,
    );
    defer obj.deinit(testing.allocator);

    const hash = try obj.store(git_dir, platform, testing.allocator);
    defer testing.allocator.free(hash);

    var loaded = try GitObject.load(hash, git_dir, platform, testing.allocator);
    defer loaded.deinit(testing.allocator);

    try testing.expectEqual(ObjectType.commit, loaded.type);
    try testing.expect(std.mem.indexOf(u8, loaded.data, "roundtrip msg") != null);
}

// ============================================================================
// Load error cases
// ============================================================================

test "load: nonexistent hash returns ObjectNotFound" {
    const git_dir = "/tmp/ziggit_ocp_noobj";
    try setupGitDir(git_dir);
    defer cleanup(git_dir);

    const result = GitObject.load(
        "0000000000000000000000000000000000000000",
        git_dir,
        platform,
        testing.allocator,
    );
    try testing.expectError(error.ObjectNotFound, result);
}

// ============================================================================
// GitObject.init and hash
// ============================================================================

test "GitObject.init: blob with manual data" {
    const data = try testing.allocator.dupe(u8, "manual blob content");
    var obj = GitObject.init(ObjectType.blob, data);
    defer obj.deinit(testing.allocator);

    try testing.expectEqual(ObjectType.blob, obj.type);
    try testing.expectEqualSlices(u8, "manual blob content", obj.data);
}

test "GitObject hash matches manual SHA-1 computation" {
    // The hash should be SHA-1 of "blob 5\0hello"
    const data = try testing.allocator.dupe(u8, "hello");
    var obj = GitObject.init(ObjectType.blob, data);
    defer obj.deinit(testing.allocator);

    const hash = try obj.hash(testing.allocator);
    defer testing.allocator.free(hash);

    // Manually compute: SHA-1("blob 5\0hello")
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update("blob 5\x00");
    hasher.update("hello");
    var expected: [20]u8 = undefined;
    hasher.final(&expected);

    var expected_hex: [40]u8 = undefined;
    _ = std.fmt.bufPrint(&expected_hex, "{}", .{std.fmt.fmtSliceHexLower(&expected)}) catch unreachable;

    try testing.expectEqualSlices(u8, &expected_hex, hash);
}

// ============================================================================
// Store idempotency  
// ============================================================================

test "store same blob twice: second store succeeds idempotent" {
    const git_dir = "/tmp/ziggit_ocp_idempotent";
    try setupGitDir(git_dir);
    defer cleanup(git_dir);

    var obj1 = try objects.createBlobObject("idempotent content", testing.allocator);
    defer obj1.deinit(testing.allocator);

    const h1 = try obj1.store(git_dir, platform, testing.allocator);
    defer testing.allocator.free(h1);

    var obj2 = try objects.createBlobObject("idempotent content", testing.allocator);
    defer obj2.deinit(testing.allocator);

    const h2 = try obj2.store(git_dir, platform, testing.allocator);
    defer testing.allocator.free(h2);

    try testing.expectEqualSlices(u8, h1, h2);
}

// ============================================================================
// Binary content
// ============================================================================

test "blob with null bytes: hash and roundtrip" {
    const git_dir = "/tmp/ziggit_ocp_binary";
    try setupGitDir(git_dir);
    defer cleanup(git_dir);

    const binary_data = "\x00\x01\x02\xff\xfe\xfd\x00\x00";
    var obj = try objects.createBlobObject(binary_data, testing.allocator);
    defer obj.deinit(testing.allocator);

    const hash = try obj.store(git_dir, platform, testing.allocator);
    defer testing.allocator.free(hash);

    var loaded = try GitObject.load(hash, git_dir, platform, testing.allocator);
    defer loaded.deinit(testing.allocator);

    try testing.expectEqualSlices(u8, binary_data, loaded.data);
}

test "blob with 1KB content: roundtrip" {
    const git_dir = "/tmp/ziggit_ocp_1kb";
    try setupGitDir(git_dir);
    defer cleanup(git_dir);

    var content: [1024]u8 = undefined;
    for (&content, 0..) |*c, i| {
        c.* = @intCast(i % 256);
    }

    var obj = try objects.createBlobObject(&content, testing.allocator);
    defer obj.deinit(testing.allocator);

    const hash = try obj.store(git_dir, platform, testing.allocator);
    defer testing.allocator.free(hash);

    var loaded = try GitObject.load(hash, git_dir, platform, testing.allocator);
    defer loaded.deinit(testing.allocator);

    try testing.expectEqualSlices(u8, &content, loaded.data);
}

// ============================================================================
// Tree with executable and directory modes
// ============================================================================

test "createTreeObject: executable file mode" {
    const entries = [_]TreeEntry{
        TreeEntry.init("100755", "script.sh", "3b18e512dba79e4c8300dd08aeb37f8e728b8dad"),
    };

    var obj = try objects.createTreeObject(&entries, testing.allocator);
    defer obj.deinit(testing.allocator);

    try testing.expectEqual(ObjectType.tree, obj.type);
    // The mode "100755" should be in the binary tree data
    // (tree format stores mode as ASCII before the null-terminated name)
    try testing.expect(std.mem.indexOf(u8, obj.data, "100755") != null);
}

test "createTreeObject: subtree entry mode 40000" {
    const entries = [_]TreeEntry{
        TreeEntry.init("40000", "subdir", "4b825dc642cb6eb9a060e54bf899d69f82023000"),
    };

    var obj = try objects.createTreeObject(&entries, testing.allocator);
    defer obj.deinit(testing.allocator);

    try testing.expectEqual(ObjectType.tree, obj.type);
    try testing.expect(std.mem.indexOf(u8, obj.data, "40000") != null);
}
