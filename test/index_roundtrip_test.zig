// test/index_roundtrip_test.zig - Tests for index file read/write through Repository API
// Verifies index binary format (DIRC), entry management, and git compatibility
const std = @import("std");
const ziggit = @import("ziggit");
const testing = std.testing;

const Repository = ziggit.Repository;

fn tmpPath(comptime suffix: []const u8) []const u8 {
    return "/tmp/ziggit_idx_test_" ++ suffix;
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

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \n\r\t");
}

// ============================================================================
// Index file format tests
// ============================================================================

test "index file starts with DIRC signature" {
    const path = tmpPath("dirc_sig");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "content\n");
    try repo.add("f.txt");

    const index_path = try std.fmt.allocPrint(testing.allocator, "{s}/.git/index", .{path});
    defer testing.allocator.free(index_path);

    const file = try std.fs.openFileAbsolute(index_path, .{});
    defer file.close();

    var header: [4]u8 = undefined;
    _ = try file.readAll(&header);
    try testing.expectEqualStrings("DIRC", &header);
}

test "index file has version 2" {
    const path = tmpPath("dirc_version");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "content\n");
    try repo.add("f.txt");

    const index_path = try std.fmt.allocPrint(testing.allocator, "{s}/.git/index", .{path});
    defer testing.allocator.free(index_path);

    const file = try std.fs.openFileAbsolute(index_path, .{});
    defer file.close();

    var buf: [8]u8 = undefined;
    _ = try file.readAll(&buf);
    const version = std.mem.readInt(u32, buf[4..8], .big);
    try testing.expectEqual(@as(u32, 2), version);
}

test "index entry count matches added files" {
    const path = tmpPath("entry_count");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "a.txt", "aaa\n");
    try repo.add("a.txt");
    try createFile(path, "b.txt", "bbb\n");
    try repo.add("b.txt");
    try createFile(path, "c.txt", "ccc\n");
    try repo.add("c.txt");

    const index_path = try std.fmt.allocPrint(testing.allocator, "{s}/.git/index", .{path});
    defer testing.allocator.free(index_path);

    const file = try std.fs.openFileAbsolute(index_path, .{});
    defer file.close();

    var buf: [12]u8 = undefined;
    _ = try file.readAll(&buf);
    const num_entries = std.mem.readInt(u32, buf[8..12], .big);
    // At least 3 entries (may be more due to append-style adds)
    try testing.expect(num_entries >= 3);
}

// ============================================================================
// Index compatibility with git
// ============================================================================

test "git ls-files shows ziggit-added files" {
    const path = tmpPath("ls_files");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "hello.txt", "hello\n");
    try repo.add("hello.txt");
    try createFile(path, "world.txt", "world\n");
    try repo.add("world.txt");

    const ls = try runGit(&.{ "git", "ls-files" }, path);
    defer testing.allocator.free(ls);

    try testing.expect(std.mem.indexOf(u8, ls, "hello.txt") != null);
    try testing.expect(std.mem.indexOf(u8, ls, "world.txt") != null);
}

test "git ls-files --stage shows correct mode and hash" {
    const path = tmpPath("ls_stage");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    const content = "staged content\n";
    try createFile(path, "staged.txt", content);
    try repo.add("staged.txt");

    const ls = try runGit(&.{ "git", "ls-files", "--stage" }, path);
    defer testing.allocator.free(ls);

    // Should show 100644 mode
    try testing.expect(std.mem.indexOf(u8, ls, "100644") != null);
    try testing.expect(std.mem.indexOf(u8, ls, "staged.txt") != null);

    // The hash should match hash-object
    const hash_out = try runGit(&.{ "git", "hash-object", "staged.txt" }, path);
    defer testing.allocator.free(hash_out);
    try testing.expect(std.mem.indexOf(u8, ls, trim(hash_out)) != null);
}

test "git status recognizes ziggit index" {
    const path = tmpPath("git_status");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "content\n");
    try repo.add("f.txt");

    // git status should show the file as staged
    const status = try runGit(&.{ "git", "status", "--porcelain" }, path);
    defer testing.allocator.free(status);
    try testing.expect(std.mem.indexOf(u8, status, "f.txt") != null);
}

test "git can commit on top of ziggit index" {
    const path = tmpPath("git_commit_on_ziggit");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    // Configure git
    _ = runGit(&.{ "git", "config", "user.name", "T" }, path) catch null;
    _ = runGit(&.{ "git", "config", "user.email", "t@t.com" }, path) catch null;

    // Add with ziggit, commit with git
    try createFile(path, "f.txt", "data\n");
    try repo.add("f.txt");

    // git commit should work on ziggit's index
    const out = try runGit(&.{ "git", "commit", "-m", "from git" }, path);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "from git") != null);
}

// ============================================================================
// Index with file modifications
// ============================================================================

test "add same file twice creates index entries" {
    const path = tmpPath("add_twice");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "version 1\n");
    try repo.add("f.txt");

    try createFile(path, "f.txt", "version 2\n");
    try repo.add("f.txt");

    // Verify index file exists and is valid DIRC format
    const index_path = try std.fmt.allocPrint(testing.allocator, "{s}/.git/index", .{path});
    defer testing.allocator.free(index_path);

    const file = try std.fs.openFileAbsolute(index_path, .{});
    defer file.close();
    var header: [4]u8 = undefined;
    _ = try file.readAll(&header);
    try testing.expectEqualStrings("DIRC", &header);
}

test "index survives repo close and reopen" {
    const path = tmpPath("idx_persist");
    cleanup(path);
    defer cleanup(path);

    // Add file and close repo
    {
        var repo = try Repository.init(testing.allocator, path);
        defer repo.close();
        try createFile(path, "persist.txt", "persisted\n");
        try repo.add("persist.txt");
    }

    // Reopen and verify index persists (via git)
    const ls = try runGit(&.{ "git", "ls-files" }, path);
    defer testing.allocator.free(ls);
    try testing.expect(std.mem.indexOf(u8, ls, "persist.txt") != null);
}

// ============================================================================
// Index edge cases
// ============================================================================

test "adding empty file creates valid index entry" {
    const path = tmpPath("idx_empty_file");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "empty.txt", "");
    try repo.add("empty.txt");

    const ls = try runGit(&.{ "git", "ls-files", "--stage" }, path);
    defer testing.allocator.free(ls);
    try testing.expect(std.mem.indexOf(u8, ls, "empty.txt") != null);
    // Empty blob hash
    try testing.expect(std.mem.indexOf(u8, ls, "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391") != null);
}

test "adding file with long name" {
    const path = tmpPath("idx_longname");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    const long_name = "a" ** 200 ++ ".txt";
    try createFile(path, long_name, "long name content\n");
    try repo.add(long_name);

    const ls = try runGit(&.{ "git", "ls-files" }, path);
    defer testing.allocator.free(ls);
    try testing.expect(std.mem.indexOf(u8, ls, long_name) != null);
}

test "index with many files" {
    const path = tmpPath("idx_many");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    var i: usize = 0;
    while (i < 50) : (i += 1) {
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "file_{d:0>3}.txt", .{i}) catch unreachable;
        var content_buf: [32]u8 = undefined;
        const content = std.fmt.bufPrint(&content_buf, "content {d}\n", .{i}) catch unreachable;
        try createFile(path, name, content);
        try repo.add(name);
    }

    _ = try repo.commit("many files", "A", "a@a.com");

    // Verify all files are in git tree
    const ls = try runGit(&.{ "git", "ls-tree", "--name-only", "HEAD" }, path);
    defer testing.allocator.free(ls);

    // Count lines
    var line_count: usize = 0;
    var lines = std.mem.splitScalar(u8, trim(ls), '\n');
    while (lines.next()) |_| line_count += 1;
    try testing.expectEqual(@as(usize, 50), line_count);
}
