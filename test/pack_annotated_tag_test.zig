const std = @import("std");
const idx_writer = @import("idx_writer");
const pack_writer = @import("pack_writer");

// ============================================================================
// Tests for pack files containing annotated tag objects
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

fn appendPackChecksum(pack: *std.ArrayList(u8)) !void {
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack.items);
    var cksum: [20]u8 = undefined;
    hasher.final(&cksum);
    try pack.appendSlice(&cksum);
}

fn gitHashObject(type_str: []const u8, data: []const u8) [20]u8 {
    var hasher = std.crypto.hash.Sha1.init(.{});
    var hdr_buf: [64]u8 = undefined;
    const header = std.fmt.bufPrint(&hdr_buf, "{s} {}\x00", .{ type_str, data.len }) catch unreachable;
    hasher.update(header);
    hasher.update(data);
    var sha: [20]u8 = undefined;
    hasher.final(&sha);
    return sha;
}

fn setupTmpDir() ![]const u8 {
    const allocator = std.testing.allocator;
    const tmp = try std.fmt.allocPrint(allocator, "/tmp/ziggit_atag_{}", .{std.crypto.random.int(u64)});
    try std.fs.cwd().makePath(tmp);
    return tmp;
}

fn cleanupTmpDir(path: []const u8) void {
    std.fs.cwd().deleteTree(path) catch {};
    std.testing.allocator.free(path);
}

// ============================================================================
// Annotated tag object in pack
// ============================================================================

test "pack with annotated tag object: SHA-1 correct" {
    const allocator = std.testing.allocator;

    const tag_data =
        "object 4b825dc642cb6eb9a060e54bf899d69f82063700\n" ++
        "type commit\n" ++
        "tag v1.0.0\n" ++
        "tagger Test <test@test.com> 1700000000 +0000\n" ++
        "\nRelease v1.0.0\n" ++
        "This is a multi-line tag message.\n";

    const expected_sha = gitHashObject("tag", tag_data);

    var pack = std.ArrayList(u8).init(allocator);
    defer pack.deinit();

    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, 1, .big);

    try encodePackHeader(&pack, 4, tag_data.len); // type=4 (tag)
    const comp = try compressData(allocator, tag_data);
    defer allocator.free(comp);
    try pack.appendSlice(comp);

    try appendPackChecksum(&pack);

    const idx_data = try idx_writer.generateIdxFromData(allocator, pack.items);
    defer allocator.free(idx_data);

    const fanout_end = 8 + 256 * 4;
    const total = std.mem.readInt(u32, idx_data[fanout_end - 4 ..][0..4], .big);
    try std.testing.expectEqual(@as(u32, 1), total);

    const sha = idx_data[fanout_end..][0..20];
    try std.testing.expectEqualSlices(u8, &expected_sha, sha);
}

test "git verify-pack accepts pack with tag object" {
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

    const tag_data =
        "object 4b825dc642cb6eb9a060e54bf899d69f82063700\n" ++
        "type commit\n" ++
        "tag v1.0.0\n" ++
        "tagger Test <test@test.com> 1700000000 +0000\n" ++
        "\nRelease v1.0.0\n";

    var pack = std.ArrayList(u8).init(allocator);
    defer pack.deinit();

    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, 1, .big);

    try encodePackHeader(&pack, 4, tag_data.len);
    const comp = try compressData(allocator, tag_data);
    defer allocator.free(comp);
    try pack.appendSlice(comp);
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
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "tag") != null);
}

// ============================================================================
// Full repo with annotated tags: git creates pack, we re-index
// ============================================================================

test "git repo with annotated tags: our idx works with git cat-file" {
    const allocator = std.testing.allocator;
    const tmp_dir = try setupTmpDir();
    defer cleanupTmpDir(tmp_dir);

    const src_dir = try std.fmt.allocPrint(allocator, "{s}/src", .{tmp_dir});
    defer allocator.free(src_dir);
    try std.fs.cwd().makePath(src_dir);

    const init_cmds = [_][]const u8{
        "git init",
        "git config user.email t@t.com",
        "git config user.name T",
    };
    for (init_cmds) |cmd| {
        const full = try std.fmt.allocPrint(allocator, "cd {s} && {s}", .{ src_dir, cmd });
        defer allocator.free(full);
        const r = try std.process.Child.run(.{ .allocator = allocator, .argv = &.{ "bash", "-c", full }, .max_output_bytes = 1024 * 1024 });
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }

    // Create a commit
    {
        const fp = try std.fmt.allocPrint(allocator, "{s}/readme.md", .{src_dir});
        defer allocator.free(fp);
        const f = try std.fs.cwd().createFile(fp, .{});
        defer f.close();
        try f.writeAll("# Hello\n");
    }
    {
        const cmd = try std.fmt.allocPrint(allocator, "cd {s} && git add -A && git commit -m 'init'", .{src_dir});
        defer allocator.free(cmd);
        const r = try std.process.Child.run(.{ .allocator = allocator, .argv = &.{ "bash", "-c", cmd }, .max_output_bytes = 1024 * 1024 });
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }

    // Create annotated tag
    {
        const cmd = try std.fmt.allocPrint(allocator, "cd {s} && git tag -a v1.0 -m 'Version 1.0 release'", .{src_dir});
        defer allocator.free(cmd);
        const r = try std.process.Child.run(.{ .allocator = allocator, .argv = &.{ "bash", "-c", cmd }, .max_output_bytes = 1024 * 1024 });
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }

    // Get the tag object hash
    const tag_hash_cmd = try std.fmt.allocPrint(allocator, "cd {s} && git rev-parse v1.0", .{src_dir});
    defer allocator.free(tag_hash_cmd);
    const tag_hash_r = try std.process.Child.run(.{ .allocator = allocator, .argv = &.{ "bash", "-c", tag_hash_cmd } });
    defer allocator.free(tag_hash_r.stdout);
    defer allocator.free(tag_hash_r.stderr);
    const tag_hash = std.mem.trimRight(u8, tag_hash_r.stdout, "\n\r ");

    // gc to create pack with tag object
    {
        const cmd = try std.fmt.allocPrint(allocator, "cd {s} && git gc", .{src_dir});
        defer allocator.free(cmd);
        const r = try std.process.Child.run(.{ .allocator = allocator, .argv = &.{ "bash", "-c", cmd }, .max_output_bytes = 1024 * 1024 });
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }

    // Find pack
    const pack_dir = try std.fmt.allocPrint(allocator, "{s}/.git/objects/pack", .{src_dir});
    defer allocator.free(pack_dir);
    var dir = try std.fs.cwd().openDir(pack_dir, .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    var pack_path: ?[]u8 = null;
    defer if (pack_path) |p| allocator.free(p);
    while (try it.next()) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".pack")) {
            pack_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pack_dir, entry.name });
            break;
        }
    }
    const pp = pack_path orelse return error.NoPackFileFound;

    // Read pack and re-index
    const pack_data = try std.fs.cwd().readFileAlloc(allocator, pp, 50 * 1024 * 1024);
    defer allocator.free(pack_data);

    const dst_dir = try std.fmt.allocPrint(allocator, "{s}/dst.git", .{tmp_dir});
    defer allocator.free(dst_dir);
    {
        const r = try std.process.Child.run(.{ .allocator = allocator, .argv = &.{ "git", "init", "--bare", dst_dir } });
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }

    const checksum = try pack_writer.savePack(allocator, dst_dir, pack_data);
    defer allocator.free(checksum);
    const dst_pack = try pack_writer.packPath(allocator, dst_dir, checksum);
    defer allocator.free(dst_pack);
    try idx_writer.generateIdx(allocator, dst_pack);

    // Set up refs including annotated tag
    const head_cmd = try std.fmt.allocPrint(allocator, "cd {s} && git rev-parse HEAD", .{src_dir});
    defer allocator.free(head_cmd);
    const head_r = try std.process.Child.run(.{ .allocator = allocator, .argv = &.{ "bash", "-c", head_cmd } });
    defer allocator.free(head_r.stdout);
    defer allocator.free(head_r.stderr);
    const head_hash = std.mem.trimRight(u8, head_r.stdout, "\n\r ");

    const refs = [_]pack_writer.RefUpdate{
        .{ .name = "refs/heads/master", .hash = head_hash },
        .{ .name = "refs/tags/v1.0", .hash = tag_hash },
    };
    try pack_writer.updateRefsAfterClone(allocator, dst_dir, &refs, true);

    // Verify: git cat-file can read the tag object
    const cat_r = try std.process.Child.run(.{
        .allocator = allocator,
        .max_output_bytes = 1024 * 1024,
        .argv = &.{ "git", "--git-dir", dst_dir, "cat-file", "-t", tag_hash },
    });
    defer allocator.free(cat_r.stdout);
    defer allocator.free(cat_r.stderr);
    try std.testing.expectEqual(@as(u8, 0), cat_r.term.Exited);
    try std.testing.expectEqualStrings("tag", std.mem.trimRight(u8, cat_r.stdout, "\n\r "));

    // git tag should list v1.0
    const tag_list = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "--git-dir", dst_dir, "tag", "--list" },
    });
    defer allocator.free(tag_list.stdout);
    defer allocator.free(tag_list.stderr);
    try std.testing.expectEqual(@as(u8, 0), tag_list.term.Exited);
    try std.testing.expect(std.mem.indexOf(u8, tag_list.stdout, "v1.0") != null);

    // git verify-pack should work
    const verify = try std.process.Child.run(.{
        .allocator = allocator,
        .max_output_bytes = 10 * 1024 * 1024,
        .argv = &.{ "git", "verify-pack", "-v", dst_pack },
    });
    defer allocator.free(verify.stdout);
    defer allocator.free(verify.stderr);
    try std.testing.expectEqual(@as(u8, 0), verify.term.Exited);
    try std.testing.expect(std.mem.indexOf(u8, verify.stdout, "tag") != null);
}
