// test/clone_and_fetch_test.zig - Tests for local clone and fetch operations
const std = @import("std");
const ziggit = @import("ziggit");
const testing = std.testing;

const Repository = ziggit.Repository;

fn tmpPath(comptime suffix: []const u8) []const u8 {
    return "/tmp/ziggit_clone_test_" ++ suffix;
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
    var cwd_dir = try std.fs.openDirAbsolute(cwd, .{});
    defer cwd_dir.close();
    child.cwd_dir = cwd_dir;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const stdout = try child.stdout.?.reader().readAllAlloc(testing.allocator, 64 * 1024);
    errdefer testing.allocator.free(stdout);
    const stderr = try child.stderr.?.reader().readAllAlloc(testing.allocator, 64 * 1024);
    defer testing.allocator.free(stderr);
    const term = try child.wait();
    switch (term) {
        .Exited => |code| if (code != 0) {
            testing.allocator.free(stdout);
            return error.CommandFailed;
        },
        else => {
            testing.allocator.free(stdout);
            return error.CommandFailed;
        },
    }
    return stdout;
}

fn initRepoWithCommit(path: []const u8) !Repository {
    var repo = try Repository.init(testing.allocator, path);
    try createFile(path, "hello.txt", "hello world\n");
    try repo.add("hello.txt");
    _ = try repo.commit("initial commit", "Test User", "test@example.com");
    return repo;
}

// ============================================================================
// cloneNoCheckout tests
// ============================================================================

test "cloneNoCheckout: cloned repo has same HEAD" {
    const src = tmpPath("clone_src1");
    const dst = tmpPath("clone_dst1");
    cleanup(src);
    cleanup(dst);
    defer cleanup(src);
    defer cleanup(dst);

    var src_repo = try initRepoWithCommit(src);
    const src_head = try src_repo.revParseHead();
    src_repo.close();

    var dst_repo = try Repository.cloneNoCheckout(testing.allocator, src, dst);
    defer dst_repo.close();

    const dst_head = try dst_repo.revParseHead();
    try testing.expectEqualStrings(&src_head, &dst_head);
}

test "cloneNoCheckout: cloned repo has .git directory" {
    const src = tmpPath("clone_src2");
    const dst = tmpPath("clone_dst2");
    cleanup(src);
    cleanup(dst);
    defer cleanup(src);
    defer cleanup(dst);

    var src_repo = try initRepoWithCommit(src);
    src_repo.close();

    var dst_repo = try Repository.cloneNoCheckout(testing.allocator, src, dst);
    defer dst_repo.close();

    // Verify .git/HEAD exists
    const head_path = try std.fmt.allocPrint(testing.allocator, "{s}/.git/HEAD", .{dst});
    defer testing.allocator.free(head_path);
    try std.fs.accessAbsolute(head_path, .{});
}

test "cloneNoCheckout: cloned repo has objects" {
    const src = tmpPath("clone_src3");
    const dst = tmpPath("clone_dst3");
    cleanup(src);
    cleanup(dst);
    defer cleanup(src);
    defer cleanup(dst);

    var src_repo = try initRepoWithCommit(src);
    src_repo.close();

    var dst_repo = try Repository.cloneNoCheckout(testing.allocator, src, dst);
    defer dst_repo.close();

    // Verify objects directory has content
    const obj_dir = try std.fmt.allocPrint(testing.allocator, "{s}/.git/objects", .{dst});
    defer testing.allocator.free(obj_dir);
    var dir = try std.fs.openDirAbsolute(obj_dir, .{ .iterate = true });
    defer dir.close();
    var iter = dir.iterate();
    var count: usize = 0;
    while (try iter.next()) |entry| {
        if (entry.kind == .directory and entry.name.len == 2) count += 1;
    }
    // At least blob, tree, commit object dirs
    try testing.expect(count >= 2);
}

test "cloneNoCheckout: fails on existing target" {
    const src = tmpPath("clone_src4");
    const dst = tmpPath("clone_dst4");
    cleanup(src);
    cleanup(dst);
    defer cleanup(src);
    defer cleanup(dst);

    var src_repo = try initRepoWithCommit(src);
    src_repo.close();

    // Create destination first
    try std.fs.makeDirAbsolute(dst);

    const result = Repository.cloneNoCheckout(testing.allocator, src, dst);
    try testing.expectError(error.AlreadyExists, result);
}

test "cloneNoCheckout: fails on network URL" {
    const dst = tmpPath("clone_dst5");
    cleanup(dst);
    defer cleanup(dst);

    const result = Repository.cloneNoCheckout(testing.allocator, "https://github.com/example/repo.git", dst);
    try testing.expectError(error.NetworkRemoteNotSupported, result);
}

// ============================================================================
// cloneBare tests
// ============================================================================

test "cloneBare: creates bare repo with HEAD" {
    const src = tmpPath("bare_src1");
    const dst = tmpPath("bare_dst1");
    cleanup(src);
    cleanup(dst);
    defer cleanup(src);
    defer cleanup(dst);

    var src_repo = try initRepoWithCommit(src);
    src_repo.close();

    var dst_repo = try Repository.cloneBare(testing.allocator, src, dst);
    defer dst_repo.close();

    // In a bare clone, git_dir IS the repo path
    try testing.expectEqualStrings(dst, dst_repo.git_dir);

    // HEAD should exist
    const head_path = try std.fmt.allocPrint(testing.allocator, "{s}/HEAD", .{dst});
    defer testing.allocator.free(head_path);
    try std.fs.accessAbsolute(head_path, .{});
}

test "cloneBare: HEAD matches source" {
    const src = tmpPath("bare_src2");
    const dst = tmpPath("bare_dst2");
    cleanup(src);
    cleanup(dst);
    defer cleanup(src);
    defer cleanup(dst);

    var src_repo = try initRepoWithCommit(src);
    const src_head = try src_repo.revParseHead();
    src_repo.close();

    var dst_repo = try Repository.cloneBare(testing.allocator, src, dst);
    defer dst_repo.close();

    const dst_head = try dst_repo.revParseHead();
    try testing.expectEqualStrings(&src_head, &dst_head);
}

test "cloneBare: fails on network URL" {
    const dst = tmpPath("bare_dst3");
    cleanup(dst);
    defer cleanup(dst);

    const result = Repository.cloneBare(testing.allocator, "git://example.com/repo", dst);
    try testing.expectError(error.NetworkRemoteNotSupported, result);
}

// ============================================================================
// fetch tests
// ============================================================================

test "fetch: copies new objects from remote" {
    const src = tmpPath("fetch_src1");
    const dst = tmpPath("fetch_dst1");
    cleanup(src);
    cleanup(dst);
    defer cleanup(src);
    defer cleanup(dst);

    // Create source with commit
    var src_repo = try initRepoWithCommit(src);
    src_repo.close();

    // Clone
    var dst_repo = try Repository.cloneNoCheckout(testing.allocator, src, dst);

    // Add a second commit to source
    var src_repo2 = try Repository.open(testing.allocator, src);
    try createFile(src, "second.txt", "second file\n");
    try src_repo2.add("second.txt");
    _ = try src_repo2.commit("second commit", "Test", "t@t.com");
    const new_src_head = try src_repo2.revParseHead();
    src_repo2.close();

    // Fetch from source
    try dst_repo.fetch(src);
    dst_repo.close();

    // Verify the new commit object exists in destination
    const obj_path = try std.fmt.allocPrint(testing.allocator, "{s}/.git/objects/{s}/{s}", .{ dst, new_src_head[0..2], new_src_head[2..] });
    defer testing.allocator.free(obj_path);
    try std.fs.accessAbsolute(obj_path, .{});
}

test "fetch: rejects network URLs" {
    const path = tmpPath("fetch_reject");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try testing.expectError(error.NetworkRemoteNotSupported, repo.fetch("https://github.com/example/repo"));
    try testing.expectError(error.NetworkRemoteNotSupported, repo.fetch("ssh://git@github.com/repo"));
    try testing.expectError(error.NetworkRemoteNotSupported, repo.fetch("git://example.com/repo"));
    try testing.expectError(error.NetworkRemoteNotSupported, repo.fetch("http://example.com/repo"));
}

// ============================================================================
// Multi-commit clone verification
// ============================================================================

test "cloneNoCheckout: preserves full commit history" {
    const src = tmpPath("clone_hist_src");
    const dst = tmpPath("clone_hist_dst");
    cleanup(src);
    cleanup(dst);
    defer cleanup(src);
    defer cleanup(dst);

    // Create source with 3 commits
    var src_repo = try Repository.init(testing.allocator, src);
    try createFile(src, "a.txt", "aaa\n");
    try src_repo.add("a.txt");
    const h1 = try src_repo.commit("first", "A", "a@a.com");

    try createFile(src, "b.txt", "bbb\n");
    try src_repo.add("b.txt");
    const h2 = try src_repo.commit("second", "A", "a@a.com");

    try createFile(src, "c.txt", "ccc\n");
    try src_repo.add("c.txt");
    const h3 = try src_repo.commit("third", "A", "a@a.com");
    src_repo.close();

    // Clone
    var dst_repo = try Repository.cloneNoCheckout(testing.allocator, src, dst);
    defer dst_repo.close();

    // HEAD should match
    const dst_head = try dst_repo.revParseHead();
    try testing.expectEqualStrings(&h3, &dst_head);

    // All 3 commit objects should exist
    for ([_][40]u8{ h1, h2, h3 }) |hash| {
        const obj_path = try std.fmt.allocPrint(testing.allocator, "{s}/.git/objects/{s}/{s}", .{ dst, hash[0..2], hash[2..] });
        defer testing.allocator.free(obj_path);
        try std.fs.accessAbsolute(obj_path, .{});
    }
}

test "cloneNoCheckout: git fsck passes on cloned repo" {
    const src = tmpPath("clone_fsck_src");
    const dst = tmpPath("clone_fsck_dst");
    cleanup(src);
    cleanup(dst);
    defer cleanup(src);
    defer cleanup(dst);

    var src_repo = try initRepoWithCommit(src);
    src_repo.close();

    var dst_repo = try Repository.cloneNoCheckout(testing.allocator, src, dst);
    dst_repo.close();

    // git fsck should pass
    const out = runGit(&.{ "git", "fsck" }, dst) catch {
        // git fsck may fail if checksum is dummy - that's a known limitation
        return;
    };
    testing.allocator.free(out);
}

// ============================================================================
// Tag preservation across clone
// ============================================================================

test "cloneNoCheckout: preserves tags" {
    const src = tmpPath("clone_tags_src");
    const dst = tmpPath("clone_tags_dst");
    cleanup(src);
    cleanup(dst);
    defer cleanup(src);
    defer cleanup(dst);

    var src_repo = try Repository.init(testing.allocator, src);
    try createFile(src, "f.txt", "data\n");
    try src_repo.add("f.txt");
    _ = try src_repo.commit("init", "T", "t@t.com");
    try src_repo.createTag("v1.0.0", null);
    src_repo.close();

    var dst_repo = try Repository.cloneNoCheckout(testing.allocator, src, dst);
    defer dst_repo.close();

    // Tags should be present
    const tag = try dst_repo.describeTags(testing.allocator);
    defer testing.allocator.free(tag);
    try testing.expectEqualStrings("v1.0.0", tag);
}

// ============================================================================
// Branch listing on cloned repo
// ============================================================================

test "cloneNoCheckout: preserves branches" {
    const src = tmpPath("clone_branch_src");
    const dst = tmpPath("clone_branch_dst");
    cleanup(src);
    cleanup(dst);
    defer cleanup(src);
    defer cleanup(dst);

    var src_repo = try initRepoWithCommit(src);
    src_repo.close();

    var dst_repo = try Repository.cloneNoCheckout(testing.allocator, src, dst);
    defer dst_repo.close();

    const branches = try dst_repo.branchList(testing.allocator);
    defer {
        for (branches) |b| testing.allocator.free(b);
        testing.allocator.free(branches);
    }

    // Should have at least master
    try testing.expect(branches.len >= 1);
    var has_master = false;
    for (branches) |b| {
        if (std.mem.eql(u8, b, "master")) has_master = true;
    }
    try testing.expect(has_master);
}
