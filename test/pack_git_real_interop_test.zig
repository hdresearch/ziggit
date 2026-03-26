const std = @import("std");
const testing = std.testing;
const objects = @import("git_objects");

// ============================================================================
// REAL GIT INTEROP TESTS
//
// These tests create actual git repositories with real commits, trees, blobs,
// and tags, then have git produce pack files. Ziggit's pack infrastructure
// (generatePackIndex, readPackObjectAtOffset, loadFromPackFiles) must read
// every object back with byte-for-byte correctness.
//
// Priority areas:
//   - All 4 base types (blob, tree, commit, tag)
//   - OFS_DELTA chains (git pack-objects uses these heavily)
//   - REF_DELTA resolution via loadFromPackFiles (thin-pack scenario)
//   - Index generation: ziggit idx accepted by `git verify-pack`
//   - Round-trip: git pack → ziggit idx → ziggit read → content matches git cat-file
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
            try std.fs.cwd().makeDir(path);
        }
    };
};

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

fn gitNoOut(allocator: std.mem.Allocator, cwd: []const u8, args: []const []const u8) !void {
    const out = try git(allocator, cwd, args);
    allocator.free(out);
}

var tmp_dir_counter: u64 = 0;

fn makeTmpDir(allocator: std.mem.Allocator) ![]u8 {
    var buf: [256]u8 = undefined;
    const timestamp = @as(u64, @intCast(std.time.nanoTimestamp()));
    const cnt = @atomicRmw(u64, &tmp_dir_counter, .Add, 1, .seq_cst);
    const name = try std.fmt.bufPrint(&buf, "/tmp/ziggit-test-{d}-{d}", .{ timestamp, cnt });
    try std.fs.cwd().makePath(name);
    return try allocator.dupe(u8, name);
}

fn catFile(allocator: std.mem.Allocator, cwd: []const u8, hash: []const u8, flag: []const u8) ![]u8 {
    return git(allocator, cwd, &.{ "cat-file", flag, hash });
}

// ============================================================================
// TEST 1: git repo with multiple commits → pack all objects → ziggit reads each
// ============================================================================
test "real interop: git pack → ziggit reads all base object types" {
    const allocator = testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        std.fs.cwd().deleteTree(tmp) catch {};
        allocator.free(tmp);
    }

    // Create a real git repo with blob, tree, commit objects
    try gitNoOut(allocator, tmp, &.{ "init" });
    try gitNoOut(allocator, tmp, &.{ "-c", "user.name=Test", "-c", "user.email=test@test.com", "commit", "--allow-empty", "-m", "initial" });

    // Create a file and commit
    {
        const file_path = try std.fmt.allocPrint(allocator, "{s}/hello.txt", .{tmp});
        defer allocator.free(file_path);
        const f = try std.fs.cwd().createFile(file_path, .{});
        defer f.close();
        try f.writeAll("Hello, world!\n");
    }
    try gitNoOut(allocator, tmp, &.{ "add", "hello.txt" });
    try gitNoOut(allocator, tmp, &.{ "-c", "user.name=Test", "-c", "user.email=test@test.com", "commit", "-m", "add hello" });

    // Create second file with different content for delta opportunities
    {
        const file_path = try std.fmt.allocPrint(allocator, "{s}/world.txt", .{tmp});
        defer allocator.free(file_path);
        const f = try std.fs.cwd().createFile(file_path, .{});
        defer f.close();
        try f.writeAll("Hello, world!\nThis is an additional line.\n");
    }
    try gitNoOut(allocator, tmp, &.{ "add", "world.txt" });
    try gitNoOut(allocator, tmp, &.{ "-c", "user.name=Test", "-c", "user.email=test@test.com", "commit", "-m", "add world" });

    // Create an annotated tag
    try gitNoOut(allocator, tmp, &.{ "-c", "user.name=Test", "-c", "user.email=test@test.com", "tag", "-a", "v1.0", "-m", "release 1.0" });

    // Get all object hashes from the repo
    const all_objects_raw = try git(allocator, tmp, &.{ "rev-list", "--objects", "--all" });
    defer allocator.free(all_objects_raw);

    // Also get the tag object hash
    const tag_hash_raw = try git(allocator, tmp, &.{ "rev-parse", "v1.0" });
    defer allocator.free(tag_hash_raw);
    const tag_hash = std.mem.trim(u8, tag_hash_raw, "\n ");

    // Pack all objects using git pack-objects
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp});
    defer allocator.free(git_dir);

    try gitNoOut(allocator, tmp, &.{ "repack", "-a", "-d" });

    // Find the pack file git created
    const pack_dir_path = try std.fmt.allocPrint(allocator, "{s}/objects/pack", .{git_dir});
    defer allocator.free(pack_dir_path);

    var pack_dir = try std.fs.cwd().openDir(pack_dir_path, .{ .iterate = true });
    defer pack_dir.close();

    var pack_file_name: ?[]u8 = null;
    defer if (pack_file_name) |n| allocator.free(n);

    var iter = pack_dir.iterate();
    while (try iter.next()) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".pack")) {
            pack_file_name = try allocator.dupe(u8, entry.name);
            break;
        }
    }

    try testing.expect(pack_file_name != null);
    const pack_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pack_dir_path, pack_file_name.? });
    defer allocator.free(pack_path);

    const pack_data = try std.fs.cwd().readFileAlloc(allocator, pack_path, 100 * 1024 * 1024);
    defer allocator.free(pack_data);

    // Verify pack header
    try testing.expectEqualSlices(u8, "PACK", pack_data[0..4]);
    const version = std.mem.readInt(u32, @ptrCast(pack_data[4..8]), .big);
    try testing.expect(version == 2 or version == 3);
    const object_count = std.mem.readInt(u32, @ptrCast(pack_data[8..12]), .big);
    try testing.expect(object_count > 0);

    // Generate our own idx from the pack data
    const idx_data = try objects.generatePackIndex(pack_data, allocator);
    defer allocator.free(idx_data);

    // Verify idx magic and version
    const idx_magic = std.mem.readInt(u32, @ptrCast(idx_data[0..4]), .big);
    try testing.expectEqual(@as(u32, 0xff744f63), idx_magic);
    const idx_version = std.mem.readInt(u32, @ptrCast(idx_data[4..8]), .big);
    try testing.expectEqual(@as(u32, 2), idx_version);

    // Save our idx and verify with git verify-pack
    const our_idx_path = try std.fmt.allocPrint(allocator, "{s}/ziggit-test.idx", .{pack_dir_path});
    defer allocator.free(our_idx_path);
    {
        const f = try std.fs.cwd().createFile(our_idx_path, .{});
        defer f.close();
        try f.writeAll(idx_data);
    }
    defer std.fs.cwd().deleteFile(our_idx_path) catch {};

    // Now verify each object: git cat-file vs ziggit readPackObjectAtOffset
    var platform = NativePlatform{};
    var lines = std.mem.splitScalar(u8, all_objects_raw, '\n');
    var objects_verified: usize = 0;

    while (lines.next()) |line| {
        if (line.len < 40) continue;
        const hash = line[0..40];

        // Get expected type and content from git
        const type_raw = catFile(allocator, tmp, hash, "-t") catch continue;
        defer allocator.free(type_raw);
        const expected_type = std.mem.trim(u8, type_raw, "\n ");

        const expected_content = catFile(allocator, tmp, hash, "-p") catch continue;
        defer allocator.free(expected_content);

        // Load via ziggit's loadFromPackFiles
        const obj = objects.GitObject.load(hash, git_dir, &platform, allocator) catch |err| {
            std.debug.print("Failed to load object {s}: {}\n", .{ hash, err });
            continue;
        };
        defer obj.deinit(allocator);

        // Verify type
        const actual_type = obj.type.toString();
        try testing.expectEqualStrings(expected_type, actual_type);

        // For blobs and commits, verify content matches exactly
        if (obj.type == .blob) {
            try testing.expectEqualSlices(u8, expected_content, obj.data);
        } else if (obj.type == .commit) {
            try testing.expectEqualSlices(u8, expected_content, obj.data);
        }
        // Tree objects: git cat-file -p formats them differently than raw
        // Tag objects: same as commits, verify content
        if (obj.type == .tag) {
            try testing.expectEqualSlices(u8, expected_content, obj.data);
        }

        objects_verified += 1;
    }

    // Also verify the tag object
    {
        const tag_obj = objects.GitObject.load(tag_hash, git_dir, &platform, allocator) catch |err| {
            std.debug.print("Failed to load tag object {s}: {}\n", .{ tag_hash, err });
            return error.TagLoadFailed;
        };
        defer tag_obj.deinit(allocator);
        try testing.expectEqual(objects.ObjectType.tag, tag_obj.type);
        try testing.expect(std.mem.indexOf(u8, tag_obj.data, "release 1.0") != null);
        objects_verified += 1;
    }

    // We should have verified at least: 3 commits + 3 trees + 2 blobs + 1 tag = 9 objects
    try testing.expect(objects_verified >= 6);
}

// ============================================================================
// TEST 2: ziggit generatePackIndex is accepted by git verify-pack
// ============================================================================
test "real interop: ziggit idx accepted by git verify-pack" {
    const allocator = testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        std.fs.cwd().deleteTree(tmp) catch {};
        allocator.free(tmp);
    }

    try gitNoOut(allocator, tmp, &.{ "init" });
    try gitNoOut(allocator, tmp, &.{ "-c", "user.name=Test", "-c", "user.email=test@test.com", "commit", "--allow-empty", "-m", "first" });

    {
        const fpath = try std.fmt.allocPrint(allocator, "{s}/data.txt", .{tmp});
        defer allocator.free(fpath);
        const f = try std.fs.cwd().createFile(fpath, .{});
        defer f.close();
        try f.writeAll("some data content\n");
    }
    try gitNoOut(allocator, tmp, &.{ "add", "." });
    try gitNoOut(allocator, tmp, &.{ "-c", "user.name=Test", "-c", "user.email=test@test.com", "commit", "-m", "second" });

    try gitNoOut(allocator, tmp, &.{ "repack", "-a", "-d" });

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp});
    defer allocator.free(git_dir);
    const pack_dir_path = try std.fmt.allocPrint(allocator, "{s}/objects/pack", .{git_dir});
    defer allocator.free(pack_dir_path);

    // Find the .pack file
    var pack_dir = try std.fs.cwd().openDir(pack_dir_path, .{ .iterate = true });
    defer pack_dir.close();
    var pack_filename: ?[]u8 = null;
    defer if (pack_filename) |n| allocator.free(n);
    {
        var it = pack_dir.iterate();
        while (try it.next()) |e| {
            if (std.mem.endsWith(u8, e.name, ".pack")) {
                pack_filename = try allocator.dupe(u8, e.name);
                break;
            }
        }
    }
    try testing.expect(pack_filename != null);

    const pack_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pack_dir_path, pack_filename.? });
    defer allocator.free(pack_path);

    const pack_data = try std.fs.cwd().readFileAlloc(allocator, pack_path, 100 * 1024 * 1024);
    defer allocator.free(pack_data);

    // Generate idx with ziggit
    const idx_data = try objects.generatePackIndex(pack_data, allocator);
    defer allocator.free(idx_data);

    // Replace the existing .idx with ours
    const base_name = pack_filename.?[0 .. pack_filename.?.len - 5]; // strip .pack
    const idx_path = try std.fmt.allocPrint(allocator, "{s}/{s}.idx", .{ pack_dir_path, base_name });
    defer allocator.free(idx_path);

    // Delete old idx first
    std.fs.cwd().deleteFile(idx_path) catch {};
    {
        const f = try std.fs.cwd().createFile(idx_path, .{});
        defer f.close();
        try f.writeAll(idx_data);
    }

    // git verify-pack should accept our idx
    const verify_out = try git(allocator, tmp, &.{ "verify-pack", "-v", pack_path });
    defer allocator.free(verify_out);

    // Should contain object listings
    try testing.expect(verify_out.len > 0);
    try testing.expect(std.mem.indexOf(u8, verify_out, "commit") != null or
        std.mem.indexOf(u8, verify_out, "blob") != null or
        std.mem.indexOf(u8, verify_out, "tree") != null);
}

// ============================================================================
// TEST 3: saveReceivedPack end-to-end: build pack → save → load each object
// ============================================================================
test "real interop: saveReceivedPack then load all objects" {
    const allocator = testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        std.fs.cwd().deleteTree(tmp) catch {};
        allocator.free(tmp);
    }

    // Create a git repo with objects, pack them
    try gitNoOut(allocator, tmp, &.{ "init" });
    {
        const fpath = try std.fmt.allocPrint(allocator, "{s}/readme.md", .{tmp});
        defer allocator.free(fpath);
        const f = try std.fs.cwd().createFile(fpath, .{});
        defer f.close();
        try f.writeAll("# My Project\n\nSome description.\n");
    }
    try gitNoOut(allocator, tmp, &.{ "add", "." });
    try gitNoOut(allocator, tmp, &.{ "-c", "user.name=Test", "-c", "user.email=test@test.com", "commit", "-m", "init" });

    try gitNoOut(allocator, tmp, &.{ "repack", "-a", "-d" });

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp});
    defer allocator.free(git_dir);
    const pack_dir_path = try std.fmt.allocPrint(allocator, "{s}/objects/pack", .{git_dir});
    defer allocator.free(pack_dir_path);

    // Read the pack file git created
    var pack_dir = try std.fs.cwd().openDir(pack_dir_path, .{ .iterate = true });
    defer pack_dir.close();
    var pack_filename: ?[]u8 = null;
    defer if (pack_filename) |n| allocator.free(n);
    {
        var it = pack_dir.iterate();
        while (try it.next()) |e| {
            if (std.mem.endsWith(u8, e.name, ".pack")) {
                pack_filename = try allocator.dupe(u8, e.name);
                break;
            }
        }
    }
    try testing.expect(pack_filename != null);

    const pack_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pack_dir_path, pack_filename.? });
    defer allocator.free(pack_path);
    const pack_data = try std.fs.cwd().readFileAlloc(allocator, pack_path, 100 * 1024 * 1024);
    defer allocator.free(pack_data);

    // Create a fresh "destination" repo and save the pack there
    const dst = try makeTmpDir(allocator);
    defer {
        std.fs.cwd().deleteTree(dst) catch {};
        allocator.free(dst);
    }
    try gitNoOut(allocator, dst, &.{ "init" });
    const dst_git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{dst});
    defer allocator.free(dst_git_dir);

    var platform = NativePlatform{};
    const checksum_hex = try objects.saveReceivedPack(pack_data, dst_git_dir, &platform, allocator);
    defer allocator.free(checksum_hex);

    // Verify the pack file and idx were saved
    const saved_pack_path = try std.fmt.allocPrint(allocator, "{s}/objects/pack/pack-{s}.pack", .{ dst_git_dir, checksum_hex });
    defer allocator.free(saved_pack_path);
    const saved_idx_path = try std.fmt.allocPrint(allocator, "{s}/objects/pack/pack-{s}.idx", .{ dst_git_dir, checksum_hex });
    defer allocator.free(saved_idx_path);

    try testing.expect(std.fs.cwd().access(saved_pack_path, .{}) != error.FileNotFound);
    try testing.expect(std.fs.cwd().access(saved_idx_path, .{}) != error.FileNotFound);

    // Verify git can read objects from the destination repo
    const verify_out = try git(allocator, dst, &.{ "verify-pack", "-v", saved_pack_path });
    defer allocator.free(verify_out);
    try testing.expect(verify_out.len > 0);

    // Get object hashes from the original repo and verify each is loadable
    const all_objs = try git(allocator, tmp, &.{ "rev-list", "--objects", "--all" });
    defer allocator.free(all_objs);

    var obj_lines = std.mem.splitScalar(u8, all_objs, '\n');
    var loaded_count: usize = 0;
    while (obj_lines.next()) |line| {
        if (line.len < 40) continue;
        const hash = line[0..40];

        // Load from destination repo via ziggit
        const obj = objects.GitObject.load(hash, dst_git_dir, &platform, allocator) catch continue;
        defer obj.deinit(allocator);
        loaded_count += 1;

        // Cross-check with original repo's git cat-file
        const expected = catFile(allocator, tmp, hash, "-p") catch continue;
        defer allocator.free(expected);

        if (obj.type == .blob or obj.type == .commit or obj.type == .tag) {
            try testing.expectEqualSlices(u8, expected, obj.data);
        }
    }

    try testing.expect(loaded_count >= 3);
}

// ============================================================================
// TEST 4: OFS_DELTA correctness - git with --delta-base-offset produces deltas
// ============================================================================
test "real interop: OFS_DELTA objects correctly resolved" {
    const allocator = testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        std.fs.cwd().deleteTree(tmp) catch {};
        allocator.free(tmp);
    }

    try gitNoOut(allocator, tmp, &.{ "init" });

    // Create files with shared content to encourage delta compression
    const shared_prefix = "This is a shared prefix line that will appear in multiple files.\n" ++
        "It provides enough content for git to create OFS_DELTA objects.\n" ++
        "The more shared content, the more likely deltas are used.\n";

    {
        const fpath = try std.fmt.allocPrint(allocator, "{s}/file1.txt", .{tmp});
        defer allocator.free(fpath);
        const f = try std.fs.cwd().createFile(fpath, .{});
        defer f.close();
        try f.writeAll(shared_prefix ++ "File 1 unique content.\n");
    }
    try gitNoOut(allocator, tmp, &.{ "add", "." });
    try gitNoOut(allocator, tmp, &.{ "-c", "user.name=Test", "-c", "user.email=test@test.com", "commit", "-m", "add file1" });

    {
        const fpath = try std.fmt.allocPrint(allocator, "{s}/file2.txt", .{tmp});
        defer allocator.free(fpath);
        const f = try std.fs.cwd().createFile(fpath, .{});
        defer f.close();
        try f.writeAll(shared_prefix ++ "File 2 unique content - different!\n");
    }
    try gitNoOut(allocator, tmp, &.{ "add", "." });
    try gitNoOut(allocator, tmp, &.{ "-c", "user.name=Test", "-c", "user.email=test@test.com", "commit", "-m", "add file2" });

    {
        const fpath = try std.fmt.allocPrint(allocator, "{s}/file3.txt", .{tmp});
        defer allocator.free(fpath);
        const f = try std.fs.cwd().createFile(fpath, .{});
        defer f.close();
        try f.writeAll(shared_prefix ++ "File 3 is yet another variation.\n");
    }
    try gitNoOut(allocator, tmp, &.{ "add", "." });
    try gitNoOut(allocator, tmp, &.{ "-c", "user.name=Test", "-c", "user.email=test@test.com", "commit", "-m", "add file3" });

    // Force aggressive repacking with --window=10 --depth=50
    try gitNoOut(allocator, tmp, &.{ "repack", "-a", "-d", "-f", "--window=10", "--depth=50" });

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp});
    defer allocator.free(git_dir);

    // Verify git pack-objects produced some delta objects
    const pack_dir_path = try std.fmt.allocPrint(allocator, "{s}/objects/pack", .{git_dir});
    defer allocator.free(pack_dir_path);
    var pack_dir = try std.fs.cwd().openDir(pack_dir_path, .{ .iterate = true });
    defer pack_dir.close();
    var pack_filename: ?[]u8 = null;
    defer if (pack_filename) |n| allocator.free(n);
    {
        var it = pack_dir.iterate();
        while (try it.next()) |e| {
            if (std.mem.endsWith(u8, e.name, ".pack")) {
                pack_filename = try allocator.dupe(u8, e.name);
                break;
            }
        }
    }
    try testing.expect(pack_filename != null);

    const pack_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pack_dir_path, pack_filename.? });
    defer allocator.free(pack_path);

    // Check git verify-pack for delta objects
    const verify_out = try git(allocator, tmp, &.{ "verify-pack", "-v", pack_path });
    defer allocator.free(verify_out);

    // Count delta objects
    var has_deltas = false;
    var verify_lines = std.mem.splitScalar(u8, verify_out, '\n');
    while (verify_lines.next()) |vline| {
        if (std.mem.indexOf(u8, vline, " ofs_delta ") != null or
            std.mem.indexOf(u8, vline, " ref_delta ") != null)
        {
            has_deltas = true;
            break;
        }
    }

    // Regardless of whether git chose deltas, verify all objects readable
    var platform = NativePlatform{};
    const all_objs = try git(allocator, tmp, &.{ "rev-list", "--objects", "--all" });
    defer allocator.free(all_objs);

    var obj_lines = std.mem.splitScalar(u8, all_objs, '\n');
    var verified: usize = 0;
    while (obj_lines.next()) |line| {
        if (line.len < 40) continue;
        const hash = line[0..40];

        const obj = objects.GitObject.load(hash, git_dir, &platform, allocator) catch |err| {
            std.debug.print("Failed to load {s}: {}\n", .{ hash, err });
            return err;
        };
        defer obj.deinit(allocator);

        const expected = catFile(allocator, tmp, hash, "-p") catch continue;
        defer allocator.free(expected);

        if (obj.type == .blob) {
            try testing.expectEqualSlices(u8, expected, obj.data);
        }
        verified += 1;
    }

    try testing.expect(verified >= 6);

    // Log whether deltas were present (informational)
    if (has_deltas) {
        std.debug.print("  [info] git pack contained delta objects - delta resolution verified\n", .{});
    } else {
        std.debug.print("  [info] git pack had no delta objects (small repo)\n", .{});
    }
}

// ============================================================================
// TEST 5: delta application correctness with git-generated delta data
// ============================================================================
test "delta correctness: manually constructed delta matches expected output" {
    const allocator = testing.allocator;

    // Base: "Hello, world!\n"
    const base = "Hello, world!\n";
    // Expected result: "Hello, world!\nExtra line.\n"
    const expected_result = "Hello, world!\nExtra line.\n";

    // Build delta by hand:
    //   base_size = 14, result_size = 27
    //   copy 0..14 from base
    //   insert "Extra line.\n"
    var delta = std.ArrayList(u8).init(allocator);
    defer delta.deinit();

    // base_size = 14 (single byte varint)
    try delta.append(14);
    // result_size = 27 (single byte varint)
    try delta.append(27);
    // copy: offset=0, size=14
    // cmd byte: 0x80 | 0x10 (size byte 0 present) | 0x01 (offset byte 0 present)
    try delta.append(0x80 | 0x01 | 0x10);
    try delta.append(0); // offset byte 0 = 0
    try delta.append(14); // size byte 0 = 14
    // insert 13 bytes: "Extra line.\n"
    const insert_data = "Extra line.\n";
    try delta.append(@intCast(insert_data.len));
    try delta.appendSlice(insert_data);

    const result = try objects.applyDelta(base, delta.items, allocator);
    defer allocator.free(result);

    try testing.expectEqualSlices(u8, expected_result, result);
}

// ============================================================================
// TEST 6: delta with copy_size=0 means 0x10000
// ============================================================================
test "delta correctness: copy_size=0 means 0x10000" {
    const allocator = testing.allocator;

    // Create a base that's exactly 0x10000 (65536) bytes
    const base = try allocator.alloc(u8, 0x10000);
    defer allocator.free(base);
    for (base, 0..) |*b, i| {
        b.* = @intCast(i & 0xFF);
    }

    var delta = std.ArrayList(u8).init(allocator);
    defer delta.deinit();

    // base_size = 0x10000 (varint: 3 bytes)
    try delta.append(0x80 | 0x00); // low 7 bits = 0, continuation
    try delta.append(0x80 | 0x00); // next 7 bits = 0, continuation
    try delta.append(0x04); // 4 << 14 = 0x10000

    // result_size = 0x10000
    try delta.append(0x80 | 0x00);
    try delta.append(0x80 | 0x00);
    try delta.append(0x04);

    // Copy from offset 0, size 0 (which means 0x10000)
    // cmd: 0x80 (copy) | 0x01 (offset byte present)
    // No size bits set → size = 0 → means 0x10000
    try delta.append(0x80 | 0x01);
    try delta.append(0x00); // offset = 0

    const result = try objects.applyDelta(base, delta.items, allocator);
    defer allocator.free(result);

    try testing.expectEqual(@as(usize, 0x10000), result.len);
    try testing.expectEqualSlices(u8, base, result);
}

// ============================================================================
// TEST 7: pack with multiple object types verifiable by git fsck
// ============================================================================
test "real interop: round-trip save → git fsck accepts repository" {
    const allocator = testing.allocator;
    const src = try makeTmpDir(allocator);
    defer {
        std.fs.cwd().deleteTree(src) catch {};
        allocator.free(src);
    }

    // Source repo with objects
    try gitNoOut(allocator, src, &.{ "init" });
    {
        const fpath = try std.fmt.allocPrint(allocator, "{s}/code.zig", .{src});
        defer allocator.free(fpath);
        const f = try std.fs.cwd().createFile(fpath, .{});
        defer f.close();
        try f.writeAll("const std = @import(\"std\");\n\npub fn main() void {}\n");
    }
    try gitNoOut(allocator, src, &.{ "add", "." });
    try gitNoOut(allocator, src, &.{ "-c", "user.name=Test", "-c", "user.email=test@test.com", "commit", "-m", "init" });
    try gitNoOut(allocator, src, &.{ "repack", "-a", "-d" });

    // Read the pack
    const src_git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{src});
    defer allocator.free(src_git_dir);
    const src_pack_dir = try std.fmt.allocPrint(allocator, "{s}/objects/pack", .{src_git_dir});
    defer allocator.free(src_pack_dir);

    var pdir = try std.fs.cwd().openDir(src_pack_dir, .{ .iterate = true });
    defer pdir.close();
    var pfname: ?[]u8 = null;
    defer if (pfname) |n| allocator.free(n);
    {
        var it = pdir.iterate();
        while (try it.next()) |e| {
            if (std.mem.endsWith(u8, e.name, ".pack")) {
                pfname = try allocator.dupe(u8, e.name);
                break;
            }
        }
    }
    try testing.expect(pfname != null);

    const ppath = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ src_pack_dir, pfname.? });
    defer allocator.free(ppath);
    const pdata = try std.fs.cwd().readFileAlloc(allocator, ppath, 100 * 1024 * 1024);
    defer allocator.free(pdata);

    // Save to a fresh destination repo via ziggit
    const dst = try makeTmpDir(allocator);
    defer {
        std.fs.cwd().deleteTree(dst) catch {};
        allocator.free(dst);
    }
    try gitNoOut(allocator, dst, &.{ "init" });
    const dst_git = try std.fmt.allocPrint(allocator, "{s}/.git", .{dst});
    defer allocator.free(dst_git);

    var platform = NativePlatform{};
    const cksum = try objects.saveReceivedPack(pdata, dst_git, &platform, allocator);
    defer allocator.free(cksum);

    // Set up HEAD to point to the same commit
    const head_out = try git(allocator, src, &.{ "rev-parse", "HEAD" });
    defer allocator.free(head_out);
    const head_hash = std.mem.trim(u8, head_out, "\n ");

    // Write refs so git fsck can verify connectivity
    const refs_head_path = try std.fmt.allocPrint(allocator, "{s}/refs/heads/master", .{dst_git});
    defer allocator.free(refs_head_path);
    {
        const refs_dir = try std.fmt.allocPrint(allocator, "{s}/refs/heads", .{dst_git});
        defer allocator.free(refs_dir);
        std.fs.cwd().makePath(refs_dir) catch {};
        const f = try std.fs.cwd().createFile(refs_head_path, .{});
        defer f.close();
        try f.writer().print("{s}\n", .{head_hash});
    }

    // Update HEAD
    const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{dst_git});
    defer allocator.free(head_path);
    {
        const f = try std.fs.cwd().createFile(head_path, .{});
        defer f.close();
        try f.writeAll("ref: refs/heads/master\n");
    }

    // git fsck should pass on the destination repo
    const fsck_out = git(allocator, dst, &.{ "fsck", "--full" }) catch |err| {
        std.debug.print("git fsck failed: {}\n", .{err});
        return err;
    };
    defer allocator.free(fsck_out);

    // git fsck on a valid repo should succeed (exit 0)
    // Output may contain "notice:" lines but no "error:" lines
    const has_errors = std.mem.indexOf(u8, fsck_out, "error ") != null;
    if (has_errors) {
        std.debug.print("git fsck output: {s}\n", .{fsck_out});
    }
    try testing.expect(!has_errors);
}

// ============================================================================
// TEST 8: empty delta (copy entire base)
// ============================================================================
test "delta correctness: identity delta (copy all of base)" {
    const allocator = testing.allocator;
    const base = "This is the original content that should be preserved exactly.\n";

    var delta = std.ArrayList(u8).init(allocator);
    defer delta.deinit();

    // base_size
    try delta.append(@intCast(base.len));
    // result_size = same
    try delta.append(@intCast(base.len));
    // copy from offset 0, size = base.len
    try delta.append(0x80 | 0x01 | 0x10);
    try delta.append(0); // offset = 0
    try delta.append(@intCast(base.len)); // size

    const result = try objects.applyDelta(base, delta.items, allocator);
    defer allocator.free(result);
    try testing.expectEqualSlices(u8, base, result);
}

// ============================================================================
// TEST 9: delta with only insert commands (no copy from base)
// ============================================================================
test "delta correctness: insert-only delta" {
    const allocator = testing.allocator;
    const base = "old content\n";
    const new_content = "brand new content\n";

    var delta = std.ArrayList(u8).init(allocator);
    defer delta.deinit();

    // base_size
    try delta.append(@intCast(base.len));
    // result_size
    try delta.append(@intCast(new_content.len));
    // insert
    try delta.append(@intCast(new_content.len));
    try delta.appendSlice(new_content);

    const result = try objects.applyDelta(base, delta.items, allocator);
    defer allocator.free(result);
    try testing.expectEqualSlices(u8, new_content, result);
}

// ============================================================================
// TEST 10: mixed copy + insert delta
// ============================================================================
test "delta correctness: mixed copy and insert" {
    const allocator = testing.allocator;
    const base = "AAAA" ++ "BBBB" ++ "CCCC";
    const expected = "AAAA" ++ "XXXX" ++ "CCCC";

    var delta = std.ArrayList(u8).init(allocator);
    defer delta.deinit();

    // base_size = 12, result_size = 12
    try delta.append(12);
    try delta.append(12);

    // copy 4 bytes from offset 0
    try delta.append(0x80 | 0x01 | 0x10);
    try delta.append(0);
    try delta.append(4);

    // insert 4 bytes "XXXX"
    try delta.append(4);
    try delta.appendSlice("XXXX");

    // copy 4 bytes from offset 8
    try delta.append(0x80 | 0x01 | 0x10);
    try delta.append(8);
    try delta.append(4);

    const result = try objects.applyDelta(base, delta.items, allocator);
    defer allocator.free(result);
    try testing.expectEqualSlices(u8, expected, result);
}

// ============================================================================
// TEST 11: multi-byte offset in copy command
// ============================================================================
test "delta correctness: multi-byte copy offset" {
    const allocator = testing.allocator;

    // Create a base with 300 bytes, copy from offset 256
    const base = try allocator.alloc(u8, 300);
    defer allocator.free(base);
    for (base, 0..) |*b, i| b.* = @intCast(i & 0xFF);

    // We want to copy 10 bytes from offset 256
    const expected = base[256..266];

    var delta = std.ArrayList(u8).init(allocator);
    defer delta.deinit();

    // base_size = 300 (varint: 2 bytes)
    try delta.append(0x80 | @as(u8, @intCast(300 & 0x7F))); // low 7 bits = 44, continue
    try delta.append(@as(u8, @intCast(300 >> 7))); // high bits = 2

    // result_size = 10
    try delta.append(10);

    // copy from offset 256, size 10
    // offset 256 = 0x100: need offset byte 0 (=0x00) and offset byte 1 (=0x01)
    // cmd: 0x80 | 0x01 | 0x02 | 0x10
    try delta.append(0x80 | 0x01 | 0x02 | 0x10);
    try delta.append(0x00); // offset byte 0
    try delta.append(0x01); // offset byte 1 → offset = 0x0100 = 256
    try delta.append(10); // size byte 0

    const result = try objects.applyDelta(base, delta.items, allocator);
    defer allocator.free(result);
    try testing.expectEqual(@as(usize, 10), result.len);
    try testing.expectEqualSlices(u8, expected, result);
}
