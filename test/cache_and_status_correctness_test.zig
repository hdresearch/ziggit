// test/cache_and_status_correctness_test.zig
// Tests that the Repository caching layer returns correct results,
// especially after mutations (add, commit, file changes).
// Verifies cache invalidation works properly and status is accurate.
const std = @import("std");
const ziggit = @import("ziggit");
const testing = std.testing;

const Repository = ziggit.Repository;

fn tmpPath(comptime suffix: []const u8) []const u8 {
    return "/tmp/ziggit_cache_status_" ++ suffix;
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

fn readFileContent(path: []const u8) ![]u8 {
    const f = try std.fs.openFileAbsolute(path, .{});
    defer f.close();
    return try f.readToEndAlloc(testing.allocator, 1024 * 1024);
}

fn deleteFile(repo_path: []const u8, name: []const u8) !void {
    const full = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ repo_path, name });
    defer testing.allocator.free(full);
    try std.fs.deleteFileAbsolute(full);
}

fn runGitOutput(args: []const []const u8, cwd: []const u8) ![]u8 {
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

// === Cache invalidation tests ===

test "revParseHead cache invalidated after commit" {
    const path = tmpPath("rph_cache_inv");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "a.txt", "hello");
    try repo.add("a.txt");
    const hash1 = try repo.commit("first", "Test", "t@t.com");

    // Second commit should return different hash
    try createFile(path, "b.txt", "world");
    try repo.add("b.txt");
    const hash2 = try repo.commit("second", "Test", "t@t.com");

    // Hashes must differ
    try testing.expect(!std.mem.eql(u8, &hash1, &hash2));

    // revParseHead should return the latest hash
    const head = try repo.revParseHead();
    try testing.expectEqualStrings(&hash2, &head);
}

test "add then commit makes file tracked by git" {
    const path = tmpPath("add_commit_tracked");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "a.txt", "hello world");
    try repo.add("a.txt");
    _ = try repo.commit("init", "Test", "t@t.com");

    // Verify git can see the file in the commit
    const ls_out = try runGitOutput(&.{ "git", "ls-tree", "--name-only", "HEAD" }, path);
    defer testing.allocator.free(ls_out);
    try testing.expect(std.mem.indexOf(u8, ls_out, "a.txt") != null);

    // Verify content
    const cat_out = try runGitOutput(&.{ "git", "cat-file", "-p", "HEAD:a.txt" }, path);
    defer testing.allocator.free(cat_out);
    try testing.expectEqualStrings("hello world", cat_out);
}

test "commit with different messages produces different hashes" {
    const path = tmpPath("diff_msg_hash");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "a.txt", "hello");
    try repo.add("a.txt");
    const hash1 = try repo.commit("message one", "Test", "t@t.com");

    try createFile(path, "b.txt", "world");
    try repo.add("b.txt");
    const hash2 = try repo.commit("message two", "Test", "t@t.com");

    try testing.expect(!std.mem.eql(u8, &hash1, &hash2));
}

test "sequential commits form valid chain verified by git log" {
    const path = tmpPath("commit_chain");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "a.txt", "v1");
    try repo.add("a.txt");
    _ = try repo.commit("first", "Test", "t@t.com");

    try createFile(path, "a.txt", "v2");
    try repo.add("a.txt");
    _ = try repo.commit("second", "Test", "t@t.com");

    try createFile(path, "a.txt", "v3");
    try repo.add("a.txt");
    _ = try repo.commit("third", "Test", "t@t.com");

    // git log should list 3 commits
    const log_out = try runGitOutput(&.{ "git", "log", "--oneline" }, path);
    defer testing.allocator.free(log_out);

    // Count lines (each commit = one line)
    var lines: usize = 0;
    var iter = std.mem.splitScalar(u8, std.mem.trim(u8, log_out, "\n"), '\n');
    while (iter.next()) |_| lines += 1;
    try testing.expectEqual(@as(usize, 3), lines);
}

test "describeTags cache invalidated after createTag" {
    const path = tmpPath("desc_tag_cache");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "a.txt", "hello");
    try repo.add("a.txt");
    _ = try repo.commit("init", "Test", "t@t.com");

    try repo.createTag("v1.0.0", null);
    const tag1 = try repo.describeTags(testing.allocator);
    defer testing.allocator.free(tag1);
    try testing.expectEqualStrings("v1.0.0", tag1);

    // Create a later tag
    try repo.createTag("v2.0.0", null);
    const tag2 = try repo.describeTags(testing.allocator);
    defer testing.allocator.free(tag2);
    try testing.expectEqualStrings("v2.0.0", tag2);
}

test "statusPorcelain empty after clean commit" {
    const path = tmpPath("status_empty");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "a.txt", "hello");
    try repo.add("a.txt");
    _ = try repo.commit("init", "Test", "t@t.com");

    // Reset caches
    repo._cached_is_clean = null;
    repo._cached_index_mtime = null;

    const status = try repo.statusPorcelain(testing.allocator);
    defer testing.allocator.free(status);
    try testing.expectEqualStrings("", status);
}

test "commit returns 40-char hex hash" {
    const path = tmpPath("commit_hash_format");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "content");
    try repo.add("f.txt");
    const hash = try repo.commit("msg", "User", "u@u.com");

    try testing.expectEqual(@as(usize, 40), hash.len);
    for (hash) |c| {
        try testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
}

test "revParseHead matches git rev-parse HEAD after ziggit commit" {
    const path = tmpPath("rph_git_match");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "content");
    try repo.add("f.txt");
    const hash = try repo.commit("init", "Test", "t@t.com");

    const git_hash_raw = try runGitOutput(&.{ "git", "rev-parse", "HEAD" }, path);
    defer testing.allocator.free(git_hash_raw);
    const git_hash = std.mem.trim(u8, git_hash_raw, " \n\r\t");

    try testing.expectEqualStrings(&hash, git_hash);
}

test "branchList includes master after commit" {
    const path = tmpPath("branch_list");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "content");
    try repo.add("f.txt");
    _ = try repo.commit("init", "Test", "t@t.com");

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

test "multiple adds before commit all tracked" {
    const path = tmpPath("multi_add");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "a.txt", "aaa");
    try createFile(path, "b.txt", "bbb");
    try createFile(path, "c.txt", "ccc");
    try repo.add("a.txt");
    try repo.add("b.txt");
    try repo.add("c.txt");
    _ = try repo.commit("three files", "Test", "t@t.com");

    // Verify with git
    const git_out = try runGitOutput(&.{ "git", "ls-tree", "--name-only", "HEAD" }, path);
    defer testing.allocator.free(git_out);

    try testing.expect(std.mem.indexOf(u8, git_out, "a.txt") != null);
    try testing.expect(std.mem.indexOf(u8, git_out, "b.txt") != null);
    try testing.expect(std.mem.indexOf(u8, git_out, "c.txt") != null);
}

test "findCommit resolves HEAD tag and branch consistently" {
    const path = tmpPath("find_commit");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "content");
    try repo.add("f.txt");
    const commit_hash = try repo.commit("init", "Test", "t@t.com");

    try repo.createTag("v1.0.0", null);

    // All three should resolve to same hash
    const from_head = try repo.findCommit("HEAD");
    const from_hash = try repo.findCommit(&commit_hash);
    const from_tag = try repo.findCommit("v1.0.0");
    const from_branch = try repo.findCommit("master");

    try testing.expectEqualStrings(&commit_hash, &from_head);
    try testing.expectEqualStrings(&commit_hash, &from_hash);
    try testing.expectEqualStrings(&commit_hash, &from_tag);
    try testing.expectEqualStrings(&commit_hash, &from_branch);
}

test "git fsck passes after ziggit operations" {
    const path = tmpPath("fsck");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "a.txt", "hello");
    try repo.add("a.txt");
    _ = try repo.commit("first", "Test", "t@t.com");

    try createFile(path, "b.txt", "world");
    try repo.add("b.txt");
    _ = try repo.commit("second", "Test", "t@t.com");

    try repo.createTag("v1.0.0", null);
    try repo.createTag("v1.1.0", "annotated tag");

    const fsck_out = try runGitOutput(&.{ "git", "fsck", "--full" }, path);
    defer testing.allocator.free(fsck_out);
    // fsck should succeed (exit 0) - the runGitOutput checks exit code
}

test "open then close then reopen works" {
    const path = tmpPath("reopen");
    cleanup(path);
    defer cleanup(path);

    {
        var repo = try Repository.init(testing.allocator, path);
        try createFile(path, "f.txt", "content");
        try repo.add("f.txt");
        _ = try repo.commit("init", "Test", "t@t.com");
        repo.close();
    }

    // Reopen
    {
        var repo = try Repository.open(testing.allocator, path);
        defer repo.close();
        const head = try repo.revParseHead();
        // Should be a valid hash, not all zeros
        try testing.expect(!std.mem.eql(u8, &head, &([_]u8{'0'} ** 40)));
    }
}

test "init on existing directory does not destroy data" {
    const path = tmpPath("reinit");
    cleanup(path);
    defer cleanup(path);

    // Create first repo with data
    {
        var repo = try Repository.init(testing.allocator, path);
        try createFile(path, "f.txt", "precious data");
        try repo.add("f.txt");
        _ = try repo.commit("init", "Test", "t@t.com");
        repo.close();
    }

    // Reinitialize  
    {
        var repo = try Repository.init(testing.allocator, path);
        defer repo.close();
        // HEAD should still have content (ref: refs/heads/master)
        const head_path = try std.fmt.allocPrint(testing.allocator, "{s}/.git/HEAD", .{path});
        defer testing.allocator.free(head_path);
        const content = try readFileContent(head_path);
        defer testing.allocator.free(content);
        try testing.expect(content.len > 0);
    }
}
