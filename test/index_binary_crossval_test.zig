// test/index_binary_crossval_test.zig
// Tests for the DIRC binary index format using the internal git module.
// Verifies entry serialization, roundtrip, DIRC magic, and checksum correctness.
// Cross-validates with git CLI.
const std = @import("std");
const git = @import("git");
const testing = std.testing;

fn tmpPath(comptime suffix: []const u8) []const u8 {
    return "/tmp/ziggit_idx_binxval_" ++ suffix;
}

fn cleanup(path: []const u8) void {
    std.fs.deleteTreeAbsolute(path) catch {};
}

fn runGit(args: []const []const u8, cwd: []const u8) ![]u8 {
    var child = std.process.Child.init(args, testing.allocator);
    child.cwd = cwd;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const stdout = try child.stdout.?.reader().readAllAlloc(testing.allocator, 1024 * 1024);
    const stderr = try child.stderr.?.reader().readAllAlloc(testing.allocator, 1024 * 1024);
    defer testing.allocator.free(stderr);
    const term = try child.wait();
    if (term.Exited != 0) {
        testing.allocator.free(stdout);
        return error.GitCommandFailed;
    }
    return stdout;
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

// === IndexEntry serialization tests ===

test "IndexEntry: writeToBuffer then readFromBuffer preserves all fields" {
    var buf = std.ArrayList(u8).init(testing.allocator);
    defer buf.deinit();

    const entry = git.index.IndexEntry{
        .ctime_sec = 1234567890,
        .ctime_nsec = 123456,
        .mtime_sec = 1234567891,
        .mtime_nsec = 654321,
        .dev = 42,
        .ino = 100,
        .mode = 33188,
        .uid = 1000,
        .gid = 1000,
        .size = 42,
        .sha1 = [_]u8{ 0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x01 },
        .flags = 7,
        .extended_flags = null,
        .path = "foo.txt",
    };

    try entry.writeToBuffer(buf.writer());

    var stream = std.io.fixedBufferStream(buf.items);
    const read_entry = try git.index.IndexEntry.readFromBuffer(stream.reader(), testing.allocator);
    defer testing.allocator.free(read_entry.path);

    try testing.expectEqual(entry.ctime_sec, read_entry.ctime_sec);
    try testing.expectEqual(entry.ctime_nsec, read_entry.ctime_nsec);
    try testing.expectEqual(entry.mtime_sec, read_entry.mtime_sec);
    try testing.expectEqual(entry.mtime_nsec, read_entry.mtime_nsec);
    try testing.expectEqual(entry.dev, read_entry.dev);
    try testing.expectEqual(entry.ino, read_entry.ino);
    try testing.expectEqual(entry.mode, read_entry.mode);
    try testing.expectEqual(entry.uid, read_entry.uid);
    try testing.expectEqual(entry.gid, read_entry.gid);
    try testing.expectEqual(entry.size, read_entry.size);
    try testing.expectEqualSlices(u8, &entry.sha1, &read_entry.sha1);
    try testing.expectEqualStrings(entry.path, read_entry.path);
}

test "IndexEntry: entry size is padded to 8-byte boundary" {
    var buf = std.ArrayList(u8).init(testing.allocator);
    defer buf.deinit();

    const entry = git.index.IndexEntry{
        .ctime_sec = 0,
        .ctime_nsec = 0,
        .mtime_sec = 0,
        .mtime_nsec = 0,
        .dev = 0,
        .ino = 0,
        .mode = 33188,
        .uid = 0,
        .gid = 0,
        .size = 0,
        .sha1 = [_]u8{0} ** 20,
        .flags = 3,
        .extended_flags = null,
        .path = "abc",
    };

    try entry.writeToBuffer(buf.writer());
    try testing.expectEqual(@as(usize, 0), buf.items.len % 8);
}

test "IndexEntry: different path lengths all produce 8-byte aligned output" {
    const paths = [_][]const u8{ "a", "ab", "abc", "abcd", "abcde", "abcdef", "abcdefg", "abcdefgh" };

    for (paths) |path| {
        var buf = std.ArrayList(u8).init(testing.allocator);
        defer buf.deinit();

        const entry = git.index.IndexEntry{
            .ctime_sec = 0,
            .ctime_nsec = 0,
            .mtime_sec = 0,
            .mtime_nsec = 0,
            .dev = 0,
            .ino = 0,
            .mode = 33188,
            .uid = 0,
            .gid = 0,
            .size = 0,
            .sha1 = [_]u8{0} ** 20,
            .flags = @intCast(path.len),
            .extended_flags = null,
            .path = path,
        };

        try entry.writeToBuffer(buf.writer());
        try testing.expectEqual(@as(usize, 0), buf.items.len % 8);
    }
}

test "IndexEntry: long path roundtrips" {
    var buf = std.ArrayList(u8).init(testing.allocator);
    defer buf.deinit();

    const long_path = "very/long/nested/directory/structure/that/goes/really/deep/file.txt";
    const entry = git.index.IndexEntry{
        .ctime_sec = 0,
        .ctime_nsec = 0,
        .mtime_sec = 0,
        .mtime_nsec = 0,
        .dev = 0,
        .ino = 0,
        .mode = 33188,
        .uid = 0,
        .gid = 0,
        .size = 100,
        .sha1 = [_]u8{0xaa} ** 20,
        .flags = @intCast(@min(long_path.len, 0xfff)),
        .extended_flags = null,
        .path = long_path,
    };

    try entry.writeToBuffer(buf.writer());
    var stream = std.io.fixedBufferStream(buf.items);
    const read_entry = try git.index.IndexEntry.readFromBuffer(stream.reader(), testing.allocator);
    defer testing.allocator.free(read_entry.path);

    try testing.expectEqualStrings(long_path, read_entry.path);
}

test "IndexEntry: executable mode (100755) roundtrips" {
    var buf = std.ArrayList(u8).init(testing.allocator);
    defer buf.deinit();

    const entry = git.index.IndexEntry{
        .ctime_sec = 0,
        .ctime_nsec = 0,
        .mtime_sec = 0,
        .mtime_nsec = 0,
        .dev = 0,
        .ino = 0,
        .mode = 33261, // 100755
        .uid = 0,
        .gid = 0,
        .size = 0,
        .sha1 = [_]u8{0} ** 20,
        .flags = 6,
        .extended_flags = null,
        .path = "run.sh",
    };

    try entry.writeToBuffer(buf.writer());
    var stream = std.io.fixedBufferStream(buf.items);
    const read_entry = try git.index.IndexEntry.readFromBuffer(stream.reader(), testing.allocator);
    defer testing.allocator.free(read_entry.path);

    try testing.expectEqual(@as(u32, 33261), read_entry.mode);
}

// === Index parseIndexData tests ===

test "Index: parseIndexData on DIRC header" {
    // Construct minimal valid DIRC index: magic + version 2 + 0 entries + SHA-1 checksum
    var buf = std.ArrayList(u8).init(testing.allocator);
    defer buf.deinit();

    // DIRC magic
    try buf.appendSlice("DIRC");
    // Version 2
    try buf.writer().writeInt(u32, 2, .big);
    // 0 entries
    try buf.writer().writeInt(u32, 0, .big);

    // Compute SHA-1 checksum
    var sha: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(buf.items, &sha, .{});
    try buf.appendSlice(&sha);

    var idx = git.index.Index.init(testing.allocator);
    defer idx.deinit();

    try idx.parseIndexData(buf.items);
    try testing.expectEqual(@as(usize, 0), idx.entries.items.len);
}

// === Git-created index readable by ziggit ===

test "ziggit parseIndexData reads git-created index" {
    const path = tmpPath("parse_git_idx");
    cleanup(path);
    defer cleanup(path);

    try runGitNoCheck(&.{ "git", "init", "-q", path }, "/tmp");
    try runGitNoCheck(&.{ "git", "config", "user.email", "t@t.com" }, path);
    try runGitNoCheck(&.{ "git", "config", "user.name", "Test" }, path);
    try createFile(path, "a.txt", "aaa");
    try createFile(path, "b.txt", "bbb");
    try runGitNoCheck(&.{ "git", "add", "." }, path);
    try runGitNoCheck(&.{ "git", "commit", "-q", "-m", "init" }, path);

    const idx_path = try std.fmt.allocPrint(testing.allocator, "{s}/.git/index", .{path});
    defer testing.allocator.free(idx_path);

    const data = try std.fs.cwd().readFileAlloc(testing.allocator, idx_path, 1024 * 1024);
    defer testing.allocator.free(data);

    var idx = git.index.Index.init(testing.allocator);
    defer idx.deinit();
    try idx.parseIndexData(data);

    try testing.expect(idx.entries.items.len >= 2);

    var found_a = false;
    var found_b = false;
    for (idx.entries.items) |entry| {
        if (std.mem.eql(u8, entry.path, "a.txt")) found_a = true;
        if (std.mem.eql(u8, entry.path, "b.txt")) found_b = true;
    }
    try testing.expect(found_a);
    try testing.expect(found_b);
}

test "ziggit reads git index entry SHA-1 correctly" {
    const path = tmpPath("idx_sha1");
    cleanup(path);
    defer cleanup(path);

    try runGitNoCheck(&.{ "git", "init", "-q", path }, "/tmp");
    try runGitNoCheck(&.{ "git", "config", "user.email", "t@t.com" }, path);
    try runGitNoCheck(&.{ "git", "config", "user.name", "Test" }, path);
    try createFile(path, "hello.txt", "hello world\n");
    try runGitNoCheck(&.{ "git", "add", "hello.txt" }, path);

    // Get expected hash from git
    const hash_out = try runGit(&.{ "git", "hash-object", "hello.txt" }, path);
    defer testing.allocator.free(hash_out);
    const expected_hash = std.mem.trim(u8, hash_out, " \n\r\t");

    // Read index
    const idx_path = try std.fmt.allocPrint(testing.allocator, "{s}/.git/index", .{path});
    defer testing.allocator.free(idx_path);
    const data = try std.fs.cwd().readFileAlloc(testing.allocator, idx_path, 1024 * 1024);
    defer testing.allocator.free(data);

    var idx = git.index.Index.init(testing.allocator);
    defer idx.deinit();
    try idx.parseIndexData(data);

    try testing.expect(idx.entries.items.len >= 1);
    const entry = idx.entries.items[0];

    // Convert SHA-1 bytes to hex string
    var hex_buf: [40]u8 = undefined;
    _ = std.fmt.bufPrint(&hex_buf, "{s}", .{std.fmt.fmtSliceHexLower(&entry.sha1)}) catch unreachable;

    try testing.expectEqualStrings(expected_hash, &hex_buf);
}

test "ziggit reads git index file size correctly" {
    const path = tmpPath("idx_size");
    cleanup(path);
    defer cleanup(path);

    try runGitNoCheck(&.{ "git", "init", "-q", path }, "/tmp");
    try runGitNoCheck(&.{ "git", "config", "user.email", "t@t.com" }, path);
    try runGitNoCheck(&.{ "git", "config", "user.name", "Test" }, path);
    try createFile(path, "data.txt", "exactly 22 bytes long!");
    try runGitNoCheck(&.{ "git", "add", "data.txt" }, path);

    const idx_path = try std.fmt.allocPrint(testing.allocator, "{s}/.git/index", .{path});
    defer testing.allocator.free(idx_path);
    const data = try std.fs.cwd().readFileAlloc(testing.allocator, idx_path, 1024 * 1024);
    defer testing.allocator.free(data);

    var idx = git.index.Index.init(testing.allocator);
    defer idx.deinit();
    try idx.parseIndexData(data);

    try testing.expect(idx.entries.items.len >= 1);
    try testing.expectEqual(@as(u32, 22), idx.entries.items[0].size);
}
