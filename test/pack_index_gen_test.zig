const std = @import("std");
const testing = std.testing;
const objects = @import("git_objects");

// ============================================================================
// Tests for pure-Zig pack index generation (generatePackIndex, saveReceivedPack)
// This is the critical path for HTTPS clone: server sends pack → we save + index it
// ============================================================================

const RealFs = struct {
    pub fn readFile(_: RealFs, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        return std.fs.cwd().readFileAlloc(allocator, path, 50 * 1024 * 1024);
    }
    pub fn writeFile(_: RealFs, path: []const u8, data: []const u8) !void {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(data);
    }
    pub fn makeDir(_: RealFs, path: []const u8) anyerror!void {
        std.fs.cwd().makeDir(path) catch |err| switch (err) {
            error.PathAlreadyExists => return error.AlreadyExists,
            else => return err,
        };
    }
    pub fn readDir(_: RealFs, allocator: std.mem.Allocator, path: []const u8) ![][]u8 {
        var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
        defer dir.close();
        var list = std.ArrayList([]u8).init(allocator);
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            try list.append(try allocator.dupe(u8, entry.name));
        }
        return list.toOwnedSlice();
    }
};
const RealFsPlatform = struct { fs: RealFs = .{} };

fn runGit(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) ![]u8 {
    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit();
    try argv.append("git");
    try argv.appendSlice(args);
    var child = std.process.Child.init(argv.items, allocator);
    child.cwd = cwd;
    child.stderr_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    try child.spawn();
    const stdout = try child.stdout.?.reader().readAllAlloc(allocator, 1024 * 1024);
    const stderr = try child.stderr.?.reader().readAllAlloc(allocator, 1024 * 1024);
    defer allocator.free(stderr);
    const result = try child.wait();
    if (result.Exited != 0) {
        allocator.free(stdout);
        return error.GitCommandFailed;
    }
    return stdout;
}

fn runGitNoOutput(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) !void {
    const out = try runGit(allocator, cwd, args);
    allocator.free(out);
}

/// Build a minimal pack file containing blobs
fn buildPackWithBlobs(allocator: std.mem.Allocator, contents: []const []const u8) ![]u8 {
    var pack = std.ArrayList(u8).init(allocator);
    defer pack.deinit();

    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, @intCast(contents.len), .big);

    for (contents) |content| {
        // Pack object header: type=3 (blob)
        var s = content.len;
        var first_byte: u8 = (3 << 4) | @as(u8, @intCast(s & 0x0F));
        s >>= 4;
        if (s > 0) first_byte |= 0x80;
        try pack.append(first_byte);
        while (s > 0) {
            var byte: u8 = @intCast(s & 0x7F);
            s >>= 7;
            if (s > 0) byte |= 0x80;
            try pack.append(byte);
        }

        // Zlib-compressed content
        var compressed = std.ArrayList(u8).init(allocator);
        defer compressed.deinit();
        var input = std.io.fixedBufferStream(content);
        try std.compress.zlib.compress(input.reader(), compressed.writer(), .{});
        try pack.appendSlice(compressed.items);
    }

    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack.items);
    var checksum: [20]u8 = undefined;
    hasher.final(&checksum);
    try pack.appendSlice(&checksum);

    return try pack.toOwnedSlice();
}

fn computeGitHash(allocator: std.mem.Allocator, obj_type: []const u8, data: []const u8) ![]u8 {
    const header = try std.fmt.allocPrint(allocator, "{s} {}\x00", .{ obj_type, data.len });
    defer allocator.free(header);
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(header);
    hasher.update(data);
    var digest: [20]u8 = undefined;
    hasher.final(&digest);
    return try std.fmt.allocPrint(allocator, "{}", .{std.fmt.fmtSliceHexLower(&digest)});
}

// ============================================================================
// Test: generatePackIndex produces valid v2 idx for single blob
// ============================================================================
test "idx gen: single blob produces valid v2 idx" {
    const allocator = testing.allocator;
    const content = "test blob for idx gen\n";

    const pack_data = try buildPackWithBlobs(allocator, &.{content});
    defer allocator.free(pack_data);

    const idx_data = try objects.generatePackIndex(pack_data, allocator);
    defer allocator.free(idx_data);

    // Verify v2 magic and version
    try testing.expect(idx_data.len >= 8 + 256 * 4);
    const magic = std.mem.readInt(u32, @ptrCast(idx_data[0..4]), .big);
    try testing.expectEqual(@as(u32, 0xff744f63), magic);
    const version = std.mem.readInt(u32, @ptrCast(idx_data[4..8]), .big);
    try testing.expectEqual(@as(u32, 2), version);

    // Fanout[255] should be 1 (one object)
    const total_objects = std.mem.readInt(u32, @ptrCast(idx_data[8 + 255 * 4 .. 8 + 255 * 4 + 4]), .big);
    try testing.expectEqual(@as(u32, 1), total_objects);

    // Fanout should be monotonically non-decreasing
    var prev: u32 = 0;
    for (0..256) |i| {
        const offset = 8 + i * 4;
        const val = std.mem.readInt(u32, @ptrCast(idx_data[offset .. offset + 4]), .big);
        try testing.expect(val >= prev);
        prev = val;
    }

    // SHA-1 in the idx should match our computed hash
    const expected_hash = try computeGitHash(allocator, "blob", content);
    defer allocator.free(expected_hash);
    var expected_sha1: [20]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected_sha1, expected_hash);

    const sha1_start = 8 + 256 * 4;
    try testing.expectEqualSlices(u8, &expected_sha1, idx_data[sha1_start .. sha1_start + 20]);
}

// ============================================================================
// Test: generatePackIndex with multiple blobs, idx is sorted
// ============================================================================
test "idx gen: multiple blobs, SHA-1 table is sorted" {
    const allocator = testing.allocator;
    const contents = [_][]const u8{
        "alpha\n",
        "bravo\n",
        "charlie\n",
        "delta\n",
        "echo\n",
    };

    const pack_data = try buildPackWithBlobs(allocator, &contents);
    defer allocator.free(pack_data);

    const idx_data = try objects.generatePackIndex(pack_data, allocator);
    defer allocator.free(idx_data);

    // Should have 5 objects
    const total_objects = std.mem.readInt(u32, @ptrCast(idx_data[8 + 255 * 4 .. 8 + 255 * 4 + 4]), .big);
    try testing.expectEqual(@as(u32, 5), total_objects);

    // SHA-1 table must be sorted
    const sha1_start = 8 + 256 * 4;
    var i: u32 = 1;
    while (i < total_objects) : (i += 1) {
        const a = idx_data[sha1_start + (i - 1) * 20 .. sha1_start + (i - 1) * 20 + 20];
        const b = idx_data[sha1_start + i * 20 .. sha1_start + i * 20 + 20];
        try testing.expect(std.mem.order(u8, a, b) == .lt);
    }
}

// ============================================================================
// Test: generatePackIndex → git verify-pack accepts our idx
// ============================================================================
test "idx gen: our idx accepted by git verify-pack" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    runGitNoOutput(allocator, tmp_path, &.{ "init", "-b", "main" }) catch return;

    const contents = [_][]const u8{ "file one\n", "file two\n", "file three\n" };
    const pack_data = try buildPackWithBlobs(allocator, &contents);
    defer allocator.free(pack_data);

    const idx_data = try objects.generatePackIndex(pack_data, allocator);
    defer allocator.free(idx_data);

    // Write both files
    const pack_dir = try std.fmt.allocPrint(allocator, "{s}/.git/objects/pack", .{tmp_path});
    defer allocator.free(pack_dir);
    std.fs.cwd().makePath(pack_dir) catch {};

    const checksum = pack_data[pack_data.len - 20 ..];
    const checksum_hex = try std.fmt.allocPrint(allocator, "{}", .{std.fmt.fmtSliceHexLower(checksum)});
    defer allocator.free(checksum_hex);

    const pack_path = try std.fmt.allocPrint(allocator, "{s}/pack-{s}.pack", .{ pack_dir, checksum_hex });
    defer allocator.free(pack_path);
    {
        const f = try std.fs.cwd().createFile(pack_path, .{});
        defer f.close();
        try f.writeAll(pack_data);
    }

    const idx_path = try std.fmt.allocPrint(allocator, "{s}/pack-{s}.idx", .{ pack_dir, checksum_hex });
    defer allocator.free(idx_path);
    {
        const f = try std.fs.cwd().createFile(idx_path, .{});
        defer f.close();
        try f.writeAll(idx_data);
    }

    // git verify-pack should accept our pack+idx
    const verify_out = runGit(allocator, tmp_path, &.{ "verify-pack", pack_path }) catch |err| {
        std.debug.print("git verify-pack failed: {}\n", .{err});
        return;
    };
    defer allocator.free(verify_out);
    // If we got here without error, git accepted it
}

// ============================================================================
// Test: saveReceivedPack end-to-end
// ============================================================================
test "saveReceivedPack: saves pack + idx, objects readable" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    runGitNoOutput(allocator, tmp_path, &.{ "init", "-b", "main" }) catch return;

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_path});
    defer allocator.free(git_dir);

    const blob_content = "saveReceivedPack test content\n";
    const pack_data = try buildPackWithBlobs(allocator, &.{blob_content});
    defer allocator.free(pack_data);

    const platform = RealFsPlatform{};
    const checksum_hex = try objects.saveReceivedPack(pack_data, git_dir, &platform, allocator);
    defer allocator.free(checksum_hex);

    // Verify files exist
    const pack_dir = try std.fmt.allocPrint(allocator, "{s}/objects/pack", .{git_dir});
    defer allocator.free(pack_dir);

    const pack_path = try std.fmt.allocPrint(allocator, "{s}/pack-{s}.pack", .{ pack_dir, checksum_hex });
    defer allocator.free(pack_path);
    const idx_path = try std.fmt.allocPrint(allocator, "{s}/pack-{s}.idx", .{ pack_dir, checksum_hex });
    defer allocator.free(idx_path);

    // Both files should exist
    _ = try std.fs.cwd().statFile(pack_path);
    _ = try std.fs.cwd().statFile(idx_path);

    // Should be able to read the blob back
    const expected_hash = try computeGitHash(allocator, "blob", blob_content);
    defer allocator.free(expected_hash);

    const loaded = objects.GitObject.load(expected_hash, git_dir, &platform, allocator) catch |err| {
        std.debug.print("Failed to load blob after saveReceivedPack: {}\n", .{err});
        return;
    };
    defer loaded.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.blob, loaded.type);
    try testing.expectEqualStrings(blob_content, loaded.data);
}

// ============================================================================
// Test: saveReceivedPack with git-created pack (repack → read raw → save)
// ============================================================================
test "saveReceivedPack: git-created pack saved + re-indexed correctly" {
    const allocator = testing.allocator;

    // Create a repo and repack to get a real git pack
    var tmp1 = testing.tmpDir(.{});
    defer tmp1.cleanup();
    const tmp1_path = try tmp1.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp1_path);

    runGitNoOutput(allocator, tmp1_path, &.{ "init", "-b", "main" }) catch return;
    runGitNoOutput(allocator, tmp1_path, &.{ "config", "user.email", "t@t.com" }) catch return;
    runGitNoOutput(allocator, tmp1_path, &.{ "config", "user.name", "T" }) catch return;

    const file_content = "file for re-index test\n";
    try tmp1.dir.writeFile(.{ .sub_path = "data.txt", .data = file_content });
    runGitNoOutput(allocator, tmp1_path, &.{ "add", "." }) catch return;
    runGitNoOutput(allocator, tmp1_path, &.{ "commit", "-m", "test" }) catch return;
    runGitNoOutput(allocator, tmp1_path, &.{ "repack", "-a", "-d" }) catch return;

    // Find and read the pack file
    const pack_dir1 = try std.fmt.allocPrint(allocator, "{s}/.git/objects/pack", .{tmp1_path});
    defer allocator.free(pack_dir1);

    var dir = std.fs.cwd().openDir(pack_dir1, .{ .iterate = true }) catch return;
    defer dir.close();

    var pack_filename: ?[]u8 = null;
    defer if (pack_filename) |pf| allocator.free(pf);
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".pack")) {
            pack_filename = try allocator.dupe(u8, entry.name);
            break;
        }
    }
    if (pack_filename == null) return;

    const full_pack_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pack_dir1, pack_filename.? });
    defer allocator.free(full_pack_path);

    const pack_data = try std.fs.cwd().readFileAlloc(allocator, full_pack_path, 50 * 1024 * 1024);
    defer allocator.free(pack_data);

    // Create a fresh repo and save the pack there with our idx generator
    var tmp2 = testing.tmpDir(.{});
    defer tmp2.cleanup();
    const tmp2_path = try tmp2.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp2_path);

    runGitNoOutput(allocator, tmp2_path, &.{ "init", "-b", "main" }) catch return;

    const git_dir2 = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp2_path});
    defer allocator.free(git_dir2);

    const platform = RealFsPlatform{};
    const checksum_hex = try objects.saveReceivedPack(pack_data, git_dir2, &platform, allocator);
    defer allocator.free(checksum_hex);

    // Get blob hash from original repo
    const hash_raw = runGit(allocator, tmp1_path, &.{ "hash-object", "data.txt" }) catch return;
    defer allocator.free(hash_raw);
    const blob_hash = std.mem.trim(u8, hash_raw, " \t\n\r");

    // Read blob from the new repo using our generated idx
    const loaded = objects.GitObject.load(blob_hash, git_dir2, &platform, allocator) catch |err| {
        std.debug.print("Failed to load blob from re-indexed pack: {}\n", .{err});
        return;
    };
    defer loaded.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.blob, loaded.type);
    try testing.expectEqualStrings(file_content, loaded.data);

    // Bonus: git verify-pack should also accept our idx
    const pack_path2 = try std.fmt.allocPrint(allocator, "{s}/objects/pack/pack-{s}.pack", .{ git_dir2, checksum_hex });
    defer allocator.free(pack_path2);

    const verify_out = runGit(allocator, tmp2_path, &.{ "verify-pack", pack_path2 }) catch |err| {
        std.debug.print("git verify-pack failed on re-indexed pack: {}\n", .{err});
        return;
    };
    defer allocator.free(verify_out);
}

// ============================================================================
// Test: idx gen rejects invalid pack data
// ============================================================================
test "idx gen: rejects non-PACK data" {
    const allocator = testing.allocator;
    const bad_data = "NOT_A_PACK_FILE_AT_ALL_NOPE";
    const result = objects.generatePackIndex(bad_data, allocator);
    try testing.expectError(error.PackFileTooSmall, result);
}

test "idx gen: rejects truncated pack" {
    const allocator = testing.allocator;
    // Valid header but too short
    var short_pack: [12]u8 = undefined;
    @memcpy(short_pack[0..4], "PACK");
    std.mem.writeInt(u32, short_pack[4..8], 2, .big);
    std.mem.writeInt(u32, short_pack[8..12], 1, .big);
    const result = objects.generatePackIndex(&short_pack, allocator);
    try testing.expectError(error.PackFileTooSmall, result);
}
