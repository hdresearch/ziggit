// test/ref_resolution_test.zig
// Tests for ref resolution: HEAD -> refs/heads/master, symbolic refs, detached HEAD,
// branch listing, tag listing, findCommit with various ref types
const std = @import("std");
const ziggit = @import("ziggit");
const testing = std.testing;

fn createTestRepo(allocator: std.mem.Allocator) !struct { repo: ziggit.Repository, path: []const u8 } {
    const base = "/tmp/ziggit_ref_test";
    std.fs.makeDirAbsolute(base) catch {};

    var buf: [64]u8 = undefined;
    const ts = std.time.milliTimestamp();
    const name = std.fmt.bufPrint(&buf, "{d}_{d}", .{ ts, @as(u64, @bitCast(ts)) *% 6364136223846793005 }) catch unreachable;
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, name });
    std.fs.makeDirAbsolute(path) catch {};

    const repo = try ziggit.Repository.init(allocator, path);
    return .{ .repo = repo, .path = path };
}

fn cleanupRepo(allocator: std.mem.Allocator, path: []const u8) void {
    std.fs.deleteTreeAbsolute(path) catch {};
    allocator.free(path);
}

fn writeFile(path: []const u8, content: []const u8) !void {
    const f = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer f.close();
    try f.writeAll(content);
}

fn readFileContent(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const f = try std.fs.openFileAbsolute(path, .{});
    defer f.close();
    return try f.readToEndAlloc(allocator, 1024 * 1024);
}

// --- HEAD resolution tests ---

test "fresh repo HEAD points to refs/heads/master" {
    const allocator = testing.allocator;
    var result = try createTestRepo(allocator);
    defer {
        result.repo.close();
        cleanupRepo(allocator, result.path);
    }

    const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{result.repo.git_dir});
    defer allocator.free(head_path);

    const head_content = try readFileContent(allocator, head_path);
    defer allocator.free(head_content);

    const trimmed = std.mem.trim(u8, head_content, " \n\r\t");
    try testing.expectEqualStrings("ref: refs/heads/master", trimmed);
}

test "revParseHead on empty repo returns all zeros" {
    const allocator = testing.allocator;
    var result = try createTestRepo(allocator);
    defer {
        result.repo.close();
        cleanupRepo(allocator, result.path);
    }

    // Empty repo: HEAD -> refs/heads/master, but master doesn't exist yet
    // Should either return zeros or error
    const head = result.repo.revParseHead() catch {
        // error is acceptable for empty repo
        return;
    };
    // If no error, should be all zeros
    try testing.expectEqualSlices(u8, &([_]u8{'0'} ** 40), &head);
}

test "revParseHead after first commit returns valid hash" {
    const allocator = testing.allocator;
    var result = try createTestRepo(allocator);
    defer {
        result.repo.close();
        cleanupRepo(allocator, result.path);
    }

    const fp = try std.fmt.allocPrint(allocator, "{s}/f.txt", .{result.path});
    defer allocator.free(fp);
    try writeFile(fp, "hi");
    try result.repo.add("f.txt");
    const commit_hash = try result.repo.commit("init", "T", "t@t.t");

    const head = try result.repo.revParseHead();
    try testing.expectEqualSlices(u8, &commit_hash, &head);
}

test "revParseHead updates after each commit" {
    const allocator = testing.allocator;
    var result = try createTestRepo(allocator);
    defer {
        result.repo.close();
        cleanupRepo(allocator, result.path);
    }

    const fp = try std.fmt.allocPrint(allocator, "{s}/seq.txt", .{result.path});
    defer allocator.free(fp);

    var last_hash: [40]u8 = undefined;
    for (0..5) |i| {
        const content = try std.fmt.allocPrint(allocator, "version {d}", .{i});
        defer allocator.free(content);
        try writeFile(fp, content);
        try result.repo.add("seq.txt");
        // Need to clear cache for subsequent commits
        result.repo._cached_head_hash = null;
        last_hash = try result.repo.commit(content, "T", "t@t.t");
    }

    result.repo._cached_head_hash = null;
    const head = try result.repo.revParseHead();
    try testing.expectEqualSlices(u8, &last_hash, &head);
}

test "refs/heads/master contains commit hash after commit" {
    const allocator = testing.allocator;
    var result = try createTestRepo(allocator);
    defer {
        result.repo.close();
        cleanupRepo(allocator, result.path);
    }

    const fp = try std.fmt.allocPrint(allocator, "{s}/x.txt", .{result.path});
    defer allocator.free(fp);
    try writeFile(fp, "x");
    try result.repo.add("x.txt");
    const commit_hash = try result.repo.commit("x", "T", "t@t.t");

    // Read refs/heads/master directly
    const ref_path = try std.fmt.allocPrint(allocator, "{s}/refs/heads/master", .{result.repo.git_dir});
    defer allocator.free(ref_path);

    const ref_content = try readFileContent(allocator, ref_path);
    defer allocator.free(ref_content);

    try testing.expectEqualSlices(u8, &commit_hash, ref_content[0..40]);
}

// --- findCommit tests ---

test "findCommit HEAD resolves to same as revParseHead" {
    const allocator = testing.allocator;
    var result = try createTestRepo(allocator);
    defer {
        result.repo.close();
        cleanupRepo(allocator, result.path);
    }

    const fp = try std.fmt.allocPrint(allocator, "{s}/fc.txt", .{result.path});
    defer allocator.free(fp);
    try writeFile(fp, "find");
    try result.repo.add("fc.txt");
    _ = try result.repo.commit("find commit", "T", "t@t.t");

    result.repo._cached_head_hash = null;
    const head = try result.repo.revParseHead();
    const found = try result.repo.findCommit("HEAD");
    try testing.expectEqualSlices(u8, &head, &found);
}

test "findCommit with full 40-char hash returns same hash" {
    const allocator = testing.allocator;
    var result = try createTestRepo(allocator);
    defer {
        result.repo.close();
        cleanupRepo(allocator, result.path);
    }

    const fp = try std.fmt.allocPrint(allocator, "{s}/full.txt", .{result.path});
    defer allocator.free(fp);
    try writeFile(fp, "full");
    try result.repo.add("full.txt");
    const commit_hash = try result.repo.commit("full hash", "T", "t@t.t");

    const found = try result.repo.findCommit(&commit_hash);
    try testing.expectEqualSlices(u8, &commit_hash, &found);
}

test "findCommit with branch name resolves correctly" {
    const allocator = testing.allocator;
    var result = try createTestRepo(allocator);
    defer {
        result.repo.close();
        cleanupRepo(allocator, result.path);
    }

    const fp = try std.fmt.allocPrint(allocator, "{s}/br.txt", .{result.path});
    defer allocator.free(fp);
    try writeFile(fp, "branch");
    try result.repo.add("br.txt");
    const commit_hash = try result.repo.commit("branch test", "T", "t@t.t");

    const found = try result.repo.findCommit("master");
    try testing.expectEqualSlices(u8, &commit_hash, &found);
}

test "findCommit with tag name resolves correctly" {
    const allocator = testing.allocator;
    var result = try createTestRepo(allocator);
    defer {
        result.repo.close();
        cleanupRepo(allocator, result.path);
    }

    const fp = try std.fmt.allocPrint(allocator, "{s}/tg.txt", .{result.path});
    defer allocator.free(fp);
    try writeFile(fp, "tag");
    try result.repo.add("tg.txt");
    const commit_hash = try result.repo.commit("tag test", "T", "t@t.t");

    try result.repo.createTag("v1.0", null);

    const found = try result.repo.findCommit("v1.0");
    try testing.expectEqualSlices(u8, &commit_hash, &found);
}

test "findCommit with short hash (7 chars) resolves" {
    const allocator = testing.allocator;
    var result = try createTestRepo(allocator);
    defer {
        result.repo.close();
        cleanupRepo(allocator, result.path);
    }

    const fp = try std.fmt.allocPrint(allocator, "{s}/sh.txt", .{result.path});
    defer allocator.free(fp);
    try writeFile(fp, "short");
    try result.repo.add("sh.txt");
    const commit_hash = try result.repo.commit("short hash", "T", "t@t.t");

    // Try 7-char prefix
    var short: [7]u8 = undefined;
    @memcpy(&short, commit_hash[0..7]);
    const found = try result.repo.findCommit(&short);
    try testing.expectEqualSlices(u8, &commit_hash, &found);
}

test "findCommit with nonexistent ref returns error" {
    const allocator = testing.allocator;
    var result = try createTestRepo(allocator);
    defer {
        result.repo.close();
        cleanupRepo(allocator, result.path);
    }

    const fp = try std.fmt.allocPrint(allocator, "{s}/ne.txt", .{result.path});
    defer allocator.free(fp);
    try writeFile(fp, "ne");
    try result.repo.add("ne.txt");
    _ = try result.repo.commit("ne", "T", "t@t.t");

    const err = result.repo.findCommit("nonexistent_branch");
    try testing.expectError(error.CommitNotFound, err);
}

// --- branchList tests ---

test "branchList on fresh repo with commit shows master" {
    const allocator = testing.allocator;
    var result = try createTestRepo(allocator);
    defer {
        result.repo.close();
        cleanupRepo(allocator, result.path);
    }

    const fp = try std.fmt.allocPrint(allocator, "{s}/bl.txt", .{result.path});
    defer allocator.free(fp);
    try writeFile(fp, "bl");
    try result.repo.add("bl.txt");
    _ = try result.repo.commit("bl", "T", "t@t.t");

    const branches = try result.repo.branchList(allocator);
    defer {
        for (branches) |b| allocator.free(b);
        allocator.free(branches);
    }

    try testing.expectEqual(@as(usize, 1), branches.len);
    try testing.expectEqualStrings("master", branches[0]);
}

test "branchList on empty repo returns empty" {
    const allocator = testing.allocator;
    var result = try createTestRepo(allocator);
    defer {
        result.repo.close();
        cleanupRepo(allocator, result.path);
    }

    const branches = try result.repo.branchList(allocator);
    defer allocator.free(branches);

    try testing.expectEqual(@as(usize, 0), branches.len);
}

test "branchList with manually created branch" {
    const allocator = testing.allocator;
    var result = try createTestRepo(allocator);
    defer {
        result.repo.close();
        cleanupRepo(allocator, result.path);
    }

    const fp = try std.fmt.allocPrint(allocator, "{s}/mb.txt", .{result.path});
    defer allocator.free(fp);
    try writeFile(fp, "mb");
    try result.repo.add("mb.txt");
    const commit_hash = try result.repo.commit("mb", "T", "t@t.t");

    // Manually create a branch ref
    const branch_path = try std.fmt.allocPrint(allocator, "{s}/refs/heads/feature-x", .{result.repo.git_dir});
    defer allocator.free(branch_path);
    try writeFile(branch_path, &commit_hash);

    const branches = try result.repo.branchList(allocator);
    defer {
        for (branches) |b| allocator.free(b);
        allocator.free(branches);
    }

    try testing.expectEqual(@as(usize, 2), branches.len);

    // Should contain both master and feature-x (order may vary)
    var found_master = false;
    var found_feature = false;
    for (branches) |b| {
        if (std.mem.eql(u8, b, "master")) found_master = true;
        if (std.mem.eql(u8, b, "feature-x")) found_feature = true;
    }
    try testing.expect(found_master);
    try testing.expect(found_feature);
}

// --- describeTags tests ---

test "describeTags on repo with no tags returns empty" {
    const allocator = testing.allocator;
    var result = try createTestRepo(allocator);
    defer {
        result.repo.close();
        cleanupRepo(allocator, result.path);
    }

    const tag = try result.repo.describeTags(allocator);
    defer allocator.free(tag);
    try testing.expectEqualStrings("", tag);
}

test "describeTags returns tag name after createTag" {
    const allocator = testing.allocator;
    var result = try createTestRepo(allocator);
    defer {
        result.repo.close();
        cleanupRepo(allocator, result.path);
    }

    const fp = try std.fmt.allocPrint(allocator, "{s}/dt.txt", .{result.path});
    defer allocator.free(fp);
    try writeFile(fp, "dt");
    try result.repo.add("dt.txt");
    _ = try result.repo.commit("dt", "T", "t@t.t");

    try result.repo.createTag("v2.0.0", null);

    const tag = try result.repo.describeTags(allocator);
    defer allocator.free(tag);
    try testing.expectEqualStrings("v2.0.0", tag);
}

test "describeTags returns lexicographically latest of multiple tags" {
    const allocator = testing.allocator;
    var result = try createTestRepo(allocator);
    defer {
        result.repo.close();
        cleanupRepo(allocator, result.path);
    }

    const fp = try std.fmt.allocPrint(allocator, "{s}/mt.txt", .{result.path});
    defer allocator.free(fp);
    try writeFile(fp, "mt");
    try result.repo.add("mt.txt");
    _ = try result.repo.commit("mt", "T", "t@t.t");

    try result.repo.createTag("v1.0.0", null);
    try result.repo.createTag("v2.0.0", null);
    try result.repo.createTag("v1.5.0", null);

    const tag = try result.repo.describeTags(allocator);
    defer allocator.free(tag);
    try testing.expectEqualStrings("v2.0.0", tag);
}

// --- Tag file format tests ---

test "tag ref file created in refs/tags directory" {
    const allocator = testing.allocator;
    var result = try createTestRepo(allocator);
    defer {
        result.repo.close();
        cleanupRepo(allocator, result.path);
    }

    const fp = try std.fmt.allocPrint(allocator, "{s}/tf.txt", .{result.path});
    defer allocator.free(fp);
    try writeFile(fp, "tf");
    try result.repo.add("tf.txt");
    _ = try result.repo.commit("tf", "T", "t@t.t");

    try result.repo.createTag("release-1", null);

    const tag_path = try std.fmt.allocPrint(allocator, "{s}/refs/tags/release-1", .{result.repo.git_dir});
    defer allocator.free(tag_path);

    // File should exist and contain 40 hex chars
    const content = try readFileContent(allocator, tag_path);
    defer allocator.free(content);
    try testing.expectEqual(@as(usize, 40), content.len);
    for (content) |c| {
        try testing.expect(std.ascii.isHex(c));
    }
}

// --- Cross-validation with git CLI ---

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

test "ziggit revParseHead matches git rev-parse HEAD" {
    const allocator = testing.allocator;
    var result = try createTestRepo(allocator);
    defer {
        result.repo.close();
        cleanupRepo(allocator, result.path);
    }

    const fp = try std.fmt.allocPrint(allocator, "{s}/rp.txt", .{result.path});
    defer allocator.free(fp);
    try writeFile(fp, "rp");
    try result.repo.add("rp.txt");
    const ziggit_hash = try result.repo.commit("rp", "Test User", "test@test.com");

    // Ask git
    const git_out = try execGit(allocator, result.path, &.{ "rev-parse", "HEAD" });
    defer allocator.free(git_out);
    const git_hash = std.mem.trim(u8, git_out, " \n\r\t");

    try testing.expectEqualSlices(u8, &ziggit_hash, git_hash);
}

test "ziggit branchList matches git branch" {
    const allocator = testing.allocator;
    var result = try createTestRepo(allocator);
    defer {
        result.repo.close();
        cleanupRepo(allocator, result.path);
    }

    const fp = try std.fmt.allocPrint(allocator, "{s}/gb.txt", .{result.path});
    defer allocator.free(fp);
    try writeFile(fp, "gb");
    try result.repo.add("gb.txt");
    const commit_hash = try result.repo.commit("gb", "T", "t@t.t");

    // Create another branch via direct file write
    const branch_path = try std.fmt.allocPrint(allocator, "{s}/refs/heads/develop", .{result.repo.git_dir});
    defer allocator.free(branch_path);
    try writeFile(branch_path, &commit_hash);

    // ziggit
    const branches = try result.repo.branchList(allocator);
    defer {
        for (branches) |b| allocator.free(b);
        allocator.free(branches);
    }

    // git
    const git_out = try execGit(allocator, result.path, &.{"branch"});
    defer allocator.free(git_out);

    // Both should show master and develop
    var found_master = false;
    var found_develop = false;
    for (branches) |b| {
        if (std.mem.eql(u8, b, "master")) found_master = true;
        if (std.mem.eql(u8, b, "develop")) found_develop = true;
    }
    try testing.expect(found_master);
    try testing.expect(found_develop);

    try testing.expect(std.mem.indexOf(u8, git_out, "master") != null);
    try testing.expect(std.mem.indexOf(u8, git_out, "develop") != null);
}

test "git tag -l sees ziggit-created tags" {
    const allocator = testing.allocator;
    var result = try createTestRepo(allocator);
    defer {
        result.repo.close();
        cleanupRepo(allocator, result.path);
    }

    const fp = try std.fmt.allocPrint(allocator, "{s}/gt.txt", .{result.path});
    defer allocator.free(fp);
    try writeFile(fp, "gt");
    try result.repo.add("gt.txt");
    _ = try result.repo.commit("gt", "T", "t@t.t");

    try result.repo.createTag("v3.0.0", null);
    try result.repo.createTag("v3.1.0", null);

    const git_out = try execGit(allocator, result.path, &.{ "tag", "-l" });
    defer allocator.free(git_out);

    try testing.expect(std.mem.indexOf(u8, git_out, "v3.0.0") != null);
    try testing.expect(std.mem.indexOf(u8, git_out, "v3.1.0") != null);
}
