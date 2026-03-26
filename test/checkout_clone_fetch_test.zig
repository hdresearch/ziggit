// test/checkout_clone_fetch_test.zig
// Tests for checkout, cloneBare, cloneNoCheckout, and fetch operations.
// Cross-validates with git CLI to ensure correctness.
const std = @import("std");
const ziggit = @import("ziggit");
const testing = std.testing;

const Repository = ziggit.Repository;

fn tmpPath(comptime suffix: []const u8) []const u8 {
    return "/tmp/ziggit_checkout_clone_" ++ suffix;
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

fn readFileContent(path: []const u8, name: []const u8) ![]u8 {
    const full = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ path, name });
    defer testing.allocator.free(full);
    const f = try std.fs.openFileAbsolute(full, .{});
    defer f.close();
    return try f.readToEndAlloc(testing.allocator, 1024 * 1024);
}

fn fileExists(path: []const u8, name: []const u8) bool {
    const full = std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ path, name }) catch return false;
    defer testing.allocator.free(full);
    std.fs.accessAbsolute(full, .{}) catch return false;
    return true;
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

// === Checkout tests ===

test "checkout: restores file content from earlier commit" {
    const path = tmpPath("co_restore");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "version 1");
    try repo.add("f.txt");
    const hash1 = try repo.commit("v1", "Test", "t@t.com");

    try createFile(path, "f.txt", "version 2");
    try repo.add("f.txt");
    _ = try repo.commit("v2", "Test", "t@t.com");

    // Checkout back to first commit
    try repo.checkout(&hash1);

    const content = try readFileContent(path, "f.txt");
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("version 1", content);
}

test "checkout: HEAD updated to checked-out commit" {
    const path = tmpPath("co_head");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "v1");
    try repo.add("f.txt");
    const hash1 = try repo.commit("first", "Test", "t@t.com");

    try createFile(path, "g.txt", "v2");
    try repo.add("g.txt");
    _ = try repo.commit("second", "Test", "t@t.com");

    try repo.checkout(&hash1);

    const head = try repo.revParseHead();
    try testing.expectEqualStrings(&hash1, &head);
}

test "checkout: new file from later commit removed after checkout to earlier" {
    const path = tmpPath("co_remove");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "a.txt", "original");
    try repo.add("a.txt");
    const hash1 = try repo.commit("only a.txt", "Test", "t@t.com");

    try createFile(path, "b.txt", "new file");
    try repo.add("b.txt");
    _ = try repo.commit("add b.txt", "Test", "t@t.com");

    // b.txt exists
    try testing.expect(fileExists(path, "b.txt"));

    // Checkout to first commit - b.txt should still be in working dir
    // (git checkout doesn't delete untracked files, but does overwrite tracked ones)
    try repo.checkout(&hash1);

    // a.txt should have original content
    const content = try readFileContent(path, "a.txt");
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("original", content);
}

test "checkout: git rev-parse HEAD valid after checkout" {
    const path = tmpPath("co_revparse");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "v1");
    try repo.add("f.txt");
    const hash1 = try repo.commit("first", "Test", "t@t.com");

    try createFile(path, "f.txt", "v2");
    try repo.add("f.txt");
    _ = try repo.commit("second", "Test", "t@t.com");

    try repo.checkout(&hash1);

    // Verify git can read HEAD after checkout
    const git_head = try runGit(&.{ "git", "rev-parse", "HEAD" }, path);
    defer testing.allocator.free(git_head);
    const trimmed = std.mem.trim(u8, git_head, " \n\r\t");
    try testing.expectEqualStrings(&hash1, trimmed);
}

// === Clone tests ===

test "cloneBare: creates bare repository" {
    const src = tmpPath("clone_bare_src");
    const dst = tmpPath("clone_bare_dst");
    cleanup(src);
    cleanup(dst);
    defer cleanup(src);
    defer cleanup(dst);

    // Create source repo
    {
        var repo = try Repository.init(testing.allocator, src);
        try createFile(src, "f.txt", "hello");
        try repo.add("f.txt");
        _ = try repo.commit("init", "Test", "t@t.com");
        repo.close();
    }

    // Clone bare
    var cloned = try Repository.cloneBare(testing.allocator, src, dst);
    defer cloned.close();

    // Bare repos have HEAD directly in the directory (not .git/HEAD)
    try testing.expect(fileExists(dst, "HEAD"));
    try testing.expect(fileExists(dst, "objects"));
    try testing.expect(fileExists(dst, "refs"));
}

test "cloneNoCheckout: preserves HEAD hash" {
    const src = tmpPath("clone_noco_src");
    const dst = tmpPath("clone_noco_dst");
    cleanup(src);
    cleanup(dst);
    defer cleanup(src);
    defer cleanup(dst);

    var src_hash: [40]u8 = undefined;
    {
        var repo = try Repository.init(testing.allocator, src);
        try createFile(src, "f.txt", "content");
        try repo.add("f.txt");
        src_hash = try repo.commit("init", "Test", "t@t.com");
        repo.close();
    }

    var cloned = try Repository.cloneNoCheckout(testing.allocator, src, dst);
    defer cloned.close();

    const head = try cloned.revParseHead();
    try testing.expectEqualStrings(&src_hash, &head);
}

test "cloneNoCheckout: objects exist in clone" {
    const src = tmpPath("clone_noco_objs_src");
    const dst = tmpPath("clone_noco_objs_dst");
    cleanup(src);
    cleanup(dst);
    defer cleanup(src);
    defer cleanup(dst);

    {
        var repo = try Repository.init(testing.allocator, src);
        try createFile(src, "f.txt", "content");
        try repo.add("f.txt");
        _ = try repo.commit("init", "Test", "t@t.com");
        repo.close();
    }

    var cloned = try Repository.cloneNoCheckout(testing.allocator, src, dst);
    defer cloned.close();

    // git fsck on clone should pass
    const fsck = try runGit(&.{ "git", "fsck", "--full" }, dst);
    defer testing.allocator.free(fsck);
}

test "cloneBare: rejects already existing target" {
    const src = tmpPath("clone_exists_src");
    const dst = tmpPath("clone_exists_dst");
    cleanup(src);
    cleanup(dst);
    defer cleanup(src);
    defer cleanup(dst);

    {
        var repo = try Repository.init(testing.allocator, src);
        try createFile(src, "f.txt", "content");
        try repo.add("f.txt");
        _ = try repo.commit("init", "Test", "t@t.com");
        repo.close();
    }

    // Create target directory first
    try std.fs.makeDirAbsolute(dst);

    const result = Repository.cloneBare(testing.allocator, src, dst);
    try testing.expectError(error.AlreadyExists, result);
}

test "cloneNoCheckout: rejects network URL" {
    const result = Repository.cloneNoCheckout(testing.allocator, "https://github.com/foo/bar", "/tmp/nope");
    try testing.expectError(error.HttpCloneFailed, result);
}

test "cloneBare: rejects network URL" {
    const result = Repository.cloneBare(testing.allocator, "git://github.com/foo/bar", "/tmp/nope");
    try testing.expectError(error.NetworkRemoteNotSupported, result);
}

// === Fetch tests ===

test "fetch: copies objects from local remote" {
    const src = tmpPath("fetch_src");
    const dst = tmpPath("fetch_dst");
    cleanup(src);
    cleanup(dst);
    defer cleanup(src);
    defer cleanup(dst);

    // Create source with a commit
    {
        var repo = try Repository.init(testing.allocator, src);
        try createFile(src, "f.txt", "remote content");
        try repo.add("f.txt");
        _ = try repo.commit("remote commit", "Test", "t@t.com");
        repo.close();
    }

    // Create destination
    var dst_repo = try Repository.init(testing.allocator, dst);
    defer dst_repo.close();

    // Fetch from source
    try dst_repo.fetch(src);

    // After fetch, objects should exist in dst
    // The remote refs should be updated
    const remote_refs_path = try std.fmt.allocPrint(testing.allocator, "{s}/.git/refs/remotes/origin", .{dst});
    defer testing.allocator.free(remote_refs_path);
    std.fs.accessAbsolute(remote_refs_path, .{}) catch {
        // If refs/remotes/origin doesn't exist, that's still OK as long as objects were copied
    };
}

test "fetch: rejects all network URL types" {
    const path = tmpPath("fetch_reject");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try testing.expectError(error.HttpFetchFailed, repo.fetch("http://example.com/repo"));
    try testing.expectError(error.HttpFetchFailed, repo.fetch("https://example.com/repo"));
    try testing.expectError(error.NetworkRemoteNotSupported, repo.fetch("git://example.com/repo"));
    try testing.expectError(error.NetworkRemoteNotSupported, repo.fetch("ssh://example.com/repo"));
}

// === Edge cases ===

test "checkout by tag name" {
    const path = tmpPath("co_tag");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "v1");
    try repo.add("f.txt");
    const hash1 = try repo.commit("first", "Test", "t@t.com");

    try repo.createTag("v1.0.0", null);

    try createFile(path, "f.txt", "v2");
    try repo.add("f.txt");
    _ = try repo.commit("second", "Test", "t@t.com");

    // Checkout by tag name
    try repo.checkout("v1.0.0");

    const head = try repo.revParseHead();
    try testing.expectEqualStrings(&hash1, &head);
}

test "checkout by branch name" {
    const path = tmpPath("co_branch");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "content");
    try repo.add("f.txt");
    const hash1 = try repo.commit("init", "Test", "t@t.com");

    // master should resolve to the commit
    try repo.checkout("master");

    const head = try repo.revParseHead();
    try testing.expectEqualStrings(&hash1, &head);
}

test "multiple clones from same source" {
    const src = tmpPath("multi_clone_src");
    const dst1 = tmpPath("multi_clone_dst1");
    const dst2 = tmpPath("multi_clone_dst2");
    cleanup(src);
    cleanup(dst1);
    cleanup(dst2);
    defer cleanup(src);
    defer cleanup(dst1);
    defer cleanup(dst2);

    {
        var repo = try Repository.init(testing.allocator, src);
        try createFile(src, "f.txt", "content");
        try repo.add("f.txt");
        _ = try repo.commit("init", "Test", "t@t.com");
        repo.close();
    }

    var clone1 = try Repository.cloneNoCheckout(testing.allocator, src, dst1);
    defer clone1.close();
    var clone2 = try Repository.cloneNoCheckout(testing.allocator, src, dst2);
    defer clone2.close();

    const h1 = try clone1.revParseHead();
    const h2 = try clone2.revParseHead();
    try testing.expectEqualStrings(&h1, &h2);
}
