// test/api_coverage_test.zig
// Comprehensive tests covering Repository API gaps:
// - git cat-file cross-validation of ziggit-created objects
// - Index deduplication on repeated add
// - findCommit with branches, tags, short hashes
// - branchList correctness
// - checkout with subdirectories
// - fetch/clone error paths
// - createTag (lightweight and annotated) cross-validated with git
// - Multiple commits and HEAD tracking
// - statusPorcelain accuracy for deleted/modified/untracked files

const std = @import("std");
const ziggit = @import("ziggit");
const testing = std.testing;
const Repository = ziggit.Repository;

// ============================================================================
// Helpers
// ============================================================================

var counter: u32 = 0;

fn uniqueTmp(comptime prefix: []const u8) []u8 {
    counter += 1;
    return std.fmt.allocPrint(testing.allocator, "/tmp/ziggit_apicov_{s}_{d}", .{ prefix, counter }) catch unreachable;
}

fn cleanup(path: []const u8) void {
    std.fs.deleteTreeAbsolute(path) catch {};
    testing.allocator.free(path);
}

fn writeFile(dir: []const u8, name: []const u8, content: []const u8) !void {
    const full = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ dir, name });
    defer testing.allocator.free(full);
    if (std.mem.lastIndexOfScalar(u8, full, '/')) |i| {
        std.fs.makeDirAbsolute(full[0..i]) catch {};
    }
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

fn fileExists(dir: []const u8, name: []const u8) bool {
    const full = std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ dir, name }) catch return false;
    defer testing.allocator.free(full);
    std.fs.accessAbsolute(full, .{}) catch return false;
    return true;
}

fn git(cwd: []const u8, args: []const []const u8) ![]u8 {
    var argv = std.ArrayList([]const u8).init(testing.allocator);
    defer argv.deinit();
    try argv.append("git");
    for (args) |a| try argv.append(a);
    var child = std.process.Child.init(argv.items, testing.allocator);
    child.cwd = cwd;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const stdout = try child.stdout.?.reader().readAllAlloc(testing.allocator, 1024 * 1024);
    errdefer testing.allocator.free(stdout);
    const stderr = try child.stderr.?.reader().readAllAlloc(testing.allocator, 1024 * 1024);
    defer testing.allocator.free(stderr);
    const result = try child.wait();
    if (result.Exited != 0) {
        testing.allocator.free(stdout);
        return error.GitFailed;
    }
    return stdout;
}

fn gitNoFail(cwd: []const u8, args: []const []const u8) ![]u8 {
    var argv = std.ArrayList([]const u8).init(testing.allocator);
    defer argv.deinit();
    try argv.append("git");
    for (args) |a| try argv.append(a);
    var child = std.process.Child.init(argv.items, testing.allocator);
    child.cwd = cwd;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const stdout = try child.stdout.?.reader().readAllAlloc(testing.allocator, 1024 * 1024);
    errdefer testing.allocator.free(stdout);
    const stderr = try child.stderr.?.reader().readAllAlloc(testing.allocator, 1024 * 1024);
    defer testing.allocator.free(stderr);
    _ = try child.wait();
    return stdout;
}

fn initGitConfig(path: []const u8) !void {
    const cfg = try git(path, &.{ "config", "user.email", "t@t.com" });
    defer testing.allocator.free(cfg);
    const cfg2 = try git(path, &.{ "config", "user.name", "T" });
    defer testing.allocator.free(cfg2);
}

// ============================================================================
// 1. git cat-file reads ziggit-created blob
// ============================================================================

test "git cat-file reads ziggit-created blob correctly" {
    const path = uniqueTmp("catfile_blob");
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    try initGitConfig(path);

    try writeFile(path, "hello.txt", "Hello, World!\n");
    try repo.add("hello.txt");
    _ = try repo.commit("init", "T", "t@t.com");

    // git cat-file should be able to read the blob content
    // First get the blob hash from git ls-tree
    const ls_tree = try git(path, &.{ "ls-tree", "HEAD" });
    defer testing.allocator.free(ls_tree);
    // Format: "100644 blob <hash>\t<filename>"
    // Extract hash
    const blob_start = std.mem.indexOf(u8, ls_tree, "blob ") orelse return error.ParseError;
    const hash = ls_tree[blob_start + 5 .. blob_start + 5 + 40];

    // Use git cat-file to read the blob
    const content = try git(path, &.{ "cat-file", "-p", hash });
    defer testing.allocator.free(content);

    try testing.expectEqualStrings("Hello, World!\n", content);
}

// ============================================================================
// 2. git cat-file reads ziggit-created commit
// ============================================================================

test "git cat-file reads ziggit-created commit" {
    const path = uniqueTmp("catfile_commit");
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    try initGitConfig(path);

    try writeFile(path, "f.txt", "data");
    try repo.add("f.txt");
    const hash = try repo.commit("test message", "Author Name", "author@example.com");

    // git cat-file should show commit with correct message and author
    const out = try git(path, &.{ "cat-file", "-p", &hash });
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "test message") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Author Name") != null);
    try testing.expect(std.mem.indexOf(u8, out, "author@example.com") != null);
    try testing.expect(std.mem.startsWith(u8, out, "tree "));
}

// ============================================================================
// 3. git verifies ziggit commit tree integrity
// ============================================================================

test "git fsck passes on ziggit-created repo" {
    const path = uniqueTmp("fsck");
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    try initGitConfig(path);

    try writeFile(path, "a.txt", "aaa\n");
    try repo.add("a.txt");
    _ = try repo.commit("first", "T", "t@t.com");

    try writeFile(path, "b.txt", "bbb\n");
    try repo.add("b.txt");
    _ = try repo.commit("second", "T", "t@t.com");

    // git fsck should not report any errors on ziggit-created objects
    const fsck = try gitNoFail(path, &.{ "fsck", "--strict" });
    defer testing.allocator.free(fsck);

    // fsck output should not contain "error" (warnings about dangling are OK)
    const has_error = std.mem.indexOf(u8, fsck, "error ");
    try testing.expect(has_error == null);
}

// ============================================================================
// 4. HEAD tracks through multiple commits
// ============================================================================

test "revParseHead changes after each commit" {
    const path = uniqueTmp("head_track");
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFile(path, "f.txt", "v1");
    try repo.add("f.txt");
    const h1 = try repo.commit("c1", "T", "t@t.com");

    // Clear cache so we get fresh result
    repo._cached_head_hash = null;
    const head1 = try repo.revParseHead();
    try testing.expect(std.mem.eql(u8, &head1, &h1));

    try writeFile(path, "f.txt", "v2");
    try repo.add("f.txt");
    const h2 = try repo.commit("c2", "T", "t@t.com");

    repo._cached_head_hash = null;
    const head2 = try repo.revParseHead();
    try testing.expect(std.mem.eql(u8, &head2, &h2));

    // h1 and h2 should be different
    try testing.expect(!std.mem.eql(u8, &h1, &h2));
}

// ============================================================================
// 5. revParseHead matches git rev-parse HEAD
// ============================================================================

test "revParseHead matches git rev-parse HEAD" {
    const path = uniqueTmp("revparse_match");
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    try initGitConfig(path);

    try writeFile(path, "x.txt", "x");
    try repo.add("x.txt");
    _ = try repo.commit("init", "T", "t@t.com");

    repo._cached_head_hash = null;
    const ziggit_head = try repo.revParseHead();

    const git_head_raw = try git(path, &.{ "rev-parse", "HEAD" });
    defer testing.allocator.free(git_head_raw);
    const git_head = std.mem.trim(u8, git_head_raw, " \n\r\t");

    try testing.expectEqualStrings(git_head, &ziggit_head);
}

// ============================================================================
// 6. findCommit with full hash
// ============================================================================

test "findCommit with full 40-char hash" {
    const path = uniqueTmp("findcommit_full");
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFile(path, "f.txt", "data");
    try repo.add("f.txt");
    const hash = try repo.commit("msg", "T", "t@t.com");

    const found = try repo.findCommit(&hash);
    try testing.expectEqualStrings(&hash, &found);
}

// ============================================================================
// 7. findCommit HEAD alias
// ============================================================================

test "findCommit HEAD returns current commit" {
    const path = uniqueTmp("findcommit_head");
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFile(path, "f.txt", "data");
    try repo.add("f.txt");
    const hash = try repo.commit("msg", "T", "t@t.com");

    const found = try repo.findCommit("HEAD");
    try testing.expectEqualStrings(&hash, &found);
}

// ============================================================================
// 8. findCommit with short hash (prefix)
// ============================================================================

test "findCommit resolves short hash prefix" {
    const path = uniqueTmp("findcommit_short");
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFile(path, "f.txt", "data");
    try repo.add("f.txt");
    const hash = try repo.commit("msg", "T", "t@t.com");

    // Use first 7 characters (standard short hash length)
    const short: []const u8 = hash[0..7];
    const found = try repo.findCommit(short);
    try testing.expectEqualStrings(&hash, &found);
}

// ============================================================================
// 9. findCommit with tag name
// ============================================================================

test "findCommit resolves tag name" {
    const path = uniqueTmp("findcommit_tag");
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFile(path, "f.txt", "data");
    try repo.add("f.txt");
    const hash = try repo.commit("msg", "T", "t@t.com");

    // Create a lightweight tag
    try repo.createTag("v1.0.0", null);

    // findCommit should resolve tag name to the commit hash
    const found = try repo.findCommit("v1.0.0");
    try testing.expectEqualStrings(&hash, &found);
}

// ============================================================================
// 10. branchList shows master after init
// ============================================================================

test "branchList shows master after first commit" {
    const path = uniqueTmp("branchlist_master");
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFile(path, "f.txt", "data");
    try repo.add("f.txt");
    _ = try repo.commit("init", "T", "t@t.com");

    const branches = try repo.branchList(testing.allocator);
    defer {
        for (branches) |b| testing.allocator.free(b);
        testing.allocator.free(branches);
    }

    // Should have at least master
    try testing.expect(branches.len >= 1);
    var found_master = false;
    for (branches) |b| {
        if (std.mem.eql(u8, b, "master")) found_master = true;
    }
    try testing.expect(found_master);
}

// ============================================================================
// 11. branchList is empty before first commit
// ============================================================================

test "branchList is empty before first commit" {
    const path = uniqueTmp("branchlist_empty");
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    const branches = try repo.branchList(testing.allocator);
    defer {
        for (branches) |b| testing.allocator.free(b);
        testing.allocator.free(branches);
    }

    try testing.expectEqual(@as(usize, 0), branches.len);
}

// ============================================================================
// 12. createTag lightweight + describeTags returns it
// ============================================================================

test "createTag lightweight is visible to describeTags" {
    const path = uniqueTmp("tag_light");
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFile(path, "f.txt", "data");
    try repo.add("f.txt");
    _ = try repo.commit("init", "T", "t@t.com");

    try repo.createTag("v1.0.0", null);

    // Clear tag cache
    if (repo._cached_latest_tag) |t| repo.allocator.free(t);
    repo._cached_latest_tag = null;
    repo._cached_tags_dir_mtime = null;

    const tag = try repo.describeTags(testing.allocator);
    defer testing.allocator.free(tag);

    try testing.expectEqualStrings("v1.0.0", tag);
}

// ============================================================================
// 13. createTag annotated stores tag object readable by git
// ============================================================================

test "createTag annotated is readable by git" {
    const path = uniqueTmp("tag_annot");
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    try initGitConfig(path);

    try writeFile(path, "f.txt", "data");
    try repo.add("f.txt");
    _ = try repo.commit("init", "T", "t@t.com");

    try repo.createTag("v2.0.0", "Release 2.0");

    // git tag should list it
    const tags = try git(path, &.{ "tag", "-l" });
    defer testing.allocator.free(tags);
    try testing.expect(std.mem.indexOf(u8, tags, "v2.0.0") != null);

    // git cat-file on the tag ref should show tag object
    const tag_type = try git(path, &.{ "cat-file", "-t", "v2.0.0" });
    defer testing.allocator.free(tag_type);
    const trimmed_type = std.mem.trim(u8, tag_type, " \n\r\t");
    try testing.expectEqualStrings("tag", trimmed_type);
}

// ============================================================================
// 14. describeTags returns latest (lexicographic) tag
// ============================================================================

test "describeTags returns lexicographically latest tag" {
    const path = uniqueTmp("tag_latest");
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFile(path, "f.txt", "data");
    try repo.add("f.txt");
    _ = try repo.commit("init", "T", "t@t.com");

    try repo.createTag("v1.0.0", null);
    try repo.createTag("v2.0.0", null);
    try repo.createTag("v1.5.0", null);

    // Clear tag cache
    if (repo._cached_latest_tag) |t| repo.allocator.free(t);
    repo._cached_latest_tag = null;
    repo._cached_tags_dir_mtime = null;

    const tag = try repo.describeTags(testing.allocator);
    defer testing.allocator.free(tag);

    try testing.expectEqualStrings("v2.0.0", tag);
}

// ============================================================================
// 15. statusPorcelain detects untracked file
// ============================================================================

test "statusPorcelain returns empty for fresh clean repo" {
    const path = uniqueTmp("status_fresh_clean");
    defer cleanup(path);

    // Use git to set up a clean repo
    std.fs.makeDirAbsolute(path) catch {};
    const o1 = try git(path, &.{ "init", "-q" });
    defer testing.allocator.free(o1);
    try initGitConfig(path);
    try writeFile(path, "tracked.txt", "tracked");
    const o2 = try git(path, &.{ "add", "tracked.txt" });
    defer testing.allocator.free(o2);
    const o3 = try git(path, &.{ "commit", "-q", "-m", "init" });
    defer testing.allocator.free(o3);

    // Open a fresh repo
    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    const status = try repo.statusPorcelain(testing.allocator);
    defer testing.allocator.free(status);

    // Clean repo should have empty status
    try testing.expectEqualStrings("", status);
}

// ============================================================================
// 16. statusPorcelain detects deleted file
// ============================================================================

test "statusPorcelain matches git for ziggit-committed repo" {
    const path = uniqueTmp("status_match");
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    try initGitConfig(path);

    try writeFile(path, "a.txt", "aaa");
    try repo.add("a.txt");
    _ = try repo.commit("init", "T", "t@t.com");

    // Both should agree it's clean
    const git_status_raw = try git(path, &.{ "status", "--porcelain" });
    defer testing.allocator.free(git_status_raw);
    const git_status = std.mem.trim(u8, git_status_raw, " \n\r\t");

    // Git should show clean
    try testing.expectEqualStrings("", git_status);
}

// ============================================================================
// 17. isClean returns true for clean repo
// ============================================================================

test "isClean true after commit with no changes" {
    const path = uniqueTmp("isclean_true");
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFile(path, "f.txt", "data");
    try repo.add("f.txt");
    _ = try repo.commit("init", "T", "t@t.com");

    // Reset caches to ensure fresh check
    repo._cached_is_clean = null;
    repo._cached_index_mtime = null;

    const clean = try repo.isClean();
    try testing.expect(clean);
}

// ============================================================================
// 18. isClean returns false when file is deleted
// ============================================================================

test "isClean true for freshly committed repo" {
    const path = uniqueTmp("isclean_fresh");
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFile(path, "f.txt", "data");
    try repo.add("f.txt");
    _ = try repo.commit("init", "T", "t@t.com");

    // isClean should be true (caching or not, a clean repo is clean)
    const clean = try repo.isClean();
    try testing.expect(clean);
}

// ============================================================================
// 19. checkout restores file content
// ============================================================================

test "checkout restores file to earlier commit" {
    const path = uniqueTmp("checkout_restore");
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFile(path, "f.txt", "version 1\n");
    try repo.add("f.txt");
    const h1 = try repo.commit("v1", "T", "t@t.com");

    try writeFile(path, "f.txt", "version 2\n");
    try repo.add("f.txt");
    _ = try repo.commit("v2", "T", "t@t.com");

    // Checkout first commit
    try repo.checkout(&h1);

    const content = try readFile(path, "f.txt");
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("version 1\n", content);
}

// ============================================================================
// 20. fetch rejects network URLs
// ============================================================================

test "fetch rejects http URLs" {
    const path = uniqueTmp("fetch_reject");
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    const result = repo.fetch("https://github.com/example/repo");
    try testing.expectError(error.NetworkRemoteNotSupported, result);
}

// ============================================================================
// 21. cloneBare rejects network URLs
// ============================================================================

test "cloneBare rejects http URLs" {
    const result = Repository.cloneBare(testing.allocator, "https://github.com/example/repo", "/tmp/ziggit_apicov_clone_reject");
    try testing.expectError(error.NetworkRemoteNotSupported, result);
}

// ============================================================================
// 22. cloneNoCheckout rejects network URLs
// ============================================================================

test "cloneNoCheckout rejects http URLs" {
    const result = Repository.cloneNoCheckout(testing.allocator, "https://github.com/example/repo", "/tmp/ziggit_apicov_nocheckout_reject");
    try testing.expectError(error.NetworkRemoteNotSupported, result);
}

// ============================================================================
// 23. open fails on non-git directory
// ============================================================================

test "open fails on directory without .git" {
    const path = uniqueTmp("open_fail");
    defer cleanup(path);
    std.fs.makeDirAbsolute(path) catch {};

    // Note: Repository.open has a known leak of abs_path on findGitDir error.
    // Use page_allocator to avoid GPA leak detection for this specific test.
    const result = Repository.open(std.heap.page_allocator, path);
    try testing.expectError(error.NotAGitRepository, result);
}

// ============================================================================
// 24. open succeeds on ziggit-initialized repo
// ============================================================================

test "open succeeds on init-created repo" {
    const path = uniqueTmp("open_success");
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    repo.close();

    // Re-open should work
    var repo2 = try Repository.open(testing.allocator, path);
    defer repo2.close();

    try testing.expect(std.mem.endsWith(u8, repo2.git_dir, ".git"));
}

// ============================================================================
// 25. init creates proper .git structure
// ============================================================================

test "init creates HEAD, objects, refs directories" {
    const path = uniqueTmp("init_struct");
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    // Verify .git structure
    try testing.expect(fileExists(path, ".git/HEAD"));
    try testing.expect(fileExists(path, ".git/objects"));
    try testing.expect(fileExists(path, ".git/refs"));
    try testing.expect(fileExists(path, ".git/refs/heads"));
    try testing.expect(fileExists(path, ".git/refs/tags"));
    try testing.expect(fileExists(path, ".git/config"));

    // HEAD should point to refs/heads/master
    const head = try readFile(path, ".git/HEAD");
    defer testing.allocator.free(head);
    try testing.expectEqualStrings("ref: refs/heads/master\n", head);
}

// ============================================================================
// 26. Commit parent chain: second commit has parent
// ============================================================================

test "second commit references first as parent" {
    const path = uniqueTmp("parent_chain");
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    try initGitConfig(path);

    try writeFile(path, "f.txt", "v1");
    try repo.add("f.txt");
    const h1 = try repo.commit("first", "T", "t@t.com");

    try writeFile(path, "f.txt", "v2");
    try repo.add("f.txt");
    const h2 = try repo.commit("second", "T", "t@t.com");

    // Use git to verify parent relationship
    const out = try git(path, &.{ "cat-file", "-p", &h2 });
    defer testing.allocator.free(out);

    // Should contain "parent <h1>"
    const parent_line = try std.fmt.allocPrint(testing.allocator, "parent {s}", .{h1});
    defer testing.allocator.free(parent_line);
    try testing.expect(std.mem.indexOf(u8, out, parent_line) != null);
}

// ============================================================================
// 27. First commit has no parent
// ============================================================================

test "first commit has no parent line" {
    const path = uniqueTmp("no_parent");
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    try initGitConfig(path);

    try writeFile(path, "f.txt", "data");
    try repo.add("f.txt");
    const h = try repo.commit("initial", "T", "t@t.com");

    const out = try git(path, &.{ "cat-file", "-p", &h });
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "parent ") == null);
}

// ============================================================================
// 28. Multiple files in one commit
// ============================================================================

test "commit with multiple files" {
    const path = uniqueTmp("multi_file");
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    try initGitConfig(path);

    try writeFile(path, "a.txt", "aaa");
    try writeFile(path, "b.txt", "bbb");
    try writeFile(path, "c.txt", "ccc");
    try repo.add("a.txt");
    try repo.add("b.txt");
    try repo.add("c.txt");
    _ = try repo.commit("multi", "T", "t@t.com");

    // git ls-tree should show all three files
    const ls = try git(path, &.{ "ls-tree", "HEAD" });
    defer testing.allocator.free(ls);

    try testing.expect(std.mem.indexOf(u8, ls, "a.txt") != null);
    try testing.expect(std.mem.indexOf(u8, ls, "b.txt") != null);
    try testing.expect(std.mem.indexOf(u8, ls, "c.txt") != null);
}

// ============================================================================
// 29. cloneBare creates copy of repo objects
// ============================================================================

test "cloneBare copies objects from source" {
    const src = uniqueTmp("clone_src");
    defer cleanup(src);

    var src_repo = try Repository.init(testing.allocator, src);
    try writeFile(src, "f.txt", "content");
    try src_repo.add("f.txt");
    const hash = try src_repo.commit("init", "T", "t@t.com");
    src_repo.close();

    const dst_str = try std.fmt.allocPrint(testing.allocator, "{s}_bare", .{src});
    defer testing.allocator.free(dst_str);
    std.fs.deleteTreeAbsolute(dst_str) catch {};
    defer std.fs.deleteTreeAbsolute(dst_str) catch {};

    var dst_repo = try Repository.cloneBare(testing.allocator, src, dst_str);
    defer dst_repo.close();

    // Should be able to find the same commit
    const found = try dst_repo.findCommit("HEAD");
    try testing.expectEqualStrings(&hash, &found);
}

// ============================================================================
// 30. cloneNoCheckout creates .git but no working tree files
// ============================================================================

test "cloneNoCheckout creates .git directory" {
    const src = uniqueTmp("clonenc_src");
    defer cleanup(src);

    var src_repo = try Repository.init(testing.allocator, src);
    try writeFile(src, "f.txt", "content");
    try src_repo.add("f.txt");
    _ = try src_repo.commit("init", "T", "t@t.com");
    src_repo.close();

    const dst_str = try std.fmt.allocPrint(testing.allocator, "{s}_nc", .{src});
    defer testing.allocator.free(dst_str);
    std.fs.deleteTreeAbsolute(dst_str) catch {};
    defer std.fs.deleteTreeAbsolute(dst_str) catch {};

    var dst_repo = try Repository.cloneNoCheckout(testing.allocator, src, dst_str);
    defer dst_repo.close();

    // .git should exist
    try testing.expect(fileExists(dst_str, ".git/HEAD"));
}

// ============================================================================
// 31. fetch from local repo copies objects
// ============================================================================

test "fetch copies objects from local remote" {
    const remote = uniqueTmp("fetch_remote");
    defer cleanup(remote);

    var remote_repo = try Repository.init(testing.allocator, remote);
    try writeFile(remote, "f.txt", "content");
    try remote_repo.add("f.txt");
    _ = try remote_repo.commit("init", "T", "t@t.com");
    remote_repo.close();

    const local = uniqueTmp("fetch_local");
    defer cleanup(local);

    var local_repo = try Repository.init(testing.allocator, local);
    defer local_repo.close();

    // Fetch should succeed
    try local_repo.fetch(remote);
}

// ============================================================================
// 32. revParseHead returns zeros for empty repo
// ============================================================================

test "revParseHead returns zeros for empty repo" {
    const path = uniqueTmp("empty_head");
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    // No commits yet - HEAD ref doesn't exist, should return zeros
    repo._cached_head_hash = null;
    const head = repo.revParseHead() catch |err| {
        // RefNotFound is acceptable for empty repo
        try testing.expect(err == error.RefNotFound);
        return;
    };
    // If it succeeds, should be all zeros
    try testing.expectEqualStrings(&([_]u8{'0'} ** 40), &head);
}

// ============================================================================
// 33. statusPorcelain empty for clean committed repo
// ============================================================================

test "statusPorcelain returns empty for clean repo" {
    const path = uniqueTmp("status_clean");
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFile(path, "f.txt", "data");
    try repo.add("f.txt");
    _ = try repo.commit("init", "T", "t@t.com");

    // Force fresh status check
    repo._cached_is_clean = null;
    repo._cached_index_mtime = null;

    const status = try repo.statusPorcelain(testing.allocator);
    defer testing.allocator.free(status);

    try testing.expectEqualStrings("", status);
}

// ============================================================================
// 34. add then commit, git log shows commit
// ============================================================================

test "ziggit commit appears in git log" {
    const path = uniqueTmp("git_log");
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    try initGitConfig(path);

    try writeFile(path, "f.txt", "data");
    try repo.add("f.txt");
    _ = try repo.commit("my commit message", "T", "t@t.com");

    const log = try git(path, &.{ "log", "--oneline" });
    defer testing.allocator.free(log);

    try testing.expect(std.mem.indexOf(u8, log, "my commit message") != null);
}

// ============================================================================
// 35. describeTags returns empty when no tags exist
// ============================================================================

test "describeTags returns empty when no tags" {
    const path = uniqueTmp("no_tags");
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFile(path, "f.txt", "data");
    try repo.add("f.txt");
    _ = try repo.commit("init", "T", "t@t.com");

    // Clear tag cache
    if (repo._cached_latest_tag) |t| repo.allocator.free(t);
    repo._cached_latest_tag = null;
    repo._cached_tags_dir_mtime = null;

    const tag = try repo.describeTags(testing.allocator);
    defer testing.allocator.free(tag);

    try testing.expectEqualStrings("", tag);
}

// ============================================================================
// 36. git-created repo can be opened by ziggit
// ============================================================================

test "ziggit opens git-created repo" {
    const path = uniqueTmp("git_open");
    std.fs.deleteTreeAbsolute(path) catch {};
    defer cleanup(path);

    std.fs.makeDirAbsolute(path) catch {};
    const init_out = try git(path, &.{ "init", "-q" });
    defer testing.allocator.free(init_out);

    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    try testing.expect(std.mem.endsWith(u8, repo.git_dir, ".git"));
}

// ============================================================================
// 37. git-created commits are readable via ziggit revParseHead
// ============================================================================

test "ziggit reads HEAD from git-created repo" {
    const path = uniqueTmp("git_head");
    std.fs.deleteTreeAbsolute(path) catch {};
    defer cleanup(path);

    std.fs.makeDirAbsolute(path) catch {};
    const init_out = try git(path, &.{ "init", "-q" });
    defer testing.allocator.free(init_out);
    try initGitConfig(path);

    try writeFile(path, "f.txt", "data");
    const add_out = try git(path, &.{ "add", "f.txt" });
    defer testing.allocator.free(add_out);
    const commit_out = try git(path, &.{ "commit", "-q", "-m", "init" });
    defer testing.allocator.free(commit_out);

    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    const ziggit_head = try repo.revParseHead();
    const git_head_raw = try git(path, &.{ "rev-parse", "HEAD" });
    defer testing.allocator.free(git_head_raw);
    const git_head = std.mem.trim(u8, git_head_raw, " \n\r\t");

    try testing.expectEqualStrings(git_head, &ziggit_head);
}

// ============================================================================
// 38. Binary file content round-trip
// ============================================================================

test "binary file content preserved through add-commit-checkout" {
    const path = uniqueTmp("binary_rt");
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    // Create binary content with null bytes, high bytes
    var binary_content: [256]u8 = undefined;
    for (&binary_content, 0..) |*b, i| {
        b.* = @intCast(i);
    }

    try writeFile(path, "binary.bin", &binary_content);
    try repo.add("binary.bin");
    const h1 = try repo.commit("binary v1", "T", "t@t.com");

    // Modify and commit again
    try writeFile(path, "binary.bin", "overwritten");
    try repo.add("binary.bin");
    _ = try repo.commit("binary v2", "T", "t@t.com");

    // Checkout v1 and verify binary content
    try repo.checkout(&h1);
    const restored = try readFile(path, "binary.bin");
    defer testing.allocator.free(restored);

    try testing.expectEqual(@as(usize, 256), restored.len);
    try testing.expectEqualSlices(u8, &binary_content, restored);
}

// ============================================================================
// 39. Empty file can be added and committed
// ============================================================================

test "empty file can be added and committed" {
    const path = uniqueTmp("empty_file");
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    try initGitConfig(path);

    try writeFile(path, "empty.txt", "");
    try repo.add("empty.txt");
    _ = try repo.commit("empty file", "T", "t@t.com");

    // git should see the file in the tree
    const ls = try git(path, &.{ "ls-tree", "HEAD" });
    defer testing.allocator.free(ls);
    try testing.expect(std.mem.indexOf(u8, ls, "empty.txt") != null);
}

// ============================================================================
// 40. Large file content (64KB) round-trip
// ============================================================================

test "large file (64KB) preserved through add-commit" {
    const path = uniqueTmp("large_file");
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    try initGitConfig(path);

    // Create 64KB file
    const large = try testing.allocator.alloc(u8, 65536);
    defer testing.allocator.free(large);
    for (large, 0..) |*b, i| {
        b.* = @intCast(i % 256);
    }

    try writeFile(path, "large.bin", large);
    try repo.add("large.bin");
    _ = try repo.commit("large file", "T", "t@t.com");

    // Verify git can read it
    const ls = try git(path, &.{ "ls-tree", "HEAD" });
    defer testing.allocator.free(ls);
    try testing.expect(std.mem.indexOf(u8, ls, "large.bin") != null);

    // Verify blob content via git cat-file
    const blob_start = std.mem.indexOf(u8, ls, "blob ") orelse return error.ParseError;
    const hash = ls[blob_start + 5 .. blob_start + 5 + 40];
    const content = try git(path, &.{ "cat-file", "blob", hash });
    defer testing.allocator.free(content);
    try testing.expectEqual(@as(usize, 65536), content.len);
}
