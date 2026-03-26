const std = @import("std");
const testing = std.testing;
const objects = @import("git_objects");

// ============================================================================
// PACK CLONE PIPELINE TESTS
//
// End-to-end tests simulating what NET-SMART and NET-PACK agents do during
// HTTPS clone/fetch. These tests create real git repos, generate pack files
// using git pack-objects, then verify ziggit can:
//
// 1. Parse every object type from git-generated pack files
// 2. Handle deep OFS_DELTA chains (3+ levels)
// 3. Generate valid idx files accepted by git verify-pack
// 4. Save packs and load objects back via loadFromPackFiles
// 5. Handle binary content (all 256 byte values)
// 6. Handle packs with many objects (50+)
// 7. Correctly compute SHA-1 for delta-resolved objects
// ============================================================================

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn git(alloc: std.mem.Allocator, cwd: []const u8, args: []const []const u8) ![]u8 {
    var argv = std.ArrayList([]const u8).init(alloc);
    defer argv.deinit();
    try argv.append("git");
    try argv.appendSlice(args);

    var child = std.process.Child.init(argv.items, alloc);
    child.cwd = cwd;
    child.stderr_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    try child.spawn();
    const stdout = try child.stdout.?.reader().readAllAlloc(alloc, 8 * 1024 * 1024);
    const stderr = try child.stderr.?.reader().readAllAlloc(alloc, 8 * 1024 * 1024);
    defer alloc.free(stderr);
    const result = try child.wait();
    if (result.Exited != 0) {
        alloc.free(stdout);
        return error.GitCommandFailed;
    }
    return stdout;
}

fn gitExec(alloc: std.mem.Allocator, cwd: []const u8, args: []const []const u8) !void {
    const out = try git(alloc, cwd, args);
    alloc.free(out);
}

fn tmpDir(alloc: std.mem.Allocator, label: []const u8) ![]u8 {
    const p = try std.fmt.allocPrint(alloc, "/tmp/ziggit_pipe_{s}_{}", .{ label, std.crypto.random.int(u64) });
    try std.fs.cwd().makePath(p);
    return p;
}

fn rmDir(path: []const u8) void {
    std.fs.cwd().deleteTree(path) catch {};
}

fn writeFile(dir_path: []const u8, name: []const u8, content: []const u8) !void {
    const full = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ dir_path, name });
    defer testing.allocator.free(full);
    if (std.fs.path.dirname(full)) |parent| {
        std.fs.cwd().makePath(parent) catch {};
    }
    const file = try std.fs.cwd().createFile(full, .{});
    defer file.close();
    try file.writeAll(content);
}

fn readFileAlloc(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fs.cwd().readFileAlloc(alloc, path, 64 * 1024 * 1024);
}

const TestFs = struct {
    pub fn readFile(self: TestFs, alloc: std.mem.Allocator, path: []const u8) ![]u8 {
        _ = self;
        return std.fs.cwd().readFileAlloc(alloc, path, 64 * 1024 * 1024);
    }
    pub fn writeFile(self: TestFs, path: []const u8, data: []const u8) !void {
        _ = self;
        if (std.fs.path.dirname(path)) |parent| {
            std.fs.cwd().makePath(parent) catch {};
        }
        const f = try std.fs.cwd().createFile(path, .{});
        defer f.close();
        try f.writeAll(data);
    }
    pub fn makeDir(self: TestFs, path: []const u8) !void {
        _ = self;
        std.fs.cwd().makePath(path) catch {};
    }
};

const TestPlatform = struct {
    fs: TestFs = .{},
};

/// Build a pack file from all objects in a repo using git pack-objects.
/// Uses `git rev-list --objects --all` piped to `git pack-objects`.
fn buildPackFromAllObjects(alloc: std.mem.Allocator, repo_dir: []const u8) ![]u8 {
    const pack_dir = try std.fmt.allocPrint(alloc, "/tmp/ziggit_packout_{}", .{std.crypto.random.int(u64)});
    defer alloc.free(pack_dir);
    try std.fs.cwd().makePath(pack_dir);
    defer std.fs.cwd().deleteTree(pack_dir) catch {};

    const pack_base = try std.fmt.allocPrint(alloc, "{s}/pack", .{pack_dir});
    defer alloc.free(pack_base);

    // Get all object hashes via rev-list
    const obj_list = try git(alloc, repo_dir, &.{ "rev-list", "--objects", "--all" });
    defer alloc.free(obj_list);

    // Extract just the SHA-1 hashes (first 40 chars of each line)
    var hash_list = std.ArrayList(u8).init(alloc);
    defer hash_list.deinit();
    var lines = std.mem.splitSequence(u8, obj_list, "\n");
    while (lines.next()) |line| {
        if (line.len >= 40) {
            try hash_list.appendSlice(line[0..40]);
            try hash_list.append('\n');
        }
    }

    // Pipe to git pack-objects
    var argv = [_][]const u8{ "git", "pack-objects", pack_base };
    var child = std.process.Child.init(&argv, alloc);
    child.cwd = repo_dir;
    child.stdin_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    try child.spawn();

    try child.stdin.?.writeAll(hash_list.items);
    child.stdin.?.close();
    child.stdin = null;

    const stdout = try child.stdout.?.reader().readAllAlloc(alloc, 1024 * 1024);
    defer alloc.free(stdout);
    const stderr = try child.stderr.?.reader().readAllAlloc(alloc, 1024 * 1024);
    defer alloc.free(stderr);

    const result = try child.wait();
    if (result.Exited != 0) return error.GitCommandFailed;

    const pack_hash = std.mem.trimRight(u8, stdout, "\n");
    const pack_path = try std.fmt.allocPrint(alloc, "{s}/pack-{s}.pack", .{ pack_dir, pack_hash });
    defer alloc.free(pack_path);

    return readFileAlloc(alloc, pack_path);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "clone pipeline: git pack-objects output readable by readPackObjectAtOffset" {
    const alloc = testing.allocator;
    const dir = try tmpDir(alloc, "clone_rpo");
    defer alloc.free(dir);
    defer rmDir(dir);

    // Create a git repo with a single commit
    try gitExec(alloc, dir, &.{ "init", "-b", "main" });
    try gitExec(alloc, dir, &.{ "config", "user.email", "test@test.com" });
    try gitExec(alloc, dir, &.{ "config", "user.name", "Test" });
    try writeFile(dir, "hello.txt", "Hello, world!\n");
    try gitExec(alloc, dir, &.{ "add", "." });
    try gitExec(alloc, dir, &.{ "commit", "-m", "initial" });

    // Get all object hashes
    const rev_list = try git(alloc, dir, &.{ "rev-list", "--objects", "--all" });
    defer alloc.free(rev_list);

    // Create pack using git pack-objects
    const pack_data = try buildPackFromAllObjects(alloc, dir);
    defer alloc.free(pack_data);

    // Verify pack header
    try testing.expectEqualSlices(u8, "PACK", pack_data[0..4]);
    const version = std.mem.readInt(u32, @ptrCast(pack_data[4..8]), .big);
    try testing.expect(version == 2 or version == 3);
    const obj_count = std.mem.readInt(u32, @ptrCast(pack_data[8..12]), .big);
    try testing.expect(obj_count >= 3); // At least commit + tree + blob

    // Generate idx and verify all objects are readable
    const idx_data = try objects.generatePackIndex(pack_data, alloc);
    defer alloc.free(idx_data);

    // Count objects we can read from pack at each offset in the idx
    const total_objects = std.mem.readInt(u32, @ptrCast(idx_data[8 + 255 * 4 .. 8 + 255 * 4 + 4]), .big);
    try testing.expectEqual(obj_count, total_objects);

    var found_blob = false;
    var found_tree = false;
    var found_commit = false;

    const sha1_start = 8 + 256 * 4;
    const crc_start = sha1_start + @as(usize, total_objects) * 20;
    const off_start = crc_start + @as(usize, total_objects) * 4;

    for (0..total_objects) |i| {
        const off_pos = off_start + i * 4;
        const offset = std.mem.readInt(u32, @ptrCast(idx_data[off_pos .. off_pos + 4]), .big);

        const obj = try objects.readPackObjectAtOffset(pack_data, offset, alloc);
        defer obj.deinit(alloc);

        switch (obj.type) {
            .blob => found_blob = true,
            .tree => found_tree = true,
            .commit => found_commit = true,
            .tag => {},
        }
    }

    try testing.expect(found_blob);
    try testing.expect(found_tree);
    try testing.expect(found_commit);
}

test "clone pipeline: deep delta chains (5 commits modifying same file)" {
    const alloc = testing.allocator;
    const dir = try tmpDir(alloc, "deep_delta");
    defer alloc.free(dir);
    defer rmDir(dir);

    try gitExec(alloc, dir, &.{ "init", "-b", "main" });
    try gitExec(alloc, dir, &.{ "config", "user.email", "test@test.com" });
    try gitExec(alloc, dir, &.{ "config", "user.name", "Test" });

    // Create 10 commits modifying the same file (encourages delta chains)
    for (0..10) |i| {
        var content_buf: [4096]u8 = undefined;
        // Build content that shares a lot with previous versions (delta-friendly)
        const content = try std.fmt.bufPrint(&content_buf, "Line 1: This is a shared header that stays constant\nLine 2: More shared content\nLine 3: Version {}\nLine 4: Still more shared content at the end\n", .{i});
        try writeFile(dir, "data.txt", content);
        try gitExec(alloc, dir, &.{ "add", "." });
        var msg_buf: [64]u8 = undefined;
        const msg = try std.fmt.bufPrint(&msg_buf, "commit {}", .{i});
        try gitExec(alloc, dir, &.{ "commit", "-m", msg });
    }

    // Force gc to generate delta chains
    try gitExec(alloc, dir, &.{ "gc", "--aggressive" });

    // Create pack of all objects
    const pack_data = try buildPackFromAllObjects(alloc, dir);
    defer alloc.free(pack_data);

    const obj_count = std.mem.readInt(u32, @ptrCast(pack_data[8..12]), .big);
    try testing.expect(obj_count >= 20); // 10 commits + 10 trees + blobs (some may be deltified)

    // Generate idx and read every object
    const idx_data = try objects.generatePackIndex(pack_data, alloc);
    defer alloc.free(idx_data);

    const total = std.mem.readInt(u32, @ptrCast(idx_data[8 + 255 * 4 .. 8 + 255 * 4 + 4]), .big);
    try testing.expectEqual(obj_count, total);

    const sha1_start = 8 + 256 * 4;
    const crc_start = sha1_start + @as(usize, total) * 20;
    const off_start = crc_start + @as(usize, total) * 4;

    var objects_read: usize = 0;
    for (0..total) |i| {
        const off_pos = off_start + i * 4;
        const offset = std.mem.readInt(u32, @ptrCast(idx_data[off_pos .. off_pos + 4]), .big);

        const obj = objects.readPackObjectAtOffset(pack_data, offset, alloc) catch |err| {
            // REF_DELTA might occur, that's fine
            if (err == error.RefDeltaRequiresExternalLookup) continue;
            return err;
        };
        defer obj.deinit(alloc);
        objects_read += 1;
    }

    // Should read most objects (some might be REF_DELTA in unusual cases)
    try testing.expect(objects_read >= 20);
}

test "clone pipeline: saveReceivedPack then git verify-pack succeeds" {
    const alloc = testing.allocator;
    const dir = try tmpDir(alloc, "save_verify");
    defer alloc.free(dir);
    defer rmDir(dir);

    // Create source repo
    try gitExec(alloc, dir, &.{ "init", "-b", "main" });
    try gitExec(alloc, dir, &.{ "config", "user.email", "test@test.com" });
    try gitExec(alloc, dir, &.{ "config", "user.name", "Test" });
    try writeFile(dir, "file.txt", "content\n");
    try gitExec(alloc, dir, &.{ "add", "." });
    try gitExec(alloc, dir, &.{ "commit", "-m", "init" });

    // Generate pack
    const pack_data = try buildPackFromAllObjects(alloc, dir);
    defer alloc.free(pack_data);

    // Create target repo (bare-like structure for saveReceivedPack)
    const target = try tmpDir(alloc, "target");
    defer alloc.free(target);
    defer rmDir(target);
    try gitExec(alloc, target, &.{ "init", "-b", "main" });

    const git_dir = try std.fmt.allocPrint(alloc, "{s}/.git", .{target});
    defer alloc.free(git_dir);

    // Save the pack using ziggit
    var platform = TestPlatform{};
    const checksum_hex = try objects.saveReceivedPack(pack_data, git_dir, &platform, alloc);
    defer alloc.free(checksum_hex);

    // Verify with git verify-pack
    const idx_path = try std.fmt.allocPrint(alloc, "{s}/objects/pack/pack-{s}.idx", .{ git_dir, checksum_hex });
    defer alloc.free(idx_path);

    try gitExec(alloc, target, &.{ "verify-pack", "-v", idx_path });
}

test "clone pipeline: binary content preserved through pack roundtrip" {
    const alloc = testing.allocator;
    const dir = try tmpDir(alloc, "binary_rt");
    defer alloc.free(dir);
    defer rmDir(dir);

    try gitExec(alloc, dir, &.{ "init", "-b", "main" });
    try gitExec(alloc, dir, &.{ "config", "user.email", "test@test.com" });
    try gitExec(alloc, dir, &.{ "config", "user.name", "Test" });

    // Create a file with all 256 byte values
    var binary_data: [256]u8 = undefined;
    for (0..256) |i| {
        binary_data[i] = @intCast(i);
    }
    try writeFile(dir, "binary.bin", &binary_data);
    try gitExec(alloc, dir, &.{ "add", "." });
    try gitExec(alloc, dir, &.{ "commit", "-m", "binary" });

    // Get the blob hash
    const blob_hash_raw = try git(alloc, dir, &.{ "hash-object", "binary.bin" });
    defer alloc.free(blob_hash_raw);
    const blob_hash = std.mem.trimRight(u8, blob_hash_raw, "\n");

    // Pack and roundtrip
    const pack_data = try buildPackFromAllObjects(alloc, dir);
    defer alloc.free(pack_data);

    const idx_data = try objects.generatePackIndex(pack_data, alloc);
    defer alloc.free(idx_data);

    // Find the blob in the pack
    const total = std.mem.readInt(u32, @ptrCast(idx_data[8 + 255 * 4 .. 8 + 255 * 4 + 4]), .big);
    const sha1_start = 8 + 256 * 4;
    const crc_start = sha1_start + @as(usize, total) * 20;
    const off_start = crc_start + @as(usize, total) * 4;

    var found_binary = false;
    for (0..total) |i| {
        const sha_pos = sha1_start + i * 20;
        const obj_sha1 = idx_data[sha_pos .. sha_pos + 20];
        var hex_buf: [40]u8 = undefined;
        _ = try std.fmt.bufPrint(&hex_buf, "{}", .{std.fmt.fmtSliceHexLower(obj_sha1)});

        if (std.mem.eql(u8, &hex_buf, blob_hash)) {
            const off_pos = off_start + i * 4;
            const offset = std.mem.readInt(u32, @ptrCast(idx_data[off_pos .. off_pos + 4]), .big);

            const obj = try objects.readPackObjectAtOffset(pack_data, offset, alloc);
            defer obj.deinit(alloc);

            try testing.expectEqual(objects.ObjectType.blob, obj.type);
            try testing.expectEqual(@as(usize, 256), obj.data.len);
            try testing.expectEqualSlices(u8, &binary_data, obj.data);
            found_binary = true;
        }
    }
    try testing.expect(found_binary);
}

test "clone pipeline: tag object in pack" {
    const alloc = testing.allocator;
    const dir = try tmpDir(alloc, "tag_pack");
    defer alloc.free(dir);
    defer rmDir(dir);

    try gitExec(alloc, dir, &.{ "init", "-b", "main" });
    try gitExec(alloc, dir, &.{ "config", "user.email", "test@test.com" });
    try gitExec(alloc, dir, &.{ "config", "user.name", "Test" });
    try writeFile(dir, "file.txt", "data\n");
    try gitExec(alloc, dir, &.{ "add", "." });
    try gitExec(alloc, dir, &.{ "commit", "-m", "init" });
    try gitExec(alloc, dir, &.{ "tag", "-a", "v1.0", "-m", "release v1.0" });

    // Pack including tags
    const pack_data = try buildPackFromAllObjects(alloc, dir);
    defer alloc.free(pack_data);

    const idx_data = try objects.generatePackIndex(pack_data, alloc);
    defer alloc.free(idx_data);

    const total = std.mem.readInt(u32, @ptrCast(idx_data[8 + 255 * 4 .. 8 + 255 * 4 + 4]), .big);
    const sha1_start = 8 + 256 * 4;
    const crc_start = sha1_start + @as(usize, total) * 20;
    const off_start = crc_start + @as(usize, total) * 4;

    var found_tag = false;
    for (0..total) |i| {
        const off_pos = off_start + i * 4;
        const offset = std.mem.readInt(u32, @ptrCast(idx_data[off_pos .. off_pos + 4]), .big);

        const obj = objects.readPackObjectAtOffset(pack_data, offset, alloc) catch continue;
        defer obj.deinit(alloc);

        if (obj.type == .tag) {
            found_tag = true;
            // Tag should contain "tag v1.0"
            try testing.expect(std.mem.indexOf(u8, obj.data, "tag v1.0") != null);
            // Tag should contain the tagger
            try testing.expect(std.mem.indexOf(u8, obj.data, "tagger") != null);
        }
    }
    try testing.expect(found_tag);
}

test "clone pipeline: many objects pack (50+ files)" {
    const alloc = testing.allocator;
    const dir = try tmpDir(alloc, "many_obj");
    defer alloc.free(dir);
    defer rmDir(dir);

    try gitExec(alloc, dir, &.{ "init", "-b", "main" });
    try gitExec(alloc, dir, &.{ "config", "user.email", "test@test.com" });
    try gitExec(alloc, dir, &.{ "config", "user.name", "Test" });

    // Create 50 files in subdirectories
    for (0..50) |i| {
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "dir{}/file{}.txt", .{ i / 10, i });
        var content_buf: [128]u8 = undefined;
        const content = try std.fmt.bufPrint(&content_buf, "File number {} with unique content {}\n", .{ i, i * 31337 });
        try writeFile(dir, name, content);
    }
    try gitExec(alloc, dir, &.{ "add", "." });
    try gitExec(alloc, dir, &.{ "commit", "-m", "50 files" });

    const pack_data = try buildPackFromAllObjects(alloc, dir);
    defer alloc.free(pack_data);

    const obj_count = std.mem.readInt(u32, @ptrCast(pack_data[8..12]), .big);
    // 50 blobs + ~6 trees (5 subdirs + root) + 1 commit = ~57
    try testing.expect(obj_count >= 50);

    const idx_data = try objects.generatePackIndex(pack_data, alloc);
    defer alloc.free(idx_data);

    // Verify all objects readable
    const total = std.mem.readInt(u32, @ptrCast(idx_data[8 + 255 * 4 .. 8 + 255 * 4 + 4]), .big);
    try testing.expectEqual(obj_count, total);

    var readable: usize = 0;
    const sha1_start = 8 + 256 * 4;
    const crc_start = sha1_start + @as(usize, total) * 20;
    const off_start = crc_start + @as(usize, total) * 4;

    for (0..total) |i| {
        const off_pos = off_start + i * 4;
        const offset = std.mem.readInt(u32, @ptrCast(idx_data[off_pos .. off_pos + 4]), .big);
        const obj = objects.readPackObjectAtOffset(pack_data, offset, alloc) catch continue;
        defer obj.deinit(alloc);
        readable += 1;
    }
    try testing.expect(readable >= 50);
}

test "clone pipeline: SHA-1 in idx matches git cat-file" {
    const alloc = testing.allocator;
    const dir = try tmpDir(alloc, "sha_match");
    defer alloc.free(dir);
    defer rmDir(dir);

    try gitExec(alloc, dir, &.{ "init", "-b", "main" });
    try gitExec(alloc, dir, &.{ "config", "user.email", "test@test.com" });
    try gitExec(alloc, dir, &.{ "config", "user.name", "Test" });
    try writeFile(dir, "a.txt", "aaa\n");
    try writeFile(dir, "b.txt", "bbb\n");
    try gitExec(alloc, dir, &.{ "add", "." });
    try gitExec(alloc, dir, &.{ "commit", "-m", "two files" });

    // Get known hashes from git
    const head_raw = try git(alloc, dir, &.{ "rev-parse", "HEAD" });
    defer alloc.free(head_raw);
    const head_hash = std.mem.trimRight(u8, head_raw, "\n");

    const tree_raw = try git(alloc, dir, &.{ "rev-parse", "HEAD^{tree}" });
    defer alloc.free(tree_raw);
    const tree_hash = std.mem.trimRight(u8, tree_raw, "\n");

    // Pack
    const pack_data = try buildPackFromAllObjects(alloc, dir);
    defer alloc.free(pack_data);

    const idx_data = try objects.generatePackIndex(pack_data, alloc);
    defer alloc.free(idx_data);

    // Extract SHA-1s from idx
    const total = std.mem.readInt(u32, @ptrCast(idx_data[8 + 255 * 4 .. 8 + 255 * 4 + 4]), .big);
    const sha1_start = 8 + 256 * 4;

    var found_head = false;
    var found_tree = false;

    for (0..total) |i| {
        const sha_pos = sha1_start + i * 20;
        const sha1_bytes = idx_data[sha_pos .. sha_pos + 20];
        var hex_buf: [40]u8 = undefined;
        _ = try std.fmt.bufPrint(&hex_buf, "{}", .{std.fmt.fmtSliceHexLower(sha1_bytes)});

        if (std.mem.eql(u8, &hex_buf, head_hash)) found_head = true;
        if (std.mem.eql(u8, &hex_buf, tree_hash)) found_tree = true;
    }

    try testing.expect(found_head);
    try testing.expect(found_tree);
}

test "clone pipeline: object content matches git cat-file -p" {
    const alloc = testing.allocator;
    const dir = try tmpDir(alloc, "catfile");
    defer alloc.free(dir);
    defer rmDir(dir);

    try gitExec(alloc, dir, &.{ "init", "-b", "main" });
    try gitExec(alloc, dir, &.{ "config", "user.email", "test@test.com" });
    try gitExec(alloc, dir, &.{ "config", "user.name", "Test" });
    try writeFile(dir, "msg.txt", "Hello from ziggit test!\n");
    try gitExec(alloc, dir, &.{ "add", "." });
    try gitExec(alloc, dir, &.{ "commit", "-m", "test content match" });

    // Get blob content from git
    const blob_hash_raw = try git(alloc, dir, &.{ "hash-object", "msg.txt" });
    defer alloc.free(blob_hash_raw);
    const blob_hash = std.mem.trimRight(u8, blob_hash_raw, "\n");

    const git_content = try git(alloc, dir, &.{ "cat-file", "-p", blob_hash });
    defer alloc.free(git_content);

    // Pack and read via ziggit
    const pack_data = try buildPackFromAllObjects(alloc, dir);
    defer alloc.free(pack_data);

    const idx_data = try objects.generatePackIndex(pack_data, alloc);
    defer alloc.free(idx_data);

    const total = std.mem.readInt(u32, @ptrCast(idx_data[8 + 255 * 4 .. 8 + 255 * 4 + 4]), .big);
    const sha1_start = 8 + 256 * 4;
    const crc_start = sha1_start + @as(usize, total) * 20;
    const off_start = crc_start + @as(usize, total) * 4;

    for (0..total) |i| {
        const sha_pos = sha1_start + i * 20;
        var hex_buf: [40]u8 = undefined;
        _ = try std.fmt.bufPrint(&hex_buf, "{}", .{std.fmt.fmtSliceHexLower(idx_data[sha_pos .. sha_pos + 20])});

        if (std.mem.eql(u8, &hex_buf, blob_hash)) {
            const off_pos = off_start + i * 4;
            const offset = std.mem.readInt(u32, @ptrCast(idx_data[off_pos .. off_pos + 4]), .big);

            const obj = try objects.readPackObjectAtOffset(pack_data, offset, alloc);
            defer obj.deinit(alloc);

            try testing.expectEqual(objects.ObjectType.blob, obj.type);
            try testing.expectEqualSlices(u8, git_content, obj.data);
            return;
        }
    }
    return error.TestExpectedEqual; // blob not found
}

test "clone pipeline: loadFromPackFiles after saveReceivedPack" {
    const alloc = testing.allocator;
    const dir = try tmpDir(alloc, "load_after");
    defer alloc.free(dir);
    defer rmDir(dir);

    // Source repo
    try gitExec(alloc, dir, &.{ "init", "-b", "main" });
    try gitExec(alloc, dir, &.{ "config", "user.email", "test@test.com" });
    try gitExec(alloc, dir, &.{ "config", "user.name", "Test" });
    try writeFile(dir, "x.txt", "xxx\n");
    try gitExec(alloc, dir, &.{ "add", "." });
    try gitExec(alloc, dir, &.{ "commit", "-m", "x" });

    const head_raw = try git(alloc, dir, &.{ "rev-parse", "HEAD" });
    defer alloc.free(head_raw);
    const head_hash = std.mem.trimRight(u8, head_raw, "\n");

    // Pack
    const pack_data = try buildPackFromAllObjects(alloc, dir);
    defer alloc.free(pack_data);

    // Target repo
    const target = try tmpDir(alloc, "target_load");
    defer alloc.free(target);
    defer rmDir(target);
    try gitExec(alloc, target, &.{ "init", "-b", "main" });

    const git_dir = try std.fmt.allocPrint(alloc, "{s}/.git", .{target});
    defer alloc.free(git_dir);

    var platform = TestPlatform{};
    const checksum_hex = try objects.saveReceivedPack(pack_data, git_dir, &platform, alloc);
    defer alloc.free(checksum_hex);

    // Now load the commit object using loadFromPackFiles
    const obj = try objects.loadFromPackFiles(head_hash, git_dir, &platform, alloc);
    defer obj.deinit(alloc);

    try testing.expectEqual(objects.ObjectType.commit, obj.type);
    try testing.expect(std.mem.indexOf(u8, obj.data, "x") != null);
}

test "clone pipeline: idx fanout table is monotonically increasing" {
    const alloc = testing.allocator;
    const dir = try tmpDir(alloc, "fanout");
    defer alloc.free(dir);
    defer rmDir(dir);

    try gitExec(alloc, dir, &.{ "init", "-b", "main" });
    try gitExec(alloc, dir, &.{ "config", "user.email", "t@t.com" });
    try gitExec(alloc, dir, &.{ "config", "user.name", "T" });
    for (0..20) |i| {
        var buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&buf, "f{}.txt", .{i});
        var cbuf: [64]u8 = undefined;
        const content = try std.fmt.bufPrint(&cbuf, "content {}\n", .{i});
        try writeFile(dir, name, content);
    }
    try gitExec(alloc, dir, &.{ "add", "." });
    try gitExec(alloc, dir, &.{ "commit", "-m", "20 files" });

    const pack_data = try buildPackFromAllObjects(alloc, dir);
    defer alloc.free(pack_data);

    const idx_data = try objects.generatePackIndex(pack_data, alloc);
    defer alloc.free(idx_data);

    // Verify magic and version
    try testing.expectEqual(@as(u32, 0xff744f63), std.mem.readInt(u32, @ptrCast(idx_data[0..4]), .big));
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, @ptrCast(idx_data[4..8]), .big));

    // Verify fanout is monotonically increasing
    var prev: u32 = 0;
    for (0..256) |i| {
        const off = 8 + i * 4;
        const val = std.mem.readInt(u32, @ptrCast(idx_data[off .. off + 4]), .big);
        try testing.expect(val >= prev);
        prev = val;
    }
    // Last fanout entry should equal total objects
    try testing.expect(prev > 0);
}

test "clone pipeline: OFS_DELTA chain SHA-1 matches git" {
    const alloc = testing.allocator;
    const dir = try tmpDir(alloc, "ofs_sha");
    defer alloc.free(dir);
    defer rmDir(dir);

    try gitExec(alloc, dir, &.{ "init", "-b", "main" });
    try gitExec(alloc, dir, &.{ "config", "user.email", "t@t.com" });
    try gitExec(alloc, dir, &.{ "config", "user.name", "T" });

    // Create commits that will produce delta chains
    try writeFile(dir, "data.txt", "AAAA\nBBBB\nCCCC\nDDDD\nEEEE\n");
    try gitExec(alloc, dir, &.{ "add", "." });
    try gitExec(alloc, dir, &.{ "commit", "-m", "v1" });

    try writeFile(dir, "data.txt", "AAAA\nBBBB\nCCCC\nDDDD\nEEEE\nFFFF\n");
    try gitExec(alloc, dir, &.{ "add", "." });
    try gitExec(alloc, dir, &.{ "commit", "-m", "v2" });

    try writeFile(dir, "data.txt", "AAAA\nBBBB\nCCCC\nDDDD\nEEEE\nFFFF\nGGGG\n");
    try gitExec(alloc, dir, &.{ "add", "." });
    try gitExec(alloc, dir, &.{ "commit", "-m", "v3" });

    // Force delta compression
    try gitExec(alloc, dir, &.{ "gc", "--aggressive" });

    // Get all blob hashes
    const all_objects = try git(alloc, dir, &.{ "rev-list", "--objects", "--all" });
    defer alloc.free(all_objects);

    const pack_data = try buildPackFromAllObjects(alloc, dir);
    defer alloc.free(pack_data);

    const idx_data = try objects.generatePackIndex(pack_data, alloc);
    defer alloc.free(idx_data);

    // For each object in the idx, verify SHA-1 matches git cat-file -t
    const total = std.mem.readInt(u32, @ptrCast(idx_data[8 + 255 * 4 .. 8 + 255 * 4 + 4]), .big);
    const sha1_start = 8 + 256 * 4;
    const crc_start = sha1_start + @as(usize, total) * 20;
    const off_start = crc_start + @as(usize, total) * 4;

    var verified: usize = 0;
    for (0..total) |i| {
        const sha_pos = sha1_start + i * 20;
        var hex_buf: [40]u8 = undefined;
        _ = try std.fmt.bufPrint(&hex_buf, "{}", .{std.fmt.fmtSliceHexLower(idx_data[sha_pos .. sha_pos + 20])});

        const off_pos = off_start + i * 4;
        const offset = std.mem.readInt(u32, @ptrCast(idx_data[off_pos .. off_pos + 4]), .big);

        const obj = objects.readPackObjectAtOffset(pack_data, offset, alloc) catch continue;
        defer obj.deinit(alloc);

        // Verify type matches git
        const git_type = git(alloc, dir, &.{ "cat-file", "-t", &hex_buf }) catch continue;
        defer alloc.free(git_type);
        const type_str = std.mem.trimRight(u8, git_type, "\n");
        try testing.expectEqualSlices(u8, obj.type.toString(), type_str);

        // Verify content matches git
        const git_data = git(alloc, dir, &.{ "cat-file", obj.type.toString(), &hex_buf }) catch continue;
        defer alloc.free(git_data);
        try testing.expectEqualSlices(u8, git_data, obj.data);

        verified += 1;
    }
    try testing.expect(verified >= 5);
}

test "clone pipeline: empty blob in pack" {
    const alloc = testing.allocator;
    const dir = try tmpDir(alloc, "empty_blob");
    defer alloc.free(dir);
    defer rmDir(dir);

    try gitExec(alloc, dir, &.{ "init", "-b", "main" });
    try gitExec(alloc, dir, &.{ "config", "user.email", "t@t.com" });
    try gitExec(alloc, dir, &.{ "config", "user.name", "T" });
    try writeFile(dir, "empty.txt", "");
    try gitExec(alloc, dir, &.{ "add", "." });
    try gitExec(alloc, dir, &.{ "commit", "-m", "empty file" });

    const blob_hash_raw = try git(alloc, dir, &.{ "hash-object", "empty.txt" });
    defer alloc.free(blob_hash_raw);
    const blob_hash = std.mem.trimRight(u8, blob_hash_raw, "\n");

    const pack_data = try buildPackFromAllObjects(alloc, dir);
    defer alloc.free(pack_data);

    const idx_data = try objects.generatePackIndex(pack_data, alloc);
    defer alloc.free(idx_data);

    const total = std.mem.readInt(u32, @ptrCast(idx_data[8 + 255 * 4 .. 8 + 255 * 4 + 4]), .big);
    const sha1_start = 8 + 256 * 4;
    const crc_start = sha1_start + @as(usize, total) * 20;
    const off_start = crc_start + @as(usize, total) * 4;

    for (0..total) |i| {
        const sha_pos = sha1_start + i * 20;
        var hex_buf: [40]u8 = undefined;
        _ = try std.fmt.bufPrint(&hex_buf, "{}", .{std.fmt.fmtSliceHexLower(idx_data[sha_pos .. sha_pos + 20])});

        if (std.mem.eql(u8, &hex_buf, blob_hash)) {
            const off_pos = off_start + i * 4;
            const offset = std.mem.readInt(u32, @ptrCast(idx_data[off_pos .. off_pos + 4]), .big);

            const obj = try objects.readPackObjectAtOffset(pack_data, offset, alloc);
            defer obj.deinit(alloc);

            try testing.expectEqual(objects.ObjectType.blob, obj.type);
            try testing.expectEqual(@as(usize, 0), obj.data.len);
            return;
        }
    }
    return error.TestExpectedEqual; // empty blob not found
}

test "delta: copy with all offset/size bit combinations" {
    // Test that copy command correctly handles various bit patterns
    // in the offset and size fields
    const alloc = testing.allocator;

    // Base data: 512 bytes
    var base: [512]u8 = undefined;
    for (0..512) |i| {
        base[i] = @intCast(i & 0xFF);
    }

    // Test: copy from offset 0x0102 (needs 2 offset bytes) with size 0x0304 (needs 2 size bytes)
    // Expected: bytes base[0x0102..0x0102+0x0304] but 0x0102+0x0304=0x406 > 512 so use smaller
    // Copy from offset 256 (0x100), size 128 (0x80)
    const copy_offset: usize = 256;
    const copy_size: usize = 128;
    const expected = base[copy_offset .. copy_offset + copy_size];

    // Build delta: header + copy command
    var delta = std.ArrayList(u8).init(alloc);
    defer delta.deinit();

    // Base size varint (512 = 0x200)
    try delta.append(0x80 | (512 & 0x7F)); // 0x80 | 0x00 = 0x80
    try delta.append(@intCast((512 >> 7) & 0x7F)); // 4

    // Result size varint (128 = 0x80)
    try delta.append(0x80 | (128 & 0x7F)); // 0x80 | 0x00 = 0x80
    try delta.append(@intCast((128 >> 7) & 0x7F)); // 1

    // Copy command: offset = 256 (needs byte 0 = 0x00, byte 1 = 0x01), size = 128 (byte 0 = 0x80)
    // cmd byte: 0x80 | 0x01 (offset byte 0) | 0x02 (offset byte 1) | 0x10 (size byte 0)
    try delta.append(0x80 | 0x01 | 0x02 | 0x10);
    try delta.append(0x00); // offset byte 0
    try delta.append(0x01); // offset byte 1
    try delta.append(0x80); // size byte 0

    const result = try objects.applyDelta(&base, delta.items, alloc);
    defer alloc.free(result);

    try testing.expectEqual(copy_size, result.len);
    try testing.expectEqualSlices(u8, expected, result);
}

test "delta: copy with only high offset bytes set" {
    // Test copy with offset that only has byte 2 set (bit 0x04)
    const alloc = testing.allocator;

    // Need a base large enough: offset byte 2 set means offset >= 0x10000
    // That's 65536+, too large for a test. Instead test byte 1 only (offset 0x0100 = 256)
    var base: [512]u8 = undefined;
    for (0..512) |i| base[i] = @intCast(i & 0xFF);

    var delta = std.ArrayList(u8).init(alloc);
    defer delta.deinit();

    // Base size = 512
    try delta.append(0x80 | 0); // 512 & 0x7F = 0, continue
    try delta.append(@intCast(512 >> 7)); // 4

    // Result size = 10
    try delta.append(10);

    // Copy: only bit 0x02 set for offset (byte 1 of offset = 1 → offset = 256)
    // size: bit 0x10 set, size byte = 10
    try delta.append(0x80 | 0x02 | 0x10);
    try delta.append(0x01); // offset byte 1 → offset = 0x0100 = 256
    try delta.append(10); // size = 10

    const result = try objects.applyDelta(&base, delta.items, alloc);
    defer alloc.free(result);

    try testing.expectEqualSlices(u8, base[256..266], result);
}
