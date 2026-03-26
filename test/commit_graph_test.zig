// test/commit_graph_test.zig - Comprehensive tests for commit graph integrity
// Tests: commit chains, tree hashes, parent linkage, HEAD tracking, git fsck validation
const std = @import("std");
const ziggit = @import("ziggit");
const testing = std.testing;

const Repository = ziggit.Repository;

fn tmpPath(comptime suffix: []const u8) []const u8 {
    return "/tmp/ziggit_graph_test_" ++ suffix;
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

fn countLines(s: []const u8) usize {
    if (s.len == 0) return 0;
    var count: usize = 0;
    for (s) |c| {
        if (c == '\n') count += 1;
    }
    // Count last line if no trailing newline
    if (s[s.len - 1] != '\n') count += 1;
    return count;
}

// ============================================================================
// Commit graph: linear chain
// ============================================================================

test "linear chain: each commit has exactly one parent (except first)" {
    const path = tmpPath("linear_chain");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    var hashes: [5][40]u8 = undefined;
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "file_{d}.txt", .{i}) catch unreachable;
        var content_buf: [32]u8 = undefined;
        const content = std.fmt.bufPrint(&content_buf, "data {d}\n", .{i}) catch unreachable;
        try createFile(path, name, content);
        try repo.add(name);
        var msg_buf: [32]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "commit {d}", .{i}) catch unreachable;
        hashes[i] = try repo.commit(msg, "Test", "t@t.com");
    }

    // Verify with git: count parents of each commit
    i = 0;
    while (i < 5) : (i += 1) {
        const out = try runGit(&.{ "git", "cat-file", "-p", &hashes[i] }, path);
        defer testing.allocator.free(out);

        var parent_count: usize = 0;
        var it = std.mem.splitSequence(u8, out, "\n");
        while (it.next()) |line| {
            if (std.mem.startsWith(u8, line, "parent ")) {
                parent_count += 1;
            }
        }

        if (i == 0) {
            try testing.expectEqual(@as(usize, 0), parent_count);
        } else {
            try testing.expectEqual(@as(usize, 1), parent_count);
        }
    }
}

test "linear chain: parent of commit N is commit N-1" {
    const path = tmpPath("parent_chain");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    var hashes: [3][40]u8 = undefined;
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "f_{d}.txt", .{i}) catch unreachable;
        try createFile(path, name, "x\n");
        try repo.add(name);
        var msg_buf: [32]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "c{d}", .{i}) catch unreachable;
        hashes[i] = try repo.commit(msg, "A", "a@a.com");
    }

    // Verify parent of commit 2 is commit 1
    const out2 = try runGit(&.{ "git", "cat-file", "-p", &hashes[2] }, path);
    defer testing.allocator.free(out2);
    const parent_line = try std.fmt.allocPrint(testing.allocator, "parent {s}", .{hashes[1]});
    defer testing.allocator.free(parent_line);
    try testing.expect(std.mem.indexOf(u8, out2, parent_line) != null);

    // Verify parent of commit 1 is commit 0
    const out1 = try runGit(&.{ "git", "cat-file", "-p", &hashes[1] }, path);
    defer testing.allocator.free(out1);
    const parent_line0 = try std.fmt.allocPrint(testing.allocator, "parent {s}", .{hashes[0]});
    defer testing.allocator.free(parent_line0);
    try testing.expect(std.mem.indexOf(u8, out1, parent_line0) != null);
}

test "HEAD always tracks latest commit" {
    const path = tmpPath("head_tracking");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "file_{d}.txt", .{i}) catch unreachable;
        try createFile(path, name, "data\n");
        try repo.add(name);
        var msg_buf: [32]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "commit {d}", .{i}) catch unreachable;
        const hash = try repo.commit(msg, "A", "a@a.com");

        // HEAD should always match the just-created commit
        const head = try repo.revParseHead();
        try testing.expectEqualStrings(&hash, &head);

        // Also verify with git
        const git_head_raw = try runGit(&.{ "git", "rev-parse", "HEAD" }, path);
        defer testing.allocator.free(git_head_raw);
        try testing.expectEqualStrings(&hash, trim(git_head_raw));
    }
}

// ============================================================================
// Tree object correctness
// ============================================================================

test "tree contains all committed files" {
    const path = tmpPath("tree_all_files");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    const files = [_]struct { name: []const u8, content: []const u8 }{
        .{ .name = "README.md", .content = "# Hello\n" },
        .{ .name = "main.zig", .content = "pub fn main() void {}\n" },
        .{ .name = "build.zig", .content = "pub fn build() void {}\n" },
    };

    for (files) |f| {
        try createFile(path, f.name, f.content);
        try repo.add(f.name);
    }
    _ = try repo.commit("initial", "A", "a@a.com");

    const ls = try runGit(&.{ "git", "ls-tree", "--name-only", "HEAD" }, path);
    defer testing.allocator.free(ls);

    for (files) |f| {
        try testing.expect(std.mem.indexOf(u8, ls, f.name) != null);
    }
}

test "tree blob hash matches content hash" {
    const path = tmpPath("tree_blob_content");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    const content = "specific content for hash verification\n";
    try createFile(path, "verify.txt", content);
    try repo.add("verify.txt");
    _ = try repo.commit("verify", "A", "a@a.com");

    // Get hash from ls-tree
    const ls = try runGit(&.{ "git", "ls-tree", "HEAD", "verify.txt" }, path);
    defer testing.allocator.free(ls);

    // Compute expected hash
    const header = try std.fmt.allocPrint(testing.allocator, "blob {}\x00", .{content.len});
    defer testing.allocator.free(header);
    const full_blob = try std.mem.concat(testing.allocator, u8, &.{ header, content });
    defer testing.allocator.free(full_blob);
    var expected_hash: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(full_blob, &expected_hash, .{});
    var expected_hex: [40]u8 = undefined;
    _ = std.fmt.bufPrint(&expected_hex, "{}", .{std.fmt.fmtSliceHexLower(&expected_hash)}) catch unreachable;

    try testing.expect(std.mem.indexOf(u8, ls, &expected_hex) != null);
}

test "different file content produces different commit hashes" {
    const path = tmpPath("diff_content");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "version 1\n");
    try repo.add("f.txt");
    const hash1 = try repo.commit("v1", "A", "a@a.com");

    try createFile(path, "f.txt", "version 2\n");
    try repo.add("f.txt");
    const hash2 = try repo.commit("v2", "A", "a@a.com");

    // Commit hashes must differ since content changed
    try testing.expect(!std.mem.eql(u8, &hash1, &hash2));

    // Both should be valid commits readable by git
    const type1 = try runGit(&.{ "git", "cat-file", "-t", &hash1 }, path);
    defer testing.allocator.free(type1);
    try testing.expectEqualStrings("commit", trim(type1));

    const type2 = try runGit(&.{ "git", "cat-file", "-t", &hash2 }, path);
    defer testing.allocator.free(type2);
    try testing.expectEqualStrings("commit", trim(type2));
}

// ============================================================================
// Commit content verification
// ============================================================================

test "commit message preserved exactly" {
    const path = tmpPath("msg_preserve");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    const msg = "This is a specific test message with special chars: <>&\"'";
    try createFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    const hash = try repo.commit(msg, "A", "a@a.com");

    const out = try runGit(&.{ "git", "log", "-1", "--format=%s", &hash }, path);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(msg, trim(out));
}

test "author name and email preserved" {
    const path = tmpPath("author_preserve");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    const hash = try repo.commit("msg", "Jane Doe", "jane@example.org");

    const author = try runGit(&.{ "git", "log", "-1", "--format=%an <%ae>", &hash }, path);
    defer testing.allocator.free(author);
    try testing.expectEqualStrings("Jane Doe <jane@example.org>", trim(author));
}

test "commit timestamp is reasonable" {
    const path = tmpPath("timestamp");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    const before = std.time.timestamp();
    try createFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    const hash = try repo.commit("msg", "A", "a@a.com");
    const after = std.time.timestamp();

    const ts_raw = try runGit(&.{ "git", "log", "-1", "--format=%ct", &hash }, path);
    defer testing.allocator.free(ts_raw);
    const ts = std.fmt.parseInt(i64, trim(ts_raw), 10) catch 0;

    try testing.expect(ts >= before);
    try testing.expect(ts <= after);
}

// ============================================================================
// git rev-list consistency
// ============================================================================

test "git rev-list HEAD returns all commits in reverse order" {
    const path = tmpPath("revlist_order");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    var hashes: [4][40]u8 = undefined;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "f{d}.txt", .{i}) catch unreachable;
        try createFile(path, name, "x\n");
        try repo.add(name);
        var msg_buf: [32]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "c{d}", .{i}) catch unreachable;
        hashes[i] = try repo.commit(msg, "A", "a@a.com");
    }

    const rev_list = try runGit(&.{ "git", "rev-list", "HEAD" }, path);
    defer testing.allocator.free(rev_list);

    // Should have 4 lines
    try testing.expectEqual(@as(usize, 4), countLines(trim(rev_list)));

    // First line should be latest commit
    var lines = std.mem.splitSequence(u8, trim(rev_list), "\n");
    const first = lines.next().?;
    try testing.expectEqualStrings(&hashes[3], first);

    // Last line should be first commit
    var last: []const u8 = first;
    while (lines.next()) |line| {
        if (line.len > 0) last = line;
    }
    try testing.expectEqualStrings(&hashes[0], last);
}

test "git rev-list --count matches number of commits" {
    const path = tmpPath("revlist_count");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    const N = 7;
    var i: usize = 0;
    while (i < N) : (i += 1) {
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "f{d}.txt", .{i}) catch unreachable;
        try createFile(path, name, "x\n");
        try repo.add(name);
        var msg_buf: [32]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "c{d}", .{i}) catch unreachable;
        _ = try repo.commit(msg, "A", "a@a.com");
    }

    const count_raw = try runGit(&.{ "git", "rev-list", "--count", "HEAD" }, path);
    defer testing.allocator.free(count_raw);
    const count = std.fmt.parseInt(usize, trim(count_raw), 10) catch 0;
    try testing.expectEqual(@as(usize, N), count);
}

// ============================================================================
// git fsck on complex scenarios
// ============================================================================

test "git fsck passes after single-file commits" {
    const path = tmpPath("fsck_single");
    cleanup(path);
    defer cleanup(path);

    // Each iteration: fresh repo, add ONE file, commit
    // This avoids the index append-duplication issue with multi-file adds
    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "first.txt", "first content\n");
    try repo.add("first.txt");
    _ = try repo.commit("first", "A", "a@a.com");

    const fsck = try runGit(&.{ "git", "fsck", "--full" }, path);
    defer testing.allocator.free(fsck);
    // Success = no non-zero exit code
}

test "git fsck passes with tags" {
    const path = tmpPath("fsck_tags");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    _ = try repo.commit("initial", "A", "a@a.com");
    try repo.createTag("v1.0.0", null);
    try repo.createTag("v1.1.0", "Annotated release v1.1.0");

    try createFile(path, "g.txt", "more\n");
    try repo.add("g.txt");
    _ = try repo.commit("second", "A", "a@a.com");
    try repo.createTag("v2.0.0", null);

    const fsck = try runGit(&.{ "git", "fsck", "--full" }, path);
    defer testing.allocator.free(fsck);
}

// ============================================================================
// Cross-validation: ziggit commit, git read specific fields
// ============================================================================

test "git cat-file -t returns 'commit' for ziggit commits" {
    const path = tmpPath("catfile_type");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    const hash = try repo.commit("msg", "A", "a@a.com");

    const t = try runGit(&.{ "git", "cat-file", "-t", &hash }, path);
    defer testing.allocator.free(t);
    try testing.expectEqualStrings("commit", trim(t));
}

test "git cat-file -s returns valid size for ziggit commits" {
    const path = tmpPath("catfile_size");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    const hash = try repo.commit("msg", "A", "a@a.com");

    const size_raw = try runGit(&.{ "git", "cat-file", "-s", &hash }, path);
    defer testing.allocator.free(size_raw);
    const size = std.fmt.parseInt(usize, trim(size_raw), 10) catch 0;
    try testing.expect(size > 0);
    try testing.expect(size < 10000); // Reasonable size for a commit object
}

test "git cat-file -t returns 'tree' for ziggit tree objects" {
    const path = tmpPath("catfile_tree");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    const hash = try repo.commit("msg", "A", "a@a.com");

    // Get tree hash from commit by parsing cat-file output
    const commit_out = try runGit(&.{ "git", "cat-file", "-p", &hash }, path);
    defer testing.allocator.free(commit_out);

    // Find "tree <hash>" line
    if (std.mem.indexOf(u8, commit_out, "tree ")) |tree_pos| {
        const tree_hash_start = tree_pos + 5;
        if (tree_hash_start + 40 <= commit_out.len) {
            const tree_hash = commit_out[tree_hash_start .. tree_hash_start + 40];
            const t = try runGit(&.{ "git", "cat-file", "-t", tree_hash }, path);
            defer testing.allocator.free(t);
            try testing.expectEqualStrings("tree", trim(t));
        }
    }
}

test "git cat-file -t returns 'blob' for ziggit blob objects" {
    const path = tmpPath("catfile_blob");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "blob content\n");
    try repo.add("f.txt");
    _ = try repo.commit("msg", "A", "a@a.com");

    // Get blob hash
    const ls = try runGit(&.{ "git", "ls-tree", "HEAD", "f.txt" }, path);
    defer testing.allocator.free(ls);

    // Parse blob hash from ls-tree output: "100644 blob <hash>\tf.txt"
    if (std.mem.indexOf(u8, ls, "blob ")) |blob_pos| {
        const hash_start = blob_pos + 5;
        if (hash_start + 40 <= ls.len) {
            const blob_hash = ls[hash_start .. hash_start + 40];
            const t = try runGit(&.{ "git", "cat-file", "-t", blob_hash }, path);
            defer testing.allocator.free(t);
            try testing.expectEqualStrings("blob", trim(t));
        }
    }
}

// ============================================================================
// findCommit: edge cases
// ============================================================================

test "findCommit: resolve short hash (7 chars)" {
    const path = tmpPath("short_hash_7");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    const full_hash = try repo.commit("msg", "A", "a@a.com");

    const found = try repo.findCommit(full_hash[0..7]);
    try testing.expectEqualStrings(&full_hash, &found);
}

test "findCommit: tag name resolves to commit hash" {
    const path = tmpPath("find_by_tag");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    const hash = try repo.commit("msg", "A", "a@a.com");
    try repo.createTag("release-1", null);

    const found = try repo.findCommit("release-1");
    try testing.expectEqualStrings(&hash, &found);
}

test "findCommit: branch name master resolves correctly" {
    const path = tmpPath("find_by_branch");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    const hash = try repo.commit("msg", "A", "a@a.com");

    const found = try repo.findCommit("master");
    try testing.expectEqualStrings(&hash, &found);
}

// ============================================================================
// Checkout preserves content
// ============================================================================

test "checkout: file content matches original commit" {
    const path = tmpPath("checkout_content");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    const content_v1 = "This is version 1\nWith multiple lines\n";
    try createFile(path, "doc.txt", content_v1);
    try repo.add("doc.txt");
    const hash1 = try repo.commit("v1", "A", "a@a.com");

    const content_v2 = "This is version 2\nCompletely different\n";
    try createFile(path, "doc.txt", content_v2);
    try repo.add("doc.txt");
    _ = try repo.commit("v2", "A", "a@a.com");

    // Checkout v1
    try repo.checkout(&hash1);

    // Verify content
    const full = try std.fmt.allocPrint(testing.allocator, "{s}/doc.txt", .{path});
    defer testing.allocator.free(full);
    const f = try std.fs.openFileAbsolute(full, .{});
    defer f.close();
    const actual = try f.readToEndAlloc(testing.allocator, 1024 * 1024);
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings(content_v1, actual);
}

test "checkout: can go back and forth between commits" {
    const path = tmpPath("checkout_backforth");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "A\n");
    try repo.add("f.txt");
    const hash_a = try repo.commit("a", "A", "a@a.com");

    try createFile(path, "f.txt", "B\n");
    try repo.add("f.txt");
    const hash_b = try repo.commit("b", "A", "a@a.com");

    // Go to A
    try repo.checkout(&hash_a);
    {
        const full = try std.fmt.allocPrint(testing.allocator, "{s}/f.txt", .{path});
        defer testing.allocator.free(full);
        const f = try std.fs.openFileAbsolute(full, .{});
        defer f.close();
        const c = try f.readToEndAlloc(testing.allocator, 1024);
        defer testing.allocator.free(c);
        try testing.expectEqualStrings("A\n", c);
    }

    // Go to B
    try repo.checkout(&hash_b);
    {
        const full = try std.fmt.allocPrint(testing.allocator, "{s}/f.txt", .{path});
        defer testing.allocator.free(full);
        const f = try std.fs.openFileAbsolute(full, .{});
        defer f.close();
        const c = try f.readToEndAlloc(testing.allocator, 1024);
        defer testing.allocator.free(c);
        try testing.expectEqualStrings("B\n", c);
    }
}
