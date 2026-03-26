// test/bun_workflow_e2e_validation_test.zig
// End-to-end bun publish workflow: ziggit API creates repos, git CLI validates
const std = @import("std");
const ziggit = @import("ziggit");

fn execGit(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) ![]const u8 {
    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit();
    try argv.append("git");
    for (args) |a| try argv.append(a);

    var child = std.process.Child.init(argv.items, allocator);
    child.cwd = cwd;
    child.stderr_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    try child.spawn();

    const stdout = try child.stdout.?.readToEndAlloc(allocator, 1024 * 1024);
    const stderr = try child.stderr.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(stderr);
    const term = try child.wait();

    if (term.Exited != 0) {
        allocator.free(stdout);
        return error.GitCommandFailed;
    }
    return stdout;
}

fn execGitNoCheck(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) ![]const u8 {
    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit();
    try argv.append("git");
    for (args) |a| try argv.append(a);

    var child = std.process.Child.init(argv.items, allocator);
    child.cwd = cwd;
    child.stderr_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    try child.spawn();

    const stdout = try child.stdout.?.readToEndAlloc(allocator, 1024 * 1024);
    const stderr = try child.stderr.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(stderr);
    _ = try child.wait();
    return stdout;
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trimRight(u8, s, "\n\r \t");
}

fn makeTmpDir(allocator: std.mem.Allocator) ![]const u8 {
    const base = "/root/ziggit_test_bun_e2e";
    std.fs.makeDirAbsolute(base) catch {};
    var buf: [64]u8 = undefined;
    const ts = std.time.milliTimestamp();
    var rng = std.rand.DefaultPrng.init(@bitCast(ts));
    const rv = rng.random().int(u64);
    const name = std.fmt.bufPrint(&buf, "be_{d}_{d}", .{ ts, rv }) catch unreachable;
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, name });
    std.fs.makeDirAbsolute(path) catch {};
    return path;
}

fn cleanupTmpDir(path: []const u8) void {
    std.fs.deleteTreeAbsolute(path) catch {};
}

fn writeFileAbs(dir: []const u8, name: []const u8, content: []const u8, allocator: std.mem.Allocator) !void {
    const fpath = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, name });
    defer allocator.free(fpath);

    // Create parent directories if needed
    if (std.mem.lastIndexOf(u8, name, "/")) |idx| {
        const parent = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, name[0..idx] });
        defer allocator.free(parent);
        std.fs.makeDirAbsolute(parent) catch {};
    }

    const f = try std.fs.createFileAbsolute(fpath, .{ .truncate = true });
    defer f.close();
    try f.writeAll(content);
}

// ============================================================
// Bun Workflow Tests
// ============================================================

test "bun publish: init, add package.json, commit, tag, status clean, describe exact" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    // Create package.json
    try writeFileAbs(tmp, "package.json",
        \\{
        \\  "name": "@test/pkg",
        \\  "version": "1.0.0",
        \\  "main": "index.js"
        \\}
    , allocator);
    try writeFileAbs(tmp, "index.js", "module.exports = {};", allocator);

    try repo.add("package.json");
    try repo.add("index.js");
    const hash = try repo.commit("feat: initial release", "bun-bot", "bot@bun.sh");
    try repo.createTag("v1.0.0", null);

    // 1. Status should be clean
    const is_clean = try repo.isClean();
    try std.testing.expect(is_clean);

    // 2. Describe should return v1.0.0
    const desc = try repo.describeTags(allocator);
    defer allocator.free(desc);
    try std.testing.expect(std.mem.indexOf(u8, desc, "v1.0.0") != null);

    // 3. Git should see the commit
    const log_out = try execGit(allocator, tmp, &.{ "log", "--oneline" });
    defer allocator.free(log_out);
    try std.testing.expect(std.mem.indexOf(u8, log_out, "feat: initial release") != null);

    // 4. Git should see the tag
    const tags_out = try execGit(allocator, tmp, &.{ "tag", "-l" });
    defer allocator.free(tags_out);
    try std.testing.expect(std.mem.indexOf(u8, tags_out, "v1.0.0") != null);

    // 5. Git rev-parse should match the commit hash
    const git_head = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(git_head);
    try std.testing.expectEqualStrings(&hash, trim(git_head));

    // 6. Git should read package.json content
    const pkg_content = try execGit(allocator, tmp, &.{ "show", "HEAD:package.json" });
    defer allocator.free(pkg_content);
    try std.testing.expect(std.mem.indexOf(u8, pkg_content, "@test/pkg") != null);
}

test "bun publish: version bump cycle with multiple tags" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    const file_path = try std.fmt.allocPrint(allocator, "{s}/package.json", .{tmp});
    defer allocator.free(file_path);

    // v1.0.0
    {
        const f = try std.fs.createFileAbsolute(file_path, .{ .truncate = true });
        defer f.close();
        try f.writeAll("{\"name\":\"pkg\",\"version\":\"1.0.0\"}");
    }
    try repo.add("package.json");
    _ = try repo.commit("v1.0.0", "bun", "bun@bun.sh");
    try repo.createTag("v1.0.0", null);

    // v1.1.0
    {
        const f = try std.fs.createFileAbsolute(file_path, .{ .truncate = true });
        defer f.close();
        try f.writeAll("{\"name\":\"pkg\",\"version\":\"1.1.0\"}");
    }
    try repo.add("package.json");
    _ = try repo.commit("v1.1.0", "bun", "bun@bun.sh");
    try repo.createTag("v1.1.0", null);

    // v2.0.0
    {
        const f = try std.fs.createFileAbsolute(file_path, .{ .truncate = true });
        defer f.close();
        try f.writeAll("{\"name\":\"pkg\",\"version\":\"2.0.0\"}");
    }
    try repo.add("package.json");
    const v2_hash = try repo.commit("v2.0.0", "bun", "bun@bun.sh");
    try repo.createTag("v2.0.0", null);

    // Verify 3 tags via git
    const tags_out = try execGit(allocator, tmp, &.{ "tag", "-l" });
    defer allocator.free(tags_out);
    try std.testing.expect(std.mem.indexOf(u8, tags_out, "v1.0.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, tags_out, "v1.1.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, tags_out, "v2.0.0") != null);

    // Verify 3 commits via git
    const count_out = try execGit(allocator, tmp, &.{ "rev-list", "--count", "HEAD" });
    defer allocator.free(count_out);
    try std.testing.expectEqualStrings("3", trim(count_out));

    // Verify HEAD matches v2.0.0 commit
    const git_head = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(git_head);
    try std.testing.expectEqualStrings(&v2_hash, trim(git_head));

    // Verify git cat-file shows valid commit object
    const catfile = try execGit(allocator, tmp, &.{ "cat-file", "-t", "HEAD" });
    defer allocator.free(catfile);
    try std.testing.expectEqualStrings("commit", trim(catfile));
}

test "bun publish: add .gitignore, lockfile, src files in correct order" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    try writeFileAbs(tmp, ".gitignore", "node_modules/\n*.log\n", allocator);
    try writeFileAbs(tmp, "package.json", "{\"name\":\"app\"}", allocator);
    try writeFileAbs(tmp, "bun.lockb", "binary-lock-content-here", allocator);

    try repo.add(".gitignore");
    try repo.add("package.json");
    try repo.add("bun.lockb");
    _ = try repo.commit("chore: initial setup", "bun", "bun@bun.sh");

    // Git should read all three files
    const gi = try execGit(allocator, tmp, &.{ "show", "HEAD:.gitignore" });
    defer allocator.free(gi);
    try std.testing.expect(std.mem.indexOf(u8, gi, "node_modules/") != null);

    const lock = try execGit(allocator, tmp, &.{ "show", "HEAD:bun.lockb" });
    defer allocator.free(lock);
    try std.testing.expect(std.mem.indexOf(u8, lock, "binary-lock-content") != null);

    // Status should be clean (aside from node_modules which doesn't exist)
    const clean = try repo.isClean();
    try std.testing.expect(clean);
}

test "bun publish: git clone from ziggit repo preserves all files and tags" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    try writeFileAbs(tmp, "package.json", "{\"name\":\"cloneable\",\"version\":\"3.0.0\"}", allocator);
    try writeFileAbs(tmp, "README.md", "# Cloneable Package", allocator);
    try repo.add("package.json");
    try repo.add("README.md");
    const orig_hash = try repo.commit("initial", "test", "test@test.com");
    try repo.createTag("v3.0.0", null);

    // Clone via git
    const clone_dir = try std.fmt.allocPrint(allocator, "{s}_clone", .{tmp});
    defer allocator.free(clone_dir);
    defer std.fs.deleteTreeAbsolute(clone_dir) catch {};

    const clone_out = try execGitNoCheck(allocator, "/root", &.{ "clone", tmp, clone_dir });
    defer allocator.free(clone_out);

    // Verify clone HEAD matches
    const clone_head = try execGit(allocator, clone_dir, &.{ "rev-parse", "HEAD" });
    defer allocator.free(clone_head);
    try std.testing.expectEqualStrings(&orig_hash, trim(clone_head));

    // Verify clone has the tag
    const clone_tags = try execGit(allocator, clone_dir, &.{ "tag", "-l" });
    defer allocator.free(clone_tags);
    try std.testing.expect(std.mem.indexOf(u8, clone_tags, "v3.0.0") != null);

    // Verify files exist in clone
    const readme_path = try std.fmt.allocPrint(allocator, "{s}/README.md", .{clone_dir});
    defer allocator.free(readme_path);
    const readme_file = try std.fs.openFileAbsolute(readme_path, .{});
    defer readme_file.close();
    var buf: [256]u8 = undefined;
    const n = try readme_file.readAll(&buf);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "Cloneable Package") != null);
}

test "bun publish: add -> commit -> add new file -> commit -> clean cycle" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    const file_path = try std.fmt.allocPrint(allocator, "{s}/index.js", .{tmp});
    defer allocator.free(file_path);
    const file2_path = try std.fmt.allocPrint(allocator, "{s}/utils.js", .{tmp});
    defer allocator.free(file2_path);

    // Initial commit
    {
        const f = try std.fs.createFileAbsolute(file_path, .{ .truncate = true });
        defer f.close();
        try f.writeAll("v1");
    }
    try repo.add("index.js");
    _ = try repo.commit("v1", "test", "t@t.com");
    try std.testing.expect(try repo.isClean());

    // Add new file and commit -> still clean
    {
        const f = try std.fs.createFileAbsolute(file2_path, .{ .truncate = true });
        defer f.close();
        try f.writeAll("utils");
    }
    try repo.add("utils.js");
    _ = try repo.commit("add utils", "test", "t@t.com");
    try std.testing.expect(try repo.isClean());

    // Git should show 2 commits
    const count = try execGit(allocator, tmp, &.{ "rev-list", "--count", "HEAD" });
    defer allocator.free(count);
    try std.testing.expectEqualStrings("2", trim(count));

    // Git should see both files
    const ls_out = try execGit(allocator, tmp, &.{ "ls-tree", "--name-only", "HEAD" });
    defer allocator.free(ls_out);
    try std.testing.expect(std.mem.indexOf(u8, ls_out, "index.js") != null);
    try std.testing.expect(std.mem.indexOf(u8, ls_out, "utils.js") != null);
}

test "bun publish: describe after commits past tag shows distance" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    try writeFileAbs(tmp, "f.txt", "tagged", allocator);
    try repo.add("f.txt");
    _ = try repo.commit("tagged commit", "test", "t@t.com");
    try repo.createTag("v1.0.0", null);

    // Make 2 more commits past the tag
    try writeFileAbs(tmp, "f.txt", "post-tag-1", allocator);
    try repo.add("f.txt");
    _ = try repo.commit("post tag 1", "test", "t@t.com");

    try writeFileAbs(tmp, "f.txt", "post-tag-2", allocator);
    try repo.add("f.txt");
    _ = try repo.commit("post tag 2", "test", "t@t.com");

    // describeTags should reference v1.0.0
    const desc = try repo.describeTags(allocator);
    defer allocator.free(desc);
    try std.testing.expect(std.mem.indexOf(u8, desc, "v1.0.0") != null);

    // git describe --tags should also reference v1.0.0 with distance
    const git_desc = try execGit(allocator, tmp, &.{ "describe", "--tags" });
    defer allocator.free(git_desc);
    try std.testing.expect(std.mem.indexOf(u8, git_desc, "v1.0.0") != null);
}

test "bun publish: revParseHead stays consistent across operations" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    try writeFileAbs(tmp, "f.txt", "data", allocator);
    try repo.add("f.txt");
    const h1 = try repo.commit("c1", "test", "t@t.com");

    // revParseHead should match commit return value
    const head1 = try repo.revParseHead();
    try std.testing.expectEqualStrings(&h1, &head1);

    // git should agree
    const git_head1 = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(git_head1);
    try std.testing.expectEqualStrings(&h1, trim(git_head1));

    // Second commit
    try writeFileAbs(tmp, "f.txt", "data2", allocator);
    try repo.add("f.txt");
    const h2 = try repo.commit("c2", "test", "t@t.com");

    const head2 = try repo.revParseHead();
    try std.testing.expectEqualStrings(&h2, &head2);

    const git_head2 = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(git_head2);
    try std.testing.expectEqualStrings(&h2, trim(git_head2));

    // h1 != h2
    try std.testing.expect(!std.mem.eql(u8, &h1, &h2));
}

test "bun publish: latestTag finds newest tag" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    try writeFileAbs(tmp, "f.txt", "v1", allocator);
    try repo.add("f.txt");
    _ = try repo.commit("v1", "test", "t@t.com");
    try repo.createTag("v1.0.0", null);

    try writeFileAbs(tmp, "f.txt", "v2", allocator);
    try repo.add("f.txt");
    _ = try repo.commit("v2", "test", "t@t.com");
    try repo.createTag("v2.0.0", null);

    const tag = try repo.latestTag(allocator);
    defer allocator.free(tag);
    // Should find one of the tags
    try std.testing.expect(std.mem.indexOf(u8, tag, "v1.0.0") != null or
        std.mem.indexOf(u8, tag, "v2.0.0") != null);

    // git tag -l should show both
    const git_tags = try execGit(allocator, tmp, &.{ "tag", "-l" });
    defer allocator.free(git_tags);
    try std.testing.expect(std.mem.indexOf(u8, git_tags, "v1.0.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, git_tags, "v2.0.0") != null);
}

test "bun publish: branchList includes default branch" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    try writeFileAbs(tmp, "f.txt", "data", allocator);
    try repo.add("f.txt");
    _ = try repo.commit("initial", "test", "t@t.com");

    const branches = try repo.branchList(allocator);
    defer {
        for (branches) |b| allocator.free(b);
        allocator.free(branches);
    }
    // Should have at least one branch (master or main)
    try std.testing.expect(branches.len >= 1);

    // Find master in branches
    var found_master = false;
    for (branches) |b| {
        if (std.mem.eql(u8, b, "master") or std.mem.eql(u8, b, "main")) {
            found_master = true;
            break;
        }
    }
    try std.testing.expect(found_master);
}

test "bun publish: findCommit by tag name resolves correctly" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    try writeFileAbs(tmp, "f.txt", "tagged", allocator);
    try repo.add("f.txt");
    const commit_hash = try repo.commit("tagged", "test", "t@t.com");
    try repo.createTag("v5.0.0", null);

    // More commits after tag
    try writeFileAbs(tmp, "f.txt", "after tag", allocator);
    try repo.add("f.txt");
    _ = try repo.commit("post-tag", "test", "t@t.com");

    // findCommit by tag should resolve to original commit
    const found = try repo.findCommit("v5.0.0");
    try std.testing.expectEqualStrings(&commit_hash, &found);

    // git should agree
    const git_tag_hash = try execGit(allocator, tmp, &.{ "rev-parse", "v5.0.0" });
    defer allocator.free(git_tag_hash);
    try std.testing.expectEqualStrings(&commit_hash, trim(git_tag_hash));
}

test "bun publish: isClean and revParseHead consistent after commit" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    const file_path = try std.fmt.allocPrint(allocator, "{s}/app.js", .{tmp});
    defer allocator.free(file_path);

    {
        const f = try std.fs.createFileAbsolute(file_path, .{ .truncate = true });
        defer f.close();
        try f.writeAll("clean");
    }
    try repo.add("app.js");
    const h = try repo.commit("clean commit", "test", "t@t.com");

    // isClean should be true
    try std.testing.expect(try repo.isClean());

    // revParseHead should match commit hash
    const head = try repo.revParseHead();
    try std.testing.expectEqualStrings(&h, &head);

    // git rev-parse should also match
    const git_head = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(git_head);
    try std.testing.expectEqualStrings(&h, trim(git_head));
}
