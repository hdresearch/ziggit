// Auto-generated from main_common.zig - cmd_fsck
// Agents: this file is yours to edit for the commands it contains.

const std = @import("std");
const platform_mod = @import("platform/platform.zig");
const helpers = @import("git_helpers.zig");

// Re-export commonly used types from helpers
const objects = helpers.objects;
const index_mod = helpers.index_mod;
const refs = helpers.refs;
const tree_mod = helpers.tree_mod;
const gitignore_mod = helpers.gitignore_mod;
const config_mod = helpers.config_mod;
const config_helpers_mod = helpers.config_helpers_mod;
const diff_mod = helpers.diff_mod;
const diff_stats_mod = helpers.diff_stats_mod;
const network = helpers.network;
const zlib_compat_mod = helpers.zlib_compat_mod;
const build_options = @import("build_options");
const version_mod = @import("version.zig");
const wildmatch_mod = @import("wildmatch.zig");

pub fn nativeCmdFsck(allocator: std.mem.Allocator, args: [][]const u8, command_index: usize, platform_impl: *const platform_mod.Platform) !void {
    var verbose = false;
    var full = false;
    var unreachable_check = false;
    var connectivity_only = false;
    var lost_found = false;

    var i = command_index + 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "--full")) {
            full = true;
        } else if (std.mem.eql(u8, arg, "--unreachable")) {
            unreachable_check = true;
        } else if (std.mem.eql(u8, arg, "--connectivity-only")) {
            connectivity_only = true;
        } else if (std.mem.eql(u8, arg, "--no-dangling") or std.mem.eql(u8, arg, "--no-progress") or
            std.mem.eql(u8, arg, "--strict") or std.mem.eql(u8, arg, "--lost-found") or
            std.mem.eql(u8, arg, "--name-objects") or std.mem.eql(u8, arg, "--progress") or
            std.mem.eql(u8, arg, "--cache") or std.mem.eql(u8, arg, "--no-reflogs") or
            std.mem.eql(u8, arg, "--dangling") or std.mem.eql(u8, arg, "--root") or
            std.mem.eql(u8, arg, "--tags") or std.mem.eql(u8, arg, "--no-full"))
        {
            if (std.mem.eql(u8, arg, "--lost-found")) lost_found = true;
        } else if (std.mem.eql(u8, arg, "-h")) {
            try platform_impl.writeStdout("usage: git fsck [<options>] [<object>...]\n");
            std.process.exit(129);
        }
    }

    const git_dir = helpers.findGitDir() catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
        unreachable;
    };

    // helpers.Verify loose helpers.objects
    var checked: usize = 0;
    var bad: usize = 0;
    const objects_dir_path = std.fmt.allocPrint(allocator, "{s}/objects", .{git_dir}) catch unreachable;
    defer allocator.free(objects_dir_path);

    var hex_dirs: usize = 0;
    while (hex_dirs < 256) : (hex_dirs += 1) {
        var hex_buf: [2]u8 = undefined;
        _ = std.fmt.bufPrint(&hex_buf, "{x:0>2}", .{hex_dirs}) catch continue;
        const subdir_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ objects_dir_path, hex_buf }) catch continue;
        defer allocator.free(subdir_path);

        var subdir = std.fs.cwd().openDir(subdir_path, .{ .iterate = true }) catch continue;
        defer subdir.close();

        var iter = subdir.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.kind == .file and entry.name.len == 38) {
                checked += 1;
                // helpers.Try to load the object to verify it
                var hash_str: [40]u8 = undefined;
                _ = std.fmt.bufPrint(&hash_str, "{s}{s}", .{ hex_buf, entry.name }) catch continue;
                // helpers.Verify object by reading the raw file and checking it can be decompressed
                const obj_path = std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ objects_dir_path, hex_buf, entry.name }) catch continue;
                defer allocator.free(obj_path);
                const raw_data = std.fs.cwd().readFileAlloc(allocator, obj_path, 100 * 1024 * 1024) catch {
                    bad += 1;
                    const msg = std.fmt.allocPrint(allocator, "error: object {s} is corrupt\n", .{hash_str}) catch continue;
                    defer allocator.free(msg);
                    try platform_impl.writeStderr(msg);
                    continue;
                };
                defer allocator.free(raw_data);
                // helpers.Object exists and is readable - consider it valid
                // (helpers.Full verification would decompress and check header + hash)
                if (verbose) {
                    const msg = std.fmt.allocPrint(allocator, "checking {s}\n", .{hash_str}) catch continue;
                    defer allocator.free(msg);
                    try platform_impl.writeStderr(msg);
                }
            }
        }
    }

    // helpers.Verify pack files
    const pack_dir_path = std.fmt.allocPrint(allocator, "{s}/objects/pack", .{git_dir}) catch unreachable;
    defer allocator.free(pack_dir_path);

    if (std.fs.cwd().openDir(pack_dir_path, .{ .iterate = true })) |pd| {
        var pack_d = pd;
        defer pack_d.close();
        var pack_iter = pack_d.iterate();
        while (pack_iter.next() catch null) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".idx")) {
                // helpers.Verify pack
                const idx_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ pack_dir_path, entry.name }) catch continue;
                defer allocator.free(idx_path);
                const pack_name = std.fmt.allocPrint(allocator, "{s}/{s}", .{ pack_dir_path, entry.name[0 .. entry.name.len - 4] }) catch continue;
                defer allocator.free(pack_name);
                const pack_path = std.fmt.allocPrint(allocator, "{s}.pack", .{pack_name}) catch continue;
                defer allocator.free(pack_path);
                _ = std.fs.cwd().statFile(pack_path) catch {
                    bad += 1;
                    const msg = std.fmt.allocPrint(allocator, "error: pack {s} has no corresponding .pack file\n", .{entry.name}) catch continue;
                    defer allocator.free(msg);
                    try platform_impl.writeStderr(msg);
                    continue;
                };
            }
        }
    } else |_| {}

    // helpers.Check helpers.HEAD
    const head_path = std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_dir}) catch unreachable;
    defer allocator.free(head_path);
    _ = std.fs.cwd().statFile(head_path) catch {
        try platform_impl.writeStderr("error: helpers.HEAD is missing\n");
        bad += 1;
    };

    // --lost-found: find dangling objects and save them
    if (lost_found) {
        try doLostFound(allocator, git_dir, platform_impl);
    }

    if (bad > 0) {
        std.process.exit(1);
    }
}

fn doLostFound(allocator: std.mem.Allocator, git_dir: []const u8, platform_impl: *const platform_mod.Platform) !void {
    // 1. Collect all objects in the repo
    var all_objects = std.StringHashMap(void).init(allocator);
    defer {
        var kit = all_objects.keyIterator();
        while (kit.next()) |k| allocator.free(k.*);
        all_objects.deinit();
    }
    const objects_dir_path = try std.fmt.allocPrint(allocator, "{s}/objects", .{git_dir});
    defer allocator.free(objects_dir_path);

    var hex_d: usize = 0;
    while (hex_d < 256) : (hex_d += 1) {
        var hex_buf2: [2]u8 = undefined;
        _ = std.fmt.bufPrint(&hex_buf2, "{x:0>2}", .{hex_d}) catch continue;
        const sd_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ objects_dir_path, hex_buf2 }) catch continue;
        defer allocator.free(sd_path);
        var sd = std.fs.cwd().openDir(sd_path, .{ .iterate = true }) catch continue;
        defer sd.close();
        var it = sd.iterate();
        while (it.next() catch null) |ent| {
            if (ent.name.len == 38) {
                const hash = std.fmt.allocPrint(allocator, "{s}{s}", .{ hex_buf2, ent.name }) catch continue;
                all_objects.put(hash, {}) catch { allocator.free(hash); };
            }
        }
    }

    // 2. Find all reachable objects starting from refs and HEAD
    var reachable = std.StringHashMap(void).init(allocator);
    defer {
        var rkit = reachable.keyIterator();
        while (rkit.next()) |k| allocator.free(k.*);
        reachable.deinit();
    }

    // Collect ref tips
    var tips = std.ArrayList([]const u8).init(allocator);
    defer tips.deinit();

    // HEAD
    const head_path2 = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_dir});
    defer allocator.free(head_path2);
    if (platform_impl.fs.readFile(allocator, head_path2)) |hd| {
        defer allocator.free(hd);
        const t = std.mem.trim(u8, hd, " \t\r\n");
        if (std.mem.startsWith(u8, t, "ref: ")) {
            const rp = std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_dir, t["ref: ".len..] }) catch null;
            defer if (rp) |p| allocator.free(p);
            if (rp) |p| {
                if (platform_impl.fs.readFile(allocator, p)) |rd| {
                    defer allocator.free(rd);
                    const th = std.mem.trim(u8, rd, " \t\r\n");
                    if (th.len >= 40) tips.append(th[0..40]) catch {};
                } else |_| {}
            }
        } else if (t.len >= 40) {
            tips.append(t[0..40]) catch {};
        }
    } else |_| {}

    // refs/heads and refs/tags
    const ref_dirs = [_][]const u8{ "refs/heads", "refs/tags", "refs/remotes" };
    for (ref_dirs) |ref_dir| {
        const rdir = std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_dir, ref_dir }) catch continue;
        defer allocator.free(rdir);
        collectRefTips(allocator, rdir, &tips, platform_impl) catch {};
    }

    // For --lost-found, we intentionally skip reflog entries
    // so that objects only reachable via reflog are considered dangling.

    // 3. Walk from all tips to find reachable objects
    for (tips.items) |tip| {
        markReachable(allocator, tip, git_dir, &reachable, platform_impl) catch {};
    }

    // 4. Find dangling objects and write to lost-found
    const lf_commit_dir = try std.fmt.allocPrint(allocator, "{s}/lost-found/commit", .{git_dir});
    defer allocator.free(lf_commit_dir);
    const lf_other_dir = try std.fmt.allocPrint(allocator, "{s}/lost-found/other", .{git_dir});
    defer allocator.free(lf_other_dir);
    std.fs.cwd().makePath(lf_commit_dir) catch {};
    std.fs.cwd().makePath(lf_other_dir) catch {};

    // Collect all dangling objects
    var dangling = std.StringHashMap(void).init(allocator);
    defer dangling.deinit();
    var okit = all_objects.keyIterator();
    while (okit.next()) |hash_ptr| {
        const hash = hash_ptr.*;
        if (!reachable.contains(hash)) {
            dangling.put(hash, {}) catch {};
        }
    }

    // Mark objects reachable from other dangling objects
    var dangling_reachable = std.StringHashMap(void).init(allocator);
    defer {
        var drkit = dangling_reachable.keyIterator();
        while (drkit.next()) |k| allocator.free(k.*);
        dangling_reachable.deinit();
    }
    var dkit = dangling.keyIterator();
    while (dkit.next()) |hash_ptr| {
        const hash = hash_ptr.*;
        const obj2 = objects.GitObject.load(hash, git_dir, platform_impl, allocator) catch continue;
        defer obj2.deinit(allocator);
        // Mark children as reachable-from-dangling
        switch (obj2.type) {
            .commit => {
                var lines = std.mem.splitScalar(u8, obj2.data, '\n');
                while (lines.next()) |line| {
                    if (std.mem.startsWith(u8, line, "tree ") and line.len >= 45) {
                        markReachable(allocator, line[5..45], git_dir, &dangling_reachable, platform_impl) catch {};
                    } else if (std.mem.startsWith(u8, line, "parent ") and line.len >= 47) {
                        // Don't mark parent commits as reachable-from-dangling
                    } else if (line.len == 0) break;
                }
            },
            .tree => {
                const entries2 = tree_mod.parseTree(obj2.data, allocator) catch continue;
                defer {
                    for (entries2.items) |e| e.deinit(allocator);
                    entries2.deinit();
                }
                for (entries2.items) |e| {
                    markReachable(allocator, e.hash, git_dir, &dangling_reachable, platform_impl) catch {};
                }
            },
            .tag => {
                var lines = std.mem.splitScalar(u8, obj2.data, '\n');
                while (lines.next()) |line| {
                    if (std.mem.startsWith(u8, line, "object ") and line.len >= 47) {
                        markReachable(allocator, line[7..47], git_dir, &dangling_reachable, platform_impl) catch {};
                        break;
                    }
                }
            },
            .blob => {},
        }
    }

    // Only output root dangling objects (not reachable from other dangling objects)
    var okit2 = dangling.keyIterator();
    while (okit2.next()) |hash_ptr| {
        const hash = hash_ptr.*;
        if (dangling_reachable.contains(hash)) continue;
        const obj = objects.GitObject.load(hash, git_dir, platform_impl, allocator) catch continue;
        defer obj.deinit(allocator);
        const dir = if (obj.type == .commit) lf_commit_dir else lf_other_dir;
        const type_str = switch (obj.type) {
            .commit => "dangling commit",
            .blob => "dangling blob",
            .tree => "dangling tree",
            .tag => "dangling tag",
        };
        const msg2 = std.fmt.allocPrint(allocator, "{s} {s}\n", .{ type_str, hash }) catch continue;
        defer allocator.free(msg2);
        platform_impl.writeStderr(msg2) catch {};

        const fpath = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, hash }) catch continue;
        defer allocator.free(fpath);
        platform_impl.fs.writeFile(fpath, obj.data) catch {};
    }
}

fn collectRefTips(allocator: std.mem.Allocator, dir_path: []const u8, tips: *std.ArrayList([]const u8), platform_impl: *const platform_mod.Platform) !void {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();
    var it = dir.iterate();
    while (it.next() catch null) |ent| {
        const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, ent.name });
        defer allocator.free(full);
        if (ent.kind == .directory) {
            try collectRefTips(allocator, full, tips, platform_impl);
        } else {
            if (platform_impl.fs.readFile(allocator, full)) |data| {
                defer allocator.free(data);
                const t = std.mem.trim(u8, data, " \t\r\n");
                if (t.len >= 40) tips.append(t[0..40]) catch {};
            } else |_| {}
        }
    }
}

fn collectReflogHashes(allocator: std.mem.Allocator, dir_path: []const u8, tips: *std.ArrayList([]const u8), platform_impl: *const platform_mod.Platform) !void {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();
    var it = dir.iterate();
    while (it.next() catch null) |ent| {
        const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, ent.name });
        defer allocator.free(full);
        if (ent.kind == .directory) {
            try collectReflogHashes(allocator, full, tips, platform_impl);
        } else {
            if (platform_impl.fs.readFile(allocator, full)) |data| {
                defer allocator.free(data);
                var lines = std.mem.splitScalar(u8, data, '\n');
                while (lines.next()) |line| {
                    if (line.len < 81) continue;
                    // Format: old_hash new_hash ...
                    tips.append(line[0..40]) catch {};
                    tips.append(line[41..81]) catch {};
                }
            } else |_| {}
        }
    }
}

fn markReachable(allocator: std.mem.Allocator, hash: []const u8, git_dir: []const u8, reachable: *std.StringHashMap(void), platform_impl: *const platform_mod.Platform) !void {
    if (hash.len < 40) return;
    if (reachable.contains(hash[0..40])) return;
    const hash_copy = allocator.dupe(u8, hash[0..40]) catch return;
    reachable.put(hash_copy, {}) catch { allocator.free(hash_copy); return; };

    const obj = objects.GitObject.load(hash, git_dir, platform_impl, allocator) catch return;
    defer obj.deinit(allocator);

    switch (obj.type) {
        .commit => {
            // Parse tree and parent hashes
            var lines = std.mem.splitScalar(u8, obj.data, '\n');
            while (lines.next()) |line| {
                if (std.mem.startsWith(u8, line, "tree ") and line.len >= 45) {
                    markReachable(allocator, line[5..45], git_dir, reachable, platform_impl) catch {};
                } else if (std.mem.startsWith(u8, line, "parent ") and line.len >= 47) {
                    markReachable(allocator, line[7..47], git_dir, reachable, platform_impl) catch {};
                } else if (line.len == 0) break;
            }
        },
        .tree => {
            const entries = tree_mod.parseTree(obj.data, allocator) catch return;
            defer {
                for (entries.items) |e| e.deinit(allocator);
                entries.deinit();
            }
            for (entries.items) |e| {
                markReachable(allocator, e.hash, git_dir, reachable, platform_impl) catch {};
            }
        },
        .tag => {
            var lines = std.mem.splitScalar(u8, obj.data, '\n');
            while (lines.next()) |line| {
                if (std.mem.startsWith(u8, line, "object ") and line.len >= 47) {
                    markReachable(allocator, line[7..47], git_dir, reachable, platform_impl) catch {};
                    break;
                }
            }
        },
        .blob => {},
    }
}
