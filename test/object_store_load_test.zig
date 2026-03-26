// test/object_store_load_test.zig - Tests for git object store/load roundtrip
// Tests that objects stored via the internal git module can be loaded back,
// and that git CLI can read objects stored by ziggit (and vice versa).
const std = @import("std");
const testing = std.testing;
const git = @import("git");

// Minimal platform implementation matching the anytype interface used by git.objects
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

// ============================================================================
// Store + Load roundtrip (blob)
// ============================================================================

test "store blob then load: content matches" {
    const tmp = "/tmp/ziggit_obj_sl_blob";
    try setupGitDir(tmp);
    defer std.fs.deleteTreeAbsolute(tmp) catch {};

    const git_dir = tmp ++ "/.git";
    const data = "hello from ziggit\n";
    const obj = git.objects.GitObject.init(.blob, data);
    const hash = try obj.store(git_dir, platform, testing.allocator);
    defer testing.allocator.free(hash);

    try testing.expect(hash.len == 40);

    var loaded = try git.objects.GitObject.load(hash, git_dir, platform, testing.allocator);
    defer loaded.deinit(testing.allocator);

    try testing.expect(loaded.type == .blob);
    try testing.expectEqualStrings(data, loaded.data);
}

test "store blob then load: hash is stable" {
    const tmp = "/tmp/ziggit_obj_sl_hash";
    try setupGitDir(tmp);
    defer std.fs.deleteTreeAbsolute(tmp) catch {};

    const git_dir = tmp ++ "/.git";
    const data = "deterministic test";
    const obj = git.objects.GitObject.init(.blob, data);

    const expected_hash = try obj.hash(testing.allocator);
    defer testing.allocator.free(expected_hash);

    const stored_hash = try obj.store(git_dir, platform, testing.allocator);
    defer testing.allocator.free(stored_hash);

    try testing.expectEqualStrings(expected_hash, stored_hash);
}

test "store blob: git cat-file can read it" {
    const tmp = "/tmp/ziggit_obj_sl_catfile";
    try setupGitDir(tmp);
    defer std.fs.deleteTreeAbsolute(tmp) catch {};

    const git_dir = tmp ++ "/.git";
    const data = "readable by git\n";
    const obj = git.objects.GitObject.init(.blob, data);
    const hash = try obj.store(git_dir, platform, testing.allocator);
    defer testing.allocator.free(hash);

    const output = try runCmd(&.{ "git", "-C", tmp, "cat-file", "-p", hash });
    defer testing.allocator.free(output);

    try testing.expectEqualStrings(data, output);
}

test "store blob: git cat-file -t reports blob" {
    const tmp = "/tmp/ziggit_obj_sl_type";
    try setupGitDir(tmp);
    defer std.fs.deleteTreeAbsolute(tmp) catch {};

    const git_dir = tmp ++ "/.git";
    const obj = git.objects.GitObject.init(.blob, "test");
    const hash = try obj.store(git_dir, platform, testing.allocator);
    defer testing.allocator.free(hash);

    const output = try runCmd(&.{ "git", "-C", tmp, "cat-file", "-t", hash });
    defer testing.allocator.free(output);

    try testing.expectEqualStrings("blob", std.mem.trim(u8, output, " \t\n\r"));
}

test "store blob: git cat-file -s reports correct size" {
    const tmp = "/tmp/ziggit_obj_sl_size";
    try setupGitDir(tmp);
    defer std.fs.deleteTreeAbsolute(tmp) catch {};

    const git_dir = tmp ++ "/.git";
    const data = "exactly 10";
    const obj = git.objects.GitObject.init(.blob, data);
    const hash = try obj.store(git_dir, platform, testing.allocator);
    defer testing.allocator.free(hash);

    const output = try runCmd(&.{ "git", "-C", tmp, "cat-file", "-s", hash });
    defer testing.allocator.free(output);

    try testing.expectEqualStrings("10", std.mem.trim(u8, output, " \t\n\r"));
}

test "store empty blob: roundtrip" {
    const tmp = "/tmp/ziggit_obj_sl_empty";
    try setupGitDir(tmp);
    defer std.fs.deleteTreeAbsolute(tmp) catch {};

    const git_dir = tmp ++ "/.git";
    const obj = git.objects.GitObject.init(.blob, "");
    const hash = try obj.store(git_dir, platform, testing.allocator);
    defer testing.allocator.free(hash);

    try testing.expectEqualStrings("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391", hash);

    var loaded = try git.objects.GitObject.load(hash, git_dir, platform, testing.allocator);
    defer loaded.deinit(testing.allocator);

    try testing.expect(loaded.type == .blob);
    try testing.expect(loaded.data.len == 0);
}

test "store binary blob with null bytes: roundtrip" {
    const tmp = "/tmp/ziggit_obj_sl_binary";
    try setupGitDir(tmp);
    defer std.fs.deleteTreeAbsolute(tmp) catch {};

    const git_dir = tmp ++ "/.git";
    const data = "ab\x00cd\x00\x01\x02\xff";
    const obj = git.objects.GitObject.init(.blob, data);
    const hash = try obj.store(git_dir, platform, testing.allocator);
    defer testing.allocator.free(hash);

    var loaded = try git.objects.GitObject.load(hash, git_dir, platform, testing.allocator);
    defer loaded.deinit(testing.allocator);

    try testing.expect(loaded.type == .blob);
    try testing.expectEqualSlices(u8, data, loaded.data);
}

// ============================================================================
// Store + Load roundtrip (commit)
// ============================================================================

test "store commit then load: content matches" {
    const tmp = "/tmp/ziggit_obj_sl_commit";
    try setupGitDir(tmp);
    defer std.fs.deleteTreeAbsolute(tmp) catch {};

    const git_dir = tmp ++ "/.git";

    var commit = try git.objects.createCommitObject(
        "4b825dc642cb6eb9a060e54bf899d69f7e6053e0",
        &[_][]const u8{},
        "Test <test@example.com> 1700000000 +0000",
        "Test <test@example.com> 1700000000 +0000",
        "test commit message",
        testing.allocator,
    );
    defer commit.deinit(testing.allocator);

    const hash = try commit.store(git_dir, platform, testing.allocator);
    defer testing.allocator.free(hash);

    var loaded = try git.objects.GitObject.load(hash, git_dir, platform, testing.allocator);
    defer loaded.deinit(testing.allocator);

    try testing.expect(loaded.type == .commit);
    try testing.expect(std.mem.indexOf(u8, loaded.data, "test commit message") != null);
    try testing.expect(std.mem.indexOf(u8, loaded.data, "tree 4b825dc642cb6eb9a060e54bf899d69f7e6053e0") != null);
}

test "store commit: git cat-file -t reports commit" {
    const tmp = "/tmp/ziggit_obj_sl_commit_type";
    try setupGitDir(tmp);
    defer std.fs.deleteTreeAbsolute(tmp) catch {};

    const git_dir = tmp ++ "/.git";
    var commit = try git.objects.createCommitObject(
        "4b825dc642cb6eb9a060e54bf899d69f7e6053e0",
        &[_][]const u8{},
        "A <a@b.com> 1 +0000",
        "A <a@b.com> 1 +0000",
        "msg",
        testing.allocator,
    );
    defer commit.deinit(testing.allocator);

    const hash = try commit.store(git_dir, platform, testing.allocator);
    defer testing.allocator.free(hash);

    const output = try runCmd(&.{ "git", "-C", tmp, "cat-file", "-t", hash });
    defer testing.allocator.free(output);
    try testing.expectEqualStrings("commit", std.mem.trim(u8, output, " \t\n\r"));
}

// ============================================================================
// Store + Load roundtrip (tree)
// ============================================================================

test "store tree then load: content matches" {
    const tmp = "/tmp/ziggit_obj_sl_tree";
    try setupGitDir(tmp);
    defer std.fs.deleteTreeAbsolute(tmp) catch {};

    const git_dir = tmp ++ "/.git";
    const entries = &[_]git.objects.TreeEntry{
        git.objects.TreeEntry.init("100644", "file.txt", "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391"),
    };

    var tree = try git.objects.createTreeObject(entries, testing.allocator);
    defer tree.deinit(testing.allocator);

    const hash = try tree.store(git_dir, platform, testing.allocator);
    defer testing.allocator.free(hash);

    var loaded = try git.objects.GitObject.load(hash, git_dir, platform, testing.allocator);
    defer loaded.deinit(testing.allocator);

    try testing.expect(loaded.type == .tree);
    try testing.expect(std.mem.indexOf(u8, loaded.data, "file.txt") != null);
}

test "store tree: git ls-tree can parse it" {
    const tmp = "/tmp/ziggit_obj_sl_lstree";
    try setupGitDir(tmp);
    defer std.fs.deleteTreeAbsolute(tmp) catch {};

    const git_dir = tmp ++ "/.git";

    // First store the empty blob so git can find it
    const blob = git.objects.GitObject.init(.blob, "");
    const blob_hash = try blob.store(git_dir, platform, testing.allocator);
    defer testing.allocator.free(blob_hash);

    const entries = &[_]git.objects.TreeEntry{
        git.objects.TreeEntry.init("100644", "empty.txt", "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391"),
    };

    var tree = try git.objects.createTreeObject(entries, testing.allocator);
    defer tree.deinit(testing.allocator);

    const hash = try tree.store(git_dir, platform, testing.allocator);
    defer testing.allocator.free(hash);

    const output = try runCmd(&.{ "git", "-C", tmp, "ls-tree", hash });
    defer testing.allocator.free(output);

    try testing.expect(std.mem.indexOf(u8, output, "empty.txt") != null);
    try testing.expect(std.mem.indexOf(u8, output, "100644") != null);
}

// ============================================================================
// Load git-created objects
// ============================================================================

test "load git-created blob" {
    const tmp = "/tmp/ziggit_obj_sl_gitblob";
    std.fs.deleteTreeAbsolute(tmp) catch {};
    defer std.fs.deleteTreeAbsolute(tmp) catch {};

    _ = try runCmd(&.{ "git", "init", "-q", tmp });

    {
        const f = try std.fs.createFileAbsolute(tmp ++ "/test.txt", .{});
        defer f.close();
        try f.writeAll("git content\n");
    }

    const hash_output = try runCmd(&.{ "git", "-C", tmp, "hash-object", "-w", "test.txt" });
    defer testing.allocator.free(hash_output);
    const hash = std.mem.trim(u8, hash_output, " \t\n\r");

    const git_dir = tmp ++ "/.git";
    var loaded = try git.objects.GitObject.load(hash, git_dir, platform, testing.allocator);
    defer loaded.deinit(testing.allocator);

    try testing.expect(loaded.type == .blob);
    try testing.expectEqualStrings("git content\n", loaded.data);
}

test "load git-created commit" {
    const tmp = "/tmp/ziggit_obj_sl_gitcommit";
    std.fs.deleteTreeAbsolute(tmp) catch {};
    defer std.fs.deleteTreeAbsolute(tmp) catch {};

    _ = try runCmd(&.{ "git", "init", "-q", tmp });
    _ = try runCmd(&.{ "git", "-C", tmp, "config", "user.email", "t@t.com" });
    _ = try runCmd(&.{ "git", "-C", tmp, "config", "user.name", "T" });

    {
        const f = try std.fs.createFileAbsolute(tmp ++ "/f.txt", .{});
        defer f.close();
        try f.writeAll("data\n");
    }
    _ = try runCmd(&.{ "git", "-C", tmp, "add", "f.txt" });
    _ = try runCmd(&.{ "git", "-C", tmp, "commit", "-q", "-m", "initial" });

    const hash_output = try runCmd(&.{ "git", "-C", tmp, "rev-parse", "HEAD" });
    defer testing.allocator.free(hash_output);
    const hash = std.mem.trim(u8, hash_output, " \t\n\r");

    const git_dir = tmp ++ "/.git";
    var loaded = try git.objects.GitObject.load(hash, git_dir, platform, testing.allocator);
    defer loaded.deinit(testing.allocator);

    try testing.expect(loaded.type == .commit);
    try testing.expect(std.mem.indexOf(u8, loaded.data, "initial") != null);
    try testing.expect(std.mem.indexOf(u8, loaded.data, "tree ") != null);
}

test "load git-created tree" {
    const tmp = "/tmp/ziggit_obj_sl_gittree";
    std.fs.deleteTreeAbsolute(tmp) catch {};
    defer std.fs.deleteTreeAbsolute(tmp) catch {};

    _ = try runCmd(&.{ "git", "init", "-q", tmp });
    _ = try runCmd(&.{ "git", "-C", tmp, "config", "user.email", "t@t.com" });
    _ = try runCmd(&.{ "git", "-C", tmp, "config", "user.name", "T" });

    {
        const f = try std.fs.createFileAbsolute(tmp ++ "/a.txt", .{});
        defer f.close();
        try f.writeAll("aaa\n");
    }
    {
        const f = try std.fs.createFileAbsolute(tmp ++ "/b.txt", .{});
        defer f.close();
        try f.writeAll("bbb\n");
    }
    _ = try runCmd(&.{ "git", "-C", tmp, "add", "." });
    _ = try runCmd(&.{ "git", "-C", tmp, "commit", "-q", "-m", "two files" });

    const tree_output = try runCmd(&.{ "git", "-C", tmp, "rev-parse", "HEAD^{tree}" });
    defer testing.allocator.free(tree_output);
    const tree_hash = std.mem.trim(u8, tree_output, " \t\n\r");

    const git_dir = tmp ++ "/.git";
    var loaded = try git.objects.GitObject.load(tree_hash, git_dir, platform, testing.allocator);
    defer loaded.deinit(testing.allocator);

    try testing.expect(loaded.type == .tree);
    try testing.expect(std.mem.indexOf(u8, loaded.data, "a.txt") != null);
    try testing.expect(std.mem.indexOf(u8, loaded.data, "b.txt") != null);
}

// ============================================================================
// Error cases
// ============================================================================

test "load non-existent object returns ObjectNotFound" {
    const tmp = "/tmp/ziggit_obj_sl_notfound";
    try setupGitDir(tmp);
    defer std.fs.deleteTreeAbsolute(tmp) catch {};

    const git_dir = tmp ++ "/.git";
    const result = git.objects.GitObject.load(
        "0000000000000000000000000000000000000000",
        git_dir,
        platform,
        testing.allocator,
    );
    try testing.expectError(error.ObjectNotFound, result);
}

// ============================================================================
// Large blob roundtrip
// ============================================================================

test "store and load 64KB blob" {
    const tmp = "/tmp/ziggit_obj_sl_large";
    try setupGitDir(tmp);
    defer std.fs.deleteTreeAbsolute(tmp) catch {};

    const git_dir = tmp ++ "/.git";
    const data = try testing.allocator.alloc(u8, 65536);
    defer testing.allocator.free(data);
    for (data, 0..) |*b, i| {
        b.* = @intCast(i % 256);
    }

    const obj = git.objects.GitObject.init(.blob, data);
    const hash = try obj.store(git_dir, platform, testing.allocator);
    defer testing.allocator.free(hash);

    var loaded = try git.objects.GitObject.load(hash, git_dir, platform, testing.allocator);
    defer loaded.deinit(testing.allocator);

    try testing.expectEqualSlices(u8, data, loaded.data);
}

// ============================================================================
// Multiple objects in same repo
// ============================================================================

test "store multiple blobs and load each" {
    const tmp = "/tmp/ziggit_obj_sl_multi";
    try setupGitDir(tmp);
    defer std.fs.deleteTreeAbsolute(tmp) catch {};

    const git_dir = tmp ++ "/.git";
    const contents = [_][]const u8{ "alpha", "beta", "gamma", "delta" };
    var hashes: [4][]u8 = undefined;

    for (contents, 0..) |content, i| {
        const obj = git.objects.GitObject.init(.blob, content);
        hashes[i] = try obj.store(git_dir, platform, testing.allocator);
    }
    defer for (&hashes) |h| testing.allocator.free(h);

    // All hashes should be unique
    for (0..4) |i| {
        for (i + 1..4) |j| {
            try testing.expect(!std.mem.eql(u8, hashes[i], hashes[j]));
        }
    }

    // Load each and verify
    for (contents, 0..) |content, i| {
        var loaded = try git.objects.GitObject.load(hashes[i], git_dir, platform, testing.allocator);
        defer loaded.deinit(testing.allocator);
        try testing.expectEqualStrings(content, loaded.data);
    }
}

// ============================================================================
// git fsck validates stored objects
// ============================================================================

test "store blob+tree+commit: git fsck passes" {
    const tmp = "/tmp/ziggit_obj_sl_fsck";
    try setupGitDir(tmp);
    defer std.fs.deleteTreeAbsolute(tmp) catch {};

    const git_dir = tmp ++ "/.git";

    // Store blob
    const blob = git.objects.GitObject.init(.blob, "fsck test\n");
    const blob_hash = try blob.store(git_dir, platform, testing.allocator);
    defer testing.allocator.free(blob_hash);

    // Store tree referencing the blob
    const tree_entries = &[_]git.objects.TreeEntry{
        git.objects.TreeEntry.init("100644", "test.txt", blob_hash),
    };
    var tree = try git.objects.createTreeObject(tree_entries, testing.allocator);
    defer tree.deinit(testing.allocator);
    const tree_hash = try tree.store(git_dir, platform, testing.allocator);
    defer testing.allocator.free(tree_hash);

    // Store commit referencing the tree
    var commit = try git.objects.createCommitObject(
        tree_hash,
        &[_][]const u8{},
        "Test <test@test.com> 1700000000 +0000",
        "Test <test@test.com> 1700000000 +0000",
        "fsck test commit",
        testing.allocator,
    );
    defer commit.deinit(testing.allocator);
    const commit_hash = try commit.store(git_dir, platform, testing.allocator);
    defer testing.allocator.free(commit_hash);

    // Update HEAD ref
    {
        const ref_path = tmp ++ "/.git/refs/heads/master";
        const f = try std.fs.createFileAbsolute(ref_path, .{ .truncate = true });
        defer f.close();
        try f.writeAll(commit_hash);
        try f.writeAll("\n");
    }

    // Run git fsck
    const output = try runCmd(&.{ "git", "-C", tmp, "fsck", "--strict" });
    defer testing.allocator.free(output);
}

// ============================================================================
// Store duplicate object is idempotent
// ============================================================================

test "store same blob twice: idempotent" {
    const tmp = "/tmp/ziggit_obj_sl_idem";
    try setupGitDir(tmp);
    defer std.fs.deleteTreeAbsolute(tmp) catch {};

    const git_dir = tmp ++ "/.git";
    const obj = git.objects.GitObject.init(.blob, "duplicate");

    const hash1 = try obj.store(git_dir, platform, testing.allocator);
    defer testing.allocator.free(hash1);
    const hash2 = try obj.store(git_dir, platform, testing.allocator);
    defer testing.allocator.free(hash2);

    try testing.expectEqualStrings(hash1, hash2);

    // Should still be loadable
    var loaded = try git.objects.GitObject.load(hash1, git_dir, platform, testing.allocator);
    defer loaded.deinit(testing.allocator);
    try testing.expectEqualStrings("duplicate", loaded.data);
}

// ============================================================================
// Helpers
// ============================================================================

fn setupGitDir(path: []const u8) !void {
    std.fs.deleteTreeAbsolute(path) catch {};
    _ = try runCmd(&.{ "git", "init", "-q", path });
}

fn runCmd(args: []const []const u8) ![]u8 {
    var child = std.process.Child.init(args, testing.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    const stdout = try child.stdout.?.reader().readAllAlloc(testing.allocator, 1024 * 1024);
    errdefer testing.allocator.free(stdout);

    const stderr = try child.stderr.?.reader().readAllAlloc(testing.allocator, 1024 * 1024);
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
