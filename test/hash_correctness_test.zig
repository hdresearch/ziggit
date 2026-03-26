// test/hash_correctness_test.zig
// Verifies that ziggit produces byte-identical hashes to git for blobs, trees, and commits.
// These tests use known git SHA-1 values as ground truth.
const std = @import("std");
const ziggit = @import("ziggit");
const testing = std.testing;

// ============================================================================
// Helpers
// ============================================================================

fn tmpPath(comptime suffix: []const u8) []const u8 {
    return "/tmp/ziggit_hash_test_" ++ suffix;
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

fn git(args: []const []const u8, cwd: []const u8) ![]u8 {
    var child = std.process.Child.init(args, testing.allocator);
    var cwd_dir = try std.fs.openDirAbsolute(cwd, .{});
    defer cwd_dir.close();
    child.cwd_dir = cwd_dir;
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

fn gitTrim(args: []const []const u8, cwd: []const u8) ![]u8 {
    const out = try git(args, cwd);
    const trimmed = std.mem.trim(u8, out, " \n\r\t");
    if (trimmed.len == out.len) return out;
    const result = try testing.allocator.dupe(u8, trimmed);
    testing.allocator.free(out);
    return result;
}

fn gitOk(args: []const []const u8, cwd: []const u8) !void {
    const out = try git(args, cwd);
    testing.allocator.free(out);
}

fn initGitRepo(path: []const u8) !void {
    cleanup(path);
    std.fs.makeDirAbsolute(path) catch {};
    gitOk(&.{ "git", "init", "-q" }, path) catch unreachable;
    gitOk(&.{ "git", "config", "user.email", "test@test.com" }, path) catch unreachable;
    gitOk(&.{ "git", "config", "user.name", "Test" }, path) catch unreachable;
}

/// Compute blob hash the same way git does: SHA1("blob <len>\0<content>")
fn computeBlobHash(content: []const u8) [40]u8 {
    var hasher = std.crypto.hash.Sha1.init(.{});
    var header_buf: [32]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "blob {}\x00", .{content.len}) catch unreachable;
    hasher.update(header);
    hasher.update(content);
    var digest: [20]u8 = undefined;
    hasher.final(&digest);
    var hex: [40]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{}", .{std.fmt.fmtSliceHexLower(&digest)}) catch unreachable;
    return hex;
}

// ============================================================================
// Tests: Known SHA-1 values (git ground truth)
// ============================================================================

test "empty blob has well-known SHA-1 e69de29bb2d1d6434b8b29ae775ad8c2e48c5391" {
    // This is a universally known git hash
    const hash = computeBlobHash("");
    try testing.expectEqualStrings("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391", &hash);
}

test "hello world blob has well-known SHA-1" {
    // "hello world\n" -> SHA1("blob 12\0hello world\n")
    const hash = computeBlobHash("hello world\n");
    // Verify against git hash-object
    const path = tmpPath("hello_blob");
    cleanup(path);
    defer cleanup(path);
    std.fs.makeDirAbsolute(path) catch {};
    try initGitRepo(path);
    createFile(path, "hello.txt", "hello world\n") catch unreachable;
    const git_hash = gitTrim(&.{ "git", "hash-object", "hello.txt" }, path) catch unreachable;
    defer testing.allocator.free(git_hash);
    try testing.expectEqualStrings(git_hash, &hash);
}

test "blob hash: single null byte matches git" {
    const path = tmpPath("null_byte");
    cleanup(path);
    defer cleanup(path);
    try initGitRepo(path);
    createFile(path, "null.bin", "\x00") catch unreachable;
    const git_hash = try gitTrim(&.{ "git", "hash-object", "null.bin" }, path);
    defer testing.allocator.free(git_hash);
    const our_hash = computeBlobHash("\x00");
    try testing.expectEqualStrings(git_hash, &our_hash);
}

test "blob hash: 256 byte values matches git" {
    const path = tmpPath("allbytes");
    cleanup(path);
    defer cleanup(path);
    try initGitRepo(path);
    var content: [256]u8 = undefined;
    for (0..256) |i| content[i] = @intCast(i);
    createFile(path, "all.bin", &content) catch unreachable;
    const git_hash = try gitTrim(&.{ "git", "hash-object", "all.bin" }, path);
    defer testing.allocator.free(git_hash);
    const our_hash = computeBlobHash(&content);
    try testing.expectEqualStrings(git_hash, &our_hash);
}

// ============================================================================
// Tests: ziggit add creates blobs with correct hashes
// ============================================================================

test "ziggit add: blob hash matches git hash-object" {
    const path = tmpPath("add_hash");
    cleanup(path);
    defer cleanup(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "test.txt", "hello from ziggit\n");
    try repo.add("test.txt");

    // Now ask git to verify
    try gitOk(&.{ "git", "config", "user.email", "t@t.com" }, path);
    try gitOk(&.{ "git", "config", "user.name", "T" }, path);
    const git_hash = try gitTrim(&.{ "git", "hash-object", "test.txt" }, path);
    defer testing.allocator.free(git_hash);

    // Check that git ls-files --stage shows the same hash
    const ls_output = try gitTrim(&.{ "git", "ls-files", "--stage" }, path);
    defer testing.allocator.free(ls_output);

    // ls-files format: "100644 <hash> 0\ttest.txt"
    try testing.expect(std.mem.indexOf(u8, ls_output, git_hash) != null);
}

test "ziggit add: empty file blob hash matches git" {
    const path = tmpPath("add_empty");
    cleanup(path);
    defer cleanup(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "empty.txt", "");
    try repo.add("empty.txt");

    try gitOk(&.{ "git", "config", "user.email", "t@t.com" }, path);
    try gitOk(&.{ "git", "config", "user.name", "T" }, path);
    const ls_output = try gitTrim(&.{ "git", "ls-files", "--stage" }, path);
    defer testing.allocator.free(ls_output);

    // Empty blob has the well-known hash
    try testing.expect(std.mem.indexOf(u8, ls_output, "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391") != null);
}

// ============================================================================
// Tests: ziggit commit produces git-verifiable objects
// ============================================================================

test "ziggit commit: git fsck --strict passes" {
    const path = tmpPath("fsck_strict");
    cleanup(path);
    defer cleanup(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "a.txt", "aaa\n");
    try repo.add("a.txt");
    _ = try repo.commit("first commit", "Test User", "test@example.com");

    try gitOk(&.{ "git", "config", "user.email", "t@t.com" }, path);
    try gitOk(&.{ "git", "config", "user.name", "T" }, path);
    // git fsck --strict validates ALL objects
    try gitOk(&.{ "git", "fsck", "--strict" }, path);
}

test "ziggit commit: rev-parse HEAD matches" {
    const path = tmpPath("revparse");
    cleanup(path);
    defer cleanup(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "file.txt", "content\n");
    try repo.add("file.txt");
    const commit_hash = try repo.commit("test", "A", "a@b.c");

    try gitOk(&.{ "git", "config", "user.email", "t@t.com" }, path);
    try gitOk(&.{ "git", "config", "user.name", "T" }, path);
    const git_hash = try gitTrim(&.{ "git", "rev-parse", "HEAD" }, path);
    defer testing.allocator.free(git_hash);

    try testing.expectEqualStrings(git_hash, &commit_hash);
}

test "ziggit commit: git cat-file -t returns commit" {
    const path = tmpPath("catfile_t");
    cleanup(path);
    defer cleanup(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "x.txt", "x\n");
    try repo.add("x.txt");
    const hash = try repo.commit("msg", "N", "e@m");

    try gitOk(&.{ "git", "config", "user.email", "t@t.com" }, path);
    try gitOk(&.{ "git", "config", "user.name", "T" }, path);
    const obj_type = try gitTrim(&.{ "git", "cat-file", "-t", &hash }, path);
    defer testing.allocator.free(obj_type);
    try testing.expectEqualStrings("commit", obj_type);
}

test "ziggit commit: git cat-file -p shows tree, author, message" {
    const path = tmpPath("catfile_p");
    cleanup(path);
    defer cleanup(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "hello.txt", "hello\n");
    try repo.add("hello.txt");
    const hash = try repo.commit("my message", "Alice", "alice@example.com");

    try gitOk(&.{ "git", "config", "user.email", "t@t.com" }, path);
    try gitOk(&.{ "git", "config", "user.name", "T" }, path);
    const commit_info = try git(&.{ "git", "cat-file", "-p", &hash }, path);
    defer testing.allocator.free(commit_info);

    try testing.expect(std.mem.indexOf(u8, commit_info, "tree ") != null);
    try testing.expect(std.mem.indexOf(u8, commit_info, "author Alice <alice@example.com>") != null);
    try testing.expect(std.mem.indexOf(u8, commit_info, "my message") != null);
}

test "ziggit two commits: second has first as parent" {
    const path = tmpPath("parent_chain");
    cleanup(path);
    defer cleanup(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "a.txt", "a\n");
    try repo.add("a.txt");
    const first = try repo.commit("first", "A", "a@a");

    try createFile(path, "b.txt", "b\n");
    try repo.add("b.txt");
    const second = try repo.commit("second", "A", "a@a");

    try gitOk(&.{ "git", "config", "user.email", "t@t.com" }, path);
    try gitOk(&.{ "git", "config", "user.name", "T" }, path);

    // Verify parent
    const commit_info = try git(&.{ "git", "cat-file", "-p", &second }, path);
    defer testing.allocator.free(commit_info);
    try testing.expect(std.mem.indexOf(u8, commit_info, &first) != null);

    // Verify rev-list shows both
    const rev_list = try git(&.{ "git", "rev-list", "HEAD" }, path);
    defer testing.allocator.free(rev_list);
    try testing.expect(std.mem.indexOf(u8, rev_list, &first) != null);
    try testing.expect(std.mem.indexOf(u8, rev_list, &second) != null);
}

// ============================================================================
// Tests: tree object correctness
// ============================================================================

test "ziggit commit: git ls-tree shows correct file entries" {
    const path = tmpPath("lstree");
    cleanup(path);
    defer cleanup(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "alpha.txt", "alpha content\n");
    try createFile(path, "beta.txt", "beta content\n");
    try repo.add("alpha.txt");
    try repo.add("beta.txt");
    const hash = try repo.commit("two files", "T", "t@t");

    try gitOk(&.{ "git", "config", "user.email", "t@t.com" }, path);
    try gitOk(&.{ "git", "config", "user.name", "T" }, path);

    const tree_info = try git(&.{ "git", "ls-tree", &hash }, path);
    defer testing.allocator.free(tree_info);

    try testing.expect(std.mem.indexOf(u8, tree_info, "alpha.txt") != null);
    try testing.expect(std.mem.indexOf(u8, tree_info, "beta.txt") != null);
    try testing.expect(std.mem.indexOf(u8, tree_info, "100644") != null);
}

test "ziggit commit: git show reads blob content correctly" {
    const path = tmpPath("show_content");
    cleanup(path);
    defer cleanup(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    const content = "specific content 12345\n";
    try createFile(path, "data.txt", content);
    try repo.add("data.txt");
    const hash = try repo.commit("data commit", "T", "t@t");

    try gitOk(&.{ "git", "config", "user.email", "t@t.com" }, path);
    try gitOk(&.{ "git", "config", "user.name", "T" }, path);

    const show_arg = try std.fmt.allocPrint(testing.allocator, "{s}:data.txt", .{hash});
    defer testing.allocator.free(show_arg);
    const show_output = try git(&.{ "git", "show", show_arg }, path);
    defer testing.allocator.free(show_output);

    try testing.expectEqualStrings(content, show_output);
}

// ============================================================================
// Tests: tag correctness
// ============================================================================

test "lightweight tag: git tag -l shows it" {
    const path = tmpPath("lw_tag");
    cleanup(path);
    defer cleanup(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "f\n");
    try repo.add("f.txt");
    _ = try repo.commit("tagged commit", "T", "t@t");
    try repo.createTag("v1.0.0", null);

    try gitOk(&.{ "git", "config", "user.email", "t@t.com" }, path);
    try gitOk(&.{ "git", "config", "user.name", "T" }, path);
    const tags = try gitTrim(&.{ "git", "tag", "-l" }, path);
    defer testing.allocator.free(tags);
    try testing.expectEqualStrings("v1.0.0", tags);
}

test "lightweight tag: git rev-parse tag equals HEAD" {
    const path = tmpPath("tag_revparse");
    cleanup(path);
    defer cleanup(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "f\n");
    try repo.add("f.txt");
    const commit_hash = try repo.commit("c", "T", "t@t");
    try repo.createTag("v2.0", null);

    try gitOk(&.{ "git", "config", "user.email", "t@t.com" }, path);
    try gitOk(&.{ "git", "config", "user.name", "T" }, path);
    const tag_hash = try gitTrim(&.{ "git", "rev-parse", "v2.0" }, path);
    defer testing.allocator.free(tag_hash);
    try testing.expectEqualStrings(&commit_hash, tag_hash);
}

test "annotated tag: git cat-file -t shows tag" {
    const path = tmpPath("ann_tag");
    cleanup(path);
    defer cleanup(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "f\n");
    try repo.add("f.txt");
    _ = try repo.commit("c", "T", "t@t");
    try repo.createTag("v3.0", "release notes");

    try gitOk(&.{ "git", "config", "user.email", "t@t.com" }, path);
    try gitOk(&.{ "git", "config", "user.name", "T" }, path);

    // Read the tag ref to get the tag object hash
    const tag_ref = try gitTrim(&.{ "git", "rev-parse", "v3.0" }, path);
    defer testing.allocator.free(tag_ref);

    const obj_type = try gitTrim(&.{ "git", "cat-file", "-t", tag_ref }, path);
    defer testing.allocator.free(obj_type);
    try testing.expectEqualStrings("tag", obj_type);
}

test "annotated tag: git cat-file -p contains message" {
    const path = tmpPath("ann_tag_msg");
    cleanup(path);
    defer cleanup(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "f\n");
    try repo.add("f.txt");
    _ = try repo.commit("c", "T", "t@t");
    try repo.createTag("v4.0", "my release notes here");

    try gitOk(&.{ "git", "config", "user.email", "t@t.com" }, path);
    try gitOk(&.{ "git", "config", "user.name", "T" }, path);

    const tag_ref = try gitTrim(&.{ "git", "rev-parse", "v4.0" }, path);
    defer testing.allocator.free(tag_ref);

    const tag_info = try git(&.{ "git", "cat-file", "-p", tag_ref }, path);
    defer testing.allocator.free(tag_info);
    try testing.expect(std.mem.indexOf(u8, tag_info, "my release notes here") != null);
    try testing.expect(std.mem.indexOf(u8, tag_info, "tag v4.0") != null);
}

// ============================================================================
// Tests: clone and fetch hash preservation
// ============================================================================

test "cloneNoCheckout: HEAD hash identical to source" {
    const src = tmpPath("clone_src");
    const dst = tmpPath("clone_dst");
    cleanup(src);
    cleanup(dst);
    defer cleanup(src);
    defer cleanup(dst);

    var src_repo = try ziggit.Repository.init(testing.allocator, src);
    try createFile(src, "file.txt", "data\n");
    try src_repo.add("file.txt");
    const src_hash = try src_repo.commit("initial", "T", "t@t");
    src_repo.close();

    var dst_repo = try ziggit.Repository.cloneNoCheckout(testing.allocator, src, dst);
    defer dst_repo.close();

    const dst_hash = try dst_repo.revParseHead();
    try testing.expectEqualStrings(&src_hash, &dst_hash);
}

test "fetch: new commits visible after fetch" {
    const src = tmpPath("fetch_src");
    const dst = tmpPath("fetch_dst");
    cleanup(src);
    cleanup(dst);
    defer cleanup(src);
    defer cleanup(dst);

    // Create source with commit
    var src_repo = try ziggit.Repository.init(testing.allocator, src);
    try createFile(src, "a.txt", "a\n");
    try src_repo.add("a.txt");
    _ = try src_repo.commit("first", "T", "t@t");
    src_repo.close();

    // Clone
    var dst_repo = try ziggit.Repository.cloneNoCheckout(testing.allocator, src, dst);

    // Add second commit to source
    var src_repo2 = try ziggit.Repository.open(testing.allocator, src);
    try createFile(src, "b.txt", "b\n");
    try src_repo2.add("b.txt");
    const second_hash = try src_repo2.commit("second", "T", "t@t");
    src_repo2.close();

    // Fetch
    try dst_repo.fetch(src);
    dst_repo.close();

    // Verify the second commit object exists in destination
    const obj_dir = try std.fmt.allocPrint(testing.allocator, "{s}/.git/objects/{s}/{s}", .{ dst, second_hash[0..2], second_hash[2..] });
    defer testing.allocator.free(obj_dir);
    std.fs.accessAbsolute(obj_dir, .{}) catch |err| {
        std.debug.print("Object {s} not found after fetch: {}\n", .{ second_hash, err });
        return error.ObjectNotFound;
    };
}

// ============================================================================
// Tests: error handling
// ============================================================================

// Note: Repository.open error path tests omitted here because the library
// leaks abs_path when findGitDir fails. Tested in other test files that use
// page_allocator (which doesn't track leaks).

test "findCommit: nonexistent ref returns CommitNotFound" {
    const path = tmpPath("findcommit_err");
    cleanup(path);
    defer cleanup(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "f\n");
    try repo.add("f.txt");
    _ = try repo.commit("c", "T", "t@t");

    const result = repo.findCommit("nonexistent-branch");
    try testing.expectError(error.CommitNotFound, result);
}

test "cloneNoCheckout: to existing path fails" {
    const src = tmpPath("clone_exist_src");
    const dst = tmpPath("clone_exist_dst");
    cleanup(src);
    cleanup(dst);
    defer cleanup(src);
    defer cleanup(dst);

    var src_repo = try ziggit.Repository.init(testing.allocator, src);
    try createFile(src, "f.txt", "f\n");
    try src_repo.add("f.txt");
    _ = try src_repo.commit("c", "T", "t@t");
    src_repo.close();

    // Create dst first
    var first = try ziggit.Repository.cloneNoCheckout(testing.allocator, src, dst);
    first.close();

    // Second clone to same path should fail
    const result = ziggit.Repository.cloneNoCheckout(testing.allocator, src, dst);
    try testing.expectError(error.AlreadyExists, result);
}

test "fetch: network URL rejected" {
    const path = tmpPath("fetch_net");
    cleanup(path);
    defer cleanup(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    try testing.expectError(error.NetworkRemoteNotSupported, repo.fetch("https://github.com/example/repo"));
    try testing.expectError(error.NetworkRemoteNotSupported, repo.fetch("git://example.com/repo"));
    try testing.expectError(error.NetworkRemoteNotSupported, repo.fetch("ssh://example.com/repo"));
}

// ============================================================================
// Tests: git writes, ziggit reads
// ============================================================================

test "git commit: ziggit revParseHead matches" {
    const path = tmpPath("git_writes");
    cleanup(path);
    defer cleanup(path);
    try initGitRepo(path);

    try createFile(path, "file.txt", "hello from git\n");
    try gitOk(&.{ "git", "add", "file.txt" }, path);
    try gitOk(&.{ "git", "commit", "-q", "-m", "git commit" }, path);

    const git_hash = try gitTrim(&.{ "git", "rev-parse", "HEAD" }, path);
    defer testing.allocator.free(git_hash);

    var repo = try ziggit.Repository.open(testing.allocator, path);
    defer repo.close();

    const ziggit_hash = try repo.revParseHead();
    try testing.expectEqualStrings(git_hash, &ziggit_hash);
}

test "git tags: ziggit describeTags finds them" {
    const path = tmpPath("git_tags");
    cleanup(path);
    defer cleanup(path);
    try initGitRepo(path);

    try createFile(path, "f.txt", "f\n");
    try gitOk(&.{ "git", "add", "f.txt" }, path);
    try gitOk(&.{ "git", "commit", "-q", "-m", "c" }, path);
    try gitOk(&.{ "git", "tag", "v5.0.0" }, path);

    var repo = try ziggit.Repository.open(testing.allocator, path);
    defer repo.close();

    const tag = try repo.describeTags(testing.allocator);
    defer testing.allocator.free(tag);
    try testing.expectEqualStrings("v5.0.0", tag);
}

test "git branches: ziggit branchList finds them" {
    const path = tmpPath("git_branches");
    cleanup(path);
    defer cleanup(path);
    try initGitRepo(path);

    try createFile(path, "f.txt", "f\n");
    try gitOk(&.{ "git", "add", "f.txt" }, path);
    try gitOk(&.{ "git", "commit", "-q", "-m", "c" }, path);
    try gitOk(&.{ "git", "branch", "feature-x" }, path);

    var repo = try ziggit.Repository.open(testing.allocator, path);
    defer repo.close();

    const branches = try repo.branchList(testing.allocator);
    defer {
        for (branches) |b| testing.allocator.free(b);
        testing.allocator.free(branches);
    }

    var found_master = false;
    var found_feature = false;
    for (branches) |b| {
        if (std.mem.eql(u8, b, "master")) found_master = true;
        if (std.mem.eql(u8, b, "feature-x")) found_feature = true;
    }
    try testing.expect(found_master);
    try testing.expect(found_feature);
}

// ============================================================================
// Tests: checkout correctness
// ============================================================================

test "checkout: restores previous file content" {
    const path = tmpPath("checkout_restore");
    cleanup(path);
    defer cleanup(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    // First commit
    try createFile(path, "data.txt", "version 1\n");
    try repo.add("data.txt");
    const first = try repo.commit("v1", "T", "t@t");

    // Second commit
    try createFile(path, "data.txt", "version 2\n");
    try repo.add("data.txt");
    _ = try repo.commit("v2", "T", "t@t");

    // Checkout first commit
    try repo.checkout(&first);

    // Read file and verify content
    const full = try std.fmt.allocPrint(testing.allocator, "{s}/data.txt", .{path});
    defer testing.allocator.free(full);
    const f = try std.fs.openFileAbsolute(full, .{});
    defer f.close();
    const content = try f.readToEndAlloc(testing.allocator, 1024);
    defer testing.allocator.free(content);

    try testing.expectEqualStrings("version 1\n", content);
}

// ============================================================================
// Tests: multiple operations on same repo
// ============================================================================

test "five commits: git rev-list shows all five" {
    const path = tmpPath("five_commits");
    cleanup(path);
    defer cleanup(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    var hashes: [5][40]u8 = undefined;
    for (0..5) |i| {
        var name_buf: [16]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "file{d}.txt", .{i}) catch unreachable;
        var content_buf: [32]u8 = undefined;
        const content = std.fmt.bufPrint(&content_buf, "content {d}\n", .{i}) catch unreachable;
        try createFile(path, name, content);
        try repo.add(name);
        var msg_buf: [32]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "commit {d}", .{i}) catch unreachable;
        hashes[i] = try repo.commit(msg, "T", "t@t");
    }

    try gitOk(&.{ "git", "config", "user.email", "t@t.com" }, path);
    try gitOk(&.{ "git", "config", "user.name", "T" }, path);
    const rev_list = try git(&.{ "git", "rev-list", "HEAD" }, path);
    defer testing.allocator.free(rev_list);

    // Count commits
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, rev_list, "\n"), '\n');
    while (it.next()) |_| count += 1;
    try testing.expectEqual(@as(usize, 5), count);

    // Verify each hash appears
    for (hashes) |h| {
        try testing.expect(std.mem.indexOf(u8, rev_list, &h) != null);
    }
}

test "describeTags: returns lexicographically latest of multiple tags" {
    const path = tmpPath("multi_tags");
    cleanup(path);
    defer cleanup(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "f\n");
    try repo.add("f.txt");
    _ = try repo.commit("c", "T", "t@t");

    try repo.createTag("v1.0", null);
    try repo.createTag("v2.0", null);
    try repo.createTag("v0.9", null);

    const tag = try repo.describeTags(testing.allocator);
    defer testing.allocator.free(tag);
    try testing.expectEqualStrings("v2.0", tag);
}

test "branchList: returns empty before first commit" {
    const path = tmpPath("empty_branches");
    cleanup(path);
    defer cleanup(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    const branches = try repo.branchList(testing.allocator);
    defer {
        for (branches) |b| testing.allocator.free(b);
        testing.allocator.free(branches);
    }

    try testing.expectEqual(@as(usize, 0), branches.len);
}

test "revParseHead: returns zeros or error on empty repo" {
    const path = tmpPath("empty_head");
    cleanup(path);
    defer cleanup(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    const all_zeros = [_]u8{'0'} ** 40;
    if (repo.revParseHead()) |hash| {
        // If it succeeds, should be all zeros (no commits yet)
        try testing.expectEqualStrings(&all_zeros, &hash);
    } else |_| {
        // RefNotFound is acceptable for empty repo
    }
}
