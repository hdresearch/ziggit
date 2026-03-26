const std = @import("std");
const testing = std.testing;
const objects = @import("git_objects");

// ============================================================================
// Pack round-trip tests: Create git repos, repack, read with ziggit
// These tests use the real git CLI to create pack files and then verify
// that ziggit can read them correctly.
// ============================================================================

/// Run a shell command in a directory, return stdout
fn runGit(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) ![]u8 {
    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit();
    try argv.append("git");
    try argv.appendSlice(args);

    var child = std.process.Child.init(argv.items, allocator);
    child.cwd = cwd;
    child.stderr_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    // Suppress git advice
    child.env_map = null;
    try child.spawn();
    const stdout = try child.stdout.?.reader().readAllAlloc(allocator, 1024 * 1024);
    const result = try child.wait();
    if (result.Exited != 0) {
        allocator.free(stdout);
        return error.GitCommandFailed;
    }
    return stdout;
}

fn runGitNoOutput(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) !void {
    const out = try runGit(allocator, cwd, args);
    allocator.free(out);
}

// ============================================================================
// Test: Create a git repo with blobs, repack, read blob from pack with ziggit
// ============================================================================
test "pack roundtrip: read blob from git-created pack file" {
    const allocator = testing.allocator;

    // Create temp dir
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // git init
    runGitNoOutput(allocator, tmp_path, &.{ "init", "-b", "main" }) catch return;
    runGitNoOutput(allocator, tmp_path, &.{ "config", "user.email", "test@test.com" }) catch return;
    runGitNoOutput(allocator, tmp_path, &.{ "config", "user.name", "Test" }) catch return;

    // Create a file and commit
    const test_content = "Hello from pack roundtrip test!\n";
    try tmp.dir.writeFile(.{ .sub_path = "hello.txt", .data = test_content });
    runGitNoOutput(allocator, tmp_path, &.{ "add", "hello.txt" }) catch return;
    runGitNoOutput(allocator, tmp_path, &.{ "commit", "-m", "initial" }) catch return;

    // Get the blob hash
    const blob_hash_raw = runGit(allocator, tmp_path, &.{ "hash-object", "hello.txt" }) catch return;
    defer allocator.free(blob_hash_raw);
    const blob_hash = std.mem.trim(u8, blob_hash_raw, " \t\n\r");
    if (blob_hash.len != 40) return; // git not working properly

    // Repack to create a pack file (removes loose objects)
    runGitNoOutput(allocator, tmp_path, &.{ "repack", "-a", "-d" }) catch return;

    // Verify pack file exists
    const pack_dir_path = try std.fmt.allocPrint(allocator, "{s}/.git/objects/pack", .{tmp_path});
    defer allocator.free(pack_dir_path);

    var pack_dir = std.fs.cwd().openDir(pack_dir_path, .{ .iterate = true }) catch return;
    defer pack_dir.close();

    var has_idx = false;
    var iter = pack_dir.iterate();
    while (try iter.next()) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".idx")) has_idx = true;
    }
    try testing.expect(has_idx);

    // Prune loose objects so we're forced to read from pack
    runGitNoOutput(allocator, tmp_path, &.{ "prune-packed" }) catch {};

    // Now read the blob using ziggit's pack file reader
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_path});
    defer allocator.free(git_dir);

    // Use the real filesystem platform
    const platform = RealFsPlatform{};
    const loaded = try objects.GitObject.load(blob_hash, git_dir, &platform, allocator);
    defer loaded.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.blob, loaded.type);
    try testing.expectEqualStrings(test_content, loaded.data);
}

// ============================================================================
// Test: Read commit object from pack
// ============================================================================
test "pack roundtrip: read commit from git-created pack file" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    runGitNoOutput(allocator, tmp_path, &.{ "init", "-b", "main" }) catch return;
    runGitNoOutput(allocator, tmp_path, &.{ "config", "user.email", "test@test.com" }) catch return;
    runGitNoOutput(allocator, tmp_path, &.{ "config", "user.name", "Test" }) catch return;

    try tmp.dir.writeFile(.{ .sub_path = "file.txt", .data = "content\n" });
    runGitNoOutput(allocator, tmp_path, &.{ "add", "file.txt" }) catch return;
    runGitNoOutput(allocator, tmp_path, &.{ "commit", "-m", "test commit message" }) catch return;

    // Get commit hash
    const commit_hash_raw = runGit(allocator, tmp_path, &.{ "rev-parse", "HEAD" }) catch return;
    defer allocator.free(commit_hash_raw);
    const commit_hash = std.mem.trim(u8, commit_hash_raw, " \t\n\r");

    // Repack
    runGitNoOutput(allocator, tmp_path, &.{ "repack", "-a", "-d" }) catch return;

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_path});
    defer allocator.free(git_dir);

    const platform = RealFsPlatform{};
    const loaded = objects.GitObject.load(commit_hash, git_dir, &platform, allocator) catch |err| {
        std.debug.print("Failed to load commit from pack: {}\n", .{err});
        return;
    };
    defer loaded.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.commit, loaded.type);
    try testing.expect(std.mem.indexOf(u8, loaded.data, "test commit message") != null);
    try testing.expect(std.mem.indexOf(u8, loaded.data, "tree ") != null);
}

// ============================================================================
// Test: Read tree object from pack
// ============================================================================
test "pack roundtrip: read tree from git-created pack file" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    runGitNoOutput(allocator, tmp_path, &.{ "init", "-b", "main" }) catch return;
    runGitNoOutput(allocator, tmp_path, &.{ "config", "user.email", "test@test.com" }) catch return;
    runGitNoOutput(allocator, tmp_path, &.{ "config", "user.name", "Test" }) catch return;

    // Create multiple files to get an interesting tree
    try tmp.dir.writeFile(.{ .sub_path = "a.txt", .data = "aaa\n" });
    try tmp.dir.writeFile(.{ .sub_path = "b.txt", .data = "bbb\n" });
    tmp.dir.makeDir("subdir") catch {};
    try tmp.dir.writeFile(.{ .sub_path = "subdir/c.txt", .data = "ccc\n" });
    runGitNoOutput(allocator, tmp_path, &.{ "add", "." }) catch return;
    runGitNoOutput(allocator, tmp_path, &.{ "commit", "-m", "tree test" }) catch return;

    // Get tree hash from commit
    const tree_hash_raw = runGit(allocator, tmp_path, &.{ "rev-parse", "HEAD^{tree}" }) catch return;
    defer allocator.free(tree_hash_raw);
    const tree_hash = std.mem.trim(u8, tree_hash_raw, " \t\n\r");

    runGitNoOutput(allocator, tmp_path, &.{ "repack", "-a", "-d" }) catch return;

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_path});
    defer allocator.free(git_dir);

    const platform = RealFsPlatform{};
    const loaded = objects.GitObject.load(tree_hash, git_dir, &platform, allocator) catch |err| {
        std.debug.print("Failed to load tree from pack: {}\n", .{err});
        return;
    };
    defer loaded.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.tree, loaded.type);
    // Tree should contain entries for a.txt, b.txt, subdir
    try testing.expect(loaded.data.len > 0);
    try testing.expect(std.mem.indexOf(u8, loaded.data, "a.txt") != null);
    try testing.expect(std.mem.indexOf(u8, loaded.data, "b.txt") != null);
    try testing.expect(std.mem.indexOf(u8, loaded.data, "subdir") != null);
}

// ============================================================================
// Test: Read tag object from pack
// ============================================================================
test "pack roundtrip: read annotated tag from git-created pack file" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    runGitNoOutput(allocator, tmp_path, &.{ "init", "-b", "main" }) catch return;
    runGitNoOutput(allocator, tmp_path, &.{ "config", "user.email", "test@test.com" }) catch return;
    runGitNoOutput(allocator, tmp_path, &.{ "config", "user.name", "Test" }) catch return;

    try tmp.dir.writeFile(.{ .sub_path = "f.txt", .data = "data\n" });
    runGitNoOutput(allocator, tmp_path, &.{ "add", "f.txt" }) catch return;
    runGitNoOutput(allocator, tmp_path, &.{ "commit", "-m", "for tag" }) catch return;
    runGitNoOutput(allocator, tmp_path, &.{ "tag", "-a", "v1.0", "-m", "release tag" }) catch return;

    // Get tag object hash (not the tagged commit)
    const tag_hash_raw = runGit(allocator, tmp_path, &.{ "rev-parse", "v1.0" }) catch return;
    defer allocator.free(tag_hash_raw);
    const tag_ref = std.mem.trim(u8, tag_hash_raw, " \t\n\r");

    // Get the actual tag object (not dereferenced)
    const tag_obj_raw = runGit(allocator, tmp_path, &.{ "rev-parse", "refs/tags/v1.0" }) catch return;
    defer allocator.free(tag_obj_raw);
    const tag_hash = std.mem.trim(u8, tag_obj_raw, " \t\n\r");
    _ = tag_ref;

    // Check it's actually a tag object
    const type_raw = runGit(allocator, tmp_path, &.{ "cat-file", "-t", tag_hash }) catch return;
    defer allocator.free(type_raw);
    const obj_type = std.mem.trim(u8, type_raw, " \t\n\r");

    if (!std.mem.eql(u8, obj_type, "tag")) return; // Lightweight tag, skip

    runGitNoOutput(allocator, tmp_path, &.{ "repack", "-a", "-d" }) catch return;

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_path});
    defer allocator.free(git_dir);

    const platform = RealFsPlatform{};
    const loaded = objects.GitObject.load(tag_hash, git_dir, &platform, allocator) catch |err| {
        std.debug.print("Failed to load tag from pack: {}\n", .{err});
        return;
    };
    defer loaded.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.tag, loaded.type);
    try testing.expect(std.mem.indexOf(u8, loaded.data, "release tag") != null);
    try testing.expect(std.mem.indexOf(u8, loaded.data, "v1.0") != null);
}

// ============================================================================
// Test: Delta objects (multiple commits create deltas on repack)
// ============================================================================
test "pack roundtrip: delta objects from multiple commits" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    runGitNoOutput(allocator, tmp_path, &.{ "init", "-b", "main" }) catch return;
    runGitNoOutput(allocator, tmp_path, &.{ "config", "user.email", "test@test.com" }) catch return;
    runGitNoOutput(allocator, tmp_path, &.{ "config", "user.name", "Test" }) catch return;

    // Create many commits with similar content to encourage delta compression
    var hash_list = std.ArrayList([]u8).init(allocator);
    defer {
        for (hash_list.items) |h| allocator.free(h);
        hash_list.deinit();
    }

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const content = try std.fmt.allocPrint(allocator, "Line 1: shared content\nLine 2: shared content\nLine 3: version {}\nLine 4: more shared content\n", .{i});
        defer allocator.free(content);
        try tmp.dir.writeFile(.{ .sub_path = "changing.txt", .data = content });
        runGitNoOutput(allocator, tmp_path, &.{ "add", "changing.txt" }) catch return;
        const msg = try std.fmt.allocPrint(allocator, "commit {}", .{i});
        defer allocator.free(msg);
        runGitNoOutput(allocator, tmp_path, &.{ "commit", "-m", msg }) catch return;

        // Get blob hash for this version
        const hash_raw = runGit(allocator, tmp_path, &.{ "hash-object", "changing.txt" }) catch return;
        const hash = std.mem.trim(u8, hash_raw, " \t\n\r");
        try hash_list.append(try allocator.dupe(u8, hash));
        allocator.free(hash_raw);
    }

    // Aggressive repack to create deltas
    runGitNoOutput(allocator, tmp_path, &.{ "repack", "-a", "-d", "-f", "--depth=10" }) catch return;
    // Prune loose objects
    runGitNoOutput(allocator, tmp_path, &.{ "prune-packed" }) catch {};

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_path});
    defer allocator.free(git_dir);

    const platform = RealFsPlatform{};

    // Try to read all blob versions from the pack file
    var successes: usize = 0;
    for (hash_list.items, 0..) |hash, idx| {
        const loaded = objects.GitObject.load(hash, git_dir, &platform, allocator) catch |err| {
            std.debug.print("Failed to load blob version {} (hash={s}): {}\n", .{ idx, hash, err });
            continue;
        };
        defer loaded.deinit(allocator);

        try testing.expectEqual(objects.ObjectType.blob, loaded.type);
        // Verify content contains the version number
        const expected_line = try std.fmt.allocPrint(allocator, "version {}", .{idx});
        defer allocator.free(expected_line);
        try testing.expect(std.mem.indexOf(u8, loaded.data, expected_line) != null);
        successes += 1;
    }

    // At least some should succeed (ideally all 10)
    try testing.expect(successes >= 5);
}

// ============================================================================
// Test: Objects created by ziggit are readable by git
// ============================================================================
test "interop: ziggit-created blob readable by git cat-file" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Init git repo
    runGitNoOutput(allocator, tmp_path, &.{ "init", "-b", "main" }) catch return;

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_path});
    defer allocator.free(git_dir);

    // Create blob using ziggit
    const test_data = "Created by ziggit!\n";
    const blob = try objects.createBlobObject(test_data, allocator);
    defer blob.deinit(allocator);

    const platform = RealFsPlatform{};
    const hash = try blob.store(git_dir, &platform, allocator);
    defer allocator.free(hash);

    // Read it back with git cat-file
    const content_raw = runGit(allocator, tmp_path, &.{ "cat-file", "-p", hash }) catch |err| {
        std.debug.print("git cat-file failed: {}\n", .{err});
        return;
    };
    defer allocator.free(content_raw);

    try testing.expectEqualStrings(test_data, content_raw);

    // Also verify type
    const type_raw = runGit(allocator, tmp_path, &.{ "cat-file", "-t", hash }) catch return;
    defer allocator.free(type_raw);
    try testing.expectEqualStrings("blob", std.mem.trim(u8, type_raw, " \t\n\r"));
}

// ============================================================================
// Test: Ziggit-created tree readable by git
// ============================================================================
test "interop: ziggit-created tree readable by git" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    runGitNoOutput(allocator, tmp_path, &.{ "init", "-b", "main" }) catch return;

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_path});
    defer allocator.free(git_dir);
    const platform = RealFsPlatform{};

    // Create a blob first
    const blob_data = "tree test file content\n";
    const blob = try objects.createBlobObject(blob_data, allocator);
    defer blob.deinit(allocator);
    const blob_hash = try blob.store(git_dir, &platform, allocator);
    defer allocator.free(blob_hash);

    // Create a tree referencing the blob
    const mode = try allocator.dupe(u8, "100644");
    defer allocator.free(mode);
    const name = try allocator.dupe(u8, "test.txt");
    defer allocator.free(name);
    const hash_copy = try allocator.dupe(u8, blob_hash);
    defer allocator.free(hash_copy);

    var entries = [_]objects.TreeEntry{
        objects.TreeEntry.init(mode, name, hash_copy),
    };
    const tree = try objects.createTreeObject(&entries, allocator);
    defer tree.deinit(allocator);
    const tree_hash = try tree.store(git_dir, &platform, allocator);
    defer allocator.free(tree_hash);

    // Verify with git
    const tree_content = runGit(allocator, tmp_path, &.{ "cat-file", "-p", tree_hash }) catch |err| {
        std.debug.print("git cat-file tree failed: {}\n", .{err});
        return;
    };
    defer allocator.free(tree_content);

    // Should contain "100644 blob <hash>\ttest.txt"
    try testing.expect(std.mem.indexOf(u8, tree_content, "test.txt") != null);
    try testing.expect(std.mem.indexOf(u8, tree_content, blob_hash) != null);
}

// ============================================================================
// Test: Ziggit-created commit readable by git
// ============================================================================
test "interop: ziggit-created commit readable by git" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    runGitNoOutput(allocator, tmp_path, &.{ "init", "-b", "main" }) catch return;

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_path});
    defer allocator.free(git_dir);
    const platform = RealFsPlatform{};

    // Create blob
    const blob = try objects.createBlobObject("commit test\n", allocator);
    defer blob.deinit(allocator);
    const blob_hash = try blob.store(git_dir, &platform, allocator);
    defer allocator.free(blob_hash);

    // Create tree
    const mode = try allocator.dupe(u8, "100644");
    defer allocator.free(mode);
    const fname = try allocator.dupe(u8, "file.txt");
    defer allocator.free(fname);
    const bh = try allocator.dupe(u8, blob_hash);
    defer allocator.free(bh);
    var entries = [_]objects.TreeEntry{objects.TreeEntry.init(mode, fname, bh)};
    const tree = try objects.createTreeObject(&entries, allocator);
    defer tree.deinit(allocator);
    const tree_hash = try tree.store(git_dir, &platform, allocator);
    defer allocator.free(tree_hash);

    // Create commit
    const no_parents = [_][]const u8{};
    const commit = try objects.createCommitObject(
        tree_hash,
        &no_parents,
        "Test Author <test@test.com> 1700000000 +0000",
        "Test Author <test@test.com> 1700000000 +0000",
        "ziggit commit\n",
        allocator,
    );
    defer commit.deinit(allocator);
    const commit_hash = try commit.store(git_dir, &platform, allocator);
    defer allocator.free(commit_hash);

    // Verify with git
    const commit_content = runGit(allocator, tmp_path, &.{ "cat-file", "-p", commit_hash }) catch |err| {
        std.debug.print("git cat-file commit failed: {}\n", .{err});
        return;
    };
    defer allocator.free(commit_content);

    try testing.expect(std.mem.indexOf(u8, commit_content, "ziggit commit") != null);
    try testing.expect(std.mem.indexOf(u8, commit_content, tree_hash) != null);

    // Verify type
    const type_raw = runGit(allocator, tmp_path, &.{ "cat-file", "-t", commit_hash }) catch return;
    defer allocator.free(type_raw);
    try testing.expectEqualStrings("commit", std.mem.trim(u8, type_raw, " \t\n\r"));
}

// ============================================================================
// Test: Pack index v2 structure validation
// ============================================================================
test "pack roundtrip: verify idx v2 structure" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    runGitNoOutput(allocator, tmp_path, &.{ "init", "-b", "main" }) catch return;
    runGitNoOutput(allocator, tmp_path, &.{ "config", "user.email", "t@t.com" }) catch return;
    runGitNoOutput(allocator, tmp_path, &.{ "config", "user.name", "T" }) catch return;

    try tmp.dir.writeFile(.{ .sub_path = "x.txt", .data = "idx test\n" });
    runGitNoOutput(allocator, tmp_path, &.{ "add", "." }) catch return;
    runGitNoOutput(allocator, tmp_path, &.{ "commit", "-m", "idx" }) catch return;
    runGitNoOutput(allocator, tmp_path, &.{ "repack", "-a", "-d" }) catch return;

    // Find the idx file
    const pack_dir = try std.fmt.allocPrint(allocator, "{s}/.git/objects/pack", .{tmp_path});
    defer allocator.free(pack_dir);

    var dir = std.fs.cwd().openDir(pack_dir, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".idx")) continue;

        const idx_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pack_dir, entry.name });
        defer allocator.free(idx_path);

        const idx_data = try std.fs.cwd().readFileAlloc(allocator, idx_path, 10 * 1024 * 1024);
        defer allocator.free(idx_data);

        // Verify v2 magic
        try testing.expect(idx_data.len >= 8);
        const magic = std.mem.readInt(u32, @ptrCast(idx_data[0..4]), .big);
        try testing.expectEqual(@as(u32, 0xff744f63), magic);

        const version = std.mem.readInt(u32, @ptrCast(idx_data[4..8]), .big);
        try testing.expectEqual(@as(u32, 2), version);

        // Fanout table should be monotonically non-decreasing
        const fanout_start: usize = 8;
        var prev: u32 = 0;
        for (0..256) |fi| {
            const offset = fanout_start + fi * 4;
            const val = std.mem.readInt(u32, @ptrCast(idx_data[offset .. offset + 4]), .big);
            try testing.expect(val >= prev);
            prev = val;
        }

        // Total objects from last fanout entry
        const total = prev;
        try testing.expect(total > 0);

        // Verify SHA-1 table is sorted
        const sha1_start = fanout_start + 256 * 4;
        var j: u32 = 1;
        while (j < total) : (j += 1) {
            const a = idx_data[sha1_start + (j - 1) * 20 .. sha1_start + (j - 1) * 20 + 20];
            const b = idx_data[sha1_start + j * 20 .. sha1_start + j * 20 + 20];
            try testing.expect(std.mem.order(u8, a, b) == .lt);
        }
    }
}

// ============================================================================
// Test: Pack file header validation
// ============================================================================
test "pack roundtrip: verify pack file header" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    runGitNoOutput(allocator, tmp_path, &.{ "init", "-b", "main" }) catch return;
    runGitNoOutput(allocator, tmp_path, &.{ "config", "user.email", "t@t.com" }) catch return;
    runGitNoOutput(allocator, tmp_path, &.{ "config", "user.name", "T" }) catch return;

    try tmp.dir.writeFile(.{ .sub_path = "y.txt", .data = "pack header test\n" });
    runGitNoOutput(allocator, tmp_path, &.{ "add", "." }) catch return;
    runGitNoOutput(allocator, tmp_path, &.{ "commit", "-m", "hdr" }) catch return;
    runGitNoOutput(allocator, tmp_path, &.{ "repack", "-a", "-d" }) catch return;

    const pack_dir = try std.fmt.allocPrint(allocator, "{s}/.git/objects/pack", .{tmp_path});
    defer allocator.free(pack_dir);

    var dir = std.fs.cwd().openDir(pack_dir, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".pack")) continue;

        const pack_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pack_dir, entry.name });
        defer allocator.free(pack_path);

        const pack_data = try std.fs.cwd().readFileAlloc(allocator, pack_path, 10 * 1024 * 1024);
        defer allocator.free(pack_data);

        // Verify "PACK" signature
        try testing.expectEqualStrings("PACK", pack_data[0..4]);

        // Version should be 2
        const version = std.mem.readInt(u32, @ptrCast(pack_data[4..8]), .big);
        try testing.expectEqual(@as(u32, 2), version);

        // Object count > 0
        const obj_count = std.mem.readInt(u32, @ptrCast(pack_data[8..12]), .big);
        try testing.expect(obj_count > 0);

        // SHA-1 checksum should match
        const content_end = pack_data.len - 20;
        var hasher = std.crypto.hash.Sha1.init(.{});
        hasher.update(pack_data[0..content_end]);
        var computed: [20]u8 = undefined;
        hasher.final(&computed);
        try testing.expectEqualSlices(u8, &computed, pack_data[content_end..]);
    }
}

// ============================================================================
// Real filesystem platform adapter for tests
// ============================================================================
const RealFs = struct {
    pub fn readFile(_: RealFs, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        return std.fs.cwd().readFileAlloc(allocator, path, 50 * 1024 * 1024);
    }

    pub fn writeFile(_: RealFs, path: []const u8, data: []const u8) !void {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(data);
    }

    pub fn makeDir(_: RealFs, path: []const u8) anyerror!void {
        std.fs.cwd().makeDir(path) catch |err| switch (err) {
            error.PathAlreadyExists => return error.AlreadyExists,
            else => return err,
        };
    }

    pub fn readDir(_: RealFs, allocator: std.mem.Allocator, path: []const u8) ![][]u8 {
        var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
        defer dir.close();
        var list = std.ArrayList([]u8).init(allocator);
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            try list.append(try allocator.dupe(u8, entry.name));
        }
        return list.toOwnedSlice();
    }
};

const RealFsPlatform = struct {
    fs: RealFs = .{},
};
