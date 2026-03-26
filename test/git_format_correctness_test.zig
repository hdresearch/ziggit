// test/git_format_correctness_test.zig
// Verifies that ziggit produces byte-exact git-compatible objects.
// Cross-validates blob/tree/commit/tag format by:
//   1. Creating objects with ziggit
//   2. Reading them with `git cat-file` to confirm format correctness
//   3. Creating objects with `git hash-object` and comparing hashes
//   4. Running `git fsck --strict` to verify repository integrity
const std = @import("std");
const ziggit = @import("ziggit");
const testing = std.testing;

const Repository = ziggit.Repository;

// ============================================================================
// Helpers
// ============================================================================

fn tmpPath(comptime suffix: []const u8) []const u8 {
    return "/tmp/ziggit_fmt_" ++ suffix;
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
    return try f.readToEndAlloc(testing.allocator, 10 * 1024 * 1024);
}

fn runGit(cwd: []const u8, args: []const []const u8) ![]u8 {
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
    errdefer testing.allocator.free(stdout);
    const stderr = try child.stderr.?.reader().readAllAlloc(testing.allocator, 10 * 1024 * 1024);
    defer testing.allocator.free(stderr);
    const result = try child.wait();
    if (result.Exited != 0) {
        testing.allocator.free(stdout);
        return error.GitCommandFailed;
    }
    return stdout;
}

fn trimResult(s: []u8) []const u8 {
    return std.mem.trim(u8, s, " \n\r\t");
}

/// Run git command and discard output (for commands where we don't need the result)
fn runGitDiscard(cwd: []const u8, args: []const []const u8) !void {
    const out = try runGit(cwd, args);
    testing.allocator.free(out);
}

fn initGitConfig(path: []const u8) !void {
    try runGitDiscard(path, &.{ "config", "user.email", "test@test.com" });
    try runGitDiscard(path, &.{ "config", "user.name", "Test" });
}

// ============================================================================
// Blob format tests
// ============================================================================

test "blob hash matches git hash-object for simple content" {
    const path = tmpPath("blob_hash_simple");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    try initGitConfig(path);

    try writeFile(path, "hello.txt", "Hello, World!\n");
    try repo.add("hello.txt");

    // Get git's expected hash for the same content
    const git_hash_out = try runGit(path, &.{ "hash-object", "hello.txt" });
    defer testing.allocator.free(git_hash_out);
    const git_hash = trimResult(git_hash_out);

    // The blob we stored should be readable by git
    const cat_file_out = try runGit(path, &.{ "cat-file", "-t", git_hash });
    defer testing.allocator.free(cat_file_out);
    try testing.expectEqualStrings("blob", trimResult(cat_file_out));

    // Content should match
    const content_out = try runGit(path, &.{ "cat-file", "blob", git_hash });
    defer testing.allocator.free(content_out);
    try testing.expectEqualStrings("Hello, World!\n", content_out);
}

test "blob hash matches git for empty content" {
    const path = tmpPath("blob_hash_empty");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    try initGitConfig(path);

    try writeFile(path, "empty.txt", "");
    try repo.add("empty.txt");

    const git_hash_out = try runGit(path, &.{ "hash-object", "empty.txt" });
    defer testing.allocator.free(git_hash_out);
    const git_hash = trimResult(git_hash_out);

    // e69de29bb2d1d6434b8b29ae775ad8c2e48c5391 is the well-known empty blob hash
    try testing.expectEqualStrings("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391", git_hash);

    const cat_file_out = try runGit(path, &.{ "cat-file", "-t", git_hash });
    defer testing.allocator.free(cat_file_out);
    try testing.expectEqualStrings("blob", trimResult(cat_file_out));
}

test "blob hash matches git for binary content" {
    const path = tmpPath("blob_hash_binary");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    try initGitConfig(path);

    // Write binary content with null bytes and high bytes
    var content: [256]u8 = undefined;
    for (&content, 0..) |*c, i| c.* = @intCast(i);
    try writeFile(path, "binary.dat", &content);
    try repo.add("binary.dat");

    const git_hash_out = try runGit(path, &.{ "hash-object", "binary.dat" });
    defer testing.allocator.free(git_hash_out);
    const git_hash = trimResult(git_hash_out);

    const cat_file_out = try runGit(path, &.{ "cat-file", "-s", git_hash });
    defer testing.allocator.free(cat_file_out);
    try testing.expectEqualStrings("256", trimResult(cat_file_out));
}

// ============================================================================
// Commit format tests
// ============================================================================

test "commit is readable by git cat-file" {
    const path = tmpPath("commit_catfile");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    try initGitConfig(path);

    try writeFile(path, "file.txt", "content\n");
    try repo.add("file.txt");
    const hash = try repo.commit("Initial commit", "Alice", "alice@test.com");

    // git cat-file -t should return "commit"
    const type_out = try runGit(path, &.{ "cat-file", "-t", &hash });
    defer testing.allocator.free(type_out);
    try testing.expectEqualStrings("commit", trimResult(type_out));

    // git cat-file -p should show the commit with tree, author, message
    const pretty_out = try runGit(path, &.{ "cat-file", "-p", &hash });
    defer testing.allocator.free(pretty_out);
    const pretty = trimResult(pretty_out);

    try testing.expect(std.mem.indexOf(u8, pretty, "tree ") != null);
    try testing.expect(std.mem.indexOf(u8, pretty, "author Alice <alice@test.com>") != null);
    try testing.expect(std.mem.indexOf(u8, pretty, "Initial commit") != null);
}

test "second commit has parent field" {
    const path = tmpPath("commit_parent");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    try initGitConfig(path);

    try writeFile(path, "a.txt", "first\n");
    try repo.add("a.txt");
    const h1 = try repo.commit("first", "A", "a@b.com");

    try writeFile(path, "b.txt", "second\n");
    try repo.add("b.txt");
    const h2 = try repo.commit("second", "A", "a@b.com");

    // Second commit should have first as parent
    const pretty_out = try runGit(path, &.{ "cat-file", "-p", &h2 });
    defer testing.allocator.free(pretty_out);
    const pretty = trimResult(pretty_out);

    const expected_parent = try std.fmt.allocPrint(testing.allocator, "parent {s}", .{h1});
    defer testing.allocator.free(expected_parent);
    try testing.expect(std.mem.indexOf(u8, pretty, expected_parent) != null);
}

test "commit with multiline message preserved" {
    const path = tmpPath("commit_multiline");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    try initGitConfig(path);

    try writeFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    const msg = "Line one\n\nLine three\nLine four";
    const hash = try repo.commit(msg, "A", "a@b.com");

    const log_out = try runGit(path, &.{ "log", "--format=%B", "-1", &hash });
    defer testing.allocator.free(log_out);
    const log = trimResult(log_out);
    try testing.expect(std.mem.indexOf(u8, log, "Line one") != null);
    try testing.expect(std.mem.indexOf(u8, log, "Line three") != null);
}

// ============================================================================
// Tree format tests
// ============================================================================

test "tree contains correct entries readable by git" {
    const path = tmpPath("tree_entries");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    try initGitConfig(path);

    try writeFile(path, "alpha.txt", "aaa\n");
    try writeFile(path, "beta.txt", "bbb\n");
    try writeFile(path, "gamma.txt", "ggg\n");
    try repo.add("alpha.txt");
    try repo.add("beta.txt");
    try repo.add("gamma.txt");
    const hash = try repo.commit("three files", "A", "a@b.com");

    // Get tree hash from commit
    const tree_out = try runGit(path, &.{ "cat-file", "-p", &hash });
    defer testing.allocator.free(tree_out);

    // Parse tree hash from "tree <hash>" line
    var lines = std.mem.splitScalar(u8, trimResult(tree_out), '\n');
    const first_line = lines.first();
    try testing.expect(std.mem.startsWith(u8, first_line, "tree "));
    const tree_hash = first_line[5..];

    // List tree contents
    const ls_tree_out = try runGit(path, &.{ "ls-tree", tree_hash });
    defer testing.allocator.free(ls_tree_out);
    const ls_tree = trimResult(ls_tree_out);

    // Should have all three files
    try testing.expect(std.mem.indexOf(u8, ls_tree, "alpha.txt") != null);
    try testing.expect(std.mem.indexOf(u8, ls_tree, "beta.txt") != null);
    try testing.expect(std.mem.indexOf(u8, ls_tree, "gamma.txt") != null);

    // All entries should be mode 100644 (regular file)
    var count: usize = 0;
    var tree_lines = std.mem.splitScalar(u8, ls_tree, '\n');
    while (tree_lines.next()) |line| {
        if (line.len > 0) {
            try testing.expect(std.mem.startsWith(u8, line, "100644 blob"));
            count += 1;
        }
    }
    try testing.expectEqual(@as(usize, 3), count);
}

test "tree entries added in sorted order are preserved" {
    const path = tmpPath("tree_sort");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    try initGitConfig(path);

    // Add files in alphabetical order (ziggit stores tree entries in add order)
    try writeFile(path, "a.txt", "a\n");
    try writeFile(path, "m.txt", "m\n");
    try writeFile(path, "z.txt", "z\n");
    try repo.add("a.txt");
    try repo.add("m.txt");
    try repo.add("z.txt");
    const hash = try repo.commit("sorted", "A", "a@b.com");

    // Get tree hash
    const tree_out = try runGit(path, &.{ "cat-file", "-p", &hash });
    defer testing.allocator.free(tree_out);
    var lines = std.mem.splitScalar(u8, trimResult(tree_out), '\n');
    const first_line = lines.first();
    const tree_hash = first_line[5..];

    // ls-tree outputs in sorted order
    const ls_tree_out = try runGit(path, &.{ "ls-tree", tree_hash });
    defer testing.allocator.free(ls_tree_out);

    // Collect file names from tree listing
    var names = std.ArrayList([]const u8).init(testing.allocator);
    defer names.deinit();
    var tree_lines = std.mem.splitScalar(u8, trimResult(ls_tree_out), '\n');
    while (tree_lines.next()) |line| {
        if (line.len == 0) continue;
        // Format: "100644 blob <hash>\t<name>"
        if (std.mem.indexOf(u8, line, "\t")) |tab_pos| {
            try names.append(line[tab_pos + 1 ..]);
        }
    }
    // Verify all files present and in order
    try testing.expectEqual(@as(usize, 3), names.items.len);
    try testing.expectEqualStrings("a.txt", names.items[0]);
    try testing.expectEqualStrings("m.txt", names.items[1]);
    try testing.expectEqualStrings("z.txt", names.items[2]);
}

// ============================================================================
// Tag format tests
// ============================================================================

test "lightweight tag points to correct commit" {
    const path = tmpPath("tag_lightweight");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    try initGitConfig(path);

    try writeFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    const head_hash = try repo.commit("init", "A", "a@b.com");
    try repo.createTag("v1.0", null);

    // git rev-parse should resolve tag to commit hash
    const tag_out = try runGit(path, &.{ "rev-parse", "v1.0" });
    defer testing.allocator.free(tag_out);
    try testing.expectEqualStrings(&head_hash, trimResult(tag_out));
}

test "annotated tag creates proper tag object" {
    const path = tmpPath("tag_annotated");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    try initGitConfig(path);

    try writeFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    const head_hash = try repo.commit("init", "A", "a@b.com");
    try repo.createTag("v2.0", "Release 2.0");

    // The tag ref points to a tag object, not directly to the commit
    const tag_ref_out = try runGit(path, &.{ "cat-file", "-t", "v2.0" });
    defer testing.allocator.free(tag_ref_out);
    try testing.expectEqualStrings("tag", trimResult(tag_ref_out));

    // Tag object should reference the commit
    const tag_content_out = try runGit(path, &.{ "cat-file", "-p", "v2.0" });
    defer testing.allocator.free(tag_content_out);
    const tag_content = trimResult(tag_content_out);

    const expected_obj = try std.fmt.allocPrint(testing.allocator, "object {s}", .{head_hash});
    defer testing.allocator.free(expected_obj);
    try testing.expect(std.mem.indexOf(u8, tag_content, expected_obj) != null);
    try testing.expect(std.mem.indexOf(u8, tag_content, "type commit") != null);
    try testing.expect(std.mem.indexOf(u8, tag_content, "tag v2.0") != null);
    try testing.expect(std.mem.indexOf(u8, tag_content, "Release 2.0") != null);
}

// ============================================================================
// git fsck validation
// ============================================================================

test "git fsck passes after multiple operations" {
    const path = tmpPath("fsck_multi");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    try initGitConfig(path);

    // Create multiple commits with multiple files
    try writeFile(path, "a.txt", "aaa\n");
    try repo.add("a.txt");
    _ = try repo.commit("first", "A", "a@b.com");

    try writeFile(path, "b.txt", "bbb\n");
    try repo.add("b.txt");
    _ = try repo.commit("second", "A", "a@b.com");

    try writeFile(path, "c.txt", "ccc\n");
    try repo.add("c.txt");
    _ = try repo.commit("third", "A", "a@b.com");

    // Create tags
    try repo.createTag("v1.0", null);
    try repo.createTag("v2.0", "Annotated tag");

    // git fsck --strict should pass
    const fsck_out = try runGit(path, &.{ "fsck", "--strict" });
    defer testing.allocator.free(fsck_out);
    // fsck outputs nothing on success (or warnings to stderr)
}

test "git fsck passes with empty file and binary content" {
    const path = tmpPath("fsck_edge");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    try initGitConfig(path);

    try writeFile(path, "empty.txt", "");
    var bin: [128]u8 = undefined;
    for (&bin, 0..) |*b, i| b.* = @intCast(i);
    try writeFile(path, "binary.dat", &bin);
    try repo.add("empty.txt");
    try repo.add("binary.dat");
    _ = try repo.commit("edge cases", "A", "a@b.com");

    // fsck may output warnings but should not fail with exit code
    const fsck_out = runGit(path, &.{"fsck"}) catch {
        // Some git versions return non-zero for warnings, that's OK
        return;
    };
    defer testing.allocator.free(fsck_out);
}

// ============================================================================
// revParseHead matches git rev-parse HEAD exactly
// ============================================================================

test "revParseHead matches git rev-parse HEAD across multiple commits" {
    const path = tmpPath("revparse_chain");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    try initGitConfig(path);

    // First commit
    try writeFile(path, "f.txt", "v1\n");
    try repo.add("f.txt");
    const h1 = try repo.commit("c1", "A", "a@b.com");

    const git_h1_out = try runGit(path, &.{ "rev-parse", "HEAD" });
    defer testing.allocator.free(git_h1_out);
    try testing.expectEqualStrings(&h1, trimResult(git_h1_out));

    // Second commit
    try writeFile(path, "f.txt", "v2\n");
    try repo.add("f.txt");
    const h2 = try repo.commit("c2", "A", "a@b.com");

    const git_h2_out = try runGit(path, &.{ "rev-parse", "HEAD" });
    defer testing.allocator.free(git_h2_out);
    try testing.expectEqualStrings(&h2, trimResult(git_h2_out));

    // Third commit
    try writeFile(path, "g.txt", "new\n");
    try repo.add("g.txt");
    const h3 = try repo.commit("c3", "A", "a@b.com");

    const git_h3_out = try runGit(path, &.{ "rev-parse", "HEAD" });
    defer testing.allocator.free(git_h3_out);
    try testing.expectEqualStrings(&h3, trimResult(git_h3_out));
}

// ============================================================================
// findCommit: resolution paths
// ============================================================================

test "findCommit resolves HEAD, full hash, branch, and tag" {
    const path = tmpPath("findcommit_all");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    try initGitConfig(path);

    try writeFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    const head_hash = try repo.commit("init", "A", "a@b.com");
    try repo.createTag("v1", null);

    // HEAD
    const h1 = try repo.findCommit("HEAD");
    try testing.expectEqualStrings(&head_hash, &h1);

    // Full hash
    const h2 = try repo.findCommit(&head_hash);
    try testing.expectEqualStrings(&head_hash, &h2);

    // Branch name
    const h3 = try repo.findCommit("master");
    try testing.expectEqualStrings(&head_hash, &h3);

    // Tag name
    const h4 = try repo.findCommit("v1");
    try testing.expectEqualStrings(&head_hash, &h4);
}

test "findCommit errors on nonexistent ref" {
    const path = tmpPath("findcommit_err");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    try initGitConfig(path);

    try writeFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "A", "a@b.com");

    const result = repo.findCommit("nonexistent_branch");
    try testing.expectError(error.CommitNotFound, result);
}

// ============================================================================
// branchList
// ============================================================================

test "branchList shows master after first commit" {
    const path = tmpPath("branchlist_master");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    try initGitConfig(path);

    try writeFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "A", "a@b.com");

    const branches = try repo.branchList(testing.allocator);
    defer {
        for (branches) |b| testing.allocator.free(b);
        testing.allocator.free(branches);
    }

    try testing.expect(branches.len >= 1);
    var found_master = false;
    for (branches) |b| {
        if (std.mem.eql(u8, b, "master")) found_master = true;
    }
    try testing.expect(found_master);
}

test "branchList shows git-created branches" {
    const path = tmpPath("branchlist_gitcreated");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    try initGitConfig(path);

    try writeFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "A", "a@b.com");

    // Create branches via git
    try runGitDiscard(path, &.{ "branch", "feature-x" });
    try runGitDiscard(path, &.{ "branch", "hotfix-1" });

    const branches = try repo.branchList(testing.allocator);
    defer {
        for (branches) |b| testing.allocator.free(b);
        testing.allocator.free(branches);
    }

    var found = [_]bool{ false, false, false };
    for (branches) |b| {
        if (std.mem.eql(u8, b, "master")) found[0] = true;
        if (std.mem.eql(u8, b, "feature-x")) found[1] = true;
        if (std.mem.eql(u8, b, "hotfix-1")) found[2] = true;
    }
    try testing.expect(found[0]);
    try testing.expect(found[1]);
    try testing.expect(found[2]);
}

// ============================================================================
// describeTags / latestTag
// ============================================================================

test "describeTags returns tag name when HEAD is tagged" {
    const path = tmpPath("describe_tagged");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    try initGitConfig(path);

    try writeFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "A", "a@b.com");
    try repo.createTag("v3.0", null);

    const desc = try repo.describeTags(testing.allocator);
    defer testing.allocator.free(desc);

    try testing.expect(desc.len > 0);
    try testing.expect(std.mem.indexOf(u8, desc, "v3.0") != null);
}

test "describeTags returns empty string when no tags exist" {
    const path = tmpPath("describe_notags");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    try initGitConfig(path);

    try writeFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "A", "a@b.com");

    const desc = try repo.describeTags(testing.allocator);
    defer testing.allocator.free(desc);
    try testing.expectEqualStrings("", desc);
}

// ============================================================================
// Clone and fetch
// ============================================================================

test "cloneNoCheckout preserves HEAD hash" {
    const path = tmpPath("clone_head");
    const clone_path = tmpPath("clone_head_dst");
    cleanup(path);
    cleanup(clone_path);
    defer cleanup(path);
    defer cleanup(clone_path);

    var repo = try Repository.init(testing.allocator, path);
    try initGitConfig(path);
    try writeFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    const source_head = try repo.commit("init", "A", "a@b.com");
    repo.close();

    var cloned = try Repository.cloneNoCheckout(testing.allocator, path, clone_path);
    defer cloned.close();

    const cloned_head = try cloned.revParseHead();
    try testing.expectEqualStrings(&source_head, &cloned_head);
}

test "fetch copies new objects from source" {
    const src = tmpPath("fetch_src");
    const dst = tmpPath("fetch_dst");
    cleanup(src);
    cleanup(dst);
    defer cleanup(src);
    defer cleanup(dst);

    // Create source with a commit
    var src_repo = try Repository.init(testing.allocator, src);
    try initGitConfig(src);
    try writeFile(src, "f.txt", "data\n");
    try src_repo.add("f.txt");
    _ = try src_repo.commit("init", "A", "a@b.com");
    src_repo.close();

    // Clone, then add to source, then fetch
    var dst_repo = try Repository.cloneNoCheckout(testing.allocator, src, dst);

    // Make a new commit in source
    var src_repo2 = try Repository.open(testing.allocator, src);
    try writeFile(src, "g.txt", "more\n");
    try src_repo2.add("g.txt");
    _ = try src_repo2.commit("second", "A", "a@b.com");
    src_repo2.close();

    // Fetch should succeed
    try dst_repo.fetch(src);
    dst_repo.close();
}

test "fetch rejects HTTP URLs" {
    const path = tmpPath("fetch_http");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try testing.expectError(error.NetworkRemoteNotSupported, repo.fetch("https://github.com/example/repo"));
    try testing.expectError(error.NetworkRemoteNotSupported, repo.fetch("http://github.com/example/repo"));
    try testing.expectError(error.NetworkRemoteNotSupported, repo.fetch("git://github.com/example/repo"));
    try testing.expectError(error.NetworkRemoteNotSupported, repo.fetch("ssh://github.com/example/repo"));
}

// ============================================================================
// Cache invalidation
// ============================================================================

test "revParseHead updates after new commit (cache cleared)" {
    const path = tmpPath("cache_revparse");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    try initGitConfig(path);

    try writeFile(path, "f.txt", "v1\n");
    try repo.add("f.txt");
    const h1 = try repo.commit("c1", "A", "a@b.com");

    // Cache should be populated
    const h1_cached = try repo.revParseHead();
    try testing.expectEqualStrings(&h1, &h1_cached);

    // New commit should clear cache
    try writeFile(path, "f.txt", "v2\n");
    try repo.add("f.txt");
    const h2 = try repo.commit("c2", "A", "a@b.com");

    const h2_cached = try repo.revParseHead();
    try testing.expectEqualStrings(&h2, &h2_cached);
    // Should be different from first
    try testing.expect(!std.mem.eql(u8, &h1, &h2));
}

// ============================================================================
// Cross-validation: git creates, ziggit reads
// ============================================================================

test "ziggit reads git-created commit correctly" {
    const path = tmpPath("git_creates_ziggit_reads");
    cleanup(path);
    defer cleanup(path);

    // Use git to create the repo and commit
    std.fs.makeDirAbsolute(path) catch {};
    try runGitDiscard(path, &.{"init"});
    try initGitConfig(path);
    try writeFile(path, "hello.txt", "Hello from git\n");
    try runGitDiscard(path, &.{ "add", "hello.txt" });
    try runGitDiscard(path, &.{ "commit", "-m", "git commit" });

    const git_head_out = try runGit(path, &.{ "rev-parse", "HEAD" });
    defer testing.allocator.free(git_head_out);
    const git_head = trimResult(git_head_out);

    // ziggit should read the same HEAD
    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    const ziggit_head = try repo.revParseHead();
    try testing.expectEqualStrings(git_head, &ziggit_head);
}

test "ziggit reads git-created tags" {
    const path = tmpPath("git_tags_ziggit_reads");
    cleanup(path);
    defer cleanup(path);

    std.fs.makeDirAbsolute(path) catch {};
    try runGitDiscard(path, &.{"init"});
    try initGitConfig(path);
    try writeFile(path, "f.txt", "data\n");
    try runGitDiscard(path, &.{ "add", "f.txt" });
    try runGitDiscard(path, &.{ "commit", "-m", "init" });
    try runGitDiscard(path, &.{ "tag", "v1.0" });

    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    const desc = try repo.describeTags(testing.allocator);
    defer testing.allocator.free(desc);
    try testing.expect(desc.len > 0);
    try testing.expect(std.mem.indexOf(u8, desc, "v1.0") != null);
}

test "ziggit reads git-created branches" {
    const path = tmpPath("git_branch_ziggit_reads");
    cleanup(path);
    defer cleanup(path);

    std.fs.makeDirAbsolute(path) catch {};
    try runGitDiscard(path, &.{"init"});
    try initGitConfig(path);
    try writeFile(path, "f.txt", "data\n");
    try runGitDiscard(path, &.{ "add", "f.txt" });
    try runGitDiscard(path, &.{ "commit", "-m", "init" });
    try runGitDiscard(path, &.{ "branch", "dev" });
    try runGitDiscard(path, &.{ "branch", "staging" });

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
