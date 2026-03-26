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

test "ziggit statusPorcelain clean matches git" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    const file_path = try std.fmt.allocPrint(allocator, "{s}/tracked.txt", .{tmp});
    defer allocator.free(file_path);
    {
        const f = try std.fs.createFileAbsolute(file_path, .{});
        defer f.close();
        try f.writeAll("tracked content");
    }
    try repo.add("tracked.txt");
    _ = try repo.commit("base", "Test", "t@t.com");

    const status = try repo.statusPorcelain(allocator);
    defer allocator.free(status);

    const git_status = try execGit(allocator, tmp, &.{ "status", "--porcelain" });
    defer allocator.free(git_status);

    // Both should be empty (clean)
    try std.testing.expectEqualStrings("", trimRight(status));
    try std.testing.expectEqualStrings("", trimRight(git_status));
}

test "ziggit isClean true after commit" {
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
        try f.writeAll("clean check");
    }
    try repo.add("f.txt");
    _ = try repo.commit("clean test", "Test", "t@t.com");

    const clean = try repo.isClean();
    try std.testing.expect(clean);
}

test "ziggit multiple tags -> git sees all" {
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

    // First commit + tag
    {
        const f = try std.fs.createFileAbsolute(file_path, .{});
        defer f.close();
        try f.writeAll("v1");
    }
    try repo.add("f.txt");
    _ = try repo.commit("release 1", "Test", "t@t.com");
    try repo.createTag("v1.0.0", null);

    // Second commit + tag
    {
        const f = try std.fs.createFileAbsolute(file_path, .{ .truncate = true });
        defer f.close();
        try f.writeAll("v2");
    }
    try repo.add("f.txt");
    _ = try repo.commit("release 2", "Test", "t@t.com");
    try repo.createTag("v2.0.0", null);

    const tags_out = try execGit(allocator, tmp, &.{ "tag", "-l" });
    defer allocator.free(tags_out);
    try std.testing.expect(std.mem.indexOf(u8, tags_out, "v1.0.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, tags_out, "v2.0.0") != null);
}

test "ziggit 5 commits + tag -> git reads full history" {
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
    try repo.createTag("v1.0.0", null);

    // Verify commit count
    const count_out = try execGit(allocator, tmp, &.{ "rev-list", "--count", "HEAD" });
    defer allocator.free(count_out);
    try std.testing.expectEqualStrings("5", trimRight(count_out));

    // Verify tag exists
    const tag_out = try execGit(allocator, tmp, &.{ "tag", "-l" });
    defer allocator.free(tag_out);
    try std.testing.expect(std.mem.indexOf(u8, tag_out, "v1.0.0") != null);

    // Verify all commit objects are valid
    const log_out = try execGit(allocator, tmp, &.{ "log", "--oneline" });
    defer allocator.free(log_out);
    try std.testing.expect(std.mem.indexOf(u8, log_out, "commit 4") != null);
    try std.testing.expect(std.mem.indexOf(u8, log_out, "commit 0") != null);
}

test "ziggit special char filenames -> git reads" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    const names = [_][]const u8{ "hello-world.txt", "under_score.txt", "CamelCase.TXT" };
    for (names) |name| {
        const fp = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tmp, name });
        defer allocator.free(fp);
        const f = try std.fs.createFileAbsolute(fp, .{});
        defer f.close();
        try f.writeAll(name);
        try repo.add(name);
    }
    _ = try repo.commit("special chars", "Test", "t@t.com");

    const ls_out = try execGit(allocator, tmp, &.{ "ls-tree", "--name-only", "HEAD" });
    defer allocator.free(ls_out);
    for (names) |name| {
        try std.testing.expect(std.mem.indexOf(u8, ls_out, name) != null);
    }
}

test "ziggit describe after commits past tag" {
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
    _ = try repo.commit("tagged commit", "Test", "t@t.com");
    try repo.createTag("v1.0.0", null);

    // Extra commit past tag
    {
        const f = try std.fs.createFileAbsolute(file_path, .{ .truncate = true });
        defer f.close();
        try f.writeAll("past tag");
    }
    try repo.add("f.txt");
    _ = try repo.commit("past tag", "Test", "t@t.com");

    // git describe should show v1.0.0-1-g<hash>
    const desc = try execGit(allocator, tmp, &.{ "describe", "--tags" });
    defer allocator.free(desc);
    try std.testing.expect(std.mem.startsWith(u8, trimRight(desc), "v1.0.0-1-g"));
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

test "ziggit 100+ files -> git sees all" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    var i: usize = 0;
    while (i < 120) : (i += 1) {
        var name_buf: [64]u8 = undefined;
        const fname = std.fmt.bufPrint(&name_buf, "file_{d:0>3}.txt", .{i}) catch unreachable;
        const fp = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tmp, fname });
        defer allocator.free(fp);
        {
            const f = try std.fs.createFileAbsolute(fp, .{});
            defer f.close();
            var content_buf: [32]u8 = undefined;
            const content = std.fmt.bufPrint(&content_buf, "content {d}", .{i}) catch unreachable;
            try f.writeAll(content);
        }
        try repo.add(fname);
    }
    _ = try repo.commit("120 files", "Test", "t@t.com");

    const count_out = try execGit(allocator, tmp, &.{ "ls-tree", "--name-only", "HEAD" });
    defer allocator.free(count_out);
    var line_count: usize = 0;
    var iter = std.mem.splitScalar(u8, trimRight(count_out), '\n');
    while (iter.next()) |_| line_count += 1;
    try std.testing.expectEqual(@as(usize, 120), line_count);
}

test "ziggit annotated tag -> git verifies tag object" {
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
        try f.writeAll("annotated");
    }
    try repo.add("f.txt");
    _ = try repo.commit("for annotated", "Test", "t@t.com");
    try repo.createTag("v4.0.0", "Release v4.0.0");

    // git should see annotated tag
    const tag_type = try execGit(allocator, tmp, &.{ "cat-file", "-t", "v4.0.0" });
    defer allocator.free(tag_type);
    try std.testing.expectEqualStrings("tag", trimRight(tag_type));

    const tag_content = try execGit(allocator, tmp, &.{ "cat-file", "-p", "v4.0.0" });
    defer allocator.free(tag_content);
    try std.testing.expect(std.mem.indexOf(u8, tag_content, "Release v4.0.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, tag_content, "tag v4.0.0") != null);
}

test "ziggit repo -> git fsck validates integrity" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    // Multiple commits with different files
    const names = [_][]const u8{ "a.txt", "b.txt", "c.txt" };
    for (names, 0..) |name, i| {
        const fp = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tmp, name });
        defer allocator.free(fp);
        {
            const f = try std.fs.createFileAbsolute(fp, .{});
            defer f.close();
            var buf: [32]u8 = undefined;
            const content = std.fmt.bufPrint(&buf, "content {d}", .{i}) catch unreachable;
            try f.writeAll(content);
        }
        try repo.add(name);
        var msg_buf: [32]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "add {s}", .{name}) catch unreachable;
        _ = try repo.commit(msg, "Test", "t@t.com");
    }
    try repo.createTag("v1.0.0", null);

    // git fsck should pass with no errors
    const fsck_out = try execGit(allocator, tmp, &.{ "fsck", "--no-dangling" });
    defer allocator.free(fsck_out);
    // fsck should not contain "error" or "corrupt"
    try std.testing.expect(std.mem.indexOf(u8, fsck_out, "error") == null);
    try std.testing.expect(std.mem.indexOf(u8, fsck_out, "corrupt") == null);
}

test "ziggit init -> git status shows empty repo" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    // git rev-parse --git-dir should work
    const git_dir = try execGit(allocator, tmp, &.{ "rev-parse", "--git-dir" });
    defer allocator.free(git_dir);
    try std.testing.expectEqualStrings(".git", trimRight(git_dir));

    // git status --porcelain should be empty (no files, no commits)
    const status = try execGit(allocator, tmp, &.{ "status", "--porcelain" });
    defer allocator.free(status);
    try std.testing.expectEqualStrings("", trimRight(status));
}

test "ziggit empty content file -> git reads" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    const file_path = try std.fmt.allocPrint(allocator, "{s}/empty.txt", .{tmp});
    defer allocator.free(file_path);
    {
        const f = try std.fs.createFileAbsolute(file_path, .{});
        f.close();
    }
    try repo.add("empty.txt");
    _ = try repo.commit("empty file", "Test", "t@t.com");

    const show_out = try execGit(allocator, tmp, &.{ "show", "HEAD:empty.txt" });
    defer allocator.free(show_out);
    try std.testing.expectEqualStrings("", show_out);
}

test "ziggit large binary -> git preserves exact bytes" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    // Create 4KB binary with all byte values
    const file_path = try std.fmt.allocPrint(allocator, "{s}/binary.dat", .{tmp});
    defer allocator.free(file_path);
    {
        const f = try std.fs.createFileAbsolute(file_path, .{});
        defer f.close();
        var data: [4096]u8 = undefined;
        for (&data, 0..) |*b, idx| {
            b.* = @intCast(idx % 256);
        }
        try f.writeAll(&data);
    }
    try repo.add("binary.dat");
    _ = try repo.commit("big binary", "Test", "t@t.com");

    const show_out = try execGit(allocator, tmp, &.{ "cat-file", "blob", "HEAD:binary.dat" });
    defer allocator.free(show_out);
    try std.testing.expectEqual(@as(usize, 4096), show_out.len);
    // Verify first and last bytes
    try std.testing.expectEqual(@as(u8, 0), show_out[0]);
    try std.testing.expectEqual(@as(u8, 255), show_out[255]);
    try std.testing.expectEqual(@as(u8, 0), show_out[256]);
}

test "ziggit two separate files in two commits -> git sees both" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    // First commit: file a
    const file_a = try std.fmt.allocPrint(allocator, "{s}/a.txt", .{tmp});
    defer allocator.free(file_a);
    {
        const f = try std.fs.createFileAbsolute(file_a, .{});
        defer f.close();
        try f.writeAll("content a");
    }
    try repo.add("a.txt");
    _ = try repo.commit("add a", "Test", "t@t.com");

    // Second commit: file b
    const file_b = try std.fmt.allocPrint(allocator, "{s}/b.txt", .{tmp});
    defer allocator.free(file_b);
    {
        const f = try std.fs.createFileAbsolute(file_b, .{});
        defer f.close();
        try f.writeAll("content b");
    }
    try repo.add("b.txt");
    _ = try repo.commit("add b", "Test", "t@t.com");

    // Both files should be visible
    const show_a = try execGit(allocator, tmp, &.{ "show", "HEAD:a.txt" });
    defer allocator.free(show_a);
    try std.testing.expectEqualStrings("content a", trimRight(show_a));

    const show_b = try execGit(allocator, tmp, &.{ "show", "HEAD:b.txt" });
    defer allocator.free(show_b);
    try std.testing.expectEqualStrings("content b", trimRight(show_b));

    // Two commits in history
    const count = try execGit(allocator, tmp, &.{ "rev-list", "--count", "HEAD" });
    defer allocator.free(count);
    try std.testing.expectEqualStrings("2", trimRight(count));
}

test "bun workflow: lockfile and nested deps" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    // Simulate bun install output
    const pkg_path = try std.fmt.allocPrint(allocator, "{s}/package.json", .{tmp});
    defer allocator.free(pkg_path);
    {
        const f = try std.fs.createFileAbsolute(pkg_path, .{});
        defer f.close();
        try f.writeAll("{\"name\":\"app\",\"version\":\"2.0.0\",\"dependencies\":{\"lodash\":\"^4.0.0\"}}");
    }

    const lock_path = try std.fmt.allocPrint(allocator, "{s}/bun.lockb", .{tmp});
    defer allocator.free(lock_path);
    {
        const f = try std.fs.createFileAbsolute(lock_path, .{});
        defer f.close();
        // Simulate binary lockfile
        try f.writeAll(&[_]u8{ 0xBE, 0xEF, 0x00, 0x01, 0x02, 0x03, 0xFF, 0xFE });
    }

    try repo.add("package.json");
    try repo.add("bun.lockb");
    _ = try repo.commit("bun install", "bun", "bun@bun.sh");
    try repo.createTag("v2.0.0", null);

    // Verify both files via git
    const pkg_show = try execGit(allocator, tmp, &.{ "show", "HEAD:package.json" });
    defer allocator.free(pkg_show);
    try std.testing.expect(std.mem.indexOf(u8, pkg_show, "lodash") != null);

    const lock_show = try execGit(allocator, tmp, &.{ "cat-file", "blob", "HEAD:bun.lockb" });
    defer allocator.free(lock_show);
    try std.testing.expectEqual(@as(usize, 8), lock_show.len);
    try std.testing.expectEqual(@as(u8, 0xBE), lock_show[0]);

    const desc = try execGit(allocator, tmp, &.{ "describe", "--tags" });
    defer allocator.free(desc);
    try std.testing.expectEqualStrings("v2.0.0", trimRight(desc));
}

test "ziggit checkout -> git verifies HEAD" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    // First commit
    const file_path = try std.fmt.allocPrint(allocator, "{s}/f.txt", .{tmp});
    defer allocator.free(file_path);
    {
        const f = try std.fs.createFileAbsolute(file_path, .{});
        defer f.close();
        try f.writeAll("version 1");
    }
    try repo.add("f.txt");
    const hash1 = try repo.commit("first", "Test", "t@t.com");
    try repo.createTag("v1.0.0", null);

    // Second commit
    {
        const f = try std.fs.createFileAbsolute(file_path, .{ .truncate = true });
        defer f.close();
        try f.writeAll("version 2");
    }
    try repo.add("f.txt");
    _ = try repo.commit("second", "Test", "t@t.com");

    // Checkout back to first commit
    try repo.checkout("v1.0.0");

    // Verify HEAD points to first commit
    const git_head = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(git_head);
    try std.testing.expectEqualStrings(&hash1, trimRight(git_head));

    // Verify file content is version 1
    const show_out = try execGit(allocator, tmp, &.{ "show", "HEAD:f.txt" });
    defer allocator.free(show_out);
    try std.testing.expectEqualStrings("version 1", trimRight(show_out));
}

test "ziggit cloneNoCheckout -> git reads cloned repo" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    // Create source repo
    const src_path = try std.fmt.allocPrint(allocator, "{s}/source", .{tmp});
    defer allocator.free(src_path);
    try std.fs.makeDirAbsolute(src_path);

    var src_repo = try ziggit.Repository.init(allocator, src_path);

    const file_path = try std.fmt.allocPrint(allocator, "{s}/hello.txt", .{src_path});
    defer allocator.free(file_path);
    {
        const f = try std.fs.createFileAbsolute(file_path, .{});
        defer f.close();
        try f.writeAll("cloned content");
    }
    try src_repo.add("hello.txt");
    const src_hash = try src_repo.commit("source commit", "Test", "t@t.com");
    try src_repo.createTag("v1.0.0", null);
    src_repo.close();

    // Clone
    const dst_path = try std.fmt.allocPrint(allocator, "{s}/dest", .{tmp});
    defer allocator.free(dst_path);
    var dst_repo = try ziggit.Repository.cloneNoCheckout(allocator, src_path, dst_path);
    dst_repo.close();

    // Verify clone with git
    const git_head = try execGit(allocator, dst_path, &.{ "rev-parse", "HEAD" });
    defer allocator.free(git_head);
    try std.testing.expectEqualStrings(&src_hash, trimRight(git_head));

    const git_tags = try execGit(allocator, dst_path, &.{ "tag", "-l" });
    defer allocator.free(git_tags);
    try std.testing.expect(std.mem.indexOf(u8, git_tags, "v1.0.0") != null);
}

test "ziggit cloneBare -> git reads bare repo" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    // Create source repo
    const src_path = try std.fmt.allocPrint(allocator, "{s}/source", .{tmp});
    defer allocator.free(src_path);
    try std.fs.makeDirAbsolute(src_path);

    var src_repo = try ziggit.Repository.init(allocator, src_path);

    const file_path = try std.fmt.allocPrint(allocator, "{s}/data.txt", .{src_path});
    defer allocator.free(file_path);
    {
        const f = try std.fs.createFileAbsolute(file_path, .{});
        defer f.close();
        try f.writeAll("bare clone data");
    }
    try src_repo.add("data.txt");
    const src_hash = try src_repo.commit("bare source", "Test", "t@t.com");
    src_repo.close();

    // Clone bare
    const bare_path = try std.fmt.allocPrint(allocator, "{s}/bare.git", .{tmp});
    defer allocator.free(bare_path);
    var bare_repo = try ziggit.Repository.cloneBare(allocator, src_path, bare_path);
    bare_repo.close();

    // Verify bare repo with git
    const git_head = try execGit(allocator, bare_path, &.{ "rev-parse", "HEAD" });
    defer allocator.free(git_head);
    try std.testing.expectEqualStrings(&src_hash, trimRight(git_head));

    // Verify it's a valid commit object
    const cat_type = try execGit(allocator, bare_path, &.{ "cat-file", "-t", "HEAD" });
    defer allocator.free(cat_type);
    try std.testing.expectEqualStrings("commit", trimRight(cat_type));
}

test "ziggit overwrite file -> git sees commits in history" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    const file_path = try std.fmt.allocPrint(allocator, "{s}/config.json", .{tmp});
    defer allocator.free(file_path);

    // Write v1
    {
        const f = try std.fs.createFileAbsolute(file_path, .{});
        defer f.close();
        try f.writeAll("{\"version\":1}");
    }
    try repo.add("config.json");
    _ = try repo.commit("v1", "Test", "t@t.com");

    // Overwrite with v2
    {
        const f = try std.fs.createFileAbsolute(file_path, .{ .truncate = true });
        defer f.close();
        try f.writeAll("{\"version\":2}");
    }
    try repo.add("config.json");
    _ = try repo.commit("v2", "Test", "t@t.com");

    // Overwrite with v3
    {
        const f = try std.fs.createFileAbsolute(file_path, .{ .truncate = true });
        defer f.close();
        try f.writeAll("{\"version\":3}");
    }
    try repo.add("config.json");
    _ = try repo.commit("v3", "Test", "t@t.com");

    // git should see 3 valid commits
    const count = try execGit(allocator, tmp, &.{ "rev-list", "--count", "HEAD" });
    defer allocator.free(count);
    try std.testing.expectEqualStrings("3", trimRight(count));

    // git should be able to read the file at HEAD
    const show_head = try execGit(allocator, tmp, &.{ "show", "HEAD:config.json" });
    defer allocator.free(show_head);
    try std.testing.expect(show_head.len > 0);

    // Verify object type is valid
    const cat_type = try execGit(allocator, tmp, &.{ "cat-file", "-t", "HEAD" });
    defer allocator.free(cat_type);
    try std.testing.expectEqualStrings("commit", trimRight(cat_type));
}

test "ziggit deeply nested 10 levels -> git reads" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    // Create 10 levels deep
    const levels = [_][]const u8{ "l1", "l1/l2", "l1/l2/l3", "l1/l2/l3/l4", "l1/l2/l3/l4/l5", "l1/l2/l3/l4/l5/l6", "l1/l2/l3/l4/l5/l6/l7", "l1/l2/l3/l4/l5/l6/l7/l8", "l1/l2/l3/l4/l5/l6/l7/l8/l9", "l1/l2/l3/l4/l5/l6/l7/l8/l9/l10" };

    for (levels) |level| {
        const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tmp, level });
        defer allocator.free(full);
        std.fs.makeDirAbsolute(full) catch {};
    }

    const deep_file = try std.fmt.allocPrint(allocator, "{s}/l1/l2/l3/l4/l5/l6/l7/l8/l9/l10/bottom.txt", .{tmp});
    defer allocator.free(deep_file);
    {
        const f = try std.fs.createFileAbsolute(deep_file, .{});
        defer f.close();
        try f.writeAll("bottom of the tree");
    }
    try repo.add("l1/l2/l3/l4/l5/l6/l7/l8/l9/l10/bottom.txt");
    _ = try repo.commit("deep tree", "Test", "t@t.com");

    const show_out = try execGit(allocator, tmp, &.{ "show", "HEAD:l1/l2/l3/l4/l5/l6/l7/l8/l9/l10/bottom.txt" });
    defer allocator.free(show_out);
    try std.testing.expectEqualStrings("bottom of the tree", trimRight(show_out));
}

test "ziggit multiple files same commit -> git ls-tree sorted" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    // Add files in reverse alphabetical order
    const names = [_][]const u8{ "zebra.txt", "monkey.txt", "apple.txt" };
    for (names) |name| {
        const fp = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tmp, name });
        defer allocator.free(fp);
        const f = try std.fs.createFileAbsolute(fp, .{});
        defer f.close();
        try f.writeAll(name);
        try repo.add(name);
    }
    _ = try repo.commit("unsorted add", "Test", "t@t.com");

    // git ls-tree should list all files (git sorts them)
    const ls_out = try execGit(allocator, tmp, &.{ "ls-tree", "--name-only", "HEAD" });
    defer allocator.free(ls_out);

    // Verify all present
    for (names) |name| {
        try std.testing.expect(std.mem.indexOf(u8, ls_out, name) != null);
    }

    // Count files - should be exactly 3
    var line_count: usize = 0;
    var iter = std.mem.splitScalar(u8, trimRight(ls_out), '\n');
    while (iter.next()) |_| line_count += 1;
    try std.testing.expectEqual(@as(usize, 3), line_count);
}

test "ziggit commit with unicode message -> git reads" {
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
        try f.writeAll("unicode test");
    }
    try repo.add("f.txt");
    _ = try repo.commit("feat: add emoji support \xf0\x9f\x9a\x80", "Test", "t@t.com");

    const log_out = try execGit(allocator, tmp, &.{ "log", "--oneline" });
    defer allocator.free(log_out);
    try std.testing.expect(std.mem.indexOf(u8, log_out, "\xf0\x9f\x9a\x80") != null);
}

test "ziggit multiline commit message -> git reads" {
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
        try f.writeAll("multiline msg");
    }
    try repo.add("f.txt");
    _ = try repo.commit("Subject line\n\nDetailed body paragraph.\nSecond line of body.", "Test", "t@t.com");

    const log_out = try execGit(allocator, tmp, &.{ "log", "--format=%B", "-1" });
    defer allocator.free(log_out);
    try std.testing.expect(std.mem.indexOf(u8, log_out, "Subject line") != null);
    try std.testing.expect(std.mem.indexOf(u8, log_out, "Detailed body paragraph.") != null);
}

test "ziggit describeTagsFast matches git describe" {
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
        try f.writeAll("fast describe");
    }
    try repo.add("f.txt");
    _ = try repo.commit("tagged", "Test", "t@t.com");
    try repo.createTag("v7.0.0", null);

    const fast_desc = try repo.describeTagsFast(allocator);
    defer allocator.free(fast_desc);

    const git_desc = try execGit(allocator, tmp, &.{ "describe", "--tags", "--abbrev=0" });
    defer allocator.free(git_desc);

    try std.testing.expectEqualStrings(trimRight(git_desc), fast_desc);
}

test "ziggit init then add+commit in subdir -> git sees subdir files" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    // Create src/ dir with multiple files
    const src_dir = try std.fmt.allocPrint(allocator, "{s}/src", .{tmp});
    defer allocator.free(src_dir);
    try std.fs.makeDirAbsolute(src_dir);

    const names = [_][]const u8{ "src/main.zig", "src/lib.zig", "src/util.zig" };
    for (names) |name| {
        const fp = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tmp, name });
        defer allocator.free(fp);
        const f = try std.fs.createFileAbsolute(fp, .{});
        defer f.close();
        try f.writeAll(name);
        try repo.add(name);
    }
    _ = try repo.commit("add src", "Test", "t@t.com");

    const ls_out = try execGit(allocator, tmp, &.{ "ls-tree", "-r", "--name-only", "HEAD" });
    defer allocator.free(ls_out);
    for (names) |name| {
        try std.testing.expect(std.mem.indexOf(u8, ls_out, name) != null);
    }
}

test "bun workflow: multiple versions with new files" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    // v1.0.0 - package.json only
    const pkg_path = try std.fmt.allocPrint(allocator, "{s}/package.json", .{tmp});
    defer allocator.free(pkg_path);
    {
        const f = try std.fs.createFileAbsolute(pkg_path, .{});
        defer f.close();
        try f.writeAll("{\"name\":\"app\",\"version\":\"1.0.0\"}");
    }
    try repo.add("package.json");
    _ = try repo.commit("v1.0.0", "bun", "bun@bun.sh");
    try repo.createTag("v1.0.0", null);

    // v1.1.0 - add new src file (don't re-add package.json)
    const src_dir = try std.fmt.allocPrint(allocator, "{s}/src", .{tmp});
    defer allocator.free(src_dir);
    try std.fs.makeDirAbsolute(src_dir);
    const idx_path = try std.fmt.allocPrint(allocator, "{s}/src/index.ts", .{tmp});
    defer allocator.free(idx_path);
    {
        const f = try std.fs.createFileAbsolute(idx_path, .{});
        defer f.close();
        try f.writeAll("export const version = '1.1.0';");
    }
    try repo.add("src/index.ts");
    _ = try repo.commit("v1.1.0", "bun", "bun@bun.sh");
    try repo.createTag("v1.1.0", null);

    // v2.0.0 - add another new file
    const readme_path = try std.fmt.allocPrint(allocator, "{s}/README.md", .{tmp});
    defer allocator.free(readme_path);
    {
        const f = try std.fs.createFileAbsolute(readme_path, .{});
        defer f.close();
        try f.writeAll("# App v2.0.0\nBreaking changes.");
    }
    try repo.add("README.md");
    _ = try repo.commit("v2.0.0 breaking", "bun", "bun@bun.sh");
    try repo.createTag("v2.0.0", null);

    // Verify 3 commits
    const count = try execGit(allocator, tmp, &.{ "rev-list", "--count", "HEAD" });
    defer allocator.free(count);
    try std.testing.expectEqualStrings("3", trimRight(count));

    // Verify all 3 tags
    const tags = try execGit(allocator, tmp, &.{ "tag", "-l" });
    defer allocator.free(tags);
    try std.testing.expect(std.mem.indexOf(u8, tags, "v1.0.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, tags, "v1.1.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, tags, "v2.0.0") != null);

    // Verify v1.0.0 has package.json
    const v1_pkg = try execGit(allocator, tmp, &.{ "show", "v1.0.0:package.json" });
    defer allocator.free(v1_pkg);
    try std.testing.expect(std.mem.indexOf(u8, v1_pkg, "\"1.0.0\"") != null);

    // Verify HEAD has all 3 files
    const ls = try execGit(allocator, tmp, &.{ "ls-tree", "-r", "--name-only", "HEAD" });
    defer allocator.free(ls);
    try std.testing.expect(std.mem.indexOf(u8, ls, "package.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, ls, "src/index.ts") != null);
    try std.testing.expect(std.mem.indexOf(u8, ls, "README.md") != null);

    // Verify git describe
    const desc = try execGit(allocator, tmp, &.{ "describe", "--tags" });
    defer allocator.free(desc);
    try std.testing.expectEqualStrings("v2.0.0", trimRight(desc));

    // Verify HEAD is a valid commit
    const cat = try execGit(allocator, tmp, &.{ "cat-file", "-t", "HEAD" });
    defer allocator.free(cat);
    try std.testing.expectEqualStrings("commit", trimRight(cat));
}
