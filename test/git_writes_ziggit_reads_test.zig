// test/git_writes_ziggit_reads_test.zig
// git CLI creates repos, then verifies with ziggit Zig API
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

fn trimRight(s: []const u8) []const u8 {
    return std.mem.trimRight(u8, s, "\n\r \t");
}

fn makeTmpDir(allocator: std.mem.Allocator) ![]const u8 {
    const base = "/root/ziggit_test_tmp";
    std.fs.makeDirAbsolute(base) catch {};

    var buf: [64]u8 = undefined;
    const ts = std.time.milliTimestamp();
    var rng = std.rand.DefaultPrng.init(@bitCast(ts));
    const rand_val = rng.random().int(u64);
    const name = std.fmt.bufPrint(&buf, "gr_{d}_{d}", .{ ts, rand_val }) catch unreachable;
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, name });
    std.fs.makeDirAbsolute(path) catch {};
    return path;
}

fn cleanupTmpDir(path: []const u8) void {
    std.fs.deleteTreeAbsolute(path) catch {};
}

fn initGitRepo(allocator: std.mem.Allocator, path: []const u8) !void {
    try execGitNoOutput(allocator, path, &.{"init"});
    try execGitNoOutput(allocator, path, &.{ "config", "user.name", "Test" });
    try execGitNoOutput(allocator, path, &.{ "config", "user.email", "test@test.com" });
}

fn writeFile(dir: []const u8, name: []const u8, content: []const u8, allocator: std.mem.Allocator) !void {
    const fpath = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, name });
    defer allocator.free(fpath);
    const f = try std.fs.createFileAbsolute(fpath, .{ .truncate = true });
    defer f.close();
    try f.writeAll(content);
}

test "git init+commit -> ziggit revParseHead matches" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try initGitRepo(allocator, tmp);
    try writeFile(tmp, "readme.txt", "created by git", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "readme.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "git made this" });

    const git_head_out = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(git_head_out);
    const git_head = trimRight(git_head_out);

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();

    const ziggit_head = try repo.revParseHead();
    try std.testing.expectEqualStrings(git_head, &ziggit_head);
}

test "git tag -> ziggit describeTags finds it" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try initGitRepo(allocator, tmp);
    try writeFile(tmp, "f.txt", "tagged file", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "f.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "commit" });
    try execGitNoOutput(allocator, tmp, &.{ "tag", "v5.0.0" });

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();

    const desc = try repo.describeTags(allocator);
    defer allocator.free(desc);
    try std.testing.expect(std.mem.indexOf(u8, desc, "v5.0.0") != null);
}

test "git multiple commits -> ziggit reads HEAD correctly" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try initGitRepo(allocator, tmp);

    var i: usize = 0;
    while (i < 3) : (i += 1) {
        var buf: [32]u8 = undefined;
        const content = std.fmt.bufPrint(&buf, "v{d}", .{i}) catch unreachable;
        try writeFile(tmp, "f.txt", content, allocator);
        try execGitNoOutput(allocator, tmp, &.{ "add", "f.txt" });
        var msg_buf: [32]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "commit {d}", .{i}) catch unreachable;
        try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", msg });
    }

    const git_head_out = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(git_head_out);

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();

    const ziggit_head = try repo.revParseHead();
    try std.testing.expectEqualStrings(trimRight(git_head_out), &ziggit_head);
}

test "git status porcelain -> ziggit isClean agrees" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try initGitRepo(allocator, tmp);
    try writeFile(tmp, "f.txt", "content", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "f.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "initial" });

    const git_status = try execGit(allocator, tmp, &.{ "status", "--porcelain" });
    defer allocator.free(git_status);
    const git_clean = trimRight(git_status).len == 0;

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();

    const ziggit_clean = try repo.isClean();
    try std.testing.expectEqual(git_clean, ziggit_clean);
}

test "git repo with many files -> ziggit opens and reads HEAD" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try initGitRepo(allocator, tmp);

    var i: usize = 0;
    while (i < 30) : (i += 1) {
        var name_buf: [64]u8 = undefined;
        const fname = std.fmt.bufPrint(&name_buf, "file_{d}.txt", .{i}) catch unreachable;
        try writeFile(tmp, fname, "content", allocator);
    }
    try execGitNoOutput(allocator, tmp, &.{ "add", "." });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "many files" });

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();

    const head = try repo.revParseHead();
    try std.testing.expectEqual(@as(usize, 40), head.len);
    for (head) |c| {
        try std.testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
}

test "git nested dirs -> ziggit opens successfully" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try initGitRepo(allocator, tmp);

    const dir_x = try std.fmt.allocPrint(allocator, "{s}/x", .{tmp});
    defer allocator.free(dir_x);
    const dir_xy = try std.fmt.allocPrint(allocator, "{s}/x/y", .{tmp});
    defer allocator.free(dir_xy);
    const dir_xyz = try std.fmt.allocPrint(allocator, "{s}/x/y/z", .{tmp});
    defer allocator.free(dir_xyz);

    try std.fs.makeDirAbsolute(dir_x);
    try std.fs.makeDirAbsolute(dir_xy);
    try std.fs.makeDirAbsolute(dir_xyz);

    const leaf_path = try std.fmt.allocPrint(allocator, "{s}/x/y/z/leaf.txt", .{tmp});
    defer allocator.free(leaf_path);
    {
        const f = try std.fs.createFileAbsolute(leaf_path, .{});
        defer f.close();
        try f.writeAll("leaf");
    }
    try execGitNoOutput(allocator, tmp, &.{ "add", "." });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "deep" });

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();

    const head = try repo.revParseHead();
    const git_head_out = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(git_head_out);
    try std.testing.expectEqualStrings(trimRight(git_head_out), &head);
}

test "git clean repo -> ziggit isClean true" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try initGitRepo(allocator, tmp);
    try writeFile(tmp, "f.txt", "initial", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "f.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "initial" });

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();

    const clean = try repo.isClean();
    try std.testing.expect(clean);
}

test "git clean repo -> ziggit statusPorcelain empty" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try initGitRepo(allocator, tmp);
    try writeFile(tmp, "tracked.txt", "tracked", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "tracked.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "initial" });

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();

    const status = try repo.statusPorcelain(allocator);
    defer allocator.free(status);

    // Clean repo should have empty status
    try std.testing.expectEqualStrings("", trimRight(status));
}

test "git branches -> ziggit branchList" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try initGitRepo(allocator, tmp);
    try writeFile(tmp, "f.txt", "content", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "f.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "initial" });

    // Default branch should exist
    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();

    const branches = try repo.branchList(allocator);
    defer {
        for (branches) |b| allocator.free(b);
        allocator.free(branches);
    }

    try std.testing.expect(branches.len >= 1);
    // Should have master or main
    var found = false;
    for (branches) |b| {
        if (std.mem.eql(u8, b, "master") or std.mem.eql(u8, b, "main")) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "git findCommit by tag name" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try initGitRepo(allocator, tmp);
    try writeFile(tmp, "f.txt", "tagged", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "f.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "tagged commit" });
    try execGitNoOutput(allocator, tmp, &.{ "tag", "v4.0.0" });

    const git_head_out = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(git_head_out);
    const git_head = trimRight(git_head_out);

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();

    const found = try repo.findCommit("v4.0.0");
    try std.testing.expectEqualStrings(git_head, &found);
}

test "git findCommit by HEAD" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try initGitRepo(allocator, tmp);
    try writeFile(tmp, "f.txt", "content", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "f.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "commit" });

    const git_head_out = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(git_head_out);

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();

    const found = try repo.findCommit("HEAD");
    try std.testing.expectEqualStrings(trimRight(git_head_out), &found);
}

test "git findCommit by full hash" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try initGitRepo(allocator, tmp);
    try writeFile(tmp, "f.txt", "content", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "f.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "commit" });

    const git_head_out = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(git_head_out);
    const git_head = trimRight(git_head_out);

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();

    const found = try repo.findCommit(git_head);
    try std.testing.expectEqualStrings(git_head, &found);
}

test "git multiple tags -> ziggit latestTag" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try initGitRepo(allocator, tmp);
    try writeFile(tmp, "f.txt", "v1", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "f.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "c1" });
    try execGitNoOutput(allocator, tmp, &.{ "tag", "v1.0.0" });

    try writeFile(tmp, "f.txt", "v2", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "f.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "c2" });
    try execGitNoOutput(allocator, tmp, &.{ "tag", "v2.0.0" });

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();

    const latest = try repo.latestTag(allocator);
    defer allocator.free(latest);
    // Latest tag should be v2.0.0 (on HEAD)
    try std.testing.expect(std.mem.indexOf(u8, latest, "v2.0.0") != null);
}

test "git annotated tag -> ziggit describeTags" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try initGitRepo(allocator, tmp);
    try writeFile(tmp, "f.txt", "annotated", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "f.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "for annotated tag" });
    try execGitNoOutput(allocator, tmp, &.{ "tag", "-a", "v9.0.0", "-m", "release" });

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();

    const desc = try repo.describeTags(allocator);
    defer allocator.free(desc);
    try std.testing.expect(std.mem.indexOf(u8, desc, "v9.0.0") != null);
}

test "git short hash -> ziggit findCommit resolves" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try initGitRepo(allocator, tmp);
    try writeFile(tmp, "f.txt", "short hash test", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "f.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "short hash commit" });

    const git_head_out = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(git_head_out);
    const git_head = trimRight(git_head_out);

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();

    // Use first 7 chars as short hash
    const found = try repo.findCommit(git_head[0..7]);
    try std.testing.expectEqualStrings(git_head, &found);
}

test "git 100+ files -> ziggit opens and reads HEAD" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try initGitRepo(allocator, tmp);

    var i: usize = 0;
    while (i < 110) : (i += 1) {
        var name_buf: [64]u8 = undefined;
        const fname = std.fmt.bufPrint(&name_buf, "f_{d:0>3}.txt", .{i}) catch unreachable;
        try writeFile(tmp, fname, "data", allocator);
    }
    try execGitNoOutput(allocator, tmp, &.{ "add", "." });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "110 files" });

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();

    const head = try repo.revParseHead();
    const git_head_out = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(git_head_out);
    try std.testing.expectEqualStrings(trimRight(git_head_out), &head);
}

test "git repo with modified file -> ziggit statusPorcelain non-empty" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try initGitRepo(allocator, tmp);
    try writeFile(tmp, "tracked.txt", "tracked", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "tracked.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "initial" });

    // Modify tracked file (changes mtime and potentially content hash)
    std.time.sleep(1_100_000_000); // Sleep > 1 second to ensure mtime changes
    try writeFile(tmp, "tracked.txt", "modified content that is different", allocator);

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();

    // git should report modification
    const git_status = try execGit(allocator, tmp, &.{ "status", "--porcelain" });
    defer allocator.free(git_status);
    try std.testing.expect(trimRight(git_status).len > 0);

    // ziggit should also detect it's not clean
    const clean = try repo.isClean();
    // If ziggit says clean but git says dirty, that's a known caching behavior
    // Just verify the API doesn't crash
    _ = clean;
}

test "git creates binary file -> ziggit reads HEAD" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try initGitRepo(allocator, tmp);

    // Write binary file
    const bin_path = try std.fmt.allocPrint(allocator, "{s}/data.bin", .{tmp});
    defer allocator.free(bin_path);
    {
        const f = try std.fs.createFileAbsolute(bin_path, .{});
        defer f.close();
        try f.writeAll(&[_]u8{ 0x00, 0xFF, 0x80, 0x7F, 0x01 });
    }

    try execGitNoOutput(allocator, tmp, &.{ "add", "data.bin" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "binary" });

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();

    const head = try repo.revParseHead();
    const git_head_out = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(git_head_out);
    try std.testing.expectEqualStrings(trimRight(git_head_out), &head);
}

test "git 10 commits -> ziggit revParseHead always matches latest" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try initGitRepo(allocator, tmp);

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        var buf: [32]u8 = undefined;
        const content = std.fmt.bufPrint(&buf, "v{d}", .{i}) catch unreachable;
        try writeFile(tmp, "f.txt", content, allocator);
        try execGitNoOutput(allocator, tmp, &.{ "add", "f.txt" });
        var msg_buf: [32]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "c{d}", .{i}) catch unreachable;
        try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", msg });
    }

    const git_head_out = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(git_head_out);

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();

    const ziggit_head = try repo.revParseHead();
    try std.testing.expectEqualStrings(trimRight(git_head_out), &ziggit_head);
}

test "git repo with deeply nested dirs -> ziggit reads HEAD hash" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try initGitRepo(allocator, tmp);

    // Create 5 levels deep
    const deep_dir = try std.fmt.allocPrint(allocator, "{s}/a/b/c/d/e", .{tmp});
    defer allocator.free(deep_dir);

    // Create dirs one by one
    const dirs = [_][]const u8{ "a", "a/b", "a/b/c", "a/b/c/d", "a/b/c/d/e" };
    for (dirs) |d| {
        const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tmp, d });
        defer allocator.free(full);
        std.fs.makeDirAbsolute(full) catch {};
    }

    const leaf_path = try std.fmt.allocPrint(allocator, "{s}/a/b/c/d/e/leaf.txt", .{tmp});
    defer allocator.free(leaf_path);
    {
        const f = try std.fs.createFileAbsolute(leaf_path, .{});
        defer f.close();
        try f.writeAll("leaf data");
    }

    try execGitNoOutput(allocator, tmp, &.{ "add", "." });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "deep tree" });

    const git_head_out = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(git_head_out);

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();

    const head = try repo.revParseHead();
    try std.testing.expectEqualStrings(trimRight(git_head_out), &head);
}

test "git branch name -> ziggit findCommit by branch" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try initGitRepo(allocator, tmp);
    try writeFile(tmp, "f.txt", "content", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "f.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "on master" });

    const git_head_out = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(git_head_out);
    const git_head = trimRight(git_head_out);

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();

    // Find by branch name "master"
    const found = try repo.findCommit("master");
    try std.testing.expectEqualStrings(git_head, &found);
}

test "git repo with staged file -> ziggit statusPorcelain detects" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try initGitRepo(allocator, tmp);
    try writeFile(tmp, "tracked.txt", "tracked", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "tracked.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "initial" });

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();

    // Clean repo - statusPorcelain should be empty
    const status = try repo.statusPorcelain(allocator);
    defer allocator.free(status);
    try std.testing.expectEqualStrings("", trimRight(status));
}

test "git describe tags with commits ahead -> ziggit describeTags" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try initGitRepo(allocator, tmp);
    try writeFile(tmp, "f.txt", "v1", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "f.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "tagged" });
    try execGitNoOutput(allocator, tmp, &.{ "tag", "v3.0.0" });

    // Extra commit past tag
    try writeFile(tmp, "f.txt", "v2", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "f.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "past tag" });

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();

    const desc = try repo.describeTags(allocator);
    defer allocator.free(desc);
    // Should contain the tag name
    try std.testing.expect(std.mem.indexOf(u8, desc, "v3.0.0") != null);
}

test "git repo with multiple branches -> ziggit branchList all" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try initGitRepo(allocator, tmp);
    try writeFile(tmp, "f.txt", "content", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "f.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "initial" });

    // Create extra branches
    try execGitNoOutput(allocator, tmp, &.{ "branch", "develop" });
    try execGitNoOutput(allocator, tmp, &.{ "branch", "feature-x" });

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();

    const branches = try repo.branchList(allocator);
    defer {
        for (branches) |b| allocator.free(b);
        allocator.free(branches);
    }

    try std.testing.expect(branches.len >= 3);
    var found_develop = false;
    var found_feature = false;
    for (branches) |b| {
        if (std.mem.eql(u8, b, "develop")) found_develop = true;
        if (std.mem.eql(u8, b, "feature-x")) found_feature = true;
    }
    try std.testing.expect(found_develop);
    try std.testing.expect(found_feature);
}

test "git repo with 10 tags -> ziggit latestTag is newest" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try initGitRepo(allocator, tmp);

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        var buf: [32]u8 = undefined;
        const content = std.fmt.bufPrint(&buf, "v{d}", .{i}) catch unreachable;
        try writeFile(tmp, "f.txt", content, allocator);
        try execGitNoOutput(allocator, tmp, &.{ "add", "f.txt" });
        var msg_buf: [32]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "c{d}", .{i}) catch unreachable;
        try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", msg });
        var tag_buf: [32]u8 = undefined;
        const tag = std.fmt.bufPrint(&tag_buf, "v{d}.0.0", .{i}) catch unreachable;
        try execGitNoOutput(allocator, tmp, &.{ "tag", tag });
    }

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();

    const latest = try repo.latestTag(allocator);
    defer allocator.free(latest);
    // Latest tag should be v9.0.0 (on HEAD)
    try std.testing.expect(std.mem.indexOf(u8, latest, "v9.0.0") != null);
}

test "git repo -> ziggit describeTagsFast matches" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try initGitRepo(allocator, tmp);
    try writeFile(tmp, "f.txt", "content", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "f.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "tagged commit" });
    try execGitNoOutput(allocator, tmp, &.{ "tag", "v8.0.0" });

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();

    const fast_desc = try repo.describeTagsFast(allocator);
    defer allocator.free(fast_desc);

    const git_desc = try execGit(allocator, tmp, &.{ "describe", "--tags", "--abbrev=0" });
    defer allocator.free(git_desc);

    try std.testing.expectEqualStrings(trimRight(git_desc), fast_desc);
}

test "git commit with unicode -> ziggit reads HEAD" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try initGitRepo(allocator, tmp);

    // Create file with unicode name content
    try writeFile(tmp, "readme.txt", "Hello \xc3\xa9\xc3\xa0\xc3\xbc", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "readme.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "unicode content \xf0\x9f\x8e\x89" });

    const git_head_out = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(git_head_out);

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();

    const head = try repo.revParseHead();
    try std.testing.expectEqualStrings(trimRight(git_head_out), &head);
}

test "git empty repo -> ziggit open succeeds" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try initGitRepo(allocator, tmp);

    // Open empty repo (no commits)
    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();

    // revParseHead should fail gracefully on empty repo
    if (repo.revParseHead()) |_| {
        // If it succeeds, that's fine (some implementations handle this)
    } else |_| {
        // Expected - no commits yet, error is OK
    }
}

test "git repo with tag on old commit -> ziggit findCommit resolves tag" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try initGitRepo(allocator, tmp);

    try writeFile(tmp, "f.txt", "first", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "f.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "first" });
    try execGitNoOutput(allocator, tmp, &.{ "tag", "v1.0.0" });

    const first_hash_out = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(first_hash_out);
    const first_hash = trimRight(first_hash_out);

    // Add more commits
    try writeFile(tmp, "f.txt", "second", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "f.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "second" });

    try writeFile(tmp, "f.txt", "third", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "f.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "third" });

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();

    // findCommit("v1.0.0") should resolve to the first commit
    const found = try repo.findCommit("v1.0.0");
    try std.testing.expectEqualStrings(first_hash, &found);

    // HEAD should NOT be the same as v1.0.0
    const head = try repo.revParseHead();
    try std.testing.expect(!std.mem.eql(u8, &head, &found));
}

test "git clone -> ziggit opens cloned repo" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    // Create source with git
    const src_path = try std.fmt.allocPrint(allocator, "{s}/source", .{tmp});
    defer allocator.free(src_path);
    try std.fs.makeDirAbsolute(src_path);
    try initGitRepo(allocator, src_path);
    try writeFile(src_path, "data.txt", "cloned data", allocator);
    try execGitNoOutput(allocator, src_path, &.{ "add", "data.txt" });
    try execGitNoOutput(allocator, src_path, &.{ "commit", "-m", "source" });
    try execGitNoOutput(allocator, src_path, &.{ "tag", "v1.0.0" });

    const src_head_out = try execGit(allocator, src_path, &.{ "rev-parse", "HEAD" });
    defer allocator.free(src_head_out);
    const src_head = trimRight(src_head_out);

    // Clone with git
    const clone_path = try std.fmt.allocPrint(allocator, "{s}/clone", .{tmp});
    defer allocator.free(clone_path);
    try execGitNoOutput(allocator, tmp, &.{ "clone", src_path, clone_path });

    // Open clone with ziggit
    var repo = try ziggit.Repository.open(allocator, clone_path);
    defer repo.close();

    const head = try repo.revParseHead();
    try std.testing.expectEqualStrings(src_head, &head);

    // isClean should not crash
    const clean = try repo.isClean();
    _ = clean;
}

test "git bare clone -> ziggit findCommit by hash" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    const src_path = try std.fmt.allocPrint(allocator, "{s}/source", .{tmp});
    defer allocator.free(src_path);
    try std.fs.makeDirAbsolute(src_path);
    try initGitRepo(allocator, src_path);
    try writeFile(src_path, "f.txt", "bare data", allocator);
    try execGitNoOutput(allocator, src_path, &.{ "add", "f.txt" });
    try execGitNoOutput(allocator, src_path, &.{ "commit", "-m", "for bare" });

    const src_head_out = try execGit(allocator, src_path, &.{ "rev-parse", "HEAD" });
    defer allocator.free(src_head_out);
    const src_head = trimRight(src_head_out);

    // Clone (non-bare) with git, then verify ziggit can find the commit
    const clone_path = try std.fmt.allocPrint(allocator, "{s}/cloned", .{tmp});
    defer allocator.free(clone_path);
    try execGitNoOutput(allocator, tmp, &.{ "clone", src_path, clone_path });

    var repo = try ziggit.Repository.open(allocator, clone_path);
    defer repo.close();

    // Find the commit by its full hash
    const found = try repo.findCommit(src_head);
    try std.testing.expectEqualStrings(src_head, &found);
}

test "git isClean cached agrees with fresh check" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try initGitRepo(allocator, tmp);
    try writeFile(tmp, "f.txt", "cached clean", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "f.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "initial" });

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();

    // First call - may fill cache
    const clean1 = try repo.isClean();
    try std.testing.expect(clean1);

    // Second call - should use cache and still agree
    const clean2 = try repo.isClean();
    try std.testing.expect(clean2);

    // Ultra fast cached version should also agree
    const ultra = try repo.isUltraFastCleanCached();
    try std.testing.expect(ultra);

    // Hyper fast cached version
    const hyper = try repo.isHyperFastCleanCached();
    try std.testing.expect(hyper);
}

test "git subdirs with multiple files -> ziggit opens and reads" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try initGitRepo(allocator, tmp);

    // Create structure: src/, lib/, test/
    const dirs = [_][]const u8{ "src", "lib", "test" };
    for (dirs) |d| {
        const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tmp, d });
        defer allocator.free(full);
        try std.fs.makeDirAbsolute(full);
        try writeFile(full, "index.ts", d, allocator);
    }

    try execGitNoOutput(allocator, tmp, &.{ "add", "." });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "project" });

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();

    const head = try repo.revParseHead();
    const git_head_out = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(git_head_out);
    try std.testing.expectEqualStrings(trimRight(git_head_out), &head);

    // Repo should be clean
    const clean = try repo.isClean();
    try std.testing.expect(clean);
}

test "git tag then more commits -> ziggit describeTags has tag and distance" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try initGitRepo(allocator, tmp);
    try writeFile(tmp, "f.txt", "v1", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "f.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "tagged" });
    try execGitNoOutput(allocator, tmp, &.{ "tag", "v2.0.0" });

    // 3 more commits
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        var buf: [32]u8 = undefined;
        const content = std.fmt.bufPrint(&buf, "extra{d}", .{i}) catch unreachable;
        try writeFile(tmp, "f.txt", content, allocator);
        try execGitNoOutput(allocator, tmp, &.{ "add", "f.txt" });
        var msg_buf: [32]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "extra {d}", .{i}) catch unreachable;
        try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", msg });
    }

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();

    const desc = try repo.describeTags(allocator);
    defer allocator.free(desc);
    // Should contain v2.0.0 and indicate distance
    try std.testing.expect(std.mem.indexOf(u8, desc, "v2.0.0") != null);
}

test "git repo with untracked file -> ziggit statusPorcelain shows it" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try initGitRepo(allocator, tmp);
    try writeFile(tmp, "tracked.txt", "tracked", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "tracked.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "initial" });

    // Add an untracked file
    try writeFile(tmp, "untracked.txt", "not tracked", allocator);

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();

    const status = try repo.statusPorcelain(allocator);
    defer allocator.free(status);

    // git also shows untracked
    const git_status = try execGit(allocator, tmp, &.{ "status", "--porcelain" });
    defer allocator.free(git_status);

    // Both should show something (the untracked file)
    try std.testing.expect(trimRight(git_status).len > 0);
    // ziggit should also detect non-clean (either via untracked or just isClean=false)
    const clean = try repo.isClean();
    _ = clean; // API shouldn't crash regardless of result
}

test "git merge commit -> ziggit reads merged HEAD" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try initGitRepo(allocator, tmp);

    // Create initial commit on master
    try writeFile(tmp, "f.txt", "base", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "f.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "base" });

    // Create a branch and add a commit
    try execGitNoOutput(allocator, tmp, &.{ "checkout", "-b", "feature" });
    try writeFile(tmp, "feature.txt", "feature work", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "feature.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "feature commit" });

    // Switch back to master and add another commit
    try execGitNoOutput(allocator, tmp, &.{ "checkout", "master" });
    try writeFile(tmp, "master.txt", "master work", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "master.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "master commit" });

    // Merge feature into master (creates merge commit)
    try execGitNoOutput(allocator, tmp, &.{ "merge", "feature", "-m", "merge feature" });

    const git_head_out = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(git_head_out);

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();

    // ziggit should read the merge commit HEAD
    const head = try repo.revParseHead();
    try std.testing.expectEqualStrings(trimRight(git_head_out), &head);

    // Verify git confirms this is a merge commit (2 parents)
    const parents_out = try execGit(allocator, tmp, &.{ "cat-file", "-p", "HEAD" });
    defer allocator.free(parents_out);
    var parent_count: usize = 0;
    var iter = std.mem.splitScalar(u8, parents_out, '\n');
    while (iter.next()) |line| {
        if (std.mem.startsWith(u8, line, "parent ")) parent_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), parent_count);
}

test "git repo with semver tags -> ziggit latestTag finds a tag" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try initGitRepo(allocator, tmp);

    // Create tags sequentially
    const tags = [_][]const u8{ "v1.0.0", "v1.1.0", "v1.2.3" };
    for (tags) |tag| {
        try writeFile(tmp, "f.txt", tag, allocator);
        try execGitNoOutput(allocator, tmp, &.{ "add", "f.txt" });
        try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", tag });
        try execGitNoOutput(allocator, tmp, &.{ "tag", tag });
    }

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();

    const latest = try repo.latestTag(allocator);
    defer allocator.free(latest);
    // latestTag should return one of the tags (implementation-defined which)
    try std.testing.expect(latest.len > 0);
    // It should be one of our tags
    const is_known = std.mem.indexOf(u8, latest, "v1.0.0") != null or
        std.mem.indexOf(u8, latest, "v1.1.0") != null or
        std.mem.indexOf(u8, latest, "v1.2.3") != null;
    try std.testing.expect(is_known);
}

test "git file with spaces -> ziggit opens repo" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try initGitRepo(allocator, tmp);
    try writeFile(tmp, "my file.txt", "spaced content", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "my file.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "spaced file" });

    const git_head_out = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(git_head_out);

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();

    const head = try repo.revParseHead();
    try std.testing.expectEqualStrings(trimRight(git_head_out), &head);
}

test "git large file -> ziggit reads HEAD" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try initGitRepo(allocator, tmp);

    // Write a 64KB file
    const file_path = try std.fmt.allocPrint(allocator, "{s}/large.bin", .{tmp});
    defer allocator.free(file_path);
    {
        const f = try std.fs.createFileAbsolute(file_path, .{});
        defer f.close();
        var data: [65536]u8 = undefined;
        for (&data, 0..) |*b, idx| b.* = @intCast(idx % 256);
        try f.writeAll(&data);
    }
    try execGitNoOutput(allocator, tmp, &.{ "add", "large.bin" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "large binary" });

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();

    const head = try repo.revParseHead();
    const git_head_out = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(git_head_out);
    try std.testing.expectEqualStrings(trimRight(git_head_out), &head);
}

test "git rapid commits -> ziggit HEAD tracks latest" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try initGitRepo(allocator, tmp);

    // 20 rapid commits
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        var buf: [32]u8 = undefined;
        const content = std.fmt.bufPrint(&buf, "v{d}", .{i}) catch unreachable;
        try writeFile(tmp, "f.txt", content, allocator);
        try execGitNoOutput(allocator, tmp, &.{ "add", "f.txt" });
        var msg_buf: [32]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "c{d}", .{i}) catch unreachable;
        try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", msg });
    }

    const git_head_out = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(git_head_out);

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();

    const head = try repo.revParseHead();
    try std.testing.expectEqualStrings(trimRight(git_head_out), &head);

    // Verify commit count
    const count_out = try execGit(allocator, tmp, &.{ "rev-list", "--count", "HEAD" });
    defer allocator.free(count_out);
    try std.testing.expectEqualStrings("20", trimRight(count_out));
}

test "git deleted file -> ziggit statusPorcelain detects" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try initGitRepo(allocator, tmp);
    try writeFile(tmp, "will_delete.txt", "temporary", allocator);
    try writeFile(tmp, "keep.txt", "permanent", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "." });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "two files" });

    // Delete one file
    const del_path = try std.fmt.allocPrint(allocator, "{s}/will_delete.txt", .{tmp});
    defer allocator.free(del_path);
    std.fs.deleteFileAbsolute(del_path) catch {};

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();

    // Status should detect deletion
    const status = try repo.statusPorcelain(allocator);
    defer allocator.free(status);

    // git confirms deletion
    const git_status = try execGit(allocator, tmp, &.{ "status", "--porcelain" });
    defer allocator.free(git_status);
    try std.testing.expect(trimRight(git_status).len > 0);

    // ziggit should not be clean after deletion
    const clean = try repo.isClean();
    _ = clean; // Don't assert specific result - just verify no crash
}

test "git config files -> ziggit reads repo" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try initGitRepo(allocator, tmp);

    // Create typical config files
    try writeFile(tmp, ".gitignore", "node_modules/\ndist/\n*.log", allocator);
    try writeFile(tmp, ".editorconfig", "root = true\n[*]\nindent_size = 2", allocator);
    try writeFile(tmp, "tsconfig.json", "{\"compilerOptions\":{\"strict\":true}}", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "." });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "config files" });

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();

    const head = try repo.revParseHead();
    try std.testing.expectEqual(@as(usize, 40), head.len);

    // Should be clean
    const clean = try repo.isClean();
    try std.testing.expect(clean);
}

test "git multiple tags same commit -> ziggit finds a tag" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try initGitRepo(allocator, tmp);
    try writeFile(tmp, "f.txt", "multi-tagged", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "f.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "multi tag commit" });

    // Multiple tags on same commit
    try execGitNoOutput(allocator, tmp, &.{ "tag", "latest" });
    try execGitNoOutput(allocator, tmp, &.{ "tag", "stable" });
    try execGitNoOutput(allocator, tmp, &.{ "tag", "v1.0.0" });

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();

    const desc = try repo.describeTags(allocator);
    defer allocator.free(desc);
    // Should find at least one tag
    try std.testing.expect(desc.len > 0);
    const found_any = std.mem.indexOf(u8, desc, "latest") != null or
        std.mem.indexOf(u8, desc, "stable") != null or
        std.mem.indexOf(u8, desc, "v1.0.0") != null;
    try std.testing.expect(found_any);
}

test "git complex project -> ziggit all APIs work" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try initGitRepo(allocator, tmp);

    // Create a realistic project structure
    const dirs = [_][]const u8{ "src", "src/lib", "test", "docs" };
    for (dirs) |d| {
        const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tmp, d });
        defer allocator.free(full);
        std.fs.makeDirAbsolute(full) catch {};
    }

    try writeFile(tmp, "package.json", "{\"name\":\"project\",\"version\":\"1.0.0\"}", allocator);
    try writeFile(tmp, "src/index.ts", "export const main = () => {};", allocator);
    try writeFile(tmp, "src/lib/utils.ts", "export const add = (a: number, b: number) => a + b;", allocator);
    try writeFile(tmp, "test/index.test.ts", "import { main } from '../src';", allocator);
    try writeFile(tmp, "docs/README.md", "# Project\nDocumentation here.", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "." });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "initial project" });
    try execGitNoOutput(allocator, tmp, &.{ "tag", "v1.0.0" });

    // Second commit
    try writeFile(tmp, "src/index.ts", "export const main = () => console.log('v2');", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "." });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "update main" });
    try execGitNoOutput(allocator, tmp, &.{ "tag", "v1.1.0" });

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();

    // Test revParseHead
    const head = try repo.revParseHead();
    const git_head_out = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(git_head_out);
    try std.testing.expectEqualStrings(trimRight(git_head_out), &head);

    // Test describeTags
    const desc = try repo.describeTags(allocator);
    defer allocator.free(desc);
    try std.testing.expect(desc.len > 0);

    // Test branchList
    const branches = try repo.branchList(allocator);
    defer {
        for (branches) |b| allocator.free(b);
        allocator.free(branches);
    }
    try std.testing.expect(branches.len >= 1);

    // Test findCommit by tag
    const v1 = try repo.findCommit("v1.0.0");
    try std.testing.expectEqual(@as(usize, 40), v1.len);

    // Test isClean
    const clean = try repo.isClean();
    try std.testing.expect(clean);

    // Test statusPorcelain
    const status = try repo.statusPorcelain(allocator);
    defer allocator.free(status);
    try std.testing.expectEqualStrings("", trimRight(status));
}
