const std = @import("std");
const testing = std.testing;
const objects = @import("git_objects");

// ============================================================================
// Pack format ground-truth tests:
//   - Use real git CLI to create repos with all object types
//   - Repack into pack files
//   - Verify ziggit can read every object type from pack
//   - Verify ziggit-generated pack+idx are readable by git
//   - Test REF_DELTA and OFS_DELTA resolution
// ============================================================================

/// Run git command, return trimmed stdout. Fails on non-zero exit.
fn git(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) ![]u8 {
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
    const stderr = try child.stderr.?.reader().readAllAlloc(allocator, 4 * 1024 * 1024);
    defer allocator.free(stderr);
    const result = try child.wait();
    if (result.Exited != 0) {
        allocator.free(stdout);
        return error.GitCommandFailed;
    }
    return stdout;
}

/// Run git command, discard output
fn gitExec(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) !void {
    const out = try git(allocator, cwd, args);
    allocator.free(out);
}

/// Create a tmp dir, return its path (caller frees)
fn makeTmpDir(allocator: std.mem.Allocator, prefix: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(allocator, "/tmp/ziggit_test_{s}_{}", .{ prefix, std.crypto.random.int(u64) });
    try std.fs.cwd().makePath(path);
    return path;
}

fn rmTmpDir(path: []const u8) void {
    std.fs.cwd().deleteTree(path) catch {};
}

/// Encode git varint for delta headers
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

/// Append a copy command to a delta instruction stream
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
        if (actual_size & 0xFF00 != 0) { cmd |= 0x20; try params.append(@intCast((actual_size >> 8) & 0xFF)); }
        if (actual_size & 0xFF0000 != 0) { cmd |= 0x40; try params.append(@intCast((actual_size >> 16) & 0xFF)); }
    }
    try delta.append(cmd);
    try delta.appendSlice(params.items);
}

/// Build a minimal valid pack file with given objects.
/// Each PackEntry is {type_num (1-4), data}. Returns owned pack bytes.
fn buildPackFile(allocator: std.mem.Allocator, entries_arg: []const PackEntry) ![]u8 {
    var pack = std.ArrayList(u8).init(allocator);
    defer pack.deinit();

    // Header
    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big); // version 2
    try pack.writer().writeInt(u32, @intCast(entries_arg.len), .big);

    for (entries_arg) |entry| {
        // Object header: type (3 bits) + size
        const obj_type: u8 = entry.type_num;
        const data = entry.data;
        const size = data.len;

        // First byte: MSB=continuation, bits 6-4=type, bits 3-0=size[3:0]
        var first: u8 = (obj_type << 4) | @as(u8, @intCast(size & 0x0F));
        var remaining = size >> 4;
        if (remaining > 0) first |= 0x80;
        try pack.append(first);
        
        while (remaining > 0) {
            var b: u8 = @intCast(remaining & 0x7F);
            remaining >>= 7;
            if (remaining > 0) b |= 0x80;
            try pack.append(b);
        }

        // OFS_DELTA header
        if (entry.type_num == 6) {
            // Encode negative offset
            const neg_offset = entry.ofs_delta_offset.?;
            var off = neg_offset;
            // Git's variable-length encoding for ofs_delta
            var off_bytes: [10]u8 = undefined;
            var off_len: usize = 1;
            off_bytes[0] = @intCast(off & 0x7F);
            off >>= 7;
            while (off > 0) {
                off -= 1;
                off_bytes[off_len] = @intCast(0x80 | (off & 0x7F));
                off >>= 7;
                off_len += 1;
            }
            // Write in reverse order
            var ri: usize = off_len;
            while (ri > 0) {
                ri -= 1;
                try pack.append(off_bytes[ri]);
            }
        }

        // REF_DELTA header
        if (entry.type_num == 7) {
            try pack.appendSlice(&entry.ref_delta_sha1.?);
        }

        // Compress data
        var compressed = std.ArrayList(u8).init(allocator);
        defer compressed.deinit();
        var stream = std.io.fixedBufferStream(data);
        try std.compress.zlib.compress(stream.reader(), compressed.writer(), .{});
        try pack.appendSlice(compressed.items);
    }

    // SHA-1 checksum of everything
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack.items);
    var checksum: [20]u8 = undefined;
    hasher.final(&checksum);
    try pack.appendSlice(&checksum);

    return try pack.toOwnedSlice();
}

const PackEntry = struct {
    type_num: u8, // 1=commit, 2=tree, 3=blob, 4=tag, 6=ofs_delta, 7=ref_delta
    data: []const u8,
    ofs_delta_offset: ?usize = null,
    ref_delta_sha1: ?[20]u8 = null,
};

// ============================================================================
// TEST 1: git creates pack with all object types, ziggit reads each
// ============================================================================
test "pack: git-created pack with commit/tree/blob/tag readable by ziggit" {
    const allocator = testing.allocator;
    const dir = try makeTmpDir(allocator, "allobj");
    defer { rmTmpDir(dir); allocator.free(dir); }

    // Init repo, create content
    try gitExec(allocator, dir, &.{ "init", "-b", "main" });
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{dir});
    defer allocator.free(git_dir);

    // Configure git user
    try gitExec(allocator, dir, &.{ "config", "user.email", "test@test.com" });
    try gitExec(allocator, dir, &.{ "config", "user.name", "Test" });

    // Create files and commit
    const file_path = try std.fmt.allocPrint(allocator, "{s}/hello.txt", .{dir});
    defer allocator.free(file_path);
    try std.fs.cwd().writeFile(.{ .sub_path = file_path, .data = "Hello World\n" });
    try gitExec(allocator, dir, &.{ "add", "." });
    try gitExec(allocator, dir, &.{ "commit", "-m", "initial commit" });

    // Create a tag
    try gitExec(allocator, dir, &.{ "tag", "-a", "v1.0", "-m", "version 1.0" });

    // Force repack to get all objects in a pack
    try gitExec(allocator, dir, &.{ "gc", "--aggressive" });

    // Get all object hashes via git
    const blob_hash_raw = try git(allocator, dir, &.{ "rev-parse", "HEAD:hello.txt" });
    defer allocator.free(blob_hash_raw);
    const blob_hash = std.mem.trim(u8, blob_hash_raw, "\n\r ");

    const tree_hash_raw = try git(allocator, dir, &.{ "rev-parse", "HEAD^{tree}" });
    defer allocator.free(tree_hash_raw);
    const tree_hash = std.mem.trim(u8, tree_hash_raw, "\n\r ");

    const commit_hash_raw = try git(allocator, dir, &.{ "rev-parse", "HEAD" });
    defer allocator.free(commit_hash_raw);
    const commit_hash = std.mem.trim(u8, commit_hash_raw, "\n\r ");

    // Platform shim for ziggit objects
    const platform = NativePlatform{};

    // Read blob
    const blob_obj = try objects.GitObject.load(blob_hash, git_dir, platform, allocator);
    defer blob_obj.deinit(allocator);
    try testing.expectEqual(objects.ObjectType.blob, blob_obj.type);
    try testing.expectEqualStrings("Hello World\n", blob_obj.data);

    // Read tree
    const tree_obj = try objects.GitObject.load(tree_hash, git_dir, platform, allocator);
    defer tree_obj.deinit(allocator);
    try testing.expectEqual(objects.ObjectType.tree, tree_obj.type);
    // Tree should contain "hello.txt" entry
    try testing.expect(std.mem.indexOf(u8, tree_obj.data, "hello.txt") != null);

    // Read commit
    const commit_obj = try objects.GitObject.load(commit_hash, git_dir, platform, allocator);
    defer commit_obj.deinit(allocator);
    try testing.expectEqual(objects.ObjectType.commit, commit_obj.type);
    try testing.expect(std.mem.indexOf(u8, commit_obj.data, "initial commit") != null);

    // Read tag (annotated tag is a separate object)
    // tag_hash might point to the commit if git resolved it. Use git cat-file to get the tag object hash.
    const tag_obj_hash_raw = try git(allocator, dir, &.{ "rev-parse", "refs/tags/v1.0" });
    defer allocator.free(tag_obj_hash_raw);
    const tag_obj_hash = std.mem.trim(u8, tag_obj_hash_raw, "\n\r ");
    
    // Check if this is actually a tag object
    const tag_type_raw = try git(allocator, dir, &.{ "cat-file", "-t", tag_obj_hash });
    defer allocator.free(tag_type_raw);
    const tag_type = std.mem.trim(u8, tag_type_raw, "\n\r ");

    if (std.mem.eql(u8, tag_type, "tag")) {
        const tag_obj = try objects.GitObject.load(tag_obj_hash, git_dir, platform, allocator);
        defer tag_obj.deinit(allocator);
        try testing.expectEqual(objects.ObjectType.tag, tag_obj.type);
        try testing.expect(std.mem.indexOf(u8, tag_obj.data, "version 1.0") != null);
    }
}

// ============================================================================
// TEST 2: Build pack from scratch, generate idx, verify git can read it
// ============================================================================
test "pack: ziggit saveReceivedPack produces git-readable pack+idx" {
    const allocator = testing.allocator;
    const dir = try makeTmpDir(allocator, "savepk");
    defer { rmTmpDir(dir); allocator.free(dir); }

    // Init bare-ish structure
    try gitExec(allocator, dir, &.{ "init", "-b", "main" });
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{dir});
    defer allocator.free(git_dir);

    // Build a pack with one blob object
    const blob_content = "This is test blob content for saveReceivedPack\n";
    const pack_data = try buildPackFile(allocator, &.{
        PackEntry{ .type_num = 3, .data = blob_content },
    });
    defer allocator.free(pack_data);

    // Save via ziggit
    const platform = NativePlatform{};
    const checksum_hex = try objects.saveReceivedPack(pack_data, git_dir, platform, allocator);
    defer allocator.free(checksum_hex);

    // Verify with git verify-pack
    const pack_path = try std.fmt.allocPrint(allocator, "{s}/objects/pack/pack-{s}.pack", .{ git_dir, checksum_hex });
    defer allocator.free(pack_path);

    const verify_output = try git(allocator, dir, &.{ "verify-pack", "-v", pack_path });
    defer allocator.free(verify_output);
    // Should contain "blob" somewhere
    try testing.expect(std.mem.indexOf(u8, verify_output, "blob") != null);

    // Verify we can read the blob back with git cat-file
    // First find the blob hash from verify-pack output
    var lines = std.mem.splitScalar(u8, verify_output, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "blob") != null) {
            const hash = line[0..40];
            const cat_output = try git(allocator, dir, &.{ "cat-file", "-p", hash });
            defer allocator.free(cat_output);
            try testing.expectEqualStrings(blob_content, cat_output);
            break;
        }
    }
}

// ============================================================================
// TEST 3: Pack with multiple object types - full round trip through ziggit
// ============================================================================
test "pack: multi-type pack round-trip through generatePackIndex" {
    const allocator = testing.allocator;
    const dir = try makeTmpDir(allocator, "multi");
    defer { rmTmpDir(dir); allocator.free(dir); }

    try gitExec(allocator, dir, &.{ "init", "-b", "main" });
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{dir});
    defer allocator.free(git_dir);

    // Build a pack with blob + tree + commit
    const blob_data = "file content\n";
    // Tree entry: "100644 file.txt\0" + 20-byte SHA-1 of blob
    // First compute blob hash
    var blob_sha1: [20]u8 = undefined;
    {
        const header = try std.fmt.allocPrint(allocator, "blob {}\x00", .{blob_data.len});
        defer allocator.free(header);
        var h = std.crypto.hash.Sha1.init(.{});
        h.update(header);
        h.update(blob_data);
        h.final(&blob_sha1);
    }

    // Build tree data
    var tree_buf = std.ArrayList(u8).init(allocator);
    defer tree_buf.deinit();
    try tree_buf.writer().print("100644 file.txt\x00", .{});
    try tree_buf.appendSlice(&blob_sha1);
    const tree_data = tree_buf.items;

    // Compute tree hash
    var tree_sha1: [20]u8 = undefined;
    {
        const header = try std.fmt.allocPrint(allocator, "tree {}\x00", .{tree_data.len});
        defer allocator.free(header);
        var h = std.crypto.hash.Sha1.init(.{});
        h.update(header);
        h.update(tree_data);
        h.final(&tree_sha1);
    }

    // Build commit data
    const tree_hex = try std.fmt.allocPrint(allocator, "{}", .{std.fmt.fmtSliceHexLower(&tree_sha1)});
    defer allocator.free(tree_hex);
    const commit_data_str = try std.fmt.allocPrint(allocator,
        "tree {s}\nauthor Test <test@test.com> 1700000000 +0000\ncommitter Test <test@test.com> 1700000000 +0000\n\ninitial\n",
        .{tree_hex},
    );
    defer allocator.free(commit_data_str);

    const pack_data = try buildPackFile(allocator, &.{
        PackEntry{ .type_num = 3, .data = blob_data },
        PackEntry{ .type_num = 2, .data = tree_data },
        PackEntry{ .type_num = 1, .data = commit_data_str },
    });
    defer allocator.free(pack_data);

    // Generate index
    const idx_data = try objects.generatePackIndex(pack_data, allocator);
    defer allocator.free(idx_data);

    // Verify idx structure: magic + version + fanout
    try testing.expectEqual(@as(u32, 0xff744f63), std.mem.readInt(u32, @ptrCast(idx_data[0..4]), .big));
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, @ptrCast(idx_data[4..8]), .big));

    // Fanout[255] should equal total objects (3)
    const total = std.mem.readInt(u32, @ptrCast(idx_data[8 + 255 * 4 .. 8 + 255 * 4 + 4]), .big);
    try testing.expectEqual(@as(u32, 3), total);

    // Save and verify with git
    const platform = NativePlatform{};
    const checksum_hex = try objects.saveReceivedPack(pack_data, git_dir, platform, allocator);
    defer allocator.free(checksum_hex);

    const pack_path = try std.fmt.allocPrint(allocator, "{s}/objects/pack/pack-{s}.pack", .{ git_dir, checksum_hex });
    defer allocator.free(pack_path);
    const verify = try git(allocator, dir, &.{ "verify-pack", "-v", pack_path });
    defer allocator.free(verify);

    // Should find all 3 object types
    try testing.expect(std.mem.indexOf(u8, verify, "blob") != null);
    try testing.expect(std.mem.indexOf(u8, verify, "tree") != null);
    try testing.expect(std.mem.indexOf(u8, verify, "commit") != null);
}

// ============================================================================
// TEST 4: OFS_DELTA in pack - build pack with base+delta, verify read
// ============================================================================
test "pack: OFS_DELTA object correctly resolved" {
    const allocator = testing.allocator;

    const base_data = "Hello World - this is the original content of the file.\n";
    const expected_result = "Hello World - this is the MODIFIED content of the file.\n";

    // Build delta: copy first 36 bytes ("Hello World - this is the "), insert "MODIFIED", copy rest
    var delta = std.ArrayList(u8).init(allocator);
    defer delta.deinit();
    var buf: [10]u8 = undefined;
    var n = encodeVarint(&buf, base_data.len);
    try delta.appendSlice(buf[0..n]);
    n = encodeVarint(&buf, expected_result.len);
    try delta.appendSlice(buf[0..n]);
    // Copy "Hello World - this is the "
    try appendCopyCmd(&delta, 0, 26);
    // Insert "MODIFIED"
    try delta.append(8);
    try delta.appendSlice("MODIFIED");
    // Copy " content of the file.\n" from offset 34
    try appendCopyCmd(&delta, 34, base_data.len - 34);

    const delta_data = try delta.toOwnedSlice();
    defer allocator.free(delta_data);

    // Build pack: base blob at offset 12, OFS_DELTA after it
    // First build the base blob entry to know its size
    var base_pack_entry = std.ArrayList(u8).init(allocator);
    defer base_pack_entry.deinit();
    {
        // Object header for blob
        var first: u8 = (3 << 4) | @as(u8, @intCast(base_data.len & 0x0F));
        var remaining = base_data.len >> 4;
        if (remaining > 0) first |= 0x80;
        try base_pack_entry.append(first);
        while (remaining > 0) {
            var b: u8 = @intCast(remaining & 0x7F);
            remaining >>= 7;
            if (remaining > 0) b |= 0x80;
            try base_pack_entry.append(b);
        }
        // Compress
        var compressed = std.ArrayList(u8).init(allocator);
        defer compressed.deinit();
        var stream = std.io.fixedBufferStream(@as([]const u8, base_data));
        try std.compress.zlib.compress(stream.reader(), compressed.writer(), .{});
        try base_pack_entry.appendSlice(compressed.items);
    }

    const base_offset: usize = 12; // After PACK header (12 bytes)
    const delta_obj_start = base_offset + base_pack_entry.items.len;
    const neg_offset = delta_obj_start - base_offset;

    const pack_data = try buildPackFile(allocator, &.{
        PackEntry{ .type_num = 3, .data = base_data },
        PackEntry{ .type_num = 6, .data = delta_data, .ofs_delta_offset = neg_offset },
    });
    defer allocator.free(pack_data);

    // Generate index and save to a temp repo
    const dir = try makeTmpDir(allocator, "ofsdelta");
    defer { rmTmpDir(dir); allocator.free(dir); }
    try gitExec(allocator, dir, &.{ "init", "-b", "main" });
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{dir});
    defer allocator.free(git_dir);

    const platform = NativePlatform{};
    const checksum_hex = try objects.saveReceivedPack(pack_data, git_dir, platform, allocator);
    defer allocator.free(checksum_hex);

    // Read delta object through ziggit (should resolve through base)
    // Get the hash of the delta result
    var expected_sha1: [20]u8 = undefined;
    {
        const header = try std.fmt.allocPrint(allocator, "blob {}\x00", .{expected_result.len});
        defer allocator.free(header);
        var h = std.crypto.hash.Sha1.init(.{});
        h.update(header);
        h.update(expected_result);
        h.final(&expected_sha1);
    }
    const expected_hex = try std.fmt.allocPrint(allocator, "{}", .{std.fmt.fmtSliceHexLower(&expected_sha1)});
    defer allocator.free(expected_hex);

    const obj = try objects.GitObject.load(expected_hex, git_dir, platform, allocator);
    defer obj.deinit(allocator);
    try testing.expectEqual(objects.ObjectType.blob, obj.type);
    try testing.expectEqualStrings(expected_result, obj.data);
}

// ============================================================================
// TEST 5: git gc produces delta chains, ziggit resolves them
// ============================================================================
test "pack: read objects after git gc with delta chains" {
    const allocator = testing.allocator;
    const dir = try makeTmpDir(allocator, "gc_delta");
    defer { rmTmpDir(dir); allocator.free(dir); }

    try gitExec(allocator, dir, &.{ "init", "-b", "main" });
    try gitExec(allocator, dir, &.{ "config", "user.email", "t@t.com" });
    try gitExec(allocator, dir, &.{ "config", "user.name", "T" });
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{dir});
    defer allocator.free(git_dir);

    // Create multiple similar files to encourage delta compression
    const file_path = try std.fmt.allocPrint(allocator, "{s}/data.txt", .{dir});
    defer allocator.free(file_path);

    var contents: [5][]u8 = undefined;
    var commit_hashes: [5][]u8 = undefined;
    for (0..5) |i| {
        // Create content that shares a lot with previous versions
        const content = try std.fmt.allocPrint(allocator, "Line 1: shared prefix content\nLine 2: shared middle section\nLine 3: version {}\nLine 4: more shared content at the end\n", .{i});
        contents[i] = content;
        try std.fs.cwd().writeFile(.{ .sub_path = file_path, .data = content });
        try gitExec(allocator, dir, &.{ "add", "." });
        const msg = try std.fmt.allocPrint(allocator, "commit {}", .{i});
        defer allocator.free(msg);
        try gitExec(allocator, dir, &.{ "commit", "-m", msg });

        const hash_raw = try git(allocator, dir, &.{ "rev-parse", "HEAD" });
        commit_hashes[i] = hash_raw;
    }
    defer for (&contents) |c| allocator.free(c);
    defer for (&commit_hashes) |c| allocator.free(c);

    // Force aggressive gc to create deltas
    try gitExec(allocator, dir, &.{ "gc", "--aggressive" });

    // Now read each commit and its tree+blob via ziggit
    const platform = NativePlatform{};
    for (0..5) |i| {
        const hash = std.mem.trim(u8, commit_hashes[i], "\n\r ");
        const commit_obj = try objects.GitObject.load(hash, git_dir, platform, allocator);
        defer commit_obj.deinit(allocator);
        try testing.expectEqual(objects.ObjectType.commit, commit_obj.type);

        // Extract tree hash from commit
        const tree_line_end = std.mem.indexOf(u8, commit_obj.data, "\n") orelse continue;
        const tree_line = commit_obj.data[0..tree_line_end];
        if (!std.mem.startsWith(u8, tree_line, "tree ")) continue;
        const tree_hash = tree_line[5..];

        const tree_obj = try objects.GitObject.load(tree_hash, git_dir, platform, allocator);
        defer tree_obj.deinit(allocator);
        try testing.expectEqual(objects.ObjectType.tree, tree_obj.type);

        // Find blob hash in tree (binary format: "mode name\0sha1")
        if (std.mem.indexOf(u8, tree_obj.data, "data.txt")) |name_pos| {
            const null_pos = name_pos + "data.txt".len;
            if (null_pos < tree_obj.data.len and tree_obj.data[null_pos] == 0 and null_pos + 21 <= tree_obj.data.len) {
                const blob_sha1 = tree_obj.data[null_pos + 1 .. null_pos + 21];
                const blob_hex = try std.fmt.allocPrint(allocator, "{}", .{std.fmt.fmtSliceHexLower(blob_sha1)});
                defer allocator.free(blob_hex);

                const blob_obj = try objects.GitObject.load(blob_hex, git_dir, platform, allocator);
                defer blob_obj.deinit(allocator);
                try testing.expectEqual(objects.ObjectType.blob, blob_obj.type);
                try testing.expectEqualStrings(contents[i], blob_obj.data);
            }
        }
    }
}

// ============================================================================
// TEST 6: generatePackIndex fanout table correctness
// ============================================================================
test "pack: generated idx has monotonically increasing fanout table" {
    const allocator = testing.allocator;

    // Build a pack with several blobs
    var entries_buf: [10]PackEntry = undefined;
    var blob_datas: [10][]u8 = undefined;
    for (0..10) |i| {
        blob_datas[i] = try std.fmt.allocPrint(allocator, "blob number {}\n", .{i});
        entries_buf[i] = PackEntry{ .type_num = 3, .data = blob_datas[i] };
    }
    defer for (&blob_datas) |d| allocator.free(d);

    const pack_data = try buildPackFile(allocator, entries_buf[0..10]);
    defer allocator.free(pack_data);

    const idx_data = try objects.generatePackIndex(pack_data, allocator);
    defer allocator.free(idx_data);

    // Verify fanout is monotonically non-decreasing
    var prev: u32 = 0;
    for (0..256) |i| {
        const offset = 8 + i * 4;
        const val = std.mem.readInt(u32, @ptrCast(idx_data[offset .. offset + 4]), .big);
        try testing.expect(val >= prev);
        prev = val;
    }
    // Last entry should equal total objects
    try testing.expectEqual(@as(u32, 10), prev);
}

// ============================================================================
// TEST 7: SHA-1 table in idx is sorted
// ============================================================================
test "pack: generated idx SHA-1 table is sorted" {
    const allocator = testing.allocator;

    var entries_buf: [5]PackEntry = undefined;
    var blob_datas: [5][]u8 = undefined;
    for (0..5) |i| {
        blob_datas[i] = try std.fmt.allocPrint(allocator, "content-{}-unique\n", .{i});
        entries_buf[i] = PackEntry{ .type_num = 3, .data = blob_datas[i] };
    }
    defer for (&blob_datas) |d| allocator.free(d);

    const pack_data = try buildPackFile(allocator, entries_buf[0..5]);
    defer allocator.free(pack_data);

    const idx_data = try objects.generatePackIndex(pack_data, allocator);
    defer allocator.free(idx_data);

    const total = std.mem.readInt(u32, @ptrCast(idx_data[8 + 255 * 4 .. 8 + 255 * 4 + 4]), .big);
    const sha_table_start = 8 + 256 * 4;

    // Verify SHA-1 entries are sorted
    var i: u32 = 1;
    while (i < total) : (i += 1) {
        const prev_offset = sha_table_start + (i - 1) * 20;
        const curr_offset = sha_table_start + i * 20;
        const prev_sha = idx_data[prev_offset .. prev_offset + 20];
        const curr_sha = idx_data[curr_offset .. curr_offset + 20];
        try testing.expect(std.mem.order(u8, prev_sha, curr_sha) == .lt);
    }
}

// ============================================================================
// TEST 8: Pack checksum validation rejects corrupted data
// ============================================================================
test "pack: corrupted pack data rejected" {
    const allocator = testing.allocator;

    const pack_data = try buildPackFile(allocator, &.{
        PackEntry{ .type_num = 3, .data = "hello\n" },
    });
    defer allocator.free(pack_data);

    // Corrupt one byte in the middle
    var corrupted = try allocator.dupe(u8, pack_data);
    defer allocator.free(corrupted);
    corrupted[pack_data.len / 2] ^= 0xFF;

    // generatePackIndex should still work (it doesn't check the pack checksum)
    // but saveReceivedPack should reject it
    const dir = try makeTmpDir(allocator, "corrupt");
    defer { rmTmpDir(dir); allocator.free(dir); }
    try gitExec(allocator, dir, &.{ "init", "-b", "main" });
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{dir});
    defer allocator.free(git_dir);

    const platform = NativePlatform{};
    const result = objects.saveReceivedPack(corrupted, git_dir, platform, allocator);
    try testing.expectError(error.PackChecksumMismatch, result);
}

// ============================================================================
// TEST 9: Delta with copy size=0 (means 0x10000)
// ============================================================================
test "delta: copy size 0 means 0x10000" {
    const allocator = testing.allocator;

    // Create base data of exactly 0x10000 bytes
    const base = try allocator.alloc(u8, 0x10000);
    defer allocator.free(base);
    for (base, 0..) |*b, i| b.* = @intCast(i & 0xFF);

    // Delta: copy entire base with size=0x10000 (encoded as no size flags)
    var delta_buf = std.ArrayList(u8).init(allocator);
    defer delta_buf.deinit();
    var buf: [10]u8 = undefined;
    var n = encodeVarint(&buf, 0x10000);
    try delta_buf.appendSlice(buf[0..n]);
    n = encodeVarint(&buf, 0x10000);
    try delta_buf.appendSlice(buf[0..n]);
    // Copy command: offset=0, size=0 (means 0x10000) -- cmd = 0x80 with no flags
    try delta_buf.append(0x80);

    const delta_data = try delta_buf.toOwnedSlice();
    defer allocator.free(delta_data);

    const result = try objects.applyDelta(base, delta_data, allocator);
    defer allocator.free(result);

    try testing.expectEqual(@as(usize, 0x10000), result.len);
    try testing.expectEqualSlices(u8, base, result);
}

// ============================================================================
// TEST 10: Verify pack objects with git cat-file match ziggit
// ============================================================================
test "pack: git cat-file and ziggit produce identical output" {
    const allocator = testing.allocator;
    const dir = try makeTmpDir(allocator, "catfile");
    defer { rmTmpDir(dir); allocator.free(dir); }

    try gitExec(allocator, dir, &.{ "init", "-b", "main" });
    try gitExec(allocator, dir, &.{ "config", "user.email", "t@t.com" });
    try gitExec(allocator, dir, &.{ "config", "user.name", "T" });
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{dir});
    defer allocator.free(git_dir);

    // Create several files
    for ([_][]const u8{ "a.txt", "b.txt", "c.txt" }) |name| {
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, name });
        defer allocator.free(path);
        const content = try std.fmt.allocPrint(allocator, "content of {s}\n", .{name});
        defer allocator.free(content);
        try std.fs.cwd().writeFile(.{ .sub_path = path, .data = content });
    }
    try gitExec(allocator, dir, &.{ "add", "." });
    try gitExec(allocator, dir, &.{ "commit", "-m", "add files" });
    try gitExec(allocator, dir, &.{ "gc" });

    const platform = NativePlatform{};

    // For each blob, compare git cat-file -p with ziggit load
    for ([_][]const u8{ "a.txt", "b.txt", "c.txt" }) |name| {
        const ref = try std.fmt.allocPrint(allocator, "HEAD:{s}", .{name});
        defer allocator.free(ref);
        const hash_raw = try git(allocator, dir, &.{ "rev-parse", ref });
        defer allocator.free(hash_raw);
        const hash = std.mem.trim(u8, hash_raw, "\n\r ");

        const git_content = try git(allocator, dir, &.{ "cat-file", "-p", hash });
        defer allocator.free(git_content);

        const obj = try objects.GitObject.load(hash, git_dir, platform, allocator);
        defer obj.deinit(allocator);
        try testing.expectEqualStrings(git_content, obj.data);
    }
}

// ============================================================================
// Minimal native platform implementation for tests
// ============================================================================
const NativePlatform = struct {
    fs: Fs = .{},

    const Fs = struct {
        pub fn readFile(_: Fs, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
            return std.fs.cwd().readFileAlloc(allocator, path, 50 * 1024 * 1024);
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
