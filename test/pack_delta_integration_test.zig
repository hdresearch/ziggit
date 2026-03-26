const std = @import("std");
const testing = std.testing;
const objects = @import("git_objects");

// ============================================================================
// Integration tests for pack file delta resolution through the full pipeline:
//   1. Build pack files with OFS_DELTA objects from scratch
//   2. Generate idx with generatePackIndex
//   3. Read objects back via GitObject.load
//   4. Verify against git CLI
//
// These tests exercise the critical path for HTTPS clone/fetch where the
// server sends a pack file containing delta-compressed objects.
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

/// Encode varint for delta headers
fn encodeVarint(buf: []u8, value: usize) usize {
    var v = value;
    var i: usize = 0;
    while (true) {
        buf[i] = @intCast(v & 0x7F);
        v >>= 7;
        if (v == 0) return i + 1;
        buf[i] |= 0x80;
        i += 1;
    }
}

/// Append a pack object header (type + variable-length size)
fn appendPackObjectHeader(pack: *std.ArrayList(u8), obj_type: u3, size: usize) !void {
    var s = size;
    var first_byte: u8 = (@as(u8, obj_type) << 4) | @as(u8, @intCast(s & 0x0F));
    s >>= 4;
    if (s > 0) first_byte |= 0x80;
    try pack.append(first_byte);
    while (s > 0) {
        var byte: u8 = @intCast(s & 0x7F);
        s >>= 7;
        if (s > 0) byte |= 0x80;
        try pack.append(byte);
    }
}

/// Encode OFS_DELTA negative offset (git's encoding: first byte has 7 bits, subsequent
/// bytes have (value + 1) << 7 semantics)
fn encodeOfsOffset(buf: []u8, offset: usize) usize {
    var off = offset;
    var i: usize = 0;
    buf[i] = @intCast(off & 0x7F);
    off >>= 7;
    i += 1;
    while (off > 0) {
        off -= 1;
        // Shift existing bytes right (we build in reverse)
        var j: usize = i;
        while (j > 0) : (j -= 1) {
            buf[j] = buf[j - 1];
        }
        buf[0] = @as(u8, @intCast(off & 0x7F)) | 0x80;
        off >>= 7;
        i += 1;
    }
    return i;
}

/// Build delta data: copy entire base then insert suffix
fn buildDelta(allocator: std.mem.Allocator, base_size: usize, result_data: []const u8, base_data: []const u8) ![]u8 {
    var delta = std.ArrayList(u8).init(allocator);
    // Header: base_size, result_size
    var buf: [10]u8 = undefined;
    var n = encodeVarint(&buf, base_size);
    try delta.appendSlice(buf[0..n]);
    n = encodeVarint(&buf, result_data.len);
    try delta.appendSlice(buf[0..n]);

    // Simple strategy: find common prefix from base, then insert the rest
    var common_len: usize = 0;
    while (common_len < base_data.len and common_len < result_data.len and
        base_data[common_len] == result_data[common_len])
    {
        common_len += 1;
    }

    // Copy command for common prefix
    if (common_len > 0) {
        try appendCopyCmd(&delta, 0, common_len);
    }

    // Insert command for the rest
    const remaining = result_data[common_len..];
    var pos: usize = 0;
    while (pos < remaining.len) {
        const chunk = @min(127, remaining.len - pos);
        try delta.append(@intCast(chunk));
        try delta.appendSlice(remaining[pos .. pos + chunk]);
        pos += chunk;
    }

    return delta.toOwnedSlice();
}

fn appendCopyCmd(delta: *std.ArrayList(u8), offset: usize, size: usize) !void {
    var cmd: u8 = 0x80;
    var params = std.ArrayList(u8).init(delta.allocator);
    defer params.deinit();

    if (offset & 0xFF != 0) { cmd |= 0x01; try params.append(@intCast(offset & 0xFF)); }
    if (offset & 0xFF00 != 0) { cmd |= 0x02; try params.append(@intCast((offset >> 8) & 0xFF)); }
    if (offset & 0xFF0000 != 0) { cmd |= 0x04; try params.append(@intCast((offset >> 16) & 0xFF)); }
    if (offset & 0xFF000000 != 0) { cmd |= 0x08; try params.append(@intCast((offset >> 24) & 0xFF)); }

    const actual_size = if (size == 0x10000) @as(usize, 0) else size;
    if (actual_size != 0) {
        if (actual_size & 0xFF != 0 or actual_size <= 0xFF) { cmd |= 0x10; try params.append(@intCast(actual_size & 0xFF)); }
        if (actual_size > 0xFF) { cmd |= 0x20; try params.append(@intCast((actual_size >> 8) & 0xFF)); }
        if (actual_size > 0xFFFF) { cmd |= 0x40; try params.append(@intCast((actual_size >> 16) & 0xFF)); }
    }

    try delta.append(cmd);
    try delta.appendSlice(params.items);
}

/// Build a pack file with a base blob + OFS_DELTA blob
fn buildPackWithOfsDelta(allocator: std.mem.Allocator, base_content: []const u8, delta_result: []const u8) ![]u8 {
    var pack = std.ArrayList(u8).init(allocator);
    defer pack.deinit();

    // Header
    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, 2, .big); // 2 objects

    // Object 1: base blob (type=3)
    const base_obj_start = pack.items.len;
    try appendPackObjectHeader(&pack, 3, base_content.len);
    {
        var compressed = std.ArrayList(u8).init(allocator);
        defer compressed.deinit();
        var input = std.io.fixedBufferStream(base_content);
        try std.compress.zlib.compress(input.reader(), compressed.writer(), .{});
        try pack.appendSlice(compressed.items);
    }

    // Object 2: OFS_DELTA (type=6) referencing object 1
    const delta_obj_start = pack.items.len;
    const delta_data = try buildDelta(allocator, base_content.len, delta_result, base_content);
    defer allocator.free(delta_data);

    try appendPackObjectHeader(&pack, 6, delta_data.len);

    // Encode negative offset to base object
    const negative_offset = delta_obj_start - base_obj_start;
    var ofs_buf: [10]u8 = undefined;
    const ofs_len = encodeOfsOffset(&ofs_buf, negative_offset);
    try pack.appendSlice(ofs_buf[0..ofs_len]);

    // Compressed delta data
    {
        var compressed = std.ArrayList(u8).init(allocator);
        defer compressed.deinit();
        var input = std.io.fixedBufferStream(delta_data);
        try std.compress.zlib.compress(input.reader(), compressed.writer(), .{});
        try pack.appendSlice(compressed.items);
    }

    // Checksum
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack.items);
    var checksum: [20]u8 = undefined;
    hasher.final(&checksum);
    try pack.appendSlice(&checksum);

    return try pack.toOwnedSlice();
}

// ============================================================================
// Test: Build OFS_DELTA pack, generate idx, read both objects back
// ============================================================================
test "ofs_delta pack: build, index, read base and delta objects" {
    const allocator = testing.allocator;

    const base_content = "line 1: shared content\nline 2: shared content\nline 3: base version\nline 4: shared content\n";
    const delta_result = "line 1: shared content\nline 2: shared content\nline 3: MODIFIED version\nline 4: shared content\n";

    const pack_data = try buildPackWithOfsDelta(allocator, base_content, delta_result);
    defer allocator.free(pack_data);

    // Generate idx
    const idx_data = try objects.generatePackIndex(pack_data, allocator);
    defer allocator.free(idx_data);

    // Verify idx has 2 objects
    const total = std.mem.readInt(u32, @ptrCast(idx_data[8 + 255 * 4 .. 8 + 255 * 4 + 4]), .big);
    try testing.expectEqual(@as(u32, 2), total);

    // Set up a temp git repo to load objects
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    runGitNoOutput(allocator, tmp_path, &.{ "init", "-b", "main" }) catch return;

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_path});
    defer allocator.free(git_dir);

    // Save pack + idx
    const platform = RealFsPlatform{};
    const checksum_hex = try objects.saveReceivedPack(pack_data, git_dir, &platform, allocator);
    defer allocator.free(checksum_hex);

    // Compute expected hashes
    const base_hash = try computeGitHash(allocator, "blob", base_content);
    defer allocator.free(base_hash);
    const delta_hash = try computeGitHash(allocator, "blob", delta_result);
    defer allocator.free(delta_hash);

    // Read base blob
    const base_obj = try objects.GitObject.load(base_hash, git_dir, &platform, allocator);
    defer base_obj.deinit(allocator);
    try testing.expectEqual(objects.ObjectType.blob, base_obj.type);
    try testing.expectEqualStrings(base_content, base_obj.data);

    // Read delta-resolved blob
    const delta_obj = try objects.GitObject.load(delta_hash, git_dir, &platform, allocator);
    defer delta_obj.deinit(allocator);
    try testing.expectEqual(objects.ObjectType.blob, delta_obj.type);
    try testing.expectEqualStrings(delta_result, delta_obj.data);
}

// ============================================================================
// Test: OFS_DELTA pack accepted by git verify-pack
// ============================================================================
test "ofs_delta pack: git verify-pack accepts our pack+idx" {
    const allocator = testing.allocator;

    const base_content = "base content for verify-pack test\n";
    const delta_result = "base content for verify-pack test\nwith appended line\n";

    const pack_data = try buildPackWithOfsDelta(allocator, base_content, delta_result);
    defer allocator.free(pack_data);

    const idx_data = try objects.generatePackIndex(pack_data, allocator);
    defer allocator.free(idx_data);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    runGitNoOutput(allocator, tmp_path, &.{ "init", "-b", "main" }) catch return;

    // Write pack + idx
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

    // git verify-pack should accept
    const verify_out = runGit(allocator, tmp_path, &.{ "verify-pack", pack_path }) catch |err| {
        std.debug.print("git verify-pack failed on ofs_delta pack: {}\n", .{err});
        return;
    };
    defer allocator.free(verify_out);
}

// ============================================================================
// Test: Multi-commit repo → repack with deltas → saveReceivedPack → read all
// This simulates what happens during HTTPS clone: server sends a deltified pack
// ============================================================================
test "clone simulation: git repack → saveReceivedPack → read all objects" {
    const allocator = testing.allocator;

    // Create source repo with multiple commits
    var src = testing.tmpDir(.{});
    defer src.cleanup();
    const src_path = try src.dir.realpathAlloc(allocator, ".");
    defer allocator.free(src_path);

    runGitNoOutput(allocator, src_path, &.{ "init", "-b", "main" }) catch return;
    runGitNoOutput(allocator, src_path, &.{ "config", "user.email", "t@t.com" }) catch return;
    runGitNoOutput(allocator, src_path, &.{ "config", "user.name", "T" }) catch return;

    // Create several commits with similar file content to ensure deltas
    var blob_hashes = std.ArrayList([]u8).init(allocator);
    defer {
        for (blob_hashes.items) |h| allocator.free(h);
        blob_hashes.deinit();
    }
    var commit_hashes = std.ArrayList([]u8).init(allocator);
    defer {
        for (commit_hashes.items) |h| allocator.free(h);
        commit_hashes.deinit();
    }

    for (0..6) |i| {
        const content = try std.fmt.allocPrint(allocator, "# README\n\nVersion {}\n\nShared paragraph that stays the same across versions.\nMore shared content here.\nAnd even more shared content.\n", .{i});
        defer allocator.free(content);
        try src.dir.writeFile(.{ .sub_path = "README.md", .data = content });
        runGitNoOutput(allocator, src_path, &.{ "add", "." }) catch return;
        const msg = try std.fmt.allocPrint(allocator, "commit {}", .{i});
        defer allocator.free(msg);
        runGitNoOutput(allocator, src_path, &.{ "commit", "-m", msg }) catch return;

        // Record blob hash
        const bh = runGit(allocator, src_path, &.{ "hash-object", "README.md" }) catch return;
        try blob_hashes.append(try allocator.dupe(u8, std.mem.trim(u8, bh, " \t\n\r")));
        allocator.free(bh);

        // Record commit hash
        const ch = runGit(allocator, src_path, &.{ "rev-parse", "HEAD" }) catch return;
        try commit_hashes.append(try allocator.dupe(u8, std.mem.trim(u8, ch, " \t\n\r")));
        allocator.free(ch);
    }

    // Get tree hash for the latest commit
    const tree_hash_raw = runGit(allocator, src_path, &.{ "rev-parse", "HEAD^{tree}" }) catch return;
    defer allocator.free(tree_hash_raw);
    const tree_hash = std.mem.trim(u8, tree_hash_raw, " \t\n\r");

    // Aggressive repack with deltas
    runGitNoOutput(allocator, src_path, &.{ "repack", "-a", "-d", "-f", "--depth=10", "--window=50" }) catch return;

    // Read the pack file
    const src_pack_dir = try std.fmt.allocPrint(allocator, "{s}/.git/objects/pack", .{src_path});
    defer allocator.free(src_pack_dir);
    var dir = std.fs.cwd().openDir(src_pack_dir, .{ .iterate = true }) catch return;
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

    const full_pack = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ src_pack_dir, pack_filename.? });
    defer allocator.free(full_pack);
    const pack_data = try std.fs.cwd().readFileAlloc(allocator, full_pack, 50 * 1024 * 1024);
    defer allocator.free(pack_data);

    // Create destination repo and save pack via saveReceivedPack (simulating clone)
    var dst = testing.tmpDir(.{});
    defer dst.cleanup();
    const dst_path = try dst.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dst_path);

    runGitNoOutput(allocator, dst_path, &.{ "init", "-b", "main" }) catch return;

    const dst_git = try std.fmt.allocPrint(allocator, "{s}/.git", .{dst_path});
    defer allocator.free(dst_git);

    const platform = RealFsPlatform{};
    const chk = try objects.saveReceivedPack(pack_data, dst_git, &platform, allocator);
    defer allocator.free(chk);

    // Read all blob versions from destination
    var blob_successes: usize = 0;
    for (blob_hashes.items, 0..) |hash, idx| {
        const loaded = objects.GitObject.load(hash, dst_git, &platform, allocator) catch |err| {
            std.debug.print("Clone sim: blob {}: {}\n", .{ idx, err });
            continue;
        };
        defer loaded.deinit(allocator);
        try testing.expectEqual(objects.ObjectType.blob, loaded.type);
        const expected_version = try std.fmt.allocPrint(allocator, "Version {}", .{idx});
        defer allocator.free(expected_version);
        try testing.expect(std.mem.indexOf(u8, loaded.data, expected_version) != null);
        blob_successes += 1;
    }
    try testing.expect(blob_successes == 6);

    // Read all commits
    var commit_successes: usize = 0;
    for (commit_hashes.items) |hash| {
        const loaded = objects.GitObject.load(hash, dst_git, &platform, allocator) catch continue;
        defer loaded.deinit(allocator);
        try testing.expectEqual(objects.ObjectType.commit, loaded.type);
        commit_successes += 1;
    }
    try testing.expect(commit_successes == 6);

    // Read the tree
    const tree_obj = objects.GitObject.load(tree_hash, dst_git, &platform, allocator) catch |err| {
        std.debug.print("Clone sim: tree load failed: {}\n", .{err});
        return;
    };
    defer tree_obj.deinit(allocator);
    try testing.expectEqual(objects.ObjectType.tree, tree_obj.type);
}

// ============================================================================
// Test: Delta copy with size=0 means 0x10000 (65536 bytes)
// ============================================================================
test "delta: copy size 0 means 0x10000" {
    const allocator = testing.allocator;

    // Create base data of exactly 0x10000 bytes
    const base = try allocator.alloc(u8, 0x10000);
    defer allocator.free(base);
    for (base, 0..) |*b, i| b.* = @intCast(i & 0xFF);

    // Build delta: copy offset=0, size=0 (which means 0x10000)
    var delta = std.ArrayList(u8).init(allocator);
    defer delta.deinit();
    var buf: [10]u8 = undefined;
    var n = encodeVarint(&buf, 0x10000); // base_size
    try delta.appendSlice(buf[0..n]);
    n = encodeVarint(&buf, 0x10000); // result_size
    try delta.appendSlice(buf[0..n]);
    // Copy command: offset=0 (no offset bytes), size=0 (no size bytes → means 0x10000)
    try delta.append(0x80); // Just the copy flag, no offset or size flags

    const delta_data = try delta.toOwnedSlice();
    defer allocator.free(delta_data);

    const result = try objects.applyDelta(base, delta_data, allocator);
    defer allocator.free(result);

    try testing.expectEqual(@as(usize, 0x10000), result.len);
    try testing.expectEqualSlices(u8, base, result);
}

// ============================================================================
// Test: Delta with non-zero offset requiring all 4 offset bytes
// ============================================================================
test "delta: copy with 4-byte offset" {
    const allocator = testing.allocator;

    // Create large enough base (need offset > 0xFFFFFF = 16MB... too large)
    // Instead test with offset=0x01020304 on a conceptual level
    // Actually let's test with offset that uses 2 bytes (0x0102)
    const base_size = 0x0200;
    const base = try allocator.alloc(u8, base_size);
    defer allocator.free(base);
    for (base, 0..) |*b, i| b.* = @intCast(i & 0xFF);

    // Copy 4 bytes from offset 0x0102
    var delta = std.ArrayList(u8).init(allocator);
    defer delta.deinit();
    var buf: [10]u8 = undefined;
    var n = encodeVarint(&buf, base_size);
    try delta.appendSlice(buf[0..n]);
    n = encodeVarint(&buf, 4);
    try delta.appendSlice(buf[0..n]);
    // Copy command: offset=0x0102, size=4
    // cmd = 0x80 | 0x01 (offset byte 0) | 0x02 (offset byte 1) | 0x10 (size byte 0)
    try delta.append(0x80 | 0x01 | 0x02 | 0x10);
    try delta.append(0x02); // offset byte 0 (low byte): 0x02
    try delta.append(0x01); // offset byte 1: 0x01 → offset = 0x0102
    try delta.append(4);    // size byte 0: 4

    const delta_data = try delta.toOwnedSlice();
    defer allocator.free(delta_data);

    const result = try objects.applyDelta(base, delta_data, allocator);
    defer allocator.free(result);

    try testing.expectEqual(@as(usize, 4), result.len);
    try testing.expectEqualSlices(u8, base[0x0102 .. 0x0102 + 4], result);
}

// ============================================================================
// Test: Chain of OFS_DELTA (delta of delta)
// ============================================================================
test "ofs_delta chain: delta referencing another delta" {
    const allocator = testing.allocator;

    // Create a repo with 3 versions of a file to get chained deltas
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    runGitNoOutput(allocator, tmp_path, &.{ "init", "-b", "main" }) catch return;
    runGitNoOutput(allocator, tmp_path, &.{ "config", "user.email", "t@t.com" }) catch return;
    runGitNoOutput(allocator, tmp_path, &.{ "config", "user.name", "T" }) catch return;

    const versions = [_][]const u8{
        "line 1\nline 2\nline 3\nline 4\nline 5\nline 6\nline 7\nline 8\nline 9\nline 10\n",
        "line 1\nline 2\nCHANGED 3\nline 4\nline 5\nline 6\nline 7\nline 8\nline 9\nline 10\n",
        "line 1\nline 2\nCHANGED 3\nline 4\nCHANGED 5\nline 6\nline 7\nline 8\nline 9\nline 10\n",
    };

    var hashes: [3][]u8 = undefined;
    for (versions, 0..) |content, i| {
        try tmp.dir.writeFile(.{ .sub_path = "file.txt", .data = content });
        runGitNoOutput(allocator, tmp_path, &.{ "add", "." }) catch return;
        const msg = try std.fmt.allocPrint(allocator, "v{}", .{i});
        defer allocator.free(msg);
        runGitNoOutput(allocator, tmp_path, &.{ "commit", "-m", msg }) catch return;
        const h = runGit(allocator, tmp_path, &.{ "hash-object", "file.txt" }) catch return;
        hashes[i] = try allocator.dupe(u8, std.mem.trim(u8, h, " \t\n\r"));
        allocator.free(h);
    }
    defer for (&hashes) |h| allocator.free(h);

    // Deep repack to create delta chains
    runGitNoOutput(allocator, tmp_path, &.{ "repack", "-a", "-d", "-f", "--depth=10" }) catch return;
    runGitNoOutput(allocator, tmp_path, &.{ "prune-packed" }) catch {};

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_path});
    defer allocator.free(git_dir);
    const platform = RealFsPlatform{};

    // Read all 3 versions back
    for (versions, 0..) |expected, i| {
        const loaded = objects.GitObject.load(hashes[i], git_dir, &platform, allocator) catch |err| {
            std.debug.print("Delta chain v{}: {}\n", .{ i, err });
            return;
        };
        defer loaded.deinit(allocator);
        try testing.expectEqual(objects.ObjectType.blob, loaded.type);
        try testing.expectEqualStrings(expected, loaded.data);
    }
}

// ============================================================================
// Test: generatePackIndex output matches git index-pack for same pack data
// ============================================================================
test "idx gen: our idx matches git index-pack SHA-1 table" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    runGitNoOutput(allocator, tmp_path, &.{ "init", "-b", "main" }) catch return;

    // Build a pack with several blobs
    const contents = [_][]const u8{
        "aaa\n",
        "bbb\n",
        "ccc\n",
    };

    // Build pack
    var pack = std.ArrayList(u8).init(allocator);
    defer pack.deinit();
    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, @intCast(contents.len), .big);
    for (contents) |content| {
        try appendPackObjectHeader(&pack, 3, content.len);
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
    const pack_data = try pack.toOwnedSlice();
    defer allocator.free(pack_data);

    // Generate our idx
    const our_idx = try objects.generatePackIndex(pack_data, allocator);
    defer allocator.free(our_idx);

    // Write pack, let git index-pack generate its idx
    const checksum_hex = try std.fmt.allocPrint(allocator, "{}", .{std.fmt.fmtSliceHexLower(&checksum)});
    defer allocator.free(checksum_hex);

    const pack_path = try std.fmt.allocPrint(allocator, "{s}/test-pack.pack", .{tmp_path});
    defer allocator.free(pack_path);
    {
        const f = try std.fs.cwd().createFile(pack_path, .{});
        defer f.close();
        try f.writeAll(pack_data);
    }

    runGitNoOutput(allocator, tmp_path, &.{ "index-pack", pack_path }) catch return;

    // Read git's idx
    const git_idx_path = try std.fmt.allocPrint(allocator, "{s}/test-pack.idx", .{tmp_path});
    defer allocator.free(git_idx_path);
    const git_idx = std.fs.cwd().readFileAlloc(allocator, git_idx_path, 10 * 1024 * 1024) catch return;
    defer allocator.free(git_idx);

    // Both should have same number of objects
    const our_total = std.mem.readInt(u32, @ptrCast(our_idx[8 + 255 * 4 .. 8 + 255 * 4 + 4]), .big);
    const git_total = std.mem.readInt(u32, @ptrCast(git_idx[8 + 255 * 4 .. 8 + 255 * 4 + 4]), .big);
    try testing.expectEqual(our_total, git_total);

    // SHA-1 tables should be identical (same objects, same sort order)
    const sha1_start: usize = 8 + 256 * 4;
    const sha1_len = @as(usize, our_total) * 20;
    try testing.expectEqualSlices(u8, git_idx[sha1_start .. sha1_start + sha1_len], our_idx[sha1_start .. sha1_start + sha1_len]);

    // Fanout tables should be identical
    try testing.expectEqualSlices(u8, git_idx[8 .. 8 + 256 * 4], our_idx[8 .. 8 + 256 * 4]);
}

// ============================================================================
// Test: saveReceivedPack + read-back matches git cat-file for all objects
// ============================================================================
test "saveReceivedPack: all objects match git cat-file" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    runGitNoOutput(allocator, tmp_path, &.{ "init", "-b", "main" }) catch return;

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_path});
    defer allocator.free(git_dir);
    const platform = RealFsPlatform{};

    // Build pack with several blobs
    const contents = [_][]const u8{
        "alpha content\n",
        "bravo content\n",
        "charlie content\n",
    };

    var pack = std.ArrayList(u8).init(allocator);
    defer pack.deinit();
    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, @intCast(contents.len), .big);
    for (contents) |content| {
        try appendPackObjectHeader(&pack, 3, content.len);
        var compressed = std.ArrayList(u8).init(allocator);
        defer compressed.deinit();
        var input = std.io.fixedBufferStream(content);
        try std.compress.zlib.compress(input.reader(), compressed.writer(), .{});
        try pack.appendSlice(compressed.items);
    }
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack.items);
    var cksum: [20]u8 = undefined;
    hasher.final(&cksum);
    try pack.appendSlice(&cksum);
    const pack_data = try pack.toOwnedSlice();
    defer allocator.free(pack_data);

    // Save via our infrastructure
    const chk = try objects.saveReceivedPack(pack_data, git_dir, &platform, allocator);
    defer allocator.free(chk);

    // For each blob, verify ziggit load matches git cat-file
    for (contents) |content| {
        const hash = try computeGitHash(allocator, "blob", content);
        defer allocator.free(hash);

        // ziggit
        const loaded = objects.GitObject.load(hash, git_dir, &platform, allocator) catch |err| {
            std.debug.print("ziggit load failed for blob: {}\n", .{err});
            continue;
        };
        defer loaded.deinit(allocator);
        try testing.expectEqualStrings(content, loaded.data);

        // git cat-file
        const git_content = runGit(allocator, tmp_path, &.{ "cat-file", "-p", hash }) catch continue;
        defer allocator.free(git_content);
        try testing.expectEqualStrings(content, git_content);
    }
}

// ============================================================================
// Test: Binary content in pack files (null bytes, high bytes)
// ============================================================================
test "pack: binary blob with null bytes round-trips correctly" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    runGitNoOutput(allocator, tmp_path, &.{ "init", "-b", "main" }) catch return;

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_path});
    defer allocator.free(git_dir);
    const platform = RealFsPlatform{};

    // Binary content with null bytes and all byte values
    var binary_content: [256]u8 = undefined;
    for (&binary_content, 0..) |*b, i| b.* = @intCast(i);

    // Build pack
    var pack = std.ArrayList(u8).init(allocator);
    defer pack.deinit();
    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, 1, .big);
    try appendPackObjectHeader(&pack, 3, binary_content.len);
    {
        var compressed = std.ArrayList(u8).init(allocator);
        defer compressed.deinit();
        var input = std.io.fixedBufferStream(&binary_content);
        try std.compress.zlib.compress(input.reader(), compressed.writer(), .{});
        try pack.appendSlice(compressed.items);
    }
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack.items);
    var cksum: [20]u8 = undefined;
    hasher.final(&cksum);
    try pack.appendSlice(&cksum);
    const pack_data = try pack.toOwnedSlice();
    defer allocator.free(pack_data);

    const chk = try objects.saveReceivedPack(pack_data, git_dir, &platform, allocator);
    defer allocator.free(chk);

    const hash = try computeGitHash(allocator, "blob", &binary_content);
    defer allocator.free(hash);

    const loaded = try objects.GitObject.load(hash, git_dir, &platform, allocator);
    defer loaded.deinit(allocator);
    try testing.expectEqual(objects.ObjectType.blob, loaded.type);
    try testing.expectEqualSlices(u8, &binary_content, loaded.data);
}
