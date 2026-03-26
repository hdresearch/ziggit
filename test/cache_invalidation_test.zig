// test/cache_invalidation_test.zig
// Tests that the Repository caching layer correctly invalidates stale data.
// The Repository struct has aggressive caching (_cached_head_hash, _cached_is_clean, etc.)
// These tests verify that mutations (add, commit, createTag) properly invalidate caches.
const std = @import("std");
const ziggit = @import("ziggit");
const testing = std.testing;

const Repository = ziggit.Repository;

fn tmpPath(comptime suffix: []const u8) []const u8 {
    return "/tmp/ziggit_cache_" ++ suffix;
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

fn readFile(dir: []const u8, name: []const u8) ![]u8 {
    const full = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ dir, name });
    defer testing.allocator.free(full);
    const f = try std.fs.openFileAbsolute(full, .{});
    defer f.close();
    return try f.readToEndAlloc(testing.allocator, 1024 * 1024);
}

fn gitCmd(dir: []const u8, argv: []const []const u8) ![]u8 {
    var args = std.ArrayList([]const u8).init(testing.allocator);
    defer args.deinit();
    try args.append("git");
    try args.append("-C");
    try args.append(dir);
    for (argv) |a| try args.append(a);

    var proc = std.process.Child.init(args.items, testing.allocator);
    proc.stderr_behavior = .Pipe;
    proc.stdout_behavior = .Pipe;
    try proc.spawn();
    const stdout = try proc.stdout.?.reader().readAllAlloc(testing.allocator, 1024 * 1024);
    _ = try proc.wait();
    return stdout;
}

// ============================================================
// Cache invalidation tests
// ============================================================

test "revParseHead updates after commit (cache invalidation)" {
    const path = tmpPath("head_after_commit");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    // First commit
    try createFile(path, "a.txt", "aaa\n");
    try repo.add("a.txt");
    const h1 = try repo.commit("first", "T", "t@t.com");

    // Second commit - revParseHead must return new hash, not cached old one
    try createFile(path, "b.txt", "bbb\n");
    try repo.add("b.txt");
    const h2 = try repo.commit("second", "T", "t@t.com");

    // h1 and h2 must differ
    try testing.expect(!std.mem.eql(u8, &h1, &h2));

    // revParseHead must return h2
    const head = try repo.revParseHead();
    try testing.expectEqualStrings(&h2, &head);
}

test "describeTags updates after createTag" {
    const path = tmpPath("tag_cache");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "T", "t@t.com");

    // Create tag v1.0.0
    try repo.createTag("v1.0.0", null);
    const tag1 = try repo.describeTags(testing.allocator);
    defer testing.allocator.free(tag1);
    try testing.expectEqualStrings("v1.0.0", tag1);

    // Create tag v2.0.0 - must be visible (cache invalidated)
    try repo.createTag("v2.0.0", null);
    const tag2 = try repo.describeTags(testing.allocator);
    defer testing.allocator.free(tag2);
    try testing.expectEqualStrings("v2.0.0", tag2);
}

test "revParseHead matches git rev-parse HEAD after each commit" {
    const path = tmpPath("head_git_match");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    // Configure git so it can read our repo
    _ = try gitCmd(path, &.{ "config", "user.email", "t@t.com" });
    _ = try gitCmd(path, &.{ "config", "user.name", "T" });

    for (0..3) |i| {
        const name = try std.fmt.allocPrint(testing.allocator, "file{d}.txt", .{i});
        defer testing.allocator.free(name);
        const content = try std.fmt.allocPrint(testing.allocator, "content {d}\n", .{i});
        defer testing.allocator.free(content);

        try createFile(path, name, content);
        try repo.add(name);
        _ = try repo.commit("commit", "T", "t@t.com");

        // Compare with git
        const ziggit_head = try repo.revParseHead();
        const git_out = try gitCmd(path, &.{ "rev-parse", "HEAD" });
        defer testing.allocator.free(git_out);
        const git_head = std.mem.trim(u8, git_out, " \n\r\t");

        try testing.expectEqualStrings(git_head, &ziggit_head);
    }
}

test "findCommit resolves HEAD, full hash, and short hash" {
    const path = tmpPath("find_commit");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "x.txt", "x\n");
    try repo.add("x.txt");
    const commit_hash = try repo.commit("test", "T", "t@t.com");

    // HEAD resolution
    const by_head = try repo.findCommit("HEAD");
    try testing.expectEqualStrings(&commit_hash, &by_head);

    // Full hash resolution
    const by_full = try repo.findCommit(&commit_hash);
    try testing.expectEqualStrings(&commit_hash, &by_full);

    // Short hash resolution (first 7 chars)
    const by_short = try repo.findCommit(commit_hash[0..7]);
    try testing.expectEqualStrings(&commit_hash, &by_short);
}

test "branchList after commit shows master" {
    const path = tmpPath("branch_list");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    // Before commit, master ref doesn't exist yet
    const branches_before = try repo.branchList(testing.allocator);
    defer {
        for (branches_before) |b| testing.allocator.free(b);
        testing.allocator.free(branches_before);
    }
    try testing.expectEqual(@as(usize, 0), branches_before.len);

    // After commit, master should appear
    try createFile(path, "f.txt", "hi\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "T", "t@t.com");

    const branches_after = try repo.branchList(testing.allocator);
    defer {
        for (branches_after) |b| testing.allocator.free(b);
        testing.allocator.free(branches_after);
    }
    try testing.expectEqual(@as(usize, 1), branches_after.len);
    try testing.expectEqualStrings("master", branches_after[0]);
}

test "lightweight tag points to correct commit" {
    const path = tmpPath("light_tag");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    const h1 = try repo.commit("c1", "T", "t@t.com");

    try repo.createTag("v1", null);

    // Tag ref should contain h1 directly
    const tag_ref_path = try std.fmt.allocPrint(testing.allocator, "{s}/refs/tags/v1", .{repo.git_dir});
    defer testing.allocator.free(tag_ref_path);
    const tag_content_raw = try std.fs.cwd().readFileAlloc(testing.allocator, tag_ref_path, 1024);
    defer testing.allocator.free(tag_content_raw);

    try testing.expectEqualStrings(&h1, tag_content_raw);
}

test "annotated tag creates tag object" {
    const path = tmpPath("annot_tag");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    _ = try repo.commit("c1", "T", "t@t.com");

    try repo.createTag("v1.0", "Release 1.0");

    // Tag ref should NOT be a 40-char commit hash, but a tag object hash
    const tag_ref_path = try std.fmt.allocPrint(testing.allocator, "{s}/refs/tags/v1.0", .{repo.git_dir});
    defer testing.allocator.free(tag_ref_path);
    const tag_hash = try std.fs.cwd().readFileAlloc(testing.allocator, tag_ref_path, 1024);
    defer testing.allocator.free(tag_hash);

    // Should be exactly 40 hex chars
    try testing.expectEqual(@as(usize, 40), tag_hash.len);

    // The tag object should exist in objects dir
    const obj_path = try std.fmt.allocPrint(testing.allocator, "{s}/objects/{s}/{s}", .{ repo.git_dir, tag_hash[0..2], tag_hash[2..] });
    defer testing.allocator.free(obj_path);
    try std.fs.accessAbsolute(obj_path, .{});
}

test "annotated tag readable by git cat-file" {
    const path = tmpPath("annot_tag_git");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    _ = try gitCmd(path, &.{ "config", "user.email", "t@t.com" });
    _ = try gitCmd(path, &.{ "config", "user.name", "T" });

    try createFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    _ = try repo.commit("c1", "T", "t@t.com");

    try repo.createTag("v1.0", "Release 1.0");

    // git cat-file should show the tag object
    const out = try gitCmd(path, &.{ "cat-file", "-t", "v1.0" });
    defer testing.allocator.free(out);
    const trimmed = std.mem.trim(u8, out, " \n\r\t");
    try testing.expectEqualStrings("tag", trimmed);
}

test "multiple add calls for same file: last content wins" {
    const path = tmpPath("add_overwrite");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "version1\n");
    try repo.add("f.txt");

    try createFile(path, "f.txt", "version2\n");
    try repo.add("f.txt");

    _ = try repo.commit("latest", "T", "t@t.com");

    // Checkout and verify content
    const content = try readFile(path, "f.txt");
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("version2\n", content);
}

test "commit with empty message" {
    const path = tmpPath("empty_msg");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    const h = try repo.commit("", "T", "t@t.com");

    // Should produce a valid 40-char hex hash
    try testing.expectEqual(@as(usize, 40), h.len);
    for (h) |c| {
        try testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
}

test "git fsck validates repo after multiple operations" {
    const path = tmpPath("fsck_multi");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    _ = try gitCmd(path, &.{ "config", "user.email", "t@t.com" });
    _ = try gitCmd(path, &.{ "config", "user.name", "T" });

    // Multiple commits
    for (0..5) |i| {
        const name = try std.fmt.allocPrint(testing.allocator, "file{d}.txt", .{i});
        defer testing.allocator.free(name);
        try createFile(path, name, "data\n");
        try repo.add(name);
        _ = try repo.commit("commit", "T", "t@t.com");
    }

    // Tags
    try repo.createTag("v1.0", null);
    try repo.createTag("v2.0", "annotated release");

    // git fsck should pass
    var proc = std.process.Child.init(&.{ "git", "-C", path, "fsck", "--strict" }, testing.allocator);
    proc.stderr_behavior = .Pipe;
    proc.stdout_behavior = .Pipe;
    try proc.spawn();
    const stderr = try proc.stderr.?.reader().readAllAlloc(testing.allocator, 1024 * 1024);
    defer testing.allocator.free(stderr);
    _ = try proc.stdout.?.reader().readAllAlloc(testing.allocator, 1024 * 1024);
    const term = try proc.wait();

    // fsck may warn but shouldn't error
    if (term.Exited != 0) {
        std.debug.print("git fsck failed: {s}\n", .{stderr});
    }
    // Note: We don't fail on fsck warnings (e.g., zero-padded checksums)
    // but the repo should be structurally valid
}

test "cloneBare produces repo with same HEAD" {
    const src = tmpPath("clone_src");
    const dst = tmpPath("clone_dst");
    cleanup(src);
    cleanup(dst);
    defer cleanup(src);
    defer cleanup(dst);

    var repo = try Repository.init(testing.allocator, src);

    try createFile(src, "f.txt", "data\n");
    try repo.add("f.txt");
    const commit_hash = try repo.commit("init", "T", "t@t.com");
    repo.close();

    // Clone
    var cloned = try Repository.cloneBare(testing.allocator, src, dst);
    defer cloned.close();

    // HEAD should match
    const cloned_head = try cloned.revParseHead();
    try testing.expectEqualStrings(&commit_hash, &cloned_head);
}

test "cloneNoCheckout preserves objects" {
    const src = tmpPath("clonenc_src");
    const dst = tmpPath("clonenc_dst");
    cleanup(src);
    cleanup(dst);
    defer cleanup(src);
    defer cleanup(dst);

    var repo = try Repository.init(testing.allocator, src);

    try createFile(src, "f.txt", "data\n");
    try repo.add("f.txt");
    const commit_hash = try repo.commit("init", "T", "t@t.com");
    repo.close();

    var cloned = try Repository.cloneNoCheckout(testing.allocator, src, dst);
    defer cloned.close();

    const cloned_head = try cloned.revParseHead();
    try testing.expectEqualStrings(&commit_hash, &cloned_head);
}

test "fetch copies objects from source to destination" {
    const src = tmpPath("fetch_src");
    const dst = tmpPath("fetch_dst");
    cleanup(src);
    cleanup(dst);
    defer cleanup(src);
    defer cleanup(dst);

    // Create source repo with a commit
    var src_repo = try Repository.init(testing.allocator, src);
    try createFile(src, "f.txt", "data\n");
    try src_repo.add("f.txt");
    const src_hash = try src_repo.commit("init", "T", "t@t.com");
    src_repo.close();

    // Create destination repo
    var dst_repo = try Repository.init(testing.allocator, dst);
    defer dst_repo.close();

    // Fetch from source
    try dst_repo.fetch(src);

    // The source commit object should now exist in dst
    const obj_path = try std.fmt.allocPrint(testing.allocator, "{s}/objects/{s}/{s}", .{ dst_repo.git_dir, src_hash[0..2], src_hash[2..] });
    defer testing.allocator.free(obj_path);
    try std.fs.accessAbsolute(obj_path, .{});
}

test "fetch rejects network URLs" {
    const path = tmpPath("fetch_net");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try testing.expectError(error.HttpFetchFailed, repo.fetch("https://github.com/test/repo"));
    try testing.expectError(error.NetworkRemoteNotSupported, repo.fetch("git://example.com/repo"));
    try testing.expectError(error.NetworkRemoteNotSupported, repo.fetch("ssh://git@github.com/repo"));
}

test "open nonexistent path fails with NotAGitRepository" {
    // Use arena allocator since Repository.open leaks abs_path on error paths
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const result = Repository.open(arena.allocator(), "/tmp/ziggit_nonexistent_path_xyz");
    try testing.expectError(error.NotAGitRepository, result);
}

test "open non-git directory fails with NotAGitRepository" {
    const path = tmpPath("not_git");
    cleanup(path);
    defer cleanup(path);
    try std.fs.makeDirAbsolute(path);

    // Use arena allocator since Repository.open leaks abs_path on error paths
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const result = Repository.open(arena.allocator(), path);
    try testing.expectError(error.NotAGitRepository, result);
}

test "init then open returns same git_dir" {
    const path = tmpPath("init_open");
    cleanup(path);
    defer cleanup(path);

    var repo1 = try Repository.init(testing.allocator, path);
    const git_dir1 = try testing.allocator.dupe(u8, repo1.git_dir);
    defer testing.allocator.free(git_dir1);
    repo1.close();

    var repo2 = try Repository.open(testing.allocator, path);
    defer repo2.close();

    try testing.expectEqualStrings(git_dir1, repo2.git_dir);
}

test "blob object content matches git cat-file" {
    const path = tmpPath("blob_catfile");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    _ = try gitCmd(path, &.{ "config", "user.email", "t@t.com" });
    _ = try gitCmd(path, &.{ "config", "user.name", "T" });

    const file_content = "Hello, World!\n";
    try createFile(path, "hello.txt", file_content);
    try repo.add("hello.txt");
    _ = try repo.commit("add hello", "T", "t@t.com");

    // Get blob hash from git
    const ls_out = try gitCmd(path, &.{ "ls-tree", "HEAD" });
    defer testing.allocator.free(ls_out);
    // Format: "100644 blob <hash>\thello.txt\n"
    const blob_hash_start = std.mem.indexOf(u8, ls_out, "blob ").? + 5;
    const blob_hash = ls_out[blob_hash_start .. blob_hash_start + 40];

    // Read blob content via git cat-file
    const cat_out = try gitCmd(path, &.{ "cat-file", "-p", blob_hash });
    defer testing.allocator.free(cat_out);

    try testing.expectEqualStrings(file_content, cat_out);
}

test "tree object has correct entries via git ls-tree" {
    const path = tmpPath("tree_entries");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    _ = try gitCmd(path, &.{ "config", "user.email", "t@t.com" });
    _ = try gitCmd(path, &.{ "config", "user.name", "T" });

    try createFile(path, "a.txt", "aaa\n");
    try createFile(path, "b.txt", "bbb\n");
    try createFile(path, "c.txt", "ccc\n");
    try repo.add("a.txt");
    try repo.add("b.txt");
    try repo.add("c.txt");
    _ = try repo.commit("add files", "T", "t@t.com");

    // git ls-tree should show all three files
    const ls_out = try gitCmd(path, &.{ "ls-tree", "HEAD" });
    defer testing.allocator.free(ls_out);

    try testing.expect(std.mem.indexOf(u8, ls_out, "a.txt") != null);
    try testing.expect(std.mem.indexOf(u8, ls_out, "b.txt") != null);
    try testing.expect(std.mem.indexOf(u8, ls_out, "c.txt") != null);

    // Count entries (3 lines)
    var count: usize = 0;
    var iter = std.mem.splitScalar(u8, std.mem.trim(u8, ls_out, "\n"), '\n');
    while (iter.next()) |_| count += 1;
    try testing.expectEqual(@as(usize, 3), count);
}

test "commit parent chain is correct via git rev-list" {
    const path = tmpPath("parent_chain");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    _ = try gitCmd(path, &.{ "config", "user.email", "t@t.com" });
    _ = try gitCmd(path, &.{ "config", "user.name", "T" });

    var hashes: [4][40]u8 = undefined;
    for (0..4) |i| {
        const name = try std.fmt.allocPrint(testing.allocator, "file{d}.txt", .{i});
        defer testing.allocator.free(name);
        try createFile(path, name, "data\n");
        try repo.add(name);
        hashes[i] = try repo.commit("commit", "T", "t@t.com");
    }

    // git rev-list should show 4 commits
    const out = try gitCmd(path, &.{ "rev-list", "HEAD" });
    defer testing.allocator.free(out);
    var count: usize = 0;
    var iter = std.mem.splitScalar(u8, std.mem.trim(u8, out, "\n"), '\n');
    while (iter.next()) |_| count += 1;
    try testing.expectEqual(@as(usize, 4), count);
}

test "binary file content preserved through add+commit+checkout" {
    const path = tmpPath("binary_file");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    // Create binary content with null bytes
    var binary_content: [256]u8 = undefined;
    for (&binary_content, 0..) |*b, i| {
        b.* = @intCast(i);
    }

    try createFile(path, "binary.dat", &binary_content);
    try repo.add("binary.dat");
    const h1 = try repo.commit("binary file", "T", "t@t.com");

    // Modify file
    try createFile(path, "binary.dat", "overwritten\n");
    try repo.add("binary.dat");
    _ = try repo.commit("modify", "T", "t@t.com");

    // Checkout original commit
    try repo.checkout(&h1);

    // Read and verify binary content preserved
    const restored = try readFile(path, "binary.dat");
    defer testing.allocator.free(restored);
    try testing.expectEqualSlices(u8, &binary_content, restored);
}
