const std = @import("std");
const testing = std.testing;
const objects = @import("git_objects");

// =============================================================================
// Ground truth tests: use real `git` to create pack files, then verify ziggit
// can read every object type correctly. Also verify ziggit-generated idx files
// are accepted by `git verify-pack`.
// =============================================================================

const ExecResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,
};

fn exec(argv: []const []const u8, cwd: []const u8) !ExecResult {
    var child = std.process.Child.init(argv, testing.allocator);
    var cwd_dir = try std.fs.openDirAbsolute(cwd, .{});
    defer cwd_dir.close();
    child.cwd_dir = cwd_dir;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const stdout = try child.stdout.?.reader().readAllAlloc(testing.allocator, 64 * 1024 * 1024);
    errdefer testing.allocator.free(stdout);
    const stderr = try child.stderr.?.reader().readAllAlloc(testing.allocator, 64 * 1024 * 1024);
    errdefer testing.allocator.free(stderr);
    const term = try child.wait();
    const exit_code: u8 = switch (term) {
        .Exited => |code| code,
        else => 255,
    };
    return ExecResult{ .stdout = stdout, .stderr = stderr, .exit_code = exit_code };
}

fn execExpectOk(argv: []const []const u8, cwd: []const u8) ![]u8 {
    const result = try exec(argv, cwd);
    defer testing.allocator.free(result.stderr);
    if (result.exit_code != 0) {
        std.debug.print("Command failed ({d}): {s}\nstderr: {s}\n", .{ result.exit_code, argv[0], result.stderr });
        testing.allocator.free(result.stdout);
        return error.CommandFailed;
    }
    return result.stdout;
}

fn freeExec(data: []u8) void {
    testing.allocator.free(data);
}

/// Create a temp dir for a test repo
fn makeTempRepo() ![]u8 {
    const result = try exec(&.{ "mktemp", "-d", "/tmp/ziggit_packtest_XXXXXX" }, "/tmp");
    defer testing.allocator.free(result.stderr);
    const path = std.mem.trimRight(u8, result.stdout, "\n\r ");
    const owned = try testing.allocator.dupe(u8, path);
    testing.allocator.free(result.stdout);
    return owned;
}

fn cleanupTempDir(path: []const u8) void {
    std.fs.cwd().deleteTree(path) catch {};
    testing.allocator.free(path);
}

// ---------------------------------------------------------------------------
// Test 1: Create repo with git, gc to pack, read all objects with ziggit
// ---------------------------------------------------------------------------
test "git-created pack: read commit, tree, blob objects" {
    const repo_path = try makeTempRepo();
    defer cleanupTempDir(repo_path);

    // Initialize repo and create some objects
    freeExec(try execExpectOk(&.{ "git", "init" }, repo_path));
    freeExec(try execExpectOk(&.{ "git", "config", "user.email", "test@test.com" }, repo_path));
    freeExec(try execExpectOk(&.{ "git", "config", "user.name", "Test" }, repo_path));

    // Create files to get blobs of various sizes
    const small_content = "Hello, world!\n";
    const medium_content = "A" ** 4096 ++ "\n";

    {
        const file_path = try std.fmt.allocPrint(testing.allocator, "{s}/small.txt", .{repo_path});
        defer testing.allocator.free(file_path);
        try std.fs.cwd().writeFile(.{ .sub_path = file_path, .data = small_content });
    }
    {
        const file_path = try std.fmt.allocPrint(testing.allocator, "{s}/medium.txt", .{repo_path});
        defer testing.allocator.free(file_path);
        try std.fs.cwd().writeFile(.{ .sub_path = file_path, .data = medium_content });
    }

    freeExec(try execExpectOk(&.{ "git", "add", "-A" }, repo_path));
    freeExec(try execExpectOk(&.{ "git", "commit", "-m", "initial commit" }, repo_path));

    // Second commit to create delta opportunities
    {
        const file_path = try std.fmt.allocPrint(testing.allocator, "{s}/medium.txt", .{repo_path});
        defer testing.allocator.free(file_path);
        const modified = "B" ++ ("A" ** 4095) ++ "\n";
        try std.fs.cwd().writeFile(.{ .sub_path = file_path, .data = modified });
    }
    freeExec(try execExpectOk(&.{ "git", "add", "-A" }, repo_path));
    freeExec(try execExpectOk(&.{ "git", "commit", "-m", "second commit" }, repo_path));

    // Repack aggressively to create deltas
    freeExec(try execExpectOk(&.{ "git", "gc", "--aggressive" }, repo_path));

    // Get all object hashes from git
    const all_objects_raw = try execExpectOk(
        &.{ "git", "rev-list", "--objects", "--all" },
        repo_path,
    );
    defer freeExec(all_objects_raw);

    const git_dir = try std.fmt.allocPrint(testing.allocator, "{s}/.git", .{repo_path});
    defer testing.allocator.free(git_dir);

    // Parse object hashes and verify each can be loaded
    var lines = std.mem.splitScalar(u8, all_objects_raw, '\n');
    var loaded_count: usize = 0;
    while (lines.next()) |line| {
        if (line.len < 40) continue;
        const hash = line[0..40];

        // Get expected content from git cat-file
        const type_out = try execExpectOk(
            &.{ "git", "cat-file", "-t", hash },
            repo_path,
        );
        defer freeExec(type_out);
        const expected_type = std.mem.trimRight(u8, type_out, "\n\r ");

        const content_out = try execExpectOk(
            &.{ "git", "cat-file", "-p", hash },
            repo_path,
        );
        defer freeExec(content_out);

        // Load with ziggit
        const platform = TestPlatform;
        const obj = objects.GitObject.load(hash, git_dir, platform, testing.allocator) catch |err| {
            std.debug.print("Failed to load object {s} (type={s}): {}\n", .{ hash, expected_type, err });
            return err;
        };
        defer obj.deinit(testing.allocator);

        // Verify type
        const ziggit_type = obj.type.toString();
        try testing.expectEqualStrings(expected_type, ziggit_type);

        // For blobs, verify data matches exactly
        if (std.mem.eql(u8, expected_type, "blob")) {
            try testing.expectEqualSlices(u8, content_out, obj.data);
        }

        loaded_count += 1;
    }

    // Should have loaded at least: 2 commits + 2 trees + 2 blobs = 6
    try testing.expect(loaded_count >= 6);
}

// ---------------------------------------------------------------------------
// Test 2: Verify ziggit generatePackIndex produces valid idx accepted by git
// ---------------------------------------------------------------------------
test "ziggit generatePackIndex accepted by git verify-pack" {
    const repo_path = try makeTempRepo();
    defer cleanupTempDir(repo_path);

    freeExec(try execExpectOk(&.{ "git", "init" }, repo_path));
    freeExec(try execExpectOk(&.{ "git", "config", "user.email", "t@t.com" }, repo_path));
    freeExec(try execExpectOk(&.{ "git", "config", "user.name", "T" }, repo_path));

    // Create content
    {
        const p = try std.fmt.allocPrint(testing.allocator, "{s}/file.txt", .{repo_path});
        defer testing.allocator.free(p);
        try std.fs.cwd().writeFile(.{ .sub_path = p, .data = "hello world\n" });
    }
    freeExec(try execExpectOk(&.{ "git", "add", "-A" }, repo_path));
    freeExec(try execExpectOk(&.{ "git", "commit", "-m", "init" }, repo_path));
    freeExec(try execExpectOk(&.{ "git", "gc" }, repo_path));

    // Find the .pack file
    const pack_dir = try std.fmt.allocPrint(testing.allocator, "{s}/.git/objects/pack", .{repo_path});
    defer testing.allocator.free(pack_dir);

    var dir = try std.fs.cwd().openDir(pack_dir, .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    var pack_name: ?[]u8 = null;
    while (try it.next()) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".pack")) {
            pack_name = try testing.allocator.dupe(u8, entry.name);
            break;
        }
    }
    defer if (pack_name) |n| testing.allocator.free(n);
    try testing.expect(pack_name != null);

    // Read the pack file
    const pack_path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ pack_dir, pack_name.? });
    defer testing.allocator.free(pack_path);
    const pack_data = try std.fs.cwd().readFileAlloc(testing.allocator, pack_path, 64 * 1024 * 1024);
    defer testing.allocator.free(pack_data);

    // Generate idx with ziggit
    const idx_data = try objects.generatePackIndex(pack_data, testing.allocator);
    defer testing.allocator.free(idx_data);

    // Write the ziggit-generated idx alongside the pack (replace git's idx)
    const idx_path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}.idx", .{
        pack_dir,
        pack_name.?[0 .. pack_name.?.len - 5], // strip ".pack"
    });
    defer testing.allocator.free(idx_path);

    try std.fs.cwd().writeFile(.{ .sub_path = idx_path, .data = idx_data });

    // Verify with git verify-pack
    const verify_result = try exec(&.{ "git", "verify-pack", "-v", pack_path }, repo_path);
    defer {
        testing.allocator.free(verify_result.stdout);
        testing.allocator.free(verify_result.stderr);
    }

    if (verify_result.exit_code != 0) {
        std.debug.print("git verify-pack FAILED:\nstdout: {s}\nstderr: {s}\n", .{
            verify_result.stdout,
            verify_result.stderr,
        });
    }
    try testing.expectEqual(@as(u8, 0), verify_result.exit_code);
}

// ---------------------------------------------------------------------------
// Test 3: applyDelta with git-generated OFS_DELTA objects
// ---------------------------------------------------------------------------
test "applyDelta with git-generated deltas" {
    const repo_path = try makeTempRepo();
    defer cleanupTempDir(repo_path);

    freeExec(try execExpectOk(&.{ "git", "init" }, repo_path));
    freeExec(try execExpectOk(&.{ "git", "config", "user.email", "t@t.com" }, repo_path));
    freeExec(try execExpectOk(&.{ "git", "config", "user.name", "T" }, repo_path));

    // Create a large file, commit, modify slightly, commit again → deltas
    const base_content = "line " ** 500 ++ "\n";
    const modified_content = "LINE " ++ ("line " ** 499) ++ "\n";
    {
        const p = try std.fmt.allocPrint(testing.allocator, "{s}/big.txt", .{repo_path});
        defer testing.allocator.free(p);
        try std.fs.cwd().writeFile(.{ .sub_path = p, .data = base_content });
    }
    freeExec(try execExpectOk(&.{ "git", "add", "-A" }, repo_path));
    freeExec(try execExpectOk(&.{ "git", "commit", "-m", "base" }, repo_path));

    {
        const p = try std.fmt.allocPrint(testing.allocator, "{s}/big.txt", .{repo_path});
        defer testing.allocator.free(p);
        try std.fs.cwd().writeFile(.{ .sub_path = p, .data = modified_content });
    }
    freeExec(try execExpectOk(&.{ "git", "add", "-A" }, repo_path));
    freeExec(try execExpectOk(&.{ "git", "commit", "-m", "modified" }, repo_path));

    // Aggressive gc to force delta compression
    freeExec(try execExpectOk(&.{ "git", "repack", "-a", "-d", "--depth=10", "--window=250" }, repo_path));

    // Now verify the second blob matches
    const head_tree_raw = try execExpectOk(&.{ "git", "rev-parse", "HEAD^{tree}" }, repo_path);
    defer freeExec(head_tree_raw);
    const head_tree = std.mem.trimRight(u8, head_tree_raw, "\n\r ");

    // Get the blob hash for big.txt in HEAD
    const ls_tree_raw = try execExpectOk(&.{ "git", "ls-tree", head_tree }, repo_path);
    defer freeExec(ls_tree_raw);

    var blob_hash: ?[]const u8 = null;
    var ls_lines = std.mem.splitScalar(u8, ls_tree_raw, '\n');
    while (ls_lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "big.txt")) |_| {
            // Format: mode type hash\tname
            var parts = std.mem.splitScalar(u8, line, '\t');
            const meta = parts.next() orelse continue;
            // meta = "100644 blob <hash>"
            var meta_parts = std.mem.splitScalar(u8, meta, ' ');
            _ = meta_parts.next(); // mode
            _ = meta_parts.next(); // type
            blob_hash = meta_parts.next();
        }
    }
    try testing.expect(blob_hash != null);

    // Load with ziggit (will go through pack → delta resolution)
    const git_dir = try std.fmt.allocPrint(testing.allocator, "{s}/.git", .{repo_path});
    defer testing.allocator.free(git_dir);

    const platform = TestPlatform;
    const obj = try objects.GitObject.load(blob_hash.?, git_dir, platform, testing.allocator);
    defer obj.deinit(testing.allocator);

    try testing.expectEqual(objects.ObjectType.blob, obj.type);
    try testing.expectEqualSlices(u8, modified_content, obj.data);
}

// ---------------------------------------------------------------------------
// Test 4: saveReceivedPack + readback (simulates clone workflow)
// ---------------------------------------------------------------------------
test "saveReceivedPack roundtrip" {
    const repo_path = try makeTempRepo();
    defer cleanupTempDir(repo_path);

    // Create a source repo with content
    const src_path = try makeTempRepo();
    defer cleanupTempDir(src_path);

    freeExec(try execExpectOk(&.{ "git", "init" }, src_path));
    freeExec(try execExpectOk(&.{ "git", "config", "user.email", "t@t.com" }, src_path));
    freeExec(try execExpectOk(&.{ "git", "config", "user.name", "T" }, src_path));
    {
        const p = try std.fmt.allocPrint(testing.allocator, "{s}/hello.txt", .{src_path});
        defer testing.allocator.free(p);
        try std.fs.cwd().writeFile(.{ .sub_path = p, .data = "hello from src\n" });
    }
    freeExec(try execExpectOk(&.{ "git", "add", "-A" }, src_path));
    freeExec(try execExpectOk(&.{ "git", "commit", "-m", "src commit" }, src_path));

    // Get pack data using git pack-objects
    const head_raw = try execExpectOk(&.{ "git", "rev-parse", "HEAD" }, src_path);
    defer freeExec(head_raw);
    const head_hash = std.mem.trimRight(u8, head_raw, "\n\r ");

    // Use rev-list + pack-objects to create a pack file
    const rev_list_out = try execExpectOk(&.{ "git", "rev-list", "--objects", head_hash }, src_path);
    defer freeExec(rev_list_out);

    // Write object list to a temp file for piping
    const obj_list_path = try std.fmt.allocPrint(testing.allocator, "{s}/obj_list", .{src_path});
    defer testing.allocator.free(obj_list_path);
    try std.fs.cwd().writeFile(.{ .sub_path = obj_list_path, .data = rev_list_out });

    const pack_out_prefix = try std.fmt.allocPrint(testing.allocator, "{s}/test_pack", .{src_path});
    defer testing.allocator.free(pack_out_prefix);

    // Use bash to pipe: git rev-list | git pack-objects
    const bash_cmd = try std.fmt.allocPrint(
        testing.allocator,
        "cd {s} && git rev-list --objects HEAD | git pack-objects {s}/test_pack",
        .{ src_path, src_path },
    );
    defer testing.allocator.free(bash_cmd);

    const pack_result = try exec(&.{ "bash", "-c", bash_cmd }, src_path);
    defer {
        testing.allocator.free(pack_result.stdout);
        testing.allocator.free(pack_result.stderr);
    }
    try testing.expectEqual(@as(u8, 0), pack_result.exit_code);

    // Read the pack hash from stdout
    const pack_hash = std.mem.trimRight(u8, pack_result.stdout, "\n\r ");
    const pack_file_path = try std.fmt.allocPrint(testing.allocator, "{s}/test_pack-{s}.pack", .{ src_path, pack_hash });
    defer testing.allocator.free(pack_file_path);

    const pack_data = try std.fs.cwd().readFileAlloc(testing.allocator, pack_file_path, 64 * 1024 * 1024);
    defer testing.allocator.free(pack_data);

    // Now set up dest repo and save pack with ziggit
    freeExec(try execExpectOk(&.{ "git", "init", "--bare" }, repo_path));

    const platform = TestPlatform;
    const checksum_hex = try objects.saveReceivedPack(pack_data, repo_path, platform, testing.allocator);
    defer testing.allocator.free(checksum_hex);

    // Verify the saved pack with git verify-pack
    const saved_pack_path = try std.fmt.allocPrint(testing.allocator, "{s}/objects/pack/pack-{s}.pack", .{ repo_path, checksum_hex });
    defer testing.allocator.free(saved_pack_path);

    const verify = try exec(&.{ "git", "verify-pack", "-v", saved_pack_path }, repo_path);
    defer {
        testing.allocator.free(verify.stdout);
        testing.allocator.free(verify.stderr);
    }

    if (verify.exit_code != 0) {
        std.debug.print("verify-pack failed:\nstdout: {s}\nstderr: {s}\n", .{ verify.stdout, verify.stderr });
    }
    try testing.expectEqual(@as(u8, 0), verify.exit_code);

    // Also verify we can read the commit object back
    const obj = try objects.GitObject.load(head_hash, repo_path, platform, testing.allocator);
    defer obj.deinit(testing.allocator);
    try testing.expectEqual(objects.ObjectType.commit, obj.type);
}

// ---------------------------------------------------------------------------
// Test 5: Tag objects in packs
// ---------------------------------------------------------------------------
test "git-created pack: read tag object" {
    const repo_path = try makeTempRepo();
    defer cleanupTempDir(repo_path);

    freeExec(try execExpectOk(&.{ "git", "init" }, repo_path));
    freeExec(try execExpectOk(&.{ "git", "config", "user.email", "t@t.com" }, repo_path));
    freeExec(try execExpectOk(&.{ "git", "config", "user.name", "T" }, repo_path));
    {
        const p = try std.fmt.allocPrint(testing.allocator, "{s}/f.txt", .{repo_path});
        defer testing.allocator.free(p);
        try std.fs.cwd().writeFile(.{ .sub_path = p, .data = "data\n" });
    }
    freeExec(try execExpectOk(&.{ "git", "add", "-A" }, repo_path));
    freeExec(try execExpectOk(&.{ "git", "commit", "-m", "init" }, repo_path));

    // Create annotated tag (stores a tag object)
    freeExec(try execExpectOk(&.{ "git", "tag", "-a", "v1.0", "-m", "release v1.0" }, repo_path));

    // GC to pack everything
    freeExec(try execExpectOk(&.{ "git", "gc", "--aggressive" }, repo_path));

    // Get the tag object hash
    const tag_hash_raw = try execExpectOk(&.{ "git", "rev-parse", "v1.0" }, repo_path);
    defer freeExec(tag_hash_raw);
    // rev-parse v1.0 gives the commit; we need the tag object itself
    const tag_ref_raw = try execExpectOk(&.{ "git", "show-ref", "--tags", "v1.0" }, repo_path);
    defer freeExec(tag_ref_raw);

    // For annotated tags, the ref points to the tag object
    // Also try: git rev-parse refs/tags/v1.0 (which gives tag obj for annotated tags)
    // Actually for annotated: refs/tags/v1.0 points to tag object
    const tag_deref_raw = try execExpectOk(&.{ "git", "for-each-ref", "--format=%(objectname) %(objecttype)", "refs/tags/v1.0" }, repo_path);
    defer freeExec(tag_deref_raw);
    const tag_line = std.mem.trimRight(u8, tag_deref_raw, "\n\r ");

    if (std.mem.indexOf(u8, tag_line, "tag")) |_| {
        // It's an annotated tag object
        const tag_hash = tag_line[0..40];
        const git_dir = try std.fmt.allocPrint(testing.allocator, "{s}/.git", .{repo_path});
        defer testing.allocator.free(git_dir);

        const platform = TestPlatform;
        const obj = try objects.GitObject.load(tag_hash, git_dir, platform, testing.allocator);
        defer obj.deinit(testing.allocator);

        try testing.expectEqual(objects.ObjectType.tag, obj.type);
        try testing.expect(std.mem.indexOf(u8, obj.data, "release v1.0") != null);
    }
}

// ---------------------------------------------------------------------------
// Test 6: Delta chain (multiple levels of OFS_DELTA)
// ---------------------------------------------------------------------------
test "git-created pack: delta chain resolution" {
    const repo_path = try makeTempRepo();
    defer cleanupTempDir(repo_path);

    freeExec(try execExpectOk(&.{ "git", "init" }, repo_path));
    freeExec(try execExpectOk(&.{ "git", "config", "user.email", "t@t.com" }, repo_path));
    freeExec(try execExpectOk(&.{ "git", "config", "user.name", "T" }, repo_path));

    // Create a file and modify it 5 times to create deep delta chains
    const base = "x" ** 2000 ++ "\n";
    {
        const p = try std.fmt.allocPrint(testing.allocator, "{s}/data.txt", .{repo_path});
        defer testing.allocator.free(p);
        try std.fs.cwd().writeFile(.{ .sub_path = p, .data = base });
    }
    freeExec(try execExpectOk(&.{ "git", "add", "-A" }, repo_path));
    freeExec(try execExpectOk(&.{ "git", "commit", "-m", "v0" }, repo_path));

    // Create successive modifications
    var i: usize = 1;
    while (i <= 5) : (i += 1) {
        const p = try std.fmt.allocPrint(testing.allocator, "{s}/data.txt", .{repo_path});
        defer testing.allocator.free(p);
        // Modify first few bytes
        var content: [2001]u8 = undefined;
        @memset(&content, 'x');
        content[0] = @intCast('a' + i);
        content[2000] = '\n';
        try std.fs.cwd().writeFile(.{ .sub_path = p, .data = &content });

        freeExec(try execExpectOk(&.{ "git", "add", "-A" }, repo_path));
        const msg = try std.fmt.allocPrint(testing.allocator, "v{d}", .{i});
        defer testing.allocator.free(msg);
        freeExec(try execExpectOk(&.{ "git", "commit", "-m", msg }, repo_path));
    }

    // Repack with deep delta chains
    freeExec(try execExpectOk(&.{ "git", "repack", "-a", "-d", "--depth=50", "--window=250" }, repo_path));

    // Verify every blob in every commit is readable
    const all_obj_raw = try execExpectOk(&.{ "git", "rev-list", "--objects", "--all" }, repo_path);
    defer freeExec(all_obj_raw);

    const git_dir = try std.fmt.allocPrint(testing.allocator, "{s}/.git", .{repo_path});
    defer testing.allocator.free(git_dir);
    const platform = TestPlatform;

    var blob_count: usize = 0;
    var lines = std.mem.splitScalar(u8, all_obj_raw, '\n');
    while (lines.next()) |line| {
        if (line.len < 40) continue;
        const hash = line[0..40];

        const type_out = try execExpectOk(&.{ "git", "cat-file", "-t", hash }, repo_path);
        defer freeExec(type_out);
        const obj_type = std.mem.trimRight(u8, type_out, "\n\r ");

        if (!std.mem.eql(u8, obj_type, "blob")) continue;
        blob_count += 1;

        // Get expected content from git
        const expected = try execExpectOk(&.{ "git", "cat-file", "blob", hash }, repo_path);
        defer freeExec(expected);

        // Load with ziggit
        const obj = objects.GitObject.load(hash, git_dir, platform, testing.allocator) catch |err| {
            std.debug.print("Failed to load blob {s}: {}\n", .{ hash, err });
            return err;
        };
        defer obj.deinit(testing.allocator);

        try testing.expectEqual(objects.ObjectType.blob, obj.type);
        try testing.expectEqualSlices(u8, expected, obj.data);
    }

    // Should have at least 6 blob versions
    try testing.expect(blob_count >= 6);
}

// ---------------------------------------------------------------------------
// Test 7: readPackObjectAtOffset for all pack object types
// ---------------------------------------------------------------------------
test "readPackObjectAtOffset: all object types in git-created pack" {
    const repo_path = try makeTempRepo();
    defer cleanupTempDir(repo_path);

    freeExec(try execExpectOk(&.{ "git", "init" }, repo_path));
    freeExec(try execExpectOk(&.{ "git", "config", "user.email", "t@t.com" }, repo_path));
    freeExec(try execExpectOk(&.{ "git", "config", "user.name", "T" }, repo_path));

    // Create content for deltas
    {
        const p = try std.fmt.allocPrint(testing.allocator, "{s}/a.txt", .{repo_path});
        defer testing.allocator.free(p);
        try std.fs.cwd().writeFile(.{ .sub_path = p, .data = "abc" ** 500 });
    }
    freeExec(try execExpectOk(&.{ "git", "add", "-A" }, repo_path));
    freeExec(try execExpectOk(&.{ "git", "commit", "-m", "c1" }, repo_path));
    {
        const p = try std.fmt.allocPrint(testing.allocator, "{s}/a.txt", .{repo_path});
        defer testing.allocator.free(p);
        try std.fs.cwd().writeFile(.{ .sub_path = p, .data = "ABC" ++ ("abc" ** 499) });
    }
    freeExec(try execExpectOk(&.{ "git", "add", "-A" }, repo_path));
    freeExec(try execExpectOk(&.{ "git", "commit", "-m", "c2" }, repo_path));
    freeExec(try execExpectOk(&.{ "git", "repack", "-a", "-d", "--depth=10" }, repo_path));

    // Find the pack file
    const pack_dir = try std.fmt.allocPrint(testing.allocator, "{s}/.git/objects/pack", .{repo_path});
    defer testing.allocator.free(pack_dir);

    var dir = try std.fs.cwd().openDir(pack_dir, .{ .iterate = true });
    defer dir.close();
    var iter = dir.iterate();
    var pack_path_buf: ?[]u8 = null;
    while (try iter.next()) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".pack")) {
            pack_path_buf = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ pack_dir, entry.name });
            break;
        }
    }
    defer if (pack_path_buf) |p| testing.allocator.free(p);
    try testing.expect(pack_path_buf != null);

    const pack_data = try std.fs.cwd().readFileAlloc(testing.allocator, pack_path_buf.?, 64 * 1024 * 1024);
    defer testing.allocator.free(pack_data);

    // Parse pack header
    try testing.expectEqualSlices(u8, "PACK", pack_data[0..4]);
    const obj_count = std.mem.readInt(u32, @ptrCast(pack_data[8..12]), .big);
    try testing.expect(obj_count >= 4); // At least 2 commits + 2 trees + 2 blobs (some may be deltas)

    // Try reading objects at each offset found by walking the pack
    var pos: usize = 12;
    const content_end = pack_data.len - 20;
    var readable_count: usize = 0;

    var obj_idx: u32 = 0;
    while (obj_idx < obj_count and pos < content_end) {
        const obj_offset = pos;

        // Try reading with readPackObjectAtOffset
        if (objects.readPackObjectAtOffset(pack_data, obj_offset, testing.allocator)) |obj| {
            obj.deinit(testing.allocator);
            readable_count += 1;
        } else |_| {
            // Some objects (REF_DELTA) may fail, that's OK for this test
        }

        // Advance pos manually by parsing the header
        const first_byte = pack_data[pos];
        pos += 1;
        const type_num = (first_byte >> 4) & 7;
        var current_byte = first_byte;
        while (current_byte & 0x80 != 0 and pos < content_end) {
            current_byte = pack_data[pos];
            pos += 1;
        }

        // Handle delta-specific headers
        if (type_num == 6) { // OFS_DELTA
            while (pos < content_end) {
                const b = pack_data[pos];
                pos += 1;
                if (b & 0x80 == 0) break;
            }
        } else if (type_num == 7) { // REF_DELTA
            pos += 20;
        }

        // Skip zlib data
        var decompressed = std.ArrayList(u8).init(testing.allocator);
        defer decompressed.deinit();
        var stream = std.io.fixedBufferStream(pack_data[pos..content_end]);
        std.compress.zlib.decompress(stream.reader(), decompressed.writer()) catch {};
        pos += @as(usize, @intCast(stream.pos));

        obj_idx += 1;
    }

    try testing.expect(readable_count >= 4);
}

// ---------------------------------------------------------------------------
// Test 8: Binary data in pack files
// ---------------------------------------------------------------------------
test "pack file with binary blob data" {
    const repo_path = try makeTempRepo();
    defer cleanupTempDir(repo_path);

    freeExec(try execExpectOk(&.{ "git", "init" }, repo_path));
    freeExec(try execExpectOk(&.{ "git", "config", "user.email", "t@t.com" }, repo_path));
    freeExec(try execExpectOk(&.{ "git", "config", "user.name", "T" }, repo_path));

    // Create binary content with all byte values
    var binary_data: [256]u8 = undefined;
    for (0..256) |j| {
        binary_data[j] = @intCast(j);
    }
    {
        const p = try std.fmt.allocPrint(testing.allocator, "{s}/bin.dat", .{repo_path});
        defer testing.allocator.free(p);
        try std.fs.cwd().writeFile(.{ .sub_path = p, .data = &binary_data });
    }
    freeExec(try execExpectOk(&.{ "git", "add", "-A" }, repo_path));
    freeExec(try execExpectOk(&.{ "git", "commit", "-m", "binary" }, repo_path));
    freeExec(try execExpectOk(&.{ "git", "gc" }, repo_path));

    // Get the blob hash
    const blob_hash_raw = try execExpectOk(&.{ "git", "hash-object", "bin.dat" }, repo_path);
    defer freeExec(blob_hash_raw);
    const blob_hash = std.mem.trimRight(u8, blob_hash_raw, "\n\r ");

    const git_dir = try std.fmt.allocPrint(testing.allocator, "{s}/.git", .{repo_path});
    defer testing.allocator.free(git_dir);

    const platform = TestPlatform;
    const obj = try objects.GitObject.load(blob_hash, git_dir, platform, testing.allocator);
    defer obj.deinit(testing.allocator);

    try testing.expectEqual(objects.ObjectType.blob, obj.type);
    try testing.expectEqualSlices(u8, &binary_data, obj.data);
}

// ---------------------------------------------------------------------------
// Test 9: fixThinPack with real thin pack from git
// ---------------------------------------------------------------------------
test "fixThinPack with git-generated thin pack" {
    const repo_path = try makeTempRepo();
    defer cleanupTempDir(repo_path);

    freeExec(try execExpectOk(&.{ "git", "init" }, repo_path));
    freeExec(try execExpectOk(&.{ "git", "config", "user.email", "t@t.com" }, repo_path));
    freeExec(try execExpectOk(&.{ "git", "config", "user.name", "T" }, repo_path));

    // Create base content
    {
        const p = try std.fmt.allocPrint(testing.allocator, "{s}/data.txt", .{repo_path});
        defer testing.allocator.free(p);
        try std.fs.cwd().writeFile(.{ .sub_path = p, .data = "base content " ** 100 ++ "\n" });
    }
    freeExec(try execExpectOk(&.{ "git", "add", "-A" }, repo_path));
    freeExec(try execExpectOk(&.{ "git", "commit", "-m", "base" }, repo_path));

    // Get base commit hash
    const base_hash_raw = try execExpectOk(&.{ "git", "rev-parse", "HEAD" }, repo_path);
    defer freeExec(base_hash_raw);
    const base_hash = std.mem.trimRight(u8, base_hash_raw, "\n\r \x00");
    if (base_hash.len != 40) {
        std.debug.print("base_hash len={d} val='{s}'\n", .{ base_hash.len, base_hash });
        return error.BadHash;
    }

    // Modify
    {
        const p = try std.fmt.allocPrint(testing.allocator, "{s}/data.txt", .{repo_path});
        defer testing.allocator.free(p);
        try std.fs.cwd().writeFile(.{ .sub_path = p, .data = "modified content " ++ ("base content " ** 99) ++ "\n" });
    }
    freeExec(try execExpectOk(&.{ "git", "add", "-A" }, repo_path));
    freeExec(try execExpectOk(&.{ "git", "commit", "-m", "modified" }, repo_path));

    // Create a thin pack (only new objects, deltas may reference base_hash objects)
    // --thin flag creates thin packs with REF_DELTA
    // Must pipe through cut -d' ' -f1 because rev-list --objects outputs "hash path" for blobs
    const bash_cmd = try std.fmt.allocPrint(
        testing.allocator,
        "cd {s} && git rev-list --objects HEAD --not {s} | cut -d' ' -f1 | git pack-objects --thin --stdout > /tmp/thin_test.pack",
        .{ repo_path, base_hash },
    );
    defer testing.allocator.free(bash_cmd);

    const result = try exec(&.{ "bash", "-c", bash_cmd }, repo_path);
    defer {
        testing.allocator.free(result.stdout);
        testing.allocator.free(result.stderr);
    }
    if (result.exit_code != 0) {
        std.debug.print("thin pack creation failed: exit={d}\nstderr: {s}\nstdout: {s}\ncmd: {s}\n", .{ result.exit_code, result.stderr, result.stdout, bash_cmd });
        return error.ThinPackCreationFailed;
    }

    // Read the thin pack
    const thin_pack = try std.fs.cwd().readFileAlloc(testing.allocator, "/tmp/thin_test.pack", 64 * 1024 * 1024);
    defer testing.allocator.free(thin_pack);

    // Verify it's a valid pack
    try testing.expectEqualSlices(u8, "PACK", thin_pack[0..4]);

    const git_dir = try std.fmt.allocPrint(testing.allocator, "{s}/.git", .{repo_path});
    defer testing.allocator.free(git_dir);

    // Fix the thin pack using ziggit
    const platform = TestPlatform;
    const fixed = try objects.fixThinPack(thin_pack, git_dir, platform, testing.allocator);
    defer testing.allocator.free(fixed);

    // The fixed pack should be valid
    try testing.expectEqualSlices(u8, "PACK", fixed[0..4]);

    // Verify the fixed pack checksum is valid
    const fixed_content_end = fixed.len - 20;
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(fixed[0..fixed_content_end]);
    var expected_checksum: [20]u8 = undefined;
    hasher.final(&expected_checksum);
    try testing.expectEqualSlices(u8, &expected_checksum, fixed[fixed_content_end..]);
}

// ---------------------------------------------------------------------------
// Test 10: applyDelta unit tests with known inputs
// ---------------------------------------------------------------------------
test "applyDelta: identity copy" {
    const base = "Hello, World!";
    // Delta: base_size=13, result_size=13, copy offset=0 size=13
    var delta_buf: [32]u8 = undefined;
    var pos: usize = 0;

    // base_size = 13
    delta_buf[pos] = 13;
    pos += 1;
    // result_size = 13
    delta_buf[pos] = 13;
    pos += 1;
    // copy cmd: offset=0, size=13
    // cmd byte: 0x80 | 0x10 (size byte 0 present)
    delta_buf[pos] = 0x80 | 0x10;
    pos += 1;
    delta_buf[pos] = 13; // size = 13
    pos += 1;

    const result = try objects.applyDelta(base, delta_buf[0..pos], testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqualSlices(u8, base, result);
}

test "applyDelta: insert only" {
    const base = "unused base!!";
    const new_data = "brand new";
    // Delta: base_size=13, result_size=9, insert 9 bytes
    var delta_buf: [32]u8 = undefined;
    var pos: usize = 0;

    delta_buf[pos] = 13; // base_size (must match base.len for strict mode)
    pos += 1;
    delta_buf[pos] = 9; // result_size
    pos += 1;
    delta_buf[pos] = 9; // insert 9 bytes
    pos += 1;
    @memcpy(delta_buf[pos .. pos + 9], new_data);
    pos += 9;

    const result = try objects.applyDelta(base, delta_buf[0..pos], testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqualSlices(u8, new_data, result);
}

test "applyDelta: copy with offset" {
    const base = "Hello, World!";
    // Copy "World" (offset=7, size=5)
    var delta_buf: [32]u8 = undefined;
    var pos: usize = 0;

    delta_buf[pos] = 13; // base_size
    pos += 1;
    delta_buf[pos] = 5; // result_size
    pos += 1;
    // cmd: 0x80 | 0x01 (offset byte 0) | 0x10 (size byte 0)
    delta_buf[pos] = 0x80 | 0x01 | 0x10;
    pos += 1;
    delta_buf[pos] = 7; // offset = 7
    pos += 1;
    delta_buf[pos] = 5; // size = 5
    pos += 1;

    const result = try objects.applyDelta(base, delta_buf[0..pos], testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqualSlices(u8, "World", result);
}

test "applyDelta: mixed copy and insert" {
    const base = "ABCDEFGHIJ";
    // Result should be "ABC_XY_HIJ" (copy ABC, insert _XY_, copy HIJ)
    const expected = "ABC_XY_HIJ";
    var delta_buf: [64]u8 = undefined;
    var pos: usize = 0;

    delta_buf[pos] = 10; // base_size
    pos += 1;
    delta_buf[pos] = 10; // result_size
    pos += 1;

    // Copy "ABC" from offset 0, size 3
    delta_buf[pos] = 0x80 | 0x10; // no offset bytes (offset=0), size byte 0
    pos += 1;
    delta_buf[pos] = 3; // size=3
    pos += 1;

    // Insert "_XY_" (4 bytes)
    delta_buf[pos] = 4;
    pos += 1;
    @memcpy(delta_buf[pos .. pos + 4], "_XY_");
    pos += 4;

    // Copy "HIJ" from offset 7, size 3
    delta_buf[pos] = 0x80 | 0x01 | 0x10; // offset byte 0, size byte 0
    pos += 1;
    delta_buf[pos] = 7; // offset=7
    pos += 1;
    delta_buf[pos] = 3; // size=3
    pos += 1;

    const result = try objects.applyDelta(base, delta_buf[0..pos], testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqualSlices(u8, expected, result);
}

test "applyDelta: copy size 0 means 0x10000" {
    // Create a base that's at least 0x10000 bytes
    const base_data = try testing.allocator.alloc(u8, 0x10000);
    defer testing.allocator.free(base_data);
    @memset(base_data, 'A');

    // Delta: copy all 0x10000 bytes using size=0 encoding
    var delta_buf: [32]u8 = undefined;
    var pos: usize = 0;

    // base_size = 0x10000 as varint: 0x80|0x00, 0x80|0x00, 0x04
    delta_buf[pos] = 0x80 | 0x00;
    pos += 1;
    delta_buf[pos] = 0x80 | 0x00;
    pos += 1;
    delta_buf[pos] = 0x04; // (4 << 14) = 0x10000
    pos += 1;
    // result_size = 0x10000
    delta_buf[pos] = 0x80 | 0x00;
    pos += 1;
    delta_buf[pos] = 0x80 | 0x00;
    pos += 1;
    delta_buf[pos] = 0x04;
    pos += 1;
    // Copy: offset=0, size=0 (means 0x10000)
    // cmd: 0x80, no offset flags, no size flags
    delta_buf[pos] = 0x80;
    pos += 1;

    const result = try objects.applyDelta(base_data, delta_buf[0..pos], testing.allocator);
    defer testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 0x10000), result.len);
    try testing.expectEqualSlices(u8, base_data, result);
}

// ---------------------------------------------------------------------------
// Test platform implementation (filesystem adapter for objects.zig)
// ---------------------------------------------------------------------------
const TestPlatform = struct {
    pub const fs = struct {
        pub fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
            return std.fs.cwd().readFileAlloc(allocator, path, 256 * 1024 * 1024);
        }

        pub fn writeFile(path: []const u8, data: []const u8) !void {
            const file = try std.fs.cwd().createFile(path, .{});
            defer file.close();
            try file.writeAll(data);
        }

        pub fn makeDir(path: []const u8) !void {
            std.fs.cwd().makePath(path) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }

        pub fn exists(path: []const u8) bool {
            const file = std.fs.cwd().openFile(path, .{}) catch return false;
            defer file.close();
            return true;
        }
    };
};
