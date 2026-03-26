// test/fast_index_parser_test.zig - Tests for the FastGitIndex parser
// Tests that the optimized index parser correctly reads entries created by
// both ziggit and git, and that entries match the full parser.
const std = @import("std");
const ziggit = @import("ziggit");
const testing = std.testing;

const Repository = ziggit.Repository;
const IndexParser = ziggit.IndexParser;
const IndexParserFast = ziggit.IndexParserFast;

fn tmpPath(comptime suffix: []const u8) []const u8 {
    return "/tmp/ziggit_fastidx_test_" ++ suffix;
}

fn cleanup(path: []const u8) void {
    std.fs.deleteTreeAbsolute(path) catch {};
}

fn createFile(repo_path: []const u8, name: []const u8, content: []const u8) !void {
    const full = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ repo_path, name });
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

// ============================================================================
// FastGitIndex parsing tests
// ============================================================================

test "FastGitIndex: reads ziggit-created index" {
    const path = tmpPath("fast_ziggit");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    try createFile(path, "hello.txt", "hello world\n");
    try repo.add("hello.txt");
    repo.close();

    const index_path = try std.fmt.allocPrint(testing.allocator, "{s}/.git/index", .{path});
    defer testing.allocator.free(index_path);

    var fast_idx = try IndexParserFast.FastGitIndex.readFromFile(testing.allocator, index_path);
    defer fast_idx.deinit();

    try testing.expectEqual(@as(usize, 1), fast_idx.entries.len);
    try testing.expectEqualStrings("hello.txt", fast_idx.entries[0].path);
}

test "FastGitIndex: reads git-created index" {
    const path = tmpPath("fast_git");
    cleanup(path);
    defer cleanup(path);

    std.fs.makeDirAbsolute(path) catch {};
    _ = try runGit(&.{ "git", "init", "-q" }, path);
    _ = try runGit(&.{ "git", "config", "user.email", "t@t.com" }, path);
    _ = try runGit(&.{ "git", "config", "user.name", "T" }, path);
    try createFile(path, "a.txt", "aaa\n");
    try createFile(path, "b.txt", "bbb\n");
    _ = try runGit(&.{ "git", "add", "a.txt", "b.txt" }, path);

    const index_path = try std.fmt.allocPrint(testing.allocator, "{s}/.git/index", .{path});
    defer testing.allocator.free(index_path);

    var fast_idx = try IndexParserFast.FastGitIndex.readFromFile(testing.allocator, index_path);
    defer fast_idx.deinit();

    try testing.expectEqual(@as(usize, 2), fast_idx.entries.len);
    // Git sorts entries alphabetically
    try testing.expectEqualStrings("a.txt", fast_idx.entries[0].path);
    try testing.expectEqualStrings("b.txt", fast_idx.entries[1].path);
}

test "FastGitIndex: size matches file size" {
    const path = tmpPath("fast_size");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    const content = "exactly 13 ch";
    try createFile(path, "sized.txt", content);
    try repo.add("sized.txt");
    repo.close();

    const index_path = try std.fmt.allocPrint(testing.allocator, "{s}/.git/index", .{path});
    defer testing.allocator.free(index_path);

    var fast_idx = try IndexParserFast.FastGitIndex.readFromFile(testing.allocator, index_path);
    defer fast_idx.deinit();

    try testing.expectEqual(@as(u32, content.len), fast_idx.entries[0].size);
}

test "FastGitIndex: multiple files have correct sizes" {
    const path = tmpPath("fast_multi_size");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    try createFile(path, "a.txt", "short");
    try repo.add("a.txt");
    try createFile(path, "b.txt", "a longer string of text here");
    try repo.add("b.txt");
    repo.close();

    const index_path = try std.fmt.allocPrint(testing.allocator, "{s}/.git/index", .{path});
    defer testing.allocator.free(index_path);

    var fast_idx = try IndexParserFast.FastGitIndex.readFromFile(testing.allocator, index_path);
    defer fast_idx.deinit();

    // Note: entries may not be in order due to how ziggit adds them
    var found_a = false;
    var found_b = false;
    for (fast_idx.entries) |entry| {
        if (std.mem.eql(u8, entry.path, "a.txt")) {
            try testing.expectEqual(@as(u32, 5), entry.size); // "short"
            found_a = true;
        }
        if (std.mem.eql(u8, entry.path, "b.txt")) {
            try testing.expectEqual(@as(u32, 28), entry.size); // "a longer string of text here"
            found_b = true;
        }
    }
    try testing.expect(found_a);
    try testing.expect(found_b);
}

test "FastGitIndex: findEntry returns correct entry" {
    const path = tmpPath("fast_find");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    try createFile(path, "target.txt", "find me\n");
    try repo.add("target.txt");
    try createFile(path, "other.txt", "not me\n");
    try repo.add("other.txt");
    repo.close();

    const index_path = try std.fmt.allocPrint(testing.allocator, "{s}/.git/index", .{path});
    defer testing.allocator.free(index_path);

    var fast_idx = try IndexParserFast.FastGitIndex.readFromFile(testing.allocator, index_path);
    defer fast_idx.deinit();

    const entry = fast_idx.findEntry("target.txt");
    try testing.expect(entry != null);
    try testing.expectEqual(@as(u32, 8), entry.?.size); // "find me\n"
}

test "FastGitIndex: findEntry returns null for missing" {
    const path = tmpPath("fast_find_miss");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    try createFile(path, "exists.txt", "here\n");
    try repo.add("exists.txt");
    repo.close();

    const index_path = try std.fmt.allocPrint(testing.allocator, "{s}/.git/index", .{path});
    defer testing.allocator.free(index_path);

    var fast_idx = try IndexParserFast.FastGitIndex.readFromFile(testing.allocator, index_path);
    defer fast_idx.deinit();

    try testing.expect(fast_idx.findEntry("nonexistent.txt") == null);
}

// ============================================================================
// Fast vs Full parser consistency
// ============================================================================

test "FastGitIndex and GitIndex agree on entry count" {
    const path = tmpPath("fast_vs_full");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    try createFile(path, "x.txt", "xxx\n");
    try repo.add("x.txt");
    try createFile(path, "y.txt", "yyy\n");
    try repo.add("y.txt");
    try createFile(path, "z.txt", "zzz\n");
    try repo.add("z.txt");
    repo.close();

    const index_path = try std.fmt.allocPrint(testing.allocator, "{s}/.git/index", .{path});
    defer testing.allocator.free(index_path);

    var fast_idx = try IndexParserFast.FastGitIndex.readFromFile(testing.allocator, index_path);
    defer fast_idx.deinit();

    var full_idx = try IndexParser.GitIndex.readFromFile(testing.allocator, index_path);
    defer full_idx.deinit();

    try testing.expectEqual(full_idx.entries.items.len, fast_idx.entries.len);
}

test "FastGitIndex and GitIndex agree on paths and sizes" {
    const path = tmpPath("fast_vs_full_data");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    try createFile(path, "alpha.txt", "alpha content\n");
    try repo.add("alpha.txt");
    try createFile(path, "beta.txt", "beta stuff\n");
    try repo.add("beta.txt");
    repo.close();

    const index_path = try std.fmt.allocPrint(testing.allocator, "{s}/.git/index", .{path});
    defer testing.allocator.free(index_path);

    var fast_idx = try IndexParserFast.FastGitIndex.readFromFile(testing.allocator, index_path);
    defer fast_idx.deinit();

    var full_idx = try IndexParser.GitIndex.readFromFile(testing.allocator, index_path);
    defer full_idx.deinit();

    // Both parsers should see the same entries
    for (fast_idx.entries, 0..) |fast_entry, i| {
        const full_entry = full_idx.entries.items[i];
        try testing.expectEqualStrings(fast_entry.path, full_entry.path);
        try testing.expectEqual(fast_entry.size, full_entry.size);
        try testing.expectEqual(fast_entry.mtime_seconds, full_entry.mtime_seconds);
    }
}

// ============================================================================
// git-created index compatibility
// ============================================================================

test "FastGitIndex: reads git-created index with many files" {
    const path = tmpPath("fast_git_many");
    cleanup(path);
    defer cleanup(path);

    std.fs.makeDirAbsolute(path) catch {};
    _ = try runGit(&.{ "git", "init", "-q" }, path);
    _ = try runGit(&.{ "git", "config", "user.email", "t@t.com" }, path);
    _ = try runGit(&.{ "git", "config", "user.name", "T" }, path);

    // Create 10 files
    var names: [10][]u8 = undefined;
    var created: usize = 0;
    for (0..10) |i| {
        names[i] = try std.fmt.allocPrint(testing.allocator, "file_{d:0>3}.txt", .{i});
        const content = try std.fmt.allocPrint(testing.allocator, "content of file {d}\n", .{i});
        defer testing.allocator.free(content);
        try createFile(path, names[i], content);
        created += 1;
    }
    defer for (0..created) |i| testing.allocator.free(names[i]);

    _ = try runGit(&.{ "git", "add", "." }, path);

    const index_path = try std.fmt.allocPrint(testing.allocator, "{s}/.git/index", .{path});
    defer testing.allocator.free(index_path);

    var fast_idx = try IndexParserFast.FastGitIndex.readFromFile(testing.allocator, index_path);
    defer fast_idx.deinit();

    try testing.expectEqual(@as(usize, 10), fast_idx.entries.len);
}

// ============================================================================
// Error handling
// ============================================================================

test "FastGitIndex: rejects nonexistent file" {
    const result = IndexParserFast.FastGitIndex.readFromFile(testing.allocator, "/tmp/nonexistent_index_file_xyz");
    try testing.expectError(error.FileNotFound, result);
}

test "GitIndex: rejects nonexistent file" {
    const result = IndexParser.GitIndex.readFromFile(testing.allocator, "/tmp/nonexistent_index_file_xyz");
    try testing.expectError(error.FileNotFound, result);
}

test "GitIndex parseIndex: rejects truncated data" {
    // Less than 12 bytes header
    const result = IndexParser.GitIndex.parseIndex(testing.allocator, "DIRC");
    try testing.expectError(error.InvalidIndex, result);
}

test "GitIndex parseIndex: rejects wrong magic" {
    const bad_data = "XXXX\x00\x00\x00\x02\x00\x00\x00\x00" ++ "\x00" ** 20;
    const result = IndexParser.GitIndex.parseIndex(testing.allocator, bad_data);
    try testing.expectError(error.InvalidIndexSignature, result);
}

test "GitIndex parseIndex: accepts DIRC with zero entries" {
    // DIRC header + version 2 + 0 entries + 20-byte checksum
    const data = "DIRC" ++ "\x00\x00\x00\x02" ++ "\x00\x00\x00\x00" ++ "\x00" ** 20;
    var idx = try IndexParser.GitIndex.parseIndex(testing.allocator, data);
    defer idx.deinit();
    try testing.expectEqual(@as(usize, 0), idx.entries.items.len);
}

test "FastGitIndex parseFast: rejects truncated data" {
    // Write a tiny file
    const tmp_file = "/tmp/ziggit_fast_trunc_test";
    defer std.fs.deleteFileAbsolute(tmp_file) catch {};
    const f = try std.fs.createFileAbsolute(tmp_file, .{ .truncate = true });
    try f.writeAll("DIRC");
    f.close();

    const result = IndexParserFast.FastGitIndex.readFromFile(testing.allocator, tmp_file);
    try testing.expectError(error.InvalidIndex, result);
}
