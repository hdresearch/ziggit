// Auto-generated from main_common.zig - cmd_rev_parse
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

pub fn cmdRevParse(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    if (@import("builtin").target.os.tag == .freestanding) {
        try platform_impl.writeStderr("rev-parse: not supported in freestanding mode\n");
        return;
    }

    // helpers.Collect all args
    var all_args = std.array_list.Managed([]const u8).init(allocator);
    defer all_args.deinit();
    while (args.next()) |arg| {
        try all_args.append(arg);
    }

    if (all_args.items.len == 0) {
        // git rev-parse with no args still validates we're in a git repo
        // helpers.findGitDirectory handles invalid gitfile with exit(128)
        const gp_check = helpers.findGitDirectory(allocator, platform_impl) catch {
            try platform_impl.writeStderr("fatal: not a git repository (or any parent up to mount point /)\nStopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set).\n");
            std.process.exit(128);
        };
        allocator.free(gp_check);
        return;
    }

    // helpers.Parse flags
    var verify = false;
    var quiet = false;
    var short: ?u8 = null; // --short[=N]
    var symbolic_full_name = false;
    var abbrev_ref = false;
    var revs_only = false;
    var no_revs = false;
    var flags_only = false;
    var no_flags = false;
    var path_format_absolute = false;
    var default_rev: ?[]const u8 = null;
    var positional_args = std.array_list.Managed([]const u8).init(allocator);
    defer positional_args.deinit();

    var arg_i: usize = 0;
    while (arg_i < all_args.items.len) : (arg_i += 1) {
        const arg = all_args.items[arg_i];
        if (std.mem.eql(u8, arg, "--verify")) {
            verify = true;
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            quiet = true;
        } else if (std.mem.eql(u8, arg, "--short")) {
            short = 7;
        } else if (std.mem.startsWith(u8, arg, "--short=")) {
            short = std.fmt.parseInt(u8, arg[8..], 10) catch 7;
        } else if (std.mem.eql(u8, arg, "--symbolic-full-name")) {
            symbolic_full_name = true;
        } else if (std.mem.eql(u8, arg, "--abbrev-ref")) {
            abbrev_ref = true;
        } else if (std.mem.eql(u8, arg, "--revs-only")) {
            revs_only = true;
        } else if (std.mem.eql(u8, arg, "--no-revs")) {
            no_revs = true;
        } else if (std.mem.eql(u8, arg, "--flags")) {
            flags_only = true;
        } else if (std.mem.eql(u8, arg, "--no-flags")) {
            no_flags = true;
        } else if (std.mem.eql(u8, arg, "--sq")) {
            // Ignore for now (shell quoting)
        } else if (std.mem.eql(u8, arg, "--sq-quote")) {
            // Shell-quote remaining args
            var output_buf = std.array_list.Managed(u8).init(allocator);
            defer output_buf.deinit();
            var first = true;
            arg_i += 1;
            while (arg_i < all_args.items.len) : (arg_i += 1) {
                const a = all_args.items[arg_i];
                if (!first) try output_buf.append(' ');
                first = false;
                try output_buf.append('\'');
                for (a) |ch| {
                    if (ch == '\'') {
                        try output_buf.appendSlice("'\\''");
                    } else {
                        try output_buf.append(ch);
                    }
                }
                try output_buf.append('\'');
            }
            try output_buf.append('\n');
            try platform_impl.writeStdout(output_buf.items);
            return;
        } else if (std.mem.eql(u8, arg, "--local-env-vars")) {
            try platform_impl.writeStdout("GIT_DIR\nGIT_WORK_TREE\nGIT_OBJECT_DIRECTORY\nGIT_INDEX_FILE\nGIT_GRAFT_FILE\nGIT_COMMON_DIR\n");
            return;
        } else if (std.mem.eql(u8, arg, "--resolve-git-dir")) {
            arg_i += 1;
            if (arg_i >= all_args.items.len) {
                try platform_impl.writeStderr("fatal: --resolve-git-dir requires an argument\n");
                std.process.exit(1);
                unreachable;
            }
            const path = all_args.items[arg_i];
            // helpers.If path is a file, read its contents (gitfile)
            const content = platform_impl.fs.readFile(allocator, path) catch {
                // helpers.Check if path is a directory with helpers.HEAD
                const head_path = std.fmt.allocPrint(allocator, "{s}/HEAD", .{path}) catch {
                    std.process.exit(1);
                    unreachable;
                };
                defer allocator.free(head_path);
                _ = std.fs.cwd().statFile(head_path) catch {
                    try platform_impl.writeStderr("fatal: not a gitdir '");
                    try platform_impl.writeStderr(path);
                    try platform_impl.writeStderr("'\n");
                    std.process.exit(1);
                    unreachable;
                };
                const output = try std.fmt.allocPrint(allocator, "{s}\n", .{path});
                defer allocator.free(output);
                try platform_impl.writeStdout(output);
                return;
            };
            defer allocator.free(content);
            const trimmed = std.mem.trim(u8, content, " \t\r\n");
            if (std.mem.startsWith(u8, trimmed, "gitdir: ")) {
                const gitdir = trimmed["gitdir: ".len..];
                // helpers.Resolve relative to the directory containing the gitfile
                if (std.fs.path.isAbsolute(gitdir)) {
                    const output = try std.fmt.allocPrint(allocator, "{s}\n", .{gitdir});
                    defer allocator.free(output);
                    try platform_impl.writeStdout(output);
                } else {
                    const dir = std.fs.path.dirname(path) orelse ".";
                    const resolved = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, gitdir });
                    defer allocator.free(resolved);
                    // helpers.Normalize the path
                    var real_buf: [4096]u8 = undefined;
                    const real = std.fs.cwd().realpath(resolved, &real_buf) catch {
                        const output = try std.fmt.allocPrint(allocator, "{s}\n", .{resolved});
                        defer allocator.free(output);
                        try platform_impl.writeStdout(output);
                        return;
                    };
                    const output = try std.fmt.allocPrint(allocator, "{s}\n", .{real});
                    defer allocator.free(output);
                    try platform_impl.writeStdout(output);
                }
            } else {
                try platform_impl.writeStderr("fatal: not a gitdir '");
                try platform_impl.writeStderr(path);
                try platform_impl.writeStderr("'\n");
                std.process.exit(1);
                unreachable;
            }
            return;
        } else if (std.mem.eql(u8, arg, "--path-format=absolute")) {
            path_format_absolute = true;
        } else if (std.mem.eql(u8, arg, "--path-format=relative")) {
            path_format_absolute = false;
        } else if (std.mem.eql(u8, arg, "--path-format")) {
            try platform_impl.writeStderr("fatal: --path-format requires a value\n");
            std.process.exit(129);
        } else if (std.mem.eql(u8, arg, "--default")) {
            arg_i += 1;
            if (arg_i < all_args.items.len) {
                default_rev = all_args.items[arg_i];
            }
        } else if (std.mem.startsWith(u8, arg, "--default=")) {
            default_rev = arg["--default=".len..];
        } else if (std.mem.eql(u8, arg, "--git-path")) {
            // --git-path <path> - resolve path relative to GIT_DIR
            arg_i += 1;
            if (arg_i >= all_args.items.len) {
                try platform_impl.writeStderr("fatal: --git-path requires an argument\n");
                std.process.exit(1);
            }
            const path_arg = all_args.items[arg_i];
            const resolved = try resolveGitPath(allocator, path_arg, platform_impl);
            defer allocator.free(resolved);
            const out = try std.fmt.allocPrint(allocator, "{s}\n", .{resolved});
            defer allocator.free(out);
            try platform_impl.writeStdout(out);
        } else if (std.mem.startsWith(u8, arg, "--since=") or std.mem.startsWith(u8, arg, "--after=")) {
            const date_str = if (std.mem.startsWith(u8, arg, "--since=")) arg["--since=".len..] else arg["--after=".len..];
            const ts = parseDateStr(date_str, allocator);
            const out = try std.fmt.allocPrint(allocator, "--max-age={d}\n", .{ts});
            defer allocator.free(out);
            try platform_impl.writeStdout(out);
        } else if (std.mem.startsWith(u8, arg, "--until=") or std.mem.startsWith(u8, arg, "--before=")) {
            const date_str = if (std.mem.startsWith(u8, arg, "--until=")) arg["--until=".len..] else arg["--before=".len..];
            const ts = parseDateStr(date_str, allocator);
            const out = try std.fmt.allocPrint(allocator, "--min-age={d}\n", .{ts});
            defer allocator.free(out);
            try platform_impl.writeStdout(out);
        } else {
            try positional_args.append(arg);
        }
    }

    // helpers.Handle info queries that don't need helpers.refs resolution
    for (positional_args.items) |arg| {
        if (std.mem.eql(u8, arg, "--show-toplevel")) {
            const git_path = helpers.findGitDirectory(allocator, platform_impl) catch {
                try platform_impl.writeStderr("fatal: not a git repository (or any parent up to mount point /)\nStopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set).\n");
                std.process.exit(128);
            };
            defer allocator.free(git_path);
            // Check if cwd is inside the .git directory
            {
                const cwd_check = try platform_impl.fs.getCwd(allocator);
                defer allocator.free(cwd_check);
                const real_git = std.fs.cwd().realpathAlloc(allocator, git_path) catch try allocator.dupe(u8, git_path);
                defer allocator.free(real_git);
                const real_cwd = std.fs.cwd().realpathAlloc(allocator, cwd_check) catch try allocator.dupe(u8, cwd_check);
                defer allocator.free(real_cwd);
                if (std.mem.eql(u8, real_cwd, real_git) or (std.mem.startsWith(u8, real_cwd, real_git) and real_cwd.len > real_git.len and real_cwd[real_git.len] == '/')) {
                    try platform_impl.writeStderr("fatal: this operation must be run in a work tree\n");
                    std.process.exit(128);
                }
            }
            // helpers.Check if this is a bare repo
            const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{git_path});
            defer allocator.free(config_path);
            if (platform_impl.fs.readFile(allocator, config_path)) |cfg| {
                defer allocator.free(cfg);
                if (std.mem.indexOf(u8, cfg, "bare = true") != null) {
                    try platform_impl.writeStderr("fatal: this operation must be run in a work tree\n");
                    std.process.exit(128);
                }
            } else |_| {}
            const repo_root = std.fs.path.dirname(git_path) orelse git_path;
            const output = try std.fmt.allocPrint(allocator, "{s}\n", .{repo_root});
            defer allocator.free(output);
            try platform_impl.writeStdout(output);
            continue;
        } else if (std.mem.eql(u8, arg, "--git-dir")) {
            const git_path = helpers.findGitDirectory(allocator, platform_impl) catch {
                try platform_impl.writeStderr("fatal: not a git repository (or any parent up to mount point /)\nStopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set).\n");
                std.process.exit(128);
            };
            defer allocator.free(git_path);
            // helpers.GIT_DIR env: output (convert to absolute if needed)
            if (std.posix.getenv("GIT_DIR")) |gd| {
                if (path_format_absolute and !std.fs.path.isAbsolute(gd)) {
                    const abs_gd = std.fs.cwd().realpathAlloc(allocator, gd) catch try allocator.dupe(u8, gd);
                    defer allocator.free(abs_gd);
                    const gd_out = try std.fmt.allocPrint(allocator, "{s}\n", .{abs_gd});
                    defer allocator.free(gd_out);
                    try platform_impl.writeStdout(gd_out);
                } else {
                    const gd_out = try std.fmt.allocPrint(allocator, "{s}\n", .{gd});
                    defer allocator.free(gd_out);
                    try platform_impl.writeStdout(gd_out);
                }
                continue;
            }
            // Gitdir link target (absolute, not standard .git): output as-is
            if (std.fs.path.isAbsolute(git_path) and !std.mem.endsWith(u8, git_path, "/.git")) {
                const gd_out = try std.fmt.allocPrint(allocator, "{s}\n", .{git_path});
                defer allocator.free(gd_out);
                try platform_impl.writeStdout(gd_out);
                continue;
            }
            if (path_format_absolute) {
                // helpers.Always output absolute path
                const abs = std.fs.cwd().realpathAlloc(allocator, git_path) catch try allocator.dupe(u8, git_path);
                defer allocator.free(abs);
                const output = try std.fmt.allocPrint(allocator, "{s}\n", .{abs});
                defer allocator.free(output);
                try platform_impl.writeStdout(output);
            } else {
                const cwd = try platform_impl.fs.getCwd(allocator);
                defer allocator.free(cwd);
                const real_git = std.fs.cwd().realpathAlloc(allocator, git_path) catch try allocator.dupe(u8, git_path);
                defer allocator.free(real_git);
                const real_cwd = std.fs.cwd().realpathAlloc(allocator, cwd) catch try allocator.dupe(u8, cwd);
                defer allocator.free(real_cwd);
                
                // helpers.If CWD helpers.IS the git dir, output "."
                if (std.mem.eql(u8, real_cwd, real_git)) {
                    try platform_impl.writeStdout(".\n");
                } else if (std.mem.startsWith(u8, real_cwd, real_git) and real_cwd.len > real_git.len and real_cwd[real_git.len] == '/') {
                    // Inside git dir - output absolute path to git dir
                    const output = try std.fmt.allocPrint(allocator, "{s}\n", .{real_git});
                    defer allocator.free(output);
                    try platform_impl.writeStdout(output);
                } else if (std.mem.startsWith(u8, real_git, real_cwd) and real_git.len > real_cwd.len and real_git[real_cwd.len] == '/') {
                    // helpers.Git dir is a subdirectory of CWD - output relative path
                    const rel = real_git[real_cwd.len + 1..];
                    const output = try std.fmt.allocPrint(allocator, "{s}\n", .{rel});
                    defer allocator.free(output);
                    try platform_impl.writeStdout(output);
                } else {
                    // helpers.Output absolute path
                    const output = try std.fmt.allocPrint(allocator, "{s}\n", .{real_git});
                    defer allocator.free(output);
                    try platform_impl.writeStdout(output);
                }
            }
            continue;
        } else if (std.mem.eql(u8, arg, "--git-common-dir")) {
            const git_path = helpers.findGitDirectory(allocator, platform_impl) catch {
                try platform_impl.writeStderr("fatal: not a git repository (or any parent up to mount point /)\nStopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set).\n");
                std.process.exit(128);
            };
            defer allocator.free(git_path);
            if (path_format_absolute) {
                // Always output absolute path
                const abs = std.fs.cwd().realpathAlloc(allocator, git_path) catch try allocator.dupe(u8, git_path);
                defer allocator.free(abs);
                const output = try std.fmt.allocPrint(allocator, "{s}\n", .{abs});
                defer allocator.free(output);
                try platform_impl.writeStdout(output);
            } else {
                const cwd = try platform_impl.fs.getCwd(allocator);
                defer allocator.free(cwd);
                if (std.mem.startsWith(u8, git_path, cwd) and git_path.len > cwd.len) {
                    const rel = git_path[cwd.len..];
                    const trimmed = if (rel.len > 0 and rel[0] == '/') rel[1..] else rel;
                    if (trimmed.len > 0) {
                        const output = try std.fmt.allocPrint(allocator, "{s}\n", .{trimmed});
                        defer allocator.free(output);
                        try platform_impl.writeStdout(output);
                    } else {
                        try platform_impl.writeStdout(".git\n");
                    }
                } else {
                    const output = try std.fmt.allocPrint(allocator, "{s}\n", .{git_path});
                    defer allocator.free(output);
                    try platform_impl.writeStdout(output);
                }
            }
            continue;
        } else if (std.mem.eql(u8, arg, "--is-inside-work-tree")) {
            const git_path = helpers.findGitDirectory(allocator, platform_impl) catch {
                try platform_impl.writeStdout("false\n");
                continue;
            };
            defer allocator.free(git_path);
            // helpers.Check bare
            const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{git_path});
            defer allocator.free(config_path);
            if (platform_impl.fs.readFile(allocator, config_path)) |cfg| {
                defer allocator.free(cfg);
                if (std.mem.indexOf(u8, cfg, "bare = true") != null) {
                    try platform_impl.writeStdout("false\n");
                    continue;
                }
            } else |_| {}
            // Check if we're inside the git dir (then we're NOT in work tree)
            const cwd_wt = try platform_impl.fs.getCwd(allocator);
            defer allocator.free(cwd_wt);
            const real_git_wt = std.fs.cwd().realpathAlloc(allocator, git_path) catch try allocator.dupe(u8, git_path);
            defer allocator.free(real_git_wt);
            const real_cwd_wt = std.fs.cwd().realpathAlloc(allocator, cwd_wt) catch try allocator.dupe(u8, cwd_wt);
            defer allocator.free(real_cwd_wt);
            if (std.mem.eql(u8, real_cwd_wt, real_git_wt) or
                (std.mem.startsWith(u8, real_cwd_wt, real_git_wt) and real_cwd_wt.len > real_git_wt.len and real_cwd_wt[real_git_wt.len] == '/'))
            {
                try platform_impl.writeStdout("false\n");
                continue;
            }
            try platform_impl.writeStdout("true\n");
            continue;
        } else if (std.mem.eql(u8, arg, "--is-inside-git-dir")) {
            // helpers.Check if cwd is inside the .git directory
            const git_path = helpers.findGitDirectory(allocator, platform_impl) catch {
                try platform_impl.writeStdout("false\n");
                continue;
            };
            defer allocator.free(git_path);
            const cwd = try platform_impl.fs.getCwd(allocator);
            defer allocator.free(cwd);
            // helpers.Resolve git_path to real path for comparison
            const real_git = std.fs.cwd().realpathAlloc(allocator, git_path) catch git_path;
            const should_free_real_git = real_git.ptr != git_path.ptr;
            defer if (should_free_real_git) allocator.free(real_git);
            const real_cwd = std.fs.cwd().realpathAlloc(allocator, cwd) catch cwd;
            const should_free_real_cwd = real_cwd.ptr != cwd.ptr;
            defer if (should_free_real_cwd) allocator.free(real_cwd);
            if (std.mem.eql(u8, real_cwd, real_git) or std.mem.startsWith(u8, real_cwd, real_git) and real_cwd.len > real_git.len and real_cwd[real_git.len] == '/') {
                try platform_impl.writeStdout("true\n");
            } else {
                try platform_impl.writeStdout("false\n");
            }
            continue;
        } else if (std.mem.eql(u8, arg, "--is-bare-repository")) {
            const git_path = helpers.findGitDirectory(allocator, platform_impl) catch {
                try platform_impl.writeStdout("false\n");
                continue;
            };
            defer allocator.free(git_path);
            const config_path = try std.fmt.allocPrint(allocator, "{s}/config", .{git_path});
            defer allocator.free(config_path);
            if (platform_impl.fs.readFile(allocator, config_path)) |cfg| {
                defer allocator.free(cfg);
                if (std.mem.indexOf(u8, cfg, "bare = true") != null) {
                    try platform_impl.writeStdout("true\n");
                    continue;
                }
            } else |_| {}
            try platform_impl.writeStdout("false\n");
            continue;
        } else if (std.mem.eql(u8, arg, "--show-cdup")) {
            const git_path = helpers.findGitDirectory(allocator, platform_impl) catch {
                try platform_impl.writeStderr("fatal: not a git repository\n");
                std.process.exit(128);
            };
            defer allocator.free(git_path);
            const repo_root = std.fs.path.dirname(git_path) orelse git_path;
            const cwd = try platform_impl.fs.getCwd(allocator);
            defer allocator.free(cwd);
            if (std.mem.eql(u8, cwd, repo_root)) {
                try platform_impl.writeStdout("\n");
            } else if (std.mem.startsWith(u8, cwd, repo_root)) {
                const rel = cwd[repo_root.len + 1 ..];
                var depth: usize = 1;
                for (rel) |c| {
                    if (c == '/') depth += 1;
                }
                var buf = std.array_list.Managed(u8).init(allocator);
                defer buf.deinit();
                var d: usize = 0;
                while (d < depth) : (d += 1) {
                    try buf.appendSlice("../");
                }
                try buf.append('\n');
                try platform_impl.writeStdout(buf.items);
            } else {
                try platform_impl.writeStdout("\n");
            }
            continue;
        } else if (std.mem.eql(u8, arg, "--show-prefix")) {
            const git_path = helpers.findGitDirectory(allocator, platform_impl) catch {
                try platform_impl.writeStderr("fatal: not a git repository\n");
                std.process.exit(128);
            };
            defer allocator.free(git_path);
            const real_git = std.fs.cwd().realpathAlloc(allocator, git_path) catch try allocator.dupe(u8, git_path);
            defer allocator.free(real_git);
            const cwd = try platform_impl.fs.getCwd(allocator);
            defer allocator.free(cwd);
            const real_cwd = std.fs.cwd().realpathAlloc(allocator, cwd) catch try allocator.dupe(u8, cwd);
            defer allocator.free(real_cwd);
            // If inside git dir, output empty
            if (std.mem.eql(u8, real_cwd, real_git) or
                (std.mem.startsWith(u8, real_cwd, real_git) and real_cwd.len > real_git.len and real_cwd[real_git.len] == '/'))
            {
                try platform_impl.writeStdout("\n");
                continue;
            }
            // When GIT_DIR is explicitly set, the working tree root is CWD
            // (unless GIT_WORK_TREE is also set)
            const repo_root = if (std.posix.getenv("GIT_DIR") != null and std.posix.getenv("GIT_WORK_TREE") == null)
                real_cwd
            else
                std.fs.path.dirname(real_git) orelse real_git;
            if (std.mem.eql(u8, real_cwd, repo_root)) {
                try platform_impl.writeStdout("\n");
            } else if (std.mem.startsWith(u8, real_cwd, repo_root) and real_cwd.len > repo_root.len and real_cwd[repo_root.len] == '/') {
                const prefix = real_cwd[repo_root.len + 1 ..];
                const output = try std.fmt.allocPrint(allocator, "{s}/\n", .{prefix});
                defer allocator.free(output);
                try platform_impl.writeStdout(output);
            } else {
                try platform_impl.writeStdout("\n");
            }
            continue;
        } else if (std.mem.eql(u8, arg, "--absolute-git-dir")) {
            const git_path = helpers.findGitDirectory(allocator, platform_impl) catch {
                try platform_impl.writeStderr("fatal: not a git repository\n");
                std.process.exit(128);
            };
            defer allocator.free(git_path);
            const output = try std.fmt.allocPrint(allocator, "{s}\n", .{git_path});
            defer allocator.free(output);
            try platform_impl.writeStdout(output);
            continue;
        } else if (std.mem.eql(u8, arg, "--show-object-format") or
            std.mem.eql(u8, arg, "--show-object-format=storage") or
            std.mem.eql(u8, arg, "--show-object-format=input") or
            std.mem.eql(u8, arg, "--show-object-format=output"))
        {
            try platform_impl.writeStdout("sha1\n");
            continue;
        } else if (std.mem.startsWith(u8, arg, "--show-object-format=")) {
            const mode = arg["--show-object-format=".len..];
            const msg = try std.fmt.allocPrint(allocator, "fatal: unknown mode for --show-object-format: {s}\n", .{mode});
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(1);
        } else if (std.mem.eql(u8, arg, "--show-ref-format")) {
            try platform_impl.writeStdout("files\n");
            continue;
        } else if (std.mem.eql(u8, arg, "--is-shallow-repository")) {
            // helpers.Check for shallow file
            if (helpers.findGitDirectory(allocator, platform_impl) catch null) |gp_shallow| {
                defer allocator.free(gp_shallow);
                const shallow_path = try std.fmt.allocPrint(allocator, "{s}/shallow", .{gp_shallow});
                defer allocator.free(shallow_path);
                if (platform_impl.fs.exists(shallow_path) catch false) {
                    try platform_impl.writeStdout("true\n");
                } else {
                    try platform_impl.writeStdout("false\n");
                }
            } else {
                try platform_impl.writeStdout("false\n");
            }
            continue;
        }
    }

    // helpers.If verify mode with no positional args that look like revisions
    if (verify) {
        // --verify expects exactly one revision argument
        var rev_arg: ?[]const u8 = null;
        for (positional_args.items) |arg| {
            if (std.mem.startsWith(u8, arg, "--")) continue;
            if (rev_arg != null) {
                if (!quiet) {
                    try platform_impl.writeStderr("fatal: Needed a single revision\n");
                }
                std.process.exit(128);
            }
            rev_arg = arg;
        }
        if (rev_arg == null) {
            if (default_rev) |def| {
                rev_arg = def;
            } else {
                if (!quiet) {
                    try platform_impl.writeStderr("fatal: Needed a single revision\n");
                }
                std.process.exit(128);
            }
        }

        const git_path = helpers.findGitDirectory(allocator, platform_impl) catch {
            if (!quiet) {
                try platform_impl.writeStderr("fatal: not a git repository (or any parent up to mount point /)\nStopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set).\n");
            }
            std.process.exit(128);
        };
        defer allocator.free(git_path);

        const hash = helpers.resolveRevision(git_path, rev_arg.?, platform_impl, allocator) catch {
            if (!quiet) {
                try platform_impl.writeStderr("fatal: Needed a single revision\n");
            }
            std.process.exit(128);
        };
        defer allocator.free(hash);

        if (short) |n| {
            const s = if (n > 40) @as(u8, 40) else n;
            const out = try std.fmt.allocPrint(allocator, "{s}\n", .{hash[0..s]});
            defer allocator.free(out);
            try platform_impl.writeStdout(out);
        } else {
            const out = try std.fmt.allocPrint(allocator, "{s}\n", .{hash});
            defer allocator.free(out);
            try platform_impl.writeStdout(out);
        }
        return;
    }

    // Non-verify mode: process each positional arg
    const git_path = helpers.findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any parent up to mount point /)\nStopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set).\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);

    // Apply --default if no rev-like positional args were given
    if (default_rev) |def| {
        var has_rev_arg = false;
        for (positional_args.items) |arg| {
            if (!std.mem.startsWith(u8, arg, "--")) {
                has_rev_arg = true;
                break;
            }
        }
        if (!has_rev_arg) {
            try positional_args.append(def);
        }
    }

    for (positional_args.items) |arg| {
        // helpers.Skip flags already processed
        if (std.mem.startsWith(u8, arg, "--")) {
            if (!revs_only and !no_flags) {
                // helpers.Output non-rev flags
                if (flags_only or no_revs) {
                    const out = try std.fmt.allocPrint(allocator, "{s}\n", .{arg});
                    defer allocator.free(out);
                    try platform_impl.writeStdout(out);
                }
            }
            continue;
        }

        if (no_revs) continue; // helpers.Skip revision args

        // helpers.Handle --symbolic-full-name for helpers.HEAD
        if (symbolic_full_name) {
            if (std.mem.eql(u8, arg, "HEAD")) {
                const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_path});
                defer allocator.free(head_path);
                if (platform_impl.fs.readFile(allocator, head_path)) |content| {
                    defer allocator.free(content);
                    const trimmed = std.mem.trim(u8, content, " \t\n\r");
                    if (std.mem.startsWith(u8, trimmed, "ref: ")) {
                        const out = try std.fmt.allocPrint(allocator, "{s}\n", .{trimmed[5..]});
                        defer allocator.free(out);
                        try platform_impl.writeStdout(out);
                        continue;
                    }
                } else |_| {}
            }
        }

        // helpers.Handle --abbrev-ref
        if (abbrev_ref) {
            if (std.mem.eql(u8, arg, "HEAD")) {
                const head_path = try std.fmt.allocPrint(allocator, "{s}/HEAD", .{git_path});
                defer allocator.free(head_path);
                if (platform_impl.fs.readFile(allocator, head_path)) |content| {
                    defer allocator.free(content);
                    const trimmed = std.mem.trim(u8, content, " \t\n\r");
                    if (std.mem.startsWith(u8, trimmed, "ref: refs/heads/")) {
                        const branch = trimmed["ref: refs/heads/".len..];
                        const out = try std.fmt.allocPrint(allocator, "{s}\n", .{branch});
                        defer allocator.free(out);
                        try platform_impl.writeStdout(out);
                        continue;
                    } else if (std.mem.startsWith(u8, trimmed, "ref: ")) {
                        const out = try std.fmt.allocPrint(allocator, "{s}\n", .{trimmed[5..]});
                        defer allocator.free(out);
                        try platform_impl.writeStdout(out);
                        continue;
                    } else {
                        try platform_impl.writeStdout("HEAD\n");
                        continue;
                    }
                } else |_| {}
            }
        }

        // helpers.Handle ^@ (all parents)
        if (std.mem.endsWith(u8, arg, "^@")) {
            const brev1 = arg[0 .. arg.len - 2];
            if (helpers.resolveRevision(git_path, brev1, platform_impl, allocator)) |bh1| {
                defer allocator.free(bh1);
                const obj1 = objects.GitObject.load(bh1, git_path, platform_impl, allocator) catch {
                    const e1 = try std.fmt.allocPrint(allocator, "fatal: bad revision '{s}'\n", .{arg});
                    defer allocator.free(e1);
                    try platform_impl.writeStderr(e1);
                    std.process.exit(128);
                };
                defer obj1.deinit(allocator);
                if (obj1.type != .commit) {
                    const e2 = try std.fmt.allocPrint(allocator, "fatal: bad revision '{s}'\n", .{arg});
                    defer allocator.free(e2);
                    try platform_impl.writeStderr(e2);
                    std.process.exit(128);
                }
                var lns1 = std.mem.splitSequence(u8, obj1.data, "\n");
                while (lns1.next()) |ln1| {
                    if (ln1.len == 0) break;
                    if (std.mem.startsWith(u8, ln1, "parent ")) {
                        const p1 = ln1["parent ".len..];
                        const o1 = try std.fmt.allocPrint(allocator, "{s}\n", .{p1});
                        defer allocator.free(o1);
                        try platform_impl.writeStdout(o1);
                    }
                }
                continue;
            } else |_| {}
        }
        // helpers.Handle ^! (commit excluding parents)
        if (std.mem.endsWith(u8, arg, "^!")) {
            const brev2 = arg[0 .. arg.len - 2];
            if (helpers.resolveRevision(git_path, brev2, platform_impl, allocator)) |bh2| {
                defer allocator.free(bh2);
                const o2a = try std.fmt.allocPrint(allocator, "{s}\n", .{bh2});
                defer allocator.free(o2a);
                try platform_impl.writeStdout(o2a);
                const obj2 = objects.GitObject.load(bh2, git_path, platform_impl, allocator) catch continue;
                defer obj2.deinit(allocator);
                if (obj2.type == .commit) {
                    var lns2 = std.mem.splitSequence(u8, obj2.data, "\n");
                    while (lns2.next()) |ln2| {
                        if (ln2.len == 0) break;
                        if (std.mem.startsWith(u8, ln2, "parent ")) {
                            const p2 = ln2["parent ".len..];
                            const o2b = try std.fmt.allocPrint(allocator, "^{s}\n", .{p2});
                            defer allocator.free(o2b);
                            try platform_impl.writeStdout(o2b);
                        }
                    }
                }
                continue;
            } else |_| {}
        }
        // helpers.Handle ^-N (parent range shorthand)
        if (std.mem.indexOf(u8, arg, "^-")) |cdp1| {
            const brev3 = arg[0..cdp1];
            const dsuf1 = arg[cdp1 + 2 ..];
            const dn1: u32 = if (dsuf1.len == 0) 1 else std.fmt.parseInt(u32, dsuf1, 10) catch 0;
            if (dn1 == 0) {
                const e3 = try std.fmt.allocPrint(allocator, "fatal: bad revision '{s}'\n", .{arg});
                defer allocator.free(e3);
                try platform_impl.writeStderr(e3);
                std.process.exit(128);
            }
            if (helpers.resolveRevision(git_path, brev3, platform_impl, allocator)) |bh3| {
                defer allocator.free(bh3);
                const ps1 = try std.fmt.allocPrint(allocator, "{s}^{d}", .{ brev3, dn1 });
                defer allocator.free(ps1);
                if (helpers.resolveRevision(git_path, ps1, platform_impl, allocator)) |ph3| {
                    defer allocator.free(ph3);
                    if (symbolic_full_name) {
                        const n1 = try std.fmt.allocPrint(allocator, "^{s}^{d}\n", .{ brev3, dn1 });
                        defer allocator.free(n1);
                        try platform_impl.writeStdout(n1);
                        const p3 = try std.fmt.allocPrint(allocator, "{s}\n", .{brev3});
                        defer allocator.free(p3);
                        try platform_impl.writeStdout(p3);
                    } else {
                        const n2 = try std.fmt.allocPrint(allocator, "^{s}\n", .{ph3});
                        defer allocator.free(n2);
                        try platform_impl.writeStdout(n2);
                        const p4 = try std.fmt.allocPrint(allocator, "{s}\n", .{bh3});
                        defer allocator.free(p4);
                        try platform_impl.writeStdout(p4);
                    }
                    continue;
                } else |_| {}
            } else |_| {}
        }
        // helpers.Handle ^<rev> negation prefix
        if (arg.len > 1 and arg[0] == '^' and arg[1] != '{' and arg[1] != '-' and arg[1] != '@' and arg[1] != '!') {
            const nrev1 = arg[1..];
            if (helpers.resolveRevision(git_path, nrev1, platform_impl, allocator)) |nh1| {
                defer allocator.free(nh1);
                const no1 = try std.fmt.allocPrint(allocator, "^{s}\n", .{nh1});
                defer allocator.free(no1);
                try platform_impl.writeStdout(no1);
                continue;
            } else |_| {}
        }

        // helpers.Try to resolve as revision
        if (helpers.resolveRevision(git_path, arg, platform_impl, allocator)) |hash| {
            defer allocator.free(hash);
            if (short) |n| {
                const s = if (n > 40) @as(u8, 40) else n;
                const out = try std.fmt.allocPrint(allocator, "{s}\n", .{hash[0..s]});
                defer allocator.free(out);
                try platform_impl.writeStdout(out);
            } else {
                const out = try std.fmt.allocPrint(allocator, "{s}\n", .{hash});
                defer allocator.free(out);
                try platform_impl.writeStdout(out);
            }
        } else |_| {
            // helpers.For --short mode with a valid hex string, just truncate (like real git)
            if (short != null and arg.len == 40 and helpers.isValidHexString(arg)) {
                const n = short.?;
                const s = if (n > 40) @as(u8, 40) else n;
                const out = try std.fmt.allocPrint(allocator, "{s}\n", .{arg[0..s]});
                defer allocator.free(out);
                try platform_impl.writeStdout(out);
            } else {
                if (!quiet) {
                    const msg = try std.fmt.allocPrint(allocator, "fatal: ambiguous argument '{s}': unknown revision or path not in the working tree.\nUse '--' to separate paths from revisions, like this:\n'git <command> [<revision>...] -- [<file>...]'\n", .{arg});
                    defer allocator.free(msg);
                    try platform_impl.writeStderr(msg);
                }
                std.process.exit(128);
            }
        }
    }
}

/// Resolve a path for --git-path, handling env var overrides and common dir.
fn resolveGitPath(allocator: std.mem.Allocator, path: []const u8, _: *const platform_mod.Platform) ![]u8 {
    // Use GIT_DIR env or default to .git (relative)
    const git_dir = if (std.posix.getenv("GIT_DIR")) |gd| gd else ".git";

    // Normalize path - collapse multiple slashes for matching purposes
    const norm_path = try normalizePath(allocator, path);
    defer allocator.free(norm_path);

    // Check env var overrides first
    // GIT_INDEX_FILE overrides "index"
    if (std.posix.getenv("GIT_INDEX_FILE")) |idx_file| {
        if (std.mem.eql(u8, norm_path, "index")) {
            return try allocator.dupe(u8, idx_file);
        }
    }

    // GIT_GRAFT_FILE overrides "info/grafts"
    if (std.posix.getenv("GIT_GRAFT_FILE")) |graft_file| {
        if (std.mem.eql(u8, norm_path, "info/grafts")) {
            return try allocator.dupe(u8, graft_file);
        }
    }

    // GIT_OBJECT_DIRECTORY overrides "objects" and "objects/*"
    if (std.posix.getenv("GIT_OBJECT_DIRECTORY")) |obj_dir| {
        if (std.mem.eql(u8, norm_path, "objects")) {
            return try allocator.dupe(u8, obj_dir);
        }
        if (std.mem.startsWith(u8, norm_path, "objects/")) {
            return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ obj_dir, norm_path["objects/".len..] });
        }
    }

    // GIT_COMMON_DIR handling
    if (std.posix.getenv("GIT_COMMON_DIR")) |common_dir| {
        // These paths stay in .git (repo-specific, NOT shared):
        if (isRepoSpecificPath(path)) {
            return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_dir, path });
        }
        // Everything else goes to common dir
        return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ common_dir, path });
    }

    // Default: relative to git_dir
    return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ git_dir, path });
}

/// Check if a path is repo-specific (stays in .git, not shared to common dir)
fn isRepoSpecificPath(path: []const u8) bool {
    // Normalize for matching
    const norm = std.mem.trim(u8, path, "/");

    // Exact matches
    const exact_private = [_][]const u8{
        "HEAD", "index", "index.lock",
        "MERGE_HEAD", "MERGE_MSG", "MERGE_RR", "MERGE_MODE",
        "FETCH_HEAD", "ORIG_HEAD", "CHERRY_PICK_HEAD",
        "REVERT_HEAD", "BISECT_LOG", "AUTO_MERGE",
        "BISECT_EXPECTED_REV", "BISECT_ANCESTORS_OK",
        "BISECT_NAMES", "BISECT_RUN", "BISECT_START",
        "BISECT_TERMS",
    };
    for (exact_private) |p| {
        if (std.mem.eql(u8, norm, p)) return true;
    }

    // Prefix matches (paths that start with these are repo-specific)
    // logs/HEAD and logs/HEAD.lock are private, but logs/refs is shared
    if (std.mem.eql(u8, norm, "logs/HEAD") or std.mem.startsWith(u8, norm, "logs/HEAD.")) return true;

    // refs/bisect/* is private
    if (std.mem.startsWith(u8, norm, "refs/bisect/") or std.mem.eql(u8, norm, "refs/bisect")) return true;
    // logs/refs/bisect/* is private
    if (std.mem.startsWith(u8, norm, "logs/refs/bisect/") or std.mem.eql(u8, norm, "logs/refs/bisect")) return true;

    // info/sparse-checkout is private
    if (isInfoSparseCheckout(path)) return true;

    // worktrees/ is private
    if (std.mem.startsWith(u8, norm, "worktrees/") or std.mem.eql(u8, norm, "worktrees")) return true;

    return false;
}

/// Check if path is info/sparse-checkout (with possible multiple slashes)
fn isInfoSparseCheckout(path: []const u8) bool {
    // Match "info/sparse-checkout" or "info//sparse-checkout" etc.
    if (std.mem.startsWith(u8, path, "info/")) {
        const rest = path["info/".len..];
        // Skip extra slashes
        var i: usize = 0;
        while (i < rest.len and rest[i] == '/') i += 1;
        if (std.mem.eql(u8, rest[i..], "sparse-checkout")) return true;
    }
    return false;
}

/// Normalize a path by collapsing multiple slashes
fn normalizePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var result = std.array_list.Managed(u8).init(allocator);
    var prev_slash = false;
    for (path) |c| {
        if (c == '/') {
            if (!prev_slash) try result.append(c);
            prev_slash = true;
        } else {
            try result.append(c);
            prev_slash = false;
        }
    }
    return result.toOwnedSlice();
}

/// Parse a date string to a Unix timestamp
fn parseDateStr(date_str: []const u8, allocator: std.mem.Allocator) i64 {
    // Try parseDateToGitFormat which returns "timestamp tz" format
    const parsed = helpers.parseDateToGitFormat(date_str, allocator) catch return 0;
    defer allocator.free(parsed);
    // Extract timestamp (before space)
    if (std.mem.indexOfScalar(u8, parsed, ' ')) |sp| {
        return std.fmt.parseInt(i64, parsed[0..sp], 10) catch 0;
    }
    return std.fmt.parseInt(i64, parsed, 10) catch 0;
}
