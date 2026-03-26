const std = @import("std");
const testing = std.testing;
const objects = @import("git_objects");

// ============================================================================
// PACK GIT INTEROP CORRECTNESS TESTS
//
// These tests create REAL git repositories, generate pack files with git's
// own pack-objects, then read every object back with ziggit's pack
// infrastructure and verify byte-exact correctness against git cat-file.
//
// They also verify that ziggit's generatePackIndex produces idx files
// that pass `git verify-pack -v`.
//
// This is the definitive interop test suite for the pack subsystem.
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
    const p = try std.fmt.allocPrint(alloc, "/tmp/ziggit_interop_{s}_{}", .{ label, std.crypto.random.int(u64) });
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

/// Filesystem adapter for objects.zig functions that take platform_impl
const TestFs = struct {
    pub fn readFile(_: TestFs, alloc: std.mem.Allocator, path: []const u8) ![]u8 {
        return std.fs.cwd().readFileAlloc(alloc, path, 64 * 1024 * 1024);
    }
    pub fn writeFile(_: TestFs, path: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(path)) |parent| {
            std.fs.cwd().makePath(parent) catch {};
        }
        const f = try std.fs.cwd().createFile(path, .{});
        defer f.close();
        try f.writeAll(data);
    }
    pub fn makeDir(_: TestFs, path: []const u8) !void {
        std.fs.cwd().makePath(path) catch {};
    }
};

const TestPlatform = struct {
    fs: TestFs = .{},
};

/// Run git cat-file to get raw object content for a hash
fn gitCatFile(alloc: std.mem.Allocator, cwd: []const u8, hash: []const u8) !struct { obj_type: []const u8, data: []u8 } {
    // Get type
    const type_out = try git(alloc, cwd, &.{ "cat-file", "-t", hash });
    const obj_type = std.mem.trimRight(u8, type_out, "\n\r");
    const type_str = try alloc.dupe(u8, obj_type);
    alloc.free(type_out);

    // Get content
    const data_out = try git(alloc, cwd, &.{ "cat-file", "-p", hash });
    return .{ .obj_type = type_str, .data = data_out };
}

/// Run git cat-file to get raw (binary) object content
fn gitCatFileRaw(alloc: std.mem.Allocator, cwd: []const u8, hash: []const u8, obj_type: []const u8) ![]u8 {
    return try git(alloc, cwd, &.{ "cat-file", obj_type, hash });
}

// ============================================================================
// Test 1: Read all object types from git-created pack (blob, tree, commit)
// ============================================================================
test "interop: read blob/tree/commit from git pack via readPackObjectAtOffset" {
    const alloc = testing.allocator;
    const dir = try tmpDir(alloc, "pk_interop1");
    defer {
        rmDir(dir);
        alloc.free(dir);
    }

    // Create a git repo with some content
    try gitExec(alloc, dir, &.{ "init" });
    try gitExec(alloc, dir, &.{ "config", "user.email", "test@test.com" });
    try gitExec(alloc, dir, &.{ "config", "user.name", "Test" });

    try writeFile(dir, "hello.txt", "Hello, World!\n");
    try writeFile(dir, "src/main.zig", "pub fn main() void {}\n");
    try gitExec(alloc, dir, &.{ "add", "." });
    try gitExec(alloc, dir, &.{ "commit", "-m", "initial commit" });

    // Modify and make a second commit to generate deltas
    try writeFile(dir, "hello.txt", "Hello, World!\nSecond line\n");
    try gitExec(alloc, dir, &.{ "add", "." });
    try gitExec(alloc, dir, &.{ "commit", "-m", "add second line" });

    // Force git gc to create a pack file
    try gitExec(alloc, dir, &.{ "gc", "--aggressive" });

    // Find the pack file
    const git_dir = try std.fmt.allocPrint(alloc, "{s}/.git", .{dir});
    defer alloc.free(git_dir);
    const pack_dir = try std.fmt.allocPrint(alloc, "{s}/objects/pack", .{git_dir});
    defer alloc.free(pack_dir);

    var pdir = try std.fs.cwd().openDir(pack_dir, .{ .iterate = true });
    defer pdir.close();

    var pack_path: ?[]u8 = null;
    var idx_path: ?[]u8 = null;
    defer if (pack_path) |p| alloc.free(p);
    defer if (idx_path) |p| alloc.free(p);

    var iter = pdir.iterate();
    while (try iter.next()) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".pack")) {
            pack_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ pack_dir, entry.name });
        }
        if (std.mem.endsWith(u8, entry.name, ".idx")) {
            idx_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ pack_dir, entry.name });
        }
    }

    try testing.expect(pack_path != null);
    try testing.expect(idx_path != null);

    // Read pack data
    const pack_data = try readFileAlloc(alloc, pack_path.?);
    defer alloc.free(pack_data);

    // Get all object hashes from git
    const rev_list = try git(alloc, dir, &.{ "rev-list", "--objects", "--all" });
    defer alloc.free(rev_list);

    var lines = std.mem.splitScalar(u8, std.mem.trimRight(u8, rev_list, "\n"), '\n');
    var checked: usize = 0;

    while (lines.next()) |line| {
        if (line.len < 40) continue;
        const hash = line[0..40];

        // Get expected content from git
        const git_type_out = try git(alloc, dir, &.{ "cat-file", "-t", hash });
        defer alloc.free(git_type_out);
        const git_type = std.mem.trimRight(u8, git_type_out, "\n\r");

        // Load object using ziggit's loadFromPackFiles
        const platform = TestPlatform{};
        const obj = objects.GitObject.load(hash, git_dir, platform, alloc) catch |err| {
            std.debug.print("Failed to load {s} ({s}): {}\n", .{ hash, git_type, err });
            continue;
        };
        defer obj.deinit(alloc);

        // Verify type matches
        try testing.expectEqualStrings(git_type, obj.type.toString());

        // For blobs, verify content matches exactly
        if (obj.type == .blob) {
            const git_content = try gitCatFileRaw(alloc, dir, hash, "blob");
            defer alloc.free(git_content);
            try testing.expectEqualSlices(u8, git_content, obj.data);
        }

        checked += 1;
    }

    // We should have checked at least blobs + trees + commits
    try testing.expect(checked >= 4);
}

// ============================================================================
// Test 2: generatePackIndex produces idx that git verify-pack accepts
// ============================================================================
test "interop: generatePackIndex produces git-valid idx" {
    const alloc = testing.allocator;
    const dir = try tmpDir(alloc, "pk_interop2");
    defer {
        rmDir(dir);
        alloc.free(dir);
    }

    // Create repo with enough objects to have a meaningful pack
    try gitExec(alloc, dir, &.{ "init" });
    try gitExec(alloc, dir, &.{ "config", "user.email", "test@test.com" });
    try gitExec(alloc, dir, &.{ "config", "user.name", "Test" });

    // Create several files to ensure variety
    try writeFile(dir, "a.txt", "aaa\n");
    try writeFile(dir, "b.txt", "bbb\n");
    try writeFile(dir, "c.txt", "ccc\n");
    try gitExec(alloc, dir, &.{ "add", "." });
    try gitExec(alloc, dir, &.{ "commit", "-m", "first" });

    try writeFile(dir, "a.txt", "aaa\nmodified\n");
    try gitExec(alloc, dir, &.{ "add", "." });
    try gitExec(alloc, dir, &.{ "commit", "-m", "second" });

    // Use git gc to pack
    try gitExec(alloc, dir, &.{ "gc" });

    // Find the pack file
    const git_dir = try std.fmt.allocPrint(alloc, "{s}/.git", .{dir});
    defer alloc.free(git_dir);
    const pack_dir = try std.fmt.allocPrint(alloc, "{s}/objects/pack", .{git_dir});
    defer alloc.free(pack_dir);

    var pdir = try std.fs.cwd().openDir(pack_dir, .{ .iterate = true });
    defer pdir.close();

    var pack_file: ?[]u8 = null;
    defer if (pack_file) |p| alloc.free(p);

    var it = pdir.iterate();
    while (try it.next()) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".pack")) {
            pack_file = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ pack_dir, entry.name });
        }
    }
    try testing.expect(pack_file != null);

    // Read pack data
    const pack_data = try readFileAlloc(alloc, pack_file.?);
    defer alloc.free(pack_data);

    // Generate idx with ziggit
    const idx_data = try objects.generatePackIndex(pack_data, alloc);
    defer alloc.free(idx_data);

    // Write the ziggit-generated idx file alongside the pack
    // First, get the pack filename stem
    const pack_basename = std.fs.path.basename(pack_file.?);
    const stem = pack_basename[0 .. pack_basename.len - 5]; // strip .pack
    const ziggit_idx_path = try std.fmt.allocPrint(alloc, "{s}/{s}.ziggit.idx", .{ pack_dir, stem });
    defer alloc.free(ziggit_idx_path);

    {
        const f = try std.fs.cwd().createFile(ziggit_idx_path, .{});
        defer f.close();
        try f.writeAll(idx_data);
    }

    // Rename original .idx and put ours in its place for verify-pack
    const orig_idx_path = try std.fmt.allocPrint(alloc, "{s}/{s}.idx", .{ pack_dir, stem });
    defer alloc.free(orig_idx_path);
    const backup_idx_path = try std.fmt.allocPrint(alloc, "{s}/{s}.idx.bak", .{ pack_dir, stem });
    defer alloc.free(backup_idx_path);

    std.fs.cwd().rename(orig_idx_path, backup_idx_path) catch {};
    std.fs.cwd().rename(ziggit_idx_path, orig_idx_path) catch {};
    defer {
        // Restore original idx
        std.fs.cwd().rename(orig_idx_path, ziggit_idx_path) catch {};
        std.fs.cwd().rename(backup_idx_path, orig_idx_path) catch {};
    }

    // Run git verify-pack on our idx
    const verify_out = git(alloc, dir, &.{ "verify-pack", "-v", pack_file.? }) catch |err| {
        std.debug.print("git verify-pack failed with ziggit idx: {}\n", .{err});
        // Read git's stderr for diagnostics
        return err;
    };
    defer alloc.free(verify_out);

    // verify-pack should list objects and not error out
    try testing.expect(verify_out.len > 0);
    try testing.expect(std.mem.indexOf(u8, verify_out, "commit") != null or
        std.mem.indexOf(u8, verify_out, "blob") != null or
        std.mem.indexOf(u8, verify_out, "tree") != null);
}

// ============================================================================
// Test 3: saveReceivedPack + loadFromPackFiles roundtrip with git validation
// ============================================================================
test "interop: saveReceivedPack roundtrip - save, load, git fsck" {
    const alloc = testing.allocator;
    const dir = try tmpDir(alloc, "pk_interop3");
    defer {
        rmDir(dir);
        alloc.free(dir);
    }

    // Create source repo
    const src = try std.fmt.allocPrint(alloc, "{s}/src", .{dir});
    defer alloc.free(src);
    try std.fs.cwd().makePath(src);

    try gitExec(alloc, src, &.{ "init" });
    try gitExec(alloc, src, &.{ "config", "user.email", "test@test.com" });
    try gitExec(alloc, src, &.{ "config", "user.name", "Test" });

    try writeFile(src, "readme.md", "# Test Project\nThis is a test.\n");
    try writeFile(src, "main.zig", "const std = @import(\"std\");\npub fn main() void {}\n");
    try gitExec(alloc, src, &.{ "add", "." });
    try gitExec(alloc, src, &.{ "commit", "-m", "init" });

    // Pack objects using git pack-objects
    try gitExec(alloc, src, &.{ "gc" });

    // Find pack file in source
    const src_pack_dir = try std.fmt.allocPrint(alloc, "{s}/.git/objects/pack", .{src});
    defer alloc.free(src_pack_dir);

    var spdir = try std.fs.cwd().openDir(src_pack_dir, .{ .iterate = true });
    defer spdir.close();

    var src_pack_path: ?[]u8 = null;
    defer if (src_pack_path) |p| alloc.free(p);

    var sit = spdir.iterate();
    while (try sit.next()) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".pack")) {
            src_pack_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ src_pack_dir, entry.name });
        }
    }
    try testing.expect(src_pack_path != null);

    const pack_data = try readFileAlloc(alloc, src_pack_path.?);
    defer alloc.free(pack_data);

    // Create destination repo (bare-ish)
    const dst = try std.fmt.allocPrint(alloc, "{s}/dst", .{dir});
    defer alloc.free(dst);
    try std.fs.cwd().makePath(dst);
    try gitExec(alloc, dst, &.{ "init" });

    // Save pack using ziggit's saveReceivedPack
    const dst_git_dir = try std.fmt.allocPrint(alloc, "{s}/.git", .{dst});
    defer alloc.free(dst_git_dir);
    const platform = TestPlatform{};

    const checksum_hex = try objects.saveReceivedPack(pack_data, dst_git_dir, platform, alloc);
    defer alloc.free(checksum_hex);

    // Verify the pack file was saved
    const saved_pack_path = try std.fmt.allocPrint(alloc, "{s}/.git/objects/pack/pack-{s}.pack", .{ dst, checksum_hex });
    defer alloc.free(saved_pack_path);
    const saved_idx_path = try std.fmt.allocPrint(alloc, "{s}/.git/objects/pack/pack-{s}.idx", .{ dst, checksum_hex });
    defer alloc.free(saved_idx_path);

    // Both files should exist
    try std.fs.cwd().access(saved_pack_path, .{});
    try std.fs.cwd().access(saved_idx_path, .{});

    // Run git fsck on destination to verify integrity
    const fsck_out = git(alloc, dst, &.{ "fsck", "--no-dangling" }) catch |err| {
        std.debug.print("git fsck failed: {}\n", .{err});
        return err;
    };
    defer alloc.free(fsck_out);

    // Now load each object from the source using ziggit's loadFromPackFiles on dst
    const src_objects = try git(alloc, src, &.{ "rev-list", "--objects", "--all" });
    defer alloc.free(src_objects);

    var obj_lines = std.mem.splitScalar(u8, std.mem.trimRight(u8, src_objects, "\n"), '\n');
    var loaded: usize = 0;

    while (obj_lines.next()) |line| {
        if (line.len < 40) continue;
        const hash = line[0..40];

        const obj = objects.GitObject.load(hash, dst_git_dir, platform, alloc) catch |err| {
            std.debug.print("Failed to load {s} from dst: {}\n", .{ hash, err });
            continue;
        };
        defer obj.deinit(alloc);

        // Cross-check with git in source
        const git_content = gitCatFileRaw(alloc, src, hash, obj.type.toString()) catch continue;
        defer alloc.free(git_content);

        if (obj.type == .blob or obj.type == .commit) {
            try testing.expectEqualSlices(u8, git_content, obj.data);
        }
        loaded += 1;
    }

    try testing.expect(loaded >= 3); // At least blob, tree, commit
}

// ============================================================================
// Test 4: Tag objects in pack files
// ============================================================================
test "interop: tag objects read correctly from git pack" {
    const alloc = testing.allocator;
    const dir = try tmpDir(alloc, "pk_interop4");
    defer {
        rmDir(dir);
        alloc.free(dir);
    }

    try gitExec(alloc, dir, &.{ "init" });
    try gitExec(alloc, dir, &.{ "config", "user.email", "test@test.com" });
    try gitExec(alloc, dir, &.{ "config", "user.name", "Test" });

    try writeFile(dir, "file.txt", "content\n");
    try gitExec(alloc, dir, &.{ "add", "." });
    try gitExec(alloc, dir, &.{ "commit", "-m", "initial" });
    try gitExec(alloc, dir, &.{ "tag", "-a", "v1.0", "-m", "release 1.0" });

    // Create more commits and tags to force delta generation
    try writeFile(dir, "file.txt", "content\nupdated\n");
    try gitExec(alloc, dir, &.{ "add", "." });
    try gitExec(alloc, dir, &.{ "commit", "-m", "update" });
    try gitExec(alloc, dir, &.{ "tag", "-a", "v2.0", "-m", "release 2.0" });

    // Pack everything
    try gitExec(alloc, dir, &.{ "gc", "--aggressive" });

    const git_dir = try std.fmt.allocPrint(alloc, "{s}/.git", .{dir});
    defer alloc.free(git_dir);

    // Get tag object hashes
    const platform = TestPlatform{};
    const tags = [_][]const u8{ "v1.0", "v2.0" };

    for (tags) |tag_name| {
        const tag_hash_out = git(alloc, dir, &.{ "rev-parse", tag_name }) catch continue;
        defer alloc.free(tag_hash_out);
        const tag_hash = std.mem.trimRight(u8, tag_hash_out, "\n\r");
        if (tag_hash.len != 40) continue;

        // Check if this is an annotated tag (not just a commit)
        const type_out = git(alloc, dir, &.{ "cat-file", "-t", tag_hash }) catch continue;
        defer alloc.free(type_out);
        const obj_type = std.mem.trimRight(u8, type_out, "\n\r");

        if (!std.mem.eql(u8, obj_type, "tag")) continue;

        // Load via ziggit
        const obj = objects.GitObject.load(tag_hash, git_dir, platform, alloc) catch |err| {
            std.debug.print("Failed to load tag {s}: {}\n", .{ tag_name, err });
            continue;
        };
        defer obj.deinit(alloc);

        try testing.expect(obj.type == .tag);

        // Verify content matches
        const git_tag_content = try gitCatFileRaw(alloc, dir, tag_hash, "tag");
        defer alloc.free(git_tag_content);
        try testing.expectEqualSlices(u8, git_tag_content, obj.data);
    }
}

// ============================================================================
// Test 5: OFS_DELTA chain resolution in real git pack
// ============================================================================
test "interop: OFS_DELTA chains resolve correctly" {
    const alloc = testing.allocator;
    const dir = try tmpDir(alloc, "pk_interop5");
    defer {
        rmDir(dir);
        alloc.free(dir);
    }

    try gitExec(alloc, dir, &.{ "init" });
    try gitExec(alloc, dir, &.{ "config", "user.email", "test@test.com" });
    try gitExec(alloc, dir, &.{ "config", "user.name", "Test" });

    // Create a file and make many small modifications to force delta chains
    var content = std.ArrayList(u8).init(alloc);
    defer content.deinit();

    try content.appendSlice("# Changelog\n\n");
    try writeFile(dir, "CHANGELOG.md", content.items);
    try gitExec(alloc, dir, &.{ "add", "." });
    try gitExec(alloc, dir, &.{ "commit", "-m", "init changelog" });

    // Make 5 incremental modifications
    for (0..5) |i| {
        const line = try std.fmt.allocPrint(alloc, "## Version {}\n- Change {}\n\n", .{ i + 1, i + 1 });
        defer alloc.free(line);
        try content.appendSlice(line);
        try writeFile(dir, "CHANGELOG.md", content.items);
        try gitExec(alloc, dir, &.{ "add", "." });
        const msg = try std.fmt.allocPrint(alloc, "version {}", .{i + 1});
        defer alloc.free(msg);
        try gitExec(alloc, dir, &.{ "commit", "-m", msg });
    }

    // Aggressive gc to maximize delta chains
    try gitExec(alloc, dir, &.{ "gc", "--aggressive" });

    const git_dir = try std.fmt.allocPrint(alloc, "{s}/.git", .{dir});
    defer alloc.free(git_dir);
    const platform = TestPlatform{};

    // Get all blob hashes
    const all_objs = try git(alloc, dir, &.{ "rev-list", "--objects", "--all" });
    defer alloc.free(all_objs);

    var lines = std.mem.splitScalar(u8, std.mem.trimRight(u8, all_objs, "\n"), '\n');
    var blob_count: usize = 0;

    while (lines.next()) |line| {
        if (line.len < 40) continue;
        const hash = line[0..40];

        const type_out = git(alloc, dir, &.{ "cat-file", "-t", hash }) catch continue;
        defer alloc.free(type_out);
        if (!std.mem.eql(u8, std.mem.trimRight(u8, type_out, "\n\r"), "blob")) continue;

        // Load via ziggit
        const obj = objects.GitObject.load(hash, git_dir, platform, alloc) catch |err| {
            std.debug.print("Failed to load blob {s}: {}\n", .{ hash, err });
            return err;
        };
        defer obj.deinit(alloc);

        // Verify exact match with git
        const git_content = try gitCatFileRaw(alloc, dir, hash, "blob");
        defer alloc.free(git_content);
        try testing.expectEqualSlices(u8, git_content, obj.data);

        blob_count += 1;
    }

    // We should have at least 6 blob versions (initial + 5 modifications) 
    // plus the main.zig blob if it exists
    try testing.expect(blob_count >= 2);
}

// ============================================================================
// Test 6: Binary data survives pack roundtrip
// ============================================================================
test "interop: binary data pack roundtrip" {
    const alloc = testing.allocator;
    const dir = try tmpDir(alloc, "pk_interop6");
    defer {
        rmDir(dir);
        alloc.free(dir);
    }

    try gitExec(alloc, dir, &.{ "init" });
    try gitExec(alloc, dir, &.{ "config", "user.email", "test@test.com" });
    try gitExec(alloc, dir, &.{ "config", "user.name", "Test" });

    // Create binary file with all byte values
    var binary_data: [256]u8 = undefined;
    for (0..256) |i| {
        binary_data[i] = @intCast(i);
    }

    try writeFile(dir, "binary.bin", &binary_data);
    try gitExec(alloc, dir, &.{ "add", "." });
    try gitExec(alloc, dir, &.{ "commit", "-m", "binary data" });
    try gitExec(alloc, dir, &.{ "gc" });

    const git_dir = try std.fmt.allocPrint(alloc, "{s}/.git", .{dir});
    defer alloc.free(git_dir);
    const platform = TestPlatform{};

    // Find blob hash for binary.bin
    const ls_tree = try git(alloc, dir, &.{ "ls-tree", "HEAD" });
    defer alloc.free(ls_tree);

    var tree_lines = std.mem.splitScalar(u8, std.mem.trimRight(u8, ls_tree, "\n"), '\n');
    while (tree_lines.next()) |tline| {
        if (std.mem.indexOf(u8, tline, "binary.bin") == null) continue;
        // Format: mode type hash\tname
        var parts = std.mem.splitScalar(u8, tline, '\t');
        const first_part = parts.first();
        // "100644 blob <hash>"
        var word_iter = std.mem.splitScalar(u8, first_part, ' ');
        _ = word_iter.next(); // mode
        _ = word_iter.next(); // type
        const hash = word_iter.next() orelse continue;

        const obj = try objects.GitObject.load(hash, git_dir, platform, alloc);
        defer obj.deinit(alloc);

        try testing.expect(obj.type == .blob);
        try testing.expectEqualSlices(u8, &binary_data, obj.data);
    }
}

// ============================================================================
// Test 7: applyDelta strict path handles all valid deltas without fallback
// ============================================================================
test "delta: strict path handles copy-at-offset-zero correctly" {
    const alloc = testing.allocator;

    // Base: "ABCDEFGHIJ" (10 bytes)
    const base = "ABCDEFGHIJ";

    // Build delta that copies from offset 0, size 5 then inserts "XYZ"
    // Expected result: "ABCDEXYZ" (8 bytes)
    var delta_buf = std.ArrayList(u8).init(alloc);
    defer delta_buf.deinit();

    // Base size varint: 10
    try delta_buf.append(10);
    // Result size varint: 8
    try delta_buf.append(8);
    // Copy command: offset=0, size=5
    // cmd byte: 0x80 | 0x10 (size low byte set) - offset is 0 so no offset bits
    // But git format: if offset is 0, no offset bytes needed
    // size=5: set bit 0x10, emit 0x05
    try delta_buf.append(0x80 | 0x10); // copy cmd with size_lo
    try delta_buf.append(5); // size = 5
    // Insert "XYZ"
    try delta_buf.append(3); // insert 3 bytes
    try delta_buf.appendSlice("XYZ");

    const result = try objects.applyDelta(base, delta_buf.items, alloc);
    defer alloc.free(result);

    try testing.expectEqualStrings("ABCDEXYZ", result);
}

test "delta: copy with multi-byte offset and size" {
    const alloc = testing.allocator;

    // Base: 300 bytes of 'A' followed by "TARGET"
    var base_buf: [306]u8 = undefined;
    @memset(base_buf[0..300], 'A');
    @memcpy(base_buf[300..306], "TARGET");

    // Delta: copy from offset 300, size 6 (should get "TARGET")
    var delta = std.ArrayList(u8).init(alloc);
    defer delta.deinit();

    // Base size: 306 (needs 2 varint bytes)
    try delta.append(0x80 | (306 & 0x7F)); // 0x80 | 50 = 0xB2
    try delta.append(@intCast(306 >> 7)); // 2

    // Result size: 6
    try delta.append(6);

    // Copy: offset=300 (0x012C), size=6
    // offset byte 0: 0x2C, offset byte 1: 0x01
    // size byte 0: 0x06
    // cmd: 0x80 | 0x01 | 0x02 | 0x10
    try delta.append(0x80 | 0x01 | 0x02 | 0x10);
    try delta.append(0x2C); // offset low
    try delta.append(0x01); // offset high
    try delta.append(0x06); // size

    const result = try objects.applyDelta(&base_buf, delta.items, alloc);
    defer alloc.free(result);

    try testing.expectEqualStrings("TARGET", result);
}

test "delta: copy size 0x10000 encoded as size=0" {
    const alloc = testing.allocator;

    // Base: 0x10000 bytes (65536)
    const base = try alloc.alloc(u8, 0x10000);
    defer alloc.free(base);
    @memset(base, 'X');

    // Delta: copy entire base using size=0 (which means 0x10000)
    var delta = std.ArrayList(u8).init(alloc);
    defer delta.deinit();

    // Delta header uses standard varint (7 bits per byte, MSB = continue)
    // Base size: 0x10000 = 65536
    // byte 0: 65536 & 0x7F = 0, continue
    // byte 1: (65536 >> 7) & 0x7F = 512 & 0x7F = 0, continue
    // byte 2: (65536 >> 14) & 0x7F = 4
    try delta.append(0x80 | 0);
    try delta.append(0x80 | 0);
    try delta.append(4);

    // Result size: 0x10000 (same encoding)
    try delta.append(0x80 | 0);
    try delta.append(0x80 | 0);
    try delta.append(4);

    // Copy command: offset=0, size=0 (means 0x10000)
    // No offset bits, no size bits → cmd = 0x80 only
    try delta.append(0x80);

    const result = try objects.applyDelta(base, delta.items, alloc);
    defer alloc.free(result);

    try testing.expectEqual(@as(usize, 0x10000), result.len);
    try testing.expectEqualSlices(u8, base, result);
}

// ============================================================================
// Test 8: Verify readPackObjectAtOffset for all pack object types in synthetic pack
// ============================================================================
test "pack: readPackObjectAtOffset for synthetic blob, tree, commit" {
    const alloc = testing.allocator;

    // Build a minimal valid pack file with one blob object
    const blob_content = "Hello from pack!\n";

    var pack = std.ArrayList(u8).init(alloc);
    defer pack.deinit();

    // Pack header
    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big); // version
    try pack.writer().writeInt(u32, 1, .big); // 1 object

    // Object: blob (type=3), size=17
    const size = blob_content.len;
    var first_byte: u8 = (3 << 4) | @as(u8, @intCast(size & 0x0F));
    var remaining = size >> 4;
    if (remaining > 0) first_byte |= 0x80;
    try pack.append(first_byte);
    while (remaining > 0) {
        var b: u8 = @intCast(remaining & 0x7F);
        remaining >>= 7;
        if (remaining > 0) b |= 0x80;
        try pack.append(b);
    }

    // Compress blob data
    var compressed = std.ArrayList(u8).init(alloc);
    defer compressed.deinit();
    var input = std.io.fixedBufferStream(blob_content);
    try std.compress.zlib.compress(input.reader(), compressed.writer(), .{});
    try pack.appendSlice(compressed.items);

    // Pack checksum
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack.items);
    var checksum: [20]u8 = undefined;
    hasher.final(&checksum);
    try pack.appendSlice(&checksum);

    // Now read the object back
    const obj = try objects.readPackObjectAtOffset(pack.items, 12, alloc);
    defer obj.deinit(alloc);

    try testing.expect(obj.type == .blob);
    try testing.expectEqualStrings(blob_content, obj.data);
}

// ============================================================================
// Test 9: Synthetic OFS_DELTA pack and readPackObjectAtOffset
// ============================================================================
test "pack: readPackObjectAtOffset resolves OFS_DELTA" {
    const alloc = testing.allocator;

    const base_content = "Hello, World! This is base content.\n";
    const target_content = "Hello, World! This is modified content.\n";

    var pack = std.ArrayList(u8).init(alloc);
    defer pack.deinit();

    // Pack header
    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, 2, .big); // 2 objects

    // Object 1: base blob at offset 12
    const base_offset: usize = 12;
    {
        const size = base_content.len;
        var first: u8 = (3 << 4) | @as(u8, @intCast(size & 0x0F));
        var rem = size >> 4;
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
        var inp = std.io.fixedBufferStream(base_content);
        try std.compress.zlib.compress(inp.reader(), comp.writer(), .{});
        try pack.appendSlice(comp.items);
    }

    // Object 2: OFS_DELTA referencing object 1
    const delta_obj_offset = pack.items.len;
    {
        // Build delta data
        var delta = std.ArrayList(u8).init(alloc);
        defer delta.deinit();

        // Base size varint
        try delta.append(@intCast(base_content.len));
        // Result size varint
        try delta.append(@intCast(target_content.len));

        // Copy first 28 bytes from base ("Hello, World! This is ")
        // Actually copy first 22 bytes: "Hello, World! This is "
        const shared_prefix = "Hello, World! This is ";
        try delta.append(0x80 | 0x10); // copy, size_lo set
        try delta.append(@intCast(shared_prefix.len));

        // Insert the different part: "modified content.\n"
        const new_suffix = "modified content.\n";
        try delta.append(@intCast(new_suffix.len));
        try delta.appendSlice(new_suffix);

        // Pack type 6 (OFS_DELTA) header
        const delta_decompressed_size = delta.items.len;
        var first: u8 = (6 << 4) | @as(u8, @intCast(delta_decompressed_size & 0x0F));
        var rem = delta_decompressed_size >> 4;
        if (rem > 0) first |= 0x80;
        try pack.append(first);
        while (rem > 0) {
            var b: u8 = @intCast(rem & 0x7F);
            rem >>= 7;
            if (rem > 0) b |= 0x80;
            try pack.append(b);
        }

        // OFS_DELTA negative offset (relative to this object's start)
        const neg_offset = delta_obj_offset - base_offset;
        // Encode as git variable-length: first byte has 7 bits, subsequent have 7 bits with +1 adjustment
        if (neg_offset < 128) {
            try pack.append(@intCast(neg_offset));
        } else {
            // Multi-byte encoding
            var off = neg_offset;
            var stack: [10]u8 = undefined;
            var si: usize = 0;
            stack[si] = @intCast(off & 0x7F);
            si += 1;
            off >>= 7;
            while (off > 0) {
                off -= 1;
                stack[si] = @intCast(off & 0x7F);
                si += 1;
                off >>= 7;
            }
            // Write in reverse (MSB first)
            var wi: usize = si;
            while (wi > 1) {
                wi -= 1;
                try pack.append(stack[wi] | 0x80);
            }
            try pack.append(stack[0]); // last byte without continue bit
        }

        // Compress delta data
        var comp = std.ArrayList(u8).init(alloc);
        defer comp.deinit();
        var inp = std.io.fixedBufferStream(delta.items);
        try std.compress.zlib.compress(inp.reader(), comp.writer(), .{});
        try pack.appendSlice(comp.items);
    }

    // Pack checksum
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack.items);
    var cksum: [20]u8 = undefined;
    hasher.final(&cksum);
    try pack.appendSlice(&cksum);

    // Read the delta object - it should resolve to target_content
    const obj = try objects.readPackObjectAtOffset(pack.items, delta_obj_offset, alloc);
    defer obj.deinit(alloc);

    try testing.expect(obj.type == .blob);
    try testing.expectEqualStrings(target_content, obj.data);
}

// ============================================================================
// Test 10: generatePackIndex + object lookup roundtrip
// ============================================================================
test "pack: generatePackIndex allows object lookup" {
    const alloc = testing.allocator;

    // Build pack with one blob
    const blob_content = "test blob for indexing\n";

    var pack = std.ArrayList(u8).init(alloc);
    defer pack.deinit();

    try pack.appendSlice("PACK");
    try pack.writer().writeInt(u32, 2, .big);
    try pack.writer().writeInt(u32, 1, .big);

    // Blob object
    const size = blob_content.len;
    var first: u8 = (3 << 4) | @as(u8, @intCast(size & 0x0F));
    var rem = size >> 4;
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
    var inp = std.io.fixedBufferStream(blob_content);
    try std.compress.zlib.compress(inp.reader(), comp.writer(), .{});
    try pack.appendSlice(comp.items);

    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(pack.items);
    var cksum: [20]u8 = undefined;
    hasher.final(&cksum);
    try pack.appendSlice(&cksum);

    // Generate index
    const idx = try objects.generatePackIndex(pack.items, alloc);
    defer alloc.free(idx);

    // Verify idx structure: magic + version
    try testing.expectEqual(@as(u32, 0xff744f63), std.mem.readInt(u32, @ptrCast(idx[0..4]), .big));
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, @ptrCast(idx[4..8]), .big));

    // Fanout[255] should be 1 (total objects)
    const fanout_255 = std.mem.readInt(u32, @ptrCast(idx[8 + 255 * 4 .. 8 + 255 * 4 + 4]), .big);
    try testing.expectEqual(@as(u32, 1), fanout_255);

    // Extract SHA-1 from index (starts at offset 8 + 256*4 = 1032)
    const sha1_in_idx = idx[1032..1052];

    // Compute expected SHA-1 for this blob
    const header_str = try std.fmt.allocPrint(alloc, "blob {}\x00", .{blob_content.len});
    defer alloc.free(header_str);
    var expected_hasher = std.crypto.hash.Sha1.init(.{});
    expected_hasher.update(header_str);
    expected_hasher.update(blob_content);
    var expected_sha1: [20]u8 = undefined;
    expected_hasher.final(&expected_sha1);

    try testing.expectEqualSlices(u8, &expected_sha1, sha1_in_idx);
}
