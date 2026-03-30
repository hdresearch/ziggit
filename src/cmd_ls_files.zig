// Auto-generated from main_common.zig - cmd_ls_files
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

pub fn cmdLsFiles(allocator: std.mem.Allocator, args: *platform_mod.ArgIterator, platform_impl: *const platform_mod.Platform) !void {
    if (@import("builtin").target.os.tag == .freestanding) {
        try platform_impl.writeStderr("ls-files: not supported in freestanding mode\n");
        return;
    }

    var cached = false;
    var deleted = false;
    var modified_flag = false;
    var others = false;
    var stage = false;
    var unmerged_flag = false;
    var directory = false;
    var no_empty_directory = false;
    var error_unmatch = false;
    var ignored_flag = false;
    var exclude_standard = false;
    var format_str: ?[]const u8 = null;
    var z_terminator = false;
    var killed_flag = false;
    var tag_flag = false;
    var verbose_flag = false;
    var resolve_undo_flag = false;
    var deduplicate_flag = false;
    var eol_flag = false;
    var exclude_patterns = std.ArrayList([]const u8).init(allocator);
    defer exclude_patterns.deinit();
    var exclude_files = std.ArrayList([]const u8).init(allocator);
    defer exclude_files.deinit();
    var pathspecs = std.ArrayList([]const u8).init(allocator);
    defer pathspecs.deinit();

    const ls_files_usage = "usage: git ls-files [<options>] [<file>...]\n\n    -z                  paths are separated with helpers.NUL character\n    -c, --cached        show cached files in the output (default)\n    -d, --deleted       show deleted files in the output\n    -m, --modified      show modified files in the output\n    -o, --others        show other files in the output\n    -s, --stage         show staged contents' object name in the output\n    --directory         show 'other' directories' names only\n    --no-empty-directory  don't show empty directories\n    --error-unmatch     if any <file> is not in the index, treat this as an error\n    -x, --exclude <pattern>  skip files matching pattern\n    -X, --exclude-from <file>  read exclude patterns from <file>\n    --exclude-standard  add the standard git exclusions\n\n";

    // helpers.Parse arguments
    var after_dd = false;
    while (args.next()) |arg| {
        if (after_dd) {
            try pathspecs.append(arg);
        } else if (std.mem.eql(u8, arg, "--")) {
            after_dd = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try platform_impl.writeStdout(ls_files_usage);
            std.process.exit(129);
        } else if (std.mem.eql(u8, arg, "--cached") or std.mem.eql(u8, arg, "-c")) {
            cached = true;
        } else if (std.mem.eql(u8, arg, "--deleted") or std.mem.eql(u8, arg, "-d")) {
            deleted = true;
        } else if (std.mem.eql(u8, arg, "--modified") or std.mem.eql(u8, arg, "-m")) {
            modified_flag = true;
        } else if (std.mem.eql(u8, arg, "--others") or std.mem.eql(u8, arg, "-o")) {
            others = true;
        } else if (std.mem.eql(u8, arg, "--stage") or std.mem.eql(u8, arg, "-s")) {
            stage = true;
        } else if (std.mem.eql(u8, arg, "--directory")) {
            directory = true;
        } else if (std.mem.eql(u8, arg, "--no-empty-directory")) {
            no_empty_directory = true;
        } else if (std.mem.eql(u8, arg, "-z")) {
            z_terminator = true;
        } else if (std.mem.eql(u8, arg, "--error-unmatch")) {
            error_unmatch = true;
        } else if (std.mem.eql(u8, arg, "--exclude-standard")) {
            exclude_standard = true;
        } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--ignored")) {
            ignored_flag = true;
        } else if (std.mem.eql(u8, arg, "-t")) {
            tag_flag = true;
        } else if (std.mem.eql(u8, arg, "-v")) {
            verbose_flag = true;
            tag_flag = true;
        } else if (std.mem.eql(u8, arg, "-k") or std.mem.eql(u8, arg, "--killed")) {
            killed_flag = true;
        } else if (std.mem.eql(u8, arg, "--resolve-undo")) {
            resolve_undo_flag = true;
        } else if (std.mem.eql(u8, arg, "--deduplicate")) {
            deduplicate_flag = true;
        } else if (std.mem.eql(u8, arg, "--eol")) {
            eol_flag = true;
        } else if (std.mem.eql(u8, arg, "--full-name") or std.mem.eql(u8, arg, "--recurse-submodules") or
            std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "-f") or
            std.mem.eql(u8, arg, "--debug") or
            std.mem.eql(u8, arg, "--sparse"))
        {
            // Known but not fully implemented flags - accept silently
        } else if (std.mem.eql(u8, arg, "-u") or std.mem.eql(u8, arg, "--unmerged")) {
            unmerged_flag = true;
            stage = true;
        } else if (std.mem.eql(u8, arg, "-x") or std.mem.eql(u8, arg, "--exclude")) {
            if (args.next()) |pat| try exclude_patterns.append(pat);
        } else if (std.mem.startsWith(u8, arg, "--exclude=")) {
            try exclude_patterns.append(arg["--exclude=".len..]);
        } else if (std.mem.startsWith(u8, arg, "-x") and arg.len > 2) {
            try exclude_patterns.append(arg[2..]);
        } else if (std.mem.eql(u8, arg, "-X") or std.mem.eql(u8, arg, "--exclude-from")) {
            if (args.next()) |f| try exclude_files.append(f);
        } else if (std.mem.startsWith(u8, arg, "--exclude-from=")) {
            try exclude_files.append(arg["--exclude-from=".len..]);
        } else if (std.mem.eql(u8, arg, "--exclude-per-directory")) {
            _ = args.next();
        } else if (std.mem.startsWith(u8, arg, "--exclude-per-directory=")) {
            // Accept the = form (ignore for now)
        } else if (std.mem.startsWith(u8, arg, "--format=")) {
            format_str = arg["--format=".len..];
        } else if (std.mem.eql(u8, arg, "--format")) {
            format_str = args.next();
        } else if (std.mem.startsWith(u8, arg, "--abbrev") or
            std.mem.startsWith(u8, arg, "--with-tree"))
        {
            if (std.mem.indexOf(u8, arg, "=") == null) _ = args.next();
        } else if (std.mem.startsWith(u8, arg, "-") and arg.len > 1) {
            const msg = try std.fmt.allocPrint(allocator, "error: unknown option `{s}'\n{s}", .{ arg[1..], ls_files_usage });
            defer allocator.free(msg);
            try platform_impl.writeStderr(msg);
            std.process.exit(129);
        } else if (arg.len > 0) {
            try pathspecs.append(arg);
        }
    }

    // helpers.Find .git directory
    const git_path = helpers.findGitDirectory(allocator, platform_impl) catch {
        try platform_impl.writeStderr("fatal: not a git repository (or any parent up to mount point /)\nStopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set).\n");
        std.process.exit(128);
    };
    defer allocator.free(git_path);

    // helpers.Normalize pathspecs: convert absolute paths to repo-relative paths
    const repo_root = std.fs.path.dirname(git_path) orelse ".";
    var normalized_pathspecs = std.ArrayList([]const u8).init(allocator);
    defer {
        for (normalized_pathspecs.items) |p| allocator.free(@constCast(p));
        normalized_pathspecs.deinit();
    }
    // helpers.Validate pathspecs - empty string is not valid
    for (pathspecs.items) |ps| {
        if (ps.len == 0) {
            try platform_impl.writeStderr("fatal: empty string is not a valid pathspec. please use . instead if you meant to match all paths\n");
            std.process.exit(128);
        }
    }

    var match_all = false;
    for (pathspecs.items) |ps| {
        // helpers.Handle git pathspec magic (e.g., ":/*" means "everything from root")
        if (ps.len >= 2 and ps[0] == ':' and ps[1] == '/') {
            // :/ prefix means "from root of working tree"
            const pattern = ps[2..];
            if (pattern.len == 0 or std.mem.eql(u8, pattern, "*")) {
                // ":/" or ":/*" means match everything
                match_all = true;
                continue;
            }
            try normalized_pathspecs.append(try allocator.dupe(u8, pattern));
            continue;
        }
        if (std.fs.path.isAbsolute(ps)) {
            if (std.mem.startsWith(u8, ps, repo_root) and ps.len > repo_root.len and ps[repo_root.len] == '/') {
                try normalized_pathspecs.append(try allocator.dupe(u8, ps[repo_root.len + 1 ..]));
            } else {
                try normalized_pathspecs.append(try allocator.dupe(u8, ps));
            }
        } else {
            const cwd = platform_impl.fs.getCwd(allocator) catch "";
            defer if (cwd.len > 0) allocator.free(cwd);
            if (cwd.len > repo_root.len and std.mem.startsWith(u8, cwd, repo_root) and cwd[repo_root.len] == '/') {
                const prefix = cwd[repo_root.len + 1 ..];
                const combined = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, ps });
                try normalized_pathspecs.append(combined);
            } else {
                try normalized_pathspecs.append(try allocator.dupe(u8, ps));
            }
        }
    }
    const no_pathspecs: []const []const u8 = &.{};
    const effective_pathspecs = if (match_all) no_pathspecs else if (normalized_pathspecs.items.len > 0) normalized_pathspecs.items else pathspecs.items;

    // helpers.Load index
    var index = index_mod.Index.load(git_path, platform_impl, allocator) catch |err| switch (err) {
        error.FileNotFound => index_mod.Index.init(allocator),
        else => return err,
    };
    defer index.deinit();

    // helpers.Build ignore patterns for -i flag
    var ignore_checker: ?gitignore_mod.GitIgnore = null;
    defer if (ignore_checker) |*ic| ic.deinit();

    if (ignored_flag or exclude_standard or exclude_patterns.items.len > 0 or exclude_files.items.len > 0) {
        var gi = gitignore_mod.GitIgnore.init(allocator);

        // helpers.Load --exclude-standard sources
        if (exclude_standard) {
            // 1. .gitignore in repo root
            const gitignore_path = std.fmt.allocPrint(allocator, "{s}/.gitignore", .{repo_root}) catch null;
            if (gitignore_path) |gip| {
                defer allocator.free(gip);
                if (platform_impl.fs.readFile(allocator, gip)) |content| {
                    defer allocator.free(content);
                    gi.addPatterns(content);
                } else |_| {}
            }
            // 2. .git/info/exclude
            const info_exclude = std.fmt.allocPrint(allocator, "{s}/info/exclude", .{git_path}) catch null;
            if (info_exclude) |ie| {
                defer allocator.free(ie);
                if (platform_impl.fs.readFile(allocator, ie)) |content| {
                    defer allocator.free(content);
                    gi.addPatterns(content);
                } else |_| {}
            }
            // 3. core.excludesFile from config
            const global_excludes = std.fmt.allocPrint(allocator, "{s}/config", .{git_path}) catch null;
            if (global_excludes) |gc| {
                defer allocator.free(gc);
                if (platform_impl.fs.readFile(allocator, gc)) |config_content| {
                    defer allocator.free(config_content);
                    // helpers.Parse core.excludesFile from config - simple approach
                    var lines_it = std.mem.splitScalar(u8, config_content, '\n');
                    while (lines_it.next()) |line| {
                        const trimmed = std.mem.trim(u8, line, " \t\r");
                        if (std.mem.startsWith(u8, trimmed, "excludesFile") or std.mem.startsWith(u8, trimmed, "excludesfile")) {
                            if (std.mem.indexOf(u8, trimmed, "=")) |eq| {
                                const path = std.mem.trim(u8, trimmed[eq + 1 ..], " \t");
                                if (platform_impl.fs.readFile(allocator, path)) |ef_content| {
                                    defer allocator.free(ef_content);
                                    gi.addPatterns(ef_content);
                                } else |_| {}
                            }
                        }
                    }
                } else |_| {}
            }
        }

        // helpers.Load -x patterns
        for (exclude_patterns.items) |pat| {
            gi.addPatterns(pat);
        }

        // helpers.Load -X exclude-from files
        for (exclude_files.items) |ef| {
            if (platform_impl.fs.readFile(allocator, ef)) |content| {
                defer allocator.free(content);
                gi.addPatterns(content);
            } else |_| {}
        }

        ignore_checker = gi;
    }

    // --format incompatibility checks
    if (format_str != null) {
        if (stage or others or killed_flag or tag_flag or resolve_undo_flag or deduplicate_flag or eol_flag) {
            try platform_impl.writeStderr("fatal: options '--format' and other display options are incompatible\n");
            std.process.exit(129);
        }
    }

    if (!cached and !deleted and !modified_flag and !others) {
        cached = true;
    }

    // Compute CWD prefix relative to repo root for relative path output
    const cwd_prefix: ?[]const u8 = blk_cwd: {
        const cwd = platform_impl.fs.getCwd(allocator) catch break :blk_cwd null;
        defer allocator.free(cwd);
        if (cwd.len > repo_root.len and std.mem.startsWith(u8, cwd, repo_root) and cwd[repo_root.len] == '/') {
            break :blk_cwd allocator.dupe(u8, cwd[repo_root.len + 1 ..]) catch null;
        }
        break :blk_cwd null;
    };
    defer if (cwd_prefix) |p| allocator.free(p);

    // Handle --eol output mode
    if (eol_flag) {
        const terminator_eol: []const u8 = if (z_terminator) "\x00" else "\n";

        // Load .gitattributes for attribute resolution
        const check_attr = @import("cmd_check_attr.zig");
        var attr_rules = std.ArrayList(check_attr.AttrRule).init(allocator);
        defer {
            for (attr_rules.items) |*rule| rule.deinit(allocator);
            attr_rules.deinit();
        }
        check_attr.loadAttrFile(allocator, repo_root, "", platform_impl, &attr_rules) catch {};
        // Load info/attributes
        const info_attr_path = try std.fmt.allocPrint(allocator, "{s}/info/attributes", .{git_path});
        defer allocator.free(info_attr_path);
        if (platform_impl.fs.readFile(allocator, info_attr_path)) |ia_content| {
            defer allocator.free(ia_content);
            check_attr.parseAttrContent(allocator, ia_content, "", &attr_rules) catch {};
        } else |_| {}

        // Read core.autocrlf and core.eol config
        const autocrlf_val = helpers.getConfigValueByKey(git_path, "core.autocrlf", allocator);
        defer if (autocrlf_val) |v| allocator.free(v);
        const eol_config_val = helpers.getConfigValueByKey(git_path, "core.eol", allocator);
        defer if (eol_config_val) |v| allocator.free(v);

        if (!others) {
            // Show tracked files
            for (index.entries.items) |entry| {
                if (effective_pathspecs.len > 0) {
                    var matches = false;
                    for (effective_pathspecs) |ps| {
                        if (std.mem.eql(u8, ps, ":/") or
                            std.mem.eql(u8, entry.path, ps) or
                            (std.mem.startsWith(u8, entry.path, ps) and entry.path.len > ps.len and entry.path[ps.len] == '/') or
                            helpers.pathspecMatchesPath(ps, entry.path, false))
                        {
                            matches = true;
                            break;
                        }
                    }
                    if (!matches) continue;
                }

                if (deleted) {
                    // Only show deleted files
                    const fp = if (repo_root.len > 0 and !std.mem.eql(u8, repo_root, "."))
                        std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, entry.path }) catch continue
                    else
                        allocator.dupe(u8, entry.path) catch continue;
                    defer allocator.free(fp);
                    const file_exists = platform_impl.fs.exists(fp) catch false;
                    if (file_exists) continue;
                }

                const eol_i = getEolInfoIndex(allocator, entry, git_path, platform_impl);
                const eol_w = getEolInfoWorktree(allocator, entry, repo_root, platform_impl);
                const attr_str = getEolAttr(allocator, entry.path, &attr_rules, autocrlf_val, eol_config_val);
                defer allocator.free(attr_str);
                const i_field = try std.fmt.allocPrint(allocator, "i/{s}", .{eol_i});
                defer allocator.free(i_field);
                const w_field = try std.fmt.allocPrint(allocator, "w/{s}", .{eol_w});
                defer allocator.free(w_field);
                const attr_field = try std.fmt.allocPrint(allocator, "attr/{s}", .{attr_str});
                defer allocator.free(attr_field);
                const output = try std.fmt.allocPrint(allocator, "{s: <8}{s: <8}{s: <22}\t{s}{s}", .{ i_field, w_field, attr_field, entry.path, terminator_eol });
                defer allocator.free(output);
                try platform_impl.writeStdout(output);
            }
        }

        if (others) {
            // Show untracked files with eol info
            const gitignore_path = try std.fmt.allocPrint(allocator, "{s}/.gitignore", .{repo_root});
            defer allocator.free(gitignore_path);
            var gitignore = gitignore_mod.GitIgnore.loadFromFile(allocator, gitignore_path, platform_impl) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => gitignore_mod.GitIgnore.init(allocator),
            };
            defer gitignore.deinit();

            var untracked_files = helpers.findUntrackedFiles(allocator, repo_root, &index, &gitignore, platform_impl) catch std.ArrayList([]u8).init(allocator);
            defer {
                for (untracked_files.items) |file| allocator.free(file);
                untracked_files.deinit();
            }
            std.sort.block([]u8, untracked_files.items, {}, struct {
                fn lt(_: void, a: []u8, b: []u8) bool { return std.mem.order(u8, a, b) == .lt; }
            }.lt);
            for (untracked_files.items) |file| {
                if (effective_pathspecs.len > 0) {
                    var matches = false;
                    for (effective_pathspecs) |ps| {
                        if (helpers.pathspecMatchesPath(ps, file, false)) { matches = true; break; }
                    }
                    if (!matches) continue;
                }
                const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, file });
                defer allocator.free(full_path);
                const wt_content = platform_impl.fs.readFile(allocator, full_path) catch "";
                defer if (wt_content.len > 0) allocator.free(wt_content);
                const eol_w = detectEolInfo(wt_content);
                const attr_str = getEolAttr(allocator, file, &attr_rules, autocrlf_val, eol_config_val);
                defer allocator.free(attr_str);
                const i_field = "i/";
                const w_field = try std.fmt.allocPrint(allocator, "w/{s}", .{eol_w});
                defer allocator.free(w_field);
                const attr_field = try std.fmt.allocPrint(allocator, "attr/{s}", .{attr_str});
                defer allocator.free(attr_field);
                const output = try std.fmt.allocPrint(allocator, "{s: <8}{s: <8}{s: <22}\t{s}{s}", .{ i_field, w_field, attr_field, file, terminator_eol });
                defer allocator.free(output);
                try platform_impl.writeStdout(output);
            }
        }
        return;
    }

    // helpers.Handle --format output mode
    if (format_str) |fmt| {
        const terminator: []const u8 = if (z_terminator) "\x00" else "\n";
        const repo_root2 = std.fs.path.dirname(git_path) orelse ".";
        for (index.entries.items) |entry| {
            if (effective_pathspecs.len > 0) {
                var matches = false;
                for (effective_pathspecs) |ps| {
                    if (std.mem.eql(u8, ps, ":/") or
                        std.mem.eql(u8, entry.path, ps) or
                        (std.mem.startsWith(u8, entry.path, ps) and entry.path.len > ps.len and entry.path[ps.len] == '/') or
                        helpers.pathspecMatchesPath(ps, entry.path, false))
                    {
                        matches = true;
                        break;
                    }
                }
                if (!matches) continue;
            }
            if (ignored_flag) {
                if (ignore_checker) |*ic| {
                    if (!ic.isIgnored(entry.path)) continue;
                } else continue;
            }

            // helpers.Apply -m (modified) filter
            if (modified_flag) {
                const full_path2 = std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root2, entry.path }) catch continue;
                defer allocator.free(full_path2);
                const file_exists2 = platform_impl.fs.exists(full_path2) catch false;
                if (!file_exists2) {
                    // File doesn't exist on disk = show it (it's "modified" in the sense of deleted)
                } else {
                    const current_content2 = platform_impl.fs.readFile(allocator, full_path2) catch continue;
                    defer allocator.free(current_content2);
                    const blob2 = objects.createBlobObject(current_content2, allocator) catch continue;
                    defer blob2.deinit(allocator);
                    const current_hash2 = blob2.hash(allocator) catch continue;
                    defer allocator.free(current_hash2);
                    const index_hash2 = std.fmt.allocPrint(allocator, "{}", .{std.fmt.fmtSliceHexLower(&entry.sha1)}) catch continue;
                    defer allocator.free(index_hash2);
                    if (std.mem.eql(u8, current_hash2, index_hash2)) continue; // not modified
                }
            }

            // helpers.Apply -d (deleted) filter
            if (deleted) {
                const full_path2 = std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root2, entry.path }) catch continue;
                defer allocator.free(full_path2);
                const file_exists2 = platform_impl.fs.exists(full_path2) catch false;
                if (file_exists2) continue; // file exists, not deleted
            }

            const formatted = try formatLsFilesEntry(allocator, fmt, entry, git_path, platform_impl, cwd_prefix);
            defer allocator.free(formatted);
            const output = try std.fmt.allocPrint(allocator, "{s}{s}", .{ formatted, terminator });
            defer allocator.free(output);
            try platform_impl.writeStdout(output);
        }
        return;
    }

    if (cached) {
        var pathspec_matched: ?[]bool = null;
        defer if (pathspec_matched) |pm| allocator.free(pm);
        if (error_unmatch and effective_pathspecs.len > 0) {
            pathspec_matched = try allocator.alloc(bool, effective_pathspecs.len);
            @memset(pathspec_matched.?, false);
        }

        const terminator_cached: []const u8 = if (z_terminator) "\x00" else "\n";
        var last_dedup_path: ?[]u8 = null;
        defer if (last_dedup_path) |lp| allocator.free(lp);
        for (index.entries.items) |entry| {
            if (effective_pathspecs.len > 0) {
                var matches = false;
                for (effective_pathspecs, 0..) |ps, pi| {
                    if (helpers.matchPathspec(entry.path, ps)) {
                        matches = true;
                        if (pathspec_matched) |pm| pm[pi] = true;
                        break;
                    }
                }
                if (!matches) continue;
            }
            // helpers.When -i (ignored) flag is set, only show files matching ignore patterns
            if (ignored_flag) {
                if (ignore_checker) |*ic| {
                    if (!ic.isIgnored(entry.path)) continue;
                } else {
                    // helpers.No ignore patterns loaded, nothing can match
                    continue;
                }
            }
            // helpers.When --unmerged is set, only show entries with stage > 0
            if (unmerged_flag) {
                const stage_check = (entry.flags >> 12) & 0x3;
                if (stage_check == 0) continue;
            }
            if (stage) {
                const hash_str = try std.fmt.allocPrint(allocator, "{}", .{std.fmt.fmtSliceHexLower(&entry.sha1)});
                defer allocator.free(hash_str);
                const stage_num = (entry.flags >> 12) & 0x3;
                const quoted = if (z_terminator) try allocator.dupe(u8, entry.path) else try helpers.cQuotePath(allocator, entry.path, true);
                defer allocator.free(quoted);
                const tag_prefix: []const u8 = if (tag_flag) blk_tag: {
                    const has_skip_wt = if (entry.extended_flags) |ef| (ef & 0x4000 != 0) else (entry.flags & 0x4000 != 0);
                    const is_assume_unchanged = (entry.flags & 0x8000) != 0;
                    if (has_skip_wt) break :blk_tag "S " else if (verbose_flag and is_assume_unchanged) break :blk_tag "h " else break :blk_tag "H ";
                } else "";
                const output = try std.fmt.allocPrint(allocator, "{s}{o} {s} {d}\t{s}{s}", .{ tag_prefix, entry.mode, hash_str, stage_num, quoted, terminator_cached });
                defer allocator.free(output);
                try platform_impl.writeStdout(output);
            } else {
                // Deduplicate: skip if same path as previous entry
                if (deduplicate_flag) {
                    if (last_dedup_path) |lp| {
                        if (std.mem.eql(u8, lp, entry.path)) continue;
                    }
                    if (last_dedup_path) |lp| allocator.free(lp);
                    last_dedup_path = try allocator.dupe(u8, entry.path);
                }
                const quoted = if (z_terminator) try allocator.dupe(u8, entry.path) else try helpers.cQuotePath(allocator, entry.path, true);
                defer allocator.free(quoted);
                const tag_prefix: []const u8 = if (tag_flag) blk_tag2: {
                    const has_skip_wt = if (entry.extended_flags) |ef| (ef & 0x4000 != 0) else (entry.flags & 0x4000 != 0);
                    const is_assume_unchanged2 = (entry.flags & 0x8000) != 0;
                    if (has_skip_wt) break :blk_tag2 "S " else if (verbose_flag and is_assume_unchanged2) break :blk_tag2 "h " else break :blk_tag2 "H ";
                } else "";
                const output = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ tag_prefix, quoted, terminator_cached });
                defer allocator.free(output);
                try platform_impl.writeStdout(output);
            }
        }

        if (error_unmatch) {
            if (pathspec_matched) |pm| {
                for (pm, 0..) |matched, pi| {
                    if (!matched) {
                        const orig_ps = if (pi < pathspecs.items.len) pathspecs.items[pi] else effective_pathspecs[pi];
                        const msg = try std.fmt.allocPrint(allocator, "error: pathspec '{s}' did not match any file(s) known to git\n", .{orig_ps});
                        defer allocator.free(msg);
                        try platform_impl.writeStderr(msg);
                        std.process.exit(1);
                    }
                }
            }
        }
    }

    if (deleted) {
        for (index.entries.items) |entry| {
            const full_path = if (std.fs.path.isAbsolute(entry.path))
                try allocator.dupe(u8, entry.path)
            else
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, entry.path });
            defer allocator.free(full_path);
            const file_exists = platform_impl.fs.exists(full_path) catch false;
            if (!file_exists) {
                const output = try std.fmt.allocPrint(allocator, "{s}\n", .{entry.path});
                defer allocator.free(output);
                try platform_impl.writeStdout(output);
            }
        }
    }

    if (modified_flag) {
        for (index.entries.items) |entry| {
            const full_path = if (std.fs.path.isAbsolute(entry.path))
                try allocator.dupe(u8, entry.path)
            else
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, entry.path });
            defer allocator.free(full_path);
            const file_exists = platform_impl.fs.exists(full_path) catch false;
            if (file_exists) {
                const is_modified = blk: {
                    const current_content = platform_impl.fs.readFile(allocator, full_path) catch break :blk false;
                    defer allocator.free(current_content);
                    const blob = objects.createBlobObject(current_content, allocator) catch break :blk false;
                    defer blob.deinit(allocator);
                    const current_hash = blob.hash(allocator) catch break :blk false;
                    defer allocator.free(current_hash);
                    const index_hash = std.fmt.allocPrint(allocator, "{}", .{std.fmt.fmtSliceHexLower(&entry.sha1)}) catch break :blk false;
                    defer allocator.free(index_hash);
                    break :blk !std.mem.eql(u8, current_hash, index_hash);
                };
                if (is_modified) {
                    const output = try std.fmt.allocPrint(allocator, "{s}\n", .{entry.path});
                    defer allocator.free(output);
                    try platform_impl.writeStdout(output);
                }
            }
        }
    }

    if (others) {
        const gitignore_path = try std.fmt.allocPrint(allocator, "{s}/.gitignore", .{repo_root});
        defer allocator.free(gitignore_path);
        var gitignore = gitignore_mod.GitIgnore.loadFromFile(allocator, gitignore_path, platform_impl) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => gitignore_mod.GitIgnore.init(allocator),
        };
        defer gitignore.deinit();

        var others_found: usize = 0;
        if (directory) {
            var dir_entries = std.ArrayList([]u8).init(allocator);
            defer {
                for (dir_entries.items) |e| allocator.free(e);
                dir_entries.deinit();
            }
            try helpers.findUntrackedDirEntries(allocator, repo_root, "", &dir_entries, &index, &gitignore, no_empty_directory, effective_pathspecs, platform_impl);
            std.sort.block([]u8, dir_entries.items, {}, struct {
                fn lt(_: void, a: []u8, b: []u8) bool { return std.mem.order(u8, a, b) == .lt; }
            }.lt);
            for (dir_entries.items) |file| {
                others_found += 1;
                const display_path_d = @as([]const u8, file);
                const output = try std.fmt.allocPrint(allocator, "{s}\n", .{display_path_d});
                defer allocator.free(output);
                try platform_impl.writeStdout(output);
            }
        } else {
            var untracked_files = helpers.findUntrackedFiles(allocator, repo_root, &index, &gitignore, platform_impl) catch std.ArrayList([]u8).init(allocator);
            defer {
                for (untracked_files.items) |file| allocator.free(file);
                untracked_files.deinit();
            }
            std.sort.block([]u8, untracked_files.items, {}, struct {
                fn lt(_: void, a: []u8, b: []u8) bool { return std.mem.order(u8, a, b) == .lt; }
            }.lt);
            for (untracked_files.items) |file| {
                if (effective_pathspecs.len > 0) {
                    var matches = false;
                    for (effective_pathspecs) |ps| {
                        if (helpers.pathspecMatchesPath(ps, file, false)) { matches = true; break; }
                    }
                    if (!matches) continue;
                }
                others_found += 1;
                const display_path_u = @as([]const u8, file);
                const output = try std.fmt.allocPrint(allocator, "{s}\n", .{display_path_u});
                defer allocator.free(output);
                try platform_impl.writeStdout(output);
            }
        }
        if (error_unmatch and others_found == 0) {
            std.process.exit(1);
        }
    }
}


/// Make a repo-relative path relative to a CWD prefix within the repo.
/// E.g., path="o1.txt", cwd_prefix="sub" -> "../o1.txt"
fn makeRelativePath(allocator: std.mem.Allocator, path: []const u8, cwd_prefix: []const u8) ![]u8 {
    if (cwd_prefix.len == 0) return allocator.dupe(u8, path);
    // Check if path starts with the cwd prefix
    if (std.mem.startsWith(u8, path, cwd_prefix) and path.len > cwd_prefix.len and path[cwd_prefix.len] == '/') {
        return allocator.dupe(u8, path[cwd_prefix.len + 1 ..]);
    }
    // Count how many directory levels in the prefix
    var depth: usize = 1;
    for (cwd_prefix) |c| {
        if (c == '/') depth += 1;
    }
    var result = std.ArrayList(u8).init(allocator);
    for (0..depth) |_| {
        try result.appendSlice("../");
    }
    try result.appendSlice(path);
    return result.toOwnedSlice();
}

/// Detect line ending type in content. Returns "lf", "crlf", "mixed", or "" (no line endings).
fn detectEolInfo(content: []const u8) []const u8 {
    if (content.len == 0) return "";

    // Match git's gather_stats / convert_is_binary / gather_convert_stats_ascii logic
    var nul_count: usize = 0;
    var lone_cr: usize = 0;
    var lone_lf: usize = 0;
    var crlf_count: usize = 0;
    var printable: usize = 0;
    var nonprintable: usize = 0;

    var i: usize = 0;
    while (i < content.len) {
        const c = content[i];
        if (c == '\r') {
            if (i + 1 < content.len and content[i + 1] == '\n') {
                crlf_count += 1;
                i += 2;
            } else {
                lone_cr += 1;
                i += 1;
            }
            continue;
        }
        if (c == '\n') {
            lone_lf += 1;
            i += 1;
            continue;
        }
        if (c == 127) {
            nonprintable += 1;
        } else if (c < 32) {
            switch (c) {
                '\x08', '\t', '\x1b', '\x0c' => {
                    printable += 1;
                },
                0 => {
                    nul_count += 1;
                    nonprintable += 1;
                },
                else => {
                    nonprintable += 1;
                },
            }
        } else {
            printable += 1;
        }
        i += 1;
    }

    // If file ends with \032 (SUB/Ctrl+Z/EOF), don't count it as non-printable
    if (content.len >= 1 and content[content.len - 1] == '\x1a') {
        if (nonprintable > 0) nonprintable -= 1;
    }

    // Binary detection: lone CR, NUL bytes, or too many non-printable chars
    if (lone_cr > 0 or nul_count > 0 or (printable >> 7) < nonprintable) {
        return "-text";
    }

    // Text line ending detection
    const has_lf = lone_lf > 0;
    const has_crlf = crlf_count > 0;
    if (has_lf and has_crlf) return "mixed";
    if (has_lf) return "lf";
    if (has_crlf) return "crlf";
    return "none";
}

/// Compute the "attr/" field for ls-files --eol.
/// This resolves .gitattributes text/eol settings for a file path.
fn getEolAttr(allocator: std.mem.Allocator, path: []const u8, attr_rules: *const std.ArrayList(@import("cmd_check_attr.zig").AttrRule), autocrlf_val: ?[]const u8, eol_config_val: ?[]const u8) []u8 {
    const check_attr = @import("cmd_check_attr.zig");
    var text_val: ?[]const u8 = null; // null=unspecified, "set"=text, "auto"=text=auto, "unset"=-text
    var eol_val: ?[]const u8 = null; // null=unspecified, "lf", "crlf"
    _ = autocrlf_val;
    _ = eol_config_val;

    // Search attribute rules (last match wins)
    for (attr_rules.items) |rule| {
        if (check_attr.attrPatternMatches(rule.pattern, path)) {
            for (rule.attrs.items) |attr| {
                if (std.mem.eql(u8, attr.name, "text")) {
                    if (std.mem.eql(u8, attr.value, "set")) {
                        text_val = "set";
                    } else if (std.mem.eql(u8, attr.value, "unset")) {
                        text_val = "unset";
                    } else if (std.mem.eql(u8, attr.value, "auto")) {
                        text_val = "auto";
                    } else if (std.mem.eql(u8, attr.value, "unspecified")) {
                        text_val = null;
                    }
                } else if (std.mem.eql(u8, attr.name, "eol")) {
                    if (std.mem.eql(u8, attr.value, "lf")) {
                        eol_val = "lf";
                    } else if (std.mem.eql(u8, attr.value, "crlf")) {
                        eol_val = "crlf";
                    }
                } else if (std.mem.eql(u8, attr.name, "binary")) {
                    if (std.mem.eql(u8, attr.value, "set")) {
                        text_val = "unset"; // binary implies -text
                    }
                }
            }
        }
    }

    // Build the attr string
    // When text is unset (-text), show "-text"
    if (text_val) |tv| {
        if (std.mem.eql(u8, tv, "unset")) {
            return allocator.dupe(u8, "-text") catch return allocator.dupe(u8, "") catch unreachable;
        } else if (std.mem.eql(u8, tv, "auto")) {
            if (eol_val) |ev| {
                return std.fmt.allocPrint(allocator, "text=auto eol={s}", .{ev}) catch return allocator.dupe(u8, "") catch unreachable;
            }
            return allocator.dupe(u8, "text=auto") catch return allocator.dupe(u8, "") catch unreachable;
        } else if (std.mem.eql(u8, tv, "set")) {
            if (eol_val) |ev| {
                return std.fmt.allocPrint(allocator, "text eol={s}", .{ev}) catch return allocator.dupe(u8, "") catch unreachable;
            }
            return allocator.dupe(u8, "text") catch return allocator.dupe(u8, "") catch unreachable;
        }
    }

    // No explicit text attribute - check if eol attribute alone implies text
    if (eol_val) |ev| {
        return std.fmt.allocPrint(allocator, "text eol={s}", .{ev}) catch return allocator.dupe(u8, "") catch unreachable;
    }

    // No attributes set - return empty
    return allocator.dupe(u8, "") catch unreachable;
}

/// Get eolinfo for an index entry by reading the object content.
fn getEolInfoIndex(allocator: std.mem.Allocator, entry: anytype, git_path: []const u8, platform_impl: anytype) []const u8 {
    // Symlinks and submodules have no eol info
    if (entry.mode & 0o170000 == 0o120000) return "";
    if (entry.mode & 0o170000 == 0o160000) return "";
    const hash_hex = std.fmt.allocPrint(allocator, "{}", .{std.fmt.fmtSliceHexLower(&entry.sha1)}) catch return "";
    defer allocator.free(hash_hex);
    const content = helpers.readBlobContent(allocator, git_path, hash_hex, platform_impl) catch return "";
    defer allocator.free(content);
    return detectEolInfo(content);
}

/// Get eolinfo for a worktree file.
fn getEolInfoWorktree(allocator: std.mem.Allocator, entry: anytype, repo_root: []const u8, platform_impl: anytype) []const u8 {
    // Symlinks and submodules have no eol info
    if (entry.mode & 0o170000 == 0o120000) return "";
    if (entry.mode & 0o170000 == 0o160000) return "";
    const full_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ repo_root, entry.path }) catch return "";
    defer allocator.free(full_path);
    const content = platform_impl.fs.readFile(allocator, full_path) catch return "";
    defer allocator.free(content);
    return detectEolInfo(content);
}

pub fn formatLsFilesEntry(allocator: std.mem.Allocator, fmt: []const u8, entry: anytype, git_path: []const u8, platform_impl: anytype, cwd_prefix: ?[]const u8) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();

    var i: usize = 0;
    while (i < fmt.len) {
        if (fmt[i] == '%' and i + 1 < fmt.len) {
            if (fmt[i + 1] == '%') {
                try result.append('%');
                i += 2;
                continue;
            }
            if (fmt[i + 1] == 'x' and i + 3 < fmt.len) {
                // %xNN hex escape
                const hex = fmt[i + 2 .. i + 4];
                const byte = std.fmt.parseInt(u8, hex, 16) catch {
                    try result.append('%');
                    i += 1;
                    continue;
                };
                try result.append(byte);
                i += 4;
                continue;
            }
            if (fmt[i + 1] == '(') {
                // %(fieldname) format
                const close = std.mem.indexOf(u8, fmt[i + 2 ..], ")") orelse {
                    try result.append('%');
                    i += 1;
                    continue;
                };
                const field = fmt[i + 2 .. i + 2 + close];
                i = i + 2 + close + 1;

                if (std.mem.eql(u8, field, "objectmode")) {
                    const mode_str = try std.fmt.allocPrint(allocator, "{o}", .{entry.mode});
                    defer allocator.free(mode_str);
                    try result.appendSlice(mode_str);
                } else if (std.mem.eql(u8, field, "objectname")) {
                    const hash_str = try std.fmt.allocPrint(allocator, "{}", .{std.fmt.fmtSliceHexLower(&entry.sha1)});
                    defer allocator.free(hash_str);
                    try result.appendSlice(hash_str);
                } else if (std.mem.eql(u8, field, "objecttype")) {
                    // helpers.Determine type from mode
                    const obj_type: []const u8 = if (entry.mode & 0o170000 == 0o120000)
                        "blob" // symlink stored as blob
                    else if (entry.mode & 0o170000 == 0o160000)
                        "commit" // gitlink/submodule
                    else if (entry.mode & 0o170000 == 0o040000)
                        "tree"
                    else
                        "blob";
                    try result.appendSlice(obj_type);
                } else if (std.mem.eql(u8, field, "objectsize")) {
                    // Submodule (gitlink) entries have no size
                    if (entry.mode & 0o170000 == 0o160000) {
                        try result.append('-');
                    } else {
                        const size = helpers.getObjectSize(allocator, git_path, &entry.sha1, platform_impl) catch 0;
                        const size_str = try std.fmt.allocPrint(allocator, "{d}", .{size});
                        defer allocator.free(size_str);
                        try result.appendSlice(size_str);
                    }
                } else if (std.mem.eql(u8, field, "objectsize:padded")) {
                    if (entry.mode & 0o170000 == 0o160000) {
                        try result.appendSlice("      -");
                    } else {
                        const size = helpers.getObjectSize(allocator, git_path, &entry.sha1, platform_impl) catch 0;
                        const size_str = try std.fmt.allocPrint(allocator, "{d: >7}", .{size});
                        defer allocator.free(size_str);
                        try result.appendSlice(size_str);
                    }
                } else if (std.mem.eql(u8, field, "stage")) {
                    const stage_num = (entry.flags >> 12) & 0x3;
                    const stage_str = try std.fmt.allocPrint(allocator, "{d}", .{stage_num});
                    defer allocator.free(stage_str);
                    try result.appendSlice(stage_str);
                } else if (std.mem.eql(u8, field, "path")) {
                    if (cwd_prefix) |pfx| {
                        // Make path relative to CWD
                        const rel = try makeRelativePath(allocator, entry.path, pfx);
                        defer allocator.free(rel);
                        try result.appendSlice(rel);
                    } else {
                        try result.appendSlice(entry.path);
                    }
                } else if (std.mem.eql(u8, field, "eolinfo:index")) {
                    const repo_root_local = std.fs.path.dirname(git_path) orelse ".";
                    _ = repo_root_local;
                    try result.appendSlice(getEolInfoIndex(allocator, entry, git_path, platform_impl));
                } else if (std.mem.eql(u8, field, "eolinfo:worktree")) {
                    const repo_root_local = std.fs.path.dirname(git_path) orelse ".";
                    try result.appendSlice(getEolInfoWorktree(allocator, entry, repo_root_local, platform_impl));
                } else if (std.mem.eql(u8, field, "eolattr")) {
                    try result.appendSlice("");
                }
                continue;
            }
            try result.append(fmt[i]);
            i += 1;
        } else if (fmt[i] == '\\' and i + 1 < fmt.len) {
            switch (fmt[i + 1]) {
                'n' => try result.append('\n'),
                't' => try result.append('\t'),
                '\\' => try result.append('\\'),
                '0' => try result.append(0),
                else => {
                    try result.append('\\');
                    try result.append(fmt[i + 1]);
                },
            }
            i += 2;
        } else {
            try result.append(fmt[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice();
}
