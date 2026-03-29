// Auto-generated from main_common.zig - cmd_ls_tree
// Agents: this file is yours to edit for the commands it contains.

const std = @import("std");
const platform_mod = @import("platform/platform.zig");
const helpers = @import("git_helpers.zig");
const cmd_diff_tree = @import("cmd_diff_tree.zig");

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

pub fn nativeCmdLsTree(allocator: std.mem.Allocator, args: [][]const u8, command_index: usize, platform_impl: *const platform_mod.Platform) !void {
    var recursive = false;
    var show_trees = false; // -t flag
    var only_trees = false; // -d flag
    var name_only = false;
    var name_status = false;
    var long_format = false;
    var null_terminated = false;
    var abbrev_len: ?usize = null;
    var full_tree = false;
    var full_name = false;
    var object_only = false;
    var has_format = false;
    var format_str: ?[]const u8 = null;
    var treeish: ?[]const u8 = null;
    var pathspecs = std.ArrayList([]const u8).init(allocator);
    defer pathspecs.deinit();

    var i = command_index + 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-r")) {
            recursive = true;
        } else if (std.mem.eql(u8, arg, "-t")) {
            show_trees = true;
        } else if (std.mem.eql(u8, arg, "-d")) {
            only_trees = true;
        } else if (std.mem.eql(u8, arg, "--name-only")) {
            name_only = true;
        } else if (std.mem.eql(u8, arg, "--name-status")) {
            name_status = true;
        } else if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--long")) {
            long_format = true;
        } else if (std.mem.eql(u8, arg, "-z")) {
            null_terminated = true;
        } else if (std.mem.eql(u8, arg, "--full-tree")) {
            full_tree = true;
        } else if (std.mem.eql(u8, arg, "--full-name")) {
            full_name = true;
        } else if (std.mem.eql(u8, arg, "--no-full-name")) {
            full_name = false;
        } else if (std.mem.eql(u8, arg, "--object-only")) {
            object_only = true;
        } else if (std.mem.startsWith(u8, arg, "--format=")) {
            has_format = true;
            format_str = arg["--format=".len..];
        } else if (std.mem.eql(u8, arg, "--abbrev")) {
            abbrev_len = 7; // default abbrev length
        } else if (std.mem.startsWith(u8, arg, "--abbrev=")) {
            const val = arg["--abbrev=".len..];
            abbrev_len = std.fmt.parseInt(usize, val, 10) catch 7;
        } else if (std.mem.eql(u8, arg, "--")) {
            // Everything after -- is a pathspec
            i += 1;
            while (i < args.len) : (i += 1) {
                try pathspecs.append(args[i]);
            }
            break;
        } else if (std.mem.eql(u8, arg, "-h")) {
            try platform_impl.writeStdout("usage: git ls-tree [<options>] <tree-ish> [<path>...]\n\n    -d                  only show trees\n    -r                  recurse into subtrees\n    -t                  show trees when recursing\n    --name-only         list only filenames\n    --name-status       list only filenames\n    --long              include object size\n    -z                  terminate entries with helpers.NUL byte\n");
            return;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            if (treeish == null) {
                treeish = arg;
            } else {
                try pathspecs.append(arg);
            }
        }
    }

    // helpers.Validate incompatible options
    {
        const name_opts = @as(u8, if (name_only) 1 else 0) + @as(u8, if (object_only) 1 else 0);
        if (long_format and (name_only or name_status)) {
            try platform_impl.writeStderr("error: --long is incompatible with --name-only\n");
            std.process.exit(129);
        }
        if (long_format and object_only) {
            try platform_impl.writeStderr("error: --long is incompatible with --object-only\n");
            std.process.exit(129);
        }
        if (name_only and name_status) {
            try platform_impl.writeStderr("error: --name-status is incompatible with --name-only\n");
            std.process.exit(129);
        }
        if ((name_only or name_status) and object_only) {
            if (name_status) {
                try platform_impl.writeStderr("error: --object-only is incompatible with --name-status\n");
            } else {
                try platform_impl.writeStderr("error: --object-only is incompatible with --name-only\n");
            }
            std.process.exit(129);
        }
        _ = name_opts;
        if (has_format) {
            if (long_format or name_only or name_status or object_only) {
                try platform_impl.writeStderr("error: --format can't be combined with other format-altering options\n");
                std.process.exit(129);
            }
        }
        // helpers.Merge name_status into name_only for output purposes
        if (name_status) name_only = true;
    }

    if (treeish == null) {
        try platform_impl.writeStderr("fatal: not enough arguments\n");
        std.process.exit(128);
    }

    const git_path = helpers.findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any of the parent directories): .git\n");
        std.process.exit(128);
        unreachable;
    };
    defer allocator.free(git_path);

    // helpers.Compute prefix (path from repo root to CWD)
    var prefix_str: []const u8 = "";
    var prefix_allocated = false;
    if (!full_tree) {
        const cwd = platform_impl.fs.getCwd(allocator) catch "";
        defer if (cwd.len > 0) allocator.free(cwd);
        // git_path is like /path/to/repo/.git, repo root is parent
        const repo_root = std.fs.path.dirname(git_path) orelse "";
        if (cwd.len > 0 and repo_root.len > 0 and cwd.len > repo_root.len and
            std.mem.startsWith(u8, cwd, repo_root) and cwd[repo_root.len] == '/')
        {
            prefix_str = allocator.dupe(u8, cwd[repo_root.len + 1 ..]) catch "";
            prefix_allocated = prefix_str.len > 0;
        }
    }
    defer if (prefix_allocated) allocator.free(@constCast(prefix_str));

    // Adjust pathspecs with prefix (prepend prefix to relative pathspecs)
    var adjusted_pathspecs = std.ArrayList([]const u8).init(allocator);
    defer {
        for (adjusted_pathspecs.items) |ps| allocator.free(@constCast(ps));
        adjusted_pathspecs.deinit();
    }
    var no_path_restriction = false;
    if (prefix_str.len > 0 and pathspecs.items.len > 0) {
        for (pathspecs.items) |ps| {
            // helpers.Resolve relative paths like ../
            const combined = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix_str, ps });
            defer allocator.free(combined);
            const normalized = try helpers.normalizePath(allocator, combined);
            if (normalized.len == 0) {
                allocator.free(normalized);
                // helpers.Path resolved to root - no restriction
                no_path_restriction = true;
                for (adjusted_pathspecs.items) |existing| allocator.free(@constCast(existing));
                adjusted_pathspecs.clearRetainingCapacity();
                break;
            } else {
                try adjusted_pathspecs.append(normalized);
            }
        }
    } else if (prefix_str.len > 0 and pathspecs.items.len == 0) {
        // helpers.When no pathspecs given but in a subdirectory, restrict to prefix
        const adjusted = try std.fmt.allocPrint(allocator, "{s}/", .{prefix_str});
        try adjusted_pathspecs.append(adjusted);
    }

    // helpers.Use adjusted pathspecs if we have them, otherwise original
    // helpers.Check for --full-tree with ../ pathspec (should error)
    if (full_tree) {
        for (pathspecs.items) |ps| {
            if (std.mem.startsWith(u8, ps, "../") or std.mem.eql(u8, ps, "..")) {
                const msg = try std.fmt.allocPrint(allocator, "fatal: {s}: '{s}' is outside repository\n", .{ ps, ps });
                defer allocator.free(msg);
                try platform_impl.writeStderr(msg);
                std.process.exit(128);
                unreachable;
            }
        }
    }

    // helpers.Use empty pathspecs when path resolved to root (show everything)
    var empty_pathspecs = std.ArrayList([]const u8).init(allocator);
    defer empty_pathspecs.deinit();
    const effective_pathspecs = if (no_path_restriction)
        &empty_pathspecs
    else if (adjusted_pathspecs.items.len > 0)
        &adjusted_pathspecs
    else
        &pathspecs;

    // helpers.Resolve tree-ish to a tree hash
    const tree_hash = helpers.resolveTreeish(git_path, treeish.?, platform_impl, allocator) catch {
        const msg = try std.fmt.allocPrint(allocator, "fatal: helpers.Not a valid object name {s}\n", .{treeish.?});
        defer allocator.free(msg);
        try platform_impl.writeStderr(msg);
        std.process.exit(128);
        unreachable;
    };
    defer allocator.free(tree_hash);

    // helpers.Collect all output entries
    var output_entries = std.ArrayList(OutputEntry) .init(allocator);
    defer {
        for (output_entries.items) |*entry| entry.deinit(allocator);
        output_entries.deinit();
    }

    // helpers.Walk the tree
    walkTree(allocator, git_path, tree_hash, "", recursive, show_trees, only_trees, effective_pathspecs, platform_impl, &output_entries) catch {
        try platform_impl.writeStderr("fatal: not a tree object\n");
        std.process.exit(128);
        unreachable;
    };

    // Tree entries are already stored in sorted order in the tree object,
    // so we don't re-sort (git's tree sorting uses implicit trailing / for directories)

    // helpers.Output
    // helpers.Read core.quotePath config (default true)
    var quote_path = true;
    {
        const config_path = std.fmt.allocPrint(allocator, "{s}/config", .{git_path}) catch null;
        if (config_path) |cp| {
            defer allocator.free(cp);
            if (std.fs.cwd().readFileAlloc(allocator, cp, 1024 * 1024)) |config_content| {
                defer allocator.free(config_content);
                // helpers.Simple search for quotepath = false
                if (std.mem.indexOf(u8, config_content, "quotepath = false") != null or
                    std.mem.indexOf(u8, config_content, "quotePath = false") != null)
                {
                    quote_path = false;
                }
            } else |_| {}
        }
    }

    const line_end: []const u8 = if (null_terminated) "\x00" else "\n";
    for (output_entries.items) |entry| {
        // helpers.Apply hash abbreviation
        const display_hash = if (abbrev_len) |abl|
            entry.hash[0..@min(abl, entry.hash.len)]
        else
            entry.hash;
        // By default, paths are shown relative to CWD (prefix).
        // --full-name shows repo-root-relative paths.
        const raw_display_path = if (!full_name and prefix_str.len > 0) blk: {
            break :blk try helpers.makeRelativePath(allocator, prefix_str, entry.full_path);
        } else entry.full_path;
        const raw_display_path_allocated = !full_name and prefix_str.len > 0;
        defer if (raw_display_path_allocated) allocator.free(@constCast(raw_display_path));

        // C-quote the path if it contains special characters
        const quoted_path = try helpers.cQuotePath(allocator, raw_display_path, quote_path);
        defer allocator.free(quoted_path);
        const display_path = quoted_path;

        if (format_str) |fmt| {
            // Custom format string
            const formatted = try formatLsTreeEntry(allocator, fmt, entry, display_hash, display_path, git_path, platform_impl);
            defer allocator.free(formatted);
            const output = try std.fmt.allocPrint(allocator, "{s}{s}", .{ formatted, line_end });
            defer allocator.free(output);
            try platform_impl.writeStdout(output);
        } else if (object_only) {
            const output = try std.fmt.allocPrint(allocator, "{s}{s}", .{ display_hash, line_end });
            defer allocator.free(output);
            try platform_impl.writeStdout(output);
        } else if (name_only) {
            const output = try std.fmt.allocPrint(allocator, "{s}{s}", .{ display_path, line_end });
            defer allocator.free(output);
            try platform_impl.writeStdout(output);
        } else if (long_format) {
            // Long format: mode type size\thash\tpath
            const size_str = if (std.mem.eql(u8, entry.obj_type, "tree") or std.mem.eql(u8, entry.obj_type, "commit"))
                try allocator.dupe(u8, "      -")
            else blk: {
                // helpers.Load the object to get its size
                const obj = objects.GitObject.load(entry.hash, git_path, platform_impl, allocator) catch {
                    break :blk try allocator.dupe(u8, "      ?");
                };
                defer obj.deinit(allocator);
                break :blk try std.fmt.allocPrint(allocator, "{d:>7}", .{obj.data.len});
            };
            defer allocator.free(size_str);
            const output = try std.fmt.allocPrint(allocator, "{s} {s} {s} {s}\t{s}{s}", .{ entry.mode, entry.obj_type, display_hash, size_str, display_path, line_end });
            defer allocator.free(output);
            try platform_impl.writeStdout(output);
        } else {
            const output = try std.fmt.allocPrint(allocator, "{s} {s} {s}\t{s}{s}", .{ entry.mode, entry.obj_type, display_hash, display_path, line_end });
            defer allocator.free(output);
            try platform_impl.writeStdout(output);
        }
    }
}

const OutputEntry = struct {
    mode: []const u8,
    obj_type: []const u8,
    hash: []const u8,
    full_path: []const u8,

    fn deinit(self: *OutputEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.mode);
        allocator.free(self.hash);
        allocator.free(self.full_path);
    }
};


pub fn walkTree(
    allocator: std.mem.Allocator,
    git_path: []const u8,
    tree_hash: []const u8,
    prefix: []const u8,
    recursive: bool,
    show_trees: bool,
    only_trees: bool,
    pathspecs: *std.ArrayList([]const u8),
    platform_impl: *const platform_mod.Platform,
    output: *std.ArrayList(OutputEntry),
) !void {
    // helpers.Load the tree object
    const tree_obj = objects.GitObject.load(tree_hash, git_path, platform_impl, allocator) catch {
        return error.ObjectNotFound;
    };
    defer tree_obj.deinit(allocator);

    if (tree_obj.type != .tree) return error.ObjectNotFound;

    // helpers.Parse tree entries
    var entries = try helpers.parseTreeEntries(tree_obj.data, allocator);
    defer {
        for (entries.items) |*entry| entry.deinit(allocator);
        entries.deinit();
    }

    for (entries.items) |entry| {
        const full_path = if (prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name })
        else
            try allocator.dupe(u8, entry.name);

        const is_tree = std.mem.eql(u8, entry.obj_type, "tree");
        const is_submodule = std.mem.eql(u8, entry.obj_type, "commit");
        const is_directory_like = is_tree or is_submodule;

        // helpers.Check pathspec filtering
        if (pathspecs.items.len > 0) {
            var matches = false;
            for (pathspecs.items) |pathspec| {
                if (helpers.pathMatchesSpec(full_path, pathspec, is_directory_like)) {
                    matches = true;
                    break;
                }
                // helpers.Also check if this tree is a prefix of the pathspec (need to recurse into it)
                if (is_tree and helpers.pathSpecStartsWith(pathspec, full_path)) {
                    matches = true;
                    break;
                }
            }
            if (!matches) {
                allocator.free(full_path);
                continue;
            }
        }

        if (is_tree) {
            if (recursive) {
                if (show_trees or only_trees) {
                    try output.append(OutputEntry{
                        .mode = try allocator.dupe(u8, entry.mode),
                        .obj_type = entry.obj_type,
                        .hash = try allocator.dupe(u8, entry.hash),
                        .full_path = try allocator.dupe(u8, full_path),
                    });
                }
                if (!only_trees) {
                    try walkTree(allocator, git_path, entry.hash, full_path, recursive, show_trees, only_trees, pathspecs, platform_impl, output);
                } else {
                    // Even with -d, recurse to find subtrees
                    try walkTree(allocator, git_path, entry.hash, full_path, recursive, show_trees, only_trees, pathspecs, platform_impl, output);
                }
            } else {
                // Non-recursive: check if pathspec asks for contents of this tree
                var show_children = false;
                if (pathspecs.items.len > 0) {
                    for (pathspecs.items) |pathspec| {
                        // helpers.If pathspec ends with '/' and matches this tree, show children
                        if (std.mem.endsWith(u8, pathspec, "/") and
                            std.mem.eql(u8, full_path, pathspec[0 .. pathspec.len - 1]))
                        {
                            show_children = true;
                            break;
                        }
                        // helpers.If pathspec has more components beyond this tree, show children
                        if (helpers.pathSpecStartsWith(pathspec, full_path) and
                            pathspec.len > full_path.len and pathspec[full_path.len] == '/')
                        {
                            show_children = true;
                            break;
                        }
                    }
                }

                if (show_children) {
                    // With -t flag, show intermediate tree entries
                    if (show_trees) {
                        try output.append(OutputEntry{
                            .mode = try allocator.dupe(u8, entry.mode),
                            .obj_type = entry.obj_type,
                            .hash = try allocator.dupe(u8, entry.hash),
                            .full_path = try allocator.dupe(u8, full_path),
                        });
                    }
                    // helpers.Recursively descend into this tree to find matching entries
                    // (handles deep pathspecs like path1/b/c/1.txt)
                    try walkTree(allocator, git_path, entry.hash, full_path, false, show_trees, only_trees, pathspecs, platform_impl, output);
                } else if (!only_trees or is_tree) {
                    try output.append(OutputEntry{
                        .mode = try allocator.dupe(u8, entry.mode),
                        .obj_type = entry.obj_type,
                        .hash = try allocator.dupe(u8, entry.hash),
                        .full_path = try allocator.dupe(u8, full_path),
                    });
                }
            }
        } else {
            // Blob or submodule entry
            if (!only_trees or is_submodule) {
                try output.append(OutputEntry{
                    .mode = try allocator.dupe(u8, entry.mode),
                    .obj_type = entry.obj_type,
                    .hash = try allocator.dupe(u8, entry.hash),
                    .full_path = try allocator.dupe(u8, full_path),
                });
            }
        }

        allocator.free(full_path);
    }
}


pub fn walkTreeOneLevel(
    allocator: std.mem.Allocator,
    git_path: []const u8,
    tree_hash: []const u8,
    prefix: []const u8,
    pathspecs: *std.ArrayList([]const u8),
    platform_impl: *const platform_mod.Platform,
    output: *std.ArrayList(OutputEntry),
    show_trees_flag: bool,
) !void {
    _ = show_trees_flag;
    const tree_obj = objects.GitObject.load(tree_hash, git_path, platform_impl, allocator) catch return;
    defer tree_obj.deinit(allocator);
    if (tree_obj.type != .tree) return;

    var entries = try helpers.parseTreeEntries(tree_obj.data, allocator);
    defer {
        for (entries.items) |*entry| entry.deinit(allocator);
        entries.deinit();
    }

    for (entries.items) |entry| {
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name });
        defer allocator.free(full_path);

        const is_tree = std.mem.eql(u8, entry.obj_type, "tree");

        // helpers.Check pathspec filtering for sub-entries
        if (pathspecs.items.len > 0) {
            var matches = false;
            for (pathspecs.items) |pathspec| {
                if (helpers.pathMatchesSpec(full_path, pathspec, is_tree)) {
                    matches = true;
                    break;
                }
                if (is_tree and helpers.pathSpecStartsWith(pathspec, full_path)) {
                    matches = true;
                    break;
                }
            }
            if (!matches) continue;
        }

        try output.append(OutputEntry{
            .mode = try allocator.dupe(u8, entry.mode),
            .obj_type = entry.obj_type,
            .hash = try allocator.dupe(u8, entry.hash),
            .full_path = try allocator.dupe(u8, full_path),
        });
    }
}


pub fn formatLsTreeEntry(
    allocator: std.mem.Allocator,
    fmt: []const u8,
    entry: OutputEntry,
    display_hash: []const u8,
    display_path: []const u8,
    git_path: []const u8,
    platform_impl: *const platform_mod.Platform,
) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    var i: usize = 0;
    while (i < fmt.len) {
        if (fmt[i] == '%' and i + 1 < fmt.len) {
            if (fmt[i + 1] == '(') {
              if (std.mem.indexOf(u8, fmt[i..], ")")) |close_offset| {
                const placeholder = fmt[i + 2 .. i + close_offset];
                if (std.mem.eql(u8, placeholder, "objectmode")) {
                    try result.appendSlice(entry.mode);
                } else if (std.mem.eql(u8, placeholder, "objecttype")) {
                    try result.appendSlice(entry.obj_type);
                } else if (std.mem.eql(u8, placeholder, "objectname")) {
                    try result.appendSlice(display_hash);
                } else if (std.mem.eql(u8, placeholder, "objectsize")) {
                    if (std.mem.eql(u8, entry.obj_type, "tree") or std.mem.eql(u8, entry.obj_type, "commit")) {
                        try result.append('-');
                    } else {
                        const obj = objects.GitObject.load(entry.hash, git_path, platform_impl, allocator) catch {
                            try result.append('-');
                            i += close_offset + 1;
                            continue;
                        };
                        defer obj.deinit(allocator);
                        const sz = try std.fmt.allocPrint(allocator, "{d}", .{obj.data.len});
                        defer allocator.free(sz);
                        try result.appendSlice(sz);
                    }
                } else if (std.mem.eql(u8, placeholder, "objectsize:padded")) {
                    if (std.mem.eql(u8, entry.obj_type, "tree") or std.mem.eql(u8, entry.obj_type, "commit")) {
                        try result.appendSlice("      -");
                    } else {
                        const obj = objects.GitObject.load(entry.hash, git_path, platform_impl, allocator) catch {
                            try result.appendSlice("      -");
                            i += close_offset + 1;
                            continue;
                        };
                        defer obj.deinit(allocator);
                        const sz = try std.fmt.allocPrint(allocator, "{d:>7}", .{obj.data.len});
                        defer allocator.free(sz);
                        try result.appendSlice(sz);
                    }
                } else if (std.mem.eql(u8, placeholder, "path")) {
                    try result.appendSlice(display_path);
                }
                i += close_offset + 1;
              } else {
                try result.append(fmt[i]);
                i += 1;
              }
            } else if (fmt[i + 1] == 'x' and i + 3 < fmt.len) {
                // Hex escape: %xNN
                const hex_str = fmt[i + 2 .. i + 4];
                const byte = std.fmt.parseInt(u8, hex_str, 16) catch {
                    try result.append('%');
                    i += 1;
                    continue;
                };
                try result.append(byte);
                i += 4;
            } else {
                try result.append(fmt[i]);
                i += 1;
            }
        } else {
            try result.append(fmt[i]);
            i += 1;
        }
    }
    return try allocator.dupe(u8, result.items);
}

// Given a prefix (CWD relative to repo root) and a full_path (relative to repo root),
// compute the display path relative to prefix. E.g., prefix="aa", full_path="a[a]/three" → "../a[a]/three"