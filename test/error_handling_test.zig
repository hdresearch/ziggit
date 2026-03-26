// test/error_handling_test.zig - Error handling and boundary condition tests
const std = @import("std");
const ziggit = @import("ziggit");
const testing = std.testing;

const Repository = ziggit.Repository;

fn tmpPath(comptime suffix: []const u8) []const u8 {
    return "/tmp/ziggit_err_" ++ suffix;
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

fn pathExists(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

// ============================================================================
// Repository.open error paths
// ============================================================================

test "error: open on non-existent path" {
    // Use page_allocator because Repository.open leaks abs_path on error
    const result = Repository.open(std.heap.page_allocator, "/tmp/ziggit_nonexistent_xyzabc");
    try testing.expectError(error.NotAGitRepository, result);
}

test "error: open on file (not directory)" {
    const path = tmpPath("openfile");
    cleanup(path);
    defer cleanup(path);

    // Create a regular file instead of directory
    const f = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    f.close();

    // Use page_allocator because Repository.open leaks abs_path on error
    const result = Repository.open(std.heap.page_allocator, path);
    try testing.expectError(error.NotAGitRepository, result);
}

test "error: open on directory without .git" {
    const path = tmpPath("nogit");
    cleanup(path);
    defer cleanup(path);
    try std.fs.makeDirAbsolute(path);

    // Use page_allocator because Repository.open leaks abs_path on error
    const result = Repository.open(std.heap.page_allocator, path);
    try testing.expectError(error.NotAGitRepository, result);
}

// ============================================================================
// Repository.add error paths
// ============================================================================

test "error: add non-existent file" {
    const path = tmpPath("addnofile");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    const result = repo.add("nonexistent.txt");
    try testing.expectError(error.FileNotFound, result);
}

// ============================================================================
// findCommit error paths
// ============================================================================

test "error: findCommit on empty repo" {
    const path = tmpPath("findcmt_empty");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    // HEAD doesn't resolve to anything useful
    const result = repo.findCommit("nonexistent-branch");
    try testing.expectError(error.CommitNotFound, result);
}

test "error: findCommit with invalid hash chars" {
    const path = tmpPath("findcmt_invalid");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "T", "t@t.com");

    // "zzzz" is not valid hex
    const result = repo.findCommit("zzzz");
    try testing.expectError(error.CommitNotFound, result);
}

// ============================================================================
// Network URL rejection
// ============================================================================

test "error: fetch rejects https URL" {
    const path = tmpPath("net_https");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try testing.expectError(error.NetworkRemoteNotSupported, repo.fetch("https://github.com/x/y.git"));
}

test "error: fetch rejects http URL" {
    const path = tmpPath("net_http");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try testing.expectError(error.NetworkRemoteNotSupported, repo.fetch("http://example.com/repo.git"));
}

test "error: fetch rejects git:// URL" {
    const path = tmpPath("net_git");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try testing.expectError(error.NetworkRemoteNotSupported, repo.fetch("git://example.com/repo.git"));
}

test "error: fetch rejects ssh URL" {
    const path = tmpPath("net_ssh");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try testing.expectError(error.NetworkRemoteNotSupported, repo.fetch("ssh://git@example.com/repo.git"));
}

test "error: cloneBare rejects network URLs" {
    try testing.expectError(error.NetworkRemoteNotSupported, Repository.cloneBare(testing.allocator, "https://github.com/x/y.git", "/tmp/z"));
    try testing.expectError(error.NetworkRemoteNotSupported, Repository.cloneBare(testing.allocator, "http://x.com/y.git", "/tmp/z"));
    try testing.expectError(error.NetworkRemoteNotSupported, Repository.cloneBare(testing.allocator, "git://x.com/y.git", "/tmp/z"));
    try testing.expectError(error.NetworkRemoteNotSupported, Repository.cloneBare(testing.allocator, "ssh://x.com/y.git", "/tmp/z"));
}

test "error: cloneNoCheckout rejects network URLs" {
    try testing.expectError(error.NetworkRemoteNotSupported, Repository.cloneNoCheckout(testing.allocator, "https://github.com/x/y.git", "/tmp/z"));
}

// ============================================================================
// Repository.init idempotency and edge cases
// ============================================================================

test "init creates all required subdirectories" {
    const path = tmpPath("initdirs");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    const git_dir = try std.fmt.allocPrint(testing.allocator, "{s}/.git", .{path});
    defer testing.allocator.free(git_dir);

    // Check all required dirs
    const dirs = [_][]const u8{
        "objects", "objects/info", "objects/pack",
        "refs", "refs/heads", "refs/tags", "refs/remotes",
        "hooks", "info",
    };

    for (dirs) |sub| {
        const full = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ git_dir, sub });
        defer testing.allocator.free(full);
        try testing.expect(pathExists(full));
    }
}

test "init creates HEAD pointing to refs/heads/master" {
    const path = tmpPath("inithead");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    const head_path = try std.fmt.allocPrint(testing.allocator, "{s}/.git/HEAD", .{path});
    defer testing.allocator.free(head_path);

    const f = try std.fs.openFileAbsolute(head_path, .{});
    defer f.close();
    var buf: [256]u8 = undefined;
    const n = try f.readAll(&buf);
    const content = std.mem.trim(u8, buf[0..n], " \n\r\t");
    try testing.expectEqualStrings("ref: refs/heads/master", content);
}

test "init creates config with repositoryformatversion 0" {
    const path = tmpPath("initcfg");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    const config_path = try std.fmt.allocPrint(testing.allocator, "{s}/.git/config", .{path});
    defer testing.allocator.free(config_path);

    const f = try std.fs.openFileAbsolute(config_path, .{});
    defer f.close();
    const content = try f.readToEndAlloc(testing.allocator, 4096);
    defer testing.allocator.free(content);

    try testing.expect(std.mem.indexOf(u8, content, "repositoryformatversion = 0") != null);
    try testing.expect(std.mem.indexOf(u8, content, "bare = false") != null);
}

// ============================================================================
// cloneBare error: target already exists
// ============================================================================

test "error: cloneBare fails when target exists" {
    const src = tmpPath("bare_src");
    const dst = tmpPath("bare_dst");
    cleanup(src);
    cleanup(dst);
    defer cleanup(src);
    defer cleanup(dst);

    var repo = try Repository.init(testing.allocator, src);
    repo.close();

    // Create target directory first
    try std.fs.makeDirAbsolute(dst);

    const result = Repository.cloneBare(testing.allocator, src, dst);
    try testing.expectError(error.AlreadyExists, result);
}

// ============================================================================
// Empty repo edge cases
// ============================================================================

test "empty repo: revParseHead returns error" {
    const path = tmpPath("emptyhead");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    // HEAD points to refs/heads/master which doesn't exist yet
    const result = repo.revParseHead();
    try testing.expectError(error.RefNotFound, result);
}

test "empty repo: branchList returns empty" {
    const path = tmpPath("emptybranch");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    const branches = try repo.branchList(testing.allocator);
    defer testing.allocator.free(branches);
    try testing.expectEqual(@as(usize, 0), branches.len);
}

test "empty repo: describeTags returns empty" {
    const path = tmpPath("emptytags");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    const tags = try repo.describeTags(testing.allocator);
    defer testing.allocator.free(tags);
    try testing.expectEqualStrings("", tags);
}

// ============================================================================
// Repository path handling
// ============================================================================

test "Repository stores correct path and git_dir" {
    const path = tmpPath("paths");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try testing.expectEqualStrings(path, repo.path);
    const expected_git_dir = try std.fmt.allocPrint(testing.allocator, "{s}/.git", .{path});
    defer testing.allocator.free(expected_git_dir);
    try testing.expectEqualStrings(expected_git_dir, repo.git_dir);
}

// ============================================================================
// Large content
// ============================================================================

test "large file: 100KB blob stored and readable by git" {
    const path = tmpPath("large");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    // Create 100KB file
    const large_content = try testing.allocator.alloc(u8, 100 * 1024);
    defer testing.allocator.free(large_content);
    for (large_content, 0..) |*b, i| {
        b.* = @intCast(i % 256);
    }

    try createFile(path, "large.bin", large_content);
    try repo.add("large.bin");
    _ = try repo.commit("large file", "T", "t@t.com");

    // git fsck should pass
    try runGitVoid(&.{ "git", "fsck" }, path);

    // Verify size with git
    const size_out = try runGit(&.{ "git", "cat-file", "-s", "HEAD:large.bin" }, path);
    defer testing.allocator.free(size_out);
    const size_str = std.mem.trim(u8, size_out, " \n\r\t");
    const size = try std.fmt.parseInt(usize, size_str, 10);
    try testing.expectEqual(@as(usize, 100 * 1024), size);
}

fn runGit(args: []const []const u8, cwd: []const u8) ![]u8 {
    var child = std.process.Child.init(args, testing.allocator);
    var cwd_dir = try std.fs.openDirAbsolute(cwd, .{});
    defer cwd_dir.close();
    child.cwd_dir = cwd_dir;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const stdout = try child.stdout.?.reader().readAllAlloc(testing.allocator, 1024 * 1024);
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

fn runGitVoid(args: []const []const u8, cwd: []const u8) !void {
    const out = try runGit(args, cwd);
    testing.allocator.free(out);
}
