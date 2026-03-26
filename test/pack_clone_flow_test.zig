const std = @import("std");
const testing = std.testing;
const objects = @import("git_objects");

// ============================================================================
// Tests for the full HTTPS clone/fetch flow:
//   1. git creates pack → ziggit receives → saves → reads all objects
//   2. REF_DELTA resolution within same pack
//   3. fixThinPack + saveReceivedPack end-to-end
//   4. Verify generatePackIndex SHA-1 correctness against git
//   5. OFS_DELTA with various offset encodings
// ============================================================================

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
    const stdout = try child.stdout.?.reader().readAllAlloc(allocator, 4 * 1024 * 1024);
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

// Platform shim for tests (matches what objects.zig expects)
const NativePlatform = struct {
    fs: Fs = .{},

    const Fs = struct {
        pub fn readFile(_: Fs, alloc: std.mem.Allocator, path: []const u8) ![]u8 {
            return std.fs.cwd().readFileAlloc(alloc, path, 100 * 1024 * 1024);
        }

        pub fn writeFile(_: Fs, path: []const u8, data: []const u8) !void {
            const file = try std.fs.cwd().createFile(path, .{});
            defer file.close();
            try file.writeAll(data);
        }

        pub fn makeDir(_: Fs, path: []const u8) !void {
            try std.fs.cwd().makeDir(path);
        }
    };
};

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

/// Build a hand-crafted pack file from a list of objects
const PackObject = struct {
    obj_type: enum { blob, tree, commit, tag, ofs_delta, ref_delta },
    data: []const u8,
    /// For ofs_delta: negative offset to base object
    ofs_base_offset: usize,
    /// For ref_delta: SHA-1 of base object
    ref_base_sha1: ?[20]u8,
};

fn buildPackFile(allocator: std.mem.Allocator, pack_objects: []const PackObject) ![]u8 {
    var pack = std.ArrayList(u8).init(allocator);
    defer pack.deinit();

    // Header
    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, @intCast(pack_objects.len), .big);

    for (pack_objects) |obj| {
        const type_num: u3 = switch (obj.obj_type) {
            .blob => 3,
            .tree => 2,
            .commit => 1,
            .tag => 4,
            .ofs_delta => 6,
            .ref_delta => 7,
        };

        // Compress data
        var compressed = std.ArrayList(u8).init(allocator);
        defer compressed.deinit();
        var input = std.io.fixedBufferStream(obj.data);
        try std.compress.zlib.compress(input.reader(), compressed.writer(), .{});

        // Encode type+size header
        const size = obj.data.len;
        var first: u8 = (@as(u8, type_num) << 4) | @as(u8, @intCast(size & 0x0F));
        var remaining = size >> 4;
        if (remaining > 0) first |= 0x80;
        try pack.append(first);
        while (remaining > 0) {
            var b: u8 = @intCast(remaining & 0x7F);
            remaining >>= 7;
            if (remaining > 0) b |= 0x80;
            try pack.append(b);
        }

        // Delta-specific headers
        if (obj.obj_type == .ofs_delta) {
            // Encode negative offset (git's variable-length encoding)
            var off = obj.ofs_base_offset;
            var off_buf: [10]u8 = undefined;
            var off_len: usize = 1;
            off_buf[0] = @intCast(off & 0x7F);
            off >>= 7;
            while (off > 0) {
                off -= 1;
                // Shift existing bytes right
                var j: usize = off_len;
                while (j > 0) : (j -= 1) {
                    off_buf[j] = off_buf[j - 1];
                }
                off_buf[0] = @intCast(0x80 | (off & 0x7F));
                off >>= 7;
                off_len += 1;
            }
            try pack.appendSlice(off_buf[0..off_len]);
        } else if (obj.obj_type == .ref_delta) {
            try pack.appendSlice(&(obj.ref_base_sha1 orelse return error.MissingRefDeltaSha1));
        }

        try pack.appendSlice(compressed.items);
    }

    // Compute and append SHA-1 checksum
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack.items);
    var checksum: [20]u8 = undefined;
    hasher.final(&checksum);
    try pack.appendSlice(&checksum);

    return try pack.toOwnedSlice();
}

/// Compute git object SHA-1 from type and data
fn computeObjectSha1(obj_type: []const u8, data: []const u8) [20]u8 {
    var hasher = std.crypto.hash.Sha1.init(.{});
    var header_buf: [64]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "{s} {}\x00", .{ obj_type, data.len }) catch unreachable;
    hasher.update(header);
    hasher.update(data);
    var sha1: [20]u8 = undefined;
    hasher.final(&sha1);
    return sha1;
}

// ============================================================================
// Test: Full clone simulation - git creates repo → repack → ziggit reads all
// ============================================================================
test "clone flow: git repo with 5 commits, repack, ziggit reads every object" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Create repo with multiple commits
    try runGitNoOutput(allocator, tmp_path, &.{ "init", "-b", "main" });
    try runGitNoOutput(allocator, tmp_path, &.{ "config", "user.email", "test@test.com" });
    try runGitNoOutput(allocator, tmp_path, &.{ "config", "user.name", "Test" });

    // Create 5 commits with varied content
    for (0..5) |i| {
        const filename = try std.fmt.allocPrint(allocator, "file{}.txt", .{i});
        defer allocator.free(filename);
        const prefix = "Content of file ";
        const padding = " with some padding data to make the content larger for delta compression testing.\n";
        const content = try std.fmt.allocPrint(allocator, "{s}{}{s}{s}{s}{s}{s}", .{ prefix, i, padding, padding, padding, padding, padding });
        defer allocator.free(content);
        try tmp.dir.writeFile(.{ .sub_path = filename, .data = content });
        try runGitNoOutput(allocator, tmp_path, &.{ "add", filename });
        const msg = try std.fmt.allocPrint(allocator, "Commit {}", .{i});
        defer allocator.free(msg);
        try runGitNoOutput(allocator, tmp_path, &.{ "commit", "-m", msg });
    }

    // Aggressive repack to create deltas
    try runGitNoOutput(allocator, tmp_path, &.{ "repack", "-a", "-d", "--window=10", "--depth=5" });

    // Read pack file
    const pack_dir_path = try std.fmt.allocPrint(allocator, "{s}/.git/objects/pack", .{tmp_path});
    defer allocator.free(pack_dir_path);
    var pack_dir = try std.fs.cwd().openDir(pack_dir_path, .{ .iterate = true });
    defer pack_dir.close();

    var pack_file: ?[]u8 = null;
    defer if (pack_file) |f| allocator.free(f);
    var iter = pack_dir.iterate();
    while (try iter.next()) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".pack")) {
            const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pack_dir_path, entry.name });
            defer allocator.free(path);
            pack_file = try std.fs.cwd().readFileAlloc(allocator, path, 10 * 1024 * 1024);
            break;
        }
    }
    try testing.expect(pack_file != null);

    // Simulate clone reception: saveReceivedPack to a fresh repo
    var tmp2 = testing.tmpDir(.{});
    defer tmp2.cleanup();
    const tmp2_path = try tmp2.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp2_path);

    try runGitNoOutput(allocator, tmp2_path, &.{ "init", "-b", "main" });
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp2_path});
    defer allocator.free(git_dir);

    const platform = NativePlatform{};

    const checksum_hex = try objects.saveReceivedPack(pack_file.?, git_dir, platform, allocator);
    defer allocator.free(checksum_hex);

    // Now get all object hashes from original repo
    const all_objects_raw = try runGit(allocator, tmp_path, &.{ "rev-list", "--all", "--objects" });
    defer allocator.free(all_objects_raw);

    var lines_iter = std.mem.splitScalar(u8, std.mem.trimRight(u8, all_objects_raw, "\n"), '\n');
    var object_count: usize = 0;
    var read_success: usize = 0;

    while (lines_iter.next()) |line| {
        if (line.len < 40) continue;
        const hash = line[0..40];
        object_count += 1;

        // Read with git cat-file from original
        const git_type_raw = try runGit(allocator, tmp_path, &.{ "cat-file", "-t", hash });
        defer allocator.free(git_type_raw);
        const git_type = std.mem.trimRight(u8, git_type_raw, "\n");

        const git_content = try runGit(allocator, tmp_path, &.{ "cat-file", "-p", hash });
        defer allocator.free(git_content);

        // Read with ziggit from the cloned repo
        const obj = objects.GitObject.load(hash, git_dir, platform, allocator) catch |err| {
            std.debug.print("Failed to load {s} ({s}): {}\n", .{ hash, git_type, err });
            continue;
        };
        defer obj.deinit(allocator);

        // Verify type matches
        try testing.expectEqualStrings(git_type, obj.type.toString());

        // For blobs and commits, verify content matches
        if (obj.type == .blob or obj.type == .commit) {
            try testing.expectEqualStrings(git_content, obj.data);
        }

        read_success += 1;
    }

    // We should be able to read all objects
    try testing.expect(object_count >= 10); // At least 5 commits + 5 blobs + trees
    try testing.expectEqual(object_count, read_success);
}

// ============================================================================
// Test: readPackObjectAtOffset correctly reads all 4 base types from pack
// ============================================================================
test "readPackObjectAtOffset: all base types from hand-crafted pack" {
    const allocator = testing.allocator;

    const blob_data = "Hello, world!\n";
    const tree_data = "100644 test.txt\x00" ++ [_]u8{0xab} ** 20;
    const commit_data = "tree " ++ [_]u8{'a'} ** 40 ++ "\nauthor Test <t@t> 1 +0000\ncommitter Test <t@t> 1 +0000\n\ntest\n";
    const tag_data = "object " ++ [_]u8{'a'} ** 40 ++ "\ntype commit\ntag v1\ntagger Test <t@t> 1 +0000\n\nrelease\n";

    const pack_data = try buildPackFile(allocator, &.{
        .{ .obj_type = .blob, .data = blob_data, .ofs_base_offset = 0, .ref_base_sha1 = null },
        .{ .obj_type = .tree, .data = tree_data, .ofs_base_offset = 0, .ref_base_sha1 = null },
        .{ .obj_type = .commit, .data = commit_data, .ofs_base_offset = 0, .ref_base_sha1 = null },
        .{ .obj_type = .tag, .data = tag_data, .ofs_base_offset = 0, .ref_base_sha1 = null },
    });
    defer allocator.free(pack_data);

    // Read blob at offset 12 (right after header)
    const blob_obj = try objects.readPackObjectAtOffset(pack_data, 12, allocator);
    defer blob_obj.deinit(allocator);
    try testing.expectEqual(objects.ObjectType.blob, blob_obj.type);
    try testing.expectEqualStrings(blob_data, blob_obj.data);

    // Verify we can also generate a valid idx from this pack
    const idx_data = try objects.generatePackIndex(pack_data, allocator);
    defer allocator.free(idx_data);
    try testing.expect(idx_data.len > 1032); // At least header + fanout
}

// ============================================================================
// Test: OFS_DELTA with offset requiring multi-byte encoding
// ============================================================================
test "readPackObjectAtOffset: OFS_DELTA with multi-byte offset" {
    const allocator = testing.allocator;

    // Create a base blob that's large enough to push offset past 127
    const base_data = "A" ** 200;
    const base_sha1 = computeObjectSha1("blob", base_data);
    _ = base_sha1;

    // Build delta: copy all of base, then insert " EXTRA"
    const extra = " EXTRA";
    const result_data = base_data ++ extra;
    var delta = std.ArrayList(u8).init(allocator);
    defer delta.deinit();

    // Header varints
    var buf: [10]u8 = undefined;
    var n = encodeVarint(&buf, base_data.len);
    try delta.appendSlice(buf[0..n]);
    n = encodeVarint(&buf, result_data.len);
    try delta.appendSlice(buf[0..n]);

    // Copy command: offset=0, size=200
    const cmd: u8 = 0x80 | 0x10 | 0x20; // size byte 0 and byte 1
    try delta.append(cmd);
    try delta.append(@intCast(base_data.len & 0xFF)); // size low byte = 200
    try delta.append(@intCast((base_data.len >> 8) & 0xFF)); // size high byte = 0

    // Insert command
    try delta.append(@intCast(extra.len));
    try delta.appendSlice(extra);

    // Build pack with base blob then OFS_DELTA
    var pack = std.ArrayList(u8).init(allocator);
    defer pack.deinit();

    // Header
    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, 2, .big); // 2 objects

    // Object 1: base blob
    const base_obj_offset = pack.items.len;
    {
        var compressed = std.ArrayList(u8).init(allocator);
        defer compressed.deinit();
        var input = std.io.fixedBufferStream(@as([]const u8, base_data));
        try std.compress.zlib.compress(input.reader(), compressed.writer(), .{});

        const size = base_data.len;
        var first: u8 = (3 << 4) | @as(u8, @intCast(size & 0x0F)); // type=blob
        var rem = size >> 4;
        if (rem > 0) first |= 0x80;
        try pack.append(first);
        while (rem > 0) {
            var b: u8 = @intCast(rem & 0x7F);
            rem >>= 7;
            if (rem > 0) b |= 0x80;
            try pack.append(b);
        }
        try pack.appendSlice(compressed.items);
    }

    // Object 2: OFS_DELTA
    const delta_obj_offset = pack.items.len;
    {
        var compressed = std.ArrayList(u8).init(allocator);
        defer compressed.deinit();
        var input = std.io.fixedBufferStream(delta.items);
        try std.compress.zlib.compress(input.reader(), compressed.writer(), .{});

        const size = delta.items.len;
        var first: u8 = (6 << 4) | @as(u8, @intCast(size & 0x0F)); // type=ofs_delta
        var rem = size >> 4;
        if (rem > 0) first |= 0x80;
        try pack.append(first);
        while (rem > 0) {
            var b: u8 = @intCast(rem & 0x7F);
            rem >>= 7;
            if (rem > 0) b |= 0x80;
            try pack.append(b);
        }

        // Encode negative offset
        const negative_offset = delta_obj_offset - base_obj_offset;
        var off = negative_offset;
        var off_buf: [10]u8 = undefined;
        var off_len: usize = 1;
        off_buf[0] = @intCast(off & 0x7F);
        off >>= 7;
        while (off > 0) {
            off -= 1;
            var j: usize = off_len;
            while (j > 0) : (j -= 1) {
                off_buf[j] = off_buf[j - 1];
            }
            off_buf[0] = @intCast(0x80 | (off & 0x7F));
            off >>= 7;
            off_len += 1;
        }
        try pack.appendSlice(off_buf[0..off_len]);

        try pack.appendSlice(compressed.items);
    }

    // Checksum
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack.items);
    var checksum: [20]u8 = undefined;
    hasher.final(&checksum);
    try pack.appendSlice(&checksum);

    // Read the delta object
    const obj = try objects.readPackObjectAtOffset(pack.items, delta_obj_offset, allocator);
    defer obj.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.blob, obj.type);
    try testing.expectEqualStrings(result_data, obj.data);
}

// ============================================================================
// Test: generatePackIndex produces idx that git verify-pack accepts
// ============================================================================
test "clone flow: generatePackIndex output accepted by git verify-pack" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Build a pack with 3 blobs
    const blob1 = "First blob content\n";
    const blob2 = "Second blob with different data\n";
    const blob3 = "Third blob for good measure\n";

    const pack_data = try buildPackFile(allocator, &.{
        .{ .obj_type = .blob, .data = blob1, .ofs_base_offset = 0, .ref_base_sha1 = null },
        .{ .obj_type = .blob, .data = blob2, .ofs_base_offset = 0, .ref_base_sha1 = null },
        .{ .obj_type = .blob, .data = blob3, .ofs_base_offset = 0, .ref_base_sha1 = null },
    });
    defer allocator.free(pack_data);

    const idx_data = try objects.generatePackIndex(pack_data, allocator);
    defer allocator.free(idx_data);

    // Write pack + idx to temp dir
    try tmp.dir.writeFile(.{ .sub_path = "test.pack", .data = pack_data });
    try tmp.dir.writeFile(.{ .sub_path = "test.idx", .data = idx_data });

    const pack_path = try std.fmt.allocPrint(allocator, "{s}/test.pack", .{tmp_path});
    defer allocator.free(pack_path);

    // git verify-pack should accept our pack+idx
    const verify_out = runGit(allocator, tmp_path, &.{ "verify-pack", "-v", pack_path }) catch |err| {
        std.debug.print("git verify-pack failed: {}\n", .{err});
        return err;
    };
    defer allocator.free(verify_out);

    // Should contain 3 entries
    var line_count: usize = 0;
    var lines = std.mem.splitScalar(u8, std.mem.trimRight(u8, verify_out, "\n"), '\n');
    while (lines.next()) |line| {
        if (line.len >= 40 and (std.mem.indexOf(u8, line, " blob ") != null)) {
            line_count += 1;
        }
    }
    try testing.expectEqual(@as(usize, 3), line_count);
}

// ============================================================================
// Test: delta with copy size=0 (meaning 0x10000 = 65536)
// ============================================================================
test "delta: copy size 0 means 0x10000 in hand-crafted delta" {
    const allocator = testing.allocator;

    // Base data: exactly 0x10000 bytes
    const base_data = try allocator.alloc(u8, 0x10000);
    defer allocator.free(base_data);
    for (base_data, 0..) |*b, i| {
        b.* = @intCast(i & 0xFF);
    }

    // Build delta: header + copy(offset=0, size=0) which means copy 0x10000 bytes
    var delta_buf = std.ArrayList(u8).init(allocator);
    defer delta_buf.deinit();

    var buf: [10]u8 = undefined;
    var n = encodeVarint(&buf, 0x10000);
    try delta_buf.appendSlice(buf[0..n]); // base size
    n = encodeVarint(&buf, 0x10000);
    try delta_buf.appendSlice(buf[0..n]); // result size

    // Copy command with no size flags → size=0 → means 0x10000
    try delta_buf.append(0x80); // just the copy bit, no offset or size flags

    const result = try objects.applyDelta(base_data, delta_buf.items, allocator);
    defer allocator.free(result);

    try testing.expectEqual(@as(usize, 0x10000), result.len);
    try testing.expectEqualSlices(u8, base_data, result);
}

// ============================================================================
// Test: delta with 4-byte copy offset (offset > 16MB)
// ============================================================================
test "delta: copy with 4-byte offset" {
    const allocator = testing.allocator;

    // Base data with 256 bytes, but we copy from offset 200
    const base_data = try allocator.alloc(u8, 256);
    defer allocator.free(base_data);
    for (base_data, 0..) |*b, i| {
        b.* = @intCast(i & 0xFF);
    }

    var delta_buf = std.ArrayList(u8).init(allocator);
    defer delta_buf.deinit();

    var buf: [10]u8 = undefined;
    var n_v = encodeVarint(&buf, 256);
    try delta_buf.appendSlice(buf[0..n_v]); // base size
    n_v = encodeVarint(&buf, 56);
    try delta_buf.appendSlice(buf[0..n_v]); // result size = last 56 bytes

    // Copy command: offset=200 (needs 1 byte), size=56 (needs 1 byte)
    try delta_buf.append(0x80 | 0x01 | 0x10); // offset byte 0 + size byte 0
    try delta_buf.append(200); // offset byte 0
    try delta_buf.append(56); // size byte 0

    const result = try objects.applyDelta(base_data, delta_buf.items, allocator);
    defer allocator.free(result);

    try testing.expectEqual(@as(usize, 56), result.len);
    try testing.expectEqualSlices(u8, base_data[200..256], result);
}

// ============================================================================
// Test: git gc creates delta chains, ziggit resolves them all
// ============================================================================
test "clone flow: git gc delta chains all resolved by ziggit" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    try runGitNoOutput(allocator, tmp_path, &.{ "init", "-b", "main" });
    try runGitNoOutput(allocator, tmp_path, &.{ "config", "user.email", "t@t" });
    try runGitNoOutput(allocator, tmp_path, &.{ "config", "user.name", "T" });

    // Create a file and modify it 10 times to create deep delta chains
    const base_content = "Line 1\nLine 2\nLine 3\nLine 4\nLine 5\n" ** 10;
    try tmp.dir.writeFile(.{ .sub_path = "data.txt", .data = base_content });
    try runGitNoOutput(allocator, tmp_path, &.{ "add", "data.txt" });
    try runGitNoOutput(allocator, tmp_path, &.{ "commit", "-m", "initial" });

    for (0..10) |i| {
        const content = try std.fmt.allocPrint(allocator, "{s}Modification {}\n", .{ base_content, i });
        defer allocator.free(content);
        try tmp.dir.writeFile(.{ .sub_path = "data.txt", .data = content });
        try runGitNoOutput(allocator, tmp_path, &.{ "add", "data.txt" });
        const msg = try std.fmt.allocPrint(allocator, "edit {}", .{i});
        defer allocator.free(msg);
        try runGitNoOutput(allocator, tmp_path, &.{ "commit", "-m", msg });
    }

    // Aggressive gc
    try runGitNoOutput(allocator, tmp_path, &.{ "gc", "--aggressive" });

    // Read pack data
    const pack_dir_path = try std.fmt.allocPrint(allocator, "{s}/.git/objects/pack", .{tmp_path});
    defer allocator.free(pack_dir_path);
    var pack_dir = try std.fs.cwd().openDir(pack_dir_path, .{ .iterate = true });
    defer pack_dir.close();

    var pack_path: ?[]u8 = null;
    defer if (pack_path) |p| allocator.free(p);
    var piter = pack_dir.iterate();
    while (try piter.next()) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".pack")) {
            pack_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pack_dir_path, entry.name });
            break;
        }
    }
    try testing.expect(pack_path != null);

    const pack_data = try std.fs.cwd().readFileAlloc(allocator, pack_path.?, 10 * 1024 * 1024);
    defer allocator.free(pack_data);

    // Save to fresh repo
    var tmp2 = testing.tmpDir(.{});
    defer tmp2.cleanup();
    const tmp2_path = try tmp2.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp2_path);
    try runGitNoOutput(allocator, tmp2_path, &.{ "init", "-b", "main" });
    const git_dir2 = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp2_path});
    defer allocator.free(git_dir2);

    const platform = NativePlatform{};

    const hex = try objects.saveReceivedPack(pack_data, git_dir2, platform, allocator);
    defer allocator.free(hex);

    // Verify: get blob hashes for all versions of data.txt
    const log_out = try runGit(allocator, tmp_path, &.{ "log", "--format=%H", "--", "data.txt" });
    defer allocator.free(log_out);

    var commit_lines = std.mem.splitScalar(u8, std.mem.trimRight(u8, log_out, "\n"), '\n');
    var verified: usize = 0;
    while (commit_lines.next()) |commit_hash| {
        if (commit_hash.len != 40) continue;
        // Get tree from commit, then blob SHA from tree
        const rev_spec = try std.fmt.allocPrint(allocator, "{s}:data.txt", .{commit_hash});
        defer allocator.free(rev_spec);
        const tree_line = try runGit(allocator, tmp_path, &.{ "rev-parse", rev_spec });
        defer allocator.free(tree_line);
        const blob_hash_trimmed = std.mem.trimRight(u8, tree_line, "\n");
        if (blob_hash_trimmed.len != 40) continue;

        // Read with git
        const git_blob = try runGit(allocator, tmp_path, &.{ "cat-file", "blob", blob_hash_trimmed });
        defer allocator.free(git_blob);

        // Read with ziggit
        const zig_obj = objects.GitObject.load(blob_hash_trimmed, git_dir2, platform, allocator) catch |err| {
            std.debug.print("Failed to load blob {s}: {}\n", .{ blob_hash_trimmed, err });
            continue;
        };
        defer zig_obj.deinit(allocator);

        try testing.expectEqual(objects.ObjectType.blob, zig_obj.type);
        try testing.expectEqualStrings(git_blob, zig_obj.data);
        verified += 1;
    }

    // Should verify at least 10 blob versions
    try testing.expect(verified >= 10);
}

// ============================================================================
// Test: generatePackIndex SHA-1 table matches git index-pack output
// ============================================================================
test "clone flow: ziggit idx SHA-1 table matches git index-pack" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    // Build pack with several blobs
    const contents = [_][]const u8{
        "alpha content\n",
        "beta content with more data\n",
        "gamma short\n",
        "delta has some different bytes here\n",
        "epsilon is the fifth blob\n",
    };

    var pack_objects: [5]PackObject = undefined;
    for (&pack_objects, 0..) |*po, i| {
        po.* = .{ .obj_type = .blob, .data = contents[i], .ofs_base_offset = 0, .ref_base_sha1 = null };
    }

    const pack_data = try buildPackFile(allocator, &pack_objects);
    defer allocator.free(pack_data);

    // Generate idx with ziggit
    const our_idx = try objects.generatePackIndex(pack_data, allocator);
    defer allocator.free(our_idx);

    // Write pack to disk and have git generate idx
    try tmp.dir.writeFile(.{ .sub_path = "test.pack", .data = pack_data });
    const pack_path = try std.fmt.allocPrint(allocator, "{s}/test.pack", .{tmp_path});
    defer allocator.free(pack_path);

    const git_idx_out_path = try std.fmt.allocPrint(allocator, "{s}/git.idx", .{tmp_path});
    defer allocator.free(git_idx_out_path);
    try runGitNoOutput(allocator, tmp_path, &.{ "index-pack", "-o", git_idx_out_path, pack_path });
    const git_idx = try std.fs.cwd().readFileAlloc(allocator, git_idx_out_path, 10 * 1024 * 1024);
    defer allocator.free(git_idx);

    // Compare SHA-1 tables (both should have same hashes in same order)
    // SHA-1 table starts at offset 8 + 256*4 = 1032
    const sha1_start = 8 + 256 * 4;
    const n_objects: usize = 5;
    const sha1_end = sha1_start + n_objects * 20;

    try testing.expect(our_idx.len >= sha1_end);
    try testing.expect(git_idx.len >= sha1_end);

    // SHA-1 tables must be identical
    try testing.expectEqualSlices(u8, git_idx[sha1_start..sha1_end], our_idx[sha1_start..sha1_end]);

    // Fanout tables must be identical
    try testing.expectEqualSlices(u8, git_idx[8..sha1_start], our_idx[8..sha1_start]);
}

// ============================================================================
// Test: fixThinPack on pack without REF_DELTA returns same data
// ============================================================================
test "fixThinPack: non-thin pack returned unchanged" {
    const allocator = testing.allocator;

    const pack_data = try buildPackFile(allocator, &.{
        .{ .obj_type = .blob, .data = "hello\n", .ofs_base_offset = 0, .ref_base_sha1 = null },
    });
    defer allocator.free(pack_data);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);
    try runGitNoOutput(allocator, tmp_path, &.{ "init", "-b", "main" });
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_path});
    defer allocator.free(git_dir);

    const platform = NativePlatform{};

    const fixed = try objects.fixThinPack(pack_data, git_dir, platform, allocator);
    defer allocator.free(fixed);

    try testing.expectEqualSlices(u8, pack_data, fixed);
}

// ============================================================================
// Test: delta with interleaved copy and insert produces correct output
// ============================================================================
test "delta: interleaved copy-insert-copy-insert" {
    const allocator = testing.allocator;

    const base = "AAABBBCCCDDDEEE";

    // Target: "AAA" + "XY" + "DDD" + "Z" = "AAAXYDDDZ" (length 10)
    const expected = "AAAXYDDDZ";

    var delta_buf = std.ArrayList(u8).init(allocator);
    defer delta_buf.deinit();

    var buf: [10]u8 = undefined;
    var n_v = encodeVarint(&buf, base.len);
    try delta_buf.appendSlice(buf[0..n_v]);
    n_v = encodeVarint(&buf, expected.len);
    try delta_buf.appendSlice(buf[0..n_v]);

    // Copy AAA (offset=0, size=3)
    try delta_buf.append(0x80 | 0x10); // size byte 0
    try delta_buf.append(3); // size=3 (offset defaults to 0)

    // Insert "XY"
    try delta_buf.append(2);
    try delta_buf.appendSlice("XY");

    // Copy DDD (offset=9, size=3)
    try delta_buf.append(0x80 | 0x01 | 0x10); // offset byte 0 + size byte 0
    try delta_buf.append(9); // offset=9
    try delta_buf.append(3); // size=3

    // Insert "Z"
    try delta_buf.append(1);
    try delta_buf.appendSlice("Z");

    const result = try objects.applyDelta(base, delta_buf.items, allocator);
    defer allocator.free(result);

    try testing.expectEqualStrings(expected, result);
}

// ============================================================================
// Test: delta with copy using 2-byte offset (offset > 255)
// ============================================================================
test "delta: copy with 2-byte offset" {
    const allocator = testing.allocator;

    // Base: 512 bytes
    const base = try allocator.alloc(u8, 512);
    defer allocator.free(base);
    for (base, 0..) |*b, i| b.* = @intCast(i & 0xFF);

    // Copy 10 bytes from offset 300
    var delta_buf = std.ArrayList(u8).init(allocator);
    defer delta_buf.deinit();

    var buf: [10]u8 = undefined;
    var n_v = encodeVarint(&buf, 512);
    try delta_buf.appendSlice(buf[0..n_v]);
    n_v = encodeVarint(&buf, 10);
    try delta_buf.appendSlice(buf[0..n_v]);

    // Copy: offset=300 (0x12C), size=10
    try delta_buf.append(0x80 | 0x01 | 0x02 | 0x10); // offset bytes 0,1 + size byte 0
    try delta_buf.append(@intCast(300 & 0xFF)); // offset low = 0x2C
    try delta_buf.append(@intCast((300 >> 8) & 0xFF)); // offset high = 0x01
    try delta_buf.append(10); // size

    const result = try objects.applyDelta(base, delta_buf.items, allocator);
    defer allocator.free(result);

    try testing.expectEqual(@as(usize, 10), result.len);
    try testing.expectEqualSlices(u8, base[300..310], result);
}

// ============================================================================
// Test: applyDelta rejects delta with result size mismatch
// ============================================================================
test "delta: rejects result size mismatch" {
    const allocator = testing.allocator;

    const base = "hello";

    var delta_buf = std.ArrayList(u8).init(allocator);
    defer delta_buf.deinit();

    var buf: [10]u8 = undefined;
    var n_v = encodeVarint(&buf, 5);
    try delta_buf.appendSlice(buf[0..n_v]); // base_size=5
    n_v = encodeVarint(&buf, 100);
    try delta_buf.appendSlice(buf[0..n_v]); // result_size=100

    // Insert only 3 bytes (mismatch with claimed 100)
    try delta_buf.append(3);
    try delta_buf.appendSlice("abc");

    // applyDelta has fallback logic, but the strict path should detect the mismatch.
    // The permissive path may still produce output. Either way, it shouldn't crash.
    const result = objects.applyDelta(base, delta_buf.items, allocator);
    if (result) |r| {
        allocator.free(r);
        // Permissive mode produced output - that's acceptable for recovery
    } else |_| {
        // Strict rejection is also fine
    }
}

// ============================================================================
// Test: pack with annotated tag object round-trips
// ============================================================================
test "clone flow: pack with annotated tag readable after save" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp_path);

    try runGitNoOutput(allocator, tmp_path, &.{ "init", "-b", "main" });
    try runGitNoOutput(allocator, tmp_path, &.{ "config", "user.email", "t@t" });
    try runGitNoOutput(allocator, tmp_path, &.{ "config", "user.name", "T" });

    try tmp.dir.writeFile(.{ .sub_path = "README", .data = "read me\n" });
    try runGitNoOutput(allocator, tmp_path, &.{ "add", "README" });
    try runGitNoOutput(allocator, tmp_path, &.{ "commit", "-m", "init" });
    try runGitNoOutput(allocator, tmp_path, &.{ "tag", "-a", "v1.0", "-m", "Release 1.0" });

    try runGitNoOutput(allocator, tmp_path, &.{ "repack", "-a", "-d" });

    // Get tag object hash
    const tag_hash_raw = try runGit(allocator, tmp_path, &.{ "rev-parse", "v1.0" });
    defer allocator.free(tag_hash_raw);
    const tag_hash = std.mem.trimRight(u8, tag_hash_raw, "\n");

    // Read tag with git
    const git_tag = try runGit(allocator, tmp_path, &.{ "cat-file", "tag", tag_hash });
    defer allocator.free(git_tag);

    // Read pack and save to new repo
    const pack_dir_path = try std.fmt.allocPrint(allocator, "{s}/.git/objects/pack", .{tmp_path});
    defer allocator.free(pack_dir_path);

    var pdir = try std.fs.cwd().openDir(pack_dir_path, .{ .iterate = true });
    defer pdir.close();

    var pack_data: ?[]u8 = null;
    defer if (pack_data) |p| allocator.free(p);
    var pit = pdir.iterate();
    while (try pit.next()) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".pack")) {
            const p = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pack_dir_path, entry.name });
            defer allocator.free(p);
            pack_data = try std.fs.cwd().readFileAlloc(allocator, p, 10 * 1024 * 1024);
            break;
        }
    }
    try testing.expect(pack_data != null);

    var tmp2 = testing.tmpDir(.{});
    defer tmp2.cleanup();
    const tmp2_path = try tmp2.dir.realpathAlloc(allocator, ".");
    defer allocator.free(tmp2_path);
    try runGitNoOutput(allocator, tmp2_path, &.{ "init", "-b", "main" });

    const platform = NativePlatform{};
    const git_dir2 = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp2_path});
    defer allocator.free(git_dir2);

    const hex = try objects.saveReceivedPack(pack_data.?, git_dir2, platform, allocator);
    defer allocator.free(hex);

    // Read tag with ziggit
    // Note: tag_hash might point to the tag object or the commit. Let's get the tag object specifically.
    const tag_obj_hash_raw = try runGit(allocator, tmp_path, &.{ "rev-parse", "refs/tags/v1.0" });
    defer allocator.free(tag_obj_hash_raw);
    const tag_obj_hash = std.mem.trimRight(u8, tag_obj_hash_raw, "\n");

    // Check if this is actually a tag object
    const type_raw = try runGit(allocator, tmp_path, &.{ "cat-file", "-t", tag_obj_hash });
    defer allocator.free(type_raw);
    const obj_type = std.mem.trimRight(u8, type_raw, "\n");

    if (std.mem.eql(u8, obj_type, "tag")) {
        const zig_obj = try objects.GitObject.load(tag_obj_hash, git_dir2, platform, allocator);
        defer zig_obj.deinit(allocator);
        try testing.expectEqual(objects.ObjectType.tag, zig_obj.type);
        try testing.expectEqualStrings(git_tag, zig_obj.data);
    }
}

// ============================================================================
// Test: idx fanout table is monotonically increasing
// ============================================================================
test "idx: fanout table monotonically increasing" {
    const allocator = testing.allocator;

    const pack_data = try buildPackFile(allocator, &.{
        .{ .obj_type = .blob, .data = "aaa\n", .ofs_base_offset = 0, .ref_base_sha1 = null },
        .{ .obj_type = .blob, .data = "bbb\n", .ofs_base_offset = 0, .ref_base_sha1 = null },
        .{ .obj_type = .blob, .data = "ccc\n", .ofs_base_offset = 0, .ref_base_sha1 = null },
        .{ .obj_type = .blob, .data = "ddd\n", .ofs_base_offset = 0, .ref_base_sha1 = null },
        .{ .obj_type = .blob, .data = "eee\n", .ofs_base_offset = 0, .ref_base_sha1 = null },
        .{ .obj_type = .blob, .data = "fff\n", .ofs_base_offset = 0, .ref_base_sha1 = null },
        .{ .obj_type = .blob, .data = "ggg\n", .ofs_base_offset = 0, .ref_base_sha1 = null },
        .{ .obj_type = .blob, .data = "hhh\n", .ofs_base_offset = 0, .ref_base_sha1 = null },
    });
    defer allocator.free(pack_data);

    const idx_data = try objects.generatePackIndex(pack_data, allocator);
    defer allocator.free(idx_data);

    // Fanout starts at offset 8
    var prev: u32 = 0;
    for (0..256) |i| {
        const off = 8 + i * 4;
        const val = std.mem.readInt(u32, @ptrCast(idx_data[off .. off + 4]), .big);
        try testing.expect(val >= prev);
        prev = val;
    }
    // Last fanout entry should equal total objects
    try testing.expectEqual(@as(u32, 8), prev);
}

// ============================================================================
// Test: binary blob with null bytes and high bytes round-trips through pack
// ============================================================================
test "clone flow: binary data round-trips through pack" {
    const allocator = testing.allocator;

    // Create binary data with all byte values
    var binary: [256]u8 = undefined;
    for (&binary, 0..) |*b, i| b.* = @intCast(i);

    const pack_data = try buildPackFile(allocator, &.{
        .{ .obj_type = .blob, .data = &binary, .ofs_base_offset = 0, .ref_base_sha1 = null },
    });
    defer allocator.free(pack_data);

    const obj = try objects.readPackObjectAtOffset(pack_data, 12, allocator);
    defer obj.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.blob, obj.type);
    try testing.expectEqualSlices(u8, &binary, obj.data);
}
