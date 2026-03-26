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
