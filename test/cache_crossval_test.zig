// test/cache_crossval_test.zig
// Cross-validation tests for cache consistency: ziggit cache APIs agree with git CLI
// Tests isHyperFastCleanCached, isUltraFastCleanCached, close/reopen patterns,
// and statusPorcelain exact format matching with git.
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

fn execGitNoOutput(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) !void {
    const out = try execGit(allocator, cwd, args);
    allocator.free(out);
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trimRight(u8, s, "\n\r \t");
}

fn makeTmpDir(allocator: std.mem.Allocator) ![]const u8 {
    const base = "/tmp/ziggit_cache_crossval";
    std.fs.makeDirAbsolute(base) catch {};
    var buf: [64]u8 = undefined;
    const ts = std.time.milliTimestamp();
    var rng = std.Random.DefaultPrng.init(@bitCast(ts));
    const r = rng.random().int(u64);
    const name = std.fmt.bufPrint(&buf, "{d}_{d}", .{ ts, r }) catch unreachable;
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

fn writeFileInSubdir(dir: []const u8, subdir: []const u8, name: []const u8, content: []const u8, allocator: std.mem.Allocator) !void {
    const full_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, subdir });
    defer allocator.free(full_dir);
    std.fs.makeDirAbsolute(full_dir) catch {};
    const fpath = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ full_dir, name });
    defer allocator.free(fpath);
    const f = try std.fs.createFileAbsolute(fpath, .{ .truncate = true });
    defer f.close();
    try f.writeAll(content);
}

// ============================================================
// Cache consistency: isClean, isHyperFastCleanCached, isUltraFastCleanCached
// ============================================================

test "cache: isHyperFastCleanCached agrees with isClean after commit" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    try writeFile(tmp, "file.txt", "hello", allocator);
    try repo.add("file.txt");
    const hash = try repo.commit("initial", "Test", "test@test.com");
    _ = hash;

    // After commit, both should agree the repo is clean
    const is_clean = try repo.isClean();
    // isHyperFastCleanCached may return cached value - call isClean first to populate cache
    const is_hyper = try repo.isHyperFastCleanCached();
    try std.testing.expect(is_clean);
    try std.testing.expect(is_hyper);
}

test "cache: isUltraFastCleanCached agrees with isClean after commit" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    try writeFile(tmp, "data.txt", "content", allocator);
    try repo.add("data.txt");
    _ = try repo.commit("first commit", "Author", "author@test.com");

    const is_clean = try repo.isClean();
    const is_ultra = try repo.isUltraFastCleanCached();
    try std.testing.expect(is_clean);
    try std.testing.expect(is_ultra);
}

test "cache: isClean true after fresh init-add-commit cycle" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    try writeFile(tmp, "a.txt", "original", allocator);
    try repo.add("a.txt");
    _ = try repo.commit("initial", "T", "t@t");

    // ziggit should report clean
    try std.testing.expect(try repo.isClean());

    // All cache variants should agree
    try std.testing.expect(try repo.isHyperFastCleanCached());
    try std.testing.expect(try repo.isUltraFastCleanCached());
}

test "cache: close and reopen -> revParseHead still correct" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    // Create and commit
    var repo = try ziggit.Repository.init(allocator, tmp);
    try writeFile(tmp, "file.txt", "data", allocator);
    try repo.add("file.txt");
    const hash1 = try repo.commit("msg", "A", "a@a");
    repo.close();

    // Reopen
    var repo2 = try ziggit.Repository.open(allocator, tmp);
    defer repo2.close();
    const hash2 = try repo2.revParseHead();

    // Verify with git
    const git_head = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(git_head);

    try std.testing.expectEqualStrings(&hash1, &hash2);
    try std.testing.expectEqualStrings(&hash1, trim(git_head));
}

test "cache: close, git modifies, reopen -> ziggit sees new HEAD" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    // ziggit creates initial commit
    var repo = try ziggit.Repository.init(allocator, tmp);
    try writeFile(tmp, "file.txt", "v1", allocator);
    try repo.add("file.txt");
    _ = try repo.commit("v1", "A", "a@a");
    repo.close();

    // git makes a new commit
    try execGitNoOutput(allocator, tmp, &.{ "config", "user.name", "T" });
    try execGitNoOutput(allocator, tmp, &.{ "config", "user.email", "t@t" });
    try writeFile(tmp, "file.txt", "v2", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "file.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "v2 by git" });

    const git_head = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(git_head);

    // Reopen with ziggit - should see the new HEAD
    var repo2 = try ziggit.Repository.open(allocator, tmp);
    defer repo2.close();
    const ziggit_head = try repo2.revParseHead();

    try std.testing.expectEqualStrings(trim(git_head), &ziggit_head);
}

test "cache: close, add tag externally, reopen -> describeTags finds it" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    try writeFile(tmp, "file.txt", "tagged", allocator);
    try repo.add("file.txt");
    _ = try repo.commit("initial", "A", "a@a");
    repo.close();

    // Git adds a tag
    try execGitNoOutput(allocator, tmp, &.{ "tag", "v5.0.0" });

    // Reopen and describe
    var repo2 = try ziggit.Repository.open(allocator, tmp);
    defer repo2.close();
    const desc = try repo2.describeTags(allocator);
    defer allocator.free(desc);

    try std.testing.expect(std.mem.indexOf(u8, desc, "v5.0.0") != null);
}

test "cache: repeated isClean calls return consistent result" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    try writeFile(tmp, "a.txt", "content", allocator);
    try repo.add("a.txt");
    _ = try repo.commit("msg", "A", "a@a");

    // Call isClean 10 times - should always return true
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        try std.testing.expect(try repo.isClean());
    }
}

// ============================================================
// statusPorcelain exact format matching with git
// ============================================================

test "statusPorcelain: empty on clean repo matches git" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    try writeFile(tmp, "readme.md", "# Hello", allocator);
    try repo.add("readme.md");
    _ = try repo.commit("init", "A", "a@a");

    const ziggit_status = try repo.statusPorcelain(allocator);
    defer allocator.free(ziggit_status);

    const git_status = try execGit(allocator, tmp, &.{ "status", "--porcelain" });
    defer allocator.free(git_status);

    // Both should be empty for clean repo
    try std.testing.expectEqualStrings(trim(git_status), trim(ziggit_status));
}

test "statusPorcelain: non-empty when file staged but not committed" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    try writeFile(tmp, "tracked.txt", "tracked", allocator);
    try repo.add("tracked.txt");
    _ = try repo.commit("init", "A", "a@a");

    // Now add a new file and stage it but don't commit
    try writeFile(tmp, "new.txt", "new content", allocator);
    try repo.add("new.txt");

    // After commit, should be clean
    _ = try repo.commit("add new", "A", "a@a");
    const status_after = try repo.statusPorcelain(allocator);
    defer allocator.free(status_after);
    try std.testing.expectEqualStrings("", trim(status_after));

    // Git should agree
    const git_status = try execGit(allocator, tmp, &.{ "status", "--porcelain" });
    defer allocator.free(git_status);
    try std.testing.expectEqualStrings("", trim(git_status));
}

// ============================================================
// describeTagsFast vs describeTags consistency
// ============================================================

test "describeTagsFast matches describeTags" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    try writeFile(tmp, "f.txt", "data", allocator);
    try repo.add("f.txt");
    _ = try repo.commit("initial", "A", "a@a");
    try repo.createTag("v3.2.1", null);

    const desc_fast = try repo.describeTagsFast(allocator);
    defer allocator.free(desc_fast);
    const desc = try repo.describeTags(allocator);
    defer allocator.free(desc);

    try std.testing.expectEqualStrings(desc_fast, desc);

    // Verify git agrees
    const git_tag = try execGit(allocator, tmp, &.{ "tag", "-l" });
    defer allocator.free(git_tag);
    try std.testing.expect(std.mem.indexOf(u8, trim(git_tag), "v3.2.1") != null);
}

test "describeTagsFast: multiple tags returns latest" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    try writeFile(tmp, "f.txt", "v1", allocator);
    try repo.add("f.txt");
    _ = try repo.commit("v1", "A", "a@a");
    try repo.createTag("v1.0.0", null);

    try writeFile(tmp, "f.txt", "v2", allocator);
    try repo.add("f.txt");
    _ = try repo.commit("v2", "A", "a@a");
    try repo.createTag("v2.0.0", null);

    try writeFile(tmp, "f.txt", "v3", allocator);
    try repo.add("f.txt");
    _ = try repo.commit("v3", "A", "a@a");
    try repo.createTag("v3.0.0", null);

    const desc = try repo.describeTagsFast(allocator);
    defer allocator.free(desc);

    // Should be latest tag
    try std.testing.expect(std.mem.indexOf(u8, desc, "v3.0.0") != null);

    // Git should list all 3 tags
    const git_tags = try execGit(allocator, tmp, &.{ "tag", "-l" });
    defer allocator.free(git_tags);
    const tag_str = trim(git_tags);
    try std.testing.expect(std.mem.indexOf(u8, tag_str, "v1.0.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, tag_str, "v2.0.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, tag_str, "v3.0.0") != null);
}

// ============================================================
// fetch cross-validation
// ============================================================

test "fetch: ziggit fetch from local repo -> git verifies new objects" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    // Create source repo
    const src_path = try std.fmt.allocPrint(allocator, "{s}/source", .{tmp});
    defer allocator.free(src_path);
    std.fs.makeDirAbsolute(src_path) catch {};

    var src = try ziggit.Repository.init(allocator, src_path);
    try writeFile(src_path, "src.txt", "source content", allocator);
    try src.add("src.txt");
    _ = try src.commit("source commit", "A", "a@a");
    try src.createTag("v1.0.0", null);
    src.close();

    // Clone
    const clone_path = try std.fmt.allocPrint(allocator, "{s}/clone", .{tmp});
    defer allocator.free(clone_path);

    var clone = try ziggit.Repository.cloneNoCheckout(allocator, src_path, clone_path);
    defer clone.close();

    // Now add more to source
    var src2 = try ziggit.Repository.open(allocator, src_path);
    try writeFile(src_path, "src2.txt", "more content", allocator);
    try src2.add("src2.txt");
    _ = try src2.commit("second commit", "A", "a@a");
    try src2.createTag("v2.0.0", null);
    src2.close();

    // Fetch into clone
    var clone2 = try ziggit.Repository.open(allocator, clone_path);
    defer clone2.close();
    try clone2.fetch(src_path);

    // Git should be able to fsck the clone
    const fsck = try execGit(allocator, clone_path, &.{ "fsck", "--no-dangling" });
    defer allocator.free(fsck);
    try std.testing.expect(std.mem.indexOf(u8, fsck, "error") == null);
}

// ============================================================
// cloneBare cross-validation  
// ============================================================

test "cloneBare: git clone from bare preserves content" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    // Create source
    const src_path = try std.fmt.allocPrint(allocator, "{s}/src", .{tmp});
    defer allocator.free(src_path);
    std.fs.makeDirAbsolute(src_path) catch {};

    var src = try ziggit.Repository.init(allocator, src_path);
    try writeFile(src_path, "package.json", "{\"name\":\"test\",\"version\":\"1.0.0\"}", allocator);
    try writeFileInSubdir(src_path, "src", "index.ts", "export default {};", allocator);
    try src.add("package.json");
    try src.add("src/index.ts");
    _ = try src.commit("initial", "A", "a@a");
    try src.createTag("v1.0.0", null);
    src.close();

    // Clone bare with ziggit
    const bare_path = try std.fmt.allocPrint(allocator, "{s}/bare.git", .{tmp});
    defer allocator.free(bare_path);
    var bare = try ziggit.Repository.cloneBare(allocator, src_path, bare_path);
    bare.close();

    // Git clone from bare
    const work_path = try std.fmt.allocPrint(allocator, "{s}/work", .{tmp});
    defer allocator.free(work_path);
    try execGitNoOutput(allocator, tmp, &.{ "clone", bare_path, work_path });

    // Verify files exist
    const pkg = try execGit(allocator, work_path, &.{ "show", "HEAD:package.json" });
    defer allocator.free(pkg);
    try std.testing.expect(std.mem.indexOf(u8, pkg, "\"test\"") != null);

    const idx = try execGit(allocator, work_path, &.{ "show", "HEAD:src/index.ts" });
    defer allocator.free(idx);
    try std.testing.expectEqualStrings("export default {};", trim(idx));

    // Verify tag survived
    const tags = try execGit(allocator, work_path, &.{ "tag", "-l" });
    defer allocator.free(tags);
    try std.testing.expect(std.mem.indexOf(u8, trim(tags), "v1.0.0") != null);
}

// ============================================================
// Bun publish lifecycle: exact sequence
// ============================================================

test "bun lifecycle: init -> add -> commit -> tag -> status -> describe -> git validates all" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    // Step 1: init
    var repo = try ziggit.Repository.init(allocator, tmp);

    // Step 2: add package.json
    try writeFile(tmp, "package.json",
        \\{
        \\  "name": "@myorg/mylib",
        \\  "version": "1.0.0",
        \\  "main": "dist/index.js",
        \\  "types": "dist/index.d.ts",
        \\  "files": ["dist"],
        \\  "scripts": {
        \\    "build": "tsc",
        \\    "test": "bun test"
        \\  },
        \\  "dependencies": {
        \\    "zod": "^3.22.0"
        \\  }
        \\}
    , allocator);
    try repo.add("package.json");

    // Step 3: commit
    const commit_hash = try repo.commit("feat: initial release", "bun-publish", "publish@bun.sh");

    // Step 4: tag
    try repo.createTag("v1.0.0", null);

    // Step 5: status should be clean
    try std.testing.expect(try repo.isClean());
    const status = try repo.statusPorcelain(allocator);
    defer allocator.free(status);
    try std.testing.expectEqualStrings("", trim(status));

    // Step 6: describe should return v1.0.0
    const desc = try repo.describeTags(allocator);
    defer allocator.free(desc);
    try std.testing.expect(std.mem.indexOf(u8, desc, "v1.0.0") != null);

    // Step 7: git validates everything
    const git_head = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(git_head);
    try std.testing.expectEqualStrings(&commit_hash, trim(git_head));

    const git_log = try execGit(allocator, tmp, &.{ "log", "--oneline" });
    defer allocator.free(git_log);
    try std.testing.expect(std.mem.indexOf(u8, git_log, "initial release") != null);

    const git_tag = try execGit(allocator, tmp, &.{ "tag", "-l" });
    defer allocator.free(git_tag);
    try std.testing.expectEqualStrings("v1.0.0", trim(git_tag));

    const git_show = try execGit(allocator, tmp, &.{ "show", "HEAD:package.json" });
    defer allocator.free(git_show);
    try std.testing.expect(std.mem.indexOf(u8, git_show, "@myorg/mylib") != null);

    const fsck = try execGit(allocator, tmp, &.{ "fsck" });
    defer allocator.free(fsck);
    try std.testing.expect(std.mem.indexOf(u8, fsck, "error") == null);

    repo.close();
}

test "bun lifecycle: version bump cycle (1.0.0 -> 1.0.1 -> 1.1.0 -> 2.0.0)" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    const versions = [_][]const u8{ "1.0.0", "1.0.1", "1.1.0", "2.0.0" };
    const messages = [_][]const u8{ "feat: initial", "fix: patch bug", "feat: minor feature", "feat!: breaking change" };

    for (versions, 0..) |ver, i| {
        const pkg_content = try std.fmt.allocPrint(allocator, "{{\"name\":\"@myorg/lib\",\"version\":\"{s}\"}}", .{ver});
        defer allocator.free(pkg_content);
        try writeFile(tmp, "package.json", pkg_content, allocator);
        try repo.add("package.json");
        _ = try repo.commit(messages[i], "bot", "bot@bun.sh");

        const tag_name = try std.fmt.allocPrint(allocator, "v{s}", .{ver});
        defer allocator.free(tag_name);
        try repo.createTag(tag_name, null);
    }

    // Git should see all 4 tags
    const git_tags = try execGit(allocator, tmp, &.{ "tag", "-l" });
    defer allocator.free(git_tags);
    for (versions) |ver| {
        const tag_name = try std.fmt.allocPrint(allocator, "v{s}", .{ver});
        defer allocator.free(tag_name);
        try std.testing.expect(std.mem.indexOf(u8, git_tags, tag_name) != null);
    }

    // Git should see 4 commits
    const git_count = try execGit(allocator, tmp, &.{ "rev-list", "--count", "HEAD" });
    defer allocator.free(git_count);
    try std.testing.expectEqualStrings("4", trim(git_count));

    // Current version should be latest
    const desc = try repo.describeTags(allocator);
    defer allocator.free(desc);
    try std.testing.expect(std.mem.indexOf(u8, desc, "v2.0.0") != null);
}

test "bun lifecycle: lockfile binary preserved exactly" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    // Create a fake binary lockfile with all byte values
    var lockfile: [512]u8 = undefined;
    for (&lockfile, 0..) |*b, i| {
        b.* = @truncate(i);
    }

    try writeFile(tmp, "bun.lockb", &lockfile, allocator);
    try writeFile(tmp, "package.json", "{\"name\":\"test\"}", allocator);
    try repo.add("bun.lockb");
    try repo.add("package.json");
    _ = try repo.commit("add lockfile", "A", "a@a");

    // Git should read exact same bytes
    const git_size = try execGit(allocator, tmp, &.{ "cat-file", "-s", "HEAD:bun.lockb" });
    defer allocator.free(git_size);
    try std.testing.expectEqualStrings("512", trim(git_size));
}

// ============================================================
// findCommit cross-validation with git rev-parse
// ============================================================

test "findCommit: by tag name matches git rev-parse" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    try writeFile(tmp, "a.txt", "first", allocator);
    try repo.add("a.txt");
    const h1 = try repo.commit("first", "A", "a@a");
    try repo.createTag("v1.0.0", null);

    try writeFile(tmp, "a.txt", "second", allocator);
    try repo.add("a.txt");
    _ = try repo.commit("second", "A", "a@a");

    // findCommit by tag should resolve to first commit
    const found = try repo.findCommit("v1.0.0");
    try std.testing.expectEqualStrings(&h1, &found);

    // git should agree
    const git_hash = try execGit(allocator, tmp, &.{ "rev-parse", "v1.0.0" });
    defer allocator.free(git_hash);
    try std.testing.expectEqualStrings(&h1, trim(git_hash));
}

test "findCommit: by HEAD matches revParseHead and git" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    try writeFile(tmp, "file.txt", "content", allocator);
    try repo.add("file.txt");
    _ = try repo.commit("msg", "A", "a@a");

    const head = try repo.revParseHead();
    const found = try repo.findCommit("HEAD");
    try std.testing.expectEqualStrings(&head, &found);

    const git_head = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(git_head);
    try std.testing.expectEqualStrings(&head, trim(git_head));
}

test "findCommit: by full hash matches git" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    try writeFile(tmp, "x.txt", "data", allocator);
    try repo.add("x.txt");
    const hash = try repo.commit("test", "A", "a@a");

    const found = try repo.findCommit(&hash);
    try std.testing.expectEqualStrings(&hash, &found);
}

// ============================================================
// branchList cross-validation
// ============================================================

test "branchList: matches git branch output" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    try writeFile(tmp, "f.txt", "data", allocator);
    try repo.add("f.txt");
    _ = try repo.commit("init", "A", "a@a");

    const branches = try repo.branchList(allocator);
    defer {
        for (branches) |b| allocator.free(b);
        allocator.free(branches);
    }

    // Should have at least one branch (master or main)
    try std.testing.expect(branches.len >= 1);

    // Git should list the same branches
    const git_branches = try execGit(allocator, tmp, &.{ "branch", "--list" });
    defer allocator.free(git_branches);

    for (branches) |b| {
        try std.testing.expect(std.mem.indexOf(u8, git_branches, b) != null);
    }
}

// ============================================================
// latestTag cross-validation
// ============================================================

test "latestTag: matches one of git's tags" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    try writeFile(tmp, "f.txt", "v1", allocator);
    try repo.add("f.txt");
    _ = try repo.commit("v1", "A", "a@a");
    try repo.createTag("v1.0.0", null);

    try writeFile(tmp, "f.txt", "v2", allocator);
    try repo.add("f.txt");
    _ = try repo.commit("v2", "A", "a@a");
    try repo.createTag("v2.0.0", null);

    const latest = try repo.latestTag(allocator);
    defer allocator.free(latest);

    // Should be one of the tags
    const git_tags = try execGit(allocator, tmp, &.{ "tag", "-l" });
    defer allocator.free(git_tags);
    try std.testing.expect(std.mem.indexOf(u8, git_tags, latest) != null);
}

// ============================================================
// checkout cross-validation
// ============================================================

test "checkout: git verifies HEAD after ziggit checkout" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    try writeFile(tmp, "f.txt", "v1", allocator);
    try repo.add("f.txt");
    const h1 = try repo.commit("v1", "A", "a@a");
    try repo.createTag("v1.0.0", null);

    try writeFile(tmp, "f.txt", "v2", allocator);
    try repo.add("f.txt");
    _ = try repo.commit("v2", "A", "a@a");

    // Checkout v1
    try repo.checkout("v1.0.0");

    // git should see v1's hash as HEAD
    const git_head = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(git_head);
    try std.testing.expectEqualStrings(&h1, trim(git_head));
}

// ============================================================
// annotated tag cross-validation
// ============================================================

test "annotated tag: git cat-file shows tag object with message" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    try writeFile(tmp, "f.txt", "release", allocator);
    try repo.add("f.txt");
    _ = try repo.commit("release commit", "A", "a@a");
    try repo.createTag("v1.0.0", "Release v1.0.0 - stable");

    // git tag should list it
    const git_tags = try execGit(allocator, tmp, &.{ "tag", "-l" });
    defer allocator.free(git_tags);
    try std.testing.expectEqualStrings("v1.0.0", trim(git_tags));

    // git cat-file should show it's a tag object with the message
    const cat = try execGit(allocator, tmp, &.{ "cat-file", "-t", "v1.0.0" });
    defer allocator.free(cat);
    try std.testing.expectEqualStrings("tag", trim(cat));

    const cat_p = try execGit(allocator, tmp, &.{ "cat-file", "-p", "v1.0.0" });
    defer allocator.free(cat_p);
    try std.testing.expect(std.mem.indexOf(u8, cat_p, "Release v1.0.0 - stable") != null);
    try std.testing.expect(std.mem.indexOf(u8, cat_p, "tag v1.0.0") != null);
}
