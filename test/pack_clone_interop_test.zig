const std = @import("std");
const pack_writer = @import("pack_writer");
const idx_writer = @import("idx_writer");

// ============================================================================
// End-to-end interop tests: git clone -> our idx -> git reads back
// ============================================================================

fn setupTmpDir() ![]const u8 {
    const allocator = std.testing.allocator;
    const tmp = try std.fmt.allocPrint(allocator, "/tmp/ziggit_interop_{}", .{std.crypto.random.int(u64)});
    try std.fs.cwd().makePath(tmp);
    return tmp;
}

fn cleanupTmpDir(path: []const u8) void {
    std.fs.cwd().deleteTree(path) catch {};
    std.testing.allocator.free(path);
}

// ============================================================================
// Full clone interop: git creates repo -> git pack-objects -> our idx
// ============================================================================

test "git pack-objects output + our idx: git verify-pack accepts" {
    const allocator = std.testing.allocator;
    const tmp_dir = try setupTmpDir();
    defer cleanupTmpDir(tmp_dir);

    const src_dir = try std.fmt.allocPrint(allocator, "{s}/src", .{tmp_dir});
    defer allocator.free(src_dir);
    try std.fs.cwd().makePath(src_dir);

    // Create repo with branching history (triggers more complex delta chains)
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

    // Create multiple files across commits
    for (0..4) |i| {
        var buf: [128]u8 = undefined;
        const content = std.fmt.bufPrint(&buf, "Shared header\nVersion={}\nMore shared content\n", .{i}) catch unreachable;
        const fp = try std.fmt.allocPrint(allocator, "{s}/data.txt", .{src_dir});
        defer allocator.free(fp);
        {
            const f = try std.fs.cwd().createFile(fp, .{});
            defer f.close();
            try f.writeAll(content);
        }

        var msg_buf: [16]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "v{}", .{i}) catch unreachable;
        const cmd = try std.fmt.allocPrint(allocator, "cd {s} && git add -A && git commit -m '{s}'", .{ src_dir, msg });
        defer allocator.free(cmd);
        const r = try std.process.Child.run(.{ .allocator = allocator, .argv = &.{ "bash", "-c", cmd }, .max_output_bytes = 1024 * 1024 });
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }

    // Use git pack-objects to create a pack (simulates what server sends)
    const dst_dir = try std.fmt.allocPrint(allocator, "{s}/dst.git", .{tmp_dir});
    defer allocator.free(dst_dir);
    {
        const r = try std.process.Child.run(.{ .allocator = allocator, .argv = &.{ "git", "init", "--bare", dst_dir } });
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }

    // Get all object hashes
    const rev_cmd = try std.fmt.allocPrint(allocator, "cd {s} && git rev-list --all --objects | cut -d' ' -f1", .{src_dir});
    defer allocator.free(rev_cmd);
    const rev_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "bash", "-c", rev_cmd },
        .max_output_bytes = 1024 * 1024,
    });
    defer allocator.free(rev_result.stdout);
    defer allocator.free(rev_result.stderr);

    // Pack all objects
    const pack_dir = try std.fmt.allocPrint(allocator, "{s}/objects/pack", .{dst_dir});
    defer allocator.free(pack_dir);

    const pack_cmd = try std.fmt.allocPrint(
        allocator,
        "cd {s} && git rev-list --all --objects | git pack-objects --stdout > {s}/test.pack",
        .{ src_dir, pack_dir },
    );
    defer allocator.free(pack_cmd);
    const pack_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "bash", "-c", pack_cmd },
        .max_output_bytes = 1024 * 1024,
    });
    allocator.free(pack_result.stdout);
    allocator.free(pack_result.stderr);

    // Read the pack
    const pack_path = try std.fmt.allocPrint(allocator, "{s}/test.pack", .{pack_dir});
    defer allocator.free(pack_path);
    const pack_data = try std.fs.cwd().readFileAlloc(allocator, pack_path, 50 * 1024 * 1024);
    defer allocator.free(pack_data);

    // Save with our pack_writer and generate idx
    const checksum = try pack_writer.savePack(allocator, dst_dir, pack_data);
    defer allocator.free(checksum);
    const proper_pack_path = try pack_writer.packPath(allocator, dst_dir, checksum);
    defer allocator.free(proper_pack_path);

    // Remove the temp pack file
    std.fs.cwd().deleteFile(pack_path) catch {};

    try idx_writer.generateIdx(allocator, proper_pack_path);

    // git verify-pack must accept our output
    const verify = try std.process.Child.run(.{
        .allocator = allocator,
        .max_output_bytes = 10 * 1024 * 1024,
        .argv = &.{ "git", "verify-pack", "-v", proper_pack_path },
    });
    defer allocator.free(verify.stdout);
    defer allocator.free(verify.stderr);
    if (verify.term.Exited != 0) {
        std.debug.print("verify-pack stderr: {s}\n", .{verify.stderr});
    }
    try std.testing.expectEqual(@as(u8, 0), verify.term.Exited);

    // Copy refs from src repo
    const head_cmd = try std.fmt.allocPrint(allocator, "cd {s} && git rev-parse HEAD", .{src_dir});
    defer allocator.free(head_cmd);
    const head_r = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "bash", "-c", head_cmd },
    });
    defer allocator.free(head_r.stdout);
    defer allocator.free(head_r.stderr);
    const head_hash = std.mem.trimRight(u8, head_r.stdout, "\n\r ");

    const refs = [_]pack_writer.RefUpdate{
        .{ .name = "refs/heads/master", .hash = head_hash },
    };
    try pack_writer.updateRefsAfterClone(allocator, dst_dir, &refs, true);

    // git log should work
    const log_r = try std.process.Child.run(.{
        .allocator = allocator,
        .max_output_bytes = 1024 * 1024,
        .argv = &.{ "git", "--git-dir", dst_dir, "log", "--oneline" },
    });
    defer allocator.free(log_r.stdout);
    defer allocator.free(log_r.stderr);
    try std.testing.expectEqual(@as(u8, 0), log_r.term.Exited);

    var commit_count: usize = 0;
    var lines = std.mem.splitScalar(u8, std.mem.trimRight(u8, log_r.stdout, "\n"), '\n');
    while (lines.next()) |line| {
        if (line.len > 0) commit_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), commit_count);
}

// ============================================================================
// Simulated fetch: two incremental packs coexist and git reads both
// ============================================================================

test "incremental fetch: two packs coexist, git reads objects from both" {
    const allocator = std.testing.allocator;
    const tmp_dir = try setupTmpDir();
    defer cleanupTmpDir(tmp_dir);

    const src_dir = try std.fmt.allocPrint(allocator, "{s}/src", .{tmp_dir});
    defer allocator.free(src_dir);
    try std.fs.cwd().makePath(src_dir);

    // Create source repo
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

    // First commit
    {
        const fp = try std.fmt.allocPrint(allocator, "{s}/file1.txt", .{src_dir});
        defer allocator.free(fp);
        const f = try std.fs.cwd().createFile(fp, .{});
        defer f.close();
        try f.writeAll("initial content\n");
    }
    {
        const cmd = try std.fmt.allocPrint(allocator, "cd {s} && git add -A && git commit -m 'first'", .{src_dir});
        defer allocator.free(cmd);
        const r = try std.process.Child.run(.{ .allocator = allocator, .argv = &.{ "bash", "-c", cmd }, .max_output_bytes = 1024 * 1024 });
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }

    // Get hash of first commit
    const hash1_cmd = try std.fmt.allocPrint(allocator, "cd {s} && git rev-parse HEAD", .{src_dir});
    defer allocator.free(hash1_cmd);
    const hash1_r = try std.process.Child.run(.{ .allocator = allocator, .argv = &.{ "bash", "-c", hash1_cmd } });
    defer allocator.free(hash1_r.stdout);
    defer allocator.free(hash1_r.stderr);
    const hash1 = std.mem.trimRight(u8, hash1_r.stdout, "\n\r ");

    // Create pack for first commit
    const dst_dir = try std.fmt.allocPrint(allocator, "{s}/dst.git", .{tmp_dir});
    defer allocator.free(dst_dir);
    {
        const r = try std.process.Child.run(.{ .allocator = allocator, .argv = &.{ "git", "init", "--bare", dst_dir } });
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }

    // Pack objects for first commit
    {
        const cmd = try std.fmt.allocPrint(
            allocator,
            "cd {s} && echo {s} | git pack-objects --revs --stdout",
            .{ src_dir, hash1 },
        );
        defer allocator.free(cmd);
        const r = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "bash", "-c", cmd },
            .max_output_bytes = 50 * 1024 * 1024,
        });
        defer allocator.free(r.stderr);

        // Save first pack
        const ck1 = try pack_writer.savePack(allocator, dst_dir, r.stdout);
        defer allocator.free(ck1);
        const pp1 = try pack_writer.packPath(allocator, dst_dir, ck1);
        defer allocator.free(pp1);
        try idx_writer.generateIdx(allocator, pp1);
        allocator.free(r.stdout);
    }

    // Set up ref in dst
    const refs1 = [_]pack_writer.RefUpdate{
        .{ .name = "refs/heads/master", .hash = hash1 },
    };
    try pack_writer.updateRefsAfterClone(allocator, dst_dir, &refs1, true);

    // Second commit in source
    {
        const fp = try std.fmt.allocPrint(allocator, "{s}/file2.txt", .{src_dir});
        defer allocator.free(fp);
        const f = try std.fs.cwd().createFile(fp, .{});
        defer f.close();
        try f.writeAll("second file\n");
    }
    {
        const cmd = try std.fmt.allocPrint(allocator, "cd {s} && git add -A && git commit -m 'second'", .{src_dir});
        defer allocator.free(cmd);
        const r = try std.process.Child.run(.{ .allocator = allocator, .argv = &.{ "bash", "-c", cmd }, .max_output_bytes = 1024 * 1024 });
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }

    const hash2_cmd = try std.fmt.allocPrint(allocator, "cd {s} && git rev-parse HEAD", .{src_dir});
    defer allocator.free(hash2_cmd);
    const hash2_r = try std.process.Child.run(.{ .allocator = allocator, .argv = &.{ "bash", "-c", hash2_cmd } });
    defer allocator.free(hash2_r.stdout);
    defer allocator.free(hash2_r.stderr);
    const hash2 = std.mem.trimRight(u8, hash2_r.stdout, "\n\r ");

    // Pack only the NEW objects (incremental, like fetch)
    {
        const cmd = try std.fmt.allocPrint(
            allocator,
            "cd {s} && echo '{s}\n^{s}' | git pack-objects --revs --stdout",
            .{ src_dir, hash2, hash1 },
        );
        defer allocator.free(cmd);
        const r = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "bash", "-c", cmd },
            .max_output_bytes = 50 * 1024 * 1024,
        });
        defer allocator.free(r.stderr);

        if (r.stdout.len >= 32) {
            const ck2 = try pack_writer.savePack(allocator, dst_dir, r.stdout);
            defer allocator.free(ck2);
            const pp2 = try pack_writer.packPath(allocator, dst_dir, ck2);
            defer allocator.free(pp2);
            try idx_writer.generateIdx(allocator, pp2);
        }
        allocator.free(r.stdout);
    }

    // Update ref for second commit
    const refs2 = [_]pack_writer.RefUpdate{
        .{ .name = "refs/heads/master", .hash = hash2 },
    };
    try pack_writer.updateRefsAfterClone(allocator, dst_dir, &refs2, true);

    // git log should show both commits
    const log_r = try std.process.Child.run(.{
        .allocator = allocator,
        .max_output_bytes = 1024 * 1024,
        .argv = &.{ "git", "--git-dir", dst_dir, "log", "--oneline" },
    });
    defer allocator.free(log_r.stdout);
    defer allocator.free(log_r.stderr);
    try std.testing.expectEqual(@as(u8, 0), log_r.term.Exited);

    var commit_count: usize = 0;
    var lines = std.mem.splitScalar(u8, std.mem.trimRight(u8, log_r.stdout, "\n"), '\n');
    while (lines.next()) |line| {
        if (line.len > 0) commit_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), commit_count);
}

// ============================================================================
// Bare clone with tags: refs/tags/* must persist
// ============================================================================

test "bare clone with tags: tags are written correctly" {
    const allocator = std.testing.allocator;
    const tmp_dir = try setupTmpDir();
    defer cleanupTmpDir(tmp_dir);

    const src_dir = try std.fmt.allocPrint(allocator, "{s}/src", .{tmp_dir});
    defer allocator.free(src_dir);
    try std.fs.cwd().makePath(src_dir);

    // Create repo with tags
    const cmds = [_][]const u8{
        "git init",
        "git config user.email t@t.com",
        "git config user.name T",
    };
    for (cmds) |cmd| {
        const full = try std.fmt.allocPrint(allocator, "cd {s} && {s}", .{ src_dir, cmd });
        defer allocator.free(full);
        const r = try std.process.Child.run(.{ .allocator = allocator, .argv = &.{ "bash", "-c", full }, .max_output_bytes = 1024 * 1024 });
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }

    {
        const fp = try std.fmt.allocPrint(allocator, "{s}/readme.md", .{src_dir});
        defer allocator.free(fp);
        const f = try std.fs.cwd().createFile(fp, .{});
        defer f.close();
        try f.writeAll("# Test\n");
    }

    const commit_cmds = [_][]const u8{
        "git add -A && git commit -m 'init'",
        "git tag v1.0",
        "git tag -a v2.0 -m 'annotated tag'",
    };
    for (commit_cmds) |cmd| {
        const full = try std.fmt.allocPrint(allocator, "cd {s} && {s}", .{ src_dir, cmd });
        defer allocator.free(full);
        const r = try std.process.Child.run(.{ .allocator = allocator, .argv = &.{ "bash", "-c", full }, .max_output_bytes = 1024 * 1024 });
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }

    // Get the commit hash and tag hashes
    const head_cmd = try std.fmt.allocPrint(allocator, "cd {s} && git rev-parse HEAD", .{src_dir});
    defer allocator.free(head_cmd);
    const head_r = try std.process.Child.run(.{ .allocator = allocator, .argv = &.{ "bash", "-c", head_cmd } });
    defer allocator.free(head_r.stdout);
    defer allocator.free(head_r.stderr);
    const head_hash = std.mem.trimRight(u8, head_r.stdout, "\n\r ");

    const tag_cmd = try std.fmt.allocPrint(allocator, "cd {s} && git rev-parse v1.0", .{src_dir});
    defer allocator.free(tag_cmd);
    const tag_r = try std.process.Child.run(.{ .allocator = allocator, .argv = &.{ "bash", "-c", tag_cmd } });
    defer allocator.free(tag_r.stdout);
    defer allocator.free(tag_r.stderr);
    const tag_hash = std.mem.trimRight(u8, tag_r.stdout, "\n\r ");

    const atag_cmd = try std.fmt.allocPrint(allocator, "cd {s} && git rev-parse v2.0", .{src_dir});
    defer allocator.free(atag_cmd);
    const atag_r = try std.process.Child.run(.{ .allocator = allocator, .argv = &.{ "bash", "-c", atag_cmd } });
    defer allocator.free(atag_r.stdout);
    defer allocator.free(atag_r.stderr);
    const atag_hash = std.mem.trimRight(u8, atag_r.stdout, "\n\r ");

    // Simulate bare clone: create structure and refs
    const dst_dir = try std.fmt.allocPrint(allocator, "{s}/dst.git", .{tmp_dir});
    defer allocator.free(dst_dir);
    {
        const r = try std.process.Child.run(.{ .allocator = allocator, .argv = &.{ "git", "init", "--bare", dst_dir } });
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }

    // Pack all objects
    {
        const cmd = try std.fmt.allocPrint(
            allocator,
            "cd {s} && git rev-list --all --objects | git pack-objects --stdout",
            .{src_dir},
        );
        defer allocator.free(cmd);
        const r = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "bash", "-c", cmd },
            .max_output_bytes = 50 * 1024 * 1024,
        });
        defer allocator.free(r.stderr);

        const ck = try pack_writer.savePack(allocator, dst_dir, r.stdout);
        defer allocator.free(ck);
        const pp = try pack_writer.packPath(allocator, dst_dir, ck);
        defer allocator.free(pp);
        try idx_writer.generateIdx(allocator, pp);
        allocator.free(r.stdout);
    }

    // Write refs (bare clone)
    const refs = [_]pack_writer.RefUpdate{
        .{ .name = "refs/heads/master", .hash = head_hash },
        .{ .name = "refs/tags/v1.0", .hash = tag_hash },
        .{ .name = "refs/tags/v2.0", .hash = atag_hash },
    };
    try pack_writer.updateRefsAfterClone(allocator, dst_dir, &refs, true);

    // Verify HEAD points to master
    {
        const hp = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{dst_dir});
        defer allocator.free(hp);
        const content = try std.fs.cwd().readFileAlloc(allocator, hp, 256);
        defer allocator.free(content);
        try std.testing.expect(std.mem.indexOf(u8, content, "refs/heads/master") != null);
    }

    // Verify tags exist
    {
        const tp = try std.fmt.allocPrint(allocator, "{s}/refs/tags/v1.0", .{dst_dir});
        defer allocator.free(tp);
        const content = try std.fs.cwd().readFileAlloc(allocator, tp, 256);
        defer allocator.free(content);
        try std.testing.expectEqualStrings(tag_hash, std.mem.trimRight(u8, content, "\n"));
    }
    {
        const tp = try std.fmt.allocPrint(allocator, "{s}/refs/tags/v2.0", .{dst_dir});
        defer allocator.free(tp);
        const content = try std.fs.cwd().readFileAlloc(allocator, tp, 256);
        defer allocator.free(content);
        try std.testing.expectEqualStrings(atag_hash, std.mem.trimRight(u8, content, "\n"));
    }

    // git tag --list should show our tags
    const tag_list = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "--git-dir", dst_dir, "tag", "--list" },
    });
    defer allocator.free(tag_list.stdout);
    defer allocator.free(tag_list.stderr);
    try std.testing.expectEqual(@as(u8, 0), tag_list.term.Exited);
    try std.testing.expect(std.mem.indexOf(u8, tag_list.stdout, "v1.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, tag_list.stdout, "v2.0") != null);
}
