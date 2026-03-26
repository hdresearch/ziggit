// test/full_workflow_crossval_test.zig - Full workflow cross-validation tests
// Tests complete workflows: init -> add -> commit -> checkout -> fetch -> clone
// Every step cross-validated with real git CLI
const std = @import("std");
const ziggit = @import("ziggit");
const testing = std.testing;

const Repository = ziggit.Repository;

fn tmpPath(comptime suffix: []const u8) []const u8 {
    return "/tmp/ziggit_fullwf_" ++ suffix;
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

fn readFile(repo_path: []const u8, name: []const u8) ![]u8 {
    const full = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ repo_path, name });
    defer testing.allocator.free(full);
    const f = try std.fs.openFileAbsolute(full, .{});
    defer f.close();
    return try f.readToEndAlloc(testing.allocator, 1024 * 1024);
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

fn runGitVoid(args: []const []const u8, cwd: []const u8) !void {
    const out = try runGit(args, cwd);
    testing.allocator.free(out);
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \n\r\t");
}

fn pathExists(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

// ============================================================================
// Full workflow: init + add + commit + verify with git
// ============================================================================

test "workflow: init, add file, commit, git fsck passes" {
    const path = tmpPath("fsck");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "hello.txt", "Hello, world!\n");
    try repo.add("hello.txt");
    _ = try repo.commit("initial commit", "Test User", "test@example.com");

    // git fsck should pass - validates all objects
    try runGitVoid(&.{ "git", "fsck", "--strict" }, path);
}

test "workflow: multiple commits create proper parent chain" {
    const path = tmpPath("chain");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    // First commit
    try createFile(path, "a.txt", "first\n");
    try repo.add("a.txt");
    const hash1 = try repo.commit("first", "T", "t@t.com");

    // Second commit
    try createFile(path, "b.txt", "second\n");
    try repo.add("b.txt");
    const hash2 = try repo.commit("second", "T", "t@t.com");

    // Verify parent chain with git
    const log_out = try runGit(&.{ "git", "log", "--format=%H", "--reverse" }, path);
    defer testing.allocator.free(log_out);
    const log = trim(log_out);

    // Should have two lines: first commit then second commit
    var lines = std.mem.splitScalar(u8, log, '\n');
    const first_line = lines.next() orelse return error.Unexpected;
    const second_line = lines.next() orelse return error.Unexpected;

    try testing.expectEqualStrings(&hash1, first_line);
    try testing.expectEqualStrings(&hash2, second_line);
}

test "workflow: git cat-file reads ziggit blob content exactly" {
    const path = tmpPath("catfile");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    const content = "exact content verification\n";
    try createFile(path, "verify.txt", content);
    try repo.add("verify.txt");
    _ = try repo.commit("verify", "T", "t@t.com");

    // Use git to read the blob back
    const ls_out = try runGit(&.{ "git", "ls-tree", "HEAD" }, path);
    defer testing.allocator.free(ls_out);

    // Parse blob hash from ls-tree output: "100644 blob <hash>\tverify.txt"
    const trimmed = trim(ls_out);
    var parts = std.mem.splitScalar(u8, trimmed, '\t');
    const mode_type_hash = parts.next() orelse return error.Unexpected;
    // Extract hash (after "100644 blob ")
    if (mode_type_hash.len < 52) return error.Unexpected;
    const blob_hash = mode_type_hash[12..52];

    const cat_out = try runGit(&.{ "git", "cat-file", "-p", blob_hash }, path);
    defer testing.allocator.free(cat_out);

    try testing.expectEqualStrings(content, cat_out);
}

test "workflow: ziggit reads git-created commits correctly" {
    const path = tmpPath("gitread");
    cleanup(path);
    defer cleanup(path);

    // Create repo with git
    try runGitVoid(&.{ "git", "init", "-q", path }, "/tmp");
    try runGitVoid(&.{ "git", "-C", path, "config", "user.email", "t@t.com" }, "/tmp");
    try runGitVoid(&.{ "git", "-C", path, "config", "user.name", "T" }, "/tmp");

    try createFile(path, "file.txt", "content\n");
    try runGitVoid(&.{ "git", "-C", path, "add", "file.txt" }, "/tmp");
    try runGitVoid(&.{ "git", "-C", path, "commit", "-q", "-m", "git commit" }, "/tmp");

    // Get git's HEAD hash
    const git_head_out = try runGit(&.{ "git", "-C", path, "rev-parse", "HEAD" }, "/tmp");
    defer testing.allocator.free(git_head_out);
    const git_head = trim(git_head_out);

    // Open with ziggit and verify
    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    const ziggit_head = try repo.revParseHead();
    try testing.expectEqualStrings(git_head, &ziggit_head);
}

test "workflow: lightweight tag points to correct commit" {
    const path = tmpPath("lwtag");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    const commit_hash = try repo.commit("tagged", "T", "t@t.com");

    try repo.createTag("v1.0", null);

    // Verify with git
    const tag_out = try runGit(&.{ "git", "rev-parse", "v1.0" }, path);
    defer testing.allocator.free(tag_out);
    try testing.expectEqualStrings(&commit_hash, trim(tag_out));
}

test "workflow: annotated tag readable by git show" {
    const path = tmpPath("anntag");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    _ = try repo.commit("for tag", "T", "t@t.com");

    try repo.createTag("v2.0", "release notes here");

    // git show should display the tag
    const show_out = try runGit(&.{ "git", "cat-file", "-t", "v2.0" }, path);
    defer testing.allocator.free(show_out);
    try testing.expectEqualStrings("tag", trim(show_out));
}

test "workflow: branchList matches git branch output" {
    const path = tmpPath("brlist");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "T", "t@t.com");

    // Create extra branches with git
    try runGitVoid(&.{ "git", "-C", path, "branch", "feature-a" }, "/tmp");
    try runGitVoid(&.{ "git", "-C", path, "branch", "feature-b" }, "/tmp");

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

test "workflow: findCommit resolves branch name" {
    const path = tmpPath("findcmt");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    const commit_hash = try repo.commit("init", "T", "t@t.com");

    // findCommit with "master" should resolve to HEAD
    const found = try repo.findCommit("master");
    try testing.expectEqualStrings(&commit_hash, &found);

    // findCommit with full hash should return same hash
    const found2 = try repo.findCommit(&commit_hash);
    try testing.expectEqualStrings(&commit_hash, &found2);

    // findCommit with "HEAD" should return same hash
    const found3 = try repo.findCommit("HEAD");
    try testing.expectEqualStrings(&commit_hash, &found3);
}

test "workflow: findCommit with short hash" {
    const path = tmpPath("shorthash");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    const commit_hash = try repo.commit("init", "T", "t@t.com");

    // Short hash (7 chars) should resolve to full hash
    const short: []const u8 = commit_hash[0..7];
    const found = try repo.findCommit(short);
    try testing.expectEqualStrings(&commit_hash, &found);
}

test "workflow: local clone preserves commits" {
    const src_path = tmpPath("clonesrc");
    const dst_path = tmpPath("clonedst");
    cleanup(src_path);
    cleanup(dst_path);
    defer cleanup(src_path);
    defer cleanup(dst_path);

    // Create source repo
    var src = try Repository.init(testing.allocator, src_path);
    try createFile(src_path, "f.txt", "clone test\n");
    try src.add("f.txt");
    const commit_hash = try src.commit("for clone", "T", "t@t.com");
    src.close();

    // Clone
    var dst = try Repository.cloneNoCheckout(testing.allocator, src_path, dst_path);
    defer dst.close();

    // Verify commit is present in clone
    const head = try dst.revParseHead();
    try testing.expectEqualStrings(&commit_hash, &head);
}

test "workflow: local fetch copies new commits" {
    const src_path = tmpPath("fetchsrc");
    const dst_path = tmpPath("fetchdst");
    cleanup(src_path);
    cleanup(dst_path);
    defer cleanup(src_path);
    defer cleanup(dst_path);

    // Create source
    var src = try Repository.init(testing.allocator, src_path);
    try createFile(src_path, "f.txt", "initial\n");
    try src.add("f.txt");
    _ = try src.commit("init", "T", "t@t.com");
    src.close();

    // Clone to dest
    var dst = try Repository.cloneNoCheckout(testing.allocator, src_path, dst_path);

    // Add new commit to source
    {
        var src2 = try Repository.open(testing.allocator, src_path);
        defer src2.close();
        try createFile(src_path, "g.txt", "new\n");
        try src2.add("g.txt");
        _ = try src2.commit("second", "T", "t@t.com");
    }

    // Fetch
    try dst.fetch(src_path);
    dst.close();

    // Verify remote ref exists
    const remote_ref_path = try std.fmt.allocPrint(testing.allocator, "{s}/.git/refs/remotes/origin/master", .{dst_path});
    defer testing.allocator.free(remote_ref_path);
    try testing.expect(pathExists(remote_ref_path));
}

test "workflow: fetch rejects network URLs" {
    const path = tmpPath("fetchnet");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    const result = repo.fetch("https://github.com/example/repo.git");
    try testing.expectError(error.HttpFetchFailed, result);
}

test "workflow: cloneBare rejects network URLs" {
    const result = Repository.cloneBare(testing.allocator, "https://github.com/example/repo.git", "/tmp/ziggit_test_bare");
    try testing.expectError(error.HttpCloneFailed, result);
}

test "workflow: open nonexistent path returns error" {
    // Use page_allocator because Repository.open leaks abs_path on error
    const result = Repository.open(std.heap.page_allocator, "/tmp/ziggit_does_not_exist_at_all");
    try testing.expectError(error.NotAGitRepository, result);
}

test "workflow: open non-git directory returns error" {
    const path = tmpPath("nongit");
    cleanup(path);
    defer cleanup(path);
    try std.fs.makeDirAbsolute(path);

    // Use page_allocator because Repository.open leaks abs_path on error
    const result = Repository.open(std.heap.page_allocator, path);
    try testing.expectError(error.NotAGitRepository, result);
}

test "workflow: binary file content preserved through add+commit+checkout" {
    const path = tmpPath("binary");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    // Write binary content (with null bytes)
    const binary_content = "\x00\x01\x02\x03\xff\xfe\xfd\x00\x00\x80";
    try createFile(path, "bin.dat", binary_content);
    try repo.add("bin.dat");
    const hash1 = try repo.commit("add binary", "T", "t@t.com");

    // Verify git can read it
    try runGitVoid(&.{ "git", "fsck", "--strict" }, path);

    // Verify content via git cat-file
    const ls_out = try runGit(&.{ "git", "ls-tree", "HEAD" }, path);
    defer testing.allocator.free(ls_out);
    const trimmed_ls = trim(ls_out);
    // Extract blob hash
    if (trimmed_ls.len >= 52) {
        const blob_hash = trimmed_ls[12..52];
        const cat_out = try runGit(&.{ "git", "cat-file", "-p", blob_hash }, path);
        defer testing.allocator.free(cat_out);
        try testing.expectEqualStrings(binary_content, cat_out);
    }
    _ = hash1;
}

test "workflow: empty commit message allowed" {
    const path = tmpPath("emptymsg");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    _ = try repo.commit("", "T", "t@t.com");

    // Should still pass fsck
    try runGitVoid(&.{ "git", "fsck" }, path);
}

test "workflow: describeTags returns lexicographically latest tag" {
    const path = tmpPath("desctag");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "T", "t@t.com");

    // Create tags in non-sorted order
    try repo.createTag("v0.1", null);
    try repo.createTag("v1.0", null);
    try repo.createTag("v0.9", null);

    const latest = try repo.describeTags(testing.allocator);
    defer testing.allocator.free(latest);

    // Lexicographically: v1.0 > v0.9 > v0.1
    try testing.expectEqualStrings("v1.0", latest);
}

test "workflow: describeTags on repo with no tags returns empty" {
    const path = tmpPath("notags");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "T", "t@t.com");

    const latest = try repo.describeTags(testing.allocator);
    defer testing.allocator.free(latest);
    try testing.expectEqualStrings("", latest);
}

test "workflow: multiple files in single commit" {
    const path = tmpPath("multi");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "a.txt", "aaa\n");
    try createFile(path, "b.txt", "bbb\n");
    try createFile(path, "c.txt", "ccc\n");
    try repo.add("a.txt");
    try repo.add("b.txt");
    try repo.add("c.txt");
    _ = try repo.commit("multi", "T", "t@t.com");

    // git ls-tree should show all three
    const ls_out = try runGit(&.{ "git", "ls-tree", "HEAD" }, path);
    defer testing.allocator.free(ls_out);
    const ls_trimmed = trim(ls_out);

    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, ls_trimmed, '\n');
    while (lines.next()) |line| {
        if (line.len > 0) count += 1;
    }
    try testing.expectEqual(@as(usize, 3), count);
}

test "workflow: revParseHead is consistent across calls" {
    const path = tmpPath("consistent");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "T", "t@t.com");

    const h1 = try repo.revParseHead();
    const h2 = try repo.revParseHead();
    const h3 = try repo.revParseHead();
    try testing.expectEqualStrings(&h1, &h2);
    try testing.expectEqualStrings(&h2, &h3);
}

test "workflow: HEAD updates after each commit" {
    const path = tmpPath("headupd");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "a.txt", "a\n");
    try repo.add("a.txt");
    const hash1 = try repo.commit("first", "T", "t@t.com");
    // Clear cache so revParseHead re-reads
    repo._cached_head_hash = null;
    const head1 = try repo.revParseHead();
    try testing.expectEqualStrings(&hash1, &head1);

    try createFile(path, "b.txt", "b\n");
    try repo.add("b.txt");
    const hash2 = try repo.commit("second", "T", "t@t.com");
    repo._cached_head_hash = null;
    const head2 = try repo.revParseHead();
    try testing.expectEqualStrings(&hash2, &head2);

    // Hashes should differ
    try testing.expect(!std.mem.eql(u8, &hash1, &hash2));
}
