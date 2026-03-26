const std = @import("std");
const pack_writer = @import("pack_writer");
const idx_writer = @import("idx_writer");
const clone = @import("clone");

// ============================================================================
// Helper utilities
// ============================================================================

const PackObject = struct {
    type_str: []const u8,
    data: []const u8,
};

fn buildPackFile(allocator: std.mem.Allocator, objects: []const PackObject) ![]u8 {
    var pack = std.ArrayList(u8).init(allocator);
    errdefer pack.deinit();

    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, @intCast(objects.len), .big);

    for (objects) |obj| {
        const obj_type: u3 = if (std.mem.eql(u8, obj.type_str, "commit"))
            1
        else if (std.mem.eql(u8, obj.type_str, "tree"))
            2
        else if (std.mem.eql(u8, obj.type_str, "blob"))
            3
        else if (std.mem.eql(u8, obj.type_str, "tag"))
            4
        else
            unreachable;

        var size = obj.data.len;
        var first_byte: u8 = (@as(u8, obj_type) << 4) | @as(u8, @intCast(size & 0x0F));
        size >>= 4;
        if (size > 0) first_byte |= 0x80;
        try pack.append(first_byte);
        while (size > 0) {
            var b: u8 = @intCast(size & 0x7F);
            size >>= 7;
            if (size > 0) b |= 0x80;
            try pack.append(b);
        }

        var compressed = std.ArrayList(u8).init(allocator);
        defer compressed.deinit();
        var compressor = try std.compress.zlib.compressor(compressed.writer(), .{});
        try compressor.writer().writeAll(obj.data);
        try compressor.finish();
        try pack.appendSlice(compressed.items);
    }

    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack.items);
    var checksum: [20]u8 = undefined;
    hasher.final(&checksum);
    try pack.appendSlice(&checksum);
    return pack.toOwnedSlice();
}

fn setupTmpDir() ![]const u8 {
    const allocator = std.testing.allocator;
    const tmp = try std.fmt.allocPrint(allocator, "/tmp/ziggit_clone_test_{}", .{std.crypto.random.int(u64)});
    try std.fs.cwd().makePath(tmp);
    return tmp;
}

fn cleanupTmpDir(path: []const u8) void {
    std.fs.cwd().deleteTree(path) catch {};
    std.testing.allocator.free(path);
}

// ============================================================================
// createBareStructure tests
// ============================================================================

test "createBareStructure creates all required directories" {
    const tmp_dir = try setupTmpDir();
    defer cleanupTmpDir(tmp_dir);

    const allocator = std.testing.allocator;
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/test.git", .{tmp_dir});
    defer allocator.free(git_dir);

    try clone.createBareStructure(git_dir);

    // Check all expected directories exist
    const expected_dirs = [_][]const u8{
        "/objects",
        "/objects/pack",
        "/refs",
        "/refs/heads",
        "/refs/tags",
        "/refs/remotes",
        "/refs/remotes/origin",
    };

    for (expected_dirs) |suffix| {
        const path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ git_dir, suffix });
        defer allocator.free(path);
        const stat = std.fs.cwd().statFile(path) catch |err| {
            // Try as directory
            _ = std.fs.cwd().openDir(path, .{}) catch {
                std.debug.print("Missing directory: {s} (err: {})\n", .{ path, err });
                return error.MissingDirectory;
            };
            continue;
        };
        _ = stat;
    }

    // Check HEAD file
    const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_dir});
    defer allocator.free(head_path);
    const head_content = try std.fs.cwd().readFileAlloc(allocator, head_path, 256);
    defer allocator.free(head_content);
    try std.testing.expectEqualStrings("ref: refs/heads/main\n", head_content);
}

// ============================================================================
// writeRemoteConfig tests
// ============================================================================

test "writeRemoteConfig creates valid config file" {
    const allocator = std.testing.allocator;
    const tmp_dir = try setupTmpDir();
    defer cleanupTmpDir(tmp_dir);

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/test.git", .{tmp_dir});
    defer allocator.free(git_dir);
    try std.fs.cwd().makePath(git_dir);

    try clone.writeRemoteConfig(allocator, git_dir, "https://github.com/example/repo.git");

    const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{git_dir});
    defer allocator.free(config_path);
    const content = try std.fs.cwd().readFileAlloc(allocator, config_path, 4096);
    defer allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "https://github.com/example/repo.git") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "[remote \"origin\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "fetch = +refs/heads/*:refs/remotes/origin/*") != null);
}

// ============================================================================
// Simulated clone workflow (no network)
// ============================================================================

test "simulated bare clone: save pack + generate idx + update refs" {
    const allocator = std.testing.allocator;
    const tmp_dir = try setupTmpDir();
    defer cleanupTmpDir(tmp_dir);

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/clone.git", .{tmp_dir});
    defer allocator.free(git_dir);

    // 1. Create bare structure
    try clone.createBareStructure(git_dir);

    // 2. Build pack data (simulating what smart HTTP would return)
    const blob_data = "Hello from remote!\n";
    const tree_data = "100644 hello.txt\x00" ++ "\x00" ** 20;
    const commit_data =
        "tree 4b825dc642cb6eb9a060e54bf899d69f82063700\n" ++
        "author Tester <t@t.com> 1700000000 +0000\n" ++
        "committer Tester <t@t.com> 1700000000 +0000\n" ++
        "\nInitial commit\n";

    const objects = [_]PackObject{
        .{ .type_str = "blob", .data = blob_data },
        .{ .type_str = "tree", .data = tree_data },
        .{ .type_str = "commit", .data = commit_data },
    };
    const pack_data = try buildPackFile(allocator, &objects);
    defer allocator.free(pack_data);

    // 3. Save pack
    const checksum = try pack_writer.savePackFast(allocator, git_dir, pack_data);
    defer allocator.free(checksum);

    // 4. Generate idx
    const pp = try pack_writer.packPath(allocator, git_dir, checksum);
    defer allocator.free(pp);
    try idx_writer.generateIdx(allocator, pp);

    // 5. Update refs (bare)
    const ref_updates = [_]pack_writer.RefUpdate{
        .{ .name = "refs/heads/main", .hash = "abcdef0123456789abcdef0123456789abcdef01" },
    };
    try pack_writer.updateRefsAfterClone(allocator, git_dir, &ref_updates, true);

    // Verify: pack file exists
    const pack_stat = try std.fs.cwd().statFile(pp);
    try std.testing.expect(pack_stat.size > 0);

    // Verify: idx file exists
    const ip = try pack_writer.idxPath(allocator, git_dir, checksum);
    defer allocator.free(ip);
    const idx_stat = try std.fs.cwd().statFile(ip);
    try std.testing.expect(idx_stat.size > 0);

    // Verify: HEAD exists
    const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_dir});
    defer allocator.free(head_path);
    const head = try std.fs.cwd().readFileAlloc(allocator, head_path, 256);
    defer allocator.free(head);
    try std.testing.expectEqualStrings("ref: refs/heads/main\n", head);

    // Verify: ref file exists
    const ref_path = try std.fmt.allocPrint(allocator, "{s}/refs/heads/main", .{git_dir});
    defer allocator.free(ref_path);
    const ref_content = try std.fs.cwd().readFileAlloc(allocator, ref_path, 256);
    defer allocator.free(ref_content);
    const trimmed = std.mem.trimRight(u8, ref_content, "\n");
    try std.testing.expectEqualStrings("abcdef0123456789abcdef0123456789abcdef01", trimmed);
}

test "simulated non-bare clone: refs go to remotes/origin" {
    const allocator = std.testing.allocator;
    const tmp_dir = try setupTmpDir();
    defer cleanupTmpDir(tmp_dir);

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/repo/.git", .{tmp_dir});
    defer allocator.free(git_dir);

    // 1. Create structure
    try clone.createBareStructure(git_dir);
    try clone.writeRemoteConfig(allocator, git_dir, "https://example.com/repo.git");

    // 2. Build and save pack
    const objects = [_]PackObject{
        .{ .type_str = "blob", .data = "content\n" },
    };
    const pack_data = try buildPackFile(allocator, &objects);
    defer allocator.free(pack_data);

    const checksum = try pack_writer.savePackFast(allocator, git_dir, pack_data);
    defer allocator.free(checksum);

    const pp = try pack_writer.packPath(allocator, git_dir, checksum);
    defer allocator.free(pp);
    try idx_writer.generateIdx(allocator, pp);

    // 3. Update refs (non-bare)
    const ref_updates = [_]pack_writer.RefUpdate{
        .{ .name = "refs/heads/main", .hash = "1234567890123456789012345678901234567890" },
    };
    try pack_writer.updateRefsAfterClone(allocator, git_dir, &ref_updates, false);

    // Verify: remotes/origin/main exists
    const remote_ref_path = try std.fmt.allocPrint(allocator, "{s}/refs/remotes/origin/main", .{git_dir});
    defer allocator.free(remote_ref_path);
    const content = try std.fs.cwd().readFileAlloc(allocator, remote_ref_path, 256);
    defer allocator.free(content);
    const trimmed = std.mem.trimRight(u8, content, "\n");
    try std.testing.expectEqualStrings("1234567890123456789012345678901234567890", trimmed);

    // Verify: config has remote origin
    const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{git_dir});
    defer allocator.free(config_path);
    const config = try std.fs.cwd().readFileAlloc(allocator, config_path, 4096);
    defer allocator.free(config);
    try std.testing.expect(std.mem.indexOf(u8, config, "https://example.com/repo.git") != null);
}

test "simulated fetch: updates remote refs and FETCH_HEAD" {
    const allocator = std.testing.allocator;
    const tmp_dir = try setupTmpDir();
    defer cleanupTmpDir(tmp_dir);

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/repo/.git", .{tmp_dir});
    defer allocator.free(git_dir);

    // Setup existing repo
    try clone.createBareStructure(git_dir);

    // Write an existing remote ref
    {
        const path = try std.fmt.allocPrint(allocator, "{s}/refs/remotes/origin/main", .{git_dir});
        defer allocator.free(path);
        const f = try std.fs.cwd().createFile(path, .{});
        defer f.close();
        try f.writeAll("0000000000000000000000000000000000000000\n");
    }

    // Simulate fetch: save new pack
    const objects = [_]PackObject{
        .{ .type_str = "blob", .data = "new content\n" },
    };
    const pack_data = try buildPackFile(allocator, &objects);
    defer allocator.free(pack_data);

    const checksum = try pack_writer.savePackFast(allocator, git_dir, pack_data);
    defer allocator.free(checksum);
    const pp = try pack_writer.packPath(allocator, git_dir, checksum);
    defer allocator.free(pp);
    try idx_writer.generateIdx(allocator, pp);

    // Update refs after fetch
    const ref_updates = [_]pack_writer.RefUpdate{
        .{ .name = "refs/heads/main", .hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" },
        .{ .name = "refs/heads/develop", .hash = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" },
    };
    try pack_writer.updateRefsAfterFetch(allocator, git_dir, &ref_updates);

    // Verify remote refs updated
    {
        const path = try std.fmt.allocPrint(allocator, "{s}/refs/remotes/origin/main", .{git_dir});
        defer allocator.free(path);
        const content = try std.fs.cwd().readFileAlloc(allocator, path, 256);
        defer allocator.free(content);
        const trimmed = std.mem.trimRight(u8, content, "\n");
        try std.testing.expectEqualStrings("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", trimmed);
    }
    {
        const path = try std.fmt.allocPrint(allocator, "{s}/refs/remotes/origin/develop", .{git_dir});
        defer allocator.free(path);
        const content = try std.fs.cwd().readFileAlloc(allocator, path, 256);
        defer allocator.free(content);
        const trimmed = std.mem.trimRight(u8, content, "\n");
        try std.testing.expectEqualStrings("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", trimmed);
    }

    // Verify FETCH_HEAD
    {
        const path = try std.fmt.allocPrint(allocator, "{s}/FETCH_HEAD", .{git_dir});
        defer allocator.free(path);
        const content = try std.fs.cwd().readFileAlloc(allocator, path, 4096);
        defer allocator.free(content);
        try std.testing.expect(std.mem.indexOf(u8, content, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") != null);
    }
}

test "git fsck validates bare clone structure" {
    const allocator = std.testing.allocator;
    const tmp_dir = try setupTmpDir();
    defer cleanupTmpDir(tmp_dir);

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/bare.git", .{tmp_dir});
    defer allocator.free(git_dir);

    // Create bare structure
    try clone.createBareStructure(git_dir);

    // Build a valid pack with a blob
    const objects = [_]PackObject{
        .{ .type_str = "blob", .data = "fsck test content\n" },
    };
    const pack_data = try buildPackFile(allocator, &objects);
    defer allocator.free(pack_data);

    const checksum = try pack_writer.savePack(allocator, git_dir, pack_data);
    defer allocator.free(checksum);
    const pp = try pack_writer.packPath(allocator, git_dir, checksum);
    defer allocator.free(pp);
    try idx_writer.generateIdx(allocator, pp);

    // git fsck should not error on the pack/idx
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "--git-dir", git_dir, "verify-pack", "-v", pp },
        .max_output_bytes = 10 * 1024 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try std.testing.expectEqual(@as(u8, 0), result.term.Exited);
}
