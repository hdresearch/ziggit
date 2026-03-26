// test/object_format_git_crossval_test.zig
// Tests that ziggit-created git objects (blobs, trees, commits, tags) are
// byte-for-byte correct by cross-validating with the git CLI.
// Also tests that objects created by git can be read correctly by ziggit.
const std = @import("std");
const ziggit = @import("ziggit");
const testing = std.testing;

const Repository = ziggit.Repository;

fn tmpPath(comptime suffix: []const u8) []const u8 {
    return "/tmp/ziggit_obj_crossval_" ++ suffix;
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

fn runGit(args: []const []const u8, cwd: []const u8) ![]u8 {
    var child = std.process.Child.init(args, testing.allocator);
    child.cwd = cwd;
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

fn runGitNoCheck(args: []const []const u8, cwd: []const u8) !void {
    var child = std.process.Child.init(args, testing.allocator);
    child.cwd = cwd;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const stdout = try child.stdout.?.reader().readAllAlloc(testing.allocator, 1024 * 1024);
    defer testing.allocator.free(stdout);
    const stderr = try child.stderr.?.reader().readAllAlloc(testing.allocator, 1024 * 1024);
    defer testing.allocator.free(stderr);
    _ = try child.wait();
}

// === Blob object tests ===

test "blob: ziggit-created blob readable by git cat-file" {
    const path = tmpPath("blob_catfile");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    const content = "Hello, World!\n";
    try createFile(path, "test.txt", content);
    try repo.add("test.txt");
    _ = try repo.commit("add test.txt", "Test", "t@t.com");

    // git cat-file -p HEAD:test.txt should return the content
    const out = try runGit(&.{ "git", "cat-file", "-p", "HEAD:test.txt" }, path);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(content, out);
}

test "blob: ziggit blob hash matches git hash-object" {
    const path = tmpPath("blob_hash_match");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    const content = "test content\n";
    try createFile(path, "f.txt", content);
    try repo.add("f.txt");
    _ = try repo.commit("init", "Test", "t@t.com");

    // Get hash from ziggit's tree
    const ls_out = try runGit(&.{ "git", "ls-tree", "HEAD" }, path);
    defer testing.allocator.free(ls_out);

    // Also compute hash with git hash-object
    const hash_out = try runGit(&.{ "git", "hash-object", "f.txt" }, path);
    defer testing.allocator.free(hash_out);
    const git_hash = std.mem.trim(u8, hash_out, " \n\r\t");

    // The blob hash in the tree should match git hash-object
    try testing.expect(std.mem.indexOf(u8, ls_out, git_hash) != null);
}

test "blob: empty file produces correct blob" {
    const path = tmpPath("blob_empty");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "empty.txt", "");
    try repo.add("empty.txt");
    _ = try repo.commit("empty file", "Test", "t@t.com");

    const out = try runGit(&.{ "git", "cat-file", "-p", "HEAD:empty.txt" }, path);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("", out);
}

test "blob: binary content with all 256 byte values" {
    const path = tmpPath("blob_binary");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    // Create file with all 256 byte values
    var content: [256]u8 = undefined;
    for (0..256) |i| content[i] = @intCast(i);

    try createFile(path, "binary.bin", &content);
    try repo.add("binary.bin");
    _ = try repo.commit("binary file", "Test", "t@t.com");

    // Verify git cat-file -s reports correct size
    const size_out = try runGit(&.{ "git", "cat-file", "-s", "HEAD:binary.bin" }, path);
    defer testing.allocator.free(size_out);
    const size_str = std.mem.trim(u8, size_out, " \n\r\t");
    try testing.expectEqualStrings("256", size_str);

    // Verify type
    const type_out = try runGit(&.{ "git", "cat-file", "-t", "HEAD:binary.bin" }, path);
    defer testing.allocator.free(type_out);
    const type_str = std.mem.trim(u8, type_out, " \n\r\t");
    try testing.expectEqualStrings("blob", type_str);
}

// === Tree object tests ===

test "tree: git cat-file -t on ziggit tree returns 'tree'" {
    const path = tmpPath("tree_type");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "content");
    try repo.add("f.txt");
    _ = try repo.commit("init", "Test", "t@t.com");

    // Get tree hash from commit
    const tree_out = try runGit(&.{ "git", "rev-parse", "HEAD^{tree}" }, path);
    defer testing.allocator.free(tree_out);
    const tree_hash = std.mem.trim(u8, tree_out, " \n\r\t");

    const type_out = try runGit(&.{ "git", "cat-file", "-t", tree_hash }, path);
    defer testing.allocator.free(type_out);
    try testing.expectEqualStrings("tree", std.mem.trim(u8, type_out, " \n\r\t"));
}

test "tree: multiple files listed correctly by git ls-tree" {
    const path = tmpPath("tree_multi");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "alpha.txt", "aaa");
    try createFile(path, "beta.txt", "bbb");
    try createFile(path, "gamma.txt", "ggg");
    try repo.add("alpha.txt");
    try repo.add("beta.txt");
    try repo.add("gamma.txt");
    _ = try repo.commit("multi", "Test", "t@t.com");

    const out = try runGit(&.{ "git", "ls-tree", "--name-only", "HEAD" }, path);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "alpha.txt") != null);
    try testing.expect(std.mem.indexOf(u8, out, "beta.txt") != null);
    try testing.expect(std.mem.indexOf(u8, out, "gamma.txt") != null);
}

test "tree: file mode is 100644 for regular files" {
    const path = tmpPath("tree_mode");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "content");
    try repo.add("f.txt");
    _ = try repo.commit("init", "Test", "t@t.com");

    const out = try runGit(&.{ "git", "ls-tree", "HEAD" }, path);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "100644") != null);
}

// === Commit object tests ===

test "commit: git cat-file -t returns 'commit'" {
    const path = tmpPath("commit_type");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "content");
    try repo.add("f.txt");
    const hash = try repo.commit("init", "Test", "t@t.com");

    const type_out = try runGit(&.{ "git", "cat-file", "-t", &hash }, path);
    defer testing.allocator.free(type_out);
    try testing.expectEqualStrings("commit", std.mem.trim(u8, type_out, " \n\r\t"));
}

test "commit: commit message preserved" {
    const path = tmpPath("commit_msg");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "content");
    try repo.add("f.txt");
    const hash = try repo.commit("My special commit message", "Test", "t@t.com");

    const out = try runGit(&.{ "git", "cat-file", "-p", &hash }, path);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "My special commit message") != null);
}

test "commit: author name and email in commit object" {
    const path = tmpPath("commit_author");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "content");
    try repo.add("f.txt");
    const hash = try repo.commit("init", "Alice Smith", "alice@example.com");

    const out = try runGit(&.{ "git", "cat-file", "-p", &hash }, path);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "Alice Smith") != null);
    try testing.expect(std.mem.indexOf(u8, out, "alice@example.com") != null);
}

test "commit: second commit has parent" {
    const path = tmpPath("commit_parent");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "a.txt", "aaa");
    try repo.add("a.txt");
    const hash1 = try repo.commit("first", "Test", "t@t.com");

    try createFile(path, "b.txt", "bbb");
    try repo.add("b.txt");
    const hash2 = try repo.commit("second", "Test", "t@t.com");

    // Check second commit has parent pointing to first
    const out = try runGit(&.{ "git", "cat-file", "-p", &hash2 }, path);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "parent") != null);
    try testing.expect(std.mem.indexOf(u8, out, &hash1) != null);
}

test "commit: first commit has no parent" {
    const path = tmpPath("commit_no_parent");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "content");
    try repo.add("f.txt");
    const hash = try repo.commit("first", "Test", "t@t.com");

    const out = try runGit(&.{ "git", "cat-file", "-p", &hash }, path);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "parent") == null);
}

// === Tag object tests ===

test "tag: lightweight tag points to correct commit" {
    const path = tmpPath("tag_lightweight");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "content");
    try repo.add("f.txt");
    const commit_hash = try repo.commit("init", "Test", "t@t.com");

    try repo.createTag("v1.0.0", null);

    const tag_out = try runGit(&.{ "git", "rev-parse", "v1.0.0" }, path);
    defer testing.allocator.free(tag_out);
    const tag_hash = std.mem.trim(u8, tag_out, " \n\r\t");

    try testing.expectEqualStrings(&commit_hash, tag_hash);
}

test "tag: annotated tag readable by git" {
    const path = tmpPath("tag_annotated");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "content");
    try repo.add("f.txt");
    _ = try repo.commit("init", "Test", "t@t.com");

    try repo.createTag("v2.0.0", "Release v2.0.0");

    // git tag -l should show it
    const tag_list = try runGit(&.{ "git", "tag", "-l" }, path);
    defer testing.allocator.free(tag_list);
    try testing.expect(std.mem.indexOf(u8, tag_list, "v2.0.0") != null);

    // git cat-file -t on the tag object should be "tag"
    const tag_hash_out = try runGit(&.{ "git", "rev-parse", "v2.0.0" }, path);
    defer testing.allocator.free(tag_hash_out);
    const tag_hash = std.mem.trim(u8, tag_hash_out, " \n\r\t");

    const type_out = try runGit(&.{ "git", "cat-file", "-t", tag_hash }, path);
    defer testing.allocator.free(type_out);
    try testing.expectEqualStrings("tag", std.mem.trim(u8, type_out, " \n\r\t"));
}

test "tag: annotated tag contains message" {
    const path = tmpPath("tag_ann_msg");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "content");
    try repo.add("f.txt");
    _ = try repo.commit("init", "Test", "t@t.com");

    try repo.createTag("v3.0.0", "This is the v3 release");

    const tag_hash_out = try runGit(&.{ "git", "rev-parse", "v3.0.0" }, path);
    defer testing.allocator.free(tag_hash_out);
    const tag_hash = std.mem.trim(u8, tag_hash_out, " \n\r\t");

    const obj_out = try runGit(&.{ "git", "cat-file", "-p", tag_hash }, path);
    defer testing.allocator.free(obj_out);

    try testing.expect(std.mem.indexOf(u8, obj_out, "This is the v3 release") != null);
    try testing.expect(std.mem.indexOf(u8, obj_out, "tag v3.0.0") != null);
}

// === Git creates, ziggit reads ===

test "git-created commit readable by ziggit revParseHead" {
    const path = tmpPath("git_to_ziggit");
    cleanup(path);
    defer cleanup(path);

    // Create repo with git
    try runGitNoCheck(&.{ "git", "init", "-q", path }, "/tmp");
    try runGitNoCheck(&.{ "git", "config", "user.email", "t@t.com" }, path);
    try runGitNoCheck(&.{ "git", "config", "user.name", "Test" }, path);
    try createFile(path, "f.txt", "git content");
    try runGitNoCheck(&.{ "git", "add", "f.txt" }, path);
    try runGitNoCheck(&.{ "git", "commit", "-q", "-m", "git commit" }, path);

    // Read with ziggit
    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    const head = try repo.revParseHead();
    // Should be valid 40-char hex
    try testing.expectEqual(@as(usize, 40), head.len);
    for (head) |c| {
        try testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }

    // Should match git rev-parse
    const git_head = try runGit(&.{ "git", "rev-parse", "HEAD" }, path);
    defer testing.allocator.free(git_head);
    try testing.expectEqualStrings(&head, std.mem.trim(u8, git_head, " \n\r\t"));
}

test "git-created tags visible to ziggit describeTags" {
    const path = tmpPath("git_tags_to_ziggit");
    cleanup(path);
    defer cleanup(path);

    // Create repo with git
    try runGitNoCheck(&.{ "git", "init", "-q", path }, "/tmp");
    try runGitNoCheck(&.{ "git", "config", "user.email", "t@t.com" }, path);
    try runGitNoCheck(&.{ "git", "config", "user.name", "Test" }, path);
    try createFile(path, "f.txt", "content");
    try runGitNoCheck(&.{ "git", "add", "f.txt" }, path);
    try runGitNoCheck(&.{ "git", "commit", "-q", "-m", "init" }, path);
    try runGitNoCheck(&.{ "git", "tag", "v5.0.0" }, path);

    // Read with ziggit
    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    const tag = try repo.describeTags(testing.allocator);
    defer testing.allocator.free(tag);
    try testing.expectEqualStrings("v5.0.0", tag);
}

test "git-created branches visible to ziggit branchList" {
    const path = tmpPath("git_branches_to_ziggit");
    cleanup(path);
    defer cleanup(path);

    // Create repo with git + extra branch
    try runGitNoCheck(&.{ "git", "init", "-q", path }, "/tmp");
    try runGitNoCheck(&.{ "git", "config", "user.email", "t@t.com" }, path);
    try runGitNoCheck(&.{ "git", "config", "user.name", "Test" }, path);
    try createFile(path, "f.txt", "content");
    try runGitNoCheck(&.{ "git", "add", "f.txt" }, path);
    try runGitNoCheck(&.{ "git", "commit", "-q", "-m", "init" }, path);
    try runGitNoCheck(&.{ "git", "branch", "feature" }, path);

    // Read with ziggit
    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    const branches = try repo.branchList(testing.allocator);
    defer {
        for (branches) |b| testing.allocator.free(b);
        testing.allocator.free(branches);
    }

    try testing.expect(branches.len >= 2);
    var found_master = false;
    var found_feature = false;
    for (branches) |b| {
        if (std.mem.eql(u8, b, "master")) found_master = true;
        if (std.mem.eql(u8, b, "feature")) found_feature = true;
    }
    // git init may use 'main' or 'master'
    try testing.expect(found_master or found_feature);
    try testing.expect(found_feature);
}

// === Interleaved operations ===

test "alternating git and ziggit commits maintain valid chain" {
    const path = tmpPath("interleave");
    cleanup(path);
    defer cleanup(path);

    // Init with ziggit
    var repo = try Repository.init(testing.allocator, path);

    // First commit with ziggit
    try createFile(path, "a.txt", "ziggit1");
    try repo.add("a.txt");
    const z1 = try repo.commit("ziggit commit 1", "Test", "t@t.com");

    // Close and do git commit
    repo.close();

    try runGitNoCheck(&.{ "git", "config", "user.email", "t@t.com" }, path);
    try runGitNoCheck(&.{ "git", "config", "user.name", "Test" }, path);
    try createFile(path, "b.txt", "git1");
    try runGitNoCheck(&.{ "git", "add", "b.txt" }, path);
    try runGitNoCheck(&.{ "git", "commit", "-q", "-m", "git commit 1" }, path);

    // Reopen with ziggit
    repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    // Verify HEAD changed (git commit should have advanced it)
    const current_head = try repo.revParseHead();
    try testing.expect(!std.mem.eql(u8, &z1, &current_head));

    // Verify fsck passes
    const fsck_out = try runGit(&.{ "git", "fsck", "--full" }, path);
    defer testing.allocator.free(fsck_out);
}
