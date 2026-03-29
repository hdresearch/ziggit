// Auto-generated from main_common.zig - cmd_add
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
        } else if (raw_arg.len > 0 and raw_arg[0] == '-') {
            // helpers.Skip other flags
        } else {
            try collected_add_paths.append(raw_arg);
        }
    }
    if ((add_all_flag or update_flag) and collected_add_paths.items.len == 0) {
        try collected_add_paths.append(".");
    }

    // helpers.Process all file arguments
    for (collected_add_paths.items) |file_path| {
        has_files = true;
        
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
                if (platform_impl.fs.exists(fp) catch false) {
                    const content = platform_impl.fs.readFile(allocator, fp) catch continue;
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
                    // helpers.Update stat info
                    const stat = std.fs.cwd().statFile(fp) catch continue;
                    entry.mtime_sec = @intCast(@divFloor(stat.mtime, 1_000_000_000));
                    entry.mtime_nsec = @intCast(@mod(stat.mtime, 1_000_000_000));
                    entry.ctime_sec = @intCast(@divFloor(stat.ctime, 1_000_000_000));
                    entry.ctime_nsec = @intCast(@mod(stat.ctime, 1_000_000_000));
                    entry.size = @intCast(stat.size);
                }
            }
        } else if (std.mem.eql(u8, file_path, ".")) {
            // helpers.Add all files in current directory (recursively)
            try addDirectoryRecursively(allocator, cwd, "", &index, git_path, platform_impl);
        } else {
            // helpers.Resolve file path 
            const full_file_path = if (std.fs.path.isAbsolute(file_path))
                try allocator.dupe(u8, file_path)
            else
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cwd, file_path });
            defer allocator.free(full_file_path);
            
            // helpers.Convert to path relative to repo root
            const repo_root_for_rel = std.fs.path.dirname(git_path) orelse ".";
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
            const metadata = std.fs.cwd().statFile(full_file_path) catch {
                // helpers.If we can't stat it (e.g. broken symlink), try to add it
                try addSingleFile(allocator, relative_file_path, full_file_path, &index, git_path, platform_impl, repo_root_for_rel);
                continue;
            };

            if (metadata.kind == .directory) {
                // helpers.Add directory recursively
                try addDirectoryRecursively(allocator, repo_root_for_rel, relative_file_path, &index, git_path, platform_impl);
            } else {
                // helpers.Add single file
                try addSingleFile(allocator, relative_file_path, full_file_path, &index, git_path, platform_impl, repo_root_for_rel);
            }
        }
    }

    if (!has_files) {
        try platform_impl.writeStderr("Nothing specified, nothing added.\n");
        try platform_impl.writeStderr("hint: helpers.Maybe you wanted to say 'git add .'?\n");
        try platform_impl.writeStderr("hint: Disable this message with \"git config set advice.addEmptyPathspec false\"\n");
        return;
    }

    // helpers.When --all or --update, remove index entries for deleted files
    if (add_all_flag or update_flag) {
        const repo_root = std.fs.path.dirname(git_path) orelse ".";
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

    // helpers.Save index
    try index.save(git_path, platform_impl);
}


pub fn addSingleFile(allocator: std.mem.Allocator, relative_path: []const u8, full_path: []const u8, index: *index_mod.Index, git_path: []const u8, platform_impl: *const platform_mod.Platform, repo_root: []const u8) !void {
    // helpers.Check if file is ignored
    const gitignore_path = try std.fmt.allocPrint(allocator, "{s}/.gitignore", .{repo_root});
    defer allocator.free(gitignore_path);
    
    var gitignore = gitignore_mod.GitIgnore.loadFromFile(allocator, gitignore_path, platform_impl) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => gitignore_mod.GitIgnore.init(allocator), // helpers.If there's any issue loading, just use empty gitignore
    };
    defer gitignore.deinit();
    
    if (gitignore.isIgnored(relative_path)) {
        // helpers.Just skip ignored files instead of erroring
        return;
    }

    // helpers.Add to index
    index.add(relative_path, full_path, platform_impl, git_path) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            const msg = try std.fmt.allocPrint(allocator, "error: failed to add '{s}' to index\n", .{relative_path});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            return err;
        },
    };
}


pub fn addDirectoryRecursively(allocator: std.mem.Allocator, repo_root: []const u8, relative_dir: []const u8, index: *index_mod.Index, git_path: []const u8, platform_impl: *const platform_mod.Platform) !void {
    const full_dir_path = if (relative_dir.len == 0)
        try allocator.dupe(u8, repo_root)
    else
        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, relative_dir });
    defer allocator.free(full_dir_path);

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
        
        const entry_full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ full_dir_path, entry.name });
        defer allocator.free(entry_full_path);
        
        switch (entry.kind) {
            .file => {
                addSingleFile(allocator, entry_relative_path, entry_full_path, index, git_path, platform_impl, repo_root) catch continue;
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
                addDirectoryRecursively(allocator, repo_root, entry_relative_path, index, git_path, platform_impl) catch continue;
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
