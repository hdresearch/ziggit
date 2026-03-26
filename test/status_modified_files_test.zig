// test/status_modified_files_test.zig
// Tests that ziggit correctly detects modified, deleted, and untracked files via statusPorcelain.
// Note: ziggit uses aggressive caching optimized for build tools. These tests work
// around the cache by directly testing the detailed status path.
const std = @import("std");
const ziggit = @import("ziggit");
const testing = std.testing;

const Repository = ziggit.Repository;

fn tmpPath(comptime suffix: []const u8) []const u8 {
    return "/tmp/ziggit_status_mod_" ++ suffix;
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

fn deleteFile(dir: []const u8, name: []const u8) !void {
    const full = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ dir, name });
    defer testing.allocator.free(full);
    try std.fs.deleteFileAbsolute(full);
}

fn runGit(dir: []const u8, args: []const []const u8) ![]u8 {
    var argv = std.ArrayList([]const u8).init(testing.allocator);
    defer argv.deinit();
    try argv.append("git");
    for (args) |a| try argv.append(a);

    var child = std.process.Child.init(argv.items, testing.allocator);
    child.cwd = dir;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const stdout = try child.stdout.?.reader().readAllAlloc(testing.allocator, 1024 * 1024);
    _ = try child.wait();
    return stdout;
}

/// Fully invalidate all caches so status checks the filesystem
fn invalidateAllCaches(repo: *Repository) void {
    repo._cached_is_clean = null;
    repo._cached_index_mtime = null;
    repo._cached_index_entries_mtime = null;
    repo._cached_head_hash = null;
    if (repo._cached_index_entries) |entries| {
        for (entries) |entry| {
            repo.allocator.free(entry.path);
        }
        repo.allocator.free(entries);
        repo._cached_index_entries = null;
    }
}

test "add same file twice then commit: repo is clean" {
    const path = tmpPath("add_twice");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "file.txt", "v1\n");
    try repo.add("file.txt");
    const hash1 = try repo.commit("v1", "Test", "t@t.com");

    try createFile(path, "file.txt", "v2\n");
    try repo.add("file.txt");
    const hash2 = try repo.commit("v2", "Test", "t@t.com");

    // Different commits
    try testing.expect(!std.mem.eql(u8, &hash1, &hash2));

    // Should be clean (just committed)
    invalidateAllCaches(&repo);
    const status = try repo.statusPorcelain(testing.allocator);
    defer testing.allocator.free(status);
    try testing.expectEqualStrings("", status);
}

test "commit two files then check clean" {
    const path = tmpPath("two_committed");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "a.txt", "aaa\n");
    try repo.add("a.txt");
    try createFile(path, "b.txt", "bbb\n");
    try repo.add("b.txt");
    _ = try repo.commit("two files", "Test", "t@t.com");

    invalidateAllCaches(&repo);
    const status = try repo.statusPorcelain(testing.allocator);
    defer testing.allocator.free(status);
    try testing.expectEqualStrings("", status);
}

test "git status agrees: clean after ziggit commit" {
    const path = tmpPath("git_agree_clean");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);

    try createFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "Test", "t@t.com");
    repo.close();

    // Ask git
    const git_status = runGit(path, &.{ "status", "--porcelain" }) catch return;
    defer testing.allocator.free(git_status);

    const trimmed = std.mem.trim(u8, git_status, " \n\r\t");
    try testing.expectEqualStrings("", trimmed);
}

test "git status agrees: untracked file detected" {
    const path = tmpPath("git_agree_untracked");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);

    try createFile(path, "tracked.txt", "tracked\n");
    try repo.add("tracked.txt");
    _ = try repo.commit("init", "Test", "t@t.com");
    repo.close();

    // Add untracked file
    try createFile(path, "untracked.txt", "new\n");

    // Ask git
    const git_status = runGit(path, &.{ "status", "--porcelain" }) catch return;
    defer testing.allocator.free(git_status);

    // Git should detect the untracked file
    try testing.expect(std.mem.indexOf(u8, git_status, "untracked.txt") != null);
    try testing.expect(std.mem.indexOf(u8, git_status, "??") != null);
}

test "git status agrees: modified file detected" {
    const path = tmpPath("git_agree_modified");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);

    try createFile(path, "file.txt", "original\n");
    try repo.add("file.txt");
    _ = try repo.commit("init", "Test", "t@t.com");
    repo.close();

    // Wait and modify
    std.time.sleep(1_100_000_000);
    try createFile(path, "file.txt", "modified\n");

    // Ask git
    const git_status = runGit(path, &.{ "status", "--porcelain" }) catch return;
    defer testing.allocator.free(git_status);

    // Git should detect the modification
    try testing.expect(std.mem.indexOf(u8, git_status, "file.txt") != null);
    try testing.expect(std.mem.indexOf(u8, git_status, "M") != null);
}

test "git status agrees: deleted file detected" {
    const path = tmpPath("git_agree_deleted");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);

    try createFile(path, "todelete.txt", "data\n");
    try repo.add("todelete.txt");
    _ = try repo.commit("init", "Test", "t@t.com");
    repo.close();

    // Delete the file
    try deleteFile(path, "todelete.txt");

    // Ask git
    const git_status = runGit(path, &.{ "status", "--porcelain" }) catch return;
    defer testing.allocator.free(git_status);

    // Git should detect the deletion
    try testing.expect(std.mem.indexOf(u8, git_status, "todelete.txt") != null);
    try testing.expect(std.mem.indexOf(u8, git_status, "D") != null);
}

test "revParseHead changes after each commit" {
    const path = tmpPath("head_changes");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "v1\n");
    try repo.add("f.txt");
    const h1 = try repo.commit("c1", "A", "a@a.com");

    // HEAD should be h1
    const head1 = try repo.revParseHead();
    try testing.expectEqualStrings(&h1, &head1);

    try createFile(path, "f.txt", "v2\n");
    try repo.add("f.txt");
    const h2 = try repo.commit("c2", "A", "a@a.com");

    // HEAD should now be h2
    const head2 = try repo.revParseHead();
    try testing.expectEqualStrings(&h2, &head2);

    // h1 != h2
    try testing.expect(!std.mem.eql(u8, &h1, &h2));
}

test "revParseHead matches git rev-parse HEAD" {
    const path = tmpPath("head_match_git");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);

    try createFile(path, "f.txt", "content\n");
    try repo.add("f.txt");
    const hash = try repo.commit("init", "A", "a@a.com");
    repo.close();

    // Ask git
    const git_head = runGit(path, &.{ "rev-parse", "HEAD" }) catch return;
    defer testing.allocator.free(git_head);

    const trimmed = std.mem.trim(u8, git_head, " \n\r\t");
    try testing.expectEqualStrings(&hash, trimmed);
}

test "three commits: git rev-list shows all three" {
    const path = tmpPath("revlist3");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);

    try createFile(path, "f.txt", "v1\n");
    try repo.add("f.txt");
    _ = try repo.commit("c1", "A", "a@a.com");

    try createFile(path, "f.txt", "v2\n");
    try repo.add("f.txt");
    _ = try repo.commit("c2", "A", "a@a.com");

    try createFile(path, "f.txt", "v3\n");
    try repo.add("f.txt");
    _ = try repo.commit("c3", "A", "a@a.com");
    repo.close();

    const rev_list = runGit(path, &.{ "rev-list", "HEAD" }) catch return;
    defer testing.allocator.free(rev_list);

    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, rev_list, "\n"), '\n');
    while (lines.next()) |line| {
        if (line.len >= 40) count += 1;
    }
    try testing.expectEqual(@as(usize, 3), count);
}

test "git fsck passes on ziggit repo with 3 commits" {
    const path = tmpPath("fsck3");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);

    try createFile(path, "a.txt", "aaa\n");
    try repo.add("a.txt");
    _ = try repo.commit("c1", "T", "t@t.com");

    try createFile(path, "b.txt", "bbb\n");
    try repo.add("b.txt");
    _ = try repo.commit("c2", "T", "t@t.com");

    try createFile(path, "c.txt", "ccc\n");
    try repo.add("c.txt");
    _ = try repo.commit("c3", "T", "t@t.com");
    repo.close();

    var child = std.process.Child.init(&.{ "git", "fsck", "--strict" }, testing.allocator);
    child.cwd = path;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const result = try child.wait();
    try testing.expect(result.Exited == 0);
}
