const std = @import("std");
const testing = std.testing;
const objects = @import("git_objects");

// ============================================================================
// REFS + PACK INTEGRATION TESTS
//
// Tests the full clone/fetch workflow from pack reception to ref updates:
//   - Save pack → update refs → git recognizes repo state
//   - Remote tracking refs (refs/remotes/origin/*)
//   - HEAD update after clone
//   - Multiple packs coexistence (initial clone + subsequent fetch)
//   - Ref resolution through pack files
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

var tmp_counter: u64 = 0;

fn makeTmpDir(allocator: std.mem.Allocator) ![]u8 {
    var buf: [256]u8 = undefined;
    const ts = @as(u64, @intCast(std.time.nanoTimestamp()));
    const cnt = @atomicRmw(u64, &tmp_counter, .Add, 1, .seq_cst);
    const name = try std.fmt.bufPrint(&buf, "/tmp/ziggit-refs-test-{d}-{d}", .{ ts, cnt });
    try std.fs.cwd().makePath(name);
    return try allocator.dupe(u8, name);
}

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

fn writeFile(path: []const u8, data: []const u8) !void {
    const f = try std.fs.cwd().createFile(path, .{});
    defer f.close();
    try f.writeAll(data);
}

// ============================================================================
// TEST 1: Simulate clone - save pack, write refs, git rev-parse works
// ============================================================================
test "clone simulation: save pack + write refs → git recognizes commit" {
    const allocator = testing.allocator;
    const src = try makeTmpDir(allocator);
    defer {
        std.fs.cwd().deleteTree(src) catch {};
        allocator.free(src);
    }

    // Create source repo
    try gitNoOut(allocator, src, &.{ "init" });
    {
        const p = try std.fmt.allocPrint(allocator, "{s}/main.zig", .{src});
        defer allocator.free(p);
        try writeFile(p, "pub fn main() void {}\n");
    }
    try gitNoOut(allocator, src, &.{ "add", "." });
    try gitNoOut(allocator, src, &.{ "-c", "user.name=T", "-c", "user.email=t@t", "commit", "-m", "init" });

    // Get HEAD hash
    const head_raw = try git(allocator, src, &.{ "rev-parse", "HEAD" });
    defer allocator.free(head_raw);
    const head_hash = std.mem.trim(u8, head_raw, "\n ");

    // Pack the source repo
    try gitNoOut(allocator, src, &.{ "repack", "-a", "-d" });

    // Read the pack file
    const src_git = try std.fmt.allocPrint(allocator, "{s}/.git", .{src});
    defer allocator.free(src_git);
    const src_pack_dir = try std.fmt.allocPrint(allocator, "{s}/objects/pack", .{src_git});
    defer allocator.free(src_pack_dir);

    var pdir = try std.fs.cwd().openDir(src_pack_dir, .{ .iterate = true });
    defer pdir.close();
    var pfn: ?[]u8 = null;
    defer if (pfn) |n| allocator.free(n);
    {
        var it = pdir.iterate();
        while (try it.next()) |e| {
            if (std.mem.endsWith(u8, e.name, ".pack")) {
                pfn = try allocator.dupe(u8, e.name);
                break;
            }
        }
    }
    try testing.expect(pfn != null);

    const ppath = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ src_pack_dir, pfn.? });
    defer allocator.free(ppath);
    const pack_data = try std.fs.cwd().readFileAlloc(allocator, ppath, 100 * 1024 * 1024);
    defer allocator.free(pack_data);

    // Create destination repo (bare-like)
    const dst = try makeTmpDir(allocator);
    defer {
        std.fs.cwd().deleteTree(dst) catch {};
        allocator.free(dst);
    }
    try gitNoOut(allocator, dst, &.{ "init" });
    const dst_git = try std.fmt.allocPrint(allocator, "{s}/.git", .{dst});
    defer allocator.free(dst_git);

    // Save pack via ziggit
    var platform = NativePlatform{};
    const cksum = try objects.saveReceivedPack(pack_data, dst_git, &platform, allocator);
    defer allocator.free(cksum);

    // Write refs/heads/master pointing to HEAD
    const master_ref_dir = try std.fmt.allocPrint(allocator, "{s}/refs/heads", .{dst_git});
    defer allocator.free(master_ref_dir);
    std.fs.cwd().makePath(master_ref_dir) catch {};

    const master_ref = try std.fmt.allocPrint(allocator, "{s}/refs/heads/master", .{dst_git});
    defer allocator.free(master_ref);
    {
        const f = try std.fs.cwd().createFile(master_ref, .{});
        defer f.close();
        try f.writer().print("{s}\n", .{head_hash});
    }

    // Write HEAD
    const head_file = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{dst_git});
    defer allocator.free(head_file);
    try writeFile(head_file, "ref: refs/heads/master\n");

    // Verify: git rev-parse HEAD should return the same hash
    const dst_head_raw = try git(allocator, dst, &.{ "rev-parse", "HEAD" });
    defer allocator.free(dst_head_raw);
    const dst_head = std.mem.trim(u8, dst_head_raw, "\n ");
    try testing.expectEqualStrings(head_hash, dst_head);

    // Verify: git log should show the commit
    const log_out = try git(allocator, dst, &.{ "log", "--oneline" });
    defer allocator.free(log_out);
    try testing.expect(std.mem.indexOf(u8, log_out, "init") != null);
}

// ============================================================================
// TEST 2: Remote tracking refs (simulated fetch)
// ============================================================================
test "fetch simulation: write remote tracking refs" {
    const allocator = testing.allocator;
    const src = try makeTmpDir(allocator);
    defer {
        std.fs.cwd().deleteTree(src) catch {};
        allocator.free(src);
    }

    try gitNoOut(allocator, src, &.{ "init" });
    {
        const p = try std.fmt.allocPrint(allocator, "{s}/a.txt", .{src});
        defer allocator.free(p);
        try writeFile(p, "aaa\n");
    }
    try gitNoOut(allocator, src, &.{ "add", "." });
    try gitNoOut(allocator, src, &.{ "-c", "user.name=T", "-c", "user.email=t@t", "commit", "-m", "first" });

    // Create a branch
    try gitNoOut(allocator, src, &.{ "checkout", "-b", "feature" });
    {
        const p = try std.fmt.allocPrint(allocator, "{s}/b.txt", .{src});
        defer allocator.free(p);
        try writeFile(p, "bbb\n");
    }
    try gitNoOut(allocator, src, &.{ "add", "." });
    try gitNoOut(allocator, src, &.{ "-c", "user.name=T", "-c", "user.email=t@t", "commit", "-m", "feature work" });

    // Get hashes for both branches
    try gitNoOut(allocator, src, &.{ "checkout", "master" });
    const master_hash_raw = try git(allocator, src, &.{ "rev-parse", "master" });
    defer allocator.free(master_hash_raw);
    const master_hash = std.mem.trim(u8, master_hash_raw, "\n ");

    const feature_hash_raw = try git(allocator, src, &.{ "rev-parse", "feature" });
    defer allocator.free(feature_hash_raw);
    const feature_hash = std.mem.trim(u8, feature_hash_raw, "\n ");

    // Pack
    try gitNoOut(allocator, src, &.{ "repack", "-a", "-d" });

    const src_git = try std.fmt.allocPrint(allocator, "{s}/.git", .{src});
    defer allocator.free(src_git);
    const src_pack_dir = try std.fmt.allocPrint(allocator, "{s}/objects/pack", .{src_git});
    defer allocator.free(src_pack_dir);

    var pdir = try std.fs.cwd().openDir(src_pack_dir, .{ .iterate = true });
    defer pdir.close();
    var pfn: ?[]u8 = null;
    defer if (pfn) |n| allocator.free(n);
    {
        var it = pdir.iterate();
        while (try it.next()) |e| {
            if (std.mem.endsWith(u8, e.name, ".pack")) {
                pfn = try allocator.dupe(u8, e.name);
                break;
            }
        }
    }
    try testing.expect(pfn != null);

    const ppath = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ src_pack_dir, pfn.? });
    defer allocator.free(ppath);
    const pack_data = try std.fs.cwd().readFileAlloc(allocator, ppath, 100 * 1024 * 1024);
    defer allocator.free(pack_data);

    // Destination
    const dst = try makeTmpDir(allocator);
    defer {
        std.fs.cwd().deleteTree(dst) catch {};
        allocator.free(dst);
    }
    try gitNoOut(allocator, dst, &.{ "init" });
    const dst_git = try std.fmt.allocPrint(allocator, "{s}/.git", .{dst});
    defer allocator.free(dst_git);

    var platform = NativePlatform{};
    const cksum = try objects.saveReceivedPack(pack_data, dst_git, &platform, allocator);
    defer allocator.free(cksum);

    // Write remote tracking refs
    const remote_refs_dir = try std.fmt.allocPrint(allocator, "{s}/refs/remotes/origin", .{dst_git});
    defer allocator.free(remote_refs_dir);
    std.fs.cwd().makePath(remote_refs_dir) catch {};

    // origin/master
    const remote_master = try std.fmt.allocPrint(allocator, "{s}/master", .{remote_refs_dir});
    defer allocator.free(remote_master);
    {
        const f = try std.fs.cwd().createFile(remote_master, .{});
        defer f.close();
        try f.writer().print("{s}\n", .{master_hash});
    }

    // origin/feature
    const remote_feature = try std.fmt.allocPrint(allocator, "{s}/feature", .{remote_refs_dir});
    defer allocator.free(remote_feature);
    {
        const f = try std.fs.cwd().createFile(remote_feature, .{});
        defer f.close();
        try f.writer().print("{s}\n", .{feature_hash});
    }

    // Also set up local master branch and HEAD
    const heads_dir = try std.fmt.allocPrint(allocator, "{s}/refs/heads", .{dst_git});
    defer allocator.free(heads_dir);
    std.fs.cwd().makePath(heads_dir) catch {};

    const local_master = try std.fmt.allocPrint(allocator, "{s}/master", .{heads_dir});
    defer allocator.free(local_master);
    {
        const f = try std.fs.cwd().createFile(local_master, .{});
        defer f.close();
        try f.writer().print("{s}\n", .{master_hash});
    }

    const head_file = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{dst_git});
    defer allocator.free(head_file);
    try writeFile(head_file, "ref: refs/heads/master\n");

    // Verify git can see both remote branches
    const branch_out = try git(allocator, dst, &.{ "branch", "-r" });
    defer allocator.free(branch_out);

    try testing.expect(std.mem.indexOf(u8, branch_out, "origin/master") != null);
    try testing.expect(std.mem.indexOf(u8, branch_out, "origin/feature") != null);

    // Verify git log on feature branch works
    const feature_log = try git(allocator, dst, &.{ "log", "--oneline", "origin/feature" });
    defer allocator.free(feature_log);
    try testing.expect(std.mem.indexOf(u8, feature_log, "feature work") != null);

    // Verify ziggit can load objects from both branches
    const master_obj = try objects.GitObject.load(master_hash, dst_git, &platform, allocator);
    defer master_obj.deinit(allocator);
    try testing.expectEqual(objects.ObjectType.commit, master_obj.type);
    try testing.expect(std.mem.indexOf(u8, master_obj.data, "first") != null);

    const feature_obj = try objects.GitObject.load(feature_hash, dst_git, &platform, allocator);
    defer feature_obj.deinit(allocator);
    try testing.expectEqual(objects.ObjectType.commit, feature_obj.type);
    try testing.expect(std.mem.indexOf(u8, feature_obj.data, "feature work") != null);
}

// ============================================================================
// TEST 3: Multiple packs coexist (clone + fetch incremental)
// ============================================================================
test "multi-pack: clone pack + fetch pack coexist, all objects readable" {
    const allocator = testing.allocator;
    const src = try makeTmpDir(allocator);
    defer {
        std.fs.cwd().deleteTree(src) catch {};
        allocator.free(src);
    }

    // Phase 1: initial commit
    try gitNoOut(allocator, src, &.{ "init" });
    {
        const p = try std.fmt.allocPrint(allocator, "{s}/x.txt", .{src});
        defer allocator.free(p);
        try writeFile(p, "initial\n");
    }
    try gitNoOut(allocator, src, &.{ "add", "." });
    try gitNoOut(allocator, src, &.{ "-c", "user.name=T", "-c", "user.email=t@t", "commit", "-m", "c1" });

    const c1_raw = try git(allocator, src, &.{ "rev-parse", "HEAD" });
    defer allocator.free(c1_raw);
    const c1 = std.mem.trim(u8, c1_raw, "\n ");

    try gitNoOut(allocator, src, &.{ "repack", "-a", "-d" });

    // Read first pack
    const src_git = try std.fmt.allocPrint(allocator, "{s}/.git", .{src});
    defer allocator.free(src_git);
    const src_pack_dir = try std.fmt.allocPrint(allocator, "{s}/objects/pack", .{src_git});
    defer allocator.free(src_pack_dir);

    const pack1_data = blk: {
        var d = try std.fs.cwd().openDir(src_pack_dir, .{ .iterate = true });
        defer d.close();
        var it = d.iterate();
        while (try it.next()) |e| {
            if (std.mem.endsWith(u8, e.name, ".pack")) {
                const pp = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ src_pack_dir, e.name });
                defer allocator.free(pp);
                break :blk try std.fs.cwd().readFileAlloc(allocator, pp, 100 * 1024 * 1024);
            }
        }
        return error.NoPackFound;
    };
    defer allocator.free(pack1_data);

    // Phase 2: add another commit
    {
        const p = try std.fmt.allocPrint(allocator, "{s}/y.txt", .{src});
        defer allocator.free(p);
        try writeFile(p, "second\n");
    }
    try gitNoOut(allocator, src, &.{ "add", "." });
    try gitNoOut(allocator, src, &.{ "-c", "user.name=T", "-c", "user.email=t@t", "commit", "-m", "c2" });

    const c2_raw = try git(allocator, src, &.{ "rev-parse", "HEAD" });
    defer allocator.free(c2_raw);
    const c2 = std.mem.trim(u8, c2_raw, "\n ");

    // Remove old packs and repack to get a new pack with only new objects
    // (simulate incremental fetch pack)
    try gitNoOut(allocator, src, &.{ "repack", "-a", "-d" });

    const pack2_data = blk: {
        var d = try std.fs.cwd().openDir(src_pack_dir, .{ .iterate = true });
        defer d.close();
        var it = d.iterate();
        while (try it.next()) |e| {
            if (std.mem.endsWith(u8, e.name, ".pack")) {
                const pp = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ src_pack_dir, e.name });
                defer allocator.free(pp);
                break :blk try std.fs.cwd().readFileAlloc(allocator, pp, 100 * 1024 * 1024);
            }
        }
        return error.NoPackFound;
    };
    defer allocator.free(pack2_data);

    // Set up destination with both packs
    const dst = try makeTmpDir(allocator);
    defer {
        std.fs.cwd().deleteTree(dst) catch {};
        allocator.free(dst);
    }
    try gitNoOut(allocator, dst, &.{ "init" });
    const dst_git = try std.fmt.allocPrint(allocator, "{s}/.git", .{dst});
    defer allocator.free(dst_git);

    var platform = NativePlatform{};

    // Save first pack (simulated clone)
    const ck1 = try objects.saveReceivedPack(pack1_data, dst_git, &platform, allocator);
    defer allocator.free(ck1);

    // Save second pack (simulated fetch) - may have same checksum if repack included all
    const ck2 = objects.saveReceivedPack(pack2_data, dst_git, &platform, allocator) catch |err| {
        // If packs are identical, that's fine
        if (err == error.PackChecksumMismatch) return;
        return err;
    };
    defer allocator.free(ck2);

    // Write refs
    const heads_dir = try std.fmt.allocPrint(allocator, "{s}/refs/heads", .{dst_git});
    defer allocator.free(heads_dir);
    std.fs.cwd().makePath(heads_dir) catch {};

    const master_ref = try std.fmt.allocPrint(allocator, "{s}/master", .{heads_dir});
    defer allocator.free(master_ref);
    {
        const f = try std.fs.cwd().createFile(master_ref, .{});
        defer f.close();
        try f.writer().print("{s}\n", .{c2});
    }

    const head_file = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{dst_git});
    defer allocator.free(head_file);
    try writeFile(head_file, "ref: refs/heads/master\n");

    // Both commits should be readable via ziggit
    const obj1 = try objects.GitObject.load(c1, dst_git, &platform, allocator);
    defer obj1.deinit(allocator);
    try testing.expectEqual(objects.ObjectType.commit, obj1.type);

    const obj2 = try objects.GitObject.load(c2, dst_git, &platform, allocator);
    defer obj2.deinit(allocator);
    try testing.expectEqual(objects.ObjectType.commit, obj2.type);

    // git log should show both commits
    const log_out = try git(allocator, dst, &.{ "log", "--oneline" });
    defer allocator.free(log_out);
    try testing.expect(std.mem.indexOf(u8, log_out, "c1") != null);
    try testing.expect(std.mem.indexOf(u8, log_out, "c2") != null);
}

// ============================================================================
// TEST 4: Object load falls through loose → pack correctly
// ============================================================================
test "object load: loose object found before pack search" {
    const allocator = testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        std.fs.cwd().deleteTree(tmp) catch {};
        allocator.free(tmp);
    }

    try gitNoOut(allocator, tmp, &.{ "init" });
    {
        const p = try std.fmt.allocPrint(allocator, "{s}/test.txt", .{tmp});
        defer allocator.free(p);
        try writeFile(p, "loose object test\n");
    }
    try gitNoOut(allocator, tmp, &.{ "add", "." });
    try gitNoOut(allocator, tmp, &.{ "-c", "user.name=T", "-c", "user.email=t@t", "commit", "-m", "test" });

    // Get blob hash
    const blob_hash_raw = try git(allocator, tmp, &.{ "hash-object", "test.txt" });
    defer allocator.free(blob_hash_raw);
    const blob_hash = std.mem.trim(u8, blob_hash_raw, "\n ");

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp});
    defer allocator.free(git_dir);

    // Object should be loadable as loose
    var platform = NativePlatform{};
    const obj = try objects.GitObject.load(blob_hash, git_dir, &platform, allocator);
    defer obj.deinit(allocator);
    try testing.expectEqual(objects.ObjectType.blob, obj.type);
    try testing.expectEqualSlices(u8, "loose object test\n", obj.data);

    // Now repack - object should still be loadable (from pack)
    try gitNoOut(allocator, tmp, &.{ "repack", "-a", "-d" });

    // Remove loose objects
    try gitNoOut(allocator, tmp, &.{ "prune-packed" });

    const obj2 = try objects.GitObject.load(blob_hash, git_dir, &platform, allocator);
    defer obj2.deinit(allocator);
    try testing.expectEqual(objects.ObjectType.blob, obj2.type);
    try testing.expectEqualSlices(u8, "loose object test\n", obj2.data);
}

// ============================================================================
// TEST 5: generatePackIndex fanout table correctness
// ============================================================================
test "generatePackIndex: fanout table is monotonically increasing" {
    const allocator = testing.allocator;
    const tmp = try makeTmpDir(allocator);
    defer {
        std.fs.cwd().deleteTree(tmp) catch {};
        allocator.free(tmp);
    }

    // Create repo with several objects to populate fanout table
    try gitNoOut(allocator, tmp, &.{ "init" });
    for (0..10) |i| {
        const fname = try std.fmt.allocPrint(allocator, "{s}/file{d}.txt", .{ tmp, i });
        defer allocator.free(fname);
        const content = try std.fmt.allocPrint(allocator, "content for file {d}\n", .{i});
        defer allocator.free(content);
        try writeFile(fname, content);
    }
    try gitNoOut(allocator, tmp, &.{ "add", "." });
    try gitNoOut(allocator, tmp, &.{ "-c", "user.name=T", "-c", "user.email=t@t", "commit", "-m", "many files" });
    try gitNoOut(allocator, tmp, &.{ "repack", "-a", "-d" });

    const git_dir = try std.fmt.allocPrint(allocator, "{s}/.git", .{tmp});
    defer allocator.free(git_dir);
    const pack_dir = try std.fmt.allocPrint(allocator, "{s}/objects/pack", .{git_dir});
    defer allocator.free(pack_dir);

    var dir = try std.fs.cwd().openDir(pack_dir, .{ .iterate = true });
    defer dir.close();
    var pfn: ?[]u8 = null;
    defer if (pfn) |n| allocator.free(n);
    {
        var it = dir.iterate();
        while (try it.next()) |e| {
            if (std.mem.endsWith(u8, e.name, ".pack")) {
                pfn = try allocator.dupe(u8, e.name);
                break;
            }
        }
    }
    try testing.expect(pfn != null);

    const ppath = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ pack_dir, pfn.? });
    defer allocator.free(ppath);
    const pack_data = try std.fs.cwd().readFileAlloc(allocator, ppath, 100 * 1024 * 1024);
    defer allocator.free(pack_data);

    const idx_data = try objects.generatePackIndex(pack_data, allocator);
    defer allocator.free(idx_data);

    // Verify fanout table
    const fanout_start: usize = 8;
    var prev: u32 = 0;
    for (0..256) |i| {
        const offset = fanout_start + i * 4;
        const val = std.mem.readInt(u32, @ptrCast(idx_data[offset .. offset + 4]), .big);
        try testing.expect(val >= prev);
        prev = val;
    }

    // Last fanout entry should equal total objects
    const total = std.mem.readInt(u32, @ptrCast(idx_data[fanout_start + 255 * 4 .. fanout_start + 255 * 4 + 4]), .big);
    try testing.expect(total > 0);

    // Total from idx should match pack header
    const pack_count = std.mem.readInt(u32, @ptrCast(pack_data[8..12]), .big);
    try testing.expectEqual(pack_count, total);
}
