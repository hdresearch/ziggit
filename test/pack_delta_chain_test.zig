const std = @import("std");
const idx_writer = @import("idx_writer");
const pack_writer = @import("pack_writer");

// ============================================================================
// Helpers
// ============================================================================

fn compressData(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var compressed = std.ArrayList(u8).init(allocator);
    errdefer compressed.deinit();
    var compressor = try std.compress.zlib.compressor(compressed.writer(), .{});
    try compressor.writer().writeAll(data);
    try compressor.finish();
    return compressed.toOwnedSlice();
}

fn encodePackHeader(buf: *std.ArrayList(u8), obj_type: u3, size: usize) !void {
    var s = size;
    var first_byte: u8 = (@as(u8, obj_type) << 4) | @as(u8, @intCast(s & 0x0F));
    s >>= 4;
    if (s > 0) first_byte |= 0x80;
    try buf.append(first_byte);
    while (s > 0) {
        var b: u8 = @intCast(s & 0x7F);
        s >>= 7;
        if (s > 0) b |= 0x80;
        try buf.append(b);
    }
}

fn encodeDeltaVarint(buf: *std.ArrayList(u8), value: usize) !void {
    var v = value;
    while (true) {
        var b: u8 = @intCast(v & 0x7F);
        v >>= 7;
        if (v > 0) b |= 0x80;
        try buf.append(b);
        if (v == 0) break;
    }
}

fn encodeOfsOffset(buf: *std.ArrayList(u8), negative_offset: usize) !void {
    var offset = negative_offset;
    var bytes: [10]u8 = undefined;
    var n: usize = 0;
    bytes[n] = @intCast(offset & 0x7F);
    n += 1;
    offset >>= 7;
    while (offset > 0) {
        offset -= 1;
        bytes[n] = @intCast(0x80 | (offset & 0x7F));
        n += 1;
        offset >>= 7;
    }
    while (n > 0) {
        n -= 1;
        try buf.append(bytes[n]);
    }
}

fn gitHashObject(comptime type_str: []const u8, data: []const u8) [20]u8 {
    var hasher = std.crypto.hash.Sha1.init(.{});
    var hdr_buf: [64]u8 = undefined;
    const header = std.fmt.bufPrint(&hdr_buf, "{s} {}\x00", .{ type_str, data.len }) catch unreachable;
    hasher.update(header);
    hasher.update(data);
    var sha: [20]u8 = undefined;
    hasher.final(&sha);
    return sha;
}

/// Build a delta that copies all of base_data and then inserts extra_data.
fn buildAppendDelta(allocator: std.mem.Allocator, base_len: usize, target: []const u8) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    try encodeDeltaVarint(&buf, base_len); // base size
    try encodeDeltaVarint(&buf, target.len); // target size

    // Copy instruction: copy base_len bytes from offset 0
    if (base_len > 0) {
        var cmd: u8 = 0x80; // copy flag
        const copy_size: usize = base_len;

        // Encode offset = 0 (no offset bytes needed)
        // Encode size
        if (copy_size & 0xFF != 0) cmd |= 0x10;
        if ((copy_size >> 8) & 0xFF != 0) cmd |= 0x20;
        if ((copy_size >> 16) & 0xFF != 0) cmd |= 0x40;
        try buf.append(cmd);
        if (copy_size & 0xFF != 0) try buf.append(@intCast(copy_size & 0xFF));
        if ((copy_size >> 8) & 0xFF != 0) try buf.append(@intCast((copy_size >> 8) & 0xFF));
        if ((copy_size >> 16) & 0xFF != 0) try buf.append(@intCast((copy_size >> 16) & 0xFF));
    }

    // Insert instruction: append the extra bytes
    const extra = target[base_len..];
    if (extra.len > 0) {
        try buf.append(@intCast(extra.len)); // insert N bytes
        try buf.appendSlice(extra);
    }

    return buf.toOwnedSlice();
}

fn appendPackChecksum(pack: *std.ArrayList(u8)) !void {
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack.items);
    var cksum: [20]u8 = undefined;
    hasher.final(&cksum);
    try pack.appendSlice(&cksum);
}

fn setupTmpDir() ![]const u8 {
    const allocator = std.testing.allocator;
    const tmp = try std.fmt.allocPrint(allocator, "/tmp/ziggit_delta_chain_{}", .{std.crypto.random.int(u64)});
    try std.fs.cwd().makePath(tmp);
    return tmp;
}

fn cleanupTmpDir(path: []const u8) void {
    std.fs.cwd().deleteTree(path) catch {};
    std.testing.allocator.free(path);
}

// ============================================================================
// REF_DELTA chain: base -> ref_delta1 -> ref_delta2
// ============================================================================

test "REF_DELTA chain: base -> delta1 -> delta2 (3-level chain)" {
    const allocator = std.testing.allocator;

    const base_data = "Line 1: base content\n";
    const target1 = "Line 1: base content\nLine 2: delta1\n";
    const target2 = "Line 1: base content\nLine 2: delta1\nLine 3: delta2\n";

    const base_sha = gitHashObject("blob", base_data);
    const target1_sha = gitHashObject("blob", target1);

    var pack = std.ArrayList(u8).init(allocator);
    defer pack.deinit();

    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, 3, .big); // 3 objects

    // Object 1: base blob
    try encodePackHeader(&pack, 3, base_data.len);
    const c1 = try compressData(allocator, base_data);
    defer allocator.free(c1);
    try pack.appendSlice(c1);

    // Object 2: REF_DELTA -> base (produces target1)
    const delta1 = try buildAppendDelta(allocator, base_data.len, target1);
    defer allocator.free(delta1);
    try encodePackHeader(&pack, 7, delta1.len);
    try pack.appendSlice(&base_sha);
    const c2 = try compressData(allocator, delta1);
    defer allocator.free(c2);
    try pack.appendSlice(c2);

    // Object 3: REF_DELTA -> target1 (produces target2)
    const delta2 = try buildAppendDelta(allocator, target1.len, target2);
    defer allocator.free(delta2);
    try encodePackHeader(&pack, 7, delta2.len);
    try pack.appendSlice(&target1_sha);
    const c3 = try compressData(allocator, delta2);
    defer allocator.free(c3);
    try pack.appendSlice(c3);

    try appendPackChecksum(&pack);

    const idx_data = try idx_writer.generateIdxFromData(allocator, pack.items);
    defer allocator.free(idx_data);

    // Should have 3 objects
    const fanout_end = 8 + 256 * 4;
    const total = std.mem.readInt(u32, idx_data[fanout_end - 4 ..][0..4], .big);
    try std.testing.expectEqual(@as(u32, 3), total);

    // Verify all 3 SHA-1s are present
    const expected_shas = [_][20]u8{
        base_sha,
        target1_sha,
        gitHashObject("blob", target2),
    };

    for (expected_shas) |expected| {
        var found = false;
        for (0..3) |i| {
            const sha = idx_data[fanout_end + i * 20 ..][0..20];
            if (std.mem.eql(u8, sha, &expected)) {
                found = true;
                break;
            }
        }
        const hex = std.fmt.bytesToHex(expected, .lower);
        if (!found) {
            std.debug.print("Missing SHA-1 in idx: {s}\n", .{&hex});
        }
        try std.testing.expect(found);
    }
}

test "git verify-pack accepts REF_DELTA chain pack" {
    const allocator = std.testing.allocator;
    const tmp_dir = try setupTmpDir();
    defer cleanupTmpDir(tmp_dir);

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_dir});
    defer allocator.free(git_dir);
    {
        const r = try std.process.Child.run(.{ .allocator = allocator, .argv = &.{ "git", "init", "--bare", git_dir } });
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }

    const base_data = "Base content for chain test\n";
    const target1 = "Base content for chain test\nSecond line\n";
    const target2 = "Base content for chain test\nSecond line\nThird line\n";

    const base_sha = gitHashObject("blob", base_data);
    const target1_sha = gitHashObject("blob", target1);

    var pack = std.ArrayList(u8).init(allocator);
    defer pack.deinit();

    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, 3, .big);

    // Base blob
    try encodePackHeader(&pack, 3, base_data.len);
    const c1 = try compressData(allocator, base_data);
    defer allocator.free(c1);
    try pack.appendSlice(c1);

    // REF_DELTA -> base
    const d1 = try buildAppendDelta(allocator, base_data.len, target1);
    defer allocator.free(d1);
    try encodePackHeader(&pack, 7, d1.len);
    try pack.appendSlice(&base_sha);
    const c2 = try compressData(allocator, d1);
    defer allocator.free(c2);
    try pack.appendSlice(c2);

    // REF_DELTA -> target1
    const d2 = try buildAppendDelta(allocator, target1.len, target2);
    defer allocator.free(d2);
    try encodePackHeader(&pack, 7, d2.len);
    try pack.appendSlice(&target1_sha);
    const c3 = try compressData(allocator, d2);
    defer allocator.free(c3);
    try pack.appendSlice(c3);

    try appendPackChecksum(&pack);

    const hex = try pack_writer.savePack(allocator, git_dir, pack.items);
    defer allocator.free(hex);
    const pp = try pack_writer.packPath(allocator, git_dir, hex);
    defer allocator.free(pp);
    try idx_writer.generateIdx(allocator, pp);

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .max_output_bytes = 10 * 1024 * 1024,
        .argv = &.{ "git", "verify-pack", "-v", pp },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(@as(u8, 0), result.term.Exited);

    // Should list 3 objects
    var obj_count: usize = 0;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len > 40 and std.mem.indexOf(u8, line, "blob") != null) {
            obj_count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 3), obj_count);
}

// ============================================================================
// Mixed OFS_DELTA and REF_DELTA in the same pack
// ============================================================================

test "mixed OFS_DELTA and REF_DELTA in same pack" {
    const allocator = std.testing.allocator;
    const tmp_dir = try setupTmpDir();
    defer cleanupTmpDir(tmp_dir);

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_dir});
    defer allocator.free(git_dir);
    {
        const r = try std.process.Child.run(.{ .allocator = allocator, .argv = &.{ "git", "init", "--bare", git_dir } });
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }

    const base1 = "Base blob one content here\n";
    const target_ofs = "Base blob one content here\nOFS delta appended\n";
    const base2 = "Base blob two different content\n";
    const target_ref = "Base blob two different content\nREF delta appended\n";

    const base2_sha = gitHashObject("blob", base2);

    var pack = std.ArrayList(u8).init(allocator);
    defer pack.deinit();

    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, 4, .big); // 4 objects

    // Object 1: base1 blob
    const obj1_start = pack.items.len;
    try encodePackHeader(&pack, 3, base1.len);
    const c1 = try compressData(allocator, base1);
    defer allocator.free(c1);
    try pack.appendSlice(c1);

    // Object 2: OFS_DELTA -> base1
    const obj2_start = pack.items.len;
    const d_ofs = try buildAppendDelta(allocator, base1.len, target_ofs);
    defer allocator.free(d_ofs);
    try encodePackHeader(&pack, 6, d_ofs.len);
    try encodeOfsOffset(&pack, obj2_start - obj1_start);
    const c2 = try compressData(allocator, d_ofs);
    defer allocator.free(c2);
    try pack.appendSlice(c2);

    // Object 3: base2 blob
    try encodePackHeader(&pack, 3, base2.len);
    const c3 = try compressData(allocator, base2);
    defer allocator.free(c3);
    try pack.appendSlice(c3);

    // Object 4: REF_DELTA -> base2
    const d_ref = try buildAppendDelta(allocator, base2.len, target_ref);
    defer allocator.free(d_ref);
    try encodePackHeader(&pack, 7, d_ref.len);
    try pack.appendSlice(&base2_sha);
    const c4 = try compressData(allocator, d_ref);
    defer allocator.free(c4);
    try pack.appendSlice(c4);

    try appendPackChecksum(&pack);

    const hex = try pack_writer.savePack(allocator, git_dir, pack.items);
    defer allocator.free(hex);
    const pp = try pack_writer.packPath(allocator, git_dir, hex);
    defer allocator.free(pp);
    try idx_writer.generateIdx(allocator, pp);

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .max_output_bytes = 10 * 1024 * 1024,
        .argv = &.{ "git", "verify-pack", "-v", pp },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(@as(u8, 0), result.term.Exited);

    // 4 object lines
    var obj_count: usize = 0;
    var lines_iter = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines_iter.next()) |line| {
        if (line.len > 40 and std.mem.indexOf(u8, line, "blob") != null) {
            obj_count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 4), obj_count);
}

// ============================================================================
// Real git-created pack with deltas: clone, gc, verify our idx
// ============================================================================

test "git gc pack with deltas: our idx matches git verify-pack" {
    const allocator = std.testing.allocator;
    const tmp_dir = try setupTmpDir();
    defer cleanupTmpDir(tmp_dir);

    // Create a real git repo with similar-content files to trigger delta compression
    const repo_dir = try std.fmt.allocPrint(allocator, "{s}/repo", .{tmp_dir});
    defer allocator.free(repo_dir);

    {
        const r = try std.process.Child.run(.{ .allocator = allocator, .argv = &.{ "git", "init", repo_dir } });
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }

    // Create files with similar content to trigger deltas
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{repo_dir});
    defer allocator.free(git_dir);

    {
        const f1_path = try std.fmt.allocPrint(allocator, "{s}/file.txt", .{repo_dir});
        defer allocator.free(f1_path);
        const f = try std.fs.cwd().createFile(f1_path, .{});
        defer f.close();
        try f.writeAll("This is a test file with some content that will be deltified.\nLine 2\nLine 3\nLine 4\nLine 5\n");
    }

    inline for (.{
        &.{ "git", "-C", repo_dir, "add", "." },
        &.{ "git", "-C", repo_dir, "commit", "-m", "first" },
    }) |argv| {
        const r = try std.process.Child.run(.{ .allocator = allocator, .argv = argv });
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }

    // Modify file slightly to create similar object (delta candidate)
    {
        const f1_path = try std.fmt.allocPrint(allocator, "{s}/file.txt", .{repo_dir});
        defer allocator.free(f1_path);
        const f = try std.fs.cwd().createFile(f1_path, .{});
        defer f.close();
        try f.writeAll("This is a test file with some content that will be deltified.\nLine 2\nLine 3\nLine 4\nLine 5\nLine 6 (new)\n");
    }

    inline for (.{
        &.{ "git", "-C", repo_dir, "add", "." },
        &.{ "git", "-C", repo_dir, "commit", "-m", "second" },
        &.{ "git", "-C", repo_dir, "gc", "--aggressive" },
    }) |argv| {
        const r = try std.process.Child.run(.{ .allocator = allocator, .argv = argv });
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }

    // Find the .pack file git created
    const pack_dir = try std.fmt.allocPrint(allocator, "{s}/objects/pack", .{git_dir});
    defer allocator.free(pack_dir);

    var dir = try std.fs.cwd().openDir(pack_dir, .{ .iterate = true });
    defer dir.close();
    var pack_name: ?[]u8 = null;
    defer if (pack_name) |n| allocator.free(n);

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".pack")) {
            pack_name = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pack_dir, entry.name });
            break;
        }
    }
    try std.testing.expect(pack_name != null);

    // Read the git-created pack
    const pack_data = try std.fs.cwd().readFileAlloc(allocator, pack_name.?, 50 * 1024 * 1024);
    defer allocator.free(pack_data);

    // Delete git's idx so we can generate our own
    const idx_name = try std.fmt.allocPrint(allocator, "{s}", .{pack_name.?[0 .. pack_name.?.len - 5]});
    defer allocator.free(idx_name);
    const idx_path = try std.fmt.allocPrint(allocator, "{s}.idx", .{idx_name});
    defer allocator.free(idx_path);
    std.fs.cwd().deleteFile(idx_path) catch {};

    // Generate our idx
    try idx_writer.generateIdx(allocator, pack_name.?);

    // git verify-pack on our generated idx
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .max_output_bytes = 10 * 1024 * 1024,
        .argv = &.{ "git", "--git-dir", git_dir, "verify-pack", "-v", pack_name.? },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) {
        std.debug.print("verify-pack stderr: {s}\n", .{result.stderr});
    }
    try std.testing.expectEqual(@as(u8, 0), result.term.Exited);
}

// ============================================================================
// Fetch simulation: incremental ref updates
// ============================================================================

test "incremental fetch: update existing remote ref and add new one" {
    const allocator = std.testing.allocator;
    const tmp_dir = try setupTmpDir();
    defer cleanupTmpDir(tmp_dir);

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp_dir});
    defer allocator.free(git_dir);

    // Create initial repo structure with existing remote ref
    const refs_path = try std.fmt.allocPrint(allocator, "{s}/refs/remotes/origin", .{git_dir});
    defer allocator.free(refs_path);
    try std.fs.cwd().makePath(refs_path);
    const tags_path = try std.fmt.allocPrint(allocator, "{s}/refs/tags", .{git_dir});
    defer allocator.free(tags_path);
    try std.fs.cwd().makePath(tags_path);

    // Write initial main ref
    {
        const path = try std.fmt.allocPrint(allocator, "{s}/refs/remotes/origin/main", .{git_dir});
        defer allocator.free(path);
        const f = try std.fs.cwd().createFile(path, .{});
        defer f.close();
        try f.writeAll("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n");
    }

    // Simulate fetch: update main, add feature branch
    const ref_updates = [_]pack_writer.RefUpdate{
        .{ .name = "refs/heads/main", .hash = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" },
        .{ .name = "refs/heads/feature", .hash = "cccccccccccccccccccccccccccccccccccccccc" },
        .{ .name = "refs/tags/v1.0", .hash = "dddddddddddddddddddddddddddddddddddddd" },
    };
    try pack_writer.updateRefsAfterFetch(allocator, git_dir, &ref_updates);

    // main should be updated
    {
        const path = try std.fmt.allocPrint(allocator, "{s}/refs/remotes/origin/main", .{git_dir});
        defer allocator.free(path);
        const content = try std.fs.cwd().readFileAlloc(allocator, path, 256);
        defer allocator.free(content);
        try std.testing.expectEqualStrings("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", std.mem.trimRight(u8, content, "\n"));
    }

    // feature should be new
    {
        const path = try std.fmt.allocPrint(allocator, "{s}/refs/remotes/origin/feature", .{git_dir});
        defer allocator.free(path);
        const content = try std.fs.cwd().readFileAlloc(allocator, path, 256);
        defer allocator.free(content);
        try std.testing.expectEqualStrings("cccccccccccccccccccccccccccccccccccccccc", std.mem.trimRight(u8, content, "\n"));
    }

    // tag should be written directly
    {
        const path = try std.fmt.allocPrint(allocator, "{s}/refs/tags/v1.0", .{git_dir});
        defer allocator.free(path);
        const content = try std.fs.cwd().readFileAlloc(allocator, path, 256);
        defer allocator.free(content);
        try std.testing.expectEqualStrings("dddddddddddddddddddddddddddddddddddddd", std.mem.trimRight(u8, content, "\n"));
    }

    // FETCH_HEAD should exist
    {
        const path = try std.fmt.allocPrint(allocator, "{s}/FETCH_HEAD", .{git_dir});
        defer allocator.free(path);
        const content = try std.fs.cwd().readFileAlloc(allocator, path, 4096);
        defer allocator.free(content);
        try std.testing.expect(std.mem.indexOf(u8, content, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb") != null);
        try std.testing.expect(std.mem.indexOf(u8, content, "cccccccccccccccccccccccccccccccccccccccc") != null);
    }
}

// ============================================================================
// git cat-file round trip: we write pack+idx, git reads objects back
// ============================================================================

test "git cat-file reads objects from our pack+idx" {
    const allocator = std.testing.allocator;
    const tmp_dir = try setupTmpDir();
    defer cleanupTmpDir(tmp_dir);

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/test.git", .{tmp_dir});
    defer allocator.free(git_dir);
    {
        const r = try std.process.Child.run(.{ .allocator = allocator, .argv = &.{ "git", "init", "--bare", git_dir } });
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }

    const blob_data = "Hello, this is the blob content for cat-file test.\n";
    const blob_sha = gitHashObject("blob", blob_data);
    const blob_hex = std.fmt.bytesToHex(blob_sha, .lower);

    // Build pack with one blob
    var pack = std.ArrayList(u8).init(allocator);
    defer pack.deinit();
    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, 1, .big);
    try encodePackHeader(&pack, 3, blob_data.len);
    const comp = try compressData(allocator, blob_data);
    defer allocator.free(comp);
    try pack.appendSlice(comp);
    try appendPackChecksum(&pack);

    const hex = try pack_writer.savePack(allocator, git_dir, pack.items);
    defer allocator.free(hex);
    const pp = try pack_writer.packPath(allocator, git_dir, hex);
    defer allocator.free(pp);
    try idx_writer.generateIdx(allocator, pp);

    // git cat-file should read the blob back
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "--git-dir", git_dir, "cat-file", "-p", &blob_hex },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(@as(u8, 0), result.term.Exited);
    try std.testing.expectEqualStrings(blob_data, result.stdout);
}
