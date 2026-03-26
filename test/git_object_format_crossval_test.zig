// Test: git object format cross-validation
// Verifies that ziggit-created objects are byte-for-byte compatible with git
const std = @import("std");
const testing = std.testing;
const ziggit = @import("ziggit");
const Repository = ziggit.Repository;

fn uniqueTmp(comptime suffix: []const u8) []const u8 {
    return "/tmp/ziggit_objfmt_" ++ suffix;
}

fn cleanup(path: []const u8) void {
    std.fs.deleteTreeAbsolute(path) catch {};
}

fn writeFile(repo_path: []const u8, name: []const u8, content: []const u8) !void {
    const full = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ repo_path, name });
    defer testing.allocator.free(full);
    const f = try std.fs.createFileAbsolute(full, .{ .truncate = true });
    defer f.close();
    try f.writeAll(content);
}

fn runGit(args: []const []const u8, cwd: []const u8) ![]u8 {
    var child = std.process.Child.init(args, testing.allocator);
    child.cwd = .{ .path = cwd };
    child.stdout_behavior = .pipe;
    child.stderr_behavior = .pipe;
    try child.spawn();
    const result = try child.wait();
    const stdout = try result.stdout.reader().readAllAlloc(testing.allocator, 64 * 1024);
    if (result.term.Exited != 0) {
        testing.allocator.free(stdout);
        return error.GitCommandFailed;
    }
    return stdout;
}

fn exec(args: []const []const u8, cwd: []const u8) ![]u8 {
    const result = try std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = args,
        .cwd = cwd,
    });
    defer testing.allocator.free(result.stderr);
    if (result.term.Exited != 0) {
        testing.allocator.free(result.stdout);
        return error.CommandFailed;
    }
    return result.stdout;
}

// ============================================================================
// 1. Blob hash matches git hash-object
// ============================================================================

test "blob SHA-1 matches git hash-object" {
    const path = uniqueTmp("blob_sha1");
    cleanup(path);
    defer cleanup(path);

    // Create repo with git first
    _ = try exec(&.{ "git", "init", "-q", path }, "/tmp");
    _ = try exec(&.{ "git", "-C", path, "config", "user.email", "t@t.com" }, "/tmp");
    _ = try exec(&.{ "git", "-C", path, "config", "user.name", "T" }, "/tmp");

    // Write a file
    try writeFile(path, "hello.txt", "Hello, World!\n");

    // Get hash from git
    const git_hash_raw = try exec(&.{ "git", "-C", path, "hash-object", "hello.txt" }, path);
    defer testing.allocator.free(git_hash_raw);
    const git_hash = std.mem.trim(u8, git_hash_raw, " \n\r\t");

    // Add with ziggit
    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();
    try repo.add("hello.txt");

    // Verify the blob object exists at the expected path
    const obj_path = try std.fmt.allocPrint(testing.allocator, "{s}/objects/{s}/{s}", .{ repo.git_dir, git_hash[0..2], git_hash[2..] });
    defer testing.allocator.free(obj_path);
    try std.fs.accessAbsolute(obj_path, .{});
}

// ============================================================================
// 2. git fsck validates ziggit-created objects
// ============================================================================

test "git fsck validates ziggit commit" {
    const path = uniqueTmp("fsck");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);

    // Configure git identity
    _ = try exec(&.{ "git", "-C", path, "config", "user.email", "t@t.com" }, "/tmp");
    _ = try exec(&.{ "git", "-C", path, "config", "user.name", "T" }, "/tmp");

    try writeFile(path, "a.txt", "content A\n");
    try repo.add("a.txt");
    _ = try repo.commit("initial commit", "Test", "test@test.com");
    repo.close();

    // git fsck should validate without errors
    const result = try std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = &.{ "git", "-C", path, "fsck", "--no-dangling" },
        .cwd = path,
    });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    // fsck exits 0 if all objects are valid
    try testing.expectEqual(@as(u8, 0), result.term.Exited);
}

// ============================================================================
// 3. git cat-file can read ziggit blob
// ============================================================================

test "git cat-file reads ziggit blob" {
    const path = uniqueTmp("catfile_blob");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    _ = try exec(&.{ "git", "-C", path, "config", "user.email", "t@t.com" }, "/tmp");
    _ = try exec(&.{ "git", "-C", path, "config", "user.name", "T" }, "/tmp");

    const content = "This is test content\nWith multiple lines\n";
    try writeFile(path, "test.txt", content);
    try repo.add("test.txt");
    _ = try repo.commit("add test file", "Test", "test@test.com");
    repo.close();

    // Use git cat-file to read the blob via ls-tree
    const tree_out = try exec(&.{ "git", "-C", path, "ls-tree", "HEAD" }, "/tmp");
    defer testing.allocator.free(tree_out);

    // Parse blob hash from ls-tree output: "100644 blob <hash>\ttest.txt"
    const hash_start = std.mem.indexOf(u8, tree_out, "blob ").? + 5;
    const hash_end = hash_start + 40;
    const blob_hash = tree_out[hash_start..hash_end];

    const blob_content = try exec(&.{ "git", "-C", path, "cat-file", "-p", blob_hash }, "/tmp");
    defer testing.allocator.free(blob_content);

    try testing.expectEqualStrings(content, blob_content);
}

// ============================================================================
// 4. git log can parse ziggit commit
// ============================================================================

test "git log reads ziggit commit message" {
    const path = uniqueTmp("gitlog");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    _ = try exec(&.{ "git", "-C", path, "config", "user.email", "t@t.com" }, "/tmp");
    _ = try exec(&.{ "git", "-C", path, "config", "user.name", "T" }, "/tmp");

    try writeFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    const hash = try repo.commit("my test message", "Author Name", "author@example.com");
    repo.close();

    // git log should show the commit message
    const log_out = try exec(&.{ "git", "-C", path, "log", "--format=%s", "-1" }, "/tmp");
    defer testing.allocator.free(log_out);
    try testing.expectEqualStrings("my test message\n", log_out);

    // git log should show the author
    const author_out = try exec(&.{ "git", "-C", path, "log", "--format=%an <%ae>", "-1" }, "/tmp");
    defer testing.allocator.free(author_out);
    try testing.expectEqualStrings("Author Name <author@example.com>\n", author_out);

    // git rev-parse HEAD should match ziggit's hash
    const rev_out = try exec(&.{ "git", "-C", path, "rev-parse", "HEAD" }, "/tmp");
    defer testing.allocator.free(rev_out);
    const git_hash = std.mem.trim(u8, rev_out, " \n\r\t");
    try testing.expectEqualStrings(&hash, git_hash);
}

// ============================================================================
// 5. Commit parent chain verified by git
// ============================================================================

test "git verifies parent chain across commits" {
    const path = uniqueTmp("parent_chain");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    _ = try exec(&.{ "git", "-C", path, "config", "user.email", "t@t.com" }, "/tmp");
    _ = try exec(&.{ "git", "-C", path, "config", "user.name", "T" }, "/tmp");

    try writeFile(path, "a.txt", "v1\n");
    try repo.add("a.txt");
    const hash1 = try repo.commit("first", "T", "t@t.com");

    try writeFile(path, "b.txt", "v2\n");
    try repo.add("b.txt");
    const hash2 = try repo.commit("second", "T", "t@t.com");

    try writeFile(path, "c.txt", "v3\n");
    try repo.add("c.txt");
    _ = try repo.commit("third", "T", "t@t.com");
    repo.close();

    // Verify parent of second commit is first commit
    const parent_out = try exec(&.{ "git", "-C", path, "log", "--format=%H %P", "--reverse" }, "/tmp");
    defer testing.allocator.free(parent_out);

    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, parent_out, "\n"), '\n');

    // First commit has no parent
    const line1 = lines.next().?;
    try testing.expectEqualStrings(&hash1, line1[0..40]);
    try testing.expect(line1.len == 40); // no parent

    // Second commit's parent is first
    const line2 = lines.next().?;
    try testing.expectEqualStrings(&hash2, line2[0..40]);
    try testing.expectEqualStrings(&hash1, line2[41..81]);
}

// ============================================================================
// 6. Tag creation verified by git
// ============================================================================

test "git reads ziggit lightweight tag" {
    const path = uniqueTmp("tag_light");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    _ = try exec(&.{ "git", "-C", path, "config", "user.email", "t@t.com" }, "/tmp");
    _ = try exec(&.{ "git", "-C", path, "config", "user.name", "T" }, "/tmp");

    try writeFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    const commit_hash = try repo.commit("initial", "T", "t@t.com");
    try repo.createTag("v1.0.0", null);
    repo.close();

    // git tag should list it
    const tags_out = try exec(&.{ "git", "-C", path, "tag" }, "/tmp");
    defer testing.allocator.free(tags_out);
    try testing.expectEqualStrings("v1.0.0\n", tags_out);

    // git rev-parse tag should resolve to commit hash
    const tag_hash_out = try exec(&.{ "git", "-C", path, "rev-parse", "v1.0.0" }, "/tmp");
    defer testing.allocator.free(tag_hash_out);
    const tag_hash = std.mem.trim(u8, tag_hash_out, " \n\r\t");
    try testing.expectEqualStrings(&commit_hash, tag_hash);
}

// ============================================================================
// 7. git reads ziggit annotated tag
// ============================================================================

test "git reads ziggit annotated tag" {
    const path = uniqueTmp("tag_ann");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    _ = try exec(&.{ "git", "-C", path, "config", "user.email", "t@t.com" }, "/tmp");
    _ = try exec(&.{ "git", "-C", path, "config", "user.name", "T" }, "/tmp");

    try writeFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    _ = try repo.commit("initial", "T", "t@t.com");
    try repo.createTag("v2.0.0", "Release version 2");
    repo.close();

    // git cat-file should show tag object type
    const type_out = try exec(&.{ "git", "-C", path, "cat-file", "-t", "v2.0.0" }, "/tmp");
    defer testing.allocator.free(type_out);
    try testing.expectEqualStrings("tag\n", type_out);

    // git tag -v should show the message (without GPG)
    const tag_content = try exec(&.{ "git", "-C", path, "cat-file", "-p", "v2.0.0" }, "/tmp");
    defer testing.allocator.free(tag_content);
    try testing.expect(std.mem.indexOf(u8, tag_content, "Release version 2") != null);
    try testing.expect(std.mem.indexOf(u8, tag_content, "tag v2.0.0") != null);
}

// ============================================================================
// 8. Binary file round-trip
// ============================================================================

test "binary file preserved through add-commit-catfile" {
    const path = uniqueTmp("binary");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    _ = try exec(&.{ "git", "-C", path, "config", "user.email", "t@t.com" }, "/tmp");
    _ = try exec(&.{ "git", "-C", path, "config", "user.name", "T" }, "/tmp");

    // Create binary content with null bytes and all byte values
    var binary_content: [256]u8 = undefined;
    for (&binary_content, 0..) |*b, i| {
        b.* = @intCast(i);
    }

    const full_path = try std.fmt.allocPrint(testing.allocator, "{s}/binary.bin", .{path});
    defer testing.allocator.free(full_path);
    {
        const f = try std.fs.createFileAbsolute(full_path, .{ .truncate = true });
        defer f.close();
        try f.writeAll(&binary_content);
    }

    try repo.add("binary.bin");
    _ = try repo.commit("add binary", "T", "t@t.com");
    repo.close();

    // Read back via git cat-file
    const tree_out = try exec(&.{ "git", "-C", path, "ls-tree", "HEAD" }, "/tmp");
    defer testing.allocator.free(tree_out);
    const hash_start = std.mem.indexOf(u8, tree_out, "blob ").? + 5;
    const blob_hash = tree_out[hash_start .. hash_start + 40];

    // Use cat-file to get binary content
    const result = try std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = &.{ "git", "-C", path, "cat-file", "blob", blob_hash },
        .cwd = path,
        .max_output_bytes = 1024,
    });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    try testing.expectEqualSlices(u8, &binary_content, result.stdout);
}

// ============================================================================
// 9. Empty file
// ============================================================================

test "empty file has correct blob hash" {
    const path = uniqueTmp("empty_file");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    _ = try exec(&.{ "git", "-C", path, "config", "user.email", "t@t.com" }, "/tmp");
    _ = try exec(&.{ "git", "-C", path, "config", "user.name", "T" }, "/tmp");

    try writeFile(path, "empty.txt", "");
    try repo.add("empty.txt");
    _ = try repo.commit("empty file", "T", "t@t.com");
    repo.close();

    // The well-known SHA-1 for an empty blob is e69de29bb2d1d6434b8b29ae775ad8c2e48c5391
    const hash_out = try exec(&.{ "git", "-C", path, "hash-object", "empty.txt" }, path);
    defer testing.allocator.free(hash_out);
    try testing.expectEqualStrings("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391\n", hash_out);

    // git fsck should pass
    const fsck = try std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = &.{ "git", "-C", path, "fsck", "--no-dangling" },
        .cwd = path,
    });
    defer testing.allocator.free(fsck.stdout);
    defer testing.allocator.free(fsck.stderr);
    try testing.expectEqual(@as(u8, 0), fsck.term.Exited);
}

// ============================================================================
// 10. revParseHead matches git rev-parse HEAD
// ============================================================================

test "revParseHead matches git after multiple commits" {
    const path = uniqueTmp("revparse_multi");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    _ = try exec(&.{ "git", "-C", path, "config", "user.email", "t@t.com" }, "/tmp");
    _ = try exec(&.{ "git", "-C", path, "config", "user.name", "T" }, "/tmp");

    // Make 3 commits
    for (0..3) |i| {
        const name = try std.fmt.allocPrint(testing.allocator, "file{d}.txt", .{i});
        defer testing.allocator.free(name);
        const content = try std.fmt.allocPrint(testing.allocator, "content {d}\n", .{i});
        defer testing.allocator.free(content);
        try writeFile(path, name, content);
        try repo.add(name);
        const msg = try std.fmt.allocPrint(testing.allocator, "commit {d}", .{i});
        defer testing.allocator.free(msg);
        _ = try repo.commit(msg, "T", "t@t.com");
    }

    const ziggit_head = try repo.revParseHead();
    repo.close();

    const git_out = try exec(&.{ "git", "-C", path, "rev-parse", "HEAD" }, "/tmp");
    defer testing.allocator.free(git_out);
    const git_head = std.mem.trim(u8, git_out, " \n\r\t");

    try testing.expectEqualStrings(&ziggit_head, git_head);
}

// ============================================================================
// 11. branchList returns correct branches
// ============================================================================

test "branchList after init returns master" {
    const path = uniqueTmp("branches");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    _ = try exec(&.{ "git", "-C", path, "config", "user.email", "t@t.com" }, "/tmp");
    _ = try exec(&.{ "git", "-C", path, "config", "user.name", "T" }, "/tmp");

    try writeFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    _ = try repo.commit("initial", "T", "t@t.com");

    const branches = try repo.branchList(testing.allocator);
    defer {
        for (branches) |b| testing.allocator.free(b);
        testing.allocator.free(branches);
    }

    try testing.expectEqual(@as(usize, 1), branches.len);
    try testing.expectEqualStrings("master", branches[0]);

    repo.close();
}

// ============================================================================
// 12. describeTags returns latest tag lexicographically
// ============================================================================

test "describeTags returns latest tag" {
    const path = uniqueTmp("describe_tags");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    _ = try exec(&.{ "git", "-C", path, "config", "user.email", "t@t.com" }, "/tmp");
    _ = try exec(&.{ "git", "-C", path, "config", "user.name", "T" }, "/tmp");

    try writeFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    _ = try repo.commit("initial", "T", "t@t.com");

    // Create tags in non-sorted order
    try repo.createTag("v1.0.0", null);
    try repo.createTag("v2.0.0", null);
    try repo.createTag("v1.5.0", null);

    const latest = try repo.describeTags(testing.allocator);
    defer testing.allocator.free(latest);
    try testing.expectEqualStrings("v2.0.0", latest);

    repo.close();
}

// ============================================================================
// 13. findCommit resolves HEAD, full hash, and tag name
// ============================================================================

test "findCommit resolves various committish forms" {
    const path = uniqueTmp("findcommit");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    _ = try exec(&.{ "git", "-C", path, "config", "user.email", "t@t.com" }, "/tmp");
    _ = try exec(&.{ "git", "-C", path, "config", "user.name", "T" }, "/tmp");

    try writeFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    const commit_hash = try repo.commit("initial", "T", "t@t.com");
    try repo.createTag("v1.0.0", null);

    // Resolve HEAD
    const head_result = try repo.findCommit("HEAD");
    try testing.expectEqualStrings(&commit_hash, &head_result);

    // Resolve full hash
    const hash_result = try repo.findCommit(&commit_hash);
    try testing.expectEqualStrings(&commit_hash, &hash_result);

    // Resolve tag name
    const tag_result = try repo.findCommit("v1.0.0");
    try testing.expectEqualStrings(&commit_hash, &tag_result);

    // Resolve branch name
    const branch_result = try repo.findCommit("master");
    try testing.expectEqualStrings(&commit_hash, &branch_result);

    // Resolve short hash (first 7 chars)
    const short_result = try repo.findCommit(commit_hash[0..7]);
    try testing.expectEqualStrings(&commit_hash, &short_result);

    repo.close();
}

// ============================================================================
// 14. git show reads ziggit tree correctly
// ============================================================================

test "git show-tree lists all ziggit-added files" {
    const path = uniqueTmp("show_tree");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    _ = try exec(&.{ "git", "-C", path, "config", "user.email", "t@t.com" }, "/tmp");
    _ = try exec(&.{ "git", "-C", path, "config", "user.name", "T" }, "/tmp");

    try writeFile(path, "a.txt", "aaa\n");
    try writeFile(path, "b.txt", "bbb\n");
    try writeFile(path, "c.txt", "ccc\n");
    try repo.add("a.txt");
    try repo.add("b.txt");
    try repo.add("c.txt");
    _ = try repo.commit("three files", "T", "t@t.com");
    repo.close();

    const tree_out = try exec(&.{ "git", "-C", path, "ls-tree", "--name-only", "HEAD" }, "/tmp");
    defer testing.allocator.free(tree_out);

    // All three files should be listed
    try testing.expect(std.mem.indexOf(u8, tree_out, "a.txt") != null);
    try testing.expect(std.mem.indexOf(u8, tree_out, "b.txt") != null);
    try testing.expect(std.mem.indexOf(u8, tree_out, "c.txt") != null);
}

// ============================================================================
// 15. Local clone produces valid repository
// ============================================================================

test "cloneBare local produces git-fsck-valid clone" {
    const src = uniqueTmp("clone_src");
    const dst = uniqueTmp("clone_dst");
    cleanup(src);
    cleanup(dst);
    defer cleanup(src);
    defer cleanup(dst);

    // Create source repo
    var src_repo = try Repository.init(testing.allocator, src);
    _ = try exec(&.{ "git", "-C", src, "config", "user.email", "t@t.com" }, "/tmp");
    _ = try exec(&.{ "git", "-C", src, "config", "user.name", "T" }, "/tmp");

    try writeFile(src, "f.txt", "source content\n");
    try src_repo.add("f.txt");
    const src_hash = try src_repo.commit("initial", "T", "t@t.com");
    src_repo.close();

    // Clone bare
    var dst_repo = try Repository.cloneBare(testing.allocator, src, dst);
    defer dst_repo.close();

    // Verify HEAD matches
    const dst_head = try dst_repo.revParseHead();
    try testing.expectEqualStrings(&src_hash, &dst_head);

    // git fsck on the clone
    const fsck = try std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = &.{ "git", "-C", dst, "fsck", "--no-dangling" },
        .cwd = dst,
    });
    defer testing.allocator.free(fsck.stdout);
    defer testing.allocator.free(fsck.stderr);
    try testing.expectEqual(@as(u8, 0), fsck.term.Exited);
}

// ============================================================================
// 16. git-created repo readable by ziggit
// ============================================================================

test "ziggit reads git-created repo correctly" {
    const path = uniqueTmp("git_created");
    cleanup(path);
    defer cleanup(path);

    // Create repo entirely with git
    _ = try exec(&.{ "git", "init", "-q", path }, "/tmp");
    _ = try exec(&.{ "git", "-C", path, "config", "user.email", "t@t.com" }, "/tmp");
    _ = try exec(&.{ "git", "-C", path, "config", "user.name", "T" }, "/tmp");
    try writeFile(path, "test.txt", "git content\n");
    _ = try exec(&.{ "git", "-C", path, "add", "test.txt" }, "/tmp");
    _ = try exec(&.{ "git", "-C", path, "commit", "-q", "-m", "git commit" }, "/tmp");
    _ = try exec(&.{ "git", "-C", path, "tag", "v1.0.0" }, "/tmp");

    // Read with ziggit
    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    // revParseHead
    const ziggit_head = try repo.revParseHead();
    const git_head_out = try exec(&.{ "git", "-C", path, "rev-parse", "HEAD" }, "/tmp");
    defer testing.allocator.free(git_head_out);
    try testing.expectEqualStrings(&ziggit_head, std.mem.trim(u8, git_head_out, " \n\r\t"));

    // findCommit
    const found = try repo.findCommit("v1.0.0");
    try testing.expectEqualStrings(&ziggit_head, &found);

    // branchList
    const branches = try repo.branchList(testing.allocator);
    defer {
        for (branches) |b| testing.allocator.free(b);
        testing.allocator.free(branches);
    }
    try testing.expect(branches.len >= 1);

    // describeTags
    const tag = try repo.describeTags(testing.allocator);
    defer testing.allocator.free(tag);
    try testing.expectEqualStrings("v1.0.0", tag);
}

// ============================================================================
// 17. Overwrite file creates new blob
// ============================================================================

test "overwriting file creates new commit with different tree" {
    const path = uniqueTmp("overwrite");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    _ = try exec(&.{ "git", "-C", path, "config", "user.email", "t@t.com" }, "/tmp");
    _ = try exec(&.{ "git", "-C", path, "config", "user.name", "T" }, "/tmp");

    try writeFile(path, "f.txt", "version 1\n");
    try repo.add("f.txt");
    const hash1 = try repo.commit("v1", "T", "t@t.com");

    try writeFile(path, "f.txt", "version 2\n");
    try repo.add("f.txt");
    const hash2 = try repo.commit("v2", "T", "t@t.com");
    repo.close();

    // Commits should be different
    try testing.expect(!std.mem.eql(u8, &hash1, &hash2));

    // Git should see the latest content
    const show_out = try exec(&.{ "git", "-C", path, "show", "HEAD:f.txt" }, "/tmp");
    defer testing.allocator.free(show_out);
    try testing.expectEqualStrings("version 2\n", show_out);

    // Git should also see the old content in the first commit
    const show_old = try exec(&.{ "git", "-C", path, "show", &hash1 ++ ":f.txt" }, "/tmp");
    defer testing.allocator.free(show_old);
    try testing.expectEqualStrings("version 1\n", show_old);
}

// ============================================================================
// 18. Large file (64KB+)
// ============================================================================

test "large file round-trips correctly" {
    const path = uniqueTmp("large_file");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    _ = try exec(&.{ "git", "-C", path, "config", "user.email", "t@t.com" }, "/tmp");
    _ = try exec(&.{ "git", "-C", path, "config", "user.name", "T" }, "/tmp");

    // Create 64KB file with known pattern
    const large_content = try testing.allocator.alloc(u8, 65536);
    defer testing.allocator.free(large_content);
    for (large_content, 0..) |*b, i| {
        b.* = @intCast(i % 256);
    }

    const full_path = try std.fmt.allocPrint(testing.allocator, "{s}/large.bin", .{path});
    defer testing.allocator.free(full_path);
    {
        const f = try std.fs.createFileAbsolute(full_path, .{ .truncate = true });
        defer f.close();
        try f.writeAll(large_content);
    }

    try repo.add("large.bin");
    _ = try repo.commit("add large file", "T", "t@t.com");
    repo.close();

    // Verify with git
    const fsck = try std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = &.{ "git", "-C", path, "fsck", "--no-dangling" },
        .cwd = path,
    });
    defer testing.allocator.free(fsck.stdout);
    defer testing.allocator.free(fsck.stderr);
    try testing.expectEqual(@as(u8, 0), fsck.term.Exited);

    // Verify content matches
    const tree_out = try exec(&.{ "git", "-C", path, "ls-tree", "HEAD" }, "/tmp");
    defer testing.allocator.free(tree_out);
    const hash_start = std.mem.indexOf(u8, tree_out, "blob ").? + 5;
    const blob_hash = tree_out[hash_start .. hash_start + 40];

    const result = try std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = &.{ "git", "-C", path, "cat-file", "blob", blob_hash },
        .cwd = path,
        .max_output_bytes = 128 * 1024,
    });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    try testing.expectEqualSlices(u8, large_content, result.stdout);
}
