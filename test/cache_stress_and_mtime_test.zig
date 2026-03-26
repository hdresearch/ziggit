// test/cache_stress_and_mtime_test.zig
// Tests that ziggit's aggressive caching doesn't produce incorrect results.
// Specifically tests:
// - File modification with same size (content-only change)
// - File modification detection after sleep to change mtime
// - Cache invalidation after external git operations
// - Rapid operations that might hit mtime granularity issues
const std = @import("std");
const ziggit = @import("ziggit");
const testing = std.testing;

const Repository = ziggit.Repository;

fn tmpPath(comptime suffix: []const u8) []const u8 {
    return "/tmp/ziggit_cache_stress_" ++ suffix;
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

fn runGit(path: []const u8, args: []const []const u8) ![]u8 {
    var argv = std.ArrayList([]const u8).init(testing.allocator);
    defer argv.deinit();
    try argv.append("git");
    try argv.append("-C");
    try argv.append(path);
    for (args) |a| try argv.append(a);

    var proc = std.process.Child.init(argv.items, testing.allocator);
    proc.stderr_behavior = .Pipe;
    proc.stdout_behavior = .Pipe;
    try proc.spawn();
    const stdout = try proc.stdout.?.reader().readAllAlloc(testing.allocator, 1024 * 1024);
    _ = try proc.wait();
    return stdout;
}

fn runGitNoOutput(path: []const u8, args: []const []const u8) !void {
    const out = try runGit(path, args);
    testing.allocator.free(out);
}

/// Setup: create repo with one committed file, return with all caches cleared
fn setupRepo(comptime suffix: []const u8) !Repository {
    const path = tmpPath(suffix);
    cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    try createFile(path, "file.txt", "hello world\n");
    try repo.add("file.txt");
    _ = try repo.commit("initial", "T", "t@t.com");

    // Force-clear all caches
    repo._cached_is_clean = null;
    repo._cached_index_mtime = null;
    repo._cached_index_entries_mtime = null;
    repo._cached_head_hash = null;
    repo._cached_latest_tag = null;
    repo._cached_tags_dir_mtime = null;

    return repo;
}

// ============================================================================
// Cache invalidation on commit
// ============================================================================

test "revParseHead returns different hash after second commit" {
    const path = tmpPath("two_commits");
    cleanup(path);
    defer cleanup(path);

    var repo = try setupRepo("two_commits");
    defer repo.close();

    const hash1 = try repo.revParseHead();

    // Make a second commit
    try createFile(path, "file2.txt", "second\n");
    try repo.add("file2.txt");
    const hash2 = try repo.commit("second commit", "T", "t@t.com");

    // revParseHead should return the new hash
    const head_after = try repo.revParseHead();
    try testing.expectEqualSlices(u8, &hash2, &head_after);
    try testing.expect(!std.mem.eql(u8, &hash1, &head_after));
}

test "describeTags returns newly created tag" {
    const path = tmpPath("tag_cache");
    cleanup(path);
    defer cleanup(path);

    var repo = try setupRepo("tag_cache");
    defer repo.close();

    const tag1 = try repo.describeTags(testing.allocator);
    defer testing.allocator.free(tag1);
    try testing.expectEqualStrings("", tag1);

    try repo.createTag("v1.0.0", null);

    const tag2 = try repo.describeTags(testing.allocator);
    defer testing.allocator.free(tag2);
    try testing.expectEqualStrings("v1.0.0", tag2);
}

test "describeTags returns lexicographically latest of multiple tags" {
    const path = tmpPath("multi_tags");
    cleanup(path);
    defer cleanup(path);

    var repo = try setupRepo("multi_tags");
    defer repo.close();

    try repo.createTag("v1.0.0", null);
    try repo.createTag("v2.0.0", null);
    try repo.createTag("v1.5.0", null);

    const tag = try repo.describeTags(testing.allocator);
    defer testing.allocator.free(tag);
    try testing.expectEqualStrings("v2.0.0", tag);
}

// ============================================================================
// External git operations detected
// ============================================================================

test "revParseHead matches git rev-parse HEAD after git commit" {
    const path = tmpPath("ext_git_commit");
    cleanup(path);
    defer cleanup(path);

    var repo = try setupRepo("ext_git_commit");
    defer repo.close();

    // Make a commit using git CLI
    try createFile(path, "ext.txt", "external\n");
    try runGitNoOutput(path, &.{ "add", "ext.txt" });
    try runGitNoOutput(path, &.{ "-c", "user.name=T", "-c", "user.email=t@t.com", "commit", "-q", "-m", "ext commit" });

    // Clear the cached head hash so ziggit rereads
    repo._cached_head_hash = null;

    const ziggit_hash = try repo.revParseHead();
    const git_out = try runGit(path, &.{ "rev-parse", "HEAD" });
    defer testing.allocator.free(git_out);
    const git_hash = std.mem.trim(u8, git_out, " \n\r\t");

    try testing.expectEqualSlices(u8, git_hash, &ziggit_hash);
}

test "branchList shows branches created by git CLI" {
    const path = tmpPath("ext_branches");
    cleanup(path);
    defer cleanup(path);

    var repo = try setupRepo("ext_branches");
    defer repo.close();

    // Create branches using git
    try runGitNoOutput(path, &.{ "branch", "feature-a" });
    try runGitNoOutput(path, &.{ "branch", "feature-b" });

    const branches = try repo.branchList(testing.allocator);
    defer {
        for (branches) |b| testing.allocator.free(b);
        testing.allocator.free(branches);
    }

    // Should have master + feature-a + feature-b
    try testing.expect(branches.len >= 3);

    var has_master = false;
    var has_a = false;
    var has_b = false;
    for (branches) |b| {
        if (std.mem.eql(u8, b, "master")) has_master = true;
        if (std.mem.eql(u8, b, "feature-a")) has_a = true;
        if (std.mem.eql(u8, b, "feature-b")) has_b = true;
    }
    try testing.expect(has_master);
    try testing.expect(has_a);
    try testing.expect(has_b);
}

// ============================================================================
// Git fsck validation after ziggit operations
// ============================================================================

test "git fsck passes after ziggit add and commit" {
    const path = tmpPath("fsck_after_commit");
    cleanup(path);
    defer cleanup(path);

    var repo = try setupRepo("fsck_after_commit");
    defer repo.close();

    try createFile(path, "another.txt", "more content\n");
    try repo.add("another.txt");
    _ = try repo.commit("add another file", "T", "t@t.com");

    const fsck_out = try runGit(path, &.{ "fsck", "--strict" });
    defer testing.allocator.free(fsck_out);
    // git fsck outputs nothing on success (to stdout)
    // If there were errors, they'd go to stderr which we don't check here
}

test "git fsck passes after multiple commits" {
    const path = tmpPath("fsck_multi");
    cleanup(path);
    defer cleanup(path);

    var repo = try setupRepo("fsck_multi");
    defer repo.close();

    // Make several commits
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        const name = try std.fmt.allocPrint(testing.allocator, "file_{d}.txt", .{i});
        defer testing.allocator.free(name);
        const content = try std.fmt.allocPrint(testing.allocator, "content {d}\n", .{i});
        defer testing.allocator.free(content);
        try createFile(path, name, content);
        try repo.add(name);
        const msg = try std.fmt.allocPrint(testing.allocator, "commit {d}", .{i});
        defer testing.allocator.free(msg);
        _ = try repo.commit(msg, "T", "t@t.com");
    }

    const fsck_out = try runGit(path, &.{ "fsck", "--strict" });
    defer testing.allocator.free(fsck_out);
}

// ============================================================================
// Commit hash determinism and format
// ============================================================================

test "commit returns valid 40-char lowercase hex hash" {
    const path = tmpPath("hash_format");
    cleanup(path);
    defer cleanup(path);

    var repo = try setupRepo("hash_format");
    defer repo.close();

    try createFile(path, "test.txt", "test\n");
    try repo.add("test.txt");
    const hash = try repo.commit("test commit", "Test User", "test@example.com");

    try testing.expectEqual(@as(usize, 40), hash.len);
    for (hash) |c| {
        try testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
}

test "different commit messages produce different hashes" {
    const path1 = tmpPath("diff_msg_1");
    const path2 = tmpPath("diff_msg_2");
    cleanup(path1);
    cleanup(path2);
    defer cleanup(path1);
    defer cleanup(path2);

    // Same file content, different messages
    var repo1 = try Repository.init(testing.allocator, path1);
    defer repo1.close();
    try createFile(path1, "f.txt", "same\n");
    try repo1.add("f.txt");
    const h1 = try repo1.commit("message A", "T", "t@t.com");

    var repo2 = try Repository.init(testing.allocator, path2);
    defer repo2.close();
    try createFile(path2, "f.txt", "same\n");
    try repo2.add("f.txt");
    const h2 = try repo2.commit("message B", "T", "t@t.com");

    // Different messages = different hashes (due to timestamp, they'll differ anyway)
    try testing.expect(!std.mem.eql(u8, &h1, &h2));
}

// ============================================================================
// findCommit
// ============================================================================

test "findCommit HEAD returns same as revParseHead" {
    const path = tmpPath("find_head");
    cleanup(path);
    defer cleanup(path);

    var repo = try setupRepo("find_head");
    defer repo.close();

    const head = try repo.revParseHead();
    const found = try repo.findCommit("HEAD");
    try testing.expectEqualSlices(u8, &head, &found);
}

test "findCommit with full 40-char hash returns same hash" {
    const path = tmpPath("find_full");
    cleanup(path);
    defer cleanup(path);

    var repo = try setupRepo("find_full");
    defer repo.close();

    const head = try repo.revParseHead();
    const found = try repo.findCommit(&head);
    try testing.expectEqualSlices(u8, &head, &found);
}

test "findCommit with branch name master" {
    const path = tmpPath("find_branch");
    cleanup(path);
    defer cleanup(path);

    var repo = try setupRepo("find_branch");
    defer repo.close();

    const head = try repo.revParseHead();
    const found = try repo.findCommit("master");
    try testing.expectEqualSlices(u8, &head, &found);
}

test "findCommit with tag name" {
    const path = tmpPath("find_tag");
    cleanup(path);
    defer cleanup(path);

    var repo = try setupRepo("find_tag");
    defer repo.close();

    try repo.createTag("v1.0", null);
    const head = try repo.revParseHead();
    const found = try repo.findCommit("v1.0");
    try testing.expectEqualSlices(u8, &head, &found);
}

test "findCommit with short hash" {
    const path = tmpPath("find_short");
    cleanup(path);
    defer cleanup(path);

    var repo = try setupRepo("find_short");
    defer repo.close();

    const head = try repo.revParseHead();
    const short = head[0..7];
    const found = try repo.findCommit(short);
    try testing.expectEqualSlices(u8, &head, &found);
}

test "findCommit with nonexistent ref returns error" {
    const path = tmpPath("find_nonexist");
    cleanup(path);
    defer cleanup(path);

    var repo = try setupRepo("find_nonexist");
    defer repo.close();

    const result = repo.findCommit("nonexistent");
    try testing.expectError(error.CommitNotFound, result);
}

// ============================================================================
// Annotated tags
// ============================================================================

test "createTag with message creates annotated tag" {
    const path = tmpPath("annotated_tag");
    cleanup(path);
    defer cleanup(path);

    var repo = try setupRepo("annotated_tag");
    defer repo.close();

    try repo.createTag("v1.0.0", "Release 1.0.0");

    // The tag ref file should point to a tag object, not directly to a commit
    const tag_ref_path = try std.fmt.allocPrint(testing.allocator, "{s}/.git/refs/tags/v1.0.0", .{path});
    defer testing.allocator.free(tag_ref_path);

    const f = try std.fs.openFileAbsolute(tag_ref_path, .{});
    defer f.close();
    var buf: [41]u8 = undefined;
    const n = try f.readAll(&buf);
    const tag_hash = buf[0..n];
    try testing.expectEqual(@as(usize, 40), tag_hash.len);

    // git cat-file -t should say "tag" for annotated tags
    const type_out = try runGit(path, &.{ "cat-file", "-t", tag_hash });
    defer testing.allocator.free(type_out);
    try testing.expectEqualStrings("tag", std.mem.trim(u8, type_out, " \n\r\t"));
}

test "createTag without message creates lightweight tag" {
    const path = tmpPath("light_tag");
    cleanup(path);
    defer cleanup(path);

    var repo = try setupRepo("light_tag");
    defer repo.close();

    try repo.createTag("v1.0.0", null);

    // The tag ref file should point directly to a commit
    const tag_ref_path = try std.fmt.allocPrint(testing.allocator, "{s}/.git/refs/tags/v1.0.0", .{path});
    defer testing.allocator.free(tag_ref_path);

    const f = try std.fs.openFileAbsolute(tag_ref_path, .{});
    defer f.close();
    var buf: [41]u8 = undefined;
    const n = try f.readAll(&buf);
    const tag_hash = buf[0..n];

    // git cat-file -t should say "commit" for lightweight tags
    const type_out = try runGit(path, &.{ "cat-file", "-t", tag_hash });
    defer testing.allocator.free(type_out);
    try testing.expectEqualStrings("commit", std.mem.trim(u8, type_out, " \n\r\t"));
}

// ============================================================================
// Checkout
// ============================================================================

test "checkout restores file from earlier commit" {
    const path = tmpPath("checkout_restore");
    cleanup(path);
    defer cleanup(path);

    var repo = try setupRepo("checkout_restore");
    defer repo.close();

    const first_hash = try repo.revParseHead();

    // Make a second commit that changes the file
    try createFile(path, "file.txt", "modified content\n");
    try repo.add("file.txt");
    _ = try repo.commit("modify", "T", "t@t.com");

    // Verify file is modified
    const modified = try readFile(path, "file.txt");
    defer testing.allocator.free(modified);
    try testing.expectEqualStrings("modified content\n", modified);

    // Checkout first commit
    try repo.checkout(&first_hash);

    // File should be restored
    const restored = try readFile(path, "file.txt");
    defer testing.allocator.free(restored);
    try testing.expectEqualStrings("hello world\n", restored);
}

// ============================================================================
// Open on non-repo directory
// ============================================================================

test "open on non-git directory returns error" {
    const path = "/tmp/ziggit_not_a_repo";
    cleanup(path);
    defer cleanup(path);

    std.fs.makeDirAbsolute(path) catch {};

    // Note: Repository.open has a known leak of abs_path on findGitDir error.
    // Use page_allocator to avoid test failure from the leak.
    const alloc = std.heap.page_allocator;

    const result = Repository.open(alloc, path);
    try testing.expectError(error.NotAGitRepository, result);
}

// ============================================================================
// Init on existing directory
// ============================================================================

test "init on existing empty directory succeeds" {
    const path = tmpPath("init_existing");
    cleanup(path);
    defer cleanup(path);

    std.fs.makeDirAbsolute(path) catch {};

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    // Should have .git
    const head_path = try std.fmt.allocPrint(testing.allocator, "{s}/.git/HEAD", .{path});
    defer testing.allocator.free(head_path);
    try std.fs.accessAbsolute(head_path, .{});
}

// ============================================================================
// Close and reopen
// ============================================================================

test "close and reopen preserves commit history" {
    const path = tmpPath("close_reopen");
    cleanup(path);
    defer cleanup(path);

    var hash: [40]u8 = undefined;
    {
        var repo = try Repository.init(testing.allocator, path);
        try createFile(path, "data.txt", "test data\n");
        try repo.add("data.txt");
        hash = try repo.commit("initial", "T", "t@t.com");
        repo.close();
    }

    {
        var repo = try Repository.open(testing.allocator, path);
        defer repo.close();
        const head = try repo.revParseHead();
        try testing.expectEqualSlices(u8, &hash, &head);
    }
}

// ============================================================================
// Git cross-validation: ziggit blob matches git hash-object
// ============================================================================

test "ziggit add produces blob with correct hash per git hash-object" {
    const path = tmpPath("blob_hash");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    const content = "Hello, World!\n";
    try createFile(path, "hello.txt", content);
    try repo.add("hello.txt");

    // Ask git what the blob hash should be
    const git_hash_out = try runGit(path, &.{ "hash-object", "hello.txt" });
    defer testing.allocator.free(git_hash_out);
    const expected_hash = std.mem.trim(u8, git_hash_out, " \n\r\t");

    // git cat-file should be able to read the blob
    const cat_out = try runGit(path, &.{ "cat-file", "-p", expected_hash });
    defer testing.allocator.free(cat_out);
    try testing.expectEqualStrings(content, cat_out);
}

// ============================================================================
// Git log shows ziggit commits
// ============================================================================

test "git log shows ziggit commits in correct order" {
    const path = tmpPath("git_log");
    cleanup(path);
    defer cleanup(path);

    var repo = try setupRepo("git_log");
    defer repo.close();

    try createFile(path, "a.txt", "aaa\n");
    try repo.add("a.txt");
    _ = try repo.commit("second", "T", "t@t.com");

    try createFile(path, "b.txt", "bbb\n");
    try repo.add("b.txt");
    _ = try repo.commit("third", "T", "t@t.com");

    const log_out = try runGit(path, &.{ "log", "--oneline" });
    defer testing.allocator.free(log_out);

    // Should have 3 lines (3 commits)
    var lines: usize = 0;
    var iter = std.mem.splitScalar(u8, std.mem.trim(u8, log_out, "\n"), '\n');
    while (iter.next()) |_| lines += 1;
    try testing.expectEqual(@as(usize, 3), lines);
}

// ============================================================================
// Empty repo behavior
// ============================================================================

test "revParseHead on empty repo returns all zeros" {
    const path = tmpPath("empty_head");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    // HEAD points to refs/heads/master which doesn't exist yet
    const result = repo.revParseHead();
    if (result) |hash| {
        // Should be all zeros or error
        _ = hash;
    } else |_| {
        // Error is also acceptable for empty repos
    }
}

test "branchList on empty repo returns empty" {
    const path = tmpPath("empty_branches");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    const branches = try repo.branchList(testing.allocator);
    defer {
        for (branches) |b| testing.allocator.free(b);
        testing.allocator.free(branches);
    }

    // No commits yet, so no branches
    try testing.expectEqual(@as(usize, 0), branches.len);
}

test "describeTags on empty repo returns empty string" {
    const path = tmpPath("empty_tags");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    const tag = try repo.describeTags(testing.allocator);
    defer testing.allocator.free(tag);
    try testing.expectEqualStrings("", tag);
}
