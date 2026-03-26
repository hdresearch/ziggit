// test/index_binary_roundtrip_test.zig
// Tests index module: binary DIRC format read/write, cross-validation with git
const std = @import("std");
const testing = std.testing;
const git = @import("git");

const NativePlatform = struct {
    const fs = struct {
        fn makeDir(path: []const u8) !void {
            std.fs.makeDirAbsolute(path) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }
        fn writeFile(path: []const u8, content: []const u8) !void {
            const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
            defer file.close();
            try file.writeAll(content);
        }
        fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
            const file = try std.fs.openFileAbsolute(path, .{});
            defer file.close();
            return try file.readToEndAlloc(allocator, 100 * 1024 * 1024);
        }
        fn fileExists(path: []const u8) bool {
            std.fs.accessAbsolute(path, .{}) catch return false;
            return true;
        }
    };
};
const platform = NativePlatform{};

fn tmpPath(comptime suffix: []const u8) []const u8 {
    return "/tmp/ziggit_index_rt_" ++ suffix;
}

fn cleanup(path: []const u8) void {
    std.fs.deleteTreeAbsolute(path) catch {};
}

fn execGit(work_dir: []const u8, args: []const []const u8) ![]u8 {
    var argv = std.ArrayList([]const u8).init(testing.allocator);
    defer argv.deinit();
    try argv.append("git");
    try argv.append("-C");
    try argv.append(work_dir);
    for (args) |a| try argv.append(a);

    var child = std.process.Child.init(argv.items, testing.allocator);
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

fn execGitNoOutput(work_dir: []const u8, args: []const []const u8) !void {
    const out = try execGit(work_dir, args);
    testing.allocator.free(out);
}

fn writeFile(dir: []const u8, name: []const u8, content: []const u8) !void {
    const full = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ dir, name });
    defer testing.allocator.free(full);
    const file = try std.fs.createFileAbsolute(full, .{ .truncate = true });
    defer file.close();
    try file.writeAll(content);
}

fn initGitRepo(path: []const u8) !void {
    cleanup(path);
    std.fs.makeDirAbsolute(path) catch {};
    try execGitNoOutput(path, &.{"init"});
    try execGitNoOutput(path, &.{ "config", "user.email", "t@t.com" });
    try execGitNoOutput(path, &.{ "config", "user.name", "Test" });
}

// ============================================================================
// Index load: read git-written index
// ============================================================================

test "index load: reads git-written index entries" {
    const path = tmpPath("idx_load");
    defer cleanup(path);
    try initGitRepo(path);

    try writeFile(path, "a.txt", "aaa\n");
    try writeFile(path, "b.txt", "bbb\n");
    try execGitNoOutput(path, &.{ "add", "a.txt", "b.txt" });

    const git_dir = try std.fmt.allocPrint(testing.allocator, "{s}/.git", .{path});
    defer testing.allocator.free(git_dir);

    var idx = try git.index.Index.load(git_dir, platform, testing.allocator);
    defer idx.deinit();

    try testing.expectEqual(@as(usize, 2), idx.entries.items.len);

    // Entries should be sorted
    var found_a = false;
    var found_b = false;
    for (idx.entries.items) |entry| {
        if (std.mem.eql(u8, entry.path, "a.txt")) found_a = true;
        if (std.mem.eql(u8, entry.path, "b.txt")) found_b = true;
    }
    try testing.expect(found_a);
    try testing.expect(found_b);
}

test "index load: entry SHA-1 matches git ls-files" {
    const path = tmpPath("idx_sha");
    defer cleanup(path);
    try initGitRepo(path);

    try writeFile(path, "hello.txt", "Hello, World!\n");
    try execGitNoOutput(path, &.{ "add", "hello.txt" });

    const git_dir = try std.fmt.allocPrint(testing.allocator, "{s}/.git", .{path});
    defer testing.allocator.free(git_dir);

    var idx = try git.index.Index.load(git_dir, platform, testing.allocator);
    defer idx.deinit();

    try testing.expectEqual(@as(usize, 1), idx.entries.items.len);

    // Get expected hash from git
    const ls_out = try execGit(path, &.{ "ls-files", "--stage" });
    defer testing.allocator.free(ls_out);

    // Format: "100644 <hash> 0\thello.txt\n"
    if (std.mem.indexOf(u8, ls_out, " ")) |idx1| {
        const hash_str = ls_out[idx1 + 1 .. idx1 + 41];
        // Convert entry sha1 to hex
        var entry_hex: [40]u8 = undefined;
        _ = std.fmt.bufPrint(&entry_hex, "{}", .{std.fmt.fmtSliceHexLower(&idx.entries.items[0].sha1)}) catch unreachable;
        try testing.expectEqualStrings(hash_str, &entry_hex);
    }
}

// ============================================================================
// Index save: write index that git can read
// ============================================================================

test "index save: git ls-files reads ziggit-written index" {
    const path = tmpPath("idx_save");
    defer cleanup(path);
    try initGitRepo(path);

    // First let git create an index
    try writeFile(path, "x.txt", "xxx\n");
    try execGitNoOutput(path, &.{ "add", "x.txt" });

    const git_dir = try std.fmt.allocPrint(testing.allocator, "{s}/.git", .{path});
    defer testing.allocator.free(git_dir);

    // Load, add another file, save
    var idx = try git.index.Index.load(git_dir, platform, testing.allocator);
    defer idx.deinit();

    // Write file for add
    try writeFile(path, "y.txt", "yyy\n");
    const y_path = try std.fmt.allocPrint(testing.allocator, "{s}/y.txt", .{path});
    defer testing.allocator.free(y_path);

    try idx.add("y.txt", y_path, platform, git_dir);
    try idx.save(git_dir, platform);

    // git should see both files
    const ls_out = try execGit(path, &.{ "ls-files" });
    defer testing.allocator.free(ls_out);

    try testing.expect(std.mem.indexOf(u8, ls_out, "x.txt") != null);
    try testing.expect(std.mem.indexOf(u8, ls_out, "y.txt") != null);
}

// ============================================================================
// Index roundtrip: load -> save -> load
// ============================================================================

test "index roundtrip: load-save-load preserves entries" {
    const path = tmpPath("idx_roundtrip");
    defer cleanup(path);
    try initGitRepo(path);

    try writeFile(path, "a.txt", "aaa\n");
    try writeFile(path, "b.txt", "bbb\n");
    try writeFile(path, "c.txt", "ccc\n");
    try execGitNoOutput(path, &.{ "add", "a.txt", "b.txt", "c.txt" });

    const git_dir = try std.fmt.allocPrint(testing.allocator, "{s}/.git", .{path});
    defer testing.allocator.free(git_dir);

    // Load
    var idx1 = try git.index.Index.load(git_dir, platform, testing.allocator);
    const count1 = idx1.entries.items.len;

    // Save
    try idx1.save(git_dir, platform);
    idx1.deinit();

    // Load again
    var idx2 = try git.index.Index.load(git_dir, platform, testing.allocator);
    defer idx2.deinit();

    try testing.expectEqual(count1, idx2.entries.items.len);

    // Verify paths match
    for (idx2.entries.items, 0..) |entry, i| {
        _ = i;
        try testing.expect(
            std.mem.eql(u8, entry.path, "a.txt") or
                std.mem.eql(u8, entry.path, "b.txt") or
                std.mem.eql(u8, entry.path, "c.txt"),
        );
    }
}

// ============================================================================
// Index: DIRC magic number verification
// ============================================================================

test "index: file starts with DIRC magic" {
    const path = tmpPath("idx_dirc");
    defer cleanup(path);
    try initGitRepo(path);

    try writeFile(path, "f.txt", "data\n");
    try execGitNoOutput(path, &.{ "add", "f.txt" });

    // Read raw index file
    const index_path = try std.fmt.allocPrint(testing.allocator, "{s}/.git/index", .{path});
    defer testing.allocator.free(index_path);

    const raw = try std.fs.cwd().readFileAlloc(testing.allocator, index_path, 1024 * 1024);
    defer testing.allocator.free(raw);

    // First 4 bytes should be "DIRC"
    try testing.expectEqualStrings("DIRC", raw[0..4]);

    // Bytes 4-7: version (usually 2)
    const version = std.mem.readInt(u32, raw[4..8], .big);
    try testing.expect(version == 2 or version == 3 or version == 4);

    // Bytes 8-11: number of entries
    const num_entries = std.mem.readInt(u32, raw[8..12], .big);
    try testing.expectEqual(@as(u32, 1), num_entries);
}

// ============================================================================
// Index: remove entry
// ============================================================================

test "index: remove entry reduces count" {
    const path = tmpPath("idx_remove");
    defer cleanup(path);
    try initGitRepo(path);

    try writeFile(path, "a.txt", "aaa\n");
    try writeFile(path, "b.txt", "bbb\n");
    try execGitNoOutput(path, &.{ "add", "a.txt", "b.txt" });

    const git_dir = try std.fmt.allocPrint(testing.allocator, "{s}/.git", .{path});
    defer testing.allocator.free(git_dir);

    var idx = try git.index.Index.load(git_dir, platform, testing.allocator);
    defer idx.deinit();

    try testing.expectEqual(@as(usize, 2), idx.entries.items.len);

    try idx.remove("a.txt");
    try testing.expectEqual(@as(usize, 1), idx.entries.items.len);

    // Remaining entry should be b.txt
    try testing.expectEqualStrings("b.txt", idx.entries.items[0].path);
}

// ============================================================================
// Index: getEntry lookup
// ============================================================================

test "index: getEntry finds existing, returns null for missing" {
    const path = tmpPath("idx_get");
    defer cleanup(path);
    try initGitRepo(path);

    try writeFile(path, "exists.txt", "data\n");
    try execGitNoOutput(path, &.{ "add", "exists.txt" });

    const git_dir = try std.fmt.allocPrint(testing.allocator, "{s}/.git", .{path});
    defer testing.allocator.free(git_dir);

    var idx = try git.index.Index.load(git_dir, platform, testing.allocator);
    defer idx.deinit();

    try testing.expect(idx.getEntry("exists.txt") != null);
    try testing.expect(idx.getEntry("missing.txt") == null);
}
