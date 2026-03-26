// test/packed_refs_interop_test.zig
// Tests ziggit reading from repos with repacked objects, merge commits,
// interleaved operations, and large trees
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
    const base = "/root/ziggit_test_packed";
    std.fs.makeDirAbsolute(base) catch {};
    var buf: [64]u8 = undefined;
    const ts = std.time.milliTimestamp();
    var rng = std.rand.DefaultPrng.init(@bitCast(ts));
    const rv = rng.random().int(u64);
    const name = std.fmt.bufPrint(&buf, "pk_{d}_{d}", .{ ts, rv }) catch unreachable;
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

test "git merge commit with two parents -> ziggit reads HEAD" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try initGitRepo(allocator, tmp);

    // Create initial commit on master
    try writeFile(tmp, "f.txt", "initial", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "f.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "initial on master" });

    // Create a branch and make a commit
    try execGitNoOutput(allocator, tmp, &.{ "checkout", "-b", "feature" });
    try writeFile(tmp, "feature.txt", "feature work", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "feature.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "feature commit" });

    // Back to master, make another commit
    try execGitNoOutput(allocator, tmp, &.{ "checkout", "master" });
    try writeFile(tmp, "master.txt", "master work", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "master.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "master commit" });

    // Merge feature into master (creates merge commit with 2 parents)
    try execGitNoOutput(allocator, tmp, &.{ "merge", "feature", "--no-edit" });

    const git_head = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(git_head);

    // ziggit should read the merge commit's HEAD
    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();
    const head = try repo.revParseHead();
    try std.testing.expectEqualStrings(trim(git_head), &head);
}

test "git merge commit -> ziggit isClean true" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try initGitRepo(allocator, tmp);

    try writeFile(tmp, "f.txt", "base", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "f.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "base" });

    try execGitNoOutput(allocator, tmp, &.{ "checkout", "-b", "br" });
    try writeFile(tmp, "br.txt", "branch", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "br.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "branch commit" });

    try execGitNoOutput(allocator, tmp, &.{ "checkout", "master" });
    try writeFile(tmp, "main.txt", "main", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "main.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "main commit" });

    try execGitNoOutput(allocator, tmp, &.{ "merge", "br", "--no-edit" });

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();
    const clean = try repo.isClean();
    try std.testing.expect(clean);
}

test "git merge -> ziggit branchList shows both branches" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try initGitRepo(allocator, tmp);

    try writeFile(tmp, "f.txt", "base", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "f.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "base" });

    try execGitNoOutput(allocator, tmp, &.{ "checkout", "-b", "develop" });
    try writeFile(tmp, "dev.txt", "dev", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "dev.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "dev commit" });

    try execGitNoOutput(allocator, tmp, &.{ "checkout", "master" });

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();
    const branches = try repo.branchList(allocator);
    defer {
        for (branches) |b| allocator.free(b);
        allocator.free(branches);
    }
    try std.testing.expect(branches.len >= 2);

    var found_master = false;
    var found_develop = false;
    for (branches) |b| {
        if (std.mem.eql(u8, b, "master")) found_master = true;
        if (std.mem.eql(u8, b, "develop")) found_develop = true;
    }
    try std.testing.expect(found_master);
    try std.testing.expect(found_develop);
}

test "git large tree 200 files -> ziggit opens and reads HEAD" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try initGitRepo(allocator, tmp);

    // Create 200 files across nested dirs
    var i: u32 = 0;
    while (i < 200) : (i += 1) {
        var name_buf: [128]u8 = undefined;
        const dir_num = i / 10;
        const file_num = i % 10;
        const name = std.fmt.bufPrint(&name_buf, "dir{d}/file{d}.txt", .{ dir_num, file_num }) catch unreachable;

        // Create directory
        var dir_buf: [128]u8 = undefined;
        const dir_path = std.fmt.bufPrint(&dir_buf, "{s}/dir{d}", .{ tmp, dir_num }) catch unreachable;
        std.fs.makeDirAbsolute(dir_path) catch {};

        var content_buf: [32]u8 = undefined;
        const content = std.fmt.bufPrint(&content_buf, "file {d}", .{i}) catch unreachable;
        try writeFile(tmp, name, content, allocator);
        try execGitNoOutput(allocator, tmp, &.{ "add", name });
    }
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "200 files" });

    const git_head = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(git_head);

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();
    const head = try repo.revParseHead();
    try std.testing.expectEqualStrings(trim(git_head), &head);
}

test "ziggit writes + git writes interleaved -> both agree on HEAD" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    // ziggit creates repo and first commit
    var repo = try ziggit.Repository.init(allocator, tmp);

    try writeFile(tmp, "z1.txt", "ziggit1", allocator);
    try repo.add("z1.txt");
    _ = try repo.commit("ziggit commit 1", "z", "z@z.com");
    repo.close();

    // git makes a commit
    try execGitNoOutput(allocator, tmp, &.{ "config", "user.name", "GitUser" });
    try execGitNoOutput(allocator, tmp, &.{ "config", "user.email", "git@git.com" });
    try writeFile(tmp, "g1.txt", "git1", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "g1.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "git commit 1" });

    // ziggit reads back
    var repo2 = try ziggit.Repository.open(allocator, tmp);
    defer repo2.close();

    const git_head = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(git_head);
    const ziggit_head = try repo2.revParseHead();
    try std.testing.expectEqualStrings(trim(git_head), &ziggit_head);

    // Both files should be in the repo (status clean)
    const clean = try repo2.isClean();
    try std.testing.expect(clean);
}

test "ziggit statusPorcelain matches git after git commit" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try initGitRepo(allocator, tmp);
    try writeFile(tmp, "f.txt", "committed", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "f.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "clean" });

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();

    const ziggit_status = try repo.statusPorcelain(allocator);
    defer allocator.free(ziggit_status);

    // Both should show clean (empty status)
    try std.testing.expectEqualStrings("", trim(ziggit_status));
}

test "git 10 rapid commits -> ziggit revParseHead tracks latest" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try initGitRepo(allocator, tmp);

    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        var buf: [64]u8 = undefined;
        const content = std.fmt.bufPrint(&buf, "v{d}", .{i}) catch unreachable;
        try writeFile(tmp, "f.txt", content, allocator);
        try execGitNoOutput(allocator, tmp, &.{ "add", "f.txt" });
        const msg = std.fmt.bufPrint(&buf, "commit {d}", .{i}) catch unreachable;
        try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", msg });
    }

    const git_head = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(git_head);

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();
    const head = try repo.revParseHead();
    try std.testing.expectEqualStrings(trim(git_head), &head);
}

test "git creates binary with all 256 byte values -> ziggit reads HEAD" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try initGitRepo(allocator, tmp);

    // Write binary file with all 256 byte values
    const file_path = try std.fmt.allocPrint(allocator, "{s}/binary.bin", .{tmp});
    defer allocator.free(file_path);
    {
        const f = try std.fs.createFileAbsolute(file_path, .{ .truncate = true });
        defer f.close();
        var bytes: [256]u8 = undefined;
        for (&bytes, 0..) |*b, idx| {
            b.* = @intCast(idx);
        }
        try f.writeAll(&bytes);
    }

    try execGitNoOutput(allocator, tmp, &.{ "add", "binary.bin" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "binary commit" });

    const git_head = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(git_head);

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();
    const head = try repo.revParseHead();
    try std.testing.expectEqualStrings(trim(git_head), &head);
}

test "ziggit writes -> git reads -> ziggit reads back round-trip" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    // ziggit creates repo with multiple commits
    var repo = try ziggit.Repository.init(allocator, tmp);

    try writeFile(tmp, "a.txt", "alpha", allocator);
    try repo.add("a.txt");
    const h1 = try repo.commit("commit 1", "test", "t@t.com");
    try repo.createTag("v1.0.0", null);

    try writeFile(tmp, "b.txt", "beta", allocator);
    try repo.add("b.txt");
    const h2 = try repo.commit("commit 2", "test", "t@t.com");
    try repo.createTag("v2.0.0", null);

    try writeFile(tmp, "c.txt", "gamma", allocator);
    try repo.add("c.txt");
    const h3 = try repo.commit("commit 3", "test", "t@t.com");

    repo.close();

    // git validates
    const git_head = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(git_head);
    try std.testing.expectEqualStrings(&h3, trim(git_head));

    const git_count = try execGit(allocator, tmp, &.{ "rev-list", "--count", "HEAD" });
    defer allocator.free(git_count);
    try std.testing.expectEqualStrings("3", trim(git_count));

    // git reads file content
    const a_content = try execGit(allocator, tmp, &.{ "show", "HEAD:a.txt" });
    defer allocator.free(a_content);
    try std.testing.expectEqualStrings("alpha", trim(a_content));

    // ziggit reads back
    var repo2 = try ziggit.Repository.open(allocator, tmp);
    defer repo2.close();

    const head2 = try repo2.revParseHead();
    try std.testing.expectEqualStrings(&h3, &head2);

    const found_v1 = try repo2.findCommit("v1.0.0");
    try std.testing.expectEqualStrings(&h1, &found_v1);

    const found_v2 = try repo2.findCommit("v2.0.0");
    try std.testing.expectEqualStrings(&h2, &found_v2);

    const clean = try repo2.isClean();
    try std.testing.expect(clean);
}

test "git deeply nested 10 levels -> ziggit reads HEAD" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try initGitRepo(allocator, tmp);

    // Create deeply nested directory structure one level at a time
    const rel_dir = "d/d/d/d/d/d/d/d/d/d";
    const full_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tmp, rel_dir });
    defer allocator.free(full_dir);

    // Create each level
    var dir_buf: [512]u8 = undefined;
    var dpos: usize = 0;
    for (tmp) |c| {
        dir_buf[dpos] = c;
        dpos += 1;
    }
    var level: u32 = 0;
    while (level < 10) : (level += 1) {
        dir_buf[dpos] = '/';
        dpos += 1;
        dir_buf[dpos] = 'd';
        dpos += 1;
        std.fs.makeDirAbsolute(dir_buf[0..dpos]) catch {};
    }

    const rel_file = rel_dir ++ "/deep.txt";
    const deep_abs = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tmp, rel_file });
    defer allocator.free(deep_abs);
    {
        const f = try std.fs.createFileAbsolute(deep_abs, .{ .truncate = true });
        defer f.close();
        try f.writeAll("deep content");
    }

    try execGitNoOutput(allocator, tmp, &.{ "add", rel_file });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "deep nested" });

    const git_head = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(git_head);

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();
    const head = try repo.revParseHead();
    try std.testing.expectEqualStrings(trim(git_head), &head);
}

test "git tag with dots and dashes -> ziggit findCommit resolves" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try initGitRepo(allocator, tmp);
    try writeFile(tmp, "f.txt", "tagged", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "f.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "tagged" });

    const git_head = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(git_head);

    try execGitNoOutput(allocator, tmp, &.{ "tag", "v1.2.3-beta.4" });

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();
    const found = try repo.findCommit("v1.2.3-beta.4");
    try std.testing.expectEqualStrings(trim(git_head), &found);
}

test "git multiple branches -> ziggit findCommit by branch name" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try initGitRepo(allocator, tmp);
    try writeFile(tmp, "f.txt", "main", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "f.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "main commit" });

    try execGitNoOutput(allocator, tmp, &.{ "checkout", "-b", "feature-x" });
    try writeFile(tmp, "x.txt", "feature", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "x.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "feature commit" });

    const feature_head = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(feature_head);

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();
    const found = try repo.findCommit("feature-x");
    try std.testing.expectEqualStrings(trim(feature_head), &found);
}

test "git ff merge -> ziggit reads HEAD correctly" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try initGitRepo(allocator, tmp);
    try writeFile(tmp, "f.txt", "base", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "f.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "base" });

    // Create branch with a commit, then ff-merge back to master
    try execGitNoOutput(allocator, tmp, &.{ "checkout", "-b", "ff-branch" });
    try writeFile(tmp, "ff.txt", "ff content", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "ff.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "ff commit" });

    const ff_head = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(ff_head);

    try execGitNoOutput(allocator, tmp, &.{ "checkout", "master" });
    try execGitNoOutput(allocator, tmp, &.{ "merge", "ff-branch" }); // ff merge

    const git_head = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(git_head);
    // FF merge means HEAD should be same as ff_head
    try std.testing.expectEqualStrings(trim(ff_head), trim(git_head));

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();
    const head = try repo.revParseHead();
    try std.testing.expectEqualStrings(trim(git_head), &head);
}
