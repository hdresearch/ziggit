// test/index_parser_unit_test.zig - Unit tests for IndexParser and IndexParserFast
// Tests DIRC binary format parsing, roundtrip consistency, and edge cases
const std = @import("std");
const ziggit = @import("ziggit");
const testing = std.testing;

const IndexParser = ziggit.IndexParser;
const IndexParserFast = ziggit.IndexParserFast;
const GitIndex = IndexParser.GitIndex;
const IndexEntry = IndexParser.IndexEntry;

// ============================================================================
// Helper utilities
// ============================================================================

fn tmpPath(comptime suffix: []const u8) []const u8 {
    return "/tmp/ziggit_idx_test_" ++ suffix;
}

fn cleanup(path: []const u8) void {
    std.fs.deleteTreeAbsolute(path) catch {};
}

fn initRepo(path: []const u8) !ziggit.Repository {
    cleanup(path);
    return try ziggit.Repository.init(testing.allocator, path);
}

fn createFile(dir: []const u8, name: []const u8, content: []const u8) !void {
    const full = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ dir, name });
    defer testing.allocator.free(full);
    const f = try std.fs.createFileAbsolute(full, .{ .truncate = true });
    defer f.close();
    try f.writeAll(content);
}

fn readFileBytes(path: []const u8) ![]u8 {
    const f = try std.fs.openFileAbsolute(path, .{});
    defer f.close();
    return try f.readToEndAlloc(testing.allocator, 10 * 1024 * 1024);
}

// ============================================================================
// GitIndex.init and basic operations
// ============================================================================

test "GitIndex.init creates empty index" {
    var idx = GitIndex.init(testing.allocator);
    defer idx.deinit();

    try testing.expectEqual(@as(usize, 0), idx.entries.items.len);
}

test "GitIndex.init can have entries appended" {
    var idx = GitIndex.init(testing.allocator);
    defer idx.deinit();

    const path = try testing.allocator.dupe(u8, "test.txt");
    try idx.entries.append(IndexEntry{
        .ctime_seconds = 100,
        .ctime_nanoseconds = 0,
        .mtime_seconds = 200,
        .mtime_nanoseconds = 0,
        .dev = 0,
        .ino = 0,
        .mode = 33188, // 100644
        .uid = 0,
        .gid = 0,
        .size = 42,
        .sha1 = [_]u8{0xab} ** 20,
        .flags = 8, // path length
        .path = path,
    });

    try testing.expectEqual(@as(usize, 1), idx.entries.items.len);
    try testing.expectEqualStrings("test.txt", idx.entries.items[0].path);
    try testing.expectEqual(@as(u32, 42), idx.entries.items[0].size);
}

test "GitIndex.findEntry finds existing entry" {
    var idx = GitIndex.init(testing.allocator);
    defer idx.deinit();

    const path1 = try testing.allocator.dupe(u8, "aaa.txt");
    const path2 = try testing.allocator.dupe(u8, "bbb.txt");
    try idx.entries.append(IndexEntry{
        .ctime_seconds = 0, .ctime_nanoseconds = 0,
        .mtime_seconds = 0, .mtime_nanoseconds = 0,
        .dev = 0, .ino = 0, .mode = 33188, .uid = 0, .gid = 0,
        .size = 10, .sha1 = [_]u8{1} ** 20, .flags = 7, .path = path1,
    });
    try idx.entries.append(IndexEntry{
        .ctime_seconds = 0, .ctime_nanoseconds = 0,
        .mtime_seconds = 0, .mtime_nanoseconds = 0,
        .dev = 0, .ino = 0, .mode = 33188, .uid = 0, .gid = 0,
        .size = 20, .sha1 = [_]u8{2} ** 20, .flags = 7, .path = path2,
    });

    const found = idx.findEntry("bbb.txt");
    try testing.expect(found != null);
    try testing.expectEqual(@as(u32, 20), found.?.size);

    const not_found = idx.findEntry("ccc.txt");
    try testing.expect(not_found == null);
}

// ============================================================================
// Index writeToFile and readFromFile roundtrip
// ============================================================================

test "index roundtrip: write then read preserves entries" {
    const path = tmpPath("roundtrip");
    cleanup(path);
    defer cleanup(path);

    std.fs.makeDirAbsolute(path) catch {};
    const index_file = try std.fmt.allocPrint(testing.allocator, "{s}/index", .{path});
    defer testing.allocator.free(index_file);

    // Write
    {
        var idx = GitIndex.init(testing.allocator);
        defer idx.deinit();

        const p1 = try testing.allocator.dupe(u8, "hello.txt");
        try idx.entries.append(IndexEntry{
            .ctime_seconds = 1000, .ctime_nanoseconds = 500,
            .mtime_seconds = 2000, .mtime_nanoseconds = 600,
            .dev = 1, .ino = 2, .mode = 33188, .uid = 3, .gid = 4,
            .size = 55, .sha1 = [_]u8{0xde} ** 20, .flags = 9, .path = p1,
        });

        try idx.writeToFile(index_file);
    }

    // Read back
    {
        var idx = try GitIndex.readFromFile(testing.allocator, index_file);
        defer idx.deinit();

        try testing.expectEqual(@as(usize, 1), idx.entries.items.len);
        const e = idx.entries.items[0];
        try testing.expectEqualStrings("hello.txt", e.path);
        try testing.expectEqual(@as(u32, 1000), e.ctime_seconds);
        try testing.expectEqual(@as(u32, 500), e.ctime_nanoseconds);
        try testing.expectEqual(@as(u32, 2000), e.mtime_seconds);
        try testing.expectEqual(@as(u32, 600), e.mtime_nanoseconds);
        try testing.expectEqual(@as(u32, 1), e.dev);
        try testing.expectEqual(@as(u32, 2), e.ino);
        try testing.expectEqual(@as(u32, 33188), e.mode);
        try testing.expectEqual(@as(u32, 3), e.uid);
        try testing.expectEqual(@as(u32, 4), e.gid);
        try testing.expectEqual(@as(u32, 55), e.size);
        try testing.expectEqualSlices(u8, &([_]u8{0xde} ** 20), &e.sha1);
    }
}

test "index roundtrip: multiple entries preserved in order" {
    const path = tmpPath("roundtrip_multi");
    cleanup(path);
    defer cleanup(path);

    std.fs.makeDirAbsolute(path) catch {};
    const index_file = try std.fmt.allocPrint(testing.allocator, "{s}/index", .{path});
    defer testing.allocator.free(index_file);

    const names = [_][]const u8{ "aaa.txt", "bbb.txt", "ccc.txt", "ddd.txt", "eee.txt" };

    // Write
    {
        var idx = GitIndex.init(testing.allocator);
        defer idx.deinit();

        for (names, 0..) |name, i| {
            const p = try testing.allocator.dupe(u8, name);
            var sha: [20]u8 = undefined;
            @memset(&sha, @intCast(i));
            try idx.entries.append(IndexEntry{
                .ctime_seconds = 0, .ctime_nanoseconds = 0,
                .mtime_seconds = 0, .mtime_nanoseconds = 0,
                .dev = 0, .ino = 0, .mode = 33188, .uid = 0, .gid = 0,
                .size = @intCast(i * 10),
                .sha1 = sha,
                .flags = @intCast(name.len),
                .path = p,
            });
        }

        try idx.writeToFile(index_file);
    }

    // Read back
    {
        var idx = try GitIndex.readFromFile(testing.allocator, index_file);
        defer idx.deinit();

        try testing.expectEqual(@as(usize, 5), idx.entries.items.len);
        for (names, 0..) |name, i| {
            try testing.expectEqualStrings(name, idx.entries.items[i].path);
            try testing.expectEqual(@as(u32, @intCast(i * 10)), idx.entries.items[i].size);
        }
    }
}

test "index roundtrip: entry with long filename" {
    const path = tmpPath("roundtrip_long");
    cleanup(path);
    defer cleanup(path);

    std.fs.makeDirAbsolute(path) catch {};
    const index_file = try std.fmt.allocPrint(testing.allocator, "{s}/index", .{path});
    defer testing.allocator.free(index_file);

    // 200-char filename (fits in 12-bit flag field max of 4095)
    const long_name = "a" ** 200 ++ ".txt";

    {
        var idx = GitIndex.init(testing.allocator);
        defer idx.deinit();

        const p = try testing.allocator.dupe(u8, long_name);
        try idx.entries.append(IndexEntry{
            .ctime_seconds = 0, .ctime_nanoseconds = 0,
            .mtime_seconds = 0, .mtime_nanoseconds = 0,
            .dev = 0, .ino = 0, .mode = 33188, .uid = 0, .gid = 0,
            .size = 99,
            .sha1 = [_]u8{0xff} ** 20,
            .flags = @intCast(@min(long_name.len, 0xfff)),
            .path = p,
        });

        try idx.writeToFile(index_file);
    }

    {
        var idx = try GitIndex.readFromFile(testing.allocator, index_file);
        defer idx.deinit();

        try testing.expectEqual(@as(usize, 1), idx.entries.items.len);
        try testing.expectEqualStrings(long_name, idx.entries.items[0].path);
    }
}

// ============================================================================
// DIRC binary format validation
// ============================================================================

test "index file starts with DIRC magic bytes" {
    const path = tmpPath("dirc_magic");
    cleanup(path);
    defer cleanup(path);

    std.fs.makeDirAbsolute(path) catch {};
    const index_file = try std.fmt.allocPrint(testing.allocator, "{s}/index", .{path});
    defer testing.allocator.free(index_file);

    var idx = GitIndex.init(testing.allocator);
    defer idx.deinit();
    try idx.writeToFile(index_file);

    const bytes = try readFileBytes(index_file);
    defer testing.allocator.free(bytes);

    try testing.expect(bytes.len >= 12);
    try testing.expectEqualStrings("DIRC", bytes[0..4]);
}

test "index file has version 2 in header" {
    const path = tmpPath("dirc_version");
    cleanup(path);
    defer cleanup(path);

    std.fs.makeDirAbsolute(path) catch {};
    const index_file = try std.fmt.allocPrint(testing.allocator, "{s}/index", .{path});
    defer testing.allocator.free(index_file);

    var idx = GitIndex.init(testing.allocator);
    defer idx.deinit();
    try idx.writeToFile(index_file);

    const bytes = try readFileBytes(index_file);
    defer testing.allocator.free(bytes);

    const version = std.mem.readInt(u32, bytes[4..8][0..4], .big);
    try testing.expectEqual(@as(u32, 2), version);
}

test "index file entry count in header matches entries" {
    const path = tmpPath("dirc_count");
    cleanup(path);
    defer cleanup(path);

    std.fs.makeDirAbsolute(path) catch {};
    const index_file = try std.fmt.allocPrint(testing.allocator, "{s}/index", .{path});
    defer testing.allocator.free(index_file);

    {
        var idx = GitIndex.init(testing.allocator);
        defer idx.deinit();

        for (0..7) |i| {
            const name = try std.fmt.allocPrint(testing.allocator, "file{d}.txt", .{i});
            try idx.entries.append(IndexEntry{
                .ctime_seconds = 0, .ctime_nanoseconds = 0,
                .mtime_seconds = 0, .mtime_nanoseconds = 0,
                .dev = 0, .ino = 0, .mode = 33188, .uid = 0, .gid = 0,
                .size = 0, .sha1 = [_]u8{0} ** 20,
                .flags = @intCast(name.len),
                .path = name,
            });
        }
        try idx.writeToFile(index_file);
    }

    const bytes = try readFileBytes(index_file);
    defer testing.allocator.free(bytes);

    const count = std.mem.readInt(u32, bytes[8..12][0..4], .big);
    try testing.expectEqual(@as(u32, 7), count);
}

test "parseIndex rejects data shorter than 12 bytes" {
    const short_data = "DIRC";
    const result = GitIndex.parseIndex(testing.allocator, short_data);
    try testing.expectError(error.InvalidIndex, result);
}

test "parseIndex rejects invalid signature" {
    const bad_sig = "XXXX\x00\x00\x00\x02\x00\x00\x00\x00";
    const result = GitIndex.parseIndex(testing.allocator, bad_sig);
    try testing.expectError(error.InvalidIndexSignature, result);
}

test "parseIndex rejects unsupported version" {
    // Version 99 is not supported
    const bad_ver = "DIRC\x00\x00\x00\x63\x00\x00\x00\x00";
    const result = GitIndex.parseIndex(testing.allocator, bad_ver);
    try testing.expectError(error.UnsupportedIndexVersion, result);
}

test "parseIndex accepts version 2" {
    // Version 2, 0 entries, plus 20-byte checksum
    var data: [32]u8 = undefined;
    @memcpy(data[0..4], "DIRC");
    std.mem.writeInt(u32, data[4..8], 2, .big);
    std.mem.writeInt(u32, data[8..12], 0, .big);
    @memset(data[12..32], 0); // dummy checksum

    var idx = try GitIndex.parseIndex(testing.allocator, &data);
    defer idx.deinit();
    try testing.expectEqual(@as(usize, 0), idx.entries.items.len);
}

// ============================================================================
// FastGitIndex tests
// ============================================================================

test "FastGitIndex reads same entries as GitIndex" {
    const path = tmpPath("fast_vs_normal");
    cleanup(path);
    defer cleanup(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "alpha.txt", "alpha content");
    try createFile(path, "beta.txt", "beta content");
    try repo.add("alpha.txt");
    try repo.add("beta.txt");

    const index_file = try std.fmt.allocPrint(testing.allocator, "{s}/.git/index", .{path});
    defer testing.allocator.free(index_file);

    // Read with normal parser
    var normal_idx = try GitIndex.readFromFile(testing.allocator, index_file);
    defer normal_idx.deinit();

    // Read with fast parser
    var fast_idx = try IndexParserFast.FastGitIndex.readFromFile(testing.allocator, index_file);
    defer fast_idx.deinit();

    // Same number of entries
    try testing.expectEqual(normal_idx.entries.items.len, fast_idx.entries.len);

    // Same paths, sizes, and mtimes
    for (normal_idx.entries.items, 0..) |normal_entry, i| {
        const fast_entry = fast_idx.entries[i];
        try testing.expectEqualStrings(normal_entry.path, fast_entry.path);
        try testing.expectEqual(normal_entry.size, fast_entry.size);
        try testing.expectEqual(normal_entry.mtime_seconds, fast_entry.mtime_seconds);
    }
}

test "FastGitIndex.findEntry works correctly" {
    const path = tmpPath("fast_find");
    cleanup(path);
    defer cleanup(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "target.txt", "find me");
    try repo.add("target.txt");

    const index_file = try std.fmt.allocPrint(testing.allocator, "{s}/.git/index", .{path});
    defer testing.allocator.free(index_file);

    var fast_idx = try IndexParserFast.FastGitIndex.readFromFile(testing.allocator, index_file);
    defer fast_idx.deinit();

    const found = fast_idx.findEntry("target.txt");
    try testing.expect(found != null);
    try testing.expectEqual(@as(u32, 7), found.?.size); // "find me" = 7 bytes

    const not_found = fast_idx.findEntry("missing.txt");
    try testing.expect(not_found == null);
}

// ============================================================================
// Index via Repository API
// ============================================================================

test "Repository.add creates index readable by both parsers" {
    const path = tmpPath("repo_add_both");
    cleanup(path);
    defer cleanup(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "test.txt", "content");
    try repo.add("test.txt");

    const index_file = try std.fmt.allocPrint(testing.allocator, "{s}/.git/index", .{path});
    defer testing.allocator.free(index_file);

    // Both parsers should read it successfully
    var normal = try GitIndex.readFromFile(testing.allocator, index_file);
    defer normal.deinit();
    try testing.expectEqual(@as(usize, 1), normal.entries.items.len);

    var fast = try IndexParserFast.FastGitIndex.readFromFile(testing.allocator, index_file);
    defer fast.deinit();
    try testing.expectEqual(@as(usize, 1), fast.entries.len);
}

test "git-created index readable by both parsers" {
    const path = tmpPath("git_index_both");
    cleanup(path);
    defer cleanup(path);

    // Create repo with git
    _ = runGitSilent(&[_][]const u8{ "git", "init", "-q", path }) catch return;
    try createFile(path, "file.txt", "hello from git");
    _ = runGitSilent(&[_][]const u8{ "git", "-C", path, "add", "file.txt" }) catch return;

    const index_file = try std.fmt.allocPrint(testing.allocator, "{s}/.git/index", .{path});
    defer testing.allocator.free(index_file);

    var normal = try GitIndex.readFromFile(testing.allocator, index_file);
    defer normal.deinit();
    try testing.expectEqual(@as(usize, 1), normal.entries.items.len);
    try testing.expectEqualStrings("file.txt", normal.entries.items[0].path);
    try testing.expectEqual(@as(u32, 14), normal.entries.items[0].size); // "hello from git"

    var fast = try IndexParserFast.FastGitIndex.readFromFile(testing.allocator, index_file);
    defer fast.deinit();
    try testing.expectEqual(@as(usize, 1), fast.entries.len);
    try testing.expectEqualStrings("file.txt", fast.entries[0].path);
    try testing.expectEqual(@as(u32, 14), fast.entries[0].size);
}

test "index with zero entries roundtrips" {
    const path = tmpPath("empty_index");
    cleanup(path);
    defer cleanup(path);

    std.fs.makeDirAbsolute(path) catch {};
    const index_file = try std.fmt.allocPrint(testing.allocator, "{s}/index", .{path});
    defer testing.allocator.free(index_file);

    {
        var idx = GitIndex.init(testing.allocator);
        defer idx.deinit();
        try idx.writeToFile(index_file);
    }

    {
        var idx = try GitIndex.readFromFile(testing.allocator, index_file);
        defer idx.deinit();
        try testing.expectEqual(@as(usize, 0), idx.entries.items.len);
    }
}

test "index SHA-1 field preserved through roundtrip" {
    const path = tmpPath("sha_roundtrip");
    cleanup(path);
    defer cleanup(path);

    std.fs.makeDirAbsolute(path) catch {};
    const index_file = try std.fmt.allocPrint(testing.allocator, "{s}/index", .{path});
    defer testing.allocator.free(index_file);

    // Specific SHA-1 pattern
    var specific_sha: [20]u8 = undefined;
    for (&specific_sha, 0..) |*b, i| {
        b.* = @intCast(i * 13 % 256);
    }

    {
        var idx = GitIndex.init(testing.allocator);
        defer idx.deinit();
        const p = try testing.allocator.dupe(u8, "file.txt");
        try idx.entries.append(IndexEntry{
            .ctime_seconds = 0, .ctime_nanoseconds = 0,
            .mtime_seconds = 0, .mtime_nanoseconds = 0,
            .dev = 0, .ino = 0, .mode = 33188, .uid = 0, .gid = 0,
            .size = 0, .sha1 = specific_sha, .flags = 8, .path = p,
        });
        try idx.writeToFile(index_file);
    }

    {
        var idx = try GitIndex.readFromFile(testing.allocator, index_file);
        defer idx.deinit();
        try testing.expectEqualSlices(u8, &specific_sha, &idx.entries.items[0].sha1);
    }
}

test "index mode 100755 preserved through roundtrip" {
    const path = tmpPath("mode_roundtrip");
    cleanup(path);
    defer cleanup(path);

    std.fs.makeDirAbsolute(path) catch {};
    const index_file = try std.fmt.allocPrint(testing.allocator, "{s}/index", .{path});
    defer testing.allocator.free(index_file);

    {
        var idx = GitIndex.init(testing.allocator);
        defer idx.deinit();
        const p = try testing.allocator.dupe(u8, "script.sh");
        try idx.entries.append(IndexEntry{
            .ctime_seconds = 0, .ctime_nanoseconds = 0,
            .mtime_seconds = 0, .mtime_nanoseconds = 0,
            .dev = 0, .ino = 0, .mode = 33261, .uid = 0, .gid = 0,  // 100755
            .size = 10, .sha1 = [_]u8{0} ** 20, .flags = 9, .path = p,
        });
        try idx.writeToFile(index_file);
    }

    {
        var idx = try GitIndex.readFromFile(testing.allocator, index_file);
        defer idx.deinit();
        try testing.expectEqual(@as(u32, 33261), idx.entries.items[0].mode);
    }
}

// ============================================================================
// Helper to run git CLI
// ============================================================================

fn runGitSilent(args: []const []const u8) ![]u8 {
    var child = std.process.Child.init(args, testing.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const stdout = try child.stdout.?.reader().readAllAlloc(testing.allocator, 1024 * 1024);
    errdefer testing.allocator.free(stdout);
    const term = try child.wait();
    if (term.Exited != 0) {
        testing.allocator.free(stdout);
        return error.CommandFailed;
    }
    return stdout;
}
