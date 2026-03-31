// Auto-generated from main_common.zig - cmd_add
// Agents: this file is yours to edit for the commands it contains.

const std = @import("std");
const platform_mod = @import("platform/platform.zig");
const helpers = @import("git_helpers.zig");
const crlf_mod = @import("crlf.zig");
const check_attr = @import("cmd_check_attr.zig");

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

pub fn cmdAdd(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    if (@import("builtin").target.os.tag == .freestanding) {
        try platform_impl.writeStderr("add: not supported in freestanding mode\n");
        return;
    }

    // helpers.Find .git directory first (before checking arguments)
    const git_path = helpers.findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);

    // helpers.Check if any files were specified
    var has_files = false;
    
    // helpers.Load index
    var index = index_mod.Index.load(git_path, platform_impl, allocator) catch |err| switch (err) {
        error.FileNotFound => index_mod.Index.init(allocator),
        else => return err,
    };
    defer index.deinit();

    // helpers.Get current working directory
    const cwd = try platform_impl.fs.getCwd(allocator);
    defer allocator.free(cwd);

    // Pre-scan for flags
    var add_all_flag = false;
    var update_flag = false;
    var force_flag = false;
    var dry_run = false;
    var intent_to_add = false;
    var refresh_flag = false;
    var chmod_mode: ?enum { plus_x, minus_x } = null;
    var collected_add_paths = std.array_list.Managed([]const u8).init(allocator);
    defer collected_add_paths.deinit();
    while (args.next()) |raw_arg| {
        if (std.mem.eql(u8, raw_arg, "--")) {
            while (args.next()) |p| try collected_add_paths.append(p);
            break;
        } else if (std.mem.eql(u8, raw_arg, "--all") or std.mem.eql(u8, raw_arg, "-A")) {
            add_all_flag = true;
        } else if (std.mem.eql(u8, raw_arg, "--update") or std.mem.eql(u8, raw_arg, "-u")) {
            update_flag = true;
        } else if (std.mem.eql(u8, raw_arg, "--force") or std.mem.eql(u8, raw_arg, "-f")) {
            force_flag = true;
        } else if (std.mem.eql(u8, raw_arg, "--dry-run") or std.mem.eql(u8, raw_arg, "-n")) {
            dry_run = true;
        } else if (std.mem.eql(u8, raw_arg, "--intent-to-add") or std.mem.eql(u8, raw_arg, "-N")) {
            intent_to_add = true;
        } else if (std.mem.eql(u8, raw_arg, "--refresh")) {
            refresh_flag = true;
        } else if (std.mem.eql(u8, raw_arg, "--chmod=+x")) {
            chmod_mode = .plus_x;
        } else if (std.mem.eql(u8, raw_arg, "--chmod=-x")) {
            chmod_mode = .minus_x;
        } else if (raw_arg.len > 0 and raw_arg[0] == '-') {
            // helpers.Skip other flags
        } else {
            try collected_add_paths.append(raw_arg);
        }
    }

    if ((add_all_flag or update_flag) and collected_add_paths.items.len == 0) {
        try collected_add_paths.append(".");
    }

    // Handle --refresh mode: update stat info for tracked files without adding new ones
    if (refresh_flag) {
        var refresh_index = index_mod.Index.load(git_path, platform_impl, allocator) catch |err| switch (err) {
            error.FileNotFound => index_mod.Index.init(allocator),
            else => return err,
        };
        defer refresh_index.deinit();
        const repo_root_refresh = if (helpers.global_git_dir_override != null or std.posix.getenv("GIT_DIR") != null)
            cwd
        else
            std.fs.path.dirname(git_path) orelse ".";
        for (refresh_index.entries.items) |*entry| {
            // If pathspecs given, only refresh matching entries
            if (collected_add_paths.items.len > 0) {
                var matches = false;
                for (collected_add_paths.items) |p| {
                    if (std.mem.eql(u8, p, ".") or std.mem.eql(u8, p, entry.path) or
                        std.mem.startsWith(u8, entry.path, p))
                    {
                        matches = true;
                        break;
                    }
                }
                if (!matches) continue;
            }
            const full_path_r = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root_refresh, entry.path });
            defer allocator.free(full_path_r);
            const stat_result = std.fs.cwd().statFile(full_path_r) catch continue;
            entry.mtime_sec = @intCast(@max(0, @divFloor(stat_result.mtime, 1_000_000_000)));
            entry.mtime_nsec = @intCast(@max(0, @mod(stat_result.mtime, 1_000_000_000)));
            entry.ctime_sec = @intCast(@max(0, @divFloor(stat_result.ctime, 1_000_000_000)));
            entry.ctime_nsec = @intCast(@max(0, @mod(stat_result.ctime, 1_000_000_000)));
            entry.size = @intCast(stat_result.size);
            entry.ino = @truncate(stat_result.inode);
            entry.dev = 0; // Not available from statFile
            entry.uid = 0;
            entry.gid = 0;
        }
        // Check if any pathspecs didn't match
        if (collected_add_paths.items.len > 0) {
            for (collected_add_paths.items) |p| {
                if (std.mem.eql(u8, p, ".")) continue;
                var found = false;
                for (refresh_index.entries.items) |entry| {
                    if (std.mem.eql(u8, entry.path, p) or
                        std.mem.startsWith(u8, entry.path, p))
                    {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    const msg = try std.fmt.allocPrint(allocator, "fatal: pathspec '{s}' did not match any files\n", .{p});
                    defer allocator.free(msg);
                    try platform_impl.writeStderr(msg);
                    std.process.exit(128);
                }
            }
        }
        try refresh_index.save(git_path, platform_impl);
        return;
    }

    // Handle dry-run mode early: just report what would change without modifying anything
    if (dry_run) {
        if (update_flag or add_all_flag) {
            const repo_root_dr = if (helpers.global_git_dir_override != null or std.posix.getenv("GIT_DIR") != null)
                try platform_impl.fs.getCwd(allocator)
            else
                try allocator.dupe(u8, std.fs.path.dirname(git_path) orelse ".");
            defer allocator.free(repo_root_dr);

            for (index.entries.items) |orig_entry| {
                const fp_dr = if (repo_root_dr.len > 0 and !std.mem.eql(u8, repo_root_dr, "."))
                    std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root_dr, orig_entry.path }) catch continue
                else
                    allocator.dupe(u8, orig_entry.path) catch continue;
                defer allocator.free(fp_dr);
                const exists_dr = blk_dr: {
                    // Use lstat (no symlink follow) to check existence
                    const fp_z = std.posix.toPosixPath(fp_dr) catch break :blk_dr false;
                    _ = std.posix.fstatat(std.posix.AT.FDCWD, &fp_z, std.posix.AT.SYMLINK_NOFOLLOW) catch break :blk_dr false;
                    break :blk_dr true;
                };
                if (exists_dr) {
                    const content_dr = platform_impl.fs.readFile(allocator, fp_dr) catch continue;
                    defer allocator.free(content_dr);
                    const blob_dr = objects.createBlobObject(content_dr, allocator) catch continue;
                    defer blob_dr.deinit(allocator);
                    const hash_dr = blob_dr.hash(allocator) catch continue;
                    defer allocator.free(hash_dr);
                    var orig_hash_hex: [40]u8 = undefined;
                    for (orig_entry.sha1, 0..) |byte, bi| {
                        orig_hash_hex[bi * 2] = "0123456789abcdef"[byte >> 4];
                        orig_hash_hex[bi * 2 + 1] = "0123456789abcdef"[byte & 0xf];
                    }
                    if (!std.mem.eql(u8, hash_dr, &orig_hash_hex)) {
                        const msg_dr = try std.fmt.allocPrint(allocator, "add '{s}'\n", .{orig_entry.path});
                        defer allocator.free(msg_dr);
                        try platform_impl.writeStdout(msg_dr);
                    }
                } else {
                    const msg_dr = try std.fmt.allocPrint(allocator, "remove '{s}'\n", .{orig_entry.path});
                    defer allocator.free(msg_dr);
                    try platform_impl.writeStdout(msg_dr);
                }
            }
        } else {
            // Dry-run for specific file paths
            const repo_root_dr2 = if (helpers.global_git_dir_override != null or std.posix.getenv("GIT_DIR") != null)
                try platform_impl.fs.getCwd(allocator)
            else
                try allocator.dupe(u8, std.fs.path.dirname(git_path) orelse ".");
            defer allocator.free(repo_root_dr2);

            for (collected_add_paths.items) |file_path| {
                // Compute repo-relative path
                const cwd_dr = try platform_impl.fs.getCwd(allocator);
                defer allocator.free(cwd_dr);
                const abs_path = if (std.fs.path.isAbsolute(file_path))
                    try allocator.dupe(u8, file_path)
                else
                    try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cwd_dr, file_path });
                defer allocator.free(abs_path);

                const rel_path = if (repo_root_dr2.len > 0 and !std.mem.eql(u8, repo_root_dr2, ".") and std.mem.startsWith(u8, abs_path, repo_root_dr2))
                    abs_path[repo_root_dr2.len + 1 ..]
                else
                    file_path;

                // Check gitignore for dry-run
                if (!force_flag) {
                    const gitignore_path_dr = try std.fmt.allocPrint(allocator, "{s}/.gitignore", .{repo_root_dr2});
                    defer allocator.free(gitignore_path_dr);
                    var gitignore_dr = gitignore_mod.GitIgnore.loadFromFile(allocator, gitignore_path_dr, platform_impl) catch |err_gi| switch (err_gi) {
                        error.OutOfMemory => return err_gi,
                        else => gitignore_mod.GitIgnore.init(allocator),
                    };
                    defer gitignore_dr.deinit();
                    if (gitignore_dr.isIgnored(rel_path)) {
                        const err_msg_dr = try std.fmt.allocPrint(allocator, "fatal: pathspec '{s}' did not match any files\n", .{file_path});
                        defer allocator.free(err_msg_dr);
                        try platform_impl.writeStderr(err_msg_dr);
                        std.process.exit(128);
                    }
                }
                const msg_dr = try std.fmt.allocPrint(allocator, "add '{s}'\n", .{rel_path});
                defer allocator.free(msg_dr);
                try platform_impl.writeStdout(msg_dr);
            }
        }
        return;
    }

    // helpers.Process all file arguments
    var has_directory_add = false;
    var had_ignored_file = false;
    for (collected_add_paths.items) |file_path| {
        has_files = true;

        // Reject empty string pathspec
        if (file_path.len == 0) {
            try platform_impl.writeStderr("fatal: invalid pathspec '' given\n");
            std.process.exit(128);
        }
        
        // helpers.Handle special cases like "." for current directory
        if (std.mem.eql(u8, file_path, ".") and update_flag and !add_all_flag) {
            // helpers.For -u flag: only update files already tracked in the index
            const repo_root_upd = std.fs.path.dirname(git_path) orelse ".";
            for (index.entries.items) |*entry| {
                const fp = if (repo_root_upd.len > 0 and !std.mem.eql(u8, repo_root_upd, "."))
                    std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root_upd, entry.path }) catch continue
                else
                    allocator.dupe(u8, entry.path) catch continue;
                defer allocator.free(fp);
                // helpers.Check if file exists and re-add it to update the hash
                // Check for symlinks first
                var link_buf_upd: [4096]u8 = undefined;
                const is_symlink = if (std.fs.cwd().readLink(fp, &link_buf_upd)) |_| true else |_| false;
                const file_exists_upd = if (is_symlink) true else if (platform_impl.fs.exists(fp) catch false) true else false;
                if (file_exists_upd) {
                    const content = if (is_symlink) blk: {
                        const target = std.fs.cwd().readLink(fp, &link_buf_upd) catch continue;
                        break :blk allocator.dupe(u8, target) catch continue;
                    } else platform_impl.fs.readFile(allocator, fp) catch continue;
                    defer allocator.free(content);
                    const blob = objects.createBlobObject(content, allocator) catch continue;
                    defer blob.deinit(allocator);
                    const hash_str = blob.store(git_path, platform_impl, allocator) catch continue;
                    defer allocator.free(hash_str);
                    // helpers.Update index entry helpers.SHA1
                    var new_sha1: [20]u8 = undefined;
                    var hi: usize = 0;
                    while (hi < 20) : (hi += 1) {
                        new_sha1[hi] = std.fmt.parseInt(u8, hash_str[hi * 2 .. hi * 2 + 2], 16) catch 0;
                    }
                    entry.sha1 = new_sha1;
                    // Update mode for symlinks
                    if (is_symlink) {
                        entry.mode = 0o120000;
                    }
                    // helpers.Update stat info - use lstat for symlinks
                    const stat_result = std.fs.cwd().statFile(fp) catch continue;
                    entry.mtime_sec = @intCast(@divFloor(stat_result.mtime, 1_000_000_000));
                    entry.mtime_nsec = @intCast(@mod(stat_result.mtime, 1_000_000_000));
                    entry.ctime_sec = @intCast(@divFloor(stat_result.ctime, 1_000_000_000));
                    entry.ctime_nsec = @intCast(@mod(stat_result.ctime, 1_000_000_000));
                    entry.size = @intCast(stat_result.size);
                }
            }
        } else if (std.mem.eql(u8, file_path, ".")) {
            // helpers.Add all files in current directory (recursively)
            try addDirectoryRecursively(allocator, cwd, "", &index, git_path, platform_impl);
            has_directory_add = true;
        } else {
            // helpers.Resolve file path 
            const full_file_path = if (std.fs.path.isAbsolute(file_path))
                try allocator.dupe(u8, file_path)
            else
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cwd, file_path });
            defer allocator.free(full_file_path);
            
            // helpers.Convert to path relative to repo root
            // When --git-dir is used, the working tree is CWD, not dirname(git_path)
            const repo_root_for_rel = if (helpers.global_git_dir_override != null or std.posix.getenv("GIT_DIR") != null)
                cwd
            else
                std.fs.path.dirname(git_path) orelse ".";
            const real_full = std.fs.cwd().realpathAlloc(allocator, full_file_path) catch try allocator.dupe(u8, full_file_path);
            defer allocator.free(real_full);
            const real_root = std.fs.cwd().realpathAlloc(allocator, repo_root_for_rel) catch try allocator.dupe(u8, repo_root_for_rel);
            defer allocator.free(real_root);
            // helpers.Compute relative path from repo root
            const relative_file_path = if (std.mem.startsWith(u8, real_full, real_root) and real_full.len > real_root.len and real_full[real_root.len] == '/')
                real_full[real_root.len + 1 ..]
            else
                file_path;

            // helpers.Check if path exists (including broken symlinks)
            const path_exists = blk: {
                if (platform_impl.fs.exists(full_file_path) catch false) break :blk true;
                var link_buf: [4096]u8 = undefined;
                _ = std.fs.cwd().readLink(full_file_path, &link_buf) catch break :blk false;
                break :blk true;
            };
            if (!path_exists) {
                const msg = try std.fmt.allocPrint(allocator, "fatal: pathspec '{s}' did not match any files\n", .{file_path});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(128);
            }

            // helpers.Check if it's a directory or file
            // For "." or paths ending in "/.", use the directory path
            const is_dot_path = std.mem.eql(u8, file_path, ".") or std.mem.endsWith(u8, file_path, "/.");
            const metadata = if (is_dot_path)
                std.fs.File.Stat{ .inode = 0, .size = 0, .mode = @as(@TypeOf(@as(std.fs.File.Stat, undefined).mode), 0o40755), .kind = .directory, .atime = 0, .mtime = 0, .ctime = 0 }
            else
                std.fs.cwd().statFile(full_file_path) catch {
                    // helpers.If we can't stat it (e.g. broken symlink), try to add it
                    addSingleFileEx(allocator, relative_file_path, full_file_path, &index, git_path, platform_impl, repo_root_for_rel, force_flag, true) catch |e| {
                        if (e == error.IgnoredFile) { had_ignored_file = true; continue; }
                        return e;
                    };
                    continue;
                };

            if (metadata.kind == .directory) {
                // Check if this is a submodule (has .git inside), but not for "." (the repo itself)
                const is_submodule = if (is_dot_path) false else blk_sub: {
                    const sub_git_path = try std.fmt.allocPrint(allocator, "{s}/.git", .{full_file_path});
                    defer allocator.free(sub_git_path);
                    std.fs.cwd().access(sub_git_path, .{}) catch break :blk_sub false;
                    break :blk_sub true;
                };
                if (is_submodule) {
                    // Add as gitlink (mode 160000) - read HEAD from submodule
                    const sub_gp = try std.fmt.allocPrint(allocator, "{s}/.git", .{full_file_path});
                    defer allocator.free(sub_gp);
                    try addSubmoduleEntry(allocator, relative_file_path, sub_gp, &index, git_path, platform_impl);
                } else if (update_flag) {
                    // -u with directory: only update tracked files under this directory
                    const upd_repo_root = std.fs.path.dirname(git_path) orelse ".";
                    for (index.entries.items) |*entry| {
                        // Check if entry is under the specified directory
                        if (!std.mem.startsWith(u8, entry.path, relative_file_path) or
                            (entry.path.len > relative_file_path.len and entry.path[relative_file_path.len] != '/'))
                            continue;
                        const fp2 = if (upd_repo_root.len > 0 and !std.mem.eql(u8, upd_repo_root, "."))
                            std.fmt.allocPrint(allocator, "{s}/{s}", .{ upd_repo_root, entry.path }) catch continue
                        else
                            allocator.dupe(u8, entry.path) catch continue;
                        defer allocator.free(fp2);
                        if (platform_impl.fs.exists(fp2) catch false) {
                            const content = platform_impl.fs.readFile(allocator, fp2) catch continue;
                            defer allocator.free(content);
                            const blob = objects.createBlobObject(content, allocator) catch continue;
                            defer blob.deinit(allocator);
                            const hash_str = blob.store(git_path, platform_impl, allocator) catch continue;
                            defer allocator.free(hash_str);
                            var new_sha1: [20]u8 = undefined;
                            var hi: usize = 0;
                            while (hi < 20) : (hi += 1) {
                                new_sha1[hi] = std.fmt.parseInt(u8, hash_str[hi * 2 .. hi * 2 + 2], 16) catch 0;
                            }
                            entry.sha1 = new_sha1;
                            const stat = std.fs.cwd().statFile(fp2) catch continue;
                            entry.mtime_sec = @intCast(@divFloor(stat.mtime, 1_000_000_000));
                            entry.mtime_nsec = @intCast(@mod(stat.mtime, 1_000_000_000));
                            entry.ctime_sec = @intCast(@divFloor(stat.ctime, 1_000_000_000));
                            entry.ctime_nsec = @intCast(@mod(stat.ctime, 1_000_000_000));
                            entry.size = @intCast(stat.size);
                        }
                    }
                    has_directory_add = true;
                } else {
                    // Check if directory itself is ignored before recursing
                    if (!force_flag and !is_dot_path) {
                        const gi_path = try std.fmt.allocPrint(allocator, "{s}/.gitignore", .{repo_root_for_rel});
                        defer allocator.free(gi_path);
                        var gi = gitignore_mod.GitIgnore.loadFromFile(allocator, gi_path, platform_impl) catch |err| switch (err) {
                            error.OutOfMemory => return err,
                            else => gitignore_mod.GitIgnore.init(allocator),
                        };
                        defer gi.deinit();
                        if (gi.isIgnored(relative_file_path) or isParentDirIgnored(&gi, relative_file_path)) {
                            const msg = try std.fmt.allocPrint(allocator, "The following paths are ignored by one of your .gitignore files:\n{s}\nhint: Use -f if you really want to add them.\nhint: Turn this message off by running\nhint: \"git config advice.addIgnoredFile false\"\n", .{relative_file_path});
                            defer allocator.free(msg);
                            try platform_impl.writeStderr(msg);
                            had_ignored_file = true;
                            continue;
                        }
                    }
                    // helpers.Add directory recursively
                    try addDirectoryRecursivelyEx(allocator, repo_root_for_rel, relative_file_path, &index, git_path, platform_impl, force_flag);
                    has_directory_add = true;
                }
            } else {
                // helpers.Add single file
                if (intent_to_add) {
                    try addIntentToAddEntry(allocator, relative_file_path, full_file_path, &index, git_path, platform_impl);
                } else {
                    addSingleFileEx(allocator, relative_file_path, full_file_path, &index, git_path, platform_impl, repo_root_for_rel, force_flag, true) catch |e| {
                        if (e == error.IgnoredFile) { had_ignored_file = true; continue; }
                        return e;
                    };
                }
            }
        }
    }

    if (!has_files) {
        try platform_impl.writeStderr("Nothing specified, nothing added.\n");
        try platform_impl.writeStderr("hint: helpers.Maybe you wanted to say 'git add .'?\n");
        try platform_impl.writeStderr("hint: Disable this message with \"git config set advice.addEmptyPathspec false\"\n");
        return;
    }

    // Remove index entries for deleted files (git add . also removes deleted files)
    if (add_all_flag or update_flag or has_directory_add) {
        const repo_root = if (helpers.global_git_dir_override != null or std.posix.getenv("GIT_DIR") != null)
            try platform_impl.fs.getCwd(allocator)
        else
            try allocator.dupe(u8, std.fs.path.dirname(git_path) orelse ".");
        defer allocator.free(repo_root);
        var i: usize = 0;
        while (i < index.entries.items.len) {
            const entry = index.entries.items[i];
            const fp = if (repo_root.len > 0 and !std.mem.eql(u8, repo_root, "."))
                std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, entry.path }) catch { i += 1; continue; }
            else
                allocator.dupe(u8, entry.path) catch { i += 1; continue; };
            defer allocator.free(fp);
            const exists = blk2: {
                std.fs.cwd().access(fp, .{}) catch break :blk2 false;
                break :blk2 true;
            };
            if (!exists) {
                index.entries.items[i].deinit(allocator);
                _ = index.entries.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    // Apply --chmod if specified
    if (chmod_mode) |cm| {
        const target_mode: u32 = if (cm == .plus_x) 0o100755 else 0o100644;
        for (index.entries.items) |*entry| {
            // Only change regular files, not symlinks or submodules
            if (entry.mode == 0o100644 or entry.mode == 0o100755) {
                // If specific paths given, only change those
                if (collected_add_paths.items.len > 0) {
                    for (collected_add_paths.items) |p| {
                        const check_p = if (std.mem.eql(u8, p, ".")) "" else p;
                        if (check_p.len == 0 or std.mem.eql(u8, entry.path, check_p) or
                            std.mem.startsWith(u8, entry.path, check_p))
                        {
                            entry.mode = target_mode;
                            break;
                        }
                    }
                } else {
                    entry.mode = target_mode;
                }
            }
        }
    }

    // helpers.Save index
    try index.save(git_path, platform_impl);

    // If any files were ignored, exit with error after saving index
    if (had_ignored_file) {
        std.process.exit(1);
    }
}


fn addIntentToAddEntry(allocator: std.mem.Allocator, relative_path: []const u8, full_path: []const u8, index: *index_mod.Index, git_path: []const u8, platform_impl: *const platform_mod.Platform) !void {
    _ = git_path;
    _ = platform_impl;
    // For intent-to-add (-N), add index entry with null hash and intent-to-add extended flag
    // First remove any existing entry for this path
    var i: usize = 0;
    while (i < index.entries.items.len) {
        if (std.mem.eql(u8, index.entries.items[i].path, relative_path)) {
            index.entries.items[i].deinit(allocator);
            _ = index.entries.orderedRemove(i);
        } else {
            i += 1;
        }
    }

    // Get file stat
    const stat = std.fs.cwd().statFile(full_path) catch return error.FileNotFound;

    const path_copy = try allocator.dupe(u8, relative_path);
    const path_len: u16 = if (relative_path.len >= 0xFFF) 0xFFF else @intCast(relative_path.len);

    const entry = index_mod.IndexEntry{
        .ctime_sec = @intCast(@divFloor(stat.ctime, 1_000_000_000)),
        .ctime_nsec = @intCast(@mod(stat.ctime, 1_000_000_000)),
        .mtime_sec = @intCast(@divFloor(stat.mtime, 1_000_000_000)),
        .mtime_nsec = @intCast(@mod(stat.mtime, 1_000_000_000)),
        .dev = 0,
        .ino = 0,
        .mode = 0o100644,
        .uid = 0,
        .gid = 0,
        .size = 0,
        .sha1 = [_]u8{0} ** 20, // Null hash for intent-to-add
        .flags = path_len | 0x4000, // CE_EXTENDED bit set
        .extended_flags = 0x2000, // Intent-to-add flag
        .path = path_copy,
    };

    try index.entries.append(entry);
    std.sort.block(index_mod.IndexEntry, index.entries.items, {}, struct {
        fn lessThan(context: void, lhs: index_mod.IndexEntry, rhs: index_mod.IndexEntry) bool {
            _ = context;
            return std.mem.lessThan(u8, lhs.path, rhs.path);
        }
    }.lessThan);
}

pub fn addSingleFile(allocator: std.mem.Allocator, relative_path: []const u8, full_path: []const u8, index: *index_mod.Index, git_path: []const u8, platform_impl: *const platform_mod.Platform, repo_root: []const u8) !void {
    return addSingleFileEx(allocator, relative_path, full_path, index, git_path, platform_impl, repo_root, false, false);
}

pub fn addSingleFileEx(allocator: std.mem.Allocator, relative_path: []const u8, full_path: []const u8, index: *index_mod.Index, git_path: []const u8, platform_impl: *const platform_mod.Platform, repo_root: []const u8, force: bool, explicit: bool) !void {
    // helpers.Check if file is ignored
    if (!force) {
        const gitignore_path = try std.fmt.allocPrint(allocator, "{s}/.gitignore", .{repo_root});
        defer allocator.free(gitignore_path);
        
        var gitignore = gitignore_mod.GitIgnore.loadFromFile(allocator, gitignore_path, platform_impl) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => gitignore_mod.GitIgnore.init(allocator),
        };
        defer gitignore.deinit();
        
        if (gitignore.isIgnored(relative_path) or isParentDirIgnored(&gitignore, relative_path)) {
            if (explicit) {
                // Error out when explicitly adding ignored files
                const msg = try std.fmt.allocPrint(allocator, "The following paths are ignored by one of your .gitignore files:\n{s}\nhint: Use -f if you really want to add them.\nhint: Turn this message off by running\nhint: \"git config advice.addIgnoredFile false\"\n", .{relative_path});
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                return error.IgnoredFile;
            }
            return;
        }
    }

    // Emit CRLF conversion warnings before adding
    // For files already in the index, use stricter warning criteria (git's safe behavior)
    const is_new_file = !fileExistsInIndex(index, relative_path);
    emitCrlfWarning(allocator, relative_path, full_path, git_path, platform_impl, is_new_file) catch {};

    // Apply CRLF→LF normalization for text files
    const filtered = applyCrlfNormalization(allocator, relative_path, full_path, git_path, platform_impl);
    defer if (filtered) |f| allocator.free(f);

    // helpers.Add to index
    index.addFiltered(relative_path, full_path, platform_impl, git_path, filtered) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            const msg = try std.fmt.allocPrint(allocator, "error: failed to add '{s}' to index\n", .{relative_path});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            return err;
        },
    };
}

fn fileExistsInIndex(index: *index_mod.Index, path: []const u8) bool {
    for (index.entries.items) |entry| {
        if (std.mem.eql(u8, entry.path, path)) return true;
    }
    return false;
}

/// Emit CRLF/LF conversion warnings to stderr, matching git's behavior.
fn emitCrlfWarning(allocator: std.mem.Allocator, relative_path: []const u8, full_path: []const u8, git_path: []const u8, platform_impl: *const platform_mod.Platform, is_new_file: bool) !void {
    const content = platform_impl.fs.readFile(allocator, full_path) catch return;
    defer allocator.free(content);

    if (content.len == 0) return;

    // Get config values
    const autocrlf_val = helpers.getConfigValueByKey(git_path, "core.autocrlf", allocator);
    defer if (autocrlf_val) |v| allocator.free(v);
    const eol_config_val = helpers.getConfigValueByKey(git_path, "core.eol", allocator);
    defer if (eol_config_val) |v| allocator.free(v);

    // Load .gitattributes rules
    const repo_root = std.fs.path.dirname(git_path) orelse ".";
    var attr_rules = crlf_mod.loadAttrRules(allocator, repo_root, git_path, platform_impl) catch return;
    defer {
        for (attr_rules.items) |*rule| rule.deinit(allocator);
        attr_rules.deinit();
    }

    const attrs = crlf_mod.getFileAttrs(relative_path, attr_rules.items);

    // Git's warning logic:
    // 1. With explicit text/text=auto attribute: warn about CRLF->LF when file has CRLF and checkout won't restore it
    // 2. With autocrlf=true (no text attr): warn about LF->CRLF for files with bare LF
    // 3. With autocrlf=input (no text attr): NO warning (silent normalization)

    const is_text = crlf_mod.isTextContent(content);

    switch (attrs.text) {
        .text => {
            // Explicit text attribute
            if (hasCrlf(content)) {
                // CRLF content will be normalized to LF on add.
                // Check if checkout would restore CRLF.
                const normalized = crlf_mod.convertCrlfToLf(allocator, content) catch return;
                defer allocator.free(normalized);
                const co_action = crlf_mod.getCheckoutAction(.text, attrs.eol, autocrlf_val, eol_config_val, normalized);
                if (co_action != .lf_to_crlf) {
                    const msg = try std.fmt.allocPrint(allocator, "warning: in the working copy of '{s}', CRLF will be replaced by LF the next time Git touches it\n", .{relative_path});
                    defer allocator.free(msg);
                    platform_impl.writeStderr(msg) catch {};
                    return;
                }
            }
            if (hasBareLf(content)) {
                const co_action = crlf_mod.getCheckoutAction(.text, attrs.eol, autocrlf_val, eol_config_val, content);
                if (co_action == .lf_to_crlf) {
                    const msg = try std.fmt.allocPrint(allocator, "warning: in the working copy of '{s}', LF will be replaced by CRLF the next time Git touches it\n", .{relative_path});
                    defer allocator.free(msg);
                    platform_impl.writeStderr(msg) catch {};
                }
            }
        },
        .text_auto => {
            if (!is_text) return;
            // For existing files with text=auto, suppress most warnings (safe behavior)
            if (!is_new_file) return;
            // Normalize content to check checkout behavior
            const normalized = crlf_mod.convertCrlfToLf(allocator, content) catch return;
            defer allocator.free(normalized);
            const co_action = crlf_mod.getCheckoutAction(.text_auto, attrs.eol, autocrlf_val, eol_config_val, normalized);
            if (hasCrlf(content) and co_action != .lf_to_crlf) {
                // CRLF->LF on add, checkout won't restore CRLF
                const msg = try std.fmt.allocPrint(allocator, "warning: in the working copy of '{s}', CRLF will be replaced by LF the next time Git touches it\n", .{relative_path});
                defer allocator.free(msg);
                platform_impl.writeStderr(msg) catch {};
            } else if (hasBareLf(content) and co_action == .lf_to_crlf) {
                // LF->CRLF on checkout
                const msg = try std.fmt.allocPrint(allocator, "warning: in the working copy of '{s}', LF will be replaced by CRLF the next time Git touches it\n", .{relative_path});
                defer allocator.free(msg);
                platform_impl.writeStderr(msg) catch {};
            }
        },
        .no_text => {},
        .unspecified => {
            // No text attribute
            // For existing files, git uses "safe" behavior and suppresses warnings
            if (!is_new_file) return;
            // Don't warn for files with lone CR (inconsistent endings)
            if (autocrlf_val) |ac| {
                if (std.mem.eql(u8, ac, "true") and is_text and !hasLoneCr(content)) {
                    // autocrlf=true: warn about LF->CRLF for files with bare LF
                    if (hasBareLf(content) and !hasCrlf(content)) {
                        const msg = try std.fmt.allocPrint(allocator, "warning: in the working copy of '{s}', LF will be replaced by CRLF the next time Git touches it\n", .{relative_path});
                        defer allocator.free(msg);
                        platform_impl.writeStderr(msg) catch {};
                    }
                } else if (std.mem.eql(u8, ac, "input") and is_text and !hasLoneCr(content)) {
                    // autocrlf=input: warn about CRLF->LF for files with CRLF
                    if (hasCrlf(content)) {
                        const msg = try std.fmt.allocPrint(allocator, "warning: in the working copy of '{s}', CRLF will be replaced by LF the next time Git touches it\n", .{relative_path});
                        defer allocator.free(msg);
                        platform_impl.writeStderr(msg) catch {};
                    }
                }
            }
        },
    }
}

/// Apply CRLF→LF normalization based on attributes and config.
/// Returns normalized content if conversion needed, null otherwise.
fn applyCrlfNormalization(allocator: std.mem.Allocator, relative_path: []const u8, full_path: []const u8, git_path: []const u8, platform_impl: *const platform_mod.Platform) ?[]u8 {
    const content = platform_impl.fs.readFile(allocator, full_path) catch return null;
    defer allocator.free(content);

    if (content.len == 0) return null;

    const autocrlf_val = helpers.getConfigValueByKey(git_path, "core.autocrlf", allocator);
    defer if (autocrlf_val) |v| allocator.free(v);

    const repo_root = std.fs.path.dirname(git_path) orelse ".";
    var attr_rules = crlf_mod.loadAttrRules(allocator, repo_root, git_path, platform_impl) catch return null;
    defer {
        for (attr_rules.items) |*rule| rule.deinit(allocator);
        attr_rules.deinit();
    }

    // Check if we should normalize based on attributes
    const attrs = crlf_mod.getFileAttrs(relative_path, attr_rules.items);

    // Only normalize when text attribute is explicitly set as "text" (not auto)
    // With unspecified/auto attr and autocrlf, git uses "safe" behavior:
    // it doesn't normalize if the file already exists in the index with CRLF
    if (attrs.text != .text) return null;

    const converted = crlf_mod.applyCommitConversion(allocator, content, relative_path, attr_rules.items, autocrlf_val) catch return null;
    return converted;
}

fn hasCrlf(content: []const u8) bool {
    var i: usize = 0;
    while (i < content.len - 1) : (i += 1) {
        if (content[i] == '\r' and content[i + 1] == '\n') return true;
    }
    return false;
}

fn hasBareLf(content: []const u8) bool {
    for (content, 0..) |c, i| {
        if (c == '\n' and (i == 0 or content[i - 1] != '\r')) return true;
    }
    return false;
}

/// Check if content has lone CR (CR not followed by LF).
fn hasLoneCr(content: []const u8) bool {
    for (content, 0..) |c, i| {
        if (c == '\r' and (i + 1 >= content.len or content[i + 1] != '\n')) return true;
    }
    return false;
}


fn addSubmoduleEntry(allocator: std.mem.Allocator, relative_path: []const u8, sub_git_path: []const u8, index: *index_mod.Index, git_path: []const u8, platform_impl: *const platform_mod.Platform) !void {
    _ = platform_impl;
    _ = git_path;
    // Read the submodule's HEAD to get the commit hash
    // sub_git_path is like "path/to/submodule/.git"
    // The .git could be a file (pointing to gitdir) or a directory
    // First, check if .git is a file (gitdir reference) or directory
    
    // Try reading .git/HEAD directly (if .git is a directory)
    const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{sub_git_path});
    defer allocator.free(head_path);
    const head_content = std.fs.cwd().readFileAlloc(allocator, head_path, 4096) catch blk_head: {
        // Maybe .git is a file containing "gitdir: ..."
        const git_file_content = std.fs.cwd().readFileAlloc(allocator, sub_git_path, 4096) catch return error.FileNotFound;
        defer allocator.free(git_file_content);
        const trimmed = std.mem.trim(u8, git_file_content, " \t\r\n");
        if (std.mem.startsWith(u8, trimmed, "gitdir: ")) {
            const gitdir = trimmed["gitdir: ".len..];
            const actual_head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{gitdir});
            defer allocator.free(actual_head_path);
            break :blk_head try std.fs.cwd().readFileAlloc(allocator, actual_head_path, 4096);
        } else {
            return error.FileNotFound;
        }
    };
    defer allocator.free(head_content);
    
    const trimmed_head = std.mem.trim(u8, head_content, " \t\r\n");
    
    // Resolve if it's a symbolic ref
    var ref_content_alloc: ?[]u8 = null;
    defer if (ref_content_alloc) |r| allocator.free(r);
    const commit_hash: []const u8 = if (std.mem.startsWith(u8, trimmed_head, "ref: ")) blk_ref: {
        const ref_name = trimmed_head["ref: ".len..];
        const ref_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{sub_git_path, ref_name});
        defer allocator.free(ref_path);
        ref_content_alloc = std.fs.cwd().readFileAlloc(allocator, ref_path, 4096) catch return error.FileNotFound;
        break :blk_ref std.mem.trim(u8, ref_content_alloc.?, " \t\r\n");
    } else trimmed_head;
    
    if (commit_hash.len != 40) return error.InvalidHash;
    
    var hash_bytes: [20]u8 = undefined;
    _ = std.fmt.hexToBytes(&hash_bytes, commit_hash) catch return error.InvalidHash;
    
    // Create index entry with mode 160000 (gitlink)
    const path_dupe = try allocator.dupe(u8, relative_path);
    const fake_stat = std.fs.File.Stat{
        .inode = 0,
        .size = 0,
        .mode = @as(@TypeOf(@as(std.fs.File.Stat, undefined).mode), 0o160000),
        .kind = .file,
        .atime = 0,
        .mtime = 0,
        .ctime = 0,
    };
    const entry = index_mod.IndexEntry.init(path_dupe, fake_stat, hash_bytes);
    
    // Check if entry already exists
    for (index.entries.items, 0..) |*existing, i| {
        if (std.mem.eql(u8, existing.path, relative_path)) {
            existing.deinit(allocator);
            index.entries.items[i] = entry;
            return;
        }
    }
    
    try index.entries.append(entry);
    std.sort.block(index_mod.IndexEntry, index.entries.items, {}, struct {
        fn lessThan(context: void, lhs: index_mod.IndexEntry, rhs: index_mod.IndexEntry) bool {
            _ = context;
            return std.mem.lessThan(u8, lhs.path, rhs.path);
        }
    }.lessThan);
}

pub fn addDirectoryRecursively(allocator: std.mem.Allocator, repo_root: []const u8, relative_dir: []const u8, index: *index_mod.Index, git_path: []const u8, platform_impl: *const platform_mod.Platform) !void {
    return addDirectoryRecursivelyEx(allocator, repo_root, relative_dir, index, git_path, platform_impl, false);
}

pub fn addDirectoryRecursivelyEx(allocator: std.mem.Allocator, repo_root: []const u8, relative_dir: []const u8, index: *index_mod.Index, git_path: []const u8, platform_impl: *const platform_mod.Platform, force: bool) !void {
    const full_dir_path = if (relative_dir.len == 0)
        try allocator.dupe(u8, repo_root)
    else
        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, relative_dir });
    defer allocator.free(full_dir_path);

    // Load gitignore for directory-level filtering
    const gitignore_path = try std.fmt.allocPrint(allocator, "{s}/.gitignore", .{repo_root});
    defer allocator.free(gitignore_path);
    var gitignore = gitignore_mod.GitIgnore.loadFromFile(allocator, gitignore_path, platform_impl) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => gitignore_mod.GitIgnore.init(allocator),
    };
    defer gitignore.deinit();

    // helpers.Try to open directory
    var dir = std.fs.cwd().openDir(full_dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.NotDir, error.AccessDenied, error.FileNotFound => return,
        else => return err,
    };
    defer dir.close();

    var iterator = dir.iterate();
    while (iterator.next() catch null) |entry| {
        // helpers.Skip .git directory
        if (std.mem.eql(u8, entry.name, ".git")) continue;
        
        const entry_relative_path = if (relative_dir.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ relative_dir, entry.name });
        defer allocator.free(entry_relative_path);

        // Check gitignore for this entry (applies to both files and directories)
        if (!force) {
            const gi_ptr: *const gitignore_mod.GitIgnore = &gitignore;
            if (gitignore.isIgnored(entry_relative_path) or isParentDirIgnored(gi_ptr, entry_relative_path)) continue;
        }
        
        const entry_full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ full_dir_path, entry.name });
        defer allocator.free(entry_full_path);
        
        switch (entry.kind) {
            .file => {
                addSingleFileEx(allocator, entry_relative_path, entry_full_path, index, git_path, platform_impl, repo_root, force, false) catch continue;
            },
            .sym_link => {
                // helpers.Add symlink - index.add handles symlinks natively
                const repo_root_dir = std.fs.path.dirname(git_path) orelse ".";
                const rel_to_repo = if (std.mem.startsWith(u8, entry_full_path, repo_root_dir))
                    entry_full_path[repo_root_dir.len + 1 ..]
                else
                    entry_relative_path;
                index.add(rel_to_repo, rel_to_repo, platform_impl, git_path) catch continue;
            },
            .directory => {
                // helpers.Recursively add subdirectory
                addDirectoryRecursivelyEx(allocator, repo_root, entry_relative_path, index, git_path, platform_impl, force) catch continue;
            },
            else => continue, // helpers.Skip other types
        }
    }
}


pub fn stageTrackedChanges(allocator: std.mem.Allocator, index: *index_mod.Index, git_path: []const u8, repo_root: []const u8, platform_impl: *const platform_mod.Platform) !void {
    // helpers.Collect paths to remove (deleted files) and paths to re-add (modified files).
    // helpers.We collect first to avoid mutating the list while iterating.
    var to_remove = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (to_remove.items) |p| allocator.free(p);
        to_remove.deinit();
    }
    var to_readd = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (to_readd.items) |p| allocator.free(p);
        to_readd.deinit();
    }

    for (index.entries.items) |entry| {
        const full_path = if (repo_root.len > 0 and !std.mem.eql(u8, repo_root, "."))
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, entry.path })
        else
            try allocator.dupe(u8, entry.path);
        defer allocator.free(full_path);

        // helpers.Check if file still exists
        const file_exists = if (std.fs.path.isAbsolute(full_path))
            blk: {
                std.fs.accessAbsolute(full_path, .{}) catch break :blk false;
                break :blk true;
            }
        else
            blk: {
                std.fs.cwd().access(full_path, .{}) catch break :blk false;
                break :blk true;
            };

        if (!file_exists) {
            try to_remove.append(try allocator.dupe(u8, entry.path));
            continue;
        }

        // helpers.Read file content and hash it to see if it changed
        const content = platform_impl.fs.readFile(allocator, full_path) catch continue;
        defer allocator.free(content);

        // helpers.Compute blob hash
        const header = try std.fmt.allocPrint(allocator, "blob {d}\x00", .{content.len});
        defer allocator.free(header);

        var hasher = std.crypto.hash.Sha1.init(.{});
        hasher.update(header);
        hasher.update(content);
        var new_hash: [20]u8 = undefined;
        hasher.final(&new_hash);

        if (!std.mem.eql(u8, &new_hash, &entry.sha1)) {
            try to_readd.append(try allocator.dupe(u8, entry.path));
        }
    }

    // helpers.Remove deleted files from index
    for (to_remove.items) |path| {
        try index.remove(path);
    }

    // Re-add modified files (this re-hashes and stores the blob)
    for (to_readd.items) |path| {
        const full_path = if (repo_root.len > 0 and !std.mem.eql(u8, repo_root, "."))
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, path })
        else
            try allocator.dupe(u8, path);
        defer allocator.free(full_path);
        index.add(path, full_path, platform_impl, git_path) catch continue;
    }

    // helpers.Save the updated index
    try index.save(git_path, platform_impl);
}


pub fn addCacheInfo(idx: *index_mod.Index, mode_str: []const u8, hash_str: []const u8, path: []const u8, allocator: std.mem.Allocator) !void {
    const mode = std.fmt.parseInt(u32, mode_str, 8) catch 0o100644;
    
    // helpers.Parse hash
    var sha1: [20]u8 = undefined;
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        sha1[i] = std.fmt.parseInt(u8, hash_str[i * 2 .. i * 2 + 2], 16) catch 0;
    }

    // Reject null helpers.SHA1 for blob and gitlink entries
    const is_zero = blk: {
        for (sha1) |b| {
            if (b != 0) break :blk false;
        }
        break :blk true;
    };
    if (is_zero and mode != 0) {
        return error.NullSha1;
    }

    // helpers.Check for directory/file conflicts  
    if (helpers.checkDFConflict(idx, path)) {
        return error.DirectoryFileConflict;
    }

    // helpers.Remove existing entry with same path
    idx.remove(path) catch {};

    // helpers.Add new entry
    const entry = index_mod.IndexEntry{
        .ctime_sec = 0,
        .ctime_nsec = 0,
        .mtime_sec = 0,
        .mtime_nsec = 0,
        .dev = 0,
        .ino = 0,
        .mode = mode,
        .uid = 0,
        .gid = 0,
        .size = 0,
        .sha1 = sha1,
        .flags = @as(u16, @intCast(@min(path.len, 0xFFF))),
        .extended_flags = null,
        .path = try allocator.dupe(u8, path),
    };
    try idx.entries.append(entry);
    
    // helpers.Sort entries by path
    std.mem.sort(index_mod.IndexEntry, idx.entries.items, {}, struct {
        fn lessThan(_: void, a: index_mod.IndexEntry, b: index_mod.IndexEntry) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lessThan);
}

/// Check if any parent directory of a path is ignored by gitignore
fn isParentDirIgnored(gitignore: *const gitignore_mod.GitIgnore, path: []const u8) bool {
    var remaining: []const u8 = path;
    while (std.mem.indexOfScalar(u8, remaining, '/')) |sep| {
        const parent = path[0 .. @intFromPtr(remaining.ptr) - @intFromPtr(path.ptr) + sep];
        if (gitignore.isIgnoredPath(parent, true)) return true;
        remaining = remaining[sep + 1 ..];
    }
    return false;
}
