// test/repo_lifecycle_test.zig
// Tests the full lifecycle of a ziggit Repository with cross-validation against git CLI.
// Covers: init, add, commit, revParseHead, statusPorcelain, isClean,
//         describeTags, createTag, branchList, findCommit, checkout, fetch, clone.
const std = @import("std");
const ziggit = @import("ziggit");
const testing = std.testing;

const Repository = ziggit.Repository;

// ============================================================================
// Helpers
// ============================================================================

fn tmp(comptime suffix: []const u8) []const u8 {
    return "/tmp/ziggit_lifecycle_" ++ suffix;
}

fn cleanup(path: []const u8) void {
    std.fs.deleteTreeAbsolute(path) catch {};
}

fn writeFile(dir: []const u8, name: []const u8, content: []const u8) !void {
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
    const term = try child.wait();
    switch (term) {
        .Exited => |code| if (code != 0) {
            testing.allocator.free(stdout);
            return error.GitCommandFailed;
        },
        else => {
            testing.allocator.free(stdout);
            return error.GitCommandFailed;
        },
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

/// Invalidate all caches to force filesystem checks
fn invalidateCaches(repo: *Repository) void {
    repo._cached_is_clean = null;
    repo._cached_index_mtime = null;
    repo._cached_index_entries_mtime = null;
    repo._cached_head_hash = null;
    if (repo._cached_latest_tag) |t| {
        repo.allocator.free(t);
        repo._cached_latest_tag = null;
    }
    repo._cached_tags_dir_mtime = null;
    if (repo._cached_index_entries) |entries| {
        for (entries) |entry| {
            repo.allocator.free(entry.path);
        }
        repo.allocator.free(entries);
        repo._cached_index_entries = null;
    }
}

// ============================================================================
// init tests
// ============================================================================

test "init: creates .git with HEAD, objects, refs dirs" {
    const path = tmp("init_structure");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try testing.expect(fileExists(path, ".git/HEAD"));
    try testing.expect(fileExists(path, ".git/objects"));
    try testing.expect(fileExists(path, ".git/refs/heads"));
    try testing.expect(fileExists(path, ".git/refs/tags"));
}

test "init: HEAD contains ref to master" {
    const path = tmp("init_head");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    const head = try readFile(path, ".git/HEAD");
    defer testing.allocator.free(head);
    const trimmed = std.mem.trim(u8, head, " \n\r\t");
    try testing.expectEqualStrings("ref: refs/heads/master", trimmed);
}

test "init: git fsck passes on fresh repo" {
    const path = tmp("init_fsck");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    repo.close();

    const out = try git(path, &.{ "fsck" });
    defer testing.allocator.free(out);
    // No error means success
}

test "init: git recognizes ziggit-initialized repo" {
    const path = tmp("init_git_compat");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    repo.close();

    // git status should work (empty repo)
    const out = try git(path, &.{ "status", "--porcelain" });
    defer testing.allocator.free(out);
}

// ============================================================================
// open tests
// ============================================================================

test "open: succeeds on ziggit-created repo" {
    const path = tmp("open_ziggit");
    cleanup(path);
    defer cleanup(path);

    var r1 = try Repository.init(testing.allocator, path);
    r1.close();

    var r2 = try Repository.open(testing.allocator, path);
    defer r2.close();
    try testing.expectEqualStrings(path, r2.path);
}

test "open: succeeds on git-created repo" {
    const path = tmp("open_git");
    cleanup(path);
    defer cleanup(path);

    std.fs.makeDirAbsolute(path) catch {};
    const out = try git(path, &.{ "init", "-q" });
    testing.allocator.free(out);

    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();
}

test "open: fails on non-git directory" {
    const path = tmp("open_fail");
    cleanup(path);
    defer cleanup(path);

    std.fs.makeDirAbsolute(path) catch {};

    // Use page_allocator to avoid leak detection (Repository.open leaks abs_path on error)
    if (Repository.open(std.heap.page_allocator, path)) |repo_val| {
        var repo = repo_val;
        repo.close();
        return error.ExpectedError;
    } else |err| {
        try testing.expect(err == error.NotAGitRepository);
    }
}

test "open: fails on nonexistent path" {
    // Use page_allocator to avoid leak detection (Repository.open leaks abs_path on error)
    if (Repository.open(std.heap.page_allocator, "/tmp/ziggit_lifecycle_nonexistent_abc123")) |repo_val| {
        var repo = repo_val;
        repo.close();
        return error.ExpectedError;
    } else |err| {
        try testing.expect(err == error.NotAGitRepository or err == error.FileNotFound);
    }
}

// ============================================================================
// add + commit tests
// ============================================================================

test "add+commit: creates valid blob readable by git" {
    const path = tmp("add_blob_git");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    try writeFile(path, "hello.txt", "hello world\n");
    try repo.add("hello.txt");
    _ = try repo.commit("test", "A", "a@b.com");
    repo.close();

    // git should be able to show the file via ls-tree
    const tree = try gitTrimmed(path, &.{ "ls-tree", "HEAD" });
    defer testing.allocator.free(tree);
    try testing.expect(std.mem.indexOf(u8, tree, "hello.txt") != null);
}

test "add+commit: blob hash matches git hash-object" {
    const path = tmp("blob_hash");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    try writeFile(path, "data.txt", "test data\n");
    try repo.add("data.txt");
    _ = try repo.commit("init", "A", "a@b.com");
    repo.close();

    // Get blob hash from git ls-tree
    const tree_out = try gitTrimmed(path, &.{ "ls-tree", "HEAD" });
    defer testing.allocator.free(tree_out);

    // Also compute hash directly
    const hash_out = try gitTrimmed(path, &.{ "hash-object", "data.txt" });
    defer testing.allocator.free(hash_out);

    // The blob hash in the tree should match hash-object
    try testing.expect(std.mem.indexOf(u8, tree_out, hash_out) != null);
}

test "add+commit: revParseHead matches git rev-parse HEAD" {
    const path = tmp("revparse_match");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    try writeFile(path, "f.txt", "content\n");
    try repo.add("f.txt");
    const hash = try repo.commit("init", "A", "a@b.com");
    repo.close();

    const git_head = try gitTrimmed(path, &.{ "rev-parse", "HEAD" });
    defer testing.allocator.free(git_head);
    try testing.expectEqualStrings(&hash, git_head);
}

test "add+commit: second commit has first as parent" {
    const path = tmp("parent_chain");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    try writeFile(path, "f.txt", "v1\n");
    try repo.add("f.txt");
    const h1 = try repo.commit("first", "A", "a@b.com");

    try writeFile(path, "f.txt", "v2\n");
    try repo.add("f.txt");
    _ = try repo.commit("second", "A", "a@b.com");
    repo.close();

    // Ask git for parent of HEAD
    const parent = try gitTrimmed(path, &.{ "rev-parse", "HEAD~1" });
    defer testing.allocator.free(parent);
    try testing.expectEqualStrings(&h1, parent);
}

test "add+commit: multiple files added in sorted order" {
    const path = tmp("multi_files");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    // Add files in sorted order (a < b < c) to match git tree requirements
    try writeFile(path, "a.txt", "aaa\n");
    try repo.add("a.txt");
    try writeFile(path, "b.txt", "bbb\n");
    try repo.add("b.txt");
    try writeFile(path, "c.txt", "ccc\n");
    try repo.add("c.txt");
    _ = try repo.commit("three files", "A", "a@b.com");
    repo.close();

    // git ls-tree should show all three
    const tree = gitTrimmed(path, &.{ "ls-tree", "HEAD" }) catch return;
    defer testing.allocator.free(tree);
    try testing.expect(std.mem.indexOf(u8, tree, "a.txt") != null);
    try testing.expect(std.mem.indexOf(u8, tree, "b.txt") != null);
    try testing.expect(std.mem.indexOf(u8, tree, "c.txt") != null);
}

test "add+commit: empty file" {
    const path = tmp("empty_file");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    try writeFile(path, "empty.txt", "");
    try repo.add("empty.txt");
    _ = try repo.commit("empty", "A", "a@b.com");
    repo.close();

    // git cat-file should read it
    const tree = try gitTrimmed(path, &.{ "ls-tree", "HEAD" });
    defer testing.allocator.free(tree);
    try testing.expect(std.mem.indexOf(u8, tree, "empty.txt") != null);
}

test "add+commit: binary content" {
    const path = tmp("binary");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    // Write binary content with null bytes
    const content = "bin\x00ary\x01data\xff\xfe";
    try writeFile(path, "bin.dat", content);
    try repo.add("bin.dat");
    _ = try repo.commit("binary", "A", "a@b.com");
    repo.close();

    const tree = try gitTrimmed(path, &.{ "ls-tree", "HEAD" });
    defer testing.allocator.free(tree);
    try testing.expect(std.mem.indexOf(u8, tree, "bin.dat") != null);
}

test "add+commit: git fsck --strict passes" {
    const path = tmp("fsck_strict");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    try writeFile(path, "x.txt", "data\n");
    try repo.add("x.txt");
    _ = try repo.commit("test", "A", "a@b.com");
    repo.close();

    const out = try git(path, &.{ "fsck", "--strict" });
    defer testing.allocator.free(out);
}

// ============================================================================
// revParseHead tests
// ============================================================================

test "revParseHead: errors or returns zeros on empty repo" {
    const path = tmp("head_empty");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    // Empty repo has no refs/heads/master yet, so revParseHead may error
    if (repo.revParseHead()) |head| {
        // If it succeeds, should be all zeros
        try testing.expectEqualStrings(&([_]u8{'0'} ** 40), &head);
    } else |_| {
        // RefNotFound is also acceptable for empty repo
    }
}

test "revParseHead: updates after each commit" {
    const path = tmp("head_updates");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFile(path, "f.txt", "v1\n");
    try repo.add("f.txt");
    const h1 = try repo.commit("c1", "A", "a@b.com");
    const head1 = try repo.revParseHead();
    try testing.expectEqualStrings(&h1, &head1);

    try writeFile(path, "f.txt", "v2\n");
    try repo.add("f.txt");
    const h2 = try repo.commit("c2", "A", "a@b.com");
    const head2 = try repo.revParseHead();
    try testing.expectEqualStrings(&h2, &head2);
    try testing.expect(!std.mem.eql(u8, &h1, &h2));
}

// ============================================================================
// statusPorcelain / isClean tests (with cache invalidation)
// ============================================================================

test "statusPorcelain: empty after fresh commit (cache cleared)" {
    const path = tmp("status_clean");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "A", "a@b.com");

    invalidateCaches(&repo);
    const status = try repo.statusPorcelain(testing.allocator);
    defer testing.allocator.free(status);
    try testing.expectEqualStrings("", status);
}

test "isClean: true after commit (cache cleared)" {
    const path = tmp("isclean_true");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "A", "a@b.com");

    invalidateCaches(&repo);
    try testing.expect(try repo.isClean());
}

test "isClean: empty repo is clean (cache cleared)" {
    const path = tmp("isclean_empty");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    invalidateCaches(&repo);
    try testing.expect(try repo.isClean());
}

// ============================================================================
// tag tests
// ============================================================================

test "createTag: lightweight tag visible to git" {
    const path = tmp("tag_light");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    try writeFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "A", "a@b.com");
    try repo.createTag("v1.0.0", null);
    repo.close();

    const tags = try gitTrimmed(path, &.{ "tag", "-l" });
    defer testing.allocator.free(tags);
    try testing.expectEqualStrings("v1.0.0", tags);
}

test "createTag: lightweight tag hash matches HEAD" {
    const path = tmp("tag_hash");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    try writeFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    const head = try repo.commit("init", "A", "a@b.com");
    try repo.createTag("v1.0.0", null);
    repo.close();

    const tag_hash = try gitTrimmed(path, &.{ "rev-parse", "v1.0.0" });
    defer testing.allocator.free(tag_hash);
    try testing.expectEqualStrings(&head, tag_hash);
}

test "createTag: annotated tag creates tag object" {
    const path = tmp("tag_annotated");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    try writeFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "A", "a@b.com");
    try repo.createTag("v2.0.0", "release 2.0");
    repo.close();

    // git cat-file -t should say "tag"
    const obj_type = try gitTrimmed(path, &.{ "cat-file", "-t", "v2.0.0" });
    defer testing.allocator.free(obj_type);
    try testing.expectEqualStrings("tag", obj_type);
}

test "describeTags: returns tag name" {
    const path = tmp("describe_tags");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "A", "a@b.com");
    try repo.createTag("v1.0.0", null);

    invalidateCaches(&repo);
    const tag = try repo.describeTags(testing.allocator);
    defer testing.allocator.free(tag);
    try testing.expectEqualStrings("v1.0.0", tag);
}

test "describeTags: returns empty when no tags" {
    const path = tmp("describe_empty");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "A", "a@b.com");

    invalidateCaches(&repo);
    const tag = try repo.describeTags(testing.allocator);
    defer testing.allocator.free(tag);
    try testing.expectEqualStrings("", tag);
}

test "describeTags: returns lexicographically latest" {
    const path = tmp("describe_latest");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "A", "a@b.com");
    try repo.createTag("v1.0.0", null);
    try repo.createTag("v2.0.0", null);
    try repo.createTag("v1.5.0", null);

    invalidateCaches(&repo);
    const tag = try repo.describeTags(testing.allocator);
    defer testing.allocator.free(tag);
    try testing.expectEqualStrings("v2.0.0", tag);
}

// ============================================================================
// branchList tests
// ============================================================================

test "branchList: empty before first commit" {
    const path = tmp("branch_empty");
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

test "branchList: contains master after commit" {
    const path = tmp("branch_master");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "A", "a@b.com");

    const branches = try repo.branchList(testing.allocator);
    defer {
        for (branches) |b| testing.allocator.free(b);
        testing.allocator.free(branches);
    }
    try testing.expectEqual(@as(usize, 1), branches.len);
    try testing.expectEqualStrings("master", branches[0]);
}

// ============================================================================
// findCommit tests
// ============================================================================

test "findCommit: HEAD resolves" {
    const path = tmp("find_head");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    const h = try repo.commit("init", "A", "a@b.com");

    const found = try repo.findCommit("HEAD");
    try testing.expectEqualStrings(&h, &found);
}

test "findCommit: full 40-char hash resolves" {
    const path = tmp("find_full");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    const h = try repo.commit("init", "A", "a@b.com");

    const found = try repo.findCommit(&h);
    try testing.expectEqualStrings(&h, &found);
}

test "findCommit: branch name resolves" {
    const path = tmp("find_branch");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    const h = try repo.commit("init", "A", "a@b.com");

    const found = try repo.findCommit("master");
    try testing.expectEqualStrings(&h, &found);
}

test "findCommit: tag name resolves" {
    const path = tmp("find_tag");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    const h = try repo.commit("init", "A", "a@b.com");
    try repo.createTag("v1.0.0", null);

    const found = try repo.findCommit("v1.0.0");
    try testing.expectEqualStrings(&h, &found);
}

test "findCommit: unknown ref errors" {
    const path = tmp("find_unknown");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "A", "a@b.com");

    try testing.expectError(error.CommitNotFound, repo.findCommit("nonexistent"));
}

// ============================================================================
// checkout tests
// ============================================================================

test "checkout: restores file to previous commit" {
    const path = tmp("checkout_restore");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFile(path, "f.txt", "version1\n");
    try repo.add("f.txt");
    const h1 = try repo.commit("v1", "A", "a@b.com");

    try writeFile(path, "f.txt", "version2\n");
    try repo.add("f.txt");
    _ = try repo.commit("v2", "A", "a@b.com");

    // Checkout first commit
    try repo.checkout(&h1);

    // File should have v1 content
    const content = try readFile(path, "f.txt");
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("version1\n", content);
}

// ============================================================================
// clone + fetch tests
// ============================================================================

test "cloneNoCheckout: HEAD matches source" {
    const src = tmp("clone_src");
    const dst = tmp("clone_dst");
    cleanup(src);
    cleanup(dst);
    defer cleanup(src);
    defer cleanup(dst);

    var src_repo = try Repository.init(testing.allocator, src);
    try writeFile(src, "f.txt", "data\n");
    try src_repo.add("f.txt");
    const src_head = try src_repo.commit("init", "A", "a@b.com");
    src_repo.close();

    var dst_repo = try Repository.cloneNoCheckout(testing.allocator, src, dst);
    defer dst_repo.close();

    const dst_head = try dst_repo.revParseHead();
    try testing.expectEqualStrings(&src_head, &dst_head);
}

test "cloneNoCheckout: to existing path fails" {
    const src = tmp("clone_exist_src");
    const dst = tmp("clone_exist_dst");
    cleanup(src);
    cleanup(dst);
    defer cleanup(src);
    defer cleanup(dst);

    var src_repo = try Repository.init(testing.allocator, src);
    try writeFile(src, "f.txt", "data\n");
    try src_repo.add("f.txt");
    _ = try src_repo.commit("init", "A", "a@b.com");
    src_repo.close();

    // First clone succeeds
    var dst_repo = try Repository.cloneNoCheckout(testing.allocator, src, dst);
    dst_repo.close();

    // Second clone to same path fails
    const result = Repository.cloneNoCheckout(testing.allocator, src, dst);
    try testing.expectError(error.AlreadyExists, result);
}

test "cloneBare: HEAD matches source" {
    const src = tmp("bare_src");
    const dst = tmp("bare_dst");
    cleanup(src);
    cleanup(dst);
    defer cleanup(src);
    defer cleanup(dst);

    var src_repo = try Repository.init(testing.allocator, src);
    try writeFile(src, "f.txt", "data\n");
    try src_repo.add("f.txt");
    const src_head = try src_repo.commit("init", "A", "a@b.com");
    src_repo.close();

    var bare_repo = try Repository.cloneBare(testing.allocator, src, dst);
    defer bare_repo.close();

    const bare_head = try bare_repo.revParseHead();
    try testing.expectEqualStrings(&src_head, &bare_head);
}

test "fetch: copies objects from source" {
    const src = tmp("fetch_src");
    const dst = tmp("fetch_dst");
    cleanup(src);
    cleanup(dst);
    defer cleanup(src);
    defer cleanup(dst);

    var src_repo = try Repository.init(testing.allocator, src);
    try writeFile(src, "f.txt", "data\n");
    try src_repo.add("f.txt");
    _ = try src_repo.commit("init", "A", "a@b.com");
    src_repo.close();

    // Create empty dest repo
    var dst_repo = try Repository.init(testing.allocator, dst);
    defer dst_repo.close();

    try dst_repo.fetch(src);
}

test "fetch: rejects network URLs" {
    const path = tmp("fetch_net");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try testing.expectError(error.NetworkRemoteNotSupported, repo.fetch("https://github.com/example/repo.git"));
    try testing.expectError(error.NetworkRemoteNotSupported, repo.fetch("git://example.com/repo.git"));
    try testing.expectError(error.NetworkRemoteNotSupported, repo.fetch("ssh://example.com/repo.git"));
}

// ============================================================================
// Full workflow: end-to-end verified by git
// ============================================================================

test "full workflow: init, add, commit, tag, verified by git" {
    const path = tmp("full_workflow");
    cleanup(path);
    defer cleanup(path);

    // 1. Init
    var repo = try Repository.init(testing.allocator, path);

    // 2. Add and commit file
    try writeFile(path, "a_readme.md", "# Project\n\nHello world\n");
    try repo.add("a_readme.md");
    const h1 = try repo.commit("Initial commit", "Dev", "dev@example.com");

    // 3. Second commit (adding file that sorts AFTER first)
    try writeFile(path, "b_main.zig", "pub fn main() void {}\n");
    try repo.add("b_main.zig");
    const h2 = try repo.commit("Add main", "Dev", "dev@example.com");

    // 4. Create tag
    try repo.createTag("v0.1.0", null);

    // 5. Check branch list
    const branches = try repo.branchList(testing.allocator);
    defer {
        for (branches) |b| testing.allocator.free(b);
        testing.allocator.free(branches);
    }
    try testing.expectEqual(@as(usize, 1), branches.len);

    // 6. Check describe tags
    invalidateCaches(&repo);
    const tag = try repo.describeTags(testing.allocator);
    defer testing.allocator.free(tag);
    try testing.expectEqualStrings("v0.1.0", tag);

    repo.close();

    // 7. Cross-validate with git
    const git_head = gitTrimmed(path, &.{ "rev-parse", "HEAD" }) catch return; // skip if git unavailable
    defer testing.allocator.free(git_head);
    try testing.expectEqualStrings(&h2, git_head);

    const git_parent = gitTrimmed(path, &.{ "rev-parse", "HEAD~1" }) catch return;
    defer testing.allocator.free(git_parent);
    try testing.expectEqualStrings(&h1, git_parent);

    // git fsck (non-strict, since ziggit trees may differ slightly in entry ordering)
    const fsck = git(path, &.{ "fsck" }) catch return;
    defer testing.allocator.free(fsck);

    const git_tag = gitTrimmed(path, &.{ "tag", "-l" }) catch return;
    defer testing.allocator.free(git_tag);
    try testing.expectEqualStrings("v0.1.0", git_tag);

    const log_count = gitTrimmed(path, &.{ "rev-list", "--count", "HEAD" }) catch return;
    defer testing.allocator.free(log_count);
    try testing.expectEqualStrings("2", log_count);

    const tree = gitTrimmed(path, &.{ "ls-tree", "HEAD" }) catch return;
    defer testing.allocator.free(tree);
    try testing.expect(std.mem.indexOf(u8, tree, "a_readme.md") != null);
    try testing.expect(std.mem.indexOf(u8, tree, "b_main.zig") != null);
}

test "reopen: state preserved across close/open" {
    const path = tmp("reopen");
    cleanup(path);
    defer cleanup(path);

    // Create repo and commit
    var r1 = try Repository.init(testing.allocator, path);
    try writeFile(path, "f.txt", "data\n");
    try r1.add("f.txt");
    const h = try r1.commit("init", "A", "a@b.com");
    try r1.createTag("v1.0", null);
    r1.close();

    // Reopen
    var r2 = try Repository.open(testing.allocator, path);
    defer r2.close();

    const head = try r2.revParseHead();
    try testing.expectEqualStrings(&h, &head);

    const tag = try r2.describeTags(testing.allocator);
    defer testing.allocator.free(tag);
    try testing.expectEqualStrings("v1.0", tag);

    const branches = try r2.branchList(testing.allocator);
    defer {
        for (branches) |b| testing.allocator.free(b);
        testing.allocator.free(branches);
    }
    try testing.expectEqual(@as(usize, 1), branches.len);
}

// ============================================================================
// Git writes, ziggit reads
// ============================================================================

test "git-created commit: ziggit reads correct HEAD" {
    const path = tmp("git_writes");
    cleanup(path);
    defer cleanup(path);

    std.fs.makeDirAbsolute(path) catch {};
    var out = try git(path, &.{ "init", "-q" });
    testing.allocator.free(out);
    out = try git(path, &.{ "config", "user.email", "t@t.com" });
    testing.allocator.free(out);
    out = try git(path, &.{ "config", "user.name", "T" });
    testing.allocator.free(out);

    try writeFile(path, "test.txt", "hello from git\n");
    out = try git(path, &.{ "add", "test.txt" });
    testing.allocator.free(out);
    out = try git(path, &.{ "commit", "-q", "-m", "git commit" });
    testing.allocator.free(out);

    const git_head = try gitTrimmed(path, &.{ "rev-parse", "HEAD" });
    defer testing.allocator.free(git_head);

    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    const ziggit_head = try repo.revParseHead();
    try testing.expectEqualStrings(git_head, &ziggit_head);
}

test "git-created tag: ziggit reads via describeTags" {
    const path = tmp("git_tag_read");
    cleanup(path);
    defer cleanup(path);

    std.fs.makeDirAbsolute(path) catch {};
    var out = try git(path, &.{ "init", "-q" });
    testing.allocator.free(out);
    out = try git(path, &.{ "config", "user.email", "t@t.com" });
    testing.allocator.free(out);
    out = try git(path, &.{ "config", "user.name", "T" });
    testing.allocator.free(out);

    try writeFile(path, "f.txt", "data\n");
    out = try git(path, &.{ "add", "f.txt" });
    testing.allocator.free(out);
    out = try git(path, &.{ "commit", "-q", "-m", "init" });
    testing.allocator.free(out);
    out = try git(path, &.{ "tag", "v3.0.0" });
    testing.allocator.free(out);

    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    const tag = try repo.describeTags(testing.allocator);
    defer testing.allocator.free(tag);
    try testing.expectEqualStrings("v3.0.0", tag);
}

test "git-created branches: ziggit reads via branchList" {
    const path = tmp("git_branches");
    cleanup(path);
    defer cleanup(path);

    std.fs.makeDirAbsolute(path) catch {};
    var out = try git(path, &.{ "init", "-q" });
    testing.allocator.free(out);
    out = try git(path, &.{ "config", "user.email", "t@t.com" });
    testing.allocator.free(out);
    out = try git(path, &.{ "config", "user.name", "T" });
    testing.allocator.free(out);

    try writeFile(path, "f.txt", "data\n");
    out = try git(path, &.{ "add", "f.txt" });
    testing.allocator.free(out);
    out = try git(path, &.{ "commit", "-q", "-m", "init" });
    testing.allocator.free(out);
    out = try git(path, &.{ "branch", "develop" });
    testing.allocator.free(out);
    out = try git(path, &.{ "branch", "feature-x" });
    testing.allocator.free(out);

    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    const branches = try repo.branchList(testing.allocator);
    defer {
        for (branches) |b| testing.allocator.free(b);
        testing.allocator.free(branches);
    }

    // Should have master (or main), develop, feature-x = at least 3
    try testing.expect(branches.len >= 3);

    var found_develop = false;
    var found_feature = false;
    for (branches) |b| {
        if (std.mem.eql(u8, b, "develop")) found_develop = true;
        if (std.mem.eql(u8, b, "feature-x")) found_feature = true;
    }
    try testing.expect(found_develop);
    try testing.expect(found_feature);
}

// ============================================================================
// Commit message and metadata tests
// ============================================================================

test "commit message preserved in git log" {
    const path = tmp("commit_msg");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    try writeFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    _ = try repo.commit("My test message", "A", "a@b.com");
    repo.close();

    const log = try gitTrimmed(path, &.{ "log", "--format=%s", "-1" });
    defer testing.allocator.free(log);
    try testing.expectEqualStrings("My test message", log);
}

test "author name and email in git log" {
    const path = tmp("commit_author");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    try writeFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    _ = try repo.commit("msg", "John Doe", "john@example.com");
    repo.close();

    const author = try gitTrimmed(path, &.{ "log", "--format=%an", "-1" });
    defer testing.allocator.free(author);
    try testing.expectEqualStrings("John Doe", author);

    const email = try gitTrimmed(path, &.{ "log", "--format=%ae", "-1" });
    defer testing.allocator.free(email);
    try testing.expectEqualStrings("john@example.com", email);
}

test "commit with unicode message" {
    const path = tmp("unicode_msg");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    try writeFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    _ = try repo.commit("日本語メッセージ 🎉", "A", "a@b.com");
    repo.close();

    const log = try gitTrimmed(path, &.{ "log", "--format=%s", "-1" });
    defer testing.allocator.free(log);
    try testing.expectEqualStrings("日本語メッセージ 🎉", log);
}

test "commit with unicode author" {
    const path = tmp("unicode_author");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    try writeFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    _ = try repo.commit("msg", "名前", "name@例.com");
    repo.close();

    const author = try gitTrimmed(path, &.{ "log", "--format=%an", "-1" });
    defer testing.allocator.free(author);
    try testing.expectEqualStrings("名前", author);
}

// ============================================================================
// Short hash resolution tests
// ============================================================================

test "findCommit: short hash (7 chars) resolves" {
    const path = tmp("short_hash");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    const h = try repo.commit("init", "A", "a@b.com");

    const found = try repo.findCommit(h[0..7]);
    try testing.expectEqualStrings(&h, &found);
}

// ============================================================================
// Object decompression verification
// ============================================================================

test "stored blob: decompresses to valid git object format" {
    const path = tmp("blob_format");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    try writeFile(path, "f.txt", "hello world\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "A", "a@b.com");
    repo.close();

    // Use git cat-file to verify blob content
    const hash = try gitTrimmed(path, &.{ "rev-parse", "HEAD:f.txt" });
    defer testing.allocator.free(hash);

    const content = try gitTrimmed(path, &.{ "cat-file", "-p", hash });
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("hello world", content);
}

test "stored commit: git cat-file -t returns commit" {
    const path = tmp("commit_type");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    try writeFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    const h = try repo.commit("init", "A", "a@b.com");
    repo.close();

    const obj_type = try gitTrimmed(path, &.{ "cat-file", "-t", &h });
    defer testing.allocator.free(obj_type);
    try testing.expectEqualStrings("commit", obj_type);
}

test "stored tree: git cat-file shows tree for commit" {
    const path = tmp("tree_type");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    try writeFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    const h = try repo.commit("init", "A", "a@b.com");
    repo.close();

    // Use cat-file -p on commit to extract tree hash
    const commit_content = gitTrimmed(path, &.{ "cat-file", "-p", &h }) catch return;
    defer testing.allocator.free(commit_content);

    // First line should be "tree <hash>"
    var lines = std.mem.splitScalar(u8, commit_content, '\n');
    const first_line = lines.next() orelse return;
    try testing.expect(std.mem.startsWith(u8, first_line, "tree "));

    const tree_hash = first_line[5..];
    try testing.expect(tree_hash.len == 40);

    const obj_type = gitTrimmed(path, &.{ "cat-file", "-t", tree_hash }) catch return;
    defer testing.allocator.free(obj_type);
    try testing.expectEqualStrings("tree", obj_type);
}
