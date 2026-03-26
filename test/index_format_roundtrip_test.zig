const std = @import("std");
const ziggit = @import("ziggit");
const testing = std.testing;

const IndexParser = ziggit.IndexParser;
const IndexParserFast = ziggit.IndexParserFast;

fn cleanupPath(path: []const u8) void {
    std.fs.deleteTreeAbsolute(path) catch {};
}

// === Index DIRC binary format tests ===

test "index: write then read preserves entry count" {
    const path = "/tmp/ziggit_test_idx_count";
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    // Add 3 files
    const names = [_][]const u8{ "a.txt", "b.txt", "c.txt" };
    for (names) |name| {
        const full = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ path, name });
        defer testing.allocator.free(full);
        const f = try std.fs.createFileAbsolute(full, .{});
        defer f.close();
        try f.writeAll(name);
    }
    for (names) |name| {
        try repo.add(name);
    }

    // Read index back
    const index_path = try std.fmt.allocPrint(testing.allocator, "{s}/.git/index", .{path});
    defer testing.allocator.free(index_path);

    var idx = try IndexParser.GitIndex.readFromFile(testing.allocator, index_path);
    defer idx.deinit();

    try testing.expectEqual(@as(usize, 3), idx.entries.items.len);
}

test "index: entry paths preserved through write/read" {
    const path = "/tmp/ziggit_test_idx_paths";
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    {
        const f = try std.fs.createFileAbsolute(path ++ "/hello.txt", .{});
        defer f.close();
        try f.writeAll("hello");
    }
    try repo.add("hello.txt");

    const index_path = try std.fmt.allocPrint(testing.allocator, "{s}/.git/index", .{path});
    defer testing.allocator.free(index_path);

    var idx = try IndexParser.GitIndex.readFromFile(testing.allocator, index_path);
    defer idx.deinit();

    try testing.expectEqual(@as(usize, 1), idx.entries.items.len);
    try testing.expectEqualStrings("hello.txt", idx.entries.items[0].path);
}

test "index: SHA-1 hashes preserved through write/read" {
    const path = "/tmp/ziggit_test_idx_sha";
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    const content = "known content\n";
    {
        const f = try std.fs.createFileAbsolute(path ++ "/known.txt", .{});
        defer f.close();
        try f.writeAll(content);
    }
    try repo.add("known.txt");

    // Compute expected blob hash
    const header = try std.fmt.allocPrint(testing.allocator, "blob {}\x00", .{content.len});
    defer testing.allocator.free(header);
    const blob = try std.mem.concat(testing.allocator, u8, &[_][]const u8{ header, content });
    defer testing.allocator.free(blob);

    var expected_hash: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(blob, &expected_hash, .{});

    const index_path = try std.fmt.allocPrint(testing.allocator, "{s}/.git/index", .{path});
    defer testing.allocator.free(index_path);

    var idx = try IndexParser.GitIndex.readFromFile(testing.allocator, index_path);
    defer idx.deinit();

    try testing.expectEqualSlices(u8, &expected_hash, &idx.entries.items[0].sha1);
}

test "index: file starts with DIRC signature" {
    const path = "/tmp/ziggit_test_idx_dirc";
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    {
        const f = try std.fs.createFileAbsolute(path ++ "/f.txt", .{});
        defer f.close();
        try f.writeAll("data");
    }
    try repo.add("f.txt");

    // Read raw index bytes
    const index_path = path ++ "/.git/index";
    const raw = try std.fs.cwd().readFileAlloc(testing.allocator, index_path, 100 * 1024);
    defer testing.allocator.free(raw);

    try testing.expectEqualStrings("DIRC", raw[0..4]);
}

test "index: version is 2" {
    const path = "/tmp/ziggit_test_idx_version";
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    {
        const f = try std.fs.createFileAbsolute(path ++ "/f.txt", .{});
        defer f.close();
        try f.writeAll("data");
    }
    try repo.add("f.txt");

    const raw = try std.fs.cwd().readFileAlloc(testing.allocator, path ++ "/.git/index", 100 * 1024);
    defer testing.allocator.free(raw);

    const version = std.mem.readInt(u32, raw[4..8][0..4], .big);
    try testing.expectEqual(@as(u32, 2), version);
}

test "index: entry count in header matches actual entries" {
    const path = "/tmp/ziggit_test_idx_entrycount";
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    const names = [_][]const u8{ "x.txt", "y.txt" };
    for (names) |name| {
        const full = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ path, name });
        defer testing.allocator.free(full);
        const f = try std.fs.createFileAbsolute(full, .{});
        defer f.close();
        try f.writeAll(name);
    }
    for (names) |name| {
        try repo.add(name);
    }

    const raw = try std.fs.cwd().readFileAlloc(testing.allocator, path ++ "/.git/index", 100 * 1024);
    defer testing.allocator.free(raw);

    const count = std.mem.readInt(u32, raw[8..12][0..4], .big);
    try testing.expectEqual(@as(u32, 2), count);
}

test "index: mode is 100644 for regular files" {
    const path = "/tmp/ziggit_test_idx_mode";
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    {
        const f = try std.fs.createFileAbsolute(path ++ "/f.txt", .{});
        defer f.close();
        try f.writeAll("data");
    }
    try repo.add("f.txt");

    const index_path = try std.fmt.allocPrint(testing.allocator, "{s}/.git/index", .{path});
    defer testing.allocator.free(index_path);

    var idx = try IndexParser.GitIndex.readFromFile(testing.allocator, index_path);
    defer idx.deinit();

    try testing.expectEqual(@as(u32, 33188), idx.entries.items[0].mode); // 100644 in decimal
}

test "index: file size recorded correctly" {
    const path = "/tmp/ziggit_test_idx_size";
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    const content = "exactly 22 bytes long!";
    {
        const f = try std.fs.createFileAbsolute(path ++ "/sized.txt", .{});
        defer f.close();
        try f.writeAll(content);
    }
    try repo.add("sized.txt");

    const index_path = try std.fmt.allocPrint(testing.allocator, "{s}/.git/index", .{path});
    defer testing.allocator.free(index_path);

    var idx = try IndexParser.GitIndex.readFromFile(testing.allocator, index_path);
    defer idx.deinit();

    try testing.expectEqual(@as(u32, content.len), idx.entries.items[0].size);
}

// === FastGitIndex compatibility ===

test "fast index: reads same entries as regular parser" {
    const path = "/tmp/ziggit_test_fastidx";
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    const names = [_][]const u8{ "a.txt", "b.txt" };
    for (names) |name| {
        const full = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ path, name });
        defer testing.allocator.free(full);
        const f = try std.fs.createFileAbsolute(full, .{});
        defer f.close();
        try f.writeAll(name);
    }
    for (names) |name| {
        try repo.add(name);
    }

    const index_path = try std.fmt.allocPrint(testing.allocator, "{s}/.git/index", .{path});
    defer testing.allocator.free(index_path);

    // Read with regular parser
    var idx = try IndexParser.GitIndex.readFromFile(testing.allocator, index_path);
    defer idx.deinit();

    // Read with fast parser
    var fast_idx = try IndexParserFast.FastGitIndex.readFromFile(testing.allocator, index_path);
    defer fast_idx.deinit();

    // Same number of entries
    try testing.expectEqual(idx.entries.items.len, fast_idx.entries.len);

    // Same paths and sizes
    for (idx.entries.items, 0..) |entry, i| {
        try testing.expectEqualStrings(entry.path, fast_idx.entries[i].path);
        try testing.expectEqual(entry.size, fast_idx.entries[i].size);
        try testing.expectEqual(entry.mtime_seconds, fast_idx.entries[i].mtime_seconds);
    }
}

// === git index compatibility ===

test "index: git ls-files reads ziggit index correctly" {
    const path = "/tmp/ziggit_test_idx_gitcompat";
    cleanupPath(path);
    defer cleanupPath(path);

    var repo = try ziggit.Repository.init(testing.allocator, path);
    defer repo.close();

    {
        const f = try std.fs.createFileAbsolute(path ++ "/tracked.txt", .{});
        defer f.close();
        try f.writeAll("tracked content\n");
    }
    try repo.add("tracked.txt");

    const result = std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = &[_][]const u8{ "git", "-C", path, "ls-files" },
    }) catch return;
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    try testing.expectEqual(@as(u8, 0), result.term.Exited);
    try testing.expectEqualStrings("tracked.txt\n", result.stdout);
}

test "index: git-written index readable by ziggit" {
    const path = "/tmp/ziggit_test_idx_gitwrite";
    cleanupPath(path);
    defer cleanupPath(path);

    // Create repo with git
    const init_result = std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = &[_][]const u8{ "git", "init", "-q", path },
    }) catch return;
    defer testing.allocator.free(init_result.stdout);
    defer testing.allocator.free(init_result.stderr);

    // Create and add file with git
    {
        const f = try std.fs.createFileAbsolute(path ++ "/gitfile.txt", .{});
        defer f.close();
        try f.writeAll("git content\n");
    }

    const add_result = std.process.Child.run(.{
        .allocator = testing.allocator,
        .argv = &[_][]const u8{ "git", "-C", path, "add", "gitfile.txt" },
    }) catch return;
    defer testing.allocator.free(add_result.stdout);
    defer testing.allocator.free(add_result.stderr);

    // Read with ziggit's index parser
    const index_path = try std.fmt.allocPrint(testing.allocator, "{s}/.git/index", .{path});
    defer testing.allocator.free(index_path);

    var idx = try IndexParser.GitIndex.readFromFile(testing.allocator, index_path);
    defer idx.deinit();

    try testing.expectEqual(@as(usize, 1), idx.entries.items.len);
    try testing.expectEqualStrings("gitfile.txt", idx.entries.items[0].path);
}

// === Invalid index data ===

test "index: rejects data shorter than 12 bytes" {
    const short: []const u8 = "short";
    const result = IndexParser.GitIndex.parseIndex(testing.allocator, short);
    try testing.expectError(error.InvalidIndex, result);
}

test "index: rejects wrong signature" {
    var bad_data: [32]u8 = [_]u8{0} ** 32;
    @memcpy(bad_data[0..4], "BADX");
    const slice: []const u8 = &bad_data;
    const result = IndexParser.GitIndex.parseIndex(testing.allocator, slice);
    try testing.expectError(error.InvalidIndexSignature, result);
}

test "index: rejects unsupported version" {
    // DIRC + version 99 + 0 entries
    var bad_data: [32]u8 = [_]u8{0} ** 32;
    @memcpy(bad_data[0..4], "DIRC");
    std.mem.writeInt(u32, bad_data[4..8], 99, .big);
    std.mem.writeInt(u32, bad_data[8..12], 0, .big);

    const slice: []const u8 = &bad_data;
    const result = IndexParser.GitIndex.parseIndex(testing.allocator, slice);
    try testing.expectError(error.UnsupportedIndexVersion, result);
}
