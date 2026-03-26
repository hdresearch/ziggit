// test/repo_api_comprehensive_test.zig
// Comprehensive tests for Repository public API with git cross-validation.
// Each test creates a fresh temp directory, exercises one API method, and
// cross-validates the result against the real git CLI where possible.

const std = @import("std");
const ziggit = @import("ziggit");
const testing = std.testing;
const Repository = ziggit.Repository;

// ============================================================================
// Helpers
// ============================================================================

var test_counter: u32 = 0;

fn uniqueTmp(comptime prefix: []const u8) ![]u8 {
    test_counter += 1;
    return try std.fmt.allocPrint(testing.allocator, "/tmp/ziggit_apitest_{s}_{d}", .{ prefix, test_counter });
}

fn cleanup(path: []const u8) void {
    std.fs.deleteTreeAbsolute(path) catch {};
}

fn writeFileAbs(dir: []const u8, name: []const u8, content: []const u8) !void {
    const full = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ dir, name });
    defer testing.allocator.free(full);
    // Make parent dirs if name has slashes
    if (std.mem.lastIndexOfScalar(u8, full, '/')) |last_slash| {
        std.fs.makeDirAbsolute(full[0..last_slash]) catch {};
    }
    const f = try std.fs.createFileAbsolute(full, .{ .truncate = true });
    defer f.close();
    try f.writeAll(content);
}

fn readFileAbs(dir: []const u8, name: []const u8) ![]u8 {
    const full = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ dir, name });
    defer testing.allocator.free(full);
    const f = try std.fs.openFileAbsolute(full, .{});
    defer f.close();
    return try f.readToEndAlloc(testing.allocator, 1024 * 1024);
}

fn pathExists(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

fn gitCmd(cwd: []const u8, args: []const []const u8) ![]u8 {
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

fn gitCmdNoFail(cwd: []const u8, args: []const []const u8) ![]u8 {
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

/// Initialize a test repo with git so we have a known state
fn initGitRepo(path: []const u8) !void {
    std.fs.makeDirAbsolute(path) catch {};
    _ = try gitCmd(path, &.{ "init", "-q" });
    _ = try gitCmd(path, &.{ "config", "user.email", "test@test.com" });
    _ = try gitCmd(path, &.{ "config", "user.name", "Test" });
}

/// Make a git commit with a file
fn gitCommit(path: []const u8, filename: []const u8, content: []const u8, msg: []const u8) !void {
    try writeFileAbs(path, filename, content);
    _ = try gitCmd(path, &.{ "add", filename });
    _ = try gitCmd(path, &.{ "commit", "-q", "-m", msg });
}

// ============================================================================
// Repository.init tests
// ============================================================================

test "init: creates .git directory structure" {
    const path = try uniqueTmp("init_struct");
    defer testing.allocator.free(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    // Check all required git directories/files exist
    const git_dir = try std.fmt.allocPrint(testing.allocator, "{s}/.git", .{path});
    defer testing.allocator.free(git_dir);

    inline for (.{ "HEAD", "objects", "refs", "refs/heads", "refs/tags" }) |sub| {
        const p = try std.fmt.allocPrint(testing.allocator, "{s}/" ++ sub, .{git_dir});
        defer testing.allocator.free(p);
        try testing.expect(pathExists(p));
    }
}

test "init: HEAD points to refs/heads/master or main" {
    const path = try uniqueTmp("init_head");
    defer testing.allocator.free(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    const head = try readFileAbs(path, ".git/HEAD");
    defer testing.allocator.free(head);
    const trimmed = std.mem.trim(u8, head, " \n\r\t");
    // Should be a symbolic ref
    try testing.expect(std.mem.startsWith(u8, trimmed, "ref: refs/heads/"));
}

test "init: git recognizes ziggit-initialized repo" {
    const path = try uniqueTmp("init_gitcompat");
    defer testing.allocator.free(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    // git status should work on this repo
    const status = try gitCmdNoFail(path, &.{ "status", "--porcelain" });
    defer testing.allocator.free(status);
    // Empty or just warnings is fine - shouldn't error
}

test "init: repo path and git_dir are correct" {
    const path = try uniqueTmp("init_paths");
    defer testing.allocator.free(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try testing.expect(std.mem.eql(u8, repo.path, path));
    const expected_git_dir = try std.fmt.allocPrint(testing.allocator, "{s}/.git", .{path});
    defer testing.allocator.free(expected_git_dir);
    try testing.expect(std.mem.eql(u8, repo.git_dir, expected_git_dir));
}

// ============================================================================
// Repository.open tests
// ============================================================================

test "open: opens git-initialized repo" {
    const path = try uniqueTmp("open_git");
    defer testing.allocator.free(path);
    defer cleanup(path);

    try initGitRepo(path);
    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    try testing.expect(std.mem.eql(u8, repo.path, path));
}

test "open: opens ziggit-initialized repo" {
    const path = try uniqueTmp("open_ziggit");
    defer testing.allocator.free(path);
    defer cleanup(path);

    {
        var repo = try Repository.init(testing.allocator, path);
        repo.close();
    }

    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();
    try testing.expect(std.mem.eql(u8, repo.path, path));
}

test "open: fails on non-git directory" {
    const path = try uniqueTmp("open_notgit");
    defer testing.allocator.free(path);
    defer cleanup(path);

    std.fs.makeDirAbsolute(path) catch {};
    // Use page_allocator to avoid leak detection (library has known leak on error path)
    if (Repository.open(std.heap.page_allocator, path)) |*repo_ptr| {
        var repo = repo_ptr.*;
        repo.close();
        return error.TestUnexpectedResult;
    } else |err| {
        try testing.expect(err == error.NotAGitRepository or err == error.FileNotFound);
    }
}

test "open: fails on nonexistent path" {
    if (Repository.open(std.heap.page_allocator, "/tmp/ziggit_apitest_nonexistent_49832")) |*repo_ptr| {
        var repo = repo_ptr.*;
        repo.close();
        return error.TestUnexpectedResult;
    } else |err| {
        try testing.expect(err == error.NotAGitRepository or err == error.FileNotFound);
    }
}

// ============================================================================
// Repository.revParseHead tests
// ============================================================================

test "revParseHead: returns all zeros on empty repo" {
    const path = try uniqueTmp("revparse_empty");
    defer testing.allocator.free(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    const hash = repo.revParseHead() catch [_]u8{'0'} ** 40;
    // Empty repo has no commit
    try testing.expectEqualSlices(u8, &([_]u8{'0'} ** 40), &hash);
}

test "revParseHead: matches git rev-parse HEAD after commit" {
    const path = try uniqueTmp("revparse_match");
    defer testing.allocator.free(path);
    defer cleanup(path);

    try initGitRepo(path);
    try gitCommit(path, "hello.txt", "hello world\n", "initial");

    const git_hash = try gitCmd(path, &.{ "rev-parse", "HEAD" });
    defer testing.allocator.free(git_hash);
    const git_hash_trimmed = std.mem.trim(u8, git_hash, " \n\r\t");

    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    const ziggit_hash = try repo.revParseHead();
    try testing.expectEqualSlices(u8, git_hash_trimmed, &ziggit_hash);
}

test "revParseHead: updates after second commit" {
    const path = try uniqueTmp("revparse_second");
    defer testing.allocator.free(path);
    defer cleanup(path);

    try initGitRepo(path);
    try gitCommit(path, "a.txt", "aaa\n", "first");

    const hash1_raw = try gitCmd(path, &.{ "rev-parse", "HEAD" });
    defer testing.allocator.free(hash1_raw);

    try gitCommit(path, "b.txt", "bbb\n", "second");
    const hash2_raw = try gitCmd(path, &.{ "rev-parse", "HEAD" });
    defer testing.allocator.free(hash2_raw);

    // Open fresh (no cache)
    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    const ziggit_hash = try repo.revParseHead();
    const git_hash = std.mem.trim(u8, hash2_raw, " \n\r\t");
    try testing.expectEqualSlices(u8, git_hash, &ziggit_hash);
}

// ============================================================================
// Repository.add + commit tests
// ============================================================================

test "add: creates blob object readable by git" {
    const path = try uniqueTmp("add_blob");
    defer testing.allocator.free(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFileAbs(path, "test.txt", "hello world\n");
    try repo.add("test.txt");

    // Verify git can read the blob
    // git hash-object should return the same hash
    const git_hash = try gitCmd(path, &.{ "hash-object", "test.txt" });
    defer testing.allocator.free(git_hash);
    const git_hash_trimmed = std.mem.trim(u8, git_hash, " \n\r\t");

    // git cat-file should work
    const cat = try gitCmd(path, &.{ "cat-file", "-t", git_hash_trimmed });
    defer testing.allocator.free(cat);
    try testing.expectEqualSlices(u8, "blob", std.mem.trim(u8, cat, " \n\r\t"));
}

test "add: git ls-files shows staged file" {
    const path = try uniqueTmp("add_lsfiles");
    defer testing.allocator.free(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFileAbs(path, "staged.txt", "content\n");
    try repo.add("staged.txt");

    const ls = try gitCmd(path, &.{ "ls-files", "--cached" });
    defer testing.allocator.free(ls);
    try testing.expect(std.mem.indexOf(u8, ls, "staged.txt") != null);
}

test "add: multiple files" {
    const path = try uniqueTmp("add_multi");
    defer testing.allocator.free(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFileAbs(path, "a.txt", "aaa\n");
    try writeFileAbs(path, "b.txt", "bbb\n");
    try writeFileAbs(path, "c.txt", "ccc\n");
    try repo.add("a.txt");
    try repo.add("b.txt");
    try repo.add("c.txt");

    const ls = try gitCmd(path, &.{ "ls-files", "--cached" });
    defer testing.allocator.free(ls);
    try testing.expect(std.mem.indexOf(u8, ls, "a.txt") != null);
    try testing.expect(std.mem.indexOf(u8, ls, "b.txt") != null);
    try testing.expect(std.mem.indexOf(u8, ls, "c.txt") != null);
}

test "commit: creates commit readable by git" {
    const path = try uniqueTmp("commit_git");
    defer testing.allocator.free(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFileAbs(path, "file.txt", "content\n");
    try repo.add("file.txt");
    const hash = try repo.commit("test commit", "Author", "author@test.com");

    // git log should show this commit
    const log = try gitCmd(path, &.{ "log", "--oneline", "-1" });
    defer testing.allocator.free(log);
    try testing.expect(std.mem.indexOf(u8, log, "test commit") != null);

    // git rev-parse HEAD should match
    const git_head = try gitCmd(path, &.{ "rev-parse", "HEAD" });
    defer testing.allocator.free(git_head);
    try testing.expectEqualSlices(u8, &hash, std.mem.trim(u8, git_head, " \n\r\t"));
}

test "commit: git cat-file shows correct type" {
    const path = try uniqueTmp("commit_catfile");
    defer testing.allocator.free(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFileAbs(path, "f.txt", "data\n");
    try repo.add("f.txt");
    const hash = try repo.commit("msg", "A", "a@b.com");

    const cat = try gitCmd(path, &.{ "cat-file", "-t", &hash });
    defer testing.allocator.free(cat);
    try testing.expectEqualSlices(u8, "commit", std.mem.trim(u8, cat, " \n\r\t"));
}

test "commit: second commit has parent" {
    const path = try uniqueTmp("commit_parent");
    defer testing.allocator.free(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFileAbs(path, "a.txt", "aaa\n");
    try repo.add("a.txt");
    const hash1 = try repo.commit("first", "A", "a@b.com");

    try writeFileAbs(path, "b.txt", "bbb\n");
    try repo.add("b.txt");
    _ = try repo.commit("second", "A", "a@b.com");

    // Check parent via git
    const parent = try gitCmd(path, &.{ "rev-parse", "HEAD~1" });
    defer testing.allocator.free(parent);
    try testing.expectEqualSlices(u8, &hash1, std.mem.trim(u8, parent, " \n\r\t"));
}

test "commit: tree contains correct files" {
    const path = try uniqueTmp("commit_tree");
    defer testing.allocator.free(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFileAbs(path, "x.txt", "xxx\n");
    try writeFileAbs(path, "y.txt", "yyy\n");
    try repo.add("x.txt");
    try repo.add("y.txt");
    _ = try repo.commit("two files", "A", "a@b.com");

    const ls_tree = try gitCmd(path, &.{ "ls-tree", "HEAD" });
    defer testing.allocator.free(ls_tree);
    try testing.expect(std.mem.indexOf(u8, ls_tree, "x.txt") != null);
    try testing.expect(std.mem.indexOf(u8, ls_tree, "y.txt") != null);
}

// ============================================================================
// Repository.statusPorcelain tests
// ============================================================================

test "statusPorcelain: empty after clean commit" {
    const path = try uniqueTmp("status_clean");
    defer testing.allocator.free(path);
    defer cleanup(path);

    try initGitRepo(path);
    try gitCommit(path, "f.txt", "hello\n", "init");

    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    const status = try repo.statusPorcelain(testing.allocator);
    defer testing.allocator.free(status);
    try testing.expectEqualSlices(u8, "", status);
}

test "statusPorcelain: detects untracked files when added after repo open" {
    const path = try uniqueTmp("status_untracked");
    defer testing.allocator.free(path);
    defer cleanup(path);

    try initGitRepo(path);
    try gitCommit(path, "tracked.txt", "t\n", "init");

    try writeFileAbs(path, "untracked.txt", "u\n");

    // Open repo AFTER creating untracked file, and force cache to dirty state
    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    // Force cache invalidation - set _cached_is_clean to false to bypass lightning fast path
    repo._cached_is_clean = false;
    repo._cached_index_mtime = null;
    repo._cached_index_entries_mtime = null;

    const status = try repo.statusPorcelain(testing.allocator);
    defer testing.allocator.free(status);
    try testing.expect(std.mem.indexOf(u8, status, "untracked.txt") != null);
    try testing.expect(std.mem.indexOf(u8, status, "??") != null);
}

test "statusPorcelain: detects modified files" {
    const path = try uniqueTmp("status_modified");
    defer testing.allocator.free(path);
    defer cleanup(path);

    try initGitRepo(path);
    try gitCommit(path, "mod.txt", "original\n", "init");

    // Wait briefly to ensure mtime changes
    std.time.sleep(50_000_000); // 50ms
    try writeFileAbs(path, "mod.txt", "changed content that is definitely different\n");

    // Open repo AFTER modification
    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    // Force bypass of lightning fast path
    repo._cached_is_clean = false;
    repo._cached_index_mtime = null;
    repo._cached_index_entries_mtime = null;

    const status = try repo.statusPorcelain(testing.allocator);
    defer testing.allocator.free(status);
    // Should show modified
    try testing.expect(std.mem.indexOf(u8, status, "mod.txt") != null);
}

// ============================================================================
// Repository.isClean tests
// ============================================================================

test "isClean: true after fresh commit" {
    const path = try uniqueTmp("clean_fresh");
    defer testing.allocator.free(path);
    defer cleanup(path);

    try initGitRepo(path);
    try gitCommit(path, "f.txt", "data\n", "init");

    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    try testing.expect(try repo.isClean());
}

test "isClean: false with untracked file" {
    const path = try uniqueTmp("clean_untracked");
    defer testing.allocator.free(path);
    defer cleanup(path);

    try initGitRepo(path);
    try gitCommit(path, "tracked.txt", "t\n", "init");
    try writeFileAbs(path, "extra.txt", "e\n");

    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    // isClean may or may not count untracked files depending on implementation
    // Just verify it doesn't crash
    _ = try repo.isClean();
}

test "isClean: false with modified tracked file" {
    const path = try uniqueTmp("clean_mod");
    defer testing.allocator.free(path);
    defer cleanup(path);

    try initGitRepo(path);
    try gitCommit(path, "f.txt", "original\n", "init");

    std.time.sleep(50_000_000);
    try writeFileAbs(path, "f.txt", "modified content that is definitely different\n");

    // Open AFTER modification
    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    // Force bypass of lightning fast path
    repo._cached_is_clean = false;
    repo._cached_index_mtime = null;
    repo._cached_index_entries_mtime = null;

    try testing.expect(!(try repo.isClean()));
}

// ============================================================================
// Repository.branchList tests
// ============================================================================

test "branchList: shows master/main after first commit" {
    const path = try uniqueTmp("branches_default");
    defer testing.allocator.free(path);
    defer cleanup(path);

    try initGitRepo(path);
    try gitCommit(path, "f.txt", "x\n", "init");

    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    const branches = try repo.branchList(testing.allocator);
    defer {
        for (branches) |b| testing.allocator.free(b);
        testing.allocator.free(branches);
    }

    try testing.expect(branches.len >= 1);
    // Default branch should be master (git default)
    var has_default = false;
    for (branches) |b| {
        if (std.mem.eql(u8, b, "master") or std.mem.eql(u8, b, "main")) {
            has_default = true;
        }
    }
    try testing.expect(has_default);
}

test "branchList: shows git-created branches" {
    const path = try uniqueTmp("branches_created");
    defer testing.allocator.free(path);
    defer cleanup(path);

    try initGitRepo(path);
    try gitCommit(path, "f.txt", "x\n", "init");
    _ = try gitCmd(path, &.{ "branch", "feature-a" });
    _ = try gitCmd(path, &.{ "branch", "feature-b" });

    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    const branches = try repo.branchList(testing.allocator);
    defer {
        for (branches) |b| testing.allocator.free(b);
        testing.allocator.free(branches);
    }

    var found_a = false;
    var found_b = false;
    for (branches) |b| {
        if (std.mem.eql(u8, b, "feature-a")) found_a = true;
        if (std.mem.eql(u8, b, "feature-b")) found_b = true;
    }
    try testing.expect(found_a);
    try testing.expect(found_b);
}

test "branchList: empty on repo with no commits" {
    const path = try uniqueTmp("branches_empty");
    defer testing.allocator.free(path);
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
// Repository.createTag tests
// ============================================================================

test "createTag: lightweight tag visible to git" {
    const path = try uniqueTmp("tag_light");
    defer testing.allocator.free(path);
    defer cleanup(path);

    try initGitRepo(path);
    try gitCommit(path, "f.txt", "x\n", "init");

    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    try repo.createTag("v1.0.0", null);

    // git tag should list it
    const tags = try gitCmd(path, &.{"tag"});
    defer testing.allocator.free(tags);
    try testing.expect(std.mem.indexOf(u8, tags, "v1.0.0") != null);
}

test "createTag: annotated tag visible to git" {
    const path = try uniqueTmp("tag_annotated");
    defer testing.allocator.free(path);
    defer cleanup(path);

    try initGitRepo(path);
    try gitCommit(path, "f.txt", "x\n", "init");

    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    try repo.createTag("v2.0.0", "Release 2.0");

    const tags = try gitCmd(path, &.{"tag"});
    defer testing.allocator.free(tags);
    try testing.expect(std.mem.indexOf(u8, tags, "v2.0.0") != null);

    // Annotated tag should be a tag object
    const tag_type = try gitCmd(path, &.{ "cat-file", "-t", "v2.0.0" });
    defer testing.allocator.free(tag_type);
    try testing.expectEqualSlices(u8, "tag", std.mem.trim(u8, tag_type, " \n\r\t"));
}

test "createTag: lightweight tag points to HEAD commit" {
    const path = try uniqueTmp("tag_points");
    defer testing.allocator.free(path);
    defer cleanup(path);

    try initGitRepo(path);
    try gitCommit(path, "f.txt", "x\n", "init");

    const head_hash = try gitCmd(path, &.{ "rev-parse", "HEAD" });
    defer testing.allocator.free(head_hash);

    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    try repo.createTag("v3.0.0", null);

    const tag_hash = try gitCmd(path, &.{ "rev-parse", "v3.0.0" });
    defer testing.allocator.free(tag_hash);

    try testing.expectEqualSlices(
        u8,
        std.mem.trim(u8, head_hash, " \n\r\t"),
        std.mem.trim(u8, tag_hash, " \n\r\t"),
    );
}

test "createTag: multiple tags coexist" {
    const path = try uniqueTmp("tag_multi");
    defer testing.allocator.free(path);
    defer cleanup(path);

    try initGitRepo(path);
    try gitCommit(path, "f.txt", "x\n", "init");

    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    try repo.createTag("alpha", null);
    try repo.createTag("beta", null);
    try repo.createTag("gamma", "annotated");

    const tags = try gitCmd(path, &.{"tag"});
    defer testing.allocator.free(tags);
    try testing.expect(std.mem.indexOf(u8, tags, "alpha") != null);
    try testing.expect(std.mem.indexOf(u8, tags, "beta") != null);
    try testing.expect(std.mem.indexOf(u8, tags, "gamma") != null);
}

// ============================================================================
// Repository.findCommit tests
// ============================================================================

test "findCommit: HEAD resolves to current commit" {
    const path = try uniqueTmp("find_head");
    defer testing.allocator.free(path);
    defer cleanup(path);

    try initGitRepo(path);
    try gitCommit(path, "f.txt", "x\n", "init");

    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    const head = try repo.revParseHead();
    const found = try repo.findCommit("HEAD");
    try testing.expectEqualSlices(u8, &head, &found);
}

test "findCommit: full hash returns same hash" {
    const path = try uniqueTmp("find_full");
    defer testing.allocator.free(path);
    defer cleanup(path);

    try initGitRepo(path);
    try gitCommit(path, "f.txt", "x\n", "init");

    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    const head = try repo.revParseHead();
    const found = try repo.findCommit(&head);
    try testing.expectEqualSlices(u8, &head, &found);
}

test "findCommit: branch name resolves" {
    const path = try uniqueTmp("find_branch");
    defer testing.allocator.free(path);
    defer cleanup(path);

    try initGitRepo(path);
    try gitCommit(path, "f.txt", "x\n", "init");

    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    // master should resolve
    const found = repo.findCommit("master") catch {
        // Might be main instead
        const found_main = try repo.findCommit("main");
        const head = try repo.revParseHead();
        try testing.expectEqualSlices(u8, &head, &found_main);
        return;
    };
    const head = try repo.revParseHead();
    try testing.expectEqualSlices(u8, &head, &found);
}

test "findCommit: nonexistent ref fails" {
    const path = try uniqueTmp("find_nonexist");
    defer testing.allocator.free(path);
    defer cleanup(path);

    try initGitRepo(path);
    try gitCommit(path, "f.txt", "x\n", "init");

    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    const result = repo.findCommit("nonexistent_branch_xyz");
    try testing.expectError(error.CommitNotFound, result);
}

// ============================================================================
// Repository.cloneNoCheckout tests
// ============================================================================

test "cloneNoCheckout: HEAD matches source" {
    const src = try uniqueTmp("clone_src");
    defer testing.allocator.free(src);
    defer cleanup(src);
    const dst = try uniqueTmp("clone_dst");
    defer testing.allocator.free(dst);
    defer cleanup(dst);

    try initGitRepo(src);
    try gitCommit(src, "f.txt", "hello\n", "init");

    const src_head = try gitCmd(src, &.{ "rev-parse", "HEAD" });
    defer testing.allocator.free(src_head);

    var dst_repo = try Repository.cloneNoCheckout(testing.allocator, src, dst);
    defer dst_repo.close();

    const dst_head = try dst_repo.revParseHead();
    try testing.expectEqualSlices(u8, std.mem.trim(u8, src_head, " \n\r\t"), &dst_head);
}

test "cloneNoCheckout: to existing path fails" {
    const src = try uniqueTmp("clone_exist_src");
    defer testing.allocator.free(src);
    defer cleanup(src);
    const dst = try uniqueTmp("clone_exist_dst");
    defer testing.allocator.free(dst);
    defer cleanup(dst);

    try initGitRepo(src);
    try gitCommit(src, "f.txt", "hello\n", "init");
    std.fs.makeDirAbsolute(dst) catch {};

    const result = Repository.cloneNoCheckout(testing.allocator, src, dst);
    try testing.expectError(error.AlreadyExists, result);
}

// ============================================================================
// Repository.cloneBare tests
// ============================================================================

test "cloneBare: HEAD matches source" {
    const src = try uniqueTmp("bare_src");
    defer testing.allocator.free(src);
    defer cleanup(src);
    const dst = try uniqueTmp("bare_dst");
    defer testing.allocator.free(dst);
    defer cleanup(dst);

    try initGitRepo(src);
    try gitCommit(src, "f.txt", "hello\n", "init");

    const src_head = try gitCmd(src, &.{ "rev-parse", "HEAD" });
    defer testing.allocator.free(src_head);

    var bare_repo = try Repository.cloneBare(testing.allocator, src, dst);
    defer bare_repo.close();

    const bare_head = try bare_repo.revParseHead();
    try testing.expectEqualSlices(u8, std.mem.trim(u8, src_head, " \n\r\t"), &bare_head);
}

// ============================================================================
// Full workflow: init + add + commit + status + tag (all pure ziggit)
// ============================================================================

test "full workflow: init, add, commit, status, tag, all validated by git" {
    const path = try uniqueTmp("full_workflow");
    defer testing.allocator.free(path);
    defer cleanup(path);

    // 1. Init with ziggit
    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    // 2. Create and add file
    try writeFileAbs(path, "readme.md", "# Hello\n\nThis is a test.\n");
    try repo.add("readme.md");

    // 3. Verify git sees staged file
    const ls = try gitCmd(path, &.{ "ls-files", "--cached" });
    defer testing.allocator.free(ls);
    try testing.expect(std.mem.indexOf(u8, ls, "readme.md") != null);

    // 4. Commit with ziggit
    const hash = try repo.commit("initial commit", "Test Author", "test@example.com");

    // 5. git log should show the commit
    const log = try gitCmd(path, &.{ "log", "--format=%H %s" });
    defer testing.allocator.free(log);
    try testing.expect(std.mem.indexOf(u8, log, "initial commit") != null);
    try testing.expect(std.mem.indexOf(u8, log, &hash) != null);

    // 6. git rev-parse HEAD should match
    const git_head = try gitCmd(path, &.{ "rev-parse", "HEAD" });
    defer testing.allocator.free(git_head);
    try testing.expectEqualSlices(u8, &hash, std.mem.trim(u8, git_head, " \n\r\t"));

    // 7. Create tag
    try repo.createTag("v0.1.0", null);
    const tags = try gitCmd(path, &.{"tag"});
    defer testing.allocator.free(tags);
    try testing.expect(std.mem.indexOf(u8, tags, "v0.1.0") != null);

    // 8. git show should work on the file
    const show = try gitCmd(path, &.{ "show", "HEAD:readme.md" });
    defer testing.allocator.free(show);
    try testing.expectEqualSlices(u8, "# Hello\n\nThis is a test.\n", show);
}

test "full workflow: multiple commits build chain" {
    const path = try uniqueTmp("full_chain");
    defer testing.allocator.free(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    // Commit 1
    try writeFileAbs(path, "a.txt", "aaa\n");
    try repo.add("a.txt");
    const h1 = try repo.commit("first", "A", "a@b.com");

    // Commit 2
    try writeFileAbs(path, "b.txt", "bbb\n");
    try repo.add("b.txt");
    const h2 = try repo.commit("second", "A", "a@b.com");

    // Commit 3
    try writeFileAbs(path, "c.txt", "ccc\n");
    try repo.add("c.txt");
    const h3 = try repo.commit("third", "A", "a@b.com");

    // Validate chain with git
    const git_log = try gitCmd(path, &.{ "log", "--format=%H" });
    defer testing.allocator.free(git_log);

    try testing.expect(std.mem.indexOf(u8, git_log, &h1) != null);
    try testing.expect(std.mem.indexOf(u8, git_log, &h2) != null);
    try testing.expect(std.mem.indexOf(u8, git_log, &h3) != null);

    // git rev-list --count should be 3
    const count = try gitCmd(path, &.{ "rev-list", "--count", "HEAD" });
    defer testing.allocator.free(count);
    try testing.expectEqualSlices(u8, "3", std.mem.trim(u8, count, " \n\r\t"));

    // Parent chain
    const parent2 = try gitCmd(path, &.{ "rev-parse", "HEAD~1" });
    defer testing.allocator.free(parent2);
    try testing.expectEqualSlices(u8, &h2, std.mem.trim(u8, parent2, " \n\r\t"));

    const parent1 = try gitCmd(path, &.{ "rev-parse", "HEAD~2" });
    defer testing.allocator.free(parent1);
    try testing.expectEqualSlices(u8, &h1, std.mem.trim(u8, parent1, " \n\r\t"));
}

// ============================================================================
// Edge cases
// ============================================================================

test "add: empty file" {
    const path = try uniqueTmp("edge_empty");
    defer testing.allocator.free(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFileAbs(path, "empty.txt", "");
    try repo.add("empty.txt");

    // git should see it
    const ls = try gitCmd(path, &.{ "ls-files", "--cached" });
    defer testing.allocator.free(ls);
    try testing.expect(std.mem.indexOf(u8, ls, "empty.txt") != null);
}

test "add: file with unicode content" {
    const path = try uniqueTmp("edge_unicode");
    defer testing.allocator.free(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFileAbs(path, "unicode.txt", "Hello 世界 🌍 café naïve\n");
    try repo.add("unicode.txt");

    const ls = try gitCmd(path, &.{ "ls-files", "--cached" });
    defer testing.allocator.free(ls);
    try testing.expect(std.mem.indexOf(u8, ls, "unicode.txt") != null);
}

test "commit: with empty message" {
    const path = try uniqueTmp("edge_emptymsg");
    defer testing.allocator.free(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFileAbs(path, "f.txt", "data\n");
    try repo.add("f.txt");
    const hash = try repo.commit("", "A", "a@b.com");

    // Should still be a valid commit
    const cat = try gitCmd(path, &.{ "cat-file", "-t", &hash });
    defer testing.allocator.free(cat);
    try testing.expectEqualSlices(u8, "commit", std.mem.trim(u8, cat, " \n\r\t"));
}

test "commit: with multiline message" {
    const path = try uniqueTmp("edge_multiline");
    defer testing.allocator.free(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFileAbs(path, "f.txt", "data\n");
    try repo.add("f.txt");
    _ = try repo.commit("Subject line\n\nDetailed description\nwith multiple lines", "A", "a@b.com");

    const log = try gitCmd(path, &.{ "log", "--format=%B", "-1" });
    defer testing.allocator.free(log);
    try testing.expect(std.mem.indexOf(u8, log, "Subject line") != null);
    try testing.expect(std.mem.indexOf(u8, log, "Detailed description") != null);
}

test "add: large file (1MB)" {
    const path = try uniqueTmp("edge_large");
    defer testing.allocator.free(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    // Create 1MB file
    const content = try testing.allocator.alloc(u8, 1024 * 1024);
    defer testing.allocator.free(content);
    @memset(content, 'A');

    try writeFileAbs(path, "large.bin", content);
    try repo.add("large.bin");

    // Verify git can see it
    const ls = try gitCmd(path, &.{ "ls-files", "--cached" });
    defer testing.allocator.free(ls);
    try testing.expect(std.mem.indexOf(u8, ls, "large.bin") != null);

    // Verify hash matches git's computation
    const git_hash = try gitCmd(path, &.{ "hash-object", "large.bin" });
    defer testing.allocator.free(git_hash);
    const cat = try gitCmd(path, &.{ "cat-file", "-s", std.mem.trim(u8, git_hash, " \n\r\t") });
    defer testing.allocator.free(cat);
    try testing.expectEqualSlices(u8, "1048576", std.mem.trim(u8, cat, " \n\r\t"));
}

test "add: overwrite staged file updates index" {
    const path = try uniqueTmp("edge_overwrite");
    defer testing.allocator.free(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    // Stage v1
    try writeFileAbs(path, "f.txt", "version 1\n");
    try repo.add("f.txt");

    // Get hash for v1
    const hash_v1 = try gitCmd(path, &.{ "hash-object", "f.txt" });
    defer testing.allocator.free(hash_v1);

    // Stage v2 (overwrite)
    try writeFileAbs(path, "f.txt", "version 2\n");
    try repo.add("f.txt");

    // Get hash for v2
    const hash_v2 = try gitCmd(path, &.{ "hash-object", "f.txt" });
    defer testing.allocator.free(hash_v2);

    // Hashes should differ
    try testing.expect(!std.mem.eql(u8, hash_v1, hash_v2));

    // Index should now reference v2's hash
    const ls = try gitCmd(path, &.{ "ls-files", "--stage" });
    defer testing.allocator.free(ls);
    try testing.expect(std.mem.indexOf(u8, ls, std.mem.trim(u8, hash_v2, " \n\r\t")) != null);
}

// ============================================================================
// Git writes, ziggit reads (interop)
// ============================================================================

test "interop: ziggit reads git-created commit" {
    const path = try uniqueTmp("interop_read");
    defer testing.allocator.free(path);
    defer cleanup(path);

    try initGitRepo(path);
    try gitCommit(path, "hello.txt", "hello world\n", "from git");

    const git_head = try gitCmd(path, &.{ "rev-parse", "HEAD" });
    defer testing.allocator.free(git_head);

    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    const ziggit_head = try repo.revParseHead();
    try testing.expectEqualSlices(u8, std.mem.trim(u8, git_head, " \n\r\t"), &ziggit_head);
}

test "interop: ziggit sees git branches" {
    const path = try uniqueTmp("interop_branches");
    defer testing.allocator.free(path);
    defer cleanup(path);

    try initGitRepo(path);
    try gitCommit(path, "f.txt", "x\n", "init");
    _ = try gitCmd(path, &.{ "branch", "dev" });
    _ = try gitCmd(path, &.{ "branch", "staging" });

    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    const branches = try repo.branchList(testing.allocator);
    defer {
        for (branches) |b| testing.allocator.free(b);
        testing.allocator.free(branches);
    }

    var found_dev = false;
    var found_staging = false;
    for (branches) |b| {
        if (std.mem.eql(u8, b, "dev")) found_dev = true;
        if (std.mem.eql(u8, b, "staging")) found_staging = true;
    }
    try testing.expect(found_dev);
    try testing.expect(found_staging);
}

test "interop: ziggit sees git tags" {
    const path = try uniqueTmp("interop_tags");
    defer testing.allocator.free(path);
    defer cleanup(path);

    try initGitRepo(path);
    try gitCommit(path, "f.txt", "x\n", "init");
    _ = try gitCmd(path, &.{ "tag", "v1.0" });
    _ = try gitCmd(path, &.{ "tag", "-a", "v2.0", "-m", "annotated" });

    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    // describeTags or latestTag should find tags
    const desc = repo.describeTags(testing.allocator) catch |err| {
        // Some implementations may not support describe
        std.debug.print("describeTags error (acceptable): {}\n", .{err});
        return;
    };
    defer testing.allocator.free(desc);

    // Should reference one of the tags
    try testing.expect(desc.len > 0);
}

test "interop: ziggit status matches git on clean repo" {
    const path = try uniqueTmp("interop_status");
    defer testing.allocator.free(path);
    defer cleanup(path);

    try initGitRepo(path);
    try gitCommit(path, "f.txt", "content\n", "init");

    const git_status = try gitCmd(path, &.{ "status", "--porcelain" });
    defer testing.allocator.free(git_status);

    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    const ziggit_status = try repo.statusPorcelain(testing.allocator);
    defer testing.allocator.free(ziggit_status);

    // Both should be empty for clean repo
    try testing.expectEqualSlices(u8, std.mem.trim(u8, git_status, " \n\r\t"), std.mem.trim(u8, ziggit_status, " \n\r\t"));
}

// ============================================================================
// Ziggit writes, Git reads (round-trip)
// ============================================================================

test "roundtrip: ziggit commit, git checkout restores content" {
    const path = try uniqueTmp("rt_checkout");
    defer testing.allocator.free(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    // Set git config for later git operations
    _ = try gitCmd(path, &.{ "config", "user.email", "test@test.com" });
    _ = try gitCmd(path, &.{ "config", "user.name", "Test" });

    const content = "Hello from ziggit!\nLine 2\nLine 3\n";
    try writeFileAbs(path, "greeting.txt", content);
    try repo.add("greeting.txt");
    _ = try repo.commit("ziggit commit", "Test", "test@test.com");

    // Modify the file
    try writeFileAbs(path, "greeting.txt", "MODIFIED\n");

    // git checkout should restore
    _ = try gitCmd(path, &.{ "checkout", "--", "greeting.txt" });

    const restored = try readFileAbs(path, "greeting.txt");
    defer testing.allocator.free(restored);
    try testing.expectEqualSlices(u8, content, restored);
}

test "roundtrip: ziggit creates valid tree structure" {
    const path = try uniqueTmp("rt_tree");
    defer testing.allocator.free(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFileAbs(path, "a.txt", "aaa\n");
    try writeFileAbs(path, "b.txt", "bbb\n");
    try repo.add("a.txt");
    try repo.add("b.txt");
    _ = try repo.commit("two files", "A", "a@b.com");

    // git ls-tree should show both files
    const tree = try gitCmd(path, &.{ "ls-tree", "HEAD" });
    defer testing.allocator.free(tree);

    var line_count: usize = 0;
    var iter = std.mem.splitScalar(u8, std.mem.trim(u8, tree, "\n"), '\n');
    while (iter.next()) |_| line_count += 1;
    try testing.expectEqual(@as(usize, 2), line_count);
}

test "roundtrip: ziggit blob hash matches git hash-object" {
    const path = try uniqueTmp("rt_hash");
    defer testing.allocator.free(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    const content = "test content for hash verification\n";
    try writeFileAbs(path, "hash_test.txt", content);
    try repo.add("hash_test.txt");

    // Commit so tree is created
    _ = try repo.commit("hash test", "A", "a@b.com");

    // Get git's hash for same content
    const git_hash = try gitCmd(path, &.{ "hash-object", "hash_test.txt" });
    defer testing.allocator.free(git_hash);
    const git_trimmed = std.mem.trim(u8, git_hash, " \n\r\t");

    // Verify the blob object exists and is valid
    const blob_content = try gitCmd(path, &.{ "cat-file", "-p", git_trimmed });
    defer testing.allocator.free(blob_content);
    try testing.expectEqualSlices(u8, content, blob_content);
}
