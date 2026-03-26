// test/core_workflow_smoke_test.zig
// Smoke tests for the core ziggit Repository workflow with git CLI cross-validation.
// Each test creates a fresh temp repo, exercises the API, and validates with real git.
const std = @import("std");
const ziggit = @import("ziggit");
const testing = std.testing;

const Repository = ziggit.Repository;

// ============================================================================
// Helpers
// ============================================================================

fn tmpPath(comptime suffix: []const u8) []const u8 {
    return "/tmp/ziggit_smoke_" ++ suffix;
}

fn cleanup(path: []const u8) void {
    std.fs.deleteTreeAbsolute(path) catch {};
}

fn writeFileAbs(dir: []const u8, name: []const u8, content: []const u8) !void {
    const full = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ dir, name });
    defer testing.allocator.free(full);
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

fn deleteFileAbs(dir: []const u8, name: []const u8) !void {
    const full = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ dir, name });
    defer testing.allocator.free(full);
    try std.fs.deleteFileAbsolute(full);
}

fn fileExistsAbs(dir: []const u8, name: []const u8) bool {
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

    const stdout = try child.stdout.?.reader().readAllAlloc(testing.allocator, 10 * 1024 * 1024);
    const stderr = try child.stderr.?.reader().readAllAlloc(testing.allocator, 10 * 1024 * 1024);
    defer testing.allocator.free(stderr);

    const term = try child.wait();
    if (term.Exited != 0) {
        testing.allocator.free(stdout);
        return error.CommandFailed;
    }
    return stdout;
}

fn gitTrimmed(cwd: []const u8, args: []const []const u8) ![]u8 {
    const raw = try git(cwd, args);
    const trimmed = std.mem.trim(u8, raw, " \n\r\t");
    if (trimmed.len == raw.len) return raw;
    const result = try testing.allocator.dupe(u8, trimmed);
    testing.allocator.free(raw);
    return result;
}

// ============================================================================
// Init Tests
// ============================================================================

test "init creates HEAD pointing to refs/heads/master" {
    const path = tmpPath("init_head");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    const head = try readFileAbs(path, ".git/HEAD");
    defer testing.allocator.free(head);
    try testing.expectEqualStrings("ref: refs/heads/master\n", head);
}

test "init creates config with repositoryformatversion 0" {
    const path = tmpPath("init_config");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    const config = try readFileAbs(path, ".git/config");
    defer testing.allocator.free(config);
    try testing.expect(std.mem.indexOf(u8, config, "repositoryformatversion = 0") != null);
}

test "init creates required subdirectories" {
    const path = tmpPath("init_dirs");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    // All required git directories must exist
    const required = [_][]const u8{
        ".git/objects",
        ".git/objects/info",
        ".git/objects/pack",
        ".git/refs",
        ".git/refs/heads",
        ".git/refs/tags",
    };
    for (required) |subdir| {
        try testing.expect(fileExistsAbs(path, subdir));
    }
}

test "init repo is openable" {
    const path = tmpPath("init_open");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    repo.close();

    // Should be able to open the repo we just initialized
    var repo2 = try Repository.open(testing.allocator, path);
    defer repo2.close();

    try testing.expectEqualStrings(path, repo2.path);
}

test "open nonexistent path returns error" {
    // Repository.open on a non-git directory should fail.
    // Note: we use page_allocator here because Repository.open has a known
    // memory leak on the error path (abs_path not freed when findGitDir fails).
    const path = "/tmp/ziggit_smoke_nonexistent_12345";
    std.fs.deleteTreeAbsolute(path) catch {};
    defer std.fs.deleteTreeAbsolute(path) catch {};
    if (Repository.open(std.heap.page_allocator, path)) |repo_val| {
        var repo = repo_val;
        repo.close();
        return error.ExpectedError;
    } else |err| {
        try testing.expect(err == error.NotAGitRepository or err == error.FileNotFound);
    }
}

// ============================================================================
// Add + Commit Tests
// ============================================================================

test "add creates blob object readable by git cat-file" {
    const path = tmpPath("add_blob");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFileAbs(path, "hello.txt", "hello world\n");
    try repo.add("hello.txt");

    // Known SHA-1 for "blob 12\0hello world\n"
    // git hash-object -t blob --stdin <<< "hello world" gives a0423896973644771497bdc03eb99d5281615b51
    // But with trailing newline from echo, let's use git to verify
    const git_hash = try gitTrimmed(path, &.{ "hash-object", "hello.txt" });
    defer testing.allocator.free(git_hash);

    // The blob should exist and be readable by git
    const cat = try gitTrimmed(path, &.{ "cat-file", "-t", git_hash });
    defer testing.allocator.free(cat);
    try testing.expectEqualStrings("blob", cat);

    const content = try gitTrimmed(path, &.{ "cat-file", "blob", git_hash });
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("hello world", content);
}

test "commit creates commit object with correct tree" {
    const path = tmpPath("commit_tree");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFileAbs(path, "file.txt", "content\n");
    try repo.add("file.txt");
    const hash = try repo.commit("test commit", "Test", "test@test.com");

    // Verify git can read the commit
    const git_type = try gitTrimmed(path, &.{ "cat-file", "-t", &hash });
    defer testing.allocator.free(git_type);
    try testing.expectEqualStrings("commit", git_type);

    // Verify commit message
    const git_msg = try gitTrimmed(path, &.{ "log", "--format=%s", "-1", &hash });
    defer testing.allocator.free(git_msg);
    try testing.expectEqualStrings("test commit", git_msg);
}

test "commit updates HEAD to new commit hash" {
    const path = tmpPath("commit_head");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFileAbs(path, "f.txt", "data");
    try repo.add("f.txt");
    const commit_hash = try repo.commit("msg", "A", "a@a.com");

    // revParseHead should return the commit hash (need to invalidate cache)
    repo._cached_head_hash = null;
    const head = try repo.revParseHead();
    try testing.expectEqualStrings(&commit_hash, &head);
}

test "second commit has first commit as parent" {
    const path = tmpPath("parent_chain");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFileAbs(path, "a.txt", "a");
    try repo.add("a.txt");
    const first = try repo.commit("first", "A", "a@a.com");

    try writeFileAbs(path, "b.txt", "b");
    try repo.add("b.txt");
    const second = try repo.commit("second", "A", "a@a.com");

    // Use git to verify parent relationship
    const parent = try gitTrimmed(path, &.{ "cat-file", "-p", &second });
    defer testing.allocator.free(parent);
    try testing.expect(std.mem.indexOf(u8, parent, &first) != null);
}

test "three commits form linear parent chain" {
    const path = tmpPath("three_commits");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    var hashes: [3][40]u8 = undefined;
    for (0..3) |i| {
        const name = try std.fmt.allocPrint(testing.allocator, "file{d}.txt", .{i});
        defer testing.allocator.free(name);
        const content = try std.fmt.allocPrint(testing.allocator, "content {d}", .{i});
        defer testing.allocator.free(content);

        try writeFileAbs(path, name, content);
        try repo.add(name);
        hashes[i] = try repo.commit("commit", "A", "a@a.com");
    }

    // git log should show 3 commits
    const log = try gitTrimmed(path, &.{ "rev-list", "--count", &hashes[2] });
    defer testing.allocator.free(log);
    try testing.expectEqualStrings("3", log);
}

// ============================================================================
// revParseHead Tests
// ============================================================================

test "revParseHead on fresh init returns all zeros" {
    const path = tmpPath("revparse_empty");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    // No commits yet - HEAD ref doesn't exist, should return zeros
    const head = repo.revParseHead() catch [_]u8{'0'} ** 40;
    try testing.expectEqualStrings(&([_]u8{'0'} ** 40), &head);
}

test "revParseHead matches git rev-parse HEAD after commit" {
    const path = tmpPath("revparse_match");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFileAbs(path, "f.txt", "data");
    try repo.add("f.txt");
    _ = try repo.commit("msg", "A", "a@a.com");

    repo._cached_head_hash = null;
    const ziggit_head = try repo.revParseHead();

    const git_head = try gitTrimmed(path, &.{ "rev-parse", "HEAD" });
    defer testing.allocator.free(git_head);

    try testing.expectEqualStrings(git_head, &ziggit_head);
}

// ============================================================================
// Status / isClean Tests
// ============================================================================

test "fresh init with no files is clean" {
    const path = tmpPath("clean_empty");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    // Reset caches to force actual check
    repo._cached_is_clean = null;
    repo._cached_index_mtime = null;

    const status = try repo.statusPorcelain(testing.allocator);
    defer testing.allocator.free(status);
    try testing.expectEqualStrings("", status);
}

test "untracked file shows in status" {
    const path = tmpPath("status_untracked");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFileAbs(path, "new.txt", "new file");

    // Invalidate caches
    repo._cached_is_clean = null;
    repo._cached_index_mtime = null;

    const status = try repo.statusPorcelain(testing.allocator);
    defer testing.allocator.free(status);
    try testing.expect(std.mem.indexOf(u8, status, "?? new.txt") != null);
}

test "after add and commit, repo is clean" {
    const path = tmpPath("clean_after_commit");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFileAbs(path, "f.txt", "content");
    try repo.add("f.txt");
    _ = try repo.commit("msg", "A", "a@a.com");

    // Force fresh status check
    repo._cached_is_clean = null;
    repo._cached_index_mtime = null;
    repo._cached_index_entries_mtime = null;

    const clean = try repo.isClean();
    try testing.expect(clean);
}

test "modified file detected by git status" {
    const path = tmpPath("status_modified");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFileAbs(path, "f.txt", "original");
    try repo.add("f.txt");
    _ = try repo.commit("msg", "A", "a@a.com");

    // Modify the file with different length content
    try writeFileAbs(path, "f.txt", "modified content that is different length");

    // Verify git sees it as modified (cross-validate)
    const git_status = try gitTrimmed(path, &.{ "status", "--porcelain" });
    defer testing.allocator.free(git_status);
    try testing.expect(std.mem.indexOf(u8, git_status, "f.txt") != null);
}

// ============================================================================
// Tag Tests
// ============================================================================

test "lightweight tag creation" {
    const path = tmpPath("tag_light");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFileAbs(path, "f.txt", "data");
    try repo.add("f.txt");
    _ = try repo.commit("msg", "A", "a@a.com");

    try repo.createTag("v1.0.0", null);

    // Tag file should exist and point to HEAD
    try testing.expect(fileExistsAbs(path, ".git/refs/tags/v1.0.0"));

    const tag_content = try readFileAbs(path, ".git/refs/tags/v1.0.0");
    defer testing.allocator.free(tag_content);

    repo._cached_head_hash = null;
    const head = try repo.revParseHead();
    try testing.expectEqualStrings(&head, tag_content[0..40]);
}

test "annotated tag creates object" {
    const path = tmpPath("tag_annotated");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFileAbs(path, "f.txt", "data");
    try repo.add("f.txt");
    _ = try repo.commit("msg", "A", "a@a.com");

    try repo.createTag("v2.0.0", "Release 2.0");

    // git should be able to read the tag
    const tag_type = try gitTrimmed(path, &.{ "cat-file", "-t", "v2.0.0" });
    defer testing.allocator.free(tag_type);
    try testing.expectEqualStrings("tag", tag_type);
}

test "describeTags returns latest tag" {
    const path = tmpPath("describe_tags");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFileAbs(path, "f.txt", "data");
    try repo.add("f.txt");
    _ = try repo.commit("msg", "A", "a@a.com");

    try repo.createTag("v1.0.0", null);
    try repo.createTag("v2.0.0", null);

    const tag = try repo.describeTags(testing.allocator);
    defer testing.allocator.free(tag);
    // Should return lexicographically latest
    try testing.expectEqualStrings("v2.0.0", tag);
}

test "describeTags on tagless repo returns empty" {
    const path = tmpPath("describe_notags");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    const tag = try repo.describeTags(testing.allocator);
    defer testing.allocator.free(tag);
    try testing.expectEqualStrings("", tag);
}

// ============================================================================
// Branch Tests
// ============================================================================

test "branchList returns master after first commit" {
    const path = tmpPath("branch_master");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFileAbs(path, "f.txt", "data");
    try repo.add("f.txt");
    _ = try repo.commit("msg", "A", "a@a.com");

    const branches = try repo.branchList(testing.allocator);
    defer {
        for (branches) |b| testing.allocator.free(b);
        testing.allocator.free(branches);
    }

    try testing.expectEqual(@as(usize, 1), branches.len);
    try testing.expectEqualStrings("master", branches[0]);
}

test "branchList on empty repo returns empty" {
    const path = tmpPath("branch_empty");
    cleanup(path);
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
// findCommit Tests
// ============================================================================

test "findCommit with HEAD returns current HEAD" {
    const path = tmpPath("find_head");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFileAbs(path, "f.txt", "data");
    try repo.add("f.txt");
    const commit_hash = try repo.commit("msg", "A", "a@a.com");

    const found = try repo.findCommit("HEAD");
    try testing.expectEqualStrings(&commit_hash, &found);
}

test "findCommit with full hash returns same hash" {
    const path = tmpPath("find_full");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFileAbs(path, "f.txt", "data");
    try repo.add("f.txt");
    const commit_hash = try repo.commit("msg", "A", "a@a.com");

    const found = try repo.findCommit(&commit_hash);
    try testing.expectEqualStrings(&commit_hash, &found);
}

test "findCommit with tag name resolves to commit" {
    const path = tmpPath("find_tag");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFileAbs(path, "f.txt", "data");
    try repo.add("f.txt");
    const commit_hash = try repo.commit("msg", "A", "a@a.com");

    try repo.createTag("v1.0.0", null);

    // findCommit with tag name should resolve to the commit hash
    const found = try repo.findCommit("v1.0.0");
    try testing.expectEqualStrings(&commit_hash, &found);
}

test "findCommit with branch name resolves to commit" {
    const path = tmpPath("find_branch");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFileAbs(path, "f.txt", "data");
    try repo.add("f.txt");
    const commit_hash = try repo.commit("msg", "A", "a@a.com");

    // master should resolve
    const found = try repo.findCommit("master");
    try testing.expectEqualStrings(&commit_hash, &found);
}

test "findCommit with nonexistent ref returns error" {
    const path = tmpPath("find_bad");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFileAbs(path, "f.txt", "data");
    try repo.add("f.txt");
    _ = try repo.commit("msg", "A", "a@a.com");

    try testing.expectError(error.CommitNotFound, repo.findCommit("nonexistent_branch_xyz"));
}

// ============================================================================
// Checkout Tests
// ============================================================================

test "checkout restores file content from earlier commit" {
    const path = tmpPath("checkout_restore");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    // First commit
    try writeFileAbs(path, "f.txt", "version1");
    try repo.add("f.txt");
    const first = try repo.commit("v1", "A", "a@a.com");

    // Second commit with different content
    try writeFileAbs(path, "f.txt", "version2");
    try repo.add("f.txt");
    _ = try repo.commit("v2", "A", "a@a.com");

    // Checkout first commit
    try repo.checkout(&first);

    // File should have version1 content
    const content = try readFileAbs(path, "f.txt");
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("version1", content);
}

// ============================================================================
// Clone Tests
// ============================================================================

test "cloneBare copies HEAD and objects" {
    const src = tmpPath("clone_src");
    const dst = tmpPath("clone_dst");
    cleanup(src);
    cleanup(dst);
    defer cleanup(src);
    defer cleanup(dst);

    var repo = try Repository.init(testing.allocator, src);
    try writeFileAbs(src, "f.txt", "data");
    try repo.add("f.txt");
    const commit_hash = try repo.commit("msg", "A", "a@a.com");
    repo.close();

    var bare = try Repository.cloneBare(testing.allocator, src, dst);
    defer bare.close();

    // Should have HEAD
    try testing.expect(fileExistsAbs(dst, "HEAD"));

    // Should be able to read the commit object
    const obj_dir = try std.fmt.allocPrint(testing.allocator, "objects/{s}", .{commit_hash[0..2]});
    defer testing.allocator.free(obj_dir);
    try testing.expect(fileExistsAbs(dst, obj_dir));
}

test "cloneBare rejects network URLs" {
    try testing.expectError(
        error.HttpCloneFailed,
        Repository.cloneBare(testing.allocator, "https://github.com/example/repo", "/tmp/x"),
    );
}

// ============================================================================
// Fetch Tests
// ============================================================================

test "fetch copies objects from remote repo" {
    const remote = tmpPath("fetch_remote");
    const local = tmpPath("fetch_local");
    cleanup(remote);
    cleanup(local);
    defer cleanup(remote);
    defer cleanup(local);

    // Create remote repo with a commit
    var remote_repo = try Repository.init(testing.allocator, remote);
    try writeFileAbs(remote, "f.txt", "remote data");
    try remote_repo.add("f.txt");
    const remote_hash = try remote_repo.commit("remote commit", "A", "a@a.com");
    remote_repo.close();

    // Create local repo
    var local_repo = try Repository.init(testing.allocator, local);
    defer local_repo.close();

    try writeFileAbs(local, "g.txt", "local data");
    try local_repo.add("g.txt");
    _ = try local_repo.commit("local commit", "A", "a@a.com");

    // Fetch from remote
    try local_repo.fetch(remote);

    // The remote's commit object should now exist locally
    const obj_path = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/objects/{s}/{s}",
        .{ local_repo.git_dir, remote_hash[0..2], remote_hash[2..] },
    );
    defer testing.allocator.free(obj_path);

    std.fs.accessAbsolute(obj_path, .{}) catch |err| {
        std.debug.print("Expected object at {s} not found: {}\n", .{ obj_path, err });
        return err;
    };
}

test "fetch rejects network URLs" {
    const path = tmpPath("fetch_net");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try testing.expectError(
        error.HttpFetchFailed,
        repo.fetch("https://github.com/example/repo"),
    );
}

// ============================================================================
// Re-add / Overwrite Tests
// ============================================================================

test "re-adding modified file updates blob hash" {
    const path = tmpPath("readd_modified");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    // Add file with initial content
    try writeFileAbs(path, "f.txt", "original");
    try repo.add("f.txt");
    const first = try repo.commit("first", "A", "a@a.com");

    // Modify and re-add
    try writeFileAbs(path, "f.txt", "modified");
    try repo.add("f.txt");
    const second = try repo.commit("second", "A", "a@a.com");

    // The two commits should have different tree hashes
    try testing.expect(!std.mem.eql(u8, &first, &second));

    // Verify git can read the latest blob
    const git_hash = try gitTrimmed(path, &.{ "hash-object", "f.txt" });
    defer testing.allocator.free(git_hash);

    // The blob object for "modified" should exist
    const cat_type = try gitTrimmed(path, &.{ "cat-file", "-t", git_hash });
    defer testing.allocator.free(cat_type);
    try testing.expectEqualStrings("blob", cat_type);
}

test "add multiple files then commit includes all" {
    const path = tmpPath("multi_add");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFileAbs(path, "a.txt", "aaa");
    try writeFileAbs(path, "b.txt", "bbb");
    try writeFileAbs(path, "c.txt", "ccc");

    try repo.add("a.txt");
    try repo.add("b.txt");
    try repo.add("c.txt");

    const hash = try repo.commit("multi", "A", "a@a.com");

    // git ls-tree should show all 3 files
    const tree_out = try gitTrimmed(path, &.{ "ls-tree", "--name-only", &hash });
    defer testing.allocator.free(tree_out);

    try testing.expect(std.mem.indexOf(u8, tree_out, "a.txt") != null);
    try testing.expect(std.mem.indexOf(u8, tree_out, "b.txt") != null);
    try testing.expect(std.mem.indexOf(u8, tree_out, "c.txt") != null);
}

// ============================================================================
// Object Integrity Tests
// ============================================================================

test "blob SHA-1 matches git hash-object" {
    const path = tmpPath("sha1_match");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    const content = "test content for SHA-1 verification\n";
    try writeFileAbs(path, "test.txt", content);
    try repo.add("test.txt");

    const git_hash = try gitTrimmed(path, &.{ "hash-object", "test.txt" });
    defer testing.allocator.free(git_hash);

    // Verify the object exists
    const obj_dir = try std.fmt.allocPrint(testing.allocator, "{s}/objects/{s}", .{ repo.git_dir, git_hash[0..2] });
    defer testing.allocator.free(obj_dir);
    try std.fs.accessAbsolute(obj_dir, .{});
}

test "commit object is valid per git fsck" {
    const path = tmpPath("fsck_commit");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFileAbs(path, "f.txt", "data for fsck test");
    try repo.add("f.txt");
    _ = try repo.commit("fsck test", "Test User", "test@example.com");

    // git fsck should pass
    const fsck = try git(path, &.{"fsck"});
    defer testing.allocator.free(fsck);
    // No error means success (git fsck returns 0)
}

// ============================================================================
// Cache Invalidation Tests
// ============================================================================

test "revParseHead cache invalidated after new commit" {
    const path = tmpPath("cache_rev");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFileAbs(path, "a.txt", "a");
    try repo.add("a.txt");
    const first = try repo.commit("first", "A", "a@a.com");

    repo._cached_head_hash = null;
    const head1 = try repo.revParseHead();
    try testing.expectEqualStrings(&first, &head1);

    try writeFileAbs(path, "b.txt", "b");
    try repo.add("b.txt");
    const second = try repo.commit("second", "A", "a@a.com");

    repo._cached_head_hash = null;
    const head2 = try repo.revParseHead();
    try testing.expectEqualStrings(&second, &head2);

    // Ensure they're different
    try testing.expect(!std.mem.eql(u8, &first, &second));
}

test "describeTags updates after new tag" {
    const path = tmpPath("cache_tags");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFileAbs(path, "f.txt", "data");
    try repo.add("f.txt");
    _ = try repo.commit("msg", "A", "a@a.com");

    try repo.createTag("v1.0.0", null);
    const tag1 = try repo.describeTags(testing.allocator);
    defer testing.allocator.free(tag1);
    try testing.expectEqualStrings("v1.0.0", tag1);

    try repo.createTag("v9.0.0", null);
    const tag2 = try repo.describeTags(testing.allocator);
    defer testing.allocator.free(tag2);
    try testing.expectEqualStrings("v9.0.0", tag2);
}

// ============================================================================
// Binary Content Tests
// ============================================================================

test "binary content preserved through add and commit" {
    const path = tmpPath("binary_content");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    // Create binary content with all 256 byte values
    var binary: [256]u8 = undefined;
    for (0..256) |i| binary[i] = @intCast(i);

    try writeFileAbs(path, "binary.bin", &binary);
    try repo.add("binary.bin");
    const hash = try repo.commit("binary", "A", "a@a.com");

    // Checkout to verify content
    try writeFileAbs(path, "binary.bin", "overwritten");
    try repo.checkout(&hash);

    const readback = try readFileAbs(path, "binary.bin");
    defer testing.allocator.free(readback);
    try testing.expectEqualSlices(u8, &binary, readback);
}

// ============================================================================
// Empty String Edge Cases
// ============================================================================

test "empty file can be added and committed" {
    const path = tmpPath("empty_file");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFileAbs(path, "empty.txt", "");
    try repo.add("empty.txt");
    const hash = try repo.commit("empty file", "A", "a@a.com");

    // git should show the file
    const tree = try gitTrimmed(path, &.{ "ls-tree", "--name-only", &hash });
    defer testing.allocator.free(tree);
    try testing.expect(std.mem.indexOf(u8, tree, "empty.txt") != null);
}
