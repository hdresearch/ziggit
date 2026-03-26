// test/roundtrip_consistency_test.zig
// Round-trip consistency: operations with ziggit API, cross-validated with git CLI
// Focus areas: hash determinism, interleaved ops, reopen consistency, API chaining
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
        std.debug.print("git failed (exit {d}): ", .{term.Exited});
        for (argv.items) |a| std.debug.print("{s} ", .{a});
        std.debug.print("\ncwd: {s}\nstderr: {s}\n", .{ cwd, stderr });
        allocator.free(stdout);
        return error.GitCommandFailed;
    }
    return stdout;
}

fn execGitNoOutput(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) !void {
    const out = try execGit(allocator, cwd, args);
    allocator.free(out);
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trimRight(u8, s, "\n\r \t");
}

fn makeTmpDir(allocator: std.mem.Allocator) ![]const u8 {
    const base = "/root/ziggit_test_roundtrip";
    std.fs.makeDirAbsolute(base) catch {};
    var buf: [64]u8 = undefined;
    const ts = std.time.milliTimestamp();
    var rng = std.rand.DefaultPrng.init(@bitCast(ts));
    const rv = rng.random().int(u64);
    const name = std.fmt.bufPrint(&buf, "rt_{d}_{d}", .{ ts, rv }) catch unreachable;
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, name });
    std.fs.makeDirAbsolute(path) catch {};
    return path;
}

fn cleanupTmpDir(path: []const u8) void {
    std.fs.deleteTreeAbsolute(path) catch {};
}

fn writeFile(dir: []const u8, name: []const u8, content: []const u8, allocator: std.mem.Allocator) !void {
    const fpath = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, name });
    defer allocator.free(fpath);
    const f = try std.fs.createFileAbsolute(fpath, .{ .truncate = true });
    defer f.close();
    try f.writeAll(content);
}

fn initGitConfig(allocator: std.mem.Allocator, path: []const u8) !void {
    try execGitNoOutput(allocator, path, &.{ "config", "user.name", "Test" });
    try execGitNoOutput(allocator, path, &.{ "config", "user.email", "test@test.com" });
}

// Test: ziggit commit hash matches git rev-parse HEAD exactly
test "roundtrip: commit hash from API matches git rev-parse" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();
    try initGitConfig(allocator, tmp);

    try writeFile(tmp, "file.txt", "hello", allocator);
    try repo.add("file.txt");
    const api_hash = try repo.commit("test commit", "Author", "a@a.com");

    const git_out = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(git_out);

    try std.testing.expectEqualStrings(&api_hash, trim(git_out));
}

// Test: close repo, reopen, HEAD still matches
test "roundtrip: close and reopen repo preserves HEAD" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    // Phase 1: create and commit
    var hash1: [40]u8 = undefined;
    {
        var repo = try ziggit.Repository.init(allocator, tmp);
        defer repo.close();
        try writeFile(tmp, "a.txt", "content", allocator);
        try repo.add("a.txt");
        hash1 = try repo.commit("first", "A", "a@a.com");
    }

    // Phase 2: reopen and verify
    {
        var repo = try ziggit.Repository.open(allocator, tmp);
        defer repo.close();
        const hash2 = try repo.revParseHead();
        try std.testing.expectEqualStrings(&hash1, &hash2);
    }

    // Phase 3: git also agrees
    const git_out = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(git_out);
    try std.testing.expectEqualStrings(&hash1, trim(git_out));
}

// Test: interleaved ziggit API and git CLI commits
test "roundtrip: interleaved ziggit and git commits" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();
    try initGitConfig(allocator, tmp);

    // ziggit commit 1
    try writeFile(tmp, "a.txt", "from ziggit", allocator);
    try repo.add("a.txt");
    _ = try repo.commit("ziggit-1", "Z", "z@z.com");

    // git commit 2
    try writeFile(tmp, "b.txt", "from git", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "b.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "git-2" });

    // ziggit commit 3
    try writeFile(tmp, "c.txt", "ziggit again", allocator);
    try repo.add("c.txt");
    _ = try repo.commit("ziggit-3", "Z", "z@z.com");

    // Both should agree on HEAD
    const z_head = try repo.revParseHead();
    const g_out = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(g_out);
    try std.testing.expectEqualStrings(&z_head, trim(g_out));

    // git should see 3 commits
    const count_out = try execGit(allocator, tmp, &.{ "rev-list", "--count", "HEAD" });
    defer allocator.free(count_out);
    try std.testing.expectEqualStrings("3", trim(count_out));

    // git fsck should pass
    try execGitNoOutput(allocator, tmp, &.{"fsck"});
}

// Test: ziggit tag then git resolves it correctly
test "roundtrip: createTag then git rev-parse tag" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();
    try initGitConfig(allocator, tmp);

    try writeFile(tmp, "f.txt", "v1", allocator);
    try repo.add("f.txt");
    const commit_hash = try repo.commit("release", "A", "a@a.com");
    try repo.createTag("v1.0.0", null);

    const tag_out = try execGit(allocator, tmp, &.{ "rev-parse", "v1.0.0" });
    defer allocator.free(tag_out);
    try std.testing.expectEqualStrings(&commit_hash, trim(tag_out));

    // git tag -l should list it
    const tags_out = try execGit(allocator, tmp, &.{ "tag", "-l" });
    defer allocator.free(tags_out);
    try std.testing.expect(std.mem.indexOf(u8, tags_out, "v1.0.0") != null);
}

// Test: git creates repo, ziggit opens and all APIs work
test "roundtrip: git creates complex repo, ziggit reads all state" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    // git creates repo with multiple commits and tags
    try execGitNoOutput(allocator, tmp, &.{"init"});
    try initGitConfig(allocator, tmp);

    try writeFile(tmp, "readme.md", "# Project", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "readme.md" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "initial" });
    try execGitNoOutput(allocator, tmp, &.{ "tag", "v0.1.0" });

    try writeFile(tmp, "lib.zig", "pub fn add() void {}", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "lib.zig" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "add lib" });
    try execGitNoOutput(allocator, tmp, &.{ "tag", "v0.2.0" });

    // ziggit opens and reads
    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();

    // revParseHead matches git
    const z_head = try repo.revParseHead();
    const g_out = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(g_out);
    try std.testing.expectEqualStrings(&z_head, trim(g_out));

    // isClean should be true
    const clean = try repo.isClean();
    try std.testing.expect(clean);

    // describeTags should find a tag
    const desc = try repo.describeTags(allocator);
    defer allocator.free(desc);
    try std.testing.expect(desc.len > 0);

    // branchList should have at least one branch
    const branches = try repo.branchList(allocator);
    defer {
        for (branches) |b| allocator.free(b);
        allocator.free(branches);
    }
    try std.testing.expect(branches.len > 0);

    // findCommit by tag name
    const tag_hash = try repo.findCommit("v0.1.0");
    const g_tag = try execGit(allocator, tmp, &.{ "rev-parse", "v0.1.0" });
    defer allocator.free(g_tag);
    try std.testing.expectEqualStrings(&tag_hash, trim(g_tag));
}

// Test: 50 files in 5 subdirectories
test "roundtrip: 50 files in subdirs verified by git" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();
    try initGitConfig(allocator, tmp);

    // Create 50 files in 5 dirs
    const dirs = [_][]const u8{ "src", "lib", "test", "docs", "examples" };
    for (dirs) |dir| {
        const dirpath = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tmp, dir });
        defer allocator.free(dirpath);
        std.fs.makeDirAbsolute(dirpath) catch {};

        for (0..10) |i| {
            var name_buf: [64]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "{s}/file{d}.txt", .{ dir, i }) catch unreachable;
            var content_buf: [32]u8 = undefined;
            const content = std.fmt.bufPrint(&content_buf, "{s}:{d}", .{ dir, i }) catch unreachable;
            try writeFile(tmp, name, content, allocator);
            try repo.add(name);
        }
    }
    _ = try repo.commit("50 files", "A", "a@a.com");

    // git should see all 50 files
    const tree = try execGit(allocator, tmp, &.{ "ls-tree", "-r", "--name-only", "HEAD" });
    defer allocator.free(tree);

    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, trim(tree), '\n');
    while (lines.next()) |line| {
        if (line.len > 0) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 50), count);
}

// Test: binary content with all 256 byte values
test "roundtrip: binary file with all byte values preserved" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    // Create binary content
    var binary: [256]u8 = undefined;
    for (&binary, 0..) |*b, i| b.* = @intCast(i);

    const fpath = try std.fmt.allocPrint(allocator, "{s}/binary.dat", .{tmp});
    defer allocator.free(fpath);
    {
        const f = try std.fs.createFileAbsolute(fpath, .{});
        defer f.close();
        try f.writeAll(&binary);
    }

    try repo.add("binary.dat");
    _ = try repo.commit("binary", "A", "a@a.com");

    // Verify git can read it with correct size
    const size_out = try execGit(allocator, tmp, &.{ "cat-file", "-s", "HEAD:binary.dat" });
    defer allocator.free(size_out);
    try std.testing.expectEqualStrings("256", trim(size_out));

    // git fsck passes
    try execGitNoOutput(allocator, tmp, &.{"fsck"});
}

// Test: multiple version tags, describeTags finds latest
test "roundtrip: 5 version tags, describe finds latest" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();
    try initGitConfig(allocator, tmp);

    const versions = [_][]const u8{ "v1.0.0", "v1.1.0", "v1.2.0", "v2.0.0", "v2.1.0" };
    for (versions, 0..) |ver, i| {
        var buf: [32]u8 = undefined;
        const content = std.fmt.bufPrint(&buf, "version {d}", .{i}) catch unreachable;
        try writeFile(tmp, "version.txt", content, allocator);
        try repo.add("version.txt");
        _ = try repo.commit(ver, "A", "a@a.com");
        try repo.createTag(ver, null);
    }

    // describeTags should return v2.1.0 (on HEAD)
    const desc = try repo.describeTags(allocator);
    defer allocator.free(desc);
    try std.testing.expectEqualStrings("v2.1.0", desc);

    // git should see all 5 tags
    const tags_out = try execGit(allocator, tmp, &.{ "tag", "-l" });
    defer allocator.free(tags_out);
    for (versions) |ver| {
        try std.testing.expect(std.mem.indexOf(u8, tags_out, ver) != null);
    }
}

// Test: statusPorcelain transitions through dirty -> staged -> clean
test "roundtrip: status transitions dirty -> committed -> clean" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();
    try initGitConfig(allocator, tmp);

    // After init, should be clean (empty)
    const clean1 = try repo.isClean();
    try std.testing.expect(clean1);

    // Write file -> still "clean" because nothing is tracked/staged
    try writeFile(tmp, "f.txt", "hello", allocator);

    // Add and commit -> should be clean
    try repo.add("f.txt");
    _ = try repo.commit("first", "A", "a@a.com");

    const clean2 = try repo.isClean();
    try std.testing.expect(clean2);

    // git status should also be clean
    const status_out = try execGit(allocator, tmp, &.{ "status", "--porcelain" });
    defer allocator.free(status_out);
    try std.testing.expectEqualStrings("", trim(status_out));
}

// Test: git repack then ziggit reads
test "roundtrip: git repack preserves ziggit-created objects" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();
    try initGitConfig(allocator, tmp);

    try writeFile(tmp, "f.txt", "data", allocator);
    try repo.add("f.txt");
    const hash = try repo.commit("before repack", "A", "a@a.com");
    try repo.createTag("v1.0.0", null);

    // Repack objects (keeps refs loose, packs objects)
    try execGitNoOutput(allocator, tmp, &.{ "repack", "-a", "-d" });

    // Close and reopen to clear caches
    repo.close();
    repo = try ziggit.Repository.open(allocator, tmp);

    // ziggit should still read HEAD
    const head = try repo.revParseHead();
    try std.testing.expectEqualStrings(&hash, &head);

    // describeTags should still work
    const desc = try repo.describeTags(allocator);
    defer allocator.free(desc);
    try std.testing.expectEqualStrings("v1.0.0", desc);
}

// Test: bun publish full workflow with all API calls
test "roundtrip: full bun publish lifecycle" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();
    try initGitConfig(allocator, tmp);

    // Step 1: Initial package
    try writeFile(tmp, "package.json", "{\"name\":\"@test/pkg\",\"version\":\"1.0.0\"}", allocator);
    try writeFile(tmp, "index.js", "module.exports = {};", allocator);
    try repo.add("package.json");
    try repo.add("index.js");
    const hash1 = try repo.commit("v1.0.0", "Bun", "bun@bun.sh");
    try repo.createTag("v1.0.0", null);

    // Step 2: Verify state
    try std.testing.expect(try repo.isClean());
    const desc1 = try repo.describeTags(allocator);
    defer allocator.free(desc1);
    try std.testing.expectEqualStrings("v1.0.0", desc1);

    // Step 3: Version bump
    try writeFile(tmp, "package.json", "{\"name\":\"@test/pkg\",\"version\":\"1.1.0\"}", allocator);
    try repo.add("package.json");
    const hash2 = try repo.commit("v1.1.0", "Bun", "bun@bun.sh");
    try repo.createTag("v1.1.0", null);

    // Step 4: Verify all state
    try std.testing.expect(try repo.isClean());
    try std.testing.expect(!std.mem.eql(u8, &hash1, &hash2));

    const desc2 = try repo.describeTags(allocator);
    defer allocator.free(desc2);
    try std.testing.expectEqualStrings("v1.1.0", desc2);

    // Step 5: git validates everything
    const git_head = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(git_head);
    try std.testing.expectEqualStrings(&hash2, trim(git_head));

    const git_count = try execGit(allocator, tmp, &.{ "rev-list", "--count", "HEAD" });
    defer allocator.free(git_count);
    try std.testing.expectEqualStrings("2", trim(git_count));

    // Step 6: git clone works
    const clone_dir = try std.fmt.allocPrint(allocator, "{s}_clone", .{tmp});
    defer allocator.free(clone_dir);
    defer std.fs.deleteTreeAbsolute(clone_dir) catch {};
    try execGitNoOutput(allocator, "/root", &.{ "clone", tmp, clone_dir });

    const clone_tags = try execGit(allocator, clone_dir, &.{ "tag", "-l" });
    defer allocator.free(clone_tags);
    try std.testing.expect(std.mem.indexOf(u8, clone_tags, "v1.0.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, clone_tags, "v1.1.0") != null);
}

// Test: findCommit resolves tag, HEAD, and full hash
test "roundtrip: findCommit resolves multiple ref types" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();
    try initGitConfig(allocator, tmp);

    try writeFile(tmp, "f.txt", "data", allocator);
    try repo.add("f.txt");
    const hash = try repo.commit("test", "A", "a@a.com");
    try repo.createTag("v1.0.0", null);

    // findCommit by HEAD
    const by_head = try repo.findCommit("HEAD");
    try std.testing.expectEqualStrings(&hash, &by_head);

    // findCommit by tag name
    const by_tag = try repo.findCommit("v1.0.0");
    try std.testing.expectEqualStrings(&hash, &by_tag);

    // findCommit by full hash
    const by_hash = try repo.findCommit(&hash);
    try std.testing.expectEqualStrings(&hash, &by_hash);

    // findCommit by short hash (first 7 chars)
    const by_short = try repo.findCommit(hash[0..7]);
    try std.testing.expectEqualStrings(&hash, &by_short);
}

// Test: empty file committed and verified
test "roundtrip: empty file preserves zero-length blob" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    const fpath = try std.fmt.allocPrint(allocator, "{s}/empty.txt", .{tmp});
    defer allocator.free(fpath);
    {
        const f = try std.fs.createFileAbsolute(fpath, .{});
        f.close();
    }
    try repo.add("empty.txt");
    _ = try repo.commit("empty", "A", "a@a.com");

    const size_out = try execGit(allocator, tmp, &.{ "cat-file", "-s", "HEAD:empty.txt" });
    defer allocator.free(size_out);
    try std.testing.expectEqualStrings("0", trim(size_out));
}
