// test/edge_cases_test.zig - Edge case tests for ziggit
// Tests: empty repos, binary files, unicode, large files, concurrent operations, error paths
const std = @import("std");
const ziggit = @import("ziggit");
const testing = std.testing;

const Repository = ziggit.Repository;

fn tmpPath(comptime suffix: []const u8) []const u8 {
    return "/tmp/ziggit_edge_test_" ++ suffix;
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
    return try f.readToEndAlloc(testing.allocator, 10 * 1024 * 1024);
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

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \n\r\t");
}

// ============================================================================
// Empty repository edge cases
// ============================================================================

test "empty repo: revParseHead returns zeros or error" {
    const path = tmpPath("empty_head");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    const result = repo.revParseHead();
    if (result) |head| {
        const zeros = [_]u8{'0'} ** 40;
        try testing.expectEqualStrings(&zeros, &head);
    } else |_| {
        // Error is also acceptable
    }
}

test "empty repo: branchList returns empty" {
    const path = tmpPath("empty_branches");
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

test "empty repo: describeTags returns empty" {
    const path = tmpPath("empty_tags");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    const tag = try repo.describeTags(testing.allocator);
    defer testing.allocator.free(tag);
    try testing.expectEqualStrings("", tag);
}

test "empty repo: isClean returns true" {
    const path = tmpPath("empty_clean");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    const clean = try repo.isClean();
    try testing.expect(clean);
}

test "empty repo: findCommit HEAD returns zeros or error" {
    const path = tmpPath("empty_findcommit");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    const result = repo.findCommit("HEAD");
    if (result) |found| {
        const zeros = [_]u8{'0'} ** 40;
        try testing.expectEqualStrings(&zeros, &found);
    } else |_| {}
}

// ============================================================================
// Binary file edge cases
// ============================================================================

test "binary: all byte values 0-255" {
    const path = tmpPath("binary_allbytes");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    var all_bytes: [256]u8 = undefined;
    for (&all_bytes, 0..) |*b, i| b.* = @intCast(i);

    try createFile(path, "allbytes.bin", &all_bytes);
    try repo.add("allbytes.bin");
    _ = try repo.commit("all bytes", "A", "a@a.com");

    // Verify via git
    const cat = try runGit(&.{ "git", "cat-file", "blob", "HEAD:allbytes.bin" }, path);
    defer testing.allocator.free(cat);
    try testing.expectEqual(@as(usize, 256), cat.len);
    for (cat, 0..) |b, i| {
        try testing.expectEqual(@as(u8, @intCast(i)), b);
    }
}

test "binary: large file with repeated pattern" {
    const path = tmpPath("binary_large");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    // 512KB file
    const size = 512 * 1024;
    const data = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(data);
    for (data, 0..) |*b, i| b.* = @intCast(i % 256);

    try createFile(path, "large.bin", data);
    try repo.add("large.bin");
    _ = try repo.commit("large binary", "A", "a@a.com");

    // Verify size via git
    const size_out = try runGit(&.{ "git", "cat-file", "-s", "HEAD:large.bin" }, path);
    defer testing.allocator.free(size_out);
    const reported_size = try std.fmt.parseInt(usize, trim(size_out), 10);
    try testing.expectEqual(size, reported_size);
}

// ============================================================================
// Unicode and special character edge cases
// ============================================================================

test "unicode: commit message with emoji" {
    const path = tmpPath("unicode_emoji");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    _ = try repo.commit("🚀 Initial release 🎉", "A", "a@a.com");

    const log = try runGit(&.{ "git", "log", "--oneline" }, path);
    defer testing.allocator.free(log);
    try testing.expect(std.mem.indexOf(u8, log, "🚀") != null);
}

test "unicode: author name with non-ASCII" {
    const path = tmpPath("unicode_author");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    _ = try repo.commit("test", "José García", "jose@example.com");

    const show = try runGit(&.{ "git", "cat-file", "-p", "HEAD" }, path);
    defer testing.allocator.free(show);
    try testing.expect(std.mem.indexOf(u8, show, "José García") != null);
}

test "unicode: file content with various scripts" {
    const path = tmpPath("unicode_content");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    const content = "Hello 世界 Привет мир مرحبا\n";
    try createFile(path, "multilang.txt", content);
    try repo.add("multilang.txt");
    _ = try repo.commit("multilang", "A", "a@a.com");

    const show = try runGit(&.{ "git", "show", "HEAD:multilang.txt" }, path);
    defer testing.allocator.free(show);
    try testing.expectEqualStrings(content, show);
}

// ============================================================================
// Special filenames
// ============================================================================

test "filename with spaces" {
    const path = tmpPath("fname_spaces");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "hello world.txt", "spaced\n");
    try repo.add("hello world.txt");
    _ = try repo.commit("spaces", "A", "a@a.com");

    const ls = try runGit(&.{ "git", "ls-tree", "--name-only", "HEAD" }, path);
    defer testing.allocator.free(ls);
    try testing.expect(std.mem.indexOf(u8, ls, "hello world.txt") != null);
}

test "filename with dots" {
    const path = tmpPath("fname_dots");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, ".hidden", "hidden\n");
    try repo.add(".hidden");
    try createFile(path, "file.tar.gz", "archive\n");
    try repo.add("file.tar.gz");
    _ = try repo.commit("dots", "A", "a@a.com");

    const ls = try runGit(&.{ "git", "ls-tree", "--name-only", "HEAD" }, path);
    defer testing.allocator.free(ls);
    try testing.expect(std.mem.indexOf(u8, ls, ".hidden") != null);
    try testing.expect(std.mem.indexOf(u8, ls, "file.tar.gz") != null);
}

test "filename with dashes and underscores" {
    const path = tmpPath("fname_dashes");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "my-file_v2.txt", "content\n");
    try repo.add("my-file_v2.txt");
    _ = try repo.commit("dashes", "A", "a@a.com");

    const ls = try runGit(&.{ "git", "ls-tree", "--name-only", "HEAD" }, path);
    defer testing.allocator.free(ls);
    try testing.expect(std.mem.indexOf(u8, ls, "my-file_v2.txt") != null);
}

// ============================================================================
// Commit message edge cases
// ============================================================================

test "commit with very long message" {
    const path = tmpPath("msg_long");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "x\n");
    try repo.add("f.txt");

    const long_msg = "A" ** 4096;
    _ = try repo.commit(long_msg, "A", "a@a.com");

    const show = try runGit(&.{ "git", "cat-file", "-p", "HEAD" }, path);
    defer testing.allocator.free(show);
    try testing.expect(std.mem.indexOf(u8, show, long_msg) != null);
}

test "commit with multiline message" {
    const path = tmpPath("msg_multiline");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "x\n");
    try repo.add("f.txt");

    const msg = "First line\n\nDetailed description\n- bullet point 1\n- bullet point 2";
    _ = try repo.commit(msg, "A", "a@a.com");

    const show = try runGit(&.{ "git", "cat-file", "-p", "HEAD" }, path);
    defer testing.allocator.free(show);
    try testing.expect(std.mem.indexOf(u8, show, "First line") != null);
    try testing.expect(std.mem.indexOf(u8, show, "bullet point 2") != null);
}

test "commit with empty-ish message" {
    const path = tmpPath("msg_short");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    _ = try repo.commit("x", "A", "a@a.com");

    const show = try runGit(&.{ "git", "cat-file", "-p", "HEAD" }, path);
    defer testing.allocator.free(show);
    try testing.expect(std.mem.indexOf(u8, show, "\nx\n") != null);
}

// ============================================================================
// Repository state after operations
// ============================================================================

test "HEAD updates correctly through multiple commits" {
    const path = tmpPath("head_updates");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    var prev_head = [_]u8{'0'} ** 40;

    var i: usize = 0;
    while (i < 5) : (i += 1) {
        var buf: [32]u8 = undefined;
        const content = std.fmt.bufPrint(&buf, "v{d}\n", .{i}) catch unreachable;
        try createFile(path, "f.txt", content);
        try repo.add("f.txt");
        var msg_buf: [32]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "commit {d}", .{i}) catch unreachable;
        const new_hash = try repo.commit(msg, "A", "a@a.com");
        const head = try repo.revParseHead();

        try testing.expectEqualStrings(&new_hash, &head);
        try testing.expect(!std.mem.eql(u8, &prev_head, &head));
        prev_head = head;
    }
}

test "tag created after multiple commits points to latest" {
    const path = tmpPath("tag_latest_commit");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "v1\n");
    try repo.add("f.txt");
    _ = try repo.commit("first", "A", "a@a.com");

    try createFile(path, "f.txt", "v2\n");
    try repo.add("f.txt");
    const hash2 = try repo.commit("second", "A", "a@a.com");

    try repo.createTag("v1.0.0", null);

    // Tag should point to second commit (HEAD)
    const tag_rev = try runGit(&.{ "git", "rev-parse", "v1.0.0" }, path);
    defer testing.allocator.free(tag_rev);
    try testing.expectEqualStrings(&hash2, trim(tag_rev));
}

// ============================================================================
// Clone edge cases
// ============================================================================

test "cloneBare creates bare repo" {
    const src = tmpPath("clone_bare_src");
    const dst = tmpPath("clone_bare_dst");
    cleanup(src);
    cleanup(dst);
    defer cleanup(src);
    defer cleanup(dst);

    {
        var repo = try Repository.init(testing.allocator, src);
        defer repo.close();
        try createFile(src, "f.txt", "x\n");
        try repo.add("f.txt");
        _ = try repo.commit("init", "A", "a@a.com");
    }

    var cloned = try Repository.cloneBare(testing.allocator, src, dst);
    defer cloned.close();

    // Bare repo should have HEAD directly in the clone path
    const head_path = try std.fmt.allocPrint(testing.allocator, "{s}/HEAD", .{dst});
    defer testing.allocator.free(head_path);
    std.fs.accessAbsolute(head_path, .{}) catch {
        try testing.expect(false); // HEAD should exist
    };
}

test "cloneNoCheckout preserves commit history" {
    const src = tmpPath("clone_noco_src");
    const dst = tmpPath("clone_noco_dst");
    cleanup(src);
    cleanup(dst);
    defer cleanup(src);
    defer cleanup(dst);

    var src_hash: [40]u8 = undefined;
    {
        var repo = try Repository.init(testing.allocator, src);
        defer repo.close();
        try createFile(src, "f.txt", "data\n");
        try repo.add("f.txt");
        src_hash = try repo.commit("init", "A", "a@a.com");
    }

    var cloned = try Repository.cloneNoCheckout(testing.allocator, src, dst);
    defer cloned.close();

    const head = try cloned.revParseHead();
    try testing.expectEqualStrings(&src_hash, &head);
}

// ============================================================================
// Fetch edge cases
// ============================================================================

test "fetch from local repo copies objects" {
    const src = tmpPath("fetch_src2");
    const dst = tmpPath("fetch_dst2");
    cleanup(src);
    cleanup(dst);
    defer cleanup(src);
    defer cleanup(dst);

    {
        var repo = try Repository.init(testing.allocator, src);
        defer repo.close();
        try createFile(src, "f.txt", "remote data\n");
        try repo.add("f.txt");
        _ = try repo.commit("remote commit", "A", "a@a.com");
    }

    var dst_repo = try Repository.init(testing.allocator, dst);
    defer dst_repo.close();

    try dst_repo.fetch(src);

    // Remote refs should exist
    const refs_dir = try std.fmt.allocPrint(testing.allocator, "{s}/.git/refs/remotes/origin", .{dst});
    defer testing.allocator.free(refs_dir);
    std.fs.accessAbsolute(refs_dir, .{}) catch {
        try testing.expect(false);
    };
}

test "fetch rejects http URLs" {
    const path = tmpPath("fetch_http");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try testing.expectError(error.NetworkRemoteNotSupported, repo.fetch("http://example.com/repo.git"));
}

test "fetch rejects https URLs" {
    const path = tmpPath("fetch_https");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try testing.expectError(error.NetworkRemoteNotSupported, repo.fetch("https://github.com/user/repo"));
}

test "fetch rejects ssh URLs" {
    const path = tmpPath("fetch_ssh");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try testing.expectError(error.NetworkRemoteNotSupported, repo.fetch("ssh://git@github.com/user/repo"));
}

test "fetch rejects git:// URLs" {
    const path = tmpPath("fetch_git");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try testing.expectError(error.NetworkRemoteNotSupported, repo.fetch("git://example.com/repo.git"));
}

// ============================================================================
// Error path tests
// ============================================================================

test "open nonexistent path returns error" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const result = Repository.open(arena.allocator(), "/tmp/ziggit_definitely_does_not_exist_xyz_abc_123");
    try testing.expectError(error.NotAGitRepository, result);
}

test "open plain directory returns error" {
    const path = tmpPath("open_plain");
    cleanup(path);
    defer cleanup(path);
    try std.fs.makeDirAbsolute(path);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const result = Repository.open(arena.allocator(), path);
    try testing.expectError(error.NotAGitRepository, result);
}

test "add nonexistent file returns error" {
    const path = tmpPath("add_nonexist");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    const result = repo.add("does_not_exist.txt");
    try testing.expectError(error.FileNotFound, result);
}

test "findCommit with invalid ref returns error" {
    const path = tmpPath("find_invalid");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "A", "a@a.com");

    try testing.expectError(error.CommitNotFound, repo.findCommit("nonexistent_branch_xyz"));
}

// ============================================================================
// Short hash expansion
// ============================================================================

test "findCommit resolves short hash" {
    const path = tmpPath("short_hash");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    const full_hash = try repo.commit("init", "A", "a@a.com");

    // Try with 7-char prefix
    const short = full_hash[0..7];
    const found = try repo.findCommit(short);
    try testing.expectEqualStrings(&full_hash, &found);
}

test "findCommit resolves 4-char short hash" {
    const path = tmpPath("short_hash_4");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    const full_hash = try repo.commit("init", "A", "a@a.com");

    const short = full_hash[0..4];
    const found = try repo.findCommit(short);
    try testing.expectEqualStrings(&full_hash, &found);
}

// ============================================================================
// Checkout edge cases
// ============================================================================

test "checkout restores deleted file" {
    const path = tmpPath("checkout_restore");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "important.txt", "important data\n");
    try repo.add("important.txt");
    const hash = try repo.commit("save", "A", "a@a.com");

    // Delete the file
    const file_path = try std.fmt.allocPrint(testing.allocator, "{s}/important.txt", .{path});
    defer testing.allocator.free(file_path);
    try std.fs.deleteFileAbsolute(file_path);

    // Checkout should restore it
    try repo.checkout(&hash);

    const content = try readFileContent(path, "important.txt");
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("important data\n", content);
}

test "checkout between two different states" {
    const path = tmpPath("checkout_switch");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    // State 1
    try createFile(path, "state.txt", "state one\n");
    try repo.add("state.txt");
    const hash1 = try repo.commit("state 1", "A", "a@a.com");

    // State 2
    try createFile(path, "state.txt", "state two\n");
    try repo.add("state.txt");
    const hash2 = try repo.commit("state 2", "A", "a@a.com");

    // Go to state 1
    try repo.checkout(&hash1);
    {
        const content = try readFileContent(path, "state.txt");
        defer testing.allocator.free(content);
        try testing.expectEqualStrings("state one\n", content);
    }

    // Go back to state 2
    try repo.checkout(&hash2);
    {
        const content = try readFileContent(path, "state.txt");
        defer testing.allocator.free(content);
        try testing.expectEqualStrings("state two\n", content);
    }
}

// ============================================================================
// Multiple tag operations
// ============================================================================

test "create and list many tags" {
    const path = tmpPath("many_tags");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "A", "a@a.com");

    // Create 20 tags
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "v0.{d}.0", .{i}) catch unreachable;
        try repo.createTag(name, null);
    }

    // Verify all tags via git
    const tags_out = try runGit(&.{ "git", "tag", "-l" }, path);
    defer testing.allocator.free(tags_out);

    i = 0;
    while (i < 20) : (i += 1) {
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "v0.{d}.0", .{i}) catch unreachable;
        try testing.expect(std.mem.indexOf(u8, tags_out, name) != null);
    }
}

test "describeTags returns lexicographically latest" {
    const path = tmpPath("describe_lex");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "A", "a@a.com");

    try repo.createTag("alpha", null);
    try repo.createTag("zeta", null);
    try repo.createTag("beta", null);

    const tag = try repo.describeTags(testing.allocator);
    defer testing.allocator.free(tag);
    try testing.expectEqualStrings("zeta", tag);
}
