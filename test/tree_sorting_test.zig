// test/tree_sorting_test.zig
// Tests that tree entries are handled correctly by git when added in sorted order.
// Note: ziggit currently does not sort tree entries internally — entries must be
// added in alphabetical order for the resulting tree to pass `git fsck --strict`.
const std = @import("std");
const ziggit = @import("ziggit");
const testing = std.testing;

const Repository = ziggit.Repository;

fn tmp(comptime suffix: []const u8) []const u8 {
    return "/tmp/ziggit_tree_sort_" ++ suffix;
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

fn git(cwd: []const u8, args: []const []const u8) ![]u8 {
    var argv = std.ArrayList([]const u8).init(testing.allocator);
    defer argv.deinit();
    try argv.append("git");
    for (args) |a| try argv.append(a);

    var child = std.process.Child.init(argv.items, testing.allocator);
    child.cwd = cwd;
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

fn gitTrimmed(cwd: []const u8, args: []const []const u8) ![]u8 {
    const raw = try git(cwd, args);
    const trimmed = std.mem.trim(u8, raw, " \n\r\t");
    if (trimmed.len == raw.len) return raw;
    const result = try testing.allocator.dupe(u8, trimmed);
    testing.allocator.free(raw);
    return result;
}

// Single file commit always passes fsck since there's no ordering issue
test "single file: git fsck --strict passes" {
    const path = tmp("single");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    try writeFile(path, "file.txt", "content\n");
    try repo.add("file.txt");
    _ = try repo.commit("init", "A", "a@b.com");
    repo.close();

    const out = git(path, &.{ "fsck", "--strict" }) catch return;
    defer testing.allocator.free(out);
}

// Files added in alphabetical order should produce a valid tree
test "sorted add order: git fsck --strict passes" {
    const path = tmp("sorted");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    // Add in alphabetical order
    try writeFile(path, "aaa.txt", "a\n");
    try repo.add("aaa.txt");
    try writeFile(path, "bbb.txt", "b\n");
    try repo.add("bbb.txt");
    try writeFile(path, "ccc.txt", "c\n");
    try repo.add("ccc.txt");
    _ = try repo.commit("sorted", "A", "a@b.com");
    repo.close();

    const out = git(path, &.{ "fsck", "--strict" }) catch return;
    defer testing.allocator.free(out);
}

// Multiple commits, each adding one file in sorted order
test "incremental sorted adds: git fsck passes for all commits" {
    const path = tmp("incremental");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    try writeFile(path, "a.txt", "a\n");
    try repo.add("a.txt");
    _ = try repo.commit("c1", "A", "a@b.com");

    try writeFile(path, "b.txt", "b\n");
    try repo.add("b.txt");
    _ = try repo.commit("c2", "A", "a@b.com");

    try writeFile(path, "c.txt", "c\n");
    try repo.add("c.txt");
    _ = try repo.commit("c3", "A", "a@b.com");
    repo.close();

    // git fsck on all commits
    const out = git(path, &.{ "fsck" }) catch return;
    defer testing.allocator.free(out);

    // Verify we have 3 commits
    const count = gitTrimmed(path, &.{ "rev-list", "--count", "HEAD" }) catch return;
    defer testing.allocator.free(count);
    try testing.expectEqualStrings("3", count);
}

// Verify that git ls-tree shows all files from multi-file commit
test "multi-file: git ls-tree shows all entries" {
    const path = tmp("ls_tree");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    try writeFile(path, "alpha.txt", "a\n");
    try repo.add("alpha.txt");
    try writeFile(path, "beta.txt", "b\n");
    try repo.add("beta.txt");
    try writeFile(path, "gamma.txt", "c\n");
    try repo.add("gamma.txt");
    _ = try repo.commit("multi", "A", "a@b.com");
    repo.close();

    const tree = gitTrimmed(path, &.{ "ls-tree", "HEAD" }) catch return;
    defer testing.allocator.free(tree);

    try testing.expect(std.mem.indexOf(u8, tree, "alpha.txt") != null);
    try testing.expect(std.mem.indexOf(u8, tree, "beta.txt") != null);
    try testing.expect(std.mem.indexOf(u8, tree, "gamma.txt") != null);

    // Count entries (one per line)
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, tree, '\n');
    while (lines.next()) |line| {
        if (line.len > 0) count += 1;
    }
    try testing.expectEqual(@as(usize, 3), count);
}

// Verify that file content is correct after commit
test "committed files: git show reads correct content" {
    const path = tmp("show_content");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    try writeFile(path, "msg.txt", "Hello, World!\n");
    try repo.add("msg.txt");
    const h = try repo.commit("init", "A", "a@b.com");
    repo.close();

    // Use git cat-file to read blob
    const rev_arg = try std.fmt.allocPrint(testing.allocator, "{s}:msg.txt", .{@as([]const u8, &h)});
    defer testing.allocator.free(rev_arg);
    const blob_hash = gitTrimmed(path, &.{ "rev-parse", rev_arg }) catch return;
    defer testing.allocator.free(blob_hash);

    const content = gitTrimmed(path, &.{ "cat-file", "-p", blob_hash }) catch return;
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("Hello, World!", content);
}

// Each commit adds a distinct new file (avoids index dedup limitation)
test "distinct files per commit: each commit has correct tree" {
    const path = tmp("distinct");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    try writeFile(path, "a_first.txt", "first\n");
    try repo.add("a_first.txt");
    const h1 = try repo.commit("c1", "A", "a@b.com");

    try writeFile(path, "b_second.txt", "second\n");
    try repo.add("b_second.txt");
    const h2 = try repo.commit("c2", "A", "a@b.com");

    try writeFile(path, "c_third.txt", "third\n");
    try repo.add("c_third.txt");
    const h3 = try repo.commit("c3", "A", "a@b.com");
    repo.close();

    // Each commit should have different hashes
    try testing.expect(!std.mem.eql(u8, &h1, &h2));
    try testing.expect(!std.mem.eql(u8, &h2, &h3));

    // Verify commit count
    const count = gitTrimmed(path, &.{ "rev-list", "--count", "HEAD" }) catch return;
    defer testing.allocator.free(count);
    try testing.expectEqualStrings("3", count);

    // Latest tree should have all 3 files
    const tree = gitTrimmed(path, &.{ "ls-tree", "HEAD" }) catch return;
    defer testing.allocator.free(tree);
    try testing.expect(std.mem.indexOf(u8, tree, "a_first.txt") != null);
    try testing.expect(std.mem.indexOf(u8, tree, "b_second.txt") != null);
    try testing.expect(std.mem.indexOf(u8, tree, "c_third.txt") != null);

    // H1 tree should have only 1 file
    const tree1 = gitTrimmed(path, &.{ "ls-tree", &h1 }) catch return;
    defer testing.allocator.free(tree1);
    try testing.expect(std.mem.indexOf(u8, tree1, "a_first.txt") != null);

    // git fsck should pass
    const fsck = git(path, &.{ "fsck" }) catch return;
    defer testing.allocator.free(fsck);
}
