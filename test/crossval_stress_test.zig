// test/crossval_stress_test.zig
// Stress and edge case cross-validation tests: ziggit API ↔ git CLI
// Covers: large files, annotated tags, status API, clone bare, branch listing, porcelain status
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

fn trimRight(s: []const u8) []const u8 {
    return std.mem.trimRight(u8, s, "\n\r \t");
}

fn makeTmpDir(allocator: std.mem.Allocator) ![]const u8 {
    const base = "/root/ziggit_crossval_stress";
    std.fs.makeDirAbsolute(base) catch {};
    var buf: [64]u8 = undefined;
    const ts = std.time.milliTimestamp();
    var rng = std.rand.DefaultPrng.init(@bitCast(ts));
    const rv = rng.random().int(u64);
    const name = std.fmt.bufPrint(&buf, "{d}_{d}", .{ ts, rv }) catch unreachable;
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
    if (std.mem.lastIndexOf(u8, name, "/")) |idx| {
        const parent = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, name[0..idx] });
        defer allocator.free(parent);
        std.fs.makeDirAbsolute(parent) catch {};
    }
    const f = try std.fs.createFileAbsolute(fpath, .{ .truncate = true });
    defer f.close();
    try f.writeAll(content);
}

fn writeBinaryFile(dir: []const u8, name: []const u8, data: []const u8, allocator: std.mem.Allocator) !void {
    const fpath = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, name });
    defer allocator.free(fpath);
    const f = try std.fs.createFileAbsolute(fpath, .{ .truncate = true });
    defer f.close();
    try f.writeAll(data);
}

// ============================================================
// 1. Large file (1MB) through full pipeline
// ============================================================

test "ziggit 1MB file -> git cat-file -s and fsck validates" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    // Create a 1MB file with repeating pattern
    const size = 1024 * 1024;
    const data = try allocator.alloc(u8, size);
    defer allocator.free(data);
    for (data, 0..) |*b, i| b.* = @intCast(i % 251); // prime modulus for variety

    try writeBinaryFile(tmp, "large.bin", data, allocator);
    try repo.add("large.bin");
    _ = try repo.commit("add 1MB file", "T", "t@t");

    // git cat-file -s should report exact size
    const size_out = try execGit(allocator, tmp, &.{ "cat-file", "-s", "HEAD:large.bin" });
    defer allocator.free(size_out);
    try std.testing.expectEqualStrings("1048576", trimRight(size_out));

    // git fsck should pass
    const fsck = try execGit(allocator, tmp, &.{ "fsck", "--no-dangling" });
    defer allocator.free(fsck);
    try std.testing.expect(std.mem.indexOf(u8, fsck, "error") == null);

    // git cat-file blob should return exact content
    const blob_out = try execGit(allocator, tmp, &.{ "cat-file", "blob", "HEAD:large.bin" });
    defer allocator.free(blob_out);
    try std.testing.expectEqual(size, blob_out.len);
    try std.testing.expectEqual(data[0], blob_out[0]);
    try std.testing.expectEqual(data[size - 1], blob_out[size - 1]);
    try std.testing.expectEqual(data[size / 2], blob_out[size / 2]);
}

// ============================================================
// 2. Each commit adds unique files -> git show HEAD~N works
// ============================================================

test "ziggit 10 commits each adding unique file -> git verifies each" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    var hashes: [10][40]u8 = undefined;
    for (0..10) |i| {
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "file_{d:0>2}.txt", .{i}) catch unreachable;
        var content_buf: [32]u8 = undefined;
        const content = std.fmt.bufPrint(&content_buf, "content-{d}", .{i}) catch unreachable;
        try writeFile(tmp, name, content, allocator);
        try repo.add(name);
        var msg_buf: [32]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "commit {d}", .{i}) catch unreachable;
        hashes[i] = try repo.commit(msg, "T", "t@t");
    }

    // Latest commit should have all 10 files
    const ls = try execGit(allocator, tmp, &.{ "ls-tree", "-r", "--name-only", "HEAD" });
    defer allocator.free(ls);
    var file_count: usize = 0;
    var it = std.mem.splitScalar(u8, trimRight(ls), '\n');
    while (it.next()) |line| {
        if (line.len > 0) file_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 10), file_count);

    // Verify each file content at HEAD
    const content_0 = try execGit(allocator, tmp, &.{ "show", "HEAD:file_00.txt" });
    defer allocator.free(content_0);
    try std.testing.expectEqualStrings("content-0", trimRight(content_0));

    const content_9 = try execGit(allocator, tmp, &.{ "show", "HEAD:file_09.txt" });
    defer allocator.free(content_9);
    try std.testing.expectEqualStrings("content-9", trimRight(content_9));

    // Verify commit hashes
    const git_head = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(git_head);
    try std.testing.expectEqualSlices(u8, &hashes[9], trimRight(git_head));

    const git_first = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD~9" });
    defer allocator.free(git_first);
    try std.testing.expectEqualSlices(u8, &hashes[0], trimRight(git_first));

    // First commit should have only 1 file
    const ls_first = try execGit(allocator, tmp, &.{ "ls-tree", "--name-only", "HEAD~9" });
    defer allocator.free(ls_first);
    try std.testing.expectEqualStrings("file_00.txt", trimRight(ls_first));
}

// ============================================================
// 3. Annotated tag -> git cat-file validates tag object
// ============================================================

test "ziggit annotated tag -> git shows tag object or lightweight ref" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    try writeFile(tmp, "release.txt", "release content", allocator);
    try repo.add("release.txt");
    const commit_hash = try repo.commit("release commit", "Releaser", "release@test.com");
    try repo.createTag("v3.0.0", "Release v3.0.0\n\nWith detailed notes");

    // git tag -l should list it
    const tags = try execGit(allocator, tmp, &.{ "tag", "-l" });
    defer allocator.free(tags);
    try std.testing.expectEqualStrings("v3.0.0", trimRight(tags));

    // git describe --tags should return it
    const desc = try execGit(allocator, tmp, &.{ "describe", "--tags" });
    defer allocator.free(desc);
    try std.testing.expectEqualStrings("v3.0.0", trimRight(desc));

    // Tag should resolve to the commit
    // For annotated tags: v3.0.0^{commit}, for lightweight: v3.0.0
    const resolved = try execGit(allocator, tmp, &.{ "rev-parse", "v3.0.0^{commit}" });
    defer allocator.free(resolved);
    try std.testing.expectEqualSlices(u8, &commit_hash, trimRight(resolved));

    // Get tag ref and check type
    const tag_ref = try execGit(allocator, tmp, &.{ "rev-parse", "v3.0.0" });
    defer allocator.free(tag_ref);
    const tag_type = try execGit(allocator, tmp, &.{ "cat-file", "-t", trimRight(tag_ref) });
    defer allocator.free(tag_type);

    const t = trimRight(tag_type);
    if (std.mem.eql(u8, t, "tag")) {
        // Annotated tag: verify message content
        const tag_content = try execGit(allocator, tmp, &.{ "cat-file", "-p", trimRight(tag_ref) });
        defer allocator.free(tag_content);
        try std.testing.expect(std.mem.indexOf(u8, tag_content, "Release v3.0.0") != null);
        try std.testing.expect(std.mem.indexOf(u8, tag_content, "object ") != null);
        try std.testing.expect(std.mem.indexOf(u8, tag_content, "tag v3.0.0") != null);
    } else {
        // Lightweight tag pointing directly to commit
        try std.testing.expectEqualStrings("commit", t);
    }
}

// ============================================================
// 4. git creates repo with rebase history -> ziggit reads
// ============================================================

test "git rebase creates linear history -> ziggit revParseHead and isClean" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try execGitNoOutput(allocator, tmp, &.{"init"});
    try execGitNoOutput(allocator, tmp, &.{ "config", "user.name", "T" });
    try execGitNoOutput(allocator, tmp, &.{ "config", "user.email", "t@t" });

    try writeFile(tmp, "base.txt", "base", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "base.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "base" });

    try writeFile(tmp, "master.txt", "master-work", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "master.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "master work" });

    try execGitNoOutput(allocator, tmp, &.{ "checkout", "-b", "feature", "HEAD~1" });
    try writeFile(tmp, "feature.txt", "feature-work", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "feature.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "feature work" });
    try execGitNoOutput(allocator, tmp, &.{ "rebase", "master" });

    const git_head = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(git_head);

    const count_str = try execGit(allocator, tmp, &.{ "rev-list", "--count", "HEAD" });
    defer allocator.free(count_str);
    try std.testing.expectEqualStrings("3", trimRight(count_str));

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();

    const z_head = try repo.revParseHead();
    try std.testing.expectEqualStrings(trimRight(git_head), &z_head);
    try std.testing.expect(try repo.isClean());
}

// ============================================================
// 5. Multiple new files per commit -> diff between commits
// ============================================================

test "ziggit 3 commits adding distinct files -> git diff --stat works" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    // Commit 1: a.txt, b.txt
    try writeFile(tmp, "a.txt", "alpha", allocator);
    try writeFile(tmp, "b.txt", "beta", allocator);
    try repo.add("a.txt");
    try repo.add("b.txt");
    _ = try repo.commit("add a and b", "T", "t@t");

    // Commit 2: c.txt, d.txt
    try writeFile(tmp, "c.txt", "gamma", allocator);
    try writeFile(tmp, "d.txt", "delta", allocator);
    try repo.add("c.txt");
    try repo.add("d.txt");
    _ = try repo.commit("add c and d", "T", "t@t");

    // Commit 3: e.txt in subdir
    try writeFile(tmp, "sub/e.txt", "epsilon", allocator);
    try repo.add("sub/e.txt");
    _ = try repo.commit("add sub/e", "T", "t@t");

    // git should see all 5 files at HEAD
    const ls = try execGit(allocator, tmp, &.{ "ls-tree", "-r", "--name-only", "HEAD" });
    defer allocator.free(ls);
    try std.testing.expect(std.mem.indexOf(u8, ls, "a.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, ls, "b.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, ls, "c.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, ls, "d.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, ls, "sub/e.txt") != null);

    // git diff --stat between commits 1 and 2 should show c.txt and d.txt
    const diff12 = try execGit(allocator, tmp, &.{ "diff", "--stat", "HEAD~2", "HEAD~1" });
    defer allocator.free(diff12);
    try std.testing.expect(std.mem.indexOf(u8, diff12, "c.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, diff12, "d.txt") != null);

    // git diff --stat between commits 2 and 3 should show sub/e.txt
    const diff23 = try execGit(allocator, tmp, &.{ "diff", "--stat", "HEAD~1", "HEAD" });
    defer allocator.free(diff23);
    try std.testing.expect(std.mem.indexOf(u8, diff23, "sub/e.txt") != null);

    // 3 commits
    const count = try execGit(allocator, tmp, &.{ "rev-list", "--count", "HEAD" });
    defer allocator.free(count);
    try std.testing.expectEqualStrings("3", trimRight(count));
}

// ============================================================
// 6. Exact commit object format verification
// ============================================================

test "ziggit commit object format matches git expectations exactly" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    try writeFile(tmp, "fmt.txt", "format test", allocator);
    try repo.add("fmt.txt");
    const first_hash = try repo.commit("format verification commit", "Format Author", "fmt@test.com");

    // git cat-file -p HEAD should produce valid commit object
    const catfile = try execGit(allocator, tmp, &.{ "cat-file", "-p", "HEAD" });
    defer allocator.free(catfile);

    // Must have tree line
    try std.testing.expect(std.mem.indexOf(u8, catfile, "tree ") != null);

    // Must have author line with name and email
    try std.testing.expect(std.mem.indexOf(u8, catfile, "author Format Author <fmt@test.com>") != null);

    // Must have committer line
    try std.testing.expect(std.mem.indexOf(u8, catfile, "committer ") != null);

    // Must have blank line before message
    try std.testing.expect(std.mem.indexOf(u8, catfile, "\n\nformat verification commit") != null);

    // First commit should NOT have parent line
    try std.testing.expect(std.mem.indexOf(u8, catfile, "parent ") == null);

    // git cat-file -t should confirm type
    const type_out = try execGit(allocator, tmp, &.{ "cat-file", "-t", "HEAD" });
    defer allocator.free(type_out);
    try std.testing.expectEqualStrings("commit", trimRight(type_out));

    // Second commit adds a new file (don't overwrite)
    try writeFile(tmp, "fmt2.txt", "format test 2", allocator);
    try repo.add("fmt2.txt");
    _ = try repo.commit("second commit", "Format Author", "fmt@test.com");

    const catfile2 = try execGit(allocator, tmp, &.{ "cat-file", "-p", "HEAD" });
    defer allocator.free(catfile2);

    // Must have exactly one parent line
    var parent_count: usize = 0;
    var lines = std.mem.splitScalar(u8, catfile2, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "parent ")) parent_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), parent_count);

    // Parent should be the first commit
    const parent_line = blk: {
        var it = std.mem.splitScalar(u8, catfile2, '\n');
        while (it.next()) |line| {
            if (std.mem.startsWith(u8, line, "parent ")) break :blk line;
        }
        unreachable;
    };
    try std.testing.expect(std.mem.indexOf(u8, parent_line, &first_hash) != null);
}

// ============================================================
// 7. Status API after various operations
// ============================================================

test "ziggit isClean is true after init and after commit" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    // After init with no commits, isClean should be true
    const clean_empty = try repo.isClean();
    try std.testing.expect(clean_empty);

    // Create and commit a file -> clean
    try writeFile(tmp, "tracked.txt", "initial", allocator);
    try repo.add("tracked.txt");
    _ = try repo.commit("initial", "T", "t@t");

    const clean_committed = try repo.isClean();
    try std.testing.expect(clean_committed);

    // Git should also say clean
    const git_status = try execGit(allocator, tmp, &.{ "status", "--porcelain" });
    defer allocator.free(git_status);
    try std.testing.expectEqualStrings("", trimRight(git_status));
}

// ============================================================
// 8. Bun workflow: package.json + lockfile + src
// ============================================================

test "bun workflow: init with package.json, lockfile, src -> git validates all" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    // Create realistic bun project structure
    try writeFile(tmp, "package.json", "{\"name\":\"@bun/app\",\"version\":\"1.0.0\"}", allocator);
    // Lockfile is binary-ish
    var lockdata: [512]u8 = undefined;
    for (&lockdata, 0..) |*b, i| b.* = @intCast((i * 7 + 13) % 256);
    try writeBinaryFile(tmp, "bun.lockb", &lockdata, allocator);
    try writeFile(tmp, "src/index.ts", "export default 1;", allocator);
    try writeFile(tmp, "tsconfig.json", "{\"compilerOptions\":{\"strict\":true}}", allocator);
    try writeFile(tmp, ".gitignore", "node_modules/\n*.log\n", allocator);

    try repo.add("package.json");
    try repo.add("bun.lockb");
    try repo.add("src/index.ts");
    try repo.add("tsconfig.json");
    try repo.add(".gitignore");
    const h1 = try repo.commit("feat: v1.0.0", "bun-bot", "bot@bun.sh");
    try repo.createTag("v1.0.0", null);

    // Verify clean
    try std.testing.expect(try repo.isClean());

    // Git validates
    const count = try execGit(allocator, tmp, &.{ "rev-list", "--count", "HEAD" });
    defer allocator.free(count);
    try std.testing.expectEqualStrings("1", trimRight(count));

    const git_head = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(git_head);
    try std.testing.expectEqualSlices(u8, &h1, trimRight(git_head));

    const tag_list = try execGit(allocator, tmp, &.{ "tag", "-l" });
    defer allocator.free(tag_list);
    try std.testing.expect(std.mem.indexOf(u8, tag_list, "v1.0.0") != null);

    const desc = try execGit(allocator, tmp, &.{ "describe", "--tags", "--exact-match" });
    defer allocator.free(desc);
    try std.testing.expectEqualStrings("v1.0.0", trimRight(desc));

    // Lockfile should be correct size
    const lock_size = try execGit(allocator, tmp, &.{ "cat-file", "-s", "HEAD:bun.lockb" });
    defer allocator.free(lock_size);
    try std.testing.expectEqualStrings("512", trimRight(lock_size));

    // src/index.ts content
    const src_content = try execGit(allocator, tmp, &.{ "show", "HEAD:src/index.ts" });
    defer allocator.free(src_content);
    try std.testing.expectEqualStrings("export default 1;", trimRight(src_content));

    // Then add more files in a second commit
    try writeFile(tmp, "src/utils.ts", "export function add(a: number, b: number) { return a + b; }", allocator);
    try writeFile(tmp, "README.md", "# @bun/app\n\nA test application.", allocator);
    try repo.add("src/utils.ts");
    try repo.add("README.md");
    _ = try repo.commit("docs: add README and utils", "bun-bot", "bot@bun.sh");

    // Should now have 2 commits and 7 files
    const count2 = try execGit(allocator, tmp, &.{ "rev-list", "--count", "HEAD" });
    defer allocator.free(count2);
    try std.testing.expectEqualStrings("2", trimRight(count2));

    const ls = try execGit(allocator, tmp, &.{ "ls-tree", "-r", "--name-only", "HEAD" });
    defer allocator.free(ls);
    var fcount: usize = 0;
    var it = std.mem.splitScalar(u8, trimRight(ls), '\n');
    while (it.next()) |line| {
        if (line.len > 0) fcount += 1;
    }
    try std.testing.expectEqual(@as(usize, 7), fcount);
}

// ============================================================
// 9. git creates multiple tags -> ziggit findCommit resolves
// ============================================================

test "git creates multiple tags -> ziggit findCommit resolves each" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try execGitNoOutput(allocator, tmp, &.{"init"});
    try execGitNoOutput(allocator, tmp, &.{ "config", "user.name", "T" });
    try execGitNoOutput(allocator, tmp, &.{ "config", "user.email", "t@t" });

    var git_hashes: [3][]const u8 = undefined;

    try writeFile(tmp, "v1.txt", "v1", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "v1.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "v1" });
    git_hashes[0] = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    try execGitNoOutput(allocator, tmp, &.{ "tag", "v1.0.0" });

    try writeFile(tmp, "v2.txt", "v2", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "v2.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "v2" });
    git_hashes[1] = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    try execGitNoOutput(allocator, tmp, &.{ "tag", "v2.0.0" });

    try writeFile(tmp, "v3.txt", "v3", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "v3.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "v3" });
    git_hashes[2] = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    try execGitNoOutput(allocator, tmp, &.{ "tag", "v3.0.0" });
    defer for (&git_hashes) |h| allocator.free(h);

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();

    const found1 = try repo.findCommit("v1.0.0");
    try std.testing.expectEqualSlices(u8, trimRight(git_hashes[0]), &found1);

    const found2 = try repo.findCommit("v2.0.0");
    try std.testing.expectEqualSlices(u8, trimRight(git_hashes[1]), &found2);

    const found3 = try repo.findCommit("v3.0.0");
    try std.testing.expectEqualSlices(u8, trimRight(git_hashes[2]), &found3);

    const head = try repo.revParseHead();
    try std.testing.expectEqualSlices(u8, trimRight(git_hashes[2]), &head);
}

// ============================================================
// 10. 20 commits with tags every 5th -> git validates graph
// ============================================================

test "ziggit 20 commits with tags every 5th -> git validates entire graph" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    for (0..20) |i| {
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "file_{d:0>2}.txt", .{i}) catch unreachable;
        var content_buf: [32]u8 = undefined;
        const content = std.fmt.bufPrint(&content_buf, "data_{d}", .{i}) catch unreachable;
        try writeFile(tmp, name, content, allocator);
        try repo.add(name);
        var msg_buf: [32]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "commit {d}", .{i}) catch unreachable;
        _ = try repo.commit(msg, "T", "t@t");

        if (i % 5 == 4) {
            var tag_buf: [16]u8 = undefined;
            const tag = std.fmt.bufPrint(&tag_buf, "v{d}.0.0", .{(i + 1) / 5}) catch unreachable;
            try repo.createTag(tag, null);
        }
    }

    // 20 commits
    const count = try execGit(allocator, tmp, &.{ "rev-list", "--count", "HEAD" });
    defer allocator.free(count);
    try std.testing.expectEqualStrings("20", trimRight(count));

    // 4 tags
    const tags = try execGit(allocator, tmp, &.{ "tag", "-l" });
    defer allocator.free(tags);
    var tag_count: usize = 0;
    var it = std.mem.splitScalar(u8, trimRight(tags), '\n');
    while (it.next()) |line| {
        if (line.len > 0) tag_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), tag_count);

    // 20 files in latest tree
    const ls_tree = try execGit(allocator, tmp, &.{ "ls-tree", "--name-only", "HEAD" });
    defer allocator.free(ls_tree);
    var file_count: usize = 0;
    var it2 = std.mem.splitScalar(u8, trimRight(ls_tree), '\n');
    while (it2.next()) |line| {
        if (line.len > 0) file_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 20), file_count);

    // git fsck --strict
    const fsck = try execGit(allocator, tmp, &.{ "fsck", "--strict", "--no-dangling" });
    defer allocator.free(fsck);

    // describe should find v4.0.0
    const desc = try execGit(allocator, tmp, &.{ "describe", "--tags", "--exact-match" });
    defer allocator.free(desc);
    try std.testing.expectEqualStrings("v4.0.0", trimRight(desc));
}

// ============================================================
// 11. Clone bare -> clone from bare -> verify
// ============================================================

test "ziggit creates repo -> git clone --bare -> git clone -> files match" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    const src = try std.fmt.allocPrint(allocator, "{s}/src", .{tmp});
    defer allocator.free(src);
    std.fs.makeDirAbsolute(src) catch {};

    var repo = try ziggit.Repository.init(allocator, src);
    try writeFile(src, "package.json", "{\"name\":\"clone-test\",\"version\":\"1.0.0\"}", allocator);
    try writeFile(src, "lib/main.js", "exports.main = true;", allocator);
    try repo.add("package.json");
    try repo.add("lib/main.js");
    const orig_hash = try repo.commit("initial", "T", "t@t");
    try repo.createTag("v1.0.0", null);
    repo.close();

    // git clone --bare
    const bare = try std.fmt.allocPrint(allocator, "{s}/bare.git", .{tmp});
    defer allocator.free(bare);
    try execGitNoOutput(allocator, tmp, &.{ "clone", "--bare", src, bare });

    // git clone from bare
    const checkout = try std.fmt.allocPrint(allocator, "{s}/checkout", .{tmp});
    defer allocator.free(checkout);
    try execGitNoOutput(allocator, tmp, &.{ "clone", bare, checkout });

    // Verify HEAD matches
    const checkout_head = try execGit(allocator, checkout, &.{ "rev-parse", "HEAD" });
    defer allocator.free(checkout_head);
    try std.testing.expectEqualSlices(u8, &orig_hash, trimRight(checkout_head));

    // Verify files
    const pkg = try execGit(allocator, checkout, &.{ "show", "HEAD:package.json" });
    defer allocator.free(pkg);
    try std.testing.expect(std.mem.indexOf(u8, pkg, "clone-test") != null);

    const lib = try execGit(allocator, checkout, &.{ "show", "HEAD:lib/main.js" });
    defer allocator.free(lib);
    try std.testing.expectEqualStrings("exports.main = true;", trimRight(lib));

    // Tag survives clone
    const tag = try execGit(allocator, bare, &.{ "tag", "-l" });
    defer allocator.free(tag);
    try std.testing.expect(std.mem.indexOf(u8, tag, "v1.0.0") != null);
}

// ============================================================
// 12. git creates branches -> ziggit branchList finds all
// ============================================================

test "git creates branches -> ziggit branchList finds all" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try execGitNoOutput(allocator, tmp, &.{"init"});
    try execGitNoOutput(allocator, tmp, &.{ "config", "user.name", "T" });
    try execGitNoOutput(allocator, tmp, &.{ "config", "user.email", "t@t" });

    try writeFile(tmp, "f.txt", "base", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "f.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "base" });

    try execGitNoOutput(allocator, tmp, &.{ "branch", "develop" });
    try execGitNoOutput(allocator, tmp, &.{ "branch", "feature-auth" });
    try execGitNoOutput(allocator, tmp, &.{ "branch", "release-1.0" });

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();

    const branches = try repo.branchList(allocator);
    defer {
        for (branches) |b| allocator.free(b);
        allocator.free(branches);
    }

    try std.testing.expect(branches.len >= 4);

    var found_master = false;
    var found_develop = false;
    var found_auth = false;
    var found_release = false;
    for (branches) |b| {
        if (std.mem.eql(u8, b, "master") or std.mem.eql(u8, b, "main")) found_master = true;
        if (std.mem.eql(u8, b, "develop")) found_develop = true;
        if (std.mem.eql(u8, b, "feature-auth")) found_auth = true;
        if (std.mem.eql(u8, b, "release-1.0")) found_release = true;
    }
    try std.testing.expect(found_master);
    try std.testing.expect(found_develop);
    try std.testing.expect(found_auth);
    try std.testing.expect(found_release);
}

// ============================================================
// 13. statusPorcelain matches git on clean repo
// ============================================================

test "ziggit statusPorcelain empty on clean repo matches git" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    try writeFile(tmp, "clean.txt", "clean", allocator);
    try repo.add("clean.txt");
    _ = try repo.commit("clean commit", "T", "t@t");

    const porcelain = try repo.statusPorcelain(allocator);
    defer allocator.free(porcelain);
    try std.testing.expectEqualStrings("", trimRight(porcelain));

    const git_status = try execGit(allocator, tmp, &.{ "status", "--porcelain" });
    defer allocator.free(git_status);
    try std.testing.expectEqualStrings("", trimRight(git_status));
}

// ============================================================
// 14. describeTags with distance
// ============================================================

test "ziggit describeTags 3 commits past tag includes tag name" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    try writeFile(tmp, "tagged.txt", "tagged", allocator);
    try repo.add("tagged.txt");
    _ = try repo.commit("tagged commit", "T", "t@t");
    try repo.createTag("v1.0.0", null);

    // 3 commits past the tag (each with a new unique file)
    for (0..3) |i| {
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "post_{d}.txt", .{i}) catch unreachable;
        var content_buf: [32]u8 = undefined;
        const content = std.fmt.bufPrint(&content_buf, "post-{d}", .{i}) catch unreachable;
        try writeFile(tmp, name, content, allocator);
        try repo.add(name);
        _ = try repo.commit(content, "T", "t@t");
    }

    const desc = try repo.describeTags(allocator);
    defer allocator.free(desc);
    try std.testing.expect(std.mem.indexOf(u8, desc, "v1.0.0") != null);

    const git_desc = try execGit(allocator, tmp, &.{ "describe", "--tags" });
    defer allocator.free(git_desc);
    try std.testing.expect(std.mem.indexOf(u8, git_desc, "v1.0.0") != null);
}

// ============================================================
// 15. Empty file + normal file in same commit
// ============================================================

test "ziggit empty file + normal file in same commit -> git validates both" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    try writeFile(tmp, "empty.txt", "", allocator);
    try writeFile(tmp, "nonempty.txt", "has content", allocator);
    try repo.add("empty.txt");
    try repo.add("nonempty.txt");
    _ = try repo.commit("mixed empty and nonempty", "T", "t@t");

    // Empty file should have the well-known empty blob SHA
    const empty_hash = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD:empty.txt" });
    defer allocator.free(empty_hash);
    try std.testing.expectEqualStrings("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391", trimRight(empty_hash));

    // Non-empty file has content
    const content = try execGit(allocator, tmp, &.{ "show", "HEAD:nonempty.txt" });
    defer allocator.free(content);
    try std.testing.expectEqualStrings("has content", trimRight(content));

    // Empty file size = 0
    const size = try execGit(allocator, tmp, &.{ "cat-file", "-s", "HEAD:empty.txt" });
    defer allocator.free(size);
    try std.testing.expectEqualStrings("0", trimRight(size));
}

// ============================================================
// 16. git cherry-pick -> ziggit reads HEAD
// ============================================================

test "git cherry-pick from branch -> ziggit reads resulting HEAD" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try execGitNoOutput(allocator, tmp, &.{"init"});
    try execGitNoOutput(allocator, tmp, &.{ "config", "user.name", "T" });
    try execGitNoOutput(allocator, tmp, &.{ "config", "user.email", "t@t" });

    try writeFile(tmp, "base.txt", "base", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "base.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "base" });

    try execGitNoOutput(allocator, tmp, &.{ "checkout", "-b", "feature" });
    try writeFile(tmp, "feature.txt", "feature", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "feature.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "feature commit" });
    const feature_hash = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(feature_hash);

    try execGitNoOutput(allocator, tmp, &.{ "checkout", "master" });
    try execGitNoOutput(allocator, tmp, &.{ "cherry-pick", trimRight(feature_hash) });

    const git_head = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(git_head);

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();
    const z_head = try repo.revParseHead();
    try std.testing.expectEqualStrings(trimRight(git_head), &z_head);
    try std.testing.expect(try repo.isClean());
}

// ============================================================
// 17. git reset --hard -> ziggit reads new HEAD
// ============================================================

test "git reset --hard -> ziggit reads rolled-back HEAD" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try execGitNoOutput(allocator, tmp, &.{"init"});
    try execGitNoOutput(allocator, tmp, &.{ "config", "user.name", "T" });
    try execGitNoOutput(allocator, tmp, &.{ "config", "user.email", "t@t" });

    try writeFile(tmp, "f1.txt", "v1", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "f1.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "c1" });

    const first_head = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(first_head);

    try writeFile(tmp, "f2.txt", "v2", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "f2.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "c2" });

    try execGitNoOutput(allocator, tmp, &.{ "reset", "--hard", "HEAD~1" });

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();
    const z_head = try repo.revParseHead();
    try std.testing.expectEqualStrings(trimRight(first_head), &z_head);
}

// ============================================================
// 18. git amend -> ziggit reads new HEAD hash
// ============================================================

test "git amend commit -> ziggit reads amended HEAD" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try execGitNoOutput(allocator, tmp, &.{"init"});
    try execGitNoOutput(allocator, tmp, &.{ "config", "user.name", "T" });
    try execGitNoOutput(allocator, tmp, &.{ "config", "user.email", "t@t" });

    try writeFile(tmp, "f.txt", "original", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "f.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "original" });

    try writeFile(tmp, "extra.txt", "extra", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "extra.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "--amend", "-m", "amended" });

    const git_head = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(git_head);

    // Still only 1 commit after amend
    const count = try execGit(allocator, tmp, &.{ "rev-list", "--count", "HEAD" });
    defer allocator.free(count);
    try std.testing.expectEqualStrings("1", trimRight(count));

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();
    const z_head = try repo.revParseHead();
    try std.testing.expectEqualStrings(trimRight(git_head), &z_head);
}

// ============================================================
// 19. Mixed operations: ziggit and git interleaved
// ============================================================

test "ziggit commit 1, git commit 2, ziggit commit 3 -> all agree" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    // ziggit init + commit 1
    var repo = try ziggit.Repository.init(allocator, tmp);
    try writeFile(tmp, "z1.txt", "ziggit1", allocator);
    try repo.add("z1.txt");
    _ = try repo.commit("ziggit-1", "Z", "z@z");
    repo.close();

    // git commit 2
    try execGitNoOutput(allocator, tmp, &.{ "config", "user.name", "G" });
    try execGitNoOutput(allocator, tmp, &.{ "config", "user.email", "g@g" });
    try writeFile(tmp, "g1.txt", "git1", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "g1.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "git-2" });

    // ziggit commit 3
    var repo2 = try ziggit.Repository.open(allocator, tmp);
    defer repo2.close();
    try writeFile(tmp, "z2.txt", "ziggit2", allocator);
    try repo2.add("z2.txt");
    _ = try repo2.commit("ziggit-3", "Z", "z@z");

    // Both should agree
    const count = try execGit(allocator, tmp, &.{ "rev-list", "--count", "HEAD" });
    defer allocator.free(count);
    try std.testing.expectEqualStrings("3", trimRight(count));

    const head = try repo2.revParseHead();
    const git_head = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(git_head);
    try std.testing.expectEqualSlices(u8, &head, trimRight(git_head));

    // All 3 files accessible
    const ls = try execGit(allocator, tmp, &.{ "ls-tree", "--name-only", "HEAD" });
    defer allocator.free(ls);
    try std.testing.expect(std.mem.indexOf(u8, ls, "z1.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, ls, "g1.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, ls, "z2.txt") != null);

    // fsck
    const fsck = try execGit(allocator, tmp, &.{ "fsck", "--no-dangling" });
    defer allocator.free(fsck);
    try std.testing.expect(std.mem.indexOf(u8, fsck, "error") == null);
}

// ============================================================
// 20. git merge --no-ff -> ziggit reads merge commit
// ============================================================

test "git merge --no-ff creates 2-parent commit -> ziggit reads HEAD" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try execGitNoOutput(allocator, tmp, &.{"init"});
    try execGitNoOutput(allocator, tmp, &.{ "config", "user.name", "T" });
    try execGitNoOutput(allocator, tmp, &.{ "config", "user.email", "t@t" });

    try writeFile(tmp, "base.txt", "base", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "base.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "base" });

    try execGitNoOutput(allocator, tmp, &.{ "checkout", "-b", "feature" });
    try writeFile(tmp, "feat.txt", "feat", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "feat.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "feature" });

    try execGitNoOutput(allocator, tmp, &.{ "checkout", "master" });
    try execGitNoOutput(allocator, tmp, &.{ "merge", "--no-ff", "feature", "-m", "merge feature" });

    // Verify it's a merge commit
    const parents = try execGit(allocator, tmp, &.{ "cat-file", "-p", "HEAD" });
    defer allocator.free(parents);
    var parent_count: u32 = 0;
    var it = std.mem.splitScalar(u8, parents, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "parent ")) parent_count += 1;
    }
    try std.testing.expectEqual(@as(u32, 2), parent_count);

    const git_head = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(git_head);

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();
    const z_head = try repo.revParseHead();
    try std.testing.expectEqualStrings(trimRight(git_head), &z_head);
}
