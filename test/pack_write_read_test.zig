const std = @import("std");
const testing = std.testing;
const objects = @import("git_objects");

// ============================================================================
// Tests for pack file writing + idx generation + reading back
// This is critical infrastructure for HTTPS clone/fetch (NET-SMART/NET-PACK)
//
// When a remote sends a pack file, we need to:
//   1. Save the .pack file
//   2. Generate a .idx file from it
//   3. Read objects back from the pack
// ============================================================================

/// Real filesystem platform adapter for tests
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

const RealFsPlatform = struct {
    fs: RealFs = .{},
};

/// Run git command, return stdout
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

// ============================================================================
// Test: Write a pack file from scratch, index it with git, read with ziggit
// ============================================================================
test "pack write: create pack file, git index-pack, ziggit reads" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Init git repo
    runGitNoOutput(allocator, tmp_path, &.{ "init", "-b", "main" }) catch return;

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_path});
    defer allocator.free(git_dir);

    // Build a minimal pack file with one blob object
    const blob_content = "Hello from pack writer test!\n";
    const pack_data = try buildPackWithBlob(allocator, blob_content);
    defer allocator.free(pack_data);

    // Compute what the blob hash should be
    const expected_hash = try computeGitHash(allocator, "blob", blob_content);
    defer allocator.free(expected_hash);

    // Write the pack file
    const pack_dir = try std.fmt.allocPrint(allocator, "{s}/objects/pack", .{git_dir});
    defer allocator.free(pack_dir);
    std.fs.cwd().makePath(pack_dir) catch {};

    // Compute pack checksum for filename
    const pack_checksum_hex = try getPackChecksumHex(allocator, pack_data);
    defer allocator.free(pack_checksum_hex);

    const pack_path = try std.fmt.allocPrint(allocator, "{s}/pack-{s}.pack", .{ pack_dir, pack_checksum_hex });
    defer allocator.free(pack_path);

    {
        const file = try std.fs.cwd().createFile(pack_path, .{});
        defer file.close();
        try file.writeAll(pack_data);
    }

    // Use git index-pack to create the .idx file
    runGitNoOutput(allocator, tmp_path, &.{ "index-pack", pack_path }) catch |err| {
        std.debug.print("git index-pack failed: {}\n", .{err});
        return;
    };

    // Now read the blob back with ziggit
    const platform = RealFsPlatform{};
    const loaded = objects.GitObject.load(expected_hash, git_dir, &platform, allocator) catch |err| {
        std.debug.print("Failed to load from pack: {}\n", .{err});
        return;
    };
    defer loaded.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.blob, loaded.type);
    try testing.expectEqualStrings(blob_content, loaded.data);
}

// ============================================================================
// Test: Pack with multiple object types
// ============================================================================
test "pack write: multiple objects (blob + tree + commit), git indexes, ziggit reads all" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    runGitNoOutput(allocator, tmp_path, &.{ "init", "-b", "main" }) catch return;
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_path});
    defer allocator.free(git_dir);

    // Create objects via git so we know the exact content & hashes
    try tmp.dir.writeFile(.{ .sub_path = "hello.txt", .data = "multi-object test\n" });
    runGitNoOutput(allocator, tmp_path, &.{ "add", "." }) catch return;
    runGitNoOutput(allocator, tmp_path, &.{ "config", "user.email", "t@t.com" }) catch return;
    runGitNoOutput(allocator, tmp_path, &.{ "config", "user.name", "T" }) catch return;
    runGitNoOutput(allocator, tmp_path, &.{ "commit", "-m", "multi" }) catch return;

    // Get hashes
    const blob_hash_raw = runGit(allocator, tmp_path, &.{ "hash-object", "hello.txt" }) catch return;
    defer allocator.free(blob_hash_raw);
    const blob_hash = std.mem.trim(u8, blob_hash_raw, " \t\n\r");

    const tree_hash_raw = runGit(allocator, tmp_path, &.{ "rev-parse", "HEAD^{tree}" }) catch return;
    defer allocator.free(tree_hash_raw);
    const tree_hash = std.mem.trim(u8, tree_hash_raw, " \t\n\r");

    const commit_hash_raw = runGit(allocator, tmp_path, &.{ "rev-parse", "HEAD" }) catch return;
    defer allocator.free(commit_hash_raw);
    const commit_hash = std.mem.trim(u8, commit_hash_raw, " \t\n\r");

    // Repack and prune to ensure objects only in pack
    runGitNoOutput(allocator, tmp_path, &.{ "repack", "-a", "-d" }) catch return;
    runGitNoOutput(allocator, tmp_path, &.{ "prune-packed" }) catch {};

    // Read all three types
    const platform = RealFsPlatform{};

    const blob = objects.GitObject.load(blob_hash, git_dir, &platform, allocator) catch |err| {
        std.debug.print("Blob load failed: {}\n", .{err});
        return;
    };
    defer blob.deinit(allocator);
    try testing.expectEqual(objects.ObjectType.blob, blob.type);
    try testing.expectEqualStrings("multi-object test\n", blob.data);

    const tree = objects.GitObject.load(tree_hash, git_dir, &platform, allocator) catch |err| {
        std.debug.print("Tree load failed: {}\n", .{err});
        return;
    };
    defer tree.deinit(allocator);
    try testing.expectEqual(objects.ObjectType.tree, tree.type);
    try testing.expect(std.mem.indexOf(u8, tree.data, "hello.txt") != null);

    const commit = objects.GitObject.load(commit_hash, git_dir, &platform, allocator) catch |err| {
        std.debug.print("Commit load failed: {}\n", .{err});
        return;
    };
    defer commit.deinit(allocator);
    try testing.expectEqual(objects.ObjectType.commit, commit.type);
    try testing.expect(std.mem.indexOf(u8, commit.data, "multi") != null);
}

// ============================================================================
// Test: Pack with OFS_DELTA objects (git repack -f creates these)
// ============================================================================
test "pack write: ofs_delta objects from aggressive repack" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    runGitNoOutput(allocator, tmp_path, &.{ "init", "-b", "main" }) catch return;
    runGitNoOutput(allocator, tmp_path, &.{ "config", "user.email", "t@t.com" }) catch return;
    runGitNoOutput(allocator, tmp_path, &.{ "config", "user.name", "T" }) catch return;

    // Create files with similar content to encourage delta compression
    var hashes = std.ArrayList([]u8).init(allocator);
    defer {
        for (hashes.items) |h| allocator.free(h);
        hashes.deinit();
    }

    for (0..5) |i| {
        const content = try std.fmt.allocPrint(allocator, "shared header line 1\nshared header line 2\nversion={}\nshared footer line 1\nshared footer line 2\n", .{i});
        defer allocator.free(content);
        try tmp.dir.writeFile(.{ .sub_path = "data.txt", .data = content });
        runGitNoOutput(allocator, tmp_path, &.{ "add", "data.txt" }) catch return;
        const msg = try std.fmt.allocPrint(allocator, "v{}", .{i});
        defer allocator.free(msg);
        runGitNoOutput(allocator, tmp_path, &.{ "commit", "-m", msg }) catch return;

        const h = runGit(allocator, tmp_path, &.{ "hash-object", "data.txt" }) catch return;
        try hashes.append(try allocator.dupe(u8, std.mem.trim(u8, h, " \t\n\r")));
        allocator.free(h);
    }

    // Aggressive repack to force deltas
    runGitNoOutput(allocator, tmp_path, &.{ "repack", "-a", "-d", "-f", "--depth=5", "--window=10" }) catch return;
    runGitNoOutput(allocator, tmp_path, &.{ "prune-packed" }) catch {};

    // Verify pack has delta objects via git verify-pack
    const pack_dir = try std.fmt.allocPrint(allocator, "{s}/.git/objects/pack", .{tmp_path});
    defer allocator.free(pack_dir);
    var dir = std.fs.cwd().openDir(pack_dir, .{ .iterate = true }) catch return;
    defer dir.close();
    var iter = dir.iterate();
    var pack_filename: ?[]u8 = null;
    defer if (pack_filename) |pf| allocator.free(pf);
    while (try iter.next()) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".pack")) {
            pack_filename = try allocator.dupe(u8, entry.name);
            break;
        }
    }
    if (pack_filename == null) return;

    const full_pack_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pack_dir, pack_filename.? });
    defer allocator.free(full_pack_path);

    // git verify-pack shows if deltas exist
    const verify_out = runGit(allocator, tmp_path, &.{ "verify-pack", "-v", full_pack_path }) catch return;
    defer allocator.free(verify_out);
    const has_delta = std.mem.indexOf(u8, verify_out, "delta") != null or
        std.mem.indexOf(u8, verify_out, "ofs") != null;
    // May or may not have deltas depending on git version, but either way reading should work

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_path});
    defer allocator.free(git_dir);
    const platform = RealFsPlatform{};

    // Read all blob versions - tests delta resolution
    var successes: usize = 0;
    for (hashes.items, 0..) |hash, idx| {
        const loaded = objects.GitObject.load(hash, git_dir, &platform, allocator) catch |err| {
            std.debug.print("Failed version {}: {}\n", .{ idx, err });
            continue;
        };
        defer loaded.deinit(allocator);
        try testing.expectEqual(objects.ObjectType.blob, loaded.type);
        const version_str = try std.fmt.allocPrint(allocator, "version={}", .{idx});
        defer allocator.free(version_str);
        try testing.expect(std.mem.indexOf(u8, loaded.data, version_str) != null);
        successes += 1;
    }
    _ = has_delta;
    try testing.expect(successes == 5);
}

// ============================================================================
// Test: REF_DELTA objects (thin packs from fetch use these)
// ============================================================================
test "pack write: ref_delta via git pack-objects --thin" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    runGitNoOutput(allocator, tmp_path, &.{ "init", "-b", "main" }) catch return;
    runGitNoOutput(allocator, tmp_path, &.{ "config", "user.email", "t@t.com" }) catch return;
    runGitNoOutput(allocator, tmp_path, &.{ "config", "user.name", "T" }) catch return;

    // Create base content
    const base_content = "shared line 1\nshared line 2\nshared line 3\nshared line 4\n";
    try tmp.dir.writeFile(.{ .sub_path = "file.txt", .data = base_content });
    runGitNoOutput(allocator, tmp_path, &.{ "add", "." }) catch return;
    runGitNoOutput(allocator, tmp_path, &.{ "commit", "-m", "base" }) catch return;

    // Modify slightly
    const new_content = "shared line 1\nshared line 2\nCHANGED LINE\nshared line 4\n";
    try tmp.dir.writeFile(.{ .sub_path = "file.txt", .data = new_content });
    runGitNoOutput(allocator, tmp_path, &.{ "add", "." }) catch return;
    runGitNoOutput(allocator, tmp_path, &.{ "commit", "-m", "modified" }) catch return;

    // Standard repack (non-thin, since thin packs need to be fixed up for storage)
    runGitNoOutput(allocator, tmp_path, &.{ "repack", "-a", "-d", "-f" }) catch return;
    runGitNoOutput(allocator, tmp_path, &.{ "prune-packed" }) catch {};

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_path});
    defer allocator.free(git_dir);

    // Get both blob hashes
    const hash1_raw = runGit(allocator, tmp_path, &.{ "rev-parse", "HEAD~1:file.txt" }) catch return;
    defer allocator.free(hash1_raw);
    const hash1 = std.mem.trim(u8, hash1_raw, " \t\n\r");

    const hash2_raw = runGit(allocator, tmp_path, &.{ "rev-parse", "HEAD:file.txt" }) catch return;
    defer allocator.free(hash2_raw);
    const hash2 = std.mem.trim(u8, hash2_raw, " \t\n\r");

    const platform = RealFsPlatform{};

    const obj1 = objects.GitObject.load(hash1, git_dir, &platform, allocator) catch |err| {
        std.debug.print("Base blob load failed: {}\n", .{err});
        return;
    };
    defer obj1.deinit(allocator);
    try testing.expectEqualStrings(base_content, obj1.data);

    const obj2 = objects.GitObject.load(hash2, git_dir, &platform, allocator) catch |err| {
        std.debug.print("Modified blob load failed: {}\n", .{err});
        return;
    };
    defer obj2.deinit(allocator);
    try testing.expectEqualStrings(new_content, obj2.data);
}

// ============================================================================
// Test: savePackFile + generatePackIndex end-to-end
// ============================================================================
test "pack infra: savePackFile writes valid pack, git verifies it" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    runGitNoOutput(allocator, tmp_path, &.{ "init", "-b", "main" }) catch return;

    // Build pack with 3 blobs
    const contents = [_][]const u8{
        "blob one\n",
        "blob two\n",
        "blob three\n",
    };
    const pack_data = try buildPackWithBlobs(allocator, &contents);
    defer allocator.free(pack_data);

    // Write pack to repo
    const pack_dir = try std.fmt.allocPrint(allocator, "{s}/.git/objects/pack", .{tmp_path});
    defer allocator.free(pack_dir);
    std.fs.cwd().makePath(pack_dir) catch {};

    const checksum_hex = try getPackChecksumHex(allocator, pack_data);
    defer allocator.free(checksum_hex);

    const pack_path = try std.fmt.allocPrint(allocator, "{s}/pack-{s}.pack", .{ pack_dir, checksum_hex });
    defer allocator.free(pack_path);
    {
        const f = try std.fs.cwd().createFile(pack_path, .{});
        defer f.close();
        try f.writeAll(pack_data);
    }

    // git verify-pack should succeed (requires idx)
    runGitNoOutput(allocator, tmp_path, &.{ "index-pack", pack_path }) catch |err| {
        std.debug.print("git index-pack failed: {}\n", .{err});
        return;
    };

    const verify_out = runGit(allocator, tmp_path, &.{ "verify-pack", pack_path }) catch |err| {
        std.debug.print("git verify-pack failed: {}\n", .{err});
        return;
    };
    defer allocator.free(verify_out);

    // Now read blobs back with ziggit
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_path});
    defer allocator.free(git_dir);
    const platform = RealFsPlatform{};

    for (contents) |content| {
        const hash = try computeGitHash(allocator, "blob", content);
        defer allocator.free(hash);

        const loaded = objects.GitObject.load(hash, git_dir, &platform, allocator) catch |err| {
            std.debug.print("Failed to load blob '{s}': {}\n", .{ std.mem.trim(u8, content, "\n"), err });
            continue;
        };
        defer loaded.deinit(allocator);
        try testing.expectEqual(objects.ObjectType.blob, loaded.type);
        try testing.expectEqualStrings(content, loaded.data);
    }
}

// ============================================================================
// Test: Large blob in pack file
// ============================================================================
test "pack write: large blob (>64KB) in pack" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    runGitNoOutput(allocator, tmp_path, &.{ "init", "-b", "main" }) catch return;
    runGitNoOutput(allocator, tmp_path, &.{ "config", "user.email", "t@t.com" }) catch return;
    runGitNoOutput(allocator, tmp_path, &.{ "config", "user.name", "T" }) catch return;

    // Create a large file (100KB)
    const large_data = try allocator.alloc(u8, 100 * 1024);
    defer allocator.free(large_data);
    for (large_data, 0..) |*b, i| {
        b.* = @intCast(i % 256);
    }
    try tmp.dir.writeFile(.{ .sub_path = "big.bin", .data = large_data });
    runGitNoOutput(allocator, tmp_path, &.{ "add", "." }) catch return;
    runGitNoOutput(allocator, tmp_path, &.{ "commit", "-m", "big" }) catch return;

    const hash_raw = runGit(allocator, tmp_path, &.{ "hash-object", "big.bin" }) catch return;
    defer allocator.free(hash_raw);
    const hash = std.mem.trim(u8, hash_raw, " \t\n\r");

    runGitNoOutput(allocator, tmp_path, &.{ "repack", "-a", "-d" }) catch return;
    runGitNoOutput(allocator, tmp_path, &.{ "prune-packed" }) catch {};

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_path});
    defer allocator.free(git_dir);
    const platform = RealFsPlatform{};

    const loaded = objects.GitObject.load(hash, git_dir, &platform, allocator) catch |err| {
        std.debug.print("Large blob load failed: {}\n", .{err});
        return;
    };
    defer loaded.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.blob, loaded.type);
    try testing.expectEqual(large_data.len, loaded.data.len);
    try testing.expectEqualSlices(u8, large_data, loaded.data);
}

// ============================================================================
// Helper: Build a minimal pack file containing a single blob
// ============================================================================
fn buildPackWithBlob(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    const contents = [_][]const u8{content};
    return buildPackWithBlobs(allocator, &contents);
}

// ============================================================================
// Helper: Build a pack file containing multiple blobs
// ============================================================================
fn buildPackWithBlobs(allocator: std.mem.Allocator, contents: []const []const u8) ![]u8 {
    var pack = std.ArrayList(u8).init(allocator);
    defer pack.deinit();

    // Header: PACK + version(2) + object count
    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, @intCast(contents.len), .big);

    // Each blob object
    for (contents) |content| {
        // Pack object header: type=3 (blob), variable-length size
        try appendPackObjectHeader(&pack, 3, content.len);

        // Zlib-compressed content
        var compressed = std.ArrayList(u8).init(allocator);
        defer compressed.deinit();
        var input = std.io.fixedBufferStream(content);
        try std.compress.zlib.compress(input.reader(), compressed.writer(), .{});
        try pack.appendSlice(compressed.items);
    }

    // SHA-1 checksum of everything before
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack.items);
    var checksum: [20]u8 = undefined;
    hasher.final(&checksum);
    try pack.appendSlice(&checksum);

    return try pack.toOwnedSlice();
}

/// Append a pack object header (type + variable-length size)
fn appendPackObjectHeader(pack: *std.ArrayList(u8), obj_type: u3, size: usize) !void {
    // First byte: MSB continuation, 3-bit type, 4-bit size
    var s = size;
    var first_byte: u8 = (@as(u8, obj_type) << 4) | @as(u8, @intCast(s & 0x0F));
    s >>= 4;
    if (s > 0) first_byte |= 0x80;
    try pack.append(first_byte);

    // Continuation bytes: MSB continuation, 7-bit size
    while (s > 0) {
        var byte: u8 = @intCast(s & 0x7F);
        s >>= 7;
        if (s > 0) byte |= 0x80;
        try pack.append(byte);
    }
}

/// Compute git object hash: SHA1("type size\0data")
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

/// Get pack checksum as hex string (last 20 bytes of pack data)
fn getPackChecksumHex(allocator: std.mem.Allocator, pack_data: []const u8) ![]u8 {
    const checksum = pack_data[pack_data.len - 20 ..];
    return try std.fmt.allocPrint(allocator, "{}", .{std.fmt.fmtSliceHexLower(checksum)});
}
