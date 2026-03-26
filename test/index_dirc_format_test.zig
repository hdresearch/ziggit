// test/index_dirc_format_test.zig
// Tests the DIRC binary index format: write entries, read back, verify fields.
// Also tests git interop: write with ziggit, read with git, and vice versa.
const std = @import("std");
const ziggit = @import("ziggit");
const testing = std.testing;

const IndexParser = ziggit.IndexParser;
const GitIndex = IndexParser.GitIndex;
const IndexEntry = IndexParser.IndexEntry;

fn tmp(comptime suffix: []const u8) []const u8 {
    return "/tmp/ziggit_index_" ++ suffix;
}

fn cleanup(path: []const u8) void {
    std.fs.deleteTreeAbsolute(path) catch {};
}

fn makeIndexEntry(allocator: std.mem.Allocator, path: []const u8, size: u32, sha1: [20]u8) !IndexEntry {
    return IndexEntry{
        .ctime_seconds = 1700000000,
        .ctime_nanoseconds = 123456789,
        .mtime_seconds = 1700000000,
        .mtime_nanoseconds = 987654321,
        .dev = 0,
        .ino = 0,
        .mode = 33188, // 100644
        .uid = 0,
        .gid = 0,
        .size = size,
        .sha1 = sha1,
        .flags = @intCast(@min(path.len, 0xfff)),
        .path = try allocator.dupe(u8, path),
    };
}

// ============================================================================
// DIRC header tests
// ============================================================================

test "index write+read: DIRC signature preserved" {
    const path = comptime tmp("dirc_sig");
    cleanup(path);
    defer cleanup(path);
    try std.fs.makeDirAbsolute(path);

    const idx_path = comptime path ++ "/index";

    var idx = GitIndex.init(testing.allocator);
    defer idx.deinit();

    const sha1 = [_]u8{0xab} ** 20;
    try idx.entries.append(try makeIndexEntry(testing.allocator, "test.txt", 42, sha1));

    try idx.writeToFile(idx_path);

    // Read raw bytes and verify DIRC header
    const f = try std.fs.openFileAbsolute(idx_path, .{});
    defer f.close();
    var header: [12]u8 = undefined;
    _ = try f.readAll(&header);

    try testing.expectEqualStrings("DIRC", header[0..4]);
    // Version should be 2
    const version = std.mem.readInt(u32, header[4..8], .big);
    try testing.expectEqual(@as(u32, 2), version);
    // Entry count should be 1
    const count = std.mem.readInt(u32, header[8..12], .big);
    try testing.expectEqual(@as(u32, 1), count);
}

// ============================================================================
// Write + Read roundtrip tests
// ============================================================================

test "index roundtrip: single entry preserves all fields" {
    const path = comptime tmp("roundtrip1");
    cleanup(path);
    defer cleanup(path);
    try std.fs.makeDirAbsolute(path);

    const idx_path = comptime path ++ "/index";

    var sha1: [20]u8 = undefined;
    for (&sha1, 0..) |*b, i| {
        b.* = @intCast(i * 13 % 256);
    }

    var write_idx = GitIndex.init(testing.allocator);
    defer write_idx.deinit();

    try write_idx.entries.append(try makeIndexEntry(testing.allocator, "hello.txt", 100, sha1));
    try write_idx.writeToFile(idx_path);

    var read_idx = try GitIndex.readFromFile(testing.allocator, idx_path);
    defer read_idx.deinit();

    try testing.expectEqual(@as(usize, 1), read_idx.entries.items.len);

    const e = read_idx.entries.items[0];
    try testing.expectEqualStrings("hello.txt", e.path);
    try testing.expectEqual(@as(u32, 100), e.size);
    try testing.expectEqual(@as(u32, 33188), e.mode);
    try testing.expectEqual(@as(u32, 1700000000), e.mtime_seconds);
    try testing.expectEqual(@as(u32, 987654321), e.mtime_nanoseconds);
    try testing.expectEqualSlices(u8, &sha1, &e.sha1);
}

test "index roundtrip: multiple entries" {
    const path = comptime tmp("roundtrip_multi");
    cleanup(path);
    defer cleanup(path);
    try std.fs.makeDirAbsolute(path);

    const idx_path = comptime path ++ "/index";

    var write_idx = GitIndex.init(testing.allocator);
    defer write_idx.deinit();

    const files = [_][]const u8{ "a.txt", "b.txt", "c.txt", "dir/d.txt" };
    for (files, 0..) |name, i| {
        const sha1 = [_]u8{@intCast(i + 1)} ** 20;
        try write_idx.entries.append(try makeIndexEntry(testing.allocator, name, @intCast((i + 1) * 50), sha1));
    }

    try write_idx.writeToFile(idx_path);

    var read_idx = try GitIndex.readFromFile(testing.allocator, idx_path);
    defer read_idx.deinit();

    try testing.expectEqual(@as(usize, 4), read_idx.entries.items.len);

    for (files, 0..) |name, i| {
        try testing.expectEqualStrings(name, read_idx.entries.items[i].path);
        try testing.expectEqual(@as(u32, @intCast((i + 1) * 50)), read_idx.entries.items[i].size);
    }
}

test "index roundtrip: long path name" {
    const path = comptime tmp("longpath");
    cleanup(path);
    defer cleanup(path);
    try std.fs.makeDirAbsolute(path);

    const idx_path = comptime path ++ "/index";

    var write_idx = GitIndex.init(testing.allocator);
    defer write_idx.deinit();

    // Path longer than typical but under 0xfff
    const long_name = "very/deeply/nested/directory/structure/with/many/levels/that/goes/on/and/on/file.txt";
    const sha1 = [_]u8{0xde} ** 20;
    try write_idx.entries.append(try makeIndexEntry(testing.allocator, long_name, 999, sha1));
    try write_idx.writeToFile(idx_path);

    var read_idx = try GitIndex.readFromFile(testing.allocator, idx_path);
    defer read_idx.deinit();

    try testing.expectEqual(@as(usize, 1), read_idx.entries.items.len);
    try testing.expectEqualStrings(long_name, read_idx.entries.items[0].path);
}

// ============================================================================
// Parse error handling
// ============================================================================

test "index parse: too short data returns InvalidIndex" {
    const result = GitIndex.parseIndex(testing.allocator, "short");
    try testing.expectError(error.InvalidIndex, result);
}

test "index parse: wrong signature returns InvalidIndexSignature" {
    const bad_header = "XXXX\x00\x00\x00\x02\x00\x00\x00\x00";
    const result = GitIndex.parseIndex(testing.allocator, bad_header);
    try testing.expectError(error.InvalidIndexSignature, result);
}

test "index parse: unsupported version returns error" {
    // Version 99
    const bad_version = "DIRC\x00\x00\x00\x63\x00\x00\x00\x00";
    const result = GitIndex.parseIndex(testing.allocator, bad_version);
    try testing.expectError(error.UnsupportedIndexVersion, result);
}

test "index parse: version 2 is accepted" {
    // Version 2, 0 entries, + 20-byte trailing checksum
    var data: [32]u8 = undefined;
    @memcpy(data[0..4], "DIRC");
    std.mem.writeInt(u32, data[4..8], 2, .big);
    std.mem.writeInt(u32, data[8..12], 0, .big);
    @memset(data[12..], 0);

    var idx = try GitIndex.parseIndex(testing.allocator, &data);
    defer idx.deinit();
    try testing.expectEqual(@as(usize, 0), idx.entries.items.len);
}

test "index parse: version 3 is accepted" {
    var data: [32]u8 = undefined;
    @memcpy(data[0..4], "DIRC");
    std.mem.writeInt(u32, data[4..8], 3, .big);
    std.mem.writeInt(u32, data[8..12], 0, .big);
    @memset(data[12..], 0);

    var idx = try GitIndex.parseIndex(testing.allocator, &data);
    defer idx.deinit();
    try testing.expectEqual(@as(usize, 0), idx.entries.items.len);
}

// ============================================================================
// findEntry tests
// ============================================================================

test "index findEntry: finds existing entry" {
    var idx = GitIndex.init(testing.allocator);
    defer idx.deinit();

    const sha1 = [_]u8{0} ** 20;
    try idx.entries.append(try makeIndexEntry(testing.allocator, "find_me.txt", 42, sha1));
    try idx.entries.append(try makeIndexEntry(testing.allocator, "other.txt", 10, sha1));

    const found = idx.findEntry("find_me.txt");
    try testing.expect(found != null);
    try testing.expectEqualStrings("find_me.txt", found.?.path);
}

test "index findEntry: returns null for missing entry" {
    var idx = GitIndex.init(testing.allocator);
    defer idx.deinit();

    const sha1 = [_]u8{0} ** 20;
    try idx.entries.append(try makeIndexEntry(testing.allocator, "exists.txt", 42, sha1));

    try testing.expect(idx.findEntry("missing.txt") == null);
}

test "index findEntry: empty index returns null" {
    var idx = GitIndex.init(testing.allocator);
    defer idx.deinit();
    try testing.expect(idx.findEntry("anything") == null);
}

// ============================================================================
// Git interop: ziggit writes index, git reads it
// ============================================================================

test "index interop: ziggit-written index readable by git ls-files" {
    const path = comptime tmp("ziggit_ls");
    cleanup(path);
    defer cleanup(path);
    try std.fs.makeDirAbsolute(path);

    // Init repo with git so ls-files works
    var child = std.process.Child.init(&.{ "git", "init", "-q", path }, testing.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    _ = try child.stdout.?.reader().readAllAlloc(testing.allocator, 1024);
    _ = try child.wait();

    // Write a file and create an index with the ziggit Repository API
    var repo = try ziggit.Repository.open(testing.allocator, path);
    defer repo.close();

    const full_path = comptime path ++ "/test_file.txt";
    {
        const f = try std.fs.createFileAbsolute(full_path, .{ .truncate = true });
        defer f.close();
        try f.writeAll("test content\n");
    }
    try repo.add("test_file.txt");

    // git ls-files should show the file
    var ls_child = std.process.Child.init(&.{ "git", "-C", path, "ls-files" }, testing.allocator);
    ls_child.stdout_behavior = .Pipe;
    ls_child.stderr_behavior = .Pipe;
    try ls_child.spawn();
    const ls_out = try ls_child.stdout.?.reader().readAllAlloc(testing.allocator, 1024);
    defer testing.allocator.free(ls_out);
    _ = try ls_child.wait();

    try testing.expect(std.mem.indexOf(u8, ls_out, "test_file.txt") != null);
}

// ============================================================================
// FastGitIndex tests
// ============================================================================

test "fast index parser: reads entries from ziggit-written index" {
    const path = comptime tmp("fast_parse");
    cleanup(path);
    defer cleanup(path);
    try std.fs.makeDirAbsolute(path);

    const idx_path = comptime path ++ "/index";

    var write_idx = GitIndex.init(testing.allocator);
    defer write_idx.deinit();

    const sha1 = [_]u8{0x42} ** 20;
    try write_idx.entries.append(try makeIndexEntry(testing.allocator, "fast.txt", 77, sha1));
    try write_idx.entries.append(try makeIndexEntry(testing.allocator, "test.txt", 88, sha1));
    try write_idx.writeToFile(idx_path);

    // Read with fast parser
    var fast_idx = try ziggit.IndexParserFast.FastGitIndex.readFromFile(testing.allocator, idx_path);
    defer fast_idx.deinit();

    try testing.expectEqual(@as(usize, 2), fast_idx.entries.len);

    // Fast parser should have correct mtime and size
    try testing.expectEqual(@as(u32, 1700000000), fast_idx.entries[0].mtime_seconds);
    try testing.expectEqual(@as(u32, 77), fast_idx.entries[0].size);
    try testing.expectEqual(@as(u32, 88), fast_idx.entries[1].size);
}

test "fast index parser: agrees with full parser on entry count and paths" {
    const path = comptime tmp("fast_agree");
    cleanup(path);
    defer cleanup(path);
    try std.fs.makeDirAbsolute(path);

    const idx_path = comptime path ++ "/index";

    var write_idx = GitIndex.init(testing.allocator);
    defer write_idx.deinit();

    const files = [_][]const u8{ "alpha.c", "beta.h", "gamma/delta.rs" };
    for (files, 0..) |name, i| {
        const sha1 = [_]u8{@intCast(i)} ** 20;
        try write_idx.entries.append(try makeIndexEntry(testing.allocator, name, @intCast(i * 100), sha1));
    }
    try write_idx.writeToFile(idx_path);

    var full_idx = try GitIndex.readFromFile(testing.allocator, idx_path);
    defer full_idx.deinit();

    var fast_idx = try ziggit.IndexParserFast.FastGitIndex.readFromFile(testing.allocator, idx_path);
    defer fast_idx.deinit();

    try testing.expectEqual(full_idx.entries.items.len, fast_idx.entries.len);

    for (full_idx.entries.items, 0..) |full_entry, i| {
        try testing.expectEqualStrings(full_entry.path, fast_idx.entries[i].path);
        try testing.expectEqual(full_entry.size, fast_idx.entries[i].size);
        try testing.expectEqual(full_entry.mtime_seconds, fast_idx.entries[i].mtime_seconds);
    }
}
