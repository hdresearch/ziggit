// test/objects_hash_and_store_test.zig
// Tests for git object hashing, storage, and loading via internal git module.
// Verifies: SHA-1 correctness, zlib compression, object format, cross-validation with git CLI
const std = @import("std");
const git = @import("git");
const testing = std.testing;

const GitObject = git.objects.GitObject;
const ObjectType = git.objects.ObjectType;

// ============================================================================
// ObjectType
// ============================================================================

test "ObjectType.toString returns correct strings" {
    try testing.expectEqualStrings("blob", ObjectType.blob.toString());
    try testing.expectEqualStrings("tree", ObjectType.tree.toString());
    try testing.expectEqualStrings("commit", ObjectType.commit.toString());
    try testing.expectEqualStrings("tag", ObjectType.tag.toString());
}

test "ObjectType.fromString parses valid types" {
    try testing.expectEqual(ObjectType.blob, ObjectType.fromString("blob").?);
    try testing.expectEqual(ObjectType.tree, ObjectType.fromString("tree").?);
    try testing.expectEqual(ObjectType.commit, ObjectType.fromString("commit").?);
    try testing.expectEqual(ObjectType.tag, ObjectType.fromString("tag").?);
}

test "ObjectType.fromString returns null for invalid types" {
    try testing.expect(ObjectType.fromString("invalid") == null);
    try testing.expect(ObjectType.fromString("") == null);
    try testing.expect(ObjectType.fromString("BLOB") == null);
}

// ============================================================================
// GitObject.hash - SHA-1 correctness
// ============================================================================

test "GitObject.hash for empty blob matches known value" {
    // git hash-object -t blob --stdin < /dev/null = e69de29bb2d1d6434b8b29ae775ad8c2e48c5391
    const obj = GitObject.init(.blob, "");
    const hash = try obj.hash(testing.allocator);
    defer testing.allocator.free(hash);
    try testing.expectEqualStrings("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391", hash);
}

test "GitObject.hash for 'hello\\n' blob matches known value" {
    // echo -n "hello\n" | git hash-object -t blob --stdin = ce013625030ba8dba906f756967f9e9ca394464a
    const obj = GitObject.init(.blob, "hello\n");
    const hash = try obj.hash(testing.allocator);
    defer testing.allocator.free(hash);
    try testing.expectEqualStrings("ce013625030ba8dba906f756967f9e9ca394464a", hash);
}

test "GitObject.hash for 'Hello, World!' blob" {
    // printf 'Hello, World!' | git hash-object --stdin
    const obj = GitObject.init(.blob, "Hello, World!");
    const hash = try obj.hash(testing.allocator);
    defer testing.allocator.free(hash);
    // Verify it's 40 hex chars
    try testing.expectEqual(@as(usize, 40), hash.len);
    for (hash) |c| {
        try testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
}

test "GitObject.hash is deterministic" {
    const obj = GitObject.init(.blob, "test data\n");
    const hash1 = try obj.hash(testing.allocator);
    defer testing.allocator.free(hash1);
    const hash2 = try obj.hash(testing.allocator);
    defer testing.allocator.free(hash2);
    try testing.expectEqualStrings(hash1, hash2);
}

test "GitObject.hash differs for different content" {
    const obj1 = GitObject.init(.blob, "content A");
    const obj2 = GitObject.init(.blob, "content B");
    const hash1 = try obj1.hash(testing.allocator);
    defer testing.allocator.free(hash1);
    const hash2 = try obj2.hash(testing.allocator);
    defer testing.allocator.free(hash2);
    try testing.expect(!std.mem.eql(u8, hash1, hash2));
}

test "GitObject.hash differs for same content different types" {
    const obj1 = GitObject.init(.blob, "same content");
    const obj2 = GitObject.init(.commit, "same content");
    const hash1 = try obj1.hash(testing.allocator);
    defer testing.allocator.free(hash1);
    const hash2 = try obj2.hash(testing.allocator);
    defer testing.allocator.free(hash2);
    try testing.expect(!std.mem.eql(u8, hash1, hash2));
}

// ============================================================================
// createBlobObject
// ============================================================================

test "createBlobObject creates correct type" {
    const obj = try git.objects.createBlobObject("test", testing.allocator);
    defer obj.deinit(testing.allocator);
    try testing.expectEqual(ObjectType.blob, obj.type);
    try testing.expectEqualStrings("test", obj.data);
}

test "createBlobObject with empty data" {
    const obj = try git.objects.createBlobObject("", testing.allocator);
    defer obj.deinit(testing.allocator);
    try testing.expectEqual(ObjectType.blob, obj.type);
    try testing.expectEqualStrings("", obj.data);
}

test "createBlobObject with binary data" {
    const data = "\x00\x01\x02\x03\xff\xfe\xfd";
    const obj = try git.objects.createBlobObject(data, testing.allocator);
    defer obj.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, data, obj.data);
}

// ============================================================================
// createCommitObject
// ============================================================================

test "createCommitObject with no parents" {
    const obj = try git.objects.createCommitObject(
        "abc123def456abc123def456abc123def456abc1",
        &[_][]const u8{},
        "Test Author <test@example.com> 1234567890 +0000",
        "Test Author <test@example.com> 1234567890 +0000",
        "Initial commit",
        testing.allocator,
    );
    defer obj.deinit(testing.allocator);

    try testing.expectEqual(ObjectType.commit, obj.type);
    try testing.expect(std.mem.indexOf(u8, obj.data, "tree abc123def456abc123def456abc123def456abc1") != null);
    try testing.expect(std.mem.indexOf(u8, obj.data, "Initial commit") != null);
    // No parent line for root commit
    try testing.expect(std.mem.indexOf(u8, obj.data, "parent") == null);
}

test "createCommitObject with one parent" {
    const parents = [_][]const u8{"def456abc123def456abc123def456abc123def456"};
    const obj = try git.objects.createCommitObject(
        "abc123def456abc123def456abc123def456abc1",
        &parents,
        "Author <a@b.com> 1234567890 +0000",
        "Author <a@b.com> 1234567890 +0000",
        "Second commit",
        testing.allocator,
    );
    defer obj.deinit(testing.allocator);

    try testing.expect(std.mem.indexOf(u8, obj.data, "parent def456abc123def456abc123def456abc123def456") != null);
}

test "createCommitObject with multiple parents (merge)" {
    const parents = [_][]const u8{
        "1111111111111111111111111111111111111111",
        "2222222222222222222222222222222222222222",
    };
    const obj = try git.objects.createCommitObject(
        "abc123def456abc123def456abc123def456abc1",
        &parents,
        "Author <a@b.com> 1234567890 +0000",
        "Author <a@b.com> 1234567890 +0000",
        "Merge commit",
        testing.allocator,
    );
    defer obj.deinit(testing.allocator);

    try testing.expect(std.mem.indexOf(u8, obj.data, "parent 1111111111111111111111111111111111111111") != null);
    try testing.expect(std.mem.indexOf(u8, obj.data, "parent 2222222222222222222222222222222222222222") != null);
}

// ============================================================================
// GitObject.store + load round-trip
// ============================================================================

fn tmpPath(comptime suffix: []const u8) []const u8 {
    return "/tmp/ziggit_obj_hash_store_" ++ suffix;
}

fn cleanup(path: []const u8) void {
    std.fs.deleteTreeAbsolute(path) catch {};
}

fn mkdirAbs(path: []const u8) !void {
    std.fs.makeDirAbsolute(path) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
}

const FsImpl = struct {
    pub fn readFile(_: @This(), allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        const file = std.fs.openFileAbsolute(path, .{}) catch |e| {
            return switch (e) {
                error.FileNotFound => error.FileNotFound,
                else => e,
            };
        };
        defer file.close();
        return try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    }

    pub fn fileExists(_: @This(), path: []const u8) bool {
        std.fs.accessAbsolute(path, .{}) catch return false;
        return true;
    }

    pub fn writeFile(_: @This(), path: []const u8, data: []const u8) !void {
        // Ensure parent directory exists
        if (std.fs.path.dirname(path)) |dir| {
            std.fs.makeDirAbsolute(dir) catch |e| switch (e) {
                error.PathAlreadyExists => {},
                else => return e,
            };
        }
        const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(data);
    }

    pub fn makeDir(_: @This(), path: []const u8) error{AlreadyExists}!void {
        std.fs.makeDirAbsolute(path) catch |e| switch (e) {
            error.PathAlreadyExists => return error.AlreadyExists,
            else => return error.AlreadyExists, // Simplify error set
        };
    }

    pub fn readDir(_: @This(), allocator: std.mem.Allocator, path: []const u8) ![]const std.fs.Dir.Entry {
        _ = allocator;
        _ = path;
        return &[_]std.fs.Dir.Entry{};
    }
};

const TestPlatform = struct {
    fs: FsImpl = .{},
};

fn setupGitDir(comptime suffix: []const u8) ![]const u8 {
    const base = tmpPath(suffix);
    cleanup(base);
    const git_dir = try std.fmt.allocPrint(testing.allocator, "{s}/.git", .{base});
    try mkdirAbs(base);
    try mkdirAbs(git_dir);
    const obj_dir = try std.fmt.allocPrint(testing.allocator, "{s}/objects", .{git_dir});
    defer testing.allocator.free(obj_dir);
    try mkdirAbs(obj_dir);
    return git_dir;
}

const platform = TestPlatform{};

test "store and load blob round-trip" {
    const git_dir = try setupGitDir("store_load_blob");
    defer {
        testing.allocator.free(git_dir);
        cleanup(tmpPath("store_load_blob"));
    }

    const obj = GitObject.init(.blob, "round trip test\n");
    const hash = try obj.store(git_dir, platform, testing.allocator);
    defer testing.allocator.free(hash);

    const loaded = try GitObject.load(hash, git_dir, platform, testing.allocator);
    defer loaded.deinit(testing.allocator);

    try testing.expectEqual(ObjectType.blob, loaded.type);
    try testing.expectEqualStrings("round trip test\n", loaded.data);
}

test "store blob, verify object file exists" {
    const git_dir = try setupGitDir("store_exists");
    defer {
        testing.allocator.free(git_dir);
        cleanup(tmpPath("store_exists"));
    }

    const obj = GitObject.init(.blob, "exists check\n");
    const hash = try obj.store(git_dir, platform, testing.allocator);
    defer testing.allocator.free(hash);

    // Object file should exist at .git/objects/XX/XXXXX...
    const obj_path = try std.fmt.allocPrint(testing.allocator, "{s}/objects/{s}/{s}", .{ git_dir, hash[0..2], hash[2..] });
    defer testing.allocator.free(obj_path);
    try std.fs.accessAbsolute(obj_path, .{});
}

test "store same content twice produces same hash" {
    const git_dir = try setupGitDir("store_idempotent");
    defer {
        testing.allocator.free(git_dir);
        cleanup(tmpPath("store_idempotent"));
    }

    const obj = GitObject.init(.blob, "same content\n");
    const hash1 = try obj.store(git_dir, platform, testing.allocator);
    defer testing.allocator.free(hash1);
    const hash2 = try obj.store(git_dir, platform, testing.allocator);
    defer testing.allocator.free(hash2);

    try testing.expectEqualStrings(hash1, hash2);
}

test "store commit object and load it back" {
    const git_dir = try setupGitDir("store_load_commit");
    defer {
        testing.allocator.free(git_dir);
        cleanup(tmpPath("store_load_commit"));
    }

    const commit_data = "tree 0000000000000000000000000000000000000000\nauthor T <t@t.com> 1234567890 +0000\ncommitter T <t@t.com> 1234567890 +0000\n\ntest commit\n";
    const obj = GitObject.init(.commit, commit_data);
    const hash = try obj.store(git_dir, platform, testing.allocator);
    defer testing.allocator.free(hash);

    const loaded = try GitObject.load(hash, git_dir, platform, testing.allocator);
    defer loaded.deinit(testing.allocator);

    try testing.expectEqual(ObjectType.commit, loaded.type);
    try testing.expect(std.mem.indexOf(u8, loaded.data, "test commit") != null);
}

test "load nonexistent object returns error" {
    const git_dir = try setupGitDir("load_nonexist");
    defer {
        testing.allocator.free(git_dir);
        cleanup(tmpPath("load_nonexist"));
    }

    const result = GitObject.load("0000000000000000000000000000000000000000", git_dir, platform, testing.allocator);
    try testing.expectError(error.ObjectNotFound, result);
}

// ============================================================================
// SHA-1 cross-validation with known git values
// ============================================================================

test "blob hash matches printf 'blob N\\0content' | sha1sum" {
    // "blob 4\0test" should hash to a known value
    // We can verify by computing ourselves
    const content = "test";
    const header = "blob 4\x00";
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(header);
    hasher.update(content);
    var expected: [20]u8 = undefined;
    hasher.final(&expected);
    var expected_hex: [40]u8 = undefined;
    _ = std.fmt.bufPrint(&expected_hex, "{}", .{std.fmt.fmtSliceHexLower(&expected)}) catch unreachable;

    const obj = GitObject.init(.blob, content);
    const hash = try obj.hash(testing.allocator);
    defer testing.allocator.free(hash);

    try testing.expectEqualStrings(&expected_hex, hash);
}

test "blob hash for 'test' matches git hash-object" {
    // Compute what git hash-object would return for "test" (no newline)
    // blob 4\0test → sha1
    const obj = GitObject.init(.blob, "test");
    const hash = try obj.hash(testing.allocator);
    defer testing.allocator.free(hash);

    // Cross-check with direct SHA-1 computation
    const full_content = "blob 4\x00test";
    var sha: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(full_content, &sha, .{});
    var hex: [40]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{}", .{std.fmt.fmtSliceHexLower(&sha)}) catch unreachable;

    try testing.expectEqualStrings(&hex, hash);
}

// ============================================================================
// applyDelta
// ============================================================================

test "applyDelta: copy instruction" {
    // Build a simple delta that copies the entire base
    const base = "Hello, World!";
    
    // Delta format:
    // - base_size varint (13)
    // - result_size varint (13)
    // - copy instruction: 0x90 (copy from offset 0, size from base) 
    //   bit 7 set = copy, bit 4 = size1 byte present
    //   Actually let's use a simpler approach: copy offset=0, size=13
    //   0x80 | 0x01 | 0x10 = 0x91 → offset_byte=0, size_byte=13
    var delta: [5]u8 = undefined;
    delta[0] = 13; // base size
    delta[1] = 13; // result size
    delta[2] = 0x80 | 0x01 | 0x10; // copy instruction: offset1 + size1
    delta[3] = 0; // offset = 0
    delta[4] = 13; // size = 13

    const result = try git.objects.applyDelta(base, &delta, testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings(base, result);
}

test "applyDelta: insert instruction" {
    // Delta that inserts literal data
    const base = "unused base";
    
    // Delta: base_size=11, result_size=5, insert 5 bytes "hello"
    var delta: [8]u8 = undefined;
    delta[0] = 11; // base size
    delta[1] = 5; // result size
    delta[2] = 5; // insert 5 bytes (bit 7 = 0, so insert)
    delta[3] = 'h';
    delta[4] = 'e';
    delta[5] = 'l';
    delta[6] = 'l';
    delta[7] = 'o';

    const result = try git.objects.applyDelta(base, &delta, testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("hello", result);
}
