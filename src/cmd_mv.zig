// Auto-generated from main_common.zig - cmd_mv
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

pub fn nativeCmdMv(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    var force = false;
    var dry_run = false;
    var skip_errors = false;
    var verbose = false;
    var sources = std.ArrayList([]const u8).init(allocator);
    defer sources.deinit();
    
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--force")) {
            force = true;
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, arg, "-k")) {
            skip_errors = true;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "--")) {
            while (args.next()) |a| try sources.append(a);
            break;
        } else {
            try sources.append(arg);
        }
    }
    
    if (sources.items.len < 2) {
        try platform_impl.writeStderr("usage: git mv [<options>] <source>... <destination>\n");
        std.process.exit(128);
    }
    
    const git_path = helpers.findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);
    
    const dest = sources.items[sources.items.len - 1];
    const srcs = sources.items[0 .. sources.items.len - 1];
    
    // helpers.Load index
    var index = index_mod.Index.load(git_path, platform_impl, allocator) catch |err| switch (err) {
        error.FileNotFound => index_mod.Index.init(allocator),
        else => return err,
    };
    defer index.deinit();
    
    // helpers.Check if dest is a directory
    const dest_is_dir = if (std.fs.cwd().statFile(dest)) |stat|
        stat.kind == .directory
    else |_|
        false;
    
    if (srcs.len > 1 and !dest_is_dir) {
        try platform_impl.writeStderr("fatal: destination is not a directory\n");
        std.process.exit(128);
    }
    
    for (srcs) |src| {
        const target = if (dest_is_dir) blk: {
            const basename = std.fs.path.basename(src);
            break :blk try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dest, basename });
        } else try allocator.dupe(u8, dest);
        defer allocator.free(target);
        
        // helpers.Check source exists
        if (!(std.fs.cwd().statFile(src) catch null != null)) {
            if (skip_errors) continue;
            const msg = try std.fmt.allocPrint(allocator, "fatal: bad source, source={s}, destination={s}\n", .{ src, target });
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(128);
        }
        
        // helpers.Check target doesn't exist (unless -f or case-change/normalization rename)
        if (!force) {
            if ((std.fs.cwd().statFile(target) catch null) != null) {
                // Allow rename if source and target refer to the same file
                // (case-change or Unicode normalization on the filesystem)
                const is_case_change = std.ascii.eqlIgnoreCase(src, target) and !std.mem.eql(u8, src, target);
                const src_stat = std.fs.cwd().statFile(src) catch null;
                const tgt_stat = std.fs.cwd().statFile(target) catch null;
                const is_same_inode = if (src_stat != null and tgt_stat != null)
                    (src_stat.?.inode == tgt_stat.?.inode)
                else
                    false;
                // Also check if the target is not tracked in the index
                // (untracked files at destination shouldn't block git mv)
                var target_in_index = false;
                for (index.entries.items) |entry| {
                    if (std.mem.eql(u8, entry.path, target)) {
                        target_in_index = true;
                        break;
                    }
                }
                if (!is_case_change and !is_same_inode and target_in_index) {
                    if (skip_errors) continue;
                    const msg = try std.fmt.allocPrint(allocator, "fatal: destination exists, source={s}, destination={s}\n", .{ src, target });
                    defer allocator.free(msg);
                    try platform_impl.writeStderr(msg);
                    std.process.exit(128);
                }
            }
        }
        
        if (!dry_run) {
            // helpers.Move the file
            std.fs.cwd().rename(src, target) catch |err| {
                if (skip_errors) continue;
                const msg = try std.fmt.allocPrint(allocator, "fatal: renaming '{s}' failed: {}\n", .{ src, err });
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(128);
            };
            
            // helpers.Update index: remove old entry, add new entry
            var new_entries = std.ArrayList(index_mod.IndexEntry).init(allocator);
            defer new_entries.deinit();
            
            for (index.entries.items) |entry| {
                if (std.mem.eql(u8, entry.path, src)) {
                    var new_entry = entry;
                    new_entry.path = try allocator.dupe(u8, target);
                    // helpers.Update flags to reflect new path length (lower 12 bits)
                    const path_len_bits: u16 = if (target.len >= 0xFFF) 0xFFF else @intCast(target.len);
                    new_entry.flags = (entry.flags & 0xF000) | path_len_bits;
                    try new_entries.append(new_entry);
                } else {
                    try new_entries.append(entry);
                }
            }
            index.entries.clearRetainingCapacity();
            for (new_entries.items) |e| try index.entries.append(e);
        }
        
        if (verbose or dry_run) {
            const msg = try std.fmt.allocPrint(allocator, "Renaming {s} to {s}\n", .{ src, target });
            defer allocator.free(msg);
            try platform_impl.writeStdout(msg);
        }
    }
    
    if (!dry_run) {
        index.save(git_path, platform_impl) catch {};
    }
}
