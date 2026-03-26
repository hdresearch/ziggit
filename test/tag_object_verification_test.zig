// test/tag_object_verification_test.zig
// Thorough tests for tag creation (lightweight and annotated) with git cross-validation
const std = @import("std");
const ziggit = @import("ziggit");
const testing = std.testing;

fn tmp(comptime suffix: []const u8) []const u8 {
    return "/tmp/ziggit_tag_verify_" ++ suffix;
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

fn readFileContent(path: []const u8) ![]u8 {
    const f = try std.fs.openFileAbsolute(path, .{});
    defer f.close();
    return try f.readToEndAlloc(testing.allocator, 1024 * 1024);
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
    gitOk(path, &.{ "config", "user.email", "test@test.com" }) catch {};
    gitOk(path, &.{ "config", "user.name", "Test" }) catch {};
    return repo;
}

// ============================================================================
// Lightweight tag tests
// ============================================================================

test "lightweight tag: git tag -l shows it" {
    const path = tmp("lw_list");
    defer cleanup(path);
    var repo = try initRepo(path);
    defer repo.close();

    try writeFile(path, "file.txt", "content\n");
    try repo.add("file.txt");
    _ = try repo.commit("first", "Test", "test@test.com");
    try repo.createTag("v1.0.0", null);

    const tags = try gitTrim(path, &.{ "tag", "-l" });
    defer testing.allocator.free(tags);
    try testing.expectEqualStrings("v1.0.0", tags);
}

test "lightweight tag: ref file contains HEAD commit hash" {
    const path = tmp("lw_ref");
    defer cleanup(path);
    var repo = try initRepo(path);
    defer repo.close();

    try writeFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    const commit_hash = try repo.commit("init", "Test", "test@test.com");

    try repo.createTag("v0.1.0", null);

    const tag_ref_path = try std.fmt.allocPrint(testing.allocator, "{s}/.git/refs/tags/v0.1.0", .{path});
    defer testing.allocator.free(tag_ref_path);
    const tag_content = try readFileContent(tag_ref_path);
    defer testing.allocator.free(tag_content);

    try testing.expectEqualStrings(&commit_hash, std.mem.trim(u8, tag_content, " \n\r\t"));
}

test "lightweight tag: git show resolves to correct commit" {
    const path = tmp("lw_show");
    defer cleanup(path);
    var repo = try initRepo(path);
    defer repo.close();

    try writeFile(path, "a.txt", "aaa\n");
    try repo.add("a.txt");
    const commit_hash = try repo.commit("c1", "Test", "test@test.com");
    try repo.createTag("release-1", null);

    const git_hash = try gitTrim(path, &.{ "rev-parse", "release-1" });
    defer testing.allocator.free(git_hash);
    try testing.expectEqualStrings(&commit_hash, git_hash);
}

test "lightweight tag: multiple tags on same commit" {
    const path = tmp("lw_multi");
    defer cleanup(path);
    var repo = try initRepo(path);
    defer repo.close();

    try writeFile(path, "x.txt", "x\n");
    try repo.add("x.txt");
    _ = try repo.commit("init", "Test", "test@test.com");
    try repo.createTag("alpha", null);
    try repo.createTag("beta", null);
    try repo.createTag("gamma", null);

    const tags = try gitTrim(path, &.{ "tag", "-l" });
    defer testing.allocator.free(tags);
    // Should contain all three
    try testing.expect(std.mem.indexOf(u8, tags, "alpha") != null);
    try testing.expect(std.mem.indexOf(u8, tags, "beta") != null);
    try testing.expect(std.mem.indexOf(u8, tags, "gamma") != null);
}

test "lightweight tag: describeTags returns latest (lexicographic)" {
    const path = tmp("lw_describe");
    defer cleanup(path);
    var repo = try initRepo(path);
    defer repo.close();

    try writeFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "Test", "test@test.com");
    try repo.createTag("v1.0.0", null);
    try repo.createTag("v2.0.0", null);
    try repo.createTag("v0.5.0", null);

    const latest = try repo.describeTags(testing.allocator);
    defer testing.allocator.free(latest);
    try testing.expectEqualStrings("v2.0.0", latest);
}

// ============================================================================
// Annotated tag tests
// ============================================================================

test "annotated tag: creates tag object" {
    const path = tmp("ann_obj");
    defer cleanup(path);
    var repo = try initRepo(path);
    defer repo.close();

    try writeFile(path, "file.txt", "hello\n");
    try repo.add("file.txt");
    _ = try repo.commit("first", "Test", "test@test.com");
    try repo.createTag("v1.0.0", "Release 1.0.0");

    // Tag ref should point to a tag object, not directly to commit
    const tag_type = try gitTrim(path, &.{ "cat-file", "-t", "v1.0.0" });
    defer testing.allocator.free(tag_type);
    try testing.expectEqualStrings("tag", tag_type);
}

test "annotated tag: tag object contains message" {
    const path = tmp("ann_msg");
    defer cleanup(path);
    var repo = try initRepo(path);
    defer repo.close();

    try writeFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "Test", "test@test.com");
    try repo.createTag("v2.0.0", "Major release");

    const tag_content = try gitTrim(path, &.{ "cat-file", "-p", "v2.0.0" });
    defer testing.allocator.free(tag_content);
    try testing.expect(std.mem.indexOf(u8, tag_content, "Major release") != null);
}

test "annotated tag: tag object references correct commit" {
    const path = tmp("ann_ref");
    defer cleanup(path);
    var repo = try initRepo(path);
    defer repo.close();

    try writeFile(path, "f.txt", "data\n");
    try repo.add("f.txt");
    const commit_hash = try repo.commit("c1", "Test", "test@test.com");
    try repo.createTag("v3.0.0", "Third");

    const tag_content = try gitTrim(path, &.{ "cat-file", "-p", "v3.0.0" });
    defer testing.allocator.free(tag_content);
    // Tag object should have "object <commit_hash>"
    try testing.expect(std.mem.indexOf(u8, tag_content, &commit_hash) != null);
}

test "annotated tag: git tag -v shows tag name" {
    const path = tmp("ann_name");
    defer cleanup(path);
    var repo = try initRepo(path);
    defer repo.close();

    try writeFile(path, "f.txt", "y\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "Test", "test@test.com");
    try repo.createTag("my-tag", "Tag message");

    const tag_content = try gitTrim(path, &.{ "cat-file", "-p", "my-tag" });
    defer testing.allocator.free(tag_content);
    try testing.expect(std.mem.indexOf(u8, tag_content, "tag my-tag") != null);
}

test "annotated tag: git rev-parse derefs to commit" {
    const path = tmp("ann_deref");
    defer cleanup(path);
    var repo = try initRepo(path);
    defer repo.close();

    try writeFile(path, "f.txt", "z\n");
    try repo.add("f.txt");
    const commit_hash = try repo.commit("init", "Test", "test@test.com");
    try repo.createTag("v1.0", "Release");

    // v1.0^{} dereferences annotated tag to the commit
    const deref = try gitTrim(path, &.{ "rev-parse", "v1.0^{}" });
    defer testing.allocator.free(deref);
    try testing.expectEqualStrings(&commit_hash, deref);
}

test "annotated tag: passes git fsck" {
    const path = tmp("ann_fsck");
    defer cleanup(path);
    var repo = try initRepo(path);
    defer repo.close();

    try writeFile(path, "f.txt", "content\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "Test", "test@test.com");
    try repo.createTag("v1.0.0", "First release");
    try repo.createTag("v1.1.0", null); // lightweight
    try repo.createTag("v2.0.0", "Second release");

    // git fsck validates all objects including tag objects
    gitOk(path, &.{ "fsck", "--strict" }) catch |err| {
        std.debug.print("git fsck failed after creating tags\n", .{});
        return err;
    };
}

// ============================================================================
// Tag interaction with commits
// ============================================================================

test "tag on first commit, then second commit changes HEAD but not tag" {
    const path = tmp("tag_head");
    defer cleanup(path);
    var repo = try initRepo(path);
    defer repo.close();

    try writeFile(path, "f.txt", "v1\n");
    try repo.add("f.txt");
    const c1 = try repo.commit("first", "Test", "test@test.com");
    try repo.createTag("v1.0", null);

    try writeFile(path, "f.txt", "v2\n");
    try repo.add("f.txt");
    const c2 = try repo.commit("second", "Test", "test@test.com");

    // HEAD should be c2
    const head = try repo.revParseHead();
    try testing.expectEqualStrings(&c2, &head);

    // Tag should still point to c1
    const tag_hash = try gitTrim(path, &.{ "rev-parse", "v1.0" });
    defer testing.allocator.free(tag_hash);
    try testing.expectEqualStrings(&c1, tag_hash);
}

test "tags on different commits" {
    const path = tmp("tag_diff");
    defer cleanup(path);
    var repo = try initRepo(path);
    defer repo.close();

    try writeFile(path, "f.txt", "v1\n");
    try repo.add("f.txt");
    const c1 = try repo.commit("first", "Test", "test@test.com");
    try repo.createTag("v1.0", null);

    try writeFile(path, "f.txt", "v2\n");
    try repo.add("f.txt");
    const c2 = try repo.commit("second", "Test", "test@test.com");
    try repo.createTag("v2.0", null);

    const t1 = try gitTrim(path, &.{ "rev-parse", "v1.0" });
    defer testing.allocator.free(t1);
    const t2 = try gitTrim(path, &.{ "rev-parse", "v2.0" });
    defer testing.allocator.free(t2);

    try testing.expectEqualStrings(&c1, t1);
    try testing.expectEqualStrings(&c2, t2);
    // They must be different
    try testing.expect(!std.mem.eql(u8, t1, t2));
}

test "describeTags updates after creating new tag" {
    const path = tmp("tag_update");
    defer cleanup(path);
    var repo = try initRepo(path);
    defer repo.close();

    try writeFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "Test", "test@test.com");

    // No tags yet
    const empty = try repo.describeTags(testing.allocator);
    defer testing.allocator.free(empty);
    try testing.expectEqualStrings("", empty);

    // Create first tag
    try repo.createTag("v1.0.0", null);
    const first = try repo.describeTags(testing.allocator);
    defer testing.allocator.free(first);
    try testing.expectEqualStrings("v1.0.0", first);

    // Create later tag
    try repo.createTag("v2.0.0", null);
    const second = try repo.describeTags(testing.allocator);
    defer testing.allocator.free(second);
    try testing.expectEqualStrings("v2.0.0", second);
}

test "latestTag is alias for describeTags" {
    const path = tmp("tag_alias");
    defer cleanup(path);
    var repo = try initRepo(path);
    defer repo.close();

    try writeFile(path, "f.txt", "x\n");
    try repo.add("f.txt");
    _ = try repo.commit("init", "Test", "test@test.com");
    try repo.createTag("v5.0.0", null);

    const d = try repo.describeTags(testing.allocator);
    defer testing.allocator.free(d);
    const l = try repo.latestTag(testing.allocator);
    defer testing.allocator.free(l);
    try testing.expectEqualStrings(d, l);
}
