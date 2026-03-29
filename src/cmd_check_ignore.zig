// Auto-generated from main_common.zig - cmd_check_ignore
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

pub fn nativeCmdCheckIgnore(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    var verbose = false;
    var quiet = false;
    var use_stdin = false;
    var use_z = false;
    var non_matching = false;
    var paths = std.ArrayList([]const u8).init(allocator);
    defer paths.deinit();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            quiet = true;
        } else if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--non-matching")) {
            non_matching = true;
        } else if (std.mem.eql(u8, arg, "--stdin")) {
            use_stdin = true;
        } else if (std.mem.eql(u8, arg, "-z")) {
            use_z = true;
        } else if (std.mem.eql(u8, arg, "--no-index")) {
            // accepted but not used differently yet
        } else if (std.mem.eql(u8, arg, "--")) {
            while (args.next()) |a| try paths.append(a);
            break;
        } else if (arg.len > 0 and arg[0] == '-') {
            // helpers.Unknown option - ignore
        } else {
            try paths.append(arg);
        }
    }

    // helpers.Validate option combinations
    if (quiet and verbose) {
        try platform_impl.writeStderr("fatal: cannot have both --quiet and --verbose\n");
        std.process.exit(128);
    }

    if (use_z and !use_stdin) {
        try platform_impl.writeStderr("fatal: -z only makes sense with --stdin\n");
        std.process.exit(128);
    }

    if (use_stdin and paths.items.len > 0) {
        try platform_impl.writeStderr("fatal: cannot specify pathnames with --stdin\n");
        std.process.exit(128);
    }

    if (!use_stdin and paths.items.len == 0) {
        try platform_impl.writeStderr("fatal: no path specified\n");
        std.process.exit(128);
    }

    if (quiet and !use_stdin and paths.items.len > 1) {
        try platform_impl.writeStderr("fatal: --quiet is only valid with a single pathname\n");
        std.process.exit(128);
    }

    // helpers.Read paths from stdin if needed
    var stdin_buf: ?[]u8 = null;
    defer if (stdin_buf) |b| allocator.free(b);
    if (use_stdin) {
        const stdin_file = std.fs.File{ .handle = std.posix.STDIN_FILENO };
        stdin_buf = stdin_file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch null;
        if (stdin_buf) |buf| {
            if (use_z) {
                var it = std.mem.splitScalar(u8, buf, 0);
                while (it.next()) |entry| {
                    if (entry.len > 0) try paths.append(entry);
                }
            } else {
                var it = std.mem.splitScalar(u8, buf, '\n');
                while (it.next()) |line| {
                    if (line.len > 0) try paths.append(line);
                }
            }
        }
    }

    const git_path = helpers.findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);

    const repo_root = std.fs.path.dirname(git_path) orelse ".";

    const cwd = try platform_impl.fs.getCwd(allocator);
    defer allocator.free(cwd);

    // helpers.Build a combined gitignore that loads from multiple sources
    var gitignore = gitignore_mod.GitIgnore.init(allocator);
    defer gitignore.deinit();

    // helpers.Load from $GIT_DIR/info/exclude
    const exclude_path = try std.fmt.allocPrint(allocator, "{s}/info/exclude", .{git_path});
    defer allocator.free(exclude_path);
    if (platform_impl.fs.readFile(allocator, exclude_path)) |content| {
        defer allocator.free(content);
        gitignore.addPatternsFromSource(content, ".git/info/exclude");
    } else |_| {}

    // helpers.Load from core.excludesfile (global)
    {
        var config = config_mod.loadGitConfig(git_path, allocator) catch null;
        defer if (config) |*c| c.deinit();
        const global_path_val: ?[]const u8 = if (config) |c| c.get("core", null, "excludesfile") else null;
        if (global_path_val) |gp| {
            const gpath = allocator.dupe(u8, gp) catch null;
            if (gpath) |global_path| {
                defer allocator.free(global_path);
                const expanded = if (global_path.len > 0 and global_path[0] == '~') epath: {
                    const home = std.process.getEnvVarOwned(allocator, "HOME") catch break :epath global_path;
                    defer allocator.free(home);
                    break :epath std.fmt.allocPrint(allocator, "{s}{s}", .{ home, global_path[1..] }) catch break :epath global_path;
                } else global_path;
                defer if (expanded.ptr != global_path.ptr) allocator.free(expanded);
                if (platform_impl.fs.readFile(allocator, expanded)) |content| {
                    defer allocator.free(content);
                    gitignore.addPatternsFromSource(content, expanded);
                } else |_| {}
            }
        }
    }

    // helpers.Load repo-level .gitignore
    const gitignore_path = try std.fmt.allocPrint(allocator, "{s}/.gitignore", .{repo_root});
    defer allocator.free(gitignore_path);
    if (platform_impl.fs.readFile(allocator, gitignore_path)) |content| {
        defer allocator.free(content);
        gitignore.addPatternsFromSource(content, ".gitignore");
    } else |_| {}

    const line_end: []const u8 = if (use_z) "\x00" else "\n";
    const sep: []const u8 = "\t";
    var found_any = false;

    for (paths.items) |path| {
        // helpers.Resolve path relative to repo root
        var check_path: []const u8 = path;
        var allocated_check_path: ?[]u8 = null;
        defer if (allocated_check_path) |p| allocator.free(p);

        if (std.mem.eql(u8, path, ".")) {
            if (cwd.len > repo_root.len and std.mem.startsWith(u8, cwd, repo_root) and cwd[repo_root.len] == '/') {
                check_path = cwd[repo_root.len + 1 ..];
            }
        } else if (!std.fs.path.isAbsolute(path)) {
            if (cwd.len > repo_root.len and std.mem.startsWith(u8, cwd, repo_root) and cwd[repo_root.len] == '/') {
                const prefix = cwd[repo_root.len + 1 ..];
                allocated_check_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, path });
                check_path = allocated_check_path.?;
            }
        }

        // helpers.Load directory-specific .gitignore files along the path
        var dir_gitignore = gitignore_mod.GitIgnore.init(allocator);
        defer dir_gitignore.deinit();
        {
            var prefix_end: usize = 0;
            while (std.mem.indexOfPos(u8, check_path, prefix_end, "/")) |slash| {
                const subdir = check_path[0..slash];
                const sub_gi_path = try std.fmt.allocPrint(allocator, "{s}/{s}/.gitignore", .{ repo_root, subdir });
                defer allocator.free(sub_gi_path);
                if (platform_impl.fs.readFile(allocator, sub_gi_path)) |content| {
                    defer allocator.free(content);
                    const rel_source = try std.fmt.allocPrint(allocator, "{s}/.gitignore", .{subdir});
                    defer allocator.free(rel_source);
                    dir_gitignore.addPatternsFromSource(content, rel_source);
                } else |_| {}
                prefix_end = slash + 1;
            }
        }

        // helpers.Check if it's a directory
        const is_dir = blk: {
            const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, check_path });
            defer allocator.free(full);
            var dir = std.fs.cwd().openDir(full, .{}) catch break :blk false;
            dir.close();
            break :blk true;
        };

        // helpers.Check directory-specific gitignore first, then repo-level
        var match_result = dir_gitignore.getMatchInfo(check_path, is_dir);
        if (!match_result.matched) {
            match_result = gitignore.getMatchInfo(check_path, is_dir);
        }

        if (match_result.matched) {
            found_any = true;
            if (!quiet) {
                if (verbose) {
                    const msg = try std.fmt.allocPrint(allocator, "{s}:{d}:{s}{s}{s}{s}", .{
                        match_result.source,
                        match_result.line_number,
                        match_result.pattern,
                        sep,
                        path,
                        line_end,
                    });
                    defer allocator.free(msg);
                    try platform_impl.writeStdout(msg);
                } else {
                    const msg = try std.fmt.allocPrint(allocator, "{s}{s}", .{ path, line_end });
                    defer allocator.free(msg);
                    try platform_impl.writeStdout(msg);
                }
            }
        } else if (verbose and non_matching) {
            // helpers.Show non-matching entry
            const msg = try std.fmt.allocPrint(allocator, "::{s}{s}{s}", .{ sep, path, line_end });
            defer allocator.free(msg);
            try platform_impl.writeStdout(msg);
        }
    }

    if (!found_any) std.process.exit(1);
}
