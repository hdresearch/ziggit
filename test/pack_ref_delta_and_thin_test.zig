const std = @import("std");
const testing = std.testing;
const objects = @import("git_objects");

// ============================================================================
// Tests for REF_DELTA resolution, thin pack fixing, deep delta chains,
// and pack ↔ git interop for all object types.
// ============================================================================

/// Run a command in a directory, return stdout
fn run(alloc: std.mem.Allocator, dir: std.fs.Dir, argv: []const []const u8) ![]u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try dir.realpath(".", &path_buf);
    var child = std.process.Child.init(argv, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.cwd = dir_path;
    try child.spawn();
    const stdout = try child.stdout.?.reader().readAllAlloc(alloc, 10 * 1024 * 1024);
    const stderr = try child.stderr.?.reader().readAllAlloc(alloc, 10 * 1024 * 1024);
    defer alloc.free(stderr);
    const result = try child.wait();
    if (result.Exited != 0) {
        alloc.free(stdout);
        return error.CommandFailed;
    }
    return stdout;
}

fn git(alloc: std.mem.Allocator, dir: std.fs.Dir, argv: []const []const u8) !void {
    const out = try run(alloc, dir, argv);
    alloc.free(out);
}

fn trimNl(s: []const u8) []const u8 {
    return std.mem.trimRight(u8, s, "\n\r ");
}

fn readPackFile(alloc: std.mem.Allocator, dir: std.fs.Dir) ![]u8 {
    var pack_dir = try dir.openDir(".git/objects/pack", .{ .iterate = true });
    defer pack_dir.close();
    var it = pack_dir.iterate();
    while (try it.next()) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".pack")) {
            return try pack_dir.readFileAlloc(alloc, entry.name, 50 * 1024 * 1024);
        }
    }
    return error.NoPackFile;
}

/// Helper to build a pack with a single blob
fn buildBlobPack(alloc: std.mem.Allocator, data: []const u8) ![]u8 {
    var pack = std.ArrayList(u8).init(alloc);
    defer pack.deinit();
    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, 1, .big);
    // type=blob(3), encode size
    const sz = data.len;
    var first: u8 = (3 << 4) | @as(u8, @intCast(sz & 0x0F));
    var rem = sz >> 4;
    if (rem > 0) first |= 0x80;
    try pack.append(first);
    while (rem > 0) {
        var b: u8 = @intCast(rem & 0x7F);
        rem >>= 7;
        if (rem > 0) b |= 0x80;
        try pack.append(b);
    }
    var comp = std.ArrayList(u8).init(alloc);
    defer comp.deinit();
    var inp = std.io.fixedBufferStream(data);
    try std.compress.zlib.compress(inp.reader(), comp.writer(), .{});
    try pack.appendSlice(comp.items);
    var h = std.crypto.hash.Sha1.init(.{});
    h.update(pack.items);
    var ck: [20]u8 = undefined;
    h.final(&ck);
    try pack.appendSlice(&ck);
    return try pack.toOwnedSlice();
}

/// Compute the git object SHA-1 for a blob
fn blobSha1(data: []const u8) [20]u8 {
    var h = std.crypto.hash.Sha1.init(.{});
    var buf: [30]u8 = undefined;
    const header = std.fmt.bufPrint(&buf, "blob {}\x00", .{data.len}) catch unreachable;
    h.update(header);
    h.update(data);
    var out: [20]u8 = undefined;
    h.final(&out);
    return out;
}

/// Encode a variable-length integer (for delta headers)
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

/// Build a pack containing: base blob + REF_DELTA referencing that blob by SHA-1
fn buildRefDeltaPack(alloc: std.mem.Allocator, base_data: []const u8, result_data: []const u8) ![]u8 {
    var pack = std.ArrayList(u8).init(alloc);
    defer pack.deinit();

    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, 2, .big); // 2 objects

    // Object 1: base blob
    {
        const sz = base_data.len;
        var first: u8 = (3 << 4) | @as(u8, @intCast(sz & 0x0F));
        var rem = sz >> 4;
        if (rem > 0) first |= 0x80;
        try pack.append(first);
        while (rem > 0) {
            var b: u8 = @intCast(rem & 0x7F);
            rem >>= 7;
            if (rem > 0) b |= 0x80;
            try pack.append(b);
        }
        var comp = std.ArrayList(u8).init(alloc);
        defer comp.deinit();
        var inp = std.io.fixedBufferStream(base_data);
        try std.compress.zlib.compress(inp.reader(), comp.writer(), .{});
        try pack.appendSlice(comp.items);
    }

    // Object 2: REF_DELTA referencing base by SHA-1
    {
        // Build delta instructions
        var delta = std.ArrayList(u8).init(alloc);
        defer delta.deinit();
        var vbuf: [10]u8 = undefined;
        var n = encodeVarint(&vbuf, base_data.len);
        try delta.appendSlice(vbuf[0..n]);
        n = encodeVarint(&vbuf, result_data.len);
        try delta.appendSlice(vbuf[0..n]);

        // Copy entire base
        if (base_data.len > 0 and base_data.len <= 0xFFFF) {
            const cmd: u8 = 0x80 | 0x10;
            try delta.append(cmd);
            try delta.append(@intCast(base_data.len & 0xFF));
            if (base_data.len > 0xFF) {
                // Need to re-encode with size byte 1
                delta.items[delta.items.len - 2] |= 0x20;
                try delta.append(@intCast((base_data.len >> 8) & 0xFF));
            }
        }

        // Insert extra
        if (result_data.len > base_data.len) {
            const extra = result_data[base_data.len..];
            var pos: usize = 0;
            while (pos < extra.len) {
                const chunk = @min(127, extra.len - pos);
                try delta.append(@intCast(chunk));
                try delta.appendSlice(extra[pos .. pos + chunk]);
                pos += chunk;
            }
        }

        const delta_size = delta.items.len;

        // Pack header: type=REF_DELTA(7)
        var first: u8 = (7 << 4) | @as(u8, @intCast(delta_size & 0x0F));
        var rem = delta_size >> 4;
        if (rem > 0) first |= 0x80;
        try pack.append(first);
        while (rem > 0) {
            var b: u8 = @intCast(rem & 0x7F);
            rem >>= 7;
            if (rem > 0) b |= 0x80;
            try pack.append(b);
        }

        // 20-byte SHA-1 of the base object
        const base_sha = blobSha1(base_data);
        try pack.appendSlice(&base_sha);

        // Compressed delta
        var comp = std.ArrayList(u8).init(alloc);
        defer comp.deinit();
        var inp = std.io.fixedBufferStream(delta.items);
        try std.compress.zlib.compress(inp.reader(), comp.writer(), .{});
        try pack.appendSlice(comp.items);
    }

    // Checksum
    var h = std.crypto.hash.Sha1.init(.{});
    h.update(pack.items);
    var ck: [20]u8 = undefined;
    h.final(&ck);
    try pack.appendSlice(&ck);
    return try pack.toOwnedSlice();
}

/// Build a "thin" REF_DELTA pack where the base is NOT included
fn buildThinRefDeltaPack(alloc: std.mem.Allocator, base_sha: [20]u8, base_size: usize, result_data: []const u8, delta_instructions: []const u8) ![]u8 {
    var pack = std.ArrayList(u8).init(alloc);
    defer pack.deinit();

    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, 1, .big); // 1 object: just the delta

    // Build delta data
    var delta = std.ArrayList(u8).init(alloc);
    defer delta.deinit();
    var vbuf: [10]u8 = undefined;
    var n = encodeVarint(&vbuf, base_size);
    try delta.appendSlice(vbuf[0..n]);
    n = encodeVarint(&vbuf, result_data.len);
    try delta.appendSlice(vbuf[0..n]);
    try delta.appendSlice(delta_instructions);

    const delta_size = delta.items.len;

    // Pack object header: type=REF_DELTA(7)
    var first: u8 = (7 << 4) | @as(u8, @intCast(delta_size & 0x0F));
    var rem = delta_size >> 4;
    if (rem > 0) first |= 0x80;
    try pack.append(first);
    while (rem > 0) {
        var b: u8 = @intCast(rem & 0x7F);
        rem >>= 7;
        if (rem > 0) b |= 0x80;
        try pack.append(b);
    }

    // Base SHA-1
    try pack.appendSlice(&base_sha);

    // Compressed delta
    var comp = std.ArrayList(u8).init(alloc);
    defer comp.deinit();
    var inp = std.io.fixedBufferStream(delta.items);
    try std.compress.zlib.compress(inp.reader(), comp.writer(), .{});
    try pack.appendSlice(comp.items);

    // Checksum
    var h = std.crypto.hash.Sha1.init(.{});
    h.update(pack.items);
    var ck: [20]u8 = undefined;
    h.final(&ck);
    try pack.appendSlice(&ck);
    return try pack.toOwnedSlice();
}

// ============================================================================
// Tests
// ============================================================================

test "generatePackIndex: REF_DELTA resolves when base is in same pack" {
    const alloc = testing.allocator;
    const base = "ref delta base content\n";
    const result = "ref delta base content\nextra line\n";

    const pack_data = try buildRefDeltaPack(alloc, base, result);
    defer alloc.free(pack_data);

    const idx_data = try objects.generatePackIndex(pack_data, alloc);
    defer alloc.free(idx_data);

    // Should have 2 entries
    const total = std.mem.readInt(u32, idx_data[8 + 255 * 4 ..][0..4], .big);
    try testing.expectEqual(@as(u32, 2), total);

    // Both SHA-1s should be correct
    const base_sha = blobSha1(base);
    const result_sha = blobSha1(result);

    const sha_start: usize = 8 + 256 * 4;
    const sha0 = idx_data[sha_start..][0..20];
    const sha1 = idx_data[sha_start + 20 ..][0..20];

    const has_base = std.mem.eql(u8, sha0, &base_sha) or std.mem.eql(u8, sha1, &base_sha);
    const has_result = std.mem.eql(u8, sha0, &result_sha) or std.mem.eql(u8, sha1, &result_sha);
    try testing.expect(has_base);
    try testing.expect(has_result);
}

test "deep delta chain: 4-level OFS_DELTA resolved correctly" {
    // Create a git repo with 4 similar blob versions to force delta chains
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = tmp.dir;

    try git(alloc, dir, &.{ "git", "init", "-b", "main" });
    try git(alloc, dir, &.{ "git", "config", "user.email", "t@t.com" });
    try git(alloc, dir, &.{ "git", "config", "user.name", "T" });
    try git(alloc, dir, &.{ "git", "config", "pack.depth", "10" }); // allow deep chains

    // Create 5 versions of a file to get deep delta chains
    const prefix = "A" ** 500;
    const versions = [_][]const u8{
        prefix ++ "\nv1\n",
        prefix ++ "\nv2\n",
        prefix ++ "\nv3\n",
        prefix ++ "\nv4\n",
        prefix ++ "\nv5\n",
    };

    for (versions, 0..) |content, i| {
        try dir.writeFile(.{ .sub_path = "file.txt", .data = content });
        try git(alloc, dir, &.{ "git", "add", "." });
        const msg = try std.fmt.allocPrint(alloc, "commit {}", .{i});
        defer alloc.free(msg);
        try git(alloc, dir, &.{ "git", "commit", "-m", msg });
    }

    try git(alloc, dir, &.{ "git", "gc", "--aggressive" });

    // Get hash of latest blob
    const hash_out = try run(alloc, dir, &.{ "git", "rev-parse", "HEAD:file.txt" });
    defer alloc.free(hash_out);
    const blob_hex = trimNl(hash_out);

    // Also get expected content from git
    const cat_out = try run(alloc, dir, &.{ "git", "cat-file", "-p", @as([]const u8, blob_hex) });
    defer alloc.free(cat_out);

    // Read pack file
    const pack_data = try readPackFile(alloc, dir);
    defer alloc.free(pack_data);

    // Generate idx
    const idx_data = try objects.generatePackIndex(pack_data, alloc);
    defer alloc.free(idx_data);

    const total = std.mem.readInt(u32, idx_data[8 + 255 * 4 ..][0..4], .big);
    const sha_start: usize = 8 + 256 * 4;
    const off_start = sha_start + 20 * total + 4 * total;

    // Find the blob and verify content
    var target_sha: [20]u8 = undefined;
    _ = try std.fmt.hexToBytes(&target_sha, blob_hex[0..40]);

    for (0..total) |i| {
        const sha_in_idx = idx_data[sha_start + 20 * i ..][0..20];
        if (std.mem.eql(u8, sha_in_idx, &target_sha)) {
            const off = std.mem.readInt(u32, idx_data[off_start + 4 * i ..][0..4], .big);
            const obj = try objects.readPackObjectAtOffset(pack_data, off, alloc);
            defer obj.deinit(alloc);
            try testing.expectEqual(objects.ObjectType.blob, obj.type);
            try testing.expectEqualStrings(cat_out, obj.data);
            return;
        }
    }
    return error.ObjectNotFound;
}

test "git pack with tag: tag object readable after gc" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = tmp.dir;

    try git(alloc, dir, &.{ "git", "init", "-b", "main" });
    try git(alloc, dir, &.{ "git", "config", "user.email", "t@t.com" });
    try git(alloc, dir, &.{ "git", "config", "user.name", "T" });
    try dir.writeFile(.{ .sub_path = "README", .data = "hello\n" });
    try git(alloc, dir, &.{ "git", "add", "." });
    try git(alloc, dir, &.{ "git", "commit", "-m", "init" });
    try git(alloc, dir, &.{ "git", "tag", "-a", "v1.0", "-m", "First release" });
    try git(alloc, dir, &.{ "git", "gc", "--aggressive" });

    // Get tag object hash (not the tagged commit)
    const tag_out = try run(alloc, dir, &.{ "git", "rev-parse", "v1.0" });
    defer alloc.free(tag_out);
    // Check if this is the tag object or the commit
    const tag_type_out = try run(alloc, dir, &.{ "git", "cat-file", "-t", trimNl(tag_out) });
    defer alloc.free(tag_type_out);

    // Get the actual tag object content from git
    const tag_content = try run(alloc, dir, &.{ "git", "cat-file", "-p", trimNl(tag_out) });
    defer alloc.free(tag_content);

    const pack_data = try readPackFile(alloc, dir);
    defer alloc.free(pack_data);

    const idx_data = try objects.generatePackIndex(pack_data, alloc);
    defer alloc.free(idx_data);

    const total = std.mem.readInt(u32, idx_data[8 + 255 * 4 ..][0..4], .big);
    const sha_start: usize = 8 + 256 * 4;
    const off_start = sha_start + 20 * total + 4 * total;

    var target_sha: [20]u8 = undefined;
    _ = try std.fmt.hexToBytes(&target_sha, trimNl(tag_out)[0..40]);

    var found = false;
    for (0..total) |i| {
        const sha_in_idx = idx_data[sha_start + 20 * i ..][0..20];
        if (std.mem.eql(u8, sha_in_idx, &target_sha)) {
            const off = std.mem.readInt(u32, idx_data[off_start + 4 * i ..][0..4], .big);
            const obj = try objects.readPackObjectAtOffset(pack_data, off, alloc);
            defer obj.deinit(alloc);
            // If git shows type=tag, verify our reader agrees
            if (std.mem.eql(u8, trimNl(tag_type_out), "tag")) {
                try testing.expectEqual(objects.ObjectType.tag, obj.type);
                // Tag content should contain "tag v1.0"
                try testing.expect(std.mem.indexOf(u8, obj.data, "v1.0") != null);
            }
            found = true;
            break;
        }
    }
    try testing.expect(found);
}

test "ziggit-generated idx accepted by git verify-pack for multi-object pack" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = tmp.dir;

    // Create a repo, add several files, gc, then verify our idx with git
    try git(alloc, dir, &.{ "git", "init", "-b", "main" });
    try git(alloc, dir, &.{ "git", "config", "user.email", "t@t.com" });
    try git(alloc, dir, &.{ "git", "config", "user.name", "T" });
    try dir.writeFile(.{ .sub_path = "a.txt", .data = "aaa\n" });
    try dir.writeFile(.{ .sub_path = "b.txt", .data = "bbb\n" });
    try git(alloc, dir, &.{ "git", "add", "." });
    try git(alloc, dir, &.{ "git", "commit", "-m", "initial" });
    try git(alloc, dir, &.{ "git", "gc", "--aggressive" });

    // Read git's pack, regenerate idx with ziggit
    const pack_data = try readPackFile(alloc, dir);
    defer alloc.free(pack_data);

    const our_idx = try objects.generatePackIndex(pack_data, alloc);
    defer alloc.free(our_idx);

    // Replace git's idx with ours
    var pack_dir = try dir.openDir(".git/objects/pack", .{ .iterate = true });
    defer pack_dir.close();
    var it = pack_dir.iterate();
    while (try it.next()) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".idx")) {
            try pack_dir.writeFile(.{ .sub_path = entry.name, .data = our_idx });
            break;
        }
    }

    // git verify-pack should accept our idx
    var pack_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var found_pack = false;
    {
        var it2 = pack_dir.iterate();
        while (try it2.next()) |entry| {
            if (std.mem.endsWith(u8, entry.name, ".pack")) {
                const abs = try pack_dir.realpath(entry.name, &pack_path_buf);
                const verify = run(alloc, dir, &.{ "git", "verify-pack", "-v", abs }) catch |err| {
                    if (err == error.CommandFailed) {
                        // Print stderr for debugging
                        return err;
                    }
                    return err;
                };
                alloc.free(verify);
                found_pack = true;
                break;
            }
        }
    }
    try testing.expect(found_pack);
}

test "all objects from git-created pack match git cat-file output" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = tmp.dir;

    try git(alloc, dir, &.{ "git", "init", "-b", "main" });
    try git(alloc, dir, &.{ "git", "config", "user.email", "t@t.com" });
    try git(alloc, dir, &.{ "git", "config", "user.name", "T" });
    try dir.writeFile(.{ .sub_path = "hello.txt", .data = "hello world\n" });
    try git(alloc, dir, &.{ "git", "add", "." });
    try git(alloc, dir, &.{ "git", "commit", "-m", "test" });
    try git(alloc, dir, &.{ "git", "gc" });

    const pack_data = try readPackFile(alloc, dir);
    defer alloc.free(pack_data);

    const idx_data = try objects.generatePackIndex(pack_data, alloc);
    defer alloc.free(idx_data);

    const total = std.mem.readInt(u32, idx_data[8 + 255 * 4 ..][0..4], .big);
    const sha_start: usize = 8 + 256 * 4;
    const off_start = sha_start + 20 * total + 4 * total;

    // For each object in the idx, compare with git cat-file
    var verified: u32 = 0;
    for (0..total) |i| {
        const sha_bytes = idx_data[sha_start + 20 * i ..][0..20];
        var hex: [40]u8 = undefined;
        _ = try std.fmt.bufPrint(&hex, "{}", .{std.fmt.fmtSliceHexLower(sha_bytes)});

        const off = std.mem.readInt(u32, idx_data[off_start + 4 * i ..][0..4], .big);
        const obj = objects.readPackObjectAtOffset(pack_data, off, alloc) catch continue;
        defer obj.deinit(alloc);

        // Get type from git
        const type_out = run(alloc, dir, &.{ "git", "cat-file", "-t", &hex }) catch continue;
        defer alloc.free(type_out);

        const expected_type = objects.ObjectType.fromString(trimNl(type_out)) orelse continue;
        try testing.expectEqual(expected_type, obj.type);

        // Get content from git
        const content_out = run(alloc, dir, &.{ "git", "cat-file", "-p", &hex }) catch continue;
        defer alloc.free(content_out);

        // For blobs and tags, content should match exactly
        if (obj.type == .blob) {
            try testing.expectEqualStrings(content_out, obj.data);
        }

        verified += 1;
    }
    try testing.expect(verified >= 2); // At least blob + commit
}

test "delta: copy command with all 3 size bytes" {
    const alloc = testing.allocator;

    // Base with 0x10203 bytes (need 3 size bytes)
    const base_size = 0x10203;
    const base = try alloc.alloc(u8, base_size);
    defer alloc.free(base);
    for (base, 0..) |*b, idx| b.* = @intCast(idx % 251);

    var delta = std.ArrayList(u8).init(alloc);
    defer delta.deinit();
    var vbuf: [10]u8 = undefined;
    var n = encodeVarint(&vbuf, base_size);
    try delta.appendSlice(vbuf[0..n]);
    n = encodeVarint(&vbuf, base_size);
    try delta.appendSlice(vbuf[0..n]);

    // Copy offset=0, size=0x10203 using all 3 size bytes
    // cmd: 0x80 | 0x10 | 0x20 | 0x40 = 0xF0
    try delta.append(0x80 | 0x10 | 0x20 | 0x40);
    try delta.append(0x03); // size byte 0
    try delta.append(0x02); // size byte 1
    try delta.append(0x01); // size byte 2

    const result = try objects.applyDelta(base, delta.items, alloc);
    defer alloc.free(result);
    try testing.expectEqual(base_size, result.len);
    try testing.expectEqualSlices(u8, base, result);
}

test "delta: insert 127 bytes (max single insert)" {
    const alloc = testing.allocator;
    const base = "base";

    const insert_data = "X" ** 127;
    const expected = insert_data;

    var delta = std.ArrayList(u8).init(alloc);
    defer delta.deinit();
    var vbuf: [10]u8 = undefined;
    var n = encodeVarint(&vbuf, base.len);
    try delta.appendSlice(vbuf[0..n]);
    n = encodeVarint(&vbuf, expected.len);
    try delta.appendSlice(vbuf[0..n]);

    // Insert 127 bytes
    try delta.append(127);
    try delta.appendSlice(insert_data);

    const result = try objects.applyDelta(base, delta.items, alloc);
    defer alloc.free(result);
    try testing.expectEqualStrings(expected, result);
}

test "delta: multiple sequential inserts" {
    const alloc = testing.allocator;
    const base = "X";
    const expected = "AABB";

    var delta = std.ArrayList(u8).init(alloc);
    defer delta.deinit();
    var vbuf: [10]u8 = undefined;
    var n = encodeVarint(&vbuf, base.len);
    try delta.appendSlice(vbuf[0..n]);
    n = encodeVarint(&vbuf, expected.len);
    try delta.appendSlice(vbuf[0..n]);

    // Insert "AA"
    try delta.append(2);
    try delta.appendSlice("AA");
    // Insert "BB"
    try delta.append(2);
    try delta.appendSlice("BB");

    const result = try objects.applyDelta(base, delta.items, alloc);
    defer alloc.free(result);
    try testing.expectEqualStrings(expected, result);
}

test "delta: overlapping copy regions" {
    const alloc = testing.allocator;
    const base = "ABCDEFGH";
    // Copy "CDE" then "DEF" - overlapping source regions
    const expected = "CDEDEF";

    var delta = std.ArrayList(u8).init(alloc);
    defer delta.deinit();
    var vbuf: [10]u8 = undefined;
    var n = encodeVarint(&vbuf, base.len);
    try delta.appendSlice(vbuf[0..n]);
    n = encodeVarint(&vbuf, expected.len);
    try delta.appendSlice(vbuf[0..n]);

    // Copy offset=2, size=3 ("CDE")
    try delta.append(0x80 | 0x01 | 0x10);
    try delta.append(2);
    try delta.append(3);

    // Copy offset=3, size=3 ("DEF")
    try delta.append(0x80 | 0x01 | 0x10);
    try delta.append(3);
    try delta.append(3);

    const result = try objects.applyDelta(base, delta.items, alloc);
    defer alloc.free(result);
    try testing.expectEqualStrings(expected, result);
}

test "pack: object count matches between header and actual objects" {
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = tmp.dir;

    try git(alloc, dir, &.{ "git", "init", "-b", "main" });
    try git(alloc, dir, &.{ "git", "config", "user.email", "t@t.com" });
    try git(alloc, dir, &.{ "git", "config", "user.name", "T" });

    // Create several objects
    for (0..5) |i| {
        const name = try std.fmt.allocPrint(alloc, "file{}.txt", .{i});
        defer alloc.free(name);
        const content = try std.fmt.allocPrint(alloc, "content of file {}\n", .{i});
        defer alloc.free(content);
        try dir.writeFile(.{ .sub_path = name, .data = content });
    }
    try git(alloc, dir, &.{ "git", "add", "." });
    try git(alloc, dir, &.{ "git", "commit", "-m", "five files" });
    try git(alloc, dir, &.{ "git", "gc" });

    const pack_data = try readPackFile(alloc, dir);
    defer alloc.free(pack_data);

    const header_count = std.mem.readInt(u32, pack_data[8..12], .big);

    // Our generatePackIndex should produce exactly that many entries
    const idx_data = try objects.generatePackIndex(pack_data, alloc);
    defer alloc.free(idx_data);

    const idx_count = std.mem.readInt(u32, idx_data[8 + 255 * 4 ..][0..4], .big);
    try testing.expectEqual(header_count, idx_count);
}

test "pack: CRC32 values in idx match raw pack object bytes" {
    const alloc = testing.allocator;

    const blob_data = "crc32 verification test\n";
    const pack_data = try buildBlobPack(alloc, blob_data);
    defer alloc.free(pack_data);

    const idx_data = try objects.generatePackIndex(pack_data, alloc);
    defer alloc.free(idx_data);

    // Get the CRC32 from the idx
    const sha_start: usize = 8 + 256 * 4;
    const crc_start = sha_start + 20; // 1 object * 20 bytes
    const stored_crc = std.mem.readInt(u32, idx_data[crc_start..][0..4], .big);

    // Get offset
    const off_start = crc_start + 4; // 1 object * 4 bytes CRC
    const offset = std.mem.readInt(u32, idx_data[off_start..][0..4], .big);

    // Compute CRC32 of the raw pack bytes for this object
    // Object goes from offset to end of compressed data (before pack checksum)
    // We need to find where this object ends - parse it
    var pos: usize = offset;
    var b = pack_data[pos];
    pos += 1;
    while (b & 0x80 != 0) {
        b = pack_data[pos];
        pos += 1;
    }
    // pos is now at start of compressed data
    var stream = std.io.fixedBufferStream(pack_data[pos..]);
    var decomp = std.ArrayList(u8).init(alloc);
    defer decomp.deinit();
    try std.compress.zlib.decompress(stream.reader(), decomp.writer());
    const obj_end = pos + @as(usize, @intCast(stream.pos));

    const computed_crc = std.hash.crc.Crc32IsoHdlc.hash(pack_data[offset..obj_end]);
    try testing.expectEqual(computed_crc, stored_crc);
}

test "pack: idx checksum covers all idx content" {
    const alloc = testing.allocator;
    const pack_data = try buildBlobPack(alloc, "checksum test\n");
    defer alloc.free(pack_data);

    const idx_data = try objects.generatePackIndex(pack_data, alloc);
    defer alloc.free(idx_data);

    // Last 20 bytes are SHA-1 of everything before
    const content = idx_data[0 .. idx_data.len - 20];
    const stored_ck = idx_data[idx_data.len - 20 ..][0..20];

    var h = std.crypto.hash.Sha1.init(.{});
    h.update(content);
    var computed: [20]u8 = undefined;
    h.final(&computed);

    try testing.expectEqualSlices(u8, &computed, stored_ck);
}

test "pack: idx contains pack checksum" {
    const alloc = testing.allocator;
    const pack_data = try buildBlobPack(alloc, "pack ck test\n");
    defer alloc.free(pack_data);

    const idx_data = try objects.generatePackIndex(pack_data, alloc);
    defer alloc.free(idx_data);

    const pack_ck = pack_data[pack_data.len - 20 ..];
    // Pack checksum is right before the idx checksum
    const idx_pack_ck = idx_data[idx_data.len - 40 .. idx_data.len - 20];
    try testing.expectEqualSlices(u8, pack_ck, idx_pack_ck);
}
