// test/refs_config_crossval_test.zig
// Tests for config parsing, object hashing, and index validation via internal git module.
const std = @import("std");
const git = @import("git");
const testing = std.testing;

fn tmpPath(comptime suffix: []const u8) []const u8 {
    return "/tmp/ziggit_refs_cfg_" ++ suffix;
}

fn cleanup(path: []const u8) void {
    std.fs.deleteTreeAbsolute(path) catch {};
}

fn runGitNoCheck(args: []const []const u8, cwd: []const u8) !void {
    var child = std.process.Child.init(args, testing.allocator);
    child.cwd = cwd;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const stdout = try child.stdout.?.reader().readAllAlloc(testing.allocator, 1024 * 1024);
    defer testing.allocator.free(stdout);
    const stderr = try child.stderr.?.reader().readAllAlloc(testing.allocator, 1024 * 1024);
    defer testing.allocator.free(stderr);
    _ = try child.wait();
}

fn createFile(dir: []const u8, name: []const u8, content: []const u8) !void {
    const full = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ dir, name });
    defer testing.allocator.free(full);
    const f = try std.fs.createFileAbsolute(full, .{ .truncate = true });
    defer f.close();
    try f.writeAll(content);
}

// === Config parsing tests ===

test "config: parse simple section" {
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator,
        \\[core]
        \\    bare = false
        \\    repositoryformatversion = 0
    );
    defer cfg.deinit();

    const bare = cfg.getValue("core", "bare");
    try testing.expect(bare != null);
    try testing.expectEqualStrings("false", bare.?);

    const ver = cfg.getValue("core", "repositoryformatversion");
    try testing.expect(ver != null);
    try testing.expectEqualStrings("0", ver.?);
}

test "config: parse multiple sections" {
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator,
        \\[core]
        \\    bare = false
        \\[user]
        \\    name = Test User
        \\    email = test@example.com
    );
    defer cfg.deinit();

    const name = cfg.getValue("user", "name");
    try testing.expect(name != null);
    try testing.expectEqualStrings("Test User", name.?);

    const email = cfg.getValue("user", "email");
    try testing.expect(email != null);
    try testing.expectEqualStrings("test@example.com", email.?);
}

test "config: getValue returns null for missing key" {
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator,
        \\[core]
        \\    bare = false
    );
    defer cfg.deinit();

    try testing.expectEqual(@as(?[]const u8, null), cfg.getValue("core", "nonexistent"));
}

test "config: getValue returns null for missing section" {
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator,
        \\[core]
        \\    bare = false
    );
    defer cfg.deinit();

    try testing.expectEqual(@as(?[]const u8, null), cfg.getValue("nonexistent", "bare"));
}

test "config: setValue adds new entry" {
    var cfg = git.config.GitConfig.init(testing.allocator);
    defer cfg.deinit();

    try cfg.setValue("user", null, "name", "Alice");
    const name = cfg.getValue("user", "name");
    try testing.expect(name != null);
    try testing.expectEqualStrings("Alice", name.?);
}

test "config: setValue overwrites existing" {
    var cfg = git.config.GitConfig.init(testing.allocator);
    defer cfg.deinit();

    try cfg.setValue("user", null, "name", "Alice");
    try cfg.setValue("user", null, "name", "Bob");
    const name = cfg.getValue("user", "name");
    try testing.expect(name != null);
    try testing.expectEqualStrings("Bob", name.?);
}

test "config: removeValue works" {
    var cfg = git.config.GitConfig.init(testing.allocator);
    defer cfg.deinit();

    try cfg.setValue("user", null, "name", "Alice");
    const removed = try cfg.removeValue("user", null, "name");
    try testing.expect(removed);

    try testing.expectEqual(@as(?[]const u8, null), cfg.getValue("user", "name"));
}

test "config: removeValue returns false for missing" {
    var cfg = git.config.GitConfig.init(testing.allocator);
    defer cfg.deinit();

    const removed = try cfg.removeValue("user", null, "name");
    try testing.expect(!removed);
}

test "config: parse git-created config" {
    const path = tmpPath("git_config");
    cleanup(path);
    defer cleanup(path);

    try runGitNoCheck(&.{ "git", "init", "-q", path }, "/tmp");
    try runGitNoCheck(&.{ "git", "config", "user.email", "test@test.com" }, path);
    try runGitNoCheck(&.{ "git", "config", "user.name", "TestUser" }, path);

    const config_path = try std.fmt.allocPrint(testing.allocator, "{s}/.git/config", .{path});
    defer testing.allocator.free(config_path);

    const content = try std.fs.cwd().readFileAlloc(testing.allocator, config_path, 64 * 1024);
    defer testing.allocator.free(content);

    var cfg = try git.config.GitConfig.parseConfig(testing.allocator, content);
    defer cfg.deinit();

    const bare = cfg.getValue("core", "bare");
    try testing.expect(bare != null);

    const email = cfg.getUserEmail();
    try testing.expect(email != null);
    try testing.expectEqualStrings("test@test.com", email.?);

    const name = cfg.getUserName();
    try testing.expect(name != null);
    try testing.expectEqualStrings("TestUser", name.?);
}

test "config: getRemoteUrl for origin" {
    var cfg = try git.config.GitConfig.parseConfig(testing.allocator,
        \\[remote "origin"]
        \\    url = https://github.com/user/repo.git
        \\    fetch = +refs/heads/*:refs/remotes/origin/*
    );
    defer cfg.deinit();

    const url = cfg.getRemoteUrl("origin");
    try testing.expect(url != null);
    try testing.expectEqualStrings("https://github.com/user/repo.git", url.?);
}

// === Object hash tests ===

test "objects: blob hash matches manual computation" {
    const content = "hello world\n";
    var obj = git.objects.GitObject.init(.blob, content);
    const hash = try obj.hash(testing.allocator);
    defer testing.allocator.free(hash);

    const header = "blob 12\x00";
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(header);
    hasher.update(content);
    var digest: [20]u8 = undefined;
    hasher.final(&digest);

    var expected: [40]u8 = undefined;
    _ = std.fmt.bufPrint(&expected, "{s}", .{std.fmt.fmtSliceHexLower(&digest)}) catch unreachable;

    try testing.expectEqualStrings(&expected, hash);
}

test "objects: empty blob has well-known hash" {
    var obj = git.objects.GitObject.init(.blob, "");
    const hash = try obj.hash(testing.allocator);
    defer testing.allocator.free(hash);
    try testing.expectEqualStrings("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391", hash);
}

test "objects: ObjectType fromString/toString roundtrip" {
    inline for (.{ .{ "blob", git.objects.ObjectType.blob }, .{ "tree", git.objects.ObjectType.tree }, .{ "commit", git.objects.ObjectType.commit }, .{ "tag", git.objects.ObjectType.tag } }) |pair| {
        const parsed = git.objects.ObjectType.fromString(pair[0]);
        try testing.expect(parsed != null);
        try testing.expectEqual(pair[1], parsed.?);
        try testing.expectEqualStrings(pair[0], parsed.?.toString());
    }
}

test "objects: ObjectType fromString null for invalid" {
    try testing.expectEqual(@as(?git.objects.ObjectType, null), git.objects.ObjectType.fromString("invalid"));
    try testing.expectEqual(@as(?git.objects.ObjectType, null), git.objects.ObjectType.fromString(""));
    try testing.expectEqual(@as(?git.objects.ObjectType, null), git.objects.ObjectType.fromString("BLOB"));
}

test "objects: different content different hash" {
    var obj1 = git.objects.GitObject.init(.blob, "aaa");
    const hash1 = try obj1.hash(testing.allocator);
    defer testing.allocator.free(hash1);

    var obj2 = git.objects.GitObject.init(.blob, "bbb");
    const hash2 = try obj2.hash(testing.allocator);
    defer testing.allocator.free(hash2);

    try testing.expect(!std.mem.eql(u8, hash1, hash2));
}

test "objects: same content same hash (deterministic)" {
    var obj1 = git.objects.GitObject.init(.blob, "identical");
    const hash1 = try obj1.hash(testing.allocator);
    defer testing.allocator.free(hash1);

    var obj2 = git.objects.GitObject.init(.blob, "identical");
    const hash2 = try obj2.hash(testing.allocator);
    defer testing.allocator.free(hash2);

    try testing.expectEqualStrings(hash1, hash2);
}

test "objects: different type same content different hash" {
    var obj1 = git.objects.GitObject.init(.blob, "data");
    const hash1 = try obj1.hash(testing.allocator);
    defer testing.allocator.free(hash1);

    var obj2 = git.objects.GitObject.init(.commit, "data");
    const hash2 = try obj2.hash(testing.allocator);
    defer testing.allocator.free(hash2);

    try testing.expect(!std.mem.eql(u8, hash1, hash2));
}

test "objects: hash is always 40 lowercase hex chars" {
    const contents = [_][]const u8{ "", "a", "hello", "x" ** 1000 };
    for (contents) |content| {
        var obj = git.objects.GitObject.init(.blob, content);
        const hash = try obj.hash(testing.allocator);
        defer testing.allocator.free(hash);
        try testing.expectEqual(@as(usize, 40), hash.len);
        for (hash) |c| {
            try testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
        }
    }
}

// === Index validation tests ===

test "Index: parseIndexData rejects too-short data" {
    var idx = git.index.Index.init(testing.allocator);
    defer idx.deinit();
    try testing.expectError(error.InvalidIndex, idx.parseIndexData("short"));
}

test "Index: parseIndexData rejects wrong magic" {
    var idx = git.index.Index.init(testing.allocator);
    defer idx.deinit();
    var buf: [32]u8 = [_]u8{0} ** 32;
    @memcpy(buf[0..4], "XXXX");
    try testing.expectError(error.InvalidIndex, idx.parseIndexData(&buf));
}

test "Index: parseIndexData accepts valid empty DIRC" {
    var buf = std.ArrayList(u8).init(testing.allocator);
    defer buf.deinit();

    try buf.appendSlice("DIRC");
    try buf.writer().writeInt(u32, 2, .big);
    try buf.writer().writeInt(u32, 0, .big);

    var sha: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(buf.items, &sha, .{});
    try buf.appendSlice(&sha);

    var idx = git.index.Index.init(testing.allocator);
    defer idx.deinit();
    try idx.parseIndexData(buf.items);
    try testing.expectEqual(@as(usize, 0), idx.entries.items.len);
}
