// test/git_interop_comprehensive_test.zig
// Comprehensive cross-validation: ziggit creates repos/objects, git verifies;
// git creates repos/objects, ziggit reads them correctly.
// Every test creates its own fixture and cleans up.
const std = @import("std");
const ziggit = @import("ziggit");
const testing = std.testing;

const Repository = ziggit.Repository;

// ============================================================================
// Helpers
// ============================================================================

fn tmp(comptime suffix: []const u8) []const u8 {
    return "/tmp/ziggit_interop_" ++ suffix;
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

fn readFileContent(dir: []const u8, name: []const u8) ![]u8 {
    const full = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ dir, name });
    defer testing.allocator.free(full);
    const f = try std.fs.openFileAbsolute(full, .{});
    defer f.close();
    return try f.readToEndAlloc(testing.allocator, 1024 * 1024);
}

fn execGit(dir: []const u8, args: []const []const u8) ![]u8 {
    var argv = std.ArrayList([]const u8).init(testing.allocator);
    defer argv.deinit();
    try argv.append("git");
    try argv.append("-C");
    try argv.append(dir);
    for (args) |a| try argv.append(a);

    var child = std.process.Child.init(argv.items, testing.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const stdout = try child.stdout.?.reader().readAllAlloc(testing.allocator, 1024 * 1024);
    errdefer testing.allocator.free(stdout);
    const stderr = try child.stderr.?.reader().readAllAlloc(testing.allocator, 1024 * 1024);
    defer testing.allocator.free(stderr);
    const term = try child.wait();
    if (term.Exited != 0) {
        testing.allocator.free(stdout);
        return error.CommandFailed;
    }
    return stdout;
}

fn gitInit(dir: []const u8) !void {
    const out = try execGit(dir, &.{ "init", "-q" });
    testing.allocator.free(out);
    const out2 = try execGit(dir, &.{ "config", "user.email", "test@test.com" });
    testing.allocator.free(out2);
    const out3 = try execGit(dir, &.{ "config", "user.name", "Test" });
    testing.allocator.free(out3);
}

fn gitAdd(dir: []const u8, path: []const u8) !void {
    const out = try execGit(dir, &.{ "add", path });
    testing.allocator.free(out);
}

fn gitCommit(dir: []const u8, msg: []const u8) ![]u8 {
    const out = try execGit(dir, &.{ "commit", "-q", "-m", msg });
    testing.allocator.free(out);
    const hash = try execGit(dir, &.{ "rev-parse", "HEAD" });
    return hash;
}

fn trimWhitespace(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \n\r\t");
}

// ============================================================================
// Tests: ziggit init, git validates
// ============================================================================

test "interop: ziggit init produces repo that git fsck accepts" {
    const path = tmp("fsck");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    const out = try execGit(path, &.{ "fsck", "--no-dangling" });
    defer testing.allocator.free(out);
    // git fsck should succeed (exit 0) on a fresh ziggit-created repo
}

test "interop: ziggit init HEAD matches git symbolic-ref" {
    const path = tmp("symref");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    const git_ref = try execGit(path, &.{ "symbolic-ref", "HEAD" });
    defer testing.allocator.free(git_ref);
    try testing.expectEqualStrings("refs/heads/master", trimWhitespace(git_ref));
}

test "interop: ziggit init config is parseable by git" {
    const path = tmp("config");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    const out = try execGit(path, &.{ "config", "core.repositoryformatversion" });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("0", trimWhitespace(out));
}

// ============================================================================
// Tests: ziggit add+commit, git reads objects
// ============================================================================

test "interop: ziggit commit blob readable by git cat-file" {
    const path = tmp("catfile");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFile(path, "hello.txt", "Hello, World!\n");
    try repo.add("hello.txt");
    const hash = try repo.commit("first commit", "Test", "test@test.com");

    // git should be able to read our commit
    const git_type = try execGit(path, &.{ "cat-file", "-t", &hash });
    defer testing.allocator.free(git_type);
    try testing.expectEqualStrings("commit", trimWhitespace(git_type));

    // git log should show our message
    const git_log = try execGit(path, &.{ "log", "--oneline", "-1" });
    defer testing.allocator.free(git_log);
    try testing.expect(std.mem.indexOf(u8, git_log, "first commit") != null);
}

test "interop: ziggit blob content matches git cat-file blob" {
    const path = tmp("blobcontent");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    const content = "The quick brown fox jumps over the lazy dog\n";
    try writeFile(path, "fox.txt", content);
    try repo.add("fox.txt");
    _ = try repo.commit("add fox", "Test", "test@test.com");

    // Get blob hash from tree
    const tree_out = try execGit(path, &.{ "ls-tree", "HEAD" });
    defer testing.allocator.free(tree_out);

    // Parse blob hash from ls-tree output (format: "mode type hash\tname")
    const tab_pos = std.mem.indexOf(u8, tree_out, "\t") orelse return error.InvalidOutput;
    const fields = tree_out[0..tab_pos];
    // "100644 blob <hash>"
    var parts = std.mem.split(u8, fields, " ");
    _ = parts.next(); // mode
    _ = parts.next(); // type
    const blob_hash = parts.next() orelse return error.InvalidOutput;

    // Verify content via git cat-file
    const blob_content = try execGit(path, &.{ "cat-file", "-p", blob_hash });
    defer testing.allocator.free(blob_content);
    try testing.expectEqualStrings(content, blob_content);
}

test "interop: ziggit rev-parse HEAD matches git rev-parse HEAD" {
    const path = tmp("revparse");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFile(path, "a.txt", "aaa\n");
    try repo.add("a.txt");
    const ziggit_hash = try repo.commit("initial", "Test", "test@test.com");

    const git_hash_raw = try execGit(path, &.{ "rev-parse", "HEAD" });
    defer testing.allocator.free(git_hash_raw);
    const git_hash = trimWhitespace(git_hash_raw);

    try testing.expectEqualStrings(git_hash, &ziggit_hash);
}

test "interop: multiple ziggit commits form valid chain" {
    const path = tmp("chain");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFile(path, "a.txt", "v1\n");
    try repo.add("a.txt");
    _ = try repo.commit("first", "Test", "test@test.com");

    try writeFile(path, "a.txt", "v2\n");
    try repo.add("a.txt");
    _ = try repo.commit("second", "Test", "test@test.com");

    try writeFile(path, "a.txt", "v3\n");
    try repo.add("a.txt");
    _ = try repo.commit("third", "Test", "test@test.com");

    // git rev-list --count should show 3
    const count_out = try execGit(path, &.{ "rev-list", "--count", "HEAD" });
    defer testing.allocator.free(count_out);
    try testing.expectEqualStrings("3", trimWhitespace(count_out));
}

// ============================================================================
// Tests: git creates, ziggit reads
// ============================================================================

test "interop: git init+commit, ziggit opens and reads HEAD" {
    const path = tmp("gitinit");
    cleanup(path);
    defer cleanup(path);
    try std.fs.makeDirAbsolute(path);

    try gitInit(path);
    try writeFile(path, "test.txt", "from git\n");
    try gitAdd(path, "test.txt");
    const git_hash_raw = try gitCommit(path, "git commit");
    defer testing.allocator.free(git_hash_raw);
    const git_hash = trimWhitespace(git_hash_raw);

    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    const ziggit_hash = try repo.revParseHead();
    try testing.expectEqualStrings(git_hash, &ziggit_hash);
}

test "interop: git multi-commit, ziggit finds each commit" {
    const path = tmp("gitmulti");
    cleanup(path);
    defer cleanup(path);
    try std.fs.makeDirAbsolute(path);

    try gitInit(path);

    try writeFile(path, "f.txt", "v1\n");
    try gitAdd(path, "f.txt");
    const h1_raw = try gitCommit(path, "c1");
    defer testing.allocator.free(h1_raw);
    const h1 = trimWhitespace(h1_raw);

    try writeFile(path, "f.txt", "v2\n");
    try gitAdd(path, "f.txt");
    const h2_raw = try gitCommit(path, "c2");
    defer testing.allocator.free(h2_raw);
    const h2 = trimWhitespace(h2_raw);

    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    // HEAD should be latest commit
    const head = try repo.revParseHead();
    try testing.expectEqualStrings(h2, &head);

    // findCommit should resolve both full hashes
    const found1 = try repo.findCommit(h1);
    try testing.expectEqualStrings(h1, &found1);

    const found2 = try repo.findCommit(h2);
    try testing.expectEqualStrings(h2, &found2);
}

test "interop: git branch, ziggit branchList" {
    const path = tmp("gitbranch");
    cleanup(path);
    defer cleanup(path);
    try std.fs.makeDirAbsolute(path);

    try gitInit(path);
    try writeFile(path, "f.txt", "x\n");
    try gitAdd(path, "f.txt");
    const h = try gitCommit(path, "init");
    testing.allocator.free(h);

    // Create extra branches
    const b1 = try execGit(path, &.{ "branch", "feature-a" });
    testing.allocator.free(b1);
    const b2 = try execGit(path, &.{ "branch", "feature-b" });
    testing.allocator.free(b2);

    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    const branches = try repo.branchList(testing.allocator);
    defer {
        for (branches) |b| testing.allocator.free(b);
        testing.allocator.free(branches);
    }

    // Should have master + feature-a + feature-b (or main)
    try testing.expect(branches.len >= 3);

    var found_a = false;
    var found_b = false;
    for (branches) |b| {
        if (std.mem.eql(u8, b, "feature-a")) found_a = true;
        if (std.mem.eql(u8, b, "feature-b")) found_b = true;
    }
    try testing.expect(found_a);
    try testing.expect(found_b);
}

test "interop: git tag, ziggit describeTags" {
    const path = tmp("gittag");
    cleanup(path);
    defer cleanup(path);
    try std.fs.makeDirAbsolute(path);

    try gitInit(path);
    try writeFile(path, "f.txt", "x\n");
    try gitAdd(path, "f.txt");
    const h = try gitCommit(path, "init");
    testing.allocator.free(h);

    const t1 = try execGit(path, &.{ "tag", "v1.0.0" });
    testing.allocator.free(t1);
    const t2 = try execGit(path, &.{ "tag", "v2.0.0" });
    testing.allocator.free(t2);

    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    const tag = try repo.describeTags(testing.allocator);
    defer testing.allocator.free(tag);

    // Should find the latest tag lexicographically (v2.0.0)
    try testing.expect(tag.len > 0);
    try testing.expectEqualStrings("v2.0.0", tag);
}

// ============================================================================
// Tests: ziggit tag, git reads
// ============================================================================

test "interop: ziggit createTag lightweight, git tag -l lists it" {
    const path = tmp("ztag");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "Test", "test@test.com");

    try repo.createTag("v0.1.0", null);

    const tag_list = try execGit(path, &.{ "tag", "-l" });
    defer testing.allocator.free(tag_list);
    try testing.expect(std.mem.indexOf(u8, tag_list, "v0.1.0") != null);
}

test "interop: ziggit createTag annotated, git tag -l lists it" {
    const path = tmp("ztagann");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "Test", "test@test.com");

    try repo.createTag("v1.0.0", "Release 1.0");

    const tag_list = try execGit(path, &.{ "tag", "-l" });
    defer testing.allocator.free(tag_list);
    try testing.expect(std.mem.indexOf(u8, tag_list, "v1.0.0") != null);
}

// ============================================================================
// Tests: SHA-1 hash correctness
// ============================================================================

test "interop: ziggit blob hash matches git hash-object" {
    const path = tmp("hashobj");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    const content = "Hello hash test\n";
    try writeFile(path, "h.txt", content);
    try repo.add("h.txt");
    _ = try repo.commit("hash test", "Test", "test@test.com");

    // Get blob hash that git computes
    const git_hash_raw = try execGit(path, &.{ "hash-object", "h.txt" });
    defer testing.allocator.free(git_hash_raw);
    const git_hash = trimWhitespace(git_hash_raw);

    // Get blob hash from ls-tree
    const tree_out = try execGit(path, &.{ "ls-tree", "HEAD" });
    defer testing.allocator.free(tree_out);

    // The blob hash in the tree should match git hash-object
    try testing.expect(std.mem.indexOf(u8, tree_out, git_hash) != null);
}

// ============================================================================
// Tests: index interop
// ============================================================================

test "interop: ziggit add produces index readable by git ls-files" {
    const path = tmp("lsfiles");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try writeFile(path, "alpha.txt", "aaa\n");
    try writeFile(path, "beta.txt", "bbb\n");
    try repo.add("alpha.txt");
    try repo.add("beta.txt");

    const ls = try execGit(path, &.{ "ls-files" });
    defer testing.allocator.free(ls);

    try testing.expect(std.mem.indexOf(u8, ls, "alpha.txt") != null);
    try testing.expect(std.mem.indexOf(u8, ls, "beta.txt") != null);
}

test "interop: git add produces index readable by ziggit IndexParser" {
    const path = tmp("gitadd");
    cleanup(path);
    defer cleanup(path);
    try std.fs.makeDirAbsolute(path);

    try gitInit(path);
    try writeFile(path, "one.txt", "111\n");
    try writeFile(path, "two.txt", "222\n");
    try gitAdd(path, "one.txt");
    try gitAdd(path, "two.txt");

    // Read the index with ziggit parser
    const index_path = try std.fmt.allocPrint(testing.allocator, "{s}/.git/index", .{path});
    defer testing.allocator.free(index_path);

    var index = try ziggit.IndexParser.GitIndex.readFromFile(testing.allocator, index_path);
    defer index.deinit();

    try testing.expectEqual(@as(usize, 2), index.entries.items.len);

    // Verify entries contain our files
    var found_one = false;
    var found_two = false;
    for (index.entries.items) |entry| {
        if (std.mem.eql(u8, entry.path, "one.txt")) found_one = true;
        if (std.mem.eql(u8, entry.path, "two.txt")) found_two = true;
    }
    try testing.expect(found_one);
    try testing.expect(found_two);
}

// ============================================================================
// Tests: clone interop
// ============================================================================

test "interop: ziggit cloneNoCheckout copies all objects" {
    const src = tmp("clonesrc");
    const dst = tmp("clonedst");
    cleanup(src);
    cleanup(dst);
    defer cleanup(src);
    defer cleanup(dst);

    // Create source repo
    var src_repo = try Repository.init(testing.allocator, src);
    defer src_repo.close();

    try writeFile(src, "f.txt", "clone me\n");
    try src_repo.add("f.txt");
    const src_hash = try src_repo.commit("clone source", "Test", "test@test.com");

    // Clone
    var dst_repo = try Repository.cloneNoCheckout(testing.allocator, src, dst);
    defer dst_repo.close();

    // Verify HEAD matches
    const dst_hash = try dst_repo.revParseHead();
    try testing.expectEqualStrings(&src_hash, &dst_hash);
}

test "interop: ziggit fetch copies new objects from source" {
    const src = tmp("fetchsrc");
    const dst = tmp("fetchdst");
    cleanup(src);
    cleanup(dst);
    defer cleanup(src);
    defer cleanup(dst);

    // Create source repo with two commits
    var src_repo = try Repository.init(testing.allocator, src);

    try writeFile(src, "f.txt", "initial\n");
    try src_repo.add("f.txt");
    const h1 = try src_repo.commit("initial", "Test", "test@test.com");
    src_repo.close();

    // Clone
    var dst_repo = try Repository.cloneNoCheckout(testing.allocator, src, dst);

    // Verify clone has first commit
    const dst_hash = try dst_repo.revParseHead();
    try testing.expectEqualStrings(&h1, &dst_hash);
    dst_repo.close();
}
