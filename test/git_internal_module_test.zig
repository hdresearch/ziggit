// test/git_internal_module_test.zig - Tests for internal git module (objects, config, index)
// Uses proper module import via build.zig anonymous import of src/git/git.zig
const std = @import("std");
const git = @import("git");
const testing = std.testing;

// ============================================================================
// Helpers
// ============================================================================

fn tmpPath(comptime suffix: []const u8) []const u8 {
    return "/tmp/ziggit_gitmod_" ++ suffix;
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

fn runGit(args: []const []const u8, cwd: []const u8) ![]u8 {
    var child = std.process.Child.init(args, testing.allocator);
    var cwd_dir = try std.fs.openDirAbsolute(cwd, .{});
    defer cwd_dir.close();
    child.cwd_dir = cwd_dir;
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

// ============================================================================
// ObjectType tests
// ============================================================================

test "ObjectType.fromString: all valid types" {
    try testing.expectEqual(git.objects.ObjectType.blob, git.objects.ObjectType.fromString("blob").?);
    try testing.expectEqual(git.objects.ObjectType.tree, git.objects.ObjectType.fromString("tree").?);
    try testing.expectEqual(git.objects.ObjectType.commit, git.objects.ObjectType.fromString("commit").?);
    try testing.expectEqual(git.objects.ObjectType.tag, git.objects.ObjectType.fromString("tag").?);
}

test "ObjectType.fromString: invalid returns null" {
    try testing.expectEqual(@as(?git.objects.ObjectType, null), git.objects.ObjectType.fromString("invalid"));
    try testing.expectEqual(@as(?git.objects.ObjectType, null), git.objects.ObjectType.fromString(""));
    try testing.expectEqual(@as(?git.objects.ObjectType, null), git.objects.ObjectType.fromString("Blob"));
    try testing.expectEqual(@as(?git.objects.ObjectType, null), git.objects.ObjectType.fromString("COMMIT"));
}

test "ObjectType.toString roundtrip for all types" {
    const types = [_]git.objects.ObjectType{ .blob, .tree, .commit, .tag };
    for (types) |t| {
        const s = t.toString();
        const parsed = git.objects.ObjectType.fromString(s);
        try testing.expect(parsed != null);
        try testing.expectEqual(t, parsed.?);
    }
}

// ============================================================================
// GitObject hash tests - known values verified against git
// ============================================================================

test "GitObject.hash: empty blob known SHA-1" {
    // git hash-object -t blob --stdin < /dev/null = e69de29bb2d1d6434b8b29ae775ad8c2e48c5391
    const obj = git.objects.GitObject.init(.blob, "");
    const hash = try obj.hash(testing.allocator);
    defer testing.allocator.free(hash);
    try testing.expectEqualStrings("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391", hash);
}

test "GitObject.hash: hello world blob" {
    // echo -n "hello world" | git hash-object --stdin
    const obj = git.objects.GitObject.init(.blob, "hello world");
    const hash = try obj.hash(testing.allocator);
    defer testing.allocator.free(hash);
    try testing.expectEqualStrings("95d09f2b10159347eece71399a7e2e907ea3df4f", hash);
}

test "GitObject.hash: hello world with newline" {
    // echo "hello world" | git hash-object --stdin
    const obj = git.objects.GitObject.init(.blob, "hello world\n");
    const hash = try obj.hash(testing.allocator);
    defer testing.allocator.free(hash);
    try testing.expectEqualStrings("3b18e512dba79e4c8300dd08aeb37f8e728b8dad", hash);
}

test "GitObject.hash: deterministic" {
    const obj1 = git.objects.GitObject.init(.blob, "deterministic test");
    const obj2 = git.objects.GitObject.init(.blob, "deterministic test");
    const h1 = try obj1.hash(testing.allocator);
    defer testing.allocator.free(h1);
    const h2 = try obj2.hash(testing.allocator);
    defer testing.allocator.free(h2);
    try testing.expectEqualStrings(h1, h2);
}

test "GitObject.hash: different content different hash" {
    const obj1 = git.objects.GitObject.init(.blob, "aaa");
    const obj2 = git.objects.GitObject.init(.blob, "bbb");
    const h1 = try obj1.hash(testing.allocator);
    defer testing.allocator.free(h1);
    const h2 = try obj2.hash(testing.allocator);
    defer testing.allocator.free(h2);
    try testing.expect(!std.mem.eql(u8, h1, h2));
}

test "GitObject.hash: all hashes are 40 lowercase hex chars" {
    const test_data = [_][]const u8{ "", "x", "longer content here", "binary\x00\x01\x02\xff" };
    for (test_data) |data| {
        const obj = git.objects.GitObject.init(.blob, data);
        const hash = try obj.hash(testing.allocator);
        defer testing.allocator.free(hash);
        try testing.expectEqual(@as(usize, 40), hash.len);
        for (hash) |c| {
            try testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
        }
    }
}

test "GitObject.hash: cross-validate with git hash-object" {
    const path = tmpPath("hash_xval");
    cleanup(path);
    defer cleanup(path);
    std.fs.makeDirAbsolute(path) catch {};

    const content = "cross-validation test data\n";
    try writeFile(path, "test.txt", content);

    const obj = git.objects.GitObject.init(.blob, content);
    const ziggit_hash = try obj.hash(testing.allocator);
    defer testing.allocator.free(ziggit_hash);

    const git_out = runGit(&.{ "git", "hash-object", "test.txt" }, path) catch return;
    defer testing.allocator.free(git_out);
    const git_hash = std.mem.trim(u8, git_out, " \n\r\t");

    try testing.expectEqualStrings(git_hash, ziggit_hash);
}

// ============================================================================
// Config parsing tests
// ============================================================================

test "config: parse empty content" {
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator, "");
    defer cfg.deinit();
    try testing.expectEqual(@as(usize, 0), cfg.entries.items.len);
}

test "config: parse simple core section" {
    const content =
        \\[core]
        \\    repositoryformatversion = 0
        \\    filemode = true
        \\    bare = false
    ;
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator, content);
    defer cfg.deinit();

    const val = cfg.get("core", null, "bare");
    try testing.expect(val != null);
    try testing.expectEqualStrings("false", val.?);

    const fm = cfg.get("core", null, "filemode");
    try testing.expect(fm != null);
    try testing.expectEqualStrings("true", fm.?);
}

test "config: parse remote section with subsection" {
    const content =
        \\[remote "origin"]
        \\    url = https://github.com/example/repo.git
        \\    fetch = +refs/heads/*:refs/remotes/origin/*
    ;
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator, content);
    defer cfg.deinit();

    const url = cfg.getRemoteUrl("origin");
    try testing.expect(url != null);
    try testing.expectEqualStrings("https://github.com/example/repo.git", url.?);
}

test "config: comments and blank lines skipped" {
    const content =
        \\# A comment
        \\; Another comment
        \\
        \\[core]
        \\    bare = false
    ;
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator, content);
    defer cfg.deinit();

    const val = cfg.get("core", null, "bare");
    try testing.expect(val != null);
    try testing.expectEqualStrings("false", val.?);
}

test "config: getBool with true and false values" {
    const content =
        \\[core]
        \\    filemode = true
        \\    bare = false
    ;
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator, content);
    defer cfg.deinit();

    try testing.expectEqual(true, cfg.getBool("core", null, "filemode", false));
    try testing.expectEqual(false, cfg.getBool("core", null, "bare", true));
}

test "config: getBool default for missing key" {
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator, "");
    defer cfg.deinit();

    try testing.expectEqual(true, cfg.getBool("core", null, "nonexistent", true));
    try testing.expectEqual(false, cfg.getBool("core", null, "nonexistent", false));
}

test "config: get returns null for missing key" {
    const content =
        \\[core]
        \\    bare = false
    ;
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator, content);
    defer cfg.deinit();

    try testing.expectEqual(@as(?[]const u8, null), cfg.get("core", null, "nonexistent"));
    try testing.expectEqual(@as(?[]const u8, null), cfg.get("nonexistent", null, "bare"));
}

test "config: getUserName and getUserEmail" {
    const content =
        \\[user]
        \\    name = Test User
        \\    email = test@example.com
    ;
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator, content);
    defer cfg.deinit();

    const name = cfg.getUserName();
    try testing.expect(name != null);
    try testing.expectEqualStrings("Test User", name.?);

    const email = cfg.getUserEmail();
    try testing.expect(email != null);
    try testing.expectEqualStrings("test@example.com", email.?);
}

test "config: setValue adds entry" {
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator, "");
    defer cfg.deinit();

    try cfg.setValue("core", null, "filemode", "true");
    const val = cfg.get("core", null, "filemode");
    try testing.expect(val != null);
    try testing.expectEqualStrings("true", val.?);
}

test "config: removeValue removes entry" {
    const content =
        \\[core]
        \\    bare = false
    ;
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator, content);
    defer cfg.deinit();

    const removed = try cfg.removeValue("core", null, "bare");
    try testing.expect(removed);
    try testing.expectEqual(@as(?[]const u8, null), cfg.get("core", null, "bare"));
}

test "config: removeValue returns false for missing" {
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator, "");
    defer cfg.deinit();

    const removed = try cfg.removeValue("core", null, "nonexistent");
    try testing.expect(!removed);
}

test "config: multiple sections" {
    const content =
        \\[core]
        \\    bare = false
        \\[user]
        \\    name = Alice
        \\[core]
        \\    filemode = true
    ;
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator, content);
    defer cfg.deinit();

    try testing.expectEqualStrings("false", cfg.get("core", null, "bare").?);
    try testing.expectEqualStrings("Alice", cfg.get("user", null, "name").?);
    try testing.expectEqualStrings("true", cfg.get("core", null, "filemode").?);
}

test "config: realistic .git/config" {
    const content =
        \\[core]
        \\    repositoryformatversion = 0
        \\    filemode = true
        \\    bare = false
        \\    logallrefupdates = true
        \\[remote "origin"]
        \\    url = git@github.com:user/repo.git
        \\    fetch = +refs/heads/*:refs/remotes/origin/*
        \\[branch "main"]
        \\    remote = origin
        \\    merge = refs/heads/main
        \\[user]
        \\    name = Developer
        \\    email = dev@example.com
    ;
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator, content);
    defer cfg.deinit();

    try testing.expectEqual(false, cfg.getBool("core", null, "bare", true));
    try testing.expectEqual(true, cfg.getBool("core", null, "filemode", false));
    try testing.expectEqualStrings("git@github.com:user/repo.git", cfg.getRemoteUrl("origin").?);
    try testing.expectEqualStrings("Developer", cfg.getUserName().?);
    try testing.expectEqualStrings("dev@example.com", cfg.getUserEmail().?);
}

// ============================================================================
// Index binary format tests
// ============================================================================

test "index: IndexEntry writeToBuffer produces padded output" {
    const sha1 = [_]u8{0xab} ** 20;
    const path = "test/file.txt";

    var buf = std.ArrayList(u8).init(testing.allocator);
    defer buf.deinit();

    var entry = git.index.IndexEntry{
        .ctime_sec = 1000,
        .ctime_nsec = 500,
        .mtime_sec = 2000,
        .mtime_nsec = 600,
        .dev = 1,
        .ino = 2,
        .mode = 33188,
        .uid = 1000,
        .gid = 1000,
        .size = 42,
        .sha1 = sha1,
        .flags = @intCast(path.len),
        .extended_flags = null,
        .path = path,
    };

    try entry.writeToBuffer(buf.writer());
    // Must be padded to 8-byte boundary
    try testing.expectEqual(@as(usize, 0), buf.items.len % 8);
    // Must be at least 62 + path.len bytes
    try testing.expect(buf.items.len >= 62 + path.len);
}

test "index: IndexEntry writeToBuffer then readFromBuffer roundtrip" {
    const sha1 = [_]u8{0xde} ** 20;
    const path = "src/main.zig";

    var buf = std.ArrayList(u8).init(testing.allocator);
    defer buf.deinit();

    var entry = git.index.IndexEntry{
        .ctime_sec = 12345,
        .ctime_nsec = 678,
        .mtime_sec = 12346,
        .mtime_nsec = 789,
        .dev = 66306,
        .ino = 100,
        .mode = 33188,
        .uid = 501,
        .gid = 20,
        .size = 256,
        .sha1 = sha1,
        .flags = @intCast(path.len),
        .extended_flags = null,
        .path = path,
    };

    try entry.writeToBuffer(buf.writer());

    var stream = std.io.fixedBufferStream(buf.items);
    const parsed = try git.index.IndexEntry.readFromBuffer(stream.reader(), testing.allocator);
    defer testing.allocator.free(parsed.path);

    try testing.expectEqual(@as(u32, 12345), parsed.ctime_sec);
    try testing.expectEqual(@as(u32, 678), parsed.ctime_nsec);
    try testing.expectEqual(@as(u32, 12346), parsed.mtime_sec);
    try testing.expectEqual(@as(u32, 789), parsed.mtime_nsec);
    try testing.expectEqual(@as(u32, 33188), parsed.mode);
    try testing.expectEqual(@as(u32, 256), parsed.size);
    try testing.expect(std.mem.eql(u8, &sha1, &parsed.sha1));
    try testing.expectEqualStrings(path, parsed.path);
}

test "index: IndexEntry with long path" {
    const sha1 = [_]u8{0xcc} ** 20;
    const path = "very/deep/nested/directory/structure/with/many/levels/file.txt";

    var buf = std.ArrayList(u8).init(testing.allocator);
    defer buf.deinit();

    var entry = git.index.IndexEntry{
        .ctime_sec = 0, .ctime_nsec = 0,
        .mtime_sec = 0, .mtime_nsec = 0,
        .dev = 0, .ino = 0,
        .mode = 33188, .uid = 0, .gid = 0,
        .size = 100,
        .sha1 = sha1,
        .flags = @intCast(path.len),
        .extended_flags = null,
        .path = path,
    };

    try entry.writeToBuffer(buf.writer());

    var stream = std.io.fixedBufferStream(buf.items);
    const parsed = try git.index.IndexEntry.readFromBuffer(stream.reader(), testing.allocator);
    defer testing.allocator.free(parsed.path);

    try testing.expectEqualStrings(path, parsed.path);
}

test "index: IndexEntry with executable mode" {
    const sha1 = [_]u8{0xee} ** 20;
    const path = "run.sh";

    var buf = std.ArrayList(u8).init(testing.allocator);
    defer buf.deinit();

    var entry = git.index.IndexEntry{
        .ctime_sec = 0, .ctime_nsec = 0,
        .mtime_sec = 0, .mtime_nsec = 0,
        .dev = 0, .ino = 0,
        .mode = 33261, // 100755
        .uid = 0, .gid = 0,
        .size = 50,
        .sha1 = sha1,
        .flags = @intCast(path.len),
        .extended_flags = null,
        .path = path,
    };

    try entry.writeToBuffer(buf.writer());

    var stream = std.io.fixedBufferStream(buf.items);
    const parsed = try git.index.IndexEntry.readFromBuffer(stream.reader(), testing.allocator);
    defer testing.allocator.free(parsed.path);

    try testing.expectEqual(@as(u32, 33261), parsed.mode);
}
