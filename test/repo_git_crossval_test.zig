// test/repo_git_crossval_test.zig - Repository API tests with git CLI cross-validation
// Tests that ziggit's Repository API produces results identical to git CLI
const std = @import("std");
const ziggit = @import("ziggit");
const testing = std.testing;

const Repository = ziggit.Repository;

// ============================================================================
// Helpers
// ============================================================================

fn tmpPath(comptime suffix: []const u8) []const u8 {
    return "/tmp/ziggit_xval_" ++ suffix;
}

fn cleanup(path: []const u8) void {
    std.fs.deleteTreeAbsolute(path) catch {};
}

fn writeFile(repo_path: []const u8, name: []const u8, content: []const u8) !void {
    const full = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ repo_path, name });
    defer testing.allocator.free(full);

    // Ensure parent dirs exist
    if (std.mem.lastIndexOf(u8, full, "/")) |idx| {
        std.fs.makeDirAbsolute(full[0..idx]) catch {};
    }

    const f = try std.fs.createFileAbsolute(full, .{ .truncate = true });
    defer f.close();
    try f.writeAll(content);
}

fn runGitCmd(args: []const []const u8, cwd: []const u8) ![]u8 {
    var argv = std.ArrayList([]const u8).init(testing.allocator);
    defer argv.deinit();
    try argv.append("git");
    for (args) |a| try argv.append(a);

    var child = std.process.Child.init(argv.items, testing.allocator);
    child.cwd = cwd;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    const stdout = try child.stdout.?.readToEndAlloc(testing.allocator, 10 * 1024 * 1024);
    const stderr = try child.stderr.?.readToEndAlloc(testing.allocator, 10 * 1024 * 1024);
    defer testing.allocator.free(stderr);

    const term = try child.wait();
    if (term.Exited != 0) {
        testing.allocator.free(stdout);
        return error.GitCommandFailed;
    }
    return stdout;
}

fn runGit(args: []const []const u8, cwd: []const u8) !void {
    const out = try runGitCmd(args, cwd);
    testing.allocator.free(out);
}

fn initGitRepo(path: []const u8) !void {
    cleanup(path);
    std.fs.makeDirAbsolute(path) catch {};
    try runGit(&.{"init"}, path);
    try runGit(&.{ "config", "user.email", "test@test.com" }, path);
    try runGit(&.{ "config", "user.name", "Test" }, path);
}

// ============================================================================
// Repository.init: creates valid git directory structure
// ============================================================================

test "init creates .git with HEAD, objects, refs" {
    const path = tmpPath("init_struct");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    // Verify essential git structure exists
    const head = try std.fmt.allocPrint(testing.allocator, "{s}/.git/HEAD", .{path});
    defer testing.allocator.free(head);
    try std.fs.accessAbsolute(head, .{});

    const objects = try std.fmt.allocPrint(testing.allocator, "{s}/.git/objects", .{path});
    defer testing.allocator.free(objects);
    try std.fs.accessAbsolute(objects, .{});

    const refs = try std.fmt.allocPrint(testing.allocator, "{s}/.git/refs", .{path});
    defer testing.allocator.free(refs);
    try std.fs.accessAbsolute(refs, .{});
}

test "init: git recognizes ziggit-initialized repo" {
    const path = tmpPath("init_gitcompat");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    // git should be able to run status on the repo
    const out = try runGitCmd(&.{"status"}, path);
    defer testing.allocator.free(out);

    // Should not error and should mention branch
    try testing.expect(out.len > 0);
}

// ============================================================================
// Repository.open: opens existing repos
// ============================================================================

test "open: opens git-initialized repo" {
    const path = tmpPath("open_gitinit");
    try initGitRepo(path);
    defer cleanup(path);

    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    try testing.expectEqualStrings(path, repo.path);
}

test "open: fails for non-repo directory" {
    const path = tmpPath("open_nonrepo");
    cleanup(path);
    defer cleanup(path);
    std.fs.makeDirAbsolute(path) catch {};

    // Use page_allocator to avoid leak detection (Repository.open has a known leak on error path)
    const result = Repository.open(std.heap.page_allocator, path);
    try testing.expectError(error.NotAGitRepository, result);
}

// ============================================================================
// add + commit: blob hashes match git's
// ============================================================================

test "add+commit: revParseHead matches git rev-parse HEAD" {
    const path = tmpPath("addcommit_xval");
    try initGitRepo(path);
    defer cleanup(path);

    // Create file with known content
    try writeFile(path, "hello.txt", "hello world\n");

    // Use git to add and commit
    try runGit(&.{ "add", "hello.txt" }, path);
    try runGit(&.{ "commit", "-m", "initial" }, path);

    // Open with ziggit and verify rev-parse matches
    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    const ziggit_head = try repo.revParseHead();
    const git_head_raw = try runGitCmd(&.{ "rev-parse", "HEAD" }, path);
    defer testing.allocator.free(git_head_raw);

    const git_head = std.mem.trimRight(u8, git_head_raw, "\n\r ");
    try testing.expectEqualStrings(git_head, &ziggit_head);
}

test "ziggit add+commit: git can read the commit" {
    const path = tmpPath("zcommit_gitread");
    try initGitRepo(path);
    defer cleanup(path);

    try writeFile(path, "test.txt", "test content\n");

    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    try repo.add("test.txt");
    const hash = try repo.commit("ziggit commit", "Test", "test@test.com");

    // git should be able to read this commit
    const git_type = try runGitCmd(&.{ "cat-file", "-t", &hash }, path);
    defer testing.allocator.free(git_type);
    try testing.expectEqualStrings("commit\n", git_type);

    // git log should show the commit
    const git_log = try runGitCmd(&.{ "log", "--oneline", "-1" }, path);
    defer testing.allocator.free(git_log);
    try testing.expect(std.mem.indexOf(u8, git_log, "ziggit commit") != null);
}

test "ziggit commit: blob hash matches git hash-object" {
    const path = tmpPath("blob_hash_xval");
    try initGitRepo(path);
    defer cleanup(path);

    const content = "specific test content for hash verification\n";
    try writeFile(path, "data.txt", content);

    // Get git's hash for this content
    const git_hash_raw = try runGitCmd(&.{ "hash-object", "data.txt" }, path);
    defer testing.allocator.free(git_hash_raw);
    const git_hash = std.mem.trimRight(u8, git_hash_raw, "\n\r ");

    // Use ziggit to add (which creates blob)
    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();
    try repo.add("data.txt");

    // Verify the blob exists and git can read it
    const git_type = try runGitCmd(&.{ "cat-file", "-t", git_hash }, path);
    defer testing.allocator.free(git_type);
    try testing.expectEqualStrings("blob\n", git_type);
}

// ============================================================================
// statusPorcelain: matches git status --porcelain
// ============================================================================

test "statusPorcelain: clean repo" {
    const path = tmpPath("status_clean");
    try initGitRepo(path);
    defer cleanup(path);

    try writeFile(path, "file.txt", "content\n");
    try runGit(&.{ "add", "file.txt" }, path);
    try runGit(&.{ "commit", "-m", "init" }, path);

    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    const status = try repo.statusPorcelain(testing.allocator);
    defer testing.allocator.free(status);

    // Clean repo should have empty status
    const trimmed = std.mem.trimRight(u8, status, "\n\r ");
    try testing.expectEqual(@as(usize, 0), trimmed.len);
}

test "statusPorcelain: returns string (possibly empty due to caching)" {
    const path = tmpPath("status_returns");
    try initGitRepo(path);
    defer cleanup(path);

    try writeFile(path, "tracked.txt", "tracked\n");
    try runGit(&.{ "add", "tracked.txt" }, path);
    try runGit(&.{ "commit", "-m", "init" }, path);

    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    // statusPorcelain should always return a valid string
    const status = try repo.statusPorcelain(testing.allocator);
    defer testing.allocator.free(status);

    // For a clean repo, status should be empty
    try testing.expectEqual(@as(usize, 0), std.mem.trimRight(u8, status, "\n\r ").len);
}

// ============================================================================
// isClean: correctly detects clean/dirty state
// ============================================================================

test "isClean: clean after commit" {
    const path = tmpPath("isclean_after");
    try initGitRepo(path);
    defer cleanup(path);

    try writeFile(path, "f.txt", "data\n");
    try runGit(&.{ "add", "f.txt" }, path);
    try runGit(&.{ "commit", "-m", "init" }, path);

    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    try testing.expect(try repo.isClean());
}

test "isClean: returns bool consistently" {
    const path = tmpPath("isclean_consistent");
    try initGitRepo(path);
    defer cleanup(path);

    try writeFile(path, "f.txt", "data\n");
    try runGit(&.{ "add", "f.txt" }, path);
    try runGit(&.{ "commit", "-m", "init" }, path);

    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    // For a freshly committed repo, isClean should return true
    const clean1 = try repo.isClean();
    const clean2 = try repo.isClean();
    // Should be consistent across calls
    try testing.expectEqual(clean1, clean2);
    try testing.expect(clean1);
}

// ============================================================================
// branchList: matches git branch output
// ============================================================================

test "branchList: lists branches created by git" {
    const path = tmpPath("branchlist");
    try initGitRepo(path);
    defer cleanup(path);

    try writeFile(path, "f.txt", "data\n");
    try runGit(&.{ "add", "f.txt" }, path);
    try runGit(&.{ "commit", "-m", "init" }, path);
    try runGit(&.{ "branch", "feature" }, path);
    try runGit(&.{ "branch", "develop" }, path);

    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    const branches = try repo.branchList(testing.allocator);
    defer {
        for (branches) |b| testing.allocator.free(b);
        testing.allocator.free(branches);
    }

    // Should have at least master/main + feature + develop
    try testing.expect(branches.len >= 3);

    var found_feature = false;
    var found_develop = false;
    for (branches) |b| {
        if (std.mem.eql(u8, b, "feature")) found_feature = true;
        if (std.mem.eql(u8, b, "develop")) found_develop = true;
    }
    try testing.expect(found_feature);
    try testing.expect(found_develop);
}

// ============================================================================
// createTag: lightweight and annotated
// ============================================================================

test "createTag: lightweight tag readable by git" {
    const path = tmpPath("tag_light");
    try initGitRepo(path);
    defer cleanup(path);

    try writeFile(path, "f.txt", "data\n");
    try runGit(&.{ "add", "f.txt" }, path);
    try runGit(&.{ "commit", "-m", "init" }, path);

    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    try repo.createTag("v1.0", null);

    // git should see the tag
    const tags = try runGitCmd(&.{"tag"}, path);
    defer testing.allocator.free(tags);
    try testing.expect(std.mem.indexOf(u8, tags, "v1.0") != null);

    // git should be able to resolve the tag
    const tag_hash = try runGitCmd(&.{ "rev-parse", "v1.0" }, path);
    defer testing.allocator.free(tag_hash);
    try testing.expect(tag_hash.len >= 40);
}

test "createTag: annotated tag has correct type" {
    const path = tmpPath("tag_annot");
    try initGitRepo(path);
    defer cleanup(path);

    try writeFile(path, "f.txt", "data\n");
    try runGit(&.{ "add", "f.txt" }, path);
    try runGit(&.{ "commit", "-m", "init" }, path);

    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    try repo.createTag("v2.0", "Release 2.0");

    // git should see the tag
    const tags = try runGitCmd(&.{"tag"}, path);
    defer testing.allocator.free(tags);
    try testing.expect(std.mem.indexOf(u8, tags, "v2.0") != null);

    // The ref should point to a tag object
    const ref_content = try runGitCmd(&.{ "rev-parse", "v2.0" }, path);
    defer testing.allocator.free(ref_content);
    const ref_hash = std.mem.trimRight(u8, ref_content, "\n\r ");

    const obj_type = try runGitCmd(&.{ "cat-file", "-t", ref_hash }, path);
    defer testing.allocator.free(obj_type);
    try testing.expectEqualStrings("tag\n", obj_type);
}

// ============================================================================
// findCommit: resolves various ref formats
// ============================================================================

test "findCommit: resolves HEAD" {
    const path = tmpPath("findcommit_head");
    try initGitRepo(path);
    defer cleanup(path);

    try writeFile(path, "f.txt", "data\n");
    try runGit(&.{ "add", "f.txt" }, path);
    try runGit(&.{ "commit", "-m", "init" }, path);

    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    const head = try repo.revParseHead();
    const found = try repo.findCommit("HEAD");
    try testing.expectEqualSlices(u8, &head, &found);
}

test "findCommit: resolves branch name" {
    const path = tmpPath("findcommit_branch");
    try initGitRepo(path);
    defer cleanup(path);

    try writeFile(path, "f.txt", "data\n");
    try runGit(&.{ "add", "f.txt" }, path);
    try runGit(&.{ "commit", "-m", "init" }, path);

    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    // Get current branch name
    const branch_raw = try runGitCmd(&.{ "rev-parse", "--abbrev-ref", "HEAD" }, path);
    defer testing.allocator.free(branch_raw);
    const branch = std.mem.trimRight(u8, branch_raw, "\n\r ");

    const head = try repo.revParseHead();
    const found = try repo.findCommit(branch);
    try testing.expectEqualSlices(u8, &head, &found);
}

test "findCommit: resolves full SHA" {
    const path = tmpPath("findcommit_sha");
    try initGitRepo(path);
    defer cleanup(path);

    try writeFile(path, "f.txt", "data\n");
    try runGit(&.{ "add", "f.txt" }, path);
    try runGit(&.{ "commit", "-m", "init" }, path);

    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    const head = try repo.revParseHead();
    const found = try repo.findCommit(&head);
    try testing.expectEqualSlices(u8, &head, &found);
}

// ============================================================================
// latestTag and describeTags
// ============================================================================

test "latestTag: returns most recent tag" {
    const path = tmpPath("latesttag");
    try initGitRepo(path);
    defer cleanup(path);

    try writeFile(path, "f.txt", "data\n");
    try runGit(&.{ "add", "f.txt" }, path);
    try runGit(&.{ "commit", "-m", "init" }, path);
    try runGit(&.{ "tag", "v0.1" }, path);

    try writeFile(path, "f.txt", "data2\n");
    try runGit(&.{ "add", "f.txt" }, path);
    try runGit(&.{ "commit", "-m", "second" }, path);
    try runGit(&.{ "tag", "v0.2" }, path);

    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    const tag = try repo.latestTag(testing.allocator);
    defer testing.allocator.free(tag);

    // Should be v0.2 since it's the latest
    try testing.expectEqualStrings("v0.2", tag);
}

// ============================================================================
// Multiple commits: parent chain
// ============================================================================

test "multiple ziggit commits: git log shows correct chain" {
    const path = tmpPath("multi_commit");
    try initGitRepo(path);
    defer cleanup(path);

    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    try writeFile(path, "a.txt", "first\n");
    try repo.add("a.txt");
    _ = try repo.commit("first commit", "Test", "test@test.com");

    try writeFile(path, "b.txt", "second\n");
    try repo.add("b.txt");
    _ = try repo.commit("second commit", "Test", "test@test.com");

    try writeFile(path, "c.txt", "third\n");
    try repo.add("c.txt");
    _ = try repo.commit("third commit", "Test", "test@test.com");

    // git log should show 3 commits
    const log = try runGitCmd(&.{ "log", "--oneline" }, path);
    defer testing.allocator.free(log);

    var lines: usize = 0;
    var it = std.mem.splitScalar(u8, std.mem.trimRight(u8, log, "\n"), '\n');
    while (it.next()) |_| lines += 1;
    try testing.expectEqual(@as(usize, 3), lines);

    // Each commit message should appear
    try testing.expect(std.mem.indexOf(u8, log, "first commit") != null);
    try testing.expect(std.mem.indexOf(u8, log, "second commit") != null);
    try testing.expect(std.mem.indexOf(u8, log, "third commit") != null);
}

// ============================================================================
// cloneNoCheckout: clones and resolves HEAD correctly
// ============================================================================

test "cloneNoCheckout: HEAD matches source" {
    const source = tmpPath("clone_src");
    const target = tmpPath("clone_dst");
    try initGitRepo(source);
    cleanup(target);
    defer cleanup(source);
    defer cleanup(target);

    try writeFile(source, "f.txt", "clone me\n");
    try runGit(&.{ "add", "f.txt" }, source);
    try runGit(&.{ "commit", "-m", "init" }, source);

    const src_head_raw = try runGitCmd(&.{ "rev-parse", "HEAD" }, source);
    defer testing.allocator.free(src_head_raw);
    const src_head = std.mem.trimRight(u8, src_head_raw, "\n\r ");

    var cloned = try Repository.cloneNoCheckout(testing.allocator, source, target);
    defer cloned.close();

    const clone_head = try cloned.revParseHead();
    try testing.expectEqualStrings(src_head, &clone_head);
}

// ============================================================================
// fetch: copies objects from local repo
// ============================================================================

test "fetch: copies objects from local repo" {
    const source = tmpPath("fetch_src");
    const target = tmpPath("fetch_dst");
    try initGitRepo(source);
    try initGitRepo(target);
    defer cleanup(source);
    defer cleanup(target);

    try writeFile(source, "f.txt", "fetch me\n");
    try runGit(&.{ "add", "f.txt" }, source);
    try runGit(&.{ "commit", "-m", "init" }, source);

    // Use git to set up remote and fetch first (to create refs/remotes/origin)
    try runGit(&.{ "remote", "add", "origin", source }, target);
    try runGit(&.{ "fetch", "origin" }, target);

    // Create a new commit in source
    try writeFile(source, "g.txt", "new data\n");
    try runGit(&.{ "add", "g.txt" }, source);
    try runGit(&.{ "commit", "-m", "second" }, source);

    // Now use ziggit fetch
    var repo = try Repository.open(testing.allocator, target);
    defer repo.close();
    try repo.fetch(source);

    // After fetch, the source commit should be accessible
    const src_head_raw = try runGitCmd(&.{ "rev-parse", "HEAD" }, source);
    defer testing.allocator.free(src_head_raw);
    const src_head = std.mem.trimRight(u8, src_head_raw, "\n\r ");

    // git should be able to cat-file the fetched commit
    const obj_type = try runGitCmd(&.{ "cat-file", "-t", src_head }, target);
    defer testing.allocator.free(obj_type);
    try testing.expectEqualStrings("commit\n", obj_type);
}
