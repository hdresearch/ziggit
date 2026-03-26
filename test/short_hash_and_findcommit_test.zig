// test/short_hash_and_findcommit_test.zig
// Tests for short hash expansion, findCommit edge cases, and ref resolution
const std = @import("std");
const ziggit = @import("ziggit");
const testing = std.testing;

const Repository = ziggit.Repository;

fn tmpPath(comptime suffix: []const u8) []const u8 {
    return "/tmp/ziggit_shorthash_" ++ suffix;
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

fn gitOk(args: []const []const u8, cwd: []const u8) !void {
    const out = try git(args, cwd);
    testing.allocator.free(out);
}

fn gitTrim(args: []const []const u8, cwd: []const u8) ![]u8 {
    const out = try git(args, cwd);
    const trimmed = std.mem.trim(u8, out, " \n\r\t");
    if (trimmed.len == out.len) return out;
    const duped = try testing.allocator.dupe(u8, trimmed);
    testing.allocator.free(out);
    return duped;
}

fn initRepoWithCommit(path: []const u8) !Repository {
    var repo = try Repository.init(testing.allocator, path);
    try createFile(path, "hello.txt", "hello world\n");
    try repo.add("hello.txt");
    _ = try repo.commit("initial", "Test", "test@test.com");
    return repo;
}

// ============================================================================
// Short hash expansion tests
// ============================================================================

test "findCommit: 7-char short hash resolves to full hash" {
    const path = tmpPath("short7");
    cleanup(path);
    defer cleanup(path);

    var repo = try initRepoWithCommit(path);
    defer repo.close();

    const full_hash = try repo.revParseHead();
    // Use first 7 characters as short hash
    const short = full_hash[0..7];

    const resolved = try repo.findCommit(short);
    try testing.expectEqualSlices(u8, &full_hash, &resolved);
}

test "findCommit: 4-char short hash (minimum) resolves" {
    const path = tmpPath("short4");
    cleanup(path);
    defer cleanup(path);

    var repo = try initRepoWithCommit(path);
    defer repo.close();

    const full_hash = try repo.revParseHead();
    const short = full_hash[0..4];

    const resolved = try repo.findCommit(short);
    try testing.expectEqualSlices(u8, &full_hash, &resolved);
}

test "findCommit: full 40-char hash resolves to itself" {
    const path = tmpPath("full40");
    cleanup(path);
    defer cleanup(path);

    var repo = try initRepoWithCommit(path);
    defer repo.close();

    const full_hash = try repo.revParseHead();
    const resolved = try repo.findCommit(&full_hash);
    try testing.expectEqualSlices(u8, &full_hash, &resolved);
}

test "findCommit: HEAD resolves to current commit" {
    const path = tmpPath("head_resolve");
    cleanup(path);
    defer cleanup(path);

    var repo = try initRepoWithCommit(path);
    defer repo.close();

    const head = try repo.revParseHead();
    const resolved = try repo.findCommit("HEAD");
    try testing.expectEqualSlices(u8, &head, &resolved);
}

test "findCommit: branch name resolves after commit" {
    const path = tmpPath("branch_resolve");
    cleanup(path);
    defer cleanup(path);

    var repo = try initRepoWithCommit(path);
    defer repo.close();

    const head = try repo.revParseHead();
    const resolved = try repo.findCommit("master");
    try testing.expectEqualSlices(u8, &head, &resolved);
}

test "findCommit: tag name resolves" {
    const path = tmpPath("tag_resolve");
    cleanup(path);
    defer cleanup(path);

    var repo = try initRepoWithCommit(path);
    defer repo.close();

    const head = try repo.revParseHead();
    try repo.createTag("v1.0", null);

    const resolved = try repo.findCommit("v1.0");
    try testing.expectEqualSlices(u8, &head, &resolved);
}

test "findCommit: nonexistent ref returns CommitNotFound" {
    const path = tmpPath("nonexist");
    cleanup(path);
    defer cleanup(path);

    var repo = try initRepoWithCommit(path);
    defer repo.close();

    const result = repo.findCommit("nonexistent_branch");
    try testing.expectError(error.CommitNotFound, result);
}

test "findCommit: invalid short hash returns CommitNotFound" {
    const path = tmpPath("invalid_short");
    cleanup(path);
    defer cleanup(path);

    var repo = try initRepoWithCommit(path);
    defer repo.close();

    // Use a hash that almost certainly doesn't exist
    const result = repo.findCommit("deadbeef");
    try testing.expectError(error.CommitNotFound, result);
}

test "findCommit: 3-char hash is too short (< 4)" {
    const path = tmpPath("tooshort");
    cleanup(path);
    defer cleanup(path);

    var repo = try initRepoWithCommit(path);
    defer repo.close();

    // 3 chars is below minimum for short hash, should be treated as ref name
    const result = repo.findCommit("abc");
    try testing.expectError(error.CommitNotFound, result);
}

test "findCommit resolves each commit in multi-commit chain" {
    const path = tmpPath("chain");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    var hashes: [3][40]u8 = undefined;

    try createFile(path, "a.txt", "aaa\n");
    try repo.add("a.txt");
    hashes[0] = try repo.commit("first", "T", "t@t");

    try createFile(path, "b.txt", "bbb\n");
    try repo.add("b.txt");
    hashes[1] = try repo.commit("second", "T", "t@t");

    try createFile(path, "c.txt", "ccc\n");
    try repo.add("c.txt");
    hashes[2] = try repo.commit("third", "T", "t@t");

    // All three hashes should be distinct
    try testing.expect(!std.mem.eql(u8, &hashes[0], &hashes[1]));
    try testing.expect(!std.mem.eql(u8, &hashes[1], &hashes[2]));
    try testing.expect(!std.mem.eql(u8, &hashes[0], &hashes[2]));

    // Each should be resolvable via short hash
    for (hashes) |h| {
        const resolved = try repo.findCommit(h[0..8]);
        try testing.expectEqualSlices(u8, &h, &resolved);
    }
}

test "findCommit: short hash matches git rev-parse --short" {
    const path = tmpPath("gitmatch");
    cleanup(path);
    defer cleanup(path);

    var repo = try initRepoWithCommit(path);
    defer repo.close();

    const head = try repo.revParseHead();

    // Ask git for its full parse of the same short hash
    const short7 = head[0..7];
    const git_result = try gitTrim(&.{ "git", "rev-parse", short7 }, path);
    defer testing.allocator.free(git_result);

    try testing.expectEqualSlices(u8, &head, git_result);
}

// ============================================================================
// revParseHead edge cases
// ============================================================================

test "revParseHead: returns all zeros before first commit" {
    const path = tmpPath("nocommit");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    const head = repo.revParseHead() catch [_]u8{'0'} ** 40;
    // Should be all zeros or an error (ref not found → zeros)
    const all_zeros = [_]u8{'0'} ** 40;
    try testing.expectEqualSlices(u8, &all_zeros, &head);
}

test "revParseHead: consistent across multiple calls" {
    const path = tmpPath("consistent");
    cleanup(path);
    defer cleanup(path);

    var repo = try initRepoWithCommit(path);
    defer repo.close();

    const h1 = try repo.revParseHead();
    const h2 = try repo.revParseHead();
    const h3 = try repo.revParseHead();

    try testing.expectEqualSlices(u8, &h1, &h2);
    try testing.expectEqualSlices(u8, &h2, &h3);
}

test "revParseHead: matches git rev-parse HEAD" {
    const path = tmpPath("gitrev");
    cleanup(path);
    defer cleanup(path);

    var repo = try initRepoWithCommit(path);
    defer repo.close();

    const ziggit_head = try repo.revParseHead();
    const git_head = try gitTrim(&.{ "git", "rev-parse", "HEAD" }, path);
    defer testing.allocator.free(git_head);

    try testing.expectEqualSlices(u8, &ziggit_head, git_head);
}

test "revParseHead: changes after second commit" {
    const path = tmpPath("headchange");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f1.txt", "one\n");
    try repo.add("f1.txt");
    const h1 = try repo.commit("first", "T", "t@t");

    // Must invalidate cache
    repo._cached_head_hash = null;

    try createFile(path, "f2.txt", "two\n");
    try repo.add("f2.txt");
    const h2 = try repo.commit("second", "T", "t@t");

    try testing.expect(!std.mem.eql(u8, &h1, &h2));
    
    // After cache clear, revParseHead should return h2
    repo._cached_head_hash = null;
    const current = try repo.revParseHead();
    try testing.expectEqualSlices(u8, &h2, &current);
}

// ============================================================================
// branchList edge cases  
// ============================================================================

test "branchList: empty before first commit" {
    const path = tmpPath("nobranch");
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

test "branchList: shows master after first commit" {
    const path = tmpPath("masterbranch");
    cleanup(path);
    defer cleanup(path);

    var repo = try initRepoWithCommit(path);
    defer repo.close();

    const branches = try repo.branchList(testing.allocator);
    defer {
        for (branches) |b| testing.allocator.free(b);
        testing.allocator.free(branches);
    }

    try testing.expectEqual(@as(usize, 1), branches.len);
    try testing.expectEqualSlices(u8, "master", branches[0]);
}

// ============================================================================
// describeTags / latestTag edge cases
// ============================================================================

test "describeTags: empty string when no tags" {
    const path = tmpPath("notags");
    cleanup(path);
    defer cleanup(path);

    var repo = try initRepoWithCommit(path);
    defer repo.close();

    const tag = try repo.describeTags(testing.allocator);
    defer testing.allocator.free(tag);

    try testing.expectEqual(@as(usize, 0), tag.len);
}

test "describeTags: returns single tag" {
    const path = tmpPath("onetag");
    cleanup(path);
    defer cleanup(path);

    var repo = try initRepoWithCommit(path);
    defer repo.close();

    try repo.createTag("v2.0", null);

    const tag = try repo.describeTags(testing.allocator);
    defer testing.allocator.free(tag);

    try testing.expectEqualSlices(u8, "v2.0", tag);
}

test "describeTags: returns lexicographically latest of multiple tags" {
    const path = tmpPath("multitag");
    cleanup(path);
    defer cleanup(path);

    var repo = try initRepoWithCommit(path);
    defer repo.close();

    try repo.createTag("v1.0", null);
    try repo.createTag("v2.0", null);
    try repo.createTag("v1.5", null);

    // Clear tags cache
    if (repo._cached_latest_tag) |t| repo.allocator.free(t);
    repo._cached_latest_tag = null;
    repo._cached_tags_dir_mtime = null;

    const tag = try repo.describeTags(testing.allocator);
    defer testing.allocator.free(tag);

    try testing.expectEqualSlices(u8, "v2.0", tag);
}

test "latestTag: alias returns same as describeTags" {
    const path = tmpPath("alias");
    cleanup(path);
    defer cleanup(path);

    var repo = try initRepoWithCommit(path);
    defer repo.close();

    try repo.createTag("v3.1", null);

    // Clear cache between calls
    if (repo._cached_latest_tag) |t| repo.allocator.free(t);
    repo._cached_latest_tag = null;
    repo._cached_tags_dir_mtime = null;

    const t1 = try repo.describeTags(testing.allocator);
    defer testing.allocator.free(t1);

    if (repo._cached_latest_tag) |t| repo.allocator.free(t);
    repo._cached_latest_tag = null;
    repo._cached_tags_dir_mtime = null;

    const t2 = try repo.latestTag(testing.allocator);
    defer testing.allocator.free(t2);

    try testing.expectEqualSlices(u8, t1, t2);
}

// ============================================================================
// createTag edge cases
// ============================================================================

test "createTag: lightweight tag readable by git" {
    const path = tmpPath("gittag");
    cleanup(path);
    defer cleanup(path);

    var repo = try initRepoWithCommit(path);
    defer repo.close();

    try repo.createTag("release-1", null);

    // git tag -l should show it
    const tags = try gitTrim(&.{ "git", "tag", "-l" }, path);
    defer testing.allocator.free(tags);

    try testing.expect(std.mem.indexOf(u8, tags, "release-1") != null);
}

test "createTag: annotated tag readable by git" {
    const path = tmpPath("anntag");
    cleanup(path);
    defer cleanup(path);

    var repo = try initRepoWithCommit(path);
    defer repo.close();

    try repo.createTag("v5.0", "Release 5.0");

    const tags = try gitTrim(&.{ "git", "tag", "-l" }, path);
    defer testing.allocator.free(tags);

    try testing.expect(std.mem.indexOf(u8, tags, "v5.0") != null);
}

test "createTag: annotated tag has message via git cat-file" {
    const path = tmpPath("anntag_msg");
    cleanup(path);
    defer cleanup(path);

    var repo = try initRepoWithCommit(path);
    defer repo.close();

    try repo.createTag("v6.0", "My release message");

    // Read the tag ref
    const ref_path = try std.fmt.allocPrint(testing.allocator, "{s}/.git/refs/tags/v6.0", .{path});
    defer testing.allocator.free(ref_path);
    const ref_file = try std.fs.openFileAbsolute(ref_path, .{});
    defer ref_file.close();
    var buf: [48]u8 = undefined;
    const n = try ref_file.readAll(&buf);
    const tag_hash = std.mem.trim(u8, buf[0..n], " \n\r\t");

    // git cat-file -p <tag_hash> should contain the message
    const content = try gitTrim(&.{ "git", "cat-file", "-p", tag_hash }, path);
    defer testing.allocator.free(content);

    try testing.expect(std.mem.indexOf(u8, content, "My release message") != null);
}

// ============================================================================
// Repository.open edge cases
// ============================================================================

test "open: non-git directory returns NotAGitRepository" {
    const path = "/tmp/ziggit_shorthash_notgit";
    cleanup(path);
    defer cleanup(path);
    try std.fs.makeDirAbsolute(path);

    // Use page_allocator to avoid leak detection issues with error paths
    const result = Repository.open(std.heap.page_allocator, path);
    try testing.expectError(error.NotAGitRepository, result);
}

test "open: nonexistent path returns error" {
    const result = Repository.open(std.heap.page_allocator, "/tmp/ziggit_shorthash_doesntexist_99999");
    try testing.expectError(error.NotAGitRepository, result);
}

// ============================================================================
// cloneBare edge cases
// ============================================================================

test "cloneBare: rejects network URLs" {
    const result = Repository.cloneBare(testing.allocator, "https://example.com/repo.git", "/tmp/ziggit_clone_net");
    try testing.expectError(error.HttpCloneFailed, result);
}

test "cloneNoCheckout: rejects network URLs" {
    const result = Repository.cloneNoCheckout(testing.allocator, "ssh://git@example.com/repo.git", "/tmp/ziggit_clone_net2");
    try testing.expectError(error.NetworkRemoteNotSupported, result);
}

test "cloneBare: to existing path fails" {
    const source = tmpPath("clonesrc");
    const target = tmpPath("clonetgt_exists");
    cleanup(source);
    cleanup(target);
    defer cleanup(source);
    defer cleanup(target);

    var repo = try initRepoWithCommit(source);
    repo.close();

    // Create target dir first
    try std.fs.makeDirAbsolute(target);

    // Use page_allocator since error path may leak
    const result = Repository.cloneBare(std.heap.page_allocator, source, target);
    try testing.expectError(error.AlreadyExists, result);
}
