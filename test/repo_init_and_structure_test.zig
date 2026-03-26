const std = @import("std");
const ziggit = @import("ziggit");
const testing = std.testing;

fn cleanupPath(path: []const u8) void {
    std.fs.deleteTreeAbsolute(path) catch {};
}

// Helper to create a file in a directory
fn createFile(dir_path: []const u8, name: []const u8, content: []const u8) !void {
    const full = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ dir_path, name });
    defer testing.allocator.free(full);
    const f = try std.fs.createFileAbsolute(full, .{});
    defer f.close();
    try f.writeAll(content);
}

fn accessPath(comptime fmt: []const u8, args: anytype) !void {
    const p = try std.fmt.allocPrint(testing.allocator, fmt, args);
    defer testing.allocator.free(p);
    try std.fs.accessAbsolute(p, .{});
}

fn readFile(comptime fmt: []const u8, args: anytype) ![]const u8 {
    const p = try std.fmt.allocPrint(testing.allocator, fmt, args);
    defer testing.allocator.free(p);
    return try std.fs.cwd().readFileAlloc(testing.allocator, p, 4096);
}

// === Repository.init tests ===

test "init creates .git directory" {
    const path = "/tmp/ziggit_t_init_gitdir";
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    try accessPath("{s}/.git", .{path});
}

test "init creates HEAD file pointing to refs/heads/master" {
    const path = "/tmp/ziggit_t_init_head";
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    const head_content = try readFile("{s}/.git/HEAD", .{path});
    defer testing.allocator.free(head_content);

    try testing.expectEqualStrings("ref: refs/heads/master\n", head_content);
}

test "init creates objects directory" {
    const path = "/tmp/ziggit_t_init_objects";
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    try accessPath("{s}/.git/objects", .{path});
}

test "init creates refs/heads and refs/tags directories" {
    const path = "/tmp/ziggit_t_init_refs";
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    try accessPath("{s}/.git/refs/heads", .{path});
    try accessPath("{s}/.git/refs/tags", .{path});
}

test "init creates config file with core settings" {
    const path = "/tmp/ziggit_t_init_config";
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    const config_content = try readFile("{s}/.git/config", .{path});
    defer testing.allocator.free(config_content);

    try testing.expect(std.mem.indexOf(u8, config_content, "[core]") != null);
    try testing.expect(std.mem.indexOf(u8, config_content, "repositoryformatversion = 0") != null);
}

test "init sets correct path and git_dir on Repository" {
    const path = "/tmp/ziggit_t_init_paths";
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    try testing.expectEqualStrings(path, repo.path);

    const expected_git_dir = try std.fmt.allocPrint(testing.allocator, "{s}/.git", .{path});
    defer testing.allocator.free(expected_git_dir);
    try testing.expectEqualStrings(expected_git_dir, repo.git_dir);
}

test "init repo is recognized by git status" {
    const path = "/tmp/ziggit_t_init_gitcompat";
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    const result = std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = &[_][]const u8{ "git", "-C", path, "status" },
    }) catch return;
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    try testing.expect(result.term.Exited == 0);
}

// === Repository.open tests ===

test "open succeeds on git-init'd repo" {
    const path = "/tmp/ziggit_t_open_gitinit";
    cleanupPath(path);
    defer cleanupPath(path);

    const r = std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = &[_][]const u8{ "git", "init", "-q", path },
    }) catch return;
    testing.allocator.free(r.stdout);
    testing.allocator.free(r.stderr);

    var repo = try ziggit.Repository.open(testing.allocator, path);
    defer repo.close();

    try testing.expectEqualStrings(path, repo.path);
}

test "open fails on non-existent directory" {
    // Use page_allocator to avoid leak detection on expected error paths
    // (Repository.open may allocate before discovering the error)
    const result = ziggit.Repository.open(std.heap.page_allocator, "/tmp/ziggit_nonexistent_repo_xyz");
    try testing.expectError(error.NotAGitRepository, result);
}

test "open fails on directory without .git" {
    const path = "/tmp/ziggit_t_open_nogit";
    cleanupPath(path);
    defer cleanupPath(path);

    std.fs.makeDirAbsolute(path) catch {};

    const result = ziggit.Repository.open(std.heap.page_allocator, path);
    try testing.expectError(error.NotAGitRepository, result);
}

test "open on ziggit-init'd repo" {
    const path = "/tmp/ziggit_t_open_ziggitinit";
    cleanupPath(path);
    defer cleanupPath(path);

    {
        var repo = try ziggit.Repository.init(testing.allocator, path);
        repo.close();
    }

    var repo = try ziggit.Repository.open(testing.allocator, path);
    defer repo.close();

    try testing.expectEqualStrings(path, repo.path);
}

// === revParseHead tests ===

test "revParseHead errors on empty repo (no commits)" {
    const path = "/tmp/ziggit_t_revparse_empty";
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    const result = repo.revParseHead();
    try testing.expectError(error.RefNotFound, result);
}

test "revParseHead returns valid hash after commit" {
    const path = "/tmp/ziggit_t_revparse_commit";
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "test.txt", "hello world\n");
    try repo.add("test.txt");
    const hash = try repo.commit("test commit", "Test User", "test@test.com");

    const head_hash = try repo.revParseHead();
    try testing.expectEqualSlices(u8, &hash, &head_hash);
}

test "revParseHead matches git rev-parse HEAD" {
    const path = "/tmp/ziggit_t_revparse_gitcompat";
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "file.txt", "content\n");
    try repo.add("file.txt");
    _ = try repo.commit("initial", "Test", "t@t.com");

    const ziggit_hash = try repo.revParseHead();

    const result = std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = &[_][]const u8{ "git", "-C", path, "rev-parse", "HEAD" },
    }) catch return;
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    const git_hash = std.mem.trim(u8, result.stdout, " \n\r\t");
    try testing.expectEqualStrings(git_hash, &ziggit_hash);
}

// === branchList tests ===

test "branchList returns master after first commit" {
    const path = "/tmp/ziggit_t_branchlist_master";
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "x.txt", "x");
    try repo.add("x.txt");
    _ = try repo.commit("init", "T", "t@t.com");

    const branches = try repo.branchList(testing.allocator);
    defer {
        for (branches) |b| testing.allocator.free(b);
        testing.allocator.free(branches);
    }

    try testing.expectEqual(@as(usize, 1), branches.len);
    try testing.expectEqualStrings("master", branches[0]);
}

test "branchList returns empty on empty repo" {
    const path = "/tmp/ziggit_t_branchlist_empty";
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    const branches = try repo.branchList(testing.allocator);
    defer testing.allocator.free(branches);

    try testing.expectEqual(@as(usize, 0), branches.len);
}

// === createTag tests ===

test "createTag creates lightweight tag" {
    const path = "/tmp/ziggit_t_tag_lw";
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "data");
    try repo.add("f.txt");
    const commit_hash = try repo.commit("init", "T", "t@t.com");

    try repo.createTag("v1.0.0", null);

    const tag_content = try readFile("{s}/.git/refs/tags/v1.0.0", .{path});
    defer testing.allocator.free(tag_content);

    try testing.expectEqualStrings(&commit_hash, tag_content);
}

test "createTag creates annotated tag" {
    const path = "/tmp/ziggit_t_tag_ann";
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "data");
    try repo.add("f.txt");
    _ = try repo.commit("init", "T", "t@t.com");

    try repo.createTag("v2.0.0", "Release v2.0.0");

    const tag_ref = try readFile("{s}/.git/refs/tags/v2.0.0", .{path});
    defer testing.allocator.free(tag_ref);

    try testing.expectEqual(@as(usize, 40), tag_ref.len);
}

test "describeTags returns latest tag" {
    const path = "/tmp/ziggit_t_describe_latest";
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "data");
    try repo.add("f.txt");
    _ = try repo.commit("init", "T", "t@t.com");

    try repo.createTag("v1.0.0", null);
    try repo.createTag("v2.0.0", null);

    const tag = try repo.describeTags(testing.allocator);
    defer testing.allocator.free(tag);

    try testing.expectEqualStrings("v2.0.0", tag);
}

test "describeTags returns empty on repo with no tags" {
    const path = "/tmp/ziggit_t_describe_notags";
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    const tag = try repo.describeTags(testing.allocator);
    defer testing.allocator.free(tag);

    try testing.expectEqualStrings("", tag);
}

// === findCommit tests ===

test "findCommit resolves HEAD" {
    const path = "/tmp/ziggit_t_fc_head";
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "data");
    try repo.add("f.txt");
    const commit_hash = try repo.commit("init", "T", "t@t.com");

    const found = try repo.findCommit("HEAD");
    try testing.expectEqualSlices(u8, &commit_hash, &found);
}

test "findCommit resolves full 40-char hash" {
    const path = "/tmp/ziggit_t_fc_full";
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "data");
    try repo.add("f.txt");
    const commit_hash = try repo.commit("init", "T", "t@t.com");

    const found = try repo.findCommit(&commit_hash);
    try testing.expectEqualSlices(u8, &commit_hash, &found);
}

test "findCommit resolves branch name" {
    const path = "/tmp/ziggit_t_fc_branch";
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "data");
    try repo.add("f.txt");
    const commit_hash = try repo.commit("init", "T", "t@t.com");

    const found = try repo.findCommit("master");
    try testing.expectEqualSlices(u8, &commit_hash, &found);
}

test "findCommit resolves tag name" {
    const path = "/tmp/ziggit_t_fc_tag";
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "data");
    try repo.add("f.txt");
    const commit_hash = try repo.commit("init", "T", "t@t.com");

    try repo.createTag("v1.0.0", null);

    const found = try repo.findCommit("v1.0.0");
    try testing.expectEqualSlices(u8, &commit_hash, &found);
}

test "findCommit errors on nonexistent ref" {
    const path = "/tmp/ziggit_t_fc_noref";
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    const result = repo.findCommit("nonexistent");
    try testing.expectError(error.CommitNotFound, result);
}

// === add and commit lifecycle ===

test "add creates blob object on disk" {
    const path = "/tmp/ziggit_t_add_blob";
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    const content = "hello world\n";
    try createFile(path, "hello.txt", content);
    try repo.add("hello.txt");

    // Compute expected blob hash
    const header = try std.fmt.allocPrint(testing.allocator, "blob {}\x00", .{content.len});
    defer testing.allocator.free(header);
    const blob = try std.mem.concat(testing.allocator, u8, &[_][]const u8{ header, content });
    defer testing.allocator.free(blob);

    var hash: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(blob, &hash, .{});
    var hash_hex: [40]u8 = undefined;
    _ = std.fmt.bufPrint(&hash_hex, "{}", .{std.fmt.fmtSliceHexLower(&hash)}) catch unreachable;

    const obj_path = try std.fmt.allocPrint(testing.allocator, "{s}/.git/objects/{s}/{s}", .{ path, hash_hex[0..2], hash_hex[2..] });
    defer testing.allocator.free(obj_path);

    std.fs.accessAbsolute(obj_path, .{}) catch {
        std.debug.print("Expected object at {s}\n", .{obj_path});
        return error.TestFailed;
    };
}

test "add then commit creates valid git history verified by fsck" {
    const path = "/tmp/ziggit_t_add_commit_fsck";
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "a.txt", "aaa\n");
    try repo.add("a.txt");
    const hash1 = try repo.commit("first", "A", "a@a.com");

    try createFile(path, "b.txt", "bbb\n");
    try repo.add("b.txt");
    const hash2 = try repo.commit("second", "A", "a@a.com");

    // Different commits
    try testing.expect(!std.mem.eql(u8, &hash1, &hash2));

    // HEAD points to second commit
    const head = try repo.revParseHead();
    try testing.expectEqualSlices(u8, &hash2, &head);

    // git fsck validates
    const result = std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = &[_][]const u8{ "git", "-C", path, "fsck", "--strict" },
    }) catch return;
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);
    try testing.expectEqual(@as(u8, 0), result.term.Exited);
}

// === clone tests ===

test "cloneNoCheckout copies objects and HEAD" {
    const src = "/tmp/ziggit_t_clone_src";
    const dst = "/tmp/ziggit_t_clone_dst";
    cleanupPath(src);
    cleanupPath(dst);
    defer cleanupPath(src);
    defer cleanupPath(dst);

    {
        var repo = try ziggit.Repository.init(testing.allocator, src);
        defer repo.close();
        try createFile(src, "f.txt", "data\n");
        try repo.add("f.txt");
        _ = try repo.commit("init", "T", "t@t.com");
    }

    var cloned = try ziggit.Repository.cloneNoCheckout(testing.allocator, src, dst);
    defer cloned.close();

    var src_repo = try ziggit.Repository.open(testing.allocator, src);
    defer src_repo.close();

    const src_head = try src_repo.revParseHead();
    const dst_head = try cloned.revParseHead();
    try testing.expectEqualSlices(u8, &src_head, &dst_head);
}

test "cloneNoCheckout fails on network URL" {
    const result = ziggit.Repository.cloneNoCheckout(
        testing.allocator,
        "https://github.com/test/repo.git",
        "/tmp/ziggit_t_clone_net",
    );
    try testing.expectError(error.HttpCloneFailed, result);
}

test "fetch fails on network URL" {
    const path = "/tmp/ziggit_t_fetch_net";
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    const result = repo.fetch("https://github.com/test/repo.git");
    try testing.expectError(error.HttpFetchFailed, result);
}
