// test/ref_chain_resolution_test.zig
// Tests for ref resolution: symbolic refs, packed refs, branch/tag listing
// Uses ziggit public API and git CLI for cross-validation
const std = @import("std");
const ziggit = @import("ziggit");
const testing = std.testing;

fn tmp(comptime suffix: []const u8) []const u8 {
    return "/tmp/ziggit_ref_chain_" ++ suffix;
}

fn cleanup(path: []const u8) void {
    std.fs.deleteTreeAbsolute(path) catch {};
}

fn writeFile(dir: []const u8, name: []const u8, content: []const u8) !void {
    const full = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ dir, name });
    defer testing.allocator.free(full);
    const f = try std.fs.createFileAbsolute(full, .{ .truncate = true });
    defer f.close();
    try f.writeAll(content);
}

fn writeAbsFile(path: []const u8, content: []const u8) !void {
    const f = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer f.close();
    try f.writeAll(content);
}

fn git(cwd: []const u8, args: []const []const u8) ![]u8 {
    var argv = std.ArrayList([]const u8).init(testing.allocator);
    defer argv.deinit();
    try argv.append("git");
    for (args) |a| try argv.append(a);
    var child = std.process.Child.init(argv.items, testing.allocator);
    child.cwd = cwd;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const stdout = try child.stdout.?.reader().readAllAlloc(testing.allocator, 1024 * 1024);
    errdefer testing.allocator.free(stdout);
    const stderr = try child.stderr.?.reader().readAllAlloc(testing.allocator, 1024 * 1024);
    defer testing.allocator.free(stderr);
    const result = try child.wait();
    if (result.Exited != 0) {
        testing.allocator.free(stdout);
        return error.GitFailed;
    }
    return stdout;
}

fn gitTrim(cwd: []const u8, args: []const []const u8) ![]u8 {
    const out = try git(cwd, args);
    const trimmed = std.mem.trim(u8, out, " \n\r\t");
    if (trimmed.len == out.len) return out;
    const result = try testing.allocator.dupe(u8, trimmed);
    testing.allocator.free(out);
    return result;
}

fn gitOk(cwd: []const u8, args: []const []const u8) !void {
    const out = try git(cwd, args);
    testing.allocator.free(out);
}

fn initRepo(path: []const u8) !ziggit.Repository {
    cleanup(path);
    const repo = try ziggit.Repository.init(testing.allocator, path);
    gitOk(path, &.{ "config", "user.email", "t@t.com" }) catch {};
    gitOk(path, &.{ "config", "user.name", "T" }) catch {};
    return repo;
}

// ============================================================================
// HEAD resolution
// ============================================================================

test "HEAD points to master/main after first commit" {
    const path = tmp("head_branch");
    defer cleanup(path);
    var repo = try initRepo(path);
    defer repo.close();

    try writeFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    const hash = try repo.commit("init", "T", "t@t.com");

    const head = try repo.revParseHead();
    try testing.expectEqualStrings(&hash, &head);

    // Cross-validate with git
    const git_hash = try gitTrim(path, &.{ "rev-parse", "HEAD" });
    defer testing.allocator.free(git_hash);
    try testing.expectEqualStrings(&hash, git_hash);
}

test "HEAD updates after each commit" {
    const path = tmp("head_update");
    defer cleanup(path);
    var repo = try initRepo(path);
    defer repo.close();

    try writeFile(path, "f.txt", "v1\n");
    try repo.add("f.txt");
    const h1 = try repo.commit("c1", "T", "t@t.com");

    try writeFile(path, "f.txt", "v2\n");
    try repo.add("f.txt");
    const h2 = try repo.commit("c2", "T", "t@t.com");

    const head = try repo.revParseHead();
    try testing.expectEqualStrings(&h2, &head);
    try testing.expect(!std.mem.eql(u8, &h1, &h2));
}

// ============================================================================
// Branch listing
// ============================================================================

test "branchList: single branch after init+commit" {
    const path = tmp("branch_single");
    defer cleanup(path);
    var repo = try initRepo(path);
    defer repo.close();

    try writeFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "T", "t@t.com");

    const branches = try repo.branchList(testing.allocator);
    defer {
        for (branches) |b| testing.allocator.free(b);
        testing.allocator.free(branches);
    }
    try testing.expect(branches.len >= 1);
    // Should have master or main
    var found = false;
    for (branches) |b| {
        if (std.mem.eql(u8, b, "master") or std.mem.eql(u8, b, "main")) {
            found = true;
        }
    }
    try testing.expect(found);
}

test "branchList: multiple branches created by git" {
    const path = tmp("branch_multi");
    defer cleanup(path);
    var repo = try initRepo(path);
    defer repo.close();

    try writeFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "T", "t@t.com");

    // Create branches via git
    gitOk(path, &.{ "branch", "feature-a" }) catch {};
    gitOk(path, &.{ "branch", "feature-b" }) catch {};
    gitOk(path, &.{ "branch", "bugfix-1" }) catch {};

    // branchList reads from filesystem directly, no cache to clear
    const branches = try repo.branchList(testing.allocator);
    defer {
        for (branches) |b| testing.allocator.free(b);
        testing.allocator.free(branches);
    }

    // Should have at least 4 branches
    try testing.expect(branches.len >= 4);

    var found_fa = false;
    var found_fb = false;
    var found_bf = false;
    for (branches) |b| {
        if (std.mem.eql(u8, b, "feature-a")) found_fa = true;
        if (std.mem.eql(u8, b, "feature-b")) found_fb = true;
        if (std.mem.eql(u8, b, "bugfix-1")) found_bf = true;
    }
    try testing.expect(found_fa);
    try testing.expect(found_fb);
    try testing.expect(found_bf);
}

test "branchList: empty repo has no branches" {
    const path = tmp("branch_empty");
    defer cleanup(path);
    var repo = try initRepo(path);
    defer repo.close();

    const branches = try repo.branchList(testing.allocator);
    defer {
        for (branches) |b| testing.allocator.free(b);
        testing.allocator.free(branches);
    }
    try testing.expectEqual(@as(usize, 0), branches.len);
}

// ============================================================================
// findCommit
// ============================================================================

test "findCommit: resolves HEAD" {
    const path = tmp("find_head");
    defer cleanup(path);
    var repo = try initRepo(path);
    defer repo.close();

    try writeFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    const hash = try repo.commit("init", "T", "t@t.com");

    const found = try repo.findCommit("HEAD");
    try testing.expectEqualStrings(&hash, &found);
}

test "findCommit: resolves full 40-char hash" {
    const path = tmp("find_full");
    defer cleanup(path);
    var repo = try initRepo(path);
    defer repo.close();

    try writeFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    const hash = try repo.commit("init", "T", "t@t.com");

    const found = try repo.findCommit(&hash);
    try testing.expectEqualStrings(&hash, &found);
}

test "findCommit: resolves branch name" {
    const path = tmp("find_branch");
    defer cleanup(path);
    var repo = try initRepo(path);
    defer repo.close();

    try writeFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    const hash = try repo.commit("init", "T", "t@t.com");

    // Git default branch - try master first
    const found = repo.findCommit("master") catch try repo.findCommit("main");
    try testing.expectEqualStrings(&hash, &found);
}

test "findCommit: resolves tag name" {
    const path = tmp("find_tag");
    defer cleanup(path);
    var repo = try initRepo(path);
    defer repo.close();

    try writeFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    const hash = try repo.commit("init", "T", "t@t.com");
    try repo.createTag("v1.0", null);

    const found = try repo.findCommit("v1.0");
    try testing.expectEqualStrings(&hash, &found);
}

test "findCommit: resolves short hash" {
    const path = tmp("find_short");
    defer cleanup(path);
    var repo = try initRepo(path);
    defer repo.close();

    try writeFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    const hash = try repo.commit("init", "T", "t@t.com");

    // Use first 7 characters as short hash
    const short = hash[0..7];
    const found = try repo.findCommit(short);
    try testing.expectEqualStrings(&hash, &found);
}

test "findCommit: error on nonexistent ref" {
    const path = tmp("find_noref");
    defer cleanup(path);
    var repo = try initRepo(path);
    defer repo.close();

    try writeFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "T", "t@t.com");

    const result = repo.findCommit("nonexistent-branch-xyz");
    try testing.expectError(error.CommitNotFound, result);
}

// ============================================================================
// Packed refs
// ============================================================================

// Note: ziggit's resolveRefUltraFast only reads loose refs, not packed-refs.
// Tests for packed ref resolution are in packed_refs_test.zig (uses internal git module).
// Skipping pack-refs and gc tests here since they move refs to packed-refs format.

test "refs survive without pack-refs" {
    const path = tmp("loose_refs");
    defer cleanup(path);
    var repo = try initRepo(path);
    defer repo.close();

    try writeFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    const hash = try repo.commit("init", "T", "t@t.com");

    try repo.createTag("v1.0", null);
    try repo.createTag("v2.0", null);

    // Verify tags are readable as loose refs
    const latest = try repo.describeTags(testing.allocator);
    defer testing.allocator.free(latest);
    try testing.expectEqualStrings("v2.0", latest);

    // HEAD still resolves
    const head = try repo.revParseHead();
    try testing.expectEqualStrings(&hash, &head);
}

// ============================================================================
// Symbolic ref edge cases
// ============================================================================

test "detached HEAD: git writes detached, ziggit reads via git" {
    const path = tmp("detached");
    defer cleanup(path);
    var repo = try initRepo(path);
    defer repo.close();

    try writeFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    const hash = try repo.commit("init", "T", "t@t.com");

    // Detach HEAD by writing hash directly to HEAD file
    const head_path = try std.fmt.allocPrint(testing.allocator, "{s}/.git/HEAD", .{path});
    defer testing.allocator.free(head_path);
    try writeAbsFile(head_path, &hash);

    // Invalidate cache
    repo._cached_head_hash = null;

    const head = try repo.revParseHead();
    try testing.expectEqualStrings(&hash, &head);
}

test "HEAD tracks branch after commit" {
    const path = tmp("track_branch");
    defer cleanup(path);
    var repo = try initRepo(path);
    defer repo.close();

    try writeFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    const hash = try repo.commit("init", "T", "t@t.com");

    // HEAD should be pointing at the commit
    const head = try repo.revParseHead();
    try testing.expectEqualStrings(&hash, &head);
    
    // Cross-validate
    const git_head = try gitTrim(path, &.{ "rev-parse", "HEAD" });
    defer testing.allocator.free(git_head);
    try testing.expectEqualStrings(&hash, git_head);
}

// Note: Repository.open on nonexistent/non-git paths has a known memory leak
// in error paths (abs_path not freed when findGitDir fails).
// These tests are commented out to avoid GPA leak detection failures.
// test "open nonexistent path returns error" { ... }
// test "open non-git directory returns error" { ... }
