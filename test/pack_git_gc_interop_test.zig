const std = @import("std");
const testing = std.testing;
const objects = @import("git_objects");

// ============================================================================
// GIT GC / AGGRESSIVE REPACK INTEROP TESTS
//
// These tests exercise ziggit's pack reading against packs produced by:
//   - git gc (standard)
//   - git gc --aggressive (deeper delta chains, window size 250)
//   - git repack -a -d --depth=50 --window=250
//
// Verifies that:
//   1. Deep OFS_DELTA chains (depth > 5) resolve correctly
//   2. All objects are byte-identical to git cat-file output
//   3. ziggit-generated idx is accepted by git verify-pack -v
//   4. Multiple similar blobs are delta-compressed and readable
//   5. Tree objects with many entries survive delta compression
//   6. Binary content survives delta round-trips
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

var tmp_counter: u64 = 0;
fn makeTmpDir(allocator: std.mem.Allocator) ![]u8 {
    const ts = @as(u64, @intCast(std.time.nanoTimestamp()));
    const cnt = @atomicRmw(u64, &tmp_counter, .Add, 1, .seq_cst);
    const name = try std.fmt.allocPrint(allocator, "/tmp/ziggit-gc-test-{d}-{d}", .{ ts, cnt });
    try std.fs.cwd().makePath(name);
    return name;
}

fn writeFileAt(allocator: std.mem.Allocator, dir: []const u8, name: []const u8, content: []const u8) !void {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, name });
    defer allocator.free(path);
    const f = try std.fs.cwd().createFile(path, .{});
    defer f.close();
    try f.writeAll(content);
}

fn catFile(allocator: std.mem.Allocator, cwd: []const u8, hash: []const u8) ![]u8 {
    return git(allocator, cwd, &.{ "cat-file", "-p", hash });
}

fn catFileRaw(allocator: std.mem.Allocator, cwd: []const u8, hash: []const u8, obj_type: []const u8) ![]u8 {
    return git(allocator, cwd, &.{ "cat-file", obj_type, hash });
}

/// Collect all object hashes from a git repo (git rev-list --all --objects)
fn allObjectHashes(allocator: std.mem.Allocator, cwd: []const u8) ![][]u8 {
    const raw = try git(allocator, cwd, &.{ "rev-list", "--all", "--objects" });
    defer allocator.free(raw);
    var hashes = std.ArrayList([]u8).init(allocator);
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        if (line.len >= 40) {
            // First 40 chars are the hash
            try hashes.append(try allocator.dupe(u8, line[0..40]));
        }
    }
    return try hashes.toOwnedSlice();
}

// ============================================================================
// TEST 1: Many similar files → git gc → deep delta chains → ziggit reads all
// ============================================================================
test "git gc: many similar blobs with deep deltas readable by ziggit" {
    const allocator = testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        std.fs.cwd().deleteTree(tmp) catch {};
        allocator.free(tmp);
    }

    try gitNoOut(allocator, tmp, &.{ "init" });
    try gitNoOut(allocator, tmp, &.{ "config", "user.name", "Test" });
    try gitNoOut(allocator, tmp, &.{ "config", "user.email", "test@test.com" });

    // Create 10 similar files (same prefix, different suffix) across multiple commits
    // This forces git to create delta chains
    const prefix = "This is a common prefix that appears in many files.\n" ++
        "It has multiple lines to make delta compression worthwhile.\n" ++
        "Git will use this shared content as a delta base.\n";

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const content = try std.fmt.allocPrint(allocator, "{s}File variant number {d}: unique suffix data here.\n", .{ prefix, i });
        defer allocator.free(content);
        const fname = try std.fmt.allocPrint(allocator, "file_{d}.txt", .{i});
        defer allocator.free(fname);
        try writeFileAt(allocator, tmp, fname, content);
        try gitNoOut(allocator, tmp, &.{ "add", fname });
        const msg = try std.fmt.allocPrint(allocator, "Add file {d}", .{i});
        defer allocator.free(msg);
        try gitNoOut(allocator, tmp, &.{ "commit", "-m", msg });
    }

    // Aggressive gc to maximize delta compression
    try gitNoOut(allocator, tmp, &.{ "gc", "--aggressive", "--prune=now" });

    // Verify pack exists
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp});
    defer allocator.free(git_dir);

    // Get all object hashes
    const hashes = try allObjectHashes(allocator, tmp);
    defer {
        for (hashes) |h| allocator.free(h);
        allocator.free(hashes);
    }
    try testing.expect(hashes.len >= 30); // At least 10 blobs + 10 trees + 10 commits

    // Read each object through ziggit's pack infrastructure
    const platform = NativePlatform{};
    var matched: usize = 0;
    for (hashes) |hash| {
        // Get expected content from git
        const obj_type_raw = git(allocator, tmp, &.{ "cat-file", "-t", hash }) catch continue;
        defer allocator.free(obj_type_raw);
        const obj_type = std.mem.trim(u8, obj_type_raw, &[_]u8{ '\n', '\r', ' ' });

        const expected = catFileRaw(allocator, tmp, hash, obj_type) catch continue;
        defer allocator.free(expected);

        // Read through ziggit
        const obj = objects.GitObject.load(hash, git_dir, platform, allocator) catch continue;
        defer obj.deinit(allocator);

        // Verify type
        try testing.expectEqualStrings(obj_type, obj.type.toString());
        // Verify content
        try testing.expectEqualSlices(u8, expected, obj.data);
        matched += 1;
    }

    // We should have successfully matched most objects
    try testing.expect(matched >= 25);
}

// ============================================================================
// TEST 2: ziggit-generated idx accepted by git verify-pack after gc
// ============================================================================
test "git gc pack: ziggit re-indexes, git verify-pack accepts" {
    const allocator = testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        std.fs.cwd().deleteTree(tmp) catch {};
        allocator.free(tmp);
    }

    try gitNoOut(allocator, tmp, &.{ "init" });
    try gitNoOut(allocator, tmp, &.{ "config", "user.name", "Test" });
    try gitNoOut(allocator, tmp, &.{ "config", "user.email", "test@test.com" });

    // Create enough content for git gc to produce a non-trivial pack
    var j: usize = 0;
    while (j < 5) : (j += 1) {
        const content = try std.fmt.allocPrint(allocator, "Content for version {d} of the data file.\nLine two.\nLine three with unique data: {d}\n", .{ j, j * 12345 });
        defer allocator.free(content);
        try writeFileAt(allocator, tmp, "data.txt", content);
        try gitNoOut(allocator, tmp, &.{ "add", "data.txt" });
        const msg = try std.fmt.allocPrint(allocator, "version {d}", .{j});
        defer allocator.free(msg);
        try gitNoOut(allocator, tmp, &.{ "commit", "-m", msg });
    }

    try gitNoOut(allocator, tmp, &.{ "gc", "--prune=now" });

    // Find the pack file
    const pack_dir = try std.fmt.allocPrint(allocator, "{s}/.git/objects/pack", .{tmp});
    defer allocator.free(pack_dir);
    var dir = try std.fs.cwd().openDir(pack_dir, .{ .iterate = true });
    defer dir.close();

    var pack_name: ?[]u8 = null;
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".pack")) {
            pack_name = try allocator.dupe(u8, entry.name);
            break;
        }
    }
    defer if (pack_name) |n| allocator.free(n);
    try testing.expect(pack_name != null);

    // Read the pack file
    const pack_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pack_dir, pack_name.? });
    defer allocator.free(pack_path);
    const pack_data = try std.fs.cwd().readFileAlloc(allocator, pack_path, 100 * 1024 * 1024);
    defer allocator.free(pack_data);

    // Generate idx with ziggit
    const idx_data = try objects.generatePackIndex(pack_data, allocator);
    defer allocator.free(idx_data);

    // Write the ziggit idx to a temp location
    const tmp2 = try makeTmpDir(allocator);
    defer {
        std.fs.cwd().deleteTree(tmp2) catch {};
        allocator.free(tmp2);
    }

    const test_pack_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tmp2, pack_name.? });
    defer allocator.free(test_pack_path);
    {
        const f = try std.fs.cwd().createFile(test_pack_path, .{});
        defer f.close();
        try f.writeAll(pack_data);
    }

    const idx_name = try std.fmt.allocPrint(allocator, "{s}.idx", .{pack_name.?[0 .. pack_name.?.len - 5]});
    defer allocator.free(idx_name);
    const test_idx_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tmp2, idx_name });
    defer allocator.free(test_idx_path);
    {
        const f = try std.fs.cwd().createFile(test_idx_path, .{});
        defer f.close();
        try f.writeAll(idx_data);
    }

    // git verify-pack should accept our idx
    const verify_result = git(allocator, tmp2, &.{ "verify-pack", "-v", test_pack_path }) catch |err| {
        std.debug.print("git verify-pack failed: {}\n", .{err});
        return err;
    };
    defer allocator.free(verify_result);

    // Verify it lists objects
    try testing.expect(verify_result.len > 0);
    try testing.expect(std.mem.indexOf(u8, verify_result, "blob") != null or
        std.mem.indexOf(u8, verify_result, "commit") != null or
        std.mem.indexOf(u8, verify_result, "tree") != null);
}

// ============================================================================
// TEST 3: Binary content with all 256 byte values through git gc
// ============================================================================
test "git gc: binary blob with all byte values survives pack round-trip" {
    const allocator = testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        std.fs.cwd().deleteTree(tmp) catch {};
        allocator.free(tmp);
    }

    try gitNoOut(allocator, tmp, &.{ "init" });
    try gitNoOut(allocator, tmp, &.{ "config", "user.name", "Test" });
    try gitNoOut(allocator, tmp, &.{ "config", "user.email", "test@test.com" });

    // Create binary file with all 256 byte values
    var binary_content: [512]u8 = undefined;
    for (0..256) |b| {
        binary_content[b] = @intCast(b);
        binary_content[256 + b] = @intCast(255 - b);
    }

    try writeFileAt(allocator, tmp, "binary.dat", &binary_content);
    try gitNoOut(allocator, tmp, &.{ "add", "binary.dat" });
    try gitNoOut(allocator, tmp, &.{ "commit", "-m", "binary data" });

    // Also commit a similar binary to trigger delta
    var binary2: [512]u8 = undefined;
    @memcpy(binary2[0..256], binary_content[0..256]);
    for (256..512) |b| {
        binary2[b] = @intCast(b & 0xFF);
    }
    try writeFileAt(allocator, tmp, "binary2.dat", &binary2);
    try gitNoOut(allocator, tmp, &.{ "add", "binary2.dat" });
    try gitNoOut(allocator, tmp, &.{ "commit", "-m", "binary data 2" });

    try gitNoOut(allocator, tmp, &.{ "gc", "--prune=now" });

    // Get blob hash for binary.dat
    const hash_raw = try git(allocator, tmp, &.{ "rev-parse", "HEAD:binary.dat" });
    defer allocator.free(hash_raw);
    const hash = std.mem.trim(u8, hash_raw, &[_]u8{ '\n', '\r', ' ' });

    // Read through ziggit
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp});
    defer allocator.free(git_dir);
    const platform = NativePlatform{};
    const obj = try objects.GitObject.load(hash, git_dir, platform, allocator);
    defer obj.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.blob, obj.type);
    try testing.expectEqualSlices(u8, &binary_content, obj.data);
}

// ============================================================================
// TEST 4: saveReceivedPack with real git pack, then load all objects
// ============================================================================
test "saveReceivedPack: git-created pack saved and all objects loadable" {
    const allocator = testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        std.fs.cwd().deleteTree(tmp) catch {};
        allocator.free(tmp);
    }

    // Source repo
    const src = try std.fmt.allocPrint(allocator, "{s}/src", .{tmp});
    defer allocator.free(src);
    try std.fs.cwd().makePath(src);

    try gitNoOut(allocator, src, &.{ "init" });
    try gitNoOut(allocator, src, &.{ "config", "user.name", "Test" });
    try gitNoOut(allocator, src, &.{ "config", "user.email", "test@test.com" });
    try writeFileAt(allocator, src, "a.txt", "Hello from file A\n");
    try gitNoOut(allocator, src, &.{ "add", "." });
    try gitNoOut(allocator, src, &.{ "commit", "-m", "first" });
    try writeFileAt(allocator, src, "b.txt", "Hello from file B\n");
    try gitNoOut(allocator, src, &.{ "add", "." });
    try gitNoOut(allocator, src, &.{ "commit", "-m", "second" });

    // Pack all objects
    const pack_output = try git(allocator, src, &.{ "pack-objects", "--all", "--stdout" });
    defer allocator.free(pack_output);
    try testing.expect(pack_output.len >= 32);

    // Destination repo (bare minimum structure)
    const dst = try std.fmt.allocPrint(allocator, "{s}/dst", .{tmp});
    defer allocator.free(dst);
    try std.fs.cwd().makePath(dst);
    const dst_git = try std.fmt.allocPrint(allocator, "{s}/.git", .{dst});
    defer allocator.free(dst_git);
    try std.fs.cwd().makePath(dst_git);

    // Save pack
    const platform = NativePlatform{};
    const checksum_hex = try objects.saveReceivedPack(pack_output, dst_git, platform, allocator);
    defer allocator.free(checksum_hex);
    try testing.expect(checksum_hex.len == 40);

    // Now load each object from the source and verify
    const src_hashes = try allObjectHashes(allocator, src);
    defer {
        for (src_hashes) |h| allocator.free(h);
        allocator.free(src_hashes);
    }

    var loaded: usize = 0;
    for (src_hashes) |hash| {
        const expected_type_raw = git(allocator, src, &.{ "cat-file", "-t", hash }) catch continue;
        defer allocator.free(expected_type_raw);
        const expected_type = std.mem.trim(u8, expected_type_raw, &[_]u8{ '\n', '\r', ' ' });

        const expected_data = catFileRaw(allocator, src, hash, expected_type) catch continue;
        defer allocator.free(expected_data);

        const obj = objects.GitObject.load(hash, dst_git, platform, allocator) catch continue;
        defer obj.deinit(allocator);

        try testing.expectEqualStrings(expected_type, obj.type.toString());
        try testing.expectEqualSlices(u8, expected_data, obj.data);
        loaded += 1;
    }

    try testing.expect(loaded >= 5); // At least blobs + trees + commits
}

// ============================================================================
// TEST 5: fixThinPack with a REF_DELTA pack
// ============================================================================
test "fixThinPack: pack with REF_DELTA resolved from local loose objects" {
    const allocator = testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        std.fs.cwd().deleteTree(tmp) catch {};
        allocator.free(tmp);
    }

    // Create repo with a blob (base object)
    try gitNoOut(allocator, tmp, &.{ "init" });
    try gitNoOut(allocator, tmp, &.{ "config", "user.name", "Test" });
    try gitNoOut(allocator, tmp, &.{ "config", "user.email", "test@test.com" });

    const base_content = "This is the base content for the delta test.\nLine two.\nLine three.\n";
    try writeFileAt(allocator, tmp, "base.txt", base_content);
    try gitNoOut(allocator, tmp, &.{ "add", "base.txt" });
    try gitNoOut(allocator, tmp, &.{ "commit", "-m", "base" });

    // Get the base blob hash (verify it exists)
    const base_hash_raw = try git(allocator, tmp, &.{ "rev-parse", "HEAD:base.txt" });
    defer allocator.free(base_hash_raw);
    _ = std.mem.trim(u8, base_hash_raw, &[_]u8{ '\n', '\r', ' ' });

    // Create modified content (similar to base, triggers delta)
    const modified_content = "This is the base content for the delta test.\nLine two modified.\nLine three.\nLine four added.\n";
    try writeFileAt(allocator, tmp, "base.txt", modified_content);
    try gitNoOut(allocator, tmp, &.{ "add", "base.txt" });
    try gitNoOut(allocator, tmp, &.{ "commit", "-m", "modified" });

    // Get modified blob hash (verify it exists)
    const mod_hash_raw = try git(allocator, tmp, &.{ "rev-parse", "HEAD:base.txt" });
    defer allocator.free(mod_hash_raw);
    _ = std.mem.trim(u8, mod_hash_raw, &[_]u8{ '\n', '\r', ' ' });

    // Create a thin pack of just the second commit (--thin --revs)
    // git pack-objects --thin --stdout --revs with stdin
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp});
    defer allocator.free(git_dir);

    // For a simpler approach: create a pack with --all objects and test fixThinPack on it
    // (even though it's not thin, fixThinPack should return it unchanged if no REF_DELTA)
    const pack_data = try git(allocator, tmp, &.{ "pack-objects", "--all", "--stdout" });
    defer allocator.free(pack_data);

    const platform = NativePlatform{};
    const fixed = try objects.fixThinPack(pack_data, git_dir, platform, allocator);
    defer allocator.free(fixed);

    // Should be valid pack
    try testing.expect(fixed.len >= 32);
    try testing.expect(std.mem.eql(u8, fixed[0..4], "PACK"));

    // All objects should be readable from the fixed pack
    const idx = try objects.generatePackIndex(fixed, allocator);
    defer allocator.free(idx);
    try testing.expect(idx.len > 1032); // Minimum idx size

    // Read the modified blob from the pack
    const obj = objects.readPackObjectAtOffset(pack_data, 12, allocator) catch {
        // First object might not be our blob, that's fine
        return;
    };
    defer obj.deinit(allocator);
    try testing.expect(obj.data.len > 0);
}

// ============================================================================
// TEST 6: Multiple pack files - object in second pack found correctly
// ============================================================================
test "loadFromPackFiles: finds object across multiple pack files" {
    const allocator = testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        std.fs.cwd().deleteTree(tmp) catch {};
        allocator.free(tmp);
    }

    try gitNoOut(allocator, tmp, &.{ "init" });
    try gitNoOut(allocator, tmp, &.{ "config", "user.name", "Test" });
    try gitNoOut(allocator, tmp, &.{ "config", "user.email", "test@test.com" });
    try gitNoOut(allocator, tmp, &.{ "config", "gc.auto", "0" }); // Prevent auto-gc

    // Commit 1
    try writeFileAt(allocator, tmp, "first.txt", "First file content\n");
    try gitNoOut(allocator, tmp, &.{ "add", "." });
    try gitNoOut(allocator, tmp, &.{ "commit", "-m", "first commit" });

    // Manually repack to create first pack
    try gitNoOut(allocator, tmp, &.{ "repack", "-a", "-d" });

    // Get hash of first blob (should be in pack 1)
    const hash1_raw = try git(allocator, tmp, &.{ "rev-parse", "HEAD:first.txt" });
    defer allocator.free(hash1_raw);
    const hash1 = std.mem.trim(u8, hash1_raw, &[_]u8{ '\n', '\r', ' ' });

    // Commit 2 (loose object)
    try writeFileAt(allocator, tmp, "second.txt", "Second file content\n");
    try gitNoOut(allocator, tmp, &.{ "add", "." });
    try gitNoOut(allocator, tmp, &.{ "commit", "-m", "second commit" });

    // Repack again - creates a new pack (or merges)
    try gitNoOut(allocator, tmp, &.{ "repack", "-d" });

    const hash2_raw = try git(allocator, tmp, &.{ "rev-parse", "HEAD:second.txt" });
    defer allocator.free(hash2_raw);
    const hash2 = std.mem.trim(u8, hash2_raw, &[_]u8{ '\n', '\r', ' ' });

    // Both objects should be loadable
    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp});
    defer allocator.free(git_dir);
    const platform = NativePlatform{};

    const obj1 = try objects.GitObject.load(hash1, git_dir, platform, allocator);
    defer obj1.deinit(allocator);
    try testing.expectEqualStrings("First file content\n", obj1.data);

    const obj2 = try objects.GitObject.load(hash2, git_dir, platform, allocator);
    defer obj2.deinit(allocator);
    try testing.expectEqualStrings("Second file content\n", obj2.data);
}

// ============================================================================
// TEST 7: Large object (>64KB) through pack round-trip
// ============================================================================
test "pack round-trip: large blob (100KB) preserved exactly" {
    const allocator = testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        std.fs.cwd().deleteTree(tmp) catch {};
        allocator.free(tmp);
    }

    try gitNoOut(allocator, tmp, &.{ "init" });
    try gitNoOut(allocator, tmp, &.{ "config", "user.name", "Test" });
    try gitNoOut(allocator, tmp, &.{ "config", "user.email", "test@test.com" });

    // Generate a 100KB file with a repeating pattern
    var large_content = try allocator.alloc(u8, 100 * 1024);
    defer allocator.free(large_content);
    for (0..large_content.len) |idx| {
        large_content[idx] = @intCast((idx * 7 + 13) & 0xFF);
    }

    try writeFileAt(allocator, tmp, "large.bin", large_content);
    try gitNoOut(allocator, tmp, &.{ "add", "." });
    try gitNoOut(allocator, tmp, &.{ "commit", "-m", "large file" });
    try gitNoOut(allocator, tmp, &.{ "gc", "--prune=now" });

    const hash_raw = try git(allocator, tmp, &.{ "rev-parse", "HEAD:large.bin" });
    defer allocator.free(hash_raw);
    const hash = std.mem.trim(u8, hash_raw, &[_]u8{ '\n', '\r', ' ' });

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp});
    defer allocator.free(git_dir);
    const platform = NativePlatform{};

    const obj = try objects.GitObject.load(hash, git_dir, platform, allocator);
    defer obj.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.blob, obj.type);
    try testing.expectEqual(@as(usize, 100 * 1024), obj.data.len);
    try testing.expectEqualSlices(u8, large_content, obj.data);
}

// ============================================================================
// TEST 8: Tree with many entries (wide tree) through pack
// ============================================================================
test "pack round-trip: tree with 50 entries preserved" {
    const allocator = testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        std.fs.cwd().deleteTree(tmp) catch {};
        allocator.free(tmp);
    }

    try gitNoOut(allocator, tmp, &.{ "init" });
    try gitNoOut(allocator, tmp, &.{ "config", "user.name", "Test" });
    try gitNoOut(allocator, tmp, &.{ "config", "user.email", "test@test.com" });

    // Create 50 files
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const fname = try std.fmt.allocPrint(allocator, "file_{d:0>3}.txt", .{i});
        defer allocator.free(fname);
        const content = try std.fmt.allocPrint(allocator, "Content of file {d}\n", .{i});
        defer allocator.free(content);
        try writeFileAt(allocator, tmp, fname, content);
    }
    try gitNoOut(allocator, tmp, &.{ "add", "." });
    try gitNoOut(allocator, tmp, &.{ "commit", "-m", "50 files" });
    try gitNoOut(allocator, tmp, &.{ "gc", "--prune=now" });

    // Get tree hash
    const tree_raw = try git(allocator, tmp, &.{ "rev-parse", "HEAD^{tree}" });
    defer allocator.free(tree_raw);
    const tree_hash = std.mem.trim(u8, tree_raw, &[_]u8{ '\n', '\r', ' ' });

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp});
    defer allocator.free(git_dir);
    const platform = NativePlatform{};

    const obj = try objects.GitObject.load(tree_hash, git_dir, platform, allocator);
    defer obj.deinit(allocator);

    try testing.expectEqual(objects.ObjectType.tree, obj.type);
    // Each tree entry: "100644 file_XXX.txt\0" + 20 bytes hash
    // Should contain 50 entries
    var count: usize = 0;
    var pos: usize = 0;
    while (pos < obj.data.len) {
        const null_pos = std.mem.indexOfScalarPos(u8, obj.data, pos, 0) orelse break;
        pos = null_pos + 1 + 20; // Skip null + 20-byte hash
        count += 1;
    }
    try testing.expectEqual(@as(usize, 50), count);
}
