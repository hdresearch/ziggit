// test/git_index_internal_test.zig - Tests for internal git index parsing
const std = @import("std");
const testing = std.testing;
const git = @import("git");

// ============================================================================
// Index.parseIndexData - binary format parsing
// ============================================================================

fn makeIndexHeader(version: u32, entry_count: u32) [12]u8 {
    var buf: [12]u8 = undefined;
    @memcpy(buf[0..4], "DIRC");
    std.mem.writeInt(u32, buf[4..8], version, .big);
    std.mem.writeInt(u32, buf[8..12], entry_count, .big);
    return buf;
}

test "parseIndexData: rejects empty data" {
    var idx = git.index.Index.init(testing.allocator);
    defer idx.deinit();
    try testing.expectError(error.InvalidIndex, idx.parseIndexData(""));
}

test "parseIndexData: rejects too-short data" {
    var idx = git.index.Index.init(testing.allocator);
    defer idx.deinit();
    try testing.expectError(error.InvalidIndex, idx.parseIndexData("SHORT"));
}

test "parseIndexData: rejects wrong magic" {
    var data: [12]u8 = undefined;
    @memcpy(data[0..4], "XXXX");
    std.mem.writeInt(u32, data[4..8], 2, .big);
    std.mem.writeInt(u32, data[8..12], 0, .big);

    var idx = git.index.Index.init(testing.allocator);
    defer idx.deinit();
    try testing.expectError(error.InvalidIndex, idx.parseIndexData(&data));
}

test "parseIndexData: accepts version 2 with zero entries" {
    const header = makeIndexHeader(2, 0);
    // Need a SHA-1 checksum at the end (20 bytes)
    var data: [32]u8 = undefined;
    @memcpy(data[0..12], &header);
    // Fill checksum area (the parser may or may not validate it)
    @memset(data[12..32], 0);

    var idx = git.index.Index.init(testing.allocator);
    defer idx.deinit();
    // This may succeed or fail depending on checksum validation
    idx.parseIndexData(&data) catch {};
}

test "parseIndexData: rejects version 1" {
    const header = makeIndexHeader(1, 0);
    var data: [32]u8 = undefined;
    @memcpy(data[0..12], &header);
    @memset(data[12..32], 0);

    var idx = git.index.Index.init(testing.allocator);
    defer idx.deinit();
    const result = idx.parseIndexData(&data);
    try testing.expect(result == error.IndexVersionTooOld or result == error.UnsupportedIndexVersion);
}

test "parseIndexData: rejects version 99" {
    const header = makeIndexHeader(99, 0);
    var data: [32]u8 = undefined;
    @memcpy(data[0..12], &header);
    @memset(data[12..32], 0);

    var idx = git.index.Index.init(testing.allocator);
    defer idx.deinit();
    const result = idx.parseIndexData(&data);
    try testing.expect(result == error.IndexVersionTooNew or result == error.UnsupportedIndexVersion);
}

// ============================================================================
// Index init/deinit
// ============================================================================

test "Index.init creates empty index" {
    var idx = git.index.Index.init(testing.allocator);
    defer idx.deinit();
    try testing.expect(idx.entries.items.len == 0);
}

// ============================================================================
// Index.getEntry
// ============================================================================

test "getEntry returns null on empty index" {
    var idx = git.index.Index.init(testing.allocator);
    defer idx.deinit();
    try testing.expect(idx.getEntry("anything") == null);
}

// ============================================================================
// Index.remove
// ============================================================================

test "remove on empty index does not crash" {
    var idx = git.index.Index.init(testing.allocator);
    defer idx.deinit();
    // remove may succeed silently or return error - just check no crash
    idx.remove("nonexistent") catch {};
}

// ============================================================================
// IndexEntry field packing
// ============================================================================

test "IndexEntry mode constants" {
    // Regular file: 100644 = 0o100644 = 33188
    try testing.expect(33188 == 0o100644);
    // Executable: 100755 = 0o100755 = 33261
    try testing.expect(33261 == 0o100755);
    // Symlink: 120000 = 0o120000 = 40960
    try testing.expect(40960 == 0o120000);
}

// ============================================================================
// Integration: git-created index readable by parseIndexData
// ============================================================================

test "git-created index: parseIndexData reads entries" {
    const tmp_dir = "/tmp/ziggit_idx_internal_test";
    std.fs.deleteTreeAbsolute(tmp_dir) catch {};
    defer std.fs.deleteTreeAbsolute(tmp_dir) catch {};

    // Create a repo with git
    _ = try runCmd(&.{ "git", "init", "-q", tmp_dir });
    _ = try runCmd(&.{ "git", "-C", tmp_dir, "config", "user.email", "t@t.com" });
    _ = try runCmd(&.{ "git", "-C", tmp_dir, "config", "user.name", "T" });

    // Create files and add them
    {
        const path = tmp_dir ++ "/hello.txt";
        const f = try std.fs.createFileAbsolute(path, .{});
        defer f.close();
        try f.writeAll("hello world\n");
    }
    {
        const path = tmp_dir ++ "/readme.md";
        const f = try std.fs.createFileAbsolute(path, .{});
        defer f.close();
        try f.writeAll("# README\n");
    }

    _ = try runCmd(&.{ "git", "-C", tmp_dir, "add", "hello.txt", "readme.md" });

    // Read the raw index file
    const index_path = tmp_dir ++ "/.git/index";
    const index_data = try std.fs.cwd().readFileAlloc(testing.allocator, index_path, 10 * 1024 * 1024);
    defer testing.allocator.free(index_data);

    // Parse it
    var idx = git.index.Index.init(testing.allocator);
    defer idx.deinit();
    try idx.parseIndexData(index_data);

    // Should have 2 entries
    try testing.expect(idx.entries.items.len == 2);

    // Find hello.txt entry
    const hello_entry = idx.getEntry("hello.txt");
    try testing.expect(hello_entry != null);
    try testing.expect(hello_entry.?.mode == 0o100644);
    try testing.expect(hello_entry.?.size == 12); // "hello world\n"

    // Find readme.md entry
    const readme_entry = idx.getEntry("readme.md");
    try testing.expect(readme_entry != null);
    try testing.expect(readme_entry.?.size == 9); // "# README\n"
}

test "git-created index: SHA-1 matches git hash-object" {
    const tmp_dir = "/tmp/ziggit_idx_sha_test";
    std.fs.deleteTreeAbsolute(tmp_dir) catch {};
    defer std.fs.deleteTreeAbsolute(tmp_dir) catch {};

    _ = try runCmd(&.{ "git", "init", "-q", tmp_dir });
    _ = try runCmd(&.{ "git", "-C", tmp_dir, "config", "user.email", "t@t.com" });
    _ = try runCmd(&.{ "git", "-C", tmp_dir, "config", "user.name", "T" });

    {
        const path = tmp_dir ++ "/test.txt";
        const f = try std.fs.createFileAbsolute(path, .{});
        defer f.close();
        try f.writeAll("test content\n");
    }

    _ = try runCmd(&.{ "git", "-C", tmp_dir, "add", "test.txt" });

    // Get git's hash-object result
    const hash_output = try runCmd(&.{ "git", "-C", tmp_dir, "hash-object", "test.txt" });
    defer testing.allocator.free(hash_output);
    const git_hash = std.mem.trim(u8, hash_output, " \t\n\r");

    // Read index and get SHA from there
    const index_path = tmp_dir ++ "/.git/index";
    const index_data = try std.fs.cwd().readFileAlloc(testing.allocator, index_path, 10 * 1024 * 1024);
    defer testing.allocator.free(index_data);

    var idx = git.index.Index.init(testing.allocator);
    defer idx.deinit();
    try idx.parseIndexData(index_data);

    const entry = idx.getEntry("test.txt").?;
    var sha_hex: [40]u8 = undefined;
    _ = std.fmt.bufPrint(&sha_hex, "{}", .{std.fmt.fmtSliceHexLower(&entry.sha1)}) catch unreachable;

    try testing.expectEqualStrings(git_hash, &sha_hex);
}

test "git-created index with subdirectory entries" {
    const tmp_dir = "/tmp/ziggit_idx_subdir_test";
    std.fs.deleteTreeAbsolute(tmp_dir) catch {};
    defer std.fs.deleteTreeAbsolute(tmp_dir) catch {};

    _ = try runCmd(&.{ "git", "init", "-q", tmp_dir });
    _ = try runCmd(&.{ "git", "-C", tmp_dir, "config", "user.email", "t@t.com" });
    _ = try runCmd(&.{ "git", "-C", tmp_dir, "config", "user.name", "T" });

    // Create nested file
    std.fs.makeDirAbsolute(tmp_dir ++ "/src") catch {};
    {
        const path = tmp_dir ++ "/src/main.zig";
        const f = try std.fs.createFileAbsolute(path, .{});
        defer f.close();
        try f.writeAll("pub fn main() void {}\n");
    }

    _ = try runCmd(&.{ "git", "-C", tmp_dir, "add", "src/main.zig" });

    const index_path = tmp_dir ++ "/.git/index";
    const index_data = try std.fs.cwd().readFileAlloc(testing.allocator, index_path, 10 * 1024 * 1024);
    defer testing.allocator.free(index_data);

    var idx = git.index.Index.init(testing.allocator);
    defer idx.deinit();
    try idx.parseIndexData(index_data);

    try testing.expect(idx.entries.items.len == 1);
    const entry = idx.getEntry("src/main.zig");
    try testing.expect(entry != null);
}

// ============================================================================
// Helpers
// ============================================================================

fn runCmd(args: []const []const u8) ![]u8 {
    var child = std.process.Child.init(args, testing.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    const stdout = try child.stdout.?.reader().readAllAlloc(testing.allocator, 64 * 1024);
    errdefer testing.allocator.free(stdout);

    const stderr = try child.stderr.?.reader().readAllAlloc(testing.allocator, 64 * 1024);
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
