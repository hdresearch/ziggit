// test/ziggit_writes_git_reads_test.zig
// Zig API creates repos, then verifies with git CLI
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
    const name = std.fmt.bufPrint(&buf, "{d}_{d}", .{ ts, rand_val }) catch unreachable;
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, name });
    std.fs.makeDirAbsolute(path) catch {};
    return path;
}

fn cleanupTmpDir(path: []const u8) void {
    std.fs.deleteTreeAbsolute(path) catch {};
}

test "ziggit init -> git recognizes repo" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    const out = try execGit(allocator, tmp, &.{ "rev-parse", "--git-dir" });
    defer allocator.free(out);
    try std.testing.expectEqualStrings(".git", trimRight(out));
}

test "ziggit add+commit -> git log shows commit" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    const file_path = try std.fmt.allocPrint(allocator, "{s}/hello.txt", .{tmp});
    defer allocator.free(file_path);
    {
        const f = try std.fs.createFileAbsolute(file_path, .{});
        defer f.close();
        try f.writeAll("hello from ziggit");
    }
    try repo.add("hello.txt");
    _ = try repo.commit("test commit from zig", "TestAuthor", "test@test.com");

    const log_out = try execGit(allocator, tmp, &.{ "log", "--oneline" });
    defer allocator.free(log_out);
    try std.testing.expect(std.mem.indexOf(u8, log_out, "test commit from zig") != null);

    const show_out = try execGit(allocator, tmp, &.{ "show", "HEAD:hello.txt" });
    defer allocator.free(show_out);
    try std.testing.expectEqualStrings("hello from ziggit", trimRight(show_out));
}

test "ziggit tag -> git tag -l" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    const file_path = try std.fmt.allocPrint(allocator, "{s}/f.txt", .{tmp});
    defer allocator.free(file_path);
    {
        const f = try std.fs.createFileAbsolute(file_path, .{});
        defer f.close();
        try f.writeAll("tagged");
    }
    try repo.add("f.txt");
    _ = try repo.commit("for tagging", "Test", "test@test.com");
    try repo.createTag("v3.0.0", null);

    const tags_out = try execGit(allocator, tmp, &.{ "tag", "-l" });
    defer allocator.free(tags_out);
    try std.testing.expect(std.mem.indexOf(u8, tags_out, "v3.0.0") != null);
}

test "ziggit commit -> git cat-file validates object" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    const file_path = try std.fmt.allocPrint(allocator, "{s}/data.txt", .{tmp});
    defer allocator.free(file_path);
    {
        const f = try std.fs.createFileAbsolute(file_path, .{});
        defer f.close();
        try f.writeAll("data");
    }
    try repo.add("data.txt");
    _ = try repo.commit("object test", "Author", "a@a.com");

    const type_out = try execGit(allocator, tmp, &.{ "cat-file", "-t", "HEAD" });
    defer allocator.free(type_out);
    try std.testing.expectEqualStrings("commit", trimRight(type_out));

    const content_out = try execGit(allocator, tmp, &.{ "cat-file", "-p", "HEAD" });
    defer allocator.free(content_out);
    try std.testing.expect(std.mem.indexOf(u8, content_out, "tree ") != null);
    try std.testing.expect(std.mem.indexOf(u8, content_out, "author Author") != null);
}

test "ziggit multiple commits -> git rev-list count" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    const file_path = try std.fmt.allocPrint(allocator, "{s}/f.txt", .{tmp});
    defer allocator.free(file_path);

    var i: usize = 0;
    while (i < 5) : (i += 1) {
        {
            const f = try std.fs.createFileAbsolute(file_path, .{ .truncate = true });
            defer f.close();
            var buf: [32]u8 = undefined;
            const content = std.fmt.bufPrint(&buf, "version {d}", .{i}) catch unreachable;
            try f.writeAll(content);
        }
        try repo.add("f.txt");
        var msg_buf: [32]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "commit {d}", .{i}) catch unreachable;
        _ = try repo.commit(msg, "Test", "t@t.com");
    }

    const count_out = try execGit(allocator, tmp, &.{ "rev-list", "--count", "HEAD" });
    defer allocator.free(count_out);
    try std.testing.expectEqualStrings("5", trimRight(count_out));
}

test "ziggit hash matches git hash" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    const file_path = try std.fmt.allocPrint(allocator, "{s}/h.txt", .{tmp});
    defer allocator.free(file_path);
    {
        const f = try std.fs.createFileAbsolute(file_path, .{});
        defer f.close();
        try f.writeAll("hash test");
    }
    try repo.add("h.txt");
    const ziggit_hash = try repo.commit("hash test", "Test", "t@t.com");

    const git_out = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(git_out);

    try std.testing.expectEqualStrings(&ziggit_hash, trimRight(git_out));
}

test "ziggit nested dirs -> git reads deep files" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    // Create nested structure
    const dir_a = try std.fmt.allocPrint(allocator, "{s}/a", .{tmp});
    defer allocator.free(dir_a);
    const dir_ab = try std.fmt.allocPrint(allocator, "{s}/a/b", .{tmp});
    defer allocator.free(dir_ab);
    const dir_abc = try std.fmt.allocPrint(allocator, "{s}/a/b/c", .{tmp});
    defer allocator.free(dir_abc);

    try std.fs.makeDirAbsolute(dir_a);
    try std.fs.makeDirAbsolute(dir_ab);
    try std.fs.makeDirAbsolute(dir_abc);

    const file_path = try std.fmt.allocPrint(allocator, "{s}/a/b/c/deep.txt", .{tmp});
    defer allocator.free(file_path);
    {
        const f = try std.fs.createFileAbsolute(file_path, .{});
        defer f.close();
        try f.writeAll("deep content");
    }
    try repo.add("a/b/c/deep.txt");
    _ = try repo.commit("nested", "Test", "t@t.com");

    const show_out = try execGit(allocator, tmp, &.{ "show", "HEAD:a/b/c/deep.txt" });
    defer allocator.free(show_out);
    try std.testing.expectEqualStrings("deep content", trimRight(show_out));
}

test "ziggit binary file -> git preserves content" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    const file_path = try std.fmt.allocPrint(allocator, "{s}/bin.dat", .{tmp});
    defer allocator.free(file_path);
    {
        const f = try std.fs.createFileAbsolute(file_path, .{});
        defer f.close();
        try f.writeAll(&[_]u8{ 0x00, 0x01, 0x02, 0xFF, 0xFE, 0xFD, 0x80, 0x7F });
    }
    try repo.add("bin.dat");
    _ = try repo.commit("binary", "Test", "t@t.com");

    const show_out = try execGit(allocator, tmp, &.{ "cat-file", "blob", "HEAD:bin.dat" });
    defer allocator.free(show_out);
    try std.testing.expectEqual(@as(usize, 8), show_out.len);
    try std.testing.expectEqual(@as(u8, 0x00), show_out[0]);
    try std.testing.expectEqual(@as(u8, 0xFF), show_out[3]);
}

test "bun workflow: init, add package.json, commit, tag, describe" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    const pkg_path = try std.fmt.allocPrint(allocator, "{s}/package.json", .{tmp});
    defer allocator.free(pkg_path);
    {
        const f = try std.fs.createFileAbsolute(pkg_path, .{});
        defer f.close();
        try f.writeAll(
            \\{"name":"test-pkg","version":"1.0.0"}
        );
    }

    try repo.add("package.json");
    _ = try repo.commit("Initial commit", "bun", "bun@bun.sh");
    try repo.createTag("v1.0.0", null);

    const describe = try execGit(allocator, tmp, &.{ "describe", "--tags" });
    defer allocator.free(describe);
    try std.testing.expectEqualStrings("v1.0.0", trimRight(describe));

    const show = try execGit(allocator, tmp, &.{ "show", "HEAD:package.json" });
    defer allocator.free(show);
    try std.testing.expect(std.mem.indexOf(u8, show, "test-pkg") != null);

    const status = try execGit(allocator, tmp, &.{ "status", "--porcelain" });
    defer allocator.free(status);
    try std.testing.expectEqualStrings("", trimRight(status));
}
