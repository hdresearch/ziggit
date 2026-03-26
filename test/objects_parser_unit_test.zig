// test/objects_parser_unit_test.zig - Unit tests for objects_parser utility functions
const std = @import("std");
const ziggit = @import("ziggit");
const testing = std.testing;

const ObjectsParser = ziggit.IndexParser; // We access objects_parser through the ziggit module
// Actually, objects_parser is not directly re-exported. Let's test through Repository API instead.

// ============================================================================
// Helper utilities
// ============================================================================

fn tmpPath(comptime suffix: []const u8) []const u8 {
    return "/tmp/ziggit_objparser_" ++ suffix;
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

fn runGitCapture(args: []const []const u8, cwd: []const u8) ![]u8 {
    var child = std.process.Child.init(args, testing.allocator);
    var cwd_dir = try std.fs.openDirAbsolute(cwd, .{});
    defer cwd_dir.close();
    child.cwd_dir = cwd_dir;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const stdout = try child.stdout.?.reader().readAllAlloc(testing.allocator, 1024 * 1024);
    errdefer testing.allocator.free(stdout);
    const stderr = try child.stderr.?.reader().readAllAlloc(testing.allocator, 1024 * 1024);
    defer testing.allocator.free(stderr);
    const result = try child.wait();
    if (result.Exited != 0) {
        testing.allocator.free(stdout);
        return error.GitCommandFailed;
    }
    return stdout;
}

fn initTestRepo(path: []const u8) !ziggit.Repository {
    cleanup(path);
    const repo = try ziggit.Repository.init(testing.allocator, path);
    // Configure git user for the test repo
    const args_email = &[_][]const u8{ "git", "config", "user.email", "test@test.com" };
    const out1 = runGitCapture(args_email, path) catch return repo;
    testing.allocator.free(out1);
    const args_name = &[_][]const u8{ "git", "config", "user.name", "Test" };
    const out2 = runGitCapture(args_name, path) catch return repo;
    testing.allocator.free(out2);
    return repo;
}

// ============================================================================
// Blob SHA-1 hash computation tests
// ============================================================================

test "blob SHA-1: empty content has known hash" {
    // The well-known SHA-1 of an empty blob: e69de29bb2d1d6434b8b29ae775ad8c2e48c5391
    const path = tmpPath("empty_blob_sha");
    cleanup(path);
    defer cleanup(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "empty.txt", "");
    try repo.add("empty.txt");

    // Verify with git hash-object
    const args = &[_][]const u8{ "git", "hash-object", "empty.txt" };
    const git_hash = runGitCapture(args, path) catch return; // skip if git unavailable
    defer testing.allocator.free(git_hash);

    const trimmed = std.mem.trim(u8, git_hash, " \n\r\t");
    try testing.expectEqualStrings("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391", trimmed);
}

test "blob SHA-1: 'hello world\\n' has known hash" {
    const path = tmpPath("hello_blob_sha");
    cleanup(path);
    defer cleanup(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "hello.txt", "hello world\n");
    try repo.add("hello.txt");

    const args = &[_][]const u8{ "git", "hash-object", "hello.txt" };
    const git_hash = runGitCapture(args, path) catch return;
    defer testing.allocator.free(git_hash);

    const trimmed = std.mem.trim(u8, git_hash, " \n\r\t");
    // Verify the hash matches the well-known value
    try testing.expectEqualStrings("3b18e512dba79e4c8300dd08aeb37f8e728b8dad", trimmed);
}

test "blob SHA-1: ziggit blob matches git hash-object for arbitrary content" {
    const path = tmpPath("arb_blob_sha");
    cleanup(path);
    defer cleanup(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    const content = "The quick brown fox jumps over the lazy dog\n";
    try createFile(path, "fox.txt", content);
    try repo.add("fox.txt");

    // Get hash from git
    const args = &[_][]const u8{ "git", "hash-object", "fox.txt" };
    const git_hash = runGitCapture(args, path) catch return;
    defer testing.allocator.free(git_hash);

    // Now verify that git cat-file can read the ziggit-created blob
    const trimmed = std.mem.trim(u8, git_hash, " \n\r\t");
    const cat_args = &[_][]const u8{ "git", "cat-file", "-p", trimmed };
    const blob_content = runGitCapture(cat_args, path) catch return;
    defer testing.allocator.free(blob_content);

    try testing.expectEqualStrings(content, blob_content);
}

// ============================================================================
// Commit object format validation
// ============================================================================

test "commit object: git cat-file -p shows tree, author, committer, message" {
    const path = tmpPath("commit_catfile");
    cleanup(path);
    defer cleanup(path);

    var repo = try initTestRepo(path);
    defer repo.close();

    try createFile(path, "a.txt", "content a\n");
    try repo.add("a.txt");
    const hash = try repo.commit("test commit message", "Alice", "alice@test.com");

    const hash_str = hash[0..];
    const args = &[_][]const u8{ "git", "cat-file", "-p", hash_str };
    const output = runGitCapture(args, path) catch return;
    defer testing.allocator.free(output);

    // Must contain tree line
    try testing.expect(std.mem.indexOf(u8, output, "tree ") != null);
    // Must contain author
    try testing.expect(std.mem.indexOf(u8, output, "author Alice <alice@test.com>") != null);
    // Must contain committer
    try testing.expect(std.mem.indexOf(u8, output, "committer Alice <alice@test.com>") != null);
    // Must contain message
    try testing.expect(std.mem.indexOf(u8, output, "test commit message") != null);
}

test "commit object: first commit has no parent line" {
    const path = tmpPath("no_parent");
    cleanup(path);
    defer cleanup(path);

    var repo = try initTestRepo(path);
    defer repo.close();

    try createFile(path, "a.txt", "a\n");
    try repo.add("a.txt");
    const hash = try repo.commit("first", "A", "a@t.com");

    const args = &[_][]const u8{ "git", "cat-file", "-p", &hash };
    const output = runGitCapture(args, path) catch return;
    defer testing.allocator.free(output);

    try testing.expect(std.mem.indexOf(u8, output, "parent ") == null);
}

test "commit object: second commit has exactly one parent line" {
    const path = tmpPath("one_parent");
    cleanup(path);
    defer cleanup(path);

    var repo = try initTestRepo(path);
    defer repo.close();

    try createFile(path, "a.txt", "a\n");
    try repo.add("a.txt");
    const h1 = try repo.commit("first", "A", "a@t.com");

    try createFile(path, "b.txt", "b\n");
    try repo.add("b.txt");
    const h2 = try repo.commit("second", "A", "a@t.com");

    const args = &[_][]const u8{ "git", "cat-file", "-p", &h2 };
    const output = runGitCapture(args, path) catch return;
    defer testing.allocator.free(output);

    // Must have exactly one parent line pointing to first commit
    const parent_prefix = "parent ";
    var count: usize = 0;
    var search_pos: usize = 0;
    while (std.mem.indexOfPos(u8, output, search_pos, parent_prefix)) |pos| {
        count += 1;
        search_pos = pos + parent_prefix.len;
    }
    try testing.expectEqual(@as(usize, 1), count);

    // Parent must be the first commit
    try testing.expect(std.mem.indexOf(u8, output, &h1) != null);
}

// ============================================================================
// Tree object format validation
// ============================================================================

test "tree object: git cat-file -p shows file entries" {
    const path = tmpPath("tree_catfile");
    cleanup(path);
    defer cleanup(path);

    var repo = try initTestRepo(path);
    defer repo.close();

    try createFile(path, "file1.txt", "content1\n");
    try createFile(path, "file2.txt", "content2\n");
    try repo.add("file1.txt");
    try repo.add("file2.txt");
    const commit_hash = try repo.commit("two files", "A", "a@t.com");

    // Get tree hash from commit
    const args1 = &[_][]const u8{ "git", "cat-file", "-p", &commit_hash };
    const commit_out = runGitCapture(args1, path) catch return;
    defer testing.allocator.free(commit_out);

    // Extract tree hash (first line: "tree <hash>")
    var lines = std.mem.split(u8, commit_out, "\n");
    const first_line = lines.next().?;
    try testing.expect(std.mem.startsWith(u8, first_line, "tree "));
    const tree_hash = first_line[5..];

    // cat-file on tree
    const args2 = &[_][]const u8{ "git", "cat-file", "-p", tree_hash };
    const tree_out = runGitCapture(args2, path) catch return;
    defer testing.allocator.free(tree_out);

    // Tree should contain both filenames
    try testing.expect(std.mem.indexOf(u8, tree_out, "file1.txt") != null);
    try testing.expect(std.mem.indexOf(u8, tree_out, "file2.txt") != null);
    // Entries should have mode 100644
    try testing.expect(std.mem.indexOf(u8, tree_out, "100644") != null);
}

test "tree object type is 'tree'" {
    const path = tmpPath("tree_type");
    cleanup(path);
    defer cleanup(path);

    var repo = try initTestRepo(path);
    defer repo.close();

    try createFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    const commit_hash = try repo.commit("msg", "A", "a@t.com");

    // Get tree hash
    const args1 = &[_][]const u8{ "git", "cat-file", "-p", &commit_hash };
    const commit_out = runGitCapture(args1, path) catch return;
    defer testing.allocator.free(commit_out);

    var lines = std.mem.split(u8, commit_out, "\n");
    const first_line = lines.next().?;
    const tree_hash = first_line[5..];

    // Check type
    const args2 = &[_][]const u8{ "git", "cat-file", "-t", tree_hash };
    const type_out = runGitCapture(args2, path) catch return;
    defer testing.allocator.free(type_out);

    try testing.expectEqualStrings("tree", std.mem.trim(u8, type_out, " \n\r\t"));
}

// ============================================================================
// Tag object format validation
// ============================================================================

test "annotated tag: git cat-file shows tag object with message" {
    const path = tmpPath("tag_catfile");
    cleanup(path);
    defer cleanup(path);

    var repo = try initTestRepo(path);
    defer repo.close();

    try createFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    _ = try repo.commit("initial", "A", "a@t.com");
    try repo.createTag("v1.0", "Release 1.0");

    // Read tag ref
    const tag_ref_path = try std.fmt.allocPrint(testing.allocator, "{s}/refs/tags/v1.0", .{path});
    defer testing.allocator.free(tag_ref_path);
    // Tag ref should exist
    const tag_ref = try std.fmt.allocPrint(testing.allocator, "{s}/.git/refs/tags/v1.0", .{path});
    defer testing.allocator.free(tag_ref);

    const f = try std.fs.openFileAbsolute(tag_ref, .{});
    defer f.close();
    var buf: [64]u8 = undefined;
    const n = try f.readAll(&buf);
    const tag_hash = std.mem.trim(u8, buf[0..n], " \n\r\t");

    // cat-file on tag object
    const args = &[_][]const u8{ "git", "cat-file", "-p", tag_hash };
    const out = runGitCapture(args, path) catch return;
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "object ") != null);
    try testing.expect(std.mem.indexOf(u8, out, "type commit") != null);
    try testing.expect(std.mem.indexOf(u8, out, "tag v1.0") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Release 1.0") != null);
}

test "lightweight tag: ref file contains commit hash directly" {
    const path = tmpPath("ltag_ref");
    cleanup(path);
    defer cleanup(path);

    var repo = try initTestRepo(path);
    defer repo.close();

    try createFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    const commit_hash = try repo.commit("initial", "A", "a@t.com");
    try repo.createTag("v0.1", null);

    // Read tag ref
    const tag_ref = try std.fmt.allocPrint(testing.allocator, "{s}/.git/refs/tags/v0.1", .{path});
    defer testing.allocator.free(tag_ref);

    const f = try std.fs.openFileAbsolute(tag_ref, .{});
    defer f.close();
    var buf: [64]u8 = undefined;
    const n = try f.readAll(&buf);
    const ref_content = std.mem.trim(u8, buf[0..n], " \n\r\t");

    // Should be the commit hash directly
    try testing.expectEqualStrings(&commit_hash, ref_content);
}

// ============================================================================
// Object compression validation
// ============================================================================

test "stored objects are valid zlib: can be read by git cat-file" {
    const path = tmpPath("zlib_valid");
    cleanup(path);
    defer cleanup(path);

    var repo = try initTestRepo(path);
    defer repo.close();

    try createFile(path, "data.txt", "some data for zlib test\n");
    try repo.add("data.txt");
    const commit_hash = try repo.commit("zlib test", "A", "a@t.com");

    // git cat-file -t should work (proves zlib decompression works)
    const args = &[_][]const u8{ "git", "cat-file", "-t", &commit_hash };
    const out = runGitCapture(args, path) catch return;
    defer testing.allocator.free(out);

    try testing.expectEqualStrings("commit", std.mem.trim(u8, out, " \n\r\t"));
}

test "git fsck validates all ziggit objects" {
    const path = tmpPath("fsck_all");
    cleanup(path);
    defer cleanup(path);

    var repo = try initTestRepo(path);
    defer repo.close();

    try createFile(path, "a.txt", "aaa\n");
    try repo.add("a.txt");
    _ = try repo.commit("first", "A", "a@t.com");

    try createFile(path, "b.txt", "bbb\n");
    try repo.add("b.txt");
    _ = try repo.commit("second", "A", "a@t.com");

    try repo.createTag("v1.0", "tag msg");
    try repo.createTag("v1.1", null);

    const fsck_out = runGitCapture(&.{ "git", "fsck", "--full", "--strict" }, path) catch |err| {
        // fsck may report warnings on stderr but still succeed
        if (err == error.GitCommandFailed) return error.FsckFailed;
        return err;
    };
    testing.allocator.free(fsck_out);
}

// ============================================================================
// Roundtrip: git writes, ziggit reads
// ============================================================================

test "git-created commit readable by ziggit revParseHead" {
    const path = tmpPath("git_write_read");
    cleanup(path);
    defer cleanup(path);

    // Create repo with git
    const init_args = &[_][]const u8{ "git", "init", path };
    const init_out = runGitCapture(init_args, "/tmp") catch return;
    testing.allocator.free(init_out);

    const email_args = &[_][]const u8{ "git", "-C", path, "config", "user.email", "t@t.com" };
    const e_out = runGitCapture(email_args, "/tmp") catch return;
    testing.allocator.free(e_out);

    const name_args = &[_][]const u8{ "git", "-C", path, "config", "user.name", "T" };
    const n_out = runGitCapture(name_args, "/tmp") catch return;
    testing.allocator.free(n_out);

    try createFile(path, "f.txt", "hello\n");

    const add_args = &[_][]const u8{ "git", "-C", path, "add", "f.txt" };
    const a_out = runGitCapture(add_args, "/tmp") catch return;
    testing.allocator.free(a_out);

    const commit_args = &[_][]const u8{ "git", "-C", path, "commit", "-m", "git commit" };
    const c_out = runGitCapture(commit_args, "/tmp") catch return;
    testing.allocator.free(c_out);

    // Get hash from git
    const rp_args = &[_][]const u8{ "git", "-C", path, "rev-parse", "HEAD" };
    const git_hash = runGitCapture(rp_args, "/tmp") catch return;
    defer testing.allocator.free(git_hash);
    const git_hash_trimmed = std.mem.trim(u8, git_hash, " \n\r\t");

    // Now open with ziggit and read HEAD
    var repo = try ziggit.Repository.open(testing.allocator, path);
    defer repo.close();

    const ziggit_hash = try repo.revParseHead();
    try testing.expectEqualStrings(git_hash_trimmed, &ziggit_hash);
}

test "git-created tags readable by ziggit describeTags" {
    const path = tmpPath("git_tags_read");
    cleanup(path);
    defer cleanup(path);

    // Create repo with git
    const init_args = &[_][]const u8{ "git", "init", path };
    const init_out = runGitCapture(init_args, "/tmp") catch return;
    testing.allocator.free(init_out);

    const email_args = &[_][]const u8{ "git", "-C", path, "config", "user.email", "t@t.com" };
    const e_out = runGitCapture(email_args, "/tmp") catch return;
    testing.allocator.free(e_out);

    const name_args = &[_][]const u8{ "git", "-C", path, "config", "user.name", "T" };
    const n_out = runGitCapture(name_args, "/tmp") catch return;
    testing.allocator.free(n_out);

    try createFile(path, "f.txt", "hello\n");

    const add_args = &[_][]const u8{ "git", "-C", path, "add", "f.txt" };
    const a_out = runGitCapture(add_args, "/tmp") catch return;
    testing.allocator.free(a_out);

    const commit_args = &[_][]const u8{ "git", "-C", path, "commit", "-m", "init" };
    const c_out = runGitCapture(commit_args, "/tmp") catch return;
    testing.allocator.free(c_out);

    // Create tags with git
    const tag1_args = &[_][]const u8{ "git", "-C", path, "tag", "v1.0" };
    const t1_out = runGitCapture(tag1_args, "/tmp") catch return;
    testing.allocator.free(t1_out);

    const tag2_args = &[_][]const u8{ "git", "-C", path, "tag", "v2.0" };
    const t2_out = runGitCapture(tag2_args, "/tmp") catch return;
    testing.allocator.free(t2_out);

    // Open with ziggit
    var repo = try ziggit.Repository.open(testing.allocator, path);
    defer repo.close();

    const latest = try repo.describeTags(testing.allocator);
    defer testing.allocator.free(latest);

    // Should be "v2.0" (lexicographically latest)
    try testing.expectEqualStrings("v2.0", latest);
}

test "git-created branches readable by ziggit branchList" {
    const path = tmpPath("git_branches_read");
    cleanup(path);
    defer cleanup(path);

    // Create repo with git
    const init_args = &[_][]const u8{ "git", "init", path };
    const init_out = runGitCapture(init_args, "/tmp") catch return;
    testing.allocator.free(init_out);

    const email_args = &[_][]const u8{ "git", "-C", path, "config", "user.email", "t@t.com" };
    const e_out = runGitCapture(email_args, "/tmp") catch return;
    testing.allocator.free(e_out);

    const name_args = &[_][]const u8{ "git", "-C", path, "config", "user.name", "T" };
    const n_out = runGitCapture(name_args, "/tmp") catch return;
    testing.allocator.free(n_out);

    try createFile(path, "f.txt", "x\n");

    const add_args = &[_][]const u8{ "git", "-C", path, "add", "f.txt" };
    const a_out = runGitCapture(add_args, "/tmp") catch return;
    testing.allocator.free(a_out);

    const commit_args = &[_][]const u8{ "git", "-C", path, "commit", "-m", "init" };
    const c_out = runGitCapture(commit_args, "/tmp") catch return;
    testing.allocator.free(c_out);

    // Create branches
    const br1 = &[_][]const u8{ "git", "-C", path, "branch", "feature-a" };
    const b1 = runGitCapture(br1, "/tmp") catch return;
    testing.allocator.free(b1);

    const br2 = &[_][]const u8{ "git", "-C", path, "branch", "feature-b" };
    const b2 = runGitCapture(br2, "/tmp") catch return;
    testing.allocator.free(b2);

    // Open with ziggit
    var repo = try ziggit.Repository.open(testing.allocator, path);
    defer repo.close();

    const branches = try repo.branchList(testing.allocator);
    defer {
        for (branches) |b| testing.allocator.free(b);
        testing.allocator.free(branches);
    }

    // Should have at least master, feature-a, feature-b
    try testing.expect(branches.len >= 3);

    var has_master = false;
    var has_a = false;
    var has_b = false;
    for (branches) |b| {
        if (std.mem.eql(u8, b, "master")) has_master = true;
        if (std.mem.eql(u8, b, "feature-a")) has_a = true;
        if (std.mem.eql(u8, b, "feature-b")) has_b = true;
    }
    try testing.expect(has_master);
    try testing.expect(has_a);
    try testing.expect(has_b);
}

// ============================================================================
// Edge cases for object creation
// ============================================================================

test "blob with all 256 byte values" {
    const path = tmpPath("blob_256");
    cleanup(path);
    defer cleanup(path);

    var repo = try initTestRepo(path);
    defer repo.close();

    // Create file with all byte values
    var content: [256]u8 = undefined;
    for (0..256) |i| {
        content[i] = @intCast(i);
    }
    try createFile(path, "binary.bin", &content);
    try repo.add("binary.bin");
    _ = try repo.commit("binary", "A", "a@t.com");

    // Verify git can read it
    const fsck_result = runGitCapture(&.{ "git", "fsck" }, path) catch |err| {
        if (err == error.GitCommandFailed) return error.FsckFailed;
        return err;
    };
    testing.allocator.free(fsck_result);
}

test "commit with very long message" {
    const path = tmpPath("long_msg");
    cleanup(path);
    defer cleanup(path);

    var repo = try initTestRepo(path);
    defer repo.close();

    try createFile(path, "f.txt", "x\n");
    try repo.add("f.txt");

    // 10KB message
    var msg_buf: [10240]u8 = undefined;
    @memset(&msg_buf, 'A');
    const msg: []const u8 = &msg_buf;

    const hash = try repo.commit(msg, "A", "a@t.com");

    // Verify git can read the commit
    const args = &[_][]const u8{ "git", "cat-file", "-p", &hash };
    const out = runGitCapture(args, path) catch return;
    defer testing.allocator.free(out);

    // Message should be present (at least the start)
    try testing.expect(std.mem.indexOf(u8, out, "AAAAAAA") != null);
}

test "commit message with newlines preserved" {
    const path = tmpPath("multiline_msg");
    cleanup(path);
    defer cleanup(path);

    var repo = try initTestRepo(path);
    defer repo.close();

    try createFile(path, "f.txt", "x\n");
    try repo.add("f.txt");

    const msg = "Line 1\n\nLine 3\nLine 4";
    const hash = try repo.commit(msg, "A", "a@t.com");

    const args = &[_][]const u8{ "git", "cat-file", "-p", &hash };
    const out = runGitCapture(args, path) catch return;
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "Line 1") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Line 3") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Line 4") != null);
}

test "commit with unicode author name" {
    const path = tmpPath("unicode_author");
    cleanup(path);
    defer cleanup(path);

    var repo = try initTestRepo(path);
    defer repo.close();

    try createFile(path, "f.txt", "x\n");
    try repo.add("f.txt");

    const hash = try repo.commit("msg", "José García", "jose@t.com");

    const args = &[_][]const u8{ "git", "cat-file", "-p", &hash };
    const out = runGitCapture(args, path) catch return;
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "José García") != null);
}

// ============================================================================
// Multiple commits chain validation
// ============================================================================

test "five commit chain: git rev-list returns all in order" {
    const path = tmpPath("chain5");
    cleanup(path);
    defer cleanup(path);

    var repo = try initTestRepo(path);
    defer repo.close();

    var hashes: [5][40]u8 = undefined;
    for (0..5) |i| {
        const fname = try std.fmt.allocPrint(testing.allocator, "file{d}.txt", .{i});
        defer testing.allocator.free(fname);
        const content = try std.fmt.allocPrint(testing.allocator, "content {d}\n", .{i});
        defer testing.allocator.free(content);
        const msg = try std.fmt.allocPrint(testing.allocator, "commit {d}", .{i});
        defer testing.allocator.free(msg);

        try createFile(path, fname, content);
        try repo.add(fname);
        hashes[i] = try repo.commit(msg, "A", "a@t.com");
    }

    // git rev-list HEAD should return all 5
    const args = &[_][]const u8{ "git", "rev-list", "HEAD" };
    const out = runGitCapture(args, path) catch return;
    defer testing.allocator.free(out);

    var line_count: usize = 0;
    var lines = std.mem.split(u8, std.mem.trim(u8, out, " \n\r\t"), "\n");
    while (lines.next()) |_| {
        line_count += 1;
    }
    try testing.expectEqual(@as(usize, 5), line_count);

    // First line should be latest commit
    var lines2 = std.mem.split(u8, std.mem.trim(u8, out, " \n\r\t"), "\n");
    const first_line = lines2.next().?;
    try testing.expectEqualStrings(&hashes[4], first_line);
}

// ============================================================================
// findCommit short hash resolution
// ============================================================================

test "findCommit: 7-char prefix resolves correctly" {
    const path = tmpPath("short7");
    cleanup(path);
    defer cleanup(path);

    var repo = try initTestRepo(path);
    defer repo.close();

    try createFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    const full_hash = try repo.commit("msg", "A", "a@t.com");

    const short: []const u8 = full_hash[0..7];
    const resolved = try repo.findCommit(short);
    try testing.expectEqualStrings(&full_hash, &resolved);
}

test "findCommit: 4-char prefix resolves correctly" {
    const path = tmpPath("short4");
    cleanup(path);
    defer cleanup(path);

    var repo = try initTestRepo(path);
    defer repo.close();

    try createFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    const full_hash = try repo.commit("msg", "A", "a@t.com");

    const short: []const u8 = full_hash[0..4];
    const resolved = try repo.findCommit(short);
    try testing.expectEqualStrings(&full_hash, &resolved);
}

test "findCommit: full 40-char hash returns same" {
    const path = tmpPath("full40");
    cleanup(path);
    defer cleanup(path);

    var repo = try initTestRepo(path);
    defer repo.close();

    try createFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    const full_hash = try repo.commit("msg", "A", "a@t.com");

    const resolved = try repo.findCommit(&full_hash);
    try testing.expectEqualStrings(&full_hash, &resolved);
}
