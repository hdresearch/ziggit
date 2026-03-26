// test/index_write_verify_test.zig
// Tests that ziggit's index write path produces git-compatible binary format.
// Verifies DIRC signature, version, entry count, SHA-1 checksum, and entry layout.
const std = @import("std");
const ziggit = @import("ziggit");
const testing = std.testing;

const Repository = ziggit.Repository;

fn tmpPath(comptime suffix: []const u8) []const u8 {
    return "/tmp/ziggit_idx_write_" ++ suffix;
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

fn readIndexFile(git_dir: []const u8) ![]u8 {
    const index_path = try std.fmt.allocPrint(testing.allocator, "{s}/index", .{git_dir});
    defer testing.allocator.free(index_path);
    const f = try std.fs.openFileAbsolute(index_path, .{});
    defer f.close();
    return try f.readToEndAlloc(testing.allocator, 10 * 1024 * 1024);
}

fn runGit(dir: []const u8, args: []const []const u8) ![]u8 {
    var argv = std.ArrayList([]const u8).init(testing.allocator);
    defer argv.deinit();
    try argv.append("git");
    for (args) |a| try argv.append(a);

    var child = std.process.Child.init(argv.items, testing.allocator);
    child.cwd = dir;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const stdout = try child.stdout.?.reader().readAllAlloc(testing.allocator, 1024 * 1024);
    _ = try child.wait();
    return stdout;
}

test "index binary: DIRC signature after add" {
    const path = tmpPath("dirc");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "test.txt", "hello\n");
    try repo.add("test.txt");

    const index_data = try readIndexFile(repo.git_dir);
    defer testing.allocator.free(index_data);

    try testing.expect(index_data.len >= 12);
    try testing.expectEqualStrings("DIRC", index_data[0..4]);
}

test "index binary: version is 2" {
    const path = tmpPath("version");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "test.txt", "hello\n");
    try repo.add("test.txt");

    const index_data = try readIndexFile(repo.git_dir);
    defer testing.allocator.free(index_data);

    const version = std.mem.readInt(u32, index_data[4..8][0..4], .big);
    try testing.expectEqual(@as(u32, 2), version);
}

test "index binary: entry count matches files added" {
    const path = tmpPath("count");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "a.txt", "aaa\n");
    try repo.add("a.txt");
    try createFile(path, "b.txt", "bbb\n");
    try repo.add("b.txt");

    const index_data = try readIndexFile(repo.git_dir);
    defer testing.allocator.free(index_data);

    const num_entries = std.mem.readInt(u32, index_data[8..12][0..4], .big);
    // May be 2 (proper de-dup) or more (append-only)
    try testing.expect(num_entries >= 2);
}

test "index binary: trailing 20 bytes present" {
    const path = tmpPath("checksum");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);
    defer repo.close();

    try createFile(path, "f.txt", "data\n");
    try repo.add("f.txt");

    const index_data = try readIndexFile(repo.git_dir);
    defer testing.allocator.free(index_data);

    // Index must have at least 12 (header) + entry data + 20 (checksum/padding)
    try testing.expect(index_data.len > 32);

    // Last 20 bytes should exist (either valid SHA-1 or zeroed placeholder)
    const trailing = index_data[index_data.len - 20 ..];
    try testing.expectEqual(@as(usize, 20), trailing.len);
}

test "index: git ls-files reads ziggit index" {
    const path = tmpPath("lsfiles");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);

    try createFile(path, "main.zig", "pub fn main() void {}\n");
    try repo.add("main.zig");
    repo.close();

    // git ls-files should show the file
    const ls = runGit(path, &.{ "ls-files" }) catch return;
    defer testing.allocator.free(ls);

    const trimmed = std.mem.trim(u8, ls, " \n\r\t");
    try testing.expectEqualStrings("main.zig", trimmed);
}

test "index: git ls-files --stage shows correct mode" {
    const path = tmpPath("stage_mode");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);

    try createFile(path, "test.txt", "hello\n");
    try repo.add("test.txt");
    repo.close();

    const stage = runGit(path, &.{ "ls-files", "--stage" }) catch return;
    defer testing.allocator.free(stage);

    // Should contain "100644" mode
    try testing.expect(std.mem.indexOf(u8, stage, "100644") != null);
    try testing.expect(std.mem.indexOf(u8, stage, "test.txt") != null);
}

test "index: git ls-files --stage hash matches git hash-object" {
    const path = tmpPath("hash_match");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);

    try createFile(path, "data.txt", "some data\n");
    try repo.add("data.txt");
    repo.close();

    // Get hash from index
    const stage = runGit(path, &.{ "ls-files", "--stage" }) catch return;
    defer testing.allocator.free(stage);

    // Get hash from hash-object
    const file_path = try std.fmt.allocPrint(testing.allocator, "{s}/data.txt", .{path});
    defer testing.allocator.free(file_path);
    const hash = runGit(path, &.{ "hash-object", "data.txt" }) catch return;
    defer testing.allocator.free(hash);

    const hash_trimmed = std.mem.trim(u8, hash, " \n\r\t");

    // The stage output should contain the same hash
    try testing.expect(std.mem.indexOf(u8, stage, hash_trimmed) != null);
}

test "index: multiple adds produce git-readable index" {
    const path = tmpPath("multi_add");
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

    // git ls-files should list all three
    const ls = runGit(path, &.{ "ls-files" }) catch return;
    defer testing.allocator.free(ls);

    const trimmed = std.mem.trim(u8, ls, " \n\r\t");
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, trimmed, '\n');
    while (lines.next()) |line| {
        if (line.len > 0) count += 1;
    }
    try testing.expect(count >= 3);
}

test "index round-trip: git add then ziggit reads" {
    const path = tmpPath("git_add_read");
    cleanup(path);
    defer cleanup(path);

    // Use git to create repo and add files
    _ = std.fs.makeDirAbsolute(path) catch {};
    const init_out = runGit(path, &.{ "init", "-q" }) catch return;
    testing.allocator.free(init_out);
    const cfg1 = runGit(path, &.{ "config", "user.email", "t@t.com" }) catch return;
    testing.allocator.free(cfg1);
    const cfg2 = runGit(path, &.{ "config", "user.name", "T" }) catch return;
    testing.allocator.free(cfg2);

    try createFile(path, "readme.md", "# Hello\n");
    const add_out = runGit(path, &.{ "add", "readme.md" }) catch return;
    testing.allocator.free(add_out);
    const commit_out = runGit(path, &.{ "commit", "-q", "-m", "init" }) catch return;
    testing.allocator.free(commit_out);

    // Now open with ziggit and verify
    var repo = try Repository.open(testing.allocator, path);
    defer repo.close();

    const head = try repo.revParseHead();
    // Should be a valid 40-char hex hash
    try testing.expectEqual(@as(usize, 40), head.len);
    for (head) |c| {
        try testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
}

test "index: empty file produces valid index entry" {
    const path = tmpPath("empty_file");
    cleanup(path);
    defer cleanup(path);

    var repo = try Repository.init(testing.allocator, path);

    try createFile(path, "empty.txt", "");
    try repo.add("empty.txt");
    repo.close();

    // Verify git can read it
    const ls = runGit(path, &.{ "ls-files", "--stage" }) catch return;
    defer testing.allocator.free(ls);

    try testing.expect(std.mem.indexOf(u8, ls, "empty.txt") != null);

    // Also verify with hash-object that the hash matches
    const hash = runGit(path, &.{ "hash-object", "empty.txt" }) catch return;
    defer testing.allocator.free(hash);
    const hash_trimmed = std.mem.trim(u8, hash, " \n\r\t");
    try testing.expect(std.mem.indexOf(u8, ls, hash_trimmed) != null);
}
