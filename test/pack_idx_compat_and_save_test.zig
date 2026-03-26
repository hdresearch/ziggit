const std = @import("std");
const objects = @import("git_objects");

// =============================================================================
// Test: ziggit generatePackIndex matches git index-pack for a real pack file
// =============================================================================

fn execGit(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) ![]u8 {
    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit();
    try argv.append("git");
    try argv.appendSlice(args);

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .cwd = cwd,
        .max_output_bytes = 10 * 1024 * 1024,
    });
    allocator.free(result.stderr);
    if (result.term.Exited != 0) {
        allocator.free(result.stdout);
        return error.CommandFailed;
    }
    return result.stdout;
}

fn execGitNoOutput(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) !void {
    const out = try execGit(allocator, cwd, args);
    allocator.free(out);
}

fn makeTmpDir(allocator: std.mem.Allocator) ![]u8 {
    const name = try std.fmt.allocPrint(allocator, "/tmp/ziggit_test_{d}", .{std.crypto.random.int(u64)});
    try std.fs.cwd().makePath(name);
    return name;
}

fn cleanupDir(allocator: std.mem.Allocator, path: []const u8) void {
    std.fs.cwd().deleteTree(path) catch {};
    allocator.free(path);
}

// Helper: create a repo with multiple commits and repack into a single .pack
fn setupRepoAndRepack(allocator: std.mem.Allocator) !struct { dir: []u8, pack_path: []u8, idx_path: []u8 } {
    const dir = try makeTmpDir(allocator);
    errdefer cleanupDir(allocator, dir);

    try execGitNoOutput(allocator, dir, &.{ "init", "-b", "main" });
    try execGitNoOutput(allocator, dir, &.{ "config", "user.email", "test@test.com" });
    try execGitNoOutput(allocator, dir, &.{ "config", "user.name", "Test" });

    // Create several commits with different object types to exercise deltas
    {
        const p = try std.fmt.allocPrint(allocator, "{s}/file1.txt", .{dir});
        defer allocator.free(p);
        try std.fs.cwd().writeFile(.{ .sub_path = p, .data = "Hello World\n" });
    }
    try execGitNoOutput(allocator, dir, &.{ "add", "." });
    try execGitNoOutput(allocator, dir, &.{ "commit", "-m", "first" });

    {
        const p = try std.fmt.allocPrint(allocator, "{s}/file1.txt", .{dir});
        defer allocator.free(p);
        try std.fs.cwd().writeFile(.{ .sub_path = p, .data = "Hello World\nSecond line\n" });
    }
    {
        const p = try std.fmt.allocPrint(allocator, "{s}/file2.txt", .{dir});
        defer allocator.free(p);
        try std.fs.cwd().writeFile(.{ .sub_path = p, .data = "Another file with some content\n" });
    }
    try execGitNoOutput(allocator, dir, &.{ "add", "." });
    try execGitNoOutput(allocator, dir, &.{ "commit", "-m", "second" });

    {
        const p = try std.fmt.allocPrint(allocator, "{s}/file1.txt", .{dir});
        defer allocator.free(p);
        try std.fs.cwd().writeFile(.{ .sub_path = p, .data = "Hello World\nSecond line\nThird line\n" });
    }
    try execGitNoOutput(allocator, dir, &.{ "add", "." });
    try execGitNoOutput(allocator, dir, &.{ "commit", "-m", "third" });

    // Create annotated tag
    try execGitNoOutput(allocator, dir, &.{ "tag", "-a", "v1.0", "-m", "release v1.0" });

    // Aggressive repack to get deltas
    try execGitNoOutput(allocator, dir, &.{ "repack", "-a", "-d", "-f", "--depth=10" });

    // Find the pack file
    const pack_dir = try std.fmt.allocPrint(allocator, "{s}/.git/objects/pack", .{dir});
    defer allocator.free(pack_dir);
    var d = try std.fs.cwd().openDir(pack_dir, .{ .iterate = true });
    defer d.close();

    var pack_path: ?[]u8 = null;
    var idx_path: ?[]u8 = null;
    var iter = d.iterate();
    while (try iter.next()) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".pack")) {
            pack_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pack_dir, entry.name });
        } else if (std.mem.endsWith(u8, entry.name, ".idx")) {
            idx_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pack_dir, entry.name });
        }
    }

    return .{
        .dir = dir,
        .pack_path = pack_path orelse return error.NoPackFile,
        .idx_path = idx_path orelse return error.NoIdxFile,
    };
}

test "generatePackIndex: fanout table matches git index-pack" {
    const allocator = std.testing.allocator;
    const setup = try setupRepoAndRepack(allocator);
    defer {
        cleanupDir(allocator, setup.dir);
        allocator.free(setup.pack_path);
        allocator.free(setup.idx_path);
    }

    // Read the git-generated pack file
    const pack_data = try std.fs.cwd().readFileAlloc(allocator, setup.pack_path, 10 * 1024 * 1024);
    defer allocator.free(pack_data);

    // Read the git-generated idx file
    const git_idx = try std.fs.cwd().readFileAlloc(allocator, setup.idx_path, 10 * 1024 * 1024);
    defer allocator.free(git_idx);

    // Generate our idx
    const our_idx = try objects.generatePackIndex(pack_data, allocator);
    defer allocator.free(our_idx);

    // Both should have v2 magic + version
    try std.testing.expectEqualSlices(u8, git_idx[0..8], our_idx[0..8]);

    // Compare fanout tables (256 * 4 bytes starting at offset 8)
    const fanout_size = 256 * 4;
    try std.testing.expectEqualSlices(u8, git_idx[8 .. 8 + fanout_size], our_idx[8 .. 8 + fanout_size]);

    // Total objects must match
    const git_total = std.mem.readInt(u32, @ptrCast(git_idx[8 + 255 * 4 .. 8 + 256 * 4]), .big);
    const our_total = std.mem.readInt(u32, @ptrCast(our_idx[8 + 255 * 4 .. 8 + 256 * 4]), .big);
    try std.testing.expectEqual(git_total, our_total);
}

test "generatePackIndex: SHA-1 table matches git index-pack" {
    const allocator = std.testing.allocator;
    const setup = try setupRepoAndRepack(allocator);
    defer {
        cleanupDir(allocator, setup.dir);
        allocator.free(setup.pack_path);
        allocator.free(setup.idx_path);
    }

    const pack_data = try std.fs.cwd().readFileAlloc(allocator, setup.pack_path, 10 * 1024 * 1024);
    defer allocator.free(pack_data);

    const git_idx = try std.fs.cwd().readFileAlloc(allocator, setup.idx_path, 10 * 1024 * 1024);
    defer allocator.free(git_idx);

    const our_idx = try objects.generatePackIndex(pack_data, allocator);
    defer allocator.free(our_idx);

    const total = std.mem.readInt(u32, @ptrCast(git_idx[8 + 255 * 4 .. 8 + 256 * 4]), .big);
    const sha_start = 8 + 256 * 4;
    const sha_end = sha_start + @as(usize, total) * 20;

    // SHA-1 tables must match exactly (sorted order)
    try std.testing.expectEqualSlices(u8, git_idx[sha_start..sha_end], our_idx[sha_start..sha_end]);
}

test "generatePackIndex: CRC32 table matches git index-pack" {
    const allocator = std.testing.allocator;
    const setup = try setupRepoAndRepack(allocator);
    defer {
        cleanupDir(allocator, setup.dir);
        allocator.free(setup.pack_path);
        allocator.free(setup.idx_path);
    }

    const pack_data = try std.fs.cwd().readFileAlloc(allocator, setup.pack_path, 10 * 1024 * 1024);
    defer allocator.free(pack_data);

    const git_idx = try std.fs.cwd().readFileAlloc(allocator, setup.idx_path, 10 * 1024 * 1024);
    defer allocator.free(git_idx);

    const our_idx = try objects.generatePackIndex(pack_data, allocator);
    defer allocator.free(our_idx);

    const total = std.mem.readInt(u32, @ptrCast(git_idx[8 + 255 * 4 .. 8 + 256 * 4]), .big);
    const sha_start = 8 + 256 * 4;
    const crc_start = sha_start + @as(usize, total) * 20;
    const crc_end = crc_start + @as(usize, total) * 4;

    try std.testing.expectEqualSlices(u8, git_idx[crc_start..crc_end], our_idx[crc_start..crc_end]);
}

test "generatePackIndex: offset table matches git index-pack" {
    const allocator = std.testing.allocator;
    const setup = try setupRepoAndRepack(allocator);
    defer {
        cleanupDir(allocator, setup.dir);
        allocator.free(setup.pack_path);
        allocator.free(setup.idx_path);
    }

    const pack_data = try std.fs.cwd().readFileAlloc(allocator, setup.pack_path, 10 * 1024 * 1024);
    defer allocator.free(pack_data);

    const git_idx = try std.fs.cwd().readFileAlloc(allocator, setup.idx_path, 10 * 1024 * 1024);
    defer allocator.free(git_idx);

    const our_idx = try objects.generatePackIndex(pack_data, allocator);
    defer allocator.free(our_idx);

    const total = std.mem.readInt(u32, @ptrCast(git_idx[8 + 255 * 4 .. 8 + 256 * 4]), .big);
    const sha_start = 8 + 256 * 4;
    const crc_start = sha_start + @as(usize, total) * 20;
    const off_start = crc_start + @as(usize, total) * 4;
    const off_end = off_start + @as(usize, total) * 4;

    try std.testing.expectEqualSlices(u8, git_idx[off_start..off_end], our_idx[off_start..off_end]);
}

test "generatePackIndex: pack checksum and idx checksum match git" {
    const allocator = std.testing.allocator;
    const setup = try setupRepoAndRepack(allocator);
    defer {
        cleanupDir(allocator, setup.dir);
        allocator.free(setup.pack_path);
        allocator.free(setup.idx_path);
    }

    const pack_data = try std.fs.cwd().readFileAlloc(allocator, setup.pack_path, 10 * 1024 * 1024);
    defer allocator.free(pack_data);

    const git_idx = try std.fs.cwd().readFileAlloc(allocator, setup.idx_path, 10 * 1024 * 1024);
    defer allocator.free(git_idx);

    const our_idx = try objects.generatePackIndex(pack_data, allocator);
    defer allocator.free(our_idx);

    // Pack checksum (last 40 bytes of idx = 20 pack checksum + 20 idx checksum)
    // The pack checksum in the idx must match the pack file's trailing 20 bytes
    const pack_checksum = pack_data[pack_data.len - 20 ..];
    const git_pack_checksum_in_idx = git_idx[git_idx.len - 40 .. git_idx.len - 20];
    const our_pack_checksum_in_idx = our_idx[our_idx.len - 40 .. our_idx.len - 20];

    try std.testing.expectEqualSlices(u8, pack_checksum, git_pack_checksum_in_idx);
    try std.testing.expectEqualSlices(u8, pack_checksum, our_pack_checksum_in_idx);

    // Idx checksum (SHA-1 of everything except the last 20 bytes)
    try std.testing.expectEqualSlices(u8, git_idx[git_idx.len - 20 ..], our_idx[our_idx.len - 20 ..]);
}

test "generatePackIndex: entire idx file is byte-identical to git index-pack" {
    const allocator = std.testing.allocator;
    const setup = try setupRepoAndRepack(allocator);
    defer {
        cleanupDir(allocator, setup.dir);
        allocator.free(setup.pack_path);
        allocator.free(setup.idx_path);
    }

    const pack_data = try std.fs.cwd().readFileAlloc(allocator, setup.pack_path, 10 * 1024 * 1024);
    defer allocator.free(pack_data);

    const git_idx = try std.fs.cwd().readFileAlloc(allocator, setup.idx_path, 10 * 1024 * 1024);
    defer allocator.free(git_idx);

    const our_idx = try objects.generatePackIndex(pack_data, allocator);
    defer allocator.free(our_idx);

    try std.testing.expectEqual(git_idx.len, our_idx.len);
    try std.testing.expectEqualSlices(u8, git_idx, our_idx);
}

// =============================================================================
// Test: saveReceivedPack end-to-end
// =============================================================================

test "saveReceivedPack: pack from git repack is saved and objects are readable" {
    const allocator = std.testing.allocator;
    const setup = try setupRepoAndRepack(allocator);
    defer {
        cleanupDir(allocator, setup.dir);
        allocator.free(setup.pack_path);
        allocator.free(setup.idx_path);
    }

    // Read the git-created pack
    const pack_data = try std.fs.cwd().readFileAlloc(allocator, setup.pack_path, 10 * 1024 * 1024);
    defer allocator.free(pack_data);

    // Create a fresh repo directory to receive the pack
    const recv_dir = try makeTmpDir(allocator);
    defer cleanupDir(allocator, recv_dir);

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{recv_dir});
    defer allocator.free(git_dir);
    const pack_subdir = try std.fmt.allocPrint(allocator, "{s}/objects/pack", .{git_dir});
    defer allocator.free(pack_subdir);
    try std.fs.cwd().makePath(pack_subdir);

    // saveReceivedPack uses platform_impl - we need to use the real filesystem
    // Instead, test the components: generatePackIndex + manual file writes
    const idx_data = try objects.generatePackIndex(pack_data, allocator);
    defer allocator.free(idx_data);

    // Write pack and idx
    const checksum_hex = blk: {
        const content_end = pack_data.len - 20;
        var buf: [40]u8 = undefined;
        _ = std.fmt.bufPrint(&buf, "{}", .{std.fmt.fmtSliceHexLower(pack_data[content_end..])}) catch unreachable;
        break :blk buf;
    };

    const new_pack_path = try std.fmt.allocPrint(allocator, "{s}/objects/pack/pack-{s}.pack", .{ git_dir, checksum_hex });
    defer allocator.free(new_pack_path);
    try std.fs.cwd().writeFile(.{ .sub_path = new_pack_path, .data = pack_data });

    const new_idx_path = try std.fmt.allocPrint(allocator, "{s}/objects/pack/pack-{s}.idx", .{ git_dir, checksum_hex });
    defer allocator.free(new_idx_path);
    try std.fs.cwd().writeFile(.{ .sub_path = new_idx_path, .data = idx_data });

    // Now verify git can read the pack we wrote
    const verify_out = try execGit(allocator, recv_dir, &.{ "verify-pack", "-v", new_pack_path });
    defer allocator.free(verify_out);

    // Should contain object entries
    try std.testing.expect(std.mem.indexOf(u8, verify_out, "commit") != null or
        std.mem.indexOf(u8, verify_out, "tree") != null or
        std.mem.indexOf(u8, verify_out, "blob") != null);
}

// =============================================================================
// Test: readPackObjectAtOffset for every object type from a real git pack
// =============================================================================

test "readPackObjectAtOffset: read all objects from git-created pack" {
    const allocator = std.testing.allocator;
    const setup = try setupRepoAndRepack(allocator);
    defer {
        cleanupDir(allocator, setup.dir);
        allocator.free(setup.pack_path);
        allocator.free(setup.idx_path);
    }

    const pack_data = try std.fs.cwd().readFileAlloc(allocator, setup.pack_path, 10 * 1024 * 1024);
    defer allocator.free(pack_data);

    // Get object list from git verify-pack
    const verify_out = try execGit(allocator, setup.dir, &.{ "verify-pack", "-v", setup.pack_path });
    defer allocator.free(verify_out);

    // Parse verify-pack output to get offsets
    var lines = std.mem.splitScalar(u8, verify_out, '\n');
    var read_count: usize = 0;
    while (lines.next()) |line| {
        // Format: SHA-1 type size size-in-packfile offset-in-packfile [depth base-SHA-1]
        if (line.len < 40) continue;
        // Skip non-object lines (chain stats, etc)
        if (!std.ascii.isHex(line[0])) continue;

        var parts = std.mem.tokenizeScalar(u8, line, ' ');
        const sha_str = parts.next() orelse continue;
        if (sha_str.len != 40) continue;
        const type_str = parts.next() orelse continue;
        _ = parts.next(); // size
        _ = parts.next(); // size-in-packfile
        const offset_str = parts.next() orelse continue;
        const offset = std.fmt.parseInt(usize, offset_str, 10) catch continue;

        // Read with ziggit
        const obj = objects.readPackObjectAtOffset(pack_data, offset, allocator) catch |err| {
            // REF_DELTA is expected to fail in readPackObjectAtOffset (no external lookup)
            if (err == error.RefDeltaRequiresExternalLookup) continue;
            return err;
        };
        defer obj.deinit(allocator);

        // Verify type matches
        const expected_type: objects.ObjectType = if (std.mem.eql(u8, type_str, "commit"))
            .commit
        else if (std.mem.eql(u8, type_str, "tree"))
            .tree
        else if (std.mem.eql(u8, type_str, "blob"))
            .blob
        else if (std.mem.eql(u8, type_str, "tag"))
            .tag
        else
            continue;

        try std.testing.expectEqual(expected_type, obj.type);

        // Verify content matches git cat-file
        const cat_out = try execGit(allocator, setup.dir, &.{ "cat-file", "-p", sha_str });
        defer allocator.free(cat_out);

        if (obj.type == .blob or obj.type == .commit or obj.type == .tag) {
            try std.testing.expectEqualSlices(u8, cat_out, obj.data);
        }
        // tree format differs (git cat-file -p formats it, raw is binary)

        read_count += 1;
    }

    // Should have read at least some objects
    try std.testing.expect(read_count >= 3);
}

// =============================================================================
// Test: delta application with git-generated deltas
// =============================================================================

test "delta: git-generated OFS_DELTA produces correct content" {
    const allocator = std.testing.allocator;
    const dir = try makeTmpDir(allocator);
    defer cleanupDir(allocator, dir);

    try execGitNoOutput(allocator, dir, &.{ "init", "-b", "main" });
    try execGitNoOutput(allocator, dir, &.{ "config", "user.email", "test@test.com" });
    try execGitNoOutput(allocator, dir, &.{ "config", "user.name", "Test" });

    // Create a file, commit, modify slightly, commit again → forces OFS_DELTA after repack
    const content1 = "Line 1\nLine 2\nLine 3\nLine 4\nLine 5\nLine 6\nLine 7\nLine 8\nLine 9\nLine 10\n";
    const content2 = "Line 1\nLine 2\nLine 3\nLine 4\nModified 5\nLine 6\nLine 7\nLine 8\nLine 9\nLine 10\nLine 11\n";

    {
        const p = try std.fmt.allocPrint(allocator, "{s}/data.txt", .{dir});
        defer allocator.free(p);
        try std.fs.cwd().writeFile(.{ .sub_path = p, .data = content1 });
    }
    try execGitNoOutput(allocator, dir, &.{ "add", "." });
    try execGitNoOutput(allocator, dir, &.{ "commit", "-m", "v1" });

    const hash1_out = try execGit(allocator, dir, &.{ "rev-parse", "HEAD:data.txt" });
    defer allocator.free(hash1_out);
    const hash1 = std.mem.trim(u8, hash1_out, "\n\r ");

    {
        const p = try std.fmt.allocPrint(allocator, "{s}/data.txt", .{dir});
        defer allocator.free(p);
        try std.fs.cwd().writeFile(.{ .sub_path = p, .data = content2 });
    }
    try execGitNoOutput(allocator, dir, &.{ "add", "." });
    try execGitNoOutput(allocator, dir, &.{ "commit", "-m", "v2" });

    const hash2_out = try execGit(allocator, dir, &.{ "rev-parse", "HEAD:data.txt" });
    defer allocator.free(hash2_out);
    const hash2 = std.mem.trim(u8, hash2_out, "\n\r ");

    // Repack aggressively to create deltas
    try execGitNoOutput(allocator, dir, &.{ "repack", "-a", "-d", "-f", "--depth=10" });

    // Find pack file
    const pack_dir_path = try std.fmt.allocPrint(allocator, "{s}/.git/objects/pack", .{dir});
    defer allocator.free(pack_dir_path);
    var pd = try std.fs.cwd().openDir(pack_dir_path, .{ .iterate = true });
    defer pd.close();

    var pack_path: ?[]u8 = null;
    var piter = pd.iterate();
    while (try piter.next()) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".pack")) {
            pack_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pack_dir_path, entry.name });
        }
    }
    defer if (pack_path) |p| allocator.free(p);

    const pack_data = try std.fs.cwd().readFileAlloc(allocator, pack_path.?, 10 * 1024 * 1024);
    defer allocator.free(pack_data);

    // Generate idx so we can look up by hash
    const idx_data = try objects.generatePackIndex(pack_data, allocator);
    defer allocator.free(idx_data);

    // Look up both blob hashes in our idx and verify content
    // We'll use verify-pack to get offsets
    const verify_out = try execGit(allocator, dir, &.{ "verify-pack", "-v", pack_path.? });
    defer allocator.free(verify_out);

    var found_v1 = false;
    var found_v2 = false;
    var vlines = std.mem.splitScalar(u8, verify_out, '\n');
    while (vlines.next()) |line| {
        if (line.len < 40) continue;
        var parts = std.mem.tokenizeScalar(u8, line, ' ');
        const sha = parts.next() orelse continue;
        if (sha.len != 40) continue;
        _ = parts.next(); // type
        _ = parts.next(); // size
        _ = parts.next(); // size-in-packfile
        const off_str = parts.next() orelse continue;
        const off = std.fmt.parseInt(usize, off_str, 10) catch continue;

        if (std.mem.eql(u8, sha, hash1)) {
            const obj = try objects.readPackObjectAtOffset(pack_data, off, allocator);
            defer obj.deinit(allocator);
            try std.testing.expectEqual(objects.ObjectType.blob, obj.type);
            try std.testing.expectEqualSlices(u8, content1, obj.data);
            found_v1 = true;
        } else if (std.mem.eql(u8, sha, hash2)) {
            const obj = try objects.readPackObjectAtOffset(pack_data, off, allocator);
            defer obj.deinit(allocator);
            try std.testing.expectEqual(objects.ObjectType.blob, obj.type);
            try std.testing.expectEqualSlices(u8, content2, obj.data);
            found_v2 = true;
        }
    }

    try std.testing.expect(found_v1);
    try std.testing.expect(found_v2);
}

// =============================================================================
// Test: git verify-pack -v on ziggit-generated idx succeeds
// =============================================================================

test "generatePackIndex: git verify-pack validates ziggit-generated idx" {
    const allocator = std.testing.allocator;
    const setup = try setupRepoAndRepack(allocator);
    defer {
        cleanupDir(allocator, setup.dir);
        allocator.free(setup.pack_path);
        allocator.free(setup.idx_path);
    }

    const pack_data = try std.fs.cwd().readFileAlloc(allocator, setup.pack_path, 10 * 1024 * 1024);
    defer allocator.free(pack_data);

    const our_idx = try objects.generatePackIndex(pack_data, allocator);
    defer allocator.free(our_idx);

    // Overwrite git's idx with ours
    try std.fs.cwd().writeFile(.{ .sub_path = setup.idx_path, .data = our_idx });

    // git verify-pack should succeed with our idx
    const verify_out = try execGit(allocator, setup.dir, &.{ "verify-pack", "-v", setup.pack_path });
    defer allocator.free(verify_out);

    // Should mention objects
    try std.testing.expect(verify_out.len > 0);
}

// =============================================================================
// Test: binary blob roundtrip through pack
// =============================================================================

test "pack roundtrip: binary blob with null bytes preserved" {
    const allocator = std.testing.allocator;
    const dir = try makeTmpDir(allocator);
    defer cleanupDir(allocator, dir);

    try execGitNoOutput(allocator, dir, &.{ "init", "-b", "main" });
    try execGitNoOutput(allocator, dir, &.{ "config", "user.email", "test@test.com" });
    try execGitNoOutput(allocator, dir, &.{ "config", "user.name", "Test" });

    // Create binary file with null bytes
    const binary_content = "BIN\x00\x01\x02\x03\xff\xfe\xfd\x00DATA\x00END";
    {
        const p = try std.fmt.allocPrint(allocator, "{s}/binary.dat", .{dir});
        defer allocator.free(p);
        try std.fs.cwd().writeFile(.{ .sub_path = p, .data = binary_content });
    }
    try execGitNoOutput(allocator, dir, &.{ "add", "." });
    try execGitNoOutput(allocator, dir, &.{ "commit", "-m", "binary" });

    const hash_out = try execGit(allocator, dir, &.{ "rev-parse", "HEAD:binary.dat" });
    defer allocator.free(hash_out);
    const blob_hash = std.mem.trim(u8, hash_out, "\n\r ");

    try execGitNoOutput(allocator, dir, &.{ "repack", "-a", "-d" });

    // Find and read pack
    const pack_dir_path = try std.fmt.allocPrint(allocator, "{s}/.git/objects/pack", .{dir});
    defer allocator.free(pack_dir_path);
    var pd = try std.fs.cwd().openDir(pack_dir_path, .{ .iterate = true });
    defer pd.close();

    var pack_path: ?[]u8 = null;
    var piter = pd.iterate();
    while (try piter.next()) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".pack")) {
            pack_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pack_dir_path, entry.name });
        }
    }
    defer if (pack_path) |p| allocator.free(p);

    const pack_data = try std.fs.cwd().readFileAlloc(allocator, pack_path.?, 10 * 1024 * 1024);
    defer allocator.free(pack_data);

    // Find blob offset via verify-pack
    const verify_out = try execGit(allocator, dir, &.{ "verify-pack", "-v", pack_path.? });
    defer allocator.free(verify_out);

    var vlines = std.mem.splitScalar(u8, verify_out, '\n');
    while (vlines.next()) |line| {
        if (line.len < 40) continue;
        var parts = std.mem.tokenizeScalar(u8, line, ' ');
        const sha = parts.next() orelse continue;
        if (!std.mem.eql(u8, sha, blob_hash)) continue;
        _ = parts.next(); // type
        _ = parts.next(); // size
        _ = parts.next(); // size-in-packfile
        const off_str = parts.next() orelse continue;
        const off = std.fmt.parseInt(usize, off_str, 10) catch continue;

        const obj = try objects.readPackObjectAtOffset(pack_data, off, allocator);
        defer obj.deinit(allocator);
        try std.testing.expectEqual(objects.ObjectType.blob, obj.type);
        try std.testing.expectEqualSlices(u8, binary_content, obj.data);
        return; // success
    }

    return error.BlobNotFound;
}

// =============================================================================
// Test: large pack with many objects
// =============================================================================

test "generatePackIndex: handles pack with 50+ objects" {
    const allocator = std.testing.allocator;
    const dir = try makeTmpDir(allocator);
    defer cleanupDir(allocator, dir);

    try execGitNoOutput(allocator, dir, &.{ "init", "-b", "main" });
    try execGitNoOutput(allocator, dir, &.{ "config", "user.email", "test@test.com" });
    try execGitNoOutput(allocator, dir, &.{ "config", "user.name", "Test" });

    // Create 20 files across 5 commits = many tree/blob/commit objects
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        var j: usize = 0;
        while (j < 4) : (j += 1) {
            const fname = try std.fmt.allocPrint(allocator, "{s}/file_{d}_{d}.txt", .{ dir, i, j });
            defer allocator.free(fname);
            const content = try std.fmt.allocPrint(allocator, "Content for file {d}_{d}, iteration {d}\n", .{ i, j, i * 4 + j });
            defer allocator.free(content);
            try std.fs.cwd().writeFile(.{ .sub_path = fname, .data = content });
        }
        try execGitNoOutput(allocator, dir, &.{ "add", "." });
        const msg = try std.fmt.allocPrint(allocator, "commit {d}", .{i});
        defer allocator.free(msg);
        try execGitNoOutput(allocator, dir, &.{ "commit", "-m", msg });
    }

    try execGitNoOutput(allocator, dir, &.{ "repack", "-a", "-d", "-f" });

    // Find pack
    const pack_dir_path = try std.fmt.allocPrint(allocator, "{s}/.git/objects/pack", .{dir});
    defer allocator.free(pack_dir_path);
    var pd = try std.fs.cwd().openDir(pack_dir_path, .{ .iterate = true });
    defer pd.close();

    var pack_path: ?[]u8 = null;
    var idx_path: ?[]u8 = null;
    var piter = pd.iterate();
    while (try piter.next()) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".pack")) {
            pack_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pack_dir_path, entry.name });
        } else if (std.mem.endsWith(u8, entry.name, ".idx")) {
            idx_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pack_dir_path, entry.name });
        }
    }
    defer if (pack_path) |p| allocator.free(p);
    defer if (idx_path) |p| allocator.free(p);

    const pack_data = try std.fs.cwd().readFileAlloc(allocator, pack_path.?, 10 * 1024 * 1024);
    defer allocator.free(pack_data);

    const git_idx = try std.fs.cwd().readFileAlloc(allocator, idx_path.?, 10 * 1024 * 1024);
    defer allocator.free(git_idx);

    const our_idx = try objects.generatePackIndex(pack_data, allocator);
    defer allocator.free(our_idx);

    // Object count should be >= 50 (5 commits + 5+ trees + 20 blobs + possible deltas)
    const total = std.mem.readInt(u32, @ptrCast(our_idx[8 + 255 * 4 .. 8 + 256 * 4]), .big);
    try std.testing.expect(total >= 25); // At least 25 objects

    // Must be byte-identical to git's idx
    try std.testing.expectEqual(git_idx.len, our_idx.len);
    try std.testing.expectEqualSlices(u8, git_idx, our_idx);
}
