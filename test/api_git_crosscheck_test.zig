// test/api_git_crosscheck_test.zig
// Cross-validates ziggit Repository public API against real git CLI.
const std = @import("std");
const ziggit = @import("ziggit");
const testing = std.testing;

const Repository = ziggit.Repository;

// ============================================================================
// Helpers
// ============================================================================

fn tmp(comptime suffix: []const u8) []const u8 {
    return "/tmp/ziggit_xcheck_" ++ suffix;
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

fn runGit(cwd_path: []const u8, args: []const []const u8) ![]u8 {
    var argv = std.ArrayList([]const u8).init(testing.allocator);
    defer argv.deinit();
    try argv.append("git");
    for (args) |a| try argv.append(a);

    var child = std.process.Child.init(argv.items, testing.allocator);
    child.cwd = cwd_path;
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

fn runGitTrimmed(cwd_path: []const u8, args: []const []const u8) ![]u8 {
    const raw = try runGit(cwd_path, args);
    const trimmed = std.mem.trim(u8, raw, " \n\r\t");
    if (trimmed.len == raw.len) return raw;
    const result = try testing.allocator.dupe(u8, trimmed);
    testing.allocator.free(raw);
    return result;
}

/// Initialize a git+ziggit repo with config set. Caller owns repo.
fn setupRepo(comptime suffix: []const u8) !Repository {
    const path = tmp(suffix);
    cleanup(path);
    const repo = try Repository.init(testing.allocator, path);
    // Configure user for commits via git
    const cfg1 = runGit(path, &.{ "config", "user.email", "test@ziggit.dev" }) catch null;
    if (cfg1) |c| testing.allocator.free(c);
    const cfg2 = runGit(path, &.{ "config", "user.name", "ZiggitTest" }) catch null;
    if (cfg2) |c| testing.allocator.free(c);
    return repo;
}

// ============================================================================
// Tests
// ============================================================================

test "init creates valid .git structure" {
    const path = tmp("init_struct");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try testing.expect(fileExists(path, ".git/HEAD"));
    try testing.expect(fileExists(path, ".git/objects"));
    try testing.expect(fileExists(path, ".git/refs"));
    try testing.expect(fileExists(path, ".git/refs/heads"));
    try testing.expect(fileExists(path, ".git/refs/tags"));

    const head = try readFile(path, ".git/HEAD");
    defer testing.allocator.free(head);
    const trimmed = std.mem.trim(u8, head, " \n\r\t");
    try testing.expect(std.mem.startsWith(u8, trimmed, "ref: refs/heads/"));
}

test "init then open round-trips" {
    const path = tmp("init_open");
    cleanup(path);
    defer cleanup(path);

    {
        var repo = try Repository.init(testing.allocator, path);
        repo.close();
    }
    {
        var repo = try Repository.open(testing.allocator, path);
        defer repo.close();
        try testing.expectEqualStrings(path, repo.path);
    }
}

test "revParseHead matches git rev-parse HEAD after commit" {
    const path = tmp("revparse");
    cleanup(path);
    defer cleanup(path);

    var repo = try setupRepo("revparse");
    defer repo.close();

    try writeFile(path, "file.txt", "hello world\n");
    try repo.add("file.txt");
    const commit_hash = try repo.commit("initial commit", "Test", "test@test.com");

    const git_hash = try runGitTrimmed(path, &.{ "rev-parse", "HEAD" });
    defer testing.allocator.free(git_hash);

    try testing.expectEqualStrings(git_hash, &commit_hash);
}

test "add creates blob object readable by git" {
    const path = tmp("add_blob");
    cleanup(path);
    defer cleanup(path);

    var repo = try setupRepo("add_blob");
    defer repo.close();

    try writeFile(path, "hello.txt", "Hello, World!\n");
    try repo.add("hello.txt");

    const git_hash = try runGitTrimmed(path, &.{ "hash-object", "hello.txt" });
    defer testing.allocator.free(git_hash);

    // Verify the blob object exists
    const obj_dir = try std.fmt.allocPrint(testing.allocator, "{s}/.git/objects/{s}", .{ path, git_hash[0..2] });
    defer testing.allocator.free(obj_dir);
    try std.fs.accessAbsolute(obj_dir, .{});
}

test "commit hash matches git cat-file verification" {
    const path = tmp("commit_hash");
    cleanup(path);
    defer cleanup(path);

    var repo = try setupRepo("commit_hash");
    defer repo.close();

    try writeFile(path, "a.txt", "content A\n");
    try repo.add("a.txt");
    const hash = try repo.commit("first", "Author", "author@test.com");

    const obj_type = try runGitTrimmed(path, &.{ "cat-file", "-t", &hash });
    defer testing.allocator.free(obj_type);
    try testing.expectEqualStrings("commit", obj_type);

    const obj_content = try runGitTrimmed(path, &.{ "cat-file", "-p", &hash });
    defer testing.allocator.free(obj_content);
    try testing.expect(std.mem.indexOf(u8, obj_content, "tree ") != null);
    try testing.expect(std.mem.indexOf(u8, obj_content, "Author <author@test.com>") != null);
    try testing.expect(std.mem.indexOf(u8, obj_content, "first") != null);
}

test "second commit has parent matching first" {
    const path = tmp("parent_chain");
    cleanup(path);
    defer cleanup(path);

    var repo = try setupRepo("parent_chain");
    defer repo.close();

    try writeFile(path, "f1.txt", "v1\n");
    try repo.add("f1.txt");
    const hash1 = try repo.commit("first", "A", "a@b.c");

    try writeFile(path, "f2.txt", "v2\n");
    try repo.add("f2.txt");
    const hash2 = try repo.commit("second", "A", "a@b.c");

    // Verify parent via git cat-file
    const commit_content = try runGitTrimmed(path, &.{ "cat-file", "-p", &hash2 });
    defer testing.allocator.free(commit_content);

    // Should contain "parent <hash1>"
    var expected_parent: [48]u8 = undefined;
    @memcpy(expected_parent[0..7], "parent ");
    @memcpy(expected_parent[7..47], &hash1);
    expected_parent[47] = '\n';
    try testing.expect(std.mem.indexOf(u8, commit_content, expected_parent[0..47]) != null);
}

test "createTag lightweight - git can see it" {
    const path = tmp("tag_light");
    cleanup(path);
    defer cleanup(path);

    var repo = try setupRepo("tag_light");
    defer repo.close();

    try writeFile(path, "a.txt", "aaa\n");
    try repo.add("a.txt");
    const commit_hash = try repo.commit("initial", "A", "a@b.c");

    try repo.createTag("v1.0.0", null);

    const tags = try runGitTrimmed(path, &.{"tag"});
    defer testing.allocator.free(tags);
    try testing.expect(std.mem.indexOf(u8, tags, "v1.0.0") != null);

    const tag_hash = try runGitTrimmed(path, &.{ "rev-parse", "v1.0.0" });
    defer testing.allocator.free(tag_hash);
    try testing.expectEqualStrings(&commit_hash, tag_hash);
}

test "createTag annotated - git can read tag object" {
    const path = tmp("tag_annot");
    cleanup(path);
    defer cleanup(path);

    var repo = try setupRepo("tag_annot");
    defer repo.close();

    try writeFile(path, "a.txt", "aaa\n");
    try repo.add("a.txt");
    _ = try repo.commit("initial", "A", "a@b.c");

    try repo.createTag("v2.0.0", "release version 2");

    const tag_ref_hash = try runGitTrimmed(path, &.{ "rev-parse", "v2.0.0" });
    defer testing.allocator.free(tag_ref_hash);

    const tag_type = try runGitTrimmed(path, &.{ "cat-file", "-t", tag_ref_hash });
    defer testing.allocator.free(tag_type);
    try testing.expectEqualStrings("tag", tag_type);

    const tag_content = try runGitTrimmed(path, &.{ "cat-file", "-p", tag_ref_hash });
    defer testing.allocator.free(tag_content);
    try testing.expect(std.mem.indexOf(u8, tag_content, "release version 2") != null);
    try testing.expect(std.mem.indexOf(u8, tag_content, "tag v2.0.0") != null);
}

test "describeTags returns tag name" {
    const path = tmp("describe");
    cleanup(path);
    defer cleanup(path);

    var repo = try setupRepo("describe");
    defer repo.close();

    try writeFile(path, "a.txt", "a\n");
    try repo.add("a.txt");
    _ = try repo.commit("first", "A", "a@b.c");
    try repo.createTag("v1.0.0", null);

    const desc = try repo.describeTags(testing.allocator);
    defer testing.allocator.free(desc);
    try testing.expect(desc.len > 0);
    try testing.expect(std.mem.indexOf(u8, desc, "v1.0.0") != null);
}

test "findCommit resolves HEAD" {
    const path = tmp("findcommit_head");
    cleanup(path);
    defer cleanup(path);

    var repo = try setupRepo("findcommit_head");
    defer repo.close();

    try writeFile(path, "a.txt", "a\n");
    try repo.add("a.txt");
    const commit_hash = try repo.commit("init", "A", "a@b.c");

    const found = try repo.findCommit("HEAD");
    try testing.expectEqualStrings(&commit_hash, &found);
}

test "findCommit resolves full 40-char hash" {
    const path = tmp("findcommit_full");
    cleanup(path);
    defer cleanup(path);

    var repo = try setupRepo("findcommit_full");
    defer repo.close();

    try writeFile(path, "a.txt", "a\n");
    try repo.add("a.txt");
    const commit_hash = try repo.commit("init", "A", "a@b.c");

    const found = try repo.findCommit(&commit_hash);
    try testing.expectEqualStrings(&commit_hash, &found);
}

test "findCommit resolves tag name" {
    const path = tmp("findcommit_tag");
    cleanup(path);
    defer cleanup(path);

    var repo = try setupRepo("findcommit_tag");
    defer repo.close();

    try writeFile(path, "a.txt", "a\n");
    try repo.add("a.txt");
    const commit_hash = try repo.commit("init", "A", "a@b.c");
    try repo.createTag("v1.0.0", null);

    const found = try repo.findCommit("v1.0.0");
    try testing.expectEqualStrings(&commit_hash, &found);
}

test "findCommit resolves short hash" {
    const path = tmp("findcommit_short");
    cleanup(path);
    defer cleanup(path);

    var repo = try setupRepo("findcommit_short");
    defer repo.close();

    try writeFile(path, "a.txt", "a\n");
    try repo.add("a.txt");
    const commit_hash = try repo.commit("init", "A", "a@b.c");

    const found = try repo.findCommit(commit_hash[0..7]);
    try testing.expectEqualStrings(&commit_hash, &found);
}

test "findCommit returns error for nonexistent ref" {
    const path = tmp("findcommit_noref");
    cleanup(path);
    defer cleanup(path);

    var repo = try setupRepo("findcommit_noref");
    defer repo.close();

    try writeFile(path, "a.txt", "a\n");
    try repo.add("a.txt");
    _ = try repo.commit("init", "A", "a@b.c");

    const result = repo.findCommit("nonexistent_branch_xyz");
    try testing.expectError(error.CommitNotFound, result);
}

test "branchList shows created branches" {
    const path = tmp("branchlist");
    cleanup(path);
    defer cleanup(path);

    var repo = try setupRepo("branchlist");
    defer repo.close();

    try writeFile(path, "a.txt", "a\n");
    try repo.add("a.txt");
    _ = try repo.commit("init", "A", "a@b.c");

    const br1 = try runGit(path, &.{ "branch", "feature-x" });
    testing.allocator.free(br1);
    const br2 = try runGit(path, &.{ "branch", "bugfix-y" });
    testing.allocator.free(br2);

    const branches = try repo.branchList(testing.allocator);
    defer {
        for (branches) |b| testing.allocator.free(b);
        testing.allocator.free(branches);
    }

    try testing.expect(branches.len >= 3);

    var found_feature = false;
    var found_bugfix = false;
    for (branches) |b| {
        if (std.mem.eql(u8, b, "feature-x")) found_feature = true;
        if (std.mem.eql(u8, b, "bugfix-y")) found_bugfix = true;
    }
    try testing.expect(found_feature);
    try testing.expect(found_bugfix);
}

test "checkout switches to previous commit" {
    const path = tmp("checkout");
    cleanup(path);
    defer cleanup(path);

    var repo = try setupRepo("checkout");
    defer repo.close();

    try writeFile(path, "file.txt", "version 1\n");
    try repo.add("file.txt");
    const hash1 = try repo.commit("v1", "A", "a@b.c");

    try writeFile(path, "file.txt", "version 2\n");
    try repo.add("file.txt");
    _ = try repo.commit("v2", "A", "a@b.c");

    try repo.checkout(&hash1);

    const content = try readFile(path, "file.txt");
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("version 1\n", content);

    repo._cached_head_hash = null;
    const current = try repo.revParseHead();
    try testing.expectEqualStrings(&hash1, &current);
}

test "multiple files in single commit visible to git" {
    const path = tmp("multifile");
    cleanup(path);
    defer cleanup(path);

    var repo = try setupRepo("multifile");
    defer repo.close();

    try writeFile(path, "a.txt", "aaa\n");
    try writeFile(path, "b.txt", "bbb\n");
    try writeFile(path, "c.txt", "ccc\n");
    try repo.add("a.txt");
    try repo.add("b.txt");
    try repo.add("c.txt");
    const hash = try repo.commit("three files", "A", "a@b.c");

    const tree_listing = try runGitTrimmed(path, &.{ "ls-tree", &hash });
    defer testing.allocator.free(tree_listing);

    try testing.expect(std.mem.indexOf(u8, tree_listing, "a.txt") != null);
    try testing.expect(std.mem.indexOf(u8, tree_listing, "b.txt") != null);
    try testing.expect(std.mem.indexOf(u8, tree_listing, "c.txt") != null);
}

test "git-created commit is readable by ziggit" {
    const path = tmp("git_to_ziggit");
    cleanup(path);
    defer cleanup(path);

    const init_out = try runGit("/tmp", &.{ "init", path });
    testing.allocator.free(init_out);
    const cfg1 = try runGit(path, &.{ "config", "user.email", "t@t.com" });
    testing.allocator.free(cfg1);
    const cfg2 = try runGit(path, &.{ "config", "user.name", "T" });
    testing.allocator.free(cfg2);
    try writeFile(path, "hello.txt", "hello from git\n");
    const add_out = try runGit(path, &.{ "add", "hello.txt" });
    testing.allocator.free(add_out);
    const commit_out = try runGit(path, &.{ "commit", "-m", "git commit" });
    testing.allocator.free(commit_out);

    const git_hash = try runGitTrimmed(path, &.{ "rev-parse", "HEAD" });
    defer testing.allocator.free(git_hash);

    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    const ziggit_hash = try repo.revParseHead();
    try testing.expectEqualStrings(git_hash, &ziggit_hash);
}

test "add then commit preserves file content" {
    const path = tmp("content_preserve");
    cleanup(path);
    defer cleanup(path);

    var repo = try setupRepo("content_preserve");
    defer repo.close();

    const content = "line1\nline2\nline3\n";
    try writeFile(path, "test.txt", content);
    try repo.add("test.txt");
    const hash = try repo.commit("preserve test", "A", "a@b.c");

    // Use "git show <hash>:test.txt" to verify content
    var show_arg_buf: [60]u8 = undefined;
    const show_arg = try std.fmt.bufPrint(&show_arg_buf, "{s}:test.txt", .{hash});
    const show_output = try runGit(path, &.{ "show", show_arg });
    defer testing.allocator.free(show_output);
    try testing.expectEqualStrings(content, show_output);
}

test "tree object structure is valid" {
    const path = tmp("tree_struct");
    cleanup(path);
    defer cleanup(path);

    var repo = try setupRepo("tree_struct");
    defer repo.close();

    try writeFile(path, "alpha.txt", "alpha\n");
    try writeFile(path, "beta.txt", "beta\n");
    try repo.add("alpha.txt");
    try repo.add("beta.txt");
    const hash = try repo.commit("tree test", "A", "a@b.c");

    // Get tree hash
    var tree_arg_buf: [60]u8 = undefined;
    const tree_arg = try std.fmt.bufPrint(&tree_arg_buf, "{s}^{{tree}}", .{hash});
    const tree_hash = try runGitTrimmed(path, &.{ "rev-parse", tree_arg });
    defer testing.allocator.free(tree_hash);

    const tree_type = try runGitTrimmed(path, &.{ "cat-file", "-t", tree_hash });
    defer testing.allocator.free(tree_type);
    try testing.expectEqualStrings("tree", tree_type);

    const tree_entries = try runGitTrimmed(path, &.{ "ls-tree", tree_hash });
    defer testing.allocator.free(tree_entries);
    try testing.expect(std.mem.indexOf(u8, tree_entries, "100644 blob") != null);
    try testing.expect(std.mem.indexOf(u8, tree_entries, "alpha.txt") != null);
    try testing.expect(std.mem.indexOf(u8, tree_entries, "beta.txt") != null);
}

test "empty file can be added and committed" {
    const path = tmp("emptyfile");
    cleanup(path);
    defer cleanup(path);

    var repo = try setupRepo("emptyfile");
    defer repo.close();

    try writeFile(path, "empty.txt", "");
    try repo.add("empty.txt");
    const hash = try repo.commit("empty file", "A", "a@b.c");

    var show_arg_buf: [60]u8 = undefined;
    const show_arg = try std.fmt.bufPrint(&show_arg_buf, "{s}:empty.txt", .{hash});
    const blob_size = try runGitTrimmed(path, &.{ "cat-file", "-s", show_arg });
    defer testing.allocator.free(blob_size);
    try testing.expectEqualStrings("0", blob_size);
}

test "commit chain of 5 commits maintains history" {
    const path = tmp("chain5");
    cleanup(path);
    defer cleanup(path);

    var repo = try setupRepo("chain5");
    defer repo.close();

    var last_hash: [40]u8 = undefined;
    for (0..5) |i| {
        var fname_buf: [32]u8 = undefined;
        const fname = try std.fmt.bufPrint(&fname_buf, "file_{d}.txt", .{i});
        var content_buf: [32]u8 = undefined;
        const content = try std.fmt.bufPrint(&content_buf, "content {d}\n", .{i});

        try writeFile(path, fname, content);
        try repo.add(fname);

        var msg_buf: [32]u8 = undefined;
        const msg = try std.fmt.bufPrint(&msg_buf, "commit {d}", .{i});
        last_hash = try repo.commit(msg, "A", "a@b.c");
    }

    const log = try runGit(path, &.{ "log", "--oneline" });
    defer testing.allocator.free(log);

    var line_count: usize = 0;
    var iter = std.mem.splitScalar(u8, std.mem.trim(u8, log, "\n"), '\n');
    while (iter.next()) |_| line_count += 1;
    try testing.expectEqual(@as(usize, 5), line_count);

    const git_head = try runGitTrimmed(path, &.{ "rev-parse", "HEAD" });
    defer testing.allocator.free(git_head);
    try testing.expectEqualStrings(git_head, &last_hash);
}

test "add updates index that git ls-files can read" {
    const path = tmp("add_index");
    cleanup(path);
    defer cleanup(path);

    var repo = try setupRepo("add_index");
    defer repo.close();

    try writeFile(path, "indexed.txt", "indexed content\n");
    try repo.add("indexed.txt");

    const ls_files = try runGitTrimmed(path, &.{"ls-files"});
    defer testing.allocator.free(ls_files);
    try testing.expectEqualStrings("indexed.txt", ls_files);
}

test "fetch rejects network URLs" {
    const path = tmp("fetch_net");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try testing.expectError(error.HttpFetchFailed, repo.fetch("https://github.com/test/repo"));
    try testing.expectError(error.NetworkRemoteNotSupported, repo.fetch("git://example.com/repo"));
    try testing.expectError(error.NetworkRemoteNotSupported, repo.fetch("ssh://git@host/repo"));
}

test "isClean true after clean commit" {
    const path = tmp("isclean_clean");
    cleanup(path);
    defer cleanup(path);

    var repo = try setupRepo("isclean_clean");
    defer repo.close();

    try writeFile(path, "a.txt", "aaa\n");
    try repo.add("a.txt");
    _ = try repo.commit("init", "A", "a@b.c");

    // Reset caches to force fresh check
    repo._cached_is_clean = null;
    repo._cached_index_mtime = null;
    repo._cached_index_entries = null;
    repo._cached_index_entries_mtime = null;

    try testing.expect(try repo.isClean());
}

test "statusPorcelain empty for clean repo" {
    const path = tmp("status_clean");
    cleanup(path);
    defer cleanup(path);

    var repo = try setupRepo("status_clean");
    defer repo.close();

    try writeFile(path, "a.txt", "a\n");
    try repo.add("a.txt");
    _ = try repo.commit("init", "A", "a@b.c");

    // Reset cache
    repo._cached_is_clean = null;
    repo._cached_index_mtime = null;

    const status = try repo.statusPorcelain(testing.allocator);
    defer testing.allocator.free(status);
    const trimmed = std.mem.trim(u8, status, " \n\r\t");
    try testing.expectEqual(@as(usize, 0), trimmed.len);
}

test "latestTag returns same as describeTags" {
    const path = tmp("latesttag");
    cleanup(path);
    defer cleanup(path);

    var repo = try setupRepo("latesttag");
    defer repo.close();

    try writeFile(path, "a.txt", "a\n");
    try repo.add("a.txt");
    _ = try repo.commit("first", "A", "a@b.c");
    try repo.createTag("v1.0.0", null);

    const desc = try repo.describeTags(testing.allocator);
    defer testing.allocator.free(desc);

    // Reset tag cache
    if (repo._cached_latest_tag) |t| repo.allocator.free(t);
    repo._cached_latest_tag = null;
    repo._cached_tags_dir_mtime = null;

    const latest = try repo.latestTag(testing.allocator);
    defer testing.allocator.free(latest);

    try testing.expectEqualStrings(desc, latest);
}

test "git add then ziggit reads index" {
    const path = tmp("git_add_ziggit_read");
    cleanup(path);
    defer cleanup(path);

    // Create repo with git
    const init_out = try runGit("/tmp", &.{ "init", path });
    testing.allocator.free(init_out);
    const cfg1 = try runGit(path, &.{ "config", "user.email", "t@t.com" });
    testing.allocator.free(cfg1);
    const cfg2 = try runGit(path, &.{ "config", "user.name", "T" });
    testing.allocator.free(cfg2);

    try writeFile(path, "fromgit.txt", "git added this\n");
    const add_out = try runGit(path, &.{ "add", "fromgit.txt" });
    testing.allocator.free(add_out);
    const commit_out = try runGit(path, &.{ "commit", "-m", "git commit" });
    testing.allocator.free(commit_out);

    // Ziggit should see the commit
    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    const head = try repo.revParseHead();
    // Should be a valid hex hash
    for (&head) |c| {
        try testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
}

test "ziggit add then git commit succeeds" {
    const path = tmp("ziggit_add_git_commit");
    cleanup(path);
    defer cleanup(path);

    // Init with git (to ensure full compat)
    const init_out = try runGit("/tmp", &.{ "init", path });
    testing.allocator.free(init_out);
    const cfg1 = try runGit(path, &.{ "config", "user.email", "t@t.com" });
    testing.allocator.free(cfg1);
    const cfg2 = try runGit(path, &.{ "config", "user.name", "T" });
    testing.allocator.free(cfg2);

    // Need an initial commit first for git to be happy
    try writeFile(path, "initial.txt", "initial\n");
    const add1 = try runGit(path, &.{ "add", "initial.txt" });
    testing.allocator.free(add1);
    const commit1 = try runGit(path, &.{ "commit", "-m", "initial" });
    testing.allocator.free(commit1);

    // Use ziggit to add a file
    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();
    try writeFile(path, "fromziggit.txt", "ziggit added this\n");
    try repo.add("fromziggit.txt");

    // Git should be able to see it as staged
    const status = try runGitTrimmed(path, &.{ "status", "--porcelain" });
    defer testing.allocator.free(status);
    try testing.expect(std.mem.indexOf(u8, status, "fromziggit.txt") != null);
}

test "multiple tags on same commit" {
    const path = tmp("multi_tags");
    cleanup(path);
    defer cleanup(path);

    var repo = try setupRepo("multi_tags");
    defer repo.close();

    try writeFile(path, "a.txt", "a\n");
    try repo.add("a.txt");
    const hash = try repo.commit("init", "A", "a@b.c");

    try repo.createTag("v1.0.0", null);
    try repo.createTag("v1.0.0-rc1", null);
    try repo.createTag("release-1", null);

    // All tags should point to the same commit
    const t1 = try runGitTrimmed(path, &.{ "rev-parse", "v1.0.0" });
    defer testing.allocator.free(t1);
    const t2 = try runGitTrimmed(path, &.{ "rev-parse", "v1.0.0-rc1" });
    defer testing.allocator.free(t2);
    const t3 = try runGitTrimmed(path, &.{ "rev-parse", "release-1" });
    defer testing.allocator.free(t3);

    try testing.expectEqualStrings(&hash, t1);
    try testing.expectEqualStrings(&hash, t2);
    try testing.expectEqualStrings(&hash, t3);
}

test "large file add and commit" {
    const path = tmp("largefile");
    cleanup(path);
    defer cleanup(path);

    var repo = try setupRepo("largefile");
    defer repo.close();

    // Create a 100KB file
    const full_path = try std.fmt.allocPrint(testing.allocator, "{s}/large.bin", .{path});
    defer testing.allocator.free(full_path);
    {
        const f = try std.fs.createFileAbsolute(full_path, .{ .truncate = true });
        defer f.close();
        var buf: [1024]u8 = undefined;
        for (&buf, 0..) |*b, i| b.* = @intCast(i % 256);
        for (0..100) |_| try f.writeAll(&buf);
    }

    try repo.add("large.bin");
    const hash = try repo.commit("large file", "A", "a@b.c");

    var show_arg_buf: [60]u8 = undefined;
    const show_arg = try std.fmt.bufPrint(&show_arg_buf, "{s}:large.bin", .{hash});
    const blob_size = try runGitTrimmed(path, &.{ "cat-file", "-s", show_arg });
    defer testing.allocator.free(blob_size);
    try testing.expectEqualStrings("102400", blob_size);
}

test "findCommit branch created by git" {
    const path = tmp("findcommit_branch");
    cleanup(path);
    defer cleanup(path);

    var repo = try setupRepo("findcommit_branch");
    defer repo.close();

    try writeFile(path, "a.txt", "a\n");
    try repo.add("a.txt");
    const commit_hash = try repo.commit("init", "A", "a@b.c");

    // Create a branch with git
    const br = try runGit(path, &.{ "branch", "test-branch" });
    testing.allocator.free(br);

    // ziggit should resolve it
    const found = try repo.findCommit("test-branch");
    try testing.expectEqualStrings(&commit_hash, &found);
}

test "overwrite file creates different commit hash" {
    const path = tmp("overwrite");
    cleanup(path);
    defer cleanup(path);

    var repo = try setupRepo("overwrite");
    defer repo.close();

    try writeFile(path, "file.txt", "original\n");
    try repo.add("file.txt");
    const hash1 = try repo.commit("original", "A", "a@b.c");

    try writeFile(path, "file2.txt", "second file\n");
    try repo.add("file2.txt");
    const hash2 = try repo.commit("add second", "A", "a@b.c");

    // Different commits (different trees)
    try testing.expect(!std.mem.eql(u8, &hash1, &hash2));

    // Both hashes should be valid git objects
    const t1 = try runGitTrimmed(path, &.{ "cat-file", "-t", &hash1 });
    defer testing.allocator.free(t1);
    try testing.expectEqualStrings("commit", t1);

    const t2 = try runGitTrimmed(path, &.{ "cat-file", "-t", &hash2 });
    defer testing.allocator.free(t2);
    try testing.expectEqualStrings("commit", t2);
}
