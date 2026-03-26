// test/index_git_compat_test.zig
// Tests that ziggit's index file format is byte-compatible with git.
// Creates index entries with ziggit, validates with git ls-files/ls-files --stage.
const std = @import("std");
const ziggit = @import("ziggit");
const testing = std.testing;

const Repository = ziggit.Repository;

fn tmpPath(comptime suffix: []const u8) []const u8 {
    return "/tmp/ziggit_igc_" ++ suffix;
}

fn cleanup(path: []const u8) void {
    std.fs.deleteTreeAbsolute(path) catch {};
}

fn createFile(dir: []const u8, name: []const u8, content: []const u8) !void {
    const full = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ dir, name });
    defer testing.allocator.free(full);
    const f = try std.fs.createFileAbsolute(full, .{ .truncate = true });
    defer f.close();
    try f.writeAll(content);
}

fn gitCmd(dir: []const u8, argv: []const []const u8) ![]u8 {
    var args = std.ArrayList([]const u8).init(testing.allocator);
    defer args.deinit();
    try args.append("git");
    try args.append("-C");
    try args.append(dir);
    for (argv) |a| try args.append(a);

    var proc = std.process.Child.init(args.items, testing.allocator);
    proc.stderr_behavior = .Pipe;
    proc.stdout_behavior = .Pipe;
    try proc.spawn();
    const stdout = try proc.stdout.?.reader().readAllAlloc(testing.allocator, 1024 * 1024);
    _ = try proc.wait();
    return stdout;
}

fn gitCmdStatus(dir: []const u8, argv: []const []const u8) !struct { stdout: []u8, exit_code: u8 } {
    var args = std.ArrayList([]const u8).init(testing.allocator);
    defer args.deinit();
    try args.append("git");
    try args.append("-C");
    try args.append(dir);
    for (argv) |a| try args.append(a);

    var proc = std.process.Child.init(args.items, testing.allocator);
    proc.stderr_behavior = .Pipe;
    proc.stdout_behavior = .Pipe;
    try proc.spawn();
    const stdout = try proc.stdout.?.reader().readAllAlloc(testing.allocator, 1024 * 1024);
    const stderr = try proc.stderr.?.reader().readAllAlloc(testing.allocator, 1024 * 1024);
    defer testing.allocator.free(stderr);
    const term = try proc.wait();
    return .{ .stdout = stdout, .exit_code = term.Exited };
}

test "ziggit add: git ls-files shows file" {
    const path = tmpPath("lsfiles");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    _ = try gitCmd(path, &.{ "config", "user.email", "t@t.com" });
    _ = try gitCmd(path, &.{ "config", "user.name", "T" });

    try createFile(path, "hello.txt", "hello world\n");
    try repo.add("hello.txt");

    const out = try gitCmd(path, &.{"ls-files"});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("hello.txt\n", out);
}

test "ziggit add: git ls-files --stage shows correct mode and hash" {
    const path = tmpPath("stage");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    _ = try gitCmd(path, &.{ "config", "user.email", "t@t.com" });
    _ = try gitCmd(path, &.{ "config", "user.name", "T" });

    try createFile(path, "test.txt", "test content\n");
    try repo.add("test.txt");

    const out = try gitCmd(path, &.{ "ls-files", "--stage" });
    defer testing.allocator.free(out);

    // Should look like: "100644 <hash> 0\ttest.txt\n"
    try testing.expect(std.mem.startsWith(u8, out, "100644 "));
    try testing.expect(std.mem.indexOf(u8, out, "test.txt") != null);

    // Extract hash and compare with git hash-object
    const hash_start = 7; // after "100644 "
    const stage_hash = out[hash_start .. hash_start + 40];

    const expected_hash_out = try gitCmd(path, &.{ "hash-object", "test.txt" });
    defer testing.allocator.free(expected_hash_out);
    const expected_hash = std.mem.trim(u8, expected_hash_out, " \n\r\t");

    try testing.expectEqualStrings(expected_hash, stage_hash);
}

test "ziggit add multiple files: git ls-files shows all" {
    const path = tmpPath("multi");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    _ = try gitCmd(path, &.{ "config", "user.email", "t@t.com" });
    _ = try gitCmd(path, &.{ "config", "user.name", "T" });

    try createFile(path, "a.txt", "aaa\n");
    try createFile(path, "b.txt", "bbb\n");
    try createFile(path, "c.txt", "ccc\n");
    try repo.add("a.txt");
    try repo.add("b.txt");
    try repo.add("c.txt");

    const out = try gitCmd(path, &.{"ls-files"});
    defer testing.allocator.free(out);

    // All three files should be listed
    try testing.expect(std.mem.indexOf(u8, out, "a.txt") != null);
    try testing.expect(std.mem.indexOf(u8, out, "b.txt") != null);
    try testing.expect(std.mem.indexOf(u8, out, "c.txt") != null);
}

test "index binary format: starts with DIRC" {
    const path = tmpPath("dirc");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "data\n");
    try repo.add("f.txt");

    // Read raw index file
    const index_path = try std.fmt.allocPrint(testing.allocator, "{s}/index", .{repo.git_dir});
    defer testing.allocator.free(index_path);

    const index_data = try std.fs.cwd().readFileAlloc(testing.allocator, index_path, 1024 * 1024);
    defer testing.allocator.free(index_data);

    try testing.expect(index_data.len >= 12);
    try testing.expectEqualStrings("DIRC", index_data[0..4]);
}

test "index binary format: version is 2" {
    const path = tmpPath("ver2");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "data\n");
    try repo.add("f.txt");

    const index_path = try std.fmt.allocPrint(testing.allocator, "{s}/index", .{repo.git_dir});
    defer testing.allocator.free(index_path);

    const index_data = try std.fs.cwd().readFileAlloc(testing.allocator, index_path, 1024 * 1024);
    defer testing.allocator.free(index_data);

    const version = std.mem.readInt(u32, index_data[4..8][0..4], .big);
    try testing.expectEqual(@as(u32, 2), version);
}

test "index binary format: entry count matches adds" {
    const path = tmpPath("count");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "a.txt", "a\n");
    try createFile(path, "b.txt", "b\n");
    try createFile(path, "c.txt", "c\n");
    try repo.add("a.txt");
    try repo.add("b.txt");
    try repo.add("c.txt");

    const index_path = try std.fmt.allocPrint(testing.allocator, "{s}/index", .{repo.git_dir});
    defer testing.allocator.free(index_path);

    const index_data = try std.fs.cwd().readFileAlloc(testing.allocator, index_path, 1024 * 1024);
    defer testing.allocator.free(index_data);

    const entry_count = std.mem.readInt(u32, index_data[8..12][0..4], .big);
    try testing.expectEqual(@as(u32, 3), entry_count);
}

test "index binary format: trailing 20 bytes present" {
    const path = tmpPath("trail");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "data\n");
    try repo.add("f.txt");

    const index_path = try std.fmt.allocPrint(testing.allocator, "{s}/index", .{repo.git_dir});
    defer testing.allocator.free(index_path);

    const index_data = try std.fs.cwd().readFileAlloc(testing.allocator, index_path, 1024 * 1024);
    defer testing.allocator.free(index_data);

    // Index must be at least: 12 (header) + 62 (min entry) + name + padding + 20 (checksum)
    try testing.expect(index_data.len >= 12 + 62 + 1 + 20);
}

test "git add then ziggit reads: round-trip" {
    const path = tmpPath("gitadd");
    cleanup(path);
    defer cleanup(path);
    try std.fs.makeDirAbsolute(path);

    // Initialize with git
    _ = try gitCmd(path, &.{ "init", "-q" });
    _ = try gitCmd(path, &.{ "config", "user.email", "t@t.com" });
    _ = try gitCmd(path, &.{ "config", "user.name", "T" });

    try createFile(path, "f.txt", "data\n");
    _ = try gitCmd(path, &.{ "add", "f.txt" });
    _ = try gitCmd(path, &.{ "commit", "-q", "-m", "init" });

    // Open with ziggit
    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    // revParseHead should match git
    const z_head = try repo.revParseHead();
    const g_out = try gitCmd(path, &.{ "rev-parse", "HEAD" });
    defer testing.allocator.free(g_out);
    const g_head = std.mem.trim(u8, g_out, " \n\r\t");

    try testing.expectEqualStrings(g_head, &z_head);
}

test "ziggit add then git commit: seamless interop" {
    const path = tmpPath("interop");
    cleanup(path);
    defer cleanup(path);

    // Init with git
    _ = try gitCmd(path, &.{ "init", "-q" });
    _ = try gitCmd(path, &.{ "config", "user.email", "t@t.com" });
    _ = try gitCmd(path, &.{ "config", "user.name", "T" });

    // Add with ziggit
    var repo = try Repository.init(testing.allocator, path);
    try createFile(path, "mixed.txt", "mixed workflow\n");
    try repo.add("mixed.txt");
    repo.close();

    // Commit with git
    _ = try gitCmd(path, &.{ "commit", "-q", "-m", "mixed commit" });

    // Verify with git
    const out = try gitCmd(path, &.{ "log", "--oneline" });
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "mixed commit") != null);
}

test "empty file: ziggit add, git hash-object agree" {
    const path = tmpPath("empty");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    _ = try gitCmd(path, &.{ "config", "user.email", "t@t.com" });
    _ = try gitCmd(path, &.{ "config", "user.name", "T" });

    try createFile(path, "empty.txt", "");
    try repo.add("empty.txt");

    // Get hash from git's index
    const out = try gitCmd(path, &.{ "ls-files", "--stage" });
    defer testing.allocator.free(out);

    if (out.len > 7) {
        const stage_hash = out[7..47];

        // Known empty blob hash
        const expected = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391";
        try testing.expectEqualStrings(expected, stage_hash);
    }
}

test "large file: 1MB file round-trip" {
    const path = tmpPath("large");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    _ = try gitCmd(path, &.{ "config", "user.email", "t@t.com" });
    _ = try gitCmd(path, &.{ "config", "user.name", "T" });

    // Create 1MB file
    const content = try testing.allocator.alloc(u8, 1024 * 1024);
    defer testing.allocator.free(content);
    for (content, 0..) |*b, i| {
        b.* = @intCast(i % 256);
    }
    try createFile(path, "large.bin", content);
    try repo.add("large.bin");
    _ = try repo.commit("large file", "T", "t@t.com");

    // Verify git can read the blob
    const out = try gitCmd(path, &.{ "ls-tree", "HEAD" });
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "large.bin") != null);

    // Verify blob content size
    const blob_hash_start = std.mem.indexOf(u8, out, "blob ").? + 5;
    const blob_hash = out[blob_hash_start .. blob_hash_start + 40];

    const size_out = try gitCmd(path, &.{ "cat-file", "-s", blob_hash });
    defer testing.allocator.free(size_out);
    const size = std.mem.trim(u8, size_out, " \n\r\t");
    try testing.expectEqualStrings("1048576", size);
}
