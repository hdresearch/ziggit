// Auto-generated from main_common.zig - cmd_update_index
// Agents: this file is yours to edit for the commands it contains.

const std = @import("std");
const platform_mod = @import("platform/platform.zig");
const helpers = @import("git_helpers.zig");
const cmd_add = @import("cmd_add.zig");

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

pub fn cmdUpdateIndex(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    const git_dir = helpers.findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
        unreachable;
    };
    defer allocator.free(git_dir);

    var idx = index_mod.Index.load(git_dir, platform_impl, allocator) catch blk: {
        break :blk index_mod.Index.init(allocator);
    };
    defer idx.deinit();

    var modified = false;
    var add_mode = false;
    var remove_mode = false;
    var force_remove = false;
    var refresh = false;
    var cache_info_mode = false;
    var assume_unchanged = false;
    var no_assume_unchanged = false;
    var skip_worktree = false;
    var no_skip_worktree = false;
    var stdin_mode = false;
    var ignore_missing = false;
    var unmerged_mode = false;
    var verbose = false;
    var info_only = false;
    var index_version_old: ?u32 = null;
    var index_version_new: ?u32 = null;

    var replace_mode = false;
    var again_mode = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--info-only")) {
            info_only = true;
        } else if (std.mem.eql(u8, arg, "--add")) {
            add_mode = true;
        } else if (std.mem.eql(u8, arg, "--remove")) {
            remove_mode = true;
        } else if (std.mem.eql(u8, arg, "--replace")) {
            replace_mode = true;
        } else if (std.mem.eql(u8, arg, "--force-remove")) {
            force_remove = true;
        } else if (std.mem.eql(u8, arg, "--refresh")) {
            refresh = true;
        } else if (std.mem.eql(u8, arg, "--really-refresh")) {
            refresh = true;
        } else if (std.mem.eql(u8, arg, "--ignore-missing")) {
            ignore_missing = true;
        } else if (std.mem.eql(u8, arg, "--unmerged")) {
            unmerged_mode = true;
        } else if (std.mem.eql(u8, arg, "--again") or std.mem.eql(u8, arg, "-g")) {
            again_mode = true;
        } else if (std.mem.eql(u8, arg, "--ignore-submodules")) {
            // silently accept
        } else if (std.mem.eql(u8, arg, "--cacheinfo")) {
            cache_info_mode = true;
            // Format: --cacheinfo <mode>,<sha1>,<path> or --cacheinfo <mode> <sha1> <path>
            if (args.next()) |info| {
                // helpers.Check if it's comma-separated
                if (std.mem.indexOfScalar(u8, info, ',')) |_| {
                    var parts = std.mem.splitScalar(u8, info, ',');
                    const mode_str = parts.next() orelse continue;
                    const hash_str = parts.next() orelse continue;
                    const path = parts.next() orelse continue;
                    cmd_add.addCacheInfo(&idx, mode_str, hash_str, path, allocator) catch |err| {
                        if (err == error.DirectoryFileConflict) {
                            const emsg = try std.fmt.allocPrint(allocator, "error: '{s}' appears as both a file and as a directory\n", .{path});
                            defer allocator.free(emsg);
                            try platform_impl.writeStderr(emsg);
                            std.process.exit(128);
                        }
                        if (err == error.NullSha1) {
                            if (verbose) {
                                const vmsg = try std.fmt.allocPrint(allocator, "add '{s}'\n", .{path});
                                defer allocator.free(vmsg);
                                try platform_impl.writeStdout(vmsg);
                            }
                            const emsg2 = try std.fmt.allocPrint(allocator, "error: Invalid path '{s}': Null sha1\n", .{path});
                            defer allocator.free(emsg2);
                            try platform_impl.writeStderr(emsg2);
                            std.process.exit(128);
                        }
                        return err;
                    };
                    if (verbose) {
                        const vmsg2 = try std.fmt.allocPrint(allocator, "add '{s}'\n", .{path});
                        defer allocator.free(vmsg2);
                        try platform_impl.writeStdout(vmsg2);
                    }
                    modified = true;
                } else {
                    // Three separate args: mode sha1 path
                    const mode_str = info;
                    const hash_str = args.next() orelse continue;
                    const path = args.next() orelse continue;
                    cmd_add.addCacheInfo(&idx, mode_str, hash_str, path, allocator) catch |err| {
                        if (err == error.DirectoryFileConflict) {
                            const emsg = try std.fmt.allocPrint(allocator, "error: '{s}' appears as both a file and as a directory\n", .{path});
                            defer allocator.free(emsg);
                            try platform_impl.writeStderr(emsg);
                            std.process.exit(128);
                        }
                        if (err == error.NullSha1) {
                            if (verbose) {
                                const vmsg = try std.fmt.allocPrint(allocator, "add '{s}'\n", .{path});
                                defer allocator.free(vmsg);
                                try platform_impl.writeStdout(vmsg);
                            }
                            const emsg2 = try std.fmt.allocPrint(allocator, "error: Invalid path '{s}': Null sha1\n", .{path});
                            defer allocator.free(emsg2);
                            try platform_impl.writeStderr(emsg2);
                            std.process.exit(128);
                        }
                        return err;
                    };
                    if (verbose) {
                        const vmsg = try std.fmt.allocPrint(allocator, "add '{s}'\n", .{path});
                        defer allocator.free(vmsg);
                        try platform_impl.writeStdout(vmsg);
                    }
                    modified = true;
                }
            } else {
                try platform_impl.writeStderr("error: option 'cacheinfo' expects <mode>,<sha1>,<path>\n");
                std.process.exit(1);
                unreachable;
            }
        } else if (std.mem.eql(u8, arg, "--assume-unchanged")) {
            assume_unchanged = true;
        } else if (std.mem.eql(u8, arg, "--no-assume-unchanged")) {
            no_assume_unchanged = true;
        } else if (std.mem.eql(u8, arg, "--skip-worktree")) {
            skip_worktree = true;
        } else if (std.mem.eql(u8, arg, "--no-skip-worktree")) {
            no_skip_worktree = true;
        } else if (std.mem.eql(u8, arg, "--stdin")) {
            stdin_mode = true;
        } else if (std.mem.eql(u8, arg, "--index-info")) {
            // helpers.Read index info from stdin: "<mode> <type> <sha1>\t<path>" or "<mode> <sha1> <stage>\t<path>"
            const stdin_data = helpers.readStdin(allocator, 10 * 1024 * 1024) catch {
                try platform_impl.writeStderr("fatal: unable to read from stdin\n");
                std.process.exit(128);
                unreachable;
            };
            defer allocator.free(stdin_data);
            var lines = std.mem.splitScalar(u8, stdin_data, '\n');
            while (lines.next()) |line| {
                if (line.len == 0) continue;
                // Format: "<mode> <sha1> <stage>\t<path>" or "<mode> <type> <sha1>\t<path>"
                if (std.mem.indexOfScalar(u8, line, '\t')) |tab_pos| {
                    const info_part = line[0..tab_pos];
                    const path = line[tab_pos + 1 ..];
                    if (path.len == 0) continue;
                    // helpers.Parse info part - split by spaces
                    var parts = std.mem.splitScalar(u8, info_part, ' ');
                    const mode_str = parts.next() orelse continue;
                    const second = parts.next() orelse continue;
                    // Second field could be "blob"/"tree"/"commit" (type) or a sha1 hash
                    var hash_str: []const u8 = undefined;
                    if (second.len == 40) {
                        // It's a hash directly: "<mode> <sha1> <stage>\t<path>"
                        hash_str = second;
                    } else {
                        // It's a type: "<mode> <type> <sha1>\t<path>"
                        hash_str = parts.next() orelse continue;
                    }
                    cmd_add.addCacheInfo(&idx, mode_str, hash_str, path, allocator) catch |err| {
                        if (err == error.DirectoryFileConflict) continue;
                        if (err == error.NullSha1) continue;
                        return err;
                    };
                    modified = true;
                }
            }
        } else if (std.mem.eql(u8, arg, "-q")) {
            // quiet mode
        } else if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "--chmod=+x")) {
            // Next arg should be a path
            if (args.next()) |path| {
                try setIndexEntryMode(&idx, path, 0o100755);
                if (verbose) {
                    const vmsg = try std.fmt.allocPrint(allocator, "add '{s}'\nchmod +x '{s}'\n", .{ path, path });
                    defer allocator.free(vmsg);
                    try platform_impl.writeStdout(vmsg);
                }
                modified = true;
            }
        } else if (std.mem.eql(u8, arg, "--chmod=-x")) {
            if (args.next()) |path| {
                try setIndexEntryMode(&idx, path, 0o100644);
                if (verbose) {
                    const vmsg = try std.fmt.allocPrint(allocator, "add '{s}'\nchmod -x '{s}'\n", .{ path, path });
                    defer allocator.free(vmsg);
                    try platform_impl.writeStdout(vmsg);
                }
                modified = true;
            }
        } else if (std.mem.eql(u8, arg, "--show-index-version")) {
            // Show the current index version from the index file
            const ver_msg = try std.fmt.allocPrint(allocator, "{d}\n", .{idx.version});
            defer allocator.free(ver_msg);
            try platform_impl.writeStdout(ver_msg);
            return;
        } else if (std.mem.eql(u8, arg, "--index-version")) {
            if (args.next()) |ver_str| {
                const new_ver = std.fmt.parseInt(u32, ver_str, 10) catch 2;
                index_version_old = idx.version;
                index_version_new = new_ver;
                idx.version = new_ver;
                modified = true;
            }
        } else if (std.mem.eql(u8, arg, "--")) {
            // rest are paths
            while (args.next()) |path| {
                if (force_remove) {
                    idx.remove(path) catch {};
                    modified = true;
                } else if (add_mode) {
                    if (!replace_mode and helpers.checkDFConflict(&idx, path)) {
                        const emdf = std.fmt.allocPrint(allocator, "error: '{s}' appears as both a file and as a directory\nerror: {s}: cannot add to the index - missing --replace option?\nfatal: Unable to process path {s}\n", .{ path, path, path }) catch "error: D/F conflict\n";
                        try platform_impl.writeStderr(emdf);
                        std.process.exit(128);
                    }
                    idx.add(path, path, platform_impl, git_dir) catch {};
                    modified = true;
                } else {
                    var pfound = false;
                    for (idx.entries.items) |entry| {
                        if (std.mem.eql(u8, entry.path, path)) { pfound = true; break; }
                    }
                    if (!pfound) {
                        const enf = std.fmt.allocPrint(allocator, "error: {s}: cannot add to the index - missing --add option?\nfatal: Unable to process path {s}\n", .{ path, path }) catch "error: cannot add\n";
                        try platform_impl.writeStderr(enf);
                        std.process.exit(128);
                    }
                    std.fs.cwd().access(path, .{}) catch {
                        const ene = std.fmt.allocPrint(allocator, "error: {s}: does not exist and --remove not passed\nfatal: Unable to process path {s}\n", .{ path, path }) catch "error: file missing\n";
                        try platform_impl.writeStderr(ene);
                        std.process.exit(128);
                    };
                    idx.add(path, path, platform_impl, git_dir) catch {};
                    modified = true;
                }
            }
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            // File path
            if (assume_unchanged or no_assume_unchanged or skip_worktree or no_skip_worktree) {
                // Set flags on existing entry
                for (idx.entries.items) |*entry| {
                    if (std.mem.eql(u8, entry.path, arg)) {
                        if (assume_unchanged) entry.flags |= 0x8000; // CE_VALID
                        if (no_assume_unchanged) entry.flags &= ~@as(u16, 0x8000);
                        if (skip_worktree) {
                            // Set skip-worktree in extended flags
                            entry.flags |= 0x4000; // CE_EXTENDED
                            entry.extended_flags = (entry.extended_flags orelse 0) | 0x4000; // SKIP_WORKTREE bit
                        }
                        if (no_skip_worktree) {
                            entry.flags &= ~@as(u16, 0x4000);
                            entry.extended_flags = null;
                        }
                        modified = true;
                        break;
                    }
                }
            } else if (force_remove) {
                idx.remove(arg) catch {};
                modified = true;
            } else if (remove_mode and add_mode) {
                // helpers.Both --add and --remove: add if exists, remove if not
                if (std.fs.cwd().access(arg, .{})) |_| {
                    // File exists - add it
                    idx.add(arg, arg, platform_impl, git_dir) catch {};
                    modified = true;
                } else |_| {
                    // File doesn't exist - remove from index
                    idx.remove(arg) catch {};
                    modified = true;
                }
            } else if (remove_mode) {
                // With --remove: update entry if file exists on disk, remove if not
                if (std.fs.cwd().access(arg, .{})) |_| {
                    // File exists - check if it's in the index, if so update it
                    var found_in_idx = false;
                    for (idx.entries.items) |entry| {
                        if (std.mem.eql(u8, entry.path, arg)) { found_in_idx = true; break; }
                    }
                    if (found_in_idx) {
                        idx.add(arg, arg, platform_impl, git_dir) catch {};
                        modified = true;
                    } else {
                        const err_msg3 = std.fmt.allocPrint(allocator, "error: {s}: cannot add to the index - missing --add option?\nfatal: Unable to process path {s}\n", .{ arg, arg }) catch "error: cannot add to the index\n";
                        try platform_impl.writeStderr(err_msg3);
                        std.process.exit(128);
                    }
                } else |_| {
                    // File doesn't exist - remove from index
                    idx.remove(arg) catch {};
                    modified = true;
                }
            } else if (add_mode) {
                if (replace_mode) {
                    // D/F conflict resolution:
                    // 1. helpers.If adding file "X", remove all entries "X/*" (file replaces dir)
                    const prefix_with_slash = std.fmt.allocPrint(allocator, "{s}/", .{arg}) catch arg;
                    const needs_free_pws = !std.mem.eql(u8, prefix_with_slash, arg);
                    var j: usize = 0;
                    while (j < idx.entries.items.len) {
                        if (std.mem.startsWith(u8, idx.entries.items[j].path, prefix_with_slash)) {
                            idx.entries.items[j].deinit(allocator);
                            _ = idx.entries.orderedRemove(j);
                        } else {
                            j += 1;
                        }
                    }
                    if (needs_free_pws) allocator.free(@constCast(prefix_with_slash));
                    // 2. helpers.If adding file "X/Y", remove entry "X" (dir replaces file)
                    if (std.mem.indexOfScalar(u8, arg, '/')) |slash_idx| {
                        const parent = arg[0..slash_idx];
                        for (idx.entries.items, 0..) |entry, ei| {
                            if (std.mem.eql(u8, entry.path, parent)) {
                                idx.entries.items[ei].deinit(allocator);
                                _ = idx.entries.orderedRemove(ei);
                                break;
                            }
                        }
                    }
                } else {
                    // Without --replace, check for D/F conflicts and fail
                    if (helpers.checkDFConflict(&idx, arg)) {
                        const emdf2 = std.fmt.allocPrint(allocator, "error: '{s}' appears as both a file and as a directory\nerror: {s}: cannot add to the index - missing --replace option?\nfatal: Unable to process path {s}\n", .{ arg, arg, arg }) catch "error: D/F conflict\n";
                        try platform_impl.writeStderr(emdf2);
                        std.process.exit(128);
                    }
                }
                idx.add(arg, arg, platform_impl, git_dir) catch {};
                modified = true;
            } else {
                // helpers.No --add/--remove flag: file must already be in the index
                var found_in_index = false;
                for (idx.entries.items) |entry| {
                    if (std.mem.eql(u8, entry.path, arg)) {
                        found_in_index = true;
                        break;
                    }
                }
                if (!found_in_index) {
                    const err_msg = std.fmt.allocPrint(allocator, "error: {s}: cannot add to the index - missing --add option?\nfatal: Unable to process path {s}\n", .{ arg, arg }) catch "error: cannot add to the index\n";
                    try platform_impl.writeStderr(err_msg);
                    std.process.exit(128);
                } else {
                    // File is in index — check if it still exists on disk
                    std.fs.cwd().access(arg, .{}) catch {
                        // File deleted but no --remove flag
                        const err_msg2 = std.fmt.allocPrint(allocator, "error: {s}: does not exist and --remove not passed\nfatal: Unable to process path {s}\n", .{ arg, arg }) catch "error: file does not exist\n";
                        try platform_impl.writeStderr(err_msg2);
                        std.process.exit(128);
                    };
                    // helpers.Save old mode for symlink preservation
                    var prev_mode: u32 = 0;
                    for (idx.entries.items) |entry| {
                        if (std.mem.eql(u8, entry.path, arg)) { prev_mode = entry.mode; break; }
                    }
                    // helpers.Update existing entry with current file stat
                    idx.add(arg, arg, platform_impl, git_dir) catch {};
                    // Preserve symlink mode when core.symlinks=false
                    if (prev_mode == 0o120000) {
                        const cfp2 = std.fmt.allocPrint(allocator, "{s}/config", .{git_dir}) catch null;
                        if (cfp2) |cp2| {
                            defer allocator.free(cp2);
                            if (platform_impl.fs.readFile(allocator, cp2)) |cd2| {
                                defer allocator.free(cd2);
                                if (helpers.parseConfigValue(cd2, "core.symlinks", allocator) catch null) |sv2| {
                                    defer allocator.free(sv2);
                                    if (std.mem.eql(u8, sv2, "false")) {
                                        for (idx.entries.items) |*e2| {
                                            if (std.mem.eql(u8, e2.path, arg)) { e2.mode = 0o120000; break; }
                                        }
                                    }
                                }
                            } else |_| {}
                        }
                    }
                    modified = true;
                }
            }
            // helpers.Apply verbose output for file add
            if (verbose and modified) {
                const vmsg = std.fmt.allocPrint(allocator, "add '{s}'\n", .{arg}) catch "";
                if (vmsg.len > 0) {
                    defer allocator.free(vmsg);
                    platform_impl.writeStdout(vmsg) catch {};
                }
            }
            // chmod mode handling removed - handled inline with --chmod=+x/--chmod=-x
        } else {
            // helpers.Unknown option starting with -
            if (std.mem.eql(u8, arg, "-h")) {
                try platform_impl.writeStderr("usage: git update-index [<options>] [--] [<file>...]\n");
                std.process.exit(129);
                unreachable;
            }
            const msg = try std.fmt.allocPrint(allocator, "error: unknown option '{s}'\nusage: git update-index [<options>] [--] [<file>...]\n", .{arg});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(129);
            unreachable;
        }
    }

    if (refresh) {
        // Refresh stat info for all entries by re-statting files
        const repo_root = std.fs.path.dirname(git_dir) orelse ".";
        var refresh_failed = false;
        // Check core.trustctime config
        const trust_ctime = blk: {
            if (helpers.getConfigValueByKey(git_dir, "core.trustctime", allocator)) |val| {
                defer allocator.free(val);
                if (std.mem.eql(u8, val, "false") or std.mem.eql(u8, val, "no") or std.mem.eql(u8, val, "0")) {
                    break :blk false;
                }
            }
            break :blk true;
        };
        // Get the index file mtime for racy detection
        const index_mtime_sec: u32 = blk: {
            const index_path = std.fmt.allocPrint(allocator, "{s}/index", .{git_dir}) catch break :blk 0;
            defer allocator.free(index_path);
            const index_stat = std.fs.cwd().statFile(index_path) catch break :blk 0;
            break :blk @intCast(@max(0, @divTrunc(index_stat.mtime, std.time.ns_per_s)));
        };
        for (idx.entries.items) |*entry| {
            // helpers.Skip higher-stage (unmerged) entries
            const stage = (entry.flags >> 12) & 0x3;
            if (stage != 0) {
                if (!unmerged_mode) {
                    refresh_failed = true;
                    const umsg = std.fmt.allocPrint(allocator, "{s}: needs merge\n", .{entry.path}) catch continue;
                    defer allocator.free(umsg);
                    platform_impl.writeStderr(umsg) catch {};
                }
                continue;
            }
            // helpers.Skip assume-unchanged entries
            if (entry.flags & 0x8000 != 0) continue;
            // helpers.Skip submodule entries (mode 160000)
            if (entry.mode == 0o160000) continue;

            const full_path = if (repo_root.len > 0 and !std.mem.eql(u8, repo_root, "."))
                std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, entry.path }) catch continue
            else
                allocator.dupe(u8, entry.path) catch continue;
            defer allocator.free(full_path);

            // helpers.Check if file exists (use lstatFile for symlinks to avoid following them)
            var link_buf: [4096]u8 = undefined;
            const is_symlink_entry = (entry.mode & 0o170000) == 0o120000;
            const file_exists = blk: {
                if (is_symlink_entry) {
                    // helpers.For symlink entries, check if the symlink itself exists (don't follow)
                    _ = std.fs.cwd().readLink(full_path, &link_buf) catch break :blk false;
                    break :blk true;
                } else {
                    std.fs.cwd().access(full_path, .{}) catch break :blk false;
                    break :blk true;
                }
            };
            if (!file_exists) {
                if (!ignore_missing) {
                    refresh_failed = true;
                    const mmsg = std.fmt.allocPrint(allocator, "{s}: needs update\n", .{entry.path}) catch continue;
                    defer allocator.free(mmsg);
                    platform_impl.writeStderr(mmsg) catch {};
                }
                continue;
            }

            // helpers.Check if it's a symlink
            if (std.fs.cwd().readLink(full_path, &link_buf)) |link_target| {
                entry.size = @intCast(link_target.len);
                // helpers.Use fstatat with SYMLINK_NOFOLLOW for proper symlink stat
                const full_path_z = std.posix.toPosixPath(full_path) catch continue;
                const lstat = std.posix.fstatat(std.posix.AT.FDCWD, &full_path_z, std.posix.AT.SYMLINK_NOFOLLOW) catch continue;
                const new_ctime_sec: u32 = @intCast(@max(0, lstat.ctime().sec));
                const new_ctime_nsec: u32 = @intCast(@max(0, lstat.ctime().nsec));
                const new_mtime_sec_s: u32 = @intCast(@max(0, lstat.mtime().sec));
                const new_mtime_nsec_s: u32 = @intCast(@max(0, lstat.mtime().nsec));
                const new_ino: u32 = @intCast(lstat.ino);
                const ctime_changed = trust_ctime and (entry.ctime_sec != new_ctime_sec or entry.ctime_nsec != new_ctime_nsec);
                if (ctime_changed or
                    entry.mtime_sec != new_mtime_sec_s or entry.mtime_nsec != new_mtime_nsec_s or
                    entry.ino != new_ino)
                {
                    modified = true;
                }
                entry.ctime_sec = new_ctime_sec;
                entry.ctime_nsec = new_ctime_nsec;
                entry.mtime_sec = new_mtime_sec_s;
                entry.mtime_nsec = new_mtime_nsec_s;
                entry.ino = new_ino;
            } else |_| {
                // Regular file - check if content changed
                if (std.fs.cwd().statFile(full_path)) |stat| {
                    const file_size: u32 = @intCast(@min(stat.size, std.math.maxInt(u32)));
                    const new_mtime_sec: u32 = @intCast(@max(0, @divTrunc(stat.mtime, std.time.ns_per_s)));
                    const new_mtime_nsec: u32 = @intCast(@max(0, @rem(stat.mtime, std.time.ns_per_s)));

                    if (entry.size != file_size or entry.mtime_sec != new_mtime_sec or entry.mtime_nsec != new_mtime_nsec) {
                        const content = platform_impl.fs.readFile(allocator, full_path) catch {
                            refresh_failed = true;
                            continue;
                        };
                        defer allocator.free(content);
                        const blob_obj = objects.createBlobObject(content, allocator) catch continue;
                        defer blob_obj.deinit(allocator);
                        const new_hash_str = blob_obj.hash(allocator) catch continue;
                        defer allocator.free(new_hash_str);
                        var new_hash: [20]u8 = undefined;
                        _ = std.fmt.hexToBytes(&new_hash, new_hash_str) catch continue;

                        if (!std.mem.eql(u8, &new_hash, &entry.sha1)) {
                            refresh_failed = true;
                            const nmsg = std.fmt.allocPrint(allocator, "{s}: needs update\n", .{entry.path}) catch continue;
                            defer allocator.free(nmsg);
                            platform_impl.writeStderr(nmsg) catch {};
                        }
                    }

                    const new_ctime_sec2: u32 = @intCast(@max(0, @divTrunc(stat.ctime, std.time.ns_per_s)));
                    const new_ctime_nsec2: u32 = @intCast(@max(0, @rem(stat.ctime, std.time.ns_per_s)));
                    const new_ino2: u32 = @intCast(stat.inode);
                    const ctime_changed2 = trust_ctime and (entry.ctime_sec != new_ctime_sec2 or entry.ctime_nsec != new_ctime_nsec2);
                    if (ctime_changed2 or
                        entry.mtime_sec != new_mtime_sec or entry.mtime_nsec != new_mtime_nsec or
                        entry.size != file_size or entry.ino != new_ino2)
                    {
                        modified = true;
                    }
                    entry.ctime_sec = new_ctime_sec2;
                    entry.ctime_nsec = new_ctime_nsec2;
                    entry.mtime_sec = new_mtime_sec;
                    entry.mtime_nsec = new_mtime_nsec;
                    entry.size = file_size;
                    entry.ino = new_ino2;

                    // Check for racy entry: entry mtime >= index mtime
                    // Racy entries need to be smeared (size set to 0) to force re-check
                    if (index_mtime_sec > 0 and new_mtime_sec >= index_mtime_sec) {
                        // Verify content is clean, then smear
                        const content2 = platform_impl.fs.readFile(allocator, full_path) catch continue;
                        defer allocator.free(content2);
                        const blob_obj2 = objects.createBlobObject(content2, allocator) catch continue;
                        defer blob_obj2.deinit(allocator);
                        const hash_str2 = blob_obj2.hash(allocator) catch continue;
                        defer allocator.free(hash_str2);
                        var hash2: [20]u8 = undefined;
                        _ = std.fmt.hexToBytes(&hash2, hash_str2) catch continue;
                        if (std.mem.eql(u8, &hash2, &entry.sha1)) {
                            // Content matches, smear the entry to avoid future raciness
                            entry.size = 0;
                            modified = true;
                        }
                    }
                } else |_| {}
            }
        }
        // modified is only set if stat info actually changed
        if (refresh_failed) {
            modified = true;
            idx.save(git_dir, platform_impl) catch {};
            std.process.exit(1);
        }
    }

    // helpers.Handle --again: re-stage entries that differ between index and worktree
    if (again_mode) {
        const repo_root2 = std.fs.path.dirname(git_dir) orelse ".";
        var i_ag: usize = 0;
        while (i_ag < idx.entries.items.len) {
            const entry = idx.entries.items[i_ag];
            const full_path2 = if (repo_root2.len > 0 and !std.mem.eql(u8, repo_root2, "."))
                std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root2, entry.path }) catch { i_ag += 1; continue; }
            else
                allocator.dupe(u8, entry.path) catch { i_ag += 1; continue; };
            defer allocator.free(full_path2);

            if (std.fs.cwd().access(full_path2, .{})) |_| {
                if (platform_impl.fs.readFile(allocator, full_path2)) |file_content| {
                    defer allocator.free(file_content);
                    var blob_obj = objects.createBlobObject(file_content, allocator) catch { i_ag += 1; continue; };
                    const new_hash = blob_obj.store(git_dir, platform_impl, allocator) catch { blob_obj.deinit(allocator); i_ag += 1; continue; };
                    blob_obj.deinit(allocator);
                    {
                        var new_sha1: [20]u8 = undefined;
                        _ = std.fmt.hexToBytes(&new_sha1, new_hash) catch { i_ag += 1; continue; };
                        if (!std.mem.eql(u8, &entry.sha1, &new_sha1)) {
                            idx.entries.items[i_ag].sha1 = new_sha1;
                            if (std.fs.cwd().statFile(full_path2)) |stat| {
                                idx.entries.items[i_ag].size = @intCast(@min(stat.size, std.math.maxInt(u32)));
                            } else |_| {}
                            modified = true;
                        }
                    }
                } else |_| {}
            } else |_| {
                if (remove_mode) {
                    _ = idx.entries.orderedRemove(i_ag);
                    modified = true;
                    continue;
                }
            }
            i_ag += 1;
        }
    }

    // Output index-version change message after all args processed (verbose may come after --index-version)
    if (verbose and index_version_old != null and index_version_new != null) {
        const vmsg = try std.fmt.allocPrint(allocator, "index-version: was {d}, set to {d}\n", .{ index_version_old.?, index_version_new.? });
        defer allocator.free(vmsg);
        try platform_impl.writeStdout(vmsg);
    }

    if (modified) {
        idx.save(git_dir, platform_impl) catch {
            try platform_impl.writeStderr("fatal: unable to write index file\n");
            std.process.exit(128);
        };
    }
}


pub fn setIndexEntryMode(idx: *index_mod.Index, path: []const u8, new_mode: u32) !void {
    for (idx.entries.items) |*entry| {
        if (std.mem.eql(u8, entry.path, path)) {
            entry.mode = new_mode;
            return;
        }
    }
    return error.FileNotFound;
}
