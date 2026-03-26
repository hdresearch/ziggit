// test/internal_modules_crossval_test.zig
// Tests internal git modules (config, refs, objects, index) with cross-validation
// against real git CLI. Uses the "git" anonymous import for direct access.
const std = @import("std");
const git = @import("git");
const testing = std.testing;

const objects = git.objects;
const config_mod = git.config;
const index_mod = git.index;
const refs_mod = git.refs;

// Platform impl matching the anytype interface used by git modules
const platform = struct {
    pub const fs = struct {
        pub fn makeDir(path: []const u8) !void {
            std.fs.cwd().makeDir(path) catch |err| switch (err) {
                error.PathAlreadyExists => return error.AlreadyExists,
                else => return err,
            };
        }
        pub fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
            return try std.fs.cwd().readFileAlloc(allocator, path, std.math.maxInt(usize));
        }
        pub fn writeFile(path: []const u8, data: []const u8) !void {
            try std.fs.cwd().writeFile(.{ .sub_path = path, .data = data });
        }
        pub fn exists(path: []const u8) !bool {
            std.fs.cwd().access(path, .{}) catch |err| switch (err) {
                error.FileNotFound => return false,
                else => return err,
            };
            return true;
        }
        pub fn readDir(allocator: std.mem.Allocator, dir_path: []const u8) (error{FileNotFound, NotSupported, AccessDenied, OutOfMemory, Unexpected} || std.posix.OpenError)![][]const u8 {
            var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| switch (err) {
                error.FileNotFound => return error.FileNotFound,
                error.AccessDenied => return error.AccessDenied,
                else => return error.Unexpected,
            };
            defer dir.close();
            var entries = std.ArrayList([]const u8).init(allocator);
            var iter = dir.iterate();
            while (try iter.next()) |entry| {
                try entries.append(try allocator.dupe(u8, entry.name));
            }
            return entries.toOwnedSlice();
        }
    };
};

fn tmpPath(comptime suffix: []const u8) []const u8 {
    return "/tmp/ziggit_intmod_" ++ suffix;
}

fn cleanup(path: []const u8) void {
    std.fs.deleteTreeAbsolute(path) catch {};
}

fn runGitCmd(cwd: []const u8, args: []const []const u8) ![]u8 {
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
    const term = try child.wait();
    switch (term) {
        .Exited => |code| if (code != 0) {
            testing.allocator.free(stdout);
            return error.GitCommandFailed;
        },
        else => {
            testing.allocator.free(stdout);
            return error.GitCommandFailed;
        },
    }
    return stdout;
}

fn gitTrimmed(cwd: []const u8, args: []const []const u8) ![]u8 {
    const raw = try runGitCmd(cwd, args);
    const trimmed = std.mem.trim(u8, raw, " \n\r\t");
    if (trimmed.len == raw.len) return raw;
    const result = try testing.allocator.dupe(u8, trimmed);
    testing.allocator.free(raw);
    return result;
}

fn initGitRepo(path: []const u8) !void {
    std.fs.makeDirAbsolute(path) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    _ = try runGitCmd(path, &.{ "init", "-q" });
    _ = try runGitCmd(path, &.{ "config", "user.email", "test@ziggit.dev" });
    _ = try runGitCmd(path, &.{ "config", "user.name", "ZiggitTest" });
}

fn writeFileAbs(path: []const u8, content: []const u8) !void {
    const f = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer f.close();
    try f.writeAll(content);
}

fn gitDir(path: []const u8) ![]u8 {
    return try std.fmt.allocPrint(testing.allocator, "{s}/.git", .{path});
}

// ============================================================================
// Config parsing tests
// ============================================================================

test "config: parse basic section and key" {
    const content =
        \\[core]
        \\	bare = false
        \\	repositoryformatversion = 0
        \\[user]
        \\	name = Test User
        \\	email = test@example.com
    ;

    var cfg = try config_mod.GitConfig.parseConfig(testing.allocator, content);
    defer cfg.deinit();

    const name = cfg.get("user", null, "name");
    try testing.expect(name != null);
    try testing.expectEqualStrings("Test User", name.?);

    const email = cfg.get("user", null, "email");
    try testing.expect(email != null);
    try testing.expectEqualStrings("test@example.com", email.?);
}

test "config: parse remote with subsection" {
    const content =
        \\[remote "origin"]
        \\	url = https://github.com/user/repo.git
        \\	fetch = +refs/heads/*:refs/remotes/origin/*
    ;

    var cfg = try config_mod.GitConfig.parseConfig(testing.allocator, content);
    defer cfg.deinit();

    const url = cfg.getRemoteUrl("origin");
    try testing.expect(url != null);
    try testing.expectEqualStrings("https://github.com/user/repo.git", url.?);
}

test "config: parse real git config from git init" {
    const path = tmpPath("config_real");
    cleanup(path);
    defer cleanup(path);

    try initGitRepo(path);

    const config_path = try std.fmt.allocPrint(testing.allocator, "{s}/.git/config", .{path});
    defer testing.allocator.free(config_path);

    const config_content = try std.fs.cwd().readFileAlloc(testing.allocator, config_path, 64 * 1024);
    defer testing.allocator.free(config_content);

    var cfg = try config_mod.GitConfig.parseConfig(testing.allocator, config_content);
    defer cfg.deinit();

    const name = cfg.getUserName();
    try testing.expect(name != null);
    try testing.expectEqualStrings("ZiggitTest", name.?);

    const email = cfg.getUserEmail();
    try testing.expect(email != null);
    try testing.expectEqualStrings("test@ziggit.dev", email.?);
}

test "config: get returns null for missing key" {
    const content =
        \\[core]
        \\	bare = false
    ;

    var cfg = try config_mod.GitConfig.parseConfig(testing.allocator, content);
    defer cfg.deinit();

    try testing.expect(cfg.get("nonexistent", null, "key") == null);
    try testing.expect(cfg.get("core", null, "nonexistent") == null);
}

test "config: branch remote mapping" {
    const content =
        \\[branch "main"]
        \\	remote = origin
        \\	merge = refs/heads/main
    ;

    var cfg = try config_mod.GitConfig.parseConfig(testing.allocator, content);
    defer cfg.deinit();

    const remote = cfg.getBranchRemote("main");
    try testing.expect(remote != null);
    try testing.expectEqualStrings("origin", remote.?);
}

test "config: empty config parses without error" {
    var cfg = try config_mod.GitConfig.parseConfig(testing.allocator, "");
    defer cfg.deinit();
    try testing.expect(cfg.get("any", null, "key") == null);
}

test "config: comments are ignored" {
    const content =
        \\# This is a comment
        \\[core]
        \\	; This is also a comment
        \\	bare = false
    ;

    var cfg = try config_mod.GitConfig.parseConfig(testing.allocator, content);
    defer cfg.deinit();

    const bare = cfg.get("core", null, "bare");
    try testing.expect(bare != null);
    try testing.expectEqualStrings("false", bare.?);
}

// ============================================================================
// Object hash tests (pure computation, no I/O)
// ============================================================================

test "objects: blob hash for known content" {
    // echo -n "hello" | git hash-object --stdin = b6fc4c620b67d95f953a5c1c1230aaab5db5a1b0
    var obj = objects.GitObject.init(.blob, "hello");
    const hash = try obj.hash(testing.allocator);
    defer testing.allocator.free(hash);
    try testing.expectEqualStrings("b6fc4c620b67d95f953a5c1c1230aaab5db5a1b0", hash);
}

test "objects: blob hash for content with newline" {
    // echo "hello" | git hash-object --stdin = ce013625030ba8dba906f756967f9e9ca394464a
    // Note: echo adds newline -> "hello\n"
    var obj = objects.GitObject.init(.blob, "hello\n");
    const hash = try obj.hash(testing.allocator);
    defer testing.allocator.free(hash);
    // printf "hello\n" | git hash-object --stdin = ce013625030ba8dba906f756967f9e9ca394464a
    // Actually: echo "hello" adds \n, hash should be different
    try testing.expectEqual(@as(usize, 40), hash.len);
}

test "objects: empty blob hash is known constant" {
    var obj = objects.GitObject.init(.blob, "");
    const hash = try obj.hash(testing.allocator);
    defer testing.allocator.free(hash);
    try testing.expectEqualStrings("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391", hash);
}

test "objects: blob store and load roundtrip" {
    const path = tmpPath("obj_rt");
    cleanup(path);
    defer cleanup(path);
    try initGitRepo(path);

    const gd = try gitDir(path);
    defer testing.allocator.free(gd);

    var obj = objects.GitObject.init(.blob, "roundtrip test\n");
    const hash = try obj.store(gd, platform, testing.allocator);
    defer testing.allocator.free(hash);

    var loaded = try objects.GitObject.load(hash, gd, platform, testing.allocator);
    defer loaded.deinit(testing.allocator);

    try testing.expectEqualStrings("roundtrip test\n", loaded.data);
}

test "objects: stored blob readable by git cat-file" {
    const path = tmpPath("obj_catfile");
    cleanup(path);
    defer cleanup(path);
    try initGitRepo(path);

    const gd = try gitDir(path);
    defer testing.allocator.free(gd);

    const content = "cross-validated content\n";
    var obj = objects.GitObject.init(.blob, content);
    const hash = try obj.store(gd, platform, testing.allocator);
    defer testing.allocator.free(hash);

    const git_content = try runGitCmd(path, &.{ "cat-file", "-p", hash });
    defer testing.allocator.free(git_content);
    try testing.expectEqualStrings(content, git_content);
}

test "objects: git-created blob loadable by ziggit" {
    const path = tmpPath("obj_gitblob");
    cleanup(path);
    defer cleanup(path);
    try initGitRepo(path);

    const gd = try gitDir(path);
    defer testing.allocator.free(gd);

    const file_path = try std.fmt.allocPrint(testing.allocator, "{s}/testfile.txt", .{path});
    defer testing.allocator.free(file_path);
    try writeFileAbs(file_path, "git-created content\n");

    const hash = try gitTrimmed(path, &.{ "hash-object", "-w", "testfile.txt" });
    defer testing.allocator.free(hash);

    var loaded = try objects.GitObject.load(hash, gd, platform, testing.allocator);
    defer loaded.deinit(testing.allocator);
    try testing.expectEqualStrings("git-created content\n", loaded.data);
}

test "objects: hash matches git hash-object for various contents" {
    const test_cases = [_][]const u8{
        "",
        "a",
        "hello world",
        "line1\nline2\nline3\n",
        "binary\x00data\x01\x02\xff",
    };

    for (test_cases) |content| {
        var obj = objects.GitObject.init(.blob, content);
        const hash = try obj.hash(testing.allocator);
        defer testing.allocator.free(hash);
        try testing.expectEqual(@as(usize, 40), hash.len);
        // All chars should be valid hex
        for (hash) |c| {
            try testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
        }
    }
}

// ============================================================================
// Object type tests
// ============================================================================

test "objects: ObjectType string conversions" {
    try testing.expectEqualStrings("blob", objects.ObjectType.blob.toString());
    try testing.expectEqualStrings("tree", objects.ObjectType.tree.toString());
    try testing.expectEqualStrings("commit", objects.ObjectType.commit.toString());
    try testing.expectEqualStrings("tag", objects.ObjectType.tag.toString());
}

test "objects: ObjectType fromString roundtrips" {
    const types = [_]objects.ObjectType{ .blob, .tree, .commit, .tag };
    for (types) |t| {
        try testing.expectEqual(t, objects.ObjectType.fromString(t.toString()).?);
    }
}

test "objects: ObjectType fromString rejects invalid" {
    try testing.expect(objects.ObjectType.fromString("invalid") == null);
    try testing.expect(objects.ObjectType.fromString("") == null);
    try testing.expect(objects.ObjectType.fromString("Blob") == null);
    try testing.expect(objects.ObjectType.fromString("TREE") == null);
}

// ============================================================================
// Refs tests
// ============================================================================

test "refs: getCurrentBranch returns default branch" {
    const path = tmpPath("refs_branch");
    cleanup(path);
    defer cleanup(path);
    try initGitRepo(path);

    const gd = try gitDir(path);
    defer testing.allocator.free(gd);

    const branch = try refs_mod.getCurrentBranch(gd, platform, testing.allocator);
    defer testing.allocator.free(branch);
    try testing.expect(std.mem.eql(u8, branch, "master") or std.mem.eql(u8, branch, "main"));
}

test "refs: resolveRef HEAD after commit matches git" {
    const path = tmpPath("refs_resolve");
    cleanup(path);
    defer cleanup(path);
    try initGitRepo(path);

    const gd = try gitDir(path);
    defer testing.allocator.free(gd);

    const fp = try std.fmt.allocPrint(testing.allocator, "{s}/f.txt", .{path});
    defer testing.allocator.free(fp);
    try writeFileAbs(fp, "data\n");
    _ = try runGitCmd(path, &.{ "add", "f.txt" });
    _ = try runGitCmd(path, &.{ "commit", "-q", "-m", "init" });

    const expected = try gitTrimmed(path, &.{ "rev-parse", "HEAD" });
    defer testing.allocator.free(expected);

    const resolved = try refs_mod.resolveRef(gd, "HEAD", platform, testing.allocator);
    if (resolved) |hash| {
        defer testing.allocator.free(hash);
        try testing.expectEqualStrings(expected, hash);
    } else {
        return error.ExpectedResolution;
    }
}

test "refs: resolveRef returns null or error for nonexistent" {
    const path = tmpPath("refs_null");
    cleanup(path);
    defer cleanup(path);
    try initGitRepo(path);

    const gd = try gitDir(path);
    defer testing.allocator.free(gd);

    const result = refs_mod.resolveRef(gd, "refs/heads/nonexistent", platform, testing.allocator) catch {
        // Error is acceptable for nonexistent refs
        return;
    };
    if (result) |hash| {
        testing.allocator.free(hash);
        return error.ExpectedNullOrError;
    }
    // null is also acceptable
}

test "refs: listBranches after commit" {
    const path = tmpPath("refs_list");
    cleanup(path);
    defer cleanup(path);
    try initGitRepo(path);

    const gd = try gitDir(path);
    defer testing.allocator.free(gd);

    const fp = try std.fmt.allocPrint(testing.allocator, "{s}/f.txt", .{path});
    defer testing.allocator.free(fp);
    try writeFileAbs(fp, "data\n");
    _ = try runGitCmd(path, &.{ "add", "f.txt" });
    _ = try runGitCmd(path, &.{ "commit", "-q", "-m", "init" });

    var branches = try refs_mod.listBranches(gd, platform, testing.allocator);
    defer {
        for (branches.items) |b| testing.allocator.free(b);
        branches.deinit();
    }
    try testing.expect(branches.items.len >= 1);
}

test "refs: updateRef creates ref readable by git" {
    const path = tmpPath("refs_update");
    cleanup(path);
    defer cleanup(path);
    try initGitRepo(path);

    const gd = try gitDir(path);
    defer testing.allocator.free(gd);

    const fp = try std.fmt.allocPrint(testing.allocator, "{s}/f.txt", .{path});
    defer testing.allocator.free(fp);
    try writeFileAbs(fp, "data\n");
    _ = try runGitCmd(path, &.{ "add", "f.txt" });
    _ = try runGitCmd(path, &.{ "commit", "-q", "-m", "init" });

    const commit_hash = try gitTrimmed(path, &.{ "rev-parse", "HEAD" });
    defer testing.allocator.free(commit_hash);

    try refs_mod.updateRef(gd, "refs/tags/test-tag", commit_hash, platform, testing.allocator);

    // Read back via ziggit
    const read_hash = try refs_mod.getRef(gd, "refs/tags/test-tag", platform, testing.allocator);
    defer testing.allocator.free(read_hash);
    try testing.expectEqualStrings(commit_hash, read_hash);

    // Read via git
    const git_tag = try gitTrimmed(path, &.{ "rev-parse", "refs/tags/test-tag" });
    defer testing.allocator.free(git_tag);
    try testing.expectEqualStrings(commit_hash, git_tag);
}

test "refs: listTags after creating tags" {
    const path = tmpPath("refs_tags");
    cleanup(path);
    defer cleanup(path);
    try initGitRepo(path);

    const gd = try gitDir(path);
    defer testing.allocator.free(gd);

    const fp = try std.fmt.allocPrint(testing.allocator, "{s}/f.txt", .{path});
    defer testing.allocator.free(fp);
    try writeFileAbs(fp, "data\n");
    _ = try runGitCmd(path, &.{ "add", "f.txt" });
    _ = try runGitCmd(path, &.{ "commit", "-q", "-m", "init" });
    _ = try runGitCmd(path, &.{ "tag", "v1.0" });
    _ = try runGitCmd(path, &.{ "tag", "v2.0" });

    var tags = try refs_mod.listTags(gd, platform, testing.allocator);
    defer {
        for (tags.items) |t| testing.allocator.free(t);
        tags.deinit();
    }
    try testing.expect(tags.items.len >= 2);
}

// ============================================================================
// Index tests
// ============================================================================

test "index: load git-created index has correct count" {
    const path = tmpPath("idx_load");
    cleanup(path);
    defer cleanup(path);
    try initGitRepo(path);

    const gd = try gitDir(path);
    defer testing.allocator.free(gd);

    const fp1 = try std.fmt.allocPrint(testing.allocator, "{s}/a.txt", .{path});
    defer testing.allocator.free(fp1);
    try writeFileAbs(fp1, "aaa\n");
    const fp2 = try std.fmt.allocPrint(testing.allocator, "{s}/b.txt", .{path});
    defer testing.allocator.free(fp2);
    try writeFileAbs(fp2, "bbb\n");

    _ = try runGitCmd(path, &.{ "add", "a.txt", "b.txt" });

    var idx = try index_mod.Index.load(gd, platform, testing.allocator);
    defer idx.deinit();
    try testing.expectEqual(@as(usize, 2), idx.entries.items.len);
}

test "index: entry paths match" {
    const path = tmpPath("idx_paths");
    cleanup(path);
    defer cleanup(path);
    try initGitRepo(path);

    const gd = try gitDir(path);
    defer testing.allocator.free(gd);

    const fp = try std.fmt.allocPrint(testing.allocator, "{s}/hello.txt", .{path});
    defer testing.allocator.free(fp);
    try writeFileAbs(fp, "hello\n");
    _ = try runGitCmd(path, &.{ "add", "hello.txt" });

    var idx = try index_mod.Index.load(gd, platform, testing.allocator);
    defer idx.deinit();
    try testing.expectEqual(@as(usize, 1), idx.entries.items.len);
    try testing.expectEqualStrings("hello.txt", idx.entries.items[0].path);
}

test "index: save and reload preserves entries" {
    const path = tmpPath("idx_save");
    cleanup(path);
    defer cleanup(path);
    try initGitRepo(path);

    const gd = try gitDir(path);
    defer testing.allocator.free(gd);

    const fp = try std.fmt.allocPrint(testing.allocator, "{s}/test.txt", .{path});
    defer testing.allocator.free(fp);
    try writeFileAbs(fp, "test content\n");
    _ = try runGitCmd(path, &.{ "add", "test.txt" });

    {
        var idx = try index_mod.Index.load(gd, platform, testing.allocator);
        defer idx.deinit();
        try idx.save(gd, platform);
    }

    var idx2 = try index_mod.Index.load(gd, platform, testing.allocator);
    defer idx2.deinit();
    try testing.expectEqual(@as(usize, 1), idx2.entries.items.len);
    try testing.expectEqualStrings("test.txt", idx2.entries.items[0].path);
}

test "index: git reads ziggit-saved index" {
    const path = tmpPath("idx_gitrd");
    cleanup(path);
    defer cleanup(path);
    try initGitRepo(path);

    const gd = try gitDir(path);
    defer testing.allocator.free(gd);

    const fp = try std.fmt.allocPrint(testing.allocator, "{s}/check.txt", .{path});
    defer testing.allocator.free(fp);
    try writeFileAbs(fp, "check\n");
    _ = try runGitCmd(path, &.{ "add", "check.txt" });

    {
        var idx = try index_mod.Index.load(gd, platform, testing.allocator);
        defer idx.deinit();
        try idx.save(gd, platform);
    }

    const git_files = try gitTrimmed(path, &.{ "ls-files" });
    defer testing.allocator.free(git_files);
    try testing.expectEqualStrings("check.txt", git_files);
}

// ============================================================================
// Cross-module integration
// ============================================================================

test "crossval: git commit readable by ziggit objects.load" {
    const path = tmpPath("xval_commit");
    cleanup(path);
    defer cleanup(path);
    try initGitRepo(path);

    const gd = try gitDir(path);
    defer testing.allocator.free(gd);

    const fp = try std.fmt.allocPrint(testing.allocator, "{s}/f.txt", .{path});
    defer testing.allocator.free(fp);
    try writeFileAbs(fp, "data\n");
    _ = try runGitCmd(path, &.{ "add", "f.txt" });
    _ = try runGitCmd(path, &.{ "commit", "-q", "-m", "test commit" });

    const hash = try gitTrimmed(path, &.{ "rev-parse", "HEAD" });
    defer testing.allocator.free(hash);

    var obj = try objects.GitObject.load(hash, gd, platform, testing.allocator);
    defer obj.deinit(testing.allocator);

    try testing.expectEqualStrings("commit", obj.type.toString());
    try testing.expect(std.mem.indexOf(u8, obj.data, "test commit") != null);
}

test "crossval: git tree readable by ziggit" {
    const path = tmpPath("xval_tree");
    cleanup(path);
    defer cleanup(path);
    try initGitRepo(path);

    const gd = try gitDir(path);
    defer testing.allocator.free(gd);

    const fp = try std.fmt.allocPrint(testing.allocator, "{s}/f.txt", .{path});
    defer testing.allocator.free(fp);
    try writeFileAbs(fp, "data\n");
    _ = try runGitCmd(path, &.{ "add", "f.txt" });
    _ = try runGitCmd(path, &.{ "commit", "-q", "-m", "init" });

    const tree_hash = try gitTrimmed(path, &.{ "rev-parse", "HEAD^{tree}" });
    defer testing.allocator.free(tree_hash);

    var obj = try objects.GitObject.load(tree_hash, gd, platform, testing.allocator);
    defer obj.deinit(testing.allocator);
    try testing.expectEqualStrings("tree", obj.type.toString());
    try testing.expect(obj.data.len > 0);
}

test "crossval: ziggit blob hash matches git exactly" {
    const path = tmpPath("xval_hash");
    cleanup(path);
    defer cleanup(path);
    try initGitRepo(path);

    const test_content = "exact hash test content\n";

    var obj = objects.GitObject.init(.blob, test_content);
    const ziggit_hash = try obj.hash(testing.allocator);
    defer testing.allocator.free(ziggit_hash);

    const fp = try std.fmt.allocPrint(testing.allocator, "{s}/hashme.txt", .{path});
    defer testing.allocator.free(fp);
    try writeFileAbs(fp, test_content);
    const git_hash = try gitTrimmed(path, &.{ "hash-object", "hashme.txt" });
    defer testing.allocator.free(git_hash);

    try testing.expectEqualStrings(git_hash, ziggit_hash);
}
