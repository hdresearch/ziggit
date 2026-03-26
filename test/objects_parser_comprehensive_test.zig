// test/objects_parser_comprehensive_test.zig - Comprehensive tests for src/lib/objects_parser.zig
// Tests SHA conversion, hex validation, commit parsing, tree parsing, and object reading
const std = @import("std");
const ziggit = @import("ziggit");
const testing = std.testing;

// Access objects_parser through ziggit's IndexParser re-export is not available,
// so we test indirectly through the Repository API which uses objects_parser internally.

const Repository = ziggit.Repository;

fn tmpPath(comptime suffix: []const u8) []const u8 {
    return "/tmp/ziggit_objparser_test_" ++ suffix;
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

// ============================================================================
// SHA-1 hash computation tests (via Repository.add which creates blobs)
// ============================================================================

test "SHA-1: empty blob matches git's known hash" {
    const path = tmpPath("sha_empty");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    try createFile(path, "empty.txt", "");
    try repo.add("empty.txt");
    _ = try repo.commit("c", "A", "a@a.com");
    repo.close();

    // Known SHA-1 of empty blob: e69de29bb2d1d6434b8b29ae775ad8c2e48c5391
    const hash_out = try runGit(&.{ "git", "hash-object", "empty.txt" }, path);
    defer testing.allocator.free(hash_out);
    const hash = std.mem.trim(u8, hash_out, " \n\r\t");
    try testing.expectEqualStrings("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391", hash);

    // Verify it's in the tree
    const ls_out = try runGit(&.{ "git", "ls-tree", "HEAD" }, path);
    defer testing.allocator.free(ls_out);
    try testing.expect(std.mem.indexOf(u8, ls_out, "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391") != null);
}

test "SHA-1: 'hello' blob matches known hash" {
    const path = tmpPath("sha_hello");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    try createFile(path, "hello.txt", "hello");
    try repo.add("hello.txt");
    _ = try repo.commit("c", "A", "a@a.com");
    repo.close();

    // Verify via git
    const hash_out = try runGit(&.{ "git", "hash-object", "hello.txt" }, path);
    defer testing.allocator.free(hash_out);
    const hash = std.mem.trim(u8, hash_out, " \n\r\t");
    // "hello" without newline: b6fc4c620b67d95f953a5c1c1230aaab5db5a1b0
    try testing.expectEqualStrings("b6fc4c620b67d95f953a5c1c1230aaab5db5a1b0", hash);
}

// ============================================================================
// Commit format tests
// ============================================================================

test "commit: first commit has no parent line" {
    const path = tmpPath("no_parent");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    try createFile(path, "f.txt", "x");
    try repo.add("f.txt");
    const hash = try repo.commit("first", "A", "a@a.com");
    repo.close();

    const content = try runGit(&.{ "git", "cat-file", "-p", &hash }, path);
    defer testing.allocator.free(content);

    // First commit should NOT have parent line
    try testing.expect(std.mem.indexOf(u8, content, "parent ") == null);
}

test "commit: second commit has exactly one parent" {
    const path = tmpPath("one_parent");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    try createFile(path, "f.txt", "v1");
    try repo.add("f.txt");
    _ = try repo.commit("first", "A", "a@a.com");

    try createFile(path, "f.txt", "v2");
    try repo.add("f.txt");
    const second = try repo.commit("second", "A", "a@a.com");
    repo.close();

    const content = try runGit(&.{ "git", "cat-file", "-p", &second }, path);
    defer testing.allocator.free(content);

    // Count parent lines
    var count: usize = 0;
    var lines = std.mem.splitSequence(u8, content, "\n");
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "parent ")) count += 1;
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "commit: tree hash is valid 40-char hex" {
    const path = tmpPath("tree_hex");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    try createFile(path, "f.txt", "x");
    try repo.add("f.txt");
    const hash = try repo.commit("c", "A", "a@a.com");
    repo.close();

    const content = try runGit(&.{ "git", "cat-file", "-p", &hash }, path);
    defer testing.allocator.free(content);

    // Extract tree hash
    var lines = std.mem.splitSequence(u8, content, "\n");
    const first_line = lines.first();
    try testing.expect(std.mem.startsWith(u8, first_line, "tree "));
    const tree_hash = first_line[5..];
    try testing.expectEqual(@as(usize, 40), tree_hash.len);

    // Verify all hex
    for (tree_hash) |c| {
        try testing.expect(std.ascii.isHex(c));
    }
}

test "commit: timestamp is in reasonable range" {
    const path = tmpPath("timestamp");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    try createFile(path, "f.txt", "x");
    try repo.add("f.txt");
    const hash = try repo.commit("c", "A", "a@a.com");
    repo.close();

    const content = try runGit(&.{ "git", "cat-file", "-p", &hash }, path);
    defer testing.allocator.free(content);

    // Find author line and extract timestamp
    var lines = std.mem.splitSequence(u8, content, "\n");
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "author ")) {
            // Format: "author Name <email> TIMESTAMP +OFFSET"
            // Find last space-delimited tokens
            var parts = std.mem.splitBackwardsSequence(u8, line, " ");
            _ = parts.next(); // timezone offset
            const ts_str = parts.next() orelse continue;
            const ts = try std.fmt.parseInt(i64, ts_str, 10);
            // Should be after 2020 and before 2030
            try testing.expect(ts > 1577836800); // 2020-01-01
            try testing.expect(ts < 1893456000); // 2030-01-01
            return;
        }
    }
    // Should have found author line
    return error.TestUnexpectedResult;
}

// ============================================================================
// Tree format tests
// ============================================================================

test "tree: entries have mode 100644 for regular files" {
    const path = tmpPath("tree_mode");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    try createFile(path, "regular.txt", "content\n");
    try repo.add("regular.txt");
    _ = try repo.commit("c", "A", "a@a.com");
    repo.close();

    const ls_out = try runGit(&.{ "git", "ls-tree", "HEAD" }, path);
    defer testing.allocator.free(ls_out);

    try testing.expect(std.mem.indexOf(u8, ls_out, "100644") != null);
}

test "tree: multiple files all present in tree" {
    const path = tmpPath("tree_multi");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    const files = [_][]const u8{ "a.txt", "b.txt", "c.txt", "d.txt", "e.txt" };
    for (files, 0..) |name, i| {
        const content = try std.fmt.allocPrint(testing.allocator, "content_{d}\n", .{i});
        defer testing.allocator.free(content);
        try createFile(path, name, content);
        try repo.add(name);
    }
    _ = try repo.commit("multi", "A", "a@a.com");
    repo.close();

    const ls_out = try runGit(&.{ "git", "ls-tree", "HEAD" }, path);
    defer testing.allocator.free(ls_out);

    for (files) |name| {
        try testing.expect(std.mem.indexOf(u8, ls_out, name) != null);
    }
}

// ============================================================================
// Object read tests (via checkout which reads objects)
// ============================================================================

test "checkout: restores correct file content" {
    const path = tmpPath("checkout_content");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    try createFile(path, "data.txt", "version one\n");
    try repo.add("data.txt");
    const first_hash = try repo.commit("v1", "A", "a@a.com");

    try createFile(path, "data.txt", "version two\n");
    try repo.add("data.txt");
    _ = try repo.commit("v2", "A", "a@a.com");

    // Checkout first commit
    try repo.checkout(&first_hash);

    // Read file content
    const file_path = try std.fmt.allocPrint(testing.allocator, "{s}/data.txt", .{path});
    defer testing.allocator.free(file_path);
    const file = try std.fs.openFileAbsolute(file_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(testing.allocator, 1024);
    defer testing.allocator.free(content);

    try testing.expectEqualStrings("version one\n", content);
    repo.close();
}

// ============================================================================
// findCommit tests  
// ============================================================================

test "findCommit: resolves full hash" {
    const path = tmpPath("find_full");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    try createFile(path, "f.txt", "x");
    try repo.add("f.txt");
    const hash = try repo.commit("c", "A", "a@a.com");

    const found = try repo.findCommit(&hash);
    try testing.expectEqualStrings(&hash, &found);
    repo.close();
}

test "findCommit: resolves HEAD" {
    const path = tmpPath("find_head");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    try createFile(path, "f.txt", "x");
    try repo.add("f.txt");
    const hash = try repo.commit("c", "A", "a@a.com");

    const found = try repo.findCommit("HEAD");
    try testing.expectEqualStrings(&hash, &found);
    repo.close();
}

test "findCommit: resolves branch name" {
    const path = tmpPath("find_branch");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    try createFile(path, "f.txt", "x");
    try repo.add("f.txt");
    const hash = try repo.commit("c", "A", "a@a.com");

    const found = try repo.findCommit("master");
    try testing.expectEqualStrings(&hash, &found);
    repo.close();
}

test "findCommit: resolves tag name" {
    const path = tmpPath("find_tag");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    try createFile(path, "f.txt", "x");
    try repo.add("f.txt");
    const hash = try repo.commit("c", "A", "a@a.com");
    try repo.createTag("v1", null);

    const found = try repo.findCommit("v1");
    try testing.expectEqualStrings(&hash, &found);
    repo.close();
}

test "findCommit: fails on nonexistent ref" {
    const path = tmpPath("find_bad");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    try createFile(path, "f.txt", "x");
    try repo.add("f.txt");
    _ = try repo.commit("c", "A", "a@a.com");

    try testing.expectError(error.CommitNotFound, repo.findCommit("nonexistent_branch_xyz"));
}

// ============================================================================
// Short hash expansion test
// ============================================================================

test "findCommit: resolves short hash (first 7 chars)" {
    const path = tmpPath("find_short");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    try createFile(path, "f.txt", "x");
    try repo.add("f.txt");
    const hash = try repo.commit("c", "A", "a@a.com");

    const short = hash[0..7];
    const found = try repo.findCommit(short);
    try testing.expectEqualStrings(&hash, &found);
    repo.close();
}
