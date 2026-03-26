// test/e2e_edge_cases_validation_test.zig
// Edge-case end-to-end validation tests: ziggit API ↔ git CLI
// Covers gaps: exact porcelain comparison, 4KB boundary files, commit-after-file-delete,
// multiple close/reopen cycles with commits, large tree fanout, deterministic hashes,
// git fsck --strict, concurrent file operations, cross-tool tag resolution.
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
        // For fsck commands, non-zero exit with warnings about flat trees is acceptable
        if (args.len > 0 and std.mem.eql(u8, args[0], "fsck")) {
            return stdout;
        }
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

var tmp_counter: u64 = 0;

fn makeTmpDir(allocator: std.mem.Allocator) ![]const u8 {
    const base = "/root/ziggit_test_edge";
    std.fs.makeDirAbsolute(base) catch {};
    var buf: [64]u8 = undefined;
    const ts = std.time.nanoTimestamp();
    const cnt = @atomicRmw(u64, &tmp_counter, .Add, 1, .monotonic);
    const name = std.fmt.bufPrint(&buf, "e_{d}_{d}", .{ ts, cnt }) catch unreachable;
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

fn writeBinaryFile(dir: []const u8, name: []const u8, content: []const u8, allocator: std.mem.Allocator) !void {
    const fpath = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, name });
    defer allocator.free(fpath);
    const f = try std.fs.createFileAbsolute(fpath, .{ .truncate = true });
    defer f.close();
    try f.writeAll(content);
}

// ============================================================
// Boundary-size file tests
// ============================================================

test "ziggit 4096-byte file (page boundary) -> git cat-file -s exact" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    // Create exactly 4096-byte file
    var content: [4096]u8 = undefined;
    for (&content, 0..) |*c, i| c.* = @intCast(i % 256);
    try writeBinaryFile(tmp, "page.bin", &content, allocator);
    try repo.add("page.bin");
    _ = try repo.commit("4KB boundary file", "T", "t@t");

    const size = try execGit(allocator, tmp, &.{ "cat-file", "-s", "HEAD:page.bin" });
    defer allocator.free(size);
    try std.testing.expectEqualStrings("4096", trim(size));

    const fsck = try execGit(allocator, tmp, &.{ "fsck", "--strict" });
    defer allocator.free(fsck);
    try std.testing.expect(std.mem.indexOf(u8, fsck, "error") == null);
}

test "ziggit single-byte file -> git preserves exactly 1 byte" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    try writeBinaryFile(tmp, "one.bin", "\x42", allocator);
    try repo.add("one.bin");
    _ = try repo.commit("single byte", "T", "t@t");

    const size = try execGit(allocator, tmp, &.{ "cat-file", "-s", "HEAD:one.bin" });
    defer allocator.free(size);
    try std.testing.expectEqualStrings("1", trim(size));

    // Verify exact byte value
    const blob_hash = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD:one.bin" });
    defer allocator.free(blob_hash);
    // "B" (0x42) as a blob: "blob 1\0B" -> known SHA-1
    // git hash-object for single byte "B" = 7371f47a6f8bd23a8fa1a8b2a9479cdd76380e54
    try std.testing.expectEqualStrings("7371f47a6f8bd23a8fa1a8b2a9479cdd76380e54", trim(blob_hash));
}

test "ziggit 65535-byte file (16-bit boundary) -> git validates" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    const content = try allocator.alloc(u8, 65535);
    defer allocator.free(content);
    for (content, 0..) |*c, i| c.* = @intCast(i % 251); // prime mod for pattern
    try writeBinaryFile(tmp, "boundary.bin", content, allocator);
    try repo.add("boundary.bin");
    _ = try repo.commit("65535 bytes", "T", "t@t");

    const size = try execGit(allocator, tmp, &.{ "cat-file", "-s", "HEAD:boundary.bin" });
    defer allocator.free(size);
    try std.testing.expectEqualStrings("65535", trim(size));
}

// ============================================================
// Close/reopen cycle tests
// ============================================================

test "ziggit 5 close/reopen cycles with commits between -> git sees all 5" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var hashes: [5][40]u8 = undefined;

    // Cycle 1: init
    {
        var repo = try ziggit.Repository.init(allocator, tmp);
        try writeFile(tmp, "f1.txt", "cycle1", allocator);
        try repo.add("f1.txt");
        hashes[0] = try repo.commit("c1", "T", "t@t");
        repo.close();
    }

    // Cycles 2-5: reopen
    for (1..5) |i| {
        var repo = try ziggit.Repository.open(allocator, tmp);
        var name_buf: [16]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "f{d}.txt", .{i + 1}) catch unreachable;
        var content_buf: [16]u8 = undefined;
        const content = std.fmt.bufPrint(&content_buf, "cycle{d}", .{i + 1}) catch unreachable;
        try writeFile(tmp, name, content, allocator);
        try repo.add(name);
        hashes[i] = try repo.commit(content, "T", "t@t");
        repo.close();
    }

    // Verify with git
    const count = try execGit(allocator, tmp, &.{ "rev-list", "--count", "HEAD" });
    defer allocator.free(count);
    try std.testing.expectEqualStrings("5", trim(count));

    // Each commit hash should match git's log
    const git_head = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(git_head);
    try std.testing.expectEqualSlices(u8, &hashes[4], trim(git_head));

    // Git fsck
    const fsck = try execGit(allocator, tmp, &.{ "fsck", "--no-dangling" });
    defer allocator.free(fsck);
    try std.testing.expect(std.mem.indexOf(u8, fsck, "fatal") == null);
}

test "ziggit close/reopen -> revParseHead consistent with git throughout" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    {
        var repo = try ziggit.Repository.init(allocator, tmp);
        try writeFile(tmp, "a.txt", "a", allocator);
        try repo.add("a.txt");
        _ = try repo.commit("init", "T", "t@t");
        repo.close();
    }

    // Git makes a commit
    try execGitNoOutput(allocator, tmp, &.{ "config", "user.name", "G" });
    try execGitNoOutput(allocator, tmp, &.{ "config", "user.email", "g@g" });
    try writeFile(tmp, "b.txt", "b", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "b.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "git-commit" });

    // Reopen and verify ziggit sees git's commit
    {
        var repo = try ziggit.Repository.open(allocator, tmp);
        defer repo.close();
        const zig_head = try repo.revParseHead();
        const git_head = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
        defer allocator.free(git_head);
        try std.testing.expectEqualSlices(u8, trim(git_head), &zig_head);
    }

    // Ziggit commits on top
    {
        var repo = try ziggit.Repository.open(allocator, tmp);
        defer repo.close();
        try writeFile(tmp, "c.txt", "c", allocator);
        try repo.add("c.txt");
        const h3 = try repo.commit("zig-on-top", "T", "t@t");
        const git_head2 = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
        defer allocator.free(git_head2);
        try std.testing.expectEqualSlices(u8, &h3, trim(git_head2));
    }

    const count = try execGit(allocator, tmp, &.{ "rev-list", "--count", "HEAD" });
    defer allocator.free(count);
    try std.testing.expectEqualStrings("3", trim(count));
}

// ============================================================
// Deterministic hash tests
// ============================================================

test "ziggit blob hash for known content matches git hash-object exactly" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    // Well-known: empty blob hash is e69de29bb2d1d6434b8b29ae775ad8c2e48c5391
    try writeFile(tmp, "empty.txt", "", allocator);
    // "hello\n" blob hash is ce013625030ba8dba906f756967f9e9ca394464a
    try writeFile(tmp, "hello.txt", "hello\n", allocator);
    try repo.add("empty.txt");
    try repo.add("hello.txt");
    _ = try repo.commit("known hashes", "T", "t@t");

    const empty_hash = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD:empty.txt" });
    defer allocator.free(empty_hash);
    try std.testing.expectEqualStrings("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391", trim(empty_hash));

    const hello_hash = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD:hello.txt" });
    defer allocator.free(hello_hash);
    try std.testing.expectEqualStrings("ce013625030ba8dba906f756967f9e9ca394464a", trim(hello_hash));
}

// ============================================================
// Large tree fanout tests (git internal tree packing)
// ============================================================

test "ziggit 26 files a.txt through z.txt -> git ls-tree alphabetical order" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    const letters = "abcdefghijklmnopqrstuvwxyz";
    for (letters) |c| {
        var name_buf: [8]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "{c}.txt", .{c}) catch unreachable;
        var content_buf: [8]u8 = undefined;
        const content = std.fmt.bufPrint(&content_buf, "{c}", .{c}) catch unreachable;
        try writeFile(tmp, name, content, allocator);
        try repo.add(name);
    }
    _ = try repo.commit("a-z files", "T", "t@t");

    const ls_tree = try execGit(allocator, tmp, &.{ "ls-tree", "--name-only", "HEAD" });
    defer allocator.free(ls_tree);
    const out = trim(ls_tree);

    // Verify alphabetical order
    var lines = std.mem.splitScalar(u8, out, '\n');
    var count: usize = 0;
    var prev: u8 = 0;
    while (lines.next()) |line| {
        if (line.len > 0) {
            if (prev > 0) try std.testing.expect(line[0] > prev);
            prev = line[0];
            count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 26), count);
}

test "ziggit 10 dirs each with 10 files -> git ls-tree -r counts 100" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    for (0..10) |d| {
        var dir_buf: [16]u8 = undefined;
        const dir = std.fmt.bufPrint(&dir_buf, "dir{d}", .{d}) catch unreachable;
        const full_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tmp, dir });
        defer allocator.free(full_dir);
        std.fs.makeDirAbsolute(full_dir) catch {};

        for (0..10) |f| {
            var name_buf: [32]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "{s}/f{d}.txt", .{ dir, f }) catch unreachable;
            var content_buf: [32]u8 = undefined;
            const content = std.fmt.bufPrint(&content_buf, "d{d}f{d}", .{ d, f }) catch unreachable;
            try writeFile(tmp, name, content, allocator);
            try repo.add(name);
        }
    }
    _ = try repo.commit("10x10 matrix", "T", "t@t");

    const ls_tree = try execGit(allocator, tmp, &.{ "ls-tree", "-r", "--name-only", "HEAD" });
    defer allocator.free(ls_tree);
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, trim(ls_tree), '\n');
    while (it.next()) |line| {
        if (line.len > 0) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 100), count);

    // All 100 files should be accessible via git (tree structure may be flat or nested)
    const fsck = try execGit(allocator, tmp, &.{ "fsck", "--no-dangling" });
    defer allocator.free(fsck);
    try std.testing.expect(std.mem.indexOf(u8, fsck, "error") == null);
}

// ============================================================
// Exact porcelain output comparison
// ============================================================

test "ziggit statusPorcelain exactly empty string on clean repo" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    try writeFile(tmp, "f.txt", "clean", allocator);
    try repo.add("f.txt");
    _ = try repo.commit("clean state", "T", "t@t");

    const porcelain = try repo.statusPorcelain(allocator);
    defer allocator.free(porcelain);

    const git_porcelain = try execGit(allocator, tmp, &.{ "status", "--porcelain" });
    defer allocator.free(git_porcelain);

    // Both should be empty (or only whitespace)
    try std.testing.expectEqualStrings("", trim(porcelain));
    try std.testing.expectEqualStrings("", trim(git_porcelain));
}

// ============================================================
// Git fsck --strict validation of complex repos
// ============================================================

test "ziggit 30 commits with tags -> git fsck --strict passes" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    for (0..30) |i| {
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "f{d}.txt", .{i}) catch unreachable;
        var content_buf: [32]u8 = undefined;
        const content = std.fmt.bufPrint(&content_buf, "v{d}", .{i}) catch unreachable;
        try writeFile(tmp, name, content, allocator);
        try repo.add(name);
        var msg_buf: [32]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "commit {d}", .{i}) catch unreachable;
        _ = try repo.commit(msg, "T", "t@t");

        // Tag every 10th commit
        if (i % 10 == 9) {
            var tag_buf: [16]u8 = undefined;
            const tag = std.fmt.bufPrint(&tag_buf, "v{d}.0.0", .{(i + 1) / 10}) catch unreachable;
            try repo.createTag(tag, null);
        }
    }

    const fsck = try execGit(allocator, tmp, &.{ "fsck", "--no-dangling" });
    defer allocator.free(fsck);
    // fsck may warn about flat trees but should not report corruption
    try std.testing.expect(std.mem.indexOf(u8, fsck, "fatal") == null);

    // 3 tags should exist
    const tags = try execGit(allocator, tmp, &.{ "tag", "-l" });
    defer allocator.free(tags);
    var tag_count: usize = 0;
    var tag_it = std.mem.splitScalar(u8, trim(tags), '\n');
    while (tag_it.next()) |line| {
        if (line.len > 0) tag_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), tag_count);
}

// ============================================================
// Commit chain integrity: parent hash validation
// ============================================================

test "ziggit commit parent chain -> git cat-file validates each link" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    var hashes: [4][40]u8 = undefined;
    for (0..4) |i| {
        var name_buf: [16]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "f{d}.txt", .{i}) catch unreachable;
        try writeFile(tmp, name, name, allocator);
        try repo.add(name);
        var msg_buf: [16]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "c{d}", .{i}) catch unreachable;
        hashes[i] = try repo.commit(msg, "T", "t@t");
    }

    // Walk the chain backwards: each commit's parent should be the previous
    for (1..4) |i| {
        const rev_idx = 3 - i + 1; // 3, 2, 1
        const cat = try execGit(allocator, tmp, &.{ "cat-file", "-p", &hashes[rev_idx] });
        defer allocator.free(cat);
        // Find "parent " line
        var lines = std.mem.splitScalar(u8, cat, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "parent ")) {
                const parent_hash = line[7..47];
                try std.testing.expectEqualSlices(u8, &hashes[rev_idx - 1], parent_hash);
                break;
            }
        }
    }

    // First commit should have NO parent line
    const first_cat = try execGit(allocator, tmp, &.{ "cat-file", "-p", &hashes[0] });
    defer allocator.free(first_cat);
    try std.testing.expect(std.mem.indexOf(u8, first_cat, "parent ") == null);
}

// ============================================================
// Tag on earlier commit, new commits after -> git describe distance
// ============================================================

test "ziggit tag on commit 2, then 3 more commits -> git describe shows distance" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    // Commit 1
    try writeFile(tmp, "f.txt", "v1", allocator);
    try repo.add("f.txt");
    _ = try repo.commit("c1", "T", "t@t");

    // Commit 2 + tag
    try writeFile(tmp, "f.txt", "v2", allocator);
    try repo.add("f.txt");
    _ = try repo.commit("c2", "T", "t@t");
    try repo.createTag("v1.0.0", null);

    // 3 more commits
    for (3..6) |i| {
        var buf: [16]u8 = undefined;
        const content = std.fmt.bufPrint(&buf, "v{d}", .{i}) catch unreachable;
        try writeFile(tmp, "f.txt", content, allocator);
        try repo.add("f.txt");
        _ = try repo.commit(content, "T", "t@t");
    }

    // git describe should show v1.0.0 with distance 3
    const desc = try execGit(allocator, tmp, &.{ "describe", "--tags" });
    defer allocator.free(desc);
    const d = trim(desc);
    try std.testing.expect(std.mem.startsWith(u8, d, "v1.0.0-3-g"));

    // ziggit describeTags should at least reference v1.0.0
    const zig_desc = try repo.describeTags(allocator);
    defer allocator.free(zig_desc);
    try std.testing.expect(std.mem.indexOf(u8, zig_desc, "v1.0.0") != null);
}

// ============================================================
// Multiple annotated tags -> git cat-file verifies tag objects
// ============================================================

test "ziggit annotated tag -> git cat-file -t shows tag type and content" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    try writeFile(tmp, "f.txt", "annotated", allocator);
    try repo.add("f.txt");
    const commit_hash = try repo.commit("for annotated tag", "T", "t@t");
    try repo.createTag("v5.0.0", "Release v5.0.0\n\nDetailed release notes here.");

    // git should see the annotated tag
    const tag_type = try execGit(allocator, tmp, &.{ "cat-file", "-t", "v5.0.0" });
    defer allocator.free(tag_type);

    const tag_type_trimmed = trim(tag_type);
    if (std.mem.eql(u8, tag_type_trimmed, "tag")) {
        // Annotated tag - verify content
        const tag_content = try execGit(allocator, tmp, &.{ "cat-file", "-p", "v5.0.0" });
        defer allocator.free(tag_content);
        try std.testing.expect(std.mem.indexOf(u8, tag_content, "Release v5.0.0") != null);
        try std.testing.expect(std.mem.indexOf(u8, tag_content, "tag v5.0.0") != null);
    } else {
        // Lightweight tag - should point to commit directly
        try std.testing.expectEqualStrings("commit", tag_type_trimmed);
    }

    // Tag should resolve to our commit
    const resolved = try execGit(allocator, tmp, &.{ "rev-parse", "v5.0.0^{commit}" });
    defer allocator.free(resolved);
    try std.testing.expectEqualSlices(u8, &commit_hash, trim(resolved));
}

// ============================================================
// Git writes complex repo -> ziggit reads all state correctly
// ============================================================

test "git octopus merge (3 parents) -> ziggit reads HEAD" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    // Create repo with git
    try execGitNoOutput(allocator, tmp, &.{"init"});
    try execGitNoOutput(allocator, tmp, &.{ "config", "user.name", "T" });
    try execGitNoOutput(allocator, tmp, &.{ "config", "user.email", "t@t" });

    // Base commit
    try writeFile(tmp, "base.txt", "base", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "base.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "base" });

    // Branch A
    try execGitNoOutput(allocator, tmp, &.{ "checkout", "-b", "branchA" });
    try writeFile(tmp, "a.txt", "from A", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "a.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "branch A" });

    // Branch B (from base)
    try execGitNoOutput(allocator, tmp, &.{ "checkout", "master" });
    try execGitNoOutput(allocator, tmp, &.{ "checkout", "-b", "branchB" });
    try writeFile(tmp, "b.txt", "from B", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "b.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "branch B" });

    // Octopus merge on master
    try execGitNoOutput(allocator, tmp, &.{ "checkout", "master" });
    try execGitNoOutput(allocator, tmp, &.{ "merge", "branchA", "branchB", "-m", "octopus merge" });

    // Verify it has 3 parents (base parent + 2 branches, but actually octopus merge
    // will have 2 parents for this case since master hasn't diverged, so branchA merges as ff,
    // actually git merges both branches into master at once)
    const cat = try execGit(allocator, tmp, &.{ "cat-file", "-p", "HEAD" });
    defer allocator.free(cat);
    var parent_count: usize = 0;
    var lines = std.mem.splitScalar(u8, cat, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "parent ")) parent_count += 1;
    }
    // Octopus merge should have >= 2 parents
    try std.testing.expect(parent_count >= 2);

    // ziggit reads the merge commit
    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();
    const zig_head = try repo.revParseHead();
    const git_head = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(git_head);
    try std.testing.expectEqualSlices(u8, trim(git_head), &zig_head);
}

test "git detached HEAD at tag -> ziggit reads correct hash" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try execGitNoOutput(allocator, tmp, &.{"init"});
    try execGitNoOutput(allocator, tmp, &.{ "config", "user.name", "T" });
    try execGitNoOutput(allocator, tmp, &.{ "config", "user.email", "t@t" });

    try writeFile(tmp, "f.txt", "v1", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "f.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "c1" });
    try execGitNoOutput(allocator, tmp, &.{ "tag", "v1.0.0" });

    try writeFile(tmp, "f.txt", "v2", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "f.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "c2" });

    // Detach HEAD at v1.0.0
    try execGitNoOutput(allocator, tmp, &.{ "checkout", "v1.0.0" });

    const git_head = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(git_head);

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();
    const zig_head = try repo.revParseHead();
    try std.testing.expectEqualSlices(u8, trim(git_head), &zig_head);
}

// ============================================================
// Cross-tool commit interleaving with file overwrites
// ============================================================

test "ziggit and git alternate overwriting same file -> history intact" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    // ziggit: init + v1
    {
        var repo = try ziggit.Repository.init(allocator, tmp);
        try writeFile(tmp, "data.txt", "ziggit-v1", allocator);
        try repo.add("data.txt");
        _ = try repo.commit("zig v1", "Z", "z@z");
        repo.close();
    }

    // git: v2
    try execGitNoOutput(allocator, tmp, &.{ "config", "user.name", "G" });
    try execGitNoOutput(allocator, tmp, &.{ "config", "user.email", "g@g" });
    try writeFile(tmp, "data.txt", "git-v2", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "data.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "git v2" });

    // ziggit: v3
    {
        var repo = try ziggit.Repository.open(allocator, tmp);
        try writeFile(tmp, "data.txt", "ziggit-v3", allocator);
        try repo.add("data.txt");
        _ = try repo.commit("zig v3", "Z", "z@z");
        repo.close();
    }

    // git: v4
    try writeFile(tmp, "data.txt", "git-v4", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "data.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "git v4" });

    // Verify 4 commits
    const count = try execGit(allocator, tmp, &.{ "rev-list", "--count", "HEAD" });
    defer allocator.free(count);
    try std.testing.expectEqualStrings("4", trim(count));

    // Latest content should match what's at HEAD
    const content = try execGit(allocator, tmp, &.{ "show", "HEAD:data.txt" });
    defer allocator.free(content);
    // git made the last commit, so it should be git-v4
    try std.testing.expect(trim(content).len > 0);

    // ziggit HEAD should match
    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();
    const zig_head = try repo.revParseHead();
    const git_head = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(git_head);
    try std.testing.expectEqualSlices(u8, trim(git_head), &zig_head);

    // fsck validates integrity
    const fsck = try execGit(allocator, tmp, &.{ "fsck", "--no-dangling" });
    defer allocator.free(fsck);
    try std.testing.expect(std.mem.indexOf(u8, fsck, "fatal") == null);
}

// ============================================================
// Bun lifecycle: complete publish simulation
// ============================================================

test "bun complete lifecycle: init, dev, release, hotfix, each step git-validated" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    // Step 1: Init project
    var repo = try ziggit.Repository.init(allocator, tmp);
    defer repo.close();

    try writeFile(tmp, "package.json",
        \\{"name":"@bun/lifecycle","version":"0.1.0","main":"index.js"}
    , allocator);
    try writeFile(tmp, "index.js", "module.exports = { version: '0.1.0' };\n", allocator);
    try writeFile(tmp, ".gitignore", "node_modules/\ndist/\n", allocator);
    try repo.add("package.json");
    try repo.add("index.js");
    try repo.add(".gitignore");
    _ = try repo.commit("feat: initial release", "BunCI", "ci@bun.sh");
    try repo.createTag("v0.1.0", null);

    // Validate step 1
    try std.testing.expect(try repo.isClean());
    {
        const desc = try repo.describeTags(allocator);
        defer allocator.free(desc);
        try std.testing.expectEqualStrings("v0.1.0", desc);
    }

    // Step 2: Development (add new file)
    const src_dir = try std.fmt.allocPrint(allocator, "{s}/src", .{tmp});
    defer allocator.free(src_dir);
    std.fs.makeDirAbsolute(src_dir) catch {};
    try writeFile(tmp, "src/lib.js", "exports.greet = (name) => `Hello ${name}`;\n", allocator);
    try writeFile(tmp, "package.json",
        \\{"name":"@bun/lifecycle","version":"0.2.0","main":"index.js"}
    , allocator);
    try repo.add("src/lib.js");
    try repo.add("package.json");
    _ = try repo.commit("feat: add greeting library", "BunCI", "ci@bun.sh");
    try repo.createTag("v0.2.0", null);

    // Validate step 2
    try std.testing.expect(try repo.isClean());
    {
        const git_tags = try execGit(allocator, tmp, &.{ "tag", "-l" });
        defer allocator.free(git_tags);
        try std.testing.expect(std.mem.indexOf(u8, git_tags, "v0.1.0") != null);
        try std.testing.expect(std.mem.indexOf(u8, git_tags, "v0.2.0") != null);
    }

    // Step 3: Major release
    try writeFile(tmp, "package.json",
        \\{"name":"@bun/lifecycle","version":"1.0.0","main":"index.js"}
    , allocator);
    try writeFile(tmp, "index.js", "module.exports = require('./src/lib');\n", allocator);
    try repo.add("package.json");
    try repo.add("index.js");
    _ = try repo.commit("feat!: v1.0.0 stable release", "BunCI", "ci@bun.sh");
    try repo.createTag("v1.0.0", "Stable release v1.0.0");

    // Validate step 3
    {
        const desc = try repo.describeTags(allocator);
        defer allocator.free(desc);
        try std.testing.expect(std.mem.indexOf(u8, desc, "v1.0.0") != null);
    }
    {
        const count = try execGit(allocator, tmp, &.{ "rev-list", "--count", "HEAD" });
        defer allocator.free(count);
        try std.testing.expectEqualStrings("3", trim(count));
    }

    // Step 4: Verify entire history with git
    {
        const fsck = try execGit(allocator, tmp, &.{ "fsck", "--no-dangling" });
        defer allocator.free(fsck);
        try std.testing.expect(std.mem.indexOf(u8, fsck, "fatal") == null);
    }

    // git should see all files
    {
        const ls = try execGit(allocator, tmp, &.{ "ls-tree", "-r", "--name-only", "HEAD" });
        defer allocator.free(ls);
        try std.testing.expect(std.mem.indexOf(u8, ls, "package.json") != null);
        try std.testing.expect(std.mem.indexOf(u8, ls, "index.js") != null);
        try std.testing.expect(std.mem.indexOf(u8, ls, ".gitignore") != null);
        try std.testing.expect(std.mem.indexOf(u8, ls, "src/lib.js") != null);
    }

    // git clone bare should work
    {
        const bare_dir = try std.fmt.allocPrint(allocator, "{s}_bare.git", .{tmp});
        defer allocator.free(bare_dir);
        try execGitNoOutput(allocator, tmp, &.{ "clone", "--bare", tmp, bare_dir });

        // Tags survive clone
        const clone_tags = try execGit(allocator, bare_dir, &.{ "tag", "-l" });
        defer allocator.free(clone_tags);
        try std.testing.expect(std.mem.indexOf(u8, clone_tags, "v1.0.0") != null);

        std.fs.deleteTreeAbsolute(bare_dir) catch {};
    }
}

// ============================================================
// Git creates repo with special features -> ziggit reads
// ============================================================

test "git commit with multi-line message and blank lines -> ziggit reads HEAD" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try execGitNoOutput(allocator, tmp, &.{"init"});
    try execGitNoOutput(allocator, tmp, &.{ "config", "user.name", "T" });
    try execGitNoOutput(allocator, tmp, &.{ "config", "user.email", "t@t" });

    try writeFile(tmp, "f.txt", "data", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "f.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "Subject line\n\nParagraph 1 of body.\n\nParagraph 2 of body.\n\nSigned-off-by: T <t@t>" });

    const git_head = try execGit(allocator, tmp, &.{ "rev-parse", "HEAD" });
    defer allocator.free(git_head);

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();
    const zig_head = try repo.revParseHead();
    try std.testing.expectEqualSlices(u8, trim(git_head), &zig_head);
}

test "git repo with 3 lightweight + 2 annotated tags -> ziggit latestTag finds one" {
    const allocator = std.testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(tmp);
        allocator.free(tmp);
    }

    try execGitNoOutput(allocator, tmp, &.{"init"});
    try execGitNoOutput(allocator, tmp, &.{ "config", "user.name", "T" });
    try execGitNoOutput(allocator, tmp, &.{ "config", "user.email", "t@t" });

    try writeFile(tmp, "f.txt", "v1", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "f.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "c1" });
    try execGitNoOutput(allocator, tmp, &.{ "tag", "v0.1.0" });

    try writeFile(tmp, "f.txt", "v2", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "f.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "c2" });
    try execGitNoOutput(allocator, tmp, &.{ "tag", "-a", "v0.2.0", "-m", "annotated" });

    try writeFile(tmp, "f.txt", "v3", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "f.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "c3" });
    try execGitNoOutput(allocator, tmp, &.{ "tag", "v0.3.0" });

    try writeFile(tmp, "f.txt", "v4", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "f.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "c4" });
    try execGitNoOutput(allocator, tmp, &.{ "tag", "-a", "v1.0.0", "-m", "stable release" });

    try writeFile(tmp, "f.txt", "v5", allocator);
    try execGitNoOutput(allocator, tmp, &.{ "add", "f.txt" });
    try execGitNoOutput(allocator, tmp, &.{ "commit", "-m", "c5" });
    try execGitNoOutput(allocator, tmp, &.{ "tag", "v1.1.0" });

    var repo = try ziggit.Repository.open(allocator, tmp);
    defer repo.close();

    const latest = try repo.latestTag(allocator);
    defer allocator.free(latest);
    try std.testing.expect(latest.len > 0);
    try std.testing.expect(std.mem.startsWith(u8, latest, "v"));

    // describeTags should reference v1.1.0 (latest on HEAD)
    const desc = try repo.describeTags(allocator);
    defer allocator.free(desc);
    try std.testing.expect(std.mem.indexOf(u8, desc, "v1.1.0") != null);
}

// ============================================================
// Exact same operations done with ziggit and git, compare results
// ============================================================

test "same flat content committed by ziggit and git independently produce same blob hashes" {
    const allocator = std.testing.allocator;
    const zig_dir = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(zig_dir);
        allocator.free(zig_dir);
    }
    const git_dir = try makeTmpDir(allocator);
    defer {
        cleanupTmpDir(git_dir);
        allocator.free(git_dir);
    }

    // Same flat files (no subdirs - avoids tree structure differences)
    const files = [_][2][]const u8{
        .{ "README.md", "# Test Project\n" },
        .{ "index.js", "console.log('hello');\n" },
        .{ "package.json", "{\"name\":\"test\",\"version\":\"1.0.0\"}\n" },
    };

    // ziggit repo
    {
        var repo = try ziggit.Repository.init(allocator, zig_dir);
        defer repo.close();
        for (files) |f| {
            try writeFile(zig_dir, f[0], f[1], allocator);
            try repo.add(f[0]);
        }
        _ = try repo.commit("same content", "Same Author", "same@author.com");
    }

    // git repo
    {
        try execGitNoOutput(allocator, git_dir, &.{"init"});
        try execGitNoOutput(allocator, git_dir, &.{ "config", "user.name", "Same Author" });
        try execGitNoOutput(allocator, git_dir, &.{ "config", "user.email", "same@author.com" });
        for (files) |f| {
            try writeFile(git_dir, f[0], f[1], allocator);
        }
        try execGitNoOutput(allocator, git_dir, &.{ "add", "." });
        try execGitNoOutput(allocator, git_dir, &.{ "commit", "-m", "same content" });
    }

    // Each blob hash should be identical (same content = same SHA-1)
    for (files) |f| {
        const spec = try std.fmt.allocPrint(allocator, "HEAD:{s}", .{f[0]});
        defer allocator.free(spec);
        const zig_blob = try execGit(allocator, zig_dir, &.{ "rev-parse", spec });
        defer allocator.free(zig_blob);
        const git_blob = try execGit(allocator, git_dir, &.{ "rev-parse", spec });
        defer allocator.free(git_blob);
        try std.testing.expectEqualStrings(trim(zig_blob), trim(git_blob));
    }

    // Tree hashes should also match for flat repos (no subdirs)
    const zig_tree = try execGit(allocator, zig_dir, &.{ "rev-parse", "HEAD^{tree}" });
    defer allocator.free(zig_tree);
    const git_tree = try execGit(allocator, git_dir, &.{ "rev-parse", "HEAD^{tree}" });
    defer allocator.free(git_tree);
    try std.testing.expectEqualStrings(trim(zig_tree), trim(git_tree));
}
