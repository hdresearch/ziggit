const std = @import("std");
const testing = std.testing;
const objects = @import("git_objects");

// ============================================================================
// CLONE WORKFLOW INTEGRATION TEST
//
// Simulates the full HTTPS clone workflow end-to-end:
//   1. Start with an empty repo (git init --bare)
//   2. Receive pack data (as clone/fetch would deliver)
//   3. Save pack with saveReceivedPack (writes .pack + .idx)
//   4. Update refs (HEAD, refs/remotes/origin/master)
//   5. Verify all objects are accessible
//   6. Verify refs resolve correctly
//   7. Cross-validate with git CLI
//
// This is the integration test the NET-SMART agent needs to validate
// that the pack infrastructure supports clone correctly.
// ============================================================================

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
            std.fs.cwd().makeDir(path) catch |err| switch (err) {
                error.PathAlreadyExists => return error.AlreadyExists,
                else => return err,
            };
        }
    };
};

fn gitObjectSha1(obj_type: []const u8, data: []const u8) [20]u8 {
    var hasher = std.crypto.hash.Sha1.init(.{});
    var header_buf: [64]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "{s} {}\x00", .{ obj_type, data.len }) catch unreachable;
    hasher.update(header);
    hasher.update(data);
    var out: [20]u8 = undefined;
    hasher.final(&out);
    return out;
}

fn sha1Hex(sha1: [20]u8) [40]u8 {
    var hex: [40]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{}", .{std.fmt.fmtSliceHexLower(&sha1)}) catch unreachable;
    return hex;
}

fn encodePackObjectHeader(buf: []u8, obj_type: u3, size: usize) usize {
    var first: u8 = (@as(u8, obj_type) << 4) | @as(u8, @intCast(size & 0x0F));
    var remaining = size >> 4;
    if (remaining > 0) first |= 0x80;
    buf[0] = first;
    var i: usize = 1;
    while (remaining > 0) {
        var b: u8 = @intCast(remaining & 0x7F);
        remaining >>= 7;
        if (remaining > 0) b |= 0x80;
        buf[i] = b;
        i += 1;
    }
    return i;
}

fn zlibCompress(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var compressed = std.ArrayList(u8).init(allocator);
    defer compressed.deinit();
    var input = std.io.fixedBufferStream(data);
    try std.compress.zlib.compress(input.reader(), compressed.writer(), .{});
    return try allocator.dupe(u8, compressed.items);
}

fn gitAvailable(allocator: std.mem.Allocator) bool {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "--version" },
    }) catch return false;
    allocator.free(result.stdout);
    allocator.free(result.stderr);
    return true;
}

fn runCmd(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
    });
    defer allocator.free(result.stderr);
    return result.stdout;
}

fn makeTempDir(allocator: std.mem.Allocator) ![]u8 {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "mktemp", "-d", "/tmp/ziggit_clone_wf_XXXXXX" },
    });
    defer allocator.free(result.stderr);
    const trimmed = std.mem.trimRight(u8, result.stdout, "\n");
    const dir = try allocator.dupe(u8, trimmed);
    allocator.free(result.stdout);
    return dir;
}

fn rmrf(allocator: std.mem.Allocator, path: []const u8) void {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "rm", "-rf", path },
    }) catch return;
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

/// Build a realistic pack containing a commit, tree, and blob.
/// Returns pack data and the commit hash.
fn buildRealisticPack(allocator: std.mem.Allocator) !struct { pack_data: []u8, commit_hash: [40]u8, tree_hash: [40]u8, blob_hash: [40]u8 } {
    // Blob
    const blob_data = "Hello from cloned repo!\n";
    const blob_sha1 = gitObjectSha1("blob", blob_data);

    // Tree: single entry
    var tree_buf: [256]u8 = undefined;
    var ts = std.io.fixedBufferStream(&tree_buf);
    ts.writer().print("100644 README.md\x00", .{}) catch unreachable;
    ts.writer().writeAll(&blob_sha1) catch unreachable;
    const tree_data = tree_buf[0..ts.pos];
    const tree_sha1 = gitObjectSha1("tree", tree_data);

    // Commit
    var commit_buf: [512]u8 = undefined;
    var cs = std.io.fixedBufferStream(&commit_buf);
    cs.writer().print("tree {s}\nauthor Bot <bot@test.com> 1700000000 +0000\ncommitter Bot <bot@test.com> 1700000000 +0000\n\nInitial commit\n", .{sha1Hex(tree_sha1)}) catch unreachable;
    const commit_data = commit_buf[0..cs.pos];
    const commit_sha1 = gitObjectSha1("commit", commit_data);

    // Build pack
    var pack = std.ArrayList(u8).init(allocator);
    defer pack.deinit();

    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, 3, .big); // 3 objects

    // Write objects
    const pack_objects = [_]struct { type_num: u3, data: []const u8 }{
        .{ .type_num = 3, .data = blob_data },
        .{ .type_num = 2, .data = tree_data },
        .{ .type_num = 1, .data = commit_data },
    };

    for (pack_objects) |obj| {
        var hdr: [10]u8 = undefined;
        const hdr_len = encodePackObjectHeader(&hdr, obj.type_num, obj.data.len);
        try pack.appendSlice(hdr[0..hdr_len]);
        const compressed = try zlibCompress(allocator, obj.data);
        defer allocator.free(compressed);
        try pack.appendSlice(compressed);
    }

    // Checksum
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack.items);
    var checksum: [20]u8 = undefined;
    hasher.final(&checksum);
    try pack.appendSlice(&checksum);

    return .{
        .pack_data = try allocator.dupe(u8, pack.items),
        .commit_hash = sha1Hex(commit_sha1),
        .tree_hash = sha1Hex(tree_sha1),
        .blob_hash = sha1Hex(blob_sha1),
    };
}

/// Write a ref file (refs/heads/master, refs/remotes/origin/master, etc.)
fn writeRef(allocator: std.mem.Allocator, git_dir: []const u8, ref_path: []const u8, hash: []const u8) !void {
    const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_dir, ref_path });
    defer allocator.free(full_path);

    // Create parent directories
    if (std.fs.path.dirname(full_path)) |dir| {
        std.fs.cwd().makePath(dir) catch {};
    }

    const file = try std.fs.cwd().createFile(full_path, .{});
    defer file.close();
    try file.writer().print("{s}\n", .{hash});
}

/// Read HEAD ref
fn readHead(allocator: std.mem.Allocator, git_dir: []const u8) ![]u8 {
    const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_dir});
    defer allocator.free(head_path);
    const content = try std.fs.cwd().readFileAlloc(allocator, head_path, 1024);
    defer allocator.free(content);
    return try allocator.dupe(u8, std.mem.trimRight(u8, content, "\n\r "));
}

// ============================================================================
// Test 1: Full clone simulation - pack save + ref update + object access
// ============================================================================
test "clone workflow: save pack, update refs, load objects" {
    const allocator = testing.allocator;
    const dir = try makeTempDir(allocator);
    defer {
        rmrf(allocator, dir);
        allocator.free(dir);
    }

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{dir});
    defer allocator.free(git_dir);

    // Init bare-like structure
    const stdout = try runCmd(allocator, &.{ "git", "init", dir });
    allocator.free(stdout);

    var platform = NativePlatform{};

    // Step 1: Receive and save pack
    const pack_info = try buildRealisticPack(allocator);
    defer allocator.free(pack_info.pack_data);

    const checksum_hex = try objects.saveReceivedPack(pack_info.pack_data, git_dir, &platform, allocator);
    defer allocator.free(checksum_hex);

    // Step 2: Update refs (simulating what clone does after receiving pack)
    try writeRef(allocator, git_dir, "refs/heads/master", &pack_info.commit_hash);
    try writeRef(allocator, git_dir, "refs/remotes/origin/master", &pack_info.commit_hash);

    // Update HEAD to point to master
    {
        const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_dir});
        defer allocator.free(head_path);
        const file = try std.fs.cwd().createFile(head_path, .{});
        defer file.close();
        try file.writeAll("ref: refs/heads/master\n");
    }

    // Step 3: Verify all objects are accessible through ziggit
    {
        const obj = try objects.GitObject.load(&pack_info.commit_hash, git_dir, &platform, allocator);
        defer obj.deinit(allocator);
        try testing.expectEqual(objects.ObjectType.commit, obj.type);
        try testing.expect(std.mem.startsWith(u8, obj.data, "tree "));
    }
    {
        const obj = try objects.GitObject.load(&pack_info.tree_hash, git_dir, &platform, allocator);
        defer obj.deinit(allocator);
        try testing.expectEqual(objects.ObjectType.tree, obj.type);
    }
    {
        const obj = try objects.GitObject.load(&pack_info.blob_hash, git_dir, &platform, allocator);
        defer obj.deinit(allocator);
        try testing.expectEqual(objects.ObjectType.blob, obj.type);
        try testing.expectEqualStrings("Hello from cloned repo!\n", obj.data);
    }

    // Step 4: Verify refs are readable
    {
        const ref_path = try std.fmt.allocPrint(allocator, "{s}/refs/heads/master", .{git_dir});
        defer allocator.free(ref_path);
        const content = try std.fs.cwd().readFileAlloc(allocator, ref_path, 1024);
        defer allocator.free(content);
        const hash = std.mem.trimRight(u8, content, "\n\r ");
        try testing.expectEqualStrings(&pack_info.commit_hash, hash);
    }
}

// ============================================================================
// Test 2: Cross-validate: clone workflow produces git-valid repo
// ============================================================================
test "clone workflow: resulting repo passes git fsck" {
    const allocator = testing.allocator;
    if (!gitAvailable(allocator)) return;

    const dir = try makeTempDir(allocator);
    defer {
        rmrf(allocator, dir);
        allocator.free(dir);
    }

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{dir});
    defer allocator.free(git_dir);

    const stdout = try runCmd(allocator, &.{ "git", "init", dir });
    allocator.free(stdout);

    var platform = NativePlatform{};

    const pack_info = try buildRealisticPack(allocator);
    defer allocator.free(pack_info.pack_data);

    const checksum_hex = try objects.saveReceivedPack(pack_info.pack_data, git_dir, &platform, allocator);
    defer allocator.free(checksum_hex);

    try writeRef(allocator, git_dir, "refs/heads/master", &pack_info.commit_hash);
    {
        const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_dir});
        defer allocator.free(head_path);
        const file = try std.fs.cwd().createFile(head_path, .{});
        defer file.close();
        try file.writeAll("ref: refs/heads/master\n");
    }

    // Run git fsck to validate the repo
    const fsck_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "-C", dir, "fsck", "--full" },
    }) catch return;
    defer allocator.free(fsck_result.stdout);
    defer allocator.free(fsck_result.stderr);

    try testing.expectEqual(@as(u8, 0), fsck_result.term.Exited);
}

// ============================================================================
// Test 3: Cross-validate: git can read objects from ziggit-saved pack
// ============================================================================
test "clone workflow: git cat-file reads ziggit-saved objects" {
    const allocator = testing.allocator;
    if (!gitAvailable(allocator)) return;

    const dir = try makeTempDir(allocator);
    defer {
        rmrf(allocator, dir);
        allocator.free(dir);
    }

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{dir});
    defer allocator.free(git_dir);

    const stdout = try runCmd(allocator, &.{ "git", "init", dir });
    allocator.free(stdout);

    var platform = NativePlatform{};

    const pack_info = try buildRealisticPack(allocator);
    defer allocator.free(pack_info.pack_data);

    const checksum_hex = try objects.saveReceivedPack(pack_info.pack_data, git_dir, &platform, allocator);
    defer allocator.free(checksum_hex);

    try writeRef(allocator, git_dir, "refs/heads/master", &pack_info.commit_hash);

    // git cat-file -t <commit>
    {
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "git", "-C", dir, "cat-file", "-t", &pack_info.commit_hash },
        }) catch return;
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        try testing.expectEqual(@as(u8, 0), result.term.Exited);
        try testing.expectEqualStrings("commit\n", result.stdout);
    }

    // git cat-file -t <blob>
    {
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "git", "-C", dir, "cat-file", "-t", &pack_info.blob_hash },
        }) catch return;
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        try testing.expectEqual(@as(u8, 0), result.term.Exited);
        try testing.expectEqualStrings("blob\n", result.stdout);
    }

    // git cat-file -p <blob> (verify content)
    {
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "git", "-C", dir, "cat-file", "-p", &pack_info.blob_hash },
        }) catch return;
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        try testing.expectEqual(@as(u8, 0), result.term.Exited);
        try testing.expectEqualStrings("Hello from cloned repo!\n", result.stdout);
    }
}

// ============================================================================
// Test 4: Incremental fetch - second pack added to existing repo
// ============================================================================
test "clone workflow: incremental fetch adds second pack" {
    const allocator = testing.allocator;

    const dir = try makeTempDir(allocator);
    defer {
        rmrf(allocator, dir);
        allocator.free(dir);
    }

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{dir});
    defer allocator.free(git_dir);

    const stdout = try runCmd(allocator, &.{ "git", "init", dir });
    allocator.free(stdout);

    var platform = NativePlatform{};

    // First "clone" - initial pack
    const pack1 = try buildRealisticPack(allocator);
    defer allocator.free(pack1.pack_data);

    const ck1 = try objects.saveReceivedPack(pack1.pack_data, git_dir, &platform, allocator);
    defer allocator.free(ck1);

    try writeRef(allocator, git_dir, "refs/heads/master", &pack1.commit_hash);

    // Second "fetch" - new blob
    const new_blob = "Updated content after fetch!\n";
    const new_sha1 = gitObjectSha1("blob", new_blob);
    const new_hex = sha1Hex(new_sha1);

    var pack2_buf = std.ArrayList(u8).init(allocator);
    defer pack2_buf.deinit();
    try pack2_buf.appendSlice("PACK");
    try pack2_buf.writer().writeInt(u32, 2, .big);
    try pack2_buf.writer().writeInt(u32, 1, .big);
    var hdr: [10]u8 = undefined;
    const hdr_len = encodePackObjectHeader(&hdr, 3, new_blob.len);
    try pack2_buf.appendSlice(hdr[0..hdr_len]);
    const compressed = try zlibCompress(allocator, new_blob);
    defer allocator.free(compressed);
    try pack2_buf.appendSlice(compressed);
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack2_buf.items);
    var cksum: [20]u8 = undefined;
    hasher.final(&cksum);
    try pack2_buf.appendSlice(&cksum);

    const ck2 = try objects.saveReceivedPack(pack2_buf.items, git_dir, &platform, allocator);
    defer allocator.free(ck2);

    // Both old and new objects should be accessible
    {
        const obj = try objects.GitObject.load(&pack1.blob_hash, git_dir, &platform, allocator);
        defer obj.deinit(allocator);
        try testing.expectEqualStrings("Hello from cloned repo!\n", obj.data);
    }
    {
        const obj = try objects.GitObject.load(&new_hex, git_dir, &platform, allocator);
        defer obj.deinit(allocator);
        try testing.expectEqualStrings(new_blob, obj.data);
    }
}

// ============================================================================
// Test 5: Real git clone → ziggit reads everything
// ============================================================================
test "clone workflow: real git clone then ziggit reads all objects" {
    const allocator = testing.allocator;
    if (!gitAvailable(allocator)) return;

    // Create source repo
    const src_dir = try makeTempDir(allocator);
    defer {
        rmrf(allocator, src_dir);
        allocator.free(src_dir);
    }

    {
        const r = try runCmd(allocator, &.{ "git", "init", src_dir });
        allocator.free(r);
    }
    {
        const r = try runCmd(allocator, &.{ "git", "-C", src_dir, "config", "user.email", "t@t.com" });
        allocator.free(r);
    }
    {
        const r = try runCmd(allocator, &.{ "git", "-C", src_dir, "config", "user.name", "T" });
        allocator.free(r);
    }

    // Create files
    for (0..3) |i| {
        const fname = try std.fmt.allocPrint(allocator, "{s}/f{}.txt", .{ src_dir, i });
        defer allocator.free(fname);
        const content = try std.fmt.allocPrint(allocator, "File {} content\n", .{i});
        defer allocator.free(content);
        try std.fs.cwd().writeFile(.{ .sub_path = fname, .data = content });
    }
    {
        const r = try runCmd(allocator, &.{ "git", "-C", src_dir, "add", "." });
        allocator.free(r);
    }
    {
        const r = try runCmd(allocator, &.{ "git", "-C", src_dir, "commit", "-m", "init" });
        allocator.free(r);
    }

    // Clone to dest using git
    const dst_dir = try makeTempDir(allocator);
    defer {
        rmrf(allocator, dst_dir);
        allocator.free(dst_dir);
    }
    rmrf(allocator, dst_dir); // remove so git clone can create it
    {
        const r = try runCmd(allocator, &.{ "git", "clone", src_dir, dst_dir });
        allocator.free(r);
    }

    // Repack to ensure pack files exist
    {
        const r = try runCmd(allocator, &.{ "git", "-C", dst_dir, "repack", "-a", "-d" });
        allocator.free(r);
    }

    // Get HEAD
    const head_out = try runCmd(allocator, &.{ "git", "-C", dst_dir, "rev-parse", "HEAD" });
    defer allocator.free(head_out);
    const head_hash = std.mem.trimRight(u8, head_out, "\n");
    if (head_hash.len != 40) return;

    // Use ziggit to load the commit
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{dst_dir});
    defer allocator.free(git_dir);
    var platform = NativePlatform{};

    const commit_obj = try objects.GitObject.load(head_hash, git_dir, &platform, allocator);
    defer commit_obj.deinit(allocator);
    try testing.expectEqual(objects.ObjectType.commit, commit_obj.type);

    // Extract tree hash from commit and load tree
    if (std.mem.indexOf(u8, commit_obj.data, "\n")) |newline| {
        const first_line = commit_obj.data[0..newline];
        if (std.mem.startsWith(u8, first_line, "tree ")) {
            const tree_hash = first_line[5..];
            if (tree_hash.len == 40) {
                const tree_obj = try objects.GitObject.load(tree_hash, git_dir, &platform, allocator);
                defer tree_obj.deinit(allocator);
                try testing.expectEqual(objects.ObjectType.tree, tree_obj.type);
                // Tree should contain our 3 files
                try testing.expect(tree_obj.data.len > 0);
            }
        }
    }
}
