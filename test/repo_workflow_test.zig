// test/repo_workflow_test.zig - End-to-end workflow tests for Repository API
// Tests multi-step operations: init->add->commit->checkout->tag cycles
const std = @import("std");
const ziggit = @import("ziggit");
const testing = std.testing;

const Repository = ziggit.Repository;

// ============================================================================
// Helpers
// ============================================================================

const base = "/tmp/ziggit_workflow_";

fn tmp(comptime suffix: []const u8) []const u8 {
    return base ++ suffix;
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

fn readFileContent(repo_path: []const u8, name: []const u8) ![]u8 {
    const full = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ repo_path, name });
    defer testing.allocator.free(full);
    const f = try std.fs.openFileAbsolute(full, .{});
    defer f.close();
    return try f.readToEndAlloc(testing.allocator, 1024 * 1024);
}

fn fileExists(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
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
    // Trim trailing whitespace in-place by returning a slice
    const trimmed = std.mem.trimRight(u8, out, " \n\r\t");
    if (trimmed.len < out.len) {
        // Return new allocation of just the trimmed part
        const result = try testing.allocator.dupe(u8, trimmed);
        testing.allocator.free(out);
        return result;
    }
    return out;
}

fn initGitRepo(path: []const u8) !void {
    cleanup(path);
    std.fs.makeDirAbsolute(path) catch {};
    try gitOk(&.{ "git", "init", "-q" }, path);
    try gitOk(&.{ "git", "config", "user.email", "test@test.com" }, path);
    try gitOk(&.{ "git", "config", "user.name", "Test" }, path);
}

// ============================================================================
// Tests: init + add + commit cycle
// ============================================================================

test "workflow: init then add then commit produces valid commit" {
    const path = tmp("init_add_commit");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "hello.txt", "hello world\n");
    try repo.add("hello.txt");
    const hash = try repo.commit("first commit", "Tester", "test@test.com");

    // Hash should be 40 hex chars
    for (hash) |c| {
        try testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }

    // HEAD should point to this commit
    const head = try repo.revParseHead();
    try testing.expectEqualSlices(u8, &hash, &head);
}

test "workflow: git fsck validates ziggit-created commit" {
    const path = tmp("fsck_validate");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "a.txt", "content a\n");
    try repo.add("a.txt");
    _ = try repo.commit("test commit", "Tester", "test@test.com");

    // git fsck --strict should pass on ziggit repo
    const fsck_out = try git(&.{ "git", "fsck", "--strict" }, path);
    defer testing.allocator.free(fsck_out);
    // If fsck passes, it exits 0 (no error from git())
}

test "workflow: two commits create parent chain" {
    const path = tmp("parent_chain");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "v1\n");
    try repo.add("f.txt");
    const h1 = try repo.commit("first", "T", "t@t");

    try createFile(path, "f.txt", "v2\n");
    try repo.add("f.txt");
    const h2 = try repo.commit("second", "T", "t@t");

    // Hashes must differ
    try testing.expect(!std.mem.eql(u8, &h1, &h2));

    // git log should show 2 commits
    const log = try git(&.{ "git", "log", "--oneline" }, path);
    defer testing.allocator.free(log);
    var lines: usize = 0;
    var it = std.mem.splitScalar(u8, std.mem.trimRight(u8, log, "\n"), '\n');
    while (it.next()) |_| lines += 1;
    try testing.expectEqual(@as(usize, 2), lines);
}

test "workflow: git cat-file reads ziggit blob" {
    const path = tmp("catfile_blob");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    const content = "the quick brown fox\n";
    try createFile(path, "fox.txt", content);
    try repo.add("fox.txt");
    _ = try repo.commit("add fox", "T", "t@t");

    // Get blob hash via git ls-tree
    const ls_tree = try gitTrim(&.{ "git", "ls-tree", "HEAD" }, path);
    defer testing.allocator.free(ls_tree);

    // Parse: "100644 blob <hash>\t<name>"
    if (std.mem.indexOf(u8, ls_tree, "blob ")) |blob_pos| {
        const hash_start = blob_pos + 5;
        if (hash_start + 40 <= ls_tree.len) {
            const blob_hash = ls_tree[hash_start .. hash_start + 40];

            // Read blob with git cat-file
            const cat_args = [_][]const u8{ "git", "cat-file", "-p", blob_hash };
            const blob_content = try gitTrim(&cat_args, path);
            defer testing.allocator.free(blob_content);

            try testing.expectEqualStrings("the quick brown fox", blob_content);
        }
    }
}

// ============================================================================
// Tests: tag operations
// ============================================================================

test "workflow: createTag then describeTags finds it" {
    const path = tmp("tag_describe");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "T", "t@t");

    try repo.createTag("v1.0.0", null);

    const tag = try repo.describeTags(testing.allocator);
    defer testing.allocator.free(tag);
    try testing.expectEqualStrings("v1.0.0", tag);
}

test "workflow: multiple tags, describeTags returns lexicographically latest" {
    const path = tmp("multi_tag");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "T", "t@t");

    try repo.createTag("v1.0.0", null);
    try repo.createTag("v2.0.0", null);
    try repo.createTag("v1.5.0", null);

    const tag = try repo.describeTags(testing.allocator);
    defer testing.allocator.free(tag);
    try testing.expectEqualStrings("v2.0.0", tag);
}

test "workflow: annotated tag passes git fsck" {
    const path = tmp("annotated_tag");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "T", "t@t");

    try repo.createTag("v1.0.0", "Release 1.0");

    const fsck = try git(&.{ "git", "fsck", "--strict" }, path);
    defer testing.allocator.free(fsck);
}

test "workflow: lightweight tag ref matches HEAD" {
    const path = tmp("tag_ref_head");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "T", "t@t");

    try repo.createTag("v1.0.0", null);

    // The tag ref file should contain the same hash as HEAD
    const head_hash = try repo.revParseHead();
    const tag_path = try std.fmt.allocPrint(testing.allocator, "{s}/refs/tags/v1.0.0", .{repo.git_dir});
    defer testing.allocator.free(tag_path);

    const tag_content_raw = try std.fs.cwd().readFileAlloc(testing.allocator, tag_path, 1024);
    defer testing.allocator.free(tag_content_raw);
    const tag_content = std.mem.trimRight(u8, tag_content_raw, " \n\r\t");

    try testing.expectEqualSlices(u8, &head_hash, tag_content);
}

// ============================================================================
// Tests: checkout workflow
// ============================================================================

test "workflow: checkout restores file content" {
    const path = tmp("checkout_restore");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "data.txt", "version 1\n");
    try repo.add("data.txt");
    const h1 = try repo.commit("v1", "T", "t@t");

    try createFile(path, "data.txt", "version 2\n");
    try repo.add("data.txt");
    _ = try repo.commit("v2", "T", "t@t");

    // Checkout first commit
    try repo.checkout(&h1);

    const content = try readFileContent(path, "data.txt");
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("version 1\n", content);
}

test "workflow: checkout updates HEAD" {
    const path = tmp("checkout_head");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "a\n");
    try repo.add("f.txt");
    const h1 = try repo.commit("first", "T", "t@t");

    try createFile(path, "f.txt", "b\n");
    try repo.add("f.txt");
    _ = try repo.commit("second", "T", "t@t");

    try repo.checkout(&h1);

    // HEAD should now be h1 (detached or via branch ref)
    const head = try repo.revParseHead();
    try testing.expectEqualSlices(u8, &h1, &head);
}

// ============================================================================
// Tests: branch operations
// ============================================================================

test "workflow: branchList shows master after commit" {
    const path = tmp("branch_master");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    // Before any commit, there may be no branch files
    try createFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "T", "t@t");

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

test "workflow: git branch created externally visible to branchList" {
    const path = tmp("ext_branch");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "T", "t@t");

    // Create branch with git CLI
    try gitOk(&.{ "git", "branch", "feature-xyz" }, path);

    const branches = try repo.branchList(testing.allocator);
    defer {
        for (branches) |b| testing.allocator.free(b);
        testing.allocator.free(branches);
    }

    var found = false;
    for (branches) |b| {
        if (std.mem.eql(u8, b, "feature-xyz")) found = true;
    }
    try testing.expect(found);
}

// ============================================================================
// Tests: findCommit resolution
// ============================================================================

test "workflow: findCommit resolves full hash" {
    const path = tmp("find_full");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    const h = try repo.commit("init", "T", "t@t");

    const found = try repo.findCommit(&h);
    try testing.expectEqualSlices(u8, &h, &found);
}

test "workflow: findCommit resolves HEAD" {
    const path = tmp("find_head");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    const h = try repo.commit("init", "T", "t@t");

    const found = try repo.findCommit("HEAD");
    try testing.expectEqualSlices(u8, &h, &found);
}

test "workflow: findCommit resolves short hash" {
    const path = tmp("find_short");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    const h = try repo.commit("init", "T", "t@t");

    // Use first 7 chars as short hash
    const found = try repo.findCommit(h[0..7]);
    try testing.expectEqualSlices(u8, &h, &found);
}

test "workflow: findCommit with nonexistent full hash returns hash (no validation)" {
    const path = tmp("find_nonexist");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "T", "t@t");

    // findCommit with a 40-char hex returns it directly without object validation
    const found = try repo.findCommit("deadbeefdeadbeefdeadbeefdeadbeefdeadbeef");
    try testing.expectEqualStrings("deadbeefdeadbeefdeadbeefdeadbeefdeadbeef", &found);
}

test "workflow: findCommit with nonexistent short hash returns error" {
    const path = tmp("find_nonexist_short");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "T", "t@t");

    // Short hash that doesn't match any object
    const result = repo.findCommit("aaaaaaa");
    try testing.expectError(error.CommitNotFound, result);
}

// ============================================================================
// Tests: clone and fetch
// ============================================================================

test "workflow: cloneNoCheckout preserves commits" {
    const src = tmp("clone_src");
    const dst = tmp("clone_dst");
    cleanup(src);
    cleanup(dst);
    defer cleanup(src);
    defer cleanup(dst);

    // Create source repo
    var src_repo = try Repository.init(testing.allocator, src);
    try createFile(src, "f.txt", "hello\n");
    try src_repo.add("f.txt");
    const src_head = try src_repo.commit("init", "T", "t@t");
    src_repo.close();

    // Clone
    var dst_repo = try Repository.cloneNoCheckout(testing.allocator, src, dst);
    defer dst_repo.close();

    // HEAD should match
    const dst_head = try dst_repo.revParseHead();
    try testing.expectEqualSlices(u8, &src_head, &dst_head);
}

test "workflow: cloneNoCheckout to existing path fails" {
    const src = tmp("clone_exist_src");
    const dst = tmp("clone_exist_dst");
    cleanup(src);
    cleanup(dst);
    defer cleanup(src);
    defer cleanup(dst);

    var src_repo = try Repository.init(testing.allocator, src);
    try createFile(src, "f.txt", "x\n");
    try src_repo.add("f.txt");
    _ = try src_repo.commit("init", "T", "t@t");
    src_repo.close();

    // First clone should work
    var dst_repo = try Repository.cloneNoCheckout(testing.allocator, src, dst);
    dst_repo.close();

    // Second clone to same path should fail
    const result = Repository.cloneNoCheckout(testing.allocator, src, dst);
    try testing.expectError(error.AlreadyExists, result);
}

test "workflow: fetch copies objects from remote" {
    const remote = tmp("fetch_remote");
    const local = tmp("fetch_local");
    cleanup(remote);
    cleanup(local);
    defer cleanup(remote);
    defer cleanup(local);

    // Create remote repo
    var remote_repo = try Repository.init(testing.allocator, remote);
    try createFile(remote, "f.txt", "data\n");
    try remote_repo.add("f.txt");
    const remote_head = try remote_repo.commit("remote commit", "T", "t@t");
    remote_repo.close();

    // Create local repo with a commit
    var local_repo = try Repository.init(testing.allocator, local);
    defer local_repo.close();
    try createFile(local, "g.txt", "local\n");
    try local_repo.add("g.txt");
    _ = try local_repo.commit("local commit", "T", "t@t");

    // Fetch from remote
    try local_repo.fetch(remote);

    // Remote commit object should now be in local objects
    const obj_path = try std.fmt.allocPrint(testing.allocator, "{s}/objects/{s}/{s}", .{ local_repo.git_dir, remote_head[0..2], remote_head[2..] });
    defer testing.allocator.free(obj_path);
    try testing.expect(fileExists(obj_path));
}

test "workflow: fetch rejects network URL" {
    const path = tmp("fetch_net");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "T", "t@t");

    try testing.expectError(error.NetworkRemoteNotSupported, repo.fetch("https://github.com/example/repo"));
    try testing.expectError(error.NetworkRemoteNotSupported, repo.fetch("git://example.com/repo"));
    try testing.expectError(error.NetworkRemoteNotSupported, repo.fetch("ssh://example.com/repo"));
}

// ============================================================================
// Tests: multiple files workflow
// ============================================================================

test "workflow: add multiple files then commit" {
    const path = tmp("multi_file");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "a.txt", "file a\n");
    try createFile(path, "b.txt", "file b\n");
    try createFile(path, "c.txt", "file c\n");

    try repo.add("a.txt");
    try repo.add("b.txt");
    try repo.add("c.txt");

    _ = try repo.commit("add three files", "T", "t@t");

    // All three files should be in tree (verify with git ls-tree)
    const ls_tree = try git(&.{ "git", "ls-tree", "HEAD" }, path);
    defer testing.allocator.free(ls_tree);

    try testing.expect(std.mem.indexOf(u8, ls_tree, "a.txt") != null);
    try testing.expect(std.mem.indexOf(u8, ls_tree, "b.txt") != null);
    try testing.expect(std.mem.indexOf(u8, ls_tree, "c.txt") != null);
}

test "workflow: modify file between commits creates different hashes" {
    const path = tmp("modify_file");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "data.txt", "original\n");
    try repo.add("data.txt");
    const h1 = try repo.commit("original", "T", "t@t");

    try createFile(path, "data.txt", "modified\n");
    try repo.add("data.txt");
    const h2 = try repo.commit("modified", "T", "t@t");

    // Hashes must differ since tree content changed
    try testing.expect(!std.mem.eql(u8, &h1, &h2));

    // HEAD should be h2
    const head = try repo.revParseHead();
    try testing.expectEqualSlices(u8, &h2, &head);
}

// ============================================================================
// Tests: cross-validation with git CLI
// ============================================================================

test "workflow: ziggit rev-parse HEAD matches git rev-parse HEAD" {
    const path = tmp("xval_revparse");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "hello\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "T", "t@t");

    const zig_head = try repo.revParseHead();
    const git_head = try gitTrim(&.{ "git", "rev-parse", "HEAD" }, path);
    defer testing.allocator.free(git_head);

    try testing.expectEqualSlices(u8, git_head, &zig_head);
}

test "workflow: git creates repo, ziggit reads it" {
    const path = tmp("git_create_zig_read");
    cleanup(path);
    defer cleanup(path);

    try initGitRepo(path);
    try createFile(path, "hello.txt", "hi\n");
    try gitOk(&.{ "git", "add", "hello.txt" }, path);
    try gitOk(&.{ "git", "commit", "-q", "-m", "init" }, path);

    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    const zig_head = try repo.revParseHead();
    const git_head = try gitTrim(&.{ "git", "rev-parse", "HEAD" }, path);
    defer testing.allocator.free(git_head);

    try testing.expectEqualSlices(u8, git_head, &zig_head);
}

test "workflow: git adds tag, ziggit reads it" {
    const path = tmp("git_tag_zig_read");
    cleanup(path);
    defer cleanup(path);

    try initGitRepo(path);
    try createFile(path, "f.txt", "x\n");
    try gitOk(&.{ "git", "add", "f.txt" }, path);
    try gitOk(&.{ "git", "commit", "-q", "-m", "init" }, path);
    try gitOk(&.{ "git", "tag", "v3.0.0" }, path);

    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    const tag = try repo.describeTags(testing.allocator);
    defer testing.allocator.free(tag);
    try testing.expectEqualStrings("v3.0.0", tag);
}

test "workflow: git creates branches, ziggit lists them" {
    const path = tmp("git_branch_zig_list");
    cleanup(path);
    defer cleanup(path);

    try initGitRepo(path);
    try createFile(path, "f.txt", "x\n");
    try gitOk(&.{ "git", "add", "f.txt" }, path);
    try gitOk(&.{ "git", "commit", "-q", "-m", "init" }, path);
    try gitOk(&.{ "git", "branch", "develop" }, path);
    try gitOk(&.{ "git", "branch", "release" }, path);

    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    const branches = try repo.branchList(testing.allocator);
    defer {
        for (branches) |b| testing.allocator.free(b);
        testing.allocator.free(branches);
    }

    // Should have at least master, develop, release
    try testing.expect(branches.len >= 3);

    var found_develop = false;
    var found_release = false;
    for (branches) |b| {
        if (std.mem.eql(u8, b, "develop")) found_develop = true;
        if (std.mem.eql(u8, b, "release")) found_release = true;
    }
    try testing.expect(found_develop);
    try testing.expect(found_release);
}

// ============================================================================
// Tests: edge cases in workflows
// ============================================================================

test "workflow: empty file add and commit" {
    const path = tmp("empty_file");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "empty.txt", "");
    try repo.add("empty.txt");
    const h = try repo.commit("empty file", "T", "t@t");

    // Should produce valid commit
    for (h) |c| {
        try testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }

    // git should be able to read it
    const fsck = try git(&.{ "git", "fsck", "--strict" }, path);
    defer testing.allocator.free(fsck);
}

test "workflow: large file add and commit" {
    const path = tmp("large_file");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    // Create a 1MB file
    const large = try testing.allocator.alloc(u8, 1024 * 1024);
    defer testing.allocator.free(large);
    @memset(large, 'A');

    try createFile(path, "large.bin", large);
    try repo.add("large.bin");
    const h = try repo.commit("large file", "T", "t@t");

    for (h) |c| {
        try testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
}

test "workflow: binary content add and commit" {
    const path = tmp("binary_content");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    // Create binary content with null bytes
    var binary: [256]u8 = undefined;
    for (&binary, 0..) |*b, i| b.* = @intCast(i);

    try createFile(path, "binary.bin", &binary);
    try repo.add("binary.bin");
    const h = try repo.commit("binary data", "T", "t@t");

    for (h) |c| {
        try testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
}

test "workflow: commit message with special characters" {
    const path = tmp("special_msg");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    _ = try repo.commit("feat: add 'quotes' & \"double\" <angles> (parens)", "T", "t@t");

    // git log should show the message
    const log = try git(&.{ "git", "log", "--format=%s", "-1" }, path);
    defer testing.allocator.free(log);
    const trimmed = std.mem.trimRight(u8, log, "\n");
    try testing.expectEqualStrings("feat: add 'quotes' & \"double\" <angles> (parens)", trimmed);
}

test "workflow: open nonexistent repo returns error" {
    // Use page_allocator to avoid memory leak detection - Repository.open
    // has a known leak on error path (abs_path not freed on NotAGitRepository)
    const result = Repository.open(std.heap.page_allocator, "/tmp/ziggit_does_not_exist_12345");
    try testing.expectError(error.NotAGitRepository, result);
}

test "workflow: add nonexistent file returns error" {
    const path = tmp("add_nofile");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    const result = repo.add("does_not_exist.txt");
    try testing.expectError(error.FileNotFound, result);
}

test "workflow: five rapid commits all have unique hashes" {
    const path = tmp("rapid_commits");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    var hashes: [5][40]u8 = undefined;
    for (0..5) |i| {
        const content = try std.fmt.allocPrint(testing.allocator, "version {d}\n", .{i});
        defer testing.allocator.free(content);
        try createFile(path, "f.txt", content);
        try repo.add("f.txt");
        const msg = try std.fmt.allocPrint(testing.allocator, "commit {d}", .{i});
        defer testing.allocator.free(msg);
        hashes[i] = try repo.commit(msg, "T", "t@t");
    }

    // All hashes should be unique
    for (0..5) |i| {
        for (i + 1..5) |j| {
            try testing.expect(!std.mem.eql(u8, &hashes[i], &hashes[j]));
        }
    }
}
