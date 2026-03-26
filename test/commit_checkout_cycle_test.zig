// test/commit_checkout_cycle_test.zig
// Tests for commit chains, checkout, and round-trip integrity.
// Verifies that ziggit can create commits, checkout previous states,
// and that git agrees with the results.
const std = @import("std");
const ziggit = @import("ziggit");
const testing = std.testing;

const Repository = ziggit.Repository;

fn tmpPath(comptime suffix: []const u8) []const u8 {
    return "/tmp/ziggit_ccc_" ++ suffix;
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

fn readFile(dir: []const u8, name: []const u8) ![]u8 {
    const full = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ dir, name });
    defer testing.allocator.free(full);
    const f = try std.fs.openFileAbsolute(full, .{});
    defer f.close();
    return try f.readToEndAlloc(testing.allocator, 1024 * 1024);
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

test "three-commit chain: each has distinct hash" {
    const path = tmpPath("chain3");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "v1\n");
    try repo.add("f.txt");
    const h1 = try repo.commit("first", "A", "a@a.com");

    try createFile(path, "f.txt", "v2\n");
    try repo.add("f.txt");
    const h2 = try repo.commit("second", "A", "a@a.com");

    try createFile(path, "f.txt", "v3\n");
    try repo.add("f.txt");
    const h3 = try repo.commit("third", "A", "a@a.com");

    // All hashes must be distinct
    try testing.expect(!std.mem.eql(u8, &h1, &h2));
    try testing.expect(!std.mem.eql(u8, &h2, &h3));
    try testing.expect(!std.mem.eql(u8, &h1, &h3));

    // HEAD should point to h3
    const head = try repo.revParseHead();
    try testing.expectEqualStrings(&h3, &head);
}

test "findCommit resolves each commit in chain" {
    const path = tmpPath("find_chain");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "v1\n");
    try repo.add("f.txt");
    const h1 = try repo.commit("first", "A", "a@a.com");

    try createFile(path, "f.txt", "v2\n");
    try repo.add("f.txt");
    _ = try repo.commit("second", "A", "a@a.com");

    // findCommit with full hash of first commit
    const found = try repo.findCommit(&h1);
    try testing.expectEqualStrings(&h1, &found);
}

test "checkout restores file to previous commit state" {
    const path = tmpPath("checkout_restore");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "data.txt", "original\n");
    try repo.add("data.txt");
    const h1 = try repo.commit("v1", "A", "a@a.com");

    try createFile(path, "data.txt", "modified\n");
    try repo.add("data.txt");
    _ = try repo.commit("v2", "A", "a@a.com");

    // File should currently say "modified"
    const content_before = try readFile(path, "data.txt");
    defer testing.allocator.free(content_before);
    try testing.expectEqualStrings("modified\n", content_before);

    // Checkout first commit
    try repo.checkout(&h1);

    // File should now say "original"
    const content_after = try readFile(path, "data.txt");
    defer testing.allocator.free(content_after);
    try testing.expectEqualStrings("original\n", content_after);
}

test "checkout then commit creates new branch point" {
    const path = tmpPath("checkout_commit");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "v1\n");
    try repo.add("f.txt");
    const h1 = try repo.commit("c1", "A", "a@a.com");

    try createFile(path, "f.txt", "v2\n");
    try repo.add("f.txt");
    const h2 = try repo.commit("c2", "A", "a@a.com");

    // Checkout first commit
    try repo.checkout(&h1);

    // Create new content and commit
    try createFile(path, "f.txt", "v3-diverged\n");
    try repo.add("f.txt");
    const h3 = try repo.commit("c3-diverged", "A", "a@a.com");

    // h3 should be different from h2
    try testing.expect(!std.mem.eql(u8, &h2, &h3));

    // HEAD should point to h3
    const head = try repo.revParseHead();
    try testing.expectEqualStrings(&h3, &head);
}

test "git rev-list validates ziggit commit chain" {
    const path = tmpPath("revlist_validate");
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

    // Ask git to validate the commit chain
    const rev_list = runGit(path, &.{ "rev-list", "HEAD" }) catch return;
    defer testing.allocator.free(rev_list);

    // Should have 3 lines (3 commits)
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, rev_list, "\n"), '\n');
    while (lines.next()) |line| {
        if (line.len >= 40) count += 1;
    }
    try testing.expectEqual(@as(usize, 3), count);
}

test "git fsck passes on ziggit multi-commit repo" {
    const path = tmpPath("fsck_multi");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);

    try createFile(path, "a.txt", "aaa\n");
    try repo.add("a.txt");
    _ = try repo.commit("add a", "Test", "t@t.com");

    try createFile(path, "b.txt", "bbb\n");
    try repo.add("b.txt");
    _ = try repo.commit("add b", "Test", "t@t.com");

    repo.close();

    // git fsck should pass
    var child = std.process.Child.init(&.{ "git", "fsck", "--strict" }, testing.allocator);
    child.cwd = path;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const result = try child.wait();
    try testing.expect(result.Exited == 0);
}

test "cloneNoCheckout then open preserves HEAD" {
    const path = tmpPath("clone_head");
    const clone_path = tmpPath("clone_head_dst");
    cleanup(path);
    cleanup(clone_path);
    defer cleanup(path);
    defer cleanup(clone_path);

    // Create source repo
    var src = try Repository.init(testing.allocator, path);
    try createFile(path, "f.txt", "content\n");
    try src.add("f.txt");
    const src_hash = try src.commit("init", "A", "a@a.com");
    src.close();

    // Clone
    var dst = try Repository.cloneNoCheckout(testing.allocator, path, clone_path);
    defer dst.close();

    // HEAD should match
    const dst_head = try dst.revParseHead();
    try testing.expectEqualStrings(&src_hash, &dst_head);
}

test "fetch copies new commits" {
    const path_a = tmpPath("fetch_src");
    const path_b = tmpPath("fetch_dst");
    cleanup(path_a);
    cleanup(path_b);
    defer cleanup(path_a);
    defer cleanup(path_b);

    // Create source with commit
    var a = try Repository.init(testing.allocator, path_a);
    try createFile(path_a, "f.txt", "hello\n");
    try a.add("f.txt");
    _ = try a.commit("init", "A", "a@a.com");
    a.close();

    // Clone to dest
    var b = try Repository.cloneNoCheckout(testing.allocator, path_a, path_b);

    // Add another commit to source
    a = try Repository.open(testing.allocator, path_a);
    try createFile(path_a, "f.txt", "updated\n");
    try a.add("f.txt");
    _ = try a.commit("update", "A", "a@a.com");
    const new_head = try a.revParseHead();
    a.close();

    // Fetch from source
    try b.fetch(path_a);
    b.close();

    // Verify the new objects exist by re-opening and finding the commit
    var b2 = try Repository.open(testing.allocator, path_b);
    defer b2.close();
    const found = try b2.findCommit(&new_head);
    try testing.expectEqualStrings(&new_head, &found);
}

test "createTag and describeTags round-trip" {
    const path = tmpPath("tag_roundtrip");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "v\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "A", "a@a.com");

    try repo.createTag("v1.0.0", null);
    try repo.createTag("v2.0.0", null);

    const tag = try repo.describeTags(testing.allocator);
    defer testing.allocator.free(tag);

    // Should return the lexicographically latest tag
    try testing.expectEqualStrings("v2.0.0", tag);
}

test "annotated tag round-trip with message" {
    const path = tmpPath("ann_tag");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "A", "a@a.com");

    try repo.createTag("release-1.0", "Release version 1.0");

    const tag = try repo.describeTags(testing.allocator);
    defer testing.allocator.free(tag);
    try testing.expectEqualStrings("release-1.0", tag);
}

test "branchList after commits on master" {
    const path = tmpPath("branchlist");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "A", "a@a.com");

    const branches = try repo.branchList(testing.allocator);
    defer {
        for (branches) |b| testing.allocator.free(b);
        testing.allocator.free(branches);
    }

    try testing.expectEqual(@as(usize, 1), branches.len);
    try testing.expectEqualStrings("master", branches[0]);
}
