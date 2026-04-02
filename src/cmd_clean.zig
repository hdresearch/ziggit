// Auto-generated from main_common.zig - cmd_clean
// Agents: this file is yours to edit for the commands it contains.

const std = @import("std");
const platform_mod = @import("platform/platform.zig");
const helpers = @import("git_helpers.zig");
const succinct_mod = @import("succinct.zig");

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

pub fn nativeCmdClean(_: std.mem.Allocator, args: [][]const u8, command_index: usize, platform_impl: *const platform_mod.Platform) !void {
    var force = false;
    var dry_run = false;
    var clean_dirs = false;
    var quiet = false;
    var exclude_only = false;
    var no_gitignore = false;
    var interactive = false;
    var pathspecs = std.array_list.Managed([]const u8).init(std.heap.page_allocator);
    defer pathspecs.deinit();
    var seen_separator = false;
    
    var i = command_index + 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (seen_separator) {
            pathspecs.append(arg) catch {};
        } else if (std.mem.eql(u8, arg, "--")) {
            seen_separator = true;
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--force")) {
            force = true;
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, arg, "-d")) {
            clean_dirs = true;
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            quiet = true;
        } else if (std.mem.eql(u8, arg, "-x")) {
            no_gitignore = true;
        } else if (std.mem.eql(u8, arg, "-X")) {
            exclude_only = true;
        } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--interactive")) {
            interactive = true;
        } else if (std.mem.eql(u8, arg, "-e") or std.mem.startsWith(u8, arg, "--exclude=")) {
            if (std.mem.eql(u8, arg, "-e")) i += 1;
        } else if (std.mem.eql(u8, arg, "-h")) {
            try platform_impl.writeStdout("usage: git clean [-d] [-f] [-n] [-q] [-x | -X] [--] [<pathspec>...]\n");
            std.process.exit(129);
        } else if (arg.len > 1 and arg[0] == '-' and arg[1] != '-') {
            for (arg[1..]) |c| {
                switch (c) {
                    'f' => force = true,
                    'n' => dry_run = true,
                    'd' => clean_dirs = true,
                    'q' => quiet = true,
                    'x' => no_gitignore = true,
                    'X' => exclude_only = true,
                    'i' => interactive = true,
                    else => {},
                }
            }
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            pathspecs.append(arg) catch {};
        }
    }

    if (!force and !dry_run and !interactive) {
        const allocator2 = std.heap.page_allocator;
        const require_force = blk: {
            if (helpers.readCfg(allocator2, "clean.requireforce", platform_impl)) |val| {
                defer allocator2.free(val);
                if (std.mem.eql(u8, val, "false") or std.mem.eql(u8, val, "no")) break :blk false;
            }
            break :blk true;
        };
        if (require_force) {
            try platform_impl.writeStderr("fatal: clean.requireForce defaults to true and neither -i, -n, nor -f given; refusing to clean\n");
            std.process.exit(128);
        }
    }

    const allocator = std.heap.page_allocator;
    const git_path = helpers.findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
        unreachable;
    };
    defer allocator.free(git_path);
    
    var idx = index_mod.Index.load(git_path, platform_impl, allocator) catch |err| switch (err) {
        error.FileNotFound => index_mod.Index.init(allocator),
        else => return,
    };
    defer idx.deinit();
    
    var tracked_dirs = std.StringHashMap(void).init(allocator);
    defer tracked_dirs.deinit();
    for (idx.entries.items) |ie| {
        var p = ie.path;
        while (std.fs.path.dirname(p)) |parent| {
            if (parent.len == 0) break;
            tracked_dirs.put(parent, {}) catch {};
            p = parent;
        }
    }
    
    const repo_root = std.fs.path.dirname(git_path) orelse ".";
    var gitignore = gitignore_mod.GitIgnore.init(allocator);
    defer gitignore.deinit();
    if (!no_gitignore) {
        const gitignore_path = std.fmt.allocPrint(allocator, "{s}/.gitignore", .{repo_root}) catch "";
        defer if (gitignore_path.len > 0) allocator.free(gitignore_path);
        if (gitignore_path.len > 0) {
            if (platform_impl.fs.readFile(allocator, gitignore_path)) |content| {
                defer allocator.free(content);
                gitignore.addPatterns(content);
            } else |_| {}
        }
        const exclude_path = std.fmt.allocPrint(allocator, "{s}/info/exclude", .{git_path}) catch "";
        defer if (exclude_path.len > 0) allocator.free(exclude_path);
        if (exclude_path.len > 0) {
            if (platform_impl.fs.readFile(allocator, exclude_path)) |content| {
                defer allocator.free(content);
                gitignore.addPatterns(content);
            } else |_| {}
        }
    }
    
    var dir = std.fs.cwd().openDir(repo_root, .{ .iterate = true }) catch return;
    defer dir.close();
    
    var to_remove = std.array_list.Managed([]u8).init(allocator);
    defer {
        for (to_remove.items) |item| allocator.free(item);
        to_remove.deinit();
    }
    
    var walker = dir.walk(allocator) catch return;
    defer walker.deinit();
    
    while (walker.next() catch null) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        const path = entry.path;
        if (std.mem.startsWith(u8, path, ".git/") or std.mem.startsWith(u8, path, ".git\\") or std.mem.eql(u8, path, ".git")) continue;
        
        var tracked = false;
        for (idx.entries.items) |ie| {
            if (std.mem.eql(u8, ie.path, path)) { tracked = true; break; }
        }
        if (tracked) continue;
        
        if (!clean_dirs) {
            const parent = std.fs.path.dirname(path) orelse "";
            if (parent.len > 0 and !tracked_dirs.contains(parent)) continue;
        }
        
        const is_ignored = !no_gitignore and gitignore.isIgnored(path);
        
        if (exclude_only) {
            if (!is_ignored) continue;
        } else {
            if (is_ignored and !no_gitignore) continue;
        }
        
        if (pathspecs.items.len > 0) {
            var matches = false;
            for (pathspecs.items) |ps| {
                const clean_ps = if (std.mem.endsWith(u8, ps, "/")) ps[0..ps.len-1] else ps;
                if (std.mem.startsWith(u8, path, clean_ps) and (path.len == clean_ps.len or (path.len > clean_ps.len and path[clean_ps.len] == '/'))) { matches = true; break; }
                if (std.mem.eql(u8, path, clean_ps)) { matches = true; break; }
            }
            if (!matches) continue;
        }
        
        to_remove.append(allocator.dupe(u8, path) catch continue) catch {};
    }
    
    std.mem.sort([]u8, to_remove.items, {}, struct {
        fn cmp(_: void, a: []u8, b: []u8) bool { return std.mem.lessThan(u8, a, b); }
    }.cmp);
    
    if (succinct_mod.isEnabled()) {
        // Succinct mode: show summary only
        if (to_remove.items.len > 0 and !quiet) {
            if (dry_run) {
                const m = std.fmt.allocPrint(allocator, "would clean {d} files\n", .{to_remove.items.len}) catch return;
                defer allocator.free(m);
                platform_impl.writeStdout(m) catch {};
            } else {
                // Actually remove files first
                for (to_remove.items) |path| {
                    dir.deleteFile(path) catch {};
                    if (std.fs.path.dirname(path)) |parent| {
                        var p = parent;
                        while (p.len > 0) {
                            dir.deleteDir(p) catch break;
                            p = std.fs.path.dirname(p) orelse break;
                        }
                    }
                }
                const m = std.fmt.allocPrint(allocator, "ok clean {d} files\n", .{to_remove.items.len}) catch return;
                defer allocator.free(m);
                platform_impl.writeStdout(m) catch {};
            }
        } else {
            // No output for quiet mode or no files, but still do the removal
            if (!dry_run) {
                for (to_remove.items) |path| {
                    dir.deleteFile(path) catch {};
                    if (std.fs.path.dirname(path)) |parent| {
                        var p = parent;
                        while (p.len > 0) {
                            dir.deleteDir(p) catch break;
                            p = std.fs.path.dirname(p) orelse break;
                        }
                    }
                }
            }
        }
    } else {
        // Normal mode: list each file
        for (to_remove.items) |path| {
            if (dry_run) {
                if (!quiet) {
                    const m = std.fmt.allocPrint(allocator, "Would remove {s}\n", .{path}) catch continue;
                    defer allocator.free(m);
                    platform_impl.writeStdout(m) catch {};
                }
            } else {
                if (!quiet) {
                    const m = std.fmt.allocPrint(allocator, "Removing {s}\n", .{path}) catch continue;
                    defer allocator.free(m);
                    platform_impl.writeStdout(m) catch {};
                }
                dir.deleteFile(path) catch {};
                if (std.fs.path.dirname(path)) |parent| {
                    var p = parent;
                    while (p.len > 0) {
                        dir.deleteDir(p) catch break;
                        p = std.fs.path.dirname(p) orelse break;
                    }
                }
            }
        }
    }
}
