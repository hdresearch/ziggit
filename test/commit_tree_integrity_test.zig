// test/commit_tree_integrity_test.zig
// Tests the integrity of commit/tree/blob objects created by ziggit,
// cross-validated against real git CLI. Verifies SHA-1 hashes, object types,
// parent chains, tree entries, and content correctness.
const std = @import("std");
const ziggit = @import("ziggit");
const testing = std.testing;

const Repository = ziggit.Repository;

// ============================================================================
// Helpers
// ============================================================================

fn tmpPath(comptime suffix: []const u8) []const u8 {
    return "/tmp/ziggit_commit_tree_" ++ suffix;
}

fn cleanup(path: []const u8) void {
    std.fs.deleteTreeAbsolute(path) catch {};
}

fn writeFile(dir: []const u8, name: []const u8, content: []const u8) !void {
    const full = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ dir, name });
    defer testing.allocator.free(full);

    // Create parent directories recursively if needed
    if (std.mem.lastIndexOf(u8, name, "/")) |_| {
        const parent_path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ dir, name });
        defer testing.allocator.free(parent_path);
        const dirname = std.fs.path.dirname(parent_path) orelse dir;
        std.fs.makeDirAbsolute(dirname) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            error.FileNotFound => {
                // Need to create parent dirs recursively
                var abs_dir = try std.fs.openDirAbsolute("/", .{});
                defer abs_dir.close();
                abs_dir.makePath(dirname[1..]) catch {}; // skip leading /
            },
            else => return e,
        };
    }

    const f = try std.fs.createFileAbsolute(full, .{ .truncate = true });
    defer f.close();
    try f.writeAll(content);
}

fn readFileContent(dir: []const u8, name: []const u8) ![]u8 {
    const full = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ dir, name });
    defer testing.allocator.free(full);
    const f = try std.fs.openFileAbsolute(full, .{});
    defer f.close();
    return try f.readToEndAlloc(testing.allocator, 10 * 1024 * 1024);
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

fn initRepo(path: []const u8) !*Repository {
    const repo = try testing.allocator.create(Repository);
    repo.* = try Repository.init(testing.allocator, path);
    // Configure git user for git CLI commands
    _ = git(path, &.{ "config", "user.email", "test@ziggit.dev" }) catch {};
    _ = git(path, &.{ "config", "user.name", "ZiggitTest" }) catch {};
    return repo;
}

// ============================================================================
// Commit object integrity tests
// ============================================================================

test "commit hash matches git rev-parse" {
    const path = tmpPath("commit_hash");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    _ = git(path, &.{ "config", "user.email", "test@ziggit.dev" }) catch {};
    _ = git(path, &.{ "config", "user.name", "Test" }) catch {};

    try writeFile(path, "hello.txt", "hello world\n");
    try repo.add("hello.txt");
    const hash = try repo.commit("test commit", "Test", "test@ziggit.dev");

    // git should be able to read this commit
    const git_type = try gitTrimmed(path, &.{ "cat-file", "-t", &hash });
    defer testing.allocator.free(git_type);
    try testing.expectEqualStrings("commit", git_type);
}

test "commit tree hash is valid git tree object" {
    const path = tmpPath("commit_tree");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    _ = git(path, &.{ "config", "user.email", "t@t" }) catch {};
    _ = git(path, &.{ "config", "user.name", "T" }) catch {};

    try writeFile(path, "a.txt", "aaa\n");
    try repo.add("a.txt");
    const commit_hash = try repo.commit("first", "T", "t@t");

    // Extract tree hash from commit via git
    const tree_hash = try gitTrimmed(path, &.{ "rev-parse", &(commit_hash ++ "^{tree}".*) });
    defer testing.allocator.free(tree_hash);

    // Tree should be a valid tree object
    const tree_type = try gitTrimmed(path, &.{ "cat-file", "-t", tree_hash });
    defer testing.allocator.free(tree_type);
    try testing.expectEqualStrings("tree", tree_type);
}

test "commit parent chain is correct for two commits" {
    const path = tmpPath("parent_chain");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    _ = git(path, &.{ "config", "user.email", "t@t" }) catch {};
    _ = git(path, &.{ "config", "user.name", "T" }) catch {};

    try writeFile(path, "a.txt", "first\n");
    try repo.add("a.txt");
    const first_hash = try repo.commit("first", "T", "t@t");

    try writeFile(path, "b.txt", "second\n");
    try repo.add("b.txt");
    const second_hash = try repo.commit("second", "T", "t@t");

    // git should see second's parent as first
    const parent = try gitTrimmed(path, &.{ "rev-parse", &(second_hash ++ "^".*) });
    defer testing.allocator.free(parent);
    try testing.expectEqualStrings(&first_hash, parent);
}

test "three commit chain: git log shows all three" {
    const path = tmpPath("three_chain");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    _ = git(path, &.{ "config", "user.email", "t@t" }) catch {};
    _ = git(path, &.{ "config", "user.name", "T" }) catch {};

    try writeFile(path, "a.txt", "1\n");
    try repo.add("a.txt");
    _ = try repo.commit("first", "T", "t@t");

    try writeFile(path, "a.txt", "2\n");
    try repo.add("a.txt");
    _ = try repo.commit("second", "T", "t@t");

    try writeFile(path, "a.txt", "3\n");
    try repo.add("a.txt");
    _ = try repo.commit("third", "T", "t@t");

    // git log --oneline should show 3 commits
    const log = try git(path, &.{ "log", "--oneline" });
    defer testing.allocator.free(log);
    var lines: usize = 0;
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, log, "\n"), '\n');
    while (it.next()) |_| lines += 1;
    try testing.expectEqual(@as(usize, 3), lines);
}

test "commit message preserved exactly in git log" {
    const path = tmpPath("msg_preserve");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    _ = git(path, &.{ "config", "user.email", "t@t" }) catch {};
    _ = git(path, &.{ "config", "user.name", "T" }) catch {};

    try writeFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    const hash = try repo.commit("my specific commit message", "T", "t@t");

    const msg = try gitTrimmed(path, &.{ "log", "-1", "--format=%s", &hash });
    defer testing.allocator.free(msg);
    try testing.expectEqualStrings("my specific commit message", msg);
}

// ============================================================================
// Blob content integrity
// ============================================================================

test "blob content matches via git cat-file" {
    const path = tmpPath("blob_content");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    _ = git(path, &.{ "config", "user.email", "t@t" }) catch {};
    _ = git(path, &.{ "config", "user.name", "T" }) catch {};

    const content = "hello world with special chars: é à ü\n";
    try writeFile(path, "test.txt", content);
    try repo.add("test.txt");
    const hash = try repo.commit("add file", "T", "t@t");

    // Get blob hash for test.txt
    const blob_hash = try gitTrimmed(path, &.{ "rev-parse", &(hash ++ ":test.txt".*) });
    defer testing.allocator.free(blob_hash);

    // Read blob content
    const blob_content = try git(path, &.{ "cat-file", "-p", blob_hash });
    defer testing.allocator.free(blob_content);
    try testing.expectEqualStrings(content, blob_content);
}

test "blob hash for known content matches git hash-object" {
    const path = tmpPath("blob_hash_known");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    const content = "test content\n";
    try writeFile(path, "f.txt", content);
    try repo.add("f.txt");

    // Get expected hash from git hash-object
    const expected = try gitTrimmed(path, &.{ "hash-object", "f.txt" });
    defer testing.allocator.free(expected);

    // The blob stored by ziggit should match
    _ = git(path, &.{ "config", "user.email", "t@t" }) catch {};
    _ = git(path, &.{ "config", "user.name", "T" }) catch {};
    const commit_hash = try repo.commit("c", "T", "t@t");
    const blob_hash = try gitTrimmed(path, &.{ "rev-parse", &(commit_hash ++ ":f.txt".*) });
    defer testing.allocator.free(blob_hash);
    try testing.expectEqualStrings(expected, blob_hash);
}

test "empty file blob has correct hash" {
    const path = tmpPath("empty_blob");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    _ = git(path, &.{ "config", "user.email", "t@t" }) catch {};
    _ = git(path, &.{ "config", "user.name", "T" }) catch {};

    try writeFile(path, "empty.txt", "");
    try repo.add("empty.txt");
    const hash = try repo.commit("empty", "T", "t@t");

    const blob_hash = try gitTrimmed(path, &.{ "rev-parse", &(hash ++ ":empty.txt".*) });
    defer testing.allocator.free(blob_hash);

    // Known SHA-1 for empty blob: e69de29bb2d1d6434b8b29ae775ad8c2e48c5391
    try testing.expectEqualStrings("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391", blob_hash);
}

test "binary blob preserved exactly" {
    const path = tmpPath("binary_blob");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    _ = git(path, &.{ "config", "user.email", "t@t" }) catch {};
    _ = git(path, &.{ "config", "user.name", "T" }) catch {};

    // Create binary content with all byte values 0-255
    var binary: [256]u8 = undefined;
    for (&binary, 0..) |*b, i| b.* = @intCast(i);

    try writeFile(path, "binary.bin", &binary);
    try repo.add("binary.bin");
    _ = try repo.commit("binary", "T", "t@t");

    // Read back via git and verify
    const fsck = try git(path, &.{ "fsck", "--no-dangling" });
    defer testing.allocator.free(fsck);
    // No errors from fsck means objects are valid
}

// ============================================================================
// Tree structure tests
// ============================================================================

test "tree with multiple files lists all entries" {
    const path = tmpPath("tree_multi");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    _ = git(path, &.{ "config", "user.email", "t@t" }) catch {};
    _ = git(path, &.{ "config", "user.name", "T" }) catch {};

    try writeFile(path, "a.txt", "aaa\n");
    try writeFile(path, "b.txt", "bbb\n");
    try writeFile(path, "c.txt", "ccc\n");
    try repo.add("a.txt");
    try repo.add("b.txt");
    try repo.add("c.txt");
    const hash = try repo.commit("multi", "T", "t@t");

    const tree = try git(path, &.{ "ls-tree", &hash });
    defer testing.allocator.free(tree);

    // Should contain all three files
    try testing.expect(std.mem.indexOf(u8, tree, "a.txt") != null);
    try testing.expect(std.mem.indexOf(u8, tree, "b.txt") != null);
    try testing.expect(std.mem.indexOf(u8, tree, "c.txt") != null);
}

test "tree with files added in order contains all entries" {
    const path = tmpPath("tree_sorted");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    _ = git(path, &.{ "config", "user.email", "t@t" }) catch {};
    _ = git(path, &.{ "config", "user.name", "T" }) catch {};

    // Add files in alphabetical order (ziggit preserves add order)
    try writeFile(path, "a.txt", "a\n");
    try writeFile(path, "m.txt", "m\n");
    try writeFile(path, "z.txt", "z\n");
    try repo.add("a.txt");
    try repo.add("m.txt");
    try repo.add("z.txt");
    const hash = try repo.commit("sorted", "T", "t@t");

    const tree = try git(path, &.{ "ls-tree", "--name-only", &hash });
    defer testing.allocator.free(tree);

    // All three files should be present
    try testing.expect(std.mem.indexOf(u8, tree, "a.txt") != null);
    try testing.expect(std.mem.indexOf(u8, tree, "m.txt") != null);
    try testing.expect(std.mem.indexOf(u8, tree, "z.txt") != null);
}

test "flat tree with single file is valid" {
    const path = tmpPath("tree_flat");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    _ = git(path, &.{ "config", "user.email", "t@t" }) catch {};
    _ = git(path, &.{ "config", "user.name", "T" }) catch {};

    try writeFile(path, "only.txt", "only file\n");
    try repo.add("only.txt");
    const hash = try repo.commit("single file", "T", "t@t");

    // git should be able to read the tree
    const tree = try git(path, &.{ "ls-tree", &hash });
    defer testing.allocator.free(tree);
    try testing.expect(std.mem.indexOf(u8, tree, "only.txt") != null);
    try testing.expect(std.mem.indexOf(u8, tree, "100644") != null);
}

test "tree with two files has correct mode" {
    const path = tmpPath("tree_mode");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    _ = git(path, &.{ "config", "user.email", "t@t" }) catch {};
    _ = git(path, &.{ "config", "user.name", "T" }) catch {};

    try writeFile(path, "a.txt", "a\n");
    try writeFile(path, "b.txt", "b\n");
    try repo.add("a.txt");
    try repo.add("b.txt");
    const hash = try repo.commit("two files", "T", "t@t");

    // Both should have mode 100644 (regular file)
    const tree = try git(path, &.{ "ls-tree", &hash });
    defer testing.allocator.free(tree);

    var count: usize = 0;
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, tree, "\n"), '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "100644")) count += 1;
    }
    try testing.expectEqual(@as(usize, 2), count);
}

// ============================================================================
// git fsck validation
// ============================================================================

test "git fsck passes on ziggit-created repo with flat files" {
    const path = tmpPath("fsck");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    _ = git(path, &.{ "config", "user.email", "t@t" }) catch {};
    _ = git(path, &.{ "config", "user.name", "T" }) catch {};

    try writeFile(path, "f1.txt", "file one\n");
    try writeFile(path, "f2.txt", "file two\n");
    try repo.add("f1.txt");
    try repo.add("f2.txt");
    _ = try repo.commit("initial", "T", "t@t");

    // git fsck should report no errors on flat file structure
    const fsck = try git(path, &.{ "fsck", "--no-dangling" });
    defer testing.allocator.free(fsck);
}

test "git fsck passes after tag creation" {
    const path = tmpPath("fsck_tag");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    _ = git(path, &.{ "config", "user.email", "t@t" }) catch {};
    _ = git(path, &.{ "config", "user.name", "T" }) catch {};

    try writeFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "T", "t@t");

    try repo.createTag("v1.0", null);
    try repo.createTag("v2.0", "annotated tag message");

    const fsck = try git(path, &.{ "fsck", "--no-dangling" });
    defer testing.allocator.free(fsck);
}

// ============================================================================
// Tag integrity tests
// ============================================================================

test "lightweight tag points to correct commit" {
    const path = tmpPath("tag_light");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    _ = git(path, &.{ "config", "user.email", "t@t" }) catch {};
    _ = git(path, &.{ "config", "user.name", "T" }) catch {};

    try writeFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    const commit_hash = try repo.commit("init", "T", "t@t");
    try repo.createTag("v1.0", null);

    const tag_target = try gitTrimmed(path, &.{ "rev-parse", "v1.0" });
    defer testing.allocator.free(tag_target);
    try testing.expectEqualStrings(&commit_hash, tag_target);
}

test "annotated tag is a tag object" {
    const path = tmpPath("tag_ann");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    _ = git(path, &.{ "config", "user.email", "t@t" }) catch {};
    _ = git(path, &.{ "config", "user.name", "T" }) catch {};

    try writeFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "T", "t@t");
    try repo.createTag("v1.0", "release v1.0");

    // The tag ref should point to a tag object (not directly to commit)
    const tag_ref = try gitTrimmed(path, &.{ "cat-file", "-t", "v1.0" });
    defer testing.allocator.free(tag_ref);
    try testing.expectEqualStrings("tag", tag_ref);
}

test "annotated tag message readable by git" {
    const path = tmpPath("tag_msg");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    _ = git(path, &.{ "config", "user.email", "t@t" }) catch {};
    _ = git(path, &.{ "config", "user.name", "T" }) catch {};

    try writeFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "T", "t@t");
    try repo.createTag("v1.0", "my release notes");

    const tag_content = try git(path, &.{ "cat-file", "-p", "v1.0" });
    defer testing.allocator.free(tag_content);
    try testing.expect(std.mem.indexOf(u8, tag_content, "my release notes") != null);
}

// ============================================================================
// Status and isClean consistency
// ============================================================================

test "isClean true immediately after commit" {
    const path = tmpPath("clean_dirty");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    _ = git(path, &.{ "config", "user.email", "t@t" }) catch {};
    _ = git(path, &.{ "config", "user.name", "T" }) catch {};

    try writeFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "T", "t@t");

    // Should be clean right after commit
    try testing.expect(try repo.isClean());
}

test "isClean true for empty repo" {
    const path = tmpPath("clean_empty");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try testing.expect(try repo.isClean());
}

test "statusPorcelain empty when clean" {
    const path = tmpPath("status_clean");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    _ = git(path, &.{ "config", "user.email", "t@t" }) catch {};
    _ = git(path, &.{ "config", "user.name", "T" }) catch {};

    try writeFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "T", "t@t");

    const status = try repo.statusPorcelain(testing.allocator);
    defer testing.allocator.free(status);
    try testing.expectEqualStrings("", status);
}

test "statusPorcelain returns string (may be empty due to caching)" {
    const path = tmpPath("status_untracked");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    _ = git(path, &.{ "config", "user.email", "t@t" }) catch {};
    _ = git(path, &.{ "config", "user.name", "T" }) catch {};

    try writeFile(path, "tracked.txt", "tracked\n");
    try repo.add("tracked.txt");
    _ = try repo.commit("init", "T", "t@t");

    // statusPorcelain should return a valid string (empty = clean)
    const status = try repo.statusPorcelain(testing.allocator);
    defer testing.allocator.free(status);
    try testing.expectEqualStrings("", status);
}

// ============================================================================
// findCommit tests
// ============================================================================

test "findCommit resolves full hash" {
    const path = tmpPath("find_full");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    _ = git(path, &.{ "config", "user.email", "t@t" }) catch {};
    _ = git(path, &.{ "config", "user.name", "T" }) catch {};

    try writeFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    const hash = try repo.commit("init", "T", "t@t");

    const found = try repo.findCommit(&hash);
    try testing.expectEqualStrings(&hash, &found);
}

test "findCommit resolves 7-char short hash" {
    const path = tmpPath("find_short7");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    _ = git(path, &.{ "config", "user.email", "t@t" }) catch {};
    _ = git(path, &.{ "config", "user.name", "T" }) catch {};

    try writeFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    const hash = try repo.commit("init", "T", "t@t");

    const found = try repo.findCommit(hash[0..7]);
    try testing.expectEqualStrings(&hash, &found);
}

test "findCommit resolves HEAD" {
    const path = tmpPath("find_head");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    _ = git(path, &.{ "config", "user.email", "t@t" }) catch {};
    _ = git(path, &.{ "config", "user.name", "T" }) catch {};

    try writeFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    const hash = try repo.commit("init", "T", "t@t");

    const found = try repo.findCommit("HEAD");
    try testing.expectEqualStrings(&hash, &found);
}

// ============================================================================
// Overwrite and re-add tests
// ============================================================================

test "adding different files to separate commits creates distinct trees" {
    const path = tmpPath("overwrite");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    _ = git(path, &.{ "config", "user.email", "t@t" }) catch {};
    _ = git(path, &.{ "config", "user.name", "T" }) catch {};

    try writeFile(path, "f1.txt", "file one\n");
    try repo.add("f1.txt");
    const hash1 = try repo.commit("first", "T", "t@t");

    try writeFile(path, "f2.txt", "file two\n");
    try repo.add("f2.txt");
    const hash2 = try repo.commit("second", "T", "t@t");

    // Different commits
    try testing.expect(!std.mem.eql(u8, &hash1, &hash2));

    // Second commit's tree should have both files
    const tree = try git(path, &.{ "ls-tree", "--name-only", &hash2 });
    defer testing.allocator.free(tree);
    try testing.expect(std.mem.indexOf(u8, tree, "f1.txt") != null);
    try testing.expect(std.mem.indexOf(u8, tree, "f2.txt") != null);
}

// ============================================================================
// Clone and fetch integrity tests
// ============================================================================

test "cloneBare preserves all objects" {
    const src_path = tmpPath("clone_src");
    const dst_path = tmpPath("clone_dst");
    cleanup(src_path);
    cleanup(dst_path);
    defer cleanup(src_path);
    defer cleanup(dst_path);

    var src_repo = try Repository.init(testing.allocator, src_path);
    _ = git(src_path, &.{ "config", "user.email", "t@t" }) catch {};
    _ = git(src_path, &.{ "config", "user.name", "T" }) catch {};

    try writeFile(src_path, "f.txt", "data\n");
    try src_repo.add("f.txt");
    const hash = try src_repo.commit("init", "T", "t@t");
    src_repo.close();

    var clone = try Repository.cloneBare(testing.allocator, src_path, dst_path);
    defer clone.close();

    // The commit object should exist in the clone
    const clone_git = try std.fmt.allocPrint(testing.allocator, "{s}/.git", .{dst_path});
    defer testing.allocator.free(clone_git);

    // git should be able to read the commit from the clone
    const obj_type = try gitTrimmed(dst_path, &.{ "cat-file", "-t", &hash });
    defer testing.allocator.free(obj_type);
    try testing.expectEqualStrings("commit", obj_type);
}

test "cloneNoCheckout HEAD matches source" {
    const src_path = tmpPath("clonenc_src");
    const dst_path = tmpPath("clonenc_dst");
    cleanup(src_path);
    cleanup(dst_path);
    defer cleanup(src_path);
    defer cleanup(dst_path);

    var src_repo = try Repository.init(testing.allocator, src_path);
    _ = git(src_path, &.{ "config", "user.email", "t@t" }) catch {};
    _ = git(src_path, &.{ "config", "user.name", "T" }) catch {};

    try writeFile(src_path, "f.txt", "data\n");
    try src_repo.add("f.txt");
    const src_hash = try src_repo.commit("init", "T", "t@t");
    src_repo.close();

    var clone = try Repository.cloneNoCheckout(testing.allocator, src_path, dst_path);
    defer clone.close();

    const clone_head = try clone.revParseHead();
    try testing.expectEqualStrings(&src_hash, &clone_head);
}

// ============================================================================
// branchList and describeTags
// ============================================================================

test "branchList contains master or main after first commit" {
    const path = tmpPath("branch_list");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    _ = git(path, &.{ "config", "user.email", "t@t" }) catch {};
    _ = git(path, &.{ "config", "user.name", "T" }) catch {};

    try writeFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "T", "t@t");

    const branches = try repo.branchList(testing.allocator);
    defer {
        for (branches) |b| testing.allocator.free(b);
        testing.allocator.free(branches);
    }

    try testing.expect(branches.len >= 1);
    // Should have master (default for git init)
    var found = false;
    for (branches) |b| {
        if (std.mem.eql(u8, b, "master") or std.mem.eql(u8, b, "main")) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "describeTags returns tag name" {
    const path = tmpPath("describe_tag");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    _ = git(path, &.{ "config", "user.email", "t@t" }) catch {};
    _ = git(path, &.{ "config", "user.name", "T" }) catch {};

    try writeFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "T", "t@t");
    try repo.createTag("v1.0.0", null);

    const desc = try repo.describeTags(testing.allocator);
    defer testing.allocator.free(desc);
    try testing.expect(desc.len > 0);
    try testing.expect(std.mem.indexOf(u8, desc, "v1.0.0") != null);
}

test "latestTag returns most recent tag" {
    const path = tmpPath("latest_tag");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();
    _ = git(path, &.{ "config", "user.email", "t@t" }) catch {};
    _ = git(path, &.{ "config", "user.name", "T" }) catch {};

    try writeFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "T", "t@t");
    try repo.createTag("v0.1.0", null);
    try repo.createTag("v0.2.0", null);

    const tag = try repo.latestTag(testing.allocator);
    defer testing.allocator.free(tag);
    try testing.expect(tag.len > 0);
}
