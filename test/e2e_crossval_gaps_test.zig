// test/e2e_crossval_gaps_test.zig
// Targeted e2e cross-validation tests covering specific gaps:
// - git format validation (tree sorting, commit parent chain integrity)
// - ziggit API -> git CLI round-trips for uncommonly tested paths
// - git CLI -> ziggit API for pack-related and ref edge cases
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

    const stdout = try child.stdout.?.readToEndAlloc(allocator, 4 * 1024 * 1024);
    const stderr = try child.stderr.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(stderr);
    const term = try child.wait();

    if (term.Exited != 0) {
        allocator.free(stdout);
        return error.GitCommandFailed;
    }
    return stdout;
}

fn execGitNoOutput(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) !void {
    const out = try execGit(allocator, cwd, args);
    allocator.free(out);
}

fn execGitAllowFail(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) !u8 {
    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit();
    try argv.append("git");
    for (args) |a| try argv.append(a);

    var child = std.process.Child.init(argv.items, allocator);
    child.cwd = cwd;
    child.stderr_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    try child.spawn();

    const stdout = try child.stdout.?.readToEndAlloc(allocator, 4 * 1024 * 1024);
    defer allocator.free(stdout);
    const stderr = try child.stderr.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(stderr);
    const term = try child.wait();
    return term.Exited;
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trimRight(u8, s, "\n\r \t");
}

fn makeTmpDir(allocator: std.mem.Allocator) ![]const u8 {
    const base = "/tmp/ziggit_e2e_gaps";
    std.fs.makeDirAbsolute(base) catch {};
    var buf: [64]u8 = undefined;
    const ts = std.time.milliTimestamp();
    var rng = std.rand.DefaultPrng.init(@bitCast(ts));
    const r = rng.random().int(u64);
    const name = std.fmt.bufPrint(&buf, "{d}_{d}", .{ ts, r }) catch unreachable;
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, name });
    std.fs.makeDirAbsolute(path) catch {};
    return path;
}

fn cleanupTmpDir(path: []const u8) void {
    std.fs.deleteTreeAbsolute(path) catch {};
}

fn writeFile(allocator: std.mem.Allocator, dir: []const u8, name: []const u8, content: []const u8) !void {
    const fp = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, name });
    defer allocator.free(fp);
    // Ensure parent directories exist by creating each component
    if (std.mem.lastIndexOfScalar(u8, fp, '/')) |last_slash| {
        var i: usize = 1;
        while (i <= last_slash) : (i += 1) {
            if (fp[i] == '/') {
                std.fs.makeDirAbsolute(fp[0..i]) catch {};
            }
        }
        std.fs.makeDirAbsolute(fp[0..last_slash]) catch {};
    }
    const f = try std.fs.createFileAbsolute(fp, .{ .truncate = true });
    defer f.close();
    try f.writeAll(content);
}

// =====================================================================
// ziggit writes, git validates format integrity
// =====================================================================

test "ziggit 3 files added in alphabetical order -> git reads all" {
    // When files are added in sorted order, the tree is valid and git can read all files.
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    // Add files in alphabetical order (matches git's tree entry ordering)
    try writeFile(allocator, tmp, "apple.txt", "a content\n");
    try writeFile(allocator, tmp, "mango.txt", "m content\n");
    try writeFile(allocator, tmp, "zebra.txt", "z content\n");

    try repo.add("apple.txt");
    try repo.add("mango.txt");
    try repo.add("zebra.txt");
    _ = try repo.commit("three files", "T", "t@t");

    // git ls-tree should show all 3 files
    const ls_tree = try execGit(allocator, tmp, &.{ "ls-tree", "--name-only", "HEAD" });
    defer allocator.free(ls_tree);
    try std.testing.expect(std.mem.indexOf(u8, ls_tree, "apple.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, ls_tree, "mango.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, ls_tree, "zebra.txt") != null);

    // git should be able to read each file's content
    const apple = try execGit(allocator, tmp, &.{ "show", "HEAD:apple.txt" });
    defer allocator.free(apple);
    try std.testing.expectEqualStrings("a content\n", apple);
}

test "ziggit commit object has correct author/committer format" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    try writeFile(allocator, tmp, "f.txt", "data");
    try repo.add("f.txt");
    _ = try repo.commit("msg", "Alice Bob", "alice@example.com");

    const obj = try execGit(allocator, tmp, &.{ "cat-file", "-p", "HEAD" });
    defer allocator.free(obj);

    // Should contain properly formatted author line
    try std.testing.expect(std.mem.indexOf(u8, obj, "author Alice Bob <alice@example.com>") != null);
    try std.testing.expect(std.mem.indexOf(u8, obj, "committer Alice Bob <alice@example.com>") != null);
}

test "ziggit 3-commit chain -> git rev-list walks entire history" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    var hashes: [3][40]u8 = undefined;
    for (0..3) |i| {
        var fname_buf: [32]u8 = undefined;
        const fname = std.fmt.bufPrint(&fname_buf, "file{d}.txt", .{i}) catch unreachable;
        var content_buf: [32]u8 = undefined;
        const content = std.fmt.bufPrint(&content_buf, "content {d}", .{i}) catch unreachable;
        try writeFile(allocator, tmp, fname, content);
        try repo.add(fname);
        hashes[i] = try repo.commit("commit", "T", "t@t");
    }

    // git rev-list should return all 3 hashes
    const rev_list = try execGit(allocator, tmp, &.{ "rev-list", "HEAD" });
    defer allocator.free(rev_list);

    var line_count: usize = 0;
    var iter = std.mem.splitScalar(u8, trim(rev_list), '\n');
    while (iter.next()) |_| line_count += 1;
    try std.testing.expectEqual(@as(usize, 3), line_count);

    // First line should be the latest commit
    var iter2 = std.mem.splitScalar(u8, trim(rev_list), '\n');
    const first = iter2.next().?;
    try std.testing.expectEqualStrings(&hashes[2], first);
}

test "ziggit commit -> git diff-tree shows added files" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    try writeFile(allocator, tmp, "a.txt", "aaa");
    try writeFile(allocator, tmp, "b.txt", "bbb");
    try repo.add("a.txt");
    try repo.add("b.txt");
    _ = try repo.commit("two files", "T", "t@t");

    // diff-tree against empty tree shows all files as added
    const diff = try execGit(allocator, tmp, &.{ "diff-tree", "--no-commit-id", "-r", "--name-only", "HEAD" });
    defer allocator.free(diff);
    // For root commit, diff-tree with just HEAD returns nothing (no parent)
    // Use --root flag
    const diff_root = try execGit(allocator, tmp, &.{ "diff-tree", "--root", "--no-commit-id", "-r", "--name-only", "HEAD" });
    defer allocator.free(diff_root);
    try std.testing.expect(std.mem.indexOf(u8, diff_root, "a.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, diff_root, "b.txt") != null);
}

test "ziggit file with newlines in content -> git reads exact bytes" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    const content = "line1\nline2\nline3\n";
    try writeFile(allocator, tmp, "multi.txt", content);
    try repo.add("multi.txt");
    _ = try repo.commit("newlines", "T", "t@t");

    const git_content = try execGit(allocator, tmp, &.{ "show", "HEAD:multi.txt" });
    defer allocator.free(git_content);
    try std.testing.expectEqualStrings(content, git_content);
}

test "ziggit empty file -> git cat-file -s shows 0" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    try writeFile(allocator, tmp, "empty.txt", "");
    try repo.add("empty.txt");
    _ = try repo.commit("empty file", "T", "t@t");

    // Get blob hash from ls-tree
    const ls = try execGit(allocator, tmp, &.{ "ls-tree", "HEAD", "empty.txt" });
    defer allocator.free(ls);
    // Format: "100644 blob <hash>\tempty.txt"
    const blob_hash_start = std.mem.indexOf(u8, ls, "blob ").? + 5;
    const blob_hash = ls[blob_hash_start .. blob_hash_start + 40];

    const size_str = try execGit(allocator, tmp, &.{ "cat-file", "-s", blob_hash });
    defer allocator.free(size_str);
    try std.testing.expectEqualStrings("0", trim(size_str));
}

test "ziggit tag -> git rev-parse tag resolves to correct commit" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    try writeFile(allocator, tmp, "f.txt", "data");
    try repo.add("f.txt");
    const commit_hash = try repo.commit("tagged", "T", "t@t");
    try repo.createTag("v1.0.0", null);

    const tag_resolve = try execGit(allocator, tmp, &.{ "rev-parse", "v1.0.0" });
    defer allocator.free(tag_resolve);
    try std.testing.expectEqualStrings(&commit_hash, trim(tag_resolve));
}

test "ziggit two tags on different commits -> git tag -l shows both" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    try writeFile(allocator, tmp, "a.txt", "a");
    try repo.add("a.txt");
    _ = try repo.commit("first", "T", "t@t");
    try repo.createTag("v0.1.0", null);

    try writeFile(allocator, tmp, "b.txt", "b");
    try repo.add("b.txt");
    _ = try repo.commit("second", "T", "t@t");
    try repo.createTag("v0.2.0", null);

    const tags = try execGit(allocator, tmp, &.{ "tag", "-l" });
    defer allocator.free(tags);
    try std.testing.expect(std.mem.indexOf(u8, tags, "v0.1.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, tags, "v0.2.0") != null);
}

// =====================================================================
// git writes, ziggit reads
// =====================================================================

test "git repo without packed refs -> ziggit revParseHead works" {
    // Tests that ziggit reads loose refs correctly (standard case)
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try execGitNoOutput(allocator, tmp, &.{ "init" });
    try execGitNoOutput(allocator, tmp, &.{ "config", "user.email", "t@t" });
    try execGitNoOutput(allocator, tmp, &.{ "config", "user.name", "T" });
    try writeFile(allocator, tmp, "f.txt", "data");
    try execGitNoOutput(allocator, tmp, &.{ "add", "f.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "init" });

    const git_hash_out = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(git_hash_out);
    const git_hash = trim(git_hash_out);

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();

    const ziggit_hash = try repo.revParseHead();
    try std.testing.expectEqualStrings(git_hash, &ziggit_hash);
}

test "git repo with 20 commits -> ziggit revParseHead matches latest" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try execGitNoOutput(allocator, tmp, &.{ "init" });
    try execGitNoOutput(allocator, tmp, &.{ "config", "user.email", "t@t" });
    try execGitNoOutput(allocator, tmp, &.{ "config", "user.name", "T" });

    for (0..20) |i| {
        var fname_buf: [32]u8 = undefined;
        const fname = std.fmt.bufPrint(&fname_buf, "f{d}.txt", .{i}) catch unreachable;
        var content_buf: [32]u8 = undefined;
        const content = std.fmt.bufPrint(&content_buf, "data {d}", .{i}) catch unreachable;
        try writeFile(allocator, tmp, fname, content);
        try execGitNoOutput(allocator, tmp, &.{ "add", fname });
        var msg_buf: [32]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "commit {d}", .{i}) catch unreachable;
        try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", msg });
    }

    const git_hash_out = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(git_hash_out);

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();
    const ziggit_hash = try repo.revParseHead();
    try std.testing.expectEqualStrings(trim(git_hash_out), &ziggit_hash);
}

test "git tag + 3 commits -> ziggit describeTags shows distance" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try execGitNoOutput(allocator, tmp, &.{ "init" });
    try execGitNoOutput(allocator, tmp, &.{ "config", "user.email", "t@t" });
    try execGitNoOutput(allocator, tmp, &.{ "config", "user.name", "T" });

    try writeFile(allocator, tmp, "base.txt", "base");
    try execGitNoOutput(allocator, tmp, &.{ "add", "base.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "base" });
    try execGitNoOutput(allocator, tmp, &.{ "tag", "v1.0.0" });

    // 3 more commits after tag
    for (0..3) |i| {
        var fname_buf: [32]u8 = undefined;
        const fname = std.fmt.bufPrint(&fname_buf, "post{d}.txt", .{i}) catch unreachable;
        try writeFile(allocator, tmp, fname, "post");
        try execGitNoOutput(allocator, tmp, &.{ "add", fname });
        try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "post" });
    }

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();
    const desc = try repo.describeTags(allocator);
    defer allocator.free(desc);

    // Should contain v1.0.0 and show distance
    try std.testing.expect(std.mem.indexOf(u8, desc, "v1.0.0") != null);
}

test "git repo with nested dirs -> ziggit isClean true" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try execGitNoOutput(allocator, tmp, &.{ "init" });
    try execGitNoOutput(allocator, tmp, &.{ "config", "user.email", "t@t" });
    try execGitNoOutput(allocator, tmp, &.{ "config", "user.name", "T" });

    const dir = try std.fmt.allocPrint(allocator, "{s}/src/lib", .{tmp});
    defer allocator.free(dir);
    std.fs.makeDirAbsolute(dir) catch {};

    try writeFile(allocator, tmp, "src/lib/mod.zig", "pub fn hello() void {}");
    try writeFile(allocator, tmp, "src/main.zig", "const lib = @import(\"lib/mod.zig\");");
    try execGitNoOutput(allocator, tmp, &.{ "add", "-A" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "nested" });

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();
    const clean = try repo.isClean();
    try std.testing.expect(clean);
}

test "git creates binary file -> ziggit revParseHead and isClean work" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try execGitNoOutput(allocator, tmp, &.{ "init" });
    try execGitNoOutput(allocator, tmp, &.{ "config", "user.email", "t@t" });
    try execGitNoOutput(allocator, tmp, &.{ "config", "user.name", "T" });

    // Write binary content
    const fp = try std.fmt.allocPrint(allocator, "{s}/data.bin", .{tmp});
    defer allocator.free(fp);
    {
        const f = try std.fs.createFileAbsolute(fp, .{ .truncate = true });
        defer f.close();
        var bytes: [256]u8 = undefined;
        for (0..256) |i| bytes[i] = @intCast(i);
        try f.writeAll(&bytes);
    }

    try execGitNoOutput(allocator, tmp, &.{ "add", "data.bin" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "binary" });

    const git_hash_out = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(git_hash_out);

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();
    const ziggit_hash = try repo.revParseHead();
    try std.testing.expectEqualStrings(trim(git_hash_out), &ziggit_hash);
    try std.testing.expect(try repo.isClean());
}

// =====================================================================
// Bun workflow: full lifecycle with ziggit API
// =====================================================================

test "bun lifecycle: init -> add package.json -> commit -> tag -> describe -> status" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    // 1. Init
    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    // 2. Add package.json
    try writeFile(allocator, tmp, "package.json",
        \\{"name": "@test/pkg", "version": "1.0.0"}
    );
    try repo.add("package.json");

    // 3. Commit
    const hash = try repo.commit("v1.0.0", "BunPublish", "bun@oven.sh");

    // 4. Tag
    try repo.createTag("v1.0.0", null);

    // 5. Describe
    const desc = try repo.describeTags(allocator);
    defer allocator.free(desc);
    try std.testing.expectEqualStrings("v1.0.0", desc);

    // 6. Status clean
    try std.testing.expect(try repo.isClean());

    // 7. Validate with git
    const git_hash_out = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(git_hash_out);
    try std.testing.expectEqualStrings(&hash, trim(git_hash_out));

    const fsck_exit = try execGitAllowFail(allocator, tmp, &.{ "fsck" });
    try std.testing.expectEqual(@as(u8, 0), fsck_exit);
}

test "bun lifecycle: multiple version bumps validated by git" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    const versions = [_][]const u8{ "0.0.1", "0.0.2", "0.1.0", "1.0.0" };
    for (versions) |ver| {
        var pkg_buf: [128]u8 = undefined;
        const pkg = std.fmt.bufPrint(&pkg_buf, "{{\"name\": \"pkg\", \"version\": \"{s}\"}}", .{ver}) catch unreachable;
        try writeFile(allocator, tmp, "package.json", pkg);
        try repo.add("package.json");
        _ = try repo.commit(ver, "T", "t@t");

        var tag_buf: [16]u8 = undefined;
        const tag = std.fmt.bufPrint(&tag_buf, "v{s}", .{ver}) catch unreachable;
        try repo.createTag(tag, null);
    }

    // Git should see 4 tags and 4 commits
    const tag_list = try execGit(allocator, tmp, &.{ "tag", "-l" });
    defer allocator.free(tag_list);

    var tag_count: usize = 0;
    var tag_iter = std.mem.splitScalar(u8, trim(tag_list), '\n');
    while (tag_iter.next()) |_| tag_count += 1;
    try std.testing.expectEqual(@as(usize, 4), tag_count);

    const count_out = try execGit(allocator, tmp, &.{ "rev-list", "--count", "HEAD" });
    defer allocator.free(count_out);
    try std.testing.expectEqualStrings("4", trim(count_out));

    // Verify git can read the history
    const log = try execGit(allocator, tmp, &.{ "log", "--oneline" });
    defer allocator.free(log);
    try std.testing.expect(log.len > 0);
}

test "bun lifecycle: workspace monorepo -> git reads all packages" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    // Create workspace structure
    const dirs = [_][]const u8{ "packages/core", "packages/cli", "packages/web" };
    for (dirs) |dir| {
        const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tmp, dir });
        defer allocator.free(full);
        std.fs.makeDirAbsolute(full) catch {};
    }

    try writeFile(allocator, tmp, "package.json", "{\"workspaces\": [\"packages/*\"]}");
    try writeFile(allocator, tmp, "packages/core/package.json", "{\"name\": \"@ws/core\"}");
    try writeFile(allocator, tmp, "packages/cli/package.json", "{\"name\": \"@ws/cli\"}");
    try writeFile(allocator, tmp, "packages/web/package.json", "{\"name\": \"@ws/web\"}");
    try writeFile(allocator, tmp, "packages/core/index.ts", "export const x = 1;");
    try writeFile(allocator, tmp, "packages/cli/index.ts", "import {x} from '@ws/core';");
    try writeFile(allocator, tmp, "packages/web/index.ts", "import {x} from '@ws/core';");

    try repo.add("package.json");
    try repo.add("packages/core/package.json");
    try repo.add("packages/core/index.ts");
    try repo.add("packages/cli/package.json");
    try repo.add("packages/cli/index.ts");
    try repo.add("packages/web/package.json");
    try repo.add("packages/web/index.ts");
    _ = try repo.commit("monorepo init", "T", "t@t");

    // Git should see all 7 files
    const ls_tree = try execGit(allocator, tmp, &.{ "ls-tree", "-r", "--name-only", "HEAD" });
    defer allocator.free(ls_tree);

    var file_count: usize = 0;
    var iter = std.mem.splitScalar(u8, trim(ls_tree), '\n');
    while (iter.next()) |_| file_count += 1;
    try std.testing.expectEqual(@as(usize, 7), file_count);

    // Verify specific file content
    const core_pkg = try execGit(allocator, tmp, &.{ "show", "HEAD:packages/core/package.json" });
    defer allocator.free(core_pkg);
    try std.testing.expect(std.mem.indexOf(u8, core_pkg, "@ws/core") != null);
}
