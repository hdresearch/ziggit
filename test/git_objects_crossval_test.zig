// test/git_objects_crossval_test.zig
// Tests git objects module: blob/tree/commit/tag creation, hashing, store/load
// Cross-validates with git CLI
const std = @import("std");
const testing = std.testing;
const git = @import("git");

const GitObject = git.objects.GitObject;
const ObjectType = git.objects.ObjectType;

// ============================================================================
// Platform impl for native filesystem
// ============================================================================
const NativePlatform = struct {
    const fs = struct {
        fn makeDir(path: []const u8) !void {
            std.fs.makeDirAbsolute(path) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }

        fn writeFile(path: []const u8, content: []const u8) !void {
            const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
            defer file.close();
            try file.writeAll(content);
        }

        fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
            const file = try std.fs.openFileAbsolute(path, .{});
            defer file.close();
            return try file.readToEndAlloc(allocator, 100 * 1024 * 1024);
        }
    };
};

const platform = NativePlatform{};

fn tmpPath(comptime suffix: []const u8) []const u8 {
    return "/tmp/ziggit_gitobj_crossval_" ++ suffix;
}

fn cleanup(path: []const u8) void {
    std.fs.deleteTreeAbsolute(path) catch {};
}

fn initBareGitDir(path: []const u8) !void {
    std.fs.deleteTreeAbsolute(path) catch {};
    std.fs.makeDirAbsolute(path) catch {};

    const dirs = [_][]const u8{
        "/objects", "/objects/pack", "/refs", "/refs/heads", "/refs/tags",
    };
    for (dirs) |d| {
        const full = try std.fmt.allocPrint(testing.allocator, "{s}{s}", .{ path, d });
        defer testing.allocator.free(full);
        std.fs.makeDirAbsolute(full) catch {};
    }

    const head_path = try std.fmt.allocPrint(testing.allocator, "{s}/HEAD", .{path});
    defer testing.allocator.free(head_path);
    const hf = try std.fs.createFileAbsolute(head_path, .{ .truncate = true });
    defer hf.close();
    try hf.writeAll("ref: refs/heads/master\n");
}

fn execGit(git_dir: []const u8, args: []const []const u8) ![]u8 {
    var argv = std.ArrayList([]const u8).init(testing.allocator);
    defer argv.deinit();
    try argv.append("git");

    // Derive work tree from .git dir
    const work_tree = if (std.mem.endsWith(u8, git_dir, "/.git"))
        git_dir[0 .. git_dir.len - 5]
    else
        git_dir;

    try argv.append("--git-dir");
    try argv.append(git_dir);
    try argv.append("--work-tree");
    try argv.append(work_tree);
    for (args) |a| try argv.append(a);

    var child = std.process.Child.init(argv.items, testing.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const stdout = try child.stdout.?.reader().readAllAlloc(testing.allocator, 1024 * 1024);
    const stderr = try child.stderr.?.reader().readAllAlloc(testing.allocator, 1024 * 1024);
    defer testing.allocator.free(stderr);
    const term = try child.wait();
    if (term.Exited != 0) {
        testing.allocator.free(stdout);
        return error.GitCommandFailed;
    }
    return stdout;
}

// ============================================================================
// Blob object tests
// ============================================================================

test "blob: hash matches git hash-object" {
    // Create blob object and verify hash matches git
    const content = "Hello, World!\n";
    const obj = git.objects.GitObject.init(.blob, content);

    const hash_hex = try obj.hash(testing.allocator);
    defer testing.allocator.free(hash_hex);

    // Known SHA-1 for "blob 14\0Hello, World!\n"
    // Let's verify with manual computation
    var hasher = std.crypto.hash.Sha1.init(.{});
    const header = try std.fmt.allocPrint(testing.allocator, "blob {}\x00", .{content.len});
    defer testing.allocator.free(header);
    hasher.update(header);
    hasher.update(content);
    var expected_hash: [20]u8 = undefined;
    hasher.final(&expected_hash);

    var expected_hex: [40]u8 = undefined;
    _ = std.fmt.bufPrint(&expected_hex, "{}", .{std.fmt.fmtSliceHexLower(&expected_hash)}) catch unreachable;

    try testing.expectEqualStrings(&expected_hex, hash_hex);
}

test "blob: store and load roundtrip" {
    const path = tmpPath("blob_rt");
    cleanup(path);
    defer cleanup(path);

    try initBareGitDir(path);

    const content = "test blob content\n";
    const obj = GitObject.init(.blob, content);

    const hash_str = try obj.store(path, platform, testing.allocator);
    defer testing.allocator.free(hash_str);

    // Load it back
    var loaded = try GitObject.load(hash_str, path, platform, testing.allocator);
    defer loaded.deinit(testing.allocator);

    try testing.expectEqual(ObjectType.blob, loaded.obj_type);
    try testing.expectEqualStrings(content, loaded.data);
}

test "blob: stored object readable by git" {
    const path = tmpPath("blob_git");
    const work = tmpPath("blob_git_work");
    cleanup(path);
    cleanup(work);
    defer cleanup(path);
    defer cleanup(work);

    // Create a proper git repo structure
    std.fs.makeDirAbsolute(work) catch {};
    const git_dir = try std.fmt.allocPrint(testing.allocator, "{s}/.git", .{work});
    defer testing.allocator.free(git_dir);
    try initBareGitDir(git_dir);

    const content = "Hello from ziggit blob!\n";
    const obj = GitObject.init(.blob, content);

    const hash_str = try obj.store(git_dir, platform, testing.allocator);
    defer testing.allocator.free(hash_str);

    // git cat-file -p should show the content
    const git_out = try execGit(git_dir, &.{ "cat-file", "-p", hash_str });
    defer testing.allocator.free(git_out);
    try testing.expectEqualStrings(content, git_out);

    // git cat-file -t should show "blob"
    const type_out = try execGit(git_dir, &.{ "cat-file", "-t", hash_str });
    defer testing.allocator.free(type_out);
    try testing.expectEqualStrings("blob\n", type_out);
}

// ============================================================================
// Tree object tests
// ============================================================================

test "tree: create and hash" {
    const entry = git.objects.TreeEntry.init("100644", "hello.txt", "8ab686eafeb1f44702738c8b0f24f2567c36da6d");
    const entries = [_]git.objects.TreeEntry{entry};
    var obj = try git.objects.createTreeObject(&entries, testing.allocator);
    defer obj.deinit(testing.allocator);

    try testing.expectEqual(ObjectType.tree, obj.obj_type);

    const hash = try obj.hash(testing.allocator);
    defer testing.allocator.free(hash);
    try testing.expectEqual(@as(usize, 40), hash.len);
}

test "tree: store and load roundtrip" {
    const path = tmpPath("tree_rt");
    cleanup(path);
    defer cleanup(path);
    try initBareGitDir(path);

    // First store a blob
    const blob_content = "file content\n";
    const blob_obj = GitObject.init(.blob, blob_content);
    const blob_hash = try blob_obj.store(path, platform, testing.allocator);
    defer testing.allocator.free(blob_hash);

    // Create tree referencing blob
    const entry = git.objects.TreeEntry.init("100644", "file.txt", blob_hash);
    const entries = [_]git.objects.TreeEntry{entry};
    var tree_obj = try git.objects.createTreeObject(&entries, testing.allocator);
    defer tree_obj.deinit(testing.allocator);

    const tree_hash = try tree_obj.store(path, platform, testing.allocator);
    defer testing.allocator.free(tree_hash);

    // Load tree back
    var loaded = try GitObject.load(tree_hash, path, platform, testing.allocator);
    defer loaded.deinit(testing.allocator);

    try testing.expectEqual(ObjectType.tree, loaded.obj_type);
    // Tree data is binary - just check it's non-empty
    try testing.expect(loaded.data.len > 0);
}

// ============================================================================
// Commit object tests
// ============================================================================

test "commit: create with parent" {
    const tree_hash = "4b825dc642cb6eb9a060e54bf899d69f82623715"; // empty tree
    const parent = "abc1234567890abcdef1234567890abcdef123456";
    const parents = [_][]const u8{parent};

    var obj = try git.objects.createCommitObject(
        tree_hash,
        &parents,
        "Author <a@b.com> 1234567890 +0000",
        "Committer <c@d.com> 1234567890 +0000",
        "test commit",
        testing.allocator,
    );
    defer obj.deinit(testing.allocator);

    try testing.expectEqual(ObjectType.commit, obj.obj_type);
    try testing.expect(std.mem.indexOf(u8, obj.data, "tree 4b825dc642cb6eb9a060e54bf899d69f82623715") != null);
    try testing.expect(std.mem.indexOf(u8, obj.data, "parent abc1234567890abcdef1234567890abcdef123456") != null);
    try testing.expect(std.mem.indexOf(u8, obj.data, "test commit") != null);
}

test "commit: create without parent (initial commit)" {
    const tree_hash = "4b825dc642cb6eb9a060e54bf899d69f82623715";
    const no_parents = [_][]const u8{};

    var obj = try git.objects.createCommitObject(
        tree_hash,
        &no_parents,
        "Author <a@b.com> 1234567890 +0000",
        "Committer <c@d.com> 1234567890 +0000",
        "initial commit",
        testing.allocator,
    );
    defer obj.deinit(testing.allocator);

    try testing.expect(std.mem.indexOf(u8, obj.data, "parent") == null);
    try testing.expect(std.mem.indexOf(u8, obj.data, "initial commit") != null);
}

// ============================================================================
// Object type enum
// ============================================================================

test "ObjectType: all types roundtrip via string" {
    const types = [_]ObjectType{ .blob, .tree, .commit, .tag };
    for (types) |t| {
        const s = t.toString();
        const parsed = ObjectType.fromString(s);
        try testing.expect(parsed != null);
        try testing.expectEqual(t, parsed.?);
    }
}

test "ObjectType: unknown string returns null" {
    try testing.expect(ObjectType.fromString("") == null);
    try testing.expect(ObjectType.fromString("invalid") == null);
    try testing.expect(ObjectType.fromString("BLOB") == null);
}

// ============================================================================
// Empty blob (known hash)
// ============================================================================

test "blob: empty content has known SHA-1" {
    // git hash-object -t blob --stdin <<< '' gives e69de29bb2d1d6434b8b29ae775ad8c2e48c5391
    const obj = GitObject.init(.blob, "");
    const hash = try obj.hash(testing.allocator);
    defer testing.allocator.free(hash);
    try testing.expectEqualStrings("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391", hash);
}

// ============================================================================
// Large blob
// ============================================================================

test "blob: 64KB content store/load roundtrip" {
    const path = tmpPath("blob_64k");
    cleanup(path);
    defer cleanup(path);
    try initBareGitDir(path);

    // Create 64KB of content
    const content = try testing.allocator.alloc(u8, 65536);
    defer testing.allocator.free(content);
    for (content, 0..) |*c, i| c.* = @intCast(i % 256);

    const obj = GitObject.init(.blob, content);
    const hash_str = try obj.store(path, platform, testing.allocator);
    defer testing.allocator.free(hash_str);

    // Load back
    var loaded = try GitObject.load(hash_str, path, platform, testing.allocator);
    defer loaded.deinit(testing.allocator);

    try testing.expectEqualSlices(u8, content, loaded.data);
}
