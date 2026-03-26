// test/index_write_read_test.zig - Tests for index save/load roundtrip
// Tests that indices written via the internal git module can be read back,
// and that git CLI can read indices written by ziggit (and vice versa).
const std = @import("std");
const testing = std.testing;
const git = @import("git");

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
        pub fn readDir(allocator: std.mem.Allocator, path: []const u8) ![][]u8 {
            var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch return error.FileNotFound;
            defer dir.close();
            var list = std.ArrayList([]u8).init(allocator);
            var iter = dir.iterate();
            while (try iter.next()) |entry| {
                try list.append(try allocator.dupe(u8, entry.name));
            }
            return try list.toOwnedSlice();
        }
    };
};

// ============================================================================
// Index save/load roundtrip
// ============================================================================

test "index save then load: entries preserved" {
    const tmp = "/tmp/ziggit_idx_wr_roundtrip";
    try setupGitDir(tmp);
    defer std.fs.deleteTreeAbsolute(tmp) catch {};

    const git_dir = tmp ++ "/.git";

    // Create an index with one entry
    var idx = git.index.Index.init(testing.allocator);
    defer idx.deinit();

    // Add a file to the index using the add method
    {
        const f = try std.fs.createFileAbsolute(tmp ++ "/hello.txt", .{});
        defer f.close();
        try f.writeAll("hello world\n");
    }

    try idx.add("hello.txt", tmp ++ "/hello.txt", platform, git_dir);

    // Save index
    try idx.save(git_dir, platform);

    // Load it back
    var idx2 = git.index.Index.init(testing.allocator);
    defer idx2.deinit();

    const index_path = tmp ++ "/.git/index";
    const index_data = try std.fs.cwd().readFileAlloc(testing.allocator, index_path, 10 * 1024 * 1024);
    defer testing.allocator.free(index_data);
    try idx2.parseIndexData(index_data);

    // Should have 1 entry
    try testing.expect(idx2.entries.items.len == 1);

    // Path should match
    const entry = idx2.getEntry("hello.txt");
    try testing.expect(entry != null);
    try testing.expectEqualStrings("hello.txt", entry.?.path);
}

test "index save: git ls-files can read it" {
    const tmp = "/tmp/ziggit_idx_wr_lsfiles";
    try setupGitDir(tmp);
    defer std.fs.deleteTreeAbsolute(tmp) catch {};

    const git_dir = tmp ++ "/.git";

    var idx = git.index.Index.init(testing.allocator);
    defer idx.deinit();

    {
        const f = try std.fs.createFileAbsolute(tmp ++ "/test.txt", .{});
        defer f.close();
        try f.writeAll("test content\n");
    }

    try idx.add("test.txt", tmp ++ "/test.txt", platform, git_dir);
    try idx.save(git_dir, platform);

    // git ls-files should show our file
    const output = try runCmd(&.{ "git", "-C", tmp, "ls-files" });
    defer testing.allocator.free(output);
    const trimmed = std.mem.trim(u8, output, " \t\n\r");

    try testing.expectEqualStrings("test.txt", trimmed);
}

test "index save: multiple files ordered correctly" {
    const tmp = "/tmp/ziggit_idx_wr_multi";
    try setupGitDir(tmp);
    defer std.fs.deleteTreeAbsolute(tmp) catch {};

    const git_dir = tmp ++ "/.git";

    var idx = git.index.Index.init(testing.allocator);
    defer idx.deinit();

    // Create files
    const files = [_]struct { name: []const u8, content: []const u8 }{
        .{ .name = "c.txt", .content = "ccc\n" },
        .{ .name = "a.txt", .content = "aaa\n" },
        .{ .name = "b.txt", .content = "bbb\n" },
    };

    for (files) |f| {
        const path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ tmp, f.name });
        defer testing.allocator.free(path);
        const file = try std.fs.createFileAbsolute(path, .{});
        defer file.close();
        try file.writeAll(f.content);
    }

    for (files) |f| {
        const full_path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ tmp, f.name });
        defer testing.allocator.free(full_path);
        try idx.add(f.name, full_path, platform, git_dir);
    }

    try idx.save(git_dir, platform);

    // git ls-files should list all files
    const output = try runCmd(&.{ "git", "-C", tmp, "ls-files" });
    defer testing.allocator.free(output);

    // Count lines
    var line_count: usize = 0;
    var iter = std.mem.splitScalar(u8, std.mem.trim(u8, output, "\n"), '\n');
    while (iter.next()) |_| line_count += 1;

    try testing.expect(line_count == 3);
}

test "index save: SHA-1 checksums match git hash-object" {
    const tmp = "/tmp/ziggit_idx_wr_sha1";
    try setupGitDir(tmp);
    defer std.fs.deleteTreeAbsolute(tmp) catch {};

    const git_dir = tmp ++ "/.git";

    var idx = git.index.Index.init(testing.allocator);
    defer idx.deinit();

    const content = "sha1 test content\n";
    {
        const f = try std.fs.createFileAbsolute(tmp ++ "/sha1.txt", .{});
        defer f.close();
        try f.writeAll(content);
    }

    try idx.add("sha1.txt", tmp ++ "/sha1.txt", platform, git_dir);
    try idx.save(git_dir, platform);

    // Get git's hash
    const hash_output = try runCmd(&.{ "git", "-C", tmp, "hash-object", "sha1.txt" });
    defer testing.allocator.free(hash_output);
    const git_hash = std.mem.trim(u8, hash_output, " \t\n\r");

    // Get hash from index
    const index_data = try std.fs.cwd().readFileAlloc(testing.allocator, tmp ++ "/.git/index", 10 * 1024 * 1024);
    defer testing.allocator.free(index_data);

    var idx2 = git.index.Index.init(testing.allocator);
    defer idx2.deinit();
    try idx2.parseIndexData(index_data);

    const entry = idx2.getEntry("sha1.txt").?;
    var sha_hex: [40]u8 = undefined;
    _ = std.fmt.bufPrint(&sha_hex, "{}", .{std.fmt.fmtSliceHexLower(&entry.sha1)}) catch unreachable;

    try testing.expectEqualStrings(git_hash, &sha_hex);
}

// ============================================================================
// Index: git writes, ziggit reads
// ============================================================================

test "git-created index: ziggit reads all entries" {
    const tmp = "/tmp/ziggit_idx_wr_gitreads";
    std.fs.deleteTreeAbsolute(tmp) catch {};
    defer std.fs.deleteTreeAbsolute(tmp) catch {};

    _ = try runCmd(&.{ "git", "init", "-q", tmp });
    _ = try runCmd(&.{ "git", "-C", tmp, "config", "user.email", "t@t.com" });
    _ = try runCmd(&.{ "git", "-C", tmp, "config", "user.name", "T" });

    // Create 5 files
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        const name = try std.fmt.allocPrint(testing.allocator, "{s}/file{d}.txt", .{ tmp, i });
        defer testing.allocator.free(name);
        const f = try std.fs.createFileAbsolute(name, .{});
        defer f.close();
        const content = try std.fmt.allocPrint(testing.allocator, "content {d}\n", .{i});
        defer testing.allocator.free(content);
        try f.writeAll(content);
    }

    _ = try runCmd(&.{ "git", "-C", tmp, "add", "." });

    // Read index with ziggit
    const index_data = try std.fs.cwd().readFileAlloc(testing.allocator, tmp ++ "/.git/index", 10 * 1024 * 1024);
    defer testing.allocator.free(index_data);

    var idx = git.index.Index.init(testing.allocator);
    defer idx.deinit();
    try idx.parseIndexData(index_data);

    try testing.expect(idx.entries.items.len == 5);
}

test "git-created index with executable: mode preserved" {
    const tmp = "/tmp/ziggit_idx_wr_exec";
    std.fs.deleteTreeAbsolute(tmp) catch {};
    defer std.fs.deleteTreeAbsolute(tmp) catch {};

    _ = try runCmd(&.{ "git", "init", "-q", tmp });
    _ = try runCmd(&.{ "git", "-C", tmp, "config", "user.email", "t@t.com" });
    _ = try runCmd(&.{ "git", "-C", tmp, "config", "user.name", "T" });

    {
        const f = try std.fs.createFileAbsolute(tmp ++ "/script.sh", .{});
        defer f.close();
        try f.writeAll("#!/bin/bash\necho hi\n");
    }
    _ = try runCmd(&.{ "chmod", "+x", tmp ++ "/script.sh" });
    _ = try runCmd(&.{ "git", "-C", tmp, "add", "script.sh" });

    const index_data = try std.fs.cwd().readFileAlloc(testing.allocator, tmp ++ "/.git/index", 10 * 1024 * 1024);
    defer testing.allocator.free(index_data);

    var idx = git.index.Index.init(testing.allocator);
    defer idx.deinit();
    try idx.parseIndexData(index_data);

    const entry = idx.getEntry("script.sh").?;
    // Git stores executable files as mode 0o100755 = 33261
    try testing.expect(entry.mode == 0o100755);
}

// ============================================================================
// IndexEntry writeToBuffer/readFromBuffer roundtrip
// ============================================================================

test "IndexEntry writeToBuffer then readFromBuffer roundtrip" {
    var buf = std.ArrayList(u8).init(testing.allocator);
    defer buf.deinit();

    const sha1 = [_]u8{ 0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x01 };

    const path = try testing.allocator.dupe(u8, "src/main.zig");

    const entry = git.index.IndexEntry{
        .ctime_sec = 1000,
        .ctime_nsec = 500,
        .mtime_sec = 2000,
        .mtime_nsec = 600,
        .dev = 1,
        .ino = 42,
        .mode = 0o100644,
        .uid = 1000,
        .gid = 1000,
        .size = 1234,
        .sha1 = sha1,
        .flags = @intCast(path.len),
        .extended_flags = null,
        .path = path,
    };
    defer testing.allocator.free(path);

    try entry.writeToBuffer(buf.writer());

    var stream = std.io.fixedBufferStream(buf.items);
    var read_entry = try git.index.IndexEntry.readFromBuffer(stream.reader(), testing.allocator);
    defer read_entry.deinit(testing.allocator);

    try testing.expect(read_entry.ctime_sec == 1000);
    try testing.expect(read_entry.mtime_sec == 2000);
    try testing.expect(read_entry.mode == 0o100644);
    try testing.expect(read_entry.size == 1234);
    try testing.expectEqualSlices(u8, &sha1, &read_entry.sha1);
    try testing.expectEqualStrings("src/main.zig", read_entry.path);
}

test "IndexEntry writeToBuffer padding is correct" {
    var buf = std.ArrayList(u8).init(testing.allocator);
    defer buf.deinit();

    const sha1 = [_]u8{0} ** 20;

    // Test various path lengths to ensure padding works
    const path_lengths = [_]usize{ 1, 2, 5, 7, 8, 9, 15, 16, 17, 100 };

    for (path_lengths) |plen| {
        buf.clearRetainingCapacity();

        const path = try testing.allocator.alloc(u8, plen);
        defer testing.allocator.free(path);
        @memset(path, 'a');

        const entry = git.index.IndexEntry{
            .ctime_sec = 0,
            .ctime_nsec = 0,
            .mtime_sec = 0,
            .mtime_nsec = 0,
            .dev = 0,
            .ino = 0,
            .mode = 0o100644,
            .uid = 0,
            .gid = 0,
            .size = 0,
            .sha1 = sha1,
            .flags = @intCast(@min(plen, 0xFFF)),
            .extended_flags = null,
            .path = path,
        };

        try entry.writeToBuffer(buf.writer());

        // Total size must be multiple of 8
        try testing.expect(buf.items.len % 8 == 0);
    }
}

// ============================================================================
// Index integrity: checksum validation
// ============================================================================

test "index binary format starts with DIRC magic" {
    const tmp = "/tmp/ziggit_idx_wr_magic";
    try setupGitDir(tmp);
    defer std.fs.deleteTreeAbsolute(tmp) catch {};

    const git_dir = tmp ++ "/.git";

    var idx = git.index.Index.init(testing.allocator);
    defer idx.deinit();

    {
        const f = try std.fs.createFileAbsolute(tmp ++ "/x.txt", .{});
        defer f.close();
        try f.writeAll("x");
    }
    try idx.add("x.txt", tmp ++ "/x.txt", platform, git_dir);
    try idx.save(git_dir, platform);

    const data = try std.fs.cwd().readFileAlloc(testing.allocator, tmp ++ "/.git/index", 10 * 1024 * 1024);
    defer testing.allocator.free(data);

    try testing.expectEqualStrings("DIRC", data[0..4]);
    // Version 2
    try testing.expect(std.mem.readInt(u32, data[4..8], .big) == 2);
    // 1 entry
    try testing.expect(std.mem.readInt(u32, data[8..12], .big) == 1);
}

test "index checksum: last 20 bytes are SHA-1 of preceding data" {
    const tmp = "/tmp/ziggit_idx_wr_checksum";
    try setupGitDir(tmp);
    defer std.fs.deleteTreeAbsolute(tmp) catch {};

    const git_dir = tmp ++ "/.git";

    var idx = git.index.Index.init(testing.allocator);
    defer idx.deinit();

    {
        const f = try std.fs.createFileAbsolute(tmp ++ "/f.txt", .{});
        defer f.close();
        try f.writeAll("checksum test\n");
    }
    try idx.add("f.txt", tmp ++ "/f.txt", platform, git_dir);
    try idx.save(git_dir, platform);

    const data = try std.fs.cwd().readFileAlloc(testing.allocator, tmp ++ "/.git/index", 10 * 1024 * 1024);
    defer testing.allocator.free(data);

    // Last 20 bytes should be SHA-1 of everything before
    const content = data[0 .. data.len - 20];
    const stored_checksum = data[data.len - 20 ..];

    var expected: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(content, &expected, .{});

    try testing.expectEqualSlices(u8, &expected, stored_checksum);
}

// ============================================================================
// Index: empty index
// ============================================================================

test "save and load empty index" {
    const tmp = "/tmp/ziggit_idx_wr_empty";
    try setupGitDir(tmp);
    defer std.fs.deleteTreeAbsolute(tmp) catch {};

    const git_dir = tmp ++ "/.git";

    var idx = git.index.Index.init(testing.allocator);
    defer idx.deinit();

    try idx.save(git_dir, platform);

    // Read it back
    const data = try std.fs.cwd().readFileAlloc(testing.allocator, tmp ++ "/.git/index", 10 * 1024 * 1024);
    defer testing.allocator.free(data);

    var idx2 = git.index.Index.init(testing.allocator);
    defer idx2.deinit();
    try idx2.parseIndexData(data);

    try testing.expect(idx2.entries.items.len == 0);
}

// ============================================================================
// Index: remove entry
// ============================================================================

test "index remove: entry disappears after save/load" {
    const tmp = "/tmp/ziggit_idx_wr_remove";
    try setupGitDir(tmp);
    defer std.fs.deleteTreeAbsolute(tmp) catch {};

    const git_dir = tmp ++ "/.git";

    // Create two files
    {
        const f = try std.fs.createFileAbsolute(tmp ++ "/keep.txt", .{});
        defer f.close();
        try f.writeAll("keep\n");
    }
    {
        const f = try std.fs.createFileAbsolute(tmp ++ "/remove.txt", .{});
        defer f.close();
        try f.writeAll("remove\n");
    }

    var idx = git.index.Index.init(testing.allocator);
    defer idx.deinit();

    try idx.add("keep.txt", tmp ++ "/keep.txt", platform, git_dir);
    try idx.add("remove.txt", tmp ++ "/remove.txt", platform, git_dir);

    // Verify both exist
    try testing.expect(idx.entries.items.len == 2);

    // Remove one
    try idx.remove("remove.txt");
    try testing.expect(idx.entries.items.len == 1);

    // Save and reload
    try idx.save(git_dir, platform);

    const data = try std.fs.cwd().readFileAlloc(testing.allocator, tmp ++ "/.git/index", 10 * 1024 * 1024);
    defer testing.allocator.free(data);

    var idx2 = git.index.Index.init(testing.allocator);
    defer idx2.deinit();
    try idx2.parseIndexData(data);

    try testing.expect(idx2.entries.items.len == 1);
    try testing.expect(idx2.getEntry("keep.txt") != null);
    try testing.expect(idx2.getEntry("remove.txt") == null);
}

// ============================================================================
// writeVarInt / readVarInt roundtrip
// ============================================================================

test "writeVarInt then readVarInt roundtrip" {
    const test_values = [_]u32{ 0, 1, 127, 128, 255, 256, 1000, 65535, 1 << 20, std.math.maxInt(u32) >> 4 };

    for (test_values) |val| {
        var buf: [8]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buf);
        try git.index.writeVarInt(stream.writer(), val);

        var read_stream = std.io.fixedBufferStream(buf[0..stream.pos]);
        const read_val = try git.index.readVarInt(read_stream.reader());

        try testing.expect(read_val == val);
    }
}

// ============================================================================
// verifyIndexIntegrity
// ============================================================================

test "verifyIndexIntegrity on valid index" {
    const tmp = "/tmp/ziggit_idx_wr_verify";
    std.fs.deleteTreeAbsolute(tmp) catch {};
    defer std.fs.deleteTreeAbsolute(tmp) catch {};

    _ = try runCmd(&.{ "git", "init", "-q", tmp });
    _ = try runCmd(&.{ "git", "-C", tmp, "config", "user.email", "t@t.com" });
    _ = try runCmd(&.{ "git", "-C", tmp, "config", "user.name", "T" });

    {
        const f = try std.fs.createFileAbsolute(tmp ++ "/f.txt", .{});
        defer f.close();
        try f.writeAll("content\n");
    }
    _ = try runCmd(&.{ "git", "-C", tmp, "add", "f.txt" });

    const data = try std.fs.cwd().readFileAlloc(testing.allocator, tmp ++ "/.git/index", 10 * 1024 * 1024);
    defer testing.allocator.free(data);

    const valid = try git.index.verifyIndexIntegrity(data);
    try testing.expect(valid);
}

test "verifyIndexIntegrity on corrupted index" {
    const tmp = "/tmp/ziggit_idx_wr_corrupt";
    std.fs.deleteTreeAbsolute(tmp) catch {};
    defer std.fs.deleteTreeAbsolute(tmp) catch {};

    _ = try runCmd(&.{ "git", "init", "-q", tmp });
    _ = try runCmd(&.{ "git", "-C", tmp, "config", "user.email", "t@t.com" });
    _ = try runCmd(&.{ "git", "-C", tmp, "config", "user.name", "T" });

    {
        const f = try std.fs.createFileAbsolute(tmp ++ "/f.txt", .{});
        defer f.close();
        try f.writeAll("content\n");
    }
    _ = try runCmd(&.{ "git", "-C", tmp, "add", "f.txt" });

    var data = try std.fs.cwd().readFileAlloc(testing.allocator, tmp ++ "/.git/index", 10 * 1024 * 1024);
    defer testing.allocator.free(data);

    // Corrupt a byte in the middle
    if (data.len > 20) {
        data[15] ^= 0xFF;
    }

    const valid = try git.index.verifyIndexIntegrity(data);
    try testing.expect(!valid);
}

// ============================================================================
// Helpers
// ============================================================================

fn setupGitDir(path: []const u8) !void {
    std.fs.deleteTreeAbsolute(path) catch {};
    _ = try runCmd(&.{ "git", "init", "-q", path });
}

fn runCmd(args: []const []const u8) ![]u8 {
    var child = std.process.Child.init(args, testing.allocator);
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
            return error.CommandFailed;
        },
        else => {
            testing.allocator.free(stdout);
            return error.CommandFailed;
        },
    }
    return stdout;
}
